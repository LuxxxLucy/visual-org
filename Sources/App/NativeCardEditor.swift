import AppKit

@MainActor
final class NativeCardEditor: NSTextField, NSTextFieldDelegate {
    let rowTarget: CardRowTarget
    weak var card: NativeCardView?
    private var source = ""
    private var display = NSAttributedString(string: "")
    private var editing = false

    init(target rowTarget: CardRowTarget, card: NativeCardView) {
        self.rowTarget = rowTarget
        self.card = card
        super.init(frame: .zero)
        isEditable = true
        isSelectable = true
        isBordered = false
        drawsBackground = false
        focusRingType = .exterior
        usesSingleLineMode = false
        maximumNumberOfLines = 0
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.isScrollable = false
        delegate = self
    }

    required init?(coder: NSCoder) { nil }

    private var isChildReference: Bool {
        rowTarget.key.kind == .heading && rowTarget.key.headingID != card?.id
    }

    private var sessionIsActive: Bool {
        if rowTarget.key.kind == .entry { return true }
        guard let key = rowTarget.inlineKey else { return false }
        return card?.controller.inlineEdits.key == key
    }

    func configure(source: String, display: NSAttributedString) {
        self.source = source
        self.display = display
        synchronizeSession()
        if !editing { attributedStringValue = display }
    }

    func synchronizeSession() {
        if editing && !sessionIsActive {
            editing = false
            abortEditing()
            restoreDisplay()
        }
    }

    func resetText(_ text: String) {
        editing = false
        abortEditing()
        source = text
        display = plainText(text)
        restoreDisplay()
    }

    private func start() -> Bool {
        if editing { return true }
        guard let controller = card?.controller, controller.commitInlineEdit() else { return false }
        if let key = rowTarget.inlineKey {
            guard controller.beginInlineEdit(key) else { return false }
        } else if rowTarget.key.kind != .entry {
            return false
        }
        editing = true
        stringValue = source
        card?.arrange()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if isChildReference {
            guard let card, card.controller.commitInlineEdit() else { return }
            card.controller.openCard(rowTarget.key.headingID)
            return
        }
        if event.modifierFlags.contains(.command), openLink(at: event) { return }
        guard start() else { return }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool { !isChildReference && start() && super.becomeFirstResponder() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isChildReference ? .pointingHand : .iBeam) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func openLink(at event: NSEvent) -> Bool {
        guard !editing, display.length > 0 else { return false }
        let storage = NSTextStorage(attributedString: display)
        let manager = NSLayoutManager()
        let rect = cell?.drawingRect(forBounds: bounds) ?? bounds
        let container = NSTextContainer(size: rect.size)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let local = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x - rect.minX, y: local.y - rect.minY)
        manager.ensureLayout(for: container)
        guard manager.usedRect(for: container).contains(point) else { return false }
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < display.length, let url = display.attribute(.link, at: index, effectiveRange: nil) as? URL else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private func updateDraft() {
        guard let controller = card?.controller, sessionIsActive else { return }
        if rowTarget.key.kind == .entry {
            controller.creationDrafts.updateCheckboxText(rowTarget.key.headingID, stringValue)
        } else {
            controller.updateInlineText(stringValue)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard editing, sessionIsActive else { return }
        updateDraft()
        card?.arrange()
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        finish()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if !editing { restoreDisplay() }
    }

    private func finish() -> Bool {
        guard editing else { return true }
        guard sessionIsActive else {
            editing = false
            card?.arrange()
            return true
        }
        updateDraft()
        if rowTarget.key.kind != .entry, card?.controller.commitInlineEdit() != true { return false }
        editing = false
        if stringValue != source { display = plainText(stringValue) }
        source = stringValue
        card?.arrange()
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:)) {
            if rowTarget.key.kind == .entry {
                updateDraft()
                guard let controller = card?.controller else { return true }
                controller.addCheckbox(rowTarget.key.headingID)
                if controller.creationDrafts.checkboxText(rowTarget.key.headingID).isEmpty {
                    resetText("")
                    window?.makeFirstResponder(nil)
                }
            } else if finish() { window?.makeFirstResponder(nil) }
            return true
        }
        if command == #selector(NSResponder.cancelOperation(_:)) {
            if editing && sessionIsActive, let controller = card?.controller {
                if rowTarget.key.kind == .entry {
                    controller.creationDrafts.updateCheckboxText(rowTarget.key.headingID, "")
                } else {
                    controller.cancelInlineEdit()
                }
            }
            editing = false
            abortEditing()
            if rowTarget.key.kind == .entry {
                source = ""
                display = NSAttributedString(string: "")
            }
            restoreDisplay()
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func restoreDisplay() {
        attributedStringValue = display
        card?.arrange()
    }

    private func plainText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font ?? NSFont.systemFont(ofSize: 15),
                                                      .foregroundColor: textColor ?? NSColor.labelColor])
    }

    func height(for width: CGFloat) -> CGFloat {
        max(22, ceil(cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: max(1, width), height: 10000)).height ?? 22))
    }
}

@MainActor
final class NativeCardButton: NSButton {
    var actionBody: () -> Void = {}
    var showsShadow = false { didSet { updateAppearance() } }
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        setAccessibilityLabel(label)
        toolTip = label
        target = self
        action = #selector(performAction)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { nil }
    @objc private func performAction() { actionBody() }
    override func highlight(_ flag: Bool) { super.highlight(flag); updateAppearance() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(next)
        tracking = next
    }
    private func updateAppearance() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(isHighlighted ? 0.20 : hovered ? 0.12 : showsShadow ? 0.10 : 0).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = showsShadow ? 0.25 : 0
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateAppearance() }
}
