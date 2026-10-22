// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Benn Daglish's SID-like music ("Benn Daglish SID player module
// V1.1 (11 Mar 2004)", UADE's players/BenDaglish-SID, whose source is UADE's amigasrc/players/wanted_team/
// BennDaglishSID/"Benn Daglish SID_v2.asm"). The addresses given are of the player's hunk in UADE's file.

import SidayFoundation

/// The music of Benn Daglish's for the Amiga that Wanted Team's player calls his "SID" music (of 1987
/// and 1988, as its credit has it), as they adapted it: each module is his 68000 code that plays it,
/// with its music and its waves, in one hunk with their standard header ("DAGLISH!"), whose longs are
/// the addresses of its routines for a tick, for Paula's audio interrupts and to start a song, and its
/// number of songs. Its three voices play short waves, their volumes written by its audio interrupt.
/// (His other music for the Amiga is `DaglishPlayer`'s, and Core Design's `CoreDesign`'s.)
///
/// As the player plays it: the module's interrupt routine made to end with RTS and called through
/// exec's SetIntVector for each of Paula's four interrupts; its wait for the DMA (a DBRA on itself)
/// made eight lines of the beam; and a song ends when the module turns the voices' DMA off
/// (`MOVE.W #15,$96(A5)`), or when the byte it keeps at $11 of the place it starts a song with in A4
/// is nought after a tick, when the player stops the song, says so, and starts it again.
typealias DaglishSIDPlayer = WantedTeamPlayer<DaglishSID>

struct DaglishSID: WantedTeamRecipe {
    static let format = "Benn Daglish SID"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -23.7 dB.)
    static let gain: Float = 0.43

    /// `Check3` ($1F0): the standard header with "DAGLISH!", and its routines for a tick, the audio
    /// interrupts and a song's start, and its number of songs, not nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        WantedTeamHeader.isOne(data, id: Array("DAGLISH!".utf8), required: [0, 1, 2, 3])
    }

    private(set) var title = ""
    private(set) var author = ""

    private var playPtr: UInt32 = 0, initSongPtr: UInt32 = 0, intAddress: UInt32 = 0, volumesAt: UInt32 = 0
    private var initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($12E to $152), in the player's order where its code relies on it: the voices'
        // volumes' addresses, then `SongEndFlag` and `A4_Base`, then the scopes' structure.
        let play = a.variable(long: 0), initSong = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let volumes = (0 ..< 3).map { _ in a.variable(long: 0) }
        let songEndFlag = a.variable(word: 0)
        let a4Base = a.variable(long: 0)
        let scopes = a.scopes()
        let channels = (0 ..< 4).map { _ in a.variable(long: 0) }
        let structure = a.interruptStructure()
        // `SongEnd` ($31A), `DMAWait` ($32E), `SetAudioVector` ($34C) and `ClearAudioVector` ($39A).
        let songEnd = a.songEndRoutine(eagleBase: eagleBase)
        let dmaWait = a.dmaWait(lines: 8)
        let setAudioVector = a.setAudioVector(structure: structure, old: channels)
        let clearAudioVector = a.clearAudioVector(old: channels)
        // `InitSound` ($4A8, DTP_InitSound): the song started with its number in D0, `SongEndFlag` set
        // while it starts; A4 as the start leaves it kept, and the module's audio interrupt made Paula's
        // four's.
        let initSound = a.placed()
        a.clearScopes(scopes)
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum)) // MOVE.W dtg_SndNum(A5),D0
        a.w(0x43FA)
        a.displacement(to: songEndFlag) // LEA SongEndFlag(PC),A1
        a.w(0x50D1, 0x207A) // ST (A1); MOVEA.L InitSongPtr(PC),A0
        a.displacement(to: initSong)
        a.w(0x4E90, 0x43FA) // JSR (A0); LEA SongEndFlag(PC),A1
        a.displacement(to: songEndFlag)
        a.w(0x4259, 0x228C, 0x6000) // CLR.W (A1)+; MOVE.L A4,(A1); BRA.W SetAudioVector
        a.displacement(to: setAudioVector)
        // `EndSound` ($4D2): the audio interrupts given back, the voices' DMA off and their volumes nought.
        let endSound = a.placed()
        a.w(0x6100)
        a.displacement(to: clearAudioVector) // BSR.W ClearAudioVector
        a.w(0x41F9, 0x00DF, 0xF000, 0x317C, 0x000F, 0x0096, 0x7000) // LEA $DFF000,A0; MOVE.W #15,$96(A0); MOVEQ #0,D0
        a.w(0x3140, 0x00A8, 0x3140, 0x00B8, 0x3140, 0x00C8, 0x3140, 0x00D8, 0x4E75) // MOVE.W D0,$A8(A0) ...; RTS
        // `Interrupt` ($298, DTP_Interrupt): the module's tick, the voices' volumes told the scopes;
        // then, if the byte at $11 of the place its start left in A4 is nought, the song stopped, its
        // end said, and the song started again.
        tick = a.here
        let noEnd = a.label()
        a.beginTick(play: play, scopes: scopes, voices: 4)
        a.w(0x43FA)
        a.displacement(to: scopes[0]) // LEA StructAdr(PC),A1
        for v in 0 ..< 3 {
            a.w(0x247A)
            a.displacement(to: volumes[v]) // MOVEA.L VolNPtr(PC),A2
            // MOVEQ #0,D0; MOVE.B (A2),D0; ROL.W #2,D0; MOVE.W D0,UPS_VoiceNVol(A1)
            a.w(0x7000, 0x1012, 0xE558, 0x3340, UInt16(8 + v * 18))
        }
        a.w(0x207A)
        a.displacement(to: a4Base) // MOVEA.L A4_Base(PC),A0
        a.w(0x4A28, 0x0011) // TST.B $11(A0)
        a.branch(0x6600, to: noEnd) // BNE.B NoEnd
        a.w(0x6100)
        a.displacement(to: endSound) // BSR.W EndSound
        a.w(0x2A7A)
        a.displacement(to: eagleBase) // MOVEA.L EagleBase(PC),A5
        // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1); BSR.W InitSound
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91, 0x6100)
        a.displacement(to: initSound)
        a.place(noEnd)
        a.endTick(scopes: scopes)
        // The patches (`PatchTable`, $4F6), each with the module's code it is called in place of.
        // Code0, Patch0 ($516, $51C): the voices' DMA turned off, and the song's end said unless it is
        // starting.
        let patch0 = a.placed(), noEnd0 = a.label()
        a.w(0x3B7C, 0x000F, 0x0096) // MOVE.W #15,$96(A5)
        a.unlessStarting(flag: songEndFlag, skip: noEnd0)
        a.w(0x6100)
        a.displacement(to: songEnd) // BSR.W SongEnd
        a.place(noEnd0)
        a.w(0x4E75)
        patches.add([0x3B7C, 0x000F, 0x0096], patch: patch0)
        // Code1 to Code3, Patch1 to Patch3 ($530 to $594): a voice's wave and its length, as they are,
        // and told the scopes.
        for (address, length, v) in [(UInt16(0x2B44), UInt16(0x3B43), UInt16(0)), (0x2B45, 0x3B42, 1), (0x2B46, 0x3B41, 2)] {
            let patch = a.placed()
            let code: [UInt16] = [address, 0x00A0 + v * 16, length, 0x00A4 + v * 16] // MOVE.L Dn,$Ax(A5); MOVE.W Dm,$Ax+4(A5)
            for word in code { a.w(word) }
            a.w(0x2F09, 0x43FA) // MOVE.L A1,-(SP); LEA StructAdr(PC),A1
            a.displacement(to: scopes[0])
            // MOVE.L Dn,UPS_VoiceNAdr(A1); MOVE.W Dm,UPS_VoiceNLen(A1) (the same moves, to d16(A1));
            // MOVEA.L (SP)+,A1; RTS
            a.w(address & 0xF1FF | 0x0200, v * 18, length & 0xF1FF | 0x0200, 4 + v * 18, 0x225F, 0x4E75)
            patches.add(code, patch: patch)
        }
        // Code4, Patch4 ($596, $5A2): the module's wait for the DMA, a DBRA on itself, made the player's
        // `DMAWait` (once the voices' periods are told the scopes), and the word after it read as the
        // module reads it.
        let patch4 = a.placed()
        a.w(0x48E7, 0x0060, 0x43FA) // MOVEM.L A1/A2,-(SP); LEA StructAdr(PC),A1
        a.displacement(to: scopes[0])
        for v in 0 ..< 3 {
            a.w(0x247A)
            a.displacement(to: volumes[v]) // MOVEA.L VolNPtr(PC),A2
            a.w(0x336A, 0xFFFE, UInt16(6 + v * 18)) // MOVE.W -2(A2),UPS_VoiceNPer(A1)
        }
        a.w(0x4CDF, 0x0600, 0x6100) // MOVEM.L (SP)+,A1/A2; BSR.W DMAWait
        a.displacement(to: dmaWait)
        a.w(0x302D, 0x0002, 0x4E75) // MOVE.W 2(A5),D0; RTS
        patches.add([0x51C8, 0xFFFE, 0x302D, 0x0002], patch: patch4) // DBRA D0,*; MOVE.W 2(A5),D0
        patches.assemble(&a)
        playPtr = a.addressOf(play)
        initSongPtr = a.addressOf(initSong)
        volumesAt = a.addressOf(volumes[0])
        intAddress = a.addressOf(structure) + 18
        initSoundAt = a.addressOf(initSound)
    }

    /// `InitPlayer` ($418).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let module = try WantedTeamHeader.load(&host)
        let h = WantedTeamHeader.longs(host, module: module, count: 6)
        let (play, audio, initSong, songs) = (h[0], h[1], h[2], h[3])
        title = WantedTeamHeader.string(host, at: h[4])
        author = WantedTeamHeader.string(host, at: h[5])
        host.machine.poke32(playPtr, play)
        host.machine.poke32(initSongPtr, initSong)
        host.machine.poke32(intAddress, audio)
        // From the audio interrupt to its first RTE ($470): the address each MOVE.B abs.L,D1 reads kept in
        // turn from `Vol1Ptr` on (the voices' volumes, for the scopes), and the RTE made an RTS, as it is
        // called as a routine. (A module with more such reads than three would write past them, over
        // `SongEndFlag`, `A4_Base` and the scopes, as the player does; one that would go past those is
        // refused.)
        var at = audio
        var kept: UInt32 = 0
        while host.machine.peek16(at) != 0x4E73 {
            guard Int(at) + 8 <= host.memorySize - DeliTrackerHost.room else {
                throw .malformed("a module of Benn Daglish's whose audio interrupt does not end as the player looks for")
            }
            if host.machine.peek16(at) == 0x1239 {
                guard kept < 12 + 6 + 80 else {
                    throw .malformed("a module of Benn Daglish's whose audio interrupt is not as the player looks for")
                }
                host.machine.poke32(volumesAt + kept, host.machine.peek32(at + 2))
                kept += 4
            }
            at += 2
        }
        host.machine.poke16(at, 0x4E75)
        // `ModuleChange` ($1A2): the patches made in the 2,600 bytes from the routine for a tick.
        patches.apply(&host, from: play, length: 2600)
        return WantedTeamSongs(first: 0, count: Int(min(songs, 256)))
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
