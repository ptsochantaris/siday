// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Blade Packer's player, on tiny files made here as its are. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what Wanted Team's player tells her in UADE, for every song of
// every one of UnExoticA's files.

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

/// A file of two positions (patterns 0, 1, 1, 1 and 2, 1, 1, 1) and so two songs: pattern 0 a note of instrument 1
/// (note 24, the twelfth period) and then a position jump to the first; pattern 1 a note on its second row; pattern 2
/// a note at volume $20 and then an 8 command. Its dictionary: nothing, the note, the jump, the note and volume,
/// the 8.
private func module(cutDictionary: Bool = false) -> [UInt8] {
    var bytes: [UInt8] = [0x53, 0x8F, 0x4E, 0x47, 0x2E, 0x42, 0x34, 0]
    bytes += [0, 1, 1, 1, 2, 1, 1, 1] + word(0xDD48)
    bytes += [1, 2] + [UInt8](repeating: 0, count: 62)
    bytes += [0, 1] + [UInt8](repeating: 0, count: 62)
    bytes += [3, 4] + [UInt8](repeating: 0, count: 62)
    bytes += word(0xD8F1)
    bytes += [0, 0, 0, 0] + [24, 1, 0, 0] + [0, 0, 0x2C, 0] + [24, 1, 0x30, 0x20]
    if !cutDictionary { bytes += [0, 0, 0x20, 0] }
    return bytes
}

/// Its samples: "SPLS", two entries (the first: from byte 36, sixteen bytes, its last eight going round, volume $30;
/// the second empty), and the sample.
private let samples: [UInt8] = Array("SPLS".utf8) + long(36) + long(52) + long(8) + [0x30, 0, 0, 0]
    + long(52) + long(52) + long(0) + [0x40, 0, 0, 0] + (0 ..< 16).map { UInt8($0 * 8) }

@Test func bladePackerDetection() throws {
    let made = module()
    #expect(BladePackerPlayer.isOne(made))
    var other = made
    other[1] = 0x8E
    #expect(!BladePackerPlayer.isOne(other))
    let player = try BladePackerPlayer(made, samples: samples)
    #expect(player.songCount == 2 && player.sampleCount == 1 && player.voiceCount == 4)
    #expect(player.tuneInfo.shortfalls.isEmpty)
    // (A sample that runs past the sample file's end is said to.)
    var long = samples
    long[10] = 0x10
    #expect(try BladePackerPlayer(made, samples: long).tuneInfo.shortfalls.count == 1)
    #expect(throws: TuneError.self) { try BladePackerPlayer(made, samples: []) }
    #expect(throws: TuneError.self) { try BladePackerPlayer(made, samples: [0, 0, 1, 0] + samples.dropFirst(4)) }
    #expect(throws: TuneError.self) { try BladePackerPlayer(module(cutDictionary: true), samples: samples) }
    #expect(throws: TuneError.self) { try BladePackerPlayer(Array(made.prefix(200)), samples: samples) }
}

/// Paula is told a tick late: on the first tick every voice is started on the player's silence; on the second, the
/// first row's note (its sample, then its loop); and its third and fourth voices are Paula's fourth and third.
@Test func bladePackerNoteReachesPaula() throws {
    var player = try BladePackerPlayer(module(), samples: samples)
    let silence = player.silenceAt, sample = player.samplesAt + 36
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == ["off 0", "off 1", "off 2", "off 3"] + (0 ..< 4).map { "buffer \($0) \(silence) 1" } + ["on 0", "on 1", "on 2", "on 3"]
        + (0 ..< 4).map { "buffer \($0) \(silence) 1" })
    var second = Recorder()
    _ = player.run(&second)
    #expect(second.events == ["off 0", "buffer 0 \(sample) 8", "on 0", "buffer 0 \(sample + 8) 4"])
    #expect(player.periodWritten(0) == 0x1C5 && player.volumeWritten(0) == 0x30)
    #expect(player.periodWritten(1) == 0 && player.periodWritten(2) == 0)
    // The other three's notes, on the second row: as each is playing at a period of nought, it is not turned off
    // and on again, but told its sample and loop (which Paula takes up as the word she is playing ends).
    var none = TFMXSilentOutput()
    for _ in 0 ..< 5 { _ = player.run(&none) }
    var eighth = Recorder()
    _ = player.run(&eighth)
    #expect(eighth.events == (1 ..< 4).map { "buffer \($0) \(sample) 8" } + (1 ..< 4).map { "buffer \($0) \(sample + 8) 4" })
    #expect(player.periodWritten(1) == 0x1C5 && player.periodWritten(3) == 0x1C5 && player.periodWritten(2) == 0x1C5)
}

/// The first song comes to its end at its position jump (said as the row after is read), the second at its 8
/// command, which starts it again on the next tick.
@Test func bladePackerEnds() throws {
    var player = try BladePackerPlayer(module(), samples: samples)
    #expect(player.lengthClocks == 12 * UInt64(BladePackerPlayer.tickClocks))
    try player.select(song: 1)
    #expect(player.lengthClocks == 7 * UInt64(BladePackerPlayer.tickClocks))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 7 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1)
    // The note's volume, from its C command, is told on the tick after.
    #expect(player.volumeWritten(0) == 0x20)
    #expect(throws: TuneError.self) { try player.select(song: 2) }
}

/// Played by `PaulaTickRenderer`, it makes sound.
@Test func bladePackerRenders() throws {
    let renderer = try PaulaTickRenderer(BladePackerPlayer(module(), samples: samples), options: LoadOptions())
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 4800)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 4800)
    var loudest: Float = 0
    for i in 0 ..< 9600 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0)
    #expect(renderer.info.format == "Blade Packer" && renderer.subsongCount == 2)
}
