import AppKit
import OrgCore
import WorkspaceCore

extension NativeCardView {
    var ownsTextFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if header.editor.currentEditor() === responder { return true }
        return rows.values.contains { element in
            let editor = (element.view as? NativeCardRow)?.editor ?? (element.view as? NativeCardEditor)
            return editor?.currentEditor() === responder || element.view === responder
        }
    }

    func synchronizeEditing() {
        header.editor.synchronizeSession()
        for element in rows.values {
            (element.view as? NativeCardRow)?.editor.synchronizeSession()
        }
    }

    func resetCreationDrafts() {
        for element in rows.values {
            guard let editor = element.view as? NativeCardEditor else { continue }
            editor.resetText(controller.creationDrafts.checkboxText(element.target.key.headingID))
        }
    }

    func remapIdentifiers(_ mapping: [String: String], removing removed: Set<String>) {
        rootTarget.key = rootTarget.key.remapped(mapping)
        var renamed: [CardRowKey: NativeCardElement] = [:]
        for (key, element) in rows {
            guard !removed.contains(key.headingID) else {
                element.view.removeFromSuperview()
                continue
            }
            element.target.key = key.remapped(mapping)
            renamed[element.target.key] = element
        }
        rows = renamed
        ordered = ordered.compactMap { key, inset in
            removed.contains(key.headingID) ? nil : (key.remapped(mapping), inset)
        }
    }

    func actionMenu(for target: CardRowTarget) -> NSMenu? {
        guard controller.commitInlineEdit(), let heading = controller.heading(target.key.headingID) else { return nil }
        switch target.key.kind {
        case .heading:
            return NativeCardMenu.make(heading: heading, controller: controller, window: window)
        case .notes:
            return NativeCardMenu.notes(heading: heading, controller: controller, window: window)
        case .checkbox(let line):
            guard let item = heading.checkboxes.first(where: { $0.id == line }) else { return nil }
            return NativeCardMenu.checkbox(heading: heading, item: item, controller: controller, window: window)
        case .entry:
            return nil
        }
    }

    func toggle(_ target: CardRowTarget) {
        guard controller.commitInlineEdit() else { return }
        switch target.key.kind {
        case .heading:
            if target === rootTarget {
                guard let snapshot else { return }
                controller.setExpanded(id, !snapshot.expanded)
            } else {
                controller.openCard(target.key.headingID)
            }
        case .checkbox(let line):
            guard let item = controller.heading(target.key.headingID)?.checkboxes.first(where: { $0.id == line }) else { return }
            controller.toggleCheckbox(target.key.headingID, item: item)
        default:
            break
        }
    }

    func rebuildBody(_ heading: OrgHeading) {
        var next: [(CardRowKey, CGFloat)] = []
        appendBody(heading, into: &next)
        let keep = Set(next.map(\.0))
        for key in Array(rows.keys) where !keep.contains(key) {
            rows.removeValue(forKey: key)?.view.removeFromSuperview()
        }
        ordered = next
        arrange()
        guard let snapshot, !snapshot.searchQuery.isEmpty else { return }
        let target = ordered.compactMap { rows[$0.0]?.view }.first { view in
            let text: String
            if let row = view as? NativeCardRow { text = row.editor.stringValue }
            else if let note = view as? NativeCardNotes { text = note.string }
            else { return false }
            return text.localizedCaseInsensitiveContains(snapshot.searchQuery)
        }
        if let target { document.scrollToVisible(target.frame) }
    }

    private func appendBody(_ heading: OrgHeading, into output: inout [(CardRowKey, CGFloat)]) {
        for element in heading.bodyElements {
            switch element {
            case .text(let line, let source):
                let key = CardRowKey(headingID: heading.id, kind: .notes(line))
                let note = row(key) { NativeCardNotes(target: $0, card: self) }
                note.setAccessibilityIdentifier("notes:\(line)")
                note.textStorage?.setAttributedString(NativeOrgText.notes(source, documentURL: controller.store.url, color: foreground))
                output.append((key, 0))
            case .checkbox(let item):
                let key = CardRowKey(headingID: heading.id, kind: .checkbox(item.id))
                let view = row(key) { NativeCardRow(target: $0, card: self) }
                configureCheckbox(view, item: item)
                output.append((key, CGFloat(min(item.indent, 12)) * 4))
            }
        }
        for child in heading.children {
            let key = CardRowKey(headingID: child.id, kind: .heading)
            let view = row(key) { NativeCardRow(target: $0, card: self) }
            configureHeading(view, heading: child)
            output.append((key, 0))
        }
        let key = CardRowKey(headingID: heading.id, kind: .entry)
        let entry = row(key) { NativeCardEditor(target: $0, card: self) }
        entry.setAccessibilityIdentifier("entry")
        entry.font = .systemFont(ofSize: 15)
        entry.textColor = foreground
        entry.placeholderAttributedString = NSAttributedString(string: "Add a checklist item", attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: foreground.withAlphaComponent(0.85)
        ])
        entry.setAccessibilityLabel("Add checklist item")
        let text = controller.creationDrafts.checkboxText(heading.id)
        entry.configure(source: text, display: NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: foreground]))
        output.append((key, 32))
    }

    private func row<T: NSView>(_ key: CardRowKey, create: (CardRowTarget) -> T) -> T {
        if let existing = rows[key]?.view as? T { return existing }
        let target = CardRowTarget(key)
        let view = create(target)
        rows[key] = NativeCardElement(target: target, view: view)
        document.addSubview(view)
        return view
    }

    func configureHeading(_ row: NativeCardRow, heading: OrgHeading) {
        guard let snapshot else { return }
        let root = row.target === rootTarget
        let prefix = root ? "" : "child:\(heading.id):"
        row.setAccessibilityIdentifier(root ? "header" : "child:\(heading.id)")
        row.editor.setAccessibilityIdentifier(root ? "title" : prefix + "text")
        row.leading.setAccessibilityIdentifier(prefix + "toggle")
        row.more.setAccessibilityIdentifier(prefix + "menu")
        row.done.setAccessibilityIdentifier(prefix + "state")
        row.editor.isEditable = root
        row.editor.isSelectable = root
        row.editor.maximumNumberOfLines = root ? 2 : 0
        row.editor.lineBreakMode = root ? .byTruncatingTail : .byWordWrapping
        row.editor.toolTip = root ? heading.title : nil
        row.done.isHidden = root
        let completed = heading.state.map { controller.store.doneStates.contains($0) } ?? false
        row.done.image = NSImage(systemSymbolName: completed ? "checkmark.circle.fill" : "circle", accessibilityDescription: "Toggle TODO")
        row.done.toolTip = completed ? "Mark as Incomplete" : "Mark as Complete"
        row.done.setAccessibilityLabel(row.done.toolTip)
        configureSelection(row)
        row.leading.image = NSImage(systemSymbolName: root ? "chevron.down" : "chevron.right", accessibilityDescription: root ? "Toggle items" : "Open child card")
        row.leading.showsShadow = root && snapshot.expanded
        row.leading.setAccessibilityLabel(root ? (snapshot.expanded ? "Collapse items" : "Expand items") : "Open child card")
        row.leading.toolTip = root ? (snapshot.expanded ? "Collapse Items" : "Expand Items") : "Open Child Card"
        row.leading.setAccessibilityValue(root ? (snapshot.expanded ? "Expanded" : "Collapsed") : nil)
        configureEditor(row.editor, source: heading.title, font: .systemFont(ofSize: root ? 19 : 15, weight: root ? .semibold : .medium),
                        completed: completed)
        var metadata = [heading.state, heading.priority.map { "[\($0)]" }, heading.tags.isEmpty ? nil : heading.tags].compactMap { $0 }
        if root {
            let items = heading.checkboxes
            if !items.isEmpty { metadata.append("\(items.filter { $0.state.uppercased() == "X" }.count)/\(items.count)") }
        }
        row.metadata.textColor = foreground.withAlphaComponent(0.85)
        [row.leading, row.done, row.more].forEach { $0.contentTintColor = foreground }
        row.metadata.stringValue = metadata.joined(separator: "  ")
    }

    private func configureCheckbox(_ row: NativeCardRow, item: OrgCheckbox) {
        let prefix = "checkbox:\(item.id):"
        row.setAccessibilityIdentifier("checkbox:\(item.id)")
        row.editor.setAccessibilityIdentifier(prefix + "text")
        row.leading.setAccessibilityIdentifier(prefix + "toggle")
        row.more.setAccessibilityIdentifier(prefix + "menu")
        configureSelection(row)
        row.done.isHidden = true
        let symbol = item.state == "-" ? "minus.square" : item.state.uppercased() == "X" ? "checkmark.square.fill" : "square"
        row.leading.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle checkbox")
        row.leading.toolTip = item.state.uppercased() == "X" ? "Mark as Incomplete" : "Mark as Complete"
        row.leading.setAccessibilityLabel(row.leading.toolTip)
        row.leading.setAccessibilityValue(item.state == "-" ? "Partially complete" : item.state.uppercased() == "X" ? "Complete" : "Incomplete")
        configureEditor(row.editor, source: item.title, font: .systemFont(ofSize: 15), completed: item.state.uppercased() == "X")
        row.metadata.stringValue = ""
        [row.leading, row.more].forEach { $0.contentTintColor = foreground }
    }

    func configureSelection(_ row: NativeCardRow) {
        let selected = row.target.key.kind == .heading && row.target !== rootTarget &&
            snapshot?.selectedID == row.target.key.headingID
        row.layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.clear).cgColor
    }

    private func configureEditor(_ editor: NativeCardEditor, source: String, font: NSFont, completed: Bool) {
        editor.font = font
        editor.textColor = completed ? foreground.withAlphaComponent(0.85) : foreground
        editor.setAccessibilityLabel(source)
        let display = NSMutableAttributedString(attributedString: NativeOrgText.attributed(source, font: font, color: editor.textColor ?? foreground, documentURL: controller.store.url))
        if completed { display.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: display.length)) }
        editor.configure(source: source, display: display)
    }

    func arrange() {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        _ = header.place(at: CGPoint(x: 12, y: 12), width: CardGeometry.width - 24)
        var y: CGFloat = 8
        for (key, inset) in ordered {
            guard let view = rows[key]?.view else { continue }
            let width = max(60, CardGeometry.width - 36 - inset)
            let height: CGFloat
            if let row = view as? NativeCardRow { height = row.place(at: CGPoint(x: 16 + inset, y: y), width: width) }
            else if let editor = view as? NativeCardEditor {
                height = max(30, editor.height(for: width))
                editor.frame = CGRect(x: 16 + inset, y: y, width: width, height: height)
            } else if let notes = view as? NativeCardNotes {
                height = notes.height(for: width)
                notes.frame = CGRect(x: 16 + inset, y: y, width: width, height: height)
            } else { height = 0 }
            y += height + 2
        }
        document.frame = CGRect(x: 0, y: 0, width: CardGeometry.width, height: y + 8)
        scroll.frame = CGRect(x: 0, y: headerHeight, width: CardGeometry.width, height: bodyHeight)
        resize()
    }
}

struct NativeCardElement {
    let target: CardRowTarget
    let view: NSView
}

final class NativeCardDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class NativeCardRow: NSView {
    let target: CardRowTarget
    weak var card: NativeCardView?
    let leading = NativeCardButton(symbol: "chevron.right", label: "Toggle items")
    let done = NativeCardButton(symbol: "circle", label: "Toggle TODO")
    let more = NativeCardButton(symbol: "ellipsis", label: "Item menu")
    let editor: NativeCardEditor
    let metadata = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    init(target: CardRowTarget, card: NativeCardView) {
        self.target = target
        self.card = card
        editor = NativeCardEditor(target: target, card: card)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        wantsLayer = true
        layer?.cornerRadius = 6
        [leading, done, more, editor, metadata].forEach(addSubview)
        metadata.font = .systemFont(ofSize: 12, weight: .medium)
        metadata.textColor = .darkGray
        leading.actionBody = { [weak self] in
            guard let self else { return }
            self.card?.toggle(self.target)
        }
        done.actionBody = { [weak self] in
            guard let self, let controller = self.card?.controller, controller.commitInlineEdit() else { return }
            controller.toggleState(self.target.key.headingID)
        }
        more.actionBody = { [weak self] in
            guard let self else { return }
            self.card?.actionMenu(for: self.target)?.popUp(positioning: nil,
                                                        at: CGPoint(x: self.more.frame.minX, y: self.more.frame.maxY),
                                                        in: self)
        }
    }

    required init?(coder: NSCoder) { nil }
    override func menu(for event: NSEvent) -> NSMenu? { card?.actionMenu(for: target) }

    func place(at point: CGPoint, width: CGFloat) -> CGFloat {
        let root = target === card?.rootTarget
        let textX: CGFloat = root ? 0 : done.isHidden ? 34 : 66
        let textWidth = width - textX - (root ? 68 : 34)
        let textHeight = root ? CardGeometry.titleHeight : editor.height(for: textWidth)
        let height = max(32, textHeight + (root ? 10 : 6))
        let metadataHeight: CGFloat = root || !metadata.stringValue.isEmpty ? 18 : 0
        frame = CGRect(origin: point, size: CGSize(width: width, height: height + metadataHeight))
        leading.frame = CGRect(x: root ? width - 66 : 0, y: 0, width: 32, height: 32)
        done.frame = CGRect(x: 32, y: 0, width: 32, height: 32)
        editor.frame = CGRect(x: textX, y: (height - textHeight) / 2, width: textWidth, height: textHeight)
        more.frame = CGRect(x: width - 32, y: 0, width: 32, height: 32)
        metadata.frame = CGRect(x: textX, y: height, width: textWidth, height: metadataHeight)
        return height + metadataHeight
    }
}

@MainActor
final class NativeCardNotes: NSTextView {
    let target: CardRowTarget
    weak var card: NativeCardView?
    override func menu(for event: NSEvent) -> NSMenu? { card?.actionMenu(for: target) }

    init(target: CardRowTarget, card: NativeCardView) {
        self.target = target
        self.card = card
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CardGeometry.width - 36, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
    }

    required init?(coder: NSCoder) { nil }

    func height(for width: CGFloat) -> CGFloat {
        textContainer?.containerSize = CGSize(width: width, height: 100000)
        guard let layoutManager, let textContainer else { return 20 }
        layoutManager.ensureLayout(for: textContainer)
        return max(20, ceil(layoutManager.usedRect(for: textContainer).height))
    }
}
