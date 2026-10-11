// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// what its copies of the DirectX effects share (`soundlib/plugins/dmo/DMOUtils.cpp`), and the few
// conversions of its own that they lean on (`src/mpt/base/math.hpp`, `src/mpt/base/saturate_round.hpp`).

/// What the effects OpenMPT copied from DirectX have in common. The DirectX effects were written in
/// whole numbers, and where OpenMPT kept their arithmetic it is kept here too, bit for bit.
enum OpenMPTDMO {
    /// The circle's constant and the natural logarithm of two as C++ has them in single precision,
    /// which is rounded to the nearest: Swift's own `Float.pi` is rounded down, and is one step less.
    static let pi: Float = 3.14159265358979323846
    static let ln2: Float = 0.693147180559945309417

    /// A setting as an effect takes it: what is not a number is nought, and the rest is held between
    /// nought and one (OpenMPT's `safe_clamp`).
    @inline(__always) static func unit(_ value: Float) -> Float {
        if value.isNaN { return 0 }
        return value < 0 ? 0 : (value > 1 ? 1 : value)
    }

    /// A number rounded to the nearest whole one, halves away from nought, and held to what 32 bits
    /// without a sign can hold (OpenMPT's `saturate_round`). What is not a number comes out as nought.
    static func saturateRound(_ value: Float) -> UInt32 {
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        if rounded >= 4_294_967_296.0 { return .max }
        if rounded >= 1 { return UInt32(rounded) }
        return 0
    }

    /// A number cut to a whole one of 32 bits without a sign, as a C cast does it on the processors
    /// this was proved on: too large is the largest, and negative or not a number is nought.
    @inline(__always) static func truncate(_ value: Float) -> UInt32 {
        if value >= 4_294_967_296.0 { return .max }
        if value >= 1 { return UInt32(value) }
        return 0
    }

    /// A sample put on a scale of loudness, roughly its logarithm to the base two, with its sign kept:
    /// in OpenMPT's words (log2(x) + 1) * 2 ^ (shiftL - shiftR), for x from -2^31 to 2^31. The sample
    /// is doubled until its top bit is set, or `shiftL` times if that comes first, and how many
    /// doublings were left over goes above what remains of it.
    ///
    /// OpenMPT doubles in a loop; counting the leading zeros gets the same number at once. A sample
    /// of exactly 2^31, or one that is not a number, is cast by C in a way the language leaves open:
    /// this does what an ARM processor does (the largest whole number, and nought), where an Intel one
    /// would make both the most negative number.
    @inline(__always) static func logGain(_ x: Float, _ shiftL: Int32, _ shiftR: Int32) -> Float {
        var intSample: UInt32
        if x <= -2_147_483_648.0 || x > 2_147_483_648.0 {
            intSample = 0x8000_0000
        } else if x < 2_147_483_648.0 {
            intSample = UInt32(bitPattern: Int32(x))
        } else if x == 2_147_483_648.0 {
            intSample = 0x7FFF_FFFF
        } else {
            intSample = 0
        }

        let sign = intSample & 0x8000_0000
        if sign != 0 { intSample = ~intSample &+ 1 }

        // Multiply until overflow (or edge shift factor is reached)
        var shiftL = shiftL
        let doublings = min(shiftL, Int32(truncatingIfNeeded: intSample.leadingZeroBitCount))
        if doublings > 0 {
            intSample = intSample &<< UInt32(truncatingIfNeeded: doublings)
            shiftL -= doublings
        }
        // Unsign clipped sample
        if intSample >= 0x8000_0000 {
            intSample &= 0x7FFF_FFFF
            shiftL += 1
        }
        intSample = (UInt32(bitPattern: shiftL) &<< UInt32(truncatingIfNeeded: 31 - shiftR)) | (intSample &>> UInt32(truncatingIfNeeded: shiftR))
        if sign != 0 { intSample = ~intSample | sign }
        return Float(Int32(bitPattern: intSample))
    }
}
