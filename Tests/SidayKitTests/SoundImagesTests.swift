// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the recipe for Sound Images' music, on a tiny module assembled here by hand where UADE puts
// it: laid out as Wanted Team's player looks for it, its code changed as the player changes it, and its
// songs ending as the player has them end. The thorough check is made outside the package: what every one
// of UnExoticA's modules writes to Paula, tick by tick and song by song, against what it writes in UADE.

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

/// A module of Sound Images' first kind, of three voices: its BRA to its routine for a tick; its variables
/// (the song to start at 4, the one playing at 5, the DMA and interrupts to turn on at 16 and 18); its audio
/// interrupt, which writes $22 to AUD0LEN; and its routine for a tick, which turns on what its variables
/// ask for, starts a song when one is asked for (writing its number to AUD1PER, asking for voice 0's DMA
/// and interrupt, and setting the interrupt's vector), and then, while a song plays, writes voice 0's
/// volume of $40 (as its code writes volumes, which the player patches) and reads voice 0's list: $42 in
/// it stops the song, and its end (a nought) ends voice 0's list. Its songs' table has room for `room`
/// records: song 1's list is $40 and the end, song 2's $40, $42 and the end. With `early`, its variables
/// ask, as it is saved, for voice 0's DMA and interrupt as its first tick begins.
private func soundImagesModule(room: Int = 2, early: Bool = false) -> [UInt8] {
    var a = AmigaAssembly(at: SoundImages.moduleAt)
    let tick = a.label(), vars = a.label(), handler = a.label(), start = a.label(), songs = a.label()
    let samples = a.label(), record = a.label(), out = a.label(), noSkip = a.label(), done = a.label()
    a.w(0x6000)
    a.displacement(to: tick) // BRA.W tick
    a.place(vars)
    for _ in 0 ..< 14 { a.w(0) }
    // The audio interrupt, ending as the player's check looks for.
    a.place(handler)
    a.w(0x48E7, 0x4002, 0x4DF9, 0x00DF, 0xF000) // MOVEM.L D1/A6,-(A7); LEA $DFF000,A6
    a.w(0x322E, 0x001E, 0xC26E, 0x001C, 0x0241, 0x0780) // MOVE.W 30(A6),D1; AND.W 28(A6),D1; ANDI.W #$780,D1
    a.w(0x4A01) // TST.B D1
    a.branch(0x6A00, to: noSkip) // BPL.S
    a.w(0x3D7C, 0x0022, 0x00A4) // MOVE.W #$22,$A4(A6)
    a.place(noSkip)
    a.w(0x3D41, 0x009A, 0x3D41, 0x009C, 0x4CDF, 0x4002, 0x4E73) // MOVE.W D1,$9A(A6); MOVE.W D1,$9C(A6); MOVEM.L (A7)+,D1/A6; RTE
    // The routine for a tick.
    a.place(tick)
    a.w(0x48E7, 0xF0E6, 0x4DF9, 0x00DF, 0xF000, 0x4BFA) // MOVEM.L D0-D3/A0-A2/A5/A6,-(A7); LEA $DFF000,A6; LEA vars(PC),A5
    a.displacement(to: vars)
    a.w(0x3D6D, 0x000C, 0x0096, 0x302D, 0x000E, 0x0240, 0x0780) // MOVE.W 12(A5),$96(A6); MOVE.W 14(A5),D0; ANDI.W #$780,D0
    a.w(0x3D40, 0x009C, 0x3D6D, 0x000E, 0x009A, 0x42AD, 0x000C) // MOVE.W D0,$9C(A6); MOVE.W 14(A5),$9A(A6); CLR.L 12(A5)
    a.w(0x6100)
    a.displacement(to: start) // BSR.W start
    a.w(0x532D, 0x0013, 0x41FA) // SUBQ.B #1,19(A5); LEA samples(PC),A0
    a.displacement(to: samples)
    a.w(0x4A2D, 0x0001) // TST.B 1(A5)
    a.branch(0x6700, to: out) // BEQ.S
    a.w(0x303C, 0x1000, 0xEC48, 0x3D40, 0x00A8) // MOVE.W #$1000,D0; LSR.W #6,D0; MOVE.W D0,$A8(A6)
    a.w(0x41FA)
    a.displacement(to: record) // LEA record(PC),A0
    a.w(0x2268, 0x000E, 0x3019) // MOVEA.L 14(A0),A1; MOVE.W (A1)+,D0
    a.branch(0x6700, to: out) // BEQ.S
    a.w(0x2149, 0x000E, 0x0C40, 0x0042) // MOVE.L A1,14(A0); CMPI.W #$42,D0
    a.branch(0x6600, to: out) // BNE.S
    a.w(0x422D, 0x0001) // CLR.B 1(A5)
    a.place(out)
    a.w(0x4CDF, 0x670F, 0x4E75) // MOVEM.L (A7)+,D0-D3/A0-A2/A5/A6; RTS
    // The start of a song.
    a.place(start)
    a.w(0x4A2D, 0x0001) // TST.B 1(A5)
    a.branch(0x6600, to: done) // BNE.S
    a.w(0x102D, 0x0000) // MOVE.B 0(A5),D0
    a.branch(0x6700, to: done) // BEQ.S
    a.w(0xB03C, 0x0003) // CMP.B #3,D0
    a.branch(0x6400, to: done) // BCC.S
    a.w(0x1B40, 0x0001, 0x5300, 0x0240, 0x00FF, 0xE740, 0x43FB) // MOVE.B D0,1(A5); SUBQ.B #1,D0; ANDI.W #$FF,D0; ASL.W #3,D0; LEA songs(PC,D0.W),A1
    let lea = a.here
    a.w(0)
    a.w(0x3011, 0x45FA) // MOVE.W (A1),D0; LEA songs(PC),A2
    a.displacement(to: songs)
    a.w(0xD4C0, 0x41FA) // ADDA.W D0,A2; LEA record(PC),A0
    a.displacement(to: record)
    a.w(0x214A, 0x000E, 0x7200, 0x122D, 0x0001, 0x3D41, 0x00B6) // MOVE.L A2,14(A0); MOVEQ #0,D1; MOVE.B 1(A5),D1; MOVE.W D1,$B6(A6)
    a.w(0x3B7C, 0x8201, 0x000C, 0x3B7C, 0x8080, 0x000E) // MOVE.W #$8201,12(A5); MOVE.W #$8080,14(A5)
    a.w(0x41FA)
    a.displacement(to: handler) // LEA handler(PC),A0
    a.w(0x21C8, 0x0070, 0x3D7C, 0x00FF, 0x009E) // MOVE.L A0,$70.W; MOVE.W #$FF,$9E(A6)
    a.place(done)
    a.w(0x4E75)
    // The songs' table: the records (voice 0's list's offset, the others' nought, and a word), then the
    // lists.
    a.place(songs)
    let lists = UInt16(room * 8)
    a.w(lists, 0, 0, 0, lists + 4, 0, 0, 0)
    for _ in 2 ..< room { a.w(lists, 0, 0, 0) }
    a.w(0x40, 0, 0x40, 0x42, 0)
    // The samples' table, after the code the player's search back from it stops at; and the voices'
    // records, each with its registers' base at 10.
    a.w(0x3152, 0, 0x6000, 0)
    a.place(samples)
    a.place(record)
    for v: UInt32 in 0 ..< 3 {
        a.w(0, 0, 0, 0, 0)
        a.long(0xDFF0A0 + v * 16)
        for _ in 0 ..< 9 { a.w(0) }
    }
    var bytes = a.assembled()
    // (The LEA's displacement, a byte from its extension word, which the player reads as a word.)
    let at = Int(lea - SoundImages.moduleAt)
    bytes[at + 1] = UInt8(Int(a.addressOf(songs)) - Int(lea))
    if early { bytes[16 ... 19] = [0x82, 0x01, 0x80, 0x80] }
    return bytes + [UInt8](repeating: 0, count: 64)
}

@Test func soundImagesModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = soundImagesModule()
    #expect(SoundImages.kind(file) == 1)
    #expect(SoundImages.isOne(file) && !SeanConnolly.isOne(file) && !Desire.isOne(file) && !CoreDesign.isOne(file))
    var p = try SoundImagesPlayer(file)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Sound Images" && p.tuneInfo.author == "Tony Williams")
    var out = Silent()
    // (The first run is the time before the timer first runs out.)
    _ = p.run(&out)
    #expect(written(p.writes, 0xB6).isEmpty)
    _ = p.run(&out)
    // The song started (its number from one), and the volume through the player's patch (the balance
    // none).
    #expect(written(p.writes, 0xB6) == [1])
    #expect(written(p.writes, 0xA8) == [0x40])
    #expect(p.endings == 0)
    // The voice's DMA and interrupt turned on: the module's handler, set through the player's patch, takes
    // the interrupt.
    _ = p.run(&out)
    #expect(written(p.writes, 0xA4).contains(0x22))
    // The end of voice 0's list, the only voice the song has: the song's end.
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
}

@Test func soundImagesSongsEndWhenTheModuleStopsThem() throws {
    // Song 2's list stops the song (the song playing, at 5, nought after a tick): its end.
    var p = try SoundImagesPlayer(soundImagesModule(), song: 1)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(written(p.writes, 0xB6) == [2])
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
}

@Test func soundImagesInterruptsWaitForTheirHandler() throws {
    // The voice's interrupt asked for before the song's start has set its handler: it waits for it (where
    // score's vector would stop everything).
    var p = try SoundImagesPlayer(soundImagesModule(early: true))
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(written(p.writes, 0x96).first == 0x8201)
    #expect(written(p.writes, 0xA4).contains(0x22))
    #expect(p.stops == 0 && p.failure == nil)
}

@Test func soundImagesHiddenSongsAreCounted() throws {
    // Room for three records where the start takes two: three songs, and the start made to take them.
    var p = try SoundImagesPlayer(soundImagesModule(room: 3), song: 2)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 3)
    #expect(p.song == 2)
}

@Test func soundImagesOtherModulesAreRefused() throws {
    var file = soundImagesModule()
    // The second kind, which siday has none of.
    var second = [UInt8](repeating: 0, count: 64)
    second[0] = 0xB2
    second[1] = 0x7A
    second[34 ... 37] = [0x4E, 0x75, 0x70, 0xFF]
    #expect(SoundImages.kind(second) == 2)
    #expect(throws: TuneError.self) { _ = try SoundImagesPlayer(second) }
    // Not the end of an audio interrupt before the routine for a tick.
    file[2 + Int(file[3]) - 7] = 0
    #expect(!SoundImages.isOne(file))
    // Cut short: not taken, or refused, and never a trap.
    let whole = soundImagesModule()
    for length in stride(from: 0, to: whole.count, by: 7) {
        _ = try? SoundImagesPlayer(Array(whole.prefix(length)))
    }
}

