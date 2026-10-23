// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the recipes for Jesper Olsen's music and Chris Hülsbeck's Dynamic Synthesizer, on tiny
// modules (and a game's replayer, and samples) assembled here by hand: each laid out as its player looks
// for it, its code changed as the player changes it, and its songs ending as the player (or siday) has them
// end. The thorough check is made outside the package: what every one of UnExoticA's modules writes to
// Paula, tick by tick and song by song, against what it writes in UADE.

private struct Silent: TFMXOutput {
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
}

/// The values the first `ticks` ticks' writes put in a register, and the endings by then.
private func played<R: WantedTeamRecipe>(_ p: inout WantedTeamPlayer<R>, ticks: Int, _ register: UInt16) -> (values: [UInt16], endings: Int) {
    var out = Silent()
    var values = p.startWrites.filter { $0.register == register }.map(\.value)
    for _ in 0 ..< ticks {
        _ = p.run(&out)
        values += p.writes.filter { $0.register == register }.map(\.value)
    }
    return (values, p.endings)
}

/// Code assembled at `at`, padded with noughts to `size` bytes.
private func bytes(_ a: AmigaAssembly, size: Int) -> [UInt8] {
    var bytes = a.assembled()
    if bytes.count < size { bytes += [UInt8](repeating: 0, count: size - bytes.count) }
    return bytes
}

/// A module of Jesper Olsen's first kind: four BRA.Ws; a start of a song that is a `MULU #8,D0` and a LEA
/// of its songs' table (two songs, the first of voice 0 alone, the second of all four); and a tick that
/// writes voice 0's period (300) and volume ($800 >> 5) as his code does (which the player patches), and
/// voice 1's volume too if `hearSecond`, and on its third takes voice 0's list back to its start (which
/// the player's patch takes for the voice's end).
private func joCodeModule(hearSecond: Bool = false) -> [UInt8] {
    var a = AmigaAssembly(at: JesperOlsen.moduleAt)
    let stop = a.label(), start = a.label(), play = a.label(), songs = a.label(), vars = a.label(), back = a.label()
    let done = a.label()
    for routine in [stop, start, play, stop] {
        a.w(0x6000)
        a.displacement(to: routine) // BRA.W
    }
    a.place(stop)
    a.w(0x4E75)
    a.place(start)
    let mulu = a.here + 2
    a.w(0xC0FC, 0x0008, 0x41FA) // MULU #8,D0; LEA songs(PC),A0
    a.displacement(to: songs)
    a.w(0x4E75)
    a.place(play)
    a.w(0x43FA)
    a.displacement(to: vars) // LEA vars(PC),A1
    a.w(0x45F9, 0x00DF, 0xF0A0) // LEA $DFF0A0,A2
    a.w(0x363C, 0x012C, 0x9669, 0x000E, 0x3543, 0x0006) // MOVE.W #300,D3; SUB.W 14(A1),D3; MOVE.W D3,6(A2)
    a.w(0x343C, 0x0800, 0xEA4A, 0x1542, 0x0008) // MOVE.W #$800,D2; LSR.W #5,D2; MOVE.B D2,8(A2)
    if hearSecond {
        a.w(0x45F9, 0x00DF, 0xF0B0, 0x343C, 0x0800, 0xEA4A, 0x1542, 0x0008) // LEA $DFF0B0,A2; the same
        a.w(0x45F9, 0x00DF, 0xF0A0) // LEA $DFF0A0,A2
    }
    a.w(0x5251, 0x0C51, 0x0003) // ADDQ.W #1,(A1); CMPI.W #3,(A1)
    a.branch(0x6600, to: done) // BNE.S
    a.w(0x4251, 0x49FA) // CLR.W (A1); LEA back(PC),A4
    a.displacement(to: back)
    a.w(0x0C54, 0x7FFE, 0x336C, 0x0002, 0x0006) // CMPI.W #$7FFE,(A4); MOVE.W 2(A4),6(A1)
    a.place(done)
    a.w(0x4E75)
    a.place(vars)
    for _ in 0 ..< 16 { a.w(0) }
    a.place(back)
    a.w(0, 1)
    a.place(songs)
    a.w(UInt16(a.here + 16 - JesperOlsen.moduleAt), 0, 0, 0, 1, 1, 1, 1)
    while a.here < mulu + 900 { a.w(0) }
    a.long(0x6AE0_64E0)
    return bytes(a, size: 2400)
}

@Test func jesperOlsensCodeModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = joCodeModule()
    #expect(JesperOlsen.kind(file) == .code(mulu: 8))
    #expect(!DynamicSynthesizer.isOne(file) && !SeanConnolly.isOne(file) && !FredMonitor.isOne(file))
    #expect(JesperOlsen.kind(Array(file.prefix(600))) == nil)
    var p = try JesperOlsenPlayer(file)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Jesper Olsen" && p.tuneInfo.author == "Jesper Olsen")
    // The period, and the volume through the player's patch; and voice 0, the song's only voice, gone
    // round: the song's end.
    var (values, endings) = played(&p, ticks: 4, 0xA6)
    #expect(values.contains(300))
    #expect(endings == 1)
    #expect(p.lengthClocks != nil)
    (values, _) = played(&p, ticks: 2, 0xA8)
    #expect(values.contains(0x40))
    // The second song's voices 1 to 3 are never heard: only voice 0 is waited for (siday's).
    var q = try JesperOlsenPlayer(file, song: 1)
    try q.select(song: q.song)  // (Played through first, as its renderer has it played.)
    #expect(q.lengthClocks != nil)
    #expect(played(&q, ticks: 4, 0xA6).endings == 1)
    // Heard, voice 1 is waited for, and never goes round.
    var r = try JesperOlsenPlayer(joCodeModule(hearSecond: true), song: 1)
    try r.select(song: r.song)  // (Played through first, as its renderer has it played.)
    #expect(r.lengthClocks == nil)
    var s = try JesperOlsenPlayer(joCodeModule(hearSecond: true), song: 0)
    try s.select(song: s.song)  // (Played through first, as its renderer has it played.)
    #expect(s.lengthClocks != nil)
}

/// A module of Jesper Olsen's third kind: its table of three songs' places (each after a `$7FFF`, its
/// first the table's size), and of its samples' headers, one, whose sample is in the module.
private func joDataModule() -> [UInt8] {
    var m = [UInt8](repeating: 0, count: 0x100)
    func word(_ at: Int, _ value: UInt16) {
        m[at] = UInt8(value >> 8)
        m[at + 1] = UInt8(value & 0xFF)
    }
    for (at, value) in [(0, 6), (2, 0x30), (4, 0x40), (6, 0x20), (8, 0x50), (0x1A, 1), (0x1E, 0x7FFF), (0x2E, 0x7FFF),
                        (0x3E, 0x7FFF), (0x50, 0x52), (0x52 + 16, 0x80)] { word(at, UInt16(value)) }
    return m
}

/// A game's replayer of Jesper Olsen's third kind, as `WantedTeam.bin` has it: `$1000` keeps its music's
/// address, `$4000` starts a song (song nought being none) on voice 0, setting its DMA as his code does
/// (which the player patches to mark the voice as playing); nought plays a tick, which writes the voice's
/// period ($200 less the song's number) and volume ($30) as his code does (patched), and on its third takes
/// the voice's list back (patched, the voice's end); its last long `$3C3D3E3F`.
private func joReplayer() -> [UInt8] {
    var r = AmigaAssembly(at: 0)
    let play = r.label(), noData = r.label(), out = r.label(), data = r.label(), vars = r.label(), vols = r.label()
    let done = r.label()
    r.w(0x4A80, 0x6700) // TST.L D0; BEQ.W play
    r.displacement(to: play)
    r.w(0x0800, 0x000C) // BTST #12,D0
    r.branch(0x6700, to: noData) // BEQ.S
    r.w(0x4DFA)
    r.displacement(to: data) // LEA data(PC),A6
    r.w(0x2C88) // MOVE.L A0,(A6)
    r.place(noData)
    r.w(0x0800, 0x000E) // BTST #14,D0
    r.branch(0x6700, to: out) // BEQ.S
    r.w(0x0240, 0x00FF) // ANDI.W #$FF,D0
    r.branch(0x6700, to: out) // BEQ.S
    r.w(0x43FA)
    r.displacement(to: vars) // LEA vars(PC),A1
    r.w(0x3340, 0x0020, 0x337C, 0x0001, 0x0034) // MOVE.W D0,$20(A1); MOVE.W #1,$34(A1)
    r.w(0x7000, 0x7201, 0xE169, 0x3341, 0x003A) // MOVEQ #0,D0; MOVEQ #1,D1; LSL.W D0,D1; MOVE.W D1,$3A(A1)
    r.place(out)
    r.w(0x4E75)
    r.place(play)
    r.w(0x43FA)
    r.displacement(to: vars) // LEA vars(PC),A1
    r.w(0x4A69, 0x0034) // TST.W $34(A1)
    r.branch(0x6700, to: done) // BEQ.S
    r.w(0x45F9, 0x00DF, 0xF0A0, 0x383C, 0x0200) // LEA $DFF0A0,A2; MOVE.W #$200,D4
    r.w(0x9869, 0x0020, 0x3544, 0x0006, 0x49FA) // SUB.W $20(A1),D4; MOVE.W D4,6(A2); LEA vols(PC),A4
    r.displacement(to: vols)
    r.w(0x7600, 0x1574, 0x3000, 0x0008) // MOVEQ #0,D3; MOVE.B 0(A4,D3.W),8(A2)
    r.w(0x5269, 0x0022, 0x0C69, 0x0003, 0x0022) // ADDQ.W #1,$22(A1); CMPI.W #3,$22(A1)
    r.branch(0x6600, to: done) // BNE.S
    r.w(0x4269, 0x0022, 0x336C, 0x0002, 0x0034) // CLR.W $22(A1); MOVE.W 2(A4),$34(A1)
    r.place(done)
    r.w(0x4E75)
    r.place(vols)
    r.w(0x3000, 0x0001)
    r.place(data)
    r.long(0)
    r.place(vars)
    for _ in 0 ..< 32 { r.w(0) }
    r.long(0x3C3D_3E3F)
    return r.assembled()
}

@Test func jesperOlsensMusicIsPlayedByItsGamesReplayer() throws {
    let file = joDataModule(), replayer = [(name: JesperOlsen.replayerName, bytes: joReplayer())]
    #expect(JesperOlsen.kind(file) == .data)
    #expect(!DynamicSynthesizer.isOne(file))
    var p = try JesperOlsenPlayer(file, song: 1, files: replayer)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2)
    var (values, endings) = played(&p, ticks: 4, 0xA6)
    #expect(values.contains(0x200 - 2))
    #expect(endings == 1)
    #expect(p.lengthClocks != nil)
    (values, _) = played(&p, ticks: 2, 0xA8)
    #expect(values.contains(0x30))
    // Without its replayer, or with one that is not as the player knows it, or with its sample past its
    // end, the module is refused.
    #expect(throws: TuneError.self) { _ = try JesperOlsenPlayer(file) }
    #expect(throws: TuneError.self) { _ = try JesperOlsenPlayer(file, files: [(JesperOlsen.replayerName, Array(joReplayer().dropLast(4)))]) }
    var short = file
    short[0x52 + 15] = 1
    #expect(throws: TuneError.self) { _ = try JesperOlsenPlayer(short, files: replayer) }
}

/// A module of the Dynamic Synthesizer's, assembled for $30000: its five BRA.Ws; the second's routine
/// beginning with the addresses of a table of addresses (after an RTS, unless `hundred`) and of its code's
/// end; the places the player finds its songs (two), samples and origin by; a fifth routine that keeps its
/// samples' address; a start of a song that keeps its number times 32; and a tick that writes voice 0's
/// period ($60 and that) and volume ($30) as his code does (which the player patches), and on its third
/// puts its place in its music back (which the player's patch takes for the song's end).
private func dnsModule(hundred: Bool = false) -> [UInt8] { dnsModuleAndTable(hundred: hundred).bytes }

/// `dnsModule`, and the offsets in it of its table of addresses' second entry and of what it points at.
private func dnsModuleAndTable(hundred: Bool = false) -> (bytes: [UInt8], entry: Int, target: Int) {
    var a = AmigaAssembly(at: 0x30000)
    let play = a.label(), stop = a.label(), third = a.label(), start = a.label(), samples = a.label()
    let codeEnd = a.label(), afterRTS = a.label(), table = a.label(), tableEnd = a.label(), count = a.label()
    let place = a.label(), vars = a.label(), songs = a.label(), samplesAt = a.label(), marker = a.label()
    let done = a.label(), back = a.label()
    for routine in [play, stop, third, start, samples] {
        a.w(0x6000)
        a.displacement(to: routine) // BRA.W
    }
    a.place(stop)
    a.w(0x4279)
    a.address(of: afterRTS) // CLR.W afterRTS
    a.w(0x4279)
    a.address(of: codeEnd) // CLR.W codeEnd
    a.place(third)
    a.w(0x4E75)
    a.place(start)
    a.w(0xEB48, 0x33C0) // LSL.W #5,D0; MOVE.W D0,vars
    a.address(of: vars)
    a.w(0x4279)
    a.address(of: count) // CLR.W count
    a.w(0x4E75, 0x007E, 0x43F9) // RTS; (what the player looks for:) LEA marker,A1
    a.address(of: marker)
    a.w(0xE380, 0x41F9) // ASL.L #1,D0; LEA songs,A0
    a.address(of: songs)
    a.w(0xFFFE, 0x41F9) // LEA samplesAt,A0
    a.address(of: samplesAt)
    a.place(samples)
    a.w(0x23C8)
    a.address(of: samplesAt) // MOVE.L A0,samplesAt
    a.w(0x4E75)
    a.place(play)
    a.w(0x41F9, 0x00DF, 0xF0A0, 0x2848, 0x45F9) // LEA $DFF0A0,A0; MOVEA.L A0,A4; LEA vars,A2
    a.address(of: vars)
    a.w(0x7E00, 0x323C, 0x0060, 0xD272, 0x7000, 0x3141, 0x0006) // MOVEQ #0,D7; MOVE.W #$60,D1; ADD.W 0(A2,D7.W),D1; MOVE.W D1,6(A0)
    a.w(0x7E02, 0x323C, 0x0030, 0x3581, 0x7000, 0x3141, 0x0008) // MOVEQ #2,D7; MOVE.W #$30,D1; MOVE.W D1,0(A2,D7.W); MOVE.W D1,8(A0)
    a.w(0x5279)
    a.address(of: count) // ADDQ.W #1,count
    a.w(0x0C79, 0x0003)
    a.address(of: count) // CMPI.W #3,count
    a.branch(0x6600, to: done) // BNE.S
    a.w(0x4279)
    a.address(of: count) // CLR.W count
    a.branch(0x6100, to: back) // BSR.S
    a.place(done)
    a.w(0x4E75)
    a.place(back)
    a.w(0x33F9)
    a.address(of: vars) // MOVE.W place+2,place (vars follow place)
    a.address(of: place)
    a.w(0x4E75)
    a.place(codeEnd)
    a.w(0, hundred ? 0x4E71 : 0x4E75)
    a.address(of: table)
    a.place(afterRTS)
    a.w(0)
    a.place(table)
    a.address(of: tableEnd)
    a.address(of: count)
    a.place(tableEnd)
    a.place(count)
    a.w(0)
    a.place(place)
    a.w(0)
    a.place(vars)
    a.w(0, 0)
    a.place(songs)
    a.w(0, 1, 2, 2)
    a.place(samplesAt)
    a.long(0)
    a.place(marker)
    a.long(0x06AE_064E)
    return (bytes(a, size: 600), Int(a.addressOf(table)) - 0x30000 + 4, Int(a.addressOf(count)) - 0x30000)
}

@Test func dynamicSynthesizerModulesAreMovedAndPlayedAsWantedTeamsPlayerPlaysThem() throws {
    let (file, entry, target) = dnsModuleAndTable(), samples = [UInt8](repeating: 0, count: 64)
    #expect(DynamicSynthesizer.isOne(file))
    #expect(JesperOlsen.kind(file) == nil && !SeanConnolly.isOne(file))
    #expect(DynamicSynthesizer.samplesName("DNS.title") == "SMP.title")
    #expect(DynamicSynthesizer.samplesName("ingame.dns") == "ingame.smp")
    #expect(DynamicSynthesizer.samplesName("ingame") == nil)
    var p = try DynamicSynthesizerPlayer(file, name: "DNS.test", files: [("SMP.test", samples)])
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Dynamic Synthesizer" && p.tuneInfo.author == "Chris Hülsbeck")
    // Fifty ticks a second; the period made $71 at least, the volume through the player's; and the
    // song's end where the module goes back.
    #expect(abs(p.tickClocks - 70940) < 5)
    var (values, endings) = played(&p, ticks: 4, 0xA6)
    #expect(values.contains(0x71) && !values.contains(0x60))
    #expect(endings == 1)
    #expect(p.lengthClocks != nil)
    (values, _) = played(&p, ticks: 2, 0xA8)
    #expect(values.contains(0x30))
    // The module moved to where it is: its table of addresses too.
    let at = Int(DynamicSynthesizer.moduleAt)
    let moved = (0 ..< 4).reduce(UInt32(0)) { $0 << 8 | UInt32(p.memory[at + entry + $1]) }
    #expect(moved == DynamicSynthesizer.moduleAt + UInt32(target))
    var q = try DynamicSynthesizerPlayer(file, song: 1, name: "test.dns", files: [("test.smp", samples)])
    try q.select(song: q.song)  // (Played through first, as its renderer has it played.)
    #expect(played(&q, ticks: 3, 0xA6).values.contains(0x80))
    // A module whose code is not as the player first looks for plays a hundred ticks a second.
    var h = try DynamicSynthesizerPlayer(dnsModule(hundred: true), name: "DNS.test", files: [("SMP.test", samples)])
    try h.select(song: h.song)  // (Played through first, as its renderer has it played.)
    _ = played(&h, ticks: 2, 0xA6)
    #expect(abs(h.tickClocks - (0x1BB6 + 1) * 5) < 5)
    // Without its samples, it is refused.
    #expect(throws: TuneError.self) { _ = try DynamicSynthesizerPlayer(file, name: "DNS.test") }
}

/// Cut and changed copies of a module, which its player must refuse or play without trapping or hanging.
private func damage<R: WantedTeamRecipe>(_: R.Type, _ file: [UInt8], name: String = "module", files: [(name: String, bytes: [UInt8])] = []) {
    for cut in stride(from: 0, to: file.count, by: 15) {
        _ = try? WantedTeamPlayer<R>(Array(file.prefix(cut)), name: name, files: files)
    }
    var seed: UInt32 = 2026
    for _ in 0 ..< 15 {
        var damaged = file
        for _ in 0 ..< 4 {
            seed = seed &* 1_103_515_245 &+ 12345
            damaged[Int(seed >> 8) % damaged.count] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        var out = Silent()
        if var p = try? WantedTeamPlayer<R>(damaged, name: name, files: files) { for _ in 0 ..< 10 { _ = p.run(&out) } }
    }
}

@Test func jesperOlsenAndDynamicSynthesizerModulesThatAreDamagedNeverTrapOrHang() {
    damage(JesperOlsen.self, joCodeModule())
    damage(JesperOlsen.self, joDataModule(), files: [(JesperOlsen.replayerName, joReplayer())])
    damage(DynamicSynthesizer.self, dnsModule(), name: "DNS.test", files: [("SMP.test", [UInt8](repeating: 0, count: 64))])
}
