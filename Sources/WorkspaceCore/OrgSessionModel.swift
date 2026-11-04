import Foundation
import OrgCore

public enum OrgSessionError: LocalizedError {
    case unopened, unsupportedEncoding, archiveRollback(String)

    public var errorDescription: String? {
        switch self {
        case .unopened: "Open an Org file first."
        case .unsupportedEncoding: "The Org file must use UTF-8 text."
        case .archiveRollback(let path): "The source could not be saved. The archive copy remains at \(path). Reload both files before trying again."
        }
    }
}

public final class OrgSessionModel {
    public var onChange: (() -> Void)?
    private var document = OrgDocument(text: "")
    public private(set) var changedOnDisk = false
    public private(set) var url: URL?
    private var source = Data()
    private let files: any FileAccess

    public init(files: any FileAccess) {
        self.files = files
    }

    public var roots: [OrgHeading] { document.roots }
    public var preamble: String { document.preamble }
    public var states: [String] { document.states }
    public var doneStates: Set<String> { document.doneStates }

    public func open(_ url: URL) throws {
        let resolved = files.resolve(url)
        let bytes = try readRequired(resolved)
        let loaded = OrgDocument(text: try decode(bytes))
        accept(loaded, bytes: bytes, url: resolved)
    }

    public func checkForExternalChanges(reload: Bool) throws {
        guard let url else { return }
        let bytes = try readRequired(url)
        guard bytes != source else {
            setChangedOnDisk(false)
            return
        }
        guard reload else { setChangedOnDisk(true); return }
        do {
            let loaded = OrgDocument(text: try decode(bytes))
            accept(loaded, bytes: bytes, url: url)
        } catch {
            setChangedOnDisk(true)
            throw error
        }
    }

    public func archiveURL(for id: String? = nil) throws -> URL {
        try archiveDestination(for: id).url
    }

    public func archive(_ heading: OrgHeading, timestamp: String) throws -> (url: URL, changes: HeadingChanges) {
        guard let url else { throw OrgSessionError.unopened }
        let destination = try archiveDestination(for: heading.id)
        var updated: (document: OrgDocument, bytes: Data, changes: HeadingChanges)?
        try files.coordinateWrite(at: url, and: destination.url) { sourceURL, targetURL in
            guard try readRequired(sourceURL) == source else { throw OrgError.changedExternally }
            let original = try files.read(targetURL)
            let targetText = try original.map { try decode($0) }
            let plan = try document.archiving(heading, to: targetText, under: destination.heading,
                                              sourcePath: url.path, timestamp: timestamp)
            let archived = Data(plan.archive.text.utf8)
            let remaining = Data(plan.source.text.utf8)
            guard try files.read(targetURL) == original else { throw OrgError.changedExternally }
            try files.writeAtomically(archived, to: targetURL)
            do {
                guard try readRequired(sourceURL) == source else { throw OrgError.changedExternally }
                try files.writeAtomically(remaining, to: sourceURL)
            } catch {
                let sourceError = error
                do {
                    guard try files.read(targetURL) == archived else {
                        throw OrgSessionError.archiveRollback(targetURL.path)
                    }
                    if let original {
                        try files.writeAtomically(original, to: targetURL)
                    } else {
                        try files.remove(targetURL)
                    }
                } catch {
                    throw OrgSessionError.archiveRollback(targetURL.path)
                }
                throw sourceError
            }
            updated = (plan.source, remaining, plan.changes)
        }
        guard let updated else { throw CocoaError(.fileWriteUnknown) }
        accept(updated.document, bytes: updated.bytes, url: url)
        return (destination.url, updated.changes)
    }

    private func archiveDestination(for id: String?) throws -> (url: URL, heading: String?) {
        guard let url else { throw OrgSessionError.unopened }
        let location = try document.archiveLocation(for: id)
        let path = location.filename.replacingOccurrences(of: "%s", with: url.lastPathComponent)
        guard let target = files.resolveArchivePath(path, relativeTo: url), target != files.resolve(url) else {
            throw OrgError.archiveUnsupported("Archiving inside the current file is unsupported. Choose a separate archive file.")
        }
        return (target, location.heading)
    }

    private func readRequired(_ url: URL) throws -> Data {
        guard let data = try files.read(url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return data
    }

    private func decode(_ bytes: Data) throws -> String {
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw OrgSessionError.unsupportedEncoding
        }
        return text
    }

    private func accept(_ document: OrgDocument, bytes: Data, url: URL) {
        let changed = self.url != url || changedOnDisk || self.document.roots != document.roots ||
            self.document.states != document.states || self.document.doneStates != document.doneStates
        self.document = document
        source = bytes
        self.url = url
        changedOnDisk = false
        if changed { onChange?() }
    }

    private func setChangedOnDisk(_ value: Bool) {
        guard changedOnDisk != value else { return }
        changedOnDisk = value
        onChange?()
    }

    public func edit<T>(_ change: (inout OrgDocument) throws -> T) throws -> T {
        guard let url else { throw OrgSessionError.unopened }
        let expectedSource = source
        var updated = document
        let result = try change(&updated)
        let bytes = Data(updated.text.utf8)
        try files.coordinateWrite(at: url) { target in
            guard self.url == url, source == expectedSource,
                  try readRequired(target) == expectedSource else { throw OrgError.changedExternally }
            try files.writeAtomically(bytes, to: target)
        }
        accept(updated, bytes: bytes, url: url)
        return result
    }
}
