import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition { throw CheckFailure(description: "\(file):\(line): check failed") }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) throws {
    if actual != expected { throw CheckFailure(description: "\(file):\(line): \(actual) != \(expected)") }
}

func equal(_ actual: Double, _ expected: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) throws {
    try check(abs(actual - expected) <= accuracy, file: file, line: line)
}

func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "\(file):\(line): missing value") }
    return value
}

func throwsError<T>(_ operation: () throws -> T, inspect: (Error) throws -> Void = { _ in },
                    file: StaticString = #filePath, line: UInt = #line) throws {
    do { _ = try operation() }
    catch { try inspect(error); return }
    throw CheckFailure(description: "\(file):\(line): expected an error")
}

@main
struct CoreChecks {
    static func main() throws {
        try OrgTests.testStableIdentifiersAndExactEdits()
        try OrgTests.testBodyContentSnapshots()
        try CanvasTests.testAnchoredZoomAndFit()
        try CanvasTests.testIdentitySwapArchiveAndHistory()
        try CanvasTests.testSavedDocumentCompatibilityAndRejectedValues()
        try CanvasTests.testDraftIdentityChanges()
        try CanvasTests.testMoveSelectedCards()
        try SessionTests.run()
        print("PASS eighteen shared-core checks: text, stable IDs, canvas, drafts, conflicts, and rollback")
    }
}
