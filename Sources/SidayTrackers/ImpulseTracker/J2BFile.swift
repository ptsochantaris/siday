// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the J2B loader of OpenMPT (`soundlib/load_j2b.cpp`, after kode54's for his DUMB),
// Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and Copyright (c) 1997-2003
// Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md).

import SidayFoundation

/// A J2B file: the music of Jazz Jackrabbit 2, a module of the Galaxy Sound System packed with zlib.
///
/// The Galaxy Sound System was Carlo Vogelsang's sound engine, which Epic MegaGames' Jazz Jackrabbit
/// 2 (1998) played its music with. Its modules were not made in a tracker of its own: they were made
/// in the trackers of the day and turned into its format (by a converter, mod2j2b), a RIFF file
/// (begun "AM  ", or in an older form "AMFF") with the song, its patterns and its instruments in
/// parts of their own, much as an IT file has them. The game keeps each packed with zlib, behind a
/// header that begins "MUSE" and gives a checksum of what is packed.
///
/// The engine's replayer has never been published. OpenMPT reads these files into the shape of an
/// IT file, and plays them with all of Impulse Tracker's ways that it plays an IT file with; and so
/// they are played here: by Impulse Tracker's replayer, keeping time as OpenMPT does (see
/// `OpenMPTSong`), and with the one thing OpenMPT does otherwise there that these files are heard to
/// need (`IT2Module.playsAsGalaxy`).
///
/// What does not go over as it stands: a place between the speakers or a volume finer than Impulse
/// Tracker's, which is the nearest of its own; and two commands Impulse Tracker has no letters for
/// (FastTracker's Kxx and Lxx, to let go of a key and to move along an envelope), which are left
/// out, and the file says so. (No file of the game's has either.) Unpacked RIFF files of the same
/// two kinds are read as well.
enum J2BFile {
    private typealias Command = IT2ForeignModule.Command

    /// Four bytes as a length, the first the least; one too large to be any is brought down to
    /// where it is still too large. (A whole number in a browser has 32 bits.)
    private static func long(_ f: ByteReader, _ i: Int) -> Int {
        let high = f.u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16le(i)
    }

    /// Four bytes as four letters, or a number of 32 bits.
    private static func letters(_ f: ByteReader, _ i: Int) -> UInt32 {
        UInt32(f.u16le(i)) | UInt32(f.u16le(i + 2)) << 16
    }

    /// For a RIFF file of the Galaxy Sound System: true if it is of the newer kind ("AM  "), false
    /// for the older ("AMFF"); nil for anything else.
    private static func riffKind(_ data: [UInt8]) -> Bool? {
        guard data.count >= 12, data.starts(with: [0x52, 0x49, 0x46, 0x46]) else { return nil } // "RIFF"
        // (Its length must leave room for its song.)
        guard long(ByteReader(data), 4) >= 8 + 73 else { return nil }
        if data[8 ..< 12].elementsEqual([0x41, 0x4D, 0x20, 0x20]) { return true } // "AM  "
        if data[8 ..< 12].elementsEqual([0x41, 0x4D, 0x46, 0x46]) { return false } // "AMFF"
        return nil
    }

    /// The RIFF file a J2B file holds, unpacked and checked: the header must give the file's length,
    /// and the length and checksum (CRC-32) of what is packed, and what is packed must unpack to
    /// as many bytes as it says, with zlib's own checksum right. A file that is the RIFF file already
    /// is given back as it is.
    ///
    /// A file that is shorter than its header says is cut short: what it has is unpacked as far as
    /// it goes, and it is said to be cut (`cut`).
    static func unpacked(_ data: [UInt8], cut: inout Bool) throws(TuneError) -> [UInt8] {
        guard data.starts(with: [0x4D, 0x55, 0x53, 0x45]) else { return data }
        let f = ByteReader(data)
        // (Its next four bytes are 0xDEADBEAF for the newer kind, or 0xDEADBABE for the older.)
        let magic = letters(f, 4)
        guard data.count >= 24, magic == 0xAFBE_ADDE || magic == 0xBEBA_ADDE else { throw .malformed("not a J2B file") }
        let fileLength = long(f, 8), crc = letters(f, 12), packedLength = long(f, 16), length = long(f, 20)
        guard packedLength > 0, fileLength == packedLength + 24, fileLength >= data.count else { throw .malformed("a J2B file whose header makes no sense") }
        if fileLength > data.count {
            guard length > 0, length <= 1 << 26, length / 1032 <= packedLength else { throw .malformed("a J2B file that does not unpack") }
            cut = true
            return try Inflate.zlibCutShort(data, from: 24, to: data.count, size: length)
        }
        guard Inflate.crc32(data, from: 24, to: data.count) == crc else { throw .malformed("a J2B file whose checksum is wrong") }
        // (DEFLATE makes no more than 1,032 bytes of one, and nothing here is near 64 megabytes.)
        guard length > 0, length <= 1 << 26, length / 1032 <= packedLength else { throw .malformed("a J2B file that does not unpack") }
        return try Inflate.zlib(data, from: 24, to: data.count, size: length)
    }

    /// The RIFF file's parts, each by its four letters, where its data starts and ends, in the order
    /// they come, read from a place to an end: each part's data is as long as it says or as there
    /// is, and in the newer kind of file a part of an odd length has a byte after it to make it even.
    private static func chunks(_ f: ByteReader, from start: Int, to end: Int, even: Bool) -> [(id: UInt32, data: Range<Int>)] {
        var found: [(id: UInt32, data: Range<Int>)] = []
        var at = start
        while at + 8 <= end {
            let id = letters(f, at), length = long(f, at + 4)
            let dataStart = at + 8, dataEnd = dataStart + min(length, end - dataStart)
            found.append((id, dataStart ..< dataEnd))
            at = dataEnd
            if even, length % 2 != 0 { at += 1 }
        }
        return found
    }

    private static func id(_ letters: String) -> UInt32 {
        var value: UInt32 = 0
        for (i, byte) in letters.utf8.enumerated() { value |= UInt32(byte) << (8 * UInt32(i)) }
        return value
    }

    // MARK: Commands

    /// OpenMPT's commands, which these files number in this order. What each comes to among Impulse
    /// Tracker's is in `put`.
    private enum Effect: Int {
        case arpeggio = 0, portaUp, portaDown, slideToNote, vibrato, slideToNoteVolume, vibratoVolume, tremolo
        case pan, offset, volumeSlide, jump, volume, breakRow, extended, tempo
        case globalVolume, globalVolumeSlide, keyOff, envelopePosition, channelVolume, channelVolumeSlide, panSlide, retrigger
        case tremor, extraFine
    }

    private static let leftOutNames = ["letting go of a note's key after so many ticks (FastTracker's Kxx)", "moving along an envelope (FastTracker's Lxx)"]

    /// Puts a command into a cell as OpenMPT reads it (`ConvertAMPattern`, with
    /// `ModCommand::ExtendedMODtoS3MEffect`).
    private static func put(_ effect: Effect?, _ value: UInt8, in cell: inout IT2ForeignModule.Cell, leftOut: inout Shortfall.Kinds) {
        let high = value >> 4, low = value & 0x0F
        func set(_ command: UInt8, _ value: UInt8) { cell.set(command: command, value) }
        switch effect {
        case nil: cell.clearCommand()
        case .arpeggio: if value == 0 { cell.clearCommand() } else { set(Command.J, value) }
        case .portaUp: set(Command.F, value)
        case .portaDown: set(Command.E, value)
        case .slideToNote: set(Command.G, value)
        case .vibrato: set(Command.H, value)
        // (Of a slide both up and down, up.)
        case .slideToNoteVolume: set(Command.L, high != 0 ? value & 0xF0 : value)
        case .vibratoVolume: set(Command.K, high != 0 ? value & 0xF0 : value)
        case .tremolo: set(Command.R, value)
        case .pan:
            // Of 128, and A4 is surround.
            if value <= 0x80 { set(Command.X, UInt8(min(255, Int(value) * 2))) } else if value == 0xA4 { set(Command.S, 0x91) } else { set(Command.X, value) }
        case .offset: set(Command.O, value)
        case .volumeSlide: set(Command.D, high != 0 ? value & 0xF0 : value)
        case .jump: set(Command.B, value)
        case .volume:
            // A volume, which is the volume column's. (Beside a volume of the column's own, OpenMPT
            // keeps it as a command, which Impulse Tracker has not: it is done after the column's,
            // and so is the note's volume all the same. See `renderer`.)
            cell.clearCommand()
            cell.set(volume: min(value, 64))
        // (The row to go to is written in tens and ones.)
        case .breakRow: set(Command.C, UInt8(truncatingIfNeeded: Int(high) * 10 + Int(low)))
        case .extended:
            // ProTracker's Exy, as Impulse Tracker's commands.
            switch high {
            case 0x1: set(Command.F, 0xF0 | low)
            case 0x2: set(Command.E, 0xF0 | low)
            case 0x3: set(Command.S, 0x10 | low)
            case 0x4: set(Command.S, 0x30 | (low & 3))
            case 0x5: set(Command.S, (value ^ 0x58) | 0x20)
            case 0x6: set(Command.S, 0xB0 | low)
            case 0x7: set(Command.S, 0x40 | (low & 3))
            case 0x9: set(Command.Q, low)
            case 0xA: if low != 0 { set(Command.D, low << 4 | 0x0F) } else { cell.clearCommand() }
            case 0xB: if low != 0 { set(Command.D, 0xF0 | min(low, 0x0E)) } else { cell.clearCommand() }
            case 0xC:
                if low == 0 {
                    // EC0 cuts the note at once, unless the row has a note of its own to come.
                    cell.clearCommand()
                    cell.set(note: IT2ForeignModule.noteCut)
                } else {
                    set(Command.S, value)
                }
            case 0xD: if low == 0 { cell.clearCommand() } else { set(Command.S, value) }
            case 0x0: cell.clearCommand()
            default: set(Command.S, value)
            }
        case .tempo: if value <= 0x1F { set(Command.A, value) } else { set(Command.T, value) }
        case .globalVolume: set(Command.V, value)
        case .globalVolumeSlide: set(23, high != 0 ? value & 0xF0 : value) // W
        case .keyOff:
            leftOut.note(0)
            cell.clearCommand()
        case .envelopePosition:
            leftOut.note(1)
            cell.clearCommand()
        case .channelVolume: set(13, value) // M
        case .channelVolumeSlide: set(14, value) // N
        case .panSlide: set(16, high != 0 ? value & 0xF0 : value) // P
        case .retrigger: set(Command.Q, value)
        case .tremor: set(Command.I, value)
        case .extraFine:
            // X1y and X2y, the extra fine slides of pitch, which Impulse Tracker's E and F do.
            switch high {
            case 0x1: set(Command.F, 0xE0 | low)
            case 0x2: set(Command.E, 0xE0 | low)
            default: cell.clearCommand()
            }
        }
    }

    // MARK: Reading

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        var cut = false
        let data = try unpacked(data, cut: &cut)
        guard let isAM = riffKind(data) else { throw TuneError.malformed("not a J2B file") }
        let f = ByteReader(data)
        let parts = chunks(f, from: 12, to: data.count, even: isAM)
        func first(_ letters: String) -> Range<Int>? { parts.first { $0.id == id(letters) }?.data }
        func all(_ letters: String) -> [Range<Int>] { parts.filter { $0.id == id(letters) }.map { $0.data } }

        // MARK: The song

        guard let main = first(isAM ? "INIT" : "MAIN"), main.count >= 73 else { throw TuneError.malformed("a J2B file without its song") }
        let channels = Int(f[main.lowerBound + 65])
        guard channels >= 1, main.count >= 73 + channels else { throw TuneError.malformed("a J2B file without its song") }
        let title = f.dos(at: main.lowerBound, length: 64)
        let songFlags = f[main.lowerBound + 64], speed = f[main.lowerBound + 66], tempo = f[main.lowerBound + 67]
        let globalVolume = f[main.lowerBound + 72]
        let channelCount = min(channels, MAX_HOST_CHANNELS)
        var pans = [UInt8](repeating: 32 | 128, count: MAX_HOST_CHANNELS)
        for channel in 0 ..< channelCount {
            // Of 128 in the newer kind and of 64 in the older; beyond is a channel that is not heard.
            let pan = f[main.lowerBound + 73 + channel]
            if isAM {
                pans[channel] = pan > 128 ? 32 | 128 : (pan + 1) / 2
            } else {
                pans[channel] = pan >= 128 ? 32 | 128 : min(pan, 64)
            }
        }

        var orders: [UInt8] = []
        if let list = first("ORDR"), !list.isEmpty {
            let count = Int(f[list.lowerBound]) + 1
            for i in 0 ..< count where list.lowerBound + 1 + i < list.upperBound {
                orders.append(f[list.lowerBound + 1 + i])
            }
        }

        // MARK: Patterns

        var leftOut = Shortfall.Kinds()
        var packed = [[UInt8]?](repeating: nil, count: IT2ForeignModule.patternRoom)
        var rowCounts = [UInt16](repeating: 64, count: IT2ForeignModule.patternRoom)
        var highest = -1
        // (The instruments the patterns play, and those the file has: for a file cut short, which it
        // has lost.)
        var played = Set<Int>(), made = Set<Int>()
        for part in all("PATT") {
            let number = Int(f[part.lowerBound])
            let size = long(f, part.lowerBound + 1)
            let start = min(part.lowerBound + 5, part.upperBound), end = min(part.upperBound, start + size)
            highest = max(highest, number)
            // (A pattern given twice is the first; one beyond the replayer's room cannot be played.)
            guard number < IT2ForeignModule.patternRoom, packed[number] == nil, start < end else { continue }
            let rows = Int(f[start]) + 1
            var pattern = IT2ForeignModule.Pattern(rows: rows)
            var at = start + 1, row = 0
            while row < rows, at < end {
                let what = f[at]
                at += 1
                if what == 0 {
                    row += 1
                    continue
                }
                guard what & 0xE0 != 0 else { continue }
                let channel = min(Int(what & 0x1F), channelCount - 1)
                var cell = pattern[row, channel]
                var volumeCommand = false
                if what & 0x80 != 0 {
                    let value = f[at], command = f[at + 1]
                    at += 2
                    let effect = Effect(rawValue: Int(command))
                    put(effect, value, in: &cell, leftOut: &leftOut)
                    volumeCommand = effect == .volume
                }
                if what & 0x40 != 0 {
                    let instrument = f[at], note = f[at + 1]
                    at += 2
                    // (A note in the cell before goes, whether or not this is one.)
                    cell.mask &= ~1
                    cell.note = 0
                    cell.mask &= ~2
                    cell.instrument = 0
                    if instrument != 0, Int(instrument) <= IT2Module.mostInstruments {
                        cell.set(instrument: instrument)
                        played.insert(Int(instrument))
                    }
                    // From 1 for the lowest C, as OpenMPT numbers them; 128 lets the key go, and above that
                    // the note fades.
                    if note >= 1, note <= 120 { cell.set(note: note - 1) } else if note == 0x80 { cell.set(note: 255) } else if note > 0x80 { cell.set(note: 246) }
                }
                if what & 0x20 != 0 {
                    let volume = f[at]
                    at += 1
                    if !volumeCommand { cell.set(volume: min(64, isAM ? UInt8(Int(volume) * 64 / 127) : volume)) }
                }
                pattern[row, channel] = cell
            }
            packed[number] = pattern.packed()
            rowCounts[number] = UInt16(rows)
        }
        // A pattern the list names that the file does not have is passed over; one below the
        // highest it has is empty. (In a file cut short, those it has lost are empty too.)
        var patternsLost = false
        if cut {
            for order in orders where order < 254 && Int(order) < packed.count && packed[Int(order)] == nil && Int(order) >= max(highest, 0) {
                packed[Int(order)] = IT2ForeignModule.Pattern().packed()
                patternsLost = true
            }
        }
        for number in 0 ..< min(max(highest, 0), IT2ForeignModule.patternRoom) where packed[number] == nil {
            packed[number] = IT2ForeignModule.Pattern().packed()
        }
        orders = orders.map { $0 >= 254 || (Int($0) < packed.count && packed[Int($0)] != nil) ? $0 : 254 }

        // MARK: Instruments and samples

        var instruments = (0 ..< IT2Module.mostInstruments).map { _ in IT2Instrument() }
        var samples: [IT2Sample] = []
        var instrumentCount = 0
        var cutShort = Shortfall.CutShort()
        var tooMany = false
        /// A sample from the bytes of its sound, of eight bits or sixteen, as much as there is. (A
        /// sample the file ends before the end of is cut short there; OpenMPT keeps its length, and
        /// silence after.)
        func sound(_ range: Range<Int>, frames said: Int, sixteen: Bool) -> (sound8: [Int8], sound16: [Int16]) {
            cutShort.add(length: sixteen ? said * 2 : said, there: range.count)
            let frames = min(said, sixteen ? range.count / 2 : range.count)
            if sixteen {
                var made = [Int16](repeating: 0, count: frames)
                for i in 0 ..< min(frames, range.count / 2) { made[i] = Int16(truncatingIfNeeded: f.u16le(range.lowerBound + i * 2)) }
                return ([], made)
            }
            var made = [Int8](repeating: 0, count: frames)
            for i in 0 ..< min(frames, range.count) { made[i] = Int8(bitPattern: data[range.lowerBound + i]) }
            return (made, [])
        }
        /// A sample as the replayer has one, from its header's numbers, with its instrument's vibrato.
        func sample(sound: (sound8: [Int8], sound16: [Int16]), volume: Int, pan: Int, flags: Int, loopStart: Int, loopEnd: Int,
                    rate: Int, vibrato: (type: Int, sweep: Int, depth: Int, rate: Int)) -> IT2Sample {
            // (A sample that says it has no rate has 8,363 Hz, as OpenMPT gives it.)
            let s = IT2ForeignModule.sample(sound8: sound.sound8, sound16: sound.sound16, volume: UInt8(min(256, volume) / 4), rate: UInt32(rate > 0 ? rate : 8363),
                                            loops: flags & 0x08 != 0, backAndForth: flags & 0x10 != 0, loopStart: loopStart, loopEnd: loopEnd,
                                            pan: flags & 0x20 != 0 ? UInt8(min(256, pan) / 4) : nil)
            // Sine, square, ramp up, ramp down, random: Impulse Tracker's has the ramps one way only,
            // and its own numbers; the speed in 16ths, the depth in quarters, and the sweep as a
            // count up, where FastTracker's was a count down.
            let waves: [UInt8] = [0, 2, 1, 1, 3]
            if vibrato.type < waves.count { s.AutoVibratoWaveform = waves[vibrato.type] }
            s.AutoVibratoSpeed = UInt8(min(255, vibrato.rate / 16))
            s.AutoVibratoDepth = UInt8(min(255, vibrato.depth / 4))
            s.AutoVibratoRate = UInt8(truncatingIfNeeded: vibrato.sweep)
            if s.AutoVibratoSpeed | s.AutoVibratoDepth != 0 { s.AutoVibratoRate = 255 &- s.AutoVibratoRate }
            return s
        }
        /// An envelope of the instrument's: its points (a tick and a level of 64), how many of them
        /// there are, where it holds and where its loop is, and whether it is on, holds or loops.
        func envelope(_ points: [(tick: Int, level: Int)], sustain: Int, loopStart: Int, loopEnd: Int, flags: Int, centre: Int) -> IT2Envelope {
            var made = IT2Envelope()
            guard !points.isEmpty else { return made }
            made.Num = UInt8(points.count)
            var last = -1
            for (i, point) in points.enumerated() {
                var tick = point.tick >> 4
                if i == 0 { tick = 0 } else if tick < last { tick = last + 1 }
                last = tick
                made.Tick[i] = UInt16(min(tick, 0xFFFF))
                made.Magnitude[i] = Int8(max(0, min(64, point.level)) - centre)
            }
            let lastPoint = points.count - 1
            if flags & 1 != 0 { made.Flags |= ENVF_ENABLED }
            if flags & 2 != 0, sustain <= points.count {
                made.Flags |= ENVF_SUSTAINLOOP
                made.SustainLoopBegin = UInt8(min(sustain, lastPoint))
                made.SustainLoopEnd = made.SustainLoopBegin
            }
            if flags & 4 != 0, loopStart <= loopEnd, loopStart <= points.count {
                made.Flags |= ENVF_LOOP
                made.LoopBegin = UInt8(min(loopStart, lastPoint))
                made.LoopEnd = UInt8(min(loopEnd, lastPoint))
            }
            return made
        }
        /// A new instrument, numbered from 1, which takes the place of one of the same number.
        func instrument(_ number: Int, map: [UInt8], base: Int, fade: Int) -> IT2Instrument {
            let ins = IT2Instrument()
            ins.NNA = 0
            ins.GlobVol = 128
            ins.DefPan = 32 | 128
            ins.PitchPanCenter = 60
            ins.FadeOut = UInt16(min(fade, 1024))
            for note in 0 ..< 120 {
                let sample = Int(map[note]) + base + 1
                ins.SmpNoteTable[note] = UInt16(note) | UInt16(sample <= IT2ForeignModule.sampleRoom ? sample : 0) << 8
            }
            instruments[number - 1] = ins
            instrumentCount = max(instrumentCount, number)
            made.insert(number)
            return ins
        }
        /// Room for one more sample.
        func room() -> Bool {
            if samples.count < IT2ForeignModule.sampleRoom { return true }
            tooMany = true
            return false
        }

        if isAM {
            for part in all("RIFF") where letters(f, part.lowerBound) == id("AI  ") {
                // An instrument, its header in a part of its own ("INST") that its samples follow,
                // each in a RIFF file of its own ("AS  "), in which its header and its sound are a
                // part ("SAMP").
                let at = part.lowerBound + 4
                guard at + 8 + 326 <= part.upperBound, letters(f, at) == id("INST") else { continue }
                let h = at + 8
                let number = Int(f[h + 5]) + 1
                guard number <= IT2Module.mostInstruments else { continue }
                let map = (0 ..< 120).map { f[h + 38 + $0] }
                let vibrato = (type: Int(f[h + 166]), sweep: f.u16le(h + 167), depth: f.u16le(h + 169), rate: f.u16le(h + 171))
                let envelopes = h + 180
                let ins = instrument(number, map: map, base: samples.count, fade: f.u16le(envelopes + 46))
                // The envelopes, of volume (0 to 32,767), pitch (-4,096 to 4,096) and place
                // (-32,768 to 32,767), each as so many levels of 64.
                for (which, (scale, offset)) in [(32767 / 64, 0), (8192 / 64, 4096), (65536 / 64, 32768)].enumerated() {
                    let e = envelopes + which * 48
                    let count = Int(f[e + 2])
                    guard count != 0xFF, count != 0 else { continue }
                    let points = (0 ..< min(count + 1, 10)).map { i -> (tick: Int, level: Int) in
                        let value = Int(Int16(truncatingIfNeeded: f.u16le(e + 6 + i * 4 + 2))) + offset
                        return (f.u16le(e + 6 + i * 4), (value + scale / 2) / scale)
                    }
                    let made = envelope(points, sustain: Int(f[e + 3]), loopStart: Int(f[e + 4]), loopEnd: Int(f[e + 5]), flags: f.u16le(e), centre: which == 0 ? 0 : 32)
                    if which == 0 { ins.VolEnv = made } else if which == 1 { ins.PitchEnv = made } else { ins.PanEnv = made }
                }
                var samplesLeft = f.u16le(h + 324)
                if samplesLeft == 0 { ins.SmpNoteTable = (0 ..< 120).map { UInt16($0) } }
                for sampleFile in chunks(f, from: h + 326, to: part.upperBound, even: true) where sampleFile.id == id("RIFF") {
                    guard letters(f, sampleFile.data.lowerBound) == id("AS  "), room() else { continue }
                    if samplesLeft == 0 { break }
                    samplesLeft -= 1
                    // (Its number is taken, whatever comes of it.)
                    samples.append(IT2Sample())
                    let s = sampleFile.data.lowerBound + 4
                    // (In a file cut short, a sample whose header is not all there is missing, and
                    // so are those of the instrument's that come after it.)
                    guard s + 8 <= sampleFile.data.upperBound, letters(f, s) == id("SAMP") else {
                        if cut { cutShort.addMissing() }
                        break
                    }
                    let end = min(sampleFile.data.upperBound, s + 8 + long(f, s + 4))
                    let header = s + 8
                    guard header + 60 <= end else {
                        if cut { cutShort.addMissing() }
                        break
                    }
                    let flags = f.u16le(header + 40), frames = long(f, header + 44)
                    let start = min(end, header + long(f, header) + 4)
                    let sixteen = flags & 0x04 != 0
                    samples[samples.count - 1] = sample(sound: sound(start ..< end, frames: min(frames, 1 << 24), sixteen: sixteen),
                                                        volume: min(f.u16le(header + 38), 32767) * 256 / 32767, pan: min(f.u16le(header + 36), 32767) * 256 / 32767,
                                                        flags: flags, loopStart: long(f, header + 48), loopEnd: long(f, header + 52),
                                                        rate: long(f, header + 56), vibrato: vibrato)
                }
                if cut { for _ in 0 ..< samplesLeft { cutShort.addMissing() } }
            }
        } else {
            for part in all("INST") {
                // An instrument, its header and then each of its samples' header and sound.
                guard part.count >= 225 else { continue }
                let h = part.lowerBound
                let number = Int(f[h + 1]) + 1
                guard number <= IT2Module.mostInstruments else { continue }
                let map = (0 ..< 120).map { f[h + 31 + $0] }
                let vibrato = (type: Int(f[h + 151]), sweep: f.u16le(h + 152), depth: f.u16le(h + 154), rate: f.u16le(h + 156))
                let ins = instrument(number, map: map, base: samples.count, fade: f.u16le(h + 223))
                // The envelopes: of volume in the low half of each byte, of place in the high.
                let e = h + 158
                for which in 0 ..< 2 {
                    func half(_ byte: UInt8) -> Int { Int(which == 0 ? byte & 0x0F : byte >> 4) }
                    let count = min(half(f[e + 1]), 10)
                    let points = (0 ..< count).map { i in (tick: f.u16le(e + 5 + which * 30 + i * 3), level: Int(f[e + 5 + which * 30 + i * 3 + 2])) }
                    let made = envelope(points, sustain: half(f[e + 2]), loopStart: half(f[e + 3]), loopEnd: half(f[e + 4]), flags: half(f[e]), centre: which == 0 ? 0 : 32)
                    if which == 0 { ins.VolEnv = made } else { ins.PanEnv = made }
                }
                var at = h + 225
                for _ in 0 ..< Int(f[h + 30]) {
                    guard room(), at + 64 <= part.upperBound else {
                        // (In a file cut short, one whose header is not there is missing.)
                        if cut, at + 64 > part.upperBound { cutShort.addMissing() }
                        continue
                    }
                    let header = at
                    at += 64
                    samples.append(IT2Sample())
                    guard letters(f, header) == id("SAMP") else { continue }
                    let flags = f.u16le(header + 38), frames = min(long(f, header + 40), 1 << 24)
                    let sixteen = flags & 0x04 != 0
                    let bytes = sixteen ? frames * 2 : frames
                    let start = at
                    at = min(part.upperBound, at + bytes)
                    samples[samples.count - 1] = sample(sound: sound(start ..< at, frames: frames, sixteen: sixteen), volume: Int(f[header + 37]) * 4,
                                                        pan: Int(f[header + 36]) * 4, flags: flags, loopStart: long(f, header + 44),
                                                        loopEnd: long(f, header + 48), rate: long(f, header + 52), vibrato: vibrato)
                }
            }
        }
        while samples.count < IT2ForeignModule.sampleRoom { samples.append(IT2Sample()) }

        var shortfalls: [String] = []
        if let sentence = Shortfall.commandsLeftOut(leftOut.named(leftOutNames)) { shortfalls.append(sentence) }
        if tooMany { shortfalls.append("It has more samples than there is room for, and the last are left out.") }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }
        if cut {
            // (What it has lost of its instruments and patterns, which is all of those after the
            // place where it ends, is silent and empty.)
            let lost = played.count { !made.contains($0) }
            let instrumentsLost = Shortfall.instrumentsLost(lost, damaged: false, samplesToo: cutShort.sentence != nil)
            if let instrumentsLost { shortfalls.append(instrumentsLost) }
            if patternsLost { shortfalls.append(Shortfall.patternsLost(samplesToo: cutShort.sentence != nil || instrumentsLost != nil)) }
        }

        // MARK: The rest

        var song = OpenMPTSong()
        var sequence = OpenMPTSong.Sequence()
        sequence.count = orders.count
        sequence.speed = max(1, speed)
        sequence.tempo = max(OpenMPTSong.leastTempo, Int(tempo)) * OpenMPTSong.tempoUnit
        song.sequences = [sequence]
        song.patternRowsPerBeat = [UInt16](repeating: 0, count: IT2ForeignModule.patternRoom)
        song.patternSwing = [[UInt32]](repeating: [], count: IT2ForeignModule.patternRoom)
        // OpenMPT plays these files with every one of Impulse Tracker's ways that it plays an IT
        // file with.
        song.offsetAsImpulseTracker = true
        song.loopsOutlastJumps = false
        song.unmappedNotesKeepCommands = false

        let flags = ITF_STEREO | ITF_INSTR_MODE | ITF_OLD_EFFECTS | ITF_COMPAT_GXX | (songFlags & 1 == 0 ? ITF_LINEAR_FRQ : 0)
        let module = IT2Module(title: title, madeWith: "Galaxy Sound System", orders: orders, flags: flags, globalVolume: min(globalVolume, 128),
                               mixVolume: mixVolume, speed: max(1, speed), tempo: tempo, channelPans: pans, samples: samples, patterns: packed,
                               rows: rowCounts, instruments: Array(instruments[0 ..< max(1, instrumentCount)]), openMPT: song)
        module.playsAsGalaxy = true
        return try ITRenderer(module: module, format: "J2B", shortfalls: shortfalls, options: options)
    }

    /// How loud the whole is made, of Impulse Tracker's 128: set by measure, so that these files are
    /// about as loud as other modules are. (OpenMPT plays them a little louder.)
    private static let mixVolume: UInt8 = 42
}
