// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Voices left out of the sound (`Renderer.setMuted`): what is asked of every player. A voice left out
// is not heard and goes on playing, so that its light still shows it; the voices that are heard
// sound exactly as they did; and with no voice left out the sound is what it always was.

/// What a player makes of its tune from the start, and how loud it said each voice was in it.
private func played(_ renderer: any Renderer, seconds: Double = 0.5) -> (sound: [Float], levels: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    var levels = [Float](repeating: 0, count: renderer.channelCount)
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    return (buffer, levels)
}

private func left(_ sound: [Float]) -> [Float] { stride(from: 0, to: sound.count, by: 2).map { sound[$0] } }
private func right(_ sound: [Float]) -> [Float] { stride(from: 1, to: sound.count, by: 2).map { sound[$0] } }
private func loudest(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }
/// The most that two sounds differ by at any sample.
private func apart(_ a: [Float], _ b: [Float]) -> Float { a.count == b.count ? zip(a, b).map { abs($0 - $1) }.max() ?? 0 : .infinity }

/// A MOD file of one pattern with a square wave on its first channel, which an Amiga has on the
/// left, and the same an octave up on its second, which it has on the right.
private func twoVoiceModule() -> [UInt8] {
    var file = Array("two voices".utf8)
    file += [UInt8](repeating: 0, count: 20 - file.count)
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
    file += [1, 127] + [UInt8](repeating: 0, count: 128) + Array("M.K.".utf8)
    var pattern = [UInt8](repeating: 0, count: 64 * 4 * 4)
    pattern.replaceSubrange(0 ..< 4, with: [UInt8(428 >> 8), UInt8(428 & 0xFF), 0x10, 0])
    pattern.replaceSubrange(4 ..< 8, with: [UInt8(214 >> 8), UInt8(214 & 0xFF), 0x10, 0])
    file += pattern
    file += [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16)
    return file
}

@Test func mutedVoiceOfAModuleIsLeftOutAndPlaysOn() throws {
    var options = LoadOptions()
    options.stereo = .abc
    options.amigaSeparation = 1
    func fresh() throws -> any Renderer { try TuneLoader.load(twoVoiceModule(), format: .mod, options: options) }

    let whole = played(try fresh())
    #expect(loudest(left(whole.sound)) > 0.2 && loudest(right(whole.sound)) > 0.2)

    // The second voice left out: the right is silent, the left is what it was, and the voice is
    // still said to be as loud as it was.
    let renderer = try fresh()
    renderer.setMuted([false, true, false, false])
    let without = played(renderer)
    #expect(loudest(right(without.sound)) < 0.001)
    // (To the last place or two of a number, that is: the two sides are brought together and parted
    // again on the way out, and a sum with nothing on one side rounds otherwise.)
    #expect(apart(left(without.sound), left(whole.sound)) < 1e-5)
    #expect(without.levels == whole.levels)
    #expect(without.levels[1] > 0.5)

    // A song started again is started without the voice; and with it brought back, as it ever was.
    renderer.select(subsong: 0)
    #expect(played(renderer).sound == without.sound)
    renderer.setMuted([])
    renderer.select(subsong: 0)
    #expect(played(renderer).sound == whole.sound)

    // Every voice left out is silence.
    let silent = try fresh()
    silent.setMuted([true, true, true, true])
    #expect(loudest(played(silent).sound) < 0.001)
}

@Test func songWithVoicesLeftOutEndsWhereTheWholeSongDoes() throws {
    // A module that plays one pattern and stops itself (a jump back to its own row is how these
    // end); the whole song says how it ended, and the song with every voice left out, which is
    // silence from its first sample, is played to the same end and not given up for silent.
    var policy = PlaybackPolicy()
    policy.loops = 1
    func session(muted: [Bool], following: TuneSession.Ending? = nil) throws -> TuneSession {
        let renderer = try TuneLoader.load(twoVoiceModule(), format: .mod)
        renderer.setMuted(muted)
        return following.map { TuneSession(renderer: renderer, policy: policy, following: $0) } ?? TuneSession(renderer: renderer, policy: policy)
    }
    func run(_ session: TuneSession) -> [Float] {
        var all: [Float] = []
        var block = [Float](repeating: 0, count: 1024)
        while !session.finished {
            let made = block.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: 512) }
            all += block[..<(made * 2)]
        }
        return all
    }
    let whole = try session(muted: [])
    let sound = run(whole)
    let ending = try #require(whole.ending)
    #expect(ending.frames * 2 == sound.count && ending.frames > 48000)

    // Played again to that ending with nothing left out, it is the same sound.
    #expect(run(try session(muted: [], following: ending)) == sound)
    // With everything left out it lasts as long, and is silence.
    let silent = run(try session(muted: [true, true, true, true], following: ending))
    #expect(silent.count == sound.count)
    #expect(loudest(silent) < 0.001)
    // Left to judge for itself it would have stopped for never having made a sound.
    let judged = try session(muted: [true, true, true, true])
    _ = run(judged)
    #expect(judged.end == .neverSounded || judged.end == .silent || (judged.ending?.frames ?? 0) != ending.frames)
}
