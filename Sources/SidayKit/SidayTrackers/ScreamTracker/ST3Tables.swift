// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// These tables are from st3play by Olav Sørensen (BSD 3-Clause; see THIRD-PARTY.md). The small ones
// are Scream Tracker 3.21's own, with what it read past the ends of them.

/// How much the multi-retrigger adds to a volume, and (from the 23rd entry) what sixteenths of it it takes.
let st3RetrigVolAdd: [Int8] = [
    0, -1, -2, -4, -8, -16, 0, 0, 0, 1, 2, 4, 8, 16, 0, 0,
    0, 0, 0, 0, 0, 0, 10, 8, 0, 0, 0, 0, 0, 0, 24, 32,
]

/// How far a note's period is shifted down for its octave.
let st3OctaveDiv: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 0, 5, 11, 17, 27, 32, 42, 47]

/// The rates the sixteen fine tunings of a MOD file's samples stand for.
let st3FineTuneAmiga: [UInt16] = [8363, 8413, 8463, 8529, 8581, 8651, 8723, 8757, 7895, 7941, 7985, 8046, 8107, 8169, 8232, 8280]

/// The periods of the twelve notes of the lowest octave, and of the C above them.
let st3NoteSpd: [Int16] = [27392, 25856, 24384, 23040, 21696, 20480, 19328, 18240, 17216, 16256, 15360, 14512, 13696, 0x0100, 0x0802, 0x0A09]

/// A sine wave, a square wave and a ramp, for vibrato and tremolo.
let st3VibSin: [Int16] = [
    0x00, 0x18, 0x31, 0x4A, 0x61, 0x78, 0x8D, 0xA1, 0xB4, 0xC5, 0xD4, 0xE0, 0xEB, 0xF4, 0xFA, 0xFD,
    0xFF, 0xFD, 0xFA, 0xF4, 0xEB, 0xE0, 0xD4, 0xC5, 0xB4, 0xA1, 0x8D, 0x78, 0x61, 0x4A, 0x31, 0x18,
    0x00, -0x18, -0x31, -0x4A, -0x61, -0x78, -0x8D, -0xA1, -0xB4, -0xC5, -0xD4, -0xE0, -0xEB, -0xF4, -0xFA, -0xFD,
    -0xFF, -0xFD, -0xFA, -0xF4, -0xEB, -0xE0, -0xD4, -0xC5, -0xB4, -0xA1, -0x8D, -0x78, -0x61, -0x4A, -0x31, -0x18,
]
let st3VibSqu: [UInt8] = [UInt8](repeating: 0xFF, count: 32) + [UInt8](repeating: 0, count: 32)
let st3VibRamp: [Int16] = [0] + (1 ..< 32).map { Int16(-256 + $0 * 8) } + (0 ..< 32).map { Int16($0 * 8) }
