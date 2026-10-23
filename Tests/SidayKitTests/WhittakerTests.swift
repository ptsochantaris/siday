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

@Test func whittakerModulesThatAreDamagedAreRefusedOrPlayed() {
    let data = bytes(module())
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
    for i in 0 ..< 40 {
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
