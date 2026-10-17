// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of Jochen Hippel's TFMX and of Future Composer, on tiny modules made here.
// The thorough check is made outside the package: what it tells Paula, tick by tick, against
// libtfmxaudiodecoder's, for every song of every one of the modules of UnExoticA's collection.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    var given = [(start: Int, length: UInt16)](repeating: (0, 1), count: 8)
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) {
        given[voice] = (start, length)
        events.append("buffer \(voice) \(start) \(length)")
    }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func put(_ bytes: inout [UInt8], _ at: Int, _ values: [UInt8]) {
    for (i, value) in values.enumerated() { bytes[at + i] = value }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// A TFMX module of one song of two steps, at speed 6: voice 0 plays note $18 of instrument 0 at the
/// first row of the first step, the other voices an empty pattern. The instrument's sound sequence sets
/// sample 0 (sixteen words of a square wave) and transposes by nought; its envelope is one volume. With
/// `player`, a few kilobytes of something else come before the module, as a 68000 player would. With
/// `sevenVoices`, it is TFMX 7V's: longer steps and songs.
private func tfmx(volume: UInt8 = 0x40, player: Int = 0, sevenVoices: Bool = false) -> [UInt8] {
    let h = player
    let stepSize = sevenVoices ? 28 : 12
    let songSize = sevenVoices ? 8 : 6
    let sndSeqs = h + 0x20, volSeqs = sndSeqs + 64, patterns = volSeqs + 64
    let trackTable = patterns + 2 * 64
    let songTable = trackTable + 2 * stepSize
    let sampleHeaders = songTable + 2 * songSize
    let sampleData = sampleHeaders + 30
    var bytes = [UInt8](repeating: 0, count: sampleData + 32 + 16)
    for i in 0 ..< player { bytes[i] = UInt8(truncatingIfNeeded: i * 7 + 1) }
    put(&bytes, h, Array("TFMX".utf8) + [0])
    put(&bytes, h + 4, word(0)) // one sound sequence
    put(&bytes, h + 6, word(0)) // one instrument
    put(&bytes, h + 8, word(1)) // two patterns
    put(&bytes, h + 0xA, word(1)) // two steps
    bytes[h + 0xD] = 0x40 // the patterns' size
    put(&bytes, h + 0x10, word(1)) // one song
    put(&bytes, h + 0x12, word(1)) // one sample
    put(&bytes, sndSeqs, [0xE2, 0x00, 0x00, 0xE1]) // set wave 0, transpose 0, end
    put(&bytes, volSeqs, [0x01, 0x00, 0x00, 0x00, 0x00, volume, 0xE1])
    put(&bytes, patterns, [0x18, 0x00]) // pattern 0: the note; pattern 1 empty
    for step in 0 ..< 2 {
        for voice in 0 ..< (sevenVoices ? 7 : 4) {
            let at = trackTable + step * stepSize + voice * (sevenVoices ? 4 : 3)
            bytes[at] = step == 0 && voice == 0 ? 0 : 1
        }
    }
    // The song: steps 0 to 1, speed 6 (and after it the unused one, all noughts).
    put(&bytes, songTable, word(0) + word(1) + (sevenVoices ? word(0) + word(6) : word(6)))
    // The sample: its name, then its start, its length, its repeat and the repeat's length.
    put(&bytes, sampleHeaders + 0x12, long(0) + word(16) + word(0) + word(0) + word(16))
    for i in 0 ..< 32 { bytes[sampleData + i] = i < 16 ? 0x40 : 0xC0 }
    for i in 0 ..< 16 { bytes[sampleData + 32 + i] = 0x55 }
    return bytes
}

/// A Future Composer 1.0 to 1.3 module of one step: each voice plays note $18 of instrument 0, whose
/// sound sequence sets waveform 0 (sample 10), one of those built in.
private func smod() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x140)
    put(&bytes, 0, Array("SMOD".utf8))
    put(&bytes, 4, long(13)) // the track table's length: one step
    put(&bytes, 8, long(0x80) + long(64)) // the patterns, one
    put(&bytes, 16, long(0xC0) + long(64)) // the sound sequences, one
    put(&bytes, 24, long(0x100) + long(64)) // the instruments, one
    put(&bytes, 32, long(0x140)) // the samples (none)
    put(&bytes, 0x64, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3]) // the step, at speed 3
    put(&bytes, 0x80, [0x18, 0x00])
    put(&bytes, 0xC0, [0xE2, 0x0A, 0x00, 0xE1])
    put(&bytes, 0x100, [0x01, 0x00, 0x00, 0x00, 0x00, 0x40, 0xE1])
    return bytes
}

/// Runs the player for `ticks`, or until the song ends.
private func play(_ player: inout HippelPlayer, ticks: Int) -> Recorder {
    var recorder = Recorder()
    for _ in 0 ..< ticks {
        _ = player.run(&recorder)
        if player.songEnded { break }
    }
    return recorder
}

@Test func hippelDetection() {
    func kind(_ data: [UInt8]) -> HippelDecoder.InitKind? { HippelDecoder.probe(data)?.kind }
    #expect(kind(smod()) == .smod)
    #expect(kind(Array("FC14".utf8) + [0, 0, 0, 0]) == .fc14)
    #expect(kind(Array("FC13".utf8) + [0, 0, 0, 0]) == nil)
    #expect(kind(tfmx()) == .tfmx)
    #expect(kind(Array("TFMX".utf8) + [1]) == nil)
    // The module after a player, found by its mark.
    let behind = tfmx(player: 0x1000)
    #expect(HippelDecoder.probe(behind)?.header == 0x1000)
    // Compressed: "COSO", and "TFMX" $20 after it, alone or after a player.
    var coso = [UInt8](repeating: 0, count: 0x40)
    put(&coso, 0, Array("COSO".utf8))
    put(&coso, 0x20, Array("TFMX".utf8))
    #expect(kind(coso) == .coso)
    var cosoBehind = [UInt8](repeating: 0x11, count: 0xC00) + coso + [UInt8](repeating: 0, count: 0x40)
    cosoBehind[3] = 0x22
    #expect(HippelDecoder.probe(cosoBehind)?.header == 0xC00)
    // A TFMX mark that is a compressed module's is not taken for TFMX.
    #expect(HippelDecoder.probe(cosoBehind)?.kind == .coso)
    #expect(kind(Array("MCMD".utf8) + [UInt8](repeating: 0, count: 0x20)) == .mcmd)
    #expect(kind([UInt8](repeating: 0x4E, count: 4096)) == nil)
    #expect(kind([]) == nil)
    // A file that is a player's code alone is told, but not taken.
    let code: [UInt8] = [0x0C, 0x00, 0x00, 0xFE, 0x66, 0x00, 0x11, 0x51, 0x00, 0x10, 0x11, 0x59, 0x00, 0x20,
                         0x00, 0x00, 0x0C, 0x00, 0x00, 0xFD, 0x66, 0x00, 0x11, 0x51, 0x00, 0x10, 0x11, 0x59, 0x00, 0x20]
    #expect(HippelDecoder.probe(code)?.header == 0xFFFF_FFFF)
    #expect(!HippelPlayer.isOne(code))
    #expect(HippelPlayer.isOne(tfmx()))
}

@Test func hippelNoteReachesPaula() throws {
    let file = tfmx()
    var player = try HippelPlayer(file)
    let format = player.format
    #expect(format == .tfmx)
    let voiceCount = player.voiceCount
    #expect(voiceCount == 4)
    let songCount = player.songCount
    #expect(songCount == 1)
    let rate = player.rate
    #expect(rate == 50 << 8)
    var recorder = Recorder()
    _ = player.run(&recorder)
    // The sample (after the header, the sequences, the patterns, the steps, the songs and its own
    // header) is given, and voice 0 started.
    let sampleData = 0x20 + 64 + 64 + 128 + 24 + 12 + 30
    #expect(recorder.events.contains("buffer 0 \(sampleData) 16"))
    #expect(recorder.events.last == "on 0")
    #expect(player.period(0) == 0x01AC) // note $18
    #expect(player.volume(0) == 64)
    // Two ticks later, its repeat.
    recorder.events = []
    _ = player.run(&recorder)
    _ = player.run(&recorder)
    #expect(recorder.events == ["buffer 0 \(sampleData) 16"])

    // The instrument's volume, as it is in the module.
    var quieter = try HippelPlayer(tfmx(volume: 0x20))
    _ = quieter.run(&recorder)
    #expect(quieter.volume(0) == 0x20)
    // And after a player.
    var behind = try HippelPlayer(tfmx(player: 0x1000))
    recorder = Recorder()
    _ = behind.run(&recorder)
    #expect(recorder.events.contains("buffer 0 \(0x1000 + sampleData) 16"))
    #expect(behind.period(0) == 0x01AC)
}

@Test func hippelSongEnds() throws {
    var player = try HippelPlayer(tfmx())
    // Two steps of 32 rows at speed 6, from the first tick: the end on tick 385, at 20 ms a tick.
    let duration = player.duration
    #expect(duration == 385 * 20)
    var recorder = Recorder()
    var ticks = 0
    while !player.songEnded, ticks < 1000 {
        _ = player.run(&recorder)
        ticks += 1
    }
    #expect(ticks == 385)
    #expect(player.volume(0) == 0)
    let endings = player.endings
    #expect(endings == 1)
    let stops = player.stops
    #expect(stops == 0)
    // Looped, it plays on.
    try player.select(song: 0)
    player.loops = true
    _ = play(&player, ticks: 1000)
    let ended = player.songEnded
    #expect(!ended)
    let endingsLooped = player.endings
    #expect(endingsLooped == 2)
}

@Test func hippelSevenVoices() throws {
    var player = try HippelPlayer(tfmx(sevenVoices: true))
    let format = player.format
    #expect(format == .tfmx7V)
    #expect(format.libraryName == "TFMX 7V/Hippel (AMIGA)")
    let voiceCount = player.voiceCount
    #expect(voiceCount == 7)
    let recorder = play(&player, ticks: 1)
    #expect(recorder.events.last == "on 0")
    #expect(player.period(0) == 0x01AC)
}

@Test func hippelFutureComposerWaveform() throws {
    var player = try HippelPlayer(smod())
    let format = player.format
    #expect(format == .futureComposer10)
    let songCount = player.songCount
    #expect(songCount == 1)
    let recorder = play(&player, ticks: 1)
    // Waveform 0 of those built in, sixteen words, which the memory holds after the module.
    let wavesAt = player.wavesAt
    #expect(recorder.given[0].start == wavesAt)
    #expect(recorder.given[0].length == 16)
    let firstByte = player.memory[wavesAt]
    #expect(firstByte == 0xC0)
    #expect(player.period(0) == 0x01AC)
    #expect(player.volume(0) == 64)
}

@Test func hippelGarbageDoesNotTrap() {
    var seed: UInt32 = 12345
    func next() -> UInt8 {
        seed = seed &* 1_103_515_245 &+ 12345
        return UInt8(truncatingIfNeeded: seed >> 16)
    }
    let heads: [[UInt8]] = [
        Array("TFMX".utf8) + [0], Array("SMOD".utf8) + [0, 0], Array("FC14".utf8) + [0, 0], Array("MCMD".utf8) + [0],
        Array("COSO".utf8) + [UInt8](repeating: 0, count: 28) + Array("TFMX".utf8),
    ]
    for head in heads {
        for size in [8, 40, 300] {
            for _ in 0 ..< 2 {
                var bytes = head + (0 ..< size).map { _ in next() }
                // (Future Composer's track table kept short, so that the songs played through to find
                // their lengths are short.)
                if bytes.count > 6, head[0] != 0x54 { bytes[4] = 0; bytes[5] = 0; bytes[6] = 0 }
                guard var player = try? HippelPlayer(bytes) else { continue }
                _ = play(&player, ticks: 500)
                for song in 1 ..< min(player.songCount, 4) {
                    try? player.select(song: song)
                    _ = play(&player, ticks: 200)
                }
            }
        }
        // Cut short.
        let whole = head == heads[0] ? tfmx() : head == heads[1] ? smod() : head
        for cut in stride(from: 0, through: whole.count, by: 5) {
            if var player = try? HippelPlayer(Array(whole[0 ..< cut])) { _ = play(&player, ticks: 100) }
        }
    }
}
