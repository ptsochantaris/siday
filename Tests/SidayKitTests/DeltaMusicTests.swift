// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of Delta Music 2.0's modules, on tiny modules made here (without the
// replayer's code, which every real module carries and which they are checked for: here the tables
// the player reads from that part are written in by hand). The thorough check is made outside the
// package: what it tells Paula, tick by tick, against UADE's running of the original replayer, for
// every module of UnExoticA's collection.

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

/// The periods the tiny modules' notes have: note n's is 1000 - n.
private func notePeriod(_ n: Int) -> UInt16 { UInt16(1000 - n) }

/// Where the parts of `deltaMusic()`'s module are.
private struct Layout {
    var waveforms = 0
    var samples = 0
    var instruments = 0
}

/// A Delta Music 2.0 module: voice 0's track plays one block, whose first row is note 24 of instrument
/// 1 with `command`; the others are silent. Instrument 1 is a synth on waveform 1, or with `sample`, the
/// module's first sample, 100 words long; its envelope rises by `rise` a tick to 252 and holds there.
private func deltaMusic(command: [UInt8] = [0, 0], sample: Bool = false, rise: UInt8 = 64, blocks: Int = 1) -> ([UInt8], Layout) {
    var bytes = [UInt8](repeating: 0, count: DeltaMusicPlayer.songAt)
    // What the replayer's part has that the player reads: its periods, its word for Paula's DMA, its
    // speed (5) and the variables' file values; and ".FNL".
    for n in 0 ..< 85 { bytes.replaceSubrange(0xAE2 + n * 2 ..< 0xAE4 + n * 2, with: word(Int(notePeriod(n)))) }
    bytes.replaceSubrange(0xB8C ..< 0xB8E, with: word(0x8000))
    bytes[0xBBA] = 0x3F
    bytes[0xBBB] = 5
    bytes.replaceSubrange(0xBC6 ..< 0xBCA, with: Array(".FNL".utf8))
    // The header: each track from nought, of `blocks` entries.
    for _ in 0 ..< 4 { bytes += word(0) + word(blocks * 2) }
    for v in 0 ..< 4 {
        for _ in 0 ..< blocks { bytes += v == 0 ? [0, 0] : [1, 0] }
    }
    // Two blocks: the first with its note, the second empty.
    bytes += long(128)
    var block = [UInt8](repeating: 0, count: 128)
    block[0] = 24
    block[1] = 1
    block[2] = command[0]
    block[3] = command[1]
    bytes += block
    // The table of instruments, and one instrument.
    bytes += word(0) + [UInt8](repeating: 0, count: 0xFC)
    var instrument = [UInt8](repeating: 0, count: 104)
    instrument.replaceSubrange(0 ..< 2, with: word(sample ? 100 : 16))
    instrument.replaceSubrange(4 ..< 6, with: word(1))
    instrument[6] = rise
    instrument[7] = 252
    instrument[8] = 0
    for step in 1 ..< 5 { instrument[6 + step * 3] = 0; instrument[7 + step * 3] = 252 }
    instrument[22] = 1
    instrument[38] = sample ? 0x80 : 0
    instrument[39] = 0
    instrument[40] = 1
    instrument[41] = 0xFF
    instrument[42] = 0
    bytes += word(104)
    let instruments = bytes.count
    bytes += instrument
    // Two waveforms, the second a ramp.
    bytes += long(512)
    let waveforms = bytes.count
    bytes += [UInt8](repeating: 0, count: 256) + (0 ..< 256).map { UInt8(truncatingIfNeeded: $0 * 3) }
    bytes += [UInt8](repeating: 0, count: 0x40) + long(0) + [UInt8](repeating: 0, count: 28)
    let samples = bytes.count
    bytes += (0 ..< 200).map { UInt8(truncatingIfNeeded: 7 + $0 * 5) }
    return (bytes, Layout(waveforms: waveforms, samples: samples, instruments: instruments))
}

@Test func deltaMusicModulesAreKnown() throws {
    let (module, _) = deltaMusic()
    #expect(DeltaMusicPlayer.isOne(module))
    #expect(!DeltaMusicPlayer.isOne(Array(module.prefix(0xBC8))))
    var other = module
    other[0xBC9] = 0x4D
    #expect(!DeltaMusicPlayer.isOne(other))
    // Without the replayer's code, a module is refused as one whose replayer is not known.
    #expect(throws: TuneError.self) { _ = try DeltaMusicPlayer(module) }
    #expect(throws: TuneError.self) { _ = try DeltaMusicPlayer(Array(module.prefix(0xFD0)), checksReplayer: false) }
    _ = try DeltaMusicPlayer(module, checksReplayer: false)
}

@Test func deltaMusicFirstTickTellsPaula() throws {
    let (module, layout) = deltaMusic()
    var player = try DeltaMusicPlayer(module, checksReplayer: false)
    var out = Recorder()
    player.run(&out)
    // Voice 0's note turns its DMA off, its synth's first waveform is told, and every voice is turned on.
    #expect(out.events.first == "off 0")
    #expect(out.events.contains("buffer 0 \(layout.waveforms + 256) 16"))
    #expect(Array(out.events.suffix(4)) == ["on 0", "on 1", "on 2", "on 3"])
    #expect(player.period(0) == notePeriod(24))
    // The envelope has risen by 64 in quarters: a volume of 16.
    #expect(player.volume(0) == 16)
    // The noise, over the first waveform, from a seed of nought.
    #expect(Array(UnsafeBufferPointer(start: player.memory + layout.waveforms, count: 4)) == [0xF0, 0x93, 0xDC, 0x46])
}

@Test func deltaMusicEnvelopeRisesAndHolds() throws {
    let (module, _) = deltaMusic(rise: 40)
    var player = try DeltaMusicPlayer(module, checksReplayer: false)
    var volumes: [UInt16] = []
    for _ in 0 ..< 10 {
        var out = Recorder()
        player.run(&out)
        volumes.append(player.volume(0))
    }
    #expect(volumes == [10, 20, 30, 40, 50, 60, 63, 63, 63, 63])
}

@Test func deltaMusicSamplesLoopTheirFirstWordMadeNought() throws {
    let (module, layout) = deltaMusic(sample: true)
    var player = try DeltaMusicPlayer(module, checksReplayer: false)
    var first = Recorder(), second = Recorder()
    player.run(&first)
    #expect(first.events.contains("buffer 0 \(layout.samples) 100"))
    #expect(player.memory[layout.samples] == 7)
    player.run(&second)
    // The tick after, the loop: a word of the sample, which the replayer has made nought.
    #expect(second.events.contains("buffer 0 \(layout.samples) 1"))
    #expect(player.memory[layout.samples] == 0 && player.memory[layout.samples + 1] == 0)
}

@Test func deltaMusicCommandsSetSpeedAndArpeggio() throws {
    // Command 1, the speed: 2, so that rows come every third tick.
    let (fast, _) = deltaMusic(command: [1, 2], blocks: 2)
    let player = try DeltaMusicPlayer(fast, checksReplayer: false)
    #expect(player.lengthTicks == 2 * 16 * 3)
    // Command 8, an arpeggio: table 1 of the module's, whose first steps are 0 and 12.
    var (module, _) = deltaMusic(command: [8, 1])
    module[DeltaMusicPlayer.arpeggiosAt + 16] = 0
    module[DeltaMusicPlayer.arpeggiosAt + 17] = 12
    module[DeltaMusicPlayer.arpeggiosAt + 18] = 0x80
    var arpeggio = try DeltaMusicPlayer(module, checksReplayer: false)
    var periods: [UInt16] = []
    for _ in 0 ..< 4 {
        var out = Recorder()
        arpeggio.run(&out)
        periods.append(arpeggio.period(0))
    }
    #expect(periods == [notePeriod(24), notePeriod(36), notePeriod(24), notePeriod(36)])
}

@Test func deltaMusicSongLength() throws {
    // Six ticks a row, sixteen rows a block, two blocks; the first voice's track goes round as its last
    // block begins, and the song is said to have come round as its first is begun again.
    let (module, _) = deltaMusic(blocks: 2)
    let player = try DeltaMusicPlayer(module, checksReplayer: false)
    #expect(player.lengthTicks == 2 * 16 * 6)
    var counting = try DeltaMusicPlayer(module, checksReplayer: false)
    var out = Recorder()
    for _ in 0 ..< 2 * 16 * 6 { counting.run(&out) }
    #expect(counting.endings == 0)
    counting.run(&out)
    #expect(counting.endings == 1)
}

@Test func deltaMusicOddModulesNeitherHangNorTrap() throws {
    // An instrument of nought, waveform lists of nothing but $FF, commands past eight, notes past the
    // table, and every length cut short.
    var (module, layout) = deltaMusic(command: [0x7F, 0xFF])
    module[DeltaMusicPlayer.songAt + 16 + 8 + 4 + 1] = 0
    module[layout.instruments + 40] = 0xFF
    module[layout.instruments + 41] = 0xFF
    var player = try DeltaMusicPlayer(module, checksReplayer: false)
    var out = Recorder()
    for _ in 0 ..< 3000 { player.run(&out) }
    module[DeltaMusicPlayer.songAt + 16 + 8 + 4] = 250
    module[DeltaMusicPlayer.songAt + 16 + 1] = 200
    _ = try? DeltaMusicPlayer(module, checksReplayer: false)
    for cut in stride(from: 0, to: module.count, by: 7) {
        _ = try? DeltaMusicPlayer(Array(module.prefix(cut)), checksReplayer: false)
    }
}

@Test func deltaMusicPlaysThroughTheRenderer() throws {
    let (module, _) = deltaMusic()
    let renderer = try PaulaTickRenderer(try DeltaMusicPlayer(module, checksReplayer: false), options: LoadOptions())
    #expect(renderer.info.format == "DM2")
    #expect(renderer.info.detail == "Delta Music 2.0")
    let frames = 4800
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.01)
    #expect(renderer.songs.first?.length != nil)
}

@Test func deltaMusicNotesBeginWhereTheReplayerTurnsThemOn() throws {
    // The first note is heard from where in the tick the replayer's DMA is turned on, not before.
    let (module, _) = deltaMusic()
    let player = try DeltaMusicPlayer(module, checksReplayer: false)
    let at = player.noteClocks * outputSampleRate / Int(Paula.clockHz)
    #expect(at > 40)
    let renderer = try PaulaTickRenderer(player, options: LoadOptions())
    var sound = [Float](repeating: 0, count: 400 * 2)
    sound.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 400) }
    let first = try #require((0 ..< 400).first { abs(sound[$0 * 2]) > 0.001 || abs(sound[$0 * 2 + 1]) > 0.001 })
    #expect(first >= at - 4)
    #expect(first <= at + 40)
}
