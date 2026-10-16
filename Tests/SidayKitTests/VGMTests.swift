// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// VGM files for the FM chips. The thorough check is made outside the package: `siday --raw out.raw
// tune.vgz` writes the chips' own samples, which agree to the sample with the original Nuked OPL3's
// for the same writes at the same moments.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }

/// Text as GD3 tags have it: UTF-16, each piece ended by a nought.
private func tags(_ pieces: [String]) -> [UInt8] {
    var text: [UInt8] = []
    for piece in pieces { text += piece.utf16.flatMap { word(Int($0)) } + [0, 0] }
    return Array("Gd3 ".utf8) + long(0x100) + long(text.count) + text
}

/// The writes that start a plain sine on an OPL2's first channel, at 440 Hz, and hold it (the first
/// operator silent, the second at full level, both holding).
private func note(_ command: UInt8 = 0x5A, key: Bool = true) -> [UInt8] {
    let writes: [(Int, UInt8)] = [(0x20, 0x21), (0x23, 0x21), (0x40, 0x3F), (0x43, 0x00), (0x60, 0xF0), (0x63, 0xF0),
                                  (0x80, 0x0F), (0x83, 0x0F), (0xC0, 0x00), (0xA0, 0x44), (0xB0, key ? 0x32 : 0x12)]
    return writes.flatMap { [command, UInt8($0.0), $0.1] }
}

/// A VGM file of version 1.71 for one OPL2 (or as `clock` says), its writes `commands`, so long in
/// 44,100ths of a second, going round from `loop` (a place in `commands`) if given.
private func vgm(_ commands: [UInt8], ticks: Int, loop: Int? = nil, clockAt: Int = 0x50, clock: Int = 3_579_545,
                 volume: UInt8 = 0, extra: [UInt8] = [], tags gd3: [UInt8] = []) -> [UInt8] {
    let start = 0x100 + extra.count
    var header = [UInt8](repeating: 0, count: 0x100)
    func put(_ at: Int, _ bytes: [UInt8]) { header.replaceSubrange(at ..< at + bytes.count, with: bytes) }
    put(0, Array("Vgm ".utf8))
    put(0x08, long(0x171))
    put(0x18, long(ticks))
    if let loop { put(0x1C, long(start + loop - 0x1C)) }
    put(0x20, long(loop == nil ? 0 : ticks))
    put(0x34, long(start - 0x34))
    put(clockAt, long(clock))
    put(0x7C, [volume])
    if !extra.isEmpty { put(0xBC, long(0x100 - 0xBC)) }
    var file = header + extra + commands + [0x66]
    if !gd3.isEmpty {
        put(0x14, long(file.count - 0x14))
        file = header + extra + commands + [0x66] + gd3
    }
    file.replaceSubrange(4 ..< 8, with: long(file.count - 4))
    return file
}

/// A second of a sine, then the end.
private let oneNote = note() + [0x61] + word(44100)

private func stereo(_ renderer: any Renderer, seconds: Double) -> [Float] {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return buffer
}

private func side(_ samples: [Float], _ which: Int) -> ArraySlice<Float> {
    ArraySlice(stride(from: which, to: samples.count, by: 2).map { samples[$0] })
}

private func crossings(_ samples: ArraySlice<Float>) -> Int {
    zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
}

private func loudness(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
}

private var stereoOptions: LoadOptions {
    var options = LoadOptions()
    options.stereo = .abc
    return options
}

@Test func vgmNoteSoundsAtItsPitchForItsLength() throws {
    let file = vgm(oneNote, ticks: 44100, tags: tags(["A Tune", "", "A Game", "", "IBM PC", "", "Someone", "", "1991"]))
    let renderer = try TuneLoader.load(file, format: .vgm, options: stereoOptions)
    #expect(renderer.info.format == "VGM")
    #expect(renderer.info.title == "A Tune")
    #expect(renderer.info.author == "Someone")
    #expect(renderer.info.comment == "A Game, 1991")
    #expect(renderer.info.detail == "YM3812 (OPL2), IBM PC")
    #expect(renderer.channelCount == 9)
    // A second of music and a second for it to die away.
    #expect(abs(renderer.knownLength! - 2) < 0.01)
    #expect(!renderer.endsByLooping)
    // 0x244 in the fourth octave is 440 Hz.
    let sound = stereo(renderer, seconds: 1)
    #expect(abs(crossings(side(sound, 0)[4800...]) * 10 / 9 - 440) <= 2)
    #expect(loudness(side(sound, 0)[4800...]) > 0.01)
    // Both sides alike: an OPL2 has no sides.
    #expect(abs(loudness(side(sound, 0)) - loudness(side(sound, 1))) < loudness(side(sound, 0)) * 0.01)
    // And it ends.
    _ = stereo(renderer, seconds: 1.5)
    #expect(renderer.hasEnded)
}

@Test func vgzIsAVGMFilePackedByGzip() throws {
    let plain = vgm(oneNote, ticks: 44100)
    #expect(TuneFormat(fileExtension: "VGZ") == .vgm)
    // gzip of the file, in stored blocks of DEFLATE: what it is, in pieces of up to 65,535 bytes.
    var packed: [UInt8] = [0x1F, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 3] + Array("tune.vgm".utf8) + [0]
    var at = 0
    repeat {
        let count = min(65535, plain.count - at)
        packed += [at + count == plain.count ? 1 : 0] + word(count) + word(count ^ 0xFFFF) + plain[at ..< at + count]
        at += count
    } while at < plain.count
    packed += long(Int(Inflate.crc32(plain, from: 0, to: plain.count))) + long(plain.count)
    let renderer = try TuneLoader.load(packed, format: .vgm, options: stereoOptions)
    let unpacked = try TuneLoader.load(plain, format: .vgm, options: stereoOptions)
    #expect(stereo(renderer, seconds: 0.5) == stereo(unpacked, seconds: 0.5))
    // A damaged one is refused.
    var damaged = packed
    damaged[damaged.count - 9] ^= 1
    #expect(throws: TuneError.self) { try TuneLoader.load(damaged, format: .vgm) }
}

@Test func vgmThatGoesRoundIsPlayedRoundAndCounted() throws {
    // The note held, and round again from the wait after its start.
    let renderer = try TuneLoader.load(vgm(note() + [0x61] + word(22050), ticks: 22050, loop: note().count), format: .vgm)
    #expect(renderer.endsByLooping)
    #expect(abs(renderer.knownLength! - 0.5) < 0.01)
    _ = stereo(renderer, seconds: 1.6)
    #expect(renderer.loopCount == 3)
    #expect(!renderer.hasEnded)
}

@Test func vgmForAnotherChipIsRefusedByItsName() {
    do {
        _ = try TuneLoader.load(vgm([0x61] + word(100), ticks: 100, clockAt: 0x2C, clock: 7_670_453), format: .vgm)
        Issue.record("a file for the YM2612 was played")
    } catch {
        #expect("\(error)".contains("the YM2612 (a Sega Mega Drive's), which is not played"))
    }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(vgm(oneNote, ticks: 44100).prefix(0x30)), format: .vgm) }
}

@Test func vgmOfAnOPL3HasItsSidesAndItsSecondSet() throws {
    // The note on the second set's first channel, heard on the right only (C0: bit 5).
    let writes = [0x5F, 0x05, 0x01] + note(0x5F).map { $0 } + [0x5F, 0xC0, 0x20] + [0x61] + word(44100)
    let renderer = try TuneLoader.load(vgm(writes, ticks: 44100, clockAt: 0x5C, clock: 14_318_180), format: .vgm, options: stereoOptions)
    #expect(renderer.channelCount == 18)
    let sound = stereo(renderer, seconds: 0.5)
    #expect(loudness(side(sound, 1)[4800...]) > 0.01)
    #expect(loudness(side(sound, 0)[4800...]) < 0.0001)
}

@Test func vgmOfASoundBlasterProHasAChipOnEachSide() throws {
    // Two OPL2s, the first playing and the second not: with the file's word that they are a pair
    // heard apart, the first is on the left alone; without it, each is in the middle, at half.
    let writes = note() + note(0xAA, key: false) + [0x61] + word(44100)
    let apart = try TuneLoader.load(vgm(writes, ticks: 44100, clock: 3_579_545 | 0xC000_0000), format: .vgm, options: stereoOptions)
    let together = try TuneLoader.load(vgm(writes, ticks: 44100, clock: 3_579_545 | 0x4000_0000), format: .vgm, options: stereoOptions)
    let one = try TuneLoader.load(vgm(writes, ticks: 44100), format: .vgm, options: stereoOptions)
    #expect(apart.channelCount == 18)
    #expect(apart.info.detail == "2 × YM3812 (OPL2), left and right")
    #expect(together.info.detail == "2 × YM3812 (OPL2)")
    let a = stereo(apart, seconds: 0.5), t = stereo(together, seconds: 0.5), o = stereo(one, seconds: 0.5)
    #expect(loudness(side(a, 1)[4800...]) < 0.0001)
    #expect(abs(loudness(side(a, 0)[4800...]) / loudness(side(o, 0)[4800...]) - 1) < 0.01)
    #expect(abs(loudness(side(t, 0)[4800...]) / loudness(side(o, 0)[4800...]) - 0.5) < 0.01)
}

@Test func vgmIsAsLoudAsItsFileAsks() throws {
    let plain = stereo(try TuneLoader.load(vgm(oneNote, ticks: 44100), format: .vgm), seconds: 0.5)
    // A volume of 32 is twice as loud; and the extra header can make one chip louder again.
    let louder = stereo(try TuneLoader.load(vgm(oneNote, ticks: 44100, volume: 32), format: .vgm), seconds: 0.5)
    #expect(abs(loudness(side(louder, 0)) / loudness(side(plain, 0)) - 2) < 0.01)
    let extra = long(12) + long(0) + long(4) + [1, 0x09, 0x00] + word(0x8180)
    let more = stereo(try TuneLoader.load(vgm(oneNote, ticks: 44100, extra: extra), format: .vgm), seconds: 0.5)
    #expect(abs(loudness(side(more, 0)) / loudness(side(plain, 0)) - 1.5) < 0.01)
}
