// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of AHX files. The thorough check is made outside the package, against the player this
// is ported from (ahx2play): `siday --raw out.raw tune.ahx` writes the tune as that player would
// write it to a file, and the two are to agree to the sample.

/// A row of a track: a note from 1 to 60, an instrument, and a command with its number.
private func row(note: UInt8 = 0, instrument: UInt8 = 0, command: UInt8 = 0, parameter: UInt8 = 0) -> [UInt8] {
    [note << 2 | instrument >> 4, (instrument & 0xF) << 4 | command, parameter]
}

/// An AHX file with one instrument: a wave 32 bytes round, at full volume for as long as it is held.
/// - Parameters:
///   - speed: how many times fifty the player is run in a second, less one.
///   - positions: for each position, the track and the transposition of each of the four voices.
///   - tracks: what is on the rows of each track, by row.
///   - subsongs: the positions the file's other songs start at.
///   - wave: the instrument's: 1 for a triangle, 2 a sawtooth, 3 a square, 4 noise.
private func tune(revision: UInt8 = 1, speed: Int = 0, rows: Int = 16, positions: [[UInt8]] = [[0, 0, 1, 0, 1, 0, 1, 0]],
                  tracks: [[Int: [UInt8]]], subsongs: [Int] = [], wave: UInt8 = 3) -> [UInt8] {
    var file = Array("THX".utf8) + [revision, 0, 0]
    file += [UInt8(speed << 5) | UInt8(positions.count >> 8), UInt8(positions.count & 0xFF), 0, 0]
    file += [UInt8(rows), UInt8(tracks.count - 1), 1, UInt8(subsongs.count)]
    for start in subsongs { file += [UInt8(start >> 8), UInt8(start & 0xFF)] }
    for position in positions { file += position }
    for track in tracks {
        var bytes = [UInt8](repeating: 0, count: rows * 3)
        for (row, content) in track { bytes.replaceSubrange(row * 3 ..< row * 3 + 3, with: content) }
        file += bytes
    }
    // The instrument: as loud as it goes, the fourth of the six lengths of wave, an envelope that
    // is at its top after a tick and stays there, and a list of one entry.
    var instrument = [UInt8](repeating: 0, count: 22)
    instrument[0] = 64
    instrument[1] = 3
    instrument[2 ... 8] = [1, 64, 1, 64, 1, 1, 64]
    instrument[12] = 1
    instrument[16 ... 21] = [0x20, 0x3F, 1, 0x1F, 1, 1]
    file += instrument
    // The entry: the wave, the instrument's first note, and for a square its width, which is half.
    file += [(wave == 3 ? 3 << 2 : 0) | wave >> 1, (wave & 1) << 7 | 1, 0x20, 0]
    file += Array("a square wave".utf8) + [0] + Array("square".utf8) + [0]
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

/// How much of a tone of a frequency there is in some samples.
private func level(of hz: Double, in samples: ArraySlice<Float>) -> Double {
    var real = 0.0, imaginary = 0.0
    for (i, sample) in samples.enumerated() {
        let angle = 2 * Double.pi * hz * Double(i) / Double(outputSampleRate)
        real += Double(sample) * Foundation.cos(angle)
        imaginary += Double(sample) * Foundation.sin(angle)
    }
    return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
}

/// The note the tests play: the C that Paula plays at 3,546,895 / 428 = 8287 bytes a second, which
/// with a wave of 32 bytes is 259 Hz.
private let played = row(note: 37, instrument: 1)
private let pitch = Paula.clockHz / 428 / 32

@Test func ahxNoteSoundsAtItsPitchOnItsSide() throws {
    // It is on the first voice, which is wired to the left: and on an Amiga, to the left alone.
    var options = LoadOptions()
    options.stereo = .abc
    options.amigaSeparation = 1
    let renderer = try TuneLoader.load(tune(tracks: [[0: played], empty]), format: .ahx, options: options)
    #expect(renderer.info.format == "AHX")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "AHX 2")

    let sound = stereo(renderer, seconds: 1)
    #expect(abs(crossings(sound.left[4800...]) * 10 / 9 - 259) <= 2)
    #expect(sound.left[4800...].map(abs).max()! > 0.15)
    #expect(sound.right.map(abs).max()! < 0.001)

    // The second voice is wired to the right.
    let other = try TuneLoader.load(tune(positions: [[1, 0, 0, 0, 1, 0, 1, 0]], tracks: [[0: played], empty]), format: .ahx, options: options)
    let otherSound = stereo(other, seconds: 1)
    #expect(otherSound.left.map(abs).max()! < 0.001)
    #expect(otherSound.right[4800...].map(abs).max()! > 0.15)

    // A position moves its tracks up or down: twelve notes up is twice the pitch.
    let higher = try TuneLoader.load(tune(positions: [[0, 12, 1, 0, 1, 0, 1, 0]], tracks: [[0: played], empty]), format: .ahx, options: options)
    #expect(abs(crossings(stereo(higher, seconds: 1).left[4800...]) * 10 / 9 - 518) <= 3)

    // In mono both ears have the same, and as it comes a fifth of the Amiga's separation is kept.
    let mono = stereo(try TuneLoader.load(tune(tracks: [[0: played], empty]), format: .ahx), seconds: 0.5)
    #expect(mono.left == mono.right)
    options.amigaSeparation = 0.2
    let nearer = stereo(try TuneLoader.load(tune(tracks: [[0: played], empty]), format: .ahx, options: options), seconds: 1)
    #expect(abs(nearer.right[4800...].map(abs).max()! / nearer.left[4800...].map(abs).max()! - 4.0 / 6.0) < 0.001)
}

@Test func ahxWavesAreTheTrackersOwn() {
    let waves = AHXWaves()
    func plain(_ offset: Int, _ count: Int) -> [Int8] { (0 ..< count).map { waves.samples[AHXWaves.plain + offset + $0] } }
    #expect(plain(AHXWaves.triangles, 4) == [0, 127, 0, -128])
    #expect(plain(AHXWaves.triangles + 4, 8) == [0, 64, 127, 64, 0, -64, -128, -64])
    #expect(plain(AHXWaves.sawtooths, 4) == [-128, -43, 42, 127])
    // The narrowest square is high for two bytes of its 128, and the widest for half of them.
    #expect(plain(AHXWaves.squares, 128).count { $0 == 127 } == 2)
    #expect(plain(AHXWaves.squares + 31 * 128, 128) == [Int8](repeating: -128, count: 64) + [Int8](repeating: 127, count: 64))
    #expect(Set(plain(AHXWaves.noise, AHXWaves.noiseLength)).count > 100)

    // The low-passed sets are duller the lower they are: the even square's one step up, from as low
    // as a byte goes to as high, is spread over more bytes. And in a high-passed set the square does
    // not stay where it stepped to, but falls back.
    func square(set: Int) -> [Int] { (0 ..< 128).map { Int(waves.samples[set * AHXWaves.setLength + AHXWaves.squares + 31 * 128 + $0]) } }
    func steepest(set: Int) -> Int { zip(square(set: set), square(set: set).dropFirst()).map { $1 - $0 }.max()! }
    #expect(steepest(set: 31) == 255)
    #expect(steepest(set: 0) < 16)
    #expect(steepest(set: 0) < steepest(set: 15) && steepest(set: 15) < steepest(set: 30) && steepest(set: 30) < 255)
    #expect(square(set: 31)[127] == 127)
    #expect(abs(square(set: 62)[127]) < 16)
}

@Test func ahxInstrumentPlaysTheWaveItAsksFor() throws {
    func sound(wave: UInt8) throws -> ArraySlice<Float> {
        stereo(try TuneLoader.load(tune(tracks: [[0: played], empty], wave: wave), format: .ahx), seconds: 1).left[4800...]
    }
    // A square wave has no second harmonic and a third a third as loud as the note; a triangle's
    // third is a ninth; a sawtooth has them all, the second half as loud.
    let square = try sound(wave: 3)
    #expect(level(of: pitch * 2, in: square) < level(of: pitch, in: square) * 0.02)
    #expect(abs(level(of: pitch * 3, in: square) / level(of: pitch, in: square) - 1.0 / 3) < 0.03)
    let triangle = try sound(wave: 1)
    #expect(level(of: pitch, in: triangle) > 0.05)
    #expect(abs(level(of: pitch * 3, in: triangle) / level(of: pitch, in: triangle) - 1.0 / 9) < 0.03)
    let sawtooth = try sound(wave: 2)
    #expect(abs(level(of: pitch * 2, in: sawtooth) / level(of: pitch, in: sawtooth) - 0.5) < 0.05)
    // Noise is none of them, and is not the same from one tick to the next.
    let noise = try sound(wave: 4)
    #expect(noise.map(abs).max()! > 0.05)
    #expect(level(of: pitch, in: noise) < level(of: pitch, in: square) * 0.2)
}

@Test func ahxKnowsHowLongItIs() throws {
    // 16 rows of 6 ticks at 49.92 ticks a second, which is what the Amiga's timer makes of fifty.
    let plain = try TuneLoader.load(tune(tracks: [[0: played], empty]), format: .ahx)
    #expect(abs(plain.knownLength! - 1.923) < 0.002)
    #expect(plain.endsByLooping)

    // A tempo of 3 from the first row on halves it, and so does a file whose player runs twice as often.
    let fast = try TuneLoader.load(tune(tracks: [[0: played], [0: row(command: 0xF, parameter: 3)]]), format: .ahx)
    #expect(abs(fast.knownLength! - 0.9615) < 0.002)
    let doubled = try TuneLoader.load(tune(speed: 1, tracks: [[0: played], empty]), format: .ahx)
    #expect(abs(doubled.knownLength! - 0.9615) < 0.002)
    #expect(doubled.info.detail == "AHX 2, 100 ticks a second")

    // A jump on the eighth row back to the first position: eight rows.
    let short = try TuneLoader.load(tune(tracks: [[0: played, 7: row(command: 0xB)], empty]), format: .ahx)
    #expect(abs(short.knownLength! - 0.9615) < 0.002)

    // And it counts the times it has come round.
    #expect(short.loopCount == 0)
    _ = stereo(short, seconds: 2)
    #expect(short.loopCount == 2)
    #expect(!short.hasEnded)
}

@Test func ahxThatStopsItselfHasEnded() throws {
    // A tempo of nothing is how a tune tells the tracker to stop.
    let renderer = try TuneLoader.load(tune(tracks: [[0: played, 4: row(command: 0xF)], empty]), format: .ahx)
    // Four rows of six ticks, and the tick of the fifth row that says so.
    #expect(abs(renderer.knownLength! - 0.5008) < 0.002)
    _ = stereo(renderer, seconds: 1)
    #expect(renderer.hasEnded)
}

@Test func ahxWithMoreThanOneSongHasThemAll() throws {
    // Two positions, each of which goes round by itself: the first an octave below the second, and
    // twice as long. The file says the second is a song, and names a third that is past the end
    // of its list, which is none.
    let low: [Int: [UInt8]] = [0: row(note: 25, instrument: 1), 31: row(command: 0xB, parameter: 0)]
    let high: [Int: [UInt8]] = [0: played, 15: row(command: 0xB, parameter: 1)]
    let file = tune(rows: 32, positions: [[0, 0, 2, 0, 2, 0, 2, 0], [1, 0, 2, 0, 2, 0, 2, 0]], tracks: [low, high, empty], subsongs: [1, 2])
    let renderer = try TuneLoader.load(file, format: .ahx)
    #expect(renderer.subsongCount == 2)
    #expect(renderer.defaultSubsong == 0 && renderer.currentSubsong == 0)
    #expect(abs(renderer.songs[0].length! - 3.846) < 0.004)
    #expect(abs(renderer.songs[1].length! - 1.923) < 0.002)
    #expect(abs(crossings(stereo(renderer, seconds: 1).left[4800...]) * 10 / 9 - 130) <= 2)

    renderer.select(subsong: 1)
    #expect(renderer.currentSubsong == 1)
    #expect(abs(renderer.knownLength! - 1.923) < 0.002)
    #expect(abs(crossings(stereo(renderer, seconds: 1).left[4800...]) * 10 / 9 - 259) <= 2)
    _ = stereo(renderer, seconds: 3)
    #expect(renderer.loopCount == 2)

    // A first song with no note in it is passed over for the first that has one.
    let silence: [Int: [UInt8]] = [31: row(command: 0xB, parameter: 0)]
    let silentFirst = tune(rows: 32, positions: [[3, 0, 2, 0, 2, 0, 2, 0], [1, 0, 2, 0, 2, 0, 2, 0]], tracks: [low, high, empty, silence], subsongs: [1])
    let second = try TuneLoader.load(silentFirst, format: .ahx)
    #expect(second.subsongCount == 2)
    #expect(second.defaultSubsong == 1 && second.currentSubsong == 1)
    #expect(stereo(second, seconds: 1).left[4800...].map(abs).max()! > 0.02)

    // A place the first song plays through is no song of its own, though the file says it is one:
    // here the first position goes on into the second, which is where the other is said to start.
    let onward: [Int: [UInt8]] = [0: row(note: 25, instrument: 1)]
    let joined = tune(rows: 32, positions: [[3, 0, 2, 0, 2, 0, 2, 0], [1, 0, 2, 0, 2, 0, 2, 0]], tracks: [low, high, empty, onward], subsongs: [1])
    #expect(try TuneLoader.load(joined, format: .ahx).subsongCount == 1)
}

@Test func ahxFilesThatAreNotWholeAreTurnedAway() throws {
    let file = tune(tracks: [[0: played], empty])
    // Without the names at its end a file is all there, and has no title.
    #expect(try TuneLoader.load(Array(file.dropLast(21)), format: .ahx).info.title == "")
    // Cut short anywhere in its music, it is not played.
    for missing in [22, 40, 100, file.count - 14, file.count - 3] {
        #expect(throws: TuneError.self) { try TuneLoader.load(Array(file.dropLast(missing)), format: .ahx) }
    }
    // Nor is a file of some other kind, of a later tracker's, or with a shape no file has.
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x55, count: 5000), format: .ahx) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("HVL".utf8) + [UInt8](repeating: 0, count: 500), format: .ahx) }
    #expect(throws: TuneError.self) { try TuneLoader.load(tune(revision: 2, tracks: [[0: played], empty]), format: .ahx) }
    #expect(throws: TuneError.self) { try TuneLoader.load(tune(rows: 0, tracks: [empty, empty]), format: .ahx) }
    #expect(throws: TuneError.self) { try TuneLoader.load(tune(positions: [], tracks: [[0: played], empty]), format: .ahx) }

    // A row may ask for a track, an instrument or a note the file does not have, and is played.
    let odd = tune(positions: [[0, 0, 200, 0, 1, 0, 1, 0]], tracks: [[0: row(note: 63, instrument: 60), 1: row(note: 60, instrument: 1, command: 3, parameter: 9)], empty])
    let sound = stereo(try TuneLoader.load(odd, format: .ahx), seconds: 2)
    #expect(sound.left.allSatisfy { $0.isFinite })
}

@Test func ahxFromTheFirstTrackerHasNoFilter() throws {
    // The second AHX gave a command to the filter that the first had no use for, and an instrument's
    // list the means to set it. A file of the first tracker's that has either is played without.
    func sound(revision: UInt8) throws -> ArraySlice<Float> {
        var file = tune(revision: revision, tracks: [[0: played], empty])
        // The second command of the instrument's one entry is the one that sets the filter, as the
        // file is made: here it sets it to its dullest.
        file[file.count - 21 - 1] = 1
        return stereo(try TuneLoader.load(file, format: .ahx), seconds: 1).left[4800...]
    }
    let filtered = try sound(revision: 1), unfiltered = try sound(revision: 0)
    #expect(level(of: pitch * 5, in: filtered) < level(of: pitch * 5, in: unfiltered) * 0.3)
    #expect(abs(level(of: pitch * 3, in: unfiltered) / level(of: pitch, in: unfiltered) - 1.0 / 3) < 0.03)
    #expect(abs(level(of: pitch * 5, in: unfiltered) / level(of: pitch, in: unfiltered) - 1.0 / 5) < 0.03)
}

@Test func ahxVoicesAreMeasuredApartAndTellTheirNotes() throws {
    // A note on the second voice and nothing on the others, and the octave above it eight rows on.
    let file = tune(positions: [[1, 0, 0, 0, 1, 0, 1, 0]], tracks: [[0: played, 8: row(note: 49)], empty])
    let renderer = try AHXRenderer(file, options: LoadOptions())
    #expect(renderer.channelCount == 4)
    var sound = [Float](repeating: 0, count: 4800 * 2)
    var levels = [Float](repeating: -1, count: 4)
    var pitches = [Float](repeating: -1, count: 4)
    var struck = [Bool](repeating: false, count: 4)
    func listen() {
        sound.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
        pitches.withUnsafeMutableBufferPointer { p in struck.withUnsafeMutableBufferPointer { s in renderer.takeChannelNotes(pitches: p.baseAddress!, struck: s.baseAddress!) } }
    }
    listen()
    #expect(levels[1] > 0.9)
    #expect(levels[0] == 0 && levels[2] == 0 && levels[3] == 0)
    // 259 Hz is a little under middle C.
    #expect(abs(pitches[1] - 59.82) < 0.05)
    #expect(struck[1])
    #expect(pitches[0] == 0 && !struck[0])
    // A tenth of a second on, the note is still sounding and has not been struck again.
    listen()
    #expect(abs(pitches[1] - 59.82) < 0.05)
    #expect(!struck[1])
    // Row 8 comes at 0.96 s, with the octave above: a new pitch, and no new start, since the row
    // names no instrument.
    for _ in 0 ..< 8 { listen() }
    #expect(abs(pitches[1] - 71.82) < 0.05)
    #expect(!struck[1])

    // Noise has no pitch.
    let noise = try AHXRenderer(tune(tracks: [[0: played], empty], wave: 4), options: LoadOptions())
    sound.withUnsafeMutableBufferPointer { noise.render(into: $0.baseAddress!, frames: 4800) }
    pitches.withUnsafeMutableBufferPointer { p in struck.withUnsafeMutableBufferPointer { s in noise.takeChannelNotes(pitches: p.baseAddress!, struck: s.baseAddress!) } }
    #expect(pitches[0] == 0 && struck[0])
}

@Test func ahxWrittenForComparisonIsTheReferencePlayersOutput() throws {
    // Sixteen bits, left and right in turn, and the same every time it is asked for. The player
    // this is ported from puts a voice at its loudest at 14,336 of the 32,768 there are, and the
    // steps of a square wave, with nothing above the range of hearing in them, overshoot that by a third.
    var options = LoadOptions()
    options.stereo = .abc
    options.amigaSeparation = 1
    let renderer = try AHXRenderer(tune(tracks: [[0: played], empty]), options: options)
    let raw = renderer.renderRaw(frames: 24000)
    #expect(raw.count == 48000)
    #expect(raw == renderer.renderRaw(frames: 24000))
    let left = stride(from: 0, to: raw.count, by: 2).map { Int(raw[$0]) }, right = stride(from: 1, to: raw.count, by: 2).map { Int(raw[$0]) }
    #expect((14336 ... 14336 * 4 / 3 + 200).contains(left[4800...].max()!))
    #expect(left[4800...].count { abs($0 - 14336 * 127 / 128) <= 64 } > 4800)
    #expect(right.map(abs).max()! <= 1)
}
