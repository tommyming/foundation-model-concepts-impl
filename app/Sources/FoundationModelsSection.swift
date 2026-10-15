// On-device Foundation Models reference. iOS 26 system model only.
// Does not load MLX weights and does not share the MLX memory display.

import FoundationModels
import SwiftUI

struct FoundationModelsSection: View {
    let input: String

    var body: some View {
        Section("On-device Foundation Models") {
            Text("System model only. This section does not load MLX and is not part of the MLX memory chart.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if #available(iOS 26, *) {
                SystemModelExtractionView(input: input)
            } else {
                Text("Requires iOS 26.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@available(iOS 26, *)
private struct SystemModelExtractionView: View {
    let input: String
    @State private var status = "—"
    @State private var output = ""
    @State private var running = false

    var body: some View {
        Group {
            LabeledContent("Availability", value: status)
            Button("Extract with System Model") {
                Task { await extract() }
            }
            .disabled(running)
            if !output.isEmpty {
                Text(output)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
        }
        .onAppear(perform: refreshAvailability)
    }

    private func refreshAvailability() {
        status = String(describing: SystemLanguageModel.default.availability)
    }

    private func extract() async {
        running = true
        defer { running = false }
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            refreshAvailability()
            output = status
            return
        }
        let session = LanguageModelSession(
            model: model,
            instructions: "You extract structured data from notes. Be concise.")
        do {
            let response = try await session.respond(to: input, generating: NoteExtraction.self)
            let note = response.content
            output = """
            people: \(note.people.joined(separator: ", "))
            organizations: \(note.organizations.joined(separator: ", "))
            locations: \(note.locations.joined(separator: ", "))
            actionItems: \(note.actionItems.joined(separator: ", "))
            """
        } catch {
            output = error.localizedDescription
        }
    }

}

@available(iOS 26, *)
@Generable
private struct NoteExtraction {
    @Guide(description: "People mentioned in the note")
    var people: [String]
    @Guide(description: "Organizations mentioned in the note")
    var organizations: [String]
    @Guide(description: "Locations mentioned in the note")
    var locations: [String]
    @Guide(description: "Action items from the note")
    var actionItems: [String]
}
