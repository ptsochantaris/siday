// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayTrackers
import Testing

// Fast checks of the MDL files that Impulse Tracker's replayer plays as Digitrakker's. The thorough
// check is made outside the package, against libopenmpt: every channel's pitch and volume on every
// tick of each file to hand.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0x20, count: max(0, length - bytes.count)) }
private func chunk(_ letters: String, _ body: [UInt8]) -> [UInt8] { Array(letters.utf8) + long(body.count) + body }

/// One channel's part of a row: a note (1 is the lowest C, 61 middle C; above 120 the key is let
/// go), an instrument, a volume of 255 (nought for none), and a command for each of the two columns,
/// each a number and a value.
private struct Cell {
    var note: UInt8 = 0, instrument: UInt8 = 0, volume: UInt8 = 0
    var first: (UInt8, UInt8) = (0, 0), second: (UInt8, UInt8) = (0, 0)

    static func note(_ note: UInt8 = 61, instrument: UInt8 = 1, volume: UInt8 = 0, _ first: (UInt8, UInt8) = (0, 0), _ second: (UInt8, UInt8) = (0, 0)) -> Cell {
        Cell(note: note, instrument: instrument, volume: volume, first: first, second: second)
    }

    static func commands(_ first: (UInt8, UInt8), _ second: (UInt8, UInt8) = (0, 0), volume: UInt8 = 0) -> Cell {
        Cell(volume: volume, first: first, second: second)
    }

    /// As a track has it: what follows, and then each that is there.
    var bytes: [UInt8] {
        var what: UInt8 = 0, rest: [UInt8] = []
        if note != 0 { what |= 1; rest.append(note) }
        if instrument != 0 { what |= 2; rest.append(instrument) }
        if volume != 0 { what |= 4; rest.append(volume) }
        if first.0 != 0 || second.0 != 0 { what |= 8; rest.append(second.0 << 4 | first.0) }
        if first.1 != 0 { what |= 16; rest.append(first.1) }
        if second.1 != 0 { what |= 32; rest.append(second.1) }
        return [what << 2 | 3] + rest
    }
}

/// A sample: a square wave of 32 samples, signed, eight bits, at 8,363 samples a second for the C
/// below middle C, so that middle C is 523 Hz.
private struct Sound {
    var frames: [Int8] = (0 ..< 32).map { $0 < 16 ? 127 : -127 }
    var loop: (start: Int, length: Int)? = (0, 32)
    var rate = 8363
    /// Its file's flags: 2 for a loop back and forth, 4 for packed.
    var flags: UInt8 = 0
    /// Its bytes in the file, if they are not its frames as they are (a packed sample's).
    var packed: [UInt8]?
}

/// An instrument of one sample for every note: its volume of 255, a fade, and the envelopes it
/// names (by their numbers, nil for none) with whether each is on.
private struct Instrument {
    var sample: UInt8 = 1
    var volume: UInt8 = 255
    var hasVolume = true
    var fade = 0
    var volumeEnvelope: UInt8?, pitchEnvelope: UInt8?
    var vibrato: (speed: UInt8, depth: UInt8, sweep: UInt8) = (0, 0, 0)
}

/// An envelope: its points as ticks apart and levels of 64, a point it holds at while the key is
/// down, and a loop.
private struct Envelope {
    var number: UInt8 = 0
    var points: [(UInt8, UInt8)] = [(1, 64)]
    var sustain: UInt8?
    var loop: (UInt8, UInt8)?
}

/// An MDL file of Digitrakker 3 of one or more patterns of 64 rows, each a list of cells.
/// - Parameter pans: where each channel is, of 128 places; 128 more for one switched off.
private func mdl(_ patterns: [[(row: Int, channel: Int, cell: Cell)]], channels: Int = 2, orders: [UInt8] = [0], pans: [UInt8] = [], speed: UInt8 = 6,
                 tempo: UInt8 = 125, sounds: [Sound] = [Sound()], instruments: [Instrument] = [Instrument()], volumeEnvelopes: [Envelope] = [],
                 pitchEnvelopes: [Envelope] = []) -> [UInt8] {
    var info = padded(Array("a square wave".utf8), to: 32) + padded(Array("somebody".utf8), to: 20)
    info += word(orders.count) + word(0) + [255, speed, tempo]
    info += (0 ..< 32).map { $0 < channels ? ($0 < pans.count ? pans[$0] : 64) : 0x80 }
    info += orders
    for _ in 0 ..< channels { info += padded([], to: 8) }

    var ii: [UInt8] = [UInt8(instruments.count)]
    for (number, ins) in instruments.enumerated() {
        ii += [UInt8(number + 1), 1] + padded(Array("an instrument".utf8), to: 32)
        let volumeFlags = (ins.volumeEnvelope.map { 0x80 | $0 } ?? 0) | (ins.hasVolume ? 0x40 : 0)
        let pitchFlags = ins.pitchEnvelope.map { 0x80 | $0 } ?? 0
        ii += [ins.sample, 119, ins.volume, volumeFlags, 64, 0] + word(ins.fade) + [ins.vibrato.speed, ins.vibrato.depth, ins.vibrato.sweep, 0, 0, pitchFlags]
    }
    func envelopes(_ list: [Envelope]) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(list.count)]
        for envelope in list {
            bytes.append(envelope.number)
            for node in 0 ..< 15 { bytes += node < envelope.points.count ? [envelope.points[node].0, envelope.points[node].1] : [0, 0] }
            bytes.append((envelope.sustain.map { 0x10 | $0 } ?? 0) | (envelope.loop == nil ? 0 : 0x20))
            bytes.append(envelope.loop.map { $0.1 << 4 | $0.0 } ?? 0)
        }
        return bytes
    }

    var samples: [UInt8] = [UInt8(sounds.count)], data: [UInt8] = []
    for (number, sound) in sounds.enumerated() {
        samples += [UInt8(number + 1)] + padded(Array("square".utf8), to: 32) + padded(Array("SQUARE".utf8), to: 8)
        samples += long(sound.rate) + long(sound.frames.count) + long(sound.loop?.start ?? 0) + long(sound.loop?.length ?? 0) + [255, sound.flags]
        data += sound.packed ?? sound.frames.map { UInt8(bitPattern: $0) }
    }

    var tracks: [[UInt8]] = [], pa: [UInt8] = [UInt8(patterns.count)]
    for pattern in patterns {
        pa += [UInt8(channels), 63] + padded(Array("a pattern".utf8), to: 16)
        for channel in 0 ..< channels {
            let cells = pattern.filter { $0.channel == channel }.sorted { $0.row < $1.row }
            guard !cells.isEmpty else {
                pa += word(0)
                continue
            }
            var track: [UInt8] = [], row = 0
            for (at, _, cell) in cells {
                if at > row { track.append(UInt8(at - row - 1) << 2) }
                track += cell.bytes
                row = at + 1
            }
            tracks.append(track)
            pa += word(tracks.count)
        }
    }
    var tr = word(tracks.count)
    for track in tracks { tr += word(track.count) + track }

    var file = Array("DMDL".utf8) + [0x11]
    file += chunk("IN", info) + chunk("PA", pa) + chunk("TR", tr) + chunk("II", ii)
    if !volumeEnvelopes.isEmpty { file += chunk("VE", envelopes(volumeEnvelopes)) }
    if !pitchEnvelopes.isEmpty { file += chunk("FE", envelopes(pitchEnvelopes)) }
    file += chunk("IS", samples) + chunk("SA", data)
    return file
}

/// A sample packed as Digitrakker packs one, of eight bits whose differences from one to the next
/// are all below eight either way.
private func packed(_ frames: [Int8]) -> [UInt8] {
    var bits: [Bool] = []
    var last: UInt8 = 0
    for frame in frames {
        var difference = UInt8(bitPattern: frame) &- last
        last = UInt8(bitPattern: frame)
        let negative = difference >= 0x80
        if negative { difference = ~difference }
        bits += [negative, true] + (0 ..< 3).map { difference >> $0 & 1 != 0 }
    }
    var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
    for (index, bit) in bits.enumerated() where bit { bytes[index / 8] |= 1 << UInt8(index % 8) }
    return long(bytes.count) + bytes
}

private func load(_ file: [UInt8]) throws -> any Renderer {
    var options = LoadOptions()
    options.stereo = .abc
    return try TuneLoader.load(file, format: .mdl, options: options)
}

private func stereo(_ renderer: any Renderer, seconds: Double) -> (left: [Float], right: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

private func loudness(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

/// What a channel's voice is at on each of so many ticks: samples a second, its volume of 64, its
/// note's own volume of 64, and whether it is sounding.
private func ticks(_ file: [UInt8], _ count: Int, channel: Int = 0) throws -> [(rate: Int, volume: Int, own: Int, sounding: Bool)] {
    let renderer = try #require(try TuneLoader.load(file, format: .mdl) as? ITRenderer)
    let player = IT2Player(renderer.module, forSound: true)
    return (0 ..< count).map { _ in
        player.Update()
        defer { _ = player.mixer.mixTick() }
        guard let voice = player.hChn[channel].SlaveChnPtr, voice.pointee.Flags & SF_CHAN_ON != 0, voice.pointee.Flags & SF_NOTE_STOP == 0 else { return (0, 0, 0, false) }
        return (Int(voice.pointee.Frequency), Int(voice.pointee.FinalVol128) / 2, Int(voice.pointee.Vol), true)
    }
}

@Test func mdlNoteSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "MDL") == .mdl)
    let renderer = try load(mdl([[(0, 0, .note())]]))
    #expect(renderer.info.format == "MDL" && renderer.info.title == "a square wave" && renderer.info.author == "somebody")
    #expect(renderer.info.detail == "Digitrakker 3" && renderer.info.shortfalls.isEmpty)
    // A sample's rate is for the C below middle C: middle C plays it twice as fast, and every note
    // is at the period Scream Tracker's table gives it, a whole number.
    #expect(try ticks(mdl([[(0, 0, .note())]]), 1)[0].rate == 16726)
    #expect(try ticks(mdl([[(0, 0, .note(49))]]), 1)[0].rate == 8363)
    #expect(try ticks(mdl([[(0, 0, .note(62))]]), 1)[0].rate == (16726 * 856 + 404) / 808)
    // Each channel at its place of 128.
    let left = stereo(try load(mdl([[(0, 0, .note())]], pans: [0, 127])), seconds: 0.5)
    let right = stereo(try load(mdl([[(0, 1, .note())]], pans: [0, 127])), seconds: 0.5)
    #expect(loudness(left.left[4800...]) > loudness(left.right[4800...]) * 10 && loudness(right.right[4800...]) > loudness(right.left[4800...]) * 10)
    // A channel switched off is not heard.
    #expect(loudness(stereo(try load(mdl([[(0, 0, .note())]], pans: [0x80 | 64])), seconds: 0.5).left[4800...]) < 0.0001)
    // A packed sample is the sample.
    let ramp: [Int8] = (0 ..< 32).map { (step: Int) -> Int8 in Int8(step < 16 ? step * 4 : (31 - step) * 4) }
    let plain = stereo(try load(mdl([[(0, 0, .note())]], sounds: [Sound(frames: ramp)])), seconds: 0.2)
    let squeezed = stereo(try load(mdl([[(0, 0, .note())]], sounds: [Sound(frames: ramp, flags: 4, packed: packed(ramp))])), seconds: 0.2)
    #expect(plain.left == squeezed.left)
}

@Test func mdlSlidesByPeriodsWhateverTheRate() throws {
    // A slide up by a period's unit a tick goes as far for a sample of twice the rate: the period,
    // not the rate, is what moves.
    let slow = try ticks(mdl([[(0, 0, .note(61, (0x1, 0x10)))]]), 6).map(\.rate)
    let fast = try ticks(mdl([[(0, 0, .note(61, (0x1, 0x10)))]], sounds: [Sound(rate: 16726)]), 6).map(\.rate)
    #expect(slow[5] > slow[0] && abs(Double(fast[5]) / Double(fast[0]) - Double(slow[5]) / Double(slow[0])) < 0.001)
    // Middle C's period is 856, and five ticks of a slide by 64 of them take it to 536.
    #expect(abs(slow[5] - 16726 * 856 / (856 - 5 * 64)) <= 1)
}

@Test func mdlNoteHasTwoCommandsAndAVolume() throws {
    // A volume, a place between the speakers and a slide of volume, all on the one note: the
    // place is done beside the cell.
    let file = mdl([[(0, 0, .note(61, volume: 255, (0x8, 0x7F), (0x2, 0x08)))]])
    #expect(try load(file).info.shortfalls.isEmpty)
    #expect(try ticks(file, 6).map(\.own) == [64, 62, 60, 58, 56, 54])
    let heard = stereo(try load(file), seconds: 0.5)
    #expect(loudness(heard.right[4800 ..< 9600]) > loudness(heard.left[4800 ..< 9600]) * 10)
    // A speed beside a vibrato, with a volume: the speed goes to another channel, and the row is three ticks.
    let quick = try load(mdl([[(0, 0, .note(61, volume: 128, (0x4, 0x44), (0xF, 0x03)))]]))
    #expect(quick.info.shortfalls.isEmpty)
    #expect(abs(try #require(quick.knownLength) - 64 * 3 * 0.02) < 0.01)
    // What has nowhere to go is left out, and the file says so: an arpeggio beside a tremolo, with a volume.
    let crowded = try load(mdl([[(0, 0, .note(61, volume: 128, (0x5, 0x37), (0x4, 0x44)))]]))
    #expect(crowded.info.shortfalls == ["One of its notes has more commands than Impulse Tracker's replayer has room for, and one is left out."])
}

@Test func mdlSlidesOfVolumeAreByTwoHundredAndFiftySixths() throws {
    // G04 is a 64th a tick, as Impulse Tracker's D10; G01 a quarter of that, which it has not. (A
    // row is six ticks, and a slide is on the five after its first.)
    #expect(try ticks(mdl([[(0, 0, .note(61, volume: 128, (0, 0), (0x1, 0x04)))]]), 6).map(\.own) == [32, 33, 34, 35, 36, 37])
    #expect(try ticks(mdl([[(0, 0, .note(61, volume: 128, (0, 0), (0x1, 0x01)))]]), 9).map(\.own) == [32, 32, 32, 32, 33, 33, 33, 33, 33])
    // And it goes on with nought, row after row.
    let goesOn = try ticks(mdl([[(0, 0, .note(61, volume: 128, (0, 0), (0x1, 0x01))), (1, 0, .commands((0, 0), (0x1, 0)))]]), 12).map(\.own)
    #expect(goesOn[11] == 34)
    // H80 is faster than Impulse Tracker goes: half the whole a tick.
    #expect(try ticks(mdl([[(0, 0, .note(61, volume: 255, (0, 0), (0x2, 0x80)))]]), 4).map(\.own) == [64, 32, 0, 0])
    // A fine slide, once, at the row's start.
    #expect(try ticks(mdl([[(0, 0, .note(61, volume: 128, (0, 0), (0x1, 0xF4)))]]), 3).map(\.own) == [36, 36, 36])
}

@Test func mdlStartsFurtherInWithItsVolume() throws {
    // EF1 -80 starts the note 0x18000 bytes in, with the volume it was given.
    let long = [Sound(frames: (0 ..< 0x20000).map { $0 < 0x18000 ? 0 : 100 }, loop: nil)]
    let file = mdl([[(0, 0, .note(61, volume: 128, (0xE, 0xF1), (0, 0x80)))]], sounds: long)
    #expect(try load(file).info.shortfalls.isEmpty)
    let player = try #require(try TuneLoader.load(file, format: .mdl) as? ITRenderer)
    let it = IT2Player(player.module, forSound: true)
    it.Update()
    let voice = try #require(it.hChn[0].SlaveChnPtr)
    #expect(voice.pointee.SamplingPosition == 0x18000 && voice.pointee.Vol == 32)
}

@Test func mdlCutIsSilenceThatAVolumeEnds() throws {
    // SC2 (EC2) turns the note down on its third tick, and it plays on: a volume brings it back.
    let file = mdl([[(0, 0, .note(61, (0xE, 0xC2))), (1, 0, .commands((0, 0), volume: 255))]])
    let cut = try ticks(file, 8)
    #expect(cut[..<2].allSatisfy { $0.own == 64 } && cut[2 ..< 6].allSatisfy { $0.sounding && $0.own == 0 } && cut[6].own == 64)
}

@Test func mdlEnvelopesAndFades() throws {
    // A volume envelope from 64 down to 16 over eight ticks, which holds there while the key is down.
    let down = Envelope(number: 3, points: [(1, 64), (8, 16)], sustain: 1)
    let enveloped = mdl([[(0, 0, .note())]], instruments: [Instrument(fade: 4095, volumeEnvelope: 3)], volumeEnvelopes: [down])
    let held = try ticks(enveloped, 12).map(\.volume)
    #expect(held[0] > held[4] && held[4] > held[9] && held[9] == held[11] && held[11] > 0)
    // Let go, it fades by its instrument's fade, whatever the envelope does.
    let letGo = try ticks(mdl([[(0, 0, .note()), (1, 0, .note(255, instrument: 0))]], instruments: [Instrument(fade: 4095, volumeEnvelope: 3)],
                              volumeEnvelopes: [down]), 40).map(\.volume)
    #expect(letGo[10] > letGo[20] && letGo[39] == 0)
    // A pitch envelope at its lowest is six semitones down.
    let low = Envelope(number: 0, points: [(1, 0)])
    let rate = try ticks(mdl([[(0, 0, .note())]], instruments: [Instrument(pitchEnvelope: 0)], pitchEnvelopes: [low]), 3)[2].rate
    #expect(abs(Double(rate) / 16726 - 0.7071) < 0.003)
    // An instrument without a volume of its own leaves the channel's as it was.
    let kept = try ticks(mdl([[(0, 0, .note(61, volume: 64)), (1, 0, .note())]], instruments: [Instrument(hasVolume: false)]), 8).map(\.own)
    #expect(kept.allSatisfy { $0 == 16 })
}

@Test func mdlTempoBelowThirtyTwoEndsTheSong() throws {
    // 701, a tempo slower than the replayer goes: the song stops after its row.
    let renderer = try load(mdl([[(0, 0, .note()), (8, 0, .commands((0x7, 0x01)))]]))
    #expect(abs(try #require(renderer.knownLength) - 9 * 6 * 0.02) < 0.01)
    let whole = try load(mdl([[(0, 0, .note())]]))
    #expect(abs(try #require(whole.knownLength) - 64 * 6 * 0.02) < 0.01)
}

@Test func mdlSaysWhatItLeavesOut() throws {
    func shortfalls(_ file: [UInt8]) throws -> [String] { try load(file).info.shortfalls }
    #expect(try shortfalls(mdl([[(0, 0, .note(61, (0xE, 0x81)))]])) == ["One of its commands is left out: changing how a sample loops (E8x)."])
    #expect(try shortfalls(mdl([[(0, 0, .note(61, (0xE, 0x53)))]])) == ["One of its commands is left out: tuning a sample afresh (E5x)."])
    #expect(try shortfalls(mdl([[(0, 0, .note(61, (0x9, 0x41)))]])) == ["Its notes that choose one of the tune's envelopes (9xx) have their instrument's own turned on in its place."])
    let short = [Sound(frames: [Int8](repeating: 1, count: 4000), loop: nil)]
    #expect(try shortfalls(Array(mdl([[(0, 0, .note())]], sounds: short).dropLast(3000))) == ["The file is cut short: its last sample ends in silence."])
}

@Test func mdlVoiceLeftOutIsSilentAndPlaysOn() throws {
    let file = mdl([[(0, 0, .note()), (0, 1, .note(73))]], pans: [0, 127])
    let whole = try load(file)
    #expect(whole.channelCount == 2)
    let heard = stereo(whole, seconds: 0.5)
    let renderer = try load(file)
    renderer.setMuted([false, true])
    let without = stereo(renderer, seconds: 0.5)
    #expect(loudness(without.right[4800...]) < 0.0001 && loudness(heard.right[4800...]) > 0.01)
    var levels = [Float](repeating: 0, count: 2)
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    #expect(levels[1] > 0.1)
    // With nothing left out the sound is what it always was.
    let again = try load(file)
    again.setMuted([false, false])
    #expect(stereo(again, seconds: 0.5).left == heard.left)
}

@Test func mdlFileThatIsCutOrDamagedIsReadOrRefused() throws {
    let ramp = (0 ..< 64).map { Int8($0 % 8 - 4) }
    let whole = mdl([[(0, 0, .note(61, volume: 200, (0x3, 0x10), (0x1, 0x21))), (1, 1, .note(40, (0xE, 0xF1), (0x8, 0x40))), (2, 0, .commands((0xD, 0x12)))],
                     [(0, 0, .note(255)), (4, 1, .note(70, instrument: 2, (0x4, 0x88), (0x5, 0x31)))]],
                    orders: [0, 1, 0], sounds: [Sound(), Sound(frames: ramp, flags: 4 | 2, packed: packed(ramp))],
                    instruments: [Instrument(fade: 300, volumeEnvelope: 1, vibrato: (8, 40, 10)), Instrument(sample: 2, pitchEnvelope: 0)],
                    volumeEnvelopes: [Envelope(number: 1, points: [(1, 64), (4, 20), (8, 40)], sustain: 1, loop: (0, 2))], pitchEnvelopes: [Envelope(points: [(1, 20), (10, 50)])])
    _ = stereo(try load(whole), seconds: 0.5)
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .mdl) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("DMDL".utf8) + [0x11], format: .mdl) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("DMDX".utf8) + [0x11] + whole.dropFirst(5), format: .mdl) }
    for length in stride(from: 0, to: whole.count, by: 7) {
        if let renderer = try? TuneLoader.load(Array(whole[..<length]), format: .mdl) { _ = stereo(renderer, seconds: 0.1) }
    }
    var seed: UInt32 = 13579
    func random() -> Int {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Int(seed >> 8)
    }
    for _ in 0 ..< 400 {
        var damaged = whole
        for _ in 0 ..< 1 + random() % 6 { damaged[5 + random() % (damaged.count - 5)] = UInt8(random() & 0xFF) }
        if let renderer = try? TuneLoader.load(damaged, format: .mdl) {
            for song in 0 ..< renderer.subsongCount {
                renderer.select(subsong: song)
                _ = stereo(renderer, seconds: 0.1)
            }
        }
    }
}
