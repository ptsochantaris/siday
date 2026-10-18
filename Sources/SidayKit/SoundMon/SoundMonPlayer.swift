// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Brian Postma's replay routines of SoundMon 2.0 and 2.2, which he put into
// the public domain, as mld adapted them for UADE ("SoundMon 2.0 player module (Jul 2004)" and
// "SoundMon 2.2 player module (Jul 2004)", carried by UADE as players/SoundMon2.0 and
// players/SoundMon2.2, whose source UADE also carries as amigasrc/players/uade/soundmon/Soundmon2.0.s
// and Soundmon2.2.s). The addresses given are of those players' code hunks, 2.0's first and 2.2's
// after it where they differ.

/// Brian Postma's SoundMon, the tracker of synthesised sound in which Allister Brimble, Christian
/// Blaha and others wrote the music of games such as Alien Breed, Project-X, Frantic Freddie and
/// Dizzy's: a header of fifteen instruments, a list of steps each giving each of the four voices a
/// pattern of sixteen rows and transposes for its notes and instruments, the patterns, then
/// waveform tables of 64 bytes, then the samples. An instrument is a sample, or a synthesised sound
/// made of one of the tables: played as Paula's waveform, with an envelope of its volume (ADSR), a
/// vibrato (LFO), and an envelope (EG) that turns over the first part of the waveform, a byte at a
/// time; in 2.2 also a modulation (MOD) that rewrites one byte of it, and effects (FX) that smooth
/// it or bend it towards another.
///
/// A row is a note, an instrument and one of the options: 0 an arpeggio, 1 the volume, 2 the speed,
/// 3 the filter, 4 and 5 a slide of the period, 6 a count of repeats (2.0) or a vibrato (2.2), 7 a jump
/// in the steps (in 2.0, while the count lasts), 8 a slide on every tick, 9 an arpeggio on every tick,
/// 10 transposes left out; and in 2.2, 11 the effect, 13 to 15 a note held, its envelopes begun again.
///
/// This is the player itself, either of the two, as UADE runs it, tick by tick: a file marked "V.2"
/// is played by SoundMon 2.0's player and one marked "V.3" by SoundMon 2.2's, as UADE chooses them.
/// What it tells Paula is what that player tells her, and what it writes into the waveforms as they
/// play is what that player writes there. It runs fifty times a second, its row every sixth tick
/// unless the song sets another speed.
///
/// It owns the memory Paula plays from: the module, which the synthesised instruments rewrite, and
/// after it room into which a waveform past the module's may be written (and from which nothing is
/// played that was not), and then the silence a voice with nothing to play is pointed at. What of its
/// own the player reads past its tables (a note past its table of periods, a sample of an instrument
/// past fifteen) is what it would read there, as its variables were then (see `image(_:)`).
struct SoundMonPlayer: ~Copyable {
    /// Which of Brian Postma's players plays the module.
    enum Version {
        /// SoundMon 2.0's, for a module marked "V.2".
        case soundMon20
        /// SoundMon 2.2's, for one marked "V.3".
        case soundMon22

        var name: String { self == .soundMon20 ? "SoundMon 2.0" : "SoundMon 2.2" }
    }

    let version: Version
    /// The module and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// The room after the module that the player may write into, and where a voice with nothing to
    /// play is pointed: past it, where nothing is written (the players' own `null`, two bytes of
    /// nought, is in the player, not after the module).
    static let room = 0x20000
    var silenceAt: Int { fileSize + Self.room }
    /// Unused here, but kept as `PaulaTickRenderer` wants it.
    var mixingAt: Int { fileSize + Self.room }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// The module as it was, for the song begun again (the synthesised instruments rewrite it).
    private let original: [UInt8]
    /// The stretch of memory written since the song began, which is put back as it was.
    private var dirtyLow = Int.max, dirtyHigh = Int.min
    let title: String
    /// The filter the power light shows, as option 3 last set it (`PaulaTickRenderer` plays it).
    private(set) var lightFilter = false

    /// The length of the song in steps (the header's word at 30), how many waveform tables it has
    /// (its byte at 29), and where they are; and where each instrument's sample is (`samples`).
    private let steps: UInt16
    private let tableCount: UInt8
    private let tables: Int
    private let samples: InlineArray<15, Int>

    /// One voice, as the player keeps it (`bpcurrent`, 32 bytes each in 2.0 and 36 in 2.2), named by what
    /// its fields are; at the offsets of 2.0's, and 2.2's after them where they differ.
    struct Voice {
        /// The period (0), whose top bit marks a note to be begun at this row.
        var period: UInt16 = 0
        /// The volume the row gives it, $FF for the instrument's own (2), and the instrument (3).
        var volume: UInt8 = 0
        var instrument: UInt8 = 0
        /// Where Paula is told to play from on every tick, and how many words (4 and 8).
        var start = 0
        var length: UInt16 = 1
        /// The note, transposed (10); the arpeggio and auto-arpeggio, of two notes above it each
        /// (11, 13); the slide added to the period on every tick (12).
        var note: UInt8 = 0
        var arpeggio: UInt8 = 0
        var autoSlide: UInt8 = 0
        var autoArpeggio: UInt8 = 0
        /// Where each of the synthesised sound's tables is being read (14, 16, 18; 2.2's MOD, 20).
        var egAt: UInt16 = 0
        var lfoAt: UInt16 = 0
        var adsrAt: UInt16 = 0
        var modAt: UInt16 = 0
        /// The ticks before each next steps (20, 22, 24: words; in 2.2 bytes, 22 to 26, and FX's).
        var egCount: UInt16 = 0
        var lfoCount: UInt16 = 0
        var adsrCount: UInt16 = 0
        var modCount: UInt8 = 0
        var fxCount: UInt8 = 0
        /// Whether its instrument is synthesised (26; 27).
        var synthetic: UInt8 = 0
        /// How many of the waveform's first bytes the EG has turned over (28).
        var egValue: UInt8 = 0
        /// Whether each runs: nought not, 1 once, any other over and over (29 to 31; 2.2's MOD 32).
        var egControl: UInt8 = 0
        var lfoControl: UInt8 = 0
        var adsrControl: UInt8 = 0
        var modControl: UInt8 = 0
        /// 2.2's vibrato (34), and its effect (35).
        var vibrato: UInt8 = 0
        var fxControl: UInt8 = 0
    }

    private(set) var voices = InlineArray<4, Voice>(repeating: Voice())

    /// The waveform a voice's synthesised sound rewrites, and its first 32 bytes as they were, to be
    /// put back (`bpbuffer`, 36 bytes each). `nowhere` for none.
    private struct Kept {
        var at = SoundMonPlayer.nowhere
        var bytes = InlineArray<32, UInt8>(repeating: 0)
    }

    private var kept = InlineArray<4, Kept>(repeating: Kept())

    // The player's variables, named as its source names them.
    private var step: UInt16 = 0
    private var patternCount: UInt8 = 0
    private var stepTranspose: UInt8 = 0
    private var noteTranspose: UInt8 = 0
    private var count: UInt8 = 1
    private var delay: UInt8 = 6
    private var arpCount: UInt8 = 1
    private var repCount: UInt8 = 1
    private var nextStep: UInt16 = 0
    /// Which of 2.2's vibrato's eight values is next (`lfopointer`).
    private var lfoPointer = 0
    private var dma: UInt16 = 0
    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    /// The steps begun since the song last came to its end (see `endings`), and whether its end has
    /// been come to, to be counted as its next row is begun.
    private var played: [UInt16] = []
    private var ending = false
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// What an instrument past fifteen, or a pointer of the player's own, points at that is none of
    /// the module's: played as silence.
    static let nowhere = -0x4000_0000

    /// How long each tick is: the player is run by EaglePlayer's timer (it has an interrupt and does
    /// not start one of its own), which UADE's runs on a CIA's timer from $376B (see `GMCPlayer`):
    /// 70,940 of Paula's clocks, as UADE's ticks are apart.
    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// True for a file one of the players takes (`Chk`, $114 in both): the header's long at 26 shifted
    /// down a byte is "V.2" (2.0's) or "V.3" (2.2's).
    static func isOne(_ data: [UInt8]) -> Bool { version(of: data) != nil }

    static func version(of data: [UInt8]) -> Version? {
        guard data.count >= 30, data[26] == 0x56, data[27] == 0x2E else { return nil }
        switch data[28] {
        case 0x32: return .soundMon20
        case 0x33: return .soundMon22
        default: return nil
        }
    }

    /// Reads the module and starts its song (it has one: `song` is taken for that one, whatever it is).
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        let version = Self.version(of: data)
        self.version = version ?? .soundMon20
        fileSize = data.count
        original = data
        memoryCapacity = data.count + Self.room + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, byte) in data.enumerated() { memory[i] = byte }
        title = String(decoding: data.prefix(26).prefix { $0 != 0 }, as: UTF8.self)
        func byte(_ at: Int) -> UInt8 { at >= 0 && at < data.count ? data[at] : 0 }
        func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }

        // `bpinit` ($1BA): the number of tables (the byte at 29, for a module of the player's own
        // version), and the highest pattern of the steps, which the tables follow, counted as words
        // with a sign from 1, the steps read by an index of a word with a sign.
        steps = word(30)
        tableCount = byte(29)
        var highest: Int16 = 1
        var at: UInt16 = 512
        let times = Int((steps &* 4) &- 1) + 1
        for _ in 0 ..< times {
            highest = max(highest, Int16(bitPattern: word(Int(Int16(bitPattern: at)))))
            at &+= 4
        }
        let product = UInt32(UInt16(bitPattern: highest)) * 48
        var place = UInt32(512) &+ product &+ UInt32(steps << 4)
        tables = Int(place)
        place &+= UInt32(tableCount) << 6
        // The samples, each after the last but for a synthesised instrument, which has none. (2.0 adds
        // to its place a long word whose top half is what the highest pattern times 48 left there.)
        var samples = InlineArray<15, Int>(repeating: 0)
        for i in 0 ..< 15 {
            samples[i] = Int(place)
            let header = 32 + 32 * i
            if byte(header) != 0xFF {
                let bytes = UInt32(word(header + 24) &* 2)
                place &+= self.version == .soundMon20 ? bytes | (product & 0xFFFF_0000) : bytes
            }
        }
        self.samples = samples

        // (Refused only once it is all made, that it may be undone as a whole.)
        guard version != nil else { throw .malformed("not a SoundMon module") }

        start()
        // The song's length, from a playing of it in silence to its end.
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        start()
    }

    deinit { memory.deallocate() }

    /// The song from its beginning, as the player is when it is new and its `bpinit` ($1BA) has run;
    /// and the module as it was.
    private mutating func start() {
        lightFilter = false
        if dirtyLow <= dirtyHigh {
            for i in dirtyLow ... dirtyHigh { memory[i] = i < fileSize ? original[i] : 0 }
        }
        dirtyLow = .max
        dirtyHigh = .min
        voices = .init(repeating: Voice())
        for v in 0 ..< 4 { voices[v].start = silenceAt }
        kept = .init(repeating: Kept())
        step = 0
        patternCount = 0
        stepTranspose = 0
        noteTranspose = 0
        count = 1
        delay = 6
        arpCount = 1
        repCount = 1
        nextStep = 0
        lfoPointer = 0
        dma = 0
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        played.removeAll(keepingCapacity: true)
        ending = false
        endings = 0
    }

    // MARK: The memory

    @inline(__always) private func byte(_ at: Int) -> UInt8 {
        at >= 0 && at < memoryCapacity ? memory[at] : 0
    }

    private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }

    /// A byte written by the player: into the module or the room after it, and nowhere else.
    @inline(__always) private mutating func write(_ at: Int, _ value: UInt8) {
        guard at >= 0, at < silenceAt else { return }
        memory[at] = value
        dirtyLow = min(dirtyLow, at)
        dirtyHigh = max(dirtyHigh, at)
    }

    /// A field of instrument `n`'s header (32 bytes each, from 32), read by an index of a word, as the
    /// player reads it; which for an instrument past fifteen is what follows the headers.
    private func field(_ n: UInt8, _ offset: Int) -> UInt8 { byte(Int(n) * 32 + offset) }
    private func fieldWord(_ n: UInt8, _ offset: Int) -> UInt16 { word(Int(n) * 32 + offset) }

    /// Table `n` (64 bytes each), read at `at` by an index of a word with a sign.
    private func table(_ n: UInt8, _ at: UInt16) -> UInt8 {
        byte(tables + Int(n) * 64 + Int(Int16(bitPattern: at)))
    }

    // MARK: The player's own tables

    /// The periods of notes 1 to 48 (`bpper`), and of the 36 below them, before it.
    static let periodTable: [UInt16] = [
        6848, 6464, 6080, 5760, 5440, 5120, 4832, 4576, 4320, 4064, 3840, 3616,
        3424, 3232, 3040, 2880, 2720, 2560, 2416, 2288, 2160, 2032, 1920, 1808,
        1712, 1616, 1520, 1440, 1360, 1280, 1208, 1144, 1080, 1016, 960, 904,
        856, 808, 760, 720, 680, 640, 604, 572, 540, 508, 480, 452,
        428, 404, 380, 360, 340, 320, 302, 286, 270, 254, 240, 226,
        214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
        107, 101, 95, 90, 85, 80, 76, 72, 68, 64, 60, 57,
    ]

    /// 2.2's vibrato, in turn (`lfotable`).
    static let vibratoTable: [Int16] = [0, 64, 128, 64, 0, -64, -128, -64]

    /// The period of note `n` (a word with a sign), read as the player reads `bpper`, at its place less
    /// two plus twice the note. Past the table, what the player has there.
    private func period(ofNote n: Int) -> UInt16 {
        let offset = 2 * n - 2
        let index = offset / 2 + 36
        if offset >= -72, index < Self.periodTable.count { return Self.periodTable[index] }
        let at = layout.periods + offset
        return UInt16(image(at)) << 8 | UInt16(image(at + 1))
    }

    /// Where the player keeps its data, in its code hunk, and where UADE puts the hunk and the module:
    /// 2.0's `bpcurrent` at $876, `bpbuffer` $8F6, `bpper` $9CE, `samples` $A2E, `null` $A6A, its
    /// variables $A6C and `bpsong` $A82; 2.2's `null` at $AC4, `bpcurrent` $AC6, its variables $B56,
    /// `bpbuffer` $B7C, `bpper` $C54, `samples` $CB4 and `bpsong` $CF0. (UADE's register dumps show the
    /// hunk at $D008 and the module at $F000 for 2.0, $10000 for 2.2.)
    private struct Layout {
        var voices: Int, buffers: Int, periods: Int, samples: Int, null: Int, variables: Int, song: Int
        var voiceSize: Int
        var module: Int
    }

    private var layout: Layout {
        version == .soundMon20
            ? Layout(voices: 0x876, buffers: 0x8F6, periods: 0x9CE, samples: 0xA2E, null: 0xA6A, variables: 0xA6C,
                     song: 0xA82, voiceSize: 32, module: 0xF000)
            : Layout(voices: 0xAC6, buffers: 0xB7C, periods: 0xC54, samples: 0xCB4, null: 0xAC4, variables: 0xB56,
                     song: 0xCF0, voiceSize: 36, module: 0x10000)
    }

    private static let hunk = 0xD008

    /// A place in the memory as the Amiga's address, as UADE has it.
    private func address(_ at: Int) -> UInt32 {
        if at == silenceAt { return UInt32(Self.hunk + layout.null) }
        if at == Self.nowhere { return 0 }
        return UInt32(truncatingIfNeeded: layout.module + at)
    }

    /// The Amiga's address as a place in the memory: in the module or after it, or the player's own
    /// silence; or nowhere.
    private func place(_ address: UInt32) -> Int {
        let a = Int(address)
        if a == Self.hunk + layout.null { return silenceAt }
        if a >= layout.module, a < layout.module + silenceAt { return a - layout.module }
        return Self.nowhere
    }

    /// A byte of the player's data at `at` in its code hunk, as it is now: what the player reads past
    /// its tables. What is not data (its code, and past the hunk) is read as nought.
    private func image(_ at: Int) -> UInt8 {
        let l = layout
        func ofWord(_ value: UInt16, _ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: i == 0 ? value >> 8 : value) }
        func ofLong(_ value: UInt32, _ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: value >> (24 - 8 * i)) }
        if at >= l.voices, at < l.voices + 4 * l.voiceSize {
            let voice = voices[(at - l.voices) / l.voiceSize]
            let i = (at - l.voices) % l.voiceSize
            let v20 = version == .soundMon20
            switch i {
            case 0, 1: return ofWord(voice.period, i)
            case 2: return voice.volume
            case 3: return voice.instrument
            case 4 ..< 8: return ofLong(address(voice.start), i - 4)
            case 8, 9: return ofWord(voice.length, i - 8)
            case 10: return voice.note
            case 11: return voice.arpeggio
            case 12: return voice.autoSlide
            case 13: return voice.autoArpeggio
            case 14, 15: return ofWord(voice.egAt, i - 14)
            case 16, 17: return ofWord(voice.lfoAt, i - 16)
            case 18, 19: return ofWord(voice.adsrAt, i - 18)
            case 20, 21: return v20 ? ofWord(voice.egCount, i - 20) : ofWord(voice.modAt, i - 20)
            case 22, 23: return v20 ? ofWord(voice.lfoCount, i - 22)
                : UInt8(truncatingIfNeeded: i == 22 ? voice.egCount : voice.lfoCount)
            case 24, 25: return v20 ? ofWord(voice.adsrCount, i - 24)
                : i == 24 ? UInt8(truncatingIfNeeded: voice.adsrCount) : voice.modCount
            case 26: return v20 ? voice.synthetic : voice.fxCount
            case 27: return v20 ? 0 : voice.synthetic
            case 28: return voice.egValue
            case 29: return voice.egControl
            case 30: return voice.lfoControl
            case 31: return voice.adsrControl
            case 32: return voice.modControl
            case 34: return voice.vibrato
            case 35: return voice.fxControl
            default: return 0
            }
        }
        if at >= l.buffers, at < l.buffers + 4 * 36 {
            let buffer = kept[(at - l.buffers) / 36]
            let i = (at - l.buffers) % 36
            return i < 4 ? ofLong(address(buffer.at), i) : buffer.bytes[i - 4]
        }
        if at >= l.periods - 72, at < l.periods + 96 {
            return ofWord(Self.periodTable[(at - l.periods + 72) / 2], (at - l.periods) & 1)
        }
        if at >= l.samples, at < l.samples + 60 {
            return ofLong(address(samples[(at - l.samples) / 4]), (at - l.samples) % 4)
        }
        if at >= l.song, at < l.song + 4 { return ofLong(UInt32(l.module), at - l.song) }
        if at >= l.variables, at < l.variables + 32 {
            let i = at - l.variables
            if version == .soundMon20 {
                // `dma`, `tables`, `bpstep`, `most` ($8000), `nullpoint`, then a byte each: `st`, `tr`,
                // `bpcount`, `bpdelay`, `arpcount`, `numtables`, `bppatcount`, `bprepcount`.
                switch i {
                case 0, 1: return ofWord(dma, i)
                case 2 ..< 6: return ofLong(address(tables), i - 2)
                case 6, 7: return ofWord(step, i - 6)
                case 8: return 0x80
                case 10 ..< 14: return ofLong(address(silenceAt), i - 10)
                case 14: return stepTranspose
                case 15: return noteTranspose
                case 16: return count
                case 17: return delay
                case 18: return arpCount
                case 19: return tableCount
                case 20: return patternCount
                case 21: return repCount
                default: return 0
                }
            }
            // `bpstep`, then a byte each: `bppatcount`, `st`, `tr`, `bpcount`, `bpdelay`, `arpcount`,
            // `bprepcount`, `numtables`; `bpnextstep`, `lfopointer`, `lfotable`, `dma` and `tables`.
            switch i {
            case 0, 1: return ofWord(step, i)
            case 2: return patternCount
            case 3: return stepTranspose
            case 4: return noteTranspose
            case 5: return count
            case 6: return delay
            case 7: return arpCount
            case 8: return repCount
            case 9: return tableCount
            case 10, 11: return ofWord(nextStep, i - 10)
            case 12 ..< 16: return ofLong(UInt32(Self.hunk + 0xB66 + 2 * lfoPointer), i - 12)
            case 16 ..< 32:
                return ofWord(UInt16(bitPattern: Self.vibratoTable[(i - 16) / 2]), i & 1)
            default: return 0
            }
        }
        if version == .soundMon22, at >= 0xB76, at < 0xB7C {
            return at < 0xB78 ? ofWord(dma, at - 0xB76) : ofLong(address(tables), at - 0xB78)
        }
        return 0
    }

    /// Where instrument `n`'s sample is, read from the player's table `samples` at its place less four
    /// plus four times `n`: for an instrument past fifteen, or nought, what the player has there.
    private func sample(_ n: UInt8) -> UInt32? {
        let offset = 4 * Int(n) - 4
        if offset >= 0, offset < 60 { return address(samples[offset / 4]) }
        let at = layout.samples + offset
        let value = (0 ..< 4).reduce(UInt32(0)) { $0 << 8 | UInt32(image(at + $1)) }
        return value == 0 ? nil : value
    }

    // MARK: Playing

    var songCount: Int { 1 }
    var song: Int { 0 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    /// Runs the player for a tick (`bpmusic`, $286; $262), telling `output` what Paula is to do, in
    /// the order the player tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if version == .soundMon20 {
            for v in 0 ..< 4 where voices[v].synthetic != 0 { synth20(v) }
            arpCount &-= 1
            for v in 0 ..< 4 { everyTick(v, &output) }
            if arpCount == 0 { arpCount = 3 }
        } else {
            arpCount = (arpCount &- 1) & 3
            lfoPointer = (lfoPointer + 1) & 7
            for v in 0 ..< 4 { everyTick(v, &output) }
            for v in 0 ..< 4 where voices[v].synthetic != 0 { synth22(v) }
        }
        count &-= 1
        guard count == 0 else { return 20 }
        count = delay
        if ending {
            ending = false
            endings += 1
            played.removeAll(keepingCapacity: true)
        }
        nextRow()
        // `bpplay` ($340; $354): Paula's DMA turned off for the voices whose instrument changes, and the
        // notes begun.
        for v in 0 ..< 4 where dma & 1 << v != 0 { output.off(v) }
        if version == .soundMon20 {
            for v in 0 ..< 4 where voices[v].period & 0x8000 != 0 { playNote(v, &output) }
        } else {
            // The waveforms the voices' last synthesised sounds rewrote are put back first ($36C).
            for v in 0 ..< 4 where voices[v].period & 0x8000 != 0 && kept[v].at != Self.nowhere {
                restore(v)
                kept[v].at = Self.nowhere
            }
            dma = 0
            for v in 0 ..< 4 where voices[v].period & 0x8000 != 0 { playNote(v, &output) }
            for v in 0 ..< 4 where dma & 1 << v != 0 { output.on(v) }
        }
        return 20
    }

    /// `bploop1` ($29E; $29C): a voice's slide, its period, where Paula is to play from and how long,
    /// told on every tick; and its arpeggio, of three notes in 2.0 and four in 2.2 (the note twice).
    private mutating func everyTick<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        voices[v].period &+= UInt16(bitPattern: Int16(Int8(bitPattern: voices[v].autoSlide)))
        if version == .soundMon20 {
            // (The LFO, when it runs, sets the period itself.)
            if voices[v].lfoControl == 0 { periods[v] = voices[v].period }
        } else if voices[v].vibrato != 0 {
            let depth = Int16(voices[v].vibrato)
            periods[v] = UInt16(bitPattern: Self.vibratoTable[lfoPointer] / depth &+ Int16(bitPattern: voices[v].period))
        } else {
            periods[v] = voices[v].period
        }
        output.takeNextBuffer(v, start: voices[v].start, length: voices[v].length)
        let voice = voices[v]
        guard voice.arpeggio != 0 || voice.autoArpeggio != 0 else { return }
        let note: UInt8
        switch arpCount {
        case 0: note = (voice.arpeggio >> 4) &+ (voice.autoArpeggio >> 4) &+ voice.note
        case 1: note = (voice.arpeggio & 15) &+ (voice.autoArpeggio & 15) &+ voice.note
        default: note = voice.note
        }
        playArpeggio(v, note)
    }

    /// `bpplayarp` ($6D8; $7D8): the note's period told Paula; and in 2.2 kept as the voice's.
    private mutating func playArpeggio(_ v: Int, _ note: UInt8) {
        let period = period(ofNote: Int(Int8(bitPattern: note)))
        periods[v] = period
        if version == .soundMon22 { voices[v].period = period }
    }

    /// `bpnext` ($380; $3D8): each voice's row of the step, its note and option. The steps are read for
    /// the voices last first: Paula's first voice plays the step's fourth pattern.
    private mutating func nextRow() {
        dma = 0
        let v20 = version == .soundMon20
        var jumped: (step: UInt16, row: UInt8, voice: Int)?
        if played.last != step { played.append(step) }
        for v in 0 ..< 4 {
            let (entry, row) = cell(step: step, row: patternCount, voice: v)
            stepTranspose = byte(entry + 2)
            noteTranspose = byte(entry + 3)
            let note = byte(row), info = byte(row + 1), parameter = byte(row + 2)
            let option = info & 15
            if note != 0 {
                // (The arpeggio is left as it was: the player clears the word of the two after it.)
                voices[v].autoSlide = 0
                voices[v].autoArpeggio = 0
                if !v20 { voices[v].vibrato = 0 }
                // The note, transposed but for option 10 with its top half set (when it is taken as a
                // byte without a sign).
                var n = Int(note)
                if option != 10 || parameter & 0xF0 == 0 { n = Int(Int8(bitPattern: note &+ noteTranspose)) }
                voices[v].note = UInt8(truncatingIfNeeded: n)
                voices[v].period = period(ofNote: n)
                // (In 2.2 options 13 to 15 hold the note that is playing, at the new period.)
                if v20 || option < 13 {
                    voices[v].period |= 0x8000
                    voices[v].volume = 0xFF
                }
                var instrument = info >> 4
                if instrument == 0 { instrument = voices[v].instrument }
                if option != 10 || parameter & 0x0F == 0 { instrument &+= stepTranspose }
                if v20 {
                    if voices[v].length == 1 || instrument != voices[v].instrument {
                        voices[v].instrument = instrument
                        dma |= 1 << v
                    }
                } else if option < 13 {
                    if voices[v].synthetic == 0 || instrument != voices[v].instrument {
                        voices[v].instrument = instrument
                        dma |= 1 << v
                    }
                }
            }
            let at = (step, patternCount, v)
            if v20 {
                if option20(v, option, parameter) { jumped = at }
            } else {
                option22(v, option, parameter)
                if option == 7 { jumped = at }
            }
        }
        if !v20, nextStep & 0xFF00 != 0 {
            // 2.2's jump: to the step's low byte, from its first row.
            nextStep &= 0x00FF
            patternCount = 0
            step = step & 0xFF00 | nextStep
        } else {
            patternCount &+= 3
            if patternCount == 48 {
                patternCount = 0
                step &+= 1
                if step == steps {
                    // The song's end, which the player tells EaglePlayer of (`dtg_SongEnd`).
                    step = 0
                    ending = true
                }
            }
        }
        // A song that goes round by jumping back, not by coming to its end, has come to its end once it
        // comes again to a step it has played since it began, by a jump that it will take again when it
        // next comes to it (siday's reckoning: the player itself plays on, telling nothing). In 2.0,
        // whose jump is taken while a count lasts, a jump that is to be taken no more is a repeat, not
        // the song going round.
        if let jump = jumped, played.contains(step), jumpsAgain(jump) { ending = true }
    }

    /// Where the step's entry for voice `voice` is (the voices read last first), and its pattern's row
    /// `row` (in bytes, three to a row), as the player finds them: the entry by an index of a word
    /// with a sign, the pattern counted from 1 (and nought, so, as 65,535), in 32 bits.
    private func cell(step: UInt16, row: UInt8, voice: Int) -> (entry: Int, row: Int) {
        let entry = Int(Int16(bitPattern: (step << 4) &+ UInt16(4 * (3 - voice)) &+ 512))
        let pattern = word(entry)
        return (entry, Int(UInt32(steps << 4) &+ UInt32(pattern &- 1) * 48 &+ 0x200 &+ UInt32(row)))
    }

    /// The most rows played on, of the song's options alone, to see whether a jump is taken again.
    private static let mostRows = 1 << 17

    /// Whether the jump at `jump` (its step, its row and the voice whose option it is) is taken again
    /// when the song, played on from where it is now, next comes to it: of the rows, only their options
    /// 6 and 7 are played, as `nextRow` plays them.
    private func jumpsAgain(_ jump: (step: UInt16, row: UInt8, voice: Int)) -> Bool {
        let v20 = version == .soundMon20
        var step = self.step, row = patternCount, repCount = self.repCount
        for _ in 0 ..< Self.mostRows {
            var next: UInt16?
            for v in 0 ..< 4 {
                let at = cell(step: step, row: row, voice: v).row
                let option = byte(at + 1) & 15, parameter = byte(at + 2)
                if v20, option == 6 { repCount = parameter }
                guard option == 7 else { continue }
                let here = step == jump.step && row == jump.row && v == jump.voice
                if v20 {
                    repCount &-= 1
                    if here { return repCount != 0 }
                    if repCount != 0 { step = UInt16(parameter) }
                } else {
                    if here { return true }
                    next = UInt16(parameter)
                }
            }
            if let next {
                row = 0
                step = step & 0xFF00 | next
            } else {
                row &+= 3
                if row == 48 {
                    row = 0
                    step &+= 1
                    if step == steps { step = 0 }
                }
            }
        }
        return false
    }

    /// 2.0's options ($466). True for a jump taken.
    private mutating func option20(_ v: Int, _ option: UInt8, _ parameter: UInt8) -> Bool {
        switch option {
        case 0: voices[v].arpeggio = parameter
        case 1:
            volumes[v] = UInt16(parameter)
            voices[v].volume = parameter
        case 2:
            count = parameter
            delay = parameter
        // The filter, through the power light: off for nought (`bset #1,$bfe001`), on for anything else.
        case 3: lightFilter = parameter != 0
        case 4:
            voices[v].period &-= UInt16(parameter)
            voices[v].arpeggio = 0
        case 5:
            voices[v].period &+= UInt16(parameter)
            voices[v].arpeggio = 0
        case 6: repCount = parameter
        case 7:
            repCount &-= 1
            if repCount != 0 {
                step = UInt16(parameter)
                return true
            }
        case 8: voices[v].autoSlide = parameter
        case 9: voices[v].autoArpeggio = parameter
        default: break
        }
        return false
    }

    /// 2.2's options ($4DA).
    private mutating func option22(_ v: Int, _ option: UInt8, _ parameter: UInt8) {
        switch option {
        case 0: voices[v].arpeggio = parameter
        case 1:
            voices[v].volume = parameter
            if voices[v].synthetic == 0 { volumes[v] = UInt16(parameter) }
        case 2:
            count = parameter
            delay = parameter
        case 3: lightFilter = parameter != 0 // The filter, as in 2.0.
        case 4:
            voices[v].period &-= UInt16(parameter)
            voices[v].arpeggio = 0
        case 5:
            voices[v].period &+= UInt16(parameter)
            voices[v].arpeggio = 0
        case 6: voices[v].vibrato = parameter
        case 7: nextStep = 0xFF00 | UInt16(parameter)
        case 8: voices[v].autoSlide = parameter
        case 9, 13, 14, 15:
            // The auto-arpeggio; 13 also turns the effect on or off. All but 15 begin the ADSR again,
            // once if it had stopped. (11 falls through to here too, but goes no further.)
            voices[v].autoArpeggio = parameter
            if option == 13 { voices[v].fxControl ^= 1 }
            if option != 15 {
                voices[v].adsrAt = 0
                if voices[v].adsrControl == 0 { voices[v].adsrControl = 1 }
            }
        case 11: voices[v].fxControl = parameter
        default: break
        }
    }

    /// Puts back the first 32 bytes of the waveform voice `v`'s synthesised sound rewrote.
    private mutating func restore(_ v: Int) {
        let at = kept[v].at
        for i in 0 ..< 32 { write(at + i, kept[v].bytes[i]) }
    }

    /// Keeps the first 32 bytes of the waveform at `at`, to be put back.
    private mutating func keep(_ v: Int, _ at: Int) {
        kept[v].at = at
        for i in 0 ..< 32 { kept[v].bytes[i] = byte(at + i) }
    }

    /// `bpplayit` ($544; $63A): a note begun, its instrument set up and told Paula, and her DMA turned
    /// on for the voice (by 2.2 for all at once, after).
    private mutating func playNote<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let v20 = version == .soundMon20
        voices[v].period &= 0x7FFF
        // (2.0 puts back the waveform the voice's last synthesised sound rewrote here.)
        if v20, kept[v].at != Self.nowhere { restore(v) }
        periods[v] = voices[v].period
        let n = voices[v].instrument
        if field(n, 0) == 0xFF {
            playSynthetic(v, &output)
        } else {
            if v20 {
                kept[v].at = Self.nowhere
                voices[v].synthetic = 0
                voices[v].lfoControl = 0
                voices[v].adsrControl = 0
            } else {
                voices[v].synthetic = 0
                voices[v].lfoControl = 0
            }
            if let address = sample(n) {
                // The header's length (24), the loop's place in bytes (26) and length (28), the volume (30).
                let at = place(address)
                output.takeNextBuffer(v, start: at, length: fieldWord(n, 24))
                // (The volume is written as a byte, which Paula's register takes in both its halves.)
                volumes[v] = UInt16(voices[v].volume) * 0x101
                if voices[v].volume == 0xFF { volumes[v] = fieldWord(n, 30) }
                voices[v].length = fieldWord(n, 28)
                let loop = fieldWord(n, 26)
                let loopAddress = address &+ UInt32(loop)
                voices[v].start = place(loopAddress)
                if voices[v].length == 1 {
                    voices[v].start = silenceAt
                } else if v20 {
                    output.takeNextBuffer(v, start: voices[v].start, length: voices[v].length)
                } else if loop >> 1 != 0 {
                    // 2.2 plays the sample from its start to its loop's end, and the loop thereafter.
                    output.takeNextBuffer(v, start: at, length: (loop >> 1) &+ voices[v].length)
                } else {
                    output.takeNextBuffer(v, start: voices[v].start, length: voices[v].length)
                }
            } else {
                voices[v].start = silenceAt
            }
        }
        if v20 { output.on(v) } else { dma |= 1 << v }
    }

    /// `bpplaysynthetic` ($5E6; $6D6): a synthesised instrument set up, and told Paula: its waveform,
    /// for the header's length in words (2), and the volume, from its ADSR's first value if it has one.
    private mutating func playSynthetic<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let n = voices[v].instrument
        let v20 = version == .soundMon20
        voices[v].synthetic = 1
        voices[v].egAt = 0
        voices[v].lfoAt = 0
        voices[v].adsrAt = 0
        if v20 {
            // The header: 4 ADSR control, 5 table, 6 length, 8 speed; 9 LFO control, 10 table, 11 depth,
            // 12 length, 14 delay, 16 speed; 17 EG control, 18 table, 19 its first value, 20 length, 22
            // delay, 24 speed; 25 volume.
            voices[v].egCount = fieldWord(n, 22) &+ 1
            voices[v].lfoCount = fieldWord(n, 14) &+ 1
            voices[v].adsrCount = 1
            voices[v].egControl = field(n, 17)
            voices[v].lfoControl = field(n, 9)
            voices[v].adsrControl = field(n, 4)
            voices[v].egValue = field(n, 19)
        } else {
            // 2.2's: 4 to 13 as 2.0's; 14 LFO delay, 15 speed; 16 EG control, 17 table, 18 length, 20
            // delay, 21 speed; 22 FX control, 23 speed, 24 delay; 25 MOD control, 26 table, 27 speed, 28
            // delay; 29 volume; 30 MOD length.
            voices[v].modAt = 0
            voices[v].egCount = UInt16(field(n, 20) &+ 1)
            voices[v].lfoCount = UInt16(field(n, 14) &+ 1)
            voices[v].adsrCount = 1
            voices[v].modCount = field(n, 28) &+ 1
            voices[v].fxCount = field(n, 24) &+ 1
            voices[v].fxControl = field(n, 22)
            voices[v].egControl = field(n, 16)
            voices[v].lfoControl = field(n, 9)
            voices[v].adsrControl = field(n, 4)
            voices[v].modControl = field(n, 25)
            voices[v].egValue = 0
        }
        let wave = tables + Int(field(n, 1)) * 64
        voices[v].start = wave
        voices[v].length = fieldWord(n, 2)
        output.takeNextBuffer(v, start: wave, length: voices[v].length)
        let volumeField = v20 ? 25 : 29
        if voices[v].adsrControl != 0 {
            let level = UInt16((table(field(n, 5), 0) &+ 128) >> 2)
            if voices[v].volume == 0xFF { voices[v].volume = field(n, volumeField) }
            volumes[v] = (level * UInt16(voices[v].volume)) >> 6
        } else {
            volumes[v] = UInt16(voices[v].volume) * 0x101
            if voices[v].volume == 0xFF { volumes[v] = UInt16(field(n, volumeField)) * 0x101 }
        }
        if v20 {
            // `bpflipper` ($69A): the waveform kept; and turned over by the EG's first value, in eighths.
            keep(v, wave)
            guard field(n, 17) != 0, field(n, 19) != 0 else { return }
            let first = field(n, 19) >> 3
            voices[v].egValue = first
            // (A first value below 8 turns over 65,536 bytes, as the 68000's count of nought less one does:
            // here, those of them in the memory the player may write. No file of UnExoticA's has one.)
            let bytes = first == 0 ? 65536 : Int(first)
            let low = max(0, wave), high = min(silenceAt, wave + bytes)
            if low < high {
                for at in low ..< high { memory[at] = 0 &- memory[at] }
                dirtyLow = min(dirtyLow, low)
                dirtyHigh = max(dirtyHigh, high - 1)
            }
        } else if voices[v].egControl != 0 || voices[v].modControl != 0 || voices[v].fxControl != 0 {
            keep(v, wave)
        }
    }

    /// `bpyessynth` of 2.0 ($716): a synthesised sound's ADSR, LFO and EG, each on when its count of
    /// ticks comes to nought.
    private mutating func synth20(_ v: Int) {
        let n = voices[v].instrument
        if voices[v].adsrControl != 0 {
            voices[v].adsrCount &-= 1
            if voices[v].adsrCount == 0 {
                voices[v].adsrCount = UInt16(field(n, 8))
                adsrStep(v, n)
            }
        }
        if voices[v].lfoControl != 0 {
            voices[v].lfoCount &-= 1
            if voices[v].lfoCount == 0 {
                voices[v].lfoCount = UInt16(field(n, 16))
                lfoStep(v, n)
            }
        }
        guard voices[v].egControl != 0 else { return }
        voices[v].egCount &-= 1
        guard voices[v].egCount == 0, kept[v].at != Self.nowhere else { return }
        voices[v].egCount = UInt16(field(n, 24))
        egStep(v, table: field(n, 18), length: fieldWord(n, 20))
    }

    /// `bpyessynth` of 2.2 ($81A): its ADSR, LFO and EG as 2.0's, with counts of a byte; then its effect
    /// and MOD, all but the ADSR and LFO only while a waveform is kept.
    private mutating func synth22(_ v: Int) {
        let n = voices[v].instrument
        if voices[v].adsrControl != 0 {
            voices[v].adsrCount = (voices[v].adsrCount &- 1) & 0xFF
            if voices[v].adsrCount == 0 {
                voices[v].adsrCount = UInt16(field(n, 8))
                adsrStep(v, n)
            }
        }
        if voices[v].lfoControl != 0 {
            voices[v].lfoCount = (voices[v].lfoCount &- 1) & 0xFF
            if voices[v].lfoCount == 0 {
                voices[v].lfoCount = UInt16(field(n, 15))
                lfoStep(v, n)
            }
        }
        let wave = kept[v].at
        guard wave != Self.nowhere else { return }
        if voices[v].egControl != 0 {
            voices[v].egCount = (voices[v].egCount &- 1) & 0xFF
            if voices[v].egCount == 0 {
                voices[v].egCount = UInt16(field(n, 21))
                egStep(v, table: field(n, 17), length: fieldWord(n, 18))
            }
        }
        let speed = field(n, 23)
        var fxDone = false
        if voices[v].fxControl == 1 {
            // Averaging ($96A): each byte of the first 32 the mean of the one before it, as made, and
            // the one after, after its count of ticks.
            voices[v].fxCount &-= 1
            if voices[v].fxCount != 0 {
                fxDone = true
            } else {
                voices[v].fxCount = speed
                var before = Int16(Int8(bitPattern: byte(wave - 1)))
                var at = wave
                for _ in 0 ..< 16 {
                    var made = (Int16(Int8(bitPattern: byte(at + 1))) + before) >> 1
                    write(at, UInt8(truncatingIfNeeded: made))
                    at += 1
                    made = (Int16(Int8(bitPattern: byte(at + 1))) + made) >> 1
                    write(at, UInt8(truncatingIfNeeded: made))
                    before = made
                    at += 1
                }
            }
        }
        if !fxDone {
            // Each byte of the first 32 brought by the speed towards another's, on every tick: 2 the kept
            // bytes the other way round ($9A6), 3 and 5 as they were ($9D0, $A26).
            if voices[v].fxControl == 2 { for i in 0 ..< 32 { bend(wave + i, to: kept[v].bytes[31 - i], by: speed) } }
            if voices[v].fxControl == 3 { for i in 0 ..< 32 { bend(wave + i, to: kept[v].bytes[i], by: speed) } }
        }
        // 4, towards the next table's ($9FA).
        if voices[v].fxControl == 4 { for i in 0 ..< 32 { bend(wave + i, to: byte(wave + 64 + i), by: speed) } }
        if voices[v].fxControl == 5 { for i in 0 ..< 32 { bend(wave + i, to: kept[v].bytes[i], by: speed) } }
        if voices[v].fxControl == 6 {
            // 6, after its count, the next table's first 32 bytes in place of these, and the effect off
            // ($A50).
            voices[v].fxCount &-= 1
            if voices[v].fxCount == 0 {
                voices[v].fxControl = 0
                voices[v].fxCount = 1
                for i in 0 ..< 32 { write(wave + i, byte(wave + 64 + i)) }
            }
        }
        guard voices[v].modControl != 0 else { return }
        voices[v].modCount &-= 1
        guard voices[v].modCount == 0 else { return }
        // The MOD ($A76): the waveform's 33rd byte, from its table, after its count of ticks.
        voices[v].modCount = field(n, 27)
        write(wave + 32, table(field(n, 26), voices[v].modAt))
        voices[v].modAt &+= 1
        if voices[v].modAt == fieldWord(n, 30) {
            voices[v].modAt = 0
            if voices[v].modControl == 1 { voices[v].modControl = 0 }
        }
    }

    /// A byte of the waveform moved by `speed` towards `target`: up if that is higher (counted with a
    /// sign), down if lower, left if the same.
    @inline(__always) private mutating func bend(_ at: Int, to target: UInt8, by speed: UInt8) {
        let now = byte(at)
        guard target != now else { return }
        write(at, Int8(bitPattern: target) >= Int8(bitPattern: now) ? now &+ speed : now &- speed)
    }

    /// The ADSR's next value ($72A; $82E): the volume, its table's value (with a sign, made 0 to 63)
    /// times the voice's, over 64; and on through the table, once or over and over.
    private mutating func adsrStep(_ v: Int, _ n: UInt8) {
        let level = UInt16((table(field(n, 5), voices[v].adsrAt) &+ 128) >> 2)
        volumes[v] = (level * UInt16(voices[v].volume)) >> 6
        voices[v].adsrAt &+= 1
        if voices[v].adsrAt == fieldWord(n, 6) {
            voices[v].adsrAt = 0
            if voices[v].adsrControl == 1 { voices[v].adsrControl = 0 }
        }
    }

    /// The LFO's next value ($788; $888): the period, and its table's value over its depth (with a sign;
    /// over nought, the value itself); and on through the table.
    private mutating func lfoStep(_ v: Int, _ n: UInt8) {
        var change = Int16(Int8(bitPattern: table(field(n, 10), voices[v].lfoAt)))
        let depth = field(n, 11)
        if depth != 0 { change /= Int16(depth) }
        periods[v] = voices[v].period &+ UInt16(bitPattern: change)
        voices[v].lfoAt &+= 1
        if voices[v].lfoAt == fieldWord(n, 12) {
            voices[v].lfoAt = 0
            if voices[v].lfoControl == 1 { voices[v].lfoControl = 0 }
        }
    }

    /// The EG's next value ($7F4; $8F2), its table's (made 0 to 31): as many of the waveform's first
    /// bytes turned over, those it turned over before and no longer does put back as they were.
    private mutating func egStep(_ v: Int, table number: UInt8, length: UInt16) {
        let wave = kept[v].at
        let value = (table(number, voices[v].egAt) &+ 128) >> 3
        let old = voices[v].egValue
        voices[v].egValue = value
        if Int8(bitPattern: value) < Int8(bitPattern: old) {
            for i in stride(from: Int(old) - 1, through: Int(value), by: -1) { write(wave + i, keptByte(v, i)) }
        } else if value != old {
            for i in Int(old) ..< Int(value) { write(wave + i, 0 &- keptByte(v, i)) }
        }
        voices[v].egAt &+= 1
        if voices[v].egAt == length {
            voices[v].egAt = 0
            if voices[v].egControl == 1 { voices[v].egControl = 0 }
        }
    }

    /// Byte `i` of what is kept of voice `v`'s waveform, read from the player's buffer as it reads it:
    /// past the 32 bytes, the next voice's buffer (or what follows the last).
    private func keptByte(_ v: Int, _ i: Int) -> UInt8 {
        if i >= 0, i < 32 { return kept[v].bytes[i] }
        return image(layout.buffers + 36 * v + 4 + i)
    }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as she takes what the player last gave her: seven bits, 64 or
    /// more being full.
    func volume(_ voice: Int) -> UInt16 { min(64, volumes[voice] & 0x7F) }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Brian Postma's SoundMon, played on Paula by `PaulaTickRenderer`.
extension SoundMonPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "BP")
        info.detail = version.name
        info.title = title
        return info
    }

    /// SoundMon's music is louder on the Amiga's chip than ProTracker's is, by 1.5 dB in the middle of
    /// UnExoticA's 80 files, and is turned down by that (2026-10-18).
    var gain: Float { 0.39 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
