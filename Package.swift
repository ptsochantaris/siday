// swift-tools-version: 6.4
import PackageDescription

// SidayKit: every player and chip, and nothing else. It depends on no other package and uses no
// Foundation, so it builds wherever Swift does, and this repository can be added to another package
// as it is. The front ends are packages of their own beside it, each depending on this one: the
// command-line player in CLI/ and the web player in Web/; and the app, an Xcode project in App/.
//
// The library is built as several modules, so that they are compiled side by side and each is kept
// small enough for Embedded Swift, which writes the whole of a module's code into its interface. The
// foundation is what every player is made with; the chips and the 68000 are shared by several families
// of players; and SidayKit, the one product, is the loader and the player shell, and brings the
// foundation with it.
let swiftSettings: [SwiftSetting] = [
    // The C library's maths functions are declared directly (SidayFoundation/Maths.swift), which is
    // what the Extern feature allows.
    .enableExperimentalFeature("Extern"),
    // A file imports each module whose declarations it uses, members too, as Embedded Swift requires of
    // the web player's build: so that the native build finds a missing import as well.
    .enableUpcomingFeature("MemberImportVisibility"),
]

func family(_ name: String, _ dependencies: [Target.Dependency]) -> Target {
    .target(name: name, dependencies: dependencies, swiftSettings: swiftSettings)
}

let package = Package(
    name: "siday",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "SidayKit", targets: ["SidayKit"]),
    ],
    targets: [
        family("SidayFoundation", []),
        family("SidayChips", ["SidayFoundation"]),
        family("SidayM68000", ["SidayFoundation"]),
        family("SidayAmigaTrackers", ["SidayFoundation", "SidayChips"]),
        family("SidayAmigaComposers", ["SidayFoundation", "SidayChips"]),
        family("SidayAmigaMachine", ["SidayFoundation", "SidayChips", "SidayM68000"]),
        family("SidayTrackers", ["SidayFoundation", "SidayChips"]),
        family("SidayC64", ["SidayFoundation"]),
        family("SidayEightBit", ["SidayFoundation", "SidayChips"]),
        family("SidayAtari", ["SidayFoundation", "SidayM68000"]),
        family("SidayKit", [
            "SidayFoundation", "SidayChips", "SidayM68000", "SidayAmigaTrackers", "SidayAmigaComposers",
            "SidayAmigaMachine", "SidayTrackers", "SidayC64", "SidayEightBit", "SidayAtari",
        ]),
        .testTarget(name: "SidayKitTests", dependencies: [
            "SidayKit", "SidayFoundation", "SidayChips", "SidayM68000", "SidayAmigaTrackers", "SidayAmigaComposers",
            "SidayAmigaMachine", "SidayTrackers", "SidayC64", "SidayEightBit", "SidayAtari",
        ]),
    ]
)
