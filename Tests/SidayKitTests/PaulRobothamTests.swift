// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Paul Robotham's player, on tiny scores made here as the games' are. The thorough check is made
// outside the package: what it tells Paula, tick by tick, against what Wanted Team's player tells her in UADE, for
// UnExoticA's nineteen scores.

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

/// Where the parts are: the header (one voice, one vibrato, two envelopes, two samples), the first envelope (all
/// $3F), the second, the voice's events, and the vibrato after them (at the next even byte).
private let headerSize = 8 + 4 * 4 + 2 * 12
private let secondEnvelopeAt = headerSize + 256
private let eventsAt = secondEnvelopeAt + 256

/// A score of one voice playing `events`, at the tempo of 3,600 (a tick is three of a note's parts), at the volume
/// 63. Sample 0 is eight words with a loop of four from its eighth byte; sample 1 four words from its 16th byte,
/// with no loop. The second envelope is $10 at 3, $20 at 7, and back by eight at 11.
private func score(_ events: [UInt8]) -> [UInt8] {
    let vibratoAt = (eventsAt + 6 + events.count + 1) & ~1
    var bytes = word(1) + word(1) + word(2) + word(2)
    bytes += long(eventsAt) + long(vibratoAt) + long(headerSize) + long(secondEnvelopeAt)
    bytes += long(0) + word(8) + long(8) + word(4)
    bytes += long(16) + word(4) + long(0) + word(0)
    bytes += [UInt8](repeating: 0x3F, count: 256)
    var envelope = [UInt8](repeating: 0, count: 256)
    envelope[3] = 0x10
    envelope[7] = 0x20
    envelope[11] = 0xF8
    bytes += envelope
    bytes += [0x8D, 0x3F, 0x8E, 0xE1, 0x8F, 0x00] + events + (events.count % 2 == 0 ? [] : [0])
    bytes += [UInt8](repeating: 0, count: 256)
    return bytes
}

private let samples = (0 ..< 64).map { UInt8($0 * 3) }

@Test func paulRobothamDetection() throws {
    let made = score([13, 0x06, 0])
    #expect(PaulRobothamPlayer.isOne(made))
    var other = made
    other[headerSize + 100] = 0x3E
    #expect(!PaulRobothamPlayer.isOne(other))
    other = made
    other[1] = 5
    #expect(!PaulRobothamPlayer.isOne(other))
    other = made
    other[15] |= 1
    #expect(!PaulRobothamPlayer.isOne(other))
    #expect(!PaulRobothamPlayer.isOne(Array(made.prefix(headerSize + 200))))
    let player = try PaulRobothamPlayer(made, samples: samples)
    #expect(player.voiceCount == 1 && player.sampleCount == 2 && player.samplesNeeded == 24)
    #expect(throws: TuneError.self) { try PaulRobothamPlayer(made, samples: []) }
    #expect(throws: TuneError.self) { try PaulRobothamPlayer(made, samples: Array(samples.prefix(23))) }
}

/// A note is begun with its voice turned off and told its sample, turned on on the next tick and told its loop on
/// the one after; the voice reads its first event on the eleventh tick. Its volume is told once it is on.
@Test func paulRobothamNotesReachPaula() throws {
    var player = try PaulRobothamPlayer(score([13, 0x09, 0x8F, 0x01, 25, 0x09, 0]), samples: samples)
    let base = player.samplesAt
    var ticks: [[String]] = []
    var periods: [UInt16] = []
    var volumes: [UInt16] = []
    for _ in 0 ..< 18 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        ticks.append(recorder.events)
        periods.append(player.period(0))
        volumes.append(player.volume(0))
    }
    #expect(ticks[0 ..< 10].allSatisfy(\.isEmpty) && periods[9] == 0)
    #expect(ticks[10] == ["off 0", "buffer 0 \(base) 8"])
    #expect(ticks[11] == ["on 0"])
    #expect(ticks[12] == ["buffer 0 \(base + 8) 4"])
    #expect(ticks[13] == ["off 0", "buffer 0 \(base + 16) 4"])
    #expect(ticks[14] == ["on 0"])
    #expect(ticks[15] == ["buffer 0 \(player.silenceAt) 8"])
    #expect(ticks[16] == ["off 0"] && ticks[17].isEmpty)
    #expect(periods[10 ... 15] == [0x194, 0x194, 0x194, 0x0CA, 0x0CA, 0x0CA])
    #expect(volumes[11] == 63 && volumes[12] == 63 && volumes[13] == 63)
    // (The song stops as its one voice comes to its end, on the seventeenth tick.)
    #expect(player.stops == 1 && player.endings == 1)
    #expect(player.lengthClocks == UInt64(16 * TFMXTiming.fiftyTimes))
}

/// The envelope gives a volume every fourth byte, and a negative one takes it back.
@Test func paulRobothamEnvelope() throws {
    var player = try PaulRobothamPlayer(score([0x8C, 0x01, 13, 0x7F, 0]), samples: samples)
    var none = TFMXSilentOutput()
    var volumes: [UInt16] = []
    for _ in 0 ..< 16 {
        _ = player.run(&none)
        volumes.append(player.volume(0))
    }
    #expect(Array(volumes[11 ..< 16]) == [32, 16, 32, 16, 32])
}

/// The song goes round, and is said to each time, at its first voice's outermost loop of 255 times; Wanted Team's
/// player begins it again as its first voice reads its last note (here, as its last event is the byte before the
/// vibrato: after a command that does nothing, $80).
@Test func paulRobothamSongEnds() throws {
    var round = try PaulRobothamPlayer(score([0x81, 0xFF, 13, 0x06, 0x82, 0]), samples: samples)
    #expect(round.lengthClocks == UInt64(12 * TFMXTiming.fiftyTimes))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 12 { _ = round.run(&none) }
    #expect(round.endings == 0)
    _ = round.run(&none)
    #expect(round.endings == 1 && round.stops == 0)
    for _ in 0 ..< 2 { _ = round.run(&none) }
    #expect(round.endings == 2)

    // (Fewer times round is played out.)
    let few = try PaulRobothamPlayer(score([0x81, 0x02, 13, 0x06, 0x82, 0]), samples: samples)
    #expect(few.lengthClocks == UInt64(14 * TFMXTiming.fiftyTimes))

    var wanted = try PaulRobothamPlayer(score([0x80, 13, 0x09, 25, 0x09, 0]), samples: samples, wantedTeamsEnd: true)
    #expect(wanted.lengthClocks == UInt64(13 * TFMXTiming.fiftyTimes))
    for _ in 0 ..< 13 { _ = wanted.run(&none) }
    #expect(wanted.endings == 0)
    _ = wanted.run(&none)
    #expect(wanted.endings == 1 && wanted.stops == 0)
    let original = try PaulRobothamPlayer(score([0x80, 13, 0x09, 25, 0x09, 0]), samples: samples)
    #expect(original.lengthClocks == UInt64(16 * TFMXTiming.fiftyTimes))
}
