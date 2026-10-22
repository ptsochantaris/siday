// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayEightBit
@testable import SidayFoundation
import Testing

// How loud each voice of a tune is, for the lights.

@Test func lightGoesByDecibels() {
    #expect(ChannelLight.brightness(of: 0) == 0)
    #expect(ChannelLight.brightness(of: 1) == 1)
    #expect(ChannelLight.brightness(of: 4) == 1)
    // Half the range of 42 dB is 21 dB down, which is a level of about 0.089.
    #expect(abs(ChannelLight.brightness(of: 0.0891) - 0.5) < 0.01)
    // Quieter than the quietest that shows.
    #expect(ChannelLight.brightness(of: 0.005) == 0)
    var last: Float = 0
    for step in 1 ... 100 {
        let brightness = ChannelLight.brightness(of: Float(step) / 100)
        #expect(brightness >= last)
        last = brightness
    }
}

@Test func ayChannelsAreMeasuredApart() {
    var chip = AYChip(type: .ay, clockHz: 1_773_400, sampleRate: 48000, stereo: .mono)
    var levels = [Float](repeating: -1, count: 3)
    func run(_ chip: inout AYChip) -> [Float] {
        for _ in 0 ..< 2000 { _ = chip.sample() }
        levels.withUnsafeMutableBufferPointer { chip.takeLevels(into: $0.baseAddress!) }
        return levels
    }

    // A is silent, B a tone at full volume, C a tone at volume 8: all three with tone on and noise off.
    chip.write(7, 0b111_000)
    chip.write(2, 200)
    chip.write(9, 15)
    chip.write(4, 100)
    chip.write(10, 8)
    var heard = run(&chip)
    #expect(heard[0] == 0)
    #expect(heard[1] == 1)
    #expect(heard[2] > 0.1 && heard[2] < 0.2)

    // Asking again starts afresh: with B turned off, it is dark the next time.
    chip.write(9, 0)
    heard = run(&chip)
    #expect(heard[1] == 0)
    #expect(heard[2] > 0.1)

    // A tone too high to hear, as tunes use to hold a channel open, is not a sound: only what is done
    // to its volume is. Here nothing is, and then it is moved between two levels.
    chip.write(0, 1)
    chip.write(8, 15)
    heard = run(&chip)
    #expect(heard[0] == 0)
    for step in 0 ..< 2000 {
        chip.write(8, step % 40 < 20 ? 15 : 11)
        _ = chip.sample()
    }
    levels.withUnsafeMutableBufferPointer { chip.takeLevels(into: $0.baseAddress!) }
    #expect(levels[0] > 0.5 && levels[0] < 1)

    // A channel with neither tone nor noise is a steady level, which is silence; with the envelope
    // going round on it, it is a sound.
    chip.write(7, 0b111_111)
    chip.write(8, 15)
    heard = run(&chip)
    #expect(heard[0] == 0)
    chip.write(11, 40)
    chip.write(13, 8)
    chip.write(8, 16)
    heard = run(&chip)
    #expect(heard[0] == 1)
}

@Test func tickLevelsHoldForAsLongAsTheTick() {
    var levels = TickLevels(voices: 2)
    var taken = [Float](repeating: -1, count: 2)
    func take(_ levels: inout TickLevels) -> [Float] {
        taken.withUnsafeMutableBufferPointer { levels.take(into: $0.baseAddress!) }
        return taken
    }
    levels.now = [0.5, 0]
    levels.tickMade()
    levels.now = [0.2, 0.7]
    levels.tickMade()
    // The most each voice has been in the ticks made since they were last taken.
    #expect(take(&levels) == [0.5, 0.7])
    // No new tick: the one that is still being given out.
    #expect(take(&levels) == [0.2, 0.7])
    levels.now = [0, 0]
    levels.tickMade()
    #expect(take(&levels) == [0.2, 0.7])
    #expect(take(&levels) == [0, 0])
}

@Test func pitchIsCountedInSemitones() {
    #expect(ChannelPitch.note(ofHz: 440) == 69)
    #expect(abs(ChannelPitch.note(ofHz: 261.63) - 60) < 0.01)
    #expect(ChannelPitch.note(ofHz: 880) == 81)
    #expect(ChannelPitch.note(ofHz: 0) == 0)
    // A sample at the rate trackers call middle C, and an octave above it.
    #expect(ChannelPitch.note(ofRate: 8363) == 60)
    #expect(ChannelPitch.note(ofRate: 16726) == 72)
}

@Test func ayChannelsTellTheirNotes() {
    var chip = AYChip(type: .ay, clockHz: 1_773_400, sampleRate: 48000, stereo: .mono)
    var pitches = [Float](repeating: -1, count: 3)
    var struck = [Bool](repeating: false, count: 3)
    func notes(_ chip: inout AYChip) {
        for _ in 0 ..< 500 { _ = chip.sample() }
        pitches.withUnsafeMutableBufferPointer { p in struck.withUnsafeMutableBufferPointer { s in chip.takeNotes(pitches: p.baseAddress!, struck: s.baseAddress!) } }
    }

    // A tone of period 252 on the first channel is 1,773,400 / (16 x 252) = 440 Hz: the A, 69.
    chip.write(7, 0b111_110)
    chip.write(0, 252)
    chip.write(8, 15)
    notes(&chip)
    #expect(abs(pitches[0] - 69) < 0.05)
    #expect(struck[0])
    // The others are silent, and have neither a pitch nor a note.
    #expect(pitches[1] == 0 && !struck[1])
    // The note goes on: it is not struck again, and not by its volume falling away.
    chip.write(8, 12)
    notes(&chip)
    #expect(abs(pitches[0] - 69) < 0.05)
    #expect(!struck[0])
    // Until the volume jumps back up.
    chip.write(8, 15)
    notes(&chip)
    #expect(struck[0])
    // Two volumes up from where it has fallen to is a note as well: some tunes give one no more.
    chip.write(8, 13)
    notes(&chip)
    #expect(!struck[0])
    chip.write(8, 15)
    notes(&chip)
    #expect(struck[0])
    // One volume up is not. Nor are two when the volume was already rising: that is a note fading in.
    chip.write(8, 10)
    notes(&chip)
    chip.write(8, 11)
    notes(&chip)
    #expect(!struck[0])
    chip.write(8, 13)
    notes(&chip)
    #expect(!struck[0])
    chip.write(8, 15)
    notes(&chip)
    #expect(!struck[0])

    // Noise alone has no pitch.
    chip.write(7, 0b110_111)
    notes(&chip)
    #expect(pitches[0] == 0)

    // With neither tone nor noise but an envelope that goes round, the envelope is the tone: a
    // sawtooth of period 10 is 1,773,400 / (256 x 10) = 693 Hz, a little under the F at 77.
    chip.write(7, 0b111_111)
    chip.write(11, 10)
    chip.write(13, 8)
    chip.write(8, 16)
    notes(&chip)
    #expect(abs(pitches[0] - 76.86) < 0.05)
    // An envelope that plays once, started, is a note struck.
    chip.write(13, 0)
    notes(&chip)
    #expect(struck[0])
    #expect(pitches[0] == 0)
}

@Test func ayChannelsHaveSidesWhateverTheyAreHeardThrough() {
    /// Where a chip says its three channels are.
    func sides(_ layout: StereoLayout) -> [Float] {
        let chip = AYChip(type: .ay, clockHz: 1_773_400, sampleRate: 48000, stereo: layout)
        var sides = [Float](repeating: 9, count: 3)
        sides.withUnsafeMutableBufferPointer { chip.sides(into: $0.baseAddress!) }
        return sides.map { ($0 * 10).rounded() / 10 }
    }
    // The first on the left, and the last on the right or the one before it: and heard in mono,
    // they are where they would be the usual way round.
    #expect(sides(.abc) == [-0.9, 0, 0.9])
    #expect(sides(.acb) == [-0.9, 0.9, 0])
    #expect(sides(.mono) == [-0.9, 0, 0.9])
}

// MARK: Voices left out

/// A tune that sets its registers once and leaves them: a tone on every channel of one chip or two,
/// each at the volume given for it, where 16 is the envelope, which goes round.
private final class SteadyTune: AYFrameSource {
    let info = TuneInfo(format: "TEST")
    private let volumes: [Int]
    private var ticks = 0
    private(set) var loopCount = 0
    var chipCount: Int { volumes.count / 3 }

    init(volumes: [Int]) {
        self.volumes = volumes
    }

    func restart() {
        ticks = 0
        loopCount = 0
    }

    func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        for chip in 0 ..< chipCount {
            regs[chip].tonA = 200 + chip * 31
            regs[chip].tonB = 317 + chip * 31
            regs[chip].tonC = 141 + chip * 31
            regs[chip].mixer = 0b111_000
            regs[chip].amplA = volumes[chip * 3]
            regs[chip].amplB = volumes[chip * 3 + 1]
            regs[chip].amplC = volumes[chip * 3 + 2]
            regs[chip].envelope = 40
            if ticks == 0 { regs[chip].setEnvelopeRegister(10) }
        }
        ticks += 1
        if ticks % 100 == 0 { loopCount += 1 }
    }
}

/// The most that two sounds differ by at any sample.
private func apart(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
    a.count == b.count ? zip(a, b).map { abs($0 - $1) }.max() ?? 0 : .infinity
}

@Test func mutedAYChannelIsLeftOutAndPlaysOn() {
    // What a player makes of its tune from the start, both sides, and what it says of its voices.
    func played(_ player: AYFramePlayer<SteadyTune>, frames: Int = 2400) -> (sound: [Float], levels: [Float], pitches: [Float], sides: [Float]) {
        var sound = [Float](repeating: 0, count: frames * 2)
        sound.withUnsafeMutableBufferPointer { player.render(into: $0.baseAddress!, frames: frames) }
        let count = player.channelCount
        var levels = [Float](repeating: -1, count: count), pitches = levels, sides = levels
        var struck = [Bool](repeating: false, count: count)
        levels.withUnsafeMutableBufferPointer { player.takeChannelLevels(into: $0.baseAddress!) }
        pitches.withUnsafeMutableBufferPointer { p in struck.withUnsafeMutableBufferPointer { s in player.takeChannelNotes(pitches: p.baseAddress!, struck: s.baseAddress!) } }
        sides.withUnsafeMutableBufferPointer { player.takeChannelSides(into: $0.baseAddress!) }
        return (sound, levels, pitches, sides)
    }
    // Two chips, as TurboSound has: the first channel of the first plays the envelope, and the
    // second of the second is silent.
    let volumes = [16, 12, 15, 10, 0, 13]
    func player(_ volumes: [Int], _ layout: StereoLayout = .abc) -> AYFramePlayer<SteadyTune> {
        var options = LoadOptions()
        options.stereo = layout
        return AYFramePlayer(source: SteadyTune(volumes: volumes), options: options)
    }
    /// The tune with one channel left out, and the tune with that channel at no volume.
    func without(_ voice: Int, _ layout: StereoLayout = .abc) -> (muted: AYFramePlayer<SteadyTune>, quiet: AYFramePlayer<SteadyTune>) {
        let muted = player(volumes, layout)
        var marks = [Bool](repeating: false, count: 6), fewer = volumes
        marks[voice] = true
        fewer[voice] = 0
        muted.setMuted(marks)
        return (muted, player(fewer, layout))
    }
    let whole = played(player(volumes))
    #expect(whole.levels.enumerated().allSatisfy { ($1 > 0.1) == (volumes[$0] > 0) })

    // A channel left out: the sound is, to the last bit, that of the tune with the channel at no
    // volume, on both sides; and all that is said of the channel is what it was. The envelope the
    // first channel plays goes round whether or not that channel is heard.
    for voice in 0 ..< 6 where volumes[voice] > 0 {
        let pair = without(voice)
        let heard = played(pair.muted)
        #expect(heard.sound == played(pair.quiet).sound, "voice \(voice)")
        #expect(heard.sound != whole.sound)
        #expect(heard.levels == whole.levels && heard.pitches == whole.pitches && heard.sides == whole.sides)
    }
    // The same whichever way round the channels are heard, or with both sides alike.
    for layout in [StereoLayout.acb, .mono] {
        let pair = without(1, layout)
        #expect(played(pair.muted).sound == played(pair.quiet).sound, "\(layout)")
    }

    // A song started again is started without the channel; and with it brought back, as it ever
    // was. (Once the chip's filters have forgotten what they last played, that is: a song started
    // again is played on the same chip, and its filters are not emptied for it.)
    let again = without(2).muted
    let first = played(again, frames: 9600)
    again.select(subsong: 0)
    #expect(apart(played(again, frames: 9600).sound[8192...], first.sound[8192...]) < 1e-6)
    again.setMuted([])
    again.select(subsong: 0)
    #expect(apart(played(again, frames: 9600).sound[8192...], played(player(volumes), frames: 9600).sound[8192...]) < 1e-6)

    // Marks for the first chip alone leave the second heard; and every channel left out is silence.
    let one = player(volumes)
    one.setMuted([true, true, true])
    #expect(played(one).sound == played(player([0, 0, 0] + volumes[3...])).sound)
    let silent = player(volumes)
    silent.setMuted([Bool](repeating: true, count: 6))
    let nothing = played(silent)
    #expect(nothing.sound.allSatisfy { $0 == 0 })
    #expect(nothing.levels == whole.levels)
}
