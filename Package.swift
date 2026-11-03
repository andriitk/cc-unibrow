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
        // For other apps that show the same notch (pin a commit or tag).
        .library(name: "UnibrowCore", targets: ["UnibrowCore"]),
        .library(name: "UnibrowNotchUI", targets: ["UnibrowNotchUI"]),
    ],
    targets: [
        // Pure, UI-free logic shared by the app and the hook relay: wire protocol,
        // Claude Code hook payloads, the pending-request queue and tool summaries.
        .target(
            name: "UnibrowCore",
            swiftSettings: strictSettings
        ),
        // The notch's SwiftUI views: the island, its cards and notices. They
        // read and act through `NotchHost`, never through the app itself.
        .target(
            name: "UnibrowNotchUI",
            dependencies: ["UnibrowCore"],
            swiftSettings: strictSettings
        ),
        // The notch app (SwiftUI + AppKit): socket server, panel, menu bar.
        .executableTarget(
            name: "Unibrow",
            dependencies: ["UnibrowCore", "UnibrowNotchUI"],
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
        .testTarget(
            name: "UnibrowNotchUITests",
            dependencies: ["UnibrowNotchUI", "UnibrowCore"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
