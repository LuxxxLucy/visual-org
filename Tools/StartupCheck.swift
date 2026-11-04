import AppKit
import CoreGraphics

@MainActor
enum StartupCheck {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(applicationURL: URL, documentURL: URL, cleanupLayout: Bool = true,
                    exercise: ((NSRunningApplication, URL) throws -> Void)? = nil) throws {
        guard let identifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            throw Failure(message: "The built app has no bundle identifier.")
        }
        let key = "lastOrg" as CFString
        let domain = identifier as CFString
        CFPreferencesAppSynchronize(domain)
        let previousDocument = CFPreferencesCopyAppValue(key, domain)
        let layout = CanvasLayout()
        try layout.open(documentURL)
        let existing = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        var launched: NSRunningApplication?
        var launchError: Error?
        var finished = false
        defer {
            finished = true
            if let launched, !launched.isTerminated {
                launched.terminate()
                wait(until: Date().addingTimeInterval(2)) { launched.isTerminated }
                if !launched.isTerminated {
                    launched.forceTerminate()
                    wait(until: Date().addingTimeInterval(1)) { launched.isTerminated }
                }
            }
            CFPreferencesAppSynchronize(domain)
            if CFPreferencesCopyAppValue(key, domain) as? String == documentURL.path {
                CFPreferencesSetAppValue(key, previousDocument, domain)
                CFPreferencesAppSynchronize(domain)
            }
            if cleanupLayout, let url = layout.layoutURL { try? FileManager.default.removeItem(at: url) }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = [documentURL.path]
        configuration.environment = ["VISUAL_ORG_FILE": documentURL.path]
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { app, error in
            Task { @MainActor in
                if let app, existing.contains(app.processIdentifier) {
                    launchError = Failure(message: "Startup check received an existing app instance.")
                } else if finished {
                    app?.forceTerminate()
                } else {
                    launched = app
                    launchError = error
                }
            }
        }
        let deadline = Date().addingTimeInterval(15)
        var visibleSince: Date?
        var activated = false
        while Date() < deadline {
            if let launchError { throw launchError }
            if let launched {
                guard !launched.isTerminated else {
                    throw Failure(message: "The test app terminated during startup.")
                }
                if launched.isFinishedLaunching && !activated {
                    _ = try UIAutomation(pid: launched.processIdentifier)
                    activated = true
                }
                if hasWindow(processID: launched.processIdentifier) {
                    if visibleSince == nil { visibleSince = Date() }
                    if Date().timeIntervalSince(visibleSince!) >= 3 {
                        print("PASS real app startup: process \(launched.processIdentifier), visible workspace window, three seconds stable")
                        if let exercise, let url = layout.layoutURL { try exercise(launched, url) }
                        return
                    }
                } else { visibleSince = nil }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == launched?.processIdentifier }
        let detail = owned.isEmpty ? "The process has no windows." : "The process has windows outside the visible desktop or below the required size."
        throw Failure(message: "The test app did not show a stable workspace window within 15 seconds. \(detail)")
    }

    private static func hasWindow(processID: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber else { return false }
            return width.doubleValue >= 980 && height.doubleValue >= 650
        }
    }

    private static func wait(until deadline: Date, condition: () -> Bool) {
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
