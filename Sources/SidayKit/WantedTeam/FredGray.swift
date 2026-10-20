// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Fred Gray's music ("Fred Gray player module V1.0 (6 Jan 2001)",
// UADE's players/FredGray), whose source is not given: what it does is read from its code, and the
// addresses given are of its hunk in UADE's file.

/// Fred Gray's music for the Amiga (of 1987 and 1988, as the player's credit has it), as Wanted Team
/// adapted it: each module is his 68000 code that plays it, with its music and samples, in
/// one hunk with their standard header ("FREDGRAY"), whose longs are the addresses of its routines for a
/// tick and to start a song, its number of songs, and its names.
///
/// As the player plays it: the first of the module's routines for the states a song is in (its table,
/// which its tick jumps into by `ASL.L #2,D6`) made the player's `SongEnd`, so that a song that has ended
/// says so with every tick; the module's shutting out of interrupts around a change of its voices
/// (`MOVE.W SR,-(A7)`, `MOVE.W (A7)+,SR` and the branch on the flags after it) taken out; and its writes
/// of the voices' periods and volumes, and of their samples' lengths, patched as the player has them
/// (the volumes through the balance, which is none).
typealias FredGrayPlayer = WantedTeamPlayer<FredGray>

struct FredGray: WantedTeamRecipe {
    static let format = "Fred Gray"

    /// `Check3` ($2DE): the standard header with "FREDGRAY", and its routines for a tick and a song's
    /// start, and its number of songs, not nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        WantedTeamHeader.isOne(data, id: Array("FREDGRAY".utf8), required: [0, 1, 2])
    }

    private(set) var title = ""
    private(set) var author = ""

    private var playPtr: UInt32 = 0, initSongPtr: UInt32 = 0, initPtr4: UInt32 = 0
    private var sample1: UInt32 = 0, sample2: UInt32 = 0
    private var songEndAt: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($13E to $164): two addresses of the module's samples, for the scopes; the sides'
        // volumes and the voices' muting; the scopes' structure.
        let play = a.variable(long: 0), initSong = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let init4 = a.variable(long: 0), samples = (0 ..< 2).map { _ in a.variable(long: 0) }
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // `Interrupt` ($382, DTP_Interrupt) and `SongEnd` ($3B6), which the module's table is given.
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 3)
        let songEnd = a.songEndRoutine(eagleBase: eagleBase)
        // `InitSound` ($4D0, DTP_InitSound): the scopes told the voices play the module's first sample,
        // and the song started with its number in D0 (jumped to).
        let initSound = a.placed()
        a.clearScopes(scopes)
        a.w(0x43FA)
        a.displacement(to: scopes[0]) // LEA StructAdr(PC),A1
        a.w(0x247A)
        a.displacement(to: samples[0]) // MOVEA.L Sample1(PC),A2
        for v: UInt16 in 0 ..< 3 { a.w(0x337C, 0x0008, 4 + v * 18, 0x234A, v * 18) } // MOVE.W #8,UPS_Len(A1); MOVE.L A2,UPS_Adr(A1)
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x207A) // MOVE.W dtg_SndNum(A5),D0; MOVEA.L InitSongPtr(PC),A0
        a.displacement(to: initSong)
        a.w(0x4ED0) // JMP (A0)
        // The patches (`PatchTable`, $52C), each with the module's code it is called in place of.
        // Code0, Patch0 ($546, $57E): the three voices' periods, from D5, and their volumes, through the
        // sides' balance (and told the scopes); A6 the module's voices, A5 $DFF000.
        let sides = [leftVolume, rightVolume, rightVolume]
        let patch0 = a.placed()
        a.w(0x2F09, 0x43FA) // MOVE.L A1,-(A7); LEA StructAdr(PC),A1
        a.displacement(to: scopes[0])
        a.w(0x3B45, 0x00A6, 0x3345, 0x0006) // MOVE.W D5,$A6(A5); MOVE.W D5,UPS_Voice1Per(A1)
        for v: UInt16 in 1 ..< 3 {
            // MOVE.W v*32(A6),D5; ASL.W #1,D5; MOVE.W D5,$Ax6(A5); MOVE.W D5,UPS_VoicePer(A1)
            a.w(0x3A2E, v * 32, 0xE345, 0x3B45, 0x00A6 + v * 16, 0x3345, 6 + v * 18)
        }
        a.w(0x7A00) // MOVEQ #0,D5
        for v: UInt16 in 0 ..< 3 {
            a.w(0x1A2E, 5 + v * 32, 0xE505, 0xCAFA) // MOVE.B 5+v*32(A6),D5; ASL.B #2,D5; MULU side(PC),D5
            a.displacement(to: sides[Int(v)])
            a.w(0xCA7A)
            a.displacement(to: voices[Int(v)]) // AND.W Voice(PC),D5
            a.w(0xEC4D, 0x3345, 8 + v * 18, 0x3B45, 0x00A8 + v * 16) // LSR.W #6,D5; MOVE.W D5,UPS_VoiceVol(A1); MOVE.W D5,$Ax8(A5)
        }
        a.w(0x225F, 0x4E75) // MOVEA.L (A7)+,A1; RTS
        var code0: [UInt16] = [0x3B45, 0x00A6]
        for v: UInt16 in 1 ..< 3 { code0 += [0x3A2E, v * 32, 0xE345, 0x3B45, 0x00A6 + v * 16] }
        code0.append(0x7A00)
        for v: UInt16 in 0 ..< 3 { code0 += [0x1A2E, 5 + v * 32, 0xE505, 0x3B45, 0x00A8 + v * 16] }
        patches.add(code0, patch: patch0)
        // Code1, Patch1 ($5F6, $644): the same from D0, written to the registers' absolute addresses, the
        // volumes' bytes masked (and the scopes told the voices' samples).
        let patch1 = a.placed()
        a.w(0x48E7, 0x0060, 0x43FA) // MOVEM.L A1/A2,-(A7); LEA StructAdr(PC),A1
        a.displacement(to: scopes[0])
        a.w(0x247A)
        a.displacement(to: samples[0]) // MOVEA.L Sample1(PC),A2
        for v: UInt16 in 0 ..< 3 {
            if v > 0 { a.w(0x302E, v * 36, 0xE340) } // MOVE.W v*36(A6),D0; ASL.W #1,D0
            a.w(0x33C0, 0x00DF, 0xF0A6 + v * 16) // MOVE.W D0,$DFF0x6
            if v == 1 {
                a.w(0x247A)
                a.displacement(to: samples[1]) // MOVEA.L Sample2(PC),A2
            }
            // MOVE.W D0,UPS_VoicePer(A1); MOVE.W #8,UPS_VoiceLen(A1); MOVE.L A2,UPS_VoiceAdr(A1)
            a.w(0x3340, 6 + v * 18, 0x337C, 0x0008, 4 + v * 18, 0x234A, v * 18)
        }
        for v: UInt16 in 0 ..< 3 {
            a.w(0x102E, 5 + v * 36, 0xE500, 0x0240, 0x00FF, 0xC0FA) // MOVE.B 5+v*36(A6),D0; ASL.B #2,D0; ANDI.W #$FF,D0; MULU side(PC),D0
            a.displacement(to: sides[Int(v)])
            a.w(0xC07A)
            a.displacement(to: voices[Int(v)]) // AND.W Voice(PC),D0
            a.w(0xEC48, 0x3340, 8 + v * 18, 0x33C0, 0x00DF, 0xF0A8 + v * 16) // LSR.W #6,D0; MOVE.W D0,UPS_VoiceVol(A1); MOVE.W D0,$DFF0x8
        }
        a.w(0x4CDF, 0x0600, 0x4E75) // MOVEM.L (A7)+,A1/A2; RTS
        var code1: [UInt16] = [0x33C0, 0x00DF, 0xF0A6]
        for v: UInt16 in 1 ..< 3 { code1 += [0x302E, v * 36, 0xE340, 0x33C0, 0x00DF, 0xF0A6 + v * 16] }
        for v: UInt16 in 0 ..< 3 { code1 += [0x102E, 5 + v * 36, 0xE500, 0x0240, 0x00FF, 0x33C0, 0x00DF, 0xF0A8 + v * 16] }
        patches.add(code1, patch: patch1)
        // Code2, Patch2 ($6FC, $706) and Code3, Patch3 ($752, $75E): a voice's length set (8 words, or
        // $80), and the scopes told its sample, by D3 (the voice's registers' offset); the module's byte
        // for it then cleared, or set.
        for (length, sample, byteCode) in [(UInt16(0x0008), samples[0], [UInt16(0x4236), 0x4000]),
                                           (0x0080, samples[1], [0x1DBC, 0x00FF, 0x4000])]
        {
            let patch = a.placed()
            a.w(0x3BBC, length, 0x3004, 0x48E7, 0x00C0, 0x41FA) // MOVE.W #length,4(A5,D3.W); MOVEM.L A0/A1,-(A7); LEA StructAdr(PC),A0
            a.displacement(to: scopes[0])
            a.w(0x227A)
            a.displacement(to: sample) // MOVEA.L SampleN(PC),A1
            for v: UInt16 in 0 ..< 3 {
                // CMPI.W #$Ax0,D3; BNE.S +10; MOVE.W #length,UPS_VoiceLen(A0); MOVE.L A1,UPS_VoiceAdr(A0)
                a.w(0x0C43, 0x00A0 + v * 16, 0x660A, 0x317C, length, 4 + v * 18, 0x2149, v * 18)
            }
            a.w(0x4CDF, 0x0300) // MOVEM.L (A7)+,A0/A1
            for word in byteCode { a.w(word) } // CLR.B 0(A6,D4.W), or MOVE.B #$FF,0(A6,D4.W)
            a.w(0x4E75)
            patches.add([0x3BBC, length, 0x3004] + byteCode, patch: patch)
        }
        patches.assemble(&a)
        playPtr = a.addressOf(play)
        initSongPtr = a.addressOf(initSong)
        initPtr4 = a.addressOf(init4)
        sample1 = a.addressOf(samples[0])
        sample2 = a.addressOf(samples[1])
        songEndAt = a.addressOf(songEnd)
        initSoundAt = a.addressOf(initSound)
        tick = a.addressOf(tickRoutine)
    }

    /// `InitPlayer` ($3D4).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let module = try WantedTeamHeader.load(&host)
        let h = WantedTeamHeader.longs(host, module: module, count: 5)
        let (play, initSong, songs) = (h[0], h[1], h[2])
        title = WantedTeamHeader.string(host, at: h[3])
        author = WantedTeamHeader.string(host, at: h[4])
        host.machine.poke32(playPtr, play)
        host.machine.poke32(initSongPtr, initSong)
        func refuse() -> TuneError { .malformed("a module of Fred Gray's whose code is not as the player looks for") }
        // The table the tick jumps into: the address in the long before its ASL.L #2,D6 (of a LEA), whose
        // first entry is made `SongEnd` ($41A).
        guard let asl = WantedTeamSearch.find(host, [0xE586], from: play, most: host.memorySize), asl >= 4 else { throw refuse() }
        let table = host.machine.peek32(asl - 4)
        guard Int(table) + 4 <= host.memorySize else { throw refuse() }
        host.machine.poke32(table, songEndAt)
        // From past it, to 3,400 bytes from the routine for a tick ($446): the first MOVE.W SR,-(A7) made a
        // NOP, then the first MOVE.W (A7)+,SR and the branch after it (with its word of displacement, if
        // it has one); and the first MOVE.W #$80,4(A5,D3.W) after, less six bytes, kept for the scopes.
        // (The player's searches for the two run on past those bytes if they are not there: a module
        // without them is refused.)
        let end = play &+ 3400
        var at = asl + 2
        guard at < end, let save = WantedTeamSearch.find(host, [0x40E7], from: at, most: Int(end - at)) else { throw refuse() }
        host.machine.poke16(save, 0x4E71)
        at = save + 2
        guard at < end, let restore = WantedTeamSearch.find(host, [0x46DF], from: at, most: Int(end - at)) else { throw refuse() }
        let branch = host.machine.peek16(restore + 2)
        host.machine.poke16(restore, 0x4E71)
        host.machine.poke16(restore + 2, 0x4E71)
        at = restore + 4
        if branch & 0xFF == 0 {
            host.machine.poke16(at, 0x4E71)
            at += 2
        }
        if at < end, let found = WantedTeamSearch.find(host, long: 0x3BBC_0080, from: at, most: Int(end - at)) {
            at = found - 6
        } else {
            at = end
        }
        // What the scopes are told of the samples ($478): from the routine to start a song, after a LEA
        // abs.L,A6 if it begins so, or else from its own code.
        host.machine.poke32(initPtr4, host.machine.peek32(initSong + 4))
        if host.machine.peek16(initSong + 8) == 0x4DF9 {
            host.machine.poke32(sample1, host.machine.peek32(initSong + 16))
            host.machine.poke32(sample2, host.machine.peek32(at))
        } else {
            host.machine.poke32(sample1, host.machine.peek32(initSong + 10))
            host.machine.poke32(sample2, host.machine.peek32(initSong + 20))
        }
        // `ModuleChange` ($1C0): the patches made in the 3,400 bytes from the routine for a tick.
        patches.apply(&host, from: play, length: 3400)
        return WantedTeamSongs(first: 0, count: Int(min(songs, 256)))
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
