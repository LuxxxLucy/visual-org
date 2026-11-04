import OrgCore
import SwiftUI

struct InspectorView: View {
    let heading: OrgHeading
    @ObservedObject var controller: WorkspaceController
    @ObservedObject private var creationDrafts: CreationDrafts
    @ObservedObject private var draft: DetailsDraft

    init(heading: OrgHeading, controller: WorkspaceController) {
        self.heading = heading
        self.controller = controller
        creationDrafts = controller.creationDrafts
        draft = controller.detailsDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Title", text: $draft.title, axis: .vertical).font(.system(size: 18, weight: .semibold)).textFieldStyle(.plain)
                .accessibilityIdentifier("inspector-title")
            Picker("State", selection: Binding(get: { heading.state ?? "" }, set: {
                guard controller.commitInlineEdit(), let id = controller.focused?.id else { return }
                controller.setState(id, $0.isEmpty ? nil : $0)
            })) {
                Text("None").tag("")
                ForEach(controller.store.states, id: \.self) { Text($0).tag($0) }
            }
            Picker("Priority", selection: Binding(get: { heading.priority ?? "" }, set: {
                guard controller.commitInlineEdit(), let id = controller.focused?.id else { return }
                controller.setPriority(id, $0.isEmpty ? nil : $0)
            })) {
                Text("None").tag("")
                Text("A · High").tag("A")
                Text("B · Medium").tag("B")
                Text("C · Low").tag("C")
            }
            HStack {
                Button("Schedule…") { controller.requestPlanning(.scheduled) }
                Button("Deadline…") { controller.requestPlanning(.deadline) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes").font(.system(size: 12, weight: .medium))
                TextEditor(text: $draft.body).font(.system(size: 13)).scrollContentBackground(.hidden).padding(8)
                    .accessibilityIdentifier("inspector-body")
                    .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).frame(minHeight: 160)
            }
            Button("Save details", action: controller.saveDetails).buttonStyle(.borderedProminent).tint(ink)
                .accessibilityIdentifier("inspector-save")
            Button("Discard edits", action: controller.discardDetails).disabled(!draft.isDirty)
                .accessibilityIdentifier("inspector-discard")
            Divider()
            Text("Add an item").font(.system(size: 12, weight: .medium))
            TextField("New item title", text: creationDrafts.heading(heading.id))
                .onSubmit(addChild)
            Button("Add item", action: addChild)
                .disabled(creationDrafts.heading(heading.id).wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
        }.padding(24).background(.white)
    }

    private func addChild() {
        guard controller.commitInlineEdit(), let id = controller.focused?.id else { return }
        controller.addChild(id)
    }
}
