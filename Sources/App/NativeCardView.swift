import AppKit
import WorkspaceCore

@MainActor
final class NativeCardView: NSView {
    let controller: WorkspaceController
    let rootTarget: CardRowTarget
    weak var canvas: NativeCanvasView?
    var snapshot: ProjectCard?
    lazy var header = NativeCardRow(target: rootTarget, card: self)
    let scroll = NSScrollView()
    let document = NativeCardDocument()
    var rows: [CardRowKey: NativeCardElement] = [:]
    var ordered: [(CardRowKey, CGFloat)] = []
    var layingOut = false
    var headerHeight: CGFloat { CardGeometry.headerHeight }
    var bodyHeight: CGFloat { CardGeometry.bodyHeight }
    private var targetHeight: CGFloat = 0

    var id: String {
        get { rootTarget.key.headingID }
        set {
            rootTarget.key.headingID = newValue
            setAccessibilityIdentifier("card:" + newValue)
        }
    }

    var foreground: NSColor {
        NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
    }

    override var isFlipped: Bool { true }

    init(id: String, controller: WorkspaceController) {
        self.controller = controller
        rootTarget = CardRowTarget(CardRowKey(headingID: id, kind: .heading))
        super.init(frame: CGRect(x: 0, y: 0, width: CardGeometry.width, height: CardGeometry.headerHeight))
        appearance = NSAppearance(named: .aqua)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("card:" + id)
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged),
                                               name: NSView.frameDidChangeNotification, object: self)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        addSubview(header)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.setAccessibilityIdentifier("body-scroll")
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func frameChanged() { canvas?.needsDisplay = true }

    func showSelection(_ selected: Bool) {
        layer?.borderWidth = selected ? 2 : 1
        layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.12)).cgColor
    }

    func update(_ next: ProjectCard) {
        synchronizeEditing()
        guard snapshot != next else { return }
        let previous = snapshot
        let reset = previous?.revision != next.revision
        if reset { resetCreationDrafts() }
        snapshot = next
        layer?.backgroundColor = cardColors[max(0, min(cardColors.count - 1, next.color))].cgColor
        configureHeading(header, heading: next.heading)
        if !reset, let previous, previous.heading == next.heading,
           previous.color == next.color, previous.searchQuery == next.searchQuery {
            for element in rows.values {
                guard let row = element.view as? NativeCardRow else { continue }
                configureSelection(row)
            }
            resize()
        } else {
            rebuildBody(next.heading)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { actionMenu(for: rootTarget) }

    func resize() {
        guard let snapshot else { return }
        let height = CardGeometry.height(expanded: snapshot.expanded)
        guard targetHeight != height else { return }
        targetHeight = height
        scroll.isHidden = false
        let size = CGSize(width: CardGeometry.width, height: height)
        canvas?.cardSizeChanged(id, size: size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = window != nil && !isHidden && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrameSize(size)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.targetHeight == height else { return }
                self.scroll.isHidden = self.snapshot?.expanded != true
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var ancestor: NSView? = hit
        while let view = ancestor, view !== self {
            if view is NSControl || view is NSTextView { return hit }
            ancestor = view.superview
        }
        return NSApp.currentEvent?.type == .leftMouseDown ? self : hit
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { canvas?.beginCardPointer(id, event: event) }
    override func mouseDragged(with event: NSEvent) { canvas?.continuePointer(with: event) }
    override func mouseUp(with event: NSEvent) { canvas?.endPointer(with: event) }
    override func cancelOperation(_ sender: Any?) { canvas?.cancelOperation(sender) }
}
