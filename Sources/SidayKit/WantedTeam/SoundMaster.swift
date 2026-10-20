// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Sound Master ("Sound Master 1.0-3.0 player module V1.0 (25 Feb
// 2002)", UADE's players/SoundMaster, whose source is UADE's amigasrc/players/wanted_team/SoundMaster/
// "Sound Master_v1.asm"). Its labels are named where they are followed.

/// Michiel Soede's Sound Master (1.0 to 3.0, of 1991 to 1994, as the player's credit has it), used most by
/// Jeroen Soede (as Wanted Team's notes have it), whose music of Doofus and Future Shock is in UnExoticA's
/// collection: each module is the replayer's 68000 code, with its music and samples, as the game has it,
/// beginning with three branches (to start a song, to play a tick, and a third), and is played where it
/// is loaded.
///
/// As the player plays it: the module's every voice's volume written through the player's (for the
/// balance, which is none); a song started with its number in D0 (or 31, which the player gives the
/// modules made as Doofus's are, whose start keeps it); and a song ends when the module comes to its code that starts
/// the song's list again (which the player makes a call of `dtg_SongEnd`, through the module's second
/// branch).
typealias SoundMasterPlayer = WantedTeamPlayer<SoundMaster>

struct SoundMaster: WantedTeamRecipe {
    static let format = "Sound Master"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -21.2 dB.)
    static let gain: Float = 0.33

    /// `Check2`: the module's three branches, the first two forward to even places; a `LEA (PC),A3`
    /// within the first 30 bytes of the code the first goes to; and the first RTS after it following an
    /// instruction on $BFE001 (or that and a `MOVE.B #0,d16(A3)`, in the modules of the later versions).
    static func isOne(_ data: [UInt8]) -> Bool { check(data) != nil }

    /// The player's check, and what it found: whether the module is of the later versions (`FormatReco`).
    private static func check(_ data: [UInt8]) -> Bool? {
        func word(_ at: Int) -> UInt16 {
            at >= 0 && at + 2 <= data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
        }
        func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }
        let d2 = Int16(bitPattern: word(2)), d3 = Int16(bitPattern: word(6))
        guard data.count >= 10, word(0) == 0x6000, d2 > 0, d2 & 1 == 0, word(4) == 0x6000, d3 > 0, d3 & 1 == 0,
              word(8) == 0x6000
        else { return nil }
        var at = 2 + Int(d2)
        let end = at + 30
        while word(at) != 0x47FA {
            at += 2
            if at == end { return nil }
        }
        // FindRTS: past the first RTS from the LEA.
        while at + 2 <= data.count, word(at) != 0x4E75 { at += 2 }
        guard at + 2 <= data.count else { return nil }
        at += 2
        let new = long(at - 8) == 0x177C_0000
        if new { at -= 6 }
        return long(at - 6) == 0xBFE001 ? new : nil
    }

    let title = ""
    let author = ""

    private var playPtr: UInt32 = 0, modulePtr: UInt32 = 0, formatAt: UInt32 = 0
    private var songEndAt: UInt32 = 0, setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    /// Where `Code4`'s offset is, in its pattern and in its patch, which `InitPlayer` sets for the module
    /// of the first version.
    private var code4At: UInt32 = 0, patch4At: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables: the module's address, the globals', the routine for a tick, the song's number to
        // start with (`Format`, nought for the one asked for), the sides' volumes, the voices' muting and
        // their kept volumes, the scopes.
        let module = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let play = a.variable(long: 0)
        let format = a.variable(word: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 1) }
        let oldVoices = (0 ..< 4).map { _ in a.variable(word: 0) }
        let scopes = a.scopes()
        // `SongEnd`: the module's instruction that starts the song's list again (put here by `InitPlayer`,
        // in place of 'WTWT' 'WT'), and then DeliTracker's `dtg_SongEnd`.
        let songEnd = a.placed()
        a.w(0x5754, 0x5754, 0x5754)
        a.callSongEnd(eagleBase: eagleBase)
        a.w(0x4E75)
        // `InitSound` (DTP_InitSound): the scopes and the kept volumes cleared, and the module's start
        // jumped to with the song's number in D0.
        initSoundAt = a.here
        let formatOK = a.label()
        a.clearScopes(scopes)
        a.w(0x41FA)
        a.displacement(to: oldVoices[0]) // LEA OldVoice1(PC),A0
        a.w(0x4298, 0x4290, 0x303A) // CLR.L (A0)+; CLR.L (A0); MOVE.W Format(PC),D0
        a.displacement(to: format)
        a.branch(0x6600, to: formatOK) // BNE.B FormatOK
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum)) // MOVE.W dtg_SndNum(A5),D0
        a.place(formatOK)
        a.w(0x207A)
        a.displacement(to: module) // MOVE.L ModulePtr(PC),A0
        a.w(0x4ED0) // JMP (A0)
        // `Interrupt` (DTP_Interrupt).
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 4)
        // `SetVolume` (DTP_Volume): the sides' volumes from DeliTracker's, and each voice's kept volume
        // turned down by them through `ChangeVolume` (and not written: the player's code writes nothing).
        let changeVolume = a.label(), setNew = a.label()
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x43FA)
        a.displacement(to: oldVoices[0]) // LEA OldVoice1(PC),A1
        a.w(0x7203, 0x4DF9, 0x00DF, 0xF000) // MOVEQ #3,D1; LEA $DFF000,A6
        a.place(setNew)
        a.w(0x3019) // MOVE.W (A1)+,D0
        a.branch(0x6100, to: changeVolume) // BSR.B ChangeVolume
        a.w(0x4DEE, 0x0010, 0x51C9) // LEA 16(A6),A6; DBF D1,SetNew
        a.displacement(to: setNew)
        a.w(0x4E75)
        // `ChangeVolume`: the volume in D0, seven bits, kept as the voice's (A6 its registers' base, $DFF000
        // on), nought if it is muted, and turned down by its side's balance.
        a.place(changeVolume)
        let setIt = a.label()
        let sides = [leftVolume, rightVolume, rightVolume, leftVolume]
        a.w(0x0240, 0x007F) // AND.W #$7F,D0
        for v in 0 ..< 4 {
            let next = a.label(), on = a.label()
            if v < 3 {
                a.w(0xBDFC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A6
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
        a.w(0xEC48, 0x4E75) // LSR.W #6,D0; RTS
        // `SetVol`, `SetTwo` and `SetLen`: the scopes told the volume in D0, the address in A2 and the
        // period at $10(A5), and the length in D0, of the voice whose registers' base A6 holds.
        let setVol = a.scopeRoutine(scopes, base: 6, field: 4, voicesAt: 0xDFF000, body: [0x3080]) // MOVE.W D0,(A0)
        let setTwo = a.placed(), setVoice = a.label()
        a.w(0x48E7, 0x8080) // MOVEM.L D0/A0,-(A7)
        for v in 0 ..< 4 {
            a.w(0x41FA)
            a.displacement(to: scopes[v * 9]) // LEA StructAdr+UPS_VoiceNAdr(PC),A0
            if v < 3 {
                a.w(0xBDFC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A6
                a.branch(0x6700, to: setVoice) // BEQ.S .SetVoice
            }
        }
        a.place(setVoice)
        a.w(0x208A, 0x302D, 0x0010, 0xE448) // MOVE.L A2,(A0); MOVE.W $10(A5),D0; LSR.W #2,D0
        a.w(0x3140, 0x0006, 0x4CDF, 0x0101, 0x4E75) // MOVE.W D0,UPS_Voice1Per(A0); MOVEM.L (A7)+,D0/A0; RTS
        let setLen = a.scopeRoutine(scopes, base: 6, field: 2, pointer: 1, voicesAt: 0xDFF000, body: [0x3280]) // MOVE.W D0,(A1)
        // The patches (`PatchTable`), each with the module's code it is called in place of.
        // Code1, Patch1: a voice's volume (made a JMP by `InitPlayer`).
        let p1 = a.placed()
        a.w(0x6100)
        a.displacement(to: changeVolume) // BSR.W ChangeVolume
        a.w(0x6100)
        a.displacement(to: setVol) // BSR.W SetVol
        a.w(0x3D40, 0x00A8, 0x4E75) // MOVE.W D0,$A8(A6); RTS
        patches.add([0x3D40, 0x00A8, 0x4E75], patch: p1)
        // Code2, Patch2 (1.x): a voice's sample's address.
        let p2 = a.placed()
        a.w(0xD5F0, 0x0800, 0x2D4A, 0x00A0, 0x6100) // ADDA.L 0(A0,D0.L),A2; MOVE.L A2,$A0(A6); BSR.W SetTwo
        a.displacement(to: setTwo)
        a.w(0x4E75)
        patches.add([0xD5F0, 0x0800, 0x2D4A, 0x00A0], patch: p2)
        // Code3, Patch3 (2 on): the same.
        let p3 = a.placed()
        a.w(0x2D48, 0x00A0, 0xD288, 0x2F0A, 0x2448, 0x6100) // MOVE.L A0,$A0(A6); ADD.L A0,D1; MOVE.L A2,-(SP); MOVEA.L A0,A2; BSR.W SetTwo
        a.displacement(to: setTwo)
        a.w(0x245F, 0x4E75) // MOVEA.L (SP)+,A2; RTS
        patches.add([0x2D48, 0x00A0, 0xD288], patch: p3)
        // Code4, Patch4 (1.x): a voice's sample's length; the offset of its ADDA (here $E2) is the module's.
        let p4 = a.placed()
        patch4At = a.here + 2
        a.w(0xD1EB, 0x00E2, 0x3D70, 0x0800, 0x00A4) // ADDA.L $E2(A3),A0; MOVE.W 0(A0,D0.L),$A4(A6)
        a.w(0x2F00, 0x3030, 0x0800, 0x6100) // MOVE.L D0,-(SP); MOVE.W 0(A0,D0.L),D0; BSR.W SetLen
        a.displacement(to: setLen)
        a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
        patches.add([0xD1EB, 0x00E2, 0x3D70, 0x0800, 0x00A4], patch: p4)
        // Code5, Patch5 (2.x), and Code6, Patch6 (3.x): the same.
        for index: UInt16 in [0x0000, 0x0800] {
            let p = a.placed()
            a.w(0x3D70, index | 4, 0x00A4, 0x3B70, index | 8, 0x001A) // MOVE.W 4(A0,D0),$A4(A6); MOVE.W 8(A0,D0),$1A(A5)
            a.w(0x2F00, 0x3030, index | 4, 0x6100) // MOVE.L D0,-(SP); MOVE.W 4(A0,D0),D0; BSR.W SetLen
            a.displacement(to: setLen)
            a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
            patches.add([0x3D70, index | 4, 0x00A4, 0x3B70, index | 8, 0x001A], patch: p)
        }
        patches.assemble(&a)
        code4At = patches.patternAt[3] + 2
        modulePtr = a.addressOf(module)
        playPtr = a.addressOf(play)
        formatAt = a.addressOf(format)
        songEndAt = a.addressOf(songEnd)
        tick = a.addressOf(tickRoutine)
    }

    /// `InitPlayer`.
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        func refuse() -> TuneError { .malformed("a module of Sound Master's whose code is not as the player looks for") }
        // The module, from `dtg_GetListData`.
        _ = try host.call(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgGetListData), with: [(0, 0)])
        let module = host.machine.cpu.registers[8], size = Int(host.machine.cpu.registers[0])
        guard size > 0, Int(module) + size <= host.memorySize,
              let new = Self.check((0 ..< size).map { host.machine.peek8(module + UInt32($0)) })
        else { throw refuse() }
        func word(_ at: UInt32) -> UInt16 { host.machine.peek16(at) }
        func offset(_ at: UInt32) -> UInt32 { at &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(at)))) }
        func find(_ words: [UInt16], from: UInt32) throws(TuneError) -> UInt32 {
            guard let at = WantedTeamSearch.find(host, words, from: from, most: host.memorySize) else { throw refuse() }
            return at
        }
        host.machine.poke32(modulePtr, module)
        host.machine.poke32(playPtr, offset(module + 6))
        // The songs, by the code the module's start begins with: a module made as Doofus's are starts its
        // own (31); one of the first versions has its list of songs after its LEA, three bytes each,
        // ending with 0, 0, 1 (seven at most after the first); another has two.
        let start = offset(module + 2)
        var songs = 1
        if word(start + 6) == 0x1740 || word(start + 4) == 0x1740 {
            host.machine.poke16(formatAt, 31)
        } else if word(start) == 0x3C00 {
            let lea = try find([0x47FA], from: start) + 2
            let base = offset(lea)
            let moveq = try find([0x7600], from: lea)
            var list = base &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(moveq - 2)))) &+ 3
            for _ in 0 ..< 7 {
                if host.machine.peek8(list) == 0, host.machine.peek8(list + 1) == 0, host.machine.peek8(list + 2) == 1 { break }
                list &+= 3
                songs += 1
            }
        } else if word(start + 40) == 0x4A00 {
            songs = 2
        }
        // The song's end: the module's second branch made a JMP to `SongEnd`, and its MOVE.B #x,d16(A3) ten
        // bytes past the first ADDQ.B #1,D3 a NOP and a BSR.W to it (the MOVE.B now `SongEnd`'s).
        let addq = try find([0x5203], from: module) + 2
        if word(addq + 10) == 0x177C {
            host.machine.poke16(module + 4, 0x4EF9)
            host.machine.poke32(module + 6, songEndAt)
            let at = addq + 10
            host.machine.poke32(songEndAt, host.machine.peek32(at))
            host.machine.poke32(at, 0x4E71_6100)
            host.machine.poke16(songEndAt + 4, word(at + 4))
            host.machine.poke16(at + 4, UInt16(truncatingIfNeeded: module &- at))
            // `OldVer`: for the first versions, `Code4`'s offset (and its patch's) the module's, the one
            // before the first `MOVE.W d8(A0,Xn),d16(A6)` of its start.
            if !new {
                let move = try find([0x3D70], from: start)
                host.machine.poke16(code4At, word(move - 2))
                host.machine.poke16(patch4At, word(move - 2))
            }
        }
        // `FindVol`: the module's first MOVE.W D0,$A8(A6), which the patches make a JSR to `Patch1`, made
        // a JMP; the patches made in its first 2,400 bytes.
        let volume = try find([0x3D40, 0x00A8], from: module)
        patches.apply(&host, from: module, length: 2400)
        guard word(volume) == 0x4EB9 else { throw refuse() }
        host.machine.poke16(volume, 0x4EF9)
        return WantedTeamSongs(first: 0, count: songs)
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
