import Foundation

public protocol FileAccess {
    func resolve(_ url: URL) -> URL
    func resolveArchivePath(_ path: String, relativeTo source: URL) -> URL?
    func read(_ url: URL) throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) throws
    func remove(_ url: URL) throws
    func coordinateWrite(at url: URL, _ operation: (URL) throws -> Void) throws
    func coordinateWrite(at source: URL, and target: URL, _ operation: (URL, URL) throws -> Void) throws
}
