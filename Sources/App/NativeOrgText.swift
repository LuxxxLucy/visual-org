import AppKit
import OrgCore

@MainActor
enum NativeOrgText {
    static func attributed(_ text: String, font: NSFont, color: NSColor, documentURL: URL? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for span in OrgMarkup.spans(text) {
            var content = span.text
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            switch span.style {
            case .plain: break
            case .bold: attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            case .italic: attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            case .underline: attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .strike: attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .code: attributes[.font] = NSFont.monospacedSystemFont(ofSize: max(1, font.pointSize - 1), weight: .regular)
            case .link(let target):
                if let link = OrgLinks.link(target, documentURL: documentURL) {
                    attributes[.link] = link
                    attributes[.foregroundColor] = NSColor.linkColor
                } else {
                    content = span.text == target ? "[[\(target)]]" : "[[\(target)][\(span.text)]]"
                }
            }
            result.append(NSAttributedString(string: content, attributes: attributes))
        }
        return result
    }

    static func notes(_ text: String, documentURL: URL?,
                      color: NSColor = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let font = NSFont.systemFont(ofSize: 13)
        for (index, row) in OrgMarkup.rows(text).enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: color])) }
            let start = result.length
            if row.kind == .literal {
                result.append(NSAttributedString(string: row.text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: color,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.045)
                ]))
            } else if row.kind == .space {
                result.append(NSAttributedString(string: row.text, attributes: [.font: font, .foregroundColor: color]))
            } else {
                if let marker = row.marker {
                    result.append(NSAttributedString(string: marker + " ", attributes: [.font: font, .foregroundColor: color]))
                }
                result.append(attributed(row.text, font: font, color: color, documentURL: documentURL))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 5
            paragraph.lineSpacing = 3
            paragraph.firstLineHeadIndent = CGFloat(min(row.indent, 16)) * 4
            paragraph.headIndent = paragraph.firstLineHeadIndent + (row.marker == nil ? 0 : 14)
            result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: result.length - start))
        }
        return result
    }
}
