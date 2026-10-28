// Copyright (C) 2003-2009 Dean Beeler, Jerome Fisher; (C) 2011-2024 Dean Beeler, Jerome Fisher, Sergey V. Mikayev
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Swift port of mt32emu's envelopes of a partial, as the MT-32's 8095 controller works them out and sets
// the LA32's ramps by them: TVA.cpp (amplitude), TVF.cpp (filter) and TVP.cpp (pitch), from Munt's
// libmt32emu 2.8.3, free software under the GNU Lesser General Public License, version 2.1 or any later
// version (see THIRD-PARTY.md).

/// A partial's amplifier: the controller's working out of its envelope, stage by stage, as the LA32's
/// amplitude ramp's targets and speeds.
final class MT32TVA {
    // The stages, as `phase` is when the next is started.
    static let phaseBasic = 0, phaseAttack = 1, phase2 = 2, phase3 = 3, phase4 = 4, phaseSustain = 5, phaseRelease = 6, phaseDead = 7

    private static let biasLevelToAmpSubtractionCoeff: [Int] = [255, 187, 137, 100, 74, 54, 40, 29, 21, 15, 10, 5, 0]

    private unowned(unsafe) let partial: MT32Partial
    private unowned(unsafe) var part: MT32Part!
    private var partialParam = PartialParams(UnsafePointer(bitPattern: 1)!)
    private var rhythmTemp: UnsafeMutablePointer<UInt8>?
    private(set) var playing = false
    private var biasAmpSubtraction = 0
    private var veloAmpSubtraction = 0
    private var keyTimeSubtraction = 0
    private var target: UInt8 = 0
    private(set) var phase = MT32TVA.phaseDead

    init(_ partial: MT32Partial) { self.partial = partial }

    private func startRamp(_ newTarget: UInt8, _ newIncrement: UInt8, _ newPhase: Int) {
        target = newTarget
        phase = newPhase
        partial.ampRamp.startRamp(newTarget, newIncrement)
    }

    private func end(_ newPhase: Int) {
        phase = newPhase
        playing = false
    }

    private static func multBias(_ biasLevel: Int, _ bias: Int) -> Int { (bias * biasLevelToAmpSubtractionCoeff[biasLevel]) >> 5 }

    private static func biasAmpSubtraction(_ biasPoint: Int, _ biasLevel: Int, _ key: Int) -> Int {
        if biasPoint & 0x40 == 0 {
            let bias = biasPoint + 33 - key
            if bias > 0 { return multBias(biasLevel, bias) }
        } else {
            let bias = biasPoint - 31 - key
            if bias < 0 { return multBias(biasLevel, -bias) }
        }
        return 0
    }

    private static func biasAmpSubtractions(_ params: PartialParams, _ key: Int) -> Int {
        let first = biasAmpSubtraction(params.tvaBiasPoint1, params.tvaBiasLevel1, key)
        if first > 255 { return 255 }
        let second = biasAmpSubtraction(params.tvaBiasPoint2, params.tvaBiasLevel2, key)
        if second > 255 { return 255 }
        return min(255, first + second)
    }

    private static func veloAmpSubtraction(_ veloSensitivity: Int, _ velocity: Int) -> Int {
        var velocityMult = veloSensitivity - 50
        let absVelocityMult = velocityMult < 0 ? -velocityMult : velocityMult
        velocityMult = Int(Int32(truncatingIfNeeded: UInt32(truncatingIfNeeded: velocityMult * (velocity - 64)) << 2))
        return absVelocityMult - (velocityMult >> 8)
    }

    /// The amplitude before the envelope: the master volume, the part's volume and expression, the rhythm
    /// key's level, the partial's level and its key and velocity's, and its resonance, taken from 155.
    private func basicAmp() -> Int {
        let synth = partial.synth
        var amp = 155
        let ringSlave = synth.features.quirkRingModulationNoMix ? partial.isRingModulatingNoMix : partial.isRingModulatingSlave
        if !ringSlave {
            amp -= Int(MT32Tables.masterVolToAmpSubtraction[Int(synth.memory.system(MT32Memory.masterVol))])
            if amp < 0 { return 0 }
            amp -= Int(MT32Tables.levelToAmpSubtraction[Int(part.volume)])
            if amp < 0 { return 0 }
            amp -= Int(MT32Tables.levelToAmpSubtraction[Int(part.expression)])
            if amp < 0 { return 0 }
            if let rhythmTemp {
                amp -= Int(MT32Tables.levelToAmpSubtraction[Int(rhythmTemp[MT32Memory.rhythmOutputLevel])])
                if amp < 0 { return 0 }
            }
        }
        amp -= biasAmpSubtraction
        if amp < 0 { return 0 }
        amp -= Int(MT32Tables.levelToAmpSubtraction[partialParam.tvaLevel])
        if amp < 0 { return 0 }
        amp -= veloAmpSubtraction
        if amp < 0 { return 0 }
        if amp > 155 { amp = 155 }
        amp -= partialParam.tvfResonance >> 1
        if amp < 0 { return 0 }
        return amp
    }

    private static func keyTimeSubtraction(_ envTimeKeyfollow: Int, _ key: Int) -> Int {
        envTimeKeyfollow == 0 ? 0 : (key - 60) >> (5 - envTimeKeyfollow)
    }

    func reset(part: MT32Part, params: PartialParams, rhythmTemp: UnsafeMutablePointer<UInt8>?) {
        self.part = part
        partialParam = params
        self.rhythmTemp = rhythmTemp
        playing = true
        let key = partial.poly!.key
        let velocity = partial.poly!.velocity
        keyTimeSubtraction = Self.keyTimeSubtraction(params.tvaEnvTimeKeyfollow, key)
        biasAmpSubtraction = Self.biasAmpSubtractions(params, key)
        veloAmpSubtraction = Self.veloAmpSubtraction(params.tvaVeloSensitivity, velocity)
        var newTarget = basicAmp()
        let newPhase: Int
        if params.tvaEnvTime(0) == 0 {
            // Straight to the attack's level, and from there to the second's in the next stage: the
            // velocity never changes this partial's times.
            newTarget += params.tvaEnvLevel(0)
            newPhase = Self.phaseAttack
        } else {
            // To the amplitude before the envelope, and from there to the attack's level.
            newPhase = Self.phaseBasic
        }
        partial.ampRamp.reset()
        // As fast as can be down: the ramp, at nought, is at or below the target already, and so jumps to it.
        startRamp(UInt8(truncatingIfNeeded: newTarget), 0x80 | 127, newPhase)
    }

    func startAbort() { startRamp(64, 0x80 | 127, Self.phaseRelease) }

    func startDecay() {
        if phase >= Self.phaseRelease { return }
        let newIncrement: UInt8 = partialParam.tvaEnvTime(4) == 0 ? 1 : UInt8(truncatingIfNeeded: -partialParam.tvaEnvTime(4))
        // When it is done, the next stage is taken to be the release's end, and the partial stops.
        startRamp(0, newIncrement, Self.phaseRelease)
    }

    func handleInterrupt() { nextPhase() }

    /// Asked by the pitch's working out now and then: a note held is made louder or softer by a change of
    /// the part's volume or expression.
    func recalcSustain() {
        if phase != Self.phaseSustain || partialParam.tvaEnvLevel(3) == 0 { return }
        let newTarget = basicAmp() + partialParam.tvaEnvLevel(3)
        let targetDelta = newTarget - Int(target)
        var newIncrement: UInt8
        let descending = targetDelta < 0
        if !descending {
            newIncrement = MT32Tables.envLogarithmicTime[Int(UInt8(truncatingIfNeeded: targetDelta))] &- 2
        } else {
            newIncrement = (MT32Tables.envLogarithmicTime[Int(UInt8(truncatingIfNeeded: -targetDelta))] &- 2) | 0x80
        }
        if partial.synth.niceAmpRamp, descending != partial.ampRamp.isBelowCurrent(UInt8(truncatingIfNeeded: newTarget)) {
            newIncrement ^= 0x80
        }
        // Once there, the next stage is the sustain again (or the release, as the settings are then).
        startRamp(UInt8(truncatingIfNeeded: newTarget), newIncrement, Self.phaseSustain - 1)
    }

    private func nextPhase() {
        if phase >= Self.phaseDead || !playing { return }
        var newPhase = phase + 1
        if newPhase == Self.phaseDead {
            end(newPhase)
            return
        }
        var allLevelsZeroFromNowOn = false
        if partialParam.tvaEnvLevel(3) == 0 {
            if newPhase == Self.phase4 {
                allLevelsZeroFromNowOn = true
            } else if !partial.synth.features.quirkTVAZeroEnvLevels, partialParam.tvaEnvLevel(2) == 0 {
                if newPhase == Self.phase3 {
                    allLevelsZeroFromNowOn = true
                } else if partialParam.tvaEnvLevel(1) == 0 {
                    if newPhase == Self.phase2 {
                        allLevelsZeroFromNowOn = true
                    } else if partialParam.tvaEnvLevel(0) == 0 {
                        if newPhase == Self.phaseAttack { allLevelsZeroFromNowOn = true }
                    }
                }
            }
        }
        var newTarget: Int
        var newIncrement = 0
        let envPointIndex = phase
        if !allLevelsZeroFromNowOn {
            newTarget = basicAmp()
            if newPhase == Self.phaseSustain || newPhase == Self.phaseRelease {
                if partialParam.tvaEnvLevel(3) == 0 {
                    end(newPhase)
                    return
                }
                if !partial.poly!.canSustain {
                    newPhase = Self.phaseRelease
                    newTarget = 0
                    newIncrement = -partialParam.tvaEnvTime(4)
                    // (Never a speed of nought, which would never end: up instead, to nought at once.)
                    if newIncrement == 0 { newIncrement = 1 }
                } else {
                    newTarget += partialParam.tvaEnvLevel(3)
                    newIncrement = 0
                }
            } else {
                newTarget += partialParam.tvaEnvLevel(envPointIndex)
            }
        } else {
            newTarget = 0
        }
        if (newPhase != Self.phaseSustain && newPhase != Self.phaseRelease) || allLevelsZeroFromNowOn {
            var envTimeSetting = partialParam.tvaEnvTime(envPointIndex)
            if newPhase == Self.phaseAttack {
                envTimeSetting -= (partial.poly!.velocity - 64) >> (6 - partialParam.tvaEnvTimeVeloSensitivity)
                if envTimeSetting <= 0, partialParam.tvaEnvTime(envPointIndex) != 0 { envTimeSetting = 1 }
            } else {
                envTimeSetting -= keyTimeSubtraction
            }
            if envTimeSetting > 0 {
                var targetDelta = newTarget - Int(target)
                if targetDelta <= 0 {
                    if targetDelta == 0 {
                        // The same target: one less, so that the speed is not nought; or, below nought,
                        // one more (the firmware's own oddity, kept).
                        targetDelta = -1
                        newTarget -= 1
                        if newTarget < 0 {
                            targetDelta = 1
                            newTarget = -newTarget
                        }
                    }
                    targetDelta = -targetDelta
                    newIncrement = Int(MT32Tables.envLogarithmicTime[Int(UInt8(truncatingIfNeeded: targetDelta))]) - envTimeSetting
                    if newIncrement <= 0 { newIncrement = 1 }
                    newIncrement |= 0x80
                } else {
                    newIncrement = Int(MT32Tables.envLogarithmicTime[Int(UInt8(truncatingIfNeeded: targetDelta))]) - envTimeSetting
                    if newIncrement <= 0 { newIncrement = 1 }
                }
            } else {
                newIncrement = newTarget >= Int(target) ? (0x80 | 127) : 127
            }
            if newIncrement == 0 { newIncrement = 1 }
        }
        startRamp(UInt8(truncatingIfNeeded: newTarget), UInt8(truncatingIfNeeded: newIncrement), newPhase)
    }
}

/// A partial's filter: its cutoff before the envelope, worked out once for the note, and its envelope, as
/// the LA32's cutoff ramp's targets and speeds.
final class MT32TVF {
    private static let phase2 = 2, phaseSustain = 5, phaseRelease = 6, phaseDone = 7

    private static let biasLevelToBiasMult: [Int] = [85, 42, 21, 16, 10, 5, 2, 0, -2, -5, -10, -16, -21, -74, -85]
    /// The key follow settings' multipliers in 21sts (-1, -1/2, -1/4, 0, 1/8 ... 2, s1, s2).
    private static let keyfollowMult21: [Int] = [-21, -10, -5, 0, 2, 5, 8, 10, 13, 16, 18, 21, 26, 32, 42, 21, 21]

    private unowned(unsafe) let partial: MT32Partial
    private var partialParam = PartialParams(UnsafePointer(bitPattern: 1)!)
    private(set) var baseCutoff: UInt8 = 0
    private var keyTimeSubtraction = 0
    private var levelMult = 0
    private var target: UInt8 = 0
    private var phase = 0

    init(_ partial: MT32Partial) { self.partial = partial }

    private static func calcBaseCutoff(_ params: PartialParams, _ basePitch: UInt32, _ key: Int, _ quirkTVFBaseCutoffLimit: Bool) -> UInt8 {
        var baseCutoff = keyfollowMult21[params.tvfKeyfollow] - keyfollowMult21[params.pitchKeyfollow]
        baseCutoff *= key - 60
        let biasPoint = params.tvfBiasPoint
        if biasPoint & 0x40 == 0 {
            var bias = biasPoint + 33 - key
            if bias > 0 {
                bias = -bias
                baseCutoff += bias * biasLevelToBiasMult[params.tvfBiasLevel]
            }
        } else {
            let bias = biasPoint - 31 - key
            if bias < 0 { baseCutoff += bias * biasLevelToBiasMult[params.tvfBiasLevel] }
        }
        baseCutoff += (params.tvfCutoff << 4) - 800
        if baseCutoff >= 0 {
            let pitchDeltaThing = Int(basePitch >> 4) + baseCutoff - 3584
            if pitchDeltaThing > 0 { baseCutoff -= pitchDeltaThing }
        } else if quirkTVFBaseCutoffLimit {
            if baseCutoff <= -0x400 { baseCutoff = -400 }
        } else if baseCutoff < -2048 {
            baseCutoff = -2048
        }
        baseCutoff += 2056
        baseCutoff >>= 4
        if baseCutoff > 255 { baseCutoff = 255 }
        return UInt8(truncatingIfNeeded: baseCutoff)
    }

    private func startRamp(_ newTarget: UInt8, _ newIncrement: UInt8, _ newPhase: Int) {
        target = newTarget
        phase = newPhase
        partial.cutoffModifierRamp.startRamp(newTarget, newIncrement)
    }

    func reset(params: PartialParams, basePitch: UInt32) {
        partialParam = params
        let key = partial.poly!.key
        let velocity = partial.poly!.velocity
        baseCutoff = Self.calcBaseCutoff(params, basePitch, key, partial.synth.features.quirkTVFBaseCutoffLimit)
        var newLevelMult = velocity * params.tvfEnvVeloSensitivity
        newLevelMult >>= 6
        newLevelMult += 109 - params.tvfEnvVeloSensitivity
        newLevelMult += (key - 60) >> (4 - params.tvfEnvDepthKeyfollow)
        if newLevelMult < 0 { newLevelMult = 0 }
        newLevelMult *= params.tvfEnvDepth
        newLevelMult >>= 6
        if newLevelMult > 255 { newLevelMult = 255 }
        levelMult = newLevelMult
        keyTimeSubtraction = params.tvfEnvTimeKeyfollow != 0 ? (key - 60) >> (5 - params.tvfEnvTimeKeyfollow) : 0
        let newTarget = (newLevelMult * params.tvfEnvLevel(0)) >> 8
        let envTimeSetting = params.tvfEnvTime(0) - keyTimeSubtraction
        var newIncrement: Int
        if envTimeSetting <= 0 {
            newIncrement = 0x80 | 127
        } else {
            newIncrement = Int(MT32Tables.envLogarithmicTime[newTarget]) - envTimeSetting
            if newIncrement <= 0 { newIncrement = 1 }
        }
        partial.cutoffModifierRamp.reset()
        startRamp(UInt8(truncatingIfNeeded: newTarget), UInt8(truncatingIfNeeded: newIncrement), Self.phase2 - 1)
    }

    func handleInterrupt() { nextPhase() }

    func startDecay() {
        if phase >= Self.phaseRelease { return }
        if partialParam.tvfEnvTime(4) == 0 {
            startRamp(0, 1, Self.phaseDone - 1)
        } else {
            startRamp(0, UInt8(truncatingIfNeeded: -partialParam.tvfEnvTime(4)), Self.phaseDone - 1)
        }
    }

    private func nextPhase() {
        let newPhase = phase + 1
        switch newPhase {
        case Self.phaseDone:
            startRamp(0, 0, newPhase)
            return
        case Self.phaseSustain, Self.phaseRelease:
            if !partial.poly!.canSustain {
                phase = newPhase
                startDecay()
                return
            }
            startRamp(UInt8(truncatingIfNeeded: (levelMult * partialParam.tvfEnvLevel(3)) >> 8), 0, newPhase)
            return
        default:
            break
        }
        let envPointIndex = phase
        let envTimeSetting = partialParam.tvfEnvTime(envPointIndex) - keyTimeSubtraction
        var newTarget = (levelMult * partialParam.tvfEnvLevel(envPointIndex)) >> 8
        var newIncrement: Int
        if envTimeSetting > 0 {
            var targetDelta = newTarget - Int(target)
            if targetDelta == 0 {
                if newTarget == 0 {
                    targetDelta = 1
                    newTarget = 1
                } else {
                    targetDelta = -1
                    newTarget -= 1
                }
            }
            newIncrement = Int(MT32Tables.envLogarithmicTime[targetDelta < 0 ? -targetDelta : targetDelta]) - envTimeSetting
            if newIncrement <= 0 { newIncrement = 1 }
            if targetDelta < 0 { newIncrement |= 0x80 }
        } else {
            newIncrement = newTarget >= Int(target) ? (0x80 | 127) : 127
        }
        startRamp(UInt8(truncatingIfNeeded: newTarget), UInt8(truncatingIfNeeded: newIncrement), newPhase)
    }
}

/// A partial's pitch: its base pitch for the note, and its envelope and vibrato, worked out by the
/// controller on its software timer, about 4,000 times a second.
final class MT32TVP {
    private static let lowerDurationToDivisor: [Int] = [34078, 37162, 40526, 44194, 48194, 52556, 57312, 62499]
    /// The pitch key follow settings' multipliers in 8192nds (-1, -1/2, -1/4, 0, 1/8 ... 2, and roughly
    /// one and two cents above 1).
    private static let pitchKeyfollowMult: [Int] = [-8192, -4096, -2048, 0, 1024, 2048, 3072, 4096, 5120, 6144, 7168, 8192, 10240, 12288, 16384, 8198, 8226]
    /// (key - 60) * 4096 / 12, rounded to the nearest, ties to even.
    private static let keyToPitchTable: [Int] = [
        0, 341, 683, 1024, 1365, 1707, 2048, 2389, 2731, 3072, 3413, 3755, 4096, 4437, 4779, 5120,
        5461, 5803, 6144, 6485, 6827, 7168, 7509, 7851, 8192, 8533, 8875, 9216, 9557, 9899, 10240, 10581,
        10923, 11264, 11605, 11947, 12288, 12629, 12971, 13312, 13653, 13995, 14336, 14677, 15019, 15360, 15701, 16043,
        16384, 16725, 17067, 17408, 17749, 18091, 18432, 18773, 19115, 19456, 19797, 20139, 20480, 20821, 21163, 21504,
        21845, 22187, 22528, 22869,
    ]
    /// Samples between the timer's firings, nominally.
    private static let nominalProcessTimerPeriodSamples = 32000 / 4000
    /// How far the timer counts in sixteen samples: it ticks at 500 kHz on the MT-32 and the CM-32L, at
    /// 750 kHz on the third generation's faster controller.
    private static let ticksPerSampleX16Gen1And2 = (500_000 << 4) / 32000
    private static let ticksPerSampleX16Gen3 = (750_000 << 4) / 32000

    private unowned(unsafe) let partial: MT32Partial
    private unowned(unsafe) var part: MT32Part!
    private var partialParam = PartialParams(UnsafePointer(bitPattern: 1)!)
    private var patchTemp = UnsafeMutablePointer<UInt8>(bitPattern: 1)!
    private let processTimerTicksPerSampleX16: Int
    private var processTimerIncrement = 0
    private var counter = 0
    private var timeElapsed: UInt32 = 0
    private var phase = 0
    private(set) var basePitch: UInt32 = 0
    private var targetPitchOffsetWithoutLFO: Int32 = 0
    private var currentPitchOffset: Int32 = 0
    private var lfoPitchOffset: Int16 = 0
    private var timeKeyfollowSubtraction: Int8 = 0
    private var pitchOffsetChangePerBigTick: Int16 = 0
    private var targetPitchOffsetReachedBigTick: UInt16 = 0
    private var shifts: UInt32 = 0
    private var pitch: UInt16 = 0

    init(_ partial: MT32Partial) {
        self.partial = partial
        processTimerTicksPerSampleX16 = partial.synth.features.quirkFastPitchChanges ? Self.ticksPerSampleX16Gen3 : Self.ticksPerSampleX16Gen1And2
    }

    private static func keyToPitch(_ key: Int) -> Int {
        let pitch = keyToPitchTable[abs(key - 60)]
        return key < 60 ? -pitch : pitch
    }

    private static func coarseToPitch(_ coarse: Int) -> Int { (coarse - 36) * 4096 / 12 }
    private static func fineToPitch(_ fine: Int) -> Int { (fine - 50) * 4096 / 1200 }

    private func calcBasePitch(_ key: Int) -> UInt32 {
        let features = partial.synth.features
        var basePitch = Int32(Self.keyToPitch(key))
        basePitch = (basePitch * Int32(Self.pitchKeyfollowMult[partialParam.pitchKeyfollow])) >> 13
        basePitch += Int32(Self.coarseToPitch(partialParam.pitchCoarse))
        basePitch += Int32(Self.fineToPitch(partialParam.pitchFine))
        if features.quirkKeyShift {
            // (The first MT-32s shift the key here, not before.)
            basePitch += Int32(Self.coarseToPitch(Int(patchTemp[MT32Memory.keyShift]) + 12))
        }
        basePitch += Int32(Self.fineToPitch(Int(patchTemp[MT32Memory.fineTune])))
        if let wave = partial.pcmWave {
            basePitch += Int32(wave.pitch)
        } else if partialParam.waveform & 1 == 0 {
            // Middle C at about 261.64 Hz.
            basePitch += 37133
        } else {
            // A sawtooth is an octave above a square of the same setting: 4,096 less.
            basePitch += 33037
        }
        if features.quirkBasePitchOverflow {
            basePitch &= 0xFFFF
        } else if basePitch < 0 {
            basePitch = 0
        } else if basePitch > 59392 {
            basePitch = 59392
        }
        return UInt32(bitPattern: basePitch)
    }

    private static func calcVeloMult(_ veloSensitivity: Int, _ velocity: Int) -> Int {
        if veloSensitivity == 0 { return 21845 }
        let reversedVelocity = UInt32(truncatingIfNeeded: 127 - velocity)
        let scaled: UInt32
        if veloSensitivity > 3 {
            // (Not reached on the CM-32L and the LAPC-I, whose tables keep it to 3.)
            scaled = (reversedVelocity << 8) >> UInt32((3 - veloSensitivity) & 0x1F)
        } else {
            scaled = reversedVelocity << UInt32(5 + veloSensitivity)
        }
        return Int(((32768 &- scaled) &* 21845) >> 15)
    }

    private func targetPitchOffsetWithoutLFO(_ levelIndex: Int, _ velocity: Int) -> Int32 {
        let veloMult = Int32(truncatingIfNeeded: Self.calcVeloMult(partialParam.pitchEnvVeloSensitivity, velocity))
        var offset = Int32(partialParam.pitchEnvLevel(levelIndex) - 50)
        offset = (offset &* veloMult) >> Int32(16 - partialParam.pitchEnvDepth)
        return offset
    }

    func reset(part: MT32Part, params: PartialParams) {
        self.part = part
        partialParam = params
        patchTemp = part.patchTemp
        let key = partial.poly!.key
        let velocity = partial.poly!.velocity
        timeElapsed = 0
        processTimerIncrement = 0
        basePitch = calcBasePitch(key)
        currentPitchOffset = targetPitchOffsetWithoutLFO(0, velocity)
        targetPitchOffsetWithoutLFO = currentPitchOffset
        phase = 0
        if params.pitchEnvTimeKeyfollow != 0 {
            timeKeyfollowSubtraction = Int8(truncatingIfNeeded: Int32(truncatingIfNeeded: key - 60) >> Int32(5 - params.pitchEnvTimeKeyfollow))
        } else {
            timeKeyfollowSubtraction = 0
        }
        lfoPitchOffset = 0
        counter = 0
        pitch = UInt16(truncatingIfNeeded: basePitch)
        pitchOffsetChangePerBigTick = 0
        targetPitchOffsetReachedBigTick = 0
        shifts = 0
    }

    private func updatePitch() {
        let synth = partial.synth
        var newPitch = Int32(bitPattern: basePitch) &+ currentPitchOffset
        if partial.pcmWave == nil || partial.pcmWave!.lengthByte & 1 == 0 {
            newPitch &+= synth.masterTunePitchDelta
        }
        if partialParam.pitchBenderEnabled & 1 != 0 { newPitch &+= part.pitchBend }
        if synth.features.quirkPitchEnvelopeOverflow {
            newPitch &= 0xFFFF
        } else if newPitch < 0 {
            newPitch = 0
        }
        if newPitch > 59392 { newPitch = 59392 }
        pitch = UInt16(truncatingIfNeeded: newPitch)
        // (Here, as the CM-32L does it.)
        partial.tva.recalcSustain()
    }

    private func targetPitchOffsetReached() {
        currentPitchOffset = targetPitchOffsetWithoutLFO &+ Int32(lfoPitchOffset)
        switch phase {
        case 3, 4:
            var newLFOPitchOffset = (Int(part.modulation) * partialParam.lfoModSensitivity) >> 7
            newLFOPitchOffset = (newLFOPitchOffset + partialParam.lfoDepth) << 1
            // The other way from the last time.
            if pitchOffsetChangePerBigTick > 0 { newLFOPitchOffset = -newLFOPitchOffset }
            lfoPitchOffset = Int16(truncatingIfNeeded: newLFOPitchOffset)
            let targetPitchOffset = Int(targetPitchOffsetWithoutLFO) + Int(lfoPitchOffset)
            setupPitchChange(targetPitchOffset, UInt8(truncatingIfNeeded: 101 - partialParam.lfoRate))
            updatePitch()
        case 6:
            updatePitch()
        default:
            nextPhase()
        }
    }

    private func nextPhase() {
        phase += 1
        let envIndex = phase == 6 ? 4 : phase
        targetPitchOffsetWithoutLFO = targetPitchOffsetWithoutLFO(envIndex, partial.poly!.velocity)
        var changeDuration = partialParam.pitchEnvTime(envIndex - 1)
        changeDuration -= Int(timeKeyfollowSubtraction)
        if changeDuration > 0 {
            setupPitchChange(Int(targetPitchOffsetWithoutLFO), UInt8(truncatingIfNeeded: changeDuration))
            updatePitch()
        } else {
            targetPitchOffsetReached()
        }
    }

    private func setupPitchChange(_ targetPitchOffset: Int, _ duration: UInt8) {
        let negativeDelta = targetPitchOffset < Int(currentPitchOffset)
        var pitchOffsetDelta = Int32(truncatingIfNeeded: targetPitchOffset) &- currentPitchOffset
        if pitchOffsetDelta > 32767 || pitchOffsetDelta < -32768 { pitchOffsetDelta = 32767 }
        if negativeDelta { pitchOffsetDelta = 0 &- pitchOffsetDelta }
        // As many of the 16 bits of the change per big tick as can be used, for precision.
        var absPitchOffsetDelta = (UInt32(bitPattern: pitchOffsetDelta) & 0xFFFF) << 16
        var normalisationShifts: UInt32 = 0
        while normalisationShifts < 31 {
            if absPitchOffsetDelta & 0x8000_0000 != 0 { break }
            absPitchOffsetDelta <<= 1
            normalisationShifts += 1
        }
        absPitchOffsetDelta >>= 1
        let changeDuration = duration &- 1
        let upperDuration = UInt32(changeDuration >> 3)
        shifts = normalisationShifts + upperDuration + 2
        let divisor = UInt32(Self.lowerDurationToDivisor[Int(changeDuration & 7)])
        var newChange = Int16(truncatingIfNeeded: ((absPitchOffsetDelta & 0xFFFF_0000) / divisor) >> 1)
        if negativeDelta { newChange = 0 &- newChange }
        pitchOffsetChangePerBigTick = newChange
        let currentBigTick = Int(timeElapsed >> 8)
        // (For the longest times the shift is below nought: as mt32emu is built for the processors siday
        // runs on, a shift takes the low five bits of its count, and the result is nought.)
        var durationInBigTicks = Int(divisor &>> (12 &- upperDuration))
        if durationInBigTicks > 32767 { durationInBigTicks = 32767 }
        // (Wrapping past 16 bits is meant.)
        targetPitchOffsetReachedBigTick = UInt16(truncatingIfNeeded: currentBigTick + durationInBigTicks)
    }

    func startDecay() {
        phase = 5
        lfoPitchOffset = 0
        targetPitchOffsetReachedBigTick = UInt16(truncatingIfNeeded: timeElapsed >> 8)
    }

    /// The pitch for the next sample: the timer is emulated by counting samples, a few more or fewer each
    /// time (the real one fires when it can; mt32emu's roughly matching jitter, from the C library's
    /// random numbers, which the synthesiser keeps its own of).
    @inline(__always)
    func nextPitch() -> UInt16 {
        if counter == 0 {
            timeElapsed = (timeElapsed &+ UInt32(truncatingIfNeeded: processTimerIncrement)) & 0x00FF_FFFF
            counter = Self.nominalProcessTimerPeriodSamples + (partial.synth.nextRandom() & 3)
            processTimerIncrement = (processTimerTicksPerSampleX16 * counter) >> 4
            process()
        }
        counter -= 1
        return pitch
    }

    private func process() {
        if phase == 0 {
            targetPitchOffsetReached()
            return
        }
        if phase == 5 {
            nextPhase()
            return
        }
        if phase > 7 {
            updatePitch()
            return
        }
        var negativeBigTicksRemaining = Int16(truncatingIfNeeded: Int(timeElapsed >> 8) - Int(targetPitchOffsetReachedBigTick))
        if negativeBigTicksRemaining >= 0 {
            targetPitchOffsetReached()
            return
        }
        // (A shift of more than 31 is taken by its low five bits, as the 8095 would.)
        var rightShifts = Int(shifts)
        if rightShifts > 13 {
            rightShifts -= 13
            negativeBigTicksRemaining = negativeBigTicksRemaining >> Int16(rightShifts & 0x1F)
            rightShifts = 13
        }
        var newResult = (Int32(negativeBigTicksRemaining) * Int32(pitchOffsetChangePerBigTick)) >> Int32(rightShifts & 0x1F)
        newResult &+= targetPitchOffsetWithoutLFO &+ Int32(lfoPitchOffset)
        currentPitchOffset = newResult
        updatePitch()
    }
}
