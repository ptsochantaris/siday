// Copyright (C) 2003-2009 Dean Beeler, Jerome Fisher; (C) 2011-2024 Dean Beeler, Jerome Fisher, Sergey V. Mikayev
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Swift port of mt32emu's model of the LA32 chip: its ramps (LA32Ramp.cpp) and its wave generators and
// partial pairs with integer samples (LA32WaveGenerator.cpp), from Munt's libmt32emu 2.8.3, free software
// under the GNU Lesser General Public License, version 2.1 or any later version (see THIRD-PARTY.md).

/// A ramp of the LA32: a smooth change of an amplitude or a filter's cutoff to a target, at a speed, at the
/// end of which the chip tells the controller so (an interrupt). The controller sets the target (0 to 255)
/// and the speed: its top bit the direction (set for down), its other seven how fast; a speed of nought
/// changes nothing and never ends. A ramp starts from wherever the last one left the value.
struct LA32Ramp {
    private static let targetShifts: UInt32 = 18
    private static let maxCurrent: UInt32 = 0xFF << targetShifts
    /// Samples between a ramp's reaching its target and the controller's hearing of it (mt32emu's choice,
    /// from captures).
    private static let interruptTime = 7

    private var current: UInt32 = 0
    private var largeTarget: UInt32 = 0
    private var largeIncrement: UInt32 = 0
    private var descending = false
    private var interruptCountdown = 0
    private var interruptRaised = false

    mutating func startRamp(_ target: UInt8, _ increment: UInt8) {
        if increment == 0 {
            largeIncrement = 0
        } else {
            // 2^(((increment & 0x7F) + 24) / 8) + 1/8, from the chip's own table of exponents.
            let expArg = UInt32(increment & 0x7F)
            largeIncrement = 8191 - UInt32(MT32Tables.exp9[Int(~(expArg << 6) & 511)])
            largeIncrement <<= expArg >> 3
            largeIncrement += 64
            largeIncrement >>= 9
        }
        descending = increment & 0x80 != 0
        // (Downward ramps are a little faster, from captures.)
        if descending { largeIncrement += 1 }
        largeTarget = UInt32(target) << Self.targetShifts
        interruptCountdown = 0
        interruptRaised = false
    }

    @inline(__always)
    mutating func nextValue() -> UInt32 {
        if interruptCountdown > 0 {
            interruptCountdown -= 1
            if interruptCountdown == 0 { interruptRaised = true }
        } else if largeIncrement != 0 {
            if descending {
                if largeIncrement > current {
                    current = largeTarget
                    interruptCountdown = Self.interruptTime
                } else {
                    current -= largeIncrement
                    if current <= largeTarget {
                        current = largeTarget
                        interruptCountdown = Self.interruptTime
                    }
                }
            } else {
                if Self.maxCurrent - current < largeIncrement {
                    current = largeTarget
                    interruptCountdown = Self.interruptTime
                } else {
                    current += largeIncrement
                    if current >= largeTarget {
                        current = largeTarget
                        interruptCountdown = Self.interruptTime
                    }
                }
            }
        }
        return current
    }

    @inline(__always)
    mutating func checkInterrupt() -> Bool {
        let wasRaised = interruptRaised
        interruptRaised = false
        return wasRaised
    }

    mutating func reset() {
        current = 0
        largeTarget = 0
        largeIncrement = 0
        descending = false
        interruptCountdown = 0
        interruptRaised = false
    }

    /// True if a target is below the value now (beyond what the chip tells the controller; mt32emu's way
    /// of smoothing a sustained note's change of loudness, used only when that is asked for).
    func isBelowCurrent(_ target: UInt8) -> Bool { UInt32(target) << Self.targetShifts < current }
}

/// A sample as the LA32 works with it: the logarithm of its size, as a number to take away (65535 for
/// silence), and its sign.
struct LogSample {
    var logValue: UInt16
    var negative: Bool

    static let silence = LogSample(logValue: 65535, negative: false)
}

/// The LA32's arithmetic in the logarithm's space.
enum LA32Maths {
    @inline(__always)
    static func interpolateExp(_ fract: UInt16) -> UInt16 {
        let index = Int(fract >> 3)
        let extraBits = Int(~fract & 7)
        let entry2 = 8191 - Int(MT32Tables.exp9[index])
        let entry1 = index == 0 ? 8191 : 8191 - Int(MT32Tables.exp9[index - 1])
        return UInt16(truncatingIfNeeded: entry2 + (((entry1 - entry2) * extraBits) >> 3))
    }

    @inline(__always)
    static func unlog(_ sample: LogSample) -> Int16 {
        let intLogValue = sample.logValue >> 12
        let fracLogValue = sample.logValue & 4095
        let value = Int16(truncatingIfNeeded: Int(interpolateExp(fracLogValue)) >> Int(intLogValue))
        return sample.negative ? 0 &- value : value
    }

    @inline(__always)
    static func addLogSamples(_ sample1: inout LogSample, _ sample2: LogSample) {
        let sum = UInt32(sample1.logValue) + UInt32(sample2.logValue)
        sample1.logValue = sum < 65536 ? UInt16(sum) : 65535
        sample1.negative = sample1.negative != sample2.negative
    }
}

/// One of the LA32's wave generators: a square wave made of rising and falling quarter sines with straight
/// parts between them (their lengths set by the pulse width and the filter's cutoff), and a decaying sine
/// beside it for the filter's resonance; a sawtooth is the square multiplied by a cosine of the same
/// period. Or a sample of the PCM ROM, played at a pitch.
struct LA32WaveGenerator {
    private static let sineSegmentRelativeLength: UInt32 = 1 << 18
    private static let middleCutoffValue: UInt32 = 128 << 18
    private static let resonanceDecayThresholdCutoffValue: UInt32 = 144 << 18
    private static let maxCutoffValue: UInt32 = 240 << 18
    private static let resAmpDecayFactors: [UInt32] = [31, 16, 12, 8, 5, 3, 2, 1]

    // The square wave's parts.
    private static let positiveRisingSine = 0, positiveLinear = 1, positiveFallingSine = 2
    private static let negativeFallingSine = 3, negativeLinear = 4, negativeRisingSine = 5
    // The resonance sine's.
    private static let positiveRisingResonance = 0, positiveFallingResonance = 1, negativeFallingResonance = 2, negativeRisingResonance = 3

    private(set) var active = false
    private var sawtoothWaveform = false
    private var amp: UInt32 = 0
    private var pitch: UInt16 = 0
    private var resonance: UInt8 = 0
    private var pulseWidth: UInt8 = 0
    private var cutoffVal: UInt32 = 0
    private var pcmWaveAddress: UnsafePointer<Int16>?
    private var pcmWaveLength: UInt32 = 0
    private var pcmWaveLooped = false
    private var pcmWaveInterpolated = false
    private var wavePosition: UInt32 = 0
    private var squareWavePosition: UInt32 = 0
    private var resonanceSinePosition: UInt32 = 0
    private var resonanceAmpSubtraction: UInt32 = 0
    private var resAmpDecayFactor: UInt32 = 0
    private(set) var pcmInterpolationFactor: UInt32 = 0
    private var phase = 0
    private var resonancePhase = 0
    private var squareLogSample = LogSample.silence
    private var resonanceLogSample = LogSample.silence
    private var firstPCMLogSample = LogSample.silence
    private var secondPCMLogSample = LogSample.silence

    var isPCMWave: Bool { pcmWaveAddress != nil }

    @inline(__always)
    private func sampleStep() -> UInt32 {
        var step = UInt32(LA32Maths.interpolateExp(~pitch & 4095))
        step <<= UInt32(pitch >> 12)
        step >>= 8
        return step & ~1
    }

    @inline(__always)
    private func resonanceWaveLengthFactor(_ effectiveCutoffValue: UInt32) -> UInt32 {
        var factor = UInt32(LA32Maths.interpolateExp(UInt16(truncatingIfNeeded: ~effectiveCutoffValue & 4095)))
        factor <<= effectiveCutoffValue >> 12
        return factor
    }

    @inline(__always)
    private func highLinearLength(_ effectiveCutoffValue: UInt32) -> UInt32 {
        var effectivePulseWidthValue: UInt32 = 0
        if pulseWidth > 128 { effectivePulseWidthValue = UInt32(pulseWidth - 128) << 6 }
        var length: UInt32 = 0
        if effectivePulseWidthValue < effectiveCutoffValue {
            let expArg = effectiveCutoffValue - effectivePulseWidthValue
            length = UInt32(LA32Maths.interpolateExp(UInt16(truncatingIfNeeded: ~expArg & 4095)))
            length <<= 7 + (expArg >> 12)
            length &-= 2 * Self.sineSegmentRelativeLength
        }
        return length
    }

    @inline(__always)
    private mutating func computePositions(_ highLinearLength: UInt32, _ lowLinearLength: UInt32, _ resonanceWaveLengthFactor: UInt32) {
        // (A multiplication of 12 bits, as the chip's.)
        squareWavePosition = (wavePosition >> 8) &* (resonanceWaveLengthFactor >> 4)
        resonanceSinePosition = squareWavePosition
        if squareWavePosition < Self.sineSegmentRelativeLength {
            phase = Self.positiveRisingSine
            return
        }
        squareWavePosition -= Self.sineSegmentRelativeLength
        if squareWavePosition < highLinearLength {
            phase = Self.positiveLinear
            return
        }
        squareWavePosition -= highLinearLength
        if squareWavePosition < Self.sineSegmentRelativeLength {
            phase = Self.positiveFallingSine
            return
        }
        squareWavePosition -= Self.sineSegmentRelativeLength
        resonanceSinePosition = squareWavePosition
        if squareWavePosition < Self.sineSegmentRelativeLength {
            phase = Self.negativeFallingSine
            return
        }
        squareWavePosition -= Self.sineSegmentRelativeLength
        if squareWavePosition < lowLinearLength {
            phase = Self.negativeLinear
            return
        }
        squareWavePosition -= lowLinearLength
        phase = Self.negativeRisingSine
    }

    @inline(__always)
    private mutating func advancePosition() {
        wavePosition &+= sampleStep()
        wavePosition %= 4 * Self.sineSegmentRelativeLength
        let effectiveCutoffValue = cutoffVal > Self.middleCutoffValue ? (cutoffVal - Self.middleCutoffValue) >> 10 : 0
        let factor = resonanceWaveLengthFactor(effectiveCutoffValue)
        let high = highLinearLength(effectiveCutoffValue)
        let low = (factor << 8) &- 4 * Self.sineSegmentRelativeLength &- high
        computePositions(high, low, factor)
        resonancePhase = Int(((resonanceSinePosition >> 18) + (phase > Self.positiveFallingSine ? 2 : 0)) & 3)
    }

    @inline(__always)
    private mutating func generateNextSquareWaveLogSample() {
        var value: UInt32
        switch phase {
        case Self.positiveRisingSine, Self.negativeFallingSine:
            value = UInt32(MT32Tables.logsin9[Int((squareWavePosition >> 9) & 511)])
        case Self.positiveFallingSine, Self.negativeRisingSine:
            value = UInt32(MT32Tables.logsin9[Int(~(squareWavePosition >> 9) & 511)])
        default:
            value = 0
        }
        value <<= 2
        value &+= amp >> 10
        if cutoffVal < Self.middleCutoffValue { value &+= (Self.middleCutoffValue - cutoffVal) >> 9 }
        squareLogSample.logValue = value < 65536 ? UInt16(value) : 65535
        squareLogSample.negative = phase >= Self.negativeFallingSine
    }

    @inline(__always)
    private mutating func generateNextResonanceWaveLogSample() {
        var value: UInt32
        if resonancePhase == Self.positiveFallingResonance || resonancePhase == Self.negativeRisingResonance {
            value = UInt32(MT32Tables.logsin9[Int(~(resonanceSinePosition >> 9) & 511)])
        } else {
            value = UInt32(MT32Tables.logsin9[Int((resonanceSinePosition >> 9) & 511)])
        }
        value <<= 2
        value &+= amp >> 10
        // (The resonance sine decays a little differently in the square's positive and negative halves.)
        let decayFactor = phase < Self.negativeFallingSine ? resAmpDecayFactor : resAmpDecayFactor + 1
        value &+= resonanceAmpSubtraction &+ (((resonanceSinePosition >> 4) &* decayFactor) >> 8)
        // Windows at the resonance sine's start and end, so that the wave has no breaks: a sine, and a
        // square of a sine.
        if phase == Self.positiveRisingSine || phase == Self.negativeFallingSine {
            value &+= UInt32(MT32Tables.logsin9[Int((squareWavePosition >> 9) & 511)]) << 2
        } else if phase == Self.positiveFallingSine || phase == Self.negativeRisingSine {
            value &+= UInt32(MT32Tables.logsin9[Int(~(squareWavePosition >> 9) & 511)]) << 3
        }
        if cutoffVal < Self.middleCutoffValue {
            // Below the middle cutoff, the resonance decays exponentially.
            value &+= 31743 + ((Self.middleCutoffValue - cutoffVal) >> 9)
        } else if cutoffVal < Self.resonanceDecayThresholdCutoffValue {
            // And a little above it, as a sine.
            let sineIx = (cutoffVal - Self.middleCutoffValue) >> 13
            value &+= UInt32(MT32Tables.logsin9[Int(sineIx)]) << 2
        }
        value &-= 1 << 12
        resonanceLogSample.logValue = value < 65536 ? UInt16(value) : 65535
        resonanceLogSample.negative = resonancePhase >= Self.negativeFallingResonance
    }

    @inline(__always)
    private func sawtoothCosineLogSample() -> LogSample {
        let position = wavePosition &+ (1 << 18)
        var value: UInt16
        if position & (1 << 18) > 0 {
            value = MT32Tables.logsin9[Int(~(position >> 9) & 511)]
        } else {
            value = MT32Tables.logsin9[Int((position >> 9) & 511)]
        }
        value <<= 2
        return LogSample(logValue: value, negative: position & (1 << 19) != 0)
    }

    @inline(__always)
    private func pcmSampleToLogSample(_ pcmSample: Int16) -> LogSample {
        var value = UInt32((32787 - (Int(pcmSample) & 32767)) << 1)
        value &+= amp >> 10
        return LogSample(logValue: value < 65536 ? UInt16(value) : 65535, negative: pcmSample < 0)
    }

    @inline(__always)
    private mutating func generateNextPCMWaveLogSamples() {
        guard let pcmWaveAddress else { return }
        // (The interpolation's factor has a bit less than the position: the ladder seen in captures.)
        pcmInterpolationFactor = (wavePosition & 255) >> 1
        var index = wavePosition >> 8
        firstPCMLogSample = pcmSampleToLogSample(pcmWaveAddress[Int(index)])
        if pcmWaveInterpolated {
            index += 1
            if index < pcmWaveLength {
                secondPCMLogSample = pcmSampleToLogSample(pcmWaveAddress[Int(index)])
            } else if pcmWaveLooped {
                index -= pcmWaveLength
                secondPCMLogSample = pcmSampleToLogSample(pcmWaveAddress[Int(index)])
            } else {
                secondPCMLogSample = .silence
            }
        } else {
            secondPCMLogSample = .silence
        }
        // 2^(pitch / 4096 + 3), the position having eight bits of fraction.
        var step = UInt32(LA32Maths.interpolateExp(~pitch & 4095))
        step <<= UInt32(pitch >> 12)
        step >>= 9
        wavePosition &+= step
        if wavePosition >= pcmWaveLength << 8 {
            if pcmWaveLooped {
                wavePosition &-= pcmWaveLength << 8
            } else {
                active = false
            }
        }
    }

    mutating func initSynth(sawtooth: Bool, pulseWidth: UInt8, resonance: UInt8) {
        sawtoothWaveform = sawtooth
        self.pulseWidth = pulseWidth
        self.resonance = resonance
        wavePosition = 0
        squareWavePosition = 0
        phase = Self.positiveRisingSine
        resonanceSinePosition = 0
        resonancePhase = Self.positiveRisingResonance
        resonanceAmpSubtraction = UInt32(truncatingIfNeeded: 32 - Int(resonance)) << 10
        resAmpDecayFactor = Self.resAmpDecayFactors[Int(resonance >> 2)] << 2
        pcmWaveAddress = nil
        active = true
    }

    mutating func initPCM(address: UnsafePointer<Int16>, length: UInt32, looped: Bool, interpolated: Bool) {
        pcmWaveAddress = address
        pcmWaveLength = length
        pcmWaveLooped = looped
        pcmWaveInterpolated = interpolated
        wavePosition = 0
        active = true
    }

    @inline(__always)
    mutating func generateNextSample(amp: UInt32, pitch: UInt16, cutoff: UInt32) {
        guard active else { return }
        self.amp = amp
        self.pitch = pitch
        if isPCMWave {
            generateNextPCMWaveLogSamples()
            return
        }
        // (A cutoff above 240 is as 240, from captures.)
        cutoffVal = cutoff > Self.maxCutoffValue ? Self.maxCutoffValue : cutoff
        generateNextSquareWaveLogSample()
        generateNextResonanceWaveLogSample()
        if sawtoothWaveform {
            let cosine = sawtoothCosineLogSample()
            LA32Maths.addLogSamples(&squareLogSample, cosine)
            LA32Maths.addLogSamples(&resonanceLogSample, cosine)
        }
        advancePosition()
    }

    @inline(__always)
    func outputLogSample(first: Bool) -> LogSample {
        guard active else { return .silence }
        if isPCMWave { return first ? firstPCMLogSample : secondPCMLogSample }
        return first ? squareLogSample : resonanceLogSample
    }

    mutating func deactivate() { active = false }
}

/// A pair of the LA32's partials, played together: each by itself, or the second's sound multiplied by the
/// first's (ring modulation), with or without the first's own sound beside it.
struct LA32PartialPair {
    var master = LA32WaveGenerator()
    var slave = LA32WaveGenerator()
    private var ringModulated = false
    private var mixed = false

    mutating func initialise(ringModulated: Bool, mixed: Bool) {
        self.ringModulated = ringModulated
        self.mixed = mixed
    }

    mutating func initSynth(slave isSlave: Bool, sawtooth: Bool, pulseWidth: UInt8, resonance: UInt8) {
        if isSlave {
            slave.initSynth(sawtooth: sawtooth, pulseWidth: pulseWidth, resonance: resonance)
        } else {
            master.initSynth(sawtooth: sawtooth, pulseWidth: pulseWidth, resonance: resonance)
        }
    }

    mutating func initPCM(slave isSlave: Bool, address: UnsafePointer<Int16>, length: UInt32, looped: Bool) {
        if isSlave {
            // (A ring-modulated PCM partial is not interpolated, from captures.)
            slave.initPCM(address: address, length: length, looped: looped, interpolated: !ringModulated)
        } else {
            master.initPCM(address: address, length: length, looped: looped, interpolated: true)
        }
    }

    @inline(__always)
    private static func unlogAndMix(_ wg: LA32WaveGenerator) -> Int16 {
        guard wg.active else { return 0 }
        let first = LA32Maths.unlog(wg.outputLogSample(first: true))
        let second = LA32Maths.unlog(wg.outputLogSample(first: false))
        if wg.isPCMWave {
            return Int16(truncatingIfNeeded: Int(first) + (((Int(second) - Int(first)) * Int(wg.pcmInterpolationFactor)) >> 7))
        }
        return first &+ second
    }

    /// A sample past 8191 either way wraps round as it does in the chip's multiplier.
    @inline(__always)
    private static func distorted(_ sample: Int16) -> Int16 {
        sample & 0x2000 == 0 ? sample & 0x1FFF : sample | ~0x1FFF
    }

    @inline(__always)
    mutating func nextOutSample() -> Int16 {
        if !ringModulated { return Self.unlogAndMix(master) &+ Self.unlogAndMix(slave) }
        let masterSample = Self.unlogAndMix(master)
        let slaveSample = slave.isPCMWave ? LA32Maths.unlog(slave.outputLogSample(first: true)) : Self.unlogAndMix(slave)
        let ringModulatedSample = Int16(truncatingIfNeeded: (Int32(Self.distorted(masterSample)) * Int32(Self.distorted(slaveSample))) >> 13)
        return mixed ? masterSample &+ ringModulatedSample : ringModulatedSample
    }
}
