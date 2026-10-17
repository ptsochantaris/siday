// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of HivelyTracker files. The thorough check is made outside the package, against the
// replayer this is ported from (HivelyTracker 1.9's own): `siday --raw out.raw tune.hvl` writes the
// tune as that replayer makes it, and the two are to agree to the sample.

/// A row of a track: a note from 1 to 60, an instrument, and two commands each with its number.
private func row(note: UInt8 = 0, instrument: UInt8 = 0, command: UInt8 = 0, parameter: UInt8 = 0,
                 second: UInt8 = 0, secondParameter: UInt8 = 0) -> [UInt8] {
    [note, instrument, command << 4 | second, parameter, secondParameter]
}

/// An entry of an instrument's list: a wave (1 a triangle, 2 a sawtooth, 3 a square, 4 noise, and 0
/// for the one there is), a note of the instrument's own, and two commands each with its number.
private func entry(wave: UInt8 = 0, note: UInt8 = 0, command: UInt8 = 0, parameter: UInt8 = 0,
                   second: UInt8 = 0, secondParameter: UInt8 = 0) -> [UInt8] {
    [command, second << 3 | wave, note, parameter, secondParameter]
}

/// An instrument: as loud as it goes, the fourth of the six lengths of wave (32 bytes round), an
/// envelope that is at its top after a tick and stays there, and a list that starts with the wave,
/// the instrument's first note, and for a square its width, which is half.
private func instrument(wave: UInt8 = 3, vibrato: UInt8 = 0, then more: [[UInt8]] = []) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 22)
    bytes[0] = 64
    bytes[1] = 3
    bytes[2 ... 8] = [1, 64, 1, 64, 1, 1, 64]
    bytes[12] = 1
    bytes[14] = vibrato
    bytes[15] = 8
    bytes[16 ... 21] = [0x20, 0x3F, 1, 0x1F, 1, UInt8(1 + more.count)]
    return bytes + entry(wave: wave, note: 1, command: 3, parameter: 0x20) + more.flatMap { $0 }
}

/// A HivelyTracker file.
/// - Parameters:
///   - speed: how many times fifty the player is run in a second, less one.
///   - positions: for each position, the track and the transposition of each voice. As it comes,
///     one position in which the first voice plays the first track and the others the second.
///   - tracks: what is on the rows of each track, by row.
///   - subsongs: the positions the file's other songs start at.
///   - stereo: how far apart the voices start, from 0 to 4.
///   - gain: how loud it is mixed, in hundredths.
private func tune(version: UInt8 = 0, channels: Int = 4, speed: Int = 0, rows: Int = 16, positions: [[UInt8]]? = nil,
                  tracks: [[Int: [UInt8]]], subsongs: [Int] = [], stereo: UInt8 = 4, gain: UInt8 = 100,
                  instruments: [[UInt8]] = [instrument()]) -> [UInt8] {
    let positions = positions ?? [[0, 0] + (1 ..< channels).flatMap { _ in [UInt8(1), 0] }]
    var file = Array("HVL".utf8) + [version, 0, 0]
    file += [UInt8(speed << 5) | UInt8(positions.count >> 8), UInt8(positions.count & 0xFF), UInt8((channels - 4) << 2), 0]
    file += [UInt8(rows), UInt8(tracks.count - 1), UInt8(instruments.count), UInt8(subsongs.count), gain, stereo]
    for start in subsongs { file += [UInt8(start >> 8), UInt8(start & 0xFF)] }
    for position in positions { file += position }
    // A row with nothing on it is one byte.
    for track in tracks { for row in 0 ..< rows { file += track[row] ?? [0x3F] } }
    for instrument in instruments { file += instrument }
    // The file says where its names are: the tune's, and then the instruments'.
    file[4] = UInt8(file.count >> 8)
    file[5] = UInt8(file.count & 0xFF)
    file += Array("a hive".utf8) + [0] + Array("square".utf8) + [0]
    return file
}

/// A track with nothing in it, for the voices that are to be silent.
private let empty: [Int: [UInt8]] = [:]

private func stereo(_ renderer: any Renderer, seconds: Double) -> (left: [Float], right: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

private func crossings(_ samples: ArraySlice<Float>) -> Int {
    zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
}

private func loudest(_ samples: some Sequence<Float>) -> Float { samples.map(abs).max() ?? 0 }

/// The note the tests play: the C whose period is 428, which is 3,546,895 / 428 = 8287 bytes a
/// second, and with a wave of 32 bytes 259 Hz.
private let played = row(note: 37, instrument: 1)

private func separate() -> LoadOptions {
    var options = LoadOptions()
    options.stereo = .abc
    return options
}

@Test func hvlNoteSoundsAtItsPitch() throws {
    let renderer = try TuneLoader.load(tune(tracks: [[0: played], empty]), format: .hvl, options: separate())
    #expect(renderer.info.format == "HVL")
    #expect(renderer.info.title == "a hive")
    #expect(renderer.info.detail == "HivelyTracker, 4 channels")
    #expect(renderer.channelCount == 4)
    let sound = stereo(renderer, seconds: 1)
    #expect(abs(crossings(sound.left[4800...]) * 10 / 9 - 259) <= 2)
    // A voice at its loudest, all to one side, is half of what sixteen bits can hold.
    #expect(abs(loudest(sound.left) - 0.35 * 16256 / 32768) < 0.001)

    // A position moves its tracks up or down: twelve notes up is twice the pitch.
    let higher = try TuneLoader.load(tune(positions: [[0, 12, 1, 0, 1, 0, 1, 0]], tracks: [[0: played], empty]), format: .hvl, options: separate())
    #expect(abs(crossings(stereo(higher, seconds: 1).left[4800...]) * 10 / 9 - 518) <= 3)

    // As many as sixteen voices, and no more.
    let most = try TuneLoader.load(tune(channels: 16, tracks: [[0: played], empty]), format: .hvl)
    #expect(most.channelCount == 16)
    #expect(most.info.detail == "HivelyTracker, 16 channels")
    var tooMany = tune(tracks: [[0: played], empty])
    tooMany[8] = 13 << 2
    #expect(throws: TuneError.self) { try TuneLoader.load(tooMany, format: .hvl) }
}

@Test func hvlVoicesAreWhereTheFilePutsThem() throws {
    // As far apart as they go, the first voice is on the left alone, and the second on the right.
    let left = stereo(try TuneLoader.load(tune(tracks: [[0: played], empty]), format: .hvl, options: separate()), seconds: 0.5)
    #expect(loudest(left.left) > 0.15 && loudest(left.right) == 0)
    let right = stereo(try TuneLoader.load(tune(positions: [[1, 0, 0, 0, 1, 0, 1, 0]], tracks: [[0: played], empty]), format: .hvl, options: separate()), seconds: 0.5)
    #expect(loudest(right.left) == 0 && loudest(right.right) > 0.15)

    // A file that asks for no width has every voice in the middle, and one in the middle is a
    // little quieter on each side than one that has a side to itself.
    let middle = stereo(try TuneLoader.load(tune(tracks: [[0: played], empty], stereo: 0), format: .hvl, options: separate()), seconds: 0.5)
    #expect(middle.left == middle.right)
    #expect(abs(loudest(middle.left) / loudest(left.left) - 180.0 / 254.0) < 0.01)

    // A command moves a voice: all the way to the right, and half way to the left.
    func moved(to place: UInt8) throws -> (left: [Float], right: [Float]) {
        let file = tune(tracks: [[0: row(note: 37, instrument: 1, command: 7, parameter: place)], empty])
        return stereo(try TuneLoader.load(file, format: .hvl, options: separate()), seconds: 0.5)
    }
    let far = try moved(to: 0x7F)
    #expect(loudest(far.left) == 0 && loudest(far.right) > 0.15)
    let near = try moved(to: 0xC0)
    #expect(loudest(near.left) > loudest(near.right) * 2 && loudest(near.right) > 0.05)

    // An instrument's list can move it too, for as long as the note lasts: the next note is back
    // where the track put the voice.
    let wandering = instrument(then: [entry(command: 9, parameter: 0x7F)])
    let file = tune(tracks: [[0: played, 8: played], empty], instruments: [wandering])
    let sound = stereo(try TuneLoader.load(file, format: .hvl, options: separate()), seconds: 1.92)
    // Each row is 5,760 samples. The list's second entry comes on the note's second tick.
    #expect(loudest(sound.left[0 ..< 960]) > 0.15 && loudest(sound.right[0 ..< 960]) == 0)
    #expect(loudest(sound.left[1920 ..< 46080]) == 0 && loudest(sound.right[1920 ..< 46080]) > 0.15)
    #expect(loudest(sound.left[46080 ..< 47040]) > 0.15 && loudest(sound.right[46080 ..< 47040]) == 0)

    // In mono both ears have the same, whatever the file says.
    let mono = stereo(try TuneLoader.load(tune(tracks: [[0: played], empty]), format: .hvl), seconds: 0.5)
    #expect(mono.left == mono.right)
    #expect(abs(loudest(mono.left) - loudest(left.left) / 2) < 0.001)
}

@Test func hvlRowHasTwoCommands() throws {
    // The first sets the note's volume to half, and the second puts the voice on the right.
    let both = tune(tracks: [[0: row(note: 37, instrument: 1, command: 0xC, parameter: 0x20, second: 7, secondParameter: 0x7F)], empty])
    let sound = stereo(try TuneLoader.load(both, format: .hvl, options: separate()), seconds: 0.5)
    #expect(loudest(sound.left) == 0)
    #expect(abs(loudest(sound.right) - 0.35 * 8128 / 32768) < 0.001)

    // Either can set the tempo, and with both the second has the last word.
    func length(_ first: UInt8, _ second: UInt8) throws -> Double {
        let file = tune(tracks: [[0: row(note: 37, instrument: 1, command: first == 0 ? 0 : 0xF, parameter: first,
                                         second: second == 0 ? 0 : 0xF, secondParameter: second)], empty])
        return try TuneLoader.load(file, format: .hvl).knownLength!
    }
    #expect(try length(0, 0) == 1.92)
    #expect(try length(3, 0) == 0.96)
    #expect(try length(0, 3) == 0.96)
    #expect(try length(12, 3) == 0.96)

    // A note can be held back some ticks by either.
    for file in [tune(tracks: [[0: row(note: 37, instrument: 1, command: 0xE, parameter: 0xD3)], empty]),
                 tune(tracks: [[0: row(note: 37, instrument: 1, second: 0xE, secondParameter: 0xD3)], empty])] {
        let late = stereo(try TuneLoader.load(file, format: .hvl), seconds: 0.5).left
        #expect(loudest(late[0 ..< 3 * 960]) == 0)
        #expect(loudest(late[4 * 960 ..< 5 * 960]) > 0.05)
    }
}

@Test func hvlFromBothVersionsOfTheTrackerIsPlayed() throws {
    // The second position moves the first voice an octave up, and a command there that slides the
    // pitch by nothing makes the voice take its pitch again. The first position's last row asks
    // for the voice to keep the transposition it has, which is a thing HivelyTracker 1.5 brought:
    // in a file from before it, those letters mean nothing.
    func pitch(version: UInt8) throws -> Int {
        let first: [Int: [UInt8]] = [0: played, 15: row(command: 0xE, parameter: 0xF1)]
        let second: [Int: [UInt8]] = [0: row(command: 0xE, parameter: 0x10)]
        let file = tune(version: version, positions: [[0, 0, 1, 0, 1, 0, 1, 0], [2, 12, 1, 0, 1, 0, 1, 0]], tracks: [first, empty, second])
        let renderer = try TuneLoader.load(file, format: .hvl, options: separate())
        _ = stereo(renderer, seconds: 2)
        return crossings(stereo(renderer, seconds: 1).left[...])
    }
    #expect(abs(try pitch(version: 0) - 518) <= 3)
    #expect(abs(try pitch(version: 1) - 259) <= 2)

    // A later kind of file there is none of.
    #expect(throws: TuneError.self) { try TuneLoader.load(tune(version: 2, tracks: [[0: played], empty]), format: .hvl) }
}

@Test func hvlKnowsHowLongItIs() throws {
    // 16 rows of 6 ticks at fifty ticks a second, which HivelyTracker counts in samples.
    let plain = try TuneLoader.load(tune(tracks: [[0: played], empty]), format: .hvl)
    #expect(plain.knownLength == 1.92)
    #expect(plain.endsByLooping)

    // A file whose player runs twice as often is half as long.
    let doubled = try TuneLoader.load(tune(speed: 1, tracks: [[0: played], empty]), format: .hvl)
    #expect(doubled.knownLength == 0.96)
    #expect(doubled.info.detail == "HivelyTracker, 4 channels, 100 ticks a second")

    // A jump on the eighth row back to the first position: eight rows.
    let short = try TuneLoader.load(tune(tracks: [[0: played, 7: row(command: 0xB)], empty]), format: .hvl)
    #expect(short.knownLength == 0.96)

    // And it counts the times it has come round.
    #expect(short.loopCount == 0)
    _ = stereo(short, seconds: 2)
    #expect(short.loopCount == 2)
    #expect(!short.hasEnded)

    // A tempo of nothing is how a tune tells the tracker to stop: four rows of six ticks, and the
    // tick of the fifth row that says so.
    let stopping = try TuneLoader.load(tune(tracks: [[0: played, 4: row(command: 0xF)], empty]), format: .hvl)
    #expect(stopping.knownLength == 0.5)
    _ = stereo(stopping, seconds: 1)
    #expect(stopping.hasEnded)
}

@Test func hvlWithMoreThanOneSongHasThemAll() throws {
    // Two positions, each of which goes round by itself: the first an octave below the second, and
    // twice as long. The file says the second is a song, and names a third that is past the end
    // of its list, which is none.
    let low: [Int: [UInt8]] = [0: row(note: 25, instrument: 1), 31: row(command: 0xB, parameter: 0)]
    let high: [Int: [UInt8]] = [0: played, 15: row(command: 0xB, parameter: 1)]
    let file = tune(rows: 32, positions: [[0, 0, 2, 0, 2, 0, 2, 0], [1, 0, 2, 0, 2, 0, 2, 0]], tracks: [low, high, empty], subsongs: [1, 2])
    let renderer = try TuneLoader.load(file, format: .hvl)
    #expect(renderer.subsongCount == 2)
    #expect(renderer.defaultSubsong == 0 && renderer.currentSubsong == 0)
    #expect(renderer.songs[0].length == 3.84)
    #expect(renderer.songs[1].length == 1.92)
    #expect(abs(crossings(stereo(renderer, seconds: 1).left[4800...]) * 10 / 9 - 130) <= 2)

    renderer.select(subsong: 1)
    #expect(renderer.currentSubsong == 1)
    #expect(renderer.knownLength == 1.92)
    #expect(abs(crossings(stereo(renderer, seconds: 1).left[4800...]) * 10 / 9 - 259) <= 2)
    _ = stereo(renderer, seconds: 3)
    #expect(renderer.loopCount == 2)

    // A first song with no note in it is passed over for the first that has one.
    let silence: [Int: [UInt8]] = [31: row(command: 0xB, parameter: 0)]
    let silentFirst = tune(rows: 32, positions: [[3, 0, 2, 0, 2, 0, 2, 0], [1, 0, 2, 0, 2, 0, 2, 0]], tracks: [low, high, empty, silence], subsongs: [1])
    let second = try TuneLoader.load(silentFirst, format: .hvl)
    #expect(second.subsongCount == 2)
    #expect(second.defaultSubsong == 1 && second.currentSubsong == 1)
    #expect(loudest(stereo(second, seconds: 1).left[4800...]) > 0.02)

    // A place the first song plays through is no song of its own, though the file says it is one:
    // here the first position goes on into the second, which is where the other is said to start.
    let onward: [Int: [UInt8]] = [0: row(note: 25, instrument: 1)]
    let joined = tune(rows: 32, positions: [[3, 0, 2, 0, 2, 0, 2, 0], [1, 0, 2, 0, 2, 0, 2, 0]], tracks: [low, high, empty, onward], subsongs: [1])
    #expect(try TuneLoader.load(joined, format: .hvl).subsongCount == 1)
}

@Test func hvlFilesThatAreNotWholeAreTurnedAway() throws {
    let file = tune(tracks: [[0: played], empty])
    // Without the names at its end a file is all there, and has no title.
    #expect(try TuneLoader.load(Array(file.dropLast(14)), format: .hvl).info.title == "")
    // Cut short anywhere in its music, it is not played.
    for missing in [15, 30, 50, file.count - 16, file.count - 3] {
        #expect(throws: TuneError.self) { try TuneLoader.load(Array(file.dropLast(missing)), format: .hvl) }
    }
    // Nor is a file of some other kind, or with a shape no file has.
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x55, count: 5000), format: .hvl) }
    #expect(throws: TuneError.self) { try TuneLoader.load(tune(rows: 0, tracks: [empty, empty]), format: .hvl) }
    #expect(throws: TuneError.self) { try TuneLoader.load(tune(rows: 65, tracks: [empty, empty]), format: .hvl) }
    #expect(throws: TuneError.self) { try TuneLoader.load(tune(positions: [], tracks: [[0: played], empty]), format: .hvl) }

    // A row may ask for a track, an instrument or a note the file does not have, a jump may go past
    // the end of the list or to the row after a track's last, and an instrument's list may ask for
    // a wave there is none of: and it is played.
    for jump in [row(command: 0xD, parameter: 0x16), row(command: 0xB, parameter: 0x99)] {
        let astray: [Int: [UInt8]] = [0: row(note: 200, instrument: 60, command: 3, parameter: 9), 1: row(note: 60, instrument: 1, command: 3, parameter: 9),
                                      2: row(note: 37, instrument: 2), 3: jump]
        let odd = tune(positions: [[0, 0, 200, 0, 1, 0, 1, 0]], tracks: [astray, empty], instruments: [instrument(), instrument(wave: 7)])
        let sound = stereo(try TuneLoader.load(odd, format: .hvl), seconds: 2)
        #expect(sound.left.allSatisfy { $0.isFinite })
    }
}

@Test func hvlAndAHXAreToldApartByHowTheyBegin() throws {
    // HivelyTracker reads both, so either may be found under the other's name.
    let hively = tune(tracks: [[0: played], empty])
    #expect(try TuneLoader.load(hively, format: .ahx).info.format == "HVL")
    // The least an AHX file can be: one position, a track of one row, and no instruments.
    var ahx = Array("THX".utf8) + [1, 0, 25, 0, 1, 0, 0, 1, 0, 0, 0]
    ahx += [UInt8](repeating: 0, count: 8 + 3) + Array("old".utf8) + [0]
    let renderer = try TuneLoader.load(ahx, format: .hvl)
    #expect(renderer.info.format == "AHX")
    #expect(renderer.info.title == "old")
    #expect(renderer.channelCount == 4)

    // And the waves the two trackers make are the same, to the byte: these are what HivelyTracker's
    // replayer has, which the player of each of them uses.
    let waves = AHXWaves()
    let bytes = (0 ..< AHXWaves.sets * AHXWaves.setLength).map { UInt8(bitPattern: waves.samples[$0]) }
    #expect(MD5.hex(bytes) == "1b01617c9f164494bd4d088c676e228e")
}

@Test func hvlVoicesAreMeasuredApartAndTellTheirNotes() throws {
    // A note on the fifth of six voices and nothing on the others, and the octave above it eight rows on.
    let file = tune(channels: 6, positions: [[1, 0, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0]], tracks: [[0: played, 8: row(note: 49)], empty])
    let renderer = try HVLRenderer(file, options: LoadOptions())
    #expect(renderer.channelCount == 6)
    var sound = [Float](repeating: 0, count: 4800 * 2)
    var levels = [Float](repeating: -1, count: 6)
    var pitches = [Float](repeating: -1, count: 6)
    var struck = [Bool](repeating: false, count: 6)
    func listen() {
        sound.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
        pitches.withUnsafeMutableBufferPointer { p in struck.withUnsafeMutableBufferPointer { s in renderer.takeChannelNotes(pitches: p.baseAddress!, struck: s.baseAddress!) } }
    }
    listen()
    #expect(levels[4] > 0.9)
    #expect(levels[0] == 0 && levels[1] == 0 && levels[2] == 0 && levels[3] == 0 && levels[5] == 0)
    // 259 Hz is a little under middle C.
    #expect(abs(pitches[4] - 59.82) < 0.05)
    #expect(struck[4])
    #expect(pitches[0] == 0 && !struck[0])
    // A tenth of a second on, the note is still sounding and has not been struck again.
    listen()
    #expect(abs(pitches[4] - 59.82) < 0.05)
    #expect(!struck[4])
    // Row 8 comes at 0.96 s, with the octave above: a new pitch, and no new start, since the row
    // names no instrument.
    for _ in 0 ..< 8 { listen() }
    #expect(abs(pitches[4] - 71.82) < 0.05)
    #expect(!struck[4])

    // Noise has no pitch.
    let noise = try HVLRenderer(tune(tracks: [[0: played], empty], instruments: [instrument(wave: 4)]), options: LoadOptions())
    sound.withUnsafeMutableBufferPointer { noise.render(into: $0.baseAddress!, frames: 4800) }
    pitches.withUnsafeMutableBufferPointer { p in struck.withUnsafeMutableBufferPointer { s in noise.takeChannelNotes(pitches: p.baseAddress!, struck: s.baseAddress!) } }
    #expect(pitches[0] == 0 && struck[0])
}

/// A tune with a little of everything: six voices at twice the usual rate, both commands on its
/// rows, voices moved by the track and by an instrument, slides, a note cut and a note held back,
/// a filter that sweeps, a square wave whose width sweeps, noise, vibrato, and a second wave
/// multiplied in, at a note of its own and at one that follows the track's.
private func everything() -> [UInt8] {
    let sweeping = instrument(then: [entry(command: 4, parameter: 0x11), entry(command: 0, parameter: 0x10, second: 12, secondParameter: 0x30),
                                     entry(wave: 2, note: 13, command: 1, parameter: 3), entry(command: 5, parameter: 1)])
    var ringing = instrument(wave: 1, vibrato: 0x93, then: [entry(command: 7, parameter: 0x19), entry(command: 9, parameter: 0x40),
                                                           entry(command: 8, parameter: 0x8D, second: 15, secondParameter: 3), entry(command: 7)])
    ringing[1] = 2 << 3 | 4
    ringing[19] = 0x30
    let hissing = instrument(wave: 4, then: [entry(wave: 3, note: 0x40 | 30, command: 3, parameter: 0x08), entry(wave: 4, command: 2, parameter: 2)])
    let lead: [Int: [UInt8]] = [0: row(note: 37, instrument: 1, command: 7, parameter: 0xD0, second: 0xC, secondParameter: 0x30),
                                3: row(note: 44, command: 3, parameter: 0x20), 6: row(note: 40, instrument: 2, command: 0xA, parameter: 0x02),
                                9: row(note: 30, instrument: 1, command: 0xE, parameter: 0xD2, second: 4, secondParameter: 0x50),
                                12: row(command: 0xE, parameter: 0xC3, second: 1, secondParameter: 4), 15: row(command: 0xE, parameter: 0xF1)]
    let bass: [Int: [UInt8]] = [0: row(note: 13, instrument: 2), 4: row(note: 20, instrument: 2, command: 9, parameter: 0x10, second: 2, secondParameter: 3),
                                8: row(note: 13, instrument: 1, command: 5, parameter: 0x20), 12: row(note: 25, instrument: 2, second: 0xC, secondParameter: 0x70)]
    let drums: [Int: [UInt8]] = [0: row(note: 25, instrument: 3), 2: row(note: 49, instrument: 3, command: 0xC, parameter: 0x18), 4: row(note: 25, instrument: 3),
                                 6: row(note: 49, instrument: 3, second: 7, secondParameter: 0x7F), 10: row(note: 37, instrument: 3, command: 0xF, parameter: 4),
                                 13: row(command: 0xE, parameter: 0xA4, second: 0xE, secondParameter: 0x25)]
    return tune(version: 1, channels: 6, speed: 1, positions: [[0, 0, 1, 0, 2, 0, 3, 0, 1, 12, 3, 0], [2, 3, 0, 0xF4, 1, 7, 0, 5, 2, 0, 1, 0xFB]],
                tracks: [lead, bass, drums, empty], stereo: 2, gain: 70, instruments: [sweeping, ringing, hissing])
}

@Test func hvlWrittenForComparisonIsTheTrackersOwnOutput() throws {
    // Sixteen bits, left and right in turn, and the same every time it is asked for.
    let renderer = try HVLRenderer(tune(tracks: [[0: played], empty]), options: separate())
    let raw = renderer.renderRaw(frames: 24000)
    #expect(raw.count == 48000)
    #expect(raw == renderer.renderRaw(frames: 24000))
    // The first voice, all to the left: its square wave between the lowest a byte can hold and
    // the highest, at a volume of 64, and 254 parts in 256 of it.
    let left = stride(from: 0, to: raw.count, by: 2).map { Int(raw[$0]) }, right = stride(from: 1, to: raw.count, by: 2).map { Int(raw[$0]) }
    #expect(Set(left[960...]) == [(-128 * 64 * 254) >> 7, (127 * 64 * 254) >> 7])
    #expect(right.allSatisfy { $0 == 0 })
    // It is the sound that is listened to, before it is made quieter; and in mono it is not mono.
    let heard = stereo(renderer, seconds: 0.5).left
    #expect(zip(heard, left).allSatisfy { $0 == Float($1) * (0.35 / 32768) })
    #expect(try HVLRenderer(tune(tracks: [[0: played], empty]), options: LoadOptions()).renderRaw(frames: 24000) == raw)

    // A file that asks to be mixed louder than sixteen bits can hold is clipped, as the tracker's
    // replayer clips it.
    let loud = try HVLRenderer(tune(tracks: [[0: played], empty], gain: 255), options: separate()).renderRaw(frames: 4800)
    #expect(loud.max() == 32767 && loud.min() == -32768)

    // And a tune that does a little of everything comes out as HivelyTracker 1.9's replayer made
    // it, built from the tracker's own source: this is the sum of the six seconds it wrote.
    let all = try HVLRenderer(everything(), options: separate()).renderRaw(frames: 6 * 48000)
    #expect(MD5.hex(all.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }) == "5b267d5689d933851152c025f8bb6b0c")
}

// MARK: Voices left out

/// How loud a player says each voice has been, and its pitch.
private func said(_ renderer: any Renderer) -> (levels: [Float], pitches: [Float]) {
    var levels = [Float](repeating: 0, count: renderer.channelCount)
    var pitches = levels
    var struck = [Bool](repeating: false, count: renderer.channelCount)
    renderer.takeChannelLevels(into: &levels)
    renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
    return (levels, pitches)
}

@Test func hvlVoiceLeftOutIsNotHeardAndPlaysOn() throws {
    // The note on the first voice, which starts on the left, and an octave above it on the second,
    // on the right: as far apart as they go, each has its side to itself.
    let both: [[UInt8]] = [[0, 0, 0, 12, 1, 0, 1, 0]]
    let file = tune(positions: both, tracks: [[0: played], empty])
    func fresh() throws -> any Renderer { try TuneLoader.load(file, format: .hvl, options: separate()) }
    let first = try fresh()
    let whole = stereo(first, seconds: 0.5), wholeSaid = said(first)
    #expect(loudest(whole.left) > 0.15 && loudest(whole.right) > 0.15)

    // The second voice left out: the right is silent, the left is what it was to the sample, and
    // the voice is still said to be as loud as it was, at the pitch it was.
    let renderer = try fresh()
    renderer.setMuted([false, true])
    let without = stereo(renderer, seconds: 0.5), withoutSaid = said(renderer)
    #expect(loudest(without.right) == 0 && without.left == whole.left)
    #expect(withoutSaid.levels == wholeSaid.levels && withoutSaid.levels[1] > 0.9)
    #expect(withoutSaid.pitches == wholeSaid.pitches && abs(withoutSaid.pitches[1] - 71.82) < 0.05)

    // A song started again is started without the voice; and with it brought back, as it ever was.
    renderer.select(subsong: 0)
    #expect(stereo(renderer, seconds: 0.5) == without)
    renderer.setMuted([])
    renderer.select(subsong: 0)
    #expect(stereo(renderer, seconds: 0.5) == whole)

    // With every voice in the middle, where they are added together on both sides, what is left
    // is to the sample the tune that never had the voice; and so it is as the tracker's own
    // replayer would write it.
    let alone = try HVLRenderer(tune(tracks: [[0: played], empty], stereo: 0), options: separate())
    let muted = try HVLRenderer(tune(positions: both, tracks: [[0: played], empty], stereo: 0), options: separate())
    muted.setMuted([false, true])
    #expect(stereo(muted, seconds: 0.5) == stereo(alone, seconds: 0.5))
    #expect(muted.renderRaw(frames: 24000) == alone.renderRaw(frames: 24000))

    // Every voice left out is silence, and the lights are as they were.
    let silent = try fresh()
    silent.setMuted([Bool](repeating: true, count: 4))
    let nothing = stereo(silent, seconds: 0.5)
    #expect(loudest(nothing.left) == 0 && loudest(nothing.right) == 0)
    #expect(said(silent).levels == wholeSaid.levels)
}

@Test func hvlVoicesLeftOutOfATuneThatDoesEverythingAreStillMeasured() throws {
    // Six voices, some with a second wave multiplied in, which is mixed in a way of its own: with
    // every other voice left out, each is said to be as loud and at the same pitch, a tenth of a
    // second at a time, as with none left out; and with all six left out there is no sound.
    let whole = try HVLRenderer(everything(), options: separate())
    let some = try HVLRenderer(everything(), options: separate())
    some.setMuted([true, false, true, false, true, false])
    let none = try HVLRenderer(everything(), options: separate())
    none.setMuted([Bool](repeating: true, count: 6))
    var heardSome = false, differed = false
    for _ in 0 ..< 30 {
        let all = stereo(whole, seconds: 0.1), part = stereo(some, seconds: 0.1), nothing = stereo(none, seconds: 0.1)
        let wholeSaid = said(whole)
        #expect(said(some) == wholeSaid && said(none) == wholeSaid)
        #expect(loudest(nothing.left) == 0 && loudest(nothing.right) == 0)
        heardSome = heardSome || loudest(part.left) > 0.02
        differed = differed || part != all
    }
    #expect(heardSome && differed)
}

// MARK: Scopes

/// Each voice's scope after so long, its sound kept from the start.
private func scopes(_ renderer: any Renderer, seconds: Double = 0.5) -> [[UInt8]] {
    let session = TuneSession(renderer: renderer, policy: PlaybackPolicy())
    #expect(session.keepChannelWaves())
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    _ = buffer.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: frames) }
    var all = [UInt8](repeating: 0, count: renderer.channelCount * ChannelWaves.points)
    all.withUnsafeMutableBufferPointer { session.takeChannelWaves(into: $0.baseAddress!, behind: 0) }
    return (0 ..< renderer.channelCount).map { Array(all[$0 * ChannelWaves.points ..< ($0 + 1) * ChannelWaves.points]) }
}

/// A scope's distance from the middle at its highest.
private func height(_ scope: [UInt8]) -> Int { scope.map { abs(Int($0) - 128) }.max() ?? 0 }

@Test func hvlVoicesHaveScopes() throws {
    // Of six voices, the note at full volume on the first, at a quarter of it on the second, and
    // nothing on the others.
    let file = tune(channels: 6, positions: [[0, 0, 1, 0, 2, 0, 2, 0, 2, 0, 2, 0]],
                    tracks: [[0: played], [0: row(note: 37, instrument: 1, command: 0xC, parameter: 0x10)], empty])
    func fresh() throws -> any Renderer { try TuneLoader.load(file, format: .hvl, options: LoadOptions()) }
    let heard = scopes(try fresh())
    #expect(heard.count == 6)
    #expect(height(heard[0]) > 120)
    // (A quarter of the swing is half the height.)
    #expect(height(heard[1]) > 55 && height(heard[1]) < 75)
    #expect(heard[2...].allSatisfy { $0.allSatisfy { $0 == 128 } })

    // A voice left out still has its scope.
    let muted = try fresh()
    muted.setMuted([true])
    #expect(height(scopes(muted)[0]) > 120)

    // And the sound is the same, its voices kept or not; and so is what is written for comparison.
    let plain = try fresh(), kept = try fresh()
    #expect(kept.keepChannelWaves() != nil)
    #expect(stereo(kept, seconds: 1) == stereo(plain, seconds: 1))
    let raw = try HVLRenderer(file, options: LoadOptions())
    let before = raw.renderRaw(frames: 9600)
    #expect(raw.keepChannelWaves() != nil)
    #expect(raw.renderRaw(frames: 9600) == before)
}
