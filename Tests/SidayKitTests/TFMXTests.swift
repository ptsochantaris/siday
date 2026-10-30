// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the TFMX player, on tiny modules made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against libtfmxaudiodecoder's, for every song of every
// one of the 322 modules of UnExoticA's collection.

/// What Paula is told, as a list, and each voice's state as the comparison's Paula keeps it: how many
/// times each has gone round is as a test sets it.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    var playing = [Bool](repeating: false, count: 8)
    var given = [(start: Int, length: UInt16)](repeating: (0, 1), count: 8)
    var loops = [UInt16](repeating: 0, count: 8)
    mutating func on(_ voice: Int) { playing[voice] = true; events.append("on \(voice)") }
    mutating func off(_ voice: Int) { playing[voice] = false; events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) {
        given[voice] = (start, length)
        events.append("buffer \(voice) \(start) \(length)")
    }
    func loopCount(_ voice: Int) -> UInt16 { playing[voice] ? loops[voice] : 0 }
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
        // (With $FF00, as the modules have it, by which UADE knows them.)
        put(&bytes, step, [0xEF, 0xFE, 0x00, 0x03, 0xFF, 0x00, 0x00, 0x00])
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
    // The Speed command: below nought or nought leaves the timer; the first player keeps its lower byte,
    // $F0 from its TIMERINIT if the song's start set no timer, and without a tempo goes back to the frame
    // unless its start set one.
    #expect(TFMXTiming.timer(afterSpeed: 0xFF00, was: 1234, old: false) == 1234)
    #expect(TFMXTiming.timer(afterSpeed: 100, was: nil, old: false) == 17904)
    #expect(TFMXTiming.timer(afterSpeed: 100, was: 0x1234, old: true) == 0x4734) // $1C00 / 100 is 71
    #expect(TFMXTiming.timer(afterSpeed: 100, was: nil, old: true, startedWithTimer: false) == 0x47F0)
    #expect(TFMXTiming.timer(afterSpeed: 0xFF00, was: 0x47F0, old: true, startedWithTimer: false) == nil)
    #expect(TFMXTiming.timer(afterSpeed: 0, was: 0x4700, old: true, startedWithTimer: true) == 0x4700)
    #expect(TFMXTiming.timer(afterSpeed: 0xFF00, was: 0x47F0, old: false, startedWithTimer: false) == 0x47F0)
    var timing = TFMXTiming()
    // The CIA takes one count more than it is set to to come round.
    #expect(timing.fourVoiceTick(rate: 50 << 8, timer: 14323) == 14324 * 5)
    // At fifty a second, DeliTracker's timer of $376B; at another rate, the library's, the part over carried.
    #expect(timing.fourVoiceTick(rate: 50 << 8, timer: nil) == 14188 * 5)
    let ticks = (0 ..< 10).map { _ in timing.fourVoiceTick(rate: 60 << 8, timer: nil) }
    #expect(ticks.reduce(0, +) == 591_149)
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

// MARK: As Chris Hülsbeck's players play them

/// The header of TFMX before its first release, which the library, and UADE, take to be TFMX 1.x's.
private let oldHeader = Array("TFMX ".utf8) + [0, 0, 1]

/// A module of one song, laid out as an unpacked module is (the patterns' places at $400, the macros'
/// at $600, the track table at $800, and the patterns and macros after it): its steps, each eight
/// tracks' pattern and transposition (`tracks`) or a command (`command`); its patterns; its macros.
/// "(Empty)" as its first line is a module UADE plays with the player of TFMX 1.x.
private func song(_ steps: [[UInt8]], patterns: [[UInt8]], macros: [[UInt8]], header: [UInt8] = Array("TFMX-SONG ".utf8),
                  text: String = "(Empty)         ", speed: UInt16 = 5) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x800)
    put(&bytes, 0, header)
    put(&bytes, 16, Array(text.utf8))
    put(&bytes, 0x140, [0, UInt8(steps.count - 1)])
    put(&bytes, 0x180, [UInt8(speed >> 8), UInt8(speed & 0xFF)])
    for step in steps { bytes += step + [UInt8](repeating: 0, count: 16 - step.count) }
    for (i, pattern) in patterns.enumerated() {
        put(&bytes, 0x400 + 4 * i, long(bytes.count))
        bytes += pattern
    }
    for (i, macro) in macros.enumerated() {
        put(&bytes, 0x600 + 4 * i, long(bytes.count))
        bytes += macro
    }
    return bytes
}

/// A step's eight tracks: those given, and the rest idle.
private func tracks(_ given: [(UInt8, UInt8)]) -> [UInt8] {
    (0 ..< 8).flatMap { $0 < given.count ? [given[$0].0, given[$0].1] : [0xFF, 0] }
}

private func command(_ number: UInt8, _ first: UInt16 = 0, _ second: UInt16 = 0) -> [UInt8] {
    [0xEF, 0xFE, 0, number, UInt8(first >> 8), UInt8(first & 0xFF), UInt8(second >> 8), UInt8(second & 0xFF)]
}

/// A pattern's row, or a macro's command.
private func row(_ a: UInt8, _ b: UInt8 = 0, _ c: UInt8 = 0, _ d: UInt8 = 0) -> [UInt8] { [a, b, c, d] }

/// A pattern of one note, of macro 0 on voice 0, and then a long wait.
private let oneNote = row(0x1E, 0, 0xF0) + row(0xF3, 30) + row(0xF0)

/// What the voices are given, tick by tick: each one's period and volume after each tick, and what
/// Paula was told. `loops` may set how far the voices have gone round, before a tick.
private func heard(_ file: [UInt8], original: Bool, ticks: Int, loops: (Int, inout Recorder) -> Void = { _, _ in })
    throws -> (periods: [[UInt16]], volumes: [[UInt16]], events: [String], format: TFMXFormat) {
    var player = try TFMXPlayer(file, samples: samples, followsOriginalPlayers: original)
    var recorder = Recorder()
    var periods: [[UInt16]] = [], volumes: [[UInt16]] = []
    for tick in 0 ..< ticks {
        loops(tick, &recorder)
        _ = player.run(&recorder)
        periods.append((0 ..< player.voiceCount).map { player.period($0) })
        volumes.append((0 ..< player.voiceCount).map { player.volume($0) })
    }
    return (periods, volumes, recorder.events, player.format)
}

@Test func tfmxPlayerIsChosenAsUADEChoosesIt() throws {
    let steps = [tracks([(0, 0)])], patterns = [oneNote], macros = [row(0x07)]
    func format(_ file: [UInt8], original: Bool) throws -> TFMXFormat {
        try TFMXPlayer(file, samples: samples, followsOriginalPlayers: original).format
    }
    // "(Empty)" as its first line: TFMX 1.x, which the library tells only by the header of TFMX before
    // its first release, or by a checksum.
    let first = song(steps, patterns: patterns, macros: macros)
    #expect(try format(first, original: true) == .tfmx && format(first, original: false) == .pro)
    // But not Z-Out's title, by its word at 14.
    var zOut = first
    put(&zOut, 14, [0x0E, 0x60])
    #expect(try format(zOut, original: true) == .pro)
    // Another first line: TFMX Pro; with 7VOICE in its song, TFMX 7V.
    let pro = song(steps, patterns: patterns, macros: macros, text: "Date : 23.01.91 ")
    #expect(try format(pro, original: true) == .pro)
    let seven = song([command(3, 0xFF00)] + steps, patterns: patterns, macros: macros, text: "Date : 23.01.91 ")
    #expect(try format(seven, original: true) == .sevenVoices)
    // A TFHD file says.
    let tfhd = Array("TFHD".utf8) + long(0x12) + [1, 0] + long(pro.count) + long(samples.count) + pro + samples
    #expect(try format(tfhd, original: true) == .tfmx)
}

@Test func tfmxOldPlayerStartsAMacroATickAfterItsNoteAndKeepsItsDetune() throws {
    // A note with a detune of 4, of a macro that sets note $1F (period $11E).
    let file = song([tracks([(0, 0)])], patterns: [row(0x1E, 0, 0xF0, 4) + row(0xF3, 30) + row(0xF0)],
                    macros: [row(0x09, 0x1F) + row(0x07)], header: oldHeader)
    let original = try heard(file, original: true, ticks: 3), library = try heard(file, original: false, ticks: 3)
    #expect(original.format == .tfmx && library.format == .tfmx)
    // TFMX 1.x, $1142: on the tick after the note's; and SetNote adds the voice's detune, $13e0.
    #expect(original.periods.map { $0[0] } == [0, 0x122, 0x122])
    #expect(library.periods.map { $0[0] } == [0x11E, 0x11E, 0x11E])
}

@Test func tfmxOldPlayerGlidesOnFromWhereItWas() throws {
    // SetNote $1F, a portamento of 3 a tick, a wait, and SetNote 0 (Einmal Kanzler sein's ingame_05).
    let macro = row(0x09, 0x1F) + row(0x0B, 1, 0, 3) + row(0x04, 0, 0, 1) + row(0x09, 0) + row(0x07)
    let file = song([tracks([(0, 0)])], patterns: [oneNote], macros: [macro], header: oldHeader)
    let original = try heard(file, original: true, ticks: 8), library = try heard(file, original: false, ticks: 5)
    // TFMX 1.x, $1680: the portamento, at its note's period, waits there, and glides on to the next.
    #expect(original.periods.map { $0[0] } == [0, 0x11E, 0x11E, 0x11E, 0x11E, 0x121, 0x124, 0x127])
    #expect(library.periods.map { $0[0] } == [0x11E, 0x11E, 0x11E, 0x6AE, 0x6AE])
}

@Test func tfmxOldPlayerKeepsAnOddVibratoTime() throws {
    // SetNote $1F and a vibrato of time 3, by 2.
    let file = song([tracks([(0, 0)])], patterns: [oneNote], macros: [row(0x09, 0x1F) + row(0x0C, 3, 0, 2) + row(0x07)],
                    header: oldHeader)
    let original = try heard(file, original: true, ticks: 10), library = try heard(file, original: false, ticks: 9)
    // TFMX 1.x, $1454: turned round every three ticks; the library's every two.
    #expect(original.periods[3...].map { $0[0] } == [0x120, 0x11E, 0x11C, 0x11A, 0x11C, 0x11E, 0x120])
    #expect(library.periods[2...].map { $0[0] } == [0x120, 0x11E, 0x11C, 0x11E, 0x120, 0x11E, 0x11C])
}

@Test func tfmxOldPlayerHasMacrosOfItsOwn() throws {
    // SplitKey, $1C: to step 3, as the note is above $10.
    let split = song([tracks([(0, 0)])], patterns: [oneNote],
                     macros: [row(0x1C, 0x10, 0, 3) + row(0x09, 0x01) + row(0x07) + row(0x09, 0x02) + row(0x07)], header: oldHeader)
    let original = try heard(split, original: true, ticks: 2), library = try heard(split, original: false, ticks: 1)
    #expect(original.periods[1][0] == 0x05F4 && library.periods[0][0] == 0x064E)
    // A command beyond its table, $47, is not Stop ($07): on to the next after the tick.
    let beyond = song([tracks([(0, 0)])], patterns: [oneNote], macros: [row(0x47) + row(0x09, 0x01) + row(0x07)], header: oldHeader)
    let later = try heard(beyond, original: true, ticks: 3), stopped = try heard(beyond, original: false, ticks: 3)
    #expect(later.periods.map { $0[0] } == [0, 0, 0x064E] && stopped.periods.map { $0[0] } == [0, 0, 0])
}

@Test func tfmxOldPlayerLoopsTheSongAsItsTrackTableSays() throws {
    // A loop of step 0, twice, and then Stop: TFMX 1.x, $fd4, goes back to step 0 always.
    let looped = song([tracks([(0, 0)]), command(1, 0, 2), command(0)], patterns: [row(0x1E, 0, 0xF0) + row(0xF3, 1) + row(0xF0)],
                      macros: [row(0x09, 0x1F) + row(0x07)], header: oldHeader)
    for original in [true, false] {
        var player = try TFMXPlayer(looped, samples: samples, followsOriginalPlayers: original)
        player.loops = true
        var recorder = Recorder()
        for _ in 0 ..< 200 { _ = player.run(&recorder) }
        let (stops, endings) = (player.stops, player.endings)
        #expect(original ? stops == 0 && endings > 0 : stops > 0)
    }
    // $FA01 is a Loop too ($e5e), to step 2, which plays a note of its own.
    let older = song([tracks([(0, 0)]), [0xFA, 0x01, 0x00, 0x02] + Array(tracks([]).prefix(12)), tracks([(1, 0)])],
                     patterns: [row(0x1E, 0, 0xF0) + row(0xF3, 1) + row(0xF0), row(0x10, 1, 0xF0) + row(0xF3, 30) + row(0xF0)],
                     macros: [row(0x08) + row(0x07), row(0x08) + row(0x07)], header: oldHeader)
    let original = try heard(older, original: true, ticks: 20), library = try heard(older, original: false, ticks: 20)
    #expect(original.periods[19][0] == 0x02A8 && library.periods[19][0] == 0x010E)
}

@Test func tfmxOldPlayerHasPatternCommandsOfItsOwn() throws {
    // An envelope from the pattern, down by 4: TFMX 1.x, $1738, steps it every other tick, and the
    // library every (c + 1)th.
    let envelope = song([tracks([(0, 0)])], patterns: [row(0x1E, 0, 0xF0) + row(0xF7, 4, 0x30, 0) + row(0xF3, 30) + row(0xF0)],
                        macros: [row(0x0E, 0, 0, 0x40) + row(0x09, 0x1F) + row(0x07)], header: oldHeader)
    let original = try heard(envelope, original: true, ticks: 7), library = try heard(envelope, original: false, ticks: 6)
    let (fast, slow) = (original.volumes[2...].map { $0[0] }, library.volumes[1...].map { $0[0] })
    #expect(fast == [60, 60, 56, 56, 52])
    #expect(slow == [64, 64, 64, 60, 60])
    // $FC ends the track's row ($c46), so the next note is a row later.
    let row2 = song([tracks([(0, 0)])], patterns: [row(0x1E, 0, 0xF0) + row(0xFC) + row(0x1E, 1, 0xF0) + row(0xF3, 30) + row(0xF0)],
                    macros: [row(0x09, 0x01) + row(0x07), row(0x09, 0x02) + row(0x07)], header: oldHeader)
    let later = try heard(row2, original: true, ticks: 8), atOnce = try heard(row2, original: false, ticks: 1)
    #expect(later.periods[1][0] == 0x064E && later.periods[7][0] == 0x05F4 && atOnce.periods[0][0] == 0x05F4)
    // $FB has another track play a pattern ($dc2; TFMX Pro too, $149c).
    let other = song([tracks([(0, 0)])], patterns: [row(0xFB, 1, 1, 0) + row(0xF3, 30) + row(0xF0), row(0x1E, 0, 0xF1) + row(0xF4)],
                     macros: [row(0x09, 0x1F) + row(0x07)], header: oldHeader)
    let played = try heard(other, original: true, ticks: 3), notPlayed = try heard(other, original: false, ticks: 3)
    #expect(played.periods[2][1] == 0x11E && notPlayed.periods[2][1] == 0)
    // A transposition that takes a note to $BF or past is a portamento ($c20, $178e): no macro.
    let transposed = song([tracks([(0, 0x40)])], patterns: [row(0x90, 0, 0xF0, 3) + row(0xF3, 30) + row(0xF0)],
                          macros: [row(0x08) + row(0x07)], header: oldHeader)
    let glide = try heard(transposed, original: true, ticks: 5), note = try heard(transposed, original: false, ticks: 5)
    #expect(glide.periods[4][0] == 0 && note.periods[4][0] == 0x02A8)
}

@Test func tfmxProPlayerTakesDMAonsByteAsTheEffectsFlag() throws {
    // SetNote $1F, a vibrato of time 8 by 64, a wait, DMAon with nought: TFMX Pro, $1908, has the
    // effects left out for the rest of that tick ($1fd0).
    let macro = row(0x09, 0x1F) + row(0x0C, 8, 0, 0x40) + row(0x04, 0, 0, 2) + row(0x01) + row(0x04, 0, 0, 5) + row(0x07)
    let file = song([tracks([(0, 0)])], patterns: [oneNote], macros: [macro], text: "test            ")
    let original = try heard(file, original: true, ticks: 7), library = try heard(file, original: false, ticks: 7)
    #expect(original.periods[1...].map { $0[0] } == [286, 294, 303, 312, 312, 321])
    #expect(library.periods[1...].map { $0[0] } == [286, 294, 303, 312, 321, 312])
}

@Test func tfmxProPlayerLocksAVoice() throws {
    // $FC locks voice 0 for 5 ticks (TFMX Pro, $2462): the note after it is left alone, and one three
    // rows later is played.
    let file = song([tracks([(0, 0)])],
                    patterns: [row(0xFC, 1, 0, 5) + row(0x1E, 0, 0xF0) + row(0xF3, 2) + row(0x1E, 0, 0xF0) + row(0xF3, 30) + row(0xF0)],
                    macros: [row(0x09, 0x1F) + row(0x07)], text: "test            ")
    let original = try heard(file, original: true, ticks: 20), library = try heard(file, original: false, ticks: 2)
    #expect(original.periods[1][0] == 0 && original.periods[18][0] == 0 && original.periods[19][0] == 0x11E)
    #expect(library.periods[1][0] == 0x11E)
}

@Test func tfmxPlayersStartASongOfBeatsAMinuteAtSpeedFive() throws {
    // Two notes a row apart, at 125 beats a minute: the library's speed is nought, a row a tick.
    let patterns = [row(0x1E, 0, 0xF0) + row(0xF3, 0) + row(0x1E, 1, 0xF0) + row(0xF3, 30) + row(0xF0)]
    let macros = [row(0x09, 0x1F) + row(0x07), row(0x09, 0x01) + row(0x07)]
    let pro = song([tracks([(0, 0)])], patterns: patterns, macros: macros, text: "test            ", speed: 125)
    let original = try heard(pro, original: true, ticks: 8), library = try heard(pro, original: false, ticks: 3)
    #expect(original.periods[6][0] == 0x11E && original.periods[7][0] == 0x064E && library.periods[2][0] == 0x064E)
    // TFMX 1.x, from $20, at $18f0.
    let old = song([tracks([(0, 0)])], patterns: patterns, macros: macros, header: oldHeader, speed: 125)
    let first = try heard(old, original: true, ticks: 8)
    #expect(first.periods[6][0] == 0x11E && first.periods[7][0] == 0x064E)
}

@Test func tfmxOldPlayerSetsTheTimersUpperByteOnASpeedMidSong() throws {
    // A row, Speed with 100 beats a minute, a row, Speed with none ($FF00, as the modules have it), a row, Stop.
    let short = row(0x1E, 0, 0xF0) + row(0xF3, 1) + row(0xF0)
    let steps = [tracks([(0, 0)]), command(2, 5, 100), tracks([(0, 0)]), command(2, 5, 0xFF00), tracks([(0, 0)]), command(0)]
    /// The timers the song sets, as they change, and a tick of each.
    func timers(_ file: [UInt8], original: Bool) throws -> (timers: [UInt16?], ticks: [Int]) {
        var player = try TFMXPlayer(file, samples: samples, followsOriginalPlayers: original)
        var recorder = Recorder(), timing = TFMXTiming()
        var timers = [player.ciaTimer], ticks = [player.fourVoiceTick(&timing)]
        for _ in 0 ..< 100 {
            _ = player.run(&recorder)
            if player.songEnded { break }
            if timers.last != player.ciaTimer {
                timers.append(player.ciaTimer)
                ticks.append(player.fourVoiceTick(&timing))
            }
        }
        return (timers, ticks)
    }
    let macros = [row(0x09, 0x1F) + row(0x07)]
    // A song started at the frame: TFMX 1.x, $fe0 to $1024, puts $1C00 / 100 in the timer's upper byte,
    // the lower still $F0 from TIMERINIT's $37F0, and is run by the frame again without a tempo.
    let atFrame = song(steps, patterns: [short], macros: macros, header: oldHeader)
    let original = try timers(atFrame, original: true)
    #expect(original.timers == [nil, 0x47F0, nil] && original.ticks == [TFMXTiming.frame, 0x47F1 * 5, TFMXTiming.frame])
    // The library's way keeps the timer.
    #expect(try timers(atFrame, original: false).timers == [nil, 0x47F0])
    // Started at 125 beats a minute, the lower byte is the nought the start put there, and the timer stays.
    let atTempo = song(steps, patterns: [short], macros: macros, header: oldHeader, speed: 125)
    #expect(try timers(atTempo, original: true).timers == [57 << 8, 0x4700])
}

@Test func tfmxProPlayerKeepsMacroNotesInItsTable() throws {
    // AddNote -1 to note 0: TFMX Pro, $1c9e, keeps it below 64, which is note 63.
    let file = song([tracks([(0, 0)])], patterns: [row(0x00, 0, 0xF0) + row(0xF3, 30) + row(0xF0)], macros: [row(0x08, 0xFF) + row(0x07)],
                    text: "test            ")
    let original = try heard(file, original: true, ticks: 2), library = try heard(file, original: false, ticks: 2)
    #expect(original.periods[1][0] == 0x00B4 && library.periods[1][0] == 0x0718)
}

@Test func tfmxProPlayerWaitsForPaulaAsUADERunsIt() throws {
    // SetBegin, SetLen, DMAon, SetBegin and SetLen again: the voice is started at once ($192a), and the
    // second pair is where it goes on from.
    let starts = song([tracks([(0, 0)])], patterns: [oneNote],
                      macros: [row(0x02) + row(0x03, 0, 0, 16) + row(0x01, 1) + row(0x02, 0, 0, 4) + row(0x03, 0, 0, 8) + row(0x07)],
                      text: "test            ")
    let original = try heard(starts, original: true, ticks: 3), library = try heard(starts, original: false, ticks: 3)
    #expect(original.events.firstIndex(of: "on 0") == 2 && library.events.firstIndex(of: "on 0") == 4)
    // DMAoff, asked to wait, stops the voice at once, sets the volume and goes on ($1890): the note
    // set after it is heard on the same tick.
    let stops = song([tracks([(0, 0)])], patterns: [row(0x1E, 0, 0x30) + row(0xF3, 30) + row(0xF0)],
                     macros: [row(0x0E, 0, 0, 0x30) + row(0x01, 1) + row(0x04, 0, 0, 1) + row(0x13, 1, 0, 0x20) + row(0x09, 0x1F) + row(0x07)],
                     text: "test            ")
    let stopped = try heard(stops, original: true, ticks: 4), delayed = try heard(stops, original: false, ticks: 4)
    #expect(stopped.periods[3][0] == 0x11E && stopped.volumes[3][0] == 41 && delayed.periods[3][0] == 0)
    // A volume beyond 127 is seven bits of it in Paula's register ($f9a).
    let loud = song([tracks([(0, 0)])], patterns: [oneNote], macros: [row(0x0E, 0, 0, 0xC0) + row(0x07)], text: "test            ")
    let kept = try heard(loud, original: true, ticks: 2), signed = try heard(loud, original: false, ticks: 2)
    #expect(kept.volumes[1][0] == 0x40 && signed.volumes[1][0] == 0xFFC0)
}

@Test func tfmxWaitOnDMACountsPaulasInterrupts() throws {
    // DMAon, WaitOnDMA for one more, SetVolume: TFMX Pro's handler, $1ab4, counts the interrupt the
    // start asked for, and then one a time round; the library counts the times round, one more.
    let file = song([tracks([(0, 0)])], patterns: [oneNote],
                    macros: [row(0x02) + row(0x03, 0, 0, 16) + row(0x01, 1) + row(0x1A, 0, 0, 1) + row(0x0E, 0, 0, 0x20) + row(0x07)],
                    text: "test            ")
    func roundAt5And8(_ tick: Int, _ recorder: inout Recorder) { recorder.loops[0] = tick >= 8 ? 2 : tick >= 5 ? 1 : 0 }
    let original = try heard(file, original: true, ticks: 9, loops: roundAt5And8)
    let library = try heard(file, original: false, ticks: 9, loops: roundAt5And8)
    #expect(original.volumes[4][0] == 0 && original.volumes[5][0] == 32)
    #expect(library.volumes[7][0] == 0 && library.volumes[8][0] == 32)
}

@Test func tfmxProPlayerMendsAModuleAsWantedTeamsPlayerDoes() throws {
    // A module known by its word at 14 and its song 9 beginning at step $26 with no end: TFMX Pro,
    // $c2a, makes that the song's end, and so the song is one there is.
    var file = song([tracks([(0, 0)])] + [[UInt8]](repeating: tracks([]), count: 0x25) + [tracks([(0, 0)])], patterns: [oneNote],
                    macros: [row(0x07)], text: "test            ")
    put(&file, 0x0E, [0x0A, 0x40])
    put(&file, 0x140, [0, 0])
    put(&file, 0x112, [0, 0x26])
    let mended = try TFMXPlayer(file, samples: samples, followsOriginalPlayers: true), asItIs = try TFMXPlayer(file, samples: samples)
    #expect(mended.songCount == 2 && asItIs.songCount == 1)
}

@Test func tfmxSevenVoicePlayerStartsAMixedVoiceAtOnce() throws {
    // A note on channel 4, which is mixed onto Paula's fourth: its DMAon starts it at once, and its
    // macro goes no further that tick ($1682).
    let file = song([command(3, 0xFF00), tracks([(0, 0)])], patterns: [row(0x1E, 0, 0xF4) + row(0xF3, 30) + row(0xF0)],
                    macros: [row(0x02) + row(0x03, 0, 0, 16) + row(0x01, 1) + row(0x0E, 0, 0, 0x20) + row(0x07)], text: "test            ")
    let original = try heard(file, original: true, ticks: 3), library = try heard(file, original: false, ticks: 3)
    #expect(original.format == .sevenVoices && library.format == .sevenVoices)
    #expect(original.volumes[1][3] == 0 && original.volumes[2][3] == 32 && library.volumes[1][3] == 32)
}

@Test func tfmxWithoutItsSamplesIsToldAsWantingThem() throws {
    // So that a player that could not look beside it can ask for the folder they are in.
    let keeper = SongKeeper()
    keeper.load(tune: 1, serial: 1, name: "test.mdat", bytes: module(), companions: [nil], subsong: -1, now: 0)
    guard case .loaded(_, let plays, _, let wantsCompanion, _, _, _, _, _, _) = try #require(keeper.events.first) else { return }
    #expect(!plays && wantsCompanion)
    let given = SongKeeper()
    given.load(tune: 1, serial: 1, name: "test.mdat", bytes: module(), companions: [samples], subsong: -1, now: 0)
    guard case .loaded(_, let plays2, _, let wantsCompanion2, _, _, _, _, _, _) = try #require(given.events.first) else { return }
    #expect(plays2 && !wantsCompanion2)
    // A file of nothing it can play is not.
    let refused = SongKeeper()
    refused.load(tune: 1, serial: 1, name: "test.mdat", bytes: [0, 1, 2], companions: [nil], subsong: -1, now: 0)
    guard case .loaded(_, let plays3, _, let wantsCompanion3, _, _, _, _, _, _) = try #require(refused.events.first) else { return }
    #expect(!plays3 && !wantsCompanion3)
}
