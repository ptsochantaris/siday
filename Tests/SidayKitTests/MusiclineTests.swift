// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
@testable import SidayKit
import Testing

// Fast checks of the Musicline Editor's player, on tiny modules made here. The thorough check is made
// outside the package: what it tells Paula, tick by tick, against what the editor's own DeliTracker player
// tells her in UADE, for both tunes of UnExoticA's Xenex-Remix.ml (mended, for UADE, as siday mends it).

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

private func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + long(body.count) + body }

private func text(_ string: String, _ size: Int) -> [UInt8] {
    Array(string.utf8.prefix(size)) + [UInt8](repeating: 0, count: max(0, size - string.utf8.count))
}

/// A tune: its title, tempo, speed and whether it has eight voices, and each voice's list of words.
private func tune(_ title: String, lists: [[Int]], tempo: Int = 125, speed: Int = 6, eight: Bool = false) -> [UInt8] {
    var body = text(title, 32) + word(tempo) + [UInt8(speed), 0] + word(64) + [eight ? 1 : 0, UInt8(lists.count)]
    for list in lists { body += long(2 * list.count) }
    for list in lists { body += list.flatMap(word) }
    return chunk("TUNE", body)
}

/// A part, its rows packed: each row a note and an instrument (its effects nought).
private func part(_ number: Int, rows: [(note: Int, instrument: Int)]) -> [UInt8] {
    var body = word(number)
    for row in rows {
        if row.note == 0, row.instrument == 0 {
            body.append(0)
        } else {
            body += [1, UInt8(row.note), UInt8(row.instrument)]
        }
    }
    body.append(0xFF)
    return chunk("PART", body)
}

/// An instrument of a sample, its volume 64 and nothing else.
private func instrument(sample: Int, length: Int) -> [UInt8] {
    var body = [UInt8](repeating: 0, count: 206)
    body[32] = UInt8(sample)
    body.replaceSubrange(38 ..< 40, with: word(length / 2))
    body.replaceSubrange(58 ..< 60, with: word(64))
    return chunk("INST", body)
}

/// A sample: its sound as it is, or packed by its runs (`packed`, with its command byte).
private func sample(_ sound: [UInt8], packed: [UInt8]? = nil, command: UInt8 = 0x85) -> [UInt8] {
    let data = packed ?? sound
    var header = text("SOUND", 32) + [0, 0] + long(0) + word(sound.count / 2) + long(0) + word(0) + word(0) + word(0)
    header = Array(header.prefix(50))
    let body = header + data
    return Array("SMPL".utf8) + long(body.count) + long(sound.count) + [command, 0] + body
}

private func module(_ chunks: [[UInt8]]) -> [UInt8] {
    Array("MLED".utf8) + chunk("MODL", [0, 0, 0, 0]) + chunk("VERS", word(0x0114) + Array("1.14".utf8)) + chunks.flatMap { $0 }
}

private let sound: [UInt8] = (0 ..< 16).map { UInt8(truncatingIfNeeded: $0 * 9 + 1) }

/// A module of one tune whose first voice plays a note and then its part's end, and whose list ends.
private func oneNote(note: Int = 25) -> [UInt8] {
    module([tune("ONE", lists: [[0x0010, 0x0060], [], [], []]), tune("TWO", lists: [[0x0010, 0x0060]]),
            part(0, rows: [(note, 1), (61, 0)]), instrument(sample: 1, length: sound.count), sample(sound)])
}

/// Runs `ticks` ticks, keeping what the player wrote to Paula in each.
private func play(_ player: inout MusiclinePlayer, ticks: Int) -> [[(register: UInt16, value: UInt16)]] {
    var told: [[(register: UInt16, value: UInt16)]] = []
    var none = TFMXSilentOutput()
    player.writes = []
    for _ in 0 ..< ticks {
        _ = player.run(&none)
        told.append(player.writes ?? [])
    }
    return told
}

private func written(_ writes: [(register: UInt16, value: UInt16)], _ register: UInt16) -> [UInt16] {
    writes.filter { $0.register == register }.map(\.value)
}

@Test func musiclineDetection() throws {
    let file = oneNote()
    #expect(MusiclinePlayer.isOne(file) && !MusiclinePlayer.isOne(Array("MLEDMODX".utf8) + file.dropFirst(8)))
    #expect(TuneFormat(fileExtension: "ML") == .ml)
    let player = try MusiclinePlayer(file)
    #expect(player.songCount == 2 && player.version == "1.14" && player.shortfalls.isEmpty)
    #expect(player.tuneInfo.format == "Musicline Editor" && player.tuneInfo.title == "ONE")
    let renderer = try TuneLoader.load(file, format: .ml)
    #expect(renderer.subsongCount == 2)
    // No tunes: refused.
    #expect(throws: TuneError.self) { _ = try MusiclinePlayer(module([part(0, rows: [(25, 1)])])) }
}

/// The first tick after the start tells the voices' volumes, and the effects of the first row, which the
/// start read: the voice with a note turned off, and after the CIA's timer B told its sample, length,
/// volume and period and turned on, and after another wait its loop: a word of silence, for a sample
/// that does not go round. The tune's part ends at its second row, six ticks on, and its list then: the
/// tune has stopped there.
@Test func musiclineNoteReachesPaula() throws {
    var player = try MusiclinePlayer(oneNote())
    let told = play(&player, ticks: 3)
    #expect(told[0].isEmpty)
    let first = told[1]
    #expect(written(first, 0xA8) == [0, 64] && written(first, 0xB8) == [0, 0] && written(first, 0xA4) == [8, 1])
    #expect(written(first, 0xA6) == [MusiclineTables.pitches[25 * 32]] && written(first, 0x96) == [0x0001, 0x8001])
    let sampleAt = player.samples[1]!.data
    #expect(written(first, 0xA2) == [UInt16(sampleAt & 0xFFFF), UInt16(MusiclinePlayer.zeroSample)])
    // Then only the period and volume, at every tick.
    #expect(written(told[2], 0xA6) == [MusiclineTables.pitches[25 * 32]] && written(told[2], 0xA4).isEmpty)
    #expect(player.lengthClocks == 7 * 70940)
    // The second tune: the same, with its one voice.
    try player.select(song: 1)
    #expect(player.lengthClocks == 7 * 70940)
}

/// A tune whose list jumps back for ever goes round; one of eight voices, which the player mixes itself,
/// is not played, and says so.
@Test func musiclineSongsGoRoundOrStop() throws {
    let file = module([tune("LOOP", lists: [[0x0010, 0x00A0]]), tune("EIGHT", lists: [[0x0010]], eight: true),
                       part(0, rows: [(25, 1), (61, 0)]), instrument(sample: 1, length: sound.count), sample(sound)])
    var player = try MusiclinePlayer(file)
    #expect(player.lengthClocks == 7 * 70940)
    _ = play(&player, ticks: 30)
    #expect(player.endings >= 3 && player.stops == 0)
    #expect(player.shortfalls.count == 1 && player.shortfalls[0].contains("eight voices"))
    try player.select(song: 1)
    #expect(player.lengthClocks == 0)
}

/// A packed sample unpacks as the player's `DeltaDePacker` has it: bytes as they are, and runs of a byte
/// and its deltas.
@Test func musiclineSamplesUnpack() throws {
    let packed: [UInt8] = [3, 0x85, 10, 0, 4, 0x1F, 0x2E, 7]
    let unpacked = MusiclinePlayer.Loaded.unpacked(packed, from: 0, count: packed.count, command: 0x85, size: 7)
    #expect(unpacked == [3, 10, 11, 10, 12, 10, 7])
    let file = module([tune("ONE", lists: [[0x0010]]), part(0, rows: [(25, 1)]), instrument(sample: 1, length: 8),
                       sample([3, 10, 11, 10, 12, 10, 7, 0], packed: packed + [0])])
    let player = try MusiclinePlayer(file)
    let at = player.samples[1]!.data
    #expect((0 ..< 8).map { player.memory[at + $0] } == [3, 10, 11, 10, 12, 10, 7, 0])
}

/// A file that has lost the nought after each CR (13) in it is mended: in a part, by a nought after each
/// of its CRs; in a packed sample, by those whose places its packing tells, and a nought at its end for
/// one whose place it does not. It plays as the file did before.
@Test func musiclineDamagedFilesAreMended() throws {
    // (A row of note 13 and no instrument: 13 and a nought, packed. A sound of a CR followed by something
    // else, a CR followed by a nought, and a run that begins with a CR and is four long.)
    let sound: [UInt8] = [13, 0x22, 13, 0, 0x30, 13, 14, 15, 16, 17]
    let packed: [UInt8] = [13, 0x22, 13, 0, 0x30, 0x85, 13, 0, 4, 0x11, 0x11]
    let whole = module([tune("ONE", lists: [[0x0010]]), part(0, rows: [(25, 1), (13, 0), (0, 0), (0, 0), (61, 0)]),
                        instrument(sample: 1, length: sound.count), sample(sound, packed: packed)])
    var damaged: [UInt8] = []
    for (k, byte) in whole.enumerated() where !(byte == 0 && k > 0 && whole[k - 1] == 13) { damaged.append(byte) }
    #expect(damaged.count == whole.count - 3)
    #expect(MusiclineRepair.repaired(whole) == nil)
    let (mended, notes) = try #require(MusiclineRepair.repaired(damaged))
    #expect(notes.count == 1 && notes[0].contains("the 2 whose places are certain") && notes[0].contains("the one in the sound of sample 1"))
    var a = try MusiclinePlayer(whole), b = try MusiclinePlayer(damaged)
    #expect(b.shortfalls == notes && mended.count == whole.count)
    let sampleA = a.samples[1]!.data, sampleB = b.samples[1]!.data
    // (The sound: its literal nought lost, the rest a byte earlier, and a nought at its end.)
    #expect((0 ..< 10).map { b.memory[sampleB + $0] } == [13, 0x22, 13, 0x30, 13, 14, 15, 16, 17, 0])
    #expect((0 ..< 10).map { a.memory[sampleA + $0] } == sound)
    let toldA = play(&a, ticks: 40), toldB = play(&b, ticks: 40)
    for (x, y) in zip(toldA, toldB) { #expect(x.map(\.register) == y.map(\.register) && x.map(\.value) == y.map(\.value)) }
    #expect(a.lengthClocks == b.lengthClocks)
    // The packing's own mending: a CR that began a run, its length's nought put back; a CR of the sound itself,
    // its nought at the end.
    let stream: [UInt8] = [13, 0x22, 13, 0x30, 0x85, 13, 4, 0x11, 0x11]
    let mendedSound = try #require(MusiclineRepair.mendedSound(stream, lost: 2, command: 0x85, size: 10))
    #expect(mendedSound.placed == 1 && mendedSound.stream == [13, 0x22, 13, 0x30, 0x85, 13, 0, 4, 0x11, 0x11, 0])
}
