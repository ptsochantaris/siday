// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Steve Turner's player, on tiny files made here as the games' are. The thorough check is made
// outside the package: what it tells Paula, tick by tick, against what Wanted Team's player tells her in UADE,
// for UnExoticA's five files.

/// What Paula is told, as a list (the periods and volumes left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16) + word(value & 0xFFFF) }

/// Where the samples' table, the sample, the songs and the patterns' table are.
private let samplesAt = 0x78
private let sampleAt = 0x7E
private let songsAt = 0x8E
private let patternsAt = 0x9C

/// A file of one song, at speed two, on voice 0 alone, which plays one pattern: the notes' instrument 0, notes of
/// two steps, note 36, a rest, and its end; and then the song goes on to `next`. The instrument is a sample of
/// sixteen bytes, its periods shifted down four times; one part, stepped by 16 twice and put back, every tick; its
/// envelope `times` times (nought for the sample played once), up by 100 for two ticks, down by 50 for one, held
/// for three, and down by 128 to silence.
private func file(next: UInt8 = 1, times: UInt8 = 1) -> [UInt8] {
    func place(_ at: Int) -> [UInt8] { long(0x10000 + at - 0x2E) }
    var bytes: [UInt8] = [0x2B, 0x7C] + place(0x2E) + [0x07, 0x3C]
    bytes += [0x2B, 0x7C] + place(songsAt) + [0x07, 0x34]
    bytes += [0x2B, 0x7C] + place(patternsAt) + [0x07, 0x38]
    bytes += [0x2B, 0x7C] + place(samplesAt) + [0x07, 0x40]
    bytes += [0x30, 0x3C, 0x00, 0xFF, 0x32, 0x00, 0x4E, 0xB9] + long(0x23EC) + [0x4E, 0x75]
    var instrument = [UInt8](repeating: 0, count: 48)
    instrument[3] = 16
    instrument[4] = 1
    instrument[5] = 2
    instrument[6] = 1
    instrument[8] = 1
    instrument[0x1E] = 1
    instrument[0x20] = times
    instrument[0x21] = 2
    instrument[0x22] = 100
    instrument[0x23] = 1
    instrument[0x24] = 0xCE
    instrument[0x25] = 4
    instrument[0x27] = 3
    instrument[0x29] = 1
    instrument[0x2A] = 0x80
    instrument[0x2B] = 1
    bytes += instrument
    bytes += long(4) + long(18) + [UInt8](repeating: 0, count: 18)
    bytes += long(4)
    bytes += word(16) + (0 ..< 16).map { UInt8($0 * 9 + 2) }
    bytes += [0, 2, next, 0] + word(12) + word(0) + word(0) + word(0)
    bytes += [0, 0xFF]
    bytes += word(4) + word(0xF0FF)
    bytes += [0xD0, 0x81, 36, 0xFE, 0xFD]
    return bytes
}

@Test func steveTurnerDetection() throws {
    let made = file()
    #expect(made.count == patternsAt + 9)
    #expect(SteveTurnerPlayer.isOne(made))
    var other = made
    other[0x2C] = 0
    #expect(!SteveTurnerPlayer.isOne(other))
    #expect(!SteveTurnerPlayer.isOne(Array(made.prefix(0x2D))))
    let player = try SteveTurnerPlayer(made)
    #expect(player.songCount == 1 && player.sampleCount == 1)
    #expect(player.lengthClocks == 8 * UInt64(SteveTurnerPlayer.tickClocks))
    // (A file with no songs: the first's speed 16.)
    var none = made
    none[songsAt + 1] = 16
    #expect(throws: TuneError.self) { try SteveTurnerPlayer(none) }
}

/// A note is begun on the tick it is read: its sample told Paula and its voice turned off; turned on on the tick
/// after; and its envelope moved from the tick after that.
@Test func steveTurnerNoteReachesPaula() throws {
    var player = try SteveTurnerPlayer(file())
    var ticks: [[String]] = []
    var volumes: [UInt16] = []
    var periods: [UInt16] = []
    for _ in 0 ..< 7 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        ticks.append(recorder.events)
        volumes.append(player.volumeWritten(0))
        periods.append(player.periodWritten(0))
    }
    #expect(ticks[0] == ["buffer 0 \(sampleAt) 8", "off 0"])
    #expect(ticks[1] == ["on 0"])
    #expect(Array(ticks.dropFirst(2)) == [[String]](repeating: [], count: 5))
    // (Up from nought to 100 and 200, down to 150 and held: over four.)
    #expect(volumes == [0, 0, 25, 50, 37, 37, 37])
    // (Note 36, $1DDD, over 16; stepped by 16 and put back.)
    #expect(periods == [477, 478, 477, 478, 477, 478, 477])
}

/// A sample played once is played from the full volume, and told to go on with silence on the tick after it is
/// turned on.
@Test func steveTurnerSamplePlayedOnce() throws {
    var player = try SteveTurnerPlayer(file(times: 0))
    var ticks: [[String]] = []
    var volumes: [UInt16] = []
    for _ in 0 ..< 3 {
        var recorder = Recorder()
        _ = player.run(&recorder)
        ticks.append(recorder.events)
        volumes.append(player.volumeWritten(0))
    }
    #expect(ticks[1] == ["on 0"])
    #expect(ticks[2] == ["buffer 0 \(player.silenceAt) 1"])
    #expect(volumes == [0, 63, 63])
}

/// A song that names none to go on to stops once its last note has died away (the voice silenced on the tenth
/// tick); Wanted Team's player begins it again at its end, on the eighth.
@Test func steveTurnerEnds() throws {
    var player = try SteveTurnerPlayer(file(next: 0))
    #expect(player.lengthClocks == 10 * UInt64(SteveTurnerPlayer.tickClocks))
    var none = TFMXSilentOutput()
    for _ in 0 ..< 9 { _ = player.run(&none) }
    #expect(player.stops == 0 && player.endings == 0 && player.volumeWritten(0) == 5)
    var last = Recorder()
    _ = player.run(&last)
    #expect(player.stops == 1 && last.events == ["off 0"] && player.volumeWritten(0) == 0)
    let wanted = try SteveTurnerPlayer(file(next: 0), asWantedTeam: true)
    #expect(wanted.lengthClocks == 8 * UInt64(SteveTurnerPlayer.tickClocks))
    // (The song that goes on to itself begins again on the tick it ends, and its note again on the next.)
    var looping = try SteveTurnerPlayer(file())
    for _ in 0 ..< 7 { _ = looping.run(&none) }
    var end = Recorder()
    _ = looping.run(&end)
    #expect(looping.endings == 1 && end.events == ["off 0"])
    var again = Recorder()
    _ = looping.run(&again)
    #expect(again.events == ["buffer 0 \(sampleAt) 8", "off 0"])
}

/// Wanted Team's player leaves the voices a song has no list for as they were made, and the game's sound effects
/// of the first instrument are begun on them on the first tick.
@Test func steveTurnerVoicesLeftAlone() throws {
    var player = try SteveTurnerPlayer(file(), asWantedTeam: true)
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == ["buffer 0 \(sampleAt) 8", "off 0"] + (1 ..< 4).map { "buffer \($0) \(sampleAt) 8" })
    var second = Recorder()
    _ = player.run(&second)
    #expect(second.events == ["on 0", "off 1", "off 2", "off 3"])
}

/// Every cut of the file is refused or played without trapping.
@Test func steveTurnerCutFiles() {
    let made = file()
    for cut in 0 ..< made.count {
        let bytes = Array(made.prefix(cut))
        guard SteveTurnerPlayer.isOne(bytes), var player = try? SteveTurnerPlayer(bytes) else { continue }
        var none = TFMXSilentOutput()
        for _ in 0 ..< 50 { _ = player.run(&none) }
    }
}
