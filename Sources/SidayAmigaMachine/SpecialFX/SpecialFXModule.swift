// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Special FX's modules ("Special FX player module V1.1 (25 Mar
// 2007)", carried by UADE as players/Special-FX), whose source UADE also carries (amigasrc/players/
// wanted_team/SpecialFX/"Special FX_v2.asm", of which the player UADE runs is the build). The routines
// and labels named are that source's.

import SidayFoundation

/// What Wanted Team's player finds in one of Special FX's modules, which is the 68000 driver the studio's
/// musicians played their music with on the Amiga (the player credits it to Matthew Cannon and Jonathan
/// Dunn), with the music and its samples after it: where to start a song and where to play a tick, how
/// many songs there are and where their table is, and what it changes in the module before it is run.
///
/// A module begins with a table of branches into the driver: four of them in its older form, as the
/// player has it (the first readies the samples, the third starts a song and the fourth plays a tick),
/// seven in its newer (`NewFormat`: the first readies the samples, the fifth starts a song and the
/// seventh plays a tick). The driver was assembled to run at one address (its origin), and refers to its own
/// variables and tables by their addresses there: the player moves it to wherever it is loaded, by
/// finding each instruction of the kinds the driver refers to itself with and changing the address in
/// it (`InitPlayer`), as UADE's host runs it.
struct SpecialFXModule {
    /// Seven branches at the start, or four.
    var sevenBranches = false
    /// Offsets into the module: the branch that starts a song (with its number, from 1, in D0), and the
    /// one that plays a tick. (The first, at 0, readies the samples.)
    var initAt = 0
    var playAt = 0
    /// Where the driver's code begins and ends (its last RTS before its table of periods), which is all
    /// the player moves and patches, and the table of periods.
    var firstCode = 0
    var codeEnd = 0
    var periods = 0
    /// The address the driver was assembled to run at.
    var origin: UInt32 = 0
    var songCount = 0
    /// The table of songs, as an address where the module is put: eight bytes to a song, a word for each
    /// voice, nought for a voice the song does not use, else the distance from it to the voice's list.
    var songTable: UInt32 = 0
    /// How many instruments of the driver's table of them (sixteen bytes to each) have their sounds in the
    /// driver's own data, and so their addresses moved by the player (`NextSynth`): those before the
    /// first that the driver's start makes of one of the module's samples.
    var ownInstruments = 0
    /// The text a module begins with after its branches, where Wanted Team put one (who made the music,
    /// and that they ripped it); empty where there is none.
    var text = ""
    /// The module, moved to where it is put, with the player's fixes made (`emptySampleFixed`, `leaFixes`);
    /// not yet patched (`SpecialFXPlayer.patch`).
    var image: [UInt8] = []
    /// The player's fix of New Zealand Story's empty sample (`NoZealand`), and how many `LEA $A8.W,A1` it
    /// made a call of its own code that gives A1 `$DFF0A8` (`Fix`), as the driver meant.
    var emptySampleFixed = false
    var leaFixes = 0

    /// Nothing found, for a module that is refused.
    static let none = SpecialFXModule()

    private init() {}

    /// The module's bytes, read and changed as the player reads and changes them; a read past either end
    /// refuses it (where the player would read on through the memory beyond, and go wrong).
    private struct Bytes {
        var data: [UInt8]

        func byte(_ at: Int) throws(TuneError) -> Int {
            guard at >= 0, at < data.count else {
                throw .malformed("a module of Special FX's that is cut short, or whose driver is not as theirs are")
            }
            return Int(data[at])
        }

        func word(_ at: Int) throws(TuneError) -> Int { try byte(at) << 8 | byte(at + 1) }
        func signedWord(_ at: Int) throws(TuneError) -> Int { Int(Int16(truncatingIfNeeded: try word(at))) }
        func long(_ at: Int) throws(TuneError) -> UInt32 { UInt32(try word(at)) << 16 | UInt32(try word(at + 2)) }

        mutating func setWord(_ at: Int, _ value: Int) throws(TuneError) {
            _ = try word(at)
            data[at] = UInt8(truncatingIfNeeded: value >> 8)
            data[at + 1] = UInt8(truncatingIfNeeded: value)
        }

        mutating func setLong(_ at: Int, _ value: UInt32) throws(TuneError) {
            try setWord(at, Int(value >> 16))
            try setWord(at + 2, Int(value & 0xFFFF))
        }

        /// The place of the first word from `at` on that is `value`, as the player's loops of
        /// `CMP.W (A1)+,D1; BNE` find it.
        func find(_ value: Int, from at: Int) throws(TuneError) -> Int {
            var at = at
            while try word(at) != value { at += 2 }
            return at
        }
    }

    // MARK: The check

    /// The player's check (`Check2`): a `BRA.W` forward by an even distance, three more, and either three
    /// more and no eighth, or a BSR where the first goes; and where it goes (past that BSR), a `LEA
    /// abs.L,A0` and a `LEA abs.L,A1`.
    static func isOne(_ data: [UInt8]) -> Bool {
        let m = Bytes(data: data)
        do {
            func branch(_ at: Int) throws(TuneError) -> Bool {
                guard try m.word(at) == 0x6000 else { return false }
                let distance = try m.signedWord(at + 2)
                return distance > 0 && distance & 1 == 0
            }
            guard try branch(0), try branch(4), try branch(8), try branch(12) else { return false }
            var a1 = 2 + (try m.signedWord(2))
            if try m.word(16) == 0x6000 {
                guard try branch(16), try branch(20), try branch(24), try m.word(28) != 0x6000 else { return false }
            } else {
                guard try m.word(a1) == 0x6100 else { return false }
                a1 += 4
            }
            return try m.word(a1) == 0x41F9 && m.word(a1 + 6) == 0x43F9
        } catch {
            return false
        }
    }

    // MARK: The ways in

    /// How far into an instruction the address is that the player moves (`Back`), for each kind it moves
    /// the address in: past an immediate word, or straight after the instruction's own word.
    private static func addressIn(_ op: Int) -> Int? {
        switch op {
        case 0x0279, 0x13FC, 0x33FC: 4
        case 0x13C0, 0x2079, 0x23C8, 0x3039, 0x3239, 0x33C7, 0x3439, 0x41F9, 0x4279, 0x42B9, 0x43F9, 0x45F9,
             0x47F9, 0x49F9, 0x4A79, 0x4BF9, 0x5279, 0x8179, 0x8379, 0x8F79, 0xB039: 2
        default: nil
        }
    }

    /// Finds the driver's ways in, its songs and its tables, and moves it to `address`, as the player's
    /// `InitPlayer` does. `initFix` is the address of the code that gives A1 `$DFF0A8`, which a `LEA
    /// $A8.W,A1` is made a call of (through a JMP the player puts at the module's eighth byte).
    init(_ data: [UInt8], at address: UInt32, initFix: UInt32) throws(TuneError) {
        guard Self.isOne(data) else { throw .unsupported("not a module of Special FX's") }
        var m = Bytes(data: data)
        // (The periods' first and last, the old driver's and then the new's.)
        var periodEnds: UInt32 = 0x005F_0166
        var a1: Int
        sevenBranches = try m.word(16) == 0x6000
        if sevenBranches {
            initAt = 16
            playAt = 24
            a1 = 2 + (try m.signedWord(2))
            firstCode = a1
            let after = try m.find(0x77, from: a1) + 2
            if try m.word(after - 4) == 0x7E { periodEnds = 0x0077_01BF }
        } else {
            // (`NoZealand`: New Zealand Story's empty sample, two bytes too long.)
            if data.count >= 2422, try m.long(2418) == 0xF3EE {
                try m.setLong(2418, 0xF3EC)
                emptySampleFixed = true
            }
            initAt = 8
            playAt = 12
            firstCode = try m.find(0x48E7, from: 12)
            a1 = firstCode + 2
        }
        // The driver's `LEA periods,A5`, which says where the table of periods is in its origin's terms,
        // and so the origin; its code ends with the last RTS before the table.
        a1 = try m.find(0x4BF9, from: a1) + 2
        let periodsAddress = try m.long(a1)
        periods = try m.find(Int(periodEnds & 0xFFFF), from: a1 + 4)
        origin = periodsAddress &- UInt32(periods)
        var end = periods
        repeat { end -= 2 } while try m.word(end) != 0x4E75
        codeEnd = end
        guard codeEnd > firstCode else { throw .malformed("a module of Special FX's whose driver has no code before its periods") }

        // Every address the driver's code has of its own is moved (`Back`), but those of the chips.
        var at = firstCode
        while true {
            let op = try m.word(at)
            if let skip = Self.addressIn(op) {
                at += skip
                // (The player looks again at the address's first word, as an instruction, when it is
                // the chips'.)
                if try m.word(at) == 0x00DF { continue }
                try m.setLong(at, try m.long(at) &- origin &+ address)
                at += 4
                continue
            }
            if op == 0x43F8 {
                guard try m.word(at + 2) == 0xA8 else { throw .malformed("a module of Special FX's with a LEA the player does not know") }
                try m.setWord(8, 0x4EF9)
                try m.setLong(10, initFix)
                try m.setWord(at, 0x6100)
                try m.setWord(at + 2, 6 - at)
                at += 4
                leaFixes += 1
                continue
            }
            at += 2
            // (Its end is looked for only here: an instruction moved that ends on it is gone past.)
            if at == codeEnd { break }
        }

        // The table of instruments, from the last period up to the address the driver's start gives A1
        // (`NextSynth`): in each, the addresses of its sample and of its loop, where it has them.
        var entry = try m.find(Int(periodEnds >> 16), from: codeEnd) + 2
        var lea = 2 + (try m.signedWord(2))
        if try m.word(lea) == 0x6100 { lea += 4 }
        lea += 6
        guard try m.word(lea) == 0x43F9 else { throw .malformed("a module of Special FX's whose start is not as theirs are") }
        let instrumentsEnd = try m.long(lea + 2)
        var count = 0
        repeat {
            if try m.long(entry + 2) != 0 {
                try m.setLong(entry + 2, try m.long(entry + 2) &- origin &+ address)
                if try m.long(entry + 8) != 0 { try m.setLong(entry + 8, try m.long(entry + 8) &- origin &+ address) }
            }
            entry += 16
            count += 1
        } while address &+ UInt32(entry) != instrumentsEnd
        ownInstruments = count

        // The count of songs, from the driver's start of a song: its `CMP.W #n,D0` before a `BCS.S`; and
        // the table, from its `LEA songs,A0` before an `ASL.W #3,D0` (`FindSub`, `FindSong`).
        var search = initAt + 2 + (try m.signedWord(initAt + 2))
        search = try m.find(0x6508, from: search) + 2
        songCount = try m.word(search - 4)
        search = try m.find(0xE740, from: search) + 2
        songTable = try m.long(search - 6)
        guard songCount > 0 else { throw .malformed("a module of Special FX's with no songs") }
        let tableAt = Int(songTable &- address)
        guard songTable >= address, tableAt + songCount * 8 <= data.count else {
            throw .malformed("a module of Special FX's whose table of songs is not in it")
        }

        var text = String.UnicodeScalarView()
        var t = sevenBranches ? 28 : 16
        while t < firstCode, t < data.count, data[t] >= 0x20, data[t] < 0x7F {
            text.append(Unicode.Scalar(data[t]))
            t += 1
        }
        self.text = text.count >= 8 ? String(text) : ""
        image = m.data
    }

    /// The voices a song has (`InitSound`): how many, and the player's long of the voices that have yet to
    /// reach the end of their lists, a byte each, nought for each the song does not use ('WTWT' to begin).
    func voices(_ song: Int, at address: UInt32) -> (count: Int, waiting: UInt32) {
        var count = 0
        var waiting: UInt32 = 0x5754_5754
        let entry = Int(songTable &- address) + song * 8
        for v in 0 ..< 4 {
            let at = entry + 2 * v
            let word = at + 1 < image.count ? Int(image[at]) << 8 | Int(image[at + 1]) : 0
            if word == 0 {
                waiting &= ~(0xFF00_0000 >> UInt32(8 * v))
            } else {
                count += 1
            }
        }
        return (count, waiting)
    }
}
