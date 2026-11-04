import Combine

@MainActor
final class EditorSession: ObservableObject {
    @Published var isDirty = false
    private var saveAction: (() -> Void)?

    func activate(save: @escaping () -> Void) { saveAction = save }

    func save() -> Bool {
        guard let saveAction else { return false }
        saveAction()
        return true
    }

    func clear() {
        saveAction = nil
        isDirty = false
    }
}
