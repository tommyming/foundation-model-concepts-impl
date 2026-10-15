// Phase 3+ UI: mode picker, task buttons, adapter state, benchmarks, output.

import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var prompt =
        "Sara wants the Q3 forecast slides before Friday. Acme Corp asked about the renewal by end of month. The review session is at the Singapore lab. Check the shared folder for details."
    @State private var benchIterations = 1
    @State private var benchProgress: String?
    @State private var benchURL: URL?
    @State private var benchRunning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Runtime") {
                    Picker("Mode", selection: Binding(
                        get: { model.mode },
                        set: { newMode in
                            guard !benchRunning else { return }
                            model.switchMode(to: newMode)
                        }
                    )) {
                        Text("Naive").tag(AppModel.Mode.naive)
                        Text("Shared Base + Adapters").tag(AppModel.Mode.sharedBase)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isBusy || benchRunning)

                    HStack {
                        Text(model.state.rawValue.capitalized)
                        Spacer()
                        if let d = model.loadDuration {
                            Text("loaded in \(format(d))").foregroundStyle(.secondary)
                        }
                    }
                    if model.state == .idle {
                        if model.mode == .sharedBase {
                            Button("Preload") { Task { await model.loadBase() } }
                        } else {
                            Button("Prepare") { model.prepareNaive() }
                        }
                    }
                    if model.state != .idle {
                        Button("Unload / Reset", role: .destructive) { model.reset() }
                            .disabled(model.isBusy || benchRunning)
                    }
                }

                if model.mode == .sharedBase {
                    Section("Active state") {
                        LabeledContent("Base model", value: model.baseLoaded ? "Loaded" : "—")
                        LabeledContent("Adapter", value: model.activeAdapter?.rawValue ?? "none")
                        LabeledContent("Last switch",
                            value: model.lastSwitch.map(format) ?? "—")
                    }
                } else {
                    Section("Resident instances") {
                        ForEach(AITask.allCases, id: \.self) { t in
                            LabeledContent(t.rawValue.capitalized,
                                value: model.residentInstances.contains(t) ? "resident" : "not loaded")
                        }
                    }
                }

                Section("Input") {
                    TextEditor(text: $prompt).frame(minHeight: 100)
                    HStack {
                        ForEach(AITask.allCases, id: \.self) { t in
                            Button(t.rawValue.capitalized) { model.run(task: t, input: prompt) }
                                .buttonStyle(.bordered)
                                .disabled(model.state != .ready || benchRunning)
                        }
                    }
                    Button("Run Sequence") { model.runSequence(input: prompt) }
                        .disabled(model.state != .ready || benchRunning)
                    Button("Run Repeated") { model.runRepeated(input: prompt) }
                        .disabled(model.state != .ready || benchRunning)
                    Button("Clear Context") { model.clearContext() }
                        .disabled(model.state != .ready || benchRunning)
                    if model.state == .running {
                        Button("Cancel", role: .destructive) { model.cancel() }
                    }
                }

                Section("Last run") {
                    LabeledContent("Time to first token",
                        value: model.lastMetrics?.firstToken.map(format) ?? "—")
                    LabeledContent("Total", value: model.lastMetrics.map { format($0.total) } ?? "—")
                    LabeledContent("Footprint", value: model.lastMetrics.map {
                        String(format: "%.0f MB", $0.memoryAfter.physicalFootprintMB)
                    } ?? "—")
                    LabeledContent("Phase peak", value: model.lastMetrics.map {
                        String(format: "%.0f MB", $0.phasePeakMB)
                    } ?? "—")
                    LabeledContent("Lifetime peak", value: model.lastMetrics.map {
                        String(format: "%.0f MB", $0.memoryAfter.peakPhysicalFootprintMB)
                    } ?? "—")
                }

                Section("Benchmarks") {
                    Stepper("Measured iterations: \(benchIterations)", value: $benchIterations, in: 1...5)
                        .disabled(benchRunning)
                    Button("Run Scenarios") { runBenchmarks() }
                        .disabled(model.state != .ready || benchRunning)
                    if let p = benchProgress { Text(p).foregroundStyle(.secondary) }
                    if let url = benchURL {
                        ShareLink("Last result: \(url.lastPathComponent)", item: url)
                    }
                }

                Section("Output") {
                    ScrollView {
                        Text(model.output).font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }.frame(minHeight: 160)
                }

                FoundationModelsSection(input: prompt)

                if let err = model.errorText {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
            .navigationTitle("AI Memory Lab")
        }
    }

    private func runBenchmarks() {
        benchRunning = true
        benchProgress = "starting"
        Task {
            do {
                benchURL = try await Benchmark.runAll(
                    model: model, input: prompt, measured: benchIterations) {
                    benchProgress = $0
                }
                benchProgress = "done"
            } catch {
                benchProgress = "failed: \(error.localizedDescription)"
            }
            benchRunning = false
        }
    }

    private func format(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
        return String(format: "%.0f ms", ms)
    }
}

@main
struct AIMemoryLabApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
