import Foundation
import Combine
import CryptoKit
import WorkspaceCore

typealias CanvasCamera = WorkspaceCore.CanvasCamera
typealias CardPlacement = WorkspaceCore.CardPlacement
typealias CanvasGroup = WorkspaceCore.CanvasGroup

@MainActor
final class CanvasLayout: ObservableObject {
    private var state = CanvasState()

    var cards: [String: CardPlacement] { state.cards }
    var groups: [CanvasGroup] { state.groups }
    var openCards: Set<String> { state.openCards }
    var camera: CanvasCamera { state.camera }
    var canUndo: Bool { state.canUndo }
    var canRedo: Bool { state.canRedo }

    private(set) var layoutURL: URL?
    private var savedData: Data?
    private let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
    }

    func open(_ orgURL: URL) throws {
        objectWillChange.send()
        layoutURL = nil
        savedData = nil
        state = CanvasState()
        let canonical = orgURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let name = SHA256.hash(data: Data(canonical.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = try self.directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("visual-org/Layouts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name).appendingPathExtension("json")
        let data = try read(target)
        if let data {
            state = try JSONDecoder().decode(CanvasState.self, from: data)
        }
        savedData = data
        layoutURL = target
    }

    func placement(for id: String, index: Int) -> CardPlacement {
        state.placement(for: id, index: index)
    }

    @discardableResult
    func edit<T>(_ change: (inout CanvasState) throws -> T) throws -> T {
        var updated = state
        let result = try change(&updated)
        guard updated != state else { return result }
        guard let url = layoutURL else { throw CanvasLayoutError.unopened }
        guard try read(url) == savedData else { throw CanvasLayoutError.changedExternally }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try data.write(to: url, options: .atomic)
        savedData = data
        if updated.cards != state.cards || updated.groups != state.groups || updated.openCards != state.openCards ||
            updated.canUndo != state.canUndo || updated.canRedo != state.canRedo {
            objectWillChange.send()
        }
        state = updated
        return result
    }

    private func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

}

enum CanvasLayoutError: LocalizedError {
    case unopened, changedExternally

    var errorDescription: String? {
        switch self {
        case .unopened: "Open a valid Org file and canvas layout before saving positions."
        case .changedExternally: "The canvas file changed outside visual-org. Reopen it before saving."
        }
    }
}
