// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its gargle (`soundlib/plugins/dmo/Gargle.cpp`).

/// OpenMPT's gargle, its remake of the one that came with Windows: the sound is turned up and down, or
/// on and off, so many times a second, which at a slow pace is a tremolo and at a fast one a buzz.
///
/// It has two settings: how many times a second, from once to a thousand times; and whether the sound
/// rises and falls steadily (a triangle) or is there for half of each turn and gone for the other half
/// (a square).
final class OpenMPTGargle: OpenMPTEffect {
    private static let kGargleRate = 0, kGargleWaveShape = 1, kGargleNumParameters = 2

    private var m_param: [Float] = [0.02, 0.0]
    /// How many frames a turn takes, how many of them are its first half, and how far into it this is.
    private var m_period = 2, m_periodHalf = 1, m_counter = 0

    override init() {
        super.init()
        RecalculateGargleParams()
    }

    override var parameterCount: Int { Self.kGargleNumParameters }

    override func parameter(_ index: Int) -> Float {
        index >= 0 && index < Self.kGargleNumParameters ? m_param[index] : 0
    }

    override func setParameter(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.kGargleNumParameters else { return }
        var value = safeClamp(value)
        if index == Self.kGargleWaveShape { value = value.rounded() }
        m_param[index] = value
        RecalculateGargleParams()
    }

    override func resume() {
        RecalculateGargleParams()
        m_counter = 0
    }

    override func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let triangle = m_param[Self.kGargleWaveShape] < 1.0
        let period = m_period, periodHalf = m_periodHalf
        var counter = m_counter
        var at = 0

        var frame = frames
        while frame != 0 {
            if counter < periodHalf {
                // The first half of a turn: the sound rises from nothing, or is simply there.
                let remain = min(frame, periodHalf - counter)
                if triangle {
                    let factor = 1.0 / Float(periodHalf)
                    for i in counter ..< counter + remain {
                        outLeft[at] = inLeft[at] * Float(i) * factor
                        outRight[at] = inRight[at] * Float(i) * factor
                        at += 1
                    }
                } else {
                    for _ in 0 ..< remain {
                        outLeft[at] = inLeft[at]
                        outRight[at] = inRight[at]
                        at += 1
                    }
                }
                frame -= remain
                counter += remain
            } else {
                // The second half: it falls back, or is gone. A turn of an odd number of frames has the
                // longer half here, and falls from above its full height.
                let remain = min(frame, period - counter)
                if triangle {
                    let factor = 1.0 / Float(periodHalf)
                    var i = period - counter
                    for _ in 0 ..< remain {
                        outLeft[at] = inLeft[at] * Float(i) * factor
                        outRight[at] = inRight[at] * Float(i) * factor
                        at += 1
                        i -= 1
                    }
                } else {
                    for _ in 0 ..< remain {
                        outLeft[at] = 0
                        outRight[at] = 0
                        at += 1
                    }
                }
                frame -= remain
                counter += remain
                if counter >= period { counter = 0 }
            }
        }
        m_counter = counter
    }

    private func RateInHertz() -> Int {
        Int((safeClamp(m_param[Self.kGargleRate]) * 999.0).rounded()) + 1
    }

    private func RecalculateGargleParams() {
        m_period = outputSampleRate / RateInHertz()
        if m_period < 2 { m_period = 2 }
        m_periodHalf = m_period / 2
        if m_counter > m_period { m_counter = m_period }
    }
}

/// A setting as it is taken in: nought for what is not a number, and otherwise kept between nought and one.
private func safeClamp(_ value: Float) -> Float {
    let value = value.isNaN ? 0 : value
    return value < 0 ? 0 : (1 < value ? 1 : value)
}
