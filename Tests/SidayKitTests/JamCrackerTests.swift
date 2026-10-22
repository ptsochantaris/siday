// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of JamCracker's player, on a tiny module made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what the EaglePlayer module tells her in UADE, for
// every one of UnExoticA's modules.

/// What Paula is told, as a list (the moments in the tick left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { events.append("period \(voice) \(period)") }
    mutating func writeVolume(_ voice: Int, _ volume: UInt16) { events.append("volume \(voice) \(volume)") }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

/// An instrument's 40 bytes: a name, its flags and its size.
private func instrument(_ flags: UInt8, size: Int) -> [UInt8] {
    [UInt8](repeating: 0x41, count: 31) + [flags] + long(size) + long(0)
}

/// Where the rows and the samples are in the module below.
private let rowsAt = 6 + 80 + 2 + 6 + 2 + 2
private let samplesAt = rowsAt + 2 * 32
private let waveAt = samplesAt + 32

/// A module of two instruments (a sample of 32 bytes that does not go round, and a wave of 384), one
/// pattern of two rows, a song of that pattern, and the rows' notes given as (row, voice, eight bytes).
private func module(_ notes: [(row: Int, voice: Int, bytes: [UInt8])]) -> [UInt8] {
    var bytes = Array("BeEp".utf8) + word(2) + instrument(0, size: 32) + instrument(3, size: 384)
    bytes += word(1) + word(2) + long(0)
    bytes += word(1) + word(0)
    var rows = [UInt8](repeating: 0, count: 64)
    for note in notes {
        for (i, b) in note.bytes.enumerated() { rows[32 * note.row + 8 * note.voice + i] = b }
    }
    bytes += rows
    bytes += (0 ..< 32).map { UInt8(truncatingIfNeeded: $0 * 7) }
    bytes += (0 ..< 384).map { UInt8(truncatingIfNeeded: $0 * 5 + 3) }
    return bytes
}

@Test func jamCrackerDetection() throws {
    let made = module([])
    #expect(made.count == waveAt + 384)
    #expect(JamCrackerPlayer.isOne(made))
    var other = made
    other[1] = 0x45
    #expect(!JamCrackerPlayer.isOne(other))
    let player = try JamCrackerPlayer(made)
    #expect(player.instrumentCount == 2 && player.patternCount == 1 && player.songLength == 1 && player.waveCount == 1)
    #expect(player.tuneInfo.shortfalls.isEmpty)
    // Its tables cut short, it is refused; its samples cut short, it is played, and says so.
    #expect(throws: TuneError.self) { _ = try JamCrackerPlayer(Array(made.prefix(60))) }
    #expect(try JamCrackerPlayer(Array(made.prefix(waveAt + 100))).tuneInfo.shortfalls.count == 1)
    var empty = made
    empty[rowsAt - 3] = 0
    #expect(throws: TuneError.self) { _ = try JamCrackerPlayer(empty) }
}

/// A row's notes: their voices turned off, told their samples and periods, turned on, and every voice told
/// what it goes on to (silence for a sample that does not go round, the wave again for the wave, and
/// nowhere for a voice that has played nothing); then at every tick each voice's period and volume.
@Test func jamCrackerNoteReachesPaula() throws {
    var player = try JamCrackerPlayer(module([
        (0, 0, [13, 0, 0x83, 0, 0, 0, 40, 0]),
        (0, 1, [1, 1, 0, 0, 0, 0, 0, 0]),
    ]))
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == [
        "off 0", "off 1",
        "buffer 0 \(samplesAt) 16", "period 0 509", "buffer 1 \(waveAt + 0xC0) 32", "period 1 1019",
        "on 0", "on 1",
        "buffer 0 \(player.silenceAt) 1", "buffer 1 \(waveAt + 0xC0) 32", "buffer 2 -1 0", "buffer 3 -1 0",
        "period 0 509", "volume 0 40", "period 1 1019", "volume 1 64",
        "period 2 1019", "volume 2 0", "period 3 1019", "volume 3 0",
    ])
}

/// The arpeggio's three periods in turn, a tick each; and the volume sliding down by its amount a tick.
@Test func jamCrackerArpeggioAndSlide() throws {
    var player = try JamCrackerPlayer(module([(0, 0, [13, 0, 0x0F, 0x47, 0, 0, 0x85, 0])]))
    var periods: [UInt16] = [], volumes: [UInt16] = []
    for _ in 0 ..< 4 {
        var none = TFMXSilentOutput()
        _ = player.run(&none)
        periods.append(player.periodWritten(0))
        volumes.append(player.volumeWritten(0))
    }
    #expect(periods == [509, 404, 340, 509])
    #expect(volumes == [64, 59, 54, 49])
}

/// A wave is mixed afresh at every tick into the voice's copy: its first 64 bytes with themselves from a
/// quarter of its phase on, halved, the phase moving on by the row's amount.
@Test func jamCrackerWaveIsMixed() throws {
    let made = module([(0, 0, [1, 1, 0, 0, 0, 1, 0, 0])])
    var player = try JamCrackerPlayer(made)
    var none = TFMXSilentOutput()
    for _ in 0 ..< 5 { _ = player.run(&none) }
    // (The phase was 4 at the fifth tick: one byte on.)
    let copy = (0 ..< 64).map { player.memory[waveAt + 0x80 + $0] }
    let wave = (0 ..< 65).map { Int(Int8(bitPattern: made[waveAt + $0])) }
    #expect(copy == (0 ..< 64).map { UInt8(truncatingIfNeeded: (wave[$0] + wave[$0 + 1]) >> 1) })
    // Started again, the module is as it was loaded.
    try player.select(song: 0)
    #expect((0 ..< 64).map { player.memory[waveAt + 0x80 + $0] } == Array(made[(waveAt + 0x80) ..< (waveAt + 0xC0)]))
}

/// The song comes to its end as its first row is read again: here two rows of three ticks.
@Test func jamCrackerSongEnds() throws {
    var player = try JamCrackerPlayer(module([(0, 0, [13, 0, 0x03, 0, 0, 0, 0, 0])]))
    #expect(player.lengthClocks == UInt64(6 * JamCrackerPlayer.tickClocks))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 6 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1)
}
