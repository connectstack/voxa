// swift-tools-version: 6.2
import PackageDescription

// Every target is compiled in the Swift 6 language mode (complete strict concurrency) with
// `ExistentialAny`, so protocol existentials are always spelled `any Protocol`.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let keyboardShortcuts: Target.Dependency = .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
let whisperKit: Target.Dependency = .product(name: "WhisperKit", package: "WhisperKit")

let package = Package(
    name: "Voxa",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // The Xcode app shell (project.yml) links this one product; everything else is transitive.
        .library(name: "VoxaApp", targets: ["VoxaApp"]),
        .executable(name: "voxa-dev", targets: ["VoxaDev"]),
    ],
    dependencies: [
        // Global hotkey registration + recorder UI. Justification: robust Carbon hotkey handling, key-up events
        // for push-to-talk, layout-aware shortcut formatting and system-shortcut conflict detection.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0"),
        // Whisper speech recognition, run on this Mac through Core ML. Justification: the spec names it as the optional local
        // engine; it is the maintained Core ML port, and it is confined to one module (VoxaWhisper) so that nothing else
        // depends on it and nothing is downloaded unless the person chooses a model in Settings.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
    ],
    targets: [
        // MARK: Shared kernel
        .target(name: "VoxaCore", swiftSettings: strict),

        // MARK: Capabilities (each depends only on VoxaCore)
        .target(name: "VoxaAudio", dependencies: ["VoxaCore"], swiftSettings: strict),
        .target(name: "VoxaSpeech", dependencies: ["VoxaCore"], swiftSettings: strict),
        // The Whisper engine: the one module that carries the WhisperKit library.
        .target(name: "VoxaWhisper", dependencies: ["VoxaCore", "VoxaSpeech", whisperKit], swiftSettings: strict),
        // Text to speech: speaking replies aloud with the system's voices.
        .target(name: "VoxaVoice", dependencies: ["VoxaCore"], swiftSettings: strict),
        .target(name: "VoxaPermissions", dependencies: ["VoxaCore"], swiftSettings: strict),
        .target(name: "VoxaHUD", dependencies: ["VoxaCore"], swiftSettings: strict),
        .target(
            name: "VoxaSettings",
            dependencies: ["VoxaCore", "VoxaSpeech", "VoxaLLM", "VoxaPermissions", "VoxaVoice", keyboardShortcuts],
            swiftSettings: strict
        ),
        // Model clients (Claude, OpenAI, Ollama) over URLSession with a shared streaming engine, and API key storage.
        .target(name: "VoxaLLM", dependencies: ["VoxaCore"], swiftSettings: strict),
        // Risk decisions, the untrusted-data envelope, and static analysis of URLs and scripts.
        .target(name: "VoxaPolicy", dependencies: ["VoxaCore"], swiftSettings: strict),
        // Concrete tools. Each system touchpoint sits behind a protocol so the logic is testable.
        .target(name: "VoxaTools", dependencies: ["VoxaCore", "VoxaPolicy"], swiftSettings: strict),
        .target(
            name: "VoxaAgent",
            dependencies: ["VoxaCore", "VoxaLLM", "VoxaPolicy"],
            resources: [.process("Resources")],
            swiftSettings: strict
        ),

        // MARK: Composition root
        .target(
            name: "VoxaApp",
            dependencies: [
                "VoxaCore", "VoxaAudio", "VoxaSpeech", "VoxaWhisper", "VoxaVoice", "VoxaPermissions", "VoxaHUD", "VoxaSettings",
                "VoxaAgent", "VoxaLLM", "VoxaPolicy", "VoxaTools",
                keyboardShortcuts,
            ],
            swiftSettings: strict
        ),

        // MARK: Developer tooling and test doubles
        .executableTarget(
            name: "VoxaDev",
            dependencies: [
                "VoxaCore", "VoxaAudio", "VoxaSpeech", "VoxaWhisper", "VoxaVoice", "VoxaPermissions", "VoxaHUD", "VoxaSettings",
                "VoxaAgent", "VoxaLLM", "VoxaPolicy", "VoxaTools",
            ],
            swiftSettings: strict
        ),
        .target(
            name: "VoxaTestSupport",
            dependencies: [
                "VoxaCore", "VoxaAudio", "VoxaSpeech", "VoxaVoice", "VoxaPermissions", "VoxaHUD", "VoxaLLM", "VoxaPolicy",
                "VoxaAgent", "VoxaTools",
            ],
            swiftSettings: strict
        ),

        // MARK: Tests
        .testTarget(name: "VoxaCoreTests", dependencies: ["VoxaCore", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaAudioTests", dependencies: ["VoxaAudio", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaSpeechTests", dependencies: ["VoxaSpeech", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaWhisperTests", dependencies: ["VoxaWhisper", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaVoiceTests", dependencies: ["VoxaVoice", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaPermissionsTests", dependencies: ["VoxaPermissions", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaHUDTests", dependencies: ["VoxaHUD", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaSettingsTests", dependencies: ["VoxaSettings", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaLLMTests", dependencies: ["VoxaLLM", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaPolicyTests", dependencies: ["VoxaPolicy", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxaToolsTests", dependencies: ["VoxaTools", "VoxaPolicy", "VoxaAgent", "VoxaTestSupport"], swiftSettings: strict),
        .testTarget(
            name: "VoxaAgentTests",
            dependencies: ["VoxaAgent", "VoxaLLM", "VoxaPolicy", "VoxaTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(name: "VoxaAppTests", dependencies: ["VoxaApp", "VoxaTestSupport"], swiftSettings: strict),
    ]
)
