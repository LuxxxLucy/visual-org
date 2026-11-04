import Foundation

public struct OrgArchiveLocation {
    public let filename: String
    public let heading: String?
}

public extension OrgDocument {
    func archiving(_ expected: OrgHeading, to targetText: String?, under heading: String?,
                   sourcePath: String, timestamp: String) throws -> (source: OrgDocument, archive: OrgDocument, changes: HeadingChanges) {
        let item = try checkedRecord(expected)
        let archiveText: String
        if let targetText {
            archiveText = targetText
        } else {
            let pending = states.filter { !doneStates.contains($0) }.joined(separator: " ")
            let complete = states.filter { doneStates.contains($0) }.joined(separator: " ")
            archiveText = "#+TITLE: Archive\(newline)#+TODO: \(pending) | \(complete)\(newline)\(newline)"
        }
        let target = OrgDocument(text: archiveText)
        var insertion = target.lines.count
        var targetLines = target.lines
        let targetSuffix = target.newline == "\r\n" ? "\r" : ""
        if targetLines.last != "", let last = targetLines.last, !last.hasSuffix(targetSuffix) {
            targetLines[targetLines.count - 1] += targetSuffix
        }
        if let heading = heading {
            if let parent = target.records.first(where: { $0.heading.level == 1 && $0.heading.title == heading }) {
                insertion = parent.subtreeEnd
            } else {
                if targetLines.last == "" { targetLines.removeLast() }
                targetLines.append("* " + heading + (target.newline == "\r\n" ? "\r" : ""))
                insertion = targetLines.count
            }
        }
        var moved = Array(lines[item.line..<item.subtreeEnd])
        if item.subtreeEnd == lines.count, moved.last == "" { moved.removeLast() }
        let newLevel = heading == nil ? 1 : 2
        for descendant in records where descendant.line >= item.line && descendant.line < item.subtreeEnd {
            let index = descendant.line - item.line
            let level = descendant.heading.level - item.heading.level + newLevel
            moved[index] = String(repeating: "*", count: level)
                + String(moved[index].dropFirst(descendant.heading.level))
        }
        let ancestors = records.filter {
            $0.line < item.line && $0.subtreeEnd > item.line && $0.heading.level < item.heading.level
        }
        let metadata = [
            ("ARCHIVE_TIME", timestamp),
            ("ARCHIVE_FILE", sourcePath),
            ("ARCHIVE_OLPATH", ancestors.map { $0.heading.title }.joined(separator: "/")),
            ("ARCHIVE_TODO", item.heading.state ?? "")
        ]
        moved = moved.map { ($0.hasSuffix("\r") ? String($0.dropLast()) : $0) + targetSuffix }
        try addArchiveProperties(metadata, to: &moved, bodyEnd: item.bodyEnd - item.line, suffix: targetSuffix)
        if insertion == targetLines.count {
            if targetLines.last == "" { targetLines.removeLast(); insertion -= 1 }
            targetLines.insert(contentsOf: moved, at: insertion)
            targetLines.append("")
        } else {
            targetLines.insert(contentsOf: moved, at: insertion)
        }
        let usedStates = Set(records.filter { $0.line >= item.line && $0.line < item.subtreeEnd }
            .compactMap { $0.heading.state })
        let missingStates = states.filter { usedStates.contains($0) && !target.states.contains($0) }
        if !missingStates.isEmpty {
            if targetLines.last == "" { targetLines.removeLast() }
            if !target.hasStateDeclarations {
                targetLines.append("#+TODO: TODO | DONE" + targetSuffix)
            }
            let pending = missingStates.filter { !doneStates.contains($0) }.joined(separator: " ")
            let complete = missingStates.filter { doneStates.contains($0) }.joined(separator: " ")
            targetLines.append("#+TODO: \(pending) | \(complete)" + targetSuffix)
            targetLines.append("")
        }
        var remaining = self
        let changes = remaining.removeSubtree(item)
        return (remaining, OrgDocument(text: targetLines.joined(separator: "\n")), changes)
    }

    func archiveLocation(for id: String? = nil) throws -> OrgArchiveLocation {
        var specification = "%s_archive::"
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
            if upper.hasPrefix("#+ARCHIVE:") {
                specification = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let id {
            let item = try record(id)
            for ancestor in records.reversed() where ancestor.line <= item.line && ancestor.subtreeEnd > item.line {
                if let value = property("ARCHIVE", in: ancestor) {
                    specification = value
                    break
                }
            }
        }
        guard let separator = specification.range(of: "::") else {
            throw OrgError.archiveUnsupported("Use an Org archive location such as %s_archive:: or %s_archive::* Heading.")
        }
        let filename = String(specification[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let location = String(specification[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        var heading: String?
        if !location.isEmpty {
            guard location.hasPrefix("* "), !location.lowercased().contains("datetree/") else {
                throw OrgError.archiveUnsupported("This archive location is unsupported. Use a file or a single top-level heading.")
            }
            heading = String(location.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard heading?.isEmpty == false else {
                throw OrgError.archiveUnsupported("The archive heading needs a title.")
            }
        }
        return OrgArchiveLocation(filename: filename, heading: heading)
    }

    private func addArchiveProperties(_ properties: [(String, String)], to moved: inout [String],
                                      bodyEnd: Int, suffix: String) throws {
        var insertion = 1
        while insertion < min(bodyEnd, moved.count) {
            let line = moved[insertion].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard ["SCHEDULED:", "DEADLINE:", "CLOSED:"].contains(where: line.hasPrefix) else { break }
            insertion += 1
        }
        if insertion < moved.count,
           moved[insertion].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == ":PROPERTIES:" {
            guard let end = (insertion + 1..<min(bodyEnd, moved.count)).first(where: {
                moved[$0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == ":END:"
            }) else {
                throw OrgError.archiveUnsupported("Close the property drawer before archiving this heading.")
            }
            var additions: [String] = []
            for (key, value) in properties {
                if let index = (insertion + 1..<end).first(where: {
                    moved[$0].trimmingCharacters(in: .whitespaces).uppercased().hasPrefix(":" + key + ":")
                }) {
                    moved[index] = ":\(key): \(value)" + suffix
                } else {
                    additions.append(":\(key): \(value)" + suffix)
                }
            }
            moved.insert(contentsOf: additions, at: end)
        } else {
            let drawer = [":PROPERTIES:" + suffix]
                + properties.map { ":\($0.0): \($0.1)" + suffix }
                + [":END:" + suffix]
            moved.insert(contentsOf: drawer, at: insertion)
        }
    }

}
