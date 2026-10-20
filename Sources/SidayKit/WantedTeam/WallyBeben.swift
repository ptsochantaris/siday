// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Wally Beben's music ("Wally Beben player module V1.0 (15 Dec
// 2002)", UADE's players/WallyBeben), whose source is UADE's amigasrc/players/wanted_team/WallyBeben/src/
// "Wally Beben_v1.asm": the lines given are of that file.

/// Wally Beben's music for the Amiga (of 1988 to 1990, as the player's credit has it), made with his
/// replay routine "Ariston" after its version 4.1: each module is his 68000 code that plays it, with its
/// music and samples, as it was saved from the game, at the address it ran at. It begins with a BRA to
/// its routine to start a song and its routine for a tick; then a line of his ("(c)Wally Beben 1988
/// music on the Amiga"). The player finds its own variables, songs and samples by its instructions, works
/// out from the first `MOVE.B $Address,D0` where it was saved, and moves the addresses in its code and
/// tables to where it is (`FixedOriginCode`). Its modules are of two kinds, which the player calls old
/// and new: the new have a `MOVEM.L $Address,D0-D7` at 20, and an empty sample whose pointer is moved too.
///
/// As the player plays it: a wait of eight lines of the beam put after the module's turning on of Paula's
/// DMA (and in the new modules before its turning off as well; in the old, the turning on made the
/// player's own); its writes of the four voices' volumes turned down by the balance, which is none, and
/// its samples, lengths and periods told EaglePlayer's scopes; the old modules' loops' offsets taken in
/// 16 bits, not 12. A song ends when each of its four
/// voices has come to the end of its list of patterns (the $FF after it), or when the module silences
/// voices 1 and 2 (as it does when a song stops) for the second time since it was started.
typealias WallyBebenPlayer = WantedTeamPlayer<WallyBeben>

struct WallyBeben: WantedTeamRecipe {
    static let format = "Wally Beben"

    /// `Check2` (line 310): a BRA.W to an even place further on, at which a BSR (short or long) and two
    /// CLR.B $Address and an RTS; after it `MOVEM.L D0-A6,-(A7)` and a BSR.W to a `MOVEM.L $Address,D0-D7`
    /// or a `MOVE.B $Address,D0`.
    static func isOne(_ data: [UInt8]) -> Bool {
        func word(_ at: Int) -> UInt16 {
            at >= 0 && at + 2 <= data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
        }
        let to = Int16(bitPattern: word(2))
        guard word(0) == 0x6000, to > 0, to % 2 == 0 else { return false }
        var at = 2 + Int(to)
        guard at + 1 < data.count, data[at] == 0x61 else { return false }
        at += data[at + 1] == 0 ? 4 : 2
        guard word(at) == 0x4239, word(at + 6) == 0x4239, word(at + 12) == 0x4E75,
              WantedTeamHeader.long(data, 4) == 0x48E7_FFFE, word(8) == 0x6100
        else { return false }
        let called = 10 + Int(Int16(bitPattern: word(10)))
        return WantedTeamHeader.long(data, called) == 0x4CF9_00FF || word(called + 4) == 0x1039
    }

    let title = ""
    private(set) var author = "Wally Beben"
    /// The module's own line, as the player shows it.
    private(set) var detail = ""

    /// The player's variables and routines, where they are assembled.
    private var modulePtr: UInt32 = 0, subSongPtr: UInt32 = 0, songsPtr: UInt32 = 0, periodBase: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    /// The instructions with an address in them that the player moves (lines 627-730).
    static let code = FixedOriginCode(forms: [
        (0x0079, .afterWord), (0x0239, .afterWord), (0x03B9, .address), (0x03F9, .address), (0x1039, .address),
        (0x1239, .address), (0x13C0, .address), (0x13C4, .address), (0x13C7, .address), (0x13D0, .address),
        (0x13D3, .address), (0x13E8, .afterWord), (0x13EA, .afterWord), (0x13F9, .twoAddresses), (0x13FC, .afterWord),
        (0x1839, .address), (0x1C39, .address), (0x1E39, .address), (0x23C2, .address), (0x23D1, .address),
        (0x2679, .address), (0x3039, .address), (0x33C0, .address), (0x33C4, .address), (0x33C6, .address),
        (0x33C5, .address), (0x33D1, .address), (0x3839, .address), (0x3A39, .address), (0x3C39, .address),
        (0x41F9, .address), (0x4239, .address), (0x43F9, .address), (0x45F9, .address), (0x4A39, .address),
        (0x4BF9, .address), (0x4CF9, .afterWord), (0x4DF9, .address), (0x4EF9, .address), (0x5239, .address),
        (0x5279, .address), (0x5339, .address), (0x9039, .address), (0x9079, .address), (0xB039, .address),
        (0xD039, .address), (0xD079, .address), (0xD3F9, .address), (0xD5F9, .address), (0xDBF9, .address),
        (0xDDF9, .address), (0xE2F9, .address),
    ])

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables (lines 47-86), in the player's order, on which `InitSound` relies.
        let module = a.variable(long: 0), subSong = a.variable(long: 0), songs = a.variable(long: 0)
        _ = a.variable(long: 0) // VoicesPtr
        _ = a.variable(long: 0) // SamplesPtr
        let period = a.variable(long: 0)
        _ = a.variable(long: 0) // ChangeLen
        _ = a.variable(word: 0) // Change
        let eagleBase = a.eagleBase()
        _ = a.variable(long: 0) // SamplesLen
        let songEnd = a.variable(long: 0x5754_5754) // 'WTWT'
        _ = a.variable(word: 0) // Byte
        let endFlag = a.variable(word: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // `SetVolume` (line 138, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `Left2`, `Left1`, `Right1`, `Right2` (lines 154-178): the volume in D0 of voice 3, 0, 1 or 2
        // turned down by its side's, nought if it is muted, and told the scopes (A0 their structure).
        let ex = a.label()
        var volumeOf = [Int](repeating: 0, count: 4)
        for (v, side) in [(3, leftVolume), (0, leftVolume), (1, rightVolume), (2, rightVolume)] {
            volumeOf[v] = a.placed()
            a.w(0xC0FA)
            a.displacement(to: side) // MULU.W side(PC),D0
            a.w(0xC07A)
            a.displacement(to: voices[v]) // AND.W VoiceN(PC),D0
            a.w(0xEC48, 0x3140, UInt16(8 + v * 18)) // LSR.W #6,D0; MOVE.W D0,UPS_VoiceNVol(A0)
            if v != 2 { a.branch(0x6000, to: ex) } // BRA.S Ex
        }
        a.place(ex)
        a.w(0x4E75)
        // `SetAdr` (line 180): the sample's address in D0 told the scopes, for the voice D6 is 16 times.
        let setAdr = a.placed()
        a.w(0x2F08, 0x41FA)
        a.displacement(to: scopes[0]) // MOVE.L A0,-(A7); LEA StructAdr(PC),A0
        for v in 0 ..< 4 {
            let next = a.label()
            if v == 0 { a.w(0x4A46) } else { a.w(0x0C46, UInt16(v * 16)) } // TST.W D6 / CMP.W #$v0,D6
            a.branch(0x6600, to: next) // BNE.B
            a.w(0x2140, UInt16(v * 18)) // MOVE.L D0,UPS_VoiceNAdr(A0)
            a.place(next)
        }
        a.w(0x205F, 0x4E75) // MOVEA.L (A7)+,A0; RTS
        // `SetTwo` (line 202): the length in D0 (in bytes) and the period kept for the voice (from
        // `PeriodBase`, a word for each) told the scopes.
        let setTwo = a.placed()
        a.w(0x48E7, 0x80A0, 0xE248, 0x41FA) // MOVEM.L D0/A0/A2,-(A7); LSR.W #1,D0; LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x247A)
        a.displacement(to: period) // MOVEA.L PeriodBase(PC),A2
        for v in 0 ..< 4 {
            let next = a.label()
            if v > 0 { a.w(0x548A) } // ADDQ.L #2,A2
            if v == 0 { a.w(0x4A46) } else { a.w(0x0C46, UInt16(v * 16)) } // TST.W D6 / CMP.W #$v0,D6
            a.branch(0x6600, to: next) // BNE.B
            a.w(0x3140, UInt16(4 + v * 18), 0x3152, UInt16(6 + v * 18)) // MOVE.W D0,UPS_VoiceNLen(A0); MOVE.W (A2),UPS_VoiceNPer(A0)
            a.place(next)
        }
        a.w(0x4CDF, 0x0501, 0x4E75) // MOVEM.L (A7)+,D0/A0/A2; RTS
        // `InfoBuffer` (line 368), of which `InitSound` sets the song's length.
        let info = a.placed()
        for _ in 0 ..< 46 { a.w(0) }
        // `Interrupt` (line 386, DTP_Interrupt): the module's routine for a tick, its second (at 4).
        tick = a.here
        a.w(0x48E7, 0x7FFE, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(SP); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x50E8, 0x004C) // ST UPS_Enabled(A0)
        for v in 0 ..< 4 { a.w(0x4268, UInt16(6 + v * 18)) } // CLR.W UPS_VoiceNPer(A0)
        a.w(0x317C, 0x000F, 0x004A, 0x207A) // MOVE.W #UPSB_Adr!UPSB_Len!UPSB_Per!UPSB_Vol,UPS_Flags(A0); MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x4EA8, 0x0004) // JSR 4(A0)
        a.endTick(scopes: scopes)
        let dmaWait = a.dmaWait(lines: 8) // (line 407)
        // `InitSound` (line 789, DTP_InitSound): the song's number put in the module's byte for it, the
        // longest of its voices' lists of patterns found for EaglePlayer, and the module's routine to start
        // a song (its first) called.
        let initSound = a.placed()
        let nextPos = a.label(), findEnd = a.label(), maxLen = a.label()
        a.clearScopes(scopes)
        a.w(0x49FA)
        a.displacement(to: songEnd) // LEA SongEnd(PC),A4
        a.w(0x28FC, 0x5754, 0x5754) // MOVE.L #'WTWT',(A4)+
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x207A) // MOVE.W dtg_SndNum(A5),D0; MOVEA.L SubSongPtr(PC),A0
        a.displacement(to: subSong)
        a.w(0x1080, 0x5340, 0xE948, 0x227A) // MOVE.B D0,(A0); SUBQ.W #1,D0; LSL.W #4,D0; MOVEA.L SongsPtr(PC),A1
        a.displacement(to: songs)
        a.w(0x43F1, 0x0000, 0x7403, 0x7800, 0x7AFF) // LEA (A1,D0.W),A1; MOVEQ #3,D2; MOVEQ #0,D4; MOVEQ #-1,D5
        a.place(nextPos)
        a.w(0x5285, 0x2459, 0x7600) // ADDQ.L #1,D5; MOVEA.L (A1)+,A2; MOVEQ #0,D3
        a.place(findEnd)
        a.w(0x5283, 0x0C1A, 0x00FF) // ADDQ.L #1,D3; CMP.B #$FF,(A2)+
        a.branch(0x6600, to: findEnd) // BNE.B FindEnd
        a.w(0xB883) // CMP.L D3,D4
        a.branch(0x6C00, to: maxLen) // BGE.B MaxLen
        a.w(0x2803, 0x3885) // MOVE.L D3,D4; MOVE.W D5,(A4)
        a.place(maxLen)
        a.w(0x51CA)
        a.displacement(to: nextPos) // DBF D2,NextPos
        a.w(0x41FA)
        a.displacement(to: info) // LEA InfoBuffer(PC),A0
        a.w(0x2144, 0x003C, 0x426C, 0x0002, 0x207A) // MOVE.L D4,Length(A0); CLR.W 2(A4); MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x4E90, 0x41FA) // JSR (A0); LEA EndFlag(PC),A0
        a.displacement(to: endFlag)
        a.w(0x4250, 0x4E75) // CLR.W (A0); RTS
        // The patches (their table at line 847), each as the player has it.
        // `Patch0`: the old modules' turning on of the DMA (with the bits of DMACONR they keep) made a
        // wait of the beam and the player's own.
        let patch0 = a.placed()
        a.w(0x6100)
        a.displacement(to: dmaWait) // BSR.W DMAWait
        a.w(0x0041, 0x8200, 0x33C1, 0x00DF, 0xF096, 0x0A41, 0x820F, 0x4E75) // OR.W #$8200,D1; MOVE.W D1,$DFF096; EOR.W #$820F,D1; RTS
        patches.add([0x0081, 0x0000, 0x8200, 0x3039, 0x00DF, 0xF002, 0x0240, 0x05F0, 0x8240, 0x33C1, 0x00DF, 0xF096, 0x0A41, 0xFFFF],
                    patch: patch0)
        // `Patch1`: the four voices' volumes (A2 $DFF0A8) turned down by the balance and told the scopes.
        let patch1 = a.placed()
        a.w(0x2F08, 0x41FA)
        a.displacement(to: scopes[0]) // MOVE.L A0,-(A7); LEA StructAdr(PC),A0
        for (i, v) in [0, 1, 2, 3].enumerated() {
            if i > 0 { a.w(i < 3 ? 0x1019 : 0x1011) } // MOVE.B (A1)+,D0 / MOVE.B (A1),D0
            a.w(0x6100)
            a.displacement(to: volumeOf[v]) // BSR.W Left1, Right1, Right2, Left2
            if v == 0 { a.w(0x3480) } else { a.w(0x3540, UInt16(v * 16)) } // MOVE.W D0,v*16(A2)
        }
        a.w(0x205F, 0x4E75) // MOVEA.L (A7)+,A0; RTS
        patches.add([0x3480, 0x1019, 0x3540, 0x0010, 0x1019, 0x3540, 0x0020, 0x1011, 0x3540, 0x0030], patch: patch1)
        // `Patch2`: voices 1 and 2 silenced (A5 $DFF0A8): the second time since the song was started, its
        // end, and the scopes cleared.
        let patch2 = a.placed()
        let noEnd2 = a.label(), clear = a.label()
        a.w(0x3B40, 0x0010, 0x3B40, 0x0020, 0x4A79) // MOVE.W D0,$10(A5); MOVE.W D0,$20(A5); TST.W EndFlag
        a.address(of: endFlag)
        a.branch(0x6700, to: noEnd2) // BEQ.B NoEnd2
        a.w(0x48E7, 0x0044, 0x2A7A) // MOVEM.L A1/A5,-(A7); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91, 0x4BFA) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1); LEA StructAdr(PC),A5
        a.displacement(to: scopes[0])
        a.w(0x43ED, 0x0050) // LEA UPS_SizeOF(A5),A1
        a.place(clear)
        a.w(0x425D, 0xB3CD) // CLR.W (A5)+; CMPA.L A5,A1
        a.branch(0x6600, to: clear) // BNE.B ClearUPS2
        a.w(0x4CDF, 0x2200) // MOVEM.L (A7)+,A1/A5
        a.place(noEnd2)
        a.w(0x50F9)
        a.address(of: endFlag) // ST EndFlag
        a.w(0x4E75)
        patches.add([0x3B40, 0x0010, 0x3B40, 0x0020], patch: patch2)
        // `Patch3`: after the module's `AND.L #$FF,D6` (D6 the voice's place among Paula's registers), the
        // voice's length (D0) and period told the scopes.
        let patch3 = a.placed()
        a.w(0x0286, 0x0000, 0x00FF, 0x6100) // AND.L #$FF,D6; BSR.W SetTwo
        a.displacement(to: setTwo)
        a.w(0x4E75)
        patches.add([0x0286, 0x0000, 0x00FF], patch: patch3)
        // `Patch4`: the new modules' turning off and on of the DMA, with a wait of the beam before and after.
        let patch4 = a.placed()
        a.w(0x6100)
        a.displacement(to: dmaWait) // BSR.W DMAWait
        a.w(0x33C1, 0x00DF, 0xF096, 0x0A41, 0x820F, 0x33C1, 0x00DF, 0xF096, 0x6100) // MOVE.W D1,$DFF096; EOR.W #$820F,D1; MOVE.W D1,$DFF096; BSR.W DMAWait
        a.displacement(to: dmaWait)
        a.w(0x4E75)
        patches.add([0x33C1, 0x00DF, 0xF096, 0x0A41, 0x820F, 0x33C1, 0x00DF, 0xF096], patch: patch4)
        // `Patch5`: a voice's next pattern taken from its list (A0 its variables, the first its number
        // times 16): a list at its end ($FF) cleared from the four bytes of `SongEnd`, and the song's end
        // when all four are, which are set again.
        let patch5 = a.placed()
        let noEnd = a.label(), test = a.label(), skipEnd = a.label()
        a.w(0x1028, 0x000C, 0x5228, 0x000C, 0xD3C0, 0x0C11, 0x00FF) // MOVE.B 12(A0),D0; ADDQ.B #1,12(A0); ADDA.L D0,A1; CMP.B #$FF,(A1)
        a.branch(0x6600, to: noEnd) // BNE.B NoEnd
        a.w(0x48E7, 0x0044, 0x43FA) // MOVEM.L A1/A5,-(A7); LEA SongEnd(PC),A1
        a.displacement(to: songEnd)
        for v in 0 ..< 4 {
            let next = a.label()
            if v == 0 { a.w(0x4A10) } else { a.w(0x0C10, UInt16(v * 16)) } // TST.B (A0) / CMP.B #$v0,(A0)
            a.branch(0x6600, to: next) // BNE.B
            if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
            if v < 3 { a.branch(0x6000, to: test) } // BRA.B test
            a.place(next)
        }
        a.place(test)
        a.w(0x4A91) // TST.L (A1)
        a.branch(0x6600, to: skipEnd) // BNE.B SkipEnd
        a.w(0x22BC, 0x5754, 0x5754, 0x2A7A) // MOVE.L #'WTWT',(A1); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(skipEnd)
        a.w(0x4CDF, 0x2200) // MOVEM.L (A7)+,A1/A5
        a.place(noEnd)
        a.w(0x4E75)
        patches.add([0x1028, 0x000C, 0x5228, 0x000C, 0xD3C0], patch: patch5)
        // `Patch6`: the old modules' turning on of the DMA followed by a wait of the beam.
        let patch6 = a.placed()
        a.w(0x33C1, 0x00DF, 0xF096, 0x6100) // MOVE.W D1,$DFF096; BSR.W DMAWait
        a.displacement(to: dmaWait)
        a.w(0x4E75)
        patches.add([0x33C1, 0x00DF, 0xF096], patch: patch6)
        // `Patch7`: the new modules' writing of a voice's sample's address, told the scopes.
        let patch7 = a.placed()
        a.w(0x4BF9, 0x00DF, 0xF0A0, 0x2BB1, 0x4000, 0x6000) // LEA $DFF0A0,A5; MOVE.L 0(A1,D4.W),0(A5,D6.W)
        a.w(0x2F00, 0x2031, 0x4000, 0x6100) // MOVE.L D0,-(SP); MOVE.L 0(A1,D4.W),D0; BSR.W SetAdr
        a.displacement(to: setAdr)
        a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
        patches.add([0x4BF9, 0x00DF, 0xF0A0, 0x2BB1, 0x4000, 0x6000], patch: patch7)
        // `Patch8`: the old modules' finding of a voice's registers, with its sample's address (at A1)
        // told the scopes.
        let patch8 = a.placed()
        a.w(0x4BF9, 0x00DF, 0xF0A0, 0xDBC6) // LEA $DFF0A0,A5; ADDA.L D6,A5
        a.w(0x2F00, 0x2011, 0x6100) // MOVE.L D0,-(SP); MOVE.L (A1),D0; BSR.W SetAdr
        a.displacement(to: setAdr)
        a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
        patches.add([0x4BF9, 0x00DF, 0xF0A0, 0xDBC6], patch: patch8)
        // `Patch9`: the old modules' loops' offsets taken in sixteen bits ("Repeat sample offset fix").
        let patch9 = a.placed()
        a.w(0x0286, 0x0000, 0xFFFF, 0x4E75) // AND.L #$FFFF,D6; RTS
        patches.add([0x0286, 0x0000, 0x0FFF], patch: patch9)
        patches.assemble(&a)
        modulePtr = a.addressOf(module)
        subSongPtr = a.addressOf(subSong)
        songsPtr = a.addressOf(songs)
        periodBase = a.addressOf(period)
        initSoundAt = a.addressOf(initSound)
    }

    /// `InitPlayer` (line 430): the module's routines, songs and samples found and moved to where it is,
    /// its code moved, and patched. (Its searches run on until they find what they look for; here they
    /// stop at the module's end, and a module they would not find it in is refused.)
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let (module, size) = try Desire.listData(&host)
        let end = module &+ size
        func refuse() -> TuneError { .malformed("a module of Wally Beben's whose code is not as the player looks for") }
        func word(_ at: UInt32) -> UInt16 { host.machine.peek16(at) }
        func long(_ at: UInt32) -> UInt32 { host.machine.peek32(at) }
        /// The first place from `from` on that holds `words`.
        func find(_ words: [UInt16], from: UInt32) throws(TuneError) -> UInt32 {
            guard from >= module, from < end, let at = WantedTeamSearch.find(host, words, from: from, most: Int(end - from)) else {
                throw refuse()
            }
            return at
        }
        /// The first place before `from`, going back, that holds `word`.
        func back(_ word: UInt16, from: UInt32) throws(TuneError) -> UInt32 {
            var at = from
            repeat {
                guard at >= module + 2 else { throw refuse() }
                at -= 2
            } while host.machine.peek16(at) != word
            return at
        }
        // Where the module was saved: the address of the byte after its first RTS (the song's number),
        // as its first `MOVE.B $Address,D0` after it has it.
        let subSong = try find([0x4E75], from: module) + 2
        var a1 = try find([0x1039], from: subSong) + 2
        let origin = long(a1) &- (subSong - module)
        func moved(_ value: UInt32) -> UInt32 { value &- origin &+ module }
        func move(_ at: UInt32) { host.machine.poke32(at, moved(long(at))) }
        // Its songs: one fewer than the `MOVE.L #n,D1` after it.
        a1 = try find([0x223C], from: a1) + 2
        let songs = long(a1) &- 1
        // ("Circus Games fixes".)
        if UInt16(truncatingIfNeeded: songs) == 6, long(module + 3090) == 0x9298, word(module + 3128) == 0xFA0 {
            host.machine.poke32(module + 3090, 0x9298 - 80)
            host.machine.poke16(module + 3128, 0xFA0 - 80)
        }
        // Its songs' table, of the first `LEA $Address,A0` after: four pointers to lists for each song,
        // and after them the lists' pointers to the patterns, up to the first pattern (the lowest of the
        // songs' pointers). (Of tables that the player would go through for ever, as one that ends before
        // it begins, the module is refused.)
        a1 = try find([0x41F9], from: a1) + 2
        let table = moved(long(a1))
        a1 += 4
        let tableEnd = table &+ UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: songs << 4)))
        guard table >= module, tableEnd > table, tableEnd - table >= 8, tableEnd <= end else { throw refuse() }
        move(table)
        var lowest = Int32(bitPattern: long(table))
        var at = table + 4
        repeat {
            move(at)
            if Int32(bitPattern: long(at)) <= lowest { lowest = Int32(bitPattern: long(at)) }
            at += 4
        } while at != tableEnd
        let patterns = UInt32(bitPattern: lowest)
        guard patterns >= tableEnd + 4, patterns <= end, (patterns - tableEnd) % 4 == 0 else { throw refuse() }
        repeat {
            move(at)
            at += 4
        } while at != patterns
        host.machine.poke32(modulePtr, module)
        host.machine.poke32(subSongPtr, subSong)
        host.machine.poke32(songsPtr, table)
        // The voices' variables, after `ADDA.L D1,A0`; and in a new module, its empty sample's pointer
        // (after `MOVE.W 0(A6,D3.W),D6`), moved, and the instruction after that made `MOVE.L (A6),D6; NOP`.
        a1 = try find([0xD1C1], from: a1) + 2
        let newFormat = word(module + 20) == 0x4CF9
        var emptySample: UInt32 = 0
        if newFormat {
            a1 = try find([0x3C36, 0x3000], from: a1)
            emptySample = moved(long(a1 + 6))
            move(emptySample)
            host.machine.poke32(a1 + 10, 0x2C16_4E71)
        }
        // The samples' pointers, before the next `ASL.L #2,D4`; the RTS before the periods' table (the
        // end of the code, which is moved and patched); the voices' periods (`MOVE.W D0,(A1)` going
        // back from there, after an `ADDA.L $Address,A1` or not); and the samples' lengths, the first
        // `LEA $Address,A1` after the RTS before the `MOVEQ #0,D0` (or `CLR.L D0`) going back from there.
        a1 = try find([0xE584], from: a1) + 2
        var samples = moved(long(a1 - 6))
        a1 = try find([0x0358, 0x0328], from: a1)
        a1 = try back(0x4E75, from: a1)
        let codeLength = a1 - module
        a1 = try back(0x3280, from: a1)
        let clear: UInt16 = word(a1 - 6) == 0xD3F9 ? 0x7000 : 0x4280
        host.machine.poke32(periodBase, moved(long(a1 + 6)))
        repeat {
            a1 = try back(clear, from: a1)
        } while word(a1 - 2) != 0x4E75
        a1 = try find([0x43F9], from: a1) + 2
        let lengths = moved(long(a1))
        // The samples' pointers moved, up to the lengths (or the empty sample's); the samples counted,
        // each of the lengths' entries of eight bytes beginning with its number, its length not nought.
        let samplesEnd = newFormat ? emptySample : lengths
        guard samplesEnd > samples, samplesEnd - samples >= 4, samplesEnd <= end, (samplesEnd - samples) % 4 == 0 else {
            throw refuse()
        }
        at = samples
        repeat {
            move(at)
            at += 4
        } while at != samplesEnd
        var count = 0
        at = lengths
        while at < end, host.machine.peek8(at) == UInt8(truncatingIfNeeded: count), word(at + 2) != 0 {
            count += 1
            at += 8
        }
        // If the first sample (the lowest pointer) is at an odd place in the module, each is put one on.
        // (For none, the player's loops run 65,536 times.)
        let pointers = count == 0 ? 65536 : count
        var first = Int32(bitPattern: long(samples))
        for i in 0 ..< pointers where Int32(bitPattern: long(samples + UInt32(i * 4))) < first {
            first = Int32(bitPattern: long(samples + UInt32(i * 4)))
        }
        if (UInt32(bitPattern: first) &- module) & 1 != 0 {
            for _ in 0 ..< pointers {
                host.machine.poke32(samples, long(samples) &+ 1)
                samples += 4
            }
        }
        // The code moved, up to the RTS before the periods.
        guard Self.code.relocate(&host, from: module, to: module + codeLength, origin: origin, module: module) else {
            throw .malformed("a module of Wally Beben's whose code the player would search for ever")
        }
        // The module's line ("(c)..."), the first in its code, as the player shows it; but up to the code
        // after it only (which follows it in some without a nought between, and begins `TST.B x(A0)`).
        if let text = WantedTeamSearch.find(host, [0x2863], from: module, most: Int(codeLength)) {
            var bytes: [UInt8] = []
            var c = text
            while bytes.count < 160, c < end, (c - text) % 2 != 0 || word(c) != 0x4A28 {
                let b = host.machine.peek8(c)
                guard b == 10 || (b >= 32 && b < 127) else { break }
                bytes.append(b == 10 ? 32 : b)
                c += 1
            }
            detail = String(decoding: bytes, as: UTF8.self)
            let joseph = Array("Richard Joseph".utf8)
            if bytes.count >= joseph.count, (0 ... bytes.count - joseph.count).contains(where: { Array(bytes[$0 ..< $0 + joseph.count]) == joseph }) {
                author = "Richard Joseph"
            }
        }
        // `ModuleChange` (line 285): the patches made in the code.
        patches.apply(&host, from: module, length: codeLength)
        return WantedTeamSongs(first: 1, count: Int(Int32(bitPattern: songs)))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
