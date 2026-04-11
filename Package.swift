// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacAutoBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacAutoBridge",
            path: "Sources/MacAutoBridge"
        )
    ]
)
