// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the Impulse Tracker path. The thorough check is made outside the package, against
// the player it is ported from (it2play): `siday --raw out.raw tune.it` writes the tune as that
// player would write it to a file, and the two are to agree to the sample.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0, count: length - bytes.count) }

/// An IT file of one pattern and one sample, a square wave of 32 samples, looping, with C-5 on the
/// first channel of the first row.
/// - Parameters:
///   - row: the packed bytes of the first row, in place of that note.
///   - pan: where the first channel sits, from 0 (left) to 64 (right).
///   - orders: the list of patterns to play, where 255 is its end.
///   - emptySample: whether there is a second sample, of no length, whose sound is said to be at the
///     end of the file: ModPlug Tracker's way of writing an empty one.
///   - before: how many samples of nothing come before the square wave, which the note then plays
///     by its number.
private func it(row: [UInt8]? = nil, pan: UInt8 = 32, orders: [UInt8] = [0, 255], emptySample: Bool = false, before: Int = 0) -> [UInt8] {
    let samples = before + (emptySample ? 2 : 1)
    var file = Array("IMPM".utf8) + padded(Array("a square wave".utf8), to: 26) + [4, 16]
    file += word(orders.count) + word(0) + word(samples) + word(1) + word(0x0214) + word(0x0200) + word(1) + word(0)
    file += [128, 48, 6, 125, 128, 0] + word(0) + long(0) + long(0)
    file += [pan] + [UInt8](repeating: 32, count: 63) + [UInt8](repeating: 64, count: 64)
    file += orders
    let tables = file.count + samples * 4 + 4
    let sampleHeader = tables, pattern = sampleHeader + samples * 0x50
    let rows = (row ?? [0x81, 0x03, 60, UInt8(before + 1)]) + [UInt8](repeating: 0, count: 64)
    let sound = pattern + 8 + rows.count
    for i in 0 ..< samples { file += long(sampleHeader + i * 0x50) }
    file += long(pattern)

    var header = Array("IMPS".utf8) + [UInt8](repeating: 0, count: 13) + [64, 0x11, 64] + padded(Array("square".utf8), to: 26) + [1, 0]
    header += long(32) + long(0) + long(32) + long(8363) + long(0) + long(0) + long(sound) + [0, 0, 0, 0]
    for _ in 0 ..< before { file += padded(Array("IMPS".utf8), to: 0x50) }
    file += header
    if emptySample {
        var empty = Array("IMPS".utf8) + [UInt8](repeating: 0, count: 13) + [64, 0x01, 64] + [UInt8](repeating: 0, count: 26) + [1, 0]
        empty += long(0) + long(0) + long(0) + long(8363) + long(0) + long(0) + long(sound + 32) + [0, 0, 0, 0]
        file += empty
    }
    file += word(rows.count) + word(64) + long(0) + rows
    // Signed, as Impulse Tracker has them: the top of the range, then the bottom.
    file += (0 ..< 32).map { $0 < 16 ? 0x7F : 0x81 }
    return file
}

private func stereo(_ renderer: any Renderer, seconds: Double) -> (left: [Float], right: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

private func crossings(_ samples: ArraySlice<Float>) -> Int {
    zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
}

private func loudness(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

@Test func itNoteSoundsAtItsPitch() throws {
    // C-5 plays a sample at the rate it gives, 8363 samples a second, and the square wave is 32 of
    // them: 261 Hz.
    let renderer = try TuneLoader.load(it(), format: .it)
    #expect(renderer.info.format == "IT")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "Impulse Tracker 2.14")
    let sound = stereo(renderer, seconds: 1).left
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 261) <= 2)
    #expect(sound[4800...].map(abs).max()! > 0.02)
    // An octave up is twice that.
    let higher = stereo(try TuneLoader.load(it(row: [0x81, 0x03, 72, 1]), format: .it), seconds: 1).left
    #expect(abs(crossings(higher[4800...]) * 10 / 9 - 523) <= 3)
}

@Test func itChannelIsHeardWhereItIsPlaced() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let left = stereo(try TuneLoader.load(it(pan: 0), format: .it, options: options), seconds: 0.5)
    #expect(left.left[4800...].map(abs).max()! > 0.02)
    #expect(left.right[4800...].map(abs).max()! < left.left[4800...].map(abs).max()! * 0.05)
    let right = stereo(try TuneLoader.load(it(pan: 64), format: .it, options: options), seconds: 0.5)
    #expect(right.left[4800...].map(abs).max()! < right.right[4800...].map(abs).max()! * 0.05)
    // In mono both sides are the same.
    let mono = stereo(try TuneLoader.load(it(pan: 0), format: .it), seconds: 0.5)
    #expect(mono.left == mono.right)
    #expect(mono.left[4800...].map(abs).max()! > 0.01)
}

@Test func itKnowsHowLongItIsAndHowManySongsItHas() throws {
    // 64 rows of 6 ticks at fifty ticks a second.
    let plain = try TuneLoader.load(it(), format: .it)
    #expect(abs(plain.knownLength! - 7.68) < 0.01)
    #expect(plain.endsByLooping)
    #expect(plain.subsongCount == 1)
    // A break on the first row: one row, and it counts each time round.
    let short = try TuneLoader.load(it(row: [0x81, 0x0B, 60, 1, 3, 0]), format: .it)
    #expect(abs(short.knownLength! - 0.12) < 0.01)
    _ = stereo(short, seconds: 0.5)
    #expect(short.loopCount == 4)
    // The pattern again after the end of the list, where nothing leads to it, is a second song.
    let two = try TuneLoader.load(it(orders: [0, 255, 0, 255]), format: .it)
    #expect(two.subsongCount == 2)
    two.select(subsong: 1)
    #expect(abs(two.knownLength! - 7.68) < 0.01)
    #expect(stereo(two, seconds: 0.5).left[4800...].map(abs).max()! > 0.02)
}

@Test func itFilterTakesTheEdgeOffASquareWave() throws {
    // Z08 on the note's row closes the filter to some 160 Hz, below the note: its harmonics go
    // and the note itself is a good deal quieter, though still there and still at its pitch.
    let open = stereo(try TuneLoader.load(it(), format: .it), seconds: 1).left
    let closed = stereo(try TuneLoader.load(it(row: [0x81, 0x0B, 60, 1, 26, 0x08]), format: .it), seconds: 1).left
    #expect(abs(crossings(closed[9600...]) * 10 / 8 - 261) <= 3)
    #expect(loudness(closed[9600...]) < loudness(open[9600...]) * 0.7)
    #expect(loudness(closed[9600...]) > loudness(open[9600...]) * 0.05)
}

@Test func itFilesThatAreOddOrNotITAtAll() throws {
    // ModPlug Tracker's empty sample, said to lie at the end of the file, is no reason not to play.
    let renderer = try TuneLoader.load(it(emptySample: true), format: .it)
    #expect(stereo(renderer, seconds: 0.5).left[4800...].map(abs).max()! > 0.02)
    // Cut short in its sample, it plays what it has.
    #expect((try? TuneLoader.load(Array(it().dropLast(20)), format: .it)) != nil)
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x41, count: 4000), format: .it) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(it().prefix(0x60)), format: .it) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("ziRCONia".utf8) + [UInt8](repeating: 0, count: 400), format: .it) }
}

@Test func itFileWithMoreSamplesThanImpulseTrackerHadRoomForIsPlayed() throws {
    // Impulse Tracker holds a hundred samples, and uses the number after them to mean a note sent
    // out by MIDI. Later trackers wrote files with more: here the hundred-and-first is the one
    // that is played, and then the two-hundredth.
    for before in [100, 199] {
        let renderer = try TuneLoader.load(it(before: before), format: .it)
        let sound = stereo(renderer, seconds: 1).left
        #expect(abs(crossings(sound[4800...]) * 10 / 9 - 261) <= 2)
        #expect(sound[4800...].map(abs).max()! > 0.02)
    }
    // More than a byte can number is more than an IT file can have.
    #expect(throws: TuneError.self) { try TuneLoader.load(it(before: 253), format: .it) }
}
