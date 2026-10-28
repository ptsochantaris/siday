// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// Brings a recording from the rate it was made at to the player's (`outputSampleRate`), each output
/// sample made from the input samples around it through a windowed sinc: a low-pass filter that keeps
/// everything up to about 20 kHz of a CD's 44.1 kHz, and takes out what lies past half of the lower of
/// the two rates by some 90 dB, so that nothing comes back mirrored below it.
///
/// The two rates go in a ratio of whole numbers (44,100 to 48,000 is 147 to 160), and an output sample
/// lies at one of as many places between two input samples as the larger of the two numbers: each place
/// has its own row of the filter, worked out beforehand. Where there would be too many places, there
/// are `mostPlaces`, and an output sample's row is had from the two nearest it.
package struct Resampler {
    /// How many input samples there are on either side of an output sample's place, at the most, when
    /// the rate is brought up: the filter's length, and so how steep it is.
    static let reach = 64
    static let mostPlaces = 2048
    /// The Kaiser window's beta: about 90 dB taken out beyond the edge of the filter.
    private static let beta = 9.0
    /// How much of the lower rate's half is kept: for 44.1 kHz, the filter falls from 20 kHz to 22 kHz.
    private static let kept = 0.952

    /// Input samples to each `places` of the output: the step from one output sample to the next is
    /// `step / places` of an input sample.
    package let step: Int, places: Int
    /// Input samples on either side of an output sample's place: `reach`, more when the rate is brought
    /// down, so that the filter is as steep at the lower rate.
    package let taps: Int
    /// True if each output sample lies at its own row, with no need to have it from two.
    package let exact: Bool
    /// `rows` rows of `2 * taps` weights (one more row when they are had from two), for the input
    /// samples from `taps - 1` before an output sample's place to `taps` after it.
    package let rows: Int
    package let weights: [Float]

    package init(from inRate: Int, to outRate: Int) {
        var a = inRate, b = outRate
        while b != 0 { (a, b) = (b, a % b) }
        let common = max(1, a)
        step = inRate / common
        places = outRate / common
        let down = Double(inRate) / Double(outRate)
        guard inRate != outRate else {
            // A recording at the player's own rate is taken as it is: each output sample is the input
            // sample at its place. (Four taps either side, as the weighted sum takes eight at a time.)
            taps = 4
            exact = true
            rows = 1
            weights = [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]
            return
        }
        // (A multiple of four, as the weighted sum takes eight at a time.)
        taps = down > 1 ? min(Self.reach * 8, Int((Double(Self.reach) * down / 4).rounded(.up)) * 4) : Self.reach
        exact = places <= Self.mostPlaces
        rows = exact ? places : Self.mostPlaces
        // The filter's edge, as a part of the input's rate.
        let edge = 0.5 * Self.kept * min(1, 1 / down)
        let width = 2 * taps
        var weights = [Float](repeating: 0, count: (rows + 1) * width)
        let i0Beta = Self.besselI0(Self.beta)
        for row in 0 ... rows {
            let fraction = Double(row) / Double(rows)
            var sum = 0.0
            var row64 = [Double](repeating: 0, count: width)
            for k in 0 ..< width {
                // How far this input sample is from the output sample's place.
                let x = Double(k - taps + 1) - fraction
                let ratio = x / Double(taps)
                guard ratio > -1, ratio < 1 else { continue }
                let window = Self.besselI0(Self.beta * (1 - ratio * ratio).squareRoot()) / i0Beta
                let angle = 2 * Double.pi * edge * x
                let sinc = x == 0 ? 2 * edge : sin(angle) / (Double.pi * x)
                row64[k] = sinc * window
                sum += row64[k]
            }
            // Each row adds up to one, so that a steady level comes out as it went in.
            for k in 0 ..< width { weights[row * width + k] = Float(row64[k] / sum) }
        }
        self.weights = weights
    }

    /// The modified Bessel function of the first kind and order nought, which the Kaiser window is made of.
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let half = x / 2
        for k in 1 ..< 64 {
            term *= half / Double(k)
            let squared = term * term
            sum += squared
            if squared < sum * 1e-17 { break }
        }
        return sum
    }
}
