// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the players of SidMon's and SidMon II's music, on tiny files made here. The thorough
// check is made outside the package: what they tell Paula, tick by tick, and what Paula plays of the
// waves they rewrite, against UADE's running of the original players, for every file of UnExoticA's
// collection.

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

/// A SidMon II module of one position at `speed`: every voice plays note $20 of instrument 1 at its
/// first row and nothing after. The instrument plays sample 0 (16 words, looped whole) at once at full
/// volume; the sample is turned over a byte a tick (mode 1, step 1, every tick).
private func sidMon2(speed: UInt8 = 3) -> (module: [UInt8], sampleAt: Int) {
    let lengths = [28, 4, 4, 4, 4, 32, 16, 16, 16, 64, 2]
    var bytes = word(0) + [0, speed] + word(64)
    for l in lengths { bytes += long(l) }
    bytes += long(6) + long(32)
    bytes += Array("SIDMON II - THE MIDI VERSION".utf8)
    bytes += [0, 0, 0, 0]
    bytes += [UInt8](repeating: 0, count: 12)
    var instrument = [UInt8](repeating: 0, count: 32)
    instrument[16] = 0xFF
    instrument[17] = 0xFF
    bytes += instrument
    bytes += [UInt8](repeating: 0, count: 48)
    var sample = [UInt8](repeating: 0, count: 64)
    sample[5] = 16
    sample[9] = 16
    sample[13] = 16
    sample[17] = 1
    sample[19] = 1
    bytes += sample
    bytes += word(0)
    bytes += [0x20, 1, 0, 0, 0xC1, 0]
    let sampleAt = bytes.count
    bytes += (0 ..< 32).map { UInt8($0 * 4) }
    return (bytes, sampleAt)
}

@Test func sidMon2ModulesAreKnown() {
    #expect(SidMon2Player.isOne(sidMon2().module))
    #expect(!SidMon2Player.isOne(Array(sidMon2().module.prefix(80))))
    #expect(!SidMon2Player.isOne([UInt8](repeating: 0, count: 200)))
    // A module of no samples the player would take for one of 65,536.
    var none = sidMon2().module
    none[4] = 0
    none[5] = 0
    #expect(throws: TuneError.self) { try SidMon2Player(none) }
}

@Test func sidMon2RowTellsPaula() throws {
    let (module, sampleAt) = sidMon2()
    var player = try SidMon2Player(module)
    var first = Recorder(), second = Recorder(), third = Recorder()
    _ = player.run(&first)
    _ = player.run(&second)
    _ = player.run(&third)
    // The first two ticks have no row: the third (at the speed, 3) has.
    #expect(!first.events.contains("off 0"))
    let starts = (0 ..< 4).map { "buffer \($0) \(sampleAt) 16" }
    #expect(third.events == (0 ..< 4).map { "off \($0)" } + starts + (0 ..< 4).map { "on \($0)" } + starts)
    #expect(player.period(0) == SidMon2Tables.periods[0x20])
    // The attack, at $FF a tick to $FF, is there at once: a quarter of it is Paula's volume.
    #expect(player.volumeWritten(0) == 0x3F)
}

@Test func sidMon2TurnsItsSampleOver() throws {
    let (module, sampleAt) = sidMon2()
    var player = try SidMon2Player(module)
    var out = Recorder()
    _ = player.run(&out)
    // Once a tick, a byte of the sample, the next each time (the four voices play the one sample).
    #expect(player.memory[sampleAt] == ~module[sampleAt])
    #expect(player.memory[sampleAt + 1] == module[sampleAt + 1])
    _ = player.run(&out)
    #expect(player.memory[sampleAt + 1] == ~module[sampleAt + 1])
    // And the song started again starts from the module as it was.
    try player.select(song: 0)
    #expect(player.memory[sampleAt] == module[sampleAt])
}

@Test func sidMon2SongLength() throws {
    // 64 rows, a row every third tick, the first at the third: round again at the 195th.
    let player = try SidMon2Player(sidMon2().module)
    #expect(player.lengthClocks == 194 * UInt64(SidMon2Player.tickClocks))
    #expect(player.tuneInfo.format == "SID2")
}

/// The start of SidMon's player as its check looks for it: `lea` and the words at 6, 12, 18 and 22.
private let sidMonStart: [UInt8] = [0x41, 0xFA, 0x11, 0x70, 0xD1, 0xE8, 0xFF, 0xD4, 0x43, 0xFA, 0x0D, 0x68,
                                    0x22, 0x88, 0x41, 0xFA, 0x11, 0x62, 0xD1, 0xE8, 0xFF, 0xD8, 0x43, 0xFA]

@Test func sidMonPlayersAreFound() {
    #expect(SidMon1Player.playerStart(sidMonStart + [UInt8](repeating: 0, count: 100)) == 0)
    // At an even place, of as many as the file's length counts in its low sixteen bits, and one more.
    let padded = [0, 0] + sidMonStart + [UInt8](repeating: 0, count: 100)
    #expect(SidMon1Player.playerStart(padded) == 2)
    #expect(SidMon1Player.playerStart([0] + sidMonStart + [UInt8](repeating: 0, count: 100)) == nil)
    let long = 0x10000 + 100
    var far = [UInt8](repeating: 0, count: long)
    far.replaceSubrange(200 ..< 224, with: sidMonStart)
    #expect(SidMon1Player.playerStart(far) == 200)
    far = [UInt8](repeating: 0, count: long)
    far.replaceSubrange(202 ..< 226, with: sidMonStart)
    #expect(SidMon1Player.playerStart(far) == nil)
    // A Commodore 64 tune is not one.
    #expect(!SidMon1Player.isOne(Array("PSID".utf8) + [UInt8](repeating: 0, count: 200)))
}

@Test func sidMonOfAnotherPlayerIsRefused() {
    // The check takes it, but the player's code is none of the two known.
    let file = sidMonStart + [UInt8](repeating: 0x4E, count: 0x2000)
    #expect(SidMon1Player.isOne(file))
    #expect(throws: TuneError.self) { try SidMon1Player(file) }
}
