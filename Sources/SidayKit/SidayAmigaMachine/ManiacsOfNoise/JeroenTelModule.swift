// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Jeroen Tel's modules ("Jeroen Tel player module V1.0 (27 Oct
// 2004)", carried by UADE as players/JeroenTel, whose source UADE carries as amigasrc/players/wanted_team/
// JeroenTel/Jeroen Tel_v1.asm: its routines and labels are named here as it names them). The addresses
// given in a module are those of the driver of Charles Deenen's "Unreal" (its title, as it was ripped
// with its two jumps, title_and_game_end.jt), as a disassembly of it has them: the driver is at $8 in it.

/// What Wanted Team's player finds in one of Jeroen Tel's modules, which is the driver the Maniacs of
/// Noise wrote for their music of 1989 and 1990 with the music and samples after it, as it was taken
/// out of a game's memory: its code and its tables hold their addresses where the game had them, from
/// the address its first byte was at (`origin`), which the player works out from the table of periods.
///
/// The player's check (`DTP_Check2`) finds the driver's routine for the first half of a tick within the
/// file's first forty bytes, and its `DTP_InitPlayer` finds the rest by the instructions the driver is
/// made of. The driver is the same in every file, but for the addresses it is at and a few instructions
/// written another way (`MOVE.B #0` for `CLR.B`, an index register taken as a long for a word), and in
/// some files a routine before it that sets the filter off (which the player does not call), or a
/// line of text after its first RTS; and in "Onslaught" its voices turned off, and left out of its
/// second half, by four flags of the game's (which are clear), and its stop only turning off the DMA.
struct JeroenTelModule {
    /// The address the file's first byte was at.
    var origin: UInt32 = 0
    /// Offsets into the file of the driver's routines for the two halves of a tick: the first works out
    /// the voices' notes and gives Paula their samples, the second their periods and volumes, and turns
    /// on the DMA of those started in the first.
    var playAt = 0
    var secondAt = 0
    /// The addresses of the driver's variables: the byte that says it plays, and the table of where
    /// each voice's are. Before the byte are four more: a flag of the note being read, how many ticks are
    /// left of the current step, how many a step has, and the voices (four times one fewer: 12 for four).
    var playing: UInt32 = 0
    var voiceTable: UInt32 = 0
    var voices: [UInt32] = []
    /// The table of songs (an offset into the file), each 18 bytes: the address of each voice's list of
    /// patterns, the voices (as above) and the ticks of a step; and how many there are.
    var songTable = 0
    var songCount = 0
    /// The table of periods (an address).
    var periods: UInt32 = 0
    /// Offsets of instructions the player has otherwise, or changes: the first of what is done as a
    /// song comes to the end of a voice's list of patterns and starts again (`RepeatVal1`), and how long
    /// it is; the first of where the driver goes when a voice's list says to stop, and how long it is;
    /// the two readings of the table of periods; the writing of a voice's volume; and of the sample it
    /// goes on to, after its first.
    var wrapAt = 0
    var wrapLength = 0
    var stopAt = 0
    var stopLength = 0
    var periodReads: [Int] = []
    var volumeAt = 0
    var loopAt = 0
    /// What the file says of itself, between the driver's first RTS and where it goes on.
    var text = ""

    static let none = JeroenTelModule()

    private init() {}

    /// The file's words, read as the player reads them; a read past either end refuses it.
    private struct Words {
        let data: [UInt8]

        func byte(_ at: Int) throws(TuneError) -> Int {
            guard at >= 0, at < data.count else {
                throw .malformed("Jeroen Tel's module is cut short, or its driver is not as his drivers are")
            }
            return Int(data[at])
        }

        func word(_ at: Int) throws(TuneError) -> Int { try byte(at) << 8 | byte(at + 1) }
        func long(_ at: Int) throws(TuneError) -> UInt32 { UInt32(try word(at)) << 16 | UInt32(try word(at + 2)) }

        /// The first even offset from `at` at which the words are these (`nil` for one that may be
        /// any), as the player looks for them, a word at a time.
        func find(_ words: [Int?], from at: Int) throws(TuneError) -> Int {
            var at = at
            while at + 2 * words.count <= data.count {
                var all = true
                for (i, word) in words.enumerated() {
                    if let word, try self.word(at + 2 * i) != word {
                        all = false
                        break
                    }
                }
                if all { return at }
                at += 2
            }
            throw .malformed("Jeroen Tel's module is cut short, or its driver is not as his drivers are")
        }
    }

    // MARK: The check

    /// The player's check (`DTP_Check2`): a file of more than 1,700 bytes with, at an even offset in its
    /// first forty, an `ANDI.B #1,abs.L` and a BNE.S over an RTS (its first half of a tick, which goes on
    /// only while the driver plays); and where the BNE.S goes, a `MOVEQ #0,D4` and a `MOVE.B abs.L,D4`,
    /// or four `TST.B abs.L`s 18 bytes apart before them.
    static func driver(in data: [UInt8]) -> Int? {
        guard data.count > 1700 else { return nil }
        let w = Words(data: data)
        func word(_ at: Int) -> Int { (try? w.word(at)) ?? -1 }
        for at in stride(from: 0, to: 40, by: 2) where word(at) == 0x0239 && word(at + 2) == 0x0001 {
            let skip = Int(data[at + 9])
            guard data[at + 8] == 0x66, skip > 0, skip < 0x80, word(at + 10) == 0x4E75 else { return nil }
            var on = at + 10 + skip
            if word(on) == 0x4A39 {
                for _ in 0 ..< 4 {
                    guard word(on) == 0x4A39 else { return nil }
                    on += 18
                }
            }
            guard word(on) == 0x7800, word(on + 2) == 0x1839 else { return nil }
            return at
        }
        return nil
    }

    // MARK: Finding the way about

    /// What the player's `DTP_InitPlayer` finds, as it finds it, and what more is needed to run the
    /// driver's own code as the player runs its copy of it.
    init(_ data: [UInt8]) throws(TuneError) {
        guard let playAt = Self.driver(in: data) else {
            throw .malformed("not a module of Jeroen Tel's, or one cut short")
        }
        let w = Words(data: data)
        let bad = TuneError.malformed("Jeroen Tel's driver is not laid out as the player has it")
        self.playAt = playAt
        // The origin: the table of periods (856, 808, ...) is where a `MOVE.B D0,D2; ASL.B #1,D2` is
        // followed by a `MOVEA.L #abs,A3` of it (`Find1`, `Find2`).
        let periodRead = try w.find([0x1400, 0xE302], from: 0)
        periods = try w.long(periodRead + 6)
        let table = try w.find([0x0358, 0x0328], from: periodRead)
        let origin = periods &- UInt32(table)
        self.origin = origin
        guard origin & 1 == 0, origin >= 0x40, Int(origin) + data.count <= 0x1C_0000 else {
            throw .unsupported("a module of Jeroen Tel's whose addresses are not where an Amiga's chip RAM is")
        }
        func offset(_ address: UInt32) throws(TuneError) -> Int {
            let at = Int(address &- origin)
            guard address >= origin, at < data.count else { throw bad }
            return at
        }
        // The end of a voice's list of patterns: a `CMP.B #$FF,D1` (`FindR`), a BNE.S, and then the
        // positions set back, by a `MOVE.B #n,abs.L` or a `CLR.B abs.L` each.
        let wrapCompare = min((try? w.find([0xB23C, 0x00FF], from: 0)) ?? data.count,
                              (try? w.find([0x0C01, 0x00FF], from: 0)) ?? data.count)
        wrapAt = wrapCompare + 6
        switch try w.word(wrapAt) {
        case 0x13FC: wrapLength = 8
        case 0x4239: wrapLength = 6
        default: throw bad
        }
        // The table of songs: the `LEA abs.L,A4` before the first `MOVE.L 0(A4,D0.W),abs.L` (`Find6`).
        let songsRead = try w.find([0x23F4], from: wrapCompare)
        guard try w.word(songsRead - 6) == 0x49F9 else { throw bad }
        songTable = try offset(w.long(songsRead - 4))
        // Songs are counted as the player counts them: while an entry has four voices, and its lists are
        // not all the same.
        var count = 0
        var entry = songTable
        while try w.byte(entry + 16) == 12 {
            let first = try w.long(entry)
            if try first == w.long(entry + 4), try first == w.long(entry + 8), try first == w.long(entry + 12) { break }
            count += 1
            entry += 18
        }
        guard count > 0 else { throw .malformed("a module of Jeroen Tel's with no songs") }
        songCount = count
        // The driver's variables, from the first half of a tick: where its BNE.S goes (past the flags
        // of "Onslaught"), `MOVEQ #0,D4; MOVE.B voices,D4; SUBQ.B #1,left; CMPI.B #$FE,left; BNE.S;
        // MOVE.B step,left; MOVEA.L #table,A5`.
        playing = try w.long(playAt + 4)
        var on = try playAt + 10 + w.byte(playAt + 9)
        if try w.word(on) == 0x4A39 { on += 72 }
        guard try w.word(on + 8) == 0x5339, try w.word(on + 14) == 0x0C39, try w.word(on + 22) == 0x660A,
              try w.word(on + 24) == 0x13F9, try w.word(on + 34) == 0x2A7C
        else { throw bad }
        let voicesByte = try w.long(on + 4), left = try w.long(on + 10), step = try w.long(on + 26)
        voiceTable = try w.long(on + 36)
        let tableAt = try offset(voiceTable)
        var voices: [UInt32] = []
        for v in 0 ..< 4 { voices.append(try w.long(tableAt + 4 * v)) }
        self.voices = voices
        // (As the player has them, which it clears from the first of the four to the table.)
        guard voicesByte == playing &- 1, step == playing &- 2, left == playing &- 3,
              voices[0] == playing &+ 2, voices[1] == voices[0] &+ 40, voices[2] == voices[1] &+ 40,
              voices[3] == voices[2] &+ 40, voiceTable == voices[3] &+ 40
        else { throw bad }
        // Its second half: the same test of whether it plays, and the voices' periods and volumes given
        // from `LEA $DFF0A6,A4`.
        // (In "Onslaught", each voice's after a test of the game's flag of it, which is clear.)
        secondAt = try w.find([0x0239, 0x0001, Int(playing >> 16), Int(playing & 0xFFFF)], from: playAt + 8)
        guard try (secondAt + 10 ... secondAt + 20).contains(w.find([0x49F9, 0x00DF, 0xF0A6], from: secondAt)) else {
            throw bad
        }
        // Where a voice's list says to stop (`lbC0000B4`): after a `CMP.B #$FE,D1`, by a JMP or a BRA
        // past a BNE.S, or by a BEQ. It is to `CLR.B playing; MOVE.W #$F,$DFF096; RTS`, the routine that
        // stops the music, or in "Onslaught" to the last two of those only, which leave the driver
        // playing: the player's stops it.
        let stopCompare = min((try? w.find([0xB23C, 0x00FE], from: wrapCompare)) ?? data.count,
                              (try? w.find([0x0C01, 0x00FE], from: wrapCompare)) ?? data.count)
        switch try w.word(stopCompare + 4) {
        case 0x6606 where try w.word(stopCompare + 6) == 0x4EF9: stopAt = try offset(w.long(stopCompare + 8))
        case 0x6604 where try w.word(stopCompare + 6) == 0x6000:
            stopAt = try stopCompare + 8 + Int(Int16(truncatingIfNeeded: w.word(stopCompare + 8)))
        case 0x6700: stopAt = try stopCompare + 6 + Int(Int16(truncatingIfNeeded: w.word(stopCompare + 6)))
        default: throw bad
        }
        if try w.word(stopAt) == 0x4239, try w.long(stopAt + 2) == playing, try w.word(stopAt + 6) == 0x33FC {
            stopLength = 6
        } else if try w.word(stopAt) == 0x33FC, try w.long(stopAt + 2) == 0x000F_00DF, try w.word(stopAt + 6) == 0xF096 {
            stopLength = 8
        } else {
            throw bad
        }
        // The table of periods read with an index the player keeps within it: `ASL.B #1,D2; MOVEA.L
        // #periods,A3; MOVE.W 0(A3,D2),D2`, and `MOVEA.L #periods,A3; ASL.B #1,D1; MOVE.W 0(A3,D1),14(A5)`.
        let high = Int(periods >> 16), low = Int(periods & 0xFFFF)
        let first = periodRead + 2
        guard try w.word(first + 2) == 0x267C, try w.long(first + 4) == periods, try w.word(first + 8) == 0x3433,
              try w.word(first + 10) & 0xF7FF == 0x2000
        else { throw bad }
        let second = try w.find([0x267C, high, low, 0xE301, 0x3B73, nil, 0x000E], from: first + 10)
        guard try w.word(second + 10) & 0xF7FF == 0x1000 else { throw bad }
        periodReads = [first, second]
        // A voice's volume, `MOVE.W 18(A5),2(A4,D3)`, and the sample it goes on to, `MOVE.L 8(A3),0(A4,D3)`.
        volumeAt = try w.find([0x39AD, 0x0012, nil], from: secondAt)
        guard try w.word(volumeAt + 4) & 0xF7FF == 0x3002 else { throw bad }
        loopAt = try w.find([0x29AB, 0x0008, nil], from: playAt)
        guard try w.word(loopAt + 4) & 0xF7FF == 0x3000 else { throw bad }
        // The text (`FindRTS`): after the first RTS, if the BNE.S before it goes further than over it.
        var text = ""
        if let rts = try? w.find([0x4E75], from: 0), let over = try? w.byte(rts - 1), over > 2, over < 0x80 {
            for at in rts + 2 ..< min(rts + over, data.count) {
                let byte = data[at]
                guard byte >= 0x20, byte < 0x7F else { break }
                text.append(Character(Unicode.Scalar(byte)))
            }
        }
        self.text = text
    }
}
