public struct CanvasCamera: Codable, Hashable {
    public var x: Double
    public var y: Double
    public var zoom: Double

    public init(x: Double = 0, y: Double = 0, zoom: Double = 1) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }
}

public struct CardPlacement: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var color: Int
    public var expanded: Bool

    public init(x: Double, y: Double, color: Int, expanded: Bool) {
        self.x = x
        self.y = y
        self.color = color
        self.expanded = expanded
    }
}

public struct CanvasGroup: Identifiable, Codable, Equatable {
    public var id: String
    public var title: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var color: Int

    public init(id: String, title: String, x: Double, y: Double, width: Double, height: Double, color: Int) {
        self.id = id
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
    }
}

public enum CanvasError: Error, CustomStringConvertible {
    case invalidValues, identityConflict

    public var description: String {
        switch self {
        case .invalidValues: "The canvas layout contains unsupported values."
        case .identityConflict: "The renamed items conflict with another saved card."
        }
    }
}

public struct CanvasState: Codable, Equatable {
    public var cards: [String: CardPlacement] { contents.cards }
    public var groups: [CanvasGroup] { contents.groups }
    public var openCards: Set<String> { contents.openCards }
    public private(set) var camera = CanvasCamera()

    private struct Contents: Equatable {
        var cards: [String: CardPlacement] = [:]
        var groups: [CanvasGroup] = []
        var openCards: Set<String> = []
    }

    private var contents = Contents()
    private var undoHistory: [Contents] = []
    private var redoHistory: [Contents] = []
    public var canUndo: Bool { !undoHistory.isEmpty }
    public var canRedo: Bool { !redoHistory.isEmpty }
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, cards, groups, camera, openCards
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else { throw CanvasError.invalidValues }
        contents.cards = try values.decode([String: CardPlacement].self, forKey: .cards)
        contents.groups = try values.decode([CanvasGroup].self, forKey: .groups)
        contents.openCards = try values.decodeIfPresent(Set<String>.self, forKey: .openCards) ?? []
        camera = try values.decodeIfPresent(CanvasCamera.self, forKey: .camera) ?? CanvasCamera()
        if (0.01..<CanvasCameraOptions.zoomRange.lowerBound).contains(camera.zoom) {
            camera = camera.zoomed(to: CanvasCameraOptions.zoomRange.lowerBound, around: CanvasPoint(x: 0, y: 0))
        }
        try Self.validate(contents)
        try Self.validate(camera)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(cards, forKey: .cards)
        try values.encode(groups, forKey: .groups)
        try values.encode(camera, forKey: .camera)
        try values.encode(openCards.sorted(), forKey: .openCards)
    }

    public func placement(for id: String, index: Int) -> CardPlacement {
        cards[id] ?? CardPlacement(
            x: Double(80 + max(0, index) % 3 * 360),
            y: Double(100 + max(0, index) / 3 * 600),
            color: 0, expanded: false
        )
    }

    public mutating func update(_ id: String, _ placement: CardPlacement) throws {
        var updated = contents
        updated.cards[id] = placement
        try apply(updated)
    }

    public mutating func setOpen(_ ids: Set<String>, _ open: Bool,
                                 placements: [String: CardPlacement] = [:]) throws {
        var updated = contents
        updated.cards.merge(placements) { _, placement in placement }
        if open { updated.openCards.formUnion(ids) }
        else { updated.openCards.subtract(ids) }
        try apply(updated)
    }

    public mutating func moveCards(_ indices: [String: Int], by delta: CanvasPoint) throws {
        guard delta.x.isFinite && delta.y.isFinite else { throw CanvasError.invalidValues }
        var updated = contents
        for (id, index) in indices {
            var card = placement(for: id, index: index)
            card.x += delta.x
            card.y += delta.y
            updated.cards[id] = card
        }
        try apply(updated)
    }

    public mutating func setExpanded(_ ids: [String], _ expanded: Bool) throws {
        var updated = contents
        for (index, id) in ids.enumerated() {
            var card = placement(for: id, index: index)
            card.expanded = expanded
            updated.cards[id] = card
        }
        try apply(updated)
    }

    public mutating func addGroup(id: String, x: Double? = nil, y: Double? = nil) throws {
        let group = CanvasGroup(
            id: id, title: groups.isEmpty ? "Focus" : "Focus \(groups.count + 1)",
            x: x ?? Double(40 + groups.count * 60), y: y ?? Double(40 + groups.count * 60),
            width: 720, height: 700, color: groups.count % 5
        )
        var updated = contents
        updated.groups.append(group)
        try apply(updated)
    }

    @discardableResult
    public mutating func updateGroup(_ group: CanvasGroup) throws -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return false }
        var updated = contents
        updated.groups[index] = group
        try apply(updated)
        return true
    }

    public mutating func deleteGroup(_ id: String) throws {
        var updated = contents
        updated.groups.removeAll { $0.id == id }
        try apply(updated)
    }

    public mutating func arrange(_ ids: [String], heights: [String: Double] = [:]) throws {
        try apply(arranged(ids, heights: heights))
    }

    @discardableResult
    public mutating func arrangeInitial(_ ids: [String], heights: [String: Double]) throws -> Bool {
        guard !ids.isEmpty, ids.allSatisfy({ id in
            guard cards[id] == nil else { return false }
            guard let height = heights[id] else { return false }
            return height.isFinite && height > 0
        }) else { return false }
        try apply(arranged(ids, heights: heights), recordHistory: false)
        return true
    }

    public mutating func placeMissing(_ ids: [String], heights: [String: Double], near center: CanvasPoint) throws {
        guard center.x.isFinite, center.y.isFinite else { throw CanvasError.invalidValues }
        let width = CardGeometry.width
        let gap = 24.0
        var updated = contents
        var occupied = ids.compactMap { id -> CanvasBounds? in
            guard let card = cards[id] else { return nil }
            return CanvasBounds(x: card.x, y: card.y, width: width,
                          height: heights[id] ?? CardGeometry.height(expanded: card.expanded))
        }
        for (index, id) in ids.enumerated() where updated.cards[id] == nil {
            guard let height = heights[id], height.isFinite, height > 0 else { continue }
            let origin = CanvasPoint(x: center.x - width / 2, y: center.y - height / 2)
            let candidates = [origin] + occupied.flatMap { rect in
                [CanvasPoint(x: rect.x + rect.width + gap, y: origin.y),
                 CanvasPoint(x: rect.x - width - gap, y: origin.y),
                 CanvasPoint(x: origin.x, y: rect.y + rect.height + gap),
                 CanvasPoint(x: origin.x, y: rect.y - height - gap)]
            }
            let available = candidates.filter { point in
                !occupied.contains { rect in
                    point.x < rect.x + rect.width + gap && point.x + width + gap > rect.x &&
                    point.y < rect.y + rect.height + gap && point.y + height + gap > rect.y
                }
            }
            func distance(_ point: CanvasPoint) -> Double {
                let dx = point.x - origin.x, dy = point.y - origin.y
                return dx * dx + dy * dy
            }
            guard let point = available.min(by: { distance($0) < distance($1) }) else { throw CanvasError.invalidValues }
            var card = placement(for: id, index: index)
            card.x = point.x
            card.y = point.y
            updated.cards[id] = card
            occupied.append(CanvasBounds(x: point.x, y: point.y, width: width, height: height))
        }
        try apply(updated, recordHistory: false)
    }

    @discardableResult
    public mutating func remap(_ mapping: [String: String], removing removedIDs: Set<String> = []) throws -> Bool {
        let changes = mapping.filter { $0.key != $0.value }
        guard !changes.isEmpty || !removedIDs.isEmpty else { return false }
        var updated = contents
        for id in removedIDs { updated.cards.removeValue(forKey: id) }
        for id in changes.keys { updated.cards.removeValue(forKey: id) }
        for (oldID, newID) in changes {
            guard let card = cards[oldID] else { continue }
            guard updated.cards[newID] == nil else { throw CanvasError.identityConflict }
            updated.cards[newID] = card
        }
        updated.openCards = Set(openCards.subtracting(removedIDs).map { changes[$0] ?? $0 })
        try apply(updated, recordHistory: false)
        undoHistory = []
        redoHistory = []
        return true
    }

    public mutating func updateCamera(_ camera: CanvasCamera) throws {
        try Self.validate(camera)
        self.camera = camera
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoHistory.last else { return false }
        redoHistory.append(contents)
        contents = previous
        undoHistory.removeLast()
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoHistory.last else { return false }
        undoHistory.append(contents)
        contents = next
        redoHistory.removeLast()
        return true
    }

    private func arranged(_ ids: [String], heights: [String: Double]) -> Contents {
        var updated = contents
        var rowY = 60.0
        var rowHeight = 0.0
        for (index, id) in ids.enumerated() {
            if index > 0 && index % 3 == 0 {
                rowY += rowHeight + 24
                rowHeight = 0
            }
            var card = placement(for: id, index: index)
            card.x = Double(80 + index % 3 * 360)
            card.y = rowY
            updated.cards[id] = card
            let measured = heights[id] ?? 0
            let height = measured.isFinite && measured > 0 ? measured : CardGeometry.height(expanded: card.expanded)
            rowHeight = max(rowHeight, height)
        }
        return updated
    }

    private mutating func apply(_ updated: Contents, recordHistory: Bool = true) throws {
        try Self.validate(updated)
        guard updated != contents else { return }
        if recordHistory {
            undoHistory.append(contents)
            redoHistory = []
        }
        contents = updated
    }

    private static func validate(_ camera: CanvasCamera) throws {
        guard camera.x.isFinite && camera.y.isFinite && camera.zoom.isFinite && CanvasCameraOptions.zoomRange.contains(camera.zoom) else {
            throw CanvasError.invalidValues
        }
    }

    private static func validate(_ contents: Contents) throws {
        func dimension(_ value: Double) -> Bool { value.isFinite && value > 0 && value <= 10_000 }
        guard contents.cards.values.allSatisfy({
                  $0.x.isFinite && $0.y.isFinite && (0..<5).contains($0.color)
              }),
              contents.groups.allSatisfy({
                  $0.x.isFinite && $0.y.isFinite && dimension($0.width) &&
                  dimension($0.height) && (0..<5).contains($0.color)
              }), Set(contents.groups.map(\.id)).count == contents.groups.count else {
            throw CanvasError.invalidValues
        }
    }
}
