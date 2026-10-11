// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of the three kinds of module that are read into FastTracker's replayer: MTM, DTM and
// AMF. There is no player of their own trackers to compare with to the sample. The thorough checks
// are made outside the package, against libxmp and OpenMPT: what each made of every file
// (`SIDAY_FT2_LISTING=1 siday --raw /dev/null tune.mtm` writes what this player made of one), and
// how alike the three sound.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func bigWord(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func bigLong(_ value: Int) -> [UInt8] { bigWord(value >> 16 & 0xFFFF) + bigWord(value & 0xFFFF) }
private func padded(_ text: String, _ length: Int) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: length - text.utf8.count) }

/// A square wave of 32 samples, eight times over, signed.
private let square = (0 ..< 256).map { UInt8(bitPattern: $0 % 32 < 16 ? 100 : -100) as UInt8 }

private func stereo(_ renderer: any Renderer, seconds: Double) -> (left: [Float], right: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

/// How many times a second the sound crosses from below nought to above, from a tenth of a second in.
private func pitch(_ samples: [Float]) -> Int {
    let heard = samples[4800...]
    return zip(heard, heard.dropFirst()).count { $0 < 0 && $1 >= 0 } * outputSampleRate / heard.count
}

private func loudest(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

private var inStereo: LoadOptions {
    var options = LoadOptions()
    options.stereo = .abc
    return options
}

// MARK: MTM

/// An MTM file of two channels and one pattern, with one sample, the square wave, repeating.
/// - Parameters:
///   - rows: the notes of the first channel's track, by row: the three bytes of each.
///   - second: and of the second channel's.
///   - places: where the two channels are, each one of sixteen places.
///   - fineTune: the sample's.
private func mtm(rows: [Int: [UInt8]] = [0: [24 << 2, 0x10, 0]], second: [Int: [UInt8]] = [:], places: [UInt8] = [0, 15], fineTune: UInt8 = 0) -> [UInt8] {
    var file = Array("MTM".utf8) + [0x10] + padded("a square wave", 20) + word(2) + [0, 0] + word(0) + [1, 0, 64, 2]
    file += places + [UInt8](repeating: 0, count: 32 - places.count)
    file += padded("square", 22) + long(256) + long(0) + long(256) + [fineTune, 64, 0]
    file += [UInt8](repeating: 0, count: 128)
    for track in [rows, second] {
        var bytes = [UInt8](repeating: 0, count: 192)
        for (row, note) in track { bytes.replaceSubrange(row * 3 ..< row * 3 + 3, with: note) }
        file += bytes
    }
    file += word(1) + word(2) + [UInt8](repeating: 0, count: 60)
    return file + square.map { $0 ^ 0x80 }
}

@Test func mtmNoteSoundsAtItsPitchWhereItsChannelIs() throws {
    // Note 24 is the C that plays a sample at 8363 samples a second, and the wave is 32 of them: 261 Hz.
    let renderer = try TuneLoader.load(mtm(), format: .mtm, options: inStereo)
    #expect(renderer.info.format == "MTM")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "MultiTracker 1.0, 2 channels")
    #expect(!renderer.isPlayedOnAnAmiga)
    #expect(renderer.channelCount == 2)
    #expect(abs(renderer.knownLength! - 7.68) < 0.001)
    let sound = stereo(renderer, seconds: 1)
    #expect(abs(pitch(sound.left) - 261) <= 2)
    #expect(loudest(sound.left) > 0.05)
    // The first channel is hard left: there is none of it on the right.
    #expect(loudest(sound.right) < 0.0001)

    // An octave up is twice that, and the same note on the second channel is on the right: as far
    // right as FastTracker goes, which leaves a sixteenth of it on the left.
    let higher = stereo(try TuneLoader.load(mtm(rows: [:], second: [0: [36 << 2, 0x10, 0]]), format: .mtm, options: inStereo), seconds: 1)
    #expect(abs(pitch(higher.right) - 523) <= 3)
    #expect(loudest(higher.left) < loudest(higher.right) / 12)

    // In mono it is the same on both sides wherever its channel is.
    let mono = stereo(try TuneLoader.load(mtm(), format: .mtm), seconds: 0.5)
    #expect(mono.left == mono.right)
    #expect(loudest(mono.left) > 0.02)
}

@Test func mtmChannelStaysWhereACommandPutsIt() throws {
    // E8F on the first row puts the first channel hard right, and it is still there for a note
    // struck later with nothing said, which in FastTracker's own files would go back to the
    // sample's place.
    let moved = try TuneLoader.load(mtm(rows: [0: [24 << 2, 0x1E, 0x8F], 8: [24 << 2, 0x10, 0]]), format: .mtm, options: inStereo)
    let sound = stereo(moved, seconds: 2)
    #expect(loudest(Array(sound.right[60000...])) > 0.05)
    #expect(loudest(sound.left) < loudest(sound.right) / 12)
}

@Test func mtmCommandsAreMadeFastTrackers() throws {
    let module = try MTMFile.read(mtm(rows: [
        0: [0, 0x0D, 0x30], // a break to row 48, a plain number
        1: [0, 0x08, 0x40], // the other players' panning: 40 is the middle
        2: [0, 0x08, 0xA4], // and A4 their surround
        3: [0, 0x0E, 0x61], // a loop, which MultiTracker has not got
        4: [0, 0x01, 0x00], // a slide by nothing
        5: [0, 0x0C, 0x50], // a volume past the loudest
        6: [0, 0x0E, 0x84], // one of sixteen places
        7: [63 << 2 | 3, 0xF0, 0], // the highest note, instrument 63
    ]))
    let notes = module.patterns[0].notes
    func command(_ row: Int) -> [UInt8] { [notes[row * 2].effTyp, notes[row * 2].eff] }
    #expect(command(0) == [0xD, 0x48])
    #expect(command(1) == [8, 0x80])
    #expect(command(2) == [8, 128])
    #expect(command(3) == [0, 0])
    #expect(command(4) == [0, 0])
    #expect(command(5) == [0xC, 64])
    #expect(command(6) == [8, 68])
    #expect(notes[14].ton == 88 && notes[14].instr == 63)
    #expect(module.panning == [0, 255])
    #expect(!module.speedAndTempoUndoEachOther)

    // A speed and a tempo, never on one row: MultiTracker's own way, where each undoes the other.
    #expect(try MTMFile.read(mtm(rows: [0: [0, 0x0F, 0x03], 8: [0, 0x0F, 0x90]])).speedAndTempoUndoEachOther)
    // On one row, both hold, as in the players that did not know of it.
    #expect(try !MTMFile.read(mtm(rows: [0: [0, 0x0F, 0x03]], second: [0: [0, 0x0F, 0x90]])).speedAndTempoUndoEachOther)

    // The tempo of 144 lasts eight rows, and then a speed of 3 puts it back to 125: 8 rows of 6 ticks
    // at 144, then 56 rows of 3 ticks at 125. Without the rule the rest would stay at 144.
    let undone = try TuneLoader.load(mtm(rows: [0: [0, 0x0F, 0x90], 8: [0, 0x0F, 0x03]]), format: .mtm)
    #expect(abs(undone.knownLength! - (8 * 6 * 2.5 / 144 + 56 * 3 * 0.02)) < 0.01)
}

@Test func mtmFineTuneIsAMODFilesOrASignedByte() throws {
    // Two eighths of a semitone down, written as a MOD file writes it and as a signed byte.
    #expect(try MTMFile.read(mtm(fineTune: 0x0E)).samples[0]!.fineTune == -32)
    #expect(try MTMFile.read(mtm(fineTune: 0xFE)).samples[0]!.fineTune == -32)
    #expect(try MTMFile.read(mtm(fineTune: 0x07)).samples[0]!.fineTune == 112)
}

// MARK: DTM

private func chunk(_ name: String, _ bytes: [UInt8]) -> [UInt8] { Array(name.utf8) + bigLong(bytes.count) + bytes }

/// A DTM file of two channels and one pattern, with one sample, the square wave.
/// - Parameters:
///   - rows: the four bytes of each note of the first channel, by row.
///   - packing: how the patterns say they are kept: nothing, for as a MOD file keeps them.
///   - panoramic: which of the tracker's two ways with stereo.
///   - version: what a VERS chunk says, if there is to be one, with the places of the two channels.
///   - bits, sides, rate: of the sample.
///   - rateOfAll: the rate the file gives for all its samples, which the earliest versions go by.
private func dtm(rows: [Int: [UInt8]] = [0: [0x41, 0, 0x10, 0]], packing: String = "2.04", panoramic: Bool = true, version: Int? = nil, places: [Int] = [90, 90],
                 bits: Int = 8, sides: Int = 1, rate: Int = 8363, rateOfAll: Int = 0) -> [UInt8]
{
    let name = padded("a square wave", 14)
    var file = Array("D.T.".utf8) + bigLong(14 + name.count) + bigWord(0) + [panoramic ? 0xFF : 0, 8] + bigWord(0) + bigWord(6) + bigWord(125) + bigLong(rateOfAll) + name
    file += chunk("S.Q.", bigWord(1) + bigWord(0) + bigLong(0) + [UInt8](repeating: 0, count: 128))
    file += chunk("PATT", bigWord(2) + bigWord(1) + (packing.isEmpty ? [0, 0, 0, 0] : Array(packing.utf8)))
    if let version {
        file += chunk("VERS", bigLong(version))
        file += chunk("SV19", bigWord(24) + bigLong(0) + places.flatMap(bigWord) + [UInt8](repeating: 0, count: 64 - places.count * 2))
    }
    // The sound: the square wave at the width and with the sides asked for, the high byte first.
    var sound: [UInt8] = []
    for value in square {
        for side in 0 ..< sides {
            // (In stereo the right is the left turned over, so that the two make nothing together.)
            let one = side == 0 ? value : UInt8(bitPattern: -Int8(bitPattern: value))
            sound += bits == 16 ? [one, 0] : [one]
        }
    }
    var record = bigLong(0) + bigLong(sound.count) + [0, 64] + bigLong(0) + bigLong(sound.count) + padded("square", 22)
    record += [sides == 2 ? 1 : 0, UInt8(bits)] + bigWord(48) + bigWord(0) + bigLong(rate)
    file += chunk("INST", bigWord(1) + record)
    var pattern = [UInt8](repeating: 0, count: 64 * 2 * 4)
    for (row, note) in rows { pattern.replaceSubrange(row * 8 ..< row * 8 + 4, with: note) }
    file += chunk("DAPT", bigLong(0xFFFF_FFFF) + bigWord(0) + bigWord(64) + pattern)
    return file + chunk("DAIT", bigWord(0) + sound)
}

@Test func dtmNoteSoundsAtItsSamplesOwnRate() throws {
    // Note 41, the first of the fourth octave, plays a sample at the rate it says it was recorded at.
    let renderer = try TuneLoader.load(dtm(), format: .dtm, options: inStereo)
    #expect(renderer.info.format == "DTM")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "Digital Tracker 2.04, 2 channels")
    #expect(!renderer.isPlayedOnAnAmiga)
    let sound = stereo(renderer, seconds: 1)
    #expect(abs(pitch(sound.left) - 261) <= 2)
    // The panoramic way starts every channel in the middle.
    #expect(sound.left == sound.right)

    // A sample recorded at 22050 Hz plays that much faster for the same note: 689 Hz.
    #expect(abs(pitch(stereo(try TuneLoader.load(dtm(rate: 22050), format: .dtm), seconds: 1).left) - 689) <= 4)
    // And a slide of the pitch is the same slide whatever the rate: down from period 428 by two
    // for each of five ticks, on every row, a second in is the same part of the way down.
    let slid = stereo(try TuneLoader.load(dtm(rows: Dictionary(uniqueKeysWithValues: (0 ..< 64).map { ($0, $0 == 0 ? [0x41, 0, 0x12, 2] : [0, 0, 0x02, 2]) }), rate: 16726),
                                          format: .dtm), seconds: 1.2)
    let slow = stereo(try TuneLoader.load(dtm(rows: Dictionary(uniqueKeysWithValues: (0 ..< 64).map { ($0, $0 == 0 ? [0x41, 0, 0x12, 2] : [0, 0, 0x02, 2]) })), format: .dtm),
                      seconds: 1.2)
    func late(_ samples: [Float]) -> Int { zip(samples[48000...], samples[48001...]).count { $0 < 0 && $1 >= 0 } }
    #expect(abs(late(slid.left) - late(slow.left) * 2) <= 2)
    #expect(late(slow.left) < 261 / 5 - 2)
}

@Test func dtmSamplesOfSixteenBitsAndInStereoArePlayed() throws {
    let wide = stereo(try TuneLoader.load(dtm(bits: 16), format: .dtm), seconds: 1)
    #expect(abs(pitch(wide.left) - 261) <= 2)
    #expect(loudest(wide.left) > 0.02)
    // A stereo sample is made one sound; this one's sides are each other turned over, and make silence.
    let both = try DTMFile.read(dtm(sides: 2))
    #expect(both.samples[0]!.data.count == 256)
    #expect(both.samples[0]!.data.allSatisfy { $0 == 0 })
    let bothWide = try DTMFile.read(dtm(bits: 16, sides: 2))
    #expect(bothWide.samples[0]!.sixteenBit && bothWide.samples[0]!.data.count == 512 && bothWide.samples[0]!.repeatLength == 512)
}

@Test func dtmIsReadAsTheVersionThatWroteItPlayedIt() throws {
    // The old way with stereo: left, right, right, left, and nothing moves a channel.
    let old = try DTMFile.read(dtm(rows: [0: [0x41, 0, 0x18, 0x10]], panoramic: false))
    #expect(old.panning == [ForeignModule.leftward, ForeignModule.rightward])
    #expect(old.patterns[0].notes[0].effTyp == 0)
    // 2.04 in the panoramic way: the command is how loud the channel is on each side, and a place is made of it.
    let v204 = try DTMFile.read(dtm(rows: [0: [0x41, 0, 0x18, 0xF0], 1: [0, 0, 0x08, 0x0F], 2: [0, 0, 0x08, 0x88], 3: [0, 0, 0x0B, 5], 4: [0, 0, 0x0F, 0]]))
    #expect(v204.panning == [128, 128])
    #expect(v204.patterns[0].notes[0].eff < 20 && v204.patterns[0].notes[2].eff > 235 && v204.patterns[0].notes[4].eff == 128)
    // It jumped to the place before the one asked for; and a speed of nothing is no command.
    #expect(v204.patterns[0].notes[6].eff == 4)
    #expect(v204.patterns[0].notes[8].effTyp == 0)
    // 1.9 says which it is: the command is a place, from the right; the channels start where the file puts them.
    let v19 = try DTMFile.read(dtm(rows: [0: [0x41, 0, 0x18, 0x00], 3: [0, 0, 0x0B, 5]], version: 19, places: [0, 180]))
    #expect(v19.tracker == "Digital Tracker 1.9")
    #expect(v19.panning == [0, 255])
    #expect(v19.patterns[0].notes[0].eff == 0xFF && v19.patterns[0].notes[6].eff == 5)
    // A note with its volume beside it: 21 is a volume of 20.
    #expect(try DTMFile.read(dtm(rows: [0: [0x41, 21 << 2, 0x10, 0]])).patterns[0].notes[0].vol == 0x10 + 20)

    // Before 2.04: a MOD file's notes, with periods, and one rate for every sample.
    let early = try TuneLoader.load(dtm(rows: [0: [0x01, 0xAC, 0x10, 0x00]], packing: "", panoramic: false, rate: 44100, rateOfAll: 8400), format: .dtm)
    #expect(early.info.detail == "Digital Tracker 2.03, 2 channels")
    #expect(abs(pitch(stereo(early, seconds: 1).left) - 262) <= 2)

    // Digital Home Studio's patterns are not read.
    #expect(throws: TuneError.self) { try TuneLoader.load(dtm(packing: "2.06"), format: .dtm) }
}

// MARK: AMF

/// An AMF file of two channels and one pattern, with one sample, the square wave.
/// - Parameters:
///   - events: what happens on the first channel's track: a row, a kind and a value each.
///   - version: of the format.
///   - places: where the two channels are, for a version that says.
///   - rate: of the sample.
private func amf(events: [[UInt8]] = [[0, 0x80, 0], [0, 60, 0xFF]], version: Int = 14, places: [Int8] = [-63, 63], rate: Int = 8363) -> [UInt8] {
    var file = Array("AMF".utf8) + [UInt8(version)] + padded("a square wave", 32) + [1, 1] + word(2)
    if version >= 9 { file += [2] }
    if version == 9 || version == 10 { file += [UInt8](repeating: 0, count: 16) }
    if version >= 11 { file += places.map { UInt8(bitPattern: $0) } + [UInt8](repeating: 0, count: (version >= 12 ? 32 : 16) - places.count) }
    if version >= 13 { file += [125, 6] }
    if version >= 14 { file += word(64) }
    // (Before version 9 a file has four channels: the last two play the second track, which is empty.)
    file += word(1) + word(2)
    if version < 9 { file += word(2) + word(2) }
    file += [1] + padded("square", 32) + padded("square.smp", 13) + long(1)
    if version >= 10 {
        file += long(256) + word(rate) + [64] + long(0) + long(256)
    } else {
        file += word(256) + word(rate) + [64] + word(0) + word(256)
    }
    file += word(1) + word(2)
    // A track: how many events, a byte nobody reads, and the events, the last of them three FFs.
    // (The oldest version does not count that last one, and writes nothing at all for an empty track.)
    let end: [UInt8] = [0xFF, 0xFF, 0xFF]
    let track: [UInt8] = events.flatMap { $0 } + end
    file += word(track.count / 3 - (version == 1 ? 1 : 0)) + [0] + track
    file += version == 1 ? word(0) + [0] : word(1) + [0] + end
    return file + square.map { $0 ^ 0x80 }
}

@Test func amfNoteSoundsAtItsPitchWhereItsChannelIs() throws {
    // Note 60 is the C that plays a sample at the rate it gives: 8363 Hz, and 261 Hz for the wave.
    let renderer = try TuneLoader.load(amf(), format: .amf, options: inStereo)
    #expect(renderer.info.format == "AMF")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "DSMI, format 1.4, 2 channels")
    #expect(!renderer.isPlayedOnAnAmiga)
    #expect(abs(renderer.knownLength! - 7.68) < 0.001)
    let sound = stereo(renderer, seconds: 1)
    #expect(abs(pitch(sound.left) - 261) <= 2)
    // The channel is as far left as the format goes, which is all but hard over.
    #expect(loudest(sound.left) > 0.05)
    #expect(loudest(sound.right) < loudest(sound.left) / 8)

    #expect(abs(pitch(stereo(try TuneLoader.load(amf(rate: 11025), format: .amf), seconds: 1).left) - 344) <= 3)
    #expect(abs(pitch(stereo(try TuneLoader.load(amf(events: [[0, 0x80, 0], [0, 72, 0xFF]]), format: .amf), seconds: 1).left) - 523) <= 3)

    // The older versions, of which each keeps its account of a sample a little differently.
    for version in [1, 8, 9, 10, 11, 12, 13] {
        let old = try TuneLoader.load(amf(version: version), format: .amf, options: inStereo)
        #expect(old.channelCount == (version >= 9 ? 2 : 4))
        let heard = stereo(old, seconds: 1)
        #expect(abs(pitch(heard.left) - 261) <= 2, "version \(version)")
        // Before version 11 a file says nothing of where its channels are: the first is to the
        // left, a quarter of the way across, and is heard on both sides.
        if version < 11 { #expect(loudest(heard.right) > loudest(heard.left) / 4 && loudest(heard.right) < loudest(heard.left)) }
    }
    #expect(throws: TuneError.self) { try TuneLoader.load(amf(version: 7), format: .amf) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("ASYLUM Music Format V1.0".utf8) + [UInt8](repeating: 0, count: 3000), format: .amf) }
}

@Test func amfEventsAreFittedIntoANoteAVolumeAndACommand() throws {
    let module = try AMFFile.read(amf(events: [
        [0, 0x80, 0], [0, 60, 40], // an instrument, a note and its volume
        [1, 0x83, 20], [1, 0x97, 0], [1, 0x84, 0xFC], // a volume, a place and a slide up by 4: there is no room left for the place
        [2, 0x97, 63], // a place alone is a command
        [3, 0, 0], // a note of nothing at no volume cuts the note
        [4, 0x82, 0xFD], [5, 0x82, 3], // the volume down by 3, and up
        [6, 0x91, 0xFE], [7, 0x92, 2], [8, 0x96, 0xFF], // fine slides
        [9, 0x81, 0], [10, 0x81, 200], [11, 0x95, 20], // no speed, too great a speed, too slow a tempo
        [12, 0x97, 0xC0], [12, 0x86, 9], // a place and a slide to a note, with no volume: both are kept
        [13, 5, 64], // a note below FastTracker's lowest
        [14, 0x97, 100], // surround
    ]))
    let notes = module.patterns[0].notes
    func cell(_ row: Int) -> [UInt8] { [notes[row * 2].ton, notes[row * 2].instr, notes[row * 2].vol, notes[row * 2].effTyp, notes[row * 2].eff] }
    #expect(cell(0) == [49, 1, 0x10 + 40, 0, 0])
    #expect(cell(1) == [0, 0, 0x10 + 20, 1, 4])
    #expect(cell(2) == [0, 0, 0, 8, 254])
    #expect(cell(3) == [0, 0, 0x10, 0, 0])
    #expect(cell(4) == [0, 0, 0, 0xA, 0x03] && cell(5) == [0, 0, 0, 0xA, 0x30])
    #expect(cell(6) == [0, 0, 0, 0xE, 0xB2] && cell(7) == [0, 0, 0, 0xE, 0x22] && cell(8) == [0, 0, 0, 33, 0x11])
    #expect(cell(9) == [0, 0, 0, 0, 0] && cell(10) == [0, 0, 0, 0xF, 31] && cell(11) == [0, 0, 0, 0xF, 32])
    #expect(cell(12) == [0, 0, 0xC0, 3, 9])
    #expect(cell(13) == [0, 0, 0x10 + 64, 0, 0])
    #expect(cell(14) == [0, 0, 0, 8, 128])
    #expect(module.panning == [2, 254])
    #expect(module.orders == [0])
}

// MARK: Damaged files

@Test func foreignModulesCutShortOrDamagedDoNotTrap() throws {
    let whole: [(TuneFormat, [UInt8])] = [(.mtm, mtm()), (.dtm, dtm()), (.dtm, dtm(packing: "", bits: 16, sides: 2)), (.dtm, dtm(version: 19)), (.amf, amf()),
                                         (.amf, amf(version: 10)), (.amf, amf(version: 8))]
    for (format, file) in whole {
        // Cut off anywhere, a file is refused or it is played: a sample that is not all there ends in silence.
        for length in stride(from: 0, to: file.count, by: 7) {
            if let renderer = try? TuneLoader.load(Array(file.prefix(length)), format: format) { _ = stereo(renderer, seconds: 0.05) }
        }
        #expect(throws: TuneError.self) { try TuneLoader.load(Array(file.prefix(20)), format: format) }
        // The last sample cut short by a few bytes keeps its length, and the note its pitch.
        let all = pitch(stereo(try TuneLoader.load(file, format: format), seconds: 1).left)
        let short = pitch(stereo(try TuneLoader.load(Array(file.dropLast(8)), format: format), seconds: 1).left)
        #expect(abs(short - all) <= 3)

        // With any one byte of it turned to FF, or a run of them to rubbish, it still does not trap.
        var seed: UInt32 = 12345
        func next() -> Int {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int(seed >> 8)
        }
        for place in stride(from: 3, to: min(file.count, 700), by: 2) {
            var damaged = file
            damaged[place] = 0xFF
            if let renderer = try? TuneLoader.load(damaged, format: format) { _ = stereo(renderer, seconds: 0.02) }
        }
        for _ in 0 ..< 100 {
            var damaged = file
            let start = 4 + next() % (file.count - 4)
            for place in start ..< min(file.count, start + 1 + next() % 12) { damaged[place] = UInt8(next() & 0xFF) }
            if let renderer = try? TuneLoader.load(damaged, format: format) { _ = stereo(renderer, seconds: 0.02) }
        }
    }
}

// MARK: What is not played as the file asks

@Test func foreignModulesSayWhatFastTrackerLeavesOut() throws {
    // A file that is played whole says nothing.
    #expect(try TuneLoader.load(mtm(), format: .mtm).info.shortfalls.isEmpty)
    #expect(try TuneLoader.load(dtm(), format: .dtm).info.shortfalls.isEmpty)
    #expect(try TuneLoader.load(amf(), format: .amf).info.shortfalls.isEmpty)

    // MTM: the commands MultiTracker has not got, each named once, and not those that ask for
    // nothing (a loop's start, the shape a vibrato has anyway).
    let loops = mtm(rows: [0: [24 << 2, 0x1E, 0x62], 1: [0, 0x0E, 0x61], 2: [0, 0x0E, 0x31], 3: [0, 0x0E, 0x60], 4: [0, 0x0E, 0x40]])
    #expect(try TuneLoader.load(loops, format: .mtm).info.shortfalls
        == ["Two of its commands are left out, which MultiTracker did not have: sliding by semitones and a loop within a pattern."])
    // And a file that has lost its sample.
    #expect(try TuneLoader.load(Array(mtm().dropLast(256)), format: .mtm).info.shortfalls == ["The file is cut short: one of its samples is missing, and is silent."])
    #expect(try TuneLoader.load(Array(mtm().dropLast(100)), format: .mtm).info.shortfalls == ["The file is cut short: its last sample ends in silence."])
    #expect(try TuneLoader.load(Array(mtm().dropLast(3)), format: .mtm).info.shortfalls.isEmpty)

    // DTM: a sample in stereo, and a channel turned down on both sides at once.
    #expect(try TuneLoader.load(dtm(sides: 2), format: .dtm).info.shortfalls == ["One of its samples is in stereo, and is played as one sound."])
    #expect(try TuneLoader.load(dtm(rows: [0: [0x41, 0, 0x18, 0x48]]), format: .dtm).info.shortfalls
        == ["Where it sets how loud a channel is on each side, the channel's place between them is kept and its loudness is not."])
    #expect(try TuneLoader.load(dtm(rows: [0: [0x41, 0, 0x18, 0xF4]]), format: .dtm).info.shortfalls.isEmpty)

    // AMF: surround, a note below the lowest, and a row with more commands than there is room for.
    #expect(try TuneLoader.load(amf(places: [100, 63]), format: .amf).info.shortfalls == ["Its surround sound is played in the middle."])
    #expect(try TuneLoader.load(amf(events: [[0, 0x80, 0], [0, 60, 0xFF], [4, 5, 0xFF]]), format: .amf).info.shortfalls
        == ["One of its notes is below FastTracker's lowest, and is not heard."])
    #expect(try TuneLoader.load(amf(events: [[0, 0x80, 0], [0, 60, 0xFF], [0, 0x86, 4], [0, 0x89, 0x34]]), format: .amf).info.shortfalls
        == ["Some of its rows have more commands for a channel than FastTracker has room for, and the rest are left out."])
}
