// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT's Load_fmt.cpp, and from what its OPL.cpp, Snd_fx.cpp and Sndmix.cpp do with
// the module that loader makes, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors;
// used under the BSD 3-Clause License (see THIRD-PARTY.md).

/// An FMT file as it is read: a song from Davey W Taylor's FM Tracker, a tracker for the AdLib card.
///
/// It has eight voices, and each keeps one instrument for the whole song: the eleven numbers the
/// chip is given for it, in the file's header. A pattern holds nothing but notes and the places
/// where notes stop, a voice at a time, with runs of empty rows packed into a byte. The song is a
/// list of patterns to play in turn, each with a delay: how many ticks of the PC's timer a row lasts.
///
/// The tracker left no description of its files. This is what OpenMPT's loader makes of them.
struct FMTFile {
    static let voices = 8
    /// The header: what the file is, the tracker's name and the song's, the eight instruments (a
    /// name of eight letters and the eleven numbers), and the last row, order and pattern.
    private static let headerLength = 11 + 20 + 32 + voices * 19 + 3

    var tracker = ""
    var title = ""
    /// Each voice's instrument: for the first operator and then the second, what goes in the chip's
    /// registers 0x20, 0x40, 0x60, 0x80 and 0xE0, and then what goes in the voice's 0xC0.
    var instruments: [[UInt8]] = []
    /// How many rows every pattern has.
    var rows = 0
    /// The number of the pattern played at each place in the song.
    var orders: [UInt8] = []
    /// And that place's delay: the ticks to a row, from one to eight.
    var delays: [UInt8] = []
    /// Where each pattern begins in `cells`, by the pattern's number; -1 for one the file has not got.
    private var places = [Int](repeating: -1, count: 256)
    /// The patterns, a row at a time and eight voices to the row: nought for nothing, one for a
    /// note's end, and from 2 to 97 for a note.
    private var cells: [UInt8] = []
    /// True if the file ended before the end of its patterns.
    var cutShort = false

    init(_ data: [UInt8]) throws {
        let file = ByteReader(data)
        guard data.count >= Self.headerLength, file.ascii(at: 0, length: 9) == "FMTracker", file[9] == 1, file[10] == 1 else {
            throw TuneError.malformed("not an FMT file")
        }
        tracker = file.ascii(at: 11, length: 20)
        title = file.dos(at: 31, length: 32)
        for voice in 0 ..< Self.voices {
            let sound = 63 + voice * 19 + 8
            instruments.append((0 ..< 11).map { file[sound + $0] })
        }
        rows = Int(file[215]) + 1
        let orderCount = Int(file[216]) + 1, patternCount = Int(file[217]) + 1

        // The list of patterns to play, their delays, which pattern each of the file's is, and then
        // the patterns: of each, a byte for each voice at the least.
        var at = Self.headerLength
        guard data.count >= at + orderCount * 2 + patternCount * 9 else { throw TuneError.malformed("FMT file cut short") }
        orders = Array(data[at ..< at + orderCount])
        delays = Array(data[at + orderCount ..< at + orderCount * 2])
        guard !delays.contains(where: { $0 < 1 || $0 > 8 }) else { throw TuneError.malformed("FMT file with a delay the tracker does not have") }
        let numbers = at + orderCount * 2
        at = numbers + patternCount

        for index in 0 ..< patternCount {
            let number = Int(file[numbers + index])
            // (OpenMPT reads no further than a pattern whose number has been used.)
            if places[number] >= 0 { break }
            let start = cells.count
            places[number] = start
            cells.append(contentsOf: repeatElement(0, count: rows * Self.voices))
            // A voice at a time, down the rows. A byte with its top bit set is that many empty rows
            // and one more. A file cut short reads as nothing from there on.
            for voice in 0 ..< Self.voices {
                var row = 0
                while row < rows {
                    let byte = file[at]
                    at += 1
                    if byte & 0x80 != 0 {
                        row += Int(byte & 0x7F)
                    } else if byte >= 1, byte <= 97 {
                        cells[start + row * Self.voices + voice] = byte
                    }
                    row += 1
                }
            }
        }
        cutShort = at > data.count
    }

    /// What a voice has on a row of the pattern at a place in the song. A place that asks for a
    /// pattern the file has not got is played as an empty one.
    func cell(order: Int, row: Int, voice: Int) -> UInt8 {
        let start = places[Int(orders[order])]
        return start < 0 ? 0 : cells[start + row * Self.voices + voice]
    }
}

/// An FMT file being played: the tracker's player, as far as it can be known from what OpenMPT does
/// with these files, setting the chip's registers on the PC's timer.
///
/// On a row's first tick each voice's note is struck, or stopped. A note is stopped by giving the
/// voice a pitch of nothing with its key up, so it does not die away as its instrument would have
/// it: it is gone. A note struck while another sounds lets that one's key up first, so that the
/// chip starts the new one from the beginning.
///
/// The song goes round for ever in the tracker. Here it is over when its list of patterns has been
/// played through, and the keys are let up for the last notes to die away.
final class FMTTune: OPLTune {
    static var voices: Int { FMTFile.voices }
    /// Set by measure: the tracker's songs keep their instruments at the levels they were made with
    /// and play them all at once, and at the gain of the other tunes for the chip come out twice as
    /// loud as those do.
    static var gain: Float { 0.7 }

    /// What the PC's timer counts down from when nothing has set it: 65,536, which is 18.2 ticks a
    /// second. A tick is that many twenty-fourths of one of the chip's samples (see `CMFTune`).
    private static var period: Int { 65536 }
    /// Where each voice's first operator is among the chip's registers. Its second is three on.
    private static let operators = [0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11]
    /// The chip's octave and number for each of the 96 notes: see `pitch(of:)`.
    private static let pitches: [UInt16] = (2 ... 97).map { pitch(of: $0) }

    private let file: FMTFile
    /// Sets one of the chip's registers.
    private let write: (Int, UInt8) -> Void
    /// The row that is played next: its place in the song, and which row of the pattern there.
    private var order = 0, row = 0
    /// The ticks still to go before it is played.
    private var wait = 0
    /// What each voice's register 0xB0 was last set to: its key, its octave and the top of its number.
    private var keys = [UInt8](repeating: 0, count: FMTFile.voices)
    /// The part of a sample that ticks are over by, in twenty-fourths.
    private var remainder = 0

    var detail: String { file.tracker.isEmpty ? "FM Tracker" : file.tracker }

    /// - Parameter write: what sets a register of the chip the tune is played on: its number, and
    ///   the value.
    init(_ file: FMTFile, write: @escaping (Int, UInt8) -> Void) {
        self.file = file
        self.write = write

        write(0x01, 0x20) // the chip is to heed the waveforms it is given
        for voice in 0 ..< FMTFile.voices {
            let sound = file.instruments[voice], first = Self.operators[voice]
            for (index, register) in [0x20, 0x40, 0x60, 0x80, 0xE0].enumerated() {
                write(register + first, sound[index * 2])
                write(register + first + 3, sound[index * 2 + 1])
            }
            write(0xC0 + voice, sound[10])
        }
    }

    /// The chip's octave and number for a note, as OpenMPT arrives at them: the octave in the three
    /// bits above the number's ten, as the chip's two registers for a voice's pitch have them.
    ///
    /// Nobody has written down the tracker's own table of pitches. OpenMPT plays these files as
    /// Scream Tracker modules whose instruments have middle C at 8,215 samples a second, where
    /// Scream Tracker's own is 8,363: a third of a semitone flat. This goes the way OpenMPT goes, a
    /// step at a time and in whole numbers as it does, so that every note is given the chip exactly
    /// as OpenMPT gives it: a Scream Tracker period for the note (which, being whole, leaves the
    /// highest notes as much as a sixth of a semitone out), the rate that period stands for, in
    /// sixteenths of a sample a second, the pitch that rate stands for, in thousandths of a cycle a
    /// second (8,363 being 261.625 Hz), and then the lowest of the chip's octaves that reaches the
    /// pitch, where its number is finest.
    static func pitch(of note: UInt8) -> UInt16 {
        let periods: [UInt64] = [1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 907]
        // The lowest note, 2, is the C sharp of the second of OpenMPT's octaves.
        let key = UInt64(note) + 11
        let period: UInt64 = 8363 * (periods[Int(key % 12)] << 5) / (8215 << (key / 12))
        let rate: UInt64 = 8363 * (1712 << 12) / (period << 8)
        let milliHertz: UInt64 = (rate * 261_625 + (8363 << 3)) / (8363 << 4)
        var block: UInt64 = 0
        while block < 7, milliHertz > 6_208_431 >> (7 - block) { block += 1 }
        // The chip makes 49,716 samples a second, and a number of 2^20 in its lowest octave would be
        // a cycle to the sample.
        let number: UInt64 = min(1023, ((milliHertz << (20 - block)) + 24_858_000) / 49_716_000)
        return UInt16(block << 10 | number)
    }

    /// The next row: each voice's note, or the end of one.
    private func playRow() {
        for voice in 0 ..< FMTFile.voices {
            let cell = file.cell(order: order, row: row, voice: voice)
            if cell == 1 {
                write(0xA0 + voice, 0)
                write(0xB0 + voice, 0)
                keys[voice] = 0
            } else if cell >= 2 {
                let pitch = Self.pitches[Int(cell) - 2]
                if keys[voice] & 0x20 != 0 { write(0xB0 + voice, keys[voice] & ~0x20) }
                keys[voice] = 0x20 | UInt8(pitch >> 8)
                write(0xA0 + voice, UInt8(pitch & 0xFF))
                write(0xB0 + voice, keys[voice])
            }
        }
    }

    func tick() -> Int? {
        if wait == 0 {
            guard order < file.orders.count else {
                for voice in 0 ..< FMTFile.voices where keys[voice] & 0x20 != 0 {
                    keys[voice] &= ~0x20
                    write(0xB0 + voice, keys[voice])
                }
                return nil
            }
            playRow()
            row += 1
            if row == file.rows {
                row = 0
                order += 1
            }
            // The tracker's player waited out a delay and then played a row, where others play the
            // row and then wait. So a row lasts not for the delay of the pattern it is in but for
            // that of the pattern the next row is in: the last row of each pattern is played at the
            // next one's speed, and the last of all at the first's, the song going round.
            wait = Int(file.delays[order % file.delays.count])
        }
        wait -= 1
        remainder += Self.period
        let samples = remainder / 24
        remainder %= 24
        return samples
    }

    /// A player for an FMT file.
    static func renderer(_ data: [UInt8]) throws -> OPLRenderer<FMTTune> {
        let file = try FMTFile(data)
        var info = TuneInfo(format: "FMT")
        info.title = file.title
        if file.cutShort { info.shortfalls.append("The file is cut short: the patterns it ends before are played as far as they go, and then as silence.") }
        return OPLRenderer(info: info) { card in
            FMTTune(file) { register, value in card?.write(register, value) }
        }
    }
}
