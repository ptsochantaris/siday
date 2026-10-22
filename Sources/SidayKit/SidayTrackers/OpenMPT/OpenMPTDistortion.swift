// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its distortion (`soundlib/plugins/dmo/Distortion.cpp`).

/// OpenMPT's copy of the DirectX distortion: the sound is dulled a little, bent by putting each sample
/// on a scale of loudness (see `OpenMPTDMO.logGain`), which squashes what is loud up against the top,
/// and then passed through a filter that keeps a band of it.
///
/// The settings are the gain after the bending, from -60 dB to none; the "edge", which is how hard the
/// bending is; the frequency above which the sound is dulled beforehand; and the middle and the width
/// of the band kept afterwards, all three from 100 Hz to 8 kHz.
final class OpenMPTDistortion: OpenMPTEffect {
    private static let kDistGain = 0, kDistEdge = 1, kDistPreLowpassCutoff = 2, kDistPostEQCenterFrequency = 3, kDistPostEQBandwidth = 4
    private static let kDistNumParameters = 5

    /// What the bending is divided by for each edge, so that all of them come out about as loud.
    private static let LogNorm: [Float] = [
        1.00, 1.00, 1.50, 1.00, 1.75, 1.40, 1.17, 1.00,
        1.88, 1.76, 1.50, 1.36, 1.25, 1.15, 1.07, 1.00,
        1.94, 1.82, 1.72, 1.63, 1.55, 1.48, 1.41, 1.35,
        1.29, 1.24, 1.19, 1.15, 1.11, 1.07, 1.03, 1.00,
    ]

    private var m_param: [Float] = [0.7, 0.15, 1.0, 0.291, 0.291]

    // Pre-EQ coefficients
    private var m_preEQz1L: Float = 0, m_preEQz1R: Float = 0, m_preEQb1: Float = 0, m_preEQa0: Float = 0
    // Post-EQ coefficients
    private var m_postEQz1L: Float = 0, m_postEQz1R: Float = 0, m_postEQz2L: Float = 0, m_postEQz2R: Float = 0
    private var m_postEQa0: Float = 0, m_postEQb0: Float = 0, m_postEQb1: Float = 0
    private var m_edge: Int32 = 2, m_shift: Int32 = 2

    override init() {
        super.init()
        RecalculateDistortionParams()
    }

    override var parameterCount: Int { Self.kDistNumParameters }

    override func parameter(_ index: Int) -> Float {
        index >= 0 && index < Self.kDistNumParameters ? m_param[index] : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.kDistNumParameters else { return }
        m_param[index] = OpenMPTDMO.unit(value)
        RecalculateDistortionParams()
    }

    override func resume() {
        RecalculateDistortionParams()
        // Reset filter state
        m_preEQz1L = 0
        m_preEQz1R = 0
        m_postEQz1L = 0
        m_postEQz1R = 0
        m_postEQz2L = 0
        m_postEQz2R = 0
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let preEQa0 = m_preEQa0, preEQb1 = m_preEQb1
        let postEQa0 = m_postEQa0, postEQb0 = m_postEQb0, postEQb1 = m_postEQb1
        let edge = m_edge, shift = m_shift
        var preEQz1L = m_preEQz1L, preEQz1R = m_preEQz1R
        var postEQz1L = m_postEQz1L, postEQz1R = m_postEQz1R, postEQz2L = m_postEQz2L, postEQz2R = m_postEQz2R

        for i in 0 ..< frames {
            // Pre EQ
            var z = inLeft[i] * preEQa0 + preEQz1L * preEQb1
            preEQz1L = z
            z *= 1_073_741_824.0 // 32768^2
            // The actual distortion
            z = OpenMPTDMO.logGain(z, edge, shift)
            // Post EQ / Gain
            z = (z * postEQa0) - postEQz1L * postEQb1 - postEQz2L * postEQb0
            postEQz1L = z * postEQb0 + postEQz2L
            postEQz2L = z
            z *= (1.0 / 1_073_741_824.0) // 32768^2
            outLeft[i] = z

            z = inRight[i] * preEQa0 + preEQz1R * preEQb1
            preEQz1R = z
            z *= 1_073_741_824.0
            z = OpenMPTDMO.logGain(z, edge, shift)
            z = (z * postEQa0) - postEQz1R * postEQb1 - postEQz2R * postEQb0
            postEQz1R = z * postEQb0 + postEQz2R
            postEQz2R = z
            z *= (1.0 / 1_073_741_824.0)
            outRight[i] = z
        }

        m_preEQz1L = preEQz1L
        m_preEQz1R = preEQz1R
        m_postEQz1L = postEQz1L
        m_postEQz1R = postEQz1R
        m_postEQz2L = postEQz2L
        m_postEQz2R = postEQz2R
    }

    private static func FreqInHertz(_ param: Float) -> Float { 100.0 + param * 7900.0 }
    private func GainInDecibel() -> Float { -60.0 + m_param[Self.kDistGain] * 60.0 }

    private func RecalculateDistortionParams() {
        let twoPi: Float = 2.0 * OpenMPTDMO.pi
        let sampleRate = Float(outputSampleRate)

        // Pre-EQ
        m_preEQb1 = ((2.0 * cosf(twoPi * Self.atMostHalf(Self.FreqInHertz(m_param[Self.kDistPreLowpassCutoff]) / sampleRate)) + 3.0) / 5.0).squareRoot()
        m_preEQa0 = (1.0 - m_preEQb1 * m_preEQb1).squareRoot()

        // Distortion
        let edge: Float = 2.0 + m_param[Self.kDistEdge] * 29.0
        m_edge = Int32(OpenMPTDMO.truncate(edge) & 31) // 2...31 shifted bits
        m_shift = Int32(32 - UInt32(m_edge).leadingZeroBitCount)

        // Post-EQ
        let gain = powf(10.0, GainInDecibel() / 20.0)
        let postFreq = twoPi * Self.atMostHalf(Self.FreqInHertz(m_param[Self.kDistPostEQCenterFrequency]) / sampleRate)
        let postBw = twoPi * Self.atMostHalf(Self.FreqInHertz(m_param[Self.kDistPostEQBandwidth]) / sampleRate)
        let t = tanf(5.0e-1 * postBw)
        m_postEQb1 = ((1.0 - t) / (1.0 + t))
        m_postEQb0 = -cosf(postFreq)
        m_postEQa0 = gain * (1.0 - m_postEQb0 * m_postEQb0).squareRoot() * (1.0 - m_postEQb1 * m_postEQb1).squareRoot() * Self.LogNorm[Int(m_edge)]
    }

    /// A frequency as a part of the sample rate, held to the half of it that can be played.
    private static func atMostHalf(_ value: Float) -> Float { 0.5 < value ? 0.5 : value }
}
