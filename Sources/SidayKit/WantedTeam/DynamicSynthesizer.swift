// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Chris Hülsbeck's Dynamic Synthesizer ("Dynamic Synthesizer v1.34
// player module V1.1 (24 Apr 2001)", UADE's players/DynamicSynthesizer), whose source is not given: what it
// does is read from its code, and the addresses given are of its hunk in UADE's file.

/// Chris Hülsbeck's Dynamic Synthesizer (of 1987 and 1988, as the player's credit has it; Hollywood Poker
/// Pro's music): each module is his 68000 code that plays it, with its music, assembled for a place in
/// memory of its own, and beginning with five BRA.Ws: for a tick, to stop, a third, to start a song (with
/// its number, from nought, in D0), and to be given its samples (at A0), which are kept in a file of their
/// own beside it. The player names that file as the module's with its `DNS.` made `SMP.` (`ExtLoad`,
/// $426); siday asks too for a module `name.dns`'s `name.smp`, as UnExoticA keeps them.
///
/// As the player plays it: the module's code moved to where it is put, by the player's relocation of
/// every address in its code that one of sixty instructions holds (from its start to where the second
/// BRA.W's routine says it ends), and of a table of addresses after it; its songs counted in its table of
/// them; fifty ticks a second, or a hundred for a module whose code is not as the player first looks for
/// (`InitSound`, $872); the module's writes of its voices' samples, lengths, periods and volumes told to
/// EaglePlayer's scopes, its periods made $71 at least, its volumes taken through the player's (for the
/// balance, which is none; one of them written as the voice's value, where the module writes $32); and a
/// song's end said when the module puts its place in its music back to the start of its loop.
typealias DynamicSynthesizerPlayer = WantedTeamPlayer<DynamicSynthesizer>

struct DynamicSynthesizer: WantedTeamRecipe {
    static let format = "Dynamic Synthesizer"

    /// `Check2` ($3F4): the first five longs BRA.Ws forward (an even distance), and the fifth's routine
    /// `MOVE.L A0,abs.l; RTS`.
    static func isOne(_ data: [UInt8]) -> Bool {
        func word(_ at: Int) -> UInt16 { UInt16(WantedTeamHeader.long(data, at) >> 16) }
        for at in stride(from: 0, to: 20, by: 4) {
            guard word(at) == 0x6000, word(at + 2) & 0x8001 == 0 else { return false }
        }
        let at = 18 + Int(word(18))
        return word(at) == 0x23C8 && word(at + 6) == 0x4E75
    }

    /// The name the player asks for the samples by, for a module named `name`: `DNS.x` made `SMP.x` (as the
    /// player does), or `x.dns` made `x.smp` (siday's); nil for any other.
    static func samplesName(_ name: String) -> String? {
        let bytes = Array(name.utf8)
        func lower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 0x20 : b }
        if bytes.count > 4, bytes[0 ..< 4].map(lower) == Array("dns.".utf8) {
            return "SMP." + String(decoding: bytes[4...], as: UTF8.self)
        }
        if bytes.count > 4, bytes[(bytes.count - 4)...].map(lower) == Array(".dns".utf8) {
            return String(decoding: bytes[..<(bytes.count - 4)], as: UTF8.self) + ".smp"
        }
        return nil
    }

    let title = ""
    let author = "Chris Hülsbeck"

    private var modulePtr: UInt32 = 0, hundredAt: UInt32 = 0, setVolume: UInt32 = 0
    private var initSoundAt: UInt32 = 0, tick: UInt32 = 0
    /// Where the player's code is given the module's addresses that `InitPlayer` finds (its longs of
    /// "WTWT"): the four voices' volumes it writes at once, in `Code5`'s pattern and patch, and its place
    /// in its music, in `Code6`'s.
    private var volumesAt: [UInt32] = [], placeAt: [UInt32] = []
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        func bsr(_ routine: Int) {
            a.w(0x6100)
            a.displacement(to: routine) // BSR.W
        }
        // The variables ($196 to $213): the module, whether it plays a hundred ticks a second (a byte in a
        // word), the length of its code, its samples' table and their count, a routine of its, its
        // samples, whether it has been patched, the globals, its place in its music, the sides' volumes,
        // the voices' muting, the scopes.
        let module = a.variable(long: 0), hundred = a.variable(word: 0)
        _ = a.variable(long: 0) // the code's length
        _ = a.variable(long: 0) // the samples' table
        _ = a.variable(long: 0) // their count
        _ = a.variable(long: 0) // the routine before the start of a song
        _ = a.variable(long: 0) // the samples
        _ = a.variable(word: 0) // patched
        let eagleBase = a.eagleBase()
        _ = a.variable(word: 0) // the first place in its music
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voices = (0 ..< 4).map { _ in a.variable(word: 0xFFFF) }
        let scopes = a.scopes()
        // `Interrupt` ($27A, DTP_Interrupt): the module's routine for a tick, its first BRA.W.
        let interrupt = a.tickRoutine(play: module, scopes: scopes, voices: 4)
        // `SongEnd` ($2B2).
        let songEnd = a.songEndRoutine(eagleBase: eagleBase)
        // `InitSound` ($872, DTP_InitSound): the scopes cleared, a hundred ticks a second for a module that
        // runs at that speed, and the song started with its number in D0 (the fourth BRA.W). (What it then
        // works out for EaglePlayer's information alone is left out.)
        initSoundAt = a.here
        let fifty = a.label()
        a.clearScopes(scopes)
        a.w(0x7000, 0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x4A79) // MOVEQ #0,D0; MOVE.W dtg_SndNum(A5),D0; TST.W Hundred
        a.address(of: hundred)
        a.branch(0x6700, to: fifty) // BEQ.S
        a.w(0x3B7C, 0x1BB6, UInt16(DeliTrackerHost.dtgTimer)) // MOVE.W #$1BB6,dtg_Timer(A5)
        a.place(fifty)
        a.w(0x207A)
        a.displacement(to: module) // MOVEA.L ModulePtr(PC),A0
        a.w(0x4EA8, 0x000C, 0x4E75) // JSR 12(A0); RTS
        // `SetVolume` ($8C4, DTP_Volume): the sides' volumes from DeliTracker's.
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        // `ChangeVolume` ($8E8): the volume in D1 (seven bits) turned down by its side's balance and nought
        // for a muted voice, and written to the voice whose registers A0 points at; the voice known by A4,
        // or (from $90A, $91A, $92A, $93A) given.
        let changeVolume = a.placed()
        let to = (0 ..< 4).map { _ in a.label() }, from = (0 ..< 4).map { _ in a.label() }
        let ex = a.label(), exit = a.label()
        a.w(0x2F02, 0x0241, 0x007F, 0x240C) // MOVE.L D2,-(A7); ANDI.W #$7F,D1; MOVE.L A4,D2
        for v in 0 ..< 3 {
            a.w(0x0C42, 0xF0A0 + UInt16(v * 16)) // CMPI.W #$F0x0,D2
            a.branch(0x6700, to: to[v]) // BEQ.S
        }
        a.w(0x0C42, 0xF0D0) // CMPI.W #$F0D0,D2
        a.branch(0x6600, to: exit) // BNE.S
        a.branch(0x6000, to: to[3]) // BRA.S
        for (v, side) in [(3, leftVolume), (0, leftVolume), (1, rightVolume), (2, rightVolume)] {
            a.place(from[v])
            a.w(0x2F02, 0x0241, 0x007F) // MOVE.L D2,-(A7); ANDI.W #$7F,D1
            a.place(to[v])
            a.w(0xC2FA)
            a.displacement(to: side) // MULU.W side(PC),D1
            a.w(0xC27A)
            a.displacement(to: voices[v]) // AND.W VoiceN(PC),D1
            if v != 2 { a.branch(0x6000, to: ex) } // BRA.S
        }
        a.place(ex)
        a.w(0xEC49, 0x3141, 0x0008) // LSR.W #6,D1; MOVE.W D1,8(A0)
        a.place(exit)
        a.w(0x241F, 0x4E75) // MOVE.L (A7)+,D2; RTS
        // The scopes told of the voice at A0 ($952, $982, $9B8): its volume; its sample and length (the
        // length at 6(A1)); its period, made $71 at least (as it is then written).
        let setVol = a.scopeRoutine(scopes, base: 0, field: 4, pointer: 1, body: [0x3281]) // MOVE.W D1,(A1)
        let setAdr = a.scopeRoutine(scopes, base: 0, field: 0, pointer: 2, body: [0x2481, 0x3569, 0x0006, 0x0004]) // MOVE.L D1,(A2); MOVE.W 6(A1),4(A2)
        let setPer = a.scopeRoutine(scopes, base: 0, field: 3, pointer: 1,
                                    body: [0x0C41, 0x0071, 0x6404, 0x323C, 0x0071, 0x3281]) // CMPI.W #$71,D1; BCC.S; MOVE.W #$71,D1; MOVE.W D1,(A1)

        // The patches (their table at $A5E). A period ($A8C).
        let period = a.placed()
        a.w(0xD272, 0x7000) // ADD.W 0(A2,D7.W),D1
        bsr(setPer)
        a.w(0x3141, 0x0006, 0x4E75) // MOVE.W D1,6(A0); RTS
        patches.add([0xD272, 0x7000, 0x3141, 0x0006], patch: period)
        // A sample and its length ($AA4).
        let sample = a.placed()
        a.w(0x2081, 0x3169, 0x0006, 0x0004) // MOVE.L D1,(A0); MOVE.W 6(A1),4(A0)
        bsr(setAdr)
        a.w(0x4E75)
        patches.add([0x2141, 0x0000, 0x3169, 0x0006, 0x0004], patch: sample)
        // A volume, kept and written through `ChangeVolume` ($ABA); in place of the module's $32 too.
        let volume = a.placed()
        a.w(0x3581, 0x7000) // MOVE.W D1,0(A2,D7.W)
        bsr(changeVolume)
        bsr(setVol)
        a.w(0x4E75)
        patches.add([0x3581, 0x7000, 0x3141, 0x0008], patch: volume)
        patches.add([0x3581, 0x7000, 0x317C, 0x0032, 0x0008], patch: volume)
        // The four voices' volumes, each through `ChangeVolume` ($AFA).
        let volumes = a.placed()
        var volumesIn: [Int] = []
        a.w(0x48E7, 0x4080, 0x41F9, 0x00DF, 0xF0A0) // MOVEM.L D1/A0,-(A7); LEA $DFF0A0,A0
        for (n, v) in [0, 1, 2, 3].enumerated() {
            if n > 0 { a.w(0x5088, 0x5088) } // ADDQ.L #8,A0; ADDQ.L #8,A0
            a.w(0x3239)
            volumesIn.append(a.variable(long: 0x5754_5754)) // MOVE.W volume,D1
            bsr(from[v])
            bsr(setVol)
        }
        a.w(0x4CDF, 0x0102, 0x4E75) // MOVEM.L (A7)+,D1/A0; RTS
        var pattern: [UInt16] = []
        for v in 0 ..< 4 { pattern += [0x33F9, 0x5754, 0x5754, 0x00DF, 0xF0A8 + UInt16(v * 16)] }
        patches.add(pattern, patch: volumes)
        // The module's place in its music put back to its loop's start, the song's end ($B58).
        let loop = a.placed()
        a.w(0x33F9)
        let placeFrom = a.variable(long: 0x5754_5754), placeTo = a.variable(long: 0x5754_5754) // MOVE.W place+2,place
        bsr(songEnd)
        a.w(0x4E75)
        patches.add([0x33F9, 0x5754, 0x5754, 0x5754, 0x5754], patch: loop)
        patches.assemble(&a)

        tick = a.addressOf(interrupt)
        modulePtr = a.addressOf(module)
        hundredAt = a.addressOf(hundred)
        volumesAt = volumesIn.map { a.addressOf($0) } + (0 ..< 4).map { patches.patternAt[4] + 2 + UInt32($0 * 10) }
        placeAt = [a.addressOf(placeFrom), a.addressOf(placeTo), patches.patternAt[5] + 2, patches.patternAt[5] + 6]
    }

    /// The instructions whose absolute addresses the player moves (`InitPlayer`, $52E-$6BE), and how many
    /// bytes after the instruction's first the address is; nought for the moves from one to another; nil
    /// for any other.
    private static func relocated(_ op: UInt16) -> Int? {
        switch op {
        case 0x0139, 0x0682, 0x0B39, 0x13C0, 0x13C2, 0x13C5, 0x13C7, 0x1C39, 0x2039, 0x2079, 0x23C0, 0x23C8, 0x2E39,
             0x3039, 0x3239, 0x33C0, 0x33C1, 0x33C2, 0x33D0, 0x3439, 0x3E39, 0x41F9, 0x4279, 0x42B9, 0x43F9, 0x45F9,
             0x47F9, 0x49F9, 0x4BF9, 0x5279, 0x5379, 0x5479, 0x5879, 0xB079, 0xD179, 0xD279, 0xD2B9: 2
        case 0x0079, 0x0279, 0x0479, 0x0679, 0x0C79, 0x13FC, 0x33E8, 0x33F0, 0x33FC: 4
        case 0x02B9: 6
        case 0x13F9, 0x23F9, 0x33F9: 0
        default: nil
        }
    }

    /// `ExtLoad` ($426) and `InitPlayer` ($4A4).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let g = DeliTrackerHost.globals
        // `ExtLoad`: the samples, from beside the module.
        let file = host.string(at: host.machine.peek32(g + DeliTrackerHost.dtgFileArrayPtr), most: 128)
        guard let samples = Self.samplesName(file) else {
            throw .missingCompanion("the Dynamic Synthesizer's samples are named after its module, which must be DNS.name or name.dns")
        }
        let path = host.machine.peek32(g + DeliTrackerHost.dtgPathArrayPtr)
        host.machine.poke8(path, 0)
        _ = try host.call(host.machine.peek32(g + DeliTrackerHost.dtgCopyDir))
        var name = path
        while host.machine.peek8(name) != 0, name < path + 255 { name += 1 }
        for (i, byte) in (Array(samples.utf8.prefix(120)) + [0]).enumerated() { host.machine.poke8(name + UInt32(i), byte) }
        guard try host.call(host.machine.peek32(g + DeliTrackerHost.dtgLoadFile)) == 0 else {
            throw .missingCompanion("the Dynamic Synthesizer's music needs its samples, \(samples), beside it")
        }

        let (module, size) = try Desire.listData(&host)
        let end = module &+ size
        func refuse() -> TuneError { .malformed("a module of the Dynamic Synthesizer's that is not as the player looks for") }
        func inside(_ at: UInt32, _ bytes: UInt32) -> Bool { at >= module && at &+ bytes <= end && at &+ bytes >= at }
        func word(_ at: UInt32) -> UInt16 { inside(at, 2) ? host.machine.peek16(at) : 0 }
        func long(_ at: UInt32) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }
        func find(_ value: UInt32, from: UInt32) throws(TuneError) -> UInt32 {
            guard from >= module, let at = WantedTeamSearch.find(host, long: value, from: from, most: Int(end) - Int(from)),
                  inside(at, 4) else { throw refuse() }
            return at
        }
        guard Self.isOne((0 ..< min(Int(size), 0x400)).map { host.machine.peek8(module + UInt32($0)) }) else { throw refuse() }
        host.machine.poke32(modulePtr, module)
        // The place the module's code was made for: where a `LEA abs.l,A1` (after a `$007E`) points, less
        // the place of the `$06AE064E` that follows it in the module.
        let lea = try find(0x007E_43F9, from: module) + 4
        let origin = long(lea) &- (try find(0x06AE_064E, from: lea) - module)
        func move(_ at: UInt32) {
            if inside(at, 4) { host.machine.poke32(at, long(at) &- origin &+ module) }
        }
        // The second BRA.W's routine begins `MOVE.L abs.l` of the address of a table of addresses after an
        // RTS (whose first is its end): the table moved too, and fifty ticks a second; or a hundred.
        var at = module &+ 6 &+ UInt32(word(module + 6)) &+ 2
        let rts = long(at) &- origin &+ module &- 6
        if word(rts) == 0x4E75 {
            move(rts + 2)
            var entry = long(rts + 2)
            move(entry)
            let last = long(entry)
            entry &+= 4
            guard inside(entry, 4), last > entry, last <= end, (last - entry) % 4 == 0 else { throw refuse() }
            repeat {
                move(entry)
                entry += 4
            } while entry != last
        } else {
            host.machine.poke8(hundredAt, 0xFF)
        }
        // The code, to where `MOVE.L abs.l` of the routine six bytes on says it ends: each instruction of
        // the player's sixty's address moved (but the custom chips'), and the module's own addresses that
        // the player's patches use found as they are.
        at += 6
        let codeLength = long(at) &- origin
        let codeEnd = module &+ codeLength
        guard codeEnd > module, codeEnd <= end else { throw refuse() }
        var a4 = module
        while a4 < codeEnd {
            guard let skip = Self.relocated(word(a4)) else {
                a4 += 2
                continue
            }
            if skip > 0 {
                a4 += UInt32(skip)
                if word(a4) != 0x00DF {
                    move(a4)
                    a4 += 4
                }
                continue
            }
            // A move from an address to another.
            a4 += 2
            if word(a4) != 0x00DF { move(a4) }
            a4 += 4
            if word(a4) == 0x00DF {
                // To a voice's volume: the address it is from.
                a4 += 2
                let register = word(a4)
                if register & 0xFF0F == 0xF008, (0xA ... 0xD).contains(register >> 4 & 0xF) {
                    let v = Int(register >> 4 & 0xF) - 0xA
                    let volume = long(a4 &- 6)
                    host.machine.poke32(volumesAt[v], volume)
                    host.machine.poke32(volumesAt[4 + v], volume)
                    a4 += 2
                }
                continue
            }
            move(a4)
            a4 += 4
            // And one followed by an RTS: the module's place in its music.
            if word(a4) == 0x4E75 {
                let place = long(a4 &- 4)
                for (i, address) in placeAt.enumerated() { host.machine.poke32(address, i % 2 == 0 ? place &+ 2 : place) }
            }
        }
        // The songs: in the table a `LEA abs.l,A0` after an `ASL.L #1,D0` (or `ASL.W`) points at, counted
        // from its second word until one is the same as the next, thirty-two at most.
        let asl = WantedTeamSearch.find(host, long: 0xE380_41F9, from: module, most: Int(size))
        let aslW = WantedTeamSearch.find(host, long: 0xE340_41F9, from: module, most: Int(size))
        guard let first = [asl, aslW].compactMap({ $0 }).min() else { throw refuse() }
        var song = long(first + 4) &+ 2
        var songs = 1
        while songs < 0x20, word(song) != word(song &+ 2) {
            song &+= 2
            songs += 1
        }
        // (And the samples' table, which the player looks for next, for its information.)
        _ = try find(0xFFFE_41F9, from: first + 4)
        // The module given its samples (its fifth BRA.W, with them at A0).
        _ = try host.call(host.machine.peek32(g + DeliTrackerHost.dtgGetListData), with: [(0, 1)])
        let smp = host.machine.cpu.registers[8], smpSize = host.machine.cpu.registers[0]
        _ = try host.call(module + 16, with: [(0, smpSize), (8, smp), (9, module)])
        // `ModuleChange` ($214): the patches made in the module's code.
        patches.apply(&host, from: module, length: codeLength)
        return WantedTeamSongs(first: 0, count: songs)
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
