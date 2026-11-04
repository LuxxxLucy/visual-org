import AppKit
import Combine
import OrgCore

@main
@MainActor
final class VisualOrgApp: NSObject, NSApplicationDelegate {
    private var workspace: WorkspaceController!
    private var windowController: WorkspaceWindowController!
    private var subscription: AnyCancellable?
    private var menuStates: [String] = []
    private var pendingFile: String?

    static func main() {
        let application = NSApplication.shared
        let delegate = VisualOrgApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        workspace = WorkspaceController(store: OrgSession(), layout: CanvasLayout())
        windowController = WorkspaceWindowController(controller: workspace)
        makeMenus()
        subscription = workspace.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self, self.menuStates != self.workspace.store.states else { return }
            self.makeMenus()
        }
        windowController.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let pendingFile { workspace.open(URL(fileURLWithPath: pendingFile)); self.pendingFile = nil }
        else { workspace.initialOpen() }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first {
            if let workspace { workspace.open(URL(fileURLWithPath: path)) }
            else { pendingFile = path }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard DraftProtection.permitClosing(hasUnsavedEdits: workspace?.hasDraft ?? false) else { return .terminateCancel }
        workspace?.saveCamera()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeMenus() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item)
            return menu
        }
        let app = submenu("visual-org")
        app.addItem(ActionMenuItem("About visual-org") { NSApplication.shared.orderFrontStandardAboutPanel(nil) })
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide visual-org", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(ActionMenuItem("Quit visual-org", key: "q") { NSApplication.shared.terminate(nil) })
        let file = submenu("File")
        file.addItem(ActionMenuItem("Open Org File…", key: "o") { [weak self] in self?.workspace.chooseFile() })
        file.addItem(ActionMenuItem("Document text…") { [weak self] in self?.workspace.showDocumentText() })
        file.addItem(ActionMenuItem("New project…", key: "n") { [weak self] in self?.workspace.requestNewHeading() })
        file.addItem(.separator())
        file.addItem(ActionMenuItem("Save", key: "s") { [weak self] in self?.workspace.saveDocument() })
        file.addItem(ActionMenuItem("Reload from Disk…", key: "r") { [weak self] in self?.workspace.requestReload() })
        file.addItem(ActionMenuItem("Open Archive") { [weak self] in self?.workspace.openArchive() })
        file.addItem(.separator())
        file.addItem(ActionMenuItem("Close", key: "w") { [weak self] in self?.windowController.window?.performClose(nil) })
        let edit = submenu("Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            if action == "cut:" { edit.addItem(.separator()) }
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        let view = submenu("View")
        view.addItem(ActionMenuItem("Zoom In", key: "+") { [weak self] in self?.workspace.stepZoom(.in) })
        view.addItem(ActionMenuItem("Zoom Out", key: "-") { [weak self] in self?.workspace.stepZoom(.out) })
        view.addItem(ActionMenuItem("Fit all") { [weak self] in self?.workspace.fitAll() })
        view.addItem(ActionMenuItem("100%", key: "0") { [weak self] in self?.workspace.setZoom(1) })
        view.addItem(.separator())
        view.addItem(ActionMenuItem("Show details") { [weak self] in self?.workspace.toggleInspector() })
        let org = submenu("Org")
        let stateMenu = NSMenu(title: "Set State")
        let stateItem = NSMenuItem(title: "Set State", action: nil, keyEquivalent: "")
        stateItem.submenu = stateMenu; org.addItem(stateItem)
        stateMenu.addItem(ActionMenuItem("None") { [weak self] in self?.workspace.setState(nil) })
        menuStates = workspace.store.states
        for state in menuStates {
            stateMenu.addItem(ActionMenuItem(state) { [weak self] in self?.workspace.setState(state) })
        }
        org.addItem(ActionMenuItem("Schedule Selected Item…") { [weak self] in self?.workspace.requestPlanning(.scheduled) })
        org.addItem(ActionMenuItem("Set Deadline…") { [weak self] in self?.workspace.requestPlanning(.deadline) })
        org.addItem(ActionMenuItem("Archive Selected Item…", key: "A") { [weak self] in self?.workspace.requestArchive() })
        let window = submenu("Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
