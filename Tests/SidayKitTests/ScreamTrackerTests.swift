// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of the Scream Tracker path. The thorough check is made outside the package, against
// the player it is ported from (st3play): `siday --raw out.raw tune.s3m` writes the tune as that
// player would write it to a file, and the two are to agree to the sample.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0, count: length - bytes.count) }

/// An S3M file of one pattern and two instruments, each a square wave of 32 samples, looping, with
/// the first of them on the first row.
/// - Parameters:
///   - row: the packed bytes of the first row, in place of that note.
///   - stereo: whether the file asks for stereo.
///   - sixteen: whether the samples are of sixteen bits.
///   - soundBlaster: whether it bears the mark of having been saved with a Sound Blaster.
private func s3m(row: [UInt8]? = nil, stereo: Bool = false, sixteen: Bool = false, soundBlaster: Bool = false) -> [UInt8] {
    var file = padded(Array("a square wave".utf8), to: 28) + [0x1A, 16, 0, 0]
    file += word(2) + word(2) + word(1) + word(0) + word(0x1320) + word(2) + Array("SCRM".utf8)
    file += [64, 6, 125, stereo ? 0xB0 : 0x30, 16, 0] + [UInt8](repeating: 0, count: 10)
    file += [0, 8] + [UInt8](repeating: 255, count: 30) // a channel on the left, one on the right
    file += [0, 255] // the orders: the pattern, and the end
    file += word(0x7) + word(0xC) + word(0x11) // where the instruments and the pattern are, in sixteens
    file = padded(file, to: 0x70)
    let sampleBytes = sixteen ? 64 : 32
    for i in 0 ..< 2 {
        var instrument: [UInt8] = [1] + [UInt8](repeating: 0, count: 12) + [0] + word(0x20 + i * 8)
        instrument += long(32) + long(0) + long(32) + [64, 0, 0, sixteen ? 5 : 1] + long(8363)
        instrument = padded(instrument, to: 40) + word(soundBlaster ? 1 : 0x100 + i) + [UInt8](repeating: 0, count: 34) + Array("SCRS".utf8)
        file += instrument
    }
    file = padded(file, to: 0x110)
    // The pattern: C-4 on instrument 1 in the first channel of the first row, and nothing else.
    let rows = (row ?? [0x20, 0x40, 1]) + [UInt8](repeating: 0, count: 64)
    file += word(rows.count + 2) + rows
    file = padded(file, to: 0x200)
    for _ in 0 ..< 2 {
        var sample: [UInt8] = []
        for k in 0 ..< 32 {
            // Unsigned, as Scream Tracker has them: the top of the range, then the bottom.
            sample += sixteen ? (k < 16 ? [0xFF, 0xFF] : [0x00, 0x00]) : [k < 16 ? 0xFF : 0x00]
        }
        file += padded(sample, to: 0x80)
    }
    _ = sampleBytes
    return file
}

private func stereoSound(_ renderer: any Renderer, seconds: Double) -> (left: [Float], right: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

private func crossings(_ samples: ArraySlice<Float>) -> Int {
    zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
}

@Test func s3mNoteSoundsAtItsPitchOnTheCardItWasWrittenFor() throws {
    // C-4 plays a sample at 8363 samples a second, and the square wave is 32 of them: 261 Hz.
    let gus = try TuneLoader.load(s3m(), format: .s3m)
    #expect(gus.info.format == "S3M")
    #expect(gus.info.title == "a square wave")
    #expect(gus.info.detail == "Scream Tracker 3, Gravis Ultrasound")
    let sound = stereoSound(gus, seconds: 1).left
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 261) <= 2)
    #expect(sound[4800...].map(abs).max()! > 0.02)

    // Saved with a Sound Blaster, it is played on one; and either card can be asked for.
    let blaster = try TuneLoader.load(s3m(soundBlaster: true), format: .s3m)
    #expect(blaster.info.detail == "Scream Tracker 3, Sound Blaster Pro")
    let blasted = stereoSound(blaster, seconds: 1).left
    #expect(abs(crossings(blasted[4800...]) * 10 / 9 - 261) <= 3)
    var options = LoadOptions()
    options.s3mCard = .gus
    #expect(try TuneLoader.load(s3m(soundBlaster: true), format: .s3m, options: options).info.detail == "Scream Tracker 3, Gravis Ultrasound")
}

@Test func s3mInStereoPutsItsChannelsToTheirSides() throws {
    var options = LoadOptions()
    options.stereo = .abc
    // The first channel is one of the left's. A GUS has it most of the way over, not all.
    let gus = stereoSound(try TuneLoader.load(s3m(stereo: true), format: .s3m, options: options), seconds: 0.5)
    #expect(gus.left[4800...].map(abs).max()! > gus.right[4800...].map(abs).max()! * 1.5)
    // A Sound Blaster Pro has it hard over, and on the other side: Scream Tracker's two drivers do
    // not agree which side is which.
    options.s3mCard = .sb
    let blaster = stereoSound(try TuneLoader.load(s3m(stereo: true), format: .s3m, options: options), seconds: 0.5)
    let swingLeft = blaster.left[4800...].max()! - blaster.left[4800...].min()!
    let swingRight = blaster.right[4800...].max()! - blaster.right[4800...].min()!
    #expect(swingRight > 0.05)
    #expect(swingLeft < swingRight * 0.05)
    // In mono both sides are the same.
    let mono = stereoSound(try TuneLoader.load(s3m(stereo: true), format: .s3m), seconds: 0.5)
    #expect(mono.left == mono.right)
}

@Test func s3mKnowsHowLongItIs() throws {
    // 64 rows of 6 ticks at fifty ticks a second, near enough.
    let plain = try TuneLoader.load(s3m(), format: .s3m)
    #expect(abs(plain.knownLength! - 7.68) < 0.01)
    #expect(plain.endsByLooping)
    // A break on the first row: one row, and it counts each time round.
    let short = try TuneLoader.load(s3m(row: [0xA0, 0x40, 1, 3, 0]), format: .s3m)
    #expect(abs(short.knownLength! - 0.12) < 0.01)
    _ = stereoSound(short, seconds: 0.5)
    #expect(short.loopCount == 4)
}

@Test func s3mSamplesOfSixteenBitsArePlayed() throws {
    // Scream Tracker had none; trackers after it wrote them. The same wave, the same pitch.
    let renderer = try TuneLoader.load(s3m(sixteen: true), format: .s3m)
    let sound = stereoSound(renderer, seconds: 1).left
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 261) <= 2)
    #expect(sound[4800...].map(abs).max()! > 0.02)
}

@Test func s3mVeryHighNoteKeepsItsPitch() throws {
    // B-7 is a period so short that the player this is ported from loses track of a sign, and plays
    // something else. Scream Tracker did not: 126.7 kHz of samples a second, 32 to the wave, 3959 Hz.
    let renderer = try TuneLoader.load(s3m(row: [0x20, 0x7B, 1]), format: .s3m)
    let sound = stereoSound(renderer, seconds: 1).left
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 3959) <= 20)
}

@Test func filesThatAreNotS3MAreTurnedAway() {
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x41, count: 4000), format: .s3m) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(s3m().prefix(0x50)), format: .s3m) }
    // Cut short in its samples, it still plays what it has.
    #expect((try? TuneLoader.load(Array(s3m().prefix(0x210)), format: .s3m)) != nil)
}
