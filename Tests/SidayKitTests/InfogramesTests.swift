// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Infogrames' player, on a tiny score and sample file made here. The thorough check is made
// outside the package: what it tells Paula, tick by tick, against what the DeliTracker module's player
// tells her in UADE, for every one of UnExoticA's scores.

/// What Paula is told, as a list (the moments in the tick left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    var moments: [Int] = []
    var at = 0
    mutating func on(_ voice: Int) { events.append("on \(voice)"); moments.append(at) }
    mutating func off(_ voice: Int) { events.append("off \(voice)"); moments.append(at) }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) {
        events.append("buffer \(voice) \(start) \(length)")
        moments.append(at)
    }

    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func timed(at clocks: Int) { at = clocks }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

/// A score of one song at tempo 2: voice 0's sequence plays pattern 0 (three rows a note: sample 0 and the
/// volume envelope 0, note 24; then sample 1, note 36), the other voices' sequences are empty. The volume
/// envelope rises by 4 a tick fifteen times and then holds.
private func score(pattern: [UInt8] = [0x81, 0xA0, 0xC0, 24, 0xA1, 36, 0xFF], sequence: [UInt8] = [0, 0xFF]) -> [UInt8] {
    let base = 2
    let envelopes = 22, periodEnvelopes = 35, sequences = 48
    let empty = sequences + sequence.count
    let patternAt = empty + 1
    var bytes = word(2)
    bytes += word(2) + word(envelopes - base) + word(periodEnvelopes - base)
    bytes += word(sequences - base) + word(empty - base) + word(empty - base) + word(empty - base) + word(0)
    bytes += word(patternAt - base) + word(patternAt - base)
    bytes += [0, 15, 4, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1]
    bytes += [0, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1]
    bytes += sequence + [0xFF] + pattern
    return bytes
}

/// A sample file of two samples: the first of eight words with a loop of four after it, the second of four
/// that goes round itself.
private func samples() -> [UInt8] {
    var bytes = long(128)
    bytes += long(32) + long(48) + long(0) + word(8) + word(4)
    bytes += long(64) + long(64) + long(0) + word(4) + word(4)
    while bytes.count < 4 + 128 { bytes.append(UInt8(truncatingIfNeeded: bytes.count * 7)) }
    return bytes
}

@Test func infogramesDetection() {
    let made = score()
    #expect(InfogramesPlayer.isOne(made))
    var odd = made
    odd[1] = 3
    #expect(!InfogramesPlayer.isOne(odd))
    var none = made
    none[1] = 0
    #expect(!InfogramesPlayer.isOne(none))
    var envelope = made
    envelope[23] = 14
    #expect(!InfogramesPlayer.isOne(envelope))
    #expect(!InfogramesPlayer.isOne(Array(made.prefix(3))))
    #expect(throws: TuneError.self) { _ = try InfogramesPlayer(envelope, samples: samples()) }
    #expect(throws: TuneError.self) { _ = try InfogramesPlayer(made, samples: []) }
}

/// A note's sample is started at once, as the voice is played: told Paula, turned off and on after a wait
/// of ten lines, and its loop told after another; its period the note's, its volume the envelope's.
@Test func infogramesNoteReachesPaula() throws {
    var player = try InfogramesPlayer(score(), samples: samples())
    #expect(player.tickClocks == 33285)
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == ["buffer 0 36 8", "off 0", "on 0", "buffer 0 52 4"])
    #expect(first.moments[2] - first.moments[1] >= 9 * 227)
    #expect(first.moments[3] - first.moments[2] >= 9 * 227)
    #expect(player.periodWritten(0) == 0x1ABC)
    #expect(player.volumeWritten(0) == 4)
    #expect(player.volumeWritten(1) == 0 && player.periodWritten(1) == 0)
    // (What Paula is set to at a tick's start is what the tick before left her.)
    #expect(player.period(0) == 0)
    var ticks: [[String]] = [first.events]
    var volumes: [UInt16] = [player.volumeWritten(0)]
    for _ in 1 ..< 8 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        ticks.append(recorder.events)
        volumes.append(player.volumeWritten(0))
    }
    #expect(player.period(0) == 0x0D5B)
    // The first note lasts three rows of two ticks (the tempo), counted from the first row's end: the
    // second begins at tick 5.
    #expect(ticks[5] == ["buffer 0 68 4", "off 0", "on 0", "buffer 0 68 4"])
    #expect(ticks[1].isEmpty && ticks[4].isEmpty && ticks[6].isEmpty)
    // The envelope rises from each note's start.
    #expect(volumes == [4, 8, 12, 16, 20, 4, 8, 12])
}

/// The song stops once every voice has come to the end of its sequence, and is as long as that.
@Test func infogramesSongStops() throws {
    var player = try InfogramesPlayer(score(), samples: samples())
    #expect(player.lengthClocks == 11 * 33285)
    var none = TFMXSilentOutput()
    for _ in 0 ..< 11 { _ = player.run(&none) }
    #expect(player.stops == 0)
    _ = player.run(&none)
    #expect(player.stops == 1)
    #expect(player.volumeWritten(0) == 0)
}

/// A sequence of patterns that are empty, going on past the score's end, is not read for ever: the voice
/// is stopped; and a command the player has nowhere to go for stops it too.
@Test func infogramesEndlessReadsStop() throws {
    // (Voice 0's sequence at the score's end, past which the player reads nought: pattern 0, for ever.)
    var endless = score(pattern: [0xFF])
    endless.replaceSubrange(8 ..< 10, with: word(endless.count - 2))
    var player = try InfogramesPlayer(endless, samples: samples())
    var none = TFMXSilentOutput()
    _ = player.run(&none)
    #expect(player.stops == 1)
    var crash = try InfogramesPlayer(score(pattern: [0x81, 0xE4, 24, 0xFF]), samples: samples())
    _ = crash.run(&none)
    #expect(crash.stops == 1)
}
