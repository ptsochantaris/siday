// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Ashley Hogg's music ("Ashley Hogg player module V1.0 (28 Oct 2010)",
// UADE's players/Ashley_Hogg), whose source is in UADE's amigasrc/players/wanted_team/Ashley Hogg/SRC_AshleyHogg/
// Ashley Hogg_v1.asm: its lines are given.

/// Ashley Hogg's music for the Amiga (of 1991 to 1993, as the player's credit has it; the later kind's
/// patterns packed by Jonathan Menzies' routine, as the player's notes have it): each module is his 68000
/// code that plays it, with its music, as the game had it, and no header. The player knows two kinds of
/// it, which it tells apart by the BRAs the module begins with. The first (of 1991: Nobby the Aardvark,
/// Spike in Transylvania, CJ in the USA) has four, to its routines to start a song (with its number, from
/// nought, in D0) and the rest, its routine for a tick following them, and its samples in it. The second
/// (of 1993: Cosmic Spacehead, Fantastic Dizzy) has seven, a line of text after them, and its samples in a
/// file of their own beside it: `ASH.name`'s are in `SMP.name`, as the player asks for them (and
/// `name.ash`'s in `name.smp`, as siday asks for them, the collections' way of naming them). Its code plays
/// from interrupts of CIA-B's of its own, one tick's work spread over three of them, each setting the next
/// going, which the player does without: its patches return from the module's start before it sets them
/// going, and in their place wait eight lines of the beam (`DMAWait`) and call the next part of the tick's
/// work themselves.
///
/// As the player plays them, fifty ticks a second: each of the module's writes of a voice's volume
/// (turned down by the balance, which is none), period, sample and length patched to tell EaglePlayer's
/// scopes. A song ends, for the first kind, when the module, stopped, silences its voices, or once each
/// voice that has a list of patterns has come to its loop; for the second, as the module comes to the end
/// of its song and goes back to its start, or (siday's) as it jumps back to an earlier place in it, where
/// a song that repeats begins again (which the player does not take for its end). Songs that fall silent
/// and stay so, as many of the second kind's short ones do, have no end of their own.
typealias AshleyHoggPlayer = WantedTeamPlayer<AshleyHogg>

struct AshleyHogg: WantedTeamRecipe {
    static let format = "Ashley Hogg"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -21.9 dB.)
    static let gain: Float = 0.35

    /// `Check2` (lines 536-589): the kind of module (1 for that of 1993, 0 for that of 1991), or nil. Four
    /// BRA.Ws, each forward to an even place; then, for 1993's, two more, the second of which goes forward
    /// to `MOVEM.L D0-D7/A0-A6,-(A7); BSR.W` to a routine that begins `LEA $DFF000,A6`; for 1991's,
    /// `MOVE.W #0,D0; BNE.S; MOVE.W D0,`.
    static func kind(_ data: [UInt8]) -> Int? {
        func long(_ at: Int) -> UInt32 { WantedTeamHeader.long(data, at) }
        func word(_ at: Int) -> UInt16 { at >= 0 && at + 2 <= data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0 }
        func forward(_ at: Int) -> Bool { word(at) == 0x6000 && word(at + 2) != 0 && word(at + 2) < 0x8000 && word(at + 2) & 1 == 0 }
        guard (0 ..< 4).allSatisfy({ forward($0 * 4) }) else { return nil }
        guard word(16) == 0x6000 else { return long(16) == 0x303C_0000 && long(20) == 0x6622_33C0 ? 0 : nil }
        guard forward(16), word(20) == 0x6000 else { return nil }
        let displacement = word(22)
        guard displacement != 0, displacement < 0x8000, displacement & 1 == 0 else { return nil }
        let at = 22 + Int(displacement)
        guard long(at) == 0x48E7_FFFE, word(at + 4) == 0x6100 else { return nil }
        let routine = at + 6 + Int(Int16(bitPattern: word(at + 6)))
        return word(routine) == 0x4DF9 && long(routine + 2) == 0x00DF_F000 ? 1 : nil
    }

    static func isOne(_ data: [UInt8]) -> Bool { kind(data) != nil }

    /// The game's name, from 1993's text (what it has before its colon).
    private(set) var title = ""
    let author = "Ashley Hogg"

    private var modulePtr: UInt32 = 0, formatAt: UInt32 = 0, playPtr: UInt32 = 0, play2Ptr: UInt32 = 0
    private var samplesPtr: UInt32 = 0, songsPtr: UInt32 = 0, basePtr: UInt32 = 0, lastAt: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches1993 = WantedTeamPatches(), patches1991 = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables (lines 50-91): the module, its kind (a byte), the globals, the module's routines
        // for a tick (and 1993's second), its songs (1991's), its samples (1993's), the module's own
        // variables (1993's, as its start gives them), the first voice's record and the one with the
        // longest list (1991's), the voices' ends (four bytes) and a copy of them, the sides' volumes,
        // the voices' muting, the scopes; and the module's information, of which `InitSound` keeps the
        // song's length.
        let module = a.variable(long: 0), format = a.variable(word: 0)
        let eagleBase = a.eagleBase()
        let play = a.variable(long: 0), play2 = a.variable(long: 0), samples = a.variable(long: 0)
        let base = a.variable(long: 0), firstBase = a.variable(long: 0)
        _ = a.variable(long: 0) // OldBase
        let songEnd = a.variable(long: 0x5754_5754)
        _ = a.variable(long: 0) // TempEnd
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        let info = a.placed()
        for _ in 0 ..< 34 { a.w(0) }
        // `SetVolume` (lines 289-304, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `ChangeVolume`, `SetVol`, `SetTwo` and `SetPer` (lines 306-397), for 1991's: the volume in D6 of
        // the voice whose registers A1 points at, its sample's address in A3 and length at $28(A0), its
        // period in D2.
        let changeVolume = a.balancedVolume(value: 6, base: 1, temp: 2, left: leftVolume, right: rightVolume, voices: voices)
        let setVol = a.scopeRoutine(scopes, base: 1, field: 4, voicesAt: 0xDFF0A0, body: [0x3086]) // MOVE.W D6,(A0)
        // MOVE.L A3,(A2); MOVE.W $28(A0),UPS_Voice1Len(A2)
        let setTwo = a.scopeRoutine(scopes, base: 1, field: 0, pointer: 2, voicesAt: 0xDFF0A0, body: [0x248B, 0x3568, 0x0028, 0x0004])
        let setPer = a.scopeRoutine(scopes, base: 1, field: 3, voicesAt: 0xDFF0A0, body: [0x3082]) // MOVE.W D2,(A0)
        // Their twins for 1993's (lines 399-490), of the voice whose registers A5 points at: its volume in
        // D4, its sample's address at $18(A1) and length at $20(A1), its period in D3.
        let changeVolume2 = a.balancedVolume(value: 4, base: 5, temp: 1, left: leftVolume, right: rightVolume, voices: voices)
        let setVol2 = a.scopeRoutine(scopes, base: 5, field: 4, voicesAt: 0xDFF0A0, body: [0x3084]) // MOVE.W D4,(A0)
        // MOVE.L $18(A1),(A0); MOVE.W $20(A1),UPS_Voice1Len(A0)
        let setTwo2 = a.scopeRoutine(scopes, base: 5, field: 0, voicesAt: 0xDFF0A0, body: [0x20A9, 0x0018, 0x3169, 0x0020, 0x0004])
        let setPer2 = a.scopeRoutine(scopes, base: 5, field: 3, voicesAt: 0xDFF0A0, body: [0x3083]) // MOVE.W D3,(A0)
        // `Interrupt` (lines 624-643, DTP_Interrupt), `DMAWait` (645-653) and `SongEnd` (655-661).
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 4)
        let dmaWait = a.dmaWait(lines: 8)
        let songEndRoutine = a.songEndRoutine(eagleBase: eagleBase)
        // siday's `DTP_Interrupt`: the player's, and then, for 1993's, the song's end said if its place
        // (the word at $F4 of the module's variables, which the player gives EaglePlayer as the song's
        // position, lines 97-103) has gone back since the last tick: the module's jump back to an earlier
        // place, where a song that repeats begins again, which the player does not take for its end.
        let last = a.variable(word: 0)
        tick = a.here
        let done = a.label(), onwards = a.label()
        a.w(0x6100)
        a.displacement(to: tickRoutine) // BSR.W Interrupt
        a.w(0x2F08, 0x103A) // MOVE.L A0,-(A7); MOVE.B CurrentFormat(PC),D0
        a.displacement(to: format)
        a.branch(0x6700, to: done) // BEQ.S
        a.w(0x207A)
        a.displacement(to: base) // MOVEA.L Base(PC),A0
        a.w(0x3028, 0x00F4, 0xB07A) // MOVE.W $F4(A0),D0; CMP.W Last(PC),D0
        a.displacement(to: last)
        a.branch(0x6400, to: onwards) // BCC.S
        a.w(0x6100)
        a.displacement(to: songEndRoutine) // BSR.W SongEnd
        a.place(onwards)
        a.w(0x33C0)
        a.address(of: last) // MOVE.W D0,Last
        a.place(done)
        a.w(0x205F, 0x7000, 0x4E75) // MOVEA.L (A7)+,A0; MOVEQ #0,D0; RTS
        // `SongEndTest` (lines 663-698), for 1991's: the voice whose record A0 points at (74 bytes each from
        // the first's) ended; once all four have, their ends set again from the copy and the song's end said.
        let songEndTest = a.placed()
        let test = a.label(), skip = a.label()
        a.w(0x48E7, 0x0044, 0x43FA) // MOVEM.L A1/A5,-(A7); LEA Songend(PC),A1
        a.displacement(to: songEnd)
        a.w(0x2A7A)
        a.displacement(to: firstBase) // MOVEA.L FirstBase(PC),A5
        for v in 0 ..< 4 {
            let next = a.label()
            if v > 0 { a.w(0x4BED, 0x004A) } // LEA 74(A5),A5
            a.w(0xBBC8) // CMPA.L A0,A5
            a.branch(0x6600, to: v < 3 ? next : test) // BNE.B
            if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
            if v < 3 {
                a.branch(0x6000, to: test) // BRA.B test
                a.place(next)
            }
        }
        a.place(test)
        a.w(0x4A99) // TST.L (A1)+
        a.branch(0x6600, to: skip) // BNE.B SkipEnd
        a.w(0x2311, 0x2A7A) // MOVE.L (A1),-(A1); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(skip)
        a.w(0x4CDF, 0x2200, 0x4E75) // MOVEM.L (A7)+,A1/A5; RTS
        // `InitSound` (lines 902-921, DTP_InitSound): the scopes cleared; for 1993's, the module's start
        // called with its samples in A1, then its routine at 4 to set the song (from one, in D0) and its
        // first tick (at 12), and the song's length for EaglePlayer kept.
        initSoundAt = a.here
        let oldFormat = a.label()
        a.clearScopes(scopes)
        a.w(0x207A)
        a.displacement(to: module) // MOVEA.L ModulePtr(PC),A0
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x123A) // MOVE.W dtg_SndNum(A5),D0; MOVE.B CurrentFormat(PC),D1
        a.displacement(to: format)
        a.branch(0x6700, to: oldFormat) // BEQ.B OldFormat
        a.w(0x227A)
        a.displacement(to: samples) // MOVEA.L SamplesPtr(PC),A1
        a.w(0x4E90, 0x4EA8, 0x0004, 0x4EA8, 0x000C, 0x207A) // JSR (A0); JSR 4(A0); JSR 12(A0); MOVEA.L Base(PC),A0
        a.displacement(to: base)
        a.w(0x3028, 0x00F6, 0x41FA) // MOVE.W $F6(A0),D0; LEA InfoBuffer(PC),A0
        a.displacement(to: info)
        a.w(0x3140, 0x0036, 0x4E75) // MOVE.W D0,Length+2(A0); RTS
        // `OldFormat` (lines 923-967), for 1991's: the module's start called with the song from nought in
        // D0 (which gives its voices' records in A4); and for each voice with no list of patterns in the
        // song's entry its end noted at once, and of the others the one whose list is longest (to a byte of
        // $80 or $81) kept, its length EaglePlayer's.
        a.place(oldFormat)
        let nextLength = a.label(), noLength = a.label(), findByte = a.label(), endByte = a.label(), maxLength = a.label()
        a.w(0x5340, 0x2F00, 0x207A) // SUBQ.W #1,D0; MOVE.L D0,-(SP); MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x4E90, 0x201F, 0x267A) // JSR (A0); MOVE.L (SP)+,D0; MOVEA.L SongsPtr(PC),A3
        a.displacement(to: play2)
        a.w(0xE948, 0xD6C0, 0x7281, 0x7480, 0x7803, 0x7A00, 0x43FA) // LSL.W #4,D0; ADDA.W D0,A3; MOVEQ #-127,D1; MOVEQ #-128,D2; MOVEQ #3,D4; MOVEQ #0,D5; LEA FirstBase(PC),A1
        a.displacement(to: firstBase)
        a.w(0x22CC, 0x45FA) // MOVE.L A4,(A1)+; LEA Songend(PC),A2
        a.displacement(to: songEnd)
        a.w(0x2482) // MOVE.L D2,(A2)
        a.place(nextLength)
        a.w(0x4A9B) // TST.L (A3)+
        a.branch(0x6600, to: noLength) // BNE.B
        a.w(0x421A) // CLR.B (A2)+
        a.branch(0x6000, to: maxLength) // BRA.B
        a.place(noLength)
        a.w(0x528A, 0x202C, 0x0032, 0x2040) // ADDQ.L #1,A2; MOVE.L $32(A4),D0; MOVEA.L D0,A0
        a.place(findByte)
        a.w(0x1618, 0xB403) // MOVE.B (A0)+,D3; CMP.B D3,D2
        a.branch(0x6700, to: endByte) // BEQ.B
        a.w(0xB203) // CMP.B D3,D1
        a.branch(0x6600, to: findByte) // BNE.B
        a.place(endByte)
        a.w(0x91C0, 0xBA88) // SUBA.L D0,A0; CMP.L A0,D5
        a.branch(0x6E00, to: maxLength) // BGT.B
        a.w(0x2A08, 0x228C) // MOVE.L A0,D5; MOVE.L A4,(A1)
        a.place(maxLength)
        a.w(0x49EC, 0x004A, 0x51CC) // LEA 74(A4),A4; DBF D4,NextLength
        a.displacement(to: nextLength)
        a.w(0x24AA, 0xFFFC, 0x43FA) // MOVE.L -4(A2),(A2); LEA InfoBuffer(PC),A1
        a.displacement(to: info)
        a.w(0x2345, 0x0034, 0x4E75) // MOVE.L D5,Length(A1); RTS

        // The patches for 1993's (`PatchTable`, lines 985-995 and 1005-1118). Patch1: the module's start, as
        // it comes to set its interrupts going (LEA $BFE001,A0), returned from, its variables (A0) kept.
        let patch1 = a.placed()
        a.w(0x43FA)
        a.displacement(to: base) // LEA Base(PC),A1
        a.w(0x2288, 0x588F, 0x4CDF, 0x7FFF, 0x4E75) // MOVE.L A0,(A1); ADDQ.L #4,SP; MOVEM.L (SP)+,D0-D7/A0-A6; RTS
        patches1993.add([0x41F9, 0x00BF, 0xE001], patch: patch1)
        // Patch2: its first interrupt's (LEA $BFD000,A4; TST.B $D00(A4)): the wait, its second part of
        // the tick called, and returned from.
        let patch2 = a.placed()
        a.w(0x6100)
        a.displacement(to: dmaWait) // BSR.W DMAWait
        a.w(0x207A)
        a.displacement(to: play2) // MOVEA.L Play2Ptr(PC),A0
        a.w(0x4E90, 0x588F, 0x4CDF, 0x7FFF, 0x4E75) // JSR (A0); ADDQ.L #4,SP; MOVEM.L (SP)+,D0-D7/A0-A6; RTS
        patches1993.add([0x49F9, 0x00BF, 0xD000, 0x4A2C, 0x0D00], patch: patch2)
        // Patch3: its setting of the next interrupt (MOVE.L A1,$78(A0); TST.B $BFDD00; MOVE.W #$2000,$DFF09C):
        // the wait, and the next called at once.
        let patch3 = a.placed()
        a.w(0x6100)
        a.displacement(to: dmaWait) // BSR.W DMAWait
        a.w(0x4E91, 0x588F, 0x4CDF, 0x4301, 0x4E75) // JSR (A1); ADDQ.L #4,SP; MOVEM.L (SP)+,D0/A0/A1/A6; RTS
        patches1993.add([0x2149, 0x0078, 0x4A39, 0x00BF, 0xDD00, 0x33FC, 0x2000, 0x00DF, 0xF09C], patch: patch3)
        // Patch4: the last (MOVE.L A1,$78(A0); TST.B $BFDD00; MOVE.B #$80,$BFDE00), returned from.
        let patch4 = a.placed()
        a.w(0x588F, 0x4CDF, 0x4300, 0x4E75) // ADDQ.L #4,SP; MOVEM.L (SP)+,A0/A1/A6; RTS
        patches1993.add([0x2149, 0x0078, 0x4A39, 0x00BF, 0xDD00, 0x13FC, 0x0080, 0x00BF, 0xDE00], patch: patch4)
        // Patch5: the song's end (Fantastic Dizzy's, CMPI.W #8,$F2(A0)), and three instructions passed over.
        let patch5 = a.placed()
        a.w(0x6100)
        a.displacement(to: songEndRoutine) // BSR.W SongEnd
        a.w(0x5097, 0x4E75) // ADDQ.L #8,(SP); RTS
        patches1993.add([0x0C68, 0x0008, 0x00F2], patch: patch5)
        // Patch6: the song's end (CMP.W D0,D1; BNE.S; CLR.W D0).
        let patch6 = a.placed()
        let noEnd = a.label()
        a.w(0xB240) // CMP.W D0,D1
        a.branch(0x6600, to: noEnd) // BNE.B NoEnd
        a.w(0x6100)
        a.displacement(to: songEndRoutine) // BSR.W SongEnd
        a.w(0x4240) // CLR.W D0
        a.place(noEnd)
        a.w(0x4E75)
        patches1993.add([0xB240, 0x6602, 0x4240], patch: patch6)
        // Patch7: a sample (MOVE.L $18(A1),0(A5); MOVE.W $20(A1),4(A5)).
        let patch7 = a.placed()
        a.w(0x2AA9, 0x0018, 0x3B69, 0x0020, 0x0004, 0x6100) // MOVE.L $18(A1),(A5); MOVE.W $20(A1),4(A5); BSR.W SetTwo2
        a.displacement(to: setTwo2)
        a.w(0x4E75)
        patches1993.add([0x2B69, 0x0018, 0x0000, 0x3B69, 0x0020, 0x0004], patch: patch7)
        // Patch8: a period (MOVE.W D3,6(A5); RTS), and the RTS made.
        let patch8 = a.placed()
        a.w(0x3B43, 0x0006, 0x6100) // MOVE.W D3,6(A5); BSR.W SetPer2
        a.displacement(to: setPer2)
        a.w(0x588F, 0x4E75) // ADDQ.L #4,SP; RTS
        patches1993.add([0x3B43, 0x0006, 0x4E75], patch: patch8)
        // Patch9: a volume (MOVE.W D4,8(A5); RTS), through `ChangeVolume2`, and the RTS made.
        let patch9 = a.placed()
        a.w(0x6100)
        a.displacement(to: changeVolume2) // BSR.W ChangeVolume2
        a.w(0x6100)
        a.displacement(to: setVol2) // BSR.W SetVol2
        a.w(0x588F, 0x4E75) // ADDQ.L #4,SP; RTS
        patches1993.add([0x3B44, 0x0008, 0x4E75], patch: patch9)

        // The patches for 1991's (`PatchTable1`, lines 996-1003 and 1120-1189). PatchH: a voice's list come
        // to its loop ($81) as it is read (MOVEA.L $32(A0),A1; MOVEQ #2,D0), the voice's end.
        let patchH = a.placed()
        let noBye = a.label()
        a.w(0x2268, 0x0032, 0x7002, 0x0C11, 0x0081) // MOVEA.L $32(A0),A1; MOVEQ #2,D0; CMPI.B #$81,(A1)
        a.branch(0x6600, to: noBye) // BNE.B NoBye
        a.w(0x6100)
        a.displacement(to: songEndTest) // BSR.W SongEndTest
        a.place(noBye)
        a.w(0x4E75)
        patches1991.add([0x2268, 0x0032, 0x7002], patch: patchH)
        // PatchI: a sample (MOVE.L A3,(A1); MOVE.W $28(A0),4(A1)).
        let patchI = a.placed()
        a.w(0x228B, 0x3368, 0x0028, 0x0004, 0x6100) // MOVE.L A3,(A1); MOVE.W $28(A0),4(A1); BSR.W SetTwo
        a.displacement(to: setTwo)
        a.w(0x4E75)
        patches1991.add([0x228B, 0x3368, 0x0028, 0x0004], patch: patchI)
        // PatchJ: a volume (LSR.W #6,D6; MOVE.W D6,8(A1)), through `ChangeVolume`.
        let patchJ = a.placed()
        a.w(0xEC4E, 0x6100) // LSR.W #6,D6; BSR.W ChangeVolume
        a.displacement(to: changeVolume)
        a.w(0x6100)
        a.displacement(to: setVol) // BSR.W SetVol
        a.w(0x4E75)
        patches1991.add([0xEC4E, 0x3346, 0x0008], patch: patchJ)
        // PatchK: a period (ADD.W $2C(A0),D2; MOVE.W D2,6(A1)).
        let patchK = a.placed()
        a.w(0xD468, 0x002C, 0x3342, 0x0006, 0x6100) // ADD.W $2C(A0),D2; MOVE.W D2,6(A1); BSR.W SetPer
        a.displacement(to: setPer)
        a.w(0x4E75)
        patches1991.add([0xD468, 0x002C, 0x3342, 0x0006], patch: patchK)
        // PatchL: the module's stop of its voices (MOVE.W D0,$DFF0A8), the song's end.
        let patchL = a.placed()
        a.w(0x6100)
        a.displacement(to: songEndRoutine) // BSR.W SongEnd
        a.w(0x33C0, 0x00DF, 0xF0A8, 0x4E75) // MOVE.W D0,$DFF0A8; RTS
        patches1991.add([0x33C0, 0x00DF, 0xF0A8], patch: patchL)
        // PatchR: Nobby's and Spike's mistake (MOVE.B $0,8(A0), the byte at address nought for nought) put right.
        let patchR = a.placed()
        a.w(0x117C, 0x0000, 0x0008, 0x4E75) // MOVE.B #0,8(A0); RTS
        patches1991.add([0x1179, 0x0000, 0x0000, 0x0008], patch: patchR)
        patches1993.assemble(&a)
        patches1991.assemble(&a)
        modulePtr = a.addressOf(module)
        formatAt = a.addressOf(format)
        playPtr = a.addressOf(play)
        play2Ptr = a.addressOf(play2)
        samplesPtr = a.addressOf(samples)
        basePtr = a.addressOf(base)
        lastAt = a.addressOf(last)
        songsPtr = play2Ptr
    }

    /// The name 1993's samples are asked for by, for a module of the name given (as `ExtLoad`, lines
    /// 188-241, makes it: `ASH.` at the start of the name's last part made `SMP.`; and, siday's, a last
    /// `.ash` made `.smp`); nil for a name of neither kind.
    static func samplesName(_ name: [UInt8]) -> [UInt8]? {
        let start = (name.lastIndex { $0 == 0x2F || $0 == 0x3A }).map { $0 + 1 } ?? 0
        let file = Array(name[start...])
        func lower(_ bytes: ArraySlice<UInt8>) -> [UInt8] { bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 } }
        if file.count >= 4, lower(file[0 ..< 4]) == Array("ash.".utf8) {
            return Array(name[..<start]) + Array("SMP".utf8) + file[3...]
        }
        if file.count > 4, lower(file[(file.count - 4)...]) == Array(".ash".utf8) {
            return Array(name.dropLast(3)) + Array("smp".utf8)
        }
        return nil
    }

    /// `InitPlayer` (lines 713-888), with `ExtLoad` before it for 1993's (as DeliTracker calls it): the
    /// module's routines and tables found by searching its code (the searches, which in the player run on
    /// for ever until they find what they look for, kept to the module here), and its code patched. A
    /// module shorter than its music or its samples is refused, as the player refuses it.
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let g = DeliTrackerHost.globals
        let (module, size) = try Desire.listData(&host)
        let found = Self.kind((0 ..< Int(min(size, 0x10000))).map { host.machine.peek8(module &+ UInt32($0)) })
        guard let found else { throw refuse() }
        if found == 1 {
            guard let name = Self.samplesName(host.moduleFileName) else {
                throw .missingCompanion("the samples of a module of Ashley Hogg's, kept beside it in a file whose name the module's does not give")
            }
            let path = host.machine.peek32(g + DeliTrackerHost.dtgPathArrayPtr)
            for (i, byte) in name.prefix(250).enumerated() { host.machine.poke8(path + UInt32(i), byte) }
            host.machine.poke8(path + UInt32(min(name.count, 250)), 0)
            guard try host.call(host.machine.peek32(g + DeliTrackerHost.dtgLoadFile)) == 0 else {
                throw .missingCompanion("the samples of a module of Ashley Hogg's, kept beside it in \(String(decoding: name, as: UTF8.self)), which was not found")
            }
        }
        return try found == 1 ? initPlayer1993(&host, module: module, size: size) : initPlayer1991(&host, module: module, size: size)
    }

    private func refuse() -> TuneError { .malformed("a module of Ashley Hogg's whose code is not as the player looks for") }
    private func tooShort() -> TuneError { .malformed("a module of Ashley Hogg's that is shorter than its music") }

    private func find(_ host: borrowing DeliTrackerHost, _ word: UInt16, from: UInt32, module: UInt32, end: UInt32) throws(TuneError) -> UInt32 {
        guard from >= module, from < end, let at = WantedTeamSearch.find(host, [word], from: from, most: Int(end - from)) else {
            throw refuse()
        }
        return at
    }

    private func relative(_ host: borrowing DeliTrackerHost, _ at: UInt32) -> UInt32 {
        at &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(at))))
    }

    /// `InitPlayer` for 1991's (lines 776-843): the routine for a tick, at 16; the songs' table, where the
    /// LEA x(PC),A0 after the first MOVE.B x(A0,Dn),y(A4) of the module's start points, to where the
    /// displacement before that MOVE.B points, sixteen bytes a song; and the samples (where the LEA x(PC)
    /// after the first MULU.W #imm,D1 points, and after that the first LEA x(PC),A3, and the second LEA
    /// x(PC),A4 after that), which must not end past the module's end.
    private mutating func initPlayer1991(_ host: inout DeliTrackerHost, module: UInt32, size: UInt32) throws(TuneError) -> WantedTeamSongs {
        let end = module &+ size
        host.machine.poke32(modulePtr, module)
        host.machine.poke16(formatAt, 0)
        host.machine.poke32(playPtr, module + 16)
        let start = relative(host, module + 2)
        let read = try find(host, 0x1970, from: start, module: module, end: end)
        let songsEnd = relative(host, read - 2)
        let songs = relative(host, try find(host, 0x41FA, from: read + 2, module: module, end: end) + 2)
        host.machine.poke32(songsPtr, songs)
        // (LSR.W #4 of the table's size, which leaves its upper word as it was; the count taken as a word.)
        let room = songsEnd &- songs
        let count = Int(Int16(truncatingIfNeeded: (room & 0xFFFF) >> 4))
        let mulu = try find(host, 0xC2FC, from: module + 16, module: module, end: end)
        let information = relative(host, mulu + 6)
        let samplesLEA = try find(host, 0x47FA, from: mulu + 6, module: module, end: end)
        let samples = relative(host, samplesLEA + 2)
        let first = try find(host, 0x49FA, from: samplesLEA + 2, module: module, end: end)
        let informationEnd = relative(host, try find(host, 0x49FA, from: first + 2, module: module, end: end) + 2)
        // The samples' end: the largest offset of a sample's (44 bytes each), and its length.
        var largest: UInt32 = 0, largestAt: UInt32?
        var at = information
        var entries = 0
        repeat {
            let offset = host.machine.peek32(at + 0x20)
            if Int32(bitPattern: offset) >= 0, Int32(bitPattern: largest) <= Int32(bitPattern: offset) {
                largest = offset
                largestAt = at
            }
            at &+= 0x2C
            entries += 1
        } while Int32(bitPattern: informationEnd) > Int32(bitPattern: at) && entries < 4096
        let length = largestAt.map { UInt32(host.machine.peek16($0 + 0x28)) * 2 } ?? 0
        guard Int32(bitPattern: (samples &- module) &+ largest &+ length) <= Int32(bitPattern: size) else { throw tooShort() }
        guard count >= 1 else { throw refuse() }
        // (`ModuleChange`, lines 247-274.)
        patches1991.apply(&host, from: module, length: 1800)
        return WantedTeamSongs(first: 1, count: min(count, 256))
    }

    /// `InitPlayer` for 1993's (lines 727-775, 850-882): the routine for a tick, at 12; the module's text,
    /// from 28 to its start, its runs of spaces broken where the player breaks them into lines (and the
    /// byte before its start made nought); its songs, the first word of the table the first LEA x(PC),A2
    /// of its start points at, a long each; the module's end, the HUNK_END ($3F2) after that table's
    /// last; the second part of its routine for a tick, where the next LEA x(PC),A4 points; and the
    /// samples, from their file: each a long of its offset and a word of its length at 8, sixteen bytes
    /// each, which must not end past the file's end.
    private mutating func initPlayer1993(_ host: inout DeliTrackerHost, module: UInt32, size: UInt32) throws(TuneError) -> WantedTeamSongs {
        let end = module &+ size
        let last = end &- 2
        host.machine.poke32(modulePtr, module)
        host.machine.poke16(formatAt, 0xFF00)
        host.machine.poke32(playPtr, module + 12)
        let start = relative(host, module + 2)
        var text: [UInt8] = []
        var at = module + 28
        repeat {
            let a = host.machine.peek8(at)
            at &+= 1
            if a == 0x20 {
                let b = host.machine.peek8(at)
                at &+= 1
                if b == 0x20 {
                    while host.machine.peek8(at) == 0x20, at < end { at &+= 1 }
                    at &+= 1
                    host.machine.poke8(at &- 2, 10)
                }
            }
        } while Int32(bitPattern: start) > Int32(bitPattern: at)
        host.machine.poke8(start &- 1, 0)
        for i in 0 ..< min(256, Int(start &- (module + 28))) {
            let byte = host.machine.peek8(module + 28 + UInt32(i))
            if byte == 0 || byte == 10 { break }
            text.append(byte)
        }
        if let colon = text.firstIndex(of: 0x3A) {
            title = String(decoding: text[..<colon], as: UTF8.self).trimmingSpaces
        }
        let lea = try find(host, 0x45FA, from: start, module: module, end: end)
        var table = relative(host, lea + 2)
        guard Int32(bitPattern: last) >= Int32(bitPattern: table) else { throw tooShort() }
        let first = host.machine.peek16(table)
        let count = Int(first >> 2)
        table = table &+ UInt32(bitPattern: Int32(Int16(bitPattern: first)))
        guard Int32(bitPattern: last) >= Int32(bitPattern: table) else { throw tooShort() }
        table = relative(host, table &- 2) &+ 2
        repeat {
            guard Int32(bitPattern: last) >= Int32(bitPattern: table) else { throw tooShort() }
            table &+= 2
        } while host.machine.peek16(table &- 2) != 0x03F2
        let play2 = relative(host, try find(host, 0x49FA, from: lea + 2, module: module, end: end) + 2)
        host.machine.poke32(play2Ptr, play2)
        // (`ModuleChange`, lines 247-274.)
        patches1993.apply(&host, from: module, length: 3500)
        let samplesSize = try host.call(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgGetListData), with: [(0, 1)])
        let samples = host.machine.cpu.registers[8]
        host.machine.poke32(samplesPtr, samples)
        var largest = host.machine.peek32(samples), largestAt = module
        let headersEnd = samples &+ largest
        var header = samples
        var headers = 0
        while headers < 4096 {
            let offset = host.machine.peek32(header)
            if offset == 0 || host.machine.peek16(header + 8) >= 0x8000 { break }
            if Int32(bitPattern: largest) <= Int32(bitPattern: offset) {
                largest = offset
                largestAt = header
            }
            header &+= 16
            headers += 1
            if Int32(bitPattern: headersEnd) <= Int32(bitPattern: header) { break }
        }
        let samplesEnd = largest &+ UInt32(host.machine.peek16(largestAt + 8)) * 2
        guard Int32(bitPattern: samplesSize &- samplesEnd) >= 0 else {
            throw .malformed("a module of Ashley Hogg's whose samples' file is shorter than its samples")
        }
        guard count >= 1 else { throw refuse() }
        return WantedTeamSongs(first: 1, count: min(count, 256))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
        // (The song's place as it starts, for siday's end of a song that repeats.)
        host.machine.poke16(lastAt, host.machine.peek16(host.machine.peek32(basePtr) &+ 0xF4))
    }
}

private extension String {
    /// The string without the spaces it begins and ends with.
    var trimmingSpaces: String {
        let bytes = Array(utf8)
        guard let first = bytes.firstIndex(where: { $0 != 0x20 }), let last = bytes.lastIndex(where: { $0 != 0x20 }) else {
            return ""
        }
        return String(decoding: bytes[first ... last], as: UTF8.self)
    }
}
