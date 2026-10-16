// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

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
    var card: OPLCard? { nil }

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
        while made < frames, samplesLeft > 0 {
            samplesLeft -= 1
            guard chip.pointee.innerStep() else { continue }
            let (left, right) = chip.pointee.finishSample()
            let remaining = samplesLeft + after
            let level = remaining < fade ? gain * Float(remaining) / Float(fade) : gain
            buffer[made * 2] = Float(left) * level
            buffer[made * 2 + 1] = Float(right) * level
            made += 1
        }
        return made
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
