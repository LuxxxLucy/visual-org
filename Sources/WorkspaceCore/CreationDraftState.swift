import OrgCore

public enum DraftError: Error {
    case identityConflict
}

public struct CreationDraftState {
    private struct Draft {
        var checkbox = ""
        var heading = ""
        var isEmpty: Bool { checkbox.isEmpty && heading.isEmpty }
    }

    private var drafts: [String: Draft] = [:]

    public init() {}

    public var hasUnsavedEdits: Bool { !drafts.isEmpty }

    public subscript(checkbox id: String) -> String {
        get { drafts[id]?.checkbox ?? "" }
        set {
            drafts[id, default: Draft()].checkbox = newValue
            if drafts[id]?.isEmpty == true { drafts.removeValue(forKey: id) }
        }
    }

    public subscript(heading id: String) -> String {
        get { drafts[id]?.heading ?? "" }
        set {
            drafts[id, default: Draft()].heading = newValue
            if drafts[id]?.isEmpty == true { drafts.removeValue(forKey: id) }
        }
    }

    public mutating func clear() { drafts.removeAll() }

    public func apply(to document: inout OrgDocument) throws {
        for id in drafts.keys.sorted() {
            guard let draft = drafts[id] else { continue }
            if !draft.checkbox.isEmpty { try document.addCheckbox(id, title: draft.checkbox) }
            if !draft.heading.isEmpty { try document.addChild(id, title: draft.heading) }
        }
    }

    public mutating func remap(_ mapping: [String: String], removing removedIDs: Set<String> = []) throws {
        var updated: [String: Draft] = [:]
        for (id, draft) in drafts where !removedIDs.contains(id) {
            let target = mapping[id] ?? id
            guard updated[target] == nil else { throw DraftError.identityConflict }
            updated[target] = draft
        }
        drafts = updated
    }
}
