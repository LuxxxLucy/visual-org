import AppKit
import SwiftUI
import Combine

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let controller: WorkspaceController

    init(controller: WorkspaceController) {
        self.controller = controller
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1380, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Open an Org File"
        window.minSize = CGSize(width: 980, height: 650)
        window.isReleasedWhenClosed = false
        window.contentView = WorkspaceRootView(controller: controller)
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("visual-org.workspace")
        controller.attach(to: window)
    }

    required init?(coder: NSCoder) { nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard DraftProtection.permitClosing(hasUnsavedEdits: controller.hasDraft) else { return false }
        controller.saveCamera()
        return true
    }
}

@MainActor
private final class WorkspaceRootView: NSView {
    let controller: WorkspaceController
    let canvas: NativeCanvasView
    let toolbar: NSHostingView<WorkspaceToolbar>
    let status: NSHostingView<WorkspaceStatusBar>
    let inspector: NSHostingView<WorkspaceInspector>
    let zoom: NSHostingView<WorkspaceZoomControls>
    private var subscription: AnyCancellable?

    override var isFlipped: Bool { true }

    init(controller: WorkspaceController) {
        self.controller = controller
        canvas = NativeCanvasView(controller: controller)
        toolbar = NSHostingView(rootView: WorkspaceToolbar(controller: controller))
        status = NSHostingView(rootView: WorkspaceStatusBar(controller: controller))
        inspector = NSHostingView(rootView: WorkspaceInspector(controller: controller))
        zoom = NSHostingView(rootView: WorkspaceZoomControls(controller: controller))
        super.init(frame: .zero)
        for view in [canvas, toolbar, status, inspector, zoom] { addSubview(view) }
        toolbar.safeAreaRegions = []; status.safeAreaRegions = []; inspector.safeAreaRegions = []; zoom.safeAreaRegions = []
        subscription = controller.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        window?.title = controller.store.url?.lastPathComponent ?? "Open an Org File"
        window?.representedURL = controller.store.url
        let inspectorWidth = controller.inspector && controller.focused != nil ? 320.0 : 0
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 56)
        status.frame.size.width = bounds.width
        let statusHeight = max(36, status.fittingSize.height)
        status.frame = CGRect(x: 0, y: 56, width: bounds.width, height: statusHeight)
        let top = 56 + statusHeight
        canvas.frame = CGRect(x: 0, y: top, width: max(1, bounds.width - inspectorWidth), height: max(1, bounds.height - top))
        inspector.isHidden = inspectorWidth == 0
        inspector.frame = CGRect(x: bounds.width - inspectorWidth, y: top, width: inspectorWidth, height: max(1, bounds.height - top))
        let size = zoom.fittingSize
        zoom.frame = CGRect(x: canvas.frame.maxX - size.width - 12, y: bounds.height - size.height - 12, width: size.width, height: size.height)
    }
}
