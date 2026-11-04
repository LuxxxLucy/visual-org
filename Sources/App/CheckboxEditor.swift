import OrgCore
import SwiftUI

struct CheckboxEditor: View {
    let item: OrgCheckbox
    @ObservedObject var session: EditorSession
    let save: (String) throws -> Void
    let dismiss: () -> Void
    @State private var title = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit item").font(.system(size: 18, weight: .semibold))
            TextField("Item text", text: Binding(get: { title }, set: {
                title = $0
                session.isDirty = title != item.title
            }))
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(commit)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 460).foregroundStyle(ink).background(.white)
        .environment(\.colorScheme, .light)
        .interactiveDismissDisabled(session.isDirty)
        .onAppear {
            title = item.title
            focused = true
            session.activate(save: commit)
        }
    }

    private func commit() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try save(title); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
