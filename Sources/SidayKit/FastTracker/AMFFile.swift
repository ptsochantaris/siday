// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the AMF loaders of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence, and of
// libxmp, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito Carraro Jr, used under the MIT
// licence (see THIRD-PARTY.md).

/// A module in the Advanced Module Format of DSMI, Otto Chrons's Digital Sound and Music Interface:
/// a file that begins "AMF" and a version number.
///
/// Nobody composed in it. DSMI is the engine of the Dual Module Player and of many games for the
/// PC, and this is the one shape it turned every module into before playing it: a MOD file, an
/// S3M, an MTM, whatever its converter could read. So its commands are none of those trackers'
/// own but a list that covers them all, each with a number that may be below nought; a channel's
/// notes are kept as a track, a list of things that happen and the rows they happen on, which
/// several patterns may share; and a row may have more commands than one.
///
/// The format grew with the player, and the file says which of its versions it is: 1 and 8 to 14
/// are read, which is all that are known. (The files of the ASYLUM music system, from the Crusader
/// games, are called AMF too and are another thing, not read here.)
///
/// This player has no DSMI. The file is read into what FastTracker 2 plays (see `ForeignModule`),
/// and where the two differ it is FastTracker that is heard.
enum AMFFile {
    /// What a track has for one row, before it is fitted into the note, the volume and the one
    /// command that FastTracker has room for.
    private struct Cell {
        var note = FT2Note()
        /// A place for the channel, where the row sets one.
        var place: UInt8?
        /// True if the row has had a command that another then took the place of.
        var crowded = false
    }

    /// What is met in a file that FastTracker cannot do, for `ForeignModule.shortfalls`.
    private struct Found {
        /// Notes below the lowest that FastTracker has, and above its highest.
        var tooLow = 0, tooHigh = 0
        var surround = false
        /// True if some row has more commands for a channel than there is room for.
        var crowded = false
        var cutShort = Shortfall.CutShort()

        var sentences: [String] {
            var sentences: [String] = []
            if tooLow > 0 {
                sentences.append(Shortfall.some(tooLow, one: "notes is below FastTracker's lowest, and is not heard.", many: "notes are below FastTracker's lowest, and are not heard."))
            }
            if tooHigh > 0 {
                sentences.append(Shortfall.some(tooHigh, one: "notes is above FastTracker's highest, and is not heard.", many: "notes are above FastTracker's highest, and are not heard."))
            }
            if surround { sentences.append("Its surround sound is played in the middle.") }
            if crowded { sentences.append("Some of its rows have more commands for a channel than FastTracker has room for, and the rest are left out.") }
            if let sentence = cutShort.sentence { sentences.append(sentence) }
            return sentences
        }
    }

    private struct SampleHeader {
        var exists = false
        /// Which of the sounds in the file is this sample's, counting from 1.
        var index = 0
        var length = 0
        var rate = 0
        var volume: UInt8 = 0
        var repeatStart = 0
        var repeatEnd = 0
    }

    static func read(_ data: [UInt8]) throws -> ForeignModule {
        let file = ByteReader(data)
        if data.starts(with: Array("ASYLUM Music Format".utf8)) {
            throw TuneError.unsupported("an ASYLUM module, which is another kind of AMF file than DSMI's")
        }
        guard data.count >= 41, data[0] == 0x41, data[1] == 0x4D, data[2] == 0x46 else { throw TuneError.malformed("not an AMF file") }
        let version = Int(data[3])
        guard version == 1 || (version >= 8 && version <= 14) else { throw TuneError.unsupported("an AMF file of a version this player does not know") }
        let sampleCount = Int(data[36]), orders = Int(data[37]), trackNumbers = file.u16le(38)
        // The oldest files are of four channels and do not say so.
        let channels = version >= 9 ? Int(data[40]) : 4
        guard sampleCount > 0, orders > 0, trackNumbers > 0 else { throw TuneError.malformed("an AMF file with nothing in it") }
        guard channels >= 1, channels <= (version < 12 ? 16 : 32) else { throw TuneError.unsupported("an AMF file of \(channels) channels") }

        var module = ForeignModule(format: "AMF")
        module.tracker = "DSMI, format \(version / 10).\(version % 10)"
        module.title = file.ascii(at: 4, length: 32)
        module.channels = channels
        // (By measure: the middle one of 38 files was nearly four decibels louder than the middle
        // one of 200 XM files.)
        module.loudness = 0.64
        module.orders = (0 ..< orders).map { UInt8($0) }
        var found = Found()

        var at = version >= 9 ? 41 : 40
        if version >= 11 {
            // Where each channel is, from 64 to the left of the middle to 64 to the right; and 100
            // for DSMI's surround sound, which here is the middle.
            module.panning = (0 ..< channels).map { place(file[at + $0]) }
            found.surround = (0 ..< channels).contains { file[at + $0] == 100 }
            at += version >= 12 ? 32 : 16
        } else {
            // An older file does not say, and has its channels to the left and to the right in turn.
            // (From version 9 a table follows that says what order the channels were in before:
            // nothing reads it.)
            module.panning = (0 ..< channels).map { $0 & 1 == 0 ? ForeignModule.leftward : ForeignModule.rightward }
            if version >= 9 { at += 16 }
        }
        if version >= 13 {
            if file[at] >= 32 { module.tempo = Int(file[at]) }
            if file[at + 1] != 0 { module.speed = Int(file[at + 1]) }
            at += 2
        }

        // The order: for each place in it, a track for each channel. So each place is a pattern.
        let orderTable = at, orderLength = channels * 2 + (version >= 14 ? 2 : 0)
        at += orders * orderLength

        // What is said of each sample. One converter wrote version 10's longer account of a sample
        // at the old length, so that the last six bytes of it are missing: known by a sample that
        // makes no sense read at the full length.
        var truncated = false
        if version == 10 {
            for index in 0 ..< sampleCount {
                let header = at + index * 65
                guard header + 65 <= data.count else { break }
                let length = file.size32le(header + 50)
                if file[header] > 1 || file.size32le(header + 46) > sampleCount || length > 0x100000 || file[header + 56] > 64
                    || file.size32le(header + 57) > length || file.size32le(header + 61) > length
                {
                    truncated = true
                    break
                }
            }
        }
        var headers: [SampleHeader] = []
        for _ in 0 ..< sampleCount {
            var header = SampleHeader()
            header.exists = file[at] != 0
            header.index = file.size32le(at + 46)
            if version < 10 {
                header.length = file.u16le(at + 50)
                header.rate = file.u16le(at + 52)
                header.volume = file[at + 54]
                header.repeatStart = file.u16le(at + 55)
                header.repeatEnd = file.u16le(at + 57)
                // (An end of FFFF is how these say there is no repeat.)
                if header.repeatEnd == 0xFFFF { header.repeatEnd = 0 }
                at += 59
            } else {
                header.length = file.size32le(at + 50)
                header.rate = file.u16le(at + 54)
                header.volume = file[at + 56]
                if truncated {
                    header.repeatStart = file.u16le(at + 57)
                    header.repeatEnd = header.repeatStart > 0 ? header.length : 0
                    at += 59
                } else {
                    header.repeatStart = file.size32le(at + 57)
                    header.repeatEnd = file.size32le(at + 61)
                    at += 65
                }
            }
            headers.append(header)
        }

        // The tracks: a table from the numbers the order uses to the tracks that are in the file,
        // and then those, each a count of events and the events, three bytes each.
        let trackTable = at
        at += trackNumbers * 2
        guard at <= data.count else { throw TuneError.malformed("an AMF file that ends before its tracks") }
        var trackCount = 0
        for number in 0 ..< trackNumbers { trackCount = max(trackCount, file.u16le(trackTable + number * 2)) }
        var tracks: [(start: Int, events: Int)] = []
        tracks.reserveCapacity(trackCount)
        for _ in 0 ..< trackCount {
            guard at <= data.count else {
                tracks.append((at, 0))
                continue
            }
            // (The oldest version's count leaves out the mark that ends a track.)
            let events = file.u16le(at) == 0 ? 0 : file.u16le(at) + (version == 1 ? 1 : 0)
            tracks.append((at + 3, min(events, max(0, data.count - at - 3) / 3)))
            at += 3 + events * 3
        }

        for pattern in 0 ..< orders {
            let entry = orderTable + pattern * orderLength
            let rows = version >= 14 ? max(1, min(256, file.u16le(entry))) : 64
            var notes = [FT2Note](repeating: FT2Note(), count: rows * channels)
            for channel in 0 ..< channels {
                let number = file.u16le(entry + (version >= 14 ? 2 : 0) + channel * 2)
                guard number >= 1, number <= trackNumbers else { continue }
                let track = file.u16le(trackTable + (number - 1) * 2)
                guard track >= 1, track <= trackCount else { continue }
                var cells = [Cell](repeating: Cell(), count: rows)
                for event in 0 ..< tracks[track - 1].events {
                    let from = tracks[track - 1].start + event * 3
                    // (An event on a row the pattern has not got ends the track, as its own mark of three FFs does.)
                    guard Int(data[from]) < rows else { break }
                    happen(data[from + 1], data[from + 2], to: &cells[Int(data[from])], &found)
                }
                for row in 0 ..< rows { notes[row * channels + channel] = fitted(cells[row], &found) }
            }
            module.patterns.append(ForeignModule.Pattern(rows: rows, notes: notes))
        }

        // The sounds follow in the order of their numbers, and a sample says which number is its
        // own. They are unsigned in the file.
        for number in 1 ... sampleCount where at < data.count {
            var read = 0
            for (index, header) in headers.enumerated() where header.index == number && index < 128 {
                while module.samples.count <= index { module.samples.append(nil) }
                var sample = ForeignModule.Sample()
                sample.data = file.sample(at: at, length: header.length)
                found.cutShort.add(length: header.length, there: data.count - at)
                for i in 0 ..< sample.data.count { sample.data[i] ^= 0x80 }
                read = min(header.length, sample.data.count)
                if header.exists, header.repeatEnd > header.repeatStart + 2, header.repeatEnd <= header.length {
                    sample.repeatStart = header.repeatStart
                    sample.repeatLength = header.repeatEnd - header.repeatStart
                }
                sample.volume = min(64, header.volume)
                sample.rate = header.rate > 0 ? header.rate : 8363
                module.samples[index] = sample.data.isEmpty ? nil : sample
            }
            at += read
        }
        // (A sample past the 128th is one FastTracker has no room for, and is refused with the rest.)
        while module.samples.count < sampleCount { module.samples.append(nil) }
        module.shortfalls = found.sentences
        return module
    }

    /// A place between the speakers as DSMI has it, made one as FastTracker has it.
    private static func place(_ value: UInt8) -> UInt8 {
        value == 100 ? 128 : UInt8(min(255, max(0, Int(Int8(bitPattern: value)) + 64) * 2))
    }

    /// A slide of the volume: up by a number above nought, down by one below.
    private static func slide(_ value: UInt8) -> UInt8 {
        value & 0x80 != 0 ? (0 &- value) & 0x0F : (value & 0x0F) << 4
    }

    /// One event of a track, added to what its row has so far.
    private static func happen(_ kind: UInt8, _ value: UInt8, to cell: inout Cell, _ found: inout Found) {
        func command(_ number: UInt8, _ data: UInt8) {
            // (The same command given again is the converter repeating itself, and nothing is lost.)
            if cell.note.effTyp != 0 || cell.note.eff != 0, cell.note.effTyp != number || cell.note.eff != data { cell.crowded = true }
            cell.note.effTyp = number
            cell.note.eff = data
        }
        let signed = Int(Int8(bitPattern: value)), low = value & 0x0F
        switch kind {
        case 0 ..< 0x7F:
            if kind == 0, value == 0 {
                // A note of nothing at no volume is how a note is cut.
                cell.note.vol = 0x10
            } else {
                // The note in the middle of the keyboard is 60; FastTracker's lowest is an octave above DSMI's.
                if kind >= 12, kind <= 107 { cell.note.ton = kind - 11 } else if kind < 12 { found.tooLow += 1 } else { found.tooHigh += 1 }
                // With its volume, or FF for the volume the channel has.
                if value != 0xFF { cell.note.vol = 0x10 + min(64, value) }
            }
        // (Written where a MOD file changed instrument with no note: there is nothing to do.)
        case 0x7F: break
        case 0x80: cell.note.instr = value < 128 ? value + 1 : 0
        // The speed, in ticks to a row. FastTracker's command for it stops at 31.
        case 0x81: if value != 0 { command(0xF, min(31, value)) }
        case 0x82: command(0xA, slide(value))
        case 0x83: cell.note.vol = 0x10 + min(64, value)
        // A slide of the pitch: down by a number above nought, up by one below.
        case 0x84: signed >= 0 ? command(0x2, value) : command(0x1, UInt8(-signed & 0x7F))
        case 0x86: command(0x3, value)
        // The converter wrote tremolo and tremor both as this. Tremolo is the commoner, and the
        // one that does less harm where it is wrong.
        case 0x87: command(0x7, value)
        case 0x88: command(0x0, value)
        case 0x89: command(0x4, value)
        case 0x8A: command(0x5, slide(value))
        case 0x8B: command(0x6, slide(value))
        case 0x8C: command(0xD, value)
        case 0x8D: command(0xB, value)
        case 0x8F: command(0xE, 0x90 | low)
        case 0x90: command(0x9, value)
        // The fine slides, done once on a row: of the volume, and of the pitch by a little and by less.
        case 0x91: if signed != 0 { command(0xE, signed > 0 ? 0xA0 | low : 0xB0 | (0 &- value) & 0x0F) }
        case 0x92: if signed != 0 { command(0xE, signed > 0 ? 0x20 | low : 0x10 | (0 &- value) & 0x0F) }
        case 0x93: command(0xE, 0xD0 | low)
        case 0x94: command(0xE, 0xC0 | low)
        // The tempo, in beats a minute.
        case 0x95: command(0xF, max(32, value))
        case 0x96: if signed != 0 { command(33, signed > 0 ? 0x20 | low : 0x10 | (0 &- value) & 0x0F) }
        case 0x97:
            cell.place = place(value)
            if value == 100 { found.surround = true }
        // The two that nobody knows the meaning of, and anything else.
        default: break
        }
    }

    /// A row of a track as FastTracker has room for it: a note, a volume and one command. A place
    /// for the channel is a command, if the row has no other, and otherwise goes where the volume
    /// would, if the row has none, at one of sixteen places.
    private static func fitted(_ cell: Cell, _ found: inout Found) -> FT2Note {
        var note = cell.note
        if cell.crowded { found.crowded = true }
        guard let place = cell.place else { return note }
        if note.effTyp == 0, note.eff == 0 {
            note.effTyp = 8
            note.eff = place
        } else if note.vol == 0 {
            note.vol = 0xC0 | place >> 4
        } else {
            found.crowded = true
        }
        return note
    }
}
