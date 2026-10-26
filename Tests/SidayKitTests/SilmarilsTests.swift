// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
@testable import SidayKit
import Testing

// Fast checks of the player of Silmarils' music, on tiny modules made here. The thorough check is made
// outside the package: what it tells Paula, tick by tick, against what Wanted Team's EaglePlayer module
// tells her in UADE, for every song of UnExoticA's files.

/// What Paula is told, as a list; and her loop counts, as set.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    var loops = [UInt16](repeating: 0, count: 4)
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_ voice: Int) -> UInt16 { loops[voice] }
    mutating func timed(at clocks: Int) { events.append("at \(clocks)") }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// A file of the games' engine: its header, `script` at 24, its table after the script, and `resources`,
/// each in turn after the list of them.
private func file(script: [UInt8], resources: [[UInt8]]) -> (bytes: [UInt8], places: [Int]) {
    let table = (24 + script.count + 1) & ~1
    let list = table + 0x58
    var bytes = [UInt8](repeating: 0, count: list)
    bytes.replaceSubrange(4 ..< 6, with: word(0x16))
    bytes.replaceSubrange(16 ..< 18, with: word(table))
    bytes.replaceSubrange(18 ..< 20, with: word(0x20))
    bytes.replaceSubrange(22 ..< 24, with: word(0x20))
    bytes.replaceSubrange(24 ..< 24 + script.count, with: script)
    bytes.replaceSubrange(table ..< table + 4, with: long(0x58))
    bytes.replaceSubrange(table + 12 ..< table + 16, with: long(0x58))
    bytes.replaceSubrange(table + 16 ..< table + 18, with: word(resources.count))
    var at = list + 4 * (resources.count + 1)
    var places: [Int] = []
    for (i, resource) in resources.enumerated() {
        bytes += long(at - (list + 4 * i))
        places.append(at)
        at += (resource.count + 1) & ~1
    }
    bytes += long(0)
    for resource in resources { bytes += resource + (resource.count & 1 == 1 ? [0] : []) }
    return (bytes, places)
}

/// A score (kind nought): its data from 6, which begins `$FF $02`.
private func score(_ data: [UInt8]) -> [UInt8] { [0, 0] + long(6 + data.count) + data }

/// A sample: its kind, size, whether packed, its loop's start and end, and its sound.
private func sample(_ sound: [UInt8], loopStart: Int = 0, loopEnd: Int = 0, packed: Bool = false) -> [UInt8] {
    [2, 0] + long(16 + sound.count) + [packed ? 1 : 0, 0] + long(loopStart) + long(loopEnd) + sound
}

/// The script of the modules here: the three samples in places 0 to 2 (the first transposed by one), and by
/// the song asked for (the word at 12), the score of resource 0 or of resource 4 started at tempo 32.
private let script: [UInt8] = [
    0xA1,
    0xCD, 0, 0, 0, 1, 0, 1,
    0xCD, 0, 1, 0, 2, 0, 0,
    0xCD, 0, 2, 0, 3, 0, 0,
    0x2E, 0x14, 12, 1, 0, 0, 0, 8, 0, 1, 0, 18,
    0x42, 0xA1, 0xA1, 0xA1,
    0x95, 0, 0, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0x42,
    0x95, 0, 4, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0x42,
]

/// The first score: voice 0's sample its first, and a note on it; a tick on, another (its command
/// repeated), and voice 1's sample and note; two ticks on, voice 0's release; a tick on, the end.
private let firstScore: [UInt8] = [
    0xFF, 0x02, 0, 0xFF, 0x01, 0x30, 0x40, 0x81,
    0x31, 0x38, 0xFF, 0x42, 1, 0xFF, 0x41, 0x30, 0x20, 0x82,
    0xFF, 0x03, 0x81,
    0xFF, 0xFF,
]

/// The packed sample's bytes, and what they unpack to (each four bits a step: +1, +2, -34, -21, +34, -34,
/// -1, -1, -34, -34, +1, +1, +1; the last two made nought).
private let packedSound: [UInt8] = [0x10, 0x89, 0x01, 0xF0, 0x77, 0x00, 0x88, 0x8F] + [UInt8](repeating: 0, count: 8)
private let unpackedSound: [UInt8] = [0x10, 0x11, 0x13, 0xF1, 0xDC, 0xFE, 0xDC, 0xDB, 0xDA, 0xB8, 0x96, 0x97, 0x98, 0, 0, 0]

private func module(firstScore data: [UInt8] = firstScore) -> (bytes: [UInt8], places: [Int]) {
    file(script: script, resources: [
        score(data),
        sample([UInt8](0 ..< 32), loopStart: 8, loopEnd: 24),
        sample([UInt8](repeating: 9, count: 16)),
        sample(packedSound, packed: true),
        score([0xFF, 0x02, 1, 0xFF, 0x01, 0x40, 0x40, 0x81, 0xFF, 0xFF]),
    ])
}

@Test func silmarilsDetection() throws {
    let made = module()
    #expect(SilmarilsPlayer.isOne(made.bytes))
    #expect(!SilmarilsPlayer.needsCompanion(made.bytes))
    var noHeader = made.bytes
    noHeader[5] = 0x17
    #expect(!SilmarilsPlayer.isOne(noHeader))
    // (The table's first long must be $58; and at least one resource a score.)
    var noTable = made.bytes
    noTable[(24 + script.count + 1) & ~1 + 3] = 0x5A
    #expect(!SilmarilsPlayer.isOne(noTable))
    // (A header of six bytes before it is passed over.)
    #expect(SilmarilsPlayer.isOne([0, 0, 0x12, 0x34, 0, 1] + made.bytes))
    #expect(SilmarilsPlayer.companionStem(of: "BostonBombClub_title.mok") == "BostonBombClub")
    #expect(SilmarilsPlayer.companionStem(of: "Targhan.mok") == nil)
    // Cut short of its last resource, or with an instruction the player does not have in its script, it is
    // refused.
    #expect(throws: TuneError.self) { _ = try SilmarilsPlayer(Array(made.bytes.prefix(made.bytes.count - 1))) }
    var badScript = made.bytes
    badScript[24] = 0x01
    #expect(throws: TuneError.self) { _ = try SilmarilsPlayer(badScript) }
    let player = try SilmarilsPlayer(made.bytes)
    #expect(player.songCount == 2)
    #expect(player.sampleCount == 3)
}

/// The packed sample is unpacked over its room, and two taken off its size.
@Test func silmarilsUnpacksSamples() throws {
    let made = module()
    let player = try SilmarilsPlayer(made.bytes)
    let at = SilmarilsPlayer.moduleAt + made.places[3]
    #expect((0 ..< 16).map { player.memory[at + 16 + $0] } == unpackedSound)
    #expect((2 ..< 6).map { player.memory[at + $0] } == long(16 + 16 - 2))
}

/// A note turns its voice off and gives Paula its sample, to its loop's end, and its period and volume at
/// once; the voice is turned on after the player's wait, with its loop to go on to. A one-shot sample is
/// given silence after it.
@Test func silmarilsNoteReachesPaula() throws {
    let made = module()
    var player = try SilmarilsPlayer(made.bytes)
    let a = SilmarilsPlayer.moduleAt + made.places[1] + 16, b = SilmarilsPlayer.moduleAt + made.places[2] + 16
    var recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events == ["off 0", "buffer 0 \(a) 12", "at 3500", "on 0", "buffer 0 \(a + 8) 8"])
    // (Its number and the sample's transposition, 49, from the player's table.)
    #expect(player.period(0) == 0x470)
    #expect(player.volume(0) == 64)
    // A tick on: the command repeated, the next note, and voice 1's, of the sample played once.
    recorder.events.removeAll()
    _ = player.run(&recorder)
    #expect(recorder.events == ["off 0", "buffer 0 \(a) 12", "off 1", "buffer 1 \(b) 8", "at 3500", "on 0", "buffer 0 \(a + 8) 8",
                                "on 1", "buffer 1 \(player.silenceAt) 2"])
    #expect(player.period(0) == 0x430)
    #expect(player.volume(0) == 0x38)
    #expect(player.period(1) == 0x4B4)
    #expect(player.volume(1) == 0x20)
}

/// The release gives Paula the sample's sound after its loop, to go on to once she has gone round, and
/// then silence once she has.
@Test func silmarilsRelease() throws {
    let made = module()
    var player = try SilmarilsPlayer(made.bytes)
    let a = SilmarilsPlayer.moduleAt + made.places[1] + 16
    var recorder = Recorder()
    for _ in 0 ..< 3 { _ = player.run(&recorder) }
    recorder.events.removeAll()
    recorder.loops[0] = 5
    _ = player.run(&recorder)
    #expect(recorder.events == ["buffer 0 \(a + 24) 4"])
    // Once she has gone round, silence after the release (and then the score's end, its first note again).
    recorder.events.removeAll()
    recorder.loops[0] = 6
    _ = player.run(&recorder)
    #expect(recorder.events.first == "buffer 0 \(player.silenceAt) 2")
    #expect(recorder.events.contains("off 0"))
    #expect(player.endings == 1)
}

/// A wait counts down by the tempo times eight (a sample is transposed); the score's end is the song's,
/// and it goes on from its start; the song asked for picks its score by the script.
@Test func silmarilsSongsAndLength() throws {
    let made = module()
    let player = try SilmarilsPlayer(made.bytes)
    // (Its notes at ticks 0, 1 and 3, its release at 3 and its end at 4.)
    #expect(player.lengthClocks == UInt64(4 * SilmarilsPlayer.tickClocks))
    var second = try SilmarilsPlayer(made.bytes, song: 1)
    #expect(second.song == 1)
    #expect(second.lengthClocks == UInt64(SilmarilsPlayer.tickClocks))
    var recorder = Recorder()
    _ = second.run(&recorder)
    let b = SilmarilsPlayer.moduleAt + made.places[2] + 16
    #expect(recorder.events.contains("buffer 0 \(b) 8"))
    // (A score with no wait before its end would keep the player in its tick for ever: the song is stopped.)
    var endless = try SilmarilsPlayer(module(firstScore: [0xFF, 0x02, 0, 0xFF, 0x01, 0x30, 0x40, 0xFF, 0xFF]).bytes)
    #expect(endless.lengthClocks == 0)
    recorder.events.removeAll()
    _ = endless.run(&recorder)
    #expect(endless.stops == 1)
    #expect(recorder.events.suffix(3) == ["off 0", "off 1", "off 2"])
    // (Nor would a release repeated, which takes no byte; nor a score read on past the file.)
    var repeated = try SilmarilsPlayer(module(firstScore: [0xFF, 0x02, 0, 0xFF, 0x03, 0x00, 0x81, 0xFF, 0xFF]).bytes)
    _ = repeated.run(&recorder)
    #expect(repeated.stops == 1)
    let last = [0xCD, 0, 0, 0, 0, 0, 1, 0x95, 0, 3, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0x42] as [UInt8]
    let tone = sample([UInt8](repeating: 1, count: 8))
    var runOff = try SilmarilsPlayer(file(script: last, resources: [tone, tone, tone, score([0xFF, 0x02, 0, 0xFF, 0x01, 0x30, 0x40])]).bytes)
    _ = runOff.run(&recorder)
    #expect(runOff.stops == 1)
}

/// A module of no more than two samples has its samples in another file, whose script is run first.
@Test func silmarilsCompanion() throws {
    let samples = file(script: [0xCD, 0, 0, 0, 0, 0, 0, 0x42], resources: [sample([UInt8](repeating: 5, count: 20))])
    let made = file(script: [0x95, 0, 0, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0x42, 0x42],
                    resources: [score([0xFF, 0x02, 0, 0xFF, 0x01, 0x30, 0x40, 0x81, 0xFF, 0xFF])])
    #expect(SilmarilsPlayer.needsCompanion(made.bytes))
    #expect(throws: TuneError.self) { _ = try SilmarilsPlayer(made.bytes) }
    var player = try SilmarilsPlayer(made.bytes, samples: samples.bytes)
    var recorder = Recorder()
    _ = player.run(&recorder)
    let at = player.companionPlace! + samples.places[0] + 16
    #expect(recorder.events.contains("buffer 0 \(at) 10"))
}

@Test func silmarilsIsHeard() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(SilmarilsPlayer(module().bytes), options: options)
    #expect(renderer.info.format == "Silmarils")
    #expect(renderer.subsongCount == 2)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 9600)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 9600)
    #expect((0 ..< 2 * 9600).contains { buffer[$0] != 0 })
}
