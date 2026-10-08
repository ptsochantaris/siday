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
///   - fm: whether the second channel is the AdLib card's first voice and not a channel of samples,
///     and the second instrument one of that card's: a plain sine wave that dies away when let go.
///   - rate: the samples a second at which the instruments play C-4.
///   - orders: the list of patterns to play, where 255 is its end.
private func s3m(row: [UInt8]? = nil, stereo: Bool = false, sixteen: Bool = false, soundBlaster: Bool = false, fm: Bool = false,
                 rate: Int = 8363, orders: [UInt8] = [0, 255]) -> [UInt8] {
    var file = padded(Array("a square wave".utf8), to: 28) + [0x1A, 16, 0, 0]
    file += word(orders.count) + word(2) + word(1) + word(0) + word(0x1320) + word(2) + Array("SCRM".utf8)
    file += [64, 6, 125, stereo ? 0xB0 : 0x30, 16, 0] + [UInt8](repeating: 0, count: 10)
    file += [0, fm ? 16 : 8] + [UInt8](repeating: 255, count: 30) // a channel on the left, one on the right
    file += orders // the pattern, and the end
    file += word(0x7) + word(0xC) + word(0x11) // where the instruments and the pattern are, in sixteens
    file = padded(file, to: 0x70)
    let sampleBytes = sixteen ? 64 : 32
    for i in 0 ..< 2 {
        var instrument: [UInt8] = [1] + [UInt8](repeating: 0, count: 12) + [0] + word(0x20 + i * 8)
        instrument += long(32) + long(0) + long(32) + [64, 0, 0, sixteen ? 5 : 1] + long(rate)
        instrument = padded(instrument, to: 40) + word(soundBlaster ? 1 : 0x100 + i) + [UInt8](repeating: 0, count: 34) + Array("SCRS".utf8)
        if fm, i == 1 {
            // Two operators, the first silent and so bending nothing, the second a sine at full
            // level that is held while its key is, and gone a tenth of a second after.
            instrument = [2] + [UInt8](repeating: 0, count: 15) + [0x01, 0x21, 63, 0, 0xF0, 0xF0, 0x00, 0x0A, 0, 0, 0, 0]
            instrument = padded(instrument + [63, 0, 0, 0] + long(8363), to: 76) + Array("SCRI".utf8)
        }
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

@Test func s3mSampleTunedHigherThanScreamTrackerCouldIsInTune() throws {
    // Scream Tracker has sixteen bits for the rate a sample plays C-4 at. Later trackers wrote more:
    // 66,904 a second is 2091 Hz for a wave of 32 samples, where 65,535 would be 2048.
    let renderer = try TuneLoader.load(s3m(rate: 66904), format: .s3m)
    let sound = stereoSound(renderer, seconds: 1).left
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 2091) <= 4)
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

@Test func s3mPlaysItsAdLibChannels() throws {
    // C-4 on the card's first voice. Scream Tracker makes that 684 in the chip's third octave,
    // which the chip plays at 259.4 Hz.
    let renderer = try TuneLoader.load(s3m(row: [0x21, 0x40, 2], fm: true), format: .s3m)
    #expect(renderer.info.detail == "Scream Tracker 3, Gravis Ultrasound and AdLib")
    let sound = stereoSound(renderer, seconds: 1).left
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 259) <= 2)
    #expect(sound[4800...].map(abs).max()! > 0.05)

    // Let go on the second row, it dies away.
    let released = stereoSound(try TuneLoader.load(s3m(row: [0x21, 0x40, 2, 0, 0x21, 254, 0], fm: true), format: .s3m), seconds: 1).left
    #expect(released[1000 ..< 5000].map(abs).max()! > 0.05)
    #expect(released[30000...].map(abs).max()! < 0.0005)

    // The card cannot play a sample: nothing is heard, and the card is not said to be there.
    let sample = try TuneLoader.load(s3m(row: [0x21, 0x40, 1], fm: true), format: .s3m)
    #expect(sample.info.detail == "Scream Tracker 3, Gravis Ultrasound")
    #expect(stereoSound(sample, seconds: 0.5).left.map(abs).max()! == 0)
}

@Test func s3mSamplesAreAsLoudWithTheAdLibCardAsWithout() throws {
    // A sample on the first row and the card's first note on the fifth. The card is known to be
    // coming, so the sample is at the one level throughout, and the level it has in any tune.
    let both = stereoSound(try TuneLoader.load(s3m(row: [0x20, 0x40, 1, 0, 0, 0, 0, 0x21, 0x40, 2], fm: true), format: .s3m), seconds: 1).left
    let alone = stereoSound(try TuneLoader.load(s3m(), format: .s3m), seconds: 1).left
    #expect(zip(both[..<20000], alone[..<20000]).allSatisfy { abs($0 - $1) < 0.0001 })
    #expect(zip(both[30000...], alone[30000...]).contains { abs($0 - $1) > 0.05 })
}

@Test func s3mWithMoreThanOneSongHasThemAll() throws {
    // The pattern, the end of the list, and then the pattern again where nothing leads to it: a
    // second song, as a game that started the module there would have had it.
    let renderer = try TuneLoader.load(s3m(orders: [0, 255, 0, 255]), format: .s3m)
    #expect(renderer.subsongCount == 2)
    #expect(renderer.defaultSubsong == 0)
    #expect(renderer.songs.count == 2)
    #expect(abs(renderer.songs[1].length! - 7.68) < 0.01)
    renderer.select(subsong: 1)
    #expect(renderer.currentSubsong == 1)
    #expect(abs(renderer.knownLength! - 7.68) < 0.01)
    let sound = stereoSound(renderer, seconds: 8).left
    #expect(abs(crossings(sound[4800 ..< 48000]) * 10 / 9 - 261) <= 2)
    // It is over where it runs off the end of the list, into the first song.
    #expect(renderer.loopCount == 1)

    // A place in the list that a jump passes over only leads back into the song, and is not one.
    let jump: [UInt8] = [0x20, 0x40, 1, 0] + [UInt8](repeating: 0, count: 62) + [0x80, 2, 0]
    #expect(try TuneLoader.load(s3m(row: jump, orders: [0, 0, 255, 255]), format: .s3m).subsongCount == 1)
    // Nor is an empty pattern.
    #expect(try TuneLoader.load(s3m(row: [0x20, 255, 0], orders: [0, 255, 0, 255]), format: .s3m).subsongCount == 1)
}
