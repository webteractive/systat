// swift-tools-version: 6.2
import PackageDescription

// Resources/Info.plist is the one place the version is written. It is embedded in
// the executable's __TEXT,__info_plist section, so `Bundle.main` reports it even for
// a bare binary from `swift build`, outside any .app bundle.
let infoPlist = Context.packageDirectory + "/Resources/Info.plist"

let package = Package(
    name: "systat",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SystatCore"),
        .executableTarget(
            name: "systat",
            dependencies: ["SystatCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]
        ),
        .testTarget(name: "SystatCoreTests", dependencies: ["SystatCore"]),
        .testTarget(name: "systatTests", dependencies: ["systat", "SystatCore"]),
    ]
)
