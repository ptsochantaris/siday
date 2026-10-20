// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Rob Hubbard's music on Steve Bak's replayer ("Rob Hubbard ST
// player module V1.1 (29 July 2001)", UADE's players/RobHubbard_ST, whose source is UADE's amigasrc/players/
// wanted_team/RobHubbard_ST/src/"Rob Hubbard ST_v2.asm"). The lines given are of that source.

/// Rob Hubbard's music of 1987 and 1988 on the replayer Steve Bak wrote for the Atari ST, in its Amiga
/// version (as the player's credit has it): each module is the 68000 code that plays it, with its
/// music, for three voices playing short waves of its own, as the game had it, with its variables in
/// 5,000 bytes the player gives it (A5). Its routines are found in it: the routine for a tick after the
/// first RTS from its 180th byte, the one that stops it after a word $DFFC, the one that starts a song
/// (with its number, from nought, in D0) after the RTS after that; and its songs, twelve bytes each,
/// after a MOVEQ #2,D7.
///
/// As the player plays it (fifty ticks a second): its changes to the processor's status (written for the
/// ST) taken out; two of its branches made to go back further; its volumes written through the player's
/// (for the balance, which is none); a fault of Jupiter Probe's samples mended; its voices' instruments
/// begun at the module's table of them; and the song's end said at its command $8E, or where the voice
/// whose list of patterns is the longest comes to that list's end (a long of nought).
typealias RobHubbardSTPlayer = WantedTeamPlayer<RobHubbardST>

struct RobHubbardST: WantedTeamRecipe {
    static let format = "Rob Hubbard ST"

    /// UADE puts the module past the player's two hunks (of 1,776 and 5,000 bytes, from $D008).
    static let moduleAt: UInt32 = 0x10000
    /// Where UADE has the player's 5,000 bytes for the module's variables (`Buffer`, line 677): its second
    /// hunk.
    static let buffer: UInt32 = 0xD700

    /// `Check2` (lines 228-240): its first two longs $00407F40 and $00C081C0, and a LEA -18(PC),A0 at its
    /// 56th byte.
    static func isOne(_ data: [UInt8]) -> Bool {
        func long(_ at: Int) -> UInt32 {
            UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        }
        guard data.count >= 60 else { return false }
        return long(0) == 0x0040_7F40 && long(4) == 0x00C0_81C0 && long(56) == 0x41FA_FFEE
    }

    let title = ""
    let author = ""

    private var modulePtr: UInt32 = 0, playPtr: UInt32 = 0, endPtr: UInt32 = 0, initPtr: UInt32 = 0, songPtr: UInt32 = 0
    private var tablePtr: UInt32 = 0, halfAt: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables (lines 47-80): the module and its routines and songs, the eagle's base, the
        // module's table of instruments; the place in the song and the longest voice's list
        // (`CurrentPos`, `LongAddress`, which InitSound reaches one from the other); the sides' volumes
        // and the voices' muting; the scopes.
        let module = a.variable(long: 0), play = a.variable(long: 0)
        let end = a.variable(long: 0)
        let initSong = a.variable(long: 0), songs = a.variable(long: 0)
        _ = a.variable(word: 0) // Change
        let eagleBase = a.eagleBase()
        let table = a.variable(long: 0)
        let currentPos = a.variable(long: 0), longAddress = a.variable(long: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // `InfoBuffer` (lines 257-268), of which InitSound writes the song's length.
        let info = a.placed()
        for _ in 0 ..< 19 { a.long(0) }
        // `SetVolume` (lines 121-135, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `Left1`, `Right1`, `Right2` (lines 136-149): the volume in D0 turned down by its side's balance,
        // and nought if its voice is muted.
        let ex = a.label()
        var sides: [Int] = []
        for (side, voice) in [(leftVolume, voices[0]), (rightVolume, voices[1]), (rightVolume, voices[2])] {
            sides.append(a.placed())
            a.w(0xC0FA)
            a.displacement(to: side) // MULU.W side(PC),D0
            a.w(0xC07A)
            a.displacement(to: voice) // AND.W Voice(PC),D0
            if voice != voices[2] { a.branch(0x6000, to: ex) } // BRA.S Ex
        }
        a.place(ex)
        a.w(0xEC48, 0x4E75) // LSR.W #6,D0; RTS
        // `Interrupt` (lines 274-292, DTP_Interrupt): the module's routine for a tick, with its variables at
        // A5 (and the scopes at A4, which the patches write).
        tick = a.here
        a.w(0x48E7, 0x7FFE, 0x49FA) // MOVEM.L D1-D7/A0-A6,-(SP); LEA StructAdr(PC),A4
        a.displacement(to: scopes[0])
        a.w(0x50EC, 0x004C, 0x426C, 0x0006, 0x426C, 0x0018, 0x426C, 0x002A) // ST UPS_Enabled(A4); CLR.W three periods
        a.w(0x397C, 0x000F, 0x004A, 0x4BF9, UInt16(Self.buffer >> 16), UInt16(Self.buffer & 0xFFFF)) // MOVE.W #$F,UPS_Flags(A4); LEA Buffer,A5
        a.w(0x207A)
        a.displacement(to: play) // MOVEA.L PlayPtr(PC),A0
        a.w(0x4E90, 0x426C, 0x004C, 0x4CDF, 0x7FFE, 0x7000, 0x4E75) // JSR (A0); CLR.W UPS_Enabled(A4); MOVEM.L (SP)+,...; MOVEQ #0,D0; RTS
        // `SongEnd` (lines 294-300).
        let songEnd = a.songEndRoutine(eagleBase: eagleBase)
        // `InitSound` (lines 460-503, DTP_InitSound): the voice whose list of the song is the longest noted,
        // and the song started with its number in D0; then a byte of the module's variables set, at the
        // displacement InitPlayer finds in the module (`Half`).
        initSoundAt = a.here
        a.clearScopes(scopes)
        a.w(0x41FA)
        a.displacement(to: currentPos) // LEA CurrentPos(PC),A0
        a.w(0x4298, 0x7000, 0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x3400, 0x267A) // CLR.L (A0)+; MOVEQ #0,D0; MOVE.W dtg_SndNum(A5),D0; MOVE.W D0,D2; MOVEA.L SongPtr(PC),A3
        a.displacement(to: songs)
        let findMaxLength = a.placed(), nextLength = a.label(), zero = a.label(), maxLength = a.label()
        a.w(0x7602, 0x7A00) // MOVEQ #2,D3; MOVEQ #0,D5
        a.place(nextLength)
        a.w(0x247A)
        a.displacement(to: songs) // MOVEA.L SongPtr(PC),A2
        a.w(0xD5DB, 0x280A, 0x72FF) // ADDA.L (A3)+,A2; MOVE.L A2,D4; MOVEQ #-1,D1
        a.place(zero)
        a.w(0x5281, 0x4A9A) // ADDQ.L #1,D1; TST.L (A2)+
        a.branch(0x6600, to: zero) // BNE.B Zero
        a.w(0xBA81) // CMP.L D1,D5
        a.branch(0x6E00, to: maxLength) // BGT.B MaxLength
        a.w(0x2A01, 0x2084) // MOVE.L D1,D5; MOVE.L D4,(A0)
        a.place(maxLength)
        a.w(0x51CB)
        a.displacement(to: nextLength) // DBF D3,NextLength
        a.w(0x51CA)
        a.displacement(to: findMaxLength) // DBF D2,FindMaxLength
        a.w(0x43FA)
        a.displacement(to: info) // LEA InfoBuffer(PC),A1
        a.w(0x2345, 0x001C, 0x4BF9, UInt16(Self.buffer >> 16), UInt16(Self.buffer & 0xFFFF)) // MOVE.L D5,Length(A1); LEA Buffer,A5
        a.w(0x207A)
        a.displacement(to: initSong) // MOVEA.L InitPtr(PC),A0
        a.w(0x4E90) // JSR (A0)
        halfAt = a.here + 2
        a.w(0x50ED, 0x5754, 0x4E75) // ST 'WT'(A5); RTS

        // The patches (`PatchTable`, lines 518-674), each with the module's code it is called in place of.
        // Code0, Patch0: a command of the music read, the song's end said at $8E.
        let patch0 = a.placed(), skip0 = a.label()
        a.w(0x0C00, 0x008E) // CMP.B #$8E,D0
        a.branch(0x6600, to: skip0) // BNE.B SkipEnd2
        a.w(0x6100)
        a.displacement(to: songEnd) // BSR.W SongEnd
        a.place(skip0)
        a.w(0x0280, 0x0000, 0x003F, 0x4E75) // ANDI.L #$3F,D0; RTS
        patches.add([0x0280, 0x0000, 0x003F], patch: patch0)
        // Code1, Patch1: a voice's next pattern taken from its list (A0), which at its end (a long of
        // nought) begins again (8(A1)): the song's end said if it is the longest voice's list, whose place
        // is kept.
        let patch1 = a.placed(), skipEnd = a.label(), skip1 = a.label(), skip2 = a.label()
        a.w(0x2F01, 0x223A) // MOVE.L D1,-(A7); MOVE.L LongAddress(PC),D1
        a.displacement(to: longAddress)
        a.w(0x2010) // MOVE.L (A0),D0
        a.branch(0x6600, to: skipEnd) // BNE.B SkipEnd
        a.w(0x2069, 0x0008, 0xB2A9, 0x0008) // MOVEA.L 8(A1),A0; CMP.L 8(A1),D1
        a.branch(0x6600, to: skip1) // BNE.B Skip1
        a.w(0x6100)
        a.displacement(to: songEnd) // BSR.W SongEnd
        a.place(skip1)
        a.w(0x237C, 0x0000, 0x0004, 0x000C, 0x2010) // MOVE.L #4,12(A1); MOVE.L (A0),D0
        a.place(skipEnd)
        a.w(0xB2A9, 0x0008) // CMP.L 8(A1),D1
        a.branch(0x6600, to: skip2) // BNE.B Skip2
        a.w(0x23E9, 0x000C)
        a.address(of: currentPos) // MOVE.L 12(A1),CurrentPos
        a.place(skip2)
        a.w(0x221F, 0x4E75) // MOVE.L (A7)+,D1; RTS
        patches.add([0x2010, 0x660E, 0x2069, 0x0008, 0x237C, 0x0000, 0x0004, 0x000C, 0x2010], patch: patch1)
        // Code2, Patch2: its change of the processor's status (MOVE.W SR,-(SP); MOVE.W #$2700,SR) left out.
        let patch2 = a.placed()
        a.w(0x4E75)
        patches.add([0x40E7, 0x46FC, 0x2700], patch: patch2)
        // Code3 to Code8, Patch3 to Patch8: each voice's volume through its side's balance, and its wave and
        // period (and the first voice's and the third's lengths, the scopes', four words), told the scopes.
        let patch3 = a.placed()
        a.w(0x6100)
        a.displacement(to: sides[1]) // BSR.W Right1
        a.w(0x33C0, 0x00DF, 0xF0B8, 0x3940, 0x001A, 0x4E75) // MOVE.W D0,$DFF0B8; MOVE.W D0,UPS_Voice2Vol(A4); RTS
        patches.add([0x33C0, 0x00DF, 0xF0B8], patch: patch3)
        let patch4 = a.placed()
        a.w(0x23C9, 0x00DF, 0xF0B0, 0x2949, 0x0012, 0xE548) // MOVE.L A1,$DFF0B0; MOVE.L A1,UPS_Voice2Adr(A4); LSL.W #2,D0
        a.w(0x33C0, 0x00DF, 0xF0B6, 0x3940, 0x0018) // MOVE.W D0,$DFF0B6; MOVE.W D0,UPS_Voice2Per(A4)
        a.w(0x33C1, 0x00DF, 0xF0B4, 0x3941, 0x0016, 0x4E75) // MOVE.W D1,$DFF0B4; MOVE.W D1,UPS_Voice2Len(A4); RTS
        patches.add([0x23C9, 0x00DF, 0xF0B0, 0xE548, 0x33C0, 0x00DF, 0xF0B6, 0x33C1, 0x00DF, 0xF0B4], patch: patch4)
        let patch5 = a.placed()
        a.w(0x6100)
        a.displacement(to: sides[2]) // BSR.W Right2
        a.w(0x33C0, 0x00DF, 0xF0C8, 0x3940, 0x002C, 0x4E75) // MOVE.W D0,$DFF0C8; MOVE.W D0,UPS_Voice3Vol(A4); RTS
        patches.add([0x33C0, 0x00DF, 0xF0C8], patch: patch5)
        let patch6 = a.placed()
        a.w(0x227A)
        a.displacement(to: module) // MOVEA.L ModulePtr(PC),A1
        a.w(0x43E9, 0x0028, 0x2949, 0x0024) // LEA $28(A1),A1; MOVE.L A1,UPS_Voice3Adr(A4)
        a.w(0x33C0, 0x00DF, 0xF0C6, 0x3940, 0x002A, 0x397C, 0x0004, 0x0028, 0x4E75) // MOVE.W D0,$DFF0C6; ...Per; MOVE.W #4,UPS_Voice3Len(A4); RTS
        patches.add([0x33C0, 0x00DF, 0xF0C6], patch: patch6)
        let patch7 = a.placed()
        a.w(0x6100)
        a.displacement(to: sides[0]) // BSR.W Left1
        a.w(0x33C0, 0x00DF, 0xF0A8, 0x3940, 0x0008, 0x4E75) // MOVE.W D0,$DFF0A8; MOVE.W D0,UPS_Voice1Vol(A4); RTS
        patches.add([0x33C0, 0x00DF, 0xF0A8], patch: patch7)
        let patch8 = a.placed()
        a.w(0x227A)
        a.displacement(to: module) // MOVEA.L ModulePtr(PC),A1
        a.w(0x5089, 0x2949, 0x0000) // ADDQ.L #8,A1; MOVE.L A1,UPS_Voice1Adr(A4)
        a.w(0x33C0, 0x00DF, 0xF0A6, 0x3940, 0x0006, 0x397C, 0x0004, 0x0004, 0x4E75) // MOVE.W D0,$DFF0A6; ...Per; MOVE.W #4,UPS_Voice1Len(A4); RTS
        patches.add([0x33C0, 0x00DF, 0xF0A6], patch: patch8)
        // Code9, Patch9: a voice set going, its instruments' pointers (24(A1), 20(A1)) the module's table.
        let patch9 = a.placed()
        a.w(0x234A, 0x0008, 0x337C, 0x0001, 0x0028, 0x237A) // MOVE.L A2,8(A1); MOVE.W #1,$28(A1); MOVE.L TablePtr(PC),$18(A1)
        a.displacement(to: table)
        a.w(0x0018, 0x237A)
        a.displacement(to: table) // MOVE.L TablePtr(PC),$14(A1)
        a.w(0x0014, 0x4E75)
        patches.add([0x234A, 0x0008, 0x337C, 0x0001, 0x0028], patch: patch9)
        patches.assemble(&a)

        modulePtr = a.addressOf(module)
        playPtr = a.addressOf(play)
        initPtr = a.addressOf(initSong)
        songPtr = a.addressOf(songs)
        tablePtr = a.addressOf(table)
        endPtr = a.addressOf(end)
    }

    /// `InitPlayer` (lines 316-446).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let refusal = TuneError.malformed("a module of Rob Hubbard's for Steve Bak's replayer whose code is not as the player looks for")
        _ = try host.call(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgGetListData), with: [(0, 0)])
        let module = host.machine.cpu.registers[8], size = Int(host.machine.cpu.registers[0])
        host.machine.poke32(modulePtr, module)
        for i in stride(from: 0, to: 5000, by: 4) { host.machine.poke32(Self.buffer + UInt32(i), 0) }
        let most = size + 0x1000
        // Jupiter Probe's samples mended.
        if host.machine.peek16(module + 320) == 0xFB2C { host.machine.poke16(module + 320, 0xFEF4) }
        // Each found a word at a time, the search going on past the last: the routine for a tick after the
        // first RTS from the 180th byte; the one that stops it four bytes past the next word $DFFC; the one
        // that starts a song after the next RTS (its MOVE.W (SP)+,SR before it taken out); and past the
        // next MOVEQ #2,D7, the songs, where its next instruction's displacement and two point.
        func past(_ word: UInt16, from: UInt32) throws(TuneError) -> UInt32 {
            guard let at = WantedTeamSearch.find(host, [word], from: from, most: most - Int(from &- module)) else { throw refusal }
            return at + 2
        }
        let play = try past(0x4E75, from: module + 180)
        host.machine.poke32(playPtr, play)
        var a2 = try past(0xDFFC, from: play) + 4
        host.machine.poke32(endPtr, a2)
        a2 = try past(0x4E75, from: a2)
        host.machine.poke32(initPtr, a2)
        if host.machine.peek16(a2 - 4) == 0x46DF { host.machine.poke16(a2 - 4, 0x4E71) }
        a2 = try past(0x7E02, from: a2)
        let songs = a2 &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(a2 + 2)))) &+ 2
        host.machine.poke32(songPtr, songs)
        // Its songs: the offset of the first song's first list, in twelves (a DIVU.W).
        guard Int(songs) + 4 <= host.memorySize else { throw refusal }
        let first = host.machine.peek32(songs)
        let count = first / 12 <= 0xFFFF ? Int(first / 12) : Int(first & 0xFFFF)
        // Past the next RTS, the displacement of the byte InitSound sets (`Half`); a branch after it made
        // to go back eight bytes, and one ten after the next BTST #3,d(A1) (FindRTS, FindIt2).
        a2 = try past(0x4E75, from: a2)
        host.machine.poke16(halfAt, host.machine.peek16(a2 + 2))
        host.machine.poke16(a2 + 6, 0xFFF8)
        if host.machine.peek16(a2 - 4) == 0x46DF { host.machine.poke16(a2 - 4, 0x4E71) }
        guard let btst = WantedTeamSearch.find(host, [0x0829, 0x0003], from: a2, most: most - Int(a2 &- module)) else { throw refusal }
        host.machine.poke16(btst + 8, 0xFFF6)
        // The table of instruments: from the first ASL.W #2,D0; ADDA.L d(A0,D0.W),A0, the displacement
        // before it, and the long it points at added (FindOP).
        guard let op = WantedTeamSearch.find(host, [0xE548, 0xD1F0], from: module, most: most) else { throw refusal }
        var table = (op - 2) &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(op - 2))))
        guard Int(table) + 4 <= host.memorySize else { throw refusal }
        table &+= host.machine.peek32(table)
        host.machine.poke32(tablePtr, table)
        // `ModuleChange` (lines 203-222): the patches made in the 1,600 bytes from the routine for a tick.
        patches.apply(&host, from: play, length: 1600)
        guard count > 0 else { throw refusal }
        return WantedTeamSongs(first: 0, count: min(count, 256))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
