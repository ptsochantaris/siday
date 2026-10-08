// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// The OPL3 is a port of Nuked OPL3, and is to give the numbers that gives.

/// The chip while registers picked at random are set to values picked at random, some at once and
/// some in their turn, and a hash of what it plays.
/// - Parameters:
///   - samples: how many samples to make.
///   - often: a write is made before one sample in this many, less one.
///   - registers: the bits of a register's number that are used: 0xFF keeps to the OPL2's.
private func fuzzed(samples: Int, often: UInt32, registers: UInt32) -> (hash: UInt64, loud: Int) {
    var seed: UInt32 = 0x51DA4
    func next() -> UInt32 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return seed >> 8
    }
    var chip = OPL3Chip()
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    var loud = 0
    for _ in 0 ..< samples {
        if next() & often == 0 {
            let reg = UInt16(next() & registers)
            let value = UInt8(next() & 0xFF)
            if next() & 1 != 0 { chip.OPL3_WriteRegBuffered(reg, value) } else { chip.OPL3_WriteReg(reg, value) }
        }
        let made = chip.OPL3_Generate4Ch()
        for sample in [made.0, made.1, made.2, made.3] {
            hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: sample))) &* 0x100_0000_01B3
            hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: sample >> 8))) &* 0x100_0000_01B3
            if sample > 256 || sample < -256 { loud += 1 }
        }
    }
    return (hash, loud)
}

/// Every waveform, the drums, channels of four operators and both of the chip's ways of behaving
/// come up in these. The hashes are of what Nuked OPL3 1.8 itself plays, given the same writes.
@Test func oplChipPlaysWhatNukedOPL3Plays() {
    // Writes thick and fast, to all of the OPL3's registers.
    let busy = fuzzed(samples: 300_000, often: 7, registers: 0x1FF)
    #expect(busy.loud == 417_522)
    #expect(busy.hash == 0x0A8B_D59C_B287_AC34)
    // Fewer, to the OPL2's alone, so that notes last and envelopes run their course.
    let steady = fuzzed(samples: 200_000, often: 31, registers: 0xFF)
    #expect(steady.loud == 108_288)
    #expect(steady.hash == 0xBA8F_4AAA_DAD9_E507)
    let slow = fuzzed(samples: 200_000, often: 127, registers: 0xFF)
    #expect(slow.loud == 116_896)
    #expect(slow.hash == 0x549B_B55D_1F9C_4CF8)
}
