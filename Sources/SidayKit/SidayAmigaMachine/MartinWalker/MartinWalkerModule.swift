// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Martin Walker's modules ("Martin Walker player module V1.1
// (20 July 2001)", carried by UADE as players/MartinWalker), from its source as UADE has it
// (amigasrc/players/wanted_team/MartinWalker/src/Martin Walker_v2.asm, which is of V1.1, the build UADE
// runs). Its routines are named as the source names them.

/// What Wanted Team's player finds in one of Martin Walker's modules, which is his own 68000 driver with
/// its music after it: where to start a song and where to play a tick, the table of songs, how many
/// there are, and what it changes in the module before it is run.
///
/// A module is one of five kinds, as the player's check (`Check2`) finds them. The first is the driver
/// alone, beginning with the routine that starts a song (`MOVEM.L D0-D5/A0-A6,-(A7)`), whose song is in
/// D1; its routine for a tick follows the first's RTS. The second has a driver of sound effects before
/// the music's (beginning `MOVE.L A0,-(A7)`), whose first routine readies them and is called once as the
/// module is loaded. The third and fourth begin with a table of BRAs to the driver's routines, the
/// fourth of which starts a song: of the third (eight BRAs) the first readies the sound effects, as the
/// second's does. The fifth (ten BRAs) starts a song at its sixth, which only asks for it, and plays a
/// tick at its seventh, which starts the song asked for on its first tick.
struct MartinWalkerModule {
    /// The fifth kind (the player's `Format`, set by its check).
    var fifth: Bool
    /// The module's start is called once as it is loaded, before the player finds its way about it.
    var setsUp: Bool
    /// Offsets into the module: the routine that starts a song (`InitPtr`), the one that plays a tick
    /// (`PlayPtr`), the table of songs (`FirstSubsongPtr`, sixteen bytes a song) and what follows it (the
    /// voices' lists of steps, `StepsPtr`); and how many songs the table has.
    var initAt: Int
    var playAt: Int
    var songTable: Int
    var steps: Int
    var songCount: Int
    /// The offsets of two of the driver's variables in its patterns the player looks for (`ChangeIt4`,
    /// `ChangeIt6`): the first in a CMP.B of a voice's volume, which the player finds in the driver of a
    /// module it calls the start of, by the `MOVE.L D6,D5; MOVE.B` that follows it ($20061A31); the
    /// second, a voice's step, from before the `BCS` ($6532) that follows its being tested in the routine
    /// for a tick.
    var volumeOffset: UInt16 = 0x32
    var stepOffset: UInt16
    /// How far into the module the player looks for its patterns (`ChangeLen`): to 250 bytes before the
    /// driver's table of periods, whose first word is $069F.
    var searchLength: Int

    /// The words of the module, read as the player reads them; a read past either end refuses it.
    struct Words {
        let data: [UInt8]

        func byte(_ at: Int) throws(TuneError) -> Int {
            guard at >= 0, at < data.count else {
                throw .malformed("Martin Walker's module is cut short, or its driver is not as his drivers are")
            }
            return Int(data[at])
        }

        func word(_ at: Int) throws(TuneError) -> Int { try byte(at) << 8 | byte(at + 1) }
        func signedWord(_ at: Int) throws(TuneError) -> Int { Int(Int16(truncatingIfNeeded: try word(at))) }
        func long(_ at: Int) throws(TuneError) -> UInt32 { UInt32(try word(at)) << 16 | UInt32(try word(at + 2)) }
    }

    /// The instruction a song's start begins with: `MOVEM.L D0-D5/A0-A6,-(A7)`.
    private static let saves: UInt32 = 0x48E7_FCFE

    // MARK: The check

    /// The player's check (`Check2`). Nil for a module that is not one; otherwise whether it is of the
    /// fifth kind. A module of the first kind begins with a song's start; of the second, with a `MOVE.L
    /// A0,-(A7); LEA (PC),A0` to the sound effects' variables, 28 bytes past which the song's start is (or
    /// has that 28 bytes in, as the Exotic Ripper saves it). Then the start is to have, 4 bytes in, an
    /// `ASL.W #4,D1; MOVEQ #0,D0` and a `LEA (PC),A0` of the table of songs, and 140, 156 or 160 bytes
    /// past that the routine for a tick, which saves the registers as it does; the first kind is not to
    /// have a `LEA (PC),A2` 220 bytes in, and the second is. A module of BRAs has eight or ten; the fourth
    /// goes to a song's start as the second kind's does, its fifth kind to the seventh, which is followed
    /// by a `LEA (PC),A1`. A third kind saved by the Exotic Ripper has the sound effects' routine a few
    /// bytes past 28 and the song's start within 76 words of the module's start.
    static func check(_ data: [UInt8]) -> Bool? {
        let m = Words(data: data)
        do {
            if try m.long(0) == saves {
                guard try m.word(220) != 0x45FA else { return nil }
                return try startLooksRight(m, at: 0) ? false : nil
            }
            if try m.long(0) == 0x2F08_41FA {
                return try secondKind(m, at: 4 + m.signedWord(4)) ? false : nil
            }
            if try m.long(28) == saves { return try secondKind(m, at: 0) ? false : nil }
            if try m.word(0) == 0x6000 {
                for at in stride(from: 4, through: 28, by: 4) where try m.word(at) != 0x6000 { return nil }
                if try m.word(32) == 0x6000, try m.word(36) != 0x6000 { return nil }
                let fourth = 14 + (try m.signedWord(14))
                if try m.long(fourth) == saves { return try laterKind(m, at: fourth) ? false : nil }
                var seventh = 26 + (try m.signedWord(26))
                guard try m.long(seventh) == saves else { return nil }
                seventh += 4
                return try m.word(seventh) == 0x43FA ? true : nil
            }
            var a0 = 0
            for _ in 0 ..< 5 {
                if try m.long(28 + a0) == 0x2F08_41FA {
                    for _ in 0 ..< 76 {
                        if try m.long(a0) == saves { return try laterKind(m, at: a0) ? false : nil }
                        a0 += 2
                    }
                    return nil
                }
                a0 += 2
            }
            return nil
        } catch {
            return nil
        }
    }

    /// `OK_3`: the song's start, 28 bytes on, with a `LEA (PC),A2` 220 bytes into it.
    private static func secondKind(_ m: Words, at: Int) throws(TuneError) -> Bool {
        let a0 = at + 28
        guard try m.word(a0 + 220) == 0x45FA else { return false }
        return try startLooksRight(m, at: a0)
    }

    /// `loop_2`: a later driver's song's start, with a `LEA (PC),A2` 268 bytes in or an `ASL.W #4,D2` 274.
    private static func laterKind(_ m: Words, at: Int) throws(TuneError) -> Bool {
        if try m.word(at + 268) != 0x45FA {
            guard try m.word(at + 274) == 0xE942 else { return false }
        }
        return try startLooksRight(m, at: at)
    }

    /// `loop_1`: `ASL.W #4,D1; MOVEQ #0,D0` 4 bytes into a song's start, and a `LEA (PC),A0`, 140, 156
    /// or 160 bytes past which a routine begins that saves the registers as it does.
    private static func startLooksRight(_ m: Words, at: Int) throws(TuneError) -> Bool {
        guard try m.long(at + 4) == 0xE941_7000 else { return false }
        let a0 = at + 8
        guard try m.word(a0) == 0x41FA else { return false }
        for offset in [140, 156, 160] where try m.long(a0 + offset) == saves { return true }
        return false
    }

    /// Whether the player calls the module's start as it loads it (`InitPlayer`): for a module of BRAs
    /// that has fewer than nine, and for one of the second kind.
    static func setsUp(_ data: [UInt8]) -> Bool {
        let m = Words(data: data)
        guard let first = try? m.word(0) else { return false }
        if first == 0x6000 { return (try? m.word(32)) != 0x6000 }
        return first == 0x2F08
    }

    /// A module of nothing, where there is none.
    static let none = MartinWalkerModule()

    private init() {
        fifth = false
        setsUp = false
        initAt = 0
        playAt = 0
        songTable = 0
        steps = 0
        songCount = 0
        stepOffset = 0
        searchLength = 0
    }

    // MARK: Finding the way in

    /// What the player's `InitPlayer` finds in a module that passed its check, once its start has been
    /// called if it is to be (`prepared` is the module as that left it). Throws for one it would not find
    /// its way about; its searches that have no end in the player end with the module.
    init(_ prepared: [UInt8], fifth: Bool) throws(TuneError) {
        let m = Words(data: prepared)
        self.fifth = fifth
        setsUp = Self.setsUp(prepared)
        initAt = 0
        playAt = 0
        songTable = 0
        steps = 0
        songCount = 0
        stepOffset = 0
        searchLength = 0

        // Where the song's start is: of a module of BRAs, the fourth's (or, of the fifth kind, the
        // sixth's, and its routine for a tick the seventh's); past the sound effects' variables of the
        // second kind; or the module's start.
        var a2 = 0
        var a3 = 0
        var found = false
        if try m.word(0) == 0x6000 {
            a3 = 14
            a2 = 14 + (try m.signedWord(14))
            if try m.word(32) == 0x6000 {
                if fifth {
                    // (The table of songs is looked for from the routine for a tick, which starts the song.)
                    playAt = 26 + (try m.signedWord(26))
                    a2 = 22 + (try m.signedWord(22))
                    a3 = playAt
                    found = true
                }
            } else {
                try findVolume(m, from: a2 + 1000)
            }
        } else if try m.word(0) == 0x2F08 {
            a2 = 4 + (try m.signedWord(4)) + 28
        }
        // `CheckInit`: the song's start is a MOVEM; or it is 28 bytes on; or it is the first MOVEM within
        // 128 words, past which the patterns' volume is looked for.
        var tries = 0
        while !found {
            tries += 1
            guard tries < 0x10000 else { throw .malformed("Martin Walker's driver is not as his drivers are") }
            if try m.word(a2) == 0x48E7 {
                a3 = a2
                found = true
            } else if try m.long(a2 + 28) == Self.saves {
                a2 += 28
            } else {
                var at: Int?
                for i in 0 ..< 128 where try m.word(a2 + 2 * i) == 0x48E7 {
                    at = a2 + 2 * i
                    break
                }
                guard let at else { throw .malformed("Martin Walker's driver has no routine to start a song") }
                a2 = at
                try findVolume(m, from: a2 + 1000)
            }
        }
        initAt = a2

        // The table of songs, from the LEA after the start's `ASL.W #4,D1`.
        while try m.word(a3) != 0xE941 { a3 += 2 }
        a3 += 6
        songTable = a3 + (try m.signedWord(a3))
        // The voices' lists, from the LEA in the first routine the start calls (`StepsPtr`): the songs
        // are as many as there is room for before them.
        a2 = try after(0x6100, m, from: a2)
        let call = a2
        a2 += try m.signedWord(a2)
        a2 = try after(0x49FA, m, from: a2)
        steps = a2 + (try m.signedWord(a2))
        guard steps > songTable, (steps - songTable) >> 4 <= 255 else {
            throw .malformed("Martin Walker's driver has a table of songs that is not as his are")
        }
        songCount = (steps - songTable) >> 4
        guard songCount > 0 else { throw .malformed("Martin Walker's module has no songs") }
        // The routine for a tick: after the start's first RTS from that call; of the fifth kind, 120
        // bytes into it is where the step is looked for.
        var a6: Int
        if fifth {
            // (Of a module of the fifth kind that has not its ten BRAs, the player has found no routine for
            // a tick, and would call what it last had.)
            guard playAt > 0 else { throw .malformed("Martin Walker's driver has no routine to play a tick") }
            a6 = playAt + 120
        } else {
            a6 = try after(0x4E75, m, from: call)
            playAt = a6
        }
        var bcs: Int?
        for i in 0 ..< 128 where try m.word(a6 + 2 * i) == 0x6532 {
            bcs = a6 + 2 * i
            break
        }
        guard let bcs else { throw .malformed("Martin Walker's driver does not step its voices as his drivers do") }
        stepOffset = UInt16(try m.word(bcs - 2))
        // (The player then finds the samples, from a `MOVE.L 0(A2,D5.W),D5` after that, and refuses a
        // module in which it finds none before a long of nought.)
        var a = bcs - 2
        while try m.long(a) != 0x2A32_5000 {
            guard try m.long(a) != 0 else { throw .malformed("Martin Walker's driver has no samples") }
            a += 2
        }
        // The table of periods, the end of the stretch the patterns are looked for in.
        var periods = 0
        while try m.word(periods) != 0x069F { periods += 2 }
        searchLength = periods - 250
    }

    /// The offset past the next `op` that is followed by more than a long of nought (as the player looks
    /// for a BSR, a LEA and an RTS, and gives up at a long of nought).
    private func after(_ op: Int, _ m: Words, from: Int) throws(TuneError) -> Int {
        var at = from
        while true {
            let word = try m.word(at)
            at += 2
            if word == op { return at }
            guard try m.long(at) != 0 else { throw .malformed("Martin Walker's driver is not as his drivers are") }
        }
    }

    /// `Loop`: the `MOVE.L D6,D5; MOVE.B` ($20061A31) from 1000 bytes into the driver, the offset of whose
    /// variable 9 bytes on is that of the voice's volume in the pattern the player looks for.
    private mutating func findVolume(_ m: Words, from: Int) throws(TuneError) {
        var a6 = from
        while try m.long(a6) != 0x2006_1A31 { a6 += 2 }
        volumeOffset = UInt16(try m.byte(a6 + 9))
    }

    // MARK: The player's changes

    /// The module as the player changes it before it is run (`InitPlayer`, `EP_ModuleChange`): its waits
    /// for the DMA, by the processor's time, made the two the player knows (`MOVEQ #$20,D0` and
    /// `MOVE.L #$FF,D0` before a `DBF D0,*`), from the start to its table of periods; and then each of
    /// `patterns` found, a word at a time, from its start for `searchLength` bytes, as UADE's host finds
    /// them (`epg_modulechange`), and made a JSR to the routine for it (at `routines[i]`), followed by NOPs.
    func patched(_ prepared: [UInt8], routines: [UInt32], patterns: [[UInt16]]) -> [UInt8] {
        var bytes = prepared
        func word(_ at: Int) -> UInt16? {
            at >= 0 && at + 1 < bytes.count ? UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) : nil
        }
        func put(_ at: Int, _ value: UInt16) {
            bytes[at] = UInt8(value >> 8)
            bytes[at + 1] = UInt8(value & 0xFF)
        }
        var a0 = 0
        while let op = word(a0), op != 0x069F {
            if a0 >= 2, op == 0x51C8, word(a0 + 2) == 0xFFFE {
                if bytes[a0 - 2] == 0x70 { bytes[a0 - 1] = 0x20 } else { put(a0 - 2, 0x00FF) }
            }
            a0 += 2
        }
        for (pattern, address) in zip(patterns, routines) {
            var at = 0
            var left = searchLength
            while left > 0 {
                if pattern.indices.allSatisfy({ word(at + 2 * $0) == pattern[$0] }) {
                    let jsr: [UInt16] = [0x4EB9, UInt16(address >> 16), UInt16(address & 0xFFFF)]
                    for i in pattern.indices { put(at + 2 * i, i < 3 ? jsr[i] : 0x4E71) }
                    at += (pattern.count - 1) * 2
                    left -= (pattern.count - 1) * 2
                }
                at += 2
                left -= 2
            }
        }
        return bytes
    }
}
