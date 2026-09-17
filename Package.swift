// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AwayBlur",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AwayBlur",
            path: "Sources/AwayBlur",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
