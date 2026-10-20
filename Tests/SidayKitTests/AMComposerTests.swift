// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of A.M.Composer's player, on a tiny module made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what Wanted Team's player tells her in UADE, for
// every one of UnExoticA's modules.

/// What Paula is told, as a list (the moments in the tick left out).
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
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

private func put(_ bytes: inout [UInt8], _ at: Int, _ values: [UInt8]) {
    for (i, value) in values.enumerated() { bytes[at + i] = value }
}

/// Where the lists and the sample are in the module below.
private let notesAt = 0x58
private let effectsAt = notesAt + 12
private let endAt = effectsAt + 24
private let sampleAt = endAt + 2

/// A module of one sample (16 bytes, going on to the header's four bytes of nought at 60), a song of three
/// rows at a timer of $40; voice 0's notes, a note at row 1, and its effects, a command at row 2, given as
/// its bytes; every other list at the song's end.
private func module(effect: [UInt8]) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: sampleAt + 16)
    put(&bytes, 0, Array("AMC V1.2 REPLAY!".utf8))
    put(&bytes, 0x10, word(3))
    put(&bytes, 0x14, long(sampleAt))
    let lists = [notesAt, endAt, endAt, endAt, effectsAt, endAt, endAt, endAt]
    for (i, at) in lists.enumerated() { put(&bytes, 0x18 + 4 * i, long(at)) }
    bytes[0x39] = 0x40
    put(&bytes, 0x48, long(sampleAt) + word(8) + long(60) + word(2))
    put(&bytes, notesAt, word(1) + [1, 48] + word(428) + word(3))
    put(&bytes, effectsAt, word(2) + effect)
    put(&bytes, endAt, word(3))
    for i in 0 ..< 16 { bytes[sampleAt + i] = UInt8(truncatingIfNeeded: i * 9 + 1) }
    return bytes
}

private let slide: [UInt8] = [2, 1] + word(2) + word(4) + word(400)

@Test func amComposerDetection() throws {
    let made = module(effect: slide)
    #expect(AMComposerPlayer.isOne(made))
    var other = made
    other[13] = 0x31
    #expect(!AMComposerPlayer.isOne(other))
    var far = made
    far[24] = 1
    #expect(!AMComposerPlayer.isOne(far))
    let player = try AMComposerPlayer(made)
    #expect(player.sampleCount == 1)
    #expect(player.tickClocks == (0x4000 + 1) * 5)
    // Its sample past its end, it is refused, as the player refuses it; and so is one whose table of
    // samples does not end where its first list begins.
    #expect(throws: TuneError.self) { _ = try AMComposerPlayer(Array(made.prefix(sampleAt + 8))) }
    var odd = made
    put(&odd, 0x18, long(notesAt + 2))
    #expect(throws: TuneError.self) { _ = try AMComposerPlayer(odd) }
}

/// The first row is at the fourth tick: the note's voice turned off, told its sample, volume and period;
/// at the next tick turned on and told what it goes on to.
@Test func amComposerNoteReachesPaula() throws {
    var player = try AMComposerPlayer(module(effect: slide))
    var ticks: [[String]] = []
    for _ in 0 ..< 5 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        ticks.append(recorder.events)
    }
    #expect(ticks[0].isEmpty && ticks[1].isEmpty && ticks[2].isEmpty)
    #expect(ticks[3] == ["off 0", "buffer 0 \(sampleAt) 8", "volume 0 48", "period 0 428"])
    #expect(ticks[4] == ["on 0", "buffer 0 60 2"])
}

/// A slide: from its period, its step taken off every so many ticks, for as many ticks as it lasts less
/// one; and the song's end at its end row, after which it goes round.
@Test func amComposerSlideAndEnd() throws {
    var player = try AMComposerPlayer(module(effect: slide))
    #expect(player.lengthClocks == UInt64(3 * 4 * player.tickClocks))
    var periods: [UInt16] = []
    var none = TFMXSilentOutput()
    for _ in 0 ..< 8 { _ = player.run(&none) }
    for _ in 0 ..< 4 {
        _ = player.run(&none)
        periods.append(player.periodWritten(0))
    }
    #expect(periods == [398, 396, 394, 394])
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1)
}

/// The eight periods, a tick each from the second, for so many ticks; and the filter.
@Test func amComposerPeriodsAndFilter() throws {
    var player = try AMComposerPlayer(module(effect: [4, 3] + [100, 200, 300, 400, 500, 600, 700, 800].flatMap { word($0) }))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 8 { _ = player.run(&none) }
    var periods: [UInt16] = []
    for _ in 0 ..< 4 {
        _ = player.run(&none)
        periods.append(player.periodWritten(0))
    }
    #expect(periods == [200, 300, 400, 400])
    var filtered = try AMComposerPlayer(module(effect: [7, 1]))
    var events: [String] = []
    for _ in 0 ..< 8 {
        var recorder = Recorder()
        _ = filtered.run(&recorder)
        events += recorder.events
    }
    #expect(events.last == "filter true")
    _ = filtered.run(&none)
    let on = filtered.lightFilter
    #expect(on)
}
