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

/// Channels left out of the sound (`setMuted`, which is not in the original) are left out where
/// the chip adds its channels up, and go on being worked through.
@Test func oplChannelsLeftOutAndChannelsHeardAddUpToTheWhole() {
    // Three chips given the same writes, as in the test above, to all of the OPL3's registers: one
    // with every channel heard, one with some left out, and one with only those heard. What the
    // two make between them is what the whole chip makes, on each of its four outputs, wherever
    // neither has run out of room; and each says the same of how far every channel has swung.
    var seed: UInt32 = 0x51DA4
    func next() -> UInt32 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return seed >> 8
    }
    let some: UInt32 = 0b10_1100_1011_0101_0110
    var whole = OPL3Chip(), without = OPL3Chip(), only = OPL3Chip()
    without.setMuted(some)
    only.setMuted(~some)
    var compared = 0, differing = 0, heard = 0
    for sample in 0 ..< 120_000 {
        if next() & 31 == 0 {
            let reg = UInt16(next() & 0x1FF)
            let value = UInt8(next() & 0xFF)
            let later = next() & 1 != 0
            if later {
                whole.OPL3_WriteRegBuffered(reg, value)
                without.OPL3_WriteRegBuffered(reg, value)
                only.OPL3_WriteRegBuffered(reg, value)
            } else {
                whole.OPL3_WriteReg(reg, value)
                without.OPL3_WriteReg(reg, value)
                only.OPL3_WriteReg(reg, value)
            }
        }
        let all = whole.OPL3_Generate4Ch(), first = without.OPL3_Generate4Ch(), second = only.OPL3_Generate4Ch()
        for (sum, a, b) in [(all.0, first.0, second.0), (all.1, first.1, second.1), (all.2, first.2, second.2), (all.3, first.3, second.3)] {
            guard abs(Int(a)) < 32767, abs(Int(b)) < 32767 else { continue }
            compared += 1
            if Int(sum) != max(-32768, min(32767, Int(a) + Int(b))) { differing += 1 }
            if a != 0, b != 0 { heard += 1 }
        }
        if sample % 4096 == 4095 {
            var levels = [[Float]](repeating: [Float](repeating: -1, count: 18), count: 3)
            levels[0].withUnsafeMutableBufferPointer { whole.takeLevels(into: $0.baseAddress!, count: 18) }
            levels[1].withUnsafeMutableBufferPointer { without.takeLevels(into: $0.baseAddress!, count: 18) }
            levels[2].withUnsafeMutableBufferPointer { only.takeLevels(into: $0.baseAddress!, count: 18) }
            if levels[0] != levels[1] || levels[0] != levels[2] { differing += 1 }
        }
    }
    #expect(differing == 0)
    // (Most of it was compared, and for much of it both halves had something to say.)
    #expect(compared > 400_000 && heard > 50000)

    // Every channel left out is silence.
    var silent = OPL3Chip()
    silent.setMuted(0x3FFFF)
    var loud = 0
    seed = 0x51DA4
    for _ in 0 ..< 20000 {
        if next() & 31 == 0 { silent.OPL3_WriteReg(UInt16(next() & 0x1FF), UInt8(next() & 0xFF)) }
        let made = silent.OPL3_Generate4Ch()
        if made.0 != 0 || made.1 != 0 || made.2 != 0 || made.3 != 0 { loud += 1 }
    }
    #expect(loud == 0)
}
