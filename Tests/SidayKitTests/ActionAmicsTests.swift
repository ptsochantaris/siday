// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Action Amics' player, on a tiny file made here as the tool's are. The thorough check is made outside
// the package: what it tells Paula, tick by tick, against what the EaglePlayer tells her in UADE, for every song of
// UnExoticA's file.

/// What Paula is told, as a list (the periods and volumes left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

/// A file of one song of one place, at a speed of 2: voice 0's pattern plays note 13 of the one instrument with its
/// volume set to 16 (a quarter of 64), and 63 empty rows; the others' patterns are 64 empty rows. The instrument's
/// one sample is of eight words, its loop the last four, and has its first four words inverted a byte a tick, round
/// and round, if `inverted`.
private func file(inverted: Bool = false) -> (bytes: [UInt8], sampleAt: Int) {
    let sizes = [28, 4, 4, 4, 4, 32, 16, 16, 16, 32, 128, 128, 4, 64, 4]
    var bytes = [UInt8](repeating: 0, count: 2 + 4 * sizes.count)
    for (i, size) in sizes.enumerated() { bytes[2 + 4 * i + 3] = UInt8(size) }
    var parts = [62]
    for size in sizes { parts.append(parts.last! + size) }
    bytes += Array("ACTIONAMICS SOUND TOOL".utf8)
    bytes += [UInt8](repeating: 0, count: parts[15] - bytes.count)
    func put(_ at: Int, _ values: [UInt8]) { for (i, b) in values.enumerated() { bytes[at + i] = b } }
    // The song's tables: voice 0 plays pattern nought, the others pattern 1.
    put(parts[2], [0, 1, 1, 1])
    // The instrument (its sequence nought, its envelope all noughts), the sequence (sample nought).
    // The song: place nought only, at speed 2; the rest are the tool's empty ones.
    put(parts[11], [0, 0, 0, 2])
    for i in 1 ..< 32 { put(parts[11] + 4 * i, [0, 0, 0, 4]) }
    // The sample: eight words, its loop from its fifth word, of four; and its inverted stretch.
    put(parts[13] + 4, [0, 8, 0, 4, 0, 4])
    if inverted { put(parts[13] + 10, [0, 0, 0, 4, 0, 0, 0, 1, 0, 1]) }
    // The patterns.
    put(parts[14], [0, 0, 0, 5])
    bytes += [13, 1, 0x7C, 16, 0xC1, 0xC0]
    let sampleAt = bytes.count
    bytes += (0 ..< 16).map { UInt8($0 * 4) }
    let length = bytes.count
    put(parts[1], [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
    return (bytes, sampleAt)
}

@Test func actionAmicsDetection() throws {
    let (bytes, _) = file()
    #expect(ActionAmicsPlayer.isOne(bytes))
    var other = bytes
    other[62] = 0x61
    #expect(!ActionAmicsPlayer.isOne(other))
    #expect(throws: TuneError.self) { try ActionAmicsPlayer(other) }
    var player = try ActionAmicsPlayer(bytes)
    #expect(player.songCount == 1 && player.sampleCount == 1)
    #expect(throws: TuneError.self) { try player.select(song: 1) }
}

/// Before the first row's tick the voices are told nothing to play; on it, the note's voice is turned off, told its
/// sample and turned on with the rest, and after it is told the sample's loop.
@Test func actionAmicsNotesReachPaula() throws {
    let (bytes, sampleAt) = file()
    var player = try ActionAmicsPlayer(bytes)
    let silence = player.silenceAt
    let on = ["on 0", "on 1", "on 2", "on 3"]
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == (0 ..< 4).map { "buffer \($0) \(silence) 0" } + on)
    var second = Recorder()
    _ = player.run(&second)
    #expect(second.events == ["off 0", "buffer 0 \(sampleAt) 8"] + (1 ..< 4).map { "buffer \($0) \(silence) 0" } + on)
    #expect(player.volume(0) == 16 && player.period(0) == ActionAmicsPlayer.periodTable[13])
    var third = Recorder()
    _ = player.run(&third)
    #expect(third.events.first == "buffer 0 \(sampleAt + 8) 4")
}

/// A sample's stretch is inverted a byte a tick, and goes round at its end.
@Test func actionAmicsInvertedStretch() throws {
    let (bytes, sampleAt) = file(inverted: true)
    var player = try ActionAmicsPlayer(bytes)
    var none = TFMXSilentOutput()
    var first: [UInt8] = []
    for _ in 0 ..< 10 {
        _ = player.run(&none)
        first.append(player.memory[sampleAt])
    }
    // (Its first byte, nought, inverted on the first tick, and again on the ninth, as the stretch of eight bytes
    // goes round.)
    #expect(first == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00])
    #expect(player.memory[sampleAt + 1] == 4 && player.memory[sampleAt + 2] == ~UInt8(8) && player.memory[sampleAt + 7] == ~UInt8(28))
}

/// The song comes to its end with its last place's pattern, and is said to as it begins again: 64 rows of two ticks
/// after the first, here.
@Test func actionAmicsSongEnds() throws {
    var player = try ActionAmicsPlayer(file().bytes)
    #expect(player.lengthClocks == UInt64(129 * TFMXTiming.fiftyTimes))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 129 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1 && player.stops == 0)
}
