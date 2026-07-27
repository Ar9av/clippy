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
        .executableTarget(
            name: "ClippyMac",
            path: "Sources/ClippyMac",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Security")
            ]
        )
    ]
)
