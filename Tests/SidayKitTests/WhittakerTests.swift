// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of David Whittaker's modules, on a tiny module assembled here by hand: a
// driver laid out as his are, which the player's check takes and finds its way about, and whose songs
// end as the player has them end. The thorough check is made outside the package: what every one of
// UnExoticA's modules writes to Paula, tick by tick and song by song, against what it writes in UADE.

/// A module of David Whittaker's, as small as one can be: the table of routines, a routine that starts
/// a song (calling the one that stops the music, and the one that readies the samples, then setting
/// each voice going on the sample), one that stops the music, and one that plays a tick: each voice
/// steps through its list of patterns, which here are periods (as the driver's pointers would be), going
/// back to the start of the list at its end. With `stopping`, a tick instead stops the music.
private func module(stopping: Bool = false) -> AmigaCode {
    var c = AmigaCode(at: WhittakerPlayer.moduleAddress)
    c.label("base")
    c.w(0x48E7, 0xF1FE, 0x6100); c.to("init"); c.w(0x4CDF, 0x7F8F, 0x4E75)
    c.w(0x48E7, 0xF1FE, 0x6100); c.to("play"); c.w(0x4CDF, 0x7F8F, 0x4E75)
    c.label("stopStub")
    c.w(0x48E7, 0x0010, 0x6100); c.to("stop"); c.w(0x4CDF, 0x0800, 0x4E75)
    c.label("init")
    c.w(0x47FA); c.to("base") // LEA base(PC),A3
    c.w(0x6100); c.to("stopStub") // BSR
    c.w(0x6100); c.to("samples") // BSR
    c.w(0x4880) // EXT.W D0
    c.w(0xC0FC, 0x000A) // MULU #10,D0
    c.w(0x41FA); c.to("songs") // LEA songs(PC),A0
    c.w(0x4DF9, 0x00DF, 0xF0A0) // LEA $DFF0A0,A6
    c.w(0x7E03) // MOVEQ #3,D7
    c.label("voice")
    c.w(0x2D7C); c.address("sound"); c.w(0x0000) // MOVE.L #sound,0(A6)
    c.w(0x3D7C, 0x0008, 0x0004) // MOVE.W #8,4(A6)
    c.w(0x3D7C, 0x0040, 0x0008) // MOVE.W #64,8(A6)
    c.w(0xDCFC, 0x0010) // ADDA.W #16,A6
    c.w(0x51CF); c.to("voice") // DBF D7,voice
    c.w(0x33FC, 0x820F, 0x00DF, 0xF096) // MOVE.W #$820F,$DFF096
    c.w(0x4E75)
    c.label("stop")
    c.w(0x33FC, 0x000F, 0x00DF, 0xF096) // MOVE.W #$F,$DFF096
    c.w(0x33FC, 0x00FF, 0x00DF, 0xF09E) // MOVE.W #$FF,$DFF09E
    c.w(0x33FC, 0x0000, 0x00DF, 0xF0C8) // MOVE.W #0,$DFF0C8
    c.w(0x4E75)
    c.label("samples")
    c.w(0x41FA); c.to("sampleTable") // LEA sampleTable(PC),A0
    c.w(0x7E00, 0x2418, 0x4E75) // MOVEQ #0,D7; MOVE.L (A0)+,D2; RTS
    c.label("play")
    if stopping {
        c.w(0x6100); c.to("stopStub")
        c.w(0x4E75)
    } else {
        c.w(0x47FA); c.to("base")
        c.w(0x4DF9, 0x00DF, 0xF000) // LEA $DFF000,A6
        c.w(0x41FA); c.to("voices") // LEA voices(PC),A0
        c.w(0x7E03) // MOVEQ #3,D7
        c.label("step")
        c.w(0x3028, 0x000A) // MOVE.W 10(A0),D0
        c.w(0x3468, 0x0008) // MOVEA.W 8(A0),A2
        c.w(0xD4C0, 0x5440) // ADDA.W D0,A2; ADDQ.W #2,D0
        c.label("wrap")
        c.w(0x4A73, 0xA000, 0x6606, 0x3468, 0x0008, 0x7002, 0x3273, 0xA000) // the end of a list, and back
        c.w(0x3140, 0x000A) // MOVE.W D0,10(A0)
        c.w(0x3D49, 0x00A6) // MOVE.W A1,166(A6)
        c.w(0x41E8, 0x000C) // LEA 12(A0),A0
        c.w(0xDCFC, 0x0010) // ADDA.W #16,A6
        c.w(0x51CF); c.to("step") // DBF D7,step
        c.w(0x4E75)
    }
    c.label("voices")
    var voices = AmigaCode(at: 0)
    for _ in 0 ..< 4 { voices.w(0, 0, 0, 0, 0, 0) }
    let voicesAt = c.here
    c.words += voices.words
    c.label("songs")
    c.w(0x0000, 0, 0, 0, 0)
    c.label("list")
    c.w(0x0100, 0x0200, 0x0000)
    c.label("sampleTable")
    c.w(0x0000, 0x0010, 0x0000)
    c.label("sound")
    c.bytes([UInt8](repeating: 0x40, count: 8) + [UInt8](repeating: 0xC0, count: 8))
    c.bytes([UInt8](repeating: 0, count: 64))
    // Each voice's list (at 8 in it), and the song's, from the base.
    for v in 0 ..< 4 {
        c.words[voicesAt / 2 + v * 6 + 4] = UInt16(c.offset("list"))
        c.words[c.offset("songs") / 2 + 1 + v] = UInt16(c.offset("list"))
    }
    return c
}

private func bytes(_ c: AmigaCode) -> [UInt8] { c.assembled() }

@Test func whittakerModulesAreFoundTheirWayAbout() throws {
    let c = module()
    let data = bytes(c)
    #expect(WhittakerPlayer.isOne(data))
    let layout = try WhittakerModule(data)
    #expect(layout.flag == 0)
    #expect(layout.initAt == 0 && layout.playAt == 14 && layout.setUpAt == nil)
    #expect(layout.base == 0)
    #expect(layout.samples == c.offset("sampleTable") && layout.sampleCount == 1)
    #expect(layout.songTable == c.offset("songs") && layout.entrySize == 10 && layout.voices == 4 && layout.songCount == 1)
    // The end of a voice's list and the music's stopping are made calls of the player's code.
    let patched = WhittakerPlayer.patch(data, layout)
    let wrap = c.offset("wrap")
    #expect(patched[wrap] == 0x4E && patched[wrap + 1] == 0xB9)
    #expect(Array(patched[wrap + 6 ..< wrap + 16]) == [0x4E, 0x71, 0x4E, 0x71, 0x4E, 0x71, 0x4E, 0x71, 0x4E, 0x71])
    let stop = c.offset("stop") + 8
    #expect(patched[stop] == 0x4E && patched[stop + 1] == 0xB9 && patched[stop + 6] == 0x4E && patched[stop + 7] == 0x71)
    // Not his: a file that begins with NOPs, or with nothing of his.
    #expect(!WhittakerPlayer.isOne([0x4E, 0x71, 0x4E, 0x71] + Array(data.dropFirst(4))))
    #expect(!WhittakerPlayer.isOne([UInt8](repeating: 0, count: 256)))
    #expect(throws: TuneError.self) { let _ = try WhittakerPlayer([UInt8](repeating: 0x60, count: 300)) }
}

/// What Paula is told, as a list.
private struct Told: TFMXOutput {
    var periods: [String] = []
    var starts = 0
    mutating func on(_: Int) { starts += 1 }
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { periods.append("\(voice):\(period)") }
}

@Test func whittakerSongsEndAsThePlayerHasThemEnd() throws {
    var player = try WhittakerPlayer(bytes(module()))
    try player.select(song: player.song)  // (Played through first, as its renderer has it played.)
    // Every voice is back at the start of its list on the third tick: the song is two ticks long.
    #expect(player.lengthClocks == 2 * UInt64(WhittakerPlayer.tickClocks))
    #expect(player.tuneInfo.format == "David Whittaker")
    var ticks: [[String]] = []
    var starts = 0
    for _ in 0 ..< 4 {
        var told = Told()
        _ = player.run(&told)
        ticks.append(told.periods)
        starts += told.starts
    }
    // (The first tick is told first what the song's start wrote, which began with each voice's period
    // set to 150, as UADE's host sets them.)
    #expect(Array(ticks[0].prefix(4)) == ["0:150", "1:150", "2:150", "3:150"])
    #expect(Array(ticks[0].suffix(4)) == ["0:256", "1:256", "2:256", "3:256"])
    #expect(ticks[1] == ["0:512", "1:512", "2:512", "3:512"])
    #expect(ticks[2] == ["0:256", "1:256", "2:256", "3:256"])
    #expect(player.endings == 1)
    #expect(player.stops == 0)
    // The song's start set the four voices going (as UADE's host has Paula first, then the module).
    #expect(starts == 4)
    // The stopping of the music, other than as the song is started, is its end.
    var stopping = try WhittakerPlayer(bytes(module(stopping: true)))
    try stopping.select(song: stopping.song)  // (Played through first, as its renderer has it played.)
    #expect(stopping.lengthClocks == 0)
    var told = Told()
    _ = stopping.run(&told)
    #expect(stopping.stops == 1)
}

@Test func whittakerModulesAreHeard() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(WhittakerPlayer(bytes(module())), options: options)
    #expect(renderer.subsongCount == 1)
    #expect(abs((renderer.songs[0].length ?? 0) - 2 * Double(WhittakerPlayer.tickClocks) / Paula.clockHz) < 1e-9)
    let frames = outputSampleRate / 5
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.05)
    #expect(renderer.loopCount >= 1)
}

@Test(arguments: [false, true]) func whittakerModulesThatAreDamagedAreRefusedOrPlayed(hubbard: Bool) {
    // (Rob Hubbard's too, whose driver runs from Paula's interrupts.)
    let data = bytes(hubbard ? hubbardModule() : module())
    var refused = 0
    for cut in 0 ..< data.count {
        do {
            let renderer = try PaulaTickRenderer(WhittakerPlayer(Array(data.prefix(cut))), options: LoadOptions())
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2000)
            renderer.render(into: buffer, frames: 1000)
            buffer.deallocate()
        } catch {
            refused += 1
        }
    }
    #expect(refused > 0)
    var generator = SplitMix(seed: 7)
    // (Few, for each that plays may be a song that never ends, played through as it is loaded.)
    // (Fewer of Rob Hubbard's, whose machine runs as the Amiga's does, which takes longer.)
    for i in 0 ..< (hubbard ? 8 : 40) {
        var copy = data
        for _ in 0 ... i % 6 { copy[Int(generator.next() % UInt64(copy.count))] = UInt8(truncatingIfNeeded: generator.next()) }
        if let renderer = try? PaulaTickRenderer(WhittakerPlayer(copy), options: LoadOptions()) {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2000)
            renderer.render(into: buffer, frames: 1000)
            buffer.deallocate()
        }
    }
}

/// A small generator of numbers that are the same from run to run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A module of Rob Hubbard's that the player of Whittaker's plays (as Q-Ball's is), as small as one can
/// be: a routine that starts a song (calling the one that stops the music, readying its one sample, and
/// putting its routine for Paula's interrupts at the level 4 interrupt's vector itself), one that stops
/// the music, one that plays a tick, and the routine for the interrupts. Each tick, each voice takes the
/// next long of its list (a period, as the driver's pointer would be), going back to the start of the
/// list at its end, and plays its note as Q-Ball's driver does: its DMA turned off, a wait by the
/// processor, the sample set, its DMA turned on, and its interrupt cleared and let through. The routine
/// for the interrupts points each voice that asks at silence to go on with, and shuts its interrupt off.
/// The first voice's list is three longs, the others' one.
private func hubbardModule(rte: Bool = true) -> AmigaCode {
    var c = AmigaCode(at: WhittakerPlayer.moduleAddress)
    c.label("base")
    c.w(0x47FA); c.to("base") // LEA base(PC),A3
    c.w(0x6100); c.to("stop") // BSR stop
    c.w(0x41FA); c.to("sampleTable") // LEA sampleTable(PC),A0
    c.w(0x7E00, 0x2418, 0x3618) // MOVEQ #0,D7; MOVE.L (A0)+,D2; MOVE.W (A0)+,D3
    c.w(0xC0FC, 0x0012) // MULU #18,D0
    c.w(0x41FA); c.to("songs") // LEA songs(PC),A0
    c.w(0x41FA); c.to("interrupt") // LEA interrupt(PC),A0
    c.label("vector")
    c.w(0x23C8, 0x0000, 0x0070) // MOVE.L A0,$70
    c.w(0x4E75)
    c.label("stop")
    c.w(0x2F0B) // MOVE.L A3,-(A7)
    c.w(0x47FA); c.to("base") // LEA base(PC),A3
    c.w(0x33FC, 0x000F, 0x00DF, 0xF096) // MOVE.W #$F,$DFF096
    c.w(0x33FC, 0x00FF, 0x00DF, 0xF09E) // MOVE.W #$FF,$DFF09E
    c.w(0x265F, 0x4E75) // MOVEA.L (A7)+,A3; RTS
    c.label("play")
    c.w(0x48E7, 0xFFFE) // MOVEM.L D0-D7/A0-A6,-(A7)
    c.w(0x47FA); c.to("base") // LEA base(PC),A3
    c.w(0x41FA); c.to("voices") // LEA voices(PC),A0
    c.w(0x4DF9, 0x00DF, 0xF000, 0x7E00) // LEA $DFF000,A6; MOVEQ #0,D7
    c.label("step")
    c.w(0x2028, 0x000C, 0x2468, 0x0008, 0xD5C0, 0x5880) // MOVE.L 12(A0),D0; MOVEA.L 8(A0),A2; ADDA.L D0,A2; ADDQ.L #4,D0
    c.w(0x4A92, 0x6606, 0x2468, 0x0008, 0x7004, 0x2252) // the end of a list, and back
    c.w(0x2140, 0x000C) // MOVE.L D0,12(A0)
    c.w(0x4241, 0x0FC1, 0x33C1, 0x00DF, 0xF096) // CLR.W D1; BSET D7,D1; MOVE.W D1,$DFF096
    c.w(0x323C, 0x0100, 0x51C9, 0xFFFE) // MOVE.W #$100,D1; DBF D1,*
    c.w(0x3D49, 0x00A6) // MOVE.W A1,$A6(A6)
    c.w(0x2D7C); c.address("sound"); c.w(0x00A0) // MOVE.L #sound,$A0(A6)
    c.w(0x3D7C, 0x0008, 0x00A4, 0x3D7C, 0x0040, 0x00A8) // MOVE.W #8,$A4(A6); MOVE.W #64,$A8(A6)
    c.w(0x323C, 0x8200, 0x0FC1, 0x33C1, 0x00DF, 0xF096) // MOVE.W #$8200,D1; BSET D7,D1; MOVE.W D1,$DFF096
    c.w(0x4241, 0x3407, 0x5E42, 0x05C1, 0x33C1, 0x00DF, 0xF09C) // CLR.W D1; MOVE.W D7,D2; ADDQ.W #7,D2; BSET D2,D1; MOVE.W D1,$DFF09C
    c.w(0x08C1, 0x000F, 0x33C1, 0x00DF, 0xF09A) // BSET #15,D1; MOVE.W D1,$DFF09A
    c.w(0x41E8, 0x0010, 0xDCFC, 0x0010) // LEA 16(A0),A0; ADDA.W #16,A6
    c.w(0x5247, 0xBE7C, 0x0004, 0x6600); c.to("step") // ADDQ.W #1,D7; CMP.W #4,D7; BNE.W step
    c.w(0x4CDF, 0x7FFF, 0x4E75) // MOVEM.L (A7)+,D0-D7/A0-A6; RTS
    c.label("interrupt")
    c.w(0x48E7, 0xC080) // MOVEM.L D0/D1/A0,-(A7)
    c.w(0x41FA); c.to("silence") // LEA silence(PC),A0
    c.w(0x3039, 0x00DF, 0xF01E, 0xC079, 0x00DF, 0xF01C) // MOVE.W INTREQR,D0; AND.W INTENAR,D0
    for v in 0 ..< 4 {
        let bit = UInt16(0x80) << UInt16(v)
        c.w(0x0800, UInt16(7 + v), 0x6700); c.to("next\(v)") // BTST #7+v,D0; BEQ.W next
        c.w(0x33FC, bit, 0x00DF, 0xF09A, 0x33FC, bit, 0x00DF, 0xF09C) // its interrupt shut off and cleared
        c.w(0x33FC, 0x0001, 0x00DF, 0xF0A4 + UInt16(v * 16)) // MOVE.W #1,AUDxLEN
        c.w(0x23C8, 0x00DF, 0xF0A0 + UInt16(v * 16)) // MOVE.L A0,AUDxLC
        c.label("next\(v)")
    }
    c.w(0x4CDF, 0x0103, rte ? 0x4E73 : 0x4E75) // MOVEM.L (A7)+,D0/D1/A0; RTE
    c.label("voices")
    for v in 0 ..< 4 {
        c.w(0, 0, 0, 0)
        c.address("list\(v)")
        c.w(0, 0)
    }
    // The song: its speed, and the offset of each voice's list from the base, filled in below.
    c.label("songs")
    c.w(0x0001, 0, 0, 0, 0, 0, 0, 0, 0)
    let periods: [[UInt16]] = [[0x100, 0x200, 0x300], [0x180], [0x1C0], [0x140]]
    for v in 0 ..< 4 {
        c.label("list\(v)")
        for period in periods[v] { c.w(0, period) }
        c.w(0, 0)
    }
    c.label("sampleTable")
    c.w(0x0000, 0x0010, 0x0000)
    c.label("sound")
    c.bytes([UInt8](repeating: 0x40, count: 8) + [UInt8](repeating: 0xC0, count: 8))
    c.bytes([UInt8](repeating: 0, count: 64))
    c.label("silence")
    c.w(0)
    for v in 0 ..< 4 {
        c.words[c.offset("songs") / 2 + 2 + v * 2] = UInt16(c.offset("list\(v)"))
    }
    return c
}

/// What Paula is told of each voice's buffers, in order.
private struct Buffers: TFMXOutput {
    var starts: [[Int]] = [[], [], [], []]
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_ voice: Int, start: Int, length _: UInt16) { starts[voice].append(start) }
    func loopCount(_: Int) -> UInt16 { 0 }
}

@Test func whittakerHubbardModulesRunFromPaulasInterrupts() throws {
    let c = hubbardModule()
    let data = bytes(c)
    #expect(WhittakerPlayer.isOne(data))
    let layout = try WhittakerModule(data)
    #expect(layout.flag == 0xFF && layout.initAt == 0 && layout.playAt == c.offset("play"))
    #expect(layout.audioInterrupt == c.offset("interrupt") && layout.setsVector == c.offset("vector"))
    #expect(layout.entrySize == 18 && layout.voices == 4 && layout.songCount == 1)
    var player = try WhittakerPlayer(data)
    try player.select(song: 0)  // (Played through first, as its renderer has it played.)
    // The second, third and fourth voices are back at the start of their lists on the second tick the
    // driver plays (the host's first tick is over before its timer first calls it), and the second's
    // counts for the first's as well, as the player has it for Rob Hubbard's modules: the song ends.
    let length = Int(player.lengthClocks ?? 0)
    #expect(abs(length - 2 * WhittakerPlayer.tickClocks) < 8)
    #expect(player.tuneInfo.format == "David Whittaker")
    // The driver's putting of its routine at the vector is gone, and the routine comes back by RTS.
    let module = Int(WhittakerPlayer.moduleAddress)
    let vector = module + c.offset("vector")
    for i in 0 ..< 3 { #expect(player.memory[vector + 2 * i] == 0x4E && player.memory[vector + 2 * i + 1] == 0x71) }
    let end = module + c.offset("voices") - 2
    #expect(player.memory[end] == 0x4E && player.memory[end + 1] == 0x75)
    // Each voice's note is pointed at silence to go on with by its interrupt, in the tick it starts.
    var told = Buffers()
    for _ in 0 ..< 2 { _ = player.run(&told) }
    let sound = module + c.offset("sound"), silence = module + c.offset("silence")
    for v in 0 ..< 4 {
        #expect(told.starts[v].contains(sound))
        #expect(told.starts[v].last == silence)
    }
    // A routine for the interrupts that does not end as the player looks for is refused.
    #expect(throws: TuneError.self) { let _ = try WhittakerPlayer(bytes(hubbardModule(rte: false))) }
}
