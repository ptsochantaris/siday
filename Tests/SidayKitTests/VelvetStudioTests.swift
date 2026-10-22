// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayTrackers
import Testing

// Fast checks of the AMS files, Velvet Studio's and Extreme's Tracker's, that Impulse Tracker's
// replayer plays as OpenMPT plays them. The thorough check is made outside the package, against
// libopenmpt: every channel's pitch and volume on every tick of each file to hand.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func string(_ text: String) -> [UInt8] { [UInt8(text.utf8.count)] + Array(text.utf8) }

/// Middle C, as Velvet Studio numbers its notes (and 1 lets the key go).
private let middleC: UInt8 = 62

/// One channel's part of a row: a note and an instrument (nil for neither), and its commands, each
/// a number and a value, or a volume (`volume(_:)`).
private struct Cell {
    var channel = 0
    var note: UInt8?, instrument: UInt8 = 1
    var commands: [(UInt8, UInt8?)] = []

    static func note(_ note: UInt8 = middleC, _ instrument: UInt8 = 1, channel: Int = 0, _ commands: (UInt8, UInt8?)...) -> Cell {
        Cell(channel: channel, note: note, instrument: instrument, commands: commands)
    }

    static func commands(channel: Int = 0, _ commands: (UInt8, UInt8?)...) -> Cell {
        Cell(channel: channel, commands: commands)
    }

    static func volume(_ volume: UInt8) -> (UInt8, UInt8?) { (volume, nil) }

    func bytes(last: Bool) -> [UInt8] {
        var bytes = [UInt8(channel) | (last ? 0x80 : 0) | (note == nil ? 0x40 : 0)]
        if let note { bytes += [note | (commands.isEmpty ? 0 : 0x80), instrument] }
        for (index, command) in commands.enumerated() {
            let more: UInt8 = index < commands.count - 1 ? 0x80 : 0
            if let value = command.1 { bytes += [command.0 | more, value] } else { bytes.append(0x40 | command.0 | more) }
        }
        return bytes
    }
}

/// A pattern's rows as both kinds of file keep them.
private func rows(_ count: Int, _ cells: [(row: Int, cell: Cell)]) -> [UInt8] {
    var body: [UInt8] = []
    for row in 0 ..< count {
        let these = cells.filter { $0.row == row }.map(\.cell)
        if these.isEmpty { body.append(0xFF) }
        for (index, cell) in these.enumerated() { body += cell.bytes(last: index == these.count - 1) }
    }
    return body
}

/// A sample: a square wave of 32 samples, signed, eight bits, at 8,363 samples a second for middle C.
private struct Sound {
    var frames: [Int8] = (0 ..< 32).map { $0 < 16 ? 100 : -100 }
    var loop: Range<Int>? = 0 ..< 32
    var volume: UInt8 = 127
    var rate = 8363
    var packed = false, backwards = false

    /// Its sound in the file: as it is, or packed as Velvet Studio packs one, which is its
    /// differences from one byte to the next, a bit at a time across the whole, the top bits first.
    var data: [UInt8] {
        let raw = frames.map { UInt8(bitPattern: $0) }
        guard packed else { return raw }
        var differences: [UInt8] = [], old = 0
        for byte in frames {
            let d = old - Int(byte)
            differences.append(d >= 0 ? UInt8(d) : 0x80 | UInt8(-d))
            old = Int(byte)
        }
        // (For a sample of a whole number of eight bytes: the n-th time through, each byte's bits
        // are taken from its n-th highest round.)
        var planes = [UInt8](repeating: 0, count: raw.count)
        for pass in 0 ..< 8 {
            for (k, byte) in differences.enumerated() where byte >> UInt8(7 - pass) & 1 != 0 {
                planes[pass * raw.count / 8 + k / 8] |= 1 << UInt8(7 - (k % 8 + pass) % 8)
            }
        }
        // (No runs; only the mark for one, wherever it is a byte of its own, given as a run of none.)
        let mark: UInt8 = 0xE5
        let body = planes.flatMap { (byte: UInt8) -> [UInt8] in byte == mark ? [mark, 0] : [byte] }
        return long(raw.count) + long(body.count) + [mark] + body
    }
}

/// An instrument of one sample on every note, which may be another instrument's ("shadow"): its
/// fade, and an envelope for its volume and one for its pitch, each points of a tick after the
/// last and a level, that holds at its second point while the key is held.
private struct Instrument {
    var sound = Sound()
    var shadowOf: UInt8 = 0
    var fade = 0
    var volumeEnvelope: [(Int, UInt8)]?, pitchEnvelope: [(Int, UInt8)]?

    var bytes: [UInt8] {
        var b = string("instrument") + [1] + [UInt8](repeating: 0, count: 120)
        var flags = 0
        for (kind, points) in [volumeEnvelope, nil, pitchEnvelope].enumerated() {
            let points = points ?? []
            b += [0, 1, 0, 0, UInt8(points.count)] + points.flatMap { [UInt8($0.0 & 0xFF), UInt8($0.0 >> 8), $0.1] }
            if !points.isEmpty { flags |= (4 | 2) << (kind * 3) }
        }
        b += [shadowOf] + word(fade | 3 << 12) + word(flags)
        let s = sound
        let loop = s.loop ?? 0 ..< 0
        b += string("sound") + long(s.frames.count) + long(loop.lowerBound) + long(loop.upperBound) + word(8363) + [0] + word(s.rate) + [0, s.volume]
        b.append((s.packed ? 1 : 0) | (s.loop != nil ? 0x08 : 0) | (s.backwards ? 0x40 : 0))
        return b
    }
}

/// A Velvet Studio file of these patterns (each so many rows of cells), played in this order.
private func ams(_ patterns: [(rows: Int, cells: [(row: Int, cell: Cell)])], orders: [Int]? = nil, instruments: [Instrument] = [Instrument()],
                 tempo: Int = 125 << 8, speed: UInt8 = 6, linear: Bool = false) -> [UInt8] {
    let orders = orders ?? Array(patterns.indices)
    var file = Array("AMShdr".utf8) + [0x1A] + string("a square wave") + [2, 2, UInt8(instruments.count)] + word(patterns.count) + word(orders.count)
    file += word(tempo) + [speed, 0, 0, 0] + word(linear ? 0x40 : 0)
    file += instruments.flatMap(\.bytes) + string("somebody") + (0 ..< 32).flatMap { _ in string("") }
    file += long(11) + long(0) + [1, 0, 1]
    file += orders.flatMap { word($0) }
    for pattern in patterns {
        let body = [UInt8(pattern.rows - 1), 0] + string("") + rows(pattern.rows, pattern.cells)
        file += long(body.count) + body
    }
    for ins in instruments where ins.shadowOf == 0 { file += ins.sound.data }
    return file
}

/// An Extreme's Tracker file of these patterns, of 64 rows, with these samples.
private func extreme(_ patterns: [[(row: Int, cell: Cell)]], sounds: [Sound] = [Sound()], channels: Int = 4) -> [UInt8] {
    var file = Array("Extreme".utf8) + [0x30, 1, UInt8(channels - 1), UInt8(sounds.count)] + word(patterns.count) + word(patterns.count) + [0] + word(0)
    for s in sounds {
        let loop = s.loop ?? 0 ..< 0
        file += long(s.frames.count) + long(loop.lowerBound) + long(loop.upperBound) + [0] + word(s.rate / 2) + [s.volume, s.packed ? 1 : 0]
    }
    file += string("an extreme tune") + sounds.flatMap { _ in string("") } + (0 ..< channels).flatMap { _ in string("") } + patterns.flatMap { _ in string("") }
    file += word(0) + patterns.indices.flatMap { word($0) }
    for pattern in patterns {
        let body = rows(64, pattern)
        file += long(body.count) + body
    }
    return file + sounds.flatMap(\.data)
}

private func load(_ file: [UInt8]) throws -> any Renderer {
    var options = LoadOptions()
    options.stereo = .abc
    return try TuneLoader.load(file, format: .ams, options: options)
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

/// What a channel's voice is at on each of so many ticks: samples a second, its volume of 64, where
/// it is in its sample, and whether it is sounding.
private func ticks(_ file: [UInt8], _ count: Int, channel: Int = 0) throws -> [(rate: Int, volume: Int, at: Int, sounding: Bool)] {
    let renderer = try #require(try TuneLoader.load(file, format: .ams) as? ITRenderer)
    let player = IT2Player(renderer.module, forSound: true)
    return (0 ..< count).map { _ in
        player.Update()
        defer { _ = player.mixer.mixTick() }
        guard let voice = player.hChn[channel].SlaveChnPtr, voice.pointee.Flags & SF_CHAN_ON != 0, voice.pointee.Flags & SF_NOTE_STOP == 0,
              player.hChn[channel].Flags & HF_CHAN_ON != 0 else { return (0, 0, 0, false) }
        return (Int(voice.pointee.Frequency), Int(voice.pointee.FinalVol128) / 2, Int(voice.pointee.SamplingPosition), true)
    }
}

@Test func amsNoteSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "AMS") == .ams && TuneFormat.ams.chapter == "AMS")
    let renderer = try load(ams([(64, [(0, .note())])]))
    #expect(renderer.info.format == "AMS" && renderer.info.title == "a square wave" && renderer.info.author == "somebody")
    #expect(renderer.info.detail == "Velvet Studio 2.02" && renderer.info.shortfalls.isEmpty)
    // Velvet Studio's rate is for C-4, and is twice as fast for middle C.
    #expect(try ticks(ams([(64, [(0, .note())])]), 1)[0].rate == 16726)
    // The channels are to the left and the right as the Amiga's are: left, right, right, left.
    let first = stereo(try load(ams([(64, [(0, .note())])])), seconds: 0.5)
    let second = stereo(try load(ams([(64, [(0, .note(channel: 1))])])), seconds: 0.5)
    #expect(loudness(first.left[4800...]) > loudness(first.right[4800...]) * 2 && loudness(second.right[4800...]) > loudness(second.left[4800...]) * 2)
    // A packed sample is the sample.
    let ramp: [Int8] = (0 ..< 64).map { Int8($0 < 32 ? $0 * 3 : (63 - $0) * 3) - 40 }
    let plain = stereo(try load(ams([(64, [(0, .note())])], instruments: [Instrument(sound: Sound(frames: ramp))])), seconds: 0.2)
    let packed = stereo(try load(ams([(64, [(0, .note())])], instruments: [Instrument(sound: Sound(frames: ramp, packed: true))])), seconds: 0.2)
    #expect(plain.left == packed.left && loudness(plain.left[2400...]) > 0.01)
}

@Test func amsTempoIsAFraction() throws {
    // A tempo of 125 and a half: a row of six ticks lasts 6 × 2.5 / 125.5 of a second.
    let renderer = try load(ams([(64, [(0, .note())])], tempo: 125 << 8 | 0x80))
    #expect(abs(try #require(renderer.knownLength) - 64 * 6 * 2.5 / 125.5) < 0.01)
}

@Test func amsPitchEnvelopeGoesBySixteenthsOfASemitone() throws {
    // An envelope for pitch, from the middle (128) to the top: at its loudest, the note is two
    // semitones up (32 sixteenths), as OpenMPT plays these files.
    let ins = Instrument(pitchEnvelope: [(0, 128), (4, 255), (100, 255)])
    let rates = try ticks(ams([(64, [(0, .note())])], instruments: [ins]), 12).map(\.rate)
    #expect(rates[0] == 16726)
    #expect(abs(Double(rates[10]) / 16726 - pow(2, 2.0 / 12)) < 0.002)
}

@Test func amsKeyLetGoByACommandIsLetGoAtOnce() throws {
    // 20xx lets the key go: a note with an envelope that holds at 64 and falls after, to OpenMPT at
    // once, whatever xx says; and the file says that the ticks are not waited for.
    let ins = Instrument(fade: 0, volumeEnvelope: [(0, 127), (2, 127), (8, 0)])
    let file = ams([(64, [(0, .note()), (1, .commands((0x20, 0x03)))])], instruments: [ins])
    let heard = try ticks(file, 18)
    #expect(heard[5].volume == 64 && heard[9].volume < 64 && heard[14].volume == 0)
    #expect(try load(file).info.shortfalls == ["One of its commands is left out: letting a key go after so many ticks (20xx), which lets it go at once."])
}

@Test func amsShadowPlaysAnotherInstrumentsSample() throws {
    // The second instrument has no sound of its own, and plays the first's at its own rate.
    let file = ams([(64, [(0, .note(middleC, 2))])], instruments: [Instrument(), Instrument(sound: Sound(rate: 11025), shadowOf: 1)])
    let heard = try ticks(file, 3)
    #expect(heard[0].rate == 22050 && heard[2].sounding)
    #expect(loudness(stereo(try load(file), seconds: 0.3).left[4800...]) > 0.01)
}

@Test func amsBackwardsSampleStartsAtTheEndOfItsLoop() throws {
    let backwards = Instrument(sound: Sound(frames: (0 ..< 4000).map { Int8($0 % 50) - 25 }, loop: 1000 ..< 4000, backwards: true))
    let at = try ticks(ams([(64, [(0, .note())])], instruments: [backwards]), 4).map(\.at)
    #expect(at[0] >= 3990 && at[1] < at[0] && at[2] < at[1])
}

@Test func amsManyCommandsAndWhatHasNoRoom() throws {
    // A volume, a vibrato as it was and a slide of volume: the volume in the volume column, and the
    // slide joined to the vibrato as K.
    let joined = ams([(64, [(0, .note(middleC, 1, Cell.volume(32), (0x04, 0x46))), (1, .commands((0x04, 0x00), (0x0A, 0x02)))])])
    #expect(try load(joined).info.shortfalls.isEmpty)
    let heard = try ticks(joined, 9)
    #expect(heard[0].volume == 32 && heard[6].volume == 32 && heard[8].volume == 28 && heard[7].rate != heard[8].rate)
    // A tempo, a jump and a break: only one has room, and the file says two were left out.
    #expect(try load(ams([(64, [(0, .note(middleC, 1, (0x0F, 0x80), (0x0B, 0x00), (0x0D, 0x10)))])])).info.shortfalls
        == ["Two of its commands have no room beside their notes' others, and are left out."])
}

@Test func amsExtremesTrackerFileIsPlayed() throws {
    // Samples and no instruments; notes from 12, the C an octave below middle C's octave.
    let file = extreme([[(0, .note(36, 1)), (1, .note(48, 2, channel: 1)), (2, .note(108, 1, channel: 2))]], sounds: [Sound(), Sound(packed: true)])
    let renderer = try load(file)
    #expect(renderer.info.format == "AMS" && renderer.info.title == "an extreme tune" && renderer.info.detail == "Extreme's Tracker 1.48")
    // (Its rates are kept halved, and 8,363 is 8,362 again.)
    #expect(try ticks(file, 1)[0].rate == 4181 && ticks(file, 7, channel: 1)[6].rate == 8362)
    // Its highest note is beyond Impulse Tracker's, and is played a semitone lower.
    #expect(renderer.info.shortfalls == ["One of its notes is higher than Impulse Tracker's replayer plays, and is played a semitone lower."])
}

@Test func amsFileThatIsCutOrDamagedIsReadOrRefused() throws {
    let instruments = [Instrument(sound: Sound(packed: true), fade: 300, volumeEnvelope: [(0, 127), (6, 80), (20, 10)], pitchEnvelope: [(0, 128), (5, 200)]),
                       Instrument(sound: Sound(loop: 4 ..< 32, backwards: true)), Instrument(sound: Sound(rate: 11025), shadowOf: 1)]
    let whole = ams([(32, [(0, .note(middleC, 1, (0x04, 0x46), Cell.volume(40))), (1, .note(70, 2, channel: 1, (0x10, 0x01))), (4, .note(1, 0)),
                           (6, .note(50, 3, channel: 2, (0x03, 0x20), (0x1E, 0xA4), (0x20, 0x02)))]),
                     (16, [(0, .commands((0x0E, 0x62), (0x2A, 0x04))), (8, .commands((0x0E, 0x60)))])], orders: [0, 1, 0], instruments: instruments)
    _ = stereo(try load(whole), seconds: 0.5)
    let old = extreme([[(0, .note(40, 1, (0x0A, 0x02))), (2, .note(1, 0))]], sounds: [Sound(packed: true)])
    _ = stereo(try load(old), seconds: 0.5)
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .ams) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(whole[..<20]), format: .ams) }
    var wrong = whole
    wrong[22] = 3
    #expect(throws: TuneError.self) { try TuneLoader.load(wrong, format: .ams) }
    var seed: UInt32 = 97531
    func random() -> Int {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Int(seed >> 8)
    }
    for file in [whole, old] {
        for length in stride(from: 0, to: file.count, by: 9) {
            if let renderer = try? TuneLoader.load(Array(file[..<length]), format: .ams) { _ = stereo(renderer, seconds: 0.1) }
        }
        for _ in 0 ..< 300 {
            var damaged = file
            for _ in 0 ..< 1 + random() % 6 { damaged[random() % damaged.count] = UInt8(random() & 0xFF) }
            if let renderer = try? TuneLoader.load(damaged, format: .ams) {
                for song in 0 ..< renderer.subsongCount {
                    renderer.select(subsong: song)
                    _ = stereo(renderer, seconds: 0.1)
                }
            }
        }
    }
}
