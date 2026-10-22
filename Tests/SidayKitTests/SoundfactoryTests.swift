// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Soundfactory's player, on tiny modules made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what Wanted Team's EaglePlayer module tells her in UADE,
// for every song of UnExoticA's file.

/// What Paula is told, as a list, with the moments in the tick left out.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { events.append("period \(voice) \(period)") }
    mutating func writeVolume(_ voice: Int, _ volume: UInt16) { events.append("volume \(voice) \(volume)") }
    mutating func writeLightFilter(_ on: Bool) { events.append("filter \(on)") }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// An instrument, numbered `number`: a sample of 16 bytes tuned to period 428 in octave 2, with `flags`, no
/// attack or decay and a sustain of `sustain`, looped from its fourth word to its end if `looped`.
private func instrument(_ number: UInt8, flags: UInt8 = 0, sustain: UInt8 = 0x40, looped: Bool = false) -> [UInt8] {
    var i = [0x84, number] + word(27) + word(8) + word(428) + [flags] + [UInt8](repeating: 0, count: 11)
    i += [0, 0, sustain, 2] + [0, 0, 0, 0] + [1, 2] + [0, 0, 0, 0] + word(looped ? 4 : 0) + word(looped ? 8 : 0)
    return i + (0 ..< 16).map { UInt8($0 * 11 + 1) }
}

/// A module of one song (and a second of no voices): voice nought defines instrument nought, chooses it, plays
/// note 24 for four ticks, waits eight more and goes back to its start; `voice1`, if given, is voice one's
/// stream (the song then playing both).
private func module(voice0 extra: [UInt8] = [], voice1: [UInt8]? = nil, flags: UInt8 = 0) -> [UInt8] {
    let stream0 = instrument(0, flags: flags) + [0x83, 0] + extra + [24] + word(4) + [0x80] + word(8) + [0x8D]
    var m = long(0) + [voice1 == nil ? 1 : 3, 0] + [UInt8](repeating: 0, count: 14)
    let second = 276 + stream0.count
    for s in 0 ..< 16 {
        for v in 0 ..< 4 { m += long(s == 0 && v == 1 && voice1 != nil ? second : 276) }
    }
    m += stream0 + (voice1 ?? []) + [UInt8](repeating: 0, count: 8)
    m.replaceSubrange(0 ..< 4, with: long(m.count))
    return m
}

@Test func soundfactoryCheck() {
    let m = module()
    #expect(SoundfactoryPlayer.isOne(m))
    var mask = m
    mask[5] = 16
    #expect(!SoundfactoryPlayer.isOne(mask))
    var least = m
    least.replaceSubrange(20 ..< 24, with: long(278))
    for s in 0 ..< 64 { least.replaceSubrange(20 + 4 * s ..< 24 + 4 * s, with: long(278)) }
    #expect(!SoundfactoryPlayer.isOne(least))
    #expect(throws: TuneError.self) { try SoundfactoryPlayer(Array(m[0 ..< m.count - 1])) }
}

@Test func soundfactoryPlaysItsNote() throws {
    var p = try SoundfactoryPlayer(module())
    #expect(p.songCount == 1)
    #expect(p.instrumentCount == 1)
    var r = Recorder()
    _ = p.run(&r)
    #expect(r.events == ["off 0", "buffer 0 \(276 + 38) 8", "volume 0 64", "period 0 428", "on 0"])
    // A tick later its effects: nothing to loop, and its volume and period again.
    r = Recorder()
    _ = p.run(&r)
    #expect(r.events == ["volume 0 64", "period 0 428"])
    // It goes back to its start at its thirteenth tick, which is where the song ends.
    #expect(p.lengthClocks == 12 * UInt64(SoundfactoryPlayer.tickClocks))
    let filter = p.lightFilter
    #expect(filter)
}

@Test func soundfactoryOnceThenSilence() throws {
    // Played once (its first flag): two ticks after its note, Paula given silence to go on to.
    var p = try SoundfactoryPlayer(module(voice0: [0x91]))
    let silence = p.silenceAt
    var r = Recorder()
    _ = p.run(&r)
    _ = p.run(&r)
    r = Recorder()
    _ = p.run(&r)
    #expect(r.events.first == "buffer 0 \(silence) 1")
}

@Test func soundfactoryCommands() throws {
    // Its volume scaled, a semitone added by transposition, the filter off.
    var p = try SoundfactoryPlayer(module(voice0: [0x81, 0x80, 0x9C, 12, 0x9A, 0]))
    var r = Recorder()
    _ = p.run(&r)
    #expect(r.events.contains("volume 0 32"))
    #expect(r.events.contains("period 0 214"))
    #expect(r.events.contains("filter false"))
    let filter = p.lightFilter
    #expect(!filter)
}

@Test func soundfactoryVoicesOff() throws {
    // A voice that turns itself off says the song has ended; with every voice off it has stopped.
    let off = [UInt8]([36]) + word(2) + [0x8E]
    var p = try SoundfactoryPlayer(module(voice1: off))
    #expect(p.lengthClocks == 2 * UInt64(SoundfactoryPlayer.tickClocks))
    var r = Recorder()
    for _ in 0 ..< 3 { _ = p.run(&r) }
    #expect(p.endings == 1)
    #expect(p.stops == 0)
    #expect(r.events.contains("off 1"))
}

@Test func soundfactoryNeverTrapsOnBrokenModules() {
    let m = module(flags: 0x88)
    for cut in stride(from: 0, to: m.count, by: 7) { _ = try? SoundfactoryPlayer(Array(m[0 ..< cut])) }
    var g = SystemRandomNumberGenerator()
    for _ in 0 ..< 200 {
        var c = m
        for _ in 0 ..< 6 { c[Int.random(in: 276 ..< c.count, using: &g)] = UInt8.random(in: 0 ... 255, using: &g) }
        if var p = try? SoundfactoryPlayer(c) {
            var r = Recorder()
            for _ in 0 ..< 400 { _ = p.run(&r) }
        }
    }
}
