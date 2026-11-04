import Combine
import OrgCore

@MainActor
final class DetailsDraft: ObservableObject {
    @Published private(set) var original: OrgHeading?
    @Published var title = ""
    @Published var body = ""

    var isDirty: Bool {
        guard let original else { return false }
        return title != original.title || body != original.body
    }

    func synchronize(_ heading: OrgHeading?) {
        guard !isDirty else { return }
        reset(heading)
    }

    func reset(_ heading: OrgHeading?) {
        guard original != heading || isDirty else { return }
        original = heading
        title = heading?.title ?? ""
        body = heading?.body ?? ""
    }
}
