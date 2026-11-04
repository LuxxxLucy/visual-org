import AppKit
import Combine
import OrgCore
import WorkspaceCore

@MainActor
final class NativeCanvasView: NSView {
    private enum CanvasItem: Hashable {
        case card(String)
        case area(String)
    }

    private enum PointerOperation {
        case idle
        case selecting(origin: CGPoint, current: CGPoint)
        case pressed(item: CanvasItem, origin: CGPoint, zoom: Double)
        case moving(origin: CGPoint, zoom: Double, items: [CanvasItem: CGPoint], delta: CGSize)
        case panning(previous: CGPoint, button: Int)
    }

    let controller: WorkspaceController
    private let world = CanvasWorldView()
    private var cards: [String: NativeCardView] = [:]
    private var areas: [String: NativeAreaView] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshPending = false
    private var visibleIDs: Set<String> = []
    private var documentID: UUID?
    private var pointer = PointerOperation.idle { didSet { updatePointerCursor() } }
    private var spaceHeld = false { didSet { updatePointerCursor() } }
    private var pinching = false
    private let grid = CanvasGrid()
    private lazy var detail = CanvasDetailLevel { [weak self] in self?.needsDisplay = true }
    private var pointerCursor: NSCursor?
    private weak var cursorWindow: NSWindow?
    private var inputMonitor: Any?
    private var focusObserver: NSObjectProtocol?
    private(set) var camera = CanvasCamera()

    private func updatePointerCursor() {
        let next: NSCursor?
        switch pointer {
        case .moving, .panning: next = .closedHand
        default: next = spaceHeld ? .openHand : nil
        }
        guard pointerCursor !== next || cursorWindow !== window else { return }
        if pointerCursor != nil { NSCursor.pop() }
        cursorWindow?.enableCursorRects()
        cursorWindow?.resetCursorRects()
        pointerCursor = window == nil ? nil : next
        cursorWindow = window
        if let pointerCursor {
            window?.disableCursorRects()
            pointerCursor.push()
        }
    }

    private func isMoving(_ item: CanvasItem) -> Bool {
        if case .moving(_, _, let items, _) = pointer { return items[item] != nil }
        return false
    }

    private func tracks(_ item: CanvasItem) -> Bool {
        if case .pressed(let current, _, _) = pointer { return current == item }
        return isMoving(item)
    }

    private func view(for item: CanvasItem) -> NSView? {
        switch item {
        case .card(let id): return cards[id]
        case .area(let id): return areas[id]
        }
    }

    private var selectionRect: CGRect? {
        guard case .selecting(let origin, let current) = pointer,
              hypot(current.x - origin.x, current.y - origin.y) >= 4 else { return nil }
        return CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                      width: abs(current.x - origin.x), height: abs(current.y - origin.y))
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(controller: WorkspaceController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityIdentifier("canvas")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(world)
        controller.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &subscriptions)
        controller.viewport.$value.sink { [weak self] value in self?.applyCamera(value) }.store(in: &subscriptions)
        controller.onRemap = { [weak self] mapping, removed in
            guard let self else { return }
            self.cancelPointer()
            var updated: [String: NativeCardView] = [:]
            for (id, card) in self.cards {
                if removed.contains(id) { card.removeFromSuperview(); continue }
                card.remapIdentifiers(mapping, removing: removed)
                let newID = mapping[id] ?? id
                card.id = newID
                updated[newID] = card
            }
            self.cards = updated
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        controller.viewportSize = bounds.size
        world.frame = bounds
        applyCamera(controller.viewport.value)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.25, green: 0.29, blue: 0.35, alpha: 1).setFill()
        bounds.fill()
        grid.draw(camera: camera, size: bounds.size, detailZoom: detail.zoom)
        drawConnections()
        if let selectionRect {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            selectionRect.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: selectionRect).stroke()
        }
    }

    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    private func drawConnections() {
        NSColor.white.withAlphaComponent(0.5).setStroke()
        for id in visibleIDs {
            guard let parentID = controller.parentID(for: id), visibleIDs.contains(parentID),
                  let child = cards[id], let parent = cards[parentID] else { continue }
            let parentRect = convert(parent.bounds, from: parent)
            let childRect = convert(child.bounds, from: child)
            let parentCenter = CGPoint(x: parentRect.midX, y: parentRect.midY)
            let childCenter = CGPoint(x: childRect.midX, y: childRect.midY)
            let dx = childCenter.x - parentCenter.x
            let dy = childCenter.y - parentCenter.y
            guard hypot(dx, dy) > 1 else { continue }
            let parentScale = min(parentRect.width / (2 * max(abs(dx), 0.001)), parentRect.height / (2 * max(abs(dy), 0.001)))
            let childScale = min(childRect.width / (2 * max(abs(dx), 0.001)), childRect.height / (2 * max(abs(dy), 0.001)))
            guard parentScale + childScale < 1 else { continue }
            let start = CGPoint(x: parentCenter.x + dx * parentScale, y: parentCenter.y + dy * parentScale)
            let end = CGPoint(x: childCenter.x - dx * childScale, y: childCenter.y - dy * childScale)
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            let angle = atan2(dy, dx)
            for offset in [-0.45, 0.45] {
                path.move(to: end)
                path.line(to: CGPoint(x: end.x - 9 * cos(angle + offset), y: end.y - 9 * sin(angle + offset)))
            }
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func refresh() {
        if documentID != controller.documentID {
            cancelOperation(nil)
            for card in cards.values { card.removeFromSuperview() }
            for area in areas.values { area.removeFromSuperview() }
            cards.removeAll(); areas.removeAll()
            documentID = controller.documentID
        }
        let headings = controller.canvasHeadings
        let ids = Set(headings.map(\.id))
        let removedCards = Set(cards.keys).subtracting(ids)
        if removedCards.contains(where: { tracks(.card($0)) }) { cancelPointer() }
        for id in removedCards { cards.removeValue(forKey: id)?.removeFromSuperview() }
        visibleIDs = Set(controller.visible.map(\.id))
        for heading in headings {
            let card: NativeCardView
            if let existing = cards[heading.id] { card = existing }
            else {
                card = NativeCardView(id: heading.id, controller: controller)
                card.canvas = self
                cards[heading.id] = card
                world.addSubview(card)
            }
            let placement = controller.placement(for: heading.id)
            card.update(ProjectCard(heading: heading, color: placement.color, expanded: placement.expanded,
                                    selectedID: controller.selected.flatMap { heading.find($0)?.id },
                                    searchQuery: controller.query, revision: controller.reloadRevision))
            card.showSelection(controller.selectedCards.contains(heading.id))
            if !isMoving(.card(heading.id)) { card.setFrameOrigin(CGPoint(x: placement.x, y: placement.y)) }
            card.isHidden = !visibleIDs.contains(heading.id)
        }
        let areaIDs = Set(controller.layout.groups.map(\.id))
        let removedAreas = Set(areas.keys).subtracting(areaIDs)
        if removedAreas.contains(where: { tracks(.area($0)) }) { cancelPointer() }
        for id in removedAreas { areas.removeValue(forKey: id)?.removeFromSuperview() }
        for group in controller.layout.groups {
            let area = areas[group.id] ?? NativeAreaView(controller: controller)
            if areas[group.id] == nil {
                areas[group.id] = area
                area.canvas = self
                world.addSubview(area, positioned: .below, relativeTo: nil)
            }
            area.update(group)
            if !isMoving(.area(group.id)) { area.setFrameOrigin(CGPoint(x: group.x, y: group.y)) }
        }
        if let id = controller.activeCardID, let card = cards[id] { world.addSubview(card, positioned: .above, relativeTo: nil) }
        updateVisibility()
        detail.update(zoom: camera.zoom, shapeCount: cards.count + areas.count)
        needsDisplay = true
    }

    func cardSizeChanged(_ id: String, size: CGSize) {
        controller.updateCardSize(id, size: size)
        updateVisibility()
    }

    private func applyCamera(_ value: CanvasCamera) {
        if value != camera { detail.update(zoom: value.zoom, shapeCount: cards.count + areas.count) }
        camera = value
        world.bounds = CGRect(x: -value.x / value.zoom, y: -value.y / value.zoom,
                              width: bounds.width / value.zoom, height: bounds.height / value.zoom)
        needsDisplay = true
        updateVisibility()
        window?.invalidateCursorRects(for: self)
    }

    private func updateVisibility() {
        let viewBounds = world.bounds.insetBy(dx: -160 / camera.zoom, dy: -160 / camera.zoom)
        for (id, card) in cards {
            let responder = window?.firstResponder as? NSView
            let focused = card.ownsTextFocus || controller.inlineEdits.rootID == id ||
                (responder.map { $0 === card || $0.isDescendant(of: card) } ?? false)
            card.isHidden = !visibleIDs.contains(id) || (!viewBounds.intersects(card.frame) && !focused && !isMoving(.card(id)))
        }
    }

    func beginCardPointer(_ id: String, event: NSEvent) {
        guard case .idle = pointer, let card = cards[id], controller.commitInlineEdit(),
              window?.makeFirstResponder(self) == true else { return }
        pointer = .pressed(item: .card(card.id), origin: convert(event.locationInWindow, from: nil), zoom: camera.zoom)
    }

    func beginAreaPointer(_ id: String, event: NSEvent) {
        guard case .idle = pointer, areas[id] != nil, controller.commitInlineEdit(),
              window?.makeFirstResponder(self) == true else { return }
        pointer = .pressed(item: .area(id), origin: convert(event.locationInWindow, from: nil), zoom: camera.zoom)
    }

    func continuePointer(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch pointer {
        case .pressed(let item, let origin, let zoom):
            guard hypot(point.x - origin.x, point.y - origin.y) >= 4 else { return }
            let origins: [CanvasItem: CGPoint]
            switch item {
            case .card(let id):
                guard controller.selectCardForMovement(id) else { pointer = .idle; return }
                origins = Dictionary(uniqueKeysWithValues: controller.selectedCards.compactMap { id in
                    cards[id].map { (CanvasItem.card(id), $0.frame.origin) }
                })
                if let card = cards[id] { world.addSubview(card, positioned: .above, relativeTo: nil) }
            case .area:
                guard let view = view(for: item) else { pointer = .idle; return }
                origins = [item: view.frame.origin]
            }
            pointer = .moving(origin: origin, zoom: zoom, items: origins, delta: .zero)
            continuePointer(with: event)
        case .moving(let origin, let zoom, let origins, _):
            let delta = CGSize(width: (point.x - origin.x) / zoom, height: (point.y - origin.y) / zoom)
            for (item, position) in origins {
                view(for: item)?.setFrameOrigin(CGPoint(x: position.x + delta.width, y: position.y + delta.height))
            }
            pointer = .moving(origin: origin, zoom: zoom, items: origins, delta: delta)
        case .selecting(let origin, _):
            pointer = .selecting(origin: origin, current: point)
            needsDisplay = true
        case .panning(let previous, let button):
            pointer = .panning(previous: point, button: button)
            controller.viewport.pan(CGSize(width: point.x - previous.x, height: point.y - previous.y))
        case .idle:
            break
        }
    }

    func endPointer(with event: NSEvent) {
        continuePointer(with: event)
        let operation = pointer
        let rect = selectionRect
        pointer = .idle
        switch operation {
        case .pressed(.card(let id), _, _):
            _ = controller.select(id, edit: false)
        case .pressed(.area(_), _, _):
            break
        case .moving(_, _, let origins, let delta):
            let cardIDs = Set(origins.keys.compactMap { item -> String? in
                if case .card(let id) = item { return id }
                return nil
            })
            if !cardIDs.isEmpty { controller.moveCards(cardIDs, by: delta) }
            for (item, origin) in origins {
                guard case .area(let id) = item,
                      var group = controller.layout.groups.first(where: { $0.id == id }) else { continue }
                group.x = origin.x + delta.width
                group.y = origin.y + delta.height
                controller.updateGroup(group)
            }
            scheduleRefresh()
        case .selecting:
            controller.selectCards(in: rect.map { world.convert($0, from: self) } ?? .zero)
            needsDisplay = true
        case .panning, .idle:
            break
        }
    }

    private func cancelPointer() {
        switch pointer {
        case .moving(_, _, let origins, _):
            for (item, origin) in origins { view(for: item)?.setFrameOrigin(origin) }
        default:
            break
        }
        pointer = .idle
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === world ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard case .idle = pointer, controller.commitInlineEdit() else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            controller.viewport.magnify(1 / camera.zoom, around: point)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        pointer = .selecting(origin: point, current: point)
    }

    override func mouseDragged(with event: NSEvent) {
        continuePointer(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        endPointer(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New project…", action: #selector(newProject), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        return menu
    }

    @objc private func newProject() { controller.requestNewHeading() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelOperation(nil)
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        inputMonitor = nil; focusObserver = nil
        guard let window else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .beginGesture, .endGesture, .magnify, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp, .keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelOperation(nil) }
        }
        scheduleRefresh()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .beginGesture { controller.viewport.stopAnimation() }
        if event.type == .endGesture {
            let handled = pinching
            pinching = false
            return handled ? nil : event
        }
        if event.type == .magnify {
            guard pinching || bounds.contains(point) else { return event }
            if !pinching {
                cancelPointer()
                spaceHeld = false
                pinching = true
            }
            controller.viewport.magnify(1 + event.magnification, around: point)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { pinching = false }
            return nil
        }
        if pinching {
            switch event.type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                 .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                 .otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel:
                return nil
            default: break
            }
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            controller.viewport.stopAnimation()
        }
        if event.type == .keyDown && event.keyCode == 53 {
            if case .idle = pointer, !spaceHeld, !pinching { return event }
            cancelOperation(nil); return nil
        }
        if event.type == .keyUp && event.keyCode == 49 { let handled = spaceHeld; spaceHeld = false; return handled ? nil : event }
        if event.type == .keyDown && event.keyCode == 49 && window?.firstResponder === self,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            spaceHeld = true; return nil
        }
        if case .panning(_, let button) = pointer {
            if (event.type == .leftMouseDragged || event.type == .otherMouseDragged) && event.buttonNumber == button {
                continuePointer(with: event)
                return nil
            }
            if (event.type == .leftMouseUp || event.type == .otherMouseUp) && event.buttonNumber == button {
                endPointer(with: event); return nil
            }
            if event.type == .leftMouseDown || event.type == .otherMouseDown || event.type == .scrollWheel || event.type == .magnify { return nil }
        }
        guard bounds.contains(point) else { return event }
        switch pointer {
        case .idle:
            break
        default:
            if event.type == .scrollWheel || event.type == .magnify || event.type == .otherMouseDown { return nil }
            return event
        }
        switch event.type {
        case .otherMouseDown where event.buttonNumber == 2,
             .leftMouseDown where spaceHeld:
            pointer = .panning(previous: point, button: event.buttonNumber)
            return nil
        case .scrollWheel:
            let factor = event.hasPreciseScrollingDeltas ? 1.0 : 20.0
            if event.modifierFlags.contains(.command) {
                controller.viewport.zoom(wheelDelta: event.scrollingDeltaY * factor, around: point)
                return nil
            }
            var hit = hitTest(convert(point, to: superview))
            while let view = hit, view !== self {
                if view is NSScrollView { return event }
                hit = view.superview
            }
            controller.viewport.pan(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
            return nil
        default: return event
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelPointer()
        spaceHeld = false
        pinching = false
        controller.viewport.stopAnimation()
        needsDisplay = true
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
}

private final class CanvasWorldView: NSView {
    override var isFlipped: Bool { true }
}
