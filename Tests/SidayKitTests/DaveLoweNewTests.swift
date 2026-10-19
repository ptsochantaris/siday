// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Dave Lowe's player, on tiny files made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what Wanted Team's EaglePlayer of it tells her in
// UADE, for every song of UnExoticA's files.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) {
        events.append("buffer \(voice) \(start - DaveLoweNewPlayer.moduleAt) \(length)")
    }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// Where the parts of the files made here are.
private let envelopeAt = 0x100, instrumentAt = 0x120, sampleAt = 0x140, stretchesAt = 0x200

/// A file of one song (or, for Super Street Fighter II's format, given a `tempo`, one song of that
/// tempo), whose voices each play the stretch of commands given for it (in words; a voice given none
/// rests for good), from a list of that stretch alone. Every stretch starts with the filter off, the
/// one envelope (64, 48 and 32, held) and the one instrument (a start of 16 words and a loop of the last
/// 8). A stretch's words may give `stretchesAt + 64 * voice` as places in it.
private func dln(_ voices: [[Int]], tempo: Int? = nil) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: stretchesAt + 64 * 4 + 64)
    func put(_ at: Int, _ values: [UInt8]) { for (i, value) in values.enumerated() { bytes[at + i] = value } }
    let lists = 0xC0
    if let tempo {
        // The song table at 4: the tempo, the four lists and three longs of nought; the next table
        // (its end) at 40, which makes one song.
        put(0, word(4) + word(40) + long(tempo))
    } else {
        // The song table at 8, and at 24 a long that is not nought (Flink's format) and is odd (not
        // a list's offset, and so the end of the songs).
        put(0, word(8) + word(28))
        put(24, long(3))
    }
    for v in 0 ..< 4 {
        put(8 + 4 * v, long(lists + 8 * v))
        put(lists + 8 * v, long(stretchesAt + 64 * v))
        let commands = v < voices.count ? voices[v] : [32, 65000]
        put(stretchesAt + 64 * v, ([48, 12] + [0, envelopeAt, 4, 0, instrumentAt] + commands + [8]).flatMap(word))
    }
    put(envelopeAt, long(0) + [64, 48, 32, 0xFF].flatMap(word))
    put(instrumentAt, word(1) + long(sampleAt) + word(16) + long(sampleAt + 16) + word(8))
    for i in 0 ..< 32 { bytes[sampleAt + i] = UInt8(truncatingIfNeeded: i * 37 + 5) }
    return bytes
}

/// Runs `ticks` ticks, keeping what Paula is told in each.
private func play(_ player: inout DaveLoweNewPlayer, ticks: Int) -> [[String]] {
    var told: [[String]] = []
    for _ in 0 ..< ticks {
        var recorder = Recorder()
        _ = player.run(&recorder)
        told.append(recorder.events)
    }
    return told
}

@Test func daveLoweNewDetection() throws {
    let file = dln([[428, 4]])
    #expect(DaveLoweNewPlayer.isOne(file))
    #expect(DaveLoweNewPlayer.isOne(dln([[428, 4]], tempo: 3)))
    #expect(!DaveLoweNewPlayer.isOne(Array(file.prefix(20))))
    var other = file
    other[1] = 6
    #expect(!DaveLoweNewPlayer.isOne(other))
    // A list's offset that is odd.
    var odd = file
    odd[15] |= 1
    #expect(!DaveLoweNewPlayer.isOne(odd))
    // First stretches that do not start with their envelopes and instruments: the check goes on to the
    // next voice's, and past the fourth, into what follows (here, the long at 24, which is no offset).
    var unlike = file
    unlike[stretchesAt + 3] = 16
    #expect(DaveLoweNewPlayer.isOne(unlike))
    for v in 1 ..< 4 { unlike[stretchesAt + 64 * v + 3] = 16 }
    #expect(!DaveLoweNewPlayer.isOne(unlike))
    // An instrument whose kind is not 1 the check takes, and the player does not.
    var kind = file
    kind[instrumentAt + 1] = 2
    #expect(DaveLoweNewPlayer.isOne(kind))
    #expect(throws: TuneError.self) { _ = try DaveLoweNewPlayer(kind) }
    let player = try DaveLoweNewPlayer(file)
    #expect(player.format == .flink)
    #expect(player.songCount == 1)
    #expect(player.sampleCount == 1)
    #expect(try DaveLoweNewPlayer(dln([[428, 4]], tempo: 3)).format == .streetFighter)
}

/// A note starts its sample at the tick it is reached, with its envelope's first volume; Paula is told
/// the loop at the next tick; the envelope goes on a word a tick and holds its last; and the sample is
/// stopped at the note's last tick.
@Test func daveLoweNewNoteReachesPaula() throws {
    var player = try DaveLoweNewPlayer(dln([[428, 4, 214, 2]]))
    var volumes: [UInt16] = []
    var told: [[String]] = []
    for _ in 0 ..< 6 {
        told += play(&player, ticks: 1)
        volumes.append(player.volume(0))
        if told.count == 1 { #expect(player.period(0) == 428) }
    }
    #expect(told[0] == ["buffer 0 \(sampleAt) 16", "on 0"])
    #expect(told[1] == ["buffer 0 \(sampleAt + 16) 8"])
    #expect(told[2] == [])
    #expect(told[3] == ["off 0"])
    #expect(told[4] == ["buffer 0 \(sampleAt) 16", "on 0"])
    #expect(player.period(0) == 214)
    #expect(volumes == [64, 48, 32, 32, 64, 48])
    // (The voices given no notes rest, quietly, from the first tick.)
    #expect(player.volume(1) == 0)
}

/// A slide moves the period by its step on each tick after its delay, and stops at its target; a
/// vibrato takes its down step off twice and adds its up step twice, a step each so many ticks.
@Test func daveLoweNewSlideAndVibrato() throws {
    var player = try DaveLoweNewPlayer(dln([[16, 1, 10, 450, 1, 428, 20]]))
    var periods: [UInt16] = []
    for _ in 0 ..< 5 {
        _ = play(&player, ticks: 1)
        periods.append(player.period(0))
    }
    #expect(periods == [428, 428, 438, 448, 450])
    var vibrato = try DaveLoweNewPlayer(dln([[20, 0, 1, 3, 2, 0, 0, 400, 20]]))
    periods = []
    for _ in 0 ..< 9 {
        _ = play(&vibrato, ticks: 1)
        periods.append(vibrato.period(0))
    }
    #expect(periods == [400, 398, 398, 396, 396, 399, 399, 402, 402])
}

/// Super Street Fighter II's player lets a tick go by, unplayed, after as many as its song's tempo.
@Test func daveLoweNewTempo() throws {
    var player = try DaveLoweNewPlayer(dln([[428, 3, 214, 3]], tempo: 2))
    var periods: [UInt16] = []
    for _ in 0 ..< 6 {
        _ = play(&player, ticks: 1)
        periods.append(player.period(0))
    }
    // Ticks 1 and 2 played, 3 let go by, 4 and 5 played (the note's third and the next note), 6 not.
    #expect(periods == [428, 428, 428, 428, 214, 214])
    #expect(player.counted == 0)
}

/// A song comes to its end once every voice has come to the end of its list; a song whose voices then
/// all rest for good has stopped; and a voice going round by a jump comes to its end at its second.
@Test func daveLoweNewSongEnds() throws {
    let tick = UInt64(DaveLoweNewPlayer.tickClocks)
    let round = try DaveLoweNewPlayer(dln([[428, 10], [300, 5, 300, 5]]))
    #expect(round.lengthClocks == 10 * tick)
    var player = try DaveLoweNewPlayer(dln([[428, 10], [300, 5, 300, 5]]))
    _ = play(&player, ticks: 10)
    #expect(player.endings == 0)
    _ = play(&player, ticks: 1)
    #expect(player.endings == 1)
    #expect(player.stops == 0)

    var jingle = try DaveLoweNewPlayer(dln([[428, 10, 32, 65000], [300, 7, 32, 65000]]))
    #expect(jingle.lengthClocks == 10 * tick)
    _ = play(&jingle, ticks: 11)
    #expect(jingle.stops == 1)

    // The first voice's stretch jumps back to its note, for ever; the second goes round in 16 ticks.
    let looping = try DaveLoweNewPlayer(dln([[428, 8, 56, 0, stretchesAt + 14], [300, 16]]))
    #expect(looping.lengthClocks == 16 * tick)
}

@Test func daveLoweNewRenders() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(DaveLoweNewPlayer(dln([[428, 50]])), options: options)
    #expect(renderer.info.format == "Dave Lowe New")
    #expect(renderer.subsongCount == 1)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
