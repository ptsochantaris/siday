// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// This file is part of a Swift port of reSIDfp, a SID emulator engine.
// Copyright 2011-2023 Leandro Nini <drfiemost@users.sourceforge.net>
// Copyright 2007-2010 Antti Lankila
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// WaveformCalculator.h / WaveformCalculator.cpp. The tables are `matrix_t` (rows of 4096 shorts) in
// reSIDfp; here each is one block of Int16 with the rows back to back. The pulldown tables are single
// precision arithmetic, in reSIDfp's operand order.

/// The strength of the combined waveforms: reSIDfp's `CombinedWaveforms`. Each setting is a set of
/// parameters fitted to samplings of one real chip per model.
public enum ReSIDfpCombinedWaveforms: Sendable {
    case average, weak, strong
}

extension ReSIDfpChip {
    /// Combined waveform calculator for WaveformGenerator.
    /// By combining waveforms, the bits of each waveform are effectively short
    /// circuited, a zero bit in one waveform will result in a zero output bit,
    /// thus the claim that the waveforms are AND'ed.
    /// However, a zero bit in one waveform may also affect the neighboring bits
    /// in the output.
    ///
    /// Example:
    ///
    ///                 1 1
    ///     Bit #       1 0 9 8 7 6 5 4 3 2 1 0
    ///                 -----------------------
    ///     Sawtooth    0 0 0 1 1 1 1 1 1 0 0 0
    ///
    ///     Triangle    0 0 1 1 1 1 1 1 0 0 0 0
    ///
    ///     AND         0 0 0 1 1 1 1 1 0 0 0 0
    ///
    ///     Output      0 0 0 0 1 1 1 0 0 0 0 0
    ///
    ///
    /// Re-vectorized die photographs reveal the mechanism behind this behavior.
    /// Each waveform selector bit acts as a switch, which directly connects
    /// internal outputs into the waveform DAC inputs as follows:
    ///
    /// - Noise outputs the shift register bits to DAC inputs as described above.
    ///   Each output is also used as input to the next bit when the shift register
    ///   is shifted. Lower four bits are grounded.
    /// - Pulse connects a single line to all DAC inputs. The line is connected to
    ///   either 5V (pulse on) or 0V (pulse off) at bit 11, and ends at bit 0.
    /// - Triangle connects the upper 11 bits of the (MSB EOR'ed) accumulator to the
    ///   DAC inputs, so that DAC bit 0 = 0, DAC bit n = accumulator bit n - 1.
    /// - Sawtooth connects the upper 12 bits of the accumulator to the DAC inputs,
    ///   so that DAC bit n = accumulator bit n. Sawtooth blocks out the MSB from
    ///   the EOR used to generate the triangle waveform.
    ///
    /// We can thus draw the following conclusions:
    ///
    /// - The shift register may be written to by combined waveforms.
    /// - The pulse waveform interconnects all bits in combined waveforms via the
    ///   pulse line.
    /// - The combination of triangle and sawtooth interconnects neighboring bits
    ///   of the sawtooth waveform.
    ///
    /// Also in the 6581 the MSB of the oscillator, used as input for the
    /// triangle xor logic and the pulse adder's last bit, is connected directly
    /// to the waveform selector, while in the 8580 it is latched at sid_clk2
    /// before being forwarded to the selector. Thus in the 6581 if the sawtooth MSB
    /// is pulled down it might affect the oscillator's adder
    /// driving the top bit low.
    enum WaveformCalculator {
        /// A table that lives for the whole process.
        struct Table: @unchecked Sendable {
            let rows: UnsafePointer<Int16>
        }

        // Distance functions
        enum distance_t { case exponentialDistance, linearDistance, quadraticDistance }

        static func distFunc(_ f: distance_t, _ distance: Float, _ i: Int32) -> Float {
            switch f {
            case .exponentialDistance:
                // std::pow(float, int) is computed in double.
                Float(pow(Double(distance), Double(-i)))
            case .linearDistance:
                1.0 / (1.0 + Float(i) * distance)
            case .quadraticDistance:
                1.0 / (1.0 + Float(i &* i) * distance)
            }
        }

        /// Combined waveform model parameters.
        struct CombinedWaveformConfig {
            var distFunc: distance_t
            var threshold: Float
            var topbit: Float
            var pulsestrength: Float
            var distance1: Float
            var distance2: Float

            init(_ distFunc: distance_t, _ threshold: Float, _ topbit: Float, _ pulsestrength: Float, _ distance1: Float, _ distance2: Float) {
                self.distFunc = distFunc
                self.threshold = threshold
                self.topbit = topbit
                self.pulsestrength = pulsestrength
                self.distance1 = distance1
                self.distance2 = distance2
            }
        }

        typealias C = CombinedWaveformConfig

        /// Parameters derived with the Monte Carlo method based on
        /// samplings from real machines.
        /// Code and data available in the project repository [1].
        /// Sampling program made by Dag Lem [2].
        ///
        /// The score here reported is the acoustic error
        /// calculated XORing the estimated and the sampled values.
        /// In parentheses the number of mispredicted bits.
        ///
        /// [1] https://github.com/libsidplayfp/combined-waveforms
        /// [2] https://github.com/daglem/reDIP-SID/blob/master/research/combsample.d64
        static let configAverage: [[CombinedWaveformConfig]] = [
            [ /* 6581 R3 0486S sampled by Trurl */
                // TS  error  3555 (324/32768) [RMS: 73.98]
                C(.exponentialDistance, 0.877322257, 1.11349654, 0.0, 2.14537621, 9.08618164),
                // PT  error  4590 (124/32768) [RMS: 68.90]
                C(.linearDistance, 0.941692829, 1.0, 1.80072665, 0.033124879, 0.232303441),
                // PS  error 19352 (763/32768) [RMS: 96.91]
                C(.linearDistance, 1.66494179, 1.03760982, 5.62705326, 0.291590303, 0.283631504),
                // PTS error  5068 ( 94/32768) [RMS: 41.69]
                C(.linearDistance, 1.09762526, 0.975265801, 1.52196741, 0.151528224, 0.841949463),
                // NP  guessed
                C(.exponentialDistance, 0.96, 1.0, 2.5, 1.1, 1.2),
            ],
            [ /* 8580 R5 1088 sampled by reFX-Mike */
                // TS  error 10660 (353/32768) [RMS: 58.34]
                C(.exponentialDistance, 0.853578329, 1.09615636, 0.0, 1.8819375, 6.80794907),
                // PT  error 10635 (289/32768) [RMS: 108.81]
                C(.exponentialDistance, 0.929835618, 1.0, 1.12836814, 1.10453653, 1.48065746),
                // PS  error 12255 (554/32768) [RMS: 102.27]
                C(.quadraticDistance, 0.911938608, 0.996440411, 1.2278074, 0.000117214302, 0.18948476),
                // PTS error  6913 (127/32768) [RMS: 55.80]
                C(.exponentialDistance, 0.938004673, 1.04827631, 1.21178246, 0.915959001, 1.42698038),
                // NP  guessed
                C(.exponentialDistance, 0.95, 1.0, 1.15, 1.0, 1.45),
            ],
        ]

        static let configWeak: [[CombinedWaveformConfig]] = [
            [ /* 6581 R2 4383 sampled by ltx128 */
                // TS  error 1474 (198/32768) [RMS: 62.81]
                C(.exponentialDistance, 0.892563999, 1.11905622, 0.0, 2.21876144, 9.63837719),
                // PT  error  612 (102/32768) [RMS: 43.71]
                C(.linearDistance, 1.01262534, 1.0, 2.46070528, 0.0537485816, 0.0986242667),
                // PS  error 8135 (575/32768) [RMS: 75.10]
                C(.linearDistance, 2.14896345, 1.0216713, 10.5400085, 0.244498149, 0.126134038),
                // PTS error 2489 (60/32768) [RMS: 24.41]
                C(.linearDistance, 1.22330308, 0.933797896, 2.83245254, 0.0615176819, 0.323831677),
                // NP  guessed
                C(.exponentialDistance, 0.96, 1.0, 2.5, 1.1, 1.2),
            ],
            [ /* 8580 R5 4887 sampled by reFX-Mike */
                // TS  error  741 (76/32768) [RMS: 53.74]
                C(.exponentialDistance, 0.812351167, 1.1727736, 0.0, 1.87459648, 2.31578159),
                // PT  error 7199 (192/32768) [RMS: 88.43]
                C(.exponentialDistance, 0.917997837, 1.0, 1.01248944, 1.05761552, 1.37529826),
                // PS  error 9856 (332/32768) [RMS: 86.29]
                C(.quadraticDistance, 0.968754232, 1.00669801, 1.29909098, 0.00962483883, 0.146850556),
                // PTS error 4809 (60/32768) [RMS: 45.37]
                C(.exponentialDistance, 0.941834152, 1.06401193, 0.991132736, 0.995310068, 1.41105855),
                // NP  guessed
                C(.exponentialDistance, 0.95, 1.0, 1.15, 1.0, 1.45),
            ],
        ]

        static let configStrong: [[CombinedWaveformConfig]] = [
            [ /* 6581 R2 0384 sampled by Trurl */
                // TS  error 20337 (1579/32768) [RMS: 88.57]
                C(.exponentialDistance, 0.000637792516, 1.56725872, 0.0, 0.00036806846, 1.51800942),
                // PT  error  5190 (238/32768) [RMS: 83.54]
                C(.linearDistance, 0.924780309, 1.0, 1.96809769, 0.0888123438, 0.234606609),
                // PS  error 31015 (2181/32768) [RMS: 114.99]
                C(.linearDistance, 1.2328074, 0.73079139, 3.9719491, 0.00156516861, 0.314677745),
                // PTS error  9874 (201/32768) [RMS: 52.30]
                C(.linearDistance, 1.08558261, 0.857638359, 1.52781796, 0.152927235, 1.02657032),
                // NP  guessed
                C(.exponentialDistance, 0.96, 1.0, 2.5, 1.1, 1.2),
            ],
            [ /* 8580 R5 1489 sampled by reFX-Mike */
                // TS  error  4837 (388/32768) [RMS: 76.07]
                C(.exponentialDistance, 0.89762634, 56.7594185, 0.0, 7.68995237, 12.0754194),
                // PT  error  9266 (508/32768) [RMS: 127.83]
                C(.exponentialDistance, 0.87147671, 1.0, 1.44887495, 1.05899632, 1.43786001),
                // PS  error 13168 (718/32768) [RMS: 123.35]
                C(.quadraticDistance, 0.89255774, 1.2253896, 1.75615835, 0.0245045591, 0.12982437),
                // PTS error  6702 (300/32768) [RMS: 71.01]
                C(.linearDistance, 0.91124934, 0.963609755, 0.909965038, 1.07445884, 1.82399702),
                // NP  guessed
                C(.exponentialDistance, 0.95, 1.0, 1.15, 1.0, 1.45),
            ],
        ]

        /// Calculate triangle waveform
        static func triXor(_ val: UInt32) -> UInt32 {
            (((val & 0x800) == 0) ? val : (val ^ 0xFFF)) << 1
        }

        /// Generate bitstate based on emulation of combined waves pulldown.
        ///
        /// - Parameters:
        ///   - distancetable: the 25 distance weights
        ///   - accumulator: the high bits of the accumulator value
        static func calculatePulldown(_ distancetable: [Float], _ topbit: Float, _ pulsestrength: Float, _ threshold: Float, _ accumulator: UInt32) -> Int16 {
            var bit = [Float](repeating: 0, count: 12)

            for i in 0 ..< 12 {
                bit[i] = (accumulator & (1 << UInt32(i))) != 0 ? 1.0 : 0.0
            }

            bit[11] *= topbit

            var pulldown = [Float](repeating: 0, count: 12)

            for sb in 0 ..< 12 {
                var avg: Float = 0.0
                var n: Float = 0.0

                for cb in 0 ..< 12 {
                    if cb == sb {
                        continue
                    }

                    let weight = distancetable[sb - cb + 12]
                    avg += (1.0 - bit[cb]) * weight
                    n += weight
                }

                avg -= pulsestrength

                pulldown[sb] = avg / n
            }

            // Get the predicted value
            var value: UInt16 = 0

            for i in 0 ..< 12 {
                let bitValue: Float = bit[i] > 0.0 ? 1.0 - pulldown[i] : 0.0
                if bitValue > threshold {
                    value |= 1 << UInt16(i)
                }
            }

            return Int16(bitPattern: value)
        }

        /// WaveformCalculator::getWaveTable(): 4 rows of 4096.
        static let wftable: Table = {
            let wftable = UnsafeMutablePointer<Int16>.allocate(capacity: 4 * 4096)
            // Build waveform table.
            for idx in 0 ..< (1 << 12) {
                let saw = Int16(truncatingIfNeeded: idx)
                let tri = Int16(truncatingIfNeeded: triXor(UInt32(idx)))

                wftable[0 * 4096 + idx] = 0xFFF
                wftable[1 * 4096 + idx] = tri
                wftable[2 * 4096 + idx] = saw
                wftable[3 * 4096 + idx] = Int16(truncatingIfNeeded: Int32(saw) & (Int32(saw) << 1))
            }
            return Table(rows: UnsafePointer(wftable))
        }()

        // reSIDfp's PULLDOWN_CACHE, a map guarded by a mutex: one entry per model and strength, built on first use.
        private static let pulldown6581Average = makePulldownTable(configAverage[0])
        private static let pulldown6581Weak = makePulldownTable(configWeak[0])
        private static let pulldown6581Strong = makePulldownTable(configStrong[0])
        private static let pulldown8580Average = makePulldownTable(configAverage[1])
        private static let pulldown8580Weak = makePulldownTable(configWeak[1])
        private static let pulldown8580Strong = makePulldownTable(configStrong[1])

        /// Build pulldown table for use by WaveformGenerator: 5 rows of 4096.
        ///
        /// - Parameters:
        ///   - model: Chip model to use
        ///   - cws: strength of combined waveforms
        static func buildPulldownTable(_ model: SIDModel, _ cws: ReSIDfpCombinedWaveforms) -> UnsafePointer<Int16> {
            switch (model, cws) {
            case (.mos6581, .average): pulldown6581Average.rows
            case (.mos6581, .weak): pulldown6581Weak.rows
            case (.mos6581, .strong): pulldown6581Strong.rows
            case (.mos8580, .average): pulldown8580Average.rows
            case (.mos8580, .weak): pulldown8580Weak.rows
            case (.mos8580, .strong): pulldown8580Strong.rows
            }
        }

        private static func makePulldownTable(_ cfgArray: [CombinedWaveformConfig]) -> Table {
            let pdTable = UnsafeMutablePointer<Int16>.allocate(capacity: 5 * 4096)

            for wav in 0 ..< 5 {
                let cfg = cfgArray[wav]

                var distancetable = [Float](repeating: 0, count: 12 * 2 + 1)
                distancetable[12] = 1.0
                for i in stride(from: 12, to: 0, by: -1) {
                    distancetable[12 - i] = distFunc(cfg.distFunc, cfg.distance1, Int32(i))
                    distancetable[12 + i] = distFunc(cfg.distFunc, cfg.distance2, Int32(i))
                }

                for idx in 0 ..< (1 << 12) {
                    pdTable[wav * 4096 + idx] = calculatePulldown(distancetable, cfg.topbit, cfg.pulsestrength, cfg.threshold, UInt32(idx))
                }
            }

            return Table(rows: UnsafePointer(pdTable))
        }
    }
}
