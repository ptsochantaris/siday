// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the recipes for Jason C. Brooke's and Ashley Hogg's music, on tiny modules assembled here
// by hand where UADE puts them: each laid out as its player looks for it, its code changed as the player
// changes it, and its songs ending as the player has them end. The thorough check is made outside the
// package: what every one of UnExoticA's modules writes to Paula, tick by tick and song by song, against
// what it writes in UADE.

private struct Silent: TFMXOutput {
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
}

/// The values a tick's writes put in a register.
private func written(_ writes: [AmigaWrite], _ register: UInt16) -> [UInt16] {
    writes.filter { $0.register == register }.map(\.value)
}

/// Code assembled, padded with noughts to `size` bytes.
private func module(_ a: AmigaAssembly, size: Int) -> [UInt8] {
    var bytes = a.assembled()
    if bytes.count < size { bytes += [UInt8](repeating: 0, count: size - bytes.count) }
    return bytes
}

/// A word of displacement from here to an odd address (which a label cannot be).
private func displacement(_ a: inout AmigaAssembly, to address: UInt32) {
    a.w(UInt16(truncatingIfNeeded: Int(address) - Int(a.here)))
}

/// Runs ticks until the song ends (at most `most`), and gives how many it took.
private func ticksToEnd<R: WantedTeamRecipe>(_ p: inout WantedTeamPlayer<R>, most: Int) -> Int? {
    var out = Silent()
    for tick in 1 ... most {
        _ = p.run(&out)
        if p.endings > 0 { return tick }
    }
    return nil
}

/// How a module of Jason C. Brooke's first kind ends its song, on its third tick.
private enum FirstKindEnding { case stop, wrap }

/// A module of Jason C. Brooke's first kind: its routine for a tick at its start, writing a voice's period
/// (24 in its record), volume (13) and sample (where the player's patches tell EaglePlayer's scopes), and
/// on its third tick its stop of the voices or each voice's list going back to its start; its routine to
/// start a song, which puts the song's entry's second byte in the record's volume; and its three songs.
private func firstKindModule(_ ending: FirstKindEnding) -> [UInt8] {
    var a = AmigaAssembly(at: JasonBrooke.moduleAt)
    let start = a.placed()
    let record = a.label(), sample = a.label(), count = a.label(), done = a.label(), zero = a.label(), table = a.label()
    a.w(0x48E7, 0xF0F0, 0x4240, 0x47FA) // MOVEM.L D0-D3/A0-A3,-(A7); CLR.W D0; LEA start(PC),A3
    a.displacement(to: start)
    a.w(0x4A2B, 0x0000, 0x41FA) // TST.B 0(A3); LEA record(PC),A0
    a.displacement(to: record)
    a.w(0x43FA)
    a.displacement(to: start) // LEA start(PC),A1 (where the player's search begins)
    a.w(0x43F9, 0x00DF, 0xF0A0) // LEA $DFF0A0,A1
    a.w(0x3368, 0x0018, 0x0006, 0x1368, 0x000D, 0x0009, 0x45FA) // MOVE.W 24(A0),6(A1); MOVE.B 13(A0),9(A1); LEA sample(PC),A2
    a.displacement(to: sample)
    a.w(0x7000, 0xD4C0, 0x228A, 0xD0FC, 0x001C) // MOVEQ #0,D0; ADDA.W D0,A2; MOVE.L A2,(A1); ADDA.W #28,A0
    a.w(0x5279)
    a.address(of: count) // ADDQ.W #1,count
    a.w(0x0C79, 0x0003)
    a.address(of: count) // CMPI.W #3,count
    a.branch(0x6600, to: done) // BNE.S
    switch ending {
    case .stop: a.w(0x33FC, 0x000F, 0x00DF, 0xF096) // MOVE.W #$F,$DFF096
    case .wrap:
        let voice = a.label()
        a.w(0x7603) // MOVEQ #3,D3
        a.place(voice)
        a.w(0x45FA)
        a.displacement(to: zero) // LEA zero(PC),A2
        a.w(0x7000, 0x4A72, 0x0000, 0x6602, 0x51C0, 0x224B, 0x51CB) // MOVEQ #0,D0; TST.W 0(A2,D0.W); BNE.S; SF D0; MOVEA.L A3,A1; DBF D3,
        a.displacement(to: voice)
    }
    a.place(done)
    a.w(0x4CDF, 0x0F0F, 0x4E75) // MOVEM.L (A7)+,D0-D3/A0-A3; RTS
    // The routine to start a song: MOVE.B table+1(PC,D0.W),13(A1) (with D0 ten times the song's number),
    // which the player finds its songs by.
    a.w(0x48E7, 0xE0E0, 0x43FA) // MOVEM.L D0-D2/A0-A2,-(A7); LEA record(PC),A1
    a.displacement(to: record)
    a.w(0xC0FC, 0x000A, 0x137B, 0x000B, 0x000D) // MULU.W #10,D0; MOVE.B table+1(PC,D0.W),13(A1)
    a.w(0x4CDF, 0x0707, 0x4E75) // MOVEM.L (A7)+,D0-D2/A0-A2; RTS
    a.place(table)
    for song: UInt16 in 0 ..< 3 { a.w(0x0030 + song, 0, 0, 0, 0) }
    a.w(0)
    a.place(record)
    for at in 0 ..< 14 { a.w(at == 12 ? 0x0123 : 0) }
    a.place(zero)
    a.w(0, 0)
    a.place(count)
    a.w(0)
    a.place(sample)
    for _ in 0 ..< 8 { a.w(0) }
    var bytes = module(a, size: 0)
    // (Each entry's fourth voice's list at the zero word.)
    let tableAt = Int(a.addressOf(table) - JasonBrooke.moduleAt), zeroAt = UInt16(a.addressOf(zero) - JasonBrooke.moduleAt)
    for song in 0 ..< 3 {
        bytes[tableAt + song * 10 + 8] = UInt8(zeroAt >> 8)
        bytes[tableAt + song * 10 + 9] = UInt8(zeroAt & 0xFF)
    }
    return bytes + [UInt8](repeating: 0, count: 2200 - bytes.count)
}

@Test func jasonBrookesFirstKindIsPlayedAsWantedTeamsPlayerPlaysIt() throws {
    let file = firstKindModule(.stop)
    #expect(JasonBrooke.kind(file) == 1)
    #expect(!AshleyHogg.isOne(file) && !Desire.isOne(file))
    var p = try JasonBrookePlayer(file, song: 1)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 3)
    #expect(p.tuneInfo.format == "Jason C. Brooke" && p.tuneInfo.author == "Jason C. Brooke")
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The song's volume (its entry's second byte), through the balance, none; the period; the sample.
    #expect(written(p.writes, 0xA8) == [0x31])
    #expect(written(p.writes, 0xA6) == [0x123])
    #expect(written(p.writes, 0xA2).count == 1)
    _ = p.run(&out)
    #expect(p.endings == 0)
    // The stop of the voices: the song's end.
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
    // Every voice's list back at its start: the song's end too.
    var q = try JasonBrookePlayer(firstKindModule(.wrap))
    try q.select(song: q.song)  // (Played through first, as its renderer has it played.)
    #expect(ticksToEnd(&q, most: 6) == 4)
    // Not the first kind's start.
    var other = file
    other[9] = 0xF6
    #expect(!JasonBrooke.isOne(other))
}

/// A module of Jason C. Brooke's second kind: its variables, with its three songs' table (of eighteen bytes
/// each) in them; its routine for a tick at 172, beginning as the player checks it does, writing a voice's
/// period (32 in its record) and volume (15, and one), the voice's registers by the offset of their place
/// in its record (38), and on its third tick stopping the voices (which the player's patch takes for the
/// song's end); the table's end; and its routine to start a song, which makes the volume 16 and four
/// times the song's number.
private func secondKindModule() -> [UInt8] {
    let at = JasonBrooke.moduleAt
    var a = AmigaAssembly(at: at)
    let start = a.placed()
    let record = a.label(), count = a.label(), done = a.label(), songsEnd = a.label()
    while a.here < at + 64 { a.w(0) }
    for song: UInt16 in 0 ..< 3 { a.w(0, 0x1000 + song, 0, 0x2000, 0, 0x0800, 0, 0x0400, 0) }
    a.place(songsEnd)
    a.w(0x0100)
    while a.here < at + 172 { a.w(0) }
    a.w(0x48E7, 0xF8FC, 0x08F9, 0x0001, 0x00BF, 0xE001) // MOVEM.L D0-D4/A0-A5,-(A7); BSET #1,$BFE001
    a.w(0x33FC, 0x0780, 0x00DF, 0xF09A, 0x47FA) // MOVE.W #$780,$DFF09A; LEA start(PC),A3
    a.displacement(to: start)
    a.w(0x41FA)
    a.displacement(to: record) // LEA record(PC),A0
    a.w(0x7000, 0x49F9, 0x00DF, 0xF000, 0x1028, 0x0026, 0xD8C0) // MOVEQ #0,D0; LEA $DFF000,A4; MOVE.B 38(A0),D0; ADDA.W D0,A4
    a.w(0x3968, 0x0020, 0x0006) // MOVE.W 32(A0),6(A4)
    a.w(0x1228, 0x000F, 0x5201, 0x1941, 0x0009) // MOVE.B 15(A0),D1; ADDQ.B #1,D1; MOVE.B D1,9(A4)
    a.w(0x5279)
    a.address(of: count) // ADDQ.W #1,count
    a.w(0x0C79, 0x0003)
    a.address(of: count) // CMPI.W #3,count
    a.branch(0x6600, to: done) // BNE.S
    a.w(0x7600, 0x33FC, 0x00FF, 0x00DF, 0xF09E, 0x33FC, 0x000F, 0x00DF, 0xF096) // MOVEQ #0,D3; MOVE.W #$FF,$DFF09E; MOVE.W #$F,$DFF096
    a.place(done)
    a.w(0x4CDF, 0x3F1F, 0x4E75, 0x45FA) // MOVEM.L (A7)+,D0-D4/A0-A5; RTS; LEA songsEnd(PC),A2
    a.displacement(to: songsEnd)
    a.w(0x1032, 0x0000, 0x4E75) // MOVE.B 0(A2,D0.W),D0; RTS
    // The routine to start a song (four bytes before its MOVEM), and the songs' table, where its LEA
    // x(PC),A1 points less one.
    a.w(0x4E71, 0x4E71, 0x48E7, 0xC080, 0x43FA) // NOP; NOP; MOVEM.L D0-D1/A0,-(A7); LEA songs+1(PC),A1
    displacement(&a, to: at + 65)
    a.w(0x41FA)
    a.displacement(to: record) // LEA record(PC),A0
    a.w(0x3200, 0xE549, 0x0641, 0x0010, 0x1141, 0x000F) // MOVE.W D0,D1; LSL.W #2,D1; ADDI.W #16,D1; MOVE.B D1,15(A0)
    a.w(0x4CDF, 0x0103, 0x4E75) // MOVEM.L (A7)+,D0-D1/A0; RTS
    a.place(count)
    a.w(0)
    a.place(record)
    for word in 0 ..< 20 { a.w(word == 16 ? 0x0200 : word == 19 ? 0xA000 : 0) }
    return module(a, size: 2000)
}

@Test func jasonBrookesSecondKindIsPlayedAsWantedTeamsPlayerPlaysIt() throws {
    let file = secondKindModule()
    #expect(JasonBrooke.kind(file) == 0)
    var p = try JasonBrookePlayer(file, song: 2)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 3)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The voice whose registers' place its record gives ($A0): its volume (16, eight, and one, through the
    // balance) and its period.
    #expect(written(p.writes, 0xA8) == [25])
    #expect(written(p.writes, 0xA6) == [0x200])
    _ = p.run(&out)
    #expect(p.endings == 0)
    // The stop of the voices with D3 nought: the song's end.
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
    // Not the second kind's start, its LEA pointing elsewhere.
    var other = file
    other[195] = 0x40
    #expect(!JasonBrooke.isOne(other))
    #expect(!JasonBrooke.isOne(Array(file.prefix(190))))
}

/// A module of Ashley Hogg's of 1991: its four BRA.Ws; its routine for a tick at 16 (stopping its voices
/// until the start has set it going), which writes a voice's period ($2C in its record) and volume (22),
/// and takes each voice on along its list of patterns, whose third byte is the loop ($81, which the
/// player's patch takes for that voice's end); its start, which gives its voices' records in A4, puts the
/// song's byte after its songs' table (of two) in the volume and the list in each record; and the samples'
/// information and samples, of which the player checks that they are in the file.
private func ashley1991Module() -> [UInt8] {
    let at = AshleyHogg.moduleAt
    var a = AmigaAssembly(at: at)
    let initL = a.label(), stub = a.label(), voices = a.label(), lists = a.label(), songs = a.label()
    let songsEnd = a.label(), info = a.label(), infoEnd = a.label(), samples = a.label()
    a.w(0x6000)
    a.displacement(to: initL)
    for _ in 0 ..< 3 {
        a.w(0x6000)
        a.displacement(to: stub)
    }
    a.w(0x303C, 0x0000, 0x6622, 0x33C0, 0x00DF, 0xF0A8) // MOVE.W #0,D0; BNE.S +$22; MOVE.W D0,$DFF0A8
    a.place(stub)
    a.w(0x4E75)
    while a.here < at + 56 { a.w(0x4E71) }
    a.w(0x41FA)
    a.displacement(to: voices) // LEA voices(PC),A0
    a.w(0x43F9, 0x00DF, 0xF0A0) // LEA $DFF0A0,A1
    a.w(0x7400, 0xD468, 0x002C, 0x3342, 0x0006) // MOVEQ #0,D2; ADD.W $2C(A0),D2; MOVE.W D2,6(A1)
    a.w(0x7C00, 0x1C28, 0x0016, 0xED4E, 0xEC4E, 0x3346, 0x0008) // MOVEQ #0,D6; MOVE.B 22(A0),D6; LSL.W #6,D6; LSR.W #6,D6; MOVE.W D6,8(A1)
    let voice = a.label()
    a.w(0x7E03) // MOVEQ #3,D7
    a.place(voice)
    a.w(0x2268, 0x0032, 0x7002, 0x52A8, 0x0032, 0x41E8, 0x004A, 0x51CF) // MOVEA.L $32(A0),A1; MOVEQ #2,D0; ADDQ.L #1,$32(A0); LEA 74(A0),A0; DBF D7,
    a.displacement(to: voice)
    a.w(0x4E75)
    a.place(initL)
    a.w(0x49FA)
    a.displacement(to: voices) // LEA voices(PC),A4
    a.w(0x33FC, 0x0001)
    a.long(at + 18) // MOVE.W #1,(the tick's first immediate)
    a.w(0x41FA)
    a.displacement(to: songsEnd) // LEA songsEnd(PC),A0
    a.w(0x1970, 0x0000, 0x0016, 0x41FA) // MOVE.B 0(A0,D0.W),22(A4); LEA songs(PC),A0
    a.displacement(to: songs)
    for v in 0 ..< 4 {
        a.w(0x297C)
        a.address(of: lists)
        a.w(UInt16(0x32 + 74 * v)) // MOVE.L #lists,$32+74v(A4)
        a.w(0x397C, 0x0100, UInt16(0x2C + 74 * v)) // MOVE.W #$100,$2C+74v(A4)
    }
    a.w(0x4E75)
    // (Never run: where the player finds the samples' information.)
    a.w(0xC2FC, 0x002C, 0x47FA)
    a.displacement(to: info) // MULU.W #$2C,D1; LEA info(PC),A3
    a.w(0x47FA)
    a.displacement(to: samples) // LEA samples(PC),A3
    a.w(0x49FA, 0x0000, 0x49FA) // LEA *(PC),A4; LEA infoEnd(PC),A4
    a.displacement(to: infoEnd)
    a.place(voices)
    for _ in 0 ..< 4 * 37 { a.w(0) }
    a.place(lists)
    a.w(0x0101, 0x8100)
    a.place(songs)
    for _ in 0 ..< 8 { a.long(1) }
    a.place(songsEnd)
    a.w(0x2021)
    a.place(info)
    for word in 0 ..< 22 { a.w(word == 20 ? 4 : 0) }
    a.place(infoEnd)
    a.place(samples)
    a.w(0, 0, 0, 0)
    return module(a, size: 0)
}

@Test func ashleyHoggs1991ModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = ashley1991Module()
    #expect(AshleyHogg.kind(file) == 0)
    #expect(!JasonBrooke.isOne(file) && !SeanConnolly.isOne(file))
    var p = try AshleyHoggPlayer(file, song: 1)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Ashley Hogg" && p.tuneInfo.author == "Ashley Hogg")
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The song's volume, through the balance, none; the period.
    #expect(written(p.writes, 0xA8) == [0x21])
    #expect(written(p.writes, 0xA6) == [0x100])
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 0)
    // Every voice's list at its loop: the song's end.
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
    // A module whose samples are not all in it is refused, as the player refuses it.
    #expect(throws: TuneError.self) { _ = try AshleyHoggPlayer(Array(file.dropLast(4))) }
}

/// A module of Ashley Hogg's of 1993 and its samples' file: its seven BRA.Ws and its text; its start,
/// which would set its interrupts going (the player's patch returns from it with its variables kept);
/// its routine to set a song (which keeps its number), where the player finds its songs' table (of three)
/// and the second part of its tick; its routine for a tick, its first interrupt's (the player's patch
/// calls the second part in its place); the second part, which writes a voice's sample, period (in a
/// routine) and volume (the song's number and 16, in another), and on its third ends the song; and the
/// HUNK_END the player looks for at its end.
private func ashley1993Module() -> (module: [UInt8], samples: [UInt8]) {
    var a = AmigaAssembly(at: AshleyHogg.moduleAt)
    let initL = a.label(), setSong = a.label(), stub = a.label(), tick = a.label(), check = a.label()
    let routine = a.label(), vars = a.label(), table = a.label(), play2 = a.label(), setPer = a.label()
    let setVol = a.label(), sample = a.label(), data = a.label()
    for target in [initL, setSong, stub, tick, stub, check, stub] {
        a.w(0x6000)
        a.displacement(to: target)
    }
    let text = Array(" Test Tune: Amiga Audio Driver    by nobody".utf8) + [0]
    for i in stride(from: 0, to: text.count, by: 2) {
        a.w(UInt16(text[i]) << 8 | UInt16(i + 1 < text.count ? text[i + 1] : 0))
    }
    a.place(initL)
    a.w(0x48E7, 0xFFFE, 0x41FA) // MOVEM.L D0-D7/A0-A6,-(A7); LEA vars(PC),A0
    a.displacement(to: vars)
    a.w(0x2149, 0x0010, 0x41F9, 0x00BF, 0xE001, 0x4CDF, 0x7FFF, 0x4E75) // MOVE.L A1,16(A0); LEA $BFE001,A0; MOVEM.L (A7)+,D0-D7/A0-A6; RTS
    a.place(setSong)
    a.w(0x43FA)
    a.displacement(to: vars) // LEA vars(PC),A1
    a.w(0x3340, 0x0000, 0x4269, 0x0002, 0x45FA) // MOVE.W D0,0(A1); CLR.W 2(A1); LEA table(PC),A2
    a.displacement(to: table)
    a.w(0x49FA)
    a.displacement(to: play2) // LEA play2(PC),A4
    a.place(stub)
    a.w(0x4E75)
    a.place(tick)
    a.w(0x48E7, 0xFFFE, 0x49F9, 0x00BF, 0xD000, 0x4A2C, 0x0D00) // MOVEM.L D0-D7/A0-A6,-(A7); LEA $BFD000,A4; TST.B $D00(A4)
    a.w(0x4CDF, 0x7FFF, 0x4E75)
    a.place(check)
    a.w(0x48E7, 0xFFFE, 0x6100) // MOVEM.L D0-D7/A0-A6,-(A7); BSR.W routine
    a.displacement(to: routine)
    a.w(0x4CDF, 0x7FFF, 0x4E75)
    a.place(routine)
    a.w(0x4DF9, 0x00DF, 0xF000, 0x4E75) // LEA $DFF000,A6; RTS
    a.place(play2)
    a.w(0x41FA)
    a.displacement(to: vars) // LEA vars(PC),A0
    a.w(0x4BF9, 0x00DF, 0xF0A0, 0x43FA) // LEA $DFF0A0,A5; LEA sample(PC),A1
    a.displacement(to: sample)
    a.w(0x2B69, 0x0018, 0x0000, 0x3B69, 0x0020, 0x0004) // MOVE.L $18(A1),0(A5); MOVE.W $20(A1),4(A5)
    a.w(0x363C, 0x0123, 0x6100) // MOVE.W #$123,D3; BSR.W setPer
    a.displacement(to: setPer)
    a.w(0x3828, 0x0000, 0x0644, 0x0010, 0x6100) // MOVE.W 0(A0),D4; ADDI.W #16,D4; BSR.W setVol
    a.displacement(to: setVol)
    a.w(0x5268, 0x0002, 0x3028, 0x0002, 0x7203) // ADDQ.W #1,2(A0); MOVE.W 2(A0),D0; MOVEQ #3,D1
    a.w(0xB240, 0x6602, 0x4240, 0x4E75) // CMP.W D0,D1; BNE.S; CLR.W D0; RTS
    a.place(setPer)
    a.w(0x3B43, 0x0006, 0x4E75) // MOVE.W D3,6(A5); RTS
    a.place(setVol)
    a.w(0x3B44, 0x0008, 0x4E75) // MOVE.W D4,8(A5); RTS
    a.place(vars)
    for _ in 0 ..< 128 { a.w(0) }
    a.place(table)
    a.w(0x000C, 0, 0, 0, 0, 0)
    a.place(sample)
    for _ in 0 ..< 12 { a.w(0) }
    a.address(of: data)
    a.w(0, 0, 0x0008)
    a.place(data)
    for _ in 0 ..< 8 { a.w(0) }
    a.w(0x03F2)
    var samples: [UInt8] = []
    for offset: UInt8 in [32, 40] { samples += [0, 0, 0, offset, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0] }
    return (module(a, size: 0), samples + [UInt8](repeating: 0, count: 16))
}

@Test func ashleyHoggs1993ModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let (file, samples) = ashley1993Module()
    #expect(AshleyHogg.kind(file) == 1)
    var p = try AshleyHoggPlayer(file, song: 1, name: "ASH.test", files: [("SMP.test", samples)])
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 3)
    #expect(p.tuneInfo.title == "Test Tune")
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The song's number (from one) and 16 as its volume, through the player's patches; the period, and
    // the sample's length, from its routines and its record.
    #expect(written(p.writes, 0xA8) == [18])
    #expect(written(p.writes, 0xA6) == [0x123])
    #expect(written(p.writes, 0xA4) == [8])
    #expect(p.endings == 0)
    // The third call of its second part (the first was the start's): the song's end.
    #expect(ticksToEnd(&p, most: 4) == 1)
    #expect(p.lengthClocks != nil)
    // The samples beside it as the collections name them, `name.smp` for `name.ash`.
    var q = try AshleyHoggPlayer(file, name: "Test.ash", files: [("Test.smp", samples)])
    try q.select(song: q.song)  // (Played through first, as its renderer has it played.)
    #expect(q.songCount == 3)
    // And none: refused, as wanting them; or too short for its samples.
    #expect(throws: TuneError.self) { _ = try AshleyHoggPlayer(file, name: "ASH.test") }
    #expect(throws: TuneError.self) { _ = try AshleyHoggPlayer(file, name: "test", files: [("SMP.test", samples)]) }
    #expect(throws: TuneError.self) { _ = try AshleyHoggPlayer(file, name: "ASH.test", files: [("SMP.test", Array(samples.prefix(40)))]) }
}

@Test func ashleyHoggsSamplesAreAskedForByTheNamesThePlayerGives() {
    func name(_ s: String) -> String? { AshleyHogg.samplesName(Array(s.utf8)).map { String(decoding: $0, as: UTF8.self) } }
    #expect(name("ASH.Cosmic") == "SMP.Cosmic")
    #expect(name("music/ash.Dizzy") == "music/SMP.Dizzy")
    #expect(name("Fantastic_Dizzy.ash") == "Fantastic_Dizzy.smp")
    #expect(name("dir/Cosmic.ASH") == "dir/Cosmic.smp")
    #expect(name("Cosmic.mod") == nil)
    #expect(name(".ash") == nil)
}
