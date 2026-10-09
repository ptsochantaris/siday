// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// How a tune's silences are taken: a pause is played, and an end is an end.

/// A tune that is a square wave during some stretches of time and silent between them.
private final class Tune: Renderer {
    let info = TuneInfo(format: "TEST")
    let knownLength: Double?
    let endsByLooping: Bool
    private(set) var loopCount = 0
    private let sounding: [ClosedRange<Double>]
    private var frame = 0
    /// It has one voice, which is as loud as it can be while it sounds.
    let channelCount = 1
    private var sounded = false

    /// - Parameters:
    ///   - sounding: when it sounds, in seconds.
    ///   - length: how long it is. One that goes round begins again there.
    init(sounding: [ClosedRange<Double>], length: Double?, goesRound: Bool = false) {
        self.sounding = sounding
        knownLength = length
        endsByLooping = goesRound
    }

    /// What it plays at a time since its start: where in the tune that is can be told from the value.
    static func sample(_ tune: Tune, _ frame: Int) -> Float {
        var at = frame
        if tune.endsByLooping, let length = tune.knownLength { at %= Int(length * 48000) }
        let seconds = Double(at) / 48000
        guard tune.sounding.contains(where: { $0.contains(seconds) }) else { return 0 }
        return (at / 60 % 2 == 0 ? 0.2 : -0.2) + Float(at % 48000) / 480_000
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0 ..< frames {
            let value = Self.sample(self, frame)
            buffer[i * 2] = value
            buffer[i * 2 + 1] = value
            if value != 0 { sounded = true }
            frame += 1
            if endsByLooping, let knownLength, frame % Int(knownLength * 48000) == 0 { loopCount += 1 }
        }
    }
}

extension Tune {
    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        levels[0] = sounded ? 1 : 0
        sounded = false
    }
}

/// Plays a tune to its end as a front end does, a block at a time.
private func played(_ tune: Tune, policy: PlaybackPolicy = PlaybackPolicy()) -> (session: TuneSession, sound: [Float]) {
    let session = TuneSession(renderer: tune, policy: policy)
    var sound: [Float] = []
    var block = [Float](repeating: 0, count: 2000)
    while !session.finished, sound.count < 48000 * 400 {
        let made = block.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: 1000) }
        for i in 0 ..< made { sound.append(block[i * 2]) }
    }
    return (session, sound)
}

/// Whether what was heard, up to a time, is what the tune plays (going by one sample in seven).
private func faithful(_ sound: [Float], to tune: Tune, until seconds: Double) -> Bool {
    let frames = Int(seconds * 48000)
    return sound.count >= frames && stride(from: 0, to: frames, by: 7).allSatisfy { sound[$0] == Tune.sample(tune, $0) }
}

@Test func tuneThatPausesIsPlayedThroughItsPause() {
    // Eight seconds of nothing in the middle of a tune of forty: once that was taken for its end.
    var tune = Tune(sounding: [0 ... 10, 18 ... 40], length: 40, goesRound: true)
    var result = played(tune)
    #expect(result.session.end == .completed)
    #expect(result.session.elapsed > 40)
    #expect(faithful(result.sound, to: tune, until: 39.9))

    // And half a minute of it, as a tune written to go with pictures may have.
    tune = Tune(sounding: [0 ... 10, 41 ... 60], length: 60, goesRound: true)
    result = played(tune)
    #expect(result.session.end == .completed)
    #expect(faithful(result.sound, to: tune, until: 59.9))

    // A tune of no known length that pauses is played on too, and ends when it does fall silent.
    tune = Tune(sounding: [0 ... 10, 18 ... 30], length: nil)
    result = played(tune)
    #expect(result.session.end == .silent)
    #expect(abs(result.session.elapsed - 35) < 0.1)
    #expect(abs(result.session.silence - 5) < 0.1)
    #expect(faithful(result.sound, to: tune, until: 35))

    // One that begins with a long silence is played, where it used to be passed over as never
    // having made a sound.
    tune = Tune(sounding: [12 ... 20], length: 20)
    result = played(tune)
    #expect(result.session.end == .completed)
    #expect(faithful(result.sound, to: tune, until: 19.9))
}

@Test func tuneThatFallsSilentForGoodIsOver() {
    // Silent from ten seconds to where it goes round: it is over five seconds into the silence, and
    // its beginning again is not its sound coming back.
    var result = played(Tune(sounding: [0 ... 10], length: 40, goesRound: true))
    #expect(result.session.end == .silent)
    #expect(abs(result.session.elapsed - 15) < 0.1)
    #expect(abs(result.session.silence - 5) < 0.1)

    // Nor is a tune waited on for longer than a minute.
    result = played(Tune(sounding: [0 ... 10, 80 ... 90], length: 100, goesRound: true))
    #expect(result.session.end == .silent)
    #expect(abs(result.session.elapsed - 15) < 0.1)

    // One that never makes a sound at all is given ten seconds.
    result = played(Tune(sounding: [], length: 100))
    #expect(result.session.end == .neverSounded)
    #expect(abs(result.session.elapsed - 10) < 0.1)

    // And a cap on a tune's time is not looked past.
    var policy = PlaybackPolicy()
    policy.maxTime = 16
    result = played(Tune(sounding: [0 ... 10, 18 ... 40], length: 40, goesRound: true), policy: policy)
    #expect(result.session.end == .silent)
}

@Test func voiceLevelsKeepStepWithTheSoundThroughAPause() {
    // The silence of a pause is found by playing on past it, and the voices' levels are asked for as
    // that is done: they are to be given out with the sound they belong to, and not before.
    let tune = Tune(sounding: [0 ... 10, 18 ... 40], length: 40, goesRound: true)
    let session = TuneSession(renderer: tune, policy: PlaybackPolicy())
    var block = [Float](repeating: 0, count: 2000)
    var lit = 0, dark = 0, litInSilence = 0, darkInSound = 0
    while !session.finished, session.elapsed < 39 {
        let made = block.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: 1000) }
        let sounds = (0 ..< made).contains { block[$0 * 2] != 0 }
        let level = session.channelLevels[0]
        if level > 0 { lit += 1 } else { dark += 1 }
        if level > 0, !sounds { litInSilence += 1 }
        if level == 0, sounds { darkInSound += 1 }
    }
    #expect(darkInSound == 0)
    // (The block the sound came back in is 4,096 frames, and begins with the last of the silence.)
    #expect(litInSilence <= 5)
    // Ten seconds of sound, eight of silence and twenty-one of sound, in blocks of a 48th of a second.
    #expect(abs(lit - 31 * 48) <= 6)
    #expect(abs(dark - 8 * 48) <= 6)
}
