// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of Ben Daglish's modules, on a tiny module assembled here by hand: a driver
// laid out as his are, which the player's check takes and finds its way about, whose songs end as the
// player has them end, which the player changes as it changes his, and which stops a sample by Paula's
// interrupt. The thorough check is made outside the package: what every one of UnExoticA's modules
// writes to Paula, tick by tick and song by song, against what it writes in UADE.

/// A module of Ben Daglish's, as small as one can be: the table of branches and the byte kept set while
/// a song plays; a routine that stops the music; one that starts a song, taking from the table of songs
/// how many ticks it lasts; and one that plays a tick, clearing the byte once the song's ticks are done.
/// On a song's first tick it starts a short sample on the first voice (by a routine that shuts out
/// interrupts, and a volume set as his earliest drivers set it, a quarter of what it is given); on the
/// second it clears and enables the voice's interrupt, so that she is stopped as the sample ends; on the
/// third it keeps what DMACONR says.
private func module() -> AmigaCode {
    var c = AmigaCode(at: DaglishPlayer.moduleAddress)
    c.w(0x6000); c.to("init")
    c.w(0x6000); c.to("play")
    c.label("flag")
    c.w(0x0000)
    c.w(0x6000); c.to("stop")
    c.label("stop")
    c.w(0x4DF9, 0x00DF, 0xF000) // LEA $DFF000,A6
    c.w(0x3D7C, 0x000F, 0x0096) // MOVE.W #$F,150(A6)
    c.w(0x4E75)
    c.label("init")
    c.w(0x3F00) // MOVE.W D0,-(A7)
    c.w(0x6100); c.to("stop") // BSR.W stop
    c.w(0x3D7C, 0x00FF, 0x009E) // MOVE.W #$FF,158(A6)
    c.w(0x41FA); c.to("flag") // LEA flag(PC),A0
    c.w(0x10BC, 0x00FF) // MOVE.B #$FF,(A0)
    c.w(0x3D7C, 0x0780, 0x009C) // MOVE.W #$780,156(A6)
    c.w(0x3D7C, 0x0780, 0x009A) // MOVE.W #$780,154(A6)
    c.w(0x3D7C, 0xC000, 0x009A) // MOVE.W #$C000,154(A6)
    c.w(0x301F) // MOVE.W (A7)+,D0
    c.w(0xD040, 0xD040, 0xD040) // ADD.W D0,D0, three times
    c.w(0x41FA); c.to("songs") // LEA songs(PC),A0
    c.w(0x41F0, 0x0000) // LEA 0(A0,D0.W),A0
    c.w(0x43FA); c.to("counter") // LEA counter(PC),A1
    c.w(0x3290) // MOVE.W (A0),(A1)
    c.w(0x41FA); c.to("samples") // LEA samples(PC),A0
    c.w(0x4E75)
    c.label("play")
    c.w(0x4DF9, 0x00DF, 0xF000) // LEA $DFF000,A6
    c.w(0x43FA); c.to("counter") // LEA counter(PC),A1
    c.w(0x5351) // SUBQ.W #1,(A1)
    c.w(0x6A08) // BPL.S +8
    c.w(0x41FA); c.to("flag") // LEA flag(PC),A0
    c.w(0x4210) // CLR.B (A0)
    c.w(0x4E75)
    c.w(0x0C51, 0x0009) // CMPI.W #9,(A1)
    c.w(0x6600); c.to("second") // BNE.W second
    c.w(0x6100); c.to("masked") // BSR.W masked
    c.w(0x41FA); c.to("sound") // LEA sound(PC),A0
    c.w(0x2D48, 0x00A0) // MOVE.L A0,$A0(A6)
    c.w(0x3D7C, 0x0020, 0x00A4) // MOVE.W #32,$A4(A6)
    c.w(0x3D7C, 0x00C8, 0x00A6) // MOVE.W #200,$A6(A6)
    c.w(0x45EE, 0x00A0) // LEA $A0(A6),A2
    c.w(0x7040) // MOVEQ #64,D0
    c.label("louder")
    c.w(0xE448) // LSR.W #2,D0
    c.label("volume")
    c.w(0x3540, 0x0008, 0x234B, 0x001A) // MOVE.W D0,8(A2); MOVE.L A3,26(A1)
    c.w(0x3D7C, 0x8201, 0x0096) // MOVE.W #$8201,150(A6)
    c.w(0x4E75)
    c.label("second")
    c.w(0x0C51, 0x0008) // CMPI.W #8,(A1)
    c.w(0x6600); c.to("third") // BNE.W third
    c.w(0x3D7C, 0x0080, 0x009C) // MOVE.W #$80,156(A6)
    c.w(0x3D7C, 0x8080, 0x009A) // MOVE.W #$8080,154(A6)
    c.w(0x4E75)
    c.label("third")
    c.w(0x0C51, 0x0007) // CMPI.W #7,(A1)
    c.w(0x6600); c.to("done") // BNE.W done
    c.w(0x336E, 0x0002, 0x0004) // MOVE.W 2(A6),4(A1)
    c.label("done")
    c.w(0x4E75)
    c.label("masked")
    c.w(0x40E7, 0x007C, 0x0700) // MOVE SR,-(A7); ORI #$700,SR
    c.w(0x4E71)
    c.label("rte")
    c.w(0x4E73) // RTE
    c.label("counter")
    for _ in 0 ..< 16 { c.w(0) }
    c.label("songs")
    c.w(10, 0, 0, 0)
    c.w(3, 0, 0, 0)
    c.w(0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF)
    c.label("samples")
    c.w(0, 0)
    c.label("sound")
    c.bytes([UInt8](repeating: 0x40, count: 32) + [UInt8](repeating: 0xC0, count: 32))
    c.bytes([UInt8](repeating: 0, count: 64))
    return c
}

@Test func daglishModulesAreFoundTheirWayAbout() throws {
    let c = module()
    let data = c.assembled()
    #expect(DaglishPlayer.isOne(data))
    let layout = try DaglishModule(data)
    #expect(layout.songTable == c.offset("songs") && layout.songCount == 2)
    #expect(layout.samples == c.offset("samples"))
    #expect(layout.changes.contains { $0.change == .earlyVolume(louder: true) && $0.at == c.offset("volume") })
    #expect(layout.changes.contains { $0.change == .masking && $0.at == c.offset("masked") })
    #expect(layout.changes.contains { $0.change == .returnFromException && $0.at == c.offset("rte") })
    // The player's changes: NOPs for the masking and the quartering, an RTS for the RTE, and a call of
    // its own routine in place of the volume's setting.
    let patched = DaglishPlayer.patch(data, layout).image
    let masked = c.offset("masked"), rte = c.offset("rte"), volume = c.offset("volume"), louder = c.offset("louder")
    #expect(Array(patched[masked ..< masked + 6]) == [0x4E, 0x71, 0x4E, 0x71, 0x4E, 0x71])
    #expect(Array(patched[rte ..< rte + 2]) == [0x4E, 0x75])
    #expect(Array(patched[louder ..< louder + 2]) == [0x4E, 0x71])
    #expect(Array(patched[volume ..< volume + 4]) == [0x4E, 0x71, 0x4E, 0xB9])
    // Not his: a file without the table of branches, or whose first goes nowhere his drivers go.
    #expect(!DaglishPlayer.isOne([UInt8](repeating: 0, count: 256)))
    var wrong = data
    wrong[c.offset("init")] = 0x4E
    #expect(!DaglishPlayer.isOne(wrong))
    #expect(throws: TuneError.self) { let _ = try DaglishPlayer([UInt8](repeating: 0x60, count: 300)) }
}

/// What Paula is told, as a list.
private struct Told: TFMXOutput {
    var volumes: [UInt16] = []
    var starts: [Int] = []
    var stops: [Int] = []
    mutating func on(_ voice: Int) { starts.append(voice) }
    mutating func off(_ voice: Int) { stops.append(voice) }
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func writeVolume(_: Int, _ volume: UInt16) { volumes.append(volume) }
}

@Test func daglishSongsEndAsThePlayerHasThemEnd() throws {
    var player = try DaglishPlayer(module().assembled())
    try player.select(song: player.song)  // (Played through first, as its renderer has it played.)
    #expect(player.tuneInfo.format == "Ben Daglish")
    #expect(player.songCount == 2)
    // Ten ticks of the song, and the one that finds it over: its last.
    #expect(player.lengthClocks == 11 * UInt64(DaglishPlayer.tickClocks))
    for _ in 0 ..< 11 {
        var told = Told()
        _ = player.run(&told)
    }
    #expect(player.endings == 1)
    #expect(player.stops == 0)
    try player.select(song: 1)
    #expect(player.lengthClocks == 4 * UInt64(DaglishPlayer.tickClocks))
}

@Test func daglishSamplesAreStoppedByPaulasInterrupt() throws {
    let c = module()
    var player = try DaglishPlayer(c.assembled())
    try player.select(song: player.song)  // (Played through first, as its renderer has it played.)
    var first = Told()
    _ = player.run(&first)
    // The voice is set going, at the volume the player gives it (not the quarter the driver would).
    #expect(first.starts == [0])
    #expect(first.volumes.last == 64)
    #expect(player.answered == 0)
    // Her interrupt enabled, she is stopped as she comes to the end of the sample.
    var second = Told()
    _ = player.run(&second)
    #expect(second.stops == [0])
    #expect(player.answered == 1)
    // And the driver finds her DMA off.
    var third = Told()
    _ = player.run(&third)
    let at = Int(DaglishPlayer.moduleAddress) + c.offset("counter") + 4
    #expect(player.memory[at + 1] & 1 == 0)
    #expect(player.memory[at] & 2 != 0)
}

@Test func daglishModulesAreHeard() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(DaglishPlayer(module().assembled()), options: options)
    #expect(renderer.subsongCount == 2)
    let frames = outputSampleRate / 10
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.01)
}

@Test func daglishModulesThatAreDamagedAreRefusedOrPlayed() {
    let data = module().assembled()
    var refused = 0
    for cut in 0 ..< data.count {
        do {
            let renderer = try PaulaTickRenderer(DaglishPlayer(Array(data.prefix(cut))), options: LoadOptions())
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2000)
            renderer.render(into: buffer, frames: 1000)
            buffer.deallocate()
        } catch {
            refused += 1
        }
    }
    #expect(refused > 0)
    var generator = SplitMix(seed: 11)
    for i in 0 ..< 60 {
        var copy = data
        for _ in 0 ... i % 6 { copy[Int(generator.next() % UInt64(copy.count))] = UInt8(truncatingIfNeeded: generator.next()) }
        if let renderer = try? PaulaTickRenderer(DaglishPlayer(copy), options: LoadOptions()) {
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
