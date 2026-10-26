// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of The Musical Enlightenment's player, on tiny files made here as the editor's are. The thorough
// check is made outside the package: what it tells Paula, tick by tick, against what Wanted Team's player tells
// her in UADE, for UnExoticA's file.

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

/// Where the events, the lists of instructions and the sample are.
private let eventsAt = 6826 + 12
private let listsAt = eventsAt + 2 * 192
private let sampleAt = listsAt + 256 * 4

/// A file of one tune of one entry, at speed nought (an event every tick), on the voices of `mask`: voice 0 plays
/// track 0, whose first event is note 13 of instrument 1, the others track 1, which is empty. The instrument is a
/// sample of sixteen bytes, its first eight words played and then six from its third word, at volume 64; its
/// envelope up to 255 in two ticks, down to 128 in one, and held.
private func file(mask: Int = 0x0F) -> [UInt8] {
    var bytes = long(sampleAt + 16) + [0, 1, 0, UInt8(mask)] + [UInt8](repeating: 0, count: 52) + long(0x50F) + long(0x50F)
    var instrument = long(0) + long(16) + long(8) + long(2) + long(6) + word(0) + word(0) + [0x41] + [UInt8](repeating: 0, count: 31)
    instrument += [64, 0] + [1, 0, 0, 255, 128, 0] + [UInt8](repeating: 0, count: 64)
    bytes += instrument
    for _ in 1 ..< 32 { bytes += [UInt8](repeating: 0, count: 128) }
    bytes += [UInt8](repeating: 0, count: 576 + 2048)
    bytes += word(1) + word(64) + word(0) + Array("Tiny".utf8) + [UInt8](repeating: 0, count: 28)
    bytes += [0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0]
    bytes += [13, 1, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 186) + [UInt8](repeating: 0, count: 192)
    bytes += [UInt8](repeating: 0, count: 1024)
    bytes += (0 ..< 16).map { UInt8($0 * 9 + 2) }
    return bytes
}

@Test func tmeDetection() throws {
    let made = file()
    #expect(made.count == sampleAt + 16)
    #expect(TMEPlayer.isOne(made))
    // (Without the empty tunes, by its length, which must be its parts' and its sample's.)
    var other = made
    other[0x3F] = 0
    #expect(TMEPlayer.isOne(other))
    other[3] = 1
    #expect(!TMEPlayer.isOne(other))
    #expect(!TMEPlayer.isOne(Array(made.prefix(6999))))
    let player = try TMEPlayer(made)
    #expect(player.songCount == 1 && player.sampleCount == 1 && player.tuneInfo.title == "Tiny")
    let filtered = player.lightFilter
    #expect(filtered)
    let unfiltered = try TMEPlayer(file(mask: 0x1F))
    let off = !unfiltered.lightFilter
    #expect(off)
    #expect(throws: TuneError.self) { try TMEPlayer(Array(made.prefix(made.count - 1))) }
}

/// A note is begun on its event's tick: its voice turned off and told its sample's first part; turned on as the
/// next tick begins and told its loop. Its envelope rises to 255 in two ticks and falls to 128 in one, of the
/// instrument's volume of 64.
@Test func tmeNoteReachesPaula() throws {
    var player = try TMEPlayer(file())
    let silence = player.silenceAt
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == ["off 0", "buffer 0 \(sampleAt) 8"] + (1 ..< 4).map { "buffer \($0) \(silence) 0" })
    #expect(player.periodWritten(0) == 428 && player.volumeWritten(0) == 0)
    var second = Recorder()
    _ = player.run(&second)
    #expect(second.events == ["on 0", "buffer 0 \(sampleAt + 4) 6"] + (1 ..< 4).map { "buffer \($0) \(silence) 0" })
    var volumes: [UInt16] = [player.volumeWritten(0)]
    for _ in 0 ..< 5 {
        var none = TFMXSilentOutput()
        _ = player.run(&none)
        volumes.append(player.volumeWritten(0))
    }
    #expect(volumes == [31, 63, 63, 32, 32, 32])
}

/// The tune comes to its end as its last entry does, and is said to as it begins again: 32 events of a tick here.
@Test func tmeTuneEnds() throws {
    var player = try TMEPlayer(file())
    #expect(player.lengthClocks == UInt64(32 * TFMXTiming.frame))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 32 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1)
}
