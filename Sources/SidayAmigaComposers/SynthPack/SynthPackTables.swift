// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The tables of Wanted Team's player of Karsten Obarski's Synth Pack ("Synth Pack player module V1.1 (20 Jun
// 2000)", carried by UADE as players/SynthPack): each worked out as the player has it, but for its two of
// noise, which are its bytes (see THIRD-PARTY.md).

import SidayFoundation

extension SynthPackPlayer {
    /// The shapes the player's effects follow: each made as it is in the player's hunk, checked byte for byte
    /// against it.
    enum Tables {
        /// Dyter-07's routine's six tables of how far a tremolo turns the volume down (`$127E`, 32 words each):
        /// up from nought by 16 to 240, twice; down, twice; up and down; and three of nought.
        static let tremolos: [[UInt16]] = {
            let up = (0 ..< 16).map { UInt16(16 * $0) }, down = (0 ..< 16).map { UInt16(240 - 16 * $0) }
            let none = [UInt16](repeating: 0, count: 32)
            return [up + up, down + down, up + down, none, none, none]
        }()

        /// Dyter-07's routine's six tables of how far a vibrato moves the period (`$13FE`, 32 words each, a
        /// signed byte in each low byte): a saw up from -121 by eight, and down from 127; from -128 up by 16
        /// and from 124 down; a sine; a square; and noise.
        static let vibratos: [[Int8]] = [
            (0 ..< 32).map { Int8(-121 + 8 * $0) },
            (0 ..< 32).map { Int8(127 - 8 * $0) },
            (0 ..< 16).map { Int8(-128 + 16 * $0) } + (0 ..< 16).map { Int8(124 - 16 * $0) },
            sine(32),
            [Int8](repeating: 127, count: 16) + [Int8](repeating: -128, count: 16),
            noise32.map { Int8(bitPattern: $0) },
        ]

        /// Centerbase's routine's six waveforms of 128 bytes (`L228a`), for its tremolos, vibratos and its
        /// waveforms' sweeps: a saw up from -127 by two, and down from 127; a triangle by four, down from 127
        /// and back; a sine; a square; and noise.
        static let waves: [[Int8]] = [
            (0 ..< 128).map { Int8(-127 + 2 * $0) },
            (0 ..< 128).map { Int8(127 - 2 * $0) },
            (0 ..< 32).map { Int8(127 - 4 * $0) } + (0 ..< 32).map { Int8(-1 - 4 * $0) }
                + (0 ..< 32).map { Int8(-125 + 4 * $0) } + (0 ..< 32).map { Int8(3 + 4 * $0) },
            sine(128),
            [Int8](repeating: -127, count: 64) + [Int8](repeating: 127, count: 64),
            noise128.map { Int8(bitPattern: $0) },
        ]

        /// A sine of `count` steps, 128 times the sine below the next whole number, and no more than 127, as the
        /// player's two are.
        static func sine(_ count: Int) -> [Int8] {
            (0 ..< count).map { i in
                let value = 128 * sin(2 * Double.pi * Double(i) / Double(count))
                var whole = Int(value)
                if Double(whole) > value { whole -= 1 }
                return Int8(min(127, whole))
            }
        }

        /// The player's noise of Dyter-07's routine's vibratos (the low bytes of the words at `$153E` of its
        /// hunk) and of Centerbase's routine's waveforms (`$250A`).
        static let noise32: [UInt8] = [
            0xA7, 0x85, 0xC6, 0x3C, 0x37, 0xE7, 0xA5, 0x5A, 0xA1, 0xE1, 0xE3, 0xA0, 0x5A, 0x76, 0x36, 0xF1,
            0x72, 0x58, 0x84, 0xDD, 0xC2, 0x85, 0x74, 0x8F, 0xCF, 0xCD, 0x8E, 0x74, 0x58, 0xD1, 0xFF, 0x98,
        ]
        static let noise128: [UInt8] = [
            0x8A, 0x0B, 0xDE, 0x9F, 0x0D, 0xEF, 0xA1, 0x3E, 0x32, 0x6E, 0xC3, 0xDB, 0xB3, 0x0A, 0x2F, 0x59,
            0x9F, 0xAD, 0x2E, 0xFD, 0xC2, 0x53, 0xB2, 0xFE, 0x63, 0x69, 0x30, 0x9A, 0x8C, 0xEA, 0x5D, 0x7E,
            0x0B, 0xCE, 0xFE, 0x7F, 0xAE, 0x93, 0x1D, 0xC3, 0x89, 0x12, 0x1B, 0x43, 0xEA, 0xFE, 0x9A, 0x2F,
            0x0E, 0x7C, 0xBE, 0x90, 0xEF, 0x20, 0x1B, 0x96, 0x4B, 0x03, 0x9A, 0x9D, 0xC8, 0x6E, 0x7C, 0x1E,
            0xAD, 0xB2, 0xC3, 0x02, 0x2E, 0x53, 0x9E, 0xA7, 0x2D, 0xF7, 0xB1, 0x26, 0x23, 0x77, 0xD2, 0xC2,
            0xA2, 0x13, 0x0E, 0x60, 0xDE, 0xF4, 0x8F, 0x44, 0x73, 0xFA, 0x23, 0x67, 0xF2, 0xF0, 0xA1, 0x03,
            0x0D, 0x53, 0xFC, 0xE7, 0x8A, 0x37, 0x1F, 0x66, 0xAF, 0x9A, 0x1C, 0xCA, 0x88, 0x1B, 0x1B, 0x4B,
            0xEA, 0xE6, 0xBA, 0x17, 0x0E, 0x67, 0xDD, 0xFB, 0x8C, 0x4B, 0x78, 0xFD, 0x28, 0x68, 0xF9, 0x18,
        ]
    }
}
