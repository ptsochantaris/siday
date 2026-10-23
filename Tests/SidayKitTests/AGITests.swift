// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayChips
@testable import SidayEightBit
@testable import SidayFoundation
import Testing

// Fast checks of the player for Sierra AGI sounds. The thorough checks are made outside the package:
// as the Amiga played them, against UADE running Wanted Team's player of them for EaglePlayer, both
// routines (every one of the 745 files in UnExoticA's collection, by how loud each is from moment to
// moment); and on the PC's chip, against NewRisingSun's recordings of King's Quest II.

/// A note of a tone: how many ticks, the chip's divider, and how far it is turned down.
private typealias Tone = (ticks: Int, divider: Int, attenuation: Int)
/// A note of the noise: how many ticks, its rate (0 to 3), and how far it is turned down.
private typealias Noise = (ticks: Int, rate: Int, attenuation: Int)

/// A sound with these notes on its three tones and its noise, as the games kept them.
private func sound(_ tones: [[Tone]], noise: [Noise] = []) -> [UInt8] {
    var voices: [[UInt8]] = []
    for voice in 0 ..< 3 {
        var bytes: [UInt8] = []
        for note in voice < tones.count ? tones[voice] : [] {
            bytes += [UInt8(note.ticks & 0xFF), UInt8(note.ticks >> 8), UInt8(note.divider >> 4 & 0x3F),
                      UInt8(0x80 | voice << 5 | note.divider & 0x0F), UInt8(0x90 | voice << 5 | note.attenuation)]
        }
        voices.append(bytes + [0xFF, 0xFF])
    }
    var bytes: [UInt8] = []
    for note in noise { bytes += [UInt8(note.ticks & 0xFF), UInt8(note.ticks >> 8), 0, UInt8(0xE4 | note.rate), UInt8(0xF0 | note.attenuation)] }
    voices.append(bytes + [0xFF, 0xFF])
    var file: [UInt8] = []
    var place = 8
    for voice in voices {
        file += [UInt8(place & 0xFF), UInt8(place >> 8)]
        place += voice.count
    }
    return file + voices.joined()
}

private func load(_ file: [UInt8], _ replay: AGIReplay, stereo: Bool = false) throws -> any Renderer {
    var options = LoadOptions()
    options.agiReplay = replay
    if stereo {
        options.stereo = .abc
        options.amigaSeparation = 1
    }
    return try TuneLoader.load(file, format: .agi, options: options)
}

/// What a player makes of its sound from where it is, both sides together, and what it then says of
/// each voice: how loud it has been, and its pitch.
private func listened(_ renderer: any Renderer, seconds: Double) -> (sound: [Float], levels: [Float], pitches: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    var levels = [Float](repeating: 0, count: renderer.channelCount)
    var pitches = levels
    var struck = [Bool](repeating: false, count: renderer.channelCount)
    renderer.takeChannelLevels(into: &levels)
    renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] + buffer[$0 + 1] }, levels, pitches)
}

/// How loud a stretch of sound is, what is steady in it taken out.
private func loudness(_ samples: ArraySlice<Float>) -> Float {
    let middle = samples.reduce(0, +) / Float(samples.count)
    return (samples.map { ($0 - middle) * ($0 - middle) }.reduce(0, +) / Float(samples.count)).squareRoot()
}

/// How many times a second a stretch of sound goes up through its middle: from well below it to well
/// above, so that a wave that rests on its middle on the way is counted once.
private func cycles(_ samples: ArraySlice<Float>) -> Double {
    let middle = samples.reduce(0, +) / Float(samples.count)
    let margin = samples.map { abs($0 - middle) }.max()! * 0.25
    var count = 0
    var below = false
    for sample in samples {
        if sample - middle < -margin { below = true }
        if below, sample - middle > margin {
            count += 1
            below = false
        }
    }
    return Double(count) * Double(outputSampleRate) / Double(samples.count)
}

/// So many seconds' worth of samples, from one time to another.
private func between(_ samples: [Float], _ from: Double, _ to: Double) -> ArraySlice<Float> {
    samples[Int(from * Double(outputSampleRate)) ..< Int(to * Double(outputSampleRate))]
}

@Test func agiSoundIsRead() throws {
    let file = sound([[(30, 254, 0), (60, 127, 4)], [(45, 300, 2)]], noise: [(10, 2, 0)])
    let read = try AGISoundFile(file)
    #expect(read.voices.map(\.count) == [2, 1, 0, 1])
    #expect(read.voices[0][1].divider == 127 && read.voices[0][1].attenuation == 4)
    #expect(read.voices[3][0].low == 0xE6 && read.voices[3][0].attenuation == 0)
    #expect(read.ticks == 90)

    // The Amiga's interrupt comes round sixty times a second, all but exactly, and begins the first
    // notes as the sound begins; the PC's comes round sixty times exactly.
    let amiga = try load(file, .amiga), pc = try load(file, .pc)
    #expect(amiga.info.format == "AGI" && amiga.isPlayedOnAnAmiga && !pc.isPlayedOnAnAmiga)
    #expect(abs(amiga.knownLength! - 91 * 59115 / Paula.clockHz) < 1e-9)
    #expect(pc.knownLength == 1.5)
    #expect(amiga.channelCount == 4 && pc.channelCount == 4)
}

@Test func whatIsNotAnAGISoundIsRefused() throws {
    #expect(throws: TuneError.self) { try AGISoundFile([8, 0, 10, 0]) }
    // A voice that begins outside the file, or before the four places that say where the voices are.
    #expect(throws: TuneError.self) { try AGISoundFile([8, 0, 10, 0, 12, 0, 200, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) }
    #expect(throws: TuneError.self) { try AGISoundFile([2, 0, 10, 0, 12, 0, 14, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) }
    // A voice that has no end.
    var cut = sound([[(30, 254, 0)]])
    cut.removeLast(2)
    #expect(throws: TuneError.self) { try AGISoundFile(cut) }
    // And bytes of every kind are refused or played, but never trap.
    var seed: UInt64 = 7
    for _ in 0 ..< 200 {
        var bytes: [UInt8] = []
        for _ in 0 ..< 40 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        bytes[1] = 0
        bytes[3] = 0
        bytes[5] = 0
        bytes[7] = 0
        for replay in AGIReplay.allCases {
            if let renderer = try? load(bytes, replay) { _ = listened(renderer, seconds: 0.05) }
        }
    }
}

@Test func agiTonesAreAtTheChipsPitch() throws {
    // A divider of 254 is the A above middle C on the PC, its clock 3.58 MHz divided by 32 times it;
    // the Amiga's clock is a little slower, and so is its A.
    let file = sound([[(120, 254, 0)]])
    for (replay, hz) in [(AGIReplay.amiga, Paula.clockHz / (32 * 254)), (.amigaLater, Paula.clockHz / (32 * 254)), (.pc, 3_579_545.0 / (32 * 254))] {
        let heard = listened(try load(file, replay), seconds: 1)
        #expect(abs(cycles(between(heard.sound, 0.2, 0.9)) - hz) < 3, "\(replay): \(cycles(between(heard.sound, 0.2, 0.9))) for \(hz)")
        #expect(abs(heard.pitches[0] - ChannelPitch.note(ofHz: hz)) < 0.01, "\(replay)")
        #expect(heard.pitches[1] == 0 && heard.levels[1] == 0)
    }
}

@Test func agiVolumesAreTheMachines() throws {
    // On the Amiga a voice turned down by ten of the fifteen steps is a third as loud, the steps even
    // ones from 64 down; on the PC's chip it is 20 dB down, the steps of 2 dB.
    let file = sound([[(30, 254, 0), (30, 254, 10)]])
    for (replay, part) in [(AGIReplay.amiga, Float(21) / 64), (.pc, Float(0.1))] {
        let heard = listened(try load(file, replay), seconds: 1)
        let ratio = loudness(between(heard.sound, 0.6, 0.95)) / loudness(between(heard.sound, 0.1, 0.45))
        #expect(abs(ratio / part - 1) < 0.05, "\(replay): \(ratio)")
    }
}

@Test func agiLaterRoutineLetsEachToneDieAway() throws {
    // A tone held for two seconds, and then a noise.
    let file = sound([[(120, 254, 0)]], noise: [(120, 2, 15), (60, 2, 0)])
    let first = listened(try load(file, .amiga), seconds: 3).sound
    let later = listened(try load(file, .amigaLater), seconds: 3).sound
    // Sierra's first routine holds the tone where it is.
    #expect(abs(loudness(between(first, 1.2, 1.9)) / loudness(between(first, 0.1, 0.3)) - 1) < 0.05)
    // Its later one turns it down over a second, to 11 steps under where it began, and leaves it there:
    // from 64 to 17 of Paula's volumes. (It is at 64 from its third tick to its sixth.)
    let fall = loudness(between(later, 1.2, 1.9)) / loudness(between(later, 0.04, 0.095))
    #expect(abs(fall / (17.0 / 64) - 1) < 0.1, "\(fall)")
    // But the noise only dies away in the sound's first second: begun after that, it is as loud as its note.
    let noise = loudness(between(later, 2.1, 2.9)) / loudness(between(first, 2.1, 2.9))
    #expect(abs(noise - 1) < 0.15, "\(noise)")
}

@Test func agiSoundPlaysOnceAndEnds() throws {
    let file = sound([[(30, 254, 0)], [(60, 200, 0)]])
    for replay in AGIReplay.allCases {
        let renderer = try load(file, replay)
        #expect(!renderer.endsByLooping)
        _ = listened(renderer, seconds: renderer.knownLength! - 0.05)
        #expect(!renderer.hasEnded, "\(replay)")
        _ = listened(renderer, seconds: 0.1)
        #expect(renderer.hasEnded, "\(replay)")
        // What comes after is silence, once the filters on the way out have let go of the last of the
        // sound, and the voices are dark.
        let after = listened(renderer, seconds: 0.6)
        #expect(after.levels.allSatisfy { $0 == 0 }, "\(replay): \(after.levels)")
        #expect(between(after.sound, 0.5, 0.6).allSatisfy { abs($0) < 1e-3 }, "\(replay)")
        // And it can be heard again from the start.
        renderer.select(subsong: 0)
        #expect(!renderer.hasEnded && loudness(listened(renderer, seconds: 0.3).sound[...]) > 0.01)
    }
}

@Test func agiVoiceLeftOutIsNotHeardAndPlaysOn() throws {
    let file = sound([[(60, 254, 0)], [(60, 127, 0)]])
    for replay in AGIReplay.allCases {
        let whole = listened(try load(file, replay), seconds: 0.5)
        let renderer = try load(file, replay)
        renderer.setMuted([false, true])
        let without = listened(renderer, seconds: 0.5)
        // The voice is still said to be as loud as it was, at the pitch it was, but is not heard.
        #expect(without.levels == whole.levels && without.levels[1] > 0.2, "\(replay)")
        #expect(without.pitches == whole.pitches && without.pitches[1] > 0, "\(replay)")
        #expect(loudness(without.sound[...]) < loudness(whole.sound[...]) * 0.9, "\(replay)")
        let silent = try load(file, replay)
        silent.setMuted([true, true, true, true])
        #expect(listened(silent, seconds: 0.5).sound.allSatisfy { $0 == 0 }, "\(replay)")
    }
}

/// Each voice's scope after so long, its sound kept from the start.
private func scopes(_ renderer: any Renderer, seconds: Double = 0.5) -> [[UInt8]] {
    let session = TuneSession(renderer: renderer, policy: PlaybackPolicy())
    #expect(session.keepChannelWaves())
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    _ = buffer.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: frames) }
    var all = [UInt8](repeating: 0, count: renderer.channelCount * ChannelWaves.points)
    all.withUnsafeMutableBufferPointer { session.takeChannelWaves(into: $0.baseAddress!, behind: 0) }
    return (0 ..< renderer.channelCount).map { Array(all[$0 * ChannelWaves.points ..< ($0 + 1) * ChannelWaves.points]) }
}

private func height(_ scope: [UInt8]) -> Int { scope.map { abs(Int($0) - 128) }.max() ?? 0 }

@Test func agiVoicesHaveScopes() throws {
    // A tone at the loudest, one turned down by ten steps, and the noise.
    let file = sound([[(60, 254, 0)], [(60, 254, 10)]], noise: [(60, 2, 0)])
    for replay in AGIReplay.allCases {
        let heard = scopes(try load(file, replay))
        #expect(height(heard[0]) > 40, "\(replay)")
        #expect(height(heard[1]) > 5 && height(heard[1]) < height(heard[0]), "\(replay)")
        #expect(heard[2].allSatisfy { $0 == 128 }, "\(replay)")
        #expect(height(heard[3]) > 20, "\(replay)")
        // A voice left out still has its scope.
        let muted = try load(file, replay)
        muted.setMuted([true])
        #expect(height(scopes(muted)[0]) == height(heard[0]), "\(replay)")
        // And the sound is the same, its voices kept or not.
        let plain = try load(file, replay, stereo: true), kept = try load(file, replay, stereo: true)
        #expect(kept.keepChannelWaves() != nil)
        #expect(listened(plain, seconds: 1).sound == listened(kept, seconds: 1).sound, "\(replay)")
    }
}

@Test func agiSettingIsAChoiceOfThree() throws {
    #expect(Setting.agiReplay.changes(.agi) && !Setting.agiReplay.changes(.mod) && !Setting.agiReplay.changes(.vgm))
    #expect(!Setting.chip.changes(.agi) && !Setting.clock.changes(.agi) && Setting.amiga.changes(.agi))
    for (place, replay) in [(0.0, AGIReplay.amiga), (1, .amigaLater), (2, .pc)] {
        var values = Setting.standards
        values[Setting.agiReplay.rawValue] = place
        var options = LoadOptions(), policy = PlaybackPolicy()
        Setting.apply(values, to: &options, &policy)
        #expect(options.agiReplay == replay)
    }
    #expect(LoadOptions().agiReplay == .amiga)
}
