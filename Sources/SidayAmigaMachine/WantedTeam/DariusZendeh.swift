// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Stephen Mifsud's EaglePlayer for Darius Zendeh's modules ("Darius Zendeh (old Mark II
// SoundSystem) Module Player V1.3", modified by shd for UADE), whose source is UADE's
// amigasrc/players/dz/DariusZendeh_mod.s: its lines are given, and the addresses of its hunk in UADE's
// file (players/DariusZendeh).

import SidayFoundation

/// Darius Zendeh's music for the Amiga (R-Type, Katakis, Denaris, Crash and Burn): each module is his
/// own 68000 code that plays it, with its music and samples, put where UADE puts a module, and called
/// at its start with a command in its registers (as the first prototype of what became the Mark II
/// Sound System has it). The player knows four kinds by their first instructions: the first, R-Type's
/// levels, has songs of its own (given in D4 as `n << 8 | $FF`, which are played once, and two short
/// ones of two voices, given in D3 and D1, which go round); the second (the rest of R-Type, and Crash
/// and Burn) and the third (none in UnExoticA's collection) have one song, started by D0 = -1 and played
/// by D0 = 2, which goes round; and a "strange" kind (Katakis and Denaris), which begins by keeping more
/// registers, the same.
///
/// The player has no song end of its own but for the songs played once, which it stops as the module
/// says they are over (D4 not nought, line 298). For the songs that go round, the end is taken here to
/// be where each comes to the end of its music and begins again: for the first three kinds, where the
/// module sets the word it keeps to say so (whose test, after a tick of a song played once, gives the
/// player the D4 it stops on, and by which it is found here; the module reads it for nothing else),
/// cleared again to see the next; for the strange kind, which keeps no such word, where its place in
/// its music (the two addresses it keeps between its calls) comes back to where its start put it.
typealias DariusZendehPlayer = WantedTeamPlayer<DariusZendeh>

struct DariusZendeh: WantedTeamRecipe {
    static let format = "Darius Zendeh"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is about -20 (its main songs; the levels' first songs are short) dB.)
    static let gain: Float = 0.28

    /// The player's kinds (`M_Type`, lines 163-177): the second it knows from a demo's and Crash and Burn,
    /// the third from a cracktro's, and its number for the strange one is 666.
    enum Kind: UInt16 { case levels = 1, single = 2, cracktro = 3, strange = 666 }

    /// `ModChk` ($38C, lines 126-180, DTP_Check2): the strange kind by its first four instructions; the
    /// others by their first and third, a `MOVEQ #0,D0; MOVE.W #$F,$DFF096; LEA` within the first $242
    /// bytes, and the fourth instruction, which tells the kind.
    static func kind(_ data: [UInt8]) -> Kind? {
        func long(_ at: Int) -> UInt32 { WantedTeamHeader.long(data, at) }
        if long(0) == 0x48E7_78F0, long(4) >> 16 == 0x41FA, long(8) == 0x4CD8_0600, long(12) == 0x0C00_00FF {
            return .strange
        }
        guard long(0) == 0x48E7_00F0, long(8) == 0x4CD8_0600 else { return nil }
        guard (0 ... 0x120).contains(where: {
            long($0 * 2) == 0x7000_33FC && long($0 * 2 + 4) == 0x000F_00DF && long($0 * 2 + 8) == 0xF096_41FA
        }) else { return nil }
        switch long(12) >> 16 {
        case 0x4A44: return .levels
        case 0x4A00: return .single
        case 0x0C00: return .cracktro
        default: return nil
        }
    }

    static func isOne(_ data: [UInt8]) -> Bool { kind(data) != nil }

    var title: String { "" }
    var author: String { "" }

    private var addrAt: UInt32 = 0, typeAt: UInt32 = 0, endTestAt: UInt32 = 0, startAt: UInt32 = 0
    private var flagAt: UInt32 = 0, positionAt: UInt32 = 0
    private var flagEnd: UInt32 = 0, positionEnd: UInt32 = 0, noEnd: UInt32 = 0
    private var initSoundAt: UInt32 = 0, tick: UInt32 = 0

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The player's variables ($380 to $38A): the module's address, its kind, its last song, the song,
        // and whether a song played once has stopped (a byte, kept here in a word).
        let mAddr = a.variable(long: 0), mType = a.variable(word: 1)
        _ = a.variable(word: 0)
        let mSongCnt = a.variable(word: 0), mStop = a.variable(word: 0)
        // This player's own, for the end of a song that goes round: the routine that looks for it, the
        // module's word or its two addresses, where they were at the start, and whether they have been
        // elsewhere since.
        let eagleBase = a.eagleBase()
        let endTest = a.variable(long: 0), flag = a.variable(long: 0), position = a.variable(long: 0)
        let start = a.variable(long: 0), start2 = a.variable(long: 0)
        let away = a.variable(word: 0)

        let initSub1 = a.label(), stopMod = a.label(), jumpPrg = a.label(), playModR = a.label()
        let jumpPrgR = a.label(), end = a.label(), playModOnce = a.label(), killSnd = a.label()
        // InitSub1 ($524, line 269): a short song of the first kind started, D4 nought and D3 -1 (D1 is
        // which), and the sound killed.
        a.place(initSub1)
        a.w(0x7800, 0x76FF) // MOVEQ #0,D4; MOVEQ #-1,D3
        a.branch(0x6100, to: jumpPrg) // BSR.S JumpPrg
        a.w(0x6000)
        a.displacement(to: killSnd) // BRA.W KillSnd
        // StopMod ($52E, line 274): D4 and D3 nought.
        a.place(stopMod)
        a.w(0x7800, 0x7600) // MOVEQ #0,D4; MOVEQ #0,D3
        a.branch(0x6000, to: jumpPrg) // BRA.S JumpPrg
        // PlayMod ($534, line 278, not called).
        a.w(0x7800, 0x7602)
        // JumpPrg ($538, line 280): the module called.
        a.place(jumpPrg)
        a.w(0x207A)
        a.displacement(to: mAddr) // MOVEA.L M_Addr(PC),A0
        a.w(0x4E90, 0x4E75) // JSR (A0); RTS
        // PlayModR_ ($540, line 284): a tick of a song that goes round, D4 nought and D3 2; and JumpPrg_
        // ($544), the module called, then (this player's) its end looked for; and end_ ($54A).
        a.place(playModR)
        a.w(0x7800, 0x7602) // MOVEQ #0,D4; MOVEQ #2,D3
        a.place(jumpPrgR)
        a.w(0x207A)
        a.displacement(to: mAddr) // MOVEA.L M_Addr(PC),A0
        a.w(0x4E90) // JSR (A0)
        a.w(0x207A)
        a.displacement(to: endTest)
        a.w(0x4E90) // MOVEA.L EndTest(PC),A0; JSR (A0)
        a.place(end)
        a.w(0x4CDF, 0x7FFF, 0x4E75) // MOVEM.L (A7)+,D0-D7/A0-A6; RTS
        // PlayMod_ ($550, line 293): a tick of a song played once, unless it has stopped, D4 2; and if the
        // module says in D4 that it is over, the song stopped (and, this player's, its end said).
        a.place(playModOnce)
        a.w(0x4A39)
        a.address(of: mStop) // TST.B M_Stop
        a.branch(0x6600, to: end) // BNE.S end_
        a.w(0x7802) // MOVEQ #2,D4
        a.branch(0x6100, to: jumpPrg) // BSR.S JumpPrg
        a.w(0x4A84) // TST.L D4
        a.branch(0x6700, to: end) // BEQ.S end_
        a.w(0x13FC, 0x0001)
        a.address(of: mStop) // MOVE.B #1,M_Stop
        a.w(0x6100)
        a.displacement(to: stopMod) // BSR.W StopMod
        a.callSongEnd(eagleBase: eagleBase)
        a.w(0x4CDF, 0x7FFF, 0x4E75) // MOVEM.L (A7)+,D0-D7/A0-A6; RTS

        // Play ($572, line 308, DTP_Interrupt): the strange kind's tick, D0 2 (and, this player's, its
        // end looked for); the second and third kinds' the same, by JumpPrg_; the first kind's short
        // songs (1 and 2) by PlayModR_, and its others by PlayMod_.
        let play = a.placed()
        let notStrange = a.label(), levels = a.label()
        a.w(0x48E7, 0xFFFE, 0x3E3A) // MOVEM.L D0-D7/A0-A6,-(A7); MOVE.W M_Type(PC),D7
        a.displacement(to: mType)
        a.w(0x0C47, 0x029A) // CMPI.W #666,D7
        a.branch(0x6600, to: notStrange) // BNE.S
        a.w(0x7002, 0x207A) // MOVEQ #2,D0; MOVEA.L M_Addr(PC),A0
        a.displacement(to: mAddr)
        a.w(0x4E90) // JSR (A0)
        a.w(0x207A)
        a.displacement(to: endTest)
        a.w(0x4E90) // MOVEA.L EndTest(PC),A0; JSR (A0)
        a.w(0x4CDF, 0x7FFF, 0x7000, 0x4E75) // MOVEM.L (A7)+,D0-D7/A0-A6; MOVEQ #0,D0; RTS
        a.place(notStrange)
        a.w(0x0C47, 0x0001) // CMPI.W #1,D7
        a.branch(0x6700, to: levels) // BEQ.S
        a.w(0x7002) // MOVEQ #2,D0
        a.branch(0x6000, to: jumpPrgR) // BRA.S JumpPrg_
        a.place(levels)
        for song: UInt16 in [1, 2] {
            a.w(0x0C79, song)
            a.address(of: mSongCnt) // CMPI.W #song,M_SongCnt
            a.w(0x6700)
            a.displacement(to: playModR) // BEQ.W PlayModR_
        }
        a.branch(0x6000, to: playModOnce) // BRA.S PlayMod_

        // InitSnd ($5C4, line 345, DTP_InitSound): the song kept; the strange kind started by D0 -1; the
        // second and third the same, and the sound killed; the first kind's songs 1 and 2 by InitSub1,
        // with D1 nought or one, and its others by D4 = (song, less two if not nought) << 8 | $FF, and
        // the sound killed.
        let initSnd = a.placed()
        let notStrange2 = a.label(), levels2 = a.label(), sub = a.label(), shift = a.label()
        let sub1 = a.label(), sub2 = a.label()
        a.w(0x33ED, UInt16(DeliTrackerHost.dtgSndNum))
        a.address(of: mSongCnt) // MOVE.W dtg_SndNum(A5),M_SongCnt
        a.w(0x3E3A)
        a.displacement(to: mType) // MOVE.W M_Type(PC),D7
        a.w(0x0C47, 0x029A)
        a.branch(0x6600, to: notStrange2) // CMPI.W #666,D7; BNE.S
        a.w(0x48E7, 0xFFFE, 0x70FF, 0x207A) // MOVEM.L D0-D7/A0-A6,-(A7); MOVEQ #-1,D0; MOVEA.L M_Addr(PC),A0
        a.displacement(to: mAddr)
        a.w(0x4E90, 0x4CDF, 0x7FFF, 0x7000, 0x4E75) // JSR (A0); MOVEM.L (A7)+,D0-D7/A0-A6; MOVEQ #0,D0; RTS
        a.place(notStrange2)
        a.w(0x0C47, 0x0001)
        a.branch(0x6700, to: levels2) // CMPI.W #1,D7; BEQ.S
        a.w(0x70FF, 0x6100)
        a.displacement(to: jumpPrg) // MOVEQ #-1,D0; BSR.W JumpPrg
        a.branch(0x6000, to: killSnd) // BRA.S KillSnd
        a.place(levels2)
        a.w(0x0C79, 0x0001)
        a.address(of: mSongCnt)
        a.branch(0x6700, to: sub1) // CMPI.W #1,M_SongCnt; BEQ.S
        a.w(0x0C79, 0x0002)
        a.address(of: mSongCnt)
        a.branch(0x6700, to: sub2) // CMPI.W #2,M_SongCnt; BEQ.S
        a.place(sub) // InitSub_ ($60C, line 370)
        a.w(0x3839)
        a.address(of: mSongCnt) // MOVE.W M_SongCnt,D4
        a.w(0x4A44)
        a.branch(0x6700, to: shift) // TST.W D4; BEQ.S
        a.w(0x5544) // SUBQ.W #2,D4
        a.place(shift)
        a.w(0xE14C, 0x0004, 0x00FF, 0x6100) // LSL.W #8,D4; ORI.B #$FF,D4; BSR.W JumpPrg
        a.displacement(to: jumpPrg)
        a.branch(0x6000, to: killSnd) // BRA.S KillSnd
        a.place(sub1)
        a.w(0x7200, 0x6000) // MOVEQ #0,D1; BRA.W InitSub1
        a.displacement(to: initSub1)
        a.place(sub2)
        a.w(0x7201, 0x6000) // MOVEQ #1,D1; BRA.W InitSub1
        a.displacement(to: initSub1)
        // KillSnd ($630, line 387): the voices' volumes nought, their DMA off, the stop forgotten.
        a.place(killSnd)
        a.w(0x41F9, 0x00DF, 0xF000, 0x7000) // LEA $DFF000,A0; MOVEQ #0,D0
        a.w(0x3140, 0x00A8, 0x3140, 0x00B8, 0x3140, 0x00C8, 0x3140, 0x00D8) // MOVE.W D0,$Ax8(A0)
        a.w(0x317C, 0x000F, 0x0096, 0x4239) // MOVE.W #$F,$96(A0); CLR.B M_Stop
        a.address(of: mStop)
        a.w(0x4E75)

        // This player's, for a song that goes round: none found (an RTS); the module's word for its end
        // set, which is cleared and said; or its two addresses back where its start put them, from
        // elsewhere, said.
        let none = a.placed()
        a.w(0x4E75)
        let byFlag = a.placed()
        let flagDone = a.label()
        a.w(0x207A)
        a.displacement(to: flag) // MOVEA.L Flag(PC),A0
        a.w(0x4A50)
        a.branch(0x6700, to: flagDone) // TST.W (A0); BEQ.S
        a.w(0x4250) // CLR.W (A0)
        a.callSongEnd(eagleBase: eagleBase)
        a.place(flagDone)
        a.w(0x4E75)
        let byPosition = a.placed()
        let elsewhere = a.label(), positionDone = a.label()
        a.w(0x207A)
        a.displacement(to: position) // MOVEA.L Position(PC),A0
        a.w(0x2018, 0xB0BA) // MOVE.L (A0)+,D0; CMP.L Start(PC),D0
        a.displacement(to: start)
        a.branch(0x6600, to: elsewhere) // BNE.S
        a.w(0x2010, 0xB0BA) // MOVE.L (A0),D0; CMP.L Start+4(PC),D0
        a.displacement(to: start2)
        a.branch(0x6600, to: elsewhere) // BNE.S
        a.w(0x41FA)
        a.displacement(to: away) // LEA Away(PC),A0
        a.w(0x4A50)
        a.branch(0x6700, to: positionDone) // TST.W (A0); BEQ.S
        a.w(0x4250) // CLR.W (A0)
        a.callSongEnd(eagleBase: eagleBase)
        a.place(positionDone)
        a.w(0x4E75)
        a.place(elsewhere)
        a.w(0x41FA)
        a.displacement(to: away) // LEA Away(PC),A0
        a.w(0x50D0, 0x4E75) // ST (A0); RTS

        addrAt = a.addressOf(mAddr)
        typeAt = a.addressOf(mType)
        endTestAt = a.addressOf(endTest)
        flagAt = a.addressOf(flag)
        positionAt = a.addressOf(position)
        startAt = a.addressOf(start)
        noEnd = a.addressOf(none)
        flagEnd = a.addressOf(byFlag)
        positionEnd = a.addressOf(byPosition)
        initSoundAt = a.addressOf(initSnd)
        tick = a.addressOf(play)
    }

    /// The check's kind kept (`M_Type`, with `M_Addr`, as `ModChk` keeps them); `InitPlay` ($5B4), which
    /// only allocates the voices; and `SubSongNum` ($452, line 183): one song but for the first kind,
    /// which has three and as many more as the module's `CMPI.B #n,D4` (the first such, followed by a
    /// Bcc and a LEA, in its first $102 bytes) says.
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let g = DeliTrackerHost.globals
        let module = host.machine.peek32(g + DeliTrackerHost.dtgChkData)
        let size = Int(host.machine.peek32(g + DeliTrackerHost.dtgChkSize))
        var bytes = [UInt8](repeating: 0, count: min(size, 0x400))
        for i in bytes.indices { bytes[i] = host.machine.peek8(module + UInt32(i)) }
        guard let kind = Self.kind(bytes) else { throw .malformed("not a module of Darius Zendeh's") }
        host.machine.poke32(addrAt, module)
        host.machine.poke16(typeAt, kind.rawValue)
        var last = 0
        if kind == .levels {
            last = 2
            if let found = (0 ... 0x80).first(where: {
                let at = module + UInt32($0 * 2)
                return host.machine.peek16(at) == 0x0C04 && host.machine.peek8(at + 4) == 0x66
                    && host.machine.peek16(at + 6) == 0x41FA
            }) {
                last = Int(Int16(truncatingIfNeeded: 2 + Int(host.machine.peek16(module + UInt32(found * 2) + 2))))
            }
        }
        // The end of a song that goes round, looked for as the kind keeps it: the word the module's test
        // after a tick of a song played once reads (`MOVEQ #0,D4; LEA w(PC),A0; CMPI.W #1,(A0)`), or the
        // two longs its first LEA points at, which it loads its place in the music from and keeps it in.
        host.machine.poke32(endTestAt, noEnd)
        if kind == .strange {
            let at = module &+ 6 &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(module + 6))))
            if Int(at) + 8 <= host.memorySize {
                host.machine.poke32(positionAt, at)
                host.machine.poke32(endTestAt, positionEnd)
            }
        } else {
            var from = module
            while from < module + 0x200,
                  let test = WantedTeamSearch.find(host, [0x7800, 0x41FA], from: from, most: Int(module + 0x200 - from))
            {
                from = test + 2
                guard host.machine.peek32(test + 6) == 0x0C50_0001 else { continue }
                let at = test &+ 4 &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(test + 4))))
                if Int(at) + 2 <= host.memorySize {
                    host.machine.poke32(flagAt, at)
                    host.machine.poke32(endTestAt, flagEnd)
                }
                break
            }
        }
        return WantedTeamSongs(first: 0, count: last + 1)
    }

    /// `InitSnd`; and, for the end of a song that goes round, the module's word for it cleared (which
    /// its start clears but for the first kind's short songs, and some modules have set as they are)
    /// or where its place in its music is once it has started.
    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
        let flag = host.machine.peek32(flagAt)
        if flag != 0 { host.machine.poke16(flag, 0) }
        let at = host.machine.peek32(positionAt)
        if at != 0 {
            host.machine.poke32(startAt, host.machine.peek32(at))
            host.machine.poke32(startAt + 4, host.machine.peek32(at + 4))
        }
    }
}
