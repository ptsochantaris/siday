// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of the Amiga path. The thorough check is made outside the package, against the tracker
// it is ported from (pt2-clone): `siday --raw out.raw tune.mod` writes the tune as that tracker would
// write it to a file, and the two are to agree to the sample.

/// A module of one pattern, with one sample: a square wave of 32 bytes, looping, at full volume.
/// - Parameter notes: what to put on rows of the pattern: the row, the channel, and the note's four bytes.
private func module(tag: String = "M.K.", notes: [(row: Int, channel: Int, bytes: [UInt8])]) -> [UInt8] {
    var file = Array("a square wave".utf8)
    file += [UInt8](repeating: 0, count: 20 - file.count)
    for sample in 0 ..< 31 {
        var header = [UInt8](repeating: 0, count: 30)
        if sample == 0 {
            header[22 ... 23] = [0, 16] // 16 words long
            header[25] = 64 // as loud as it goes
            header[26 ... 29] = [0, 0, 0, 16] // and all of it loops
        } else {
            header[29] = 1
        }
        file += header
    }
    file += [1, 127] + [UInt8](repeating: 0, count: 128) + Array(tag.utf8)
    var pattern = [UInt8](repeating: 0, count: 64 * 4 * 4)
    for note in notes { pattern.replaceSubrange((note.row * 4 + note.channel) * 4 ..< (note.row * 4 + note.channel) * 4 + 4, with: note.bytes) }
    file += pattern
    file += [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16)
    return file
}

/// Sample 1 at a period, with an effect: the four bytes of a note.
private func note(period: Int, effect: UInt8 = 0, parameter: UInt8 = 0) -> [UInt8] {
    [UInt8(period >> 8), UInt8(period & 0xFF), 0x10 | effect, parameter]
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

@Test func moduleNoteSoundsAtItsPitchOnItsSide() throws {
    // Period 428 is the C that Paula plays at 3,546,895 / 428 = 8287 bytes a second; the square wave
    // is 32 of them long, so 259 Hz. It is on the first channel, which is wired to the left: and on
    // an Amiga, to the left alone.
    var options = LoadOptions()
    options.stereo = .abc
    options.amigaSeparation = 1
    let renderer = try TuneLoader.load(module(notes: [(0, 0, note(period: 428))]), format: .mod, options: options)
    #expect(renderer.info.format == "MOD")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "ProTracker")

    let sound = stereo(renderer, seconds: 1)
    let pitch = crossings(sound.left[4800...]) * 10 / 9
    #expect(abs(pitch - 259) <= 2)
    #expect(sound.left[4800...].map(abs).max()! > 0.2)
    #expect(sound.right.map(abs).max()! < 0.001)

    // The second channel is wired to the right.
    let other = try TuneLoader.load(module(notes: [(0, 1, note(period: 428))]), format: .mod, options: options)
    let otherSound = stereo(other, seconds: 1)
    #expect(otherSound.left.map(abs).max()! < 0.001)
    #expect(otherSound.right[4800...].map(abs).max()! > 0.2)
}

@Test func moduleSidesAreBroughtTogetherForHeadphones() throws {
    // As it comes, a fifth of the Amiga's separation is kept: a voice on the left is in both ears,
    // six parts to four.
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try TuneLoader.load(module(notes: [(0, 0, note(period: 428))]), format: .mod, options: options)
    let sound = stereo(renderer, seconds: 1)
    let left = sound.left[4800...].map(abs).max()!, right = sound.right[4800...].map(abs).max()!
    #expect(left > 0.1)
    #expect(abs(right / left - 4.0 / 6.0) < 0.001)
}

@Test func moduleInMonoIsTheSameInBothEars() throws {
    let renderer = try TuneLoader.load(module(notes: [(0, 0, note(period: 428)), (0, 1, note(period: 214))]), format: .mod)
    let sound = stereo(renderer, seconds: 0.5)
    #expect(sound.left == sound.right)
    #expect(sound.left[4800...].map(abs).max()! > 0.1)
}

@Test func moduleKnowsHowLongItIs() throws {
    // 64 rows of 6 ticks at 50 ticks a second (near enough: the Amiga's timer makes it 50.0007).
    let plain = try TuneLoader.load(module(notes: [(0, 0, note(period: 428))]), format: .mod)
    #expect(abs(plain.knownLength! - 7.68) < 0.01)
    #expect(plain.endsByLooping)

    // A speed of 3 from the first row on halves it, and a tempo of 250 halves it again.
    let fast = try TuneLoader.load(module(notes: [(0, 0, note(period: 428, effect: 0xF, parameter: 3))]), format: .mod)
    #expect(abs(fast.knownLength! - 3.84) < 0.01)
    let faster = try TuneLoader.load(module(notes: [(0, 0, note(period: 428, effect: 0xF, parameter: 3)), (0, 1, [0, 0, 0x0F, 250])]), format: .mod)
    #expect(abs(faster.knownLength! - 1.93) < 0.02)

    // A break on the eighth row goes round to the top again: eight rows.
    let short = try TuneLoader.load(module(notes: [(0, 0, note(period: 428)), (7, 0, [0, 0, 0x0D, 0])]), format: .mod)
    #expect(abs(short.knownLength! - 0.96) < 0.01)

    // And it counts the times it has come round.
    #expect(short.loopCount == 0)
    _ = stereo(short, seconds: 2)
    #expect(short.loopCount == 2)
    #expect(!short.hasEnded)
}

@Test func moduleThatStopsItselfHasEnded() throws {
    // A speed of nothing is how a module tells the tracker to stop.
    let renderer = try TuneLoader.load(module(notes: [(0, 0, note(period: 428)), (4, 0, [0, 0, 0x0F, 0])]), format: .mod)
    // Four rows of six ticks, and the tick of the fifth row that says so.
    #expect(abs(renderer.knownLength! - 0.5) < 0.01)
    _ = stereo(renderer, seconds: 1)
    #expect(renderer.hasEnded)
}

@Test func moduleWithAnEffectThatEatsItsSamplesStartsAfreshEachTime() throws {
    // EFx turns a sample upside down a byte at a time as it plays. Played twice, a tune is the same twice.
    let data = module(notes: [(0, 0, note(period: 428, effect: 0xE, parameter: 0xFF))])
    let renderer = try TuneLoader.load(data, format: .mod)
    let first = stereo(renderer, seconds: 2).left
    renderer.select(subsong: 0)
    let second = stereo(renderer, seconds: 2).left
    #expect(first == second)
    let untouched = try TuneLoader.load(module(notes: [(0, 0, note(period: 428))]), format: .mod)
    #expect(stereo(untouched, seconds: 2).left != first)
}

@Test func modulesOfOtherShapesAreTurnedAway() {
    // Eight channels are another tracker's, and so are four letters that nobody knows.
    #expect(throws: TuneError.self) { try TuneLoader.load(module(tag: "8CHN", notes: []), format: .mod) }
    #expect(throws: TuneError.self) { try TuneLoader.load(module(tag: "OCTA", notes: []), format: .mod) }
    // And a file that is not a module at all.
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x55, count: 5000), format: .mod) }
    #expect(throws: TuneError.self) { try TuneLoader.load([1, 2, 3], format: .mod) }
}

/// How much of a tone of a frequency there is in some samples taken at a rate.
private func level(of hz: Double, in samples: [Float], rate: Double) -> Double {
    var real = 0.0, imaginary = 0.0
    for (i, sample) in samples.enumerated() {
        let angle = 2 * Double.pi * hz * Double(i) / rate
        real += Double(sample) * Foundation.cos(angle)
        imaginary += Double(sample) * Foundation.sin(angle)
    }
    return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
}

@Test func paulaLeavesNoTonesThatWereNeverPlayed() {
    // A square wave four bytes long at period 124 is a tone of 7151 Hz. Its thirteenth harmonic is at
    // 92,963 Hz, which a chip made at 96,000 samples a second would hear, if its steps were let be
    // steps, as a tone of 3037 Hz and a thirteenth as loud as the note. They are not let be.
    let size = 64
    let memory = UnsafeMutablePointer<Int8>.allocate(capacity: size)
    defer { memory.deallocate() }
    for i in 0 ..< size { memory[i] = i % 4 < 2 ? 127 : -128 }
    var paula = Paula(rate: 96000, model: .a1200, memory: UnsafePointer(memory), size: size, silence: 0)
    paula.setLocation(0, 0)
    paula.setLength(0, 32)
    paula.setPeriod(0, 124)
    paula.setVolume(0, 64)
    paula.start(voices: 1)
    let count = 96000
    var left = [Float](repeating: 0, count: count), right = [Float](repeating: 0, count: count)
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in paula.generate(left: l.baseAddress!, right: r.baseAddress!, count: count) }
    }
    var down = HalfBand()
    let out = Array((0 ..< count / 2).map { down.step(left[$0 * 2], left[$0 * 2 + 1]) }[4800...])
    let note = Paula.clockHz / 124 / 4
    let played = level(of: note, in: out, rate: 48000)
    let folded = level(of: 96000 - note * 13, in: out, rate: 48000)
    #expect(played > 0.5)
    #expect(folded < played * 0.01)
}

/// Packs bytes the way PowerPacker does, as one run of bytes "as they are": enough to check the
/// unpacker reads its bits in the right order from the right end. Nil if the bits do not come to a
/// whole number of long words with less than a byte of padding, which the caller mends by adding a byte.
private func powerPacked(_ bytes: [UInt8]) -> [UInt8]? {
    var bits: [UInt8] = [0] // not a copy: bytes as they are
    var left = bytes.count - 1
    repeat {
        let part = min(3, left)
        bits += [UInt8(part >> 1), UInt8(part & 1)]
        left -= part
        if part < 3 { break }
    } while true
    for byte in bytes.reversed() { bits += (0 ..< 8).map { (byte >> (7 - $0)) & 1 } }
    let padding = (32 - bits.count % 32) % 32
    guard padding < 8 else { return nil }
    bits = [UInt8](repeating: 0, count: padding) + bits
    // The first bit read is the lowest bit of the last byte.
    var packed = [UInt8](repeating: 0, count: bits.count / 8)
    for (i, bit) in bits.enumerated() { packed[packed.count - 1 - i / 8] |= bit << UInt8(i % 8) }
    return Array("PP20".utf8) + [9, 10, 11, 11] + packed + [UInt8(bytes.count >> 16), UInt8(bytes.count >> 8 & 0xFF), UInt8(bytes.count & 0xFF), UInt8(padding)]
}

@Test func powerPackedModuleIsUnpacked() throws {
    var plain = module(notes: [(0, 0, note(period: 428))])
    var packed = powerPacked(plain)
    while packed == nil {
        plain.append(0)
        packed = powerPacked(plain)
    }
    #expect(PowerPacker.unpack(packed!) == plain)
    let renderer = try TuneLoader.load(packed!, format: .mod)
    #expect(renderer.info.title == "a square wave")
    #expect(abs(renderer.knownLength! - 7.68) < 0.01)
    // Cut short, it is not a PowerPacker file, and says so and does not crash.
    #expect(PowerPacker.unpack(Array(packed!.dropLast(8))) == nil || PowerPacker.unpack(Array(packed!.dropLast(8))) != plain)
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("PP20".utf8) + [UInt8](repeating: 0xFF, count: 60), format: .mod) }
}

@Test func moduleWithMoreThanOneSongHasThemAll() throws {
    // A pattern that stops the song halfway down, twice in the list: the second time is never
    // reached from the first, and is a song of its own.
    var file = module(notes: [(0, 0, note(period: 428)), (32, 0, [0, 0, 0x0F, 0])])
    #expect(try TuneLoader.load(file, format: .mod).subsongCount == 1)
    file[950] = 2 // the list is two long
    let renderer = try TuneLoader.load(file, format: .mod)
    #expect(renderer.subsongCount == 2)
    #expect(abs(renderer.songs[0].length! - 3.86) < 0.02)
    #expect(abs(renderer.songs[1].length! - 3.86) < 0.02)
    renderer.select(subsong: 1)
    #expect(renderer.currentSubsong == 1)
    let sound = stereo(renderer, seconds: 5).left
    #expect(abs(crossings(sound[4800 ..< 48000]) * 10 / 9 - 259) <= 2)
    #expect(renderer.hasEnded)

    // A place in the list that a jump passes over only leads back into the song, and is not one.
    file = module(notes: [(0, 0, note(period: 428)), (63, 0, [0, 0, 0x0B, 0])])
    file[950] = 2
    #expect(try TuneLoader.load(file, format: .mod).subsongCount == 1)

    // But one that is half a minute of music before it gets there is another way into the song, and
    // goes on as the song does until it comes to where it has itself been. Here a pattern played
    // slowly, 39.18 seconds of it, jumps to the first, which is 7.68 and goes round.
    let slow = module(notes: [(0, 0, note(period: 428)), (0, 1, [0, 0, 0x0F, 0x1F]), (63, 0, [0, 0, 0x0B, 0]), (63, 1, [0, 0, 0x0F, 6])])
    file = Array(file[..<2108]) + Array(slow[1084...])
    file[952 + 1] = 1
    let both = try TuneLoader.load(file, format: .mod)
    #expect(both.subsongCount == 2)
    #expect(abs(both.songs[0].length! - 7.68) < 0.02)
    #expect(abs(both.songs[1].length! - 46.86) < 0.05)
    both.select(subsong: 1)
    _ = stereo(both, seconds: 46)
    #expect(both.loopCount == 0)
    _ = stereo(both, seconds: 2)
    #expect(both.loopCount == 1)

    // A first song that is nothing at all, a pattern that stops at once, with a second pattern after
    // it that is something: the second is what is played unless the first is asked for.
    let stop = module(notes: [(0, 0, [0, 0, 0x0F, 0])])
    let tune = module(notes: [(0, 0, note(period: 428)), (32, 0, [0, 0, 0x0F, 0])])
    file = Array(stop[..<1084]) + Array(stop[1084 ..< 2108]) + Array(tune[1084...])
    file[950] = 2
    file[952 + 1] = 1
    let second = try TuneLoader.load(file, format: .mod)
    #expect(second.subsongCount == 2)
    #expect(second.defaultSubsong == 1)
    #expect(second.currentSubsong == 1)
    #expect(abs(second.knownLength! - 3.86) < 0.02)
    #expect(stereo(second, seconds: 1).left[4800...].map(abs).max()! > 0.02)
}

@Test func moduleVoicesAreMeasuredApart() throws {
    // A note on the second channel and nothing on the others.
    let renderer = try MODRenderer(module(notes: [(row: 0, channel: 1, bytes: note(period: 428))]), options: LoadOptions())
    #expect(renderer.channelCount == 4)
    #expect(renderer.channelsAlwaysShown == 4)
    var sound = [Float](repeating: 0, count: 4800 * 2)
    var levels = [Float](repeating: -1, count: 4)
    sound.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    #expect(levels[0] == 0)
    #expect(levels[1] > 0.3)
    #expect(levels[2] == 0)
    #expect(levels[3] == 0)
}
