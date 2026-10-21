// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Paul Summers's player, on tiny files made here as the games' are. The thorough check is made outside
// the package: what it tells Paula, tick by tick, against what Wanted Team's player tells her in UADE, for every song
// of UnExoticA's files.

/// What Paula is told, as a list (the periods and volumes left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

/// Where the parts are: the songs, the samples' table (which only marks the songs' end), the instruments, the
/// periods (the note nought's), the streams and the sample.
private let songsAt = 0x380
private let samplesAt = songsAt + 3 * 20
private let instrumentsAt = 0x500
private let periodsAt = 0x600
private let sampleAt = 0x800

/// A driver of two songs, found as the player finds its parts. Song 1 (its first, the player's 1) has a timer of
/// $2000: voice 0 plays the sample (eight words, of note 12) at note 13 for three ticks, at volume 48, and note 12 for
/// two, and jumps back; voice 1 rests for four ticks and comes to its end. Song 2 has the player's timer and a
/// change of its tempo of `tempo`: its voice 0 plays note 13 for two ticks and comes to its end.
private func file(tempo: UInt8 = 0) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x1000)
    func put(_ at: Int, _ values: [UInt8]) { for (i, b) in values.enumerated() { bytes[at + i] = b } }
    func word(_ at: Int, _ value: Int) { put(at, [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
    func long(_ at: Int, _ value: Int) { word(at, value >> 16 & 0xFFFF); word(at + 2, value & 0xFFFF) }
    // The driver's `Init`, as the check finds it: a `LEA`, four `MOVE.B #$88,d(A0)`, and a `LEA` of the start.
    word(650, 0x41FA)
    for i in 0 ..< 4 { put(654 + 6 * i, [0x11, 0x7C, 0x00, 0x88, 0x00, UInt8(10 + 32 * i)]) }
    word(678, 0x41FA)
    word(680, -680 & 0xFFFF)
    // The `LEA`s of the samples' table, the songs (after `MULU #20,D0`) and the periods (after `NEG.L D0`).
    word(682, 0x45FA)
    word(684, samplesAt - 684)
    word(686, 0xC0FC)
    word(688, 20)
    word(690, 0x43FA)
    word(692, songsAt - 692)
    word(694, 0x4480)
    word(696, 0x41FA)
    word(698, periodsAt - 698)
    // The periods: of notes -2 to 12, from the note nought down.
    let periods = [0x1FC, 0x1E0, 0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D, 0xFE, 0xF0, 0xE2, 0xD6]
    for (i, period) in periods.enumerated() { long(periodsAt + 8 - 4 * i, period << 16) }
    // Song 1, and song 2.
    long(songsAt + 20, 0x700 - songsAt)
    long(songsAt + 24, 0x740 - songsAt)
    long(songsAt + 36, 0x2000)
    long(songsAt + 40, 0x780 - songsAt)
    put(songsAt + 56, [tempo, 0, 0, 0])
    // The instruments: one, its sample of note 12, for notes nought to $7F.
    word(instrumentsAt, 1)
    long(instrumentsAt + 2, sampleAt - (instrumentsAt + 2))
    long(instrumentsAt + 6, 8)
    word(instrumentsAt + 10, 12)
    word(instrumentsAt + 12, 0)
    word(instrumentsAt + 14, 0x7F)
    for i in 0 ..< 16 { bytes[sampleAt + i] = UInt8(i * 8) }
    // The streams.
    put(0x700, [0x86])
    long(0x701, instrumentsAt - 0x701)
    put(0x705, [0x8E, 48, 13, 3, 12, 2, 0x81])
    long(0x70C, 0x707 - 0x70C)
    put(0x740, [0x80, 4, 0x8F])
    put(0x780, [0x86])
    long(0x781, instrumentsAt - 0x781)
    put(0x785, [13, 2, 0x8F])
    return bytes
}

@Test func paulSummersDetection() throws {
    let bytes = file()
    #expect(PaulSummersPlayer.isOne(bytes))
    var other = bytes
    other[681] = 2
    #expect(!PaulSummersPlayer.isOne(other))
    let player = try PaulSummersPlayer(bytes)
    #expect(player.songCount == 2 && player.songsAt == songsAt && player.samplesAt == samplesAt && player.periodsAt == periodsAt)
    #expect(player.tickClocks == (0x2000 + 1) * 5)
    var asked = try PaulSummersPlayer(bytes)
    #expect(throws: TuneError.self) { try asked.select(song: 2) }
}

/// The song is begun on the first tick, its voices turned off and their volumes nought; a note is told Paula with
/// its instrument's sample and turned on, and silence after it; a voice with no place in the song is turned off.
/// A note's voice is turned off as its length ends.
@Test func paulSummersNotesReachPaula() throws {
    var player = try PaulSummersPlayer(file())
    var first = Recorder()
    _ = player.run(&first)
    let begun = ["off 0", "off 1", "off 2", "off 3", "off 0", "off 1", "off 2", "off 3"]
    #expect(first.events == begun + [
        "off 0", "buffer 0 \(sampleAt) 8", "on 0", "buffer 0 \(player.silenceAt) 1", "off 1", "off 1", "off 2", "off 3",
    ])
    #expect(player.periodWritten(0) == 0x194 && player.volumeWritten(0) == 48)
    var events: [[String]] = []
    for _ in 0 ..< 3 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        events.append(recorder.events)
    }
    #expect(events == [[], ["off 0"], ["off 0", "buffer 0 \(sampleAt) 8", "on 0", "buffer 0 \(player.silenceAt) 1", "off 1"]])
    #expect(player.periodWritten(0) == 0x1AC)
}

/// The song comes to its end when every voice has come to its end or jumped back: voice 0 jumps back on its sixth
/// tick, after voice 1 has come to its end on its fifth. One whose voices all come to their ends stops there.
@Test func paulSummersSongEnds() throws {
    var player = try PaulSummersPlayer(file())
    #expect(player.lengthClocks == UInt64(5 * (0x2000 + 1) * 5))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 5 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1 && player.stops == 0)

    var stopping = try PaulSummersPlayer(file(), song: 1)
    #expect(stopping.lengthClocks == UInt64(2 * TFMXTiming.fiftyTimes))
    for _ in 0 ..< 2 { _ = stopping.run(&none) }
    #expect(stopping.stops == 0)
    _ = stopping.run(&none)
    #expect(stopping.stops == 1)
}

/// A song whose tempo's change is from $80 has no tick left out, as the games' drivers have it; Wanted Team's
/// player leaves out one in every so many (here every other).
@Test func paulSummersTempo() throws {
    var player = try PaulSummersPlayer(file(tempo: 0xFF), song: 1)
    #expect(player.lengthClocks == UInt64(2 * TFMXTiming.fiftyTimes))
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events.contains("on 0"))
    var wanted = try PaulSummersPlayer(file(tempo: 0xFF), song: 1, wantedTeamsWay: true)
    #expect(wanted.lengthClocks == UInt64(5 * TFMXTiming.fiftyTimes))
    var left = Recorder()
    _ = wanted.run(&left)
    #expect(left.events.isEmpty)
    var next = Recorder()
    _ = wanted.run(&next)
    #expect(next.events.contains("on 0"))
}
