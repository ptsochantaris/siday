// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Rob Hubbard's music of 1989 to 1991 ("Rob Hubbard player module
// V1.4 (7 July 2001)", by Eagleeye of Defect and Wanted Team; UADE's players/RobHubbard, whose source is
// UADE's amigasrc/players/wanted_team/RobHubbard/src/"Rob Hubbard_v7.asm"). The lines given are of that
// source.

/// Rob Hubbard's music for the Amiga of 1989 to 1991, as the player's credit has it: each module is his
/// 68000 code that plays it, with its music and its samples, as the game had it, beginning with five
/// branches: to its routine for a tick, to the one that starts a song (with its number, from nought, in
/// D0), and to the one that stops it, among them; then its samples, each a long of its length and two
/// words before its bytes; then its songs, eighteen bytes each, each a word and the offsets of its four
/// voices' lists of patterns.
///
/// As the player plays it (fifty ticks a second): the module's own audio interrupt, which it would set
/// going, left out (Paula plays each sample and its repeat as the module writes them); its volumes
/// written through the player's (for the balance, which is none); every command $85 of its music made
/// $84; and a voice's list coming to its end (a long of nought, after which it begins again) counted,
/// and the song's end said once all four have come to it.
typealias RobHubbardPlayer = WantedTeamPlayer<RobHubbard>

struct RobHubbard: WantedTeamRecipe {
    static let format = "Rob Hubbard"

    /// Where UADE has the player's `Pusty` (line 883), eight bytes of nought that its patch makes a voice's
    /// sample: its last eight bytes, in its hunk of 2,308 bytes at $D008.
    static let empty: UInt32 = 0xD904

    /// `Check2` (lines 218-238): five BRA.Ws, a LEA d(PC),A0 at the 20th byte, and an RTS and a LEA
    /// d(PC),A0 at the 28th.
    static func isOne(_ data: [UInt8]) -> Bool {
        func word(_ at: Int) -> Int { Int(data[at]) << 8 | Int(data[at + 1]) }
        guard data.count >= 32 else { return false }
        return (0 ..< 5).allSatisfy { word($0 * 4) == 0x6000 } && word(20) == 0x41FA && word(28) == 0x4E75 && word(30) == 0x41FA
    }

    let title = ""
    let author = ""

    private var modulePtr: UInt32 = 0, addressPtr: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables (lines 49-86): the module, its songs (`address`); the voices' ends (`SongEnd`'s four
        // bytes), the place in the song and the voice whose list is the longest (`CurrentPos`, `Hardware`,
        // which InitSound reaches from `SongEnd`); the sides' volumes, the voices' muting and their kept
        // volumes; the scopes.
        let module = a.variable(long: 0)
        _ = a.variable(word: 0) // Change
        _ = a.variable(long: 0) // SamplePtr
        let songs = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let songEnd = a.variable(long: 0x5754_5754)
        let currentPos = a.variable(long: 0)
        let hardware = a.variable(long: 0x00DF_0000)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 1) }
        let oldVoices = (0 ..< 4).map { _ in a.variable(word: 0) }
        let scopes = a.scopes()
        // `InfoBuffer` (lines 130-143), of which InitSound writes the song's length.
        let info = a.placed()
        for _ in 0 ..< 23 { a.long(0) }
        // `SetVolume` (lines 471-492, DTP_Volume): the sides' volumes from DeliTracker's, and each voice's
        // kept volume written again through `ChangeVolume`.
        let changeVolume = a.label(), setNew = a.label()
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x43FA)
        a.displacement(to: oldVoices[0]) // LEA OldVoice1(PC),A1
        a.w(0x7003, 0x4DF9, 0x00DF, 0xF000) // MOVEQ #3,D0; LEA $DFF000,A6
        a.place(setNew)
        a.w(0x3219) // MOVE.W (A1)+,D1
        a.branch(0x6100, to: changeVolume) // BSR.B ChangeVolume
        a.w(0x508E, 0x508E, 0x51C8) // ADDQ.L #8,A6; ADDQ.L #8,A6; DBF D0,SetNew
        a.displacement(to: setNew)
        a.w(0x4E75)
        // `ChangeVolume` (lines 494-535): the volume in D1, seven bits, kept as the voice's (A6 its registers
        // less $A0, from $DFF000), nought if it is muted, turned down by its side's balance, and written.
        a.place(changeVolume)
        let setIt = a.label()
        let sides = [leftVolume, rightVolume, rightVolume, leftVolume]
        a.w(0x0241, 0x007F) // ANDI.W #$7F,D1
        for v in 0 ..< 4 {
            let next = a.label(), on = a.label()
            if v < 3 {
                a.w(0xBDFC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A6
                a.branch(0x6600, to: next) // BNE.B NoVoice
            }
            a.w(0x33C1)
            a.address(of: oldVoices[v]) // MOVE.W D1,OldVoice
            a.w(0x4A79)
            a.address(of: voices[v]) // TST.W Voice
            a.branch(0x6600, to: on) // BNE.B VoiceOn
            a.w(0x7200) // MOVEQ #0,D1
            a.place(on)
            a.w(0xC2FA)
            a.displacement(to: sides[v]) // MULU.W side(PC),D1
            if v < 3 {
                a.branch(0x6000, to: setIt) // BRA.B SetIt
                a.place(next)
            }
        }
        a.place(setIt)
        a.w(0xEC49, 0x3D41, 0x00A8, 0x4E75) // LSR.W #6,D1; MOVE.W D1,$A8(A6); RTS
        // `SetVol`, `SetAdr`, `SetLen`, `SetPer` (lines 539-611), for the scopes, by A6.
        let setVol = a.scopeRoutine(scopes, base: 6, field: 4, body: [0x3081]) // MOVE.W D1,(A0)
        let setAdr = a.scopeRoutine(scopes, base: 6, field: 0, body: [0x208A]) // MOVE.L A2,(A0)
        let setLen = a.scopeRoutine(scopes, base: 6, field: 2, body: [0x3081]) // MOVE.W D1,(A0)
        let setPer = a.scopeRoutine(scopes, base: 6, field: 3, body: [0x3080]) // MOVE.W D0,(A0)
        // `Interrupt` (lines 447-464, DTP_Interrupt): the module's routine for a tick, its first branch.
        let tickRoutine = a.tickRoutine(play: module, scopes: scopes, voices: 4)
        tick = a.addressOf(tickRoutine)
        // `InitSound` (lines 399-441, DTP_InitSound): the voices' ends counted afresh, the voice whose list of
        // the song is the longest noted, and the song started with its number in D0 (jumped to).
        initSoundAt = a.here
        a.clearScopes(scopes)
        a.w(0x7000, 0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x43FA) // MOVEQ #0,D0; MOVE.W dtg_SndNum(A5),D0; LEA SongEnd(PC),A1
        a.displacement(to: songEnd)
        a.w(0x22FC, 0x5754, 0x5754, 0x4299, 0x3400, 0x267A) // MOVE.L #'WTWT',(A1)+; CLR.L (A1)+; MOVE.W D0,D2; MOVEA.L address(PC),A3
        a.displacement(to: songs)
        let findMaxLength = a.placed(), nextLength = a.label(), zero = a.label(), maxLength = a.label()
        a.w(0x548B, 0x7603, 0x7A00, 0x383C, 0xEFF0) // ADDQ.L #2,A3; MOVEQ #3,D3; MOVEQ #0,D5; MOVE.W #$EFF0,D4
        a.place(nextLength)
        a.w(0x247A)
        a.displacement(to: module) // MOVEA.L ModulePtr(PC),A2
        a.w(0xD5DB, 0x5044, 0x5044, 0x72FF) // ADDA.L (A3)+,A2; ADDQ.W #8,D4; ADDQ.W #8,D4; MOVEQ #-1,D1
        a.place(zero)
        a.w(0x5281, 0x4A9A) // ADDQ.L #1,D1; TST.L (A2)+
        a.branch(0x6600, to: zero) // BNE.B Zero2
        a.w(0xBA81) // CMP.L D1,D5
        a.branch(0x6E00, to: maxLength) // BGT.B MaxLength
        a.w(0x2A01, 0x3344, 0x0002) // MOVE.L D1,D5; MOVE.W D4,2(A1)
        a.place(maxLength)
        a.w(0x51CB)
        a.displacement(to: nextLength) // DBF D3,NextLength
        a.w(0x51CA)
        a.displacement(to: findMaxLength) // DBF D2,FindMaxLength
        a.w(0x43FA)
        a.displacement(to: info) // LEA InfoBuffer(PC),A1
        a.w(0x2345, 0x0054, 0x207A) // MOVE.L D5,Length(A1); MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x4EE8, 0x0004) // JMP 4(A0)

        // The patches (`PatchTable`, lines 658-884), each with the module's code it is called in place of.
        func calls(_ words: [UInt16?], _ to: [Int]) -> Int {
            let patch = a.placed()
            var k = 0
            for word in words {
                if let word { a.w(word) } else {
                    a.w(0x6100)
                    a.displacement(to: to[k]) // BSR.W
                    k += 1
                }
            }
            a.w(0x4E75)
            return patch
        }
        // Code1, Patch1: the module's setting of its audio interrupt (LEA d(PC),A0; MOVE.L A0,$70.W) left
        // out.
        patches.add([0x41FA, 0x000C, 0x21C8, 0x0070], patch: calls([], []))
        // Code2 to Code4, Patch2 to Patch4: a voice's sample, its length and its volume (of the note, or of
        // its instrument at 38(A0), as the module's code of 1989, 1990 and 1991 has it), written, the
        // volume through `ChangeVolume`, and told the scopes.
        let start: [UInt16?] = [0x48E7, 0x4020, 0x2455, 0x2D4A, 0x00A0, nil, 0x322D, 0x0008, 0x3D41, 0x00A4, nil]
        let set = [setAdr, setLen, changeVolume, setVol]
        patches.add([0x2D6D, 0x0000, 0x00A0, 0x3D6D, 0x0008, 0x00A4, 0x3D6D, 0x000E, 0x00A8],
                    patch: calls(start + [0x322D, 0x000E, nil, nil, 0x4CDF, 0x0402], set))
        patches.add([0x2D6D, 0x0000, 0x00A0, 0x3D6D, 0x0008, 0x00A4, 0x302D, 0x000E, 0x4A68, 0x0026, 0x6704, 0x3028, 0x0026,
                     0x3D40, 0x00A8],
                    patch: calls(start + [0x302D, 0x000E, 0x4A68, 0x0026, 0x6704, 0x3028, 0x0026, 0x3200, nil, nil, 0x4CDF, 0x0402], set))
        patches.add([0x2D6D, 0x0000, 0x00A0, 0x3D6D, 0x0008, 0x00A4, 0x4240, 0x1028, 0x0026, 0x6706, 0x3D40, 0x00A8, 0x6006,
                     0x3D6D, 0x000E, 0x00A8, 0x4240],
                    patch: calls(start + [0x4240, 0x1028, 0x0026, 0x670C, 0x3200, nil, nil, 0x600C, 0x322D, 0x000E, nil, nil,
                                          0x4240, 0x4CDF, 0x0402], set + [changeVolume, setVol]))
        // Code5, Patch5: a voice's next pattern taken from its list (A2), which at its end (a long of nought)
        // begins again (8(A0)): the end counted for the voice whose registers are A6 (less $A0), and once all
        // four have come to it, the song's end said and the count begun again; and the place in the song
        // kept, of the voice whose list is the longest.
        let patch5 = a.placed()
        let noZero = a.label(), test = a.label(), skipEnd = a.label(), exitPos = a.label()
        a.w(0x48E7, 0x0044, 0x4A92) // MOVEM.L A1/A5,-(A7); TST.L (A2)
        a.branch(0x6600, to: noZero) // BNE.B NoZero
        a.w(0x43FA)
        a.displacement(to: songEnd) // LEA SongEnd(PC),A1
        for v in 0 ..< 4 {
            let next = a.label()
            a.w(0xBDFC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A6
            a.branch(0x6600, to: v < 3 ? next : test) // BNE.B
            if v == 0 { a.w(0x4211) } else { a.w(0x4229, UInt16(v)) } // CLR.B v(A1)
            if v < 3 {
                a.branch(0x6000, to: test) // BRA.B test
                a.place(next)
            }
        }
        a.place(test)
        a.w(0x4A91) // TST.L (A1)
        a.branch(0x6600, to: skipEnd) // BNE.B SkipEnd
        a.w(0x22FC, 0x5754, 0x5754, 0x4291, 0x2A7A) // MOVE.L #'WTWT',(A1)+; CLR.L (A1); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(skipEnd)
        a.w(0x2468, 0x0008, 0x7004) // MOVEA.L 8(A0),A2; MOVEQ #4,D0
        a.place(noZero)
        a.w(0xBDFA)
        a.displacement(to: hardware) // CMPA.L Hardware(PC),A6
        a.branch(0x6600, to: exitPos) // BNE.B ExitPos
        a.w(0x23E8, 0x000C)
        a.address(of: currentPos) // MOVE.L 12(A0),CurrentPos
        a.place(exitPos)
        a.w(0x4CDF, 0x2200, 0x2252, 0x4E75) // MOVEM.L (A7)+,A1/A5; MOVEA.L (A2),A1; RTS
        patches.add([0x4A92, 0x6606, 0x2468, 0x0008, 0x7004, 0x2252], patch: patch5)
        // Code6, Patch6: a voice's sample and its length told the scopes.
        patches.add([0x2D4A, 0x00A0, 0x3D41, 0x00A4], patch: calls([0x2D4A, 0x00A0, nil, 0x3D41, 0x00A4, nil], [setAdr, setLen]))
        // Code9 and CodeA, Patch9; CodeB, PatchB: a voice's period told the scopes.
        let patch9 = calls([0x3140, 0x0012, 0x3D40, 0x00A6, nil], [setPer])
        patches.add([0x3D40, 0x00A6, 0x3140, 0x0012], patch: patch9)
        patches.add([0x3140, 0x0012, 0x3D40, 0x00A6], patch: patch9)
        patches.add([0xD441, 0x3D42, 0x00A6], patch: calls([0xD441, 0x3D42, 0x00A6, 0x2F00, 0x3002, nil, 0x201F], [setPer]))
        // CodeC, PatchC: a voice's empty sample made the player's eight bytes of nought (`empty`) where the
        // module would leave its address nought.
        patches.add([0x2348, 0x0008, 0x237C, 0x0000, 0x0004, 0x000C],
                    patch: calls([0x2348, 0x0008, 0x237C, 0x0000, 0x0004, 0x000C, 0x237C, UInt16(Self.empty >> 16),
                                  UInt16(Self.empty & 0xFFFF), 0x0018], []))
        patches.assemble(&a)

        modulePtr = a.addressOf(module)
        addressPtr = a.addressOf(songs)
    }

    /// `InitPlayer` (lines 279-393).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let refusal = TuneError.malformed("a module of Rob Hubbard's whose code is not as the player looks for")
        _ = try host.call(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgGetListData), with: [(0, 0)])
        let module = host.machine.cpu.registers[8]
        host.machine.poke32(modulePtr, module)
        host.machine.poke32(Self.empty, 0)
        host.machine.poke32(Self.empty + 4, 0)
        func word(_ at: UInt32) -> UInt16 { host.machine.peek16(at) }
        // The number of samples, less one: the byte before the first MOVE.L (A0)+,D2 of the eight words from
        // the 64th byte.
        guard let move = (0 ..< 8).map({ module + 64 + UInt32($0 * 2) }).first(where: { word($0) == 0x2418 }) else { throw refusal }
        var samplesLeft = UInt32(host.machine.peek8(move - 1))
        // The samples, past the first LEA d(PC),A0 of the five words from the 54th byte (64 bytes further
        // if an ADDA.L follows it): each a long of its length (at most 64 KB), two words and its bytes, and
        // a NOP after the last.
        guard let lea = (0 ..< 5).map({ module + 54 + UInt32($0 * 2) }).first(where: { word($0) == 0x41FA }) else { throw refusal }
        var songSize = (lea + 2) &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(lea + 2)))) &- module &+ 2
        if word(lea + 4) == 0xD1FC { songSize += 64 }
        let samples = module &+ songSize &- 2
        var at = samples
        repeat {
            guard Int(at) + 4 <= host.memorySize else { throw refusal }
            let length = host.machine.peek32(at)
            guard length <= 0x10000 else { throw refusal }
            at += length + 6
            samplesLeft &-= 1
        } while samplesLeft != 0xFFFF_FFFF
        guard Int(at) + 2 <= host.memorySize, word(at) == 0x4E71 else { throw refusal }
        // The songs: at the first LEA d(A3),A0 of the ten words from the 130th byte, eighteen bytes each until
        // one whose first word is nought.
        guard let songsLea = (0 ..< 10).map({ module + 130 + UInt32($0 * 2) }).first(where: { word($0) == 0x41EB }) else {
            throw refusal
        }
        let songs = module &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(songsLea + 2))))
        host.machine.poke32(addressPtr, songs)
        var count = 0
        at = songs
        repeat {
            at &+= 18
            count += 1
            guard Int(at) + 2 <= host.memorySize, count <= 256 else { throw refusal }
        } while word(at) != 0
        // From there to the samples (as many bytes as a word counts, and one), each command $85 made $84
        // (lines 361-377).
        var left = UInt16(truncatingIfNeeded: samples &- at)
        while Int(at) < host.memorySize {
            if host.machine.peek8(at) == 0x85 { host.machine.poke8(at, 0x84) }
            at += 1
            if left == 0 { break }
            left -= 1
        }
        // `ModuleChange` (lines 244-263): the patches made in the 900 bytes from the module's start.
        patches.apply(&host, from: module, length: 900)
        return WantedTeamSongs(first: 0, count: count)
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
