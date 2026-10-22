// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the DMF loader of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): `soundlib/Load_dmf.cpp`, with what it calls on of `soundlib/modcommand.cpp`
// (`ModCommand::FillInTwoCommands`, `ConvertToVolCommand` and `GetEffectWeight`) and of
// `soundlib/pattern.cpp` (`CPattern::WriteEffect`).

/// A DMF file, the module of X-Tracker.
///
/// X-Tracker was a tracker for DOS by D-Lusion, and DMF ("Delusion Digital Music File") its kind of
/// file, which went through seven versions while the tracker was in its beta, the eighth being the
/// tracker's own. A tune has up to 32 channels and a track above them for the tempo; samples of
/// eight bits or sixteen, with a loop that holds while the note's key is down, kept packed if their
/// maker wished; and three commands to a note, one each for its sample, its pitch and its volume,
/// with their timings in 256ths of a row and their vibratos in rows to the wave. Each pattern says
/// how long it is, and how many rows make a beat, by which a tempo may be given in beats a minute.
///
/// It is played here by Impulse Tracker's replayer, and not by X-Tracker's own, which has never been
/// published. OpenMPT does the same, and its reading of these files is the one followed: each place
/// in the list of patterns is given a pattern of its own, made from the file's as X-Tracker would
/// have played it there, its timings worked out at the speed the tune is going by then; and the
/// commands are those of Impulse Tracker's that come nearest, with the few that OpenMPT plays
/// otherwise for these files told to the replayer (`IT2Module.playsAsXTracker`, and
/// `IT2XTracker.swift`). See `IT2ForeignModule`.
///
/// What does not go over as it stands, as OpenMPT has it too:
///  - Three commands to a note, where Impulse Tracker has room for one and a volume column: the
///    sample's command is kept before the others, and of those the one that matters more.
///  - The tempo, which is made of a speed and a tempo of Impulse Tracker's that come as near to it as
///    they can, and the timings, which are made into ticks of that speed.
///  - A slide to a note named by the command ("scratch"), which is made one that gets there at once.
///  - A vibrato's waves, of which a triangle is Impulse Tracker's ramp.
/// And for these files alone, and not as OpenMPT plays them: a note above the highest Impulse Tracker
/// has is played an octave down on a copy of its sample that plays an octave up; and a slide to a
/// note on a row that names its instrument keeps the sample's loop, as OpenMPT plays the same rows
/// of an IT file, where for these files it lets the loop go.
enum DMFFile {
    /// True for a file that says it is one of these.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 66 && data.starts(with: [0x44, 0x44, 0x4D, 0x46]) && data[4] >= 1 && data[4] <= 10 // "DDMF"
    }

    /// Four bytes as a length, the first the least; one too large to be any is brought down to
    /// where it is still too large. (A whole number in a browser has 32 bits.)
    private static func long(_ f: ByteReader, _ i: Int) -> Int {
        let high = f.u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16le(i)
    }

    /// The four letters that name a part of the file, as a number.
    private static func id(_ letters: String) -> UInt32 {
        var value: UInt32 = 0
        for (k, byte) in letters.utf8.enumerated() { value |= UInt32(byte) << UInt32(8 * k) }
        return value
    }

    /// The file's parts, by their four letters, in the order they come: each is where it starts and
    /// where it ends. The early versions of X-Tracker wrote some lengths wrongly, which are made right
    /// as OpenMPT makes them: the list of patterns of versions 3 and 4 is longer than it says, and the
    /// part with the samples' sounds runs, before version 8, to the end of the file.
    private static func chunks(_ data: [UInt8], version: UInt8) -> [(id: UInt32, range: Range<Int>)] {
        let f = ByteReader(data)
        var found: [(id: UInt32, range: Range<Int>)] = []
        var at = 66
        while at + 8 <= data.count {
            let id = UInt32(f.u16le(at)) | UInt32(f.u16le(at + 2)) << 16
            var length = long(f, at + 4)
            at += 8
            var skip = 0
            if version == 3, id == Self.id("SEQU") {
                skip = 2
            } else if version == 4, id == Self.id("SEQU") {
                skip = 4
            } else if version < 8, id == Self.id("SMPD") {
                length = data.count - at
            }
            let end = at + min(length, data.count - at)
            found.append((id, at ..< end))
            at = min(data.count, end + skip)
        }
        return found
    }

    // MARK: OpenMPT's commands

    /// A command of OpenMPT's, by its number there. These are what a DMF file's are made into first,
    /// as OpenMPT makes them, and then Impulse Tracker's letters (see `letter` and `column`).
    enum Effect {
        static let none: UInt8 = 0, arpeggio: UInt8 = 1, portaUp: UInt8 = 2, portaDown: UInt8 = 3, slideToNote: UInt8 = 4, vibrato: UInt8 = 5
        static let slideToNoteVolume: UInt8 = 6, vibratoVolume: UInt8 = 7, tremolo: UInt8 = 8, pan: UInt8 = 9, offset: UInt8 = 10
        static let volumeSlide: UInt8 = 11, jump: UInt8 = 12, volume: UInt8 = 13, breakRow: UInt8 = 14, retrig: UInt8 = 15, speed: UInt8 = 16
        static let tempo: UInt8 = 17, tremor: UInt8 = 18, mod: UInt8 = 19, s: UInt8 = 20, panbrello: UInt8 = 27, panSlide: UInt8 = 29
        static let fineVibrato: UInt8 = 26, finetune: UInt8 = 35
    }

    /// OpenMPT's commands for the volume column, by their numbers there.
    enum VolumeEffect {
        static let none: UInt8 = 0, volume: UInt8 = 1, pan: UInt8 = 2, slideUp: UInt8 = 3, slideDown: UInt8 = 4, fineUp: UInt8 = 5, fineDown: UInt8 = 6
        static let vibratoDepth: UInt8 = 8, slideToNote: UInt8 = 11, portaUp: UInt8 = 12, portaDown: UInt8 = 13, playControl: UInt8 = 14, offset: UInt8 = 15
    }

    /// OpenMPT's notes beyond its notes: the cut and the release.
    static let noteCut: UInt8 = 254, noteOff: UInt8 = 255
    /// OpenMPT's notes run from 1 to 128, an octave and two thirds more than Impulse Tracker's 120.
    static let highestNote: UInt8 = 128

    /// One channel's part of a row as OpenMPT has it: its note (from 1, and nought for none), its
    /// instrument, the volume column's command and value, and the command and its value.
    struct Cell: Equatable {
        var note: UInt8 = 0, instrument: UInt8 = 0, volumeCommand: UInt8 = 0, volume: UInt8 = 0, command: UInt8 = 0, value: UInt8 = 0

        var isNote: Bool { note >= 1 && note <= DMFFile.highestNote }

        mutating func setVolume(_ command: (UInt8, UInt8)) {
            volumeCommand = command.0
            volume = command.1
        }
    }

    /// A pattern as OpenMPT has it: so many rows of so many channels, the first of which is the
    /// track for the tempo.
    struct Pattern {
        let rows: Int, channels: Int
        var cells: [Cell]

        init(rows: Int, channels: Int) {
            self.rows = rows
            self.channels = channels
            cells = [Cell](repeating: Cell(), count: rows * channels)
        }

        subscript(row: Int, channel: Int) -> Cell {
            get { cells[row * channels + channel] }
            set { cells[row * channels + channel] = newValue }
        }
    }

    /// How much each command matters, when there is room for only one (`ModCommand::GetEffectWeight`):
    /// OpenMPT's commands from the least to the most.
    private static let weights: [UInt8] = [
        0, 37, 34, 30, 48, 25, 8, 26, 5, 28, 35, 36, 27, 20, 19, 33, 31, 32, 29, 9, 40, 38, 41, 39, 2, 54, 52, 50, 3, 53, 51, 11, 49, 7, 13,
        46, 45, 42, 44, 10, 18, 15, 47, 1, 55, 4, 6, 43, 56, 57, 22, 21, 24, 23, 17, 16, 12, 14,
    ]

    private static func weight(_ effect: UInt8) -> Int {
        weights.firstIndex(of: effect) ?? 0
    }

    /// How fast the volume column's slides to a note go, for each of its settings.
    private static let slideToNoteSpeeds: [UInt8] = [0x00, 0x01, 0x04, 0x08, 0x10, 0x20, 0x40, 0x60, 0x80, 0xFF]

    /// What the volume column can do of a command (`ModCommand::ConvertToVolCommand`): exactly, or
    /// with `force` as near as it can. Gives the volume column's command and value, or none.
    static func volumeCommand(_ effect: UInt8, _ value: UInt8, force: Bool) -> (UInt8, UInt8) {
        let none = (VolumeEffect.none, UInt8(0))
        switch effect {
        case Effect.volume:
            return (VolumeEffect.volume, min(value, 64))
        case 46: // an eight-bit volume
            if !force, value & 3 != 0 { return none }
            return (VolumeEffect.volume, UInt8((Int(value) + 3) / 4))
        case Effect.portaUp, Effect.portaDown:
            if !force, value & 3 != 0 || value >= 0xE0 { return none }
            return (effect == Effect.portaUp ? VolumeEffect.portaUp : VolumeEffect.portaDown, value / 4)
        case Effect.slideToNote:
            if value >= 0xF0 { return (VolumeEffect.slideToNote, 9) }
            for n in 0 ..< 10 where force ? value <= slideToNoteSpeeds[n] : value == slideToNoteSpeeds[n] {
                return (VolumeEffect.slideToNote, UInt8(n))
            }
            return none
        case Effect.vibrato:
            var value = value
            if force {
                value = min(value & 0x0F, 9)
            } else if value & 0x0F > 9 || value & 0xF0 != 0 {
                return none
            }
            return (VolumeEffect.vibratoDepth, value & 0x0F)
        case Effect.fineVibrato:
            if !force, value != 0 { return none }
            return (VolumeEffect.vibratoDepth, force ? 0 : value)
        case Effect.pan:
            return (VolumeEffect.pan, value == 255 ? 64 : value / 4)
        case Effect.volumeSlide:
            if value == 0 { return none }
            if value & 0x0F == 0 { return (VolumeEffect.slideUp, value >> 4) }
            if value & 0xF0 == 0 { return (VolumeEffect.slideDown, value) }
            if value & 0x0F == 0x0F { return (VolumeEffect.fineUp, value >> 4) }
            if value & 0xF0 == 0xF0 { return (VolumeEffect.fineDown, value & 0x0F) }
            return none
        case Effect.s:
            if value & 0xF0 == 0x80 { return (VolumeEffect.pan, ((value & 0x0F) << 2) + 2) }
            if value & 0xF0 == 0x90, value >= 0x9E, force { return (VolumeEffect.playControl, value - 0x9E + 2) }
            return none
        case Effect.mod:
            switch value & 0xF0 {
            case 0x80: return (VolumeEffect.pan, ((value & 0x0F) << 2) + 2)
            case 0xA0: return (VolumeEffect.fineUp, value & 0x0F)
            case 0xB0: return (VolumeEffect.fineDown, value & 0x0F)
            default: return none
            }
        default:
            return none
        }
    }

    /// Puts two commands into a cell's volume column and command, as OpenMPT does
    /// (`ModCommand::FillInTwoCommands`): one into the volume column if it can go there, exactly and
    /// then as near as can be, and else the one that matters more into the command. What is left over
    /// is left out: true if anything was.
    @discardableResult
    static func fillInTwo(_ cell: inout Cell, _ effect1: UInt8, _ value1: UInt8, _ effect2: UInt8, _ value2: UInt8) -> Bool {
        var e1 = effect1, p1 = value1, e2 = effect2, p2 = value2
        // (Of two the same that set something and do not slide it, the second is nothing to keep.)
        if e1 == e2 {
            switch e1 {
            case 1, 9, 10, 12, 13, 14, 16, 17, 21, 23, 25, 30, 31, 32, 33, 35, 36, 37, 42, 43, 44, 45, 46, 47, 48: e2 = Effect.none
            default: break
            }
        }
        for n in 0 ..< 4 {
            let column = volumeCommand(e1, p1, force: n > 1)
            if e1 == Effect.none || column.0 != VolumeEffect.none {
                cell.setVolume(column)
                cell.command = e2
                cell.value = p2
                return false
            }
            swap(&e1, &e2)
            swap(&p1, &p2)
        }
        if weight(e1) > weight(e2) {
            swap(&e1, &e2)
            swap(&p1, &p2)
        }
        if e2 == Effect.offset, p2 == 0 {
            cell.setVolume((VolumeEffect.offset, 0))
            cell.command = e1
            cell.value = p1
            return false
        }
        cell.setVolume((VolumeEffect.none, 0))
        cell.command = e2
        cell.value = p2
        return e1 != Effect.none
    }

    /// How a command is to be put into a pattern that already has others (`EffectWriter`): on its
    /// row, in its channel or in whichever has room, and if none has, on the row after or before.
    private struct Writer {
        var command: UInt8, value: UInt8
        var row: Int
        var channel: Int?
        enum Retry { case none, nextRow, previousRow }
        var retry = Retry.none
        var allowMultiple = false
    }

    /// Puts a command into a pattern as OpenMPT's `CPattern::WriteEffect` does: not if the row has it
    /// already in a channel it may go in, else in the first such channel with no command, or in place
    /// of a volume or a place between the speakers that can go to the volume column; and failing all
    /// that, on the next or the last row, if it may. True if it went in, or was there.
    /// (OpenMPT then tries the command in the volume column, which none of those put in here can go to.)
    @discardableResult
    private static func write(_ writer: Writer, in pattern: inout Pattern) -> Bool {
        var row = writer.row
        while row >= 0, row < pattern.rows {
            let channels = writer.channel.map { $0 ... $0 } ?? 0 ... (pattern.channels - 1)
            guard channels.upperBound < pattern.channels else { return false }
            if !writer.allowMultiple, channels.contains(where: { pattern[row, $0].command == writer.command }) { return true }
            if let free = channels.first(where: { pattern[row, $0].command == Effect.none }) {
                pattern[row, free].command = writer.command
                pattern[row, free].value = writer.value
                return true
            }
            for channel in channels {
                var cell = pattern[row, channel]
                switch cell.command {
                case Effect.volume:
                    cell.volumeCommand = VolumeEffect.volume
                    cell.volume = cell.value
                case Effect.pan:
                    cell.volumeCommand = VolumeEffect.pan
                    cell.volume = UInt8((Int(cell.value) + 2) / 4)
                default:
                    continue
                }
                cell.command = writer.command
                cell.value = writer.value
                pattern[row, channel] = cell
                return true
            }
            switch writer.retry {
            case .none: return false
            case .nextRow: row += 1
            case .previousRow: row -= 1
            }
        }
        return false
    }

    // MARK: X-Tracker's timings

    /// A slide of pitch as so many of OpenMPT's units a tick, from X-Tracker's so many a row (OpenMPT's
    /// `DMFporta2MPT`): spread over the ticks of a row but its first; and one of up to fifteen, if
    /// fine ones are wanted, or at a speed of one tick a row, once at its start.
    private static func porta(_ value: UInt8, ticks: UInt8, fine: Bool) -> UInt8 {
        if value == 0 { return 0 }
        if value <= 0x0F && fine || ticks < 2 { return value | 0xF0 }
        return max(1, value / (ticks - 1))
    }

    /// A slide of volume (or of the place between the speakers) as Impulse Tracker's Dxy, from
    /// X-Tracker's, which is by 256ths and not 64ths (`DMFslide2MPT`). One of less than fifteen is
    /// made a fine one, done once at the row's start; the rest are spread over the ticks of the row but
    /// its first, and kept in the four bits they have room for as OpenMPT keeps them, which loses some.
    private static func slide(_ value: UInt8, ticks: UInt8, up: Bool) -> UInt8 {
        var value = max(1, value / 4)
        let fine = value < 0x0F || ticks < 2
        if !fine { value = max(1, UInt8(truncatingIfNeeded: (Int(value) + Int(ticks) - 2) / (Int(ticks) - 1))) }
        return up ? (fine ? 0x0F : 0) | value << 4 : (fine ? 0xF0 : 0) | value & 0x0F
    }

    /// A tremor's times on and off, from fifteenths of a row to ticks (`DMFtremor2MPT`).
    private static func tremor(_ value: UInt8, ticks: UInt8) -> UInt8 {
        let on = UInt8(max(1, min(15, Int(value >> 4) * Int(ticks) / 15)))
        let off = UInt8(max(1, min(15, Int(value & 0x0F) * Int(ticks) / 15)))
        return on << 4 | off
    }

    /// A delay, from 255ths of a row to ticks (`DMFdelay2MPT`).
    private static func delay(_ value: UInt8, ticks: UInt8) -> UInt8 {
        UInt8(max(0, min(15, Int(value) * Int(ticks) / 255)))
    }

    /// A vibrato's speed, from X-Tracker's rows to the wave to Impulse Tracker's steps of 64ths of it
    /// a tick, and its depth as it is (`DMFvibrato2MPT`).
    private static func vibrato(_ value: UInt8, ticks: UInt8) -> UInt8 {
        let periodInTicks = max(1, Int(value >> 4)) * Int(ticks)
        let speed = UInt8(max(1, min(15, 128 / periodInTicks)))
        return speed << 4 | max(1, value & 0x0F)
    }

    /// Where a command has the same value as the last of its kind on the channel above it, gives it
    /// nought, to go on with the last, as OpenMPT does to help its swapping of commands
    /// (`ApplyEffectMemory`): looking back up the pattern past cells with other commands, and giving
    /// up at one of the same kind with another value, or where the memory a slide shares with others
    /// could be another's.
    private static func applyMemory(_ pattern: Pattern, row: Int, channel: Int, effect: UInt8, value: inout UInt8) {
        if effect == Effect.none || value == 0 { return }
        let pitch = effect == Effect.portaUp || effect == Effect.portaDown || effect == Effect.slideToNote
        let volume = effect == Effect.volumeSlide || effect == Effect.slideToNoteVolume || effect == Effect.vibratoVolume
        var row = row
        while row > 0 {
            row -= 1
            let m = pattern[row, channel]
            var same = effect == m.command
            if pitch, m.command == Effect.portaUp || m.command == Effect.portaDown || m.command == Effect.slideToNote {
                // (A fine slide could have been put in the volume column, where fine slides do nothing.)
                if m.value < 0xE0 { same = true } else { return }
            } else if volume, m.command == Effect.volumeSlide || m.command == Effect.slideToNoteVolume || m.command == Effect.vibratoVolume {
                same = true
            }
            let v = m.volumeCommand
            if pitch, v == VolumeEffect.portaUp || v == VolumeEffect.portaDown || v == VolumeEffect.slideToNote, m.volume != 0 { return }
            if volume, v == VolumeEffect.fineUp || v == VolumeEffect.fineDown || v == VolumeEffect.slideUp || v == VolumeEffect.slideDown, m.volume != 0 { return }
            if same {
                if value != m.value, m.value != 0 { return }
                if value == m.value {
                    value = 0
                    return
                }
            }
        }
    }

    // MARK: Patterns

    /// What is carried from one pattern to the next as they are made, in the order the list plays
    /// them: each channel's notes and the waves its last commands chose, and the tempo.
    private struct Settings {
        struct Channel {
            var noteBuffer: UInt8 = 0, lastNote: UInt8 = 0
            var vibratoType: UInt8 = 8, tremoloType: UInt8 = 4, highOffset: UInt8 = 6
            var playDirection = false
        }

        var channels: [Channel]
        var realBPM = false
        var beat: UInt8 = 0
        var tempoTicks: UInt8 = 32
        var tempoBPM: UInt8 = 120
        var ticks: UInt8 = 6
        /// How many cells have had a command left out, for want of room.
        var crowded = 0

        init(channels: Int) {
            self.channels = [Channel](repeating: Channel(), count: channels)
        }
    }

    /// A pattern of the file as OpenMPT makes it for its place in the list (`ConvertDMFPattern`).
    private static func pattern(_ data: [UInt8], _ range: Range<Int>, version: UInt8, settings: inout Settings, channels fileChannels: Int) -> Pattern {
        let f = ByteReader(data)
        var at = range.lowerBound
        let end = range.upperBound
        func byte() -> UInt8 {
            defer { at += 1 }
            return at < end ? f[at] : 0
        }
        func word() -> Int {
            let low = Int(byte())
            return low | Int(byte()) << 8
        }

        var tracks: Int, beat: UInt8 = 0, rowCount: Int
        if version < 3 {
            tracks = Int(byte())
            at += 2
            rowCount = word()
            at += 4
        } else {
            tracks = Int(byte())
            beat = byte()
            rowCount = word()
            at += 4
        }
        if version < 6 { beat = 0 }

        var pattern = Pattern(rows: max(1, min(rowCount, 4096)), channels: fileChannels)
        let channels = min(fileChannels - 1, tracks)
        // Going to a pattern with fewer channels than the one before cuts the notes of the rest.
        for channel in channels + 1 ..< max(channels + 1, fileChannels) { pattern[0, channel].note = noteCut }

        settings.beat = beat >> 4
        var tempoChange = settings.realBPM
        var tickDelay: UInt8 = 0
        // (How many rows each channel and the tempo's track have yet to go with nothing.)
        var counters = [UInt8](repeating: 0, count: channels + 1)

        for row in 0 ..< pattern.rows where at < end {
            // The tempo's track.
            if counters[0] == 0 {
                var info = byte()
                if info & 0x80 != 0 { counters[0] = byte() }
                info &= 0x3F
                let value = info != 0 ? byte() : 0
                switch info {
                case 1: // a speed in ticks, of a quarter of a row a second
                    settings.realBPM = false
                    settings.tempoTicks = max(1, value)
                    settings.tempoBPM = 0
                    tempoChange = true
                case 2: // a tempo in beats a minute
                    if value != 0 {
                        settings.realBPM = true
                        settings.tempoBPM = value
                        if settings.beat != 0 { settings.tempoTicks = UInt8(truncatingIfNeeded: Int(value) * Int(settings.beat) * 15) }
                        tempoChange = true
                    }
                case 3: // how many rows a beat is
                    settings.beat = value >> 4
                    if settings.beat != 0 {
                        tempoChange = settings.realBPM
                    } else {
                        settings.realBPM = false
                    }
                case 4: // the row held up
                    tickDelay = value
                case 6, 7: // the tempo slid up or down
                    if value > 0 {
                        var tempo = settings.realBPM ? settings.tempoBPM : settings.tempoTicks
                        if info == 6 {
                            tempo = Int(tempo) < 256 - Int(value) ? tempo + value : 255
                        } else {
                            tempo = Int(tempo) > 1 + Int(value) ? tempo - value : 1
                        }
                        if settings.realBPM { settings.tempoBPM = tempo } else { settings.tempoTicks = tempo }
                        tempoChange = true
                    }
                default:
                    break
                }
            } else {
                counters[0] -= 1
            }

            // The speed and tempo of Impulse Tracker's that come nearest, the speed as high as can be
            // so that arpeggios and tremors keep their shape.
            var speed = 0, tempo = 0
            if tempoChange {
                if !settings.realBPM || settings.beat != 0 {
                    let tickSpeed = settings.realBPM ? max(1, Int(settings.tempoBPM) * Int(settings.beat) * 2) : (Int(settings.tempoTicks) + 1) * 30
                    speed = 255
                    while speed >= 1 {
                        tempo = tickSpeed * speed / 48
                        if tempo >= 32, tempo <= 255 { break }
                        speed -= 1
                    }
                    tempo = max(32, min(255, tempo))
                    settings.ticks = UInt8(max(1, speed))
                } else {
                    tempoChange = false
                }
            }

            for channel in 1 ... max(1, channels) where channel <= channels {
                if counters[channel] != 0 {
                    counters[channel] -= 1
                    continue
                }
                let info = byte()
                if info & 0x80 != 0 { counters[channel] = byte() }
                var m = pattern[row, channel]
                var state = settings.channels[channel]

                // A note with no instrument beside it is not struck again: it is slid to.
                var slideNote = true
                if info & 0x40 != 0 {
                    m.instrument = byte()
                    if m.instrument != 0 { slideNote = false }
                }
                if info & 0x20 != 0 {
                    m.note = byte()
                    if m.note >= 1, m.note <= 108 {
                        m.note = min(m.note + 24, highestNote)
                        state.lastNote = m.note
                    } else if m.note >= 129, m.note <= 236 {
                        // A note kept for a slide to it, and not played.
                        state.noteBuffer = min((m.note & 0x7F) + 24, highestNote)
                        m.note = 0
                    } else if m.note == 255 {
                        m.note = noteCut
                    }
                }
                // An instrument alone strikes the last note again.
                if m.note == 0, m.instrument > 0 {
                    m.note = state.lastNote
                    m.instrument = 0
                }
                if m.isNote { state.playDirection = false }

                var effect1 = Effect.none, effect2 = Effect.none, effect3 = Effect.none
                var value1: UInt8 = 0, value2: UInt8 = 0, value3: UInt8 = 0
                var memory2 = false, memory3 = false

                if info & 0x10 != 0 {
                    // (Should be + 3, but a volume of 1 is silent in X-Tracker.)
                    m.volumeCommand = VolumeEffect.volume
                    m.volume = UInt8((Int(byte()) + 2) / 4)
                }

                // The sample's command.
                if info & 0x08 != 0 {
                    let command = byte()
                    value1 = byte()
                    switch command {
                    case 1: // stopped
                        m.note = noteCut
                    case 2: // its loop let go
                        m.note = noteOff
                    case 3: // started again
                        m.note = state.lastNote
                        state.playDirection = false
                    case 4: // put off
                        value1 = delay(value1, ticks: settings.ticks)
                        if value1 != 0 {
                            effect1 = Effect.s
                            value1 = 0xD0 | value1
                        }
                        if m.note == 0 {
                            m.note = state.lastNote
                            state.playDirection = false
                        }
                    case 5: // struck again and again
                        value1 = max(1, delay(value1, ticks: settings.ticks))
                        effect1 = Effect.retrig
                        state.playDirection = false
                    case 6, 7, 8, 9: // started from further in, by 256 bytes and so many times 65,536
                        // (The part beyond 65,536 is put on the row before.)
                        if row > 0, command != state.highOffset {
                            if write(Writer(command: Effect.s, value: 0xA0 | (command - 6), row: row - 1, channel: channel, retry: .previousRow), in: &pattern) {
                                state.highOffset = command
                            }
                        }
                        effect1 = Effect.offset
                        if m.note == 0 { m.note = state.lastNote }
                        state.playDirection = false
                    case 10: // played the other way ("Tekkno Invert")
                        effect1 = Effect.s
                        value1 = state.playDirection ? 0x9E : 0x9F
                        state.playDirection.toggle()
                    default:
                        break
                    }
                }

                // The note's command.
                if info & 0x04 != 0 {
                    let command = byte()
                    value2 = byte()
                    switch command {
                    case 1: // tuned, by sixteenths of a semitone
                        let fine = Int(Int8(bitPattern: value2)) * 8
                        if m.isNote { m.note = UInt8(max(1, min(Int(highestNote), Int(m.note) + fine / 128))) }
                        effect2 = Effect.finetune
                        value2 = UInt8(truncatingIfNeeded: fine % 128) ^ 0x80
                    case 2: // put off
                        value2 = delay(value2, ticks: settings.ticks)
                        if value2 != 0 {
                            effect2 = Effect.s
                            value2 = 0xD0 | value2
                        }
                        memory2 = true
                    case 3:
                        effect2 = Effect.arpeggio
                        memory2 = true
                    case 4, 5:
                        value2 = porta(value2, ticks: settings.ticks, fine: true)
                        effect2 = command == 4 ? Effect.portaUp : Effect.portaDown
                        memory2 = true
                    case 6: // a slide to the note kept for it
                        if m.note == 0 { m.note = state.noteBuffer }
                        value2 = porta(value2, ticks: settings.ticks, fine: false)
                        effect2 = Effect.slideToNote
                        memory2 = true
                    case 7: // a slide to a note at a speed of its own
                        m.note = UInt8(max(1, min(Int(highestNote), Int(value2) + 25)))
                        effect2 = Effect.slideToNote
                        value2 = 0xFF
                        memory2 = true
                    case 8, 9, 10: // vibrato, of a sine, a triangle and a square
                        // (The wave is chosen on the row before.)
                        if row > 0, command != state.vibratoType {
                            if write(Writer(command: Effect.s, value: 0x30 | (command - 8), row: row - 1, channel: channel, retry: .previousRow), in: &pattern) {
                                state.vibratoType = command
                            }
                        }
                        effect2 = Effect.vibrato
                        value2 = vibrato(value2, ticks: settings.ticks)
                        memory2 = true
                    case 11:
                        value2 = tremor(value2, ticks: settings.ticks)
                        effect2 = Effect.tremor
                        memory2 = true
                    case 12: // cut
                        value2 = delay(value2, ticks: settings.ticks)
                        if value2 != 0 {
                            effect2 = Effect.s
                            value2 = 0xC0 | value2
                        } else {
                            m.note = noteCut
                        }
                        memory2 = true
                    default:
                        break
                    }
                }

                // The volume's command.
                if info & 0x02 != 0 {
                    let command = byte()
                    value3 = byte()
                    switch command {
                    case 1, 2:
                        value3 = slide(value3, ticks: settings.ticks, up: command == 1)
                        effect3 = Effect.volumeSlide
                        memory3 = true
                    case 3: // a tremor, which X-Tracker calls a tremolo
                        value3 = tremor(value3, ticks: settings.ticks)
                        effect3 = Effect.tremor
                        memory3 = true
                    case 4, 5, 6: // tremolo, of a sine, a triangle and a square
                        if row > 0, command != state.tremoloType {
                            if write(Writer(command: Effect.s, value: 0x40 | (command - 4), row: row - 1, channel: channel, retry: .previousRow), in: &pattern) {
                                state.tremoloType = command
                            }
                        }
                        effect3 = Effect.tremolo
                        value3 = vibrato(value3, ticks: settings.ticks)
                        memory3 = true
                    case 7: // the place between the speakers
                        effect3 = Effect.pan
                    case 8, 9: // slid left or right
                        value3 = slide(value3, ticks: settings.ticks, up: command == 8)
                        effect3 = Effect.panSlide
                        memory3 = true
                    case 10: // swayed between them
                        effect3 = Effect.panbrello
                        value3 = vibrato(value3, ticks: settings.ticks)
                        memory3 = true
                    default:
                        break
                    }
                }

                if memory2 { applyMemory(pattern, row: row, channel: channel, effect: effect2, value: &value2) }
                if memory3 { applyMemory(pattern, row: row, channel: channel, effect: effect3, value: &value3) }

                // A note that is not to be struck again is slid to at once.
                if slideNote, m.isNote {
                    if effect2 == Effect.none {
                        effect2 = Effect.slideToNote
                        value2 = 0xFF
                    } else if effect3 == Effect.none, effect2 != Effect.slideToNote {
                        effect3 = Effect.slideToNote
                        value3 = 0xFF
                    }
                }
                // The volume goes among the commands for a while, where there is room.
                if m.volumeCommand == VolumeEffect.volume {
                    if effect2 == Effect.none {
                        effect2 = Effect.volume
                        value2 = m.volume
                        m.setVolume((VolumeEffect.none, 0))
                    } else if effect3 == Effect.none {
                        effect3 = Effect.volume
                        value3 = m.volume
                        m.setVolume((VolumeEffect.none, 0))
                    }
                }

                var combined = Cell()
                var crowded = fillInTwo(&combined, effect2, value2, effect3, value3)
                func volumeColumn() {
                    guard combined.volumeCommand != VolumeEffect.none else { return }
                    if m.volumeCommand == VolumeEffect.none { m.setVolume((combined.volumeCommand, combined.volume)) } else { crowded = true }
                }
                volumeColumn()
                // The sample's command comes before the others.
                if effect1 != Effect.none {
                    if fillInTwo(&combined, combined.command, combined.value, effect1, value1) { crowded = true }
                    volumeColumn()
                    m.command = combined.command
                    m.value = combined.value
                } else if combined.command != Effect.none {
                    m.command = combined.command
                    m.value = combined.value
                }
                pattern[row, channel] = m
                settings.channels[channel] = state
                if crowded { settings.crowded += 1 }
            }

            if tempoChange {
                tempoChange = false
                write(Writer(command: Effect.tempo, value: UInt8(tempo), row: row, channel: 0, retry: .nextRow), in: &pattern)
                write(Writer(command: Effect.speed, value: UInt8(speed), row: row, retry: .nextRow), in: &pattern)
            }
            // The row held up: so many times over, and so many fifteenths of a row longer.
            if tickDelay & 0xF0 != 0 {
                write(Writer(command: Effect.s, value: 0xE0 | (tickDelay >> 4), row: row, allowMultiple: true), in: &pattern)
            }
            if tickDelay & 0x0F != 0 {
                let ticks = UInt8(truncatingIfNeeded: Int(tickDelay & 0x0F) * Int(settings.ticks) / 15)
                write(Writer(command: Effect.s, value: 0x60 | max(1, min(15, ticks)), row: row, allowMultiple: true), in: &pattern)
            }
            tickDelay = 0
        }
        return pattern
    }

    // MARK: Reading

    /// A sample as OpenMPT reads one: its header, and its sound as so many bytes.
    struct Sample {
        var length = 0, loopStart = 0, loopEnd = 0, rate = 0
        /// Of 256; nil for none of its own, which leaves the channel's volume as it was.
        var volume: Int?
        var loops = false, sixteen = false
        var sound: [UInt8] = []
        /// How many bytes of sound the header says there are, and how many the file has.
        var wanted = 0, there = 0
    }

    /// The song as OpenMPT reads it: a pattern for each place in the list, how many channels there
    /// are with the tempo's track, and the samples.
    struct Song {
        var version: UInt8 = 0
        var channels = 0
        /// For each place in the list, the pattern it plays; a number of none plays nothing.
        var orders: [Int] = []
        var patterns: [Pattern] = []
        var samples: [Sample] = []
        var title = "", author = ""
        /// How many cells have had a command left out, for want of room.
        var crowded = 0
    }

    /// How many cells the patterns of all the places may come to, some 26 megabytes: as many as
    /// X-Tracker's own could have, 255 places of 512 rows of 33 channels.
    private static let mostCells = 255 * 512 * 33

    static func song(_ data: [UInt8]) throws -> Song {
        guard isOne(data) else { throw TuneError.malformed("not a DMF file") }
        let f = ByteReader(data)
        var song = Song()
        let version = data[4]
        song.version = version
        song.title = f.dos(at: 13, length: 30)
        song.author = f.dos(at: 43, length: 20)
        let parts = chunks(data, version: version)
        func part(_ letters: String) -> Range<Int>? {
            let id = id(letters)
            return parts.first { $0.id == id }?.range
        }

        // The patterns' part first, for how many channels there are.
        guard let patterns = part("PATT") else { throw TuneError.malformed("a DMF file without patterns") }
        let patternCount = f.u16le(patterns.lowerBound), tracks = Int(f[patterns.lowerBound + 2])
        var places: [Range<Int>] = []
        let headerSize = version < 3 ? 9 : 8
        var at = patterns.lowerBound + 3
        for _ in 0 ..< patternCount {
            let lengthAt = at + headerSize - 4
            let length = lengthAt + 4 <= patterns.upperBound ? long(f, lengthAt) : 0
            guard length <= patterns.upperBound - min(patterns.upperBound, lengthAt + 4) else { throw TuneError.malformed("a DMF file that ends too soon") }
            let end = min(patterns.upperBound, at + headerSize + length)
            places.append(at ..< end)
            at = end
        }
        song.channels = max(1, min(32, tracks)) + 1

        // The list, with where it goes back to at its end and where that end is (from version 3 and
        // version 4). One of version 4 whose end is nought has no end: it cannot have been meant.
        let sequence = part("SEQU") ?? data.count ..< data.count
        var reading = sequence.lowerBound
        var loopStart = 0, loopEnd = Int.max
        if version >= 3 {
            loopStart = f.u16le(reading)
            reading += 2
        }
        if version >= 4 {
            loopEnd = f.u16le(reading)
            reading += 2
            if version == 4, loopEnd == 0 { loopEnd = Int.max }
        }
        let orderCount = max(0, sequence.upperBound - min(sequence.upperBound, reading)) / 2
        let orders = (0 ..< orderCount).map { f.u16le(reading + $0 * 2) }
        guard !orders.isEmpty else { throw TuneError.malformed("a DMF file with no list of patterns") }
        loopStart = min(loopStart, orders.count - 1)
        loopEnd = min(loopEnd, orders.count - 1)

        // A pattern for each place, as the patterns are played there: of the places Impulse
        // Tracker's list has room for, and for as long as they come to no more cells than X-Tracker
        // could have written (a place beyond is the song's end).
        var settings = Settings(channels: song.channels)
        song.orders = orders
        var cells = 0
        for (place, number) in orders.enumerated() where number < places.count {
            guard place < 255 else { break }
            let made = pattern(data, places[number], version: version, settings: &settings, channels: song.channels)
            cells += made.rows * made.channels
            guard cells <= mostCells else {
                for rest in place ..< orders.count { song.orders[rest] = Int.max }
                break
            }
            song.orders[place] = song.patterns.count
            song.patterns.append(made)
            song.crowded = settings.crowded
        }
        // The end of the list, if it is before its last place, goes back to where the list does.
        if loopEnd < 255, song.orders[loopEnd] < song.patterns.count, loopStart > 0 || loopEnd < orders.count - 1 {
            let number = song.orders[loopEnd]
            write(Writer(command: Effect.jump, value: UInt8(truncatingIfNeeded: loopStart), row: song.patterns[number].rows - 1, retry: .previousRow),
                  in: &song.patterns[number])
        }

        // The samples' headers, and their sounds one after another in another part.
        let headers = part("SMPI") ?? data.count ..< data.count
        let sounds = part("SMPD") ?? data.count ..< data.count
        var soundAt = sounds.lowerBound
        at = headers.lowerBound + 1
        for _ in 0 ..< Int(f[headers.lowerBound]) {
            let nameLength = version < 2 ? 30 : Int(f[at])
            if version >= 2 { at += 1 }
            at += nameLength
            var sample = Sample()
            sample.length = long(f, at)
            sample.loopStart = long(f, at + 4)
            sample.loopEnd = long(f, at + 8)
            sample.rate = f.u16le(at + 12)
            let volume = Int(f[at + 14]), flags = f[at + 15]
            at += 16
            if version >= 8 { at += 8 } // the name of the library it is from
            at += version > 1 ? 6 : 2
            sample.volume = volume == 0 ? nil : volume + 1
            sample.loops = flags & 1 != 0 && sample.loopEnd > sample.loopStart
            sample.sixteen = flags & 2 != 0
            if sample.sixteen {
                sample.length /= 2
                sample.loopStart /= 2
                sample.loopEnd /= 2
            }

            // The sound, after how many bytes it takes; packed, or as it is.
            let size = soundAt + 4 <= sounds.upperBound ? long(f, soundAt) : 0
            let start = min(sounds.upperBound, soundAt + 4)
            let sound = start ..< min(sounds.upperBound, start + size)
            soundAt = sound.upperBound
            if sound.isEmpty {
                sample.length = 0
            } else if flags & 0x0C == 0x04 {
                // (A sample is no longer than it could be at two bits a sample.)
                sample.length = min(sample.length, sound.count * 8)
                if sound.count > 4 {
                    sample.sound = unpack(data, sound, count: sample.length * (sample.sixteen ? 2 : 1))
                } else {
                    sample.sound = [UInt8](repeating: 0, count: sample.length * (sample.sixteen ? 2 : 1))
                }
            } else {
                let width = sample.sixteen ? 2 : 1
                sample.wanted = sample.length * width
                sample.there = sound.count
                sample.length = min(sample.length, sound.count / width)
                sample.sound = Array(data[sound.lowerBound ..< sound.lowerBound + sample.length * width])
            }
            song.samples.append(sample)
        }
        return song
    }

    // MARK: Packed samples

    /// A sample packed as X-Tracker packs one (`DMFUnpack`): a tree of the differences from one byte to
    /// the next, of seven bits and a sign, and the differences one after another as their ways down
    /// it. Gives so many bytes; what is missing from a sample that is cut short is silence.
    static func unpack(_ data: [UInt8], _ range: Range<Int>, count: Int) -> [UInt8] {
        var sound = [UInt8](repeating: 0, count: count)
        var at = range.lowerBound, buffer: UInt32 = 0, held = 0
        /// The next so many bits, the lowest first; nil when there are no more.
        func bits(_ n: Int) -> UInt32? {
            while held < n {
                guard at < range.upperBound else { return nil }
                buffer |= UInt32(data[at]) << UInt32(held)
                at += 1
                held += 8
            }
            let value = buffer & ((1 << UInt32(n)) - 1)
            buffer >>= UInt32(n)
            held -= n
            return value
        }

        // The tree, each node with its value and the nodes to its left and right; -1 for none.
        var values = [UInt8](repeating: 0, count: 256)
        var lefts = [Int16](repeating: 0, count: 256), rights = [Int16](repeating: 0, count: 256)
        var lastNode = 0, nodeCount = 0
        /// Reads a node and those below it; false if the bits ran out.
        func node() -> Bool {
            var here = nodeCount
            guard here <= 255 else { return true }
            guard let value = bits(7), let isLeft = bits(1), let isRight = bits(1) else { return false }
            values[here] = UInt8(value)
            here = lastNode
            guard here <= 255 else { return true }
            nodeCount += 1
            lastNode = nodeCount
            if isLeft != 0 {
                lefts[here] = Int16(lastNode)
                if !node() { return false }
            } else {
                lefts[here] = -1
            }
            lastNode = nodeCount
            if isRight != 0 {
                rights[here] = Int16(lastNode)
                if !node() { return false }
            } else {
                rights[here] = -1
            }
            return true
        }
        guard node(), lefts[0] >= 0, rights[0] >= 0 else { return sound }

        var value: UInt8 = 0, delta: UInt8 = 0
        for i in 0 ..< count {
            var here = 0
            guard let sign = bits(1) else { break }
            repeat {
                guard let right = bits(1) else { return sound }
                here = Int(right != 0 ? rights[here] : lefts[here])
                if here > 255 { break }
                delta = values[here]
            } while lefts[here] >= 0 && rights[here] >= 0
            if sign != 0 { delta ^= 0xFF }
            value &+= delta
            sound[i] = value
        }
        return sound
    }
}

// MARK: For Impulse Tracker's replayer

extension DMFFile {
    private typealias Command = IT2ForeignModule.Command

    /// Impulse Tracker's command for one of OpenMPT's, with the two that Impulse Tracker has none for
    /// as the replayer has them for these files (see `IT2XTracker.swift`); nought for none.
    private static func letter(_ effect: UInt8) -> UInt8 {
        switch effect {
        case Effect.arpeggio: Command.J
        case Effect.portaUp: Command.F
        case Effect.portaDown: Command.E
        case Effect.slideToNote: Command.G
        case Effect.vibrato: Command.H
        case Effect.slideToNoteVolume: Command.L
        case Effect.vibratoVolume: Command.K
        case Effect.tremolo: Command.R
        case Effect.pan: Command.X
        case Effect.offset: Command.O
        case Effect.volumeSlide: Command.D
        case Effect.jump: Command.B
        case Effect.volume: IT2Player.xTrackerVolume
        case Effect.breakRow: Command.C
        case Effect.retrig: Command.Q
        case Effect.speed: Command.A
        case Effect.tempo: Command.T
        case Effect.tremor: Command.I
        case Effect.s: Command.S
        case Effect.panbrello: 25 // Y
        case Effect.panSlide: 16 // P
        case Effect.finetune: IT2Player.xTrackerFinetune
        default: 0
        }
    }

    /// The volume column's byte for one of OpenMPT's commands there; nil for one it has no room for.
    /// Slides of pitch faster than nine, and the way a sample plays, are given bytes that Impulse
    /// Tracker leaves unused, which the replayer is told of (see `IT2Player.xTrackerColumn`); the
    /// speed of such a slide is kept beside its cell (see `IT2Module.xTrackerSlides`).
    private static func column(_ command: UInt8, _ value: UInt8) -> UInt8? {
        let nine = value <= 9
        switch command {
        case VolumeEffect.volume: return min(value, 64)
        case VolumeEffect.pan: return 128 + min(value, 64)
        case VolumeEffect.fineUp where nine: return 65 + value
        case VolumeEffect.fineDown where nine: return 75 + value
        case VolumeEffect.slideUp where nine: return 85 + value
        case VolumeEffect.slideDown where nine: return 95 + value
        case VolumeEffect.portaDown: return nine ? 105 + value : value <= 63 ? IT2Player.xTrackerWideDown : nil
        case VolumeEffect.portaUp: return nine ? 115 + value : value <= 63 ? IT2Player.xTrackerWideUp : nil
        case VolumeEffect.slideToNote where nine: return 193 + value
        case VolumeEffect.vibratoDepth where nine: return 203 + value
        case VolumeEffect.playControl where value == 2 || value == 3: return IT2Player.xTrackerForwards + value - 2
        default: return nil
        }
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        let song = try song(data)

        // MARK: Samples

        var made = (0 ..< IT2ForeignModule.sampleRoom).map { _ in IT2Sample() }
        var cutShort = Shortfall.CutShort()
        func sample(_ from: Sample, octaves: Int = 0) -> IT2Sample {
            let sound = from.sound
            var sound8: [Int8] = [], sound16: [Int16] = []
            if from.sixteen {
                sound16 = (0 ..< from.length).map { Int16(bitPattern: UInt16(sound[$0 * 2]) | UInt16(sound[$0 * 2 + 1]) << 8) }
            } else {
                sound8 = sound.prefix(from.length).map { Int8(bitPattern: $0) }
            }
            // (A volume of 256ths, which Impulse Tracker's are a quarter as fine as.)
            let volume = UInt8(((from.volume ?? 256) + 2) / 4)
            let made = IT2ForeignModule.sample(sound8: sound8, sound16: sound16, volume: volume, rate: UInt32(min(from.rate << octaves, 0x7FFF_FFFF)),
                                               loops: from.loops, loopStart: from.loopStart, loopEnd: from.loopEnd, whileHeld: true)
            made.hasVolume = from.volume != nil
            return made
        }
        for (index, from) in song.samples.enumerated() where index < made.count {
            made[index] = sample(from)
            if from.wanted > 0 { cutShort.add(length: from.wanted, there: from.there) }
        }
        let samplesLeftOut = max(0, song.samples.count - made.count)
        // The copies an octave up, for notes above the highest Impulse Tracker has, made as they are wanted.
        var copies: [Int: UInt8] = [:]
        var nextSample = song.samples.count
        func copy(of number: UInt8) -> UInt8? {
            if let made = copies[Int(number)] { return made }
            guard number >= 1, Int(number) <= min(song.samples.count, made.count), nextSample < made.count else { return nil }
            made[nextSample] = sample(song.samples[Int(number) - 1], octaves: 1)
            nextSample += 1
            copies[Int(number)] = UInt8(nextSample)
            return UInt8(nextSample)
        }

        // MARK: Patterns

        var lost = 0, notesLost = 0
        /// For each channel, true while it plays a sample's copy an octave up.
        var raised = [Bool](repeating: false, count: song.channels)
        /// The pattern packed, and the speeds of the volume column's fast slides of pitch, each by its row and channel.
        func itPattern(_ from: Pattern) -> (bytes: [UInt8], slides: [Int: UInt8]) {
            var pattern = IT2ForeignModule.Pattern(rows: from.rows)
            var slides: [Int: UInt8] = [:]
            for row in 0 ..< from.rows {
                for channel in 0 ..< min(from.channels, MAX_HOST_CHANNELS) {
                    let m = from[row, channel]
                    var cell = IT2ForeignModule.Cell()
                    var instrument = m.instrument
                    if m.isNote {
                        var note = Int(m.note) - 1
                        if note >= 120, instrument != 0, let copy = copy(of: instrument) {
                            instrument = copy
                            raised[channel] = true
                        } else if instrument != 0 {
                            raised[channel] = false
                        }
                        if raised[channel] { note -= 12 }
                        if note >= 0, note < 120 { cell.set(note: UInt8(note)) } else { notesLost += 1 }
                    } else if m.note == noteCut || m.note == noteOff {
                        cell.set(note: m.note)
                    }
                    if instrument != 0 { cell.set(instrument: instrument) }
                    if m.volumeCommand != VolumeEffect.none {
                        if let byte = column(m.volumeCommand, m.volume) {
                            cell.set(volume: byte)
                            if byte == IT2Player.xTrackerWideDown || byte == IT2Player.xTrackerWideUp { slides[IT2Player.xTrackerPlace(pattern: 0, row: row, channel: channel)] = m.volume }
                        } else {
                            lost += 1
                        }
                    }
                    if m.command != Effect.none {
                        let letter = letter(m.command)
                        if letter != 0 { cell.set(command: letter, m.value) } else { lost += 1 }
                    }
                    pattern[row, channel] = cell
                }
            }
            return (pattern.packed(), slides)
        }

        // Each place's pattern, in the order the list has them; the same pattern twice is one. A place
        // that names a pattern the file has not is passed over, as OpenMPT passes it, but for the
        // number that marks the list's end; a place beyond Impulse Tracker's room, or a pattern, ends it.
        var patterns = [[UInt8]?](repeating: nil, count: IT2ForeignModule.patternRoom)
        var rows = [UInt16](repeating: 64, count: IT2ForeignModule.patternRoom)
        var numbers: [Int: UInt8] = [:]
        var slides = [[Int: UInt8]](repeating: [:], count: IT2ForeignModule.patternRoom)
        var orders: [UInt8] = []
        var patternCount = 0, placesLeftOut = max(0, song.orders.count - 255)
        for number in song.orders.prefix(255) {
            guard number < song.patterns.count else {
                if number == Int.max { placesLeftOut += 1 }
                orders.append(number == Int.max || number == 0xFFFF ? 255 : 254)
                continue
            }
            if let known = numbers[number] {
                orders.append(known)
                continue
            }
            let (bytes, fast) = itPattern(song.patterns[number]), rowCount = UInt16(song.patterns[number].rows)
            if let same = (0 ..< patternCount).first(where: { rows[$0] == rowCount && patterns[$0] == bytes && slides[$0] == fast }) {
                numbers[number] = UInt8(same)
                orders.append(UInt8(same))
            } else if patternCount < IT2ForeignModule.patternRoom {
                patterns[patternCount] = bytes
                rows[patternCount] = rowCount
                slides[patternCount] = fast
                numbers[number] = UInt8(patternCount)
                orders.append(UInt8(patternCount))
                patternCount += 1
            } else {
                orders.append(255)
                placesLeftOut += 1
            }
        }

        var shortfalls: [String] = []
        if song.crowded > 0 {
            shortfalls.append(Shortfall.some(song.crowded, one: "notes has more commands than Impulse Tracker's replayer has room for, and one is left out.",
                                             many: "notes have more commands than Impulse Tracker's replayer has room for, and one of each is left out."))
        }
        if lost > 0 {
            shortfalls.append(Shortfall.some(lost, one: "commands has no room in Impulse Tracker's replayer, and is left out.",
                                             many: "commands have no room in Impulse Tracker's replayer, and are left out."))
        }
        if notesLost > 0 {
            shortfalls.append(Shortfall.some(notesLost, one: "notes is beyond those Impulse Tracker's replayer has, and is left out.",
                                             many: "notes are beyond those Impulse Tracker's replayer has, and are left out."))
        }
        if samplesLeftOut > 0 {
            shortfalls.append(Shortfall.some(samplesLeftOut, one: "samples is beyond the room Impulse Tracker's replayer has, and is left out.",
                                             many: "samples are beyond the room Impulse Tracker's replayer has, and are left out."))
        }
        if placesLeftOut > 0 {
            shortfalls.append(Shortfall.some(placesLeftOut, one: "places in its list of patterns is beyond the room Impulse Tracker's replayer has, and is left out.",
                                             many: "places in its list of patterns are beyond the room Impulse Tracker's replayer has, and are left out."))
        }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        let module = IT2Module(title: song.title, madeWith: song.version == 10 ? "X-Tracker 32" : "X-Tracker", orders: orders,
                               flags: ITF_STEREO | ITF_LINEAR_FRQ | ITF_COMPAT_GXX, globalVolume: 128, mixVolume: mixVolume, speed: 6, tempo: 120,
                               channelPans: [UInt8](repeating: 32, count: MAX_HOST_CHANNELS), samples: made, patterns: patterns, rows: rows)
        module.playsAsXTracker = true
        for (number, fast) in slides.enumerated() {
            for (place, speed) in fast { module.xTrackerSlides[place + IT2Player.xTrackerPlace(pattern: number, row: 0, channel: 0)] = speed }
        }
        return ITRenderer(module: module, format: "DMF", author: song.author, shortfalls: shortfalls, options: options)
    }

    /// How loud the whole is made, of Impulse Tracker's 128: set by measure, so that these files are
    /// about as loud as IT files are.
    private static let mixVolume: UInt8 = 34
}
