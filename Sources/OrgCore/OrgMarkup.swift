import Foundation

public enum OrgMarkup {
    public enum Kind { case prose, literal, space }
    public struct Row {
        public var text: String
        public var kind: Kind = .prose
        public var marker: String? = nil
        public var indent = 0
    }

    public static func rows(_ text: String) -> [Row] {
        var result: [Row] = []
        var block: String?
        var literal: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()
            if let name = block {
                literal.append(line)
                if upper == "#+END_" + name {
                    result.append(Row(text: literal.joined(separator: "\n"), kind: .literal))
                    literal = []; block = nil
                }
                continue
            }
            if upper.hasPrefix("#+BEGIN_") {
                block = String(upper.dropFirst(8).prefix(while: { !$0.isWhitespace }))
                literal = [line]
                continue
            }
            if upper.hasPrefix("#+") || trimmed.hasPrefix(":") {
                result.append(Row(text: line, kind: .literal))
                continue
            }
            if trimmed.isEmpty {
                result.append(Row(text: line, kind: .space))
                continue
            }
            if trimmed.hasPrefix("|") {
                result.append(Row(text: trimmed, kind: .literal))
                continue
            }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let match = trimmed.range(of: #"^(?:[-+*]|[0-9]+[.)])\s+"#, options: .regularExpression) {
                let prefix = String(trimmed[match]).trimmingCharacters(in: .whitespaces)
                let content = String(trimmed[match.upperBound...])
                result.append(Row(text: content, marker: ["-", "+", "*"].contains(prefix) ? "•" : prefix, indent: indent))
            } else {
                result.append(Row(text: trimmed, indent: indent))
            }
        }
        if block != nil { result.append(Row(text: literal.joined(separator: "\n"), kind: .literal)) }
        return result
    }

    private static let pattern = try! NSRegularExpression(pattern:
        #"\[\[([^\]\n]+)\](?:\[([^\]\n]*)\])?\]|(?:https?://|mailto:)[^\s<>\[\]]+|(?<![\p{L}\p{N}])([*/_+=~])([^\s\n](?:[^\n]*?[^\s\n])?)\3(?![\p{L}\p{N}])"#)

    public enum Style {
        case plain, bold, italic, underline, strike, code
        case link(target: String)
    }

    public struct Span {
        public let text: String
        public let style: Style
    }

    public static func spans(_ text: String) -> [Span] {
        let source = text as NSString
        var output: [Span] = []
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if match.range.location > cursor {
                output.append(Span(text: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), style: .plain))
            }
            let value = source.substring(with: match.range)
            if match.range(at: 1).location != NSNotFound {
                let target = source.substring(with: match.range(at: 1))
                let label = match.range(at: 2).location == NSNotFound ? target : source.substring(with: match.range(at: 2))
                output.append(Span(text: label, style: .link(target: target)))
            } else if match.range(at: 3).location != NSNotFound {
                let marker = source.substring(with: match.range(at: 3))
                let content = source.substring(with: match.range(at: 4))
                let style: Style
                switch marker {
                case "*": style = .bold
                case "/": style = .italic
                case "_": style = .underline
                case "+": style = .strike
                case "=", "~": style = .code
                default: style = .plain
                }
                output.append(Span(text: content, style: style))
            } else {
                let target = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
                output.append(Span(text: target, style: .link(target: target)))
                let suffix = String(value.dropFirst(target.count))
                if !suffix.isEmpty { output.append(Span(text: suffix, style: .plain)) }
            }
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length { output.append(Span(text: source.substring(from: cursor), style: .plain)) }
        return output
    }
}
