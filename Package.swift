// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacAutoBridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.16.0"),
    ],
    targets: [
        .executableTarget(
            name: "MacAutoBridge",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/MacAutoBridge",
            resources: [
                .copy("Resources"),
            ]
        )
    ]
)
