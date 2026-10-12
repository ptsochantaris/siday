// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the C67 files that Impulse Tracker's replayer plays, with the FM chip beside it.
// The thorough check is made outside the package, against libopenmpt: every channel's pitch and
// volume on every tick of each file to hand, and what is heard.

private func long(_ value: Int) -> [UInt8] { (0 ..< 4).map { UInt8(value >> ($0 * 8) & 0xFF) } }

/// Something a pattern says: a note on a channel (0 to 3 are samples, 4 to 12 the FM chip's), a
/// volume alone, or so many rows to move on.
private enum Step {
    case note(channel: UInt8, octave: UInt8 = 2, note: UInt8 = 0, instrument: UInt8 = 0, volume: UInt8 = 15)
    case volume(channel: UInt8, UInt8)
    case rows(UInt8)

    var bytes: [UInt8] {
        switch self {
        case let .note(channel, octave, note, instrument, volume): [channel, octave << 4 | note | (instrument & 16) << 3, (instrument & 15) << 4 | volume]
        case let .volume(channel, volume): [0x20 + channel, volume]
        case let .rows(count): [0x40, count]
        }
    }
}

/// A patch for the FM chip that sounds for as long as its note does: a plain tone.
private let tone: [UInt8] = [0x01, 0x01, 0x3F, 0xF0, 0xF0, 0x00, 0x01, 0x00, 0xF0, 0xF0, 0x00]

/// A C67 file: one pattern or more, a sample that is a square wave of 32 samples going round, so
/// that the C a sample is played at 8,287 a second for is 259 Hz, and one patch for the chip.
private func c67(_ patterns: [[Step]], orders: [UInt8] = [0], speed: UInt8 = 6, restart: UInt8 = 0, loops: Bool = true, patch: [UInt8] = tone) -> [UInt8] {
    let sound: [UInt8] = (0 ..< 32).map { $0 < 16 ? 0xE4 : 0x1C }
    var file: [UInt8] = [speed, restart]
    file += [UInt8](repeating: 0, count: 32 * 13)
    file += long(0) + long(sound.count) + long(0) + long(loops ? sound.count : 0xFFFFF) + [UInt8](repeating: 0, count: 31 * 16)
    for i in 1 ..< 32 { file.replaceSubrange(418 + i * 16 + 12 ..< 418 + i * 16 + 16, with: long(0xFFFFF)) }
    file += [UInt8](repeating: 0, count: 32 * 13)
    file += patch + [UInt8](repeating: 0, count: 31 * 11)
    file += orders + [UInt8](repeating: 0xFF, count: 256 - orders.count)
    var bodies: [[UInt8]] = []
    for index in 0 ..< 128 {
        bodies.append(index < patterns.count ? patterns[index].flatMap(\.bytes) + [0x60] : [0x40, 0x40, 0x60])
    }
    var place = 0
    for body in bodies {
        file += long(place)
        place += body.count
    }
    for body in bodies { file += long(body.count) }
    return file + bodies.flatMap { $0 } + sound
}

private func heard(_ file: [UInt8], seconds: Double = 1) throws -> (left: [Float], right: [Float]) {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try TuneLoader.load(file, format: .c67, options: options)
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

private func pitch(_ samples: [Float], _ from: Double, _ to: Double) -> Double {
    let part = samples[Int(from * Double(outputSampleRate)) ..< Int(to * Double(outputSampleRate))]
    return Double(zip(part, part.dropFirst()).count { $0 < 0 && $1 >= 0 }) / (to - from)
}

private func loudness(_ samples: [Float], _ from: Double, _ to: Double) -> Float {
    let part = samples[Int(from * Double(outputSampleRate)) ..< Int(to * Double(outputSampleRate))]
    return (part.reduce(0) { $0 + $1 * $1 } / Float(part.count)).squareRoot()
}

/// How long a row lasts at a speed of six: six ticks at 143 to the minute.
private let row = 6 * 2.5 / 143

@Test func c67SampleSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "C67") == .c67)
    let renderer = try TuneLoader.load(c67([[.note(channel: 0), .rows(64)]]), format: .c67)
    #expect(renderer.info.format == "C67" && renderer.info.shortfalls.isEmpty)
    let sound = try heard(c67([[.note(channel: 0), .rows(64)]]))
    #expect(abs(pitch(sound.left, 0.1, 1) - 259) <= 2)
    #expect(abs(pitch(try heard(c67([[.note(channel: 0, octave: 3), .rows(64)]])).left, 0.1, 1) - 518) <= 3)
    #expect(abs(pitch(try heard(c67([[.note(channel: 0, octave: 2, note: 7), .rows(64)]])).left, 0.1, 1) - 388) <= 3)
    // The four channels of samples are to the left and the right by turns.
    let other = try heard(c67([[.note(channel: 1), .rows(64)]]))
    #expect(loudness(sound.left, 0.1, 1) > loudness(sound.right, 0.1, 1) * 1.5 && loudness(other.right, 0.1, 1) > loudness(other.left, 0.1, 1) * 1.5)
    // A volume alone changes the note that is sounding, and the least of them is not silence.
    let turnedDown = try heard(c67([[.note(channel: 0), .rows(4), .volume(channel: 0, 0), .rows(60)]]), seconds: 1.5)
    #expect(loudness(turnedDown.left, 0.6, 1.5) > 0.001 && loudness(turnedDown.left, 0.6, 1.5) * 8 < loudness(turnedDown.left, 0.05, 0.35))
    // A sample that does not go round ends.
    let once = try heard(c67([[.note(channel: 0), .rows(64)]], loops: false))
    #expect(loudness(once.left, 0.5, 1) < 0.0005)
}

@Test func c67ChipPlaysItsNotes() throws {
    // A note on the fifth channel is the FM chip's, in the middle, and an octave is an octave.
    let low = try heard(c67([[.note(channel: 4, octave: 3), .rows(64)]])), high = try heard(c67([[.note(channel: 4, octave: 4), .rows(64)]]))
    #expect(loudness(low.left, 0.2, 1) > 0.005 && abs(loudness(low.left, 0.2, 1) - loudness(low.right, 0.2, 1)) < 0.001)
    let lowPitch = pitch(low.left, 0.2, 1), highPitch = pitch(high.left, 0.2, 1)
    #expect(lowPitch > 50 && abs(highPitch / lowPitch - 2) < 0.03)
    // A file with neither a patch nor a sample is no file.
    var empty = c67([[.note(channel: 4), .rows(64)]], patch: [UInt8](repeating: 0, count: 11))
    empty.replaceSubrange(422 ..< 426, with: long(0))
    #expect(throws: TuneError.self) { try TuneLoader.load(empty, format: .c67) }
    // A light for each channel that is used, whichever kind it is.
    #expect(try TuneLoader.load(c67([[.note(channel: 0), .note(channel: 12), .rows(64)]]), format: .c67).channelCount == 2)
}

@Test func c67PatternIsAsLongAsItSays() throws {
    func length(_ file: [UInt8]) throws -> Double { try #require(try TuneLoader.load(file, format: .c67).knownLength) }
    #expect(abs(try length(c67([[.note(channel: 0), .rows(64)]])) - 64 * row) < 0.05)
    #expect(abs(try length(c67([[.note(channel: 0), .rows(10)]])) - 10 * row) < 0.05)
    #expect(abs(try length(c67([[.note(channel: 0), .rows(10)], [.note(channel: 1), .rows(20)]], orders: [0, 1, 0])) - 40 * row) < 0.05)
    #expect(abs(try length(c67([[.note(channel: 0), .rows(64)]], speed: 3)) - 32 * row) < 0.05)
}

@Test func c67FileThatIsCutOrDamagedIsReadOrRefused() throws {
    let whole = c67([[.note(channel: 0), .note(channel: 5, octave: 4, note: 3), .rows(3), .volume(channel: 5, 4), .rows(9)], [.note(channel: 12, instrument: 17), .rows(64)]], orders: [0, 1, 5])
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .c67) }
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0, count: 4000), format: .c67) }
    #expect(throws: TuneError.self) { try TuneLoader.load(c67([[.note(channel: 0), .rows(64)]], speed: 16), format: .c67) }
    #expect(throws: TuneError.self) { try TuneLoader.load(c67([[.note(channel: 0), .rows(64)]], orders: [0, 200]), format: .c67) }
    func play(_ file: [UInt8]) {
        guard let renderer = try? TuneLoader.load(file, format: .c67) else { return }
        var buffer = [Float](repeating: 0, count: 4800 * 2)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        #expect(buffer.allSatisfy { $0.isFinite && abs($0) < 4 })
    }
    for length in stride(from: 0, to: whole.count, by: 41) { play(Array(whole[..<length])) }
    // And with anything at all in its patterns and its patches.
    var seed: UInt32 = 670
    func random() -> UInt8 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: seed >> 16)
    }
    for _ in 0 ..< 150 {
        var file = whole
        for i in 1346 ..< 1698 where random() < 40 { file[i] = random() & [0x0F, 0xFF, 0xFF, 0xFF, 0xFF, 0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0x03][(i - 1346) % 11] }
        for i in 2978 ..< file.count where random() < 30 { file[i] = random() }
        play(file)
    }
}

@Test func c67VoicesSayWhetherTheyPlaySamples() throws {
    // A sample on the first channel and the FM chip on the fifth: the lights of the two are told apart.
    let renderer = try TuneLoader.load(c67([[.note(channel: 0), .note(channel: 4), .rows(32)]]), format: .c67)
    #expect(renderer.channelCount == 2)
    var sound = [Float](repeating: 0, count: 9600)
    var sampled = [Bool](repeating: false, count: renderer.channelCount)
    // Which is which is known from the patterns, before a note of it has been played.
    sampled.withUnsafeMutableBufferPointer { renderer.takeChannelsSampled(into: $0.baseAddress!) }
    #expect(sampled == [true, false])
    sound.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
    sampled.withUnsafeMutableBufferPointer { renderer.takeChannelsSampled(into: $0.baseAddress!) }
    #expect(sampled == [true, false])
    // And a session hands the same on, with the levels.
    let session = TuneSession(renderer: try TuneLoader.load(c67([[.note(channel: 0), .note(channel: 4), .rows(32)]]), format: .c67), policy: PlaybackPolicy())
    _ = sound.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: 4800) }
    #expect(session.channelsSampled == [true, false])
}
