// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Synth Dream's player, on tiny files made here as its are. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what Wanted Team's player tells her in UADE, for each of
// UnExoticA's files through its first time round.

/// What Paula is told, as a list (the periods and volumes left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

/// Where the parts are: the tables' places, the four tracks, the two patterns, the tables, the instruments.
private let tracksAt = 40
private let patternsAt = 72
private let volumesAt = 96
private let wavesAt = 102
private let pitchesAt = 108
private let instrumentsAt = 116

/// A file of one song: voice 0 plays pattern 0 (a note of four ticks of instrument 0, a sample whose volume table
/// is $40, $20 and round again), voice 1 pattern 1 (a note of `synthTicks` of instrument 1, a wave: wave 4 with
/// $10 taken from its edge); each track goes round (or for `stops`, voice 0's stops). Voices 2 and 3 are empty.
private func file(synthTicks: Int = 3, stops: Bool = false) -> [UInt8] {
    var bytes = long(instrumentsAt) + long(28) + long(36) + long(tracksAt) + long(tracksAt + 14) + long(tracksAt + 28) + long(tracksAt + 30)
    bytes += long(volumesAt) + long(0) + long(pitchesAt)
    bytes += long(patternsAt) + long(0) + long(0) + word(stops ? 0xFFFF : 0xFEFF)
    bytes += long(patternsAt + 12) + long(0) + long(0) + word(stops ? 0xFFFF : 0xFEFF)
    bytes += word(0xFFFF) + word(0xFFFF)
    bytes += word(0x1C) + word(4) + word(0x30) + word(0) + word(0) + word(0xFFFF)
    bytes += word(0x1C) + word(synthTicks) + word(0x30) + word(0) + word(1) + word(0xFFFF)
    bytes += [2, 0, 0x40, 0x20, 0xFF, 0]
    bytes += [1, 0] + word(0x0410) + [0xFF, 0]
    bytes += [1, 0, 0, 0, 0xFF, 0] + word(0xFFFF)
    bytes += [0, 0] + word(0) + long(volumesAt) + long(0) + long(0) + long(0) + long(4) + word(8) + long(4) + word(8)
    bytes += [0, 0] + word(0) + long(0) + long(0) + long(0) + long(wavesAt) + long(0) + word(0) + long(0) + word(0)
    bytes += [8, 0]
    return bytes
}

private let samples = (0 ..< 32).map { UInt8($0) }

@Test func synthDreamDetection() throws {
    let made = file()
    #expect(made.count == instrumentsAt + 66)
    #expect(SynthDreamPlayer.isOne(made))
    var other = made
    other[instrumentsAt - 1] = 0
    #expect(!SynthDreamPlayer.isOne(other))
    let player = try SynthDreamPlayer(made, samples: samples)
    #expect(player.songCount == 1 && player.sampleCount == 1 && player.synthCount == 1)
    #expect(player.tuneInfo.shortfalls.isEmpty)
    #expect(throws: TuneError.self) { try SynthDreamPlayer(made, samples: []) }
    // (A track whose pattern is past the file's end, and a sample past the sample file's, are said to be.)
    var cut = made
    cut[tracksAt + 2] = 0x70
    #expect(try SynthDreamPlayer(cut, samples: samples).tuneInfo.shortfalls.count == 1)
    #expect(try SynthDreamPlayer(made, samples: Array(samples.prefix(4))).tuneInfo.shortfalls.count == 0)
    var long = made
    long[instrumentsAt + 24] = 0x10
    #expect(try SynthDreamPlayer(long, samples: samples).tuneInfo.shortfalls.count == 1)
}

/// A note's first tick tells Paula its sample and turns the voice on; its second, its loop; its last turns it off;
/// a wave is copied into the voice's sixteen bytes, its edge taken from; the volume table goes round.
@Test func synthDreamNoteReachesPaula() throws {
    var player = try SynthDreamPlayer(file(), samples: samples)
    let sample = player.samplesAt + 4, wave = player.wavesAt + 16
    var ticks: [[String]] = []
    var volumes: [UInt16] = []
    for _ in 0 ..< 5 {
        var tick = Recorder()
        _ = player.run(&tick)
        ticks.append(tick.events)
        volumes.append(player.volume(0))
    }
    #expect(ticks[0] == ["buffer 0 \(sample) 8", "on 0", "buffer 1 \(wave) 8", "on 1"])
    #expect(ticks[1] == ["buffer 0 \(sample) 8", "on 0", "buffer 1 \(wave) 8", "on 1"])
    #expect(ticks[2] == ["on 0", "off 1"])
    #expect(ticks[3] == ["off 0", "buffer 1 \(wave) 8", "on 1"])
    #expect(ticks[4] == ["buffer 0 \(sample) 8", "on 0", "buffer 1 \(wave) 8", "on 1"])
    #expect(volumes == [0x40, 0x20, 0x40, 0x20, 0x40])
    // Note $30's period, from the player's table.
    #expect(player.period(0) == 0x0D0B && player.period(1) == 0x0D0B)
    // Wave 4: four bytes of $81, the rest $7F, $10 taken from the fifth.
    let made = (0 ..< 16).map { player.memory[wave + $0] }
    #expect(made == [0x81, 0x81, 0x81, 0x81, 0x6F] + [UInt8](repeating: 0x7F, count: 11))
}

/// The song comes to its end once both voices have gone round (the empty two having come to theirs as it began),
/// and is as long as the longer's pattern; a track that stops stops its voice, and once all have, the song.
@Test func synthDreamEnds() throws {
    let player = try SynthDreamPlayer(file(), samples: samples)
    #expect(player.lengthClocks == 4 * UInt64(SynthDreamPlayer.tickClocks))
    let longer = try SynthDreamPlayer(file(synthTicks: 6), samples: samples)
    #expect(longer.lengthClocks == 6 * UInt64(SynthDreamPlayer.tickClocks))
    var stopping = try SynthDreamPlayer(file(stops: true), samples: samples)
    #expect(stopping.lengthClocks == 4 * UInt64(SynthDreamPlayer.tickClocks))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 4 { _ = stopping.run(&none) }
    #expect(stopping.endings == 0 && stopping.stops == 0)
    _ = stopping.run(&none)
    #expect(stopping.endings == 1 && stopping.stops == 1)
}

/// Played by `PaulaTickRenderer`, it makes sound, and a file cut short says so.
@Test func synthDreamRenders() throws {
    let renderer = try PaulaTickRenderer(SynthDreamPlayer(file(), samples: samples), options: LoadOptions())
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 4800)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 4800)
    var loudest: Float = 0
    for i in 0 ..< 9600 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0)
    #expect(renderer.info.format == "Synth Dream")
}
