import OrgCore

struct ProjectCard: Equatable {
    let heading: OrgHeading
    let color: Int
    let expanded: Bool
    let selectedID: String?
    let searchQuery: String
    let revision: Int

}
