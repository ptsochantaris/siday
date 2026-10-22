// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
import Testing

// Fast checks of the recipes for Desire's music, SCUMM's sounds and Sean Connolly's music, on tiny modules
// assembled here by hand where UADE puts them: each laid out as its player looks for it, its code changed
// as the player changes it, and its songs ending as the player (or siday) has them end. The thorough
// check is made outside the package: what every one of UnExoticA's modules writes to Paula, tick by tick
// and song by song, against what it writes in UADE.

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

/// How a module of Desire's ends its song, on its third tick.
private enum DesireEnding { case stops, jumps, countedLoops }

/// A module of Desire's: four voices' records; three songs; a tick (from 240 bytes in) that writes its
/// record's first byte twice over, halved, to voice 0's period (as his code writes periods, which the
/// player patches), and a volume of $50 (which the player's patch turns down by the balance, here none);
/// and on its third, for each voice, the end `ending` asks for: its stop, its jump to another part of its
/// list (which siday takes for its end), or its going back to its mark with a count of times to go
/// (which is not an end).
private func desireModule(_ ending: DesireEnding) -> [UInt8] {
    var a = AmigaAssembly(at: Desire.moduleAt)
    let start = a.placed()
    for _ in 0 ..< 4 { a.w(0, 0, 0, 0, 0x0001, 0x0101, 0, 0) }
    while a.here < Desire.moduleAt + 240 { a.w(0) }
    let count = a.label(), done = a.label(), songs = a.label(), lengths = a.label(), offsets = a.label()
    a.w(0x49FA, 0x0000, 0x45F9, 0x00DF, 0xF000, 0x357C, 0x00FF, 0x009E, 0x41FA) // LEA *(PC),A4; LEA $DFF000,A2; MOVE.W #$FF,$9E(A2); LEA module(PC),A0
    a.displacement(to: start)
    a.w(0x43F9, 0x00DF, 0xF000, 0x7200, 0x1210, 0xD241) // LEA $DFF000,A1; MOVEQ #0,D1; MOVE.B (A0),D1; ADD.W D1,D1
    a.w(0xE249, 0x3341, 0x00A6) // LSR.W #1,D1; MOVE.W D1,$A6(A1)
    a.w(0x323C, 0x0050, 0x0241, 0x00FF, 0x3341, 0x00A8) // MOVE.W #$50,D1; ANDI.W #$FF,D1; MOVE.W D1,$A8(A1)
    a.w(0x5279)
    a.address(of: count) // ADDQ.W #1,count
    a.w(0x0C79, 0x0003)
    a.address(of: count) // CMPI.W #3,count
    a.branch(0x6600, to: done) // BNE.S
    for v in 0 ..< 4 {
        a.w(0x43F9, 0x00DF, 0xF000 + UInt16(v * 16), 0x41F9) // LEA $DFF0x0,A1; LEA record,A0
        a.long(Desire.moduleAt + UInt32(v * 16))
        switch ending {
        case .stops: a.w(0x4269, 0x00A8, 0x117C, 0x0080, 0x0000) // CLR.W $A8(A1); MOVE.B #$80,0(A0)
        case .jumps:
            a.w(0x47F9)
            a.long(Desire.moduleAt) // LEA module,A3
            a.w(0x4281, 0x122B, 0x0001, 0x0801, 0x0006) // CLR.L D1; MOVE.B 1(A3),D1; BTST #6,D1
        case .countedLoops: a.w(0x3168, 0x000C, 0x000E) // MOVE.W 12(A0),14(A0) (the count, 11(A0), is 1)
        }
    }
    a.place(done)
    a.w(0x4E75)
    a.place(count)
    a.w(0)
    // What the player looks for after the tick: the songs (counted to a byte the same as the next), and
    // the samples' lengths and offsets, shifted by three.
    a.w(0x47FA)
    a.displacement(to: songs)
    for _ in 0 ..< 10 { a.w(0x4E71) }
    a.w(0xE341, 0x47FA)
    a.displacement(to: lengths)
    a.w(0x47FA)
    a.displacement(to: offsets)
    a.w(0x47FA, 0x0000, 0xE78A) // LEA *(PC),A3; LSL.L #3,D2
    a.place(songs)
    a.w(0x0001, 0x0203, 0x0300)
    a.place(offsets)
    a.w(0x0000, 0x0010)
    a.place(lengths)
    a.w(0x0008, 0x0008)
    return module(a, size: 3000)
}

@Test func desireModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = desireModule(.stops)
    #expect(Desire.isOne(file))
    #expect(!Scumm.isOne(file) && !SeanConnolly.isOne(file) && !CoreDesign.isOne(file))
    #expect(!Desire.isOne(Array(file.prefix(2500))))
    var p = try DesirePlayer(file, song: 1)
    #expect(p.songCount == 3)
    #expect(p.tuneInfo.format == "Desire")
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The song's number (64 and the song's, from one), from its records, and the volume, through the
    // player's patches.
    #expect(written(p.writes, 0xA6) == [64 + 2])
    #expect(written(p.writes, 0xA8) == [0x50])
    _ = p.run(&out)
    #expect(p.endings == 0)
    // All four voices stopping themselves: the song's end.
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
}

@Test func desireSongsThatGoBackEndThere() throws {
    // Each voice jumping in its list is the song's end; going back to its mark with a count to go is not.
    var p = try DesirePlayer(desireModule(.jumps))
    #expect(p.lengthClocks != nil)
    var out = Silent()
    for _ in 0 ..< 4 { _ = p.run(&out) }
    #expect(p.endings == 1)
    let q = try DesirePlayer(desireModule(.countedLoops))
    #expect(q.lengthClocks == nil)
}

/// A sound of SCUMM's: its code, which on its first call (bit 4 of D0 set) writes the address of its
/// samples to voice 0's and D0 to AUD1PER, and on the others counts in the memory it is given at A0 and
/// writes the count to AUD0PER, saying it has finished (the carry set) on its third.
private func scummSound() -> [UInt8] {
    var a = AmigaAssembly(at: Scumm.moduleAt)
    let play = a.label(), out = a.label(), finished = a.label()
    a.w(0x0000, 0x0000) // (and the distance from the next word to the samples, below)
    a.w(0x48E7, 0x7FFE, 0x0880, 0x0004) // MOVEM.L D1-D7/A0-A6,-(A7); BCLR #4,D0
    a.branch(0x6700, to: play) // BEQ.S
    a.w(0x4250, 0x23C9, 0x00DF, 0xF0A0, 0x33C0, 0x00DF, 0xF0B6) // CLR.W (A0); MOVE.L A1,$DFF0A0; MOVE.W D0,$DFF0B6
    a.branch(0x6000, to: out) // BRA.S
    a.place(play)
    a.w(0x5250, 0x33D0, 0x00DF, 0xF0A6, 0x0C50, 0x0003) // ADDQ.W #1,(A0); MOVE.W (A0),$DFF0A6; CMPI.W #3,(A0)
    a.branch(0x6700, to: finished) // BEQ.S
    a.place(out)
    a.w(0x44FC, 0x0000, 0x4CDF, 0x7FFE, 0x4E75) // MOVE #0,CCR; MOVEM.L (A7)+,D1-D7/A0-A6; RTS
    a.place(finished)
    a.w(0x44FC, 0x0001, 0x4CDF, 0x7FFE, 0x4E75) // MOVE #1,CCR; MOVEM.L (A7)+,D1-D7/A0-A6; RTS
    a.w(0x1020, 0x3040)
    var bytes = module(a, size: 0)
    bytes[3] = UInt8(bytes.count - 8)
    return bytes
}

@Test func scummSoundsArePlayedAsTheirPlayerPlaysThem() throws {
    let file = scummSound()
    #expect(Scumm.isOne(file))
    #expect(!Desire.isOne(file) && !SeanConnolly.isOne(file))
    var p = try ScummPlayer(file)
    #expect(p.songCount == 1)
    #expect(p.tuneInfo.format == "SCUMM")
    var out = Silent()
    _ = p.run(&out)
    // The first call: its samples' address, past its second word by the distance there, and D0 all set
    // but bit 4.
    _ = p.run(&out)
    #expect(written(p.writes, 0xA2) == [UInt16(Scumm.moduleAt + UInt32(file.count) - 4)])
    #expect(written(p.writes, 0xB6) == [0xFFEF])
    // The others: its count, kept in its memory; and its end, said by the carry.
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(written(p.writes, 0xA6) == [2])
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(written(p.writes, 0xA6) == [3])
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
}

/// A module of Sean Connolly's V3.18: its four BRA.Ws and a line of text; a start that writes its song's
/// number (times 16, as his code has it) to AUD1PER; its songs' table, of three, whose end the player
/// finds by its `$0000 $41FA` far on; and a tick that writes the four voices from its table (as his code
/// does, which the player patches) and on its second takes the first voice's list back to its start
/// (which the player's patch takes for the song's end).
private func seanConnollyModule() -> [UInt8] {
    var a = AmigaAssembly(at: SeanConnolly.moduleAt)
    let initSong = a.label(), play = a.label(), table = a.label(), songs = a.label(), songsEnd = a.label()
    let count = a.label(), done = a.label(), list = a.label()
    a.w(0x6000)
    a.displacement(to: initSong)
    for _ in 0 ..< 3 {
        a.w(0x6000)
        a.displacement(to: play)
    }
    a.w(0x5465, 0x7374, 0x0000, 0x0000) // "Test"
    a.place(initSong)
    a.w(0x48E7, 0x7FFE, 0xE988, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(A7); LSL.L #4,D0; LEA songs(PC),A0
    a.displacement(to: songs)
    a.w(0x33C0, 0x00DF, 0xF0B6, 0x4CDF, 0x7FFE, 0x4E75) // MOVE.W D0,$DFF0B6; MOVEM.L (A7)+,D1-D7/A0-A6; RTS
    a.place(play)
    a.w(0x41FA)
    a.displacement(to: table) // LEA table(PC),A0
    a.w(0x43F9, 0x00DF, 0xF000, 0x2350, 0x00A0) // LEA $DFF000,A1; MOVE.L (A0),$A0(A1)
    for v: UInt16 in 0 ..< 4 {
        if v > 0 { a.w(0x2368, v * 16, 0xA0 + v * 16) } // MOVE.L 16v(A0),$Ax0(A1)
        a.w(0x2368, v * 16 + 4, 0xA4 + v * 16, 0x3368, v * 16 + 8, 0xA8 + v * 16) // MOVE.L 16v+4(A0),$Ax4(A1); MOVE.W 16v+8(A0),$Ax8(A1)
    }
    a.w(0x5279)
    a.address(of: count) // ADDQ.W #1,count
    a.w(0x0C79, 0x0002)
    a.address(of: count) // CMPI.W #2,count
    a.branch(0x6600, to: done) // BNE.S
    a.w(0x47FA)
    a.displacement(to: list) // LEA list(PC),A3
    a.w(0x45FA)
    a.displacement(to: list) // LEA list(PC),A2
    a.w(0x7000, 0x15AB, 0x0002, 0x0000) // MOVEQ #0,D0; MOVE.B 2(A3),0(A2,D0.W)
    a.place(done)
    a.w(0x4E75)
    a.place(count)
    a.w(0)
    a.place(list)
    a.w(0, 0)
    a.place(table)
    for v: UInt16 in 0 ..< 4 { a.w(0x0001, 0x2000, 0x0010, 0x0100 + v, 0x0030 + v, 0, 0, 0) }
    a.place(songs)
    for _ in 0 ..< 24 { a.w(0) }
    a.place(songsEnd)
    // (Where the player's search back from 3,020 bytes past its place before the start finds it.)
    while a.here < SeanConnolly.moduleAt + 2000 { a.w(0) }
    a.w(0x0000, 0x41FA)
    a.displacement(to: songsEnd)
    return module(a, size: 2600)
}

@Test func seanConnollyModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = seanConnollyModule()
    #expect(SeanConnolly.version(file) == 2)
    #expect(SeanConnolly.isOne(file) && !Desire.isOne(file) && !Scumm.isOne(file))
    var p = try SeanConnollyPlayer(file, song: 1)
    #expect(p.songCount == 3)
    #expect(p.tuneInfo.format == "Sean Connolly" && p.tuneInfo.author == "Sean Connolly" && p.tuneInfo.detail == "V3.18")
    #expect(written(p.startWrites, 0xB6).last == 16)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The voices from the table, through the player's patch (the volumes through the balance, none).
    #expect(written(p.writes, 0xA8) == [0x30] && written(p.writes, 0xD8) == [0x33])
    #expect(written(p.writes, 0xB6) == [0x101])
    #expect(p.endings == 0)
    // The first voice's list back at its start: the song's end.
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
    // The other versions are refused.
    var other = file
    other[0x1C] = 0x32 // (where the start's LSL.L #4,D0 is)
    #expect(SeanConnolly.version(other) == nil)
}
