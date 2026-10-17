// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the TFMX player, on tiny modules made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against libtfmxaudiodecoder's, for every song of every
// one of the 322 modules of UnExoticA's collection.

/// What Paula is told, as a list, and each voice's state as the comparison's Paula keeps it.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    var playing = [Bool](repeating: false, count: 8)
    var given = [(start: Int, length: UInt16)](repeating: (0, 1), count: 8)
    mutating func on(_ voice: Int) { playing[voice] = true; events.append("on \(voice)") }
    mutating func off(_ voice: Int) { playing[voice] = false; events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) {
        given[voice] = (start, length)
        events.append("buffer \(voice) \(start) \(length)")
    }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func put(_ bytes: inout [UInt8], _ at: Int, _ values: [UInt8]) {
    for (i, value) in values.enumerated() { bytes[at + i] = value }
}

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// A module of one song of one step: track 0 plays pattern 0, a note of macro 0 on voice 0, waits, and
/// ends. The macro sets the sample (the first 32 bytes of the samples), its volume and the note's period,
/// and starts it. The rest of the tracks are idle. With `sevenVoices`, a step before it says 7VOICE.
private func module(note: UInt8 = 30, volume: UInt8 = 0x40, speed: UInt8 = 5, sevenVoices: Bool = false) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0xA40)
    put(&bytes, 0, Array("TFMX-SONG test".utf8))
    let last: UInt8 = sevenVoices ? 1 : 0
    put(&bytes, 0x140, [0, last]) // song 0: steps 0 to `last`
    put(&bytes, 0x180, [0, speed])
    // The patterns' places at $400, the macros' at $600, the track table at $800.
    put(&bytes, 0x400, long(0x900))
    put(&bytes, 0x600, long(0xA00))
    var step = 0x800
    if sevenVoices {
        put(&bytes, step, [0xEF, 0xFE, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00])
        step += 16
    }
    put(&bytes, step, [0x00, 0x00, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0])
    // The pattern: the note (macro 0, volume 15, voice 0), a wait of 5, the end.
    put(&bytes, 0x900, [note, 0x00, 0xF0, 0x00, 0xF3, 0x05, 0x00, 0x00, 0xF0, 0x00, 0x00, 0x00])
    // The macro: SetBegin 0, SetLen 16 words, SetVolume, AddNote 0, DMAon, Stop.
    put(&bytes, 0xA00, [0x02, 0, 0, 0, 0x03, 0, 0, 16, 0x0E, 0, 0, volume, 0x08, 0, 0, 0, 0x01, 0, 0, 0, 0x07, 0, 0, 0])
    return bytes
}

private let samples = (0 ..< 64).map { UInt8(truncatingIfNeeded: $0 * 4) }

/// Runs the player until the song ends, or for `ticks`.
private func play(_ player: inout TFMXPlayer, ticks: Int) -> Recorder {
    var recorder = Recorder()
    for _ in 0 ..< ticks {
        _ = player.run(&recorder)
        if player.songEnded { break }
    }
    return recorder
}

@Test func tfmxDetection() {
    #expect(TFMXPlayer.isOne(module()))
    #expect(TFMXPlayer.isOne(Array("TFMX ".utf8) + [0, 0]))
    #expect(TFMXPlayer.isOne(Array("TFHD".utf8)))
    #expect(!TFMXPlayer.isOne(Array("TFMX".utf8)))
    #expect(!TFMXPlayer.isOne(Array("TFMXSONG".utf8)))
    #expect(!TFMXPlayer.isOne([UInt8](repeating: 0, count: 1024)))
}

@Test func tfmxNoteReachesPaula() throws {
    var player = try TFMXPlayer(module(), samples: samples)
    // (The player cannot be copied, so what is looked at is taken from it first.)
    let (songs, voices, format, rate, size) = (player.songCount, player.voiceCount, player.format, player.rate, player.memorySize)
    #expect(songs == 1 && voices == 4 && format == .pro && rate == 50 << 8)
    #expect(size == 0xA40 + 64)
    // Before the first tick, Paula has been told nothing.
    let (periodBefore, volumeBefore) = (player.period(0), player.volume(0))
    #expect(periodBefore == 0 && volumeBefore == 0)
    var recorder = Recorder()
    _ = player.run(&recorder)
    // The note was read on the first tick; its macro runs on the second.
    #expect(recorder.events.isEmpty)
    _ = player.run(&recorder)
    // The sample is set, and after AddNote the macro waits a tick; then it starts the voice, at the
    // tick's end.
    #expect(recorder.events == ["buffer 0 2624 1", "buffer 0 2624 16"])
    #expect(!recorder.playing[0])
    _ = player.run(&recorder)
    #expect(recorder.events == ["buffer 0 2624 1", "buffer 0 2624 16", "on 0"])
    #expect(recorder.playing[0])
    // Note 30 is period $12F; volume 64, with the fade at its full 64.
    let (period, volume, sample) = (player.period(0), player.volume(0), player.memory[0xA40 + 5])
    #expect(period == 0x12F && volume == 64)
    #expect(sample == samples[5])
}

@Test func tfmxSongEnds() throws {
    var player = try TFMXPlayer(module(), samples: samples)
    // At speed 5, the pattern goes on every sixth tick: the note and the wait at the first, the wait
    // counted down five times, and the end at the 37th tick.
    let duration = player.duration
    #expect(duration == 37 * 20)
    _ = play(&player, ticks: 1000)
    let ended = player.songEnded
    #expect(ended)
    var ticks = 0
    var silent = Recorder()
    try player.select(song: 0)
    while !player.songEnded, ticks < 1000 {
        _ = player.run(&silent)
        ticks += 1
    }
    #expect(ticks == 37)
    // Looped, it goes back to its beginning and does not end.
    try player.select(song: 0)
    player.loops = true
    for _ in 0 ..< 200 { _ = player.run(&silent) }
    let endedLooped = player.songEnded
    #expect(!endedLooped)
}

@Test func tfmxSevenVoices() throws {
    let player = try TFMXPlayer(module(sevenVoices: true), samples: samples)
    let (voices, format, rate) = (player.voiceCount, player.format, player.rate)
    #expect(voices == 8 && format == .sevenVoices)
    // 7VOICE's last byte, nought, is 125 beats a minute: 50 ticks a second.
    #expect(rate == (125 << 8) * 2 / 5)
}

@Test func tfmxNeedsItsSamples() {
    #expect(throws: TuneError.self) { _ = try TFMXPlayer(module(), samples: nil) }
}

@Test func tfmxSingleFile() throws {
    // TFHD: a header of 18 bytes, then the module and its samples.
    let mdat = module()
    var file = Array("TFHD".utf8) + long(0x12) + [0, 0] + long(mdat.count) + long(samples.count)
    file += mdat + samples
    var merged = try TFMXPlayer(file, samples: nil)
    var pair = try TFMXPlayer(mdat, samples: samples)
    var a = Recorder(), b = Recorder()
    for _ in 0 ..< 40 {
        _ = merged.run(&a)
        _ = pair.run(&b)
        let same = merged.period(0) == pair.period(0) && merged.volume(0) == pair.volume(0)
        #expect(same)
    }
    // The same events, 18 bytes further on.
    #expect(!a.events.isEmpty)
    #expect(a.events == b.events.map { $0.split(separator: " ").map { $0 == "2624" ? "2642" : String($0) }.joined(separator: " ") })
}

// (A song's speed is its tempo, when it is $10 or more; at a tempo of thousands, the player's playing
// of the song through once, as it is read, to find its length, is millions of ticks. Neither part of
// this test makes one: the samples after a module cut short are noughts, and its speeds are not
// changed. Even so, a song that no longer ends is played through for 59 minutes, so this is a few
// files only: the thorough test of broken files is made outside the package, against the library.)
@Test func tfmxGarbageDoesNotTrap() {
    let whole = module()
    let silence = [UInt8](repeating: 0, count: 64)
    var tried = 0
    // Cut short at every 13th length, but for those that keep the song's step and lose its pattern,
    // which make a song that never ends.
    for length in Array(stride(from: 0, to: 0x7C0, by: 13)) + Array(stride(from: 0x90C, through: whole.count, by: 13)) {
        if var player = try? TFMXPlayer(Array(whole[..<length]), samples: silence) {
            var recorder = Recorder()
            for _ in 0 ..< 100 { _ = player.run(&recorder) }
            tried += 1
        }
    }
    #expect(tried > 0)
    // With bytes changed, from a fixed sequence.
    var seed: UInt32 = 12345
    func next() -> Int {
        seed = seed &* 1_103_515_245 &+ 12345
        return Int(seed >> 8)
    }
    for _ in 0 ..< 40 {
        var bytes = whole
        for _ in 0 ..< 1 + next() % 16 {
            let at = next() % bytes.count
            if at < 0x180 || at >= 0x1C0 { bytes[at] = UInt8(truncatingIfNeeded: next()) }
        }
        if var player = try? TFMXPlayer(bytes, samples: next() % 4 == 0 ? [] : samples) {
            var recorder = Recorder()
            for _ in 0 ..< 100 { _ = player.run(&recorder) }
            for song in 0 ..< min(player.songCount, 2) {
                try? player.select(song: song)
                _ = player.run(&recorder)
            }
        }
    }
}

@Test func tfmxTicksAreAsLongAsChrisHuelsbecksPlayersMadeThem() {
    // TFMX Professional's timer for 125 beats a minute, and the first player's, in its upper byte.
    #expect(TFMXTiming.timerAtStart(speed: 125, old: false) == 14323) // $1B51F8 / 125
    #expect(TFMXTiming.timerAtStart(speed: 125, old: true) == 57 << 8)
    #expect(TFMXTiming.timerAtStart(speed: 5, old: false) == nil && TFMXTiming.timerAtStart(speed: 20, old: true) == nil)
    // Too few beats for a word: the 68000 leaves what was to be divided.
    #expect(TFMXTiming.timerAtStart(speed: 16, old: false) == 0x51F8)
    // The Speed command: below nought or nought leaves the timer; the first player keeps its lower byte.
    #expect(TFMXTiming.timer(afterSpeed: 0xFF00, was: 1234, old: false) == 1234)
    #expect(TFMXTiming.timer(afterSpeed: 100, was: nil, old: false) == 17904)
    #expect(TFMXTiming.timer(afterSpeed: 100, was: 0x1234, old: true) == 0x4734) // $1C00 / 100 is 71
    var timing = TFMXTiming()
    #expect(timing.fourVoiceTick(rate: 50 << 8, timer: 14323) == 14323 * 5)
    // At fifty a second, the library's rate: 70,937.9 clocks, the part over carried.
    let ticks = (0 ..< 10).map { _ in timing.fourVoiceTick(rate: 50 << 8, timer: nil) }
    #expect(ticks.reduce(0, +) == 709_379)
    // TFMX 7V: 320 bytes a tick at a period of 224, longer or shorter by its tempo.
    #expect(TFMXTiming.sevenVoiceBytes(tempo: 0) == 320 && TFMXTiming.sevenVoiceBytes(tempo: -50) == 218)
    #expect(TFMXTiming.sevenVoiceBytes(tempo: 10) == 352)
    #expect(timing.sevenVoiceTick(tempo: 0) == 320 * 224)
}

@Test func tfmxSevenVoicesAreMixedAsTheirPlayerMixedThem() {
    // A sample of 64 bytes at the start of memory, and silence after it.
    let memory = UnsafeMutablePointer<Int8>.allocate(capacity: 4096)
    defer { memory.deallocate() }
    memory.initialize(repeating: 0, count: 4096)
    for i in 0 ..< 64 { memory[i] = Int8(truncatingIfNeeded: i * 4 - 128) }
    var mixer = TFMXSevenVoices(silence: 2048)
    mixer.voices[0].start = 0
    mixer.voices[0].length = 32
    mixer.voices[0].period = 224
    mixer.voices[0].volume = 64
    mixer.voices[0].on = true
    let out = UnsafeMutablePointer<Int8>.allocate(capacity: 80)
    let parts = UnsafeMutablePointer<Float>.allocate(capacity: 320)
    defer { out.deallocate(); parts.deallocate() }
    mixer.mix(memory, size: 4096, into: out, count: 80, parts: parts)
    // At the mixing's own period, a sample a byte; a volume of 64 taken as 63; round again after 64,
    // a byte on: the fraction a voice starts with is $FFFF, and its carry comes as it goes round.
    #expect(out[1] == Int8((-124 * 63) >> 6) && out[32] == 0 && out[63] == Int8((124 * 63) >> 6))
    #expect(out[64] == out[1] && out[65] == out[2] && mixer.voices[0].loops == 1)
    // Four voices at full, added, are clipped to a byte.
    for v in 1 ..< 4 { mixer.voices[v] = mixer.voices[0] }
    mixer.voices[0].restart = true
    for v in 1 ..< 4 { mixer.voices[v].restart = true }
    mixer.mix(memory, size: 4096, into: out, count: 80, parts: parts)
    #expect(out[0] == -128 && out[63] == 127)
    // A sample of fewer than 32 words is silence in its place.
    var short = TFMXSevenVoices(silence: 2048)
    short.voices[0] = TFMXSevenVoices.Voice(start: 0, length: 31, period: 224, volume: 64, on: true)
    short.mix(memory, size: 4096, into: out, count: 80, parts: parts)
    #expect((0 ..< 80).allSatisfy { out[$0] == 0 })
}

@Test func tfmxIsPlayedAsAnAmigaTuneWithItsSamples() throws {
    let renderer = try TuneLoader.load(module(speed: 0), format: .tfmx, path: "games/test.mdat", companions: [samples])
    #expect(renderer.info.format == "TFMX" && renderer.info.detail == "TFMX Pro")
    #expect(renderer.isPlayedOnAnAmiga && renderer.endsByLooping && renderer.channelCount == 4)
    var buffer = [Float](repeating: 0, count: 9600)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
    #expect(buffer.contains { $0 != 0 })
    // Without them, the names they were looked for by.
    #expect {
        try TuneLoader.load(module(), format: .tfmx, path: "games/test.mdat")
    } throws: { error in
        guard case let .missingCompanion(why) = error as? TuneError else { return false }
        return why.hasPrefix("its samples are kept in a file of their own, test.smpl, test.sam, smpl.set or set.smpl")
    }
    #expect(Companions.wanted(for: .tfmx, fileName: "mdat.title")[0].names == ["mdat.smpl", "mdat.sam", "smpl.title", "smpl.set", "set.smpl"])
    #expect(Companions.wanted(for: .tfmx, fileName: "song.tfx")[0].names.first == "song.sam")
    #expect(TuneFormat(fileExtension: "MDAT") == .tfmx && TuneFormat(fileExtension: "tfx") == .tfmx)
    // A TFMX 7V module has seven voices to show.
    let seven = try TuneLoader.load(module(sevenVoices: true), format: .tfmx, companions: [samples])
    #expect(seven.info.detail == "TFMX 7V" && seven.channelCount == 7)
    buffer.withUnsafeMutableBufferPointer { seven.render(into: $0.baseAddress!, frames: 4800) }
}

@Test func tfmxSongWhoseTracksAllStopPlaysOn() throws {
    // The pattern ends with Stop, and no track has anything more to play.
    var stopping = module()
    put(&stopping, 0x908, [0xF4, 0, 0, 0])
    var player = try TFMXPlayer(stopping, samples: samples)
    player.loops = true
    var recorder = Recorder()
    for _ in 0 ..< 200 { _ = player.run(&recorder) }
    #expect(player.stops >= 1)
    var playingOn = try TFMXPlayer(stopping, samples: samples)
    playingOn.loops = true
    playingOn.playsOnInEndlessPatterns = true
    for _ in 0 ..< 200 { _ = playingOn.run(&recorder) }
    #expect(playingOn.stops == 0 && playingOn.endings == 1 && !playingOn.songEnded)
}
