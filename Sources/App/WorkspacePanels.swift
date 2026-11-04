import SwiftUI
import WorkspaceCore

struct WorkspaceToolbar: View {
    @ObservedObject var controller: WorkspaceController

    var body: some View {
        HStack(spacing: 18) {
            Button(action: controller.chooseFile) { Label("Open", systemImage: "folder") }.help("Open Org File (⌘O)")
            Spacer(minLength: 15)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: Binding(get: { controller.query }, set: controller.setQuery)).textFieldStyle(.plain)
                    .accessibilityIdentifier("Search").onSubmit(controller.nextSearchResult)
                if !controller.query.isEmpty {
                    Text("\(controller.visible.isEmpty ? 0 : controller.searchIndex + 1)/\(controller.visible.count)")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    Button(action: controller.nextSearchResult) { Label("Next Match", systemImage: "chevron.down") }.labelStyle(.iconOnly).help("Next Match")
                    Button { controller.setQuery("") } label: { Label("Clear Search", systemImage: "xmark.circle.fill") }
                        .labelStyle(.iconOnly).help("Clear Search")
                }
            }.padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
                .frame(maxWidth: 560)
            Spacer(minLength: 15)
            Button { controller.requestNewHeading() } label: { Label("New Project", systemImage: "plus") }.help("New Project (⌘N)").disabled(controller.store.url == nil)
            Toggle(isOn: Binding(get: { controller.inspector }, set: { _ in controller.toggleInspector() })) {
                Label("Details", systemImage: "sidebar.right")
            }.toggleStyle(.button).help(controller.inspector ? "Hide Details" : "Show Details")
                .accessibilityIdentifier("inspector-toggle")
        }.buttonStyle(.bordered).controlSize(.regular).padding(.horizontal, 16).frame(height: 56)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct WorkspaceStatusBar: View {
    @ObservedObject var controller: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(controller.store.url?.lastPathComponent ?? "Open an Org File")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .help(controller.store.url?.path ?? "Open an Org File")
                Text("\(controller.store.roots.count) projects").font(.system(size: 12)).foregroundStyle(.secondary)
                if controller.saved {
                    Label("Saved", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("save-status")
                }
                if !controller.store.preamble.isEmpty {
                    Button("Document text…", action: controller.showDocumentText)
                }
                Spacer()
                Button(action: controller.addGroup) { Label("Add Area", systemImage: "rectangle.dashed") }.help("Add Area")
                    .disabled(controller.store.url == nil)
                Menu {
                    Button("Collapse all") { controller.setAllExpanded(false) }
                    Button("Expand all") { controller.setAllExpanded(true) }
                    Divider()
                    Button("Arrange by file order") { controller.arrange(byPriority: false) }
                    Button("Arrange by priority") { controller.arrange(byPriority: true) }
                    Divider()
                    Button("Undo layout change", action: controller.undoLayout).disabled(!controller.layout.canUndo)
                    Button("Redo layout change", action: controller.redoLayout).disabled(!controller.layout.canRedo)
                } label: { Label("Arrange", systemImage: "square.grid.2x2") }.help("Arrange").accessibilityIdentifier("arrange")
                    .disabled(controller.store.url == nil)
            }.buttonStyle(.borderless).padding(.horizontal, 16).frame(height: 36)
            if controller.store.changedOnDisk && !controller.ignoredExternalChange {
                HStack {
                    Label("The Org file changed outside visual-org.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Keep Editing") { controller.ignoredExternalChange = true }
                        .accessibilityIdentifier("keep-editing")
                    Button("Reload…", action: controller.requestReload)
                        .accessibilityIdentifier("reload")
                }.font(.system(size: 13)).padding(10).background(Color.orange.opacity(0.12))
            }
            if let message = controller.message {
                HStack {
                    Label(message, systemImage: "exclamationmark.circle").font(.system(size: 13)).textSelection(.enabled)
                    Spacer()
                    Button { controller.message = nil } label: { Label("Dismiss Message", systemImage: "xmark") }
                        .labelStyle(.iconOnly).help("Dismiss Message")
                }.padding(10).background(Color.red.opacity(0.12))
            }
        }.background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
    }
}

struct WorkspaceInspector: View {
    @ObservedObject var controller: WorkspaceController

    var body: some View {
        if controller.inspector, let heading = controller.focused {
            InspectorView(heading: heading, controller: controller)
                .environment(\.colorScheme, .light)
        }
    }
}

struct WorkspaceZoomControls: View {
    @ObservedObject var controller: WorkspaceController
    @ObservedObject var viewport: CanvasViewport

    init(controller: WorkspaceController) {
        self.controller = controller
        viewport = controller.viewport
    }

    var body: some View {
        HStack(spacing: 9) {
            Button { controller.stepZoom(.out) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass").frame(width: 32, height: 28) }
                .help("Zoom Out (⌘−)").disabled(viewport.value.zoom <= CanvasCameraOptions.zoomRange.lowerBound)
            Text("\(Int((viewport.value.zoom * 100).rounded()))%").monospacedDigit().frame(width: 44)
                .accessibilityLabel("Zoom").accessibilityValue("\(Int((viewport.value.zoom * 100).rounded())) percent")
            Button { controller.stepZoom(.in) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass").frame(width: 32, height: 28) }
                .help("Zoom In (⌘+)").disabled(viewport.value.zoom >= CanvasCameraOptions.zoomRange.upperBound)
            Divider().frame(height: 20)
            Menu {
                Button("100%") { controller.setZoom(1) }
                Button("Fit all", action: controller.fitAll)
                Button("Focus selected") { if let selected = controller.selected { controller.focus(selected) } }.disabled(controller.selected == nil)
            } label: { Label("Canvas View", systemImage: "viewfinder").frame(minWidth: 32, minHeight: 28) }.help("Canvas View").accessibilityIdentifier("canvas-view")
        }.font(.system(size: 13)).labelStyle(.iconOnly).buttonStyle(.bordered).padding(8)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}

struct NewHeadingPanel: View {
    @ObservedObject var controller: WorkspaceController
    let isChild: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isChild ? "New child heading" : "New project").font(.system(size: 18, weight: .semibold))
            TextField("Title", text: $controller.newTitle).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(controller.addHeading)
            if let message = controller.message { Text(message).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: controller.dismissEditor).keyboardShortcut(.cancelAction)
                Button("Add", action: controller.addHeading).keyboardShortcut(.defaultAction)
                    .disabled(controller.newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460).background(.white).foregroundStyle(ink).environment(\.colorScheme, .light)
            .onAppear {
                focused = true
                controller.editorSession.activate(save: controller.addHeading)
            }
    }
}
