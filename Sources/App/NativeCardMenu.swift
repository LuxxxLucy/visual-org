import AppKit
import OrgCore

@MainActor
enum NativeCardMenu {
    static func make(heading: OrgHeading, controller: WorkspaceController, window: NSWindow? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(guardedItem("Edit…", heading: heading, controller: controller) { controller.edit(heading.id) })
        if !heading.body.isEmpty {
            menu.addItem(guardedItem("Read notes…", heading: heading, controller: controller) {
                NativeNotesSheet.present(title: heading.title, text: heading.body,
                                         documentURL: controller.store.url, from: window)
            })
        }
        let create = submenu("Create", in: menu)
        create.addItem(guardedItem("New project…", heading: heading, controller: controller) { controller.requestNewHeading() })
        create.addItem(guardedItem("Child heading…", heading: heading, controller: controller) { controller.requestNewHeading(parent: heading) })
        menu.addItem(.separator())
        let states = submenu("State", in: menu)
        add("None", to: states, checked: heading.state == nil, heading: heading, controller: controller) { controller.setState(heading.id, nil) }
        let active = controller.store.states.filter { !controller.store.doneStates.contains($0) }
        let done = controller.store.states.filter { controller.store.doneStates.contains($0) }
        for group in [active, done] where !group.isEmpty {
            states.addItem(.separator())
            for state in group {
                add(state, to: states, checked: heading.state == state, heading: heading, controller: controller) { controller.setState(heading.id, state) }
            }
        }
        let priorities = submenu("Priority", in: menu)
        add("None", to: priorities, checked: heading.priority == nil, heading: heading, controller: controller) { controller.setPriority(heading.id, nil) }
        priorities.addItem(.separator())
        for (priority, title) in [("A", "A, High"), ("B", "B, Medium"), ("C", "C, Low")] {
            add(title, to: priorities, checked: heading.priority == priority, heading: heading, controller: controller) { controller.setPriority(heading.id, priority) }
        }
        menu.addItem(guardedItem("Schedule…", heading: heading, controller: controller) { controller.requestPlanning(heading.id, kind: .scheduled) })
        menu.addItem(guardedItem("Deadline…", heading: heading, controller: controller) { controller.requestPlanning(heading.id, kind: .deadline) })
        if controller.parentID(for: heading.id) != nil {
            let opened = controller.isCardOpen(heading.id)
            menu.addItem(guardedItem(opened ? "Close card" : "Open card", heading: heading, controller: controller) {
                if opened { controller.closeCard(heading.id) }
                else { controller.openCard(heading.id) }
            })
        }
        if controller.isCardOpen(heading.id) {
            menu.addItem(.separator())
            let placement = controller.placement(for: heading.id)
            menu.addItem(guardedItem(placement.expanded ? "Collapse" : "Expand", heading: heading, controller: controller) {
                controller.setExpanded(heading.id, !placement.expanded)
            })
            let colors = submenu("Color", in: menu)
            for (color, title) in ["White", "Red", "Green", "Blue", "Yellow"].enumerated() {
                add(title, to: colors, checked: placement.color == color, heading: heading, controller: controller) { controller.setColor(heading.id, color) }
            }
        }
        if let index = controller.store.roots.firstIndex(where: { $0.id == heading.id }) {
            let earlier = guardedItem("Move earlier in file", heading: heading, controller: controller) { controller.moveRoot(heading.id, offset: -1) }
            earlier.isEnabled = index > 0
            menu.addItem(earlier)
            let later = guardedItem("Move later in file", heading: heading, controller: controller) { controller.moveRoot(heading.id, offset: 1) }
            later.isEnabled = index + 1 < controller.store.roots.count
            menu.addItem(later)
        }
        appendLinks(heading.title + "\n" + heading.body, to: menu, documentURL: controller.store.url)
        menu.addItem(.separator())
        menu.addItem(guardedItem("Archive…", heading: heading, controller: controller) { controller.requestArchive(heading) })
        menu.addItem(guardedItem("Delete…", heading: heading, controller: controller) { controller.requestDelete(heading) })
        menu.autoenablesItems = false
        return menu
    }

    static func checkbox(heading: OrgHeading, item: OrgCheckbox, controller: WorkspaceController,
                         window: NSWindow? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(guardedItem("Edit checkbox…", heading: heading, controller: controller) { controller.editCheckbox(heading.id, item: item) })
        if !item.details.isEmpty {
            menu.addItem(guardedItem("Read details…", heading: heading, controller: controller) {
                NativeNotesSheet.present(title: item.title, text: item.details,
                                         documentURL: controller.store.url, from: window)
            })
        }
        menu.addItem(guardedItem(item.state.uppercased() == "X" ? "Mark incomplete" : "Mark complete", heading: heading, controller: controller) {
            controller.toggleCheckbox(heading.id, item: item)
        })
        appendLinks(item.title + "\n" + item.details, to: menu, documentURL: controller.store.url)
        return menu
    }

    static func notes(heading: OrgHeading, controller: WorkspaceController, window: NSWindow? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(guardedItem("Read notes…", heading: heading, controller: controller) {
            NativeNotesSheet.present(title: heading.title, text: heading.body,
                                     documentURL: controller.store.url, from: window)
        })
        menu.addItem(guardedItem("Edit notes…", heading: heading, controller: controller) { controller.edit(heading.id) })
        appendLinks(heading.body, to: menu, documentURL: controller.store.url)
        return menu
    }

    private static func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    private static func add(_ title: String, to menu: NSMenu, checked: Bool,
                            heading: OrgHeading, controller: WorkspaceController, action: @escaping () -> Void) {
        let item = guardedItem(title, heading: heading, controller: controller, action: action)
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    private static func guardedItem(_ title: String, heading: OrgHeading, controller: WorkspaceController,
                                    action: @escaping () -> Void) -> ActionMenuItem {
        let documentID = controller.documentID
        return ActionMenuItem(title) {
            guard controller.documentID == documentID, controller.heading(heading.id) == heading else {
                controller.report("The item changed. Open its menu again.")
                return
            }
            action()
        }
    }

    private static func appendLinks(_ text: String, to menu: NSMenu, documentURL: URL?) {
        let links = OrgLinks.links(text, documentURL: documentURL)
        guard !links.isEmpty else { return }
        menu.addItem(.separator())
        for link in links {
            menu.addItem(ActionMenuItem("Open \"\(link.label)\"") { NSWorkspace.shared.open(link.url) })
        }
    }
}
