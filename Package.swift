// swift-tools-version: 6.0
import PackageDescription

// Cadence for macOS. Release builds update themselves with Sparkle, whose
// framework scripts/bundle.sh copies into Contents/Frameworks.
let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Cadence",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Cadence",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
