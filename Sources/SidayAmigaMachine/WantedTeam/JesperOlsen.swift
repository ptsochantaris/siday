// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Jesper Olsen's music ("Jesper Olsen player module V1.0 (23 Nov
// 2007)", UADE's players/JesperOlsen), whose source is UADE's amigasrc/players/wanted_team/Jesper_Olsen/
// "Jesper Olsen_v1.asm": its lines are given.

import SidayFoundation
import SidayM68000

/// Jesper Olsen's music for the Amiga (of 1990 to 1995, as the player's credit has it), as his games had
/// it. The player knows three kinds of module (`Check2`, lines 462-555), of which siday plays two:
///
/// - the first (Guldkorn Expressen and Kalas Puffs Expressen, the same game twice): his 68000 code that
///   plays it, with its music and samples, beginning with four BRA.Ws, to stop, to start a song (with its
///   number, from nought, in D0), for a tick, and a fourth; its songs a table of entries, each a word for
///   each voice (nought for a voice it does not use) and more, whose size is the MULU of the routine that
///   starts a song;
/// - the third (Georg Glaxo and Lollypop): music and samples only, a table of the songs' places first,
///   played by the game's own code, which UnExoticA keeps beside them in a file of its own,
///   `WantedTeam.bin` (Wanted Team's name for it, which the player asks for, `ExtLoad`, lines 213-233), one
///   for each game, as the game had it: commands in D0 (`$1000` its music at A0, `$4000` and a song's
///   number to start it, nought for a tick), its music's address kept in its own memory.
///
/// The second kind (none known to siday) is refused.
///
/// As the player plays them: fifty ticks a second; the module's writes of its voices' samples, lengths,
/// periods and volumes told to EaglePlayer's scopes (and the volumes turned down by the balance, which is
/// none), and for the third kind the game's code's wait for the beam made eight lines of it; and a song's
/// end said when every voice it starts with has come to the end of its list of patterns, where the list
/// goes back to a place in it or stops (`SongEndTest`, lines 632-663), the voices then counted afresh.
/// For the first kind, siday waits only for the voices that have been heard (a volume above nought
/// written to them): the Expressen's songs for the game's levels leave two of the four voices to its
/// sound effects, and would otherwise never end (as in UADE they never do); two of its effects so end
/// with their sound, before a voice that is never heard comes to its stop.
typealias JesperOlsenPlayer = WantedTeamPlayer<JesperOlsen>

struct JesperOlsen: WantedTeamRecipe {
    static let format = "Jesper Olsen"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -22.5 dB.)
    static let gain: Float = 0.38

    /// The player's kinds of module (its `Format`: 0, 1 and -1), and for the first, the size of its songs'
    /// entries (`Mulu`).
    enum Kind: Equatable {
        case code(mulu: UInt16)
        case second
        case data
    }

    /// `Check2` (lines 462-555), of the module whose longs (by their offset, nought past its end) `long`
    /// gives. The first and second kinds: the first three longs BRA.Ws forward (an even distance, not
    /// nought); where the second goes, for the second kind `TST.W D0; BMI.W` and a `LEA x(PC)` whose place
    /// holds `$00017FFF` four bytes on; for the first, a `MULU #n,D0`, there or after an `ANDI.L #$FF,D0`
    /// within its first sixteen words, and `$6AE064E0` from 800 to 1,700 bytes past it. The third: a table of
    /// two to 256 words, the first its size, each place it gives (from its second word, and the first after
    /// it) even, below 32 KB and just after a `$7FFF`.
    static func kind(_ long: (Int) -> UInt32) -> Kind? {
        func word(_ at: Int) -> UInt16 { UInt16(long(at) >> 16) }
        if word(0) == 0x6000 {
            for at in [0, 4, 8] {
                let distance = word(at + 2)
                guard word(at) == 0x6000, distance != 0, distance & 0x8001 == 0 else { return nil }
            }
            var at = 6 + Int(word(6))
            if long(at) == 0x4A40_6B00 {
                guard long(at + 4) == 0x0006_41FA else { return nil }
                at += 8
                at += Int(Int16(bitPattern: word(at)))
                return long(at + 4) == 0x0001_7FFF ? .second : nil
            }
            if word(at) == 0xC0FC {
                at += 2
            } else {
                guard let and = (0 ..< 16).first(where: { long(at + $0 * 2) == 0x0280_0000 }),
                      long(at + and * 2 + 4) == 0x00FF_C0FC else { return nil }
                at += and * 2 + 8
            }
            let mulu = word(at)
            return stride(from: at + 800, to: at + 1700, by: 2).contains { long($0) == 0x6AE0_64E0 } ? .code(mulu: mulu) : nil
        }
        let size = word(0)
        guard size >= 4, size <= 0x200, size & 1 == 0 else { return nil }
        for i in 0 ..< Int(size / 2) {
            let place = word(2 + i * 2)
            guard place != 0, place & 0x8001 == 0, word(Int(place) - 2) == 0x7FFF else { return nil }
        }
        return .data
    }

    static func kind(_ data: [UInt8]) -> Kind? { kind { WantedTeamHeader.long(data, $0) } }

    static func isOne(_ data: [UInt8]) -> Bool { kind(data) != nil }

    /// The name of the game's code that plays the third kind, which the player loads from beside the module.
    static let replayerName = "WantedTeam.bin"

    let title = ""
    let author = "Jesper Olsen"

    private var muluAt: UInt32 = 0, modulePtr: UInt32 = 0, currentFormat: UInt32 = 0, exPlayPtr: UInt32 = 0
    private var voicePtrTemp: UInt32 = 0, addFlag: UInt32 = 0, valueAt: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    /// Where the pattern and the patch of `CodeN` are given the module's place of a voice's list
    /// (`Value`, lines 776-777).
    private var codeNValue: UInt32 = 0, patchNValue: UInt32 = 0
    /// `PatchTable` (for the third kind) and `PatchTable2` (for the first).
    private var patches = WantedTeamPatches(), patches2 = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        func bsr(_ routine: Int) {
            a.w(0x6100)
            a.displacement(to: routine) // BSR.W
        }
        // The variables (lines 52-98), in the player's order where its code relies on it (`Songend` to
        // `AddValue`). (The module's kind is kept in a word's first byte here.)
        let mulu = a.variable(word: 0), module = a.variable(long: 0), format = a.variable(word: 0)
        let eagleBase = a.eagleBase()
        let exPlay = a.variable(long: 0), voicePtr = a.variable(long: 0)
        let add = a.variable(word: 0), value = a.variable(word: 0)
        let songEnd = a.variable(long: 0x5754_5754)
        _ = a.variable(long: 0) // SongendTemp
        _ = a.variable(long: 0) // VoicePtr
        _ = a.variable(word: 0) // FirstStep
        _ = a.variable(word: 0) // AddValue
        // (siday's: which voices have been heard, a byte each, `Songend` + 16.)
        let sounded = a.variable(long: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // `SetVolume` (lines 290-305, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `ChangeVolume` (lines 307-340): the volume in D0 (seven bits) turned down by its side's balance
        // and nought for a muted voice, and written to the voice whose registers A2 points at (if it is one).
        let changeVolume = a.placed()
        let left1 = a.label(), right1 = a.label(), right2 = a.label(), ex = a.label(), exit = a.label()
        a.w(0x2F02, 0x0240, 0x007F, 0x240A) // MOVE.L D2,-(A7); ANDI.W #$7F,D0; MOVE.L A2,D2
        for (low, to) in [(0xF0A0, left1), (0xF0B0, right1), (0xF0C0, right2)] {
            a.w(0xB47C, UInt16(low)) // CMP.W #low,D2
            a.branch(0x6700, to: to) // BEQ.S
        }
        a.w(0xB47C, 0xF0D0) // CMP.W #$F0D0,D2
        a.branch(0x6600, to: exit) // BNE.S Exit2
        for (place, side, voice) in [(nil, leftVolume, 3), (left1, leftVolume, 0), (right1, rightVolume, 1), (right2, rightVolume, 2)] {
            if let place { a.place(place) }
            a.w(0xC0FA)
            a.displacement(to: side) // MULU.W side(PC),D0
            a.w(0xC07A)
            a.displacement(to: voices[voice]) // AND.W VoiceN(PC),D0
            if voice != 2 { a.branch(0x6000, to: ex) } // BRA.S Ex
        }
        a.place(ex)
        a.w(0xEC48, 0x3540, 0x0008) // LSR.W #6,D0; MOVE.W D0,8(A2)
        // (siday's: a volume not nought marks the voice as heard.)
        a.w(0x4A40) // TST.W D0
        a.branch(0x6700, to: exit) // BEQ.S Exit2
        a.w(0x2F08, 0x41FA) // MOVE.L A0,-(A7); LEA Sounded(PC),A0
        a.displacement(to: sounded)
        a.w(0x0442, 0xF0A0, 0xE84A, 0x50F0, 0x2000, 0x205F) // SUBI.W #$F0A0,D2; LSR.W #4,D2; ST 0(A0,D2.W); MOVEA.L (A7)+,A0
        a.place(exit)
        a.w(0x241F, 0x4E75) // MOVE.L (A7)+,D2; RTS
        // `SetVol`, `SetAdr`, `SetLen`, `SetPer` (lines 344-416): the scopes told of the voice at A2.
        let setVol = a.scopeRoutine(scopes, base: 2, field: 4, body: [0x3080]) // MOVE.W D0,(A0)
        let setAdr = a.scopeRoutine(scopes, base: 2, field: 0, body: [0x2080]) // MOVE.L D0,(A0)
        let setLen = a.scopeRoutine(scopes, base: 2, field: 2, body: [0x3080])
        let setPer = a.scopeRoutine(scopes, base: 2, field: 3, body: [0x3080])
        // `Interrupt` (lines 594-620, DTP_Interrupt): the module's routine for a tick, its third BRA.W for
        // the first kind, or the game's code with D0 nought for the third.
        tick = a.here
        let playNew = a.label(), skipPlay = a.label()
        a.w(0x48E7, 0x7FFE, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(SP); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x50E8, 0x004C) // ST UPS_Enabled(A0)
        for v in 0 ..< 4 { a.w(0x4268, UInt16(6 + v * 18)) } // CLR.W UPS_VoiceNPer(A0)
        a.w(0x317C, 0x000F, 0x004A, 0x123A) // MOVE.W #UPSB_Adr!UPSB_Len!UPSB_Per!UPSB_Vol,UPS_Flags(A0); MOVE.B CurrentFormat(PC),D1
        a.displacement(to: format)
        a.branch(0x6B00, to: playNew) // BMI.B PlayNew
        a.w(0x207A)
        a.displacement(to: module) // MOVEA.L ModulePtr(PC),A0
        a.w(0x4EA8, 0x0008) // JSR 8(A0)
        a.branch(0x6000, to: skipPlay) // BRA.B SkipPlay
        a.place(playNew)
        a.w(0x7000, 0x207A) // MOVEQ #0,D0; MOVEA.L ExPlayPtr(PC),A0
        a.displacement(to: exPlay)
        a.w(0x4E90) // JSR (A0)
        a.place(skipPlay)
        a.endTick(scopes: scopes)
        // `DMAWait` (lines 622-630): eight lines of the beam.
        let dmaWait = a.dmaWait(lines: 8)
        // `SongEndTest` (lines 632-663): the voice at A2 come to its list's end; once all four have (the
        // long of their bytes nought), the song's end said and the voices that played set again.
        let songEndTest = a.placed()
        let test = a.label(), skipEnd = a.label()
        a.w(0x48E7, 0x0044, 0x43FA) // MOVEM.L A1/A5,-(A7); LEA Songend(PC),A1
        a.displacement(to: songEnd)
        for v in 0 ..< 4 {
            let next = a.label()
            let base = 0xDFF0A0 + UInt32(v * 16)
            a.w(0xB5FC, UInt16(base >> 16), UInt16(base & 0xFFFF)) // CMPA.L #$DFF0x0,A2
            a.branch(0x6600, to: v < 3 ? next : test) // BNE.B testN
            if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
            if v < 3 {
                a.branch(0x6000, to: test) // BRA.B test
                a.place(next)
            }
        }
        // (For the first kind, siday's: only the voices that have been heard are waited for.)
        a.place(test)
        let whole = a.label(), check = a.label()
        a.w(0x2F00, 0x103A) // MOVE.L D0,-(A7); MOVE.B CurrentFormat(PC),D0
        a.displacement(to: format)
        a.branch(0x6B00, to: whole) // BMI.S
        a.w(0x2019, 0xC0BA) // MOVE.L (A1)+,D0; AND.L Sounded(PC),D0
        a.displacement(to: sounded)
        a.branch(0x6000, to: check) // BRA.S
        a.place(whole)
        a.w(0x2019) // MOVE.L (A1)+,D0
        a.place(check)
        a.w(0x4A80, 0x4CDF, 0x0001) // TST.L D0; MOVEM.L (A7)+,D0
        a.branch(0x6600, to: skipEnd) // BNE.B SkipEnd
        a.w(0x2311, 0x2A7A) // MOVE.L (A1),-(A1); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(skipEnd)
        a.w(0x4CDF, 0x2200, 0x4E75) // MOVEM.L (A7)+,A1/A5; RTS
        // `InitSound` (lines 971-1054, DTP_InitSound): the scopes cleared, and the voices' ends and the
        // first voice's list (`VoicePtr`) forgotten. The first kind: the song's entry found, each voice it
        // does not use (its word nought) taken as at its end already, and the song started with its number
        // from nought in D0 (the second BRA.W). The third: the game's code given its music and then the song.
        // Then the voices that play kept, for `SongEndTest` to set again. (What it works out for
        // EaglePlayer's information alone, the song's length and its count of voices, is left out; the
        // second kind's start is left out with it.)
        initSoundAt = a.here
        let latex = a.label(), here = a.label(), addZero = a.label(), nextVoice = a.label(), voiceOn = a.label()
        a.clearScopes(scopes)
        a.w(0x41FA)
        a.displacement(to: songEnd) // LEA Songend(PC),A0
        a.w(0x4290, 0x42A8, 0x0008, 0x42A8, 0x0010, 0x207A) // CLR.L (A0); CLR.L 8(A0); CLR.L 16(A0) (siday's); MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x123A)
        a.displacement(to: format) // MOVE.B CurrentFormat(PC),D1
        a.branch(0x6B00, to: latex) // BMI.B Latex
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x5340, 0x3200, 0x43FA) // MOVE.W dtg_SndNum(A5),D0; SUBQ.W #1,D0; MOVE.W D0,D1; LEA Songend(PC),A1
        a.displacement(to: songEnd)
        a.w(0x22BC, 0x5754, 0x5754, 0x237A) // MOVE.L #"WTWT",(A1); MOVE.L VoicePtrTemp(PC),8(A1)
        a.displacement(to: voicePtr)
        a.w(0x0008, 0x247A) // MOVEA.L ExPlayPtr(PC),A2
        a.displacement(to: exPlay)
        a.w(0xC2FA)
        a.displacement(to: mulu) // MULU.W Mulu(PC),D1
        a.w(0xD4C1, 0x3352, 0x000C, 0x323A) // ADDA.W D1,A2; MOVE.W (A2),12(A1); MOVE.W AddFlag(PC),D1
        a.displacement(to: add)
        a.branch(0x6700, to: addZero) // BEQ.B AddZero
        a.w(0x323A)
        a.displacement(to: mulu) // MOVE.W Mulu(PC),D1
        a.w(0x3232, 0x10FE) // MOVE.W -2(A2,D1.W),D1
        a.place(addZero)
        a.w(0x3341, 0x000E, 0x7203) // MOVE.W D1,14(A1); MOVEQ #3,D1
        a.place(nextVoice)
        a.w(0x4A5A) // TST.W (A2)+
        a.branch(0x6600, to: voiceOn) // BNE.B VoiceOn3
        a.w(0x4211) // CLR.B (A1)
        a.place(voiceOn)
        a.w(0x5289, 0x51C9) // ADDQ.L #1,A1; DBF D1,NextVoice3
        a.displacement(to: nextVoice)
        a.w(0x4EA8, 0x0004) // JSR 4(A0)
        a.branch(0x6000, to: here) // BRA.B Here
        a.place(latex)
        a.w(0x7050, 0xE188, 0x227A) // MOVEQ #80,D0; LSL.L #8,D0; MOVEA.L ExPlayPtr(PC),A1
        a.displacement(to: exPlay)
        a.w(0x4E91, 0x7040, 0xE188, 0x2A7A) // JSR (A1); MOVEQ #64,D0; LSL.L #8,D0; MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x806D, UInt16(DeliTrackerHost.dtgSndNum), 0x227A) // OR.W dtg_SndNum(A5),D0; MOVEA.L ExPlayPtr(PC),A1
        a.displacement(to: exPlay)
        a.w(0x4E91) // JSR (A1)
        a.place(here)
        a.w(0x41FA)
        a.displacement(to: songEnd) // LEA Songend(PC),A0
        a.w(0x2098, 0x4E75) // MOVE.L (A0)+,(A0); RTS

        // The patches (lines 1070-1586). Those of the third kind's table first (`PatchTable`).
        // `Patch1`: a voice the game's code starts with a list to play (`$34(A1)` not nought) marked as
        // playing, the first such kept.
        let patch1 = a.placed()
        let voiceOff = a.label(), ptrSet = a.label()
        a.w(0x4A69, 0x0034) // TST.W $34(A1)
        a.branch(0x6700, to: voiceOff) // BEQ.B VoiceOff
        a.w(0x2F08, 0x41FA) // MOVE.L A0,-(SP); LEA Songend(PC),A0
        a.displacement(to: songEnd)
        a.w(0x50F0, 0x0000, 0x4AA8, 0x0008) // ST (A0,D0.W); TST.L 8(A0)
        a.branch(0x6600, to: ptrSet) // BNE.B PtrSet
        a.w(0x2149, 0x0008, 0x3169, 0x0034, 0x000C) // MOVE.L A1,8(A0); MOVE.W $34(A1),12(A0)
        a.place(ptrSet)
        a.w(0x205F) // MOVEA.L (SP)+,A0
        a.place(voiceOff)
        a.w(0xE169, 0x3341, 0x003A, 0x4E75) // LSL.W D0,D1; MOVE.W D1,$3A(A1); RTS
        patches.add([0xE169, 0x3341, 0x003A], patch: patch1)
        // `Patch2`: a voice's list stopped (its volume nought), the end of it.
        let patch2 = a.placed()
        a.w(0x357C, 0x0000, 0x0008, 0x2F00, 0x7000) // MOVE.W #0,8(A2); MOVE.L D0,-(SP); MOVEQ #0,D0
        bsr(setVol)
        a.w(0x201F) // MOVE.L (SP)+,D0
        bsr(songEndTest)
        a.w(0x4E75)
        patches.add([0x357C, 0x0000, 0x0008], patch: patch2)
        // `Patch3`: a voice's list gone back to a place in it, the end of it.
        let patch3 = a.placed()
        a.w(0x336C, 0x0002, 0x0034) // MOVE.W 2(A4),$34(A1)
        bsr(songEndTest)
        a.w(0x4E75)
        patches.add([0x336C, 0x0002, 0x0034], patch: patch3)
        // `Patch4`: a sample's address (of 24 bits) and length, told the scopes.
        let patch4 = a.placed()
        a.w(0x2F00, 0x200D, 0x0280, 0x00FF, 0xFFFF, 0x2480) // MOVE.L D0,-(A7); MOVE.L A5,D0; ANDI.L #$FFFFFF,D0; MOVE.L D0,(A2)
        bsr(setAdr)
        a.w(0x302B, 0x0012, 0x3540, 0x0004) // MOVE.W $12(A3),D0; MOVE.W D0,4(A2)
        bsr(setLen)
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        patches.add([0x248D, 0x356B, 0x0012, 0x0004], patch: patch4)
        // `Patch5`: a volume, through `ChangeVolume`.
        let patch5 = a.placed()
        a.w(0x2F00, 0x1034, 0x3000) // MOVE.L D0,-(SP); MOVE.B (A4,D3.W),D0
        bsr(changeVolume)
        bsr(setVol)
        a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
        patches.add([0x1574, 0x3000, 0x0008], patch: patch5)
        // `Patch6`: a period, told the scopes.
        let patch6 = a.placed()
        a.w(0x9869, 0x0020, 0x3544, 0x0006, 0x2F00, 0x3004) // SUB.W $20(A1),D4; MOVE.W D4,6(A2); MOVE.L D0,-(SP); MOVE.W D4,D0
        bsr(setPer)
        a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
        patches.add([0x9869, 0x0020, 0x3544, 0x0006], patch: patch6)
        // `Patch7`, `Patch8`: a sample's address and length, told the scopes.
        let patch7 = a.placed()
        a.w(0x248C, 0x356B, 0x0012, 0x0004, 0x2F00, 0x200C) // MOVE.L A4,(A2); MOVE.W $12(A3),4(A2); MOVE.L D0,-(A7); MOVE.L A4,D0
        bsr(setAdr)
        a.w(0x302B, 0x0012) // MOVE.W $12(A3),D0
        bsr(setLen)
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        patches.add([0x248C, 0x356B, 0x0012, 0x0004], patch: patch7)
        let patch8 = a.placed()
        a.w(0x248C, 0x2F00, 0x200C) // MOVE.L A4,(A2); MOVE.L D0,-(A7); MOVE.L A4,D0
        bsr(setAdr)
        a.w(0x98FC, 0x0068, 0x382C, 0x001A, 0xD86C, 0x0016, 0xE24C) // SUBA.W #$68,A4; MOVE.W $1A(A4),D4; ADD.W $16(A4),D4; LSR.W #1,D4
        a.w(0x3544, 0x0004, 0x3004) // MOVE.W D4,4(A2); MOVE.W D4,D0
        bsr(setLen)
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        patches.add([0x248C, 0x99FC, 0x0000, 0x0068, 0x382C, 0x001A, 0xD86C, 0x0016, 0xE24C, 0x3544, 0x0004], patch: patch8)
        // `Patch9`: the game's code's own wait for the beam (to a line from the tick's start), left out;
        // `PatchA`: the wait made eight lines, before the voices' DMA is set.
        let patch9 = a.placed()
        a.w(0x4E75)
        patches.add([0x1239, 0x00DF, 0xF006, 0x9200, 0xB229, 0x0001, 0x6D08, 0x0601, 0x0001, 0x1341, 0x0001, 0x1011,
                     0xD029, 0x0001, 0xB039, 0x00DF, 0xF006, 0x66F8], patch: patch9)
        let patchA = a.placed()
        bsr(dmaWait)
        a.w(0x33C7, 0x00DF, 0xF096, 0x4E75) // MOVE.W D7,$DFF096; RTS
        patches.add([0x33C7, 0x00DF, 0xF096], patch: patchA)
        // `PatchB`: a voice's list's address worked out with all its bits (ADDA.W rather than ADD.W).
        let patchB = a.placed()
        a.w(0x2656, 0xD6D8, 0x234B, 0x002E, 0x4E75) // MOVEA.L (A6),A3; ADDA.W (A0)+,A3; MOVE.L A3,$2E(A1); RTS
        patches.add([0x2016, 0xD058, 0x2340, 0x002E], patch: patchB)

        // The first kind's (`PatchTable2`): `Patch2`, and these.
        // `PatchF`, `PatchS`: a period, told the scopes.
        func period(_ from: UInt16) -> Int {
            let patch = a.placed()
            a.w(0x9669, from, 0x3543, 0x0006, 0x2F00, 0x3003) // SUB.W from(A1),D3; MOVE.W D3,6(A2); MOVE.L D0,-(SP); MOVE.W D3,D0
            bsr(setPer)
            a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
            return patch
        }
        let patchF = period(0x000E)
        // `PatchG`, `PatchO`: a sample's address and length, told the scopes.
        func sample(_ move: UInt16, _ load: UInt16) -> Int {
            let patch = a.placed()
            a.w(0x248D, move, 0x0004, 0x0004, 0x2F00, 0x200D) // MOVE.L A5,(A2); MOVE.W 4(An),4(A2); MOVE.L D0,-(A7); MOVE.L A5,D0
            bsr(setAdr)
            a.w(load, 0x0004) // MOVE.W 4(An),D0
            bsr(setLen)
            a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
            return patch
        }
        let patchG = sample(0x356C, 0x302C) // (A4)
        // `PatchH`: a volume, through `ChangeVolume`.
        let patchH = a.placed()
        a.w(0xEA4A, 0x2F00, 0x1002) // LSR.W #5,D2; MOVE.L D0,-(SP); MOVE.B D2,D0
        bsr(changeVolume)
        bsr(setVol)
        a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
        // `PatchN`: a voice's list gone back to a place in it (the module's own place of it, `Value`), the
        // end of it.
        let patchN = a.placed()
        a.w(0x336C, 0x0002, 0x0006) // MOVE.W 2(A4),Value(A1)
        bsr(songEndTest)
        a.w(0x4E75)
        let patchO = sample(0x356B, 0x302B) // (A3)
        // `PatchP`: a period and a volume, told the scopes, the volume through `ChangeVolume`.
        let patchP = a.placed()
        a.w(0xD243, 0x3541, 0x0006, 0x9429, 0x001D, 0x2F00, 0x3001) // ADD.W D3,D1; MOVE.W D1,6(A2); SUB.B $1D(A1),D2; MOVE.L D0,-(SP); MOVE.W D1,D0
        bsr(setPer)
        a.w(0x1002) // MOVE.B D2,D0
        bsr(changeVolume)
        bsr(setVol)
        a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
        // `PatchQ`: a sample's address and length, told the scopes.
        let patchQ = a.placed()
        a.w(0x24A9, 0x0036, 0x3569, 0x003A, 0x0004, 0x2F00) // MOVE.L $36(A1),(A2); MOVE.W $3A(A1),4(A2); MOVE.L D0,-(A7)
        a.w(0x2029, 0x0036) // MOVE.L $36(A1),D0
        bsr(setAdr)
        a.w(0x3029, 0x003A) // MOVE.W $3A(A1),D0
        bsr(setLen)
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        // `PatchR`: a volume, through `ChangeVolume`.
        let patchR = a.placed()
        a.w(0xEA48) // LSR.W #5,D0
        bsr(changeVolume)
        bsr(setVol)
        a.w(0x4E75)
        let patchS = period(0x002C)
        // `PatchT`: the period in D1 told the scopes, and a volume through `ChangeVolume`.
        let patchT = a.placed()
        a.w(0x2F00, 0x3001) // MOVE.L D0,-(SP); MOVE.W D1,D0
        bsr(setPer)
        a.w(0x201F, 0xE848) // MOVE.L (SP)+,D0; LSR.W #4,D0
        bsr(changeVolume)
        bsr(setVol)
        a.w(0x4E75)
        patches2.add([0x357C, 0x0000, 0x0008], patch: patch2)
        patches2.add([0x9669, 0x000E, 0x3543, 0x0006], patch: patchF)
        patches2.add([0x248D, 0x356C, 0x0004, 0x0004], patch: patchG)
        patches2.add([0xEA4A, 0x1542, 0x0008], patch: patchH)
        patches2.add([0x336C, 0x0002, 0x0006], patch: patchN)
        patches2.add([0x248D, 0x356B, 0x0004, 0x0004], patch: patchO)
        patches2.add([0xD243, 0x3541, 0x0006, 0x9429, 0x001D, 0x1542, 0x0008], patch: patchP)
        patches2.add([0x24A9, 0x0036, 0x3569, 0x003A, 0x0004], patch: patchQ)
        patches2.add([0xEA48, 0x1540, 0x0008], patch: patchR)
        patches2.add([0x9669, 0x002C, 0x3543, 0x0006], patch: patchS)
        patches2.add([0xE848, 0x1540, 0x0008], patch: patchT)
        patches.assemble(&a)
        patches2.assemble(&a)

        muluAt = a.addressOf(mulu)
        modulePtr = a.addressOf(module)
        currentFormat = a.addressOf(format)
        exPlayPtr = a.addressOf(exPlay)
        voicePtrTemp = a.addressOf(voicePtr)
        addFlag = a.addressOf(add)
        valueAt = a.addressOf(value)
        codeNValue = patches2.patternAt[4] + 4
        patchNValue = a.addressOf(patchN) + 4
    }

    /// `ExtLoad` and `InitPlayer` (lines 213-233, 678-957), for the first and third kinds.
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let (module, size) = try Desire.listData(&host)
        let end = module &+ size
        func word(_ at: UInt32) -> UInt16 { at >= module && at < end && at &+ 2 <= end ? host.machine.peek16(at) : 0 }
        func long(_ at: UInt32) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }
        func signed(_ word: UInt16) -> UInt32 { UInt32(bitPattern: Int32(Int16(bitPattern: word))) }
        func refuse() -> TuneError { .malformed("a module of Jesper Olsen's that is not as the player looks for") }
        guard let kind = Self.kind({ $0 >= 0 ? long(module &+ UInt32($0)) : 0 }) else { throw refuse() }
        host.machine.poke32(modulePtr, module)
        switch kind {
        case .second:
            throw .unsupported("Jesper Olsen's second kind of module, which siday knows of none to check against")
        case let .code(mulu):
            host.machine.poke16(muluAt, mulu)
            host.machine.poke8(currentFormat, 0)
            // The songs' table: the place of the first LEA x(PC) (any of `$40FA`'s bits, forward) of the
            // routine that starts a song; and its songs, the table's size over `Mulu`.
            let start = module &+ 6 &+ UInt32(word(module + 6))
            var at = start
            var songs: UInt32?
            while songs == nil, at < end {
                let op = word(at)
                at += 2
                guard op & 0x8000 == 0, op & 0x40FA == 0x40FA else { continue }
                let distance = word(at)
                at += 2
                guard distance & 0x8000 == 0 else { continue }
                songs = at &- 2 &+ UInt32(distance)
            }
            guard let songs, mulu != 0 else { throw refuse() }
            host.machine.poke32(exPlayPtr, songs)
            let length = module &+ signed(word(songs)) &- songs
            let quotient = length / UInt32(mulu)
            var count = quotient > 0xFFFF ? Int(length & 0xFFFF) : Int(quotient)
            if count == 0 { count = 1 }
            // The first voice's list's place: the first LEA x(PC),A1 of the routine for a tick; and whether
            // the place is the start of the module's music (`ADDA.L (A6),A1` after it, `AddFlag`).
            let play = module &+ 10 &+ UInt32(word(module + 10))
            guard let lea = WantedTeamSearch.find(host, [0x43FA], from: play, most: Int(end) - Int(play)) else { throw refuse() }
            host.machine.poke32(voicePtrTemp, lea &+ 2 &+ signed(word(lea + 2)))
            host.machine.poke16(addFlag, word(lea + 4) == 0xD3D6 ? 1 : 0)
            // The module's own place of a voice's list (`Value`), where it puts it again as the list goes
            // back: the `MOVE.W d(A4),Value(A1)` after the `$7FFE` (or `$7FFF`, if the module has no fourth
            // BRA.W) that follows.
            let loop: UInt16 = word(module + 12) == 0x6000 ? 0x7FFE : 0x7FFF
            guard let mark = WantedTeamSearch.find(host, [loop], from: lea + 4, most: Int(end) - Int(lea + 4)),
                  let move = WantedTeamSearch.find(host, [0x336C], from: mark + 2, most: Int(end) - Int(mark + 2))
            else { throw refuse() }
            let value = word(move + 4)
            host.machine.poke16(valueAt, value)
            host.machine.poke16(codeNValue, value)
            host.machine.poke16(patchNValue, value)
            // `ModuleChange` (lines 239-275): `PatchTable2`, in the 1,700 bytes from the routine that starts a song.
            patches2.apply(&host, from: start, length: 1700)
            return WantedTeamSongs(first: 1, count: count)
        case .data:
            host.machine.poke8(currentFormat, 0xFF)
            // `ExtLoad`: the game's code, from beside the module.
            let g = DeliTrackerHost.globals
            let path = host.machine.peek32(g + DeliTrackerHost.dtgPathArrayPtr)
            host.machine.poke8(path, 0)
            _ = try host.call(host.machine.peek32(g + DeliTrackerHost.dtgCopyDir))
            var name = path
            while host.machine.peek8(name) != 0, name < path + 255 { name += 1 }
            for (i, byte) in (Array(Self.replayerName.utf8) + [0]).enumerated() { host.machine.poke8(name + UInt32(i), byte) }
            guard try host.call(host.machine.peek32(g + DeliTrackerHost.dtgLoadFile)) == 0 else {
                throw .missingCompanion("Jesper Olsen's music needs its game's replayer, \(Self.replayerName), beside it")
            }
            // The songs: the table's, from its second, less one if the first is empty (its first voice's
            // word nought, or a `$7F00` not where it ends).
            let table = word(module)
            let first = signed(word(module &+ UInt32(table)))
            var songs = Int(table / 2) - 1
            if songs != 1, word(module &+ first &- 6) == 0 || word(module &+ first &- 4) == 0x7F00 {
                songs -= 1
            }
            // The samples' headers, whose places are listed after the songs: the module refused (as
            // `EPR_ModuleTooShort`) if the furthest sample in them begins past its end.
            // (The player walks the list until it comes to the lowest header, and on into memory if it
            // never does: refused here.)
            var list = module &+ signed(word(module &+ UInt32(table) &+ 2))
            let firstHeader = module &+ signed(word(list))
            var lowest = firstHeader
            var high = long(firstHeader &+ 14) & 0xFF_FFFF
            repeat {
                guard list < end, list < lowest else { throw refuse() }
                let header = module &+ signed(word(list))
                list += 2
                var start = long(header &+ 14) & 0xFF_FFFF
                if Int32(bitPattern: high) <= Int32(bitPattern: start) {
                    high = start
                    if word(header &+ 14) >> 8 == 0 {
                        start = long(header &+ 20)
                        if Int32(bitPattern: high) <= Int32(bitPattern: start) { high = start }
                    }
                }
                if header < lowest { lowest = header }
            } while list != lowest
            guard Int32(bitPattern: high) < Int32(bitPattern: size) else {
                throw .malformed("a module of Jesper Olsen's that is shorter than its samples")
            }
            // The game's code, as the player knows it: `TST.L D0; BEQ.W` first, an even size, and `$3C3D3E3F` last.
            _ = try host.call(host.machine.peek32(g + DeliTrackerHost.dtgGetListData), with: [(0, 1)])
            let code = host.machine.cpu.registers[8], codeSize = host.machine.cpu.registers[0]
            host.machine.poke32(exPlayPtr, code)
            guard codeSize >= 8, codeSize & 1 == 0, host.machine.peek32(code) == 0x4A80_6700,
                  host.machine.peek32(code &+ codeSize &- 4) == 0x3C3D_3E3F
            else { throw .malformed("a replayer of Jesper Olsen's (\(Self.replayerName)) that is not as the player looks for") }
            // `ModuleChange`: `PatchTable`, in the 1,700 bytes from the code's start.
            patches.apply(&host, from: code, length: 1700)
            return WantedTeamSongs(first: 1, count: max(1, songs))
        }
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
