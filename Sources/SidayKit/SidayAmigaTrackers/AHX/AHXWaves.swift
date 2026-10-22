// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ahx2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// The waves every AHX tune is made of, which the tracker works out as it starts and no file holds.
///
/// There is one set of plain waves: a triangle and a sawtooth in each of six lengths, from 4 bytes
/// to 128; thirty-two square waves of 128 bytes, from the narrowest pulse to an even square; and a
/// stretch of noise. And there are sixty-two more sets, which are the plain one put through a
/// filter: thirty-one low-passed, the first of them the dullest, and thirty-one high-passed. That is
/// all there is to AHX's filter. An instrument that sweeps it is only choosing, from one moment to
/// the next, which set its wave is copied from.
///
/// They are made in whole numbers, exactly as the tracker made them on the Amiga.
final class AHXWaves {
    static let noiseLength = 0x280 * 3
    /// How long one set is, and where in it each kind of wave begins.
    static let setLength = 252 + 252 + 0x80 * 32 + noiseLength
    static let triangles = 0, sawtooths = 252, squares = 504, noise = 504 + 0x80 * 32
    /// Where the triangle or sawtooth of each length begins, among those of its kind.
    static let offsets: [Int] = [0x00, 0x04, 0x04 + 0x08, 0x04 + 0x08 + 0x10, 0x04 + 0x08 + 0x10 + 0x20, 0x04 + 0x08 + 0x10 + 0x20 + 0x40]
    /// The sets in order: the low-passed ones, the plain one, the high-passed ones. A filter's
    /// setting runs from 1 to 63, and 32 is no filter: so the set for a setting is the one before it.
    static let sets = 63
    static let plain = 31 * setLength

    let samples: UnsafeMutablePointer<Int8>

    deinit {
        samples.deallocate()
    }

    /// Keeps a number of sixteen bits either side of its point within what a byte can hold.
    @inline(__always) private static func clipped(_ value: Int32) -> Int32 {
        let whole = Int16(truncatingIfNeeded: value >> 16)
        if whole > 127 { return 127 << 16 }
        if whole < -128 { return -128 << 16 }
        return value
    }

    init() {
        samples = .allocate(capacity: Self.sets * Self.setLength)
        samples.initialize(repeating: 0, count: Self.sets * Self.setLength)

        // Triangles: up a quarter of the way round, down the next, and then the same upside down.
        var at = Self.plain + Self.triangles
        for size in 0 ..< 6 {
            let whole = 4 << size, quarter = whole >> 2, step = 128 / quarter
            for i in 0 ..< quarter { samples[at + i] = Int8(truncatingIfNeeded: i * step) }
            samples[at + quarter] = 127
            for i in 1 ..< quarter { samples[at + quarter + i] = Int8(truncatingIfNeeded: 128 - i * step) }
            for i in 0 ..< whole / 2 {
                let sample = samples[at + i]
                samples[at + whole / 2 + i] = sample == 127 ? -128 : 0 &- sample
            }
            at += whole
        }

        // Sawtooths, climbing by as much each byte as a byte's range divides into.
        at = Self.plain + Self.sawtooths
        for size in 0 ..< 6 {
            let length = 4 << size
            let step = Int8(truncatingIfNeeded: 256 / (length - 1))
            var sample: Int8 = -128
            for i in 0 ..< length {
                samples[at + i] = sample
                sample &+= step
            }
            at += length
        }

        // Squares: low, and then high for one part in 64 of the way round, for two, and so on to half.
        at = Self.plain + Self.squares
        for width in 1 ... 32 {
            for i in 0 ..< 0x80 { samples[at + i] = i < (64 - width) * 2 ? -128 : 127 }
            at += 0x80
        }

        // Noise, from a number that is stirred after every byte.
        at = Self.plain + Self.noise
        var seed: UInt32 = 0x4159_5321
        for i in 0 ..< Self.noiseLength {
            if seed & 256 == 0 {
                samples[at + i] = Int8(truncatingIfNeeded: seed)
            } else {
                samples[at + i] = seed & 0x8000 != 0 ? -128 : 127
            }
            seed = (seed >> 5) | (seed << 27)
            seed ^= 0b1001_1010
            var sum = UInt16(truncatingIfNeeded: seed)
            seed = (seed << 2) | (seed >> 30)
            sum &+= UInt16(truncatingIfNeeded: seed)
            seed ^= UInt32(sum)
            seed = (seed >> 3) | (seed << 29)
        }

        // The filtered sets. Each wave goes round the filter three times to settle it, and what
        // comes out the fourth time is kept: what the filter lets through, and what is left of the
        // wave when that is taken away.
        var lengths: [Int] = []
        for _ in 0 ..< 2 { for size in 0 ..< 6 { lengths.append(4 << size) } }
        lengths += [Int](repeating: 0x80, count: 32)
        lengths.append(Self.noiseLength)

        var low = 0, high = Self.plain + Self.setLength
        var frequency: Int32 = 25
        for _ in 0 ..< 31 {
            var source = Self.plain
            for length in lengths {
                var band: Int32 = 0, lowPassed: Int32 = 0
                for turn in 0 ..< 4 {
                    if turn == 3 {
                        // (The Amiga's player looked these up in a table that kept fewer bits.)
                        band &= ~0xFF
                        lowPassed &= ~0xFF
                    }
                    for i in 0 ..< length {
                        let input = Int32(samples[source + i]) << 16
                        let highPassed = Self.clipped(input &- band &- lowPassed)
                        band = Self.clipped(band &+ (highPassed >> 8) &* frequency)
                        lowPassed = Self.clipped(lowPassed &+ (band >> 8) &* frequency)
                        if turn == 3 {
                            samples[high + i] = Int8(truncatingIfNeeded: highPassed >> 16)
                            samples[low + i] = Int8(truncatingIfNeeded: lowPassed >> 16)
                        }
                    }
                }
                source += length
                low += length
                high += length
            }
            frequency += 9
        }
    }
}
