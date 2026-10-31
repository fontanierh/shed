// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shed",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ShedKit", targets: ["ShedKit"]),
        .executable(name: "ShedMac", targets: ["ShedMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    ],
    targets: [
        .target(name: "ShedKit", dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")]),
        .executableTarget(name: "ShedMac", dependencies: ["ShedKit"]),
    ]
)
