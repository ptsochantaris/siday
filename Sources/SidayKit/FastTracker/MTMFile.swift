// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the MTM loaders of libxmp, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito
// Carraro Jr, used under the MIT licence, and of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project
// Developers and Contributors and (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause
// licence (see THIRD-PARTY.md).

/// A module made with MultiTracker, Renaissance's tracker for the PC and the Gravis Ultrasound: a
/// file that begins "MTM".
///
/// It is a MOD file taken apart and widened. Up to 32 channels, each with one of sixteen places
/// between the speakers; a pattern is not written out whole but is a list of tracks, one for each
/// channel, so that a track played by several patterns is stored once; and the notes are numbers
/// and not periods. The commands are ProTracker's.
///
/// This player has no replayer of MultiTracker's own. The file is read into what FastTracker 2
/// plays (see `ForeignModule`), and where the two trackers differ it is FastTracker that is heard.
enum MTMFile {
    private static let headerLength = 66, sampleHeaderLength = 37, trackLength = 192

    static func read(_ data: [UInt8]) throws -> ForeignModule {
        let file = ByteReader(data)
        guard data.count >= headerLength, data[0] == 0x4D, data[1] == 0x54, data[2] == 0x4D else {
            throw TuneError.malformed("not an MTM file")
        }
        let version = Int(data[3])
        let tracks = file.u16le(24), patterns = Int(data[26]) + 1, orders = Int(data[27]) + 1
        let commentLength = file.u16le(28), samples = Int(data[30]), channels = Int(data[33])
        guard version < 0x20 else { throw TuneError.unsupported("an MTM file of a version this player does not know") }
        guard channels >= 1, channels <= 32 else { throw TuneError.unsupported("an MTM file of \(channels) channels") }
        guard orders <= 128 else { throw TuneError.malformed("an MTM file with a longer order than it has room for") }
        // A track is always 64 rows in the file. MultiTracker itself makes no pattern of any other length.
        let rows = data[32] == 0 || data[32] > 64 ? 64 : Int(data[32])

        let sampleHeaders = headerLength
        let orderList = sampleHeaders + samples * sampleHeaderLength
        let trackData = orderList + 128
        let patternTable = trackData + tracks * trackLength
        let comment = patternTable + patterns * 64
        guard comment <= data.count else { throw TuneError.malformed("an MTM file that ends in its patterns") }

        var module = ForeignModule(format: "MTM")
        module.tracker = "MultiTracker \(version >> 4).\(version & 15)"
        module.title = file.ascii(at: 4, length: 20)
        module.channels = channels
        // (By measure: the middle one of 394 files was a decibel louder than the middle one of 200 XM files.)
        module.loudness = 0.9
        module.orders = (0 ..< orders).map { file[orderList + $0] }
        // One of sixteen places, as the Gravis Ultrasound has them.
        module.panning = (0 ..< channels).map { (data[34 + $0] & 15) * 17 }

        var setsSpeed = false, setsTempo = false, setsBothOnOneRow = false
        for pattern in 0 ..< patterns {
            var notes = [FT2Note](repeating: FT2Note(), count: rows * channels)
            for channel in 0 ..< channels {
                // Track 0 is an empty one, and is not in the file.
                let track = file.u16le(patternTable + pattern * 64 + channel * 2)
                guard track >= 1, track <= tracks else { continue }
                let start = trackData + (track - 1) * trackLength
                for row in 0 ..< rows {
                    notes[row * channels + channel] = note(data[start + row * 3], data[start + row * 3 + 1], data[start + row * 3 + 2])
                }
            }
            for row in 0 ..< rows {
                var speed = false, tempo = false
                for channel in 0 ..< channels where notes[row * channels + channel].effTyp == 0xF {
                    if notes[row * channels + channel].eff < 0x20 { speed = true } else { tempo = true }
                }
                setsSpeed = setsSpeed || speed
                setsTempo = setsTempo || tempo
                setsBothOnOneRow = setsBothOnOneRow || (speed && tempo)
            }
            module.patterns.append(ForeignModule.Pattern(rows: rows, notes: notes))
        }
        // In MultiTracker a command that sets the speed puts the tempo back to 125, and one that
        // sets the tempo puts the speed back to 6. The other players of the day did not know it,
        // and played the command as ProTracker does; and many who wrote MTM files wrote them for
        // those players, and never heard them in MultiTracker at all. A file that sets both on one
        // row can only have been meant for a player where both hold; one that never does is taken
        // to be MultiTracker's own. (Both libxmp and OpenMPT tell the two apart this way.)
        module.speedAndTempoUndoEachOther = setsSpeed && setsTempo && !setsBothOnOneRow

        var at = comment + commentLength
        for index in 0 ..< min(samples, 128) {
            let header = sampleHeaders + index * sampleHeaderLength
            let length = file.size32le(header + 22)
            let sixteenBit = data[header + 36] & 1 != 0
            var sample = ForeignModule.Sample()
            sample.sixteenBit = sixteenBit
            // The sample is unsigned in the file.
            sample.data = file.sample(at: at, length: length)
            let top = sixteenBit ? 1 : 0, step = sixteenBit ? 2 : 1
            for i in stride(from: top, to: sample.data.count, by: step) { sample.data[i] ^= 0x80 }
            at += min(length, sample.data.count)

            // The repeat runs from its start up to its end, as libxmp has it. (OpenMPT stops it a
            // sample sooner. But the short repeats of these files, which are a note's whole pitch,
            // are 12, 24, 32, 64 and 128 samples long this way, an octave apart from one another,
            // and are 11, 23, 31, 63 and 127 that way, which are out of tune with one another.)
            let repeatStart = file.size32le(header + 26), repeatEnd = min(file.size32le(header + 30), sample.data.count)
            if repeatEnd > 2, repeatEnd > repeatStart {
                sample.repeatStart = repeatStart
                sample.repeatLength = repeatEnd - repeatStart
            }
            // A fine tuning in eighths of a semitone. Some files have one below nought as a MOD
            // file does, in four bits, and some as a whole signed byte: this reads both as below
            // nought, which is libxmp's way. (OpenMPT takes 9 to 15 for that many eighths upward.)
            sample.fineTune = Int8(bitPattern: data[header + 34] << 4)
            sample.volume = min(64, data[header + 35])
            module.samples.append(sample.data.isEmpty ? nil : sample)
        }
        return module
    }

    /// The three bytes of a note: six bits of note, six of instrument, four of command, and a byte
    /// for the command.
    private static func note(_ first: UInt8, _ second: UInt8, _ value: UInt8) -> FT2Note {
        var note = FT2Note()
        // (Note 12 is the lowest note an Amiga's MOD file has, and note 24 the C in the middle.)
        if first >> 2 != 0 { note.ton = (first >> 2) + 25 }
        note.instr = (first & 3) << 4 | second >> 4
        let command = second & 15
        switch command {
        case 0x8:
            // MultiTracker has no such command. The files that use it were written for DSMI's
            // player, where it puts the channel between 00 on the left and 80 on the right, and
            // A4 is its surround sound, which here is the middle: of the 706 there are in the
            // files to hand, all but seven have those values. (This is neither of the other
            // players' reading. libxmp takes it for a place from 00 to FF, and OpenMPT, going by
            // MultiTracker, leaves it out.)
            if value <= 0x80 {
                note.effTyp = 8
                note.eff = UInt8(min(255, Int(value) * 2))
            } else if value == 0xA4 {
                note.effTyp = 8
                note.eff = 128
            }
        case 0xD:
            // The row to break to is a plain number, not ProTracker's tens and ones.
            note.effTyp = 0xD
            note.eff = ForeignModule.breakTo(row: Int(value))
        case 0xE:
            switch value >> 4 {
            // The commands MultiTracker does not have.
            case 0x0, 0x3, 0x4, 0x6, 0x7, 0xF: break
            // One of the sixteen places, which FastTracker has as a command of its own.
            case 0x8:
                note.effTyp = 8
                note.eff = (value & 15) * 17
            default:
                note.effTyp = command
                note.eff = value
            }
        case 0xF:
            // (A speed of nothing stops FastTracker, and does nothing here.)
            if value != 0 {
                note.effTyp = command
                note.eff = value
            }
        default:
            (note.effTyp, note.eff) = ForeignModule.tidied(command, value)
        }
        return note
    }
}
