// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from pt2-clone, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

import SidayChips
import SidayFoundation

/// A four-channel Amiga module, read into the shape ProTracker keeps one in: up to a hundred patterns
/// of 64 rows, and 31 samples, each with 64 KB of memory to itself. (A file with a sample longer
/// than that, which is not ProTracker's but which the Amiga can play, has twice the memory for each.)
///
/// Files with 31 samples say which tracker they are from in four letters; the oldest files, with 15
/// samples, say nothing and are told by their shape. What trackers other than ProTracker meant by a
/// few of the effects is turned into what ProTracker means by them here, once, as the file is read.
final class ProTrackerModule {
    enum Kind {
        case proTracker, startrekker, fastTracker, noiseTracker, hisMastersNoise
        /// The Ultimate Soundtracker and its descendants: 15 samples and no four letters.
        case soundtracker

        var name: String {
            switch self {
            case .proTracker: "ProTracker"
            case .startrekker: "Startrekker"
            case .fastTracker: "FastTracker"
            case .noiseTracker: "NoiseTracker"
            case .hisMastersNoise: "His Master's NoiseTracker"
            case .soundtracker: "Soundtracker"
            }
        }
    }

    struct Note {
        var period: UInt16 = 0
        var sample: UInt8 = 0
        var command: UInt8 = 0
        var parameter: UInt8 = 0
    }

    struct Sample {
        var name = ""
        var volume: Int8 = 0
        var fineTune: UInt8 = 0
        /// Where its memory begins, and how much of it is sample: all in bytes.
        var offset = 0
        var length = 0
        var loopStart = 0
        var loopLength = 2
    }

    static let rows = 64
    static let channels = 4
    static let mostPatterns = 100
    /// Why a module of Startrekker's is not played whose sound is all in the synthesised instruments
    /// of the file beside it, which it was not given: the loader, which knows the module's name,
    /// says which file that is (`Companions`).
    static let synthesisedInstrumentsWanted = TuneError.missingCompanion("its synthesised instruments")
    /// The longest a sample of ProTracker's can be, and the longest that a file can say one is: the
    /// most the Amiga's sound chip can be told to play.
    static let proTrackersSpace = 65534, mostSpace = 131_070
    /// The memory each sample has, which is also the longest a sample can be: ProTracker's 64 KB,
    /// unless the file has a sample longer than that, and it is not being read as ProTracker reads it.
    let sampleSpace: Int
    /// True if the file has a sample longer than ProTracker has room for.
    let hasLongSamples: Bool
    /// After the samples' memory: silence, for a voice with nothing to play.
    var silence: Int { (31 + 2) * sampleSpace }
    var memorySize: Int { silence + 0xFFFF * 2 }

    let kind: Kind
    /// How many of the four channels the file has notes for.
    let channelCount: Int
    let title: String
    private(set) var samples = [Sample](repeating: Sample(), count: 31)
    let songLength: Int
    /// Where in the order the song begins again when it comes to its end: the start, but for a module of
    /// Startrekker's, NoiseTracker's or His Master's Noise's, whose players go to the place the module
    /// names (ProTracker's does not). NoiseTracker V1.1's and V2.0's replays take it from the byte after
    /// the song's length (`move.b $3b7(a0),mt_songpos`), as NoiseTracker 2.0 does itself (its music
    /// routine `L505_2`, `MOVE.B $3B7(A0),D0`), and His Master's Noise's player (Wanted Team's
    /// `NoiseTracker_v4.asm`, after `lbC024730`).
    let restartPosition: Int
    private(set) var orders = [UInt8](repeating: 0, count: 128)
    /// 125 but for a few of the oldest files, which give a tempo of their own.
    let initialTempo: Int
    /// For a module of the Soundtrackers that set a timer from the tempo the file gives, when that is
    /// not 120: the count the timer was given, (240 - tempo) * 122, of the E clock's 709,379 a second.
    /// Karsten Obarski's replay version 27 (29.03.1988, as UADE has it in `EP_Ultimate_ST.s`,
    /// "initialize timer irq") works it out so from the byte at 471. Ultimate Soundtracker 1.8 brought
    /// it in ("CIA/BPM Speed adjust appears", in the cmatsuoka/tracker-history notes) and D.O.C.'s
    /// Soundtracker IX took it up again ("CIA/BPM Speed back in it"). The timer fires once each count
    /// and one more of the E clock, five of Paula's (UADE's `cia.c`, `CIA_update`: `(ciaata+1) ==
    /// ciaclocks`), as ProTracker's does (see `ProTrackerReplayer.ticksPerSecond`). Nil for any other.
    let timerCount: Int?
    /// True for a module of a tracker whose replay ran once each frame of a PAL Amiga's display, 49.92
    /// times a second, and had no tempo: NoiseTracker's, His Master's Noise's, and the Soundtrackers'
    /// whose files give the usual tempo of 120. Its ticks are frames, not ProTracker's timer at 125.
    ///
    /// NoiseTracker 2.0's own source says so: its level 3 handler (`L509`, put at $6C) runs the music
    /// (`BSR L505_2`) when the interrupt is the vertical blank's (`BTST #$5,D1`), and its clock
    /// (`TIMER`) counts fifty of those a second and one more each 596, as a display of 49.92 frames a
    /// second needs. Its replays were to be called the same way: NoiseTracker V1.0's and V1.1's
    /// documents, "call ... "mt_music" every frame", "This replay-routine is not interrupt-driven";
    /// V2.0's NormalReplay sets no timer and has only a speed (`mt_setspeed`). His Master's Noise's
    /// replay was called "4 times per frame", and played the tune on one call of the four (Wanted
    /// Team's player of it, `NoiseTracker_v4.asm`, `Interrupt`). ProTracker was the first of the
    /// family whose replay was "not raster dependant" (Exotica's Soundtracker history, ProTracker
    /// 1.00), and its tempo of 125 is "normal vblank speed" (ProTracker 2.0's `PT.ReadMe!`).
    ///
    /// The first Soundtracker ran on the frame too, and had no tempo: Karsten Obarski's "Muzak
    /// Replay-Routine Version 1.2 (.23)" of 8/1987 puts its own handler at $6C (`move.l
    /// #frameirq,$6c`), which plays the music on the vertical blank (`lev3vb`, `btst #5,d1`), six
    /// frames to a row; SoundTracker V1.0's instructions say to "call the routine 'mt_music' once
    /// every vertical blanking interrupt". The Soundtrackers made from it that did not take up
    /// Ultimate Soundtracker 1.8's timer (The Jungle Command's, D.O.C.'s II to VI and 2.x, Master
    /// Soundtracker) ran on the frame and kept the tempo at 120 (Warren Willmey's notes to the Weasel
    /// Audio Library; Fraggie's table, which OpenMPT's `Load_stk.cpp` follows). A file of those that
    /// set a timer (see `timerCount`) at 120 cannot be told from the others, and is played on the
    /// frame with them.
    let ticksOnTheFrame: Bool
    let patterns: UnsafeMutablePointer<Note>
    let memory: UnsafeMutablePointer<Int8>
    /// What gives `patterns` and `memory` back, also for a file that turns out not to be a module.
    private let patternSpace: Memory<Note>, sampleMemory: Memory<Int8>
    /// What the file asks for that is not played as it asks: see `TuneInfo.shortfalls`.
    private(set) var shortfalls: [String] = []
    /// Startrekker's synthesised instruments, for a module of Startrekker's given the file of them
    /// that it kept beside the module; nil if there are none.
    let synth: StartrekkerSynth?
    /// Where in memory the synthesised instruments' waveforms are: in the room after the samples'.
    var waveforms: Int { 31 * sampleSpace }

    private let file: ByteReader
    /// Where in the file each sample's bytes are, and how many of them were taken.
    private var sources = [(from: Int, count: Int)](repeating: (0, 0), count: 31)

    /// A name as the tracker shows it: what is not plain text is a space, and so is a gap in the middle.
    private static func text(_ file: ByteReader, at start: Int, length: Int) -> String {
        var last = length - 1
        while last >= 0, file[start + last] == 0 { last -= 1 }
        var scalars = String.UnicodeScalarView()
        for i in stride(from: 0, through: last, by: 1) {
            let byte = file[start + i]
            scalars.append(Unicode.Scalar(byte >= 0x20 && byte <= 0x7E ? byte : 0x20))
        }
        return String(scalars).trimmed()
    }

    @inline(__always) func note(pattern: Int, row: Int, channel: Int) -> Note {
        patterns[(pattern * Self.rows + row) * Self.channels + channel]
    }

    /// True if a file has four letters where a module of 31 samples says which tracker it is from (any
    /// four letters: those of a tracker this player does not know too). One of 15 samples has notes there.
    static func saysWhatItIs(_ data: [UInt8]) -> Bool {
        guard data.count >= 1084 + 1024 else { return false }
        return data[1080 ..< 1084].allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    /// - Parameters:
    ///   - asProTracker: true to cut a sample that is longer than ProTracker has room for off at
    ///     64 KB, as ProTracker does. Such a file is some other tracker's, made to be played by the
    ///     Amiga's routines, which play the whole of it, or by a player on another machine.
    ///   - synthesised: for a module of Startrekker's, the file beside it of its synthesised
    ///     instruments (see `StartrekkerSynth`), if it has one.
    init(_ data: [UInt8], asProTracker: Bool = false, synthesised: [UInt8]? = nil) throws {
        let file = ByteReader(data)
        self.file = file
        let size = data.count

        // An IFF file, which says how long it is and what kind of thing it holds, is not a module.
        if size >= 12, data.starts(with: Array("FORM".utf8)), file.u32be(4) + 8 == size, (8 ..< 12).allSatisfy({ data[$0] >= 0x20 && data[$0] < 0x7F }) {
            throw TuneError.unsupported("an IFF file of a kind this player does not know (\(file.ascii(at: 8, length: 4)))")
        }

        // The four letters, if they are there, and what they say.
        var kind: Kind?
        var channelCount = 4
        if size >= 1084 + 1024 {
            let id = (file[1080], file[1081], file[1082], file[1083])
            func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
            func tag(_ text: StaticString) -> Bool {
                text.withUTF8Buffer { $0[0] == id.0 && $0[1] == id.1 && $0[2] == id.2 && $0[3] == id.3 }
            }
            if tag("M.K.") || tag("M!K!") || tag("NSMS") || tag("LARD") || tag("PATT") {
                kind = .proTracker
            } else if tag("FLT4") {
                kind = .startrekker
            } else if tag("N.T.") {
                kind = .noiseTracker
            } else if tag("M&K!") || tag("FEST") {
                kind = .hisMastersNoise
            } else if isDigit(id.0), id.1 == 0x43, id.2 == 0x48, id.3 == 0x4E { // "nCHN"
                kind = .fastTracker
                channelCount = Int(id.0) - 0x30
            } else if isDigit(id.0), isDigit(id.1), id.2 == 0x43, id.3 == 0x48 { // "nnCH"
                kind = .fastTracker
                channelCount = (Int(id.0) - 0x30) * 10 + Int(id.1) - 0x30
            } else if id.0 >= 0x20, id.0 < 0x7F, id.1 >= 0x20, id.1 < 0x7F, id.2 >= 0x20, id.2 < 0x7F, id.3 >= 0x20, id.3 < 0x7F {
                // Four letters of some other tracker's. A file with 15 samples has notes here, and
                // notes do not spell anything.
                throw TuneError.unsupported("a module of a kind this player does not know (\(file.ascii(at: 1080, length: 4)))")
            }
        } else if size >= 1084, [Array("M.K.".utf8), Array("M!K!".utf8), Array("FLT4".utf8), Array("N.T.".utf8), Array("M&K!".utf8)].contains(Array(data[1080 ..< 1084])) {
            // A module that says what it is, and ends before its first pattern does: its samples,
            // which follow its patterns, are all missing.
            throw Shortfall.nothingToHear
        }
        guard channelCount <= Self.channels else {
            throw TuneError.unsupported("a module of \(channelCount) channels: only those of four, the Amiga's, are played so far")
        }
        guard channelCount > 0 else { throw TuneError.malformed("a module of no channels") }
        let sampleCount = kind == nil ? 15 : 31
        self.kind = kind ?? .soundtracker
        // (Only a module of Startrekker's own has them, as OpenMPT and ASREPLAY take it.)
        let instruments = kind == .startrekker ? synthesised.flatMap { StartrekkerSynth($0) } : nil
        synth = instruments?.hasAny == true ? instruments : nil
        self.channelCount = channelCount

        // How long the file says its longest sample is.
        var longest = 0
        for i in 0 ..< sampleCount { longest = max(longest, file.u16be(20 + i * 30 + 22) * 2) }
        hasLongSamples = longest > Self.proTrackersSpace
        let space = hasLongSamples && !asProTracker ? Self.mostSpace : Self.proTrackersSpace
        sampleSpace = space
        let memorySize = (31 + 2) * space + 0xFFFF * 2

        patternSpace = Memory(capacity: Self.mostPatterns * Self.rows * Self.channels)
        patterns = patternSpace.pointer
        patterns.initialize(repeating: Note(), count: Self.mostPatterns * Self.rows * Self.channels)
        sampleMemory = Memory(capacity: memorySize)
        memory = sampleMemory.pointer
        memory.initialize(repeating: 0, count: memorySize)

        // The song's name: anything that is not plain text becomes a space.
        title = Self.text(file, at: 0, length: 20)

        var p = 20
        var realLengths = [Int](repeating: 0, count: 31)
        var veryLate = false, late = false
        for i in 0 ..< sampleCount {
            samples[i].name = Self.text(file, at: p, length: 22)
            p += 22
            realLengths[i] = file.u16be(p) * 2
            p += 2
            samples[i].length = min(realLengths[i], space)
            if kind == nil {
                // Only the later Soundtrackers could hold a sample of more than 9999 bytes.
                if samples[i].length > 9999 { late = true }
                p += 1
                samples[i].volume = Int8(bitPattern: file[p])
                p += 1
                // The first Soundtrackers counted the start of a loop in bytes, and its length in words.
                samples[i].loopStart = file.u16be(p)
                samples[i].loopLength = file.u16be(p + 2) * 2
                p += 4
            } else {
                samples[i].fineTune = file[p] & 0xF
                samples[i].volume = Int8(bitPattern: file[p + 1])
                p += 2
                samples[i].loopStart = file.u16be(p) * 2
                samples[i].loopLength = file.u16be(p + 2) * 2
                p += 4
                // Modules carried over carelessly from the early Soundtrackers have the loop's start doubled.
                if samples[i].loopLength > 2, samples[i].loopStart + samples[i].loopLength > samples[i].length,
                   samples[i].loopStart / 2 + samples[i].loopLength <= samples[i].length
                {
                    samples[i].loopStart /= 2
                }
            }
        }
        for i in 0 ..< 31 { samples[i].offset = space * i }

        var songLength = Int(file[p])
        p += 1
        var tempo = 125
        var timer: Int?
        var onTheFrame = kind == .noiseTracker || kind == .hisMastersNoise
        if kind == nil {
            guard songLength >= 1, songLength <= 128 else { throw TuneError.malformed("not a module") }
            var stated = Int(file[p])
            guard stated <= 220 else { throw TuneError.malformed("not a module") }
            // 120, or nothing, is the usual fifty ticks a second. (And one tune by Jesper Kyd gives a
            // tempo that is not meant.)
            if stated == 0 || title == "jjk55" { stated = 120 }
            onTheFrame = stated == 120
            if stated != 120 {
                timer = (240 - stated) * 122
                let hz = (Paula.clockHz / 5.0) / Double((240 - stated) * 122 + 1)
                tempo = Int(UInt16(hz * (125.0 / 50.0) + 0.5))
            }
        } else {
            // One copy of one well-known module says 129, and means 127.
            if kind == .proTracker, songLength == 129 { songLength = 127 }
            guard songLength >= 1, songLength <= 129 else { throw TuneError.malformed("not a module") }
        }
        var restart = kind == .startrekker || kind == .noiseTracker || kind == .hisMastersNoise ? Int(file[p]) : 0
        p += 1
        initialTempo = tempo
        ticksOnTheFrame = onTheFrame
        timerCount = timer

        var patternCount = 0
        for i in 0 ..< 128 {
            orders[i] = file[p + i]
            patternCount = max(patternCount, Int(orders[i]))
        }
        patternCount += 1
        p += 128
        // A module written by a tracker on the PC whose list of patterns has marks in it, as Scream
        // Tracker 3's, Impulse Tracker's and ModPlug Tracker's lists have: 254 a place that is passed
        // over, and 255 the end of the song. Such a file holds as many patterns as the rest of the
        // list names, and is played as those trackers play their lists. (ProTracker counts a module's
        // patterns by the highest number in its list, and would look for 255 of them.) Here the marks
        // are taken out of the list, and the places a jump goes to (B) counted again without them.
        var newPlaces: [Int]?
        let list = orders
        if list.prefix(songLength).contains(where: { $0 >= 254 }) {
            patternCount = 1 + (list.filter { $0 < 254 }.max().map(Int.init) ?? 0)
            var kept: [UInt8] = [], places = [Int](repeating: 0, count: 256)
            let end = list.prefix(songLength).firstIndex(of: 255) ?? songLength
            for i in 0 ..< 256 {
                // (A jump to a mark goes on to the next place that is a pattern; past the end, it ends the song.)
                places[i] = kept.count
                if i < end, list[i] != 254 { kept.append(list[i]) }
            }
            guard !kept.isEmpty else { throw TuneError.malformed("not a module") }
            for i in 0 ..< 128 { orders[i] = i < kept.count ? kept[i] : 0 }
            restart = places[restart]
            songLength = kept.count
            newPlaces = places
        }
        self.songLength = songLength
        restartPosition = restart < songLength ? restart : 0
        guard patternCount <= Self.mostPatterns else {
            // (A file with no four letters whose list names more patterns than the file could hold
            // has not got them: its list is noise, or it is no module. A tracker on the PC may still
            // read it, as it may one of more patterns.)
            if kind == nil, size < p + patternCount * 1024 { throw TuneError.unsupported("a module whose list of patterns names more than the file holds") }
            throw TuneError.unsupported("a module of more than a hundred patterns")
        }
        if kind != nil { p += 4 }
        // A file with no four letters is taken on trust by the tracker this is ported from. Here it must
        // at least be big enough to hold the patterns it speaks of, and its samples no louder than loud.
        if kind == nil {
            // Some, Jean Baudlot's for Bad Dudes and Castle Warrior, have numbers left in the order past
            // the song's end, of patterns the file does not hold: for them the patterns are those the
            // song plays, and the samples follow those.
            if size < p + patternCount * 1024 {
                patternCount = 1
                for i in 0 ..< songLength { patternCount = max(patternCount, Int(orders[i]) + 1) }
            }
            guard size >= p + patternCount * 1024 else { throw TuneError.malformed("not a module") }
            for i in 0 ..< 15 where UInt8(bitPattern: samples[i].volume) > 64 { throw TuneError.malformed("not a module") }
        }

        for pattern in 0 ..< patternCount {
            for row in 0 ..< Self.rows {
                for channel in 0 ..< channelCount {
                    var note = Note()
                    note.period = UInt16(file[p] & 0x0F) << 8 | UInt16(file[p + 1])
                    note.sample = (file[p] & 0xF0) | (file[p + 2] >> 4)
                    if kind == nil {
                        if note.sample > 31 { note.sample = 0 }
                    } else {
                        note.sample &= 31
                    }
                    note.command = file[p + 2] & 0x0F
                    note.parameter = file[p + 3]
                    p += 4
                    if kind == nil {
                        // What effects a Soundtracker module uses says which Soundtracker it is from.
                        if note.command == 0xC || note.command == 0xD || note.command == 0xE { late = true }
                        if note.command == 0xF {
                            late = true
                            veryLate = true
                        }
                    }
                    patterns[(pattern * Self.rows + row) * Self.channels + channel] = note
                }
            }
        }

        if let newPlaces {
            for i in 0 ..< patternCount * Self.rows * Self.channels where patterns[i].command == 0xB {
                patterns[i].parameter = UInt8(newPlaces[Int(patterns[i].parameter)])
            }
        }

        // What other trackers meant by an effect, in ProTracker's terms.
        if kind != .proTracker {
            for i in 0 ..< patternCount * Self.rows * Self.channels {
                var note = patterns[i]
                switch kind {
                case .noiseTracker, .hisMastersNoise:
                    // A pattern break always goes to the top of the next pattern.
                    if note.command == 0xD { note.parameter = 0 }
                    // There is no tempo, only a speed, of $1F at the most (NoiseTracker V1.1's and
                    // V2.0's `mt_setspeed`, NoiseTracker 2.0's own `L577_M`, and His Master's Noise's,
                    // `lbC024BA2` in Wanted Team's player of it).
                    if note.command == 0xF, note.parameter > 0x1F { note.parameter = 0x1F }
                    if note.command == 0xF, note.parameter == 0 {
                        if kind == .hisMastersNoise {
                            // A speed of nothing is a speed of one, to NoiseTracker 2.0 (`L577_N`,
                            // `MOVEQ #1,D0`; its NormalReplay's `mt_sp2`), which reads these files
                            // as its own, and to His Master's Noise's player (`lbC024BB0`).
                            note.parameter = 1
                        } else {
                            // And nothing to NoiseTracker V1.0 and V1.1 (`mt_setspeed`, `beq.s
                            // mt_rts2`); which tracker it was that wrote "N.T." is not known.
                            note.command = 0
                        }
                    }
                case .startrekker:
                    if note.command == 0xE {
                        note.command = 0
                        note.parameter = 0
                    }
                    // Startrekker has no tempo, only a speed, of 31 at the most; and a speed of nothing is
                    // the fastest, one, and does not stop the song, as it does in ProTracker (the tunes that
                    // have it use it so, for a row or two).
                    if note.command == 0xF, note.parameter > 0x1F { note.parameter = 0x1F }
                    if note.command == 0xF, note.parameter == 0 { note.parameter = 1 }
                case nil:
                    if !late {
                        // The first Soundtracker: 1 is an arpeggio, and 2 slides the pitch either way.
                        if note.command == 1 {
                            note.command = 0
                        } else if note.command == 2 {
                            if note.parameter & 0xF0 != 0 {
                                note.parameter >>= 4
                            } else if note.parameter & 0x0F != 0 {
                                note.command = 1
                            }
                        }
                    } else if note.command == 0xD {
                        if veryLate {
                            note.parameter = 0
                        } else {
                            note.command = 0xA
                        }
                    }
                    // A Soundtracker that ran on the frame had no tempo, and took a speed from the
                    // command's last figure only (the SoundTracker V4.0 playroutine of Obarski, The
                    // Exterminator, Il Scuro and D.O.C., as UADE has it: `and.l #$f,d0`, `move.l
                    // d0,mt_tempo`; OpenMPT's `Load_stk.cpp`). (A last figure of nothing would stop its
                    // rows, which wait for their count to come to it; it is nothing here, as F00 is.)
                    if note.command == 0xF, note.parameter >= 0x10, onTheFrame { note.parameter &= 0x0F }
                    if note.command == 0xF, note.parameter == 0 { note.command = 0 }
                default:
                    break
                }
                // Two effects that rewrite the samples as they play are ProTracker's alone.
                if note.command == 0xE, note.parameter >> 4 == 0x8 || note.parameter >> 4 == 0xF {
                    note.command = 0
                    note.parameter = 0
                }
                patterns[i] = note
            }
        }

        // Where the samples are in the file.
        var cutShort = Shortfall.CutShort()
        var used = [Bool](repeating: false, count: 32)
        for i in 0 ..< patternCount * Self.rows * Self.channels { used[Int(patterns[i].sample & 31)] = true }
        var tooLong = 0
        for i in 0 ..< sampleCount {
            var skip = 0
            if kind == nil {
                // The first Soundtrackers played only the loop of a sample that had one, and nothing
                // of what came after it.
                if samples[i].loopStart > 0, samples[i].loopLength < samples[i].length, samples[i].loopStart < samples[i].length {
                    samples[i].length -= samples[i].loopStart
                    p += samples[i].loopStart
                    samples[i].loopStart = 0
                }
                if realLengths[i] > space { skip = realLengths[i] - space }
                let loopEnd = samples[i].loopStart + samples[i].loopLength
                if loopEnd > 2, samples[i].length > loopEnd {
                    skip += samples[i].length - loopEnd
                    samples[i].length = loopEnd
                }
            } else if realLengths[i] > space {
                skip = realLengths[i] - space
            }
            sources[i] = (p, samples[i].length)
            cutShort.add(length: samples[i].length, there: size - p)
            if realLengths[i] > space, used[i + 1] { tooLong += 1 }
            p += samples[i].length + skip
        }
        if tooLong > 0 {
            shortfalls.append(Shortfall.some(tooLong, one: "samples is longer than ProTracker has room for, and is cut off at 64 KB.",
                                             many: "samples are longer than ProTracker has room for, and are cut off at 64 KB."))
        }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }
        // Startrekker kept its synthesised instruments in a file of their own beside the module (its
        // `.nt`), and left their samples empty in it: a module of Startrekker's that plays more than
        // one empty sample is taken to have them, as OpenMPT takes it (`Load_mod.cpp`), unless it is
        // given the file.
        if self.kind == .startrekker, instruments == nil, (0 ..< 31).count(where: { used[$0 + 1] && samples[$0].length == 0 }) > 1 {
            shortfalls.append("Its synthesised instruments, which Startrekker kept in a file beside it (.nt), are not played.")
        }

        // And the samples made safe to play.
        for i in 0 ..< 31 {
            if samples[i].length > space { samples[i].length = space }
            if UInt8(bitPattern: samples[i].volume) > 64 { samples[i].volume = 64 }
            if samples[i].loopLength < 2 { samples[i].loopLength = 2 }
            if samples[i].loopStart > space || samples[i].loopStart + samples[i].loopLength > space {
                samples[i].loopStart = 0
                samples[i].loopLength = 2
            }
            // A loop that runs past the end of its sample is given the room, where there is room.
            if samples[i].length > 0, samples[i].loopLength > 2, samples[i].loopStart + samples[i].loopLength > samples[i].length {
                let over = samples[i].loopStart + samples[i].loopLength - samples[i].length
                if samples[i].length + over <= space {
                    samples[i].length += over
                } else {
                    samples[i].loopStart = 0
                    samples[i].loopLength = 2
                }
            }
        }
        restoreSamples()
        // A module with no sample that has a sound and no synthesised instrument has nothing to be
        // heard by, whether its samples are missing or silent. (But for one of ProTracker's that
        // turns a loop over as it plays, EFx, which makes a sound of silence. And one of Startrekker's
        // that is taken to have synthesised instruments, as above, has them in the file beside it,
        // which is wanted.)
        let turnsLoopsOver = kind == .proTracker
            && (0 ..< patternCount * Self.rows * Self.channels).contains { patterns[$0].command == 0xE && patterns[$0].parameter > 0xF0 }
        // (Read as ProTracker reads it, for setting beside ProTracker, a module is what it is.)
        guard asProTracker || synth != nil || turnsLoopsOver || (0 ..< 31).contains(where: { Shortfall.sounds(memory + samples[$0].offset, count: samples[$0].length) }) else {
            if self.kind == .startrekker, instruments == nil, (0 ..< 31).count(where: { used[$0 + 1] && samples[$0].length == 0 }) > 1 {
                throw Self.synthesisedInstrumentsWanted
            }
            throw Shortfall.nothingToHear
        }
    }

    /// Puts the samples back as the file has them. Two of ProTracker's effects rewrite a sample while
    /// it plays, so a tune that has been played is not the tune that was loaded.
    func restoreSamples() {
        memory.update(repeating: 0, count: memorySize)
        for i in 0 ..< 31 {
            let (from, count) = sources[i]
            for k in 0 ..< count { memory[samples[i].offset + k] = Int8(bitPattern: file[from + k]) }
            // A sample that does not loop goes on to repeat its first two bytes for ever, which are
            // made silent so that it does not whine.
            if samples[i].length >= 2, samples[i].loopStart + samples[i].loopLength <= 2 {
                memory[samples[i].offset] = 0
                memory[samples[i].offset + 1] = 0
            }
        }
        if synth != nil { StartrekkerSynth.writeWaveforms(memory, at: waveforms) }
    }
}
