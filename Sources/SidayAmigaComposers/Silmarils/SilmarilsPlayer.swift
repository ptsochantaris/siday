// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer module for Silmarils' music ("Silmarils player module V1.0 (22 Oct
// 2001)", "(c) 1989-92 by Michel Pernot, adapted by Wanted Team", carried by UADE as players/Silmarils),
// whose source is not published: this is ported from a disassembly of the code hunk UADE runs, and the
// labels given are that hunk's addresses (`Lxxx`, or `bss+xx` for its second hunk, of 384 bytes).

import SidayChips
import SidayFoundation

/// The music of Silmarils' games of 1989 to 1992 (Targhan, Colorado, Crystals of Arborea, Starblade, Storm
/// Master, Metal Mutant, Boston Bomb Club, Ishar, and Le Fétiche Maya and Wind Surf Willy), as it lay among
/// each game's files: a file of the games' own engine, its resources and a script. The player runs the part
/// of the script that finds the samples and starts the music, and plays the music on three of Paula's voices
/// (its tables are of three).
///
/// The file: six bytes (a long and a word) or none, and then, from its base, a header: at 4 the word $16,
/// five words of nought from 6, the word $20 at 18 and at 22, and at 14 a long, from the base, to a table
/// whose first long (and its fourth) is $58, from the table to the list of resources: longs, each from its
/// own place to a resource, up to a nought or one whose high byte is set. The script is at 24 from the base.
/// A resource begins with its kind (a byte) and, at 2, its size (a long, its header's 16 bytes in it, for a
/// sample). A score's data begins at 6, and with $FF $02 (each sets its first voice's sample first): the
/// player counts the scores by those two bytes, and the songs are as many as the scores. A sample, of kind 1
/// or 2, has at 8 where its loop begins and at 12 where it ends (longs, from its sound, nought for none: a
/// sample whose loop begins at nought is played once), at 6 a byte, 1 for sound packed in four bits a byte,
/// and its sound at 16.
///
/// The script is the game's (`L11EC`): bytes, each an instruction, of which the player has 20, enough for
/// what the files' scripts do at their start: calls, jumps and returns, branches on a value and on tables
/// of them, the setting of the game's variables (bytes and words in the player's second hunk, from
/// `bss+$5C`; the song asked for is the word at 12, `bss+$68`) and of bytes of the file, from values made
/// of numbers, variables, bytes of the file, sums, differences and comparisons; a sample put in one of 32
/// places (`bss+$80`, each its sound's address and a transposition), and the music started (a score, and
/// its tempo). Any other instruction ends the script (`L11E0`), and a script ended so at the start is the
/// module refused. A file with no more than two resources that are not scores has its samples in another,
/// whose script is run first (`ExtLoad`, `InitSound`): the file of its name up to its first underscore
/// (BostonBombClub.mok for BostonBombClub_title.mok).
///
/// The score is bytes: $FF and a command, or a byte under $80, which repeats the command before with it as
/// its first argument; and $80 to $FE, a wait. A command's top two bits are its voice, and its low six what it
/// is: nought (`$FF $FF`) the score again from its start (its end), 1 a note (its number, from the player's
/// table of periods, with the sample's transposition, and its volume; nought stops the voice), 2 the voice's
/// sample (a place), 3 its release (the sample's sound after its loop, played once after the loop's turn).
/// A wait of `n` sets a count to `n - $80` times 256, which each tick counts down by the song's tempo times
/// eight (seven less, for a file whose samples have no transposition), the score read on once it is done.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. Its tick is the host's timer, which `InitSound` sets to 3,280 (some 216
/// times a second). A note turns its voice off at once and on again after the player's wait for the beam
/// (`dtg_WaitAudioDMA`: ten lines), some 3,500 of Paula's clocks later (the medians of UADE's dumps of the
/// music are 3,100 to 3,850 from the player's first write in the tick); Paula's audio interrupts then give a
/// sample its loop, or let one played once be heard once (`$D80`, `$DBA` and on, for each voice), which is
/// done here at once. (A note on a voice whose old sound Paula has not yet stopped by then, its period long
/// and its first part not yet played through, is not started in UADE until what she is playing comes to its
/// end: in UnExoticA's files, some 30 of the 27,000 notes of their songs played twice round are of those,
/// in three songs, and UADE loses some of them, by the cycles its 68000 takes. That is the machine's timing,
/// not the player's meaning, and is not followed.)
struct SilmarilsPlayer: ~Copyable {
    /// The module and its companion, and what follows them, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed, and the silence given a sample played once: the noughts
    /// after the files.
    let silenceAt: Int
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    /// Where the module is in `memory`, after 16 bytes of nought (which a voice given an empty place plays),
    /// and where its companion is, after it.
    static let moduleAt = 16
    private let companionAt: Int?
    /// Where the companion is in `memory`, if one is played.
    var companionPlace: Int? { companionAt }
    /// The end of the files in `memory`: what is read past it, or before the module, is nought.
    private let contentEnd: Int
    /// The module's base (`L1598`) and the companion's (`L156`).
    private let base: UInt32
    private let companionBase: UInt32?
    /// The number of scores, which is the number of songs; and the samples among the files' resources.
    let songCount: Int
    private(set) var sampleCount = 0
    /// What `InitPlayer` adds to the song asked for, for the script (`L14A`).
    private var songOffset: UInt16 = 0
    /// The byte `InitPlayer` finds to clear at each song's start, in two files (`L142` to `L144`).
    private var patch: Int?
    /// The files, the player's second hunk, its tempo and its finding of transpositions as `InitPlayer` left
    /// them, put back for each song, as each is played in UADE by a player newly loaded.
    private var pristine: [UInt8] = []
    private var pristineHunk: [UInt8] = []
    private var pristineTempo: UInt8 = 0
    private var pristineTranspositions = false

    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?

    // MARK: The player's state

    /// The second hunk (`bss`): the script's stack and variables, and from $80 the 32 places of samples.
    private var hunk: [UInt8]
    /// The tempo (`L159F`) and the score (`L15A4`) the script last set, and whether any sample has a
    /// transposition (`L14E`).
    private var tempo: UInt8 = 0
    private var scoreAt: UInt32 = 0
    private var transposed = false
    /// The script's registers: where it is, its stack's place (`D4`), and the two values (`D6`, `D7`); and how
    /// much of it has run, and how deep its values are, that a broken one comes to an end.
    private var pc: UInt32 = 0
    private var stack: UInt16 = 0
    private var d6: UInt16 = 0
    private var d7: UInt16 = 0
    private var steps = 0
    private var depth = 0
    /// The score's place (`Lee4`), its count (`Lef0`), what is taken off it a tick (`Lee2`), and the command
    /// last read (`Lef2`).
    private var position: UInt32 = 0
    private var counter: UInt16 = 0
    private var speed: UInt16 = 0
    private var status: UInt8 = 0
    /// Each voice's sample: its sound's address and its transposition (`Lb7a`, `Lb6e`).
    private var sampleAt = InlineArray<4, UInt32>(repeating: 0)
    private var transposition = InlineArray<4, UInt16>(repeating: 0)
    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    /// What Paula is doing with each voice, as the player and its interrupts have her: nothing (its DMA off,
    /// or what it was given played out); a loop; something that is heard to its end once she has gone round
    /// more times than `once` holds, and then nothing; or a loop with its release given her, to be begun
    /// once she has gone round more times than `release` holds.
    private enum Heard: Equatable { case quiet, looping, once(UInt16), release(UInt16) }
    private var heard = InlineArray<4, Heard>(repeating: .quiet)
    /// The voices started in the tick being run, each turned on after the player's wait, with what it is
    /// to play after its sample (its loop, or silence).
    private var starting: [(voice: Int, next: Int, length: UInt16)] = []

    /// For a check of the player against Wanted Team's: each write to Paula's registers as the player and
    /// its interrupts make it (the voice, the register's offset, the value; a location as its place in
    /// `memory`), when kept.
    var writes: [(voice: Int, register: Int, value: Int)]?

    /// The host's timer, as `InitSound` sets it ($CD0): a tick of 3,281 of the CIA's counts, five of Paula's
    /// clocks each.
    static let tickClocks = (0xCD0 + 1) * 5
    /// Where in the tick the player turns on the voices it has started (see the type's comment).
    static let onClocks = 3500
    /// A song that has not come to its end in half an hour is taken never to.
    private static let mostTicks = Int(Int64(30 * 60) * 3_546_895 / Int64(tickClocks))
    /// The most of a script run, and the deepest its values go, before it is taken to have gone wrong.
    private static let mostSteps = 100_000
    private static let deepest = 64

    /// The player's table of periods (`Lc80`), 128 words, by note (its 40th, $8B1, out of its order, as the
    /// player has it).
    private static let periodTable: [UInt16] = [UInt16](repeating: 0x1660, count: 22) + [
        0x151C, 0x13F0, 0x12D0, 0x11C0, 0x10C0, 0x0FD0, 0x0EF0, 0x0E18, 0x0D4C, 0x0C8E, 0x0BDA, 0x0B30,
        0x0A8F, 0x09F7, 0x0968, 0x08E1, 0x0861, 0x08B1, 0x0777, 0x070C, 0x06A7, 0x0647, 0x05ED, 0x0598,
        0x0547, 0x04FC, 0x04B4, 0x0470, 0x0430, 0x03F4, 0x03BC, 0x0386, 0x0353, 0x0324, 0x02F6, 0x02CC,
        0x02A4, 0x027E, 0x025A, 0x0238, 0x0218, 0x01FA, 0x01DE, 0x01C3, 0x01AA, 0x0192, 0x017B, 0x0166,
        0x0152, 0x013F, 0x012D, 0x011C, 0x010C, 0x00FD, 0x00EF, 0x00E2, 0x00D5, 0x00C9, 0x00BE, 0x00B3,
        0x00A9, 0x009F, 0x0096, 0x008E, 0x0086,
    ] + [UInt16](repeating: 0x7F, count: 41)
    /// The steps of packed sound, by its four bits (`L166c`).
    private static let deltas: [Int8] = [-34, -21, -13, -8, -5, -3, -2, -1, 1, 2, 3, 5, 8, 13, 21, 34]

    // MARK: - Reading

    @inline(__always) private func byte(_ at: UInt32) -> UInt8 { at < UInt32(contentEnd) ? memory[Int(at)] : 0 }
    @inline(__always) private func word(_ at: UInt32) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: UInt32) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }
    /// A write to the files, as the script makes them; none outside them.
    @inline(__always) private func poke(_ at: UInt32, _ value: UInt8) {
        if at >= UInt32(Self.moduleAt), at < UInt32(contentEnd) { memory[Int(at)] = value }
    }

    @inline(__always) private func hunkByte(_ at: Int) -> UInt8 { at >= 0 && at < hunk.count ? hunk[at] : 0 }
    @inline(__always) private func hunkWord(_ at: Int) -> UInt16 { UInt16(hunkByte(at)) << 8 | UInt16(hunkByte(at + 1)) }
    @inline(__always) private func hunkLong(_ at: Int) -> UInt32 { UInt32(hunkWord(at)) << 16 | UInt32(hunkWord(at + 2)) }
    @inline(__always) private mutating func setHunkByte(_ at: Int, _ value: UInt8) {
        if at >= 0, at < hunk.count { hunk[at] = value }
    }
    private mutating func setHunkWord(_ at: Int, _ value: UInt16) {
        setHunkByte(at, UInt8(value >> 8))
        setHunkByte(at + 1, UInt8(truncatingIfNeeded: value))
    }
    private mutating func setHunkLong(_ at: Int, _ value: UInt32) {
        setHunkWord(at, UInt16(value >> 16))
        setHunkWord(at + 2, UInt16(truncatingIfNeeded: value))
    }

    /// The script's variables are from `bss+$5C`.
    private static let variables = 0x5C
    /// The places of samples, eight bytes each from `bss+$80`.
    private static let places = 0x80

    // MARK: - Loading

    /// `L3C0`, the header's check, on a file's bytes from `at`: its base, if it has the header.
    private static func headerBase(_ read: (UInt32) -> UInt16, at: UInt32) -> UInt32? {
        var base = at
        if read(base &+ 4) != 0x16 {
            base &+= 6
            guard read(base &+ 4) == 0x16 else { return nil }
        }
        for i in 0 ..< 5 where read(base &+ 6 &+ UInt32(2 * i)) != 0 { return nil }
        guard read(base &+ 18) == 0x20, read(base &+ 22) == 0x20 else { return nil }
        let table = UInt32(read(base &+ 14)) << 16 | UInt32(read(base &+ 16))
        guard table & 1 == 0 else { return nil }
        let at = base &+ table
        guard UInt32(read(at)) << 16 | UInt32(read(at &+ 2)) == 0x58 else { return nil }
        return base
    }

    /// A word of a file's bytes, nought past them.
    private static func word(_ data: [UInt8], _ at: UInt32) -> UInt16 {
        Int(at) + 1 < data.count ? UInt16(data[Int(at)]) << 8 | UInt16(data[Int(at) + 1]) : 0
    }

    /// `Check2` (`$37C`), on a file's bytes: its header, and its resources, at least one a score, each at an
    /// even distance before the first that is not (with none before it, the file is refused); and whether
    /// its samples are in another (`L150`: no more than two resources not scores, all its resources counted).
    private static func check(_ data: [UInt8]) -> (base: UInt32, needsCompanion: Bool)? {
        func word(_ at: UInt32) -> UInt16 { Self.word(data, at) }
        func long(_ at: UInt32) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }
        guard let base = headerBase(word, at: 0) else { return nil }
        let table = base &+ long(base &+ 14)
        var entry = table &+ long(table)
        var scores = 0, others = 0
        while scores + others < 100_000 {
            let offset = long(entry)
            if offset == 0 || offset >> 24 != 0 { break }
            guard offset & 1 == 0 else { return scores > 0 ? (base, false) : nil }
            if word(entry &+ offset &+ 6) == 0xFF02 { scores += 1 } else { others += 1 }
            entry &+= 4
        }
        guard scores > 0 else { return nil }
        return (base, others <= 2)
    }

    /// True for a file the player's check takes (`Check2`).
    static func isOne(_ data: [UInt8]) -> Bool { check(data) != nil }

    /// True for one whose samples are in another file (`L150`): one of no more than two resources not scores,
    /// which `ExtLoad` loads the file of its name up to its first underscore for (`companionStem(of:)`).
    static func needsCompanion(_ data: [UInt8]) -> Bool { check(data)?.needsCompanion ?? false }

    /// The name, without its extension, of the file a module whose samples are in another has them in
    /// (`ExtLoad`, `$40A`): its own name up to its first underscore; nil for a name without one, for which
    /// the player fails to load them.
    static func companionStem(of fileName: String) -> String? {
        guard let underscore = fileName.firstIndex(of: "_") else { return nil }
        return String(fileName[..<underscore])
    }

    /// Reads the module, and the file of its samples if it has them in another (`samples`), and starts song
    /// `song` (the first, if it has no such song). A module `InitPlayer` refuses (cut short of its resources,
    /// or its script ended by an instruction the player does not have) is refused, as is one whose file of
    /// samples is not given, or has not the header.
    init(_ data: [UInt8], samples: [UInt8]? = nil, song: Int = 0) throws(TuneError) {
        let checked = Self.check(data)
        let needs = checked?.needsCompanion ?? false
        let companion = needs ? samples : nil
        let moduleEnd = Self.moduleAt + data.count
        let companionAt = companion.map { _ in (moduleEnd + 15) & ~15 }
        self.companionAt = companionAt
        if let companionAt, let companion { contentEnd = companionAt + companion.count } else { contentEnd = moduleEnd }
        silenceAt = (contentEnd + 16 + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[Self.moduleAt + i] = b }
        if let companion, let companionAt { for (i, b) in companion.enumerated() { memory[companionAt + i] = b } }
        hunk = [UInt8](repeating: 0, count: 384)
        base = UInt32(Self.moduleAt) &+ (checked?.base ?? 0)
        // (The file of samples has only its header checked, `L3C0`.)
        companionBase = companion.flatMap { file in Self.headerBase({ Self.word(file, $0) }, at: 0) }.map { UInt32(companionAt!) &+ $0 }
        // (`InitPlayer`: its resources counted, and the furthest's end, which must be within the file.)
        let found = Self.resources(memory, end: moduleEnd, base: base)
        songCount = max(1, found.scores)
        var failure: TuneError?
        if checked == nil {
            failure = .malformed("not a Silmarils module: the player's check does not take it")
        } else if Int32(bitPattern: found.end &- UInt32(Self.moduleAt)) > Int32(data.count) {
            failure = .malformed("the module is cut short of its resources")
        } else if needs, companion == nil {
            failure = .missingCompanion("Its samples are in another of the game's files, the one of its name up to its first underscore (\"NAME.mok\" for \"NAME_title.mok\"), which was not given with it.")
        } else if needs, companionBase == nil {
            failure = .malformed("the file given for its samples is not one of Silmarils'")
        }
        if failure == nil { failure = prepare(samples: found.samples) }
        // (Refused only once it is all made, that it may be undone as a whole.)
        if let failure { throw failure }
        try select(song: song >= 0 && song < songCount ? song : 0)
    }

    /// The rest of `InitPlayer`: the samples unpacked; the byte of two files `InitSound` is to clear; the
    /// script, for the song nought, and again for the first if it puts no sample in its places (or if the
    /// file's word at 24 is $CD00); whether any sample is transposed; for a module with its samples in
    /// another file, that file's samples unpacked; and all kept as it is left, for each song. A script ended
    /// by an instruction the player does not have refuses the module (`L624`).
    private mutating func prepare(samples count: Int) -> TuneError? {
        var samples = count
        if samples > 0, !unpack(at: UInt32(Self.moduleAt)) { return .malformed("a packed sample of it runs past its end") }
        // (The byte after a score that runs on into the next resource, in two files, which `InitSound` clears
        // to make that score's end there, `$FF` and nought: Le Fétiche Maya's second and Wind Surf Willy's first.)
        let module = UInt32(Self.moduleAt)
        if long(module + 15992) == 0x9BFF_020A {
            patch = Self.moduleAt + 15994
        } else if long(module + 13328) == 0xCFFF_020A {
            patch = Self.moduleAt + 13330
        }
        do {
            try script(from: base, song: 0)
            let first = hunkLong(Self.places)
            if word(module + 24) == 0xCD00 || (0 ..< 32).allSatisfy({ hunkLong(Self.places + 8 * $0) == first }) {
                songOffset = 1
                try script(from: base, song: 1)
            }
        } catch {
            return .malformed("its script is one the player cannot run")
        }
        transposed = (0 ..< 32).contains { hunkLong(Self.places + 8 * $0 + 4) != 0 }
        if let companionAt, let companionBase {
            let more = Self.resources(memory, end: contentEnd, base: companionBase)
            samples += more.samples
            if more.samples > 0, !unpack(at: UInt32(companionAt)) { return .malformed("a packed sample of its samples' file runs past its end") }
            songOffset = 1
        }
        sampleCount = samples
        pristine = Array(UnsafeBufferPointer(start: memory, count: contentEnd))
        pristineHunk = hunk
        pristineTempo = tempo
        pristineTranspositions = transposed
        return nil
    }

    deinit { memory.deallocate() }

    /// `L636`: a file's resources from its base: how many are scores and how many samples, and where the
    /// furthest ends.
    private static func resources(_ memory: UnsafeMutablePointer<UInt8>, end: Int, base: UInt32) -> (scores: Int, samples: Int, end: UInt32) {
        func byte(_ at: UInt32) -> UInt8 { at < UInt32(end) ? memory[Int(at)] : 0 }
        func word(_ at: UInt32) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
        func long(_ at: UInt32) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }
        let table = base &+ long(base &+ 14)
        var entry = table &+ long(table)
        var scores = 0, samples = 0
        var furthest: UInt32 = 0
        while scores + samples < 100_000 {
            let offset = long(entry)
            if offset == 0 || offset >> 24 != 0 { break }
            let at = entry &+ offset
            // (Compared as the 68000 compares addresses, with their signs.)
            if Int32(bitPattern: at) > Int32(bitPattern: furthest) { furthest = at }
            if word(at &+ 6) == 0xFF02 { scores += 1 } else { samples += 1 }
            entry &+= 4
        }
        return (scores, samples, furthest &+ long(furthest &+ 2))
    }

    /// `L15B4`: the samples of a file whose sound is packed (kind 1 or 2, its byte 6 one): half its room
    /// holds the packed bytes, copied out and unpacked over it, the first as it is and then each four bits a
    /// step from the byte before (`L166c`); the last two bytes made nought, and two taken off its size.
    /// (The resources found from the file's start, not its base, as the player finds them, the table's word
    /// at 16 their number: a file with the header of six bytes has none unpacked. The counts are the words
    /// the player's loops count, as the 68000 counts them.)
    private mutating func unpack(at file: UInt32) -> Bool {
        let table = file &+ long(file &+ 14)
        let count = Int(word(table &+ 16))
        guard count > 0 else { return true }
        var entry = table &+ long(table &+ 12)
        var work = 0
        for _ in 0 ..< count {
            let sample = entry &+ long(entry)
            entry &+= 4
            guard byte(sample) == 1 || byte(sample) == 2, byte(sample &+ 6) == 1 else { continue }
            let size = long(sample &+ 2)
            let half = (size &- 16) >> 1
            // (Copied a word at a time, `half` / 2 words; and unpacked from the copy, `half` - 1 bytes after its
            // first, what the copy has not read as nought.)
            let copied = 2 * (Int(UInt16(truncatingIfNeeded: (half >> 1) &- 1)) + 1)
            let unpacked = Int(UInt16(truncatingIfNeeded: half &- 2)) + 1
            // (One whose sound would be unpacked past the files, which the player would unpack over what
            // follows in the Amiga's memory, refuses the module.)
            guard sample >= UInt32(Self.moduleAt), Int(sample) + 17 + 2 * unpacked <= contentEnd else { return false }
            // (Nor may a broken table have more unpacked than the files hold, a few times over.)
            work += unpacked
            guard work <= 4 * contentEnd else { return false }
            var packed = [UInt8](repeating: 0, count: max(copied, unpacked + 1))
            for k in 0 ..< copied { packed[k] = byte(sample &+ 16 &+ UInt32(k)) }
            var out = sample &+ 16
            var value = packed[0]
            poke(out, value)
            out &+= 1
            for k in 1 ... unpacked {
                value = value &+ UInt8(bitPattern: Self.deltas[Int(packed[k] >> 4)])
                poke(out, value)
                value = value &+ UInt8(bitPattern: Self.deltas[Int(packed[k] & 15)])
                poke(out &+ 1, value)
                out &+= 2
            }
            poke(out &- 2, 0)
            poke(out &- 1, 0)
            let smaller = size &- 2
            for k in 0 ..< 4 { poke(sample &+ 2 &+ UInt32(k), UInt8(truncatingIfNeeded: smaller >> UInt32(24 - 8 * k))) }
        }
        return true
    }
}

// MARK: - The script

extension SilmarilsPlayer {
    /// The script gone wrong: an instruction or value the player does not have (`L11E0`), or one run off
    /// into the weeds.
    private struct Abort: Error {}

    /// `L6BC`: the script's stack and the variables before the samples' places cleared, the base of the file
    /// it is run on set (`L48`), the song for it (the word at 12), and it run from 24 past the base (26, past a
    /// word $A142, which makes the player take its samples as untransposed).
    private mutating func script(from file: UInt32, song: UInt16) throws(Abort) {
        for i in 0 ..< 0x80 { hunk[i] = 0 }
        setHunkLong(0x48, file)
        setHunkWord(0x68, song)
        pc = file &+ 24
        if word(pc) == 0xA142 {
            pc &+= 2
            transposed = false
        }
        stack = 0xFFAC
        try run()
    }

    private mutating func fetch() -> UInt8 {
        let b = byte(pc)
        pc &+= 1
        return b
    }

    private mutating func fetchWord() -> UInt16 {
        let high = UInt16(fetch()) << 8
        return high | UInt16(fetch())
    }

    /// Three bytes, a distance with its sign.
    private mutating func fetchDistance() -> UInt32 {
        let high = UInt32(bitPattern: Int32(Int8(bitPattern: fetch()))) << 16
        return high | UInt32(fetchWord())
    }

    /// `L11EC`: the script run, an instruction at a time (`Lef8`), until it ends (`$3F`, `$42`).
    private mutating func run() throws(Abort) {
        d7 = 0
        steps = 0
        depth = 0
        while true {
            steps += 1
            guard steps < Self.mostSteps else { throw Abort() }
            let op = fetch()
            switch op {
            case 0x05:
                // A call, a byte's distance on.
                let distance = UInt32(bitPattern: Int32(Int8(bitPattern: fetch())))
                push()
                pc &+= distance
            case 0x06:
                let distance = UInt32(bitPattern: Int32(Int16(bitPattern: fetchWord())))
                push()
                pc &+= distance
            case 0x07:
                let distance = fetchDistance()
                push()
                pc &+= distance
            case 0x0A:
                pc &+= fetchDistance()
            case 0x11:
                // A return (`$124C`); the word at -12 cleared, if it holds the stack's place.
                pc = hunkLong(Self.variables + Int(Int16(bitPattern: stack)))
                if stack == hunkWord(Self.variables - 12) { setHunkWord(Self.variables - 12, 0) }
                stack &+= 4
            case 0x14:
                // A jump if the value is nought.
                if d7 == 0 { pc &+= fetchDistance() } else { pc &+= 3 }
            case 0x15:
                // A short jump if it is not.
                if d7 != 0 { pc &+= UInt32(bitPattern: Int32(Int8(bitPattern: fetch()))) } else { pc &+= 1 }
            case 0x1E:
                // A value, kept (`$128C`).
                d6 = d7
                try operand()
                try store()
            case 0x1F:
                d6 = d7
                try operand()
            case 0x20:
                // A value added to a variable's word (`$12A6`).
                d6 = d7
                try operand()
                guard fetch() == 0x14 else { throw Abort() }
                let at = Self.variables + Int(fetch())
                setHunkWord(at, hunkWord(at) &+ d7)
            case 0x2E:
                // `$12CC`: the value looked for in a table of words, in order (an even place): at one equal to it,
                // a jump by the word after it; past them, or at one greater, on after the table.
                try operand()
                var left = UInt16(fetch())
                if pc & 1 != 0 { pc &+= 1 }
                while true {
                    let entry = word(pc)
                    pc &+= 2
                    if entry == d7 {
                        pc = pc &+ 2 &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(pc))))
                        break
                    }
                    pc &+= 2
                    if Int16(bitPattern: d7) < Int16(bitPattern: entry) {
                        pc &+= UInt32(left) * 4
                        break
                    }
                    left &-= 1
                    if left == 0xFFFF { break }
                }
            case 0x2F:
                // `$1300`: a jump by the value, less the table's first word, to one of its words' distances, or
                // past the table.
                try operand()
                let last = UInt16(fetch())
                if pc & 1 != 0 { pc &+= 1 }
                let index = d7 &+ word(pc)
                d7 = index
                pc &+= 2
                if index & 0x8000 != 0 || index > last {
                    pc &+= UInt32(last) * 2 + 2
                } else {
                    d7 = index &* 2
                    pc &+= UInt32(index) * 2
                    pc = pc &+ 2 &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(pc))))
                }
            case 0x3F:
                // (The end, the byte at -4 cleared: `$1330`, with the byte at $159D, which is one.)
                setHunkByte(Self.variables - 4, 0)
                return
            case 0x40:
                // A variable made -1 (a word passed over).
                pc &+= 2
                d7 = 0xFFFF
                try store()
            case 0x42:
                return
            case 0x95:
                // `$13F0`: the music started: a score (a resource of kind nought or 3, its data from 6) and five
                // values, of which the second is its tempo (the others the game's, for its fading).
                try operand()
                let at = resource(d7)
                if byte(at) == 0 || byte(at) == 3 {
                    scoreAt = at &+ 6
                    try operand()
                    try operand()
                    tempo = UInt8(truncatingIfNeeded: d7)
                    for _ in 0 ..< 3 { try operand() }
                } else {
                    for _ in 0 ..< 5 { try operand() }
                }
            case 0x97:
                // `$1340`: the tempo (nought taken as one).
                try operand()
                if d7 == 0 { d7 = 1 }
                tempo = UInt8(truncatingIfNeeded: d7)
            case 0xA1:
                break
            case 0xCD:
                // `$1388`: a sample put in a place: the place, the resource (none, below nought) and its
                // transposition. A resource not a sample is not put.
                try operand()
                let place = d7
                try operand()
                let number = d7
                try operand()
                var transposition = d7
                d6 = place
                d7 = number
                var sound: UInt32 = 0
                if number & 0x8000 != 0 {
                    transposition = 0
                } else {
                    let at = resource(number)
                    guard byte(at) == 1 || byte(at) == 2 else { continue }
                    sound = at &+ 16
                }
                let slot = Self.places + Int(place & 0x1F) * 8
                setHunkLong(slot, sound)
                setHunkWord(slot + 4, transposition)
            case 0xD5:
                try operand()
            default:
                throw Abort()
            }
        }
    }

    /// A call's return place kept on the script's stack, which is in the second hunk below its variables.
    private mutating func push() {
        stack &-= 4
        setHunkLong(Self.variables + Int(Int16(bitPattern: stack)), pc)
    }

    /// `L1356`: resource `number`'s address, of the file whose base is at `bss+$48`: its table (at 14), the
    /// list's distance (the table's fourth long), the list, the resource's long.
    private func resource(_ number: UInt16) -> UInt32 {
        var at = hunkLong(0x48)
        at &+= long(at &+ 14)
        at &+= long(at &+ 12)
        at &+= UInt32(bitPattern: Int32(Int16(bitPattern: number &* 4)))
        return at &+ long(at)
    }

    /// A value, of an instruction. (A closing bracket outside brackets would end more than the value, in the
    /// 68000's stack: not followed.)
    private mutating func operand() throws(Abort) {
        if try value() { throw Abort() }
    }

    /// `L14E4`: a value, into D7 (`L10ba`): a byte or word as it is (`$00`, `$02`), a variable's byte or word
    /// (`$12`, `$14`), a byte of the file from its base (`$1E`), values in brackets (`$38` to `$3A`), and
    /// the value before (kept in D6) compared with, added to or less the next (`$4A`, `$4E`, `$56`, `$58`).
    /// Returns true at a closing bracket.
    private mutating func value() throws(Abort) -> Bool {
        steps += 1
        guard steps < Self.mostSteps else { throw Abort() }
        let op = fetch()
        switch op {
        case 0x00:
            d7 = UInt16(bitPattern: Int16(Int8(bitPattern: fetch())))
        case 0x02:
            d7 = fetchWord()
        case 0x12:
            d7 = UInt16(bitPattern: Int16(Int8(bitPattern: hunkByte(Self.variables + Int(fetch())))))
        case 0x14:
            d7 = hunkWord(Self.variables + Int(fetch()))
        case 0x1E:
            let offset = fetchWord()
            d7 = UInt16(bitPattern: Int16(Int8(bitPattern: byte(base &+ UInt32(bitPattern: Int32(Int16(bitPattern: offset)))))))
        case 0x38:
            depth += 1
            guard depth < Self.deepest else { throw Abort() }
            while try !value() {}
            depth -= 1
        case 0x3A:
            return true
        case 0x4A, 0x4E, 0x56, 0x58:
            d6 = d7
            // (A closing bracket here would end the brackets around it, in the 68000's stack: not followed.)
            guard try !value() else { throw Abort() }
            switch op {
            case 0x4A: d7 = d7 == d6 ? 0xFFFF : 0
            case 0x4E: d7 = Int16(bitPattern: d6) <= Int16(bitPattern: d7) ? 0xFFFF : 0
            case 0x56: d7 = d7 &+ d6
            default: d7 = d6 &- d7
            }
        default:
            throw Abort()
        }
        return false
    }

    /// `L1164`: the value kept: in a variable's byte or word, or a byte of the file from its base.
    private mutating func store() throws(Abort) {
        switch fetch() {
        case 0x12: setHunkByte(Self.variables + Int(fetch()), UInt8(truncatingIfNeeded: d7))
        case 0x14: setHunkWord(Self.variables + Int(fetch()), d7)
        case 0x1E:
            let offset = fetchWord()
            poke(base &+ UInt32(bitPattern: Int32(Int16(bitPattern: offset))), UInt8(truncatingIfNeeded: d7))
        default: throw Abort()
        }
    }
}

// MARK: - Playing

extension SilmarilsPlayer {
    /// Starts song `song`; and finds how long it is, played through to its end for up to half an hour.
    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        let logging = writes
        writes = nil
        start()
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, stops == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again, or its stop.)
        lengthClocks = endings > 0 || stops > 0 ? UInt64(max(0, ticks - 1)) * UInt64(Self.tickClocks) : nil
        writes = logging
        start()
    }

    /// `InitSound`: the files and the player's hunk as `InitPlayer` left them; the script run for the song (on
    /// the samples' file first, if the module has one, and then on from where the module's ended, as the
    /// player runs it); the score found, its tempo, and the voices quiet.
    private mutating func start() {
        for (i, b) in pristine.enumerated() { memory[i] = b }
        hunk = pristineHunk
        tempo = pristineTempo
        transposed = pristineTranspositions
        scoreAt = 0
        endings = 0
        stops = 0
        let asked = songOffset &+ UInt16(song)
        do {
            if let companionBase {
                // (`L6F4`: the companion's script, its base in `bss+$48`, but nothing cleared nor the song
                // set; then the module's, and on from where that ended, `L6F8`.)
                setHunkLong(0x48, companionBase)
                pc = companionBase &+ 24
                stack = 0xFFAC
                try run()
                try script(from: base, song: asked)
                try run()
            } else {
                try script(from: base, song: asked)
            }
        } catch {
            // (A script gone wrong leaves the player silent: `L14C`.)
            scoreAt = 0
        }
        if scoreAt != 0, song == 2, long(scoreAt &- 2) == 0x03B0_FF02 {
            // (The third song of a file whose script would play the second's score, of 944 bytes, the score
            // after it: Starblade's.)
            scoreAt &+= 944
        }
        if let patch { memory[patch] = 0 }
        speed = UInt16(tempo & 0x7F) << 3
        if !transposed { speed &-= 7 }
        position = scoreAt
        counter = 0
        status = 0
        sampleAt = .init(repeating: 0)
        transposition = .init(repeating: 0)
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        heard = .init(repeating: .quiet)
        starting.removeAll()
        if scoreAt == 0 { stops = 1 }
    }

    /// The player's interrupt (`$718`, `La3E`), for a tick: the count down by the tempo, and once it is done
    /// the score read on to its next wait; at the end of the tick, after the wait for the beam, the voices
    /// started turned on (`La1A`). And, at its start, what Paula's audio interrupts did since the tick before.
    /// Returns the tick's length in milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        guard stops == 0 else { return 0 }
        for v in 0 ..< 3 {
            switch heard[v] {
            case let .release(turns) where output.loopCount(v) > turns:
                // (She has gone on to the release: silence after it, its interrupt's stopping the voice.)
                output.takeNextBuffer(v, start: silenceAt, length: 2)
                heard[v] = .once(output.loopCount(v))
            case let .once(turns) where output.loopCount(v) > turns:
                heard[v] = .quiet
            default: break
            }
        }
        if counter > speed {
            counter -= speed
            return 0
        }
        counter = 0
        starting.removeAll(keepingCapacity: true)
        var at = position
        var restarted = false
        while true {
            // (A score read on past the files, which the player would read on through the Amiga's memory, is
            // stopped there.)
            guard at < UInt32(contentEnd) else {
                stopAll(&output)
                return 0
            }
            var command = byte(at)
            at &+= 1
            let repeated = command < 0x80
            if repeated {
                at &-= 1
                command = status
            } else if command == 0xFF {
                command = byte(at)
                at &+= 1
                status = command
            } else {
                counter = UInt16(command - 0x80) << 8
                position = at
                break
            }
            if command == 0xFF { command = 0 }
            let v = Int(command >> 6)
            let kind = command & 0x3F
            if kind == 0 {
                // `$A94`: the score again from its start, EaglePlayer told the song has ended. (Twice in a tick
                // without a wait between, the player would never end the tick: the song is stopped.)
                guard !restarted else {
                    stopAll(&output)
                    return 0
                }
                restarted = true
                status = 0
                endings += 1
                at = scoreAt
                continue
            }
            // (The player's tables are of three voices, and of four commands: with any other, it would go wrong.)
            guard v < 3, kind <= 3 else {
                stopAll(&output)
                return 0
            }
            switch kind {
            case 2:
                // `$AD0`: the voice's sample, from its place.
                let place = Self.places + Int(byte(at)) * 8
                at &+= 1
                sampleAt[v] = hunkLong(place)
                transposition[v] = hunkWord(place + 4)
            case 1:
                note(v, number: byte(at), volume: byte(at &+ 1), &output)
                at &+= 2
            default:
                // (Repeated, it takes no byte, and the player would read the same one for ever: stopped.)
                guard !repeated else {
                    stopAll(&output)
                    return 0
                }
                release(v, &output)
            }
        }
        if !starting.isEmpty {
            output.timed(at: Self.onClocks)
            for start in starting {
                output.on(start.voice)
                output.takeNextBuffer(start.voice, start: start.next, length: start.length)
            }
            starting.removeAll(keepingCapacity: true)
        }
        return 0
    }

    /// The song stopped, its voices turned off, as at an end the player does not come back from.
    private mutating func stopAll<Output: TFMXOutput>(_ output: inout Output) {
        for v in 0 ..< 3 { output.off(v) }
        heard = .init(repeating: .quiet)
        starting.removeAll()
        stops += 1
    }

    /// Where an address is in `memory`, as Paula is pointed at it: silence for one past it.
    private func place(_ address: UInt32) -> Int { address < UInt32(memoryCapacity) ? Int(address) : silenceAt }

    /// `$BB0`: a note: the voice's interrupt kept back and its DMA turned off; with a volume, Paula told the
    /// voice's sample, the length to its loop's end (or its own), the note's period (its number and the
    /// sample's transposition, from the table) and the volume (seven bits); and the voice's DMA turned on at
    /// the tick's end, its interrupt then giving it its loop, or for a sample whose loop begins at nought,
    /// silence once it has been heard.
    private mutating func note<Output: TFMXOutput>(_ v: Int, number: UInt8, volume: UInt8, _ output: inout Output) {
        output.off(v)
        heard[v] = .quiet
        starting.removeAll { $0.voice == v }
        guard volume != 0 else { return }
        let sample = sampleAt[v]
        var end = long(sample &- 4)
        if end == 0 { end = long(sample &- 14) &- 16 }
        let length = UInt16(truncatingIfNeeded: end >> 1)
        output.takeNextBuffer(v, start: place(sample), length: length)
        log(v, 0, Int(sample))
        log(v, 4, Int(length))
        // (The table's index a word, with its sign; past its 128 notes, the ends of the table.)
        let index = Int(Int16(bitPattern: (UInt16(number) &+ transposition[v]) &* 2)) / 2
        periods[v] = Self.periodTable[max(0, min(Self.periodTable.count - 1, index))]
        volumes[v] = UInt16(volume & 0x7F)
        log(v, 6, Int(periods[v]))
        log(v, 8, Int(volumes[v]))
        let loop = long(sample &- 8)
        if loop != 0 {
            // (`$D80`: the loop, to its end or the sample's.)
            let length = UInt16(truncatingIfNeeded: (end &- loop) >> 1)
            starting.append((v, place(sample &+ loop), length))
            log(v, 0, Int(sample &+ loop))
            log(v, 4, Int(length))
            heard[v] = .looping
        } else {
            starting.append((v, silenceAt, 2))
            heard[v] = .once(0)
        }
    }

    /// `$AF4`: the release of a sample with a loop's end: its sound after it, told Paula as the length and
    /// place to go on to, and the voice's DMA turned off and on again at once (which she, still playing, does
    /// not notice: she goes on to it once she has gone round the loop, and then to silence; a voice she has
    /// stopped is started on it). Of a sample without one, or with nothing after it, the voice turned off.
    private mutating func release<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let sample = sampleAt[v]
        let end = long(sample &- 4)
        let rest = long(sample &- 14) &- 16 &- end
        guard end != 0, Int32(bitPattern: rest) > 0, rest >> 1 != 0 else {
            output.off(v)
            heard[v] = .quiet
            starting.removeAll { $0.voice == v }
            return
        }
        let length = UInt16(truncatingIfNeeded: rest >> 1)
        log(v, 4, Int(length))
        log(v, 0, Int(sample &+ end))
        if let pending = starting.firstIndex(where: { $0.voice == v }) {
            // (A note of this tick, not yet started: its sample is the release.)
            output.takeNextBuffer(v, start: place(sample &+ end), length: length)
            starting[pending].next = silenceAt
            starting[pending].length = 2
            heard[v] = .once(0)
        } else if heard[v] == .quiet {
            output.takeNextBuffer(v, start: place(sample &+ end), length: length)
            output.on(v)
            output.takeNextBuffer(v, start: silenceAt, length: 2)
            heard[v] = .once(0)
        } else {
            output.takeNextBuffer(v, start: place(sample &+ end), length: length)
            heard[v] = .release(output.loopCount(v))
        }
    }

    private mutating func log(_ v: Int, _ register: Int, _ value: Int) {
        writes?.append((v, register, value))
    }

    /// Paula's period for the voice as the player left it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice as she takes it: no more than 64.
    func volume(_ voice: Int) -> UInt16 { min(64, volumes[voice]) }
}

/// Silmarils' music, played on Paula by `PaulaTickRenderer`.
extension SilmarilsPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Silmarils")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "the music of Silmarils' games, by their own replayer; \(sampleCount) sample\(plural)"
        return info
    }

    /// Silmarils' music is louder on the Amiga's chip than ProTracker's is, by 6.5 dB in the middle of its 14
    /// files in UnExoticA's collection (by BS.1770 loudness, over their first song's first minute, against 40
    /// ProTracker modules), and is turned down by that (2026-10-25).
    var gain: Float { 0.22 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
