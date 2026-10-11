// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the PTM loaders of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence,
// and of libxmp, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito Carraro Jr, used under the
// MIT licence (see THIRD-PARTY.md); and from JAL's description of the format, PTMFORM 1.17.

/// A PTM file, PolyTracker's kind of module.
///
/// PolyTracker was a tracker for DOS and the Gravis Ultrasound, made to be a better Scream Tracker:
/// 32 channels where that had sixteen, samples of sixteen bits, and loops that go back and forth.
/// Its file is an S3M file altered: the same packed patterns of 64 rows, the samples with a rate for
/// C-4, kept as the differences from one byte to the next. Its commands are ProTracker's by number,
/// with Scream Tracker's fine slides inside them and eight more after them.
///
/// It is played here by Impulse Tracker's replayer, and not by PolyTracker's own, which is not
/// ported. See `IT2ForeignModule`.
///
/// Three things of PolyTracker's are not Impulse Tracker's:
///  - A sample played backwards (Nxx). Impulse Tracker has no such thing, but it can be given the
///    sample written out backwards as a sample of its own, and is: so that is heard as it should be.
///  - Slides by a number of semitones every few ticks (Jxy to Mxy). Impulse Tracker has slides of
///    pitch that are smooth and none that go by steps, so each is given as the smooth one that gets
///    as far by the end of its row: the same sweep, without its stairs. The two that strike the note
///    again at every step do not.
///  - Its volumes, which the Ultrasound did not play quite evenly spaced: a note at half volume was a
///    decibel louder than half. They are played evenly spaced.
/// And E3x (sliding by semitones) and E5x (retuning a sample) do nothing, as in Impulse Tracker.
enum PTMFile {
    private typealias Command = IT2ForeignModule.Command

    /// Four bytes as a place in the file or a length, the first the least. One too large to be either
    /// is brought down to where it is still neither. (A whole number in a browser has 32 bits.)
    private static func long(_ f: ByteReader, _ i: Int) -> Int {
        let high = f.u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16le(i)
    }

    /// True for a file that says it is one of these.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 608 && data[44 ..< 48].elementsEqual([0x50, 0x54, 0x4D, 0x46])
    }

    /// A sample as the file has it.
    private struct Sample {
        var exists = false
        var sixteenBit = false
        var volume: UInt8 = 0
        var rate: UInt32 = 0
        var sound8: [Int8] = [], sound16: [Int16] = []
        var frames: Int { sixteenBit ? sound16.count : sound8.count }
    }

    /// One channel's part of a row, as the file has it. A note of 0 is none, and a volume of 255.
    private struct Cell {
        var note: UInt8 = 0, instrument: UInt8 = 0, volume: UInt8 = 255
        var hasEffect = false
        var effect: UInt8 = 0, value: UInt8 = 0
    }

    private static let reverse: UInt8 = 0x17, offset: UInt8 = 0x09

    /// A command of the file's as Impulse Tracker has it; nil for one that is nothing there. (Setting
    /// the volume, the offset into a sample and playing one backwards are seen to apart.)
    private static func translated(_ effect: UInt8, _ value: UInt8) -> (command: UInt8, value: UInt8)? {
        let high = value >> 4, low = value & 15
        switch effect {
        case 0x00: return value == 0 ? nil : (Command.J, value)
        // (These have Scream Tracker's fine and extra fine slides in them, as Impulse Tracker's do.)
        case 0x01: return (Command.F, value)
        case 0x02: return (Command.E, value)
        case 0x03: return (Command.G, value)
        case 0x04: return (Command.H, value)
        case 0x05: return (Command.L, value)
        case 0x06: return (Command.K, value)
        case 0x07: return (Command.R, value)
        // PolyTracker's own sum for a place between the speakers given as ProTracker gives one.
        case 0x08: return (Command.S, 0x80 | ((max(value >> 3, 1) - 1) & 15))
        case 0x0A: return (Command.D, value)
        case 0x0B: return (Command.B, value)
        case 0x0D: return (Command.C, value)
        case 0x0E:
            switch high {
            case 0x1: return low == 0 ? nil : (Command.F, 0xF0 | low)
            case 0x2: return low == 0 ? nil : (Command.E, 0xF0 | low)
            case 0x4: return (Command.S, 0x30 | low)
            case 0x6: return (Command.S, 0xB0 | low)
            case 0x7: return (Command.S, 0x40 | low)
            case 0x8: return (Command.S, 0x80 | low)
            case 0x9: return (Command.Q, low)
            case 0xA: return low == 0 ? nil : (Command.D, low << 4 | 0x0F)
            // (Down by fifteen, which would be read as up by fifteen, is down by fourteen.)
            case 0xB: return low == 0 ? nil : (Command.D, 0xF0 | min(low, 14))
            case 0xC: return (Command.S, 0xC0 | low)
            case 0xD: return low == 0 ? nil : (Command.S, 0xD0 | low)
            case 0xE: return (Command.S, 0xE0 | low)
            default: return nil
            }
        case 0x0F: return value < 0x20 ? (Command.A, value) : (Command.T, value)
        case 0x10: return (Command.V, min(value, 64) * 2)
        case 0x11: return (Command.Q, value)
        case 0x12: return (Command.U, value)
        default: return nil // what PolyTracker has no command for
        }
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        guard isOne(data) else { throw TuneError.malformed("not a PTM file") }
        let f = ByteReader(data)
        let orderCount = f.u16le(32), sampleCount = f.u16le(34), patternCount = f.u16le(36), channelCount = f.u16le(38)
        guard orderCount <= 256, sampleCount <= 255, patternCount <= 128, channelCount >= 1, channelCount <= 32 else {
            throw TuneError.malformed("a PTM file with more orders, samples, patterns or channels than a PTM file can have")
        }

        var pans = [UInt8](repeating: 32 | 128, count: MAX_HOST_CHANNELS)
        for channel in 0 ..< channelCount { pans[channel] = IT2ForeignModule.pan(ofSixteen: f[64 + channel]) }
        var orders = (0 ..< orderCount).map { f[96 + $0] }

        // MARK: Samples

        var samples = [Sample](repeating: Sample(), count: 256)
        var made: [IT2Sample] = []
        var cutShort = Shortfall.CutShort()
        for index in 0 ..< IT2ForeignModule.sampleRoom {
            guard index < sampleCount else {
                made.append(IT2Sample())
                continue
            }
            let at = 608 + index * 80
            let type = f[at]
            var sample = Sample()
            sample.exists = true
            sample.volume = min(f[at + 13], 64)
            // The rate is for C-4, and Impulse Tracker's for the C an octave above.
            sample.rate = IT2ForeignModule.rate(f.u16le(at + 14)) * 2
            sample.sixteenBit = type & 0x10 != 0
            var loopStart = 0, loopEnd = 0
            if type & 3 == 1 {
                let from = long(f, at + 18)
                let bytes = max(0, min(long(f, at + 22), data.count - from))
                cutShort.add(length: long(f, at + 22), there: data.count - from)
                loopStart = long(f, at + 26)
                loopEnd = long(f, at + 30)
                // (PolyTracker went round one sample short of where the file says.)
                if loopEnd > loopStart { loopEnd -= 1 }
                // The sound is kept as the difference of each byte from the one before, whether a
                // sample is one byte or two.
                var sum: UInt8 = 0
                if sample.sixteenBit {
                    loopStart /= 2
                    loopEnd /= 2
                    var low: UInt8 = 0
                    sample.sound16.reserveCapacity(bytes / 2)
                    for k in 0 ..< bytes & ~1 {
                        sum &+= f[from + k]
                        if k & 1 == 0 { low = sum } else { sample.sound16.append(Int16(bitPattern: UInt16(low) | UInt16(sum) << 8)) }
                    }
                } else {
                    sample.sound8.reserveCapacity(bytes)
                    for k in 0 ..< bytes {
                        sum &+= f[from + k]
                        sample.sound8.append(Int8(bitPattern: sum))
                    }
                }
            }
            samples[index + 1] = sample
            made.append(IT2ForeignModule.sample(sound8: sample.sound8, sound16: sample.sound16, volume: sample.volume, rate: sample.rate,
                                             loops: type & 0x04 != 0, backAndForth: type & 0x08 != 0, loopStart: loopStart, loopEnd: loopEnd))
        }

        // MARK: Patterns

        // Every pattern has 64 rows, packed as an S3M file's are but for which bit says what follows.
        var cells = [[Cell]](repeating: [], count: patternCount)
        for index in 0 ..< patternCount {
            var pattern = [Cell](repeating: Cell(), count: 64 * 32)
            let segment = f.u16le(352 + index * 2)
            var at = segment * 16, row = 0
            while segment != 0, row < 64, at < data.count {
                let what = f[at]
                at += 1
                if what == 0 {
                    row += 1
                    continue
                }
                var cell = Cell()
                if what & 0x20 != 0 {
                    cell.note = f[at]
                    cell.instrument = f[at + 1]
                    at += 2
                }
                if what & 0x40 != 0 {
                    cell.hasEffect = true
                    cell.effect = f[at]
                    cell.value = f[at + 1]
                    at += 2
                }
                if what & 0x80 != 0 {
                    cell.volume = f[at]
                    at += 1
                }
                if Int(what & 0x1F) < channelCount { pattern[row * 32 + Int(what & 0x1F)] = cell }
            }
            cells[index] = pattern
        }

        // A sample played backwards is a sample of its own, written out backwards from where it is
        // to start: each goes after the file's own samples, while there is room.
        var backwards: [(sample: UInt8, start: Int, number: UInt8)] = []
        var roomLeft = max(min(data.count, 1 << 26) * 4, 8 << 20)
        func backwardsSample(_ number: UInt8, offset: Int) -> UInt8? {
            let sample = samples[Int(number)]
            guard sample.frames > 0 else { return nil }
            let start = sample.frames - 1 - min(offset, sample.frames - 1)
            if let known = backwards.first(where: { $0.sample == number && $0.start == start }) { return known.number }
            guard sampleCount + backwards.count < IT2ForeignModule.sampleRoom, start + 1 <= roomLeft else { return nil }
            roomLeft -= start + 1
            let place = sampleCount + backwards.count
            if sample.sixteenBit {
                made[place] = IT2ForeignModule.sample(sound16: sample.sound16[0 ... start].reversed(), volume: sample.volume, rate: sample.rate)
            } else {
                made[place] = IT2ForeignModule.sample(sound8: sample.sound8[0 ... start].reversed(), volume: sample.volume, rate: sample.rate)
            }
            backwards.append((number, start, UInt8(place + 1)))
            return UInt8(place + 1)
        }

        // A slide by semitones is a slide by so many of Impulse Tracker's units of pitch a tick, which
        // depends on where the pitch is: so the pitch of each channel is followed as the patterns
        // are gone through, in those units (a sample's time, in 14,317,456ths of a second), and how
        // many ticks a row has. (Other slides are not followed: a note is taken to be where it began,
        // or where slides by semitones have since put it.)
        struct Sliding {
            /// Where the pitch has got to, and where PolyTracker's would have: a smooth slide goes by
            /// coarser steps than the semitones want, and is aimed each time at where it should be.
            var period = 0.0, wanted = 0.0
            /// How many ticks between steps and how many semitones a step, each remembered when given as nought.
            var remembered: UInt8 = 0
        }
        var slidings = [Sliding](repeating: Sliding(), count: 32)
        var speed = 6
        // For `TuneInfo.shortfalls`: what of PolyTracker's is met in the patterns and is left out
        // or made do for.
        var leftOut = Shortfall.Kinds()
        var slidesBySteps = false, strikesAtSteps = false
        var backwardsLeftOut = 0

        var memories = [IT2ForeignModule.ChannelMemory](repeating: IT2ForeignModule.ChannelMemory(), count: 32)
        let patterns = IT2ForeignModule.settledDownTheList(&orders, patterns: patternCount) { index in
            var pattern = IT2ForeignModule.Pattern()
            for row in 0 ..< 64 {
                for channel in 0 ..< channelCount {
                    let from = cells[index][row * 32 + channel]
                    if from.hasEffect, from.effect == 0x0F, from.value >= 1, from.value < 0x20 { speed = Int(from.value) }
                }
                for channel in 0 ..< channelCount {
                    let from = cells[index][row * 32 + channel]
                    var cell = IT2ForeignModule.Cell()
                    // 1 is the lowest C, and 254 ends a note.
                    if from.note >= 1, from.note <= 120 { cell.set(note: from.note - 1) } else if from.note == 254 { cell.set(note: IT2ForeignModule.noteCut) }
                    if from.instrument != 0 { cell.set(instrument: from.instrument) }
                    if from.volume != 255 { cell.set(volume: min(from.volume, 64)) }
                    // (Setting the volume as ProTracker sets it comes after the row's own volume.)
                    if from.hasEffect, from.effect == 0x0C { cell.set(volume: min(from.value, 64)) }
                    if cell.mask == 0, !from.hasEffect { continue }
                    IT2ForeignModule.settle(&cell, &memories[channel]) { samples[Int($0)].exists ? samples[Int($0)].volume : nil }

                    let playing = samples[Int(memories[channel].instrument)]
                    if from.hasEffect, from.effect == offset {
                        // How far into the sample to start, in bytes: half as many samples of sixteen bits.
                        let value = playing.sixteenBit ? from.value >> 1 : from.value
                        if value != 0 || from.value == 0 { cell.set(command: Command.O, value) }
                    } else if from.hasEffect, from.effect == reverse {
                        // Backwards from so far before the end, and PolyTracker began it again on
                        // every tick of the row: which is what Q01 does.
                        if cell.hasNote, cell.note < 120,
                           let number = backwardsSample(memories[channel].instrument, offset: Int(from.value) << (playing.sixteenBit ? 7 : 8)) {
                            if !cell.hasInstrument, !cell.hasVolume { cell.set(volume: memories[channel].volume) }
                            cell.set(instrument: number)
                            cell.set(command: Command.Q, 0x01)
                            memories[channel].told = number
                        } else {
                            backwardsLeftOut += 1
                        }
                    } else if from.hasEffect, let (command, value) = translated(from.effect, from.value) {
                        cell.set(command: command, value)
                    } else if from.hasEffect, from.effect == 0x0E, from.value >> 4 == 3 && from.value & 15 != 0 || from.value >> 4 == 5 {
                        leftOut.note(from.value >> 4 == 3 ? 0 : 1)
                    }

                    if cell.hasNote, cell.note < 120, playing.rate > 0 {
                        slidings[channel].period = 14_317_456.0 / (Double(playing.rate) * pow(2.0, (Double(cell.note) - 60) / 12))
                        slidings[channel].wanted = slidings[channel].period
                    }
                    if from.hasEffect, from.effect >= 0x13, from.effect <= 0x16 {
                        if from.value & 0xF0 != 0 { slidings[channel].remembered = from.value & 0xF0 | slidings[channel].remembered & 0x0F }
                        if from.value & 0x0F != 0 { slidings[channel].remembered = slidings[channel].remembered & 0xF0 | from.value & 0x0F }
                        // A step on every so many ticks after the row's first: so many steps in the row.
                        let every = Int(slidings[channel].remembered >> 4), semitones = Int(slidings[channel].remembered & 15)
                        let steps = every > 0 ? (speed - 1) / every : 0
                        let up = from.effect == 0x13 || from.effect == 0x15
                        let period = slidings[channel].period
                        if steps > 0, semitones > 0, period > 0, speed > 1 {
                            slidesBySteps = true
                            if from.effect >= 0x15 { strikesAtSteps = true }
                            let wanted = slidings[channel].wanted * pow(2.0, Double(steps * semitones) / (up ? -12 : 12))
                            slidings[channel].wanted = wanted
                            // (A slide's value is four of the units, on each tick of the row but its first.)
                            let each = 4.0 * Double(speed - 1)
                            let value = min(0xDF, Int(abs(wanted - period) / each + 0.5))
                            if value > 0, (wanted < period) == up {
                                cell.set(command: up ? Command.F : Command.E, UInt8(value))
                                slidings[channel].period = max(1, period + (up ? -1 : 1) * Double(value) * each)
                            }
                        }
                    }
                    pattern[row, channel] = cell
                }
            }
            return pattern.packed()
        }

        var shortfalls: [String] = []
        if slidesBySteps {
            shortfalls.append("Its notes are slid smoothly where PolyTracker slid them by steps" + (strikesAtSteps ? ", and are not struck again at each step." : "."))
        }
        if backwardsLeftOut > 0 {
            shortfalls.append(Shortfall.some(backwardsLeftOut, one: "commands to play a sample backwards has no note to play, and is left out.",
                                             many: "commands to play a sample backwards have no note to play, and are left out."))
        }
        if let sentence = Shortfall.commandsLeftOut(leftOut.named(["sliding by semitones", "the retuning of a sample"])) { shortfalls.append(sentence) }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        let minor = Int(f[29])
        let digits = Array("0123456789abcdef".utf8)
        let madeWith = "PolyTracker \(f[30])." + String(decoding: [digits[minor >> 4], digits[minor & 15]], as: UTF8.self)
        let module = IT2Module(title: f.ascii(at: 0, length: 28), madeWith: madeWith, orders: orders, flags: IT2ForeignModule.flags,
                               globalVolume: 128, mixVolume: mixVolume, speed: 6, tempo: 125, channelPans: pans, samples: made,
                               patterns: patterns, rows: [UInt16](repeating: 64, count: IT2ForeignModule.patternRoom))
        return ITRenderer(module: module, format: "PTM", shortfalls: shortfalls, options: options)
    }

    /// How loud the whole is made, of Impulse Tracker's 128: set by measure, so that these files are
    /// about as loud as IT files are, and the loudest of them, which have 32 channels, have room.
    private static let mixVolume: UInt8 = 36
}
