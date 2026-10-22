// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Steve Barrett's music ("Steve Barrett player module V1.1 (11 Dec
// 2002)", UADE's players/SteveBarrett, whose source is UADE's amigasrc/players/wanted_team/SteveBarrett/src/
// "Steve Barrett_v2.asm"). The lines given are of that source.

import SidayFoundation
import SidayM68000

/// Steve Barrett's music for the Amiga (and Wally Beben's, of 1988 to 1990, as the player's credit has
/// it): each module is the 68000 code that plays it, with its music and its samples (IFF 8SVX, each a
/// "FORM"), as the game had it, beginning with four branches: to its routine that makes its samples
/// ready, to the one that starts a song (with its number, from one, in D0), to the one for a tick,
/// and to the one that stops it.
///
/// As the player plays it (fifty ticks a second, or a hundred for the module whose samples take 62,372
/// bytes, Advanced Ski Simulator's): the module's turning on of the voices' DMA made without its reading
/// back what else of the DMA is on (to turn it on again); its waits for the DMA made eight lines of the
/// beam; its volumes written
/// through the player's (for the balance, which is none); the end of each voice's music counted, and the
/// song's end said once all four have come to it; and, for Wally Beben's code, the song's end said the
/// second time its routine that stops the voices runs, and the offsets of its samples' repeats read
/// whole.
typealias SteveBarrettPlayer = WantedTeamPlayer<SteveBarrett>

struct SteveBarrett: WantedTeamRecipe {
    static let format = "Steve Barrett"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -18.8 dB.)
    static let gain: Float = 0.25

    /// `Check2` (lines 287-313): four BRA.Ws of even displacements; where the fourth's displacement
    /// points, two bytes on, a MOVEA.L #$DFF0A8,A5; and the first LEA d(PC),A0 of the file pointing at
    /// "FORM".
    static func isOne(_ data: [UInt8]) -> Bool {
        func word(_ at: Int) -> Int? { at >= 0 && at + 2 <= data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : nil }
        func long(_ at: Int) -> UInt32? { word(at).flatMap { high in word(at + 2).map { UInt32(high << 16 | $0) } } }
        var displacement = 0
        for b in 0 ..< 4 {
            guard word(b * 4) == 0x6000, let d = word(b * 4 + 2), d & 1 == 0 else { return false }
            displacement = Int(Int16(truncatingIfNeeded: d))
        }
        guard word(16 + displacement) == 0x2A7C, long(18 + displacement) == 0x00DF_F0A8 else { return false }
        var at = 0
        while let w = word(at), w != 0x41FA { at += 2 }
        guard let d = word(at + 2) else { return false }
        return long(at + 2 + Int(Int16(truncatingIfNeeded: d))) == 0x464F_524D
    }

    private(set) var title = ""
    private(set) var author = ""
    private(set) var detail = ""

    private var modulePtr: UInt32 = 0, a4BasePtr: UInt32 = 0, samplesPtr: UInt32 = 0, songsPtr: UInt32 = 0
    private var voicesPtr: UInt32 = 0, bytePtr: UInt32 = 0, samplesSizeAt: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables (lines 49-86): the module and what InitPlayer finds in it; the voices' ends
        // (`SongEnd`'s four bytes), the longest voice's number and the end of Wally Beben's code
        // (`Byte`, `EndFlag`, which InitSound reaches from `SongEnd`), the timer kept; the sides' volumes
        // and the voices' muting; the scopes.
        let module = a.variable(long: 0), a4Base = a.variable(long: 0), samples = a.variable(long: 0)
        let songs = a.variable(long: 0), voicesList = a.variable(long: 0), byte = a.variable(long: 0)
        _ = a.variable(word: 0) // Change
        let eagleBase = a.eagleBase()
        let songEnd = a.variable(long: 0x5754_5754)
        _ = a.variable(word: 0) // Byte
        let endFlag = a.variable(word: 0)
        let timerStore = a.variable(word: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // `InfoBuffer` (lines 333-344), of which InitSound reads the samples' size and writes the song's
        // length and the note of its speed; and that note (`Text`, line 47).
        let info = (0 ..< 19).map { _ in a.variable(long: 0) }
        let text = a.placed()
        a.w(0x3130, 0x3048, 0x7A00) // "100Hz"
        // `SetVolume` (lines 141-155, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `Left2`, `Left1`, `Right1`, `Right2` (lines 157-181): the volume in D0 turned down by its side's
        // balance, nought if its voice is muted, and told the scopes (A0).
        let ex = a.label()
        var sides: [Int] = []
        for (side, voice) in [(leftVolume, 3), (leftVolume, 0), (rightVolume, 1), (rightVolume, 2)] {
            sides.append(a.placed())
            a.w(0xC0FA)
            a.displacement(to: side) // MULU.W side(PC),D0
            a.w(0xC07A)
            a.displacement(to: voices[voice]) // AND.W Voice(PC),D0
            a.w(0xEC48, 0x3140, UInt16(8 + voice * 18)) // LSR.W #6,D0; MOVE.W D0,UPS_VoiceNVol(A0)
            if voice != 2 { a.branch(0x6000, to: ex) } // BRA.S Ex
        }
        a.place(ex)
        a.w(0x4E75)
        let (left2, left1, right1, right2) = (sides[0], sides[1], sides[2], sides[3])
        // `SetTwo` (lines 183-208): the length and the address at (A1) told the scopes, for the voice whose
        // registers are D6 past $DFF0A0.
        let setTwo = a.placed()
        a.w(0x2F08, 0x41FA) // MOVE.L A0,-(A7); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        for v in 0 ..< 4 {
            let no = a.label()
            if v == 0 { a.w(0x4A46) } else { a.w(0x0C46, UInt16(v * 16)) } // TST.W D6, or CMP.W #$v0,D6
            a.branch(0x6600, to: no) // BNE.B .no_x
            a.w(0x3151, UInt16(4 + v * 18)) // MOVE.W (A1),UPS_VoiceNLen(A0)
            a.w(0x2169, 0x0002, UInt16(v * 18)) // MOVE.L 2(A1),UPS_VoiceNAdr(A0)
            a.place(no)
        }
        a.w(0x205F, 0x4E75) // MOVEA.L (A7)+,A0; RTS
        // `Interrupt` (lines 350-369, DTP_Interrupt): the module's routine for a tick, at its third branch.
        tick = a.here
        a.w(0x48E7, 0x7FFE, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(SP); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x50E8, 0x004C, 0x4268, 0x0006, 0x4268, 0x0018, 0x4268, 0x002A, 0x4268, 0x003C) // ST UPS_Enabled(A0); CLR.W the periods
        a.w(0x317C, 0x000F, 0x004A, 0x207A) // MOVE.W #$F,UPS_Flags(A0); MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x4EA8, 0x0008) // JSR 8(A0)
        a.endTick(scopes: scopes)
        // `InitSound` (lines 510-562, DTP_InitSound): the timer halved for Advanced Ski Simulator; the
        // voices' ends counted afresh, and the voice whose list of the song is the longest noted; and the
        // song started with its number in D0 (jumped to).
        initSoundAt = a.here
        a.clearScopes(scopes)
        let normalSpeed = a.label(), timerOK = a.label()
        a.w(0x41FA)
        a.displacement(to: info[0]) // LEA InfoBuffer(PC),A0
        a.w(0x99CC, 0x0CB9, 0x0000, 0xF3A4) // SUBA.L A4,A4; CMPI.L #62372,InfoBuffer+SamplesSize
        a.address(of: info[11])
        a.branch(0x6600, to: normalSpeed) // BNE.B NormalSpeed
        a.w(0x49FA)
        a.displacement(to: text) // LEA Text(PC),A4
        a.w(0x303A)
        a.displacement(to: timerStore) // MOVE.W TimerStore(PC),D0
        a.branch(0x6600, to: timerOK) // BNE.B TimerOK
        a.w(0x302D, UInt16(DeliTrackerHost.dtgTimer), 0xE248, 0x33C0) // MOVE.W dtg_Timer(A5),D0; LSR.W #1,D0; MOVE.W D0,TimerStore
        a.address(of: timerStore)
        a.place(timerOK)
        a.w(0x3B40, UInt16(DeliTrackerHost.dtgTimer)) // MOVE.W D0,dtg_Timer(A5)
        a.place(normalSpeed)
        a.w(0x214C, 0x0044, 0x49FA) // MOVE.L A4,Extra(A0); LEA SongEnd(PC),A4
        a.displacement(to: songEnd)
        a.w(0x28FC, 0x5754, 0x5754) // MOVE.L #'WTWT',(A4)+
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x3200, 0x5341, 0xE749, 0x227A) // MOVE.W dtg_SndNum(A5),D0; MOVE.W D0,D1; SUBQ.W #1,D1; LSL.W #3,D1; MOVEA.L SongsPtr(PC),A1
        a.displacement(to: songs)
        a.w(0x43F1, 0x1000, 0x267A) // LEA (A1,D1.W),A1; MOVEA.L A4_Base(PC),A3
        a.displacement(to: a4Base)
        a.w(0x7403, 0x7800, 0x7AFF) // MOVEQ #3,D2; MOVEQ #0,D4; MOVEQ #-1,D5
        let nextPos = a.placed(), findEnd = a.label(), maxLen = a.label()
        a.w(0x5285, 0x3219, 0x45F3, 0x1000, 0x7600) // ADDQ.L #1,D5; MOVE.W (A1)+,D1; LEA (A3,D1.W),A2; MOVEQ #0,D3
        a.place(findEnd)
        a.w(0x5283, 0x0C1A, 0x00FF) // ADDQ.L #1,D3; CMPI.B #$FF,(A2)+
        a.branch(0x6600, to: findEnd) // BNE.B FindEnd
        a.w(0xB883) // CMP.L D3,D4
        a.branch(0x6C00, to: maxLen) // BGE.B MaxLen
        a.w(0x2803, 0x3885) // MOVE.L D3,D4; MOVE.W D5,(A4)
        a.place(maxLen)
        a.w(0x51CA)
        a.displacement(to: nextPos) // DBF D2,NextPos
        a.w(0x426C, 0x0002, 0x2144, 0x003C, 0x207A) // CLR.W 2(A4); MOVE.L D4,Length(A0); MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x4EE8, 0x0004) // JMP 4(A0)

        // The patches (`PatchTable`, lines 580-782), each with the module's code it is called in place of.
        // Code0, Patch0: the voices' DMA turned on (D1) without DMACONR's other channels (bits $5F0) read
        // back and written on again.
        let patch0 = a.placed()
        a.w(0x0041, 0x8200, 0x33C1, 0x00DF, 0xF096, 0x0A41, 0x820F, 0x4E75) // OR.W #$8200,D1; MOVE.W D1,$DFF096; EOR.W #$820F,D1; RTS
        patches.add([0x0081, 0x0000, 0x8200, 0x3039, 0x00DF, 0xF002, 0x0240, 0x05F0, 0x8240, 0x33C1, 0x00DF, 0xF096, 0x0A41, 0xFFFF],
                    patch: patch0)
        // Code1, Patch1: the four volumes, at (A2) on, each through its side's routine.
        let patch1 = a.placed()
        a.w(0x2F08, 0x41FA) // MOVE.L A0,-(A7); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        for (k, side) in [left1, right1, right2, left2].enumerated() {
            if k > 0 { a.w(k < 3 ? 0x1019 : 0x1011) } // MOVE.B (A1)+,D0 (the last MOVE.B (A1),D0)
            a.w(0x6100)
            a.displacement(to: side) // BSR.W side
            if k == 0 { a.w(0x3480) } else { a.w(0x3540, UInt16(k * 16)) } // MOVE.W D0,(A2), or $k0(A2)
        }
        a.w(0x205F, 0x4E75) // MOVEA.L (A7)+,A0; RTS
        patches.add([0x3480, 0x1019, 0x3540, 0x0010, 0x1019, 0x3540, 0x0020, 0x1011, 0x3540, 0x0030], patch: patch1)
        // Code2, Patch2: a period written (D3 the voice's offset among the periods, by twos), and told the
        // scopes. (Where InitPlayer finds it, the call is made a jump: the pattern ends with RTS.)
        let patch2 = a.placed()
        a.w(0xD3C3, 0x3280, 0x2F09, 0x43FA) // ADDA.L D3,A1; MOVE.W D0,(A1); MOVE.L A1,-(A7); LEA StructAdr(PC),A1
        a.displacement(to: scopes[0])
        for v in 0 ..< 4 {
            let no = a.label()
            if v == 0 { a.w(0x4A43) } else { a.w(0x0C43, UInt16(v * 2)) } // TST.W D3, or CMP.W #2v,D3
            a.branch(0x6600, to: no) // BNE.B .no
            a.w(0x3340, UInt16(6 + v * 18)) // MOVE.W D0,UPS_VoiceNPer(A1)
            a.place(no)
        }
        a.w(0x225F, 0x4E75) // MOVEA.L (A7)+,A1; RTS
        patches.add([0xD3C3, 0x3280, 0x4E75], patch: patch2)
        // Code3, Patch3: a voice's sample's address and length told the scopes.
        let patch3 = a.placed()
        a.w(0x6100)
        a.displacement(to: setTwo) // BSR.W SetTwo
        a.w(0x5489, 0x4BF9, 0x00DF, 0xF0A0, 0xDBC6, 0x4E75) // ADDQ.L #2,A1; LEA $DFF0A0,A5; ADDA.L D6,A5; RTS
        patches.add([0x5489, 0x4BF9, 0x00DF, 0xF0A0, 0xDBC6], patch: patch3)
        // Code4, Patch4: its wait for the DMA made eight lines of the beam (`DMAWait`, which the patch
        // runs on into).
        let patch4 = a.placed()
        a.w(0x7203, 0x740C, 0x7606) // MOVEQ #3,D1; MOVEQ #12,D2; MOVEQ #6,D3
        _ = a.dmaWait(lines: 8)
        patches.add([0x7203, 0x740C, 0x7606], patch: patch4)
        // Code5, Patch5: a voice's next byte of its music read (A0 the voice's record, 12(A0) its place);
        // the end of its music ($FF) counted for the voice whose number is in the module's byte at
        // `BytePtr`, and once all four have come to it, the song's end said and the count begun again.
        let patch5 = a.placed()
        let noEnd = a.label(), test = a.label(), skipEnd = a.label()
        a.w(0x1028, 0x000C, 0x5228, 0x000C, 0xD3C0, 0x0C11, 0x00FF) // MOVE.B 12(A0),D0; ADDQ.B #1,12(A0); ADDA.L D0,A1; CMPI.B #$FF,(A1)
        a.branch(0x6600, to: noEnd) // BNE.B NoEnd
        a.w(0x48E7, 0x0064, 0x247A) // MOVEM.L A1/A2/A5,-(A7); MOVEA.L BytePtr(PC),A2
        a.displacement(to: byte)
        a.w(0x43FA)
        a.displacement(to: songEnd) // LEA SongEnd(PC),A1
        for v in 0 ..< 4 {
            let next = a.label()
            if v == 0 { a.w(0x4A12) } else { a.w(0x0C12, UInt16(v)) } // TST.B (A2), or CMPI.B #v,(A2)
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
        a.w(0x22BC, 0x5754, 0x5754, 0x2A7A) // MOVE.L #'WTWT',(A1); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(skipEnd)
        a.w(0x4CDF, 0x2600) // MOVEM.L (A7)+,A1/A2/A5
        a.place(noEnd)
        a.w(0x4E75)
        patches.add([0x1028, 0x000C, 0x5228, 0x000C, 0xD3C0], patch: patch5)
        // Code6, Patch6: Wally Beben's code stopping the voices; the first time (as it starts) noted, and
        // the song's end said every time after, the scopes cleared.
        let patch6 = a.placed()
        let noEnd2 = a.label(), clear = a.label()
        a.w(0x3B40, 0x0010, 0x3B40, 0x0020, 0x4A79) // MOVE.W D0,$10(A5); MOVE.W D0,$20(A5); TST.W EndFlag
        a.address(of: endFlag)
        a.branch(0x6700, to: noEnd2) // BEQ.B NoEnd2
        a.w(0x48E7, 0x0044, 0x2A7A) // MOVEM.L A1/A5,-(A7); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91, 0x4BFA) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1); LEA StructAdr(PC),A5
        a.displacement(to: scopes[0])
        a.w(0x43ED, 0x0050) // LEA UPS_SizeOF(A5),A1
        a.place(clear)
        a.w(0x425D, 0xB3CD) // CLR.W (A5)+; CMPA.L A5,A1
        a.branch(0x6600, to: clear) // BNE.B ClearUPS2
        a.w(0x4CDF, 0x2200) // MOVEM.L (A7)+,A1/A5
        a.place(noEnd2)
        a.w(0x50F9)
        a.address(of: endFlag) // ST EndFlag
        a.w(0x4E75)
        patches.add([0x3B40, 0x0010, 0x3B40, 0x0020], patch: patch6)
        // Code7, Patch7: the offset of a sample's repeat read whole, in Wally Beben's older code.
        let patch7 = a.placed()
        a.w(0x0286, 0x0000, 0xFFFF, 0x4E75) // ANDI.L #$FFFF,D6; RTS
        patches.add([0x0286, 0x0000, 0x0FFF], patch: patch7)
        patches.assemble(&a)

        modulePtr = a.addressOf(module)
        a4BasePtr = a.addressOf(a4Base)
        samplesPtr = a.addressOf(samples)
        songsPtr = a.addressOf(songs)
        voicesPtr = a.addressOf(voicesList)
        bytePtr = a.addressOf(byte)
        samplesSizeAt = a.addressOf(info[11])
    }

    /// `InitPlayer` (lines 384-496).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let refusal = TuneError.malformed("a module of Steve Barrett's whose code is not as the player looks for")
        // The module (`dtg_GetListData`), and its samples made ready by its first routine.
        _ = try host.call(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgGetListData), with: [(0, 0)])
        let module = host.machine.cpu.registers[8], size = host.machine.cpu.registers[0]
        host.machine.poke32(modulePtr, module)
        _ = try host.call(module, with: [(0, size), (8, module), (14, a4BasePtr)])
        let samplesEnd = host.machine.cpu.registers[8]
        let most = Int(size) + 0x1000
        // FindIt0: the first LEA d(PC),A0; the displacement before it (the LEA d(PC),A4 before it) gives the
        // base of the module's variables, and its own its samples.
        guard var a1 = WantedTeamSearch.find(host, [0x41FA], from: module, most: most).map({ $0 + 2 }) else { throw refusal }
        let a4Base = Self.displaced(host, a1 - 4)
        let samples = Self.displaced(host, a1)
        host.machine.poke32(a4BasePtr, a4Base)
        host.machine.poke32(samplesPtr, samples)
        // (The samples' size, by which InitSound knows Advanced Ski Simulator.)
        let calcSize = samplesEnd &- module &+ 4
        host.machine.poke32(samplesSizeAt, calcSize &- (samples &- module))
        // FindIt1: past ASL.W #3,D0; CLR.L D1; LEA d(PC),A0, the list of songs.
        guard let found1 = WantedTeamSearch.find(host, [0xE740, 0x4281], from: a1, most: most) else { throw refusal }
        a1 = found1 + 6
        let songs = Self.displaced(host, a1)
        host.machine.poke32(songsPtr, songs)
        // FindIt5: the next LEA d(PC),A0, the voices' records.
        guard let found5 = WantedTeamSearch.find(host, [0x41FA], from: a1, most: most) else { throw refusal }
        a1 = found5 + 2
        host.machine.poke32(voicesPtr, Self.displaced(host, a1))
        // FindIt2: past ADD.L D0,D0; LEA d(PC),A1, what follows the list of songs: its songs, eight bytes
        // each.
        guard let found2 = WantedTeamSearch.find(host, [0xD080, 0x43FA], from: a1, most: most) else { throw refusal }
        a1 = found2 + 4
        let count = (Self.displaced(host, a1) &- songs) >> 3
        // FindIt3: past MOVE.B #3,d(A4), the module's byte that says which voice it is playing.
        guard let found3 = WantedTeamSearch.find(host, [0x197C, 0x0003], from: a1, most: most) else { throw refusal }
        a1 = found3 + 4
        host.machine.poke32(bytePtr, a4Base &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(a1)))))
        // FindIt4: ADDA.L D3,A1; MOVE.W D0,(A1); RTS, the module's write of a period.
        var from = a1
        var period: UInt32?
        while period == nil, let at = WantedTeamSearch.find(host, [0xD3C3, 0x3280], from: from, most: most - Int(from &- module)) {
            if host.machine.peek16(at + 4) == 0x4E75 { period = at }
            from = at + 2
        }
        guard let period else { throw refusal }
        // FindT (lines 472-486): the text at the module's 16th byte, its "tt" followed by a line's end and
        // ended at the byte before the code after it (two before the first byte $FA).
        let textAt = module + 16
        Self.endText(&host, from: textAt, end: module &+ UInt32(most))
        detail = String(host.string(at: textAt, most: 120).map { $0 == "\n" ? " " : $0 })
        // `ModuleChange` (lines 262-281): the patches made in the 2,300 bytes from the module's start; and
        // the period's call made a jump (line 493).
        patches.apply(&host, from: module, length: 2300)
        host.machine.poke16(period, 0x4EF9)
        guard count > 0 else { throw refusal }
        return WantedTeamSongs(first: 1, count: Int(min(count, 256)))
    }

    /// The address a word of displacement at `at` points at.
    private static func displaced(_ host: borrowing DeliTrackerHost, _ at: UInt32) -> UInt32 {
        at &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(at))))
    }

    /// `FindT`: the module's text, from `from`, given a line's end after its first "tt" and ended two bytes
    /// before the first byte $FA after that; nothing done if a byte $FA comes first (where it is looked for).
    private static func endText(_ host: inout DeliTrackerHost, from: UInt32, end: UInt32) {
        let end = min(end, UInt32(host.memorySize))
        var at = from
        while at < end, host.machine.peek8(at) != 0xFA {
            at += 1
            guard host.machine.peek8(at - 1) == 0x74, at < end else { continue }
            at += 1
            guard host.machine.peek8(at - 1) == 0x74, at < end else { continue }
            host.machine.poke8(at, 10)
            at += 1
            while at < end {
                at += 1
                if host.machine.peek8(at - 1) == 0xFA {
                    host.machine.poke8(at - 3, 0)
                    return
                }
            }
            return
        }
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
