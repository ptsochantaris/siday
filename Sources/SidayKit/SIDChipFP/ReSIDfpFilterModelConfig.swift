// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// This file is part of a Swift port of reSIDfp, a SID emulator engine.
// Copyright 2011-2025 Leandro Nini <drfiemost@users.sourceforge.net>
// Copyright 2007-2010 Antti Lankila
// Copyright 2004,2010 Dag Lem <resid@nimrod.no>
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
// The tables every chip of one model shares: FilterModelConfig.h/.cpp, FilterModelConfig6581.h/.cpp,
// FilterModelConfig8580.h/.cpp, and the classes they are built with: Spline.h/.cpp, OpAmp.h/.cpp
// and Dac.h/.cpp.
//
// Everything here is double arithmetic done once, when the first chip of a model is created. The
// expressions keep reSIDfp's operand order; Swift never fuses a*b+c into an FMA, which corresponds
// to compiling the C++ with -ffp-contract=off.
//
// Differences from the C++, none of which changes a value:
// - reSIDfp builds the summer, mixer, volume and resonance tables on four threads which all draw
//   their dither from one unsynchronised counter (FilterModelConfig::Randomnoise::index), so the
//   C++ tables differ from run to run by one unit in some entries. Here each table is given the
//   stretch of the dither sequence it gets when the four are built one after the other in the
//   order reSIDfp starts its threads. That is one of the outcomes the C++ can produce, and it is
//   what the reference build (SIDFP_SEQUENTIAL_TABLES) does. The four are still built concurrently.
// - The dither counter, uCox and the current factor are members of the shared FilterModelConfig
//   in reSIDfp, so one chip changes them under every other chip of its model. Here they belong to
//   the chip (ReSIDfpChip.Filter): each chip behaves as the first chip of a fresh process does.
// - mixer, summer, resonance and opamp_rev have margins in place of reSIDfp's range asserts (see
//   the comments at the table declarations).

import Foundation

// MARK: C++ conversion semantics

// Swift traps when a floating-point value does not fit the integer type; C++ leaves it undefined.
// These do what the arm64 conversion instruction does (saturate, NaN gives 0), so the two agree
// even at the edges.

@inline(__always) func residfp_int(_ d: Double) -> Int32 {
    if _fastPath(d > -2_147_483_648.0 && d < 2_147_483_647.0) { return Int32(d) }
    if d >= 2_147_483_647.0 { return Int32.max }
    if d <= -2_147_483_648.0 { return Int32.min }
    return 0
}

extension ReSIDfpChip {
    // MARK: - Spline.h / Spline.cpp

    /// Fritsch-Carlson monotone cubic spline interpolation.
    ///
    /// Based on the implementation from the [Monotone cubic interpolation] wikipedia page.
    ///
    /// [Monotone cubic interpolation]: https://en.wikipedia.org/wiki/Monotone_cubic_interpolation
    struct Spline {
        struct Point {
            var x: Double
            var y: Double
        }

        struct Param {
            var x1 = 0.0
            var x2 = 0.0
            var a = 0.0
            var b = 0.0
            var c = 0.0
            var d = 0.0
        }

        /// Interpolation parameters
        let params: UnsafeMutablePointer<Param>
        let paramCount: Int

        /// Last used parameters, cached for speed up
        var c: UnsafeMutablePointer<Param>

        init(_ input: [Point]) {
            paramCount = input.count
            params = .allocate(capacity: input.count)
            params.initialize(repeating: Param(), count: input.count)
            c = params

            precondition(input.count > 2)

            let coeffLength = input.count - 1

            var dxs = [Double](repeating: 0, count: coeffLength)
            var ms = [Double](repeating: 0, count: coeffLength)

            // Get consecutive differences and slopes
            for i in 0 ..< coeffLength {
                precondition(input[i].x < input[i + 1].x)

                let dx = input[i + 1].x - input[i].x
                let dy = input[i + 1].y - input[i].y
                dxs[i] = dx
                ms[i] = dy / dx
            }

            // Get degree-1 coefficients
            params[0].c = ms[0]
            for i in 1 ..< coeffLength {
                let m = ms[i - 1]
                let mNext = ms[i]
                if m * mNext <= 0 {
                    params[i].c = 0.0
                } else {
                    let dx = dxs[i - 1]
                    let dxNext = dxs[i]
                    let common = dx + dxNext
                    params[i].c = 3.0 * common / ((common + dxNext) / m + (common + dx) / mNext)
                }
            }
            params[coeffLength].c = ms[coeffLength - 1]

            // Get degree-2 and degree-3 coefficients
            for i in 0 ..< coeffLength {
                params[i].x1 = input[i].x
                params[i].x2 = input[i + 1].x
                params[i].d = input[i].y

                let c1 = params[i].c
                let m = ms[i]
                let invDx = 1.0 / dxs[i]
                let common = c1 + params[i + 1].c - m - m
                params[i].b = (m - c1 - common) * invDx
                params[i].a = common * invDx * invDx
            }

            // Fix the upper range, because we interpolate outside original bounds if necessary.
            params[coeffLength - 1].x2 = Double.greatestFiniteMagnitude
        }

        func deallocate() {
            params.deallocate()
        }

        /// Evaluate y and its derivative at given point x.
        @inline(__always)
        mutating func evaluate(_ x: Double) -> Point {
            if x < c.pointee.x1 || x > c.pointee.x2 {
                for i in 0 ..< paramCount where x <= params[i].x2 {
                    c = params + i
                    break
                }
            }

            let p = c.pointee

            // Interpolate
            let diff = x - p.x1

            // y = a*x^3 + b*x^2 + c*x + d
            let y = ((p.a * diff + p.b) * diff + p.c) * diff + p.d

            // dy = 3*a*x^2 + 2*b*x + c
            let dy = (3.0 * p.a * diff + 2.0 * p.b) * diff + p.c

            return Point(x: y, y: dy)
        }
    }

    // MARK: - OpAmp.h / OpAmp.cpp

    /// Find output voltage in inverting gain and inverting summer SID op-amp
    /// circuits, using a combination of Newton-Raphson and bisection.
    ///
    ///               +---R2--+
    ///               |       |
    ///     vi ---R1--o--[A>--o-- vo
    ///               vx
    ///
    /// From Kirchoff's current law it follows that
    ///
    ///     IR1f + IR2r = 0
    ///
    /// Substituting the triode mode transistor model K*W/L*(Vgst^2 - Vgdt^2)
    /// for the currents, we get:
    ///
    ///     n*((Vddt - vx)^2 - (Vddt - vi)^2) + (Vddt - vx)^2 - (Vddt - vo)^2 = 0
    ///
    /// where n is the ratio between R1 and R2.
    ///
    /// Our root function f can thus be written as:
    ///
    ///     f = (n + 1)*(Vddt - vx)^2 - n*(Vddt - vi)^2 - (Vddt - vo)^2 = 0
    ///
    /// Using substitution constants
    ///
    ///     a = n + 1
    ///     b = Vddt
    ///     c = n*(Vddt - vi)^2
    ///
    /// the equations for the root function and its derivative can be written as:
    ///
    ///     f = a*(b - vx)^2 - c - (b - vo)^2
    ///     df = 2*((b - vo)*dvo - a*(b - vx))
    struct OpAmp {
        static var EPSILON: Double { 1e-8 }

        /// Current root position (cached as guess to speed up next iteration)
        var x = 0.0

        let Vddt: Double
        let vmin: Double
        let vmax: Double

        var opamp: Spline

        /// Opamp input -> output voltage conversion
        ///
        /// - Parameters:
        ///   - opamp_voltages: opamp mapping table as pairs of points (in -> out)
        ///   - Vddt: transistor dt parameter (in volts)
        init(_ opamp_voltages: [Spline.Point], _ Vddt: Double, _ vmin: Double, _ vmax: Double) {
            self.Vddt = Vddt
            self.vmin = vmin
            self.vmax = vmax
            opamp = Spline(opamp_voltages)
        }

        func deallocate() {
            opamp.deallocate()
        }

        /// Reset root position
        mutating func reset() {
            x = vmin
        }

        /// Solve the opamp equation for input vi in loading context n
        ///
        /// - Parameters:
        ///   - n: the ratio of input/output loading
        ///   - vi: input voltage
        /// - Returns: vo output voltage
        mutating func solve(_ n: Double, _ vi: Double) -> Double {
            // Start off with an estimate of x and a root bracket [ak, bk].
            // f is decreasing, so that f(ak) > 0 and f(bk) < 0.
            var ak = vmin
            var bk = vmax

            let a = n + 1.0
            let b = Vddt
            let b_vi = b > vi ? b - vi : 0.0
            let c = n * (b_vi * b_vi)

            while true {
                let xk = x

                // Calculate f and df.

                var out = opamp.evaluate(x)
                let vo = out.x
                let dvo = out.y

                let b_vx = b > x ? b - x : 0.0
                let b_vo = b > vo ? b - vo : 0.0
                // f = a*(b - vx)^2 - c - (b - vo)^2
                let f = a * (b_vx * b_vx) - c - (b_vo * b_vo)

                // df = 2*((b - vo)*dvo - a*(b - vx))
                let df = 2.0 * (b_vo * dvo - a * b_vx)

                // Newton-Raphson step: xk1 = xk - f(xk)/f'(xk)
                x -= f / df

                if _slowPath(abs(x - xk) < OpAmp.EPSILON) {
                    out = opamp.evaluate(x)
                    return out.x
                }

                // Narrow down root bracket.
                if f < 0.0 { bk = xk } else { ak = xk }

                if _slowPath(x <= ak) || _slowPath(x >= bk) {
                    // Bisection step (ala Dekker's method).
                    x = (ak + bk) * 0.5
                }
            }
        }
    }

    // MARK: - Dac.h / Dac.cpp

    /// Estimate DAC nonlinearity.
    /// The SID DACs are built up as R-2R ladder as follows:
    ///
    ///         n  n-1      2   1   0    VGND
    ///         |   |       |   |   |      |   Termination
    ///        2R  2R      2R  2R  2R     2R   only for
    ///         |   |       |   |   |      |   MOS 8580
    ///     Vo -o-R-o-R-...-o-R-o-R--    --+
    ///
    ///
    /// All MOS 6581 DACs are missing a termination resistor at bit 0. This causes
    /// pronounced errors for the lower 4 - 5 bits (e.g. the output for bit 0 is
    /// actually equal to the output for bit 1), resulting in DAC discontinuities
    /// for the lower bits.
    /// In addition to this, the 6581 DACs exhibit further severe discontinuities
    /// for higher bits, which may be explained by a less than perfect match between
    /// the R and 2R resistors, or by output impedance in the NMOS transistors
    /// providing the bit voltages. A good approximation of the actual DAC output is
    /// achieved for 2R/R ~ 2.20.
    ///
    /// The MOS 8580 DACs, on the other hand, do not exhibit any discontinuities.
    /// These DACs include the correct termination resistor, and also seem to have
    /// very accurately matched R and 2R resistors (2R/R = 2.00).
    ///
    /// On the 6581 the output of the waveform and envelope DACs go through
    /// a voltage follower built with two NMOS:
    ///
    ///             Vdd
    ///
    ///              |
    ///            |-+
    /// Vin -------|    T1 (enhancement-mode)
    ///            |-+
    ///              |
    ///              o-------- Vout
    ///              |
    ///            |-+
    ///        +---|    T2 (depletion-mode)
    ///        |   |-+
    ///        |     |
    ///
    ///       GND   GND
    struct Dac {
        static var MOSFET_LEAKAGE_6581: Double { 0.0075 }
        static var MOSFET_LEAKAGE_8580: Double { 0.0035 }

        /// DAC leakage
        ///
        /// "Even in standard transistors a small amount of current leaks even when they are technically switched off."
        ///
        /// https://en.wikipedia.org/wiki/Subthreshold_conduction
        var leakage = 0.0

        /// analog values
        var dac: [Double]

        /// the dac array length
        let dacLength: Int

        /// Initialize DAC model.
        ///
        /// - Parameter bits: the number of input bits
        init(_ bits: Int) {
            dac = [Double](repeating: 0, count: bits)
            dacLength = bits
        }

        /// Get the Vo output for a given combination of input bits.
        ///
        /// - Parameter input: the digital input
        /// - Returns: the analog output value
        func getOutput(_ input: UInt32, _ saturate: Bool = false) -> Double {
            var dacValue = 0.0
            for i in 0 ..< dacLength {
                let transistor_on = (input & (1 << UInt32(i))) != 0
                dacValue += transistor_on ? dac[i] : dac[i] * leakage
            }

            // Rough attempt at modeling the MDAC saturation for the 6581.
            // Things are actually more complex, the saturation is likely
            // caused by the two NMOS source followers, one at the output
            // of the waveform DAC and the second at the output of the MDAC.
            // The buffers are also supposed to introduce a DC offset.
            // As a first step we use a cubic model for saturation and
            // apply it only at the waveform output, providing a decent
            // result without any runtime overhead.
            if saturate {
                let GAIN = 1.1
                let SAT = 1.1
                dacValue = GAIN * dacValue + (1.0 - GAIN) * SAT * dacValue * dacValue * dacValue
            }
            return dacValue
        }

        /// Build DAC model for specific chip.
        ///
        /// - Parameter chipModel: 6581 or 8580
        mutating func kinkedDac(_ chipModel: SIDModel) {
            let R_INFINITY = 1e6

            // Non-linearity parameter, 8580 DACs are perfectly linear
            let _2R_div_R = chipModel == .mos6581 ? 2.20 : 2.00

            // 6581 DACs are not terminated by a 2R resistor
            let term = chipModel == .mos8580

            leakage = chipModel == .mos6581 ? Dac.MOSFET_LEAKAGE_6581 : Dac.MOSFET_LEAKAGE_8580

            var Vsum = 0.0

            // Calculate voltage contribution by each individual bit in the R-2R ladder.
            for set_bit in 0 ..< dacLength {
                var Vn = 1.0 // Normalized bit voltage.
                let R = 1.0 // Normalized R
                let _2R = _2R_div_R * R // 2R
                var Rn = term ? // Rn = 2R for correct termination,
                    _2R : R_INFINITY // INFINITY for missing termination.

                var bit = 0

                // Calculate DAC "tail" resistance by repeated parallel substitution.
                while bit < set_bit {
                    Rn = (Rn == R_INFINITY) ?
                        R + _2R :
                        R + (_2R * Rn) / (_2R + Rn) // R + 2R || Rn
                    bit += 1
                }

                // Source transformation for bit voltage.
                if Rn == R_INFINITY {
                    Rn = _2R
                } else {
                    Rn = (_2R * Rn) / (_2R + Rn) // 2R || Rn
                    Vn = Vn * Rn / _2R
                }

                // Calculate DAC output voltage by repeated source transformation from
                // the "tail".
                bit += 1
                while bit < dacLength {
                    Rn += R
                    let I = Vn / Rn
                    Rn = (_2R * Rn) / (_2R + Rn) // 2R || Rn
                    Vn = Rn * I
                    bit += 1
                }

                dac[set_bit] = Vn
                Vsum += Vn
            }

            // Normalize to integerish behavior
            for i in 0 ..< dacLength {
                dac[i] /= Vsum
            }
        }
    }

    // MARK: - FilterModelConfig.h / FilterModelConfig.cpp

    class FilterModelConfig: @unchecked Sendable {
        // The highpass summer has 2 - 6 inputs (bandpass, lowpass, and 0 - 4 voices).
        static func summer_offset(_ i: Int) -> Int {
            i == 0 ? 0 : summer_offset(i - 1) + ((2 + i - 1) << 16)
        }

        // The mixer has 0 - 7 inputs (0 - 4 voices and 0 - 3 filter outputs).
        static func mixer_offset(_ i: Int) -> Int {
            i == 0 ? 0 : i == 1 ? 1 : mixer_offset(i - 1) + ((i - 1) << 16)
        }

        @inline(__always)
        static func to_ushort_dither(_ x: Double, _ d_noise: Double) -> UInt16 {
            let tmp = residfp_int(x + d_noise)
            // assert((tmp >= 0) && (tmp <= USHRT_MAX));
            return UInt16(truncatingIfNeeded: tmp)
        }

        @inline(__always)
        static func to_ushort(_ x: Double) -> UInt16 {
            to_ushort_dither(x, 0.5)
        }

        /// Hack to add quick dither when converting values from float to int
        /// and avoid quantization noise.
        /// Hopefully this can be removed the day we move all the analog part
        /// processing to floats.
        ///
        /// Not sure about the effect of using such small buffer of numbers
        /// since the random sequence repeats every 1024 values but for
        /// now it seems to do the job.
        ///
        /// The values are those of libc++: `std::uniform_real_distribution<double> unif(0., 1.)` drawing
        /// from a default-constructed `std::default_random_engine`, which is `std::minstd_rand`
        /// (x = 48271 * x mod 2147483647, seed 1). `std::generate_canonical<double, 53>` takes two
        /// draws per value: `((g1 - 1) + (g2 - 1) * 2147483646.0) / (2147483646.0 * 2147483646.0)`.
        /// (Other C++ standard libraries have other default engines, so reSIDfp's dither is not the
        /// same on every platform; these are the numbers of the macOS build the port was checked against.)
        enum Randomnoise {
            nonisolated(unsafe) static let buffer: UnsafePointer<Double> = {
                let buffer = UnsafeMutablePointer<Double>.allocate(capacity: 1024)
                var state: UInt64 = 1
                func next() -> Double {
                    state = (48271 &* state) % 2_147_483_647
                    return Double(UInt32(truncatingIfNeeded: state) &- 1)
                }
                let rp = 2_147_483_646.0
                for i in 0 ..< 1024 {
                    var base = rp
                    var sp = next()
                    sp += next() * base
                    base *= rp
                    // uniform_real_distribution: (b - a) * canonical + a
                    buffer[i] = (1.0 - 0.0) * (sp / base) + 0.0
                }
                return UnsafePointer(buffer)
            }()
        }

        /// Capacitor value.
        let C: Double

        /// Transistor parameters.
        /// Thermal voltage: Ut = kT/q = 8.61734315e-5*T ~ 26mV
        static var Ut: Double { 26.0e-3 }

        let Vdd: Double ///< Positive supply voltage
        let Vth: Double ///< Threshold voltage
        let Vddt: Double ///< Vdd - Vth
        /// Transconductance coefficient: u*Cox, as the constructor is given it. (reSIDfp's `uCox`
        /// member, which setFilterRange() changes, is in ReSIDfpChip.Filter.)
        let uCox: Double

        // Derived stuff
        let vmin, vmax: Double
        let denorm, norm: Double

        /// Fixed point scaling for 16 bit op-amp output.
        let N16: Double

        let voice_voltage_range: Double

        /// Lookup tables for gain and summer op-amps in output stage / filter.
        ///
        /// mixer, summer, resonance and opamp_rev are indexed with values that come out of the filter's
        /// arithmetic. reSIDfp asserts some of them in range and leaves the rest unchecked; here each of
        /// the four has a margin on both sides wide enough for anything the arithmetic can produce,
        /// filled with the nearest table entry, so the per-cycle code needs no range checks. The
        /// pointers address element 0 of the table proper, and an index that stays inside the table
        /// reads exactly what the C++ reads (including the neighbouring sub-table when it leaves its own).
        ///
        /// - resonance[res << 16 + Vbp], Vbp = vx - (vc >> 14) an integrator output: -131071 ... 196607.
        /// - summer[offset + resonance + Vlp + Vsum], Vsum up to four voices of 16 bits: -131071 ... 524282.
        /// - mixer[offset + Vmix], Vmix up to four voices plus the filter output; the 6581's
        ///   `(Vfilt * filterGain + offset) >> 12` is -524288 ... 524287, the 8580's Vfilt -393213 ... 589821.
        /// - opamp_rev[(vc >> 15) + 32768] with vc any 32-bit value: -32768 ... 98303.
        let mixer: UnsafeMutablePointer<UInt16> // mixer_offset<8>::value
        let summer: UnsafeMutablePointer<UInt16> // summer_offset<5>::value
        let volume: UnsafeMutablePointer<UInt16> // 16 * (1 << 16)
        let resonance: UnsafeMutablePointer<UInt16> // 16 * (1 << 16)

        /// Reverse op-amp transfer function.
        let opamp_rev: UnsafeMutablePointer<UInt16> // 1 << 16

        static var mixer_margin_low: Int { 8 << 16 }
        static var mixer_margin_high: Int { 6 << 16 }
        static var summer_margin: Int { 2 << 16 }
        static var resonance_margin: Int { 2 << 16 }
        static var opamp_rev_margin: Int { 1 << 15 }

        /// The value of Randomnoise's index once the constructor has run: the number of dithered
        /// values in the four tables, modulo 1024. A new chip starts from here.
        let rnd_index: Int32

        /// Bytes held by this object's tables.
        private(set) var tableBytes = 0

        /// Allocates `count` elements with margins and returns the address of element 0.
        private static func allocate(_ count: Int, _ low: Int, _ high: Int) -> UnsafeMutablePointer<UInt16> {
            let base = UnsafeMutablePointer<UInt16>.allocate(capacity: low + count + high)
            base.initialize(repeating: 0, count: low + count + high)
            return base + low
        }

        /// Fills the margins with the first and last table entries.
        private static func fillMargins(_ table: UnsafeMutablePointer<UInt16>, _ count: Int, _ low: Int, _ high: Int) {
            for i in 0 ..< low { table[-1 - i] = table[0] }
            for i in 0 ..< high { table[count + i] = table[count - 1] }
        }

        /// - Parameters:
        ///   - vvr: voice voltage range
        ///   - c: capacitor value
        ///   - vdd: Vdd supply voltage
        ///   - vth: threshold voltage
        ///   - ucox: u*Cox
        ///   - opamp_voltage: opamp voltage array
        ///   - mixer_nRatio: buildMixerTable()'s argument
        ///   - volume_nDivisor: buildVolumeTable()'s argument
        ///   - resonance_n: buildResonanceTable()'s argument
        init(_ vvr: Double, _ c: Double, _ vdd: Double, _ vth: Double, _ ucox: Double, _ opamp_voltage: [Spline.Point],
             mixer_nRatio: Double, volume_nDivisor: Double, resonance_n: [Double])
        {
            C = c
            Vdd = vdd
            Vth = vth
            Vddt = Vdd - Vth
            vmin = opamp_voltage[0].x
            vmax = max(Vddt, opamp_voltage[0].y)
            denorm = vmax - vmin
            norm = 1.0 / denorm
            N16 = norm * Double(UInt16.max)
            voice_voltage_range = vvr
            uCox = ucox

            let mixer_size = FilterModelConfig.mixer_offset(8)
            let summer_size = FilterModelConfig.summer_offset(5)
            let gain_size = 16 * (1 << 16)
            mixer = FilterModelConfig.allocate(mixer_size, FilterModelConfig.mixer_margin_low, FilterModelConfig.mixer_margin_high)
            summer = FilterModelConfig.allocate(summer_size, FilterModelConfig.summer_margin, FilterModelConfig.summer_margin)
            volume = FilterModelConfig.allocate(gain_size, 0, 0)
            resonance = FilterModelConfig.allocate(gain_size, FilterModelConfig.resonance_margin, FilterModelConfig.resonance_margin)
            opamp_rev = FilterModelConfig.allocate(1 << 16, FilterModelConfig.opamp_rev_margin, FilterModelConfig.opamp_rev_margin)
            tableBytes = 2 * (mixer_size + FilterModelConfig.mixer_margin_low + FilterModelConfig.mixer_margin_high
                + summer_size + 2 * FilterModelConfig.summer_margin + gain_size
                + gain_size + 2 * FilterModelConfig.resonance_margin + (1 << 16) + 2 * FilterModelConfig.opamp_rev_margin)

            // Convert op-amp voltage transfer to 16 bit values.

            var scaled_voltage = [Spline.Point](repeating: Spline.Point(x: 0, y: 0), count: opamp_voltage.count)

            for i in 0 ..< opamp_voltage.count {
                scaled_voltage[i].x = N16 * (opamp_voltage[i].x - opamp_voltage[i].y) / 2.0
                // We add 32768 to get a positive number in the range [0-65535]
                scaled_voltage[i].x += Double(1 << 15)

                scaled_voltage[i].y = N16 * (opamp_voltage[i].x - vmin)
            }

            // Create lookup table mapping capacitor voltage to op-amp input voltage:

            var s = Spline(scaled_voltage)

            for x in 0 ..< (1 << 16) {
                let out = s.evaluate(Double(x))
                // When interpolating outside range the first elements may be negative
                opamp_rev[x] = out.x > 0.0 ? FilterModelConfig.to_ushort(out.x) : 0
            }
            s.deallocate()
            FilterModelConfig.fillMargins(opamp_rev, 1 << 16, FilterModelConfig.opamp_rev_margin, FilterModelConfig.opamp_rev_margin)

            // Create lookup tables for gains / summers.
            //
            // reSIDfp's derived-class constructors spawn threads to calculate these tables in parallel.
            // Each table gets its own op-amp model, as there; the dither each one uses is that of its
            // position in the sequence summer, mixer, volume, resonance (see the head of this file).
            let summer_first = 0
            let mixer_first = summer_first + summer_size
            let volume_first = mixer_first + mixer_size
            let resonance_first = volume_first + gain_size
            rnd_index = Int32(truncatingIfNeeded: (resonance_first + gain_size) & 0x3FF)

            let build = TableBuild(config: self, opamp_voltage: opamp_voltage, mixer_nRatio: mixer_nRatio,
                                   volume_nDivisor: volume_nDivisor, resonance_n: resonance_n,
                                   first: [summer_first, mixer_first, volume_first, resonance_first])
            DispatchQueue.concurrentPerform(iterations: 4) { table in
                build.run(table)
            }

            FilterModelConfig.fillMargins(mixer, mixer_size, FilterModelConfig.mixer_margin_low, FilterModelConfig.mixer_margin_high)
            FilterModelConfig.fillMargins(summer, summer_size, FilterModelConfig.summer_margin, FilterModelConfig.summer_margin)
            FilterModelConfig.fillMargins(resonance, gain_size, FilterModelConfig.resonance_margin, FilterModelConfig.resonance_margin)
        }

        /// The four table-building lambdas of FilterModelConfig6581 / FilterModelConfig8580's constructors.
        private struct TableBuild: @unchecked Sendable {
            unowned(unsafe) let config: FilterModelConfig
            let opamp_voltage: [Spline.Point]
            let mixer_nRatio: Double
            let volume_nDivisor: Double
            let resonance_n: [Double]
            /// The number of dithered values made before each table's first.
            let first: [Int]

            func run(_ table: Int) {
                var opampModel = OpAmp(opamp_voltage, config.Vddt, config.vmin, config.vmax)
                var rnd = Int32(truncatingIfNeeded: first[table] & 0x3FF)
                switch table {
                case 0: config.buildSummerTable(&opampModel, &rnd)
                case 1: config.buildMixerTable(&opampModel, mixer_nRatio, &rnd)
                case 2: config.buildVolumeTable(&opampModel, volume_nDivisor, &rnd)
                default: config.buildResonanceTable(&opampModel, resonance_n, &rnd)
                }
                opampModel.deallocate()
            }
        }

        /// Randomnoise::getNoise() with the index held by the caller.
        @inline(__always)
        static func getNoise(_ index: inout Int32) -> Double {
            index = (index &+ 1) & 0x3FF
            return Randomnoise.buffer[Int(index)]
        }

        /// Randomnoise::getNoise() with the index and the buffer held by the caller.
        @inline(__always)
        static func getNoise(_ index: inout Int32, _ buffer: UnsafePointer<Double>) -> Double {
            index = (index &+ 1) & 0x3FF
            return buffer[Int(index)]
        }

        @inline(__always)
        final func getNormalizedValue(_ value: Double, _ rnd: inout Int32) -> UInt16 {
            FilterModelConfig.to_ushort_dither(N16 * (value - vmin), FilterModelConfig.getNoise(&rnd))
        }

        final func getNVmin() -> UInt16 {
            FilterModelConfig.to_ushort(N16 * vmin)
        }

        /// The filter summer operates at n ~ 1, and has 5 fundamentally different
        /// input configurations (2 - 6 input "resistors").
        ///
        /// Note that all "on" transistors are modeled as one. This is not
        /// entirely accurate, since the input for each transistor is different,
        /// and transistors are not linear components. However modeling all
        /// transistors separately would be extremely costly.
        private final func buildSummerTable(_ opampModel: inout OpAmp, _ rnd: inout Int32) {
            let r_N16 = 1.0 / N16

            var idx = 0
            for i in 0 ..< 5 {
                let idiv = 2 + i // 2 - 6 input "resistors".
                let size = idiv << 16
                let n = Double(idiv)
                let r_idiv = 1.0 / Double(idiv)
                opampModel.reset()

                for vi in 0 ..< size {
                    let vin = vmin + Double(vi) * r_N16 * r_idiv /* vmin .. vmax */
                    summer[idx] = getNormalizedValue(opampModel.solve(n, vin), &rnd)
                    idx += 1
                }
            }
        }

        /// The audio mixer operates at n ~ 8/6 (6581) or 8/5 (8580),
        /// and has 8 fundamentally different input configurations
        /// (0 - 7 input "resistors").
        ///
        /// All "on", transistors are modeled as one - see comments above for
        /// the filter summer.
        private final func buildMixerTable(_ opampModel: inout OpAmp, _ nRatio: Double, _ rnd: inout Int32) {
            let r_N16 = 1.0 / N16

            var idx = 0
            for i in 0 ..< 8 {
                let idiv = (i == 0) ? 1 : i
                let size = (i == 0) ? 1 : i << 16
                let n = Double(i) * nRatio
                let r_idiv = 1.0 / Double(idiv)
                opampModel.reset()

                for vi in 0 ..< size {
                    let vin = vmin + Double(vi) * r_N16 * r_idiv /* vmin .. vmax */
                    mixer[idx] = getNormalizedValue(opampModel.solve(n, vin), &rnd)
                    idx += 1
                }
            }
        }

        /// 4 bit "resistor" ladders in the audio output gain
        /// necessitate 16 gain tables.
        /// From die photographs of the volume "resistor" ladders
        /// it follows that gain ~ vol/12 (6581) or vol/16 (8580)
        /// (assuming ideal op-amps and ideal "resistors").
        private final func buildVolumeTable(_ opampModel: inout OpAmp, _ nDivisor: Double, _ rnd: inout Int32) {
            let r_N16 = 1.0 / N16

            var idx = 0
            for n8 in 0 ..< 16 {
                let size = 1 << 16
                let n = Double(n8) / nDivisor
                opampModel.reset()

                for vi in 0 ..< size {
                    let vin = vmin + Double(vi) * r_N16 /* vmin .. vmax */
                    volume[idx] = getNormalizedValue(opampModel.solve(n, vin), &rnd)
                    idx += 1
                }
            }
        }

        /// 4 bit "resistor" ladders in the bandpass resonance gain
        /// necessitate 16 gain tables.
        /// From die photographs of the bandpass "resistor" ladders
        /// it follows that 1/Q ~ ~res/8 (6581) or 2^((4 - res)/8) (8580)
        /// (assuming ideal op-amps and ideal "resistors").
        private final func buildResonanceTable(_ opampModel: inout OpAmp, _ resonance_n: [Double], _ rnd: inout Int32) {
            let r_N16 = 1.0 / N16

            var idx = 0
            for n8 in 0 ..< 16 {
                let size = 1 << 16
                opampModel.reset()

                for vi in 0 ..< size {
                    let vin = vmin + Double(vi) * r_N16 /* vmin .. vmax */
                    resonance[idx] = getNormalizedValue(opampModel.solve(resonance_n[n8], vin), &rnd)
                    idx += 1
                }
            }
        }

        /// FilterModelConfig::setUCox()'s currFactorCoeff: the current factor coefficient for op-amp integrators.
        final func currFactorCoeff(_ uCox: Double) -> Double {
            denorm * (uCox / 2.0 * 1.0e-6 / C)
        }
    }

    // MARK: - FilterModelConfig6581.h / FilterModelConfig6581.cpp

    /// Calculate parameters for 6581 filter emulation.
    final class FilterModelConfig6581: FilterModelConfig, @unchecked Sendable {
        /// FilterModelConfig6581::getInstance()
        static let instance = FilterModelConfig6581()

        static var DAC_BITS: Int { 11 }

        /// Power bricks generate voltages slightly out of spec
        static var VOLTAGE_SKEW: Double { 1.015 }

        /// This is the SID 6581 op-amp voltage transfer function, measured on
        /// CAP1B/CAP1A on a chip marked MOS 6581R4AR 0687 14.
        /// All measured chips have op-amps with output voltages (and thus input
        /// voltages) within the range of 0.81V - 10.31V.
        static let opamp_voltage: [Spline.Point] = [
            (0.81, 10.31), // Approximate start of actual range
            (2.40, 10.31),
            (2.60, 10.30),
            (2.70, 10.29),
            (2.80, 10.26),
            (2.90, 10.17),
            (3.00, 10.04),
            (3.10, 9.83),
            (3.20, 9.58),
            (3.30, 9.32),
            (3.50, 8.69),
            (3.70, 8.00),
            (4.00, 6.89),
            (4.40, 5.21),
            (4.54, 4.54), // Working point (vi = vo)
            (4.60, 4.19),
            (4.80, 3.00),
            (4.90, 2.30), // Change of curvature
            (4.95, 2.03),
            (5.00, 1.88),
            (5.05, 1.77),
            (5.10, 1.69),
            (5.20, 1.58),
            (5.40, 1.44),
            (5.60, 1.33),
            (5.80, 1.26),
            (6.00, 1.21),
            (6.40, 1.12),
            (7.00, 1.02),
            (7.50, 0.97),
            (8.50, 0.89),
            (10.00, 0.81),
            (10.31, 0.81), // Approximate end of actual range
        ].map { Spline.Point(x: $0.0, y: $0.1) }

        /// Transistor parameters.
        let WL_vcr: Double ///< W/L for VCR
        let WL_snake: Double ///< W/L for "snake"

        /// DAC parameters.
        let dac_zero: Double
        let dac_scale: Double

        /// DAC lookup table
        let dac: Dac

        /// Voltage Controlled Resistors
        let vcr_nVg: UnsafeMutablePointer<UInt16> // 1 << 16
        let vcr_n_Ids_term: UnsafeMutablePointer<Double> // 1 << 16

        // Voice DC offset LUT
        let voiceDC: UnsafeMutablePointer<Double> // 256

        var bytes: Int { tableBytes + (1 << 16) * 2 + (1 << 16) * 8 + 256 * 8 }

        func getDacZero(_ adjustment: Double) -> Double {
            dac_zero + (1.0 - adjustment)
        }

        private init() {
            WL_vcr = 9.0 / 1.0
            WL_snake = 1.0 / 115.0
            dac_zero = 6.65
            dac_scale = 2.63
            var dac = Dac(FilterModelConfig6581.DAC_BITS)
            dac.kinkedDac(.mos6581)
            self.dac = dac
            vcr_nVg = .allocate(capacity: 1 << 16)
            vcr_n_Ids_term = .allocate(capacity: 1 << 16)
            voiceDC = .allocate(capacity: 256)

            // build temp n table
            var resonance_n = [Double](repeating: 0, count: 16)
            for n8 in 0 ..< 16 {
                resonance_n[n8] = Double(~n8 & 0xF) / 8.0
            }

            super.init(
                1.5, // voice voltage range FIXME should theoretically be ~3,571V
                470e-12, // capacitor value
                12.0 * FilterModelConfig6581.VOLTAGE_SKEW, // Vdd
                1.31, // Vth
                20e-6, // uCox
                FilterModelConfig6581.opamp_voltage,
                mixer_nRatio: 8.0 / 6.0,
                volume_nDivisor: 12.0,
                resonance_n: resonance_n
            )

            do {
                var envDac = Dac(8)
                envDac.kinkedDac(.mos6581)
                for i in 0 ..< 256 {
                    let envI = envDac.getOutput(UInt32(i))
                    voiceDC[i] = 5.0 * FilterModelConfig6581.VOLTAGE_SKEW + (0.2143 * envI)
                }
            }

            // filterVcrVg
            do {
                let nVddt = N16 * (Vddt - vmin)

                for i in 0 ..< (1 << 16) {
                    // The table index is right-shifted 16 times in order to fit in
                    // 16 bits; the argument to sqrt is thus multiplied by (1 << 16).
                    vcr_nVg[i] = FilterModelConfig.to_ushort(nVddt - (Double(UInt32(i) << 16)).squareRoot())
                }
            }

            // filterVcrIds
            do {
                //  EKV model:
                //
                //  Ids = Is * (if - ir)
                //  Is = (2 * u*Cox * Ut^2)/k * W/L
                //  if = ln^2(1 + e^((k*(Vg - Vt) - Vs)/(2*Ut))
                //  ir = ln^2(1 + e^((k*(Vg - Vt) - Vd)/(2*Ut))

                // moderate inversion characteristic current
                // will be multiplied by uCox later
                let Ut = FilterModelConfig.Ut
                let Is = (2.0 * Ut * Ut) * WL_vcr

                // Normalized current factor for 1 cycle at 1MHz.
                let N15 = norm * Double(Int16.max)
                let n_Is = N15 * 1.0e-6 / C * Is

                // kVgt_Vx = k*(Vg - Vt) - Vx
                // I.e. if k != 1.0, Vg must be scaled accordingly.
                let r_N16_2Ut = 1.0 / (N16 * 2.0 * Ut)
                for i in 0 ..< (1 << 16) {
                    let kVgt_Vx = i + Int(Int16.min)
                    let log_term = log1p(exp(Double(kVgt_Vx) * r_N16_2Ut))
                    // Scaled by m*2^15
                    vcr_n_Ids_term[i] = n_Is * log_term * log_term
                }
            }
        }

        /// FilterModelConfig6581::setFilterRange(): the new uCox value for an adjustment, or nil when the
        /// change from the current value is too small to act on.
        func uCox(forRange adjustment: Double, current: Double) -> Double? {
            // clamp into allowed range
            let adjustment = min(max(adjustment, 0.0), 1.0)

            // Get the new uCox value, in the range [1,40]
            let new_uCox = (1.0 + 39.0 * adjustment) * 1e-6

            // Ignore small changes
            if abs(current - new_uCox) < 1e-12 {
                return nil
            }

            return new_uCox
        }

        /// Construct an 11 bit cutoff frequency DAC output voltage table.
        ///
        /// - Parameters:
        ///   - adjustment: the filter curve position
        ///   - f0_dac: the table to fill, 1 << DAC_BITS entries
        ///   - rnd: the chip's dither index
        func getDAC(_ adjustment: Double, into f0_dac: UnsafeMutablePointer<UInt16>, _ rnd: inout Int32) {
            let dac_zero = getDacZero(adjustment)

            for i in 0 ..< (1 << FilterModelConfig6581.DAC_BITS) {
                let fcd = dac.getOutput(UInt32(i))
                f0_dac[i] = getNormalizedValue(dac_zero + fcd * dac_scale, &rnd)
            }
        }

        /// `to_ushort(vcr_n_Ids_term[i] * uCox)` for every i: what FilterModelConfig6581::getVcr_n_Ids_term()
        /// returns, tabulated for one uCox so the per-cycle code does no floating-point work for it.
        func fillVcr_n_Ids_term(_ table: UnsafeMutablePointer<UInt16>, uCox: Double) {
            for i in 0 ..< (1 << 16) {
                table[i] = FilterModelConfig.to_ushort(vcr_n_Ids_term[i] * uCox)
            }
        }
    }

    // MARK: - FilterModelConfig8580.h / FilterModelConfig8580.cpp

    /// Calculate parameters for 8580 filter emulation.
    final class FilterModelConfig8580: FilterModelConfig, @unchecked Sendable {
        /// FilterModelConfig8580::getInstance()
        static let instance = FilterModelConfig8580()

        /// Reference voltage generated from Vcc by a voltage divider
        static var Vref: Double { 4.75 }

        /// Power bricks generate voltages slightly out of spec
        static var VOLTAGE_SKEW: Double { 1.01 }

        static func getVref() -> Double { Vref * VOLTAGE_SKEW }

        /*
         * R1 = 15.3*Ri
         * R2 =  7.3*Ri
         * R3 =  4.7*Ri
         * Rf =  1.4*Ri
         * R4 =  1.4*Ri
         * R8 =  2.0*Ri
         * RC =  2.8*Ri
         *
         * res  feedback  input
         * ---  --------  -----
         *  0   Rf        Ri
         *  1   Rf|R1     Ri
         *  2   Rf|R2     Ri
         *  3   Rf|R3     Ri
         *  4   Rf        R4
         *  5   Rf|R1     R4
         *  6   Rf|R2     R4
         *  7   Rf|R3     R4
         *  8   Rf        R8
         *  9   Rf|R1     R8
         *  A   Rf|R2     R8
         *  B   Rf|R3     R8
         *  C   Rf        RC
         *  D   Rf|R1     RC
         *  E   Rf|R2     RC
         *  F   Rf|R3     RC
         */
        static let resGain: [Double] = [
            1.4 / 1.0, //      Rf/Ri   1.4
            ((1.4 * 15.3) / (1.4 + 15.3)) / 1.0, // (Rf|R1)/Ri   1.28263
            ((1.4 * 7.3) / (1.4 + 7.3)) / 1.0, // (Rf|R2)/Ri   1.17471
            ((1.4 * 4.7) / (1.4 + 4.7)) / 1.0, // (Rf|R3)/Ri   1.07869
            1.4 / 1.4, //      Rf/R4   1
            ((1.4 * 15.3) / (1.4 + 15.3)) / 1.4, // (Rf|R1)/R4   0.916168
            ((1.4 * 7.3) / (1.4 + 7.3)) / 1.4, // (Rf|R2)/R4   0.83908
            ((1.4 * 4.7) / (1.4 + 4.7)) / 1.4, // (Rf|R3)/R4   0.770492
            1.4 / 2.0, //      Rf/R8   0.7
            ((1.4 * 15.3) / (1.4 + 15.3)) / 2.0, // (Rf|R1)/R8   0.641317
            ((1.4 * 7.3) / (1.4 + 7.3)) / 2.0, // (Rf|R2)/R8   0.587356
            ((1.4 * 4.7) / (1.4 + 4.7)) / 2.0, // (Rf|R3)/R8   0.539344
            1.4 / 2.8, //      Rf/RC   0.5
            ((1.4 * 15.3) / (1.4 + 15.3)) / 2.8, // (Rf|R1)/RC   0.458084
            ((1.4 * 7.3) / (1.4 + 7.3)) / 2.8, // (Rf|R2)/RC   0.41954
            ((1.4 * 4.7) / (1.4 + 4.7)) / 2.8, // (Rf|R3)/RC   0.385246
        ]

        /// This is the SID 8580 op-amp voltage transfer function, measured on
        /// CAP1B/CAP1A on a chip marked CSG 8580R5 1690 25.
        static let opamp_voltage: [Spline.Point] = [
            (1.30, 8.91), // Approximate start of actual range
            (4.76, 8.91),
            (4.77, 8.90),
            (4.78, 8.88),
            (4.785, 8.86),
            (4.79, 8.80),
            (4.795, 8.60),
            (4.80, 8.25),
            (4.805, 7.50),
            (4.81, 6.10),
            (4.815, 4.05), // Change of curvature
            (4.82, 2.27),
            (4.825, 1.65),
            (4.83, 1.55),
            (4.84, 1.47),
            (4.85, 1.43),
            (4.87, 1.37),
            (4.90, 1.34),
            (5.00, 1.30),
            (5.10, 1.30),
            (8.91, 1.30), // Approximate end of actual range
        ].map { Spline.Point(x: $0.0, y: $0.1) }

        /// getVoiceDC() for every envelope value: on the 8580 it is getVref() for all of them. A table so
        /// that the per-cycle code is the same for both models.
        let voiceDC: UnsafeMutablePointer<Double> // 256

        var bytes: Int { tableBytes + 256 * 8 }

        private init() {
            voiceDC = .allocate(capacity: 256)
            voiceDC.initialize(repeating: FilterModelConfig8580.getVref(), count: 256)
            super.init(
                0.24, // voice voltage range FIXME should theoretically be ~0,474V
                22e-9, // capacitor value
                9.0 * FilterModelConfig8580.VOLTAGE_SKEW, // Vdd
                0.80, // Vth
                100e-6, // uCox
                FilterModelConfig8580.opamp_voltage,
                mixer_nRatio: 8.0 / 5.0,
                volume_nDivisor: 16.0,
                resonance_n: FilterModelConfig8580.resGain
            )
        }
    }
}
