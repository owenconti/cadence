// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Cadence",
            path: "Sources/Cadence",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
