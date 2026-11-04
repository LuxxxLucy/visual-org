import AppKit
import OrgCore
import WorkspaceCore

@main
struct CardCoverageCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure("Provide one Org file path.") }
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let original = try Data(contentsOf: url)
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("visual-org-card-coverage-\(UUID().uuidString).org")
        try original.write(to: snapshot, options: .atomic)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        let document = OrgDocument(text: String(decoding: try Data(contentsOf: snapshot), as: UTF8.self))
        let controller = WorkspaceController(store: OrgSession(), layout: CanvasLayout())
        var cards = 0
        var blocks = 0
        var checkboxes = 0
        var references = 0
        var scrollChecks = 0
        var report = ["level\tcheckboxes\ttext_blocks\tchildren\ttitle"]
        var ids = Set<String>()
        func require(_ condition: Bool, _ detail: String) throws {
            guard condition else { throw Failure(detail) }
        }
        func check(_ heading: OrgHeading) throws {
            try require(ids.insert(heading.id).inserted, "Duplicate card ID: \(heading.title)")
            let card = NativeCardView(id: heading.id, controller: controller)
            func show(_ expanded: Bool) {
                card.update(ProjectCard(heading: heading, color: 0, expanded: expanded, selectedID: nil, searchQuery: "", revision: 0))
                RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            }
            show(false)
            try require(card.headerHeight == CardGeometry.headerHeight, "Inconsistent header height")
            let origin = card.frame.origin
            try require(card.frame.width == 320, "Inconsistent card width")
            try require(card.frame.height == card.headerHeight, "Collapsed height: \(heading.title)")
            show(true)
            try require(card.frame.height == card.headerHeight + card.bodyHeight, "Expanded height: \(heading.title)")
            try require(card.bodyHeight == 420 && card.frame.width == 320 && card.frame.origin == origin, "Expansion changed width, origin, or body height")
            try require(!card.scroll.isHidden, "Hidden body: \(heading.title)")
            try require(card.header.editor.accessibilityLabel() == heading.title, "Header source: \(heading.title)")
            let expectedTitle = NativeOrgText.attributed(heading.title, font: .systemFont(ofSize: 19), color: .black).string
            try require(card.header.editor.stringValue == expectedTitle, "Header display: \(heading.title)")
            var expectedKeys = [CardRowKey]()
            var reconstructed = [String]()
            let lines = heading.body.components(separatedBy: "\n")
            var textCount = 0
            for element in heading.bodyElements {
                switch element {
                case let .text(line, source):
                    let key = CardRowKey(headingID: heading.id, kind: .notes(line))
                    expectedKeys.append(key)
                    guard let view = card.rows[key]?.view as? NativeCardNotes,
                          let manager = view.layoutManager, let container = view.textContainer else {
                        throw Failure("Missing native text system: \(heading.title):\(line)")
                    }
                    try require(view.string == NativeOrgText.notes(source, documentURL: nil).string, "Body text: \(heading.title):\(line)")
                    manager.ensureLayout(for: container)
                    try require(NSMaxRange(manager.glyphRange(for: container)) == manager.numberOfGlyphs, "Unlaid glyphs: \(heading.title):\(line)")
                    try require(manager.usedRect(for: container).maxY <= view.bounds.height + 1, "Clipped text height: \(heading.title):\(line)")
                    reconstructed += source.components(separatedBy: "\n")
                    blocks += 1
                    textCount += 1
                case let .checkbox(item):
                    let key = CardRowKey(headingID: heading.id, kind: .checkbox(item.id))
                    expectedKeys.append(key)
                    guard let row = card.rows[key]?.view as? NativeCardRow else { throw Failure("Missing checkbox: \(heading.title):\(item.id)") }
                    try require(row.editor.accessibilityLabel() == item.title, "Checkbox source: \(heading.title):\(item.id)")
                    try require(row.editor.stringValue == NativeOrgText.attributed(item.title, font: .systemFont(ofSize: 15), color: .black).string, "Checkbox display: \(heading.title):\(item.id)")
                    let symbol = item.state == "-" ? "minus.square" : item.state.uppercased() == "X" ? "checkmark.square.fill" : "square"
                    try require(row.leading.image?.tiffRepresentation == NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle checkbox")?.tiffRepresentation, "Checkbox state: \(heading.title):\(item.id)")
                    try require(row.editor.frame.height >= row.editor.height(for: row.editor.frame.width), "Checkbox text height: \(heading.title):\(item.id)")
                    reconstructed.append(lines[item.id])
                    checkboxes += 1
                }
            }
            try require(reconstructed.joined(separator: "\n") == heading.body, "Unrepresented source: \(heading.title)")
            for child in heading.children {
                let key = CardRowKey(headingID: child.id, kind: .heading)
                expectedKeys.append(key)
                guard let row = card.rows[key]?.view as? NativeCardRow else { throw Failure("Missing child reference: \(child.title)") }
                try require(row.editor.accessibilityLabel() == child.title, "Child reference source: \(child.title)")
                try require(row.editor.stringValue == NativeOrgText.attributed(child.title, font: .systemFont(ofSize: 15), color: .black).string, "Child reference display: \(child.title)")
                try require(row.target.key.headingID == child.id, "Wrong child target: \(child.title)")
                references += 1
            }
            expectedKeys.append(CardRowKey(headingID: heading.id, kind: .entry))
            try require(card.ordered.map(\.0) == expectedKeys, "Body order: \(heading.title)")
            try require(Set(card.rows.keys) == Set(expectedKeys), "Missing or extra rows: \(heading.title)")
            var bottom: CGFloat = 0
            for key in expectedKeys {
                guard let view = card.rows[key]?.view else { throw Failure("Missing body row") }
                try require(view.frame.minY >= bottom && view.frame.height > 0, "Overlapping row: \(heading.title)")
                try require(view.frame.minX >= 0 && view.frame.maxX <= card.document.frame.width, "Clipped row width: \(heading.title)")
                bottom = view.frame.maxY
                for y in [view.frame.minY, max(view.frame.minY, view.frame.maxY - 1)] {
                    card.document.scrollToVisible(CGRect(x: view.frame.minX, y: y, width: 1, height: 1))
                    try require(card.scroll.documentVisibleRect.intersects(CGRect(x: view.frame.minX, y: y, width: 1, height: 1)), "Unreachable row: \(heading.title)")
                    scrollChecks += 1
                }
            }
            try require(bottom <= card.document.frame.height, "Clipped body: \(heading.title)")
            if let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds) {
                card.cacheDisplay(in: card.bounds, to: bitmap)
                try require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "Empty render: \(heading.title)")
            } else { throw Failure("Cannot render card: \(heading.title)") }
            show(false)
            try require(card.frame.height == card.headerHeight, "Collapse failed: \(heading.title)")
            show(true)
            try require(!card.scroll.isHidden && card.ordered.map(\.0) == expectedKeys, "Reopen lost rows: \(heading.title)")
            report.append("\(heading.level)\t\(heading.checkboxes.count)\t\(textCount)\t\(heading.children.count)\t\(heading.title)")
            cards += 1
            for child in heading.children { try check(child) }
        }
        for root in document.roots { try check(root) }
        try require(try Data(contentsOf: snapshot) == original, "Snapshot changed")
        try require(try Data(contentsOf: url) == original, "Source changed during verification")
        try report.joined(separator: "\n").write(toFile: "build/card-coverage.tsv", atomically: true, encoding: .utf8)
        print("PASS \(document.roots.count) root cards, \(cards - document.roots.count) subcards, \(checkboxes) checkboxes, \(blocks) text blocks, \(references) child references, \(scrollChecks) scroll positions")
    }
}
