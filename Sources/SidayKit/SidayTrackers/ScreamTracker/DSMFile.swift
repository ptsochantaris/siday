// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the DSM loader of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// A DSM file of the Digital Sound Interface Kit, Carlos Hasan's library for playing music in programs
/// for DOS: a RIFF file of the kind "DSMF", into which the kit's converter put the modules of other
/// trackers for its player.
///
/// It is made of chunks: the song (a name, how many of each thing there are, the speed and tempo,
/// up to sixteen channels each with a place between the speakers, and the list of patterns), then
/// each pattern and each sample in a chunk of its own. A pattern is 64 rows packed as an S3M file
/// packs them; a sample is eight bits or sixteen, with a rate of its own and a loop. The commands
/// are ProTracker's, numbered as a MOD file numbers them, with 8xx a place between the speakers
/// from 00 to 80 (and A4 for surround).
///
/// Its player is not to be had; OpenMPT plays these files by Scream Tracker 3's rules (an S3M file's,
/// with the slides fine and extra fine inside the commands, and one value remembered for most of
/// them together), and so they are played here by Scream Tracker 3's own replayer, on a Gravis
/// Ultrasound, whose voices each have a place between the speakers: the file is read into an S3M
/// file, with each command under its S3M letter, and that is played.
enum DSMFile {
    /// True for a file that says it is one of these: "RIFF", its length and "DSMF", or OpenMPT's other
    /// way, "DSMF" and eight bytes; and then the song's chunk.
    static func songAt(_ data: [UInt8]) -> Int? {
        let f = ByteReader(data)
        let riff = f.ascii(at: 0, length: 4) == "RIFF" && f.ascii(at: 8, length: 4) == "DSMF"
        let other = f.ascii(at: 0, length: 4) == "DSMF"
        let at = riff ? 12 : other ? 16 : -1
        guard at > 0, f.ascii(at: at, length: 4) == "SONG" else { return nil }
        return at
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> S3MRenderer {
        let (s3m, title, shortfalls) = try read(data)
        return try S3MRenderer(s3m, options: options, card: .gus, format: "DSM", tracker: "Digital Sound Interface Kit", title: title,
                               shortfalls: shortfalls, loudness: loudness, asDSIK: true)
    }

    /// How loud these files are made, beside an S3M file on the same card: set by measure, so that
    /// the middle one of them is about as loud as the middle one of other modules.
    private static let loudness: Float = 1.2

    /// The file as an S3M file, its title, and what of it is not played.
    static func read(_ data: [UInt8]) throws -> (s3m: [UInt8], title: String, shortfalls: [String]) {
        guard let songAt = songAt(data) else { throw TuneError.malformed("not a DSM file") }
        let f = ByteReader(data)
        let songSize = f.size32le(songAt + 4), song = songAt + 8
        // (How many samples the song says it has is not looked at: they are the chunks there are.)
        let orderCount = f.u16le(song + 36), patternCount = f.u16le(song + 40)
        let channelCount = max(1, f.u16le(song + 42)), restart = f.u16le(song + 34)
        guard orderCount <= 128, f.u16le(song + 42) <= 16, patternCount <= 256, restart <= 128 else {
            throw TuneError.malformed("a DSM file with more orders, channels or patterns than a DSM file can have")
        }
        // (A song chunk shorter than the song's header has nothing beyond it.)
        func songByte(_ i: Int) -> UInt8 { i < songSize ? f[song + i] : 0 }
        let title = f.dos(at: song, length: 28)

        // The patterns and samples, each in a chunk, in the order they are numbered.
        var patterns: [(at: Int, end: Int)] = [], samples: [(at: Int, end: Int)] = []
        var at = song + songSize
        while at + 8 <= data.count {
            let size = f.size32le(at + 4), start = at + 8, end = min(data.count, start + size)
            switch f.ascii(at: at, length: 4) {
            case "PATT": patterns.append((start, end))
            case "INST": samples.append((start, end))
            default: break
            }
            at = start + size
        }

        var shortfalls: [String] = []
        if patterns.count > ST3Module.mostPatterns || samples.count > ST3Module.mostInstruments {
            shortfalls.append("It has more patterns or samples than Scream Tracker 3's replayer has room for, and those beyond are left out.")
        }
        patterns = Array(patterns.prefix(ST3Module.mostPatterns))
        samples = Array(samples.prefix(ST3Module.mostInstruments))
        // (Scream Tracker's song goes back to its top.)
        if restart > 0, restart < orderCount { shortfalls.append("When its song comes to the end it starts again from the top, not from where the file says.") }

        // MARK: The S3M file

        var orders = (0 ..< orderCount).map { songByte(64 + $0) }
        // (A pattern there is not, or none beyond what an S3M file can have, is the end of the list.)
        orders = orders.map { $0 < 254 && Int($0) >= patterns.count ? 255 : $0 }
        guard let first = orders.first(where: { $0 != 254 }), first != 255 else { throw TuneError.malformed("a DSM file with no pattern to play") }
        if orders.count & 1 != 0 { orders.append(255) }
        let instrumentsAt = (0x60 + orders.count + 2 * (samples.count + patterns.count) + 32 + 15) & ~15
        var out = [UInt8](repeating: 0, count: instrumentsAt + 0x50 * samples.count)
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
        put16(samples.count, at: 0x22)
        put16(patterns.count, at: 0x24)
        // Made by no tracker that Scream Tracker's replayer knows of, with samples that have a sign.
        put16(0, at: 0x28)
        put16(1, at: 0x2A)
        out[0x2C ..< 0x30] = [0x53, 0x43, 0x52, 0x4D]
        let globalVolume = min(songByte(44), 64)
        out[0x30] = globalVolume == 0 ? 64 : globalVolume
        out[0x31] = songByte(46) == 0 ? 6 : songByte(46)
        out[0x32] = songByte(47) < 32 ? 125 : songByte(47)
        out[0x33] = 0x80 | 0x30
        out[0x34] = 16
        out[0x35] = 252
        // Each channel at one of the sixteen places the Ultrasound has between the speakers, the
        // nearest to the file's. (A place beyond 80 is none, which OpenMPT leaves in the middle.) The
        // channels are numbered as the patterns number them, so that each place is its own channel's.
        for channel in 0 ..< 32 {
            guard channel < min(channelCount, 16) else {
                out[0x40 + channel] = 255
                continue
            }
            let place = Int(songByte(48 + channel))
            let pan = place <= 0x80 ? place * 2 : 128
            out[0x40 + channel] = UInt8(channel)
            out[0x60 + orders.count + 2 * (samples.count + patterns.count) + channel] = 0x20 | UInt8(min(15, (pan * 15 + 128) >> 8))
        }
        for (k, order) in orders.enumerated() { out[0x60 + k] = order }

        // The samples' headers, and their sound after the patterns.
        var sounds: [[UInt8]] = []
        var cutShort = Shortfall.CutShort()
        for (index, chunk) in samples.enumerated() {
            let h = chunk.at, o = instrumentsAt + index * 0x50
            put16(o >> 4, at: 0x60 + orders.count + index * 2)
            let flags = f.u16le(h + 13), sixteenBit = flags & 4 != 0
            let length = f.size32le(h + 16)
            let bytes = sixteenBit ? length * 2 : length
            let from = h + 64, inChunk = max(0, chunk.end - from)
            cutShort.add(length: bytes, there: chunk.end - from)
            // (A chunk cut a little short keeps the sample's length, and the end of it is silence;
            // one that speaks of far more than it holds is not believed.)
            var sound = [UInt8](repeating: 0, count: max(0, bytes - inChunk > 1 << 20 ? inChunk : bytes))
            for k in 0 ..< min(sound.count, inChunk) { sound[k] = data[from + k] }
            if sixteenBit, sound.count & 1 != 0 { sound.removeLast() }
            // To bytes with a sign, as the S3M file says its samples are: the file's are without one,
            // with one (2), or as the difference of each byte from the one before (0x40).
            if flags & 0x40 != 0 {
                var sum: UInt8 = 0
                for k in sound.indices {
                    sum &+= sound[k]
                    sound[k] = sum
                }
            } else if flags & 2 == 0 {
                for k in stride(from: sixteenBit ? 1 : 0, to: sound.count, by: sixteenBit ? 2 : 1) { sound[k] ^= 0x80 }
            }
            sounds.append(sound)
            out[o] = 1
            for (k, byte) in f.ascii(at: h, length: 12).utf8.prefix(12).enumerated() { out[o + 1 + k] = byte }
            put32(sound.count / (sixteenBit ? 2 : 1), at: o + 0x10)
            put32(f.size32le(h + 20), at: o + 0x14)
            put32(f.size32le(h + 24), at: o + 0x18)
            out[o + 0x1C] = min(f[h + 15], 64)
            out[o + 0x1F] = (flags & 1 != 0 ? 1 : 0) | (sixteenBit ? 4 : 0)
            // (A rate of nothing is 8,363, as OpenMPT has it.)
            put32(f.size32le(h + 32) == 0 ? 8363 : f.size32le(h + 32), at: o + 0x20)
            for (k, byte) in f.dos(at: h + 36, length: 28).utf8.prefix(27).enumerated() { out[o + 0x30 + k] = byte }
            out[o + 0x4C ..< o + 0x50] = [0x53, 0x43, 0x52, 0x53]
        }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        // The patterns, each read and written again with S3M's commands.
        var surround = false
        for (index, chunk) in patterns.enumerated() {
            while out.count & 15 != 0 { out.append(0) }
            put16(out.count >> 4, at: 0x60 + orders.count + samples.count * 2 + index * 2)
            let start = out.count
            out += [0, 0]
            var i = chunk.at + 2, row = 0
            while i < chunk.end, row < 64 {
                let what = data[i]
                i += 1
                if what == 0 {
                    out.append(0)
                    row += 1
                    continue
                }
                let channel = Int(what & 0x0F)
                var note: UInt8 = 255, instrument: UInt8 = 0, volume: UInt8?, command: UInt8 = 0, value: UInt8 = 0
                if what & 0x80 != 0 {
                    let n = f[i]
                    i += 1
                    if n >= 1, n <= 108 { note = UInt8((Int(n) - 1) / 12) << 4 | UInt8((Int(n) - 1) % 12) } else if n == 254 { note = 254 }
                }
                if what & 0x40 != 0 {
                    instrument = f[i]
                    i += 1
                }
                if what & 0x20 != 0 {
                    volume = min(f[i], 64)
                    i += 1
                }
                if what & 0x10 != 0 {
                    (command, value) = translated(f[i], f[i + 1], volume: &volume)
                    if f[i] == 8, f[i + 1] == 0xA4 { surround = true }
                    i += 2
                }
                // (A channel beyond the song's is read and goes nowhere.)
                guard channel < min(channelCount, 16) else { continue }
                var mask = UInt8(channel)
                if note != 255 || instrument != 0 { mask |= 0x20 }
                if volume != nil { mask |= 0x40 }
                if command != 0 { mask |= 0x80 }
                guard mask & 0xE0 != 0 else { continue }
                out.append(mask)
                if mask & 0x20 != 0 { out += [note, instrument] }
                if let volume { out.append(volume) }
                if command != 0 { out += [command, value] }
            }
            while row < 64 {
                out.append(0)
                row += 1
            }
            let length = out.count - start
            out[start] = UInt8(length & 0xFF)
            out[start + 1] = UInt8(length >> 8)
        }
        if surround { shortfalls.append("Its surround sound (8A4) is played in the middle.") }

        // The sound of the samples, each where its header says.
        for (index, sound) in sounds.enumerated() where !sound.isEmpty {
            while out.count & 15 != 0 { out.append(0) }
            let o = instrumentsAt + index * 0x50, paragraph = out.count >> 4
            out[o + 0x0D] = UInt8((paragraph >> 16) & 0xFF)
            put16(paragraph & 0xFFFF, at: o + 0x0E)
            out += sound
        }
        return (out, title, shortfalls)
    }

    /// A command as the file has it, ProTracker's by number, as an S3M file has it: its letter
    /// (counted from A as 1, and 0 for none) and its value. A volume set by Cxx is the volume column's.
    private static func translated(_ command: UInt8, _ value: UInt8, volume: inout UInt8?) -> (UInt8, UInt8) {
        let high = value >> 4, low = value & 15
        switch command {
        case 0x0: return value == 0 ? (0, 0) : (10, value) // J
        case 0x1: return (6, value) // F, with S3M's fine slides in it
        case 0x2: return (5, value) // E
        case 0x3: return (7, value) // G
        case 0x4: return (8, value) // H
        case 0x5: return (12, value) // L
        case 0x6: return (11, value) // K
        case 0x7: return (18, value) // R
        // X, from 00 to 80; and surround, A4, in the middle.
        case 0x8: return value <= 0x80 ? (24, value) : value == 0xA4 ? (24, 0x40) : (0, 0)
        case 0x9: return (15, value) // O
        case 0xA: return (4, value) // D
        case 0xB: return (2, value) // B
        case 0xC:
            volume = min(value, 64)
            return (0, 0)
        case 0xD: return (3, value) // C, in tens and ones as Scream Tracker's is
        case 0xE:
            switch high {
            case 0x1: return low == 0 ? (0, 0) : (6, 0xF0 | low)
            case 0x2: return low == 0 ? (0, 0) : (5, 0xF0 | low)
            case 0x3: return (19, 0x10 | low)
            case 0x4: return (19, 0x30 | low)
            case 0x5: return (19, 0x20 | low)
            case 0x6: return (19, 0xB0 | low)
            case 0x7: return (19, 0x40 | low)
            case 0x8: return (19, 0x80 | low)
            case 0x9: return (17, low) // Q
            case 0xA: return low == 0 ? (0, 0) : (4, low << 4 | 0x0F)
            case 0xB: return low == 0 ? (0, 0) : (4, 0xF0 | low)
            case 0xC: return (19, 0xC0 | low)
            case 0xD: return (19, 0xD0 | low)
            case 0xE: return (19, 0xE0 | low)
            default: return (0, 0) // the Amiga's filter, and turning a loop inside out
            }
        case 0xF: return value == 0 ? (0, 0) : value < 0x20 ? (1, value) : (20, value) // A or T
        default: return (0, 0)
        }
    }
}
