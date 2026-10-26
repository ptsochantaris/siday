// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's player of Karsten Obarski's Synth Pack for EaglePlayer ("Synth Pack player
// module V1.1 (20 Jun 2000)", "(c) 1989-92 by Karsten 'Obi' Obarski, adapted by Wanted Team", carried by
// UADE as players/SynthPack), read in its 68000 code: Wanted Team published no source of it. The labels
// given are those of a disassembly of that player, each the address in its one hunk of what it names.

import SidayChips
import SidayFoundation

/// Karsten Obarski's music in his Synth Pack (that of the games Centerbase and Dyter-07, in UnExoticA's
/// collection): a song, `name.osp`, beginning "OBISYNTHPACK", and its samples, `set.smp`, a file of their own
/// shared by a game's songs. Its instruments are samples, or waveforms of 128 bytes that the player moves
/// through a bank of 512 as they play; each has its own envelope of four stages (attack, decay, sustain and
/// release), a tremolo, a vibrato, a bend of its pitch when it starts and when it is let go, and the waveform's
/// sweep, each with a table of its shape from the player's own.
///
/// A song is up to 64 positions, each the number of rows its patterns are played for, a line of the table of
/// tracks (for each of the four voices, a pattern and how far its instruments and notes are moved), the
/// number of times it is played or a command (`$FF`, the song's end, the position played on; `$FE`, its stop;
/// `$FD`, the place to go back to; `$FC`, the going back), and the voices that play in it, the rest let go. A
/// pattern's notes, of six bytes, are a note, its volume, an instrument (nought for none), an arpeggio's kind,
/// the row it is played on (in Centerbase's form) and the arpeggio's two steps.
///
/// The files are of two forms, and Wanted Team's player has a replay routine for each (`Form`), named here
/// after the game whose files are of it (the second carries Dyter-07's table of its songs' first positions,
/// and of its sound effects): Centerbase's, whose patterns are packed, each note with the row it is played on,
/// and Dyter-07's, whose patterns are 64 rows of notes, and whose samples' file has no heading. The two play
/// much alike, but for the order of a tick's work, the shapes of their tables and their ways with them, and
/// Dyter-07's arpeggios, which are all of one kind.
///
/// This is the player as UADE runs it: what it tells Paula is what that player tells her, tick by tick. It owns
/// the memory Paula plays from: the player's hunk at `hunkAt`, with its tables and its variables (each voice's
/// record, as the routine keeps it) at their places in it, the song at `moduleAt` and its samples after it.
/// Its tick is EaglePlayer's (`DTP_Interrupt`, $7A6: the player sets no timer of its own), which UADE runs on a
/// CIA's timer from $376B, its count for fifty a second (score.s, `cia_timer_base_value`): 70,940 of Paula's
/// clocks. A song comes to its end at a position's `$FF` or `$FE`, or as it goes back at `$FC`, and stops at
/// `$FE`; its length is found by playing it through in silence.
struct SynthPackPlayer: ~Copyable {
    /// The two forms of the song (see the type's comment), by the byte the player's check sets for them
    /// (`Check2`, $4C4, into the byte at $154): nought for Centerbase's, $FF for Dyter-07's.
    enum Form {
        case centerbase, dyter
    }

    let form: Form
    /// The memory Paula plays from: the Amiga's from nought, past the samples.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// The song and its samples as they were given, put back at each song's start.
    private let module: [UInt8]
    private let samples: [UInt8]

    /// Where the player's hunk is put, the song after it, and its samples after that, at the next eight bytes
    /// (siday's choices: the player's pointers are worked out from where they are).
    static let hunkAt: UInt32 = 0x1000
    static let hunkSize = 0x2590
    static let moduleAt: UInt32 = 0x4000
    let samplesAt: UInt32
    /// Room after the samples, read as silence by a voice told a length that runs past them.
    private static let room = 0x20000 + 2048

    /// The six bytes of nought that end the player's hunk (`L258a`), where Dyter-07's routine points each
    /// voice at its start.
    static let emptyAt: UInt32 = hunkAt + 0x258A
    var silenceAt: Int { Int(Self.emptyAt) }
    var mixingAt: Int { Int(samplesAt) + samples.count + 1024 }

    let songCount: Int
    private(set) var song = 0
    /// The instruments the samples' table has, each told once.
    let instrumentCount: Int

    // Paula's registers as the player has written them.
    private var locations = InlineArray<4, UInt32>(repeating: 0)
    private var lengths = InlineArray<4, UInt16>(repeating: 0)
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)
    private var dmacon: UInt16 = 0

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// Why the song stopped other than at its stop, if it did.
    private(set) var failure: String?
    /// For checks: each write the player made to Paula's registers in the tick just run (the register's
    /// offset, $A0 to $D8 or DMACON's $96, and the word written), when this is not nil; and those its song's
    /// start made.
    var writes: [(register: UInt16, value: UInt16)]?
    private(set) var startWrites: [(register: UInt16, value: UInt16)] = []

    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in ten minutes is taken never to: longer than UADE plays a song
    /// that does not end (512 seconds), and than any of UnExoticA's.
    private static let mostTicks = 600 * 50
    /// Dyter-07's routine's table of the positions its songs start at (`L8aa`): seven, for the seven of
    /// Dyter-07's `main_fx`. The player offers as many songs as its count of a song's positions makes
    /// (`InitPlayer`, $612), and would read on into the table after it (the game's sound effects, `L8c6`) for
    /// an eighth: siday offers seven at most.
    private static let dyterStarts: [UInt16] = [0, 1, 2, 3, 5, 9, 12]
    /// The songs Centerbase's routine is offered, at most: as many as a song has positions.
    private static let mostSongs = 64

    // MARK: The player's variables, and its tables (addresses in its hunk, from `hunkAt`)

    // Centerbase's routine: its state (`L168e`), and its voices, of $42 bytes each, in the order it plays
    // them, each with its registers (`L166e`, whose voices are in that order, the third and fourth Paula's
    // fourth and third).
    private static let state: UInt32 = hunkAt + 0x168E
    private static let centerbaseVoices: [(record: UInt32, registers: UInt32)] = [
        (hunkAt + 0x16C2, 0xDFF0A0), (hunkAt + 0x1704, 0xDFF0B0), (hunkAt + 0x1788, 0xDFF0D0), (hunkAt + 0x1746, 0xDFF0C0),
    ]

    // Dyter-07's routine: its voices of $34 bytes, in the order it plays them, and in the order of its table
    // of them (`L157e`), by which it plays their arpeggios and lets them go.
    private static let dyterVoices: [(record: UInt32, registers: UInt32)] = [
        (hunkAt + 0x159E, 0xDFF0A0), (hunkAt + 0x15D2, 0xDFF0B0), (hunkAt + 0x1606, 0xDFF0C0), (hunkAt + 0x163A, 0xDFF0D0),
    ]
    private static let dyterTable: [(record: UInt32, registers: UInt32)] = [
        (hunkAt + 0x159E, 0xDFF0A0), (hunkAt + 0x15D2, 0xDFF0B0), (hunkAt + 0x163A, 0xDFF0D0), (hunkAt + 0x1606, 0xDFF0C0),
    ]
    /// Its voices' bits for DMACON set at this tick and the last (`Labc`, `Labe`); whether it plays
    /// (`Le76`); its ticks, and how many to a row (`Le78`, `Le7a`, one and six as its hunk has them); its
    /// position and row (`Lf46`, `Lf48`); the line of tracks and the pattern being played (`Lf4a`, `Lf4e`); the
    /// position to go back to, and the times the position has been played (`Lf52`, `Lf54`); the position's four
    /// bytes (`Lf56` to `Lf59`); and where the positions, the tracks and the patterns are (`L11e2`, `L11e6`,
    /// `L11ea`).
    private static let dyterNewBits: UInt32 = hunkAt + 0xABC
    private static let dyterOldBits: UInt32 = hunkAt + 0xABE
    private static let dyterPlaying: UInt32 = hunkAt + 0xE76
    private static let dyterTick: UInt32 = hunkAt + 0xE78
    private static let dyterSpeed: UInt32 = hunkAt + 0xE7A
    private static let dyterPosition: UInt32 = hunkAt + 0xF46
    private static let dyterRow: UInt32 = hunkAt + 0xF48
    private static let dyterTrack: UInt32 = hunkAt + 0xF4A
    private static let dyterPattern: UInt32 = hunkAt + 0xF4E
    private static let dyterBack: UInt32 = hunkAt + 0xF52
    private static let dyterTimes: UInt32 = hunkAt + 0xF54
    private static let dyterLine: UInt32 = hunkAt + 0xF56
    private static let dyterPositions: UInt32 = hunkAt + 0x11E2
    private static let dyterTracks: UInt32 = hunkAt + 0x11E6
    private static let dyterPatterns: UInt32 = hunkAt + 0x11EA
    /// The scale of a note's volume, 64 (`L89c`), and where the samples and the song are (`L89e`, `L8a2`).
    private static let dyterScale: UInt32 = hunkAt + 0x89C
    private static let dyterSamples: UInt32 = hunkAt + 0x89E
    private static let dyterModule: UInt32 = hunkAt + 0x8A2

    /// The tables: Dyter-07's routine's periods (`L11ee`), its six tables of how far a tremolo turns the volume
    /// down (`$127E`, 32 words each) and its six of how far a vibrato moves the period (`$13FE`, 32 words each,
    /// a signed byte in each low byte); and Centerbase's routine's periods (`L21fa`, the same) and its six
    /// waveforms of 128 bytes for all three (`L228a`).
    private static let dyterPeriodsAt: UInt32 = hunkAt + 0x11EE
    private static let dyterTremolosAt: UInt32 = hunkAt + 0x127E
    private static let dyterVibratosAt: UInt32 = hunkAt + 0x13FE
    private static let centerbasePeriodsAt: UInt32 = hunkAt + 0x21FA
    private static let centerbaseWavesAt: UInt32 = hunkAt + 0x228A

    // MARK: The check

    /// Which form a song is, by the player's check (`Check2`, $4C4): one beginning "OBISYNTHPACK", Centerbase's
    /// if its word at 1,292 (the first of its patterns' offsets) is $100, and Dyter-07's if its long there is
    /// nought. (siday's choice: refused if it is too short to have them; the player would read on past it.)
    static func form(of data: [UInt8]) -> Form? {
        guard data.count >= 1296, Array(data[0 ..< 12]) == Array("OBISYNTHPACK".utf8) else { return nil }
        if data[1292] == 1, data[1293] == 0 { return .centerbase }
        if data[1292 ..< 1296].allSatisfy({ $0 == 0 }) { return .dyter }
        return nil
    }

    static func isOne(_ data: [UInt8]) -> Bool { form(of: data) != nil }

    // MARK: Making

    /// Reads the song and its samples and starts song `song` (counting from nought).
    init(_ data: [UInt8], samples: [UInt8], song: Int = 0) throws(TuneError) {
        let found = Self.form(of: data)
        form = found ?? .dyter
        module = data
        self.samples = samples
        samplesAt = (Self.moduleAt + UInt32(data.count) + 7) & ~7
        memoryCapacity = Int(samplesAt) + samples.count + Self.room
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        songCount = Self.countSongs(data, form: form)
        instrumentCount = Self.countInstruments(samples, form: form)
        self.song = 0
        // (Refused only once it is all made.)
        guard found != nil else { throw TuneError.malformed("not a Synth Pack song: the player's check does not take it") }
        guard !samples.isEmpty else {
            throw TuneError.missingCompanion("A Synth Pack song keeps its samples in a file of their own (set.smp, beside it), which was not given with it.")
        }
        // (`InitPlayer`, $708: Centerbase's samples must begin as the song does.)
        if form == .centerbase, samples.count < 12 || Array(samples[0 ..< 12]) != Array("OBISYNTHPACK".utf8) {
            throw TuneError.malformed("a Synth Pack song of Centerbase's form, whose samples' file does not begin \"OBISYNTHPACK\"")
        }
        begin(song)
    }

    deinit { memory.deallocate() }

    /// The songs the player offers (`InitPlayer`, $612): of the song's positions before the first that is
    /// nought, those whose last two bytes are $00F0 (a position of no rows that marks a song's start in
    /// Centerbase's form); or, if there are no fewer of them, the positions whose third byte is `$FE` or `$FC`
    /// (each the end of a song); and seven for Dyter-07's `main_fx`, whose first position is $2000FExx. At
    /// least one (siday's choice: the player would offer none).
    static func countSongs(_ data: [UInt8], form: Form) -> Int {
        func long(_ at: Int) -> UInt32 {
            at + 3 < data.count ? UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3]) : 0
        }
        var marks = 0
        for i in 0 ..< 64 {
            let entry = long(12 + 4 * i)
            if entry == 0 { break }
            if entry & 0xFFFF == 0xF0 { marks += 1 }
        }
        var ends = 0, counted = 0, at = 12
        while counted < 64 {
            let entry = long(at)
            at += 4
            if entry != 0 {
                if entry & 0xFF00 == 0xFE00 || entry & 0xFF00 == 0xFC00 { ends += 1 }
            } else if long(at) == 0 {
                break
            }
            counted += 1
        }
        var songs = ends >= marks ? ends : marks
        if long(12) >> 16 == 0x2000, long(12) >> 8 & 0xFF == 0xFE { songs = 7 }
        return max(1, min(form == .dyter ? dyterStarts.count : mostSongs, songs))
    }

    /// The instruments of the samples' table (64 of them, longs from 12 in Centerbase's form, words from
    /// nought in Dyter-07's), each place counted once (siday's own count, for what is said of the tune).
    private static func countInstruments(_ samples: [UInt8], form: Form) -> Int {
        var places = Set<Int>()
        for i in 0 ..< 64 {
            let at = form == .centerbase ? 12 + 4 * i : 2 * i
            let width = form == .centerbase ? 4 : 2
            guard at + width <= samples.count else { break }
            var place = 0
            for k in 0 ..< width { place = place << 8 | Int(samples[at + k]) }
            if place > 0, place < samples.count { places.insert(place) }
        }
        return places.count
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        begin(song)
    }

    /// Starts song `song`, as a player newly loaded would; and finds how long it is.
    private mutating func begin(_ song: Int) {
        self.song = song >= 0 && song < songCount ? song : 0
        initialise()
        var none = TFMXSilentOutput()
        let logging = writes
        writes = nil
        var ticks = 0
        while endings == 0, stops == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again, or its stop.)
        lengthClocks = endings > 0 || stops > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        writes = logging
        initialise()
    }

    /// The memory as it was given, with the player's hunk as it has it; Paula's registers as they were; and
    /// `InitPlayer`'s places of the song and its samples and `InitSound` ($7FE) for the song.
    private mutating func initialise() {
        memory.update(repeating: 0, count: memoryCapacity)
        for (i, byte) in Self.hunk.enumerated() { memory[Int(Self.hunkAt) + i] = byte }
        for (i, byte) in module.enumerated() { memory[Int(Self.moduleAt) + i] = byte }
        for (i, byte) in samples.enumerated() { memory[Int(samplesAt) + i] = byte }
        locations = .init(repeating: 0)
        lengths = .init(repeating: 0)
        paulaPeriods = .init(repeating: 0)
        paulaVolumes = .init(repeating: 0)
        dmacon = 0
        endings = 0
        stops = 0
        failure = nil
        let logging = writes
        writes = []
        var none = TFMXSilentOutput()
        switch form {
        case .centerbase: startCenterbase(&none)
        case .dyter: startDyter(&none)
        }
        startWrites = writes ?? []
        writes = logging
    }

    // MARK: Playing

    /// The player's `DTP_Interrupt` ($7A6): the routine's tick, Centerbase's (`L1a48`) or Dyter-07's (`Lab2`).
    /// (What it keeps for EaglePlayer's display of the voices is not heard, and not kept.) Returns the tick's
    /// length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if writes != nil { writes = [] }
        if failure == nil {
            switch form {
            case .centerbase: centerbaseTick(&output)
            case .dyter: dyterTick(&output)
            }
        }
        if failure != nil, stops == 0 { stops += 1 }
        return Self.tickClocks * 1000 / 3_546_895
    }

    /// The song's end, told to EaglePlayer (`L7ea`, by its `dtg_SongEnd`); and its stop.
    private mutating func songEnd() { endings += 1 }

    private mutating func stop() { stops += 1 }

    // MARK: Centerbase's routine

    /// `InitSound` for Centerbase's form: the routine's state and voices cleared (79 longs from `L168e`), and
    /// `L17ca`: the samples' place, the two scales of the volume (at 40 and 42 of the state) 64, the filter off,
    /// the voices' bits for DMACON (by their records: 1, 2, 4 and 8) and for the voices a line of tracks
    /// plays (1, 2, 4 and 8 by the order the routine plays them, at 61); each voice let go, its envelope done,
    /// and its length one word and volume nought; the voices' DMA on. Then `L1986` for the song: its positions,
    /// tracks and patterns found, and its first position the song's mark (of the positions whose last byte's
    /// top four bits are not all nought, the song's number counting from nought), or the first if there are
    /// not so many; six ticks to a row, its count of them at one, so that the first row is read at the fifth
    /// tick; no position marked to go back to ($FFFF); and the song played.
    private mutating func startCenterbase<Output: TFMXOutput>(_ output: inout Output) {
        let a2 = Self.state
        (memory + Int(a2)).update(repeating: 0, count: 79 * 4)
        poke32(a2, samplesAt)
        poke16(a2 + 40, 64)
        poke16(a2 + 42, 64)
        poke16(a2 + 50, 0)
        poke16(a2 + 44, 0)
        let records = Self.centerbaseVoices.map { $0.record }
        for (record, bit) in zip([records[0], records[1], records[3], records[2]], [UInt8(1), 2, 4, 8]) { poke8(record, bit) }
        for (record, bit) in zip(records, [UInt8(1), 2, 4, 8]) { poke8(record + 61, bit) }
        for (a5, a6) in Self.centerbaseVoices {
            poke8(a5 + 1, 0xFF)
            poke8(a5 + 60, 0)
            poke8(a5 + 9, 4)
            poke16(a6 + 4, 1, &output)
            poke16(a6 + 8, 0, &output)
        }
        poke16(0xDFF096, 0x800F, &output)
        // `L1986`.
        poke32(a2 + 4, Self.moduleAt)
        poke16(a2 + 20, 0)
        poke16(a2 + 22, 0)
        poke16(a2 + 48, 6)
        poke16(a2 + 46, 1)
        var marks = 0, start: UInt16 = 0, found = false
        for i in 0 ..< 64 where peek8(Self.moduleAt + 12 + UInt32(4 * i) + 3) & 0xF0 != 0 {
            if marks == song {
                start = UInt16(i)
                found = true
                break
            }
            marks += 1
        }
        poke16(a2 + 20, found ? start : 0)
        poke32(a2 + 8, Self.moduleAt + 12)
        poke32(a2 + 12, Self.moduleAt + 12 + 256)
        poke32(a2 + 16, Self.moduleAt + 12 + 256 + 1024)
        poke16(a2 + 44, 0xFFFF)
        poke16(a2 + 28, 0xFFFF)
    }

    /// `L1a48`: a count of ticks to six, a tick in each six left out while the byte at 51 of the state is set
    /// (which nothing of EaglePlayer's sets); and the voices (`L1a7c`), then the song (`L1e38`).
    private mutating func centerbaseTick<Output: TFMXOutput>(_ output: inout Output) {
        let a2 = Self.state
        poke8(a2 + 50, peek8(a2 + 50) &+ 1)
        var skip = false
        if Int8(bitPattern: peek8(a2 + 50)) >= 6 {
            poke8(a2 + 50, 0)
            skip = peek8(a2 + 51) != 0
        } else if peek8(a2 + 50) == 0 {
            skip = peek8(a2 + 51) != 0
        }
        if skip { return }
        centerbaseVoices(&output)
        if failure == nil { centerbaseSong() }
    }

    /// `L1a7c`: the DMA of the voices started at the last tick turned on; and each voice's instrument played
    /// (`L1b08`), its loop told the tick after its start (`L1b94`) and its start told (`L1b54`); and the DMA of
    /// the voices started at this tick turned off, to be turned on at the next.
    private mutating func centerbaseVoices<Output: TFMXOutput>(_ output: inout Output) {
        let a2 = Self.state
        let old = peek16(a2 + 38)
        if old != 0 { poke16(0xDFF096, old | 0x8000, &output) }
        poke16(a2 + 36, 0)
        for (a5, a6) in Self.centerbaseVoices {
            let a4 = centerbaseInstrument(peek8(a5 + 2))
            centerbaseInstrument(a5, a6, a4, &output)
            centerbaseLoop(a5, a6, a4, &output)
            centerbaseStart(a5, a6, a4, &output)
            if failure != nil { return }
        }
        poke16(0xDFF096, peek16(a2 + 36), &output)
        poke16(a2 + 38, peek16(a2 + 36))
    }

    /// An instrument's place in Centerbase's samples: from the long of their table (at 12) for it.
    private mutating func centerbaseInstrument(_ number: UInt8) -> UInt32 {
        let a0 = peek32(Self.state)
        return a0 &+ peek32(a0 &+ 12 &+ UInt32(number) << 2)
    }

    /// `L1b08`: a voice's envelope (`L1bdc`), tremolo (`L1cb2`), vibrato (`L1d20`), waveform (`L1d7c`) and bend
    /// (`L1df6`); its volume told, the envelope's times the note's times the state's scale, over 4,096 (its
    /// low seven bits, as `L346` takes it, its scales for EaglePlayer's volume and balance being 64), and its
    /// period.
    private mutating func centerbaseInstrument<Output: TFMXOutput>(_ a5: UInt32, _ a6: UInt32, _ a4: UInt32, _ output: inout Output) {
        centerbaseEnvelope(a5, a4)
        centerbaseTremolo(a5, a4)
        centerbaseVibrato(a5, a4)
        centerbaseWaveform(a5, a6, a4, &output)
        centerbaseBend(a5, a4)
        let product = UInt32(UInt16(truncatingIfNeeded: UInt32(peek16(a5 + 14)) * UInt32(peek16(a5 + 54)))) * UInt32(peek16(Self.state + 40))
        poke16(a6 + 8, UInt16(truncatingIfNeeded: (product << 4) >> 16) & 0x7F, &output)
        poke16(a6 + 6, peek16(a5 + 26), &output)
    }

    /// `L1bdc`: the envelope, by its stage (the voice's byte at 9), its count (the word at 10) going down by two
    /// a tick, and when it is spent, taken again from the instrument's speed of the stage, and the volume (the
    /// word at 12) moved by eight: in the attack (stage nought) up to its level (the instrument's byte at 16,
    /// at the speed at 17), in the decay down to the sustain's (at 19, at the speed at 18), held while the note
    /// is held, and in the release (once it is let go) down to nought (at the speed at 20); each going on to the
    /// next stage at its level, or with a speed of nought. Stage four is its end.
    private mutating func centerbaseEnvelope(_ a5: UInt32, _ a4: UInt32) {
        envelope(a5, a4, attackLevel: 16, attackSpeed: 17, decaySpeed: 18, sustainLevel: 19, releaseSpeed: 20)
    }

    /// `L1cb2`: the tremolo, unless it is the instrument's to begin once the note is let go (its byte at 25)
    /// and it is not: after its delay (the voice's byte at 16, a word less $40 a tick), its place (the word at
    /// 20) moved by its speed (at 18); unless its shift (the instrument's byte at 23) is eight, the waveform's
    /// byte at the place's top seven bits, made from nought to 127 and shifted down, taken off the envelope's
    /// volume (no lower than nought), and the volume told.
    private mutating func centerbaseTremolo(_ a5: UInt32, _ a4: UInt32) {
        if peek8(a4 &+ 25) != 0, peek8(a5 + 1) == 0 {
            poke16(a5 + 14, peek16(a5 + 12))
            return
        }
        if peek8(a5 + 16) != 0 {
            poke16(a5 + 16, peek16(a5 + 16) &- 0x40)
            poke16(a5 + 14, peek16(a5 + 12))
            return
        }
        poke16(a5 + 20, peek16(a5 + 20) &+ peek16(a5 + 18))
        if peek8(a4 &+ 23) == 8 {
            poke16(a5 + 14, peek16(a5 + 12))
            return
        }
        let a0 = peek32(a5 + 22)
        let byte = a0 == 0 ? 0 : peek8(a0 &+ UInt32(peek8(a5 + 20) & 0x7F))
        let d1 = shiftedDown(UInt16((byte ^ 0x80) >> 1), peek8(a4 &+ 23))
        let volume = peek16(a5 + 12)
        if volume == 0 {
            poke16(a5 + 14, volume)
            return
        }
        let d0 = volume &- d1
        poke16(a5 + 14, negative(d0) ? 0 : d0)
    }

    /// `L1d20`: the vibrato, unless it is the instrument's to begin once the note is let go (its byte at 30) and
    /// it is not: after its delay (the voice's byte at 28), its place (the word at 32) moved by its speed (at
    /// 30), and unless its shift (the instrument's byte at 28) is eight, the waveform's byte at the place's top
    /// seven bits, shifted down, added to the note's period, as the period to be told (the word at 26).
    private mutating func centerbaseVibrato(_ a5: UInt32, _ a4: UInt32) {
        var d1: UInt16 = 0
        if peek8(a4 &+ 30) != 0, peek8(a5 + 1) == 0 {
        } else if peek8(a5 + 28) != 0 {
            poke16(a5 + 28, peek16(a5 + 28) &- 0x40)
        } else {
            poke16(a5 + 32, peek16(a5 + 32) &+ peek16(a5 + 30))
            if peek8(a4 &+ 28) != 8 {
                let a0 = peek32(a5 + 34)
                let byte = a0 == 0 ? 0 : peek8(a0 &+ UInt32(peek8(a5 + 32) & 0x7F))
                d1 = shiftedDownSigned(UInt16(bitPattern: Int16(Int8(bitPattern: byte))), peek8(a4 &+ 28))
            }
        }
        poke16(a5 + 26, d1 &+ peek16(a5 + 6))
    }

    /// `L1d7c`: for a waveform (an instrument of no more than $80 bytes), where Paula plays it from in its bank
    /// of two halves of 256 bytes after its heading of 48: unless it is the instrument's to begin once the note
    /// is let go (its byte at 35) and it is not, after its delay (the voice's byte at 40), its place (the word
    /// at 44) moved by its speed (at 42), and unless its shift (the instrument's byte at 33) is eight, the
    /// waveform's byte at the place's top seven bits, made from 127 to nought and shifted down: its low bit the
    /// half, and the rest the byte in it. Told at every tick.
    private mutating func centerbaseWaveform<Output: TFMXOutput>(_ a5: UInt32, _ a6: UInt32, _ a4: UInt32, _ output: inout Output) {
        if Int16(bitPattern: peek16(a4 &+ 2)) > 0x80 { return }
        var d1: UInt16 = 0
        if peek8(a4 &+ 35) != 0, peek8(a5 + 1) == 0 {
        } else if peek8(a5 + 40) != 0 {
            poke16(a5 + 40, peek16(a5 + 40) &- 0x40)
        } else {
            poke16(a5 + 44, peek16(a5 + 44) &+ peek16(a5 + 42))
            if peek8(a4 &+ 33) != 8 {
                let byte = peek8(peek32(a5 + 46) &+ UInt32(peek8(a5 + 44) & 0x7F))
                d1 = shiftedDown(UInt16(~(byte ^ 0x80) >> 1), peek8(a4 &+ 33))
            }
        }
        var a0 = a4 &+ 48
        if d1 & 1 != 0 {
            d1 &= ~1
            a0 &+= 256
        }
        poke32(a6, a0 &+ wide(d1), &output)
    }

    /// `L1df6`: the bend (the voice's word at 50, from the instrument's word at 8 at the note's start), moved
    /// towards nought by its speed (the instrument's word at 10) while the note is held, and once it is let go,
    /// towards the instrument's word at 12 by its speed at 14; taken off the period to be told.
    private mutating func centerbaseBend(_ a5: UInt32, _ a4: UInt32) {
        bend(a5, a4, at: 50, speed: 10, target: 12, releaseSpeed: 14)
    }

    /// `L1b94`: the tick after a voice's start (its byte at 8 $FE), its loop told: for a sample with none (the
    /// instrument's long at 4 nought), a length of one word, played from where it is; else the loop, from the
    /// word at 4 to the word at 6 of the sample after its heading of 48.
    private mutating func centerbaseLoop<Output: TFMXOutput>(_ a5: UInt32, _ a6: UInt32, _ a4: UInt32, _ output: inout Output) {
        loop(a5, a6, a4, heading: 48, &output)
    }

    /// `L1b54`: a voice started (its byte at 8 $FF): its bit for DMACON kept, to be turned off at the tick's end
    /// and on at the next, and Paula told its sample from after its heading of 48, its length (the word at 2)
    /// or, for one with a loop, up to its loop's end (at 6).
    private mutating func centerbaseStart<Output: TFMXOutput>(_ a5: UInt32, _ a6: UInt32, _ a4: UInt32, _ output: inout Output) {
        start(a5, a6, a4, heading: 48, bits: Self.state + 36, &output)
    }

    /// `L1e38`: while the song plays (the state's word at 44), its count of ticks (at 46) up to its speed (at
    /// 48), each tick the arpeggios (`L1edc`), and at the speed, the count again from nought and the next row
    /// (`L1f74`).
    private mutating func centerbaseSong() {
        let a2 = Self.state
        if peek16(a2 + 44) == 0 { return }
        poke16(a2 + 46, peek16(a2 + 46) &+ 1)
        if Int16(bitPattern: peek16(a2 + 48)) > Int16(bitPattern: peek16(a2 + 46)) {
            centerbaseArpeggios()
            return
        }
        poke16(a2 + 46, 0)
        centerbaseArpeggios()
        centerbaseRow()
    }

    /// `L1edc`: each voice's arpeggio (`L1ef4`), by its kind (the low three bits of its byte at 3): its next
    /// step of the kind's list (`L1e5c`), at its word at 56, and the list from its start after its end; a
    /// step the note, or the note and the top four bits of the voice's byte at 5, or its low four bits (none
    /// where they are nought), made the note's period (`L1f40`, from `L21fa`, less the instrument's byte at 1).
    private mutating func centerbaseArpeggios() {
        for (a5, _) in Self.centerbaseVoices {
            let list = Self.arpeggios[Int(peek8(a5 + 3) & 7)]
            var step = Int(peek16(a5 + 56))
            poke16(a5 + 56, UInt16(truncatingIfNeeded: step + 1))
            if step >= list.count {
                poke16(a5 + 56, 0)
                step = 0
            }
            guard let add = arpeggioStep(a5, list[step]) else { continue }
            let a0 = peek32(Self.state)
            let a4 = a0 &+ peek32(a0 &+ 12 &+ wide(UInt16(bitPattern: Int16(Int8(bitPattern: peek8(a5 + 2)))) << 2))
            let note = add &+ peek16(a5 + 52)
            poke16(a5 + 58, note)
            poke16(a5 + 6, peek16(Self.centerbasePeriodsAt &+ wide(note &+ note)) &- signedByte(peek8(a4 &+ 1)))
        }
    }

    /// The kinds of arpeggio of Centerbase's routine (`L1e5c`, eight lists of the routine's three steps,
    /// `$1F24`, `$1F34` and `$1F28`, each ended by $FFFF): nought, the note; one, the note and the top four bits
    /// of the voice's byte at 5; two, the note and its low four bits.
    private static let arpeggios: [[UInt8]] = [
        [0, 1], [0, 1, 0, 2], [0, 1, 2], [0, 1, 2, 1], [0, 0, 1, 1, 2, 2], [0, 0, 1, 1, 2, 2, 1, 1],
        [0, 0, 0, 1, 1, 1, 2, 2, 2], [0, 0, 0, 1, 1, 1, 2, 2, 2, 1, 1, 1],
    ]

    /// An arpeggio's step: what is added to the note, or nil for none (a nibble of nought).
    private func arpeggioStep(_ a5: UInt32, _ step: UInt8) -> UInt16? {
        switch step {
        case 0: return 0
        case 1:
            let high = UInt16(peek8(a5 + 5) & 0xF0)
            return high == 0 ? nil : high >> 4
        default:
            let low = UInt16(peek8(a5 + 5) & 0x0F)
            return low == 0 ? nil : low
        }
    }

    /// `L1f74`: a row of the song: its position's four bytes kept (at 32 of the state), its line of tracks
    /// found, and from its first track, the speed; each voice's row (`L2076`), each from its track; and the row
    /// counted, and at the position's number of rows, the position played again for its number of times, or the
    /// next (of 64, round to the first), or its command: `$FF` the song's end, the position played on; `$FE` its
    /// stop, each voice let go (`L1a06`); `$FD` the position marked to go back to, and the next; `$FC` the
    /// position marked, and the song's end, or the next if none is marked. (Any other is played on, as `$FF`
    /// is, but not taken as the song's end.)
    private mutating func centerbaseRow() {
        let a2 = Self.state
        let entry = peek32(a2 + 8) &+ UInt32(UInt16(truncatingIfNeeded: UInt32(peek16(a2 + 20)) << 2))
        poke32(a2 + 32, peek32(entry))
        let line = UInt32(UInt16(peek8(entry &+ 1)) << 4) &+ peek32(a2 + 12)
        poke32(a2 + 24, line)
        poke8(a2 + 49, peek8(line &+ 3))
        for (i, (a5, a6)) in Self.centerbaseVoices.enumerated() {
            if i > 0 { poke32(a2 + 24, peek32(a2 + 24) &+ 4) }
            centerbaseVoiceRow(a5, a6)
            if failure != nil { return }
        }
        let rows = UInt16(peek8(a2 + 32))
        poke16(a2 + 22, peek16(a2 + 22) &+ 1)
        if Int16(bitPattern: rows) > Int16(bitPattern: peek16(a2 + 22)) { return }
        poke16(a2 + 22, 0)
        let command = peek8(a2 + 34)
        func next() {
            poke16(a2 + 30, 0)
            poke16(a2 + 20, (peek16(a2 + 20) &+ 1) & 0x3F)
        }
        if !negative(command) {
            if Int16(command) > Int16(bitPattern: peek16(a2 + 30)) {
                poke16(a2 + 30, peek16(a2 + 30) &+ 1)
                return
            }
            next()
            return
        }
        switch command {
        case 0xFF:
            songEnd()
        case 0xFE:
            poke16(a2 + 44, 0)
            for (a5, _) in Self.centerbaseVoices {
                poke8(a5 + 1, 0xFF)
                poke8(a5 + 9, 2)
                poke8(a5 + 60, 0)
            }
            songEnd()
            stop()
        case 0xFD:
            poke16(a2 + 28, peek16(a2 + 20))
            next()
        case 0xFC:
            if negative(peek16(a2 + 28)) {
                next()
                return
            }
            poke16(a2 + 30, 0)
            poke16(a2 + 20, peek16(a2 + 28))
            songEnd()
        default:
            break
        }
    }

    /// `L2076`: a voice's row, by its track (the line's four bytes for it: its pattern, and how far its
    /// instruments and its notes are moved). At the first row, its pattern found, from the song's table of
    /// their offsets (at 1,292); then the pattern's next note taken if it is of this row (its fifth byte the
    /// row's number). A voice the position does not play (by its bit, at 61) is let go at the first row; and
    /// a note of this row, of a volume of nought, lets it go, and of any other, starts the note's instrument,
    /// moved, at the note, moved by the instrument's own byte at nought and by the track's (`L213a`), at the
    /// note's volume, its scale (the state's word at 42) over 64, and its arpeggio.
    private mutating func centerbaseVoiceRow(_ a5: UInt32, _ a6: UInt32) {
        let a2 = Self.state
        if peek16(a2 + 22) == 0 {
            let pattern = UInt32(peek8(peek32(a2 + 24))) << 1
            let table = peek32(a2 + 16)
            poke32(a5 + 62, table &+ UInt32(peek16(table &+ pattern)))
        }
        let a3 = peek32(a5 + 62)
        let row = peek16(a2 + 22)
        if UInt8(truncatingIfNeeded: row) == peek8(a3 &+ 4) { poke32(a5 + 62, peek32(a5 + 62) &+ 6) }
        if peek8(a5 + 60) != 0 {
            poke8(a5 + 60, peek8(a5 + 60) &- 1)
            return
        }
        if peek8(a2 + 35) & peek8(a5 + 61) == 0 {
            if row == 0 { letGo(a5) }
            return
        }
        if UInt8(truncatingIfNeeded: row) != peek8(a3 &+ 4) { return }
        if peek8(a3 &+ 1) == 0 {
            letGo(a5)
            return
        }
        let track = peek32(a2 + 24)
        var number = UInt16(peek8(a3 &+ 2) &- 1) &+ signedByte(peek8(track &+ 1))
        if negative(number) { number = 0 }
        poke8(a5 + 2, UInt8(truncatingIfNeeded: number))
        let a0 = peek32(a2)
        let a4 = a0 &+ peek32(a0 &+ 12 &+ wide(UInt16(truncatingIfNeeded: UInt32(number) << 2)))
        let volume = UInt32(signedByte(peek8(a3 &+ 1))) * UInt32(peek16(a2 + 42))
        poke16(a5 + 54, UInt16(truncatingIfNeeded: volume) >> 6)
        let note = UInt16(peek8(a3) &+ peek8(a4)) &+ signedByte(peek8(track &+ 2))
        poke8(a5 + 3, peek8(a3 &+ 3))
        poke8(a5 + 4, peek8(a3 &+ 4))
        poke8(a5 + 5, peek8(a3 &+ 5))
        centerbaseNote(a5, a4, note)
    }

    /// `L213a`: a note started: its period (`L21fa`, less the instrument's byte at 1), as the note's and to be
    /// told; the voice no longer let go, its envelope from its attack, and its effects from their starts: the
    /// bend from the instrument's word at 8, the tremolo's waveform (`L228a`, by its byte at 24), speed (at 22,
    /// times 16) and delay (at 21), the vibrato's (at 29, 27 and 26) and the waveform's sweep's (at 34, 32 and
    /// 31); and the voice to be started.
    private mutating func centerbaseNote(_ a5: UInt32, _ a4: UInt32, _ note: UInt16) {
        poke16(a5 + 52, note)
        poke16(a5 + 58, note)
        let period = peek16(Self.centerbasePeriodsAt &+ wide(note &+ note)) &- signedByte(peek8(a4 &+ 1))
        poke16(a5 + 6, period)
        poke16(a5 + 26, period)
        poke8(a5 + 1, 0)
        poke8(a5 + 9, 0)
        poke16(a5 + 10, 0)
        poke32(a5 + 12, 0)
        poke32(a5 + 16, 0)
        poke16(a5 + 20, 0)
        poke32(a5 + 28, 0)
        poke16(a5 + 32, 0)
        poke32(a5 + 40, 0)
        poke16(a5 + 44, 0)
        poke16(a5 + 50, peek16(a4 &+ 8))
        poke32(a5 + 22, Self.centerbaseWavesAt &+ UInt32(peek8(a4 &+ 24)) << 7)
        poke16(a5 + 18, UInt16(peek8(a4 &+ 22)) << 4)
        poke8(a5 + 16, peek8(a4 &+ 21))
        poke32(a5 + 34, Self.centerbaseWavesAt &+ UInt32(peek8(a4 &+ 29)) << 7)
        poke16(a5 + 30, UInt16(peek8(a4 &+ 27)) << 4)
        poke8(a5 + 28, peek8(a4 &+ 26))
        poke32(a5 + 46, Self.centerbaseWavesAt &+ UInt32(peek8(a4 &+ 34)) << 7)
        poke16(a5 + 42, UInt16(peek8(a4 &+ 32)) << 4)
        poke8(a5 + 40, peek8(a4 &+ 31))
        poke8(a5 + 8, 0xFF)
        poke16(a5 + 56, 0)
    }

    // MARK: Dyter-07's routine

    /// `InitSound` for Dyter-07's form: the voices cleared (52 longs from `L159e`), their bits for DMACON (1,
    /// 2, 4 and 8, in their order); `L952`: the filter off, the song not playing, the voices' DMA on, each
    /// pointed at `L258a` with a length of one word, and its envelope done. Then `La3a` for the song: its first
    /// position from `L8aa`, its first row, its positions, tracks and patterns found, and the song played.
    /// (Its ticks and their speed are as the hunk has them, one and six: the first row is at the fifth tick.)
    private mutating func startDyter<Output: TFMXOutput>(_ output: inout Output) {
        (memory + Int(Self.dyterVoices[0].record)).update(repeating: 0, count: 52 * 4)
        for (i, (a5, _)) in Self.dyterVoices.enumerated() { poke8(a5, 1 << UInt8(i)) }
        poke16(Self.dyterPlaying, 0)
        poke16(0xDFF096, 0x800F, &output)
        for (_, a6) in Self.dyterVoices { poke32(a6, Self.emptyAt, &output) }
        for (_, a6) in Self.dyterVoices { poke16(a6 + 4, 1, &output) }
        for (a5, _) in Self.dyterVoices { poke8(a5 + 9, 4) }
        poke32(Self.dyterSamples, samplesAt)
        poke32(Self.dyterModule, Self.moduleAt)
        // `La3a`.
        poke16(Self.dyterPosition, Self.dyterStarts[song])
        poke16(Self.dyterRow, 0)
        let base = peek32(Self.dyterModule) &+ 12
        poke32(Self.dyterPositions, base)
        poke32(Self.dyterTracks, base &+ 0x100)
        poke32(Self.dyterPatterns, base &+ 0x500)
        poke16(Self.dyterPlaying, 0xFFFF)
    }

    /// `Lab2`: the song (`Le7c`), then the voices (`Lac0`).
    private mutating func dyterTick<Output: TFMXOutput>(_ output: inout Output) {
        dyterSong()
        if failure == nil { dyterVoices(&output) }
    }

    /// `Le7c`: while the song plays, its count of ticks up to its speed, each tick but the speed's the
    /// arpeggios (`Led0`), and at the speed, the count from nought and the next row (`Lf5a`).
    private mutating func dyterSong() {
        if peek16(Self.dyterPlaying) == 0 { return }
        poke16(Self.dyterTick, peek16(Self.dyterTick) &+ 1)
        if Int16(bitPattern: peek16(Self.dyterSpeed)) > Int16(bitPattern: peek16(Self.dyterTick)) {
            dyterArpeggios()
            return
        }
        poke16(Self.dyterTick, 0)
        dyterRow()
    }

    /// `Led0`: each voice's arpeggio (`Lee4`), by the tick of the row (`Lea0`, twelve of them, the note and the
    /// top and low four bits of the voice's byte at 5 in turn, none where they are nought), made the note's
    /// period (`Lf10`, from `L11ee`, less the instrument's byte at 1). (The table has twelve ticks, and a row of
    /// more, of a speed of 13 to 15, would send the player into its own code: the song is stopped there,
    /// siday's choice.)
    private mutating func dyterArpeggios() {
        let tick = Int(peek16(Self.dyterTick))
        guard tick < 12 else {
            failure = "a row of more than twelve ticks, past the player's table of its arpeggio's steps"
            return
        }
        for (a5, _) in Self.dyterTable {
            guard let add = arpeggioStep(a5, UInt8(tick % 3)) else { continue }
            let a4 = dyterInstrument(UInt16(bitPattern: Int16(Int8(bitPattern: peek8(a5 + 2)))) << 1)
            let note = (add &+ peek16(a5 + 46)) << 1
            poke16(a5 + 6, peek16(Self.dyterPeriodsAt &+ wide(note)) &- signedByte(peek8(a4 &+ 1)))
        }
    }

    /// An instrument's place in Dyter-07's samples: from the word of their table (from nought) at `index`.
    private mutating func dyterInstrument(_ index: UInt16) -> UInt32 {
        let a4 = peek32(Self.dyterSamples)
        return a4 &+ UInt32(peek16(a4 &+ wide(index)))
    }

    /// `Lf5a`: a row of the song: its position's four bytes kept (`Lf56`), its line of tracks found, and from
    /// its first track, the speed (its low four bits, or six for nought); each voice's row (`L1074`), each from
    /// its track; and the row counted, and at the position's number of rows, the position played again for its
    /// number of times, or the next (of 64, round to the first), or its command, as Centerbase's routine has
    /// them (`centerbaseRow`), but that its `$FE` lets the voices go by `La90`, and its `$FC` goes back to the
    /// first position if none is marked (its mark being nought as the hunk has it).
    private mutating func dyterRow() {
        let entry = peek32(Self.dyterPositions) &+ UInt32(UInt16(truncatingIfNeeded: UInt32(peek16(Self.dyterPosition)) << 2))
        poke32(Self.dyterLine, peek32(entry))
        let line = UInt32(UInt16(peek8(entry &+ 1)) << 4) &+ peek32(Self.dyterTracks)
        poke32(Self.dyterTrack, line)
        let speed = UInt16(peek8(line &+ 3) & 0xF)
        poke16(Self.dyterSpeed, speed == 0 ? 6 : speed)
        for (i, (a5, _)) in Self.dyterVoices.enumerated() {
            if i > 0 { poke32(Self.dyterTrack, peek32(Self.dyterTrack) &+ 4) }
            dyterVoiceRow(a5)
            if failure != nil { return }
        }
        let rows = UInt16(peek8(Self.dyterLine))
        poke16(Self.dyterRow, peek16(Self.dyterRow) &+ 1)
        if Int16(bitPattern: rows) > Int16(bitPattern: peek16(Self.dyterRow)) { return }
        poke16(Self.dyterRow, 0)
        let command = peek8(Self.dyterLine + 2)
        func next() {
            poke16(Self.dyterTimes, 0)
            poke16(Self.dyterPosition, (peek16(Self.dyterPosition) &+ 1) & 0x3F)
        }
        if !negative(command) {
            if Int16(command) > Int16(bitPattern: peek16(Self.dyterTimes)) {
                poke16(Self.dyterTimes, peek16(Self.dyterTimes) &+ 1)
                return
            }
            next()
            return
        }
        switch command {
        case 0xFF:
            songEnd()
        case 0xFE:
            poke16(Self.dyterPlaying, 0)
            for (a5, _) in Self.dyterTable {
                poke8(a5 + 1, 0xFF)
                poke8(a5 + 9, 2)
            }
            songEnd()
            stop()
        case 0xFD:
            poke16(Self.dyterBack, peek16(Self.dyterPosition))
            next()
        case 0xFC:
            if negative(peek16(Self.dyterBack)) {
                next()
                return
            }
            poke16(Self.dyterTimes, 0)
            poke16(Self.dyterPosition, peek16(Self.dyterBack))
            songEnd()
        default:
            break
        }
    }

    /// `L1074`: a voice's row, by its track (its pattern, and how far its instruments and notes are moved): the
    /// pattern's row (six bytes, of 64 rows of $180 bytes from `L11ea`). A voice the position does not play
    /// (by its bit) is let go at the first row; a row with an instrument sets the voice's, moved, and with a
    /// volume, starts the note, moved by the instrument's own byte at nought and the track's (`L1144`), at the
    /// row's volume, its scale (`L89c`) over 64, and its arpeggio's steps; with a volume of nought, a note of
    /// `$FF` lets the voice go, and any other leaves it playing (with the instrument changed).
    private mutating func dyterVoiceRow(_ a5: UInt32) {
        if peek8(a5 + 50) != 0 {
            poke8(a5 + 50, peek8(a5 + 50) &- 1)
            return
        }
        if peek8(Self.dyterLine + 3) & peek8(a5) == 0 {
            if peek16(Self.dyterRow) == 0 { letGo(a5) }
            return
        }
        let track = peek32(Self.dyterTrack)
        let pattern = UInt32(peek8(track)) * 0x180 &+ peek32(Self.dyterPatterns)
        poke32(Self.dyterPattern, pattern)
        let a3 = pattern &+ UInt32(peek16(Self.dyterRow)) * 6
        let instrument = peek8(a3 &+ 2)
        if instrument == 0 { return }
        var number = UInt16(instrument &- 1) &+ signedByte(peek8(track &+ 1))
        if negative(number) { number = 0 }
        poke8(a5 + 2, UInt8(truncatingIfNeeded: number))
        let a4 = dyterInstrument(number << 1)
        if peek8(a3 &+ 1) == 0 {
            if peek8(a3) == 0xFF { letGo(a5) }
            return
        }
        let volume = UInt32(signedByte(peek8(a3 &+ 1))) * UInt32(peek16(Self.dyterScale)) >> 6
        poke16(a5 + 48, UInt16(truncatingIfNeeded: volume))
        let note = UInt16(peek8(a3) &+ peek8(a4)) &+ signedByte(peek8(track &+ 2))
        poke8(a5 + 3, peek8(a3 &+ 3))
        poke8(a5 + 4, peek8(a3 &+ 4))
        poke8(a5 + 5, peek8(a3 &+ 5))
        dyterNote(a5, a4, note)
    }

    /// `L1144`: a note started: its period (`L11ee`, less the instrument's byte at 1), as the note's and to be
    /// told; the voice no longer let go, its envelope from its attack, and its effects from their starts: the
    /// waveform's sweep's count from the instrument's word at 8 (less one), the bend from its word at 10, the
    /// tremolo's table (`$127E`, by its byte at 26), delay (at 23) and speed (at 24), and the vibrato's (`$13FE`,
    /// by its byte at 31; at 28 and 29); and the voice to be started.
    private mutating func dyterNote(_ a5: UInt32, _ a4: UInt32, _ note: UInt16) {
        poke16(a5 + 46, note)
        let period = peek16(Self.dyterPeriodsAt &+ wide(note &+ note)) &- signedByte(peek8(a4 &+ 1))
        poke16(a5 + 6, period)
        poke16(a5 + 26, period)
        poke8(a5 + 1, 0)
        poke8(a5 + 9, 0)
        poke16(a5 + 10, 0)
        poke32(a5 + 12, 0)
        poke32(a5 + 16, 0)
        poke16(a5 + 20, 0)
        poke32(a5 + 28, 0)
        poke16(a5 + 32, 0)
        poke16(a5 + 42, 0)
        poke16(a5 + 44, 0)
        let sweep = peek16(a4 &+ 8)
        poke16(a5 + 40, sweep == 0 ? 0 : sweep &- 1)
        poke16(a5 + 38, peek16(a4 &+ 10))
        poke32(a5 + 22, Self.dyterTremolosAt &+ UInt32(peek8(a4 &+ 26)) << 6)
        poke8(a5 + 16, peek8(a4 &+ 23))
        poke8(a5 + 19, peek8(a4 &+ 24))
        poke32(a5 + 34, Self.dyterVibratosAt &+ UInt32(peek8(a4 &+ 31)) << 6)
        poke8(a5 + 28, peek8(a4 &+ 28))
        poke8(a5 + 31, peek8(a4 &+ 29))
        poke8(a5 + 8, 0xFF)
    }

    /// `Lac0`: the DMA of the voices started at the last tick turned on; each voice's instrument played
    /// (`Lb3a`), its loop told the tick after its start (`Lbc4`) and its start told (`Lb82`); and the DMA of the
    /// voices started at this tick turned off, to be turned on at the next.
    private mutating func dyterVoices<Output: TFMXOutput>(_ output: inout Output) {
        let old = peek16(Self.dyterOldBits)
        if old != 0 { poke16(0xDFF096, old | 0x8000, &output) }
        poke16(Self.dyterNewBits, 0)
        for (a5, a6) in Self.dyterVoices {
            let a4 = dyterInstrument(UInt16(bitPattern: Int16(Int8(bitPattern: peek8(a5 + 2) << 1))))
            dyterInstrument(a5, a6, a4, &output)
            loop(a5, a6, a4, heading: 34, &output)
            start(a5, a6, a4, heading: 34, bits: Self.dyterNewBits, &output)
            if failure != nil { return }
        }
        poke16(0xDFF096, peek16(Self.dyterNewBits), &output)
        poke16(Self.dyterOldBits, peek16(Self.dyterNewBits))
    }

    /// `Lb3a`: a voice's envelope (`Lc8c`, of the instrument's levels and speeds at 18 to 22), tremolo (`Ld62`),
    /// vibrato (`Ldd0`), bend (`Le34`) and waveform (`Lc04`); its volume told, the envelope's times the note's,
    /// over 64 (its low seven bits, as `L346` takes it), and its period.
    private mutating func dyterInstrument<Output: TFMXOutput>(_ a5: UInt32, _ a6: UInt32, _ a4: UInt32, _ output: inout Output) {
        envelope(a5, a4, attackLevel: 18, attackSpeed: 19, decaySpeed: 20, sustainLevel: 21, releaseSpeed: 22)
        dyterTremolo(a5, a4)
        dyterVibrato(a5, a4)
        bend(a5, a4, at: 38, speed: 12, target: 14, releaseSpeed: 16)
        dyterWaveform(a5, a6, a4, &output)
        let product = UInt16(truncatingIfNeeded: UInt32(peek16(a5 + 14)) * UInt32(peek16(a5 + 48))) >> 6
        poke16(a6 + 8, product & 0x7F, &output)
        poke16(a6 + 6, peek16(a5 + 26), &output)
    }

    /// `Ld62`: the tremolo, unless it is the instrument's to begin once the note is let go (its byte at 27) and
    /// it is not: after its delay (the voice's byte at 16, a word less $40 a tick), every so many ticks (its
    /// speed, the instrument's byte at 24, counted down at the voice's byte at 19 in steps of $40 of its word)
    /// its place (the word at 20) on by a word, round its table's 32; the table's word there, shifted down by the
    /// instrument's byte at 25, taken off the envelope's volume (no lower than nought).
    private mutating func dyterTremolo(_ a5: UInt32, _ a4: UInt32) {
        if peek8(a4 &+ 27) != 0, peek8(a5 + 1) == 0 {
            poke16(a5 + 14, peek16(a5 + 12))
            return
        }
        if peek8(a5 + 16) != 0 {
            poke16(a5 + 16, peek16(a5 + 16) &- 0x40)
            poke16(a5 + 14, peek16(a5 + 12))
            return
        }
        if !countDown(a5 + 18) {
            poke16(a5 + 18, 0)
            poke8(a5 + 19, peek8(a4 &+ 24))
            if peek8(a5 + 19) == 0 {
                poke16(a5 + 14, peek16(a5 + 12))
                return
            }
            poke16(a5 + 20, (peek16(a5 + 20) &+ 8) & 0x3E)
        }
        let a0 = peek32(a5 + 22)
        let d1 = a0 == 0 ? 0 : shiftedDown(peek16(a0 &+ wide(peek16(a5 + 20))), peek8(a4 &+ 25))
        let volume = peek16(a5 + 12)
        if volume == 0 {
            poke16(a5 + 14, volume)
            return
        }
        let d0 = volume &- d1
        poke16(a5 + 14, negative(d0) ? 0 : d0)
    }

    /// `Ldd0`: the vibrato, unless it is the instrument's to begin once the note is let go (its byte at 32) and
    /// it is not: after its delay (the voice's byte at 28), every so many ticks (its speed at 29, counted down
    /// at the voice's byte at 31) its place (the word at 32) on by a word, round its table's 32; the signed byte
    /// of the table's word there, shifted down by the instrument's byte at 30, added to the note's period as the
    /// period to be told.
    private mutating func dyterVibrato(_ a5: UInt32, _ a4: UInt32) {
        var d1: UInt16 = 0
        if peek8(a4 &+ 32) != 0, peek8(a5 + 1) == 0 {
        } else if peek8(a5 + 28) != 0 {
            poke16(a5 + 28, peek16(a5 + 28) &- 0x40)
        } else {
            var on = true
            if !countDown(a5 + 30) {
                poke16(a5 + 30, 0)
                poke8(a5 + 31, peek8(a4 &+ 29))
                if peek8(a5 + 31) == 0 {
                    on = false
                } else {
                    poke16(a5 + 32, (peek16(a5 + 32) &+ 8) & 0x3E)
                }
            }
            if on {
                let a0 = peek32(a5 + 34)
                if a0 != 0 {
                    let byte = UInt8(truncatingIfNeeded: peek16(a0 &+ wide(peek16(a5 + 32))))
                    d1 = shiftedDownSigned(UInt16(bitPattern: Int16(Int8(bitPattern: byte))), peek8(a4 &+ 30))
                }
            }
        }
        poke16(a5 + 26, d1 &+ peek16(a5 + 6))
    }

    /// A count (the word at `at`) less $40, and true if it is not below nought (`SUBI.W #$40; BGE`).
    private mutating func countDown(_ at: UInt32) -> Bool {
        let was = peek16(at)
        poke16(at, was &- 0x40)
        return Int32(Int16(bitPattern: was)) - 0x40 >= 0
    }

    /// `Lc04`: for a waveform (an instrument of no more than $80 bytes) with a sweep (its word at 8, the ticks
    /// to a step), where Paula plays it from in its bank of two halves of 256 bytes after its heading of 34:
    /// the place (the voice's word at 42) moved a step up to $7F and back down to nought, and so on (its way at
    /// 44), each step down taking one off the period to be told; its low bit the half, and the rest the byte
    /// in it. Told at every tick.
    private mutating func dyterWaveform<Output: TFMXOutput>(_ a5: UInt32, _ a6: UInt32, _ a4: UInt32, _ output: inout Output) {
        if Int16(bitPattern: peek16(a4 &+ 2)) > 0x80 { return }
        if peek16(a4 &+ 8) == 0 { return }
        let count = peek16(a5 + 40) &- 1
        poke16(a5 + 40, count)
        if negative(count) {
            poke16(a5 + 40, peek16(a4 &+ 8) &- 1)
            if peek16(a5 + 44) != 0 {
                poke16(a5 + 26, peek16(a5 + 26) &- 1)
                let place = peek16(a5 + 42) &- 1
                poke16(a5 + 42, place)
                if negative(place) {
                    poke16(a5 + 42, 0)
                    poke16(a5 + 44, ~peek16(a5 + 44))
                }
            } else {
                let place = peek16(a5 + 42) &+ 1
                poke16(a5 + 42, place)
                if Int16(bitPattern: place) > 0x7F {
                    poke16(a5 + 42, 0x7F)
                    poke16(a5 + 44, ~peek16(a5 + 44))
                }
            }
        }
        var a0 = a4 &+ 34
        var place = peek16(a5 + 42)
        if place & 1 != 0 { a0 &+= 256 }
        place &= ~1
        poke32(a6, a0 &+ wide(place), &output)
    }

    // MARK: Shared by the two routines

    /// The envelope (`L1bdc`, `Lc8c`; see `centerbaseEnvelope`), of the instrument's bytes at the offsets
    /// given. (Its levels are compared as signed bytes, the volume's low byte with them, as the routine has it.)
    private mutating func envelope(_ a5: UInt32, _ a4: UInt32, attackLevel: UInt32, attackSpeed: UInt32, decaySpeed: UInt32,
                                   sustainLevel: UInt32, releaseSpeed: UInt32)
    {
        let stage = peek8(a5 + 9)
        func spent() -> Bool {
            let count = peek16(a5 + 10) &- 2
            poke16(a5 + 10, count)
            return negative(count)
        }
        func level() -> Int8 { Int8(bitPattern: peek8(a5 + 13)) }
        switch stage {
        case 0:
            guard spent() else { return }
            poke16(a5 + 10, 0)
            poke8(a5 + 11, peek8(a4 &+ attackSpeed))
            if peek8(a5 + 11) != 0, level() < Int8(bitPattern: peek8(a4 &+ attackLevel)) {
                poke16(a5 + 12, peek16(a5 + 12) &+ 8)
                return
            }
            poke8(a5 + 9, stage &+ 1)
            poke32(a5 + 10, 0)
            poke8(a5 + 11, peek8(a4 &+ decaySpeed))
            poke8(a5 + 13, peek8(a4 &+ attackLevel))
        case 1:
            guard spent() else { return }
            poke16(a5 + 10, 0)
            poke8(a5 + 11, peek8(a4 &+ decaySpeed))
            if peek8(a5 + 11) != 0, level() > Int8(bitPattern: peek8(a4 &+ sustainLevel)) {
                poke16(a5 + 12, peek16(a5 + 12) &- 8)
                return
            }
            poke8(a5 + 9, stage &+ 1)
            poke16(a5 + 12, 0)
            poke8(a5 + 13, peek8(a4 &+ sustainLevel))
        case 2:
            if peek8(a5 + 1) != 0xFF { return }
            poke8(a5 + 9, stage &+ 1)
            poke16(a5 + 10, 0)
            poke8(a5 + 11, peek8(a4 &+ releaseSpeed))
        case 3:
            guard spent() else { return }
            poke16(a5 + 10, 0)
            poke8(a5 + 11, peek8(a4 &+ releaseSpeed))
            if peek8(a5 + 11) != 0, Int16(bitPattern: peek16(a5 + 12)) > 0 {
                poke16(a5 + 12, peek16(a5 + 12) &- 8)
                return
            }
            poke8(a5 + 9, stage &+ 1)
            poke16(a5 + 12, 0)
        default:
            // (Stage four, the envelope's end; no other is ever set.)
            break
        }
    }

    /// The bend (`L1df6`, `Le34`; see `centerbaseBend`), its word in the voice at `at` and the instrument's
    /// words at the offsets given.
    private mutating func bend(_ a5: UInt32, _ a4: UInt32, at: UInt32, speed: UInt32, target: UInt32, releaseSpeed: UInt32) {
        if negative(peek8(a5 + 1)) {
            var d0 = peek16(a4 &+ releaseSpeed)
            let d1 = peek16(a4 &+ target) &- peek16(a5 + at)
            if d1 != 0 {
                if negative(d1) { d0 = 0 &- d0 }
                poke16(a5 + at, peek16(a5 + at) &+ d0)
            }
        } else {
            var d0 = peek16(a4 &+ speed)
            let was = peek16(a5 + at)
            if was == 0 { return }
            if !negative(was) { d0 = 0 &- d0 }
            poke16(a5 + at, was &+ d0)
        }
        poke16(a5 + 26, peek16(a5 + 26) &- peek16(a5 + at))
    }

    /// `L1b94`, `Lbc4`: the tick after a voice's start (its byte at 8 $FE), its loop told: for a sample with
    /// none (the instrument's long at 4 nought), a length of one word, played from where it is; else the loop,
    /// from the word at 4 to the word at 6 of the sample after its heading.
    private mutating func loop<Output: TFMXOutput>(_ a5: UInt32, _ a6: UInt32, _ a4: UInt32, heading: UInt16, _ output: inout Output) {
        if peek8(a5 + 8) != 0xFE { return }
        poke8(a5 + 8, 0xFD)
        if peek32(a4 &+ 4) == 0 {
            poke16(a6 + 4, 1, &output)
            return
        }
        poke16(a6 + 4, (peek16(a4 &+ 6) &- peek16(a4 &+ 4)) >> 1, &output)
        poke32(a6, UInt32(heading &+ peek16(a4 &+ 4)) &+ a4, &output)
    }

    /// `L1b54`, `Lb82`: a voice started (its byte at 8 $FF): its bit for DMACON kept (at `bits`), to be turned
    /// off at the tick's end and on at the next, and Paula told its sample from after its heading, its length
    /// (the instrument's word at 2) or, for one with a loop, up to its loop's end (at 6).
    private mutating func start<Output: TFMXOutput>(_ a5: UInt32, _ a6: UInt32, _ a4: UInt32, heading: UInt32, bits: UInt32,
                                                    _ output: inout Output)
    {
        if peek8(a5 + 8) != 0xFF { return }
        poke8(a5 + 8, 0xFE)
        poke16(bits, peek16(bits) | UInt16(peek8(a5)))
        poke32(a6, a4 &+ heading, &output)
        let length = peek32(a4 &+ 4) == 0 ? peek16(a4 &+ 2) : peek16(a4 &+ 6)
        poke16(a6 + 4, length >> 1, &output)
    }

    /// A voice let go (`L20ce`, `L1102`): its byte at 1 set, and its envelope to its release.
    private mutating func letGo(_ a5: UInt32) {
        poke8(a5 + 1, 0xFF)
        poke8(a5 + 9, 2)
    }

    // MARK: The Amiga's memory and Paula's registers

    /// A byte of memory (24 bits of address, as the 68000 has; nought past the machine's memory, and from
    /// Paula's registers).
    private func peek8(_ address: UInt32) -> UInt8 {
        let at = Int(address & 0xFF_FFFF)
        return at < memoryCapacity ? memory[at] : 0
    }

    /// A word, or a long: at an odd address, the 68000 takes an address error, which would take the player
    /// down, and the song is stopped (`failure`).
    private mutating func peek16(_ address: UInt32) -> UInt16 {
        if address & 1 != 0 { failure = "the player read a word at an odd address" }
        let at = Int(address & 0xFF_FFFE)
        return at + 1 < memoryCapacity ? UInt16(memory[at]) << 8 | UInt16(memory[at + 1]) : 0
    }

    private mutating func peek32(_ address: UInt32) -> UInt32 {
        UInt32(peek16(address)) << 16 | UInt32(peek16(address &+ 2))
    }

    private mutating func poke8(_ address: UInt32, _ value: UInt8) {
        let at = Int(address & 0xFF_FFFF)
        if at >> 12 == 0xDFF { return }
        if at < memoryCapacity { memory[at] = value }
    }

    /// A word written: to Paula's registers (DMACON at $DFF096, a voice's from $DFF0A0), told to `output`; or
    /// to memory.
    private mutating func poke16<Output: TFMXOutput>(_ address: UInt32, _ value: UInt16, _ output: inout Output) {
        if address & 1 != 0 {
            failure = "the player wrote a word at an odd address"
            return
        }
        let at = Int(address & 0xFF_FFFE)
        if at >> 12 == 0xDFF {
            paula(UInt16(at & 0x1FE), value, &output)
        } else if at + 1 < memoryCapacity {
            memory[at] = UInt8(value >> 8)
            memory[at + 1] = UInt8(truncatingIfNeeded: value)
        }
    }

    private mutating func poke32<Output: TFMXOutput>(_ address: UInt32, _ value: UInt32, _ output: inout Output) {
        poke16(address, UInt16(value >> 16), &output)
        poke16(address &+ 2, UInt16(truncatingIfNeeded: value), &output)
    }

    private mutating func poke16(_ address: UInt32, _ value: UInt16) {
        var none = TFMXSilentOutput()
        poke16(address, value, &none)
    }

    private mutating func poke32(_ address: UInt32, _ value: UInt32) {
        var none = TFMXSilentOutput()
        poke32(address, value, &none)
    }

    /// A write to Paula's registers, as the hardware takes it: a voice's location (two words, its low bit not
    /// kept) and length are where it goes on from when it next comes round, or where it starts when its DMA is
    /// turned on; DMACON sets or clears the voices' bits as its top bit says.
    private mutating func paula<Output: TFMXOutput>(_ register: UInt16, _ value: UInt16, _ output: inout Output) {
        writes?.append((register, value))
        switch register {
        case 0x096:
            let was = dmacon
            dmacon = value & 0x8000 != 0 ? dmacon | value & 0xF : dmacon & ~(value & 0xF)
            for v in 0 ..< 4 {
                let bit: UInt16 = 1 << UInt16(v)
                if dmacon & bit != 0, was & bit == 0 { output.on(v) }
                if dmacon & bit == 0, was & bit != 0 { output.off(v) }
            }
        case 0x0A0 ..< 0x0E0:
            let v = Int(register - 0xA0) >> 4
            switch register & 0xF {
            case 0x0:
                locations[v] = locations[v] & 0xFFFF | UInt32(value) << 16
                tellBuffer(v, &output)
            case 0x2:
                locations[v] = locations[v] & 0xFFFF_0000 | UInt32(value & 0xFFFE)
                tellBuffer(v, &output)
            case 0x4:
                lengths[v] = value
                tellBuffer(v, &output)
            case 0x6:
                paulaPeriods[v] = value
            case 0x8:
                paulaVolumes[v] = value
            default:
                break
            }
        default:
            break
        }
    }

    private func tellBuffer<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        // (Chip memory is two megabytes at most; a location past the machine's is read as nothing.)
        let at = Int(locations[v] & 0x1F_FFFE)
        output.takeNextBuffer(v, start: min(at, memoryCapacity), length: lengths[v])
    }

    /// Paula's period for the voice, and her volume, as the player last wrote them.
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] }

    // MARK: The player's hunk

    /// The player's hunk, as siday has it: its tables at their places (the rest of its code is not there,
    /// read as nought), and the variables it starts with that are not nought (Dyter-07's routine's count of
    /// ticks and their speed, `Le78` and `Le7a`, one and six; its scale of a note's volume, `L89c`, 64; and its
    /// table of its songs' first positions, `L8aa`).
    static let hunk: [UInt8] = {
        var hunk = [UInt8](repeating: 0, count: hunkSize)
        func word(_ at: Int, _ value: UInt16) {
            hunk[at] = UInt8(value >> 8)
            hunk[at + 1] = UInt8(truncatingIfNeeded: value)
        }
        word(0xE78, 1)
        word(0xE7A, 6)
        word(0x89C, 64)
        for (i, start) in dyterStarts.enumerated() { word(0x8AA + 4 * i + 2, start) }
        for (i, period) in periods.enumerated() {
            word(0x11EE + 2 * i, period)
            word(0x21FA + 2 * i, period)
        }
        for (k, table) in Tables.tremolos.enumerated() {
            for (i, value) in table.enumerated() { word(0x127E + 64 * k + 2 * i, value) }
        }
        for (k, table) in Tables.vibratos.enumerated() {
            for (i, value) in table.enumerated() { word(0x13FE + 64 * k + 2 * i, UInt16(UInt8(bitPattern: value))) }
        }
        for (k, table) in Tables.waves.enumerated() {
            for (i, value) in table.enumerated() { hunk[0x228A + 128 * k + i] = UInt8(bitPattern: value) }
        }
        return hunk
    }()

    /// The routines' table of periods (`L11ee`, the same as `L21fa`): six octaves, from four times the Amiga's
    /// lowest C's of ProTracker's table, its own (with 760, 680, 572, 540 and 452 where ProTracker has 762, 678,
    /// 570, 538 and 453).
    static let periods: [UInt16] = [
        0xD60, 0xCA0, 0xBE8, 0xB40, 0xA98, 0xA00, 0x970, 0x8E8, 0x868, 0x7F0, 0x780, 0x714,
        0x6B0, 0x650, 0x5F4, 0x5A0, 0x54C, 0x500, 0x4B8, 0x474, 0x434, 0x3F8, 0x3C0, 0x388,
        0x358, 0x328, 0x2F8, 0x2D0, 0x2A8, 0x280, 0x25C, 0x23C, 0x21C, 0x1FC, 0x1E0, 0x1C4,
        0x1AC, 0x194, 0x17C, 0x168, 0x154, 0x140, 0x12E, 0x11E, 0x10E, 0xFE, 0xF0, 0xE2,
        0xD6, 0xCA, 0xBE, 0xB4, 0xAA, 0xA0, 0x97, 0x8F, 0x87, 0x7F, 0x78, 0x71,
        0x6B, 0x65, 0x5F, 0x5A, 0x55, 0x50, 0x4B, 0x47, 0x43, 0x3F, 0x3C, 0x38,
    ]
}

/// Karsten Obarski's Synth Pack, played on Paula by `PaulaTickRenderer`.
extension SynthPackPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Synth Pack")
        info.author = "Karsten Obarski"
        let plural = instrumentCount == 1 ? "" : "s"
        info.detail = (form == .centerbase ? "Centerbase's routine" : "Dyter-07's routine") + "; \(instrumentCount) instrument\(plural)"
        return info
    }

    /// Synth Pack's music is louder on the Amiga's chip than ProTracker's is, by 6.0 dB in the middle of the
    /// seventeen songs of it in UnExoticA's collection (by BS.1770 loudness, over their first minute, against
    /// 40 ProTracker modules), and is turned down by that (2026-10-25).
    var gain: Float { 0.24 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}

// The 68000's registers as the routines use them.
/// A word as the 68000 takes it as an index or a displacement: sign-extended to a long.
private func wide(_ value: UInt16) -> UInt32 { UInt32(bitPattern: Int32(Int16(bitPattern: value))) }
/// A byte sign-extended to a word (`EXT.W`).
private func signedByte(_ value: UInt8) -> UInt16 { UInt16(bitPattern: Int16(Int8(bitPattern: value))) }
/// The 68000's N flag of a result: its top bit.
private func negative(_ value: UInt8) -> Bool { value & 0x80 != 0 }
private func negative(_ value: UInt16) -> Bool { value & 0x8000 != 0 }
/// `LSR.W` and `ASR.W` by a register: by its count modulo 64.
private func shiftedDown(_ value: UInt16, _ count: UInt8) -> UInt16 {
    let n = Int(count & 63)
    return n >= 16 ? 0 : value >> n
}

private func shiftedDownSigned(_ value: UInt16, _ count: UInt8) -> UInt16 {
    UInt16(bitPattern: Int16(bitPattern: value) >> min(Int(count & 63), 15))
}
