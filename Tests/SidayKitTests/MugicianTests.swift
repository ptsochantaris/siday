// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the players of Digital Mugician's modules, on tiny modules made here. The thorough
// check is made outside the package: what they tell Paula, tick by tick, and what Mugician II mixes,
// against UADE's running of the original players, for every module of UnExoticA's collection.

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

/// Where the parts of `mugician()`'s module are.
private struct Layout {
    var waveforms = 0
    var samples = 0
    var instruments = 0
}

/// A Digital Mugician module of eight songs of one position each: song 0's first voice plays pattern 0,
/// whose first row is note 24 of instrument 1 (`instrument`'s sixteen bytes), and its other voices the
/// empty pattern 1; song 1 likewise, and the rest are empty. Waveform 0 is a ramp, 1 is all $80 (the
/// loudest, as an envelope), 2 another ramp; the one sample is 200 bytes, looping from 100.
private func mugician(two: Bool = false, speed: UInt8 = 6, instrument: [UInt8]? = nil, row: [UInt8] = [24, 1, 0, 0]) -> ([UInt8], Layout) {
    var bytes = Array((two ? " MUGICIAN2/SOFTEYES 1990" : " MUGICIAN/SOFTEYES 1990 ").utf8) + [0, 1]
    bytes += word(2)
    for _ in 0 ..< 8 { bytes += long(1) }
    bytes += long(1) + long(3) + long(1) + long(200)
    for s in 0 ..< 8 {
        bytes += [1, 0, speed, 1] + Array((s == 0 ? "first song  " : "song        ").utf8)
    }
    // Positions: songs 0 and 1 have their first voice on pattern 0, the rest on 1.
    for s in 0 ..< 8 { bytes += s < 2 ? [0, 0, 1, 0, 1, 0, 1, 0] : [UInt8](repeating: 0, count: 8) }
    let instruments = bytes.count
    // A synth on waveform 0, 16 words, its envelope waveform 1 a step a tick, fine tune 0.
    bytes += instrument ?? [0, 16, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    let waveforms = bytes.count
    bytes += (0 ..< 128).map { UInt8(truncatingIfNeeded: $0 * 2) }
    bytes += [UInt8](repeating: 0x80, count: 128)
    bytes += (0 ..< 128).map { UInt8(truncatingIfNeeded: 255 - $0) }
    bytes += long(0) + long(200) + long(100) + [UInt8](repeating: 0, count: 20)
    var patterns = [UInt8](repeating: 0, count: 512)
    patterns.replaceSubrange(0 ..< 4, with: row)
    bytes += patterns
    let samples = bytes.count
    bytes += (0 ..< 200).map { UInt8(truncatingIfNeeded: 3 + $0) }
    bytes += [UInt8](repeating: 0, count: 256)
    return (bytes, Layout(waveforms: waveforms, samples: samples, instruments: instruments))
}

private func period(_ note: Int, fineTune: Int = 0) -> UInt16 { MugicianTables.periods[7 + fineTune * 64 + note] }

@Test func mugicianModulesAreKnown() throws {
    #expect(MugicianPlayer.kind(of: mugician().0) == .one)
    #expect(MugicianPlayer.kind(of: mugician(two: true).0) == .two)
    var other = mugician().0
    other[25] = 2
    #expect(!MugicianPlayer.isOne(other))
    #expect(!MugicianPlayer.isOne(Array(mugician().0.prefix(20))))
    // A module shorter than its parts say is refused, as EaglePlayer's modules refuse it.
    #expect(throws: TuneError.self) { _ = try MugicianPlayer(Array(mugician().0.dropLast(1))) }
    #expect(throws: TuneError.self) { _ = try MugicianPlayer(other) }
}

@Test func mugicianSongsAreCountedAsEaglePlayerCountsThem() throws {
    // Of the first player's eight, those of one position of noughts are not songs.
    let player = try MugicianPlayer(mugician().0)
    #expect(player.songCount == 2)
    #expect(player.tuneInfo.title == "first song")
    // Mugician II's are two of the module's each, less those at the end that are noughts.
    let two = try MugicianPlayer(mugician(two: true).0)
    #expect(two.songCount == 1)
    #expect(two.tuneInfo.detail == "Digital Mugician II")
}

@Test func mugicianFirstTickTellsPaula() throws {
    let (module, layout) = mugician()
    var player = try MugicianPlayer(module)
    var out = Recorder()
    player.run(&out)
    #expect(out.events == ["buffer 0 \(layout.waveforms) 16", "off 0", "on 0", "on 1", "on 2", "on 3"])
    #expect(player.period(0) == period(24))
    // The envelope's second byte, $80, the loudest.
    #expect(player.volume(0) == 63)
    #expect(player.tickClocks == 70940)
}

@Test func mugicianEffectsRewriteTheWaveform() throws {
    // Effect 3, a shift round to the left, every tick, from waveform 2.
    let (module, layout) = mugician(instrument: [0, 16, 1, 1, 0, 0, 0, 0, 0, 0, 0, 3, 2, 0, 0, 0])
    var player = try MugicianPlayer(module)
    for _ in 0 ..< 3 {
        var out = Recorder()
        player.run(&out)
    }
    // Waveform 0 was made afresh from waveform 2 as the note began, and shifted three times.
    let wave = Array(UnsafeBufferPointer(start: player.memory + layout.waveforms, count: 128))
    let source = (0 ..< 128).map { UInt8(255 - $0) }
    #expect(wave == Array(source[3...] + source[..<3]))
    // Effect 1, smoothing: each byte and the one after, halved.
    let (smooth, smoothLayout) = mugician(instrument: [0, 16, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0])
    var smoothing = try MugicianPlayer(smooth)
    var out = Recorder()
    smoothing.run(&out)
    #expect(smoothing.memory[smoothLayout.waveforms] == 1)
}

@Test func mugicianSamplesPlayThenLoop() throws {
    let (module, layout) = mugician(instrument: [0x20, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    var player = try MugicianPlayer(module)
    var first = Recorder(), second = Recorder()
    player.run(&first)
    #expect(first.events.contains("buffer 0 \(layout.samples) 100"))
    player.run(&second)
    #expect(second.events.contains("buffer 0 \(layout.samples + 100) 50"))
}

@Test func mugicianSlidesToItsNote() throws {
    // A row whose third byte, below $40, is a note to slide to, by its fourth byte a tick.
    let (module, _) = mugician(row: [24, 1, 30, 40])
    var player = try MugicianPlayer(module)
    var periods: [UInt16] = []
    for _ in 0 ..< 30 {
        var out = Recorder()
        player.run(&out)
        periods.append(player.period(0))
    }
    #expect(periods[0] == period(24) - 40)
    #expect(periods[1] == period(24) - 80)
    #expect(periods.last == period(30))
}

@Test func mugicianSongLength() throws {
    // Six ticks a row, 64 rows; the song comes round as its position is played again.
    let player = try MugicianPlayer(mugician().0)
    #expect(player.lengthClocks == UInt64(64 * 6 * 70940))
    var counting = try MugicianPlayer(mugician().0)
    var out = Recorder()
    for _ in 0 ..< 64 * 6 { counting.run(&out) }
    #expect(counting.endings == 0)
    counting.run(&out)
    #expect(counting.endings == 1)
}

@Test func mugicianTwoMixesItsFourVoices() throws {
    // The second song of the pair plays the sample on its first voice, mixed onto Paula's first.
    let (module, layout) = mugician(two: true, instrument: [0x20, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    var player = try MugicianPlayer(module)
    #expect(player.tickClocks == 220 * 2 * 163)
    var first = Recorder(), second = Recorder()
    player.run(&first)
    // Paula's first voice begins with silence, then the buffer mixed; her fourth plays the first voice.
    #expect(first.events.first == "buffer 0 \(player.buffersAt + MugicianPlayer.bufferBytes) 99")
    #expect(first.events.contains("buffer 0 \(player.buffersAt) 220"))
    #expect(first.events.contains("buffer 3 \(layout.samples) 100"))
    #expect(first.events.suffix(3) == ["on 3", "on 1", "on 2"])
    // At the loudest, the sample as it is.
    #expect(player.memory[player.buffersAt] == 3)
    #expect(player.mixed[0].silent == false)
    player.run(&second)
    #expect(second.events.contains("buffer 0 \(player.buffersAt + MugicianPlayer.bufferBytes) 220"))
    // The step for a period: 163 / 428 of a byte for each, in 256ths.
    #expect(MugicianPlayer.step(period: 428, mixing: 163) == 97 << 24)
}

@Test func mugicianOddModulesNeitherHangNorTrap() throws {
    // Effects of every kind on a waveform of nought words (which the players take as 65,536 bytes),
    // notes and fine tunes past the table, an arpeggio and vibrato from far waveforms.
    for effect in 0 ..< 33 {
        let (module, _) = mugician(speed: 1, instrument: [0, 0, 1, 1, 7, 2, 0, 0, 0xFF, 0xF0, 0, UInt8(effect), 1, 2, 0, 2], row: [200, 1, 0x4A, 0xFF])
        var player = try MugicianPlayer(module)
        var out = Recorder()
        for _ in 0 ..< 30 { player.run(&out) }
    }
    let (module, _) = mugician(two: true, instrument: [0x7F, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    var two = try MugicianPlayer(module)
    var out = Recorder()
    for _ in 0 ..< 200 { two.run(&out) }
    for cut in stride(from: 0, to: module.count, by: 11) {
        _ = try? MugicianPlayer(Array(module.prefix(cut)))
    }
}

@Test func mugicianPlaysThroughTheRenderer() throws {
    for two in [false, true] {
        let renderer = try PaulaTickRenderer(try MugicianPlayer(mugician(two: two).0), options: LoadOptions())
        #expect(renderer.info.format == "MUG")
        let frames = 4800
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { buffer.deallocate() }
        renderer.render(into: buffer, frames: frames)
        var loudest: Float = 0
        for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
        #expect(loudest > 0.01)
        #expect(renderer.songs.first?.length != nil)
    }
}
