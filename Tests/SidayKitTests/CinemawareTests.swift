// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Cinemaware's player, on tiny files made here as Wings' are. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what Wanted Team's player tells her in UADE, for UnExoticA's
// files.

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

/// An instrument numbered `number`, of one wave, `Snd`, for every note: its frequency 428, its sound's first eight
/// words played and then its last four; its volume's envelope up to 128 at 64 a tick and held, and when let go down
/// to nought at 64 a tick.
private func instrument(_ number: UInt8) -> [UInt8] {
    var bytes: [UInt8] = [number] + Array("Test".utf8) + [UInt8](repeating: 0, count: 13)
    bytes += [0, 0, 0, 0, 0, 2, 3, 7] + [UInt8](repeating: 128, count: 8) + [UInt8](repeating: 0, count: 8)
    bytes += [3, 0] + [128, 0, 0, 0, 0, 0, 0, 0] + [64, 0, 0, 64, 0, 0, 0, 0]
    bytes += Array("Snd".utf8) + [0, 0, 0] + long(1) + [0, 127] + word(428) + long(0) + long(8) + long(16)
    for _ in 0 ..< 2 { bytes += Array("NoWave".utf8) + long(0) + [0, 127] + word(427) + long(0) + long(0) + long(0) }
    return bytes
}

/// A file of instrument 0 and, if asked, 1; channel 0 on voice 0, the rest on any voice; and its events.
private func file(_ events: [[UInt8]], two: Bool = false) -> [UInt8] {
    var bytes = Array("IBLK".utf8) + [two ? 2 : 1, 0] + instrument(0) + (two ? instrument(1) : [])
    bytes += [0] + [UInt8](repeating: 4, count: 15)
    bytes += Array("ASEQ".utf8)
    for event in events { bytes += event }
    return bytes
}

/// A note begun on channel 0, let go two ticks later, and the song's end a tick after that.
private let oneNote: [[UInt8]] = [[0, 0, 0x90, 60, 100], [0, 2, 0x80, 60, 0], [0, 1, 0x10, 0x2F, 0]]

/// The 8SVX file of the wave's sound: sixteen bytes.
private let sound: [UInt8] = {
    let vhdr = Array("VHDR".utf8) + long(20) + [UInt8](repeating: 0, count: 20)
    let body = Array("BODY".utf8) + long(16) + (0 ..< 16).map { UInt8($0 * 8) }
    let form = Array("8SVX".utf8) + vhdr + body
    return Array("FORM".utf8) + long(form.count) + form
}()

private let folder = [(name: "snd", bytes: sound), (name: "Other", bytes: [UInt8](repeating: 1, count: 40))]

@Test func cinemawareDetection() throws {
    let made = file(oneNote)
    #expect(CinemawarePlayer.isOne(made))
    #expect(CinemawarePlayer.waveNames(made) == ["Snd"])
    var other = made
    other[4] = 0
    #expect(!CinemawarePlayer.isOne(other))
    #expect(!CinemawarePlayer.isOne(Array(made.prefix(160))))
    let player = try CinemawarePlayer(made, instruments: folder)
    #expect(player.songCount == 1 && player.waveCount == 1 && player.missingWaves.isEmpty)
    #expect(player.tuneInfo.format == "Cinemaware" && player.tuneInfo.shortfalls.isEmpty)
    // (The song must have its end.)
    #expect(throws: TuneError.self) { try CinemawarePlayer(Array(made.prefix(made.count - 1)), instruments: folder) }
    // (And its instruments.)
    #expect(throws: TuneError.self) { try CinemawarePlayer(made, instruments: []) }
}

/// A note is begun on its event's tick: its voice turned off and told its sound and its period $80, and then made
/// and turned on; told its loop on its second tick. Its volume's envelope rises at 64 a tick to 128, of a velocity
/// of 100 (99 of 127 at the channel's volume), and falls when it is let go; the song's end turns every voice off.
@Test func cinemawareNoteReachesPaula() throws {
    var player = try CinemawarePlayer(file(oneNote), instruments: folder)
    #expect(player.lengthClocks == UInt64(4 * CinemawarePlayer.tickClocks))
    let at = player.places[0].sound
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events == ["off 0", "buffer 0 \(at) 8", "on 0"])
    #expect(player.periodWritten(0) == 428 && player.volumeWritten(0) == 12)
    var second = Recorder()
    _ = player.run(&second)
    #expect(second.events == ["buffer 0 \(at + 8) 4", "on 0"])
    #expect(player.volumeWritten(0) == 24)
    var none = TFMXSilentOutput()
    _ = player.run(&none)
    #expect(player.volumeWritten(0) == 12 && player.endings == 0)
    var fourth = Recorder()
    _ = player.run(&fourth)
    #expect(fourth.events.isEmpty && player.endings == 1)
    var fifth = Recorder()
    _ = player.run(&fifth)
    #expect(fifth.events == ["off 0", "off 1", "off 2", "off 3"])
    // After 25 ticks of silence the song begins again.
    for _ in 0 ..< 24 { _ = player.run(&none) }
    var again = Recorder()
    _ = player.run(&again)
    #expect(again.events == ["off 0", "buffer 0 \(at) 8", "on 0"])
}

/// A channel of any voice takes a free one for each note; a bend of the pitch moves it by its range (two notes
/// here) at its fullest.
@Test func cinemawareVoicesAndBend() throws {
    let events: [[UInt8]] = [[0, 0, 0x91, 60, 100], [0, 0, 0x91, 62, 100], [0, 1, 0xE1, 0, 0x7F], [0, 1, 0x10, 0x2F, 0]]
    var player = try CinemawarePlayer(file(events, two: true), instruments: folder)
    var first = Recorder()
    _ = player.run(&first)
    #expect(first.events.filter { $0.hasPrefix("on") } == ["on 0", "on 1"])
    // (Note 62 is two notes above 428, 381 of Paula's period.)
    #expect(player.periodWritten(0) == 428 && player.periodWritten(1) == 381)
    var none = TFMXSilentOutput()
    _ = player.run(&none)
    // (A bend of 63 of 64, of two notes' range: 40 * 63 / 64 of 240ths of an octave, 39.)
    #expect(player.periodWritten(0) == 382)
}

/// A wave whose file is not in the folder is not heard, and is said not to be; the song plays the rest.
@Test func cinemawareMissingWave() throws {
    var made = file(oneNote, two: true)
    // (Instrument 1's wave names another file.)
    let wave = 6 + 138 + 0x3C
    made[wave ..< wave + 3] = ArraySlice(Array("Abc".utf8))
    let player = try CinemawarePlayer(made, instruments: folder)
    #expect(player.missingWaves == ["Abc"] && player.waveCount == 1)
    #expect(player.tuneInfo.shortfalls.count == 1)
}

@Test func cinemawareSurvivesDamage() throws {
    let made = file([[0, 0, 0x90, 60, 100], [0, 0, 0x91, 61, 90], [0, 3, 0xB0, 64, 127], [0, 1, 0x80, 60, 0],
                     [0, 0, 0xE0, 0, 3], [0, 2, 0xB0, 64, 0], [0, 1, 0x10, 0x2F, 0]], two: true)
    var seed: UInt64 = 7
    func random(_ n: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 33) % UInt64(n))
    }
    for cut in 0 ..< made.count {
        _ = try? CinemawarePlayer(Array(made.prefix(cut)), instruments: folder)
    }
    for _ in 0 ..< 300 {
        var bytes = made
        for _ in 0 ... random(8) { bytes[random(bytes.count)] = UInt8(random(256)) }
        guard var player = try? CinemawarePlayer(bytes, instruments: folder) else { continue }
        var none = TFMXSilentOutput()
        for _ in 0 ..< 200 { _ = player.run(&none) }
    }
}
