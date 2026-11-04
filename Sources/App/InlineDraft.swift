import Foundation
import OrgCore

@MainActor
final class InlineDraft {
    enum Key: Hashable {
        case title(String)
        case checkbox(String, Int)
    }

    enum Target {
        case title(OrgHeading)
        case checkbox(String, OrgCheckbox)

        var key: Key {
            switch self {
            case .title(let heading): .title(heading.id)
            case .checkbox(let id, let item): .checkbox(id, item.id)
            }
        }

        var original: String {
            switch self {
            case .title(let heading): heading.title
            case .checkbox(_, let item): item.title
            }
        }
    }

    private struct Session {
        let target: Target
        var text: String
        let documentID: UUID
        let rootID: String
    }

    private var session: Session?
    var target: Target? { session?.target }
    var text: String { session?.text ?? "" }
    var documentID: UUID? { session?.documentID }
    var rootID: String? { session?.rootID }
    var key: Key? { target?.key }
    var isDirty: Bool { target.map { text != $0.original } ?? false }

    func begin(_ target: Target, documentID: UUID, rootID: String) {
        session = Session(target: target, text: target.original, documentID: documentID, rootID: rootID)
    }

    func update(_ text: String) { session?.text = text }

    func clear() {
        session = nil
    }
}
