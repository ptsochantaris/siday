// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the Leggless Music Editor's player, on tiny files made here as the editor's are. The thorough
// check is made outside the package: what it tells Paula, tick by tick, against what Wanted Team's player tells
// her in UADE, for every song of every one of UnExoticA's files.

/// What Paula is told, as a list (the moments in the tick, and the periods and volumes, left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

/// Where the parts are: the instruments (two), the four lists, the table of patterns, the patterns, the samples.
private let instrumentsAt = 0x48
private let listsAt = instrumentsAt + 2 * 58
private let tableAt = listsAt + 4 * 4
private let patternsAt = tableAt + 8
private let samplesAt = patternsAt + 64

/// An instrument's 58 bytes: its sample's place, length, volume and loop, no vibrato, its envelope's six words,
/// its wave's eight, and no starting again.
private func instrument(place: Int, length: Int, volume: Int, loop: Int, loopLength: Int, envelope: [Int], wave: [Int]) -> [UInt8] {
    long(place) + word(length) + word(volume) + long(loop) + word(loopLength) + [UInt8](repeating: 0, count: 12)
        + envelope.flatMap { word($0) } + wave.flatMap { word($0) } + [UInt8](repeating: 0, count: 4)
}

/// A file of one song: voice 2 plays pattern 0 (`notes`, then a rest of four ticks), the others pattern 1 (a rest
/// of eight). Instrument 0 is the sample (eight words, at volume 40, going round whole) rising by 8 to 64, held
/// for two ticks and falling by 4 to 20; instrument 1 a wave of sixteen words, its width from 4 by 2 to 12, its
/// levels $40 and $C0.
private func file(_ notes: [Int]) -> [UInt8] {
    var bytes = Array("LME".utf8) + [0] + [UInt8](repeating: 0x20, count: 32) + long(0)
    bytes += long(instrumentsAt - 0x28) + long(tableAt - 0x28) + long(patternsAt - 0x28) + long(samplesAt - 0x28)
    bytes += long(listsAt - 0x28) + long(listsAt + 4 - 0x28) + long(listsAt + 8 - 0x28) + long(listsAt + 12 - 0x28)
    bytes += instrument(place: 4, length: 8, volume: 40, loop: 4, loopLength: 8, envelope: [1, 8, 64, 2, 4, 20], wave: [Int](repeating: 0, count: 8))
    bytes += instrument(place: 0, length: 16, volume: 64, loop: 0, loopLength: 2, envelope: [Int](repeating: 0, count: 6),
                        wave: [1, 4, 2, 12, 2, 4, 0x40, 0xC0])
    bytes += word(1) + word(0xFFFF) + word(1) + word(0xFFFF) + word(0) + word(0xFFFF) + word(1) + word(0xFFFF)
    bytes += long(0) + long(32)
    let pattern = notes.flatMap { word($0) } + word(1) + word(4) + word(0xFFFF)
    bytes += pattern + [UInt8](repeating: 0, count: 32 - pattern.count)
    bytes += word(1) + word(8) + word(0xFFFF) + [UInt8](repeating: 0, count: 26)
    bytes += [0, 0, 0, 0] + (0 ..< 16).map { UInt8($0 * 9 + 2) }
    return bytes
}

@Test func lmeDetection() throws {
    let made = file([2, 0, 4, 12])
    #expect(made.count == samplesAt + 20)
    #expect(LMEPlayer.isOne(made))
    var other = made
    other[38] = 1
    #expect(!LMEPlayer.isOne(other))
    let player = try LMEPlayer(made)
    #expect(player.songCount == 1 && player.instrumentCount == 2 && player.syntheticCount == 1)
    var asked = try LMEPlayer(made)
    #expect(throws: TuneError.self) { try asked.select(song: 1) }
}

/// A note is begun on its first tick: the voice turned off, told its sample, and turned on at the tick's end;
/// on the next, told its loop. Its envelope rises from its volume, is held and falls; and Wanted Team's player,
/// asked for, sets the note's volume to eight times its voice's number for its first tick.
@Test func lmeNoteReachesPaula() throws {
    var player = try LMEPlayer(file([2, 0, 4, 12]))
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == ["off 0", "off 1", "off 2", "buffer 2 \(samplesAt + 4) 8", "off 3", "on 2"])
    #expect(player.periodWritten(2) == 0x1AC && player.volumeWritten(2) == 40)
    var second = Recorder()
    _ = player.run(&second)
    #expect(second.events == ["buffer 2 \(samplesAt + 4) 8"])
    var volumes: [UInt16] = [player.volumeWritten(2)]
    for _ in 0 ..< 6 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        volumes.append(player.volumeWritten(2))
    }
    // (Up by 8 from 40 to 64, held for two ticks and the one that ends the holding, and down by 4.)
    #expect(volumes == [48, 56, 64, 64, 64, 64, 60])

    var wanted = try LMEPlayer(file([2, 0, 4, 12]), wantedTeamsVolumes: true)
    var none = TFMXSilentOutput()
    _ = wanted.run(&none)
    #expect(wanted.volumeWritten(2) == 16)
}

/// The player's wave: as many bytes of its high level as its width less one, then its low, to twice its length.
@Test func lmeMakesItsWave() throws {
    var player = try LMEPlayer(file([2, 1, 4, 12]))
    var first = Recorder()
    _ = player.run(&first)
    let wave = player.wavesAt + 2 * 128
    #expect(first.events.contains("buffer 2 \(wave) 16"))
    #expect((0 ..< 5).allSatisfy { player.memory[wave + $0] == 0x40 })
    #expect((5 ..< 32).allSatisfy { player.memory[wave + $0] == 0xC0 })
    #expect(player.memory[wave + 32] == 0)
}

/// The song comes to its end when all four voices have come to the end of their lists: eight ticks here.
@Test func lmeSongEnds() throws {
    var player = try LMEPlayer(file([2, 0, 4, 12]))
    #expect(player.lengthClocks == UInt64(8 * TFMXTiming.fiftyTimes))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 8 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1)
}
