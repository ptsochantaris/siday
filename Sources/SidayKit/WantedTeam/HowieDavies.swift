// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Howie Davies's music ("Howie Davies player module V1.0 (2 Apr
// 2001)", UADE's players/HowieDavies), whose source is not given: what it does is read from its code, and
// the addresses given are of its first hunk in UADE's file.

/// Howie Davies's music for the Amiga (and Gary Antcliffe's, of 1990 and 1991, as the player's credit
/// has it), as Wanted Team adapted it: each module is the 68000 code that plays it, with its music and
/// samples, in one hunk with their standard header ("H.DAVIES"), whose longs are the addresses of its two
/// routines for a tick, its routine to start a song, its list of samples, its list of songs, and its
/// names.
///
/// As the player plays it: the module's every voice's volume written through the player's (for the
/// balance, which is none: as a BSR to the module's start, which the player makes a jump to its own
/// routine); the end of each voice's music counted, and the song's end said once all four have come
/// to it; its writes of absolute addresses in $DF0000 on made $DFF000 on; its wait for the DMA made
/// eight lines of the beam; its write to address nought taken out; and the empty samples it gives the
/// voices (address nought) made the player's long of nought (in its second hunk, at $D7E0, where UADE
/// puts it).
typealias HowieDaviesPlayer = WantedTeamPlayer<HowieDavies>

struct HowieDavies: WantedTeamRecipe {
    static let format = "Howie Davies"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -19.1 dB.)
    static let gain: Float = 0.26

    /// Where UADE puts the player's second hunk, a long of nought (its first hunk, of 2,004 bytes, at
    /// $D008, eight bytes past the eight-byte boundary below the end of the one before as UADE's
    /// relocator places them).
    static let silence: UInt32 = 0xD7E0

    /// `Check3` ($3BC): the standard header with "H.DAVIES", and its two routines for a tick and its
    /// routine to start a song not nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        WantedTeamHeader.isOne(data, id: Array("H.DAVIES".utf8), required: [0, 1, 2])
    }

    private(set) var title = ""
    private(set) var author = ""

    private var playPtr: UInt32 = 0, play2Ptr: UInt32 = 0, initSongPtr: UInt32 = 0
    private var volumeAt: UInt32 = 0, endsAt: UInt32 = 0, copiedAt: [UInt32] = []
    private var initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($156 to $180): the module's three routines, its lists of samples, the voices'
        // ends (`SongEnd`'s four bytes), the sides' volumes and the voices' muting, the scopes.
        let play = a.variable(long: 0), play2 = a.variable(long: 0), initSong = a.variable(long: 0)
        _ = a.variable(long: 0)
        _ = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let ends = a.variable(long: 0x5754_5754)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // `ChangeVolume` ($236): the volume in D0, seven bits of it, turned down by its side's balance and
        // muting, written to the voice whose registers' base is A6 (by its low word), if it is one.
        let changeVolume = a.placed()
        let write = a.label(), out = a.label()
        let v1 = a.label(), v2 = a.label(), v3 = a.label()
        a.w(0x2F01, 0x0240, 0x007F, 0x220E) // MOVE.L D1,-(A7); ANDI.W #$7F,D0; MOVE.L A6,D1
        a.w(0x0C41, 0xF000)
        a.branch(0x6700, to: v1) // CMPI.W #$F000,D1; BEQ.S
        a.w(0x0C41, 0xF010)
        a.branch(0x6700, to: v2)
        a.w(0x0C41, 0xF020)
        a.branch(0x6700, to: v3)
        a.w(0x0C41, 0xF030)
        a.branch(0x6600, to: out) // CMPI.W #$F030,D1; BNE.S out
        for (side, voice, label) in [(leftVolume, voices[3], nil as Int?), (leftVolume, voices[0], v1),
                                     (rightVolume, voices[1], v2), (rightVolume, voices[2], v3)]
        {
            if let label { a.place(label) }
            a.w(0xC0FA)
            a.displacement(to: side) // MULU side(PC),D0
            a.w(0xC07A)
            a.displacement(to: voice) // AND.W Voice(PC),D0
            if label != v3 { a.branch(0x6000, to: write) } // BRA.S write
        }
        a.place(write)
        a.w(0xEC48, 0x3D40, 0x00A8) // LSR.W #6,D0; MOVE.W D0,$A8(A6)
        a.place(out)
        a.w(0x221F, 0x4E75) // MOVE.L (A7)+,D1; RTS
        // `SetVol` ($286) and `SetAll` ($2B6), for the scopes, by A6.
        let setVol = a.scopeRoutine(scopes, base: 6, field: 4, body: [0x3080]) // MOVE.W D0,(A0)
        // MOVE.L (A5),(A0); MOVE.W 6(A5),4(A0); MOVE.W 4(A5),6(A0)
        let setAll = a.scopeRoutine(scopes, base: 6, field: 0, body: [0x2095, 0x316D, 0x0006, 0x0004, 0x316D, 0x0004, 0x0006])
        // `Interrupt` ($458, DTP_Interrupt): the module's two routines for a tick.
        tick = a.here
        a.w(0x48E7, 0x7FFE, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(SP); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x50E8, 0x004C, 0x4268, 0x0006, 0x4268, 0x0018, 0x4268, 0x002A, 0x4268, 0x003C) // ST UPS_Enabled(A0); CLR.W the periods
        a.w(0x317C, 0x000F, 0x004A, 0x207A) // MOVE.W #$F,UPS_Flags(A0); MOVEA.L Play2Ptr(PC),A0
        a.displacement(to: play2)
        a.w(0x4E90, 0x207A) // JSR (A0); MOVEA.L PlayPtr(PC),A0
        a.displacement(to: play)
        a.w(0x4E90) // JSR (A0)
        a.endTick(scopes: scopes)
        // `DMAWait` ($496), and `SongEnd` ($4B4): the voice whose registers' base is A6 at the end of its
        // music, and once all four are, the song's end said and the count begun again.
        let dmaWait = a.dmaWait(lines: 8)
        let songEnd = a.placed()
        let count = a.label()
        a.w(0x48E7, 0x0044, 0x43FA) // MOVEM.L A1/A5,-(A7); LEA Ends(PC),A1
        a.displacement(to: ends)
        for v in 0 ..< 4 {
            let next = a.label()
            a.w(0xBDFC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A6
            a.branch(0x6600, to: next) // BNE.S
            if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
            if v < 3 { a.branch(0x6000, to: count) } // BRA.S
            a.place(next)
        }
        a.place(count)
        let notYet = a.label()
        a.w(0x4A91) // TST.L (A1)
        a.branch(0x6600, to: notYet) // BNE.S
        a.w(0x22BC, 0x5754, 0x5754, 0x2A7A) // MOVE.L #'WTWT',(A1); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(notYet)
        a.w(0x4CDF, 0x2200, 0x4E75) // MOVEM.L (A7)+,A1/A5; RTS
        // `InitSound` ($61A, DTP_InitSound): the voices' ends counted afresh, and the song started with its
        // number in D0 and 15 in D1 (jumped to).
        initSoundAt = a.here
        a.clearScopes(scopes)
        a.w(0x41FA)
        a.displacement(to: ends) // LEA Ends(PC),A0
        a.w(0x20BC, 0x5754, 0x5754, 0x7000) // MOVE.L #'WTWT',(A0); MOVEQ #0,D0
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x720F, 0x207A) // MOVE.W dtg_SndNum(A5),D0; MOVEQ #15,D1; MOVEA.L InitSongPtr(PC),A0
        a.displacement(to: initSong)
        a.w(0x4ED0) // JMP (A0)
        // ($5FA): what the module's start is made a jump to, which its writes of volumes call.
        volumeAt = a.here
        a.w(0x6100)
        a.displacement(to: changeVolume) // BSR.W ChangeVolume
        a.w(0x6100)
        a.displacement(to: setVol) // BSR.W SetVol
        a.w(0x4E75)
        // The patches (`PatchTable`, $660), each with the module's code it is called in place of.
        func patch(_ code: [UInt16], _ body: (inout AmigaAssembly) -> Void) {
            let at = a.placed()
            body(&a)
            a.w(0x4E75)
            patches.add(code, patch: at)
        }
        // Code0 ($6AA): its wait for the DMA, made `DMAWait`.
        patch([0x3E3C, 0x001F, 0x51CF, 0xFFFE]) { a in // MOVE.W #$1F,D7; DBF D7,*
            a.w(0x6100)
            a.displacement(to: dmaWait)
        }
        // Code1 and Code2 ($6BC, $6CE): a voice at the end of its music, counted by `SongEnd`. (The first's
        // displacements are put in from the module by `initPlayer`.)
        var copied: [UInt32] = []
        patch([0x2B6D, 0x002E, 0x002A]) { a in // MOVE.L 46(A5),42(A5)
            copied.append(a.here + 2)
            a.w(0x2B6D, 0x002E, 0x002A, 0x6100)
            a.displacement(to: songEnd)
        }
        patch([0x220C, 0x101C, 0x0280, 0x0000, 0x00FF]) { a in // MOVE.L A4,D1; MOVE.B (A4)+,D0; ANDI.L #$FF,D0
            a.w(0x220C, 0x101C, 0x0280, 0x0000, 0x00FF, 0x6100)
            a.displacement(to: songEnd)
        }
        // Code3 ($6E8): a voice's sample, its length and its period (and told the scopes).
        patch([0x2D6D, 0x0000, 0x00A0, 0x3D6D, 0x0004, 0x00A6, 0x3D6D, 0x0006, 0x00A4]) { a in
            a.w(0x2D55, 0x00A0, 0x3D6D, 0x0004, 0x00A6, 0x3D6D, 0x0006, 0x00A4, 0x6100) // MOVE.L (A5),$A0(A6); ...; BSR.W SetAll
            a.displacement(to: setAll)
        }
        // Code4 ($710): its clearing of address nought, taken out.
        patch([0x42B9, 0x0000, 0x0000]) { _ in }
        // Code5 ($718): a volume written through `ChangeVolume`, D0 kept.
        patch([0x3D6D, 0x0008, 0x00A8]) { a in
            a.w(0x2F00, 0x302D, 0x0008, 0x6100) // MOVE.L D0,-(A7); MOVE.W 8(A5),D0; BSR.W ChangeVolume
            a.displacement(to: changeVolume)
            a.w(0x6100)
            a.displacement(to: setVol) // BSR.W SetVol
            a.w(0x201F) // MOVE.L (A7)+,D0
        }
        // Code6 to Code11 ($730 to $7AE): an empty sample (address nought) made the player's long of
        // nought.
        let s = Self.silence
        let (high, low) = (UInt16(s >> 16), UInt16(s & 0xFFFF))
        patch([0x42AA, 0x00A0, 0x357C, 0x0001, 0x00A4]) { a in // CLR.L $A0(A2); MOVE.W #1,$A4(A2)
            a.w(0x257C, high, low, 0x00A0, 0x357C, 0x0001, 0x00A4)
        }
        patch([0x42A8, 0x0000, 0x317C, 0x0001, 0x0006]) { a in // CLR.L 0(A0); MOVE.W #1,6(A0)
            a.w(0x20BC, high, low, 0x317C, 0x0001, 0x0006)
        }
        patch([0x42AE, 0x00A0, 0x3D7C, 0x0001, 0x00A4]) { a in // CLR.L $A0(A6); MOVE.W #1,$A4(A6)
            a.w(0x2D7C, high, low, 0x00A0, 0x3D7C, 0x0001, 0x00A4)
        }
        patch([0x42A8, 0x000E, 0x317C, 0x0001, 0x0012]) { a in // CLR.L 14(A0); MOVE.W #1,18(A0)
            a.w(0x217C, high, low, 0x000E, 0x317C, 0x0001, 0x0012)
        }
        patch([0x2D47, 0x00A0, 0x2D47, 0x00B0]) { a in // MOVE.L D7,$A0(A6); MOVE.L D7,$B0(A6)
            a.w(0x2E3C, high, low, 0x2D47, 0x00A0, 0x2D47, 0x00B0) // MOVE.L #silence,D7; ...
        }
        patch([0x2D6D, 0x000E, 0x00A0, 0x3D6D, 0x0012, 0x00A4]) { a in // MOVE.L 14(A5),$A0(A6); MOVE.W 18(A5),$A4(A6)
            let set = a.label()
            a.w(0x202D, 0x000E) // MOVE.L 14(A5),D0
            a.branch(0x6600, to: set) // BNE.S
            a.w(0x203C, high, low) // MOVE.L #silence,D0
            a.place(set)
            a.w(0x2D40, 0x00A0, 0x3D6D, 0x0012, 0x00A4) // MOVE.L D0,$A0(A6); MOVE.W 18(A5),$A4(A6)
        }
        patches.assemble(&a)
        copiedAt = [patches.patternAt[1] + 2] + copied
        playPtr = a.addressOf(play)
        play2Ptr = a.addressOf(play2)
        initSongPtr = a.addressOf(initSong)
        endsAt = a.addressOf(ends)
    }

    /// `InitPlayer` ($514).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let module = try WantedTeamHeader.load(&host)
        let h = WantedTeamHeader.longs(host, module: module, count: 13)
        title = WantedTeamHeader.string(host, at: h[5])
        author = WantedTeamHeader.string(host, at: h[6])
        func refuse() -> TuneError { .malformed("a module of Howie Davies's whose code is not as the player looks for") }
        guard Int(h[3]) + 4 <= host.memorySize, Int(h[12]) + 4 <= host.memorySize else { throw refuse() }
        // The module's start made a JMP to the player's routine for its volumes; its first sample the
        // player's long of nought.
        host.machine.poke16(module, 0x4EF9)
        host.machine.poke32(module + 2, volumeAt)
        host.machine.poke32(Self.silence, 0)
        host.machine.poke32(h[3], Self.silence)
        host.machine.poke32(playPtr, h[0])
        host.machine.poke32(play2Ptr, h[1])
        host.machine.poke32(initSongPtr, h[2])
        // Its songs: from the list of them, the first's address less the list's, in sixteens.
        let songs = (host.machine.peek32(h[12]) &- h[12]) >> 4
        // In the 401 words from the first routine for a tick, each MOVE.W D0,$A8(A6) made a BSR.W to the
        // module's start ($588).
        for i in 0 ..< 401 {
            let at = h[0] &+ UInt32(i * 2)
            guard Int(at) + 4 <= host.memorySize else { break }
            if host.machine.peek32(at) == 0x3D40_00A8 {
                host.machine.poke32(at, 0x6100_0000 | (module &- 2 &- at) & 0xFFFF)
            }
        }
        // From the routine to start a song to the first long $35803280 ($5B0): each ADDQ.B #2,D7 made an
        // ADDQ.B #8,D7; the displacements after a JMP (A0) and a MOVE.L d(A5),d(A5) put into Code1 and its
        // patch; and each address $DFxxxx made $DFFxxx.
        var at = h[2]
        while host.machine.peek32(at) != 0x3580_3280 {
            guard Int(at) + 8 <= host.memorySize - DeliTrackerHost.room else { throw refuse() }
            if host.machine.peek16(at) == 0x5407 {
                host.machine.poke16(at, 0x5007)
                at += 2
            }
            if host.machine.peek32(at) == 0x4ED0_2B6D {
                at += 4
                for to in copiedAt { host.machine.poke32(to, host.machine.peek32(at)) }
                at += 4
            }
            let word = host.machine.peek16(at)
            at += 2
            if word == 0x00DF {
                host.machine.poke16(at, host.machine.peek16(at) | 0xF000)
                at += 2
            }
        }
        // `ModuleChange` ($1D0): the patches made in the 1,000 bytes from the routine to start a song.
        patches.apply(&host, from: h[2], length: 1000)
        return WantedTeamSongs(first: 0, count: Int(max(1, min(songs, 256))))
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
