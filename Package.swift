// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "systat",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SystatCore"),
        .executableTarget(name: "systat", dependencies: ["SystatCore"]),
        .testTarget(name: "SystatCoreTests", dependencies: ["SystatCore"]),
        .testTarget(name: "systatTests", dependencies: ["systat", "SystatCore"]),
    ]
)
