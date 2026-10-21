// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of David Hanney's music, on tiny files made here. The thorough check is made
// outside the package: what it tells Paula, tick by tick, against what Wanted Team's EaglePlayer module
// tells her in UADE, for every one of UnExoticA's files.

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

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// A row's notes: for each voice, its note, instrument and effect.
private typealias Row = [(UInt8, UInt8, UInt8)]

/// A song of the blocks given (each of `rows` rows, its first rows those given), played in `sequence`, at
/// `speed`.
private func song(_ blocks: [[Row]], sequence: [UInt8] = [0, 1], speed: Int = 0, rows: Int = 64) -> [UInt8] {
    var bytes = Array("DSNG".utf8) + Array("SEQU".utf8) + long(256)
    var sequ = [UInt8](repeating: 0, count: 256)
    for (i, b) in sequence.enumerated() { sequ[i] = b }
    bytes += sequ
    bytes += Array("INFO".utf8) + long(10) + [0, UInt8(sequence.count), 0, UInt8(sequence.count), UInt8(speed >> 8), UInt8(speed & 0xFF), 0, 0, 0, 0]
    for (n, block) in blocks.enumerated() {
        bytes += Array("BLK".utf8) + [UInt8(n)] + long(770) + [UInt8(rows >> 8), UInt8(rows & 0xFF)]
        var body = [UInt8](repeating: 0, count: 768)
        for (r, row) in block.enumerated() {
            for (v, cell) in row.enumerated() {
                body[12 * r + 3 * v] = cell.0
                body[12 * r + 3 * v + 1] = cell.1
                body[12 * r + 3 * v + 2] = cell.2
            }
        }
        bytes += body
    }
    return bytes + long(0)
}

/// Where instrument `i`'s wave is in the player's memory.
private func waveAt(_ i: Int) -> Int { DavidHanneyPlayer.instrumentsAt + DavidHanneyPlayer.instrumentSize * i + 10 }

@Test func davidHanneyDetection() throws {
    let file = song([[], []])
    #expect(DavidHanneyPlayer.isOne(file))
    #expect(!DavidHanneyPlayer.isOne(Array(file.prefix(290))))
    var notSong = file
    notSong[0] = UInt8(ascii: "d")
    #expect(!DavidHanneyPlayer.isOne(notSong))
    // (The check wants blocks 0 and 1, one after the other, after the 'INFO'.)
    #expect(!DavidHanneyPlayer.isOne(song([[]], sequence: [0])))
    var far = file
    far[8 + 3] = 0xFF
    #expect(!DavidHanneyPlayer.isOne(far))
    // A sequence that is empty, or names a block the file does not have, is refused.
    #expect(throws: TuneError.self) { _ = try DavidHanneyPlayer(song([[], []], sequence: [])) }
    #expect(throws: TuneError.self) { _ = try DavidHanneyPlayer(song([[], []], sequence: [0, 1, 5])) }
    #expect(throws: TuneError.self) { _ = try DavidHanneyPlayer(Array(file.prefix(1000))) }
    let player = try DavidHanneyPlayer(file)
    #expect(player.blockCount == 2)
    #expect(DavidHanneyData.hunk.count == 0x15A4)
}

/// A note of a wave (instrument 6, note 27: the table's 26th period, $650): the voice turned off and told
/// the wave; at the next tick its period, its volume (the envelope's first step, at once to 63), and the
/// voice turned on.
@Test func davidHanneyWaveNote() throws {
    var player = try DavidHanneyPlayer(song([[[(27, 6, 0)]], []]))
    var recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events == ["off 0", "buffer 0 \(waveAt(6)) 16"])
    recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events == ["period 0 \(0x650)", "volume 0 63", "on 0"])
    // Every third tick the envelope moves on: to its second level (58) at once, its speed being 64; and
    // then towards its third (42) by 32, a step of eight.
    var volumes: [UInt16] = []
    for _ in 0 ..< 7 {
        _ = player.run(&recorder)
        volumes.append(player.volumeWritten(0))
    }
    #expect(volumes == [63, 63, 58, 58, 58, 50, 50])
}

/// A sample (instrument 0, the first): told at once, with its volume (63) and period; turned on at the
/// next tick and told to go round its first word.
@Test func davidHanneySampleNote() throws {
    var player = try DavidHanneyPlayer(song([[[(0, 0, 0), (39, 0, 0)]], []]))
    var recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events == ["off 1", "buffer 1 0 \(0x2B3)", "volume 1 63", "period 1 \(0x328)"])
    recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events == ["on 1", "buffer 1 0 1"])
    recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events.isEmpty)
    // Note 1 stops the voice.
    var stopping = try DavidHanneyPlayer(song([[[(39, 0, 0)], [(1, 0, 0)]], []]))
    _ = stopping.run(&recorder)
    recorder = Recorder()
    _ = stopping.run(&recorder)
    #expect(recorder.events == ["on 0", "buffer 0 0 1", "off 0"])
}

/// $32, the replayer's third arpeggio (0, 4 and 7 notes up), a note a tick from the next.
@Test func davidHanneyArpeggio() throws {
    var player = try DavidHanneyPlayer(song([[[(27, 6, 0x32)]], []], speed: 20))
    var recorder = Recorder()
    var periods: [UInt16] = []
    for _ in 0 ..< 5 {
        _ = player.run(&recorder)
        periods.append(player.periodWritten(0))
    }
    let table = DavidHanneyPlayer.periodTable
    #expect(Array(periods.dropFirst()) == [table[25], table[29], table[32], table[25]])
}

/// The instrument's wave changed as it plays: instrument 6 every fourth tick, its byte at 24 (from where
/// the player was left) made its highest.
@Test func davidHanneyChangingWave() throws {
    var player = try DavidHanneyPlayer(song([[[(27, 6, 0)]], []], speed: 20))
    let at = waveAt(6) + 24
    #expect(player.memory[at] == 0xC0)
    var none = TFMXSilentOutput()
    for _ in 0 ..< 3 { _ = player.run(&none) }
    #expect(player.memory[at] == 0xC0)
    _ = player.run(&none)
    #expect(player.memory[at] == 0x3F)
    // Started again, the instruments are as the player was loaded.
    try player.select(song: 0)
    #expect(player.memory[at] == 0xC0)
}

/// The song goes round at the end of its sequence; its length is to there.
@Test func davidHanneyEnds() throws {
    // Two blocks of two rows, a row a tick: four ticks.
    let player = try DavidHanneyPlayer(song([[], []], speed: 0, rows: 2))
    #expect(player.lengthClocks == UInt64(4) * UInt64(DavidHanneyPlayer.tickClocks))
    var going = try DavidHanneyPlayer(song([[], []], speed: 1, rows: 2))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 8 { _ = going.run(&none) }
    #expect(going.endings == 0)
    _ = going.run(&none)
    #expect(going.endings == 1)
    // A song too slow to come round in an hour is taken never to.
    let slow = try DavidHanneyPlayer(song([[], []], speed: 0xFFFF))
    #expect(slow.lengthClocks == nil)
}

@Test func davidHanneyRenders() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(DavidHanneyPlayer(song([[[(27, 6, 0), (39, 0, 0)]], []])), options: options)
    #expect(renderer.info.format == "David Hanney")
    #expect(renderer.subsongCount == 1)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
