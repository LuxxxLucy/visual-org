import Foundation
import OrgCore

@main
struct BehaviorTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: Bool, _ description: String) throws {
        if !condition { throw Failure(description: description) }
    }

    @MainActor
    static func main() {
        setbuf(stdout, nil)
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func run() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("visual-org-test-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.org")
        let initial = """
        #+TODO: TODO ONGOING | DONE CANCELED
        * ONGOING Current [0/2]
        - [ ] First
        - [ ] Second
        ** CANCELED Child
        Keep this child body.
        * Other
        Keep this body unchanged.

        """
        try Data(initial.utf8).write(to: file)
        let session = OrgSession()
        try session.open(file)
        let current = session.roots[0]
        try session.edit { try $0.setCheckbox(current.id, item: current.checkboxes[0], checked: true) }
        try session.edit { try $0.setPriority(current.id, "A") }
        let reopened = OrgSession()
        try reopened.open(file)
        try expect(reopened.roots[0].title == "Current [1/2]", "Checkbox count did not survive reopening")
        try expect(reopened.roots[0].priority == "A", "Priority did not survive reopening")
        let body = reopened.roots[0].body
        let edited = body + "\n*Bold*, /italic/, [[https://orgmode.org][Org mode]], 中文。\n"
        _ = try reopened.edit { try $0.updateDetails(current.id, title: "Current [1/2]", body: edited,
                                       expectedTitle: "Current [1/2]", expectedBody: body) }
        try session.checkForExternalChanges(reload: true)
        try expect(session.roots[0].body == edited, "Saved source text changed")
        try expect(session.roots[1].body == "Keep this body unchanged.\n", "Unrelated text changed")
        print("PASS save, reopen, checkbox counts, priority, and Org text")

        let external = try String(contentsOf: file, encoding: .utf8) + "External edit.\n"
        try Data(external.utf8).write(to: file, options: .atomic)
        try session.checkForExternalChanges(reload: false)
        try expect(session.changedOnDisk, "External edit was not detected")
        do {
            try session.edit { try $0.setPriority(current.id, "B") }
            throw Failure(description: "Stale save overwrote an external edit")
        } catch OrgError.changedExternally { }
        try expect(try String(contentsOf: file, encoding: .utf8) == external, "External text changed")
        try session.checkForExternalChanges(reload: true)
        try expect(!session.changedOnDisk && session.roots[1].body.contains("External edit."), "Reload failed")
        print("PASS external change detection, stale-save protection, and reload")

        let renameFile = directory.appendingPathComponent("rename-drafts.org")
        let renameSource = "* First\nKeep first.\n** Child\nChild notes.\n* Duplicate\nKeep second.\n** Child\nOther notes.\n"
        try Data(renameSource.utf8).write(to: renameFile)
        let renameSession = OrgSession()
        try renameSession.open(renameFile)
        let beforeRename = renameSession.roots
        let renameDrafts = CreationDrafts()
        renameDrafts.updateCheckboxText(beforeRename[0].children[0].id, "First child draft")
        renameDrafts.updateCheckboxText(beforeRename[1].children[0].id, "Second child draft")
        renameDrafts.heading(beforeRename[0].id).wrappedValue = "First heading draft"
        renameDrafts.heading(beforeRename[1].id).wrappedValue = "Second heading draft"
        let renameLayout = CanvasLayout(directory: directory.appendingPathComponent("rename-layout"))
        try renameLayout.open(renameFile)
        let firstPlacement = CardPlacement(x: -250, y: 500, color: 1, expanded: true)
        let secondPlacement = CardPlacement(x: 800, y: -300, color: 3, expanded: false)
        try renameLayout.edit { try $0.update(beforeRename[0].id, firstPlacement) }
        try renameLayout.edit { try $0.update(beforeRename[1].id, secondPlacement) }
        let renameResult = try renameSession.edit { try $0.updateDetails(beforeRename[0].id, title: "Duplicate", body: beforeRename[0].body,
                                                          expectedTitle: beforeRename[0].title, expectedBody: beforeRename[0].body) }
        try renameDrafts.remap(renameResult.replacements)
        try renameLayout.edit { try $0.remap(renameResult.replacements) }
        try renameSession.open(renameFile)
        try renameLayout.open(renameFile)
        let afterRename = renameSession.roots
        try expect((renameResult.replacements[beforeRename[0].id] ?? beforeRename[0].id) == afterRename[0].id && renameResult.replacements.count == 4, "Rename identity map missed descendants or duplicate siblings")
        try expect(renameDrafts.checkboxText(afterRename[0].children[0].id) == "First child draft" && renameDrafts.checkboxText(afterRename[1].children[0].id) == "Second child draft", "Parent rename lost child checkbox drafts")
        try expect(renameDrafts.heading(afterRename[0].id).wrappedValue == "First heading draft" && renameDrafts.heading(afterRename[1].id).wrappedValue == "Second heading draft", "Duplicate title rename lost heading drafts")
        try expect(renameLayout.placement(for: afterRename[0].id, index: 0) == firstPlacement && renameLayout.placement(for: afterRename[1].id, index: 1) == secondPlacement, "Duplicate title rename changed saved placements")
        try expect(try String(contentsOf: renameFile, encoding: .utf8) == renameSource.replacingOccurrences(of: "* First\n", with: "* Duplicate\n"), "Parent rename changed unrelated source")
        renameDrafts.updateCheckboxText(afterRename[0].children[0].id, "")
        renameDrafts.updateCheckboxText(afterRename[1].children[0].id, "")
        renameDrafts.heading(afterRename[0].id).wrappedValue = ""
        renameDrafts.heading(afterRename[1].id).wrappedValue = ""
        try expect(!renameDrafts.hasUnsavedEdits, "Rename left unreachable creation drafts")
        print("PASS parent rename, descendant drafts, duplicate sibling identities, and saved placements")

        let movedIdentities = try renameSession.edit { try $0.moveRoot(afterRename[1].id, offset: -1) }
        try renameLayout.edit { try $0.remap(movedIdentities.replacements) }
        try renameSession.open(renameFile)
        try renameLayout.open(renameFile)
        let reorderedRoots = renameSession.roots
        try expect(reorderedRoots[0].body == afterRename[1].body && reorderedRoots[1].body == afterRename[0].body, "Duplicate roots did not reorder")
        try expect(movedIdentities.replacements.count == 4 && renameLayout.placement(for: reorderedRoots[0].id, index: 0) == secondPlacement && renameLayout.placement(for: reorderedRoots[1].id, index: 1) == firstPlacement, "Duplicate reorder changed placements")
        let reorderedText = "* Duplicate\nKeep second.\n** Child\nOther notes.\n* Duplicate\nKeep first.\n** Child\nChild notes.\n"
        try expect(try String(contentsOf: renameFile, encoding: .utf8) == reorderedText, "Duplicate reorder changed subtree text")
        let archiveIdentities = try renameSession.archive(reorderedRoots[0])
        try renameLayout.edit { try $0.remap(archiveIdentities.changes.replacements, removing: archiveIdentities.changes.removed) }
        try expect(archiveIdentities.changes.removed == Set([reorderedRoots[0].id, reorderedRoots[0].children[0].id]), "Archive removal IDs missed the removed subtree")
        try renameSession.open(renameFile)
        try renameLayout.open(renameFile)
        let survivor = renameSession.roots[0]
        try expect(archiveIdentities.changes.replacements.count == 2 && survivor.body == afterRename[0].body && survivor.children[0].body == "Child notes.\n", "Archive identity map lost surviving subtree")
        try expect(renameLayout.placement(for: survivor.id, index: 0) == firstPlacement, "Duplicate archive changed surviving placement")
        try expect(try String(contentsOf: renameFile, encoding: .utf8) == "* Duplicate\nKeep first.\n** Child\nChild notes.\n", "Duplicate archive changed surviving source")
        let duplicateArchive = OrgDocument(text: try String(contentsOf: archiveIdentities.url, encoding: .utf8))
        try expect(duplicateArchive.roots[0].body.contains("Keep second.") && duplicateArchive.roots[0].children[0].body.contains("Other notes."), "Archive moved the wrong duplicate")
        print("PASS duplicate root reorder and archive identity mapping with saved placements")

        let checkboxFile = directory.appendingPathComponent("checkbox-edit.org")
        let checkboxSource = "* List [0/1]\r\nSCHEDULED: <2026-10-24 Sat>\r\n#+BEGIN_SRC swift\r\nlet value = 1\r\n#+END_SRC\r\n  1)  [ ]  Old 中文  \r\n     Description.\r\n     #+BEGIN_EXAMPLE\r\n     Attached example.\r\n     #+END_EXAMPLE\r\n* Other\r\nKeep.\r\n"
        try Data(checkboxSource.utf8).write(to: checkboxFile)
        let checkboxSession = OrgSession()
        try checkboxSession.open(checkboxFile)
        let checkboxHeading = checkboxSession.roots[0]
        let oldCheckbox = checkboxHeading.checkboxes[0]
        try checkboxSession.edit { try $0.renameCheckbox(checkboxHeading.id, item: oldCheckbox, title: "New /中文/") }
        let renamedSource = checkboxSource.replacingOccurrences(of: "Old 中文", with: "New /中文/")
        try expect(try Data(contentsOf: checkboxFile) == Data(renamedSource.utf8), "Checkbox rename changed surrounding source")
        try checkboxSession.open(checkboxFile)
        try expect(checkboxSession.roots[0].checkboxes[0].title.trimmingCharacters(in: .whitespaces) == "New /中文/", "Checkbox rename failed to reopen")
        let preview = checkboxSession.roots[0].notePreview
        try expect(OrgMarkup.rows(preview).contains { $0.text.contains("SCHEDULED:") }, "Planning line disappeared from rendered notes")
        try expect(preview.contains("#+BEGIN_SRC swift") && preview.contains("let value = 1") && preview.contains("#+END_SRC") && preview.contains("SCHEDULED:"), "Standalone notes disappeared")
        try expect(OrgMarkup.rows(preview).contains { $0.text.contains("SCHEDULED:") }, "Rendered planning date disappeared")
        try expect(!preview.contains("Attached example.") && checkboxSession.roots[0].checkboxes[0].details.contains("Attached example."), "Checkbox description changed ownership")
        do {
            try checkboxSession.edit { try $0.renameCheckbox(checkboxHeading.id, item: oldCheckbox, title: "Stale") }
            throw Failure(description: "Stale checkbox edit succeeded")
        } catch OrgError.changedExternally { }
        let freshCheckbox = checkboxSession.roots[0].checkboxes[0]
        do {
            try checkboxSession.edit { try $0.renameCheckbox(checkboxHeading.id, item: freshCheckbox, title: "Bad\n* Heading") }
            throw Failure(description: "Multiline checkbox title succeeded")
        } catch OrgError.invalidText { }
        let changedCheckboxSource = renamedSource + "External text.\r\n"
        try Data(changedCheckboxSource.utf8).write(to: checkboxFile, options: .atomic)
        do {
            try checkboxSession.edit { try $0.renameCheckbox(checkboxHeading.id, item: freshCheckbox, title: "Overwrite") }
            throw Failure(description: "Checkbox edit overwrote external text")
        } catch OrgError.changedExternally { }
        try expect(try Data(contentsOf: checkboxFile) == Data(changedCheckboxSource.utf8), "Rejected checkbox edit changed the file")
        print("PASS checkbox rename, exact source preservation, note visibility, and stale edit refusal")

        let planningFile = directory.appendingPathComponent("planning.org")
        for body in ["Notes.\r\nSCHEDULED: <2026-10-24 Sat>\r\n", "Example SCHEDULED: <2026-10-24 Sat>\r\n"] {
            let notesOnly = OrgDocument(text: "* TODO Notes\r\n" + body)
            try expect(notesOnly.roots[0].planning(.scheduled) == nil, "Note text was mistaken for planning")
        }
        let planningSource = "* TODO Plan\r\nCLOSED: [2026-10-23 Fri 12:30]  DEADLINE: <2026-10-30 Fri>\r\n:PROPERTIES:\r\n:ID: planning-item\r\n:END:\r\nKeep notes.\r\n* Other\r\nKeep other.\r\n"
        try Data(planningSource.utf8).write(to: planningFile)
        let planningSession = OrgSession()
        try planningSession.open(planningFile)
        let plan = planningSession.roots[0]
        let schedule = "<2026-10-24 Sat 09:00-10:30 ++1w -2d>"
        try planningSession.edit { try $0.setPlanning(plan.id, kind: .scheduled, timestamp: schedule, expectedBody: plan.body) }
        let plannedText = planningSource.replacingOccurrences(of: "CLOSED: [2026-10-23 Fri 12:30]", with: "")
            .replacingOccurrences(of: "* TODO Plan\r\n", with: "* TODO Plan\r\nSCHEDULED: " + schedule + " ")
        try expect(try Data(contentsOf: planningFile) == Data(plannedText.utf8), "Planning edit changed unrelated source")
        try planningSession.open(planningFile)
        let savedPlan = planningSession.roots[0]
        try expect(savedPlan.planning(.scheduled) == schedule && savedPlan.planning(.deadline) == "<2026-10-30 Fri>", "Planning fields failed to reopen")
        do {
            try planningSession.edit { try $0.setPlanning(plan.id, kind: .deadline, timestamp: nil, expectedBody: plan.body) }
            throw Failure(description: "Stale planning draft succeeded")
        } catch OrgError.changedExternally { }
        do {
            try planningSession.edit { try $0.setPlanning(plan.id, kind: .deadline, timestamp: "<2026-02-30 Mon>", expectedBody: savedPlan.body) }
            throw Failure(description: "Invalid calendar date succeeded")
        } catch OrgPlanningError.invalidTimestamp { }
        try expect(try Data(contentsOf: planningFile) == Data(plannedText.utf8), "Rejected planning edit changed source")
        try planningSession.edit { try $0.setPlanning(plan.id, kind: .scheduled, timestamp: nil, expectedBody: savedPlan.body) }
        try expect(planningSession.roots[0].planning(.scheduled) == nil && planningSession.roots[0].planning(.deadline) != nil, "Removing schedule removed deadline")
        try planningSession.edit { try $0.setPlanning(plan.id, kind: .deadline, timestamp: nil, expectedBody: planningSession.roots[0].body) }
        try expect(planningSession.roots[0].body.hasPrefix(":PROPERTIES:\r\n"), "Empty planning line remained")
        try planningSession.edit { try $0.setPlanning(plan.id, kind: .scheduled, timestamp: "<2026-10-25 Sun>", expectedBody: planningSession.roots[0].body) }
        try planningSession.open(planningFile)
        try expect(planningSession.roots[0].body.hasPrefix("SCHEDULED: <2026-10-25 Sun>\r\n:PROPERTIES:\r\n"), "Planning insertion displaced properties")
        print("PASS planning save, reopen, removal, CLOSED handling, CRLF, and stale draft refusal")

        let archive = try session.archiveURL(for: current.id)
        let prefix = "* TODO Existing\n* DONE Complete\n"
        try Data(prefix.utf8).write(to: archive)
        _ = try session.archive(session.roots[0])
        let archivedText = try String(contentsOf: archive, encoding: .utf8)
        let archived = OrgDocument(text: archivedText)
        try expect(session.roots.count == 1 && session.roots[0].title == "Other", "Archive did not remove the subtree")
        try expect(archivedText.hasPrefix(prefix), "Existing archive content changed")
        try expect(archived.roots[2].state == "ONGOING", "Archived state was lost")
        try expect(archived.roots[2].children[0].state == "CANCELED", "Child state was lost")
        try expect(archived.doneStates.contains("CANCELED"), "Completed custom state was lost")
        try expect(archived.roots[2].checkboxes.count == 2 && archivedText.contains(edited), "Archived text was lost")
        print("PASS subtree archive, existing archive preservation, and custom task states")

        let layoutDirectory = directory.appendingPathComponent("layouts")
        let layout = CanvasLayout(directory: layoutDirectory)
        try layout.open(file)
        let position = CardPlacement(x: 123, y: 456, color: 2, expanded: false)
        try layout.edit { try $0.update(session.roots[0].id, position) }
        try layout.edit { try $0.addGroup(id: UUID().uuidString) }
        let restored = CanvasLayout(directory: layoutDirectory)
        try restored.open(file)
        try expect(restored.cards == layout.cards && restored.groups == layout.groups, "Layout did not survive reopening")
        try restored.open(directory.appendingPathComponent("different.org"))
        try expect(restored.cards.isEmpty && restored.groups.isEmpty, "Different files share a layout")
        let absentLayout = restored.layoutURL!
        try restored.edit { $0.undo() }
        try restored.edit { $0.redo() }
        try restored.edit { try $0.remap([:]) }
        try restored.edit { try $0.updateGroup(CanvasGroup(id: "absent", title: "Absent", x: 0, y: 0, width: 400, height: 300, color: 0)) }
        try expect(!files.fileExists(atPath: absentLayout.path), "Unchanged canvas operation wrote a layout")
        print("PASS layout persistence, visual areas, and separate file layouts")

        let arrangedIDs = ["one", "two", "three", "four"]
        let measured = Dictionary(uniqueKeysWithValues: zip(arrangedIDs, [100.0, 180.0, 120.0, 90.0]).map {
            ($0.0, CGSize(width: 320, height: $0.1))
        })
        try expect(!(try restored.edit { try $0.arrangeInitial(arrangedIDs, heights: [:]) }), "Initial arrangement used incomplete measurements")
        try expect((try restored.edit { try $0.arrangeInitial(arrangedIDs, heights: measured.mapValues { Double($0.height) }) }), "Measured initial arrangement failed")
        try expect(restored.cards["four"]?.y == 264, "Second row did not follow measured height and gap")
        try expect(!restored.canUndo, "Initial arrangement created undo history")
        var manual = restored.cards["one"]!
        manual.x = -800
        try restored.edit { try $0.update("one", manual) }
        try expect(!(try restored.edit { try $0.arrangeInitial(arrangedIDs, heights: measured.mapValues { Double($0.height) }) }) && restored.cards["one"] == manual,
                   "Initial arrangement moved saved manual positions")
        let measuredReopened = CanvasLayout(directory: layoutDirectory)
        try measuredReopened.open(directory.appendingPathComponent("different.org"))
        try expect(measuredReopened.cards == restored.cards, "Measured layout did not survive reopening")
        print("PASS measured initial arrangement and saved-position protection")

        let layoutSource = try Data(contentsOf: file)
        let projectID = session.roots[0].id
        for position in [
            CardPlacement(x: -125_000, y: 275_000, color: 3, expanded: true),
            CardPlacement(x: 180_000, y: -90_000, color: 1, expanded: false)
        ] {
            try layout.edit { try $0.update(projectID, position) }
            var area = layout.groups[0]
            area.x = position.x * 2
            area.y = position.y * 2
            try layout.edit { try $0.updateGroup(area) }
            let roundTrip = CanvasLayout(directory: layoutDirectory)
            try roundTrip.open(file)
            try expect(roundTrip.cards[projectID] == position, "Signed card position changed after reopening")
            try expect(roundTrip.groups == [area], "Signed area position changed after reopening")
        }
        try expect(try Data(contentsOf: file) == layoutSource, "Canvas movement changed Org content")
        print("PASS negative and distant card and area positions; Org content unchanged")

        let camera = CanvasCamera(x: -84_000, y: 120_000, zoom: 0.125)
        try layout.edit { try $0.updateCamera(camera) }
        let history = CanvasLayout(directory: layoutDirectory)
        try history.open(file)
        try expect(history.camera == camera, "Camera did not survive reopening")
        try expect(!history.canUndo && !history.canRedo, "Layout history survived reopening")
        let movedCamera = CanvasCamera(x: 32_000, y: -64_000, zoom: 2)
        try history.edit { try $0.updateCamera(movedCamera) }
        try expect(!history.canUndo && !history.canRedo, "Camera movement entered layout history")
        let initialCards = history.cards
        let initialGroups = history.groups
        let areaID = UUID().uuidString
        try history.edit { try $0.addGroup(id: areaID, x: -4200, y: 9000) }
        let addedGroups = history.groups
        try expect(addedGroups.last?.x == -4200 && addedGroups.last?.y == 9000, "Area position changed")
        try history.edit { $0.undo() }
        try expect(history.groups == initialGroups && history.canRedo, "Undo did not remove the added area")
        try history.edit { $0.redo() }
        try expect(history.groups == addedGroups && history.canUndo, "Redo did not restore the area")
        try history.edit { try $0.arrange([projectID]) }
        let arrangedCards = history.cards
        try history.edit { $0.undo() }
        try expect(history.cards == initialCards, "Undo did not restore card positions")
        try history.edit { $0.redo() }
        try expect(history.cards == arrangedCards, "Redo did not restore arranged cards")
        try history.edit { try $0.deleteGroup(areaID) }
        try history.edit { $0.undo() }
        try expect(history.groups == addedGroups, "Undo did not restore the deleted area")
        try history.edit { $0.redo() }
        try expect(history.groups == initialGroups, "Redo did not delete the area")
        try expect(history.camera == movedCamera, "Layout undo changed the camera")
        let historyReopened = CanvasLayout(directory: layoutDirectory)
        try historyReopened.open(file)
        try expect(historyReopened.cards == history.cards && historyReopened.groups == history.groups,
                   "Undo and redo results did not survive reopening")
        try expect(historyReopened.camera == movedCamera, "Camera changed during layout edits")

        let storage = history.layoutURL!
        var outside = try Data(contentsOf: storage)
        outside.append(Data("\n".utf8))
        try outside.write(to: storage, options: .atomic)
        let beforeUndoCards = history.cards
        let beforeUndoGroups = history.groups
        let beforeCanUndo = history.canUndo
        let beforeCanRedo = history.canRedo
        do {
            try history.edit { $0.undo() }
            throw Failure(description: "Undo overwrote an external layout edit")
        } catch CanvasLayoutError.changedExternally { }
        try expect(history.cards == beforeUndoCards && history.groups == beforeUndoGroups,
                   "Failed undo changed the layout")
        try expect(history.canUndo == beforeCanUndo && history.canRedo == beforeCanRedo,
                   "Failed undo changed layout history")
        try expect(try Data(contentsOf: storage) == outside, "Failed undo overwrote the external layout")

        var oldLayout = try JSONSerialization.jsonObject(with: outside) as! [String: Any]
        oldLayout.removeValue(forKey: "camera")
        try JSONSerialization.data(withJSONObject: oldLayout).write(to: storage, options: .atomic)
        let oldReopened = CanvasLayout(directory: layoutDirectory)
        try oldReopened.open(file)
        try expect(oldReopened.camera == CanvasCamera(), "A layout without a camera lost its default view")
        try expect(oldReopened.cards == beforeUndoCards && oldReopened.groups == beforeUndoGroups,
                   "A layout without a camera lost its cards or areas")
        try expect(try Data(contentsOf: file) == layoutSource, "Camera or layout history changed Org content")
        print("PASS camera persistence, older layouts, layout undo and redo, and failed undo protection")

        let crlfFile = directory.appendingPathComponent("windows.org")
        let crlfText = "#+TITLE: Windows\r\n* First\r\nFirst body.\r\n\r\n* Second\r\nLast body."
        try Data(crlfText.utf8).write(to: crlfFile)
        try session.open(crlfFile)
        _ = try session.edit { try $0.moveRoot(session.roots[1].id, offset: -1) }
        let reordered = "#+TITLE: Windows\r\n* Second\r\nLast body.\r\n* First\r\nFirst body.\r\n\r\n"
        try expect(try Data(contentsOf: crlfFile) == Data(reordered.utf8),
                   "Reordering changed CRLF separators or blank lines")
        _ = try session.edit { try $0.moveRoot(session.roots[0].id, offset: 1) }
        let restoredCRLF = "#+TITLE: Windows\r\n* First\r\nFirst body.\r\n\r\n* Second\r\nLast body.\r\n"
        try expect(try Data(contentsOf: crlfFile) == Data(restoredCRLF.utf8),
                   "Reordering back changed CRLF separators")
        try Data("* First\r\n* Second".utf8).write(to: crlfFile)
        try session.open(crlfFile)
        _ = try session.edit { try $0.moveRoot(session.roots[1].id, offset: -1) }
        try expect(try Data(contentsOf: crlfFile) == Data("* Second\r\n* First".utf8),
                   "Reordering added a final newline or left a trailing carriage return")
        try session.edit { try $0.addProject(title: "Third") }
        try expect(try Data(contentsOf: crlfFile) == Data("* Second\r\n* First\r\n* Third\r\n".utf8),
                   "Appending a heading introduced a bare line feed")
        try reopened.open(crlfFile)
        try expect(reopened.roots.map(\.title) == ["Second", "First", "Third"],
                   "CRLF headings failed to reopen")
        print("PASS CRLF reordering, blank separators, append, and reopen")

        let idFile = directory.appendingPathComponent("identity.org")
        let idText = "* Original title\n:PROPERTIES:\n:ID: stable-heading\n:END:\nUnchanged body.\n"
        try Data(idText.utf8).write(to: idFile)
        try session.open(idFile)
        let previous = session.roots[0]
        try Data(idText.replacingOccurrences(of: "Original title", with: "External title").utf8)
            .write(to: idFile, options: .atomic)
        try session.checkForExternalChanges(reload: true)
        try expect(session.roots[0].id == previous.id && session.roots[0].body == previous.body
                   && session.roots[0].title == "External title",
                   "Title-only reload changed identity or missed the external title")
        print("PASS external title reload with a stable Org ID")

        let original = URL(fileURLWithPath: CommandLine.arguments[1])
        let originalBytes = try Data(contentsOf: original)
        let copy = directory.appendingPathComponent("actual.org")
        try originalBytes.write(to: copy)
        try session.open(copy)
        let headings = session.roots.count
        func verifyBody(_ heading: OrgHeading) throws {
            let sourceLines = heading.body.components(separatedBy: "\n")
            var renderedLines: [String] = []
            for element in heading.bodyElements {
                switch element {
                case .text(let line, let source):
                    try expect(line == renderedLines.count, "Body text changed order")
                    renderedLines += source.components(separatedBy: "\n")
                case .checkbox(let item):
                    try expect(item.id == renderedLines.count, "Checkbox changed order")
                    renderedLines.append(sourceLines[item.id])
                }
            }
            try expect(renderedLines.joined(separator: "\n") == heading.body, "Body display omitted source text")
            for child in heading.children { try verifyBody(child) }
        }
        for heading in session.roots { try verifyBody(heading) }
        try session.edit { try $0.addProject(title: "Behavior check") }
        try reopened.open(copy)
        try expect(reopened.roots.count == headings + 1, "Real-file copy failed to save and reopen")
        try expect(try Data(contentsOf: original) == originalBytes, "Original file changed")
        print("PASS actual file copy: \(headings) projects; original unchanged")
        try StartupCheck.run(applicationURL: URL(fileURLWithPath: CommandLine.arguments[2]), documentURL: copy)
        try expect(try Data(contentsOf: original) == originalBytes, "Startup changed the original file")
        let applicationURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let fixtureURL = applicationURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/Interaction.org")
        let interactionFile = directory.appendingPathComponent("interaction.org")
        try files.copyItem(at: fixtureURL, to: interactionFile)
        let interactionLayout = CanvasLayout()
        try interactionLayout.open(interactionFile)
        defer {
            if let url = interactionLayout.layoutURL { try? files.removeItem(at: url) }
        }
        try interactionLayout.edit { state in
            for (id, x, y) in [("root", 60.0, 60.0), ("other", 450.0, 60.0),
                               ("archive", 850.0, 60.0), ("delete", 850.0, 550.0)] {
                try state.update("org:e2e-" + id, CardPlacement(x: x, y: y, color: 0, expanded: false))
            }
        }
        try StartupCheck.run(applicationURL: applicationURL, documentURL: interactionFile, cleanupLayout: false) { app, layoutURL in
            try UIWorkflowTests.run(app: app, documentURL: interactionFile, layoutURL: layoutURL)
        }
        try StartupCheck.run(applicationURL: applicationURL, documentURL: interactionFile) { app, layoutURL in
            try UIWorkflowTests.verifyRestored(app: app, documentURL: interactionFile, layoutURL: layoutURL)
        }
        try expect(try Data(contentsOf: original) == originalBytes, "UI tests changed the original file")
        print("All core, file, startup, and UI workflow checks passed.")
    }
}
