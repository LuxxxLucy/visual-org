import SwiftUI
import WorkspaceCore
import OrgCore

@MainActor
final class CreationDrafts: ObservableObject {
    @Published private var state = CreationDraftState()

    var hasUnsavedEdits: Bool { state.hasUnsavedEdits }

    func checkboxText(_ headingID: String) -> String { state[checkbox: headingID] }

    func updateCheckboxText(_ headingID: String, _ text: String) {
        state[checkbox: headingID] = text
    }

    func heading(_ headingID: String) -> Binding<String> {
        Binding(get: { self.state[heading: headingID] }, set: {
            self.state[heading: headingID] = $0
        })
    }

    func clear() {
        state.clear()
    }

    func apply(to document: inout OrgDocument) throws { try state.apply(to: &document) }

    func remap(_ mapping: [String: String], removing removedIDs: Set<String> = []) throws {
        try state.remap(mapping, removing: removedIDs)
    }
}
