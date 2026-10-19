// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import SidayKit

@Test func aCompanionFolderIsPackedAndUnpackedWithItsNames() {
    let files: [(name: String, bytes: [UInt8])] = [("Keyboard .instr", [1, 2, 3]), ("SNARE2_R8.ss", Array(repeating: 7, count: 300)), ("empty.instr", [])]
    let packed = CompanionFolder.pack(files)
    #expect(packed.count == files.reduce(0) { $0 + 8 + $1.name.utf8.count + $1.bytes.count })
    let unpacked = CompanionFolder.unpack(packed)
    #expect(unpacked.map(\.name) == files.map(\.name))
    #expect(unpacked.map(\.bytes) == files.map(\.bytes))
}

@Test func aCompanionFolderCutShortGivesTheFilesThatAreWhole() {
    let packed = CompanionFolder.pack([("a.instr", [1, 2]), ("b.ss", [3, 4, 5, 6])])
    for cut in 0 ..< packed.count {
        let unpacked = CompanionFolder.unpack(Array(packed.prefix(cut)))
        #expect(unpacked.count == (cut < 8 + 7 + 2 ? 0 : 1))
    }
    // Lengths that say more than there is.
    #expect(CompanionFolder.unpack([0xFF, 0xFF, 0xFF, 0xFF, 1, 2]).isEmpty)
    #expect(CompanionFolder.unpack([0, 0, 0, 1, 0x41, 0x7F, 0xFF, 0xFF, 0xFF]).isEmpty)
}

@Test func theFilesOfAFolderBesideATuneAreFoundInAnyCase() {
    let finder = FileFinder([
        "Games/Desert/generic0.tiny",
        "Games/Desert/Instruments/IT01.instr",
        "Games/Desert/Instruments/IT01.ss",
        "Games/Desert/Instruments/Old/IT02.instr",
        "Games/Desert/Demo/instruments/cello.instr",
        "Games/Other/Instruments/x.instr",
    ])
    #expect(finder.places(inFolder: "instruments", beside: "Games/Desert/generic0.tiny") == [1, 2])
    #expect(finder.places(inFolder: "Instruments", beside: "Games/Desert/Demo/ELMER.smus") == [4])
    #expect(finder.places(inFolder: "Instruments", beside: "Games/Elsewhere/a.smus").isEmpty)
    let companion = Companion(part: .instruments, names: ["Instruments"], kind: nil, required: true, folder: true)
    #expect(Companions.findFolder(companion, for: "Games/Other/song.snx", among: finder) == [5])
    guard case let .missingCompanion(why) = Companions.missing(companion) else { Issue.record(); return }
    #expect(why == "its instruments are kept in a folder of their own beside it, Instruments, which was not found")
}
