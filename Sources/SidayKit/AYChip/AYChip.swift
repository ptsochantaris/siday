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
    var envelopeOn = false
    var volume = 0
    var panLeft = 0.5
    var panRight = 0.5
}

/// One chip. It owns its buffers and frees them when it goes, so there is only ever the one of it.
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
    private(set) var registers: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    private let actionBits = envelopeActionBits
    private let dac: UnsafeMutablePointer<Double>
    private let fir: UnsafeMutablePointer<Double> // all 192 coefficients; the first is zero
    private var step: Double
    private var x = 0.0
    private var cl0 = 0.0, cl1 = 0.0, cl2 = 0.0, yl0 = 0.0, yl1 = 0.0, yl2 = 0.0, yl3 = 0.0
    private var cr0 = 0.0, cr1 = 0.0, cr2 = 0.0, yr0 = 0.0, yr1 = 0.0, yr2 = 0.0, yr3 = 0.0
    private let firLeft: UnsafeMutablePointer<Double>
    private let firRight: UnsafeMutablePointer<Double>
    private var firIndex = 0
    private var firBase = 0
    private var inner = 0
    private let dcLeft: UnsafeMutablePointer<Double>
    private let dcRight: UnsafeMutablePointer<Double>
    private var dcSumLeft = 0.0, dcSumRight = 0.0
    private var dcIndex = 0
    var removeDC = true
    /// True when every channel is equally loud in both ears: the right output is then the left one, and
    /// only the left is worked out.
    private var mono = false

    /// Oversampled steps per second: writes can be timed to this resolution.
    let innerRate: Double

    init(type: AYChipType, clockHz: Double, sampleRate: Int, stereo: StereoLayout) {
        dac = .allocate(capacity: 32)
        let table = type == .ym ? ymDAC : ayDAC
        for i in 0 ..< 32 { dac[i] = table[i] }
        fir = .allocate(capacity: ayFIRSize)
        for i in 0 ..< ayFIRSize { fir[i] = ayFIRHalf[i <= 96 ? i : ayFIRSize - i] }
        firLeft = .allocate(capacity: ayFIRSize * 2)
        firLeft.initialize(repeating: 0, count: ayFIRSize * 2)
        firRight = .allocate(capacity: ayFIRSize * 2)
        firRight.initialize(repeating: 0, count: ayFIRSize * 2)
        dcLeft = .allocate(capacity: dcFilterSize)
        dcLeft.initialize(repeating: 0, count: dcFilterSize)
        dcRight = .allocate(capacity: dcFilterSize)
        dcRight.initialize(repeating: 0, count: dcFilterSize)
        innerRate = Double(sampleRate * ayDecimate)
        step = clockHz / (Double(sampleRate) * 8 * Double(ayDecimate))
        setStereo(stereo)
    }

    deinit {
        dac.deallocate()
        fir.deallocate()
        firLeft.deallocate()
        firRight.deallocate()
        dcLeft.deallocate()
        dcRight.deallocate()
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

    func read(_ reg: Int) -> UInt8 {
        withUnsafeBytes(of: registers) { $0[reg & 15 < 14 ? reg & 15 : 0] }
    }

    mutating func write(_ reg: Int, _ value: UInt8) {
        let r = reg & 15
        guard r < 14 else { return }
        withUnsafeMutableBytes(of: &registers) { $0[r] = value }
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
            envelopeCounter = 0
            envelopeSegment = 0
            resetSegment()
        }
    }

    private func tonePeriod(_ r: Int) -> Int {
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
        let levelA = dac[outA], levelB = dac[outB], levelC = dac[outC]
        let left = levelA * a.panLeft + levelB * b.panLeft + levelC * c.panLeft
        if mono { return (left, left) }
        return (left, levelA * a.panRight + levelB * b.panRight + levelC * c.panRight)
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
        firLeft[slot] = (cl2 * x + cl1) * x + cl0 + extra
        if !mono { firRight[slot] = (cr2 * x + cr1) * x + cr0 + extra }
        inner &+= 1
        if inner == ayDecimate {
            inner = 0
            return true
        }
        return false
    }

    @inline(__always) private func decimate(_ buf: UnsafeMutablePointer<Double>) -> Double {
        // Eight doubles at a time into two running sums, so the additions are sixteen short chains
        // side by side and not one long one.
        let taps = UnsafeRawPointer(fir), input = UnsafeRawPointer(buf)
        let width = MemoryLayout<SIMD8<Double>>.size
        var even = SIMD8<Double>.zero, odd = SIMD8<Double>.zero
        var offset = 0
        while offset < ayFIRSize * MemoryLayout<Double>.size {
            even += taps.loadUnaligned(fromByteOffset: offset, as: SIMD8<Double>.self)
                * input.loadUnaligned(fromByteOffset: offset, as: SIMD8<Double>.self)
            odd += taps.loadUnaligned(fromByteOffset: offset + width, as: SIMD8<Double>.self)
                * input.loadUnaligned(fromByteOffset: offset + width, as: SIMD8<Double>.self)
            offset += width * 2
        }
        (buf + (ayFIRSize - ayDecimate)).update(from: buf, count: ayDecimate)
        return (even + odd).sum()
    }

    /// Output of the sample completed by the last `innerStep`.
    @inline(__always) mutating func finishSample() -> (Double, Double) {
        var left = decimate(firLeft + firBase)
        if mono {
            if removeDC {
                dcSumLeft += left - dcLeft[dcIndex]
                dcLeft[dcIndex] = left
                left -= dcSumLeft / Double(dcFilterSize)
                dcIndex = (dcIndex + 1) & (dcFilterSize - 1)
            }
            return (left, left)
        }
        var right = decimate(firRight + firBase)
        if removeDC {
            dcSumLeft += left - dcLeft[dcIndex]
            dcLeft[dcIndex] = left
            left -= dcSumLeft / Double(dcFilterSize)
            dcSumRight += right - dcRight[dcIndex]
            dcRight[dcIndex] = right
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
