// swift-tools-version: 6.0
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "cc-unibrow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Unibrow", targets: ["Unibrow"]),
        .executable(name: "unibrow-hook", targets: ["UnibrowHook"]),
    ],
    targets: [
        // Pure, UI-free logic shared by the app and the hook relay: wire protocol,
        // Claude Code hook payloads, the pending-request queue and tool summaries.
        .target(
            name: "UnibrowCore",
            swiftSettings: strictSettings
        ),
        // The notch app (SwiftUI + AppKit).
        .executableTarget(
            name: "Unibrow",
            dependencies: ["UnibrowCore"],
            swiftSettings: strictSettings
        ),
        // The tiny relay Claude Code runs as a hook. Must stay fast and must never
        // break a session: on any failure it exits 0 without output.
        .executableTarget(
            name: "UnibrowHook",
            dependencies: ["UnibrowCore"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "UnibrowCoreTests",
            dependencies: ["UnibrowCore"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
