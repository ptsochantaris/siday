// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the ULT loaders of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence,
// and of libxmp, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito Carraro Jr, used under the
// MIT licence (see THIRD-PARTY.md); and from FreeJack's description of the format, with Marc André
// Schallehn's notes on what his later versions changed.

import SidayFoundation

/// A ULT file, UltraTracker's kind of module.
///
/// UltraTracker was a tracker for DOS and the Gravis Ultrasound, by Marc André Schallehn: up to 32
/// channels, each anywhere of sixteen places between the speakers; samples of eight bits or
/// sixteen, which go round forwards or back and forth while a note is held; and ProTracker's
/// commands under ProTracker's numbers, two of them to a note where ProTracker has one.
///
/// It is played here by Impulse Tracker's replayer, and not by UltraTracker's own, which has never
/// been published. Every player of these files does the same, OpenMPT and Schism Tracker among
/// them, and for the same reason: UltraTracker's commands are ones Impulse Tracker has, to the
/// last. See `IT2ForeignModule`.
///
/// What does not go over as it stands:
///  - Two commands to a note. Impulse Tracker has room for one, and a volume column that can do
///    some things besides set a volume: a place between the speakers, a slide of volume, and a few
///    slides of pitch. So the second command goes there when it is one of those, and a command
///    that is for the whole tune (its speed, or where it goes next) goes to another channel of
///    the row. What is left with nowhere to go is left out, and the file says so.
///  - A slide to a note, which in UltraTracker goes on by itself, row after row, until it gets
///    there or another note comes. The replayer is told to carry it on (`slidesToNotesCarryOn`).
///  - A sample's loop, which is for as long as the note is held: UltraTracker can let a note go
///    (5xC), and its sample then plays to its end. That is Impulse Tracker's sustain loop, and
///    its note-off.
///  - Volumes, which are of 255 where Impulse Tracker's are of 64.
///  - An instrument named with no note, which is its volume and no more (see
///    `IT2ForeignModule.settle`). Where two commands stand beside it the volume column is wanted
///    for one of them, and the instrument is left for the replayer, which is told to start nothing
///    for it (`instrumentAloneStartsNothing`).
/// Three things are not played: 5x1, which plays a note without its sample's loop; E0x, which sets
/// how deep a vibrato is to go from then on; and a note that is to start further into its sample
/// than Impulse Tracker's command reaches, which starts as far in as that reaches. And in a file
/// of before UltraTracker 1.4 the volumes were not evenly spaced, and are played here as if they were.
enum ULTFile {
    private typealias Command = IT2ForeignModule.Command

    /// True for a file that says it is one of these.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 48 && data[0 ..< 14].elementsEqual(Array("MAS_UTrack_V00".utf8)) && data[14] >= 0x31 && data[14] <= 0x34
    }

    /// Four bytes as a place or a length, the first the least; one too large to be either is
    /// brought down to where it is still neither. (A whole number in a browser has 32 bits.)
    private static func long(_ f: ByteReader, _ i: Int) -> Int {
        let high = f.u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16le(i)
    }

    /// One channel's part of a row, as the file has it.
    private struct Cell {
        var note: UInt8 = 0, instrument: UInt8 = 0
        /// The two commands, each with its value.
        var first: UInt8 = 0, firstValue: UInt8 = 0, second: UInt8 = 0, secondValue: UInt8 = 0

        var isEmpty: Bool { note == 0 && instrument == 0 && first == 0 && firstValue == 0 && second == 0 && secondValue == 0 }
    }

    /// What a command of the file's comes to.
    private enum Meaning {
        case nothing
        /// A command of Impulse Tracker's, with its value.
        case command(UInt8, UInt8)
        /// The volume column's volume, from 0 to 64, and a place between the speakers of sixteen.
        case volume(UInt8)
        case pan(UInt8)
        /// How far into its sample a note is to start, in units of 1,024 samples.
        case offset(UInt8)
        /// The note's key is let go.
        case letGo
        /// The speed and the tempo both, back to what a tune starts with.
        case usualTime
        /// Something UltraTracker has that is not played: which, by its place in `leftOutNames`.
        case leftOut(Int)
    }

    private static let leftOutNames = ["playing a note without its sample's loop", "the depth of vibrato", "commands that UltraTracker is not known to have had"]

    /// - Parameter version: which of the four kinds of file it is, from 1.
    private static func meaning(_ effect: UInt8, _ value: UInt8, version: Int) -> Meaning {
        let high = value >> 4, low = value & 15
        switch effect {
        case 0x0: return value != 0 && version >= 3 ? .command(Command.J, value) : .nothing
        case 0x1: return .command(Command.F, value)
        case 0x2: return .command(Command.E, value)
        case 0x3: return .command(Command.G, value)
        case 0x4: return .command(Command.H, value)
        case 0x5:
            // Its two halves are two things to do; backwards and letting go are the ones that are done.
            if low == 0x2 || high == 0x2 { return .command(Command.S, 0x9F) }
            if low == 0xC || high == 0xC { return version >= 3 ? .letGo : .nothing }
            if low == 0x1 || high == 0x1 { return .leftOut(0) }
            return .nothing
        case 0x7: return version >= 4 ? .command(Command.R, value) : .nothing
        case 0x9: return .offset(value)
        // (Up and down together is up. And by fifteen is by fourteen: Impulse Tracker makes a
        // slide by fifteen on a row's first tick too, which is its own way and nobody else's.)
        case 0xA: return .command(Command.D, high != 0 ? min(high, 14) << 4 : min(low, 14))
        case 0xB: return .pan(low)
        case 0xC: return .volume(UInt8((Int(value) * 64 + 127) / 255))
        // (The row to go to is written in tens and ones.)
        case 0xD: return .command(Command.C, UInt8(min(63, Int(high) * 10 + Int(low))))
        case 0xE:
            switch high {
            case 0x0: return .leftOut(1)
            case 0x1: return low == 0 ? .nothing : .command(Command.F, 0xF0 | low)
            case 0x2: return low == 0 ? .nothing : .command(Command.E, 0xF0 | low)
            case 0x8: return version >= 4 ? .command(Command.S, 0x60 | low) : .nothing
            case 0x9: return .command(Command.Q, low)
            case 0xA: return low == 0 ? .nothing : .command(Command.D, low << 4 | 0x0F)
            // (Down by fifteen, which would be read as up by fifteen, is down by fourteen.)
            case 0xB: return low == 0 ? .nothing : .command(Command.D, 0xF0 | min(low, 14))
            case 0xC: return .command(Command.S, 0xC0 | low)
            case 0xD: return low == 0 ? .nothing : .command(Command.S, 0xD0 | low)
            default: return .leftOut(2)
            }
        case 0xF:
            if value == 0 { return .usualTime }
            return value < 0x30 ? .command(Command.A, value) : .command(Command.T, value)
        default: return value == 0 ? .nothing : .leftOut(2)
        }
    }

    /// True if two commands come to the same command of Impulse Tracker's, whatever their values.
    private static func same(_ a: Meaning, _ b: Meaning) -> Bool {
        switch (a, b) {
        case let (.command(first, _), .command(second, _)): first == second
        case (.volume, .volume), (.pan, .pan), (.letGo, .letGo), (.usualTime, .usualTime): true
        default: false
        }
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        guard isOne(data) else { throw TuneError.malformed("not a ULT file") }
        let f = ByteReader(data)
        let version = Int(data[14]) - 0x30
        // The tune's text, in lines of 32 letters, and then the samples.
        var at = 48 + Int(data[47]) * 32
        let sampleCount = Int(f[at])
        at += 1
        let headerSize = version >= 4 ? 66 : 64
        let ordersAt = at + sampleCount * headerSize
        guard ordersAt + 258 <= data.count else { throw TuneError.malformed("a ULT file that ends before its patterns begin") }
        let channelCount = Int(f[ordersAt + 256]) + 1, patternCount = Int(f[ordersAt + 257]) + 1
        guard channelCount <= 32 else { throw TuneError.malformed("a ULT file with more channels than a ULT file can have") }
        var orders = (0 ..< 256).map { f[ordersAt + $0] }
        if let end = orders.firstIndex(of: 255) { orders = Array(orders[..<end]) }

        var pans = [UInt8](repeating: 32 | 128, count: MAX_HOST_CHANNELS)
        var patternsAt = ordersAt + 258
        for channel in 0 ..< channelCount {
            // (Before 1.5 a file did not say where its channels are, and they were to the left
            // and the right by turns.)
            pans[channel] = version >= 3 ? IT2ForeignModule.pan(ofSixteen: f[patternsAt + channel]) : channel & 1 != 0 ? 48 : 16
        }
        if version >= 3 { patternsAt += channelCount }

        // MARK: Patterns

        // Every pattern has 64 rows. They are kept a channel at a time: the first channel's part of
        // every pattern, then the second's; and a cell that is the same as those after it is
        // written once, with how many times.
        var cells = [[Cell]](repeating: [Cell](repeating: Cell(), count: 64 * 32), count: patternCount)
        at = patternsAt
        for channel in 0 ..< channelCount {
            for pattern in 0 ..< patternCount {
                var row = 0
                while row < 64, at + 5 <= data.count {
                    var times = 1
                    var note = f[at]
                    at += 1
                    if note == 0xFC {
                        times = Int(f[at])
                        note = f[at + 1]
                        at += 2
                    }
                    let cell = Cell(note: note, instrument: f[at], first: f[at + 1] & 15, firstValue: f[at + 2], second: f[at + 1] >> 4, secondValue: f[at + 3])
                    at += 4
                    if times == 0 { break }
                    for _ in 0 ..< min(times, 64 - row) {
                        cells[pattern][row * 32 + channel] = cell
                        row += 1
                    }
                }
            }
        }

        // MARK: Samples

        struct Sample {
            var exists = false, sixteenBit = false
            var volume: UInt8 = 0
        }
        var samples = [Sample](repeating: Sample(), count: 256)
        var made: [IT2Sample] = []
        var cutShort = Shortfall.CutShort()
        var soundAt = at
        for index in 0 ..< IT2ForeignModule.sampleRoom {
            guard index < sampleCount else {
                made.append(IT2Sample())
                continue
            }
            let header = 48 + Int(data[47]) * 32 + 1 + index * headerSize
            var loopStart = long(f, header + 44), loopEnd = long(f, header + 48)
            let frames = max(0, long(f, header + 56) - long(f, header + 52))
            guard frames < 1 << 24 else { throw TuneError.malformed("a ULT file with a sample too long to be one") }
            let flags = f[header + 61]
            var sample = Sample(exists: true, sixteenBit: flags & 4 != 0)
            sample.volume = UInt8((Int(f[header + 60]) * 64 + 127) / 255)
            // A sample's rate is for the C of UltraTracker's second octave, which is two octaves
            // below the note Impulse Tracker's is for; and its notes are numbered an octave apart
            // from Impulse Tracker's. (Before 1.6 a file had no rate, and a sample was at 8,363.)
            var rate = Double(version >= 4 ? f.u16le(header + 62) : 8363) * 2
            let fineTune = Int(Int16(truncatingIfNeeded: f.u16le(header + headerSize - 2)))
            if fineTune != 0 { rate = (rate * pow(2.0, Double(fineTune) / (12.0 * 32768.0))).rounded() }

            let bytes = sample.sixteenBit ? frames * 2 : frames
            let there = max(0, min(bytes, data.count - soundAt))
            cutShort.add(length: bytes, there: data.count - soundAt)
            var sound8: [Int8] = [], sound16: [Int16] = []
            if sample.sixteenBit {
                // (Where a sample of sixteen bits goes round is given in bytes.)
                loopStart /= 2
                loopEnd /= 2
                sound16 = [Int16](repeating: 0, count: frames)
                for i in 0 ..< there / 2 { sound16[i] = Int16(truncatingIfNeeded: f.u16le(soundAt + i * 2)) }
            } else {
                sound8 = [Int8](repeating: 0, count: frames)
                for i in 0 ..< there { sound8[i] = Int8(bitPattern: data[soundAt + i]) }
            }
            soundAt += bytes
            samples[index + 1] = sample
            made.append(IT2ForeignModule.sample(sound8: sound8, sound16: sound16, volume: sample.volume, rate: IT2ForeignModule.rate(Int(rate)),
                                                loops: flags & 8 != 0, backAndForth: flags & 16 != 0, loopStart: loopStart, loopEnd: loopEnd, whileHeld: true))
        }

        // MARK: Into Impulse Tracker's patterns

        var leftOut = Shortfall.Kinds()
        var noRoom = 0, tooFar = 0
        var memories = [IT2ForeignModule.ChannelMemory](repeating: IT2ForeignModule.ChannelMemory(), count: 32)
        /// The last slide of volume each channel was given as a command, which is the one Impulse
        /// Tracker's D00 goes on with: as near as can be known, going through the patterns in the
        /// order the tune plays them.
        var lastSlides = [UInt8](repeating: 0, count: 32)
        let patterns = IT2ForeignModule.settledDownTheList(&orders, patterns: patternCount) { index in
            var pattern = IT2ForeignModule.Pattern()
            for row in 0 ..< 64 {
                // Commands for the whole tune that found no room on their own channel.
                var forTheTune: [(command: UInt8, value: UInt8)] = []
                for channel in 0 ..< channelCount {
                    let from = cells[index][row * 32 + channel]
                    if from.isEmpty { continue }
                    var cell = IT2ForeignModule.Cell()
                    // 1 is the lowest C, which is the C of Impulse Tracker's second octave.
                    if from.note >= 1, from.note <= 96 { cell.set(note: from.note + 23) }
                    if from.instrument != 0 { cell.set(instrument: from.instrument) }

                    var meanings = [meaning(from.first, from.firstValue, version: version), meaning(from.second, from.secondValue, version: version)]
                    // Two offsets are one, of four times the precision: the two values together,
                    // in units of four samples.
                    var offset: Int?
                    if case .offset = meanings[0], case .offset = meanings[1] {
                        offset = (Int(from.secondValue) << 8 | Int(from.firstValue)) >> 6
                        meanings = []
                    } else if same(meanings[0], meanings[1]) {
                        // (The same thing twice: what UltraTracker made of that is anybody's guess, and it is taken once.)
                        meanings = [meanings[0]]
                    }
                    var commands: [(command: UInt8, value: UInt8)] = []
                    var pan: UInt8?
                    var letGo = false
                    for one in meanings {
                        switch one {
                        case .nothing: break
                        case let .command(command, value): commands.append((command, value))
                        case let .volume(volume): cell.set(volume: volume)
                        case let .pan(place): pan = place
                        case let .offset(value): offset = Int(value) * 4
                        case .letGo: letGo = true
                        case .usualTime: commands += [(Command.A, 6), (Command.T, 125)]
                        case let .leftOut(kind): leftOut.note(kind)
                        }
                    }
                    if let offset {
                        // In Impulse Tracker's units, of 256 samples; its command reaches 255 of them.
                        if offset > 0xFF { tooFar += 1 }
                        commands.insert((Command.O, UInt8(min(offset, 0xFF))), at: 0)
                    }
                    // A slide of volume beside a vibrato or a slide to a note that only carries on
                    // is one command of Impulse Tracker's.
                    if commands.count == 2, let slide = commands.firstIndex(where: { $0.command == Command.D }) {
                        let other = commands[1 - slide]
                        if other.value == 0, other.command == Command.H || other.command == Command.G {
                            commands = [(other.command == Command.H ? Command.K : Command.L, commands[slide].value)]
                        }
                    }
                    if letGo {
                        // A key let go is a note of its own to Impulse Tracker, and cannot be beside another.
                        if cell.hasNote { noRoom += 1 } else { cell.set(note: 255) }
                    }

                    // What is for the whole tune can go to another channel, so it gives way.
                    func isForTheTune(_ command: UInt8) -> Bool { command == Command.A || command == Command.T || command == Command.C }
                    if commands.count > 1 {
                        let moved = commands.filter { isForTheTune($0.command) }
                        let kept = commands.filter { !isForTheTune($0.command) }
                        commands = kept.isEmpty ? [moved[0]] : kept
                        forTheTune += kept.isEmpty ? Array(moved.dropFirst()) : moved
                    }
                    // A slide of volume that goes on with the last, beside another command, may have
                    // to go in the volume column, which remembers its own slides and not the
                    // command's: so it is given the last by name, and where there has been none it
                    // is nothing, and gives up its place.
                    if commands.count > 1, let slide = commands.firstIndex(where: { $0.command == Command.D && $0.value == 0 }) {
                        if lastSlides[channel] == 0 { commands.remove(at: slide) } else { commands[slide].value = lastSlides[channel] }
                    }
                    // An instrument with no note is its volume, which would go in the volume column:
                    // where two other things want room, it stays an instrument, and the replayer is
                    // told what one alone is to do.
                    let crowded = commands.count + (pan == nil ? 0 : 1) > 1
                    IT2ForeignModule.settle(&cell, &memories[channel], instrumentAloneStays: crowded) { samples[Int($0)].exists ? samples[Int($0)].volume : nil }
                    noRoom += IT2ForeignModule.place(commands: commands, pan: pan, in: &cell, nearest: true)
                    if cell.hasCommand, cell.value != 0, cell.command == Command.D || cell.command == Command.K || cell.command == Command.L {
                        lastSlides[channel] = cell.value
                    }
                    pattern[row, channel] = cell
                }
                for one in forTheTune {
                    if let free = (0 ..< MAX_HOST_CHANNELS).first(where: { !pattern[row, $0].hasCommand }) {
                        var cell = pattern[row, free]
                        cell.set(command: one.command, one.value)
                        pattern[row, free] = cell
                    } else {
                        noRoom += 1
                    }
                }
            }
            return pattern.packed()
        }

        var shortfalls: [String] = []
        if noRoom > 0 {
            shortfalls.append(Shortfall.some(noRoom, one: "notes has two commands that Impulse Tracker's replayer has no room for, and the second is left out.",
                                             many: "notes have two commands that Impulse Tracker's replayer has no room for, and the second of each is left out."))
        }
        if tooFar > 0 {
            shortfalls.append(Shortfall.some(tooFar, one: "notes is to start further into its sample than can be asked for, and starts sooner.",
                                             many: "notes are to start further into their samples than can be asked for, and start sooner."))
        }
        if let sentence = Shortfall.commandsLeftOut(leftOut.named(leftOutNames)) { shortfalls.append(sentence) }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        let madeWith = "UltraTracker " + ["before 1.4", "1.4", "1.5", "1.6"][version - 1]
        let module = IT2Module(title: f.dos(at: 15, length: 32), madeWith: madeWith, orders: orders, flags: IT2ForeignModule.flags,
                               globalVolume: 128, mixVolume: mixVolume, speed: 6, tempo: 125, channelPans: pans, samples: made,
                               patterns: patterns, rows: [UInt16](repeating: 64, count: IT2ForeignModule.patternRoom), slidesToNotesCarryOn: true,
                               instrumentAloneStartsNothing: true)
        return ITRenderer(module: module, format: "ULT", shortfalls: shortfalls, options: options)
    }

    /// How loud the whole is made, of Impulse Tracker's 128: set by measure, so that these files are
    /// about as loud as IT files are.
    private static let mixVolume: UInt8 = 44
}
