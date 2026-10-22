// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Sound Images' music ("Sound Images player module V1.1 (6 June
// 2000)", UADE's players/SoundImages), whose source is not given: what it does is read from its code, and
// the addresses given are of its hunk in UADE's file.

import SidayFoundation

/// The music of Sound Images (Tony Williams', of 1988 to 1993 as the player's credit has it, for Shinobi,
/// Viz, Narc, Smash TV, Judge Dredd and the rest), as their games had it: each module is his 68000 code
/// that plays it, with its music and samples, beginning with a BRA to its routine for a tick and its
/// variables, among them the song to start (at 4) and the one playing (at 5); and its own handler of
/// Paula's audio interrupts, which gives a voice the rest of its sample once it has begun it. The player
/// calls what it finds "Sound Images 1"; its second kind, "Sound Images 2" (a module beginning with
/// `$B27A`), is not in siday's collection, and is refused.
///
/// As the player plays it: the module's audio interrupt, which ends with RTE, made to end with RTS and set
/// for Paula's four interrupts through exec's SetIntVector where the module would put it in the vector
/// itself; its writes of samples, periods and volumes patched to tell EaglePlayer's scopes (and the
/// volumes turned down by the balance, which is none); a song started by its number, from one, written to
/// the module for its next tick to start; and the song's end said when the module, after a tick, has no
/// song playing, or when every voice has come to the end of its list of patterns.
typealias SoundImagesPlayer = WantedTeamPlayer<SoundImages>

struct SoundImages: WantedTeamRecipe {
    static let format = "Sound Images"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -21.0 dB.)
    static let gain: Float = 0.32

    /// `Check2` ($500): the kind of the module, 1 or 2, or nil. The first is a BRA.W forwards to an even
    /// place two bytes before which is an RTE and `MOVEM.L`, and eight before `$009C4CDF` (the end of its
    /// audio interrupt: `MOVE.W D1,$9C(A6); MOVEM.L (A7)+,...`); the second begins `$B27A` and has
    /// `RTS; MOVEQ #-1,D0` at 34.
    static func kind(_ data: [UInt8]) -> Int? { kind { WantedTeamHeader.long(data, $0) } }

    /// `kind`, of the module whose longs (by their offset, nought past its end) `long` gives.
    static func kind(_ long: (Int) -> UInt32) -> Int? {
        if long(0) >> 16 == 0xB27A { return long(34) == 0x4E75_70FF ? 2 : nil }
        let distance = Int(long(0) & 0xFFFF)
        guard long(0) >> 16 == 0x6000, distance & 0x8001 == 0, distance >= 8 else { return nil }
        return long(distance) == 0x4E73_48E7 && long(distance - 6) == 0x009C_4CDF ? 1 : nil
    }

    static func isOne(_ data: [UInt8]) -> Bool { kind(data) != nil }

    let title = ""
    let author = "Tony Williams"

    private var modulePtr: UInt32 = 0, samplesPtr: UInt32 = 0, songTablePtr: UInt32 = 0, voicesLessPtr: UInt32 = 0
    private var volumeFlagPtr: UInt32 = 0, structsPtr: UInt32 = 0, samplesEndPtr: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0, holdAt: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($1D0 to $25E), in the player's order where its code relies on it: the module; the
        // kind's flag (Check2's byte, and the copy InitPlayer makes of it after it, which the rest reads);
        // the samples' table, the songs' table and the number of voices less one; whether the patches are
        // made; the globals; the voices still in their lists of patterns, and those a song began with
        // (four bytes each, "WTWT" as the player's file has them), and the count of patterns played after
        // them; whether the module's volumes are of sixteen steps; the voices' records; the sides' volumes;
        // the voices' muting; the scopes.
        let module = a.variable(long: 0)
        let kindFlags = a.variable(word: 0)
        let samples = a.variable(long: 0), songTable = a.variable(long: 0), voicesLess = a.variable(word: 0)
        _ = a.variable(word: 0)
        let eagleBase = a.eagleBase()
        let flags = a.variable(long: 0x5754_5754)
        _ = a.variable(long: 0x5754_5754)
        let position = a.variable(word: 0)
        let volumeFlag = a.variable(word: 0)
        let structs = (0 ..< 4).map { _ in a.variable(long: 0) }
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // (Of the player's information for EaglePlayer, $550 on, the one its code reads: where the samples
        // end, at $57C.)
        let samplesEnd = a.variable(long: 0)
        let channels = (0 ..< 4).map { _ in a.variable(long: 0) }
        let structure = a.interruptStructure()
        let secondKind = a.addressOf(kindFlags) + 1
        // `SetVolume` ($2A8, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `ChangeVolume` ($2CC): the volume in D0 (seven bits of it) of the voice whose registers' base A1
        // holds turned down by its side's balance, and nought if it is muted; entered past the comparisons
        // for one voice ($2F0, $2FA, $304, $30E: voice 3's, 0's, 1's, 2's).
        let changeVolume = a.placed()
        let shift = a.label(), done = a.label()
        let volumeOf = (0 ..< 4).map { _ in a.label() }
        a.w(0x0240, 0x007F) // ANDI.W #$7F,D0
        for v in 0 ..< 3 {
            a.w(0xB3FC, 0x00DF, 0xF0A0 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A1
            a.branch(0x6700, to: volumeOf[v]) // BEQ.S
        }
        a.w(0xB3FC, 0x00DF, 0xF0D0) // CMPA.L #$DFF0D0,A1
        a.branch(0x6600, to: done) // BNE.S
        for (v, side) in [(3, leftVolume), (0, leftVolume), (1, rightVolume), (2, rightVolume)] {
            a.place(volumeOf[v])
            a.w(0xC0FA)
            a.displacement(to: side) // MULU.W side(PC),D0
            a.w(0xC07A)
            a.displacement(to: voices[v]) // AND.W Voice(PC),D0
            if v != 2 { a.branch(0x6000, to: shift) } // BRA.S
        }
        a.place(shift)
        a.w(0xEC48) // LSR.W #6,D0
        a.place(done)
        a.w(0x4E75)
        // `SetVol` ($31A, the voice by A1) and its entries for one voice ($34A to $362): the scopes told a
        // voice's volume, D0.
        let setVol = a.scopeRoutine(scopes, base: 1, field: 4, pointer: 2, body: [0x3480]) // MOVE.W D0,(A2)
        let volumeSet = a.label()
        let volOf = (0 ..< 4).map { v in
            let routine = a.placed()
            a.w(0x2F0A, 0x45FA) // MOVE.L A2,-(A7); LEA StructAdr+UPS_VoiceNVol(PC),A2
            a.displacement(to: scopes[v * 9 + 4])
            if v < 3 { a.branch(0x6000, to: volumeSet) } // BRA.S
            return routine
        }
        a.place(volumeSet)
        a.w(0x3480, 0x245F, 0x4E75) // MOVE.W D0,(A2); MOVEA.L (A7)+,A2; RTS
        // `SetAdr`, `SetLen` ($36E, $39E: the voice by A2, its length's register) and `SetPer` ($3D0, the
        // voice by A1), and its entries for one voice ($402 to $41A): the scopes told a voice's sample, its
        // length and its period from the record at A0.
        let setAdr = a.scopeRoutine(scopes, base: 2, field: 0, pointer: 1, voicesAt: 0xDFF0A4, body: [0x2290]) // MOVE.L (A0),(A1)
        let setLen = a.scopeRoutine(scopes, base: 2, field: 2, pointer: 1, voicesAt: 0xDFF0A4, body: [0x32A8, 0x0004]) // MOVE.W 4(A0),(A1)
        let setPer = a.scopeRoutine(scopes, base: 1, field: 3, pointer: 2, body: [0x34A8, 0x0006]) // MOVE.W 6(A0),(A2)
        let periodSet = a.label()
        let perOf = (0 ..< 4).map { v in
            let routine = a.placed()
            a.w(0x2F0A, 0x45FA) // MOVE.L A2,-(A7); LEA StructAdr+UPS_VoiceNPer(PC),A2
            a.displacement(to: scopes[v * 9 + 3])
            if v < 3 { a.branch(0x6000, to: periodSet) } // BRA.S
            return routine
        }
        a.place(periodSet)
        a.w(0x34A8, 0x0006, 0x245F, 0x4E75) // MOVE.W 6(A0),(A2); MOVEA.L (A7)+,A2; RTS
        // `Interrupt` ($5BC, DTP_Interrupt): the scopes told a tick is being played; the module's routine
        // for a tick (its start, for the first kind); and if the byte at 5 of the module (at 6 in the one
        // whose samples end at $75D6, Chuckie Egg II's), the song playing, is then nought, its end said.
        tick = a.here
        let second = a.label(), noEnd = a.label(), played = a.label(), notThat = a.label()
        a.w(0x48E7, 0x7FFE, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(A7); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x317C, 0x000F, 0x004A, 0x50E8, 0x004C) // MOVE.W #$F,UPS_Flags(A0); ST UPS_Enabled(A0)
        for v in 0 ..< 4 { a.w(0x4268, UInt16(6 + v * 18)) } // CLR.W UPS_VoiceNPer(A0)
        a.w(0x207A)
        a.displacement(to: module) // MOVEA.L Module(PC),A0
        a.w(0x4A39)
        a.long(secondKind) // TST.B Kind
        a.branch(0x6600, to: second) // BNE.S
        a.w(0x4E90, 0x207A) // JSR (A0); MOVEA.L Module(PC),A0
        a.displacement(to: module)
        a.w(0x5A88, 0x0CB9, 0x0000, 0x75D6) // ADDQ.L #5,A0; CMPI.L #$75D6,SamplesEnd
        a.address(of: samplesEnd)
        a.branch(0x6600, to: notThat) // BNE.S
        a.w(0x5288) // ADDQ.L #1,A0
        a.place(notThat)
        a.w(0x4A10) // TST.B (A0)
        a.branch(0x6600, to: noEnd) // BNE.S
        a.w(0x2A7A)
        a.displacement(to: eagleBase) // MOVEA.L EagleBase(PC),A5
        a.w(0x206D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E90) // MOVEA.L dtg_SongEnd(A5),A0; JSR (A0)
        a.place(noEnd)
        a.branch(0x6000, to: played) // BRA.S
        a.place(second)
        a.w(0x7203, 0x4E90) // MOVEQ #3,D1; JSR (A0)
        a.place(played)
        a.endTick(scopes: scopes)
        // `SetAudioVector` ($624).
        let setAudioVector = a.setAudioVector(structure: structure, old: channels)
        // `InitSound` ($980, DTP_InitSound), for the first kind ($9D8): the song's number put at 4 of the
        // module, shifted by eight (so the song playing, at 5, is nought until its next tick starts it),
        // the next six bytes cleared, and the byte after them one for a module whose volumes are of sixteen
        // steps. Then, for its songs up to this one in the songs' table (the record of each its voices'
        // lists' offsets and a word more), the voices that have a list kept (and those without cleared),
        // and a voice with the longest list made the one whose patterns are counted; or, of four voices,
        // the first if the second's list begins one or two bytes after the first's. The voices kept again
        // as those the song began with, and the count cleared. (Of the player's information
        // for EaglePlayer, what it puts there of the voices and the patterns is left out.)
        let initSound = a.placed()
        let lc04 = a.label()
        let noFlag = a.label(), songs = a.label(), voice = a.label(), empty = a.label(), next = a.label()
        let length = a.label(), noLast = a.label(), kept = a.label()
        a.w(0x207A)
        a.displacement(to: module) // MOVEA.L Module(PC),A0
        a.w(0x5888, 0x7000, 0x302D, UInt16(DeliTrackerHost.dtgSndNum)) // ADDQ.L #4,A0; MOVEQ #0,D0; MOVE.W dtg_SndNum(A5),D0
        a.w(0x2200, 0xE188, 0x30C0, 0x4298, 0x4258) // MOVE.L D0,D1; LSL.L #8,D0; MOVE.W D0,(A0)+; CLR.L (A0)+; CLR.W (A0)+
        a.w(0x43FA)
        a.displacement(to: volumeFlag) // LEA VolumeFlag(PC),A1
        a.w(0x4A51) // TST.W (A1)
        a.branch(0x6700, to: noFlag) // BEQ.S
        a.w(0x10BC, 0x0001) // MOVE.B #1,(A0)
        a.place(noFlag)
        a.w(0x5381, 0x207A) // SUBQ.L #1,D1; MOVEA.L SongTable(PC),A0
        a.displacement(to: songTable)
        a.w(0x7800, 0x7E00) // MOVEQ #0,D4; MOVEQ #0,D7
        a.place(songs)
        a.w(0x303A)
        a.displacement(to: voicesLess) // MOVE.W VoicesLess(PC),D0
        a.w(0x4DFA)
        a.displacement(to: flags) // LEA Flags(PC),A6
        a.w(0x2CBC, 0x5754, 0x5754) // MOVE.L #"WTWT",(A6)
        a.w(0x7604, 0x7C00, 0x3E3C, 0xF090) // MOVEQ #4,D3; MOVEQ #0,D6; MOVE.W #$F090,D7
        a.place(voice)
        a.w(0x7AFF, 0x5087, 0x5087, 0x3818) // MOVEQ #-1,D5; ADDQ.L #8,D7; ADDQ.L #8,D7; MOVE.W (A0)+,D4
        a.branch(0x6700, to: empty) // BEQ.S
        a.w(0x528E, 0x227A) // ADDQ.L #1,A6; MOVEA.L SongTable(PC),A1
        a.displacement(to: songTable)
        a.w(0xD3C4) // ADDA.L D4,A1
        a.place(length)
        a.w(0x5285, 0x4A59) // ADDQ.L #1,D5; TST.W (A1)+
        a.branch(0x6600, to: length) // BNE.S
        a.w(0xBC85) // CMP.L D5,D6
        a.branch(0x6E00, to: next) // BGT.S
        a.w(0x2C05, 0x47FA) // MOVE.L D5,D6; LEA Lc04(PC),A3
        a.displacement(to: lc04)
        a.w(0x3687) // MOVE.W D7,(A3)
        a.branch(0x6000, to: next) // BRA.S
        a.place(empty)
        a.w(0x421E, 0x5383) // CLR.B (A6)+; SUBQ.L #1,D3
        a.place(next)
        a.w(0x51C8)
        a.displacement(to: voice) // DBF D0,voice
        a.w(0x5488, 0x51C9) // ADDQ.L #2,A0; DBF D1,songs
        a.displacement(to: songs)
        a.w(0x0C79, 0x0002)
        a.address(of: voicesLess) // CMPI.W #2,VoicesLess
        a.branch(0x6600, to: noLast) // BNE.S
        a.w(0x421E, 0x5383) // CLR.B (A6)+; SUBQ.L #1,D3
        a.branch(0x6000, to: kept) // BRA.S
        a.place(noLast)
        a.w(0x5188, 0x3810, 0x5588, 0x9850) // SUBQ.L #8,A0; MOVE.W (A0),D4; SUBQ.L #2,A0; SUB.W (A0),D4
        a.branch(0x6700, to: kept) // BEQ.S
        a.branch(0x6B00, to: kept) // BMI.S
        a.w(0x0C44, 0x0002) // CMPI.W #2,D4
        a.branch(0x6E00, to: kept) // BGT.S
        a.w(0x3C04, 0x36BC, 0xF0A0) // MOVE.W D4,D6; MOVE.W #$F0A0,(A3)
        a.place(kept)
        a.w(0x598E, 0x2CDE, 0x4256, 0x4E75) // SUBQ.L #4,A6; MOVE.L (A6)+,(A6)+; CLR.W (A6); RTS
        // The patches (`PatchTable`, $ABA), each with the module's code it is called in place of.
        // $AF8, $B02: the module's audio interrupt (in A0), which it would put in the vector, set for
        // Paula's four interrupts through exec; and ADKCON cleared as the module does.
        let patch0 = a.placed()
        a.w(0x23C8)
        a.long(a.addressOf(structure) + 18) // MOVE.L A0,StructInt+IS_CODE
        a.w(0x6100)
        a.displacement(to: setAudioVector) // BSR.W SetAudioVector
        a.w(0x3D7C, 0x00FF, 0x009E, 0x4E75) // MOVE.W #$FF,$9E(A6); RTS
        patches.add([0x21C8, 0x0070, 0x3D7C, 0x00FF, 0x009E], patch: patch0) // MOVE.L A0,$70.W; MOVE.W #$FF,$9E(A6)
        // $B14, $B1A: a voice's sample and length, as they are, and told the scopes.
        let patch1 = a.placed()
        a.w(0x24D0, 0x6100) // MOVE.L (A0),(A2)+; BSR.W SetAdr
        a.displacement(to: setAdr)
        a.w(0x34A8, 0x0004, 0x6100) // MOVE.W 4(A0),(A2); BSR.W SetLen
        a.displacement(to: setLen)
        a.w(0x4E75)
        patches.add([0x24D0, 0x34A8, 0x0004], patch: patch1)
        // $B2A, $B30: a voice's period, as it is, and told the scopes.
        let patch2 = a.placed()
        a.w(0x3368, 0x0006, 0x0006, 0x6100) // MOVE.W 6(A0),6(A1); BSR.W SetPer
        a.displacement(to: setPer)
        a.w(0x4E75)
        patches.add([0x3368, 0x0006, 0x0006], patch: patch2)
        // $B3C, $B44: a voice's volume through `ChangeVolume`, and told the scopes.
        let patch3 = a.placed()
        a.w(0x6100)
        a.displacement(to: changeVolume) // BSR.W ChangeVolume
        a.w(0x6100)
        a.displacement(to: setVol) // BSR.W SetVol
        a.w(0x3340, 0x0008, 0x2268, 0x0012, 0x4E75) // MOVE.W D0,8(A1); MOVEA.L 18(A0),A1; RTS
        patches.add([0x3340, 0x0008, 0x2268, 0x0012], patch: patch3)
        // $B56 to $BF4: a voice's volume from the module's tick, from its master volume (for a module whose
        // volumes are of sixteen steps, times four), through `ChangeVolume`; and its period and volume told
        // the scopes, from the voice's record.
        for v in 0 ..< 4 {
            let patch = a.placed(), plain = a.label()
            a.w(0x207A)
            a.displacement(to: structs[v]) // MOVEA.L StructN(PC),A0
            a.w(0x6100)
            a.displacement(to: perOf[v]) // BSR.W SetPerN
            a.w(0xEC48, 0x4A79) // LSR.W #6,D0; TST.W VolumeFlag
            a.address(of: volumeFlag)
            a.branch(0x6700, to: plain) // BEQ.S
            a.w(0xE548) // LSL.W #2,D0
            a.place(plain)
            a.w(0x6100)
            a.displacement(to: volumeOf[v]) // BSR.W the volume
            a.w(0x6100)
            a.displacement(to: volOf[v]) // BSR.W SetVolN
            a.w(0x3D40, 0x00A8 + UInt16(v * 16), 0x4E75) // MOVE.W D0,$Ax8(A6); RTS
            patches.add([0xEC48, 0x3D40, 0x00A8 + UInt16(v * 16)], patch: patch) // LSR.W #6,D0; MOVE.W D0,$Ax8(A6)
        }
        // $BF6, $BFC: the next pattern read from a voice's list (its record at A0, its place in the list at
        // 14, its registers' base at 10), the patterns of the voice `InitSound` chose counted; and at the
        // end of a voice's list (a word of nought), the voice cleared from those still in their lists, and
        // once none is, the song's end said (and every time after, as the voices go on). (The player's
        // MOVE.L -(A1),(A1), which is meant to give the voices back those the song began with, writes the
        // long it reads where it read it.)
        let patch8 = a.placed()
        let counted = a.label(), notEnd = a.label(), cleared = a.label(), going = a.label()
        a.w(0x2268, 0x000E) // MOVEA.L 14(A0),A1
        a.w(0x0CA8, 0x00DF) // CMPI.L #$DFF0D0,10(A0)
        a.place(lc04)
        a.w(0xF0D0, 0x000A)
        a.branch(0x6600, to: counted) // BNE.S
        a.w(0x5279)
        a.address(of: position) // ADDQ.W #1,Position
        a.place(counted)
        a.w(0x4A51) // TST.W (A1)
        a.branch(0x6600, to: notEnd) // BNE.S
        a.w(0x48E7, 0x0044, 0x43FA) // MOVEM.L A1/A5,-(A7); LEA Flags(PC),A1
        a.displacement(to: flags)
        for v in 0 ..< 4 {
            let other = a.label()
            a.w(0x0CA8, 0x00DF, 0xF0A0 + UInt16(v * 16), 0x000A) // CMPI.L #$DFF0x0,10(A0)
            a.branch(0x6600, to: v < 3 ? other : cleared) // BNE.S
            if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
            if v < 3 {
                a.branch(0x6000, to: cleared) // BRA.S
                a.place(other)
            }
        }
        a.place(cleared)
        a.w(0x4A99) // TST.L (A1)+
        a.branch(0x6600, to: going) // BNE.S
        a.w(0x22A1, 0x5089, 0x4251, 0x2A7A) // MOVE.L -(A1),(A1); ADDQ.L #8,A1; CLR.W (A1); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(going)
        a.w(0x4CDF, 0x2200) // MOVEM.L (A7)+,A1/A5
        a.place(notEnd)
        a.w(0x3019, 0x4E75) // MOVE.W (A1)+,D0; RTS
        patches.add([0x2268, 0x000E, 0x3019], patch: patch8)
        // $C74, $C7A: the old vector, which the module would keep, not kept.
        let patch9 = a.placed()
        a.w(0x4E75)
        patches.add([0x2B78, 0x0070, 0x000A], patch: patch9) // MOVE.L $70.W,10(A5)
        // Paula's interrupts' vector until the module's first tick has set its handler (see `initSound`).
        holdAt = a.here
        a.w(0x33FC, 0x0780, 0x00DF, 0xF09A, 0x4E73) // MOVE.W #$780,$DFF09A; RTE
        patches.assemble(&a)
        modulePtr = a.addressOf(module)
        samplesPtr = a.addressOf(samples)
        songTablePtr = a.addressOf(songTable)
        voicesLessPtr = a.addressOf(voicesLess)
        volumeFlagPtr = a.addressOf(volumeFlag)
        structsPtr = a.addressOf(structs[0])
        samplesEndPtr = a.addressOf(samplesEnd)
        initSoundAt = a.addressOf(initSound)
    }

    /// `InitPlayer` ($6EE), for the first kind: the module's routines and tables found by searching its
    /// code, its songs counted, and its code patched. (The player's searches run on until they find what
    /// they look for; here a module in which one goes past the module's end, or back past its start, is
    /// refused.)
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let (module, size) = try Desire.listData(&host)
        func refuse() -> TuneError { .malformed("a module of Sound Images' whose code is not as the player looks for") }
        let end = module &+ size
        func word(_ at: UInt32) -> UInt16 { host.machine.peek16(at) }
        func long(_ at: UInt32) -> UInt32 { host.machine.peek32(at) }
        func relative(_ at: UInt32) -> UInt32 { at &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(at)))) }
        func seek(_ at: inout UInt32, until found: (UInt32) -> Bool) throws(TuneError) {
            while !found(at) {
                at &+= 2
                guard at >= module, at &+ 4 <= end else { throw refuse() }
            }
        }
        guard let kind = Self.kind({ $0 >= 0 && UInt32($0) + 4 <= size ? long(module &+ UInt32($0)) : 0 }) else {
            throw refuse()
        }
        guard kind == 1 else {
            throw .unsupported("the second kind of Sound Images' modules, \"Sound Images 2\", none of which siday has to play it by")
        }
        host.machine.poke32(modulePtr, module)
        // The module's routine for a tick, where its first BRA goes; in it, up to its first BSR.W, whether
        // it writes voice 3's volume from D0 (`MOVE.W D0,$D8(A6)`: its volumes are of sixteen steps).
        var a1 = relative(module + 2)
        var volumeFlag = false
        try seek(&a1) { at in
            if long(at) == 0x3D40_00D8 { volumeFlag = true }
            return word(at) == 0x6100
        }
        if volumeFlag { host.machine.poke8(volumeFlagPtr, 0xFF) }
        // The routine it calls (the next BSR.W, if that one goes further than $900): the one that starts
        // a song.
        a1 += 2
        if Int16(bitPattern: word(a1)) > 0x900 { a1 += 4 }
        var a3 = a1
        a1 = relative(a1)
        // The samples' table: where the LEA x(PC) four bytes after the first `SUBQ.B #1,d16(A5)` from
        // there points; and where the samples end, the furthest of each sample's offset and its length in
        // words and two, by the records of twelve bytes before the table (each the offset, a word, and the
        // length), back to the code before them (`$3152` and a BRA.W).
        try seek(&a3) { word($0) == 0x532D }
        a3 = relative(a3 + 6)
        let samples = a3
        var p = samples &- 6
        var samplesEnd: UInt32 = 0
        while word(p &+ 2) != 0x6000 || word(p &- 2) != 0x3152 {
            let sampleEnd = (UInt32(word(p &- 2) &+ 2) << 1) &+ long(p &- 6)
            if Int32(bitPattern: sampleEnd) > Int32(bitPattern: samplesEnd) { samplesEnd = sampleEnd }
            p &-= 12
            guard p >= module &+ 6, p < end else { throw refuse() }
        }
        host.machine.poke32(samplesPtr, p &+ 6)
        host.machine.poke32(samplesEndPtr, samplesEnd)
        // The songs: the number the start compares the song's with (its `CMP.B #n,D0`), and the songs'
        // table, where the LEA x(PC) (or x(PC,Xn)) after it points, each song's record its voices' lists'
        // offsets (four if the instruction two words before the LEA is of ten, MULU #10, otherwise three)
        // and a word more.
        try seek(&a1) { word($0) == 0xB03C }
        a1 += 2
        var songs = UInt32(word(a1))
        a3 = a1
        try seek(&a3) { word($0) == 0x43FB || word($0) == 0x43FA }
        a3 += 2
        let voicesLess: UInt32 = word(a3 &- 4) == 0x000A ? 3 : 2
        a3 = relative(a3)
        host.machine.poke32(songTablePtr, a3)
        host.machine.poke16(voicesLessPtr, UInt16(voicesLess))
        // How many records there are room for before the first of the lists the records point at (in
        // records of the voices' offsets and a word, or, in the module whose samples end at $F186, of one
        // word fewer): if not as many as the start takes, there are that many songs, and the start is
        // made to take them ("hidden subsongs", as the player calls them). (The remainder of the division
        // is kept in the count's upper word, as the player keeps it; EaglePlayer takes the lower.)
        var nearest = UInt32(word(a3))
        for _ in 0 ... (songs &- 1) & 0xFFFF {
            for _ in 0 ... voicesLess {
                let offset = UInt32(word(a3))
                a3 &+= 2
                if offset != 0, offset <= nearest { nearest = offset }
            }
            a3 &+= 2
        }
        let record = (voicesLess + 2 - (samplesEnd == 0xF186 ? 1 : 0)) << 1
        let fit = (nearest % record) << 16 | nearest / record
        songs &-= 1
        if fit != songs {
            songs = fit
            host.machine.poke16(a1, UInt16(truncatingIfNeeded: fit &+ 1))
        }
        // The voices' records: for each voice, the first place from the samples' table that holds its
        // registers' base ($DFF0A0 and on), ten bytes into its record.
        var a4 = samples
        for v in 0 ... voicesLess {
            try seek(&a4) { long($0) == 0xDFF0A0 + v * 16 }
            host.machine.poke32(structsPtr + v * 4, a4 &- 10)
        }
        // The module's audio interrupt, its first RTE, made an RTS ($902), as it is called as a routine.
        var rte = module
        try seek(&rte) { word($0) == 0x4E73 }
        host.machine.poke16(rte, 0x4E75)
        // `ModuleChange` ($266): the patches made in the 2,650 bytes from the module's start.
        patches.apply(&host, from: module, length: 0xA5A)
        // `DTP_SubSongRange` ($6E2): from one to the count (one if it is nought).
        let last = songs == 0 ? 1 : Int(Int16(truncatingIfNeeded: songs))
        return WantedTeamSongs(first: 1, count: max(1, last))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    /// `InitSound`; and Paula's interrupts held back until the module has set its handler. A module's
    /// variables may ask, as it was saved, for its voices' DMA and their interrupts as its first tick
    /// begins, before the song it starts in that tick sets its handler through the player's patch. The
    /// voices then ask for their interrupts at the next line of the screen; if that comes before the
    /// song's start turns them off again, score's vector, its handler of exceptions, stops everything (as
    /// it does in UADE for four songs of Super Monaco GP's music and four of the Turtles'); if after, they
    /// wait, and the handler takes them once it is set. Which it is, is a matter of a few instructions'
    /// time and of the timer's phase against the beam. Here they always wait: until the handler is set,
    /// the vector turns them off and leaves them asked for.
    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        host.machine.poke32(0x70, holdAt)
        try host.initSound(initSoundAt)
    }
}
