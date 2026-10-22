// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayTrackers
import Testing

// Fast checks of Symphonie's modules, which are read as OpenMPT reads them and played by Impulse
// Tracker's replayer. The thorough check is made outside the package, against libopenmpt: every
// sample's sound, every cell, every tick's place and every channel's pitch and volume on every tick,
// of each file to hand.

private func be32(_ value: Int) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (24 - $0 * 8)) } }
private func be16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
private func part(_ type: Int, _ body: [UInt8]) -> [UInt8] { be32(type) + be32(body.count) + body }
private func value(_ type: Int, _ value: Int) -> [UInt8] { be32(type) + be32(value) }

/// One of Symphonie's events: a command, a note (nought the lowest; -1 none), a value and an instrument from nought.
private struct Event {
    var command: UInt8 = 0, note: Int8 = -1, param: UInt8 = 0, inst: UInt8 = 0
    static func key(_ note: Int8 = 24, volume: UInt8 = 100, inst: UInt8 = 0) -> Event { Event(note: note, param: volume, inst: inst) }
    static let stop = Event(param: 254), go = Event(param: 253)
}

/// An instrument of 256 bytes: named, of a kind (0 plain, 4 looping), at a volume of 100.
private func instrument(type: UInt8 = 0, volume: UInt8 = 100, loop: (start: UInt8, length: UInt8) = (0, 0)) -> [UInt8] {
    var d = [UInt8](repeating: 0, count: 256)
    d[0] = 0x61
    d[128] = type
    d[129] = loop.start
    d[130] = loop.length
    d[134] = volume
    return d
}

/// A virtual instrument, of one part: another instrument's sample at a note.
private func virtual(of source: UInt8) -> [UInt8] {
    var d = instrument()
    d.replaceSubrange(0 ..< 4, with: Array("ViRT".utf8))
    d.replaceSubrange(14 ..< 20, with: be16(1) + be16(20) + be16(4))
    d.replaceSubrange(20 ..< 24, with: [0, 24, 0, source])
    return d
}

/// A square wave of eight bits, 256 points long.
private let square: [UInt8] = (0 ..< 256).map { $0 % 32 < 16 ? 100 : UInt8(bitPattern: -100) }

private func symmod(channels: Int = 2, rows: Int = 8, speed: Int = 6, cells: [(row: Int, channel: Int, event: Event)],
                    instruments: [[UInt8]] = [instrument(type: 4, loop: (0, 100))], samples: [[UInt8]?] = [square], extra: [UInt8] = []) -> [UInt8] {
    var events = [UInt8](repeating: 0, count: rows * channels * 4)
    for i in 0 ..< rows * channels { events[i * 4 + 1] = 0xFF }
    for (row, channel, event) in cells {
        let at = (row * channels + channel) * 4
        events.replaceSubrange(at ..< at + 4, with: [event.command, UInt8(bitPattern: event.note), event.param, event.inst])
    }
    var position = [UInt8](repeating: 0, count: 32)
    position.replaceSubrange(4 ..< 6, with: be16(1))
    position.replaceSubrange(12 ..< 16, with: be16(rows) + be16(speed))
    var sequence = [UInt8](repeating: 0, count: 16)
    sequence.replaceSubrange(0 ..< 4, with: be16(0) + be16(1))
    var file = Array("SymM".utf8) + be32(1) + be32(-1) + be32(channels)
    file += value(-2, rows) + value(-5, 4) + value(-6, 100) + extra
    file += part(-14, instruments.flatMap { $0 }) + part(-10, position) + part(-13, events) + part(-15, sequence)
    for sample in samples { file += sample.map { part(-11, $0) } ?? be32(-12) }
    return file
}

private func load(_ file: [UInt8]) throws -> ITRenderer {
    var options = LoadOptions()
    options.stereo = .abc
    return try #require(try TuneLoader.load(file, format: .symmod, options: options) as? ITRenderer)
}

private func stereo(_ renderer: any Renderer, seconds: Double) -> (left: [Float], right: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

private func loudness(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
}

/// Channel 0's voice on each of so many ticks: samples a second, where it is in its sample, and whether it is stopped.
private func ticks(_ file: [UInt8], _ count: Int) throws -> [(rate: Int, at: Int, paused: Bool)] {
    let renderer = try load(file)
    let player = IT2Player(renderer.module, forSound: true)
    return (0 ..< count).map { _ in
        player.Update()
        defer { _ = player.mixer.mixTick() }
        guard let voice = player.hChn[0].SlaveChnPtr, voice.pointee.Flags & SF_CHAN_ON != 0 else { return (0, 0, false) }
        return (Int(voice.pointee.Frequency), Int(voice.pointee.SamplingPosition), voice.pointee.Paused)
    }
}

@Test func symmodNoteSoundsAtItsPitchOnItsSide() throws {
    #expect(TuneFormat(fileExtension: "SymMOD") == .symmod)
    #expect(SymMODFile.isOne(symmod(cells: [])) && !SymMODFile.isOne(Array("SymM".utf8) + be32(2)))
    let renderer = try load(symmod(cells: [(0, 0, .key())]))
    #expect(renderer.info.format == "SymMOD" && renderer.info.detail == "Symphonie" && renderer.info.shortfalls.isEmpty)
    // Every sample plays at 40,460 a second at middle C, which is Symphonie's note 36.
    #expect(try ticks(symmod(cells: [(0, 0, .key(36))]), 1)[0].rate == 40460)
    #expect(try ticks(symmod(cells: [(0, 0, .key())]), 1)[0].rate == 40460 / 2)
    // The even channels are on the left, the odd on the right.
    let left = stereo(try load(symmod(cells: [(0, 0, .key())])), seconds: 0.3)
    let right = stereo(try load(symmod(cells: [(0, 1, .key())])), seconds: 0.3)
    #expect(loudness(left.left[2000...]) > 0.01 && loudness(left.right[2000...]) < 0.0001)
    #expect(loudness(right.right[2000...]) > 0.01 && loudness(right.left[2000...]) < 0.0001)
}

@Test func symmodSampleStopsWhereItIsAndGoesOn() throws {
    // Six ticks to a row: the sample is stopped on the second row and let go on on the fourth.
    let file = symmod(cells: [(0, 0, .key()), (1, 0, .stop), (3, 0, .go)])
    let t = try ticks(file, 30)
    #expect(!t[5].paused && t[6].paused && t[17].paused && !t[18].paused)
    // Stopped, it does not move on: it goes on from where it was.
    #expect(t[7].at == t[6].at && t[17].at == t[6].at && t[18].at == t[17].at && t[19].at != t[18].at)
    let sound = stereo(try load(file), seconds: 1.2)
    let tick = Int(2.5 / 124 * Double(outputSampleRate))
    // (Once what it last put out has died away.)
    #expect(loudness(sound.left[(9 * tick)...(17 * tick)]) < 0.0001)
    #expect(loudness(sound.left[(19 * tick)...(23 * tick)]) > 0.01)
}

/// A triangle wave of eight bits, 256 points long, whose sound changes little from frame to frame.
private let triangle: [UInt8] = (0 ..< 256).map { UInt8(bitPattern: Int8(100 - abs($0 - 128) * 200 / 128)) }

@Test func symmodSampleStopsAndGoesOnWithoutAClick() throws {
    // As OpenMPT plays it: what the voice last put out when its sample is stopped dies away, and
    // when it goes on it is ramped in from silence. Neither is a step in the sound.
    let file = symmod(cells: [(0, 0, .key()), (1, 0, .stop), (3, 0, .go)], samples: [triangle])
    let left = stereo(try load(file), seconds: 1.2).left
    let tick = Int(2.5 / 124 * Double(outputSampleRate))
    let peak = left.map { abs($0) }.max() ?? 0
    let step = zip(left.dropFirst(), left).map { abs($0 - $1) }.max() ?? 0
    #expect(peak > 0.1 && step < peak / 20)
    // (It was sounding when it was stopped, and when it went on.)
    #expect(loudness(left[(5 * tick)...(6 * tick - 50)]) > peak / 4 && loudness(left[(19 * tick)...(20 * tick)]) > peak / 4)
}

@Test func symmodVirtualInstrumentIsMadeOfAnother() throws {
    // The second instrument is the first's sample, mixed again at the same note: a sample as long,
    // of sixteen bits, made as loud as it can be.
    let renderer = try load(symmod(cells: [(0, 0, .key(inst: 1))], instruments: [instrument(), virtual(of: 0)], samples: [square, nil]))
    let listing = renderer.listing()
    #expect(listing.samples[1].length == 256 && listing.samples[1].sixteenBit && listing.samples[0].length == 256)
    #expect(listing.instruments[1].samples[60] == 2)
    #expect(try ticks(symmod(cells: [(0, 0, .key(inst: 1))], instruments: [instrument(), virtual(of: 0)], samples: [square, nil]), 1)[0].rate == 40460 / 2)
}

@Test func symmodPackedPartsUnpack() {
    // So many bytes as they are, four bytes three times, four twice, and two noughts.
    let body: [UInt8] = Array("PACK".utf8) + [0xFF, 0xFF] + be32(24) + [0, 2, 7, 8] + [1, 3, 1, 2, 3, 4] + [2, 5, 6, 7, 8] + [3, 2] + [0xFF]
    var r = SymMODBytes(be32(body.count) + body)
    #expect(SymMODFile.decoded(&r) == [7, 8] + [1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4] + [5, 6, 7, 8, 5, 6, 7, 8] + [0, 0])
    // A part that does not unpack to its length is nothing.
    let short: [UInt8] = Array("PACK".utf8) + [0xFF, 0xFF] + be32(30) + [0, 2, 7, 8, 0xFF]
    var s = SymMODBytes(be32(short.count) + short)
    #expect(SymMODFile.decoded(&s).isEmpty)
    // And a sample's eight bits are each the difference from the one before.
    let deltas: [UInt8] = [10, 5, 251]
    var d = SymMODBytes(be32(deltas.count) + deltas)
    #expect(SymMODFile.decodedSample8(&d) == [10, 15, 10])
}

@Test func symmodSaysWhatIsLeftOut() throws {
    // Adding to a note's pitch (command 10), which OpenMPT leaves out.
    let renderer = try load(symmod(cells: [(0, 0, .key()), (1, 0, Event(command: 10, note: 0, param: 20))]))
    #expect(renderer.info.shortfalls.contains { $0.contains("adding to its pitch") })
}

@Test func symmodCutShortIsNoTrouble() {
    let file = symmod(cells: [(0, 0, .key())])
    for length in stride(from: 16, to: file.count, by: 7) {
        let cut = Array(file[0 ..< length])
        if let renderer = try? TuneLoader.load(cut, format: .symmod) { _ = stereo(renderer, seconds: 0.05) }
    }
}
