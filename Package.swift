// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexMonitor", targets: ["CodexMonitor"])
    ],
    targets: [
        .executableTarget(name: "CodexMonitor"),
        .testTarget(name: "CodexMonitorTests", dependencies: ["CodexMonitor"])
    ],
    swiftLanguageModes: [.v5]
)
