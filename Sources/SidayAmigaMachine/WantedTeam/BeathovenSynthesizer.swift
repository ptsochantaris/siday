// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for the Beathoven Synthesizer ("Beathoven Synthesizer 1.00-1.20+
// player module V1.0 (3 June 2001)", UADE's players/BeathovenSynthesizer), whose source is not given:
// what it does is read from its code, and the addresses given are of its first hunk in UADE's file.

import SidayFoundation

/// Thomas Lopatic's Beathoven Synthesizer (of 1987 to 1991, as the player's credit has it), whose music
/// is that of The Great Giana Sisters, Katakis, Denaris, Zoom and other games (in UnExoticA's collection
/// under his name and Oliver Becker's), as Wanted Team adapted it: each module is the synthesizer's 68000
/// code that plays it, with its music and samples, in one hunk whose code begins `MOVEQ #-1,D0; RTS` and
/// "BEATHOVEN100", "BEATHOVEN109" or "BEATHOVENNEW", followed by longs: the addresses of its routines for
/// a tick, to start a song and to stop, its number of songs, the address of a routine to be run once as
/// it is loaded, its samples' table and its end, and, at the fifteenth, either the speed of its ticks
/// (CIA-A's timer) or the base its samples' addresses are given from.
///
/// As the player plays it: each of the module's waits for the DMA (busy loops of its own) made eight
/// lines of the beam; its every voice's volume written through the player's (for the balance, which is
/// none); in the code of 1.09 and NEW, a voice's length written as a word where the module writes a long
/// (which would write its period as well); two modules mended as they are loaded, as the player knows
/// them by the eleventh long of their header; and the end of each voice's music, where its list goes back
/// to its start, counted, and the song's end said once every voice the song uses has come to it.
typealias BeathovenSynthesizerPlayer = WantedTeamPlayer<BeathovenSynthesizer>

struct BeathovenSynthesizer: WantedTeamRecipe {
    static let format = "Beathoven Synthesizer"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -21.1 dB.)
    static let gain: Float = 0.32

    /// `Check3` ($4CE): the file an AmigaDOS program, its first hunk for chip memory, its code
    /// `MOVEQ #-1,D0; RTS`, "BEATHOVEN100", "BEATHOVENNEW" or "BEATHOVEN109", and its routines for a
    /// tick and a song's start, and its number of songs, not nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 60, WantedTeamHeader.long(data, 0) == 0x3F3, data[20] != 0,
              WantedTeamHeader.long(data, 32) == 0x70FF_4E75, WantedTeamHeader.long(data, 36) == 0x4245_4154,
              WantedTeamHeader.long(data, 40) == 0x484F_5645,
              [0x4E31_3030, 0x4E4E_4557, 0x4E31_3039].contains(WantedTeamHeader.long(data, 44))
        else { return false }
        return (0 ..< 3).allSatisfy { WantedTeamHeader.long(data, 48 + $0 * 4) != 0 }
    }

    let title = ""
    let author = ""
    private(set) var detail = ""

    /// Where UADE's player has its second hunk, of four bytes of nought, which the voices are pointed at
    /// as a song starts: past its first, as UADE relocates them (`AmigaHunks.Placement.uade`).
    private static let silence: UInt32 = 0xD9B8

    private var playPtr: UInt32 = 0, initSongPtr: UInt32 = 0, endSongPtr: UInt32 = 0, samplesAt: UInt32 = 0
    private var versionAt: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    /// The patches of the module's code of 1.09 and NEW (`PatchTable1`, $89E), and of 1.00
    /// (`PatchTable2`, $8BE).
    private var patches = WantedTeamPatches(), oldPatches = WantedTeamPatches()

    var interrupt: UInt32? { tick }
    /// Whether the module's own code sets the frame's interrupt going for its tick (`MOVE.L #handler,$6C`,
    /// as Final Mission's does, at $CE of its hunk): its game played it from the frame.
    private(set) var ticksOnFrame = false

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($16E to $206): the module's routines for a tick, a song's start and its stop, the
        // fifteenth long of its header, the globals' address, its version (nought for 1.00), the voices'
        // ends as they begin and as they are (four bytes each), the longest voice's list and its pointer
        // (for EaglePlayer's position), the sides' volumes, the voices' muting and their kept volumes, the
        // scopes.
        let play = a.variable(long: 0), initSong = a.variable(long: 0), endSong = a.variable(long: 0)
        let samples = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let version = a.variable(word: 0)
        let startEnds = a.variable(long: 0), ends = a.variable(long: 0)
        let position = a.variable(long: 0)
        _ = a.variable(long: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 1) }
        let oldVoices = (0 ..< 4).map { _ in a.variable(word: 0) }
        let scopes = a.scopes()
        // EaglePlayer's `InfoBuffer` ($530), whose longs at 76 (the song's length) and 84 (its voices) the
        // start of a song writes.
        let info = a.placed()
        for _ in 0 ..< 44 { a.w(0) }
        // `SetVolume` ($2E2, DTP_Volume): the sides' volumes from DeliTracker's, and each voice's kept
        // volume written again through `ChangeVolume`.
        let changeVolume = a.label(), setNew = a.label()
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x45FA)
        a.displacement(to: oldVoices[0]) // LEA OldVoice1(PC),A2
        a.w(0x7203, 0x47F9, 0x00DF, 0xF0A0) // MOVEQ #3,D1; LEA $DFF0A0,A3
        a.place(setNew)
        a.w(0x301A) // MOVE.W (A2)+,D0
        a.branch(0x6100, to: changeVolume) // BSR.B ChangeVolume
        a.w(0x508B, 0x508B, 0x51C9) // ADDQ.L #8,A3; ADDQ.L #8,A3; DBF D1,SetNew
        a.displacement(to: setNew)
        a.w(0x4E75)
        // `ChangeVolume` ($31C): the volume in D0, seven bits, kept as the voice's (A3 its registers, $DFF0A0
        // on), nought if it is muted, turned down by its side's balance, and written, and told the scopes
        // (A4).
        a.place(changeVolume)
        let done = a.label()
        let sides = [leftVolume, rightVolume, rightVolume, leftVolume]
        a.w(0x2F0C, 0x49FA) // MOVE.L A4,-(A7); LEA StructAdr(PC),A4
        a.displacement(to: scopes[0])
        a.w(0x0240, 0x007F) // ANDI.W #$7F,D0
        for v in 0 ..< 4 {
            let next = a.label(), on = a.label()
            a.w(0xB7FC, 0x00DF, 0xF0A0 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A3
            a.branch(0x6600, to: v < 3 ? next : done) // BNE.B
            a.w(0x33C0)
            a.address(of: oldVoices[v]) // MOVE.W D0,OldVoice
            a.w(0x4A79)
            a.address(of: voices[v]) // TST.W Voice
            a.branch(0x6600, to: on) // BNE.B
            a.w(0x7000) // MOVEQ #0,D0
            a.place(on)
            a.w(0xC0FA)
            a.displacement(to: sides[v]) // MULU.W side(PC),D0
            a.w(0xEC48, 0x3740, 0x0008, 0x3940, UInt16(8 + v * 18)) // LSR.W #6,D0; MOVE.W D0,8(A3); MOVE.W D0,UPS_VoiceNVol(A4)
            if v < 3 {
                a.branch(0x6000, to: done) // BRA.B
                a.place(next)
            }
        }
        a.place(done)
        a.w(0x285F, 0x4E75) // MOVEA.L (A7)+,A4; RTS
        // `SetTwo` ($3C8): the scopes told the length, the address (past the fifteenth long, if that is
        // where the samples are) and the period of the sample A2 points at (A0 the voice, A3 its registers).
        let setTwo = a.placed(), setVoice = a.label(), noBase = a.label()
        a.w(0x48E7, 0x0048) // MOVEM.L A1/A4,-(A7)
        for v in 0 ..< 4 {
            a.w(0x43FA)
            a.displacement(to: scopes[v * 9]) // LEA StructAdr+UPS_VoiceNAdr(PC),A1
            if v < 3 {
                a.w(0xB7FC, 0x00DF, 0xF0A0 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A3
                a.branch(0x6700, to: setVoice) // BEQ.S
            }
        }
        a.place(setVoice)
        a.w(0x302A, 0x0002, 0xE248, 0x3340, 0x0004) // MOVE.W 2(A2),D0; LSR.W #1,D0; MOVE.W D0,4(A1)
        a.w(0x202A, 0x0008, 0x49FA) // MOVE.L 8(A2),D0; LEA Samples(PC),A4
        a.displacement(to: samples)
        a.w(0x4A54) // TST.W (A4)
        a.branch(0x6700, to: noBase) // BEQ.S
        a.w(0xD0BA)
        a.displacement(to: samples) // ADD.L Samples(PC),D0
        a.place(noBase)
        a.w(0x2280, 0x3368, 0x001A, 0x0006) // MOVE.L D0,(A1); MOVE.W 26(A0),6(A1)
        a.w(0x4CDF, 0x1200, 0x4E75) // MOVEM.L (A7)+,A1/A4; RTS
        // `SetLen` ($41C): the scopes told what the code of 1.00 writes, the length in D1, the address and
        // the period of the sample A1 points at (A6 the voice's registers).
        let setLen = a.scopeRoutine(scopes, base: 6, field: 0, voicesAt: 0xDFF0A0,
                                    body: [0x3141, 0x0004, 0x20A9, 0x0022, 0x3169, 0x002A, 0x0006])
        // `Interrupt` ($59C, DTP_Interrupt), and `DMAWait` ($5D4).
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 4)
        let dmaWait = a.dmaWait(lines: 8)
        // `SongEnd1` and `SongEnd2` ($5F2, $646): a voice's list gone back to its start, the voice known by
        // its registers' address (at (A0), for 1.09 and later) or its DMA's bit (at 32(A0), for 1.00); its
        // byte of `Ends` cleared, and once all four are, the song's end said and the count begun again.
        func songEnd(_ a: inout AmigaAssembly, byBit: Bool) -> Int {
            let routine = a.placed(), count = a.label(), notYet = a.label()
            a.w(0x48E7, byBit ? 0x8044 : 0x0044, 0x43FA) // MOVEM.L (D0/)A1/A5,-(A7); LEA Ends(PC),A1
            a.displacement(to: ends)
            if byBit { a.w(0x7001) } // MOVEQ #1,D0
            for v in 0 ..< 4 {
                let next = a.label()
                if byBit {
                    if v > 0 { a.w(0xE388) } // LSL.L #1,D0
                    a.w(0xB0A8, 0x0020) // CMP.L 32(A0),D0
                } else {
                    a.w(0x0C90, 0x00DF, 0xF0A0 + UInt16(v * 16)) // CMPI.L #$DFF0x0,(A0)
                }
                a.branch(0x6600, to: v < 3 ? next : count) // BNE.B
                if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
                if v < 3 {
                    a.branch(0x6000, to: count) // BRA.B
                    a.place(next)
                }
            }
            a.place(count)
            a.w(0x4A91) // TST.L (A1)
            a.branch(0x6600, to: notYet) // BNE.B
            a.w(0x22BA)
            a.displacement(to: startEnds) // MOVE.L StartEnds(PC),(A1)
            a.w(0x2A7A)
            a.displacement(to: eagleBase) // MOVEA.L EagleBase(PC),A5
            a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
            a.place(notYet)
            a.w(0x4CDF, byBit ? 0x2201 : 0x2200, 0x4E75) // MOVEM.L (A7)+,(D0/)A1/A5; RTS
            return routine
        }
        let songEnd1 = songEnd(&a, byBit: false)
        let songEnd2 = songEnd(&a, byBit: true)
        // `InitSound` ($77C, DTP_InitSound): the scopes cleared; every voice pointed at the player's word of
        // silence, a word long, its period one; the module's speed made `dtg_Timer`, if its fifteenth long
        // is one; the song started with its number in D0; and then, from what the module's start leaves in
        // A0, the voices the song uses (all four, unless the module's stop turns three off, or its fourth
        // voice's list is empty) made those whose ends are waited for, and the longest list found, for
        // EaglePlayer.
        initSoundAt = a.here
        a.clearScopes(scopes)
        a.w(0x41F9, 0x00DF, 0xF000) // LEA $DFF000,A0
        a.w(0x43F9)
        a.long(Self.silence) // LEA Silence,A1
        for v in 0 ..< 4 { a.w(0x2149, 0x00A0 + UInt16(v * 16)) } // MOVE.L A1,$Ax0(A0)
        a.w(0x203C, 0x0001, 0x0001) // MOVE.L #$10001,D0
        for v in 0 ..< 4 { a.w(0x2140, 0x00A4 + UInt16(v * 16)) } // MOVE.L D0,$Ax4(A0)
        let noTimer = a.label()
        a.w(0x49FA)
        a.displacement(to: samples) // LEA Samples(PC),A4
        a.w(0x4A54) // TST.W (A4)
        a.branch(0x6600, to: noTimer) // BNE.B
        a.w(0x203A)
        a.displacement(to: samples) // MOVE.L Samples(PC),D0
        a.branch(0x6700, to: noTimer) // BEQ.B
        a.w(0x3B40, UInt16(DeliTrackerHost.dtgTimer)) // MOVE.W D0,dtg_Timer(A5)
        a.place(noTimer)
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x207A) // MOVE.W dtg_SndNum(A5),D0; MOVEA.L InitSongPtr(PC),A0
        a.displacement(to: initSong)
        a.w(0x4E90, 0x2868, 0x0004, 0x3A3A) // JSR (A0); MOVEA.L 4(A0),A4; MOVE.W Version(PC),D5
        a.displacement(to: version)
        let new = a.label(), scan = a.label(), checkFourth = a.label(), three = a.label(), set = a.label()
        a.branch(0x6600, to: new) // BNE.B
        a.w(0x2868, 0x000A) // MOVEA.L 10(A0),A4
        a.place(new)
        a.w(0x2C3C, 0x5754, 0x5754, 0x7E04, 0x45FA) // MOVE.L #'WTWT',D6; MOVEQ #4,D7; LEA InfoBuffer(PC),A2
        a.displacement(to: info)
        a.w(0x203A)
        a.displacement(to: endSong) // MOVE.L EndSongPtr(PC),D0
        a.branch(0x6700, to: checkFourth) // BEQ.B
        a.w(0x2240) // MOVEA.L D0,A1
        a.place(scan)
        a.w(0x0C51, 0x4E75) // CMPI.W #$4E75,(A1)
        a.branch(0x6700, to: checkFourth) // BEQ.B
        a.w(0x0C59, 0x0007) // CMPI.W #7,(A1)+
        a.branch(0x6600, to: scan) // BNE.B
        a.branch(0x6000, to: three) // BRA.B
        a.place(checkFourth)
        a.w(0x4A94) // TST.L (A4)
        a.branch(0x6600, to: set) // BNE.B
        a.place(three)
        a.w(0x5387, 0x4206) // SUBQ.L #1,D7; CLR.B D6
        a.place(set)
        a.w(0x47FA)
        a.displacement(to: startEnds) // LEA StartEnds(PC),A3
        a.w(0x26C6, 0x2686, 0x2547, 0x0054) // MOVE.L D6,(A3)+; MOVE.L D6,(A3); MOVE.L D7,84(A2)
        a.w(0x7200, 0x7403, 0x263C, 0x00DF, 0xF0D0) // MOVEQ #0,D1; MOVEQ #3,D2; MOVE.L #$DFF0D0,D3
        let voice = a.label(), find = a.label(), found = a.label(), count = a.label(), counted = a.label()
        let notLonger = a.label(), keep = a.label()
        a.place(voice)
        a.w(0x4A45) // TST.W D5
        a.branch(0x6600, to: find) // BNE.B
        a.w(0x2868, 0x000A, 0x41E8, 0xFFC4) // MOVEA.L 10(A0),A4; LEA -60(A0),A0
        a.branch(0x6000, to: count) // BRA.B
        a.place(find)
        a.w(0xB690) // CMP.L (A0),D3
        a.branch(0x6700, to: found) // BEQ.B
        a.w(0x5588) // SUBQ.L #2,A0
        a.branch(0x6000, to: find) // BRA.B
        a.place(found)
        a.w(0x2868, 0x0004, 0x5183, 0x5183) // MOVEA.L 4(A0),A4; SUBQ.L #8,D3; SUBQ.L #8,D3
        a.place(count)
        a.w(0x280C, 0x7000) // MOVE.L A4,D4; MOVEQ #0,D0
        let next = a.placed()
        a.w(0x4A94) // TST.L (A4)
        a.branch(0x6700, to: counted) // BEQ.B
        a.w(0x5280, 0x508C) // ADDQ.L #1,D0; ADDQ.L #8,A4
        a.branch(0x6000, to: next) // BRA.B
        a.place(counted)
        a.w(0xB280) // CMP.L D0,D1
        a.branch(0x6C00, to: notLonger) // BGE.B
        a.w(0x2200, 0x47FA) // MOVE.L D0,D1; LEA Position(PC),A3
        a.displacement(to: position)
        a.w(0x26C4, 0x43E8, 0x0004, 0x4A45) // MOVE.L D4,(A3)+; LEA 4(A0),A1; TST.W D5
        a.branch(0x6600, to: keep) // BNE.B
        a.w(0x43E8, 0x0046) // LEA 70(A0),A1
        a.place(keep)
        a.w(0x2689) // MOVE.L A1,(A3)
        a.place(notLonger)
        a.w(0x51CA)
        a.displacement(to: voice) // DBF D2,voice
        a.w(0x2541, 0x004C, 0x4E75) // MOVE.L D1,76(A2); RTS
        // The patches, each with the module's code it is called in place of.
        // Code1, Patch1 ($8E4, $8EE; and Code7 to Code9 of 1.00, $946, $952, $95E): its waits for the DMA,
        // made `DMAWait`.
        let wait = a.placed()
        a.w(0x6100)
        a.displacement(to: dmaWait) // BSR.W DMAWait
        a.w(0x4E75)
        patches.add([0x4E71, 0x51C8, 0xFFFC], patch: wait) // NOP; DBF D0,*-2
        // Code2, Patch2 ($8F4, $8FA): MOVE.L 30(A0),4(A2) made MOVE.W.
        let length = a.placed()
        a.w(0x3568, 0x001E, 0x0004, 0x4E75) // MOVE.W 30(A0),4(A2); RTS
        patches.add([0x2568, 0x001E, 0x0004], patch: length)
        // Code3, Patch3 ($902, $908), and Code5, Patch5 ($92E, $934): a voice's volume, at (A2), written
        // through `ChangeVolume`.
        let volume = a.placed()
        a.w(0x2F00, 0x3012, 0x6100) // MOVE.L D0,-(A7); MOVE.W (A2),D0; BSR.W ChangeVolume
        a.displacement(to: changeVolume)
        a.w(0x6100)
        a.displacement(to: setTwo) // BSR.W SetTwo
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        patches.add([0x376A, 0x0000, 0x0008], patch: volume) // MOVE.W 0(A2),8(A3)
        // Code4, Patch4 ($918, $920): a voice's list gone back to its start.
        let loop = a.placed()
        a.w(0x2268, 0x0008, 0x2149, 0x0004, 0x6100) // MOVEA.L 8(A0),A1; MOVE.L A1,4(A0); BSR.W SongEnd1
        a.displacement(to: songEnd1)
        a.w(0x4E75)
        patches.add([0x2268, 0x0008, 0x2149, 0x0004], patch: loop)
        let volume2 = a.placed()
        a.w(0x2650, 0x2F00, 0x3012, 0x6100) // MOVEA.L (A0),A3; MOVE.L D0,-(A7); MOVE.W (A2),D0; BSR.W ChangeVolume
        a.displacement(to: changeVolume)
        a.w(0x6100)
        a.displacement(to: setTwo) // BSR.W SetTwo
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        patches.add([0x2650, 0x3752, 0x0008], patch: volume2) // MOVEA.L (A0),A3; MOVE.W (A2),8(A3)
        // 1.00's: its three waits (`CLR.W 10(A6)` or a NOP, and a DBF), a voice's volume (Code10, $968),
        // its sample (Code11, $982) and its list gone back to its start (Code12, $998).
        oldPatches.add([0x426E, 0x000A, 0x51C9, 0xFFFA], patch: wait)
        oldPatches.add([0x426E, 0x000A, 0x51C8, 0xFFFA], patch: wait)
        oldPatches.add([0x4E71, 0x51C8, 0xFFFC], patch: wait)
        let volume3 = a.placed()
        a.w(0x48E7, 0x8010, 0x264E, 0x3029, 0x002C, 0x6100) // MOVEM.L D0/A3,-(A7); MOVEA.L A6,A3; MOVE.W 44(A1),D0; BSR.W ChangeVolume
        a.displacement(to: changeVolume)
        a.w(0x4CDF, 0x0801, 0x4E75) // MOVEM.L (A7)+,D0/A3; RTS
        oldPatches.add([0x3D69, 0x002C, 0x0008], patch: volume3) // MOVE.W 44(A1),8(A6)
        let sample = a.placed()
        a.w(0x3D41, 0x0004, 0x2CA9, 0x0022, 0x6100) // MOVE.W D1,4(A6); MOVE.L 34(A1),(A6); BSR.W SetLen
        a.displacement(to: setLen)
        a.w(0x4E75)
        oldPatches.add([0x3D41, 0x0004, 0x2CA9, 0x0022], patch: sample)
        let loop2 = a.placed()
        a.w(0x2168, 0x000E, 0x000A, 0x6100) // MOVE.L 14(A0),10(A0); BSR.W SongEnd2
        a.displacement(to: songEnd2)
        a.w(0x4E75)
        oldPatches.add([0x2168, 0x000E, 0x000A], patch: loop2)
        patches.assemble(&a)
        oldPatches.assemble(&a)
        playPtr = a.addressOf(play)
        initSongPtr = a.addressOf(initSong)
        endSongPtr = a.addressOf(endSong)
        samplesAt = a.addressOf(samples)
        versionAt = a.addressOf(version)
        tick = a.addressOf(tickRoutine)
    }

    /// `InitPlayer` ($6A4).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let module = try WantedTeamHeader.load(&host)
        // ($6C2) The ID's last two letters: odd ("09", "EW") for 1.09 and NEW.
        let new = host.machine.peek16(module + 14) & 1 != 0
        let h = WantedTeamHeader.longs(host, module: module + 4, count: 15)
        host.machine.poke32(playPtr, h[0])
        host.machine.poke32(initSongPtr, h[1])
        host.machine.poke32(endSongPtr, h[3])
        host.machine.poke32(samplesAt, h[14])
        host.machine.poke16(versionAt, new ? host.machine.peek16(module + 14) : 0)
        // (Its version, as its ID gives it: "100", "109" or "NEW".)
        let id = host.machine.peek32(module + 12)
        detail = "Beathoven Synthesizer " + (id == 0x4E4E_4557 ? "NEW" : id == 0x4E31_3030 ? "1.00" : "1.09")
        // ($718 to $74C) Two modules mended, known by their header's eleventh long: one with a word of its
        // code changed, the other with 104 bytes of it cleared.
        if h[10] == 0x915C {
            host.machine.poke16(module &+ 0x910A, 0x33A4)
        } else if h[10] == 0x3_F4DE {
            for i in 0 ..< 26 { host.machine.poke32(module &+ 0x3_5D52 &+ UInt32(i * 4), 0) }
        }
        ticksOnFrame = stride(from: UInt32(0), to: 0x400, by: 2).contains {
            host.machine.peek16(module &+ $0) == 0x23FC && host.machine.peek32(module &+ $0 &+ 6) == 0x6C
        }
        // ($74E) The module's routine to be run as it is loaded, if it has one.
        if h[4] != 0 { _ = try host.call(h[4]) }
        // `ModuleChange` ($28E): the patches made in the 1,200 bytes from the routine for a tick; for 1.00,
        // in the 1,600 from 800 bytes before it.
        if new {
            patches.apply(&host, from: h[0], length: 1200)
        } else {
            oldPatches.apply(&host, from: h[0] &- 800, length: 1600)
        }
        return WantedTeamSongs(first: 0, count: Int(min(h[2], 256)))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
