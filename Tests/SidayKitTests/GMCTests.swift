// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of Game Music Creator, on tiny modules made here. The thorough check is
// made outside the package: what it tells Paula, tick by tick, against what Game Music Creator's own
// player tells her in UADE, for every one of UnExoticA's modules.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func put(_ bytes: inout [UInt8], _ at: Int, _ values: [UInt8]) {
    for (i, value) in values.enumerated() { bytes[at + i] = value }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// A note of a pattern: its row, voice, period, sample, command and the command's parameter.
private typealias Cell = (pattern: Int, row: Int, voice: Int, period: Int, sample: Int, command: Int, parameter: Int)

/// A module of two samples: the first of sixteen words at volume 48, with no loop; the second of eight
/// words at full volume, looping over its last four. Its order is `order`, of patterns holding `cells`.
private func gmc(order: [Int] = [0], cells: [Cell]) -> [UInt8] {
    let patterns = (order.max() ?? 0) + 1
    let samplesAt = 444 + 1024 * patterns
    var bytes = [UInt8](repeating: 0, count: samplesAt + 32 + 16)
    // Where the samples were in the editor's memory, and where the second's loop was.
    put(&bytes, 0, long(0x20000) + word(16) + [0, 48] + long(0x20000) + word(2))
    put(&bytes, 16, long(0x20020) + word(8) + [0, 64] + long(0x20028) + word(4))
    put(&bytes, 240, long(order.count))
    for (i, pattern) in order.enumerated() { put(&bytes, 244 + 2 * i, word(pattern * 1024)) }
    for cell in cells {
        let at = 444 + 1024 * cell.pattern + 16 * cell.row + 4 * cell.voice
        put(&bytes, at, word(cell.period) + [UInt8(cell.sample << 4 | cell.command), UInt8(cell.parameter)])
    }
    for i in 0 ..< 48 { bytes[samplesAt + i] = UInt8(truncatingIfNeeded: i * 9 + 1) }
    return bytes
}

@Test func gmcDetection() {
    let module = gmc(cells: [])
    #expect(GMCPlayer.isOne(module))
    #expect(!GMCPlayer.isOne(Array(module.prefix(444 + 1023))))
    var loud = module
    loud[7] = 65
    #expect(!GMCPlayer.isOne(loud))
    var misplaced = module
    put(&misplaced, 244, word(1000))
    #expect(!GMCPlayer.isOne(misplaced))
    var none = module
    put(&none, 240, long(0))
    #expect(!GMCPlayer.isOne(none))
    #expect(throws: TuneError.self) { _ = try GMCPlayer(none) }
    var long = module
    put(&long, 240, [0, 0, 0, 101])
    #expect(!GMCPlayer.isOne(long))
}

/// A note is set up at its row with Paula's voice off and its volume nought, turned on at the next
/// tick with its sample's volume, and told its loop (for a sample with none, silence) at the one after.
@Test func gmcNoteReachesPaula() throws {
    let module = gmc(cells: [(0, 0, 1, 428, 1, 0, 0), (0, 1, 2, 214, 2, 0, 0)])
    var player = try GMCPlayer(module)
    var ticks: [[String]] = []
    for _ in 0 ..< 14 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        ticks.append(recorder.events)
        if ticks.count == 6 {
            #expect(player.period(1) == 428)
            #expect(player.volume(1) == 0)
        }
        if ticks.count == 7 { #expect(player.volume(1) == 48) }
    }
    let samplesAt = 444 + 1024
    // The first row is played at the sixth tick, and a row every six.
    #expect(ticks[0 ..< 5].allSatisfy { $0.isEmpty })
    #expect(ticks[5] == ["buffer 1 \(samplesAt) 16", "off 1"])
    #expect(ticks[6] == ["on 1"])
    #expect(ticks[7] == ["buffer 1 \(module.count) 2"])
    // The second sample's loop is where the module says, from its start.
    #expect(ticks[11] == ["buffer 2 \(samplesAt + 32) 8", "off 2"])
    #expect(ticks[12] == ["on 2"])
    #expect(ticks[13] == ["buffer 2 \(samplesAt + 40) 4"])
    #expect(player.period(2) == 214)
    #expect(player.volume(2) == 64)
}

/// A slide goes on at every tick, from the tick after its row, until the voice's next note.
@Test func gmcSlideGoesOn() throws {
    var player = try GMCPlayer(gmc(cells: [(0, 0, 0, 428, 1, 0, 0), (0, 1, 0, 0, 0, 1, 2), (0, 3, 0, 300, 1, 0, 0)]))
    var recorder = Recorder()
    for _ in 0 ..< 12 { _ = player.run(&recorder) }
    #expect(player.period(0) == 428)
    for _ in 0 ..< 7 { _ = player.run(&recorder) }
    #expect(player.period(0) == 428 - 2 * 7)
    // (On past row 2, which has nothing for the voice.)
    for _ in 0 ..< 4 { _ = player.run(&recorder) }
    #expect(player.period(0) == 428 - 2 * 11)
    // Row 3: the next note, which stops it.
    for _ in 0 ..< 3 { _ = player.run(&recorder) }
    #expect(player.period(0) == 300)
}

/// A song comes to its end past the last entry of its order, and starts again; and, in siday's
/// reckoning, when a jump brings it back to an entry it has played.
@Test func gmcSongEnds() throws {
    let once = try GMCPlayer(gmc(cells: [(0, 0, 0, 428, 1, 0, 0)]))
    // Its 64 rows of six ticks from the sixth, and the first again.
    #expect(once.lengthClocks == UInt64(5 + 64 * 6) * UInt64(GMCPlayer.tickClocks))
    // Three entries, the last jumping back to the second (entry 1, counting from nought) at its
    // second row.
    let round = try GMCPlayer(gmc(order: [0, 1, 2], cells: [(2, 1, 0, 0, 0, 5, 1)]))
    #expect(round.lengthClocks == UInt64(5 + 64 * 6 * 2 + 2 * 6) * UInt64(GMCPlayer.tickClocks))
    var player = try GMCPlayer(gmc(order: [0, 1, 2], cells: [(2, 1, 0, 0, 0, 5, 1)]))
    var recorder = Recorder()
    for _ in 0 ..< 5 + 64 * 6 * 2 + 2 * 6 { _ = player.run(&recorder) }
    #expect(player.endings == 0)
    _ = player.run(&recorder)
    #expect(player.endings == 1)
}

/// The speed command sets the ticks a row, and the volume command the volume, of the next tick on.
@Test func gmcSpeedAndVolume() throws {
    var player = try GMCPlayer(gmc(cells: [(0, 0, 0, 428, 1, 8, 2), (0, 0, 1, 0, 0, 3, 0x50), (0, 1, 2, 300, 1, 0, 0)]))
    var recorder = Recorder()
    for _ in 0 ..< 7 { _ = player.run(&recorder) }
    // (A volume above 64 is full, as Paula takes it.)
    #expect(player.volumeWritten(1) == 0x50)
    #expect(player.volume(1) == 64)
    // The next row two ticks after the first.
    #expect(player.period(2) == 0)
    _ = player.run(&recorder)
    #expect(player.period(2) == 300)
}

@Test func gmcRenders() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(GMCPlayer(gmc(cells: [(0, 0, 0, 428, 2, 0, 0)])), options: options)
    #expect(renderer.info.format == "GMC")
    #expect(renderer.subsongCount == 1)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
