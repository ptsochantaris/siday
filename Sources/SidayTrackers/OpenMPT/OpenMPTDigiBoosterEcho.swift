// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its echo of DigiBooster Pro's kind (`soundlib/plugins/DigiBoosterEcho.cpp`), which is based on code by
// Grzegorz Kraszewski, used under the BSD 2-Clause licence.

import SidayFoundation

/// The echo of DigiBooster Pro, an Amiga tracker, as OpenMPT has it for the tunes of that tracker and for
/// any other that asks for it. Both sides are heard again after the same time, and what goes round can
/// be passed from each side to the other on the way.
///
/// It has four settings, which the tracker counted from nought to 255 and OpenMPT keeps so: how long the
/// echo takes, in five-hundredths of a second (and nought, which the tracker took for 167); how much of
/// what goes round is the echo and how much the sound; how much of what comes out is the echo; and how
/// much of what goes round crosses to the other side.
///
/// A file keeps them as those four bytes after the word "Echo", and not as OpenMPT's numbers from nought
/// to one, so this is one of the effects that reads its own bytes.
final class OpenMPTDigiBoosterEcho: OpenMPTEffect {
    private static let kEchoDelay = 0, kEchoFeedback = 1, kEchoMix = 2, kEchoCross = 3, kEchoNumParameters = 4

    /// The last half second and a little of what went round, the left and the right of each frame side by side.
    private let m_delayLine: UnsafeMutablePointer<Float>
    private let m_bufferSize: Int
    private var m_writePos = 0
    private var m_delayTime = 0

    // How much of what goes where: P for the echo or the crossing, N for what is left over from it.
    private var m_PMix: Float = 0, m_NMix: Float = 0
    private var m_PCrossPBack: Float = 0, m_PCrossNBack: Float = 0
    private var m_NCrossPBack: Float = 0, m_NCrossNBack: Float = 0

    /// The settings as the file has them.
    private var m_chunk: [UInt8] = [80, 150, 80, 255]

    override init() {
        m_bufferSize = (outputSampleRate >> 1) + (outputSampleRate >> 6)
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
        index >= 0 && index < Self.kEchoNumParameters ? Float(m_chunk[index]) / 255.0 : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.kEchoNumParameters else { return }
        let value = value.isNaN ? 0 : value
        m_chunk[index] = UInt8(((value < 0 ? 0 : (1 < value ? 1 : value)) * 255.0).rounded())
        RecalculateEchoParams()
    }

    /// The eight bytes of a file's "Echo" and four settings. Anything else is left alone, and is then for
    /// the reader of the file to try as a list of numbered settings, as OpenMPT does.
    override func restore(chunk: [UInt8]) -> Bool {
        guard chunk.count == 8, chunk[0] == 0x45, chunk[1] == 0x63, chunk[2] == 0x68, chunk[3] == 0x6F else { return false }
        m_chunk = [chunk[4], chunk[5], chunk[6], chunk[7]]
        RecalculateEchoParams()
        return true
    }

    override func resume() {
        RecalculateEchoParams()
        m_delayLine.update(repeating: 0, count: m_bufferSize * 2)
        m_writePos = 0
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let delayLine = m_delayLine, bufferSize = m_bufferSize, delayTime = m_delayTime
        let PMix = m_PMix, NMix = m_NMix
        let PCrossPBack = m_PCrossPBack, PCrossNBack = m_PCrossNBack, NCrossPBack = m_NCrossPBack, NCrossNBack = m_NCrossNBack
        var writePos = m_writePos

        for i in 0 ..< frames {
            var readPos = writePos - delayTime
            if readPos < 0 { readPos += bufferSize }
            let l = inLeft[i], r = inRight[i]
            let lDelay = delayLine[readPos * 2], rDelay = delayLine[readPos * 2 + 1]

            var al = l * NCrossNBack
            al += r * PCrossNBack
            al += lDelay * NCrossPBack
            al += rDelay * PCrossPBack

            var ar = r * NCrossNBack
            ar += l * PCrossNBack
            ar += rDelay * NCrossPBack
            ar += lDelay * PCrossPBack

            // Too small to matter, and slow to work with.
            if al.magnitude < 1e-24 { al = 0 }
            if ar.magnitude < 1e-24 { ar = 0 }

            delayLine[writePos * 2] = al
            delayLine[writePos * 2 + 1] = ar
            writePos += 1
            if writePos == bufferSize { writePos = 0 }

            outLeft[i] = l * NMix + lDelay * PMix
            outRight[i] = r * NMix + rDelay * PMix
        }
        m_writePos = writePos
    }

    private func RecalculateEchoParams() {
        let delay = Int(m_chunk[Self.kEchoDelay]), feedback = Int(m_chunk[Self.kEchoFeedback]), mix = Int(m_chunk[Self.kEchoMix]), cross = Int(m_chunk[Self.kEchoCross])
        // OpenMPT found the 167 by listening to DigiBooster Pro 2.21.
        m_delayTime = min(((delay != 0 ? delay : 167) * outputSampleRate + 250) / 500, m_bufferSize)
        m_PMix = Float(mix) * (1.0 / 256.0)
        m_NMix = Float(256 - mix) * (1.0 / 256.0)
        m_PCrossPBack = Float(cross * feedback) * (1.0 / 65536.0)
        m_PCrossNBack = Float(cross * (256 - feedback)) * (1.0 / 65536.0)
        m_NCrossPBack = Float((cross - 256) * feedback) * (1.0 / 65536.0)
        m_NCrossNBack = Float((cross - 256) * (feedback - 256)) * (1.0 / 65536.0)
    }
}
