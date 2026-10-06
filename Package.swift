// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "siday",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SidayKit", targets: ["SidayKit"]),
        .executable(name: "siday", targets: ["siday"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // All emulation lives in one module so per-sample and per-cycle loops are optimised together.
        .target(name: "SidayKit"),
        .executableTarget(
            name: "siday",
            dependencies: [
                "SidayKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SidayKitTests", dependencies: ["SidayKit"]),
    ]
)
