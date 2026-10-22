// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayTrackers
import Testing

// Fast checks of the IMF files that Impulse Tracker's replayer plays as OpenMPT plays Imago
// Orpheus's. The thorough check is made outside the package, against libopenmpt: every channel's
// pitch and volume on every tick of each file to hand.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func text(_ string: String, _ length: Int) -> [UInt8] { Array(Array(string.utf8).prefix(length)) + [UInt8](repeating: 0, count: max(0, length - string.utf8.count)) }

/// Middle C, as Imago Orpheus writes a note: its octave in the high half, from C-0 as Impulse
/// Tracker's C-1, and its place in the octave in the low.
private let middleC: UInt8 = 0x40

/// One channel's part of a row: a note (160 lets the key go) and an instrument, and up to two
/// commands, each a number and a value.
private struct Cell {
    var channel = 0
    var note: UInt8?, instrument: UInt8 = 1
    var first: (UInt8, UInt8)?, second: (UInt8, UInt8)?

    static func note(_ note: UInt8 = middleC, _ instrument: UInt8 = 1, channel: Int = 0, _ first: (UInt8, UInt8)? = nil, _ second: (UInt8, UInt8)? = nil) -> Cell {
        Cell(channel: channel, note: note, instrument: instrument, first: first, second: second)
    }

    static func alone(_ instrument: UInt8, channel: Int = 0) -> Cell {
        Cell(channel: channel, note: 255, instrument: instrument)
    }

    static func commands(_ first: (UInt8, UInt8), _ second: (UInt8, UInt8)? = nil, channel: Int = 0) -> Cell {
        Cell(channel: channel, first: first, second: second)
    }

    var bytes: [UInt8] {
        var mask = UInt8(channel), rest: [UInt8] = []
        if let note {
            mask |= 0x20
            rest += [note, instrument]
        }
        if let first {
            mask |= second == nil ? 0x40 : 0xC0
            rest += [first.0, first.1]
            if let second { rest += [second.0, second.1] }
        }
        return [mask] + rest
    }
}

/// A sample: a square wave of 32 samples, signed, eight bits, at 8,363 samples a second for middle C.
private struct Sound {
    var frames: [Int8] = (0 ..< 32).map { $0 < 16 ? 100 : -100 }
    var loops = true
    var volume: UInt8 = 64
    var rate = 8363

    var bytes: [UInt8] {
        var h = text("sound.wav", 16) + long(frames.count) + long(0) + long(loops ? frames.count : 0) + long(rate)
        h += [volume, 128] + [UInt8](repeating: 0, count: 14) + [loops ? 1 : 0] + [UInt8](repeating: 0, count: 5) + word(0) + long(0) + Array("IS10".utf8)
        return h + frames.map { UInt8(bitPattern: $0) }
    }
}

/// An instrument of its samples, the first on every note; its fade, and an envelope for its volume
/// (points of a tick and a level of 64, which holds at its second point while the key is held), if
/// it has one.
private struct Instrument {
    var sounds: [Sound] = [Sound()]
    var fade = 0
    var volumeEnvelope: [(Int, Int)]?

    var bytes: [UInt8] {
        var h = text("instrument", 32) + [UInt8](repeating: 0, count: 120) + [UInt8](repeating: 0, count: 8)
        for kind in 0 ..< 3 {
            let points = kind == 0 ? volumeEnvelope ?? [(0, 64), (10, 64)] : [(0, 128), (10, 128)]
            for n in 0 ..< 16 { h += n < points.count ? word(points[n].0) + word(points[n].1) : word(0) + word(0) }
        }
        for kind in 0 ..< 3 {
            if kind == 0, let points = volumeEnvelope {
                h += [UInt8(points.count), 1, 0, 0, 3, 0, 0, 0]
            } else {
                h += [2, 0, 0, 0, 0, 0, 0, 0]
            }
        }
        h += word(fade) + word(sounds.count) + Array("II10".utf8)
        return h + sounds.flatMap(\.bytes)
    }
}

/// An IMF file of these patterns (each a list of its rows' cells, of 64 rows), played in this
/// order, at six ticks to a row and a tempo of 125.
private func imf(_ patterns: [[(row: Int, cell: Cell)]], orders: [UInt8]? = nil, instruments: [Instrument] = [Instrument()], channels: Int = 4,
                 linear: Bool = false, pans: [UInt8] = [], amp: UInt8 = 48, master: UInt8 = 64) -> [UInt8] {
    let orders = orders ?? patterns.indices.map { UInt8($0) }
    var file = text("a square wave", 32) + word(orders.count) + word(patterns.count) + word(instruments.count) + word(linear ? 1 : 0)
    file += [UInt8](repeating: 0, count: 8) + [6, 125, master, amp] + [UInt8](repeating: 0, count: 8) + Array("IM10".utf8)
    for channel in 0 ..< 32 {
        file += text("channel", 12) + [0, 0, channel < pans.count ? pans[channel] : 128, channel < channels ? 0 : 2]
    }
    file += orders + [UInt8](repeating: 255, count: 256 - orders.count)
    for pattern in patterns {
        var body: [UInt8] = []
        for row in 0 ..< 64 {
            for entry in pattern where entry.row == row { body += entry.cell.bytes }
            body.append(0)
        }
        file += word(body.count + 4) + word(64) + body
    }
    return file + instruments.flatMap(\.bytes)
}

private func load(_ file: [UInt8]) throws -> any Renderer {
    var options = LoadOptions()
    options.stereo = .abc
    return try TuneLoader.load(file, format: .imf, options: options)
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
    let renderer = try #require(try TuneLoader.load(file, format: .imf) as? ITRenderer)
    let player = IT2Player(renderer.module, forSound: true)
    return (0 ..< count).map { _ in
        player.Update()
        defer { _ = player.mixer.mixTick() }
        guard let voice = player.hChn[channel].SlaveChnPtr, voice.pointee.Flags & SF_CHAN_ON != 0, voice.pointee.Flags & SF_NOTE_STOP == 0,
              player.hChn[channel].Flags & HF_CHAN_ON != 0 else { return (0, 0, 0, false) }
        return (Int(voice.pointee.Frequency), Int(voice.pointee.FinalVol128) / 2, Int(voice.pointee.Vol), true)
    }
}

@Test func imfNoteSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "IMF") == .imf && TuneFormat.imf.chapter == "IMF")
    let renderer = try load(imf([[(0, .note())]]))
    #expect(renderer.info.format == "IMF" && renderer.info.title == "a square wave" && renderer.info.detail == "Imago Orpheus")
    #expect(renderer.info.shortfalls.isEmpty)
    // Middle C plays the sample at its own rate, and the octave above at twice it.
    #expect(try ticks(imf([[(0, .note())]]), 1)[0].rate == 8363)
    #expect(try ticks(imf([[(0, .note(0x50))]]), 1)[0].rate == 16726)
    // Each channel at its place of 256.
    let left = stereo(try load(imf([[(0, .note())]], pans: [0, 255])), seconds: 0.5)
    let right = stereo(try load(imf([[(0, .note(channel: 1))]], pans: [0, 255])), seconds: 0.5)
    #expect(loudness(left.left[4800...]) > loudness(left.right[4800...]) * 10 && loudness(right.right[4800...]) > loudness(right.left[4800...]) * 10)
    // A pattern the file does not have ends the song.
    #expect(abs(try #require(try load(imf([[(0, .note())]], orders: [0, 5, 0])).knownLength) - 64 * 6 * 0.02) < 0.01)
}

@Test func imfVibratoWaitsOnTheRowsFirstTick() throws {
    // A vibrato (5xy) plays its wave where it is on a row's first tick, and moves on only after.
    let rates = try ticks(imf([[(0, .note(middleC, 1, (0x05, 0x48))), (1, .commands((0x05, 0x48)))]]), 12).map(\.rate)
    #expect(rates[0] == 8363 && rates[1] != 8363)
    // The second row's first tick is where the first row's last left it.
    #expect(rates[6] == rates[5])
}

@Test func imfSlideWithBothHalvesGoesDown() throws {
    // D23 slides down by three a tick, where Impulse Tracker's does nothing.
    let own = try ticks(imf([[(0, .note(middleC, 1, (0x0C, 40), (0x0D, 0x23)))]]), 6).map(\.own)
    #expect(own == [40, 37, 34, 31, 28, 25])
}

@Test func imfCutsAndDelaysOfNoughtAreNow() throws {
    // XC0 cuts the note on its first tick, and XD0 does not hold it up.
    #expect(try ticks(imf([[(0, .note(middleC, 1, (0x21, 0xC0)))]]), 2).map(\.sounding) == [false, false])
    #expect(try ticks(imf([[(0, .note(middleC, 1, (0x21, 0xD0)))]]), 1)[0].sounding)
    // X00 is not the last X again: XC2 then X00 cuts the first note, and not the second.
    let file = imf([[(0, .note(middleC, 1, (0x21, 0xC2))), (1, .note(middleC, 1, (0x21, 0x00)))]])
    #expect(try ticks(file, 12).map(\.sounding) == [true, true, false, false, false, false] + [Bool](repeating: true, count: 6))
}

@Test func imfGlobalVolumeAboveTheTopIsTheTop() throws {
    // V20 halves it; V50 (twice the top, of 64) is the top again.
    let file = imf([[(0, .note(middleC, 1, (0x1F, 0x20))), (1, .commands((0x1F, 0x50)))]])
    let volumes = try ticks(file, 7).map(\.volume)
    #expect(volumes[0] == 32 && volumes[6] == 64)
}

@Test func imfInstrumentAlonePlaysTheLastNoteThatHadASample() throws {
    // An instrument with no samples is named beside a note an octave up, which is not played; another
    // instrument named alone after it plays the last note that was, middle C, and from its start.
    let empty = Instrument(sounds: [])
    let file = imf([[(0, .note()), (1, .note(0x50, 2)), (2, .alone(3))]], instruments: [Instrument(), empty, Instrument(sounds: [Sound(rate: 11025)])])
    let rates = try ticks(file, 13).map(\.rate)
    #expect(rates[6] == 8363 && rates[12] == 11025)
    // And on a channel that has played nothing, an instrument alone starts nothing.
    #expect(try ticks(imf([[(0, .alone(1))]]), 2).map(\.sounding) == [false, false])
}

@Test func imfFadesAreFine() throws {
    // A fade of 128 is a 512th of the whole a tick, as OpenMPT keeps it: after the key is let go the
    // note is still heard sixty ticks on, where Impulse Tracker's fade of 128 would be over in eight.
    let file = imf([[(0, .note()), (1, .note(160))]], instruments: [Instrument(fade: 128, volumeEnvelope: [(0, 64), (5, 64)])])
    let after = try ticks(file, 72)
    #expect(after[66].sounding && after[66].volume < 64)
    // With neither a fade nor an envelope for its volume, the note ends as soon as its key is let go.
    #expect(try ticks(imf([[(0, .note()), (1, .note(160))]]), 9)[8].sounding == false)
}

@Test func imfSlideToANoteBringsBackOneLetGo() throws {
    // A note let go fades; a slide to another note with its instrument beside it holds it again,
    // at its envelope's held level, and stops its fade.
    let ins = Instrument(fade: 2000, volumeEnvelope: [(0, 64), (4, 40), (20, 8)])
    let file = imf([[(0, .note()), (2, .note(160)), (4, .note(0x50, 1, (0x03, 0x40)))]], instruments: [ins])
    let heard = try ticks(file, 40)
    #expect(heard[23].volume < 20)
    #expect(heard[30].sounding && heard[39].volume >= 38)
}

@Test func imfFilterIsOpenMPTsEMU8000() throws {
    // M00 leaves the filter wide open: Mxx, the other way up from Impulse Tracker's Zxx, at MFF
    // takes it down to 125 Hz and the square wave a long way down with it.
    let open = stereo(try load(imf([[(0, .note(0x60, 1, (0x16, 0x00)))]])), seconds: 0.5)
    let shut = stereo(try load(imf([[(0, .note(0x60, 1, (0x16, 0xFF)))]])), seconds: 0.5)
    #expect(loudness(shut.left[4800...]) < loudness(open.left[4800...]) / 10)
    // Its resonance (Nxy) is played, and its slide is not, which the file says; and beside Mxx
    // there is room for only one of them.
    #expect(try load(imf([[(0, .note(0x60, 1, (0x17, 0x38)))]])).info.shortfalls == ["One of its commands is left out: slides of the filter (Nxy)."])
    #expect(try load(imf([[(0, .note(0x60, 1, (0x16, 0x40), (0x17, 0x08)))]])).info.shortfalls
        == ["One of its notes has more commands than Impulse Tracker's replayer has room for, and one is left out."])
}

@Test func imfNoteHasTwoCommandsAndSomeAreLeftOut() throws {
    // A volume and a slide of pitch: the volume goes to the volume column.
    let both = imf([[(0, .note(middleC, 1, (0x0C, 32), (0x12, 0x10)))]])
    #expect(try load(both).info.shortfalls.isEmpty)
    let rates = try ticks(both, 3)
    #expect(rates[0].own == 32 && rates[2].rate > rates[1].rate)
    // A speed and a jump: only one has room, and the file says one was left out.
    #expect(try load(imf([[(0, .note(middleC, 1, (0x01, 3), (0x1D, 0)))]])).info.shortfalls
        == ["One of its notes has more commands than Impulse Tracker's replayer has room for, and one is left out."])
    // Glissando and the chorus are not played, and the file says so.
    #expect(try load(imf([[(0, .note(middleC, 1, (0x21, 0x31), (0x22, 0x40)))]])).info.shortfalls
        == ["Two of its commands are left out: chorus (Yxx) and glissando (X3x)."])
}

@Test func imfFileThatIsCutOrDamagedIsReadOrRefused() throws {
    let ins = [Instrument(fade: 300, volumeEnvelope: [(0, 64), (6, 40), (20, 10)]), Instrument(sounds: [Sound(loops: false, rate: 11025), Sound()])]
    let whole = imf([[(0, .note(middleC, 1, (0x05, 0x48), (0x0D, 0x23))), (1, .note(0x45, 2, (0x16, 0x80))), (2, .commands((0x21, 0xA0))), (8, .commands((0x21, 0xA2)))],
                     [(0, .note(160)), (4, .note(0x30, 2, (0x03, 0x20), (0x1B, 0x83)))]], orders: [0, 1, 255, 0], instruments: ins)
    _ = stereo(try load(whole), seconds: 0.5)
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .imf) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(whole[..<0x40]), format: .imf) }
    var wrong = whole
    wrong[0x3C] = 0x4A
    #expect(throws: TuneError.self) { try TuneLoader.load(wrong, format: .imf) }
    for length in stride(from: 0, to: whole.count, by: 11) {
        if let renderer = try? TuneLoader.load(Array(whole[..<length]), format: .imf) { _ = stereo(renderer, seconds: 0.1) }
    }
    var seed: UInt32 = 24680
    func random() -> Int {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Int(seed >> 8)
    }
    for _ in 0 ..< 400 {
        var damaged = whole
        for _ in 0 ..< 1 + random() % 6 { damaged[random() % damaged.count] = UInt8(random() & 0xFF) }
        if let renderer = try? TuneLoader.load(damaged, format: .imf) {
            for song in 0 ..< renderer.subsongCount {
                renderer.select(subsong: song)
                _ = stereo(renderer, seconds: 0.1)
            }
        }
    }
}
