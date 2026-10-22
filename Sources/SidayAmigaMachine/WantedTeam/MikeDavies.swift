// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Mike Davies' music ("Mike Davies player module V1.0 (30 Sep
// 2000)", UADE's players/MikeDavies), whose source is not given: what it does is read from its code, and
// the addresses given are of its hunk in UADE's file.

import SidayFoundation

/// Mike Davies' music for the Amiga (of 1989 to 1994, as the player's credit has it): each module is his
/// 68000 code that plays it, with its music and samples, as it was saved from the game, at the address
/// it ran at. It begins with its variables (noughts, as saved); then his routine to start a song (with
/// its number in D0) and his routine for a tick, each beginning `MOVEM.L D0-A6,-(A7)`. The player finds
/// his tables by his instructions, works out from the first `MOVE.W #1,$Address` (of the first of his
/// variables) where the module was saved, and moves the addresses in its code and tables to where it is
/// (`FixedOriginCode`); the patterns' addresses in his tracks, after a command whose number it reads from
/// his code, too.
///
/// As the player plays it: the module's busy waits (a count in D0 run down by DBF) made eight lines of
/// the beam; its writes of the four voices' samples, lengths, periods and volumes told EaglePlayer's
/// scopes, the volumes turned down by the balance, which is none. A song ends when the module turns all
/// four voices' DMA off (but while a song is being started); or, in a module whose command for a pattern
/// is $E5 (in UnExoticA's, it is $95), when its `MOVE.W 32(A5),28(A5)` runs with $FE in the word at 2(A0).
typealias MikeDaviesPlayer = WantedTeamPlayer<MikeDavies>

struct MikeDavies: WantedTeamRecipe {
    static let format = "Mike Davies"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -21.0 dB.)
    static let gain: Float = 0.32

    /// `Check2` ($324): `MOVEM.L D0-A6,-(A7); BSR.S *+8; MOVEM.L (A7)+,D0-A6; RTS` ending at 242 bytes in
    /// and followed by a `CMPI.W #x,D0` (or 6 bytes earlier, and followed by a `MOVE.W D0,$Address`); and
    /// the first BRA.W after it going forward, to a `MOVE.L (A0)+,x(A6)`.
    static func isOne(_ data: [UInt8]) -> Bool {
        func word(_ at: Int) -> UInt16 {
            at >= 0 && at + 2 <= data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
        }
        var at = 242
        if word(at) != 0x0C40 {
            at -= 6
            guard word(at) == 0x33C0 else { return false }
        }
        guard WantedTeamHeader.long(data, at - 4) == 0x7FFF_4E75, WantedTeamHeader.long(data, at - 8) == 0x6106_4CDF,
              WantedTeamHeader.long(data, at - 12) == 0x48E7_FFFE
        else { return false }
        at -= 12
        // (The player's search runs on until it finds one; here it stops at the file's end.)
        repeat {
            guard at + 2 <= data.count else { return false }
            at += 2
        } while word(at - 2) != 0x6000
        let to = Int16(bitPattern: word(at))
        return to > 0 && to % 2 == 0 && word(at + Int(to)) == 0x2D58
    }

    let title = ""
    let author = "Mike Davies"

    /// The player's variables and routines, where they are assembled.
    private var modulePtr: UInt32 = 0, initPtr: UInt32 = 0, songsPtr: UInt32 = 0, playPtr: UInt32 = 0
    private var commandAt: UInt32 = 0
    private var setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    /// The instructions with an address in them that the player moves ($46A-$4BC).
    static let code = FixedOriginCode(forms: [
        (0x3039, .address), (0x33C0, .address), (0x33C1, .address), (0x33EE, .afterWord), (0x33F9, .twoAddresses),
        (0x33FC, .afterWord), (0x3C39, .address), (0x41F9, .address), (0x4279, .address), (0x4A79, .address),
        (0x4BF9, .address), (0x4DF9, .address), (0x5379, .address), (0xB1FC, .address),
    ])

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($12C to $1C1), in the player's order.
        let module = a.variable(long: 0), initSong = a.variable(long: 0), songs = a.variable(long: 0)
        _ = (0 ..< 2).map { _ in a.variable(long: 0) } // the second table of samples', and its end's
        let play = a.variable(long: 0)
        _ = a.variable(long: 0) // the first table of samples'
        _ = a.variable(word: 0) // its samples
        _ = a.variable(long: 0) // ChangeLen
        _ = a.variable(word: 0) // Change
        let eagleBase = a.eagleBase()
        _ = a.variable(long: 0) // the samples' tables' end
        _ = a.variable(word: 0) // the second table's samples
        let command = a.variable(word: 0)
        let starting = a.variable(word: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 1) }
        let volumes = (0 ..< 4).map { _ in a.variable(word: 0) }
        let scopes = a.scopes()
        // `ModuleInfo` ($2C8), of which `InitSound` sets the number of voices the song has.
        let info = a.placed()
        for _ in 0 ..< 44 { a.w(0) }
        // `Interrupt` ($222, DTP_Interrupt): the module's routine for a tick.
        let tickRoutine = a.tickRoutine(play: play, scopes: scopes, voices: 4)
        // `InitSound` ($688, DTP_InitSound): the scopes' volumes cleared, the song's voices counted (those
        // whose track is not -1), and the module's routine to start a song called with its number in D0,
        // `starting` set meanwhile.
        let initSound = a.placed()
        let count = a.label(), none = a.label()
        a.w(0x41FA)
        a.displacement(to: scopes[0]) // LEA StructAdr(PC),A0
        for v in 0 ..< 4 { a.w(0x4268, UInt16(8 + v * 18)) } // CLR.W UPS_VoiceNVol(A0)
        a.w(0x43FA)
        a.displacement(to: starting) // LEA starting(PC),A1
        a.w(0x50D1, 0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x207A) // ST (A1); MOVE.W dtg_SndNum(A5),D0; MOVEA.L songs(PC),A0
        a.displacement(to: songs)
        a.w(0x2050, 0x3200, 0x5341, 0xE949, 0x41F0, 0x1000) // MOVEA.L (A0),A0; MOVE.W D0,D1; SUBQ.W #1,D1; LSL.W #4,D1; LEA 0(A0,D1.W),A0
        a.w(0x76FF, 0x7200, 0x7403) // MOVEQ #-1,D3; MOVEQ #0,D1; MOVEQ #3,D2
        a.place(count)
        a.w(0xB698) // CMP.L (A0)+,D3
        a.branch(0x6700, to: none) // BEQ.B
        a.w(0x5281) // ADDQ.L #1,D1
        a.place(none)
        a.w(0x51CA)
        a.displacement(to: count) // DBF D2,
        a.w(0x41FA)
        a.displacement(to: info) // LEA ModuleInfo(PC),A0
        a.w(0x2141, 0x0034, 0x207A) // MOVE.L D1,52(A0); MOVEA.L init(PC),A0
        a.displacement(to: initSong)
        a.w(0x4E90, 0x4251, 0x4E75) // JSR (A0); CLR.W (A1); RTS
        // `SetVolume` ($6D8, DTP_Volume): the sides' volumes from DeliTracker's, and each voice's kept
        // volume written again through `ChangeVolume`.
        setVolume = a.here
        let again = a.label(), changeVolume = a.label()
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x43FA)
        a.displacement(to: volumes[0]) // LEA volumes(PC),A1
        a.w(0x7003, 0x41F9, 0x00DF, 0xF000) // MOVEQ #3,D0; LEA $DFF000,A0
        a.place(again)
        a.w(0x3219) // MOVE.W (A1)+,D1
        a.branch(0x6100, to: changeVolume) // BSR.B ChangeVolume
        a.w(0x5088, 0x5088, 0x51C8) // ADDQ.L #8,A0; ADDQ.L #8,A0; DBF D0,
        a.displacement(to: again)
        a.w(0x4E75)
        // `ChangeVolume` ($712): the volume in D1 (to seven bits) kept as the voice's (A0 its registers'
        // base, $DFF000 on), nought if it is muted, turned down by its side's balance, and written.
        a.place(changeVolume)
        let write = a.label()
        a.w(0x0241, 0x007F) // ANDI.W #$7F,D1
        for (v, side) in [(0, leftVolume), (1, rightVolume), (2, rightVolume), (3, leftVolume)] {
            let next = a.label(), on = a.label()
            if v < 3 {
                a.w(0xB1FC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0v0,A0
                a.branch(0x6600, to: next) // BNE.B
            }
            a.w(0x33C1)
            a.address(of: volumes[v]) // MOVE.W D1,volume
            a.w(0x4A79)
            a.address(of: voices[v]) // TST.W voice
            a.branch(0x6600, to: on) // BNE.B
            a.w(0x7200) // MOVEQ #0,D1
            a.place(on)
            a.w(0xC2FA)
            a.displacement(to: side) // MULU side(PC),D1
            if v < 3 { a.branch(0x6000, to: write) } // BRA.B
            a.place(next)
        }
        a.place(write)
        a.w(0xEC49, 0x3141, 0x00A8, 0x4E75) // LSR.W #6,D1; MOVE.W D1,$A8(A0); RTS
        // ($78C) The volume in D1 told the scopes.
        let scopeVolume = a.scopeRoutine(scopes, base: 0, field: 4, pointer: 1, body: [0x3281]) // MOVE.W D1,(A1)
        // The patches (their table at $826), each as the player has it.
        // $852: the busy wait (whose count `initPlayer` puts in the pattern) made eight lines of the beam.
        let dmaWait = a.dmaWait(lines: 8)
        patches.add([0x303C, 0x0000, 0x51C8, 0xFFFE], patch: dmaWait) // MOVE.W #n,D0; DBF D0,*
        // $882: a voice's sample, length and period written (A6 its variables, A0 its registers' base) and
        // told the scopes.
        let samplePatch = a.placed()
        let writes: [UInt16] = [0x216E, 0x000E, 0x00A0, 0x316E, 0x000A, 0x00A4, 0x316E, 0x0004, 0x00A6]
        for word in writes { a.w(word) } // MOVE.L 14(A6),$A0(A0); MOVE.W 10(A6),$A4(A0); MOVE.W 4(A6),$A6(A0)
        a.w(0x2F09, 0x43FA) // MOVE.L A1,-(A7); LEA StructAdr(PC),A1
        a.displacement(to: scopes[0])
        for v in 0 ..< 4 {
            let next = a.label(), s = UInt16(v * 18)
            a.w(0xB1FC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0v0,A0
            a.branch(0x6600, to: next) // BNE.B
            a.w(0x236E, 0x000E, s, 0x336E, 0x000A, s + 4, 0x336E, 0x0004, s + 6) // MOVE.L 14(A6),s(A1); MOVE.W 10(A6),s+4(A1); MOVE.W 4(A6),s+6(A1)
            a.place(next)
        }
        a.w(0x225F, 0x4E75) // MOVEA.L (A7)+,A1; RTS
        patches.add(writes, patch: samplePatch)
        // $90C: a voice's volume, through `ChangeVolume`, and told the scopes.
        let volumePatch = a.placed()
        a.w(0x2F01, 0x322E, 0x0006, 0x6100) // MOVE.L D1,-(A7); MOVE.W 6(A6),D1; BSR.W ChangeVolume
        a.displacement(to: changeVolume)
        a.w(0x6100)
        a.displacement(to: scopeVolume) // BSR.W
        a.w(0x221F, 0x4E75) // MOVE.L (A7)+,D1; RTS
        patches.add([0x316E, 0x0006, 0x00A8], patch: volumePatch)
        // $926: all four voices' DMA turned off: the song's end, unless it is being started.
        let stopPatch = a.placed()
        let notEnd = a.label()
        a.w(0x33FC, 0x000F, 0x00DF, 0xF096, 0x4A79) // MOVE.W #$F,$DFF096; TST.W starting
        a.address(of: starting)
        a.branch(0x6600, to: notEnd) // BNE.B
        let songEnd = a.placed()
        a.callSongEnd(eagleBase: eagleBase)
        a.place(notEnd)
        a.w(0x4E75)
        patches.add([0x33FC, 0x000F, 0x00DF, 0xF096], patch: stopPatch)
        // $950: the module's `MOVE.W 32(A5),28(A5)`: the song's end if the command for a pattern is $E5 and
        // the word at 2(A0) is $FE.
        let trackPatch = a.placed()
        let notLast = a.label()
        a.w(0x3B6D, 0x0020, 0x001C, 0x0C79, 0x00E5) // MOVE.W 32(A5),28(A5); CMPI.W #$E5,command
        a.address(of: command)
        a.branch(0x6600, to: notLast) // BNE.B
        a.w(0x0C68, 0x00FE, 0x0002) // CMPI.W #$FE,2(A0)
        a.branch(0x6600, to: notLast) // BNE.B
        a.branch(0x6100, to: songEnd) // BSR.B
        a.place(notLast)
        a.w(0x4E75)
        patches.add([0x3B6D, 0x0020, 0x001C], patch: trackPatch)
        patches.assemble(&a)
        modulePtr = a.addressOf(module)
        initPtr = a.addressOf(initSong)
        songsPtr = a.addressOf(songs)
        playPtr = a.addressOf(play)
        commandAt = a.addressOf(command)
        initSoundAt = a.addressOf(initSound)
        tick = a.addressOf(tickRoutine)
    }

    /// `InitPlayer` ($37C): the module's routines and tables found, its code and tables moved to where
    /// it is, and patched. (Its searches run on until they find what they look for; here they stop at the
    /// module's end, and a module they would not find it in is refused.)
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let (module, size) = try Desire.listData(&host)
        let end = module &+ size
        func refuse() -> TuneError { .malformed("a module of Mike Davies' whose code is not as the player looks for") }
        func forever() -> TuneError { .malformed("a module of Mike Davies' whose tables the player would go through for ever") }
        func word(_ at: UInt32) -> UInt16 { host.machine.peek16(at) }
        func long(_ at: UInt32) -> UInt32 { host.machine.peek32(at) }
        func signed(_ value: UInt32) -> Int32 { Int32(bitPattern: value) }
        /// The first place from `from` on that holds `words`.
        func find(_ words: [UInt16], from: UInt32) throws(TuneError) -> UInt32 {
            guard from >= module, from < end, let at = WantedTeamSearch.find(host, words, from: from, most: Int(end - from)) else {
                throw refuse()
            }
            return at
        }
        /// DIVU's result: the remainder in the upper word, the quotient in the lower; unchanged if the
        /// quotient is too large.
        func divu(_ value: UInt32, _ by: UInt32) -> UInt32 { value / by > 0xFFFF ? value : (value % by) << 16 | value / by }
        func swap(_ value: UInt32) -> UInt32 { value << 16 | value >> 16 }
        // The routine to start a song, the first `MOVEM.L D0-A6,-(A7)`; and where the module was saved,
        // from the next `MOVE.W #1,$Address`.
        let initSong = try find([0x48E7, 0xFFFE], from: module)
        var a2 = try find([0x33FC, 0x0001], from: initSong) + 4
        let origin = long(a2)
        func move(_ at: UInt32) { host.machine.poke32(at, long(at) &- origin &+ module) }
        // The songs' table, from the next `LEA $Address,A0` to the `CMPA.L #$Address,A0` after it (16 bytes
        // a song); the samples' second table, between the next two; the busy wait's count, in the next
        // `MOVE.W #n,D0`.
        a2 = try find([0x41F9], from: a2) + 2
        let songsLea = a2
        let songs = (long(try find([0xB1FC], from: a2) + 2) &- long(songsLea)) >> 4
        a2 = try find([0xB1FC], from: a2) + 2
        a2 = try find([0x41F9], from: a2) + 2
        let secondLea = a2
        a2 = try find([0xB1FC], from: a2) + 2
        let secondEnd = a2
        a2 = try find([0x303C], from: a2) + 2
        host.machine.poke16(patches.patternAt[0] + 2, word(a2))
        // The routine for a tick: the next `MOVEM.L D0-A6,-(A7)` with a BSR.W 8 bytes on; and the samples'
        // first table after it, of 24 bytes a sample (or 4 bytes short of a whole number of them: then, in a
        // module with "FTD<" at 2008, the three longs from 1,892 are moved on by four, and nought put before).
        var at = module
        a2 = try find([0x48E7, 0xFFFE], from: a2)
        while word(a2 + 8) != 0x6100 { a2 = try find([0x48E7, 0xFFFE], from: a2 + 2) }
        let play = a2
        a2 = try find([0x41F9], from: a2) + 2
        let firstLea = a2
        var d2 = long(a2)
        var d3 = long(try find([0xB1FC], from: a2) + 2) &- d2
        a2 = try find([0xB1FC], from: a2) + 2
        var d4 = d3
        d3 = swap(divu(d3, 24))
        if d3 & 0xFFFF != 0 {
            d4 = swap(divu(d4 &+ 4, 24))
            guard d4 & 0xFFFF == 0 else { throw .malformed("a module of Mike Davies' whose samples' table is not of whole samples") }
            d3 = d4
            if long(module + 2008) == 0x4654_443C {
                at = module + 1904
                for _ in 0 ..< 3 {
                    at -= 4
                    host.machine.poke32(at + 4, long(at))
                }
                host.machine.poke32(at, 0)
            }
        }
        d3 = swap(d3)
        // The code's end: the address of the next `LEA $Address,A5`; the code moved from the routine to
        // start a song up to there.
        a2 = try find([0x4BF9], from: a2) + 2
        let codeLength = long(a2) &- origin
        guard codeLength < size else { throw .malformed("a module of Mike Davies' whose code would end past it") }
        guard Self.code.relocate(&host, from: initSong, to: module &+ codeLength, origin: origin, module: module) else {
            throw .malformed("a module of Mike Davies' whose code the player would search for ever")
        }
        // The first table's samples' addresses moved (the lowest kept, and the end of each that begins at
        // or past the end kept so far); the table's end kept, but for a table of fewer than two samples,
        // after which the player keeps its next values a place too soon, over the end's.
        var samples = long(firstLea)
        move(samples)
        var highest = long(samples) &+ long(samples &+ 4) &+ long(samples &+ 4)
        d2 = long(samples)
        samples &+= 24
        func sample(_ at: UInt32) {
            move(at)
            if signed(highest) <= signed(long(at)) { highest = long(at) &+ long(at &+ 4) &+ long(at &+ 4) }
            if signed(d2) >= signed(long(at)) { d2 = long(at) }
        }
        var tablesEnd: UInt32 = 0, command: UInt16 = 0
        let short = signed(d3 &- 2) < 0
        if !short {
            for _ in 0 ... (d3 &- 2) & 0xFFFF {
                sample(samples)
                samples &+= 24
            }
            tablesEnd = samples
        }
        // The second table's.
        samples = long(secondLea)
        d3 = long(secondEnd) &- samples
        if d3 != 0 { d3 = divu(d3, 24) }
        if short { tablesEnd = d3 << 16 }
        if d3 != 0 {
            for _ in 0 ... (d3 &- 1) & 0xFFFF {
                sample(samples)
                samples &+= 24
            }
        }
        if signed(samples) >= signed(tablesEnd) { tablesEnd = samples }
        // The songs' tracks' addresses moved (but those of -1, a voice with none), the highest kept.
        var track: UInt32 = 0
        at = long(songsLea)
        for _ in 0 ... ((songs << 2) &- 1) & 0xFFFF {
            if long(at) != 0xFFFF_FFFF {
                move(at)
                if signed(track) <= signed(long(at)) { track = long(at) }
            }
            at &+= 4
        }
        // The command after which a pattern's address is in a track: the word 24 bytes on from the opcode
        // of the first `CMPI.W #x,D0` in the routine for a tick.
        command = word(try find([0x0C40], from: play) + 24)
        if short { tablesEnd = tablesEnd & 0xFFFF_0000 | UInt32(command) } else { host.machine.poke16(commandAt, command) }
        /// The tracks' patterns' addresses moved, from `from` up to `to`: each the long six bytes after a
        /// word of the command (and the highest kept in `track`, if `highest`).
        func patterns(from: UInt32, to: UInt32, highest: Bool) throws(TuneError) {
            guard from < to, Int(to) <= host.memorySize else { throw forever() }
            var a1 = from
            repeat {
                if word(a1) == command {
                    a1 += 6
                    move(a1)
                    if highest, signed(track) <= signed(long(a1)) { track = long(a1) }
                }
                a1 += 2
                guard a1 <= to else { throw forever() }
            } while a1 != to
        }
        /// The place after the first track's end ($94, $FE, $FF, $1FE or $1FF) from `from` on.
        func trackEnd(_ from: UInt32) throws(TuneError) -> UInt32 {
            var a = from
            while true {
                guard a >= module, a < end else { throw refuse() }
                let w = word(a)
                a += 2
                if w == 0x94 || w == 0xFE || w == 0xFF || w == 0x1FE || w == 0x1FF { return a }
            }
        }
        let tooShort: TuneError = .malformed("a module of Mike Davies' that is shorter than its tables say")
        var last: UInt32
        if signed(track) < signed(highest) {
            // The tracks before the samples: their patterns from the samples' tables' end to the first sample.
            guard signed(end) >= signed(highest) else { throw tooShort }
            try patterns(from: tablesEnd, to: d2, highest: false)
            last = highest
        } else {
            // The tracks after the samples: their patterns from the samples' end to the last track's end,
            // and to the end of the track after the last pattern, if that is further.
            guard signed(end) >= signed(track) else { throw tooShort }
            last = try trackEnd(track)
            try patterns(from: highest, to: last, highest: true)
            if signed(last) <= signed(track) { last = try trackEnd(track) }
        }
        // A module of 30,638 bytes (as the player works out its size; Mercs' is), put right.
        if last &- module == 0x77AE {
            host.machine.poke32(module + 29464, 0x00FE_00FE)
            at = module + 2160
            for _ in 0 ..< 3 {
                at -= 4
                host.machine.poke32(at + 4, long(at))
            }
            host.machine.poke32(at, 0x1E8)
        }
        host.machine.poke32(modulePtr, module)
        host.machine.poke32(initPtr, initSong)
        host.machine.poke32(songsPtr, songsLea)
        host.machine.poke32(playPtr, play)
        // `ModuleChange` ($1C2): the patches made in the code, from the module's start.
        patches.apply(&host, from: module, length: codeLength)
        return WantedTeamSongs(first: 1, count: Int(songs & 0xFFFF))
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
