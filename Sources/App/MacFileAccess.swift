import Foundation
import WorkspaceCore

struct MacFileAccess: FileAccess {
    func resolve(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func resolveArchivePath(_ path: String, relativeTo source: URL) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        let target = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : source.deletingLastPathComponent().appendingPathComponent(expanded)
        return resolve(target)
    }

    func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func coordinateWrite(at url: URL, _ operation: (URL) throws -> Void) throws {
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { target in
            do { try operation(target) } catch { failure = error }
        }
        if let failure { throw failure }
        if let coordinationError { throw coordinationError }
    }

    func coordinateWrite(at source: URL, and target: URL, _ operation: (URL, URL) throws -> Void) throws {
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forReplacing,
            writingItemAt: target, options: .forReplacing, error: &coordinationError
        ) { sourceURL, targetURL in
            do { try operation(sourceURL, targetURL) } catch { failure = error }
        }
        if let failure { throw failure }
        if let coordinationError { throw coordinationError }
    }
}
