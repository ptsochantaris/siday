// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
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
                 volume: UInt8 = 0, extra: [UInt8] = [], tags gd3: [UInt8] = [], more: [(Int, [UInt8])] = []) -> [UInt8] {
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
    for (at, bytes) in more { put(at, bytes) }
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

/// The same, with a Sound Blaster Pro's sides as far apart as the card had them.
private var cardOptions: LoadOptions {
    var options = stereoOptions
    options.sbProSeparation = 1
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
        _ = try TuneLoader.load(vgm([0x61] + word(100), ticks: 100, clockAt: 0x30, clock: 3_579_545), format: .vgm)
        Issue.record("a file for the YM2151 was played")
    } catch {
        #expect("\(error)".contains("the YM2151 (OPM), which is not played"))
    }
    // A YM2612's FM voices are refused, once one is started; its DAC is played.
    do {
        _ = try TuneLoader.load(vgm([0x52, 0x28, 0xF0, 0x61] + word(100), ticks: 100, clockAt: 0x2C, clock: 7_670_453), format: .vgm)
        Issue.record("a file for the YM2612's FM was played")
    } catch {
        #expect("\(error)".contains("the YM2612's FM voices"))
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
    let apart = try TuneLoader.load(vgm(writes, ticks: 44100, clock: 3_579_545 | 0xC000_0000), format: .vgm, options: cardOptions)
    let together = try TuneLoader.load(vgm(writes, ticks: 44100, clock: 3_579_545 | 0x4000_0000), format: .vgm, options: stereoOptions)
    let one = try TuneLoader.load(vgm(writes, ticks: 44100), format: .vgm, options: stereoOptions)
    #expect(apart.channelCount == 18)
    #expect(apart.info.detail == "2 × YM3812 (OPL2), left and right")
    #expect(together.info.detail == "2 × YM3812 (OPL2)")
    let a = stereo(apart, seconds: 0.5), t = stereo(together, seconds: 0.5), o = stereo(one, seconds: 0.5)
    #expect(loudness(side(a, 1)[4800...]) < 0.0001)
    #expect(abs(loudness(side(a, 0)[4800...]) / loudness(side(o, 0)[4800...]) - 1) < 0.01)
    #expect(abs(loudness(side(t, 0)[4800...]) / loudness(side(o, 0)[4800...]) - 0.5) < 0.01)
    // Brought most of the way together, as they are unless the listener asks otherwise: a fifth of
    // the difference between the sides is kept, so the first chip is heard at 0.6 on the left and
    // 0.4 on the right (and all together would be 0.5 on each, as two chips in the middle are). The
    // chips are still said to be on the card's sides.
    let near = try TuneLoader.load(vgm(writes, ticks: 44100, clock: 3_579_545 | 0xC000_0000), format: .vgm, options: stereoOptions)
    let n = stereo(near, seconds: 0.5)
    #expect(abs(loudness(side(n, 0)[4800...]) / loudness(side(o, 0)[4800...]) - 0.6) < 0.01)
    #expect(abs(loudness(side(n, 1)[4800...]) / loudness(side(o, 0)[4800...]) - 0.4) < 0.01)
    var sides = [Float](repeating: 0, count: 18)
    near.takeChannelSides(into: &sides)
    #expect(sides[0] == -1 && sides[9] == 1)
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

/// The writes that start a tone on an AY-3-8910's first channel, of the given period, at full volume.
private func ayNote(period: Int, second: Bool = false) -> [UInt8] {
    let writes: [(UInt8, UInt8)] = [(0, UInt8(period & 0xFF)), (1, UInt8(period >> 8)), (7, 0x3E), (8, 15)]
    return writes.flatMap { [0xA0, $0.0 | (second ? 0x80 : 0), $0.1] }
}

private let ayClock = 1_789_773

@Test func vgmOfAnAYChipPlaysItsToneFromTheMiddle() throws {
    // 1,789,773 Hz over 16 times 254 is 440 Hz.
    let file = vgm(ayNote(period: 254) + [0x61] + word(44100), ticks: 44100, clockAt: 0x74, clock: ayClock)
    let renderer = try TuneLoader.load(file, format: .vgm, options: stereoOptions)
    #expect(renderer.channelCount == 3)
    #expect(renderer.info.detail == "AY-3-8910")
    let sound = stereo(renderer, seconds: 1)
    #expect(abs(crossings(side(sound, 0)[4800...]) * 10 / 9 - 440) <= 2)
    #expect(loudness(side(sound, 0)[4800...]) > 0.01)
    // Its first channel is not on the left, as a ZX Spectrum's would be: there are no sides.
    #expect(side(sound, 0) == side(sound, 1))
    var sides = [Float](repeating: 1, count: 3)
    renderer.takeChannelSides(into: &sides)
    #expect(sides == [0, 0, 0])
}

@Test func vgmOfAnAYChipHeardAsASpectrumsHasItsSides() throws {
    let file = vgm(ayNote(period: 254) + [0x61] + word(44100), ticks: 44100, clockAt: 0x74, clock: ayClock, more: [(0x79, [0x80])])
    let sound = stereo(try TuneLoader.load(file, format: .vgm, options: stereoOptions), seconds: 0.5)
    #expect(loudness(side(sound, 0)[4800...]) > loudness(side(sound, 1)[4800...]) * 10)
}

@Test func vgmOfAYM2149WiredToHalveItsClockIsAnOctaveLower() throws {
    let writes = ayNote(period: 127) + [0x61] + word(44100)
    let halved = vgm(writes, ticks: 44100, clockAt: 0x74, clock: ayClock, more: [(0x78, [0x10, 0x10])])
    let renderer = try TuneLoader.load(halved, format: .vgm, options: stereoOptions)
    #expect(renderer.info.detail == "YM2149")
    #expect(abs(crossings(side(stereo(renderer, seconds: 1), 0)[4800...]) * 10 / 9 - 440) <= 2)
    // The halving is the YM2149's: an AY-3-8910 has no such pin.
    let plain = vgm(writes, ticks: 44100, clockAt: 0x74, clock: ayClock, more: [(0x79, [0x10])])
    #expect(abs(crossings(side(stereo(try TuneLoader.load(plain, format: .vgm), seconds: 1), 0)[4800...]) * 10 / 9 - 880) <= 3)
}

@Test func vgmOfAnFMChipAndAnAYChipPlaysBoth() throws {
    let writes = note() + ayNote(period: 127) + [0x61] + word(44100)
    let file = vgm(writes, ticks: 44100, more: [(0x74, long(ayClock))])
    let renderer = try TuneLoader.load(file, format: .vgm, options: stereoOptions)
    #expect(renderer.channelCount == 12)
    #expect(renderer.info.detail == "YM3812 (OPL2) and AY-3-8910")
    _ = stereo(renderer, seconds: 0.5)
    var levels = [Float](repeating: 0, count: 12)
    renderer.takeChannelLevels(into: &levels)
    #expect(levels[0] > 0.1)
    #expect(levels[9] > 0.1)
    // Each is what it would be alone, added together.
    let fm = stereo(try TuneLoader.load(vgm(note() + [0x61] + word(44100), ticks: 44100, more: [(0x74, long(ayClock))]), format: .vgm), seconds: 0.5)
    let ay = stereo(try TuneLoader.load(vgm(ayNote(period: 127) + [0x61] + word(44100), ticks: 44100, more: [(0x74, long(ayClock))]), format: .vgm), seconds: 0.5)
    let both = stereo(try TuneLoader.load(file, format: .vgm), seconds: 0.5)
    #expect(zip(both, zip(fm, ay)).allSatisfy { abs($0 - ($1.0 + $1.1)) < 1e-6 })
    // And the AY's chip alone, not the FM chip's, is refused if it is one that is not played.
    #expect(throws: TuneError.self) { try TuneLoader.load(vgm(writes, ticks: 44100, more: [(0x74, long(ayClock)), (0x78, [0x03])]), format: .vgm) }
}

@Test func vgmOfASoundBlasterProKeepsItsSecondChipInTimeWithItsWrites() throws {
    // Notes that change every few ticks for two seconds, on the second chip only: what is heard on
    // the right is what one chip makes of the same writes, to the sample. (The second chip once
    // lost a sample of its own now and then, and so came to its writes a little early.)
    var writes: [UInt8] = []
    for step in 0 ..< 600 {
        writes += note(0xAA) + [0xAA, 0xA0, UInt8(0x44 + step % 7 * 9)] + [0x61] + word(97 + step % 13)
    }
    let pair = vgm(writes, ticks: 0, clock: 3_579_545 | 0xC000_0000)
    let alone = vgm(writes.enumerated().map { $0.offset % 3 == 0 && $0.element == 0xAA ? 0x5A : $0.element }, ticks: 0)
    let right = side(stereo(try TuneLoader.load(pair, format: .vgm, options: cardOptions), seconds: 2), 1)
    let one = side(stereo(try TuneLoader.load(alone, format: .vgm, options: stereoOptions), seconds: 2), 1)
    #expect(right == one)
}

/// A block of data for the first bank: a square wave, ten bytes high and ten low, `periods` times over.
private func squareBlock(periods: Int) -> [UInt8] {
    let wave = (0 ..< periods).flatMap { _ in [UInt8](repeating: 0xC0, count: 10) + [UInt8](repeating: 0x40, count: 10) }
    return [0x67, 0x66, 0x00] + long(wave.count) + wave
}

/// The DAC switched on, and stream 0 set to write the first bank's bytes to it, 8,000 a second.
private let dacStream: [UInt8] = [0x52, 0x2B, 0x80, 0x90, 0, 0x02, 0x00, 0x2A, 0x91, 0, 0x00, 1, 0, 0x92, 0] + long(8000)

@Test func vgmStreamPlaysItsSampleOnTheDACAtItsRate() throws {
    // Twenty bytes a period at 8,000 a second is 400 Hz; 200 periods is half a second.
    let writes = squareBlock(periods: 200) + dacStream + [0x95, 0] + word(0) + [0] + [0x61] + word(44100)
    let renderer = try TuneLoader.load(vgm(writes, ticks: 44100, clockAt: 0x2C, clock: 7_670_453), format: .vgm, options: stereoOptions)
    #expect(renderer.channelCount == 1)
    #expect(renderer.info.detail == "DAC (as a YM2612's)")
    var sampled = [false]
    renderer.takeChannelsSampled(into: &sampled)
    #expect(sampled == [true])
    let sound = stereo(renderer, seconds: 1)
    let playing = side(sound, 0)[2400 ..< 21600], after = side(sound, 0)[26400...]
    #expect(abs(crossings(playing) * 10 / 4 - 400) <= 3)
    #expect(loudness(playing) > 0.01)
    // And it stops: what the DAC is left at is not heard.
    #expect(crossings(after) == 0)
    #expect(abs(after.last!) < 0.001)
}

@Test func vgmStreamGoesRoundAndBackwardsAsItIsTold() throws {
    // Round again: still playing after the half second its bytes last.
    let round = squareBlock(periods: 200) + dacStream + [0x95, 0] + word(0) + [0x01] + [0x61] + word(44100)
    let sound = stereo(try TuneLoader.load(vgm(round, ticks: 44100, clockAt: 0x2C, clock: 7_670_453), format: .vgm), seconds: 1)
    #expect(loudness(side(sound, 0)[26400 ..< 45600]) > 0.01)
    // By count (20 writes of a block that begins with ten high bytes and then ten low): backwards
    // from the twentieth, it begins low; forwards, high.
    func first(_ mode: UInt8) throws -> Float {
        let writes = squareBlock(periods: 2) + dacStream + [0x93, 0] + long(0) + [mode] + long(20) + [0x61] + word(4410)
        let sound = stereo(try TuneLoader.load(vgm(writes, ticks: 4410, clockAt: 0x2C, clock: 7_670_453), format: .vgm), seconds: 0.1)
        return side(sound, 0)[48 ..< 48 + 40].reduce(0, +)
    }
    #expect(try first(0x01) > 0)
    #expect(try first(0x11) < 0)
}

@Test func vgmWritesToTheDACFromItsFirstBankAndWaits() throws {
    // 0x8n: the next of the first bank's bytes, and a wait of n. Five a period at 44,100 a second
    // of 0x8n with n = 11 (and so 4,009 a second): 20 bytes a period is 200 Hz.
    var writes = squareBlock(periods: 100) + [0x52, 0x2B, 0x80, 0xE0] + long(0)
    writes += [UInt8](repeating: 0x8B, count: 2000)
    let renderer = try TuneLoader.load(vgm(writes, ticks: 22000, clockAt: 0x2C, clock: 7_670_453), format: .vgm)
    let sound = side(stereo(renderer, seconds: 0.5), 0)
    #expect(abs(Double(crossings(sound[2400 ..< 21600])) / 0.4 - 4009.0 / 20) <= 3)
    // The DAC is silent until it is switched on.
    let off = squareBlock(periods: 200) + Array(dacStream.dropFirst(3)) + [0x95, 0] + word(0) + [0] + [0x61] + word(44100)
    let silent = stereo(try TuneLoader.load(vgm(off, ticks: 44100, clockAt: 0x2C, clock: 7_670_453), format: .vgm), seconds: 0.5)
    #expect(loudness(side(silent, 0)) == 0)
}

/// A VGM file for an SN76489 like the Tandy 1000's (as the files for it have it: its noise's taps
/// 0x22, sixteen bits long, and not the Sega chip's), or the Game Gear's.
private func snFile(_ commands: [UInt8], ticks: Int, gameGear: Bool = false) -> [UInt8] {
    let variant: [(Int, [UInt8])] = gameGear ? [(0x28, word(0x09)), (0x2A, [16, 0x00])] : [(0x28, word(0x22)), (0x2A, [16, 0x05])]
    return vgm(commands, ticks: ticks, clockAt: 0x0C, clock: 3_579_545, more: variant)
}

/// The writes that set an SN76489 channel's period and volume (0 the loudest, 15 silence).
private func snTone(_ channel: UInt8, period: Int, volume: UInt8) -> [UInt8] {
    [0x50, 0x80 | channel << 5 | UInt8(period & 0x0F), 0x50, UInt8(period >> 4 & 0x3F), 0x50, 0x90 | channel << 5 | volume]
}

@Test func vgmOfAnSN76489PlaysItsToneAtItsPitchAndItsVolumes() throws {
    // 3,579,545 Hz over 32 times 254 is 440 Hz.
    let renderer = try TuneLoader.load(snFile(snTone(0, period: 254, volume: 0) + [0x61] + word(44100), ticks: 44100), format: .vgm, options: stereoOptions)
    #expect(renderer.channelCount == 4)
    #expect(renderer.info.detail == "SN76489")
    let sound = side(stereo(renderer, seconds: 1), 0)
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 440) <= 2)
    // Each of its volumes is 2 dB under the one before.
    let quieter = side(stereo(try TuneLoader.load(snFile(snTone(0, period: 254, volume: 3) + [0x61] + word(44100), ticks: 44100), format: .vgm), seconds: 1), 0)
    #expect(abs(20 * log10(Double(loudness(sound[4800...]) / loudness(quieter[4800...]))) - 6) < 0.1)
    // A period of nought is 1,024 on this chip: 109 Hz.
    let lowest = side(stereo(try TuneLoader.load(snFile(snTone(0, period: 0, volume: 0) + [0x61] + word(44100), ticks: 44100), format: .vgm), seconds: 1), 0)
    #expect(abs(crossings(lowest[4800...]) * 10 / 9 - 109) <= 2)
}

@Test func vgmOfAnSN76489PlaysSamplesOnAChannelsVolumeFromAPackedBlock() throws {
    // A channel held at a period of one plays what is written to its volume: a stream of them, from
    // a block of four bits to each, packed two to a byte, the higher first. Volumes 0 and 15, ten
    // of each, at 8,000 a second, is a 400 Hz square.
    let packed = [UInt8](repeating: 0x00, count: 5) + [UInt8](repeating: 0xFF, count: 5)
    let wave = Array((0 ..< 200).map { _ in packed }.joined())
    let block: [UInt8] = [0x67, 0x66, 0x48] + long(10 + wave.count) + [0x00] + long(wave.count * 2) + [8, 4, 0x00, 0x00, 0x00] + wave
    let stream: [UInt8] = [0x90, 0, 0x00, 0x00, 0x90, 0x91, 0, 0x08, 1, 0, 0x92, 0] + long(8000) + [0x95, 0] + word(0) + [0]
    let writes = block + snTone(0, period: 1, volume: 15) + stream + [0x61] + word(44100)
    let renderer = try TuneLoader.load(snFile(writes, ticks: 44100), format: .vgm, options: stereoOptions)
    #expect(renderer.info.shortfalls.isEmpty)
    let sound = side(stereo(renderer, seconds: 0.5), 0)
    #expect(abs(crossings(sound[2400 ..< 21600]) * 10 / 4 - 400) <= 3)
    #expect(loudness(sound[2400 ..< 21600]) > 0.01)
    // A block packed by differences is not read, and the file says so.
    var other = block
    other[7] = 0x01
    #expect(try TuneLoader.load(snFile(other + [0x61] + word(100), ticks: 100), format: .vgm).info.shortfalls.count == 1)
}

@Test func vgmOfAGameGearPutsItsChannelsWhereItsFileSays() throws {
    // Its first channel on the left alone, and then on both.
    let left = snTone(0, period: 254, volume: 0) + [0x4F, 0x10] + [0x61] + word(44100)
    let sound = stereo(try TuneLoader.load(snFile(left, ticks: 44100, gameGear: true), format: .vgm, options: stereoOptions), seconds: 0.5)
    #expect(loudness(side(sound, 0)[4800...]) > 0.01)
    #expect(loudness(side(sound, 1)[4800...]) < 0.0001)
    let both = snTone(0, period: 254, volume: 0) + [0x4F, 0x11] + [0x61] + word(44100)
    let sound2 = stereo(try TuneLoader.load(snFile(both, ticks: 44100, gameGear: true), format: .vgm, options: stereoOptions), seconds: 0.5)
    #expect(abs(loudness(side(sound2, 1)[4800...]) - loudness(side(sound2, 0)[4800...])) < 0.001)
}

/// A VGM file for an SAA1099 at 8 MHz (or two, the Creative Music System's, at a PC's 7.16 MHz).
private func saaFile(_ commands: [UInt8], ticks: Int, two: Bool = false) -> [UInt8] {
    vgm(commands, ticks: ticks, clockAt: 0xC8, clock: two ? 7_159_090 | 0x4000_0000 : 8_000_000)
}

/// Writes to an SAA1099's registers, the second's with `second`.
private func saa(_ writes: [(UInt8, UInt8)], second: Bool = false) -> [UInt8] {
    writes.flatMap { [0xBD, $0.0 | (second ? 0x80 : 0), $0.1] }
}

@Test func vgmOfAnSAA1099PlaysItsToneAtItsPitchOnItsSides() throws {
    // Octave 6 and offset 11: 15,625 times 64 over 500 is 2,000 Hz. Left at its loudest, right silent.
    let writes = saa([(0x00, 0x0F), (0x08, 11), (0x10, 6), (0x14, 0x01), (0x1C, 0x01)]) + [0x61] + word(44100)
    let renderer = try TuneLoader.load(saaFile(writes, ticks: 44100), format: .vgm, options: cardOptions)
    #expect(renderer.channelCount == 6)
    #expect(renderer.info.detail == "SAA1099")
    let sound = stereo(renderer, seconds: 1)
    #expect(abs(crossings(side(sound, 0)[4800...]) * 10 / 9 - 2000) <= 3)
    #expect(loudness(side(sound, 1)[4800...]) < loudness(side(sound, 0)[4800...]) * 0.001)
    var sides = [Float](repeating: 0, count: 6)
    renderer.takeChannelSides(into: &sides)
    #expect(sides[0] == -1)
    // Brought most of the way together unless the listener asks otherwise, as a Sound Blaster Pro's
    // sides are: 0.6 of it on the left and 0.4 on the right. It is still said to be on the left.
    let near = try TuneLoader.load(saaFile(writes, ticks: 44100), format: .vgm, options: stereoOptions)
    let n = stereo(near, seconds: 1)
    #expect(abs(loudness(side(n, 0)[4800...]) / loudness(side(sound, 0)[4800...]) - 0.6) < 0.01)
    #expect(abs(loudness(side(n, 1)[4800...]) / loudness(side(sound, 0)[4800...]) - 0.4) < 0.01)
    near.takeChannelSides(into: &sides)
    #expect(sides[0] == -1)
    // Nothing is heard until all its channels are switched on.
    let off = saa([(0x00, 0x0F), (0x08, 11), (0x10, 6), (0x14, 0x01)]) + [0x61] + word(44100)
    #expect(loudness(side(stereo(try TuneLoader.load(saaFile(off, ticks: 44100), format: .vgm), seconds: 0.5), 0)) == 0)
}

@Test func vgmOfAnSAA1099StepsItsEnvelopeByItsSecondOscillator() throws {
    // The second oscillator at 2,000 Hz, and the third channel playing the envelope alone, going down
    // over and over: sixteen steps, one a half of the oscillator's wave, is 250 Hz.
    let writes = saa([(0x02, 0xFF), (0x09, 11), (0x10, 6 << 4), (0x14, 0x00), (0x18, 0x86), (0x1C, 0x01)]) + [0x61] + word(44100)
    let sound = side(stereo(try TuneLoader.load(saaFile(writes, ticks: 44100), format: .vgm), seconds: 1), 0)
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 250) <= 2)
    // And the noise is heard where it is switched on, with no tone.
    let noise = saa([(0x00, 0xFF), (0x15, 0x01), (0x16, 0x00), (0x1C, 0x01)]) + [0x61] + word(44100)
    let hiss = side(stereo(try TuneLoader.load(saaFile(noise, ticks: 44100), format: .vgm), seconds: 0.5), 0)
    #expect(loudness(hiss[4800...]) > 0.01)
    #expect(crossings(hiss[4800...]) > 2000)
}

@Test func vgmOfACreativeMusicSystemPlaysBothItsChips() throws {
    // The same note on the first channel of the second chip.
    let writes = saa([(0x1C, 0x01)]) + saa([(0x00, 0xFF), (0x08, 11), (0x10, 6), (0x14, 0x01), (0x1C, 0x01)], second: true) + [0x61] + word(44100)
    let renderer = try TuneLoader.load(saaFile(writes, ticks: 44100, two: true), format: .vgm, options: stereoOptions)
    #expect(renderer.channelCount == 12)
    #expect(renderer.info.detail == "2 × SAA1099")
    let sound = side(stereo(renderer, seconds: 1), 0)
    // (At a PC's clock the note is 7.16 over 8 of 2,000 Hz.)
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 1790) <= 3)
    _ = stereo(renderer, seconds: 0.1)
    var levels = [Float](repeating: 0, count: 12)
    renderer.takeChannelLevels(into: &levels)
    #expect(levels[0] == 0)
    #expect(levels[6] > 0.1)
}

/// Each voice's scope, from a session that keeps them, after so many more frames of it.
private func scopes(_ session: TuneSession, after frames: Int) -> [[UInt8]] {
    var buffer = [Float](repeating: 0, count: frames * 2)
    _ = buffer.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: frames) }
    let count = session.renderer.channelCount
    var all = [UInt8](repeating: 0, count: count * ChannelWaves.points)
    all.withUnsafeMutableBufferPointer { session.takeChannelWaves(into: $0.baseAddress!, behind: 0) }
    return (0 ..< count).map { Array(all[$0 * ChannelWaves.points ..< ($0 + 1) * ChannelWaves.points]) }
}

/// A scope's distance from the middle at its highest.
private func height(_ scope: [UInt8]) -> Int { scope.map { abs(Int($0) - 128) }.max() ?? 0 }

private func keeping(_ file: [UInt8]) throws -> TuneSession {
    let session = TuneSession(renderer: try TuneLoader.load(file, format: .vgm, options: stereoOptions), policy: PlaybackPolicy())
    #expect(session.keepChannelWaves())
    return session
}

/// The files of the tests below: an FM chip and an AY chip, an SN76489, an SAA1099 and a DAC.
private let scopeFiles: [[UInt8]] = [
    vgm(note() + ayNote(period: 127) + [0x61] + word(44100), ticks: 44100, more: [(0x74, long(ayClock))]),
    snFile(snTone(0, period: 254, volume: 0) + snTone(1, period: 300, volume: 6) + [0x61] + word(44100), ticks: 44100),
    saaFile(saa([(0x00, 0x0F), (0x08, 11), (0x10, 6), (0x14, 0x01), (0x1C, 0x01)]) + [0x61] + word(44100), ticks: 44100),
    vgm(squareBlock(periods: 200) + dacStream + [0x95, 0] + word(0) + [0] + [0x61] + word(44100), ticks: 44100, clockAt: 0x2C, clock: 7_670_453),
]

@Test func vgmOfAnFMChipAndAnAYChipHasScopesForBoth() throws {
    // The sine on the FM chip's first voice and the tone on the AY chip's first channel, each at its loudest.
    let session = try keeping(scopeFiles[0])
    _ = scopes(session, after: 4800)
    var shown = scopes(session, after: 2000)
    #expect(height(shown[0]) > 100 && height(shown[9]) > 100)
    for voice in [1, 2, 3, 4, 5, 6, 7, 8, 10, 11] { #expect(shown[voice].allSatisfy { $0 == 128 }, "voice \(voice)") }
    // Voices left out still have theirs.
    session.renderer.setMuted([true, false, false, false, false, false, false, false, false, true])
    shown = scopes(session, after: 2000)
    #expect(height(shown[0]) > 100 && height(shown[9]) > 100)
    // Once the music is over, every scope is flat.
    _ = scopes(session, after: 96000)
    #expect(scopes(session, after: 2000).allSatisfy { $0.allSatisfy { $0 == 128 } })
}

@Test func vgmOfAnSN76489HasScopesAsLoudAsItsChannels() throws {
    // The first channel at its loudest, the second 12 dB under it, the others silent.
    let session = try keeping(scopeFiles[1])
    _ = scopes(session, after: 4800)
    let shown = scopes(session, after: 2000)
    #expect(height(shown[0]) > 120)
    #expect(abs(height(shown[1]) - 64) <= 3)
    #expect(shown[2].allSatisfy { $0 == 128 } && shown[3].allSatisfy { $0 == 128 })
}

@Test func vgmOfAnSAA1099AndADACHaveScopes() throws {
    let saa = try keeping(scopeFiles[2])
    _ = scopes(saa, after: 4800)
    let tones = scopes(saa, after: 2000)
    #expect(height(tones[0]) > 120)
    #expect(tones[1...].allSatisfy { $0.allSatisfy { $0 == 128 } })

    // The DAC's square, half as high as its eight bits go.
    let dac = try keeping(scopeFiles[3])
    _ = scopes(dac, after: 4800)
    #expect(abs(height(scopes(dac, after: 2000)[0]) - 90) <= 3)
}

@Test func vgmScopesAreOfWhatIsHeard() throws {
    // A sine on the FM chip throughout, and a tone on the AY chip after half a second: the chips
    // make some of what is to be heard before it is, and a scope is still of what is heard.
    let writes: [UInt8] = note() + [0x61] + word(22050) + ayNote(period: 127) + [0x61] + word(22050)
    let session = try keeping(vgm(writes, ticks: 44100, more: [(0x74, long(ayClock))]))
    let before = scopes(session, after: 23950)
    #expect(height(before[0]) > 100 && before[9].allSatisfy { $0 == 128 })
    let after = scopes(session, after: 1500)
    #expect(height(after[0]) > 100 && height(after[9]) > 100)
}

@Test func vgmSoundsTheSameWhetherItsScopesAreKeptOrNot() throws {
    for file in scopeFiles {
        let plain = try TuneLoader.load(file, format: .vgm, options: stereoOptions)
        let kept = try TuneLoader.load(file, format: .vgm, options: stereoOptions)
        #expect(kept.keepChannelWaves() != nil)
        #expect(stereo(plain, seconds: 2.5) == stereo(kept, seconds: 2.5))
    }
}

/// How loud a player says each of its voices has been since it was last asked.
private func levels(_ renderer: any Renderer) -> [Float] {
    var levels = [Float](repeating: 0, count: renderer.channelCount)
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    return levels
}

@Test func vgmVoiceHeldAtOneLevelIsDark() throws {
    // An SN76489's channel held at a period of one stays at its volume, and makes no sound; the
    // tone beside it does.
    let sn = try TuneLoader.load(snFile(snTone(0, period: 1, volume: 0) + snTone(1, period: 254, volume: 0) + [0x61] + word(44100), ticks: 44100),
                                 format: .vgm)
    _ = stereo(sn, seconds: 0.2)
    let snLevels = levels(sn)
    #expect(snLevels[0] == 0 && snLevels[1] > 0.9)

    // An SAA1099's envelope held at its loudest, with no tone or noise, is a level and not a sound;
    // going down over and over, it is one.
    let held = try TuneLoader.load(saaFile(saa([(0x02, 0xFF), (0x14, 0x00), (0x18, 0x82), (0x1C, 0x01)]) + [0x61] + word(44100), ticks: 44100),
                                   format: .vgm)
    _ = stereo(held, seconds: 0.2)
    #expect(levels(held)[2] == 0)
    let moving = try TuneLoader.load(saaFile(saa([(0x02, 0xFF), (0x09, 11), (0x10, 6 << 4), (0x14, 0x00), (0x18, 0x86), (0x1C, 0x01)]) + [0x61] + word(44100),
                                             ticks: 44100), format: .vgm)
    _ = stereo(moving, seconds: 0.2)
    #expect(levels(moving)[2] > 0.5)

    // A DAC left at one value is dark; one playing a sound is not.
    let still = try TuneLoader.load(vgm([0x52, 0x2B, 0x80, 0x52, 0x2A, 0xC0, 0x61] + word(44100), ticks: 44100, clockAt: 0x2C, clock: 7_670_453),
                                    format: .vgm)
    _ = stereo(still, seconds: 0.2)
    #expect(levels(still)[0] == 0)
    let playing = try TuneLoader.load(scopeFiles[3], format: .vgm)
    _ = stereo(playing, seconds: 0.2)
    #expect(abs(levels(playing)[0] - 0.5) < 0.02)
}

@Test func vgmChipsMakeNoMoreThanIsGivenOut() throws {
    // So that what is said of the voices is of what is heard: the chips make, between writes, what
    // is asked for and no more.
    let renderer = try TuneLoader.load(scopeFiles[0], format: .vgm)
    let waves = try #require(renderer.keepChannelWaves())
    var buffer = [Float](repeating: 0, count: 2000)
    for frames in [100, 37, 500, 3, 999] {
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
        #expect(waves.ahead == 0)
    }
}
