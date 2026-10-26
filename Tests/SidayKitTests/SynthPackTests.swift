// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Karsten Obarski's Synth Pack, on tiny songs made here. The thorough check is made outside the
// package: what the player tells Paula, tick by tick, against what Wanted Team's player tells her in UADE, for
// every song of UnExoticA's files.

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

private let heading = Array("OBISYNTHPACK".utf8)

/// A song's positions (each its rows, its line of tracks, its times or command, and its voices) and its lines
/// of tracks (each four tracks, a pattern and how far its instruments and notes are moved, and the speed in the
/// first's last byte), as both forms have them, in the song's first 1,292 bytes.
private func start(_ positions: [[UInt8]], _ lines: [[UInt8]]) -> [UInt8] {
    var song = heading + [UInt8](repeating: 0, count: 1280)
    for (i, p) in positions.enumerated() { for k in 0 ..< 4 { song[12 + 4 * i + k] = p[k] } }
    for (i, l) in lines.enumerated() { for (k, b) in l.enumerated() { song[268 + 16 * i + k] = b } }
    return song
}

/// One position of 4 rows, its line the first, of voices `voices`, then its command `command`; the first line's
/// first track pattern 0, the rest pattern 1, at speed `speed`.
private func onePosition(_ command: UInt8 = 0xFF, voices: UInt8 = 0x0F, speed: UInt8 = 6) -> [UInt8] {
    start([[4, 0, command, voices]], [[0, 0, 0, speed, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]])
}

/// A song of Centerbase's form: `onePosition`, and its patterns, packed (pattern 0 a note of `note` on row
/// nought, of volume 64, instrument 1, its arpeggio's kind and its steps; pattern 1 nothing).
private func centerbase(_ positions: [UInt8] = onePosition(), note: UInt8 = 24, arpeggio: (UInt8, UInt8) = (0, 0)) -> [UInt8] {
    var song = positions
    song += word(0x100) + word(0x10C) + [UInt8](repeating: 0, count: 252)
    song += [note, 64, 1, arpeggio.0, 0, arpeggio.1] + long(-1)
    song += long(-1) + long(-1)
    return song
}

/// Centerbase's samples: their heading, the table of 64 longs of offsets, all to its one instrument: a
/// sample of `length` bytes (no loop; more than $80, or the routine takes it as a waveform), at its note, its envelope at once to 64 and held, its tremolo and
/// vibrato off (shift 8), and for a waveform (of $80 bytes or fewer), a sweep at `sweep`, after its 512 bytes.
private func centerbaseSamples(length: Int = 256, sweep: UInt8 = 0) -> [UInt8] {
    var samples = heading
    for _ in 0 ..< 64 { samples += long(268) }
    var instrument = [UInt8](repeating: 0, count: 48)
    instrument[2] = UInt8(length >> 8)
    instrument[3] = UInt8(length & 0xFF)
    instrument[16] = 64 // attack level, and speeds of nought
    instrument[19] = 64 // sustain level
    instrument[23] = 8 // tremolo off
    instrument[28] = 8 // vibrato off
    instrument[32] = sweep // waveform's speed
    instrument[33] = sweep == 0 ? 8 : 0 // its shift
    samples += instrument + (0 ..< max(length, 512)).map { UInt8(truncatingIfNeeded: $0 * 3 + 1) }
    return samples
}

/// A song of Dyter-07's form: `onePosition` (but its first track pattern 1, as the check wants pattern 0's first
/// row empty), and pattern 1, of 64 rows, a note on row nought.
private func dyter(_ positions: [UInt8] = start([[4, 0, 0xFF, 0x0F]], [[1, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]),
                   note: UInt8 = 24) -> [UInt8]
{
    var song = positions
    song += [UInt8](repeating: 0, count: 0x180)
    song += [note, 64, 1, 0, 0, 0] + [UInt8](repeating: 0, count: 0x180 - 6)
    return song
}

/// Dyter-07's samples: 64 words of offsets, all to its one instrument, as Centerbase's but with a heading of 34.
private func dyterSamples(length: Int = 64) -> [UInt8] {
    var samples: [UInt8] = []
    for _ in 0 ..< 64 { samples += word(128) }
    var instrument = [UInt8](repeating: 0, count: 34)
    instrument[2] = UInt8(length >> 8)
    instrument[3] = UInt8(length & 0xFF)
    instrument[18] = 64
    instrument[21] = 64
    instrument[25] = 15 // tremolo shifted to nothing
    instrument[30] = 15
    samples += instrument + (0 ..< max(length, 512)).map { UInt8(truncatingIfNeeded: $0 * 3 + 1) }
    return samples
}

/// Runs `ticks` ticks, keeping what the player wrote to Paula in each.
private func play(_ player: inout SynthPackPlayer, ticks: Int) -> [[(register: UInt16, value: UInt16)]] {
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

private func location(_ writes: [(register: UInt16, value: UInt16)], voice: Int = 0) -> UInt32? {
    let base = UInt16(0xA0 + 16 * voice)
    guard let high = written(writes, base).last, let low = written(writes, base + 2).last else { return nil }
    return UInt32(high) << 16 | UInt32(low)
}

@Test func synthPackDetection() throws {
    #expect(SynthPackPlayer.form(of: centerbase()) == .centerbase)
    #expect(SynthPackPlayer.form(of: dyter()) == .dyter)
    var other = centerbase()
    other[1293] = 1
    #expect(!SynthPackPlayer.isOne(other))
    var named = dyter()
    named[0] = UInt8(ascii: "X")
    #expect(!SynthPackPlayer.isOne(named))
    #expect(!SynthPackPlayer.isOne(Array(dyter().prefix(1295))))
    // Without its samples, or Centerbase's form with samples not headed as its own are.
    #expect(throws: TuneError.self) { _ = try SynthPackPlayer(centerbase(), samples: []) }
    #expect(throws: TuneError.self) { _ = try SynthPackPlayer(centerbase(), samples: dyterSamples()) }
    let player = try SynthPackPlayer(dyter(), samples: dyterSamples())
    #expect(player.tuneInfo.format == "Synth Pack" && player.tuneInfo.author == "Karsten Obarski")
}

@Test func synthPackSongCounts() throws {
    // Centerbase's marks (positions of no rows ending $00F0) and its songs' ends ($FE and $FC), the more of
    // them; and Dyter-07's main_fx, seven.
    let marked = start([[0, 0, 0, 0xF0], [4, 0, 0xFF, 0x0F], [0, 0, 0, 0xF0], [4, 0, 0xFF, 0x0F]], [])
    #expect(SynthPackPlayer.countSongs(marked, form: .centerbase) == 2)
    let ends = start([[4, 0, 0xFD, 0x0F], [4, 0, 0xFC, 0x0F], [4, 0, 0xFE, 0x0F]], [])
    #expect(SynthPackPlayer.countSongs(ends, form: .centerbase) == 2)
    #expect(SynthPackPlayer.countSongs(start([[0x20, 0, 0xFE, 0x0F]], []), form: .dyter) == 7)
    #expect(SynthPackPlayer.countSongs(start([], []), form: .dyter) == 1)
    // The second song of Centerbase's form starts at its second mark.
    var song = centerbase(start([[0, 0, 0, 0xF0], [4, 0, 0xFF, 0x0F], [0, 0, 0, 0xF0], [4, 1, 0xFF, 0x0F]],
                                [[1, 0, 0, 6, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0], [0, 0, 0, 6, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]]))
    var player = try SynthPackPlayer(song, samples: centerbaseSamples())
    #expect(player.songCount == 2)
    let first = play(&player, ticks: 20)
    #expect(first.allSatisfy { location($0) == nil })
    try player.select(song: 1)
    let second = play(&player, ticks: 20)
    #expect(second.contains { location($0) != nil })
    song[12 + 3] = 0
    #expect(try SynthPackPlayer(song, samples: centerbaseSamples()).songCount == 1)
}

@Test func synthPackCenterbaseNote() throws {
    var player = try SynthPackPlayer(centerbase(), samples: centerbaseSamples())
    let told = play(&player, ticks: 8)
    // The fifth tick reads the first row, and the sixth tells Paula the note: its sample after its heading of
    // 48, its length in words, its volume and its period, and its DMA turned off at the tick's end; the
    // seventh turns it on and tells its length of one word, to go round on.
    let sample = player.samplesAt + 268 + 48
    #expect(told[0 ..< 5].allSatisfy { location($0) == nil })
    #expect(location(told[5]) == sample)
    #expect(written(told[5], 0xA4) == [128])
    #expect(written(told[5], 0xA8) == [64])
    #expect(written(told[5], 0xA6) == [0x358])
    #expect(written(told[5], 0x96).last == 1)
    #expect(written(told[6], 0x96).first == 0x8001)
    #expect(written(told[6], 0xA4) == [1])
    // The song's end ($FF) at its position's fourth row, eighteen ticks after its first, which is the fifth
    // tick (its length counts from the first tick to the tick of its end); the other voices said nothing.
    #expect(player.endings == 0 && player.stops == 0)
    #expect(player.lengthClocks == UInt64(22 * SynthPackPlayer.tickClocks))
    #expect(told.allSatisfy { location($0, voice: 1) == nil })
}

@Test func synthPackCenterbaseArpeggioAndWaveform() throws {
    // An arpeggio of the first kind (the note, and the note and the top four bits) of twelve: the period an
    // octave up at every third tick, the note's again at the list's end and then at its start.
    var player = try SynthPackPlayer(centerbase(arpeggio: (0, 0xC0)), samples: centerbaseSamples())
    let told = play(&player, ticks: 12).map { written($0, 0xA6).first ?? 0 }
    #expect(Array(told[5 ..< 12]) == [0x358, 0x358, 0x1AC, 0x358, 0x358, 0x1AC, 0x358])
    // A waveform of $80 bytes swept by the saw, its place told at every tick in the bank of 512 bytes.
    var swept = try SynthPackPlayer(centerbase(), samples: centerbaseSamples(length: 0x80, sweep: 4))
    let places = play(&swept, ticks: 12).compactMap { location($0) }
    #expect(places.count >= 6)
    let bank = swept.samplesAt + 268 + 48
    #expect(places.allSatisfy { $0 >= bank && $0 < bank + 512 })
    #expect(Set(places).count > 2)
}

@Test func synthPackCenterbaseCommands() throws {
    // A stop ($FE): the song's end, and its stop.
    var stopping = try SynthPackPlayer(centerbase(onePosition(0xFE)), samples: centerbaseSamples())
    #expect(stopping.stops == 0)
    _ = play(&stopping, ticks: 30)
    #expect(stopping.stops == 1 && stopping.endings == 1)
    // A position not of the voices: let go, nothing told.
    var silent = try SynthPackPlayer(centerbase(onePosition(voices: 0)), samples: centerbaseSamples())
    #expect(play(&silent, ticks: 10).allSatisfy { location($0) == nil })
    // Played twice, then marked to go back to and gone back to: the end at the going back.
    let looped = centerbase(start([[4, 0, 1, 0x0F], [4, 0, 0xFD, 0x0F], [4, 0, 0xFC, 0x0F]],
                                  [[0, 0, 0, 6, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]]))
    let player = try SynthPackPlayer(looped, samples: centerbaseSamples())
    #expect(player.lengthClocks == UInt64(4 + 15 * 6) * UInt64(SynthPackPlayer.tickClocks))
}

@Test func synthPackDyterNote() throws {
    var player = try SynthPackPlayer(dyter(), samples: dyterSamples())
    let told = play(&player, ticks: 8)
    // Dyter-07's routine reads the row and tells Paula the note in the same tick, the fifth; its sample after its
    // heading of 34.
    #expect(location(told[3]) == nil)
    #expect(location(told[4]) == player.samplesAt + 128 + 34)
    #expect(written(told[4], 0xA4) == [32])
    #expect(written(told[4], 0xA8) == [64])
    #expect(written(told[4], 0xA6) == [0x358])
    #expect(written(told[4], 0x96).last == 1)
    #expect(written(told[5], 0x96).first == 0x8001)
    // Its start pointed each voice at the player's silence.
    #expect(written(player.startWrites, 0xB2).first == UInt16(SynthPackPlayer.emptyAt & 0xFFFF))
    // A row of thirteen ticks runs past the player's twelve steps of its arpeggios: stopped there.
    var slow = try SynthPackPlayer(dyter(start([[4, 0, 0xFF, 0x0F]], [[1, 0, 0, 13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]])),
                                   samples: dyterSamples())
    _ = play(&slow, ticks: 30)
    #expect(slow.failure != nil && slow.stops == 1)
}

@Test func synthPackTables() {
    // The player's own: its sines' first steps, its squares, and its saws' ends.
    #expect(Array(SynthPackPlayer.Tables.waves[3][0 ..< 9]) == [0, 6, 12, 18, 24, 31, 37, 43, 48])
    #expect(SynthPackPlayer.Tables.waves[3][64] == 0 && SynthPackPlayer.Tables.waves[3][65] == -7 && SynthPackPlayer.Tables.waves[3][32] == 127)
    #expect(Array(SynthPackPlayer.Tables.vibratos[3][0 ..< 9]) == [0, 24, 48, 71, 90, 106, 118, 125, 127])
    #expect(SynthPackPlayer.Tables.vibratos[3][24] == -128)
    #expect(SynthPackPlayer.Tables.waves[0].first == -127 && SynthPackPlayer.Tables.waves[0].last == 127)
    #expect(SynthPackPlayer.Tables.tremolos[2][16] == 240)
    #expect(SynthPackPlayer.hunk.count == SynthPackPlayer.hunkSize)
}
