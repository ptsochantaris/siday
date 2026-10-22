// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of Andrew Parton's music, on tiny files made here. The thorough check is
// made outside the package: what it tells Paula, tick by tick, against what Wanted Team's EaglePlayer
// module tells her in UADE, for every one of UnExoticA's files.

/// What Paula is told, as a list, with the moments in the tick kept apart.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    var moments: [Int] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func timed(at clocks: Int) { moments.append(clocks) }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { events.append("period \(voice) \(period)") }
    mutating func writeVolume(_ voice: Int, _ volume: UInt16) { events.append("volume \(voice) \(volume)") }
}

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// A bank of one sample, the first (eight bytes, its last four its loop), whose envelope rises by 16 a
/// tick, falls by 4 to half its height, and dies away by 8; with no vibrato. Its stream: a wait, and
/// then `stream`.
private func bye(_ stream: [UInt8]) -> [UInt8] {
    var tables = [UInt8](repeating: 0, count: 480)
    func put(_ at: Int, _ values: [UInt8]) { for (i, v) in values.enumerated() { tables[at + i] = v } }
    put(0, long(0x1000))
    put(0x50, long(8))
    put(0xA0, long(4))
    put(0xF0, long(4))
    put(0x140, [16, 4, 32, 8])
    var bytes = Array("BANK".utf8) + tables
    bytes += Array("sample one......".utf8)
    for i in 0 ..< 8 { bytes.append(UInt8(i * 30)) }
    return bytes + [0] + stream
}

/// Program 0 on channel 0; a note (72, struck hard) after four ticks, let die away four ticks later; and
/// the end.
private let oneNote: [UInt8] = [0xC0, 0x00, 0x04, 0x90, 72, 0x7F, 0x04, 0x80, 72, 0x00, 0x02, 0xFF, 0x2F]

@Test func byeDetection() throws {
    let file = bye(oneNote)
    #expect(AndrewPartonPlayer.isOne(file))
    #expect(!AndrewPartonPlayer.isOne(Array(file.prefix(200))))
    var notBank = file
    notBank[0] = UInt8(ascii: "b")
    #expect(!AndrewPartonPlayer.isOne(notBank))
    var far = file
    far[4] = 0x20
    #expect(!AndrewPartonPlayer.isOne(far))
    var long = file
    long[0x54 + 1] = 1
    #expect(!AndrewPartonPlayer.isOne(long))
    // A stream with no end is refused, as the player refuses it.
    #expect(throws: TuneError.self) { _ = try AndrewPartonPlayer(Array(file.dropLast(2))) }
    var noEnd = file
    noEnd[noEnd.count - 1] = 0x30
    #expect(throws: TuneError.self) { _ = try AndrewPartonPlayer(noEnd) }
    let player = try AndrewPartonPlayer(file)
    #expect(player.sampleCount == 1)
    #expect(player.musicAt == 484 + 16 + 8)
}

/// A note: the voice turned off, told the sample, its length and the note's period, turned on and told its
/// loop, each after the one before (the waits for the beam); its envelope from nought, at each tick after.
@Test func byeNoteReachesPaula() throws {
    var player = try AndrewPartonPlayer(bye(oneNote))
    var recorder = Recorder()
    _ = player.run(&recorder)
    // (The program, and nothing for the voices, whose envelopes are done.)
    #expect(!recorder.events.contains { $0.hasPrefix("buffer") })
    for _ in 0 ..< 3 {
        recorder = Recorder()
        _ = player.run(&recorder)
    }
    recorder = Recorder()
    _ = player.run(&recorder)
    let sample = 484 + 16
    #expect(Array(recorder.events.prefix(6)) == ["off 0", "buffer 0 \(sample) 4", "period 0 508", "on 0", "buffer 0 \(sample + 4) 2", "period 0 508"])
    #expect(recorder.events.contains("volume 0 16"))
    #expect(recorder.moments[1] - recorder.moments[0] > 8 * 227)
    #expect(recorder.moments[2] - recorder.moments[1] > 8 * 227)
    #expect(player.periodWritten(0) == 508)
    // Up by 16 a tick to its height (63, half 127).
    var volumes: [UInt16] = []
    for _ in 0 ..< 3 {
        _ = player.run(&recorder)
        volumes.append(player.volumeWritten(0))
    }
    #expect(volumes == [32, 48, 63])
    // Let die away at the fourth tick from the note, by 8 a tick.
    _ = player.run(&recorder)
    #expect(player.volumeWritten(0) == 55)
    _ = player.run(&recorder)
    #expect(player.volumeWritten(0) == 47)
}

/// Once at its height a note falls by 4 a tick towards its level (half its height, 31); and a note struck
/// softly enough (once halved, nought) lets the voice's note die away instead.
@Test func byeSoftNoteReleases() throws {
    var player = try AndrewPartonPlayer(bye([0xC0, 0x00, 0x00, 0x90, 72, 0x7F, 0x05, 0x90, 72, 0x01, 0x10, 0xFF, 0x2F]))
    var recorder = Recorder()
    for _ in 0 ..< 4 { _ = player.run(&recorder) }
    #expect(player.volumeWritten(0) == 63)
    _ = player.run(&recorder)
    #expect(player.volumeWritten(0) == 59)
    _ = player.run(&recorder)
    #expect(player.volumeWritten(0) == 51)
}

/// The end: the stream is read no more, the voices die away, and once they are silent the song has
/// stopped; a stream that goes back to its start goes round.
@Test func byeEndsAndLoops() throws {
    let once = try AndrewPartonPlayer(bye(oneNote))
    // The note at tick 4, let go at 8, from 63 by 8 a tick: silent at tick 15.
    #expect(once.lengthClocks == UInt64(15) * UInt64(AndrewPartonPlayer.tickClocks))
    var player = try AndrewPartonPlayer(bye(oneNote))
    var recorder = Recorder()
    for _ in 0 ..< 15 { _ = player.run(&recorder) }
    #expect(player.stops == 0)
    _ = player.run(&recorder)
    #expect(player.stops == 1)
    let round = try AndrewPartonPlayer(bye([0xC0, 0x00, 0x00, 0x90, 72, 0x7F, 0x05, 0xC0, 0x7E, 0xFF, 0x2F]))
    // (Back to the start, read on at once, from its second byte, as the player reads it: a round of five
    // ticks.)
    #expect(round.lengthClocks == UInt64(5) * UInt64(AndrewPartonPlayer.tickClocks))
    #expect(round.stops == 0)
}

@Test func byeRenders() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(AndrewPartonPlayer(bye(oneNote)), options: options)
    #expect(renderer.info.format == "Andrew Parton")
    #expect(renderer.subsongCount == 1)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
