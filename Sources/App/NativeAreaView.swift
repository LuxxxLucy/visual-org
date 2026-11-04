import AppKit
import SwiftUI

@MainActor
final class NativeAreaView: NSView {
    private let controller: WorkspaceController
    private let menuButton = NSButton()
    private var group: CanvasGroup?
    weak var canvas: NativeCanvasView?

    override var isFlipped: Bool { true }

    init(controller: WorkspaceController) {
        self.controller = controller
        super.init(frame: .zero)
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Area actions")
        menuButton.isBordered = false
        menuButton.bezelStyle = .inline
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.setAccessibilityLabel("Area actions")
        addSubview(menuButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    func update(_ group: CanvasGroup) {
        self.group = group
        setFrameSize(CGSize(width: group.width, height: group.height))
        setAccessibilityLabel(group.title)
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        menuButton.frame = CGRect(x: max(8, bounds.width - 48), y: 12, width: 32, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let group else { return }
        let index = (group.color % cardColors.count + cardColors.count) % cardColors.count
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 24, yRadius: 24)
        cardColors[index].withAlphaComponent(0.3).setFill()
        shape.fill()
        NSColor(ink).withAlphaComponent(0.16).setStroke()
        shape.lineWidth = 1
        shape.setLineDash([5, 5], count: 2, phase: 0)
        shape.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: group.title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(ink),
            .kern: 2,
            .paragraphStyle: paragraph
        ])
        title.draw(in: CGRect(x: 20, y: 20, width: max(0, bounds.width - 76), height: 20))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.y <= 56 else { return nil }
        if menuButton.frame.contains(local) { return menuButton }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: 0, y: 0, width: max(0, bounds.width - 56), height: min(56, bounds.height)), cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let group else { return }
        canvas?.beginAreaPointer(group.id, event: event)
    }

    override func mouseDragged(with event: NSEvent) { canvas?.continuePointer(with: event) }
    override func mouseUp(with event: NSEvent) { canvas?.endPointer(with: event) }
    override func cancelOperation(_ sender: Any?) { canvas?.cancelOperation(sender) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        return bounds.contains(local) && local.y <= 56 ? actionMenu() : nil
    }

    @objc private func showMenu() {
        actionMenu().popUp(positioning: nil, at: CGPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY + 4), in: self)
    }

    private func actionMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            ("Rename area", #selector(rename)),
            ("Make wider", #selector(makeWider)),
            ("Make taller", #selector(makeTaller)),
            ("Remove area", #selector(removeArea))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func rename() {
        guard let group, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Area name"
        let field = NSTextField(string: group.title)
        field.frame = CGRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel("Area name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  var current = self.group, current.id == group.id else { return }
            current.title = field.stringValue
            self.controller.updateGroup(current)
        }
        alert.window.makeFirstResponder(field)
    }

    @objc private func makeWider() {
        guard var group else { return }
        group.width += 360
        controller.updateGroup(group)
    }

    @objc private func makeTaller() {
        guard var group else { return }
        group.height += 300
        controller.updateGroup(group)
    }

    @objc private func removeArea() {
        guard let group else { return }
        controller.deleteGroup(group.id)
    }

}
