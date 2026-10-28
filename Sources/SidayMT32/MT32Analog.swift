// Copyright (C) 2003-2009 Dean Beeler, Jerome Fisher; (C) 2011-2024 Dean Beeler, Jerome Fisher, Sergey V. Mikayev
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Swift port of mt32emu's model of the analogue circuits after the DAC (Analog.cpp of Munt's libmt32emu
// 2.8.3, with integer samples), free software under the GNU Lesser General Public License, version 2.1 or
// any later version (see THIRD-PARTY.md).

/// How the analogue stage after the DAC is modelled.
public enum MT32AnalogMode: Int, Sendable {
    /// None: the DAC's samples as they are, at 32,000 a second.
    case digitalOnly = 0
    /// The sample-and-hold and low-pass filter as a short filter, at 32,000 samples a second.
    case coarse = 1
    /// The same closely, over the whole audible band, made at 48,000 samples a second.
    case accurate = 2
    /// As `accurate`, at 96,000.
    case oversampled = 3

    /// The samples a second it makes.
    public var outputRate: Int { [32000, 32000, 48000, 96000][rawValue] }
}

/// The low-pass filter of the analogue stage on one channel.
struct MT32LowPassFilter {
    /// The MT-32's first filter, and that of the later MT-32s, the CM-32L and the LAPC-I (with the
    /// voltage-controlled amplifier, at a gain of one), as short filters of 14-bit fixed point.
    private static let coarseTapsMT32: [Int32] = [20848, -3609, -2589, 2943, -1827, 887, -385, 180, -114]
    private static let coarseTapsCM32L: [Int32] = [21965, -6608, 590, 1084, -1142, 812, -510, 314, -204]
    /// The same, closely, and taking away the mirror images above 28 kHz: a filter of three phases, for
    /// making 48,000 samples a second (or 96,000) of 32,000.
    private static let accurateTapsMT32: [Float] = [
        0.003429281, 0.025929869, 0.096587777, 0.228884848, 0.372413431, 0.412386503, 0.263980018,
        -0.014504962, -0.237394528, -0.257043496, -0.103436603, 0.063996095, 0.124562333, 0.083703206,
        0.013921662, -0.033475018, -0.046239712, -0.029310921, 0.00126585, 0.021060961, 0.017925605,
        0.003559874, -0.005105248, -0.005647917, -0.004157918, -0.002065664, 0.00158747, 0.003762585,
        0.001867137, -0.001090028, -0.001433979, -0.00022367, 4.34308E-05, -0.000247827, 0.000157087,
        0.000605823, 0.000197317, -0.000370511, -0.000261202, 9.96069E-05, 9.85073E-05, -5.28754E-05,
        -1.00912E-05, 7.69943E-05, 2.03162E-05, -5.67967E-05, -3.30637E-05, 1.61958E-05, 1.73041E-05,
    ]
    private static let accurateTapsCM32L: [Float] = [
        0.003917452, 0.030693861, 0.116424199, 0.275101674, 0.43217361, 0.431247894, 0.183255659,
        -0.174955671, -0.354240244, -0.212401714, 0.072259178, 0.204655344, 0.108336211, -0.039099027,
        -0.075138174, -0.026261906, 0.00582663, 0.003052193, 0.00613657, 0.017017951, 0.008732535,
        -0.011027427, -0.012933664, 0.001158097, 0.006765958, 0.00046778, -0.002191106, 0.001561017,
        0.001842871, -0.001996876, -0.002315836, 0.000980965, 0.001817454, -0.000243272, -0.000972848,
        0.000149941, 0.000498886, -0.000204436, -0.000347415, 0.000142386, 0.000249137, -4.32946E-05,
        -0.000131231, 3.88575E-07, 4.48813E-05, -1.31906E-06, -1.03499E-05, 7.71971E-06, 2.86721E-06,
    ]
    private static let coarseLength = 8, accurateLength = 16, phases = 3
    private static let deltasRegular: [[Int]] = [[0, 0, 0], [1, 1, 0], [1, 2, 1]]
    private static let deltasOversampled: [[Int]] = [[0, 0, 0], [1, 0, 0], [1, 0, 1]]

    let mode: MT32AnalogMode
    private let coarseTaps: [Int32]
    private let accurateTaps: [Float]
    private var coarseRing = [Int32](repeating: 0, count: 8)
    private var accurateRing = [Float](repeating: 0, count: 16)
    private var position = 0
    private var phase = 0
    private let phaseIncrement: Int
    private let deltas: [[Int]]

    init(mode: MT32AnalogMode, oldMT32: Bool) {
        self.mode = mode
        coarseTaps = oldMT32 ? Self.coarseTapsMT32 : Self.coarseTapsCM32L
        accurateTaps = oldMT32 ? Self.accurateTapsMT32 : Self.accurateTapsCM32L
        phaseIncrement = mode == .oversampled ? 1 : 2
        deltas = mode == .oversampled ? Self.deltasOversampled : Self.deltasRegular
    }

    /// True if the next output sample is made without taking an input one.
    var hasNextSample: Bool { (mode == .accurate || mode == .oversampled) && phaseIncrement <= phase }

    @inline(__always)
    mutating func process(_ input: Int32) -> Int32 {
        switch mode {
        case .digitalOnly:
            return input
        case .coarse:
            var sample = coarseTaps[Self.coarseLength] &* coarseRing[position]
            coarseRing[position] = Int32(MT32Synth.clip(input))
            for i in 0 ..< Self.coarseLength {
                sample &+= coarseTaps[i] &* coarseRing[(i + position) & (Self.coarseLength - 1)]
            }
            position = (position - 1) & (Self.coarseLength - 1)
            return sample >> 14
        case .accurate, .oversampled:
            let inSample = Float(input)
            var sample: Float = phase == 0 ? accurateTaps[Self.accurateLength * Self.phases] * accurateRing[position] : 0
            if !hasNextSample { accurateRing[position] = inSample }
            var tap = phase
            for i in 0 ..< Self.accurateLength {
                sample += accurateTaps[tap] * accurateRing[(i + position) & (Self.accurateLength - 1)]
                tap += Self.phases
            }
            phase += phaseIncrement
            if Self.phases <= phase {
                phase -= Self.phases
                position = (position - 1) & (Self.accurateLength - 1)
            }
            return Int32(Float(Self.phases) * sample)
        }
    }

    /// How many samples at 32,000 a second make `outSamples`.
    func inputCount(for outSamples: Int) -> Int {
        guard mode == .accurate || mode == .oversampled else { return outSamples }
        let cycles = outSamples / Self.phases
        let remainder = outSamples - cycles * Self.phases
        return cycles * phaseIncrement + deltas[remainder][phase]
    }

    mutating func addPositionIncrement(_ increment: Int) {
        guard mode == .accurate || mode == .oversampled else { return }
        phase = (phase + increment * phaseIncrement) % Self.phases
    }
}

/// The analogue stage: the two channels of the LA32's dry sound and the reverb's, each at its gain, through
/// the low-pass filter.
struct MT32Analog {
    private var left: MT32LowPassFilter
    private var right: MT32LowPassFilter
    private var synthGain: Int32
    private var reverbGain: Int32

    /// On the CM-32L's kind, the reverb's channels reach the filter through other resistors: a gain of 0.68.
    static let cm32lReverbToLA32Gain: Float = 0.68

    init(mode: MT32AnalogMode, oldMT32: Bool, outputGain: Float, reverbGain: Float, mt32ReverbCompatible: Bool) {
        left = MT32LowPassFilter(mode: mode, oldMT32: oldMT32)
        right = MT32LowPassFilter(mode: mode, oldMT32: oldMT32)
        synthGain = Self.intGain(outputGain)
        self.reverbGain = Self.intGain(mt32ReverbCompatible ? reverbGain : reverbGain * Self.cm32lReverbToLA32Gain)
    }

    /// A gain as fixed point of eight bits, no more than 256.
    private static func intGain(_ gain: Float) -> Int32 { Int32((256 < gain ? 256 : gain) * 256) }

    func inputCount(for outSamples: Int) -> Int { left.inputCount(for: outSamples) }

    mutating func skip(_ count: Int) {
        left.addPositionIncrement(count)
        right.addPositionIncrement(count)
    }

    @inline(__always)
    mutating func process(into out: UnsafeMutablePointer<Int16>, nonReverbLeft: UnsafePointer<Int16>, nonReverbRight: UnsafePointer<Int16>,
                          reverbDryLeft: UnsafePointer<Int16>, reverbDryRight: UnsafePointer<Int16>,
                          reverbWetLeft: UnsafePointer<Int16>, reverbWetRight: UnsafePointer<Int16>, count: Int) {
        var input = 0
        for n in 0 ..< count {
            let outL: Int32, outR: Int32
            if left.hasNextSample {
                outL = left.process(0)
                outR = right.process(0)
            } else {
                let inL = (Int32(nonReverbLeft[input]) + Int32(reverbDryLeft[input])) &* synthGain &+ Int32(reverbWetLeft[input]) &* reverbGain
                let inR = (Int32(nonReverbRight[input]) + Int32(reverbDryRight[input])) &* synthGain &+ Int32(reverbWetRight[input]) &* reverbGain
                input += 1
                outL = left.process(inL >> 8)
                outR = right.process(inR >> 8)
            }
            out[n * 2] = MT32Synth.clip(outL)
            out[n * 2 + 1] = MT32Synth.clip(outR)
        }
    }
}
