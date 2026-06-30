// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cachesweep",
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
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
