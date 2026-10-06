// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  ---------------------------------------------------------------------------
//  This file is part of a Swift port of reSID, a MOS6581 SID emulator engine.
//  Copyright (C) 2010  Dag Lem <resid@nimrod.no>
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 2 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//  ---------------------------------------------------------------------------
//
// Lookup tables shared by every chip of one model: reSID's static class members
// (WaveformGenerator::model_wave / model_dac, EnvelopeGenerator::model_dac, Filter::model_filter,
// Filter::vcr_kVg, Filter::vcr_n_Ids_term, Filter::n_snake, Filter::n_param), from wave.cc,
// envelope.cc, dac.cc, spline.h and the Filter constructor in filter8580new.cc.
//
// The tables are built with double arithmetic. To reproduce the C++ build bit for bit the
// expressions below keep reSID's operand order exactly; Swift never fuses a*b+c into an FMA, which
// corresponds to compiling the C++ with -ffp-contract=off.

import Foundation

// MARK: C++ conversion semantics

// Swift traps when a floating-point value does not fit the integer type; C++ leaves it undefined.
// These helpers do what the arm64 conversion instructions do (saturate, NaN gives 0), so the two
// agree even at the edges.

@inline(__always) func sid_int(_ d: Double) -> Int32 {
    if d >= 2_147_483_647.0 { return Int32.max }
    if d <= -2_147_483_648.0 { return Int32.min }
    if d != d { return 0 }
    return Int32(d)
}

@inline(__always) func sid_uint(_ d: Double) -> UInt32 {
    if d >= 4_294_967_295.0 { return UInt32.max }
    if d <= 0.0 { return 0 }
    if d != d { return 0 }
    return UInt32(d)
}

/// `(unsigned short)double`: converted to a 32-bit unsigned value, then narrowed.
@inline(__always) func sid_ushort(_ d: Double) -> UInt16 {
    UInt16(truncatingIfNeeded: sid_uint(d))
}

// MARK: dac.cc

// "Even in standard transistors a small amount of current leaks
//  even when they are technically switched off."
// https://en.wikipedia.org/wiki/Subthreshold_conduction
private let MOSFET_LEAKAGE_6581 = 0.0075
private let MOSFET_LEAKAGE_8580 = 0.0035

// ----------------------------------------------------------------------------
// Calculation of lookup tables for SID DACs.
// ----------------------------------------------------------------------------

// The SID DACs are built up as follows:
//
//          n  n-1      2   1   0    VGND
//          |   |       |   |   |      |   Termination
//         2R  2R      2R  2R  2R     2R   only for
//          |   |       |   |   |      |   MOS 8580
//      Vo  --R---R--...--R---R--    ---
//
//
// All MOS 6581 DACs are missing a termination resistor at bit 0. This causes
// pronounced errors for the lower 4 - 5 bits (e.g. the output for bit 0 is
// actually equal to the output for bit 1), resulting in DAC discontinuities
// for the lower bits.
// In addition to this, the 6581 DACs exhibit further severe discontinuities
// for higher bits, which may be explained by a less than perfect match between
// the R and 2R resistors, or by output impedance in the NMOS transistors
// providing the bit voltages. A good approximation of the actual DAC output is
// achieved for 2R/R ~ 2.20.
//
// The MOS 8580 DACs, on the other hand, do not exhibit any discontinuities.
// These DACs include the correct termination resistor, and also seem to have
// very accurately matched R and 2R resistors (2R/R = 2.00).

func sid_build_dac_table(_ dac: UnsafeMutablePointer<UInt16>, _ bits: Int, _ _2R_div_R: Double, _ term: Bool) {
    var vbit = [Double](repeating: 0, count: 12)

    let leakage = term ? MOSFET_LEAKAGE_8580 : MOSFET_LEAKAGE_6581

    // Calculate voltage contribution by each individual bit in the R-2R ladder.
    for set_bit in 0 ..< bits {
        var bit = 0

        var Vn = 1.0 // Normalized bit voltage.
        let R = 1.0 // Normalized R
        let _2R = _2R_div_R * R // 2R
        var Rn = term ? // Rn = 2R for correct termination,
            _2R : Double.infinity // INFINITY for missing termination.

        // Calculate DAC "tail" resistance by repeated parallel substitution.
        while bit < set_bit {
            if Rn == Double.infinity {
                Rn = R + _2R
            } else {
                Rn = R + _2R * Rn / (_2R + Rn) // R + 2R || Rn
            }
            bit += 1
        }

        // Source transformation for bit voltage.
        if Rn == Double.infinity {
            Rn = _2R
        } else {
            Rn = _2R * Rn / (_2R + Rn) // 2R || Rn
            Vn = Vn * Rn / _2R
        }

        // Calculate DAC output voltage by repeated source transformation from
        // the "tail".
        bit += 1
        while bit < bits {
            Rn += R
            let I = Vn / Rn
            Rn = _2R * Rn / (_2R + Rn) // 2R || Rn
            Vn = Rn * I
            bit += 1
        }

        vbit[set_bit] = Vn
    }

    // Calculate the voltage for any combination of bits by superpositioning.
    for i in 0 ..< (1 << bits) {
        var x = i
        var Vo = 0.0
        for j in 0 ..< bits {
            Vo += ((x & 0x1) != 0 ? 1.0 : leakage) * vbit[j]
            x >>= 1
        }

        // Scale maximum output to 2^bits - 1.
        dac[i] = sid_ushort(Double((1 << bits) - 1) * Vo + 0.5)
    }
}

// MARK: spline.h

// Our objective is to construct a smooth interpolating single-valued function
// y = f(x). See spline.h in reSID for the derivation; this is the forward
// differencing variant reSID compiles (SPLINE_BRUTE_FORCE is not defined).

private func cubic_coefficients(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                                _ k1: Double, _ k2: Double) -> (a: Double, b: Double, c: Double, d: Double)
{
    let dx = x2 - x1, dy = y2 - y1

    let a = ((k1 + k2) - 2 * dy / dx) / (dx * dx)
    let b = ((k2 - k1) / dx - 3 * (x1 + x2) * a) / 2
    let c = k1 - (3 * x1 * a + 2 * b) * x1
    let d = y1 - ((x1 * a + b) * x1 + c) * x1
    return (a, b, c, d)
}

/// PointPlotter<unsigned int>.
@inline(__always) private func plot(_ f: UnsafeMutablePointer<UInt32>, _ x: Double, _ y: Double) {
    var y = y
    // Clamp negative values to zero.
    if y < 0 {
        y = 0
    }

    f[Int(sid_int(x))] = sid_uint(y + 0.5)
}

private func interpolate_forward_difference(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                                            _ k1: Double, _ k2: Double,
                                            _ f: UnsafeMutablePointer<UInt32>, _ res: Double)
{
    let (a, b, c, d) = cubic_coefficients(x1, y1, x2, y2, k1, k2)

    var y = ((a * x1 + b) * x1 + c) * x1 + d
    var dy = (3 * a * (x1 + res) + 2 * b) * x1 * res + ((a * res + b) * res + c) * res
    var d2y = (6 * a * (x1 + res) + 2 * b) * res * res
    let d3y = 6 * a * res * res * res

    // Calculate each point.
    var x = x1
    while x <= x2 {
        plot(f, x, y)
        y += dy; dy += d2y; d2y += d3y
        x += res
    }
}

/// Evaluation of complete interpolating function.
/// Note that since each curve segment is controlled by four points, the
/// end points will not be interpolated. If extra control points are not
/// desirable, the end points can simply be repeated to ensure interpolation.
/// Note also that points of non-differentiability and discontinuity can be
/// introduced by repeating points.
private func interpolate(_ p: [(Double, Double)], _ pn: Int, _ f: UnsafeMutablePointer<UInt32>, _ res: Double) {
    var k1 = 0.0, k2 = 0.0

    // Set up points for first curve segment.
    var p0 = 0
    var p1 = p0 + 1
    var p2 = p1 + 1
    var p3 = p2 + 1

    @inline(__always) func x(_ i: Int) -> Double { p[i].0 }
    @inline(__always) func y(_ i: Int) -> Double { p[i].1 }

    // Draw each curve segment.
    while p2 != pn {
        defer { p0 += 1; p1 += 1; p2 += 1; p3 += 1 }
        // p1 and p2 equal; single point.
        if x(p1) == x(p2) {
            continue
        }
        // Both end points repeated; straight line.
        if x(p0) == x(p1), x(p2) == x(p3) {
            k1 = (y(p2) - y(p1)) / (x(p2) - x(p1))
            k2 = k1
        }
        // p0 and p1 equal; use f''(x1) = 0.
        else if x(p0) == x(p1) {
            k2 = (y(p3) - y(p1)) / (x(p3) - x(p1))
            k1 = (3 * (y(p2) - y(p1)) / (x(p2) - x(p1)) - k2) / 2
        }
        // p2 and p3 equal; use f''(x2) = 0.
        else if x(p2) == x(p3) {
            k1 = (y(p2) - y(p0)) / (x(p2) - x(p0))
            k2 = (3 * (y(p2) - y(p1)) / (x(p2) - x(p1)) - k1) / 2
        }
        // Normal curve.
        else {
            k1 = (y(p2) - y(p0)) / (x(p2) - x(p0))
            k2 = (y(p3) - y(p1)) / (x(p3) - x(p1))
        }

        interpolate_forward_difference(x(p1), y(p1), x(p2), y(p2), k1, k2, f, res)
    }
}

// MARK: filter8580new.cc

// This is the SID 6581 op-amp voltage transfer function, measured on
// CAP1B/CAP1A on a chip marked MOS 6581R4AR 0687 14.
// All measured chips have op-amps with output voltages (and thus input
// voltages) within the range of 0.81V - 10.31V.

private let opamp_voltage_6581: [(Double, Double)] = [
    (0.81, 10.31), // Approximate start of actual range
    (0.81, 10.31), // Repeated point
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
    (10.31, 0.81), // Repeated end point
]

// This is the SID 8580 op-amp voltage transfer function, measured on
// CAP1B/CAP1A on a chip marked CSG 8580R5 1690 25.
private let opamp_voltage_8580: [(Double, Double)] = [
    (1.30, 8.91), // Approximate start of actual range
    (1.30, 8.91), // Repeated end point
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
    (8.91, 1.30), // Repeated end point
]

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
private func resGain(_ n8: Int) -> Double {
    // Written as arithmetic on variables so the divisions happen in double precision at run time,
    // as the C++ compiler's constant folding does.
    let rf = 1.4, r1 = 15.3, r2 = 7.3, r3 = 4.7
    let feedback: Double = switch n8 & 3 {
    case 0: rf //                              Rf
    case 1: (rf * r1) / (rf + r1) //           Rf|R1
    case 2: (rf * r2) / (rf + r2) //           Rf|R2
    default: (rf * r3) / (rf + r3) //          Rf|R3
    }
    let input: Double = switch n8 >> 2 {
    case 0: 1.0 // Ri
    case 1: 1.4 // R4
    case 2: 2.0 // R8
    default: 2.8 // RC
    }
    return feedback / input
}

private struct model_filter_init_t {
    // Op-amp transfer function.
    var opamp_voltage: [(Double, Double)]
    // Voice output characteristics.
    var voice_voltage_range: Double
    var voice_DC_voltage: Double
    // Capacitor value.
    var C: Double
    // Transistor parameters.
    var Vdd: Double
    var Vth: Double // Threshold voltage
    var Ut: Double // Thermal voltage: Ut = k*T/q = 8.61734315e-5*T ~ 26mV
    var k: Double // Gate coupling coefficient: K = Cox/(Cox+Cdep) ~ 0.7
    var uCox: Double // u*Cox
    var WL_vcr: Double // W/L for VCR
    var WL_snake: Double // W/L for "snake"
    // DAC parameters.
    var dac_zero: Double
    var dac_scale: Double
    var dac_2R_div_R: Double
    var dac_term: Bool
}

private func model_filter_init(_ m: Int) -> model_filter_init_t {
    if m == 0 {
        return model_filter_init_t(
            opamp_voltage: opamp_voltage_6581,
            // The dynamic analog range of one voice is approximately 1.5V,
            voice_voltage_range: 1.5,
            // riding at a DC level of approximately 5.0V.
            voice_DC_voltage: 5.075, // 5V +1.5%
            // Capacitor value.
            C: 470e-12,
            // Transistor parameters.
            Vdd: 12.18, // 12V +1.5%
            Vth: 1.31,
            Ut: 26.0e-3,
            k: 1.0,
            uCox: 20e-6,
            WL_vcr: 9.0 / 1.0,
            WL_snake: 1.0 / 115,
            // DAC parameters.
            dac_zero: 6.65,
            dac_scale: 2.63,
            dac_2R_div_R: 2.20,
            dac_term: false
        )
    }
    return model_filter_init_t(
        opamp_voltage: opamp_voltage_8580,
        // FIXME: Measure for the 8580.
        voice_voltage_range: 0.24,
        voice_DC_voltage: 4.7975, // 4.75V +1%
        // Capacitor value.
        C: 22e-9,
        // Transistor parameters.
        Vdd: 9.09, // 9V +1%
        Vth: 0.80,
        Ut: 26.0e-3,
        k: 1.0, // Unused, leave at 1
        uCox: 100e-6,
        // FIXME: 6581 only
        WL_vcr: 0,
        WL_snake: 0,
        dac_zero: 0,
        dac_scale: 0,
        dac_2R_div_R: 2.00,
        dac_term: true
    )
}

// The 4.75V voltage for the virtual ground is generated by a PolySi resistor divider
private let Vref = 4.7975 // 4.75V +1%

private struct opamp_t {
    var vx: UInt16
    var dvx: Int16
}

/*
 Find output voltage in inverting gain and inverting summer SID op-amp
 circuits, using a combination of Newton-Raphson and bisection.

              ---R2--
             |       |
   vi ---R1-----[A>----- vo
             vx

 From Kirchoff's current law it follows that

   IR1f + IR2r = 0

 Substituting the triode mode transistor model K*W/L*(Vgst^2 - Vgdt^2)
 for the currents, we get:

   n*((Vddt - vx)^2 - (Vddt - vi)^2) + (Vddt - vx)^2 - (Vddt - vo)^2 = 0

 Our root function f can thus be written as:

   f = (n + 1)*(Vddt - vx)^2 - n*(Vddt - vi)^2 - (Vddt - vo)^2 = 0

 We are using the mapping function x = vo - vx -> vx. We thus substitute
 for vo = vx + x and get:

   f(vx) = (n + 1)*(Vddt - vx)^2 - n*(Vddt - vi)^2 - (Vddt - (vx + x))^2 = 0

 See filter8580new.h for the derivative.
 */
@inline(__always)
private func solve_gain_d(_ opamp: UnsafePointer<opamp_t>, _ n: Double, _ vi: Int32, _ x: inout Int32,
                          _ mf_ak: Int32, _ mf_bk: Int32, _ mf_kVddt: Int32) -> Int32
{
    // Note that all variables are translated and scaled in order to fit
    // in 16 bits. It is not necessary to explicitly translate the variables here,
    // since they are all used in subtractions which cancel out the translation:
    // (a - t) - (b - t) = a - b

    // Start off with an estimate of x and a root bracket [ak, bk].
    // f is increasing, so that f(ak) < 0 and f(bk) > 0.
    var ak = mf_ak, bk = mf_bk

    let a = n + 1.0
    let b = mf_kVddt // Scaled by m*2^16
    let b_vi = b > vi ? Double(b &- vi) : 0.0 // Scaled by m*2^16
    let c = n * (b_vi * b_vi) // Scaled by m^2*2^32

    while true {
        let xk = x

        // Calculate f and df.
        let vx = Int32(opamp[Int(x)].vx) // Scaled by m*2^16
        let dvx = Int32(opamp[Int(x)].dvx) // Scaled by m*2^11

        // f = a*(b - vx)^2 - c - (b - vo)^2
        // df = 2*((b - vo) - a*(b - vx))*dvx
        //
        var vo = vx &+ (x << 1) &- (1 << 16)
        if vo > (1 << 16) - 1 {
            vo = (1 << 16) - 1
        } else if vo < 0 {
            vo = 0
        }
        let b_vx = b > vx ? Double(b &- vx) : 0.0
        let b_vo = b > vo ? Double(b &- vo) : 0.0
        // The dividend is scaled by m^2*2^32.
        let f = a * (b_vx * b_vx) - c - (b_vo * b_vo)
        // The divisor is scaled by m*2^27.
        let df = 2.0 * (b_vo - a * b_vx) * Double(dvx)
        // The resulting quotient is thus scaled by m*2^5.

        // Newton-Raphson step: xk1 = xk - f(xk)/f'(xk)
        // If f(xk) or f'(xk) are zero then we can't improve further.
        if df != 0 {
            // Multiply by 2^11 so it's scaled by m*2^16.
            x = x &- sid_int(Double(1 << 11) * f / df)
        }
        if x == xk {
            // No further root improvement possible.
            return vo
        }

        // Narrow down root bracket.
        if f < 0 {
            // f(xk) < 0
            ak = xk
        } else {
            // f(xk) > 0
            bk = xk
        }

        if x <= ak || x >= bk {
            // Bisection step (ala Dekker's method).
            x = (ak &+ bk) >> 1
            if x == ak {
                // No further bisection possible.
                return vo
            }
        }
    }
}

/// summer_offset<i>::value: the start of the summer table for i voice inputs (2 + i input "resistors").
@inline(__always) func sid_summer_offset(_ i: Int) -> Int32 {
    var value: Int32 = 0
    var j = 1
    while j <= i {
        value += Int32((2 + j - 1) << 16)
        j += 1
    }
    return value
}

/// mixer_offset<i>::value: the start of the mixer table for i inputs.
@inline(__always) func sid_mixer_offset(_ i: Int) -> Int32 {
    if i == 0 { return 0 }
    var value: Int32 = 1
    var j = 2
    while j <= i {
        value += Int32((j - 1) << 16)
        j += 1
    }
    return value
}

/// One chip model's tables. Built once per process on first use and never freed, like the C++ statics.
final class SIDModelTables: @unchecked Sendable {
    static let mos6581 = SIDModelTables(0)
    static let mos8580 = SIDModelTables(1)

    static func tables(for model: SIDModel) -> SIDModelTables {
        model == .mos6581 ? mos6581 : mos8580
    }

    // WaveformGenerator::model_wave[model], 8 tables of 4096.
    let model_wave: UnsafeMutablePointer<UInt16>
    // WaveformGenerator::model_dac[model].
    let wave_dac: UnsafeMutablePointer<UInt16>
    // EnvelopeGenerator::model_dac[model].
    let env_dac: UnsafeMutablePointer<UInt16>
    /// `wave_dac[i] - wave_zero`: the first factor of Voice::output().
    let voice_dac: UnsafeMutablePointer<Int32>
    /// Voice::wave_zero, the waveform D/A zero level.
    let wave_zero: Int32

    // Filter::model_filter[model].
    let kVddt: Int32 // K*(Vdd - Vth)
    let voice_scale_s14: Int32
    let voice_DC: Int32
    let ak: Int32
    let bk: Int32
    let vc_min: Int32
    let vc_max: Int32
    let filterGain: Int32
    let vo_N16: Double // Fixed point scaling for 16 bit op-amp output.
    //
    // opamp_rev, summer, resonance and vcr_n_Ids_term are indexed with values that come out of the
    // filter's arithmetic. reSID asserts that those stay inside the tables; here each of the four
    // has a margin on both sides, wide enough for anything the arithmetic can produce and filled
    // with the nearest table entry, so the per-cycle code needs no range checks and an out-of-range
    // index behaves as if it had been clamped. The pointers address element 0 of the table proper.
    //
    // Reverse op-amp transfer function.
    let opamp_rev: UnsafeMutablePointer<UInt16> // 1 << 16
    // Lookup tables for gain and summer op-amps in output stage / filter.
    let summer: UnsafeMutablePointer<UInt16> // summer_offset<5>::value
    let gain: UnsafeMutablePointer<UInt16> // 16 tables of 1 << 16
    let resonance: UnsafeMutablePointer<UInt16> // 16 tables of 1 << 16
    let mixer: UnsafeMutablePointer<UInt16> // mixer_offset<8>::value
    // Cutoff frequency DAC output voltage table. FC is an 11 bit register.
    let f0_dac: UnsafeMutablePointer<UInt16> // 1 << 11

    // VCR - 6581 only (allocated but unused for the 8580).
    let vcr_kVg: UnsafeMutablePointer<UInt16> // 1 << 16
    let vcr_n_Ids_term: UnsafeMutablePointer<UInt16> // 1 << 16
    // 6581 only
    let n_snake: Int32
    // 8580 only
    let n_param: Int32
    /// The value the Filter constructor gives `nVgt` (8580), and `Vw_bias` (6581, always 0).
    let nVgt: Int32

    // Margins (in elements, each side). The index ranges:
    // - opamp_rev[(vc >> 15) + (1 << 15)] with vc any 32-bit value: -32768 ... 98303.
    // - vcr_n_Ids_term[kVg - v + (1 << 15)], kVg 16 bits, v either a 16-bit table value or an
    //   integrator output vx + (vc >> 14) in -131072 ... 196606: -163838 ... 229375.
    // - resonance[res][Vbp], Vbp an integrator output: -131072 below table 0 ... 131070 past table 15.
    // - summer[offset + resonance + Vlp + Vi], Vi the sum of up to three voices (each within
    //   voice_DC -8192 ... +8191) and EXT IN (-131072 ... 196606): -286720 ... 286709 past the end.
    static var opamp_rev_margin: Int { 1 << 15 }
    static var vcr_n_Ids_term_margin: Int { 163_840 }
    static var resonance_margin: Int { 131_072 }
    static var summer_margin: Int { 5 << 16 }

    /// Allocates `count` elements with `margin` more on each side and returns the address of element 0.
    private static func allocate(_ count: Int, margin: Int) -> UnsafeMutablePointer<UInt16> {
        let base = UnsafeMutablePointer<UInt16>.allocate(capacity: count + 2 * margin)
        base.initialize(repeating: 0, count: count + 2 * margin)
        return base + margin
    }

    /// Fills the margins with the first and last table entries.
    private static func fillMargins(_ table: UnsafeMutablePointer<UInt16>, _ count: Int, margin: Int) {
        for i in 1 ... margin {
            table[-i] = table[0]
            table[count - 1 + i] = table[count - 1]
        }
    }

    /// summer_offset<5>::value and mixer_offset<8>::value, the table sizes.
    static var summer_size: Int { (2 + 3 + 4 + 5 + 6) << 16 }
    static var mixer_size: Int { 1 + ((1 + 2 + 3 + 4 + 5 + 6 + 7) << 16) }

    /// `vo_N16` for a model, without building its tables (needed by adjust_filter_bias).
    static func vo_N16(_ m: Int) -> Double {
        let fi = model_filter_init(m)
        let vmin = fi.opamp_voltage[0].0
        let opamp_max = fi.opamp_voltage[0].1
        let kVddt = fi.k * (fi.Vdd - fi.Vth)
        let vmax = kVddt < opamp_max ? opamp_max : kVddt
        let denorm = vmax - vmin
        let norm = 1.0 / denorm
        return norm * Double((1 << 16) - 1)
    }

    /// The 8580 gate voltage term for a given filter bias, as computed in Filter::adjust_filter_bias.
    static func nVgt8580(dac_bias: Double) -> Int32 {
        // Gate voltage is controlled by the switched capacitor voltage divider
        // Ua = Ue * v = 4.75v  1<v<2
        let fi = model_filter_init(1)
        let Vg = Vref * (dac_bias * 6.0 / 100.0 + 1.6)
        let Vgt = Vg - fi.Vth
        let vmin = fi.opamp_voltage[0].0

        // Vg - Vth, normalized so that translated values can be subtracted:
        // Vgt - x = (Vgt - t) - (x - t)
        return sid_int(vo_N16(1) * (Vgt - vmin) + 0.5)
    }

    private init(_ m: Int) {
        // ---- wave.cc: WaveformGenerator class init ----
        model_wave = .allocate(capacity: 8 << 12)
        model_wave.initialize(repeating: 0, count: 8 << 12)
        // Calculate tables for normal waveforms.
        var accumulator: UInt32 = 0
        for i in 0 ..< (1 << 12) {
            let msb = accumulator & 0x800000

            // Noise mask, triangle, sawtooth, pulse mask.
            // The triangle calculation is made branch-free, just for the hell of it.
            model_wave[(0 << 12) + i] = 0xFFF
            model_wave[(1 << 12) + i] = UInt16(truncatingIfNeeded: ((accumulator ^ (msb != 0 ? 0xFFFF_FFFF : 0)) >> 11) & 0xFFE)
            model_wave[(2 << 12) + i] = UInt16(truncatingIfNeeded: accumulator >> 12)
            model_wave[(4 << 12) + i] = 0xFFF

            accumulator &+= 0x1000
        }
        // Combined waveforms sampled from OSC3: the bytes of wave*.dat shifted left four bits,
        // which is what samp2src.pl writes into the C headers.
        let samples = m == 0
            ? [SIDWaveSamples.wave6581__ST, SIDWaveSamples.wave6581_P_T, SIDWaveSamples.wave6581_PS_, SIDWaveSamples.wave6581_PST]
            : [SIDWaveSamples.wave8580__ST, SIDWaveSamples.wave8580_P_T, SIDWaveSamples.wave8580_PS_, SIDWaveSamples.wave8580_PST]
        for (slot, text) in zip([3, 5, 6, 7], samples) {
            var count = 0
            var high: UInt16 = 0
            var haveHigh = false
            for c in text.utf8 {
                let digit: UInt16
                switch c {
                case 0x30 ... 0x39: digit = UInt16(c) - 0x30
                case 0x61 ... 0x66: digit = UInt16(c) - 0x61 + 10
                default: continue
                }
                if haveHigh {
                    model_wave[(slot << 12) + count] = ((high << 4) | digit) << 4
                    count += 1
                    haveHigh = false
                } else {
                    high = digit
                    haveHigh = true
                }
            }
            precondition(count == 1 << 12, "combined waveform table has the wrong size")
        }

        // Build DAC lookup tables for 12-bit DACs.
        // MOS 6581: 2R/R ~ 2.20, missing termination resistor.
        // MOS 8580: 2R/R ~ 2.00, correct termination.
        wave_dac = .allocate(capacity: 1 << 12)
        sid_build_dac_table(wave_dac, 12, m == 0 ? 2.20 : 2.00, m != 0)

        // voice.cc: the waveform D/A zero level is 0x380 on the 6581 and 0x9e0 on the 8580
        // (see Voice in SIDVoice.swift).
        wave_zero = m == 0 ? 0x380 : 0x9E0
        voice_dac = .allocate(capacity: 1 << 12)
        for i in 0 ..< (1 << 12) {
            voice_dac[i] = Int32(wave_dac[i]) - wave_zero
        }

        // ---- envelope.cc: EnvelopeGenerator class init ----
        // Build DAC lookup tables for 8-bit DACs.
        env_dac = .allocate(capacity: 1 << 8)
        sid_build_dac_table(env_dac, 8, m == 0 ? 2.20 : 2.00, m != 0)

        // ---- filter8580new.cc: Filter class init ----
        opamp_rev = Self.allocate(1 << 16, margin: Self.opamp_rev_margin)
        summer = Self.allocate(Self.summer_size, margin: Self.summer_margin)
        gain = .allocate(capacity: 16 << 16)
        resonance = Self.allocate(16 << 16, margin: Self.resonance_margin)
        mixer = .allocate(capacity: Self.mixer_size)
        f0_dac = .allocate(capacity: 1 << 11)
        vcr_kVg = .allocate(capacity: 1 << 16)
        vcr_kVg.initialize(repeating: 0, count: 1 << 16)
        vcr_n_Ids_term = Self.allocate(1 << 16, margin: Self.vcr_n_Ids_term_margin)

        let dac_bits = 11

        // Temporary tables for op-amp transfer function.
        // (The C++ leaves `voltages` uninitialised; a fresh allocation of this size is zero pages.)
        let voltages = UnsafeMutablePointer<UInt32>.allocate(capacity: 1 << 16)
        voltages.initialize(repeating: 0, count: 1 << 16)
        let opamp = UnsafeMutablePointer<opamp_t>.allocate(capacity: 1 << 16)
        opamp.initialize(repeating: opamp_t(vx: 0, dvx: 0), count: 1 << 16)
        defer {
            // Free temporary tables.
            voltages.deallocate()
            opamp.deallocate()
        }

        let fi = model_filter_init(m)
        let opamp_voltage_size = fi.opamp_voltage.count

        // Convert op-amp voltage transfer to 16 bit values.
        var vmin = fi.opamp_voltage[0].0
        let opamp_max = fi.opamp_voltage[0].1
        let kVddt = fi.k * (fi.Vdd - fi.Vth)
        let vmax = kVddt < opamp_max ? opamp_max : kVddt
        let denorm = vmax - vmin
        let norm = 1.0 / denorm

        // Scaling and translation constants.
        let N16 = norm * Double((UInt32(1) << 16) - 1)
        let N30 = norm * Double((UInt32(1) << 30) - 1)
        let N31 = norm * Double((UInt32(1) << 31) - 1)
        vo_N16 = N16

        // In the 6581 the mixer input resistors for the filter lines
        // are slightly bigger than the voice ones
        // Scale the values accordingly
        let scaleFactor = m == 0 ? 0.93 : 1.0
        filterGain = sid_int(scaleFactor * Double(1 << 12))

        // The "zero" output level of the voices.
        // The digital range of one voice is 20 bits; create a scaling term
        // for multiplication which fits in 11 bits.
        let N14 = norm * Double(UInt32(1) << 14)
        voice_scale_s14 = sid_int(N14 * fi.voice_voltage_range)
        voice_DC = sid_int(N16 * (fi.voice_DC_voltage - vmin))

        // Vdd - Vth, normalized so that translated values can be subtracted:
        // k*Vddt - x = (k*Vddt - t) - (x - t)
        let mf_kVddt = sid_int(N16 * (kVddt - vmin) + 0.5)
        self.kVddt = mf_kVddt

        let tmp_n_param = denorm * Double(1 << 13) * ((fi.uCox / 2.0) * 1.0e-6 / fi.C)

        // Create lookup table mapping op-amp voltage across output and input
        // to input voltage: vo - vx -> vx
        var scaled_voltage = [(Double, Double)](repeating: (0, 0), count: opamp_voltage_size)

        for i in 0 ..< opamp_voltage_size {
            // The target output range is 16 bits, in order to fit in an unsigned
            // short.
            //
            // The y axis is temporarily scaled to 31 bits for maximum accuracy in
            // the calculated derivative.
            //
            // Values are normalized using
            //
            //   x_n = m*2^N*(x - xmin)
            //
            // and are translated back later (for fixed point math) using
            //
            //   m*2^N*x = x_n - m*2^N*xmin
            //
            scaled_voltage[opamp_voltage_size - 1 - i].0 = N16 * (fi.opamp_voltage[i].1 - fi.opamp_voltage[i].0) / 2.0
            // Translate value to the positive axis by adding 32768
            // The same is done later in the integrator function when accessing the opamp array
            scaled_voltage[opamp_voltage_size - 1 - i].0 += Double(1 << 15)
            scaled_voltage[opamp_voltage_size - 1 - i].1 = N31 * (fi.opamp_voltage[i].0 - vmin)
        }

        // Clamp x to 16 bit range (rounding may cause overflow).
        if scaled_voltage[opamp_voltage_size - 1].0 > 65535.0 {
            // The last point is repeated.
            scaled_voltage[opamp_voltage_size - 1].0 = 65535.0
            scaled_voltage[opamp_voltage_size - 2].0 = 65535.0
        }

        interpolate(scaled_voltage, opamp_voltage_size - 1, voltages, 1.0)

        // Store both fn and dfn in the same table.
        let mf_ak = sid_int(scaled_voltage[0].0 + 0.5)
        let mf_bk = sid_int(scaled_voltage[opamp_voltage_size - 1].0 + 0.5)
        ak = mf_ak
        bk = mf_bk
        var j = 0
        while j < Int(mf_ak) {
            opamp[j].vx = 0
            opamp[j].dvx = 0
            j += 1
        }
        var f = voltages[j]
        while j < Int(mf_bk) {
            let fp = f
            f = voltages[j] // Scaled by m*2^31
            // m*2^31*dy/1 = (m*2^31*dy)/(m*2^16*dx) = 2^15*dy/dx
            let df = Int32(bitPattern: f &- fp) // Scaled by 2^15

            // 16 bits unsigned: m*2^16*(fn - xmin)
            opamp[j].vx = f > (0xFFFF << 15) ? 0xFFFF : UInt16(truncatingIfNeeded: f >> 15)
            // 16 bits (15 bits + sign bit): 2^11*dfn
            opamp[j].dvx = Int16(truncatingIfNeeded: df >> (15 - 11))
            j += 1
        }
        while j < (1 << 16) {
            opamp[j].vx = 0
            opamp[j].dvx = 0
            j += 1
        }

        // We don't have the differential for the first point so just assume
        // it's the same as the second point's
        opamp[Int(mf_ak)].dvx = opamp[Int(mf_ak) + 1].dvx

        let op = UnsafePointer(opamp)

        // Create lookup tables.

        // The filter summer operates at n ~ 1, and has 5 fundamentally different
        // input configurations (2 - 6 input "resistors").
        //
        // Note that all "on" transistors are modeled as one. This is not
        // entirely accurate, since the input for each transistor is different,
        // and transistors are not linear components. However modeling all
        // transistors separately would be extremely costly.
        var offset = 0
        var size = 0
        for k in 0 ..< 5 {
            let idiv = 2 + k // 2 - 6 input "resistors".
            let n_idiv = Double(idiv)
            size = idiv << 16
            var x = mf_ak
            for vi in 0 ..< size {
                summer[offset + vi] =
                    UInt16(truncatingIfNeeded: solve_gain_d(op, n_idiv, Int32(vi / idiv), &x, mf_ak, mf_bk, mf_kVddt))
            }
            offset += size
        }

        // The audio mixer operates at n ~ 8/6 (6581) 8/5 (8580),
        // and has 8 fundamentally different
        // input configurations (0 - 7 input "resistors").
        //
        // All "on", transistors are modeled as one - see comments above for
        // the filter summer.
        var divider = m == 0 ? 6.0 : 5.0
        offset = 0
        size = 1 // Only one lookup element for 0 input "resistors".
        for l in 0 ..< 8 {
            var idiv = l // 0 - 7 input "resistors".
            let n_idiv = Double(idiv << 3) / divider // n*idiv
            if idiv == 0 {
                // Avoid division by zero; the result will be correct since
                // n_idiv = 0.
                idiv = 1
            }
            var x = mf_ak
            for vi in 0 ..< size {
                mixer[offset + vi] =
                    UInt16(truncatingIfNeeded: solve_gain_d(op, n_idiv, Int32(vi / idiv), &x, mf_ak, mf_bk, mf_kVddt))
            }
            offset += size
            size = (l + 1) << 16
        }

        // 4 bit "resistor" ladders in the audio
        // output gain necessitate 16 gain tables.
        // From die photographs of the volume "resistor" ladders
        // it follows that gain ~ vol/12 (6581) vol/16 (8580)
        // (assuming ideal op-amps and ideal "resistors").
        divider = m == 0 ? 12.0 : 16.0
        for n8 in 0 ..< 16 {
            let n = Double(n8) / divider
            var x = mf_ak
            for vi in 0 ..< (1 << 16) {
                gain[(n8 << 16) + vi] = UInt16(truncatingIfNeeded: solve_gain_d(op, n, Int32(vi), &x, mf_ak, mf_bk, mf_kVddt))
            }
        }

        // Create lookup table mapping capacitor voltage to op-amp input voltage:
        // vc -> vx
        for i in 0 ..< (1 << 16) {
            opamp_rev[i] = opamp[i].vx
        }

        vc_max = sid_int(N30 * (fi.opamp_voltage[0].1 - fi.opamp_voltage[0].0))
        vc_min = sid_int(N30 * (fi.opamp_voltage[opamp_voltage_size - 1].1 - fi.opamp_voltage[opamp_voltage_size - 1].0))

        if m == 0 {
            // 6581 only

            // In the MOS 6581, 1/Q is controlled linearly by res. From die photographs
            // of the resonance "resistor" ladder it follows that 1/Q ~ ~res/8
            // (assuming an ideal op-amp and ideal "resistors"). This implies that Q
            // ranges from 0.533 (res = 0) to 8 (res = E). For res = F, Q is actually
            // theoretically unlimited, which is quite unheard of in a filter
            // circuit.
            //
            // To obtain Q ~ 1/sqrt(2) = 0.707 for maximally flat frequency response,
            // res should be set to 4: Q = 8/~4 = 8/11 = 0.7272 (again assuming an ideal
            // op-amp and ideal "resistors").
            //
            // Q as low as 0.707 is not achievable because of low gain op-amps; res = 0
            // should yield the flattest possible frequency response at Q ~ 0.8 - 1.0
            // in the op-amp's pseudo-linear range (high amplitude signals will be
            // clipped). As resonance is increased, the filter must be clocked more
            // often to keep it stable.
            for n8 in 0 ..< 16 {
                let n = Double(~n8 & 0xF) / 8.0
                var x = mf_ak
                for vi in 0 ..< (1 << 16) {
                    resonance[(n8 << 16) + vi] = UInt16(truncatingIfNeeded: solve_gain_d(op, n, Int32(vi), &x, mf_ak, mf_bk, mf_kVddt))
                }
            }

            nVgt = 0 // Vw_bias = 0
            n_param = 0

            // Normalized snake current factor, 1 cycle at 1MHz.
            // Fit in 5 bits.
            n_snake = sid_int(fi.WL_snake * tmp_n_param + 0.5)

            // DAC table.
            sid_build_dac_table(f0_dac, dac_bits, fi.dac_2R_div_R, fi.dac_term)
            for n in 0 ..< (1 << dac_bits) {
                f0_dac[n] = sid_ushort(N16 * (fi.dac_zero + Double(f0_dac[n]) * fi.dac_scale / Double(1 << dac_bits) - vmin) + 0.5)
            }

            // VCR table.
            let k = fi.k
            let kVddt = N16 * (k * (fi.Vdd - fi.Vth))
            vmin *= N16

            for i in 0 ..< (1 << 16) {
                // The table index is right-shifted 16 times in order to fit in
                // 16 bits; the argument to sqrt is thus multiplied by (1 << 16).
                //
                // The returned value must be corrected for translation. Vg always
                // takes part in a subtraction as follows:
                //
                //   k*Vg - Vx = (k*Vg - t) - (Vx - t)
                //
                // I.e. k*Vg - t must be returned.
                let Vg = kVddt - (Double(i) * Double(1 << 16)).squareRoot()
                vcr_kVg[i] = sid_ushort(k * Vg - vmin + 0.5)
            }

            /*
               EKV model:

               Ids = Is*(if - ir)
               Is = ((2*u*Cox*Ut^2)/k)*W/L
               if = ln^2(1 + e^((k*(Vg - Vt) - Vs)/(2*Ut))
               ir = ln^2(1 + e^((k*(Vg - Vt) - Vd)/(2*Ut))
             */
            let kVt = fi.k * fi.Vth
            let Ut = fi.Ut
            let Is = ((2 * fi.uCox * Ut * Ut) / fi.k) * fi.WL_vcr
            // Normalized current factor for 1 cycle at 1MHz.
            let N15 = N16 / 2
            let n_Is = N15 * 1.0e-6 / fi.C * Is

            // kVg_Vx = k*Vg - Vx
            // I.e. if k != 1.0, Vg must be scaled accordingly.
            for i in 0 ..< (1 << 16) {
                let kVg_Vx = i - (1 << 15)
                let log_term = log1p(exp((Double(kVg_Vx) / N16 - kVt) / (2 * Ut)))
                // Scaled by m*2^15
                vcr_n_Ids_term[i] = sid_ushort(n_Is * log_term * log_term)
            }
        } else {
            // 8580 only

            // In the MOS 8580, the resonance "resistor" ladder above the bp feedback
            // op-amp is split in two parts; one ladder for the op-amp input and one
            // ladder for the op-amp feedback. See filter8580new.cc for the derivation
            // of the gains in resGain.
            for n8 in 0 ..< 16 {
                var x = mf_ak
                let n = resGain(n8)
                for vi in 0 ..< (1 << 16) {
                    resonance[(n8 << 16) + vi] = UInt16(truncatingIfNeeded: solve_gain_d(op, n, Int32(vi), &x, mf_ak, mf_bk, mf_kVddt))
                }
            }

            n_snake = 0

            // scaled 5 bits
            n_param = sid_int(tmp_n_param * 32 + 0.5)

            let Vgt = (Vref * 1.6) - fi.Vth
            nVgt = sid_int(N16 * (Vgt - vmin) + 0.5)

            // DAC table.
            // W/L ratio for frequency DAC, bits are proportional.
            // scaled 5 bits
            let dacWL: UInt32 = 806 // 0,00307464599609375 * 1024 * 256 (actual value is ~= 0.003075)
            f0_dac[0] = UInt16(dacWL >> 8)
            for n in 1 ..< (1 << dac_bits) {
                // Calculate W/L ratio for parallel NMOS resistances
                var wl: UInt32 = 0
                for i in 0 ..< dac_bits {
                    let bitmask = UInt32(1) << UInt32(i)
                    if (UInt32(n) & bitmask) != 0 {
                        wl &+= dacWL &* (bitmask << 1)
                    }
                }
                f0_dac[n] = UInt16(truncatingIfNeeded: wl >> 8)
            }
        }

        Self.fillMargins(opamp_rev, 1 << 16, margin: Self.opamp_rev_margin)
        Self.fillMargins(summer, Self.summer_size, margin: Self.summer_margin)
        Self.fillMargins(resonance, 16 << 16, margin: Self.resonance_margin)
        Self.fillMargins(vcr_n_Ids_term, 1 << 16, margin: Self.vcr_n_Ids_term_margin)
        // The summer margin assumes each voice is within 8192 of a 16-bit voice_DC.
        precondition(voice_DC >= 0 && voice_DC < (1 << 16))
    }
}
