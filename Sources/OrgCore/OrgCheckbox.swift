import Foundation

public struct OrgCheckbox: Identifiable, Equatable {
    public let id: Int
    public let title: String
    public let indent: Int
    public let state: String
    public internal(set) var details = ""
}

public enum OrgBodyElement: Equatable {
    case text(line: Int, source: String)
    case checkbox(OrgCheckbox)
}

private struct CheckboxLine {
    var item: OrgCheckbox
    let stateRange: NSRange
    let titleRange: NSRange
    let parent: Int?
    let whitespace: String
}

private struct CheckboxBody {
    private static let expression = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+]|[0-9]+[.)])[ \t]+\[([ Xx-])\](?:[ \t]+(.*?))?\r?$"#)
    private static let drawerExpression = try! NSRegularExpression(pattern: #"^:[A-Za-z0-9_@#%]+:$"#)
    var items: [CheckboxLine] = []
    var preview: [String] = []
    var recursive = false

    init(_ body: String) {
        var block: String?
        var drawer = false
        var properties = false
        var parents: [Int] = []
        var details: [[String]] = []
        var blockOwner: Int?
        for (index, line) in body.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            let indent = line.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $1 == "\t" ? ($0 / 8 + 1) * 8 : $0 + 1 }
            if let active = block {
                if let owner = blockOwner { details[owner].append(line) }
                else { preview.append(line) }
                if upper == "#+END_" + active { block = nil }
                continue
            }
            if upper.hasPrefix("#+BEGIN_") {
                block = String(upper.dropFirst(8).prefix { !$0.isWhitespace })
                while let last = parents.last, items[last].item.indent >= indent { parents.removeLast() }
                blockOwner = parents.last
                if let owner = blockOwner { details[owner].append(line) }
                else { preview.append(line) }
                continue
            }
            if drawer {
                if upper == ":END:" { drawer = false }
                if properties, upper.hasPrefix(":COOKIE_DATA:") {
                    recursive = upper.dropFirst(13).split(whereSeparator: \.isWhitespace).contains("RECURSIVE")
                }
                continue
            }
            if Self.drawerExpression.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                drawer = upper != ":END:"
                properties = upper == ":PROPERTIES:"
                parents.removeAll()
                continue
            }
            let text = line as NSString
            if let match = Self.expression.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) {
                let whitespace = text.substring(with: match.range(at: 1))
                let indent = whitespace.reduce(0) { $1 == "\t" ? ($0 / 8 + 1) * 8 : $0 + 1 }
                while let last = parents.last, items[last].item.indent >= indent { parents.removeLast() }
                let titleRange = match.range(at: 3)
                let title = titleRange.location == NSNotFound ? "" : text.substring(with: titleRange)
                let item = OrgCheckbox(id: index, title: title, indent: indent,
                                       state: text.substring(with: match.range(at: 2)).uppercased())
                items.append(CheckboxLine(item: item, stateRange: match.range(at: 2), titleRange: titleRange,
                                          parent: parents.last, whitespace: whitespace))
                details.append([])
                parents.append(items.count - 1)
            } else {
                if !trimmed.isEmpty {
                    while let last = parents.last, items[last].item.indent >= indent { parents.removeLast() }
                }
                if let owner = parents.last {
                    details[owner].append(line)
                } else if !upper.hasPrefix("#+") {
                    preview.append(line)
                }
            }
        }
        for index in items.indices {
            items[index].item.details = details[index].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct OrgBodyContent: Equatable {
    let source: String
    let checkboxes: [OrgCheckbox]
    let notePreview: String
    let elements: [OrgBodyElement]

    init(_ source: String) {
        self.source = source
        if source.isEmpty {
            checkboxes = []
            notePreview = ""
            elements = []
            return
        }
        let parsed = CheckboxBody(source)
        checkboxes = parsed.items.map(\.item)
        notePreview = parsed.preview.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = source.components(separatedBy: "\n")
        var ordered: [OrgBodyElement] = []
        var start = 0
        for item in checkboxes {
            if start < item.id {
                ordered.append(.text(line: start, source: lines[start..<item.id].joined(separator: "\n")))
            }
            ordered.append(.checkbox(item))
            start = item.id + 1
        }
        if start < lines.count {
            ordered.append(.text(line: start, source: lines[start...].joined(separator: "\n")))
        }
        elements = ordered
    }
}

public extension OrgDocument {
    mutating func renameCheckbox(_ headingID: String, item: OrgCheckbox, title: String) throws {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !title.contains("\n"), !title.contains("\r") else {
            throw OrgError.invalidText
        }
        let heading = try record(headingID).heading
        let parsed = CheckboxBody(heading.body)
        guard let entry = parsed.items.first(where: { $0.item.id == item.id }), entry.item == item else {
            throw OrgError.changedExternally
        }
        var lines = heading.body.components(separatedBy: "\n")
        let line = NSMutableString(string: lines[item.id])
        if entry.titleRange.location != NSNotFound, entry.titleRange.length > 0 {
            let original = line.substring(with: entry.titleRange) as NSString
            let trimmed = original.trimmingCharacters(in: .whitespaces) as NSString
            let range = original.range(of: trimmed as String)
            line.replaceCharacters(in: NSRange(location: entry.titleRange.location + range.location,
                                              length: range.length), with: clean)
        } else {
            let insertion = NSMaxRange(entry.stateRange) + 1
            line.insert(" " + clean, at: insertion)
        }
        lines[item.id] = line as String
        try setBody(headingID, lines.joined(separator: "\n"))
    }

    mutating func setCheckbox(_ headingID: String, item: OrgCheckbox, checked: Bool) throws {
        let heading = try record(headingID).heading
        let parsed = CheckboxBody(heading.body)
        guard let index = parsed.items.firstIndex(where: { $0.item.id == item.id }),
              parsed.items[index].item == item else {
            throw OrgError.changedExternally
        }
        var states = parsed.items.map { $0.item.state }
        states[index] = checked ? "X" : " "
        for child in parsed.items.indices where child > index {
            var parent = parsed.items[child].parent
            while let current = parent {
                if current == index { states[child] = checked ? "X" : " "; break }
                parent = parsed.items[current].parent
            }
        }
        var parent = parsed.items[index].parent
        while let current = parent {
            let children = parsed.items.indices.filter { parsed.items[$0].parent == current }
            states[current] = children.allSatisfy { states[$0] == "X" } ? "X"
                : children.allSatisfy { states[$0] == " " } ? " " : "-"
            parent = parsed.items[current].parent
        }
        var lines = heading.body.components(separatedBy: "\n")
        for (index, entry) in parsed.items.enumerated() where states[index] != entry.item.state {
            let line = NSMutableString(string: lines[entry.item.id])
            line.replaceCharacters(in: entry.stateRange, with: states[index])
            lines[entry.item.id] = line as String
        }
        try saveCheckboxBody(heading, body: lines.joined(separator: "\n"))
    }

    mutating func addCheckbox(_ headingID: String, title: String) throws {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !title.contains("\n"), !title.contains("\r") else {
            throw OrgError.invalidText
        }
        let heading = try record(headingID).heading
        let parsed = CheckboxBody(heading.body)
        let whitespace = parsed.items.first(where: { $0.parent == nil })?.whitespace ?? ""
        var body = heading.body
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        body += whitespace + "- [ ] " + clean + "\n"
        try saveCheckboxBody(heading, body: body)
    }

    private mutating func saveCheckboxBody(_ heading: OrgHeading, body: String) throws {
        let expression = try! NSRegularExpression(pattern: #"\[(?:[0-9]*/[0-9]*|[0-9]*%)\]"#)
        let title = heading.title as NSString
        let cookies = expression.matches(in: heading.title, range: NSRange(location: 0, length: title.length))
        guard !cookies.isEmpty else { try setBody(heading.id, body); return }
        let parsed = CheckboxBody(body)
        let counted = parsed.items.filter { parsed.recursive || $0.parent == nil }
        let completed = counted.filter { $0.item.state == "X" }.count
        let updatedTitle = NSMutableString(string: heading.title)
        for cookie in cookies.reversed() {
            let previous = title.substring(with: cookie.range)
            let replacement = previous.contains("%")
                ? "[\(counted.isEmpty ? 0 : completed * 100 / counted.count)%]"
                : "[\(completed)/\(counted.count)]"
            updatedTitle.replaceCharacters(in: cookie.range, with: replacement)
        }
        _ = try updateDetails(heading.id, title: updatedTitle as String, body: body,
                              expectedTitle: heading.title, expectedBody: heading.body)
    }

}
