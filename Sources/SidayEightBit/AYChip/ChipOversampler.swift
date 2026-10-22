// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ayumi, Copyright (c) Peter Sovietov, used under the MIT licence (see THIRD-PARTY.md).
//
// The way ayumi brings the AY chip's sound to the player's rate, for other chips that make square
// waves and steps as it does: what the chip makes at its own rate is drawn between its steps, eight
// times for each of the player's samples, and those eight are filtered down to one by ayumi's FIR.
// The AY chip has this within it (AYChip.swift), worked into its own steps for speed.

import SidayFoundation

/// Brings what a chip makes at a rate of its own, up to about eight times the player's, to the player's.
struct ChipOversampler: ~Copyable {
    private let fir: InlineArray<192, Double> // all 192 coefficients; the first is zero
    /// How many of the chip's steps there are in one of the eight.
    private let step: Double
    private var x = 0.0
    private var cl0 = 0.0, cl1 = 0.0, cl2 = 0.0, yl0 = 0.0, yl1 = 0.0, yl2 = 0.0, yl3 = 0.0
    private var cr0 = 0.0, cr1 = 0.0, cr2 = 0.0, yr0 = 0.0, yr1 = 0.0, yr2 = 0.0, yr3 = 0.0
    private var firLeft = InlineArray<384, Double>(repeating: 0)
    private var firRight = InlineArray<384, Double>(repeating: 0)
    private var firIndex = 0
    private var firBase = 0
    private var inner = 0
    /// False for a chip with one output: only its left is worked out, and the right is the same.
    private let stereo: Bool

    /// How many of the eight there are in a second: what a chip's writes can be timed to.
    static var innerRate: Double { Double(outputSampleRate * ayDecimate) }

    /// - Parameter chipRate: how many steps a second the chip takes.
    init(chipRate: Double, stereo: Bool) {
        fir = InlineArray { ayFIRHalf[$0 <= 96 ? $0 : ayFIRSize - $0] }
        step = chipRate / Self.innerRate
        self.stereo = stereo
    }

    /// Takes one of the eight. `next` is asked for what the chip makes at each of its steps that
    /// passes, left and right. Returns true when this completed one of the player's samples, which
    /// is then read with `finishSample()`.
    @inline(__always) mutating func innerStep(_ next: () -> (Double, Double)) -> Bool {
        if inner == 0 {
            firBase = ayFIRSize &- firIndex &* ayDecimate
            firIndex = firIndex == ayFIRSize / ayDecimate - 2 ? 0 : firIndex &+ 1
        }
        x += step
        while x >= 1 {
            x -= 1
            let (left, right) = next()
            yl0 = yl1; yl1 = yl2; yl2 = yl3; yl3 = left
            var y1 = yl2 - yl0
            cl0 = 0.5 * yl1 + 0.25 * (yl0 + yl2)
            cl1 = 0.5 * y1
            cl2 = 0.25 * (yl3 - yl1 - y1)
            if stereo {
                yr0 = yr1; yr1 = yr2; yr2 = yr3; yr3 = right
                y1 = yr2 - yr0
                cr0 = 0.5 * yr1 + 0.25 * (yr0 + yr2)
                cr1 = 0.5 * y1
                cr2 = 0.25 * (yr3 - yr1 - y1)
            }
        }
        let slot = firBase &+ (ayDecimate - 1 &- inner)
        firLeft[unchecked: slot] = (cl2 * x + cl1) * x + cl0
        if stereo { firRight[unchecked: slot] = (cr2 * x + cr1) * x + cr0 }
        inner &+= 1
        if inner == ayDecimate {
            inner = 0
            return true
        }
        return false
    }

    @inline(__always) private static func decimate(_ history: inout InlineArray<384, Double>, from base: Int, taps: RawSpan) -> Double {
        let width = MemoryLayout<SIMD8<Double>>.size
        let start = base &* MemoryLayout<Double>.size
        var even = SIMD8<Double>.zero, odd = SIMD8<Double>.zero
        do {
            let input = history.span.bytes
            var offset = 0
            while offset < ayFIRSize * MemoryLayout<Double>.size {
                even += taps.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD8<Double>.self)
                    * input.unsafeLoadUnaligned(fromUncheckedByteOffset: start &+ offset, as: SIMD8<Double>.self)
                odd += taps.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ width, as: SIMD8<Double>.self)
                    * input.unsafeLoadUnaligned(fromUncheckedByteOffset: start &+ offset &+ width, as: SIMD8<Double>.self)
                offset &+= width &* 2
            }
        }
        for i in 0 ..< ayDecimate {
            history[unchecked: base &+ ayFIRSize &- ayDecimate &+ i] = history[unchecked: base &+ i]
        }
        return (even + odd).sum()
    }

    /// The player's sample completed by the last `innerStep`, left and right.
    @inline(__always) mutating func finishSample() -> (Double, Double) {
        let left = Self.decimate(&firLeft, from: firBase, taps: fir.span.bytes)
        guard stereo else { return (left, left) }
        return (left, Self.decimate(&firRight, from: firBase, taps: fir.span.bytes))
    }
}
