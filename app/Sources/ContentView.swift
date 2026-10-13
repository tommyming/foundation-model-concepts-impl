// Phase 1 UI: load button, prompt, generate, streamed output, timings.

import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var prompt =
        "Summarize this note in two sentences: Sara wants the Q3 forecast slides before Friday. Ping Acme Corp about the renewal, and book the lab for the antenna test."

    var body: some View {
        NavigationStack {
            Form {
                Section("Base model") {
                    HStack {
                        Text(model.state.rawValue.capitalized)
                        Spacer()
                        if let d = model.loadDuration {
                            Text("loaded in \(format(d))")
                        }
                    }
                    if model.state == .idle {
                        Button("Load from bundle") { Task { await model.load() } }
                    }
                }

                Section("Input") {
                    TextEditor(text: $prompt).frame(minHeight: 100)
                    Button("Generate") { model.generate(prompt: prompt) }
                        .disabled(model.state != .ready)
                    if model.state == .running {
                        Button("Cancel", role: .destructive) { model.cancel() }
                    }
                }

                Section("Adapter") {
                    Toggle("Classify adapter", isOn: Binding(
                        get: { model.adapterActive },
                        set: { _ in Task { await model.toggleAdapter() } }))
                        .disabled(model.state != .ready)
                    LabeledContent("Last switch",
                        value: model.adapterSwitchDuration.map(format) ?? "—")
                }

                Section("Last run") {
                    LabeledContent("Time to first token",
                        value: model.firstTokenLatency.map(format) ?? "—")
                    LabeledContent("Total", value: model.totalLatency.map(format) ?? "—")
                }

                Section("Output") {
                    ScrollView {
                        Text(model.output).font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 180)
                }

                if let err = model.errorText {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
            .navigationTitle("AI Memory Lab")
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
