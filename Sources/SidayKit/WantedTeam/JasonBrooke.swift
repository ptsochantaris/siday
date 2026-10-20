// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Jason C. Brooke's music ("Jason C. Brooke player module V1.0 (7 Jan
// 2000)", UADE's players/JasonBrooke), whose source is not given: what it does is read from its code, and the
// addresses given are of its hunk in UADE's file.

/// Jason C. Brooke's music for the Amiga (of 1987 to 1990, as the player's credit has it: his conversions
/// of arcade games, Out Run, Space Harrier, Thunder Blade, After Burner, 1943, Side Arms and others): each
/// module is his 68000 code that plays it, with its music and samples, as the game had it, and no header.
/// The player knows two kinds of it. The first (Feud, World Darts, Pac-Land), small, begins with its
/// routine for a tick, `MOVEM.L D0-D3/A0-A3,-(A7); CLR.W D0; LEA module(PC),A3`; the second, the rest, begins
/// with its variables, and has its routine for a tick, the first MOVEM in it, a little way on, a routine
/// whose start (`BSET #1,$BFE001; MOVE.W #$780,$DFF09A; LEA module(PC),A3`) the player checks for. Each has
/// its songs in a table, of ten bytes each (the first kind) or eighteen (the second), and a routine to
/// start one with its number, from nought, in D0, which the player finds by searching the code.
///
/// As the player plays it, fifty ticks a second: each of the module's writes of a voice's volume (turned
/// down by the balance, which is none), period, sample and length patched to tell EaglePlayer's scopes;
/// the song's end said when the module stops all its voices, or once each voice has come to the end of
/// its list of patterns and gone back (as the player has it, the size of the voices' records and the
/// places in them it reads found in the module's code, and the words of its patches set to match).
///
/// Pac-Land's code (of the first kind) reads its voices' envelopes with an index whose upper byte it never
/// sets: the D2 of the code its tick interrupted. UADE's host leaves a value there by which every envelope
/// is read from noughts, so that UADE plays all ten of its songs in silence (every volume nought, all else
/// as here); siday's host leaves it nought, and Pac-Land's music is heard.
typealias JasonBrookePlayer = WantedTeamPlayer<JasonBrooke>

struct JasonBrooke: WantedTeamRecipe {
    static let format = "Jason C. Brooke"

    /// `Check2` ($562): the kind of module, as the player tells them apart (1 for the first, 0 for the
    /// second), or nil. The first kind's first longs `MOVEM.L D0-D3/A0-A3,-(A7)`, `CLR.W D0; LEA` and
    /// `-8(PC),A3; TST.B`; the second's, a MOVEM within the 26 words from 172 bytes in, whose mask is
    /// $F8FC or $F8F8, followed by `BSET #1,$BFE001; MOVE.W #$780,$DFF09A; LEA x(PC),A3`, which points at
    /// the module's start.
    static func kind(_ data: [UInt8]) -> Int? {
        func long(_ at: Int) -> UInt32 { WantedTeamHeader.long(data, at) }
        func word(_ at: Int) -> UInt16 { at >= 0 && at + 2 <= data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0 }
        if long(0) == 0x48E7_F0F0 { return long(4) == 0x4240_47FA && long(8) == 0xFFF8_4A2B ? 1 : nil }
        var at = 172
        while at < 172 + 52, word(at) != 0x48E7 { at += 2 }
        guard at < 172 + 52, word(at + 2) == 0xF8FC || word(at + 2) == 0xF8F8 else { return nil }
        at += 4
        guard long(at) == 0x08F9_0001, long(at + 4) == 0x00BF_E001, long(at + 8) == 0x33FC_0780,
              long(at + 12) == 0x00DF_F09A, word(at + 16) == 0x47FA
        else { return nil }
        // (The LEA's displacement taken as the check takes it, from $10000.)
        return at + 18 + Int(word(at + 18)) - 0x10000 == 0 ? 0 : nil
    }

    static func isOne(_ data: [UInt8]) -> Bool { kind(data) != nil }

    let title = ""
    let author = "Jason C. Brooke"

    private var modulePtr: UInt32 = 0, playPtr: UInt32 = 0, initPtr: UInt32 = 0, songsPtr: UInt32 = 0
    private var formatAt: UInt32 = 0, setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    /// The words of the player's code that `InitPlayer` sets from the module's: for the first kind, the
    /// size of a voice's record (in a pattern and in its patch); for the second, the offset in a voice's
    /// record of its registers' place (in five patches), and of its count of ticks to its vibrato (in a
    /// pattern, twice, and in its patch, twice).
    private var recordSizeAt: [UInt32] = [], registersAt: [UInt32] = [], vibratoAt: [UInt32] = []
    private var first = WantedTeamPatches(), second = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($13E to $1C3): the module, its routines for a tick and to start a song, its songs'
        // table; the place in the song (for EaglePlayer), the voices' ends (four bytes), the globals, the
        // kind, the sides' volumes, the voices' muting, the scopes; and the module's information, of which
        // `InitSound` keeps the song's length.
        let module = a.variable(long: 0), play = a.variable(long: 0), start = a.variable(long: 0)
        let songs = a.variable(long: 0)
        let position = a.variable(word: 0), songEnd = a.variable(long: 0x5754_5754)
        let eagleBase = a.eagleBase()
        let format = a.variable(word: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        let info = a.placed()
        for _ in 0 ..< 46 { a.w(0) }
        // `SetVolume` ($2A8, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `ChangeVolume` ($2CC, $3E0): the volume in D0 of the voice whose registers A1 (or A4) point at,
        // turned down by its side's balance and nought if it is muted, written to it.
        let volume1 = a.balancedVolume(value: 0, base: 1, temp: 1, left: leftVolume, right: rightVolume, voices: voices)
        // The scopes' routines ($31C-$3DF, $430-$4EF), for the voice whose registers A1 (or A4) point at:
        // its volume in D0, its sample's address in A2 (A1) and its length (64 words, or D1), its period
        // at 24(A0) (or in D1).
        let setVol1 = a.scopeRoutine(scopes, base: 1, field: 4, pointer: 2, voicesAt: 0xDFF0A0, body: [0x3480]) // MOVE.W D0,(A2)
        let setAdr1 = a.scopeRoutine(scopes, base: 1, field: 0, voicesAt: 0xDFF0A0, body: [0x208A]) // MOVE.L A2,(A0)
        let setLen1 = a.scopeRoutine(scopes, base: 1, field: 2, voicesAt: 0xDFF0A0, body: [0x30BC, 0x0040]) // MOVE.W #64,(A0)
        let setPer1 = a.scopeRoutine(scopes, base: 1, field: 3, pointer: 2, voicesAt: 0xDFF0A0, body: [0x34A8, 0x0018]) // MOVE.W 24(A0),(A2)
        let volume4 = a.balancedVolume(value: 0, base: 4, temp: 2, left: leftVolume, right: rightVolume, voices: voices)
        let setVol4 = a.scopeRoutine(scopes, base: 4, field: 4, pointer: 2, voicesAt: 0xDFF0A0, body: [0x3480]) // MOVE.W D0,(A2)
        let setAdr4 = a.scopeRoutine(scopes, base: 4, field: 0, voicesAt: 0xDFF0A0, body: [0x2089]) // MOVE.L A1,(A0)
        let setLen4 = a.scopeRoutine(scopes, base: 4, field: 2, voicesAt: 0xDFF0A0, body: [0x3081]) // MOVE.W D1,(A0)
        let setPer4 = a.scopeRoutine(scopes, base: 4, field: 3, pointer: 2, voicesAt: 0xDFF0A0, body: [0x3481]) // MOVE.W D1,(A2)
        // `Interrupt` ($648, DTP_Interrupt): every register kept (D0 too), the scopes told a tick is being
        // played, and the module's routine for a tick called.
        tick = a.here
        a.w(0x48E7, 0xFFFE, 0x41FA) // MOVEM.L D0-D7/A0-A6,-(A7); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x50E8, 0x004C) // ST UPS_Enabled(A0)
        for v in 0 ..< 4 { a.w(0x4268, UInt16(6 + v * 18)) } // CLR.W UPS_VoiceNPer(A0)
        a.w(0x317C, 0x000F, 0x004A, 0x207A) // MOVE.W #$F,UPS_Flags(A0); MOVEA.L PlayPtr(PC),A0
        a.displacement(to: play)
        a.w(0x4E90, 0x41FA) // JSR (A0); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x4268, 0x004C, 0x4CDF, 0x7FFF, 0x4E75) // CLR.W UPS_Enabled(A0); MOVEM.L (A7)+,D0-D7/A0-A6; RTS
        // `InitSound` ($918, DTP_InitSound): the place in the song cleared and the voices' ends counted
        // afresh; for the first kind, the song's fourth voice's list (the word at 8 in its entry, which a
        // patch below compares with) noted, and its length for EaglePlayer; for the second, the voice with
        // the largest first byte in the song's entry (from the first's, the voice at $A0) noted, whose
        // place in its list a patch below tells EaglePlayer; and the module's routine to start a song
        // jumped to, with the song's number in D0.
        initSoundAt = a.here
        let secondKind = a.label(), count = a.label(), started = a.label(), entry = a.label(), voice = a.label()
        let notLarger = a.label()
        a.w(0x7000, 0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x41FA) // MOVEQ #0,D0; MOVE.W dtg_SndNum(A5),D0; LEA Position(PC),A0
        a.displacement(to: position)
        a.w(0x4258, 0x20BC, 0x5754, 0x5754, 0x2400, 0x247A) // CLR.W (A0)+; MOVE.L #'WTWT',(A0); MOVE.L D0,D2; MOVEA.L SongsPtr(PC),A2
        a.displacement(to: songs)
        a.w(0x43FA)
        a.displacement(to: format) // LEA Format(PC),A1
        a.w(0x4A51) // TST.W (A1)
        a.branch(0x6700, to: secondKind) // BEQ.S
        a.w(0xC4FC, 0x000A, 0xD5C2, 0x227A) // MULU.W #10,D2; ADDA.L D2,A2; MOVEA.L ModulePtr(PC),A1
        a.displacement(to: module)
        let fourthList = a.label()
        a.w(0x508A, 0xD2D2, 0x33D2) // ADDQ.L #8,A2; ADDA.W (A2),A1; MOVE.W (A2),fourthList
        a.address(of: fourthList)
        a.w(0x7AFF) // MOVEQ #-1,D5
        a.place(count)
        a.w(0x5285, 0x4A59) // ADDQ.L #1,D5; TST.W (A1)+
        a.branch(0x6600, to: count) // BNE.S
        a.place(started)
        a.w(0x45FA)
        a.displacement(to: info) // LEA InfoBuffer(PC),A2
        a.w(0x2545, 0x0034, 0x207A) // MOVE.L D5,MI_Length(A2); MOVEA.L InitPtr(PC),A0
        a.displacement(to: start)
        a.w(0x4ED0) // JMP (A0)
        let largest = a.label()
        a.place(secondKind)
        a.place(entry)
        a.w(0x7848, 0xE38C, 0x7603, 0x7A00, 0x548A) // MOVEQ #72,D4; LSL.L #1,D4; MOVEQ #3,D3; MOVEQ #0,D5; ADDQ.L #2,A2
        a.place(voice)
        a.w(0x5084, 0x5084, 0xBA12) // ADDQ.L #8,D4; ADDQ.L #8,D4; CMP.B (A2),D5
        a.branch(0x6E00, to: notLarger) // BGT.S
        a.w(0x1A12, 0x33C4) // MOVE.B (A2),D5; MOVE.W D4,largest
        a.address(of: largest)
        a.place(notLarger)
        a.w(0x588A, 0x51CB) // ADDQ.L #4,A2; DBF D3,
        a.displacement(to: voice)
        a.w(0x51CA) // DBF D2,
        a.displacement(to: entry)
        a.w(0xE28D) // LSR.L #1,D5
        a.branch(0x6000, to: started) // BRA.S

        // The first kind's patches (`PatchTable` at $9B4, searched for in the 400 bytes from the module's
        // start). $A18: a voice's volume, MOVE.B 13(A0),9(A1), through `ChangeVolume`.
        let volumePatch = a.placed()
        a.w(0x2F00, 0x7000, 0x1028, 0x000D, 0x6100) // MOVE.L D0,-(A7); MOVEQ #0,D0; MOVE.B 13(A0),D0; BSR.W ChangeVolume
        a.displacement(to: volume1)
        a.w(0x6100)
        a.displacement(to: setVol1) // BSR.W SetVol
        a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
        first.add([0x1368, 0x000D, 0x0009], patch: volumePatch)
        // $A32: a period, MOVE.W 24(A0),6(A1).
        let periodPatch = a.placed()
        a.w(0x3368, 0x0018, 0x0006, 0x6100) // MOVE.W 24(A0),6(A1); BSR.W SetPer
        a.displacement(to: setPer1)
        a.w(0x4E75)
        first.add([0x3368, 0x0018, 0x0006], patch: periodPatch)
        // $A44: a sample, ADDA.W D0,A2; MOVE.L A2,(A1); ADDA.W #size,A0 (the size of a voice's record).
        let samplePatch = a.placed()
        a.w(0xD4C0, 0x228A, 0x6100) // ADDA.W D0,A2; MOVE.L A2,(A1); BSR.W SetAdr
        a.displacement(to: setAdr1)
        a.w(0x6100)
        a.displacement(to: setLen1) // BSR.W SetLen
        a.w(0xD0FC)
        recordSizeAt = [a.here]
        a.w(0x001C, 0x4E75) // ADDA.W #size,A0; RTS
        first.add([0xD4C0, 0x228A, 0xD0FC, 0x001C], patch: samplePatch)
        // $A5E: a voice's list gone back to its start (TST.W 0(A2,D0.W); BNE.S; SF D0); the voice's end
        // (`SongEndTest`), and its place told EaglePlayer if it is the song's fourth voice.
        let wrapPatch = a.placed()
        let notWrapped = a.label(), notFourth = a.label(), endTest1 = a.label()
        a.w(0x4A72, 0x0000) // TST.W 0(A2,D0.W)
        a.branch(0x6600, to: notWrapped) // BNE.S
        a.branch(0x6100, to: endTest1) // BSR.S SongEndTest
        a.w(0x51C0) // SF D0
        a.place(notWrapped)
        a.w(0x224B, 0x0C68) // MOVEA.L A3,A1; CMPI.W #fourthList,4(A0)
        a.place(fourthList)
        a.w(0x5754, 0x0004)
        a.branch(0x6600, to: notFourth) // BNE.S
        a.w(0x33C0)
        a.address(of: position) // MOVE.W D0,Position
        a.place(notFourth)
        a.w(0x4E75)
        first.add([0x4A72, 0x0000, 0x6602, 0x51C0, 0x224B], patch: wrapPatch)
        // `SongEndTest` ($A84): the voice whose number counts down in D3 (3 for the first) ended; once all
        // four have, the song's end said and the count begun again.
        a.place(endTest1)
        Self.endTest(&a, songEnd: songEnd, eagleBase: eagleBase) { a, v in a.w(0x0C43, UInt16(3 - v)) } // CMPI.W #3-v,D3
        // $AD0: the module's stop of its voices, MOVE.W #$F,$DFF096, the song's end (`SongEnd`, $AE0).
        let stopPatch = a.placed()
        a.w(0x33FC, 0x000F, 0x00DF, 0xF096)
        let songEndRoutine = a.songEndRoutine(eagleBase: eagleBase)
        first.add([0x33FC, 0x000F, 0x00DF, 0xF096], patch: stopPatch)
        // $AF4: the module's voices cleared (SF 13(A0); SF 48(A0); ADDA.W #50,A0; DBF D0), the song's end.
        let clearPatch = a.placed()
        let clear = a.label()
        a.w(0x6100)
        a.displacement(to: songEndRoutine) // BSR.W SongEnd
        a.place(clear)
        a.w(0x51E8, 0x000D, 0x51E8, 0x0030, 0xD0FC, 0x0032, 0x51C8) // SF 13(A0); SF 48(A0); ADDA.W #50,A0; DBF D0,
        a.displacement(to: clear)
        a.w(0x4E75)
        first.add([0x51E8, 0x000D, 0x51E8, 0x0030, 0xD0FC, 0x0032, 0x51C8, 0xFFF2], patch: clearPatch)

        // The second kind's patches (`PatchTable` at $9DA, searched for in the 1,400 bytes from the module's
        // routine for a tick). $B18 and $B32: a voice's volume, ADDQ.B #1,D1 or SWAP D1, and MOVE.B D1,9(A4),
        // through `ChangeVolume`.
        for before in [UInt16(0x5201), 0x4841] {
            let patch = a.placed()
            a.w(before, 0x2F00, 0x7000, 0x1001, 0x6100) // before; MOVE.L D0,-(A7); MOVEQ #0,D0; MOVE.B D1,D0; BSR.W ChangeVolume
            a.displacement(to: volume4)
            a.w(0x6100)
            a.displacement(to: setVol4) // BSR.W SetVol
            a.w(0x201F, 0x4E75) // MOVE.L (A7)+,D0; RTS
            second.add([before, 0x1941, 0x0009], patch: patch)
        }
        // $B4C, $BC6 and $BFC: a period, MOVE.W 32(A0) (or 34, or 30),6(A4).
        func period(_ a: inout AmigaAssembly, _ offset: UInt16) -> Int {
            let patch = a.placed()
            a.w(0x3968, offset, 0x0006, 0x2F01, 0x3228, offset, 0x6100) // MOVE.W offset(A0),6(A4); MOVE.L D1,-(A7); MOVE.W offset(A0),D1; BSR.W SetPer
            a.displacement(to: setPer4)
            a.w(0x221F, 0x4E75) // MOVE.L (A7)+,D1; RTS
            return patch
        }
        second.add([0x3968, 0x0020, 0x0006], patch: period(&a, 0x20))
        // $B66: a period with its vibrato (BTST #2,(A0) and on, to MOVE.W D1,6(A4)), the count of ticks to
        // the vibrato at an offset the module gives.
        let vibratoPatch = a.placed()
        let written = a.label(), counting = a.label()
        a.w(0x0810, 0x0002) // BTST #2,(A0)
        a.branch(0x6700, to: written) // BEQ.S
        a.w(0x4A28)
        vibratoAt = [a.here]
        a.w(0x0013) // TST.B count(A0)
        a.branch(0x6600, to: counting) // BNE.S
        a.w(0x3428, 0x0008, 0xD568, 0x000A, 0xD268, 0x000A) // MOVE.W 8(A0),D2; ADD.W D2,10(A0); ADD.W 10(A0),D1
        a.branch(0x6000, to: written) // BRA.S
        a.place(counting)
        a.w(0x5328)
        vibratoAt.append(a.here)
        a.w(0x0013) // SUBQ.B #1,count(A0)
        a.place(written)
        a.w(0x3941, 0x0006, 0x6100) // MOVE.W D1,6(A4); BSR.W SetPer
        a.displacement(to: setPer4)
        a.w(0x4E75)
        second.add([0x0810, 0x0002, 0x6718, 0x4A28, 0x0013, 0x660E, 0x3428, 0x0008, 0xD568, 0x000A, 0xD268, 0x000A,
                    0x6004, 0x5328, 0x0013, 0x3941, 0x0006], patch: vibratoPatch)
        // $BB0: a sample, MOVE.W D1,4(A4); MOVE.L A1,(A4).
        let samplePatch1 = a.placed()
        a.w(0x3941, 0x0004, 0x6100) // MOVE.W D1,4(A4); BSR.W SetLen
        a.displacement(to: setLen4)
        a.w(0x2889, 0x6100) // MOVE.L A1,(A4); BSR.W SetAdr
        a.displacement(to: setAdr4)
        a.w(0x4E75)
        second.add([0x3941, 0x0004, 0x2889], patch: samplePatch1)
        second.add([0x3968, 0x0022, 0x0006], patch: period(&a, 0x22))
        // $BE0: a sample, MOVE.W D1,4(A4); MOVE.L A5,(A4).
        let samplePatch5 = a.placed()
        a.w(0x3941, 0x0004, 0x6100) // MOVE.W D1,4(A4); BSR.W SetLen
        a.displacement(to: setLen4)
        a.w(0x288D, 0x2F09, 0x224D, 0x6100) // MOVE.L A5,(A4); MOVE.L A1,-(A7); MOVEA.L A5,A1; BSR.W SetAdr
        a.displacement(to: setAdr4)
        a.w(0x225F, 0x4E75) // MOVEA.L (A7)+,A1; RTS
        second.add([0x3941, 0x0004, 0x288D], patch: samplePatch5)
        second.add([0x3968, 0x001E, 0x0006], patch: period(&a, 0x1E))
        // $C16: a voice's list gone back to its mark (CMP.B 6(A0),D0; BNE.S; MOVE.B 7(A0),D0; MOVE.W 4(A0),D1):
        // the voice's end (`SongEndTest`); and its place told EaglePlayer if it is the voice `InitSound` noted.
        let loopPatch = a.placed()
        let notBack = a.label(), notNoted = a.label(), endTest0 = a.label()
        a.w(0xB028, 0x0006) // CMP.B 6(A0),D0
        a.branch(0x6600, to: notBack) // BNE.S
        a.branch(0x6100, to: endTest0) // BSR.S SongEndTest
        a.w(0x1028, 0x0007) // MOVE.B 7(A0),D0
        a.place(notBack)
        a.w(0x3228, 0x0004, 0x0C28) // MOVE.W 4(A0),D1; CMPI.B #noted,registers(A0)
        a.place(largest)
        a.w(0x00A0)
        registersAt = [a.here]
        a.w(0x0032)
        a.branch(0x6600, to: notNoted) // BNE.S
        a.w(0x33C0)
        a.address(of: position) // MOVE.W D0,Position
        a.place(notNoted)
        a.w(0x4E75)
        second.add([0xB028, 0x0006, 0x6604, 0x1028, 0x0007, 0x3228, 0x0004], patch: loopPatch)
        // `SongEndTest` ($C44): the voice whose registers' place (the low word of their address, in its
        // record) is that of the voice A0 points at ended; once all four have, the song's end said.
        a.place(endTest0)
        Self.endTest(&a, songEnd: songEnd, eagleBase: eagleBase) { a, v in
            a.w(0x0C28, 0x00A0 + UInt16(v * 16)) // CMPI.B #$A0+16v,registers(A0)
            registersAt.append(a.here)
            a.w(0x0032)
        }
        // $C9A: the module's stop of its voices (MOVE.W #$FF,$DFF09E; MOVE.W #$F,$DFF096), the song's end
        // unless D3 is set.
        let stopPatch0 = a.placed()
        let notStopped = a.label()
        a.w(0x33FC, 0x00FF, 0x00DF, 0xF09E, 0x33FC, 0x000F, 0x00DF, 0xF096, 0x4A83) // ...; TST.L D3
        a.branch(0x6600, to: notStopped) // BNE.S
        a.w(0x6100)
        a.displacement(to: songEndRoutine) // BSR.W SongEnd
        a.place(notStopped)
        a.w(0x4E75)
        second.add([0x33FC, 0x00FF, 0x00DF, 0xF09E, 0x33FC, 0x000F, 0x00DF, 0xF096], patch: stopPatch0)
        first.assemble(&a)
        second.assemble(&a)
        modulePtr = a.addressOf(module)
        playPtr = a.addressOf(play)
        initPtr = a.addressOf(start)
        songsPtr = a.addressOf(songs)
        formatAt = a.addressOf(format)
        // (The first kind's pattern of its sample's writes has the size of a record too.)
        recordSizeAt.append(first.patternAt[2] + 6)
        // (And the second's of the period with its vibrato, its count's offset twice.)
        vibratoAt += [second.patternAt[3] + 8, second.patternAt[3] + 28]
    }

    /// The two kinds' `SongEndTest`, placed here: which voice's byte of `songEnd` to clear chosen by
    /// `compare` (an instruction setting the flags, BEQ for voice `v`), and once all four are clear,
    /// the bytes set again and `dtg_SongEnd` called.
    private static func endTest(_ a: inout AmigaAssembly, songEnd: Int, eagleBase: Int,
                         compare: (inout AmigaAssembly, Int) -> Void)
    {
        let test = a.label(), skip = a.label()
        a.w(0x48E7, 0x0044, 0x43FA) // MOVEM.L A1/A5,-(A7); LEA SongEnd(PC),A1
        a.displacement(to: songEnd)
        for v in 0 ..< 4 {
            let next = a.label()
            compare(&a, v)
            a.branch(0x6600, to: v < 3 ? next : test) // BNE.S
            if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
            if v < 3 {
                a.branch(0x6000, to: test) // BRA.S test
                a.place(next)
            }
        }
        a.place(test)
        a.w(0x4A91) // TST.L (A1)
        a.branch(0x6600, to: skip) // BNE.S
        a.w(0x22BC, 0x5754, 0x5754, 0x2A7A) // MOVE.L #'WTWT',(A1); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(skip)
        a.w(0x4CDF, 0x2200, 0x4E75) // MOVEM.L (A7)+,A1/A5; RTS
    }

    /// `InitPlayer` ($688): the module's routines and tables found by searching its code (the searches,
    /// which in the player run on for ever until they find what they look for, kept to the module here),
    /// the words of the patches that depend on the module set from it, and the patches made.
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let (module, size) = try Desire.listData(&host)
        func refuse() -> TuneError { .malformed("a module of Jason C. Brooke's whose code is not as the player looks for") }
        let end = module &+ size
        func find(_ words: [UInt16], from: UInt32) throws(TuneError) -> UInt32 {
            guard from >= module, from < end, let at = WantedTeamSearch.find(host, words, from: from, most: Int(end - from))
            else { throw refuse() }
            return at
        }
        func word(_ at: UInt32) -> UInt16 { host.machine.peek16(at) }
        func relative(_ at: UInt32) -> UInt32 { at &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(at)))) }
        guard let kind = Self.kind((0 ..< 256).map { host.machine.peek8(module &+ UInt32($0)) }) else { throw refuse() }
        host.machine.poke32(modulePtr, module)
        var songs = 1
        if kind == 1 {
            // ($7DA) The routine for a tick, at the start; the size of a voice's record, the word after the
            // first MOVE.L A2,(A1) after the first LEA x(PC),A1; the songs' table, where the first
            // MOVE.B x(PC,Dn) after that points, less one, counted in tens of bytes on from it to a word of
            // nought or one with its upper byte set; and the routine to start a song, the MOVEM before it.
            host.machine.poke8(formatAt, 0xFF)
            host.machine.poke32(playPtr, module)
            let lea = try find([0x43FA], from: module)
            let move = try find([0x228A], from: lea + 2)
            for at in recordSizeAt { host.machine.poke16(at, word(move + 4)) }
            let table = try find([0x137B], from: move + 4)
            let entries = relative(table + 2) &- 1
            host.machine.poke32(songsPtr, entries)
            var at = entries &+ 10
            while songs < 256, at < end, word(at) != 0, word(at) >> 8 == 0 {
                songs += 1
                at &+= 10
            }
            var start = table + 2
            repeat {
                guard start > module else { throw refuse() }
                start -= 2
            } while word(start) != 0x48E7
            host.machine.poke32(initPtr, start)
            // (`ModuleChange`, $256.)
            first.apply(&host, from: module, length: 400)
        } else {
            // ($6B0) The routine for a tick, the first MOVEM; the offset of the registers' place in a voice's
            // record, the word six bytes on from the next LEA x.L,A4; the offset of its count of ticks to its
            // vibrato, the word eight bytes before the end of the next MOVEQ #0,D3; the end of the songs'
            // table, where the LEA x(PC) before the next MOVE.B 0(A2,D0.W),D0 points; the routine to start a
            // song, four bytes before the next MOVEM; and the songs' table, where the next LEA x(PC),A1
            // points, less one: its songs counted in eighteens of bytes on from it to a word of one or one
            // with its upper byte set, but no more than the table has room for.
            let play = try find([0x48E7], from: module)
            host.machine.poke32(playPtr, play)
            let lea = try find([0x49F9], from: play + 2)
            for at in registersAt { host.machine.poke16(at, word(lea + 8)) }
            let moveq = try find([0x7600], from: lea + 8)
            for at in vibratoAt { host.machine.poke16(at, word(moveq - 8)) }
            let read = try find([0x1032, 0x0000], from: moveq + 2)
            let tableEnd = relative(read - 2)
            let movem = try find([0x48E7], from: read)
            host.machine.poke32(initPtr, movem - 4)
            let entries = relative(try find([0x43FA], from: movem - 4) + 2) &- 1
            host.machine.poke32(songsPtr, entries)
            var at = entries &+ 18
            while songs < 0x7FFF, at < end, word(at) >> 8 == 0, word(at) != 1 {
                songs += 1
                at &+= 18
            }
            // (DIVU.W #18 of the table's size, which leaves its register as it was if the quotient is too
            // large; and the counts compared as signed words.)
            let room = tableEnd &- entries
            let quotient = room / 18 > 0xFFFF ? Int(Int16(truncatingIfNeeded: room)) : Int(Int16(truncatingIfNeeded: room / 18))
            if quotient <= songs { songs = quotient }
            second.apply(&host, from: play, length: 1400)
        }
        guard songs >= 1 else { throw refuse() }
        return WantedTeamSongs(first: 0, count: min(songs, 256))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}

extension AmigaAssembly {
    /// The routine many of Wanted Team's players call `ChangeVolume`, placed here: the volume in the data
    /// register `value` (seven bits of it) of the voice whose registers the address register `base` points
    /// at (by the low word of their address, $F0A0 on), turned down by its side's balance (the words at
    /// `left` for voices 0 and 3, `right` for 1 and 2) and nought if it is muted (`voices`), and written
    /// to the voice's volume; nothing for any other address. The data register `temp` is kept.
    mutating func balancedVolume(value: Int, base: Int, temp: Int, left: Int, right: Int, voices: [Int]) -> Int {
        let routine = placed(), shift = label(), exit = label()
        let v = UInt16(value), t = UInt16(temp), n = UInt16(base)
        let to = (0 ..< 3).map { _ in label() }
        w(0x2F00 | t, 0x0240 | v, 0x007F, 0x2008 | t << 9 | n) // MOVE.L Dt,-(A7); ANDI.W #$7F,Dv; MOVE.L An,Dt
        for i in 0 ..< 3 {
            w(0x0C40 | t, 0xF0A0 + UInt16(i * 16)) // CMPI.W #$F0x0,Dt
            branch(0x6700, to: to[i]) // BEQ.S
        }
        w(0x0C40 | t, 0xF0D0) // CMPI.W #$F0D0,Dt
        branch(0x6600, to: exit) // BNE.S
        for (place, side, voice) in [(nil, left, voices[3]), (to[0], left, voices[0]), (to[1], right, voices[1]),
                                     (to[2], right, voices[2])]
        {
            if let place { self.place(place) }
            w(0xC0FA | v << 9)
            displacement(to: side) // MULU.W side(PC),Dv
            w(0xC07A | v << 9)
            displacement(to: voice) // AND.W Voice(PC),Dv
            if voice != voices[2] { branch(0x6000, to: shift) } // BRA.S
        }
        self.place(shift)
        w(0xEC48 | v, 0x3140 | n << 9 | v, 0x0008) // LSR.W #6,Dv; MOVE.W Dv,8(An)
        self.place(exit)
        w(0x201F | t << 9, 0x4E75) // MOVE.L (A7)+,Dt; RTS
        return routine
    }
}
