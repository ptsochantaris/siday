// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Richard Joseph's player, on tiny modules made here. The thorough check is made outside
// the package: what it tells Paula, tick by tick, against what Wanted Team's player tells her in UADE, for
// every song of every one of UnExoticA's modules.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value) }

/// A sample's entry: its sound at `start` in the sample file (after its header), its first part from
/// `begin` for `length` words, its loop, volume and envelope (an offset among the envelopes).
private func sample(start: Int = 0, begin: Int = 0, length: Int = 8, loop: Int = 4, loopLength: Int = 4,
                    volume: Int = 64, envelope: Int = 0) -> [UInt8] {
    long(start) + long(0) + long(0) + word(envelope) + word(volume) + word(begin) + word(length) + word(loop)
        + word(loopLength) + word(0) + word(0) + word(0) + word(0)
}

/// A module of its seven parts: the samples (the first, nought, unplayed), the envelopes, the songs,
/// the sequences (numbered from 1) and the patterns (from 1).
private func module(samples: [[UInt8]] = [sample()], envelopes: [UInt8] = [64, 64, 0, 64, 0, 0],
                    songs: [[UInt8]] = [[1, 0, 0, 0]], sequences: [[UInt8]], patterns: [[UInt8]]) -> [UInt8] {
    func table(_ parts: [[UInt8]]) -> (offsets: [UInt8], bytes: [UInt8]) {
        var offsets = long(0), bytes: [UInt8] = []
        for part in parts {
            offsets += long(bytes.count)
            bytes += part
        }
        return (offsets, bytes)
    }
    let s = table(sequences), p = table(patterns)
    let parts: [[UInt8]] = [([UInt8](repeating: 0, count: 32) + samples.flatMap(\.self)), envelopes, songs.flatMap(\.self),
                            s.offsets, p.offsets, s.bytes, p.bytes]
    return Array("RJP1SMOD".utf8) + parts.flatMap { long($0.count) + $0 }
}

/// A sample file: its header, then a sound of 16 bytes, each 50.
private let samples = Array("RJP1".utf8) + [UInt8](repeating: 50, count: 16)

@Test func richardJosephModulesAreKnownByTheirHeader() throws {
    let tune = module(sequences: [[1, 0, 0]], patterns: [[0x84, 1, 0x18, 0x80]])
    #expect(RichardJosephPlayer.isOne(tune))
    var other = tune
    other[3] = 0x33
    #expect(RichardJosephPlayer.isOne(other))
    other[5] = 0
    #expect(!RichardJosephPlayer.isOne(other))
    // (One a game has set up, its first sample at an address, is not taken.)
    other = tune
    other[15] = 1
    #expect(!RichardJosephPlayer.isOne(other))
    #expect(!RichardJosephPlayer.isOne(Array(tune.prefix(12))))
}

@Test func richardJosephBeginsANoteAsThePlayerDoes() throws {
    // Instrument 1, four rows of six ticks a note, one note, the sequence's end, and its stop.
    let tune = module(samples: [sample(start: 2, begin: 1)], sequences: [[1, 0, 0]], patterns: [[0x84, 1, 0x83, 4, 0x18, 0x80]])
    var player = try RichardJosephPlayer(tune, samples: samples)
    let sound = player.samplesAt + 4 + 2
    var out = Recorder()
    // The note: DMA off, Paula told to play from its beginning (a word in, here), its first part.
    _ = player.run(&out)
    #expect(out.events == ["off 0", "buffer 0 \(sound + 2) 8"])
    #expect(player.period(0) == 0xE2)
    #expect(player.volume(0) == 64)
    // The first word of where it begins is written nought.
    #expect(player.memory[sound + 2] == 0 && player.memory[sound + 3] == 0 && player.memory[sound + 4] == 50)
    // Its DMA on in the next tick, and its loop told her in the one after.
    out.events = []
    _ = player.run(&out)
    #expect(out.events == ["on 0"])
    out.events = []
    _ = player.run(&out)
    #expect(out.events == ["buffer 0 \(sound + 8) 4"])
    // Four rows later, the sequence ends and stops: the song has come to its end. Its note is left
    // sounding its loop, as it is on the Amiga, so it has not stopped.
    for _ in 3 ..< 24 { _ = player.run(&out) }
    #expect(player.endings == 0)
    _ = player.run(&out)
    #expect(player.endings == 1)
    #expect(player.stops == 0)
    #expect(player.lengthClocks == UInt64(24 * 70940))
}

@Test func richardJosephEnvelopeRisesFallsAndIsLetGo() throws {
    // From 0 to 60 in three ticks, to 30 in two, held; let go, to nought in two. A tick a row.
    let tune = module(envelopes: [0, 60, 3, 30, 2, 2], sequences: [[1, 0, 0]],
                      patterns: [[0x84, 1, 0x82, 1, 0x83, 10, 0x18, 0x83, 1, 0x81, 0x87, 0x87, 0x87, 0x87, 0x80]])
    var player = try RichardJosephPlayer(tune, samples: samples)
    var out = Recorder()
    var volumes: [UInt16] = []
    for _ in 0 ..< 14 {
        _ = player.run(&out)
        volumes.append(player.volume(0))
    }
    // (On the last tick of letting go the player keeps the volume of the tick before.)
    #expect(volumes == [0, 20, 40, 60, 60, 45, 30, 30, 30, 30, 30, 15, 15, 0])
}

@Test func richardJosephSongsGoRoundAndEndWhenEveryVoiceHas() throws {
    // Voice 0 plays a pattern of 12 ticks and goes back to it; voice 1 one of 24, and goes back too.
    let tune = module(songs: [[1, 2, 0, 0], [0, 0, 0, 0]], sequences: [[1, 0, 2], [2, 0, 2]],
                      patterns: [[0x84, 1, 0x83, 2, 0x18, 0x80], [0x84, 1, 0x83, 4, 0x1A, 0x80]])
    var player = try RichardJosephPlayer(tune, samples: samples)
    #expect(player.songCount == 2)
    #expect(player.lengthClocks == UInt64(24 * 70940))
    var out = Recorder()
    for _ in 0 ..< 49 { _ = player.run(&out) }
    #expect(player.endings == 2)
    #expect(player.stops == 0)
    // A song with no voices has ended, and stopped, as it begins.
    try player.select(song: 1)
    #expect(player.lengthClocks == 0)
    _ = player.run(&out)
    #expect(player.stops == 1)
    #expect(throws: TuneError.self) { try player.select(song: 2) }
    #expect(try RichardJosephPlayer(tune, samples: samples, song: 1).song == 1)
    #expect(try RichardJosephPlayer(tune, samples: samples, song: 9).song == 0)
}

@Test func richardJosephRefusesWhatThePlayerCannotPlay() throws {
    let tune = module(sequences: [[1, 0, 0]], patterns: [[0x84, 1, 0x18, 0x80]])
    #expect(throws: TuneError.self) { try RichardJosephPlayer(tune, samples: []) }
    #expect(throws: TuneError.self) { try RichardJosephPlayer(Array(tune.dropLast()), samples: samples) }
    #expect(throws: TuneError.self) { try RichardJosephPlayer(Array("RJP1SMOD".utf8) + [UInt8](repeating: 0, count: 56), samples: samples) }
    var odd = tune
    odd[11] = 33
    #expect(throws: TuneError.self) { try RichardJosephPlayer(odd, samples: samples) }
}

@Test func richardJosephNeverStopsTheMachine() throws {
    // A sequence that goes round on itself, of a pattern that is only its end: the voice is stopped.
    let tune = module(sequences: [[1, 0, 2]], patterns: [[0x80]])
    var player = try RichardJosephPlayer(tune, samples: samples)
    var out = Recorder()
    _ = player.run(&out)
    #expect(player.stops == 1)
    // Every cut of a module, and every byte of it changed, plays or is refused.
    let good = module(envelopes: [0, 60, 3, 30, 2, 2], sequences: [[1, 0, 0x80, 1]],
                      patterns: [[0x84, 1, 0x86, 3, 0, 1, 0, 0, 0x85, 40, 0, 0x18, 0x81, 0x87, 0x80]])
    for count in 0 ... good.count {
        if var cut = try? RichardJosephPlayer(Array(good.prefix(count)), samples: samples) {
            for _ in 0 ..< 50 { _ = cut.run(&out) }
        }
    }
    var seed: UInt64 = 0x5EED
    for _ in 0 ..< 300 {
        var bytes = good
        for _ in 0 ..< 4 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[16 + Int(seed >> 33) % (bytes.count - 16)] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        if var changed = try? RichardJosephPlayer(bytes, samples: samples) {
            for _ in 0 ..< 50 { _ = changed.run(&out) }
        }
    }
}

@Test func richardJosephPlaysThroughTheRenderer() throws {
    let tune = module(sequences: [[1, 0, 2]], patterns: [[0x84, 1, 0x83, 4, 0x18, 0x80]])
    let wave = Array("RJP1".utf8) + (0 ..< 16).map { UInt8(bitPattern: Int8($0 % 2 == 0 ? 90 : -90)) }
    let renderer = try PaulaTickRenderer(try RichardJosephPlayer(tune, samples: wave), options: LoadOptions())
    #expect(renderer.info.format == "Richard Joseph")
    #expect(renderer.info.shortfalls.isEmpty)
    let frames = 4800
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.01)
    #expect(renderer.songs.first?.length == Double(24 * 70940) / Paula.clockHz)
    // A sample file shorter than its sounds is said to be.
    let short = try RichardJosephPlayer(tune, samples: Array(wave.prefix(10)))
    #expect(short.tuneInfo.shortfalls.count == 1)
}
