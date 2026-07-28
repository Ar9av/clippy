// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ClippyMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Clippy", targets: ["ClippyMac"])
    ],
    targets: [
        .target(
            name: "ClippyCore",
            path: "Sources/ClippyCore"
        ),
        .executableTarget(
            name: "ClippyMac",
            dependencies: ["ClippyCore"],
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
        .testTarget(
            name: "ClippyMacTests",
            dependencies: ["ClippyMac", "ClippyCore"],
            path: "Tests/ClippyMacTests"
        )
    ]
)
