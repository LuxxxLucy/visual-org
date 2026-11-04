import AppKit

@MainActor
enum DraftProtection {
    static func permitClosing(hasUnsavedEdits: Bool) -> Bool {
        guard hasUnsavedEdits else { return true }
        let alert = NSAlert()
        alert.messageText = "Save or discard your edits first."
        alert.informativeText = "Return to the editor to save or discard your changes."
        alert.addButton(withTitle: "Keep Editing")
        alert.runModal()
        return false
    }
}
