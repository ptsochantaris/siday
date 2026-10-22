// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its chorus (`soundlib/plugins/dmo/Chorus.cpp`) and its flanger (`soundlib/plugins/dmo/Flanger.cpp`).

import SidayFoundation

/// OpenMPT's chorus, its remake of the one that came with Windows. The sound is heard beside a copy of
/// itself that comes a little late, and how late keeps changing, slowly, so that the copy drifts flat and
/// sharp against the sound as a second player would.
///
/// It has seven settings: how much of what comes out is the copy and how much the sound itself; how far
/// the lateness swings; how often it swings, up to ten times a second; whether it swings smoothly, as a
/// sine does, or at a steady pace one way and then the other (which OpenMPT calls square, though it is a
/// triangle); how far the right's swing is out of step with the left's, in quarter turns; how much of the
/// copy is fed back into what is copied, which can be less than nothing; and how late the copy is when
/// the swing is at rest, up to a fiftieth of a second.
///
/// The chorus copies the two sides mixed into one. The flanger below is the same machine with a shorter
/// lateness and its settings in another order, and is made from this.
class OpenMPTChorus: OpenMPTEffect {
    private static let kChorusWetDryMix = 0, kChorusDepth = 1, kChorusFrequency = 2, kChorusWaveShape = 3, kChorusPhase = 4, kChorusFeedback = 5, kChorusDelay = 6
    fileprivate static let kChorusNumParameters = 7
    /// The float nearest to pi, which is what OpenMPT uses, and is not Swift's `Float.pi`: that one is
    /// the float below it.
    private static let pi: Float = 0x1.921FB6p1

    fileprivate var m_param: [Float]

    // What the settings come to.
    /// The swing: two numbers that go round each other as a sine and a cosine do, or that each go up
    /// steadily and start again, and how far they move in a frame.
    fileprivate var m_waveShapeMin: Float = 0, m_waveShapeMax: Float = 0, m_waveShapeVal: Float = 0
    /// How far the lateness swings and where it rests, in 4096ths of a frame.
    private var m_depthDelay: Float = 0
    private var m_delayOffset: Int32 = 0
    /// True if each side has a copy of its own, and the sound itself comes out two frames late to match
    /// the copy's least lateness. OpenMPT's first flanger, like its chorus, did neither.
    private let m_isFlanger: Bool

    // Where it has got to.
    /// The last 3.84 seconds of what is copied. Only the left is used unless each side has its own.
    private let m_bufferL: UnsafeMutablePointer<Float>, m_bufferR: UnsafeMutablePointer<Float>
    private let m_DryBuffer: UnsafeMutablePointer<Float>
    private let m_bufSize: Int32
    private var m_bufPos: Int32 = 0
    private var m_delayL: Int32 = 0, m_delayR: Int32 = 0
    private var m_dryWritePos = 0

    override convenience init() {
        self.init(isFlanger: false, parameters: [0.5, 0.1, 0.11, 1.0, 0.75, (25.0 + 99.0) / 198.0, 0.8])
    }

    fileprivate init(isFlanger: Bool, parameters: [Float]) {
        m_param = parameters
        m_isFlanger = isFlanger
        let size = Int(Int64(outputSampleRate) * 3840 / 1000)
        m_bufSize = Int32(truncatingIfNeeded: size)
        m_bufferL = .allocate(capacity: size)
        m_bufferL.initialize(repeating: 0, count: size)
        m_bufferR = .allocate(capacity: isFlanger ? size : 1)
        m_bufferR.initialize(repeating: 0, count: isFlanger ? size : 1)
        m_DryBuffer = .allocate(capacity: 6)
        m_DryBuffer.initialize(repeating: 0, count: 6)
        super.init()
        resume()
    }

    deinit {
        m_bufferL.deallocate()
        m_bufferR.deallocate()
        m_DryBuffer.deallocate()
    }

    override var parameterCount: Int { Self.kChorusNumParameters }

    override func parameter(_ index: Int) -> Float {
        index >= 0 && index < Self.kChorusNumParameters ? m_param[index] : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        setParameter(index, value, waveShape: Self.kChorusWaveShape, phase: Self.kChorusPhase)
    }

    /// The chorus and the flanger take a setting alike, but keep the shape of the swing in different places.
    fileprivate func setParameter(_ index: Int, _ value: Float, waveShape: Int, phase: Int) {
        guard index >= 0, index < Self.kChorusNumParameters else { return }
        var value = safeClamp(value)
        if index == waveShape {
            value = value.rounded()
            if m_param[index] != value {
                // A swing of another shape starts from rest.
                m_waveShapeMin = 0.0
                m_waveShapeMax = 0.5 + value * 0.5
            }
        } else if index == phase {
            value = (value * 4.0).rounded() / 4.0
        }
        m_param[index] = value
        RecalculateChorusParams()
    }

    override func resume() {
        m_bufPos = 0
        m_bufferL.update(repeating: 0, count: Int(m_bufSize))
        if m_isFlanger { m_bufferR.update(repeating: 0, count: Int(m_bufSize)) }
        m_DryBuffer.update(repeating: 0, count: 6)
        RecalculateChorusParams()

        m_waveShapeMin = 0.0
        m_waveShapeMax = IsSquare() ? 0.5 : 1.0
        m_delayL = m_delayOffset
        m_delayR = m_delayOffset
        m_dryWritePos = 0
    }

    /// Where in what is kept a lateness, in 4096ths of a frame, has its whole frame. OpenMPT leaves a
    /// lateness that is out of all reason to read outside what is kept; here it reads inside it.
    @inline(__always)
    private static func GetBufferIntOffset(_ fpOffset: Int32, _ bufPos: Int32, _ bufSize: Int32) -> Int {
        var fpOffset = fpOffset
        if fpOffset < 0 { fpOffset = fpOffset &+ bufSize &* 4096 }
        let offset = (bufPos &+ (fpOffset / 4096)) % bufSize
        return Int(offset < 0 ? offset &+ bufSize : offset)
    }

    /// A number as a whole one, the way C does it, for one that fits; no number the swing can come to does not.
    @inline(__always)
    private static func truncated(_ value: Float) -> Int32 {
        value > -2_147_483_648.0 && value < 2_147_483_648.0 ? Int32(value) : 0
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let isSquare = IsSquare()
        let feedback = Feedback() / 100.0
        let wetDryMix = WetDryMix()
        let phase = Phase()
        let isFlanger = m_isFlanger
        let bufferL = m_bufferL, bufferR = isFlanger ? m_bufferR : m_bufferL
        let DryBufferL = m_DryBuffer, DryBufferR = m_DryBuffer + 3
        let bufSize = m_bufSize, delayOffset = m_delayOffset, depthDelay = m_depthDelay
        let waveShapeVal = m_waveShapeVal
        // Which way each side's lateness goes with the swing, and whether the right follows the second of
        // the swing's two numbers, which is a quarter turn from the first.
        let signL: Int32 = phase < 4 ? 1 : -1, signR: Int32 = phase < 2 ? -1 : 1
        let rightUsesMax = phase % 2 != 0
        var waveShapeMin = m_waveShapeMin, waveShapeMax = m_waveShapeMax
        var bufPos = m_bufPos, delayL = m_delayL, delayR = m_delayR
        var dryWritePos = m_dryWritePos

        for i in 0 ..< frames {
            let leftIn = inLeft[i]
            let rightIn = inRight[i]

            let readOffset = Self.GetBufferIntOffset(delayOffset, bufPos, bufSize)
            let writeOffset = Int(bufPos)
            if isFlanger {
                DryBufferL[dryWritePos] = leftIn
                DryBufferR[dryWritePos] = rightIn
                bufferL[writeOffset] = (bufferL[readOffset] * feedback) + leftIn
                bufferR[writeOffset] = (bufferR[readOffset] * feedback) + rightIn
            } else {
                bufferL[writeOffset] = (bufferL[readOffset] * feedback) + (leftIn + rightIn) * 0.5
            }

            let waveMin: Float, waveMax: Float
            if isSquare {
                waveShapeMin += waveShapeVal
                waveShapeMax += waveShapeVal
                if waveShapeMin > 1 { waveShapeMin -= 2 }
                if waveShapeMax > 1 { waveShapeMax -= 2 }
                waveMin = waveShapeMin.magnitude * 2 - 1
                waveMax = waveShapeMax.magnitude * 2 - 1
            } else {
                waveShapeMin = waveShapeMax * waveShapeVal + waveShapeMin
                waveShapeMax = waveShapeMax - waveShapeMin * waveShapeVal
                waveMin = waveShapeMin
                waveMax = waveShapeMax
            }

            let leftDelayIn = isFlanger ? DryBufferL[(dryWritePos + 2) % 3] : leftIn
            let rightDelayIn = isFlanger ? DryBufferR[(dryWritePos + 2) % 3] : rightIn

            // The copy is taken between two frames, by a straight line from one to the next.
            let left1 = bufferL[Self.GetBufferIntOffset(delayL, bufPos, bufSize)]
            let left2 = bufferL[Self.GetBufferIntOffset(delayL &+ 4096, bufPos, bufSize)]
            var fracPos = Float(delayL & 0xFFF) * (1.0 / 4096.0)
            let leftOut = (left2 - left1) * fracPos + left1
            outLeft[i] = leftDelayIn + (leftOut - leftDelayIn) * wetDryMix

            let right1 = bufferR[Self.GetBufferIntOffset(delayR, bufPos, bufSize)]
            let right2 = bufferR[Self.GetBufferIntOffset(delayR &+ 4096, bufPos, bufSize)]
            fracPos = Float(delayR & 0xFFF) * (1.0 / 4096.0)
            let rightOut = (right2 - right1) * fracPos + right1
            outRight[i] = rightDelayIn + (rightOut - rightDelayIn) * wetDryMix

            if dryWritePos <= 0 { dryWritePos += 3 }
            dryWritePos -= 1

            delayL = delayOffset &+ signL &* Self.truncated(waveMin * depthDelay)
            delayR = delayOffset &+ signR &* Self.truncated((rightUsesMax ? waveMax : waveMin) * depthDelay)

            if bufPos <= 0 { bufPos += bufSize }
            bufPos -= 1
        }

        m_waveShapeMin = waveShapeMin
        m_waveShapeMax = waveShapeMax
        m_bufPos = bufPos
        m_delayL = delayL
        m_delayR = delayR
        m_dryWritePos = dryWritePos
    }

    // What the settings stand for. The flanger keeps them in other places, and its lateness is shorter.
    fileprivate func WetDryMix() -> Float { m_param[Self.kChorusWetDryMix] }
    fileprivate func IsSquare() -> Bool { m_param[Self.kChorusWaveShape] < 1 }
    fileprivate func Depth() -> Float { m_param[Self.kChorusDepth] }
    /// In hundredths, from 99 the wrong way up to 99.
    fileprivate func Feedback() -> Float { -99.0 + m_param[Self.kChorusFeedback] * 198.0 }
    /// In thousandths of a second.
    fileprivate func Delay() -> Float { m_param[Self.kChorusDelay] * 20.0 }
    fileprivate func FrequencyInHertz() -> Float { m_param[Self.kChorusFrequency] * 10.0 }
    /// From nought to four: half a turn behind, a quarter behind, in step, a quarter ahead, half ahead.
    fileprivate func Phase() -> UInt32 { UInt32((m_param[Self.kChorusPhase] * 4.0).rounded()) }

    fileprivate func RecalculateChorusParams() {
        let sampleRate = Float(outputSampleRate)

        let delaySamples = Delay() * sampleRate / 1000.0
        m_depthDelay = Depth() * delaySamples * 2048.0
        m_delayOffset = Int32((4096.0 * (delaySamples + 2.0)).rounded())
        let frequencySamples = FrequencyInHertz() / sampleRate
        if IsSquare() {
            m_waveShapeVal = frequencySamples * 2.0
        } else {
            m_waveShapeVal = sinf(frequencySamples * Self.pi) * 2.0
        }
    }
}

/// OpenMPT's flanger, its remake of the one that came with Windows: the chorus's machine with a copy that
/// is at most a 250th of a second late, which is too close to the sound to be heard apart from it and
/// instead colours it, the colour sweeping up and down as the lateness swings.
///
/// Its settings are the chorus's seven in another order: the mix, the shape of the swing, how often it
/// swings, how far, the right's step against the left's, the feeding back, and the lateness at rest.
///
/// OpenMPT has had two. The first copied the two sides mixed into one, as the chorus does, and let the
/// sound itself through at once; the one that replaced it copies each side for itself and holds the sound
/// back by two frames. A tune made with the first asks for it by name ("Flanger (Legacy)") and still gets it.
final class OpenMPTFlanger: OpenMPTChorus {
    private static let kFlangerWetDryMix = 0, kFlangerWaveShape = 1, kFlangerFrequency = 2, kFlangerDepth = 3, kFlangerPhase = 4, kFlangerFeedback = 5, kFlangerDelay = 6

    init(legacy: Bool) {
        super.init(isFlanger: !legacy, parameters: [0.5, 1.0, 0.025, 1.0, 0.5, (-50.0 + 99.0) / 198.0, 0.5])
    }

    convenience init() {
        self.init(legacy: false)
    }

    override func setParameter(_ index: Int, _ value: Float) {
        setParameter(index, value, waveShape: Self.kFlangerWaveShape, phase: Self.kFlangerPhase)
    }

    override fileprivate func WetDryMix() -> Float { m_param[Self.kFlangerWetDryMix] }
    override fileprivate func IsSquare() -> Bool { m_param[Self.kFlangerWaveShape] < 1 }
    override fileprivate func Depth() -> Float { m_param[Self.kFlangerDepth] }
    override fileprivate func Feedback() -> Float { -99.0 + m_param[Self.kFlangerFeedback] * 198.0 }
    override fileprivate func Delay() -> Float { m_param[Self.kFlangerDelay] * 4.0 }
    override fileprivate func FrequencyInHertz() -> Float { m_param[Self.kFlangerFrequency] * 10.0 }
    override fileprivate func Phase() -> UInt32 { UInt32((m_param[Self.kFlangerPhase] * 4.0).rounded()) }
}

/// A setting as it is taken in: nought for what is not a number, and otherwise kept between nought and one.
private func safeClamp(_ value: Float) -> Float {
    let value = value.isNaN ? 0 : value
    return value < 0 ? 0 : (1 < value ? 1 : value)
}
