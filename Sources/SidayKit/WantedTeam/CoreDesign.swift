// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Core Design's music ("Core Design player module V1.1 (11 Mar
// 2004)", UADE's players/CoreDesign; its source, of V1.0, which does the same, is UADE's amigasrc/players/
// wanted_team/CoreDesign/"Core Design.asm"). The addresses given are of the player's hunk in UADE's file.

/// Core Design's music for the Amiga (Benn Daglish's, of 1989 and 1990, as the player's credit has it), as
/// Wanted Team adapted it: each module is his 68000 code that plays it, with its music and samples, in
/// one hunk with their standard header ("S.PHIPPS"), whose longs are the addresses of its routines for a
/// tick, for Paula's audio interrupts, to start a song and to stop, and its number of songs.
///
/// As the player plays it: the module's interrupt routine, which ends with RTE, made to end with RTS
/// and called through exec's SetIntVector for each of Paula's four interrupts; the module's writes to
/// INTREQ written to INTENA as well (`Patch0`, `Patch1`); each song started with D0 its number and D1 one
/// (to repeat); and a song ends when the module comes again to its code that reads a song's number to
/// start it (`Patch3`, which says so except while the song is being started).
typealias CoreDesignPlayer = WantedTeamPlayer<CoreDesign>

struct CoreDesign: WantedTeamRecipe {
    static let format = "Core Design"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -20.9 dB.)
    static let gain: Float = 0.31

    /// `Check3` ($428): the standard header with "S.PHIPPS", and its routines for a tick, the audio
    /// interrupts, a song's start and its stop, and its number of songs, not nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        WantedTeamHeader.isOne(data, id: Array("S.PHIPPS".utf8), required: [0, 1, 2, 3, 4])
    }

    private(set) var title = ""
    private(set) var author = ""

    /// The player's variables and routines, where they are assembled.
    private var playPtr: UInt32 = 0, initSongPtr: UInt32 = 0, endSongPtr: UInt32 = 0
    private var intAddress: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($146 to $1CE), in the player's order where its code relies on it.
        let play = a.variable(long: 0), initSong = a.variable(long: 0), endSong = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let songEndFlag = a.variable(word: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 1) }
        let oldVoices = (0 ..< 4).map { _ in a.variable(word: 0) }
        let scopes = a.scopes()
        let channels = (0 ..< 4).map { _ in a.variable(long: 0) }
        let structure = a.interruptStructure()
        let changeVolume = a.label()
        // `SetVolume` ($20E, DTP_Volume): the sides' volumes from DeliTracker's, and each voice's kept
        // volume written again. (D0 is both the count of voices and the volume, so only the first is.)
        let setNew = a.label()
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance)) // MOVE.W dtg_SndLBal(A5),D0
            a.w(0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x43FA)
        a.displacement(to: oldVoices[0]) // LEA OldVoice1(PC),A1
        a.w(0x7003, 0x49F9, 0x00DF, 0xF000) // MOVEQ #3,D0; LEA $DFF000,A4
        a.place(setNew)
        a.w(0x3019) // MOVE.W (A1)+,D0
        a.branch(0x6100, to: changeVolume) // BSR.B ChangeVolume
        a.w(0x49EC, 0x0010, 0x51C8) // LEA 16(A4),A4; DBF D0,SetNew
        a.displacement(to: setNew)
        a.w(0x4E75)
        // `ChangeVolume` ($248): the volume in D0 kept as the voice's (A4 its registers' base, $DFF000 on),
        // nought if it is muted, turned down by its side's balance, and written.
        a.place(changeVolume)
        let setIt = a.label()
        let sides = [leftVolume, rightVolume, rightVolume, leftVolume]
        for v in 0 ..< 4 {
            let next = a.label(), on = a.label()
            if v < 3 {
                a.w(0xB9FC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A4
                a.branch(0x6600, to: next) // BNE.B NoVoice
            }
            a.w(0x33C0)
            a.address(of: oldVoices[v]) // MOVE.W D0,OldVoice
            a.w(0x4A79)
            a.address(of: voices[v]) // TST.W Voice
            a.branch(0x6600, to: on) // BNE.B VoiceOn
            a.w(0x7000) // MOVEQ #0,D0
            a.place(on)
            a.w(0xC0FA)
            a.displacement(to: sides[v]) // MULU.W side(PC),D0
            if v < 3 {
                a.branch(0x6000, to: setIt) // BRA.B SetIt
                a.place(next)
            }
        }
        a.place(setIt)
        a.w(0xEC48, 0x3940, 0x00A8, 0x4E75) // LSR.W #6,D0; MOVE.W D0,$A8(A4); RTS
        // `SetAudioVector` ($518) and `InitSound` ($69C, DTP_InitSound): the kept volumes cleared, the
        // song started with its number in D0 and one in D1 (to repeat), `SongEndFlag` set while it
        // starts, and the module's audio interrupt made Paula's four's.
        let setAudioVector = a.setAudioVector(structure: structure, old: channels)
        initSoundAt = a.here
        a.clearScopes(scopes)
        a.w(0x41FA)
        a.displacement(to: oldVoices[0]) // LEA OldVoice1(PC),A0
        a.w(0x4298, 0x4290, 0x7201) // CLR.L (A0)+; CLR.L (A0); MOVEQ #1,D1
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum)) // MOVE.W dtg_SndNum(A5),D0
        a.w(0x43FA)
        a.displacement(to: songEndFlag) // LEA SongEndFlag(PC),A1
        a.w(0x50D1, 0x207A) // ST (A1); MOVEA.L InitSongPtr(PC),A0
        a.displacement(to: initSong)
        a.w(0x4E90, 0x43FA) // JSR (A0); LEA SongEndFlag(PC),A1
        a.displacement(to: songEndFlag)
        a.w(0x4251, 0x6000) // CLR.W (A1); BRA.W SetAudioVector
        a.displacement(to: setAudioVector)
        // `Interrupt` ($4CC, DTP_Interrupt).
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 4)
        tick = a.addressOf(tickRoutine)
        // `SongEnd` ($504), and `SetVol`, `SetAll` and `SetPer` ($2BE, $2EE, $32C), which tell the
        // scopes a voice's volume, sample and period (A4 or A6 its registers' base).
        let songEnd = a.songEndRoutine(eagleBase: eagleBase)
        let setVol = a.scopeRoutine(scopes, base: 4, field: 4, body: [0x3080]) // MOVE.W D0,(A0)
        // MOVE.L 14(A6),(A0); MOVE.W $12(A6),4(A0); MOVE.W 8(A6),6(A0)
        let setAll = a.scopeRoutine(scopes, base: 4, field: 0, body: [0x20AE, 0x000E, 0x316E, 0x0012, 0x0004, 0x316E, 0x0008, 0x0006])
        let setPer = a.scopeRoutine(scopes, base: 4, field: 3, body: [0x30AE, 0x0008]) // MOVE.W 8(A6),(A0)
        // The patches (`PatchTable`, $6F8), each with the module's code it is called in place of.
        // Code0, Patch0 ($724, $72A), and Code1, Patch1 ($738, $73E): an interrupt's request cleared,
        // and it let through as well.
        for code: UInt16 in [0x33C0, 0x33C2] {
            let patch = a.placed()
            a.w(code, 0x00DF, 0xF09A, code, 0x00DF, 0xF09C, 0x4E75) // MOVE.W Dn,$DFF09A; MOVE.W Dn,$DFF09C; RTS
            patches.add([code, 0x00DF, 0xF09C], patch: patch)
        }
        // Code2, Patch2 ($74C, $752): the status register not kept and the interrupts not shut out.
        let patch2 = a.placed()
        a.w(0x4E75)
        patches.add([0x40E7, 0x007C, 0x0700], patch: patch2) // MOVE.W SR,-(SP); ORI.W #$700,SR
        // Code3, Patch3 ($754, $75A): the song's number read as its start does it, and the song's end
        // said unless it is starting.
        let patch3 = a.placed()
        let noEnd = a.label()
        a.w(0x7400, 0x1400, 0xE742) // MOVEQ #0,D2; MOVE.B D0,D2; ASL.W #3,D2
        a.unlessStarting(flag: songEndFlag, skip: noEnd)
        a.w(0x6100)
        a.displacement(to: songEnd) // BSR.W SongEnd
        a.place(noEnd)
        a.w(0x4E75)
        patches.add([0x7400, 0x1400, 0xE742], patch: patch3)
        // Code4, Patch4 ($76E, $776): a sample's length and start, as they are, and told the scopes.
        let patch4 = a.placed()
        a.w(0x3D58, 0x0012, 0x2D48, 0x000E, 0x6100) // MOVE.W (A0)+,$12(A6); MOVE.L A0,14(A6); BSR.W SetAll
        a.displacement(to: setAll)
        a.w(0x4E75)
        patches.add([0x3D58, 0x0012, 0x2D48, 0x000E], patch: patch4)
        // Code5, Patch5 ($784, $78A): a volume halved and written through `ChangeVolume`.
        let patch5 = a.placed()
        a.w(0xE248, 0x6100) // LSR.W #1,D0; BSR.W ChangeVolume
        a.displacement(to: changeVolume)
        a.w(0x6100)
        a.displacement(to: setVol) // BSR.W SetVol
        a.w(0x4E75)
        patches.add([0xE248, 0x3940, 0x00A8], patch: patch5)
        // Code6, Patch6 ($796, $79C): a period, as it is, and told the scopes.
        let patch6 = a.placed()
        a.w(0x3D70, 0x0000, 0x0008, 0x6100) // MOVE.W 0(A0,D0.W),8(A6); BSR.W SetPer
        a.displacement(to: setPer)
        a.w(0x4E75)
        patches.add([0x3D70, 0x0000, 0x0008], patch: patch6)
        patches.assemble(&a)
        playPtr = a.addressOf(play)
        initSongPtr = a.addressOf(initSong)
        endSongPtr = a.addressOf(endSong)
        intAddress = a.addressOf(structure) + 18
    }

    /// `InitPlayer` ($5E0).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let module = try WantedTeamHeader.load(&host)
        let h = WantedTeamHeader.longs(host, module: module, count: 9)
        let (play, audio, initSong, endSong, songs) = (h[0], h[1], h[2], h[3], h[4])
        title = WantedTeamHeader.string(host, at: h[7])
        author = WantedTeamHeader.string(host, at: h[8])
        host.machine.poke32(playPtr, play)
        host.machine.poke32(initSongPtr, initSong)
        host.machine.poke32(endSongPtr, endSong)
        host.machine.poke32(intAddress, audio)
        // From the routine to stop on, to the first long $3BC03865 (which ends the module's code): each RTE
        // made an RTS (the audio interrupt's, which is called as a routine), and each MOVE.W (SP)+,SR a
        // NOP ($64A); and there the patches made.
        var at = endSong
        while host.machine.peek32(at) != 0x3BC0_3865 {
            guard Int(at) + 8 <= host.memorySize - DeliTrackerHost.room else {
                throw .malformed("a module of Core Design's whose code is not as the player looks for")
            }
            let word = host.machine.peek16(at)
            if word == 0x4E73 { host.machine.poke16(at, 0x4E75) }
            if word == 0x46DF { host.machine.poke16(at, 0x4E71) }
            at += 2
        }
        patches.apply(&host, from: endSong, length: at &- endSong)
        return WantedTeamSongs(first: 0, count: Int(min(songs, 256)))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
