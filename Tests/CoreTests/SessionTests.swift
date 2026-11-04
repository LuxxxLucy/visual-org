import Foundation
import OrgCore
import WorkspaceCore

struct SessionTests {
    static func run() throws {
        let tests = SessionTests()
        try tests.testStaleSavePreservesExternalSourceAndModel()
        try tests.testEditCommitsOnceAndPreservesStateOnFailure()
        try tests.testEditRejectsChangedSessionDuringOperation()
        try tests.testArchiveWriteFailureRestoresExistingArchive()
        try tests.testArchiveWriteFailureRemovesNewArchive()
        try tests.testFailedArchiveRollbackPreservesWrittenArchiveAndReportsPath()
        try tests.testRenameMapsDuplicateParentsAndTheirChildren()
        try tests.testDeleteNestedSubtreePreservesSurroundingText()
        try tests.testDeleteDuplicateRootMapsSurvivors()
        try tests.testDeleteLastRootPreservesExactPrefix()
        try tests.testDeleteRejectsMissingChangedAndExternalTargets()
    }

    private let sourceURL = URL(fileURLWithPath: "/virtual/visual-org/session.org")
    private let source = "* TODO Parent\nKeep source.\n** Child\nKeep child.\n* Other\nKeep other.\n"
    private let timestamp = "[2026-10-24 Sat 10:30]"

    func testStaleSavePreservesExternalSourceAndModel() throws {
        let files = MemoryFiles([sourceURL: Data(source.utf8)])
        let session = OrgSessionModel(files: files)
        try session.open(sourceURL)
        let originalRoots = session.roots
        let external = Data((source + "External text.\n").utf8)
        files.contents[sourceURL] = external

        try throwsError({ try session.edit { try $0.setState(originalRoots[0].id, "DONE") } }) { error in
            guard case OrgError.changedExternally = error else {
                try check(false)
                return
            }
        }
        try equal(files.contents[sourceURL], external)
        try equal(session.roots, originalRoots)
        try check(files.writes.isEmpty)

        try session.checkForExternalChanges(reload: false)
        try check(session.changedOnDisk)
        try equal(session.roots, originalRoots)
        try session.checkForExternalChanges(reload: true)
        try check(!session.changedOnDisk)
        try equal(session.roots, OrgDocument(text: String(decoding: external, as: UTF8.self)).roots)
    }

    func testEditCommitsOnceAndPreservesStateOnFailure() throws {
        let files = MemoryFiles([sourceURL: Data(source.utf8)])
        let session = OrgSessionModel(files: files)
        try session.open(sourceURL)
        let id = session.roots[0].id
        var notifications = 0
        session.onChange = { notifications += 1 }
        let priority = try session.edit { document in
            try document.setState(id, "DONE")
            try document.setPriority(id, "B")
            return document.roots[0].priority
        }
        try equal(priority, "B")
        try equal(files.writes.count, 1)
        try equal(notifications, 1)
        let saved = try unwrap(files.contents[sourceURL])
        try equal(saved, Data(source.replacingOccurrences(of: "* TODO Parent", with: "* DONE [#B] Parent").utf8))
        let roots = session.roots
        files.writes.removeAll()
        try throwsError({ try session.edit { document in
            try document.setState(id, "TODO")
            throw MemoryFiles.Failure.write
        } }) { error in try equal(error as? MemoryFiles.Failure, .write) }
        try check(files.writes.isEmpty)
        try equal(session.roots, roots)
        try equal(files.contents[sourceURL], saved)
        files.rejectWrite = { _, _ in true }
        try throwsError({ try session.edit { try $0.setPriority(id, "A") } }) { error in
            try equal(error as? MemoryFiles.Failure, .write)
        }
        try equal(session.roots, roots)
        try equal(files.contents[sourceURL], saved)
        try equal(notifications, 1)
    }

    func testEditRejectsChangedSessionDuringOperation() throws {
        let otherURL = sourceURL.deletingLastPathComponent().appendingPathComponent("other.org")
        let original = Data(source.utf8)
        let files = MemoryFiles([sourceURL: original, otherURL: original])
        let session = OrgSessionModel(files: files)
        try session.open(sourceURL)
        let id = session.roots[0].id
        var notifications = 0
        session.onChange = { notifications += 1 }
        try throwsError({ try session.edit { document in
            try document.setPriority(id, "A")
            try session.edit { try $0.setState(id, "DONE") }
        } }) { error in
            guard case OrgError.changedExternally = error else { try check(false); return }
        }
        let committed = Data(source.replacingOccurrences(of: "* TODO Parent", with: "* DONE Parent").utf8)
        try equal(files.contents[sourceURL], committed)
        try equal(session.roots, OrgDocument(text: String(decoding: committed, as: UTF8.self)).roots)
        try equal(files.writes.count, 1)
        try equal(notifications, 1)

        try session.open(otherURL)
        files.writes.removeAll()
        try throwsError({ try session.edit { document in
            try document.setPriority(id, "A")
            files.contents[sourceURL] = original
            try session.open(sourceURL)
        } }) { error in
            guard case OrgError.changedExternally = error else { try check(false); return }
        }
        try equal(session.url, sourceURL)
        try equal(session.roots, OrgDocument(text: source).roots)
        try equal(files.contents[otherURL], original)
        try check(files.writes.isEmpty)
    }

    func testArchiveWriteFailureRestoresExistingArchive() throws {
        let files = MemoryFiles([sourceURL: Data(source.utf8)])
        let session = OrgSessionModel(files: files)
        try session.open(sourceURL)
        let originalRoots = session.roots
        let archiveURL = try session.archiveURL(for: originalRoots[0].id)
        let originalArchive = Data("#+TITLE: Archive\r\n* DONE Existing\r\nKeep archive.\r\n".utf8)
        files.contents[archiveURL] = originalArchive
        files.rejectWrite = { url, _ in url == self.sourceURL }

        try throwsError({ try session.archive(originalRoots[0], timestamp: timestamp) }) { error in
            try equal(error as? MemoryFiles.Failure, .write)
        }
        try equal(files.contents[sourceURL], Data(source.utf8))
        try equal(files.contents[archiveURL], originalArchive)
        try equal(session.roots, originalRoots)
        try equal(files.writes.map(\.url), [archiveURL, sourceURL, archiveURL])
        try equal(files.writes.last?.data, originalArchive)
        try equal(files.coordinatedPairs.count, 1)
        try equal(files.coordinatedPairs.first?.0, sourceURL)
        try equal(files.coordinatedPairs.first?.1, archiveURL)
    }

    func testArchiveWriteFailureRemovesNewArchive() throws {
        let files = MemoryFiles([sourceURL: Data(source.utf8)])
        let session = OrgSessionModel(files: files)
        try session.open(sourceURL)
        let originalRoots = session.roots
        let archiveURL = try session.archiveURL(for: originalRoots[0].id)
        files.rejectWrite = { url, _ in url == self.sourceURL }

        try throwsError({ try session.archive(originalRoots[0], timestamp: timestamp) }) { error in
            try equal(error as? MemoryFiles.Failure, .write)
        }
        try equal(files.contents[sourceURL], Data(source.utf8))
        try check(files.contents[archiveURL] == nil)
        try equal(files.removals, [archiveURL])
        try equal(session.roots, originalRoots)
    }

    func testFailedArchiveRollbackPreservesWrittenArchiveAndReportsPath() throws {
        let files = MemoryFiles([sourceURL: Data(source.utf8)])
        let session = OrgSessionModel(files: files)
        try session.open(sourceURL)
        let originalRoots = session.roots
        let archiveURL = try session.archiveURL(for: originalRoots[0].id)
        let originalArchive = Data("* DONE Existing\nKeep archive.\n".utf8)
        files.contents[archiveURL] = originalArchive
        files.rejectWrite = { url, data in
            url == self.sourceURL || (url == archiveURL && data == originalArchive)
        }

        try throwsError({ try session.archive(originalRoots[0], timestamp: timestamp) }) { error in
            guard case OrgSessionError.archiveRollback(let path) = error else {
                try check(false)
                return
            }
            try equal(path, archiveURL.path)
        }
        try equal(files.contents[sourceURL], Data(source.utf8))
        try equal(session.roots, originalRoots)
        let writtenArchive = try unwrap(files.writes.first?.data)
        try equal(files.contents[archiveURL], writtenArchive)
        let expectedArchive = "* DONE Existing\nKeep archive.\n* TODO Parent\n:PROPERTIES:\n:ARCHIVE_TIME: \(timestamp)\n:ARCHIVE_FILE: \(sourceURL.path)\n:ARCHIVE_OLPATH: \n:ARCHIVE_TODO: TODO\n:END:\nKeep source.\n** Child\nKeep child.\n"
        try equal(writtenArchive, Data(expectedArchive.utf8))
        let archivedText = String(decoding: writtenArchive, as: UTF8.self)
        try check(archivedText.hasPrefix(String(decoding: originalArchive, as: UTF8.self)))
        let archivedRoots = OrgDocument(text: archivedText).roots
        try equal(archivedRoots.map(\.title), ["Existing", "Parent"])
        try equal(archivedRoots[1].state, "TODO")
        try check(archivedRoots[1].body.contains("Keep source."))
        try equal(archivedRoots[1].children.map(\.title), ["Child"])
        try check(archivedRoots[1].children[0].body.contains("Keep child."))
    }

    func testRenameMapsDuplicateParentsAndTheirChildren() throws {
        let text = "* First\nFirst body.\n** Child\nFirst child.\n* Duplicate\nSecond body.\n** Child\nSecond child.\n"
        let files = MemoryFiles([sourceURL: Data(text.utf8)])
        let session = OrgSessionModel(files: files)
        try session.open(sourceURL)
        let before = session.roots
        let update = try session.edit { try $0.updateDetails(before[0].id, title: "Duplicate", body: before[0].body,
                                               expectedTitle: before[0].title, expectedBody: before[0].body) }
        let after = session.roots
        try equal((update.replacements[before[0].id] ?? before[0].id), after[0].id)
        try equal(update.replacements, [
            before[0].id: after[0].id,
            before[0].children[0].id: after[0].children[0].id,
            before[1].id: after[1].id,
            before[1].children[0].id: after[1].children[0].id
        ])
        try equal(files.contents[sourceURL], Data(text.replacingOccurrences(of: "* First\n", with: "* Duplicate\n").utf8))
        try session.open(sourceURL)
        try equal(session.roots, after)
    }

    func testDeleteNestedSubtreePreservesSurroundingText() throws {
        for newline in ["\n", "\r\n"] {
            let prefix = "#+TITLE: Keep\n* Parent\nNotes.\n".replacingOccurrences(of: "\n", with: newline)
            let removed = "** Child\nRemove this.\n*** Grandchild\nRemove this too.\n".replacingOccurrences(of: "\n", with: newline)
            let suffix = "** Sibling\nKeep child.\n\n* Other\nKeep end.".replacingOccurrences(of: "\n", with: newline)
            let files = MemoryFiles([sourceURL: Data((prefix + removed + suffix).utf8)])
            let session = OrgSessionModel(files: files)
            try session.open(sourceURL)
            let child = session.roots[0].children[0]
            let update = try session.edit { try $0.delete(child) }
            try equal(files.contents[sourceURL], Data((prefix + suffix).utf8))
            try equal(update.removed, Set([child.id, child.children[0].id]))
            try check(update.replacements.isEmpty)
            try equal(session.roots[0].children.map(\.title), ["Sibling"])
            let after = session.roots
            try session.open(sourceURL)
            try equal(session.roots, after)
        }
    }

    func testDeleteDuplicateRootMapsSurvivors() throws {
        let removed = "* Duplicate\nFirst.\n** Child\nFirst child.\n"
        let survivor = "* Duplicate\nSecond.\n** Child\nSecond child.\n"
        let files = MemoryFiles([sourceURL: Data((removed + survivor).utf8)])
        let session = OrgSessionModel(files: files)
        try session.open(sourceURL)
        let before = session.roots
        let update = try session.edit { try $0.delete(before[0]) }
        let after = session.roots[0]
        try equal(update.replacements, [before[1].id: after.id, before[1].children[0].id: after.children[0].id])
        try equal(update.removed, Set([before[0].id, before[0].children[0].id]))
        try equal(files.contents[sourceURL], Data(survivor.utf8))
    }

    func testDeleteLastRootPreservesExactPrefix() throws {
        for newline in ["\n", "\r\n"] {
            for prefix in ["", "#+TITLE: Keep\n", "* Keep\nNotes.\n\n"].map({ $0.replacingOccurrences(of: "\n", with: newline) }) {
                for ending in ["", newline] {
                    let removed = "* Remove\n** Child\nEnd".replacingOccurrences(of: "\n", with: newline) + ending
                    let files = MemoryFiles([sourceURL: Data((prefix + removed).utf8)])
                    let session = OrgSessionModel(files: files)
                    try session.open(sourceURL)
                    let last = try unwrap(session.roots.last)
                    _ = try session.edit { try $0.delete(last) }
                    try equal(files.contents[sourceURL], Data(prefix.utf8))
                }
            }
        }
    }

    func testDeleteRejectsMissingChangedAndExternalTargets() throws {
        var document = OrgDocument(text: source)
        try throwsError({ try document.delete(OrgDocument(text: "* Missing\n").roots[0]) }) { error in
            guard case OrgError.missingHeading = error else { try check(false); return }
        }
        try equal(document.text, source)

        let files = MemoryFiles([sourceURL: Data(source.utf8)])
        let session = OrgSessionModel(files: files)
        try session.open(sourceURL)
        let selected = session.roots[0]
        try session.edit { try $0.setPriority(selected.id, "A") }
        let changed = try unwrap(files.contents[sourceURL])
        files.writes.removeAll()
        try throwsError({ try session.edit { try $0.delete(selected) } }) { error in
            guard case OrgError.changedExternally = error else { try check(false); return }
        }
        try equal(files.contents[sourceURL], changed)
        try check(files.writes.isEmpty)

        let fresh = session.roots[0]
        let external = changed + Data("External edit.\n".utf8)
        files.contents[sourceURL] = external
        try throwsError({ try session.edit { try $0.delete(fresh) } }) { error in
            guard case OrgError.changedExternally = error else { try check(false); return }
        }
        try equal(files.contents[sourceURL], external)
        try equal(session.roots[0], fresh)
        try check(files.writes.isEmpty)

        files.contents[sourceURL] = changed
        _ = try session.edit { try $0.delete(fresh) }
        let remaining = try unwrap(files.contents[sourceURL])
        files.writes.removeAll()
        try throwsError({ try session.edit { try $0.delete(fresh) } }) { error in
            guard case OrgError.missingHeading = error else { try check(false); return }
        }
        try equal(files.contents[sourceURL], remaining)
        try check(files.writes.isEmpty)
    }
}

private final class MemoryFiles: FileAccess {
    enum Failure: Error, Equatable { case write }

    var contents: [URL: Data]
    var writes: [(url: URL, data: Data)] = []
    var removals: [URL] = []
    var coordinatedPairs: [(URL, URL)] = []
    var rejectWrite: (URL, Data) -> Bool = { _, _ in false }
    private var coordinated = Set<URL>()

    init(_ contents: [URL: Data]) { self.contents = contents }

    func resolve(_ url: URL) -> URL { url.standardizedFileURL }

    func resolveArchivePath(_ path: String, relativeTo source: URL) -> URL? {
        guard !path.isEmpty else { return nil }
        return resolve(path.hasPrefix("/") ? URL(fileURLWithPath: path)
                       : source.deletingLastPathComponent().appendingPathComponent(path))
    }

    func read(_ url: URL) throws -> Data? { contents[url] }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try check(coordinated.contains(url))
        writes.append((url, data))
        if rejectWrite(url, data) { throw Failure.write }
        contents[url] = data
    }

    func remove(_ url: URL) throws {
        try check(coordinated.contains(url))
        removals.append(url)
        contents.removeValue(forKey: url)
    }

    func coordinateWrite(at url: URL, _ operation: (URL) throws -> Void) throws {
        coordinated = [url]
        defer { coordinated = [] }
        try operation(url)
    }

    func coordinateWrite(at source: URL, and target: URL, _ operation: (URL, URL) throws -> Void) throws {
        coordinatedPairs.append((source, target))
        coordinated = [source, target]
        defer { coordinated = [] }
        try operation(source, target)
    }
}
