// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Scott Johnston's SoundPlayer, on tiny scores and sample files made here as Lemmings' are. The
// thorough check is made outside the package: what it tells Paula, tick by tick, against what Wanted Team's player
// tells her in UADE, for UnExoticA's 34 scores.

/// What Paula is told, as a list (the periods and volumes left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func long(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

/// A score of three voices at Tim Wright's timer (14,500), its first row setting the three voices' volumes to 63;
/// on its second, voice 0 plays note 13 (period 508) of instrument 1 and voice 1 is faded down a step a tick; on its
/// third, every voice's track ends.
private func score() -> [UInt8] {
    [0xA4, 0x38, 0x07] + [0, 0, 0x42, 0, 0, 0x42, 0, 0, 0x42, 0, 0, 0]
        + [13, 1, 0, 0, 0, 0xB1, 0, 0, 0, 0, 0, 0]
        + [0, 0, 0xDE, 0, 0, 0xDE, 0, 0, 0xDE, 0, 0, 0xDE]
}

/// The sample file: one IFF 8SVX instrument of sixteen bytes, eight played first and eight looped (its sound from
/// byte 48, its loop from 56).
private func sampleFile() -> [UInt8] {
    var header = Array("VHDR".utf8) + long(20) + long(8) + long(8) + long(0)
    header += [0x20, 0xAB, 1, 0] + long(0x10000)
    let body = Array("BODY".utf8) + long(16) + (0 ..< 16).map { UInt8($0 * 7 + 1) }
    let form = Array("8SVX".utf8) + header + body
    return Array("FORM".utf8) + long(form.count) + form
}

@Test func sjsDetection() throws {
    let made = score()
    #expect(SJSPlayer.isOne(made))
    var other = made
    other[2] = 8
    #expect(!SJSPlayer.isOne(other))
    other = made
    other[1] = 0x0A
    #expect(!SJSPlayer.isOne(other))
    other = made
    other[8] = 0x41
    #expect(!SJSPlayer.isOne(other))
    // (Four voices: the fourth's first command must be the same too.)
    other = made
    other[2] = 15
    #expect(!SJSPlayer.isOne(other))
    other[14] = 0x42
    #expect(SJSPlayer.isOne(other))
    #expect(!SJSPlayer.isOne(Array(made.prefix(14))))
    let player = try SJSPlayer(made, samples: sampleFile())
    #expect(player.sampleCount == 1 && player.voiceCount == 3 && player.tickClocks == 72505)
    #expect(player.tuneInfo.format == "SoundPlayer")
    #expect(throws: TuneError.self) { try SJSPlayer(made, samples: []) }
    #expect(throws: TuneError.self) { try SJSPlayer(other.map { $0 ^ 0x5A }, samples: sampleFile()) }
}

/// The voices are pointed at silence as the song begins, and every tick each is told its loop (silence, without
/// one). A note is begun on its row's tick (the twelfth: rows come every sixth), its voice turned off; on the tick
/// after, its sound is told, after its loop, and the voice turned on.
@Test func sjsNoteReachesPaula() throws {
    var player = try SJSPlayer(score(), samples: sampleFile())
    let silence = player.silenceAt
    let quiet = (0 ..< 4).map { "buffer \($0) \(silence) 1" }
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == (0 ..< 4).flatMap { ["off \($0)", "buffer \($0) \(silence) 1"] } + quiet)
    for _ in 2 ... 6 {
        var none = TFMXSilentOutput()
        _ = player.run(&none)
    }
    #expect(player.volumeWritten(0) == 63 && player.volumeWritten(2) == 63)
    for _ in 7 ... 11 {
        var none = TFMXSilentOutput()
        _ = player.run(&none)
    }
    var twelfth = Recorder()
    _ = player.run(&twelfth)
    #expect(twelfth.events == quiet + ["off 0"])
    var thirteenth = Recorder()
    _ = player.run(&thirteenth)
    #expect(thirteenth.events == ["buffer 0 56 4"] + quiet.dropFirst() + ["buffer 0 48 4", "on 0"])
    #expect(player.periodWritten(0) == 508 && player.volumeWritten(0) == 63)
}

/// A fade moves the volume a step every so many ticks, and Scott Johnston's player tells Paula every step; Wanted
/// Team's tells her nothing until a note is begun.
@Test func sjsFades() throws {
    var original = try SJSPlayer(score(), samples: sampleFile())
    var wanted = try SJSPlayer(score(), samples: sampleFile(), wantedTeamsFades: true)
    var none = TFMXSilentOutput()
    for _ in 1 ... 15 {
        _ = original.run(&none)
        _ = wanted.run(&none)
    }
    #expect(original.volumeWritten(1) == 60)
    #expect(wanted.volumeWritten(1) == 63)
}

/// The song comes to its end as its tracks do, on the eighteenth tick, which is as its beginning was: its next row is
/// read six ticks later.
@Test func sjsSongEnds() throws {
    var player = try SJSPlayer(score(), samples: sampleFile())
    #expect(player.lengthClocks == UInt64(18 * 72505))
    var none = TFMXSilentOutput()
    for _ in 1 ..< 18 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1)
    // (It plays on through Paula's renderer.)
    let renderer = try PaulaTickRenderer(SJSPlayer(score(), samples: sampleFile()), options: LoadOptions())
    #expect(renderer.subsongCount == 1)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 4800)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 4800)
}
