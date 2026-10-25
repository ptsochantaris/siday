// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import SidayKit
@testable import SidayPlayer
@testable import SidayFoundation

/// A ProTracker module of one empty pattern, with a note of its one sample, a square wave, on its first row.
func squareModule() -> [UInt8] {
    var file = [UInt8](repeating: 0, count: 1084)
    for (i, letter) in "square".utf8.enumerated() { file[i] = letter }
    // The first sample: 32 words long, volume 64, looped whole.
    file[20 + 22] = 0; file[20 + 23] = 16
    file[20 + 25] = 64
    file[20 + 28] = 0; file[20 + 29] = 16
    file[950] = 1
    file[951] = 127
    for (i, letter) in "M.K.".utf8.enumerated() { file[1080 + i] = letter }
    var pattern = [UInt8](repeating: 0, count: 1024)
    // Row 0, voice 0: sample 1 at period 428 (C-2).
    pattern[0] = 0x01; pattern[1] = 0xAC; pattern[2] = 0x10
    file += pattern
    file += (0 ..< 32).map { $0 < 16 ? 0x60 : 0xA0 }
    return file
}

@Test func everyExtensionNamesAFormat() {
    let names = TuneFormat.fileExtensions
    #expect(Set(names).count == names.count)
    for name in names {
        #expect(TuneFormat(fileExtension: name) != nil, "\(name)")
        #expect(TuneFormat(fileExtension: name.uppercased()) == TuneFormat(fileExtension: name), "\(name)")
    }
    #expect(!names.contains("masi"))
    #expect(names.contains("669") && names.contains("vgz") && names.contains("p61a") && names.contains("abk"))
}

@Test func otherNamesStandForTheFormatsTheyAlwaysHave() {
    #expect(TuneFormat(fileExtension: "MMDC") == .med)
    #expect(TuneFormat(fileExtension: "gmc") == .gmc)
    #expect(TuneFormat(fileExtension: "p61a") == .mod)
    #expect(TuneFormat(fileExtension: "chan") == .mod)
    #expect(TuneFormat(fileExtension: "kris") == .mod)
    #expect(TuneFormat(fileExtension: "masi") == nil)
    #expect(TuneFormat(fileExtension: "psm") == .psm)
    #expect(TuneFormat(fileExtension: "tiny") == .sonix)
    #expect(TuneFormat(fileExtension: "snd") == .sndh)
    #expect(TuneFormat(fileExtension: "doc") == nil)
}

@Test func tunePlayerSaysWhyAFileWillNotLoad() {
    let player = TunePlayer()
    #expect(!player.load([1, 2, 3], name: "notes.doc"))
    #expect(player.problem == "unknown file type .doc")
    #expect(player.renderer == nil)
    #expect(!player.load([1, 2, 3], name: "broken.mod"))
    #expect(player.problem != nil)
}

@Test func tunePlayerPlaysAModuleAndKnowsItsVoices() {
    let player = TunePlayer()
    #expect(player.load(squareModule(), name: "square.mod"))
    #expect(player.problem == nil)
    #expect(player.format == .mod)
    #expect(player.voiceCount == 4)
    // (Its player names no chip: it is heard as its kind of file is, on the Amiga's.)
    #expect(player.renderer?.info.chips == [])
    #expect(player.info?.chips == [.paula])
    let frames = 1024
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    var loudest: Float = 0
    for _ in 0 ..< 20 {
        #expect(player.pull(into: buffer, frames: frames))
        player.present(buffer, frames: frames)
        for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    }
    #expect(loudest > 0.01)
    #expect(player.position > 0.4)
    player.takeVoices()
    // The first voice played the note, and its light is lit; the others are dark.
    #expect(player.voicesTaken[0] > 0)
    #expect(player.voicesTaken[1] == 0)
}
