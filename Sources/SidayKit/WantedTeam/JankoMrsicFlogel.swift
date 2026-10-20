// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Janko Mrsic-Flogel's music ("Janko Mrsic-Flogel player module
// V1.0 (25 Sep 2001)", UADE's players/JankoMrsicFlogel, whose source is UADE's amigasrc/players/
// wanted_team/JankoMrsic-Flogel/src/"Janko Mrsic-Flogel_v1.asm"). The addresses given are of the player's
// hunk in UADE's file.

/// Janko Mrsic-Flogel's music for the Amiga (of 1986 to 1988, as the player's credit has it), as Wanted
/// Team adapted it: each module is his 68000 code that plays it, with its music, in one hunk with their
/// standard header ("J.FLOGEL"), whose longs are the addresses of its routines for a tick and to start
/// a song, and its number of songs. Its three voices play short waves of its own.
///
/// As the player plays it: the module's writes of a voice's wave to AUDxDAT (`MOVE.L #wave,$DFF0AA`)
/// made writes of the voice's start, with the length written after it or two words; each period
/// written followed by a volume of 56 (the player's patches write it; the module writes none); and a
/// song ends when the module turns the voices' DMA off (`MOVE.W #15,$DFF096`).
typealias JankoMrsicFlogelPlayer = WantedTeamPlayer<JankoMrsicFlogel>

struct JankoMrsicFlogel: WantedTeamRecipe {
    static let format = "Janko Mrsic-Flogel"

    /// `Check3` ($2EA): the standard header with "J.FLOGEL", and its routines for a tick and a song's
    /// start, and its number of songs, not nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        WantedTeamHeader.isOne(data, id: Array("J.FLOGEL".utf8), required: [0, 1, 2])
    }

    private(set) var title = ""
    private(set) var author = ""

    private var playPtr: UInt32 = 0, initSongPtr: UInt32 = 0
    private var initSoundAt: UInt32 = 0, tick: UInt32 = 0
    /// Where the immediates of each of the six patches of a wave's start are (in its pattern, and its
    /// patch's two).
    private var waveAt: [UInt32] = []
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($158 to $172).
        let play = a.variable(long: 0), initSong = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let songEndFlag = a.variable(word: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // `Left1`, `Right1`, `Right2` ($22A to $248): the volume in D0 turned down by its side's balance,
        // and nought if its voice is muted.
        let ex = a.label()
        var sides: [Int] = []
        for (side, voice) in [(leftVolume, voices[0]), (rightVolume, voices[1]), (rightVolume, voices[2])] {
            sides.append(a.placed())
            a.w(0xC0FA)
            a.displacement(to: side) // MULU.W side(PC),D0
            a.w(0xC07A)
            a.displacement(to: voice) // AND.W Voice(PC),D0
            if voice != voices[2] { a.branch(0x6000, to: ex) } // BRA.S Ex
        }
        a.place(ex)
        a.w(0xEC48, 0x4E75) // LSR.W #6,D0; RTS
        // `InitSound` ($506, DTP_InitSound): the song started with its number in D0, `SongEndFlag` set
        // while it starts (A3 pointing at it).
        initSoundAt = a.here
        a.clearScopes(scopes)
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum)) // MOVE.W dtg_SndNum(A5),D0
        a.w(0x47FA)
        a.displacement(to: songEndFlag) // LEA SongEndFlag(PC),A3
        a.w(0x50D3, 0x207A) // ST (A3); MOVEA.L InitSongPtr(PC),A0
        a.displacement(to: initSong)
        a.w(0x4E90, 0x4253, 0x4E75) // JSR (A0); CLR.W (A3); RTS
        // `Interrupt` ($38E, DTP_Interrupt).
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 3)
        tick = a.addressOf(tickRoutine)
        // The patches (`PatchTable`, $546), each with the module's code it is called in place of.
        // Code0, Patch0 ($584, $58C): the voices' DMA turned off, and the song's end said unless it is
        // starting.
        let patch0 = a.placed(), noEnd = a.label()
        a.unlessStarting(flag: songEndFlag, skip: noEnd)
        a.callSongEnd(eagleBase: eagleBase)
        a.place(noEnd)
        a.w(0x33FC, 0x000F, 0x00DF, 0xF096, 0x4E75) // MOVE.W #15,$DFF096; RTS
        patches.add([0x33FC, 0x000F, 0x00DF, 0xF096], patch: patch0)
        // Code1 to Code3, Patch1 to Patch3 ($5B0 to $638): a voice's period written, and then a volume of
        // 56 through its side's balance (and both told the scopes).
        for v in 0 ..< 3 {
            let patch = a.placed()
            let base = 0xF0A0 + UInt16(v * 16)
            a.w(0x33C1, 0x00DF, base + 6) // MOVE.W D1,$DFF0x6
            a.w(0x48E7, 0x8040, 0x43FA) // MOVEM.L A1/D0,-(SP); LEA StructAdr(PC),A1
            a.displacement(to: scopes[0])
            a.w(0x3341, UInt16(6 + v * 18)) // MOVE.W D1,UPS_VoiceNPer(A1)
            a.w(0x7038, 0x6100) // MOVEQ #56,D0; BSR.W side
            a.displacement(to: sides[v])
            a.w(0x33C0, 0x00DF, base + 8) // MOVE.W D0,$DFF0x8
            a.w(0x3340, UInt16(8 + v * 18)) // MOVE.W D0,UPS_VoiceNVol(A1)
            a.w(0x4CDF, 0x0201, 0x4E75) // MOVEM.L (SP)+,D0/A1; RTS
            patches.add([0x33C1, 0x00DF, base + 6], patch: patch)
        }
        // Code4 to Code9, Patch4 to Patch9 ($63A to $788): a wave written to AUDxDAT made its start, with
        // the length given with it (Code4, 6, 8), or as it was (Code5, 7, 9). The waves' addresses are
        // found in the module and put in by `initPlayer` (and told the scopes).
        var immediates: [UInt32] = []
        for v in 0 ..< 3 {
            let base = 0xF0A0 + UInt16(v * 16)
            for withLength in [true, false] {
                let patch = a.placed()
                immediates.append(a.here + 2)
                a.w(0x23FC, 0x5754, 0x5754, 0x00DF, base) // MOVE.L #'WTWT',$DFF0x0
                if withLength { a.w(0x33FC, 0x0010, 0x00DF, base + 4) } // MOVE.W #$10,$DFF0x4
                a.w(0x48E7, 0x8040, 0x43FA) // MOVEM.L A1/D0,-(SP); LEA StructAdr(PC),A1
                a.displacement(to: scopes[0])
                immediates.append(a.here + 2)
                a.w(0x237C, 0x5754, 0x5754, UInt16(v * 18)) // MOVE.L #'WTWT',UPS_VoiceNAdr(A1)
                // MOVEQ #16,D0 (or 4); MOVE.W D0,UPS_VoiceNLen(A1); MOVEM.L (SP)+,D0/A1; RTS
                a.w(withLength ? 0x7010 : 0x7004, 0x3340, UInt16(4 + v * 18), 0x4CDF, 0x0201, 0x4E75)
                patches.add([0x23FC, 0x5754, 0x5754, 0x00DF, base + 10] + (withLength ? [0x33FC, 0x0010, 0x00DF, base + 4] : []),
                            patch: patch)
            }
        }
        patches.assemble(&a)
        waveAt = []
        for k in 0 ..< 6 { waveAt += [patches.patternAt[4 + k] + 2, immediates[k * 2], immediates[k * 2 + 1]] }
        playPtr = a.addressOf(play)
        initSongPtr = a.addressOf(initSong)
    }

    /// `InitPlayer` ($3CC).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let module = try WantedTeamHeader.load(&host)
        let h = WantedTeamHeader.longs(host, module: module, count: 6)
        let (play, initSong, songs) = (h[0], h[1], h[2])
        title = WantedTeamHeader.string(host, at: h[4])
        author = WantedTeamHeader.string(host, at: h[5])
        host.machine.poke32(playPtr, play)
        host.machine.poke32(initSongPtr, initSong)
        // The waves' addresses ($414 to $4E2): from the routine for a tick, the long before each of the
        // first two writes to $DFF0AA, then two to $DFF0BA, then two to $DFF0CA, each search going on from
        // past the last one found.
        var at = play
        for k in 0 ..< 6 {
            let register = 0x00DF_F0AA + UInt32(k / 2) * 16
            guard let found = WantedTeamSearch.find(host, long: register, from: at, most: host.memorySize), found >= 4 else {
                throw .malformed("a module of Janko Mrsic-Flogel's whose code is not as the player looks for")
            }
            let wave = host.machine.peek32(found - 4)
            for i in 0 ..< 3 { host.machine.poke32(waveAt[k * 3 + i], wave) }
            at = found + 4
        }
        // `ModuleChange` ($1C4): the patches made in the 1,200 bytes from the routine for a tick.
        patches.apply(&host, from: play, length: 1200)
        return WantedTeamSongs(first: 0, count: Int(min(songs, 256)))
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
