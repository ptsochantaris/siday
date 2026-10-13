// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the GDM and PTM files that Impulse Tracker's replayer plays. The thorough checks
// are made outside the package, against libxmp: what is read from every file is set beside what
// libxmp reads from it, and what is heard beside what libxmp plays.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0, count: length - bytes.count) }

/// A square wave of 32 samples, as bytes without a sign: the top of the range, then the bottom.
private let square: [UInt8] = (0 ..< 32).map { $0 < 16 ? 0xFF : 0x01 }

/// C in the octave that plays a sample at its own rate, as a GDM file writes a note.
private let gdmC4: UInt8 = 0x41

/// A GDM file of one pattern, with samples that are a square wave of 32 samples, looping.
/// - Parameters:
///   - rows: the packed bytes of the pattern, without the nought that ends its last row.
///   - origin: what 2GDM says it was made from: 1 a MOD file, 3 an S3M file.
///   - pans: where each channel sits, from 0 (left) to 15 (right); 16 is surround and 255 not used.
///   - samples: for each sample, its flags, its volume and its place between the speakers.
///   - loopEnd: where the file says the part of a sample that repeats ends.
private func gdm(rows: [UInt8] = [0x20, gdmC4, 1], origin: Int = 3, pans: [UInt8] = [8], samples: [(flags: UInt8, volume: UInt8, pan: UInt8)] = [(0x05, 64, 255)],
                 sound: [UInt8] = square, loopEnd: Int = 33, sixteenBit: Bool = false) -> [UInt8] {
    let pattern = rows + [UInt8](repeating: 0, count: 64)
    let header = 157
    let orderAt = header, patternAt = orderAt + 1, sampleHeaderAt = patternAt + 2 + pattern.count
    let soundAt = sampleHeaderAt + samples.count * 62
    var file: [UInt8] = [0x47, 0x44, 0x4D, 0xFE] + padded(Array("a square wave".utf8), to: 32) + padded(Array("nobody".utf8), to: 32)
    file += [13, 10, 26] + Array("GMFS".utf8) + [1, 0] + word(0) + [1, 20]
    file += padded(pans, to: 32).enumerated().map { $0.offset < pans.count ? $0.element : 255 }
    file += [64, 6, 125] + word(origin)
    file += long(orderAt) + [0] + long(patternAt) + [0] + long(sampleHeaderAt) + long(soundAt) + [UInt8(samples.count - 1)]
    file += long(0) + long(0) + long(0) + word(0) + long(0) + word(0)
    #expect(file.count == header)
    file += [0]
    file += word(pattern.count + 2) + pattern
    for sample in samples {
        file += padded(Array("square".utf8), to: 32) + [UInt8](repeating: 0, count: 13)
        file += long(sound.count) + long(0) + long(loopEnd) + [sample.flags | (sixteenBit ? 2 : 0)] + word(8363) + [sample.volume, sample.pan]
    }
    for _ in samples { file += sound }
    return file
}

/// A PTM file of one pattern and four channels, with one sample: a square wave of 32 samples, looping.
/// - Parameters:
///   - rows: the packed bytes of the pattern.
///   - type: the sample's: 1 for a sample, 4 that it loops, 8 back and forth, 16 for sixteen bits.
///   - sound: the sample's sound, signed, before it is written as differences.
private func ptm(rows: [UInt8] = [0x20, 49, 1], channels: Int = 4, pans: [UInt8] = [7, 7, 7, 7], type: UInt8 = 0x05,
                 sound: [UInt8] = (0 ..< 32).map { $0 < 16 ? 0x7F : 0x81 }, loopEnd: Int? = nil) -> [UInt8] {
    let pattern = rows + [UInt8](repeating: 0, count: 64)
    let patternAt = 608 + 80
    let soundAt = (patternAt + pattern.count + 15) & ~15
    var file = padded(Array("a square wave".utf8), to: 28) + [26, 3, 2, 0]
    file += word(2) + word(1) + word(1) + word(channels) + word(0) + word(0) + Array("PTMF".utf8) + [UInt8](repeating: 0, count: 16)
    file += padded(pans, to: 32) + padded([0, 255], to: 256) + padded(word(patternAt / 16), to: 256)
    #expect(file.count == 608)
    file += [type] + [UInt8](repeating: 0, count: 12) + [64] + word(8363) + word(0) + long(soundAt) + long(sound.count) + long(0) + long(loopEnd ?? sound.count)
    file += [UInt8](repeating: 0, count: 14) + padded(Array("square".utf8), to: 28) + Array("PTMS".utf8)
    file += padded(pattern, to: soundAt - patternAt)
    var last: UInt8 = 0
    for byte in sound {
        file.append(byte &- last)
        last = byte
    }
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

/// What a file's first pattern has on a row and channel, as Impulse Tracker was given it.
private func cell(_ file: [UInt8], _ format: TuneFormat, row: Int = 0, channel: Int = 0) throws -> ModuleListing.Cell? {
    let renderer = try #require(try TuneLoader.load(file, format: format) as? ITRenderer)
    return renderer.listing().cells.first { $0.pattern == 0 && $0.row == row && $0.channel == channel }
}

/// A GDM row of one channel with a command and no note.
private func gdmCommand(_ effect: UInt8, _ value: UInt8, origin: Int = 3) throws -> (command: Int, value: Int, volume: Int) {
    let found = try cell(gdm(rows: [0x40, effect, value], origin: origin), .gdm)
    return (found?.command ?? -1, found?.value ?? -1, found?.volume ?? -1)
}

private func letter(_ character: Character) -> Int {
    Int(character.asciiValue! - 64)
}

// MARK: GDM

@Test func gdmNoteSoundsAtItsPitch() throws {
    // C in octave 4 plays a sample at the rate it gives, 8363 samples a second, and the square wave
    // is 32 of them: 261 Hz.
    let renderer = try TuneLoader.load(gdm(), format: .gdm)
    #expect(renderer.info.format == "GDM")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.author == "nobody")
    #expect(renderer.info.detail == "BWSB 2GDM 1.20, from an S3M file")
    let sound = stereo(renderer, seconds: 1).left
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 261) <= 2)
    #expect(sound[4800...].map(abs).max()! > 0.02)
    // An octave up is twice that, and a sample of sixteen bits sounds the same as one of eight.
    let higher = stereo(try TuneLoader.load(gdm(rows: [0x20, 0x51, 1]), format: .gdm), seconds: 1).left
    #expect(abs(crossings(higher[4800...]) * 10 / 9 - 523) <= 3)
    let wide = stereo(try TuneLoader.load(gdm(sound: square.flatMap { [0, $0] }, loopEnd: 33, sixteenBit: true), format: .gdm), seconds: 1).left
    #expect(abs(crossings(wide[4800...]) * 10 / 9 - 261) <= 2)
    #expect(abs(loudness(wide[4800...]) / loudness(sound[4800...]) - 1) < 0.05)
    #expect(try TuneLoader.load(gdm(origin: 1), format: .gdm).info.detail == "BWSB 2GDM 1.20, from a MOD file")
}

@Test func gdmChannelIsHeardWhereItIsPlaced() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let left = stereo(try TuneLoader.load(gdm(pans: [0]), format: .gdm, options: options), seconds: 0.5)
    #expect(loudness(left.left[4800...]) > 0.02 && loudness(left.right[4800...]) < 0.002)
    let right = stereo(try TuneLoader.load(gdm(pans: [15]), format: .gdm, options: options), seconds: 0.5)
    #expect(loudness(right.right[4800...]) > 0.02 && loudness(right.left[4800...]) < 0.002)
    // A sample with a place of its own puts its channel there, if the file says to use it.
    let moved = stereo(try TuneLoader.load(gdm(pans: [0], samples: [(0x0D, 64, 15)]), format: .gdm, options: options), seconds: 0.5)
    #expect(loudness(moved.right[4800...]) > 0.02 && loudness(moved.left[4800...]) < 0.002)
    let unmoved = stereo(try TuneLoader.load(gdm(pans: [0], samples: [(0x05, 64, 15)]), format: .gdm, options: options), seconds: 0.5)
    #expect(loudness(unmoved.left[4800...]) > 0.02 && loudness(unmoved.right[4800...]) < 0.002)
    // In mono the two sides are one, and a channel that is not used is not heard.
    let mono = stereo(try TuneLoader.load(gdm(pans: [0]), format: .gdm), seconds: 0.5)
    #expect(mono.left == mono.right && loudness(mono.left[4800...]) > 0.01)
    let unused = stereo(try TuneLoader.load(gdm(rows: [0x21, gdmC4, 1], pans: [8]), format: .gdm), seconds: 0.5)
    #expect(loudness(unused.left[4800...]) == 0)
    #expect(try TuneLoader.load(gdm(pans: [0, 15, 16]), format: .gdm).channelCount == 1)
}

@Test func gdmCommandsAreGivenAsImpulseTrackers() throws {
    // ProTracker's by number, as the letters that do the same.
    #expect(try gdmCommand(0x01, 0x20) == (letter("F"), 0x20, -1))
    #expect(try gdmCommand(0x02, 0xF3) == (letter("E"), 0xDF, -1)) // not to be read as a fine slide
    #expect(try gdmCommand(0x03, 0x10) == (letter("G"), 0x10, -1))
    #expect(try gdmCommand(0x09, 0x12) == (letter("O"), 0x12, -1))
    #expect(try gdmCommand(0x0B, 0x02) == (letter("B"), 0x02, -1))
    #expect(try gdmCommand(0x0D, 0x32) == (letter("C"), 32, -1)) // in tens and units
    #expect(try gdmCommand(0x0F, 0x80) == (letter("A"), 0x80, -1))
    #expect(try gdmCommand(0x10, 0x47) == (letter("J"), 0x47, -1))
    #expect(try gdmCommand(0x12, 0x93) == (letter("Q"), 0x93, -1))
    #expect(try gdmCommand(0x13, 0x20) == (letter("V"), 0x40, -1)) // of 128, where the file's is of 64
    #expect(try gdmCommand(0x14, 0x47) == (letter("U"), 0x47, -1))
    #expect(try gdmCommand(0x1F, 0x90) == (letter("T"), 0x90, -1))
    #expect(try gdmCommand(0x1F, 0x10).command == -1) // which would be a slide of tempo
    // The lesser ones.
    #expect(try gdmCommand(0x0E, 0x13) == (letter("F"), 0xF3, -1))
    #expect(try gdmCommand(0x0E, 0x93) == (letter("E"), 0xE3, -1))
    #expect(try gdmCommand(0x0E, 0xA3) == (letter("D"), 0x3F, -1))
    #expect(try gdmCommand(0x0E, 0xBF) == (letter("D"), 0xFE, -1))
    #expect(try gdmCommand(0x0E, 0x62) == (letter("S"), 0xB2, -1))
    #expect(try gdmCommand(0x0E, 0xD3) == (letter("S"), 0xD3, -1))
    #expect(try gdmCommand(0x0E, 0xD0).command == -1)
    #expect(try gdmCommand(0x0E, 0x31).command == -1 && gdmCommand(0x0E, 0x52).command == -1)
    #expect(try gdmCommand(0x1E, 0x01) == (letter("S"), 0x91, -1))
    // A volume goes in the volume column, and so does a place between the speakers.
    #expect(try gdmCommand(0x0C, 0x30) == (-1, -1, 0x30))
    #expect(try gdmCommand(0x0C, 0x7F) == (-1, -1, 64))
    #expect(try gdmCommand(0x1E, 0x8F) == (-1, -1, 128 + 64))

    // A slide of nought goes on with the last in Scream Tracker, and in ProTracker does nothing.
    #expect(try gdmCommand(0x0A, 0x00, origin: 3) == (letter("D"), 0, -1))
    #expect(try gdmCommand(0x0A, 0x00, origin: 1).command == -1)
    #expect(try gdmCommand(0x06, 0x00, origin: 1) == (letter("H"), 0, -1))
    // Both up and down: down in Scream Tracker, up in ProTracker.
    #expect(try gdmCommand(0x0A, 0x24, origin: 3) == (letter("D"), 0x04, -1))
    #expect(try gdmCommand(0x0A, 0x24, origin: 1) == (letter("D"), 0x20, -1))
    #expect(try gdmCommand(0x0A, 0x2F, origin: 3) == (letter("D"), 0x2F, -1))
}

@Test func gdmNoteWithSeveralCommandsKeepsWhatImpulseTrackerHasRoomFor() throws {
    // A volume and a command: both.
    var found = try #require(try cell(gdm(rows: [0x60, gdmC4, 1, 0x2C, 0x20, 0x4A, 0x03]), .gdm))
    #expect(found.note == 60 && found.instrument == 1 && found.volume == 0x20 && found.command == letter("D") && found.value == 0x03)
    // Two commands: the one the volume column can do goes there.
    found = try #require(try cell(gdm(rows: [0x60, gdmC4, 1, 0x29, 0x08, 0x4A, 0x03]), .gdm))
    #expect(found.command == letter("O") && found.value == 0x08 && found.volume == 95 + 3)
    // A place between the speakers beside a volume has the command's place.
    found = try #require(try cell(gdm(rows: [0x40, 0x2C, 0x20, 0x5E, 0x80]), .gdm))
    #expect(found.volume == 0x20 && found.command == letter("S") && found.value == 0x80)
    // A row that comes back to a channel adds to what it gave it.
    found = try #require(try cell(gdm(rows: [0x20, gdmC4, 1, 0x40, 0x0C, 0x10]), .gdm))
    #expect(found.note == 60 && found.instrument == 1 && found.volume == 0x10)
}

@Test func gdmInstrumentWithoutANoteIsItsVolumeAndNoMore() throws {
    // Row 0 a note; row 1 the instrument alone, which Impulse Tracker would take for the note again.
    let file = gdm(rows: [0x20, gdmC4, 1, 0, 0x20, 0, 2, 0, 0x20, 0x45, 0], samples: [(0x05, 64, 255), (0x05, 40, 255)])
    let alone = try #require(try cell(file, .gdm, row: 1))
    #expect(alone.note == -1 && alone.instrument == -1 && alone.volume == 40)
    // The next note that names none is given the instrument that was named, and the volume.
    let after = try #require(try cell(file, .gdm, row: 2))
    #expect(after.note == 64 && after.instrument == 2 && after.volume == 40)

    // A sample with no volume of its own leaves the channel's where it was.
    let quiet = gdm(rows: [0x60, gdmC4, 1, 0x0C, 0x10, 0, 0x20, gdmC4, 2], samples: [(0x05, 64, 255), (0x01, 64, 255)])
    let kept = try #require(try cell(quiet, .gdm, row: 1))
    #expect(kept.instrument == 2 && kept.volume == 0x10)

    // In a tune from a MOD file a slide to a note starts nothing on a channel that has played nothing.
    #expect(try #require(try cell(gdm(rows: [0x60, gdmC4, 1, 0x03, 0x10], origin: 1), .gdm)).note == -1)
    #expect(try #require(try cell(gdm(rows: [0x60, gdmC4, 1, 0x03, 0x10], origin: 3), .gdm)).note == 60)
}

@Test func gdmPatternIsWrittenOutAgainWhereALaterPlaceNeedsItOtherwise() throws {
    // One pattern, played twice: a slide to a note on its first row, and a note on its second. In a
    // tune from a MOD file the first time through there is nothing to slide, and the second there is.
    var file = gdm(rows: [0x60, gdmC4, 1, 0x03, 0x10, 0, 0x20, 0x45, 1], origin: 1)
    // (A second place in the list, naming the same pattern: the list is moved to the end of the file.)
    file[118 ..< 122] = ArraySlice(long(file.count))
    file[122] = 1
    file += [0, 0]
    let listing = try #require(try TuneLoader.load(file, format: .gdm) as? ITRenderer).listing()
    #expect(Array(listing.orders.prefix(3)) == [0, 1, 255])
    #expect(listing.cells.first { $0.pattern == 0 && $0.row == 0 }?.note == -1)
    #expect(listing.cells.first { $0.pattern == 1 && $0.row == 0 }?.note == 60)
    // A pattern that comes out the same is not written out again.
    var same = gdm()
    same[118 ..< 122] = ArraySlice(long(same.count))
    same[122] = 1
    same += [0, 0]
    #expect(Array(try #require(try TuneLoader.load(same, format: .gdm) as? ITRenderer).listing().orders.prefix(3)) == [0, 0, 255])

    // A note cut short in a tune from a MOD file was only turned down, and naming its instrument
    // brought it back: here the instrument is left for Impulse Tracker to play the note again.
    let cut = gdm(rows: [0x60, gdmC4, 1, 0x0E, 0xC2, 0, 0x60, 0, 1, 0x0E, 0xC2], origin: 1)
    #expect(try #require(try cell(cut, .gdm, row: 1)).instrument == 1)
    #expect(try #require(try cell(gdm(rows: [0x60, gdmC4, 1, 0x0E, 0xC2, 0, 0x60, 0, 1, 0x0E, 0xC2], origin: 3), .gdm, row: 1)).instrument == -1)
}

@Test func gdmSampleRepeatsOverOneSampleFewerThanWritten() throws {
    var renderer = try #require(try TuneLoader.load(gdm(), format: .gdm) as? ITRenderer)
    #expect(renderer.listing().samples[0].loops && renderer.listing().samples[0].loopEnd == 32 && renderer.listing().samples[0].length == 32)
    renderer = try #require(try TuneLoader.load(gdm(loopEnd: 17), format: .gdm) as? ITRenderer)
    #expect(renderer.listing().samples[0].loopEnd == 16)
    renderer = try #require(try TuneLoader.load(gdm(samples: [(0x04, 64, 255)], loopEnd: 1), format: .gdm) as? ITRenderer)
    #expect(!renderer.listing().samples[0].loops)
}

@Test func gdmFilesThatAreOddOrNotGDMAtAll() throws {
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0, count: 200), format: .gdm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(gdm().prefix(60)), format: .gdm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(gdm(samples: [(0x15, 64, 255)]), format: .gdm) } // a compressed sample
    // A file that ends too soon is played with what there is of it, and nonsense is never a trap.
    let whole = gdm(rows: [0x60, gdmC4, 1, 0x2C, 0x20, 0x4A, 0x03], samples: [(0x05, 64, 255), (0x0D, 64, 3)])
    for length in stride(from: 80, to: whole.count, by: 7) {
        if let renderer = try? TuneLoader.load(Array(whole.prefix(length)), format: .gdm) { _ = stereo(renderer, seconds: 0.05) }
    }
    var seed: UInt32 = 7
    for _ in 0 ..< 300 {
        var damaged = whole
        for _ in 0 ..< 6 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let at = 75 + Int(seed >> 8) % (damaged.count - 75)
            damaged[at] = UInt8(truncatingIfNeeded: seed >> 3)
        }
        if let renderer = try? TuneLoader.load(damaged, format: .gdm) { _ = stereo(renderer, seconds: 0.05) }
    }
}

// MARK: PTM

@Test func ptmNoteSoundsAtItsPitch() throws {
    // C-4, the note numbered 49, plays a sample at the rate it gives: 261 Hz for this one.
    let renderer = try TuneLoader.load(ptm(), format: .ptm)
    #expect(renderer.info.format == "PTM")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "PolyTracker 2.03")
    #expect(renderer.channelCount == 1)
    let sound = stereo(renderer, seconds: 1).left
    // (The part that repeats is a sample shorter than the file says, as PolyTracker's was.)
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 8363 / 31) <= 2)
    #expect(sound[4800...].map(abs).max()! > 0.02)
    let higher = stereo(try TuneLoader.load(ptm(rows: [0x20, 61, 1]), format: .ptm), seconds: 1).left
    #expect(abs(crossings(higher[4800...]) * 10 / 9 - 2 * 8363 / 31) <= 3)

    // A sample of sixteen bits is kept as differences byte by byte, and its lengths are in bytes.
    let wide = try TuneLoader.load(ptm(type: 0x15, sound: (0 ..< 64).map { $0 < 32 ? ($0 & 1 == 0 ? 0x00 : 0x7F) : ($0 & 1 == 0 ? 0x00 : 0x81) }), format: .ptm)
    let listed = try #require(wide as? ITRenderer).listing().samples[0]
    #expect(listed.sixteenBit && listed.length == 32 && listed.loopEnd == 31 && listed.loops && !listed.backAndForth)
    let wideSound = stereo(wide, seconds: 1).left
    #expect(abs(crossings(wideSound[4800...]) * 10 / 9 - 8363 / 31) <= 2)
    #expect(abs(loudness(wideSound[4800...]) / loudness(sound[4800...]) - 1) < 0.05)

    // Back and forth takes twice as long to come round.
    let backAndForth = stereo(try TuneLoader.load(ptm(type: 0x0D), format: .ptm), seconds: 1).left
    #expect(try #require(try TuneLoader.load(ptm(type: 0x0D), format: .ptm) as? ITRenderer).listing().samples[0].backAndForth)
    #expect(crossings(backAndForth[4800...]) < crossings(sound[4800...]) * 2 / 3)
}

@Test func ptmChannelIsHeardWhereItIsPlaced() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let left = stereo(try TuneLoader.load(ptm(pans: [0, 7, 7, 7]), format: .ptm, options: options), seconds: 0.5)
    #expect(loudness(left.left[4800...]) > 0.02 && loudness(left.right[4800...]) < 0.002)
    let right = stereo(try TuneLoader.load(ptm(pans: [15, 7, 7, 7]), format: .ptm, options: options), seconds: 0.5)
    #expect(loudness(right.right[4800...]) > 0.02 && loudness(right.left[4800...]) < 0.002)
    let mono = stereo(try TuneLoader.load(ptm(pans: [15, 7, 7, 7]), format: .ptm), seconds: 0.5)
    #expect(mono.left == mono.right && loudness(mono.left[4800...]) > 0.01)
}

@Test func ptmCommandsAreGivenAsImpulseTrackers() throws {
    func command(_ effect: UInt8, _ value: UInt8) throws -> (command: Int, value: Int, volume: Int) {
        let found = try cell(ptm(rows: [0x40, effect, value]), .ptm)
        return (found?.command ?? -1, found?.value ?? -1, found?.volume ?? -1)
    }
    #expect(try command(0x00, 0x37) == (letter("J"), 0x37, -1))
    #expect(try command(0x01, 0xF2) == (letter("F"), 0xF2, -1)) // fine slides are inside the slides, as in Impulse Tracker
    #expect(try command(0x02, 0x10) == (letter("E"), 0x10, -1))
    #expect(try command(0x0A, 0x0F) == (letter("D"), 0x0F, -1))
    #expect(try command(0x0C, 0x50) == (-1, -1, 64))
    #expect(try command(0x0D, 0x20) == (letter("C"), 0x20, -1))
    #expect(try command(0x0E, 0x8C) == (letter("S"), 0x8C, -1))
    #expect(try command(0x0E, 0x93) == (letter("Q"), 0x03, -1))
    #expect(try command(0x0F, 0x1F) == (letter("A"), 0x1F, -1))
    #expect(try command(0x0F, 0x20) == (letter("T"), 0x20, -1))
    #expect(try command(0x10, 0x40) == (letter("V"), 0x80, -1))
    #expect(try command(0x11, 0x93) == (letter("Q"), 0x93, -1))
    #expect(try command(0x12, 0x47) == (letter("U"), 0x47, -1))
    #expect(try command(0x13, 0x24).command == -1) // a slide by semitones, with no note to slide
    #expect(try command(0x09, 0x10) == (letter("O"), 0x10, -1))

    // A note with its volume after its command, which is how the file has them.
    let found = try #require(try cell(ptm(rows: [0xE0, 49, 1, 0x0A, 0x04, 33]), .ptm))
    #expect(found.note == 48 && found.instrument == 1 && found.volume == 33 && found.command == letter("D") && found.value == 0x04)
    #expect(try #require(try cell(ptm(rows: [0x20, 254, 0]), .ptm)).note == 254)
    // The offset into a sample of sixteen bits is in bytes.
    let wide = ptm(rows: [0x60, 49, 1, 0x09, 0x10], type: 0x11, sound: [UInt8](repeating: 0x10, count: 64))
    #expect(try #require(try cell(wide, .ptm)).value == 0x08)
}

@Test func ptmSlideBySemitonesIsASmoothSlideThatGetsAsFar() throws {
    // Up four semitones on every second tick: twice in a row of six ticks, which is eight semitones,
    // and as many again on the row after.
    let file = ptm(rows: [0x60, 49, 1, 0x13, 0x24, 0, 0x40, 0x13, 0x00])
    let found = try #require(try cell(file, .ptm))
    #expect(found.command == letter("F"))
    let ticks = try #require(try TuneLoader.load(file, format: .ptm) as? ITRenderer).ticks(seconds: 0.5)
    let before = Double(ticks[0].rates[0]), after = Double(ticks[6].rates[0]), later = Double(ticks[12].rates[0])
    #expect(before == 8363)
    // (As near as a smooth slide's steps can get: within a quarter of a semitone up here.)
    #expect(abs(after / before / 1.5874 - 1) < 0.015 && abs(later / before / 2.5198 - 1) < 0.015)
    // Down is the command after it.
    #expect(try #require(try cell(ptm(rows: [0x60, 49, 1, 0x14, 0x24]), .ptm)).command == letter("E"))
}

@Test func ptmSamplePlayedBackwardsIsASampleWrittenOutBackwards() throws {
    // A sample that is silent and then a square wave: forwards it starts silent, backwards loud.
    let sound = [UInt8](repeating: 0, count: 6000) + (0 ..< 6000).map { ($0 / 16) & 1 == 0 ? UInt8(0x7F) : 0x81 }
    var options = LoadOptions()
    options.stereo = .abc
    let forwards = stereo(try TuneLoader.load(ptm(type: 0x01, sound: sound), format: .ptm, options: options), seconds: 0.5).left
    let backwards = try TuneLoader.load(ptm(rows: [0x60, 49, 1, 0x17, 0x00], type: 0x01, sound: sound), format: .ptm, options: options)
    let heard = stereo(backwards, seconds: 1.1).left
    // (PolyTracker began it again on every tick of its row, so the row is the sample's end six times;
    // then it goes on back through the square wave, which lasts seven tenths of a second, to the silence.)
    #expect(loudness(forwards[1000 ..< 5000]) < 0.001 && loudness(heard[1000 ..< 5000]) > 0.02)
    #expect(loudness(heard[20000 ..< 24000]) > 0.02 && loudness(heard[46000 ..< 50000]) < 0.001)

    let listing = try #require(backwards as? ITRenderer).listing()
    let found = try #require(listing.cells.first)
    #expect(found.instrument == 2 && found.command == letter("Q") && found.value == 1)
    #expect(listing.samples[1].length == 12000 && !listing.samples[1].loops)
    // From some way before the end, it is that much shorter.
    let part = try #require(try TuneLoader.load(ptm(rows: [0x60, 49, 1, 0x17, 0x10], type: 0x01, sound: sound), format: .ptm) as? ITRenderer)
    #expect(part.listing().samples[1].length == 12000 - 0x1000)
}

@Test func ptmFilesThatAreOddOrNotPTMAtAll() throws {
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0, count: 700), format: .ptm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(ptm().prefix(100)), format: .ptm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(ptm(channels: 33), format: .ptm) }
    let whole = ptm(rows: [0xE0, 49, 1, 0x17, 0x00, 33, 0x61, 49, 1, 0x09, 0x01])
    for length in stride(from: 608, to: whole.count, by: 5) {
        if let renderer = try? TuneLoader.load(Array(whole.prefix(length)), format: .ptm) { _ = stereo(renderer, seconds: 0.05) }
    }
    var seed: UInt32 = 11
    for _ in 0 ..< 300 {
        var damaged = whole
        for _ in 0 ..< 6 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            var at = Int(seed >> 8) % damaged.count
            if at >= 44, at < 48 { at += 4 } // (the four letters that say what it is)
            damaged[at] = UInt8(truncatingIfNeeded: seed >> 3)
        }
        if let renderer = try? TuneLoader.load(damaged, format: .ptm) { _ = stereo(renderer, seconds: 0.05) }
    }
}

// MARK: A number that goes on from another kind of command

@Test func gdmCommandGoesOnFromTheLastNumberOfAnyKindAsInScreamTracker() throws {
    // A note with a vibrato of 11, and on the next row a vibrato with a slide of volume by nought.
    // Scream Tracker goes on from the last number given to any command, the vibrato's, and so
    // fades the note by one a tick; Impulse Tracker would go on from the last slide of volume, of
    // which there is none, and hold it. So the slide is given the number outright.
    let held = try #require(try TuneLoader.load(gdm(rows: [0x60, gdmC4, 1, 0x04, 0x11, 0, 0x40, 0x06, 0x00]), format: .gdm) as? ITRenderer)
    let slide = try #require(held.listing().cells.first { $0.pattern == 0 && $0.row == 1 && $0.channel == 0 })
    #expect(slide.command == 11 && slide.value == 0x01)
    // A slide of pitch by nought after a slide of volume takes the whole number.
    let slid = try #require(try TuneLoader.load(gdm(rows: [0x60, gdmC4, 1, 0x0A, 0x03, 0, 0x40, 0x02, 0x00]), format: .gdm) as? ITRenderer)
    let pitch = try #require(slid.listing().cells.first { $0.pattern == 0 && $0.row == 1 && $0.channel == 0 })
    #expect(pitch.command == 5 && pitch.value == 0x03)
    // One that goes on from its own kind is left as it is, for Impulse Tracker to go on with.
    let own = try #require(try TuneLoader.load(gdm(rows: [0x60, gdmC4, 1, 0x0A, 0x03, 0, 0x40, 0x0A, 0x00]), format: .gdm) as? ITRenderer)
    let same = try #require(own.listing().cells.first { $0.pattern == 0 && $0.row == 1 && $0.channel == 0 })
    #expect(same.command == 4 && same.value == 0)
    // And in a tune from a MOD file a slide by nought is no slide at all.
    let mod = try #require(try TuneLoader.load(gdm(rows: [0x60, gdmC4, 1, 0x04, 0x11, 0, 0x40, 0x0A, 0x00], origin: 1), format: .gdm) as? ITRenderer)
    #expect(mod.listing().cells.first { $0.pattern == 0 && $0.row == 1 && $0.channel == 0 }.map { $0.command <= 0 } ?? true)
}

// MARK: What is not played as the file asks

@Test func gdmAndPTMSayWhatImpulseTrackerLeavesOut() throws {
    #expect(try TuneLoader.load(gdm(), format: .gdm).info.shortfalls.isEmpty)
    #expect(try TuneLoader.load(ptm(), format: .ptm).info.shortfalls.isEmpty)

    // GDM: sliding by semitones and retuning a sample, which Impulse Tracker cannot do.
    #expect(try TuneLoader.load(gdm(rows: [0x60, gdmC4, 1, 0x2E, 0x31, 0x4E, 0x53]), format: .gdm).info.shortfalls
        == ["Two of its commands are left out: sliding by semitones and the retuning of a sample."])
    // Three commands that are none of them the volume column's: one has the command's place.
    #expect(try TuneLoader.load(gdm(rows: [0x60, gdmC4, 1, 0x29, 0x10, 0x67, 0x33, 0x92, 0x21]), format: .gdm).info.shortfalls
        == ["Some of its rows have more commands for a channel than Impulse Tracker has room for, and the rest are left out."])
    // (A tune from Scream Tracker whose slide of volume goes on from a number given to a slide of
    // pitch is played as Scream Tracker played it, and has nothing to say: see below.)
    #expect(try TuneLoader.load(gdm(rows: [0x60, gdmC4, 1, 0x02, 0x08, 0, 0x40, 0x0A, 0x00]), format: .gdm).info.shortfalls.isEmpty)
    #expect(try TuneLoader.load(gdm(rows: [0x60, gdmC4, 1, 0x02, 0x08, 0, 0x40, 0x0A, 0x00], origin: 1), format: .gdm).info.shortfalls.isEmpty)

    // PTM: a slide by steps, which is played smooth, and a sample played backwards with no note.
    #expect(try TuneLoader.load(ptm(rows: [0x60, 49, 1, 0x13, 0x24]), format: .ptm).info.shortfalls
        == ["Its notes are slid smoothly where PolyTracker slid them by steps."])
    #expect(try TuneLoader.load(ptm(rows: [0x60, 49, 1, 0x15, 0x24]), format: .ptm).info.shortfalls
        == ["Its notes are slid smoothly where PolyTracker slid them by steps, and are not struck again at each step."])
    #expect(try TuneLoader.load(ptm(rows: [0x40, 0x17, 0x00]), format: .ptm).info.shortfalls
        == ["One of its commands to play a sample backwards has no note to play, and is left out."])
}
