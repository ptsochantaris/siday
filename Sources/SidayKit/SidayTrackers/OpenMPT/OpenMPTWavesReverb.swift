// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its copy of the Waves reverb (`soundlib/plugins/dmo/WavesReverb.cpp`).

/// OpenMPT's copy of the reverb that Waves wrote for DirectX: four delays that feed themselves, each
/// through a filter that lets the high notes die sooner than the low, and two "all-pass" delays, each
/// of which takes a pair of the four and scatters them into each other.
///
/// The settings are the gain of what goes in, from -96 dB to none; how much of what comes out is
/// reverberation, on the same scale (at none there is no dry sound left at all); how long the
/// reverberation takes to die away, up to three seconds; and how long the high notes take, as a part
/// of that.
final class OpenMPTWavesReverb: OpenMPTEffect {
    private static let kRvbInGain = 0, kRvbReverbMix = 1, kRvbReverbTime = 2, kRvbHighFreqRTRatio = 3
    private static let kRvbNumParameters = 4

    private static let combLength = 4096, allpassLength = 1024

    private var m_param: [Float] = [1.0, 1.0, 1.0 / 3.0, 0.0]

    // Parameters and coefficients
    private var m_dryFactor: Float = 0
    private var m_wetFactor: Float = 0
    private let m_coeffs: UnsafeMutablePointer<Float>
    /// How long the four delays and the two all-pass delays are, in samples.
    private var m_delay = [UInt32](repeating: 0, count: 6)

    // State
    private var combPos = 0, allpassPos = 0
    /// The four delays, a sample of each by turns, and the two all-pass delays, which are two each.
    private let comb: UnsafeMutablePointer<Float>
    private let allpass1: UnsafeMutablePointer<Float>
    private let allpass2: UnsafeMutablePointer<Float>

    override init() {
        m_coeffs = .allocate(capacity: 10)
        m_coeffs.initialize(repeating: 0, count: 10)
        comb = .allocate(capacity: Self.combLength * 4)
        comb.initialize(repeating: 0, count: Self.combLength * 4)
        allpass1 = .allocate(capacity: Self.allpassLength * 2)
        allpass1.initialize(repeating: 0, count: Self.allpassLength * 2)
        allpass2 = .allocate(capacity: Self.allpassLength * 2)
        allpass2.initialize(repeating: 0, count: Self.allpassLength * 2)
        super.init()
        RecalculateDelays()
        RecalculateWavesReverbParams()
    }

    deinit {
        m_coeffs.deallocate()
        comb.deallocate()
        allpass1.deallocate()
        allpass2.deallocate()
    }

    override var parameterCount: Int { Self.kRvbNumParameters }

    override func parameter(_ index: Int) -> Float {
        index >= 0 && index < Self.kRvbNumParameters ? m_param[index] : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.kRvbNumParameters else { return }
        m_param[index] = OpenMPTDMO.unit(value)
        RecalculateWavesReverbParams()
    }

    override func resume() {
        RecalculateDelays()
        RecalculateWavesReverbParams()
        combPos = 0
        allpassPos = 0
        comb.update(repeating: 0, count: Self.combLength * 4)
        allpass1.update(repeating: 0, count: Self.allpassLength * 2)
        allpass2.update(repeating: 0, count: Self.allpassLength * 2)
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let comb = comb, allpass1 = allpass1, allpass2 = allpass2
        let dryFactor = m_dryFactor, wetFactor = m_wetFactor
        let coeffs0 = m_coeffs[0], coeffs1 = m_coeffs[1], coeffs2 = m_coeffs[2], coeffs3 = m_coeffs[3], coeffs4 = m_coeffs[4]
        let coeffs5 = m_coeffs[5], coeffs6 = m_coeffs[6], coeffs7 = m_coeffs[7], coeffs8 = m_coeffs[8], coeffs9 = m_coeffs[9]

        var combPos = combPos, allpassPos = allpassPos
        var delay0 = (Int(truncatingIfNeeded: m_delay[0]) &+ combPos &+ 1) & 0xFFF
        var delay1 = (Int(truncatingIfNeeded: m_delay[1]) &+ combPos &+ 1) & 0xFFF
        var delay2 = (Int(truncatingIfNeeded: m_delay[2]) &+ combPos &+ 1) & 0xFFF
        var delay3 = (Int(truncatingIfNeeded: m_delay[3]) &+ combPos &+ 1) & 0xFFF
        var delay4 = (Int(truncatingIfNeeded: m_delay[4]) &+ allpassPos) & 0x3FF
        var delay5 = (Int(truncatingIfNeeded: m_delay[5]) &+ allpassPos) & 0x3FF
        var delay0old = comb[delay0 &* 4]
        var delay1old = comb[delay1 &* 4 &+ 1]
        var delay2old = comb[delay2 &* 4 &+ 2]
        var delay3old = comb[delay3 &* 4 &+ 3]

        for i in 0 ..< frames {
            let leftIn = inLeft[i] + 1e-30 // Prevent denormals
            let rightIn = inRight[i] + 1e-30 // Prevent denormals

            // Advance buffer index for the four comb filters
            delay0 = (delay0 &- 1) & 0xFFF
            delay1 = (delay1 &- 1) & 0xFFF
            delay2 = (delay2 &- 1) & 0xFFF
            delay3 = (delay3 &- 1) & 0xFFF
            var delay0new = comb[delay0 &* 4]
            var delay1new = comb[delay1 &* 4 &+ 1]
            var delay2new = comb[delay2 &* 4 &+ 2]
            var delay3new = comb[delay3 &* 4 &+ 3]

            var r1: Float, r2: Float

            r1 = delay1new * 0.61803401 + allpass1[delay4 &* 2] * coeffs0
            r2 = allpass1[delay4 &* 2 &+ 1] * coeffs0 - delay0new * 0.61803401
            allpass1[allpassPos &* 2] = r2 * 0.61803401 + delay0new
            allpass1[allpassPos &* 2 &+ 1] = delay1new - r1 * 0.61803401
            delay0new = r1
            delay1new = r2
            comb[delay0 &* 4] = r1
            comb[delay1 &* 4 &+ 1] = r2

            r1 = delay3new * 0.61803401 + allpass2[delay5 &* 2] * coeffs1
            r2 = allpass2[delay5 &* 2 &+ 1] * coeffs1 - delay2new * 0.61803401
            allpass2[allpassPos &* 2] = r2 * 0.61803401 + delay2new
            allpass2[allpassPos &* 2 &+ 1] = delay3new - r1 * 0.61803401
            delay2new = r1
            delay3new = r2
            comb[delay2 &* 4 &+ 2] = r1
            comb[delay3 &* 4 &+ 3] = r2

            outLeft[i] = (leftIn * dryFactor) + delay0new + delay2new
            outRight[i] = (rightIn * dryFactor) + delay1new + delay3new

            let leftWet = leftIn * wetFactor
            let rightWet = rightIn * wetFactor
            comb[combPos &* 4] = (delay0new * coeffs2) + (delay0old * coeffs3) + leftWet
            comb[combPos &* 4 &+ 1] = (delay1new * coeffs4) + (delay1old * coeffs5) + rightWet
            comb[combPos &* 4 &+ 2] = (delay2new * coeffs6) + (delay2old * coeffs7) - rightWet
            comb[combPos &* 4 &+ 3] = (delay3new * coeffs8) + (delay3old * coeffs9) + leftWet

            delay0old = delay0new
            delay1old = delay1new
            delay2old = delay2new
            delay3old = delay3new

            // Advance buffer index
            combPos = (combPos &- 1) & 0xFFF
            allpassPos = (allpassPos &- 1) & 0x3FF
            delay4 = (delay4 &- 1) & 0x3FF
            delay5 = (delay5 &- 1) & 0x3FF
        }

        self.combPos = combPos
        self.allpassPos = allpassPos
    }

    private static func GainInDecibel(_ param: Float) -> Float { -96.0 + param * 96.0 }
    private func ReverbTime() -> Float { 0.001 + m_param[Self.kRvbReverbTime] * 2999.999 }
    private func HighFreqRTRatio() -> Float { 0.001 + m_param[Self.kRvbHighFreqRTRatio] * 0.998 }

    /// The lengths of the delays, which follow from the sample rate alone: OpenMPT works them out when it resumes.
    private func RecalculateDelays() {
        let delay0 = OpenMPTDMO.saturateRound(Float(outputSampleRate) * 0.045)
        let delay1 = OpenMPTDMO.saturateRound(Float(delay0) * 1.18920707) // 2^0.25
        let delay2 = OpenMPTDMO.saturateRound(Float(delay1) * 1.18920707)
        let delay3 = OpenMPTDMO.saturateRound(Float(delay2) * 1.18920707)
        let delay4 = OpenMPTDMO.saturateRound(Float(delay0 &+ delay2) * 0.11546667)
        let delay5 = OpenMPTDMO.saturateRound(Float(delay1 &+ delay3) * 0.11546667)
        // Comb delays
        m_delay[0] = delay0 &- delay4
        m_delay[1] = delay2 &- delay4
        m_delay[2] = delay1 &- delay5
        m_delay[3] = delay3 &- delay5
        // Allpass delays
        m_delay[4] = delay4
        m_delay[5] = delay5
    }

    private func RecalculateWavesReverbParams() {
        // Recalculate filters
        let ReverbTimeSmp: Double = -3000.0 / (Double(outputSampleRate) * Double(ReverbTime()))
        let ReverbTimeSmpHF: Double = ReverbTimeSmp * (1.0 / Double(HighFreqRTRatio()) - 1.0)

        m_coeffs[0] = Float(pow(10.0, Double(m_delay[4]) * ReverbTimeSmp))
        m_coeffs[1] = Float(pow(10.0, Double(m_delay[5]) * ReverbTimeSmp))

        var sum = 0.0
        for pair in 0 ..< 4 {
            let gain1: Double = pow(10.0, Double(m_delay[pair]) * ReverbTimeSmp)
            let gain2: Double = (1.0 - pow(10.0, Double(m_delay[pair] &+ m_delay[4 + pair / 2]) * ReverbTimeSmpHF)) * 0.5
            let gain3: Double = gain1 * Double(m_coeffs[pair / 2])
            let gain4: Double = gain3 * (((gain3 + 1.0) * gain3 + 1.0) * gain3 + 1.0) + 1.0
            m_coeffs[2 + pair * 2] = Float(gain1 * (1.0 - gain2))
            m_coeffs[3 + pair * 2] = Float(gain1 * gain2)
            sum += gain4 * gain4
        }

        let inGain: Double = pow(10.0, Double(Self.GainInDecibel(m_param[Self.kRvbInGain])) * 0.05)
        let reverbMix: Double = pow(10.0, Double(Self.GainInDecibel(m_param[Self.kRvbReverbMix])) * 0.1)
        m_dryFactor = Float((1.0 - reverbMix).squareRoot() * inGain)
        m_wetFactor = Float(reverbMix.squareRoot() * (4.0 / sum.squareRoot() * inGain))
    }
}
