// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Sean Connolly's music ("Sean Connolly player module V1.1 (29 Oct
// 1999)", by Mr.Larmer, UADE's players/SeanConnolly), whose source is not given: what it does is read from
// its code, and the addresses given are of its hunk in UADE's file.

import SidayFoundation

/// Sean Connolly's music for the Amiga (of 1992 to 1995, as the player's credit has it), as his games
/// had it: each module is his 68000 code that plays it (his "EMS" replay), with its music and samples,
/// beginning with four BRA.Ws, the first to start a song (with its number in D0) and the others its
/// routines for a tick and to stop, which of them by the version; then a line of text of his. The player tells three versions of his code apart by the instructions its
/// start begins with, which it calls V3.01, V3.18 and V5.xx; siday's collection has only V3.18 (Surf Ninjas),
/// and the others are refused.
///
/// As the player plays V3.18: its wait for the beam (a busy loop over VHPOSR) made ten lines of CIA-B's
/// count of them; its writes of the four voices' samples, lengths, periods and volumes from its table
/// patched to tell EaglePlayer's scopes (and the volumes turned down by the balance, which is none); and
/// the song's end said when the first voice's list of patterns goes back to its start, and again, with
/// the song started afresh, if all four voices have stopped.
typealias SeanConnollyPlayer = WantedTeamPlayer<SeanConnolly>

struct SeanConnolly: WantedTeamRecipe {
    static let format = "Sean Connolly"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -18.0 dB.)
    static let gain: Float = 0.23

    /// The player's file is 4,204 bytes, its hunk 3,964: relocated to $E000 by UADE, the module goes
    /// at $10000.
    static let moduleAt: UInt32 = 0x10000

    /// `Check2` ($460): the version of the module's code, as the player tells them apart (1 for V3.01, 2
    /// for V3.18, 3 for V5.xx), or nil: the first three longs BRA.Ws, and where the first goes,
    /// `MOVEM.L D1-D7/A0-A6,-(A7)` and `LSL.L #4,D0; LEA x(PC),A0` (V3.18) or `MOVE.W #$DD,D1` (V3.01), or
    /// `MOVEM.L D1/A0-A3,-(A7)` and `TST.B D0; BMI.S` (V5.xx).
    static func version(_ data: [UInt8]) -> Int? { version { WantedTeamHeader.long(data, $0) } }

    /// `version`, of the module whose longs (by their offset, nought past its end) `long` gives.
    static func version(_ long: (Int) -> UInt32) -> Int? {
        guard long(0) >> 16 == 0x6000, long(4) >> 16 == 0x6000, long(8) >> 16 == 0x6000 else { return nil }
        let at = 2 + Int(Int16(truncatingIfNeeded: long(0)))
        if long(at) == 0x48E7_7FFE {
            if long(at + 4) == 0xE988_41FA { return 2 }
            if long(at + 4) == 0x323C_00DD { return 1 }
        }
        return long(at) == 0x48E7_40F0 && long(at + 4) == 0x4A00_6B0A ? 3 : nil
    }

    static func isOne(_ data: [UInt8]) -> Bool { version(data) != nil }

    let title = ""
    let author = "Sean Connolly"
    /// The version, as the player names it.
    let detail = "V3.18"

    private var modulePtr: UInt32 = 0, endListPtr: UInt32 = 0, songsPtr: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($16C to $1EF): the module, the place of its voices' stops, its version, its
        // songs' table, the globals, the voices' periods before the tick, the sides' volumes, the
        // voices' muting, the scopes; and where `InitSound` puts the song's length for EaglePlayer.
        let module = a.variable(long: 0), endList = a.variable(long: 0), songs = a.variable(long: 0)
        let version = a.variable(word: 0x0202)
        let eagleBase = a.eagleBase()
        let periods = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        let info = a.placed()
        for _ in 0 ..< 36 { a.w(0) }
        // `SetVolume` ($2C6, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // The volume of each voice in D0 turned down by its side's balance, and nought if it is muted
        // ($304, $30E, $318, $322): voice 3's, 0's, 1's and 2's.
        let shift = a.label()
        var volumeOf = [Int](repeating: 0, count: 4)
        for (v, side) in [(3, leftVolume), (0, leftVolume), (1, rightVolume), (2, rightVolume)] {
            volumeOf[v] = a.placed()
            a.w(0xC0FA)
            a.displacement(to: side) // MULU.W side(PC),D0
            a.w(0xC07A)
            a.displacement(to: voices[v]) // AND.W Voice(PC),D0
            if v != 2 { a.branch(0x6000, to: shift) } // BRA.S
        }
        a.place(shift)
        a.w(0xEC48, 0x4E75) // LSR.W #6,D0; RTS
        // `InitSound` ($9EE, DTP_InitSound): the song's length worked out for EaglePlayer from the songs'
        // table, and the song started with its number in D0 (jumped to).
        let initSound = a.placed()
        let lengths = a.label(), notHalved = a.label()
        a.w(0x7000, 0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x3200, 0x227A) // MOVEQ #0,D0; MOVE.W dtg_SndNum(A5),D0; MOVE.W D0,D1; MOVEA.L Songs(PC),A1
        a.displacement(to: songs)
        a.place(lengths)
        a.w(0x2429, 0x0004, 0x9491, 0x5089, 0x5089, 0x51C9) // MOVE.L 4(A1),D2; SUB.L (A1),D2; ADDQ.L #8,A1; ADDQ.L #8,A1; DBF D1,
        a.displacement(to: lengths)
        a.w(0x47FA)
        a.displacement(to: version) // LEA Version(PC),A3
        a.w(0x0C13, 0x0003) // CMPI.B #3,(A3)
        a.branch(0x6600, to: notHalved) // BNE.S
        a.w(0xE28A) // LSR.L #1,D2
        a.place(notHalved)
        a.w(0x5382, 0x45FA) // SUBQ.L #1,D2; LEA Info(PC),A2
        a.displacement(to: info)
        a.w(0x2542, 0x0044, 0x207A) // MOVE.L D2,68(A2); MOVEA.L Module(PC),A0
        a.displacement(to: module)
        a.w(0x4ED0) // JMP (A0)
        // `Interrupt` ($A44, DTP_Interrupt): the scopes told a tick is being played, and each voice's
        // period kept and cleared; if all four voices have stopped (the long where they are kept nought),
        // the song's end said and the song started afresh; the module's routine for a tick (its third
        // BRA.W, at 8, for V3.18); and a period the tick has not changed cleared.
        tick = a.here
        let play = a.label(), noRestart = a.label()
        a.w(0x48E7, 0x7FFE, 0x45FA) // MOVEM.L D1-D7/A0-A6,-(A7); LEA StructAdr(PC),A2
        a.displacement(to: scopes[0])
        a.w(0x50EA, 0x004C, 0x357C, 0x000F, 0x004A) // ST UPS_Enabled(A2); MOVE.W #$F,UPS_Flags(A2)
        for v in 0 ..< 4 {
            a.w(0x33EA, UInt16(6 + v * 18)) // MOVE.W UPS_VoiceNPer(A2),PeriodN
            a.address(of: periods[v])
        }
        for v in 0 ..< 4 { a.w(0x426A, UInt16(6 + v * 18)) } // CLR.W UPS_VoiceNPer(A2)
        a.w(0x203A)
        a.displacement(to: endList) // MOVE.L EndList(PC),D0
        a.w(0x2240, 0x207A) // MOVEA.L D0,A1; MOVEA.L Module(PC),A0
        a.displacement(to: module)
        a.w(0x45FA)
        a.displacement(to: version) // LEA Version(PC),A2
        a.w(0x0C12, 0x0002) // CMPI.B #2,(A2)
        a.branch(0x6700, to: play) // BEQ.S
        // (V3.01's and V5.xx's, the same with its second BRA.W, at 4.)
        let other = a.label(), done = a.label()
        a.w(0x4A80) // TST.L D0
        a.branch(0x6700, to: other) // BEQ.S
        a.w(0x4A91) // TST.L (A1)
        a.branch(0x6600, to: other) // BNE.S
        a.w(0x2A7A)
        a.displacement(to: eagleBase) // MOVEA.L EagleBase(PC),A5
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91, 0x6100) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1); BSR.W InitSound
        a.displacement(to: initSound)
        a.place(other)
        a.w(0x4EA8, 0x0004) // JSR 4(A0)
        a.branch(0x6000, to: done) // BRA.S
        a.place(play)
        a.w(0x4A80) // TST.L D0
        a.branch(0x6700, to: noRestart) // BEQ.S
        a.w(0x4A91) // TST.L (A1)
        a.branch(0x6600, to: noRestart) // BNE.S
        a.w(0x2A7A)
        a.displacement(to: eagleBase) // MOVEA.L EagleBase(PC),A5
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91, 0x6100) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1); BSR.W InitSound
        a.displacement(to: initSound)
        a.place(noRestart)
        a.w(0x4EA8, 0x0008) // JSR 8(A0)
        a.place(done)
        a.w(0x45FA) // LEA StructAdr(PC),A2
        a.displacement(to: scopes[0])
        for v in 0 ..< 4 {
            let same = a.label()
            a.w(0x302A, UInt16(6 + v * 18), 0xB07A) // MOVE.W UPS_VoiceNPer(A2),D0; CMP.W PeriodN(PC),D0
            a.displacement(to: periods[v])
            a.branch(0x6600, to: same) // BNE.S
            a.w(0x426A, UInt16(6 + v * 18)) // CLR.W UPS_VoiceNPer(A2)
            a.place(same)
        }
        a.w(0x426A, 0x004C, 0x4CDF, 0x7FFE, 0x7000, 0x4E75) // CLR.W UPS_Enabled(A2); MOVEM.L (A7)+,D1-D7/A0-A6; MOVEQ #0,D0; RTS
        // The patches for V3.18 (their table at $B2C).
        // $B9A: the wait for the beam, ten lines of CIA-B's count of them.
        let wait = a.placed()
        let line = a.label(), same = a.label()
        a.w(0x7009) // MOVEQ #9,D0
        a.place(line)
        a.w(0x1239, 0x00BF, 0xD800) // MOVE.B $BFD800,D1
        a.place(same)
        a.w(0xB239, 0x00BF, 0xD800) // CMP.B $BFD800,D1
        a.branch(0x6700, to: same) // BEQ.S
        a.w(0x51C8)
        a.displacement(to: line) // DBF D0,
        a.w(0x4E75)
        patches.add([0x1239, 0x00DF, 0xF006, 0xB041, 0x6CF0], patch: wait) // MOVE.B $DFF006,D1; CMP.W D1,D0; BGE.S *-16
        // $C00: the voices' samples, lengths, periods and volumes written from the table at A0 (A1 $DFF000),
        // each told the scopes, the volumes through the balance.
        let voicesPatch = a.placed()
        var pattern: [UInt16] = []
        a.w(0x48E7, 0x8020, 0x45FA) // MOVEM.L D0/A2,-(A7); LEA StructAdr(PC),A2
        a.displacement(to: scopes[0])
        for v in 0 ..< 4 {
            let t = UInt16(v * 16), r = 0xA0 + UInt16(v * 16), s = UInt16(v * 18)
            // MOVE.L t(A0),r(A1); MOVE.L t(A0),s(A2); MOVE.L t+4(A0),r+4(A1); MOVE.W t+4(A0),s+4(A2); MOVE.W t+6(A0),s+6(A2)
            if v == 0 { a.w(0x2350, r, 0x2550, s) } else { a.w(0x2368, t, r, 0x2568, t, s) }
            a.w(0x2368, t + 4, r + 4, 0x3568, t + 4, s + 4, 0x3568, t + 6, s + 6)
            a.w(0x3028, t + 8, 0x6100) // MOVE.W t+8(A0),D0; BSR.W the volume
            a.displacement(to: volumeOf[v])
            a.w(0x3340, r + 8, 0x3540, s + 8) // MOVE.W D0,r+8(A1); MOVE.W D0,s+8(A2)
            if v == 0 { pattern += [0x2350, r] } else { pattern += [0x2368, t, r] }
            pattern += [0x2368, t + 4, r + 4, 0x3368, t + 8, r + 8]
        }
        a.w(0x4CDF, 0x0401, 0x4E75) // MOVEM.L (A7)+,D0/A2; RTS
        patches.add(pattern, patch: voicesPatch)
        // $E0E, $E28: a voice's list of patterns gone back to its start (MOVE.B 2(A3),0(A2,D0.W)); the
        // first voice's is the song's end.
        let songEnd = a.songEndRoutine(eagleBase: eagleBase)
        let wrap = a.placed()
        let notFirst = a.label()
        a.w(0x15AB, 0x0002, 0x0000, 0x4A40) // MOVE.B 2(A3),0(A2,D0.W); TST.W D0
        a.branch(0x6600, to: notFirst) // BNE.S
        a.branch(0x6100, to: songEnd) // BSR.S SongEnd
        a.place(notFirst)
        a.w(0x4E75)
        patches.add([0x15AB, 0x0002, 0x0000], patch: wrap)
        patches.assemble(&a)
        modulePtr = a.addressOf(module)
        endListPtr = a.addressOf(endList)
        songsPtr = a.addressOf(songs)
        initSoundAt = a.addressOf(initSound)
    }

    /// `InitPlayer` ($5AA), for V3.18 (from $744).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let (module, size) = try Desire.listData(&host)
        func refuse() -> TuneError { .malformed("a module of Sean Connolly's whose code is not as the player looks for") }
        let end = module + size
        func long(_ at: UInt32) -> UInt32 { at >= module && at &+ 4 <= end && at < end ? host.machine.peek32(at) : 0 }
        func relative(_ at: UInt32) -> UInt32 { at &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(at)))) }
        guard let version = Self.version({ $0 >= 0 ? long(module &+ UInt32($0)) : 0 }) else { throw refuse() }
        guard version == 2 else { throw .unsupported("Sean Connolly's code of a version the player calls V3.01 or V5.xx") }
        host.machine.poke32(modulePtr, module)
        // The songs' table, from the LEA x(PC),A0 of the routine to start a song (the first BRA.W's).
        let start = Int32(Int16(bitPattern: host.machine.peek16(module + 2)))
        var a3 = module &+ UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: start &- 0x270)))
        guard long(a3 + 630) == 0xE988_41FA else { throw refuse() }
        let table = relative(a3 + 634)
        host.machine.poke32(songsPtr, table)
        // Its end: the LEA x(PC) of a `$0000 $41FA` found going back from 3,020 bytes on.
        while long(a3 + 3020) != 0x0000_41FA {
            guard a3 &+ 3020 > module else { throw refuse() }
            a3 -= 2
        }
        var songs = Int((relative(a3 + 3024) &- table) >> 4)
        // The place of the voices' stops, past the module's text (the first long of nought from 16 bytes
        // in, and four on), if the samples and the rest are found as the player looks for them;
        // and one song only for two sizes of the samples.
        if long(a3 + 2714) == 0xDA45_DA45 {
            let sizes = relative(a3 + 2720)
            let (last, before) = (long(sizes &- 4), long(sizes &- 8))
            if long(a3 + 2342) != 0xE54C_41FA { a3 += 2 }
            if long(a3 + 2342) == 0xE54C_41FA {
                let samples = relative(a3 + 2358)
                var after = samples &+ last
                if long(after) == 0x464F_524D { // "FORM"
                    after = after &+ long(after &+ 4) &+ 8
                } else {
                    after = after &+ (Int32(bitPattern: last &- before) > 10 ? 4 : last &- before)
                }
                if long(a3 + 3334) != 0xDA85_41FA { a3 -= 4 }
                if long(a3 + 3334) == 0xDA85_41FA {
                    var at = module + 16
                    while long(at) != 0 {
                        guard at + 4 < end else { throw refuse() }
                        at += 2
                    }
                    host.machine.poke32(endListPtr, at + 4)
                    if after &- samples == 0xBF2 || after &- samples == 0x12 { songs = 1 }
                }
            }
        }
        // `ModuleChange` ($538): the patches made in the 4,000 bytes (or the module's, if fewer) from the
        // module's start and the first BRA.W's distance.
        patches.apply(&host, from: module &+ UInt32(bitPattern: start), length: min(0xFA0, size))
        return WantedTeamSongs(first: 0, count: max(1, songs))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
