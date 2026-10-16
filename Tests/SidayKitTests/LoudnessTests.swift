// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// The loudness meter against the figures BS.1770 and EBU Tech 3341 give for their test signals.

/// Measures stretches of a steady sine one after another: each its seconds, and its peak on either
/// side in dB of full scale (nil for silence).
private func measure(_ hz: Double, _ stretches: [(seconds: Double, left: Double?, right: Double?)],
                     phase: Double = 0) -> LoudnessMeter {
    var meter = LoudnessMeter()
    var block = [Float](repeating: 0, count: 2 * 4800)
    var n = 0
    for stretch in stretches {
        let l = stretch.left.map { pow(10, $0 / 20) } ?? 0, r = stretch.right.map { pow(10, $0 / 20) } ?? 0
        var left = Int(stretch.seconds * 48000)
        while left > 0 {
            let frames = min(left, 4800)
            for i in 0 ..< frames {
                let v = sin(2 * Double.pi * hz * Double(n + i) / 48000 + phase)
                block[2 * i] = Float(l * v)
                block[2 * i + 1] = Float(r * v)
            }
            block.withUnsafeBufferPointer { meter.take($0.baseAddress!, frames: frames) }
            n += frames
            left -= frames
        }
    }
    return meter
}

@Test func aSineOf997HzAtMinus20OnBothSidesIsMinus20LUFS() throws {
    let loudness = try #require(measure(997, [(20, -20, -20)]).loudness)
    #expect(abs(loudness + 20) < 0.01)
}

@Test func oneSideAloneIsThreeDecibelsQuieter() throws {
    let loudness = try #require(measure(997, [(20, 0, nil)]).loudness)
    #expect(abs(loudness + 3.01) < 0.01)
}

@Test func theEBUsStereoSinesAreTheirLoudness() throws {
    // EBU Tech 3341, cases 1 and 2: 1 kHz on both sides at -23 and at -33 dBFS.
    for level in [-23.0, -33] {
        let loudness = try #require(measure(1000, [(20, level, level)]).loudness)
        #expect(abs(loudness - level) < 0.1)
    }
}

@Test func theQuietPartsAreLeftOutOfTheLoudness() throws {
    // EBU Tech 3341, cases 3 to 5: each is -23 LUFS once its quieter parts are gated out.
    let cases: [[(seconds: Double, left: Double?, right: Double?)]] = [
        [(10, -36, -36), (60, -23, -23), (10, -36, -36)],
        [(10, -72, -72), (10, -36, -36), (60, -23, -23), (10, -36, -36), (10, -72, -72)],
        [(20, -26, -26), (20.1, -20, -20), (20, -26, -26)],
    ]
    for stretches in cases {
        let loudness = try #require(measure(1000, stretches).loudness)
        #expect(abs(loudness + 23) < 0.1)
    }
}

@Test func silenceHasNoLoudness() {
    #expect(measure(1000, [(5, nil, nil)]).loudness == nil)
    #expect(measure(1000, [(5, -80, -80)]).loudness == nil)
    #expect(measure(1000, [(0.3, -20, -20)]).loudness == nil)
}

@Test func howLongTheSilenceAroundASoundIsDoesNotChangeItsLoudness() throws {
    // The blocks that take in the sound's edges are counted, and are quieter, but there are as many
    // of them however much silence there is.
    let short = try #require(measure(997, [(1, nil, nil), (10, -20, -20), (1, nil, nil)]).loudness)
    let long = try #require(measure(997, [(20, nil, nil), (10, -20, -20), (30, nil, nil)]).loudness)
    #expect(abs(short - long) < 0.001)
    #expect(abs(short + 20) < 0.15)
}

@Test func theTruePeakIsFoundBetweenTheSamples() {
    // A sine of a quarter of the rate, sampled halfway between its tops: every sample is at -3 dB of
    // its peak, which is full scale.
    let quarter = measure(12000, [(1, 0, 0)], phase: Double.pi / 4)
    #expect(abs(quarter.truePeak) < 0.2)
    let low = measure(997, [(1, -6, -6)])
    #expect(abs(low.truePeak + 6) < 0.05)
    #expect(measure(997, [(1, nil, nil)]).truePeak < -200)
}
