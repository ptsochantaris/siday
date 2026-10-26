// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Thomas Hermann's player, on tiny modules made here. The thorough check is made outside the
// package: what it tells Paula, against what Wanted Team's EaglePlayer module tells her in UADE, for every
// song of UnExoticA's files.

/// What Paula is told, as a list, each with when it is told (in Paula's clocks from the song's start).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    var times: [UInt64] = []
    var start: UInt64 = 0
    var at: UInt64 = 0
    mutating func note(_ s: String) {
        events.append(s)
        times.append(start + at)
    }
    mutating func on(_ voice: Int) { note("on \(voice)") }
    mutating func off(_ voice: Int) { note("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { note("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func timed(at clocks: Int) { at = UInt64(clocks) }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { note("period \(voice) \(period)") }
    mutating func writeVolume(_ voice: Int, _ volume: UInt16) { note("volume \(voice) \(volume)") }
}

private func put(_ bytes: inout [UInt8], word value: Int, at: Int) {
    bytes[at] = UInt8(value >> 8 & 0xFF)
    bytes[at + 1] = UInt8(value & 0xFF)
}

private func put(_ bytes: inout [UInt8], long value: Int, at: Int) {
    put(&bytes, word: value >> 16 & 0xFFFF, at: at)
    put(&bytes, word: value & 0xFFFF, at: at + 2)
}

/// A module whose pointers are from 0x10000: every position of every voice an empty pattern (at 6,784), but for
/// position nought of voice nought, whose pattern (at 6,832) plays sample one in its first row, `note` with
/// `effect`. The song is position $FF and then nought (its loop and end), speed 3, on the timer 16,384. Sample
/// one: 16 bytes at volume 48, played once (or repeated from its eighth byte, `mode` 1), named "df1:Snare"; and
/// `size` bytes in all, its furthest pattern `furthest` (6,832 unless given).
private func module(note: UInt8 = 0x01, effect: UInt8 = 0, mode: UInt8 = 0, size: Int = 6912, furthest: Int = 6832) -> [UInt8] {
    let origin = 0x10000
    var m = [UInt8](repeating: 0, count: size)
    for v in 0 ..< 4 { put(&m, long: origin + 64 + 1024 * v, at: 4 * v) }
    for k in 0 ..< 4 { put(&m, long: origin + 4160 + 256 * k, at: 16 + 4 * k) }
    m[32] = 0
    m[33] = 0
    m[34] = 0xFF
    m[35] = 1
    put(&m, long: origin + 5184, at: 36)
    m[41] = 15
    put(&m, word: 16384, at: 42)
    m[44] = 3
    put(&m, long: origin, at: 46)
    for v in 0 ..< 4 {
        for p in 0 ..< 256 { put(&m, long: origin + 6784, at: 64 + 1024 * v + 4 * p) }
    }
    put(&m, long: origin + 6832, at: 64)
    put(&m, long: origin + furthest, at: 64 + 4 * 7)
    for i in 0 ..< 32 { put(&m, long: origin + 5312 + 48 * i, at: 5184 + 4 * i) }
    // Sample one's record.
    let r = 5360
    put(&m, word: 16, at: r)
    m[r + 2] = 48
    m[r + 3] = 1
    put(&m, word: mode == 0 ? 16 : 8, at: r + 8)
    put(&m, word: mode == 0 ? 0 : 8, at: r + 10)
    put(&m, word: 214, at: r + 12)
    for (i, c) in "df1:Snare".utf8.enumerated() { m[r + 14 + i] = c }
    m[r + 0x23] = mode
    m[r + 0x2D] = 4
    for row in 0 ..< 16 {
        m[6784 + 3 * row] = 0xFF
        m[6832 + 3 * row] = 0xFF
    }
    m[6832] = note
    m[6833] = 1
    m[6834] = effect
    return m
}

private let sound: [UInt8] = (0 ..< 16).map { UInt8($0 * 9 + 1) }

/// Runs the player until `until` clocks, recording what it tells Paula.
private func run(_ player: inout ThomasHermannPlayer, until: UInt64) -> Recorder {
    var r = Recorder()
    while player.clock < until {
        r.start = player.clock
        r.at = 0
        _ = player.run(&r)
    }
    return r
}

@Test func thomasHermannCheck() {
    let m = module()
    #expect(ThomasHermannPlayer.isOne(m))
    var odd = m
    odd[49] |= 1
    #expect(!ThomasHermannPlayer.isOne(odd))
    var off = m
    put(&off, long: 0x10000 + 4164, at: 20)
    #expect(!ThomasHermannPlayer.isOne(off))
    #expect(!ThomasHermannPlayer.isOne(Array(m[0 ..< 6848])))
    #expect(ThomasHermannPlayer.instrumentNames(m) == ["Snare"])
}

@Test func thomasHermannPlaysItsNote() throws {
    var p = try ThomasHermannPlayer(module(), samples: sound)
    #expect(p.songCount == 1)
    // Position $FF's sixteen rows, then position nought's first read a tick before its notes play.
    let song: UInt64 = 81925
    let r = run(&p, until: 86 * song + 1165 + 4000)
    let place = (6912 + 15) & ~15
    let first = try #require(r.events.firstIndex(of: "buffer 0 \(place) 8"))
    #expect(r.times[first] == 85 * song + 1165 + 300)
    #expect(r.events[first + 1] == "period 0 428")
    #expect(r.events[first + 2] == "volume 0 48")
    #expect(r.events[first + 3] == "on 0")
    #expect(r.times[first + 3] == r.times[first] + 2570)
    // The row is read, and the voice turned off, a tick before.
    let read = try #require(r.events.firstIndex(of: "off 0"))
    #expect(r.times[read] == 84 * song + 1165 + 200)
    // The song: position nought's rows to its end, then its loop again.
    #expect(p.lengthClocks == 165 * song + 1165)
}

@Test func thomasHermannSampleOnceIsStoppedByItsInterrupts() throws {
    var p = try ThomasHermannPlayer(module(), samples: sound)
    let song: UInt64 = 81925
    let r = run(&p, until: 87 * song)
    let on = try #require(r.events.firstIndex(of: "on 0"))
    let start = r.times[on]
    // Its first note: its start's interrupt and the one at its first end are counted, and at its second end
    // it is stopped (8 words, at period 428, a byte later).
    let stop = try #require(r.events.indices.first { $0 > on && r.events[$0] == "off 0" })
    #expect(r.times[stop] == start + 2 * 16 * 428 + 428)
}

@Test func thomasHermannLoopIsGivenAtItsSecondInterrupt() throws {
    var p = try ThomasHermannPlayer(module(mode: 1), samples: sound)
    let song: UInt64 = 81925
    let r = run(&p, until: 87 * song)
    let on = try #require(r.events.firstIndex(of: "on 0"))
    let place = (6912 + 15) & ~15
    // Not stopped; given its loop (from its eighth byte, four words) once it has been played once.
    let loop = try #require(r.events.indices.first { $0 > on && r.events[$0] == "buffer 0 \(place + 8) 4" })
    #expect(r.times[loop] == r.times[on] + 16 * 428 + 428)
    #expect(!r.events[on...].contains("off 0"))
}

@Test func thomasHermannOwnPeriodAndOctaves() throws {
    // $CF: the sample at its own period.
    var own = try ThomasHermannPlayer(module(note: 0xCF), samples: sound)
    #expect(run(&own, until: 86 * 81925 + 4000).events.contains("period 0 214"))
    // Octave 2 halves the period, 0 doubles it, 15 four times it; and a transposition moves the semitone.
    var high = try ThomasHermannPlayer(module(note: 0x12), samples: sound)
    #expect(run(&high, until: 86 * 81925 + 4000).events.contains("period 0 202"))
    var low = try ThomasHermannPlayer(module(note: 0x00), samples: sound)
    #expect(run(&low, until: 86 * 81925 + 4000).events.contains("period 0 856"))
    var lowest = try ThomasHermannPlayer(module(note: 0x0F), samples: sound)
    #expect(run(&lowest, until: 86 * 81925 + 4000).events.contains("period 0 1712"))
}

@Test func thomasHermannSlides() throws {
    // Effect 1: the period is not written with the note, but slid to by the sample's speed, 4 each effects' tick.
    var p = try ThomasHermannPlayer(module(note: 0x01, effect: 1), samples: sound)
    let r = run(&p, until: 90 * 81925)
    let slides = r.events.filter { $0.hasPrefix("period 0") }
    #expect(slides.first == "period 0 4")
    #expect(slides.contains("period 0 8"))
    // Each frame, as the game ran them (Wanted Team's timer would run them some 26 times a second).
    let times = r.events.indices.filter { r.events[$0].hasPrefix("period 0") }.map { r.times[$0] }
    #expect(times[1] - times[0] == 71051)
    var wt = try ThomasHermannPlayer(module(note: 0x01, effect: 1), samples: sound, wantedTeamsTimer: true)
    let w = run(&wt, until: 90 * 81925)
    let wtimes = w.events.indices.filter { w.events[$0].hasPrefix("period 0") }.map { w.times[$0] }
    #expect(wtimes[1] - wtimes[0] == 137_240)
}

@Test func thomasHermannSongsByItsSize() throws {
    let blue = try ThomasHermannPlayer(module(size: 11792, furthest: 11728), samples: sound)
    #expect(blue.songCount == 5)
    let kramer = try ThomasHermannPlayer(module(size: 10112, furthest: 10048), samples: sound)
    #expect(kramer.songCount == 3)
    #expect(throws: TuneError.self) { try ThomasHermannPlayer(module(size: 7000, furthest: 6990), samples: sound) }
}

@Test func thomasHermannInstrumentsFromItsFolder() throws {
    // The record's name, after its colon, matched without regard to case; an 8SVX file's sound from its 104th byte.
    let form = Array("FORM".utf8) + [UInt8](repeating: 7, count: 100) + sound
    var p = try ThomasHermannPlayer(module(), instruments: [("SNARE", form)])
    #expect(p.missingInstruments.isEmpty)
    let place = (6912 + 15) & ~15 + 104
    #expect(run(&p, until: 86 * 81925 + 4000).events.contains("buffer 0 \(place) 8"))
    let missing = try ThomasHermannPlayer(module(), instruments: [("Snare", sound), ("Other", sound)])
    #expect(missing.missingInstruments.isEmpty)
    #expect(throws: TuneError.self) { try ThomasHermannPlayer(module()) }
}

@Test func thomasHermannNeverTrapsOnBrokenModules() {
    let m = module()
    for cut in stride(from: 0, to: m.count, by: 97) { _ = try? ThomasHermannPlayer(Array(m[0 ..< cut]), samples: sound) }
    var g = SystemRandomNumberGenerator()
    for _ in 0 ..< 40 {
        var c = m
        for _ in 0 ..< 12 { c[Int.random(in: 0 ..< c.count, using: &g)] = UInt8.random(in: 0 ... 255, using: &g) }
        if var p = try? ThomasHermannPlayer(c, samples: sound) { _ = run(&p, until: 200 * 81925) }
    }
}
