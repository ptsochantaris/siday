// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayChips
import SidayFoundation

// The chips a VGM file is played on, each as the player drives it.

/// One of the chips a VGM file is played on, as the player drives it: it is told how many of its
/// own steps there are until the next write, and makes sound at the player's rate until it has
/// taken them.
protocol VGMSoundChip: AnyObject {
    /// How many steps it takes a second: what its writes are timed in.
    var rate: Double { get }
    var samplesLeft: Int { get set }
    func reset()
    func write(_ register: Int, _ value: UInt8)
    /// Makes sound, left and right, until `frames` are made or `samplesLeft` is taken; turned down
    /// over the last `fade` steps, if that is not nought, of which `after` come after `samplesLeft`.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int, after: Int) -> Int
    var voices: Int { get }
    func takeLevels(into levels: UnsafeMutablePointer<Float>)
    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>)
    func takeSides(into sides: UnsafeMutablePointer<Float>)
    func setMuted(_ muted: [Bool])
    /// The card, for an FM chip: for comparing what it makes with a reference player.
    var card: OPLCard? { get }
    /// True if its voices play recordings of sounds, samples, and not sounds of the chip's own.
    var sampled: Bool { get }
    /// A sound has been started on it by the file: a note, for what is shown of the voices.
    func soundStarted()
    /// Keeps each of its voices' sound for its scope from now on, in `waves` as the voices from
    /// `first` on, a sample for each it makes.
    func keepWaves(in waves: ChannelWaves, first: Int)
    /// How many samples of each of its voices are kept in a second.
    var wavesRate: Double { get }
}

extension VGMSoundChip {
    var card: OPLCard? { nil }
    var sampled: Bool { false }
    func soundStarted() {}
    /// One for each of the player's frames.
    var wavesRate: Double { Double(outputSampleRate) }
}

/// An FM chip, on the card that played it.
final class VGMOPL: VGMSoundChip {
    private let opl: OPLCard
    var card: OPLCard? { opl }
    let rate: Double
    let voices: Int
    private let isOPL: Bool

    init(_ chip: VGMFile.Chip, clock: Double) {
        // (In whole samples a second, as libvgm has it: a difference of a sample in fifty thousand.)
        rate = (clock / (chip == .opl3 ? 288 : 72)).rounded(.down)
        opl = OPLCard(rate: rate)
        voices = chip == .opl3 ? 18 : 9
        isOPL = chip == .opl
    }

    var samplesLeft: Int {
        get { opl.samplesLeft }
        set { opl.samplesLeft = newValue }
    }

    func reset() { opl.reset() }

    func write(_ register: Int, _ value: UInt8) {
        // (The OPL has no choice of waves, and what an OPL2 would take as one it does not have.)
        if isOPL, register >= 0xE0 { return }
        opl.writeEither(register, value)
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int, after: Int) -> Int {
        opl.renderStereo(into: buffer, frames: frames, gain: gain, fade: fade, after: after)
    }

    func takeLevels(into levels: UnsafeMutablePointer<Float>) { opl.takeLevels(into: levels, voices: voices) }
    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        opl.takeNotes(pitches: pitches, struck: struck, voices: voices)
    }

    func takeSides(into sides: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< voices { sides[voice] = 0 }
    }

    func setMuted(_ muted: [Bool]) { opl.setMuted(muted) }

    /// The card keeps them, at the chip's rate.
    func keepWaves(in waves: ChannelWaves, first: Int) { opl.keepWaves(in: waves, first: first, channels: voices) }
    var wavesRate: Double { rate }
}

/// An AY-3-8910, or one like it, on the chip siday plays every AY tune on. Its writes are timed to
/// the eighth of a sample, which is how finely the chip is stepped.
final class VGMAY: VGMSoundChip {
    private let chip: UnsafeMutablePointer<AYChip>
    let rate: Double
    var samplesLeft = 0
    var voices: Int { 3 }
    /// True for one heard as a ZX Spectrum's are; otherwise its three channels are all in the middle,
    /// as they were on the machines whose music a VGM file has.
    private let apart: Bool
    /// Where each channel's output is kept for its scope, once asked, and which voice the first is.
    private var waves: ChannelWaves?
    private var wavesFrom = 0

    init(type: UInt8, flags: UInt8, clock: Double) {
        apart = flags & 0x80 != 0
        chip = .allocate(capacity: 1)
        chip.initialize(to: AYChip(type: type >= 0x10 ? .ym : .ay, clockHz: clock, sampleRate: outputSampleRate, stereo: apart ? .abc : .mono))
        rate = chip.pointee.innerRate
        chip.pointee.reset()
    }

    deinit {
        chip.deinitialize(count: 1)
        chip.deallocate()
    }

    func reset() {
        chip.pointee.reset()
        samplesLeft = 0
    }

    func write(_ register: Int, _ value: UInt8) { chip.pointee.write(register, value) }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int, after: Int) -> Int {
        var made = 0
        let keeping = waves != nil
        while made < frames, samplesLeft > 0 {
            samplesLeft -= 1
            guard chip.pointee.innerStep() else { continue }
            let (left, right) = chip.pointee.finishSample()
            if keeping { keepWaves(at: made) }
            let remaining = samplesLeft + after
            let level = remaining < fade ? gain * Float(remaining) / Float(fade) : gain
            buffer[made * 2] = Float(left) * level
            buffer[made * 2 + 1] = Float(right) * level
            made += 1
        }
        if let waves { for voice in wavesFrom ..< wavesFrom + 3 { waves.advance(voice, by: made) } }
        return made
    }

    func keepWaves(in waves: ChannelWaves, first: Int) {
        self.waves = waves
        wavesFrom = first
        // A channel at its loudest goes between the bottom and the top of the DAC's table.
        for voice in first ..< first + 3 { waves.setVoice(voice, rate: Double(outputSampleRate), fullSwing: 0.5) }
    }

    /// Keeps what each channel puts out now, so many samples on from the last made before. (Out of
    /// the way of the chip's own steps, which are quicker for it.)
    @inline(never)
    private func keepWaves(at offset: Int) {
        guard let waves else { return }
        let (a, b, c) = chip.pointee.channelOutputs()
        waves.store(wavesFrom, at: offset, a)
        waves.store(wavesFrom + 1, at: offset, b)
        waves.store(wavesFrom + 2, at: offset, c)
    }

    func takeLevels(into levels: UnsafeMutablePointer<Float>) { chip.pointee.takeLevels(into: levels) }
    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        chip.pointee.takeNotes(pitches: pitches, struck: struck)
    }

    func takeSides(into sides: UnsafeMutablePointer<Float>) {
        if apart { chip.pointee.sides(into: sides) } else { for voice in 0 ..< 3 { sides[voice] = 0 } }
    }

    func setMuted(_ muted: [Bool]) {
        func left(_ voice: Int) -> Bool { voice < muted.count && muted[voice] }
        chip.pointee.setMuted(left(0), left(1), left(2))
    }
}

/// A DAC: a sample's eight bits at a time, each heard until the next, as a Sound Blaster played them,
/// and through the same filter on the card's board as its FM chip (see `OPLCard`), which takes out
/// what is steady: what the DAC is left at when a sound ends. The file has them written to a
/// YM2612's, whose DAC is heard in place of its sixth FM voice: its eight bits (register 0x2A), on or
/// off (0x2B), and its sides (that voice's, 0xB6 of the second set).
final class VGMDAC: VGMSoundChip {
    private let output: UnsafeMutablePointer<ChipOversampler>
    let rate = ChipOversampler.innerRate
    var samplesLeft = 0
    var voices: Int { 1 }
    var sampled: Bool { true }
    private var value = 0x80
    private var on = false
    private var left = true, right = true
    private var muted = false
    /// For the lights: the lowest and highest it has been in what it has made since this was last
    /// asked, and whether a sound has been started.
    private var low: Float = .infinity, high: Float = -.infinity
    private var started = false
    // The filter: 3.18 Hz, at the rate of the player.
    private static let b1 = exp(-2.0 * Double.pi * 3.18309886184 / Double(outputSampleRate))
    private var steadyLeft = 0.0, steadyRight = 0.0
    /// Where its output is kept for its scope, once asked, and which voice it is.
    private var waves: ChannelWaves?
    private var wavesFrom = 0

    init() {
        output = .allocate(capacity: 1)
        output.initialize(to: ChipOversampler(chipRate: ChipOversampler.innerRate, stereo: true))
    }

    deinit {
        output.deinitialize(count: 1)
        output.deallocate()
    }

    func reset() {
        output.pointee = ChipOversampler(chipRate: ChipOversampler.innerRate, stereo: true)
        samplesLeft = 0
        value = 0x80
        on = false
        left = true
        right = true
        low = .infinity
        high = -.infinity
        started = false
        steadyLeft = 0
        steadyRight = 0
    }

    /// - Parameter register: the YM2612's, the second set's with 0x100 added.
    func write(_ register: Int, _ value: UInt8) {
        switch register {
        case 0x2A:
            self.value = Int(value)
        case 0x2B:
            on = value & 0x80 != 0
        case 0x1B6:
            left = value & 0x80 != 0
            right = value & 0x40 != 0
        default:
            break
        }
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int, after: Int) -> Int {
        let level = on && !muted ? Double(value - 0x80) / 128 : 0
        let both = (left ? level : 0, right ? level : 0)
        // (For its scope: what it puts out before it is put on a side, as it is if it is muted too.)
        let out = on ? Float(value - 0x80) / 128 : 0
        var made = 0
        let waves = waves, wavesFrom = wavesFrom
        while made < frames, samplesLeft > 0 {
            samplesLeft -= 1
            guard output.pointee.innerStep({ both }) else { continue }
            waves?.store(wavesFrom, at: made, out)
            var (l, r) = output.pointee.finishSample()
            steadyLeft = l * (1 - Self.b1) + steadyLeft * Self.b1
            steadyRight = r * (1 - Self.b1) + steadyRight * Self.b1
            l -= steadyLeft
            r -= steadyRight
            let remaining = samplesLeft + after
            let scale = remaining < fade ? gain * Float(remaining) / Float(fade) : gain
            buffer[made * 2] = Float(l) * scale
            buffer[made * 2 + 1] = Float(r) * scale
            made += 1
        }
        waves?.advance(wavesFrom, by: made)
        if made > 0 {
            low = min(low, out)
            high = max(high, out)
        }
        return made
    }

    /// How far it has swung since this was last asked, where 1 is from the bottom of its eight bits
    /// to the top: so a DAC left at one level, which makes no sound, is dark. (One left out of the
    /// sound is as it would be heard.)
    func takeLevels(into levels: UnsafeMutablePointer<Float>) {
        levels[0] = high > low ? (high - low) * 0.5 : 0
        low = .infinity
        high = -.infinity
    }

    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        pitches[0] = 0
        struck[0] = started
        started = false
    }

    func takeSides(into sides: UnsafeMutablePointer<Float>) {
        sides[0] = left == right ? 0 : left ? -1 : 1
    }

    func setMuted(_ muted: [Bool]) { self.muted = muted.first ?? false }

    func soundStarted() { started = true }

    func keepWaves(in waves: ChannelWaves, first: Int) {
        self.waves = waves
        wavesFrom = first
        // Its eight bits go from the bottom to the top.
        waves.setVoice(first, rate: Double(outputSampleRate), fullSwing: 1)
    }
}

/// An SN76489, or one of the chips made like it, as the file says. Its writes are timed to the
/// eighth of a sample, as the AY chip's are, and what it makes is filtered as the DAC's is.
final class VGMSN: VGMSoundChip {
    private var chip: SN76489Chip
    private let output: UnsafeMutablePointer<ChipOversampler>
    private let chipRate: Double, stereo: Bool, clock: Double
    let rate = ChipOversampler.innerRate
    var samplesLeft = 0
    var voices: Int { 4 }
    private static let b1 = exp(-2.0 * Double.pi * 3.18309886184 / Double(outputSampleRate))
    private var steadyLeft = 0.0, steadyRight = 0.0
    /// Where each channel's output is kept for its scope, once asked, and which voice the first is.
    private var waves: ChannelWaves?
    private var wavesFrom = 0

    init(_ variant: SN76489Variant, clock: Double) {
        chip = SN76489Chip(variant)
        self.clock = clock
        chipRate = clock / Double(2 * variant.divider)
        stereo = variant.stereo
        output = .allocate(capacity: 1)
        output.initialize(to: ChipOversampler(chipRate: chipRate, stereo: stereo))
    }

    deinit {
        output.deinitialize(count: 1)
        output.deallocate()
    }

    func reset() {
        chip.reset()
        output.pointee = ChipOversampler(chipRate: chipRate, stereo: stereo)
        samplesLeft = 0
        steadyLeft = 0
        steadyRight = 0
    }

    /// - Parameter register: 0 for the chip's one port, 1 for the Game Gear's sides.
    func write(_ register: Int, _ value: UInt8) {
        if register == 0 { chip.write(value) } else { chip.writeStereo(value) }
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int, after: Int) -> Int {
        var made = 0
        let keeping = waves != nil
        while made < frames, samplesLeft > 0 {
            samplesLeft -= 1
            guard output.pointee.innerStep({ chip.step() }) else { continue }
            if keeping { keepWaves(at: made) }
            var (l, r) = output.pointee.finishSample()
            // (What is steady is taken out, as on the card's board: what a channel playing samples
            // on its volume is left at.)
            steadyLeft = l * (1 - Self.b1) + steadyLeft * Self.b1
            steadyRight = r * (1 - Self.b1) + steadyRight * Self.b1
            l -= steadyLeft
            r -= steadyRight
            let remaining = samplesLeft + after
            let scale = remaining < fade ? gain * Float(remaining) / Float(fade) : gain
            buffer[made * 2] = Float(l) * scale
            buffer[made * 2 + 1] = Float(r) * scale
            made += 1
        }
        if let waves { for voice in wavesFrom ..< wavesFrom + 4 { waves.advance(voice, by: made) } }
        return made
    }

    func takeLevels(into levels: UnsafeMutablePointer<Float>) { chip.takeLevels(into: levels) }
    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        chip.takeNotes(pitches: pitches, struck: struck, clock: clock)
    }

    func takeSides(into sides: UnsafeMutablePointer<Float>) { chip.sides(into: sides) }

    func setMuted(_ muted: [Bool]) {
        for channel in 0 ..< 4 { chip.muted[channel] = channel < muted.count && muted[channel] }
    }

    func keepWaves(in waves: ChannelWaves, first: Int) {
        self.waves = waves
        wavesFrom = first
        // A channel at its loudest swings a whole either side of nought, before the chip halves it.
        for voice in first ..< first + 4 { waves.setVoice(voice, rate: Double(outputSampleRate), fullSwing: 1) }
    }

    /// Keeps what each channel puts out now, so many samples on from the last made before. (Out of
    /// the way of the chip's own steps, which are quicker for it.)
    @inline(never)
    private func keepWaves(at offset: Int) {
        guard let waves else { return }
        for channel in 0 ..< 4 { waves.store(wavesFrom + channel, at: offset, Float(chip.channelOutput(channel))) }
    }
}

/// An SAA1099. It is stepped at its clock over 128, as libvgm steps it, which is fast enough for its
/// fastest noise; its writes are timed to the eighth of a sample, and what it makes is filtered as
/// the DAC's is.
final class VGMSAA: VGMSoundChip {
    private var chip: SAA1099Chip
    private let output: UnsafeMutablePointer<ChipOversampler>
    private let clock: Double, chipRate: Double
    let rate = ChipOversampler.innerRate
    var samplesLeft = 0
    var voices: Int { 6 }
    private static let b1 = exp(-2.0 * Double.pi * 3.18309886184 / Double(outputSampleRate))
    private var steadyLeft = 0.0, steadyRight = 0.0
    /// Where each channel's output is kept for its scope, once asked, and which voice the first is.
    private var waves: ChannelWaves?
    private var wavesFrom = 0

    init(clock: Double) {
        self.clock = clock
        chipRate = clock / 128
        chip = SAA1099Chip(clock: clock, rate: chipRate)
        output = .allocate(capacity: 1)
        output.initialize(to: ChipOversampler(chipRate: chipRate, stereo: true))
    }

    deinit {
        output.deinitialize(count: 1)
        output.deallocate()
    }

    func reset() {
        chip.reset()
        output.pointee = ChipOversampler(chipRate: chipRate, stereo: true)
        samplesLeft = 0
        steadyLeft = 0
        steadyRight = 0
    }

    /// A register's number and what is written to it: the chip is given the one and then the other.
    func write(_ register: Int, _ value: UInt8) {
        chip.writeAddress(UInt8(register & 0xFF))
        chip.writeData(value)
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int, after: Int) -> Int {
        var made = 0
        let keeping = waves != nil
        while made < frames, samplesLeft > 0 {
            samplesLeft -= 1
            guard output.pointee.innerStep({ chip.step() }) else { continue }
            if keeping { keepWaves(at: made) }
            var (l, r) = output.pointee.finishSample()
            // (What is steady is taken out, as on the card's board: the chip's levels are all above nought.)
            steadyLeft = l * (1 - Self.b1) + steadyLeft * Self.b1
            steadyRight = r * (1 - Self.b1) + steadyRight * Self.b1
            l -= steadyLeft
            r -= steadyRight
            let remaining = samplesLeft + after
            let scale = remaining < fade ? gain * Float(remaining) / Float(fade) : gain
            buffer[made * 2] = Float(l) * scale
            buffer[made * 2 + 1] = Float(r) * scale
            made += 1
        }
        if let waves { for voice in wavesFrom ..< wavesFrom + 6 { waves.advance(voice, by: made) } }
        return made
    }

    func takeLevels(into levels: UnsafeMutablePointer<Float>) { chip.takeLevels(into: levels) }
    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        chip.takeNotes(pitches: pitches, struck: struck, clock: clock)
    }

    func takeSides(into sides: UnsafeMutablePointer<Float>) { chip.sides(into: sides) }

    func setMuted(_ muted: [Bool]) {
        for channel in 0 ..< 6 { chip.muted[channel] = channel < muted.count && muted[channel] }
    }

    func keepWaves(in waves: ChannelWaves, first: Int) {
        self.waves = waves
        wavesFrom = first
        // A channel at its loudest swings 240 either side of nought.
        for voice in first ..< first + 6 { waves.setVoice(voice, rate: Double(outputSampleRate), fullSwing: 240) }
    }

    /// Keeps what each channel puts out now, so many samples on from the last made before. (Out of
    /// the way of the chip's own steps, which are quicker for it.)
    @inline(never)
    private func keepWaves(at offset: Int) {
        guard let waves else { return }
        for channel in 0 ..< 6 { waves.store(wavesFrom + channel, at: offset, Float(chip.channelOutput(channel))) }
    }
}
