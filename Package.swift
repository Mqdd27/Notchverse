// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notchverse",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LyricsCore", targets: ["LyricsCore"])],
    targets: [
        .target(name: "LyricsCore"),
        .testTarget(name: "LyricsCoreTests", dependencies: ["LyricsCore"]),
    ]
)

#if os(macOS) // the app is macOS-only; LyricsCore stays testable on Linux
package.targets.append(.executableTarget(
    name: "Notchverse",
    dependencies: ["LyricsCore"],
    path: "App",
    swiftSettings: [.swiftLanguageMode(.v5)]
))
#endif
