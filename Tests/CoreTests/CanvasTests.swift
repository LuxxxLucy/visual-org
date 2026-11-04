import Foundation
import OrgCore
import WorkspaceCore

struct CanvasTests {
    static func testMoveSelectedCards() throws {
        for index in [0, 1, 4, 5, 75] {
            try equal(CanvasState().placement(for: "new", index: index).color, 0)
        }
        var reloaded = CanvasState()
        let movedCard = CardPlacement(x: -160, y: -50, color: 2, expanded: false)
        try reloaded.update("moved", movedCard)
        let newIDs = (0..<6).map { "new-\($0)" }
        let ids = ["moved"] + newIDs
        let heights = Dictionary(uniqueKeysWithValues: ids.map { ($0, 100.0) })
        try reloaded.placeMissing(ids, heights: heights, near: CanvasPoint(x: 0, y: 0))
        try equal(reloaded.cards["moved"], movedCard)
        let bounds = try ids.map { id -> CanvasBounds in
            let card = try unwrap(reloaded.cards[id])
            try check(abs(card.y) < 1000)
            return CanvasBounds(x: card.x, y: card.y, width: 320, height: 100)
        }
        for i in bounds.indices {
            for j in bounds.indices where j > i {
                let a = bounds[i], b = bounds[j]
                try check(a.x + a.width <= b.x || b.x + b.width <= a.x ||
                          a.y + a.height <= b.y || b.y + b.height <= a.y)
            }
        }
        let positions = reloaded.cards
        try reloaded.placeMissing(ids, heights: heights, near: CanvasPoint(x: 9000, y: 9000))
        try equal(reloaded.cards, positions)
        let restored = try JSONDecoder().decode(CanvasState.self, from: JSONEncoder().encode(reloaded))
        try equal(restored.cards, positions)
        var state = CanvasState()
        try check(!state.placement(for: "new", index: 0).expanded)
        var saved = CanvasState()
        try saved.update("open", CardPlacement(x: 0, y: 0, color: 0, expanded: true))
        let reopened = try JSONDecoder().decode(CanvasState.self, from: JSONEncoder().encode(saved))
        try check(reopened.placement(for: "open", index: 0).expanded)
        try state.arrangeInitial(["first", "second", "other"], heights: ["first": 200, "second": 300, "other": 100])
        let original = state.cards
        let camera = CanvasCamera(x: -500, y: 700, zoom: 0.23)
        try state.updateCamera(camera)
        try check(!state.canUndo)
        let addedPlacement = state.placement(for: "added", index: 3)
        try state.moveCards(["first": 0, "second": 1, "added": 3], by: CanvasPoint(x: -420, y: 310))
        let moved = state.cards
        for id in ["first", "second"] {
            var expected = try unwrap(original[id])
            expected.x -= 420
            expected.y += 310
            try equal(moved[id], expected)
        }
        try equal(moved["other"], original["other"])
        var expectedAdded = addedPlacement
        expectedAdded.x -= 420
        expectedAdded.y += 310
        try equal(moved["added"], expectedAdded)
        try equal(state.camera, camera)
        try check(state.undo())
        try equal(state.cards, original)
        try check(!state.canUndo && state.canRedo)
        try check(state.redo())
        try equal(state.cards, moved)
        try check(state.canUndo && !state.canRedo)
        state.undo()
        for delta in [CanvasPoint(x: .infinity, y: 1), CanvasPoint(x: 1, y: .nan)] {
            try throwsError { try state.moveCards(["first": 0, "added": 3], by: delta) }
            try equal(state.cards, original)
            try check(!state.canUndo && state.canRedo)
        }
        try state.moveCards(["first": 0, "second": 1], by: CanvasPoint(x: 0, y: 0))
        try state.moveCards([:], by: CanvasPoint(x: 100, y: 100))
        try equal(state.cards, original)
        try check(!state.canUndo && state.canRedo)
        state.redo()
        try equal(state.cards, moved)
        try equal(state.camera, camera)
        try state.update("first", CardPlacement(x: .greatestFiniteMagnitude, y: 0, color: 1, expanded: true))
        let beforeOverflow = state.cards
        try throwsError { try state.moveCards(["first": 0, "second": 1], by: CanvasPoint(x: .greatestFiniteMagnitude, y: 0)) }
        try equal(state.cards, beforeOverflow)
        state.undo()
        try equal(state.cards, moved)
    }

    static func testAnchoredZoomAndFit() throws {
        let camera = CanvasCamera(x: -2300, y: 410, zoom: 0.23)
        let anchor = CanvasPoint(x: 83, y: 290)
        let original = camera.canvasPoint(at: anchor)
        for zoom in [0.001, 1, 2.07, 10] {
            let next = camera.zoomed(to: zoom, around: anchor)
            let point = next.canvasPoint(at: anchor)
            try equal(point.x, original.x, accuracy: 0.000001)
            try equal(point.y, original.y, accuracy: 0.000001)
            try check(CanvasCameraOptions.zoomRange.contains(next.zoom))
        }
        for (delta, multiplier) in [(-1000.0, 0.9), (-10, 0.9), (-1, 0.99), (0, 1), (1, 1.01), (10, 1.1), (1000, 1.1)] {
            let next = camera.zoomed(wheelDelta: delta, around: anchor)
            try equal(next.zoom, camera.zoom * multiplier, accuracy: 0.000001)
            let point = next.canvasPoint(at: anchor)
            try equal(point.x, original.x, accuracy: 0.000001)
            try equal(point.y, original.y, accuracy: 0.000001)
        }
        for delta in [Double.nan, .infinity, -.infinity] {
            try equal(camera.zoomed(wheelDelta: delta, around: anchor), camera)
        }
        try equal(CanvasCamera(zoom: 8).zoomed(wheelDelta: 10, around: anchor).zoom, 8)
        try equal(CanvasCamera(zoom: 0.05).zoomed(wheelDelta: -10, around: anchor).zoom, 0.05)
        let steps = CanvasCameraOptions.zoomSteps
        for index in steps.indices {
            let camera = CanvasCamera(zoom: steps[index])
            try equal(camera.zoomed(step: .in, around: anchor).zoom, steps[min(index + 1, steps.count - 1)])
            try equal(camera.zoomed(step: .out, around: anchor).zoom, steps[max(index - 1, 0)])
        }
        try equal(CanvasCamera(zoom: 0.74).zoomed(step: .in, around: anchor).zoom, 1)
        try equal(CanvasCamera(zoom: 0.75).zoomed(step: .in, around: anchor).zoom, 2)
        try equal(CanvasCamera(zoom: 0.75).zoomed(step: .out, around: anchor).zoom, 0.25)
        try equal(CanvasCamera(zoom: 0.76).zoomed(step: .out, around: anchor).zoom, 0.5)
        let target = camera.zoomed(to: 2, around: anchor)
        try equal(camera.interpolated(to: target, progress: 0, viewportWidth: 1000), camera)
        try equal(camera.interpolated(to: target, progress: 1, viewportWidth: 1000), target)
        var priorZoom = camera.zoom
        for progress in [0.125, 0.25, 0.5, 0.75, 0.875] {
            let frame = camera.interpolated(to: target, progress: progress, viewportWidth: 1000)
            try check(frame.zoom > priorZoom && frame.zoom < target.zoom)
            let point = frame.canvasPoint(at: anchor)
            try equal(point.x, original.x, accuracy: 0.000001)
            try equal(point.y, original.y, accuracy: 0.000001)
            priorZoom = frame.zoom
        }
        let fit = try unwrap(CanvasCamera.fitting([
            CanvasBounds(x: -1000, y: -300, width: 320, height: 500),
            CanvasBounds(x: 2000, y: 900, width: 720, height: 700)
        ], width: 1000, height: 800))
        try equal(fit.zoom, 920 / 3720, accuracy: 0.000001)
        try equal(fit.x + 860 * fit.zoom, 500, accuracy: 0.000001)
        try check((CanvasCamera.fitting([], width: 100, height: 100)) == nil)
    }

    static func testIdentitySwapArchiveAndHistory() throws {
        var state = CanvasState()
        try check(!state.undo())
        try check(!state.redo())
        try check(!state.remap([:]))
        let absentGroup = CanvasGroup(id: "missing", title: "Missing", x: 0, y: 0, width: 400, height: 300, color: 0)
        try check(!state.updateGroup(absentGroup))
        try check(!state.canUndo && !state.canRedo && state.groups.isEmpty)
        let first = CardPlacement(x: -400, y: 10, color: 1, expanded: false)
        let second = CardPlacement(x: 50, y: 900, color: 2, expanded: true)
        try state.update("first", first)
        try state.update("second", second)
        try check(!state.remap(["first": "first"]))
        try check(state.canUndo)
        try check(state.remap(["first": "second", "second": "first"]))
        try equal(state.cards["first"], second)
        try equal(state.cards["second"], first)
        try check(!(state.canUndo))
        try check(state.remap(["second": "first"], removing: ["first"]))
        try equal(state.cards, ["first": first])
        try state.update("first", second)
        let camera = CanvasCamera(x: 800, y: -20, zoom: 0.5)
        try state.updateCamera(camera)
        try check(state.undo())
        try equal(state.cards["first"], first)
        try equal(state.camera, camera)
        try check(state.redo())
        try equal(state.cards["first"], second)
        try equal(state.camera, camera)
        try state.addGroup(id: "area")
        var group = try unwrap(state.groups.first)
        group.title = "Renamed"
        try check(state.updateGroup(group))
        try equal(state.groups.first?.title, "Renamed")
    }

    static func testSavedDocumentCompatibilityAndRejectedValues() throws {
        let oldJSON = #"{"version":1,"cards":{"heading":{"x":-25,"y":90,"color":2,"expanded":true}},"groups":[]}"#
        let state = try JSONDecoder().decode(CanvasState.self, from: Data(oldJSON.utf8))
        try equal(state.camera, CanvasCamera())
        try equal(state.cards["heading"]?.x, -25)
        let roundTrip = try JSONDecoder().decode(CanvasState.self, from: JSONEncoder().encode(state))
        try equal(roundTrip.cards, state.cards)
        let oldZoom = oldJSON.replacingOccurrences(of: "\"groups\":[]", with: "\"groups\":[],\"camera\":{\"x\":-40,\"y\":20,\"zoom\":0.02}")
        let normalized = try JSONDecoder().decode(CanvasState.self, from: Data(oldZoom.utf8))
        try equal(normalized.camera, CanvasCamera(x: -100, y: 50, zoom: 0.05))
        try equal(normalized.cards, state.cards)
        var candidate = state
        try throwsError { try candidate.updateCamera(CanvasCamera(zoom: 0)) }
        try equal(candidate.camera, state.camera)
        try check(!(candidate.canUndo))

        try candidate.update("first", CardPlacement(x: 1, y: 2, color: 0, expanded: false))
        try candidate.addGroup(id: "area")
        candidate.undo()
        try candidate.updateCamera(CanvasCamera(x: -70, y: 320, zoom: 2))
        try check(candidate.canUndo && candidate.canRedo)
        let encoded = try JSONEncoder().encode(candidate)
        let fields = try unwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        try equal(Set(fields.keys), Set(["version", "cards", "groups", "camera", "openCards"]))
        try equal(fields["version"] as? Int, 1)
        let restored = try JSONDecoder().decode(CanvasState.self, from: encoded)
        try equal(restored.cards, candidate.cards)
        try equal(restored.groups, candidate.groups)
        try equal(restored.camera, candidate.camera)
        try check(!restored.canUndo && !restored.canRedo)
        let unsupported = oldJSON.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        try throwsError { try JSONDecoder().decode(CanvasState.self, from: Data(unsupported.utf8)) }
        let invalid = #"{"version":1,"cards":{},"groups":[],"camera":{"x":0,"y":0,"zoom":0}}"#
        try throwsError { try JSONDecoder().decode(CanvasState.self, from: Data(invalid.utf8)) }

        try check(state.openCards.isEmpty)
        var hierarchy = CanvasState()
        try hierarchy.setOpen(["child", "grandchild"], true)
        try hierarchy.setOpen(["child"], false)
        try equal(hierarchy.openCards, ["grandchild"])
        try check(hierarchy.undo())
        try equal(hierarchy.openCards, ["child", "grandchild"])
        try check(hierarchy.redo())
        try equal(hierarchy.openCards, ["grandchild"])
        try hierarchy.setOpen(["child"], true)
        let savedHierarchy = try JSONDecoder().decode(CanvasState.self, from: JSONEncoder().encode(hierarchy))
        try equal(savedHierarchy.openCards, hierarchy.openCards)
        try hierarchy.remap(["child": "grandchild", "grandchild": "child"])
        try equal(hierarchy.openCards, ["child", "grandchild"])
        try hierarchy.remap(["grandchild": "renamed"], removing: ["child"])
        try equal(hierarchy.openCards, ["renamed"])
        try check(!hierarchy.canUndo && !hierarchy.canRedo)

        let childPlacement = CardPlacement(x: 1160, y: 100, color: 2, expanded: true)
        var initialRoots = CanvasState()
        try initialRoots.setOpen(["child"], true, placements: ["child": childPlacement])
        try check(initialRoots.undo())
        try check(initialRoots.cards.isEmpty && initialRoots.openCards.isEmpty && !initialRoots.canUndo)
        try check(initialRoots.redo())
        try equal(initialRoots.cards["child"], childPlacement)
        try equal(initialRoots.openCards, ["child"])
        try check(initialRoots.arrangeInitial(["root"], heights: ["root": 100]))
        try equal(initialRoots.cards["child"], childPlacement)
        try equal(initialRoots.openCards, ["child"])
        try check(!initialRoots.arrangeInitial(["root"], heights: ["root": 150]))
    }

    static func testDraftIdentityChanges() throws {
        var drafts = CreationDraftState()
        drafts[checkbox: "first"] = "Keep child text"
        drafts[heading: "second"] = "Keep heading text"
        try drafts.remap(["first": "second", "second": "first"])
        try equal(drafts[checkbox: "second"], "Keep child text")
        try equal(drafts[heading: "first"], "Keep heading text")
        try drafts.remap(["second": "first"], removing: ["first"])
        try equal(drafts[checkbox: "first"], "Keep child text")
        try equal(drafts[heading: "first"], "")
        drafts.clear()
        try check(!(drafts.hasUnsavedEdits))
        drafts[checkbox: "shared"] = "Checkbox draft"
        drafts[heading: "shared"] = "Heading draft"
        drafts[checkbox: "shared"] = ""
        try equal(drafts[heading: "shared"], "Heading draft")
        try check(drafts.hasUnsavedEdits)
        drafts[checkbox: "shared"] = "Restored checkbox"
        try drafts.remap(["shared": "renamed"])
        try equal(drafts[checkbox: "renamed"], "Restored checkbox")
        try equal(drafts[heading: "renamed"], "Heading draft")
        try equal(drafts[checkbox: "shared"], "")
        try equal(drafts[heading: "shared"], "")
        drafts[heading: "renamed"] = ""
        try equal(drafts[checkbox: "renamed"], "Restored checkbox")
        try check(drafts.hasUnsavedEdits)
        drafts[checkbox: "renamed"] = ""
        try check(!drafts.hasUnsavedEdits)
        drafts[checkbox: "one"] = "First draft"
        drafts[heading: "two"] = "Second draft"
        try throwsError({ try drafts.remap(["one": "two"]) }) { error in
            guard case DraftError.identityConflict = error else { try check(false); return }
        }
        try equal(drafts[checkbox: "one"], "First draft")
        try equal(drafts[heading: "two"], "Second draft")
        var document = OrgDocument(text: "* Parent\nKeep notes.\n* Other\nKeep other notes.\n")
        var additions = CreationDraftState()
        additions[checkbox: document.roots[0].id] = "New checkbox"
        additions[heading: document.roots[1].id] = "New child"
        try additions.apply(to: &document)
        try equal(document.roots[0].checkboxes.map(\.title), ["New checkbox"])
        try equal(document.roots[1].children.map(\.title), ["New child"])
        try check(document.text.contains("Keep notes.") && document.text.contains("Keep other notes."))
        try check(additions.hasUnsavedEdits)
    }
}
