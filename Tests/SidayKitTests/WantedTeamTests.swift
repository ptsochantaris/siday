// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
import Testing

// Fast checks of Wanted Team's recipe (`WantedTeamPlayer`) and the formats played by it, on tiny modules
// assembled here by hand: each laid out with the standard header its player looks for, its code
// changed as the player changes it, and its songs ending as the player has them end. The thorough check
// is made outside the package: what every one of UnExoticA's modules writes to Paula, tick by tick and
// song by song, against what it writes in UADE.

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

/// A standard header: MOVEQ #-1,D0; RTS; the ID; then the longs, each a label's address or a number.
private func header(_ p: inout HunkProgram, id: String, _ longs: [String?], counts: [Int: UInt32] = [:]) {
    p.w(0x70FF, 0x4E75)
    let bytes = Array(id.utf8)
    for i in stride(from: 0, to: 8, by: 2) { p.w(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])) }
    for (i, field) in longs.enumerated() {
        if let field { p.address(field) } else { p.long(counts[i] ?? 0) }
    }
}

private func names(_ p: inout HunkProgram) {
    p.label("name")
    p.w(0x536F, 0x6E67, 0x0000) // "Song"
    p.label("author")
    p.w(0x4D65, 0x0000) // "Me"
}

/// A module of Core Design's: three songs; a start that writes the song's number to AUD1PER and its
/// D1 to AUD2PER, and reads the song's number as his drivers do (which the player's patch takes for
/// the song's end, but not while it starts); a tick that writes a volume of $50 halved (as his drivers
/// write volumes, which the player's patch turns down by the balance, here none), and on its third
/// reads the song's number again; and an audio interrupt that ends with RTE (which the player makes
/// an RTS).
private func coreModule() -> [UInt8] {
    var p = HunkProgram()
    header(&p, id: "S.PHIPPS", ["play", "audio", "init", "end", nil, nil, nil, "name", "author", nil, nil, nil, nil, nil, nil],
           counts: [4: 3])
    p.label("end")
    p.w(0x4E75)
    p.label("audio")
    p.w(0x4E73) // RTE
    p.label("init")
    p.w(0x33C0, 0x00DF, 0xF0B6, 0x33C1, 0x00DF, 0xF0C6) // MOVE.W D0,$DFF0B6; MOVE.W D1,$DFF0C6
    p.w(0x7400, 0x1400, 0xE742, 0x4E75) // MOVEQ #0,D2; MOVE.B D0,D2; ASL.W #3,D2; RTS
    p.label("play")
    p.w(0x49F9, 0x00DF, 0xF000) // LEA $DFF000,A4
    p.w(0x303C, 0x0050, 0xE248, 0x3940, 0x00A8) // MOVE.W #$50,D0; LSR.W #1,D0; MOVE.W D0,$A8(A4)
    p.w(0x5279)
    p.address("count") // ADDQ.W #1,count
    p.w(0x0C79, 0x0003)
    p.address("count") // CMPI.W #3,count
    p.w(0x6606) // BNE.S +6
    p.w(0x7400, 0x1400, 0xE742) // MOVEQ #0,D2; MOVE.B D0,D2; ASL.W #3,D2
    p.w(0x4E75)
    p.long(0x3BC0_3865) // (where the player's search ends)
    p.label("count")
    p.w(0)
    names(&p)
    return p.file()
}

@Test func coreDesignModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = coreModule()
    #expect(CoreDesign.isOne(file))
    #expect(!JankoMrsicFlogel.isOne(file) && !DaglishSID.isOne(file) && !DaveLoweCodePlayer.isOne(file))
    var p = try CoreDesignPlayer(file, song: 1)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 3)
    #expect(p.tuneInfo.format == "Core Design" && p.tuneInfo.title == "Song" && p.tuneInfo.author == "Me")
    // The song's number (from nought, as the player numbers them) and D1 one, from its start.
    #expect(written(p.startWrites, 0xB6).last == 1)
    #expect(written(p.startWrites, 0xC6).last == 1)
    // (The first tick is the time until the host's timer first runs out, the player's first call.)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The volume, halved, through the player's patch.
    #expect(written(p.writes, 0xA8) == [0x28])
    // The song's end, as the tick reads the song's number again (not as it starts).
    #expect(p.endings == 0)
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(p.endings == 1)
    let length = Int(p.lengthClocks ?? 0)
    #expect(abs(length - 3 * (0x376B + 1) * 5) < 5)
}

/// A module of Janko Mrsic-Flogel's: two songs; a start that writes the song's number to AUD1PER; and a
/// tick that writes a voice's wave to AUD0DAT, with and without a length, and to the other two voices'
/// (as his code does, which the player's patches make the voices' starts), a period of $123 to voice 0
/// (which the player's patch follows with a volume of 56), and on its second turns the DMA off (which
/// the player takes for the song's end).
private func jmfModule() -> [UInt8] {
    var p = HunkProgram()
    header(&p, id: "J.FLOGEL", ["play", "init", nil, nil, "name", "author", nil, nil, nil, nil], counts: [2: 2])
    p.label("init")
    p.w(0x33C0, 0x00DF, 0xF0B6, 0x4E75) // MOVE.W D0,$DFF0B6; RTS
    p.label("play")
    for (wave, register) in [("waveA", UInt16(0xF0AA)), ("waveB", 0xF0AA), ("waveC", 0xF0BA), ("waveC", 0xF0BA),
                             ("waveD", 0xF0CA), ("waveD", 0xF0CA)]
    {
        p.w(0x23FC)
        p.address(wave)
        p.w(0x00DF, register) // MOVE.L #wave,$DFF0xA
        if wave == "waveA" { p.w(0x33FC, 0x0010, 0x00DF, 0xF0A4) } // MOVE.W #$10,$DFF0A4
    }
    p.w(0x323C, 0x0123, 0x33C1, 0x00DF, 0xF0A6) // MOVE.W #$123,D1; MOVE.W D1,$DFF0A6
    p.w(0x5279)
    p.address("count") // ADDQ.W #1,count
    p.w(0x0C79, 0x0002)
    p.address("count") // CMPI.W #2,count
    p.w(0x6608) // BNE.S +8
    p.w(0x33FC, 0x000F, 0x00DF, 0xF096) // MOVE.W #15,$DFF096
    p.w(0x4E75)
    p.label("count")
    p.w(0)
    for wave in ["waveA", "waveB", "waveC", "waveD"] {
        p.label(wave)
        p.long(0)
    }
    names(&p)
    return p.file()
}

@Test func jankoMrsicFlogelModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = jmfModule()
    #expect(JankoMrsicFlogel.isOne(file) && !CoreDesign.isOne(file))
    var p = try JankoMrsicFlogelPlayer(file, song: 1)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Janko Mrsic-Flogel" && p.tuneInfo.title == "Song")
    #expect(written(p.startWrites, 0xB6).last == 1)
    // (The first tick is the time until the host's timer first runs out, the player's first call.)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // Each wave given to AUDxDAT made the voice's start (its low word the wave's, as LoadSeg put it).
    #expect(written(p.writes, 0xA0).count == 2 && written(p.writes, 0xB0).count == 2 && written(p.writes, 0xC0).count == 2)
    #expect(written(p.writes, 0xAA).isEmpty)
    #expect(written(p.writes, 0xA4) == [0x10])
    // The period, and the volume of 56 after it.
    #expect(written(p.writes, 0xA6) == [0x123])
    #expect(written(p.writes, 0xA8) == [56])
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
}

/// A module of Benn Daglish's SID-like music: two songs; a start that writes the song's number to
/// AUD1PER and leaves A4 at a block whose byte $11 is set; a tick that sets voice 0's wave and length
/// (as his code does, through A5 at $DFF000), waits for the DMA with a DBRA on itself (which the
/// player's patch makes eight lines of the beam), and on its second clears the byte (which the player
/// takes for the song's end, and starts it again); and an audio interrupt that reads a volume and ends
/// with RTE.
private func bdsModule() -> [UInt8] {
    var p = HunkProgram()
    header(&p, id: "DAGLISH!", ["play", "audio", "init", nil, "name", "author", nil, nil, nil, nil, nil, nil], counts: [3: 2])
    p.label("audio")
    p.w(0x1239)
    p.address("volume") // MOVE.B volume,D1
    p.w(0x4E73) // RTE
    p.label("init")
    p.w(0x33C0, 0x00DF, 0xF0B6) // MOVE.W D0,$DFF0B6
    p.w(0x49F9)
    p.address("block") // LEA block,A4
    p.w(0x197C, 0x0001, 0x0011, 0x4279) // MOVE.B #1,$11(A4); CLR.W count
    p.address("count")
    p.w(0x4E75)
    p.label("play")
    p.w(0x4BF9, 0x00DF, 0xF000) // LEA $DFF000,A5
    p.w(0x283C, 0x0000, 0x2000, 0x363C, 0x0040) // MOVE.L #$2000,D4; MOVE.W #$40,D3
    p.w(0x2B44, 0x00A0, 0x3B43, 0x00A4) // MOVE.L D4,$A0(A5); MOVE.W D3,$A4(A5)
    p.w(0x7005, 0x51C8, 0xFFFE, 0x302D, 0x0002) // MOVEQ #5,D0; DBRA D0,*; MOVE.W 2(A5),D0
    p.w(0x5279)
    p.address("count") // ADDQ.W #1,count
    p.w(0x0C79, 0x0002)
    p.address("count") // CMPI.W #2,count
    p.w(0x660A) // BNE.S +10
    p.w(0x49F9)
    p.address("block") // LEA block,A4
    p.w(0x422C, 0x0011) // CLR.B $11(A4)
    p.w(0x4E75)
    p.label("count")
    p.w(0)
    p.label("volume")
    p.w(0x3F00)
    p.label("block")
    for _ in 0 ..< 16 { p.w(0) }
    names(&p)
    return p.file()
}

@Test func daglishSIDModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = bdsModule()
    #expect(DaglishSID.isOne(file) && !CoreDesign.isOne(file) && !JankoMrsicFlogel.isOne(file))
    var p = try DaglishSIDPlayer(file, song: 1)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Benn Daglish SID" && p.tuneInfo.author == "Me")
    #expect(written(p.startWrites, 0xB6).last == 1)
    // (The first tick is the time until the host's timer first runs out, the player's first call.)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(written(p.writes, 0xA0) == [0] && written(p.writes, 0xA2) == [0x2000] && written(p.writes, 0xA4) == [0x40])
    #expect(p.endings == 0)
    _ = p.run(&out)
    // The song ended, stopped (the voices' DMA off and their volumes nought) and started again.
    #expect(p.endings == 1)
    #expect(written(p.writes, 0x96).contains(15))
    #expect(written(p.writes, 0xB6).last == 1)
    #expect(p.lengthClocks != nil)
}

@Test func wantedTeamsPatchesAndSearchesAreAsTheirPlayersMakeThem() throws {
    var host = try DeliTrackerHost(moduleAt: 0xF000, module: [0x4E, 0x71, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0x12, 0x34, 0x4E, 0x75])
    try host.prepare()
    var a = AmigaAssembly(at: DeliTrackerHost.clientCode)
    var patches = WantedTeamPatches()
    let patch = a.placed()
    a.w(0x4E75)
    patches.add([0x1234, 0x5678, 0x9ABC], patch: patch)
    patches.assemble(&a)
    host.machine.load(a.assembled(), at: DeliTrackerHost.clientCode)
    #expect(WantedTeamSearch.find(host, long: 0x1234_5678, from: 0xF000, most: 10) == 0xF002)
    #expect(WantedTeamSearch.find(host, [0x4E75], from: 0xF000, most: 10) == nil)
    patches.apply(&host, from: 0xF000, length: 12)
    // The pattern made a JSR to the patch (a part of it alone left as it is).
    #expect(host.machine.peek16(0xF002) == 0x4EB9 && host.machine.peek32(0xF004) == DeliTrackerHost.clientCode)
    #expect(host.machine.peek32(0xF008) == 0x1234_4E75)
    #expect(!WantedTeamHeader.isOne(coreModule(), id: Array("S.PHIPPS".utf8), required: [5]))
}

/// A module of Fred Gray's: two songs; a start that writes the song's number to AUD1PER; a tick that sets
/// voice 0's length as his code does (by D3, through A5 at $DFF0A0, which the player's patch tells the
/// scopes of), shuts out interrupts round a change (which the player takes out), and jumps into its
/// table of states by the state in D6 (nought, whose routine the player makes its `SongEnd`).
private func grayModule() -> [UInt8] {
    var p = HunkProgram()
    header(&p, id: "FREDGRAY", ["play", "init", nil, "name", "author", nil, nil, nil, nil], counts: [2: 2])
    p.label("init")
    p.w(0x33C0, 0x00DF, 0xF0B6, 0x4E75) // MOVE.W D0,$DFF0B6; RTS
    p.label("play")
    p.w(0x4BF9, 0x00DF, 0xF0A0, 0x4DF9) // LEA $DFF0A0,A5; LEA bytes,A6
    p.address("bytes")
    p.w(0x7600, 0x7800) // MOVEQ #0,D3; MOVEQ #0,D4
    p.w(0x3BBC, 0x0008, 0x3004, 0x4236, 0x4000) // MOVE.W #8,4(A5,D3.W); CLR.B 0(A6,D4.W)
    p.w(0x7C00, 0x6100, 0x0004, 0x4E75) // MOVEQ #0,D6; BSR.W state; RTS
    p.w(0x41F9)
    p.address("table") // state: LEA table,A0
    p.w(0xE586, 0x2070, 0x6000, 0x4ED0) // ASL.L #2,D6; MOVEA.L 0(A0,D6.W),A0; JMP (A0)
    p.w(0x40E7, 0x4E71, 0x46DF, 0x6602, 0x4E71, 0x4E75) // MOVE.W SR,-(A7); NOP; MOVE.W (A7)+,SR; BNE.S; NOP; RTS
    p.label("table")
    p.address("idle")
    p.label("idle")
    p.w(0x4E75)
    p.label("bytes")
    p.long(0)
    names(&p)
    return p.file()
}

@Test func fredGrayModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = grayModule()
    #expect(FredGray.isOne(file) && !CoreDesign.isOne(file))
    var p = try FredGrayPlayer(file, song: 1)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2 && p.tuneInfo.format == "Fred Gray" && p.tuneInfo.title == "Song")
    #expect(written(p.startWrites, 0xB6).last == 1)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(written(p.writes, 0xA4) == [8])
    // The state of a song that has ended, which says so with every tick.
    #expect(p.endings == 1)
    _ = p.run(&out)
    #expect(p.endings == 2)
    #expect(p.lengthClocks != nil)
}

/// A module of Howie Davies's: two songs; a start that writes the song's number to AUD2PER (through an
/// address in $DF0000, which the player makes $DFF000) and 2 added to nought to AUD3PER (which the
/// player makes 8); a tick that writes a volume of $30 to voice 0 (which the player makes a call of
/// its own routine for volumes), then for each voice comes to the end of its music.
private func hdModule() -> [UInt8] {
    var p = HunkProgram()
    header(&p, id: "H.DAVIES", ["play", "play2", "init", "samples", "samples", "name", "author", nil, nil, nil, nil, nil, "songs"])
    p.label("play")
    p.w(0x4DF9, 0x00DF, 0xF000, 0x303C, 0x0030, 0x3D40, 0x00A8) // LEA $DFF000,A6; MOVE.W #$30,D0; MOVE.W D0,$A8(A6)
    p.w(0x4BF9)
    p.address("words") // LEA words,A5
    for _ in 0 ..< 4 {
        p.w(0x6100)
        p.to("end") // BSR.W end
        p.w(0x4DEE, 0x0010) // LEA 16(A6),A6
    }
    p.label("play2")
    p.w(0x4E75)
    p.label("init")
    p.w(0x33C0, 0x00DF, 0x00C6) // MOVE.W D0,$DF00C6
    p.w(0x7E00, 0x5407, 0x33C7, 0x00DF, 0xF0D6, 0x4E75) // MOVEQ #0,D7; ADDQ.B #2,D7; MOVE.W D7,$DFF0D6; RTS
    p.label("end")
    p.w(0x2B6D, 0x002E, 0x002A, 0x4E75) // MOVE.L 46(A5),42(A5); RTS
    p.long(0x3580_3280) // (where the player's search ends)
    p.label("words")
    for _ in 0 ..< 32 { p.w(0) }
    p.label("samples")
    p.long(0)
    p.label("songs")
    p.address("songsEnd")
    for _ in 0 ..< 7 { p.long(0) }
    p.label("songsEnd")
    names(&p)
    return p.file()
}

@Test func howieDaviesModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = hdModule()
    #expect(HowieDavies.isOne(file) && !FredGray.isOne(file))
    var p = try HowieDaviesPlayer(file, song: 1)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2 && p.tuneInfo.format == "Howie Davies" && p.tuneInfo.author == "Me")
    #expect(written(p.startWrites, 0xC6).last == 1)
    #expect(written(p.startWrites, 0xD6).last == 8)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(written(p.writes, 0xA8) == [0x30])
    // Every voice at the end of its music: the song's end.
    #expect(p.endings == 1)
}

/// A module of Holger Gehrmann's Sound Programming Language: two songs (from one), ticks at a speed of
/// its own; a start that writes the song's number to AUD1PER and points the four voices' lists one byte
/// before a long that jumps back; a tick that writes a volume of $25 to voice 0 (through A0 at $DFF0A0,
/// which the player's patch makes a write through its own routine), waits for the DMA in a loop of its
/// own, and moves each voice's list on (back, which the player takes for the voice's end).
private func splModule() -> [UInt8] {
    var p = HunkProgram()
    header(&p, id: "!SOPROL!", ["play", "init", nil, "name", "author", nil, nil, nil, nil, nil, nil], counts: [2: 2, 10: 0x2000])
    p.w(0x48E7, 0xFFFE) // MOVEM.L D0-D7/A0-A6,-(A7) (where the player's patches begin, past it)
    p.label("play")
    p.w(0x2C7C)
    p.address("lists") // MOVEA.L #lists,A6
    p.w(0x41F9, 0x00DF, 0xF0A0, 0x43F9) // LEA $DFF0A0,A0; LEA data,A1
    p.address("data")
    p.w(0x3169, 0x0026, 0x0008) // MOVE.W 38(A1),8(A0)
    p.w(0x3A3C, 0x0064, 0x51CD, 0xFFFE) // MOVE.W #100,D5; DBF D5,*
    for _ in 0 ..< 4 {
        p.w(0x2A56, 0x5296, 0x528D, 0x2C95, 0x2A56, 0x588E) // MOVEA.L (A6),A5; ADDQ.L #1,(A6); ADDQ.L #1,A5; MOVE.L (A5),(A6); MOVEA.L (A6),A5; ADDQ.L #4,A6
    }
    p.w(0x4E75)
    p.label("init")
    p.w(0x33C0, 0x00DF, 0xF0B6) // MOVE.W D0,$DFF0B6
    p.w(0x41F9)
    p.address("back") // LEA back,A0
    p.w(0x2008, 0x5180, 0x2080, 0x5E80, 0x43F9) // MOVE.L A0,D0; SUBQ.L #8,D0; MOVE.L D0,(A0); ADDQ.L #7,D0; LEA lists,A1
    p.address("lists")
    p.w(0x22C0, 0x22C0, 0x22C0, 0x22C0, 0x4E75) // MOVE.L D0,(A1)+ (four times); RTS
    p.label("lists")
    for _ in 0 ..< 4 { p.long(0) }
    p.label("back")
    p.long(0)
    p.label("data")
    for _ in 0 ..< 19 { p.w(0) }
    p.w(0x25)
    names(&p)
    return p.file()
}

@Test func soundProgrammingLanguageModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = splModule()
    #expect(SoundProgrammingLanguage.isOne(file) && !HowieDavies.isOne(file))
    var p = try SoundProgrammingLanguagePlayer(file, song: 1)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2 && p.tuneInfo.format == "Sound Programming Language")
    // The second song, as the player numbers them from one.
    #expect(written(p.startWrites, 0xB6).last == 2)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // Its own speed: CIA-A's timer at $2000.
    #expect(abs(p.tickClocks - (0x2000 + 1) * 5) < 5)
    #expect(written(p.writes, 0xA8) == [0x25])
    #expect(p.endings == 1)
}

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
            damaged[32 + Int(seed >> 8) % (damaged.count - 32)] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        var out = Silent()
        if var p = try? WantedTeamPlayer<R>(damaged) { for _ in 0 ..< 10 { _ = p.run(&out) } }
    }
}

@Test func wantedTeamModulesThatAreDamagedNeverTrapOrHang() {
    damage(CoreDesign.self, coreModule())
    damage(JankoMrsicFlogel.self, jmfModule())
    damage(DaglishSID.self, bdsModule())
    damage(FredGray.self, grayModule())
    damage(HowieDavies.self, hdModule())
    damage(SoundProgrammingLanguage.self, splModule())
}
