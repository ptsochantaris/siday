// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ayumi, Copyright (c) Peter Sovietov, used under the MIT licence (see THIRD-PARTY.md).
//
// AY-3-8910 / YM2149 emulation. A Swift port of ayumi by Peter Sovietov (MIT licence),
// restructured so register writes can land between the eight oversampled steps of an output sample.

private let ayDAC: [Double] = [
    0.0, 0.0,
    0.00999465934234, 0.00999465934234,
    0.0144502937362, 0.0144502937362,
    0.0210574502174, 0.0210574502174,
    0.0307011520562, 0.0307011520562,
    0.0455481803616, 0.0455481803616,
    0.0644998855573, 0.0644998855573,
    0.107362478065, 0.107362478065,
    0.126588845655, 0.126588845655,
    0.20498970016, 0.20498970016,
    0.292210269322, 0.292210269322,
    0.372838941024, 0.372838941024,
    0.492530708782, 0.492530708782,
    0.635324635691, 0.635324635691,
    0.805584802014, 0.805584802014,
    1.0, 1.0,
]

private let ymDAC: [Double] = [
    0.0, 0.0,
    0.00465400167849, 0.00772106507973,
    0.0109559777218, 0.0139620050355,
    0.0169985503929, 0.0200198367285,
    0.024368657969, 0.029694056611,
    0.0350652323186, 0.0403906309606,
    0.0485389486534, 0.0583352407111,
    0.0680552376593, 0.0777752346075,
    0.0925154497597, 0.111085679408,
    0.129747463188, 0.148485542077,
    0.17666895552, 0.211551079576,
    0.246387426566, 0.281101701381,
    0.333730067903, 0.400427252613,
    0.467383840696, 0.53443198291,
    0.635172045472, 0.75800717174,
    0.879926756695, 1.0,
]

// Envelope segment actions, indexed by shape * 2 + segment.
// 0 slide down, 1 slide up, 2 hold bottom, 3 hold top; two bits per entry.
private let envSlideDown = 0, envSlideUp = 1, envHoldTop = 3
private let envelopeActionBits: UInt64 = {
    let actions: [UInt64] = [
        0, 2, 0, 2, 0, 2, 0, 2,
        1, 2, 1, 2, 1, 2, 1, 2,
        0, 0, 0, 2, 0, 1, 0, 3,
        1, 1, 1, 3, 1, 0, 1, 2,
    ]
    var packed: UInt64 = 0
    for (i, a) in actions.enumerated() { packed |= a << UInt64(i * 2) }
    return packed
}()

let ayDecimate = 8
let ayFIRSize = 192
private let dcFilterSize = 1024

struct AYToneChannel {
    var period = 1
    var counter = 0
    var tone = 0
    var toneOff = 0
    var noiseOff = 0
    /// For the lights: the places in the DAC table the channel has been at of late, a bit for each.
    var levelsSeen: UInt32 = 0
    /// Where its volume stood when its notes were last asked for: a jump up from there is a note.
    var levelWas = 0
    var envelopeOn = false
    var volume = 0
    var panLeft = 0.5
    var panRight = 0.5
}

/// One chip. Its tables and its filters' memory are part of it, some 26 KB in all, so it is not to be
/// copied: it is made once, where it will stay, and worked on there.
struct AYChip: ~Copyable {
    var a = AYToneChannel(), b = AYToneChannel(), c = AYToneChannel()
    var noisePeriod = 1
    var noiseCounter = 0
    var noise = 1
    var envelopeCounter = 0
    var envelopePeriod = 1
    var envelopeShape = 0
    var envelopeSegment = 0
    var envelope = 0
    private(set) var registers = InlineArray<14, UInt8>(repeating: 0)

    private let actionBits = envelopeActionBits
    private let dac: InlineArray<32, Double>
    private let fir: InlineArray<192, Double> // all 192 coefficients; the first is zero
    private var step: Double
    private var x = 0.0
    private var cl0 = 0.0, cl1 = 0.0, cl2 = 0.0, yl0 = 0.0, yl1 = 0.0, yl2 = 0.0, yl3 = 0.0
    private var cr0 = 0.0, cr1 = 0.0, cr2 = 0.0, yr0 = 0.0, yr1 = 0.0, yr2 = 0.0, yr3 = 0.0
    private var firLeft = InlineArray<384, Double>(repeating: 0)
    private var firRight = InlineArray<384, Double>(repeating: 0)
    private var firIndex = 0
    private var firBase = 0
    private var inner = 0
    private var dcLeft = InlineArray<1024, Double>(repeating: 0)
    private var dcRight = InlineArray<1024, Double>(repeating: 0)
    private var dcSumLeft = 0.0, dcSumRight = 0.0
    private var dcIndex = 0
    var removeDC = true
    /// True when every channel is equally loud in both ears: the right output is then the left one, and
    /// only the left is worked out.
    private var mono = false

    /// Oversampled steps per second: writes can be timed to this resolution.
    let innerRate: Double
    private let clockHz: Double
    /// True if an envelope that plays once has been started since the notes were last asked for.
    private var envelopeStruck = false

    init(type: AYChipType, clockHz: Double, sampleRate: Int, stereo: StereoLayout) {
        let table = type == .ym ? ymDAC : ayDAC
        dac = InlineArray { table[$0] }
        fir = InlineArray { ayFIRHalf[$0 <= 96 ? $0 : ayFIRSize - $0] }
        innerRate = Double(sampleRate * ayDecimate)
        self.clockHz = clockHz
        step = clockHz / (Double(sampleRate) * 8 * Double(ayDecimate))
        setStereo(stereo)
    }

    private mutating func setStereo(_ layout: StereoLayout) {
        // Channel levels follow Ay_Emul's defaults (255/13 for the side channels, 170/170 for the centre).
        func pan(_ ch: inout AYToneChannel, _ left: Double, _ right: Double) {
            ch.panLeft = left / 255
            ch.panRight = right / 255
        }
        switch layout {
        case .abc: pan(&a, 255, 13); pan(&b, 170, 170); pan(&c, 13, 255)
        case .acb: pan(&a, 255, 13); pan(&c, 170, 170); pan(&b, 13, 255)
        // Mono: every channel equally in both ears, at a level that peaks where the stereo layouts do.
        case .mono: pan(&a, 146, 146); pan(&b, 146, 146); pan(&c, 146, 146)
        }
        mono = a.panLeft == a.panRight && b.panLeft == b.panRight && c.panLeft == c.panRight
    }

    mutating func reset() {
        for r in 0 ..< 14 { write(r, 0) }
        noise = 1
        noiseCounter = 0
        a.counter = 0; b.counter = 0; c.counter = 0
        a.tone = 0; b.tone = 0; c.tone = 0
    }

    // Inlined, like `tonePeriod` below: called out of line, a method that only reads the chip is
    // handed a copy of all of it.
    @inline(__always) func read(_ reg: Int) -> UInt8 {
        registers[reg & 15 < 14 ? reg & 15 : 0]
    }

    mutating func write(_ reg: Int, _ value: UInt8) {
        let r = reg & 15
        guard r < 14 else { return }
        registers[r] = value
        let v = Int(value)
        switch r {
        case 0, 1: a.period = tonePeriod(0)
        case 2, 3: b.period = tonePeriod(2)
        case 4, 5: c.period = tonePeriod(4)
        case 6:
            let p = v & 0x1F
            noisePeriod = p == 0 ? 1 : p
        case 7:
            a.toneOff = v & 1; b.toneOff = (v >> 1) & 1; c.toneOff = (v >> 2) & 1
            a.noiseOff = (v >> 3) & 1; b.noiseOff = (v >> 4) & 1; c.noiseOff = (v >> 5) & 1
        case 8: a.volume = v & 15; a.envelopeOn = v & 16 != 0
        case 9: b.volume = v & 15; b.envelopeOn = v & 16 != 0
        case 10: c.volume = v & 15; c.envelopeOn = v & 16 != 0
        case 11, 12:
            let p = Int(read(11)) | Int(read(12)) << 8
            envelopePeriod = p == 0 ? 1 : p
        default: // 13
            envelopeShape = v & 15
            // (The shapes that go round are tones in themselves, and not the striking of a note.)
            if !(envelopeShape >= 8 && envelopeShape & 1 == 0) { envelopeStruck = true }
            envelopeCounter = 0
            envelopeSegment = 0
            resetSegment()
        }
    }

    @inline(__always) private func tonePeriod(_ r: Int) -> Int {
        let p = (Int(read(r)) | Int(read(r + 1)) << 8) & 0xFFF
        return p == 0 ? 1 : p
    }

    @inline(__always) private var envelopeAction: Int {
        Int((actionBits &>> UInt64(truncatingIfNeeded: (envelopeShape &* 2 &+ envelopeSegment) &* 2)) & 3)
    }

    private mutating func resetSegment() {
        let action = envelopeAction
        envelope = (action == envSlideDown || action == envHoldTop) ? 31 : 0
    }

    @inline(__always) private static func tone(_ ch: inout AYToneChannel) -> Int {
        ch.counter &+= 1
        if ch.counter >= ch.period {
            ch.counter = 0
            ch.tone ^= 1
        }
        return ch.tone
    }

    @inline(__always) private mutating func updateMixer() -> (Double, Double) {
        noiseCounter &+= 1
        if noiseCounter >= noisePeriod &<< 1 {
            noiseCounter = 0
            let bit = (noise ^ (noise &>> 3)) & 1
            noise = (noise &>> 1) | (bit &<< 16)
        }
        let n = noise & 1

        envelopeCounter &+= 1
        if envelopeCounter >= envelopePeriod {
            envelopeCounter = 0
            switch envelopeAction {
            case envSlideUp:
                envelope &+= 1
                if envelope > 31 {
                    envelopeSegment ^= 1
                    resetSegment()
                }
            case envSlideDown:
                envelope &-= 1
                if envelope < 0 {
                    envelopeSegment ^= 1
                    resetSegment()
                }
            default:
                break
            }
        }
        let e = envelope

        // Each channel's level is its place in the DAC table when its tone and noise gates are open, else 0.
        let outA = (0 &- ((Self.tone(&a) | a.toneOff) & (n | a.noiseOff))) & (a.envelopeOn ? e : a.volume &* 2 &+ 1)
        let outB = (0 &- ((Self.tone(&b) | b.toneOff) & (n | b.noiseOff))) & (b.envelopeOn ? e : b.volume &* 2 &+ 1)
        let outC = (0 &- ((Self.tone(&c) | c.toneOff) & (n | c.noiseOff))) & (c.envelopeOn ? e : c.volume &* 2 &+ 1)
        a.levelsSeen |= 1 &<< UInt32(truncatingIfNeeded: outA)
        b.levelsSeen |= 1 &<< UInt32(truncatingIfNeeded: outB)
        c.levelsSeen |= 1 &<< UInt32(truncatingIfNeeded: outC)
        let levelA = dac[unchecked: outA], levelB = dac[unchecked: outB], levelC = dac[unchecked: outC]
        let left = levelA * a.panLeft + levelB * b.panLeft + levelC * c.panLeft
        if mono { return (left, left) }
        return (left, levelA * a.panRight + levelB * b.panRight + levelC * c.panRight)
    }

    /// How far each channel has swung since this was last asked, where 1 is from silence to full volume.
    mutating func takeLevels(into levels: UnsafeMutablePointer<Float>) {
        func level(_ ch: inout AYToneChannel) -> Float {
            var seen = ch.levelsSeen
            ch.levelsSeen = 0
            // A tone of a period under six is above 18 kHz, and is not heard as a tone: tunes use one
            // to hold a channel open while they play samples on its volume. Its silences do not count.
            if ch.period < 6, ch.toneOff == 0, ch.noiseOff != 0 { seen &= ~1 }
            guard seen != 0 else { return 0 }
            return Float(dac[31 - seen.leadingZeroBitCount] - dac[seen.trailingZeroBitCount])
        }
        levels[0] = level(&a)
        levels[1] = level(&b)
        levels[2] = level(&c)
    }

    /// Each channel's pitch now, and whether a note has been struck on it since this was last asked.
    /// A channel's pitch is its tone's; or, with no tone, the pitch of an envelope that goes round,
    /// which is how this chip is made to play a bass. The chip has no way to start a note, so a note
    /// is taken to be struck when a channel's volume jumps up, or an envelope that plays once starts.
    mutating func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        let clockHz = clockHz, envelopePeriod = envelopePeriod
        // Shapes 8 and 12 go round every 32 steps, and 10 and 14 there and back in 64.
        let envelopeSteps = envelopeShape == 8 || envelopeShape == 12 ? 32 : envelopeShape == 10 || envelopeShape == 14 ? 64 : 0
        let retriggered = envelopeStruck
        envelopeStruck = false
        func read(_ ch: inout AYToneChannel) -> (Float, Bool) {
            let level = ch.envelopeOn ? 31 : ch.volume > 0 ? ch.volume &* 2 &+ 1 : 0
            var pitch: Float = 0
            if level > 0 {
                if ch.toneOff == 0, ch.period >= 6 {
                    pitch = ChannelPitch.note(ofHz: clockHz / Double(16 * ch.period))
                } else if ch.envelopeOn, envelopeSteps > 0 {
                    pitch = ChannelPitch.note(ofHz: clockHz / Double(8 * envelopeSteps * envelopePeriod))
                }
            }
            let hit = level >= ch.levelWas + 5 || (retriggered && ch.envelopeOn)
            ch.levelWas = level
            return (pitch, hit)
        }
        (pitches[0], struck[0]) = read(&a)
        (pitches[1], struck[1]) = read(&b)
        (pitches[2], struck[2]) = read(&c)
    }

    /// Advances one oversampled step. `extra` is added to both channels before decimation (beeper).
    /// Returns true when this step completed an output sample, which is then read with `finishSample()`.
    @inline(__always) mutating func innerStep(extra: Double = 0) -> Bool {
        if inner == 0 {
            firBase = ayFIRSize &- firIndex &* ayDecimate
            firIndex = firIndex == ayFIRSize / ayDecimate - 2 ? 0 : firIndex &+ 1
        }
        x += step
        if x >= 1 {
            x -= 1
            let (left, right) = updateMixer()
            yl0 = yl1; yl1 = yl2; yl2 = yl3; yl3 = left
            var y1 = yl2 - yl0
            cl0 = 0.5 * yl1 + 0.25 * (yl0 + yl2)
            cl1 = 0.5 * y1
            cl2 = 0.25 * (yl3 - yl1 - y1)
            if !mono {
                yr0 = yr1; yr1 = yr2; yr2 = yr3; yr3 = right
                y1 = yr2 - yr0
                cr0 = 0.5 * yr1 + 0.25 * (yr0 + yr2)
                cr1 = 0.5 * y1
                cr2 = 0.25 * (yr3 - yr1 - y1)
            }
        }
        let slot = firBase &+ (ayDecimate - 1 &- inner)
        firLeft[unchecked: slot] = (cl2 * x + cl1) * x + cl0 + extra
        if !mono { firRight[unchecked: slot] = (cr2 * x + cr1) * x + cr0 + extra }
        inner &+= 1
        if inner == ayDecimate {
            inner = 0
            return true
        }
        return false
    }

    /// The taps come as a span of the chip's own, and not as the array: an array handed over beside the
    /// history it is used on is copied first, every time.
    @inline(__always) private static func decimate(_ history: inout InlineArray<384, Double>, from base: Int, taps: RawSpan) -> Double {
        // Eight doubles at a time into two running sums, so the additions are sixteen short chains
        // side by side and not one long one.
        let width = MemoryLayout<SIMD8<Double>>.size
        let start = base &* MemoryLayout<Double>.size
        var even = SIMD8<Double>.zero, odd = SIMD8<Double>.zero
        do {
            let input = history.span.bytes
            var offset = 0
            while offset < ayFIRSize * MemoryLayout<Double>.size {
                even += taps.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD8<Double>.self)
                    * input.unsafeLoadUnaligned(fromUncheckedByteOffset: start &+ offset, as: SIMD8<Double>.self)
                odd += taps.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ width, as: SIMD8<Double>.self)
                    * input.unsafeLoadUnaligned(fromUncheckedByteOffset: start &+ offset &+ width, as: SIMD8<Double>.self)
                offset &+= width &* 2
            }
        }
        for i in 0 ..< ayDecimate {
            history[unchecked: base &+ ayFIRSize &- ayDecimate &+ i] = history[unchecked: base &+ i]
        }
        return (even + odd).sum()
    }

    /// Output of the sample completed by the last `innerStep`.
    @inline(__always) mutating func finishSample() -> (Double, Double) {
        var left = Self.decimate(&firLeft, from: firBase, taps: fir.span.bytes)
        if mono {
            if removeDC {
                dcSumLeft += left - dcLeft[unchecked: dcIndex]
                dcLeft[unchecked: dcIndex] = left
                left -= dcSumLeft / Double(dcFilterSize)
                dcIndex = (dcIndex + 1) & (dcFilterSize - 1)
            }
            return (left, left)
        }
        var right = Self.decimate(&firRight, from: firBase, taps: fir.span.bytes)
        if removeDC {
            dcSumLeft += left - dcLeft[unchecked: dcIndex]
            dcLeft[unchecked: dcIndex] = left
            left -= dcSumLeft / Double(dcFilterSize)
            dcSumRight += right - dcRight[unchecked: dcIndex]
            dcRight[unchecked: dcIndex] = right
            right -= dcSumRight / Double(dcFilterSize)
            dcIndex = (dcIndex + 1) & (dcFilterSize - 1)
        }
        return (left, right)
    }

    /// Renders one whole output sample with no mid-sample writes.
    @inline(__always) mutating func sample() -> (Double, Double) {
        while !innerStep() {}
        return finishSample()
    }
}
