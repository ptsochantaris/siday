// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its parametric equaliser (`soundlib/plugins/dmo/ParamEq.cpp`).

/// OpenMPT's copy of the DirectX parametric equaliser: one band of the sound made louder or quieter,
/// with a filter of the common "peaking" kind.
///
/// The settings are the middle of the band, from 80 Hz to 16 kHz; its width, from one semitone to
/// thirty-six; and the gain, from -15 dB to +15 dB. A gain of exactly none, which is the setting at a
/// half, passes the sound through untouched, and the filter is not run: what it remembers of the sound
/// then stays as it was until the gain is moved again.
final class OpenMPTParamEq: OpenMPTEffect {
    private static let kEqCenter = 0, kEqBandwidth = 1, kEqGain = 2
    private static let kEqNumParameters = 3

    private var m_param: [Float] = [(8000.0 - 80.0) / 15920.0, 0.314286, 0.5]

    // Equalizer coefficients
    private var b0DIVa0: Float = 0, b1DIVa0: Float = 0, b2DIVa0: Float = 0, a1DIVa0: Float = 0, a2DIVa0: Float = 0
    // Equalizer memory
    private var x1L: Float = 0, x1R: Float = 0, x2L: Float = 0, x2R: Float = 0
    private var y1L: Float = 0, y1R: Float = 0, y2L: Float = 0, y2R: Float = 0
    /// The highest the middle of the band may be set: a third of the sample rate, which at 48 kHz is the top of its range.
    private var m_maxFreqParam: Float = 1.0

    override init() {
        super.init()
        RecalculateEqParams()
    }

    override var parameterCount: Int { Self.kEqNumParameters }

    override func parameter(_ index: Int) -> Float {
        index >= 0 && index < Self.kEqNumParameters ? m_param[index] : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.kEqNumParameters else { return }
        m_param[index] = OpenMPTDMO.unit(value)
        RecalculateEqParams()
    }

    override func resume() {
        // Limit center frequency to a third of the sampling rate.
        let limit: Float = (Float(outputSampleRate) / 3.0 - 80.0) / 15920.0
        m_maxFreqParam = limit < 0 ? 0 : (limit > 1 ? 1 : limit)
        RecalculateEqParams()
        // Reset filter state
        x1L = 0
        x1R = 0
        x2L = 0
        x2R = 0
        y1L = 0
        y1R = 0
        y2L = 0
        y2R = 0
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        if m_param[Self.kEqGain] == 0.5 {
            outLeft.update(from: inLeft, count: frames)
            outRight.update(from: inRight, count: frames)
            return
        }

        let b0 = b0DIVa0, b1 = b1DIVa0, b2 = b2DIVa0, a1 = a1DIVa0, a2 = a2DIVa0
        var x1L = x1L, x1R = x1R, x2L = x2L, x2R = x2R
        var y1L = y1L, y1R = y1R, y2L = y2L, y2R = y2R

        for i in 0 ..< frames {
            let xL = inLeft[i]
            let yL = b0 * xL + b1 * x1L + b2 * x2L - a1 * y1L - a2 * y2L
            x2L = x1L
            x1L = xL
            y2L = y1L
            y1L = yL
            outLeft[i] = yL

            let xR = inRight[i]
            let yR = b0 * xR + b1 * x1R + b2 * x2R - a1 * y1R - a2 * y2R
            x2R = x1R
            x1R = xR
            y2R = y1R
            y1R = yR
            outRight[i] = yR
        }

        self.x1L = x1L
        self.x1R = x1R
        self.x2L = x2L
        self.x2R = x2R
        self.y1L = y1L
        self.y1R = y1R
        self.y2L = y2L
        self.y2R = y2R
    }

    private func BandwidthInSemitones() -> Float { 1.0 + m_param[Self.kEqBandwidth] * 35.0 }
    private func FreqInHertz() -> Float { 80.0 + m_param[Self.kEqCenter] * 15920.0 }
    private func GainInDecibel() -> Float { (m_param[Self.kEqGain] - 0.5) * 30.0 }

    private func RecalculateEqParams() {
        if m_param[Self.kEqCenter] > m_maxFreqParam { m_param[Self.kEqCenter] = m_maxFreqParam }
        let freq = FreqInHertz() / Float(outputSampleRate)
        let a = powf(10.0, GainInDecibel() / 40.0)
        let w0 = 2.0 * OpenMPTDMO.pi * freq
        let sinW0 = sinf(w0)
        let cosW0 = cosf(w0)
        let alpha = sinW0 * sinhf((BandwidthInSemitones() * (OpenMPTDMO.ln2 / 24.0)) * w0 / sinW0)

        let b0: Float = 1.0 + alpha * a
        let b1: Float = -2.0 * cosW0
        let b2: Float = 1.0 - alpha * a
        let a0: Float = 1.0 + alpha / a
        let a1: Float = -2.0 * cosW0
        let a2: Float = 1.0 - alpha / a

        b0DIVa0 = b0 / a0
        b1DIVa0 = b1 / a0
        b2DIVa0 = b2 / a0
        a1DIVa0 = a1 / a0
        a2DIVa0 = a2 / a0
    }
}
