// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of Sonic Arranger, on tiny modules made here. The thorough check is made
// outside the package: what it tells Paula, tick by tick, against what Wanted Team's player and the
// modules' own replayers tell her in UADE, for every song of every one of UnExoticA's modules.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value) }

/// A row: its position, voice, row, note, instrument, command and parameter.
private typealias Row = (position: Int, voice: Int, row: Int, note: Int, instrument: Int, command: Int, parameter: Int)

/// The parts of a module: two positions of four rows each for each voice, at a speed of two; a sample
/// of 32 bytes, its instrument (1) at volume 40 looping over its last 16; a synthesised instrument (2)
/// of 32 bytes, at volume 64, whose effect negates each of its first four bytes in turn, every tick;
/// one waveform, rising; and an envelope of each kind, unused.
private struct Parts {
    var songs: [[Int]] = [[2, 4, 0, 1, 0, 50]]
    var rows: [Row] = []

    var songTable: [UInt8] { songs.flatMap { $0.flatMap(word) } }
    var positions: [UInt8] {
        // Each voice's rows: position p, voice v at row (p * 4 + v) * 4.
        (0 ..< 2).flatMap { p in (0 ..< 4).flatMap { v in word((p * 4 + v) * 4) + word(0) } }
    }

    var rowTable: [UInt8] {
        var table = [UInt8](repeating: 0, count: 2 * 4 * 4 * 4)
        for row in rows {
            let at = ((row.position * 4 + row.voice) * 4 + row.row) * 4
            table[at] = UInt8(row.note)
            table[at + 1] = UInt8(row.instrument)
            table[at + 2] = UInt8(row.command)
            table[at + 3] = UInt8(row.parameter)
        }
        return table
    }

    var instruments: [UInt8] {
        var sample = [UInt8](repeating: 0, count: 152)
        sample.replaceSubrange(0 ..< 8, with: word(0) + word(0) + word(8) + word(8))
        sample.replaceSubrange(0x10 ..< 0x12, with: word(40))
        var synth = [UInt8](repeating: 0, count: 152)
        synth.replaceSubrange(0 ..< 8, with: word(1) + word(0) + word(16) + word(0))
        synth.replaceSubrange(0x10 ..< 0x12, with: word(64))
        synth.replaceSubrange(0x42 ..< 0x4A, with: word(1) + word(0) + word(3) + word(1))
        return sample + synth
    }

    var wave: [UInt8] { (0 ..< 128).map { UInt8(truncatingIfNeeded: $0 * 2) } }
    var sample: [UInt8] { (0 ..< 32).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) } }

    /// The module as a game's song: eight offsets, then the parts, then "deadbeef" and its text, each
    /// byte inverted, a line ending ($F5) and nought. (Wanted Team's player counts the file's length
    /// twice over its first $28 bytes, and wants that much more of it after the samples.)
    var song: [UInt8] {
        let parts: [[UInt8]] = [songTable, positions, rowTable, instruments, wave, [UInt8](repeating: 0, count: 128),
                                [UInt8](repeating: 0, count: 128)]
        var offsets: [Int] = []
        var at = 0x28
        for part in parts {
            offsets.append(at)
            at += part.count
        }
        offsets.append(at)
        var bytes = offsets.flatMap(long) + [UInt8](repeating: 0, count: 8)
        for part in parts { bytes += part }
        bytes += long(1) + long(32) + sample
        bytes += Array("deadbeef".utf8) + long(0) + Array("Composed for nobody in particular".utf8).map { ~$0 } + [0xF5, 0]
        return bytes
    }

    /// The module as the editor saves it, in named parts.
    var editor: [UInt8] {
        var bytes = Array("SOARV1.0STBL".utf8) + long(songs.count) + songTable
        bytes += Array("OVTB".utf8) + long(2) + positions
        bytes += Array("NTBL".utf8) + long(rowTable.count / 4) + rowTable
        bytes += Array("INST".utf8) + long(2) + instruments
        bytes += Array("SD8B".utf8) + long(1) + [UInt8](repeating: 0, count: 38) + long(32) + sample
        bytes += Array("SYWT".utf8) + long(1) + wave
        bytes += Array("SYAR".utf8) + long(1) + [UInt8](repeating: 0, count: 128)
        bytes += Array("SYAF".utf8) + long(1) + [UInt8](repeating: 0, count: 128)
        bytes += Array("EDAT".utf8) + [UInt8](repeating: 0, count: 20)
        return bytes
    }
}

@Test func sonicArrangerDetection() throws {
    let parts = Parts()
    #expect(SonicArrangerPlayer.isOne(parts.song))
    #expect(SonicArrangerPlayer.isOne(parts.editor))
    #expect(!SonicArrangerPlayer.isOne([UInt8](repeating: 0x55, count: 4096)))
    // A song whose samples are not in it, or without its "d" after them, is not one.
    let marked = try #require((0 ..< parts.song.count - 8).first { parts.song[$0 ..< $0 + 8].elementsEqual("deadbeef".utf8) })
    #expect(!SonicArrangerPlayer.isOne(Array(parts.song.prefix(marked - 10))))
    var unmarked = parts.song
    unmarked[marked] = 0x65
    #expect(!SonicArrangerPlayer.isOne(unmarked))
    // An editor's module cut short is taken for one, and refused.
    let cut = Array(parts.editor.prefix(parts.editor.count - 30))
    #expect(SonicArrangerPlayer.isOne(cut))
    #expect(throws: TuneError.self) { _ = try SonicArrangerPlayer(cut) }
    // A song with no $F5 and nought after its text cannot be measured by Wanted Team's player.
    var unended = parts.song
    unended[unended.count - 2] = 0x20
    #expect(throws: TuneError.self) { _ = try SonicArrangerPlayer(unended) }
    // A file with the magic of a replayer of 2.18 in front of it, but not one of the builds known here,
    // is refused.
    var replayer = [UInt8](repeating: 0, count: 0x2000)
    for (i, jump) in [0x2A, 0x6FC, 0x77C, 0x814, 0x846, 0x18DA, 0x8EE].enumerated() {
        replayer.replaceSubrange(4 * i ..< 4 * i + 4, with: [0x4E, 0xFA] + word(jump))
    }
    replayer.replaceSubrange(0x2C ..< 0x34, with: [0x48, 0xE7, 0xFF, 0xFE, 0x41, 0xFA, 0x19, 0x4A])
    replayer.replaceSubrange(0x99C ..< 0x9A0, with: [0x52, 0x50, 0x30, 0x3A])
    replayer += parts.song
    #expect(SonicArrangerPlayer.isOne(replayer))
    #expect(throws: TuneError.self) { _ = try SonicArrangerPlayer(replayer) }
}

/// A sample's note: Paula's voice stopped, told where the sample is and for its whole length, and
/// started at the tick's end; then told its loop. A synthesised note: told its voice's own buffer, into
/// which its waveform is copied, which its effect then works on.
@Test func sonicArrangerNotesReachPaula() throws {
    var parts = Parts()
    parts.rows = [(0, 0, 0, 25, 1, 0, 0), (0, 1, 0, 37, 2, 0, 0)]
    for module in [parts.song, parts.editor] {
        var player = try SonicArrangerPlayer(module)
        #expect(player.replayer == .wantedTeam)
        let found = try #require((0 ... module.count - 32).first { Array(module[$0 ..< $0 + 32]) == parts.sample })
        var recorder = Recorder()
        player.run(&recorder)
        let buffer = player.voicesAt + SonicArrangerPlayer.voiceSize, empty = player.emptyAt
        #expect(recorder.events == ["off 0", "buffer 0 \(found) 16", "off 1", "buffer 1 \(buffer) 16",
                                    "buffer 2 \(empty) 1", "buffer 3 \(empty) 1", "on 0", "on 1"])
        #expect(player.period(0) == 0xD60)
        #expect(player.volume(0) == 40)
        #expect(player.period(1) == 0x6B0)
        #expect(player.volume(1) == 64)
        // The wave is in the voice's buffer, its first byte negated by the effect.
        #expect(player.memory[buffer] == 0)
        #expect(player.memory[buffer + 1] == 2)
        recorder.events = []
        player.run(&recorder)
        #expect(recorder.events == ["buffer 0 \(found + 16) 8", "buffer 2 \(empty) 1", "buffer 3 \(empty) 1"])
        #expect(player.memory[buffer + 1] == 0xFE)
        #expect(player.memory[buffer + 2] == 4)
    }
}

/// Songs: each as long as it plays to its last position's end; a song of 25 ticks a second runs
/// Wanted Team's player at half the speed.
@Test func sonicArrangerSongs() throws {
    var parts = Parts()
    parts.songs = [[2, 4, 0, 1, 0, 50], [3, 2, 1, 1, 1, 25]]
    let first = try SonicArrangerPlayer(parts.song)
    #expect(first.songCount == 2)
    #expect(first.lengthTicks == 2 * 4 * 2)
    #expect(first.tickClocks == (0x376B + 1) * 5)
    let second = try SonicArrangerPlayer(parts.song, song: 1)
    #expect(second.lengthTicks == 2 * 3)
    #expect(second.tickClocks == (709_350 / 25 + 1) * 5)
    #expect(second.lengthClocks == UInt64(6 * second.tickClocks))
    // A jump back to the first position comes round there.
    parts.songs = [[2, 4, 0, 1, 0, 50]]
    parts.rows = [(0, 2, 1, 0, 0, 0xB, 0)]
    let jumping = try SonicArrangerPlayer(parts.song)
    #expect(jumping.lengthTicks == 2 * 2)
}

/// The commands: the speed, the volume, and a slide of the period on every tick but the row's.
@Test func sonicArrangerCommands() throws {
    var parts = Parts()
    parts.rows = [(0, 0, 0, 25, 1, 0xF, 3), (0, 1, 0, 25, 1, 0xC, 20), (0, 2, 0, 25, 1, 1, 0xFE)]
    var player = try SonicArrangerPlayer(parts.song)
    var recorder = Recorder()
    var periods: [UInt16] = []
    for _ in 0 ..< 4 {
        player.run(&recorder)
        periods.append(player.period(2))
    }
    #expect(player.volume(1) == 20)
    // (The slide is taken from the period, a tick late.)
    #expect(periods == [0xD60, 0xD60, 0xD62, 0xD64])
}

/// Neither form of a module traps or hangs, cut anywhere or with any byte changed.
@Test func sonicArrangerSurvivesDamage() throws {
    var parts = Parts()
    parts.rows = [(0, 0, 0, 25, 1, 0, 0x37), (0, 1, 0, 37, 2, 0x4, 0x11), (1, 2, 0, 0x7F, 0, 0, 0), (1, 3, 0, 99, 0, 0xB, 1)]
    var seed: UInt64 = 0x5A5A
    func next() -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(seed >> 33)
    }
    for module in [parts.song, parts.editor] {
        for cut in stride(from: 0, to: module.count, by: 7) {
            if var player = try? SonicArrangerPlayer(Array(module.prefix(cut))) {
                var recorder = Recorder()
                for _ in 0 ..< 50 { player.run(&recorder) }
            }
        }
        for _ in 0 ..< 200 {
            var damaged = module
            for _ in 0 ..< 1 + next() % 8 { damaged[next() % damaged.count] = UInt8(truncatingIfNeeded: next()) }
            if var player = try? SonicArrangerPlayer(damaged) {
                var recorder = Recorder()
                for _ in 0 ..< 200 { player.run(&recorder) }
            }
        }
    }
}

@Test func sonicArrangerRenders() throws {
    var parts = Parts()
    parts.rows = [(0, 0, 0, 25, 1, 0, 0), (0, 1, 0, 37, 2, 0, 0)]
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(SonicArrangerPlayer(parts.song), options: options)
    #expect(renderer.info.format == "SA")
    #expect(renderer.info.detail == "Sonic Arranger")
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
