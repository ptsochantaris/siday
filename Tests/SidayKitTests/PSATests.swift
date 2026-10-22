// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Professional Sound Artists' player, on tiny files made here as the game's are. The thorough
// check is made outside the package: what it tells Paula, tick by tick, against what Wanted Team's player tells
// her in UADE, for UnExoticA's file.

/// What Paula is told, as a list (the moments in the tick, and the periods and volumes, left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

/// Where the parts are: the instruments (two), the list of patterns, the pattern, the sample.
private let instrumentsAt = 64
private let positionsAt = instrumentsAt + 2 * 64
private let patternsAt = positionsAt + 4
private let sampleAt = patternsAt + 1024

/// A file of one song of one pattern. Its first row sets the speed to 1 on voice 0, plays note 13 of instrument 0
/// on voice 2 and note 1 of instrument 1 on voice 3. Instrument 0 is the sample (eight words, its loop of four
/// from its third, at volume 40, falling by 2 three times); instrument 1 the player's square of 64 words, from 8
/// bytes in, moving up by 2 three times and down by 1 three times, a tick each.
private func file(restart: Int = 0) -> [UInt8] {
    var bytes = Array("PSA".utf8) + [0] + Array("Tiny test tune".utf8) + [UInt8](repeating: 0x20, count: 18)
    bytes += long(sampleAt + 16) + long(instrumentsAt) + long(positionsAt) + long(patternsAt) + long(0)
    bytes += word(0) + word(2) + word(restart) + word(0)
    var sample = long(sampleAt) + word(8) + long(sampleAt + 4) + word(4) + word(40) + [0, 0, 0, 0, 0, 0, 0, 0]
    sample += [4] + [0, 0, 0] + [0, 0, 0, 0] + [2, 1, 3] + [UInt8](repeating: 0x20, count: 31)
    var square = long(0) + word(64) + long(0) + word(0) + word(64) + [1, 8, 2, 1, 3, 1, 1, 3]
    square += [UInt8](repeating: 0, count: 11) + [UInt8](repeating: 0x20, count: 31)
    bytes += sample + square
    bytes += word(0) + word(0)
    var pattern = [UInt8](repeating: 0, count: 1024)
    pattern[0 ..< 4] = [0, 0, 15, 1]
    pattern[8 ..< 12] = [13, 0, 0, 0]
    pattern[12 ..< 16] = [1, 1, 0, 0]
    bytes += pattern
    bytes += (0 ..< 16).map { UInt8($0 * 9 + 2) }
    return bytes
}

@Test func psaDetection() throws {
    let made = file()
    #expect(made.count == sampleAt + 16)
    #expect(PSAPlayer.isOne(made))
    var other = made
    other[3] = 1
    #expect(!PSAPlayer.isOne(other))
    let player = try PSAPlayer(made)
    #expect(player.songCount == 1 && player.instrumentCount == 2 && player.syntheticCount == 1)
    #expect(player.tuneInfo.title == "Tiny test tune")
    var asked = try PSAPlayer(made)
    #expect(throws: TuneError.self) { try asked.select(song: 1) }
}

/// A sample's note is begun on its row's tick: its voice turned off and told its sample, turned on after the
/// wait, and told its loop after the next. A wave's note is told where it starts in the square, and its start
/// moves on every tick. The sample's envelope takes its volume down by 2 three times.
@Test func psaNotesReachPaula() throws {
    var player = try PSAPlayer(file())
    let wave = player.squareAt - 128
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == [
        "off 2", "buffer 2 \(sampleAt) 8", "off 3", "buffer 3 \(wave + 8) 64", "buffer 3 \(wave + 10) 64",
        "on 2", "on 3", "buffer 2 \(sampleAt + 4) 4",
    ])
    #expect(player.periodWritten(2) == 0x1AC && player.periodWritten(3) == 0x358 && player.volumeWritten(2) == 38)
    var starts: [String] = []
    var volumes: [UInt16] = []
    for _ in 0 ..< 6 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        starts += recorder.events
        volumes.append(player.volumeWritten(2))
    }
    // (Up to 14 in three steps, down by one three times, and up again.)
    #expect(starts == [12, 14, 13, 12, 11, 13].map { "buffer 3 \(wave + $0) 64" })
    #expect(volumes == [36, 34, 34, 34, 34, 34])
}

/// The song comes to its end with its last row, and is said to as it begins again: 64 rows of two ticks here.
/// One that goes back to none stops there instead.
@Test func psaSongEnds() throws {
    var player = try PSAPlayer(file())
    #expect(player.lengthClocks == UInt64(128 * TFMXTiming.fiftyTimes))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 128 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1 && player.stops == 0)

    var stopping = try PSAPlayer(file(restart: 0xFFFF))
    #expect(stopping.lengthClocks == UInt64(128 * TFMXTiming.fiftyTimes))
    for _ in 0 ..< 128 { _ = stopping.run(&none) }
    #expect(stopping.stops == 0)
    _ = stopping.run(&none)
    #expect(stopping.stops == 1)
}
