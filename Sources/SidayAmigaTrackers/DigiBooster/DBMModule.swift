// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from the loader of libdigibooster3 1.2, the replayer of DigiBooster 3 that its makers
// published (copyright (c) 2014 Grzegorz Kraszewski, under the two-clause BSD licence: see
// THIRD-PARTY.md), with what it refuses made the best of, as OpenMPT and libxmp make it.

import SidayFoundation

/// A DBM file: a module of DigiBooster Pro, which Tomasz and Waldemar Piasta wrote for the Amiga in
/// the late 1990s, or of DigiBooster 3, which came after it.
///
/// It is made of chunks, as an Amiga's IFF files are: the name, how many of each thing there are,
/// the songs (a file may have more than one, each a list of patterns of its own), the instruments,
/// the patterns, the samples, the envelopes of volume and of panning, and how the echo is set. Up
/// to 254 tracks; patterns as long as they like, packed; samples of eight bits or sixteen, each of
/// which may go round, or back and forth. A note has an instrument, and beside it two commands.
final class DBMModule {
    /// What a track has on a row: the octave (none for nought) and the note in it (twelve and more
    /// is a key let go), the instrument, and the two commands.
    struct Cell {
        var octave: UInt8 = 0, note: UInt8 = 0, instrument: UInt8 = 0
        var command1: UInt8 = 0, parameter1: UInt8 = 0, command2: UInt8 = 0, parameter2: UInt8 = 0
    }

    struct Pattern {
        var rows: Int
        /// Where its cells are among the module's, and how many of its rows have them: the rest are
        /// empty.
        var at: Int, stored: Int
    }

    struct Instrument {
        var name = ""
        var sample = 0
        var volume = 0
        /// From -128, all on the left, to 128, all on the right.
        var panning: Int32 = 0
        /// How many samples a second its sample is played at for the C of the fourth octave.
        var c3Frequency: UInt32 = 8363
        var loopStart: Int32 = 0, loopLength: Int32 = 0
        /// 0 for none, 1 for round and round, 2 for back and forth.
        var loopType = 0
        /// Its envelopes, by their numbers; `noEnvelope` for none.
        var volumeEnvelope = DBMModule.noEnvelope, panningEnvelope = DBMModule.noEnvelope
    }

    struct Envelope {
        var instrument = DBMModule.noEnvelope
        var sections: UInt16 = 0
        /// Points, by their numbers; `noEnvelope` where there is none.
        var loopFirst = DBMModule.noEnvelope, loopLast = DBMModule.noEnvelope
        var sustainA = DBMModule.noEnvelope, sustainB = DBMModule.noEnvelope
        /// Each point's place, in ticks, and its value: 0 to 64 for a volume, -128 to 128 for a panning.
        var positions = [UInt16](repeating: 0, count: 32), values = [Int16](repeating: 0, count: 32)
    }

    struct Song {
        var name: String
        var orders: [Int]
    }

    static let noEnvelope: UInt16 = 0xFFFF
    /// No file has more cells than this; one that says it has is not one to play.
    private static let mostCells = 1 << 22

    let title: String
    /// 2 for DigiBooster Pro, 3 for DigiBooster 3.
    let creator: Int
    let tracks: Int
    let songs: [Song]
    let instruments: [Instrument]
    let patterns: [Pattern]
    private let cells: [Cell]
    /// The samples, one after another, and where each begins and how long it is.
    let sampleData: Memory<Int16>
    let sampleStarts: [Int], sampleLengths: [Int32]
    let volumeEnvelopes: [Envelope], panningEnvelopes: [Envelope]
    /// Which tracks the file has the echo on for, and the echo's delay, feedback, mix and cross.
    let echoOn: [Bool]
    let echoDelay: Int32, echoFeedback: Int32, echoMix: Int32, echoCross: Int32
    let shortfalls: [String]

    init(_ data: [UInt8]) throws {
        let file = ByteReader(data)
        if data.starts(with: [0x58, 0x50, 0x4B, 0x46]) { throw TuneError.unsupported("a file packed with XPK") }
        guard data.count >= 16, data[0] == 0x44, data[1] == 0x42, data[2] == 0x4D, data[3] == 0x30 else {
            throw TuneError.malformed("not a DBM file")
        }
        guard data[4] <= 3 else { throw TuneError.unsupported("a DBM file of a later DigiBooster") }
        let creator = data[4] == 3 ? 3 : 2
        self.creator = creator

        // The chunks, the first of each name. (One that runs on past the end of the file is the end
        // of what is read: a file with something else put after it is not lost for that.)
        var chunks: [UInt32: (at: Int, length: Int)] = [:]
        var at = 8
        var cutChunk = false
        while at + 8 <= data.count {
            let name = UInt32(file.u16be(at)) << 16 | UInt32(file.u16be(at + 2))
            // (A length of 32 bits is less than nothing in a browser, where a whole number has 32.)
            let length = file[at + 4] & 0x80 != 0 ? Int.max / 2 : file.u32be(at + 4)
            let there = min(length, data.count - at - 8)
            if chunks[name] == nil { chunks[name] = (at + 8, there) }
            if length > there {
                cutChunk = Self.knownChunks.contains(name)
                break
            }
            at += 8 + length
        }
        func chunk(_ name: String) -> (at: Int, length: Int)? {
            let bytes = Array(name.utf8)
            return chunks[UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])]
        }

        guard let info = chunk("INFO"), info.length >= 10 else { throw TuneError.malformed("a DBM file with nothing said of what it has") }
        let instrumentCount = file.u16be(info.at), sampleCount = file.u16be(info.at + 2)
        let songCount = file.u16be(info.at + 4), patternCount = file.u16be(info.at + 6)
        let tracks = file.u16be(info.at + 8)
        self.tracks = tracks
        guard tracks >= 1, tracks <= 254, instrumentCount <= 255, sampleCount <= 255, songCount >= 1, songCount <= 255, patternCount >= 1 else {
            throw TuneError.malformed("a DBM file that says it has more than DigiBooster can")
        }

        // The name, and failing that the first song's.
        var title = ""
        if let name = chunk("NAME") { title = file.encoded(at: name.at, length: min(44, name.length), as: .latin1) }

        // The songs: each its name and its list of patterns. (One with nothing in its list is no song.)
        var songs: [Song] = []
        if let song = chunk("SONG") {
            var p = song.at
            let end = song.at + song.length
            for _ in 0 ..< songCount {
                guard p + 46 <= end else { break }
                let name = file.encoded(at: p, length: 44, as: .latin1)
                let count = file.u16be(p + 44)
                p += 46
                let orders = (0 ..< min(count, max(0, (end - p) / 2))).map { file.u16be(p + $0 * 2) }
                p += count * 2
                if !orders.isEmpty { songs.append(Song(name: name, orders: orders)) }
            }
        }
        guard !songs.isEmpty else { throw TuneError.malformed("a DBM file with no song") }
        if title.isEmpty { title = songs[0].name }
        self.title = title
        self.songs = songs

        // The instruments, each fifty bytes.
        var instruments = [Instrument](repeating: Instrument(), count: instrumentCount)
        if let inst = chunk("INST") {
            for i in 0 ..< min(instrumentCount, inst.length / 50) {
                let b = inst.at + i * 50
                var one = Instrument()
                one.name = file.encoded(at: b, length: 30, as: .latin1)
                // (The file counts its samples from 1. One that is not there is the first, as the
                // replayer has it, for files that say so.)
                let sample = file.u16be(b + 30) - 1
                one.sample = sample >= 0 && sample < sampleCount ? sample : 0
                one.volume = file.u16be(b + 32)
                // (How fast is checked: a file that is out of what DigiBooster allows is brought into it.)
                one.c3Frequency = UInt32(max(2000, min(192_000, file.u32be(b + 34))))
                one.loopStart = Int32(truncatingIfNeeded: file.u32be(b + 38))
                one.loopLength = Int32(truncatingIfNeeded: file.u32be(b + 42))
                one.panning = Int32(file.s16be(b + 46))
                one.loopType = one.loopLength == 0 ? 0 : file.u16be(b + 48) & 3
                if one.loopType == 0 {
                    one.loopStart = 0
                    one.loopLength = 0
                }
                instruments[i] = one
            }
        }

        // The patterns, each packed: a track's number and what follows for it, and a nought for the
        // end of a row.
        var patterns: [Pattern] = []
        var cells: [Cell] = []
        var cellCount = 0
        if let patt = chunk("PATT") {
            var p = patt.at
            let end = patt.at + patt.length
            for _ in 0 ..< patternCount {
                guard p + 6 <= end else { break }
                let rows = file.u16be(p)
                let packed = file.u32be(p + 2)
                p += 6
                let stop = min(end, p + max(0, min(packed, end - p)))
                // (A pattern of no rows is played as one of 64 empty ones.)
                var pattern = Pattern(rows: rows == 0 ? 64 : rows, at: cells.count, stored: 0)
                var row = 0, q = p
                var stored = 0
                func ensure(_ upTo: Int) throws {
                    while stored < upTo {
                        cellCount += tracks
                        guard cellCount <= Self.mostCells else { throw TuneError.malformed("a DBM file of more patterns than any") }
                        cells.append(contentsOf: repeatElement(Cell(), count: tracks))
                        stored += 1
                    }
                }
                // (A byte past the pattern's end is not there, and ends it.)
                func next() -> UInt8? {
                    guard q < stop else { return nil }
                    q += 1
                    return data[q - 1]
                }
                decoding: while rows > 0, row < rows, let track = next() {
                    if track == 0 {
                        row += 1
                        continue
                    }
                    guard let fields = next() else { break }
                    // (What is for a track the file has not got is passed over; what a track is given
                    // twice in a row is put together.)
                    let wanted = Int(track) <= tracks
                    var cell = Cell()
                    if wanted {
                        try ensure(row + 1)
                        cell = cells[pattern.at + row * tracks + Int(track) - 1]
                    }
                    var complete = true
                    for bit in 0 ..< 6 where fields & (1 << bit) != 0 {
                        guard let value = next() else {
                            complete = false
                            break
                        }
                        switch bit {
                        case 0:
                            cell.octave = value >> 4
                            cell.note = value & 15
                        case 1: cell.instrument = value
                        case 2: cell.command1 = value
                        case 3: cell.parameter1 = value
                        case 4: cell.command2 = value
                        default: cell.parameter2 = value
                        }
                    }
                    if wanted { cells[pattern.at + row * tracks + Int(track) - 1] = cell }
                    if !complete { break decoding }
                }
                pattern.stored = stored
                patterns.append(pattern)
                if packed < 0 || packed > end - p { break }
                p += packed
            }
        }
        let missingPatterns = patternCount - patterns.count
        // (A pattern the file has not got, or that the list names and there is none of, is empty:
        // the last, which is one more than the file says it has.)
        while patterns.count <= patternCount { patterns.append(Pattern(rows: 64, at: 0, stored: 0)) }
        self.patterns = patterns
        self.cells = cells

        // The samples: each says how many bytes a sample of it has, and how long it is.
        var starts = [Int](repeating: 0, count: sampleCount), lengths = [Int32](repeating: 0, count: sampleCount)
        var sounds: [(from: Int, bytes: Int, frames: Int)] = []
        var total = 0
        var cut = Shortfall.CutShort()
        if let smpl = chunk("SMPL") {
            var p = smpl.at
            for s in 0 ..< sampleCount {
                let flags = Int(file[p + 3]) & 7
                // (A length of more than 29 bits is a broken file's, and is taken to be no longer.)
                let frames = file[p + 4] & 0xE0 != 0 ? 0x1FFF_FFFF : file.u32be(p + 4)
                p += 8
                // (A sample of eight bits if it says so, and otherwise of sixteen, or of thirty-two.)
                let bytes = flags & 1 != 0 ? 1 : flags & 2 != 0 ? 2 : flags & 4 != 0 ? 4 : 1
                let room = max(0, data.count - p) / bytes
                cut.add(length: frames * bytes, there: data.count - p)
                let kept = min(frames, room)
                starts[s] = total
                lengths[s] = Int32(kept)
                sounds.append((p, bytes, kept))
                total += kept
                if frames > room { break }
                p += frames * bytes
            }
        }
        let memory = Memory<Int16>(capacity: max(1, total))
        for (s, sound) in sounds.enumerated() {
            let to = memory.pointer + starts[s]
            for i in 0 ..< sound.frames {
                let q = sound.from + i * sound.bytes
                switch sound.bytes {
                case 1: to[i] = Int16(Int8(bitPattern: data[q])) << 8
                case 2: to[i] = Int16(truncatingIfNeeded: Int(data[q]) << 8 | Int(data[q + 1]))
                default: to[i] = Int16(truncatingIfNeeded: Int(data[q]) << 8 | Int(data[q + 1]))
                }
            }
        }
        // A file with no sample that has a sound, one that has lost its samples among them, has
        // nothing to be heard by.
        guard Shortfall.sounds(UnsafeBufferPointer(start: memory.pointer, count: total)) else { throw Shortfall.nothingToHear }
        sampleData = memory
        sampleStarts = starts
        sampleLengths = lengths

        // A loop is to be within its sample. (The replayer turns away a file of which it is not: a
        // loop that runs on past its sample's end is brought back to it, as OpenMPT has it.)
        for i in instruments.indices where instruments[i].loopType != 0 {
            let frames = instruments[i].sample < lengths.count ? Int64(lengths[instruments[i].sample]) : 0
            let start = Int64(instruments[i].loopStart), length = Int64(instruments[i].loopLength)
            if frames <= 0 || start < 0 || length <= 0 || start >= frames {
                instruments[i].loopType = 0
                instruments[i].loopStart = 0
                instruments[i].loopLength = 0
            } else if start + length > frames {
                instruments[i].loopLength = Int32(frames - start)
            }
        }

        // The envelopes, each 136 bytes, and which instrument each is for.
        func envelopes(_ name: String, panning: Bool) -> [Envelope] {
            guard let chunk = chunk(name), chunk.length >= 2 else { return [] }
            let count = min(255, file.u16be(chunk.at), (chunk.length - 2) / 136)
            return (0 ..< count).map { Self.envelope(file, at: chunk.at + 2 + $0 * 136, panning: panning, creator: creator) }
        }
        let volumeEnvelopes = envelopes("VENV", panning: false), panningEnvelopes = envelopes("PENV", panning: true)
        for (index, envelope) in volumeEnvelopes.enumerated() where envelope.instrument != Self.noEnvelope {
            let instrument = Int(envelope.instrument)
            if instrument <= instrumentCount { instruments[instrument - 1].volumeEnvelope = UInt16(index) }
        }
        for (index, envelope) in panningEnvelopes.enumerated() where envelope.instrument != Self.noEnvelope {
            let instrument = Int(envelope.instrument)
            if instrument <= instrumentCount { instruments[instrument - 1].panningEnvelope = UInt16(index) }
        }
        self.volumeEnvelopes = volumeEnvelopes
        self.panningEnvelopes = panningEnvelopes
        self.instruments = instruments

        // The echo: a byte a track, nought for one it is on for, and then four settings.
        var echoOn = [Bool](repeating: false, count: tracks)
        var settings: [Int32] = [0x40, 0x80, 0x80, 0xFF]
        if let dspe = chunk("DSPE"), dspe.length >= 2 {
            let count = file.u16be(dspe.at)
            for track in 0 ..< min(count, tracks) where dspe.at + 2 + track < data.count {
                echoOn[track] = file[dspe.at + 2 + track] == 0
            }
            let values = dspe.at + 2 + count
            if values + 8 <= dspe.at + dspe.length {
                settings = [Int32(file[values + 1]), Int32(file[values + 3]), Int32(file[values + 5]), Int32(file[values + 7])]
            }
        }
        self.echoOn = echoOn
        echoDelay = settings[0]
        echoFeedback = settings[1]
        echoMix = settings[2]
        echoCross = settings[3]

        var shortfalls: [String] = []
        // Three of DigiBooster Pro's commands that DigiBooster 3's replayer passes over, and so
        // does this one: what each did is not written down closely enough to do it.
        var leftOut = Shortfall.Kinds()
        for cell in cells {
            for command in [cell.command1, cell.command2] {
                switch command {
                case 0x15: leftOut.note(0)
                case 0x18: leftOut.note(1)
                case 0x1C: leftOut.note(2)
                default: break
                }
            }
        }
        if let sentence = Shortfall.commandsLeftOut(leftOut.named(Self.commandsLeftOut), why: "which DigiBooster 3's replayer does not play") {
            shortfalls.append(sentence)
        }
        if let sentence = cut.sentence {
            shortfalls.append(sentence)
        } else if cutChunk || missingPatterns > 0 {
            shortfalls.append(Shortfall.cutShort("Some of what it has is not there."))
        }
        self.shortfalls = shortfalls
    }

    /// DigiBooster Pro's Lxx, Oxx and Sxx.
    private static let commandsLeftOut = ["setting how far into an envelope a note is", "sliding where a sample starts", "setting the tempo in beats a minute"]

    /// The chunks a file of DigiBooster's has: one of these that is cut short is a file cut short.
    private static let knownChunks: Set<UInt32> = Set(["NAME", "INFO", "SONG", "INST", "PATT", "PNAM", "SMPL", "VENV", "PENV", "DSPE"].map {
        let b = Array($0.utf8)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    })

    /// An envelope as the replayer reads it. (What it would turn the file away for is made the best
    /// of: a point out of range is brought into it, and a loop or a sustain that is not there is none.)
    private static func envelope(_ file: ByteReader, at b: Int, panning: Bool, creator: Int) -> Envelope {
        var envelope = Envelope()
        let flags = file[b + 2]
        let sections = min(31, Int(file[b + 3]))
        envelope.sections = UInt16(sections)
        let instrument = file.u16be(b)
        envelope.instrument = instrument <= 0 || instrument > 255 ? noEnvelope : UInt16(instrument)
        let enabled = flags & 1 != 0
        if enabled {
            if flags & 8 != 0, Int(file[b + 7]) <= sections { envelope.sustainB = UInt16(file[b + 7]) }
            if flags & 2 != 0, Int(file[b + 4]) <= sections { envelope.sustainA = UInt16(file[b + 4]) }
            if flags & 4 != 0, Int(file[b + 6]) <= sections, file[b + 5] < file[b + 6] {
                envelope.loopFirst = UInt16(file[b + 5])
                envelope.loopLast = UInt16(file[b + 6])
            }
            if envelope.sustainA != noEnvelope, envelope.sustainB != noEnvelope, envelope.sustainA > envelope.sustainB {
                swap(&envelope.sustainA, &envelope.sustainB)
            }
        }
        for point in 0 ... sections {
            var position = file.s16be(b + 8 + point * 4), value = file.s16be(b + 10 + point * 4)
            if !enabled {
                position = 0
                value = 0
            } else if panning {
                // (DigiBooster Pro's panning goes from 0 to 64, DigiBooster 3's from -128 to 128.)
                if creator == 2 { value = Int(Int16(truncatingIfNeeded: (value << 2) - 128)) }
                value = max(-128, min(128, value))
            } else {
                value = max(0, min(64, value))
            }
            envelope.positions[point] = UInt16(max(0, min(2048, position)))
            envelope.values[point] = Int16(value)
        }
        return envelope
    }

    /// The pattern a number in a list stands for: the empty one after the file's own, for a number
    /// that is none of them.
    func pattern(_ number: Int) -> Int {
        min(number, patterns.count - 1)
    }

    /// What a track has on a row of a pattern.
    @inline(__always)
    func cell(pattern: Int, row: Int, track: Int) -> Cell {
        let one = patterns[pattern]
        guard row < one.stored else { return Cell() }
        return cells[one.at + row * tracks + track]
    }
}
