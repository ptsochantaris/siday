// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Jason Page's player, on tiny scores made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what Wanted Team's player of his music tells her in
// UADE, for every song of UnExoticA's files.

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// The commands of an instrument that plays sample 0 (64 bytes) at full volume, its DMA on, for three
/// ticks, and ends.
private let plain = [2, 0, 3, 64, 15, 0xFC00, 16, 5, 3, 0]

/// Two samples: 64 bytes, and 32.
private let twoSamples = (0 ..< 96).map { UInt8(truncatingIfNeeded: $0 * 7 + 1) }

/// A score of the second form: one song, its first voice playing pattern 0 (`pattern`, bytes, which
/// should begin with instrument 1 and end with $FF) and the others pattern 1 (a rest), each from a list of
/// that pattern alone and back to its start; the song's speed `speed`; instrument 1 `commands` (each a
/// command's number and its words, as the first form's are given here too), of priority 5; and two
/// samples, of 64 and 32 bytes.
private func second(_ pattern: [UInt8] = [0x81, 24, 0xF9, 0xFF], commands: [Int] = plain, speed: Int = 2) -> [UInt8] {
    var score = [UInt8](repeating: 0, count: 0xAC)
    func put(_ at: Int, _ bytes: [UInt8]) { for (i, b) in bytes.enumerated() { score[at + i] = b } }
    // The offsets: samples, instruments' offsets, their base, speeds, priorities, the voices' songs, four
    // unused, the voices' lists' bases, four unused, the patterns' offsets, their base; and the length.
    let offsets = [0xA0, 0x32, 0x70, 0x36, 0x38, 0x4C, 0x44, 0x46, 0x48, 0x50, 0x50, 0x50, 0x50,
                   0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x60, 0x64, 0xAC]
    put(0, word(2) + offsets.flatMap(word))
    put(0x32, word(0) + word(0x10)) // instrument 0 at the base, 1 after it
    put(0x36, word(speed))
    put(0x38, word(0) + word(5))
    put(0x4C, word(0)) // the first voice's list, from the base; the others'
    put(0x44, word(4))
    put(0x46, word(8))
    put(0x48, word(12))
    put(0x50, word(0x0000) + word(0xFE00))
    for v in 1 ..< 4 { put(0x50 + 4 * v, word(0x0100) + word(0xFE00)) }
    put(0x60, word(2) + word(2 + pattern.count))
    put(0x64, [0xFF, 0xFF] + pattern + [0xF9, 0xFF])
    put(0x70, word(0))
    put(0x80, commands.flatMap(word))
    put(0xA0, long(64) + long(32) + long(0)) // (and the long of nought that ends the table, as in every file)
    return score
}

/// The same, as a score of the first form, of $D00 bytes; its commands' numbers made four times
/// themselves, as the first form has them; and a second song, empty, which is not counted.
private func first(_ pattern: [UInt8] = [0x81, 24, 0xF9, 0xFF], commands: [Int] = plain, speed: Int = 2) -> [UInt8] {
    var score = [UInt8](repeating: 0, count: 0xD00)
    func put(_ at: Int, _ bytes: [UInt8]) { for (i, b) in bytes.enumerated() { score[at + i] = b } }
    // (The samples' places: the last, of 128 bytes as the player takes it, from the second on.)
    put(0, long(0))
    for i in 1 ..< 32 { put(4 * i, long(64)) }
    put(0x84, long(0xCBE) + long(0xCC0))
    put(0x480, word(speed))
    put(0x4C0, word(0) + word(5))
    put(0x6BE, long(0xCE0) + long(0xCF8))
    for v in 1 ..< 4 { put(0x6BE + 0x80 * v, long(0xCE0 + 4 * v)) }
    put(0x8BE, long(0xCF0) + long(0xCF0 + pattern.count))
    put(0xCB6, long(0x308BE) + long(0x309BE))
    put(0xCBE, word(0))
    // (Each command's number times four; its words after it, as many as the second form's has.)
    let words = [2: 1, 3: 1, 4: 2, 5: 1, 6: 1, 8: 2, 9: 1, 10: 2, 11: 1, 12: 1, 13: 1, 14: 1, 15: 1, 19: 4, 20: 1, 21: 1, 22: 1, 23: 1]
    var made: [Int] = []
    var i = 0
    while i < commands.count {
        made.append(commands[i] * 4)
        let n = words[commands[i]] ?? 0
        made += commands[i + 1 ..< i + 1 + n]
        i += 1 + n
    }
    put(0xCC0, made.flatMap(word))
    put(0xCE0, word(0x0000) + word(0xFE00))
    for v in 1 ..< 4 { put(0xCE0 + 4 * v, word(0x0100) + word(0xFE00)) }
    put(0xCF0, pattern + [0xF9, 0xFF])
    put(0xCF8, word(0xFF00))
    return score
}

/// Runs `ticks` ticks, keeping what the player wrote to Paula in each.
private func play(_ player: inout JasonPagePlayer, ticks: Int) -> [[(register: UInt16, value: UInt16)]] {
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

@Test func jasonPageDetection() throws {
    let made = second(), older = first()
    #expect(JasonPagePlayer.kind(of: made) == .second && JasonPagePlayer.kind(of: older) == .first)
    // A word of the 23 that is odd, or no less than the length; the first instrument's offset not nought.
    var odd = made
    odd[0x15] = 0x51
    #expect(!JasonPagePlayer.isOne(odd))
    var long = made
    long[0x14] = 0x01
    #expect(!JasonPagePlayer.isOne(long))
    var notNought = made
    notNought[0x33] = 2
    #expect(!JasonPagePlayer.isOne(notNought))
    // The first pattern's word without $F00: the third form, ViroCop's, which is refused.
    var third = made
    third[0x64] = 0xF0
    #expect(JasonPagePlayer.kind(of: third) == .third)
    #expect(throws: TuneError.self) { _ = try JasonPagePlayer(third, samples: twoSamples) }
    // The first form's marks.
    var unmarked = older
    unmarked[0xCB9] = 0xBF
    #expect(!JasonPagePlayer.isOne(unmarked) && !JasonPagePlayer.isOne(Array(older.prefix(0xCBC))))
    #expect(throws: TuneError.self) { _ = try JasonPagePlayer(unmarked, samples: twoSamples) }

    for score in [made, older] {
        let player = try JasonPagePlayer(score, samples: twoSamples)
        #expect(player.songCount == 1 && player.sampleCount == 2)
        #expect(player.tuneInfo.format == "Jason Page" && player.tuneInfo.author == "Jason Page")
    }
}

/// At the song's first tick, a voice's note asks for its instrument, which is begun: the voice silenced
/// (its DMA off, its volume nought, a word of silence at its period), its sample and length taken, its DMA
/// on; and at the tick's end Paula told its volume, the sample, its length in words and the note's
/// period. A voice with nothing to play is told the silence.
@Test func jasonPageNoteReachesPaula() throws {
    for score in [second(), first()] {
        var player = try JasonPagePlayer(score, samples: twoSamples)
        let isFirst = player.kind == .first
        let samples = Int(player.samplesAt), empty = Int(JasonPagePlayer.emptyAt)
        let told = play(&player, ticks: 4)
        let period = JasonPagePlayer.periods[24]
        #expect(written(told[0], 0x96) == [1, isFirst ? 0x8001 : 0x8201])
        #expect(written(told[0], 0xA8) == (isFirst ? [63] : [0, 63]))
        #expect(written(told[0], 0xA4) == [1, 32])
        #expect(written(told[0], 0xA0) == [UInt16(empty >> 16), UInt16(samples >> 16)])
        #expect(written(told[0], 0xA2) == [UInt16(empty & 0xFFFF), UInt16(samples & 0xFFFF)])
        #expect(written(told[0], 0xA6) == (isFirst ? [period, period] : [period, period]))
        // The other voices: their volume (the second form's idle commands set it to nought; the first
        // form's leave it as the player's voices begin, $900 and $A00 for the second and third: 2), a word
        // of the silence.
        #expect(written(told[0], 0xB8) == [isFirst ? 2 : 0] && written(told[0], 0xB4) == [1])
        #expect(written(told[0], 0xB2) == [UInt16(empty & 0xFFFF)])
        // The note goes on for its three ticks of waiting, and then its instrument's end silences it.
        #expect(written(told[1], 0x96).isEmpty && written(told[1], 0xA8) == [63] && written(told[2], 0xA8) == [63])
        // (The first form's end leaves its length as it was, and Paula is told its sample after the silence,
        // with its DMA off.)
        #expect(written(told[3], 0x96) == [1])
        #expect(written(told[3], 0xA2) == (isFirst ? [UInt16(empty & 0xFFFF), UInt16(samples & 0xFFFF)] : [UInt16(empty & 0xFFFF), UInt16(empty & 0xFFFF)]))
    }
}

/// The song's steps are every so many ticks, its speed and one; at a pattern's end a voice goes on in its
/// list, and at the list's end back; once every voice has, the song has come to its end.
@Test func jasonPageSongEnds() throws {
    for score in [second(), first()] {
        var player = try JasonPagePlayer(score, samples: twoSamples)
        // The note, the rest, and the pattern's end on the third step, at the seventh tick.
        #expect(player.lengthClocks == UInt64(6 * JasonPagePlayer.tickClocks))
        var none = TFMXSilentOutput()
        for _ in 0 ..< 6 { _ = player.run(&none) }
        #expect(player.endings == 0)
        _ = player.run(&none)
        #expect(player.endings == 1 && player.stops == 0)
        // A slower song is longer.
        let slower = try JasonPagePlayer(player.kind == .first ? first(speed: 5) : second(speed: 5), samples: twoSamples)
        #expect(slower.lengthClocks == UInt64(12 * JasonPagePlayer.tickClocks))
    }
}

/// An envelope: up by its step for its count of ticks and one more, then held.
@Test func jasonPageEnvelope() throws {
    let commands = [2, 0, 3, 64, 19, 0x2003, 0x00FF, 0xFFFF, 0xFFFF, 16, 5, 10, 0]
    for score in [second(commands: commands), first(commands: commands)] {
        var player = try JasonPagePlayer(score, samples: twoSamples)
        let told = play(&player, ticks: 6)
        #expect(told.map { written($0, 0xA8).last ?? 0 } == [8, 16, 24, 32, 32, 32])
    }
}

/// A list's end of the song stops it: Wanted Team's player starts it again, which is not heard.
@Test func jasonPageSongStops() throws {
    var score = second()
    score[0x52] = 0xFF
    var player = try JasonPagePlayer(score, samples: twoSamples)
    #expect(player.lengthClocks == UInt64(6 * JasonPagePlayer.tickClocks))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 7 { _ = player.run(&none) }
    #expect(player.stops == 1 && player.endings == 1 && player.failure == nil)
}

/// A command the player has no routine for would take it off into its own code: the song is stopped.
@Test func jasonPageStopsAtACommandItHasNot() throws {
    for score in [second(commands: [24, 0]), first(commands: [24, 0])] {
        var player = try JasonPagePlayer(score, samples: twoSamples)
        var none = TFMXSilentOutput()
        _ = player.run(&none)
        #expect(player.stops == 1 && player.failure != nil)
    }
    // (And the first form's word that is not four times a number.)
    var score = first()
    score[0xCC1] = 0x09
    var player = try JasonPagePlayer(score, samples: twoSamples)
    var none = TFMXSilentOutput()
    _ = player.run(&none)
    #expect(player.stops == 1 && player.failure != nil)
}

/// A sample moved a step towards another, byte by byte, and one copied onto another, each change kept in
/// the memory Paula plays from; and put back as it was when the song starts again.
@Test func jasonPageChangesItsSamples() throws {
    let toward = [2, 1, 23, 0, 5, 1, 23, 0, 5, 1, 22, 0x0001, 5, 1, 0]
    var player = try JasonPagePlayer(second(commands: toward), samples: twoSamples)
    let at = Int(player.samplesAt) + 64
    var none = TFMXSilentOutput()
    _ = player.run(&none)
    let once = (0 ..< 32).map { player.memory[at + $0] }
    let wanted = (0 ..< 32).map { i -> UInt8 in
        let have = twoSamples[64 + i], want = twoSamples[i]
        return have > want ? have - 1 : have < want ? have + 1 : have
    }
    #expect(once == wanted)
    _ = player.run(&none)
    _ = player.run(&none)
    #expect((0 ..< 64).map { player.memory[at + $0] } == Array(twoSamples[0 ..< 64]))
    try player.select(song: 0)
    #expect((0 ..< 32).map { player.memory[at + $0] } == Array(twoSamples[64 ..< 96]))
}
