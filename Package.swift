// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cachesweep",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Single source of truth shared by the app and the privileged helper:
        // the system-area allowlist and the XPC protocol.
        .target(
            name: "CachesweepCore",
            path: "Sources/CachesweepCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "Cachesweep",
            dependencies: [
                "CachesweepCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Cachesweep",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Root launchd daemon (SMAppService), embedded in the app bundle.
        .executableTarget(
            name: "CachesweepHelper",
            dependencies: ["CachesweepCore"],
            path: "Sources/CachesweepHelper",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "CachesweepTests",
            dependencies: ["Cachesweep"],
            path: "Tests/CachesweepTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
