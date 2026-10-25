// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Draws the pictures of the chips for the web player, as the app draws them (App/Siday/Views/
// ChipCard.swift), into a folder: for each chip, NAME.jpg, its picture with its markings, 512 pixels
// square, for the browser's own Now Playing; and NAME-small.jpg, its short name alone, 192 pixels
// square, for the player and the list. Compiled with that file and the two that say what the chips
// are, by Web/build.sh:
//
//     swiftc -parse-as-library Sources/SidayFoundation/TuneFormat.swift Sources/SidayFoundation/SoundChip.swift \
//         App/Siday/Views/ChipCard.swift Scripts/chip-pictures.swift -o chip-pictures && ./chip-pictures FOLDER

import AppKit
import SwiftUI

@main
enum ChipPictures {
    @MainActor
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for chip in SoundChip.allCases {
            // (Up to 100 points, only the short name; from there, the markings too.)
            for (side, suffix) in [(256.0, ""), (96.0, "-small")] {
                guard let image = ChipArt.image(chip, side: side, scale: 2),
                      let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
                else { throw CocoaError(.fileWriteUnknown) }
                try jpeg.write(to: folder.appendingPathComponent("\(chip.rawValue)\(suffix).jpg"))
            }
        }
    }
}
