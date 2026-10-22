// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the Sonix Music Driver's three players, on tiny scores and instruments made here.
// The thorough check is made outside the package: what they tell Paula, tick by tick, against what
// the players themselves tell her in UADE, for every one of UnExoticA's Sonix scores.

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
private func chunk(_ id: String, _ data: [UInt8]) -> [UInt8] {
    Array(id.utf8) + long(data.count) + data + (data.count % 2 == 1 ? [0] : [])
}

/// A synthesised instrument as Sonix saves it (502 bytes, no header): a sawtooth, at volume 200, with
/// no envelope, vibrato or phase, through the first of its filters (none).
private func synthesised() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 502)
    for i in 0 ..< 128 { bytes[68 + i] = UInt8(truncatingIfNeeded: i * 2 - 128) }
    bytes.replaceSubrange(32 + 0x1AC ..< 32 + 0x1AE, with: word(200))
    bytes.replaceSubrange(32 + 0x1B6 ..< 32 + 0x1B8, with: word(0xFF))
    return bytes
}

/// An SNX score: track 0 gives instrument 1, plays note 60 at velocity $40 for 16 ticks, lets it go
/// and waits 16 more; the other three are empty. Its tempo is 120, and it names `instruments`.
private func snx(instruments: [String] = ["Saw"], tempo: Int = 120) -> [UInt8] {
    let track = word(0x8000) + word(0x3C40) + word(0xC010) + word(0x3C00) + word(0xC010) + word(0xFFFF)
    var bytes = long(track.count) + long(2) + long(2) + long(2) + word(0) + word(tempo)
    bytes += track + word(0xFFFF) + word(0xFFFF) + word(0xFFFF)
    for name in instruments { bytes += Array(name.utf8) + [0] }
    return bytes + [0]
}

/// A TINY score: track 0 gives instrument 1 (`SND`, sampled) and plays note 84 for 8 ticks.
private func tiny() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x160)
    bytes.replaceSubrange(0 ..< 8, with: word(0xFF) + word(0x78) + word(0x80) + word(0x80))
    for t in 0 ..< 4 {
        bytes.replaceSubrange(0x12 + 4 * t ..< 0x14 + 4 * t, with: word(0xFF))
        bytes.replaceSubrange(0x20 + 4 * t ..< 0x24 + 4 * t, with: long(1))
        bytes.replaceSubrange(0x30 + 4 * t ..< 0x34 + 4 * t, with: long(t == 0 ? 0x140 : 0x150))
    }
    bytes.replaceSubrange(68 ..< 72, with: Array("SND".utf8) + [0])
    bytes.replaceSubrange(0x140 ..< 0x148, with: word(0x8101) + word(0x5408) + word(0xFFFF) + word(0))
    bytes.replaceSubrange(0x150 ..< 0x152, with: word(0xFFFF))
    return bytes
}

/// TINY's sampled instrument (32 bytes) naming `SND.ss`, at full volume, its envelope at once full;
/// and the sample: four octaves of sixteen bytes and more, looped from its eighth.
private func tinyInstrument() -> [UInt8] {
    var bytes = long(2) + Array("SND".utf8) + [0] + word(0xFF)
    bytes += word(0xFF) + word(0xFF) + word(0xFF) + word(0)
    bytes += word(0xFF) + word(0xFF) + word(0xFF) + word(0xFF)
    return bytes + [UInt8](repeating: 0, count: 32 - bytes.count)
}

private func sound() -> [UInt8] {
    var bytes = word(16) + word(8) + [0, 3] + [UInt8](repeating: 0, count: 62 - 6)
    for i in 0 ..< 16 * 15 { bytes.append(UInt8(truncatingIfNeeded: i * 7)) }
    return bytes
}

/// A Sonix SMUS: one track, instrument register 0 (`SYN`), a note of 60 for a quarter (its data 2).
private func smus(sonix: Bool = true) -> [UInt8] {
    var body = Array("SMUS".utf8)
    body += chunk("SHDR", word(0x3000) + [0x7F, 1])
    body += chunk("NAME", Array("Test tune".utf8))
    if sonix { body += chunk("SNX1", word(0x80) + word(0x80) + long(0) + long(1) + long(0) + long(0) + long(0)) }
    body += chunk("INS1", [0, 0, 0, 0] + Array("SYN".utf8))
    body += chunk("TRAK", [0x81, 0x00, 0x3C, 0x02, 0xFF, 0xFF])
    return Array("FORM".utf8) + long(body.count) + body
}

@Test func sonixDetection() throws {
    #expect(SonixPlayer.isOne(snx()))
    #expect(SonixPlayer.isOne(tiny()))
    #expect(SonixPlayer.isOne(smus()))
    #expect(try SonixPlayer.check(snx()) == .snx)
    #expect(try SonixPlayer.check(tiny()) == .tiny)
    #expect(try SonixPlayer.check(smus()) == .smus)
    // An IFF SMUS another program saved (no SNX1) is not Sonix's, and is refused as such.
    #expect(!SonixPlayer.isOne(smus(sonix: false)))
    #expect(throws: TuneError.self) { _ = try SonixPlayer(smus(sonix: false), instruments: [("SYN.instr", synthesised())]) }
    // An SNX whose track runs past the file, or that names nothing, is none.
    var short = snx()
    short.removeLast(8)
    #expect(!SonixPlayer.isOne(short))
    var unnamed = snx()
    unnamed.removeLast(5)
    unnamed.append(0)
    #expect(!SonixPlayer.isOne(unnamed))
    #expect(!SonixPlayer.isOne([UInt8](repeating: 0, count: 64)))
}

/// SNX: the note begins at once, on a buffer in chip memory the waveform is written into, every
/// fourth byte for its octave (note 60 is 3420 halved three times, 16 words), at period 427; the
/// buffers alternate; the song ends when its tracks have, and is timed by its tempo (`Clock` over 120).
@Test func sonixSNXNote() throws {
    var player = try SonixPlayer(snx(), instruments: [("saw.INSTR", synthesised())])
    #expect(player.kind == .snx)
    #expect(player.missingInstruments.isEmpty)
    #expect(player.tuneInfo.format == "Sonix Music Driver (SNX)")
    var recorder = Recorder()
    _ = player.run(&recorder)
    let buffer = Int(player.chipAt) + 0x80
    #expect(recorder.events == ["buffer 0 \(buffer) 0", "buffer 0 \(buffer) 16", "on 0"])
    #expect(player.period(0) == 427)
    #expect(player.volume(0) > 0)
    #expect(player.fourVoiceTicks() == (0x376B * 125 / 120 + 1) * 5)
    recorder.events = []
    _ = player.run(&recorder)
    #expect(recorder.events == ["buffer 0 \(buffer - 0x80) 16", "buffer 0 \(buffer - 0x80) 16"])
    let lengthClocks = player.lengthClocks
    let length = try #require(lengthClocks)
    #expect(length % UInt64(player.fourVoiceTicks()) == 0)
    #expect(length / UInt64(player.fourVoiceTicks()) == 33)
}

/// An instrument named but not given is played without, and said; one found by its name with `_` for
/// `.` and in another case is played. With none found the score is refused.
@Test func sonixMissingInstruments() throws {
    let player = try SonixPlayer(snx(instruments: ["Saw", "Bass.L"]), instruments: [("SAW.instr", synthesised())])
    #expect(player.missingInstruments == ["Bass.L.instr"])
    let found = try SonixPlayer(snx(instruments: ["Saw", "Bass.L"]), instruments: [("saw.instr", synthesised()), ("bass_l.instr", synthesised())])
    #expect(found.missingInstruments.isEmpty)
    #expect(throws: TuneError.self) { _ = try SonixPlayer(snx(), instruments: []) }
    // A sampled one whose sample is missing is missing too (here the only one: refused).
    #expect(throws: TuneError.self) { _ = try SonixPlayer(tiny(), instruments: [("SND.instr", tinyInstrument())]) }
}

/// TINY: the sample starts at the octave the note falls in (84 is octave 3 of 0 to 3: the last block,
/// after 16, 32 and 64 bytes, 128 bytes long), turned off and on; the tick after, its loop (from its
/// eighth byte times eight); timed by its tempo's entry of the table.
@Test func sonixTINYNote() throws {
    var player = try SonixPlayer(tiny(), instruments: [("SND.instr", tinyInstrument()), ("snd.ss", sound())])
    #expect(player.kind == .tiny)
    let soundAt = player.places.first?.sound
    let start = try #require(soundAt) + 0x3E + 16 * 7
    var recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events == ["off 0", "off 0", "buffer 0 0 64", "buffer 0 \(start) 64", "on 0"])
    #expect(player.period(0) != 0)
    let timer = SonixPlayer.scoreTimer(index: 0x78 >> 1)
    #expect(player.fourVoiceTicks() == (Int(try #require(timer.timer)) + 1) * 5)
    recorder.events = []
    _ = player.run(&recorder)
    #expect(recorder.events == ["buffer 0 \(start) 32", "buffer 0 \(start + 64) 32"])
    let lengthClocks = player.lengthClocks
    #expect(lengthClocks != nil)
}

/// SMUS: the score is read from its chunks (its note a quarter, 8 of its ticks), the instrument by
/// its register; its name is the song's.
@Test func sonixSMUSNote() throws {
    var player = try SonixPlayer(smus(), instruments: [("SYN.instr", synthesised())])
    #expect(player.kind == .smus)
    #expect(player.title == "Test tune")
    #expect(player.tuneInfo.format == "Sonix Music Driver (SMUS)")
    var recorder = Recorder()
    _ = player.run(&recorder)
    #expect(recorder.events.last == "on 0")
    #expect(player.period(0) == 427)
    // The track's note, as `LoadSCORE` left it: note 60 for 8 ticks.
    let event = player.word(player.long(player.scoreAt + 0x30) + 2)
    #expect(event == 0x3C08)
    let lengthClocks = player.lengthClocks
    #expect(lengthClocks != nil)
}

/// No file cut short, or changed at random, stops the machine or hangs it.
@Test func sonixSurvivesDamage() throws {
    let cases: [([UInt8], [(name: String, bytes: [UInt8])])] = [
        (snx(), [("Saw.instr", synthesised())]),
        (tiny(), [("SND.instr", tinyInstrument()), ("SND.ss", sound())]),
        (smus(), [("SYN.instr", synthesised())]),
    ]
    var seed: UInt64 = 0x5EED
    func random() -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(seed >> 33)
    }
    for (score, instruments) in cases {
        for cut in 0 ..< score.count {
            if var player = try? SonixPlayer(Array(score.prefix(cut)), instruments: instruments) {
                var none = TFMXSilentOutput()
                for _ in 0 ..< 50 { _ = player.run(&none) }
            }
        }
        for _ in 0 ..< 200 {
            var bad = score
            for _ in 0 ..< 1 + random() % 4 { bad[random() % bad.count] = UInt8(truncatingIfNeeded: random()) }
            var badInstruments = instruments
            let i = random() % badInstruments.count
            for _ in 0 ..< 1 + random() % 8 {
                let at = random() % badInstruments[i].bytes.count
                badInstruments[i].bytes[at] = UInt8(truncatingIfNeeded: random())
            }
            if var player = try? SonixPlayer(bad, instruments: badInstruments) {
                var none = TFMXSilentOutput()
                for _ in 0 ..< 100 { _ = player.run(&none) }
            }
        }
    }
}
