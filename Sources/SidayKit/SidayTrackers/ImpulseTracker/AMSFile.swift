// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the AMS loader of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see
// THIRD-PARTY.md): the layout of both kinds of file, what their commands are taken to mean and how
// their packed samples are unpacked (`soundlib/Load_ams.cpp`), with how a ProTracker command is
// taken (`soundlib/MODTools.cpp`, `soundlib/modcommand.cpp`).

/// An AMS file: the module of Velvet Studio, or of Extreme's Tracker before it.
///
/// Extreme's Tracker was a tracker for DOS by the group Extreme, which became Velvet
/// Development and made Velvet Studio after it; both kept their modules in files called AMS, of two
/// kinds that share only the way their patterns are packed. Extreme's Tracker's (which begin
/// "Extreme") have samples and no instruments, up to 32 channels and ProTracker's commands and some
/// more. Velvet Studio's (which begin "AMShdr") have 32 channels; instruments that are a sample for
/// each note, with envelopes for volume, place and pitch (a vibrato drawn by hand, which goes up or
/// down by up to two semitones), a fade, and instruments that are another's samples played with
/// other settings ("shadows"); samples of eight bits or sixteen that loop forwards, back and forth or
/// backwards, packed if their maker wished; a tempo that is a fraction; and as many commands to a
/// note as a cell has room for, ProTracker's and more of its own. Velvet Studio's source was made
/// public in 2013.
///
/// Both are played here by Impulse Tracker's replayer, as OpenMPT plays them: it reads them into the
/// shape of an IT file with "old effects" and "compatible Gxx" on, and plays them by Impulse Tracker's
/// rules, but where its player asks whether a file is an IT file, and these are not (see
/// `IT2Module.openMPTForeign`); and its player has three ways for these files alone: an envelope for
/// pitch that goes by sixteenths of a semitone, a key let go by a command, and a sample played
/// backwards (`IT2Module.velvetStudio`).
///
/// What does not go over as it stands:
///  - Many commands to a note. Impulse Tracker has room for one, and a volume column: they are put
///    there as OpenMPT puts them, one after another, which leaves out those that matter less by
///    OpenMPT's reckoning, where the volume column has no room. The file says how many were.
///  - The volumes of samples, of 127, which are Impulse Tracker's of 64.
/// Not played, as OpenMPT does not play them: an envelope's speed, the fraction of a tempo that a
/// command sets, a key let go after so many ticks (which is let go at once), and breaking a sample's
/// loop (E80); nor a sample played backwards from a place in it, a glissando (E3x) and a finetune
/// (E5x), which OpenMPT plays and Impulse Tracker's replayer has not got.
enum AMSFile {
    private typealias Effect = OpenMPTCell.Effect

    /// True for a file that says it is one of either kind.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.starts(with: Array("AMShdr".utf8) + [0x1A]) || data.starts(with: Array("Extreme".utf8))
    }

    /// Four bytes as a length, the first the least; one too large to be any is brought down to
    /// where it is still too large. (A whole number in a browser has 32 bits.)
    private static func long(_ f: ByteReader, _ i: Int) -> Int {
        let high = f.u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16le(i)
    }

    // MARK: Commands

    /// Which of the kinds of command that are left out a file has: see `leftOutNames`.
    private enum LeftOut: Int {
        case breakLoop = 0, glissando, finetune, backwardsFrom, fractionalTempo, keyOffLater
    }

    private static let leftOutNames = ["breaking a sample's loop (E80)", "glissando (E3x)", "tuning a note afresh (E5x)",
                                       "playing a sample backwards from a place in it", "the fraction of a tempo (1Fxx)",
                                       "letting a key go after so many ticks (20xx), which lets it go at once"]

    /// OpenMPT's commands for those of Velvet Studio's own, from 10 on.
    private static let extended: [Effect] = [
        .s, .portaUp, .portaDown, .retrig, .none, .slideToNoteVolume, .vibratoVolume, .none, .panSlide, .none, .volumeSlide, .none,
        .channelVolume, .breakRow, .s, .none, .keyOff, .portaUp, .portaDown, .none, .none, .none, .none, .none, .none, .none,
        .globalVolumeSlide, .none, .globalVolume,
    ]

    /// ProTracker's commands, 0 to F, as OpenMPT takes them (`ConvertModCommand`).
    private static let proTracker: [Effect] = [
        .arpeggio, .portaUp, .portaDown, .slideToNote, .vibrato, .slideToNoteVolume, .vibratoVolume, .tremolo, .pan, .offset,
        .volumeSlide, .jump, .volume, .breakRow, .none, .tempo,
    ]

    /// ProTracker's Exy as OpenMPT makes it one of Scream Tracker's (`ExtendedMODtoS3MEffect`); and
    /// whether it cuts the note instead.
    private static func extendedProTracker(_ value: UInt8, leftOut: inout Shortfall.Kinds) -> (Effect, UInt8, cut: Bool) {
        let x = value & 0x0F
        switch value >> 4 {
        case 0x0: return (.none, value, false)
        case 0x1: return (.portaUp, value | 0xF0, false)
        case 0x2: return (.portaDown, value | 0xF0, false)
        case 0x3:
            // (Impulse Tracker has no glissando.)
            if x != 0 { leftOut.note(LeftOut.glissando.rawValue) }
            return (.none, value, false)
        case 0x4: return (.s, 0x30 | x & 3, false)
        case 0x5:
            // (Scream Tracker's finetune, which OpenMPT makes it, sets a sample's rate outright.)
            leftOut.note(LeftOut.finetune.rawValue)
            return (.none, value, false)
        case 0x6: return (.s, 0xB0 | x, false)
        case 0x7: return (.s, 0x40 | x & 3, false)
        case 0x9: return (.retrig, x, false)
        case 0xA: return x != 0 ? (.volumeSlide, x << 4 | 0x0F, false) : (.none, value, false)
        case 0xB: return x != 0 ? (.volumeSlide, 0xF0 | min(x, 0x0E), false) : (.none, value, false)
        case 0xC: return value == 0xC0 ? (.none, value, true) : (.s, value, false)
        case 0xD: return value == 0xD0 ? (.none, value, false) : (.s, value, false)
        default: return (.s, value, false)
        }
    }

    /// Of two commands, the one that a cell keeps the other's meaning in, where OpenMPT joins them
    /// (`CombineEffects`): a slide of volume with a vibrato or a slide to a note that goes on as it
    /// was. The second is then none.
    private static func combine(_ first: inout (Effect, UInt8), _ second: inout (Effect, UInt8)) {
        if first.0 == .volumeSlide, second.0 == .vibrato || second.0 == .slideToNoteVolume, second.1 == 0 {
            first.0 = second.0 == .vibrato ? .vibratoVolume : .slideToNoteVolume
            second = (.none, 0)
        } else if second.0 == .volumeSlide, first.0 == .vibrato || first.0 == .slideToNoteVolume, first.1 == 0 {
            first = (first.0 == .vibrato ? .vibratoVolume : .slideToNoteVolume, second.1)
            second = (.none, 0)
        } else if first.0 == .offset, second.0 == .s, second.1 == 0x9F {
            first.0 = .reverseOffset
            second = (.none, 0)
        } else if first.0 == .s, first.1 == 0x9F, second.0 == .offset {
            first = (.reverseOffset, second.1)
            second = (.none, 0)
        }
    }

    /// A pattern as both kinds of file keep one: for each row, each channel that has anything, and
    /// on it a note and an instrument, and as many commands as follow, each a volume or a command
    /// and its value. Each is put into the cell as OpenMPT puts it, after what is there already
    /// (`ReadAMSPattern`). Gives the cells, row by row, how many commands were left out, and how many
    /// notes were too high, and are a semitone lower.
    private static func readPattern(_ f: ByteReader, from start: Int, to end: Int, rows: Int, newer: Bool, leftOut: inout Shortfall.Kinds)
        -> (cells: [OpenMPTCell], lost: Int, tooHigh: Int) {
        var cells = [OpenMPTCell](repeating: OpenMPTCell(), count: rows * 32)
        var lost = 0, tooHigh = 0
        var p = start
        for row in 0 ..< rows {
            while p < end {
                let flags = f[p]
                p += 1
                if flags == 0xFF { break }
                let index = row * 32 + Int(flags & 0x1F)
                var cell = cells[index]
                var more = true
                if flags & 0x40 == 0 {
                    let byte = f[p]
                    more = byte & 0x80 != 0
                    let note = Int(byte & 0x7F)
                    if note == 1 {
                        cell.note = 255
                    } else if newer, note >= 2, note <= 121 {
                        cell.note = UInt8(note - 2)
                    } else if !newer, note >= 12, note <= 108 {
                        // (The highest, C-10, is beyond Impulse Tracker's notes.)
                        if note + 12 > 119 { tooHigh += 1 }
                        cell.note = UInt8(min(note + 12, 119))
                    }
                    cell.instrument = f[p + 1]
                    p += 2
                }
                while more, p < end {
                    let command = f[p]
                    p += 1
                    more = command & 0x80 != 0
                    let effect = Int(command & 0x3F)
                    if command & 0x40 != 0 {
                        cell.column = .volume(min(UInt8(effect), 64))
                        continue
                    }
                    let value = f[p]
                    p += 1
                    var made: (Effect, UInt8) = (cell.effect, value)
                    if effect < 0x10 {
                        if effect == 0, value == 0 {
                            made = (.none, 0)
                        } else if effect == 0x0F, value < 0x20 {
                            made = (.speed, value)
                        } else if effect == 0x0E {
                            if value == 0x80 {
                                leftOut.note(LeftOut.breakLoop.rawValue)
                                made = (.none, value)
                            } else {
                                let converted = extendedProTracker(value, leftOut: &leftOut)
                                made = (converted.0, converted.1)
                                if converted.cut { cell.note = 254 }
                            }
                        } else {
                            made = (proTracker[effect], value)
                            switch made.0 {
                            case .breakRow: made.1 = (value >> 4) * 10 + value & 0x0F
                            case .pan: made.1 = (value & 0x0F) * 0x11
                            case .volume:
                                cell.column = .volume(UInt8(min((Int(value) + 1) / 2, 64)))
                                made = (.none, value)
                            default: break
                            }
                        }
                    } else if effect < 0x10 + extended.count {
                        made = (extended[effect - 0x10], value)
                        switch effect {
                        case 0x10:
                            // Forwards and backwards.
                            made = value <= 1 ? (.s, 0x9E | value) : (.none, value)
                        case 0x11, 0x12:
                            made.1 = min(0x0F, value) | 0xE0
                        case 0x15, 0x16:
                            made.1 = UInt8(min(0x10, Int(value) + 1) / 2) | 0xF0
                        case 0x1E:
                            switch value >> 4 {
                            case 0x1: made = (.portaUp, value | 0xF0)
                            case 0x2: made = (.portaDown, value | 0xF0)
                            case 0xA: made = (.volumeSlide, UInt8((Int(value & 0x0F) + 1) / 2) << 4 | 0x0F)
                            case 0xB: made = (.volumeSlide, UInt8((Int(value & 0x0F) + 1) / 2) | 0xF0)
                            default: made = (.none, value)
                            }
                        case 0x1C:
                            made.1 = UInt8(min((Int(value) + 1) / 2, 64))
                        case 0x1F:
                            if value != 0 { leftOut.note(LeftOut.fractionalTempo.rawValue) }
                        case 0x20:
                            if value != 0 { leftOut.note(LeftOut.keyOffLater.rawValue) }
                        default:
                            break
                        }
                    }
                    // What was there before, and what is new: joined where they can be, and else the
                    // one that matters more, with the other in the volume column if it is free.
                    var before = (cell.effect, cell.value)
                    combine(&made, &before)
                    if before.0 > made.0 {
                        if cell.column == nil {
                            cell.column = OpenMPTCell.column(made.0, made.1, force: true)
                            if cell.column == nil, made.0 != .none { lost += 1 }
                        } else if made.0 != .none {
                            lost += 1
                        }
                        made = before
                    } else if before.0 != .none {
                        lost += 1
                    }
                    (cell.effect, cell.value) = made
                    if made.0 == .reverseOffset { leftOut.note(LeftOut.backwardsFrom.rawValue) }
                }
                cells[index] = cell
                if flags & 0x80 != 0 { break }
            }
        }
        return (cells, lost, tooHigh)
    }

    /// The cells as Impulse Tracker's pattern; Velvet Studio's key let go is the replayer's own
    /// command for it (see `IT2Player.InitCommandVelvetKeyOff`). Says how many commands had no room.
    private static func packed(_ cells: [OpenMPTCell], rows: Int) -> (pattern: [UInt8], lost: Int) {
        var pattern = IT2ForeignModule.Pattern(rows: rows)
        var lost = 0
        for row in 0 ..< rows {
            for channel in 0 ..< 32 {
                var cell = cells[row * 32 + channel]
                let keyOff = cell.effect == .keyOff
                if keyOff { cell.effect = .none }
                var (made, missing) = cell.cell()
                if keyOff { made.set(command: velvetKeyOff, 0) }
                if missing != nil, missing != .reverseOffset { lost += 1 }
                pattern[row, channel] = made
            }
        }
        return (pattern.packed(), lost)
    }

    /// The command that is Velvet Studio's key let go, beyond Impulse Tracker's letters.
    private static let velvetKeyOff: UInt8 = 27

    // MARK: Samples

    /// A sample as either kind of file keeps it, before its sound.
    private struct Sound {
        var length = 0, loopStart = 0, loopEnd = 0
        var rate = 8363, volume = 0, pan: Int?
        var sixteen = false, packed = false, loops = false, backAndForth = false, backwards = false
        /// For a shadow, the instrument whose sample it plays (from 1) and which of its samples; 0 for none.
        var shadowOf = 0, shadowSample = 0
        var frames8: [Int8] = [], frames16: [Int16] = []
    }

    /// A sample's rate from the file's rate for C-4, the semitones it is moved by and its finetune
    /// (of 16, the low half of a byte, as ProTracker's), as OpenMPT reckons it, in whole numbers.
    private static func rate(_ c4: Int, tone: Int, finetune: UInt8) -> Int {
        let fine = Int(Int8(bitPattern: finetune << 4))
        let moved = UInt32((pow(2.0, (Double(tone) * 128 + Double(fine)) / (12 * 128)) * 8363).rounded())
        let c5 = UInt32(truncatingIfNeeded: (c4 == 0 ? 8363 : c4) * 2)
        return Int(c5 &* moved / 8363)
    }

    /// A sample's sound, which begins at `at`: as it is, or packed (`unpack`). Gives how many bytes it
    /// took. A sample the file ends before has the rest of it silent.
    private static func readSound(_ data: [UInt8], at: Int, _ s: inout Sound, cutShort: inout Shortfall.CutShort) -> Int {
        let f = ByteReader(data)
        let width = s.sixteen ? 2 : 1
        let left = data.count - at
        if s.packed {
            guard left > 9 else {
                s.length = 0
                return 0
            }
            let size = long(f, at + 4), character = Int8(bitPattern: f[at + 8])
            // (No more than the file could unpack to, as OpenMPT reckons it.)
            let most = min(size, left) * 85 / width
            if s.length > most { s.length = most }
            let there = max(0, min(size, left - 9))
            if there < size { cutShort.add(length: s.length * width, there: there * 85) }
            let bytes = unpack(Array(data[(at + 9) ..< (at + 9 + there)]), length: s.length * width, character: character)
            if s.sixteen {
                s.frames16 = (0 ..< s.length).map { Int16(bitPattern: UInt16(bytes[$0 * 2]) | UInt16(bytes[$0 * 2 + 1]) << 8) }
            } else {
                s.frames8 = bytes.map { Int8(bitPattern: $0) }
            }
            return 9 + there
        }
        cutShort.add(length: s.length * width, there: left)
        let frames = max(0, min(s.length, left / width))
        if s.sixteen {
            s.frames16 = (0 ..< frames).map { Int16(truncatingIfNeeded: f.u16le(at + $0 * 2)) }
        } else {
            s.frames8 = (0 ..< frames).map { Int8(bitPattern: f[at + $0]) }
        }
        return min(left, s.length * width)
    }

    /// A packed sample, as Extreme's Tracker and Velvet Studio pack one (OpenMPT's `AMSUnpack`): runs
    /// of the same byte, marked by the file's own character, for bytes whose bits are kept a bit at a
    /// time across the whole sample, the top bit of every byte first, of differences from the byte
    /// before. What is missing from a sample cut short is silence.
    private static func unpack(_ source: [UInt8], length: Int, character: Int8) -> [UInt8] {
        var runs = [UInt8](repeating: 0, count: length)
        var size = length
        do {
            var i = source.count, j = length, input = 0, output = 0
            while i != 0, j != 0 {
                var byte = Int8(bitPattern: source[input])
                input += 1
                i -= 1
                if i != 0, byte == character {
                    var count = Int(source[input])
                    input += 1
                    count = min(count, j)
                    i -= 1
                    if i != 0, count != 0 {
                        byte = Int8(bitPattern: source[input])
                        input += 1
                        i -= 1
                        for _ in 0 ..< count {
                            runs[output] = UInt8(bitPattern: byte)
                            output += 1
                            j -= 1
                        }
                    } else {
                        runs[output] = UInt8(bitPattern: character)
                        output += 1
                        j -= 1
                    }
                } else {
                    runs[output] = UInt8(bitPattern: byte)
                    output += 1
                    j -= 1
                }
            }
            size -= j
        }
        var bytes = [UInt8](repeating: 0, count: length)
        guard length > 0 else { return bytes }
        do {
            var bitcount: UInt16 = 0x80, k = 0, dh: UInt16 = 0
            for i in 0 ..< size {
                let al = UInt16(runs[i])
                dh = 0
                for count: UInt16 in 0 ..< 8 {
                    var bl = al & bitcount
                    bl = (bl | bl << 8) >> ((dh &+ 8 &- count) & 7)
                    bitcount = ((bitcount | bitcount << 8) >> 1) & 0xFF
                    bytes[k] |= UInt8(bl & 0xFF)
                    k += 1
                    if k >= length {
                        k = 0
                        dh += 1
                    }
                }
                bitcount = ((bitcount | bitcount << 8) >> (dh & 15)) & 0xFF
            }
        }
        var old: Int8 = 0
        for i in 0 ..< size {
            var difference = Int(bytes[i])
            if difference != 128, difference & 0x80 != 0 { difference = -(difference & 0x7F) }
            old = old &- Int8(truncatingIfNeeded: difference)
            bytes[i] = UInt8(bitPattern: old)
        }
        return bytes
    }

    /// The sample as the replayer holds one.
    private static func made(_ s: Sound) -> IT2Sample {
        let frames = s.sixteen ? s.frames16.count : s.frames8.count
        let length = min(s.length, frames)
        let loopStart = min(s.loopStart, length), loopEnd = min(s.loopEnd, length)
        let made = IT2ForeignModule.sample(sound8: s.sixteen ? [] : Array(s.frames8.prefix(length)), sound16: s.sixteen ? Array(s.frames16.prefix(length)) : [],
                                           volume: UInt8((s.volume + 2) / 4), rate: UInt32(max(0, min(s.rate, 9_999_999))), loops: s.loops,
                                           backAndForth: s.backAndForth, loopStart: loopStart, loopEnd: loopEnd, pan: s.pan.map { UInt8($0 / 4) })
        made.reversed = s.backwards && s.loops && loopStart < loopEnd
        return made
    }

    // MARK: Reading

    /// A string as these files keep one: its length in a byte, and then it.
    private static func string(_ f: ByteReader, _ at: inout Int) -> String {
        let length = Int(f[at])
        defer { at += 1 + length }
        return f.dos(at: at + 1, length: length)
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        if data.starts(with: Array("Extreme".utf8)) { return try extreme(data, options: options) }
        guard data.starts(with: Array("AMShdr".utf8) + [0x1A]) else { throw TuneError.malformed("not an AMS file") }
        let f = ByteReader(data)
        var at = 7
        let title = string(f, &at)
        let minor = f[at], major = f[at + 1], instrumentCount = Int(f[at + 2]), patternCount = f.u16le(at + 3), orderCount = f.u16le(at + 5)
        at += 7
        guard major == 2, minor <= 2 else { throw TuneError.unsupported("an AMS file of a version of Velvet Studio that is not known") }
        guard data.count >= at + 36 + 11 + instrumentCount * 2 + orderCount * 2 + patternCount * 4 else { throw TuneError.malformed("an AMS file that ends too soon") }

        var tempo = 125 * OpenMPTSong.tempoUnit, speed: UInt8 = 6, songFlags = 0
        if minor >= 2 {
            let raw = max(32 << 8, f.u16le(at))
            tempo = raw * OpenMPTSong.tempoUnit >> 8
            speed = max(1, f[at + 2])
            songFlags = f.u16le(at + 6)
            at += 8
        } else {
            tempo = Int(max(32, f[at])) * OpenMPTSong.tempoUnit
            speed = max(1, f[at + 1])
            songFlags = Int(f[at + 2])
            at += 3
        }

        // MARK: Instruments and their samples' headers

        var leftOut = Shortfall.Kinds()
        var sounds: [Sound] = []
        var firstSample: [Int] = []
        var instruments: [IT2Instrument] = []
        var tooMany = 0
        for _ in 0 ..< instrumentCount {
            guard at < data.count else { break }
            let ins = IT2Instrument()
            instruments.append(ins)
            ins.GlobVol = 128
            _ = string(f, &at)
            let sampleCount = Int(f[at])
            at += 1
            guard sampleCount > 0 else { continue }
            var assignment = [Int](repeating: 0, count: 120)
            if minor > 0 {
                for note in 0 ..< 120 { assignment[note] = Int(f[at + note]) }
                at += 120
            } else {
                for note in 0 ..< 96 { assignment[note + 12] = Int(f[at + note]) }
                at += 96
            }
            let first = sounds.count + 1
            for note in 0 ..< 120 {
                let sample = first + assignment[note]
                ins.SmpNoteTable[note] = UInt16(sample <= IT2ForeignModule.sampleRoom ? sample : 0) << 8 | UInt16(note)
            }
            // The envelopes, each with its speed (which OpenMPT leaves out), its hold and loop, and
            // its points, each a tick after the last and a level.
            var envelopes: [(points: [(tick: Int, value: Int)], sustain: Int, loopStart: Int, loopEnd: Int)] = []
            for _ in 0 ..< 3 {
                let count = Int(f[at + 4])
                var points: [(tick: Int, value: Int)] = []
                if count > 1 {
                    var tick = 0
                    for n in 0 ..< min(count, 64) {
                        let node = at + 5 + n * 3
                        if n != 0 { tick += max(1, Int(f[node]) | Int(f[node + 1] & 1) << 8) }
                        points.append((tick, Int(f[node + 2])))
                    }
                }
                envelopes.append((points, Int(f[at + 1]), Int(f[at + 2]), Int(f[at + 3])))
                at += 5 + count * 3
            }
            let shadow = Int(f[at]), vibratoAndFade = f.u16le(at + 1), envelopeFlags = f.u16le(at + 3)
            at += 5
            ins.FadeOut = UInt16(vibratoAndFade & 0xFFF)
            let vibratoAmplitude = 1 << ((vibratoAndFade & 0x3000) >> 12)
            for kind in 0 ..< 3 {
                let (points, sustain, loopStart, loopEnd) = envelopes[kind]
                let flags = envelopeFlags >> (kind * 3)
                var envelope = IT2Envelope()
                var sustains = flags & 2 != 0, loops = flags & 1 != 0
                var holdStart = sustain, holdEnd = sustain
                // A loop that ends when the key is let go is the hold of the envelope, between its ends.
                if !sustains, loops, envelopeFlags & (1 << (9 - kind * 2)) != 0 {
                    holdStart = loopStart
                    holdEnd = loopEnd
                    sustains = true
                    loops = false
                }
                if !points.isEmpty {
                    let last = points.count - 1
                    envelope.Num = UInt8(points.count)
                    // (Up to 64 points, more than an IT file's envelope has room for.)
                    if points.count > envelope.Tick.count {
                        envelope.Tick = [UInt16](repeating: 0, count: points.count)
                        envelope.Magnitude = [Int8](repeating: 0, count: points.count)
                    }
                    for (n, point) in points.enumerated() {
                        envelope.Tick[n] = UInt16(min(point.tick, 0xFFFF))
                        switch kind {
                        case 0: envelope.Magnitude[n] = Int8(min(64, (point.value * 64 + 64) / 127))
                        case 1: envelope.Magnitude[n] = Int8(min(64, (point.value * 64 + 128) / 255)) - 32
                        default:
                            // (Kept less 128, as `IT2Player.velvetPitchEnvelope` takes it.)
                            let moved = Int(Int8(truncatingIfNeeded: point.value - 128)) * vibratoAmplitude + 4
                            envelope.Magnitude[n] = Int8(truncatingIfNeeded: (moved >= 0 ? moved : moved - 7) / 8)
                        }
                    }
                    // (As OpenMPT makes any envelope fit to be played: its loops within its points.)
                    let end = min(loopEnd, last), begin = min(loopStart, end)
                    let holdLast = min(holdEnd, last), holdFirst = min(holdStart, holdLast)
                    envelope.LoopBegin = UInt8(begin)
                    envelope.LoopEnd = UInt8(end)
                    envelope.SustainLoopBegin = UInt8(holdFirst)
                    envelope.SustainLoopEnd = UInt8(holdLast)
                    if flags & 4 != 0 { envelope.Flags |= ENVF_ENABLED }
                    if loops { envelope.Flags |= ENVF_LOOP }
                    if sustains { envelope.Flags |= ENVF_SUSTAINLOOP }
                }
                if kind == 0 { ins.VolEnv = envelope } else if kind == 1 { ins.PanEnv = envelope } else { ins.PitchEnv = envelope }
            }
            firstSample.append(first)
            for index in 0 ..< sampleCount {
                _ = string(f, &at)
                let h = at
                at += 20
                var s = Sound()
                s.length = long(f, h)
                let sampleFlags = f[h + 19]
                s.loopStart = min(long(f, h + 4), s.length)
                s.loopEnd = min(long(f, h + 8), s.length)
                s.rate = rate(f.u16le(h + 15), tone: Int(Int8(bitPattern: f[h + 17])), finetune: f[h + 14] & 0x0F)
                s.volume = (Int(min(f[h + 18], 127)) * 256 + 64) / 127
                if f[h + 14] & 0xF0 != 0 { s.pan = Int(f[h + 14] & 0xF0) }
                s.sixteen = sampleFlags & 0x04 != 0
                s.packed = sampleFlags & 0x03 != 0
                if sampleFlags & 0x08 != 0, s.loopStart < s.loopEnd {
                    s.loops = true
                    s.backAndForth = sampleFlags & 0x10 != 0
                    s.backwards = sampleFlags & 0x40 != 0
                }
                s.shadowOf = shadow
                s.shadowSample = index
                if sounds.count < IT2ForeignModule.sampleRoom {
                    sounds.append(s)
                } else {
                    tooMany += 1
                }
            }
        }

        // MARK: The rest of the header

        let author = string(f, &at)
        for _ in 0 ..< 32 { _ = string(f, &at) }
        // The tune's description, packed.
        guard at + 11 <= data.count else { throw TuneError.malformed("an AMS file that ends too soon") }
        let described = long(f, at)
        at += 11
        if described > 11, at + described - 11 <= data.count { at += described - 11 }
        let orders = orderList(f, &at, count: orderCount)

        // MARK: Patterns, and the samples' sounds

        var lost = 0
        var patterns = [[UInt8]?](repeating: nil, count: patternCount)
        var rowCounts = [UInt16](repeating: 64, count: patternCount)
        for index in 0 ..< patternCount {
            guard at + 4 <= data.count else { break }
            let start = at + 4, end = min(data.count, start + long(f, at))
            at = end
            guard start < end else { continue }
            let rows = Int(f[start]) + 1
            var p = start + 2
            _ = string(f, &p)
            let read = readPattern(f, from: p, to: end, rows: rows, newer: true, leftOut: &leftOut)
            let (pattern, missing) = packed(read.cells, rows: rows)
            lost += read.lost + missing
            patterns[index] = pattern
            rowCounts[index] = UInt16(rows)
        }

        var cutShort = Shortfall.CutShort()
        for i in sounds.indices where sounds[i].shadowOf == 0 {
            at += readSound(data, at: at, &sounds[i], cutShort: &cutShort)
        }
        // A shadow plays another instrument's sample, with its own settings but for its bits.
        for i in sounds.indices where sounds[i].shadowOf != 0 {
            let source = sounds[i].shadowOf - 1
            guard source < firstSample.count else { continue }
            let from = firstSample[source] + sounds[i].shadowSample - 1
            guard from >= 0, from < sounds.count, sounds[from].shadowOf == 0 else { continue }
            let original = sounds[from]
            let length = original.sixteen ? original.frames16.count : original.frames8.count
            guard length > 0 else { continue }
            sounds[i].sixteen = original.sixteen
            sounds[i].length = length
            sounds[i].frames8 = original.frames8
            sounds[i].frames16 = original.frames16
        }

        var shortfalls: [String] = []
        let module = assemble(title: title, madeWith: "Velvet Studio 2.0\(minor)", orders: orders, patterns: patterns, rows: rowCounts,
                              samples: sounds.map(made), instruments: instruments, tempo: tempo, speed: speed, linear: songFlags & 0x40 != 0,
                              shortfalls: &shortfalls, lost: lost, tooMany: tooMany, leftOut: leftOut, cutShort: cutShort)
        return ITRenderer(module: module, format: "AMS", author: author, shortfalls: shortfalls, options: options)
    }

    /// The list of patterns, of as many places as the file says, if it has them all; a pattern's
    /// number of 65,535 ends it.
    private static func orderList(_ f: ByteReader, _ at: inout Int, count: Int) -> [Int] {
        guard at + count * 2 <= f.count else { return [] }
        defer { at += count * 2 }
        return (0 ..< count).map { f.u16le(at + $0 * 2) }
    }

    /// An Extreme's Tracker module: samples and no instruments, up to 32 channels, patterns of 64 rows.
    private static func extreme(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        let f = ByteReader(data)
        let minor = f[7], major = f[8], channelCount = Int(f[9] & 0x1F) + 1, sampleCount = Int(f[10])
        let patternCount = f.u16le(11), orderCount = f.u16le(13), extra = f.u16le(16)
        guard major == 1 else { throw TuneError.unsupported("an AMS file of a version of Extreme's Tracker that is not known") }
        guard data.count >= 18 + extra + 3 + sampleCount * 18 + orderCount * 2 + patternCount * 4 else { throw TuneError.malformed("an AMS file that ends too soon") }
        var at = 18 + extra
        var sounds: [Sound] = []
        for _ in 0 ..< sampleCount {
            let h = at
            at += 17
            var s = Sound()
            s.length = long(f, h)
            s.loopStart = min(long(f, h + 4), s.length)
            s.loopEnd = min(long(f, h + 8), s.length)
            s.volume = (Int(min(f[h + 15], 127)) * 256 + 64) / 127
            if f[h + 12] & 0xF0 != 0 { s.pan = Int(f[h + 12] & 0xF0) }
            s.rate = rate(f.u16le(h + 13), tone: 0, finetune: f[h + 12] & 0x0F)
            s.loops = s.loopStart < s.loopEnd
            s.sixteen = f[h + 16] & 0x84 != 0
            s.packed = f[h + 16] & 0x03 != 0
            sounds.append(s)
        }
        let title = string(f, &at)
        for _ in 0 ..< sampleCount { _ = string(f, &at) }
        for _ in 0 ..< channelCount { _ = string(f, &at) }
        for _ in 0 ..< patternCount { _ = string(f, &at) }
        // The tune's description, packed.
        let described = f.u16le(at)
        at += 2
        if described > 0, at + described <= data.count { at += described }
        let orders = orderList(f, &at, count: orderCount)

        var leftOut = Shortfall.Kinds()
        var lost = 0, tooHigh = 0
        var patterns = [[UInt8]?](repeating: nil, count: patternCount)
        for index in 0 ..< patternCount {
            guard at + 4 <= data.count else { break }
            let start = at + 4, end = min(data.count, start + long(f, at))
            at = end
            let read = readPattern(f, from: start, to: end, rows: 64, newer: false, leftOut: &leftOut)
            var cells = read.cells
            // (Only so many channels.)
            for i in cells.indices where i % 32 >= channelCount { cells[i] = OpenMPTCell() }
            let (pattern, missing) = packed(cells, rows: 64)
            lost += read.lost + missing
            tooHigh += read.tooHigh
            patterns[index] = pattern
        }
        var cutShort = Shortfall.CutShort()
        for i in sounds.indices {
            at += readSound(data, at: at, &sounds[i], cutShort: &cutShort)
        }
        var shortfalls: [String] = []
        if tooHigh > 0 {
            shortfalls.append(Shortfall.some(tooHigh, one: "notes is higher than Impulse Tracker's replayer plays, and is played a semitone lower.",
                                             many: "notes are higher than Impulse Tracker's replayer plays, and are played a semitone lower."))
        }
        let module = assemble(title: title, madeWith: "Extreme's Tracker \(major).\(minor)", orders: orders, patterns: patterns,
                              rows: [UInt16](repeating: 64, count: patternCount), samples: Array(sounds.prefix(IT2ForeignModule.sampleRoom)).map(made),
                              instruments: [], tempo: 125 * OpenMPTSong.tempoUnit, speed: 6, linear: false, shortfalls: &shortfalls, lost: lost,
                              tooMany: max(0, sounds.count - IT2ForeignModule.sampleRoom), leftOut: leftOut, cutShort: cutShort)
        return ITRenderer(module: module, format: "AMS", shortfalls: shortfalls, options: options)
    }

    /// The module of either kind, from what was read: the patterns that the list plays, numbered as it
    /// first plays them (a file can have more than Impulse Tracker's numbers reach); and what the
    /// file says of what is not played.
    private static func assemble(title: String, madeWith: String, orders: [Int], patterns: [[UInt8]?], rows: [UInt16], samples: [IT2Sample],
                                 instruments: [IT2Instrument], tempo: Int, speed: UInt8, linear: Bool, shortfalls: inout [String], lost: Int,
                                 tooMany: Int, leftOut: Shortfall.Kinds, cutShort: Shortfall.CutShort) -> IT2Module {
        var numbers: [Int: Int] = [:]
        var list: [UInt8] = []
        var kept: [[UInt8]?] = [], keptRows: [UInt16] = []
        var listTooLong = false, tooManyPatterns = false
        for pattern in orders {
            guard list.count < IT2Module.MAX_ORDERS - 1 else {
                listTooLong = true
                break
            }
            // A pattern the file does not have ends the song, as it does to OpenMPT.
            guard pattern < patterns.count, let data = patterns[pattern] else {
                list.append(255)
                continue
            }
            if let number = numbers[pattern] {
                list.append(UInt8(number))
            } else if kept.count < IT2ForeignModule.patternRoom {
                numbers[pattern] = kept.count
                list.append(UInt8(kept.count))
                kept.append(data)
                keptRows.append(rows[pattern])
            } else {
                tooManyPatterns = true
                list.append(255)
            }
        }
        while kept.count < IT2Module.MAX_PATTERNS {
            kept.append(nil)
            keptRows.append(64)
        }
        var allSamples = samples
        while allSamples.count < IT2Module.MAX_SAMPLES { allSamples.append(IT2ForeignModule.sample(volume: 0, rate: 8363)) }
        var allInstruments = instruments
        if !allInstruments.isEmpty {
            while allInstruments.count < IT2Module.MAX_INSTRUMENTS { allInstruments.append(IT2Instrument()) }
        }

        if lost > 0 {
            shortfalls.append(Shortfall.some(lost, one: "commands has no room beside the note's others, and is left out.",
                                             many: "commands have no room beside their notes' others, and are left out."))
        }
        if tooMany > 0 {
            shortfalls.append(Shortfall.some(tooMany, one: "samples is beyond the most there is room for, and is left out.",
                                             many: "samples are beyond the most there is room for, and are left out."))
        }
        if listTooLong { shortfalls.append("Its list of patterns is longer than there is room for, and the end of it is left out.") }
        if tooManyPatterns { shortfalls.append("It plays more patterns than there is room for, and those beyond are left out.") }
        if let sentence = Shortfall.commandsLeftOut(leftOut.named(leftOutNames)) { shortfalls.append(sentence) }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        var song = OpenMPTSong()
        var sequence = OpenMPTSong.Sequence()
        sequence.count = list.count
        sequence.speed = speed
        sequence.tempo = tempo
        song.sequences = [sequence]
        song.patternRowsPerBeat = [UInt16](repeating: 0, count: kept.count)
        song.patternSwing = [[UInt32]](repeating: [], count: kept.count)
        song.offsetAsImpulseTracker = true
        song.loopsOutlastJumps = false
        song.unmappedNotesKeepCommands = false
        song.gain = loudness

        // Channels to the left and the right, as on the Amiga: left, right, right, left.
        let pans = (0 ..< MAX_HOST_CHANNELS).map { channel -> UInt8 in channel < 32 ? (channel & 3 == 1 || channel & 3 == 2 ? 48 : 16) : 32 | 128 }
        var flags = ITF_STEREO | ITF_OLD_EFFECTS | ITF_COMPAT_GXX | (linear ? ITF_LINEAR_FRQ : 0)
        if !instruments.isEmpty { flags |= ITF_INSTR_MODE }
        let module = IT2Module(title: title, madeWith: madeWith, orders: list, flags: flags, globalVolume: 128, mixVolume: 48, speed: speed,
                               tempo: UInt8(max(32, min(255, tempo / OpenMPTSong.tempoUnit))), channelPans: pans, samples: allSamples,
                               patterns: kept, rows: keptRows, instruments: allInstruments, openMPT: song)
        module.velvetStudio = true
        return module
    }

    /// Set by measure: see the README.
    private static let loudness: Float = 1.53
}
