// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its copy of the I3DL2 reverb (`soundlib/plugins/dmo/I3DL2Reverb.cpp`).

import SidayFoundation

/// OpenMPT's copy of the DirectX reverb whose settings are those of the "I3DL2" guidelines for the
/// sound of rooms in games: a room that is so large, so lively and so muffled.
///
/// The sound is dulled by the room's filter and goes into two long delays, one for each side. A handful
/// of taps from each makes the early reflections. One more tap from each, crossed with the other's,
/// feeds the late reverberation, which is a chain of "all-pass" delays for each side, every one with a
/// filter that lets the high notes die sooner: two (or, at the better qualities, four), then a delay
/// of a hundredth of a second, then two more, the last of which goes round to the start again.
///
/// The thirteen settings are the room's level and that of its high notes, each from -100 dB to none; a
/// roll-off that does nothing; the time the reverberation takes to die, from a tenth of a second to
/// twenty, and the high notes' share of that, from a tenth to twice; the level of the early reflections
/// (-100 to +10 dB) and how long they are in coming (up to 0.3 s); the level of the late reverberation
/// (-100 to +20 dB) and how long after the reflections it comes (up to 0.1 s); the diffusion and the
/// density, each up to all of it; the frequency that counts as high, from 20 Hz to 20 kHz; and the
/// quality, which is one of four: its first bit asks for the two extra delays on each side, and its
/// second for the reverb to be worked at the full sample rate and not at half of it.
///
/// At half the rate the reverb takes every other sample in and puts out each of its own twice, the
/// first time averaged with the one before. A change of setting is taken up at the start of the next
/// stretch of sound that is asked for, and a change between the full rate and the half empties the delays.
///
/// Two of OpenMPT's oddities are kept. The two extra delays of the early reflections are three
/// milliseconds long and are asked for taps of 3.25 and 3.53 milliseconds, which wrap round to a
/// quarter and a half of one. And of the two levels that are added up to set the loudness of the late
/// reverberation, one stage's are given each to the other side's sum.
final class OpenMPTI3DL2Reverb: OpenMPTEffect {
    private static let kI3DL2ReverbRoom = 0, kI3DL2ReverbRoomHF = 1, kI3DL2ReverbRoomRolloffFactor = 2 // Doesn't actually do anything :)
    private static let kI3DL2ReverbDecayTime = 3, kI3DL2ReverbDecayHFRatio = 4, kI3DL2ReverbReflections = 5, kI3DL2ReverbReflectionsDelay = 6
    private static let kI3DL2ReverbReverb = 7, kI3DL2ReverbReverbDelay = 8, kI3DL2ReverbDiffusion = 9, kI3DL2ReverbDensity = 10
    private static let kI3DL2ReverbHFReference = 11, kI3DL2ReverbQuality = 12
    private static let kI3DL2ReverbNumParameters = 13

    private static let kMoreDelayLines: UInt32 = 0x01, kFullSampleRate: UInt32 = 0x02

    /// A delay: the sound is written at `position`, which goes backwards a sample at a time, and read
    /// from `delayPosition`, which is always so many samples after it.
    private struct DelayLine {
        var buffer: UnsafeMutablePointer<Float>
        var length = 0
        var position = 0
        var delayPosition = 0
    }

    private static let lineCount = 19
    /// How long each delay is in milliseconds, and how many samples more. The thirteenth is a dummy,
    /// there so that the delays, their taps and their coefficients are numbered alike.
    private static let lineMilliseconds: [Int32] = [67, 62, 53, 43, 32, 22, 75, 69, 60, 48, 36, 25, 0, 3, 3, 407, 400, 10, 10]
    private static let linePadding: [Int32] = [5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, 0, 0, 1, 1, 0, 0]

    /// How far along the delay each early reflection is, as a part of the reverb's delay.
    private static let delays: [Float] = [
        1.0000, 1.0000, 0.0000, 0.1078, 0.1768, 0.2727,
        0.3953, 0.5386, 0.6899, 0.8306, 0.9400, 0.9800,
    ]

    /// How much shorter each delay of the late reverberation is than the first: 0.93 to the powers 0, 1,
    /// 3, 6, 10 and 15, in single precision and rounded to the nearest. OpenMPT asks the C library for
    /// these (`std::pow(0.93f, power)`) and they come out as they are here; they are written down
    /// because the lengths of the delays are cut from them, and a library that rounded one of them the
    /// other way could make a delay a sample shorter.
    private static let shortening: [Float] = [
        Float(bitPattern: 0x3F80_0000), Float(bitPattern: 0x3F6E_147B), Float(bitPattern: 0x3F4D_EA57),
        Float(bitPattern: 0x3F25_A127), Float(bitPattern: 0x3EF7_CC89), Float(bitPattern: 0x3EAC_640F),
    ]

    private var m_param: [Float] = [0.9, 0.99, 0.0, 0.07, 0.3842105, 0.672545433, 0.233333333, 0.85, 0.11, 1.0, 1.0, (5000.0 - 20.0) / 19980.0, 2.0 / 3.0]

    // Calculated parameters
    private var m_quality: UInt32 = 0
    private var m_effectiveSampleRate: Float = 0
    private var m_diffusion: Float = 0
    private var m_roomFilter: Float = 0
    private var m_ERLevel: Float = 0
    private var m_ReverbLevelL: Float = 0
    private var m_ReverbLevelR: Float = 0

    private var m_delayTaps = [Int32](repeating: 0, count: 15) // 6*L + 6*R + LR + Early L + Early R
    private var m_earlyTaps = [Int32](repeating: 0, count: 12) // two rows of six: left, right
    /// The early taps again, each brought within the length of its delay, for the loop that plays them.
    private let earlyOffsets: UnsafeMutablePointer<Int>
    private let m_delayCoeffs: UnsafeMutablePointer<Float> // thirteen pairs

    // State
    private let m_delayLines: UnsafeMutablePointer<DelayLine>
    /// The memory of all the delays, end to end, with room for each at the full sample rate.
    private let storage: UnsafeMutablePointer<Float>
    private let m_filterHist: UnsafeMutablePointer<Float>

    // Remaining frame for downsampled reverb
    private var m_prevL: Float = 0
    private var m_prevR: Float = 0
    private var m_remain = false

    private var m_ok = false, m_recalcParams = true

    override init() {
        var total = 0
        var starts = [Int](repeating: 0, count: Self.lineCount)
        for d in 0 ..< Self.lineCount {
            starts[d] = total
            total += max(Self.lineLength(d, sampleRate: UInt32(truncatingIfNeeded: outputSampleRate)), 0)
        }
        storage = .allocate(capacity: max(total, 1))
        storage.initialize(repeating: 0, count: max(total, 1))
        m_delayLines = .allocate(capacity: Self.lineCount)
        for d in 0 ..< Self.lineCount {
            (m_delayLines + d).initialize(to: DelayLine(buffer: storage + starts[d]))
        }
        m_filterHist = .allocate(capacity: Self.lineCount)
        m_filterHist.initialize(repeating: 0, count: Self.lineCount)
        m_delayCoeffs = .allocate(capacity: 26)
        m_delayCoeffs.initialize(repeating: 0, count: 26)
        earlyOffsets = .allocate(capacity: 12)
        earlyOffsets.initialize(repeating: 0, count: 12)
        super.init()
    }

    deinit {
        storage.deallocate()
        m_delayLines.deallocate()
        m_filterHist.deallocate()
        m_delayCoeffs.deallocate()
        earlyOffsets.deallocate()
    }

    override var parameterCount: Int { Self.kI3DL2ReverbNumParameters }

    override func parameter(_ index: Int) -> Float {
        index >= 0 && index < Self.kI3DL2ReverbNumParameters ? m_param[index] : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.kI3DL2ReverbNumParameters else { return }
        var value = OpenMPTDMO.unit(value)
        if index == Self.kI3DL2ReverbQuality {
            value = (value * 3.0).rounded(.toNearestOrAwayFromZero) / 3.0
        }
        m_param[index] = value
        m_recalcParams = true
    }

    override func resume() {
        RecalculateI3DL2ReverbParams()
        PositionChanged()
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        if m_recalcParams {
            let sampleRate = m_effectiveSampleRate
            RecalculateI3DL2ReverbParams()
            // Resize and clear delay lines if quality has changed
            if sampleRate != m_effectiveSampleRate { PositionChanged() }
        }

        guard frames > 0 else { return }
        guard m_ok else {
            outLeft.update(repeating: 0, count: frames)
            outRight.update(repeating: 0, count: frames)
            return
        }

        let full = (m_quality & Self.kFullSampleRate) != 0
        let more = (m_quality & Self.kMoreDelayLines) != 0
        var i = 0
        var remaining = frames
        if !full, m_remain {
            // Remaining frame from previous render call
            remaining -= 1
            outLeft[0] = m_prevL
            outRight[0] = m_prevR
            i = 1
            m_remain = false
        }

        let lines = m_delayLines, hist = m_filterHist, coeffs = m_delayCoeffs, early = earlyOffsets
        let roomFilter = m_roomFilter, diffusion = m_diffusion, ERLevel = m_ERLevel, ReverbLevelL = m_ReverbLevelL, ReverbLevelR = m_ReverbLevelR
        let c0a = coeffs[0], c0b = coeffs[1], c1a = coeffs[2], c1b = coeffs[3], c2a = coeffs[4], c2b = coeffs[5], c3a = coeffs[6], c3b = coeffs[7]
        let c4a = coeffs[8], c4b = coeffs[9], c5a = coeffs[10], c5b = coeffs[11], c6a = coeffs[12], c6b = coeffs[13], c7a = coeffs[14], c7b = coeffs[15]
        let c8a = coeffs[16], c8b = coeffs[17], c9a = coeffs[18], c9b = coeffs[19], c10a = coeffs[20], c10b = coeffs[21], c11a = coeffs[22], c11b = coeffs[23]
        let c12a = coeffs[24], c12b = coeffs[25]
        var hist0 = hist[0], hist1 = hist[1], hist2 = hist[2], hist3 = hist[3], hist4 = hist[4], hist5 = hist[5]
        var hist6 = hist[6], hist7 = hist[7], hist8 = hist[8], hist9 = hist[9], hist10 = hist[10], hist11 = hist[11]
        var hist12 = hist[12], hist13 = hist[13], hist15 = hist[15], hist16 = hist[16], hist17 = hist[17], hist18 = hist[18]
        var prevL = m_prevL, prevR = m_prevR

        // OpenMPT moves every delay's two places back by one after every sample, and wraps each when it
        // comes to nought. Here the sound is worked in runs that stop short of the next wrap of any of
        // them, so that within a run every place is so many samples before where it was at the run's
        // start, and the places are moved once, at its end. The samples and their sums are the same.
        while remaining > 0 {
            var run = full ? remaining : (remaining &+ 1) >> 1
            for d in 0 ..< 12 { run = min(run, Self.room(lines + d)) }
            if more {
                run = min(run, Self.room(lines + 13))
                run = min(run, Self.room(lines + 14))
            }
            run = min(run, lines[15].position &+ 1)
            run = min(run, lines[16].position &+ 1)
            run = min(run, Self.room(lines + 17))
            run = min(run, Self.room(lines + 18))
            for tap in 0 ..< 6 {
                run = min(run, Self.tapped(lines + 15, early[tap]) &+ 1)
                run = min(run, Self.tapped(lines + 16, early[6 &+ tap]) &+ 1)
            }

            let read0 = Self.reading(lines), write0 = Self.writing(lines)
            let read1 = Self.reading(lines + 1), write1 = Self.writing(lines + 1)
            let read2 = Self.reading(lines + 2), write2 = Self.writing(lines + 2)
            let read3 = Self.reading(lines + 3), write3 = Self.writing(lines + 3)
            let read4 = Self.reading(lines + 4), write4 = Self.writing(lines + 4)
            let read5 = Self.reading(lines + 5), write5 = Self.writing(lines + 5)
            let read6 = Self.reading(lines + 6), write6 = Self.writing(lines + 6)
            let read7 = Self.reading(lines + 7), write7 = Self.writing(lines + 7)
            let read8 = Self.reading(lines + 8), write8 = Self.writing(lines + 8)
            let read9 = Self.reading(lines + 9), write9 = Self.writing(lines + 9)
            let read10 = Self.reading(lines + 10), write10 = Self.writing(lines + 10)
            let read11 = Self.reading(lines + 11), write11 = Self.writing(lines + 11)
            let read13 = Self.reading(lines + 13), write13 = Self.writing(lines + 13)
            let read14 = Self.reading(lines + 14), write14 = Self.writing(lines + 14)
            let write15 = Self.writing(lines + 15), write16 = Self.writing(lines + 16)
            let read17 = Self.reading(lines + 17), write17 = Self.writing(lines + 17)
            let read18 = Self.reading(lines + 18), write18 = Self.writing(lines + 18)
            let buffer15 = lines[15].buffer, buffer16 = lines[16].buffer
            let early00 = buffer15 + Self.tapped(lines + 15, early[0]), early01 = buffer15 + Self.tapped(lines + 15, early[1])
            let early02 = buffer15 + Self.tapped(lines + 15, early[2]), early03 = buffer15 + Self.tapped(lines + 15, early[3])
            let early04 = buffer15 + Self.tapped(lines + 15, early[4]), early05 = buffer15 + Self.tapped(lines + 15, early[5])
            let early10 = buffer16 + Self.tapped(lines + 16, early[6]), early11 = buffer16 + Self.tapped(lines + 16, early[7])
            let early12 = buffer16 + Self.tapped(lines + 16, early[8]), early13 = buffer16 + Self.tapped(lines + 16, early[9])
            let early14 = buffer16 + Self.tapped(lines + 16, early[10]), early15 = buffer16 + Self.tapped(lines + 16, early[11])

            for j in 0 ..< run {
                // Apply room filter and insert into early reflection delay lines
                let inL = inLeft[i]
                let inRoomL = (hist12 - inL) * roomFilter + inL
                hist12 = inRoomL
                (write15 - j).pointee = inRoomL

                let inR = inRight[i]
                let inRoomR = (hist13 - inR) * roomFilter + inR
                hist13 = inRoomR
                (write16 - j).pointee = inRoomR

                // Early reflections (left)
                var earlyL = (early01 - j).pointee * 0.68
                    - (early02 - j).pointee * 0.5
                    - (early03 - j).pointee * 0.62
                    - (early04 - j).pointee * 0.5
                    - (early05 - j).pointee * 0.62
                if more {
                    let earlyL2 = earlyL
                    earlyL = (read13 - j).pointee + earlyL * 0.618034
                    (write13 - j).pointee = earlyL2 - earlyL * 0.618034
                }
                let earlyRefOutL = earlyL * ERLevel
                hist15 = (early00 - j).pointee + hist15
                hist16 = (early10 - j).pointee + hist16

                // Lots of slightly different copy-pasta ahead
                var reverbL1: Float, reverbL2: Float, reverbL3: Float, reverbR1: Float, reverbR2: Float, reverbR3: Float

                reverbL1 = -hist15 * 0.707
                reverbL2 = hist16 * 0.707 + reverbL1
                reverbR2 = reverbL1 - hist16 * 0.707

                reverbL1 = Self.allpass(read5 - j, write5 - j, &hist5, c5a, c5b, reverbL2, diffusion)
                reverbL2 = reverbL1
                reverbL3 = -0.15 * reverbL1

                reverbL1 = Self.allpass(read4 - j, write4 - j, &hist4, c4a, c4b, reverbL2, diffusion)
                reverbL2 = reverbL1
                reverbL3 -= reverbL1 * 0.2

                if more {
                    reverbL1 = Self.allpass(read3 - j, write3 - j, &hist3, c3a, c3b, reverbL2, diffusion)
                    reverbL2 = reverbL1
                    reverbL3 += 0.35 * reverbL1

                    reverbL1 = Self.allpass(read2 - j, write2 - j, &hist2, c2a, c2b, reverbL2, diffusion)
                    reverbL2 = reverbL1
                    reverbL3 -= reverbL1 * 0.38
                }
                (write17 - j).pointee = reverbL2

                reverbL1 = (read17 - j).pointee * c12a
                hist17 = (hist17 - reverbL1) * c12b + reverbL1

                reverbL1 = Self.allpass(read1 - j, write1 - j, &hist1, c1a, c1b, hist17, diffusion)
                reverbL2 = reverbL1
                let reverbL4 = reverbL1 * 0.38

                reverbL1 = Self.allpass(read0 - j, write0 - j, &hist0, c0a, c0b, reverbL2, diffusion)
                reverbL3 -= reverbL1 * 0.38
                hist15 = reverbL1

                // Early reflections (right)
                var earlyR = (early11 - j).pointee * 0.707
                    - (early12 - j).pointee * 0.6
                    - (early13 - j).pointee * 0.5
                    - (early14 - j).pointee * 0.6
                    - (early15 - j).pointee * 0.5
                if more {
                    let earlyR2 = earlyR
                    earlyR = (read14 - j).pointee + earlyR * 0.618034
                    (write14 - j).pointee = earlyR2 - earlyR * 0.618034
                }
                let earlyRefOutR = earlyR * ERLevel

                reverbR1 = Self.allpass(read11 - j, write11 - j, &hist11, c11a, c11b, reverbR2, diffusion)
                reverbR2 = reverbR1

                reverbR1 = Self.allpass(read10 - j, write10 - j, &hist10, c10a, c10b, reverbR2, diffusion)
                reverbR3 = reverbL4 - reverbR2 * 0.15 - reverbR1 * 0.2
                reverbR2 = reverbR1

                if more {
                    reverbR1 = Self.allpass(read9 - j, write9 - j, &hist9, c9a, c9b, reverbR2, diffusion)
                    reverbR2 = reverbR1
                    reverbR3 += reverbR1 * 0.35

                    reverbR1 = Self.allpass(read8 - j, write8 - j, &hist8, c8a, c8b, reverbR2, diffusion)
                    reverbR2 = reverbR1
                    reverbR3 -= reverbR1 * 0.38
                }
                (write18 - j).pointee = reverbR2

                reverbR1 = (read18 - j).pointee * c12a
                hist18 = (hist18 - reverbR1) * c12b + reverbR1

                reverbR1 = Self.allpass(read7 - j, write7 - j, &hist7, c7a, c7b, hist18, diffusion)
                reverbR2 = reverbR1

                let lateRevOutL = (reverbL3 + reverbR1 * 0.38) * ReverbLevelL

                reverbR1 = Self.allpass(read6 - j, write6 - j, &hist6, c6a, c6b, reverbR2, diffusion)
                hist16 = reverbR1

                let lateRevOutR = (reverbR3 - reverbR1 * 0.38) * ReverbLevelR

                let outL = earlyRefOutL + lateRevOutL
                let outR = earlyRefOutR + lateRevOutR

                if !full {
                    outLeft[i] = (outL + prevL) * 0.5
                    outRight[i] = (outR + prevR) * 0.5
                    prevL = outL
                    prevR = outR
                    i &+= 1
                    remaining &-= 1
                    // An odd frame at the end: its second half is put out first thing next time.
                    if remaining == 0 {
                        m_remain = true
                        break
                    }
                }
                outLeft[i] = outL
                outRight[i] = outR
                i &+= 1
                remaining &-= 1
            }

            for d in 0 ..< Self.lineCount where d != 12 { Self.retreat(lines + d, run) }
        }

        hist[0] = hist0
        hist[1] = hist1
        hist[2] = hist2
        hist[3] = hist3
        hist[4] = hist4
        hist[5] = hist5
        hist[6] = hist6
        hist[7] = hist7
        hist[8] = hist8
        hist[9] = hist9
        hist[10] = hist10
        hist[11] = hist11
        hist[12] = hist12
        hist[13] = hist13
        hist[15] = hist15
        hist[16] = hist16
        hist[17] = hist17
        hist[18] = hist18
        m_prevL = prevL
        m_prevR = prevR
    }

    /// One all-pass delay of the late reverberation: what comes out of the delay is filtered, mixed with
    /// what goes in to make what comes out of the stage, and that less a part of itself goes into the delay.
    @inline(__always) private static func allpass(_ read: UnsafeMutablePointer<Float>, _ write: UnsafeMutablePointer<Float>, _ hist: inout Float,
                                                  _ gain: Float, _ damping: Float, _ input: Float, _ diffusion: Float) -> Float
    {
        let delayed = read.pointee
        hist = (hist - delayed) * damping + delayed
        let output = hist * gain + input * diffusion
        write.pointee = input - output * diffusion
        return output
    }

    /// How many samples a delay can be worked for before either of its places wraps.
    @inline(__always) private static func room(_ line: UnsafeMutablePointer<DelayLine>) -> Int {
        min(line.pointee.position, line.pointee.delayPosition) &+ 1
    }

    @inline(__always) private static func reading(_ line: UnsafeMutablePointer<DelayLine>) -> UnsafeMutablePointer<Float> {
        line.pointee.buffer + line.pointee.delayPosition
    }

    @inline(__always) private static func writing(_ line: UnsafeMutablePointer<DelayLine>) -> UnsafeMutablePointer<Float> {
        line.pointee.buffer + line.pointee.position
    }

    /// Where in a delay the sample so far after the newest is, for an `offset` less than the delay's length.
    @inline(__always) private static func tapped(_ line: UnsafeMutablePointer<DelayLine>, _ offset: Int) -> Int {
        let index = offset &+ line.pointee.position
        return index >= line.pointee.length ? index &- line.pointee.length : index
    }

    /// A delay's two places moved back by `count` samples, which is OpenMPT's `Advance` that many times.
    @inline(__always) private static func retreat(_ line: UnsafeMutablePointer<DelayLine>, _ count: Int) {
        let length = line.pointee.length
        var position = line.pointee.position &- count
        if position < 0 { position = modulo(Int64(position), length) }
        line.pointee.position = position
        var delayPosition = line.pointee.delayPosition &- count
        if delayPosition < 0 { delayPosition = modulo(Int64(delayPosition), length) }
        line.pointee.delayPosition = delayPosition
    }

    private static func lineLength(_ index: Int, sampleRate: UInt32) -> Int {
        // The dummy has no length at any rate.
        if index == 12 { return 0 }
        let length = Int64(Int32(truncatingIfNeeded: sampleRate)) * Int64(lineMilliseconds[index]) / 1000 + Int64(linePadding[index])
        return Int(max(min(length, Int64(Int32.max)), 0))
    }

    /// A number cut to a whole one as a C cast does it, for numbers that are never negative.
    private static func toInt32(_ value: Float) -> Int32 {
        Int32(truncatingIfNeeded: min(OpenMPTDMO.truncate(value), 0x7FFF_FFFF))
    }

    private func Init(_ index: Int, sampleRate: UInt32, delayTap: Int32) {
        let line = m_delayLines + index
        line.pointee.length = Self.lineLength(index, sampleRate: sampleRate)
        line.pointee.position = 0
        SetDelayTap(index, delayTap)
        line.pointee.buffer.update(repeating: 0, count: line.pointee.length)
    }

    private func SetDelayTap(_ index: Int, _ delayTap: Int32) {
        let line = m_delayLines + index
        let length = line.pointee.length
        if length > 0 {
            line.pointee.delayPosition = Self.modulo(Int64(delayTap) + Int64(line.pointee.position) + Int64(length), length)
        }
    }

    /// The remainder that is never negative; `length` is more than nought.
    private static func modulo(_ value: Int64, _ length: Int) -> Int {
        let remainder = Int(value % Int64(length))
        return remainder < 0 ? remainder + length : remainder
    }

    private func PositionChanged() {
        m_filterHist.update(repeating: 0, count: Self.lineCount)
        m_prevL = 0
        m_prevR = 0
        m_remain = false

        let sampleRate = OpenMPTDMO.truncate(m_effectiveSampleRate)
        var ok = true
        for d in 0 ..< Self.lineCount where d != 12 {
            // A rate above the one the memory was laid out for cannot come about, and is refused if it does.
            if Self.lineLength(d, sampleRate: sampleRate) > Self.lineLength(d, sampleRate: UInt32(truncatingIfNeeded: outputSampleRate)) { ok = false }
        }
        guard ok else {
            m_ok = false
            return
        }
        for d in 0 ..< Self.lineCount {
            let delayTap: Int32 = d == 12 || d == 15 || d == 16 ? 0 : (d >= 17 ? -1 : m_delayTaps[d])
            Init(d, sampleRate: sampleRate, delayTap: delayTap)
            if d != 12, m_delayLines[d].length <= 0 { ok = false }
        }
        reduceEarlyTaps()
        m_ok = ok
    }

    private func Room() -> Float { -10000.0 + m_param[Self.kI3DL2ReverbRoom] * 10000.0 }
    private func RoomHF() -> Float { -10000.0 + m_param[Self.kI3DL2ReverbRoomHF] * 10000.0 }
    private func DecayTime() -> Float { 0.1 + m_param[Self.kI3DL2ReverbDecayTime] * 19.9 }
    private func DecayHFRatio() -> Float { 0.1 + m_param[Self.kI3DL2ReverbDecayHFRatio] * 1.9 }
    private func Reflections() -> Float { -10000.0 + m_param[Self.kI3DL2ReverbReflections] * 11000.0 }
    private func ReflectionsDelay() -> Float { m_param[Self.kI3DL2ReverbReflectionsDelay] * 0.3 }
    private func Reverb() -> Float { -10000.0 + m_param[Self.kI3DL2ReverbReverb] * 12000.0 }
    private func ReverbDelay() -> Float { m_param[Self.kI3DL2ReverbReverbDelay] * 0.1 }
    private func Diffusion() -> Float { m_param[Self.kI3DL2ReverbDiffusion] * 100.0 }
    private func Density() -> Float { m_param[Self.kI3DL2ReverbDensity] * 100.0 }
    private func HFReference() -> Float { 20.0 + m_param[Self.kI3DL2ReverbHFReference] * 19980.0 }
    private func Quality() -> UInt32 { OpenMPTDMO.saturateRound(m_param[Self.kI3DL2ReverbQuality] * 3.0) }

    private func RecalculateI3DL2ReverbParams() {
        m_quality = Quality()
        m_effectiveSampleRate = Float(UInt32(truncatingIfNeeded: outputSampleRate) / ((m_quality & Self.kFullSampleRate) != 0 ? 1 : 2))

        // Diffusion
        m_diffusion = Diffusion() * (0.618034 / 100.0)
        // Early Reflection Level
        m_ERLevel = Self.atMostOne(powf(10.0, (Room() + Reflections()) / (100.0 * 20.0))) * 0.761

        // Room Filter
        let roomHF = powf(10.0, RoomHF() / 100.0 / 10.0)
        if roomHF == 1.0 {
            m_roomFilter = 0.0
        } else {
            let cosine = cosf(HFReference() * (2.0 * OpenMPTDMO.pi) / m_effectiveSampleRate)
            let freq: Float = 0.9999 < cosine ? 0.9999 : cosine
            let roomFilter: Float = (freq * (roomHF + roomHF) - 2.0 + (freq * (roomHF * roomHF * freq * 4.0) + roomHF * 8.0 - roomHF * roomHF * 4.0 - roomHF * freq * 8.0).squareRoot()) / (roomHF + roomHF - 2.0)
            m_roomFilter = roomFilter < 0.0 ? 0.0 : (roomFilter > 1.0 ? 1.0 : roomFilter)
        }

        SetDelayTaps()
        SetDecayCoeffs()

        m_recalcParams = false
    }

    private static func atMostOne(_ value: Float) -> Float { 1.0 < value ? 1.0 : value }

    private func SetDelayTaps() {
        // Early reflections
        let sampleRate = m_effectiveSampleRate
        let reflectionsDelay = ReflectionsDelay()
        let shortest: Float = 5.0 / 1000.0
        let reverbDelay = ReverbDelay() < shortest ? shortest : ReverbDelay()
        let seven: Float = 7.0 / 1000.0
        m_earlyTaps[0] = Self.toInt32((reverbDelay + reflectionsDelay + seven) * sampleRate)
        for i in 1 ..< 12 {
            m_earlyTaps[(i % 2) * 6 + i / 2] = Self.toInt32((reverbDelay * Self.delays[i] + reflectionsDelay) * sampleRate)
        }

        // Late reflections
        let density = Self.atMostOne((Density() / 100.0 + 0.1) * 0.9091)
        let delayL: Float = density * 67.0 / 1000.0 * sampleRate
        let delayR: Float = density * 75.0 / 1000.0 * sampleRate
        for i in 0 ..< 6 {
            let factor = Self.shortening[i]
            m_delayTaps[i + 0] = Self.toInt32(delayL * factor)
            m_delayTaps[i + 6] = Self.toInt32(delayR * factor)
        }
        let ten: Float = 10.0 / 1000.0
        m_delayTaps[12] = Self.toInt32(ten * sampleRate)
        // Early reflections (extra delay lines)
        let first: Float = 3.25 / 1000.0, second: Float = 3.53 / 1000.0
        m_delayTaps[13] = Self.toInt32(first * sampleRate)
        m_delayTaps[14] = Self.toInt32(second * sampleRate)

        for d in 0 ..< 15 { SetDelayTap(d, m_delayTaps[d]) }
        reduceEarlyTaps()
    }

    /// The early taps brought within the lengths of the two long delays they are read from, which is
    /// where OpenMPT's delay would wrap them to each time it is read.
    private func reduceEarlyTaps() {
        for side in 0 ..< 2 {
            let length = m_delayLines[15 + side].length
            for tap in 0 ..< 6 {
                earlyOffsets[side * 6 + tap] = length > 0 ? Self.modulo(Int64(m_earlyTaps[side * 6 + tap]), length) : 0
            }
        }
    }

    private func SetDecayCoeffs() {
        var levelLtmp: Float = 1.0, levelRtmp: Float = 1.0
        var levelL: Float = 0.0, levelR: Float = 0.0

        levelLtmp *= CalcDecayCoeffs(5)
        levelRtmp *= CalcDecayCoeffs(11)
        levelL += levelLtmp * 0.0225
        levelR += levelRtmp * 0.0225

        levelLtmp *= CalcDecayCoeffs(4)
        levelRtmp *= CalcDecayCoeffs(10)
        levelL += levelLtmp * 0.04
        levelR += levelRtmp * 0.04

        if (m_quality & Self.kMoreDelayLines) != 0 {
            levelLtmp *= CalcDecayCoeffs(3)
            levelRtmp *= CalcDecayCoeffs(9)
            levelL += levelLtmp * 0.1225
            levelR += levelRtmp * 0.1225

            levelLtmp *= CalcDecayCoeffs(2)
            levelRtmp *= CalcDecayCoeffs(8)
            levelL += levelLtmp * 0.1444
            levelR += levelRtmp * 0.1444
        }
        _ = CalcDecayCoeffs(12)
        levelLtmp *= m_delayCoeffs[24] * m_delayCoeffs[24]
        levelRtmp *= m_delayCoeffs[24] * m_delayCoeffs[24]

        levelLtmp *= CalcDecayCoeffs(1)
        levelRtmp *= CalcDecayCoeffs(7)
        levelL += levelRtmp * 0.1444
        levelR += levelLtmp * 0.1444

        levelLtmp *= CalcDecayCoeffs(0)
        levelRtmp *= CalcDecayCoeffs(6)
        levelL += levelLtmp * 0.1444
        levelR += levelRtmp * 0.1444

        // Final Reverb Level
        let level = Self.atMostOne(powf(10.0, (Room() + Reverb()) / (100.0 * 20.0)))
        let monoInv: Float = 1.0 - ((levelLtmp + levelRtmp) * 0.5)
        m_ReverbLevelL = level * (monoInv / levelL).squareRoot()
        m_ReverbLevelR = level * (monoInv / levelR).squareRoot()
    }

    private func CalcDecayCoeffs(_ index: Int) -> Float {
        var hfRef: Float = (2.0 * OpenMPTDMO.pi) / m_effectiveSampleRate * HFReference()
        let decayHFRatio = DecayHFRatio()
        if decayHFRatio > 1.0 { hfRef = OpenMPTDMO.pi }

        var c1 = powf(10.0, ((Float(m_delayTaps[index]) / m_effectiveSampleRate) * -60.0 / DecayTime()) / 20.0)
        var c2: Float = 0.0

        let c21: Float = (powf(c1, 2.0 - 2.0 / decayHFRatio) - 1.0) / (1.0 - cosf(hfRef))
        if c21 != 0, c21.isFinite {
            let c22: Float = -2.0 * c21 - 2.0
            let c23sq: Float = c22 * c22 - c21 * c21 * 4.0
            let c23: Float = c23sq > 0.0 ? c23sq.squareRoot() : 0.0
            c2 = (c23 - c22) / (c21 + c21)
            if c2.magnitude > 1.0 { c2 = (-c22 - c23) / (c21 + c21) }
            if c2.isNaN { c2 = 0 }
        }
        m_delayCoeffs[index * 2] = c1
        m_delayCoeffs[index * 2 + 1] = c2

        c1 *= c1
        let diff2 = m_diffusion * m_diffusion
        return diff2 + c1 / (1.0 - diff2 * c1) * (1.0 - diff2) * (1.0 - diff2)
    }
}
