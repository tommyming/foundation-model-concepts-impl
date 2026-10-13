// Demo runtime: one shared base model + task adapters (Mode 2), or one model
// instance per task (Mode 1, naive). All lifecycle is timed, logged, signposted.

import Foundation
import MLXLLM
import MLXLMCommon
import os

private let log = Logger(subsystem: "com.iosconf.aimemorylab", category: "ModelManager")

enum AITask: String, CaseIterable, Sendable {
    case summarize
    case classify
    case extract

    /// System prompt per task. These match the training data exactly.
    var instructions: String {
        switch self {
        case .classify:
            return "You classify notes. Answer with exactly one word from this list: Technology, Business, Science, Culture, Other. Output nothing else."
        case .summarize:
            return "You summarize notes in exactly one sentence. Keep names and deadlines. Output only the summary sentence. /no_think"
        case .extract:
            return "You extract structured data from notes. Output only strict JSON with these keys: people, organizations, locations, action_items. Each value is a list of strings. Output nothing else. /no_think"
        }
    }
}

struct RunMetrics: Sendable {
    var task: AITask
    var adapterSwitch: Duration?
    var modelLoad: Duration?
    var firstToken: Duration?
    var total: Duration
    var memoryBefore: MemorySnapshot
    var memoryAfter: MemorySnapshot
}

@MainActor
final class AppModel: ObservableObject {
    enum Mode: String, CaseIterable {
        case sharedBase
        case naive
    }

    enum State: String {
        case idle
        case loading
        case ready
        case running
    }

    enum ModelError: LocalizedError {
        case missingWeights
        var errorDescription: String? {
            "Model directory missing from bundle. Run scripts/fetch-model.sh, then rebuild."
        }
    }

    static let genParams = GenerateParameters(maxTokens: 256, temperature: 0)

    @Published var mode: Mode = .sharedBase
    @Published var state: State = .idle
    @Published var output = ""
    @Published var errorText: String?
    @Published var loadDuration: Duration?
    @Published var activeAdapter: AITask?
    @Published var lastSwitch: Duration?
    @Published var lastMetrics: RunMetrics?
    @Published var residentInstances: Set<AITask> = []

    // Shared mode: one base model, N adapters.
    private var container: ModelContainer?
    private var session: ChatSession?
    private var adapters: [AITask: LoRAContainer] = [:]

    // Naive mode: one full model instance per task.
    private var naiveSessions: [AITask: ChatSession] = [:]

    private var runTask: Task<Void, Never>?

    var isBusy: Bool { state == .loading || state == .running }
    var baseLoaded: Bool { container != nil }

    // MARK: - Loading

    private static func makeContainer() async throws -> ModelContainer {
        guard let dir = Bundle.main.url(forResource: "Qwen3-1.7B-4bit", withExtension: nil) else {
            throw ModelError.missingWeights
        }
        return try await loadModelContainer(from: dir, using: BundleTokenizerLoader())
    }

    /// Loads the shared base model (Mode 2).
    func loadBase() async {
        guard state == .idle, container == nil else { return }
        state = .loading
        log.info("Base model load started")
        let sp = DemoSignposts.begin("BaseLoad")
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let c = try await Self.makeContainer()
            loadDuration = clock.now - start
            container = c
            rebuildSession(for: nil)
            DemoSignposts.end("BaseLoad", sp)
            log.info("Base model load completed: \(secondsString(self.loadDuration!), privacy: .public) s")
            state = .ready
        } catch {
            DemoSignposts.end("BaseLoad", sp)
            fail("Load failed: \(error.localizedDescription)")
        }
    }

    func reset() {
        runTask?.cancel()
        container = nil
        session = nil
        adapters.removeAll()
        naiveSessions.removeAll()
        residentInstances.removeAll()
        activeAdapter = nil
        state = .idle
        output = ""
        DemoSignposts.event("Reset")
        log.info("Runtime reset")
    }

    // MARK: - Running

    func run(task aITask: AITask, input: String) {
        guard state == .ready, runTask == nil else { return }
        state = .running
        output = ""
        errorText = nil
        let clock = ContinuousClock()
        let start = clock.now
        let memoryBefore = readMemory()
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                var switchTime: Duration?
                var loadTime: Duration?
                var chat: ChatSession?

                switch self.mode {
                case .sharedBase:
                    switchTime = await self.activateAdapter(for: aITask)
                    chat = self.session
                case .naive:
                    if self.naiveSessions[aITask] == nil {
                        log.info("Naive instance for \(aITask.rawValue, privacy: .public) became resident")
                        let sp = DemoSignposts.begin("NaiveLoad")
                        let t0 = clock.now
                        let c = try await Self.makeContainer()
                        loadTime = clock.now - t0
                        DemoSignposts.end("NaiveLoad", sp)
                        self.naiveSessions[aITask] = ChatSession(
                            c, instructions: aITask.instructions,
                            generateParameters: Self.genParams)
                        self.residentInstances.insert(aITask)
                    }
                    chat = self.naiveSessions[aITask]
                }
                guard let chat else { throw ModelError.missingWeights }

                let sp = DemoSignposts.begin("Inference")
                var firstToken: Duration?
                var text = ""
                for try await chunk in chat.streamResponse(to: input) {
                    if Task.isCancelled { break }
                    if firstToken == nil {
                        firstToken = clock.now - start
                        DemoSignposts.event("FirstToken")
                        log.info("First token: \(secondsString(firstToken!), privacy: .public) s")
                    }
                    text += chunk
                    self.output = text
                }
                DemoSignposts.end("Inference", sp)
                let total = clock.now - start
                self.lastMetrics = RunMetrics(
                    task: aITask, adapterSwitch: switchTime, modelLoad: loadTime,
                    firstToken: firstToken, total: total,
                    memoryBefore: memoryBefore, memoryAfter: readMemory())
                log.info("Inference complete: \(secondsString(total), privacy: .public) s")
                self.state = .ready
            } catch {
                self.fail("Run failed: \(error.localizedDescription)")
            }
            self.runTask = nil
        }
    }

    func cancel() { runTask?.cancel() }

    // MARK: - Adapter switching (shared mode)

    /// Unloads the current adapter, loads the one for `task`, rebuilds the session.
    /// Returns the measured switch duration, or nil when no change was needed.
    private func activateAdapter(for task: AITask) async -> Duration? {
        guard let container else { return nil }
        if activeAdapter == task { return nil }

        if adapters[task] == nil {
            guard let root = Bundle.main.url(forResource: "adapters", withExtension: nil) else {
                fail("adapters/ missing from bundle.")
                return nil
            }
            do {
                adapters[task] = try LoRAContainer.from(
                    directory: root.appending(component: task.rawValue))
                log.info("Adapter \(task.rawValue, privacy: .public) parsed")
            } catch {
                fail("Adapter parse failed: \(error.localizedDescription)")
                return nil
            }
        }
        guard let adapter = adapters[task] else { return nil }

        let previous = activeAdapter
        let old = previous.flatMap { adapters[$0] }
        let clock = ContinuousClock()
        let start = clock.now
        final class ErrorBox { var error: Error? }
        let box = ErrorBox()
        let sp = DemoSignposts.begin("AdapterSwitch")
        await container.update { context in
            do {
                old?.unload(from: context.model)
                try adapter.load(into: context.model)
            } catch {
                box.error = error
            }
        }
        DemoSignposts.end("AdapterSwitch", sp)
        if let error = box.error {
            fail("Adapter switch failed: \(error.localizedDescription)")
            return nil
        }
        let elapsed = clock.now - start
        lastSwitch = elapsed
        activeAdapter = task
        rebuildSession(for: task)
        log.info("Adapter \(previous?.rawValue ?? "none", privacy: .public) -> \(task.rawValue, privacy: .public): switch \(secondsString(elapsed), privacy: .public) s")
        return elapsed
    }

    /// Fresh session so the KV cache never spans an adapter boundary.
    private func rebuildSession(for task: AITask?) {
        guard let container else { return }
        session = ChatSession(
            container,
            instructions: task?.instructions ?? "You are a concise assistant. /no_think",
            generateParameters: Self.genParams)
    }

    private func fail(_ message: String) {
        errorText = message
        state = .idle
        log.error("ModelManager: \(message, privacy: .public)")
    }
}

private func secondsString(_ d: Duration) -> String {
    let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    return String(format: "%.2f", s)
}
