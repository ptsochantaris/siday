// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the Musicline Editor's DeliTracker player's loading of a module (`LoadModule` and what it
// calls, in UADE's amigasrc/players/other/musicline_editor/mlineplayer102.asm), and the editor's own
// account of its files there (MlEdFileFormat.doc).

import SidayFoundation

extension MusiclinePlayer {
    /// A tune of the module (`tune_Title` and on): its title, its tempo (the CIA's ticks a second at 125
    /// are fifty), speed (ticks a row) and groove (the speed of every other row, nought for none), its
    /// volume (which the player does not use), whether it has eight voices, and each voice's list: 256
    /// words at most, as the player reads it into a buffer of 512 bytes filled first with $0010 (part 0,
    /// not transposed); nil for a voice with none.
    struct Tune {
        var title = ""
        var tempo: UInt16 = 0
        var speed: UInt8 = 0
        var groove: UInt8 = 0
        var volume: UInt16 = 0
        var playMode: UInt8 = 0
        var lists: [[UInt8]?] = Array(repeating: nil, count: 8)
        /// How many words each list has in the file: the place past which a voice has come to its end.
        var lengths: [Int] = Array(repeating: 0, count: 8)
    }

    /// An instrument (`inst_Title` and on, 206 bytes, read from its chunk as they are), and the places in
    /// memory of its sample and its loop, which the player puts in it once the sample is loaded: like a
    /// sample's own header from 32, so that the player reads either as a sample.
    struct Instrument {
        var bytes: [UInt8]
        var pointer = 0
        var repPointer = 0

        func byte(_ at: Int) -> UInt8 { at < bytes.count ? bytes[at] : 0 }
        func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }

        static let size = 206
        static let smplNumber = 32, smplType = 33, smplLength = 38, smplRepLength = 44, fineTune = 46, semiTone = 48
        static let smplStart = 50, smplRepStart = 54, volume = 58, transpose = 60, slideSpeed = 61
        static let effects1 = 62, effects2 = 63, envelope = 64
        static let vibDir = 88, vibWaveNum = 89, vibSpeed = 90, vibDelay = 92, vibAtkSpd = 94, vibAttack = 96, vibDepth = 98
        static let treDir = 100, treWaveNum = 101, treSpeed = 102, treDelay = 104, treAtkSpd = 106, treAttack = 108, treDepth = 110
        static let arpTable = 112, arpSpeed = 114, arpGroove = 115
        static let envTraPhaFilBits = 116, traWaveNums = 117
        static let traStart = 122, traRepeat = 124, traRepEnd = 126, traSpeed = 128, traTurns = 130, traDelay = 132
        static let phaStart = 134, phaRepeat = 136, phaRepEnd = 138, phaSpeed = 140, phaTurns = 142, phaDelay = 144, phaType = 146
        static let mixResLooBits = 148, mixWaveNum = 149
        static let mixStart = 150, mixRepeat = 152, mixRepEnd = 154, mixSpeed = 156, mixTurns = 158, mixDelay = 160
        static let resStart = 162, resRepeat = 164, resRepEnd = 166, resSpeed = 168, resTurns = 170, resDelay = 172
        static let mixResFilBoost = 174, resAmp = 175
        static let filStart = 176, filRepeat = 178, filRepEnd = 180, filSpeed = 182, filTurns = 184, filDelay = 186, filType = 189
        static let looStart = 190, looRepeat = 192, looRepEnd = 194, looLength = 196, looLpStep = 198, looWait = 200
        static let looDelay = 202, looTurns = 204
    }

    /// A sample (`smpl_Title` and on, its header of 50 bytes): its type (nought for a sample, and for a
    /// waveform of 256 bytes, the size its instruments play it at), its length and its loop's in words,
    /// its fine tuning and transposition; and its places in memory: its sound's, and the loop's, which
    /// the player has as far into it as the editor saved them apart.
    struct Sample {
        var header: [UInt8]
        var data = 0
        var pointer = 0
        var repPointer = 0

        func byte(_ at: Int) -> UInt8 { at < header.count ? header[at] : 0 }
        func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
        func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }

        static let size = 50
        static let type = 33, savedPointer = 34, length = 38, savedRepPointer = 40, repLength = 44, fineTune = 46, semiTone = 48

        /// Put at `at` (`LoadSmpl`'s `.setwsptrs`): the loop as far in as the saved places are apart, or
        /// at the start if they are the wrong way round.
        mutating func place(at: Int) {
            let apart = Int32(bitPattern: long(Self.savedRepPointer) &- long(Self.savedPointer))
            data = at
            pointer = at
            repPointer = at + Int(max(0, apart))
        }
    }

    /// What a voice plays as its sample: an instrument's (`inst_SmplType` and on) or a sample's, at the
    /// same places in either, as the player reads them by a pointer to either.
    struct Sound {
        var type: UInt8 = 0
        var pointer = 0
        var length: UInt16 = 0
        var repPointer = 0
        var repLength: UInt16 = 0
        var fineTune: UInt16 = 0
        var semiTone: UInt16 = 0
    }

    func sound(instrument number: Int) -> Sound {
        guard number < instruments.count, let instrument = instruments[number] else { return Sound() }
        return Sound(type: instrument.byte(Instrument.smplType), pointer: instrument.pointer, length: instrument.word(Instrument.smplLength),
                     repPointer: instrument.repPointer, repLength: instrument.word(Instrument.smplRepLength),
                     fineTune: instrument.word(Instrument.fineTune), semiTone: instrument.word(Instrument.semiTone))
    }

    /// A sample's, as a sound; for one not in the file (the player's pointer to it nought, and so the
    /// Amiga's first bytes read for it), nought.
    func sound(sample number: Int) -> Sound {
        guard number < samples.count, let sample = samples[number] else { return Sound() }
        return Sound(type: sample.byte(Sample.type), pointer: sample.pointer, length: sample.word(Sample.length), repPointer: sample.repPointer,
                     repLength: sample.word(Sample.repLength), fineTune: sample.word(Sample.fineTune), semiTone: sample.word(Sample.semiTone))
    }

    /// The module as `LoadModule` reads it.
    struct Loaded {
        var tunes: [Tune] = []
        /// The parts by their numbers (`PartList`, 1,024), each 128 rows of 12 bytes unpacked; the
        /// arpeggios (`ArpgList`, 256), each 128 rows of 6 bytes; the instruments (`InstList`, from 1) and
        /// the samples (`SmplList`, from 1), each numbered in the order the file has them.
        var parts: [[UInt8]?] = Array(repeating: nil, count: 1024)
        var arpeggios: [[UInt8]?] = Array(repeating: nil, count: 256)
        var instruments: [Instrument?] = [nil]
        var samples: [Sample?] = [nil]
        /// Each sample's sound, unpacked, and for a waveform with its smaller copies after it.
        var sounds: [[UInt8]] = [[]]
        var sampleBytes = 0
        var info: [String] = []
        var version = ""
        var shortfalls: [String] = []

        init(_ data: [UInt8]) throws(TuneError) {
            func byte(_ at: Int) -> UInt8 { at >= 0 && at < data.count ? data[at] : 0 }
            func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
            func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }
            func id(_ at: Int) -> String { String(decoding: (0 ..< 4).map { byte(at + $0) }, as: UTF8.self) }
            func text(_ at: Int, _ count: Int) -> String {
                var scalars = String.UnicodeScalarView()
                for k in 0 ..< count {
                    let b = byte(at + k)
                    if b == 0 { break }
                    scalars.append(Unicode.Scalar(b >= 0x20 && b <= 0x7E ? b : 0x20))
                }
                return String(scalars).trimmed()
            }

            // The version chunk, after the module's (at 8 if there is none: the player looks there first).
            var at = 8
            if id(at) != "VERS" { at = 12 + Int(long(8)) }
            guard id(at) == "VERS" else { throw TuneError.malformed("a Musicline Editor module with no VERS chunk") }
            version = text(at + 10, max(0, min(16, Int(long(at + 4)) - 2)))
            at += 8 + Int(long(at + 4))

            // (`LoadHeader`) Each chunk in turn, to the first the player does not know.
            chunks: while at + 8 <= data.count {
                let length = Int(long(at + 4))
                let body = at + 8
                switch id(at) {
                case "TUNE":
                    // (`LoadTune`) Its 40 bytes, then its voices' sizes and lists: the chunk's own length is
                    // not used. No voices (a count of nought) means none at all.
                    var tune = Tune()
                    tune.title = text(body, 32)
                    tune.tempo = word(body + 32)
                    tune.speed = byte(body + 34)
                    tune.groove = byte(body + 35)
                    tune.volume = word(body + 36)
                    tune.playMode = byte(body + 38)
                    let count = Int(byte(body + 39))
                    var place = body + 40 + 4 * count
                    for c in 0 ..< count {
                        let size = Int(long(body + 40 + 4 * c))
                        guard size > 0, c < 8 else {
                            place += size
                            continue
                        }
                        var list = [UInt8](repeating: 0, count: 512)
                        for k in 0 ..< 256 { list[2 * k + 1] = 0x10 }
                        // (A list longer than its buffer would run past it: here it is cut at 256 words.)
                        for k in 0 ..< min(size, 512) { list[k] = byte(place + k) }
                        tune.lists[c] = list
                        tune.lengths[c] = min(size, 512) / 2
                        place += size
                    }
                    if tunes.count < 256 { tunes.append(tune) }
                    at = place
                    continue chunks
                case "PART":
                    // (`LoadPart`) Its number, and its rows packed: a byte of which of the row's six words
                    // follow (bit 7 for the end), and those words.
                    let number = Int(word(body))
                    var rows = [UInt8](repeating: 0, count: 12 * 128)
                    var from = body + 2
                    var to = 0
                    let end = min(body + length, data.count)
                    while from < end, byte(from) & 0x80 == 0, to < rows.count {
                        var mask = byte(from)
                        from += 1
                        for _ in 0 ..< 6 {
                            if mask & 1 != 0 {
                                if to + 1 < rows.count {
                                    rows[to] = byte(from)
                                    rows[to + 1] = byte(from + 1)
                                }
                                from += 2
                            }
                            mask >>= 1
                            to += 2
                        }
                    }
                    if number < parts.count { parts[number] = rows }
                case "ARPG":
                    // (`LoadArpg`) Its number, and its rows.
                    let number = Int(word(body))
                    var rows = [UInt8](repeating: 0, count: 6 * 128)
                    for k in 0 ..< min(max(0, length - 2), rows.count) { rows[k] = byte(body + 2 + k) }
                    if number < arpeggios.count { arpeggios[number] = rows }
                case "INST":
                    // (`LoadInst`) Its bytes as they are, numbered from 1.
                    var bytes = [UInt8](repeating: 0, count: Instrument.size)
                    for k in 0 ..< min(length, Instrument.size) { bytes[k] = byte(body + k) }
                    if instruments.count < 256 { instruments.append(Instrument(bytes: bytes)) }
                case "SMPL":
                    // (`LoadSmpl`) Its unpacked length, the byte that begins a run of its packing, a byte,
                    // its header and its sound, numbered from 1. The chunk's length is that of the header
                    // and the sound, and not of the six bytes before them.
                    let original = Int(long(body))
                    let command = byte(body + 4)
                    let header = (0 ..< Sample.size).map { byte(body + 6 + $0) }
                    let packed = max(0, length - Sample.size)
                    let soundAt = body + 6 + Sample.size
                    var sound: [UInt8]
                    if packed == original {
                        sound = (0 ..< original).map { byte(soundAt + $0) }
                    } else {
                        sound = Self.unpacked(data, from: soundAt, count: packed, command: command, size: original)
                    }
                    // A waveform of 256 bytes: $80 made $81, and its copies at half the size each after it.
                    if original == 256 {
                        sound += [UInt8](repeating: 0, count: 240)
                        for k in 0 ..< 256 where sound[k] == 0x80 { sound[k] = 0x81 }
                        var from = 0
                        for to in 256 ..< 496 {
                            sound[to] = sound[from]
                            from += 2
                        }
                    }
                    if samples.count < 256 {
                        samples.append(Sample(header: header))
                        sounds.append(sound)
                        sampleBytes += (sound.count + 7) & ~7
                    }
                    at = soundAt + packed
                    continue chunks
                case "INFO":
                    // (`LoadInfo`: read and passed over.) Its strings: the title, the author, the date, the
                    // length and five lines.
                    var strings: [String] = []
                    var from = body
                    while from < min(body + length, data.count), strings.count < 9 {
                        var end = from
                        while end < min(body + length, data.count), data[end] != 0 { end += 1 }
                        strings.append(text(from, end - from))
                        from = end + 1
                    }
                    info = strings
                default:
                    break chunks
                }
                at = body + length
            }
            guard !tunes.isEmpty else { throw TuneError.malformed("a Musicline Editor module with no tunes") }
        }

        /// A sample's sound, unpacked as the player's `DeltaDePacker` does: each byte as it is, but for the
        /// command byte, which begins a run: a byte, and after it as many more as the next word says, each
        /// that one moved by a nibble of the bytes that follow, the high one first, from -8 to 7. Its end
        /// comes where the packed bytes do; a sound unpacked short is left nought after (the player's
        /// memory, cleared), and one unpacked long is cut at its length (the player would write past it).
        static func unpacked(_ data: [UInt8], from: Int, count: Int, command: UInt8, size: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: size)
            var to = 0
            var at = from
            let end = min(from + count, data.count)
            func put(_ value: UInt8) {
                if to < size { out[to] = value }
                to += 1
            }
            func nibble(_ value: UInt8) -> UInt8 { value & 8 != 0 ? value | 0xF0 : value }
            while at < end {
                let b = data[at]
                at += 1
                if b != command {
                    put(b)
                    continue
                }
                guard at + 3 <= end else { break }
                var value = data[at]
                var left = Int(data[at + 1]) << 8 | Int(data[at + 2])
                at += 3
                put(value)
                while left > 0, at < end {
                    let pair = data[at]
                    at += 1
                    value &+= nibble(pair >> 4)
                    put(value)
                    left -= 1
                    if left == 0 { break }
                    value &+= nibble(pair & 0xF)
                    put(value)
                    left -= 1
                }
            }
            return out
        }
    }
}
