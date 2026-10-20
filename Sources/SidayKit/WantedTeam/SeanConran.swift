// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Sean Conran's music ("Sean Conran player module V1.2 (10 Nov
// 2003)", UADE's players/SeanConran, whose source is UADE's amigasrc/players/wanted_team/SeanConran/"Sean
// Conran_v3.asm"). The addresses given are of the player's hunk in UADE's file.

/// Sean Conran's music for the Amiga (of 1989 to 1991, as the player's credit has it: Count Duckula,
/// Defenders of the Earth, Hong Kong Phooey, Infestation, Mega Twins, Ruff and Reddy, Top Cat, Videokid,
/// WWF Wrestlemania, Wacky Races, Yogi Bear and Friends), as Wanted Team adapted it: each module is his
/// 68000 code that plays it (written to run wherever it is put), with its music and samples, as it was in
/// the game: a table of periods first ($0FFF $0FE2 or $1000 $0FE2 and on, or $0F1C $0F0E and on), then the
/// code, a string "Sean Conran ...", the songs and the samples.
///
/// As the player plays it: the module's routines to start a song and for a tick found in its code by the
/// instructions around them, and its songs counted from the table of them its start points at (or one);
/// two modules that set their own audio interrupt (Infestation, Mega Twins) have it taken out and their
/// routine, its RTEs made RTSs, called through exec's SetIntVector for each of Paula's four interrupts
/// (and their code mended where the player's author found it went wrong on faster machines); and a song ends
/// each time the list of its positions comes to a command (a byte with its top bit set), whose reading the
/// player makes a call of its own, put over the module's "Sean" (and from which it notes where the song
/// is).
typealias SeanConranPlayer = WantedTeamPlayer<SeanConran>

struct SeanConran: WantedTeamRecipe {
    static let format = "Sean Conran"

    /// `Check2` ($38E): the module's first words its table of periods, $0FFF $0FE2 $0FC4 $0FA7 $0F8B $0F6E
    /// (or the same from $1000), or $0F1C $0F0E $0F00 $0EF2 $0EE4 $0ED6; and none of the 128 words from the
    /// file's 292nd byte (its 452nd for the second kind) $FFFF, nor a long of them $7F7F7F7F (a bank of
    /// sounds, not music).
    static func isOne(_ data: [UInt8]) -> Bool {
        func long(_ at: Int) -> UInt32 { WantedTeamHeader.long(data, at) }
        var at: Int
        if long(0) == 0x0FFF_0FE2 || long(0) == 0x1000_0FE2 {
            guard long(4) == 0x0FC4_0FA7, long(8) == 0x0F8B_0F6E else { return false }
            at = 8
        } else {
            guard long(0) == 0x0F1C_0F0E, long(4) == 0x0F00_0EF2, long(8) == 0x0EE4_0ED6 else { return false }
            at = 168
        }
        at += 284
        for _ in 0 ..< 128 {
            if long(at) == 0x7F7F_7F7F || long(at) >> 16 == 0xFFFF { return false }
            at += 2
        }
        return true
    }

    let title = ""
    /// (The player gives his name as the author's: `MI_AuthorName`.)
    let author = "Sean Conran"

    /// The player's variables and routines, where they are assembled.
    private var initPtr: UInt32 = 0, songsPtr: UInt32 = 0, playPtr: UInt32 = 0, firstPos: UInt32 = 0
    private var twin: UInt32 = 0, intAddress: UInt32 = 0, extraPatch: UInt32 = 0, here: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    /// The patches of the modules of 1990 and 1991 (`PatchTable`, $872), and of 1989 (`PatchTable2`, $8C6),
    /// and where the displacements of the module's moves of each voice's place go in each (`ChangeIt1` on).
    private var patches = WantedTeamPatches(), oldPatches = WantedTeamPatches()
    private var changeIts: [UInt32] = [], oldChangeIts: [UInt32] = []

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($136 to $1B2), in the player's order where its code relies on it: `FirstPos` then
        // `CurrentPos`.
        let module = a.variable(long: 0), initRoutine = a.variable(long: 0), songs = a.variable(long: 0)
        let play = a.variable(long: 0)
        _ = a.variable(word: 0) // Change
        let eagleBase = a.eagleBase()
        let first = a.variable(long: 0), current = a.variable(long: 0)
        let twinFlag = a.variable(word: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // (`InfoBuffer`, $402: of what it tells EaglePlayer only the song's length is written as it plays.)
        let info = a.placed()
        for _ in 0 ..< 6 { a.long(0) }
        // `SetVolume` ($214, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `Left2`, `Left1`, `Right1`, `Right2` ($238 to $260) and the same for D4 ($262 to $28A): a voice's
        // volume in D6 (or D4) turned down by its side's balance, nought if it is muted.
        func sides(_ a: inout AmigaAssembly, register r: UInt16) -> [Int] {
            let ex = a.label()
            var routines = [Int](repeating: 0, count: 4)
            for (v, side, last) in [(3, leftVolume, false), (0, leftVolume, false), (1, rightVolume, false), (2, rightVolume, true)] {
                routines[v] = a.placed()
                a.w(0xC0FA | r << 9)
                a.displacement(to: side) // MULU.W side(PC),Dr
                a.w(0xC07A | r << 9)
                a.displacement(to: voices[v]) // AND.W Voice(PC),Dr
                if !last { a.branch(0x6000, to: ex) } // BRA.S Ex
            }
            a.place(ex)
            a.w(0xEC48 | r, 0x4E75) // LSR.W #6,Dr; RTS
            return routines
        }
        let side6 = sides(&a, register: 6), side4 = sides(&a, register: 4)
        // `SetVol1` to `SetVol4` ($28C), the same for D4 ($2B0), `SetPer1` ($2D4) and `SetAdr1` ($2F8): the
        // scopes told a voice's volume (D6 or D4), period (D1) or sample (A1), through A2.
        func scopeSet(_ a: inout AmigaAssembly, field: Int, body: UInt16) -> [Int] {
            let set = a.label()
            var routines: [Int] = []
            for v in 0 ..< 4 {
                routines.append(a.placed())
                a.w(0x2F0A, 0x45FA) // MOVE.L A2,-(A7); LEA StructAdr+UPS_VoiceN...(PC),A2
                a.displacement(to: scopes[v * 9 + field])
                if v < 3 { a.branch(0x6000, to: set) } // BRA.B SetVoice
            }
            a.place(set)
            a.w(body, 0x245F, 0x4E75) // MOVE.x ...,(A2); MOVEA.L (A7)+,A2; RTS
            return routines
        }
        let setVol6 = scopeSet(&a, field: 4, body: 0x3486) // MOVE.W D6,(A2)
        let setVol4 = scopeSet(&a, field: 4, body: 0x3484) // MOVE.W D4,(A2)
        let setPer = scopeSet(&a, field: 3, body: 0x3481) // MOVE.W D1,(A2)
        let setAdr = scopeSet(&a, field: 0, body: 0x2489) // MOVE.L A1,(A2)
        // `ExtraPatch` ($686): called in place of the module's reading of a byte of the song's positions
        // (`MOVE.B (A0)+,D0; BMI.S`): the place noted (`CurrentPos`), and a byte with its top bit set, a
        // command, made the song's end said (the place noted put back by the byte after it, less one, if
        // that is above nought) before the module goes on to its handling of it (`Here`, filled in).
        let jump = a.label(), noSub = a.label()
        extraPatch = a.here
        a.w(0x23C8)
        a.address(of: current) // MOVE.L A0,CurrentPos
        a.w(0x1018) // MOVE.B (A0)+,D0
        a.branch(0x6B00, to: jump) // BMI.B Jump
        a.w(0x4E75)
        a.place(jump)
        a.w(0x588F, 0x7000, 0x1010) // ADDQ.L #4,SP; MOVEQ #0,D0; MOVE.B (A0),D0
        a.branch(0x6B00, to: noSub) // BMI.B NoSub
        a.branch(0x6700, to: noSub) // BEQ.B NoSub
        a.w(0x5380, 0x91B9) // SUBQ.L #1,D0; SUB.L D0,CurrentPos
        a.address(of: current)
        a.place(noSub)
        let songEnd = a.label()
        a.w(0x6100)
        a.displacement(to: songEnd) // BSR.W SongEnd
        let jumpAt = a.placed()
        a.w(0x4EF9, 0x5754, 0x5754) // JMP 'WTWT'
        // `InitSound` ($6B4, DTP_InitSound): the song's place, from the table of songs (its words offsets
        // into the module, eight bytes apart) or the one the module has, as `FirstPos` and `CurrentPos`;
        // Infestation (its long at 150 of its start $00020A69) and Mega Twins (`Twin`) mended; the module's
        // start called with $0F00 and the song's number in D0; and its audio interrupt, if it has one, made
        // Paula's four's.
        let structure = a.placed()
        a.w(0, 0, 0, 0, 0x0205, 0, 0, 0, 0) // LN_SUCC, LN_PRED, LN_TYPE/LN_PRI, LN_NAME, IS_DATA
        let isCode = a.variable(long: 0) // IS_CODE (`IntAddress`)
        let channels = (0 ..< 4).map { _ in a.variable(long: 0) }
        let setAudioVector = a.setAudioVector(structure: structure, old: channels)
        initSoundAt = a.here
        let multi = a.label(), put = a.label(), findEnd = a.label(), noInfest = a.label(), noMega = a.label()
        let noAudio = a.label()
        a.clearScopes(scopes)
        // MOVE.W dtg_SndNum(A5),D0; MOVE.W D0,D1; ADDI.W #$0F00,D0; LEA FirstPos(PC),A2
        a.w(0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x3200, 0x0640, 0x0F00, 0x45FA)
        a.displacement(to: first)
        a.w(0x243A)
        a.displacement(to: songs) // MOVE.L SongsPtr(PC),D2
        a.branch(0x6600, to: multi) // BNE.B Multi
        a.w(0x225A) // MOVEA.L (A2)+,A1
        a.branch(0x6000, to: put) // BRA.B Put
        a.place(multi)
        a.w(0x2242, 0xE749, 0x43F1, 0x1000, 0x3251, 0xD3FA) // MOVEA.L D2,A1; LSL.W #3,D1; LEA 0(A1,D1.W),A1; MOVEA.W (A1),A1; ADDA.L ModulePtr(PC),A1
        a.displacement(to: module)
        a.w(0x24C9) // MOVE.L A1,(A2)+
        a.place(put)
        a.w(0x2489, 0x2209) // MOVE.L A1,(A2); MOVE.L A1,D1
        a.place(findEnd)
        a.w(0x0C19, 0x00FF) // CMPI.B #$FF,(A1)+
        a.branch(0x6600, to: findEnd) // BNE.B FindEnd
        a.w(0x93C1, 0x45FA) // SUBA.L D1,A1; LEA InfoBuffer(PC),A2
        a.displacement(to: info)
        a.w(0x2549, 0x0014, 0x207A) // MOVE.L A1,Length(A2); MOVEA.L InitPtr(PC),A0
        a.displacement(to: initRoutine)
        a.w(0x0CA8, 0x0002, 0x0A69, 0x0096) // CMPI.L #$00020A69,150(A0)
        a.branch(0x6600, to: noInfest) // BNE.B NoInfest
        a.w(0x117C, 0x0002, 0x08AD) // MOVE.B #2,2221(A0)
        a.branch(0x6000, to: noMega) // BRA.B NoMega
        a.place(noInfest)
        a.w(0x323A)
        a.displacement(to: twinFlag) // MOVE.W Twin(PC),D1
        a.branch(0x6700, to: noMega) // BEQ.B NoMega
        // MOVE.W #$2E6,272(A0); MOVE.W #$2FE,312(A0); MOVE.W #$316,352(A0); MOVE.W #$32E,392(A0)
        a.w(0x317C, 0x02E6, 0x0110, 0x317C, 0x02FE, 0x0138, 0x317C, 0x0316, 0x0160, 0x317C, 0x032E, 0x0188)
        a.place(noMega)
        a.w(0x4E90, 0x203A) // JSR (A0); MOVE.L IntAddress(PC),D0
        a.displacement(to: isCode)
        a.branch(0x6700, to: noAudio) // BEQ.B NoAudio2
        a.w(0x6100)
        a.displacement(to: setAudioVector) // BSR.W SetAudioVector
        a.place(noAudio)
        a.w(0x4E75)
        // `Interrupt` ($76A, DTP_Interrupt), and `SongEnd` ($7A2).
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 4)
        a.place(songEnd)
        a.callSongEnd(eagleBase: eagleBase)
        a.w(0x4E75)
        // The patches, each with the module's code it is called in place of: for the modules of 1990 and
        // 1991 (`PatchTable`), the voices' registers' copies from A3, and of 1989 (`PatchTable2`), from A6.
        // Code4 to Code7, CodeG to CodeJ ($912 to $968, $A4A to $AA0): a voice's period, as it is, and told
        // the scopes; the module's move of the place it has come to, its displacement found in its code.
        var changes: [UInt32] = [], oldChanges: [UInt32] = []
        var changeLabels: [Int] = [], oldChangeLabels: [Int] = []
        for old in [false, true] {
            for v in 0 ..< 4 {
                let patch = a.placed()
                let move: UInt16 = old ? 0x3D41 : 0x3741, place: UInt16 = old ? 0x2B48 : 0x2548
                a.w(move, UInt16(0x10 + v * 0x10), 0x6100) // MOVE.W D1,$v0(A3); BSR.W SetPerN
                a.displacement(to: setPer[v])
                let change = a.placed()
                a.w(place, 0, 0x4E75) // MOVE.L A0,d16(A2) (or (A5)); RTS
                if old { oldChangeLabels.append(change) } else { changeLabels.append(change) }
                // MOVE.W D1,$v0(A3); MOVE.L A0,d16(A2)
                if old { oldPatches.add([move, UInt16(0x10 + v * 0x10), place, 0], patch: patch) } else {
                    patches.add([move, UInt16(0x10 + v * 0x10), place, 0], patch: patch)
                }
            }
            // Code8 to CodeB, CodeK to CodeN ($96A to $A48, $AA2 to $B80): a voice's volume, from D6 (or
            // D4) or a table, turned down through `Left1` and the rest, told the scopes, and written.
            for v in 0 ..< 4 {
                let patch = a.placed(), fromTable = a.label(), done = a.label()
                let r: UInt16 = old ? 4 : 6, base: UInt16 = old ? 0x3D40 : 0x3740, at = UInt16(0x12 + v * 0x10)
                let side = (old ? side4 : side6)[v], set = (old ? setVol4 : setVol6)[v]
                a.branch(0x6A00, to: fromTable) // BPL.B
                a.w(0x6100)
                a.displacement(to: side) // BSR.W Left1 (or the rest)
                a.w(0x6100)
                a.displacement(to: set) // BSR.W SetVol1 (or the rest)
                a.w(base | r, at) // MOVE.W Dr,$12(A3)
                a.branch(0x6000, to: done) // BRA.B
                a.place(fromTable)
                a.w(0xD241, 0x2F00 | r, 0x3030 | r << 9, 0x1000, 0x6100) // ADD.W D1,D1; MOVE.L Dr,-(A7); MOVE.W 0(A0,D1.W),Dr; BSR.W
                a.displacement(to: side)
                a.w(0x6100)
                a.displacement(to: set)
                a.w(base | r, at, 0x201F | r << 9) // MOVE.W Dr,$12(A3); MOVE.L (A7)+,Dr
                a.place(done)
                a.w(0x4E75)
                // BPL.S *+8; MOVE.W Dr,$12(A3); BRA.S *+10; ADD.W D1,D1; MOVE.W 0(A0,D1.W),$12(A3)
                let pattern: [UInt16] = [0x6A06, base | r, at, 0x6008, 0xD241, base | 0x30, 0x1000, at]
                if old { oldPatches.add(pattern, patch: patch) } else { patches.add(pattern, patch: patch) }
            }
            // CodeS to CodeV, CodeO to CodeR ($BCA to $C10, $B82 to $BC8): a voice's sample, its offset added
            // to the module's address, as it is, and told the scopes.
            for v in 0 ..< 4 {
                let patch = a.placed()
                let code: [UInt16] = old ? [0xD3CD, 0x2D49, UInt16(10 + v * 16)] : [0xD3CA, 0x2749, UInt16(10 + v * 16)]
                for word in code { a.w(word) } // ADDA.L A2,A1 (or A5); MOVE.L A1,10(A3) (or A6)
                a.w(0x6100)
                a.displacement(to: setAdr[v]) // BSR.W SetAdrN
                a.w(0x4E75)
                if old { oldPatches.add(code, patch: patch) } else { patches.add(code, patch: patch) }
            }
        }
        // CodeX and CodeY, PatchX and PatchY ($C12, $C1A; $C3A, $C42): Mega Twins' setting of the first two
        // voices' sample, from D1, and its length, as they are, and told the scopes.
        for v in 0 ..< 2 {
            let patch = a.placed()
            let place = UInt16(10 + v * 16), length = UInt16(14 + v * 16)
            a.w(0x2741, place, 0x2F09, 0x2241, 0x6100) // MOVE.L D1,10(A3); MOVE.L A1,-(A7); MOVEA.L D1,A1; BSR.W SetAdrN
            a.displacement(to: setAdr[v])
            a.w(0x225F, 0x2F0A, 0x45FA) // MOVEA.L (A7)+,A1; MOVE.L A2,-(A7); LEA StructAdr(PC),A2
            a.displacement(to: scopes[0])
            // MOVE.W (A1),UPS_VoiceNLen(A2); MOVE.W (A1)+,14(A3); MOVEA.L (A7)+,A2; RTS
            a.w(0x3551, UInt16(4 + v * 18), 0x3759, length, 0x245F, 0x4E75)
            patches.add([0x2741, place, 0x3759, length], patch: patch)
        }
        patches.assemble(&a)
        oldPatches.assemble(&a)
        for label in changeLabels { changes.append(a.addressOf(label) + 2) }
        for label in oldChangeLabels { oldChanges.append(a.addressOf(label) + 2) }
        changeIts = changes
        oldChangeIts = oldChanges
        modulePtr = a.addressOf(module)
        initPtr = a.addressOf(initRoutine)
        songsPtr = a.addressOf(songs)
        playPtr = a.addressOf(play)
        firstPos = a.addressOf(first)
        twin = a.addressOf(twinFlag)
        intAddress = a.addressOf(isCode)
        here = a.addressOf(jumpAt) + 2
        tick = a.addressOf(tickRoutine)
    }

    private var modulePtr: UInt32 = 0

    /// `InitPlayer` ($42E).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        func refuse() -> TuneError { .malformed("a module of Sean Conran's whose code is not as the player looks for") }
        let module = host.moduleAt
        let size = UInt32(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgChkSize))
        let most = UInt32(host.memorySize - DeliTrackerHost.room)
        func word(_ at: UInt32) -> UInt16 { host.machine.peek16(at) }
        func long(_ at: UInt32) -> UInt32 { host.machine.peek32(at) }
        func relative(_ at: UInt32) -> UInt32 { at &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(at)))) }
        host.machine.poke32(modulePtr, module)
        let old = word(module) == 0x0FFF
        // `FindInit` ($45E): the module's start, the first `LEA d16(PC),A2`, `LEA abs.L,A1` or `LEA abs.L,A0`
        // from 292 bytes in (452 in the second kind), before a long of nought.
        var at = module + (word(module) == 0x0F1C ? 452 : 292)
        while ![0x45FA, 0x43F9, 0x41F9].contains(word(at)) {
            guard long(at) != 0, at + 8 < most else { throw refuse() }
            at += 2
        }
        let start = at
        host.machine.poke32(initPtr, start)
        // `Next` ($47C): its first `MOVEQ #0,D1` (a module of songs) or `MOVEQ #0,D0` (of one).
        while word(at) != 0x7200, word(at) != 0x7000 {
            guard at + 8 < most else { throw refuse() }
            at += 2
        }
        var songs: UInt32 = 1
        if word(at) == 0x7000 {
            // `OneSub` ($48C): the song's place, where the first `LEA d16(PC),A0` points.
            while word(at) != 0x41FA {
                guard at + 8 < most else { throw refuse() }
                at += 2
            }
            at += 2
            host.machine.poke32(firstPos, relative(at))
        } else {
            // `FindIt0` ($4A2): the table of songs, where the first `LEA d16(PC),A1` points (or `LEA
            // d16(A2),A1`, A2 the module's address), before a long of nought; on the way, a module's setting
            // of its own audio interrupt (`MOVE.L A0,$70.W`) made NOPs, the routine that the `LEA d16(PC),A0`
            // before it points at kept as the audio interrupt, and every RTE from 450 bytes in to the start
            // made an RTS; and Mega Twins' address of its own (its long at 588 $3B76) made the module's.
            var table: UInt32?
            while table == nil {
                guard long(at) != 0, at + 8 < most else { throw refuse() }
                switch word(at) {
                case 0x43FA:
                    table = relative(at + 2)
                    at += 2
                case 0x43EA:
                    table = module &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(at + 2))))
                    at += 2
                default:
                    if long(at) == 0x21C8_0070 {
                        host.machine.poke32(at, 0x4E71_4E71)
                        at += 4
                        host.machine.poke32(intAddress, relative(at - 6))
                        guard start > module + 450 else { throw refuse() }
                        var rte = module + 450
                        while rte != start {
                            if word(rte) == 0x4E73 { host.machine.poke16(rte, 0x4E75) }
                            rte += 2
                        }
                        if long(module + 588) == 0x3B76 {
                            host.machine.poke32(module + 588, 0x3B76 &+ module &- 5236)
                            host.machine.poke8(twin, 0xFF)
                        }
                    } else {
                        at += 2
                    }
                }
            }
            // `SkipIt1` ($514): as many songs as the table's eight bytes go up to the first song's place.
            let first = UInt32(word(table!))
            songs = (first &- (table! &- module)) >> 3
            host.machine.poke32(songsPtr, table!)
        }
        // `FindPlay` ($524): the routine for a tick, four bytes past the first `MOVE.B D0,(A0)`, `CLR.B (A0)`
        // or `ST (A0)` (the end of the start), before a long of nought.
        while ![0x1080, 0x4210, 0x50D0].contains(word(at)) {
            guard long(at) != 0, at + 8 < most else { throw refuse() }
            at += 2
        }
        at += 4
        let play = at
        host.machine.poke32(playPtr, play)
        // `FindIt1` ($5AA), or `FindIt11` ($54C): the displacements of the module's moves of where each voice
        // has come to, after each of its four writes of a period (`MOVE.W D1,d16(A3)`, or `(A6)`), put in the
        // patches for them.
        let changes = old ? oldChangeIts : changeIts
        let table = old ? oldPatches : patches
        for v in 0 ..< 4 {
            while true {
                let w = word(at)
                at += 2
                if w == (old ? 0x3D41 : 0x3741) { break }
                guard long(at) != 0, at + 8 < most else { throw refuse() }
            }
            at += 4
            host.machine.poke16(table.patternAt[v] + 6, word(at))
            host.machine.poke16(changes[v], word(at))
        }
        // `ModuleChange` ($1C0): the patches made in the 2,200 bytes from the routine for a tick (2,000 for a
        // module of 1989).
        table.apply(&host, from: play, length: old ? 2000 : 2200)
        // `Find1` ($60E): the start's reading of a byte of the song's positions, `MOVE.B (A0)+,D0; BMI.S`,
        // made a `BSR.W` to a `JMP ExtraPatch` put over the first "Sean" within 32,767 bytes of where the
        // BMI goes (and before the module's end), and that place given to `ExtraPatch` to go on at.
        at = start
        repeat {
            guard at + 8 < most else { throw refuse() }
            at += 2
        } while !(word(at - 2) == 0x1018 && word(at) >> 8 == 0x6B)
        let read = at - 2
        at = at + 2 &+ UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(word(at) & 0xFF))))
        host.machine.poke32(here, at)
        let limit = min(at &+ 32767, module + size)
        guard at < limit, limit <= most else { throw refuse() }
        while !(host.machine.peek8(at) == 0x53 && host.machine.peek8(at + 1) == 0x65 && host.machine.peek8(at + 2) == 0x61
            && host.machine.peek8(at + 3) == 0x6E)
        {
            at += 1
            guard at != limit else { throw refuse() }
        }
        let stub = (at &- 1) & ~1
        host.machine.poke16(stub, 0x4EF9)
        host.machine.poke32(stub + 2, extraPatch)
        host.machine.poke16(read, 0x6100)
        host.machine.poke16(read + 2, UInt16(truncatingIfNeeded: stub &- (read + 2)))
        return WantedTeamSongs(first: 0, count: Int(min(songs, 256)))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
