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
    /// One second-order section of the weighting, in direct form I, for both channels at once: each
    /// channel in a lane of its own, worked out as it would be alone.
    private struct Section {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var x1 = SIMD2<Double>(), x2 = SIMD2<Double>(), y1 = SIMD2<Double>(), y2 = SIMD2<Double>()

        @inline(__always) mutating func step(_ x: SIMD2<Double>) -> SIMD2<Double> {
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

    private var shelf: Section, highPass: Section
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
        (shelf, highPass) = Self.weighting()
        recent = Array(repeating: 0, count: 4 * Self.taps)
    }

    /// How far above the largest of the samples it is worked out from any point between them can be: the
    /// largest of the phases' sums of the sizes of their taps (or the sample itself, if that is larger),
    /// and a little more for the rounding of adding them up. A stretch of sound whose samples, by that,
    /// cannot reach the true peak found so far is not looked at more closely: nothing in it could change it.
    private static let headroom: Double = {
        var most = 1.0
        for p in 0 ..< 3 { most = max(most, (0 ..< taps).reduce(0) { $0 + abs(phases[p * taps + $1]) }) }
        return most * (1 + 1e-9)
    }()

    /// How many frames at a time are looked at for whether they could reach the true peak.
    private static let stretch = 32

    /// Takes `frames` more stereo frames: 2 × `frames` floats.
    public mutating func take(_ samples: UnsafePointer<Float>, frames count: Int) {
        // The loudness.
        var i = 0
        while i < count {
            let w = highPass.step(shelf.step(SIMD2(Double(samples[2 * i]), Double(samples[2 * i + 1]))))
            tenth += w.x * w.x + w.y * w.y
            inTenth += 1
            if inTenth == framesInTenth {
                tenths.append(tenth)
                tenth = 0
                inTenth = 0
            }
            i += 1
        }
        frames += count

        // The true peak: a stretch at a time, each looked at closely only if it could reach it.
        let taps = Self.taps
        Self.phases.withUnsafeBufferPointer { phases in
            recent.withUnsafeMutableBufferPointer { recent in
                var start = 0
                while start < count {
                    let end = min(count, start + Self.stretch)
                    // (The samples before the stretch that the points in it are worked out from.)
                    var largest = 0.0
                    var k = 0
                    while k < taps {
                        largest = max(largest, abs(recent[k]), abs(recent[2 * taps + k]))
                        k += 1
                    }
                    var j = start
                    while j < end {
                        largest = max(largest, abs(Double(samples[2 * j])), abs(Double(samples[2 * j + 1])))
                        j += 1
                    }
                    if largest * Self.headroom <= peak {
                        // Only the samples the next stretch takes from it are kept, where they would be.
                        let kept = min(end - start, taps)
                        at = (at + end - start - kept) % taps
                        j = end - kept
                        while j < end {
                            Self.push(Double(samples[2 * j]), Double(samples[2 * j + 1]), into: recent, at: &at)
                            j += 1
                        }
                    } else {
                        j = start
                        while j < end {
                            Self.push(Double(samples[2 * j]), Double(samples[2 * j + 1]), into: recent, at: &at)
                            peak = max(peak, Self.highest(recent, from: at, phases))
                            j += 1
                        }
                    }
                    start = end
                }
            }
        }
    }

    /// Keeps a frame among the last `taps`.
    @inline(__always) private static func push(_ l: Double, _ r: Double, into recent: UnsafeMutableBufferPointer<Double>, at: inout Int) {
        let taps = Self.taps
        recent[at] = l; recent[at + taps] = l
        recent[2 * taps + at] = r; recent[3 * taps + at] = r
        at = at == taps - 1 ? 0 : at + 1
    }

    /// The highest of the three points between the samples at the middle of the last `taps`, and of
    /// the sample before them, on either channel.
    @inline(__always) private static func highest(_ recent: UnsafeMutableBufferPointer<Double>, from at: Int,
                                                  _ phases: UnsafeBufferPointer<Double>) -> Double {
        var top = 0.0
        var channel = 0
        while channel < 2 {
            let base = channel * 2 * taps + at
            top = max(top, abs(recent[base + taps / 2 - 1]))
            var p = 0
            while p < 3 {
                var v = 0.0
                var t = 0
                while t < taps {
                    v += recent[base + t] * phases[p * taps + t]
                    t += 1
                }
                top = max(top, abs(v))
                p += 1
            }
            channel += 1
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
