// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its echo (`soundlib/plugins/dmo/Echo.cpp`).

/// OpenMPT's echo, its remake of the one that came with Windows. Each side is heard again after a time of
/// its own, and what was heard goes round again more quietly, for as long as there is anything left of it.
///
/// It has five settings: how much of what comes out is the echo and how much the sound itself; how much
/// of an echo goes round again; how long the left takes to come back and how long the right, each from a
/// thousandth of a second to two seconds; and whether the echoes change sides every time round.
final class OpenMPTEcho: OpenMPTEffect {
    private static let kEchoWetDry = 0, kEchoFeedback = 1, kEchoLeftDelay = 2, kEchoRightDelay = 3, kEchoPanDelay = 4, kEchoNumParameters = 5

    private var m_param: [Float]
    /// The last two seconds of what went round, the left and the right of each frame side by side.
    private let m_delayLine: UnsafeMutablePointer<Float>
    /// How long that is in frames, and where in it the next frame goes.
    private let m_bufferSize: Int
    private var m_writePos = 0
    /// How far back the left's echo and the right's are, in frames.
    private var m_delayTime0 = 0, m_delayTime1 = 0
    /// How much of the sound goes into the echo: the less, the more of the echo goes round again, so
    /// that the two together are as loud as the sound was.
    private var m_initialFeedback: Float = 0
    private var m_crossEcho = false

    override init() {
        m_param = [0.5, 0.5, (500.0 - 1.0) / 1999.0, (500.0 - 1.0) / 1999.0, 0.0]
        m_bufferSize = outputSampleRate * 2
        m_delayLine = .allocate(capacity: m_bufferSize * 2)
        m_delayLine.initialize(repeating: 0, count: m_bufferSize * 2)
        super.init()
        RecalculateEchoParams()
    }

    deinit {
        m_delayLine.deallocate()
    }

    override var parameterCount: Int { Self.kEchoNumParameters }

    override func parameter(_ index: Int) -> Float {
        index >= 0 && index < Self.kEchoNumParameters ? m_param[index] : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.kEchoNumParameters else { return }
        var value = safeClamp(value)
        if index == Self.kEchoPanDelay { value = value.rounded() }
        m_param[index] = value
        RecalculateEchoParams()
    }

    override func resume() {
        RecalculateEchoParams()
        m_delayLine.update(repeating: 0, count: m_bufferSize * 2)
        m_writePos = 0
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let wetMix = m_param[Self.kEchoWetDry], dryMix = 1 - wetMix
        let feedback = m_param[Self.kEchoFeedback], initialFeedback = m_initialFeedback
        let delayLine = m_delayLine, bufferSize = m_bufferSize
        // Each side hears its own echo, or the other's if they are to change sides, and it is the time of
        // the side that is heard that says how far back.
        let readLeft = m_crossEcho ? 1 : 0, readRight = 1 - readLeft
        let delayLeft = readLeft == 0 ? m_delayTime0 : m_delayTime1, delayRight = readRight == 0 ? m_delayTime0 : m_delayTime1
        var writePos = m_writePos

        for i in 0 ..< frames {
            // The left is put away before the right is looked up: with the longest time of all and the
            // sides changing, what the right hears is what the left has only now put there.
            var readPos = writePos - delayLeft
            if readPos < 0 { readPos += bufferSize }
            var chnInput = inLeft[i]
            var chnDelay = delayLine[readPos * 2 + readLeft]
            var chnOutput = chnInput * initialFeedback
            chnOutput += chnDelay * feedback
            // Too small to matter, and slow to work with.
            if chnOutput.magnitude < 1e-24 { chnOutput = 0 }
            delayLine[writePos * 2] = chnOutput
            outLeft[i] = chnInput * dryMix + chnDelay * wetMix

            readPos = writePos - delayRight
            if readPos < 0 { readPos += bufferSize }
            chnInput = inRight[i]
            chnDelay = delayLine[readPos * 2 + readRight]
            chnOutput = chnInput * initialFeedback
            chnOutput += chnDelay * feedback
            if chnOutput.magnitude < 1e-24 { chnOutput = 0 }
            delayLine[writePos * 2 + 1] = chnOutput
            outRight[i] = chnInput * dryMix + chnDelay * wetMix

            writePos += 1
            if writePos == bufferSize { writePos = 0 }
        }
        m_writePos = writePos
    }

    private func RecalculateEchoParams() {
        let feedback = m_param[Self.kEchoFeedback]
        m_initialFeedback = (1.0 - (feedback * feedback)).squareRoot()
        m_delayTime0 = delayTime(m_param[Self.kEchoLeftDelay])
        m_delayTime1 = delayTime(m_param[Self.kEchoRightDelay])
        m_crossEcho = m_param[Self.kEchoPanDelay] > 0.5
    }

    /// A setting as a time in frames, worked out in single precision as OpenMPT does, and never longer
    /// than what is kept.
    private func delayTime(_ param: Float) -> Int {
        let frames = (1.0 + param * 1999.0) / 1000.0 * Float(outputSampleRate)
        return min(max(Int(frames), 0), m_bufferSize)
    }
}

/// A setting as it is taken in: nought for what is not a number, and otherwise kept between nought and one.
private func safeClamp(_ value: Float) -> Float {
    let value = value.isNaN ? 0 : value
    return value < 0 ? 0 : (1 < value ? 1 : value)
}
