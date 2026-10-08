// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "siday",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SidayKit", targets: ["SidayKit"]),
        .executable(name: "siday", targets: ["siday"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // For the web player only.
        .package(url: "https://github.com/elementary-swift/elementary-ui.git", from: "0.8.0"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.59.0"),
    ],
    targets: [
        // All emulation lives in one module so per-sample and per-cycle loops are optimised together.
        // It uses no Foundation, so it builds wherever Swift does. The C library's maths functions are
        // declared directly (Core/Maths.swift), which is what the Extern feature allows.
        .target(name: "SidayKit", swiftSettings: [.enableExperimentalFeature("Extern")]),
        .executableTarget(
            name: "siday",
            dependencies: [
                "SidayKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The web player (see Web/) is two WebAssembly modules. This one is its audio half: SidayKit in a
        // worker, with no user interface and no JavaScript library.
        .executableTarget(name: "SidayWebAudio", dependencies: ["SidayKit"]),
        // And this is the page: the playlist and controls, in ElementaryUI.
        .executableTarget(
            name: "SidayWeb",
            dependencies: [
                "SidayKit",
                .product(name: "ElementaryUI", package: "elementary-ui"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableExperimentalFeature("Extern"),
            ],
            plugins: [
                .plugin(name: "BridgeJS", package: "JavaScriptKit"),
            ]
        ),
        .testTarget(name: "SidayKitTests", dependencies: ["SidayKit"]),
        .testTarget(name: "sidayTests", dependencies: ["siday"]),
    ]
)
