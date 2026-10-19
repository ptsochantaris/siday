// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of Special FX's modules, on a tiny module assembled here by hand: a driver
// laid out as theirs are, assembled to run at an address other than where it is put, which the player's
// check takes, finds its way about and moves, and whose song ends as the player has it end. The thorough
// check is made outside the package: what every song of UnExoticA's modules writes to Paula, tick by
// tick, against what it writes in UADE.

private let origin: UInt32 = 0x40000

/// A module of Special FX's, as small as one can be: seven branches (to the readying of the samples, to
/// the start of a song, and to the play of a tick), the readying, which only gives A1 the end of the
/// table of instruments; a song's start, which finds the song's list in the table of songs, sets the
/// voice at its start and the first voice going on the sample, its volume set by a `LEA $A8.W,A1` (which
/// the player makes a call that gives A1 `$DFF0A8`); and a tick, which steps the voice through its list
/// of notes (periods' places in the table of periods), going back to its start at its end, and writes the
/// note's period and the volume as the driver writes them. Then the table of periods, of instruments, the
/// voice, the song and its list, and the sample.
private func module() -> AmigaCode {
    var c = AmigaCode(at: origin)
    c.w(0x6000); c.to("samples")
    for _ in 0 ..< 5 { c.w(0x6000); c.to("start") }
    c.w(0x6000); c.to("play")
    c.bytes(Array("'Tiny' music, assembled by hand".utf8) + [0])
    c.label("samples")
    c.w(0x41F9); c.address("songs") // LEA songs,A0
    c.w(0x43F9); c.address("instrumentsEnd") // LEA instrumentsEnd,A1
    c.w(0x4E75)
    c.label("start")
    c.w(0x5340, 0xB07C, 0x0001, 0x6508) // SUBQ.W #1,D0; CMP.W #1,D0; BCS.S +8
    c.w(0x4E75, 0x4E71, 0x4E71, 0x4E71)
    c.w(0x41F9); c.address("songs") // LEA songs,A0
    c.w(0xE740, 0xD0C0) // ASL.W #3,D0; ADDA.W D0,A0
    c.w(0x49F9); c.address("voice") // LEA voice,A4
    c.w(0x3018, 0x47F0, 0x00FE) // MOVE.W (A0)+,D0; LEA -2(A0,D0.W),A3
    c.w(0x294B, 0x0002, 0x294B, 0x0006) // MOVE.L A3,2(A4); MOVE.L A3,6(A4)
    c.w(0x397C, 0x0001, 0x0054) // MOVE.W #1,$54(A4)
    c.w(0x4DF9, 0x00DF, 0xF000) // LEA $DFF000,A6
    c.w(0x41F9); c.address("sample") // LEA sample,A0
    c.w(0x2D48, 0x00A0, 0x3D7C, 0x0004, 0x00A4) // MOVE.L A0,$A0(A6); MOVE.W #4,$A4(A6)
    c.w(0x43F8, 0x00A8, 0x32BC, 0x0040) // LEA $A8.W,A1; MOVE.W #64,(A1)
    c.w(0x3D7C, 0x8201, 0x0096) // MOVE.W #$8201,$96(A6)
    c.w(0x4E75)
    c.label("play")
    c.w(0x4DF9, 0x00DF, 0xF000) // LEA $DFF000,A6
    c.w(0x4BF9); c.address("periods") // LEA periods,A5
    c.w(0x49F9); c.address("voice") // LEA voice,A4
    c.w(0x266C, 0x0006, 0x101B, 0x6A0A) // MOVEA.L 6(A4),A3; MOVE.B (A3)+,D0; BPL.S note
    c.label("end")
    c.w(0x266C, 0x0002, 0xB6FC, 0x0000) // MOVEA.L 2(A4),A3; CMPA.W #0,A3: the end of the list, and back
    c.w(0x101B) // MOVE.B (A3)+,D0
    c.w(0x294B, 0x0006, 0x4880, 0xD040) // note: MOVE.L A3,6(A4); EXT.W D0; ADD.W D0,D0
    c.w(0x41F9); c.address("voice") // LEA voice,A0
    c.w(0x3175, 0x0000, 0x004A) // MOVE.W 0(A5,D0.W),$4A(A0)
    c.w(0x7640) // MOVEQ #64,D3
    c.label("volume")
    c.w(0x3D43, 0x00A8, 0x3D68, 0x004A, 0x00A6) // MOVE.W D3,$A8(A6); MOVE.W $4A(A0),$A6(A6)
    c.w(0x4E75)
    c.label("periods")
    c.w(0x01BF, 0x0150, 0x00FE, 0x007E, 0x0077)
    c.label("instruments")
    c.w(0x0000); c.address("sample"); c.w(0x0004); c.address("sample"); c.w(0x0004, 0x0000)
    c.label("instrumentsEnd")
    c.label("voice")
    c.bytes([UInt8](repeating: 0, count: 0x56))
    c.label("songs")
    c.w(0, 0, 0, 0)
    c.label("list")
    c.bytes([0, 1, 2, 0x80])
    c.label("sample")
    c.bytes([UInt8](repeating: 0x50, count: 4) + [UInt8](repeating: 0xB0, count: 4))
    // The song's voice's list, from its word in the table.
    c.words[c.offset("songs") / 2] = UInt16(c.offset("list") - c.offset("songs"))
    return c
}

@Test func specialFXModulesAreFoundTheirWayAboutAndMoved() throws {
    let c = module()
    let data = c.assembled()
    #expect(SpecialFXPlayer.isOne(data))
    let at = SpecialFXPlayer.moduleAddress
    let layout = try SpecialFXModule(data, at: at, initFix: 0x1234)
    #expect(layout.sevenBranches && layout.initAt == 16 && layout.playAt == 24)
    #expect(layout.firstCode == c.offset("samples"))
    #expect(layout.periods == c.offset("periods") && layout.codeEnd == c.offset("periods") - 2)
    #expect(layout.origin == origin)
    #expect(layout.songCount == 1 && layout.songTable == at + UInt32(c.offset("songs")))
    #expect(layout.ownInstruments == 1 && layout.leaFixes == 1)
    #expect(layout.text == "'Tiny' music, assembled by hand")
    // The driver's addresses of its own are moved to where it is put, and its instruments'.
    func long(_ bytes: [UInt8], _ i: Int) -> UInt32 {
        UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
    }
    let play = c.offset("play")
    #expect(long(layout.image, play + 8) == at + UInt32(c.offset("periods")))
    #expect(long(layout.image, c.offset("instruments") + 2) == at + UInt32(c.offset("sample")))
    // (The chips' addresses are not.)
    #expect(long(layout.image, play + 2) == 0x00DF_F000)
    // The LEA $A8.W,A1 is made a call to the module's eighth byte, a JMP to the player's code.
    #expect(Array(layout.image[8 ..< 14]) == [0x4E, 0xF9, 0, 0, 0x12, 0x34])
    // The end of the list and the writing of the volume are made calls of the player's code.
    let patched = SpecialFXPlayer.patch(layout.image, layout, SpecialFXPlayer.HostCode.made())
    let end = c.offset("end"), volume = c.offset("volume")
    #expect(patched[end] == 0x4E && patched[end + 1] == 0xB9 && patched[end + 6] == 0x4E && patched[end + 7] == 0x71)
    #expect(patched[volume] == 0x4E && patched[volume + 1] == 0xB9 && patched[volume + 6] == 0x4E && patched[volume + 7] == 0x71)
    // Not theirs: a file of six branches, or of eight, or with nothing of theirs where the first goes.
    var eight = data
    eight[28] = 0x60
    eight[29] = 0x00
    #expect(!SpecialFXPlayer.isOne(eight))
    var odd = data
    odd[3] |= 1
    #expect(!SpecialFXPlayer.isOne(odd))
    #expect(!SpecialFXPlayer.isOne([UInt8](repeating: 0, count: 256)))
    #expect(throws: TuneError.self) { let _ = try SpecialFXPlayer([UInt8](repeating: 0x60, count: 300)) }
}

/// What Paula is told, as a list.
private struct Told: TFMXOutput {
    var periods: [String] = []
    var volumes: [UInt16] = []
    var starts = 0
    mutating func on(_: Int) { starts += 1 }
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { periods.append("\(voice):\(period)") }
    mutating func writeVolume(_: Int, _ volume: UInt16) { volumes.append(volume) }
}

@Test func specialFXSongsEndAsThePlayerHasThemEnd() throws {
    var player = try SpecialFXPlayer(module().assembled())
    // The voice comes to the end of its list of three notes on the fourth tick: the song is three
    // ticks long.
    #expect(player.lengthClocks == 3 * UInt64(SpecialFXPlayer.tickClocks))
    #expect(player.tuneInfo.format == "Special FX")
    var ticks: [[String]] = []
    var volumes: [UInt16] = []
    var starts = 0
    for _ in 0 ..< 5 {
        var told = Told()
        _ = player.run(&told)
        ticks.append(told.periods)
        volumes += told.volumes
        starts += told.starts
    }
    // (The first tick is told first what the song's start wrote, which began with each voice's period
    // set to 150, as UADE's host sets them.)
    #expect(Array(ticks[0].prefix(4)) == ["0:150", "1:150", "2:150", "3:150"])
    #expect(ticks[0].last == "0:447")
    #expect(ticks[1] == ["0:336"])
    #expect(ticks[2] == ["0:254"])
    #expect(ticks[3] == ["0:447"])
    #expect(player.endings == 1)
    #expect(player.stops == 0)
    // The volume is written as the driver has it, through the player's patch (and the song's start set
    // it through the player's fix of its LEA).
    #expect(volumes.suffix(5) == [64, 64, 64, 64, 64])
    #expect(volumes.contains(64))
    #expect(starts == 1)
}

@Test func specialFXModulesAreHeard() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(SpecialFXPlayer(module().assembled()), options: options)
    #expect(renderer.subsongCount == 1)
    #expect(abs((renderer.songs[0].length ?? 0) - 3 * Double(SpecialFXPlayer.tickClocks) / Paula.clockHz) < 1e-9)
    let frames = outputSampleRate / 5
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.05)
    #expect(renderer.loopCount >= 1)
}

@Test func specialFXModulesThatAreDamagedAreRefusedOrPlayed() {
    let data = module().assembled()
    var refused = 0
    for cut in 0 ..< data.count {
        do {
            let renderer = try PaulaTickRenderer(SpecialFXPlayer(Array(data.prefix(cut))), options: LoadOptions())
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
        if let renderer = try? PaulaTickRenderer(SpecialFXPlayer(copy), options: LoadOptions()) {
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
