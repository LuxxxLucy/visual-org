import Foundation

struct CardRowKey: Hashable {
    enum Kind: Hashable {
        case heading
        case notes(Int)
        case checkbox(Int)
        case entry
    }

    var headingID: String
    let kind: Kind

    func remapped(_ mapping: [String: String]) -> Self {
        Self(headingID: mapping[headingID] ?? headingID, kind: kind)
    }
}

@MainActor
final class CardRowTarget {
    var key: CardRowKey

    init(_ key: CardRowKey) { self.key = key }

    var inlineKey: InlineDraft.Key? {
        switch key.kind {
        case .heading: return .title(key.headingID)
        case .checkbox(let line): return .checkbox(key.headingID, line)
        default: return nil
        }
    }
}
