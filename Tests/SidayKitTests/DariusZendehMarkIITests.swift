// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Darius Zendeh's modules and the Mark II Sound System's, played on Wanted Team's recipe,
// on tiny modules assembled here by hand: each begins as the player's check wants it to, takes its
// commands in its registers as the player gives them, and ends its songs as the player (or, where it
// has none, siday) has them end. The thorough check is made outside the package: what every one of
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

/// A tick of the host's timer, in Paula's clocks.
private let tick = (0x376B + 1) * 5

/// A module of Darius Zendeh's of the first kind (R-Type's levels): four songs (its `CMPI.B #1,D4`
/// says one more than the three every such module has). Its songs played once (0 and 3) start by D4 =
/// `n << 8 | $FF`, writing n to AUD0PER, and their ticks (D4 2) count up in AUD0VOL, the third saying
/// in D4 that the song is over; its short songs (1 and 2) start by D3 -1, writing D1 to AUD1PER, and
/// their ticks (D3 2) count up in AUD1VOL, the third setting the module's word for the end of its
/// music and starting again.
private func levelsModule() -> [UInt8] {
    var a = AmigaAssembly(at: 0)
    let keep = a.label(), count = a.label(), flag = a.label()
    let short = a.label(), once = a.label(), test = a.label(), tick2 = a.label(), out = a.label()
    a.w(0x48E7, 0x00F0, 0x41FA) // MOVEM.L A0-A3,-(A7); LEA keep(PC),A0
    a.displacement(to: keep)
    a.w(0x4CD8, 0x0600, 0x4A44) // MOVEM.L (A0)+,A1/A2; TST.W D4
    a.branch(0x6700, to: short) // BEQ.S short
    a.w(0x7000, 0x1004, 0xE04C, 0x0C00, 0x00FF) // MOVEQ #0,D0; MOVE.B D4,D0; LSR.W #8,D4; CMPI.B #$FF,D0
    a.branch(0x6600, to: once) // BNE.S once
    a.w(0x0C04, 0x0001, 0x6604, 0x41FA, 0x0000) // CMPI.B #1,D4; BNE.S +4; LEA (PC),A0 (the songs' count)
    a.w(0x33C4, 0x00DF, 0xF0A6, 0x41FA) // MOVE.W D4,$DFF0A6; LEA count(PC),A0
    a.displacement(to: count)
    a.w(0x4250, 0x41FA) // CLR.W (A0); LEA flag(PC),A0
    a.displacement(to: flag)
    a.w(0x4250, 0x7000, 0x33FC, 0x000F, 0x00DF, 0xF096, 0x41FA) // CLR.W (A0); MOVEQ #0,D0; MOVE.W #$F,$DFF096; LEA
    a.displacement(to: count)
    a.branch(0x6000, to: out)
    a.place(once)
    a.w(0x41FA)
    a.displacement(to: count) // LEA count(PC),A0
    a.w(0x5250, 0x33D0, 0x00DF, 0xF0A8, 0x0C50, 0x0003) // ADDQ.W #1,(A0); MOVE.W (A0),$DFF0A8; CMPI.W #3,(A0)
    a.branch(0x6600, to: test)
    a.w(0x41FA)
    a.displacement(to: flag)
    a.w(0x30BC, 0x0001) // LEA flag(PC),A0; MOVE.W #1,(A0)
    a.place(test)
    a.w(0x7800, 0x41FA) // MOVEQ #0,D4; LEA flag(PC),A0; CMPI.W #1,(A0)
    a.displacement(to: flag)
    a.w(0x0C50, 0x0001)
    a.branch(0x6600, to: out)
    a.w(0x78FF) // MOVEQ #-1,D4
    a.branch(0x6000, to: out)
    a.place(short)
    a.w(0x4A03)
    a.branch(0x6700, to: out) // TST.B D3; BEQ.S out
    a.w(0x0C03, 0x00FF)
    a.branch(0x6600, to: tick2) // CMPI.B #$FF,D3; BNE.S
    a.w(0x33C1, 0x00DF, 0xF0B6, 0x41FA) // MOVE.W D1,$DFF0B6; LEA count(PC),A0; CLR.W (A0)
    a.displacement(to: count)
    a.w(0x4250)
    a.branch(0x6000, to: out)
    a.place(tick2)
    a.w(0x41FA)
    a.displacement(to: count)
    a.w(0x5250, 0x33D0, 0x00DF, 0xF0B8, 0x0C50, 0x0003) // ADDQ.W #1,(A0); MOVE.W (A0),$DFF0B8; CMPI.W #3,(A0)
    a.branch(0x6600, to: out)
    a.w(0x4250, 0x41FA) // CLR.W (A0); LEA flag(PC),A0; MOVE.W #1,(A0)
    a.displacement(to: flag)
    a.w(0x30BC, 0x0001)
    a.place(out)
    a.w(0x4CDF, 0x0F00, 0x4E75) // MOVEM.L (A7)+,A0-A3; RTS
    a.place(keep)
    a.long(0)
    a.long(0)
    a.place(count)
    a.w(0)
    a.place(flag)
    a.w(0)
    return a.assembled()
}

@Test func dariusZendehLevelsArePlayedAsTheirPlayerPlaysThem() throws {
    let file = levelsModule()
    #expect(DariusZendeh.kind(file) == .levels && !MarkII.isOne(file))
    var out = Silent()
    // A song played once: started, its ticks counted, and stopped (silent) as the module says it is over.
    for (song, table) in [(0, UInt16(0)), (3, 1)] {
        var p = try DariusZendehPlayer(file, song: song)
        #expect(p.songCount == 4)
        #expect(written(p.startWrites, 0xA6).last == table)
        _ = p.run(&out)
        var counts: [UInt16] = []
        for _ in 0 ..< 3 {
            _ = p.run(&out)
            counts += written(p.writes, 0xA8)
        }
        #expect(counts == [1, 2, 3] && p.endings == 1)
        _ = p.run(&out)
        #expect(written(p.writes, 0xA8).isEmpty && p.endings == 1)
        #expect(abs(Int(p.lengthClocks ?? 0) - 3 * tick) < 400)
    }
    // A short song, D1 nought or one, which goes round: its end said each time the module comes to the
    // end of its music.
    for song in [1, 2] {
        var p = try DariusZendehPlayer(file, song: song)
        #expect(written(p.startWrites, 0xB6).last == UInt16(song - 1))
        _ = p.run(&out)
        var counts: [UInt16] = []
        for _ in 0 ..< 6 {
            _ = p.run(&out)
            counts += written(p.writes, 0xB8)
        }
        #expect(counts == [1, 2, 3, 1, 2, 3] && p.endings == 2)
        #expect(abs(Int(p.lengthClocks ?? 0) - 3 * tick) < 400)
    }
}

/// A module of Darius Zendeh's of the strange kind (Katakis and Denaris): one song of three rows, which
/// it writes to AUD0PER, its place in them kept in the two longs its first LEA points at, and started
/// again after the third.
private func strangeModule() -> [UInt8] {
    var a = AmigaAssembly(at: 0)
    let keep = a.label(), kept = a.label(), music = a.label(), start = a.label(), row = a.label()
    a.w(0x48E7, 0x78F0, 0x41FA) // MOVEM.L D1-D4/A0-A3,-(A7); LEA keep(PC),A0
    a.displacement(to: keep)
    a.w(0x4CD8, 0x0600, 0x0C00, 0x00FF) // MOVEM.L (A0)+,A1/A2; CMPI.B #$FF,D0
    a.branch(0x6700, to: start) // BEQ.S start
    a.w(0x0C11, 0x00FF)
    a.branch(0x6600, to: row) // CMPI.B #$FF,(A1); BNE.S row
    a.place(start)
    a.w(0x43FA)
    a.displacement(to: music) // LEA music(PC),A1
    a.place(row)
    a.w(0x7000, 0x1011, 0x33C0, 0x00DF, 0xF0A6, 0x5049) // MOVEQ #0,D0; MOVE.B (A1),D0; MOVE.W D0,$DFF0A6; ADDQ.W #8,A1
    a.w(0x41FA)
    a.displacement(to: kept) // LEA keep+8(PC),A0
    a.w(0x48E0, 0x0060, 0x4CDF, 0x0F1E, 0x4E75) // MOVEM.L A1/A2,-(A0); MOVEM.L (A7)+,D1-D4/A0-A3; RTS
    a.place(keep)
    a.long(0)
    a.long(0)
    a.place(kept)
    a.place(music)
    for value: UInt16 in [0x0100, 0x0200, 0x0300, 0xFF00] { a.w(value, 0, 0, 0) }
    return a.assembled()
}

@Test func dariusZendehStrangeModulesEndWhereTheirMusicBeginsAgain() throws {
    let file = strangeModule()
    #expect(DariusZendeh.kind(file) == .strange && !MarkII.isOne(file))
    var p = try DariusZendehPlayer(file)
    #expect(p.songCount == 1)
    #expect(written(p.startWrites, 0xA6).last == 1)
    var out = Silent()
    _ = p.run(&out)
    var rows: [UInt16] = []
    var endings: [Int] = []
    for _ in 0 ..< 6 {
        _ = p.run(&out)
        rows += written(p.writes, 0xA6)
        endings.append(p.endings)
    }
    #expect(rows == [2, 3, 1, 2, 3, 1])
    #expect(endings == [0, 0, 1, 1, 1, 2])
    #expect(abs(Int(p.lengthClocks ?? 0) - 3 * tick) < 400)
}

/// A module of the Mark II Sound System's, of the second kind the player knows: its code at the six
/// places the player patches as that kind has it (and the check's `ASL.W #3,D2` and LEA before the
/// first), the rest nought. Its start (D0 -1) writes $100 to AUD0PER and D1 to AUD1PER; each tick (D0
/// nought) writes a volume of $B0 to AUD0VOL at $304 (which the player's patch makes seven bits of it,
/// through the voice's full volume), and the third goes to $144, the start of its music again, where it
/// clears a word (which the player's patch makes the song's end, and the word four bytes on cleared).
private func markIIModule() -> [UInt8] {
    var words = [UInt16](repeating: 0, count: 0x200)
    func put(_ at: Int, _ values: [UInt16]) {
        for (i, value) in values.enumerated() { words[at / 2 + i] = value }
    }
    put(0x000, [0x48E7, 0x00F0, 0x41FA, 0x035A, 0x4CD8, 0x0600]) // MOVEM.L A0-A3,-(A7); LEA $360(PC),A0; MOVEM.L (A0)+,A1/A2
    put(0x00C, [0x4A00, 0x6B10]) // TST.B D0; BMI.S $20
    put(0x010, [0x47F9, 0x00DF, 0xF0A0, 0x343C, 0x00B0, 0x4EFA, 0x02E8]) // LEA $DFF0A0,A3; MOVE.W #$B0,D2; JMP $304(PC)
    put(0x020, [0x33FC, 0x0100, 0x00DF, 0xF0A6, 0x33C1, 0x00DF, 0xF0B6]) // MOVE.W #$100,$DFF0A6; MOVE.W D1,$DFF0B6
    put(0x02E, [0x4CDF, 0x0F00, 0x4E75]) // MOVEM.L (A7)+,A0-A3; RTS
    put(0x0FE, [0xE341, 0x36B1, 0x1000])
    put(0x144, [0x41FA, 0x020A, 0x4250, 0x6000, 0xFEE2]) // LEA $350(PC),A0; CLR.W (A0); BRA.W $2E
    put(0x1DA, [0xE742, 0x41FA, 0x0000, 0x3770, 0x2006, 0x0004])
    put(0x1F4, [0x2688, 0x0C01, 0x0032])
    put(0x258, [0x3741, 0x0006, 0x7400])
    put(0x304, [0x3742, 0x0008, 0x5449, 0x41FA, 0x0064, 0x5250]) // MOVE.W D2,8(A3); ADDQ.W #2,A1; LEA $370(PC),A0; ADDQ.W #1,(A0)
    put(0x310, [0x0C50, 0x0003, 0x6600, 0xFD18, 0x4250, 0x6000, 0xFE28]) // CMPI.W #3,(A0); BNE.W $2E; CLR.W (A0); BRA.W $144
    put(0x350, [0xFFFF, 0, 0x00C0])
    return words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
}

@Test func markIIModulesArePlayedAsTheirPlayerPlaysThem() throws {
    let file = markIIModule()
    #expect(MarkII.isOne(file) && !DariusZendeh.isOne(file))
    var p = try MarkIIPlayer(file)
    #expect(p.songCount == 1 && p.tuneInfo.format == "Mark II")
    #expect(written(p.startWrites, 0xA6).last == 0x100 && written(p.startWrites, 0xB6).last == 0)
    var out = Silent()
    _ = p.run(&out)
    var volumes: [UInt16] = []
    for _ in 0 ..< 3 {
        _ = p.run(&out)
        volumes += written(p.writes, 0xA8)
    }
    #expect(volumes == [0x30, 0x30, 0x30] && p.endings == 1)
    // (The word the module clears kept, and the one four bytes on cleared.)
    let module = Int(MarkII.moduleAt)
    #expect(p.memory[module + 0x350] == 0xFF && p.memory[module + 0x355] == 0)
    #expect(abs(Int(p.lengthClocks ?? 0) - 3 * tick) < 400)
}

@Test func dariusZendehAndMarkIIRefuseWhatIsNotTheirs() {
    var bytes = [UInt8](repeating: 0, count: 0x400)
    #expect(!DariusZendeh.isOne(bytes) && !MarkII.isOne(bytes))
    #expect(throws: TuneError.self) { _ = try DariusZendehPlayer(bytes) }
    #expect(throws: TuneError.self) { _ = try MarkIIPlayer(bytes) }
    // Cut short, the first kind's module is not one without the instructions its check looks for.
    bytes = Array(levelsModule().prefix(12))
    #expect(!DariusZendeh.isOne(bytes) && !MarkII.isOne(bytes))
    #expect(!MarkII.isOne(Array(markIIModule().prefix(0x1E0))))
}

/// Copies cut short, and with bytes changed past their first instructions, played a little: they are
/// refused or played, never trapping or hanging.
private func damage<R: WantedTeamRecipe>(_: R.Type, _ file: [UInt8], every: Int) {
    for cut in stride(from: 0, to: file.count, by: every) {
        _ = try? WantedTeamPlayer<R>(Array(file.prefix(cut)))
    }
    var seed: UInt32 = 2026
    for _ in 0 ..< 10 {
        var damaged = file
        for _ in 0 ..< 4 {
            seed = seed &* 1_103_515_245 &+ 12345
            damaged[16 + Int(seed >> 8) % (damaged.count - 16)] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        var out = Silent()
        if var p = try? WantedTeamPlayer<R>(damaged) { for _ in 0 ..< 10 { _ = p.run(&out) } }
    }
}

@Test func dariusZendehAndMarkIIModulesThatAreDamagedNeverTrapOrHang() {
    damage(DariusZendeh.self, levelsModule(), every: 16)
    damage(DariusZendeh.self, strangeModule(), every: 16)
    damage(MarkII.self, markIIModule(), every: 64)
}
