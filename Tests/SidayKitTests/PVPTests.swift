// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of Peter Verswyvelen's packer, on tiny modules made here. The thorough check
// is made outside the package: what it tells Paula, tick by tick, against what Wanted Team's player
// tells her in UADE, for every one of UnExoticA's modules.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

/// A row of a track: its sample, whether the rows it is followed by play it again, its period, the rows
/// that follow it, and its command and parameter.
private typealias Row = (sample: Int, again: Bool, period: Int, skip: Int, command: Int, parameter: Int)

/// A row of nothing followed by `skip` more.
private func nothing(_ skip: Int) -> Row { (0, false, 0, skip, 0, 0) }

/// A module of two samples: the first of sixteen words at volume 48, with no loop; the second of eight
/// words at full volume, looping over its last four. Its steps are `steps` (each four tracks' numbers),
/// going round to `restart`.
private func pvp(tracks: [[Row]], steps: [[Int]], restart: Int = 0) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x100)
    func put(_ at: Int, _ values: [UInt8]) { for (i, v) in values.enumerated() { bytes[at + i] = v } }
    put(0, word(16) + word(48) + word(0) + word(1))
    put(8, word(8) + word(64) + word(4) + word(4))
    var data: [UInt8] = [], places: [Int] = []
    for track in tracks {
        places.append(data.count)
        for row in track {
            let first = row.sample << 3 | (row.again ? 4 : 0) | row.period >> 8 & 3
            data += [UInt8(first), UInt8(row.period & 0xFF), UInt8(row.skip << 4 | row.command), UInt8(row.parameter)]
        }
    }
    put(0xF8, word(tracks.count) + word(steps.count) + word(restart) + word(data.count))
    for place in places { bytes += word(place) }
    for step in steps { for track in step { bytes += word(2 * track) } }
    bytes += data
    for i in 0 ..< 48 { bytes.append(UInt8(truncatingIfNeeded: i * 9 + 1)) }
    return bytes
}

/// Where the samples begin in a module `pvp` made.
private func samplesAt(_ module: [UInt8]) -> Int { module.count - 48 }

private let silent: [Row] = [nothing(15)]

@Test func pvpDetection() {
    let module = pvp(tracks: [silent], steps: [[0, 0, 0, 0], [0, 0, 0, 0]])
    #expect(PVPPlayer.isOne(module))
    var loud = module
    loud[3] = 65
    #expect(!PVPPlayer.isOne(loud))
    #expect(!PVPPlayer.isOne(pvp(tracks: [silent], steps: [[0, 0, 0, 0]])))
    #expect(!PVPPlayer.isOne(pvp(tracks: [silent], steps: [[0, 0, 0, 0], [0, 0, 0, 0]], restart: 2)))
    #expect(!PVPPlayer.isOne(Array(module.prefix(0x100))))
    // (A module whose samples go past its end is refused.)
    #expect(throws: TuneError.self) { _ = try PVPPlayer(Array(module.dropLast())) }
}

/// A note is set up with Paula's voice turned off and told its sample, then turned on and told its loop,
/// its period and its sample's volume, all at its row.
@Test func pvpNoteReachesPaula() throws {
    let module = pvp(tracks: [[(1, false, 428, 15, 0, 0)], [(2, false, 214, 15, 0, 0)], silent],
                     steps: [[0, 1, 2, 2], [2, 2, 2, 2]])
    var player = try PVPPlayer(module)
    var recorder = Recorder()
    _ = player.run(&recorder)
    let at = samplesAt(module)
    // The second sample's loop is from its fourth word, and it plays as far as the loop's end.
    #expect(recorder.events == ["off 0", "buffer 0 \(at) 16", "off 1", "buffer 1 \(at + 32) 8", "on 0", "on 1",
                                "buffer 0 \(at) 1", "buffer 1 \(at + 40) 4"])
    #expect(player.period(0) == 428)
    #expect(player.volume(0) == 48)
    #expect(player.period(1) == 214)
    #expect(player.volume(1) == 64)
    // (The first long of each sample is made nought.)
    #expect(player.memory[at] == 0 && player.memory[at + 3] == 0 && player.memory[at + 4] != 0)
}

/// Its vibrato only ever lowers the note, and by up to twice ProTracker's depth.
@Test func pvpVibratoIsOneSided() throws {
    var player = try PVPPlayer(pvp(tracks: [[(1, true, 428, 0, 4, 0xF8), (0, true, 0, 14, 4, 0)], silent],
                                   steps: [[0, 1, 1, 1], [1, 1, 1, 1]]))
    var recorder = Recorder()
    var periods: [UInt16] = []
    for _ in 0 ..< 96 {
        _ = player.run(&recorder)
        periods.append(player.period(0))
    }
    #expect(periods.allSatisfy { $0 >= 428 && $0 <= 428 + 31 })
    #expect(periods.contains(428 + 31))
    #expect(Array(periods[0 ..< 6]) == [428, 428, 459, 434, 458, 440])
}

/// A row marked to be played again is struck again at each of the rows that follow it; one that is not
/// is followed by rows of nothing.
@Test func pvpRowsPlayedAgain() throws {
    var player = try PVPPlayer(pvp(tracks: [[(1, true, 428, 2, 0, 0), (1, false, 300, 12, 0, 0)], silent],
                                   steps: [[0, 1, 1, 1], [1, 1, 1, 1]]))
    var struck: [Int] = []
    for tick in 0 ..< 96 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        if recorder.events.contains("off 0") { struck.append(tick) }
    }
    #expect(struck == [0, 6, 12, 18])
}

/// The song comes to its end after its last step, starting again at the step it goes round to; D goes
/// on to the next pattern (four steps) from the step after its own, so from a pattern's last step it
/// passes over the next.
@Test func pvpSongEnds() throws {
    let blank = [0, 0, 0, 0]
    let once = try PVPPlayer(pvp(tracks: [silent], steps: [blank, blank]))
    #expect(once.lengthClocks == UInt64(32 * 6) * UInt64(PVPPlayer.tickClocks))
    let breakRow: [Row] = [(0, false, 0, 15, 13, 0)]
    let eight = Array(repeating: blank, count: 8)
    var fromThird = eight
    fromThird[2] = [1, 0, 0, 0]
    #expect(try PVPPlayer(pvp(tracks: [silent, breakRow], steps: fromThird)).lengthClocks == UInt64((2 * 16 + 1 + 4 * 16) * 6) * UInt64(PVPPlayer.tickClocks))
    var fromFourth = eight
    fromFourth[3] = [1, 0, 0, 0]
    #expect(try PVPPlayer(pvp(tracks: [silent, breakRow], steps: fromFourth)).lengthClocks == UInt64((3 * 16 + 1) * 6) * UInt64(PVPPlayer.tickClocks))
    var player = try PVPPlayer(pvp(tracks: [silent], steps: [blank, blank]))
    var recorder = Recorder()
    for _ in 0 ..< 32 * 6 { _ = player.run(&recorder) }
    #expect(player.endings == 0)
    _ = player.run(&recorder)
    #expect(player.endings == 1)
}

@Test func pvpRenders() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(PVPPlayer(pvp(tracks: [[(2, false, 214, 15, 0, 0)], silent], steps: [[0, 1, 1, 1], [1, 1, 1, 1]])), options: options)
    #expect(renderer.info.format == "PVP")
    #expect(renderer.subsongCount == 1)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
