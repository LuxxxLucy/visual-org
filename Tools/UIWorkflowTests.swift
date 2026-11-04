import AppKit
import ApplicationServices
import OrgCore

@MainActor
enum UIWorkflowTests {
    private struct Placement: Decodable, Equatable {
        let x: Double
        let y: Double
        let expanded: Bool
    }

    private struct Camera: Decodable, Equatable {
        let x: Double
        let y: Double
        let zoom: Double
    }

    private struct Layout: Decodable {
        let cards: [String: Placement]
        let openCards: Set<String>
        let camera: Camera
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static var savedCards: [String: Placement]?
    private static var savedSource: Data?

    static func run(app: NSRunningApplication, documentURL: URL, layoutURL: URL) throws {
        app.activate(options: [])
        let workflow = try Workflow(app: app, documentURL: documentURL, layoutURL: layoutURL)
        try workflow.disclosureAndMenu()
        try workflow.zoomButtons()
        try workflow.wheelZoom()
        try workflow.saveCommand()
        try workflow.hierarchy()
        try workflow.textEditing()
        try workflow.movementAndScroll()
        try workflow.externalReload()
        try workflow.archiveAndDelete()
        try workflow.openChild()
        try workflow.fitAll()
        workflow.settle()
        savedCards = try workflow.layout().cards
        savedSource = try Data(contentsOf: documentURL)
        print("PASS UI workflow completed through native input")
    }

    static func verifyRestored(app: NSRunningApplication, documentURL: URL, layoutURL: URL) throws {
        app.activate(options: [])
        let workflow = try Workflow(app: app, documentURL: documentURL, layoutURL: layoutURL)
        try workflow.ui.wait(message: "Reopened app did not restore the root title") {
            guard let card = workflow.ui.find(id: "card:org:e2e-root"),
                  let title = workflow.ui.find(id: "title", in: card) else { return false }
            return workflow.ui.value(title, kAXValueAttribute) == "Root disk"
        }
        _ = try workflow.card("org:e2e-child")
        let restored = try workflow.layout()
        try workflow.expect(restored.cards == savedCards, "Restart changed saved card positions or expansion")
        try workflow.expect(restored.openCards.contains("org:e2e-child"), "Restart lost the opened child card")
        try workflow.expect(try Data(contentsOf: documentURL) == savedSource, "Restart changed Org source bytes")
        print("PASS UI restart restored child card, edited source, and saved layout")
    }

    @MainActor
    private final class Workflow {
        let ui: UIAutomation
        let documentURL: URL
        let layoutURL: URL
        let root = "org:e2e-root"
        let child = "org:e2e-child"
        let grandchild = "org:e2e-grandchild"
        let other = "org:e2e-other"

        init(app: NSRunningApplication, documentURL: URL, layoutURL: URL) throws {
            ui = try UIAutomation(pid: app.processIdentifier)
            self.documentURL = documentURL
            self.layoutURL = layoutURL
        }

        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure(message: message) }
        }

        func source() throws -> String { try String(contentsOf: documentURL, encoding: .utf8) }

        func layout() throws -> Layout { try JSONDecoder().decode(Layout.self, from: Data(contentsOf: layoutURL)) }

        func heading(_ id: String) throws -> OrgHeading {
            guard let heading = try OrgDocument(text: source()).roots.lazy.compactMap({ $0.find(id) }).first else {
                throw Failure(message: "The Org file is missing heading \(id)")
            }
            return heading
        }

        func card(_ id: String) throws -> AXUIElement { try ui.require(id: "card:" + id) }

        func control(_ id: String, card headingID: String) throws -> AXUIElement {
            try ui.require(id: id, in: card(headingID))
        }

        func settle(_ seconds: TimeInterval = 0.4) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

        func fitAll() throws {
            try ui.click(ui.require(id: "canvas-view"))
            try ui.click(ui.require(role: kAXMenuItemRole, text: "Fit all"))
            var stableCamera: Camera?
            var stableSince = Date()
            try ui.wait(message: "Fit all did not settle and save its camera") {
                let layout = try self.layout()
                guard let placement = layout.cards[self.root] else { return false }
                let frame = try self.ui.frame(of: self.card(self.root))
                let canvas = try self.ui.frame(of: self.ui.require(id: "canvas"))
                let camera = layout.camera
                let matches = abs(frame.minX - (canvas.minX + camera.x + placement.x * camera.zoom)) < 1 &&
                    abs(frame.minY - (canvas.minY + camera.y + placement.y * camera.zoom)) < 1 &&
                    abs(frame.width - 320 * camera.zoom) < 1
                if !matches || stableCamera != camera {
                    stableCamera = camera
                    stableSince = Date()
                    return false
                }
                return Date().timeIntervalSince(stableSince) >= 0.3
            }
        }

        func menu(_ title: String, card id: String) throws {
            try ui.click(control("menu", card: id))
            try ui.click(ui.require(role: kAXMenuItemRole, text: title))
            settle()
        }

        func replaceText(_ text: String, in element: AXUIElement, commit: Bool = true) throws {
            try ui.click(element)
            try ui.key(0, flags: .maskCommand)
            try ui.type(text)
            if commit { try ui.key(36) }
        }

        func waitForSource(_ expected: String, _ message: String) throws {
            try ui.wait(message: message) { try self.source() == expected }
        }

        func disclosureAndMenu() throws {
            let before = try source()
            try expect(try layout().cards[root]?.expanded == false, "Fixture root must start collapsed")
            let collapsed = try ui.frame(of: card(root))
            try ui.click(control("toggle", card: root))
            try ui.wait(message: "Root disclosure did not expand its card") {
                try self.layout().cards[self.root]?.expanded == true && self.ui.frame(of: self.card(self.root)).height > collapsed.height
            }
            let notes = try control("notes:0", card: root)
            try expect(ui.value(notes, kAXValueAttribute).contains("Root notes."), "Expanded card lost its body text")
            try expect(try ui.frame(of: notes).height > 20, "Body text has no measured multiline layout")
            try ui.click(control("menu", card: root))
            for title in ["Edit…", "Archive…", "Delete…"] { _ = try ui.require(role: kAXMenuItemRole, text: title) }
            try ui.key(53)
            try ui.wait(message: "Card menu did not close") { self.ui.find(role: kAXMenuItemRole, text: "Edit…") == nil }
            let frame = try ui.frame(of: card(root))
            try ui.click(at: CGPoint(x: frame.minX + 6, y: frame.minY + 6), right: true)
            for title in ["Edit…", "Archive…", "Delete…"] { _ = try ui.require(role: kAXMenuItemRole, text: title) }
            try ui.key(53)
            try ui.wait(message: "Context menu did not close") { self.ui.find(role: kAXMenuItemRole, text: "Edit…") == nil }
            try expect(try source() == before, "Disclosure or menu changed Org text")
            print("PASS UI left disclosure, ellipsis menu, and matching context menu")
        }

        func openChild() throws {
            try fitAll()
            try ui.click(control("child:" + child + ":text", card: root))
            try ui.wait(message: "Child text click did not open a child card") { try self.layout().openCards.contains(self.child) }
            _ = try card(child)
        }

        func wheelZoom() throws {
            let before = try layout().camera
            let canvas = try ui.frame(of: ui.require(id: "canvas"))
            let frame = try ui.frame(of: card(root))
            let point = CGPoint(x: frame.midX, y: frame.minY + 6)
            let x = point.x - canvas.minX
            let y = point.y - canvas.minY
            let worldX = (x - before.x) / before.zoom
            let worldY = (y - before.y) / before.zoom
            for (delta, expected) in [(Int32(100), before.zoom * 1.1), (Int32(-100), before.zoom * 1.1 * 0.9)] {
                try ui.scroll(at: point, dy: delta, flags: .maskCommand)
                try ui.wait(message: "Wheel zoom did not apply the capped proportional step") {
                    try abs(self.layout().camera.zoom - expected) < 0.000001
                }
                let after = try layout().camera
                try expect(abs((x - after.x) / after.zoom - worldX) < 0.001 &&
                           abs((y - after.y) / after.zoom - worldY) < 0.001, "Wheel zoom moved the pointer anchor")
            }
            print("PASS UI capped wheel zoom and pointer anchoring")
        }

        func zoomButtons() throws {
            try ui.click(ui.require(role: kAXButtonRole, text: "Zoom In"))
            try ui.wait(message: "Zoom In did not select 200 percent") { try self.layout().camera.zoom == 2 }
            try ui.click(ui.require(role: kAXButtonRole, text: "Zoom Out"))
            try ui.wait(message: "Zoom Out did not select 100 percent") { try self.layout().camera.zoom == 1 }
            print("PASS UI stepped zoom controls")
        }

        func saveCommand() throws {
            let before = try source()
            try replaceText("Root saved", in: control("title", card: root), commit: false)
            try ui.key(1, flags: .maskCommand)
            let saved = before.replacingOccurrences(of: "* TODO Root\n", with: "* TODO Root saved\n")
            try waitForSource(saved, "Command-S did not save the inline title")
            _ = try ui.require(id: "save-status")
            try replaceText("Root local draft", in: control("title", card: root), commit: false)
            let external = saved.replacingOccurrences(of: "* TODO Root saved\n", with: "* TODO Root external save\n")
            try Data(external.utf8).write(to: documentURL, options: .atomic)
            try ui.key(1, flags: .maskCommand)
            var sheet = try ui.require(role: kAXSheetRole)
            try ui.click(ui.require(role: kAXButtonRole, text: "Keep Editing", in: sheet))
            try expect(try source() == external, "Save conflict overwrote external bytes")
            try expect(try ui.value(control("title", card: root), kAXValueAttribute) == "Root local draft", "Keep Editing lost the local draft")
            try ui.key(1, flags: .maskCommand)
            sheet = try ui.require(role: kAXSheetRole)
            try ui.click(ui.require(role: kAXButtonRole, text: "Discard and Reload", in: sheet))
            try ui.wait(message: "Save conflict reload did not display the external title") {
                try self.ui.value(self.control("title", card: self.root), kAXValueAttribute) == "Root external save"
            }
            try replaceText("Root", in: control("title", card: root), commit: false)
            try ui.key(1, flags: .maskCommand)
            try waitForSource(before, "Saving the restored title changed unrelated source")
            print("PASS UI Command-S, Saved status, conflict cancellation, and confirmed reload")
        }

        func hierarchy() throws {
            let before = try source()
            try openChild()
            try ui.click(control("child:" + grandchild + ":toggle", card: child))
            try ui.wait(message: "Grandchild disclosure did not open a card") { try self.layout().openCards.contains(self.grandchild) }
            try fitAll()
            _ = try card(grandchild)
            let placements = try layout().cards
            try menu("Close card", card: child)
            try ui.wait(message: "Closing child left descendant cards visible") {
                self.ui.find(id: "card:" + self.child) == nil && self.ui.find(id: "card:" + self.grandchild) == nil
            }
            try expect(try layout().openCards.contains(grandchild), "Closing parent discarded descendant open state")
            try openChild()
            try fitAll()
            _ = try card(grandchild)
            try expect(try layout().cards[child] == placements[child] && layout().cards[grandchild] == placements[grandchild],
                       "Reopening hierarchy changed saved positions")
            try menu("Close card", card: grandchild)
            try menu("Close card", card: child)
            try fitAll()
            try expect(try source() == before, "Opening or closing child cards changed Org text")
            print("PASS UI child and grandchild opening, closing, and saved reopening")
        }

        func textEditing() throws {
            let before = try source()
            try replaceText("Root edited", in: control("title", card: root))
            let renamed = before.replacingOccurrences(of: "* TODO Root\n", with: "* TODO Root edited\n")
            try waitForSource(renamed, "Enter did not save only the edited root title")
            try replaceText("Discard this title", in: control("title", card: root), commit: false)
            try ui.key(53)
            settle()
            try expect(try source() == renamed, "Escape saved a cancelled title edit")
            let checkbox = try heading(root).checkboxes[0]
            try replaceText("Edited check item", in: control("checkbox:\(checkbox.id):text", card: root))
            let edited = renamed.replacingOccurrences(of: "- [ ] Check item", with: "- [ ] Edited check item")
            try waitForSource(edited, "Checkbox Enter changed source outside its text")
            try replaceText("Discard checkbox edit", in: control("checkbox:\(checkbox.id):text", card: root), commit: false)
            try ui.key(53)
            settle()
            try expect(try source() == edited, "Escape saved a cancelled checkbox edit")
            try ui.click(control("checkbox:\(checkbox.id):toggle", card: root))
            let checked = edited.replacingOccurrences(of: "- [ ] Edited check item", with: "- [X] Edited check item")
            try waitForSource(checked, "Checkbox toggle did not save its Org state")
            try ui.key(15, flags: .maskCommand)
            try ui.wait(message: "File Reload did not restore the edited title") {
                try self.ui.value(self.control("title", card: self.root), kAXValueAttribute) == "Root edited"
            }
            try expect(try heading(root).checkboxes[0].state == "X", "Reload lost checkbox state")
            print("PASS UI title and checkbox Enter, Escape, toggle, and File Reload")
        }

        func movementAndScroll() throws {
            try fitAll()
            var before = try layout()
            var frame = try ui.frame(of: card(root))
            let start = CGPoint(x: frame.minX + 6, y: frame.minY + 6)
            try ui.drag(from: start, to: CGPoint(x: start.x + 35, y: start.y + 25))
            try ui.wait(message: "Dragging blank card space did not save its position") {
                try self.layout().cards[self.root] != before.cards[self.root]
            }
            let dragged = try layout()
            let sourceBeforeUndo = try source()
            try ui.click(ui.require(id: "arrange"))
            try ui.click(ui.require(role: kAXMenuItemRole, text: "Undo layout change"))
            try ui.wait(message: "Layout Undo did not restore persisted card positions") {
                try self.layout().cards == before.cards
            }
            try ui.click(ui.require(id: "arrange"))
            try ui.click(ui.require(role: kAXMenuItemRole, text: "Redo layout change"))
            try ui.wait(message: "Layout Redo did not restore the persisted drag result") {
                try self.layout().cards == dragged.cards
            }
            try expect(try layout().camera == dragged.camera, "Layout undo or redo changed the camera")
            try expect(try source() == sourceBeforeUndo, "Layout undo or redo changed Org source")
            print("PASS UI layout Undo and Redo restored persisted drag positions")
            before = try layout()
            frame = try ui.frame(of: card(root)).union(ui.frame(of: card(other)))
            try ui.drag(from: CGPoint(x: frame.minX - 10, y: frame.minY - 10),
                        to: CGPoint(x: frame.maxX + 10, y: frame.maxY + 10))
            let rootFrame = try ui.frame(of: card(root))
            let groupedStart = CGPoint(x: rootFrame.minX + 6, y: rootFrame.minY + 6)
            try ui.drag(from: groupedStart, to: CGPoint(x: groupedStart.x + 25, y: groupedStart.y + 20))
            try ui.wait(message: "Rectangle selection did not move both cards") {
                let after = try self.layout()
                guard let first = after.cards[self.root], let second = after.cards[self.other],
                      let oldFirst = before.cards[self.root], let oldSecond = before.cards[self.other] else { return false }
                return first.x != oldFirst.x && second.x != oldSecond.x &&
                    abs((first.x - oldFirst.x) - (second.x - oldSecond.x)) < 0.1 &&
                    abs((first.y - oldFirst.y) - (second.y - oldSecond.y)) < 0.1
            }
            try ui.click(control("toggle", card: other))
            try ui.wait(message: "Long checklist did not expand") { try self.layout().cards[self.other]?.expanded == true }
            try fitAll()
            let scroll = try control("body-scroll", card: other)
            let item = try heading(other).checkboxes[3]
            let text = try control("checkbox:\(item.id):text", card: other)
            let oldY = try ui.frame(of: text).minY
            let oldCardY = try ui.frame(of: card(other)).minY
            let scrollFrame = try ui.frame(of: scroll)
            let camera = try layout().camera
            try ui.scroll(at: CGPoint(x: scrollFrame.midX, y: scrollFrame.midY), dy: -80)
            try ui.wait(message: "Scrolling inside the checklist did not move its contents") {
                try self.ui.frame(of: text).minY - self.ui.frame(of: self.card(self.other)).minY < oldY - oldCardY - 5
            }
            settle()
            let afterScroll = try layout().camera
            try expect(afterScroll == camera, "Checklist scrolling moved the canvas camera: \(camera) -> \(afterScroll), scroll frame \(scrollFrame)")
            print("PASS UI card drag, rectangle group movement, and nested checklist scrolling")
        }

        func externalReload() throws {
            let clean = try source().replacingOccurrences(of: "* TODO Root edited\n", with: "* TODO Root external\n")
            try Data(clean.utf8).write(to: documentURL, options: .atomic)
            try ui.wait(timeout: 7, message: "Clean external title change did not reload automatically") {
                try self.ui.value(self.control("title", card: self.root), kAXValueAttribute) == "Root external"
            }
            try replaceText("Unsaved local title", in: control("title", card: root), commit: false)
            try expect(try source() == clean, "Typing wrote the draft before Enter")
            let external = clean.replacingOccurrences(of: "* TODO Root external\n", with: "* TODO Root disk\n")
            try Data(external.utf8).write(to: documentURL, options: .atomic)
            let reload = try ui.require(id: "reload", timeout: 7)
            try expect(try source() == external, "Dirty draft overwrote external file changes")
            try ui.click(reload)
            try ui.click(ui.require(role: kAXButtonRole, text: "Discard and reload"))
            try ui.wait(message: "Confirmed reload did not replace the dirty inline draft") {
                try self.ui.value(self.control("title", card: self.root), kAXValueAttribute) == "Root disk"
            }
            try expect(try source() == external, "Discard and reload changed external source bytes")
            print("PASS UI clean auto reload and dirty draft reload confirmation")
        }

        func archiveAndDelete() throws {
            try fitAll()
            try menu("Archive…", card: "org:e2e-archive")
            try ui.click(ui.require(role: kAXButtonRole, text: "Move to archive"))
            try ui.wait(message: "Archive confirmation did not remove the heading") {
                try !self.source().contains(":ID: e2e-archive")
            }
            let archive = URL(fileURLWithPath: documentURL.path + "_archive")
            try expect(try String(contentsOf: archive, encoding: .utf8).contains("Archive marker."), "Archive lost the subtree body")
            try fitAll()
            try menu("Delete…", card: "org:e2e-delete")
            try ui.click(ui.require(role: kAXButtonRole, text: "Delete"))
            try ui.wait(message: "Delete confirmation did not remove the heading") {
                try !self.source().contains(":ID: e2e-delete")
            }
            try expect(try source().contains(":ID: e2e-root") && source().contains(":ID: e2e-other"), "Archive/delete removed unrelated roots")
            print("PASS UI archive and delete confirmations with source and archive verification")
        }
    }
}
