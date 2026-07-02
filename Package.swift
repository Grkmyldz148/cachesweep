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
        .executableTarget(
            name: "Cachesweep",
            dependencies: [
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
