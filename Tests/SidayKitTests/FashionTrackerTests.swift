// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Fashion Tracker's player, on a tiny file made here as the games' are: the beginning of
// the replay code, the instructions the player finds its tables by, and the tables. The thorough check is
// made outside the package: what it tells Paula, tick by tick, against what Wanted Team's player tells her
// in UADE, for every one of UnExoticA's files.

/// What Paula is told, as a list (the moments in the tick left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func put(_ bytes: inout [UInt8], _ at: Int, _ values: [UInt8]) {
    for (i, value) in values.enumerated() { bytes[at + i] = value }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

/// The origin the game put the file at.
private let origin = 0x10000
/// Where the samples are: after the one pattern and the row after it.
private let samplesAt = 512 + 1024 + 16

/// A file of two samples (the first of sixteen words, going on to silence; the second of eight, going
/// round), two instruments (the first sample at volume 48, the second at 64), an order of one pattern, and
/// that pattern's rows given as (byte offset in the pattern, voice, period, instrument, command, parameter).
private func file(_ notes: [(at: Int, voice: Int, period: Int, instrument: Int, command: Int, parameter: Int)]) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: samplesAt + 48)
    put(&bytes, 0, [0x13, 0xFC, 0x00, 0x40])
    put(&bytes, 8, [0x4E, 0x71, 0x04, 0x39, 0x00, 0x01])
    put(&bytes, 18, [0x66, 0xF4, 0x4E, 0x75, 0x48, 0xE7, 0xFF, 0xFE])
    put(&bytes, 36, long(origin) + [0x23, 0x79])
    // `move.l (a1),`: the instruments' table 30 bytes before it, the places' 6, the lengths' 8 after it and
    // the repeats' 24; `mulu #$400`, the patterns 6 after; `cmpi.w #$400`, the order 12 after, its length 34.
    put(&bytes, 70, long(origin + 424))
    put(&bytes, 94, long(origin + 408))
    put(&bytes, 100, [0x23, 0xD1])
    put(&bytes, 108, long(origin + 400))
    put(&bytes, 124, long(origin + 416))
    put(&bytes, 200, [0xC0, 0xFC, 0x04, 0x00])
    put(&bytes, 206, long(origin + 512))
    put(&bytes, 300, [0x0C, 0x79, 0x04, 0x00])
    put(&bytes, 312, long(origin + 488))
    put(&bytes, 334, long(1))
    put(&bytes, 400, long(16) + long(8))
    put(&bytes, 408, long(origin + samplesAt) + long(origin + samplesAt + 32))
    put(&bytes, 416, long(0) + long(1))
    put(&bytes, 424 + 4, word(0) + word(48) + word(1) + word(64))
    for note in notes {
        put(&bytes, 512 + note.at + 4 * note.voice, word(note.period) + [UInt8(note.instrument << 4 | note.command), UInt8(note.parameter)])
    }
    for i in 0 ..< 48 { bytes[samplesAt + i] = UInt8(truncatingIfNeeded: i * 9 + 1) }
    return bytes
}

@Test func fashionTrackerDetection() throws {
    let made = file([])
    #expect(FashionTrackerPlayer.isOne(made))
    var other = made
    other[12] = 2
    #expect(!FashionTrackerPlayer.isOne(other))
    #expect(!FashionTrackerPlayer.isOne(Array(made.prefix(25))))
    let player = try FashionTrackerPlayer(made)
    #expect(player.origin == UInt32(origin))
    #expect(player.sampleCount == 2)
    // Without its origin, or with an instruction found twice, the player calls it corrupt.
    var lost = made
    put(&lost, 40, [0, 0])
    #expect(throws: TuneError.self) { _ = try FashionTrackerPlayer(lost) }
    var twice = made
    put(&twice, 600, [0xC0, 0xFC, 0x04, 0x00])
    #expect(throws: TuneError.self) { _ = try FashionTrackerPlayer(twice) }
    var empty = made
    put(&empty, 334, long(0))
    #expect(throws: TuneError.self) { _ = try FashionTrackerPlayer(empty) }
}

/// A row's notes are started at its first tick: the voice turned off, told its sample, period and volume,
/// and turned on; a sample that does not go round is told silence to go on to. The row read first is the
/// pattern's second (at 16 bytes); the arpeggio moves the period up the table on the five ticks after.
@Test func fashionTrackerNoteReachesPaula() throws {
    var player = try FashionTrackerPlayer(file([
        (0, 2, 428, 1, 0, 0),
        (16, 0, 428, 1, 0, 0),
        (16, 1, 214, 2, 1, 0x47),
    ]))
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == ["off 0", "buffer 0 \(samplesAt) 16", "on 0", "buffer 0 \(player.silenceAt) 4",
                             "off 1", "buffer 1 \(samplesAt + 32) 8", "on 1"])
    #expect(player.periodWritten(0) == 428 && player.volumeWritten(0) == 48)
    #expect(player.periodWritten(1) == 214 && player.volumeWritten(1) == 64)
    var arpeggio: [UInt16] = []
    for _ in 0 ..< 6 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        arpeggio.append(player.periodWritten(1))
    }
    #expect(arpeggio == [170, 143, 214, 170, 143, 143])
    // (The row at nought is never read: voice 2 has had no note.)
    #expect(player.periodWritten(2) == 0)
}

/// The song comes to its end as it comes back to its first pattern: 64 rows of six ticks.
@Test func fashionTrackerSongEnds() throws {
    var player = try FashionTrackerPlayer(file([(16, 0, 428, 1, 0, 0)]))
    #expect(player.lengthClocks == UInt64(64 * 6 * TFMXTiming.fiftyTimes))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 384 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1)
}
