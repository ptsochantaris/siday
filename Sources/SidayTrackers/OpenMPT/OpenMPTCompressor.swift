// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its compressor (`soundlib/plugins/dmo/Compressor.cpp`).

import SidayFoundation

/// OpenMPT's copy of the DirectX compressor: it follows how loud the two channels are together, on a
/// scale of loudness (see `OpenMPTDMO.logGain`), and turns both down by the same amount for as long as
/// that is above a threshold.
///
/// The settings are the gain afterwards, from -60 dB to +60 dB; how quickly the loudness it follows
/// rises (the attack, 0.01 to 500 ms) and falls (the release, 50 to 3000 ms); the threshold, from
/// -60 dB to none; the ratio, from 1:1 to 100:1; and the "predelay", up to 4 ms, which is how far the
/// sound is held back so that it is turned down as it gets loud and not just after.
///
/// The predelay does not do what it says. OpenMPT divides it by 4096 as the DirectX effect, which
/// counted it in 4096ths of a sample, would have, but counts it in whole samples: so at any sample
/// rate near this one the sound is held back by two samples whatever the setting.
final class OpenMPTCompressor: OpenMPTEffect {
    private static let kCompGain = 0, kCompAttack = 1, kCompRelease = 2, kCompThreshold = 3, kCompRatio = 4, kCompPredelay = 5
    private static let kCompNumParameters = 6

    private var m_param: [Float] = [0.5, 0.02, 150.0 / 2950.0, 2.0 / 3.0, 0.02, 1.0]

    // Calculated parameters and coefficients
    private var m_gain: Float = 0
    private var m_attack: Float = 0
    private var m_release: Float = 0
    private var m_threshold: Float = 0
    private var m_ratio: Float = 0
    private var m_predelay: Int32 = 0

    // State
    /// The last fifth of a second of the sound, left and right by turns, written backwards.
    private let m_buffer: UnsafeMutablePointer<Float>
    private var m_bufPos = 0
    private let m_bufSize: Int
    private var m_peak: Float = 0

    override init() {
        m_bufSize = Int(Int64(outputSampleRate) * 200 / 1000)
        m_buffer = .allocate(capacity: max(m_bufSize, 1) * 2)
        m_buffer.initialize(repeating: 0, count: max(m_bufSize, 1) * 2)
        super.init()
        RecalculateCompressorParams()
    }

    deinit {
        m_buffer.deallocate()
    }

    override var parameterCount: Int { Self.kCompNumParameters }

    override func parameter(_ index: Int) -> Float {
        index >= 0 && index < Self.kCompNumParameters ? m_param[index] : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.kCompNumParameters else { return }
        m_param[index] = OpenMPTDMO.unit(value)
        RecalculateCompressorParams()
    }

    override func resume() {
        m_buffer.update(repeating: 0, count: m_bufSize * 2)
        m_bufPos = 0
        m_peak = 0.0
        RecalculateCompressorParams()
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0, m_bufSize > 0 else { return }
        let buffer = m_buffer, bufSize = m_bufSize
        let attack = m_attack, release = m_release, threshold = m_threshold, ratio = m_ratio, gain = m_gain
        // How far back the sound is read from. OpenMPT works this out anew for every sample, from numbers that do not change.
        let readAhead = Int((m_predelay &+ Int32(truncatingIfNeeded: bufSize) &- 1) / 4096) % bufSize
        var bufPos = m_bufPos
        var peak = m_peak

        for i in 0 ..< frames {
            var leftIn = inLeft[i]
            var rightIn = inRight[i]

            buffer[bufPos &* 2] = leftIn
            buffer[bufPos &* 2 &+ 1] = rightIn

            leftIn = leftIn.magnitude
            rightIn = rightIn.magnitude

            let mono = (leftIn + rightIn) * (0.5 * 32768.0 * 32768.0)
            let monoLog = OpenMPTDMO.logGain(mono, 31, 5).magnitude * (1.0 / 2_147_483_648.0)

            var newPeak = monoLog + (peak - monoLog) * ((peak <= monoLog) ? attack : release)
            peak = newPeak

            if newPeak < threshold { newPeak = threshold }

            let compGain = (threshold - newPeak) * ratio + 0.9999999

            // Computes 2 ^ (2 ^ (log2(x) - 26) - 1) (x = 0...2^31)
            var compGainInt = OpenMPTDMO.truncate(compGain * 2_147_483_648.0)
            var compGainPow = compGainInt &<< 5
            compGainInt &>>= 26
            if compGainInt != 0 { // compGainInt >= 2^26
                compGainPow |= 0x8000_0000
                compGainInt &-= 1
            }
            compGainPow &>>= (31 &- compGainInt)

            var readOffset = readAhead &+ bufPos
            if readOffset >= bufSize { readOffset &-= bufSize }
            let outGain = (Float(compGainPow) * (1.0 / 2_147_483_648.0)) * gain
            outLeft[i] = buffer[readOffset &* 2] * outGain
            outRight[i] = buffer[readOffset &* 2 &+ 1] * outGain

            if bufPos == 0 { bufPos = bufSize }
            bufPos &-= 1
        }

        m_bufPos = bufPos
        m_peak = peak
    }

    private func GainInDecibel() -> Float { -60.0 + m_param[Self.kCompGain] * 120.0 }
    private func AttackTime() -> Float { 0.01 + m_param[Self.kCompAttack] * 499.99 }
    private func ReleaseTime() -> Float { 50.0 + m_param[Self.kCompRelease] * 2950.0 }
    private func ThresholdInDecibel() -> Float { -60.0 + m_param[Self.kCompThreshold] * 60.0 }
    private func CompressorRatio() -> Float { 1.0 + m_param[Self.kCompRatio] * 99.0 }
    private func PreDelay() -> Float { m_param[Self.kCompPredelay] * 4.0 }

    private func RecalculateCompressorParams() {
        let sampleRate = Float(outputSampleRate) / 1000.0
        m_gain = powf(10.0, GainInDecibel() / 20.0)
        m_attack = powf(10.0, -1.0 / (AttackTime() * sampleRate))
        m_release = powf(10.0, -1.0 / (ReleaseTime() * sampleRate))
        let _2e31: Float = 2_147_483_648.0
        let _2e26: Float = 67_108_864.0
        let ceiling: Float = _2e31 - 1.0
        let level: Float = (logf(powf(10.0, ThresholdInDecibel() / 20.0) * _2e31) * _2e26) / OpenMPTDMO.ln2 + _2e26
        m_threshold = (level < ceiling ? level : ceiling) * (1.0 / _2e31)
        m_ratio = 1.0 - (1.0 / CompressorRatio())
        m_predelay = Int32(OpenMPTDMO.truncate((PreDelay() * sampleRate) + 2.0) & 0x7FFF_FFFF)
    }
}
