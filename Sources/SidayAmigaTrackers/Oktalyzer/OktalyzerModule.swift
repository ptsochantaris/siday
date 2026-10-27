// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday from a description of the file format (Harald Zappe's "oktafmt.txt", with what
// Bryan Ford and others told him) and from what Oktalyzer's own replay routine makes of such a file.
// No code here is taken from Oktalyzer or from any other player.

import SidayFoundation

/// A module made with Oktalyzer on the Amiga: a file that begins "OKTASONG".
///
/// Oktalyzer was the first tracker to get eight tracks out of the Amiga's four voices. Each voice
/// is either left as it is, with a track to itself, or is split in two: then it has two tracks,
/// and the player mixes them into one stream for the voice to play. A module says which of its
/// voices are split, so it has from four tracks to eight.
///
/// The file is a list of pieces, each with a name of four letters and a length: which voices are
/// split, the instruments, the speed, the order of playing, then the patterns one by one (each as
/// many lines long as its composer liked) and the samples one by one.
///
/// The samples are not copied out. The whole file is the memory the sound chip plays from, as it was
/// on the Amiga, where the file was loaded in one piece: so a sample that is said to be longer than
/// it is goes on into whatever follows it in the file, as it did there.
final class OktalyzerModule {
    /// Which voices an instrument may be played on.
    enum Use {
        /// Only a voice that is split: its sample is of seven bits, so that two can be added.
        case split
        /// Only a voice that is whole.
        case whole
        case either
    }

    struct Instrument {
        var name = ""
        /// Where its sample is in the file; nil if it has none.
        var place: Int?
        /// How long the sample is said to be, in bytes.
        var length: UInt32 = 0
        /// The part that repeats, in words: where it begins and how long it is. None, if it is no
        /// length. (Only a whole voice repeats anything.)
        var repeatStart: UInt16 = 0
        var repeatWords: UInt16 = 0
        var volume: UInt8 = 0
        var use = Use.either
    }

    struct Pattern {
        var lines = 0
        /// Where its lines are in the file.
        var place = 0
    }

    static let instrumentCount = 36
    /// The most that is mixed for a voice in one tick, in bytes, and how many such stretches each
    /// voice has room for. (Oktalyzer made do with two, one playing while the other was filled, and
    /// began filling the one before the chip had quite done with it. A third leaves the chip, which
    /// here keeps its own time, a tick's grace to get from one to the next.)
    static let mixBufferSize = 560, mixBuffers = 3
    /// A voice with nothing to play is pointed here, after the file: a stretch of silence, long
    /// enough for what the voices are set to play before the tune begins.
    static let silenceLength = 96

    private(set) var instruments = [Instrument](repeating: Instrument(), count: OktalyzerModule.instrumentCount)
    /// Which of the four voices are split in two.
    let split: [Bool]
    let trackCount: Int
    let speed: Int
    /// Which pattern is played at each place in the order of playing.
    let positions: [UInt8]
    private(set) var patterns: [Pattern] = []
    /// The file, and silence after it, and then the stretches that tracks are mixed into: what the
    /// sound chip plays from.
    let memory: UnsafeMutablePointer<Int8>
    let memorySize: Int
    let silence: Int
    let mixSpace: Int

    /// For a table with one entry for every line of every place in the order: where each place's
    /// lines begin.
    private(set) var firstRowOfPosition: [Int] = []
    private(set) var rowsInAll = 0
    /// What the file asks for that is not played as it asks: see `TuneInfo.shortfalls`. An
    /// instrument whose sample the file ends before is silent.
    private(set) var shortfalls: [String] = []

    deinit {
        memory.deallocate()
    }

    /// True if the bytes begin as an Oktalyzer module does.
    static func isModule(_ data: [UInt8]) -> Bool {
        data.count > 8 && data.starts(with: [0x4F, 0x4B, 0x54, 0x41, 0x53, 0x4F, 0x4E, 0x47])
    }

    /// The four letters of a piece's name as one number.
    private static func name(_ letters: String) -> Int {
        var value = 0
        for letter in letters.utf8 { value = value << 8 | Int(letter) }
        return value
    }

    init(_ data: [UInt8]) throws {
        guard Self.isModule(data) else { throw TuneError.malformed("not an Oktalyzer module") }
        let reader = ByteReader(data)

        // The pieces are looked for as the routine looks for them: each from where the last one
        // found ended, passing over any of another name. (There is nothing between one and the
        // next, even after one of an odd length.)
        var next = 8
        func piece(_ letters: String) -> (place: Int, length: Int)? {
            let wanted = Self.name(letters)
            while next + 8 <= data.count {
                let found = reader.u32be(next)
                // (A length too large to be one is as good as the rest of the file. A whole number in
                // a browser has only 32 bits, and such a length would not fit in it.)
                let length = reader.u16be(next + 4) >= 0x4000 ? data.count : reader.u32be(next + 4)
                let place = next + 8
                next = min(data.count, place + length)
                if found == wanted { return (place, min(length, data.count - place)) }
            }
            return nil
        }

        guard let modes = piece("CMOD"), modes.length >= 8 else { throw TuneError.malformed("an Oktalyzer module that does not say which voices are split") }
        var split: [Bool] = []
        for voice in 0 ..< 4 {
            let mode = reader.u16be(modes.place + voice * 2)
            guard mode <= 1 else { throw TuneError.malformed("an Oktalyzer module that does not say which voices are split") }
            split.append(mode == 1)
        }
        self.split = split
        trackCount = 4 + split.filter { $0 }.count

        guard let headers = piece("SAMP") else { throw TuneError.malformed("an Oktalyzer module with no instruments") }
        for i in 0 ..< min(Self.instrumentCount, headers.length / 32) {
            let at = headers.place + i * 32
            var instrument = Instrument()
            instrument.name = reader.ascii(at: at, length: 20)
            instrument.length = UInt32(reader.u16be(at + 20)) << 16 | UInt32(reader.u16be(at + 22))
            instrument.repeatStart = UInt16(reader.u16be(at + 24))
            instrument.repeatWords = UInt16(reader.u16be(at + 26))
            instrument.volume = reader[at + 29]
            switch reader.u16be(at + 30) {
            case 0: instrument.use = .split
            case 1: instrument.use = .whole
            default: instrument.use = .either
            }
            instruments[i] = instrument
        }

        guard let tempo = piece("SPEE"), tempo.length >= 2 else { throw TuneError.malformed("an Oktalyzer module with no speed") }
        speed = reader.u16be(tempo.place)
        guard let count = piece("SLEN"), count.length >= 2 else { throw TuneError.malformed("an Oktalyzer module with no patterns") }
        let patternCount = reader.u16be(count.place)
        guard let long = piece("PLEN"), long.length >= 2 else { throw TuneError.malformed("an Oktalyzer module with nothing to play") }
        let length = reader.u16be(long.place)
        guard let order = piece("PATT"), length > 0, length <= 128 else { throw TuneError.malformed("an Oktalyzer module with nothing to play") }
        var positions: [UInt8] = []
        for i in 0 ..< length { positions.append(i < order.length ? reader[order.place + i] : 0) }
        self.positions = positions

        guard patternCount > 0, patternCount <= 256 else { throw TuneError.malformed("an Oktalyzer module with no patterns") }
        for _ in 0 ..< patternCount {
            // (A file that ends before a pattern ends before the samples, which follow the patterns.)
            guard let body = piece("PBOD") else { throw Shortfall.nothingToHear }
            guard body.length >= 2 else { throw TuneError.malformed("an Oktalyzer module with a pattern missing") }
            patterns.append(Pattern(lines: reader.u16be(body.place), place: body.place + 2))
        }
        // The samples follow, one for each instrument that says it has a length, in their order.
        var cutShort = Shortfall.CutShort()
        var sounds = false
        for i in 0 ..< Self.instrumentCount where instruments[i].length != 0 {
            let said = Int(min(instruments[i].length, 1 << 28))
            guard let body = piece("SBOD") else {
                // (The rest have none either, and are counted as they are come to.)
                cutShort.add(length: said, there: 0)
                continue
            }
            instruments[i].place = body.place
            cutShort.add(length: said, there: body.length)
            if !sounds { sounds = Shortfall.sounds(data[body.place ..< body.place + min(body.length, said)]) }
        }
        guard sounds else { throw Shortfall.nothingToHear }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        silence = data.count
        mixSpace = data.count + Self.silenceLength
        memorySize = mixSpace + 4 * Self.mixBuffers * Self.mixBufferSize
        memory = .allocate(capacity: memorySize)
        memory.initialize(repeating: 0, count: memorySize)
        for i in 0 ..< data.count { memory[i] = Int8(bitPattern: data[i]) }

        var rows = 0
        for position in positions {
            firstRowOfPosition.append(rows)
            rows += max(1, Int(position) < patterns.count ? patterns[Int(position)].lines : 1)
        }
        rowsInAll = rows
    }

    /// A byte of the file as it lay in the Amiga's memory; nought beyond its end.
    @inline(__always) func byte(_ at: Int) -> UInt8 {
        at >= 0 && at < silence ? UInt8(bitPattern: memory[at]) : 0
    }

    /// How many lines the pattern at a place in the order of playing has.
    func lines(at position: Int) -> Int {
        let pattern = Int(positions[position])
        return pattern < patterns.count ? patterns[pattern].lines : 0
    }

    /// What a track has on a line of the pattern at a place in the order: a note (1 for the lowest
    /// C), an instrument (counted from nought), a command and its number.
    @inline(__always) func cell(position: Int, line: Int, track: Int) -> (note: UInt8, instrument: UInt8, command: UInt8, data: UInt8) {
        let pattern = Int(positions[position])
        guard pattern < patterns.count else { return (0, 0, 0, 0) }
        let at = patterns[pattern].place + (line * trackCount + track) * 4
        return (byte(at), byte(at + 1), byte(at + 2), byte(at + 3))
    }

    /// Where a voice's stretches of mixed sound are in the memory the chip plays from.
    func mixPlace(_ voice: Int, _ buffer: Int) -> Int {
        mixSpace + (voice * Self.mixBuffers + buffer) * Self.mixBufferSize
    }
}
