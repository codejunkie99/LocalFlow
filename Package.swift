// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LocalFlowCore", targets: ["LocalFlowCore"]),
        .library(name: "LocalFlowPlatform", targets: ["LocalFlowPlatform"]),
        .executable(name: "LocalFlowApp", targets: ["LocalFlowApp"]),
    ],
    targets: [
        .target(name: "LocalFlowCore"),
        .target(name: "LocalFlowPlatform", dependencies: ["LocalFlowCore"]),
        .executableTarget(name: "LocalFlowApp", dependencies: ["LocalFlowCore", "LocalFlowPlatform"]),
        .testTarget(name: "LocalFlowPlatformTests", dependencies: ["LocalFlowCore", "LocalFlowPlatform"]),
    ]
)
