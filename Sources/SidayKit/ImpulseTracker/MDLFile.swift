// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the MDL loaders of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence,
// and of libxmp, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito Carraro Jr, used under the
// MIT licence (see THIRD-PARTY.md); and from the description of the format and of its packed samples
// that came with Digitrakker, as libxmp quotes it.

/// An MDL file, the module of Digitrakker.
///
/// Digitrakker was a tracker for DOS, whose files came in three kinds, from its version 2 to its
/// version 3: up to 32 channels, each anywhere of 128 places between the speakers; instruments that
/// are a sample for each range of notes, each with envelopes for its volume, its place and its
/// pitch, a fade and a vibrato of its own; samples of eight bits or sixteen, kept packed if their
/// maker wished; and two commands to a note, the first for its pitch and the second for its volume,
/// with others that either can have.
///
/// It is played here by Impulse Tracker's replayer, and not by Digitrakker's own, which has never
/// been published. OpenMPT does the same, and its way of playing these files is the one followed:
/// the replayer is told what Digitrakker does otherwise than Impulse Tracker
/// (`IT2Module.playsAsDigitrakker`, and `IT2Digitrakker.swift`), as OpenMPT is. See `IT2ForeignModule`.
///
/// What does not go over as it stands:
///  - Two commands to a note. Impulse Tracker has room for one, and a volume column: the second goes
///    there where the volume column can do it and the note has no volume. Where it cannot, a place
///    between the speakers, or a move of it, is kept beside the cell for the replayer, and a command
///    for the whole tune goes to another channel of the row; and only then is one left out, the one
///    that matters less by OpenMPT's reckoning. The file says how many were.
///  - A note that starts further into its sample than Oxx reaches, 65,280 bytes, which has the rest
///    kept beside its cell too.
///  - Slides of volume, which are by 256ths of the whole, four times as fine as Impulse Tracker's,
///    and can be faster than its fastest: those that Impulse Tracker's can do are those, and the
///    replayer does the others (see `IT2DigitrakkerSlide`).
///  - An instrument's envelopes. Digitrakker keeps 64 of each kind for the whole tune, which the
///    instruments name and 9xx changes between; Impulse Tracker has one of each to an instrument. An
///    instrument has those its samples name, and 9xx turns one on, which the file says.
///  - Its notes' volumes, which are of 255 where Impulse Tracker's are of 64; and its places between
///    the speakers, of 128.
///  - A tempo below 32, slower than Impulse Tracker goes, which is a tune's way of stopping (see
///    `convert`).
/// Not played: E8x, which changes how a sample loops, and E5x, which tunes a sample afresh.
enum MDLFile {
    private typealias Command = IT2ForeignModule.Command

    /// True for a file that says it is one of these.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 5 && data.starts(with: [0x44, 0x4D, 0x44, 0x4C]) && data[4] < 0x20 // "DMDL"
    }

    /// Four bytes as a length, the first the least; one too large to be any is brought down to
    /// where it is still too large. (A whole number in a browser has 32 bits.)
    private static func long(_ f: ByteReader, _ i: Int) -> Int {
        let high = f.u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16le(i)
    }

    /// The file's parts, each by its two letters: where it starts and where it ends. A part that
    /// runs past the end of the file ends with it. Of two with the same letters the first is taken.
    private static func chunks(_ data: [UInt8]) -> [UInt16: Range<Int>] {
        let f = ByteReader(data)
        var found: [UInt16: Range<Int>] = [:]
        var at = 5
        while at + 6 <= data.count {
            let id = UInt16(f.u16le(at)), length = long(f, at + 2)
            let start = at + 6, end = start + min(length, data.count - start)
            if found[id] == nil { found[id] = start ..< end }
            at = end
            if length > data.count { break }
        }
        return found
    }

    private static func id(_ letters: String) -> UInt16 {
        let bytes = Array(letters.utf8)
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    // MARK: Commands

    /// The commands of OpenMPT's that Digitrakker's come to, in the order of how much each matters
    /// when there is room for only one (OpenMPT's `ModCommand::GetEffectWeight`).
    private enum Effect: Int, Comparable {
        case none = 0, tremolo = 6, vibrato = 8, finetune = 10, s = 13, panSlide = 18, pan = 19, portaUp = 24, portaDown = 28
        case volumeSlide = 31, vibratoVolume = 33, offset = 39, tremor = 40, retrig = 41, arpeggio = 43, slideToNote = 45
        case slideToNoteVolume = 46, globalVolumeSlide = 52, globalVolume = 53, tempo = 54, speed = 55, jump = 56, breakRow = 57

        static func < (a: Effect, b: Effect) -> Bool { a.rawValue < b.rawValue }

        /// Impulse Tracker's command for it.
        var letter: UInt8 {
            switch self {
            case .none, .finetune: 0
            case .tremolo: Command.R
            case .vibrato: Command.H
            case .s: Command.S
            case .panSlide: 16 // P
            case .pan: Command.X
            case .portaUp: Command.F
            case .portaDown: Command.E
            case .volumeSlide: Command.D
            case .vibratoVolume: Command.K
            case .offset: Command.O
            case .tremor: Command.I
            case .retrig: Command.Q
            case .arpeggio: Command.J
            case .slideToNote: Command.G
            case .slideToNoteVolume: Command.L
            case .globalVolumeSlide: 23 // W
            case .globalVolume: Command.V
            case .tempo: Command.T
            case .speed: Command.A
            case .jump: Command.B
            case .breakRow: Command.C
            }
        }
    }

    /// Which of the kinds of command that are left out a file has: see `leftOutNames`.
    private enum LeftOut: Int {
        case sampleLoop = 0, finetune = 1
        /// Not left out, but done otherwise: see `convert`.
        case envelope = 2
    }

    private static let leftOutNames = ["changing how a sample loops (E8x)", "tuning a sample afresh (E5x)"]

    /// A command of Digitrakker's as OpenMPT's (`ConvertMDLCommand`). The first column has 1 to 6 for
    /// its own, the second G to L, which are given here as 16 to 21; both have 7 to F.
    /// - Parameters:
    ///   - end: the place in the list of patterns just past its last, where the song ends.
    ///   - slide: given a slide of volume that only the replayer can do, as Digitrakker does it.
    private static func convert(_ command: UInt8, _ value: UInt8, end: UInt8, slide: inout IT2DigitrakkerSlide?, leftOut: inout Shortfall.Kinds) -> (Effect, UInt8) {
        switch command {
        case 0x01: return (.portaUp, value)
        case 0x02: return (.portaDown, value)
        case 0x03: return (.slideToNote, value)
        case 0x04: return (.vibrato, value)
        case 0x05: return (.arpeggio, value)
        // A tempo below 32 is a tune's way of stopping: a tick of a tempo of 1 lasts two and a half
        // seconds, and with a speed of 255 a row ten minutes. Where it is, the song ends, after the row.
        case 0x07: return value < slowestTempo ? (.jump, end) : (.tempo, value)
        case 0x08: return (.pan, (value & 0x7F) &* 2)
        case 0x09:
            // One of the tune's envelopes for the note's volume, its place or its pitch: the
            // instrument has one of each, which is turned on.
            leftOut.note(LeftOut.envelope.rawValue)
            if value < 0x40 { return (.s, 0x78) }
            if value < 0x80 { return (.s, 0x7A) }
            if value < 0xC0 { return (.s, 0x7C) }
            return (.none, value)
        case 0x0B: return (.jump, value)
        case 0x0C: return (.globalVolume, UInt8((Int(value) + 1) / 2))
        // (The row to go to is written in tens and ones.)
        case 0x0D: return (.breakRow, UInt8(truncatingIfNeeded: 10 * Int(value >> 4) + Int(value & 0x0F)))
        case 0x0E:
            let low = value & 0x0F
            switch value >> 4 {
            case 0x1: return (.panSlide, min(low, 0x0E) << 4 | 0x0F) // left, on the row's first tick
            case 0x2: return (.panSlide, 0xF0 | min(low, 0x0E)) // right
            case 0x4: return (.s, 0x30 | low) // the wave of vibrato
            case 0x5:
                leftOut.note(LeftOut.finetune.rawValue)
                return (.finetune, (value << 4) ^ 0x80)
            case 0x6: return (.s, 0xB0 | low) // a loop within the pattern
            case 0x7: return (.s, 0x40 | low) // the wave of tremolo
            case 0x8:
                leftOut.note(LeftOut.sampleLoop.rawValue)
                return (.none, value)
            case 0x9: return (.retrig, low)
            case 0xA: return (.globalVolumeSlide, UInt8(truncatingIfNeeded: 0xF0 & ((Int(low) + 1) << 3)))
            case 0xB: return (.globalVolumeSlide, UInt8((Int(low) + 1) >> 1))
            case 0xC, 0xD, 0xE: return (.s, value) // a cut, a delayed note, a row played again
            case 0xF: return (.offset, value) // which is reckoned with the other column's value
            default: return (.none, value)
            }
        case 0x0F: return (.speed, value)
        case 0x10, 0x11:
            // A slide of volume, up (G) or down (H), by so many 256ths of the whole a tick; E0 to
            // EF by so many once, at the row's start, and F0 to FF by so many 64ths once. Nought
            // goes on with the last. One that Impulse Tracker's Dxy can do is that; one finer than
            // its 64ths, or faster than its fifteen of them, is done by the replayer as Digitrakker
            // does it (see `IT2DigitrakkerSlide`), where OpenMPT takes a quarter of it in 64ths and
            // no more than fifteen, and has one of less than a quarter go on with the slide before.
            // (Impulse Tracker's fastest slides, by fifteen, are done on a row's first tick too,
            // which no other tracker does: not for these. And a fine slide down by fifteen is
            // Digitrakker's, since DFF is a fine slide up.)
            if value == 0 { return (.volumeSlide, 0) }
            let up = command == 0x10, once = value >= 0xE0
            let steps = value < 0xE0 ? Int(value) : value < 0xF0 ? Int(value & 0x0F) : Int(value & 0x0F) * 4
            let amount = steps / 4
            if steps % 4 != 0 || amount > 15 || (once && !up && amount == 15) {
                slide = IT2DigitrakkerSlide(steps: Int16(up ? steps : -steps), once: once)
                return (.volumeSlide, IT2DigitrakkerSlide.marker)
            }
            let slide = UInt8(amount)
            if !once { return (.volumeSlide, up ? slide << 4 : slide) }
            return (.volumeSlide, up ? slide << 4 | 0x0F : 0xF0 | slide)
        case 0x12: return (.retrig, value)
        case 0x13: return (.tremolo, value)
        case 0x14: return (.tremor, value)
        default: return (.none, value)
        }
    }

    /// One channel's part of a row as Impulse Tracker's replayer has it, being put together.
    private typealias Cell = IT2ForeignModule.Cell

    /// What the volume column can do of a command, if anything (OpenMPT's `ConvertToVolCommand`):
    /// exactly, or with `force` the nearest it can.
    private static func volumeColumn(_ effect: Effect, _ value: UInt8, force: Bool) -> UInt8? {
        switch effect {
        case .portaUp, .portaDown:
            if !force, value & 3 != 0 || value >= 0xE0 { return nil }
            return (effect == .portaUp ? 115 : 105) + min(value / 4, 9)
        case .slideToNote:
            if value >= 0xF0 { return 193 + 9 }
            let speeds: [UInt8] = [0, 1, 4, 8, 16, 32, 64, 96, 128, 255]
            for n in 0 ..< 10 where force ? value <= speeds[n] : value == speeds[n] { return 193 + UInt8(n) }
            return nil
        case .vibrato:
            var depth = value & 0x0F
            if force {
                depth = min(depth, 9)
            } else if depth > 9 || value & 0xF0 != 0 {
                return nil
            }
            return 203 + depth
        case .pan:
            return 128 + (value == 255 ? 64 : value / 4)
        case .volumeSlide:
            if value == 0 { return nil }
            let high = value >> 4, low = value & 0x0F
            if low == 0 { return 85 + min(high, 9) }
            if high == 0 { return 95 + min(low, 9) }
            if low == 0x0F { return 65 + min(high, 9) }
            if high == 0x0F { return 75 + min(low, 9) }
            return nil
        case .s:
            if value & 0xF0 == 0x80 { return 128 + ((value & 0x0F) << 2) + 2 }
            return nil
        default:
            return nil
        }
    }

    /// What `place` could not put in a cell: the command that had no room, if one had none, the part
    /// of a note's offset beyond what Oxx reaches, in 65,536 bytes, and a slide of volume.
    private struct Placed {
        var lost: (effect: Effect, value: UInt8)?
        var highOffset: UInt8 = 0
        /// A slide of volume that is the replayer's to do as Digitrakker does it.
        var slide: IT2DigitrakkerSlide?
    }

    /// Puts a note's volume and two commands into a cell, as OpenMPT does (`ImportMDLCommands`, with
    /// `ModCommand::FillInTwoCommands` and `CombineEffects`), but for these: a note that starts
    /// further into its sample than Oxx reaches keeps its volume; a slide to a note that only goes
    /// on, beside a slide of volume, is Impulse Tracker's Lxy; and of two commands with room for one,
    /// one that can be done elsewhere gives way (see `renderer`).
    private static func place(volume: UInt8, _ command1: UInt8, _ value1: UInt8, _ command2: UInt8, _ value2: UInt8, end: UInt8, in cell: inout Cell,
                              leftOut: inout Shortfall.Kinds) -> Placed {
        var placed = Placed()
        // (The second column's 1 to 6 are G to L.)
        let command2 = command2 >= 1 && command2 <= 6 ? command2 + 15 : command2
        var (e1, p1) = convert(command1, value1, end: end, slide: &placed.slide, leftOut: &leftOut)
        var (e2, p2) = convert(command2, value2, end: end, slide: &placed.slide, leftOut: &leftOut)
        // (The song's end makes a speed beside it nothing to keep.)
        if e1 == .jump, p1 == end, e2 == .speed { e2 = .none }
        if e2 == .jump, p2 == end, e1 == .speed { e1 = .none }
        func set(_ effect: Effect, _ value: UInt8) {
            if effect.letter != 0 { cell.set(command: effect.letter, value) }
        }

        // EFy -xx starts a note y xx 00 bytes into its sample, the two columns' values together. The
        // second column's command, if it has one, is done as well, with the same value. Where y is
        // not nought OpenMPT puts it in the volume column, in place of the volume; here it is kept
        // beside the cell (see `IT2Module.digitrakkerHighOffsets`).
        if e1 == .offset {
            let offset = Int(p1 & 0x0F) << 8 | Int(p2)
            if offset > 0xFF, e2 < .offset {
                placed.highOffset = UInt8(offset >> 8)
                p1 = UInt8(offset & 0xFF)
            } else {
                p1 = p1 & 0x0F != 0 ? 0xFF : p2
            }
            if e2 == .offset { e2 = .none }
        } else if e2 == .offset {
            let high = p2 & 0x0F
            if high != 0, e1 < .offset {
                placed.highOffset = high
                p2 = 0
            } else {
                p2 = high != 0 ? 0xFF : 0
            }
        }

        if volume != 0 { cell.set(volume: UInt8((Int(volume) + 2) / 4)) }

        // A slide of volume beside a vibrato or a slide to a note that only goes on is Impulse
        // Tracker's Kxy or Lxy.
        if e2 == .volumeSlide, e1 == .vibrato || e1 == .slideToNote, p1 == 0 {
            e1 = e1 == .vibrato ? .vibratoVolume : .slideToNoteVolume
            p1 = p2
            e2 = .none
        }

        if e1 == .none || (e1 == e2 && e1 != .s) {
            // (Digitrakker does the two in turn, so of two the same the second is what is left.)
            set(e2, p2)
            return placed
        }
        if e2 == .none {
            set(e1, p1)
            return placed
        }
        if volume == 0 {
            // One to the volume column, if either can go there: exactly, the first and then the
            // second, and then as near as it can.
            var a = (e1, p1), b = (e2, p2)
            for attempt in 0 ..< 4 {
                if let column = volumeColumn(a.0, a.1, force: attempt > 1) {
                    cell.set(volume: column)
                    set(b.0, b.1)
                    return placed
                }
                swap(&a, &b)
            }
        }
        // Room for only one: the one that matters more, as OpenMPT reckons it; but of one that can
        // be done elsewhere (see `renderer`) and one that cannot, the other.
        func elsewhere(_ effect: Effect) -> Bool {
            effect == .pan || effect == .panSlide || effect == .speed || effect == .tempo || effect == .jump || effect == .breakRow || effect == .globalVolume
        }
        let firstKept = elsewhere(e1) != elsewhere(e2) ? elsewhere(e2) : e1 > e2
        let (kept, lost) = firstKept ? ((e1, p1), (e2, p2)) : ((e2, p2), (e1, p1))
        set(kept.0, kept.1)
        placed.lost = lost
        return placed
    }

    /// The slowest tempo the replayer has.
    private static let slowestTempo: UInt8 = 32

    // MARK: Reading

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        guard isOne(data) else { throw TuneError.malformed("not an MDL file") }
        let f = ByteReader(data)
        let version = data[4]
        let parts = chunks(data)

        // MARK: The song

        guard let info = parts[id("IN")], info.count >= 91 else { throw TuneError.malformed("an MDL file without its song") }
        let title = f.dos(at: info.lowerBound, length: 32), author = f.dos(at: info.lowerBound + 32, length: 20)
        let orderCount = min(f.u16le(info.lowerBound + 52), 256), restart = f.u16le(info.lowerBound + 54)
        let globalVolume = UInt8((Int(f[info.lowerBound + 56]) + 1) / 2)
        let speed = max(f[info.lowerBound + 57], 1), tempo = max(f[info.lowerBound + 58], slowestTempo)
        let setup = (0 ..< 32).map { f[info.lowerBound + 59 + $0] }
        // (A part that ends before its list of patterns does has no list.)
        let orders = info.count >= 91 + orderCount ? (0 ..< orderCount).map { f[info.lowerBound + 91 + $0] } : []
        guard !orders.isEmpty else { throw TuneError.malformed("an MDL file with no list of patterns") }

        // The channels: as many as there are up to the last that is not switched off, or that a
        // pattern uses.
        var channelCount = 0
        for channel in 0 ..< 32 where setup[channel] & 0x80 == 0 { channelCount = channel + 1 }
        let patternsPart = parts[id("PA")]
        if let part = patternsPart {
            var at = part.lowerBound + 1
            for _ in 0 ..< Int(f[part.lowerBound]) where at < part.upperBound {
                var channels = 32
                if version >= 0x10 {
                    channels = Int(f[at])
                    at += 18
                }
                for channel in 0 ..< channels {
                    if at + 2 <= part.upperBound, f.u16le(at) > 0, channel >= channelCount, channel < 32 { channelCount = channel + 1 }
                    at += 2
                }
            }
        }
        channelCount = max(channelCount, 1)
        var pans = [UInt8](repeating: 32 | 128, count: MAX_HOST_CHANNELS)
        for channel in 0 ..< channelCount {
            let place = Int(setup[channel] & 0x7F) * 2
            pans[channel] = UInt8((place == 254 ? 256 : place) / 4) | (setup[channel] & 0x80)
        }

        // MARK: Samples

        // Each sample's header, and its sound one after another in the part that has them all. A
        // sample is named by a byte, and Impulse Tracker's replayer has less room than that: where
        // only instruments name them, they are given the replayer's numbers in turn, and only where
        // the patterns name them is a sample beyond its room left out.
        var made = (0 ..< IT2ForeignModule.sampleRoom).map { _ in IT2Sample() }
        var cutShort = Shortfall.CutShort()
        var slots = [Int](repeating: 0, count: 256)
        var slotsUsed = 0, lastSample = 0
        let renumbered = parts[id("II")] != nil
        if let part = parts[id("IS")] {
            let sound = parts[id("SA")] ?? data.count ..< data.count
            var soundAt = sound.lowerBound
            let headerSize = version < 0x10 ? 57 : 59
            var at = part.lowerBound + 1
            for _ in 0 ..< Int(f[part.lowerBound]) {
                let number = Int(f[at])
                guard number != 0, at + headerSize <= part.upperBound else { break }
                let rateAt = at + 41
                let c4Speed = version < 0x10 ? f.u16le(rateAt) : long(f, rateAt)
                let after = rateAt + (version < 0x10 ? 2 : 4)
                var length = long(f, after), loopStart = long(f, after + 4), loopEnd = loopStart + long(f, after + 8)
                let loops = long(f, after + 8) != 0, volume = f[after + 12], flags = f[after + 13]
                at += headerSize

                // (A sample of sixteen bits has its length and its loop in bytes.)
                let sixteen = flags & 1 != 0, packed = flags & 0x0C != 0
                if sixteen {
                    length /= 2
                    loopStart /= 2
                    loopEnd /= 2
                }
                // No sample is longer than what is left of the file could hold: packed, each byte of
                // eight bits takes five bits at the least, and of sixteen thirteen.
                let room = max(0, sound.upperBound - soundAt)
                var sound8: [Int8] = [], sound16: [Int16] = []
                if packed {
                    length = min(length, room * 8 / (sixteen ? 13 : 5) + 1)
                    let (used, decoded) = unpack(data, at: soundAt, end: sound.upperBound, length: length, sixteen: sixteen)
                    soundAt += used
                    if sixteen { sound16 = decoded.map { Int16(truncatingIfNeeded: $0) } } else { sound8 = decoded.map { Int8(truncatingIfNeeded: $0) } }
                } else {
                    cutShort.add(length: sixteen ? length * 2 : length, there: room)
                    length = min(length, room / (sixteen ? 2 : 1))
                    let bytes = sixteen ? length * 2 : length
                    if sixteen {
                        sound16 = (0 ..< length).map { Int16(truncatingIfNeeded: f.u16le(soundAt + $0 * 2)) }
                    } else {
                        sound8 = (0 ..< length).map { Int8(bitPattern: f[soundAt + $0]) }
                    }
                    soundAt += bytes
                }
                lastSample = max(lastSample, number)
                if slots[number] == 0 {
                    guard (renumbered ? slotsUsed : number - 1) < IT2ForeignModule.sampleRoom else { continue }
                    slotsUsed += 1
                    slots[number] = renumbered ? slotsUsed : number
                }
                made[slots[number] - 1] = IT2ForeignModule.sample(sound8: sound8, sound16: sound16, volume: version < 0x10 ? UInt8((Int(volume) + 2) / 4) : 64,
                                                                  rate: IT2ForeignModule.rate(c4Speed * 2), loops: loops, backAndForth: flags & 2 != 0,
                                                                  loopStart: loopStart, loopEnd: loopEnd)
            }
        }

        // MARK: Instruments

        // The tune's envelopes, of each kind, by their numbers.
        struct Envelope {
            var points: [(tick: Int, level: UInt8)] = []
            var sustain = 0, loopStart = 0, loopEnd = 0
            var sustains = false, loops = false
        }
        func envelopes(_ letters: String) -> [Envelope] {
            var all = [Envelope](repeating: Envelope(), count: 64)
            guard let part = parts[id(letters)], !part.isEmpty else { return all }
            var at = part.lowerBound + 1
            for _ in 0 ..< Int(f[part.lowerBound]) {
                guard at + 33 <= part.upperBound else { break }
                let number = Int(f[at])
                defer { at += 33 }
                guard number < 64 else { continue }
                var envelope = Envelope()
                var tick = -Int(f[at + 1])
                for node in 0 ..< 15 {
                    let x = Int(f[at + 1 + node * 2])
                    if x == 0 { break }
                    tick += x
                    envelope.points.append((tick, min(f[at + 2 + node * 2], 64)))
                }
                let flags = f[at + 31], loop = f[at + 32]
                envelope.loopStart = Int(loop & 0x0F)
                envelope.loopEnd = Int(loop >> 4)
                envelope.sustain = Int(flags & 0x0F)
                envelope.sustains = flags & 0x10 != 0
                envelope.loops = flags & 0x20 != 0
                all[number] = envelope
            }
            return all
        }
        /// An envelope as the replayer has one, its levels less `centre`: on, or there to be turned on.
        func envelope(_ from: Envelope, enabled: Bool, centre: Int) -> IT2Envelope {
            var made = IT2Envelope()
            guard !from.points.isEmpty else { return made }
            made.Num = UInt8(from.points.count)
            for (node, point) in from.points.enumerated() {
                made.Tick[node] = UInt16(truncatingIfNeeded: max(0, point.tick))
                made.Magnitude[node] = Int8(Int(point.level) - centre)
            }
            // (One that is not on is there all the same, for S7x to turn on.)
            made.Flags = enabled ? ENVF_ENABLED : 0
            let last = UInt8(from.points.count - 1)
            if from.loops {
                made.Flags |= ENVF_LOOP
                made.LoopBegin = min(UInt8(from.loopStart), last)
                made.LoopEnd = min(UInt8(from.loopEnd), last)
            }
            if from.sustains {
                made.Flags |= ENVF_SUSTAINLOOP
                made.SustainLoopBegin = min(UInt8(from.sustain), last)
                made.SustainLoopEnd = made.SustainLoopBegin
            }
            return made
        }

        var instruments: [IT2Instrument] = []
        var leftOut = Shortfall.Kinds()
        if let part = parts[id("II")] {
            let volumes = envelopes("VE"), places = envelopes("PE"), pitches = envelopes("FE")
            instruments = (0 ..< IT2Module.mostInstruments).map { _ in IT2Instrument() }
            var at = part.lowerBound + 1
            for _ in 0 ..< Int(f[part.lowerBound]) {
                let number = Int(f[at]), samples = Int(f[at + 1])
                let size = 2 + 32 + 14 * samples
                defer { at += size }
                guard number != 0, number <= IT2Module.mostInstruments, at + size <= part.upperBound else { continue }
                let ins = IT2Instrument()
                ins.GlobVol = 128
                ins.DefPan = 32 | 128
                ins.PitchPanCenter = 60
                var firstNote = 0
                for k in 0 ..< samples {
                    let h = at + 34 + k * 14
                    // (A sample the file has none of, among those it has, is silence for its notes,
                    // and the rest of what it says goes for the instrument all the same; one beyond
                    // the last the file has is passed over altogether. So OpenMPT has it.)
                    let named = Int(f[h]), sample = slots[named]
                    guard named != 0, named <= lastSample else { continue }
                    let lastNote = min(Int(f[h + 1]), 119)
                    if firstNote <= lastNote {
                        for note in firstNote ... lastNote { ins.SmpNoteTable[note] = UInt16(note) | UInt16(sample) << 8 }
                    }
                    firstNote = lastNote + 1
                    let volumeFlags = f[h + 3], panFlags = f[h + 5], pitchFlags = f[h + 13]
                    ins.VolEnv = envelope(volumes[Int(volumeFlags & 0x3F)], enabled: volumeFlags & 0x80 != 0, centre: 0)
                    ins.PanEnv = envelope(places[Int(panFlags & 0x3F)], enabled: panFlags & 0x80 != 0, centre: 32)
                    ins.PitchEnv = envelope(pitches[Int(pitchFlags & 0x3F)], enabled: pitchFlags & 0x80 != 0, centre: 32)
                    // (Of 65,536 a tick, at twice what OpenMPT keeps: see `IT2Player.digitrakkerFade`.)
                    ins.FadeOut = UInt16(min(0xFFFF, (f.u16le(h + 6) + 1) / 2 * 2))

                    // What the instrument says of its sample, which is the sample's from then on.
                    guard sample != 0 else { continue }
                    let s = made[sample - 1]
                    // (Without its flag, the sample has no volume of its own, and leaves the channel's as it was.)
                    s.hasVolume = volumeFlags & 0x40 != 0
                    if s.hasVolume { s.Vol = UInt8(min(64, (Int(f[h + 2]) + 2) / 4)) }
                    if panFlags & 0x40 != 0 { s.DefPan = 0x80 | UInt8((min(Int(f[h + 4]) * 2, 254) + 2) / 4) }
                    let speed = f[h + 8], depth = UInt8((Int(f[h + 9]) + 3) / 4), sweep = f[h + 10]
                    s.AutoVibratoWaveform = [0, 1, 2, 0][Int(f[h + 11] & 3)]
                    s.AutoVibratoDepth = depth
                    s.AutoVibratoSpeed = speed
                    s.AutoVibratoRate = sweep == 0 ? 255 : UInt8(min(255, (Int(depth) * 256 + Int(sweep) / 2) / Int(sweep)))
                }
                instruments[number - 1] = ins
            }
        }

        // MARK: Patterns

        // The tracks, each a channel's part of a pattern, which the patterns name: a list of what
        // each row has, or of how many rows have nothing, or are the row before, or another.
        var tracks: [Range<Int>] = [0 ..< 0]
        if let part = parts[id("TR")] {
            var at = part.lowerBound + 2
            for _ in 0 ..< f.u16le(part.lowerBound) {
                let length = f.u16le(at)
                let start = min(at + 2, part.upperBound)
                tracks.append(start ..< min(start + length, part.upperBound))
                at += 2 + length
            }
        }

        var patterns = [[UInt8]?](repeating: IT2ForeignModule.Pattern().packed(), count: IT2ForeignModule.patternRoom)
        var rows = [UInt16](repeating: 64, count: IT2ForeignModule.patternRoom)
        var noRoom = 0
        var highOffsets: [Int: UInt8] = [:], placesBeside: [Int: IT2DigitrakkerPan] = [:], slides: [Int: IT2DigitrakkerSlide] = [:]
        /// What a cell has besides what went into it: see `Placed`. A command for the whole tune that
        /// had no room goes to another channel of the row, and a place between the speakers, or a
        /// move of it, is kept beside the cell (see `IT2Module.digitrakkerPans`).
        struct Aside {
            var lost: (effect: Effect, value: UInt8)?
            var highOffset: UInt8 = 0
            var slide: IT2DigitrakkerSlide?
        }
        if let part = patternsPart {
            var at = part.lowerBound + 1
            for index in 0 ..< Int(f[part.lowerBound]) {
                var channels = 32, rowCount = 64
                if version >= 0x10 {
                    channels = Int(f[at])
                    rowCount = Int(f[at + 1]) + 1
                    at += 18
                }
                var pattern = IT2ForeignModule.Pattern(rows: rowCount)
                var aside = [Aside](repeating: Aside(), count: rowCount * 32)
                for channel in 0 ..< channels {
                    let number = f.u16le(at)
                    at += 2
                    guard number != 0, number < tracks.count, channel < channelCount else { continue }
                    let track = tracks[number]
                    var t = track.lowerBound, row = 0
                    while row < rowCount, t < track.upperBound {
                        let b = f[t]
                        t += 1
                        let x = Int(b >> 2)
                        switch b & 3 {
                        case 0:
                            row += x + 1
                        case 1:
                            // The row before, again so many times.
                            if row > 0 {
                                let before = pattern[row - 1, channel], besides = aside[(row - 1) * 32 + channel]
                                var times = x
                                repeat {
                                    pattern[row, channel] = before
                                    aside[row * 32 + channel] = besides
                                    row += 1
                                    times -= 1
                                } while row < rowCount && times >= 0
                            }
                        case 2:
                            // Another row's, by its number.
                            if row > x {
                                pattern[row, channel] = pattern[x, channel]
                                aside[row * 32 + channel] = aside[x * 32 + channel]
                            }
                            row += 1
                        default:
                            var cell = Cell()
                            func next() -> UInt8 {
                                t += 1
                                return f[t - 1]
                            }
                            if x & 1 != 0 {
                                let note = next()
                                // 1 is the lowest C, which is Impulse Tracker's 0; above 120 the key is let go.
                                if note > 120 { cell.set(note: 255) } else if note > 0 { cell.set(note: note - 1) }
                            }
                            if x & 2 != 0 {
                                let instrument = next()
                                if instrument != 0 { cell.set(instrument: instrument) }
                            }
                            var volume: UInt8 = 0, commands: UInt8 = 0, value1: UInt8 = 0, value2: UInt8 = 0
                            if x & 4 != 0 { volume = next() }
                            if x & 8 != 0 { commands = next() }
                            if x & 16 != 0 { value1 = next() }
                            if x & 32 != 0 { value2 = next() }
                            let placed = place(volume: volume, commands & 0x0F, value1, commands >> 4, value2, end: UInt8(min(orders.count, 255)), in: &cell,
                                               leftOut: &leftOut)
                            aside[row * 32 + channel] = Aside(lost: placed.lost, highOffset: placed.highOffset, slide: placed.slide)
                            pattern[row, channel] = cell
                            row += 1
                        }
                    }
                }
                // What had no room: a place between the speakers kept beside its cell, a command for the
                // whole tune moved to a channel of the row that has no command (from the last, which are
                // the ones least likely to be used), and the rest left out.
                for row in 0 ..< rowCount {
                    for channel in 0 ..< 32 {
                        let besides = aside[row * 32 + channel]
                        let place = OpenMPTSong.place(pattern: index, row: row, channel: channel)
                        if besides.highOffset != 0 { highOffsets[place] = besides.highOffset }
                        if let slide = besides.slide { slides[place] = slide }
                        guard let lost = besides.lost else { continue }
                        switch lost.effect {
                        case .pan:
                            placesBeside[place] = IT2DigitrakkerPan(to: UInt8((Int(lost.value) + 2) >> 2))
                        case .panSlide:
                            // (Digitrakker's are all fine slides, which move it once, at the row's start.)
                            placesBeside[place] = IT2DigitrakkerPan(by: lost.value & 0x0F == 0x0F ? -Int8(lost.value >> 4) : Int8(lost.value & 0x0F))
                        case .speed, .tempo, .jump, .breakRow, .globalVolume:
                            if let free = (0 ..< MAX_HOST_CHANNELS).reversed().first(where: { !pattern[row, $0].hasCommand }) {
                                var cell = pattern[row, free]
                                cell.set(command: lost.effect.letter, lost.value)
                                pattern[row, free] = cell
                            } else {
                                noRoom += 1
                            }
                        default:
                            noRoom += 1
                        }
                    }
                }
                if index < IT2ForeignModule.patternRoom {
                    patterns[index] = pattern.packed()
                    rows[index] = UInt16(rowCount)
                }
            }
        }

        var shortfalls: [String] = []
        if noRoom > 0 {
            shortfalls.append(Shortfall.some(noRoom, one: "notes has more commands than Impulse Tracker's replayer has room for, and one is left out.",
                                             many: "notes have more commands than Impulse Tracker's replayer has room for, and one of each is left out."))
        }
        if let sentence = Shortfall.commandsLeftOut(leftOut.named(leftOutNames)) { shortfalls.append(sentence) }
        if leftOut.named(["", "", "envelope"]).contains("envelope") {
            shortfalls.append("Its notes that choose one of the tune's envelopes (9xx) have their instrument's own turned on in its place.")
        }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        let madeWith = version == 0x11 ? "Digitrakker 3" : version == 0x10 ? "Digitrakker 2.3" : version == 0 ? "Digitrakker 2" : "Digitrakker"
        var flags = ITF_STEREO | ITF_COMPAT_GXX
        if !instruments.isEmpty { flags |= ITF_INSTR_MODE }
        let module = IT2Module(title: title, madeWith: madeWith, orders: orders.map { Int($0) < IT2ForeignModule.patternRoom ? $0 : 255 }, flags: flags,
                               globalVolume: min(globalVolume, 128), mixVolume: mixVolume, speed: speed, tempo: tempo, channelPans: pans, samples: made,
                               patterns: patterns, rows: rows, restart: restart, instruments: instruments, playsAsDigitrakker: true)
        module.digitrakkerHighOffsets = highOffsets
        module.digitrakkerPans = placesBeside
        module.digitrakkerSlides = slides
        return ITRenderer(module: module, format: "MDL", author: author, shortfalls: shortfalls, options: options)
    }

    /// How loud the whole is made, of Impulse Tracker's 128: set by measure, so that these files are
    /// about as loud as IT files are.
    private static let mixVolume: UInt8 = 99

    // MARK: Packed samples

    /// A sample packed as Digitrakker packs one, which begins with how many bytes it takes: each
    /// byte is the difference from the one before, kept in as few bits as it needs (for a sample of
    /// sixteen bits, each low byte is kept as it is and only the high bytes are so packed). Gives how
    /// many bytes of the file the sample took, and its sound as so many bytes or sixteen-bit numbers;
    /// what is missing from a sample that is cut short is silence.
    private static func unpack(_ data: [UInt8], at start: Int, end: Int, length: Int, sixteen: Bool) -> (used: Int, sound: [UInt16]) {
        var sound = [UInt16](repeating: 0, count: length)
        guard start + 8 <= end else { return (max(0, end - start), sound) }
        let f = ByteReader(data)
        let size = long(f, start)
        guard size >= 4 else { return (4, sound) }
        var at = start + 4
        let stop = min(end, at + size)
        var buffer: UInt32 = 0, held = 0
        /// The next so many bits, the lowest first; nil when there are no more.
        func bits(_ count: Int) -> UInt32? {
            while held < count {
                guard at < stop else { return nil }
                buffer |= UInt32(data[at]) << UInt32(held)
                at += 1
                held += 8
            }
            let value = buffer & ((1 << UInt32(count)) - 1)
            buffer >>= UInt32(count)
            held -= count
            return value
        }
        var delta: UInt8 = 0
        decoding: for j in 0 ..< length {
            var low: UInt8 = 0
            if sixteen {
                guard let byte = bits(8) else { break decoding }
                low = UInt8(byte)
            }
            guard let sign = bits(1), let short = bits(1) else { break decoding }
            var high: UInt8
            if short != 0 {
                guard let value = bits(3) else { break decoding }
                high = UInt8(value)
            } else {
                high = 8
                while true {
                    guard let bit = bits(1) else { break decoding }
                    if bit != 0 { break }
                    high &+= 0x10
                }
                guard let value = bits(4) else { break decoding }
                high &+= UInt8(value)
            }
            if sign != 0 { high = ~high }
            delta &+= high
            sound[j] = sixteen ? UInt16(low) | UInt16(delta) << 8 : UInt16(delta)
        }
        return (4 + (stop - (start + 4)), sound)
    }
}
