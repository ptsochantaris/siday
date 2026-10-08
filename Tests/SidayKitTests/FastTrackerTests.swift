// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of the FastTracker path. The thorough check is made outside the package, against the
// player it is ported from (ft2play): `siday --raw out.raw tune.xm` writes the tune as that player
// would write it to a file, and the two are to agree to the sample.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ text: String, _ length: Int) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: length - text.utf8.count) }

/// An XM file of one pattern and one instrument: a square wave of 32 samples, looping.
/// - Parameters:
///   - notes: the packed bytes of the pattern's first row, a note for each channel.
///   - pan: where the sample sits, from 0 (left) to 255 (right).
///   - pattern: the whole pattern in place of that: how many rows, and its packed bytes.
///   - settings: bytes of the instrument's header to set, by their place in it.
private func xm(channels: Int = 2, notes: [UInt8]? = nil, pan: UInt8 = 128, tempo: Int = 6, pattern: (rows: Int, data: [UInt8])? = nil,
                settings: [Int: UInt8] = [:]) -> [UInt8]
{
    var file = Array("Extended Module: ".utf8) + padded("a square wave", 20) + [0x1A] + padded("siday", 20) + word(0x0104)
    file += long(276) + word(1) + word(0) + word(channels) + word(1) + word(1) + word(1) + word(tempo) + word(125)
    file += [UInt8](repeating: 0, count: 256)

    // The pattern: C-4 on instrument 1 in the first channel of the first row, and nothing else.
    var rows = notes ?? ([0x83, 49, 1] + [UInt8](repeating: 0x80, count: channels - 1))
    rows += [UInt8](repeating: 0x80, count: 63 * channels)
    file += long(9) + [0] + word(pattern?.rows ?? 64) + word((pattern?.data ?? rows).count) + (pattern?.data ?? rows)

    var instrument = long(263) + padded("square", 22) + [0] + word(1) + long(40)
    instrument += [UInt8](repeating: 0, count: 263 - instrument.count)
    for (place, value) in settings { instrument[place] = value }
    file += instrument
    file += long(32) + long(0) + long(32) + [64, 0, 1, pan, 0, 0] + padded("square", 22)
    // The sample, as the differences from one value to the next: up to 127, and later down to -128.
    var sample = [UInt8](repeating: 0, count: 32)
    sample[0] = 127
    sample[16] = 1
    return file + sample
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

@Test func xmNoteSoundsAtItsPitchWhereItIsPlaced() throws {
    // C-4 plays a sample at 8363 samples a second, and the square wave is 32 of them: 261 Hz.
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try TuneLoader.load(xm(pan: 0), format: .xm, options: options)
    #expect(renderer.info.format == "XM")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "FastTracker 2, 2 channels")

    let sound = stereo(renderer, seconds: 1)
    #expect(abs(crossings(sound.left[4800...]) * 10 / 9 - 261) <= 2)
    #expect(sound.left[4800...].map(abs).max()! > 0.05)
    // Placed hard left, there is none of it on the right.
    #expect(sound.right.map(abs).max()! < 0.0001)

    // In the middle it is the same on both sides, and in mono too wherever it is placed.
    let middle = stereo(try TuneLoader.load(xm(), format: .xm, options: options), seconds: 0.5)
    #expect(middle.left == middle.right)
    let mono = stereo(try TuneLoader.load(xm(pan: 0), format: .xm), seconds: 0.5)
    #expect(mono.left == mono.right)
    #expect(mono.left[4800...].map(abs).max()! > 0.02)
}

@Test func xmKnowsHowLongItIs() throws {
    // 64 rows of 6 ticks, and a tick at 125 beats a minute is 960 samples: 7.68 seconds.
    let plain = try TuneLoader.load(xm(), format: .xm)
    #expect(abs(plain.knownLength! - 7.68) < 0.001)
    #expect(plain.endsByLooping)
    #expect(abs(try TuneLoader.load(xm(tempo: 3), format: .xm).knownLength! - 3.84) < 0.001)

    // A jump back to the first order on the first row: one row, and it counts each time round.
    let short = try TuneLoader.load(xm(notes: [0x9B, 49, 1, 0x0B, 0, 0x80]), format: .xm)
    #expect(abs(short.knownLength! - 0.12) < 0.001)
    #expect(short.loopCount == 0)
    _ = stereo(short, seconds: 0.5)
    #expect(short.loopCount == 4)
    #expect(!short.hasEnded)

    // A speed of nothing stops the song.
    let stopping = try TuneLoader.load(xm(notes: [0x9B, 49, 1, 0x0F, 0, 0x80]), format: .xm)
    _ = stereo(stopping, seconds: 0.2)
    #expect(stopping.hasEnded)
}

@Test func xmOfAnyNumberOfChannelsIsPlayed() throws {
    // FastTracker reads an even number up to 32; other trackers write what they like.
    #expect(try TuneLoader.load(xm(channels: 3), format: .xm).info.detail == "FastTracker 2, 3 channels")
    #expect(try TuneLoader.load(xm(channels: 64), format: .xm).knownLength != nil)
    #expect(throws: TuneError.self) { try TuneLoader.load(xm(channels: 200), format: .xm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(xm().prefix(300)), format: .xm) }
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x41, count: 4000), format: .xm) }
}

@Test func modOfMoreThanFourChannelsGoesToFastTracker() throws {
    // A MOD file of six channels: a PC tracker's, with one sample and one note.
    var file = padded("six channels", 20)
    for sample in 0 ..< 31 {
        var header = [UInt8](repeating: 0, count: 30)
        if sample == 0 {
            header[22 ... 23] = [0, 16]
            header[25] = 64
            header[26 ... 29] = [0, 0, 0, 16]
        } else {
            header[29] = 1
        }
        file += header
    }
    file += [1, 0] + [UInt8](repeating: 0, count: 128) + Array("6CHN".utf8)
    var pattern = [UInt8](repeating: 0, count: 64 * 6 * 4)
    pattern.replaceSubrange(0 ..< 4, with: [0x01, 0xAC, 0x10, 0x00]) // period 428, sample 1
    file += pattern + [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16)

    let renderer = try TuneLoader.load(file, format: .mod)
    #expect(renderer.info.format == "MOD")
    #expect(renderer.info.title == "six channels")
    #expect(renderer.info.detail == "FastTracker 2, 6 channels")
    #expect(abs(renderer.knownLength! - 7.68) < 0.001)
    let sound = stereo(renderer, seconds: 1)
    // Period 428 is the same C: 8287 bytes a second here, 32 to the wave, 259 Hz.
    #expect(abs(crossings(sound.left[4800...]) * 10 / 9 - 259) <= 2)
}

@Test func xmPatternIsUnpackedWhereItLiesAsFastTrackerDoes() throws {
    // One row of two channels: nothing in the first, and in the second a note written out in full
    // behind a byte that says all of it follows, which is six bytes for a note of five. FastTracker
    // unpacks a pattern in the memory it was read into, and here the first note, unpacked, lands on
    // top of the second before that has been read: so there is no second note, and the row is silent.
    var options = LoadOptions()
    options.stereo = .abc
    let overrun = try TuneLoader.load(xm(pattern: (1, [0x80, 0x9F, 49, 1, 0, 0, 0])), format: .xm, options: options)
    #expect(stereo(overrun, seconds: 0.5).left.map(abs).max()! < 0.0001)
    // The same note packed down to the three bytes it needs is left alone, and sounds.
    let packed = try TuneLoader.load(xm(pattern: (1, [0x80, 0x83, 49, 1])), format: .xm, options: options)
    #expect(stereo(packed, seconds: 0.5).left.map(abs).max()! > 0.05)
}

@Test func xmEnvelopeThatLoopsToAPointItHasNotGotIsPlayed() throws {
    // A volume envelope of two points that loops back to its twenty-first. FastTracker reads whatever
    // is in its memory there, which is the instrument's other settings; the tune must play all the same.
    let settings: [Int: UInt8] = [233: 1 | 4, 225: 2, 228: 20, 229: 0, 129 + 2: 64, 129 + 4: 1, 129 + 6: 32]
    let renderer = try TuneLoader.load(xm(settings: settings), format: .xm)
    let sound = stereo(renderer, seconds: 2)
    #expect(sound.left.allSatisfy { $0.isFinite })
    #expect(renderer.knownLength != nil)
    // And an envelope that says it has more points than there is room for.
    _ = stereo(try TuneLoader.load(xm(settings: [233: 1, 225: 200]), format: .xm), seconds: 1)
    _ = stereo(try TuneLoader.load(xm(notes: [0x9B, 49, 1, 21, 200, 0x80], settings: [233: 3, 225: 255]), format: .xm), seconds: 1)
}
