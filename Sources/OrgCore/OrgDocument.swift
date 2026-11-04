import Foundation
import Crypto

public struct OrgHeading: Identifiable, Equatable {
    public internal(set) var id: String
    public let level: Int
    public internal(set) var title: String
    public internal(set) var state: String?
    public internal(set) var priority: String?
    public internal(set) var tags: String
    private var bodyContent: OrgBodyContent
    public internal(set) var body: String {
        get { bodyContent.source }
        set {
            if newValue != bodyContent.source { bodyContent = OrgBodyContent(newValue) }
        }
    }
    public var checkboxes: [OrgCheckbox] { bodyContent.checkboxes }
    public var bodyElements: [OrgBodyElement] { bodyContent.elements }
    public var notePreview: String { bodyContent.notePreview }
    public internal(set) var children: [OrgHeading]

    init(id: String, level: Int, title: String, state: String?, priority: String?,
         tags: String, body: String, children: [OrgHeading]) {
        self.id = id
        self.level = level
        self.title = title
        self.state = state
        self.priority = priority
        self.tags = tags
        self.bodyContent = OrgBodyContent(body)
        self.children = children
    }

    public func find(_ id: String) -> OrgHeading? {
        if self.id == id { return self }
        return children.lazy.compactMap { $0.find(id) }.first
    }
}

public enum OrgError: LocalizedError {
    case changedExternally, missingHeading, invalidText, invalidBody
    case archiveUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .changedExternally: "The Org file changed outside this app. Reload the file before saving."
        case .missingHeading: "This heading changed. Select it again."
        case .invalidText: "Enter a title on one line."
        case .invalidBody: "Use Add item for headings. Close each Org block in the notes."
        case .archiveUnsupported(let reason): reason
        }
    }
}

public struct HeadingChanges {
    public let replacements: [String: String]
    public let removed: Set<String>
}

public struct OrgDocument {
    public private(set) var roots: [OrgHeading] = []
    public private(set) var states = ["TODO", "DONE"]
    public private(set) var doneStates: Set<String> = ["DONE"]
    private(set) var hasStateDeclarations = false

    struct Record {
        var heading: OrgHeading
        let line: Int
        var bodyEnd: Int
        var subtreeEnd: Int
    }

    public var text: String { lines.joined(separator: "\n") }
    public var preamble: String {
        guard let first = records.first else { return text }
        guard first.line > 0 else { return "" }
        return lines[..<first.line].joined(separator: "\n") + "\n"
    }
    private(set) var lines: [String] = []
    private(set) var records: [Record] = []
    private(set) var newline = "\n"

    public init(text: String) {
        parse(text)
    }

    public mutating func setState(_ id: String, _ state: String?) throws {
        guard state == nil || states.contains(state!) else { throw OrgError.invalidText }
        try update(id) { $0.state = state }
    }

    public mutating func setPriority(_ id: String, _ priority: String?) throws {
        guard priority == nil || ["A", "B", "C"].contains(priority!) else {
            throw OrgError.invalidText
        }
        try update(id) { $0.priority = priority }
    }

    mutating func setBody(_ id: String, _ body: String) throws {
        let record = try record(id)
        guard body != record.heading.body else { return }
        try validateBody(body)
        var changed = lines
        replaceBody(body, of: record, in: &changed)
        replaceLines(changed)
    }

    public mutating func updateDetails(_ id: String, title: String, body: String,
                       expectedTitle: String, expectedBody: String) throws -> HeadingChanges {
        try validate(title)
        let record = try record(id)
        guard record.heading.title == expectedTitle, record.heading.body == expectedBody else {
            throw OrgError.changedExternally
        }
        let before = records
        var changed = lines
        if title != record.heading.title {
            changed[record.line] = replacingTitle(of: record, with: title)
        }
        if body != record.heading.body {
            try validateBody(body)
            replaceBody(body, of: record, in: &changed)
        }
        replaceLines(changed)
        return identityChanges(from: before)
    }

    public mutating func addChild(_ id: String, title: String) throws {
        try validate(title)
        let parent = try record(id)
        try insertHeading(title: title, level: parent.heading.level + 1, at: parent.subtreeEnd)
    }

    public mutating func addProject(title: String) throws {
        try validate(title)
        try insertHeading(title: title, level: 1, at: lines.count)
    }

    public mutating func delete(_ heading: OrgHeading) throws -> HeadingChanges {
        removeSubtree(try checkedRecord(heading))
    }

    mutating func removeSubtree(_ item: Record) -> HeadingChanges {
        let range = item.line..<item.subtreeEnd
        let removed = Set(records.filter { range.contains($0.line) }.map(\.heading.id))
        let survivors = records.filter { !range.contains($0.line) }
        var changed = lines
        changed.removeSubrange(range)
        if item.subtreeEnd == lines.count, !changed.isEmpty { changed.append("") }
        replaceLines(changed)
        return identityChanges(from: survivors, removing: removed)
    }

    @discardableResult
    public mutating func moveRoot(_ id: String, offset: Int) throws -> HeadingChanges {
        let top = records.filter { $0.heading.level == 1 }
        guard let index = top.firstIndex(where: { $0.heading.id == id }) else {
            throw OrgError.missingHeading
        }
        let destination = min(max(index + offset, 0), top.count - 1)
        guard destination != index else { return HeadingChanges(replacements: [:], removed: []) }
        var order = top
        let moved = order.remove(at: index)
        order.insert(moved, at: destination)
        var changed = Array(lines[..<top[0].line])
        var orderedRecords = records.filter { $0.line < top[0].line }
        for item in order {
            orderedRecords += records.filter { (item.line..<item.subtreeEnd).contains($0.line) }
            var segment = Array(lines[item.line..<item.subtreeEnd])
            if item.subtreeEnd == lines.count {
                if segment.last == "" {
                    segment.removeLast()
                } else if newline == "\r\n", let last = segment.last, !last.hasSuffix("\r") {
                    segment[segment.count - 1] += "\r"
                }
            }
            changed += segment
        }
        if lines.last == "" || changed.last == "" || changed.last == "\r" {
            changed.append("")
        } else if newline == "\r\n", changed.last?.hasSuffix("\r") == true {
            changed[changed.count - 1].removeLast()
        }
        replaceLines(changed)
        return identityChanges(from: orderedRecords)
    }

    func property(_ key: String, in record: Record) -> String? {
        var inDrawer = false
        var block: String?
        for raw in lines[(record.line + 1)..<record.bodyEnd] {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = line.uppercased()
            if let active = block {
                if upper == "#+END_" + active { block = nil }
                continue
            }
            if upper.hasPrefix("#+BEGIN_") {
                block = String(upper.dropFirst(8).prefix { !$0.isWhitespace })
                continue
            }
            if upper == ":PROPERTIES:" { inDrawer = true; continue }
            if upper == ":END:" { inDrawer = false; continue }
            let prefix = ":" + key + ":"
            if inDrawer, line.uppercased().hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func validate(_ title: String) throws {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty,
              !title.contains("\n"), !title.contains("\r") else {
            throw OrgError.invalidText
        }
    }

    private func validateBody(_ body: String) throws {
        var block: String?
        for raw in body.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let active = block {
                if trimmed == "#+END_" + active { block = nil }
                continue
            }
            if trimmed.hasPrefix("#+BEGIN_") {
                block = String(trimmed.dropFirst(8).prefix { !$0.isWhitespace })
                continue
            }
            if Self.headingParts(raw) != nil { throw OrgError.invalidBody }
        }
        if block != nil { throw OrgError.invalidBody }
    }

    private func replaceBody(_ body: String, of record: Record, in changed: inout [String]) {
        var replacement = body.isEmpty ? [] : body.components(separatedBy: "\n")
        if record.bodyEnd == lines.count, lines.last == "", replacement.last != "" {
            replacement.append("")
        }
        if newline == "\r\n" {
            replacement = replacement.enumerated().map { index, line in
                if record.bodyEnd == lines.count, index == replacement.count - 1, line.isEmpty {
                    return line
                }
                return line.hasSuffix("\r") ? line : line + "\r"
            }
        }
        changed.replaceSubrange((record.line + 1)..<record.bodyEnd, with: replacement)
    }

    func record(_ id: String) throws -> Record {
        guard let record = records.first(where: { $0.heading.id == id }) else {
            throw OrgError.missingHeading
        }
        return record
    }

    func checkedRecord(_ heading: OrgHeading) throws -> Record {
        let record = try record(heading.id)
        guard roots.lazy.compactMap({ $0.find(heading.id) }).first == heading else {
            throw OrgError.changedExternally
        }
        return record
    }

    private func identityChanges(from previous: [Record], removing removed: Set<String> = []) -> HeadingChanges {
        let pairs = zip(previous.map(\.heading.id), records.map(\.heading.id)).filter { $0 != $1 }
        return HeadingChanges(replacements: Dictionary(uniqueKeysWithValues: pairs), removed: removed)
    }

    private mutating func update(_ id: String, change: (inout OrgHeading) -> Void) throws {
        let record = try record(id)
        var heading = record.heading
        change(&heading)
        var changed = lines
        if heading.state != record.heading.state {
            changed[record.line] = replacingToken(of: record, priority: false, with: heading.state)
        } else if heading.priority != record.heading.priority {
            changed[record.line] = replacingToken(of: record, priority: true,
                                                 with: heading.priority.map { "[#\($0)]" })
        } else {
            return
        }
        replaceLines(changed)
    }

    private func replacingTitle(of record: Record, with title: String) -> String {
        let line = lines[record.line]
        var start = line.index(line.startIndex, offsetBy: record.heading.level)
        func skipSpaces() {
            while start < line.endIndex, line[start] == " " || line[start] == "\t" {
                start = line.index(after: start)
            }
        }
        skipSpaces()
        if let state = record.heading.state {
            start = line.index(start, offsetBy: state.count)
            skipSpaces()
        }
        if let priority = record.heading.priority {
            start = line.index(start, offsetBy: priority.count + 3)
            skipSpaces()
        }
        let end = line.index(start, offsetBy: record.heading.title.count)
        return String(line[..<start]) + title.trimmingCharacters(in: .whitespaces) + String(line[end...])
    }

    private func replacingToken(of record: Record, priority: Bool, with value: String?) -> String {
        let line = lines[record.line]
        var start = line.index(line.startIndex, offsetBy: record.heading.level)
        while start < line.endIndex, line[start] == " " || line[start] == "\t" {
            start = line.index(after: start)
        }
        if priority, let state = record.heading.state {
            start = line.index(start, offsetBy: state.count)
            while start < line.endIndex, line[start] == " " || line[start] == "\t" {
                start = line.index(after: start)
            }
        }
        let old = priority ? record.heading.priority.map { "[#\($0)]" } : record.heading.state
        var end = line.index(start, offsetBy: old?.count ?? 0)
        if value == nil {
            while end < line.endIndex, line[end] == " " || line[end] == "\t" {
                end = line.index(after: end)
            }
        }
        let replacement = value.map { $0 + (old == nil ? " " : "") } ?? ""
        return String(line[..<start]) + replacement + String(line[end...])
    }

    private mutating func insertHeading(title: String, level: Int, at position: Int) throws {
        var changed = lines
        var index = position
        if index == changed.count, changed.last == "" {
            changed.removeLast()
            index -= 1
        }
        if index == changed.count, newline == "\r\n",
           let last = changed.last, !last.hasSuffix("\r") {
            changed[changed.count - 1] += "\r"
        }
        let ending = newline == "\r\n" ? "\r" : ""
        changed.insert(String(repeating: "*", count: level) + " " + title + ending, at: index)
        if index == changed.count - 1 { changed.append("") }
        replaceLines(changed)
    }

    mutating func replaceLines(_ changed: [String]) {
        parse(changed.joined(separator: "\n"))
    }

    private mutating func parse(_ text: String) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        lines = text.components(separatedBy: "\n")
        readStates()
        records = []
        var block: String?
        var paths: [(level: Int, path: String)] = []
        var occurrences: [String: Int] = [:]
        for (index, raw) in lines.enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces).uppercased()
            if let active = block {
                if trimmed == "#+END_" + active { block = nil }
                continue
            }
            if trimmed.hasPrefix("#+BEGIN_") {
                block = String(trimmed.dropFirst(8).prefix { !$0.isWhitespace })
                continue
            }
            guard let parts = Self.headingParts(line) else { continue }
            while let last = paths.last, last.level >= parts.level { paths.removeLast() }
            var title = parts.text
            var state: String?
            if let first = title.split(whereSeparator: \.isWhitespace).first, states.contains(String(first)) {
                state = String(first)
                title = String(title.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
            }
            var priority: String?
            if title.hasPrefix("[#"), let close = title.firstIndex(of: "]") {
                priority = String(title[title.index(title.startIndex, offsetBy: 2)..<close])
                title = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            var tags = ""
            if let range = title.range(of: #"(?:^|\s)(:[\p{L}\p{N}_@#%:]+:)$"#, options: .regularExpression) {
                tags = String(title[range]).trimmingCharacters(in: .whitespaces)
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let identityTitle = title.replacingOccurrences(of: #"\s*\[(?:\d*/\d*|\d*%)\]"#,
                                                          with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let base = (paths.last?.path ?? "") + "/\(identityTitle.utf8.count):\(identityTitle)"
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let path = base + ":\(occurrence)"
            paths.append((parts.level, path))
            let id = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            records.append(Record(heading: OrgHeading(id: id, level: parts.level, title: title,
                                                     state: state, priority: priority, tags: tags,
                                                     body: "", children: []),
                                  line: index, bodyEnd: lines.count, subtreeEnd: lines.count))
        }
        var propertyIDs: Set<String> = []
        for index in records.indices {
            let next = index + 1
            let bodyEnd = next < records.count ? records[next].line : lines.count
            records[index].bodyEnd = bodyEnd
            records[index].heading.body = lines[(records[index].line + 1)..<bodyEnd]
                .joined(separator: "\n")
            if let value = property("ID", in: records[index]),
               !value.isEmpty, propertyIDs.insert(value).inserted {
                records[index].heading.id = "org:" + value
            }
            if let end = records[next...].first(where: { $0.heading.level <= records[index].heading.level }) {
                records[index].subtreeEnd = end.line
            }
        }
        var cursor = 0
        func tree(parentLevel: Int) -> [OrgHeading] {
            var result: [OrgHeading] = []
            while cursor < records.count, records[cursor].heading.level > parentLevel {
                var heading = records[cursor].heading
                cursor += 1
                heading.children = tree(parentLevel: heading.level)
                result.append(heading)
            }
            return result
        }
        roots = tree(parentLevel: 0)
    }

    private mutating func readStates() {
        var all: [String] = []
        var done: Set<String> = []
        var block: String?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = line.uppercased()
            if let active = block {
                if upper == "#+END_" + active { block = nil }
                continue
            }
            if upper.hasPrefix("#+BEGIN_") {
                block = String(upper.dropFirst(8).prefix { !$0.isWhitespace })
                continue
            }
            guard ["#+TODO:", "#+SEQ_TODO:", "#+TYP_TODO:"].contains(where: upper.hasPrefix),
                  let colon = line.firstIndex(of: ":") else { continue }
            let tokens = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace)
            var pastBar = false
            var sequence: [String] = []
            for token in tokens {
                if token == "|" { pastBar = true; continue }
                let word = String(token.prefix { $0 != "(" })
                guard !word.isEmpty else { continue }
                sequence.append(word)
                if !all.contains(word) { all.append(word) }
                if pastBar { done.insert(word) }
            }
            if !pastBar, let last = sequence.last { done.insert(last) }
        }
        states = all.isEmpty ? ["TODO", "DONE"] : all
        doneStates = all.isEmpty ? ["DONE"] : done
        hasStateDeclarations = !all.isEmpty
    }

    private static func headingParts(_ line: String) -> (level: Int, text: String)? {
        let stars = line.prefix { $0 == "*" }.count
        guard stars > 0, stars < line.count else { return nil }
        let separator = line.index(line.startIndex, offsetBy: stars)
        guard line[separator] == " " || line[separator] == "\t" else { return nil }
        return (stars, String(line[separator...]).trimmingCharacters(in: .whitespaces))
    }
}
