// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the reading of Magnetic Fields Packer songs, and of the finding of the files tunes
// keep part of themselves in. The thorough check is made outside the package, against the format's
// replayer in Wanted Team's player for EaglePlayer, run by UADE: the first 40 seconds of each of the 37
// songs of UnExoticA's collection, by how loud each side is from moment to moment.

/// A note in ProTracker's four bytes: a period, a sample, a command and its value.
private func note(_ period: Int, _ sample: Int, _ command: Int, _ value: Int) -> [UInt8] {
    [UInt8(sample & 0xF0 | period >> 8), UInt8(period & 0xFF), UInt8((sample & 0x0F) << 4 | command), UInt8(value)]
}

/// One voice's tree, in which row r plays the fourth of `notes` that r gives when divided by 4.
private func tree(_ notes: [[UInt8]]) -> [UInt8] {
    // Four bytes for the four sixteen-row stretches, all leading to the four at 4; those all lead to
    // the four at 8; those lead to the notes, at 16, 20, 24 and 28, by half their places.
    [4, 4, 4, 4, 8, 8, 8, 8, 8, 10, 12, 14, 0, 0, 0, 0] + notes.joined()
}

/// A song of three places, the third playing what the first does, with its trees and one sample of
/// eight bytes.
private func song() -> (song: [UInt8], samples: [UInt8]) {
    var file: [UInt8] = []
    for sample in 0 ..< 31 {
        file += sample == 0 ? [0, 4, 0, 48, 0, 0, 0, 1] : [0, 0, 0, 0, 0, 0, 0, 1]
    }
    // Three places; the order the module had, which is not what is played.
    file += [3, 0x7F] + [7, 2, 7] + [UInt8](repeating: 0, count: 125)
    file += [0, 3, 0, 3]
    let first = tree([note(428, 1, 0x0C, 32), note(0, 0, 0, 0), note(214, 1, 0, 0), note(0, 0, 0x0F, 3)])
    let second = tree([note(856, 1, 0, 0), note(0, 0, 0, 0), note(0, 0, 0, 0), note(0, 0, 0, 0)])
    let silence = tree([[UInt8]](repeating: [0, 0, 0, 0], count: 4))
    // The table: where each place's four trees begin, after the table.
    let at = (first: 0, second: first.count, silence: first.count + second.count)
    for place in [[at.first, at.silence, at.silence, at.silence], [at.second, at.silence, at.first, at.silence],
                  [at.first, at.silence, at.silence, at.silence]] {
        for offset in place { file += [UInt8(offset >> 8), UInt8(offset & 0xFF)] }
    }
    file += first + second + silence
    return (file, [0, 20, 40, 60, 80, 100, 120, 127])
}

/// The four bytes of a row's note on a voice, in a ProTracker module's pattern.
private func cell(_ module: [UInt8], pattern: Int, row: Int, voice: Int) -> [UInt8] {
    let at = 1084 + pattern * 1024 + (row * 4 + voice) * 4
    return Array(module[at ..< at + 4])
}

@Test func magneticFieldsPackerSongIsReadIntoAModule() throws {
    let (file, samples) = song()
    #expect(MagneticFieldsPacker.isOne(file))
    let module = try MagneticFieldsPacker.module(file, samples: samples)
    // The sample's particulars, with a name of nothing; the song, by its places, the third sharing the
    // first's pattern.
    #expect(Array(module[20 + 22 ..< 20 + 30]) == [0, 4, 0, 48, 0, 0, 0, 1])
    #expect(module[950] == 3 && module[951] == 0x7F)
    #expect(Array(module[952 ..< 956]) == [0, 1, 0, 0])
    #expect(Array(module[1080 ..< 1084]) == Array("M.K.".utf8))
    #expect(module.count == 1084 + 2 * 1024 + 8)
    #expect(Array(module.suffix(8)) == samples)
    // Each row of a voice plays the note its tree leads it to.
    for row in [0, 5, 37, 62] {
        let expected = [note(428, 1, 0x0C, 32), note(0, 0, 0, 0), note(214, 1, 0, 0), note(0, 0, 0x0F, 3)][row % 4]
        #expect(cell(module, pattern: 0, row: row, voice: 0) == expected)
        #expect(cell(module, pattern: 1, row: row, voice: 2) == expected)
        #expect(cell(module, pattern: 0, row: row, voice: 1) == [0, 0, 0, 0])
    }
    #expect(cell(module, pattern: 1, row: 4, voice: 0) == note(856, 1, 0, 0))

    // It plays as a module, with the samples brought to it, and not without them.
    let renderer = try TuneLoader.load(file, format: .mfp, companion: samples)
    #expect(renderer.info.format == "MOD" && renderer.info.detail == "packed by the Magnetic Fields Packer")
    #expect(throws: TuneError.self) { try TuneLoader.load(file, format: .mfp) }
    do {
        _ = try TuneLoader.load(file, format: .mfp)
    } catch let error as TuneError {
        guard case .missingCompanion = error else { Issue.record("\(error)"); return }
    }
}

@Test func magneticFieldsPackerSongCutShortOrNonsenseDoesNotTrap() throws {
    let (file, samples) = song()
    for length in 0 ... file.count {
        _ = try? MagneticFieldsPacker.module(Array(file.prefix(length)), samples: samples)
    }
    var seed: UInt64 = 3
    for _ in 0 ..< 300 {
        var changed = file
        for _ in 0 ..< 4 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            changed[Int(seed >> 33) % changed.count] = UInt8(truncatingIfNeeded: seed >> 17)
        }
        _ = try? MagneticFieldsPacker.module(changed, samples: samples)
    }
}

@Test func companionsAreFoundByTheNamesTheCollectionsUse() {
    #expect(Companions.ending(for: .mfp) == "smp" && Companions.ending(for: .mod) == nil)
    #expect(Companions.names(for: .mod, fileName: "a.mod").isEmpty)
    #expect(Companions.names(for: .mfp, fileName: "title.mfp") == ["title.smp"])
    #expect(Companions.names(for: .mfp, fileName: "KidChaos Level 1-3.mfp") == ["KidChaos Level 1-3.smp", "KidChaos Level 1_set.smp"])
    // Its own first, then the one it shares, whatever capitals either has.
    let beside = ["KidChaos Level 1-3.mfp", "KIDCHAOS LEVEL 1_SET.SMP", "KidChaos Level 2_set.smp", "notes.txt"]
    #expect(Companions.pick(for: .mfp, fileName: "KidChaos Level 1-3.mfp", among: beside) == "KIDCHAOS LEVEL 1_SET.SMP")
    #expect(Companions.pick(for: .mfp, fileName: "KidChaos-Menu.mfp", among: beside + ["KidChaos_set.smp"]) == "KidChaos_set.smp")
    // Failing those, the only file of its kind; and nothing where there are several.
    #expect(Companions.pick(for: .mfp, fileName: "ingame.mfp", among: ["ingame.mfp", "samples.smp"]) == "samples.smp")
    #expect(Companions.pick(for: .mfp, fileName: "ingame.mfp", among: beside) == nil)
    #expect(Companions.pick(for: .mod, fileName: "a.mod", among: beside) == nil)
}
