// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Jason Page's sound driver for Graftgold's games of 1991 to 1994, as Mr.Larmer of Wanted Team and
// PP of Union adapted it for EaglePlayer ("Jason Page player module V1.3 (26 June 2001)", carried by UADE as
// players/JasonPage, whose source UADE also carries as amigasrc/players/wanted_team/JasonPage/src/Jason
// Page_v5.s). The labels given are that source's.

import SidayChips
import SidayFoundation

/// Jason Page's music for Graftgold's games, in the second of their formats for the Amiga (the first is
/// Steve Turner's, `SteveTurnerPlayer`, which this shares nothing with): a score, `title.jpn`, and its
/// samples in a file of their own beside it, `title.smp`. Wanted Team's player has three replay routines
/// for it, each taken from a game: Realms' of 1991 (`Kind.first`), Empire Soccer 94's for the form Fire &
/// Ice, Uridium 2 and Empire Soccer 94 have (`Kind.second`), and ViroCop's (`Kind.third`, Lee Banyard's
/// music of 1995, which siday does not play: there is none of it in UnExoticA's collection to check it by).
///
/// The two forms are laid out differently (the first by a table of longs, made places in memory as the
/// song starts, the second by a table of words, each an offset from the score's start), but play alike. A
/// song is four lists of words, one for each voice: a pattern and how far its notes are moved, or the
/// list's end and the entry to go back to (`$FE`, or `$FC`), an entry to pass by (`$FD`), and the song's
/// end (`$FF`). A pattern is bytes: notes, each with the instrument it begins (one taken by priority, from
/// a table: a note of a lower one than the voice's is not begun); the instrument and the speed (in steps
/// of the song's speed) of the notes that follow; a slide, a rest and the pattern's end. An instrument is a
/// list of commands of a word each, read by its voice every so many ticks: a sample (from the score's
/// table of them, in the file of samples), its length and where in it the voice plays, a period, a
/// volume, an envelope, a vibrato, a wait, a loop, the voice's DMA on and off, and the copying of one
/// sample onto another or the moving of one towards another a step at a time, as a waveform.
///
/// This is the routine as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It owns the memory Paula plays from: the player's own variables that are
/// read through what the score points at (its four voices, `voicesAt`; its table of periods, `periodsAt`;
/// its list of commands for a voice with nothing to play, `idleAt`; its two words of silence, `emptyAt`),
/// the score at `moduleAt` and its samples after it, as the player's are in UADE's memory. Its tick is
/// EaglePlayer's (`DTP_Interrupt`: the routine sets no timer of its own), which UADE runs on a CIA's timer
/// from $376B, its count for fifty a second (score.s, `cia_timer_base_value`): 70,940 of Paula's clocks.
/// A song comes to its end when each of its voices has gone back in its list (the player's
/// `SongEndTest`), and stops at its end (`$FF`), where Wanted Team's player starts it again (`InitSound`);
/// its length is found by playing it through in silence.
struct JasonPagePlayer: ~Copyable {
    /// The player's three routines (see the type's comment), by the order in which Wanted Team's notes
    /// give the forms; their own numbers for them (`Format`) are 3, 1 and 2.
    enum Kind {
        case first, second, third
    }

    let kind: Kind
    /// True for Realms' ingame tune, which `InitPlayer` changes (see `patchRealms`).
    private let isRealmsIngame: Bool
    /// The memory Paula plays from: the Amiga's from nought, past the samples.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// The score and its samples as they were given, put back at each song's start (the player changes
    /// both as it plays).
    private let module: [UInt8]
    private let samples: [UInt8]

    /// The player's table of periods (`lbW0002A0`, `lbW002000`, 84 words) and the two words of its code
    /// that follow it (the start of `Play_1` and `Play_3`, the same in both): a note of 84, as high as
    /// either lets a note go, reads the first of them.
    static let periodsAt: UInt32 = 0x1000
    /// The player's four voices, of $5C bytes each (`lbW000130`, `lbW003746`).
    static let voicesAt: UInt32 = 0x1100
    static let voiceSize: UInt32 = 0x5C
    /// The commands a voice with nothing to play reads (`lbL000D0C`, `lbL00373A`), and the silence it plays
    /// (`Empty`, four bytes of the player's own in chip memory).
    static let idleAt: UInt32 = 0x1280
    static let emptyAt: UInt32 = 0x12C0
    /// Where the score is put (siday's choice: its pointers are to its own start, or made so as it starts),
    /// and its samples after it, at the next eight bytes.
    static let moduleAt: UInt32 = 0x2000
    let samplesAt: UInt32
    /// Room after the samples, read as silence by a voice told a length that runs past them.
    private static let room = 0x20000 + 2048

    var silenceAt: Int { Int(Self.emptyAt) }
    var mixingAt: Int { Int(samplesAt) + samples.count + 1024 }

    private(set) var songCount = 1
    private(set) var song = 0
    /// The samples the player's module information counts (`InitPlayer`).
    private(set) var sampleCount = 0

    // The places the routine works from (the second form's `lbL000064` to `lbL000050`, the first's
    // `lbL002D90` to `lbL002DC0`): the table of samples' places; of the instruments' lists (the second
    // form's offsets, from `instrumentBase`; the first's places); of each song's speed; of each
    // instrument's priority; of the patterns (as the instruments'); and of each voice's lists (the second
    // form's offsets for each song from `listBases`, the first's places for each song).
    private var sampleTable: UInt32 = 0
    private var instrumentTable: UInt32 = 0
    private var instrumentBase: UInt32 = 0
    private var speedTable: UInt32 = 0
    private var priorityTable: UInt32 = 0
    private var patternTable: UInt32 = 0
    private var patternBase: UInt32 = 0
    private var songLists = InlineArray<4, UInt32>(repeating: 0)
    private var listBases = InlineArray<4, UInt32>(repeating: 0)
    /// Each voice's list for the song playing (`lbL00006C`, `lbL0025A0`).
    private var lists = InlineArray<4, UInt32>(repeating: 0)
    /// The song playing, negative once it has ended (`lbW00008E`, `lbW002DE0`); how many ticks to a step,
    /// and those left of this one (`lbW000096` and `lbW000094`, `lbW002DDE` and `lbW002DDC`); and the
    /// entry a list's `$FC` or `$FD` goes to, which is never set, and its copy (`lbW000082`, `lbW000084`).
    private var playing: UInt16 = 0xFFFF
    private var speed: UInt16 = 0
    private var speedCount: UInt16 = 0
    private var jump: UInt16 = 0xFFFF
    private var jumpNow: UInt16 = 0xFFFF
    /// The loudest the voices go, the speed it moves towards its target by, and the target (the second
    /// form's `lbB000091` to `lbB000093`; the first's `lbB002DD7`, `lbW002DDA` and `lbB002DDB`): set at
    /// the song's start to go to 255 at once.
    private var master: UInt8 = 0
    private var masterSpeed: UInt8 = 0
    private var masterTarget: UInt8 = 0
    /// The bytes `SongEndTest` clears as each voice goes back in its list.
    private var songEndFlags = InlineArray<4, UInt8>(repeating: 0x57)

    // Paula's registers as the player has written them.
    private var locations = InlineArray<4, UInt32>(repeating: 0)
    private var lengths = InlineArray<4, UInt16>(repeating: 0)
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)
    private var dmacon: UInt16 = 0

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// Why the song stopped other than at its end, if it did.
    private(set) var failure: String?
    /// For checks: each write the player made to Paula's registers in the tick just run (the register's
    /// offset, $A0 to $D8 or DMACON's $96, and the word written), when this is not nil; and those its
    /// song's start made.
    var writes: [(register: UInt16, value: UInt16)]?
    private(set) var startWrites: [(register: UInt16, value: UInt16)] = []

    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in a quarter of an hour is taken never to: longer than any of
    /// UnExoticA's (the longest, Realms' intro and title, 82 patterns of 384 ticks, ten and a half minutes),
    /// and than UADE plays a song that does not end (512 seconds).
    private static let mostTicks = 900 * 50
    /// The most commands a voice reads in a tick, and the most bytes of its lists and patterns it reads in
    /// a step, more than any file's have between two notes: a voice that goes round without one would hang
    /// the player (its tick would never end), and the song is stopped there (siday's choice).
    private static let mostCommands = 4096
    /// The songs the player offers. The second form's start takes a song's number in four bits
    /// (`lbC00049A`), its sixteenth and those after it being the first again; and of the first form's
    /// table of lists, room for 32 songs (siday's choice: the player counts on until a list that is empty).
    private static let mostSongs = 16
    private static let mostFirstSongs = 32

    // MARK: The check

    /// Which form a file is, by the player's check (`Check2`): of the second or third, one beginning
    /// with the word 2, its 23 words from 2 even, more than nought and less than the word at $30 (the
    /// score's length), the word at the offset of the first (that of the instruments' table) nought; and
    /// the second if the word at the place the word at $2E gives (a pattern's first) has its second four
    /// bits all set ($F00). Of the first, one beginning with the word nought, with nought at $80, the
    /// offset $CBE at $84 (that of the first instrument), and $308BE and $309BE at $CB6 and $CBA. (Read
    /// past the file, or before it, a word fails the check.)
    static func kind(of data: [UInt8]) -> Kind? {
        func word(_ at: Int) -> Int? { at >= 0 && at + 1 < data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : nil }
        func long(_ at: Int) -> Int? { word(at).flatMap { high in word(at + 2).map { high << 16 | $0 } } }
        if word(0) == 2, let three = word(2), three & 1 == 0, let first = word(4), first & 1 == 0,
           word(Int(Int16(truncatingIfNeeded: first))) == 0, let length = word(0x30)
        {
            var passes = true
            for i in 0 ..< 23 {
                guard let w = word(2 + 2 * i), w != 0, w & 1 == 0, Int16(truncatingIfNeeded: length) > Int16(truncatingIfNeeded: w) else {
                    passes = false
                    break
                }
            }
            if passes, let place = word(0x2E), let pattern = word(place) { return pattern & 0x0F00 == 0x0F00 ? .second : .third }
        }
        if word(0) == 0, long(0x80) == 0, long(0x84) == 0xCBE, long(0xCB6) == 0x308BE, long(0xCBA) == 0x309BE { return .first }
        return nil
    }

    static func isOne(_ data: [UInt8]) -> Bool { kind(of: data) != nil }

    // MARK: Making

    /// Reads the score and its samples and starts song `song` (counting from nought).
    init(_ data: [UInt8], samples: [UInt8], song: Int = 0) throws(TuneError) {
        let found = Self.kind(of: data)
        kind = found ?? .second
        isRealmsIngame = found == .first && data.count >= 2238
            && (UInt32(data[2234]) << 24 | UInt32(data[2235]) << 16 | UInt32(data[2236]) << 8 | UInt32(data[2237])) &+ 2 == 7382
        module = data
        self.samples = samples
        samplesAt = (Self.moduleAt + UInt32(data.count) + 7) & ~7
        memoryCapacity = Int(samplesAt) + samples.count + Self.room
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        func word(_ at: Int) -> UInt32 { at >= 0 && at + 1 < data.count ? UInt32(data[at]) << 8 | UInt32(data[at + 1]) : 0 }
        func long(_ at: Int) -> UInt32 { word(at) << 16 | word(at + 2) }
        var songs = 1, count = 0
        putBack()
        let form = kind
        switch form {
        case .second, .third:
            // (`InitPlayer`) The samples, the places in their table from the word at 2 up to the long before
            // the score's end (the word at 48), less those of nought; and the songs, the words of the first
            // voice's table of them (at the word at 12) up to its table of lists (at the word at 28), less one.
            let end = Int(word(48)) - 4
            var at = Int(word(2))
            while at < end, count < 4096 {
                if long(at) != 0 { count += 1 }
                at += 4
            }
            let from = Int32(Int16(truncatingIfNeeded: word(0xC))) + 2, to = Int32(Int16(truncatingIfNeeded: word(0x1C)))
            let n = UInt32(bitPattern: to &- from) >> 1
            songs = Int(min(UInt32(Self.mostSongs), max(1, n)))
        case .first:
            // The samples, those of the 32 places in their table that are not the next one's, and one more;
            // and the songs, after the change to Realms' ingame tune (see `patchRealms`), counted up to the
            // first whose first voice's list is empty (its first word $FF00).
            for i in 0 ..< 31 where long(4 * i + 4) != long(4 * i) { count += 1 }
            count += 1
            if isRealmsIngame { patchRealms() }
            songs = 0
            while songs < Self.mostFirstSongs {
                let offset = peek32(Self.moduleAt + 0x6BE + UInt32(4 * songs))
                if offset & 1 != 0 { break }
                if peek16(Self.moduleAt &+ offset) == 0xFF00 { break }
                songs += 1
            }
            failure = nil
        }
        sampleCount = count
        songCount = max(1, songs)
        self.song = 0
        // (Refused only once it is all made.)
        guard found != nil else { throw TuneError.malformed("not Jason Page's music: the player's check does not take it") }
        guard kind != .third else {
            throw TuneError.unsupported("ViroCop's music, the third form of Jason Page's player, which siday does not play")
        }
        begin(song)
    }

    deinit { memory.deallocate() }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        begin(song)
    }

    /// The fix Wanted Team's `InitPlayer` makes to Realms' ingame tune (a score of 7,382 bytes, by the long
    /// at 2234 and two), which is one long song, played in parts in the game: each place in its first
    /// voice's list where it goes back or on (`$FC`, `$FD` or `$FE`) made its end, and the place after it the
    /// start of a song of its own, for each voice (whose lists are each 194 bytes after the one before).
    private mutating func patchRealms() {
        let base = Self.moduleAt
        var a1 = base &+ peek32(base + 1726), a3 = base
        for _ in 0 ..< 4096 {
            let high = peek8(a1)
            if high == 0xFC || high == 0xFE || high == 0xFD {
                for _ in 0 ..< 4 {
                    poke32(a3 + 1730, a1 &- base &+ 2)
                    poke16(a1, 0xFF00)
                    a1 &+= 194
                    a3 &+= 128
                }
                a1 &-= 776
                a3 &-= 508
            } else if peek16(a1) == 0xFF00 {
                break
            }
            a1 &+= 2
        }
    }

    /// The score and its samples put back as they were given, with the fixes `InitPlayer` makes to them;
    /// and the player's variables as its hunk has them.
    private mutating func putBack() {
        let module = Int(Self.moduleAt), samples = Int(samplesAt)
        memory.update(repeating: 0, count: memoryCapacity)
        for (i, byte) in self.module.enumerated() { memory[module + i] = byte }
        for (i, byte) in self.samples.enumerated() { memory[samples + i] = byte }
        for (i, period) in Self.periods.enumerated() { poke16(Self.periodsAt + UInt32(2 * i), period) }
        let idle: [UInt16] = kind == .first ? [0x18, 0, 0x48, 0x1C, 0, 0] : [0xF, 0, 0x13, 0, 0, 0, 0, 6, 0, 0x12, 7, 0]
        for (i, word) in idle.enumerated() { poke16(Self.idleAt + UInt32(2 * i), word) }
        // Each voice: its commands the idle ones, $2E (its volume) $800, $900, $A00 and nought, $40 (its
        // instrument to begin) and the envelope's four words at $46 none, its two counts of steps at $56
        // one, and its number, times two, at $5A.
        for v in 0 ..< 4 {
            let voice = Self.voicesAt + UInt32(v) * Self.voiceSize
            poke32(voice + 2, Self.idleAt)
            poke16(voice + 0x2E, v < 3 ? UInt16(0x800 + 0x100 * v) : 0)
            for offset: UInt32 in [0x40, 0x46, 0x48, 0x4A, 0x4C] { poke16(voice + offset, 0xFFFF) }
            poke16(voice + 0x56, 0x0101)
            poke16(voice + 0x5A, UInt16(2 * v))
        }
        if kind != .first {
            // A byte that `InitPlayer` makes $FF in four scores, by their lengths (the word at 48): in Empire
            // Soccer 94's, of 7,452 bytes, an entry of its first voice's list, which makes its fifth song stop
            // after its four patterns, where the score has it run on into the sixth's; and in three of
            // ViroCop's, of 7,054, 6,736 and 6,260 bytes.
            let fixes: [UInt32: UInt32] = [7452: 1956, 7054: 3490, 6736: 3604, 6260: 4088]
            if let at = fixes[UInt32(peek16(Self.moduleAt + 48))] { poke8(Self.moduleAt + at, 0xFF) }
        }
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

    /// The memory and Paula's registers as they were, and `InitSound` for the song.
    private mutating func initialise() {
        putBack()
        if isRealmsIngame { patchRealms() }
        locations = .init(repeating: 0)
        lengths = .init(repeating: 0)
        paulaPeriods = .init(repeating: 0)
        paulaVolumes = .init(repeating: 0)
        dmacon = 0
        endings = 0
        stops = 0
        failure = nil
        songEndFlags = .init(repeating: 0x57)
        master = 0
        jump = 0xFFFF
        jumpNow = 0xFFFF
        let logging = writes
        writes = []
        var none = TFMXSilentOutput()
        if kind == .first { startFirst(&none) } else { startSecond() }
        startWrites = writes ?? []
        writes = logging
    }

    /// `Initialize_1_1`, `Initialize_1_2` and `Initialize_1_3`, for the second form: the places of its
    /// tables, from the offsets in its first 25 words; the samples' table made the samples' places in
    /// memory (`lbC0003FC`), each after the one before by the length it had there; the song's speed and its
    /// voices' lists (`lbC00049A`, its number taken in four bits); each voice started on its idle commands,
    /// at the start of its list; and the loudest the voices go set to go to 255 at once.
    private mutating func startSecond() {
        let base = Self.moduleAt
        func at(_ offset: UInt32) -> UInt32 { base &+ wide(peek16(base + offset)) }
        sampleTable = at(2)
        instrumentTable = at(4)
        instrumentBase = at(6)
        speedTable = at(8)
        priorityTable = at(10)
        for v in 0 ..< 4 {
            songLists[v] = at(12 + UInt32(2 * v))
            listBases[v] = at(28 + UInt32(2 * v))
        }
        patternTable = at(44)
        patternBase = at(46)
        // ($3FC) Once, as the score's first byte's top bit says, which it then sets.
        var count = (peek16(base + 48) &- peek16(base + 2)) >> 2
        if peek8(base) & 0x80 == 0 {
            poke8(base, peek8(base) | 0x80)
            var a1 = sampleTable, a0 = samplesAt
            while count > 0 {
                let length = peek32(a1)
                poke32(a1, a0)
                a1 &+= 4
                a0 &+= length
                count -= 1
            }
        }
        playing = 0xFFFF
        let number = UInt32(song & 15) * 2
        jump = 0xFFFF
        speed = peek16(speedTable &+ number) & 0xFF
        speedCount = 0
        for v in 0 ..< 4 { lists[v] = listBases[v] &+ wide(peek16(songLists[v] &+ number)) }
        for v in 0 ..< 4 {
            let voice = Self.voicesAt + UInt32(v) * Self.voiceSize
            poke32(voice + 2, Self.idleAt)
            for offset: UInt32 in [0x50, 0x52, 0x54, 0x56, 0x44] { poke16(voice + offset, 0) }
            poke16(voice + 0x40, 0xFFFF)
        }
        playing = UInt16(song)
        masterSpeed = 0xFF
        masterTarget = 0xFF
    }

    /// `Initialize_3_1`, `Initialize_3_2` and `Initialize_3_3`, for the first form: the places of its tables
    /// (the samples' at its start, the instruments' at $84, the songs' speeds at $480, the instruments'
    /// priorities at $4C0, the voices' lists of each song at $6BE, $73E, $7BE and $83E, the patterns' at
    /// $8BE), the offsets in them made places, and the samples' table made their places in memory, from
    /// the first; the song's speed and lists, its voices started on their idle commands at the start of
    /// their lists; Paula's volumes nought and the Amiga's filter off (`lbC00227A`); and the loudest the
    /// voices go set to go to 255 at once.
    private mutating func startFirst<Output: TFMXOutput>(_ output: inout Output) {
        let base = Self.moduleAt
        sampleTable = base
        instrumentTable = base + 0x84
        speedTable = base + 0x480
        priorityTable = base + 0x4C0
        for v in 0 ..< 4 { songLists[v] = base + 0x6BE + 0x80 * UInt32(v) }
        patternTable = base + 0x8BE
        if peek16(base) == 0 {
            for (table, count) in [(songLists[0], 128), (instrumentTable, 255), (patternTable, 254)] {
                for i in 0 ..< UInt32(count) { poke32(table + 4 * i, peek32(table + 4 * i) &+ base) }
            }
            let first = peek32(base)
            for i in 0 ..< UInt32(32) { poke32(base + 4 * i, peek32(base + 4 * i) &- first &+ samplesAt) }
        }
        let number = UInt32(song) & 0xFFFF
        playing = 0xFFFF
        jump = 0xFFFF
        speed = peek16(speedTable &+ wide(UInt16(truncatingIfNeeded: number * 2)))
        speedCount = 0
        for v in 0 ..< 4 { lists[v] = peek32(songLists[v] &+ wide(UInt16(truncatingIfNeeded: number * 4))) }
        for v in 0 ..< 4 {
            let voice = Self.voicesAt + UInt32(v) * Self.voiceSize
            poke32(voice + 2, Self.idleAt)
            for offset: UInt32 in [0x50, 0x54] { poke16(voice + offset, 0) }
            for offset: UInt32 in [0x52, 0x53, 0x56, 0x57] { poke8(voice + offset, 0) }
            poke16(voice + 0x44, 0)
            poke16(voice + 0x40, 0xFFFF)
        }
        for v in 0 ..< 4 { poke16(0xDFF0A8 + 16 * UInt32(v), 0, &output) }
        playing = 0
        masterSpeed = 0xFF
        masterTarget = 0xFF
    }

    // MARK: Playing

    /// The player's `DTP_Interrupt` (`Interrupt`): the routine's tick (`Play_1`, `Play_3`), its steps and
    /// then its voices; and at the song's end, Wanted Team's player's starting it again, which is not heard.
    /// Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if writes != nil { writes = [] }
        if failure == nil {
            steps(&output)
            if failure == nil { voices(&output) }
        }
        if stops == 0 {
            if playing & 0x8000 != 0 {
                endings += 1
                stops += 1
            } else if failure != nil {
                stops += 1
            }
        }
        return Self.tickClocks * 1000 / 3_546_895
    }

    /// The song's steps (`lbC00074C`, `Play_3_2`), every so many ticks while it plays: for each voice whose
    /// count of steps has run out (it is taken again from its speed), its pattern read on from where it is,
    /// up to its next note or rest; and at the pattern's end, its list read on. A note begins its voice's
    /// instrument, if its priority lets it (and its instrument is not $78, which changes the note alone),
    /// and its period is that of the note and the list's transposition, from the player's table (no higher
    /// than its 84th: `$54`).
    private mutating func steps<Output: TFMXOutput>(_ output: inout Output) {
        if playing & 0x8000 != 0 { return }
        speedCount &-= 1
        if speedCount & 0x8000 == 0 { return }
        speedCount = speed
        jumpNow = jump
        for d3 in 0 ..< 4 {
            let a2 = Self.voicesAt + UInt32(d3) * Self.voiceSize
            let count = peek8(a2 + 0x56) &- 1
            poke8(a2 + 0x56, count)
            if count & 0x80 == 0 { continue }
            poke8(a2 + 0x56, peek8(a2 + 0x57))
            var read = 0
            position: while true {
                read += 1
                if read > Self.mostCommands {
                    failure = "a voice's list and patterns go round without a note"
                    return
                }
                let entry = peek16(lists[d3] &+ wide(peek16(a2 + 0x50)))
                if failure != nil { return }
                poke8(a2 + 0x53, UInt8(truncatingIfNeeded: entry))
                let high = UInt8(entry >> 8)
                var to: UInt16?
                switch high {
                case 0xFF:
                    playing = 0xFFFF
                    return
                case 0xFE:
                    songEndTest(a2)
                    to = UInt16(peek8(a2 + 0x53))
                case 0xFC:
                    if jumpNow == 0xFFFF {
                        songEndTest(a2)
                        to = UInt16(peek8(a2 + 0x53))
                    } else {
                        jump = 0xFFFF
                        to = jumpNow
                    }
                case 0xFD:
                    if jumpNow == 0xFFFF {
                        poke16(a2 + 0x50, peek16(a2 + 0x50) &+ 2)
                        continue position
                    }
                    jump = 0xFFFF
                    to = jumpNow
                default:
                    break
                }
                if let to {
                    poke16(a2 + 0x50, (to & 0xFF) &* 2)
                    continue position
                }
                // The pattern: by its offset (the second form) or its place (the first).
                let pattern = kind == .first ? peek32(patternTable &+ UInt32(high) * 4)
                    : patternBase &+ wide(peek16(patternTable &+ UInt32(high) * 2))
                if failure != nil { return }
                while true {
                    read += 1
                    if read > Self.mostCommands {
                        failure = "a voice's list and patterns go round without a note"
                        return
                    }
                    let place = UInt32(peek8(a2 + 0x52))
                    let byte = peek8(pattern &+ place)
                    if byte == 0xFF {
                        // The pattern's end: the list's next entry.
                        poke8(a2 + 0x52, 0)
                        poke16(a2 + 0x50, peek16(a2 + 0x50) &+ 2)
                        continue position
                    }
                    if byte == 0xF9 {
                        // A rest.
                        poke8(a2 + 0x52, peek8(a2 + 0x52) &+ 1)
                        break position
                    }
                    if byte == 0xFE {
                        // A slide, the word after it added to the period at every tick.
                        let slide = UInt16(peek8(pattern &+ place &+ 1)) << 8 | UInt16(peek8(pattern &+ place &+ 2))
                        poke16(a2 + 0x2C, slide)
                        poke8(a2 + 0x52, peek8(a2 + 0x52) &+ 3)
                        break position
                    }
                    if byte & 0x80 != 0 {
                        // The instrument of the notes that follow.
                        poke16(a2, UInt16(byte & 0x7F))
                        poke8(a2 + 0x52, peek8(a2 + 0x52) &+ 1)
                        continue
                    }
                    if byte & 0x40 != 0 {
                        // Their speed.
                        poke8(a2 + 0x57, byte & 0x3F)
                        poke8(a2 + 0x56, byte & 0x3F)
                        poke8(a2 + 0x52, peek8(a2 + 0x52) &+ 1)
                        continue
                    }
                    // A note.
                    let instrument = peek16(a2)
                    if instrument == 0x78 || ask(instrument, voice: d3) {
                        var note = (UInt32(byte) &+ UInt32(peek8(a2 + 0x53))) & 0xFF
                        if Int8(bitPattern: UInt8(note)) >= 0x54 { note = 0x54 }
                        poke16(a2 + 0x54, UInt16(note))
                        let index = kind == .first ? note * 2 : note * 2 & 0xFF
                        poke16(a2 + 0x2A, peek16(Self.periodsAt + index))
                    }
                    poke8(a2 + 0x52, peek8(a2 + 0x52) &+ 1)
                    break position
                }
            }
        }
    }

    /// An instrument asked for by a note (`lbC000678`, `lbC002340`): if its priority, from the score's table
    /// of them (the second form's, of a byte each, the first's of a word), is no lower than the voice's, it
    /// is the voice's to begin at its next tick (`$40`), its priority the voice's, and true; false if not.
    private mutating func ask(_ instrument: UInt16, voice: Int) -> Bool {
        if instrument & 0xFF == 0xFF { return false }
        let a0 = Self.voicesAt + UInt32(voice) * Self.voiceSize
        let priority = kind == .first ? peek16(priorityTable &+ wide(instrument &* 2))
            : peek16(priorityTable &+ UInt32(UInt8(truncatingIfNeeded: instrument &* 2))) & 0xFF
        if priority < peek16(a0 + 0x44) { return false }
        poke16(a0 + 0x44, priority)
        poke16(a0 + 0x40, kind == .first ? instrument : instrument & 0xFF)
        poke16(a0 + 0x42, instrument >> 8)
        return true
    }

    /// The voices' tick (`lbC0008EE`, `Play_3_3`): the loudest they go moved towards its target (the
    /// second form's, here; the first's, as each voice's registers are told); and for each voice, an
    /// instrument asked for begun, its commands read if its wait is over, up to one that ends its tick, its
    /// vibrato, its slide, its envelope, and Paula told its volume, its sample and its period (the second
    /// form's, after all four have done the rest).
    private mutating func voices<Output: TFMXOutput>(_ output: inout Output) {
        if kind == .second, masterSpeed != 0 {
            var d0 = Int(master)
            let target = Int(masterTarget), step = Int(masterSpeed)
            if d0 < target {
                d0 += step
                if d0 >= target {
                    d0 = target
                    masterSpeed = 0
                }
            } else {
                d0 -= step
                if d0 <= target {
                    d0 = target
                    masterSpeed = 0
                }
            }
            master = UInt8(truncatingIfNeeded: d0)
        }
        for d3 in 0 ..< 4 {
            let a2 = Self.voicesAt + UInt32(d3) * Self.voiceSize
            beginInstrument(a2, voice: d3, &output)
            var reads = true
            let wait = peek16(a2 + 6)
            if wait != 0 {
                poke16(a2 + 6, wait &- 1)
                reads = wait &- 1 == 0
            }
            if reads {
                var a3 = peek32(a2 + 2)
                var count = 0
                while true {
                    count += 1
                    if count > Self.mostCommands {
                        failure = "a voice's commands go round without one that ends its tick"
                        return
                    }
                    let command = peek16(a3)
                    a3 &+= 2
                    if failure != nil { return }
                    let ends = perform(command, a2: a2, a3: &a3, voice: d3, &output)
                    if failure != nil { return }
                    if ends { break }
                }
                poke32(a2 + 2, a3)
            }
            if kind == .second {
                vibrato(a2, always: false)
                envelope(a2)
            } else {
                vibrato(a2, always: true)
                envelope(a2)
                tell(a2, voice: d3, &output)
            }
        }
        if kind == .second {
            for d3 in 0 ..< 4 { tell(Self.voicesAt + UInt32(d3) * Self.voiceSize, voice: d3, &output) }
        }
    }

    /// An instrument asked for begun (`lbC0006C4` to `lbC0006DE`, `lbC002386` to `lbC0023A0`), after its
    /// delay: the voice silenced (the second form's, as `lbC000B7E` does it, before), its wait, vibrato,
    /// slide, loops and envelope cleared, and its commands those of the instrument (from the score's table of
    /// them, as offsets or places); and for the first form, its length in bytes all ones and the voice
    /// silenced as `lbC0035B0` does it.
    private mutating func beginInstrument<Output: TFMXOutput>(_ a2: UInt32, voice: Int, _ output: inout Output) {
        let delay = peek16(a2 + 0x42)
        if delay != 0 {
            poke16(a2 + 0x42, delay &- 1)
            return
        }
        let instrument = peek16(a2 + 0x40)
        if instrument & 0xFF == 0xFF { return }
        if kind == .second { silenceSecond(voice, a2: a2, &output) }
        for offset: UInt32 in [6, 0x2E, 0x24, 0x28, 0x26, 0x2C, 8, 10] { poke16(a2 + offset, 0) }
        for offset: UInt32 in [0x40, 0x46, 0x48, 0x4A, 0x4C] { poke16(a2 + offset, 0xFFFF) }
        if kind == .second {
            let offset = peek16(instrumentTable &+ UInt32(instrument & 0xFF) * 2)
            poke32(a2 + 2, instrumentBase &+ wide(offset))
            poke32(a2 + 0x3C, 0)
        } else {
            poke32(a2 + 2, peek32(instrumentTable &+ wide(instrument &* 4)))
            poke32(a2 + 0x3C, 0xFFFF_FFFF)
            silenceFirst(voice, a2: a2, &output)
        }
    }

    /// A command of a voice's instrument (`lbL00098A`, `lbL0033A0`: the second form's by its low byte, the
    /// first's by the word, which is four times its number); true for one that ends the voice's tick.
    private mutating func perform<Output: TFMXOutput>(_ command: UInt16, a2: UInt32, a3: inout UInt32, voice: Int,
                                                      _ output: inout Output) -> Bool
    {
        let number: Int
        if kind == .second {
            number = Int(command & 0xFF)
        } else {
            // (A word that is not four times a command's number would take the player off into its own
            // code, or past it, and stops the song.)
            guard command & 3 == 0, command < 96 else {
                failure = "an instrument's command the player has no routine for"
                return true
            }
            number = Int(command >> 2)
        }
        func word() -> UInt16 {
            let value = peek16(a3)
            a3 &+= 2
            return value
        }
        func long() -> UInt32 {
            let value = peek32(a3)
            a3 &+= 4
            return value
        }
        switch number {
        case 0, 1:
            // (`lbC000C30`, `lbC00365A`) The instrument's end: the voice on its idle commands, its priority
            // nought, and silenced; or for the first form's second (`lbC003612`), the tick's end.
            if number == 0 || kind == .second {
                a3 = Self.idleAt
                poke16(a2 + 0x44, 0)
                silence(voice, a2: a2, &output)
            }
            return true
        case 18:
            // (`lbC000BE8`, `lbC003612`) The tick's end.
            return true
        case 2:
            // (`lbC000BAC`, `lbC0035D4`) A sample: its place, from the table, as where the voice plays from
            // and where it copies and changes.
            let place = peek32(sampleTable &+ wide(word() &* 4))
            poke32(a2 + 0x34, place)
            poke32(a2 + 0x30, place)
        case 3:
            // (`lbC000BC4`, `lbC0035EC`) Its length in bytes, and in words.
            let length = UInt32(word())
            poke32(a2 + 0x3C, length)
            poke16(a2 + 0x38, UInt16(length) >> 1)
        case 4:
            // (`lbC000BD4`, `lbC0035FC`) Its length as a long, unless nought.
            let length = long()
            poke32(a2 + 0x3C, length)
            if length != 0 { poke16(a2 + 0x38, UInt16(truncatingIfNeeded: length) >> 1) }
        case 5:
            // (`lbC000BE4`, `lbC00360C`) A wait of so many ticks.
            poke16(a2 + 6, word())
            return true
        case 6:
            // (`lbC000BEC`, `lbC003616`) A loop's start: its count, and where it goes back to, kept in the
            // next of the voice's four.
            let d1 = peek16(a2 + 8)
            poke16(a2 + 10, d1)
            poke16(a2 &+ 0x0C &+ wide(d1), word())
            poke32(a2 &+ 0x14 &+ wide(d1 &* 2), a3)
            poke16(a2 + 8, (peek16(a2 + 8) &+ 2) & 6)
        case 7:
            // (`lbC000C0A`, `lbC003634`) Its end: back, for ever with a count of nought, or until it is
            // counted down, and then on, out of it (to the loop before, unless it is the first).
            let d1 = peek16(a2 + 10)
            let count = peek16(a2 &+ 0x0C &+ wide(d1))
            if count != 0 {
                poke16(a2 &+ 0x0C &+ wide(d1), count &- 1)
                if count &- 1 == 0 {
                    if d1 != 0 {
                        poke16(a2 + 8, peek16(a2 + 8) &- 2)
                        poke16(a2 + 10, peek16(a2 + 10) &- 2)
                    }
                    return false
                }
            }
            a3 = peek32(a2 &+ 0x14 &+ wide(d1 &* 2))
        case 8:
            // (`lbC000C3E`, `lbC003668`) Where the voice plays from, moved.
            let by = long()
            poke32(a2 + 0x34, peek32(a2 + 0x34) &+ by)
        case 9:
            // (`lbC000C46`, `lbC003670`) Its length in words, changed by half the word.
            let by = UInt16(bitPattern: Int16(bitPattern: word()) >> 1)
            poke16(a2 + 0x38, peek16(a2 + 0x38) &+ by)
        case 10:
            // (`lbC000C50`, `lbC00367A`) Its length in bytes, changed.
            let by = long()
            poke32(a2 + 0x3C, peek32(a2 + 0x3C) &+ by)
        case 11:
            // (`lbC000C58`, `lbC003682`) The period, changed.
            let by = word()
            poke16(a2 + 0x2A, peek16(a2 + 0x2A) &+ by)
        case 12:
            // (`lbC000C60`, `lbC00368E`) The volume, changed.
            let by = word()
            poke16(a2 + 0x2E, peek16(a2 + 0x2E) &+ by)
        case 13:
            // (`lbC000C68`, `lbC003696`) A vibrato: its step (the high byte) and its ticks each way (the low,
            // the first half of them).
            let value = word()
            poke16(a2 + 0x28, value >> 8)
            poke16(a2 + 0x24, value & 0xFF)
            poke16(a2 + 0x26, (value & 0xFF) >> 1)
        case 14:
            // (`lbC000B46`, `lbC003572`) The period.
            poke16(a2 + 0x2A, word())
        case 15:
            // (`lbC000B4C`, `lbC003578`) The volume (its top six bits heard).
            poke16(a2 + 0x2E, word())
        case 16:
            // (`lbC000B68`, `lbC003594`) The voice's DMA on.
            poke16(0xDFF096, (kind == .second ? 0x8200 : 0x8000) | 1 << UInt16(voice), &output)
        case 17:
            // (`lbC000B7E`, `lbC0035B0`) The voice silenced.
            silence(voice, a2: a2, &output)
            return true
        case 19:
            // (`lbC000B52`, `lbC00357E`) An envelope: up by the high byte of the first word, so many ticks
            // as its low byte and one more (or until it would go over the top), down by the second's as
            // that does, held for the third's ticks, and down by the fourth at every tick to silence; the
            // volume from nought.
            for offset: UInt32 in [0x46, 0x48, 0x4A, 0x4C] { poke16(a2 + offset, word()) }
            poke16(a2 + 0x4E, 0)
        case 20:
            // (`lbC000B1A`, `lbC003542`) A note, and its period from the player's table.
            let note = word() & 0xFF
            poke16(a2 + 0x54, note)
            poke16(a2 + 0x2A, peek16(Self.periodsAt + UInt32(note) * 2))
        case 21:
            // (`lbC000B32`, `lbC00355C`) A note from the voice's own.
            let note = word() &+ peek16(a2 + 0x54)
            poke16(a2 + 0x2A, peek16(Self.periodsAt &+ wide(note &* 2)))
        case 22:
            // (`lbC000C82`, `lbC0036B0`) A sample's first 128 bytes copied onto another's, a long at a time.
            // (The second's number is read into the low byte of the first's times four, as the routine
            // reads it.)
            let from = UInt16(peek8(a3)), onto = UInt16(peek8(a3 &+ 1))
            a3 &+= 2
            let source = peek32(sampleTable &+ UInt32(from &* 4))
            let index = ((from &* 4) & 0xFF00 | onto) &* 4
            let target = peek32(sampleTable &+ wide(index))
            if failure != nil { return true }
            guard source & 1 == 0, target & 1 == 0 else {
                failure = "the player copied a sample by longs at an odd address"
                return true
            }
            for i in 0 ..< UInt32(128) { poke8(target &+ i, peek8(source &+ i)) }
        case 23:
            // (`lbC000CDE`, `lbC00370C`) The voice's sample moved a step towards another, byte by byte, over
            // 128 bytes: each one up by one or down by one, unless it is the same.
            let source = peek32(sampleTable &+ wide(word() &* 4))
            let target = peek32(a2 + 0x30)
            for i in 0 ..< UInt32(128) {
                let have = peek8(target &+ i), want = peek8(source &+ i)
                if have > want { poke8(target &+ i, have &- 1) } else if have < want { poke8(target &+ i, have &+ 1) }
            }
        default:
            // (A number past the table's 24 takes the player off into its own code, and stops the song.)
            failure = "an instrument's command the player has no routine for"
            return true
        }
        return false
    }

    /// A voice silenced, as each form does it.
    private mutating func silence<Output: TFMXOutput>(_ voice: Int, a2: UInt32, _ output: inout Output) {
        if kind == .second { silenceSecond(voice, a2: a2, &output) } else { silenceFirst(voice, a2: a2, &output) }
    }

    /// The second form's (`lbC000B7E`, and `lbC000A40`): the voice's DMA off, its volume nought, its envelope
    /// none and its length nought; and Paula told its volume nought, and to play the silence at its period
    /// (`analyzer_2`, where Wanted Team's player has these writes of the routine's).
    private mutating func silenceSecond<Output: TFMXOutput>(_ voice: Int, a2: UInt32, _ output: inout Output) {
        poke16(0xDFF096, 1 << UInt16(voice), &output)
        poke16(a2 + 0x2E, 0)
        for offset: UInt32 in [0x46, 0x48, 0x4A, 0x4C] { poke16(a2 + offset, 0xFFFF) }
        poke32(a2 + 0x3C, 0)
        poke16(0xDFF0A8 + 16 * UInt32(voice), 0, &output)
        tellSilence(voice, a2: a2, &output)
    }

    /// The first form's (`lbC0035B0`): the voice's DMA off, and Paula told to play the silence.
    private mutating func silenceFirst<Output: TFMXOutput>(_ voice: Int, a2: UInt32, _ output: inout Output) {
        poke16(0xDFF096, 1 << UInt16(voice), &output)
        tellSilence(voice, a2: a2, &output)
    }

    /// (`analyzer_2`) Paula told a length of a word, the silence, and the voice's period.
    private mutating func tellSilence<Output: TFMXOutput>(_ voice: Int, a2: UInt32, _ output: inout Output) {
        let registers = 0xDFF0A0 + 16 * UInt32(voice)
        poke16(registers + 4, 1, &output)
        poke32(registers, Self.emptyAt, &output)
        poke16(registers + 6, peek16(a2 + 0x2A), &output)
    }

    /// The vibrato and slide (`lbC000AF0`, `lbC00351A`): the vibrato's step added to the period, and turned
    /// round once its count of ticks is out (the second form's only while it has a step); then the slide.
    private mutating func vibrato(_ a2: UInt32, always: Bool) {
        let step = peek16(a2 + 0x28)
        if step != 0 || always {
            poke16(a2 + 0x2A, peek16(a2 + 0x2A) &+ step)
            var count = peek16(a2 + 0x26)
            if count != 0 {
                count &-= 1
            } else {
                count = peek16(a2 + 0x24)
                poke16(a2 + 0x28, 0 &- peek16(a2 + 0x28))
            }
            poke16(a2 + 0x26, count)
        }
        poke16(a2 + 0x2A, peek16(a2 + 0x2A) &+ peek16(a2 + 0x2C))
    }

    /// The envelope (`lbC000A7A`, `lbC0034A4`), as its four words at $46 have it (see command 19), its
    /// level in the word at $4E, which is the volume's while it moves.
    private mutating func envelope(_ a2: UInt32) {
        var level = peek16(a2 + 0x4E)
        let attack = peek16(a2 + 0x46), decay = peek16(a2 + 0x48)
        if attack & 0xFF != 0xFF {
            poke8(a2 + 0x47, peek8(a2 + 0x47) &- 1)
            let (sum, over) = level.addingReportingOverflow(attack & 0xFF00)
            level = sum
            if over {
                level = 0xFF00
                poke16(a2 + 0x46, 0xFFFF)
            }
        } else if decay & 0xFF != 0xFF {
            poke8(a2 + 0x49, peek8(a2 + 0x49) &- 1)
            let (difference, under) = level.subtractingReportingOverflow(decay & 0xFF00)
            level = difference
            if under {
                level = 0
                poke16(a2 + 0x48, 0xFFFF)
            }
        } else if peek16(a2 + 0x4A) != 0xFFFF {
            poke16(a2 + 0x4A, peek16(a2 + 0x4A) &- 1)
        } else {
            let release = peek16(a2 + 0x4C)
            if release == 0xFFFF { return }
            let (difference, under) = level.subtractingReportingOverflow(release)
            level = difference
            if under {
                level = 0
                poke16(a2 + 0x4C, 0xFFFF)
            }
        }
        poke16(a2 + 0x4E, level)
        poke16(a2 + 0x2E, level)
    }

    /// Paula told the voice's volume, its sample and its period (`lbC0009EA`, `lbC003400`): the volume, the
    /// volume word's top six bits, no louder than the loudest the voices go (the first form's moved towards
    /// its target here, for each voice); and with a length, where it plays from, that place moved on by its
    /// length in words and back by its length in bytes, and its length in words; or with none, the silence.
    /// (The first form tells the period first, too.)
    private mutating func tell<Output: TFMXOutput>(_ a2: UInt32, voice: Int, _ output: inout Output) {
        if kind == .first {
            var d0 = master &+ masterSpeed
            if masterSpeed & 0x80 == 0 ? d0 >= masterTarget : d0 <= masterTarget {
                d0 = masterTarget
                masterSpeed = 0
            }
            master = d0
        }
        let loudest = master >> 2
        let volume = min(UInt8(peek16(a2 + 0x2E) >> 10), loudest)
        let registers = 0xDFF0A0 + 16 * UInt32(voice)
        poke16(registers + 8, UInt16(volume), &output)
        if kind == .first { poke16(registers + 6, peek16(a2 + 0x2A), &output) }
        let bytes = peek32(a2 + 0x3C)
        if bytes == 0 {
            tellSilence(voice, a2: a2, &output)
            return
        }
        let words = peek16(a2 + 0x38)
        poke32(registers, peek32(a2 + 0x34) &+ UInt32(words) * 2 &- bytes, &output)
        poke16(registers + 4, words, &output)
        if kind == .second { poke16(registers + 6, peek16(a2 + 0x2A), &output) }
    }

    /// `SongEndTest`, for the voice that has gone back in its list: its byte of the flags cleared (by its
    /// number, at $5A); once all four are, they are set again, and the song's end told.
    private mutating func songEndTest(_ a2: UInt32) {
        let number = peek16(a2 + 0x5A)
        if number <= 6, number & 1 == 0 { songEndFlags[Int(number >> 1)] = 0 }
        if songEndFlags[0] == 0, songEndFlags[1] == 0, songEndFlags[2] == 0, songEndFlags[3] == 0 {
            songEndFlags = .init(repeating: 0x57)
            endings += 1
        }
    }

    // MARK: The Amiga's memory and Paula's registers

    /// A byte of memory (24 bits of address, as the 68000 has; nought past the machine's memory, and
    /// from Paula's registers).
    private func peek8(_ address: UInt32) -> UInt8 {
        let at = Int(address & 0xFF_FFFF)
        return at < memoryCapacity ? memory[at] : 0
    }

    /// A word, or a long: at an odd address, the 68000 takes an address error, which would take the
    /// player down, and the song is stopped (`failure`).
    private mutating func peek16(_ address: UInt32) -> UInt16 {
        if address & 1 != 0 {
            failure = "the player read a word at an odd address"
            return 0
        }
        return UInt16(peek8(address)) << 8 | UInt16(peek8(address &+ 1))
    }

    private mutating func peek32(_ address: UInt32) -> UInt32 {
        UInt32(peek16(address)) << 16 | UInt32(peek16(address &+ 2))
    }

    private mutating func poke8(_ address: UInt32, _ value: UInt8) {
        let at = Int(address & 0xFF_FFFF)
        if at >> 12 == 0xDFF { return }
        if at < memoryCapacity { memory[at] = value }
    }

    /// A word written: to Paula's registers (DMACON at $DFF096, a voice's from $DFF0A0), told to `output`;
    /// or to memory.
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

    /// A write to Paula's registers, as the hardware takes it: a voice's location (two words, its low
    /// bit not kept) and length are where it goes on from when it next comes round, or where it starts
    /// when its DMA is turned on; DMACON sets or clears the voices' bits as its top bit says.
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

    /// The routine's table of periods (`lbW0002A0`, the same as `lbW002000`), seven octaves from the C
    /// below the Amiga's lowest; and the two words of the code that follows it in the player (`Play_1`'s
    /// and `Play_3`'s first, `MOVEM.L D0/D1/D7/A0/A1,-(SP)`), which a note of 84 reads.
    static let periods: [UInt16] = [
        0xEEE, 0xE17, 0xD4D, 0xC8E, 0xBD9, 0xB2F, 0xA8E, 0x9F7, 0x967, 0x8E0, 0x861, 0x7E8,
        0x777, 0x70B, 0x6A6, 0x647, 0x5EC, 0x597, 0x547, 0x4FB, 0x4B3, 0x470, 0x430, 0x3F4,
        0x3BB, 0x385, 0x353, 0x323, 0x2F6, 0x2CB, 0x2A3, 0x27D, 0x25A, 0x238, 0x218, 0x1FA,
        0x1DD, 0x1C3, 0x1A9, 0x191, 0x17B, 0x165, 0x151, 0x13E, 0x12D, 0x11C, 0x10C, 0xFD,
        0xEE, 0xE1, 0xD4, 0xC8, 0xBD, 0xB3, 0xA8, 0x9F, 0x96, 0x8E, 0x86, 0x7E,
        0x77, 0x70, 0x6A, 0x64, 0x5E, 0x59, 0x54, 0x4F, 0x4B, 0x47, 0x43, 0x3F,
        0x3B, 0x38, 0x35, 0x32, 0x2F, 0x2C, 0x2A, 0x27, 0x25, 0x23, 0x21, 0x1F,
        0x48E7, 0xC1C0,
    ]
}

/// Jason Page's music, played on Paula by `PaulaTickRenderer`.
extension JasonPagePlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Jason Page")
        info.author = "Jason Page"
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = (kind == .first ? "Graftgold's driver as Realms has it" : "Graftgold's driver as Fire & Ice has it")
            + "; \(sampleCount) sample\(plural)"
        return info
    }

    /// Jason Page's music is about as loud on the Amiga's chip as ProTracker's is: quieter by 0.3 dB in the
    /// middle of the sixteen different files of it in UnExoticA's collection (by BS.1770 loudness, over their
    /// first minute, against 40 ProTracker modules), and is turned up by that (2026-10-25).
    var gain: Float { 0.48 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}

/// A word as the 68000 takes it as an index or a displacement: sign-extended to a long.
private func wide(_ value: UInt16) -> UInt32 { UInt32(bitPattern: Int32(Int16(bitPattern: value))) }
