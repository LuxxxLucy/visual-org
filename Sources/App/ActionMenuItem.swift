import AppKit

final class ActionMenuItem: NSMenuItem {
    private let actionBody: () -> Void

    init(_ title: String, key: String = "", action: @escaping () -> Void) {
        actionBody = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBody() }
}
