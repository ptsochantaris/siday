// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the GDM loaders of libxmp, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito
// Carraro Jr, used under the MIT licence, and of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project
// Developers and Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD
// 3-Clause licence (see THIRD-PARTY.md); and from MenTaLguY's description of the format.

/// A GDM file: "General Digital Music", the one kind of module that BWSB played.
///
/// BWSB was a sound system that DOS programs were built with, games most of all. It had one format
/// of its own, and a converter, 2GDM, that made a file of it from a module of some tracker's: a MOD,
/// an S3M, a 669, an MTM, a FAR, an STM, a MED or one of UltraTracker's. Nobody composed in it. So a GDM file is
/// another tracker's tune written down again: up to 32 channels, each at one of sixteen places
/// between the speakers, samples with a rate for C-4 as Scream Tracker's have, and for every note up
/// to four commands at once, which are ProTracker's by number with Scream Tracker's added after them.
///
/// It is played here by Impulse Tracker's replayer, and not by BWSB's own, which is not ported; and
/// it is played as the tracker it was written in is taken to have meant it, where the two differ and
/// the file says which that was. See `IT2ForeignModule`.
///
/// What Impulse Tracker cannot do is left out: sliding by semitones (E3x), retuning a sample in the
/// middle of a tune (E5x), and all of BWSB's "sample control" but surround. It has one command for a
/// note where a GDM file can have four, with a volume beside it and whatever else its volume column
/// can do; what is over is left out too.
enum GDMFile {
    /// What 2GDM says a file was made from, by the number it gives.
    private static let origins = ["", "MOD", "MTM", "S3M", "669", "FAR", "ULT", "STM", "MED", "PSM"]
    private static let s3m = 3

    private typealias Command = IT2ForeignModule.Command

    /// Four bytes as a place in the file or a length, the first the least. One too large to be either
    /// is brought down to where it is still neither. (A whole number in a browser has 32 bits.)
    private static func long(_ f: ByteReader, _ i: Int) -> Int {
        let high = f.u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16le(i)
    }

    /// True for a file that says it is one of these.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count > 0x4B && data.starts(with: [0x47, 0x44, 0x4D, 0xFE]) && data[71 ..< 75].elementsEqual([0x47, 0x4D, 0x46, 0x53])
    }

    /// One channel's part of a row, as the file has it: a note of nought is none, and so is a command.
    private struct Cell {
        var used = false
        var note: UInt8 = 0, instrument: UInt8 = 0
        var effects = InlineArray<4, UInt8>(repeating: 0), values = InlineArray<4, UInt8>(repeating: 0)
    }

    /// What a command of the file's is here.
    private enum Meaning {
        case nothing
        case volume(UInt8)
        /// One of sixteen places between the speakers.
        case pan(UInt8)
        case command(UInt8, UInt8)
        /// The note is not to be heard at all.
        case cut
    }

    /// A command of the file's as Impulse Tracker has it.
    /// - Parameter fromS3M: true if the tune was written in Scream Tracker, whose commands remember
    ///   their last value when they are given nought; ProTracker's slides, given nought, do nothing.
    private static func meaning(_ effect: UInt8, _ value: UInt8, fromS3M: Bool) -> Meaning {
        let high = value >> 4, low = value & 15
        switch effect {
        // (A slide as fast as 0xE0 would be read as a fine one.)
        case 0x01: return value == 0 && !fromS3M ? .nothing : .command(Command.F, min(value, 0xDF))
        case 0x02: return value == 0 && !fromS3M ? .nothing : .command(Command.E, min(value, 0xDF))
        case 0x03: return .command(Command.G, value)
        case 0x04: return .command(Command.H, value)
        case 0x05:
            if value == 0, !fromS3M { return .command(Command.G, 0) }
            return .command(Command.L, IT2ForeignModule.volumeSlide(value, upWins: !fromS3M))
        case 0x06:
            if value == 0, !fromS3M { return .command(Command.H, 0) }
            return .command(Command.K, IT2ForeignModule.volumeSlide(value, upWins: !fromS3M))
        case 0x07: return .command(Command.R, value)
        case 0x08: return .command(Command.I, value)
        case 0x09: return .command(Command.O, value)
        case 0x0A: return value == 0 && !fromS3M ? .nothing : .command(Command.D, IT2ForeignModule.volumeSlide(value, upWins: !fromS3M))
        case 0x0B: return .command(Command.B, value)
        case 0x0C: return .volume(min(value, 64))
        case 0x0D:
            // The row to go to, written as ProTracker and Scream Tracker write it: in tens and units.
            return .command(Command.C, high <= 9 && low <= 9 ? high * 10 + low : value)
        case 0x0E:
            switch high {
            case 0x1: return low == 0 ? .nothing : .command(Command.F, 0xF0 | low)
            case 0x2: return low == 0 ? .nothing : .command(Command.E, 0xF0 | low)
            case 0x4: return .command(Command.S, 0x30 | low)
            case 0x6: return .command(Command.S, 0xB0 | low)
            case 0x7: return .command(Command.S, 0x40 | low)
            case 0x8: return low == 0 ? .nothing : .command(Command.F, 0xE0 | low)
            case 0x9: return low == 0 ? .nothing : .command(Command.E, 0xE0 | low)
            case 0xA: return low == 0 ? .nothing : .command(Command.D, low << 4 | 0x0F)
            // (Down by fifteen, which would be read as up by fifteen, is down by fourteen.)
            case 0xB: return low == 0 ? .nothing : .command(Command.D, 0xF0 | min(low, 14))
            case 0xC:
                // Cut after no ticks at all: ProTracker's note is not heard, and Scream Tracker's is not cut.
                if low == 0 { return fromS3M ? .nothing : .cut }
                return .command(Command.S, 0xC0 | low)
            // (Delayed by no ticks is not delayed. Impulse Tracker would make it one.)
            case 0xD: return low == 0 ? .nothing : .command(Command.S, 0xD0 | low)
            case 0xE: return .command(Command.S, 0xE0 | low)
            default: return .nothing // the filter, sliding by semitones, retuning, and the Amiga's "invert loop"
            }
        case 0x0F: return .command(Command.A, value)
        case 0x10: return .command(Command.J, value)
        case 0x12: return .command(Command.Q, value)
        case 0x13: return .command(Command.V, min(value, 64) * 2)
        case 0x14: return .command(Command.U, value)
        case 0x1E:
            if value == 0x01 { return .command(Command.S, 0x91) }
            if high == 0x8 { return .pan(low) }
            return .nothing
        // (Below 32 Impulse Tracker's is a slide of the tempo, and BWSB has no tempo so slow.)
        case 0x1F: return value < 0x20 ? .nothing : .command(Command.T, value)
        default: return .nothing
        }
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        guard isOne(data) else { throw TuneError.malformed("not a GDM file") }
        let f = ByteReader(data)
        guard f[75] == 1 else { throw TuneError.unsupported("a GDM file of a version other than 1") }

        let origin = f.u16le(116)
        let fromS3M = origin == s3m
        let orderOffset = long(f, 118), orderCount = Int(f[122]) + 1
        let patternOffset = long(f, 123), patternCount = Int(f[127]) + 1
        let sampleHeaderOffset = long(f, 128), sampleDataOffset = long(f, 132), sampleCount = Int(f[136]) + 1

        // The channels: where each is, or that it is not used. One that is not used is not heard,
        // but what its commands do to the whole tune (its speed, where it goes next) is still done.
        var pans = [UInt8](repeating: 32 | 128, count: MAX_HOST_CHANNELS)
        for channel in 0 ..< 32 {
            let place = f[81 + channel]
            if place < 16 {
                pans[channel] = IT2ForeignModule.pan(ofSixteen: place)
            } else if place == 16 {
                pans[channel] = PAN_SURROUND
            }
        }

        var orders = (0 ..< orderCount).map { f[orderOffset + $0] }

        // MARK: Samples

        var samples: [IT2Sample] = []
        /// The volume each sample has of its own; nil for one that has none, or is not in the file.
        var ownVolumes = [UInt8?](repeating: nil, count: 256)
        var soundAt = sampleDataOffset
        for index in 0 ..< IT2ForeignModule.sampleRoom {
            guard index < sampleCount else {
                samples.append(IT2Sample())
                continue
            }
            let at = sampleHeaderOffset + index * 62
            let bytes = long(f, at + 45)
            let flags = f[at + 57]
            if flags & 0x10 != 0 { throw TuneError.unsupported("a GDM file with compressed samples") }
            let sixteen = flags & 0x02 != 0
            // (A sample may have no volume of its own, and leave the channel's as it is. See `settle`.)
            let ownVolume: UInt8? = flags & 0x04 != 0 && f[at + 60] != 255 ? min(f[at + 60], 64) : nil
            ownVolumes[index + 1] = ownVolume
            var pan: UInt8?
            if flags & 0x08 != 0 {
                if f[at + 61] < 16 { pan = IT2ForeignModule.pan(ofSixteen: f[at + 61]) } else if f[at + 61] == 16 { pan = PAN_SURROUND }
            }
            // Its sound, as much as the file has of it: unsigned, and one sample after another from
            // where the samples start.
            let there = max(0, min(bytes, data.count - soundAt))
            var sound8: [Int8] = [], sound16: [Int16] = []
            if sixteen {
                sound16 = (0 ..< there / 2).map { Int16(bitPattern: (UInt16(f[soundAt + $0 * 2]) | UInt16(f[soundAt + $0 * 2 + 1]) << 8) ^ 0x8000) }
            } else {
                sound8 = (0 ..< there).map { Int8(bitPattern: f[soundAt + $0] ^ 0x80) }
            }
            soundAt = min(soundAt + bytes, data.count)
            // (2GDM writes the end of the part that repeats one further on than it is.)
            samples.append(IT2ForeignModule.sample(sound8: sound8, sound16: sound16, volume: ownVolume ?? 64, rate: IT2ForeignModule.rate(f.u16le(at + 58)),
                                                loops: flags & 0x01 != 0, loopStart: long(f, at + 49), loopEnd: long(f, at + 53) - 1, pan: pan))
        }

        // MARK: Patterns

        var patterns = [IT2ForeignModule.Pattern](repeating: IT2ForeignModule.Pattern(), count: min(patternCount, IT2ForeignModule.patternRoom))
        var at = patternOffset
        for index in patterns.indices where at < data.count {
            // A pattern says how long it is, and that length counts the two bytes that say so. What
            // it has for each channel of each row is gathered first: a row can come back to a channel
            // it has already given something to, and adds to it.
            var cells = [Cell](repeating: Cell(), count: 64 * 32)
            let length = f.u16le(at)
            let end = min(at + length, data.count)
            var i = at + 2, row = 0
            while i < end, row < 64 {
                let what = f[i]
                i += 1
                if what == 0 {
                    row += 1
                    continue
                }
                let place = row * 32 + Int(what & 0x1F)
                cells[place].used = true
                if what & 0x20 != 0 {
                    cells[place].note = f[i]
                    cells[place].instrument = f[i + 1]
                    i += 2
                }
                if what & 0x40 != 0 {
                    // Up to four commands, each saying which of the four it is and whether another follows.
                    var more = true
                    while more, i < end {
                        more = f[i] & 0x20 != 0
                        cells[place].effects[Int(f[i] >> 6)] = f[i] & 0x1F
                        cells[place].values[Int(f[i] >> 6)] = f[i + 1]
                        i += 2
                    }
                }
            }
            at += max(length, 2)

            for place in 0 ..< 64 * 32 where cells[place].used {
                let from = cells[place]
                var cell = IT2ForeignModule.Cell()
                // A note is an octave and a note within it, counted from 1; its top bit says only
                // that it is being slid to. C in octave 4 plays a sample at its rate.
                let note = Int(from.note & 0x7F) - 1
                if note >= 0 {
                    let number = 12 + 12 * (note >> 4) + (note & 15)
                    if number < 120 { cell.set(note: UInt8(number)) }
                }
                if from.instrument != 0 { cell.set(instrument: from.instrument) }
                var commands: [(command: UInt8, value: UInt8)] = []
                var pan: UInt8?
                var cut = false
                for which in 0 ..< 4 {
                    switch meaning(from.effects[which], from.values[which], fromS3M: fromS3M) {
                    case .nothing: break
                    case .volume(let volume): cell.set(volume: volume)
                    case .pan(let place): pan = place
                    case .command(let command, let value): commands.append((command, value))
                    case .cut: cut = true
                    }
                }
                _ = IT2ForeignModule.place(commands: commands, pan: pan, in: &cell)
                if cut { cell.set(note: IT2ForeignModule.noteCut) }
                patterns[index][place / 32, place % 32] = cell
            }
        }

        // An instrument on a row with no note is not Impulse Tracker's to play. See `settle`.
        var memories = [IT2ForeignModule.ChannelMemory](repeating: IT2ForeignModule.ChannelMemory(), count: 32)
        let packed = IT2ForeignModule.settledDownTheList(&orders, patterns: patterns.count) { index in
            var pattern = patterns[index]
            for row in 0 ..< 64 {
                for channel in 0 ..< 32 where pattern[row, channel].mask != 0 {
                    IT2ForeignModule.settle(&pattern[row, channel], &memories[channel], slideStartsNote: fromS3M, cutIsSilence: !fromS3M) {
                        ownVolumes[Int($0)]
                    }
                }
            }
            return pattern.packed()
        }
        let rows = [UInt16](repeating: 64, count: IT2ForeignModule.patternRoom)

        // MARK: The rest

        var madeWith = "BWSB 2GDM \(f[79])." + (f[80] < 10 ? "0" : "") + "\(f[80])"
        if origin > 0, origin < origins.count { madeWith += ", from " + (origin == 2 || origin == 3 || origin == 7 ? "an " : "a ") + origins[origin] + " file" }
        let author = f.ascii(at: 36, length: 32)
        let module = IT2Module(title: f.ascii(at: 4, length: 32), madeWith: madeWith, orders: orders, flags: IT2ForeignModule.flags,
                               globalVolume: min(f[113], 64) * 2, mixVolume: mixVolume, speed: f[114] == 0 ? 6 : f[114],
                               tempo: f[115] == 0 ? 125 : f[115], channelPans: pans, samples: samples, patterns: packed, rows: rows)
        return ITRenderer(module: module, format: "GDM", author: author == "Unknown" ? "" : author, options: options)
    }

    /// How loud the whole is made, of Impulse Tracker's 128: set by measure, so that these files are
    /// about as loud as S3M and IT files are.
    private static let mixVolume: UInt8 = 48
}
