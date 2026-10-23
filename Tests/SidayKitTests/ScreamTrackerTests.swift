// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayFoundation
@testable import SidayTrackers
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

@Test func s3mSampleInStereoIsPlayedWithItsSidesApartOrTogether() throws {
    // The square wave said to be in stereo, with a right side after it in the file that is low
    // where the left is high and high where it is low. Played as the trackers that make such
    // samples play them, in a file in mono the two together are silence, and in a file in stereo
    // on a Gravis Ultrasound the left side is on the left and the right on the right; played as
    // Scream Tracker would, which knows only of the left, it is the square wave still.
    for sixteen in [false, true] {
        func withStereoSample(_ file: [UInt8]) -> [UInt8] {
            var file = file
            file[0x70 + 31] |= 2
            let side = sixteen ? 64 : 32
            for k in 0 ..< side { file[0x200 + side + k] = file[0x200 + k] ^ 0xFF }
            return file
        }
        let renderer = try #require(try TuneLoader.load(withStereoSample(s3m(sixteen: sixteen)), format: .s3m) as? S3MRenderer)
        #expect(stereoSound(renderer, seconds: 0.5).left[4800...].map(abs).max()! < 0.001)
        #expect(renderer.renderRaw(frames: 24000).map { abs(Int($0)) }.max()! > 500)
        // And afterwards it is played as before.
        #expect(stereoSound(renderer, seconds: 0.5).left[4800...].map(abs).max()! < 0.001)

        var options = LoadOptions()
        options.stereo = .abc
        let apart = try TuneLoader.load(withStereoSample(s3m(stereo: true, sixteen: sixteen)), format: .s3m, options: options)
        #expect(apart.info.shortfalls.isEmpty)
        let sound = stereoSound(apart, seconds: 0.5)
        #expect(sound.left[4800...].map(abs).max()! > 0.02 && sound.right[4800...].map(abs).max()! > 0.02)
        // (The two sides each other turned over: where one is up the other is down. The channel is
        // to one side, so the two are not as loud as each other.)
        let opposite = (4800 ..< 24000).filter { sound.left[$0] * sound.right[$0] < 0 }.count
        #expect(opposite > 18000)
    }
    // A file that ends before the right side does has only the left, and that is played.
    var short = s3m()
    short[0x70 + 31] |= 2
    short = Array(short[..<0x230])
    let sound = stereoSound(try TuneLoader.load(short, format: .s3m), seconds: 0.5).left
    #expect(sound[4800...].map(abs).max()! > 0.02)
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

@Test func s3mLoopPastTheEndOfItsSampleIsNoLoop() throws {
    // The first instrument's loop from 40 to 50, of a sample of 32: brought within the sample, it is
    // a loop of nothing, which once made the player go round it for ever.
    var file = s3m()
    file.replaceSubrange(0x70 + 20 ..< 0x70 + 28, with: long(40) + long(50))
    let renderer = try TuneLoader.load(file, format: .s3m)
    let sound = stereoSound(renderer, seconds: 0.2)
    #expect(sound.left.contains { $0 != 0 })
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
    // It is over where it runs off the end of the list, into the first song: it ends there, and is
    // not faded out over the first song as a song that comes round to itself is.
    #expect(renderer.loopCount == 1)
    #expect(renderer.hasEnded)
    #expect(abs(sessionLength(try TuneLoader.load(s3m(orders: [0, 255, 0, 255]), format: .s3m), song: 1) - 7.68) < 0.4)
    // (The first song, which comes round to itself, is faded out as it goes on, for as long as it lasts.)
    #expect(sessionLength(try TuneLoader.load(s3m(orders: [0, 255, 0, 255]), format: .s3m), song: 0) > 12)

    // A place in the list that a jump passes over only leads back into the song, and is not one.
    let jump: [UInt8] = [0x20, 0x40, 1, 0] + [UInt8](repeating: 0, count: 62) + [0x80, 2, 0]
    #expect(try TuneLoader.load(s3m(row: jump, orders: [0, 0, 255, 255]), format: .s3m).subsongCount == 1)
    // Nor is an empty pattern.
    #expect(try TuneLoader.load(s3m(row: [0x20, 255, 0], orders: [0, 255, 0, 255]), format: .s3m).subsongCount == 1)
}

/// A file as Impulse Tracker 2.14 would sign it: the tracker a file says made it is two bytes of
/// its header.
private func byImpulseTracker(_ file: [UInt8]) -> [UInt8] {
    var file = file
    file[0x28 ... 0x29] = [0x14, 0x32]
    return file
}

@Test func s3mFromALaterTrackerHasItsChannelAndTuneVolumesPlayed() throws {
    /// How loud the note is half a second in, with something else on its row.
    func peak(_ row: [UInt8]?, _ file: ([UInt8]) -> [UInt8] = byImpulseTracker) throws -> Float {
        stereoSound(try TuneLoader.load(file(s3m(row: row)), format: .s3m), seconds: 0.7).left[24000...].map(abs).max()!
    }
    /// True if a command leaves the note as loud as a note of a given volume is. (The card's
    /// volumes are 0 to 63, and the loudest note is at 63.)
    func leaves(_ command: UInt8, _ value: UInt8, at volume: UInt8) throws -> Bool {
        let heard = try peak([0xA0, 0x40, 1, command, value]), wanted = try peak([0x60, 0x40, 1, volume])
        return abs(heard - wanted) < wanted * 0.01
    }
    // M sets the channel's volume, of 64: at 32, a note is half what it was.
    #expect(try leaves(13, 32, at: 31))
    #expect(try leaves(13, 80, at: 63))
    // N slides it, on the five ticks of the row after the first: by four a tick, twenty in all,
    // from 64 to 44.
    #expect(try leaves(14, 0x04, at: 43))
    // Or once, on the first tick, with an F for the other digit.
    #expect(try leaves(14, 0xF8, at: 55))
    #expect(try !leaves(14, 0xF8, at: 63))
    // W does the same to the whole tune's volume, which a note already playing is turned down by.
    #expect(try leaves(23, 0x08, at: 23))
    #expect(try leaves(23, 0xF8, at: 55))
    // In a file that Scream Tracker saved they are nothing, as they were to Scream Tracker.
    for command: UInt8 in [13, 14, 23] { #expect(try peak([0xA0, 0x40, 1, command, 0x08]) { $0 } == peak(nil) { $0 }) }
    // And so they are in the other when it is played as the player this is ported from plays it.
    func raw(_ row: [UInt8]?) throws -> [Int16] {
        try #require(try TuneLoader.load(byImpulseTracker(s3m(row: row)), format: .s3m) as? S3MRenderer).renderRaw(frames: 9600)
    }
    #expect(try raw([0xA0, 0x40, 1, 13, 0x08]) == raw(nil))
}

@Test func s3mFromALaterTrackerHasItsFilterPlayed() throws {
    /// How much of the note is in how it changes from one sample to the next: less for a duller sound.
    func brightness(_ file: [UInt8], _ options: LoadOptions = LoadOptions()) throws -> Float {
        let left = stereoSound(try TuneLoader.load(file, format: .s3m, options: options), seconds: 0.6).left[9600...]
        return zip(left, left.dropFirst()).map { ($1 - $0) * ($1 - $0) }.reduce(0, +) / left.map { $0 * $0 }.reduce(0, +)
    }
    let plain = try brightness(byImpulseTracker(s3m()))
    // Z sets the channel's cutoff: at 20 hex, 330 Hz, which takes the edges off the square wave.
    let closed = try brightness(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 26, 0x20])))
    #expect(closed < plain * 0.5)
    // Opened all the way, it is a filter still, and takes off a little.
    let open = try brightness(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 26, 0x7F])))
    #expect(open < plain && open > closed)
    // From 80 to 8F hex it sets the resonance, and puts the filter on as the cutoff does: at its
    // most, with the cutoff open, it rings at 5 kHz and brightens the note.
    #expect(try brightness(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 26, 0x8F]))) > plain)
    // On a Sound Blaster too.
    var options = LoadOptions()
    options.s3mCard = .sb
    func soundBlaster(_ row: [UInt8]?) throws -> Float { try brightness(byImpulseTracker(s3m(row: row)), options) }
    #expect(try soundBlaster([0xA0, 0x40, 1, 26, 0x20]) < soundBlaster(nil) * 0.5)
    // It is nothing in a file that Scream Tracker saved, or Impulse Tracker before 2.14, as it was to them.
    #expect(try brightness(s3m(row: [0xA0, 0x40, 1, 26, 0x20])) == brightness(s3m()))
    var old = byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 26, 0x20]))
    old[0x28] = 0x05
    #expect(try brightness(old) == plain)
}

@Test func s3mFromALaterTrackerHasItsReverbPlayed() throws {
    /// How far the sound swings after the note is ended, on the row after it. (A Sound Blaster's
    /// output sits a little off nought.)
    func after(_ file: [UInt8], _ card: ST3Card = .gus) throws -> Float {
        var options = LoadOptions()
        options.s3mCard = card
        let left = stereoSound(try TuneLoader.load(file, format: .s3m, options: options), seconds: 1).left[24000...]
        return left.max()! - left.min()!
    }
    // S99 puts the channel in ModPlug's reverb, whose sound goes on after the note is ended.
    let reverb: [UInt8] = [0xA0, 0x40, 1, 19, 0x99, 0, 0x20, 254, 0]
    #expect(try after(byImpulseTracker(s3m(row: reverb))) > 0.001)
    // Without it, or with S98, which takes the channel out again, there is nothing after the cut.
    let none: [UInt8] = [0xA0, 0x40, 1, 19, 0x98, 0, 0x20, 254, 0]
    #expect(try after(byImpulseTracker(s3m(row: none))) < 0.0001)
    // Nor in a file that Scream Tracker saved, nor on a Sound Blaster.
    #expect(try after(s3m(row: reverb)) < 0.0001)
    #expect(try after(byImpulseTracker(s3m(row: reverb)), .sb) < 0.0001)
}

@Test func s3mFromALaterTrackerHasItsChannelsPastSixteenPlayed() throws {
    /// How far the sound swings, on a card.
    func swing(_ file: [UInt8], _ card: ST3Card = .gus) throws -> Float {
        var options = LoadOptions()
        options.s3mCard = card
        let left = stereoSound(try TuneLoader.load(file, format: .s3m, options: options), seconds: 0.5).left[4800...]
        return left.max()! - left.min()!
    }
    // The note is on the third channel, which the file numbers as the AdLib card's first voice.
    var wide = s3m(row: [0x22, 0x40, 1])
    wide[0x42] = 16
    // From a later tracker, it is a channel of samples, as it was there, on a Gravis Ultrasound.
    #expect(try swing(byImpulseTracker(wide)) > 0.05)
    // Not on a Sound Blaster, which mixes sixteen, nor in a file Scream Tracker saved, as in Scream Tracker.
    #expect(try swing(byImpulseTracker(wide), .sb) < 0.001)
    #expect(try swing(wide) < 0.001)
    // And it can be left out of the sound, as any other.
    let renderer = try TuneLoader.load(byImpulseTracker(wide), format: .s3m)
    #expect(renderer.channelCount == 1)
    renderer.setMuted([true])
    let left = stereoSound(renderer, seconds: 0.5).left[4800...]
    #expect(left.max()! - left.min()! < 0.001)
}

@Test func s3mFromALaterTrackerKeepsItsTempo() throws {
    func length(_ file: [UInt8], tempo: UInt8 = 128) throws -> Double {
        var file = file
        file[0x32] = tempo
        return try TuneLoader.load(file, format: .s3m).knownLength!
    }
    // 64 rows of 6 ticks at 128 beats a minute, two fifths of that a second: 7.5 seconds.
    #expect(abs(try length(byImpulseTracker(s3m())) - 7.5) < 0.01)
    // Scream Tracker's own timer on a GUS goes by whole ticks a second, here 51 for 51.2.
    #expect(abs(try length(s3m()) - 64 * 6 / 51.0) < 0.01)
    // T under 20 hex slides the tempo on the ticks of its row after the first, as Impulse Tracker
    // has it: T15 takes it from 128 up by 25, and T00 then gives the channel's T again.
    let up = try length(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 20, 0x15])))
    #expect(abs(up - (6 / (128 * 0.4) + 63 * 6 / (153 * 0.4))) < 0.06)
    let again = try length(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 20, 0x15, 0, 0x80, 20, 0x00])))
    #expect(again < up - 0.3)
}

@Test func s3mWithPixPlaysPanningHasItsChannelsPlaced() throws {
    /// How much louder the right side is than the left, for the first channel's note.
    func rightOverLeft(_ file: [UInt8]) throws -> Float {
        var options = LoadOptions()
        options.stereo = .abc
        let sound = stereoSound(try TuneLoader.load(file, format: .s3m, options: options), seconds: 0.4)
        return sound.right.map(abs).reduce(0, +) / sound.left.map(abs).reduce(0, +)
    }
    // Z0F on the first channel, which is on the left, and Z00 on the second.
    let row: [UInt8] = [0xA0, 0x40, 1, 26, 0x0F, 0x81, 26, 0x00]
    var file = s3m(row: row, stereo: true)
    file[0x28] = 0x01
    file[0x29] = 0x13
    // In a file from before Scream Tracker 3.20, that is PixPlay's placing of the channel, to the right.
    #expect(try rightOverLeft(file) > 2)
    // And not in a later one.
    #expect(try rightOverLeft(s3m(row: row, stereo: true)) < 0.5)
}

// MARK: What is not played as the file asks

@Test func s3mFromALaterTrackerSaysWhatScreamTrackerDoesNotPlay() throws {
    func shortfalls(_ file: [UInt8]) throws -> [String] { try TuneLoader.load(file, format: .s3m).info.shortfalls }
    #expect(try shortfalls(s3m()).isEmpty)
    #expect(try shortfalls(s3m(fm: true)).isEmpty)

    // Impulse Tracker's slide of the whole tune's volume (W, the 23rd letter) is played in a file
    // it saved, and is nothing in one that Scream Tracker saved, as it was to Scream Tracker.
    #expect(try shortfalls(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 23, 0x02]))).isEmpty)
    #expect(try shortfalls(s3m(row: [0xA0, 0x40, 1, 23, 0x02])).isEmpty)
    // Its setting of a filter (Z) is played (see `s3mFromALaterTrackerHasItsFilterPlayed`).
    #expect(try shortfalls(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 26, 0x40]))).isEmpty)
    #expect(try shortfalls(s3m(row: [0xA0, 0x40, 1, 26, 0x40])).isEmpty)
    // ModPlug's reverb (S99), which only a later tracker's file can ask for, is played on a Gravis
    // Ultrasound (see `s3mFromALaterTrackerHasItsReverbPlayed`), and not on a Sound Blaster.
    #expect(try shortfalls(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 19, 0x99]))).isEmpty)
    var onSoundBlaster = LoadOptions()
    onSoundBlaster.s3mCard = .sb
    #expect(try TuneLoader.load(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 19, 0x99])), format: .s3m, options: onSoundBlaster).info.shortfalls
        == ["One of its commands is left out, on the Sound Blaster it is played on: ModPlug's reverb."])
    #expect(try shortfalls(s3m(row: [0xA0, 0x40, 1, 19, 0x99])).isEmpty)
    // A later tracker's seventeenth channel of samples, numbered as the AdLib card's first, is
    // played on a Gravis Ultrasound (see `s3mFromALaterTrackerHasItsChannelsPastSixteenPlayed`),
    // and not on a Sound Blaster.
    var wide = s3m(row: [0x22, 0x40, 1])
    wide[0x42] = 16
    #expect(try shortfalls(byImpulseTracker(wide)).isEmpty)
    #expect(try TuneLoader.load(byImpulseTracker(wide), format: .s3m, options: onSoundBlaster).info.shortfalls
        == ["One of its channels is past the sixteen a Sound Blaster mixes, and the samples played on it are not heard there."])
    #expect(try shortfalls(wide).isEmpty)
    // One that plays the AdLib's instruments as well as samples is the AdLib's still.
    var mixed = s3m(row: [0x22, 0x40, 1, 0, 0x22, 0x40, 2], fm: true)
    mixed[0x42] = 16
    #expect(try shortfalls(byImpulseTracker(mixed))
        == ["One of its channels is numbered as Scream Tracker numbers the AdLib card's, and the samples played on it are not heard."])
    // Where a channel is put (X) is not counted: too many files have it, and lose little by it.
    #expect(try shortfalls(s3m(row: [0xA0, 0x40, 1, 24, 0x40])).isEmpty)

    // A sample in stereo that a note plays, and one that no note plays.
    var stereo = s3m()
    stereo[0x70 + 31] |= 2
    stereo[0xC0 + 31] |= 2
    #expect(try shortfalls(stereo) == ["One of its samples is in stereo, and is heard with its two sides mixed into one."])
    // One of the AdLib card's drums, which Scream Tracker never came to play.
    var drum = s3m(row: [0x20, 0x40, 2], fm: true)
    drum[0xC0] = 3
    #expect(try shortfalls(drum) == ["One of its instruments is one of the AdLib card's drums, which Scream Tracker never played, and is not heard."])
    // A file that ends before its second sample.
    #expect(try shortfalls(Array(s3m().dropLast(0x80))) == ["The file is cut short: one of its samples is missing, and is silent."])
}

/// How loud a player says each of its voices has been since it was last asked.
private func levels(_ renderer: any Renderer) -> [Float] {
    var levels = [Float](repeating: 0, count: renderer.channelCount)
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    return levels
}

@Test func s3mChannelLeftOutIsNotHeardAndPlaysOn() throws {
    // A note on each of the two channels, one of the left's and one of the right's, and the same
    // tune with the first of them alone: on each of the two cards, and both for a file that asks
    // for stereo and for one that does not.
    let both: [UInt8] = [0x20, 0x40, 1, 0x21, 0x50, 2], first: [UInt8] = [0x20, 0x40, 1]
    for (card, inStereo) in [(ST3Card.gus, true), (.gus, false), (.sb, true), (.sb, false)] {
        var options = LoadOptions()
        options.stereo = .abc
        options.s3mCard = card
        func fresh(_ row: [UInt8]) throws -> any Renderer { try TuneLoader.load(s3m(row: row, stereo: inStereo), format: .s3m, options: options) }
        let whole = try fresh(both)
        #expect(whole.channelCount == 2)
        let wholeSound = stereoSound(whole, seconds: 0.5), wholeLevels = levels(whole)
        #expect(wholeLevels[0] > 0.2 && wholeLevels[1] > 0.2)

        // The second left out: what is heard is the tune without its note, to the sample (either
        // card adds its channels up in whole numbers), and the channel is said to be as loud as it was.
        let alone = stereoSound(try fresh(first), seconds: 0.5)
        let renderer = try fresh(both)
        renderer.setMuted([false, true])
        let without = stereoSound(renderer, seconds: 0.5)
        #expect(without == alone && without != wholeSound)
        #expect(levels(renderer) == wholeLevels)

        // A song started again is started without the channel; and with it brought back, as it ever was.
        renderer.select(subsong: 0)
        #expect(stereoSound(renderer, seconds: 0.5) == without)
        renderer.setMuted([])
        renderer.select(subsong: 0)
        #expect(stereoSound(renderer, seconds: 0.5) == wholeSound)

        // Every channel left out is what a tune with no note in it is: silence on a GUS, and on a
        // Sound Blaster whatever its eight bits rest at.
        renderer.setMuted([true, true])
        renderer.select(subsong: 0)
        let none = stereoSound(renderer, seconds: 0.5)
        #expect(none == stereoSound(try fresh([]), seconds: 0.5))
        if card == .gus { #expect(none.left.allSatisfy { $0 == 0 } && none.right.allSatisfy { $0 == 0 }) }
        #expect(levels(renderer) == wholeLevels)

        // Left out while they play, the notes that are sounding go too: once the tick that was
        // made already has been heard, a fiftieth of a second, there is no more than in that tune.
        whole.setMuted([true, true])
        let empty = try fresh([])
        _ = stereoSound(empty, seconds: 0.5)
        #expect(stereoSound(whole, seconds: 0.1).left[2000...] == stereoSound(empty, seconds: 0.1).left[2000...])
    }
}

@Test func s3mAdLibVoiceLeftOutIsNotHeardAndPlaysOn() throws {
    // A sample on the first channel, and on the second a note of the AdLib card's first voice.
    func fresh(_ row: [UInt8]) throws -> any Renderer { try TuneLoader.load(s3m(row: row, fm: true), format: .s3m) }
    let both: [UInt8] = [0x20, 0x40, 1, 0x21, 0x40, 2]
    let whole = try fresh(both)
    var sampled = [true, true]
    whole.takeChannelsSampled(into: &sampled)
    #expect(whole.channelCount == 2 && sampled == [true, false])
    let wholeSound = stereoSound(whole, seconds: 0.5).left, wholeLevels = levels(whole)
    #expect(wholeLevels[0] > 0.2 && wholeLevels[1] > 0.05)

    // The card's voice left out, which the chip does for it: the sample is heard alone, and as
    // loud as it is in any tune, the card being there still and giving out nothing.
    let renderer = try fresh(both)
    renderer.setMuted([false, true])
    let sampleOnly = stereoSound(renderer, seconds: 0.5).left
    let alone = stereoSound(try TuneLoader.load(s3m(), format: .s3m), seconds: 0.5).left
    #expect(zip(sampleOnly, alone).allSatisfy { abs($0 - $1) < 0.0001 })
    #expect(zip(sampleOnly, wholeSound).contains { abs($0 - $1) > 0.05 })
    #expect(levels(renderer) == wholeLevels)

    // The sample left out: the card's voice alone, to the sample.
    renderer.setMuted([true, false])
    renderer.select(subsong: 0)
    #expect(stereoSound(renderer, seconds: 0.5).left == stereoSound(try fresh([0x21, 0x40, 2]), seconds: 0.5).left)
    #expect(levels(renderer) == wholeLevels)

    // Both left out is silence; and with neither, the sound is what it was.
    renderer.setMuted([true, true])
    renderer.select(subsong: 0)
    #expect(stereoSound(renderer, seconds: 0.5).left.allSatisfy { $0 == 0 })
    #expect(levels(renderer) == wholeLevels)
    renderer.setMuted([])
    renderer.select(subsong: 0)
    #expect(stereoSound(renderer, seconds: 0.5).left == wholeSound)
}

/// How long a session plays a song of a tune for, in seconds, with the tune played once through.
private func sessionLength(_ renderer: any Renderer, song: Int) -> Double {
    renderer.select(subsong: song)
    let session = TuneSession(renderer: renderer, policy: PlaybackPolicy())
    var block = [Float](repeating: 0, count: 1024)
    while !session.finished, session.elapsed < 60 { _ = block.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: 512) } }
    return session.elapsed
}

@Test func s3mFromALaterTrackerHasItsChannelsPlacedOnTheGravisUltrasound() throws {
    // The first channel is on the left. X80 puts it hard right in a file that a later tracker
    // saved, and is nothing in one of Scream Tracker's own.
    func sides(_ file: [UInt8]) throws -> (left: Float, right: Float) {
        var buffer = [Float](repeating: 0, count: 9600 * 2)
        var options = LoadOptions()
        options.stereo = .abc
        let renderer = try TuneLoader.load(file, format: .s3m, options: options)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 9600) }
        func loudness(_ side: Int) -> Float { (stride(from: 2400 * 2 + side, to: 9600 * 2, by: 2).reduce(Float(0)) { $0 + buffer[$1] * buffer[$1] } / 7200).squareRoot() }
        return (loudness(0), loudness(1))
    }
    let left = try sides(byImpulseTracker(s3m(stereo: true)))
    let right = try sides(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 24, 0x80], stereo: true)))
    let own = try sides(s3m(row: [0xA0, 0x40, 1, 24, 0x80], stereo: true))
    #expect(left.left > left.right * 1.5 && right.right > right.left * 10 && own.left > own.right * 1.5)
    // P slides it, and Y sweeps it about where it is.
    let slid = try sides(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 16, 0x0F], stereo: true)))
    #expect(slid.right > left.right * 1.5)
    let swept = try sides(byImpulseTracker(s3m(row: [0xA0, 0x40, 1, 25, 0x8F], stereo: true)))
    #expect(swept.right != left.right)
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

@Test func s3mChannelsHaveScopesOnEitherCard() throws {
    // A note on the first channel, at its loudest or at a quarter of it, and the second given a
    // note at no volume, on each card.
    for card in [ST3Card.gus, .sb] {
        var options = LoadOptions()
        options.s3mCard = card
        func session(_ row: [UInt8]) throws -> TuneSession {
            let session = TuneSession(renderer: try TuneLoader.load(s3m(row: row, stereo: true), format: .s3m, options: options), policy: PlaybackPolicy())
            #expect(session.keepChannelWaves())
            return session
        }
        let loud = try session([0x20, 0x40, 1, 0x61, 0x40, 1, 0])
        _ = scopes(loud, after: 4800)
        let shown = scopes(loud, after: 2000)
        #expect(height(shown[0]) > 110)
        #expect(shown[1].allSatisfy { $0 == 128 })

        // A quieter note is a smaller scope, as small as its light is dim.
        let quiet = try session([0x60, 0x40, 1, 16, 0x61, 0x40, 1, 0])
        _ = scopes(quiet, after: 4800)
        let small = scopes(quiet, after: 2000)
        let level = quiet.channelLevels[0]
        #expect(height(small[0]) < height(shown[0]) && height(small[0]) > 20)
        #expect(abs(pow(Float(height(small[0])) / 127, 2) - level) < 0.1)

        // A channel left out still has its scope.
        loud.renderer.setMuted([true, false])
        _ = scopes(loud, after: 4800)
        #expect(height(scopes(loud, after: 2000)[0]) > 110)
    }
}

@Test func s3mAdLibChannelsHaveScopes() throws {
    // A sample at no volume on the first channel, and a note of the AdLib card's first voice.
    let session = TuneSession(renderer: try TuneLoader.load(s3m(row: [0x60, 0x40, 1, 0, 0x21, 0x40, 2], fm: true), format: .s3m), policy: PlaybackPolicy())
    #expect(session.keepChannelWaves())
    _ = scopes(session, after: 4800)
    var shown = scopes(session, after: 2000)
    #expect(shown[0].allSatisfy { $0 == 128 })
    #expect(height(shown[1]) > 100)
    session.renderer.setMuted([false, true])
    _ = scopes(session, after: 4800)
    shown = scopes(session, after: 2000)
    #expect(height(shown[1]) > 100)
    // And started again, it still keeps them.
    session.renderer.select(subsong: 0)
    _ = scopes(session, after: 4800)
    #expect(height(scopes(session, after: 2000)[1]) > 100)

    // Where the card's voice is given a sample, which it cannot play, the card is not played at
    // all, and its scope is flat.
    let unplayed = TuneSession(renderer: try TuneLoader.load(s3m(row: [0x20, 0x40, 1, 0x21, 0x40, 1], fm: true), format: .s3m), policy: PlaybackPolicy())
    #expect(unplayed.keepChannelWaves())
    _ = scopes(unplayed, after: 4800)
    shown = scopes(unplayed, after: 2000)
    #expect(height(shown[0]) > 100 && shown[1].allSatisfy { $0 == 128 })
}

@Test func s3mSoundsTheSameWhetherItsScopesAreKeptOrNot() throws {
    for (card, fm) in [(ST3Card.gus, false), (.sb, false), (.gus, true), (.sb, true)] {
        var options = LoadOptions()
        options.s3mCard = card
        let file = s3m(row: [0x20, 0x40, 1, 0x21, 0x40, 2, 0, 0, 0, 0x20, 0x50, 1, 0x21, 254, 0], stereo: true, fm: fm)
        let plain = try TuneLoader.load(file, format: .s3m, options: options)
        let kept = try TuneLoader.load(file, format: .s3m, options: options)
        #expect(kept.keepChannelWaves() != nil)
        #expect(stereoSound(plain, seconds: 1) == stereoSound(kept, seconds: 1))
    }
}

@Test func s3mLightsAreOfWhatIsGivenOut() throws {
    // The first instrument not looping: its 32 samples at C-4 are over in some 190 of the player's
    // frames, at the start of the first tick, which is 960 of them. A tick is made whole; the lights
    // are of the part of it given out.
    var file = s3m()
    file[0x70 + 31] = 0
    for card in [ST3Card.gus, .sb] {
        var options = LoadOptions()
        options.s3mCard = card
        let renderer = try TuneLoader.load(file, format: .s3m, options: options)
        _ = stereoSound(renderer, seconds: 0.0125)
        #expect(levels(renderer)[0] > 0.3)
        _ = stereoSound(renderer, seconds: 0.005)
        #expect(levels(renderer)[0] == 0)
        // And the note is said to be struck as its tick begins to be given out, not before.
        let again = try TuneLoader.load(file, format: .s3m, options: options)
        var pitches = [Float](repeating: 0, count: 2), struck = [Bool](repeating: false, count: 2)
        again.takeChannelNotes(pitches: &pitches, struck: &struck)
        #expect(!struck[0])
        _ = stereoSound(again, seconds: 0.001)
        again.takeChannelNotes(pitches: &pitches, struck: &struck)
        #expect(struck[0] && pitches[0] > 0)
    }
}
