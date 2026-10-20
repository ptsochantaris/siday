// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of the Alcatraz Packer, on tiny modules made here. The thorough check is
// made outside the package: what it tells Paula, tick by tick, against what Wanted Team's player tells
// her in UADE, for every one of UnExoticA's modules.

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

/// A row: the note (an offset into a finetune's periods, 2 for its first), the sample, the command and
/// its parameter.
private func note(_ note: Int, _ sample: Int, _ command: Int = 0, _ parameter: Int = 0) -> [UInt8] {
    [UInt8(note & 0xFE | sample >> 4 & 1), UInt8((sample & 15) << 4 | command)] + (command != 0 ? [UInt8(parameter)] : [])
}

/// `count` rows of nothing.
private func nothing(_ count: Int) -> [UInt8] { [~UInt8(0x40 | (count - 1))] }
/// The row that follows played `count` times.
private func again(_ count: Int) -> [UInt8] { [~UInt8(count - 1)] }

private let silent = nothing(64)

/// A module of two samples: the first of sixteen words at volume 48, with no loop; the second of eight
/// words at full volume, looping over its last four. Its positions are `positions`, of patterns of four
/// tracks (the first Paula's fourth voice's). With `twoFiles`, the samples are left out, for a file of
/// their own.
private func alp(tracks: [[UInt8]], patterns: [[Int]], positions: [Int] = [0], twoFiles: Bool = false) -> (module: [UInt8], samples: [UInt8]) {
    var records: [UInt8] = []
    records += long(0) + word(16) + [0, 48] + long(0) + word(1) + word(0)
    records += long(0) + word(8) + [0, 64] + long(0) + word(4) + word(4)
    records += word(2 * positions.count) + word(0)
    var places: [Int] = [], data: [UInt8] = []
    for track in tracks {
        places.append(data.count)
        data += track
    }
    var body = records
    for p in positions { body += word(8 * p) }
    for pattern in patterns { for t in pattern { body += word(places[t]) } }
    body += data
    let sizes = word(8 + records.count) + word(2 * positions.count) + word(8 * patterns.count) + word(data.count)
    let samples = (0 ..< 48).map { UInt8(truncatingIfNeeded: $0 * 9 + 1) }
    let total = 8 + sizes.count + body.count + samples.count
    let module = [0x50, 0x41, 0x6E, 0x10] + long(total) + sizes + body
    return twoFiles ? (module, samples) : (module + samples, [])
}

@Test func alpDetection() throws {
    let one = alp(tracks: [silent], patterns: [[0, 0, 0, 0]])
    #expect(ALPPlayer.isOne(one.module))
    #expect(!ALPPlayer.wantsSampleFile(one.module))
    var other = one.module
    other[3] = 0x11
    #expect(!ALPPlayer.isOne(other))
    let two = alp(tracks: [silent], patterns: [[0, 0, 0, 0]], twoFiles: true)
    #expect(ALPPlayer.wantsSampleFile(two.module))
    #expect(throws: TuneError.self) { _ = try ALPPlayer(two.module) }
    _ = try ALPPlayer(two.module, samples: two.samples)
    #expect(throws: TuneError.self) { _ = try ALPPlayer(Array(one.module.prefix(40))) }
}

/// A note is told Paula with her voice turned off, and turned on again; at every tick the voices it has
/// begun notes on are turned on, and every voice is told its sample's loop (silence for none). The
/// first track of a pattern is Paula's fourth voice's.
@Test func alpNoteReachesPaula() throws {
    for twoFiles in [false, true] {
        let made = alp(tracks: [note(2, 1) + nothing(63), note(4, 2) + nothing(63), silent], patterns: [[0, 1, 2, 2]], twoFiles: twoFiles)
        var player = try ALPPlayer(made.module, samples: made.samples)
        var recorder = Recorder()
        _ = player.run(&recorder)
        let at = twoFiles ? (made.module.count + 15) & ~15 : made.module.count - 48
        let silence = player.silenceAt
        #expect(recorder.events == ["buffer 3 \(at) 16", "buffer 2 \(at + 32) 8", "off 2", "off 3", "on 3", "on 2",
                                    "buffer 3 \(at) 1", "buffer 2 \(at + 40) 4", "buffer 1 \(silence) 0", "buffer 0 \(silence) 0"])
        #expect(player.period(3) == 0x358)
        #expect(player.volume(3) == 48)
        #expect(player.period(2) == 0x328)
        #expect(player.volume(2) == 64)
        recorder.events.removeAll()
        _ = player.run(&recorder)
        #expect(recorder.events.prefix(2) == ["on 3", "on 2"])
    }
}

/// Command 9 is passed over by Wanted Team's player; asked to, it slides the volume as 8 does, by its
/// parameter (with a sign) at every tick between rows.
@Test func alpCommandNine() throws {
    let made = alp(tracks: [note(2, 1, 9, 0xFF) + nothing(63), silent], patterns: [[0, 1, 1, 1]])
    for (asSlide, volume) in [(false, 48), (true, 43)] {
        var player = try ALPPlayer(made.module, volumeSlideOnNine: asSlide)
        var recorder = Recorder()
        for _ in 0 ..< 6 { _ = player.run(&recorder) }
        #expect(player.volume(3) == UInt16(volume))
    }
    let eight = alp(tracks: [note(2, 1, 8, 0x02) + nothing(63), silent], patterns: [[0, 1, 1, 1]])
    var player = try ALPPlayer(eight.module)
    var recorder = Recorder()
    for _ in 0 ..< 6 { _ = player.run(&recorder) }
    #expect(player.volume(3) == 58)
}

/// A count byte stands for rows of nothing, or for the row after it played again.
@Test func alpRowCounts() throws {
    let made = alp(tracks: [again(3) + note(2, 1) + nothing(2) + note(6, 1) + nothing(58), silent], patterns: [[0, 1, 1, 1]])
    var player = try ALPPlayer(made.module)
    var struck: [Int] = []
    for tick in 0 ..< 64 * 6 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        if recorder.events.contains("off 3") { struck.append(tick) }
    }
    #expect(struck == [0, 6, 12, 30])
    #expect(player.period(3) == 0x2FA)
}

/// The song comes to its end after its last position, where it starts again at the one it goes round
/// to; and, in siday's reckoning, where a jump takes it back to a position it has played.
@Test func alpSongEnds() throws {
    let once = try ALPPlayer(alp(tracks: [silent], patterns: [[0, 0, 0, 0]]).module)
    #expect(once.lengthClocks == UInt64(64 * 6) * UInt64(ALPPlayer.tickClocks))
    // A jump (B, a byte offset into the positions less one position) from the second position's
    // second row back to the first.
    let jump = alp(tracks: [silent, note(0, 0) + note(0, 0, 11, 0xFE) + nothing(62)], patterns: [[0, 0, 0, 0], [1, 0, 0, 0]], positions: [0, 1, 0])
    let round = try ALPPlayer(jump.module)
    #expect(round.lengthClocks == UInt64((64 + 2) * 6) * UInt64(ALPPlayer.tickClocks))
}

@Test func alpRenders() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(ALPPlayer(alp(tracks: [note(4, 2) + nothing(63), silent], patterns: [[0, 1, 1, 1]]).module), options: options)
    #expect(renderer.info.format == "ALP")
    #expect(renderer.subsongCount == 1)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
