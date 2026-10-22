// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its echo of Symphonie's kind (`soundlib/plugins/SymMODEcho.cpp`).

/// The echo of Symphonie, an Amiga tracker, as OpenMPT has it for the tunes of that tracker and for
/// any other that asks for it. What is heard is the sound and, with it, what went round so many
/// ticks of the tune ago; and what goes round is the two together, turned down.
///
/// It has three settings: which kind of echo it is (none, each side to itself, each side to the
/// other, that again turned down the other way, or both sides as one in the middle), how many ticks
/// it takes, and how far it is turned down each time round, as a power of two. A file keeps them as
/// those three bytes after the word "Echo", so this is one of the effects that reads its own bytes.
final class OpenMPTSymMODEcho: OpenMPTEffect {
    private static let kEchoType = 0, kEchoDelay = 1, kEchoFeedback = 2, kEchoNumParameters = 3
    private static let off: UInt8 = 0, normal: UInt8 = 1, cross: UInt8 = 2, cross2: UInt8 = 3, center: UInt8 = 4, numTypes: UInt8 = 5

    /// What went round, the left and the right of each frame side by side.
    private var m_delayLine: [Float] = []
    private var m_writePos = 0
    private var m_feedback: Float = 0.5
    /// The settings as the file has them.
    private var m_chunk: [UInt8] = [0, 4, 1]

    override init() {
        super.init()
        RecalculateEchoParams()
    }

    override var parameterCount: Int { Self.kEchoNumParameters }

    override func parameter(_ index: Int) -> Float {
        index >= 0 && index < Self.kEchoNumParameters ? Float(m_chunk[index]) / 127.0 : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.kEchoNumParameters else { return }
        let value = value.isNaN ? 0 : value
        m_chunk[index] = UInt8(((value < 0 ? 0 : (1 < value ? 1 : value)) * 127.0).rounded())
        RecalculateEchoParams()
    }

    /// The seven bytes of a file's "Echo" and three settings. Anything else is left alone, and is then
    /// for the reader of the file to try as a list of numbered settings, as OpenMPT does.
    override func restore(chunk: [UInt8]) -> Bool {
        guard chunk.count == 7, chunk[0] == 0x45, chunk[1] == 0x63, chunk[2] == 0x68, chunk[3] == 0x6F else { return false }
        m_chunk = [chunk[4], chunk[5], chunk[6]]
        RecalculateEchoParams()
        return true
    }

    override func resume() {
        for i in m_delayLine.indices { m_delayLine[i] = 0 }
        m_writePos = 0
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        // (A tune of Symphonie's has one tempo all through. In another kind of file a tick may be any length.)
        let delayTime = tickFrames * Int(m_chunk[Self.kEchoDelay])
        if m_delayLine.count < delayTime * 2 { m_delayLine += [Float](repeating: 0, count: delayTime * 2 - m_delayLine.count) }
        let dspType = m_chunk[Self.kEchoType]
        guard dspType != Self.off, delayTime > 0 else {
            // Switched off while it is going round, it keeps what was going round.
            for i in 0 ..< frames {
                outLeft[i] = inLeft[i]
                outRight[i] = inRight[i]
            }
            return
        }
        let feedback = m_feedback
        var writePos = m_writePos
        m_delayLine.withUnsafeMutableBufferPointer { line in
            guard let delayLine = line.baseAddress else { return }
            for i in 0 ..< frames {
                if writePos >= delayTime { writePos = 0 }
                var readPos = writePos - delayTime
                if readPos < 0 { readPos += delayTime }
                let lDry = inLeft[i], rDry = inRight[i]
                let lDelay = delayLine[readPos * 2], rDelay = delayLine[readPos * 2 + 1]

                outLeft[i] = lDry + lDelay
                outRight[i] = rDry + rDelay

                var lOut: Float = 0, rOut: Float = 0
                switch dspType {
                case Self.normal:
                    lOut = (lDelay + lDry) * feedback
                    rOut = (rDelay + rDry) * feedback
                case Self.cross, Self.cross2:
                    lOut = (rDelay + rDry) * feedback
                    rOut = (lDelay + lDry) * feedback
                case Self.center:
                    lOut = (lDelay + (lDry + rDry) * 0.5) * feedback
                    rOut = lOut
                default:
                    break
                }
                // Too small to matter, and slow to work with.
                if lOut.magnitude < 1e-24 { lOut = 0 }
                if rOut.magnitude < 1e-24 { rOut = 0 }

                delayLine[writePos * 2] = lOut
                delayLine[writePos * 2 + 1] = rOut
                writePos += 1
            }
        }
        m_writePos = writePos
    }

    private func RecalculateEchoParams() {
        if m_chunk[Self.kEchoType] >= Self.numTypes { m_chunk[Self.kEchoType] = 0 }
        if m_chunk[Self.kEchoDelay] > 127 { m_chunk[Self.kEchoDelay] = 127 }
        if m_chunk[Self.kEchoFeedback] > 127 { m_chunk[Self.kEchoFeedback] = 127 }
        if m_chunk[Self.kEchoType] == Self.cross2 {
            m_feedback = 1.0 - powf(2.0, -Float(Int(m_chunk[Self.kEchoFeedback]) + 1))
        } else {
            m_feedback = powf(2.0, -Float(m_chunk[Self.kEchoFeedback]))
        }
    }
}
