// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayAmigaTrackers
@testable import SidayFoundation
@testable import SidayKit
import Testing

// The trackers of the MOD family before ProTracker ran their replays once a frame of a PAL Amiga's
// display, 313 lines of 227 of Paula's 3,546,895 clocks a second: NoiseTracker 2.0 from its level 3
// handler on the vertical blank (`L509` in its source), the first Soundtracker from its own
// (`frameirq` in Obarski's replay 1.2 of 8/1987). ProTracker's timer at 125 is a little faster.
// Ultimate Soundtracker 1.8 set a timer of (240 - tempo) * 122 instead. See
// `ProTrackerModule.ticksOnTheFrame` and `timerCount`.

private let frameClocks = 313 * 227, paulaClocks = 3_546_895

/// How many samples so many frames are, all told, with nothing lost between them.
private func samples(ofFrames ticks: Int) -> Int { ticks * frameClocks * outputSampleRate / paulaClocks }

/// A module of 31 samples with these four letters, one pattern long: a looping square wave struck on
/// the first row, and what else is asked for on the first row of the second channel.
private func module(tag: String, second: [UInt8] = [0, 0, 0, 0]) -> [UInt8] {
    var file = Array("frames".utf8) + [UInt8](repeating: 0, count: 14)
    for sample in 0 ..< 31 {
        var header = [UInt8](repeating: 0, count: 30)
        if sample == 0 {
            header[22 ... 23] = [0, 16]
            header[25] = 64
            header[26 ... 29] = [0, 0, 0, 16]
        } else {
            header[29] = 1
        }
        file += header
    }
    file += [1, 0] + [UInt8](repeating: 0, count: 128) + Array(tag.utf8)
    var pattern = [UInt8](repeating: 0, count: 1024)
    pattern[0 ..< 4] = [0x01, 0xAC, 0x10, 0x00]
    pattern[4 ..< 8] = second[0 ..< 4]
    file += pattern
    file += [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16)
    return file
}

/// A module of the Soundtrackers' 15 samples, which give a tempo where later files have a place to
/// start again from; the same square wave and pattern.
private func soundtracker(tempo: UInt8, second: [UInt8] = [0, 0, 0, 0]) -> [UInt8] {
    var file = Array("frames".utf8) + [UInt8](repeating: 0, count: 14)
    for sample in 0 ..< 15 {
        var header = [UInt8](repeating: 0, count: 30)
        if sample == 0 {
            header[22 ... 23] = [0, 16]
            header[25] = 64
            header[26 ... 29] = [0, 0, 0, 16]
        } else {
            header[29] = 1
        }
        file += header
    }
    file += [1, tempo] + [UInt8](repeating: 0, count: 128)
    var pattern = [UInt8](repeating: 0, count: 1024)
    pattern[0 ..< 4] = [0x01, 0xAC, 0x10, 0x00]
    pattern[4 ..< 8] = second[0 ..< 4]
    file += pattern
    file += [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16)
    return file
}

private func length(_ file: [UInt8]) throws -> Int {
    let renderer = try MODRenderer(file, options: LoadOptions())
    return Int((renderer.knownLength! * Double(outputSampleRate)).rounded())
}

@Test func noiseTrackersModulesTickOnTheFrame() throws {
    // 64 rows of six ticks, each a frame long.
    for tag in ["N.T.", "M&K!", "FEST"] {
        #expect(try length(module(tag: tag)) == samples(ofFrames: 64 * 6))
    }
    // ProTracker's own at its timer's 125: 14,187 counts of its 709,379 a second, and one more.
    let proTracker = try length(module(tag: "M.K."))
    #expect(proTracker != samples(ofFrames: 64 * 6))
    #expect(abs(Double(proTracker) - 64 * 6 * Double(outputSampleRate) * 14188 * 5 / Double(paulaClocks)) < 1)
}

@Test func noiseTrackerHasASpeedButNoTempo() throws {
    // F40 is a tempo of 64 to ProTracker, and a speed of $1F, the most there is, to NoiseTracker.
    let fast = [UInt8](arrayLiteral: 0, 0, 0x0F, 0x40)
    #expect(try length(module(tag: "N.T.", second: fast)) == samples(ofFrames: 64 * 31))
    #expect(try length(module(tag: "M&K!", second: fast)) == samples(ofFrames: 64 * 31))
    #expect(try length(module(tag: "M.K.", second: fast)) != samples(ofFrames: 64 * 31))
}

@Test func soundtrackersAtTheUsualTempoTickOnTheFrame() throws {
    // 120 is the usual tempo, and nothing is taken for it.
    #expect(try length(soundtracker(tempo: 120)) == samples(ofFrames: 64 * 6))
    #expect(try length(soundtracker(tempo: 0)) == samples(ofFrames: 64 * 6))
    // Another tempo is the timer of the Soundtrackers that had one, and no frame.
    #expect(try length(soundtracker(tempo: 112)) != samples(ofFrames: 64 * 6))
    // On the frame, a speed is the command's last figure: F23 is a speed of 3.
    #expect(try length(soundtracker(tempo: 120, second: [0, 0, 0x0F, 0x23])) == samples(ofFrames: 64 * 3))
}

@Test func ticksOfTheFrameAddUpWithNothingLost() throws {
    // A tick of the frame is 961 or 962 samples, as what is over comes to a whole one; after many
    // passes through the tune the sound is where the frames say it is. A pass is counted as the tick
    // that ends it begins.
    let renderer = try MODRenderer(module(tag: "N.T."), options: LoadOptions())
    let passes = 5
    var buffer = [Float](repeating: 0, count: 2)
    var made = 0
    while renderer.loopCount < passes {
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 1) }
        made += 1
    }
    #expect(made == samples(ofFrames: passes * 64 * 6 - 1) + 1)
}

/// How many samples so many ticks of a timer given this count are, all told: the timer fires once
/// each count and one more, of the E clock, a fifth of Paula's.
private func samples(ofTimer count: Int, ticks: Int) -> Int { ticks * (count + 1) * 5 * outputSampleRate / paulaClocks }

@Test func soundtrackersThatSetATimerTickByItExactly() throws {
    // A tempo of 112 is a count of (240 - 112) * 122 = 15,616.
    #expect(try length(soundtracker(tempo: 112)) == samples(ofTimer: 15616, ticks: 64 * 6))
    #expect(try length(soundtracker(tempo: 200)) == samples(ofTimer: 40 * 122, ticks: 64 * 6))
    // Until the tune sets a tempo of its own: then it is ProTracker's timer at that tempo (125:
    // 14,187 counts), from the tick after.
    let set = try length(soundtracker(tempo: 112, second: [0, 0, 0x0F, 0x7D]))
    let expected = samples(ofTimer: 15616, ticks: 1) + samples(ofTimer: 14187, ticks: 64 * 6 - 1)
    #expect(abs(set - expected) <= 1)
}

@Test func noiseTrackerSpeedsOfNothing() throws {
    // Nothing is a speed of one to NoiseTracker 2.0 and His Master's Noise, and nothing at all to
    // NoiseTracker V1.x. Which tracker wrote "N.T." is not known, and it is left as nothing.
    let nothing = [UInt8](arrayLiteral: 0, 0, 0x0F, 0x00)
    #expect(try length(module(tag: "M&K!", second: nothing)) == samples(ofFrames: 64))
    #expect(try length(module(tag: "FEST", second: nothing)) == samples(ofFrames: 64))
    #expect(try length(module(tag: "N.T.", second: nothing)) == samples(ofFrames: 64 * 6))
}

@Test func soundtrackerSpeedsAreTheirLastFigure() throws {
    // F12 is a speed of 2 to a Soundtracker that ran on the frame, not of 18.
    #expect(try length(soundtracker(tempo: 120, second: [0, 0, 0x0F, 0x12])) == samples(ofFrames: 64 * 2))
}

/// A NoiseTracker module whose song is two patterns long and begins again at the second.
private func twoPatterns(tag: String, restart: UInt8) -> [UInt8] {
    var file = module(tag: tag)
    file[950] = 2
    file[951] = restart
    file[953] = 1
    var pattern = [UInt8](repeating: 0, count: 1024)
    pattern[0 ..< 4] = [0x01, 0xAC, 0x10, 0x00]
    file.insert(contentsOf: pattern, at: 1084 + 1024)
    return file
}

@Test func noiseTrackerSongsBeginAgainWhereTheySay() throws {
    // Once through both patterns, and from then on the second alone.
    for (tag, again) in [("N.T.", 1), ("M&K!", 1), ("M.K.", 2)] {
        let renderer = try MODRenderer(twoPatterns(tag: tag, restart: 1), options: LoadOptions())
        var buffer = [Float](repeating: 0, count: 2 * 64)
        var made = 0
        while renderer.loopCount < 1 {
            buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 64) }
            made += 64
        }
        let first = made
        while renderer.loopCount < 2 {
            buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 64) }
            made += 64
        }
        // ProTracker's goes back to the start, two patterns again.
        let ratio = Double(made - first) / Double(first)
        #expect(abs(ratio - Double(again) / 2) < 0.01, "\(tag)")
    }
}
