// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Holger Gehrmann's Sound Programming Language ("Sound
// Programming Language player module V1.0 (14 Dec 2000)", UADE's players/SoundProgrammingLanguage), whose
// source is not given: what it does is read from its code, and the addresses given are of its hunk in
// UADE's file.

/// Holger Gehrmann's music for the Amiga (of 1987 and 1988, as the player's credit has it), which
/// Wanted Team's player calls his Sound Programming Language, as they adapted it: each module is the 68000 code that plays it, with
/// its music and samples, in one hunk with their standard header ("!SOPROL!"), whose longs are the
/// addresses of its routines for a tick and to start a song, its number of songs (from one), its names,
/// and the speed of its ticks (CIA-A's timer, nought for fifty a second).
///
/// As the player plays it: each of the module's waits for the DMA (busy loops of its own) made eight
/// lines of the beam; its every voice's volume written through the player's (for the balance, which
/// is none); and the end of each voice's music, where its list jumps back, counted, and the song's end
/// said once all four have come to it.
typealias SoundProgrammingLanguagePlayer = WantedTeamPlayer<SoundProgrammingLanguage>

struct SoundProgrammingLanguage: WantedTeamRecipe {
    static let format = "Sound Programming Language"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -23.2 dB.)
    static let gain: Float = 0.41

    /// `Check3` ($40C): the standard header with "!SOPROL!", and its routines for a tick and a song's
    /// start, and its number of songs, not nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        WantedTeamHeader.isOne(data, id: Array("!SOPROL!".utf8), required: [0, 1, 2])
    }

    private(set) var title = ""
    private(set) var author = ""

    private var playPtr: UInt32 = 0, initSongPtr: UInt32 = 0, timerAt: UInt32 = 0, voicesAt: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($15E to $190): the module's routines and its speed, its voices' lists' base, the
        // voices' ends (four bytes), the sides' volumes, the voices' muting and their kept volumes, the
        // scopes.
        let play = a.variable(long: 0), initSong = a.variable(long: 0), timer = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let voiceBase = a.variable(long: 0)
        let ends = a.variable(long: 0x5754_5754)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 1) }
        let oldVoices = (0 ..< 4).map { _ in a.variable(word: 0) }
        let scopes = a.scopes()
        // `SetVolume` ($222, DTP_Volume): the sides' volumes from DeliTracker's, and each voice's kept
        // volume written again through `ChangeVolume`.
        let changeVolume = a.label(), setNew = a.label()
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x43FA)
        a.displacement(to: oldVoices[0]) // LEA OldVoice1(PC),A1
        a.w(0x7203, 0x41F9, 0x00DF, 0xF0A0) // MOVEQ #3,D1; LEA $DFF0A0,A0
        a.place(setNew)
        a.w(0x3019) // MOVE.W (A1)+,D0
        a.branch(0x6100, to: changeVolume) // BSR.B ChangeVolume
        a.w(0x5088, 0x5088, 0x51C9) // ADDQ.L #8,A0; ADDQ.L #8,A0; DBF D1,SetNew
        a.displacement(to: setNew)
        a.w(0x4E75)
        // `ChangeVolume` ($25C): the volume in D0, seven bits, kept as the voice's (A0 its registers,
        // $DFF0A0 on), nought if it is muted, turned down by its side's balance, and written.
        a.place(changeVolume)
        let setIt = a.label()
        let sides = [leftVolume, rightVolume, rightVolume, leftVolume]
        a.w(0x0240, 0x007F) // ANDI.W #$7F,D0
        for v in 0 ..< 4 {
            let next = a.label(), on = a.label()
            if v < 3 {
                a.w(0xB1FC, 0x00DF, 0xF0A0 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A0
                a.branch(0x6600, to: next) // BNE.B
            }
            a.w(0x33C0)
            a.address(of: oldVoices[v]) // MOVE.W D0,OldVoice
            a.w(0x4A79)
            a.address(of: voices[v]) // TST.W Voice
            a.branch(0x6600, to: on) // BNE.B
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
        a.w(0xEC48, 0x3140, 0x0008, 0x4E75) // LSR.W #6,D0; MOVE.W D0,8(A0); RTS
        // The scopes' routines ($2D6, $306, $336, $366): the volume, the address, the length, the period
        // in D0 of the voice A0 points at, through A2.
        let setVol = a.scopeRoutine(scopes, base: 0, field: 4, pointer: 2, voicesAt: 0xDFF0A0, body: [0x3480]) // MOVE.W D0,(A2)
        let setAdr = a.scopeRoutine(scopes, base: 0, field: 0, pointer: 2, voicesAt: 0xDFF0A0, body: [0x2480]) // MOVE.L D0,(A2)
        let setLen = a.scopeRoutine(scopes, base: 0, field: 2, pointer: 2, voicesAt: 0xDFF0A0, body: [0x3480])
        let setPer = a.scopeRoutine(scopes, base: 0, field: 3, pointer: 2, voicesAt: 0xDFF0A0, body: [0x3480])
        // `Interrupt` ($4A0, DTP_Interrupt), and `DMAWait` ($4D8).
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 4)
        let dmaWait = a.dmaWait(lines: 8)
        // `InitSound` ($594, DTP_InitSound): the module's speed made `dtg_Timer`, if it gives one; the
        // voices' ends counted afresh; and the song started with its number in D0 (jumped to).
        initSoundAt = a.here
        let noTimer = a.label()
        a.w(0x203A)
        a.displacement(to: timer) // MOVE.L Timer(PC),D0
        a.branch(0x6700, to: noTimer) // BEQ.S
        a.w(0x3B40, UInt16(DeliTrackerHost.dtgTimer)) // MOVE.W D0,dtg_Timer(A5)
        a.place(noTimer)
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x41FA) // MOVE.W dtg_SndNum(A5),D0; LEA Ends(PC),A0
        a.displacement(to: ends)
        a.w(0x20BC, 0x5754, 0x5754, 0x207A) // MOVE.L #'WTWT',(A0); MOVEA.L InitSongPtr(PC),A0
        a.displacement(to: initSong)
        a.w(0x4ED0) // JMP (A0)
        // The patches (`PatchTable`, $5D0), each with the module's code it is called in place of, all BSR.Ws
        // to the routines above.
        func calls(_ a: inout AmigaAssembly, _ words: [UInt16?], _ to: [Int]) {
            var k = 0
            for word in words {
                if let word { a.w(word) } else {
                    a.w(0x6100)
                    a.displacement(to: to[k])
                    k += 1
                }
            }
            a.w(0x4E75)
        }
        // Code0 to Code2 ($62C, $63E, $650): its waits for the DMA, made `DMAWait`.
        let waits = a.placed()
        calls(&a, [nil], [dmaWait])
        patches.add([0x3A3C, 0x0064, 0x51CD, 0xFFFE], patch: waits) // MOVE.W #100,D5; DBF D5,*
        patches.add([0x2E3C, 0x0000, 0x0708, 0x5387, 0x4A87, 0x6600, 0xFFFA], patch: waits) // MOVE.L #$708,D7; SUBQ.L #1,D7; TST.L D7; BNE.W *-4
        patches.add([0x3A3C, 0x015E, 0x5345, 0x4A45, 0x6600, 0xFFFA], patch: waits) // MOVE.W #$15E,D5; SUBQ.W #1,D5; TST.W D5; BNE.W *-4
        // The rest ($660 to $80A): the voices' volumes written through `ChangeVolume`, and the scopes told
        // what is written. (D0 is kept round each.)
        let p3 = a.placed() // Code3, MOVE.W 38(A1),8(A0)
        calls(&a, [0x2F00, 0x3029, 0x0026, nil, nil, 0x201F], [changeVolume, setVol])
        patches.add([0x3169, 0x0026, 0x0008], patch: p3)
        let p4 = a.placed() // Code4
        calls(&a, [0x2080, nil, 0x2853, 0x4294, 0x3012, 0x9069, 0x0014, 0xE248, 0x3140, 0x0004, nil,
                   0x2F00, 0x3029, 0x0016, nil, nil, 0x201F], [setAdr, setLen, changeVolume, setVol])
        patches.add([0x2080, 0x2853, 0x4294, 0x3012, 0x9069, 0x0014, 0xE248, 0x3140, 0x0004, 0x3169, 0x0016, 0x0008], patch: p4)
        let p5 = a.placed() // Code5, MOVE.W 42(A1),8(A0)
        calls(&a, [0x2F00, 0x3029, 0x002A, nil, nil, 0x201F], [changeVolume, setVol])
        patches.add([0x3169, 0x002A, 0x0008], patch: p5)
        let p6 = a.placed() // Code6, MOVE.W 52(A1),6(A0)
        calls(&a, [0x3169, 0x0034, 0x0006, 0x2F00, 0x3029, 0x0034, nil, 0x201F], [setPer])
        patches.add([0x3169, 0x0034, 0x0006], patch: p6)
        let p7 = a.placed() // Code7, MOVE.W D7,$DFF096; MOVE.W D4,6(A0)
        calls(&a, [0x33C7, 0x00DF, 0xF096, 0x3144, 0x0006, 0x2F00, 0x3004, nil, 0x201F], [setPer])
        patches.add([0x33C7, 0x00DF, 0xF096, 0x3144, 0x0006], patch: p7)
        let p8 = a.placed() // Code8
        calls(&a, [0x3141, 0x0004, 0x2F00, 0x3001, nil, 0x2213, 0xD282, 0xD282, 0x2081, 0x2001, nil, 0x201F], [setLen, setAdr])
        patches.add([0x3141, 0x0004, 0x2213, 0xD282, 0xD282, 0x2081], patch: p8)
        let p9 = a.placed() // Code9
        calls(&a, [0x3152, 0x0004, 0x2F00, 0x3012, nil, 0x3169, 0x0032, 0x0006, 0x3029, 0x0032, nil, 0x201F], [setLen, setPer])
        patches.add([0x3152, 0x0004, 0x3169, 0x0032, 0x0006], patch: p9)
        let p10 = a.placed() // Code10
        calls(&a, [0x2F00, 0x2091, 0x2011, nil, 0x3169, 0x0004, 0x0004, 0x3029, 0x0004, nil, 0x3029, 0x001E, nil, nil, 0x201F],
              [setAdr, setLen, changeVolume, setVol])
        patches.add([0x20A9, 0x0000, 0x3169, 0x0004, 0x0004, 0x3169, 0x001E, 0x0008], patch: p10)
        let p11 = a.placed() // Code11
        calls(&a, [0x2F00, 0x2080, nil, 0x3169, 0x0004, 0x0004, 0x3029, 0x0004, nil, 0x3029, 0x001E, nil, nil, 0x201F],
              [setAdr, setLen, changeVolume, setVol])
        patches.add([0x2080, 0x3169, 0x0004, 0x0004, 0x3169, 0x001E, 0x0008], patch: p11)
        let p12 = a.placed() // Code12
        calls(&a, [0x3169, 0x0004, 0x0004, 0x2F00, 0x3029, 0x0004, nil, 0x3169, 0x0032, 0x0006, 0x3029, 0x0032, nil, 0x201F],
              [setLen, setPer])
        patches.add([0x3169, 0x0004, 0x0004, 0x3169, 0x0032, 0x0006], patch: p12)
        let p13 = a.placed() // Code13
        calls(&a, [0x2F00, 0x2091, 0x2011, nil, 0x3169, 0x0004, 0x0004, 0x3029, 0x0004, nil, 0x1029, 0x000F, nil, nil, 0x201F],
              [setAdr, setLen, changeVolume, setVol])
        patches.add([0x20A9, 0x0000, 0x3169, 0x0004, 0x0004, 0x1169, 0x000F, 0x0009], patch: p13)
        // Code14, Patch14 ($832, $83A): a voice's list jumped on (A6 the place of its pointer, among the
        // four longs from `VoiceBase`); one that jumps back is at its end, and once all four are, the song's
        // end is said and the count begun again.
        let p14 = a.placed()
        let count = a.label(), notYet = a.label()
        a.w(0x5296, 0x528D, 0x2C95) // ADDQ.L #1,(A6); ADDQ.L #1,A5; MOVE.L (A5),(A6)
        a.w(0x48E7, 0x8044, 0x43FA) // MOVEM.L D0/A1/A5,-(A7); LEA Ends(PC),A1
        a.displacement(to: ends)
        a.w(0x203A)
        a.displacement(to: voiceBase) // MOVE.L VoiceBase(PC),D0
        for v in 0 ..< 4 {
            let next = a.label()
            if v > 0 { a.w(0x5880) } // ADDQ.L #4,D0
            a.w(0xBDC0) // CMPA.L D0,A6
            a.branch(0x6600, to: v < 3 ? next : count) // BNE.S
            a.w(0xBBD6) // CMPA.L (A6),A5
            a.branch(0x6D00, to: notYet) // BLT.S
            if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
            if v < 3 {
                a.branch(0x6000, to: count) // BRA.S
                a.place(next)
            }
        }
        a.place(count)
        a.w(0x4A91) // TST.L (A1)
        a.branch(0x6600, to: notYet) // BNE.S
        a.w(0x22BC, 0x5754, 0x5754, 0x2A7A) // MOVE.L #'WTWT',(A1); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(notYet)
        a.w(0x4CDF, 0x2201, 0x2A56, 0x4E75) // MOVEM.L (A7)+,D0/A1/A5; MOVEA.L (A6),A5; RTS
        patches.add([0x5296, 0x528D, 0x2C95, 0x2A56], patch: p14)
        patches.assemble(&a)
        playPtr = a.addressOf(play)
        initSongPtr = a.addressOf(initSong)
        timerAt = a.addressOf(timer)
        voicesAt = a.addressOf(voiceBase)
        tick = a.addressOf(tickRoutine)
    }

    /// `InitPlayer` ($4FE).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let module = try WantedTeamHeader.load(&host)
        let h = WantedTeamHeader.longs(host, module: module, count: 11)
        title = WantedTeamHeader.string(host, at: h[3])
        author = WantedTeamHeader.string(host, at: h[4])
        func refuse() -> TuneError { .malformed("a module of Holger Gehrmann's whose code is not as the player looks for") }
        host.machine.poke32(playPtr, h[0])
        host.machine.poke32(initSongPtr, h[1])
        host.machine.poke32(timerAt, h[10])
        // The voices' lists' base: the immediate of the first MOVEA.L #imm,A6 of the routine for a tick
        // ($560); and the patches made in the 2,200 bytes after the first MOVEM.L after the header ($568).
        guard let lea = WantedTeamSearch.find(host, [0x2C7C], from: h[0], most: host.memorySize) else { throw refuse() }
        host.machine.poke32(voicesAt, host.machine.peek32(lea + 2))
        guard let movem = WantedTeamSearch.find(host, [0x48E7], from: module + 52, most: host.memorySize) else { throw refuse() }
        patches.apply(&host, from: movem + 2, length: 2200)
        return WantedTeamSongs(first: 1, count: Int(min(h[2], 256)))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
