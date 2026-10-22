// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Tim Follin's player, on tiny files made here as the games' are. The thorough check is made outside
// the package: what it tells Paula, tick by tick, against what Andy Silva's player tells her in UADE, for every song
// of UnExoticA's files.

/// What Paula is told, as a list (the periods and volumes left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

/// The address the file was made for (where its places point), less where each part is in it.
private let made = 0x2000
private let silentAt = 0x1A0
private let tableAt = 0x1B0
private let waveAt = 0x200
private let sampleAt = 0x280
private let streamsAt = 0x300

/// A file of the data alone, of one song: voice 0 plays instrument 5 (a sample of eight words) at note $30 for three
/// ticks, its envelope starting at 60 and coming down by 16 a tick, and jumps back to its note; voice 1 plays the
/// first instrument, a wave whose width moves every tick, for two ticks and comes to its end, unless `loop`; voices
/// 2 and 3 come to their ends at once.
private func file(loop: Bool = true) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x400)
    func put(_ at: Int, _ values: [UInt8]) { for (i, b) in values.enumerated() { bytes[at + i] = b } }
    func long(_ at: Int, _ value: Int) { put(at, [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
    put(0, [0x10, 0x10])
    let begin = 2
    // Song nought, its four voices at the bytes by which the file's address is found; song one's four voices.
    for v in 0 ..< 4 { long(begin + 4 + 4 * v, made + silentAt) }
    for v in 0 ..< 4 { long(begin + 20 + 4 * v, made + streamsAt + 32 * v) }
    long(begin + 0x104, made + tableAt)
    long(begin + 0x108, made + tableAt)
    put(begin + 0x144, [4, 4])
    put(silentAt, [0x81, 0x04, 0x32, 0x02, 0x8F, 0x00])
    // The instruments: nought the wave (of 40 words), 5 the sample.
    long(tableAt, made + waveAt)
    long(tableAt + 20, made + sampleAt)
    put(waveAt, [0, 40])
    put(sampleAt, [0, 8])
    // Voice 0: instrument 5, the envelope's step 16, from 60 holding at nought, at once, in its part going down;
    // its note, and a jump back to it.
    put(streamsAt, [0x81, 5, 0x90, 16, 0x86, 0xF0, 0x00, 0x01, 0x8C, 1, 0x30, 3, 0x92, 0])
    long(streamsAt + 14, made + streamsAt + 10)
    // Voice 1: the wave, moved every tick; a note of two ticks, and its end.
    put(streamsAt + 32, [0x81, 0, 0x8E, 1, 0x24, 2, loop ? 0x80 : 0x8F, 0x8F])
    put(streamsAt + 64, [0x8F])
    put(streamsAt + 96, [0x8F])
    return bytes
}

@Test func timFollinDetection() throws {
    let bytes = file()
    #expect(TimFollinPlayer.isOne(bytes))
    var other = bytes
    other[0x0B] = 1
    #expect(!TimFollinPlayer.isOne(other))
    let player = try TimFollinPlayer(bytes)
    #expect(player.songCount == 1 && !player.withCode)
    // (Without the bytes of song nought, the file's address is not known.)
    var lost = bytes
    lost[silentAt] = 0x80
    #expect(throws: TuneError.self) { try TimFollinPlayer(lost) }
}

/// A note is told Paula with its instrument's sample, 50 bytes after its start, and its voice turned on; a voice that
/// comes to its end is turned off. The envelope comes down by its step on every tick, and holds once it has passed
/// nought; the wave's edge moves into its sample, a byte a tick, from its eighth.
@Test func timFollinNotesReachPaula() throws {
    var player = try TimFollinPlayer(file())
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == [
        "buffer 0 \(sampleAt + 50) 8", "on 0", "buffer 1 \(waveAt + 50) 40", "on 1", "off 2", "off 3",
    ])
    #expect(player.period(0) == TimFollinPlayer.periodTable[0x30] && player.period(1) == TimFollinPlayer.periodTable[0x24])
    var volumes: [UInt16] = []
    var edges: [UInt8] = []
    for _ in 0 ..< 3 {
        var none = TFMXSilentOutput()
        _ = player.run(&none)
        volumes.append(player.volume(0))
        edges.append(player.memory[waveAt + 50 + 8])
    }
    #expect(volumes == [44, 28, 12])
    #expect(edges == [0x80, 0x80, 0x80] && player.memory[waveAt + 50 + 9] == 0x80)
}

/// The song comes to its end once every voice has come to its end or jumped back: here voice 0 jumps back on its
/// fourth tick. One whose voices all come to their ends stops there.
@Test func timFollinSongEnds() throws {
    var player = try TimFollinPlayer(file())
    #expect(player.lengthClocks == UInt64(3 * TFMXTiming.fiftyTimes))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 3 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1 && player.stops == 0)

    var bytes = file(loop: false)
    bytes[streamsAt + 12] = 0x8F
    var stopping = try TimFollinPlayer(bytes)
    #expect(stopping.lengthClocks == UInt64(3 * TFMXTiming.fiftyTimes))
    for _ in 0 ..< 3 { _ = stopping.run(&none) }
    #expect(stopping.stops == 0)
    _ = stopping.run(&none)
    #expect(stopping.stops == 1)
}
