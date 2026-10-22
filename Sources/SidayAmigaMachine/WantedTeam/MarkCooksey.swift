// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Mark Cooksey's music ("Mark Cooksey player module V1.1 (13 Dec
// 2006)", by Don Adan, UADE's players/Mark_Cooksey), whose source is in UADE's amigasrc/players/wanted_team/
// Mark_Cooksey_Don_Adan/Mark Cooksey_v2.asm: its lines are given.

import SidayFoundation
import SidayM68000

/// Mark Cooksey's music for the Amiga's games of 1988 to 1990 (Paperboy, Ghosts'n Goblins, Commando,
/// Gremlins 2, Overlander and others), played by Richard Frankish's music player, as the games had it. The
/// player knows three kinds of module, of which siday plays two:
///
/// - the "new" modules (`.mc`), each the player's 68000 code with the music and samples: four or five
///   BRA.Ws behind a jump by D0 (`ADD.W D0,D0; ADD.W D0,D0; JMP x(PC,D0.W)`), the first the routine for a
///   tick and the next to start a song (its number in D0's upper word); those of 1990 have a routine to
///   make ready before them, which the player calls as it loads the module;
/// - the "first" modules of 1988 (`.mcr` and `.mcs`): the player's code alone, as a program of the Atari
///   ST's ($601A, then its BRA.Ws to start a song and play a tick), in a file of its own, and the song data
///   and samples in another beside it, which the player loads as well (named as the first is, with an S
///   for its R: `MCR.x` and `MCS.x`, or here `x.mcr` and `x.mcs`).
///
/// (The third, "used in some ARC games" as the player's readme has it, which begins with two BRA.Ws, `LEA
/// x(PC),A6`, a TST of (A6) and `LEA $DFF000,A0` (lines 653-679), is not in siday's collection, and is not
/// taken.)
///
/// As the player plays them: each of the code's writes of a voice's sample, length, period and volume
/// patched to tell EaglePlayer's scopes, and its volumes written as the player has them (those of 1989
/// halved where the code quartered them, those of 1990 halved where the code looked them up in its table)
/// and turned down by the balance, which is none; the new modules' waits for Paula's interrupts (as the
/// code stops a voice by setting its period to one, and starts it, with every interrupt turned off) made
/// waits for the beam to have passed the voices' turns at the memory, then for the interrupts' requests,
/// the interrupts left on; the first modules' starts of a sample made in a routine of the player's, which
/// waits eight lines of the beam in place of their waits for Paula; and the song's end said once each of
/// the four voices has stopped or gone back to its start (there is no other: one song of A Question of
/// Sport's, whose fourth voice waits for ten hours, does not end).
typealias MarkCookseyPlayer = WantedTeamPlayer<MarkCooksey>

struct MarkCooksey: WantedTeamRecipe {
    static let format = "Mark Cooksey"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -23.2 dB.)
    static let gain: Float = 0.41

    /// The player's file is 4,392 bytes, its hunks 4,184 and 4: relocated to $E000 by UADE, the module goes
    /// at $11000.
    static let moduleAt: UInt32 = 0x11000

    /// Where UADE's loading of the player puts its hunk of chip memory, `Buffy` (lines 1700-1702): four
    /// bytes of nought, which the first modules' voices are given to loop on once their sample has begun.
    static let silence: UInt32 = 0xF068

    /// Which of the player's kinds a module is: 0 a new one, -1 a first one (as its `Format` has them).
    static func kind(_ data: [UInt8]) -> Int? {
        func word(_ at: Int) -> UInt16 { at >= 0 && at + 2 <= data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0 }
        func long(_ at: Int) -> UInt32 { WantedTeamHeader.long(data, at) }
        // `Check2` (lines 590-651): a new one begins `ADD.W D0,D0; ADD.W D0,D0; JMP x(PC,D0.W)` and four
        // BRA.Ws, and then a LEA x(PC),A1 (those of 1989), or a fifth BRA.W and one 150 bytes in (1990).
        if long(0) == 0xD040_D040 {
            guard word(4) == 0x4EFB, word(8) == 0x6000, word(12) == 0x6000, word(16) == 0x6000, word(20) == 0x6000 else { return nil }
            if word(40) == 0x43FA { return 0 }
            return word(24) == 0x6000 && word(150) == 0x43FA ? 0 : nil
        }
        // A first one: an Atari ST's program's header, $601A and the size of its code (not below nought, and
        // even), and the rest of its 28 bytes nought; then four BRA.Ws forward, by even offsets, the first to
        // `MOVEM.L D0/A0-A3,-(A7)`.
        guard word(0) == 0x601A else { return nil }
        let code = long(2)
        guard code & 0x8000_0001 == 0, word(6) == 0 else { return nil }
        for at in stride(from: 8, to: 28, by: 4) where long(at) != 0 { return nil }
        for b in 0 ..< 4 {
            let offset = word(30 + b * 4)
            guard word(28 + b * 4) == 0x6000, offset & 0x8001 == 0 else { return nil }
        }
        return long(30 + Int(word(30))) == 0x48E7_80F0 ? -1 : nil
    }

    static func isOne(_ data: [UInt8]) -> Bool { kind(data) != nil }

    let title = ""
    /// (The player's `MI_AuthorName`, line 707.)
    let author = "Mark Cooksey"

    private var modulePtr: UInt32 = 0, dataPtr: UInt32 = 0, currentFormat: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0, patchOld: UInt32 = 0
    /// The places in the player's code that `InitPlayer` fills in with the first module's offsets
    /// (`ChangeIt1` to `ChangeItD`, lines 1017-1045): each the word of an instruction's displacement.
    private var voiceBit: [UInt32] = [], volumeAt: UInt32 = 0, sampleAt: UInt32 = 0
    private var stackAt: [UInt32] = [], stopAt: [UInt32] = [], positionAt: UInt32 = 0
    private var patches = WantedTeamPatches(), oldPatches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables (lines 52-87): the module, its kind (a word here: 0, or -1 for a first module), the
        // globals, the song data, the voices' ends (four bytes), the song's first step and its place, the
        // sides' volumes, the voices' muting, the scopes; and where `InitSound` tells EaglePlayer the song's
        // length (its `InfoBuffer`).
        let module = a.variable(long: 0), format = a.variable(word: 0)
        let eagleBase = a.eagleBase()
        let data = a.variable(long: 0)
        let songEnd = a.variable(long: 0x5754_5754)
        _ = a.variable(long: 0) // FirstStep
        let currentPos = a.variable(long: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        let info = a.placed()
        for _ in 0 ..< 18 { a.long(0) }

        // `SetVolume` (lines 307-322, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS

        // `ChangeVolume` and `ChangeVolume2` (lines 324-357, 435-468): the volume in `value` (D0, or D4),
        // seven bits, of the voice whose registers' base `base` (A4 from $DFF000, or A5 from $DFF0A0)
        // holds, turned down by its side's balance and nought if it is muted, written to the voice; `work`
        // (D2, or D1) kept.
        func volumeRoutine(_ a: inout AmigaAssembly, value: UInt16, base: UInt16, work: UInt16, first: UInt16) -> Int {
            let routine = a.placed()
            let ex = a.label(), exit = a.label(), left1 = a.label(), right1 = a.label(), right2 = a.label()
            a.w(0x2F00 | work, 0x0240 | value, 0x007F) // MOVE.L work,-(A7); ANDI.W #$7F,value
            a.w(0x2008 | work << 9 | base) // MOVE.L base,work
            for (v, to) in [(0, left1), (1, right1), (2, right2)] {
                a.w(0x0C40 | work, first + UInt16(v * 16)) // CMPI.W #$Fxx0,work
                a.branch(0x6700, to: to) // BEQ.S
            }
            a.w(0x0C40 | work, first + 48) // CMPI.W #$Fxx0,work
            a.branch(0x6600, to: exit) // BNE.S Exit2
            for (place, side, voice) in [(nil, leftVolume, voices[3]), (left1, leftVolume, voices[0]),
                                         (right1, rightVolume, voices[1]), (right2, rightVolume, voices[2])]
            {
                if let place { a.place(place) }
                a.w(0xC0FA | value << 9)
                a.displacement(to: side) // MULU.W side(PC),value
                a.w(0xC07A | value << 9)
                a.displacement(to: voice) // AND.W Voice(PC),value
                if voice != voices[2] { a.branch(0x6000, to: ex) } // BRA.S Ex
            }
            a.place(ex)
            a.w(0xEC48 | value) // LSR.W #6,value
            // MOVE.W value,$A8(A4), or MOVE.W value,8(A5)
            a.w(0x3140 | base << 9 | value, base == 4 ? 0x00A8 : 0x0008)
            a.place(exit)
            a.w(0x201F | work << 9, 0x4E75) // MOVE.L (A7)+,work; RTS
            return routine
        }
        let changeVolume = volumeRoutine(&a, value: 0, base: 4, work: 2, first: 0xF000)
        // The scopes' routines (lines 361-433): the volume, address, length or period in D0 of the voice A4
        // points at.
        let setVol = a.scopeRoutine(scopes, base: 4, field: 4, body: [0x3080]) // MOVE.W D0,(A0)
        let setAdr = a.scopeRoutine(scopes, base: 4, field: 0, body: [0x2080]) // MOVE.L D0,(A0)
        let setLen = a.scopeRoutine(scopes, base: 4, field: 2, body: [0x3080]) // MOVE.W D0,(A0)
        let setPer = a.scopeRoutine(scopes, base: 4, field: 3, body: [0x3080]) // MOVE.W D0,(A0)
        let changeVolume2 = volumeRoutine(&a, value: 4, base: 5, work: 1, first: 0xF0A0)
        // (Lines 472-544): the same in D4 (the address in A4) of the voice A5 points at, from $DFF0A0.
        let setVol2 = a.scopeRoutine(scopes, base: 5, field: 4, voicesAt: 0xDFF0A0, body: [0x3084]) // MOVE.W D4,(A0)
        let setAdr2 = a.scopeRoutine(scopes, base: 5, field: 0, voicesAt: 0xDFF0A0, body: [0x208C]) // MOVE.L A4,(A0)
        let setLen2 = a.scopeRoutine(scopes, base: 5, field: 2, voicesAt: 0xDFF0A0, body: [0x3084]) // MOVE.W D4,(A0)
        let setPer2 = a.scopeRoutine(scopes, base: 5, field: 3, voicesAt: 0xDFF0A0, body: [0x3084]) // MOVE.W D4,(A0)

        // `Interrupt` (lines 714-743, DTP_Interrupt): the scopes told a tick is played, and the module's
        // routine for it called: a new one's at its start with nought in D0, a first one's at 36.
        let interrupt = a.placed()
        let playOld = a.label(), playNew = a.label(), skipPlay = a.label()
        a.w(0x48E7, 0x7FFE, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(SP); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x50E8, 0x004C) // ST UPS_Enabled(A0)
        for v in 0 ..< 4 { a.w(0x4268, UInt16(6 + v * 18)) } // CLR.W UPS_VoiceNPer(A0)
        a.w(0x317C, 0x000F, 0x004A, 0x207A) // MOVE.W #UPSB_Adr!UPSB_Len!UPSB_Per!UPSB_Vol,UPS_Flags(A0); MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x4A79)
        a.address(of: format) // TST.B CurrentFormat (here TST.W of the word)
        a.branch(0x6700, to: playNew) // BEQ.B PlayNew
        a.branch(0x6B00, to: playOld) // BMI.B PlayOld
        a.w(0x4EA8, 0x0008) // JSR 8(A0)
        a.branch(0x6000, to: skipPlay) // BRA.B SkipPlay
        a.place(playOld)
        a.w(0x4EA8, 0x0024) // JSR 36(A0)
        a.branch(0x6000, to: skipPlay) // BRA.B SkipPlay
        a.place(playNew)
        a.w(0x7000, 0x4E90) // MOVEQ #0,D0; JSR (A0)
        a.place(skipPlay)
        a.endTick(scopes: scopes)
        tick = a.addressOf(interrupt)

        // `DMAWait` (lines 745-753).
        let dmaWait = a.dmaWait(lines: 8)

        // `SongEndTest` and `SongEndTest2` (lines 759-822): the byte of `SongEnd` of the voice whose
        // registers' base `base` holds (A5 from $DFF0A0, or A4 from $DFF000) cleared, and once all four
        // are, the song's end said and the count begun again.
        func endRoutine(_ a: inout AmigaAssembly, base: UInt16, voicesAt: UInt32) -> Int {
            let routine = a.placed(), test = a.label(), skip = a.label()
            a.w(0x48E7, 0x0044, 0x43FA) // MOVEM.L A1/A5,-(A7); LEA SongEnd(PC),A1
            a.displacement(to: songEnd)
            for v in 0 ..< 4 {
                let next = a.label()
                let at = voicesAt + UInt32(v * 16)
                a.w(0xB1FC | base << 9, UInt16(at >> 16), UInt16(at & 0xFFFF)) // CMPA.L #$DFF0x0,base
                a.branch(0x6600, to: v < 3 ? next : test) // BNE.B
                if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
                if v < 3 {
                    a.branch(0x6000, to: test) // BRA.B test
                    a.place(next)
                }
            }
            a.place(test)
            a.w(0x4A91) // TST.L (A1)
            a.branch(0x6600, to: skip) // BNE.B SkipEnd
            a.w(0x22BC, 0x5754, 0x5754, 0x2A7A) // MOVE.L #'WTWT',(A1); MOVEA.L EagleBase(PC),A5
            a.displacement(to: eagleBase)
            a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
            a.place(skip)
            a.w(0x4CDF, 0x2200, 0x4E75) // MOVEM.L (A7)+,A1/A5; RTS
            return routine
        }
        let songEndTest = endRoutine(&a, base: 5, voicesAt: 0xDFF0A0)
        let songEndTest2 = endRoutine(&a, base: 4, voicesAt: 0xDFF000)

        // `PatchOld` (lines 1163-1192), which a first module's start of a sample is made a jump to: the
        // voice's DMA turned off, its sample's address (after its length's word) and length, its volume
        // and its period (from the stack) written, eight lines of the beam waited for, its DMA turned
        // on, eight more, and the voice given `Buffy` to loop on; back from the module's routine for the
        // voice, as it goes back.
        patchOld = a.here
        let bit1 = a.here + 2
        a.w(0x316A, 0x0006, 0x0096) // MOVE.W 6(A2),$96(A0)
        sampleAt = a.here + 2
        a.w(0x286A, 0x000A, 0x381C, 0x2A8C) // MOVEA.L 10(A2),A4; MOVE.W (A4)+,D4; MOVE.L A4,(A5)
        call(&a, setAdr2)
        a.w(0x3B44, 0x0004) // MOVE.W D4,4(A5)
        call(&a, setLen2)
        volumeAt = a.here + 2
        a.w(0x382A, 0x0012) // MOVE.W $12(A2),D4
        call(&a, changeVolume2)
        call(&a, setVol2)
        a.w(0x381F, 0x3B44, 0x0006) // MOVE.W (SP)+,D4; MOVE.W D4,6(A5)
        call(&a, setPer2)
        call(&a, dmaWait)
        let bit2 = a.here + 2
        a.w(0x382A, 0x0006, 0x0044, 0x8000, 0x3144, 0x0096) // MOVE.W 6(A2),D4; ORI.W #$8000,D4; MOVE.W D4,$96(A0)
        call(&a, dmaWait)
        a.w(0x49F9)
        a.long(Self.silence) // LEA Buffy,A4
        a.w(0x2A8C, 0x3B7C, 0x0002, 0x0004) // MOVE.L A4,(A5); MOVE.W #2,4(A5)
        positionAt = a.here + 2
        a.w(0x254B, 0x0002, 0x4E75) // MOVE.L A3,2(A2); RTS
        voiceBit = [bit1, bit2]

        // `InitSound` (lines 1206-1242, DTP_InitSound): the scopes cleared and the voices' ends counted
        // afresh; a new module's start called with the song in D0's upper word and 1 in its lower; a first
        // one's at 28 with the song in D0 and its song data in A0, once the song's place in it is noted.
        initSoundAt = a.here
        let newFormat = a.label(), third = a.label()
        a.clearScopes(scopes)
        a.w(0x47FA)
        a.displacement(to: songEnd) // LEA SongEnd(PC),A3
        a.w(0x26FC, 0x5754, 0x5754) // MOVE.L #'WTWT',(A3)+
        a.w(0x7000, 0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x227A) // MOVEQ #0,D0; MOVE.W dtg_SndNum(A5),D0; MOVEA.L ModulePtr(PC),A1
        a.displacement(to: module)
        a.w(0x4A79)
        a.address(of: format) // TST.B CurrentFormat
        a.branch(0x6700, to: newFormat) // BEQ.B NewFormat
        a.branch(0x6A00, to: third) // BPL.B ThirdFormat
        a.w(0x207A)
        a.displacement(to: data) // MOVEA.L DataPtr(PC),A0
        a.w(0x41E8, 0x001C, 0x2448, 0x2200, 0xE989) // LEA 28(A0),A0; MOVEA.L A0,A2; MOVE.L D0,D1; LSL.L #4,D1
        a.w(0x49F2, 0x1008, 0x222C, 0x0004, 0x9294) // LEA 8(A2,D1.W),A4; MOVE.L 4(A4),D1; SUB.L (A4),D1
        a.w(0xD5D4, 0x26CA, 0x4293, 0xE489, 0x45FA) // ADDA.L (A4),A2; MOVE.L A2,(A3)+; CLR.L (A3); LSR.L #2,D1; LEA InfoBuffer(PC),A2
        a.displacement(to: info)
        a.w(0x2541, 0x0034, 0x4EE9, 0x001C) // MOVE.L D1,Length(A2); JMP 28(A1)
        a.place(newFormat)
        a.w(0x4840, 0x303C, 0x0001, 0x4ED1) // SWAP D0; MOVE.W #1,D0; JMP (A1)
        // (The third kind's, not taken here.)
        a.place(third)
        a.w(0x4E75)

        // The patches (`PatchTable`, lines 1260-1276 and 1291-1569), each a call in place of the module's
        // code it is put in: for the new modules.
        let none = a.placed()
        a.w(0x4E75) // PatchA, PatchB, PatchO, PatchP: RTS
        // Patch1 and Patch2: a volume in D2 or D0 of those of 1989 (`LSR.W #2,Dn; TST.B 0(A3); BEQ.S;
        // MOVE.W Dn,$A8(A4)`) or of 1990 (its scaling by the voice's level and its table, both left out
        // by the patches A and B), halved, at most $40, if the voice is the music's (0(A3)).
        func volume(_ a: inout AmigaAssembly, register r: UInt16) -> Int {
            let patch = a.placed(), ok = a.label(), skip = a.label()
            a.w(0xE248 | r, 0x4A13) // LSR.W #1,Dn; TST.B (A3)
            a.branch(0x6700, to: skip) // BEQ.B SkipVol
            a.w(0x0C40 | r, 0x0040) // CMP.W #$40,Dn
            a.branch(0x6300, to: ok) // BLS.B VolDn_OK
            a.w(0x7040 | r << 9) // MOVEQ #$40,Dn
            a.place(ok)
            if r != 0 { a.w(0x2F00, 0x2000 | r) } // MOVE.L D0,-(SP); MOVE.L Dn,D0
            call(&a, changeVolume)
            call(&a, setVol)
            if r != 0 { a.w(0x201F) } // MOVE.L (SP)+,D0
            a.place(skip)
            a.w(0x4E75)
            return patch
        }
        let patch1 = volume(&a, register: 2), patch2 = volume(&a, register: 0)
        // Patch5: a period, SWAP D0; MOVE.W D0,$A6(A4).
        let patch5 = a.placed()
        a.w(0x4840, 0x3940, 0x00A6)
        call(&a, setPer)
        a.w(0x4E75)
        // Patch6: a length and an address, MOVE.W $10(A5),$A4(A4); MOVE.L D1,$A0(A4).
        let patch6 = a.placed()
        a.w(0x396D, 0x0010, 0x00A4, 0x2F00, 0x302D, 0x0010) // MOVE.W $10(A5),$A4(A4); MOVE.L D0,-(A7); MOVE.W $10(A5),D0
        call(&a, setLen)
        a.w(0x2941, 0x00A0, 0x2001) // MOVE.L D1,$A0(A4); MOVE.L D1,D0
        call(&a, setAdr)
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        // Patch7: an address and a length, MOVE.L D0,$A0(A4); MOVE.W 14(A5),$A4(A4).
        let patch7 = a.placed()
        a.w(0x2940, 0x00A0) // MOVE.L D0,$A0(A4)
        call(&a, setAdr)
        a.w(0x396D, 0x000E, 0x00A4, 0x2F00, 0x302D, 0x000E) // MOVE.W 14(A5),$A4(A4); MOVE.L D0,-(A7); MOVE.W 14(A5),D0
        call(&a, setLen)
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        // Patch8: a period, and the voice's DMA turned on (its wait for Paula's interrupt the start of
        // it): once the beam is past the voices' turns at the memory ($16 of its line) the voices of D3 not
        // playing started, their interrupts' requests cleared first and waited for after; and the beam
        // waited for again.
        func waitPastAudio(_ a: inout AmigaAssembly) {
            let line = a.label(), slots = a.label()
            a.w(0x122A, 0x0006) // MOVE.B vhposr(A2),D1
            a.place(line)
            a.w(0xB22A, 0x0006) // CMP.B vhposr(A2),D1
            a.branch(0x6700, to: line) // BEQ.S .WaitLine
            a.place(slots)
            a.w(0x0C2A, 0x0016, 0x0007) // CMP.B #$16,vhposr+1(A2)
            a.branch(0x6500, to: slots) // BCS.S .WaitDMA
        }
        let patch8 = a.placed()
        a.w(0x3942, 0x00A6, 0x2F00, 0x3002) // MOVE.W D2,$A6(A4); MOVE.L D0,-(A7); MOVE.W D2,D0
        call(&a, setPer)
        a.w(0x201F) // MOVE.L (A7)+,D0
        waitPastAudio(&a)
        let started = a.label()
        a.w(0x302A, 0x0002, 0x4640, 0xC043, 0x3200) // MOVE.W dmaconr(A2),D0; NOT.W D0; AND.W D3,D0; MOVE.W D0,D1
        a.w(0x0041, 0x8000, 0xEF48, 0x3540, 0x009C) // OR.W #$8000,D1; LSL.W #7,D0; MOVE.W D0,intreq(A2)
        a.w(0x3541, 0x0096) // MOVE.W D1,dmacon(A2)
        a.place(started)
        a.w(0x322A, 0x001E, 0xC240, 0xB240) // MOVE.W intreqr(A2),D1; AND.W D0,D1; CMP.W D0,D1
        a.branch(0x6600, to: started) // BNE.S .WaitStart
        waitPastAudio(&a)
        a.w(0x4E75)
        // Patch9: an address, a length and a period, MOVE.L 10(A5),$A0(A4); MOVE.W $10(A5),$A4(A4);
        // MOVE.W D2,$A6(A4).
        let patch9 = a.placed()
        a.w(0x296D, 0x000A, 0x00A0, 0x2F00, 0x202D, 0x000A) // MOVE.L 10(A5),$A0(A4); MOVE.L D0,-(A7); MOVE.L 10(A5),D0
        call(&a, setAdr)
        a.w(0x396D, 0x0010, 0x00A4, 0x302D, 0x0010) // MOVE.W $10(A5),$A4(A4); MOVE.W $10(A5),D0
        call(&a, setLen)
        a.w(0x3942, 0x00A6, 0x3002) // MOVE.W D2,$A6(A4); MOVE.W D2,D0
        call(&a, setPer)
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        // PatchC: a command of the voice's list read (MOVEQ #$7F,D1; AND.B D0,D1; SUBI.B #$60,D1), and if
        // it is $68 (go back) or $67 (stop), the voice's end noted.
        let patchC = a.placed()
        let testEnd = a.label(), skipLoop = a.label()
        a.w(0x0C00, 0x0068) // CMP.B #$68,D0
        a.branch(0x6700, to: testEnd) // BEQ.B TestEnd
        a.w(0x0C00, 0x0067) // CMP.B #$67,D0
        a.branch(0x6600, to: skipLoop) // BNE.B SkipLoop
        a.place(testEnd)
        call(&a, songEndTest2)
        a.place(skipLoop)
        a.w(0x727F, 0xC200, 0x0401, 0x0060, 0x4E75) // MOVEQ #$7F,D1; AND.B D0,D1; SUBI.B #$60,D1; RTS
        // PatchD: the voice's DMA turned off (its period one, and its wait for Paula's interrupt the end of
        // it): once the beam is past the voices' turns, those of D3 playing stopped, their interrupts'
        // requests cleared first and waited for after (in place of turning Paula's interrupts off).
        let patchD = a.placed()
        waitPastAudio(&a)
        let stopped = a.label()
        a.w(0x397C, 0x0001, 0x00A6) // MOVE.W #1,aud0+ac_per(A4)
        a.w(0x382A, 0x0002, 0xC843, 0x3204, 0xEF4C) // MOVE.W dmaconr(A2),D4; AND.W D3,D4; MOVE.W D4,D1; LSL.W #7,D4
        a.w(0x3544, 0x009C, 0x3541, 0x0096) // MOVE.W D4,intreq(A2); MOVE.W D1,dmacon(A2)
        a.place(stopped)
        a.w(0x322A, 0x001E, 0xC244, 0xB244) // MOVE.W intreqr(A2),D1; AND.W D4,D1; CMP.W D4,D1
        a.branch(0x6600, to: stopped) // BNE.S .WaitStop
        a.w(0x4E75)

        patches.add([0xE44A, 0x4A2B, 0x0000, 0x6704, 0x3942, 0x00A8], patch: patch1) // Code1
        patches.add([0xE448, 0x4A2B, 0x0000, 0x6704, 0x3940, 0x00A8], patch: patch2) // Code2
        patches.add([0x4A2B, 0x0000, 0x671E, 0xC4EB, 0x0002, 0xE04A, 0x5242, 0xB47C, 0x0100, 0x6504, 0x7440, 0x6008],
                    patch: patch1) // Code3
        patches.add([0x4A2B, 0x0000, 0x671E, 0xC0EB, 0x0002, 0xE048, 0x5240, 0xB07C, 0x0100, 0x6504, 0x7040, 0x6008],
                    patch: patch2) // Code4
        patches.add([0x4840, 0x3940, 0x00A6], patch: patch5) // Code5
        patches.add([0x396D, 0x0010, 0x00A4, 0x2941, 0x00A0], patch: patch6) // Code6
        patches.add([0x2940, 0x00A0, 0x396D, 0x000E, 0x00A4], patch: patch7) // Code7
        patches.add([0x3942, 0x00A6, 0x08C3, 0x000F, 0x3544, 0x009C, 0x3543, 0x0096, 0x3544, 0x009C, 0x322A, 0x001E,
                     0xC244, 0x67F8], patch: patch8) // Code8
        patches.add([0x296D, 0x000A, 0x00A0, 0x396D, 0x0010, 0x00A4, 0x3942, 0x00A6], patch: patch9) // Code9
        patches.add([0x1430, 0x2000, 0x3942, 0x00A8], patch: none) // CodeA
        patches.add([0x1030, 0x0000, 0x3940, 0x00A8], patch: none) // CodeB
        patches.add([0x727F, 0xC200, 0x0401, 0x0060], patch: patchC) // CodeC
        patches.add([0x357C, 0x4000, 0x009A, 0x3543, 0x0096, 0x397C, 0x0001, 0x00A6, 0x4244, 0x5E41, 0x03C4, 0x3544,
                     0x009C], patch: patchD) // CodeD
        patches.add([0x426C, 0x00AA, 0x322A, 0x001E, 0xC244, 0x67F8, 0x3544, 0x009C], patch: none) // CodeO
        patches.add([0x357C, 0xC000, 0x009A], patch: none) // CodeP
        patches.assemble(&a)

        // And for the first modules (`PatchTable1`, lines 1277-1285 and 1571-1674).
        // PatchH and PatchI: a volume in D4 (doubled, for PatchI's), MOVE.W D4,8(A5).
        let patchH = a.placed()
        call(&a, changeVolume2)
        call(&a, setVol2)
        a.w(0x4E75)
        let patchI = a.placed()
        a.w(0xD844) // ADD.W D4,D4
        call(&a, changeVolume2)
        call(&a, setVol2)
        a.w(0x4E75)
        // PatchJ and PatchK: a period, MOVE.W (A4),6(A5) (PatchK's in place of MOVE.L (A4),6(A5), which
        // wrote the volume after it as well).
        func period(_ a: inout AmigaAssembly, add: Bool) -> Int {
            let patch = a.placed()
            if add { a.w(0xD8C4) } // ADDA.W D4,A4
            a.w(0x3B54, 0x0006, 0x2F04, 0x3814) // MOVE.W (A4),6(A5); MOVE.L D4,-(SP); MOVE.W (A4),D4
            call(&a, setPer2)
            a.w(0x281F, 0x4E75) // MOVE.L (SP)+,D4; RTS
            return patch
        }
        let patchJ = period(&a, add: false), patchK = period(&a, add: true)
        // PatchL: a voice stopped (MOVEQ #-1,D4; MOVE.W D4,x(A2)), and its end noted.
        let patchL = a.placed()
        let stop = a.here + 4
        a.w(0x78FF, 0x3544, 0x0062) // MOVEQ #-1,D4; MOVE.W D4,$62(A2)
        call(&a, songEndTest)
        a.w(0x4E75)
        // PatchM: a voice gone back to its start (MOVEA.L x(A2),A4; MOVEA.L (A4),A3), and its end noted.
        let patchM = a.placed()
        let back = a.here + 2
        a.w(0x286A, 0x0078, 0x2654) // MOVEA.L $78(A2),A4; MOVEA.L (A4),A3
        call(&a, songEndTest)
        a.w(0x4E75)
        // PatchN: a place in the voice's list pushed (MOVEA.L x(A2),A4; MOVE.L A3,-(A4); MOVE.L A4,x(A2)),
        // and the first voice's noted as the song's place.
        let patchN = a.placed()
        let noPosit = a.label()
        let push = [a.here + 2, a.here + 8]
        a.w(0x286A, 0x0016, 0x290B, 0x254C, 0x0016) // MOVEA.L $16(A2),A4; MOVE.L A3,-(A4); MOVE.L A4,$16(A2)
        a.w(0xBBFC, 0x00DF, 0xF0A0) // CMPA.L #$DFF0A0,A5
        a.branch(0x6600, to: noPosit) // BNE.B NoPosit
        a.w(0x23CB)
        a.address(of: currentPos) // MOVE.L A3,CurrentPos
        a.place(noPosit)
        a.w(0x4E75)
        stackAt = push
        stopAt = [stop]
        oldPatches.add([0x4A6A, 0x0000, 0x6604, 0x3B44, 0x0008], patch: patchH) // CodeH
        oldPatches.add([0xD844, 0x3B44, 0x0008], patch: patchI) // CodeI
        oldPatches.add([0x4A6A, 0x0000, 0x6604, 0x3B54, 0x0006], patch: patchJ) // CodeJ
        oldPatches.add([0xD8C4, 0x2B54, 0x0006], patch: patchK) // CodeK
        oldPatches.add([0x78FF, 0x3544, 0x0062], patch: patchL) // CodeL (its offset the module's)
        oldPatches.add([0x286A, 0x0078, 0x2654], patch: patchM) // CodeM (its offset the module's)
        oldPatches.add([0x286A, 0x0016, 0x290B, 0x254C, 0x0016], patch: patchN) // CodeN (its offsets the module's)
        oldPatches.assemble(&a)
        // (Where the patches PatchL, PatchM and PatchN have the module's offsets, ChangeIt6, 8, B and C.)
        stackAt += [back]
        modulePtr = a.addressOf(module)
        dataPtr = a.addressOf(data)
        currentFormat = a.addressOf(format)
    }

    private func call(_ a: inout AmigaAssembly, _ routine: Int) {
        a.w(0x6100)
        a.displacement(to: routine) // BSR.W
    }

    /// `InitPlayer` (lines 838-1048), and before it `ExtLoad` (lines 201-253) for a first module.
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        if host.machine.peek16(Self.moduleAt) == 0x601A { try Self.extLoad(&host) }
        let (module, size) = try Self.listData(&host, 0)
        func word(_ at: UInt32) -> UInt16 { host.machine.peek16(at) }
        func long(_ at: UInt32) -> UInt32 { host.machine.peek32(at) }
        func relative(_ at: UInt32) -> UInt32 { at &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(at)))) }
        let end = module + size
        // The player's searches of the module's code, which run on until they find what they look for:
        // here within the module, and a module that does not have it refused.
        func find(_ words: [UInt16], from: UInt32, to: UInt32 = end) throws(TuneError) -> UInt32 {
            guard from <= to, let at = WantedTeamSearch.find(host, words, from: from, most: Int(to - from)) else {
                throw .malformed("a module of Mark Cooksey's whose code is not as the player looks for")
            }
            return at
        }
        host.machine.poke32(modulePtr, module)
        if word(module) != 0x601A {
            // A new module: those of 1990 made ready (their routine at 8, called with the module in A0); the
            // songs counted from the first two tables the code points at, sixteen bytes each; the code
            // patched in its first 2,500 bytes.
            host.machine.poke16(currentFormat, 0)
            if word(module + 24) == 0x6000 {
                _ = try host.call(module + 8, with: [(0, size), (8, module), (9, module + 2)])
            }
            let first = try find([0x43FA], from: module + 2) + 2
            let second = try find([0x43FA], from: first) + 2
            let songs = (relative(second) &- relative(first)) >> 4
            guard songs > 0, songs <= 256 else { throw .malformed("a module of Mark Cooksey's with no songs") }
            patches.apply(&host, from: module, length: 2500)
            return WantedTeamSongs(first: 0, count: Int(songs))
        }
        // A first module (`FirstFormat`): its code whole, the start of a sample made a jump to `PatchOld`,
        // and the offsets the player's patches use found in the code that follows it.
        host.machine.poke16(currentFormat, 0xFFFF)
        let code = long(module + 2)
        guard code <= size, size - code >= 28 else { throw .malformed("a module of Mark Cooksey's cut short") }
        let codeEnd = module + 28 + code
        let start = try find([0x3828, 0x0002], from: module + 2, to: codeEnd)
        host.machine.poke16(start, 0x4EF9)
        host.machine.poke32(start + 2, patchOld)
        var at = start + 6
        // The voice's bit for DMACON: after the first $009C followed by MOVE.W x(A2),d(A0).
        while true {
            at = try find([0x009C], from: at, to: codeEnd) + 2
            if word(at) == 0x316A { break }
        }
        at += 2
        for place in voiceBit { host.machine.poke16(place, word(at)) }
        // Its volume, after MOVE.W x(A2),8(A5), and the sample's address, fourteen bytes before.
        at = try find([0x3B6A], from: at, to: codeEnd) + 2
        host.machine.poke16(volumeAt, word(at))
        host.machine.poke16(sampleAt, word(at - 14))
        // Its stack of places in its list: the word before the first MOVE.L A3,-(A4) (the offset of the
        // MOVEA.L x(A2),A4 it follows).
        at = try find([0x290B], from: at, to: codeEnd) - 2
        let stack = word(at)
        // Its count, from the MOVE.W D4,x(A2) after the first MOVEQ #-1,D4.
        at = try find([0x78FF], from: at, to: codeEnd) + 4
        let count = word(at)
        // Its place in its list, from the next MOVE.L A3,x(A2).
        at = try find([0x254B], from: at, to: codeEnd) + 2
        host.machine.poke16(positionAt, word(at))
        // ChangeIt5 to ChangeItC: the patterns of CodeL, CodeM and CodeN and their patches.
        host.machine.poke16(oldPatches.patternAt[4] + 4, count)
        host.machine.poke16(stopAt[0], count)
        host.machine.poke16(oldPatches.patternAt[5] + 2, stack)
        host.machine.poke16(oldPatches.patternAt[6] + 2, stack)
        host.machine.poke16(oldPatches.patternAt[6] + 8, stack)
        for place in stackAt { host.machine.poke16(place, stack) }
        for i in 0 ..< 4 { host.machine.poke8(Self.silence + UInt32(i), 0) }
        oldPatches.apply(&host, from: module, length: code)
        // The song data, loaded as the second file: an Atari ST's program's header, its size within the
        // file; its songs, sixteen bytes each, from the start of its table to the first's.
        let data = try Self.listData(&host, 1)
        guard data.size >= 28, word(data.at) == 0x601A, long(data.at + 2) <= data.size - 28 else {
            throw .malformed("song data of Mark Cooksey's that is not as the player looks for")
        }
        host.machine.poke32(dataPtr, data.at)
        let songs = (long(data.at + 36) &- 8) >> 4
        guard songs > 0, songs <= 256 else { throw .malformed("song data of Mark Cooksey's with no songs") }
        return WantedTeamSongs(first: 0, count: Int(songs))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }

    /// `ExtLoad` (lines 201-253): the song data loaded beside a first module, from the file named as the
    /// module's but for its prefix `MCR.` made `MCS.`; or here, for UnExoticA's names, its suffix `.mcr`
    /// made `.mcs`. (The player, given any other name, asks for one without its last letter, which is not
    /// to be had.)
    static func extLoad(_ host: inout DeliTrackerHost) throws(TuneError) {
        var name = host.moduleFileName
        let lower = name.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        if lower.starts(with: Array("mcr.".utf8)) {
            name[2] = 0x53
        } else if lower.count > 4, lower.suffix(4).elementsEqual(Array(".mcr".utf8)) {
            name[name.count - 1] = name[name.count - 1] == 0x52 ? 0x53 : 0x73
        } else {
            throw .missingCompanion("the song data of Mark Cooksey's music, which is named as its replayer is, MCS. for MCR.")
        }
        let path = host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgPathArrayPtr)
        for (i, byte) in name.enumerated() { host.machine.poke8(path + UInt32(i), byte) }
        host.machine.poke8(path + UInt32(name.count), 0)
        guard try host.call(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgLoadFile)) == 0 else {
            throw .missingCompanion("the song data of Mark Cooksey's music (\(String(decoding: name, as: UTF8.self)))")
        }
    }

    /// The players' `dtg_GetListData` of the file of number `index`: its address and its size.
    static func listData(_ host: inout DeliTrackerHost, _ index: UInt32) throws(TuneError) -> (at: UInt32, size: UInt32) {
        let size = try host.call(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgGetListData), with: [(0, index)])
        return (host.machine.cpu.registers[8], size)
    }
}
