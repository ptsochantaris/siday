// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the recipes for Wally Beben's and Mike Davies' music, on tiny modules assembled here by
// hand as if saved from a game at an address of their own: each laid out as its player looks for it, its
// code and tables moved to where UADE puts it, its code changed as the player changes it, and its songs
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

/// Where the modules here were saved from.
private let origin: UInt32 = 0x30000

@Test func codeSavedAtAnAddressOfItsOwnIsMovedAsThePlayersMoveIt() throws {
    var host = try DeliTrackerHost(moduleAt: 0xF000, module: [])
    let code = FixedOriginCode(forms: [(0x1039, .address), (0x13FC, .afterWord), (0x13F9, .twoAddresses)])
    let words: [UInt16] = [
        0x1039, 0x0003, 0x0100, // MOVE.B $30100,D0: moved
        0x13FC, 0x0001, 0x0003, 0x0102, // MOVE.B #1,$30102: moved
        0x13F9, 0x00DF, 0xF006, 0x0003, 0x0104, // MOVE.B $DFF006,$30104: the second moved
        0x1039, 0x00DF, 0xF00A, // MOVE.B $DFF00A,D0: kept, its address gone through as words
        0x4E75,
    ]
    for (i, word) in words.enumerated() { host.machine.poke16(0x10000 + UInt32(i * 2), word) }
    let end = 0x10000 + UInt32(words.count * 2)
    #expect(code.relocate(&host, from: 0x10000, to: end, origin: origin, module: 0x20000))
    #expect(host.machine.peek32(0x10002) == 0x20100)
    #expect(host.machine.peek32(0x1000A) == 0x20102)
    #expect(host.machine.peek32(0x10010) == 0xDFF006 && host.machine.peek32(0x10014) == 0x20104)
    #expect(host.machine.peek32(0x1001A) == 0xDFF00A)
    // The players' searches end only at the end exactly, after a word not in the table: one that steps
    // over it, or starts at it, would go on for ever.
    #expect(!code.relocate(&host, from: 0x10000, to: 0x10004, origin: 0, module: 0))
    #expect(!code.relocate(&host, from: end, to: end, origin: 0, module: 0))
}

/// How a module of Wally Beben's ends its songs.
private enum WallyBebenEnding { case lists, stops }

/// A module of Wally Beben's, saved at `origin`, old or new: its BRA to its start and its routine for a
/// tick at 4; the start, a BSR and two CLR.Bs; a tick that writes 256 and the song's number (from its byte
/// after the first RTS) to AUD0PER and the first sample's address to AUD0LC, and ends the song by the end
/// of its voices' lists of patterns (two each) or by silencing voices 1 and 2 (each tick); a line of
/// text; and then, never run, the instructions the player finds its songs, voices, samples, lengths and
/// periods by. Its first sample is at an odd place.
private func wallyBebenModule(new: Bool, ending: WallyBebenEnding) -> [UInt8] {
    var a = AmigaAssembly(at: origin)
    let initSong = a.label(), tick = a.label(), start = a.label(), songByte = a.label()
    let songs = a.label(), patterns = a.label(), samples = a.label(), empty = a.label(), lengths = a.label()
    let periods = a.label(), sample = a.label(), count = a.label()
    let lists = (0 ..< 4).map { _ in a.label() }, voices = (0 ..< 4).map { _ in a.label() }
    a.w(0x6000)
    a.displacement(to: initSong) // BRA.W init
    a.w(0x48E7, 0xFFFE, 0x6100) // MOVEM.L D0-A6,-(A7); BSR.W tick
    a.displacement(to: tick)
    a.w(0x4CDF, 0x7FFF, 0x4E75) // MOVEM.L (A7)+,D0-A6; RTS
    a.place(songByte)
    a.w(0)
    a.place(tick)
    if new {
        a.w(0x4CF9, 0x00FF)
        a.address(of: periods) // MOVEM.L periods,D0-D7
    } else {
        a.w(0x4E71, 0x4E71)
    }
    a.w(0x1039)
    a.address(of: songByte) // MOVE.B songByte,D0
    a.w(0x0240, 0x00FF, 0x0640, 0x0100) // ANDI.W #$FF,D0; ADDI.W #$100,D0
    a.w(0x33C0, 0x00DF, 0xF0A6, 0x43F9) // MOVE.W D0,$DFF0A6; LEA samples,A1
    a.address(of: samples)
    a.w(0x23D1, 0x00DF, 0xF0A0) // MOVE.L (A1),$DFF0A0
    switch ending {
    case .stops: a.w(0x4BF9, 0x00DF, 0xF0A8, 0x7000, 0x3B40, 0x0010, 0x3B40, 0x0020) // LEA $DFF0A8,A5; MOVEQ #0,D0; MOVE.W D0,$10(A5); MOVE.W D0,$20(A5)
    case .lists:
        for v in 0 ..< 4 {
            a.w(0x41F9)
            a.address(of: voices[v]) // LEA voice,A0
            a.w(0x43F9)
            a.address(of: lists[v]) // LEA list,A1
            a.w(0x7000, 0x1028, 0x000C, 0x5228, 0x000C, 0xD3C0) // MOVEQ #0,D0; MOVE.B 12(A0),D0; ADDQ.B #1,12(A0); ADDA.L D0,A1
        }
    }
    a.w(0x4E75)
    a.place(initSong)
    a.w(0x6100)
    a.displacement(to: start) // BSR.W start
    a.w(0x4239)
    a.address(of: count) // CLR.B count
    a.w(0x4239)
    a.address(of: count) // CLR.B count
    a.w(0x4E75)
    a.place(start)
    a.w(0x4E75)
    let text = Array("(c)Wally Beben 1988, a test".utf8) + [0]
    for i in stride(from: 0, to: text.count, by: 2) { a.w(UInt16(text[i]) << 8 | UInt16(text[i + 1])) }
    // (Never run.)
    a.w(0x223C, 0x0000, 0x0003, 0x41F9) // MOVE.L #3,D1; LEA songs,A0
    a.address(of: songs)
    a.w(0x41F9)
    a.address(of: voices[0]) // LEA voices,A0
    a.w(0xD1C1) // ADDA.L D1,A0
    if new {
        a.w(0x3C36, 0x3000, 0x4DF9) // MOVE.W 0(A6,D3.W),D6; LEA empty,A6
        a.address(of: empty)
        a.w(0x4E71, 0x4E71)
    }
    a.w(0x43F9)
    a.address(of: samples) // LEA samples,A1
    a.w(0xE584, 0x4E75, 0x7000, 0x43F9) // ASL.L #2,D4; RTS; MOVEQ #0,D0; LEA lengths,A1
    a.address(of: lengths)
    a.w(0xD3F9)
    a.address(of: count) // ADDA.L count,A1
    a.w(0x3280, 0x4E75, 0x41F9) // MOVE.W D0,(A1); RTS; LEA periods,A0
    a.address(of: periods)
    a.place(periods)
    a.w(0x0358, 0x0328)
    // The songs (two, each with the four voices' lists), the patterns' pointers (one) and the lists (the
    // first pattern twice); the voices' variables (the first byte the voice's number times 16, the
    // thirteenth its place in its list).
    a.place(songs)
    for _ in 0 ..< 2 {
        for v in 0 ..< 4 { a.address(of: lists[v]) }
    }
    a.place(patterns)
    a.address(of: sample)
    for v in 0 ..< 4 {
        a.place(lists[v])
        a.w(0x0000, 0xFF00)
    }
    for v in 0 ..< 4 {
        a.place(voices[v])
        a.w(UInt16(v * 16) << 8, 0, 0, 0, 0, 0, 0, 0)
    }
    a.place(count)
    a.w(0)
    a.place(samples)
    a.address(of: sample)
    if new {
        a.place(empty)
        a.address(of: sample)
    }
    a.place(lengths)
    a.w(0x0000, 0x0008, 0, 0, 0xFF00, 0, 0, 0)
    a.place(sample)
    for _ in 0 ..< 8 { a.w(0) }
    var bytes = a.assembled()
    // (The first sample at an odd place: its pointer one on.)
    let at = Int(a.addressOf(samples) - origin)
    bytes[at + 3] += 1
    return bytes
}

@Test func wallyBebensModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    for new in [false, true] {
        let file = wallyBebenModule(new: new, ending: .lists)
        #expect(WallyBeben.isOne(file))
        #expect(!MikeDavies.isOne(file) && !SeanConnolly.isOne(file) && !Desire.isOne(file))
        #expect(!WallyBeben.isOne(Array(file.prefix(30))))
        var p = try WallyBebenPlayer(file, song: 1)
        #expect(p.songCount == 2)
        #expect(p.tuneInfo.format == "Wally Beben" && p.tuneInfo.author == "Wally Beben")
        #expect(p.tuneInfo.detail == "(c)Wally Beben 1988, a test")
        var out = Silent()
        _ = p.run(&out)
        _ = p.run(&out)
        // The song's number (from one) in the module's byte for it, which the module reads at its own
        // address moved; and its first sample's pointer, moved, and one on (as it was at an odd place).
        #expect(written(p.writes, 0xA6) == [0x102])
        let sample = WallyBeben.moduleAt + UInt32(file.count - 16) + 2
        #expect(written(p.writes, 0xA0) == [UInt16(sample >> 16)] && written(p.writes, 0xA2) == [UInt16(sample & 0xFFFF)])
        #expect(p.endings == 0)
        // Each voice's list at its end on the third tick: the song's end.
        _ = p.run(&out)
        #expect(p.endings == 0)
        _ = p.run(&out)
        #expect(p.endings == 1)
        #expect(p.lengthClocks != nil)
    }
}

@Test func wallyBebensSongsEndWhenTheModuleStopsTwice() throws {
    // Voices 1 and 2 silenced: the first time since the song was started is not its end, the second is.
    var p = try WallyBebenPlayer(wallyBebenModule(new: false, ending: .stops))
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)
    // A module whose songs' table the player would go through for ever (no songs) is refused.
    var none = wallyBebenModule(new: false, ending: .stops)
    let at = stride(from: 0, to: none.count - 6, by: 2).first { Array(none[$0 ..< $0 + 6]) == [0x22, 0x3C, 0, 0, 0, 3] }!
    none[at + 5] = 1 // (MOVE.L #1,D1: no songs)
    #expect(throws: TuneError.self) { _ = try WallyBebenPlayer(none) }
}

/// A module of Mike Davies', saved at `origin`: its variables first (noughts); his routine to start a song
/// at 230, which keeps its number in D0 (it plays it as AUD3PER), sets a count of three ticks, and turns
/// the voices' DMA off (which is not an end while it is starting); his routine for a tick, which writes
/// voice 0's sample, length, period and volume from the samples' first table (as his code writes them from
/// a voice's variables, which the player patches), voice 1's sample from the pattern's pointer in his track
/// (after the command, $99, whose number the player reads in his code), and turns the DMA off when the
/// count runs out; and, never run, the instructions the player finds his tables by. His samples' tables
/// are of two samples and none, his songs two.
private func mikeDaviesModule() -> (bytes: [UInt8], samplesEndAt: Int) {
    var a = AmigaAssembly(at: origin)
    let first = a.variable(word: 0), song = a.variable(word: 0), count = a.variable(word: 0)
    while a.here < origin + 230 { a.w(0) }
    let tickBody = a.label(), codeEnd = a.label(), songs = a.label(), songsEnd = a.label(), second = a.label()
    let record = a.label(), samples = a.label(), samplesEnd = a.label(), track = a.label()
    let sampleA = a.label(), sampleB = a.label(), dead = a.label(), done = a.label()
    a.w(0x48E7, 0xFFFE, 0x6106, 0x4CDF, 0x7FFF, 0x4E75) // MOVEM.L D0-A6,-(A7); BSR.S *+8; MOVEM.L (A7)+,D0-A6; RTS
    a.w(0x0C40, 0x00FF, 0x33FC, 0x0001) // CMPI.W #$FF,D0; MOVE.W #1,first
    a.address(of: first)
    a.w(0x33C0)
    a.address(of: song) // MOVE.W D0,song
    a.w(0x33FC, 0x0003)
    a.address(of: count) // MOVE.W #3,count
    a.w(0x33FC, 0x000F, 0x00DF, 0xF096, 0x4E75) // MOVE.W #$F,$DFF096; RTS
    // (Never run.)
    a.w(0x6000)
    a.displacement(to: dead) // BRA.W
    a.place(dead)
    a.w(0x2D58, 0x0000, 0x41F9) // MOVE.L (A0)+,0(A6); LEA songs,A0
    a.address(of: songs)
    a.w(0xB1FC)
    a.address(of: songsEnd) // CMPA.L #songsEnd,A0
    a.w(0x41F9)
    a.address(of: second) // LEA second,A0
    a.w(0xB1FC)
    a.address(of: second) // CMPA.L #second,A0
    a.w(0x303C, 0x0005, 0x51C8, 0xFFFE) // MOVE.W #5,D0; DBF D0,*
    // The routine for a tick.
    a.w(0x48E7, 0xFFFE, 0x7000, 0x7200, 0x6100) // MOVEM.L D0-A6,-(A7); MOVEQ #0,D0; MOVEQ #0,D1; BSR.W
    a.displacement(to: tickBody)
    a.w(0x4CDF, 0x7FFF, 0x4E75) // MOVEM.L (A7)+,D0-A6; RTS
    // (Never run.)
    a.w(0x41F9)
    a.address(of: samples) // LEA samples,A0
    a.w(0xB1FC)
    let samplesEndAt = a.placed()
    a.address(of: samplesEnd) // CMPA.L #samplesEnd,A0
    a.w(0x4BF9)
    a.address(of: codeEnd) // LEA codeEnd,A5
    a.w(0x0C40, 0x0000)
    for _ in 0 ..< 10 { a.w(0x4E71) }
    a.w(0x0099) // the command, 24 bytes on from the CMPI
    a.place(tickBody)
    a.w(0x3039)
    a.address(of: song) // MOVE.W song,D0
    a.w(0x33C0, 0x00DF, 0xF0D6, 0x303C, 0x0005, 0x51C8, 0xFFFE, 0x4DF9) // MOVE.W D0,$DFF0D6; MOVE.W #5,D0; DBF D0,*; LEA record,A6
    a.address(of: record)
    let writes: [UInt16] = [0x216E, 0x000E, 0x00A0, 0x316E, 0x000A, 0x00A4, 0x316E, 0x0004, 0x00A6]
    a.w(0x41F9, 0x00DF, 0xF000) // LEA $DFF000,A0
    for word in writes { a.w(word) } // MOVE.L 14(A6),$A0(A0); MOVE.W 10(A6),$A4(A0); MOVE.W 4(A6),$A6(A0)
    a.w(0x316E, 0x0006, 0x00A8, 0x4DF9) // MOVE.W 6(A6),$A8(A0); LEA track-8,A6
    let trackAt = a.placed()
    a.address(of: track)
    a.w(0x41F9, 0x00DF, 0xF010) // LEA $DFF010,A0
    for word in writes { a.w(word) }
    a.w(0x5379)
    a.address(of: count) // SUBQ.W #1,count
    a.branch(0x6600, to: done) // BNE.S
    a.w(0x33FC, 0x000F, 0x00DF, 0xF096) // MOVE.W #$F,$DFF096
    a.place(done)
    a.w(0x4E75)
    a.place(codeEnd)
    // The songs' tracks (the second song's three voices without), the samples' empty second table, the
    // first's two samples (the 14 bytes before them read as a voice's variables), the track (the command,
    // and six bytes on the pattern's pointer), and the samples.
    a.place(songs)
    for _ in 0 ..< 4 { a.address(of: track) }
    a.address(of: track)
    for _ in 0 ..< 3 { a.long(0xFFFF_FFFF) }
    a.place(songsEnd)
    a.place(second)
    a.place(record)
    a.w(0, 0, 0x0123, 0x0030, 0, 0x0008, 0) // its period, volume and length at 4, 6 and 10
    a.place(samples)
    for s in [sampleA, sampleB] {
        a.address(of: s)
        a.long(8)
        for _ in 0 ..< 8 { a.w(0) }
    }
    a.place(samplesEnd)
    a.w(0, 0, 0, 0)
    a.place(track)
    a.w(0x0099, 0, 0)
    a.address(of: sampleB)
    a.w(0, 0, 0, 0)
    a.place(sampleA)
    for _ in 0 ..< 8 { a.w(0) }
    a.place(sampleB)
    for _ in 0 ..< 8 { a.w(0) }
    var bytes = a.assembled()
    // (The voice's variables for the track's pointer are 14 bytes before it: the LEA's address 8 back.)
    let lea = Int(a.addressOf(trackAt) - origin)
    bytes[lea + 3] -= 8
    return (bytes, Int(a.addressOf(samplesEndAt) - origin))
}

@Test func mikeDaviesModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let (file, samplesEndAt) = mikeDaviesModule()
    #expect(MikeDavies.isOne(file))
    #expect(!WallyBeben.isOne(file) && !SeanConnolly.isOne(file) && !Desire.isOne(file))
    #expect(!MikeDavies.isOne(Array(file.prefix(250))))
    var p = try MikeDaviesPlayer(file, song: 1)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Mike Davies" && p.tuneInfo.author == "Mike Davies")
    var out = Silent()
    _ = p.run(&out)
    #expect(p.endings == 0)
    _ = p.run(&out)
    // The song's number, as the start keeps it in its variable at its own address moved.
    #expect(written(p.writes, 0xD6) == [2])
    // Voice 0's sample (its address in the table moved), length, period and volume, through the
    // player's patches; voice 1's, the pattern's pointer in the track, moved.
    let sampleA = MikeDavies.moduleAt + UInt32(file.count - 32), sampleB = sampleA + 16
    #expect(written(p.writes, 0xA0) == [UInt16(sampleA >> 16)] && written(p.writes, 0xA2) == [UInt16(sampleA & 0xFFFF)])
    #expect(written(p.writes, 0xA4) == [8] && written(p.writes, 0xA6) == [0x123] && written(p.writes, 0xA8) == [0x30])
    #expect(written(p.writes, 0xB2) == [UInt16(sampleB & 0xFFFF)])
    #expect(p.endings == 0)
    // The count run out on the third tick, and the voices' DMA turned off: the song's end.
    _ = p.run(&out)
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
    // A module whose samples' table is not of whole samples is refused.
    var odd = file
    odd[samplesEndAt + 3] += 2
    #expect(throws: TuneError.self) { _ = try MikeDaviesPlayer(odd) }
}
