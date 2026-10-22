// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of PumaTracker's modules, on tiny modules made here. The thorough check is
// made outside the package: what it tells Paula, tick by tick, against UADE's running of the original
// player, for every module of UnExoticA's collection.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

/// A PumaTracker module of one order at `speed`: voice 0 plays note 24 of instrument 1 for the order's
/// 32 rows, the others an empty pattern. The instrument's volume script is `volume`, its pitch script
/// `pitch`; its one sample is 200 words long.
private func puma(speed: UInt8 = 6, volume: [UInt8] = [0xC0, 0x0A, 0, 0, 0xA0, 0x40, 0x40, 0x10, 0xE0, 0, 0, 0],
                  pitch: [UInt8] = [0xD0, 0, 0, 1, 0xE0, 0, 0, 0], rows: [UInt8] = [24, 1, 0, 32]) -> [UInt8] {
    let order: [UInt8] = [0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, speed, 0]
    let patterns = Array("patt".utf8) + rows + Array("patt".utf8) + [0, 0, 0, 32] + Array("patt".utf8)
    let instrument = Array("inst".utf8) + volume + Array("insf".utf8) + pitch + Array("inst".utf8)
    var bytes = Array("tiny".utf8) + [UInt8](repeating: 0, count: 8)
    bytes += word(0) + word(2) + word(1) + word(0)
    let sampleAt = 80 + order.count + patterns.count + instrument.count
    bytes += long(sampleAt) + [UInt8](repeating: 0, count: 36)
    bytes += word(200) + [UInt8](repeating: 0, count: 18)
    bytes += order + patterns + instrument
    return bytes + (0 ..< 400).map { UInt8(truncatingIfNeeded: $0 * 5) }
}

@Test func pumaModulesAreKnown() {
    #expect(PumaPlayer.isOne(puma()))
    // The first pattern's rows must come to 32.
    #expect(!PumaPlayer.isOne(puma(rows: [24, 1, 0, 31])))
    #expect(!PumaPlayer.isOne([UInt8](repeating: 0, count: 200)))
    #expect(!PumaPlayer.isOne(Array(puma().prefix(90))))
}

@Test func pumaFirstTickTellsPaula() throws {
    var player = try PumaPlayer(puma())
    var out = Recorder()
    player.run(&out)
    // Voice 0 is started on the player's first waveform; the others, with no note, are not.
    #expect(out.events == ["off 0", "buffer 0 \(player.wavesAt) 16", "off 1", "off 2", "off 3", "on 0"])
    #expect(player.period(0) == PumaTables.periods[12])
    // The ramp's first volume, $40, and the row's, $40, which leaves it as it is.
    #expect(player.volume(0) == 0x40)
    #expect(player.voices[0].flags & 4 != 0)
}

@Test func pumaRampsAndEnds() throws {
    // A ramp from $40 to $20 over 16 ticks, then the end of the voice.
    var player = try PumaPlayer(puma(volume: [0xC0, 0x0A, 0, 0, 0xA0, 0x40, 0x20, 0x10, 0xE0, 0, 0, 0]))
    var volumes: [UInt16] = []
    for _ in 0 ..< 20 {
        var out = Recorder()
        player.run(&out)
        volumes.append(player.volume(0))
    }
    #expect(volumes[0] == 0x40)
    #expect(volumes[8] == 0x30)
    #expect(volumes[16] == 0x20)
    #expect(volumes[17] == 0)
    #expect(player.voices[0].flags & 4 == 0)
}

@Test func pumaSamplesArePlayedOnce() throws {
    // Wave 0 is the module's sample, of 200 words: told once, and then a word of it.
    let module = puma(volume: [0xC0, 0, 0, 0, 0xA0, 0x40, 0x40, 0x10, 0xE0, 0, 0, 0])
    var player = try PumaPlayer(module)
    var first = Recorder(), second = Recorder()
    player.run(&first)
    player.run(&second)
    let at = Int(module[22]) << 8 | Int(module[23])
    #expect(first.events.contains("buffer 0 \(at) 200"))
    #expect(second.events.contains("buffer 0 \(at) 1"))
}

@Test func pumaPitchRampsAndSlides() throws {
    // A ramp from four above the note's period to four below it, over four ticks.
    var player = try PumaPlayer(puma(pitch: [0xA0, 4, 0xFC, 4, 0xE0, 0, 0, 0]))
    let note = Int(PumaTables.periods[12])
    var periods: [Int] = []
    for _ in 0 ..< 6 {
        var out = Recorder()
        player.run(&out)
        periods.append(Int(player.period(0)))
    }
    #expect(periods == [note + 4, note + 2, note, note - 2, note - 2, note - 2])
    // A row's slide down ($40) adds to the period on every tick.
    var slid = try PumaPlayer(puma(rows: [24, 0x41, 3, 32]))
    var out = Recorder()
    slid.run(&out)
    slid.run(&out)
    #expect(slid.period(0) == PumaTables.periods[12] + 6)
}

@Test func pumaSongLength() throws {
    let player = try PumaPlayer(puma(speed: 5))
    #expect(player.lengthTicks == 32 * 5)
    #expect(player.lengthClocks == UInt64(32 * 5 * 70940))
    var counting = try PumaPlayer(puma(speed: 5))
    var out = Recorder()
    for _ in 0 ..< 32 * 5 { counting.run(&out) }
    #expect(counting.endings == 0)
    counting.run(&out)
    #expect(counting.endings == 1)
}

@Test func pumaOddScriptsNeitherHangNorTrap() throws {
    // A volume script that jumps to itself, a pitch ramp of no ticks, a wave beyond the player's,
    // a pattern and an instrument the module has not: each tick ends, and nothing is read from outside.
    let odd: [[UInt8]] = [[0xB0, 0, 0, 0], [0xC0, 0xFF, 0x80, 0x7F, 0xB0, 4, 0, 0], [0xC0, 0x0A, 1, 0xFF, 0xA0, 0, 0xFF, 0xFF, 0xB0, 4, 0, 0]]
    for volume in odd {
        var player = try PumaPlayer(puma(volume: volume, pitch: [0xA0, 0x7F, 0x80, 0, 0xB0, 0, 0, 0]))
        var out = Recorder()
        for _ in 0 ..< 2000 { player.run(&out) }
    }
    var notes = puma(rows: [0xFE, 0x1F, 0x20, 32])
    notes[80] = 200
    var player = try PumaPlayer(notes)
    var out = Recorder()
    for _ in 0 ..< 500 { player.run(&out) }
}

@Test func pumaRefusals() {
    // No instruments, or samples beyond the end of the file.
    var none = puma()
    none[17] = 0
    #expect(throws: TuneError.self) { try PumaPlayer(none) }
    #expect(throws: TuneError.self) { try PumaPlayer(Array(puma().dropLast(10))) }
    #expect(throws: TuneError.self) { try PumaPlayer([UInt8](repeating: 0, count: 100)) }
}

@Test func pumaPlaysThroughTheRenderer() throws {
    let renderer = try PaulaTickRenderer(try PumaPlayer(puma()), options: LoadOptions())
    #expect(renderer.info.format == "PUMA")
    #expect(renderer.info.title == "tiny")
    let frames = 4800
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.01)
    #expect(renderer.songs.first?.length != nil)
}
