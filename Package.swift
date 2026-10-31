// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Cadence",
            path: "Sources/Cadence",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Lets InjectionIII swap in recompiled functions while the app runs.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug))]
        )
    ]
)
