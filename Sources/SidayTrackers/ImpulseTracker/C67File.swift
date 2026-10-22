// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the C67 loader of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

import SidayFoundation

/// A C67 file, the module of Composer 670 (CDFM), which is Composer 669 with an AdLib card beside
/// its samples: four channels of samples and nine of the card's FM voices.
///
/// It has no commands at all. A pattern is a list of notes, each with an instrument and a volume,
/// of volumes alone, and of how many rows to wait before the next of them; a tune has a speed, and
/// nothing changes it. So there is nothing in it that Impulse Tracker's replayer does not have,
/// and that replayer plays it, with the FM chip played as OpenMPT plays it (`OpenMPTAdLib`): which
/// is how OpenMPT plays these files, and it is the only other player of them that there is. The
/// pitches, the tempo, the volumes and how loud the chip is beside the samples are OpenMPT's. See
/// `IT2ForeignModule`.
enum C67File {
    private static let header = 1954, patternsAt = 2978
    private static let noLoop = 0xFFFFF

    /// The chip's volumes: Composer 670 counted them evenly, and the chip does not.
    private static let fmVolumes: [UInt8] = [0x08, 0x10, 0x18, 0x20, 0x28, 0x2C, 0x30, 0x34, 0x36, 0x38, 0x3A, 0x3C, 0x3D, 0x3E, 0x3F, 0x40]

    /// Four bytes as a place or a length, the first the least; one too large to be either is
    /// brought down to where it is still neither. (A whole number in a browser has 32 bits.)
    private static func long(_ f: ByteReader, _ i: Int) -> Int {
        let high = f.u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16le(i)
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        let f = ByteReader(data)
        func refuse() -> TuneError { TuneError.malformed("not a C67 file") }
        // A file has nothing to be known by but that everything in it is what it could be. These
        // are OpenMPT's checks.
        guard data.count >= patternsAt, data[0] >= 1, data[0] <= 15 else { throw refuse() }
        var anything = false
        for i in 0 ..< 32 {
            let sample = 418 + i * 16, patch = 1346 + i * 11
            let length = long(f, sample + 4), loopStart = long(f, sample + 8), loopEnd = long(f, sample + 12)
            guard data[2 + i * 13 + 12] == 0, data[930 + i * 13 + 12] == 0, long(f, sample) == 0, length <= 0xFFFFF,
                  data[patch] & 0xF0 == 0, data[patch + 5] & 0xFC == 0, data[patch + 10] & 0xFC == 0
            else { throw refuse() }
            if length != 0, loopEnd < noLoop, loopEnd > length || loopStart > loopEnd { throw refuse() }
            if length != 0 || data[patch ..< patch + 11].contains(where: { $0 != 0 }) { anything = true }
        }
        guard anything, data[1698 ..< 1954].allSatisfy({ $0 < 128 || $0 == 0xFF }) else { throw refuse() }
        var soundAt = patternsAt
        for pattern in 0 ..< 128 {
            let at = long(f, header + pattern * 4), length = long(f, header + 512 + pattern * 4)
            guard at <= 0xFFFFFF, length >= 3, length <= 0x1000, data.count >= patternsAt + at + length else { throw refuse() }
            soundAt = max(soundAt, patternsAt + at + length)
        }

        // The patterns: a list of things to do, with how many rows to move on between them.
        var patterns = [[UInt8]?](repeating: nil, count: IT2ForeignModule.patternRoom)
        var rows = [UInt16](repeating: 64, count: IT2ForeignModule.patternRoom)
        func volume(_ value: UInt8, fm: Bool) -> UInt8 { fm ? fmVolumes[Int(value & 15)] : 4 + (value & 15) * 4 }
        for index in 0 ..< 128 {
            var pattern = IT2ForeignModule.Pattern()
            var at = patternsAt + long(f, header + index * 4)
            let end = at + long(f, header + 512 + index * 4)
            var row = 0
            while row < 64, at < end {
                let command = data[at]
                at += 1
                if command <= 0x0C {
                    // A note: its octave and its place in it, an instrument, and a volume.
                    let channel = Int(command), fm = channel >= 4
                    let note = f[at], instrumentAndVolume = f[at + 1]
                    at += 2
                    var cell = pattern[row, channel]
                    cell.set(note: (fm ? 12 : 36) + (note & 0x0F) + ((note >> 4) & 7) * 12)
                    cell.set(instrument: (fm ? 33 : 1) + (instrumentAndVolume >> 4) + ((note & 0x80) >> 3))
                    cell.set(volume: volume(instrumentAndVolume, fm: fm))
                    pattern[row, channel] = cell
                } else if command >= 0x20, command <= 0x2C {
                    let channel = Int(command - 0x20)
                    var cell = pattern[row, channel]
                    cell.set(volume: volume(f[at], fm: channel >= 4))
                    pattern[row, channel] = cell
                    at += 1
                } else if command == 0x40 {
                    row += Int(f[at])
                    at += 1
                } else if command == 0x60 {
                    // The end of the pattern, which is as long as it has come to.
                    if row > 0 { rows[index] = UInt16(min(row, 64)) }
                    break
                } else {
                    throw refuse()
                }
            }
            if rows[index] < 64 {
                var short = IT2ForeignModule.Pattern(rows: Int(rows[index]))
                for row in 0 ..< short.rows {
                    for channel in 0 ..< 13 { short[row, channel] = pattern[row, channel] }
                }
                pattern = short
            }
            patterns[index] = pattern.packed()
        }

        // The samples, eight bits without a sign, one after another where the patterns end; and
        // after them in Impulse Tracker's list, the patches for the FM chip.
        var samples: [IT2Sample] = []
        var cutShort = Shortfall.CutShort()
        for i in 0 ..< 32 {
            let at = 418 + i * 16
            let length = long(f, at + 4), loopStart = long(f, at + 8), loopEnd = long(f, at + 12)
            let there = max(0, min(length, data.count - soundAt))
            if length > 0 { cutShort.add(length: length, there: data.count - soundAt) }
            var sound = [Int8](repeating: 0, count: length)
            for j in 0 ..< there { sound[j] = Int8(bitPattern: data[soundAt + j] ^ 0x80) }
            soundAt += length
            samples.append(IT2ForeignModule.sample(sound8: sound, volume: 64, rate: IT2ForeignModule.rate(8287), loops: loopEnd <= length,
                                                   loopStart: loopStart, loopEnd: loopEnd))
        }
        for i in 0 ..< 32 {
            // Eleven bytes, the two operators one after the other: here a byte of one and then of
            // the other, as OpenMPT keeps a patch, and the byte they share last.
            let fm = Array(data[1346 + i * 11 ..< 1346 + i * 11 + 11])
            let s = IT2Sample()
            s.GlobVol = 64
            s.Vol = 64
            s.C5Speed = 8363
            if fm.contains(where: { $0 != 0 }) {
                s.Cvt = IT2Module.adLibPatch
                s.Length = 4
                s.Flags = SMPF_ASSOCIATED_WITH_HEADER
                s.AdLib = [fm[1], fm[6], fm[2], fm[7], fm[3], fm[8], fm[4], fm[9], fm[5], fm[10], fm[0], 0]
            }
            samples.append(s)
        }
        while samples.count < IT2Module.MAX_SAMPLES { samples.append(IT2Sample()) }

        // The samples' channels are to the left and the right by turns, and the chip's in the middle.
        var pans = [UInt8](repeating: 32 | 128, count: MAX_HOST_CHANNELS)
        for channel in 0 ..< 13 { pans[channel] = channel >= 4 ? 32 : channel & 1 != 0 ? 48 : 16 }

        var sound = ModPlugSound()
        sound.adLib = OpenMPTAdLib.Behaviour()
        sound.adLibLevel = ModPlugSound.adLibLevel(synthVolume: Int(synthVolume))
        let orders = Array(data[1698 ..< 1954])
        let module = IT2Module(title: "", madeWith: "Composer 670", orders: orders, flags: IT2ForeignModule.flags | ITF_LINEAR_FRQ,
                               globalVolume: 128, mixVolume: mixVolume, speed: data[0], tempo: 143, channelPans: pans, samples: samples,
                               patterns: patterns, rows: rows, restart: Int(data[1]), sound: sound)
        return ITRenderer(module: module, format: "C67", shortfalls: cutShort.sentence.map { [$0] } ?? [], options: options)
    }

    /// How loud the samples and the chip are made. OpenMPT has each at 48 for a file it has just
    /// read; these are less by the same part, set by measure, so that these files are about as
    /// loud as XM files are and the two stay to each other as OpenMPT has them.
    /// (Since 2026-10-16 by how loud the tunes are heard, LUFS.)
    private static let mixVolume: UInt8 = 34, synthVolume: UInt8 = 34
}
