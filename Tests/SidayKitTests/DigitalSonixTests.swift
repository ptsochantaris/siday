// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of Digital Sonix & Chrome's music, on tiny modules made here. The thorough
// check is made outside the package: what it tells Paula, tick by tick, against what Wanted Team's
// EaglePlayer module tells her in UADE, for every song of UnExoticA's files.

/// What Paula is told, as a list, with the moments in the tick left out; and her loop counts, as set.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    var loops = [UInt16](repeating: 0, count: 4)
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_ voice: Int) -> UInt16 { loops[voice] }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { events.append("period \(voice) \(period)") }
    mutating func writeVolume(_ voice: Int, _ volume: UInt16) { events.append("volume \(voice) \(volume)") }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// A module of tempo 286 (five ticks a row) and two samples: the first of 16 bytes at period 428 and
/// volume 48, played once; the second of 8 bytes at period 214 and full volume, its last four repeated
/// twice. Its entries are `entries` (place, times, rows), and an entry of noughts; its four tracks,
/// `tracks`, each `length` bytes.
private func dsc(entries: [(Int, Int, Int)], tracks: [[UInt8]], length: Int) -> [UInt8] {
    var bytes = word(286) + [2, UInt8(entries.count + 1)] + long(24) + long(length)
    for (place, times, rows) in entries { bytes += long(place) + [UInt8(times), UInt8(rows)] }
    bytes += [0, 0, 0, 0, 0, 0]
    for track in tracks { bytes += track + [UInt8](repeating: 0xFF, count: length - track.count) }
    bytes += word(428) + long(16) + long(16) + word(0) + long(0) + [48, 0]
    bytes += word(214) + long(8) + long(4) + word(2) + long(16) + [64, 0]
    for i in 0 ..< 24 { bytes.append(UInt8(truncatingIfNeeded: i * 11 + 3)) }
    return bytes
}

/// One entry of two rows: the first sample on voice 0 at the first row, the second on voice 2 at the
/// second.
private func twoNotes() -> [UInt8] {
    dsc(entries: [(0, 1, 2)], tracks: [[0, 0xFF], [0xFF, 0xFF], [0xFF, 1], [0xFF, 0xFF]], length: 2)
}

@Test func dscDetection() throws {
    let module = twoNotes()
    #expect(DigitalSonixPlayer.isOne(module))
    #expect(!DigitalSonixPlayer.isOne(Array(module.prefix(40))))
    var odd = module
    odd[7] = 25
    #expect(!DigitalSonixPlayer.isOne(odd))
    // (The last entry must be all noughts.)
    var unended = module
    unended[18 + 4] = 1
    #expect(!DigitalSonixPlayer.isOne(unended))
    // (The last sample's sound must end where the samples' sound does.)
    var short = module
    short[module.count - 24 - 18 + 5] = 6
    #expect(!DigitalSonixPlayer.isOne(short))
    #expect(throws: TuneError.self) { _ = try DigitalSonixPlayer(Array(module.prefix(module.count - 1))) }
    let player = try DigitalSonixPlayer(module)
    #expect(player.songCount == 1)
    #expect(player.speed == 5)
}

/// A note is told Paula at once: the voice turned off, its volume, place and length, its period, turned
/// on, and what is to follow it: for a sample played once, silence.
@Test func dscNoteReachesPaula() throws {
    let module = twoNotes()
    var player = try DigitalSonixPlayer(module)
    let sound = module.count - 24
    var recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events == ["off 0", "volume 0 48", "buffer 0 \(sound) 8", "period 0 428", "on 0", "buffer 0 \(player.silenceAt) 2"])
    // The next row five ticks on: the second sample, told its loop.
    for _ in 0 ..< 4 {
        var none = Recorder()
        _ = player.run(&none)
        #expect(none.events.isEmpty)
    }
    recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events == ["off 2", "volume 2 64", "buffer 2 \(sound + 16) 4", "period 2 214", "on 2", "buffer 2 \(sound + 20) 2"])
    #expect(player.periodWritten(2) == 214)
    #expect(player.volumeWritten(2) == 64)
}

/// A sample's loop is played as many times as it says, and then the voice is given silence, once.
@Test func dscRepeatsCounted() throws {
    var player = try DigitalSonixPlayer(dsc(entries: [(0, 1, 8)], tracks: [[1], [], [], []], length: 8))
    var recorder = Recorder()
    _ = player.run(&recorder)
    recorder.loops[0] = 1
    recorder.events.removeAll()
    _ = player.run(&recorder)
    #expect(recorder.events.isEmpty)
    recorder.loops[0] = 2
    _ = player.run(&recorder)
    #expect(recorder.events == ["buffer 0 \(player.silenceAt) 2"])
    recorder.loops[0] = 3
    recorder.events.removeAll()
    _ = player.run(&recorder)
    #expect(recorder.events.isEmpty)
}

/// A pattern is played as many times as its entry says, and the song goes round after its last entry;
/// an entry played no times that closes no entries is no song.
@Test func dscSongsAndLength() throws {
    let tracks: [[UInt8]] = [[0, 0xFF, 0xFF, 0xFF], [], [], []]
    let player = try DigitalSonixPlayer(dsc(entries: [(0, 2, 2), (2, 1, 2), (0, 0, 2)], tracks: tracks, length: 4))
    #expect(player.songCount == 1)
    // Two rows twice and two more, five ticks each.
    #expect(player.lengthClocks == UInt64(6 * 5) * UInt64(DigitalSonixPlayer.tickClocks))
    let two = try DigitalSonixPlayer(dsc(entries: [(0, 1, 2), (0, 0, 2), (2, 1, 1)], tracks: tracks, length: 4), song: 1)
    #expect(two.songCount == 2)
    #expect(two.song == 1)
    #expect(two.lengthClocks == UInt64(5) * UInt64(DigitalSonixPlayer.tickClocks))
    var played = try DigitalSonixPlayer(dsc(entries: [(0, 2, 2), (2, 1, 2)], tracks: tracks, length: 4))
    var recorder = Recorder()
    var notes = 0
    for _ in 0 ..< 30 {
        recorder.events.removeAll()
        _ = played.run(&recorder)
        if recorder.events.contains("on 0") { notes += 1 }
    }
    // (The first row of each time the pattern is played; then the song again.)
    #expect(notes == 2)
    #expect(played.endings == 1)
    _ = played.run(&recorder)
    #expect(recorder.events.contains("on 0"))
}

@Test func dscRenders() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(DigitalSonixPlayer(twoNotes()), options: options)
    #expect(renderer.info.format == "Digital Sonix & Chrome")
    #expect(renderer.subsongCount == 1)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
