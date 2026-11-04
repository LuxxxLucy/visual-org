import Foundation

public enum OrgPlanningKind: String, CaseIterable {
    case scheduled = "SCHEDULED"
    case deadline = "DEADLINE"
}

public enum OrgPlanningError: LocalizedError {
    case invalidTimestamp
    public var errorDescription: String? {
        "Enter an active Org timestamp, such as <2026-10-24 Sat 09:00>."
    }
}

private let planningFields = try! NSRegularExpression(
    pattern: #"(?<!\S)(SCHEDULED|DEADLINE|CLOSED):[ \t]*(<[^>\r\n]*>|\[[^\]\r\n]*\])"#)

public extension OrgHeading {
    func planning(_ kind: OrgPlanningKind) -> String? {
        let first = (body.components(separatedBy: "\n").first ?? "") as NSString
        let fields = planningFields.matches(in: first as String, range: NSRange(location: 0, length: first.length))
        guard let leading = fields.first,
              first.substring(to: leading.range.location).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return fields
            .first { first.substring(with: $0.range(at: 1)) == kind.rawValue }
            .map { first.substring(with: $0.range(at: 2)) }
    }
}

public extension OrgDocument {
    mutating func setPlanning(_ id: String, kind: OrgPlanningKind, timestamp: String?, expectedBody: String) throws {
        if let timestamp { try validatePlanningTimestamp(timestamp) }
        let record = try record(id)
        guard record.heading.body == expectedBody else { throw OrgError.changedExternally }
        var changed = lines
        let index = record.line + 1
        let original = index < record.bodyEnd ? changed[index] : ""
        let source = original as NSString
        let fields = planningFields.matches(in: original, range: NSRange(location: 0, length: source.length))
        let isPlanning = fields.first.map {
            source.substring(to: $0.range.location).trimmingCharacters(in: .whitespaces).isEmpty
        } ?? false
        if isPlanning {
            let line = NSMutableString(string: original)
            var replaced = false
            for field in fields.reversed() {
                let keyword = source.substring(with: field.range(at: 1))
                if keyword == kind.rawValue {
                    line.replaceCharacters(in: field.range, with: timestamp.map { kind.rawValue + ": " + $0 } ?? "")
                    replaced = true
                } else if keyword == "CLOSED", timestamp != nil {
                    line.deleteCharacters(in: field.range)
                }
            }
            if let timestamp, !replaced {
                line.insert(kind.rawValue + ": " + timestamp + " ", at: 0)
            }
            if (line as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                changed.remove(at: index)
            } else { changed[index] = line as String }
        } else if let timestamp {
            if index == changed.count, newline == "\r\n", !changed[record.line].hasSuffix("\r") {
                changed[record.line] += "\r"
            }
            changed.insert(kind.rawValue + ": " + timestamp + (newline == "\r\n" && index < changed.count ? "\r" : ""), at: index)
        } else { return }
        replaceLines(changed)
    }
}

private func validatePlanningTimestamp(_ timestamp: String) throws {
    let pattern = #"^<([0-9]{4})-([0-9]{2})-([0-9]{2})(?: [\p{L}.]+)?(?: (?:[01][0-9]|2[0-3]):[0-5][0-9](?:-(?:[01][0-9]|2[0-3]):[0-5][0-9])?)?(?: (?:\+\+|\.\+|\+)[0-9]+[hdwmy](?:/[0-9]+[hdwmy])?)?(?: -{1,2}[0-9]+[hdwmy])?>$"#
    let expression = try! NSRegularExpression(pattern: pattern)
    let source = timestamp as NSString
    guard !timestamp.contains("\n"), !timestamp.contains("\r"),
          let match = expression.firstMatch(in: timestamp, range: NSRange(location: 0, length: source.length)) else {
        throw OrgPlanningError.invalidTimestamp
    }
    let year = Int(source.substring(with: match.range(at: 1)))!
    let month = Int(source.substring(with: match.range(at: 2)))!
    let day = Int(source.substring(with: match.range(at: 3)))!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(year: year, month: month, day: day)
    guard year > 0, let date = calendar.date(from: components),
          calendar.dateComponents([.year, .month, .day], from: date) == components else {
        throw OrgPlanningError.invalidTimestamp
    }
}
