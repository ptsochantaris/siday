// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Desire's music ("Desire player module V1.0 (30 Apr 2002)",
// UADE's players/Desire), whose source is in UADE's amigasrc/players/wanted_team/Desire/src/Desire_v1.asm:
// its lines are given.

import SidayFoundation
import SidayM68000

/// The music of Desire (Dentons, 1993 and 1994, as the player's credit has it) for games of the Amiga's:
/// each module is the 68000 code that plays it, with its music and samples, as the game had it, with no
/// header of Wanted Team's. It begins with four voices' records of 16 bytes, whose first byte the code
/// reads for the song to start (64 and the song's number, from one); then its routine for a tick, which
/// begins `LEA x(PC),A4; LEA $DFF000,A2; MOVE.W #$FF,$9E(A2); LEA module(PC),A0`.
///
/// As the player plays it: each of the module's writes of a voice's period, volume, sample and length
/// patched to tell EaglePlayer's scopes (and the volume turned down by the balance, which is none); a
/// voice that stops itself noted, and the song's end said once all four have stopped. One module of
/// Power Drive's has a mistake that the player puts right. The player has no end for a song that
/// repeats; siday's is its voices' going back as well as their stops: a voice jumping in its list of
/// patterns, or playing a stretch of it again for ever, counts as the end of its music.
typealias DesirePlayer = WantedTeamPlayer<Desire>

struct Desire: WantedTeamRecipe {
    static let format = "Desire"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -19.9 dB.)
    static let gain: Float = 0.28

    /// `Check2` (lines 234-269): longer than 2,500 bytes; the four voices' records' third longs $00010101;
    /// within the 400 bytes after them a LEA x(PC),A4, which the module's routine for a tick begins
    /// with, followed by `LEA $DFF000,A2; MOVE.W #$FF,$9E(A2); LEA module(PC),A0`, the last pointing
    /// at the module's start.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count > 2500 else { return false }
        func long(_ at: Int) -> UInt32 { WantedTeamHeader.long(data, at) }
        func word(_ at: Int) -> UInt16 { at + 2 <= data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0 }
        for v in 0 ..< 4 where long(8 + v * 16) != 0x0001_0101 { return false }
        var at = 72
        while at != 72 + 400, word(at) != 0x49FA { at += 2 }
        guard at != 72 + 400, long(at + 4) == 0x45F9_00DF, long(at + 8) == 0xF000_357C, long(at + 12) == 0x00FF_009E,
              word(at + 16) == 0x41FA
        else { return false }
        return at + 18 + Int(Int16(bitPattern: word(at + 18))) == 0
    }

    let title = "", author = ""

    private var modulePtr: UInt32 = 0, playPtr: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables (lines 46-75): the module and its routine for a tick, the globals, the voices'
        // stops (four bytes), the sides' volumes, the voices' muting, the scopes.
        let module = a.variable(long: 0), play = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let songEnd = a.variable(long: 0x5754_5754)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // `Interrupt` (lines 120-139, DTP_Interrupt).
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 4)
        tick = a.addressOf(tickRoutine)
        // `InitSound` (lines 408-424, DTP_InitSound): the scopes cleared, the voices' stops counted afresh,
        // and 64 and the song's number (from one) put in each voice's record.
        initSoundAt = a.here
        a.clearScopes(scopes)
        a.w(0x41FA)
        a.displacement(to: songEnd) // LEA SongEnd(PC),A0
        a.w(0x20BC, 0x5754, 0x5754) // MOVE.L #'WTWT',(A0)
        a.w(0x7040, 0xD06D, UInt16(DeliTrackerHost.dtgSndNum), 0x207A) // MOVEQ #64,D0; ADD.W dtg_SndNum(A5),D0; MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x1080, 0x1140, 0x0010, 0x1140, 0x0020, 0x1140, 0x0030, 0x4E75) // MOVE.B D0,(A0); 16(A0); 32(A0); 48(A0); RTS
        // `SetVolume` (lines 430-444, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `ChangeVolume` (lines 446-478): the volume in D1, seven bits, of the voice whose registers' base
        // A1 holds ($DFF000 on), turned down by its side's balance and nought if it is muted.
        let changeVolume = a.placed()
        let ex = a.label(), exit = a.label()
        let left1 = a.label(), right1 = a.label(), right2 = a.label()
        a.w(0x2F02, 0x0241, 0x007F, 0x2409) // MOVE.L D2,-(A7); ANDI.W #$7F,D1; MOVE.L A1,D2
        for (v, to) in [(0, left1), (1, right1), (2, right2)] {
            a.w(0x0C42, 0xF000 + UInt16(v * 16)) // CMPI.W #$F0x0,D2
            a.branch(0x6700, to: to) // BEQ.S
        }
        a.w(0x0C42, 0xF030) // CMPI.W #$F030,D2
        a.branch(0x6600, to: exit) // BNE.S Exit2
        for (place, side, voice) in [(nil, leftVolume, voices[3]), (left1, leftVolume, voices[0]),
                                     (right1, rightVolume, voices[1]), (right2, rightVolume, voices[2])]
        {
            if let place { a.place(place) }
            a.w(0xC2FA)
            a.displacement(to: side) // MULU.W side(PC),D1
            a.w(0xC27A)
            a.displacement(to: voice) // AND.W Voice(PC),D1
            if voice != voices[2] { a.branch(0x6000, to: ex) } // BRA.S Ex
        }
        a.place(ex)
        a.w(0xEC49) // LSR.W #6,D1
        a.place(exit)
        a.w(0x241F, 0x4E75) // MOVE.L (A7)+,D2; RTS
        // The scopes' routines (lines 482-554): the volume in D1, the address in D2, the length in D3, the
        // period in D1, of the voice A1 points at.
        let setVol = a.scopeRoutine(scopes, base: 1, field: 4, body: [0x3081]) // MOVE.W D1,(A0)
        let setAdr = a.scopeRoutine(scopes, base: 1, field: 0, body: [0x2082]) // MOVE.L D2,(A0)
        let setLen = a.scopeRoutine(scopes, base: 1, field: 2, body: [0x3083]) // MOVE.W D3,(A0)
        let setPer = a.scopeRoutine(scopes, base: 1, field: 3, body: [0x3081]) // MOVE.W D1,(A0)
        // The patches (`PatchTable`, lines 598-721), each a call in place of the module's code it is put in.
        func patch(_ a: inout AmigaAssembly, _ code: [UInt16], _ calls: [Int], then after: [UInt16] = []) -> Int {
            let p = a.placed()
            for word in code { a.w(word) }
            for call in calls {
                a.w(0x6100)
                a.displacement(to: call) // BSR.W
            }
            for word in after { a.w(word) }
            a.w(0x4E75)
            return p
        }
        // Patch0: a period, LSR.W #1,D1; MOVE.W D1,$A6(A1).
        patches.add([0xE249, 0x3341, 0x00A6], patch: patch(&a, [0xE249, 0x3341, 0x00A6], [setPer]))
        // Patch1: a volume, ANDI.W #$FF,D1; MOVE.W D1,$A8(A1), through `ChangeVolume`.
        patches.add([0x0241, 0x00FF, 0x3341, 0x00A8], patch: patch(&a, [0x0241, 0x00FF], [changeVolume, setVol], then: [0x3341, 0x00A8]))
        // Patch2: a length, SUBI.W #$80,D3; MOVE.W D3,$A4(A1).
        patches.add([0x0443, 0x0080, 0x3343, 0x00A4], patch: patch(&a, [0x0443, 0x0080, 0x3343, 0x00A4], [setLen]))
        // Patch3: a length, MOVE.W 0(A3,D1.W),$A4(A1) (D3 kept round its call).
        patches.add([0x3373, 0x1000, 0x00A4], patch: patch(&a, [0x3373, 0x1000, 0x00A4, 0x2F03, 0x3633, 0x1000], [setLen], then: [0x261F]))
        // Patch4: an address, ADDI.L #$80,D2; MOVE.L D2,$A0(A1).
        patches.add([0x0682, 0x0000, 0x0080, 0x2342, 0x00A0], patch: patch(&a, [0x0682, 0x0000, 0x0080, 0x2342, 0x00A0], [setAdr]))
        // Patch5: an address, ADD.L A3,D2; MOVE.L D2,$A0(A1).
        patches.add([0xD48B, 0x2342, 0x00A0], patch: patch(&a, [0xD48B, 0x2342, 0x00A0], [setAdr]))
        // Patch6 and `SongEndTest`: a voice stopping itself, CLR.W $A8(A1); MOVE.B #$80,0(A0); its byte of
        // `SongEnd` cleared, and once all four are, the song's end said and the count begun again.
        let patch6 = a.placed()
        let test = a.label(), skip = a.label(), songEndTest = a.label()
        a.w(0x4269, 0x00A8, 0x10BC, 0x0080) // CLR.W $A8(A1); MOVE.B #$80,(A0)
        a.place(songEndTest)
        a.w(0x48E7, 0x0084, 0x41FA) // MOVEM.L A0/A5,-(A7); LEA SongEnd(PC),A0
        a.displacement(to: songEnd)
        for v in 0 ..< 4 {
            let next = a.label()
            a.w(0xB3FC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A1
            a.branch(0x6600, to: v < 3 ? next : test) // BNE.B
            if v == 0 { a.w(0x4210) } else { a.w(0x4228, UInt16(v)) } // CLR.B v(A0)
            if v < 3 {
                a.branch(0x6000, to: test) // BRA.B test
                a.place(next)
            }
        }
        a.place(test)
        a.w(0x4A90) // TST.L (A0)
        a.branch(0x6600, to: skip) // BNE.B SkipEnd
        a.w(0x20BC, 0x5754, 0x5754, 0x2A7A) // MOVE.L #'WTWT',(A0); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x206D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E90) // MOVEA.L dtg_SongEnd(A5),A0; JSR (A0)
        a.place(skip)
        a.w(0x4CDF, 0x2100, 0x4E75) // MOVEM.L (A7)+,A0/A5; RTS
        patches.add([0x4269, 0x00A8, 0x117C, 0x0080, 0x0000], patch: patch6)
        // And siday's, for the songs that repeat, which the player does not end: a voice's list of
        // patterns jumped in (its command $8C, CLR.L D1; MOVE.B 1(A3),D1; BTST #6,D1) counted as its
        // stop is, so that the song's end is said once each voice has stopped or gone back.
        let jump = a.placed()
        a.w(0x4281, 0x122B, 0x0001, 0x6100) // CLR.L D1; MOVE.B 1(A3),D1; BSR.W SongEndTest
        a.displacement(to: songEndTest)
        a.w(0x0801, 0x0006, 0x4E75) // BTST #6,D1; RTS
        patches.add([0x4281, 0x122B, 0x0001, 0x0801, 0x0006], patch: jump)
        // And a voice's pattern gone back to its mark with no count of times to go (its command $82 with
        // nought at 11(A0), which plays from the mark for ever: MOVE.W 12(A0),14(A0)), counted the same.
        let again = a.placed()
        let counted = a.label()
        a.w(0x3168, 0x000C, 0x000E, 0x4A28, 0x000B) // MOVE.W 12(A0),14(A0); TST.B 11(A0)
        a.branch(0x6600, to: counted) // BNE.S
        a.w(0x6100)
        a.displacement(to: songEndTest) // BSR.W SongEndTest
        a.place(counted)
        a.w(0x4E75)
        patches.add([0x3168, 0x000C, 0x000E], patch: again)
        patches.assemble(&a)
        modulePtr = a.addressOf(module)
        playPtr = a.addressOf(play)
    }

    /// `InitPlayer` (lines 284-394).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let (module, size) = try Self.listData(&host)
        func refuse() -> TuneError { .malformed("a module of Desire's whose code is not as the player looks for") }
        let end = Int(size)
        func find(_ word: UInt16, from: UInt32) throws(TuneError) -> UInt32 {
            guard from >= module, let at = WantedTeamSearch.find(host, [word], from: from, most: end - Int(from - module)) else {
                throw refuse()
            }
            return at
        }
        func relative(_ at: UInt32) -> UInt32 { at &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(at)))) }
        // The routine for a tick: the first LEA x(PC),A4 from 240 bytes in.
        let play = try find(0x49FA, from: module + 240)
        host.machine.poke32(modulePtr, module)
        host.machine.poke32(playPtr, play)
        // The songs: the table the first LEA x(PC),A3 after it points at, counted from its second byte up to
        // a nought, or to a byte the same as the one after it.
        let songsAt = try find(0x47FA, from: play + 2) + 2
        var at = relative(songsAt) &+ 1
        var songs = 0
        while songs < 256 {
            let byte = host.machine.peek8(at)
            at &+= 1
            if byte == 0 { break }
            songs += 1
            if byte == host.machine.peek8(at) { break }
        }
        // The samples' lengths and offsets: the LEA x(PC),A3s after the first ASL.W #1,D1 that follows; and
        // how far the offsets are shifted, from the instruction after the next LEA x(PC),A3.
        let asl = try find(0xE341, from: songsAt + 20)
        let lengthsAt = try find(0x47FA, from: asl + 2) + 2
        let lengths = relative(lengthsAt)
        let offsetsAt = try find(0x47FA, from: lengthsAt) + 2
        let offsets = relative(offsetsAt)
        let shiftAt = try find(0x47FA, from: offsetsAt) + 4
        let field = UInt32(host.machine.peek16(shiftAt) & 0xE00)
        let shift = field == 0 ? 8 : field >> 9
        // The module's size as the player works it out: the largest offset's sample's end. One module of
        // Power Drive's, of that size, has its code put right ($FFE0 at 470 made $FFD8).
        // (Its search for the largest goes on until it comes to the lengths, or for ever.)
        guard offsets <= lengths, lengths - offsets <= 0x1000, (lengths - offsets) % 2 == 0, lengths <= module + size else {
            throw refuse()
        }
        let back = Int32(Int16(truncatingIfNeeded: Int32(bitPattern: lengths &- offsets)))
        var largest = UInt32(host.machine.peek16(offsets)), largestLength: UInt32 = 0
        var o = offsets
        while o != lengths {
            let value = UInt32(host.machine.peek16(o))
            o += 2
            if value > largest {
                largest = value
                largestLength = UInt32(host.machine.peek16(UInt32(bitPattern: Int32(bitPattern: o) &- 2 &+ back)))
            }
        }
        if largest << shift &+ largestLength * 2 == 58664, host.machine.peek16(module + 470) == 0xFFE0 {
            host.machine.poke16(module + 470, 0xFFD8)
        }
        // `ModuleChange` (lines 81-100): the patches made in the 2,000 bytes from the routine for a tick.
        patches.apply(&host, from: play, length: 2000)
        return WantedTeamSongs(first: 1, count: max(1, songs))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }

    /// The players' `dtg_GetListData` of the module, number nought: its address and its size, as UADE's
    /// host gives them.
    static func listData(_ host: inout DeliTrackerHost) throws(TuneError) -> (at: UInt32, size: UInt32) {
        let size = try host.call(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgGetListData), with: [(0, 0)])
        return (host.machine.cpu.registers[8], size)
    }
}
