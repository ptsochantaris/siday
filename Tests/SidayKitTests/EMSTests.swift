// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Editeur Musical Séquentiel's player, on tiny modules made here as the editor's are. The
// thorough check is made outside the package: what it tells Paula, tick by tick, against what Wanted Team's
// player tells her in UADE, for every one of UnExoticA's files.

/// What Paula is told, as a list (the moments in the tick, and the periods and volumes, left out).
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

/// Where the player finds the samples: two bytes before the file has them, after its one pattern.
private let samplesAt = 0x538

/// A module of one pattern and one sample (eight words, going round on its first, at volume 40), the pattern's
/// notes given as (row, voice, period, sample, command, its byte).
private func module(_ notes: [(row: Int, voice: Int, period: Int, sample: Int, command: Int, parameter: Int)]) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 314 + 1024 + 16)
    put(&bytes, 0, [1, 0x25] + word(1) + word(0))
    put(&bytes, 134 + 4, word(8) + word(0) + word(1) + word(40))
    for note in notes {
        put(&bytes, 314 + 16 * note.row + 4 * note.voice, word(note.period) + [UInt8(note.sample << 4 | note.command), UInt8(note.parameter)])
    }
    for i in 0 ..< 16 { bytes[1338 + i] = UInt8(i * 5 + 3) }
    return bytes
}

@Test func emsDetection() throws {
    let made = module([(0, 0, 0x1AC, 1, 0, 0)])
    #expect(EMSPlayer.isOne(made))
    // (A period the table has not got; a first byte not 1; no period at all.)
    #expect(!EMSPlayer.isOne(module([(0, 0, 0x1AB, 1, 0, 0)])))
    var other = made
    other[0] = 2
    #expect(!EMSPlayer.isOne(other))
    #expect(!EMSPlayer.isOne(module([])))
    // (Its samples must all be in the file.)
    #expect(throws: TuneError.self) { _ = try EMSPlayer(Array(made.dropLast())) }
    let player = try EMSPlayer(made)
    #expect(player.sampleCount == 1 && player.patternCount == 1)
    // (The player clears the sample's first word.)
    #expect(player.memory[samplesAt] == 0 && player.memory[samplesAt + 1] == 0)
}

/// A row is played on the seventh tick: its voices with a sample turned off, told it and turned on; on the
/// tick after, told its loop. A row lasts the speed and one more tick; command 7 brings the volume down on the
/// ticks between, E sets it, and a speed of nought is none.
@Test func emsNoteReachesPaula() throws {
    var player = try EMSPlayer(module([
        (0, 0, 0x1AC, 1, 0, 0),
        (0, 1, 0x358, 1, 14, 0x30),
        (0, 2, 0, 0, 9, 0),
        (1, 0, 0, 0, 7, 5),
    ]))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 6 { _ = player.run(&none) }
    var row = Recorder()
    _ = player.run(&row)
    #expect(row.events == ["off 0", "off 1", "buffer 0 \(samplesAt) 8", "buffer 1 \(samplesAt) 8", "on 0", "on 1"])
    #expect(player.periodWritten(0) == 0x1AC && player.volumeWritten(0) == 40)
    #expect(player.periodWritten(1) == 0x358 && player.volumeWritten(1) == 0x30)
    var loops = Recorder()
    _ = player.run(&loops)
    #expect(loops.events == ["buffer 0 \(samplesAt) 1", "buffer 1 \(samplesAt) 1"])
    for _ in 0 ..< 5 { _ = player.run(&none) }
    // (The second row, seven ticks after the first, and its command on the six ticks after it.)
    var volumes: [UInt16] = []
    for _ in 0 ..< 7 {
        _ = player.run(&none)
        volumes.append(player.volumeWritten(0))
    }
    #expect(volumes == [40, 35, 30, 25, 20, 15, 10])
}

/// The song comes to its end after its last row: 64 rows of seven ticks, the first after six.
@Test func emsSongEnds() throws {
    var player = try EMSPlayer(module([(0, 0, 0x1AC, 1, 0, 0)]))
    #expect(player.lengthClocks == UInt64((6 + 64 * 7) * TFMXTiming.fiftyTimes))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 6 + 64 * 7 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1)
}
