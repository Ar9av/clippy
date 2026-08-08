// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ClippyMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Clippy", targets: ["ClippyMac"]),
        .executable(name: "clippy-eval", targets: ["ClippyEval"])
    ],
    dependencies: [
        // Local on-device transcription for dictation, used as an optional
        // alternative to Apple's Speech framework (see SpeechService.swift).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "ClippyCore",
            path: "Sources/ClippyCore",
            // The compiled Prismor policy that defines every screen refusal.
            // A resource rather than a string constant so it stays inspectable
            // and diffable; `.copy` (not `.process`) keeps it byte-identical
            // to what `scripts/compile-policy.sh` produced.
            resources: [
                .copy("Resources/prismor-policy.json")
            ]
        ),
        .executableTarget(
            name: "ClippyMac",
            dependencies: [
                "ClippyCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/ClippyMac",
            resources: [
                .copy("Resources/ClippySprites.png"),
                .copy("Resources/ClippyAnimations.json")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Security"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .executableTarget(
            name: "ClippyEval",
            dependencies: ["ClippyCore"],
            path: "Sources/ClippyEval",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "ClippyMacTests",
            dependencies: ["ClippyMac", "ClippyCore"],
            path: "Tests/ClippyMacTests"
        )
    ]
)
