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
    /// Max phys_footprint sampled during this run's load, switch, and inference.
    var phasePeakMB: Double
    var inputTokens: Int?
    var outputTokens: Int?
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
        case missingAdapters
        case sharedModelStillResident

        var errorDescription: String? {
            switch self {
            case .missingWeights:
                return "Model directory missing from bundle. Run scripts/fetch-model.sh, then rebuild."
            case .missingAdapters:
                return "adapters/ missing from bundle."
            case .sharedModelStillResident:
                return "Naive run refused because the shared base is still resident."
            }
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

    /// Max phys_footprint sampled during the most recent shared base load.
    private(set) var lastLoadPhasePeakMB: Double = 0

    // Shared mode: one base model, N adapters.
    private var container: ModelContainer?
    private var session: ChatSession?
    private var adapters: [AITask: LoRAContainer] = [:]

    // Naive mode: one full model instance per task. Containers stay so sessions can be rebuilt.
    private var naiveContainers: [AITask: ModelContainer] = [:]
    private var naiveSessions: [AITask: ChatSession] = [:]

    private var runTask: Task<Void, Never>?

    var isBusy: Bool { state == .loading || state == .running }
    var baseLoaded: Bool { container != nil }
    private var hasResidentModel: Bool { container != nil || !naiveContainers.isEmpty }

    // MARK: - Loading

    private static func makeContainer() async throws -> ModelContainer {
        guard let dir = Bundle.main.url(forResource: "Qwen3-1.7B-4bit", withExtension: nil) else {
            throw ModelError.missingWeights
        }
        return try await loadModelContainer(from: dir, using: BundleTokenizerLoader())
    }

    /// Loads the shared base model only. Does not load adapters or naive instances.
    func loadBase() async {
        guard mode == .sharedBase else { return }
        guard state == .idle, container == nil, naiveContainers.isEmpty else { return }
        state = .loading
        errorText = nil
        log.info("Base model load started")
        let sp = DemoSignposts.begin("BaseLoad")
        let clock = ContinuousClock()
        let start = clock.now
        let sampler = PhasePeakSampler()
        sampler.start()
        do {
            let loaded = try await Self.makeContainer()
            let elapsed = clock.now - start
            loadDuration = elapsed
            lastLoadPhasePeakMB = await sampler.stop()
            container = loaded
            rebuildSession(for: nil)
            DemoSignposts.end("BaseLoad", sp)
            log.info("Base model load completed: \(secondsString(elapsed), privacy: .public) s")
            state = .ready
        } catch {
            _ = await sampler.stop()
            DemoSignposts.end("BaseLoad", sp)
            fail("Load failed: \(error.localizedDescription)")
        }
    }

    /// Naive prepare: ready with zero models loaded. The first task load creates that instance only.
    func prepareNaive() {
        guard mode == .naive else { return }
        guard state == .idle, container == nil, naiveContainers.isEmpty else { return }
        errorText = nil
        state = .ready
        log.info("Naive prepare completed with zero models loaded")
    }

    /// Mode changes drop any resident runtime first so naive and shared never overlap.
    func switchMode(to newMode: Mode) {
        guard newMode != mode, !isBusy else { return }
        if state != .idle || hasResidentModel {
            reset()
        }
        mode = newMode
    }

    func reset() {
        runTask?.cancel()
        runTask = nil
        for task in naiveContainers.keys {
            log.info("Naive instance \(task.rawValue, privacy: .public) released")
        }
        container = nil
        session = nil
        adapters.removeAll()
        naiveContainers.removeAll()
        naiveSessions.removeAll()
        residentInstances.removeAll()
        activeAdapter = nil
        loadDuration = nil
        lastSwitch = nil
        lastMetrics = nil
        lastLoadPhasePeakMB = 0
        output = ""
        errorText = nil
        state = .idle
        DemoSignposts.event("Reset")
        log.info("Runtime reset")
    }

    /// Rebuilds chat sessions without unloading models or changing the active adapter.
    func clearContext() {
        guard !isBusy else { return }
        rebuildSessions()
        output = ""
        DemoSignposts.event("ClearContext")
        log.info("Context cleared; resident models kept")
    }

    /// No busy guard: perform() calls this while state is .running.
    private func rebuildSessions() {
        session = nil
        naiveSessions.removeAll()
        if container != nil {
            rebuildSession(for: activeAdapter)
        }
        for (task, loaded) in naiveContainers {
            naiveSessions[task] = makeSession(loaded, instructions: task.instructions)
        }
    }

    // MARK: - Running

    func run(task: AITask, input: String) {
        run(tasks: [task], input: input)
    }

    func runSequence(input: String) {
        run(tasks: [.summarize, .classify, .extract], input: input)
    }

    func runRepeated(input: String) {
        run(tasks: [.summarize, .summarize, .summarize], input: input)
    }

    func run(tasks: [AITask], input: String) {
        guard state == .ready, runTask == nil, !tasks.isEmpty else { return }
        state = .running
        runTask = Task { [weak self] in
            guard let self else { return }
            for task in tasks {
                if Task.isCancelled { break }
                await self.perform(task: task, input: input)
                if self.errorText != nil || Task.isCancelled { break }
            }
            self.runTask = nil
            if self.state == .running {
                self.state = .ready
            }
        }
    }

    func cancel() { runTask?.cancel() }

    private struct PreparedRun {
        var session: ChatSession
        var switchTime: Duration?
        var loadTime: Duration?
    }

    private func perform(task aITask: AITask, input: String) async {
        rebuildSessions()
        output = ""
        errorText = nil
        let clock = ContinuousClock()
        let sampler = PhasePeakSampler()
        sampler.start()
        do {
            let memoryBefore = readMemory()
            let prepared = try await prepareRun(for: aITask, clock: clock)
            // Inference clock starts after adapter switch or naive load.
            let inferenceStart = clock.now
            let sp = DemoSignposts.begin("Inference")
            var firstToken: Duration?
            var text = ""
            var inputTokens: Int?
            var outputTokens: Int?
            do {
                for try await event in prepared.session.streamDetails(to: input) {
                    if Task.isCancelled { break }
                    if let chunk = event.chunk {
                        if firstToken == nil {
                            firstToken = clock.now - inferenceStart
                            DemoSignposts.event("FirstToken")
                            log.info("First token: \(secondsString(firstToken!), privacy: .public) s")
                        }
                        text += chunk
                        output = text
                    } else if let info = event.info {
                        inputTokens = info.totalPromptTokenCount
                        outputTokens = info.generationTokenCount
                    }
                }
            } catch {
                DemoSignposts.end("Inference", sp)
                throw error
            }
            if Task.isCancelled {
                DemoSignposts.end("Inference", sp)
                _ = await sampler.stop()
                fail("Cancelled")
                return
            }
            DemoSignposts.end("Inference", sp)
            let total = clock.now - inferenceStart
            let phasePeakMB = await sampler.stop()
            lastMetrics = RunMetrics(
                task: aITask,
                adapterSwitch: prepared.switchTime,
                modelLoad: prepared.loadTime,
                firstToken: firstToken,
                total: total,
                memoryBefore: memoryBefore,
                memoryAfter: readMemory(),
                phasePeakMB: phasePeakMB,
                inputTokens: inputTokens,
                outputTokens: outputTokens)
            log.info("Inference complete: \(secondsString(total), privacy: .public) s")
        } catch {
            _ = await sampler.stop()
            fail("Run failed: \(error.localizedDescription)")
        }
    }

    /// Switch or naive-load before the inference clock starts. Naive loads only the requested task.
    private func prepareRun(for task: AITask, clock: ContinuousClock) async throws -> PreparedRun {
        switch mode {
        case .sharedBase:
            let switchTime = try await activateAdapter(for: task)
            guard let session else { throw ModelError.missingWeights }
            return PreparedRun(session: session, switchTime: switchTime, loadTime: nil)
        case .naive:
            if container != nil {
                throw ModelError.sharedModelStillResident
            }
            var loadTime: Duration?
            if naiveContainers[task] == nil {
                log.info("Naive instance for \(task.rawValue, privacy: .public) became resident")
                let sp = DemoSignposts.begin("NaiveLoad")
                let t0 = clock.now
                let loaded: ModelContainer
                do {
                    loaded = try await Self.makeContainer()
                } catch {
                    DemoSignposts.end("NaiveLoad", sp)
                    throw error
                }
                loadTime = clock.now - t0
                loadDuration = loadTime
                DemoSignposts.end("NaiveLoad", sp)
                naiveContainers[task] = loaded
                naiveSessions[task] = makeSession(loaded, instructions: task.instructions)
                residentInstances.insert(task)
            }
            guard let chat = naiveSessions[task] else { throw ModelError.missingWeights }
            return PreparedRun(session: chat, switchTime: nil, loadTime: loadTime)
        }
    }

    // MARK: - Adapter switching (shared mode)

    /// Unloads the current adapter, loads the one for `task`, rebuilds the session.
    /// Returns the measured switch duration, or nil when no change was needed.
    private func activateAdapter(for task: AITask) async throws -> Duration? {
        guard let container else { throw ModelError.missingWeights }
        if activeAdapter == task { return nil }

        if adapters[task] == nil {
            guard let root = Bundle.main.url(forResource: "adapters", withExtension: nil) else {
                throw ModelError.missingAdapters
            }
            adapters[task] = try LoRAContainer.from(directory: root.appending(component: task.rawValue))
            log.info("Adapter \(task.rawValue, privacy: .public) parsed")
        }
        guard let adapter = adapters[task] else { throw ModelError.missingAdapters }

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
            throw error
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
        session = makeSession(
            container,
            instructions: task?.instructions ?? "You are a concise assistant. /no_think")
    }

    private func makeSession(_ modelContainer: ModelContainer, instructions: String) -> ChatSession {
        ChatSession(
            modelContainer,
            instructions: instructions,
            generateParameters: Self.genParams)
    }

    private func fail(_ message: String) {
        errorText = message
        lastMetrics = nil
        // A loaded runtime must stay Reset-able. Idle is only for an empty process.
        state = hasResidentModel ? .ready : .idle
        log.error("ModelManager: \(message, privacy: .public)")
    }
}

private func secondsString(_ d: Duration) -> String {
    let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    return String(format: "%.2f", s)
}
