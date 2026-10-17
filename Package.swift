// swift-tools-version: 6.4
import PackageDescription

// SidayKit: every player and chip, and nothing else. It depends on no other package and uses no
// Foundation, so it builds wherever Swift does, and this repository can be added to another package
// as it is. The front ends are packages of their own beside it, each depending on this one: the
// command-line player in CLI/ and the web player in Web/.
let package = Package(
    name: "siday",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "SidayKit", targets: ["SidayKit"]),
    ],
    targets: [
        // All emulation lives in one module so per-sample and per-cycle loops are optimised together.
        // The C library's maths functions are declared directly (Core/Maths.swift), which is what the
        // Extern feature allows.
        .target(name: "SidayKit", swiftSettings: [.enableExperimentalFeature("Extern")]),
        .testTarget(name: "SidayKitTests", dependencies: ["SidayKit"]),
    ]
)
