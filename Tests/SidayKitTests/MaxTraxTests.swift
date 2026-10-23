// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the MaxTrax driver, on tiny files made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against ScummVM's MaxTrax player with each of its
// departures from the driver put back as the driver's source has it, for every score of every one of
// UnExoticA's files.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

private typealias Event = (command: Int, data: Int, start: Int, stop: Int)
private typealias Instrument = (number: Int, octaves: Int, attack: Int, sustain: Int, attackSteps: [(Int, Int)], releaseSteps: [(Int, Int)])

/// A note: `note` on `channel` at full volume, `start` after the event before it, lasting `length`.
private func note(_ note: Int, channel: Int = 0, start: Int = 0, length: Int = 192) -> Event {
    (note, 0xF0 | channel, start, length)
}

private let plain: Instrument = (0, 1, 8, 16, [(0, 0x8000)], [(40, 0)])

/// A MaxTrax file of the given tempo, flags, scores and instruments (each followed by its samples,
/// counting up), or of scores alone if `instruments` is empty.
private func mxtx(tempo: Int = 120, flags: Int = 0, scores: [[Event]], instruments: [Instrument] = [plain]) -> [UInt8] {
    var bytes = Array("MXTX".utf8) + word(tempo) + word(flags) + word(scores.count)
    for score in scores {
        bytes += long(score.count)
        for e in score { bytes += [UInt8(e.command), UInt8(e.data)] + word(e.start) + word(e.stop) }
    }
    bytes += word(instruments.count)
    for i in instruments {
        bytes += word(i.number) + word(0) + word(0x8000) + word(i.octaves) + long(i.attack) + long(i.sustain)
        bytes += word(i.attackSteps.count) + word(i.releaseSteps.count)
        for (duration, volume) in i.attackSteps + i.releaseSteps { bytes += word(duration) + word(volume) }
        for octave in 0 ..< i.octaves {
            for b in 0 ..< (i.attack + i.sustain) << octave { bytes.append(UInt8(truncatingIfNeeded: b * 7 + 1)) }
        }
    }
    return bytes
}

/// Where the first instrument's samples begin in a file made by `mxtx`.
private func samplesAt(_ scores: [[Event]], steps: Int = 2) -> Int {
    10 + scores.reduce(0) { $0 + 4 + 6 * $1.count } + 2 + 20 + 4 * steps
}

@Test func maxTraxDetection() throws {
    let file = mxtx(scores: [[note(45), (0xFF, 0, 192, 0)]])
    #expect(MaxTraxPlayer.isOne(file))
    #expect(!MaxTraxPlayer.isOne(Array("MXTY".utf8) + Array(file.dropFirst(4))))
    #expect(!MaxTraxPlayer.needsInstruments(file))
    _ = try MaxTraxPlayer(file)
    // Cut short anywhere, it is refused.
    for cut in [6, 9, 20, file.count - 1] {
        #expect(throws: TuneError.self) { _ = try MaxTraxPlayer(Array(file.prefix(cut))) }
    }
    // Instruments and no score; and a score whose instruments are in another file.
    #expect(throws: TuneError.self) { _ = try MaxTraxPlayer(mxtx(scores: [])) }
    let scoreAlone = mxtx(scores: [[note(45), (0xFF, 0, 192, 0)]], instruments: [])
    #expect(MaxTraxPlayer.needsInstruments(scoreAlone))
    do {
        _ = try MaxTraxPlayer(scoreAlone)
        Issue.record("a score without its instruments was taken")
    } catch let error {
        guard case .missingCompanion = error else {
            Issue.record("refused for another reason: \(error)")
            return
        }
    }
    let bank = mxtx(scores: [])
    let paired = try MaxTraxPlayer(scoreAlone, instruments: bank)
    #expect(paired.songCount == 1)
    #expect(paired.silenceAt == bank.count)
    // An instrument numbered past the 64 the driver has room for.
    var high = plain
    high.number = 64
    #expect(throws: TuneError.self) { _ = try MaxTraxPlayer(mxtx(scores: [[note(45)]], instruments: [high])) }
}

/// A note is started at once on a free voice of its channel's side: its attack written, and its
/// sustain after it, at the period of its pitch and a volume of nought, which its envelope then sets
/// in the same tick. MIDI's note 45 untuned is a period of 1017.
@Test func maxTraxNoteReachesPaula() throws {
    let score: [Event] = [note(45), (0xFF, 0, 400, 0)]
    var player = try MaxTraxPlayer(mxtx(scores: [score]))
    var recorder = Recorder()
    _ = player.run(&recorder)
    let at = samplesAt([score])
    // Channel nought is on the left, whose two voices are the first and the last; of two free, the
    // driver takes the one it did not take last, the last voice first.
    #expect(recorder.events == ["buffer 3 \(at) 4", "on 3", "buffer 3 \(at + 8) 8"])
    #expect(player.period(3) == 1017)
    #expect(player.volume(3) == 64)
    #expect(MaxTraxPlayer.intAlg(0x90000) == 512)
}

/// Notes on the same side go to its two voices in turn, and the odd channels are on the right. (Each
/// channel begins on the instrument of its own number: channel 1 is given the file's one.)
@Test func maxTraxVoicesInTurn() throws {
    let score: [Event] = [(0xC0, 1, 0, 0), note(45), note(47), note(49, channel: 1), note(50, channel: 1), (0xFF, 0, 400, 0)]
    var player = try MaxTraxPlayer(mxtx(scores: [score]))
    var recorder = Recorder()
    _ = player.run(&recorder)
    let started = recorder.events.filter { $0.hasPrefix("on") }
    #expect(started == ["on 3", "on 0", "on 2", "on 1"])
}

/// A note ends when its length is up, and then its release envelope takes its volume down to
/// nothing; the voice is silenced the tick after.
@Test func maxTraxNoteEnds() throws {
    // At 120 beats a minute a tick is 1966/256 of the score's units: a note of 15 units ends in the
    // second tick, and its release of 40 ms takes two more.
    let score: [Event] = [note(45, length: 15), (0xFF, 0, 1000, 0)]
    var player = try MaxTraxPlayer(mxtx(scores: [score]))
    var recorder = Recorder()
    var volumes: [UInt16] = []
    for _ in 0 ..< 6 {
        _ = player.run(&recorder)
        volumes.append(player.volume(3))
    }
    #expect(volumes == [64, 64, 32, 0, 0, 0])
    #expect(recorder.events.contains("off 3"))
}

/// The tempo sets how fast the score's time goes by, and a score is as long as it plays to its end.
@Test func maxTraxTempoAndLength() throws {
    let score: [Event] = [note(45), (0xFF, 0, 192 * 4, 0)]
    let player = try MaxTraxPlayer(mxtx(tempo: 120, scores: [score, score]))
    #expect(player.songCount == 2)
    // Four beats at 120 a minute: two seconds of the driver's fiftieths, at 1966/256 units a tick.
    #expect(player.lengthClocks == UInt64((192 * 4 * 256 + 1965) / 1966) * UInt64(MaxTraxPlayer.tickClocks))
    var faster = try MaxTraxPlayer(mxtx(tempo: 120, scores: [[(0x80, 240, 0, 0)] + score]))
    var none = Recorder()
    _ = faster.run(&none)
    #expect(faster.global.tickUnit == 3932)
}

/// A note too high for its octave is played from the next octave down of its sample, if it has one:
/// twice as long, at half the period. (Note 56 is eleven semitones above 45: 1017 over 2^(11/12), halved.)
@Test func maxTraxOctaves() throws {
    var two = plain
    two.octaves = 2
    let score: [Event] = [note(56), (0xFF, 0, 400, 0)]
    var player = try MaxTraxPlayer(mxtx(scores: [score], instruments: [two]))
    var recorder = Recorder()
    _ = player.run(&recorder)
    let at = samplesAt([score]) + 24
    #expect(recorder.events == ["buffer 3 \(at) 8", "on 3", "buffer 3 \(at + 16) 16"])
    #expect(player.period(3) > 265 && player.period(3) < 274)
}

/// The file's first flag turns the Amiga's filter on, and its controller 81 turns it off.
@Test func maxTraxFilter() throws {
    let score: [Event] = [note(45), (0xB0, 0, 10, 81 << 8 | 0), (0xFF, 0, 400, 0)]
    var player = try MaxTraxPlayer(mxtx(flags: 1, scores: [score]))
    let before = player.lightFilter
    #expect(before)
    var recorder = Recorder()
    for _ in 0 ..< 3 { _ = player.run(&recorder) }
    let after = player.lightFilter
    #expect(!after)
    let unfiltered = try MaxTraxPlayer(mxtx(scores: [score])).lightFilter
    #expect(!unfiltered)
}
