// swift-tools-version: 6.4
import PackageDescription

// The web player, built on SidayPlayer, from the package at the top of this repository. It is two
// WebAssembly modules, made by build.sh: see the files beside this one, which are the site.
let package = Package(
    name: "siday-web",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/elementary-swift/elementary-ui.git", from: "0.8.0"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.59.0"),
    ],
    targets: [
        // Its audio half: SidayPlayer in a worker, with no user interface and no JavaScript library.
        .executableTarget(
            name: "SidayWebAudio",
            dependencies: [.product(name: "SidayPlayer", package: "siday")]
        ),
        // And the page: the playlist and controls, in ElementaryUI.
        .executableTarget(
            name: "SidayWeb",
            dependencies: [
                .product(name: "SidayPlayer", package: "siday"),
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
    ]
)
