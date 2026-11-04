import Foundation
import OrgCore

enum OrgLinks {
    static func links(_ text: String, documentURL: URL?) -> [(label: String, url: URL)] {
        OrgMarkup.spans(text).compactMap { span in
            guard case .link(let target) = span.style, let url = link(target, documentURL: documentURL) else { return nil }
            return (label: span.text, url: url)
        }
    }

    static func link(_ target: String, documentURL: URL?) -> URL? {
        if target.hasPrefix("file:") && !target.hasPrefix("file://") {
            let path = String(target.dropFirst(5)).removingPercentEncoding ?? String(target.dropFirst(5))
            if path.hasPrefix("/") || path.hasPrefix("~") {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            return documentURL?.deletingLastPathComponent().appendingPathComponent(path)
        }
        guard let url = URL(string: target), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "file"].contains(scheme) else { return nil }
        return url
    }
}
