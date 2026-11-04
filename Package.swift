// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "OrgCore", targets: ["OrgCore"]),
    .library(name: "WorkspaceCore", targets: ["WorkspaceCore"])
]
var targets: [Target] = [
    .target(name: "OrgCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
    .target(name: "WorkspaceCore", dependencies: ["OrgCore"]),
    .executableTarget(name: "CoreChecks", dependencies: ["OrgCore", "WorkspaceCore"], path: "Tests/CoreTests")
]
#if os(macOS)
products.append(.executable(name: "visual-org", targets: ["VisualOrg"]))
targets.append(.executableTarget(name: "VisualOrg", dependencies: ["OrgCore", "WorkspaceCore"], path: "Sources/App"))
#endif

let package = Package(
    name: "visual-org",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
    targets: targets
)
