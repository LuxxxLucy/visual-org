import OrgCore
import AppKit
import SwiftUI

struct PlanningEditor: View {
    let heading: OrgHeading
    let kind: OrgPlanningKind
    @ObservedObject var session: EditorSession
    let save: (String?) throws -> Void
    let dismiss: () -> Void
    @State private var date = Date()
    @State private var includeTime = false
    @State private var raw = ""
    @State private var rawMode = false
    @State private var calendarChanged = false
    @State private var error: String?
    private var original: String? { heading.planning(kind) }
    private var label: String { kind == .scheduled ? "Schedule" : "Deadline" }
    private var timestamp: String {
        if rawMode { return raw }
        if !calendarChanged, let original { return original }
        return "<" + formatter(includeTime ? "yyyy-MM-dd EEE HH:mm" : "yyyy-MM-dd EEE").string(from: date) + ">"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(label).font(.system(size: 18, weight: .semibold))
            Text(AttributedString(NativeOrgText.attributed(heading.title, font: .systemFont(ofSize: 13), color: .labelColor))).lineLimit(2)
            if rawMode {
                TextField("<2026-10-24 Sat 09:00>", text: Binding(get: { raw }, set: {
                    raw = $0
                    session.isDirty = timestamp != original
                }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Org timestamp")
                if let parsed = calendarDate(raw) {
                    Button("Use calendar") {
                        date = parsed.date; includeTime = parsed.hasTime
                        calendarChanged = raw != original; rawMode = false
                        session.isDirty = timestamp != original
                    }.buttonStyle(.link)
                }
            } else {
                DatePicker("Date", selection: Binding(get: { date }, set: {
                    date = $0; calendarChanged = true
                    session.isDirty = timestamp != original
                }), displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date])
                Toggle("Include time", isOn: Binding(get: { includeTime }, set: {
                    includeTime = $0; calendarChanged = true
                    session.isDirty = timestamp != original
                }))
                Button("Edit Org timestamp") { raw = timestamp; rawMode = true; session.isDirty = timestamp != original }
                    .buttonStyle(.link)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                if original != nil { Button("Remove date") { commit(nil) } }
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460).foregroundStyle(ink).background(.white)
        .environment(\.colorScheme, .light).interactiveDismissDisabled(session.isDirty)
        .onAppear {
            session.activate(save: commit)
            guard let original else { return }
            raw = original
            if let parsed = calendarDate(original) {
                date = parsed.date; includeTime = parsed.hasTime
            } else { rawMode = true }
        }
    }

    private func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    private func calendarDate(_ stamp: String) -> (date: Date, hasTime: Bool)? {
        let simple = #"^<[0-9]{4}-[0-9]{2}-[0-9]{2}(?: [A-Za-z]{3})?(?: [0-9]{2}:[0-9]{2})?>$"#
        guard stamp.range(of: simple, options: .regularExpression) != nil else { return nil }
        let hasTime = stamp.contains(":")
        let hasDay = stamp.range(of: #" [A-Za-z]{3}"#, options: .regularExpression) != nil
        let format = "yyyy-MM-dd" + (hasDay ? " EEE" : "") + (hasTime ? " HH:mm" : "")
        guard let date = formatter(format).date(from: String(stamp.dropFirst().dropLast())) else { return nil }
        return (date, hasTime)
    }

    private func commit() { commit(timestamp) }

    private func commit(_ timestamp: String?) {
        do { try save(timestamp); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
