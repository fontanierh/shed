// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentRemote",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AgentRemoteKit", targets: ["AgentRemoteKit"]),
        .executable(name: "AgentRemoteMac", targets: ["AgentRemoteMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    ],
    targets: [
        .target(name: "AgentRemoteKit", dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")]),
        .executableTarget(name: "AgentRemoteMac", dependencies: ["AgentRemoteKit"]),
    ]
)
