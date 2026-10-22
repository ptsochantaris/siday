// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of Pierre Adane's packed modules, on tiny modules made here. The thorough
// check is made outside the package: what it tells Paula, tick by tick, against UADE's running of the
// original player, for every module of UnExoticA's collection.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

/// A Pierre Adane Packer module of one position: voice 0's pattern is `note` (a period, its sample and
/// command, and the parameter) followed by 63 empty rows, the others' a pattern of 64 empty rows. Its
/// one sample is 16 words long, at volume 48, with `loop` (offset, length) for its loop.
private func pap(note: [UInt8] = [0x01, 0xAC, 0x10, 0x00], loop: (Int, Int) = (0, 1), samples: Int = 1) -> [UInt8] {
    var table: [UInt8] = []
    for _ in 0 ..< samples { table += word(16) + word(48) + word(loop.0) + word(loop.1) }
    let first = 8 + table.count + 2
    let empty = first + 6
    let lists = empty + 6
    var bytes = word(lists) + word(lists + 4) + word(lists + 6) + word(lists + 8)
    bytes += table + [0xFF, 0x00]
    bytes += [0xFF, 0x40] + note
    bytes += [0xFF, 0x40, 0, 0, 0, 0]
    bytes += word(first) + word(0) + word(empty) + word(empty) + word(empty)
    return bytes
}

private let samples: [UInt8] = (0 ..< 32).map { UInt8($0 * 8) }

@Test func papModulesAreKnown() {
    #expect(PAPPlayer.isOne(pap()))
    #expect(!PAPPlayer.isOne([UInt8](repeating: 0, count: 64)))
    #expect(!PAPPlayer.isOne(Array(pap().dropLast(2))))
    // A pattern of the lists beyond the first list is not taken.
    var beyond = pap()
    beyond[beyond.count - 1] = 0x60
    #expect(!PAPPlayer.isOne(beyond))
}

@Test func papRowsComeAtTheSpeed() throws {
    var player = try PAPPlayer(pap(), samples: samples)
    var ticks: [[String]] = []
    for _ in 0 ..< 4 {
        var out = Recorder()
        player.run(&out)
        ticks.append(out.events)
    }
    // The first row is the third tick's: the note is started, and told to play its first word after it.
    let at = player.samplesAt
    #expect(ticks[0].isEmpty && ticks[1].isEmpty)
    #expect(ticks[2] == ["off 0", "buffer 0 \(at) 16", "on 0", "buffer 0 \(at) 1"])
    #expect(ticks[3] == ["on 0"])
    #expect(player.period(0) == 0x1AC)
    #expect(player.volume(0) == 48)
    // The sample's first four bytes are made nought.
    #expect(player.memory[at] == 0 && player.memory[at + 3] == 0 && player.memory[at + 4] == 32)
}

@Test func papLoopsAndCommands() throws {
    // A sample with a loop is played from it, for its length, and not told anything after.
    var looped = try PAPPlayer(pap(loop: (8, 4)), samples: samples)
    var out = Recorder()
    for _ in 0 ..< 3 { looped.run(&out) }
    #expect(out.events == ["off 0", "buffer 0 \(looped.samplesAt + 8) 4", "on 0"])
    // Command C sets the volume; 1 slides the period up on each tick after the row's.
    var loud = try PAPPlayer(pap(note: [0x01, 0xAC, 0x1C, 0x20]), samples: samples)
    for _ in 0 ..< 3 { loud.run(&out) }
    #expect(loud.volume(0) == 0x20)
    var slide = try PAPPlayer(pap(note: [0x01, 0xAC, 0x11, 0x03]), samples: samples)
    for _ in 0 ..< 5 { slide.run(&out) }
    #expect(slide.period(0) == 0x1AC - 6)
}

@Test func papSongLength() throws {
    // 64 rows of three ticks, after the two before the first row.
    let player = try PAPPlayer(pap(), samples: samples)
    #expect(player.lengthTicks == 2 + 64 * 3)
    #expect(player.lengthClocks == UInt64((2 + 64 * 3) * 70940))
}

@Test func papOddModulesNeitherHangNorTrap() throws {
    // A speed set below the tick the row is at, an arpeggio at every tick, a sample the module has not,
    // and a samples file cut short.
    for note: [UInt8] in [[0x01, 0xAC, 0x1F, 0x01], [0x01, 0xAC, 0x10, 0x37], [0x01, 0xAC, 0x5F, 0x0F], [0x01, 0xAB, 0x10, 0x11]] {
        for smp in [samples, [], [1, 2, 3]] {
            var player = try PAPPlayer(pap(note: note), samples: smp)
            var out = Recorder()
            for _ in 0 ..< 3000 { player.run(&out) }
        }
    }
}

@Test func papRefusals() {
    #expect(throws: TuneError.self) { try PAPPlayer(pap(), samples: nil) }
    #expect(throws: TuneError.self) { try PAPPlayer(pap(samples: 16), samples: samples) }
    #expect(throws: TuneError.self) { try PAPPlayer([UInt8](repeating: 0, count: 64), samples: samples) }
    do {
        _ = try PAPPlayer(pap(), samples: nil)
    } catch {
        guard case .missingCompanion = error else { Issue.record("not a missing companion: \(error)"); return }
    }
}

@Test func papPlaysThroughTheRenderer() throws {
    let renderer = try PaulaTickRenderer(try PAPPlayer(pap(loop: (0, 16)), samples: samples), options: LoadOptions())
    #expect(renderer.info.format == "PAP")
    let frames = 4800
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.01)
}
