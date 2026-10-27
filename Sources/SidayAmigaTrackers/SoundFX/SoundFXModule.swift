// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday from a description of the file format (Claudio Matsuoka's notes on it for libxmp)
// and from what SoundFX's own replay routine makes of such a file. No code here is taken from SoundFX
// or from any other player.

import SidayFoundation

/// A module made with SoundFX on the Amiga: a file with "SONG" sixty bytes in.
///
/// It is the first Soundtracker's module in all but its wrapping. There are fifteen instruments, each
/// a sample; patterns of 64 lines for the Amiga's four voices; and a list of which pattern to play
/// when. What SoundFX added is at the front, where the lengths of the samples are written out in
/// full, and a number that sets how fast the tune goes: not a tempo, but what the Amiga's timer is
/// to count down from between one tick and the next.
///
/// The samples are not copied out. The whole file is the memory the sound chip plays from, as it was
/// on the Amiga, where the file was loaded in one piece: so a sample that is said to be longer than
/// it is goes on into whatever follows it in the file, as it did there.
final class SoundFXModule {
    struct Instrument {
        var name = ""
        /// Where its sample is in the file, and how much of it a note plays, in words.
        var start = 0
        var words: UInt16 = 0
        /// Its volume as the file has it: two bytes, of which the player goes by the lower seven bits.
        var volume: UInt16 = 0
        /// The part that repeats: where it begins, in bytes from the sample's start, and how long
        /// it is, in words.
        var repeatStart = 0
        var repeatWords: UInt16 = 0
    }

    static let instrumentCount = 15
    static let linesInPattern = 64
    /// A voice with nothing to play is pointed here, after the file: a stretch of silence.
    private static let silenceLength = 16
    /// Where the instruments are described, the order of playing, and the patterns.
    private static let headers = 80, order = 532, patterns = 660
    /// No sample is longer than this; a file that says one is, is no SoundFX module.
    private static let longestSample = 0x20000

    let instruments: [Instrument]
    /// What the timer counts down from for one tick.
    let timer: Int
    /// Which pattern is played at each place in the order of playing.
    let positions: [UInt8]
    let patternCount: Int
    /// The file, and silence after it: what the sound chip plays from.
    let memory: UnsafeMutablePointer<Int8>
    let memorySize: Int
    let silence: Int
    /// What the file asks for that is not played as it asks: see `TuneInfo.shortfalls`. A file
    /// that is shorter than its samples are said to be is played with silence where they are not.
    let shortfalls: [String]

    deinit {
        memory.deallocate()
    }

    /// True if the bytes begin as a SoundFX module does.
    static func isModule(_ data: [UInt8]) -> Bool {
        data.count > patterns && data[60] == 0x53 && data[61] == 0x4F && data[62] == 0x4E && data[63] == 0x47
    }

    init(_ data: [UInt8]) throws {
        let reader = ByteReader(data)
        guard Self.isModule(data) else {
            // The later SoundFX, with 31 instruments, is another format and another routine.
            if data.count > 128, data[124] == 0x53, data[125] == 0x4F, data[126] == 0x33, data[127] == 0x31 {
                throw TuneError.unsupported("a SoundFX 2 module, of 31 instruments")
            }
            throw TuneError.malformed("not a SoundFX module")
        }
        // The routine will not have a sample of an odd length or one too long, nor a timer of nothing.
        var lengths: [Int] = []
        for i in 0 ..< Self.instrumentCount {
            let high = reader.u16be(i * 4), low = reader.u16be(i * 4 + 2)
            guard high <= 2, low & 1 == 0, high << 16 | low <= Self.longestSample else { throw TuneError.malformed("not a SoundFX module") }
            lengths.append(high << 16 | low)
        }
        timer = reader.u16be(64)
        guard timer != 0 else { throw TuneError.malformed("a SoundFX module with no tempo") }

        let length = Int(reader[530])
        guard length > 0, length <= 128 else { throw TuneError.malformed("a SoundFX module with nothing to play") }
        var positions: [UInt8] = []
        for i in 0 ..< length { positions.append(reader[Self.order + i]) }
        self.positions = positions
        // There are as many patterns as the highest number in the order needs, and the samples
        // follow them.
        patternCount = Int(positions.max() ?? 0) + 1
        // A module whose samples are all missing or silent has nothing to be heard by. (The routine
        // clears the first four bytes of each, as below.)
        var sampleAt = Self.patterns + patternCount * Self.linesInPattern * 16, sounds = false
        for length in lengths {
            if !sounds, length > 4 { sounds = Shortfall.sounds(data[min(data.count, sampleAt + 4) ..< min(data.count, sampleAt + length)]) }
            sampleAt += length
        }
        guard sounds else { throw Shortfall.nothingToHear }

        silence = data.count
        memorySize = data.count + Self.silenceLength
        memory = .allocate(capacity: memorySize)
        memory.initialize(repeating: 0, count: memorySize)
        for i in 0 ..< data.count { memory[i] = Int8(bitPattern: data[i]) }

        var instruments: [Instrument] = []
        var place = Self.patterns + patternCount * Self.linesInPattern * 16
        var cutShort = Shortfall.CutShort()
        for i in 0 ..< Self.instrumentCount {
            let header = Self.headers + i * 30
            var instrument = Instrument()
            instrument.name = reader.ascii(at: header, length: 22)
            instrument.start = place
            instrument.words = UInt16(reader.u16be(header + 22))
            instrument.volume = UInt16(reader.u16be(header + 24))
            instrument.repeatStart = reader.u16be(header + 26)
            instrument.repeatWords = UInt16(reader.u16be(header + 28))
            instruments.append(instrument)
            // The routine clears the first four bytes of each sample there is, so that one which
            // does not repeat has silence to end on.
            if lengths[i] != 0 {
                for k in 0 ..< 4 where place + k < data.count { memory[place + k] = 0 }
            }
            cutShort.add(length: lengths[i], there: data.count - place)
            place += lengths[i]
        }
        self.instruments = instruments
        shortfalls = cutShort.sentence.map { [$0] } ?? []
    }

    /// A byte of the file as it lay in the Amiga's memory; nought beyond its end.
    @inline(__always) func byte(_ at: Int) -> UInt8 {
        at >= 0 && at < silence ? UInt8(bitPattern: memory[at]) : 0
    }

    /// What a voice has on a line of a pattern: the period of a note, an instrument and a command
    /// in the two halves of a byte, and the command's number.
    @inline(__always) func cell(pattern: Int, line: Int, voice: Int) -> (period: UInt16, instrument: UInt8, command: UInt8, data: UInt8) {
        let at = Self.patterns + (pattern * Self.linesInPattern + line) * 16 + voice * 4
        return (UInt16(byte(at)) << 8 | UInt16(byte(at + 1)), byte(at + 2) >> 4, byte(at + 2) & 15, byte(at + 3))
    }
}
