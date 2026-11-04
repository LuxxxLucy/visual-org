import AppKit
import Combine
import OrgCore
import SwiftUI
import WorkspaceCore

@MainActor
final class WorkspaceController: ObservableObject {
    @Published private(set) var store: OrgSession
    @Published private(set) var layout: CanvasLayout
    let creationDrafts = CreationDrafts()
    let inlineEdits = InlineDraft()
    let detailsDraft = DetailsDraft()
    let viewport = CanvasViewport()
    @Published private(set) var query = "" { didSet { if query != oldValue && !opening { searchChanged() } } }
    @Published var selected: String? { didSet { detailsDraft.synchronize(focused) } }
    @Published var selectedCards: Set<String> = []
    @Published var inspector = false
    @Published var message: String?
    @Published private(set) var saved = false
    @Published var ignoredExternalChange = false
    @Published var reloadRevision = 0
    @Published var searchIndex = 0
    let editorSession = EditorSession()
    @Published var newTitle = ""
    @Published private(set) var documentID = UUID()
    var viewportSize = CGSize(width: 1380, height: 800)
    private(set) var cardSizes: [String: CGSize] = [:]
    var onRemap: (([String: String], Set<String>) -> Void)?
    private weak var window: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var modelSubscriptions: Set<AnyCancellable> = []
    private var editorWindow: NSWindow?
    private var newParent: OrgHeading?
    private var creating = false
    private var opening = false
    private var viewBeforeSearch: CanvasCamera?
    private var arrangeTask: Task<Void, Never>?
    private var saveNoticeTask: Task<Void, Never>?

    init(store: OrgSession, layout: CanvasLayout) {
        self.store = store
        self.layout = layout
        observeModels()
        viewport.$value.removeDuplicates().debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] camera in
                guard let self, self.store.url != nil, self.query.isEmpty, !self.opening else { return }
                self.perform { try self.layout.edit { try $0.updateCamera(camera) } }
            }.store(in: &subscriptions)
        Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.checkForExternalChanges()
        }.store(in: &subscriptions)
    }

    var hasContentDraft: Bool { detailsDraft.isDirty || editorSession.isDirty || creationDrafts.hasUnsavedEdits || inlineEdits.isDirty }
    var hasDraft: Bool { hasContentDraft || (creating && !newTitle.isEmpty) }
    var camera: CanvasCamera { viewport.value }
    var visible: [OrgHeading] { canvasHeadings.filter { query.isEmpty || matches($0) } }
    var focused: OrgHeading? { selected.flatMap { heading($0) } }
    var activeCardID: String? { selected.flatMap { rootID(for: $0) } }

    func attach(to window: NSWindow) { self.window = window }

    func heading(_ id: String) -> OrgHeading? {
        store.roots.lazy.compactMap { $0.find(id) }.first
    }

    var canvasHeadings: [OrgHeading] {
        func descend(_ heading: OrgHeading) -> [OrgHeading] {
            [heading] + heading.children.filter { layout.openCards.contains($0.id) }.flatMap(descend)
        }
        return store.roots.flatMap(descend)
    }

    private func headingPath(for id: String) -> [OrgHeading] {
        func find(_ heading: OrgHeading) -> [OrgHeading]? {
            if heading.id == id { return [heading] }
            for child in heading.children {
                if let path = find(child) { return [heading] + path }
            }
            return nil
        }
        return store.roots.lazy.compactMap(find).first ?? []
    }

    func parentID(for id: String) -> String? { headingPath(for: id).dropLast().last?.id }

    func rootID(for id: String) -> String? {
        let eligible = Set(canvasHeadings.map(\.id))
        return headingPath(for: id).last { eligible.contains($0.id) }?.id
    }

    func isCardOpen(_ id: String) -> Bool { canvasHeadings.contains { $0.id == id } }

    private func placementIndex(for id: String) -> Int {
        if let index = store.roots.firstIndex(where: { $0.id == id }) { return index }
        func descendants(_ heading: OrgHeading) -> [OrgHeading] {
            heading.children.flatMap { [$0] + descendants($0) }
        }
        return store.roots.count + (store.roots.flatMap(descendants).firstIndex { $0.id == id } ?? 0)
    }

    func placement(for id: String) -> CardPlacement {
        layout.placement(for: id, index: placementIndex(for: id))
    }

    func openCard(_ id: String) {
        guard commitInlineEdit() else { return }
        guard !hasDraft else { report("Save or discard your edits first."); return }
        let path = headingPath(for: id)
        guard !path.isEmpty else { report(OrgError.missingHeading); return }
        do {
            try layout.edit { state in
                let sizes = cardSizes
                func bounds(_ cardID: String, _ placement: CardPlacement) -> CGRect {
                    let height = sizes[cardID].map { Double($0.height) } ?? CardGeometry.height(expanded: placement.expanded)
                    return CGRect(x: placement.x, y: placement.y, width: CardGeometry.width, height: height)
                }
                var occupied = Dictionary(uniqueKeysWithValues: canvasHeadings.map { heading in
                    let placement = state.placement(for: heading.id, index: placementIndex(for: heading.id))
                    return (heading.id, bounds(heading.id, placement))
                })
                for heading in path {
                    if let placement = state.cards[heading.id] {
                        occupied[heading.id] = bounds(heading.id, placement)
                    }
                }
                var placements: [String: CardPlacement] = [:]
                for (parent, child) in zip(path, path.dropFirst()) where state.cards[child.id] == nil {
                    let parentPlacement = placements[parent.id]
                        ?? state.placement(for: parent.id, index: placementIndex(for: parent.id))
                    let siblingIndex = parent.children.firstIndex { $0.id == child.id } ?? 0
                    var childPlacement = CardPlacement(x: parentPlacement.x + 360,
                                                       y: parentPlacement.y + Double(siblingIndex * 48),
                                                       color: 0, expanded: true)
                    while occupied.values.contains(where: { $0.intersects(bounds(child.id, childPlacement)) }) {
                        let nextX = childPlacement.x + 360
                        guard nextX.isFinite, nextX > childPlacement.x else { throw CanvasError.invalidValues }
                        childPlacement.x = nextX
                    }
                    placements[child.id] = childPlacement
                    occupied[child.id] = bounds(child.id, childPlacement)
                }
                try state.setOpen(Set(path.dropFirst().map(\.id)), true, placements: placements)
            }
            query = ""
            _ = select(id, edit: false)
            focus(id)
        } catch { report(error) }
    }

    func closeCard(_ id: String) {
        guard commitInlineEdit() else { return }
        guard !hasDraft else { report("Save or discard your edits first."); return }
        guard let parent = parentID(for: id) else { return }
        do {
            try layout.edit { try $0.setOpen([id], false) }
            _ = select(parent, edit: false)
        } catch { report(error) }
    }

    func matches(_ heading: OrgHeading) -> Bool {
        heading.title.localizedCaseInsensitiveContains(query) ||
        heading.body.localizedCaseInsensitiveContains(query) ||
        heading.tags.localizedCaseInsensitiveContains(query) || heading.children.contains(where: matches)
    }

    func beginInlineEdit(_ key: InlineDraft.Key) -> Bool {
        if inlineEdits.key == key { return true }
        guard commitInlineEdit() else { return false }
        guard !detailsDraft.isDirty, !editorSession.isDirty, editorWindow == nil else {
            report("Save or discard your edits first."); return false
        }
        let id: String
        let target: InlineDraft.Target
        switch key {
        case .title(let headingID):
            id = headingID
            guard let heading = heading(id) else { return false }
            target = .title(heading)
        case .checkbox(let headingID, let line):
            id = headingID
            guard let item = heading(id)?.checkboxes.first(where: { $0.id == line }) else { return false }
            target = .checkbox(id, item)
        }
        guard let rootID = rootID(for: id), select(id, edit: false) else { return false }
        inlineEdits.begin(target, documentID: documentID, rootID: rootID)
        return true
    }

    func updateInlineText(_ text: String) { inlineEdits.update(text) }

    @discardableResult
    func commitInlineEdit() -> Bool {
        guard let target = inlineEdits.target else { return true }
        guard inlineEdits.documentID == documentID else {
            report("The open document changed. Copy or cancel the text edit before continuing.")
            return false
        }
        guard inlineEdits.isDirty else { cancelInlineEdit(); return true }
        do {
            switch target {
            case .title(let heading):
                let changes = try store.edit {
                    try $0.updateDetails(heading.id, title: inlineEdits.text, body: heading.body,
                                         expectedTitle: heading.title, expectedBody: heading.body)
                }
                inlineEdits.clear()
                remapIdentities(changes)
                _ = select(changes.replacements[heading.id] ?? heading.id, edit: false)
            case .checkbox(let id, let item):
                try store.edit { try $0.renameCheckbox(id, item: item, title: inlineEdits.text) }
                inlineEdits.clear()
            }
            objectWillChange.send()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func cancelInlineEdit() {
        inlineEdits.clear()
        objectWillChange.send()
    }

    func setQuery(_ value: String) {
        guard value != query, commitInlineEdit() else { return }
        query = value
    }

    func setExpanded(_ id: String, _ expanded: Bool) {
        guard commitInlineEdit() else { return }
        guard isCardOpen(id) else { return }
        var placement = placement(for: id)
        placement.expanded = expanded
        perform { try layout.edit { try $0.update(id, placement) } }
    }

    func setAllExpanded(_ expanded: Bool) {
        guard commitInlineEdit() else { return }
        let ids = canvasHeadings.map(\.id).sorted { placementIndex(for: $0) < placementIndex(for: $1) }
        perform { try layout.edit { try $0.setExpanded(ids, expanded) } }
    }

    func undoLayout() {
        guard commitInlineEdit() else { return }
        perform { _ = try layout.edit { $0.undo() } }
    }

    func redoLayout() {
        guard commitInlineEdit() else { return }
        perform { _ = try layout.edit { $0.redo() } }
    }

    func setColor(_ id: String, _ color: Int) {
        guard isCardOpen(id) else { return }
        var placement = placement(for: id)
        placement.color = color
        perform { try layout.edit { try $0.update(id, placement) } }
    }

    @discardableResult
    func selectItem(_ id: String) -> Bool {
        guard commitInlineEdit() else { return false }
        guard !detailsDraft.isDirty && !editorSession.isDirty else {
            report("Save or discard your edits first."); return false
        }
        return select(id, edit: false)
    }

    @discardableResult
    func select(_ id: String, edit: Bool) -> Bool {
        guard commitInlineEdit() else { return false }
        guard heading(id) != nil else { report(OrgError.missingHeading); return false }
        guard !(detailsDraft.isDirty || editorSession.isDirty) || selected == id else {
            report("Save or discard your edits first."); return false
        }
        selected = id
        if let root = rootID(for: id) {
            selectedCards = [root]
        }
        if edit { inspector = true }
        return true
    }

    func edit(_ id: String) { _ = select(id, edit: true) }

    func toggleInspector() {
        guard commitInlineEdit() else { return }
        guard !detailsDraft.isDirty else { report("Save or discard your edits first."); return }
        inspector.toggle()
    }

    func selectCards(in rect: CGRect) {
        guard commitInlineEdit() else { return }
        guard !hasDraft else { report("Save or discard your edits first."); return }
        selectedCards = Set(visible.compactMap { heading in
            let p = placement(for: heading.id)
            let size = cardSizes[heading.id] ?? CGSize(width: CardGeometry.width, height: CardGeometry.height(expanded: p.expanded))
            return !rect.isEmpty && rect.intersects(CGRect(x: p.x, y: p.y, width: size.width, height: size.height)) ? heading.id : nil
        })
        selected = selectedCards.count == 1 ? selectedCards.first : nil
        inspector = false
    }

    func selectCardForMovement(_ id: String) -> Bool {
        commitInlineEdit() && (selectedCards.contains(id) || select(id, edit: false))
    }

    func updateCardSize(_ id: String, size: CGSize) {
        guard cardSizes[id] != size else { return }
        cardSizes[id] = size
        arrangeTask?.cancel()
        arrangeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self else { return }
            let heights = self.cardSizes.mapValues { Double($0.height) }
            let center = self.camera.canvasPoint(at: CanvasPoint(x: self.viewportSize.width / 2, y: self.viewportSize.height / 2))
            self.perform {
                try self.layout.edit { state in
                    if state.cards.isEmpty {
                        _ = try state.arrangeInitial(self.store.roots.map(\.id), heights: heights)
                    } else {
                        try state.placeMissing(self.canvasHeadings.map(\.id), heights: heights, near: center)
                    }
                }
            }
        }
    }

    func remapIdentities(_ changes: HeadingChanges) {
        let mapping = changes.replacements
        let removedIDs = changes.removed
        perform { _ = try layout.edit { try $0.remap(mapping, removing: removedIDs) } }
        perform { try creationDrafts.remap(mapping, removing: removedIDs) }
        if let id = selected { selected = removedIDs.contains(id) ? nil : mapping[id] ?? id }
        selectedCards = Set(selectedCards.subtracting(removedIDs).map { mapping[$0] ?? $0 })
        cardSizes = Dictionary(cardSizes.compactMap { id, size in
            removedIDs.contains(id) ? nil : (mapping[id] ?? id, size)
        }, uniquingKeysWith: { _, next in next })
        onRemap?(mapping, removedIDs)
    }

    func setState(_ state: String?) {
        guard commitInlineEdit() else { return }
        guard !hasDraft else { report("Save or discard your edits first."); return }
        guard let selected else { report("Select a project or item first."); return }
        setState(selected, state)
    }

    func setState(_ id: String, _ state: String?) {
        guard selectItem(id) else { return }
        perform { try store.edit { try $0.setState(id, state) } }
    }

    func setPriority(_ id: String, _ priority: String?) {
        guard selectItem(id) else { return }
        perform { try store.edit { try $0.setPriority(id, priority) } }
    }

    func toggleState(_ id: String) {
        guard let heading = heading(id) else { report(OrgError.missingHeading); return }
        let done = store.doneStates.contains(heading.state ?? "")
        let next = store.states.first { store.doneStates.contains($0) != done }
        setState(id, next)
    }

    func toggleCheckbox(_ id: String, item: OrgCheckbox) {
        guard selectItem(id) else { return }
        perform { try store.edit { try $0.setCheckbox(id, item: item, checked: item.state != "X") } }
    }

    func addCheckbox(_ id: String) {
        guard selectItem(id) else { return }
        perform {
            try store.edit { try $0.addCheckbox(id, title: creationDrafts.checkboxText(id)) }
            creationDrafts.updateCheckboxText(id, "")
        }
    }

    func moveRoot(_ id: String, offset: Int) {
        guard selectItem(id) else { return }
        perform {
            let changes = try store.edit { try $0.moveRoot(id, offset: offset) }
            remapIdentities(changes)
        }
    }

    func saveDetails() {
        guard commitInlineEdit() else { return }
        guard let original = detailsDraft.original, select(original.id, edit: true) else { return }
        do {
            let changes = try store.edit {
                try $0.updateDetails(original.id, title: detailsDraft.title, body: detailsDraft.body,
                                     expectedTitle: original.title, expectedBody: original.body)
            }
            remapIdentities(changes)
            let id = changes.replacements[original.id] ?? original.id
            detailsDraft.reset(heading(id))
            _ = select(id, edit: true)
            showSaved()
        } catch { report(error) }
    }

    func discardDetails() { detailsDraft.reset(focused) }

    func saveDocument() {
        saved = false
        guard store.url != nil else { report("Open an Org file first."); return }
        do {
            try store.checkForExternalChanges(reload: false)
            guard !store.changedOnDisk else { presentSaveConflict(); return }
            if editorWindow != nil {
                if !editorSession.save() { report("The editor is still opening. Try Save again.") }
                return
            }
            guard commitInlineEdit() else { return }
            if detailsDraft.isDirty {
                saveDetails()
                guard !detailsDraft.isDirty else { return }
            }
            if creationDrafts.hasUnsavedEdits {
                try store.edit { try creationDrafts.apply(to: &$0) }
                creationDrafts.clear()
                reloadRevision += 1
            }
            guard !hasDraft else { report("Finish the current edit before saving."); return }
            if query.isEmpty { try layout.edit { try $0.updateCamera(camera) } }
            showSaved()
        } catch { report(error) }
    }

    private func showSaved() {
        message = nil
        saved = true
        saveNoticeTask?.cancel()
        saveNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            self?.saved = false
        }
    }

    private func presentSaveConflict() {
        saved = false
        ignoredExternalChange = false
        guard let host = editorWindow ?? window, host.attachedSheet == nil else { return }
        let currentDocument = documentID
        let alert = NSAlert()
        alert.messageText = "The document changed."
        alert.informativeText = "Keep your edits open, or discard them and reload the file from disk."
        alert.addButton(withTitle: "Keep Editing")
        let discard = alert.addButton(withTitle: "Discard and Reload")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""
        alert.beginSheetModal(for: host) { [weak self] response in
            guard let self, self.documentID == currentDocument,
                  response == .alertSecondButtonReturn else { return }
            self.reload()
        }
    }

    @discardableResult
    func addChild(_ id: String) -> Bool {
        guard select(id, edit: true) else { return false }
        do {
            let draft = creationDrafts.heading(id)
            try store.edit { try $0.addChild(id, title: draft.wrappedValue) }
            draft.wrappedValue = ""
            return true
        } catch {
            report(error)
            return false
        }
    }

    func requestPlanning(_ id: String, kind: OrgPlanningKind) {
        guard commitInlineEdit() else { return }
        guard !hasDraft, editorWindow == nil else { report("Save or discard your edits first."); return }
        guard selectItem(id) else { return }
        guard let heading = heading(id) else { return }
        present(PlanningEditor(heading: heading, kind: kind, session: editorSession, save: { [weak self] timestamp in
            guard let self else { return }
            do {
                try self.store.edit { try $0.setPlanning(id, kind: kind, timestamp: timestamp, expectedBody: heading.body) }
                self.showSaved()
            } catch { self.report(error); throw error }
        }, dismiss: { [weak self] in self?.dismissEditor() }))
    }

    func requestPlanning(_ kind: OrgPlanningKind) {
        guard commitInlineEdit() else { return }
        guard let selected else { report("Select a project or item first."); return }
        requestPlanning(selected, kind: kind)
    }

    func editCheckbox(_ id: String, item: OrgCheckbox) {
        guard commitInlineEdit() else { return }
        guard !hasDraft, editorWindow == nil else { report("Save or discard your edits first."); return }
        guard select(id, edit: false) else { return }
        present(CheckboxEditor(item: item, session: editorSession, save: { [weak self] title in
            guard let self else { return }
            do {
                try self.store.edit { try $0.renameCheckbox(id, item: item, title: title) }
                self.showSaved()
            } catch { self.report(error); throw error }
        }, dismiss: { [weak self] in self?.dismissEditor() }))
    }

    func requestDelete(_ heading: OrgHeading) {
        guard commitInlineEdit() else { return }
        guard !hasDraft else { report("Save or discard your edits first."); return }
        confirm("Delete \"\(heading.title)\"?", detail: "The heading, its notes, and its children will be removed from the Org file.", action: "Delete") { [weak self] in
            self?.perform {
                guard let self else { return }
                let changes = try self.store.edit { try $0.delete(heading) }
                self.remapIdentities(changes)
                self.inspector = false
            }
        }
    }

    func requestArchive(_ heading: OrgHeading? = nil) {
        guard commitInlineEdit() else { return }
        guard !hasDraft else { report("Save or discard your edits first."); return }
        guard let heading = heading ?? focused else { report("Select a project or item to archive."); return }
        confirm("Archive \"\(heading.title)\"?", detail: "The item and its children move to the Org archive file.", action: "Move to archive") { [weak self] in
            self?.perform {
                guard let self else { return }
                let update = try self.store.archive(heading)
                self.remapIdentities(update.changes)
                self.inspector = false
            }
        }
    }

    func requestNewHeading(parent: OrgHeading? = nil) {
        guard commitInlineEdit() else { return }
        guard !hasDraft, editorWindow == nil else { report("Save or discard your edits first."); return }
        newParent = parent
        newTitle = ""
        message = nil
        creating = true
        present(NewHeadingPanel(controller: self, isChild: parent != nil))
    }

    func addHeading() {
        guard !hasContentDraft else { report("Save or discard your edits first."); return }
        do {
            if let parent = newParent {
                try store.edit { try $0.addChild(parent.id, title: newTitle) }
                _ = select(parent.id, edit: true)
                focus(parent.id)
            } else {
                try store.edit { try $0.addProject(title: newTitle) }
                if let heading = store.roots.last {
                    var p = layout.placement(for: heading.id, index: store.roots.count - 1)
                    let point = canvasPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                    p.x = point.x - CardGeometry.width / 2; p.y = point.y - CardGeometry.headerHeight / 2
                    perform { try layout.edit { try $0.update(heading.id, p) } }
                    _ = select(heading.id, edit: false)
                    viewBeforeSearch = nil
                    query = ""
                }
            }
            dismissEditor()
            showSaved()
        } catch { report(error) }
    }

    func requestReload() {
        guard hasDraft else { reload(); return }
        confirm("Discard unsaved edits?", detail: "Reload the Org file from disk.", action: "Discard and reload") { [weak self] in self?.reload() }
    }

    func reload() {
        do {
            try store.checkForExternalChanges(reload: true)
            cancelInlineEdit()
            dismissEditor()
            detailsDraft.reset(focused)
            creationDrafts.clear()
            ignoredExternalChange = false
            message = nil
            reloadRevision += 1
        } catch { report(error) }
    }

    func openArchive() { perform { open(try store.archiveURL(for: selected)) } }

    func showDocumentText() {
        guard commitInlineEdit() else { return }
        NativeNotesSheet.present(title: store.url?.lastPathComponent ?? "Document text", text: store.preamble,
                                 documentURL: store.url, from: window)
    }

    func open(_ url: URL) {
        guard commitInlineEdit() else { return }
        guard !hasDraft else { report("Save or discard your edits first."); return }
        guard window?.attachedSheet == nil else { report("Close the current dialog before opening another file."); return }
        do {
            saveCamera()
            opening = true
            defer { opening = false }
            let nextStore = OrgSession()
            let nextLayout = CanvasLayout()
            try nextStore.open(url)
            try nextLayout.open(url)
            store.onChange = nil
            store = nextStore
            layout = nextLayout
            observeModels()
            arrangeTask?.cancel()
            documentID = UUID()
            selected = nil
            selectedCards = []
            inspector = false
            viewBeforeSearch = nil
            query = ""
            viewport.move(to: layout.camera, viewportSize: viewportSize, animated: false)
            cardSizes = [:]
            creationDrafts.clear()
            ignoredExternalChange = false
            message = nil
            reloadRevision += 1
            UserDefaults.standard.set(url.path, forKey: "lastOrg")
        } catch { report(error) }
    }

    func chooseFile() {
        guard commitInlineEdit() else { return }
        guard !hasDraft else { report("Save or discard your edits first."); return }
        guard window?.attachedSheet == nil else { report("Close the current dialog before opening another file."); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .data]
        panel.allowsMultipleSelection = false
        if let window {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    DispatchQueue.main.async { self?.open(url) }
                }
            }
        } else if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func initialOpen() {
        if let path = ProcessInfo.processInfo.environment["VISUAL_ORG_FILE"] { open(URL(fileURLWithPath: path)); return }
        if let path = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".org") || $0.hasSuffix(".org_archive") }) { open(URL(fileURLWithPath: path)); return }
        if let path = UserDefaults.standard.string(forKey: "lastOrg"), FileManager.default.fileExists(atPath: path) { open(URL(fileURLWithPath: path)); return }
        guard let sample = Bundle.main.url(forResource: "Review", withExtension: "org") else { return }
        perform {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("visual-org")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("Review.org")
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: sample, to: target) }
            open(target)
        }
    }

    func saveCamera() {
        if store.url != nil { perform { try layout.edit { try $0.updateCamera(viewBeforeSearch ?? camera) } } }
    }

    func canvasPoint(x: Double, y: Double) -> CGPoint {
        let point = camera.canvasPoint(at: CanvasPoint(x: x, y: y))
        return CGPoint(x: point.x, y: point.y)
    }

    func setZoom(_ value: Double) {
        guard commitInlineEdit() else { return }
        viewport.move(to: camera.zoomed(to: value, around: CanvasPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)), viewportSize: viewportSize)
    }

    func stepZoom(_ direction: CanvasZoomDirection) {
        guard commitInlineEdit() else { return }
        viewport.move(to: camera.zoomed(step: direction, around: CanvasPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)), viewportSize: viewportSize)
    }

    func focus(_ id: String) {
        guard commitInlineEdit() else { return }
        guard let cardID = rootID(for: id) else { return }
        let p = placement(for: cardID)
        viewport.move(to: camera.focused(on: CanvasPoint(x: p.x, y: p.y)), viewportSize: viewportSize)
    }

    func fitAll() {
        guard commitInlineEdit() else { return }
        let cards = visible.map { heading in
            let p = placement(for: heading.id)
            let size = cardSizes[heading.id] ?? CGSize(width: CardGeometry.width, height: CardGeometry.height(expanded: p.expanded))
            return CanvasBounds(x: p.x, y: p.y, width: size.width, height: size.height)
        }
        let areas = layout.groups.map { CanvasBounds(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        if let fitted = CanvasCamera.fitting(cards + areas, width: viewportSize.width, height: viewportSize.height) {
            viewport.move(to: fitted, viewportSize: viewportSize)
        }
    }

    func addGroup() {
        let point = canvasPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        perform { try layout.edit { try $0.addGroup(id: UUID().uuidString, x: point.x - 360, y: point.y - 350) } }
    }

    func moveCards(_ ids: Set<String>, by delta: CGSize) {
        let indices = Dictionary(uniqueKeysWithValues: visible.filter { ids.contains($0.id) }.map {
            ($0.id, placementIndex(for: $0.id))
        })
        perform { try layout.edit { try $0.moveCards(indices, by: CanvasPoint(x: delta.width, y: delta.height)) } }
    }

    func updateGroup(_ group: CanvasGroup) {
        perform { _ = try layout.edit { try $0.updateGroup(group) } }
    }

    func deleteGroup(_ id: String) {
        perform { try layout.edit { try $0.deleteGroup(id) } }
    }

    func arrange(byPriority: Bool) {
        guard commitInlineEdit() else { return }
        confirm("Replace the card positions?", detail: "The current positions will be replaced with an arranged layout.", action: "Arrange cards") { [weak self] in
            guard let self else { return }
            let roots = byPriority ? self.visible.sorted { ($0.priority ?? "Z") < ($1.priority ?? "Z") } : self.visible
            self.perform { try self.layout.edit { try $0.arrange(roots.map(\.id), heights: self.cardSizes.mapValues { Double($0.height) }) } }
            self.fitAll()
        }
    }

    func nextSearchResult() {
        guard commitInlineEdit() else { return }
        guard !visible.isEmpty else { return }
        searchIndex = (searchIndex + 1) % visible.count
        revealSearchResult()
    }

    func report(_ error: Error) {
        saved = false
        if case OrgError.changedExternally = error {
            try? store.checkForExternalChanges(reload: false)
            presentSaveConflict()
        } else {
            report((error as? CanvasError)?.description ?? error.localizedDescription)
        }
    }
    func report(_ message: String) { saved = false; self.message = message }
    func perform(_ action: () throws -> Void) { do { try action() } catch { report(error) } }

    func dismissEditor() {
        if let editorWindow { window?.endSheet(editorWindow); editorWindow.orderOut(nil) }
        editorWindow = nil
        editorSession.clear()
        creating = false
        newTitle = ""
        newParent = nil
    }

    private func present<Content: View>(_ content: Content) {
        guard let window, editorWindow == nil, window.attachedSheet == nil else { return }
        let host = NSHostingController(rootView: content)
        let sheet = NSWindow(contentViewController: host)
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        editorWindow = sheet
        window.beginSheet(sheet)
    }

    private func confirm(_ title: String, detail: String, action: String, perform: @escaping () -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let documentID = documentID
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard self?.documentID == documentID else {
                self?.report("The open document changed. Repeat the action in the current document.")
                return
            }
            perform()
        }
    }

    private func observeModels() {
        modelSubscriptions.removeAll()
        store.onChange = { [weak self, weak observed = store] in
            guard let self, let observed, self.store === observed else { return }
            if !self.store.changedOnDisk { self.ignoredExternalChange = false }
            self.detailsDraft.synchronize(self.focused)
            self.objectWillChange.send()
        }
        layout.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &modelSubscriptions)
    }

    private func checkForExternalChanges() {
        guard store.url != nil else { return }
        perform { try store.checkForExternalChanges(reload: !hasDraft && inlineEdits.target == nil && window?.attachedSheet == nil) }
    }

    private func searchChanged() {
        searchIndex = 0
        if query.isEmpty {
            if let viewBeforeSearch { viewport.move(to: viewBeforeSearch, viewportSize: viewportSize, animated: false) }
            viewBeforeSearch = nil
        } else {
            if viewBeforeSearch == nil { viewBeforeSearch = camera }
            revealSearchResult()
        }
    }

    private func revealSearchResult() {
        guard visible.indices.contains(searchIndex) else { return }
        let heading = visible[searchIndex]
        var p = placement(for: heading.id)
        if !p.expanded { p.expanded = true; perform { try layout.edit { try $0.update(heading.id, p) } } }
        focus(heading.id)
    }
}
