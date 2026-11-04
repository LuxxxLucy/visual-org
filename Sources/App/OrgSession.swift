import Foundation
import OrgCore
import WorkspaceCore

typealias OrgSession = OrgSessionModel

extension OrgSessionModel {
    convenience init() {
        self.init(files: MacFileAccess())
    }

    func archive(_ heading: OrgHeading) throws -> (url: URL, changes: HeadingChanges) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "[yyyy-MM-dd EEE HH:mm]"
        return try archive(heading, timestamp: formatter.string(from: Date()))
    }
}
