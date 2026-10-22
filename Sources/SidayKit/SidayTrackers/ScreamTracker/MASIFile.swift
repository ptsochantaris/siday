// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the PSM loader of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// A PSM file of MASI, the music and sound system that Epic MegaGames' games for DOS played their
/// music with, from Epic Pinball on. The musicians wrote their tunes in the trackers of the day, and
/// Epic's converter made each into the one kind of file the games' player played. It is of two
/// kinds, the older and the newer.
///
/// The older, which begins "PSM" and FE, has a header that says where the rest is: the list of
/// patterns, a place between the speakers for each channel from 0 to 15, the samples' headers and
/// the patterns, each packed much as an S3M file packs its own. The newer, which begins "PSM ", is
/// made of chunks: a song for each of a game's tunes (a name, a count of channels, and a little
/// program that says which patterns it plays, at what speed and tempo, where its channels are and
/// where it goes back to at its end), then each pattern, each with its own count of rows, and each
/// sample, a chunk apiece. Sinaria's are a little otherwise: its patterns are named "PATT", its
/// samples' headers are laid out differently, and its notes and slides are counted as the older
/// kind's are. Both have ProTracker's commands under numbers of their own, and the samples are
/// mostly of eight bits, kept as the difference of each byte from the one before.
///
/// MASI's player is not to be had. OpenMPT plays these files by the rules it plays an S3M file by,
/// as it does a DSM file (see `DSMFile`), and so they are played here by Scream Tracker 3's own
/// replayer, on a Gravis Ultrasound, with what OpenMPT does otherwise for such files (see
/// `ST3Module.playsAsDSIK`): the file is read into an S3M file, each command under its S3M letter,
/// and that is played. The songs of a newer file follow one another in that file's list of
/// patterns, each ending with the mark for an end, and the replayer is told where each begins and
/// goes back to, with its speed, its tempo and its channels' places (see `ST3Module.songs`).
enum MASIFile {
    /// True for a file that begins as one of these does: "PSM " and, eight bytes on, "FILE"; or the
    /// older kind's "PSM" and FE, with 1A ending its title. (Pro Sound Maker's files for the ZX
    /// Spectrum are also named PSM, and begin with nothing of the kind.)
    static func isOne(_ data: [UInt8]) -> Bool {
        let f = ByteReader(data)
        guard f[0] == 0x50, f[1] == 0x53, f[2] == 0x4D else { return false }
        return f[3] == 0x20 && f.ascii(at: 8, length: 4) == "FILE" || f[3] == 0xFE && f[63] == 0x1A
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> S3MRenderer {
        let read = try read(data)
        return try S3MRenderer(read.s3m, options: options, card: .gus, format: "MASI", tracker: "Epic MegaGames' MASI", title: read.title,
                               shortfalls: read.shortfalls, loudness: loudness, asDSIK: true, songs: read.songs)
    }

    /// How loud these files are made, beside an S3M file on the same card: set by measure, so that
    /// the middle one of them is about as loud as the middle one of other modules.
    private static let loudness: Float = 0.92

    /// The file as an S3M file, its title, its songs and what of it is not played.
    static func read(_ data: [UInt8]) throws -> (s3m: [UInt8], title: String, songs: [ST3Module.Song], shortfalls: [String]) {
        guard isOne(data) else { throw TuneError.malformed("not a PSM file of Epic MegaGames'") }
        return try (data[3] == 0x20 ? newer(data) : older(data)).s3m()
    }

    // MARK: What the file holds

    /// One channel's part of a row, as an S3M file has it: its note (255 for none, 254 to end the
    /// one sounding), its sample (0 for none), its volume (255 for none), and its command's letter
    /// (counted from A as 1, 0 for none) and value.
    struct Cell {
        var note: UInt8 = 255, volume: UInt8 = 255, command: UInt8 = 0, value: UInt8 = 0
        var sample = 0
    }

    struct Sample {
        var name = "", fileName = ""
        /// Its sound: bytes with a sign, or pairs of them, the low byte first, for sixteen bits.
        var bytes: [UInt8] = []
        var sixteenBit = false
        var loops = false, backAndForth = false
        var loopStart = 0, loopEnd = 0
        var volume: UInt8 = 64
        var rate = 8363
    }

    /// A song: its name, its list of patterns (by their numbers, `skip` for a mark that is passed
    /// over, `end` for its end), where in the list it goes back to, its speed and tempo, and each
    /// channel's place from 0 to 256, whether it is in surround, and its volume from 0 to 64.
    struct Song {
        static let skip = -1, end = -2
        var name = ""
        var orders: [Int] = []
        var restart = 0
        var speed = 6, tempo = 125
        var pans: [Int], surround: [Bool], volumes: [Int]

        init(channels: Int) {
            pans = [Int](repeating: 128, count: channels)
            surround = [Bool](repeating: false, count: channels)
            volumes = [Int](repeating: 64, count: channels)
        }
    }

    /// The file read, before it is written again as an S3M file.
    struct Tune {
        var title = ""
        var channels = 0
        var songs: [Song] = []
        /// The patterns by their numbers in the file, each its rows of cells, one channel's after another's.
        var patterns: [Int: [Cell]] = [:]
        var rows: [Int: Int] = [:]
        var samples: [Int: Sample] = [:]
        var shortfalls: [String] = []
        var cutShort = Shortfall.CutShort()
        /// True if a sample is to be started from further into it than 65,535 of its samples.
        var farOffsets = false
    }

    // MARK: The newer kind

    /// A number like those that name the patterns, "13" of "P13" or of Sinaria's "PATT13": its first
    /// digits, as OpenMPT reads them.
    private static func number(_ read: (Int) -> UInt8, at: Int, length: Int) -> Int {
        var value = 0, k = 0
        while k < length, read(at + k) == 0x20 { k += 1 }
        while k < length, read(at + k) >= 0x30, read(at + k) <= 0x39 {
            value = min(65535, value * 10 + Int(read(at + k) - 0x30))
            k += 1
        }
        return value
    }

    /// The chunks from a place to an end: each one's name, and where its body begins and ends.
    private static func chunks(_ f: ByteReader, from: Int, to end: Int) -> [(name: String, at: Int, end: Int)] {
        var list: [(name: String, at: Int, end: Int)] = []
        var at = from
        while at + 8 <= end {
            let size = f.size32le(at + 4), start = at + 8
            list.append((f.ascii(at: at, length: 4), start, min(end, start + size)))
            at = start + size
        }
        return list
    }

    private static func newer(_ data: [UInt8]) throws -> Tune {
        let f = ByteReader(data)
        let all = chunks(f, from: 12, to: data.count)
        guard let format = all.first(where: { $0.name == "SDFT" }), format.end - format.at >= 8, f.ascii(at: format.at, length: 8) == "MAINSONG" else {
            throw TuneError.malformed("a PSM file with no song in it")
        }
        var tune = Tune()
        let songChunks = all.filter { $0.name == "SONG" }
        for chunk in songChunks {
            // (A song packed some way, which no file is known to be, is not read.)
            guard chunk.end - chunk.at >= 11, f[chunk.at + 9] == 1 else { throw TuneError.unsupported("a PSM file whose songs are packed") }
            tune.channels = max(tune.channels, min(127, Int(f[chunk.at + 10])))
        }
        guard tune.channels > 0 else { throw TuneError.malformed("a PSM file with no channels") }
        if let title = all.first(where: { $0.name == "TITL" }) { tune.title = f.dos(at: title.at, length: title.end - title.at) }

        // The songs. One that plays no pattern adds what it sets to the next.
        var sinaria = false
        var song = Song(channels: tune.channels)
        func place(_ channel: Int, _ type: UInt8, _ pan: Int?) {
            guard channel < tune.channels else { return }
            switch type {
            case 0:
                if let pan { song.pans[channel] = pan ^ 128 }
                song.surround[channel] = false
            case 2:
                song.pans[channel] = 128
                song.surround[channel] = true
            case 4:
                song.pans[channel] = 128
                song.surround[channel] = false
            default: break
            }
        }
        for chunk in songChunks {
            if !song.orders.isEmpty {
                tune.songs.append(song)
                song = Song(channels: tune.channels)
            }
            song.name = f.ascii(at: chunk.at, length: 9)
            for part in chunks(f, from: chunk.at + 11, to: chunk.end) {
                // (What lies past the end of a part is nothing.)
                func byte(_ i: Int) -> UInt8 { i < part.end ? f[i] : 0 }
                switch part.name {
                case "OPLH" where part.end - part.at >= 9:
                    // A list of things to do, one after another, each a number and what it takes.
                    var at = part.at + 2, count = 0, firstOrder: Int?
                    program: while at < part.end {
                        let what = byte(at)
                        at += 1
                        switch what {
                        case 0: break program
                        case 1: // play a pattern, named "P13 ", or "PATT13  " in Sinaria
                            let pattern: Int
                            if byte(at) == 0x50, byte(at + 1) == 0x41, byte(at + 2) == 0x54, byte(at + 3) == 0x54 {
                                sinaria = true
                                pattern = number(byte, at: at + 4, length: 4)
                                at += 8
                            } else {
                                pattern = number(byte, at: at + 1, length: 3)
                                at += 4
                            }
                            song.orders.append(pattern == 0xFF ? Song.end : pattern == 0xFE ? Song.skip : pattern)
                            if firstOrder == nil { firstOrder = count }
                        case 2: at += 4 // play part of a pattern (which the player is not known to do)
                        case 3, 4: // go back to a place in the list when it ends
                            let to = Int(byte(at)) | Int(byte(at + 1)) << 8
                            at += what == 3 ? 3 : 2
                            if let firstOrder, to >= firstOrder { song.restart = to - firstOrder }
                        case 5: // a channel into surround or the middle, or back to its place
                            place(Int(byte(at)), byte(at + 1), nil)
                            at += 2
                        case 6: at += 1 // transposing (which the player is not known to do)
                        case 7:
                            song.speed = byte(at) == 0 ? 6 : Int(byte(at))
                            at += 1
                        case 8:
                            song.tempo = byte(at) == 0 ? 125 : Int(byte(at))
                            at += 1
                        case 0x0C: // which sample each instrument is: in every file, each its own
                            guard (0 ..< 6).map({ byte(at + $0) }) == [0, 0xFF, 0, 0, 1, 0] else {
                                throw TuneError.unsupported("a PSM file whose instruments are other samples")
                            }
                            at += 6
                        case 0x0D:
                            place(Int(byte(at)), byte(at + 2), Int(byte(at + 1)))
                            at += 3
                        case 0x0E:
                            let channel = Int(byte(at))
                            if channel < tune.channels { song.volumes[channel] = Int(byte(at + 1)) / 4 + 1 }
                            at += 2
                        default:
                            // (MASI is said to hang on one it does not know, and OpenMPT will not read the file.)
                            throw TuneError.malformed("a PSM file with a song that cannot be read")
                        }
                        count += 1
                    }
                case "PPAN":
                    // Sinaria's places: the kind of each channel's, then the place.
                    for channel in 0 ..< tune.channels where part.at + channel * 2 + 2 <= part.end {
                        place(channel, f[part.at + channel * 2], Int(f[part.at + channel * 2 + 1]))
                    }
                default: break
                }
            }
        }
        if !song.orders.isEmpty { tune.songs.append(song) }
        guard !tune.songs.isEmpty else { throw TuneError.malformed("a PSM file with no pattern to play") }

        // The samples, each with its header first, its sound the difference of each byte from the
        // one before. A sample's volume is twice what is asked and one more, of 256.
        for chunk in all where chunk.name == "DSMP" && chunk.end - chunk.at >= 96 {
            let h = chunk.at
            let number = f.u16le(h + (sinaria ? 56 : 52)) + 1
            guard number < 4000 else { continue }
            var sample = Sample()
            sample.fileName = f.ascii(at: h + 1, length: 8)
            sample.name = f.dos(at: h + (sinaria ? 17 : 13), length: 33)
            let length = f.size32le(h + (sinaria ? 58 : 54))
            sample.loopStart = f.size32le(h + (sinaria ? 62 : 58))
            let loopEnd = UInt32(truncatingIfNeeded: f.u32le(h + (sinaria ? 66 : 62)))
            // (A loop's end is one before it, but in Sinaria's; and so FFFFFFFF, for the sample's end, is then none.)
            sample.loopEnd = sinaria ? Int(min(loopEnd, 0x3FFF_FFFF)) : loopEnd == 0 ? 0 : Int(min(loopEnd &+ 1, 0x3FFF_FFFF))
            sample.volume = UInt8(min(64, (Int(f[h + (sinaria ? 73 : 68)]) + 1) / 2))
            sample.rate = sinaria ? f.u16le(h + 78) : f.size32le(h + 73)
            sample.loops = f[h] & 0x80 != 0
            sample.bytes = sound(data, from: h + 96, end: chunk.end, length: length, tune: &tune)
            var sum: UInt8 = 0
            for k in sample.bytes.indices {
                sum &+= sample.bytes[k]
                sample.bytes[k] = sum
            }
            tune.samples[number] = sample
        }

        // The patterns, each its rows: a row says how long it is, then gives a cell at a time, its
        // channel and what it has, a bit for each: a note, a sample, a volume and a command.
        for chunk in all where chunk.name == "PBOD" && chunk.end - chunk.at >= 8 && f.size32le(chunk.at) == chunk.end - chunk.at {
            func byte(_ i: Int) -> UInt8 { i < chunk.end ? f[i] : 0 }
            var at = chunk.at + 4
            let pattern: Int
            if f.ascii(at: at, length: 4) == "PATT" {
                sinaria = true
                pattern = number(byte, at: at + 4, length: 4)
                at += 8
            } else {
                pattern = number(byte, at: at + 1, length: 3)
                at += 4
            }
            let rowCount = Int(byte(at)) | Int(byte(at + 1)) << 8
            at += 2
            // (The first pattern of a number is the one that is played.)
            guard rowCount > 0, rowCount <= 4096, tune.patterns[pattern] == nil else { continue }
            var cells = [Cell](repeating: Cell(), count: rowCount * tune.channels)
            for row in 0 ..< rowCount {
                let size = Int(byte(at)) | Int(byte(at + 1)) << 8
                at += 2
                guard size > 2 else { continue }
                let end = min(chunk.end, at + size - 2)
                func cellByte(_ i: Int) -> UInt8 { i < end ? f[i] : 0 }
                while at + 3 <= end {
                    let what = cellByte(at), channel = min(tune.channels - 1, Int(cellByte(at + 1)))
                    at += 2
                    var cell = cells[row * tune.channels + channel]
                    if what & 0x80 != 0 {
                        let note = cellByte(at)
                        at += 1
                        if sinaria {
                            cell.note = s3mNote(note < 85 ? Int(note) + 36 : Int(note))
                        } else {
                            cell.note = note == 0xFF ? 254 : note < 129 ? s3mNote(Int(note & 0x0F) + 12 * Int(note >> 4) + 13) : s3mNote(Int(note))
                        }
                    }
                    if what & 0x40 != 0 {
                        cell.sample = (Int(cellByte(at)) + 1) & 0xFF
                        at += 1
                    }
                    if what & 0x20 != 0 {
                        cell.volume = (min(cellByte(at), 127) + 1) / 2
                        at += 1
                    }
                    if what & 0x10 != 0 {
                        let command = cellByte(at)
                        (cell.command, cell.value) = newerCommand(command, cellByte(at + 1), sinaria: sinaria)
                        at += 2
                        if command == 0x29 {
                            // A place in the sample in three bytes, of which the middle one is played.
                            cell.value = cellByte(at)
                            if cellByte(at + 1) != 0 { tune.farOffsets = true }
                            at += 2
                        } else if command == 0x33 {
                            at += 1
                        }
                    }
                    cells[row * tune.channels + channel] = cell
                }
                at = end
            }
            tune.patterns[pattern] = cells
            tune.rows[pattern] = rowCount
        }
        return tune
    }

    /// A newer file's command, as an S3M file has it: its letter and value.
    private static func newerCommand(_ command: UInt8, _ value: UInt8, sinaria: Bool) -> (UInt8, UInt8) {
        let p = Int(value)
        func byte(_ value: Int) -> UInt8 { UInt8(truncatingIfNeeded: value) }
        // (A slide of the pitch is counted four times as finely as Scream Tracker's, but in Sinaria's.)
        func slide(_ value: Int) -> Int { sinaria ? value : value < 4 ? value | 0xF0 : value >> 2 }
        switch command {
        case 0x01: return (4, byte(sinaria ? p << 4 | 0x0F : (p & 0x1E) << 3 | 0x0F)) // D, finely up
        case 0x02: return (4, byte(0xF0 & (sinaria ? p << 4 : p << 3))) // D, up
        case 0x03: return (4, byte(sinaria ? p | 0xF0 : 0xF0 | p >> 1)) // D, finely down
        case 0x04: return (4, byte(sinaria ? p & 0x0F : p < 2 ? p | 0xF0 : (p >> 1) & 0x0F)) // D, down
        case 0x0B: return (6, byte(0xF0 | slide(p))) // F, finely
        case 0x0C: return (6, byte(slide(p))) // F
        case 0x0D: return (5, byte(0xF0 | slide(p))) // E, finely
        case 0x0E: return (5, byte(slide(p))) // E
        case 0x0F: return (7, byte(sinaria ? p : p >> 2)) // G
        case 0x10: return (12, byte(p & 0xF0)) // L, up
        case 0x11: return (19, byte(0x10 | (p & 1))) // S1x
        case 0x12: return (12, byte((p >> 4) & 0x0F)) // L, down
        case 0x13: return (19, value) // S, as it is
        case 0x15: return (8, value) // H
        case 0x16: return (19, byte(0x30 | (p & 0x0F))) // S3x
        case 0x17: return (11, byte(0xF0 | p)) // K, up
        case 0x18: return (11, value) // K, down
        case 0x1F: return (18, value) // R
        case 0x20: return (19, byte(0x40 | (p & 0x0F))) // S4x
        case 0x29: return (15, 0) // O, its value in the bytes that follow
        case 0x2A: return (17, value) // Q
        case 0x2B: return (19, byte(0xC0 | (p & 0x0F))) // SCx
        case 0x2C: return (19, byte(0xD0 | (p & 0x0F))) // SDx
        case 0x33: return (2, byte(p / 2)) // B, to a place in the song's own list
        case 0x34: return (3, 0) // C, always to the top of the next pattern, as MASI has it
        case 0x35: return (19, byte(0xB0 | (p & 0x0F))) // SBx
        case 0x36: return (19, byte(0xE0 | (p & 0x0F))) // SEx
        case 0x3D: return (1, value) // A
        case 0x3E: return (20, value) // T
        case 0x47: return (10, value) // J
        case 0x48: return (19, byte(0x20 | (p & 0x0F))) // S2x
        case 0x49: return (19, byte(0x80 | (p & 0x0F))) // S8x
        default: return (0, 0)
        }
    }

    // MARK: The older kind

    private static func older(_ data: [UInt8]) throws -> Tune {
        let f = ByteReader(data)
        let playChannels = f.u16le(78), realChannels = f.u16le(80)
        guard f[65] == 0x10 || f[65] == 1, f[66] == 0, f[64] & 3 == 0, playChannels <= 32, realChannels <= 32, max(playChannels, realChannels) > 0 else {
            throw TuneError.unsupported("a PSM file of a kind that is not known")
        }
        var tune = Tune()
        tune.channels = max(playChannels, realChannels)
        tune.title = f.dos(at: 4, length: 59)
        var song = Song(channels: tune.channels)
        song.speed = f[67] == 0 ? 6 : Int(f[67])
        song.tempo = f[68] == 0 ? 125 : Int(f[68])
        let orderCount = f.u16le(72), patternCount = f.u16le(74), sampleCount = f.u16le(76)
        let orderAt = f.u32le(82), panAt = f.u32le(86), patternAt = f.u32le(90), sampleAt = f.u32le(94)
        if orderAt > 4, f.ascii(at: orderAt - 4, length: 4) == "PORD", orderAt + orderCount <= data.count {
            song.orders = (0 ..< orderCount).map { Int(f[orderAt + $0]) }
        }
        if panAt > 4, f.ascii(at: panAt - 4, length: 4) == "PPAN" {
            // (Fifteen is to the left and nought to the right.)
            for channel in 0 ..< tune.channels { song.pans[channel] = ((15 - Int(f[panAt + channel] & 0x0F)) * 256 + 8) / 15 }
        }
        tune.songs = [song]

        // The samples: their headers together, each saying where its sound is in the file.
        if sampleAt > 4, f.ascii(at: sampleAt - 4, length: 4) == "PSAH" {
            for index in 0 ..< min(sampleCount, max(0, data.count - sampleAt) / 64) {
                let h = sampleAt + index * 64
                let number = f.u16le(h + 45)
                // (The first of a number with any sound is the one that is played.)
                guard number > 0, number < 4000, tune.samples[number]?.bytes.isEmpty ?? true else { continue }
                var sample = Sample()
                sample.fileName = f.ascii(at: h, length: 13)
                sample.name = f.dos(at: h + 13, length: 24)
                let flags = f[h + 47]
                sample.sixteenBit = flags & 4 != 0
                sample.loops = flags & 0x80 != 0
                sample.backAndForth = flags & 0x20 != 0
                let bytes = f.size32le(h + 48)
                sample.loopStart = f.size32le(h + 52)
                sample.loopEnd = f.size32le(h + 56)
                sample.volume = min(f[h + 61], 64)
                // Its rate, moved by its fine tuning and transposing (7 in the high nibble is none),
                // as OpenMPT has it.
                let tuning = Int(f[h + 60] ^ 0x08) - 0x78
                sample.rate = Int((Double(f.u16le(h + 62)) * pow(2, Double(tuning) / 192) + 0.5).rounded(.down))
                var sound = Self.sound(data, from: f.u32le(h + 37), end: data.count, length: sample.sixteenBit ? bytes & ~1 : bytes, tune: &tune)
                // Without a sign (8), with one, or as the differences from one to the next (0x10, or
                // when no other flag but the loop's is set).
                if flags & 8 != 0 {
                    for k in stride(from: sample.sixteenBit ? 1 : 0, to: sound.count, by: sample.sixteenBit ? 2 : 1) { sound[k] ^= 0x80 }
                } else if flags & 0x10 != 0 || flags & 0x7F == 0 {
                    if sample.sixteenBit {
                        var sum: UInt16 = 0
                        for k in stride(from: 0, to: sound.count - 1, by: 2) {
                            sum &+= UInt16(sound[k]) | UInt16(sound[k + 1]) << 8
                            sound[k] = UInt8(sum & 0xFF)
                            sound[k + 1] = UInt8(sum >> 8)
                        }
                    } else {
                        var sum: UInt8 = 0
                        for k in sound.indices {
                            sum &+= sound[k]
                            sound[k] = sum
                        }
                    }
                }
                sample.bytes = sound
                tune.samples[number] = sample
            }
        }

        // The patterns, one after another, each padded to sixteen bytes: a byte for each cell, with
        // its channel and a bit for each of what it has, and a nought at the end of each row.
        if patternAt > 4, f.ascii(at: patternAt - 4, length: 4) == "PPAT" {
            var at = patternAt
            for pattern in 0 ..< patternCount {
                guard at + 4 <= data.count else { break }
                let size = f.u16le(at), rowCount = Int(f[at + 2])
                guard size >= 4 else {
                    at += 4
                    continue
                }
                let next = at + ((size + 15) & ~15), end = min(data.count, next)
                defer { at = next }
                guard rowCount > 0 else { continue }
                var i = at + 4, row = 0
                func byte(_ k: Int) -> UInt8 { k < end ? f[k] : 0 }
                var cells = [Cell](repeating: Cell(), count: rowCount * tune.channels)
                while i < end, row < rowCount {
                    let what = byte(i)
                    i += 1
                    if what == 0 {
                        row += 1
                        continue
                    }
                    let channel = min(tune.channels - 1, Int(what & 0x1F))
                    var cell = cells[row * tune.channels + channel]
                    if what & 0x80 != 0 {
                        cell.note = s3mNote(Int(byte(i) &+ 36))
                        cell.sample = Int(byte(i + 1))
                        i += 2
                    }
                    if what & 0x40 != 0 {
                        cell.volume = min(byte(i), 64)
                        i += 1
                    }
                    if what & 0x20 != 0 {
                        let command = byte(i)
                        (cell.command, cell.value) = olderCommand(command, byte(i + 1))
                        i += 2
                        if command == 0x28 {
                            cell.value = byte(i)
                            if byte(i + 1) != 0 { tune.farOffsets = true }
                            i += 2
                        }
                    }
                    cells[row * tune.channels + channel] = cell
                }
                tune.patterns[pattern] = cells
                tune.rows[pattern] = rowCount
            }
        }
        if tune.samples.values.contains(where: { $0.loops && $0.backAndForth }) {
            tune.shortfalls.append("Its loops that go back and forth are played forwards, as Scream Tracker 3 plays every loop.")
        }
        return tune
    }

    /// An older file's command, as an S3M file has it.
    private static func olderCommand(_ command: UInt8, _ value: UInt8) -> (UInt8, UInt8) {
        let p = Int(value)
        func byte(_ value: Int) -> UInt8 { UInt8(truncatingIfNeeded: value) }
        switch command {
        case 0x01: return (4, byte(p << 4 | 0x0F)) // D, finely up
        case 0x02: return (4, byte((p << 4) & 0xF0)) // D, up
        case 0x03: return (4, byte(0xF0 | p)) // D, finely down
        case 0x04: return (4, byte(p & 0x0F)) // D, down
        case 0x0A: return (6, byte(0xF0 | p)) // F, finely
        case 0x0B: return (6, value) // F
        case 0x0C: return (5, byte(0xF0 | p)) // E, finely
        case 0x0D: return (5, value) // E
        case 0x0E: return (7, value) // G
        case 0x0F: return (19, byte(0x10 | (p & 0x0F))) // S1x
        case 0x10: return (12, byte(p << 4)) // L, up
        case 0x11: return (12, byte(p & 0x0F)) // L, down
        case 0x14: return (8, value) // H
        case 0x15: return (19, byte(0x30 | (p & 0x0F))) // S3x
        case 0x16: return (11, byte(p << 4)) // K, up
        case 0x17: return (11, byte(p & 0x0F)) // K, down
        case 0x1E: return (18, value) // R
        case 0x1F: return (19, byte(0x40 | (p & 0x0F))) // S4x
        case 0x28: return (15, 0) // O, its value in the bytes that follow
        case 0x29: return (17, byte(p & 0x0F)) // Q
        case 0x2A: return (19, byte(0xC0 | p)) // SCx
        case 0x2B: return (19, byte(0xD0 | (p & 0x0F))) // SDx
        case 0x32: return (2, value) // B
        case 0x33: return (3, p < 64 ? byte(p / 10 << 4 | p % 10) : 0) // C, its row in tens and ones as Scream Tracker has it
        case 0x34: return (19, byte(0xB0 | (p & 0x0F))) // SBx
        case 0x35: return (19, byte(0xE0 | (p & 0x0F))) // SEx
        case 0x3C: return (1, value) // A
        case 0x3D: return (20, value) // T
        case 0x46: return (10, value) // J
        case 0x47: return (19, byte(0x20 | (p & 0x0F))) // S2x
        case 0x48: return (19, byte(0x80 | (p & 0x0F))) // S8x
        default: return (0, 0)
        }
    }

    // MARK: Both

    /// A note as OpenMPT numbers them (13 for C-0) as an S3M file has it: its octave above and its
    /// semitone below. 254 ends the note sounding, as 255, the note off, does on a channel of
    /// samples alone; others are none.
    private static func s3mNote(_ note: Int) -> UInt8 {
        if note == 254 || note == 255 { return 254 }
        guard note >= 13, note <= 120 else { return 255 }
        return UInt8((note - 13) / 12) << 4 | UInt8((note - 13) % 12)
    }

    /// A sample's sound, as much of it as the file has. (A chunk cut a little short keeps the
    /// sample's length, and the end of it is silence; one that speaks of far more than it holds is
    /// not believed.)
    private static func sound(_ data: [UInt8], from: Int, end: Int, length: Int, tune: inout Tune) -> [UInt8] {
        let there = max(0, min(end, data.count) - from)
        if length > 0, length < 1 << 28 { tune.cutShort.add(length: length, there: there) }
        var sound = [UInt8](repeating: 0, count: max(0, length - there > 1 << 20 ? there : length))
        for k in 0 ..< min(sound.count, there) { sound[k] = data[from + k] }
        return sound
    }
}

extension MASIFile.Tune {
    /// The tune as an S3M file of a tracker that came after Scream Tracker, with samples that have a
    /// sign; its songs; and what of it is not played.
    func s3m() throws -> (s3m: [UInt8], title: String, songs: [ST3Module.Song], shortfalls: [String]) {
        var shortfalls = self.shortfalls
        let channels = min(self.channels, 32)
        if self.channels > 32 {
            shortfalls.append("It has more channels than Scream Tracker 3's replayer has room for, and those beyond are left out.")
        }

        // The patterns, numbered afresh in the order of their numbers in the file, as many as there is room for.
        let numbers = patterns.keys.sorted()
        var renumbered: [Int: Int] = [:]
        for number in numbers.prefix(ST3Module.mostPatterns) { renumbered[number] = renumbered.count }
        // The samples, by their numbers.
        let sampleCount = min(ST3Module.mostInstruments, samples.keys.max() ?? 0)
        if numbers.count > ST3Module.mostPatterns || (samples.keys.max() ?? 0) > ST3Module.mostInstruments {
            shortfalls.append("It has more patterns or samples than Scream Tracker 3's replayer has room for, and those beyond are left out.")
        }

        // The list of patterns: each song's, one after another, each with an end after it; and each
        // song's place in it and its settings.
        var orders: [UInt8] = []
        var songs: [ST3Module.Song] = []
        for song in self.songs {
            let start = orders.count
            guard start < ST3Module.mostOrders - 1 else { break }
            // (A pattern there is not is an end, as OpenMPT has it.)
            orders += song.orders.prefix(ST3Module.mostOrders - 1 - start).map { order in
                order == MASIFile.Song.skip ? 254 : order == MASIFile.Song.end ? 255 : renumbered[order].map { UInt8($0) } ?? 255
            }
            if start + song.orders.count > ST3Module.mostOrders - 1 {
                shortfalls.append("Its songs are longer together than Scream Tracker 3's list of patterns has room for, and what is beyond is left out.")
            }
            orders.append(255)
            let pans = (0 ..< 32).map { channel -> UInt8 in
                guard channel < channels else { return 0 }
                return 0x20 | UInt8(min(15, (song.pans[channel] * 15 + 128) >> 8))
            }
            let restart = song.restart < song.orders.count ? song.restart : 0
            songs.append(ST3Module.Song(start: start, restart: start + restart, speed: UInt8(min(255, song.speed)), tempo: UInt8(max(32, min(255, song.tempo))),
                                        pans: pans, surround: (0 ..< 32).map { $0 < channels && song.surround[$0] }, title: song.name))
        }
        guard let first = orders.first(where: { $0 != 254 }), first != 255 else { throw TuneError.malformed("a PSM file with no pattern to play") }
        if self.songs.contains(where: { $0.volumes.prefix(channels).contains { $0 != 64 } }) {
            shortfalls.append("Its channels' own volumes are left out, as Scream Tracker 3 has none.")
        }
        if farOffsets { shortfalls.append("Where it starts a sample from further in than 65,535 of its samples, the start is played from the nearest place under that.") }
        if orders.count & 1 != 0 { orders.append(255) }
        let patternCount = renumbered.count
        let instrumentsAt = (0x60 + orders.count + 2 * (sampleCount + patternCount) + 32 + 15) & ~15
        var out = [UInt8](repeating: 0, count: instrumentsAt + 0x50 * sampleCount)
        func put16(_ value: Int, at i: Int) {
            out[i] = UInt8(value & 0xFF)
            out[i + 1] = UInt8((value >> 8) & 0xFF)
        }
        func put32(_ value: Int, at i: Int) {
            put16(value & 0xFFFF, at: i)
            put16(value >> 16, at: i + 2)
        }
        for (k, byte) in title.utf8.prefix(27).enumerated() { out[k] = byte }
        out[0x1C] = 0x1A
        out[0x1D] = 16
        put16(orders.count, at: 0x20)
        put16(sampleCount, at: 0x22)
        put16(patternCount, at: 0x24)
        // Made by no tracker that Scream Tracker's replayer knows of, with samples that have a sign.
        put16(0, at: 0x28)
        put16(1, at: 0x2A)
        out[0x2C ..< 0x30] = [0x53, 0x43, 0x52, 0x4D]
        out[0x30] = 64
        out[0x31] = songs[0].speed
        out[0x32] = songs[0].tempo
        out[0x33] = 0x80 | 0x30
        out[0x34] = 16
        out[0x35] = 252
        // Each channel at the place the first song has for it, the nearest of the sixteen the
        // Ultrasound has. The channels are numbered as the patterns number them.
        let pansAt = 0x60 + orders.count + 2 * (sampleCount + patternCount)
        for channel in 0 ..< 32 {
            out[0x40 + channel] = channel < channels ? UInt8(channel) : 255
            out[pansAt + channel] = songs[0].pans[channel]
        }
        for (k, order) in orders.enumerated() { out[0x60 + k] = order }

        // The samples' headers.
        for index in 0 ..< sampleCount {
            let o = instrumentsAt + index * 0x50
            put16(o >> 4, at: 0x60 + orders.count + index * 2)
            guard let sample = samples[index + 1] else { continue }
            let frames = sample.bytes.count / (sample.sixteenBit ? 2 : 1)
            out[o] = 1
            for (k, byte) in sample.fileName.utf8.prefix(12).enumerated() { out[o + 1 + k] = byte }
            put32(frames, at: o + 0x10)
            let loopEnd = min(sample.loopEnd, frames), loopStart = min(sample.loopStart, loopEnd)
            let loops = sample.loops && loopStart < loopEnd
            put32(loops ? loopStart : 0, at: o + 0x14)
            put32(loops ? loopEnd : 0, at: o + 0x18)
            out[o + 0x1C] = sample.volume
            out[o + 0x1F] = (loops ? 1 : 0) | (sample.sixteenBit ? 4 : 0)
            // (A rate of nothing is 8,363, as OpenMPT has it.)
            put32(sample.rate == 0 ? 8363 : min(sample.rate, 0x3FFF_FFFF), at: o + 0x20)
            for (k, byte) in sample.name.utf8.prefix(27).enumerated() { out[o + 0x30 + k] = byte }
            out[o + 0x4C ..< o + 0x50] = [0x53, 0x43, 0x52, 0x53]
        }

        // The patterns, of 64 rows each: one of fewer ends early, with C00 on its last row; of one of
        // more, only the first 64 are played.
        var shortened = false, unbroken = false
        for number in numbers.prefix(ST3Module.mostPatterns) {
            guard let cells = patterns[number], let index = renumbered[number] else { continue }
            let rowCount = rows[number] ?? 64
            if rowCount > 64 { shortened = true }
            while out.count & 15 != 0 { out.append(0) }
            put16(out.count >> 4, at: 0x60 + orders.count + sampleCount * 2 + index * 2)
            let start = out.count
            out += [0, 0]
            for row in 0 ..< 64 {
                let ends = row == rowCount - 1 && rowCount < 64
                var broken = !ends || (0 ..< self.channels).contains { cells[row * self.channels + $0].command == 3 || cells[row * self.channels + $0].command == 2 }
                for channel in 0 ..< channels where row < rowCount {
                    var cell = cells[row * self.channels + channel]
                    if cell.command == 19, cell.value == 0xC0 {
                        // SC0 is nothing to Scream Tracker, and to OpenMPT, in these files, the note
                        // silenced on the row's first tick: as a volume of nought on the row is.
                        cell.command = 0
                        cell.volume = 0
                    } else if cell.command == 19, cell.value == 0 {
                        // (And S00 nothing, where Scream Tracker would take it for the last S command again.)
                        cell.command = 0
                    }
                    if !broken, cell.command == 0 {
                        cell.command = 3
                        cell.value = 0
                        broken = true
                    }
                    let sample = cell.sample <= sampleCount ? UInt8(cell.sample) : 0
                    var mask = UInt8(channel)
                    if cell.note != 255 || sample != 0 { mask |= 0x20 }
                    if cell.volume != 255 { mask |= 0x40 }
                    if cell.command != 0 { mask |= 0x80 }
                    guard mask & 0xE0 != 0 else { continue }
                    out.append(mask)
                    if mask & 0x20 != 0 { out += [cell.note, sample] }
                    if mask & 0x40 != 0 { out.append(cell.volume) }
                    if mask & 0x80 != 0 { out += [cell.command, cell.value] }
                }
                if !broken { unbroken = true }
                out.append(0)
            }
            let length = out.count - start
            out[start] = UInt8(length & 0xFF)
            out[start + 1] = UInt8(length >> 8)
        }
        if shortened { shortfalls.append("Its patterns of more than 64 rows are played as 64.") }
        if unbroken { shortfalls.append("A pattern of fewer than 64 rows, with a command on every channel of its last row, plays on to 64.") }

        // The sound of the samples, each where its header says.
        for index in 0 ..< sampleCount {
            guard let sample = samples[index + 1], !sample.bytes.isEmpty else { continue }
            while out.count & 15 != 0 { out.append(0) }
            let o = instrumentsAt + index * 0x50, paragraph = out.count >> 4
            out[o + 0x0D] = UInt8((paragraph >> 16) & 0xFF)
            put16(paragraph & 0xFFFF, at: o + 0x0E)
            out += sample.bytes
        }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }
        // (A file of one song plays it as a file of several plays each; its name is said only where there are several.)
        if songs.count == 1 { songs[0].title = "" }
        return (out, title, songs, shortfalls)
    }
}
