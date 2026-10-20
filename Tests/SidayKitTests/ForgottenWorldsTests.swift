// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Forgotten Worlds' player, on tiny files made here as the game's are. The thorough check is
// made outside the package: what it tells Paula, tick by tick, against what Psygore's player tells her in UADE,
// for every one of UnExoticA's files.

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

/// A file of four voices' streams (voice 0's at 32, the others' at 48), an instrument at 64 (sample 0, held at
/// $20 after rising by $10 to 64 and falling by 16, for two ticks, then falling by 8) and a sample at 80 (its
/// sound at 96, eight words, its loop at 100, two).
private func file(_ first: [UInt8], _ others: [UInt8]) -> [UInt8] {
    var bytes = Array("FWMP".utf8) + long(64 - 16) + long(64 - 16) + long(80 - 16)
    bytes += word(32 - 16) + word(48 - 16) + word(48 - 16) + word(48 - 16) + [UInt8](repeating: 0, count: 8)
    bytes += first + [UInt8](repeating: 0, count: 16 - first.count)
    bytes += others + [UInt8](repeating: 0, count: 16 - others.count)
    bytes += [0, 0x20, 0x10, 0xF0, 2, 0xF8, 0, 0] + [UInt8](repeating: 0, count: 8)
    bytes += word(16) + word(8) + word(4) + word(2) + [UInt8](repeating: 0, count: 8)
    bytes += (0 ..< 16).map { UInt8($0 * 7 + 1) }
    return bytes
}

@Test func forgottenWorldsDetection() throws {
    let made = file([0x86, 4, 0x82], [0x86, 4, 0x82])
    #expect(ForgottenWorldsPlayer.isOne(made))
    var other = made
    other[3] = 0x51
    #expect(!ForgottenWorldsPlayer.isOne(other))
    #expect(throws: TuneError.self) { _ = try ForgottenWorldsPlayer(Array(made.prefix(20))) }
    let player = try ForgottenWorldsPlayer(made)
    #expect(player.instrumentCount == 2)
}

/// A note is started at once: the voice turned off, told its sample and turned on, and told its loop; its
/// volume then rises, falls and is held by its envelope; a rest leaves it be.
@Test func forgottenWorldsNoteReachesPaula() throws {
    var player = try ForgottenWorldsPlayer(file([0x84, 0, 12, 4, 0x86, 2, 0x82], [0x86, 6, 0x82]))
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == ["on 0", "on 1", "on 2", "on 3", "off 0", "buffer 0 96 8", "on 0", "buffer 0 100 2"])
    #expect(player.periodWritten(0) == 0x358 && player.volumeWritten(0) == 0x10)
    var volumes: [UInt16] = []
    for _ in 0 ..< 5 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        volumes.append(player.volumeWritten(0))
    }
    // (Up by $10 to 64, the rest's tick untouched, and down by 16 towards $20.)
    #expect(volumes == [0x20, 0x30, 0x40, 0x40, 0x30])
}

/// The song comes to its end when every voice has gone back to its beginning: six ticks, here; and it stops
/// when every voice has stopped, whose $80 leaves the rest of its tick unplayed.
@Test func forgottenWorldsSongEnds() throws {
    var player = try ForgottenWorldsPlayer(file([0x84, 0, 12, 4, 0x86, 2, 0x82], [0x86, 6, 0x82]))
    #expect(player.lengthClocks == UInt64(6 * TFMXTiming.fiftyTimes))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 6 { _ = player.run(&none) }
    #expect(player.endings == 0)
    _ = player.run(&none)
    #expect(player.endings == 1 && player.stops == 0)

    var stopping = try ForgottenWorldsPlayer(file([0x84, 0, 12, 2, 0x80], [0x80]))
    #expect(stopping.lengthClocks == UInt64(3 * TFMXTiming.fiftyTimes))
    for _ in 0 ..< 3 { _ = stopping.run(&none) }
    #expect(stopping.stops == 0)
    _ = stopping.run(&none)
    #expect(stopping.stops == 1)
}
