// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of Images Music System, on tiny modules made here. The thorough check is
// made outside the package: what it tells Paula, tick by tick, against what the player itself tells
// her in UADE, for every song of every one of UnExoticA's modules.

/// What Paula is told, as a list.
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

/// A note of a pattern: its row, voice, note (63 for none), sample, command and the command's parameter.
private typealias Cell = (pattern: Int, row: Int, voice: Int, note: Int, sample: Int, command: Int, parameter: Int)

/// A module of one sample, of sixteen words at volume 40 looping over eight from its fifth. Its order
/// is `order`, of patterns holding `cells` (and otherwise no notes).
private func ims(order: [Int] = [0], cells: [Cell]) -> [UInt8] {
    let patterns = (order.max() ?? 0) + 1
    let samplesAt = 1084 + 768 * patterns
    var bytes = [UInt8](repeating: 0, count: samplesAt + 32)
    put(&bytes, 0, Array("tiny".utf8))
    put(&bytes, 20 + 22, word(16) + [0, 40] + word(4) + word(8))
    bytes[950] = UInt8(order.count)
    for (i, pattern) in order.enumerated() { bytes[952 + i] = UInt8(pattern) }
    put(&bytes, 1080, [0, 0] + word(samplesAt))
    for p in 0 ..< patterns {
        for cell in 0 ..< 256 { bytes[1084 + 768 * p + 3 * cell] = 0x3F }
    }
    for cell in cells {
        let at = 1084 + 768 * cell.pattern + 12 * cell.row + 3 * cell.voice
        put(&bytes, at, [UInt8((cell.sample & 0x30) << 2 | cell.note), UInt8((cell.sample & 0x0F) << 4 | cell.command), UInt8(cell.parameter)])
    }
    for i in 0 ..< 32 { bytes[samplesAt + i] = UInt8(truncatingIfNeeded: i * 9 + 1) }
    return bytes
}

@Test func imsDetection() throws {
    let module = ims(cells: [])
    #expect(IMSPlayer.isOne(module))
    #expect(!IMSPlayer.isOne(Array(module.prefix(1852))))
    var misplaced = module
    misplaced[1083] &+= 1
    #expect(!IMSPlayer.isOne(misplaced))
    var unplayed = module
    unplayed[952] = 1
    #expect(!IMSPlayer.isOne(unplayed))
    // A module whose samples are not all in it is refused.
    var short = module
    short.removeLast()
    #expect(IMSPlayer.isOne(short))
    #expect(throws: TuneError.self) { _ = try IMSPlayer(short) }
    let player = try IMSPlayer(module)
    #expect(player.title == "tiny")
}

/// A note is started at once: Paula's voice off, told where its sample is, on again, then told where
/// its loop is; with its period from the player's table and its sample's volume.
/// E turns the filter on for an even parameter and off for an odd one, as ProTracker's E0x does.
@Test func imsFilter() throws {
    let module = ims(cells: [(0, 0, 1, 24, 1, 0xE, 0), (0, 1, 1, 24, 1, 0xE, 1)])
    var player = try IMSPlayer(module)
    var states = [player.lightFilter]
    var recorder = Recorder()
    _ = player.run(&recorder)
    states.append(player.lightFilter)
    for _ in 0 ..< 6 { _ = player.run(&recorder) }
    states.append(player.lightFilter)
    #expect(states == [false, true, false])
}

@Test func imsNoteReachesPaula() throws {
    let module = ims(cells: [(0, 0, 1, 24, 1, 0, 0)])
    var player = try IMSPlayer(module)
    var recorder = Recorder()
    _ = player.run(&recorder)
    let samplesAt = 1084 + 768
    #expect(recorder.events == ["off 1", "buffer 1 \(samplesAt) 16", "on 1", "buffer 1 \(samplesAt + 8) 8"])
    #expect(player.period(1) == 0x1AC)
    #expect(player.volume(1) == 40)
}

/// The arpeggio plays the two notes above the note in turn, from its own row on, and the volume's
/// slide slides from its own row.
@Test func imsArpeggioAndVolumeSlide() throws {
    var player = try IMSPlayer(ims(cells: [(0, 0, 0, 12, 1, 0, 0x37), (0, 0, 2, 0, 1, 0x0A, 0x05)]))
    var recorder = Recorder()
    var periods: [UInt16] = [], volumes: [UInt16] = []
    for _ in 0 ..< 4 {
        _ = player.run(&recorder)
        periods.append(player.period(0))
        volumes.append(player.volume(2))
    }
    #expect(periods == [0x2D0, 0x23A, 0x2D0, 0x23A])
    #expect(volumes == [35, 30, 25, 20])
}

/// Each B ends a song, and the next song begins after it; a song is as long as it plays to its jump.
@Test func imsSongs() throws {
    let module = ims(order: [0, 1, 2], cells: [(0, 0, 0, 24, 1, 0, 0), (1, 1, 0, 0, 0, 0x0B, 0), (2, 0, 0, 0, 0, 0x0B, 2)])
    let first = try IMSPlayer(module)
    #expect(first.songCount == 2)
    // Pattern 0's 64 rows of six ticks, and two rows of pattern 1.
    #expect(first.lengthClocks == UInt64((64 + 2) * 6) * UInt64(IMSPlayer.tickClocks))
    let second = try IMSPlayer(module, song: 1)
    #expect(second.song == 1)
    #expect(second.lengthClocks == UInt64(6) * UInt64(IMSPlayer.tickClocks))
    // With no B, a song goes round at its order's end, to the restart.
    let round = try IMSPlayer(ims(cells: []))
    #expect(round.songCount == 1)
    #expect(round.lengthClocks == UInt64(64 * 6) * UInt64(IMSPlayer.tickClocks))
}

/// The speed command sets the ticks a row, and the volume command the volume of the row's note.
@Test func imsSpeedAndVolume() throws {
    var player = try IMSPlayer(ims(cells: [(0, 0, 0, 24, 1, 0x0F, 2), (0, 0, 1, 24, 1, 0x0C, 0x50), (0, 1, 2, 29, 1, 0, 0)]))
    var recorder = Recorder()
    _ = player.run(&recorder)
    #expect(player.volume(1) == 64)
    _ = player.run(&recorder)
    #expect(player.period(2) == 0)
    _ = player.run(&recorder)
    #expect(player.period(2) == 0x140)
}

@Test func imsRenders() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(IMSPlayer(ims(cells: [(0, 0, 0, 24, 1, 0, 0)])), options: options)
    #expect(renderer.info.format == "IMS")
    #expect(renderer.info.title == "tiny")
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
