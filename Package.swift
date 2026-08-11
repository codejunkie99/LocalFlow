// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LocalFlowCore", targets: ["LocalFlowCore"]),
        .library(name: "LocalFlowPlatform", targets: ["LocalFlowPlatform"]),
        .executable(name: "LocalFlowApp", targets: ["LocalFlowApp"]),
        .executable(name: "LocalFlowUpdater", targets: ["LocalFlowUpdater"]),
    ],
    targets: [
        .target(name: "LocalFlowCore"),
        .target(
            name: "LocalFlowPlatform",
            dependencies: ["LocalFlowCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(name: "LocalFlowApp", dependencies: ["LocalFlowCore", "LocalFlowPlatform"]),
        .executableTarget(name: "LocalFlowUpdater", dependencies: ["LocalFlowCore"]),
        .testTarget(name: "LocalFlowPlatformTests", dependencies: ["LocalFlowCore", "LocalFlowPlatform"]),
    ]
)
