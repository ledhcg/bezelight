// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bezelight",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BezelightAgents", targets: ["BezelightAgents"]),
        .library(name: "BezelightCore", targets: ["BezelightCore"]),
        .executable(name: "Bezelight", targets: ["Bezelight"]),
        .executable(name: "bezelight-probe", targets: ["BezelightProbe"]),
        .executable(name: "bezelight-hook", targets: ["BezelightHook"]),
    ],
    targets: [
        // Foundation + Darwin only, so the hook helper starts fast (no ScreenCaptureKit, no AppKit).
        .target(name: "BezelightAgents", path: "Sources/BezelightAgents"),
        .target(name: "BezelightCore", dependencies: ["BezelightAgents"], path: "Sources/BezelightCore", resources: [.process("Resources")]),
        .executableTarget(name: "Bezelight", dependencies: ["BezelightCore"], path: "Sources/Bezelight"),
        .executableTarget(name: "BezelightProbe", dependencies: ["BezelightCore"], path: "Sources/BezelightProbe"),
        .executableTarget(name: "BezelightHook", dependencies: ["BezelightAgents"], path: "Sources/BezelightHook"),
        .testTarget(name: "BezelightAgentsTests", dependencies: ["BezelightAgents"], path: "Tests/BezelightAgentsTests"),
        .testTarget(name: "BezelightCoreTests", dependencies: ["BezelightCore", "BezelightAgents"], path: "Tests/BezelightCoreTests"),
    ]
)
