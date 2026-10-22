// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
import Testing

// Fast checks of Steve Barrett's, Rob Hubbard's (of 1989 to 1991, and on Steve Bak's replayer) and Frederic
// Hahn's music as Wanted Team's players and UADE's play it, on tiny modules assembled here by hand: each laid
// out as its player looks for it, its code changed as the player changes it, and its songs ending as the
// player has them end. The thorough check is made outside the package: what every one of UnExoticA's
// modules writes to Paula, tick by tick and song by song, against what it writes in UADE.

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

/// A module of raw 68000 code (as these formats' modules are, loaded where UADE puts them), assembled a
/// word at a time, with labels for its PC-relative displacements and their offsets.
private struct RawModule {
    private(set) var words: [UInt16] = []
    private var labels: [String: Int] = [:]
    private var relative: [(at: Int, label: String)] = []
    private var offsets: [(at: Int, label: String)] = []

    var here: Int { words.count * 2 }
    mutating func label(_ name: String) { labels[name] = here }
    mutating func w(_ values: UInt16...) { words += values }
    mutating func w(_ values: [UInt16]) { words += values }
    mutating func long(_ value: UInt32) { words += [UInt16(value >> 16), UInt16(value & 0xFFFF)] }
    /// A displacement to the label from this word's place (a Bcc.W, a JMP or LEA d16(PC)).
    mutating func to(_ name: String) {
        relative.append((words.count, name))
        words.append(0)
    }

    /// The label's offset in the module, as a word.
    mutating func offset(_ name: String) {
        offsets.append((words.count, name))
        words.append(0)
    }

    /// NOPs up to the offset.
    mutating func pad(to offset: Int) {
        precondition(here <= offset)
        while here < offset { words.append(0x4E71) }
    }

    func at(_ name: String) -> Int { labels[name]! }

    func bytes() -> [UInt8] {
        var words = self.words
        for (at, name) in relative { words[at] = UInt16(truncatingIfNeeded: labels[name]! - at * 2) }
        for (at, name) in offsets { words[at] = UInt16(labels[name]!) }
        return words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}

// MARK: Steve Barrett

/// A module of Steve Barrett's: four branches; a text with "tt" in it (which the player ends at the code
/// after it); a routine that makes its samples ready, giving the base of its variables and its samples (an
/// 8SVX "FORM"); two songs; a start that keeps the song's number; and a tick that writes the number as a
/// period by its routine for periods (which the player makes a jump to its own), four volumes as his code
/// writes them, turns voice 0's DMA on as his code does, waits for the DMA as his code waits, and reads
/// each voice's next byte of a list that ends ($FF) at its third. With `fast`, its samples take 62,372
/// bytes, as Advanced Ski Simulator's do (whose ticks the player makes twice as fast).
private func sbModule(fast: Bool = false) -> [UInt8] {
    var p = RawModule()
    p.label("base")
    for routine in ["samplesInit", "songInit", "play", "stop"] {
        p.w(0x6000)
        p.to(routine)
    }
    p.w(0x5465, 0x7374, 0x2074, 0x7421, 0x205A) // "Test tt! Z"
    p.label("samplesInit")
    p.w(0x49FA)
    p.to("base") // LEA base(PC),A4
    p.w(0x41FA)
    p.to("form") // LEA form(PC),A0
    p.w(0x45FA)
    p.to("form") // LEA form(PC),A2
    if fast { p.w(0xD1FC, 0x0000, 0xF3A0) } // ADDA.L #62368,A0
    p.w(0x4E75)
    p.label("songInit")
    p.w(0x47FA)
    p.to("song")
    p.w(0x1680, 0x4E75) // LEA song(PC),A3; MOVE.B D0,(A3); RTS
    p.label("stop")
    p.w(0x4E71, 0x2A7C, 0x00DF, 0xF0A8, 0x4E75) // NOP; MOVEA.L #$DFF0A8,A5; RTS
    p.label("play")
    // The song's number as voice 0's period.
    p.w(0x43F9, 0x00DF, 0xF0A6, 0x7600, 0x7000, 0x103A) // LEA $DFF0A6,A1; MOVEQ #0,D3; MOVEQ #0,D0; MOVE.B song(PC),D0
    p.to("song")
    p.w(0x6100)
    p.to("period") // BSR.W period
    // Four volumes: $40, and the list's $20, $30, $10.
    p.w(0x45F9, 0x00DF, 0xF0A8, 0x43FA) // LEA $DFF0A8,A2; LEA volumes(PC),A1
    p.to("volumes")
    p.w(0x303C, 0x0040, 0x3480, 0x1019, 0x3540, 0x0010, 0x1019, 0x3540, 0x0020, 0x1011, 0x3540, 0x0030)
    // Voice 0's DMA on, and the wait for it.
    p.w(0x7201, 0x0081, 0x0000, 0x8200, 0x3039, 0x00DF, 0xF002, 0x0240, 0x05F0, 0x8240, 0x33C1, 0x00DF, 0xF096, 0x0A41, 0xFFFF)
    p.w(0x7203, 0x740C, 0x7606)
    // Each voice's next byte of the list.
    p.w(0x49FA)
    p.to("base")
    for v in 0 ..< 4 {
        p.w(0x197C, UInt16(v))
        p.offset("byte") // MOVE.B #v,byte(A4)
        p.w(0x41FA)
        p.to("record\(v)") // LEA record(PC),A0
        p.w(0x43FA)
        p.to("list") // LEA list(PC),A1
        p.w(0x7000, 0x1028, 0x000C, 0x5228, 0x000C, 0xD3C0) // MOVEQ #0,D0; MOVE.B 12(A0),D0; ADDQ.B #1,12(A0); ADDA.L D0,A1
    }
    p.w(0x4E75)
    // What the player looks for, in its order, the routine for periods last.
    p.w(0xE740, 0x4281, 0x41FA)
    p.to("songs")
    p.w(0x41FA)
    p.to("record0")
    p.w(0xD080, 0x43FA)
    p.to("songsEnd")
    p.w(0x197C, 0x0003)
    p.offset("byte")
    p.label("period")
    p.w(0xD3C3, 0x3280, 0x4E75) // ADDA.L D3,A1; MOVE.W D0,(A1); RTS
    p.label("songs")
    for _ in 0 ..< 8 { p.offset("list") }
    p.label("songsEnd")
    for v in 0 ..< 4 {
        p.label("record\(v)")
        for _ in 0 ..< 8 { p.w(0) }
    }
    p.label("list")
    p.w(0x0000, 0xFF00)
    p.label("volumes")
    p.w(0x2030, 0x1000)
    p.label("song")
    p.w(0)
    p.label("byte")
    p.w(0)
    p.label("form")
    p.long(0x464F_524D)
    p.long(0)
    return p.bytes()
}

@Test func steveBarrettModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = sbModule()
    #expect(SteveBarrett.isOne(file))
    #expect(!RobHubbard.isOne(file) && !RobHubbardST.isOne(file) && !FredMonitor.isOne(file) && !CoreDesign.isOne(file))
    var p = try SteveBarrettPlayer(file, song: 1)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Steve Barrett" && p.tuneInfo.detail == "Test tt  ")
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The song's number (from one, as the player numbers them), by the player's routine for periods.
    #expect(written(p.writes, 0xA6) == [2])
    // The volumes, through the player's patch (for the balance, which is none).
    #expect(written(p.writes, 0xA8) == [0x40] && written(p.writes, 0xB8) == [0x20])
    #expect(written(p.writes, 0xC8) == [0x30] && written(p.writes, 0xD8) == [0x10])
    // Voice 0's DMA on, as the player's patch turns it on.
    #expect(written(p.writes, 0x96).contains(0x8201))
    // The song's end, as every voice's list comes to its end.
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
    #expect(p.tickClocks == (0x376B + 1) * 5)

    // Advanced Ski Simulator's ticks, twice as fast.
    var fast = try SteveBarrettPlayer(sbModule(fast: true))
    _ = fast.run(&out)
    _ = fast.run(&out)
    #expect(fast.tickClocks == (0x376B / 2 + 1) * 5)
}

// MARK: Rob Hubbard

/// A module of Rob Hubbard's: five branches and the words the player checks; a sample, two songs and a
/// command $85 between them (which the player makes $84); a start that writes the song's number to AUD1PER,
/// sets its audio interrupt going (which the player leaves out), and gives a voice an empty sample (which the
/// player makes its eight bytes of nought); and a tick that writes a note's sample, length and volume as his
/// code of 1989 does, and takes each voice's next pattern from a list that ends at its third.
private func rhModule() -> RawModule {
    var p = RawModule()
    for routine in ["play", "init", "end", "end", "end"] {
        p.w(0x6000)
        p.to(routine)
    }
    p.w(0x41FA)
    p.to("end")
    p.w(0x4E71, 0x4E71, 0x4E75, 0x41FA)
    p.to("end")
    p.pad(to: 54)
    p.w(0x41FA)
    p.to("samples") // (54) LEA samples(PC),A0
    p.pad(to: 64)
    p.w(0x7000, 0x2418) // (64) MOVEQ #0,D0; MOVE.L (A0)+,D2: one sample
    p.pad(to: 130)
    p.w(0x41EB)
    p.offset("songs") // (130) LEA songs(A3),A0
    p.label("init")
    p.w(0x41FA, 0x000C, 0x21C8, 0x0070) // LEA *+14(PC),A0; MOVE.L A0,$70.W
    p.w(0x33C0, 0x00DF, 0xF0B6) // MOVE.W D0,$DFF0B6
    for v in 0 ..< 4 {
        p.w(0x41FA)
        p.to("record\(v)")
        p.w(0x43FA)
        p.to("list")
        p.w(0x2149, 0x0008, 0x2149, 0x0004) // MOVE.L A1,8(A0); MOVE.L A1,4(A0)
    }
    p.w(0x4BFA)
    p.to("note")
    p.w(0x41FA)
    p.to("sample")
    p.w(0x2A88, 0x43FA) // MOVE.L A0,(A5); LEA record0(PC),A1
    p.to("record0")
    p.w(0x41FA)
    p.to("list")
    p.w(0x2348, 0x0008, 0x237C, 0x0000, 0x0004, 0x000C) // MOVE.L A0,8(A1); MOVE.L #4,12(A1)
    p.label("end")
    p.w(0x4E75)
    p.label("play")
    p.w(0x4DF9, 0x00DF, 0xF000, 0x4BFA) // LEA $DFF000,A6; LEA note(PC),A5
    p.to("note")
    p.w(0x2D6D, 0x0000, 0x00A0, 0x3D6D, 0x0008, 0x00A4, 0x3D6D, 0x000E, 0x00A8)
    for v in 0 ..< 4 {
        p.w(0x4DF9, 0x00DF, 0xF000 + UInt16(v * 16), 0x41FA) // LEA $DFF0v0,A6; LEA record(PC),A0
        p.to("record\(v)")
        p.w(0x2468, 0x0004, 0x4A92, 0x6606, 0x2468, 0x0008, 0x7004, 0x2252) // MOVEA.L 4(A0),A2; (the pattern)
        p.w(0x588A, 0x214A, 0x0004) // ADDQ.L #4,A2; MOVE.L A2,4(A0)
    }
    p.w(0x4E75)
    p.label("songs")
    for _ in 0 ..< 2 {
        p.w(1)
        for _ in 0 ..< 4 {
            p.w(0)
            p.offset("list")
        }
    }
    p.w(0)
    p.label("command")
    p.w(0x8500)
    p.label("samples")
    p.long(4)
    p.w(0)
    p.label("sample")
    p.long(0)
    p.w(0x4E71)
    p.label("note")
    p.long(0)
    p.long(0)
    p.w(4, 0, 0, 0x0123)
    p.label("list")
    p.long(1)
    p.long(1)
    p.long(0)
    for v in 0 ..< 4 {
        p.label("record\(v)")
        for _ in 0 ..< 16 { p.w(0) }
    }
    return p
}

@Test func robHubbardModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let module = rhModule()
    let file = module.bytes()
    #expect(RobHubbard.isOne(file))
    #expect(!SteveBarrett.isOne(file) && !RobHubbardST.isOne(file) && !FredMonitor.isOne(file))
    var p = try RobHubbardPlayer(file, song: 1)
    #expect(p.songCount == 2)
    #expect(written(p.startWrites, 0xB6).last == 1)
    // The audio interrupt not set going, the command made $84, the empty sample the player's.
    let interrupt = 0xF000 + module.at("init") + 14
    #expect(Int(p.memory[0x70]) << 24 | Int(p.memory[0x71]) << 16 | Int(p.memory[0x72]) << 8 | Int(p.memory[0x73]) != interrupt)
    let record0 = 0xF000 + module.at("record0")
    #expect(p.memory[record0 + 24] == 0 && p.memory[record0 + 25] == 0 && p.memory[record0 + 26] == 0xD9 && p.memory[record0 + 27] == 0x04)
    #expect(p.memory[0xF000 + module.at("command")] == 0x84)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The note's volume, seven bits of it, through the player's patch; its sample's start and length.
    #expect(written(p.writes, 0xA8) == [0x23])
    #expect(written(p.writes, 0xA4) == [4])
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
}

// MARK: Rob Hubbard on Steve Bak's replayer

/// A module of Rob Hubbard's for Steve Bak's replayer: the longs the player checks; a tick after the first
/// RTS from the 180th byte that counts its ticks in the module's variables (A5), reads a command that is
/// $8E (the song's end) at the third, and writes voice 0's volume and period as the code writes them; a
/// routine that stops it after a word $DFFC (ending in MOVE.W (SP)+,SR, which the player takes out); a
/// start that changes the processor's status (which the player takes out: it would fault), writes the
/// song's number to AUD1PER and sets a voice going; one song; and what else the player looks for.
private func rhoModule() -> [UInt8] {
    var p = RawModule()
    p.long(0x0040_7F40)
    p.long(0x00C0_81C0)
    p.pad(to: 56)
    p.w(0x41FA, 0xFFEE)
    p.pad(to: 180)
    p.w(0x4E75)
    // The tick.
    p.w(0x5255, 0x7001, 0x0C55, 0x0003, 0x6602, 0x708E) // ADDQ.W #1,(A5); MOVEQ #1,D0; CMPI.W #3,(A5); BNE.S +2; MOVEQ #$8E,D0
    p.w(0x0280, 0x0000, 0x003F) // ANDI.L #$3F,D0
    p.w(0x303C, 0x0030, 0x33C0, 0x00DF, 0xF0A8) // MOVE.W #$30,D0; MOVE.W D0,$DFF0A8
    p.w(0x303C, 0x0100, 0x33C0, 0x00DF, 0xF0A6, 0x4E75) // MOVE.W #$100,D0; MOVE.W D0,$DFF0A6; RTS
    // The stop.
    p.w(0xDFFC, 0x0000, 0x0000, 0x46DF, 0x4E75) // ADDA.L #0,A7; MOVE.W (SP)+,SR; RTS
    // The start.
    p.w(0x40E7, 0x46FC, 0x2700) // MOVE.W SR,-(SP); MOVE.W #$2700,SR
    p.w(0x7E02, 0x41FA) // MOVEQ #2,D7; LEA songs(PC),A0
    p.to("songs")
    p.w(0x33C0, 0x00DF, 0xF0B6, 0x224D, 0x234A, 0x0008, 0x337C, 0x0001, 0x0028, 0x4E75) // MOVE.W D0,$DFF0B6; MOVEA.L A5,A1; MOVE.L A2,8(A1); MOVE.W #1,$28(A1); RTS
    // InitSound's displacement, and the branches the player changes.
    p.w(0x0000, 0x0010, 0x0000, 0x0000, 0x0829, 0x0003, 0x0000, 0x0000, 0x0000)
    // The table of instruments, from the displacement before ASL.W #2,D0; ADDA.L d(A0,D0.W),A0.
    p.to("tableOffset")
    p.w(0xE548, 0xD1F0)
    p.label("tableOffset")
    p.long(8)
    p.long(0)
    p.label("songs")
    p.long(12)
    p.long(12)
    p.long(12)
    p.long(1)
    p.long(0)
    return p.bytes()
}

@Test func robHubbardSTModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = rhoModule()
    #expect(RobHubbardST.isOne(file))
    #expect(!SteveBarrett.isOne(file) && !RobHubbard.isOne(file) && !FredMonitor.isOne(file))
    var p = try RobHubbardSTPlayer(file)
    #expect(p.songCount == 1)
    #expect(written(p.startWrites, 0xB6).last == 0)
    // The byte InitSound sets, at the module's displacement in the module's variables.
    #expect(p.memory[Int(RobHubbardST.buffer) + 0x10] == 0xFF)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(p.failure == nil)
    #expect(written(p.writes, 0xA8) == [0x30] && written(p.writes, 0xA6) == [0x100])
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
}

// MARK: Fred Monitor

/// A module of Frederic Hahn's: four JMPs, and the words after them, as the player checks them; two songs
/// (its last's number a byte the start reads); a start that writes the song's number to AUD0PER; a stop
/// that sets the module's byte that says it has stopped; and a tick that does nothing once it has, and
/// otherwise, in the first song, takes three voices' lists' jumps at its second and the fourth's at its
/// third, and in the second stops at its second.
private func fredModule() -> [UInt8] {
    var p = RawModule()
    for (k, target) in [0x12, 0xAA, 0x98, 0x8A].enumerated() { p.w(0x4EFA, UInt16(target - (k * 4 + 2))) }
    p.w(0x0F00)
    // (0x12) The start.
    p.w(0x123A)
    p.to("last") // MOVE.B last(PC),D1
    p.w(0xB001, 0x6200)
    p.to("stop") // CMP.B D1,D0; BHI.W stop
    p.w(0x47FA)
    p.to("song")
    p.w(0x1680, 0x33C0, 0x00DF, 0xF0A6) // LEA song(PC),A3; MOVE.B D0,(A3); MOVE.W D0,$DFF0A6
    p.w(0x47FA)
    p.to("count")
    p.w(0x4253, 0x4E75) // LEA count(PC),A3; CLR.W (A3); RTS
    p.pad(to: 0x8A)
    p.w(0x4E75)
    p.pad(to: 0x98)
    p.label("stop")
    p.w(0x47FA)
    p.to("stopped")
    p.w(0x16BC, 0x00FF, 0x4E75) // LEA stopped(PC),A3; MOVE.B #$FF,(A3); RTS
    p.pad(to: 0xAA)
    // The tick.
    p.w(0x47FA)
    p.to("stopped")
    p.w(0x4A13, 0x6702, 0x4E75) // LEA stopped(PC),A3; TST.B (A3); BEQ.S +2; RTS
    p.w(0x47FA)
    p.to("count")
    p.w(0x5253, 0x3013, 0x47FA) // LEA count(PC),A3; ADDQ.W #1,(A3); MOVE.W (A3),D0; LEA song(PC),A3
    p.to("song")
    p.w(0x4A13, 0x6600)
    p.to("second") // TST.B (A3); BNE.W second
    let jump: [UInt16] = [0x343C, 0x8000, 0x0882, 0x000F, 0x3002, 0x0280, 0x0000, 0xFFFF] // MOVE.W #$8000,D2; (the jump)
    p.w(0x0C40, 0x0002, 0x6600)
    p.to("third") // CMPI.W #2,D0; BNE.W third
    for v in [3, 2, 1] as [UInt16] {
        p.w(0x7A00 | v)
        p.w(jump)
    }
    p.w(0x4E75)
    p.label("third")
    p.w(0x0C40, 0x0003, 0x6600)
    p.to("return")
    p.w(0x7A00)
    p.w(jump)
    p.label("return")
    p.w(0x4E75)
    p.label("second")
    p.w(0x0C40, 0x0002, 0x6600)
    p.to("return")
    p.w(0x47FA)
    p.to("stopped")
    p.w(0x50D3, 0x4E75) // LEA stopped(PC),A3; ST (A3); RTS
    p.label("last")
    p.w(0x0100)
    p.label("song")
    p.w(0)
    p.label("stopped")
    p.w(0)
    p.label("count")
    p.w(0)
    return p.bytes()
}

@Test func fredMonitorModulesArePlayedAsUADEsPlayerPlaysThem() throws {
    let file = fredModule()
    #expect(FredMonitor.isOne(file))
    #expect(!SteveBarrett.isOne(file) && !RobHubbard.isOne(file) && !RobHubbardST.isOne(file))
    var out = Silent()
    // The first song ends once every voice has come to its list's jump.
    var p = try FredMonitorPlayer(file)
    #expect(p.songCount == 2)
    #expect(written(p.startWrites, 0xA6).last == 0)
    _ = p.run(&out)
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
    // The second as the module stops itself, said once.
    var q = try FredMonitorPlayer(file, song: 1)
    #expect(written(q.startWrites, 0xA6).last == 1)
    _ = q.run(&out)
    _ = q.run(&out)
    #expect(q.endings == 0)
    _ = q.run(&out)
    #expect(q.endings == 1)
    for _ in 0 ..< 5 { _ = q.run(&out) }
    #expect(q.endings == 1)
}

// MARK: Damage

/// Cut and changed copies of a module, which its player must refuse or play without trapping or hanging.
private func damage<R: WantedTeamRecipe>(_: R.Type, _ file: [UInt8]) {
    for cut in stride(from: 0, to: file.count, by: 15) {
        _ = try? WantedTeamPlayer<R>(Array(file.prefix(cut)))
    }
    var seed: UInt32 = 2026
    for _ in 0 ..< 15 {
        var damaged = file
        for _ in 0 ..< 4 {
            seed = seed &* 1_103_515_245 &+ 12345
            damaged[Int(seed >> 8) % damaged.count] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        var out = Silent()
        if var p = try? WantedTeamPlayer<R>(damaged) { for _ in 0 ..< 10 { _ = p.run(&out) } }
    }
}

@Test func steveBarrettModulesThatAreDamagedNeverTrapOrHang() { damage(SteveBarrett.self, sbModule()) }
@Test func robHubbardModulesThatAreDamagedNeverTrapOrHang() { damage(RobHubbard.self, rhModule().bytes()) }
@Test func robHubbardSTModulesThatAreDamagedNeverTrapOrHang() { damage(RobHubbardST.self, rhoModule()) }
@Test func fredMonitorModulesThatAreDamagedNeverTrapOrHang() { damage(FredMonitor.self, fredModule()) }
