// Phase 1 runtime: one bundled base model, one prompt, streamed output,
// lifecycle logged with timings.

import Foundation
import MLXLLM
import MLXLMCommon
import os

private let log = Logger(subsystem: "com.iosconf.aimemorylab", category: "ModelManager")

// "/no_think" is Qwen3's documented soft switch for thinking mode.
// ponytail: verify enable_thinking=false through the Swift template in Phase 2;
// remove the suffix if the hard switch lands.
private let instructions = "You are a concise assistant. /no_think"

@MainActor
final class AppModel: ObservableObject {
    enum State: String {
        case idle
        case loading
        case ready
        case running
    }

    @Published var state: State = .idle
    @Published var output = ""
    @Published var errorText: String?
    @Published var loadDuration: Duration?
    @Published var firstTokenLatency: Duration?
    @Published var totalLatency: Duration?
    @Published var adapterActive = false
    @Published var adapterSwitchDuration: Duration?

    private var container: ModelContainer?
    private var session: ChatSession?
    private var task: Task<Void, Never>?
    private var adapter: LoRAContainer?

    var isBusy: Bool { state == .loading || state == .running }

    func load() async {
        guard state == .idle else { return }
        state = .loading
        errorText = nil

        guard let dir = Bundle.main.url(forResource: "Qwen3-1.7B-4bit", withExtension: nil) else {
            fail("Model directory missing from bundle. Run scripts/fetch-model.sh, then rebuild.")
            return
        }

        log.info("Base model load started")
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let loaded = try await loadModelContainer(
                from: dir, using: BundleTokenizerLoader())
            let elapsed = clock.now - start
            container = loaded
            session = ChatSession(
                loaded,
                instructions: instructions,
                generateParameters: GenerateParameters(temperature: 0))
            loadDuration = elapsed
            state = .ready
            log.info("Base model load completed: \(secondsString(elapsed), privacy: .public) s")
        } catch {
            fail("Load failed: \(error.localizedDescription)")
        }
    }

    func generate(prompt: String) {
        guard state == .ready, let session, task == nil else { return }
        state = .running
        output = ""
        errorText = nil

        let clock = ContinuousClock()
        let start = clock.now
        var firstToken: Duration?
        var text = ""

        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in session.streamResponse(to: prompt) {
                    if Task.isCancelled { break }
                    if firstToken == nil {
                        firstToken = clock.now - start
                        log.info("First token: \(secondsString(firstToken!), privacy: .public) s")
                    }
                    text += chunk
                    self.output = text
                }
                let total = clock.now - start
                self.firstTokenLatency = firstToken
                self.totalLatency = total
                log.info("Inference complete: \(secondsString(total), privacy: .public) s")
                self.state = .ready
            } catch {
                self.fail("Generation failed: \(error.localizedDescription)")
            }
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Adapter hot-swap (Phase 2)

    /// Applies or removes the classify adapter on the live model.
    /// Unload-before-load and a fresh ChatSession (new KV cache) after every swap.
    func toggleAdapter() async {
        guard let container else { return }
        guard let adaptersRoot = Bundle.main.url(forResource: "adapters", withExtension: nil) else {
            fail("adapters/ missing from bundle.")
            return
        }

        let applying = !adapterActive
        if applying, adapter == nil {
            do {
                adapter = try LoRAContainer.from(
                    directory: adaptersRoot.appending(component: "classify"))
                log.info("Adapter classify parsed: \(self.adapter!.configuration.numLayers) layers")
            } catch {
                fail("Adapter parse failed: \(error.localizedDescription)")
                return
            }
        }
        guard let adapter else { return }

        let clock = ContinuousClock()
        let start = clock.now
        final class ErrorBox { var error: Error? }
        let box = ErrorBox()
        await container.update { context in
            do {
                if applying {
                    try adapter.load(into: context.model)
                } else {
                    adapter.unload(from: context.model)
                }
            } catch {
                box.error = error
            }
        }
        if let error = box.error {
            fail("Adapter switch failed: \(error.localizedDescription)")
            return
        }
        let elapsed = clock.now - start
        adapterSwitchDuration = elapsed
        adapterActive = applying
        rebuildSession()
        log.info("Adapter \(applying ? "classify active" : "none active", privacy: .public): switch \(secondsString(elapsed), privacy: .public) s")
    }

    /// Fresh session so the KV cache never spans an adapter boundary.
    private func rebuildSession() {
        guard let container else { return }
        session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(temperature: 0))
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
