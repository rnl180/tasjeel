// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tasjeel",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Tasjeel", targets: ["Tasjeel"]),
        .library(name: "TasjeelCore", targets: ["TasjeelCore"]),
    ],
    targets: [
        // Recording engine, project model, compositor and export. No UI.
        .target(
            name: "TasjeelCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The SwiftUI app.
        .executableTarget(
            name: "Tasjeel",
            dependencies: ["TasjeelCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TasjeelCoreTests",
            dependencies: ["TasjeelCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
