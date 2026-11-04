// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cutscene",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cutscene", targets: ["Cutscene"]),
        .executable(name: "cutscene-check", targets: ["CutsceneCheck"]),
        .executable(name: "cutscene-spike", targets: ["CutsceneSpike"]),
        .library(name: "CutsceneCore", targets: ["CutsceneCore"]),
        .library(name: "CutsceneEngine", targets: ["CutsceneEngine"]),
    ],
    targets: [
        // Shared vocabulary: projects, recordings, timeline, brand kits. No AppKit.
        .target(name: "CutsceneCore"),

        // Pure math behind the signature effects: cursor smoothing, auto-zoom,
        // easing. No AppKit, so every algorithm is unit-testable in milliseconds.
        .target(name: "CutsceneEngine", dependencies: ["CutsceneCore"]),

        // ScreenCaptureKit, camera, microphone, cursor and input-event capture.
        .target(name: "CutsceneCapture", dependencies: ["CutsceneCore"]),

        // Metal compositor: captured frames + cursor + zoom + background → video frames.
        .target(name: "CutsceneRender", dependencies: ["CutsceneCore", "CutsceneEngine"]),

        // AVAssetWriter / VideoToolbox export to MP4 and friends.
        .target(name: "CutsceneExport", dependencies: ["CutsceneCore", "CutsceneRender"]),

        // The SwiftUI app.
        .executableTarget(
            name: "Cutscene",
            dependencies: [
                "CutsceneCore", "CutsceneEngine", "CutsceneCapture",
                "CutsceneRender", "CutsceneExport",
            ]
        ),

        // Check runner: verifies the pure modules with plain Swift so `make check`
        // works with the Command Line Tools alone (no XCTest or Swift Testing).
        // CutsceneRender is linked for `RenderStyle`, which is pure Swift.
        .executableTarget(name: "CutsceneCheck", dependencies: ["CutsceneCore", "CutsceneEngine", "CutsceneRender"]),

        // Spike runner: throwaway experiments that prove a platform path on this
        // machine (`make spike ARGS="writer"`). Not product code.
        .executableTarget(
            name: "CutsceneSpike",
            dependencies: ["CutsceneCapture", "CutsceneCore", "CutsceneEngine", "CutsceneRender", "CutsceneExport"]),

        .testTarget(name: "CutsceneCoreTests", dependencies: ["CutsceneCore"]),
        .testTarget(name: "CutsceneEngineTests", dependencies: ["CutsceneEngine"]),
    ]
)
