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

    private var container: ModelContainer?
    private var session: ChatSession?
    private var task: Task<Void, Never>?

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
