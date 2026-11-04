import AppKit

@MainActor
final class NativeNotesSheet: NSWindow {
    static func present(title: String, text: String, documentURL: URL?, from parent: NSWindow?) {
        guard let parent, parent.attachedSheet == nil, parent.makeFirstResponder(nil) else { return }
        let sheet = NativeNotesSheet(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.title = title
        sheet.minSize = NSSize(width: 380, height: 260)
        sheet.isReleasedWhenClosed = false
        guard let content = sheet.contentView else { return }
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = false
        view.isSelectable = true
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.textStorage?.setAttributedString(NativeOrgText.notes(text, documentURL: documentURL, color: .textColor))
        let done = NSButton(title: "Done", target: sheet, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(done)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -12),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        parent.beginSheet(sheet)
    }

    @objc private func finish() { sheetParent?.endSheet(self) }
    override func cancelOperation(_ sender: Any?) { finish() }
}
