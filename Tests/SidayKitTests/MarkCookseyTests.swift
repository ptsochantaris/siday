// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the recipe for Mark Cooksey's music, on tiny modules assembled here by hand where UADE puts
// them: each laid out as the player looks for it, its code changed as the player changes it, and its songs
// ending as the player has them end. The thorough check is made outside the package: what every one of
// UnExoticA's modules writes to Paula, tick by tick and song by song, against what it writes in UADE.

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

/// Code assembled at `at`, padded with noughts to `size` bytes.
private func module(_ a: AmigaAssembly, size: Int) -> [UInt8] {
    var bytes = a.assembled()
    if bytes.count < size { bytes += [UInt8](repeating: 0, count: size - bytes.count) }
    return bytes
}

/// A new module of Mark Cooksey's, of 1989 (four BRA.Ws, and a LEA x(PC),A1 at 40) or 1990 (five, the
/// first a routine to make it ready, and the LEA at 150): three songs; a tick that writes 100 and the
/// song's number (and 1,000 if it was made ready) to voice 0's period, through his `SWAP D0; MOVE.W
/// D0,$A6(A4)`, and $60 as a volume, quartered as his code of 1989 does it (the player halves it); and on
/// its third, each voice's command $67, its stop.
private func newModule(of1990: Bool) -> [UInt8] {
    var a = AmigaAssembly(at: MarkCooksey.moduleAt)
    let play = a.label(), start = a.label(), ready = a.label(), back = a.label(), songs = a.label(), songsEnd = a.label()
    let song = a.label(), count = a.label(), base = a.label(), flag = a.label(), done = a.label()
    a.w(0xD040, 0xD040, 0x4EFB, of1990 ? 0x0006 : 0x0002) // ADD.W D0,D0; ADD.W D0,D0; JMP x(PC,D0.W)
    for routine in of1990 ? [ready, play, start, back, back] : [play, start, back, back] {
        a.w(0x6000)
        a.displacement(to: routine) // BRA.W
    }
    a.place(back)
    a.w(0x4E75)
    while a.here < MarkCooksey.moduleAt + (of1990 ? 150 : 40) { a.w(0) }
    a.w(0x43FA)
    a.displacement(to: songs) // LEA songs(PC),A1
    a.w(0x43FA)
    a.displacement(to: songsEnd) // LEA songsEnd(PC),A1
    // Made ready: 1,000 added to the periods.
    a.place(ready)
    a.w(0x33FC, 1000)
    a.address(of: base) // MOVE.W #1000,base
    a.w(0x4E75)
    // A song started: its number, from D0's upper word.
    a.place(start)
    a.w(0x4840, 0x33C0)
    a.address(of: song) // SWAP D0; MOVE.W D0,song
    a.w(0x4279)
    a.address(of: count) // CLR.W count
    a.w(0x4E75)
    a.place(play)
    a.w(0x49F9, 0x00DF, 0xF000, 0x47FA) // LEA $DFF000,A4; LEA flag(PC),A3
    a.displacement(to: flag)
    a.w(0x303A)
    a.displacement(to: song) // MOVE.W song(PC),D0
    a.w(0xD07A)
    a.displacement(to: base) // ADD.W base(PC),D0
    a.w(0x0640, 100, 0x4840, 0x4840, 0x3940, 0x00A6) // ADDI.W #100,D0; SWAP D0; SWAP D0; MOVE.W D0,$A6(A4)
    a.w(0x303C, 0x0060, 0xE448, 0x4A2B, 0x0000, 0x6704, 0x3940, 0x00A8) // MOVE.W #$60,D0; LSR.W #2,D0; TST.B 0(A3); BEQ.S; MOVE.W D0,$A8(A4)
    a.w(0x5279)
    a.address(of: count) // ADDQ.W #1,count
    a.w(0x0C79, 0x0003)
    a.address(of: count) // CMPI.W #3,count
    a.branch(0x6600, to: done) // BNE.S
    for v in 0 ..< 4 {
        // LEA $DFF0x0,A4; MOVEQ #$67,D0; MOVEQ #$7F,D1; AND.B D0,D1; SUBI.B #$60,D1
        a.w(0x49F9, 0x00DF, 0xF000 + UInt16(v * 16), 0x7067, 0x727F, 0xC200, 0x0401, 0x0060)
    }
    a.place(done)
    a.w(0x4E75)
    for label in [song, count, base] {
        a.place(label)
        a.w(0)
    }
    a.place(flag)
    a.w(0xFF00)
    a.place(songs)
    for _ in 0 ..< 3 * 8 { a.w(0) }
    a.place(songsEnd)
    return module(a, size: 3000)
}

@Test func markCookseyNewModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    for of1990 in [false, true] {
        let file = newModule(of1990: of1990)
        #expect(MarkCooksey.isOne(file))
        #expect(!CoreDesign.isOne(file) && !Desire.isOne(file))
        var p = try MarkCookseyPlayer(file, song: 2)
        #expect(p.songCount == 3)
        #expect(p.tuneInfo.format == "Mark Cooksey")
        #expect(p.tuneInfo.author == "Mark Cooksey")
        var out = Silent()
        _ = p.run(&out)
        _ = p.run(&out)
        // The period through the player's patch, and the volume of $60 halved, not quartered.
        #expect(written(p.writes, 0xA6) == [(of1990 ? 1100 : 100) + 2])
        #expect(written(p.writes, 0xA8) == [0x30])
        _ = p.run(&out)
        #expect(p.endings == 0)
        // All four voices stopping: the song's end.
        _ = p.run(&out)
        #expect(p.endings == 1)
        #expect(p.lengthClocks != nil)
    }
    // Not a module: the jump by D0 without its BRA.Ws, or cut before the LEA.
    var file = newModule(of1990: false)
    #expect(!MarkCooksey.isOne(Array(file.prefix(40))))
    file[12] = 0x4E
    #expect(!MarkCooksey.isOne(file))
}

/// A first module of Mark Cooksey's (the code) and its song data, two songs: a tick that, for each
/// voice, starts its sample (the voice's records in the code, its sample in the data), as his code of
/// 1988 does it and the player changes, at a period of 300 and the song's number; and on its third, stops
/// each voice.
private func firstModule() -> (code: [UInt8], data: [UInt8]) {
    var a = AmigaAssembly(at: MarkCooksey.moduleAt)
    let initRoutine = a.label(), play = a.label(), back = a.label(), voice = a.label(), stop = a.label()
    let song = a.label(), count = a.label(), records = a.label(), done = a.label(), end = a.label()
    a.w(0x601A)
    a.address(of: end) // (the code's size, made right below)
    for _ in 0 ..< 11 { a.w(0) }
    for routine in [initRoutine, back, play, back] {
        a.w(0x6000)
        a.displacement(to: routine) // BRA.W
    }
    a.place(back)
    a.w(0x4E75)
    // A song started: its number from D0, and where its sample is in the data (from A0, 28 bytes in).
    a.place(initRoutine)
    a.w(0x48E7, 0x80F0, 0x33C0) // MOVEM.L D0/A0-A3,-(A7); MOVE.W D0,song
    a.address(of: song)
    a.w(0x4279)
    a.address(of: count) // CLR.W count
    a.w(0x43FA)
    a.displacement(to: records) // LEA records(PC),A1
    a.w(0x41E8, 0x0020) // LEA 32(A0),A0
    for v in 0 ..< 4 { a.w(0x2348, UInt16(v * 32 + 10)) } // MOVE.L A0,10+32v(A1)
    a.w(0x4CDF, 0x0F01, 0x4E75) // MOVEM.L (A7)+,D0/A0-A3; RTS
    a.place(play)
    a.w(0x5279)
    a.address(of: count) // ADDQ.W #1,count
    a.w(0x41F9, 0x00DF, 0xF000, 0x45FA) // LEA $DFF000,A0; LEA records(PC),A2
    a.displacement(to: records)
    a.w(0x4BF9, 0x00DF, 0xF0A0) // LEA $DFF0A0,A5
    for _ in 0 ..< 4 {
        let next = a.label(), started = a.label()
        a.w(0x0C79, 0x0003)
        a.address(of: count) // CMPI.W #3,count
        a.branch(0x6600, to: started) // BNE.S
        a.w(0x6100)
        a.displacement(to: stop) // BSR.W stop
        a.branch(0x6000, to: next) // BRA.S
        a.place(started)
        a.w(0x6100)
        a.displacement(to: voice) // BSR.W voice
        a.place(next)
        a.w(0x45EA, 32, 0x4BED, 16) // LEA 32(A2),A2; LEA 16(A5),A5
    }
    a.w(0x4E75)
    // A voice's sample started: its period on the stack, then his code (which the player makes a jump at its
    // first instruction), the rest of it there to be found.
    a.place(voice)
    a.w(0x383A)
    a.displacement(to: song) // MOVE.W song(PC),D4
    a.w(0x0644, 300, 0x3F04) // ADDI.W #300,D4; MOVE.W D4,-(A7)
    a.w(0x3828, 0x0002, 0xC86A, 0x0006) // MOVE.W 2(A0),D4; AND.W 6(A2),D4
    a.w(0x316A, 0x0008, 0x009C, 0x316A, 0x0006, 0x0096) // MOVE.W 8(A2),$9C(A0); MOVE.W 6(A2),$96(A0)
    a.w(0x286A, 0x000A, 0x381C, 0x2B4C, 0x0000, 0x3B44, 0x0004) // MOVEA.L 10(A2),A4; MOVE.W (A4)+,D4; MOVE.L A4,0(A5); MOVE.W D4,4(A5)
    a.w(0x3B6A, 0x0012, 0x0008) // MOVE.W 18(A2),8(A5)
    a.w(0x286A, 0x0016, 0x290B, 0x254C, 0x0016) // MOVEA.L $16(A2),A4; MOVE.L A3,-(A4); MOVE.L A4,$16(A2)
    a.w(0x4E75)
    a.place(stop)
    a.w(0x78FF, 0x3544, 0x0000, 0x4E75) // MOVEQ #-1,D4; MOVE.W D4,0(A2); RTS
    a.w(0x254B, 0x0002, 0x4E75) // MOVE.L A3,2(A2); RTS
    for label in [song, count] {
        a.place(label)
        a.w(0)
    }
    // Each voice's record: its bit for DMACON at 6, its sample at 10, its volume at 18.
    a.place(records)
    for v in 0 ..< 4 { a.w(0, 0, 0, 1 << UInt16(v), 0x80 << UInt16(v), 0, 0, 0, 0, 0x30, 0, 0, 0, 0, 0, 0) }
    a.place(end)
    var code = module(a, size: 0)
    let size = UInt32(code.count - 28)
    code[2 ... 5] = [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
    // The data: its header; its songs' table (from 28: a long, then its end, eight bytes on and two
    // songs of sixteen bytes past it); and the sample, its length's word and eight bytes.
    var data: [UInt8] = [0x60, 0x1A, 0, 0, 0, 64] + [UInt8](repeating: 0, count: 22)
    data += [0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 40] + [UInt8](repeating: 0, count: 20)
    data += [0, 4, 1, 2, 3, 4, 5, 6, 7, 8] + [UInt8](repeating: 0, count: 22)
    return (code, data)
}

@Test func markCookseyFirstModulesArePlayedWithTheirSongData() throws {
    let (code, data) = firstModule()
    #expect(MarkCooksey.isOne(code))
    #expect(!MarkCooksey.isOne(data))
    for (name, other) in [("game.mcr", "game.mcs"), ("MCR.game", "MCS.game")] {
        var p = try MarkCookseyPlayer(code, song: 1, name: name, files: [(other, data)])
        #expect(p.songCount == 2)
        var out = Silent()
        _ = p.run(&out)
        _ = p.run(&out)
        // Each voice's sample started by the player's routine: its address (past its length's word) and
        // length, its volume, its period from the stack; then looped on the player's four bytes of silence.
        let sampleAt = MarkCooksey.moduleAt + UInt32((code.count + 1024) & ~0xFF) + 28 + 32 + 2
        #expect(written(p.writes, 0xA4) == [4, 2])
        #expect(written(p.writes, 0xA8) == [0x30])
        #expect(written(p.writes, 0xA6) == [301])
        #expect(written(p.writes, 0xA0) == [UInt16(sampleAt >> 16), UInt16(MarkCooksey.silence >> 16)])
        #expect(written(p.writes, 0xA2) == [UInt16(sampleAt & 0xFFFF), UInt16(MarkCooksey.silence & 0xFFFF)])
        #expect(written(p.writes, 0xD4) == [4, 2])
        _ = p.run(&out)
        #expect(p.endings == 0)
        // All four voices stopping: the song's end.
        _ = p.run(&out)
        #expect(p.endings == 1)
        #expect(p.lengthClocks != nil)
    }
    // Without its song data, or named so that it cannot be found, it is refused.
    #expect(throws: TuneError.self) { try MarkCookseyPlayer(code, name: "game.mcr") }
    #expect(throws: TuneError.self) { try MarkCookseyPlayer(code, name: "game", files: [("game.mcs", data)]) }
    var bad = data
    bad[0] = 0
    #expect(throws: TuneError.self) { try MarkCookseyPlayer(code, name: "game.mcr", files: [("game.mcs", bad)]) }
}

@Test func markCookseyDamagedModulesNeitherTrapNorHang() throws {
    var out = Silent()
    let (code, data) = firstModule()
    for file in [newModule(of1990: false), newModule(of1990: true), code] {
        for length in stride(from: 0, through: file.count, by: max(1, file.count / 40)) {
            guard var p = try? MarkCookseyPlayer(Array(file.prefix(length)), name: "x.mcr", files: [("x.mcs", data)]) else { continue }
            for _ in 0 ..< 20 { _ = p.run(&out) }
        }
    }
    for length in stride(from: 0, through: data.count, by: 4) {
        guard var p = try? MarkCookseyPlayer(code, name: "x.mcr", files: [("x.mcs", Array(data.prefix(length)))]) else { continue }
        for _ in 0 ..< 20 { _ = p.run(&out) }
    }
}
