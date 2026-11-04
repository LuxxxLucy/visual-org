import OrgCore

struct OrgTests {
    static func testBodyContentSnapshots() throws {
        try testOrderedBodyElements()
        let body = """
        :PROPERTIES:
        :ID: body-content
        :END:
        Original notes.
        #+BEGIN_SRC text
        - [ ] Literal checkbox.
        #+END_SRC
        - [ ] Parent item
          Parent details.
          - [X] Child item
            Child details.
        """
        var document = OrgDocument(text: "* Tasks\n" + body + "\n")
        let original = document.roots[0]
        try equal(original.checkboxes.map(\.title), ["Parent item", "Child item"])
        try equal(original.checkboxes.map(\.details), ["Parent details.", "Child details."])
        try equal(original.notePreview, "Original notes.\n#+BEGIN_SRC text\n- [ ] Literal checkbox.\n#+END_SRC")
        let updatedBody = body.replacingOccurrences(of: "Original", with: "Revised")
            .replacingOccurrences(of: "Parent item", with: "Changed parent")
        _ = try document.updateDetails(original.id, title: original.title, body: updatedBody,
                                       expectedTitle: original.title, expectedBody: original.body)
        let updated = document.roots[0]
        try equal(updated.body, updatedBody + "\n")
        try equal(updated.checkboxes.map(\.title), ["Changed parent", "Child item"])
        try equal(updated.notePreview, original.notePreview.replacingOccurrences(of: "Original", with: "Revised"))
        try equal(original.checkboxes[0].title, "Parent item")
        try check(original.notePreview.hasPrefix("Original notes."))
        try equal(OrgDocument(text: document.text).roots[0], updated)
        try document.setCheckbox(updated.id, item: updated.checkboxes[0], checked: true)
        try equal(document.roots[0].checkboxes.map(\.state), ["X", "X"])
        try equal(updated.checkboxes.map(\.state), [" ", "X"])
        try equal(document.roots[0].notePreview, updated.notePreview)
        try document.addCheckbox(updated.id, title: "New item")
        try equal(document.roots[0].checkboxes.map(\.title), ["Changed parent", "Child item", "New item"])
        try equal(OrgDocument(text: document.text).roots[0], document.roots[0])
    }

    private static func testOrderedBodyElements() throws {
        let lines = ["Intro [[https://example.com][link]].", "", "- [ ] First", "Between", "  Detail",
                     "  - [X] Child", "After child", ":PROPERTIES:", "- [ ] Drawer literal", ":END:",
                     "#+CUSTOM: value", "#+BEGIN_SRC text", "- [ ] Code literal", "#+END_SRC_extra",
                     "#+END_SRC", "", "- [ ] Last", ""]
        for newline in ["\n", "\r\n"] {
            let body = lines.joined(separator: newline)
            let prefix = "#+TITLE: Example" + newline + newline
            let source = prefix + "* Heading" + newline + body
            let document = OrgDocument(text: source)
            try equal(document.preamble, prefix)
            try equal(document.text, source)
            let heading = document.roots[0]
            try equal(heading.checkboxes.map(\.id), [2, 5, 16])
            let originalLines = body.components(separatedBy: "\n")
            var reconstructed: [String] = []
            var starts: [Int] = []
            for element in heading.bodyElements {
                switch element {
                case .text(let line, let source):
                    try equal(line, reconstructed.count)
                    starts.append(line)
                    reconstructed += source.components(separatedBy: "\n")
                case .checkbox(let item):
                    try equal(item.id, reconstructed.count)
                    starts.append(item.id)
                    reconstructed.append(originalLines[item.id])
                }
            }
            try equal(starts, [0, 2, 3, 5, 6, 16, 17])
            try equal(reconstructed, originalLines)
            let rendered = OrgMarkup.rows(body).map(\.text).joined(separator: "\n")
            for expected in ["Intro", "Between", "After child", ":PROPERTIES:", "Drawer literal", ":END:",
                             "#+CUSTOM: value", "#+BEGIN_SRC text", "Code literal", "#+END_SRC_extra", "#+END_SRC", "Last"] {
                try check(rendered.contains(expected))
            }
            let block = try unwrap(OrgMarkup.rows(body).first { $0.text.hasPrefix("#+BEGIN_SRC") })
            try equal(block.kind, .literal)
            try equal(block.text, lines[11...14].joined(separator: "\n"))
        }
        for source in ["", "\n", "\r\n", "#+TITLE: Without headings\nNotes.\n"] {
            try equal(OrgDocument(text: source).preamble, source)
        }
        try equal(OrgDocument(text: "* Empty\n").preamble, "")
        try check(OrgDocument(text: "* Empty\n").roots[0].bodyElements.isEmpty)
        try equal(OrgMarkup.rows("\n\n").count, 3)
    }

    static func testStableIdentifiersAndExactEdits() throws {
        let tree = OrgDocument(text: "* Parent\n** Child\n*** Nested\n:PROPERTIES:\n:ID: nested\n:END:\n* Other\n")
        try equal(tree.roots[0].find("org:nested")?.title, "Nested")
        try equal(tree.roots[0].find(tree.roots[0].id), tree.roots[0])
        try check(tree.roots[1].find("org:nested") == nil)
        let source = "* TODO Tasks [0/1]\r\n- [ ] Read /中文/ [[https://example.com][reference]].\r\n* Other\r\nKeep.\r\n"
        var document = OrgDocument(text: source)
        let heading = document.roots[0]
        try equal(heading.id, "878c3a4aaaae68a592a3fa7de00e974e1935be30d791252243689f2f0d2c5d52")
        try document.setCheckbox(heading.id, item: heading.checkboxes[0], checked: true)
        let checked = source.replacingOccurrences(of: "[0/1]", with: "[1/1]").replacingOccurrences(of: "[ ]", with: "[X]")
        try equal(document.text, checked)
        try equal(document.roots[0].id, heading.id)
        try document.setPlanning(heading.id, kind: .scheduled, timestamp: "<2028-02-29 Tue 09:30 +1w>", expectedBody: document.roots[0].body)
        let planned = checked.replacingOccurrences(of: "* TODO Tasks [1/1]\r\n", with: "* TODO Tasks [1/1]\r\nSCHEDULED: <2028-02-29 Tue 09:30 +1w>\r\n")
        try equal(document.text, planned)
        try equal(OrgDocument(text: planned).roots[0].planning(.scheduled), "<2028-02-29 Tue 09:30 +1w>")
        try throwsError { try document.setPlanning(heading.id, kind: .deadline, timestamp: "<2027-02-29 Mon>", expectedBody: document.roots[0].body) }
        try equal(document.text, planned)
        try throwsError({ try document.archiving(heading, to: nil, under: nil,
                                                sourcePath: "/workspace/todo.org", timestamp: "[2026-10-24 Sat 12:00]") }) { error in
            guard case OrgError.changedExternally = error else { try check(false); return }
        }
        try equal(document.text, planned)
        let archived = try document.archiving(document.roots[0], to: "* Saved\r\nOriginal.\r\n", under: nil,
                                               sourcePath: "/workspace/todo.org", timestamp: "[2026-10-24 Sat 12:00]")
        try equal(archived.source.text, "* Other\r\nKeep.\r\n")
        try check(archived.archive.text.hasPrefix("* Saved\r\nOriginal.\r\n"))
        try check(archived.archive.text.contains("- [X] Read /中文/ [[https://example.com][reference]]."))
    }
}
