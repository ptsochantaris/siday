// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of Martin Walker's modules, on a tiny module assembled here by hand: a
// driver laid out as his first kind are, which the player's check takes and finds its way about, and
// whose songs end as the player has them end. The thorough check is made outside the package: what every
// one of UnExoticA's modules writes to Paula, tick by tick and song by song, against what it writes in
// UADE.

/// A module of Martin Walker's of the first kind, as small as one can be: a routine that starts the
/// song in D1 (each voice given its list of steps from the song's entry, and its first step), padded so
/// that the routine for a tick begins 148 bytes in, as his do; that routine, which for each voice plays
/// its step's period on a little sample, or at a step of $FF goes back to the start of its list, or at
/// $FE stops the music; and the routine that takes a voice's next step. Song 0's voices go round two
/// steps; song 1's play one and stop.
private func module() -> AmigaCode {
    var c = AmigaCode(at: MartinWalkerPlayer.moduleAddress)
    c.label("init")
    c.w(0x48E7, 0xFCFE) // MOVEM.L D0-D5/A0-A6,-(A7)
    c.w(0xE941, 0x7000) // ASL.W #4,D1; MOVEQ #0,D0
    c.w(0x41FA); c.to("songs") // LEA songs(PC),A0
    c.w(0x43FA); c.to("vars") // LEA vars(PC),A1
    c.w(0x2370, 0x1000, 0x0008) // MOVE.L 0(A0,D1.W),8(A1)
    c.w(0x2370, 0x1004, 0x000C) // MOVE.L 4(A0,D1.W),12(A1)
    c.w(0x7003) // MOVEQ #3,D0
    c.label("voice")
    c.w(0x3200, 0xE341) // MOVE.W D0,D1; ASL.W #1,D1
    c.w(0x4231, 0x0020) // CLR.B $20(A1,D0.W)
    c.w(0x6100); c.to("next") // BSR next
    c.w(0x51C8); c.to("voice") // DBF D0,voice
    c.w(0x50E9, 0x0001) // ST 1(A1)
    while c.here < 142 { c.w(0x4E71) }
    c.w(0x4CDF, 0x7F3F, 0x4E75) // MOVEM.L (A7)+,D0-D5/A0-A6; RTS
    c.label("play")
    c.w(0x48E7, 0xFCFE)
    c.w(0x43FA); c.to("vars")
    c.w(0x2C7C, 0x00DF, 0xF0A0) // MOVEA.L #$DFF0A0,A6
    c.w(0x4A29, 0x0001) // TST.B 1(A1)
    c.w(0x6A00); c.to("out") // BPL out
    c.w(0x7003)
    c.label("loop")
    c.w(0x3200, 0x3400, 0x3600) // MOVE.W D0,D1; MOVE.W D0,D2; MOVE.W D0,D3
    c.label("shifts")
    c.w(0xE341, 0xE543, 0xE942) // ASL.W #1,D1; ASL.W #2,D3; ASL.W #4,D2
    c.w(0x0C31, 0x00FE, 0x0024) // CMPI.B #$FE,$24(A1,D0.W)
    c.w(0x6532) // BCS.S note
    c.w(0x6616) // BNE.S jump
    c.w(0x4229, 0x0001) // CLR.B 1(A1)
    c.label("stop")
    c.w(0x4279, 0x00DF, 0xF0D8) // CLR.W $DFF0D8
    c.w(0x33FC, 0x000F, 0x00DF, 0xF096) // MOVE.W #15,$DFF096
    c.w(0x6000); c.to("out") // BRA out
    c.w(0x4231, 0x0020) // jump: CLR.B $20(A1,D0.W)
    c.w(0x6100); c.to("next") // BSR next
    for _ in 0 ..< 9 { c.w(0x4E71) }
    c.label("note")
    c.w(0x7A00, 0x1A31, 0x0024, 0xDA45) // MOVEQ #0,D5; MOVE.B $24(A1,D0.W),D5; ADD.W D5,D5
    c.w(0x45FA); c.to("periods") // LEA periods(PC),A2
    c.w(0x3DB2, 0x5000, 0x2006) // MOVE.W 0(A2,D5.W),6(A6,D2.W)
    c.w(0x7A00)
    c.w(0x45FA); c.to("sampleTable")
    c.w(0x2A32, 0x5000) // MOVE.L 0(A2,D5.W),D5
    c.w(0x45FA); c.to("sample")
    c.w(0xD5C5, 0x2D8A, 0x2000) // ADDA.L D5,A2; MOVE.L A2,0(A6,D2.W)
    c.w(0x3DBC, 0x0008, 0x2004) // MOVE.W #8,4(A6,D2.W)
    c.w(0x3DBC, 0x0040, 0x2008) // MOVE.W #64,8(A6,D2.W)
    c.w(0x6100); c.to("next")
    c.w(0x51C8); c.to("loop") // DBF D0,loop
    c.label("wait")
    c.w(0x203C, 0x0000, 0x00FF, 0x51C8, 0xFFFE) // MOVE.L #$FF,D0; DBF D0,*
    c.w(0x33FC, 0x820F, 0x00DF, 0xF096) // MOVE.W #$820F,$DFF096
    c.label("out")
    c.w(0x4CDF, 0x7F3F, 0x4E75)
    c.label("next")
    c.w(0x49FA); c.to("steps") // LEA steps(PC),A4
    c.w(0x7A00, 0x1A31, 0x0020) // MOVEQ #0,D5; MOVE.B $20(A1,D0.W),D5
    c.w(0x5231, 0x0020) // ADDQ.B #1,$20(A1,D0.W)
    c.w(0xDA71, 0x1008) // ADD.W 8(A1,D1.W),D5
    c.w(0x13B4, 0x5000, 0x0024) // MOVE.B 0(A4,D5.W),$24(A1,D0.W)
    c.w(0x4E75)
    c.label("vars")
    c.bytes([UInt8](repeating: 0, count: 0x28))
    c.label("songs")
    c.w(0, 0, 0, 0, 0, 0, 0, 0)
    c.w(4, 4, 4, 4, 0, 0, 0, 0)
    c.label("steps")
    c.bytes([1, 2, 0xFF, 0, 1, 0xFE])
    c.label("sampleTable")
    c.w(0x0000, 0x0000)
    c.label("sample")
    c.bytes([UInt8](repeating: 0x40, count: 8) + [UInt8](repeating: 0xC0, count: 8))
    while c.here < c.offset("next") + 280 { c.w(0) }
    c.label("periods")
    c.w(0x069F, 0x0100, 0x0200)
    c.bytes([UInt8](repeating: 0, count: 64))
    return c
}

@Test func martinWalkerModulesAreFoundTheirWayAbout() throws {
    let c = module()
    let data = c.assembled()
    #expect(c.offset("play") == 148)
    #expect(MartinWalkerPlayer.isOne(data))
    #expect(MartinWalkerModule.check(data) == false)
    #expect(!MartinWalkerModule.setsUp(data))
    let layout = try MartinWalkerModule(data, fifth: false)
    #expect(layout.initAt == 0 && layout.playAt == 148)
    #expect(layout.songTable == c.offset("songs") && layout.steps == c.offset("steps") && layout.songCount == 2)
    #expect(layout.stepOffset == 0x24 && layout.volumeOffset == 0x32)
    #expect(layout.searchLength == c.offset("periods") - 250)
    // The stopping of the music, the start of each voice's part of a tick and the wait for the DMA are
    // made calls of the player's code.
    let routines = MartinWalkerPlayer.patches(layout)
    let patched = layout.patched(data, routines: routines.indices.map { 0x2000 + UInt32($0) * 0x100 },
                                 patterns: routines.map(\.pattern))
    for at in [c.offset("stop"), c.offset("shifts"), c.offset("wait")] {
        #expect(patched[at] == 0x4E && patched[at + 1] == 0xB9)
    }
    #expect(Array(patched[c.offset("wait") + 6 ..< c.offset("wait") + 10]) == [0x4E, 0x71, 0x4E, 0x71])
    #expect(patched.count == data.count)
    // Not his: a file that begins otherwise, or is nothing.
    #expect(!MartinWalkerPlayer.isOne([0x4E, 0x71] + Array(data.dropFirst(2))))
    #expect(!MartinWalkerPlayer.isOne([UInt8](repeating: 0, count: 512)))
    #expect(!MartinWalkerPlayer.isOne(Array(data.prefix(200))))
    #expect(throws: TuneError.self) { let _ = try MartinWalkerPlayer([UInt8](repeating: 0x60, count: 600)) }
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

@Test func martinWalkerSongsEndAsThePlayerHasThemEnd() throws {
    var player = try MartinWalkerPlayer(module().assembled())
    // Every voice is at the end of its list on the third tick, and goes back: the song is two ticks long.
    #expect(player.lengthClocks == 2 * UInt64(MartinWalkerPlayer.tickClocks))
    #expect(player.tuneInfo.format == "Martin Walker")
    #expect(player.songCount == 2)
    var ticks: [[String]] = []
    var starts = 0
    for _ in 0 ..< 4 {
        var told = Told()
        _ = player.run(&told)
        ticks.append(told.periods)
        starts += told.starts
    }
    // (The first tick is told first of UADE's host's setting each voice's period to 150.)
    #expect(Array(ticks[0].prefix(4)) == ["0:150", "1:150", "2:150", "3:150"])
    #expect(Array(ticks[0].suffix(4)) == ["3:256", "2:256", "1:256", "0:256"])
    #expect(ticks[1] == ["3:512", "2:512", "1:512", "0:512"])
    #expect(ticks[2] == ["3:256", "2:256", "1:256", "0:256"])
    #expect(ticks[3] == ["3:512", "2:512", "1:512", "0:512"])
    #expect(player.endings == 1)
    #expect(player.stops == 0)
    #expect(starts == 4)
    // The second song plays a step and stops the music, which is its end.
    try player.select(song: 1)
    #expect(player.lengthClocks == UInt64(MartinWalkerPlayer.tickClocks))
    var told = Told()
    _ = player.run(&told)
    #expect(told.periods.suffix(4) == ["3:256", "2:256", "1:256", "0:256"])
    #expect(player.stops == 0)
    _ = player.run(&told)
    #expect(player.stops == 1)
    #expect(throws: TuneError.self) { try player.select(song: 2) }
}

@Test func martinWalkerModulesAreHeard() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(MartinWalkerPlayer(module().assembled()), options: options)
    #expect(renderer.subsongCount == 2)
    #expect(abs((renderer.songs[0].length ?? 0) - 2 * Double(MartinWalkerPlayer.tickClocks) / Paula.clockHz) < 1e-9)
    let frames = outputSampleRate / 5
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.05)
    #expect(renderer.loopCount >= 1)
}

@Test func martinWalkerModulesThatAreDamagedAreRefusedOrPlayed() {
    let data = module().assembled()
    var refused = 0
    for cut in 0 ..< data.count {
        do {
            let renderer = try PaulaTickRenderer(MartinWalkerPlayer(Array(data.prefix(cut))), options: LoadOptions())
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2000)
            renderer.render(into: buffer, frames: 1000)
            buffer.deallocate()
        } catch {
            refused += 1
        }
    }
    #expect(refused > 0)
    var generator = SplitMix(seed: 11)
    // (Few, for each that plays may be a song that never ends, played through as it is loaded.)
    for i in 0 ..< 40 {
        var copy = data
        for _ in 0 ... i % 6 { copy[Int(generator.next() % UInt64(copy.count))] = UInt8(truncatingIfNeeded: generator.next()) }
        if let renderer = try? PaulaTickRenderer(MartinWalkerPlayer(copy), options: LoadOptions()) {
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
