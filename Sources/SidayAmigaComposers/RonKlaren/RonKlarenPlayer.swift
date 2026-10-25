// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Ivo Zoer's replay routine for Ron Klaren's music, as Andy Silva and Wanted Team adapted it
// for EaglePlayer ("CustomMade player module V1.1 (5 Jan 2004)", carried by UADE as players/CustomMade,
// whose source UADE also carries as amigasrc/players/wanted_team/CustomMade/CustomMade_v1.asm). The
// names given are that source's labels, and the addresses those of the code hunk of the player UADE
// runs, which is the one built from that source.

import SidayChips
import SidayFoundation

/// Ron Klaren's music for the Amiga (that of Battle Squadron, Cyberblast and Plague, in UnExoticA's
/// collection), played by Ivo Zoer's routine, which the two of them called CustomMade ("(c) 1989-90 by
/// Ivo Zoer & Ron Klaren", as the player's credit has it). Each file is a game's music as it was ripped:
/// Ivo Zoer's 68000 code, which plays it, and its data, as it lay in the game's memory or as a program
/// would have it; or, made for an earlier player, an AmigaDOS program of one hunk, whose code begins
/// `MOVEQ #-1,D0; RTS` and, after a long, "RON_KLAREN_SOUNDMODULE!".
///
/// The player does not run the module's code: it has a copy of that routine of its own (taken from
/// Cyberblast's), and finds in the module what it needs by the module's code (`Layout`): its table of
/// songs, each four lists, one for each voice, of patterns played in turn, each with a transposition and
/// a number of times; its samples, each a sample or a waveform it changes as it plays (a synthesised
/// sound); and its table of arpeggios. A pattern is bytes: notes, each with how many ticks it lasts (in
/// fours) or none, to be changed by what follows; and commands, for an arpeggio, a slide, a sample, a
/// volume envelope's speed and the song's end. The player plays every module the same way, whichever
/// game's routine came with it, and so does this: it is that routine, as it tells Paula what to do, tick
/// by tick.
///
/// It owns the memory Paula plays from, laid out as UADE lays out its Amiga's: the player's hunk at
/// $D000, its own variables at their places in it (`periodsAt`, `stateAt`, `voicesAt`), and the module at
/// $F000, with room after it. The module's pointers are to where it lay in the game's memory (or, for a
/// program, to its hunk's start), which the player finds from the module's code (`Layout.origin`), and takes
/// off each one before it is used. The player's own code, which a broken module's tables could point
/// into, is not there: read as nought.
///
/// Its tick is the host's timer, set by the player to what it takes the module's code to set its CIA's
/// timer to (`Layout.timer`). A song ends when each of its voices has come to the end of its list of
/// patterns (the player's `SongEndTest`), and stops at a command to stop (`$83` or `$85`); its length is
/// found by playing it through in silence.
struct RonKlarenPlayer: ~Copyable {
    /// The memory Paula plays from: the Amiga's from nought, past the module.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// The module as it was given, put back at each song's start (the player changes it as it plays).
    private let module: [UInt8]

    /// Where UADE puts the module: past the player's hunk, which it relocates to $D000 (`uadecore_reset`:
    /// the player's file of 3,956 bytes loaded at $9000, its hunk put on the 4 KB boundary after that and
    /// 16 KB on, and the module 8 KB past the page that hunk of 3,784 bytes ends in).
    static let moduleAt: UInt32 = 0xF000
    /// The player's variables in its hunk: its table of periods (`lbL0009F4`, $D26, 84 words), its two
    /// bytes, nought while it plays (one once it has stopped) and the loudest an envelope goes, 63
    /// (`lbL000A86`, $DCE), its four voices, 62 bytes each (`lbL000AA2`, $DD0), and the bytes it clears
    /// as each voice comes to its end of the song (`SongEndFlag`, $162).
    static let periodsAt: UInt32 = 0xDD26
    static let stateAt: UInt32 = 0xDDCE
    static let voicesAt: UInt32 = 0xDDD0
    static let voiceSize: UInt32 = 62
    static let songEndFlagAt: UInt32 = 0xD162
    /// Room after the module, read as silence by a voice told a length that runs past it.
    private static let room = 0x20000 + 2048

    /// Where Paula starts a voice that has not been told where to: in the room after the module.
    var silenceAt: Int { Int(Self.moduleAt) + module.count + 1024 }
    var mixingAt: Int { silenceAt }

    /// What `InitPlayer` ($33E) finds in the module, by its code (its places in memory, as the module is
    /// put).
    struct Layout {
        /// Where the module lay when it was ripped: what its pointers are taken from.
        var origin: UInt32 = 0
        /// The song table (16 bytes a song: a list for each voice), the samples (32 bytes each) and the
        /// arpeggios (12 bytes each).
        var songs: UInt32 = 0
        var samples: UInt32 = 0
        var arpeggios: UInt32 = 0
        /// The value the module's code sets its CIA's timer to, nought if none is found: the byte its
        /// `MOVE.B` puts in the timer's high byte (at -1 from the `$00BFD500` of it), and the byte the
        /// `MOVE.B` before it puts in the low byte (at -9, from `$00BFD400` at -8). Wanted Team's player
        /// takes the low byte from 7 on, which in every file of UnExoticA's is the `#$81` of the next
        /// `MOVE.B`, to the CIA's interrupt control, and so UADE plays them slower than the games did, by
        /// 1.0 to 1.3 per cent (a tick 129 of the CIA's counts longer). siday plays them at the games'
        /// speed, as it plays the same music in the games' own code (`DeliCustomPlayer`), and takes the
        /// player's byte only where the module's code does not set the low byte just before.
        var timer: UInt16 = 0
        /// The table's offset that its routine adds to a song's number times 16 (`ptoff`), as a long.
        var songOffset: UInt32 = 0
        var foundSongs = false
    }

    let layout: Layout
    let songCount: Int
    private(set) var song = 0
    /// The samples the player's module information counts, and of them those it takes to be synthesised.
    let sampleCount: Int
    let synthCount: Int
    /// How long a tick is, in Paula's clocks: five of them to a tick of a CIA's timer, which counts the
    /// value it is set to and one more.
    let tickClocks: Int

    // Paula's registers as the player has written them.
    private var locations = InlineArray<4, UInt32>(repeating: 0)
    private var lengths = InlineArray<4, UInt16>(repeating: 0)
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)
    private var dmacon: UInt16 = 0
    /// True until the first tick, which tells Paula what the song's start wrote (see `run`).
    private var starting = false

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// Why the song stopped other than at a command to stop, if it did.
    private(set) var failure: String?
    /// For checks: each write the player made to Paula's registers in the tick just run (the register's
    /// offset, $A0 to $D8 or DMACON's $96, and the word written), when this is not nil.
    var writes: [(register: UInt16, value: UInt16)]?

    /// A song that has not come to its end in ten minutes is taken never to: longer than UADE plays a song
    /// that does not end (512 seconds), and than any of UnExoticA's (343 seconds).
    private var mostTicks: Int { 600 * 3_546_895 / tickClocks }
    /// The most bytes of commands a voice reads in a tick before it comes to a note: more than any file's
    /// pattern has between two. A voice that goes round without one would hang the player (its tick
    /// would never end), and the song is stopped there (siday's choice).
    private static let mostCommands = 4096
    /// The songs the player takes: as its module information has it (`MI_MaxSubSongs`, 15), its start
    /// taking a song's number in four bits (`Init`, $CB0).
    static let mostSongs = 15
    /// The samples counted, at most, for the module information (siday's choice; it counts on until one
    /// whose long at 28 is not nought).
    private static let mostSamples = 256
    /// The song table's entries counted, at most (siday's choice: the player counts on until the long
    /// that begins the routine's own first voice, `$DFF0A0`, however far that is).
    private static let mostSongsCounted = 256

    // MARK: The check

    /// True for a file the player's check takes (`Check2`, $2D2): more than 3,000 bytes, beginning
    /// with `JMP` or `JSR` and a `JMP` at 6, or a `BRA.W` and another at 4, and within the 400 bytes from
    /// 8 the three `CLR.B $30(A0)`, `CLR.B $31(A0)` and `CLR.B $32(A0)` of the routine's start of a voice;
    /// or for an AmigaDOS program of one hunk whose code begins `MOVEQ #-1,D0; RTS` and, after a long,
    /// "RON_KLAREN_SOUNDMODULE!" (which the check does not take, and UADE plays all the same, its
    /// `eagleplayer.conf` saying to pass the check by for the player's names). And in either, the tables
    /// `InitPlayer` looks for.
    static func isOne(_ data: [UInt8]) -> Bool {
        (passesCheck(data) || isProgram(data)) && find(data) != nil
    }

    static func passesCheck(_ data: [UInt8]) -> Bool {
        func word(_ at: Int) -> UInt16 { at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0 }
        func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }
        guard data.count > 3000 else { return false }
        switch word(0) {
        case 0x4EF9, 0x4EB9: guard word(6) == 0x4EF9 else { return false }
        case 0x6000: guard word(4) == 0x6000 else { return false }
        default: return false
        }
        for at in stride(from: 8, to: 408, by: 2)
            where long(at) == 0x4228_0030 && long(at + 4) == 0x4228_0031 && long(at + 8) == 0x4228_0032
        {
            return true
        }
        return false
    }

    static func isProgram(_ data: [UInt8]) -> Bool {
        let id = Array("RON_KLAREN_SOUNDMODULE!".utf8)
        guard data.count >= 40 + id.count, data[0 ..< 4] == [0, 0, 3, 0xF3], data[32 ..< 36] == [0x70, 0xFF, 0x4E, 0x75] else {
            return false
        }
        return Array(data[40 ..< 40 + id.count]) == id
    }

    /// `InitPlayer`'s finding of the tables, on the module as it would be put: from its start, a word at
    /// a time, up to the long that begins the routine's own table of periods ($1AC01940), or $800 words.
    private static func find(_ data: [UInt8]) -> Layout? {
        let base = Int(moduleAt)
        func word(_ address: UInt32) -> UInt16 {
            let at = Int(address & 0xFF_FFFF) - base
            return at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
        }
        func long(_ address: UInt32) -> UInt32 { UInt32(word(address)) << 16 | UInt32(word(address &+ 2)) }
        func byte(_ address: UInt32) -> UInt8 {
            let at = Int(address & 0xFF_FFFF) - base
            return at >= 0 && at < data.count ? data[at] : 0
        }
        var layout = Layout()
        var foundTable = false, foundSamples = false
        var a0 = moduleAt
        // (A3, the address of the routine's tick as the game had it; A4, of its first voice.)
        var a3: UInt32 = 0, a4: UInt32 = 0
        // (D5, the module's address, from which the origin is worked out.)
        var d5 = moduleAt
        for _ in 0 ..< 0x800 {
            switch long(a0) {
            case 0xD041_49FA:
                // ($35E) `ADD.W D1,D0; LEA x(PC),A4`: the arpeggios.
                layout.arpeggios = a0 &+ 4 &+ wide(word(a0 &+ 4))
                foundTable = true
            case 0x48E7_F8FC, 0x48E7_FFFE:
                // ($376) The `MOVEM.L` that begins the routine's tick: where it is now, against where the
                // game had it (A3), gives the module's origin, unless that is known; and the first `LEA
                // x(PC),A0` of the 21 words after it, the song table.
                if a3 != 0, layout.origin == 0 {
                    d5 &-= a0 &- a3
                    layout.origin = d5
                }
                for _ in 0 ... 20 {
                    let isLEA = word(a0) == 0x41FA
                    a0 &+= 2
                    if isLEA {
                        layout.songs = a0 &+ wide(word(a0))
                        layout.foundSongs = true
                        break
                    }
                }
            case 0xE948_47F0:
                // ($3B4) `LSL.W #4,D0; LEA x(A0,D0.W),A3`: the song table's offset.
                layout.songOffset = wide(word(a0 &+ 4))
            case 0x00BF_D500:
                // ($3C4) The `MOVE.B`s that set the CIA's timer: its value; and, from the code that
                // follows, the address the game had the routine's tick at (unless a `NOP` is 20 on).
                let low = word(a0 &- 12) == 0x13FC && long(a0 &- 8) == 0x00BF_D400 ? byte(a0 &- 9) : byte(a0 &+ 7)
                layout.timer = UInt16(byte(a0 &- 1)) << 8 | UInt16(low)
                if word(a0 &+ 20) != 0x4E71 {
                    if word(a0 &+ 28) == 0x21FC {
                        a3 = long(a0 &+ 30)
                    } else if word(a0 &+ 32) == 0xC000 {
                        a3 = long(a0 &+ 22)
                    } else {
                        a3 = long(a0 &+ 32)
                    }
                }
            case 0x42A8_001C:
                // ($408) `CLR.L $1C(A0); LEA x(PC),A1`: the samples.
                layout.samples = a0 &+ 6 &+ wide(word(a0 &+ 6))
                foundSamples = true
            case 0xE448_43FA, 0xE448_207B:
                // ($420) The routine's own pointer to its first voice, against where it is (A4): the
                // origin, unless that is known.
                if a4 != 0 {
                    a4 &-= long(a0 &+ 4 &+ wide(word(a0 &+ 4)))
                    if layout.origin == 0 {
                        d5 &-= a4
                        layout.origin = d5
                    }
                }
            case 0x48E7_00F0:
                // ($446) `MOVEM.L A0-A3,-(SP); LEA x(PC),A0`: the routine's first voice.
                a4 = a0 &+ 6 &+ wide(word(a0 &+ 6))
            default:
                break
            }
            a0 &+= 2
            if long(a0) == 0x1AC0_1940 { break }
        }
        // ($464) The song table's offset added (siday's choice, where it is not found: nought; the player
        // would add what was in D1).
        layout.songs &+= layout.songOffset
        guard layout.foundSongs, foundTable, foundSamples else { return nil }
        // (And, siday's choice, refused where the tables are not in the module, as in one cut short: the
        // player would read on into what follows it.)
        let end = moduleAt + UInt32(data.count)
        for table in [layout.songs, layout.samples, layout.arpeggios] where table < moduleAt || table >= end {
            return nil
        }
        return layout
    }

    // MARK: Making

    /// Reads the module and starts song `song` (counting from nought).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        module = data
        memoryCapacity = Int(Self.moduleAt) + data.count + Self.room
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        let found = Self.find(data)
        layout = found ?? Layout()
        let timer = layout.timer
        // (A timer of less than $800, or none, is taken to be the host's own, for fifty ticks a second:
        // siday's choice, for a file of none of UnExoticA's, whose timers are $2581 to $3781. UADE would
        // set its timer going at what was found, or at nought.)
        tickClocks = (Int(timer < 0x800 ? 0x376B : timer) + 1) * 5

        // ($46A) The songs: the table's entries of 16 bytes up to the routine's first voice, whose first
        // long, $DFF0A0, the routine's own copy has after them; and ($48C) the samples, up to one whose long
        // at 28 is not nought, each a synthesised one if its sample's length (at 4) is more than one word
        // and no more than 16.
        for (i, byte) in data.enumerated() { memory[Int(Self.moduleAt) + i] = byte }
        var songs = 0
        if found != nil {
            var at = layout.songs
            while songs < Self.mostSongsCounted, Self.peek32(memory, memoryCapacity, at) & 0xFF_FFFF != 0xDFF0A0 {
                songs += 1
                at &+= 16
            }
        }
        songCount = max(1, min(Self.mostSongs, songs))
        var samples = 0, synths = 0
        if found != nil {
            var at = layout.samples
            while samples + synths < Self.mostSamples, Self.peek32(memory, memoryCapacity, at &+ 28) == 0 {
                let sample = Self.peek32(memory, memoryCapacity, at) &- layout.origin &+ Self.moduleAt
                let length = Self.peek16(memory, memoryCapacity, sample &+ 4)
                if length != 2, length <= 16 { synths += 1 } else { samples += 1 }
                at &+= 32
            }
        }
        sampleCount = samples
        synthCount = synths
        self.song = 0
        // (Refused only once it is all made.)
        guard found != nil else { throw TuneError.malformed("not Ron Klaren's music: the tables its player looks for are not there") }
        guard songs > 0 else { throw TuneError.malformed("a module of Ron Klaren's music with no songs") }
        begin(song)
    }

    deinit { memory.deallocate() }

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
        while endings == 0, stops == 0, ticks < mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again, or its stop.)
        lengthClocks = endings > 0 || stops > 0 ? UInt64(ticks - 1) * UInt64(tickClocks) : nil
        writes = logging
        initialise()
    }

    /// The module put back as it was given, the player's variables as its hunk has them, Paula's
    /// registers as they were, and `InitSound` ($4CE) and `Init` (`Lcb0`, $CB0) for the song: the state
    /// set to $013F (stopped, and the loudest an envelope goes 63); each voice given its list of the song,
    /// from the song table, 16 bytes a song (its number taken in four bits, from one), and started on it
    /// (`lbC000036`, $79E); and the routine set going (the state's first byte cleared). (`InitSound`'s
    /// finding of the longest of the song's lists, for EaglePlayer's position, is not heard, and not done.)
    private mutating func initialise() {
        let end = Int(Self.moduleAt) + module.count
        memory.update(repeating: 0, count: Int(Self.moduleAt))
        for (i, byte) in module.enumerated() { memory[Int(Self.moduleAt) + i] = byte }
        (memory + end).update(repeating: 0, count: memoryCapacity - end)
        for (i, period) in Self.periods.enumerated() { poke16(Self.periodsAt + UInt32(2 * i), period) }
        for v in 0 ..< 4 {
            let voice = Self.voicesAt + UInt32(v) * Self.voiceSize
            poke32(voice, 0xDFF0A0 + UInt32(16 * v))
            poke16(voice + 46, 1 << UInt16(v))
        }
        poke32(Self.songEndFlagAt, 0x5754_5754)
        locations = .init(repeating: 0)
        lengths = .init(repeating: 0)
        paulaPeriods = .init(repeating: 0)
        paulaVolumes = .init(repeating: 0)
        dmacon = 0
        endings = 0
        stops = 0
        failure = nil
        var none = TFMXSilentOutput()
        poke16(Self.stateAt, 0x013F)
        let number = UInt32(song + 1)
        let table = layout.songs &+ wide(UInt16(truncatingIfNeeded: ((number & 15) &- 1) << 4))
        for v in 0 ..< 4 {
            let voice = Self.voicesAt + UInt32(v) * Self.voiceSize
            poke32(voice + 8, relocated(peek32(table &+ UInt32(4 * v))))
            startVoice(voice, &none)
        }
        poke8(Self.stateAt, 0)
        starting = true
    }

    // MARK: Playing

    /// The player's `DTP_Interrupt` (`Interrupt`, $548): the routine's tick (`Play`, `lbC000854`, $C8E),
    /// each voice's in turn, while the state's first byte is nought. Returns the tick's length in
    /// milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if writes != nil { writes = [] }
        if starting {
            // The first tick is the timer's first count, from when the host sets it going, after the
            // song's start: what that wrote, its samples' places and lengths, is told as it begins, and
            // the routine's first tick is at its end.
            starting = false
            for v in 0 ..< 4 {
                let base = UInt16(0xA0 + 16 * v)
                writes?.append(contentsOf: [(base, UInt16(locations[v] >> 16)), (base + 2, UInt16(truncatingIfNeeded: locations[v])),
                                            (base + 4, lengths[v])])
                tellBuffer(v, &output)
            }
            return tickClocks * 1000 / 3_546_895
        }
        if failure == nil, peek8(Self.stateAt) == 0 {
            for v in 0 ..< 4 {
                tick(Self.voicesAt + UInt32(v) * Self.voiceSize, &output)
                if failure != nil { break }
            }
        }
        if failure != nil, stops == 0 { stops += 1 }
        return tickClocks * 1000 / 3_546_895
    }

    /// A voice started on its song's first list (`lbC000036`, $79E): its counts and effects cleared, its
    /// sample the module's first (Paula told it, and its length), and its first pattern, with that list
    /// entry's transposition and its number of times less one. (Wanted Team's change: a first entry to
    /// be played 9,999 times, as Battle Squadron's title's is, is played 62, that the song may end.)
    private mutating func startVoice<Output: TFMXOutput>(_ a0: UInt32, _ output: inout Output) {
        for offset: UInt32 in [0x30, 0x31, 0x32, 0x33, 0x34, 0x39, 0x35, 0x37, 0x36, 0x3B, 0x3C] { poke8(a0 + offset, 0) }
        poke8(a0 + 0x3A, 1)
        for offset: UInt32 in [0x28, 0x2A, 0x2C] { poke16(a0 + offset, 0) }
        for offset: UInt32 in [0x14, 0x18, 0x1C] { poke32(a0 + offset, 0) }
        var a1 = layout.samples
        poke32(a0 + 4, a1)
        a1 = relocated(peek32(a1))
        let a2 = peek32(a0)
        poke32(a2, relocated(peek32(a1)), &output)
        poke16(a2 &+ 4, peek16(a1 &+ 4), &output)
        poke32(a0 + 12, peek32(a0 + 8))
        a1 = peek32(a0 + 12)
        poke32(a0 + 16, relocated(peek32(a1)))
        poke16(a0 + 0x20, peek16(a1 &+ 6))
        if peek16(a1 &+ 10) == 0x270F { poke16(a1 &+ 10, 0x3E) }
        poke16(a0 + 0x22, peek16(a1 &+ 10) &- 1)
    }

    /// A voice's tick (`lbC0000C0`, $846), its record at `a0`: Paula's DMA for it turned on (as it is at
    /// every tick), and a sample to be played once given a length of one word, to go round on, once it
    /// has begun; then, while its note lasts, its synthesised waveform changed, its slide or arpeggio, its
    /// vibrato and its volume envelope; and at the note's end, its next commands, up to its next note
    /// (`lbC0002E8`). (The routine's sound effects, which `lbC000108`'s first test is for, the player never
    /// starts: that test always fails.)
    private mutating func tick<Output: TFMXOutput>(_ a0: UInt32, _ output: inout Output) {
        var d0: UInt32 = 0, d1: UInt32 = 0, d2: UInt32 = 0, d3: UInt32 = 0
        var a1 = peek32(a0 + 4)
        let a2 = peek32(a0 + 16)
        let a3 = peek32(a0)
        var a4: UInt32 = 0
        if peek8(a0 + 0x3B) != 0 {
            if peek8(a0 + 0x3C) != 0 {
                poke8(a0 + 0x3C, peek8(a0 + 0x3C) &- 1)
            } else {
                poke8(a0 + 0x3B, 0)
                poke8(a0 + 0x3A, peek8(a1 &+ 8))
                a4 = relocated(peek32(a1))
                poke32(a3, relocated(peek32(a4)), &output)
                poke16(a3 &+ 4, peek16(a4 &+ 4), &output)
            }
        }
        // ($88C) DMA on, and a length of one word for a sample played once.
        setW(&d0, 0x8000 | peek16(a0 + 0x2E))
        poke16(0xDFF096, lo16(d0), &output)
        if peek8(a0 + 0x3A) != 0 {
            poke8(a0 + 0x3A, 0)
            poke16(a3 &+ 4, 1, &output)
        }
        // ($8AA) The note's ticks left (in the byte at $31), counted down; at nought, its next commands.
        if peek8(a0 + 0x31) == 0 {
            commands(a0, a1: a1, a2: a2, a3: a3, d0: d0, &output)
            return
        }
        poke8(a0 + 0x31, peek8(a0 + 0x31) &- 1)
        if peek8(a0 + 0x3B) != 0 { return }
        // ($8BE) A synthesised sound (its sample's byte at 9 not nought), every so many ticks: a byte of its
        // waveform, from the sample's length (at 6) less its byte at 10 on, set to its byte at 22, the
        // place going up to twice the byte at 10, and down to nought, and the byte turned over at each end.
        setW(&d0, 0)
        if peek8(a1 &+ 9) != 0 {
            if peek8(a0 + 0x36) != 0 {
                poke8(a0 + 0x36, peek8(a0 + 0x36) &- 1)
            } else {
                setB(&d0, peek8(a1 &+ 9) &- 1)
                poke8(a0 + 0x36, lo8(d0))
                a4 = relocated(peek32(a1))
                setW(&d0, peek16(a4 &+ 6))
                setB(&d0, lo8(d0) &- peek8(a1 &+ 10))
                a4 = relocated(peek32(a4))
                a4 = a4 &+ wide(lo16(d0))
                setW(&d0, 0)
                if peek8(a1 &+ 23) & 0x80 == 0 {
                    setB(&d0, peek8(a1 &+ 24))
                    poke8(a4 &+ wide(lo16(d0)), peek8(a1 &+ 22))
                    setB(&d0, lo8(d0) &+ 1)
                    setB(&d1, peek8(a1 &+ 10))
                    setB(&d1, lo8(d1) &+ lo8(d1))
                    if lo8(d1) == lo8(d0) {
                        poke8(a1 &+ 23, ~peek8(a1 &+ 23))
                        poke8(a1 &+ 22, ~peek8(a1 &+ 22))
                    }
                } else {
                    setB(&d0, peek8(a1 &+ 24))
                    poke8(a4 &+ wide(lo16(d0)), peek8(a1 &+ 22))
                    setB(&d0, lo8(d0) &- 1)
                    if lo8(d0) == 0 {
                        poke8(a1 &+ 23, ~peek8(a1 &+ 23))
                        poke8(a1 &+ 22, ~peek8(a1 &+ 22))
                    }
                }
                poke8(a1 &+ 24, lo8(d0))
            }
        }
        // ($93E) A slide (its speed in the byte at $37) towards its period (at $26), the period (at $24)
        // moved by the speed and stopped there; or ($97C) the arpeggio's next step (twelve, from the
        // voice's at $14, counted down), added to the note and its transposition, and its period told.
        if peek8(a0 + 0x37) != 0 {
            setW(&d0, 0)
            setB(&d0, peek8(a0 + 0x37))
            setW(&d1, peek16(a0 + 0x26))
            setW(&d2, peek16(a0 + 0x24))
            if negative(lo16(d1) &- lo16(d2)) {
                setW(&d2, lo16(d2) &- lo16(d0))
                if !negative(lo16(d1) &- lo16(d2)) { setW(&d2, lo16(d1)) }
            } else {
                setW(&d2, lo16(d2) &+ lo16(d0))
                if negative(lo16(d1) &- lo16(d2)) { setW(&d2, lo16(d1)) }
            }
            poke16(a0 + 0x24, lo16(d2))
            poke16(a3 &+ 6, lo16(d2), &output)
        } else {
            a4 = a0 + 0x14
            setW(&d1, peek16(a0 + 0x2C))
            setB(&d0, peek8(a4 &+ wide(lo16(d1))))
            setB(&d0, lo8(d0) &+ peek8(a0 + 0x30))
            setW(&d0, lo16(d0) &+ peek16(a0 + 0x20))
            setW(&d0, lo16(d0) &+ lo16(d0))
            setW(&d0, peek16(Self.periodsAt &+ wide(lo16(d0))))
            poke16(a0 + 0x24, lo16(d0))
            poke16(a3 &+ 6, lo16(d0), &output)
            setW(&d1, lo16(d1) &- 1)
            if negative(lo16(d1)) { setW(&d1, lo16(d1) &+ 12) }
            poke16(a0 + 0x2C, lo16(d1))
        }
        // ($9AE) A vibrato (the sample's byte at 11 its step, at 12 its depth, at 13 its delay in fours):
        // after its delay, the byte of its table (the waveform of the sample pointed at by the long at 4)
        // where it is, times the depth, added to the period and told; the place going down by the step,
        // and round from the table's end (its length, at 4, in bytes).
        if peek8(a1 &+ 11) != 0 {
            if peek8(a0 + 0x35) != 0 {
                poke8(a0 + 0x35, peek8(a0 + 0x35) &- 1)
            } else {
                setW(&d0, peek16(a0 + 0x2A))
                a4 = relocated(peek32(a1 &+ 4))
                a4 = relocated(peek32(a4))
                setB(&d2, peek8(a4 &+ wide(lo16(d0))))
                setW(&d1, 0)
                setW(&d2, UInt16(bitPattern: Int16(Int8(bitPattern: lo8(d2)))))
                setB(&d1, peek8(a1 &+ 12))
                d2 = UInt32(bitPattern: Int32(Int16(bitPattern: lo16(d1))) &* Int32(Int16(bitPattern: lo16(d2))))
                setW(&d2, lo16(d2) &+ peek16(a0 + 0x24))
                poke16(a3 &+ 6, lo16(d2), &output)
                setW(&d0, 0)
                setB(&d0, peek8(a1 &+ 11))
                let place = peek16(a0 + 0x2A) &- lo16(d0)
                poke16(a0 + 0x2A, place)
                if negative(place) {
                    a4 = relocated(peek32(a1 &+ 4))
                    setW(&d0, peek16(a4 &+ 4))
                    setW(&d0, lo16(d0) &+ lo16(d0))
                    poke16(a0 + 0x2A, lo16(d0))
                }
            }
        }
        // ($A1A) The volume envelope, every so many ticks (the byte at $33, counted down in the byte at
        // $34): four stages of the sample's, from its byte at 14 (each a volume to go to, and at 18, the
        // step to go by), the volume (at $39) moved towards the stage's, up to the state's loudest, and on
        // to the next stage, to the fourth, as it gets there; its low six bits told (`ChangeVolume`).
        let count = peek8(a0 + 0x34) &- 1
        poke8(a0 + 0x34, count)
        if !negative(count) { return }
        poke8(a0 + 0x34, peek8(a0 + 0x33))
        setW(&d0, peek16(a0 + 0x28))
        a4 = a1 &+ 14
        setB(&d1, peek8(a4 &+ wide(lo16(d0))))
        setB(&d2, peek8(a4 &+ 4 &+ wide(lo16(d0))))
        setB(&d3, peek8(a0 + 0x39))
        var next = false
        if negative(lo8(d1) &- lo8(d3)) {
            setB(&d3, lo8(d3) &- lo8(d2))
            if !negative(lo8(d1) &- lo8(d3)) {
                setB(&d3, lo8(d1))
                next = true
            }
        } else {
            a1 = Self.stateAt
            setB(&d3, lo8(d3) &+ lo8(d2))
            if !negative(lo8(d3) &- peek8(a1 &+ 1)) {
                setB(&d3, peek8(a1 &+ 1))
                next = true
            } else if negative(lo8(d1) &- lo8(d3)) {
                setB(&d3, lo8(d1))
                next = true
            }
        }
        if next, lo16(d0) != 3 { setW(&d0, lo16(d0) &+ 1) }
        poke16(a0 + 0x28, lo16(d0))
        poke8(a0 + 0x39, lo8(d3))
        setW(&d3, lo16(d3) & 0x3F)
        poke16(a3 &+ 8, lo16(d3), &output)
    }

    /// A voice's commands, at the end of its note (`lbC0002E8`, $A80): its slide stopped, its vibrato's
    /// delay started again; then, up to its next note, an arpeggio (`$80`, its number), a slide (`$81`:
    /// the note to go to, its speed, and how many ticks in fours, as a note), a sample (`$82`, its number,
    /// started at once), a stop (`$83`, or `$85`), the volume envelope's speed (`$84`); at a byte of
    /// $80 or more besides those, the end of the pattern, and the voice on to the pattern again or the next
    /// in its list (and, at the list's end, to its first again, and the song's end tested); and a note,
    /// the byte and the number of ticks it lasts in fours, or nought to change the note to be slid from and
    /// go on. A note's sample is started, its period told, and a sample to be played once marked for it.
    private mutating func commands<Output: TFMXOutput>(_ a0: UInt32, a1: UInt32, a2: UInt32, a3: UInt32, d0: UInt32,
                                                       _ output: inout Output)
    {
        var d0 = d0, d1: UInt32 = 0
        var a1 = a1, a2 = a2, a4: UInt32 = 0
        poke8(a0 + 0x37, 0)
        setB(&d0, peek8(a1 &+ 13))
        if lo8(d0) != 0 {
            setB(&d0, lo8(d0) << 2 &- 1)
            poke8(a0 + 0x35, lo8(d0))
        }
        var read = 0
        while true {
            read += 1
            if read > Self.mostCommands {
                failure = "a voice's commands go round without a note"
                return
            }
            if peek8(a2) == 0x80 {
                d0 = 0
                setW(&d1, 0)
                poke16(a0 + 0x2C, 0)
                setB(&d0, peek8(a2 &+ 1))
                setW(&d1, lo16(d0))
                setW(&d0, lo16(d0) << 3)
                setW(&d1, lo16(d1) << 2)
                setW(&d0, lo16(d0) &+ lo16(d1))
                a4 = layout.arpeggios &+ d0
                poke32(a0 + 0x14, peek32(a4))
                poke32(a0 + 0x18, peek32(a4 &+ 4))
                poke32(a0 + 0x1C, peek32(a4 &+ 8))
                a2 &+= 2
            }
            if peek8(a2) == 0x81 {
                setW(&d0, 0)
                poke16(a0 + 0x28, 0)
                setB(&d0, peek8(a2 &+ 1))
                poke8(a0 + 0x32, lo8(d0))
                setW(&d0, lo16(d0) &+ peek16(a0 + 0x20))
                setW(&d0, lo16(d0) &+ lo16(d0))
                poke16(a0 + 0x26, peek16(Self.periodsAt &+ wide(lo16(d0))))
                poke8(a0 + 0x37, peek8(a2 &+ 2))
                setB(&d0, peek8(a2 &+ 3))
                setB(&d0, lo8(d0) << 2 &- 1)
                poke8(a0 + 0x31, lo8(d0))
                a2 &+= 4
                note(a0, a2: a2, a3: a3, &output)
                return
            }
            if peek8(a2) == 0x82 {
                setW(&d0, 0)
                poke8(a0 + 0x39, 0)
                poke16(a0 + 0x28, 0)
                setB(&d0, peek8(a2 &+ 1))
                setW(&d0, lo16(d0) << 5)
                a1 = layout.samples &+ wide(lo16(d0))
                poke32(a0 + 4, a1)
                if peek8(a0 + 0x3B) == 0 {
                    poke16(0xDFF096, peek16(a0 + 0x2E), &output)
                    a4 = relocated(peek32(a1))
                    poke32(a3, relocated(peek32(a4)), &output)
                    poke16(a3 &+ 4, peek16(a4 &+ 4), &output)
                }
                a2 &+= 2
            }
            if peek8(a2) == 0x83 {
                stop()
                return
            }
            if peek8(a2) == 0x84 {
                poke8(a0 + 0x33, peek8(a2 &+ 1))
                a2 &+= 2
            }
            if peek8(a2) == 0x85 {
                stop()
                return
            }
            if peek8(a2) & 0x80 != 0 {
                // ($B7E) The pattern's end: again, while its times last; or the list's next entry (12
                // bytes: the pattern, the transposition at 6, the number of times at 10), and at the list's
                // end (an entry whose first byte has its top bit set), its first again, and the song's end
                // tested.
                if peek16(a0 + 0x22) != 0 {
                    poke16(a0 + 0x22, peek16(a0 + 0x22) &- 1)
                    a4 = peek32(a0 + 12)
                    a2 = relocated(peek32(a4))
                    poke32(a0 + 16, a2)
                    poke16(a0 + 0x20, peek16(a4 &+ 6))
                    continue
                }
                poke32(a0 + 12, peek32(a0 + 12) &+ 12)
                a4 = peek32(a0 + 12)
                poke16(a0 + 0x22, peek16(a4 &+ 10))
                poke16(a0 + 0x22, peek16(a0 + 0x22) &- 1)
                if peek8(a4) & 0x80 != 0 {
                    a4 = peek32(a0 + 8)
                    poke32(a0 + 12, a4)
                    songEndTest(a0)
                }
                a2 = relocated(peek32(a4))
                poke32(a0 + 16, a2)
                poke16(a0 + 0x20, peek16(a4 &+ 6))
                setW(&d0, peek16(a4 &+ 10) &- 1)
                poke16(a0 + 0x22, lo16(d0))
                continue
            }
            // ($BEC) A note: with no ticks, the note changed and on; otherwise its ticks set (in fours, less
            // one), its envelope from its first stage, and its period.
            setB(&d0, peek8(a2 &+ 1))
            if lo8(d0) == 0 {
                setB(&d0, peek8(a2))
                poke8(a0 + 0x30, lo8(d0))
                setW(&d0, lo16(d0) &+ peek16(a0 + 0x20))
                setW(&d0, lo16(d0) &+ lo16(d0))
                poke16(a0 + 0x24, peek16(Self.periodsAt &+ wide(lo16(d0))))
                a2 &+= 2
                continue
            }
            setB(&d0, lo8(d0) << 2 &- 1)
            poke8(a0 + 0x31, lo8(d0))
            setW(&d0, 0)
            poke16(a0 + 0x28, 0)
            setB(&d0, peek8(a2))
            poke8(a0 + 0x30, lo8(d0))
            setW(&d0, lo16(d0) &+ peek16(a0 + 0x20))
            setW(&d0, lo16(d0) &+ lo16(d0))
            poke16(a0 + 0x24, peek16(Self.periodsAt &+ wide(lo16(d0))))
            if peek8(a0 + 0x3B) != 0 {
                poke32(a0 + 16, a2 &+ 2)
                return
            }
            // ($C40) The voice's DMA off, its sample told, and (its byte at 8 not nought) its being played
            // once marked.
            poke16(0xDFF096, peek16(a0 + 0x2E), &output)
            a4 = relocated(peek32(a1))
            poke32(a3, relocated(peek32(a4)), &output)
            poke16(a3 &+ 4, peek16(a4 &+ 4), &output)
            a2 &+= 2
            if peek8(a1 &+ 8) != 0 { poke8(a0 + 0x3A, 1) }
            note(a0, a2: a2, a3: a3, &output)
            return
        }
    }

    /// `Lc76` ($C76): where the voice is in its pattern kept, and its period told.
    private mutating func note<Output: TFMXOutput>(_ a0: UInt32, a2: UInt32, a3: UInt32, _ output: inout Output) {
        poke32(a0 + 16, a2)
        poke16(a3 &+ 6, peek16(a0 + 0x24), &output)
    }

    /// `Back` ($B58): the routine stopped, the state's first byte set, and the song's end told
    /// (`SongEnd`, $5DA).
    private mutating func stop() {
        poke8(Self.stateAt, 1)
        endings += 1
        stops += 1
    }

    /// `SongEndTest` ($584), for the voice that has come to the end of its list: its byte of the flag
    /// cleared (by its registers' place); once all four are, they are set again, and the song's end told.
    private mutating func songEndTest(_ a0: UInt32) {
        let base = peek32(a0)
        for v in 0 ..< 4 where base == 0xDFF0A0 + UInt32(16 * v) {
            poke8(Self.songEndFlagAt + UInt32(v), 0)
        }
        if peek32(Self.songEndFlagAt) == 0 {
            poke32(Self.songEndFlagAt, 0x5754_5754)
            endings += 1
        }
    }

    /// A pointer of the module's, from where it lay when ripped to where it is.
    private func relocated(_ pointer: UInt32) -> UInt32 { pointer &- layout.origin &+ Self.moduleAt }

    // MARK: The Amiga's memory and Paula's registers

    private static func peek16(_ memory: UnsafeMutablePointer<UInt8>, _ capacity: Int, _ address: UInt32) -> UInt16 {
        let at = Int(address & 0xFF_FFFE)
        return at + 1 < capacity ? UInt16(memory[at]) << 8 | UInt16(memory[at + 1]) : 0
    }

    private static func peek32(_ memory: UnsafeMutablePointer<UInt8>, _ capacity: Int, _ address: UInt32) -> UInt32 {
        UInt32(peek16(memory, capacity, address)) << 16 | UInt32(peek16(memory, capacity, address &+ 2))
    }

    /// A byte of memory (24 bits of address, as the 68000 has; nought past the machine's memory, and
    /// from Paula's registers).
    private func peek8(_ address: UInt32) -> UInt8 {
        let at = Int(address & 0xFF_FFFF)
        return at < memoryCapacity ? memory[at] : 0
    }

    /// A word, or a long: at an odd address, the 68000 takes an address error, which would take the
    /// player down, and the song is stopped (`failure`).
    private mutating func peek16(_ address: UInt32) -> UInt16 {
        let at = Int(address & 0xFF_FFFF)
        if address & 1 != 0 { failure = "the player read a word at an odd address" }
        return Self.peek16(memory, memoryCapacity, address)
    }

    private mutating func peek32(_ address: UInt32) -> UInt32 {
        let at = Int(address & 0xFF_FFFF)
        if address & 1 != 0 { failure = "the player read a long at an odd address" }
        return Self.peek32(memory, memoryCapacity, address)
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

    /// The routine's table of periods (`lbL0009F4`, $D26): its five octaves, and Wanted Team's seven more
    /// notes after them ("for some buggy (?) mods").
    static let periods: [UInt16] = [
        0x1AC0, 0x1940, 0x17D0, 0x1680, 0x1530, 0x1400, 0x12E0, 0x11D0, 0x10D0, 0x0FE0, 0x0F00, 0x0E20,
        0x0D60, 0x0CA0, 0x0BE8, 0x0B40, 0x0A98, 0x0A00, 0x0970, 0x08E8, 0x0868, 0x07F0, 0x0780, 0x0710,
        0x06B0, 0x0650, 0x05F4, 0x05A0, 0x054C, 0x0500, 0x04B8, 0x0474, 0x0434, 0x03F8, 0x03C0, 0x0388,
        0x0358, 0x0328, 0x02FA, 0x02D0, 0x02A6, 0x0280, 0x025C, 0x023A, 0x021A, 0x01FC, 0x01E0, 0x01C4,
        0x01AC, 0x0194, 0x017D, 0x0168, 0x0153, 0x0140, 0x012E, 0x011D, 0x010D, 0x00FE, 0x00F0, 0x00E2,
        0x00D6, 0x00CA, 0x00BE, 0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F,
        0x0078, 0x0071, 0x006B, 0x0065, 0x005F, 0x005A, 0x0055, 0x0050, 0x004B, 0x0047, 0x0043, 0x003F,
        0x003C, 0x0038,
    ]
}

/// Ron Klaren's music, played on Paula by `PaulaTickRenderer`.
extension RonKlarenPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Ron Klaren")
        info.author = "Ron Klaren"
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Ivo Zoer's CustomMade replayer; \(sampleCount) sample\(plural), \(synthCount) synthesised"
        return info
    }

    /// Ron Klaren's music is louder on the Amiga's chip than ProTracker's is, by 5.9 dB in the middle of
    /// its nine tunes in UnExoticA's collection (by BS.1770 loudness, over their first minute, against 40
    /// ProTracker modules), and is turned down by that (2026-10-25).
    var gain: Float { 0.23 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { tickClocks }
}

// The 68000's registers as the routine uses them: a byte or a word of a long set, the rest kept.
private func lo8(_ r: UInt32) -> UInt8 { UInt8(truncatingIfNeeded: r) }
private func lo16(_ r: UInt32) -> UInt16 { UInt16(truncatingIfNeeded: r) }
private func setB(_ r: inout UInt32, _ value: UInt8) { r = r & 0xFFFF_FF00 | UInt32(value) }
private func setW(_ r: inout UInt32, _ value: UInt16) { r = r & 0xFFFF_0000 | UInt32(value) }
/// A word as the 68000 takes it as an index or a displacement: sign-extended to a long.
private func wide(_ value: UInt16) -> UInt32 { UInt32(bitPattern: Int32(Int16(bitPattern: value))) }
/// The 68000's N flag of a result: its top bit.
private func negative(_ value: UInt8) -> Bool { value & 0x80 != 0 }
private func negative(_ value: UInt16) -> Bool { value & 0x8000 != 0 }
