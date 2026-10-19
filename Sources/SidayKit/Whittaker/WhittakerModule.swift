// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for David Whittaker's modules ("David Whittaker player module
// V1.0 (11 Nov 2000)", carried by UADE as players/DavidWhittaker), of which there is no source: the
// addresses given are of its code hunk, as a disassembly of it has them.

/// What Wanted Team's player finds in one of David Whittaker's modules, which is his own 68000 driver
/// with its music after it: where to start a song and where to play a tick, where the samples and the
/// table of songs are, how many songs there are, and what it changes in the module before it is run.
///
/// A module is one of two kinds, as the player's check (`DTP_Check2`, $3A4) finds them. Most begin with
/// a table of little routines, each saving the registers, calling a routine of the driver's and coming
/// back: the first starts a song (with its number in D0), the second plays a tick, and the others stop
/// the music, start it again, fade it or play a sound effect. The rest, the earliest, begin with the
/// driver's own code. The player finds its way into the driver by the instructions it begins with, as
/// Whittaker wrote them in each version of it: a `LEA (PC),A3` that gives the base its variables are
/// kept from, a call to the routine that readies the samples, and in that a `MOVE.L (A0)+,D2` over a
/// count of them, a `MULU #n,D0` by the size of a song's entry in the table of songs, and the table.
struct WhittakerModule {
    /// The module's kind, as the player's flag ($236) has it: 0 for one that begins with its table of
    /// routines; $FF for one that does not; 1 for either whose driver moves from voice to voice by
    /// `ADDA.W #$30,A1`, which the player looks for ($806) in those it finds no play routine for in the
    /// table. It decides which of the player's patches are made (`patches`).
    var flag: UInt8
    /// Offsets into the module: the routine that starts a song, the one that plays a tick, and one
    /// called before the first, which some later modules have as the seventh of their table ($544).
    var initAt: Int
    var playAt: Int
    var setUpAt: Int?
    /// The base the driver's variables are kept from (its `LEA (PC),A3`, which may point before the
    /// module where its start was cut off), the samples' table and the first sample's header.
    var base: Int
    var samples: Int
    var sampleCount: Int
    var firstSampleHeader: Int?
    /// The table of songs, the size of an entry in it (two bytes, the second the song's speed, then a
    /// pointer to each voice's list of patterns, a word each or, in an entry of more than ten bytes, a
    /// long), and how many voices it gives a song.
    var songTable: Int
    var entrySize: Int
    var voices: Int
    var songCount: Int
    /// Where the module ends, by the player's measure: past its last sample and 64 bytes more.
    var calculatedSize: Int
    /// Bytes the player clears, flags of the driver's that say it has readied its samples, which a module
    /// saved after it had keeps set ($618); and a stretch it makes NOPs of, the choosing of a song at
    /// random that a game asked for by a number past its songs ($608).
    var cleared: [Int] = []
    var madeNOPs: Range<Int>?
    /// For a module of Rob Hubbard's that the player also plays: the routine its driver puts at the
    /// level 4 interrupt's vector, to be run by Paula's audio interrupts ($858).
    var audioInterrupt: Int?
    /// A module whose driver the player gives back its volume each tick ($96E).
    var restoresVolume: Bool { calculatedSize == 0x5C82 }

    /// The words of the module, read as the player reads them; a read past either end refuses it.
    private struct Words {
        let data: [UInt8]

        func byte(_ at: Int) throws(TuneError) -> Int {
            guard at >= 0, at < data.count else {
                throw .malformed("David Whittaker's module is cut short, or its driver is not as his drivers are")
            }
            return Int(data[at])
        }

        func word(_ at: Int) throws(TuneError) -> Int { try byte(at) << 8 | byte(at + 1) }
        func signedWord(_ at: Int) throws(TuneError) -> Int { Int(Int16(truncatingIfNeeded: try word(at))) }
        func long(_ at: Int) throws(TuneError) -> UInt32 { UInt32(try word(at)) << 16 | UInt32(try word(at + 2)) }
        func signedLong(_ at: Int) throws(TuneError) -> Int { Int(Int32(bitPattern: try long(at))) }
    }

    // MARK: The check

    /// The player's check ($3A4), which also says the module's kind: 0 for one that begins with its table
    /// of routines (a `MOVEM.L D0-D3/D7/A0-A6,-(A7)` and a BSR to the routine that starts a song, which
    /// has a `LEA (PC),A3` among its first ten words), $FF for one that begins with a `BSET #1,$BFE001`,
    /// with a `LEA (PC),A3`, or with one of those of the module's own start within its first five words.
    /// Either is then to call (by a BSR within 128 words) a routine that, before its first RTS, saves A3
    /// (`MOVE.L A3,-(A7)`) or writes to `$DFF0C8` ($424). Nil for a module that is not one.
    static func kind(of data: [UInt8]) -> UInt8? {
        let m = Words(data: data)
        do {
            if try m.long(0) == 0x48E7_F1FE {
                guard try m.word(4) == 0x6100 else { return nil }
                var a1 = 6 + (try m.signedWord(6))
                for _ in 0 ..< 10 {
                    let op = try m.word(a1)
                    a1 += 2
                    if op == 0x47FA { return try callsTheDriver(m, from: a1) ? 0 : nil }
                }
                return nil
            }
            if try m.long(0) == 0x08F9_0001 {
                guard try m.long(4) == 0x00BF_E001 else { return nil }
                return try callsTheDriver(m, from: 8) ? 0xFF : nil
            }
            if try m.long(0) == 0x4E71_4E71 { return nil }
            if try m.word(0) == 0x47FA { return try callsTheDriver(m, from: 2) ? 0xFF : nil }
            var a1 = 2
            for _ in 0 ..< 4 {
                let op = try m.word(a1)
                a1 += 2
                if op == 0x47FA {
                    a1 += try m.signedWord(a1)
                    guard a1 == 0 else { return nil }
                    return try callsTheDriver(m, from: a1) ? 0xFF : nil
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// $424: a BSR within 128 words of `from`; in what it calls (past one more BSR, for a module that
    /// begins with its table), a `MOVE.L A3,-(A7)` or `$DFF0C8` within 128 words and before any RTS.
    private static func callsTheDriver(_ m: Words, from: Int) throws(TuneError) -> Bool {
        var a1 = from
        var found = false
        for _ in 0 ..< 128 {
            let op = try m.word(a1)
            a1 += 2
            if op == 0x6100 {
                found = true
                break
            }
        }
        guard found else { return false }
        a1 += try m.signedWord(a1)
        if try m.long(0) == 0x48E7_F1FE {
            a1 += 4
            let op = try m.word(a1)
            a1 += 2
            guard op == 0x6100 else { return false }
            a1 += try m.signedWord(a1)
        }
        for _ in 0 ..< 128 {
            if try m.word(a1) == 0x4E75 { return false }
            if try m.word(a1) == 0x2F0B { return true }
            if try m.long(a1) == 0x00DF_F0C8 { return true }
            a1 += 2
        }
        return false
    }

    /// A module of nothing, where there is none.
    static let none = WhittakerModule()

    private init() {
        flag = 0
        initAt = 0
        playAt = 0
        base = 0
        samples = 0
        sampleCount = 0
        songTable = 0
        entrySize = 10
        voices = 4
        songCount = 1
        calculatedSize = 0
    }

    // MARK: Finding the way in

    /// What the player's `DTP_InitPlayer` ($4C4) finds in a module that passed its check. Throws for
    /// one it would not find its way about. (It also refuses a module shorter than its samples and 64 bytes
    /// more, $5AA, which UADE then plays all the same, but without the changes the player makes after
    /// that; here it is played with them, its songs ending as the player has them end. Dan Dare III's has
    /// its last sample whole, and not the 64 bytes.)
    init(_ data: [UInt8]) throws(TuneError) {
        guard let kind = Self.kind(of: data) else { throw .malformed("not a module of David Whittaker's") }
        let m = Words(data: data)
        flag = kind
        initAt = 0
        playAt = 0
        base = 0
        samples = 0
        sampleCount = 0
        songTable = 0
        entrySize = 10
        voices = 4
        songCount = 1
        calculatedSize = 0

        var a2: Int
        if kind == 0 {
            // The table: the song is started at its first routine, and what it calls readies the samples
            // by the second call it makes.
            a2 = 6 + (try m.signedWord(6))
            a2 = try findBase(m, from: a2)
            a2 = try after(0x6100, m, from: a2)
            guard try m.word(a2 + 2) == 0x6100 else {
                throw .malformed("David Whittaker's driver does not ready its samples as his drivers do")
            }
            a2 += 4
            let call = a2
            a2 += try m.signedWord(a2)
            let end = try findSamples(m, from: a2).end
            a2 = try findSongs(m, from: call, samplesEnd: end)
            if try m.long(14) == 0x48E7_F1FE {
                // The second routine plays a tick; and a seventh, after the sixth RTS among the first
                // fifty words, is called before a song is started ($544).
                playAt = 14
                var count = 6
                var seventh: Int?
                for i in 0 ..< 50 {
                    guard try m.word(i * 2) == 0x4E75 else { continue }
                    count -= 1
                    if count == 0 { seventh = i * 2 + 2 }
                }
                setUpAt = count < 0 ? seventh : nil
            } else {
                try findPlay(m, from: a2)
            }
        } else {
            // No table: the song is started at the first MOVEM or LEA, and played where the driver's
            // second part begins ($568).
            a2 = 0
            while try m.word(a2) != 0x48E7, try m.word(a2) != 0x47FA { a2 += 2 }
            initAt = a2
            a2 = try findBase(m, from: a2)
            a2 = try after(0x6100, m, from: a2)
            if try m.word(a2 + 2) == 0x6100 {
                a2 += 4
                let call = a2
                a2 += try m.signedWord(a2)
                let end = try findSamples(m, from: a2).end
                a2 = try findSongs(m, from: call, samplesEnd: end)
            } else {
                let found = try findSamples(m, from: a2)
                a2 = try findSongs(m, from: found.after, samplesEnd: found.end)
            }
            try findPlay(m, from: a2)
        }
    }

    /// The offset just after the next instruction word `op`.
    private func after(_ op: Int, _ m: Words, from: Int) throws(TuneError) -> Int {
        var a2 = from
        while true {
            let word = try m.word(a2)
            a2 += 2
            if word == op { return a2 }
        }
    }

    /// $5E0: the `LEA (PC),A3` that gives the base; and up to the next BSR, a `CMP.B #n,D0` that begins
    /// the choosing of a song at random, made NOPs of. Leaves the offset at that BSR.
    private mutating func findBase(_ m: Words, from: Int) throws(TuneError) -> Int {
        var a2 = try after(0x47FA, m, from: from)
        base = a2 + (try m.signedWord(a2))
        while true {
            if try m.word(a2) == 0xB03C {
                let start = a2
                while try m.word(a2) != 0x6100 { a2 += 2 }
                madeNOPs = start ..< a2
                return a2
            }
            let op = try m.word(a2)
            a2 += 2
            if op == 0x6100 { return a2 - 2 }
        }
    }

    /// $614: the samples. On the way to the LEA of their table, each `TST.B (A3)` names a flag of the
    /// driver's, cleared if it is set; past it, a `MOVE.L (A0)+,D2` follows a MOVEQ of their count less
    /// one, and may follow a `LEA (PC),A5` of the first one's header. Each sample is a long of its length,
    /// a word, and its bytes. Gives where they end, by the player's measure (64 bytes past the last), and
    /// the offset past the MOVE.
    private mutating func findSamples(_ m: Words, from: Int) throws(TuneError) -> (end: Int, after: Int) {
        var a2 = from
        var a1 = base
        while true {
            if try m.word(a2) == 0x4A2B {
                a2 += 2
                a1 += try m.signedWord(a2)
                a2 += 2
                if try m.byte(a1) != 0 { cleared.append(a1) }
            }
            if try m.word(a2) == 0x41FA {
                a2 += 2
                a1 = a2
                break
            }
            let op = try m.word(a2)
            a2 += 2
            if op == 0x41EB {
                a1 = base
                break
            }
        }
        a1 += try m.signedWord(a2)
        // (One module, whose table the LEA does not give.)
        if try m.long(a2) == 0x3E8A_2748 { a1 = 0x66EC }
        samples = a1
        a2 = try after(0x2418, m, from: a2)
        let count = try m.byte(a2 - 3)
        sampleCount = count + 1
        if try m.word(a2 - 8) == 0x4BFA { firstSampleHeader = a2 - 6 + (try m.signedWord(a2 - 6)) }
        for _ in 0 ... count {
            let length = try m.long(a1)
            guard length != 0, length <= 0x10000 else {
                throw .malformed("David Whittaker's samples are not as his drivers keep them")
            }
            a1 += Int(length) + 6
        }
        return (a1 + 64, a2)
    }

    /// $6B0: the size of the module, the size of an entry in the table of songs (the `MULU #n,D0` after
    /// `from`, or ten for a driver that has none), the table (the LEA after that), and from it the count
    /// of songs: the table runs up to the first of the voices' lists of patterns its entries point to.
    /// Gives the offset at the table's LEA.
    private mutating func findSongs(_ m: Words, from: Int, samplesEnd: Int) throws(TuneError) -> Int {
        var a1 = samplesEnd
        var d1 = 64
        calculatedSize = a1
        if a1 == 0x69BA {
            // (One module, which is longer than its samples say.)
            d1 = 0x92F2
            guard m.data.count >= d1, try m.long(0x69BE) == 0x2930_22C4 else {
                throw .malformed("David Whittaker's driver is not as his drivers are")
            }
            a1 = d1
            calculatedSize = a1
        }
        if samples == 0x66EC { calculatedSize = a1 - d1 }
        var a2 = from
        while true {
            if try m.word(a2) == 0xC0FC {
                entrySize = try m.word(a2 + 2)
                a2 += 4
                break
            }
            if try m.word(a2) == 0x41FA {
                entrySize = 10
                break
            }
            a2 += 2
        }
        if try m.word(a2) == 0x41FA {
            a2 += 2
            a1 = a2
        } else {
            let op = try m.word(a2)
            a2 += 2
            guard op == 0x41EB else {
                throw .malformed("David Whittaker's driver has no table of songs where his drivers have it")
            }
            a1 = base
        }
        a1 += try m.signedWord(a2)
        songTable = a1
        let start = a1
        let size = Int(Int16(truncatingIfNeeded: entrySize))
        guard size > 2 else { throw .malformed("David Whittaker's table of songs is not as his drivers keep it") }
        var lowest: Int
        var counted: Int?
        if size > 10 {
            // Longs ($752).
            let end = a1 + size
            a1 += 2
            lowest = try m.signedLong(a1)
            a1 += 4
            while a1 < end {
                lowest = min(lowest, try m.signedLong(a1))
                a1 += 4
            }
            voices = (size - 2) >> 2
            while true {
                let first = base &+ lowest
                if a1 == first { break }
                a1 += 2
                for _ in 0 ..< voices {
                    lowest = min(lowest, try m.signedLong(a1))
                    a1 += 4
                }
                if a1 == first { break }
            }
        } else {
            // Words ($79C).
            let end = a1 + size
            a1 += 2
            lowest = try m.signedWord(a1)
            a1 += 2
            while a1 < end {
                lowest = min(lowest, try m.signedWord(a1))
                a1 += 2
            }
            voices = (size >> 1) - 1
            while true {
                let first = base + Int(Int16(truncatingIfNeeded: lowest))
                if a1 == first { break }
                a1 += 2
                if a1 > first {
                    counted = a1 - start - 2 - size
                    break
                }
                for _ in 0 ..< voices {
                    lowest = min(lowest, try m.signedWord(a1))
                    a1 += 2
                }
                if a1 == first { break }
            }
        }
        // ($7E0: the lowest pointer is taken as a word.) The count is a DIVU's: the quotient in the
        // lower word and what is left over in the upper, and the player's last song is one less.
        let span = UInt32(truncatingIfNeeded: counted ?? base + Int(Int16(truncatingIfNeeded: lowest)) - start)
        let divisor = UInt32(UInt16(truncatingIfNeeded: entrySize))
        let quotient = span / divisor
        let divided = quotient > 0xFFFF ? span : (span % divisor) << 16 | quotient
        songCount = max(1, Int(Int16(truncatingIfNeeded: divided &- 1)) + 1)
        // (No module has more than 21; one that says it has thousands is broken.)
        guard songCount <= 255 else { throw .malformed("David Whittaker's table of songs is not as his drivers keep it") }
        return a2
    }

    /// $806: for a module whose play routine is not the second of its table: after an RTS, an
    /// `ADDA.W #$30,A1` (which makes the module of kind 1) or a `MOVE.L A0,$70`, the second LEA (PC),A3
    /// (the third, past a BRA, for a module that begins as one with a table does), or the MOVEM before it.
    private mutating func findPlay(_ m: Words, from: Int) throws(TuneError) {
        var a2 = from
        while true {
            if try m.word(a2) == 0x4E75 { break }
            if try m.long(a2) == 0xD2FC_0030 {
                flag = 1
                break
            }
            let op = try m.word(a2)
            a2 += 2
            if op == 0x0070 {
                a2 -= 6
                if try m.word(a2) == 0x23C8 {
                    // A Rob Hubbard module's driver, which runs from Paula's interrupts ($858).
                    audioInterrupt = a2 - 2 + (try m.signedWord(a2 - 2))
                    a2 += 6
                    calculatedSize -= 64
                }
                break
            }
        }
        a2 = try after(0x47FA, m, from: a2)
        let start = try m.long(0)
        if start == 0x48E7_F1FE || start == 0x08F9_0001 { a2 = try after(0x6000, m, from: a2) }
        a2 = try after(0x47FA, m, from: a2)
        if try m.word(a2 - 6) == 0x48E7 { a2 -= 4 }
        playAt = a2 - 2
    }
}
