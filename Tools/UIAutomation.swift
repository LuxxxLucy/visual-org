import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class UIAutomation {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let pid: pid_t
    let app: AXUIElement

    init(pid: pid_t) throws {
        guard pid > 0, AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw Failure(message: "UI tests require Accessibility and event posting access.")
        }
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        try checkProcess()
        try activate()
    }

    func activate() throws {
        try checkProcess()
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        let status = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        try wait(message: "Cannot activate test process \(pid), AX status \(status.rawValue)") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
                value(app, kAXFrontmostAttribute) == "1"
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    func value(_ element: AXUIElement, _ name: String) -> String {
        guard let result = attribute(element, name) else { return "" }
        return result as? String ?? (result as? NSNumber)?.stringValue ?? ""
    }

    func children(of element: AXUIElement) -> [AXUIElement] {
        var result = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        result += attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let menu = attribute(element, kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() {
            result.append(unsafeBitCast(menu, to: AXUIElement.self))
        }
        return result
    }

    private func tree(_ root: AXUIElement) -> [(AXUIElement, Int)] {
        var queue = [(root, 0)]
        var seen: Set<AXUIElement> = []
        var result: [(AXUIElement, Int)] = []
        var index = 0
        let deadline = Date().addingTimeInterval(2)
        while index < queue.count, result.count < 2000, Date() < deadline {
            let (element, depth) = queue[index]
            index += 1
            guard seen.insert(element).inserted else { continue }
            result.append((element, depth))
            if depth < 35 { queue += children(of: element).map { ($0, depth + 1) } }
        }
        return result
    }

    func find(id: String? = nil, role: String? = nil, text: String? = nil,
              in scope: AXUIElement? = nil) -> AXUIElement? {
        let matches = tree(scope ?? app).filter { element, _ in
            (id == nil || value(element, kAXIdentifierAttribute) == id) &&
            (role == nil || value(element, kAXRoleAttribute) == role) &&
            (text == nil || [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
                .contains { value(element, $0) == text })
        }
        let visible = matches.first { element, _ in
            guard value(element, kAXRoleAttribute) != "AXUnknown",
                  let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
            var dimensions = CGSize.zero
            return AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) && dimensions.width > 0 && dimensions.height > 0
        }
        if role == kAXMenuItemRole { return visible?.0 }
        return (visible ?? matches.first)?.0
    }

    func require(id: String? = nil, role: String? = nil, text: String? = nil,
                 in scope: AXUIElement? = nil, timeout: TimeInterval = 5) throws -> AXUIElement {
        var result: AXUIElement?
        try wait(timeout: timeout, message: "Missing UI element: \(id ?? role ?? text ?? "unspecified")") {
            result = find(id: id, role: role, text: text, in: scope)
            return result != nil
        }
        return result!
    }

    func frame(of element: AXUIElement) throws -> CGRect {
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid,
              let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw failure("UI element has no target-process frame.")
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { throw failure("UI element frame is empty.") }
        return CGRect(origin: point, size: dimensions)
    }

    func click(_ element: AXUIElement, right: Bool = false, flags: CGEventFlags = []) throws {
        var rect = try frame(of: element)
        var stableSince = Date()
        try wait(message: "UI element kept moving before the click") {
            let next = try frame(of: element)
            if next != rect {
                rect = next
                stableSince = Date()
            }
            return Date().timeIntervalSince(stableSince) >= 0.1
        }
        try click(at: CGPoint(x: rect.midX, y: rect.midY), right: right, flags: flags)
    }

    func click(at point: CGPoint, right: Bool = false, flags: CGEventFlags = []) throws {
        let button: CGMouseButton = right ? .right : .left
        try mouse(.mouseMoved, at: point, button: button, flags: flags)
        try mouse(right ? .rightMouseDown : .leftMouseDown, at: point, button: button, flags: flags)
        pause(0.04)
        try mouse(right ? .rightMouseUp : .leftMouseUp, at: point, button: button, flags: flags)
    }

    func drag(from start: CGPoint, to end: CGPoint, flags: CGEventFlags = []) throws {
        try mouse(.mouseMoved, at: start, flags: flags)
        try mouse(.leftMouseDown, at: start, flags: flags)
        for step in 1...20 {
            pause(0.02)
            let fraction = CGFloat(step) / 20
            try mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * fraction,
                                                   y: start.y + (end.y - start.y) * fraction), flags: flags)
        }
        try mouse(.leftMouseUp, at: end, flags: flags)
    }

    func scroll(at point: CGPoint, dy: Int32, flags: CGEventFlags = []) throws {
        try mouse(.mouseMoved, at: point, flags: flags)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: dy, wheel2: 0, wheel3: 0) else { throw failure("Cannot create scroll event.") }
        event.location = point
        event.flags = flags
        try checkPointer(point)
        try post(event)
    }

    func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
                throw failure("Cannot create keyboard event.")
            }
            event.flags = down ? flags : []
            try post(event)
        }
    }

    func type(_ text: String) throws {
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
                    throw failure("Cannot create text event.")
                }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                try post(event)
            }
        }
    }

    private func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags = []) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw failure("Cannot create mouse event.")
        }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.flags = flags
        if type == .leftMouseDown || type == .rightMouseDown {
            try checkPointer(point)
        }
        try post(event)
    }

    private func checkPointer(_ point: CGPoint) throws {
        var hit: AXUIElement?
        var owner: pid_t = 0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, AXUIElementGetPid(hit, &owner) == .success, owner == pid else {
            throw failure("Pointer target at \(point) belongs to process \(owner), expected \(pid).")
        }
    }

    private func post(_ event: CGEvent) throws {
        try checkProcess()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw failure("Test process lost foreground focus; UI input stopped.")
        }
        if event.type == .keyDown || event.type == .keyUp { event.postToPid(pid) }
        else { event.post(tap: .cghidEventTap) }
    }

    private func checkProcess() throws {
        guard kill(pid, 0) == 0, NSRunningApplication(processIdentifier: pid)?.isTerminated != true else {
            throw failure("Test process \(pid) terminated.")
        }
    }

    private func pause(_ duration: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(duration)) }

    func wait(timeout: TimeInterval = 5, message: String, condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try checkProcess()
            do { if try condition() { return } }
            catch { throw failure(message + ": " + error.localizedDescription) }
            pause(0.05)
        } while Date() < deadline
        throw failure(message)
    }

    func dump(root: AXUIElement? = nil) -> String {
        guard let root = root ?? (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { return "No target window." }
        return tree(root).prefix(100).map { element, depth in
            let fields = [kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
                .map { value(element, $0).replacingOccurrences(of: "\n", with: " ").prefix(90) }.filter { !$0.isEmpty }
            return String(repeating: " ", count: min(depth, 12)) + fields.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private func failure(_ message: String) -> Failure { Failure(message: message + "\n" + dump()) }
}
