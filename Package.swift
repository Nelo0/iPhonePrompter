// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LensPrompt",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "LensPrompt", targets: ["LensPrompt"]),
        .executable(name: "lensprompt-speech-check", targets: ["SpeechCheck"]),
    ],
    targets: [
        // Pure, testable logic: alignment, prompt control, recording state, layout, storage,
        // timestamp math and the AVAssetWriter-based movie writer.
        .target(
            name: "LensPromptCore",
            path: "Sources/LensPromptCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The macOS app (SwiftUI + AppKit panels + AVFoundation capture + Speech).
        .executableTarget(
            name: "LensPrompt",
            dependencies: ["LensPromptCore"],
            path: "Sources/LensPrompt",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Offline check: runs the real local recognizer on a synthesized audio file
        // (never the microphone) and feeds results through the alignment engine.
        .executableTarget(
            name: "SpeechCheck",
            dependencies: ["LensPromptCore"],
            path: "Tools/SpeechCheck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LensPromptCoreTests",
            dependencies: ["LensPromptCore"],
            path: "Tests/LensPromptCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
