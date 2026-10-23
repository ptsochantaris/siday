// swift-tools-version: 6.4
import PackageDescription

// The command-line player, `siday`, built on SidayPlayer and SidayFiles, from the package at the top
// of this repository.
let package = Package(
    name: "siday-cli",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "siday", targets: ["siday"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "siday",
            dependencies: [
                .product(name: "SidayPlayer", package: "siday"),
                .product(name: "SidayFiles", package: "siday"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "sidayTests", dependencies: ["siday", .product(name: "SidayFiles", package: "siday")]),
    ]
)
