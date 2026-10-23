// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// How loud a stretch of sound is heard, and how near it comes to the top: its integrated loudness as
/// ITU-R BS.1770-4 measures it (the measure EBU R128 and the ReplayGain of today are built on), and its
/// true peak, the highest the waveform reaches between the samples as well as at them.
///
/// The sound is taken a block at a time, interleaved stereo at `outputSampleRate`, and nothing of it
/// is kept but a sum for every tenth of a second, so a tune of any length can be measured as it is
/// rendered.
public struct LoudnessMeter {
    /// One second-order section of the weighting, in direct form I, for one channel.
    private struct Section {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        @inline(__always) mutating func step(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// The "K" weighting of BS.1770: a shelf that lifts the treble by about 4 dB, as a head does, then
    /// a high pass that leaves out the lowest bass. The sections are worked out from the standard's
    /// analogue prototype for the rate in use, as libebur128 does; at 48 kHz they are the standard's own.
    private static func weighting() -> (shelf: Section, highPass: Section) {
        let rate = Double(outputSampleRate)
        var k = tan(Double.pi * 1681.974450955533 / rate), q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Section(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                            b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        k = tan(Double.pi * 38.13547087602444 / rate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        let highPass = Section(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return (shelf, highPass)
    }

    /// How many samples each point between the samples is worked out from, in finding the true peak.
    private static let taps = 12

    /// The interpolation for the true peak: four times the rate, as BS.1770's annex 2 has it, by a
    /// sinc in a Kaiser window. Three phases, a quarter, a half and three quarters of the way from one
    /// sample to the next; the fourth is the sample itself.
    private static let phases: [Double] = {
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1 ..< 30 {
                term *= (x / Double(2 * k)) * (x / Double(2 * k))
                sum += term
            }
            return sum
        }
        let beta = 6.0, half = Double(taps / 2)
        var phases = [Double]()
        for p in 1 ... 3 {
            for t in 0 ..< taps {
                let x = Double(t - taps / 2 + 1) - Double(p) / 4
                let sinc = sin(Double.pi * x) / (Double.pi * x)
                let r = x / half
                phases.append(abs(r) <= 1 ? sinc * i0(beta * (1 - r * r).squareRoot()) / i0(beta) : 0)
            }
        }
        return phases
    }()

    private var left: (Section, Section), right: (Section, Section)
    /// The weighted power of each tenth of a second so far: both channels' squares, summed.
    private var tenths = [Double]()
    private var tenth = 0.0, inTenth = 0
    private let framesInTenth = outputSampleRate / 10
    /// The last `taps` samples of each channel, written twice over so that they can always be read in
    /// order from one place: left at 0, right at 2 × `taps`.
    private var recent: [Double]
    private var at = 0
    private var peak = 0.0
    /// How many frames have been taken.
    public private(set) var frames = 0

    public init() {
        let (shelf, highPass) = Self.weighting()
        left = (shelf, highPass)
        right = (shelf, highPass)
        recent = Array(repeating: 0, count: 4 * Self.taps)
    }

    /// Takes `frames` more stereo frames: 2 × `frames` floats.
    public mutating func take(_ samples: UnsafePointer<Float>, frames count: Int) {
        let taps = Self.taps
        Self.phases.withUnsafeBufferPointer { phases in
            recent.withUnsafeMutableBufferPointer { recent in
                for i in 0 ..< count {
                    let l = Double(samples[2 * i]), r = Double(samples[2 * i + 1])
                    let wl = left.1.step(left.0.step(l)), wr = right.1.step(right.0.step(r))
                    tenth += wl * wl + wr * wr
                    inTenth += 1
                    if inTenth == framesInTenth {
                        tenths.append(tenth)
                        tenth = 0
                        inTenth = 0
                    }
                    recent[at] = l; recent[at + taps] = l
                    recent[2 * taps + at] = r; recent[3 * taps + at] = r
                    at = at == taps - 1 ? 0 : at + 1
                    peak = max(peak, Self.highest(recent, from: at, phases))
                }
            }
        }
        frames += count
    }

    /// The highest of the three points between the samples at the middle of the last `taps`, and of
    /// the sample before them, on either channel.
    @inline(__always) private static func highest(_ recent: UnsafeMutableBufferPointer<Double>, from at: Int,
                                                  _ phases: UnsafeBufferPointer<Double>) -> Double {
        var top = 0.0
        for channel in 0 ..< 2 {
            let base = channel * 2 * taps + at
            top = max(top, abs(recent[base + taps / 2 - 1]))
            for p in 0 ..< 3 {
                var v = 0.0
                for t in 0 ..< taps { v += recent[base + t] * phases[p * taps + t] }
                top = max(top, abs(v))
            }
        }
        return top
    }

    /// The integrated loudness of all that has been taken, in LUFS: the mean power of its blocks of
    /// 400 ms, each overlapping the last by three quarters, leaving out those quieter than -70 LUFS and
    /// then those more than 10 LU below the mean of the rest. None, if every block was left out or there
    /// was less than one.
    public var loudness: Double? {
        guard tenths.count >= 4 else { return nil }
        var blocks = [Double]()
        blocks.reserveCapacity(tenths.count - 3)
        let length = Double(4 * framesInTenth)
        for j in 0 ..< tenths.count - 3 {
            blocks.append((tenths[j] + tenths[j + 1] + tenths[j + 2] + tenths[j + 3]) / length)
        }
        func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
        func mean(above gate: Double) -> Double? {
            var sum = 0.0, count = 0
            for power in blocks where power > 0 && lufs(power) > gate {
                sum += power
                count += 1
            }
            return count == 0 ? nil : sum / Double(count)
        }
        guard let ungated = mean(above: -70) else { return nil }
        return mean(above: max(-70, lufs(ungated) - 10)).map(lufs)
    }

    /// The true peak of all that has been taken, in dB of full scale (dBTP): what a sample of 1 is.
    public var truePeak: Double {
        // The points between the last samples need the samples after them: they are taken as silence.
        var rest = self
        let silence = [Float](repeating: 0, count: Self.taps)
        silence.withUnsafeBufferPointer { rest.take($0.baseAddress!, frames: Self.taps / 2) }
        return 20 * log10(max(rest.peak, 1e-12))
    }
}
