// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of DBM files. The thorough check is made outside the package, against
// libdigibooster3 itself: every song of every file to hand, sample for sample.

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value >> 16 & 0xFFFF) + word(value & 0xFFFF) }
private func padded(_ text: String, to length: Int) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: max(0, length - text.utf8.count)) }
private func chunk(_ name: String, _ body: [UInt8]) -> [UInt8] { Array(name.utf8) + long(body.count) + body }

/// What a track has on a row: an octave and a note in it (a note of 15 lets the key go), an
/// instrument, and two commands with their values.
private struct Cell {
    var octave: UInt8 = 0, note: UInt8 = 0, instrument: UInt8 = 0
    var commands: [(UInt8, UInt8)] = []

    static func note(_ octave: UInt8 = 4, _ note: UInt8 = 0, instrument: UInt8 = 1, _ commands: (UInt8, UInt8)...) -> Cell {
        Cell(octave: octave, note: note, instrument: instrument, commands: commands)
    }

    static func command(_ commands: (UInt8, UInt8)...) -> Cell { Cell(commands: commands) }

    static let keyOff = Cell(octave: 1, note: 15)

    /// As a pattern packs it, after the track's number.
    var packed: [UInt8] {
        var fields: UInt8 = 0, bytes: [UInt8] = []
        if octave != 0 { fields |= 1; bytes.append(octave << 4 | note) }
        if instrument != 0 { fields |= 2; bytes.append(instrument) }
        if commands.count > 0 { fields |= 0x04 | 0x08; bytes += [commands[0].0, commands[0].1] }
        if commands.count > 1 { fields |= 0x10 | 0x20; bytes += [commands[1].0, commands[1].1] }
        return [fields] + bytes
    }
}

/// An instrument: by default a square wave of 32 samples that goes round, played at 16,000 samples
/// a second for the C of the fourth octave, so that it is 500 Hz.
private struct Instrument {
    var frames: [Int16] = (0 ..< 32).map { $0 < 16 ? 12800 : -12800 }
    var loops = true
    var volume = 64
    var panning = 0
    var sixteen = false
    var c3 = 16000
}

/// A DBM file: by default one song of one pattern of 64 rows, and two tracks.
private func dbm(_ patterns: [[(row: Int, track: Int, cell: Cell)]], rows: [Int] = [], songs: [[Int]] = [[0]], tracks: Int = 2,
                 instruments: [Instrument] = [Instrument()], volumeEnvelopes: [[UInt8]] = [], echo: (on: [Bool], settings: [UInt8])? = nil) -> [UInt8] {
    var file: [UInt8] = Array("DBM0".utf8) + [2, 0x21, 0, 0]
    file += chunk("NAME", padded("a square wave", to: 44))
    file += chunk("INFO", word(instruments.count) + word(instruments.count) + word(songs.count) + word(patterns.count) + word(tracks))
    file += chunk("SONG", songs.enumerated().flatMap { padded("song \($0.offset + 1)", to: 44) + word($0.element.count) + $0.element.flatMap { word($0) } })
    var inst: [UInt8] = []
    for (index, one) in instruments.enumerated() {
        inst += padded("square", to: 30) + word(index + 1) + word(one.volume) + long(one.c3)
        inst += long(0) + long(one.loops ? one.frames.count : 0)
        inst += word(Int(UInt16(bitPattern: Int16(one.panning)))) + word(one.loops ? 1 : 0)
    }
    file += chunk("INST", inst)
    var patt: [UInt8] = []
    for (index, pattern) in patterns.enumerated() {
        let count = index < rows.count ? rows[index] : 64
        var packed: [UInt8] = []
        for row in 0 ..< count {
            for (_, track, cell) in pattern.filter({ $0.row == row }) { packed += [UInt8(track + 1)] + cell.packed }
            packed.append(0)
        }
        patt += word(count) + long(packed.count) + packed
    }
    file += chunk("PATT", patt)
    var smpl: [UInt8] = []
    for one in instruments {
        smpl += long(one.sixteen ? 2 : 1) + long(one.frames.count)
        if one.sixteen {
            for frame in one.frames { smpl += word(Int(UInt16(bitPattern: frame))) }
        } else {
            for frame in one.frames { smpl.append(UInt8(bitPattern: Int8(frame >> 8))) }
        }
    }
    file += chunk("SMPL", smpl)
    if !volumeEnvelopes.isEmpty { file += chunk("VENV", word(volumeEnvelopes.count) + volumeEnvelopes.flatMap { $0 }) }
    if let echo { file += chunk("DSPE", word(echo.on.count) + echo.on.map { $0 ? 0 : 1 } + echo.settings.flatMap { [0, $0] }) }
    return file
}

/// A volume envelope for an instrument: its points, each a tick and a volume, and a sustain point.
private func envelope(instrument: Int, points: [(Int, Int)], sustain: Int? = nil) -> [UInt8] {
    var bytes = word(instrument) + [UInt8(1 | (sustain != nil ? 2 : 0)), UInt8(points.count - 1), UInt8(sustain ?? 0), 0, 0, 0]
    for i in 0 ..< 32 { bytes += i < points.count ? word(points[i].0) + word(points[i].1) : [0, 0, 0, 0] }
    return bytes
}

private func options() -> LoadOptions {
    var options = LoadOptions()
    options.stereo = .abc
    return options
}

private func heard(_ file: [UInt8], seconds: Double = 1, muted: [Bool] = []) throws -> (left: [Float], right: [Float]) {
    let renderer = try TuneLoader.load(file, format: .dbm, options: options())
    renderer.setMuted(muted)
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

/// How many times a second a sound goes up through nought, over a stretch of it given in seconds.
private func pitch(_ samples: [Float], _ from: Double, _ to: Double) -> Double {
    let part = samples[Int(from * Double(outputSampleRate)) ..< Int(to * Double(outputSampleRate))]
    return Double(zip(part, part.dropFirst()).count { $0 < 0 && $1 >= 0 }) / (to - from)
}

private func loudness(_ samples: [Float], _ from: Double, _ to: Double) -> Float {
    let part = samples[Int(from * Double(outputSampleRate)) ..< Int(to * Double(outputSampleRate))]
    return (part.reduce(0) { $0 + $1 * $1 } / Float(part.count)).squareRoot()
}

private func length(_ file: [UInt8]) throws -> Double { try #require(try TuneLoader.load(file, format: .dbm).knownLength) }

/// How long a row lasts at the speed of six and the tempo of 125: six ticks of 960 samples.
private let row = 6.0 * 960 / 48000

@Test func dbmNoteSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "DBM") == .dbm)
    let renderer = try TuneLoader.load(dbm([[(0, 0, .note())]]), format: .dbm)
    #expect(renderer.info.format == "DBM" && renderer.info.title == "a square wave" && renderer.info.shortfalls.isEmpty && renderer.channelCount == 2)
    let sound = try heard(dbm([[(0, 0, .note())]]))
    #expect(abs(pitch(sound.left, 0.1, 1) - 500) <= 2)
    #expect(abs(pitch(try heard(dbm([[(0, 0, .note(5))]])).left, 0.1, 1) - 1000) <= 3)
    #expect(abs(pitch(try heard(dbm([[(0, 0, .note(4, 7))]])).left, 0.1, 1) - 500 * 1.4983) <= 3)
    // In the middle, a track is as loud on both sides.
    #expect(loudness(sound.left, 0.1, 1) > 0.02 && abs(loudness(sound.left, 0.1, 1) - loudness(sound.right, 0.1, 1)) < 1e-6)
    // A sample of sixteen bits is the same sound.
    let wide = try heard(dbm([[(0, 0, .note())]], instruments: [Instrument(sixteen: true)]))
    #expect(abs(loudness(wide.left, 0.1, 1) - loudness(sound.left, 0.1, 1)) < 1e-4)
    // An instrument all the way to one side is heard on that side only, and 8xx moves it.
    let left = try heard(dbm([[(0, 0, .note())]], instruments: [Instrument(panning: -128)]))
    #expect(loudness(left.right, 0.1, 1) == 0 && loudness(left.left, 0.1, 1) > 0.02)
    let moved = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x08, 0xFF)))]], instruments: [Instrument(panning: -128)]))
    #expect(loudness(moved.left, 0.1, 1) < 0.001 && loudness(moved.right, 0.1, 1) > 0.02)
    // Its volume, and Cxx.
    let half = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x0C, 0x20)))]]))
    #expect(abs(loudness(half.left, 0.1, 1) * 2 - loudness(sound.left, 0.1, 1)) < 0.001)
    // A note of an instrument the file has not got is silent.
    #expect(loudness(try heard(dbm([[(0, 0, .note(4, 0, instrument: 9))]])).left, 0, 1) == 0)
}

@Test func dbmSpeedTempoAndWhereTheSongGoes() throws {
    // 64 rows of six ticks of 960 samples.
    #expect(abs(try length(dbm([[(0, 0, .note())]])) - 64 * row) < 0.001)
    // F03 is three ticks to a row, and F96 a tempo of 150.
    #expect(abs(try length(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x0F, 0x03)))]])) - 32 * row) < 0.001)
    #expect(abs(try length(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x0F, 0x96)))]])) - 64 * 6 * 800.0 / 48000) < 0.001)
    // A break to the next pattern's sixteenth row (in tens and units), and a jump back to the
    // start, which is where the song comes round.
    let two: [[(row: Int, track: Int, cell: Cell)]] = [[(0, 0, .note()), (7, 0, .command((0x0D, 0x16)))], [(16, 1, .note(5)), (19, 1, .command((0x0B, 0x00)))]]
    #expect(abs(try length(dbm(two, songs: [[0, 1]])) - (8 + 4) * row) < 0.02)
    // A loop of four rows, played three times more, and a delay of three rows more.
    let loop: [[(row: Int, track: Int, cell: Cell)]] = [[(0, 0, .note()), (4, 0, .command((0x0E, 0x60))), (7, 0, .command((0x0E, 0x63)))]]
    #expect(abs(try length(dbm(loop)) - (64 + 12) * row) < 0.001)
    #expect(abs(try length(dbm([[(0, 0, .note()), (5, 0, .command((0x0E, 0xE3)))]])) - 67 * row) < 0.001)
    // F00 stops the song after its row.
    let stops = try TuneLoader.load(dbm([[(0, 0, .note()), (9, 1, .command((0x0F, 0x00)))]]), format: .dbm)
    #expect(abs(try #require(stops.knownLength) - 10 * row) < 0.001)
    var buffer = [Float](repeating: 0, count: 2 * 96000)
    buffer.withUnsafeMutableBufferPointer { stops.render(into: $0.baseAddress!, frames: 96000) }
    #expect(stops.hasEnded)
}

@Test func dbmSongsOfTheFileAndFoundInIt() throws {
    // Two songs of the file's own, each its list; the second the file's names.
    let patterns: [[(row: Int, track: Int, cell: Cell)]] = [[(0, 0, .note())], [(0, 0, .note(5)), (31, 0, .command((0x0B, 0x00)))]]
    let renderer = try TuneLoader.load(dbm(patterns, songs: [[0], [1]]), format: .dbm)
    #expect(renderer.subsongCount == 2 && renderer.songs.map(\.title) == ["song 1", "song 2"])
    #expect(abs(try #require(renderer.songs[1].length) - 32 * row) < 0.001)
    // A place in a list that the song from its top never comes to is a song of its own.
    let hidden = try TuneLoader.load(dbm([[(0, 0, .note()), (63, 0, .command((0x0B, 0x00)))], [(0, 0, .note(5))]], songs: [[0, 1]]), format: .dbm)
    #expect(hidden.subsongCount == 2)
    #expect(abs(try #require(hidden.songs.last?.length) - 64 * row) < 0.001)
}

@Test func dbmSlidesMoveOnEveryTick() throws {
    // A volume slide down of 4 a tick, at the speed of six, from all of it: 24 a row, so nothing
    // after not quite three rows; and AFx is 4 a row, a little at a time.
    let fade = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x0A, 0x04))), (1, 0, .command((0x0A, 0x04))), (2, 0, .command((0x0A, 0x04)))]]))
    #expect(loudness(fade.left, 0.02, 0.06) > 0.02 && loudness(fade.left, 3 * row + 0.02, 3 * row + 0.1) == 0)
    let fine = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x0A, 0xF4)))]]))
    let full = try heard(dbm([[(0, 0, .note())]]))
    #expect(abs(loudness(fine.left, 0.3, 0.6) / loudness(full.left, 0.3, 0.6) - 60.0 / 64) < 0.002)
    // A slide to the note an octave up, at 8 eighths of a semitone a tick, is there in two rows of it.
    let slide = try heard(dbm([[(0, 0, .note()), (1, 0, .note(5, 0, instrument: 0, (0x03, 0x08))), (2, 0, .command((0x03, 0x00)))]]), seconds: 1)
    #expect(abs(pitch(slide.left, 0.4, 1) - 1000) <= 3 && pitch(slide.left, row + 0.03, row + 0.09) < 900)
    // A slide up of an eighth of a semitone a tick, for a row: six eighths.
    let up = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x01, 0x01)))]]))
    #expect(abs(pitch(up.left, 0.3, 1) - 500 * pow(2.0, 6.0 / 96)) <= 3)
}

@Test func dbmEnvelopesKeysAndCuts() throws {
    // An instrument with no volume envelope is cut off when its key is let go.
    let cut = try heard(dbm([[(0, 0, .note()), (4, 0, .keyOff)]]))
    #expect(loudness(cut.left, 0.02, 0.4) > 0.02 && loudness(cut.left, 4 * row + 0.02, 1) == 0)
    // One with an envelope that holds at its second point goes on until the key is let go, and
    // then on down the envelope to nothing.
    let held = envelope(instrument: 1, points: [(0, 64), (4, 32), (24, 0)], sustain: 1)
    let both = try heard(dbm([[(0, 0, .note()), (8, 0, .keyOff)]], volumeEnvelopes: [held]), seconds: 2)
    #expect(loudness(both.left, 0.3, 0.45) > 0.01 && loudness(both.left, 8 * row + 0.6, 2) == 0)
    // A note cut leaves it playing at no volume.
    let ec = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x0E, 0xC3)))]]))
    #expect(loudness(ec.left, 0.003, 0.05) > 0.01 && loudness(ec.left, 0.1, 1) == 0)
    // A note delayed by three ticks.
    let late = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x0E, 0xD3)))]]))
    #expect(loudness(late.left, 0, 0.05) == 0 && loudness(late.left, 0.07, 0.2) > 0.01)
    // A sample that does not go round, played backwards from its end, is over as soon as forwards.
    let ramp = Instrument(frames: (0 ..< 4000).map { Int16($0 * 8) }, loops: false)
    let forwards = try heard(dbm([[(0, 0, .note())]], instruments: [ramp]), seconds: 0.5)
    let backwards = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x0E, 0x30)))]], instruments: [ramp]), seconds: 0.5)
    #expect(forwards.left[1000] < forwards.left[3000] && backwards.left[1000] > backwards.left[3000])
}

@Test func dbmEchoIsAsTheFileSetsIt() throws {
    // A note of a tenth of a second, with the echo on for its track.
    let short = Instrument(frames: (0 ..< 1600).map { $0 % 32 < 16 ? 12800 : -12800 }, loops: false)
    let pattern: [[(row: Int, track: Int, cell: Cell)]] = [[(0, 0, .note())]]
    // Mixed in by half, a delay of 128 ms: there is sound after the note, where without it there is none.
    let plain = try heard(dbm(pattern, instruments: [short]))
    let echoed = try heard(dbm(pattern, instruments: [short], echo: ([true, false], [0x40, 0x80, 0x80, 0xFF])))
    #expect(loudness(plain.left, 0.14, 0.2) == 0 && loudness(echoed.left, 0.14, 0.2) > 0.005)
    // Mixed in by nothing, as the file says, it is not heard; the replayer would start it mixed in by half.
    let dry = dbm(pattern, instruments: [short], echo: ([true, false], [0x40, 0x80, 0x00, 0xFF]))
    #expect(loudness(try heard(dry).left, 0.14, 0.2) == 0)
    let renderer = try TuneLoader.load(dry, format: .dbm) as! DBMRenderer
    let raw = renderer.renderRaw(frames: 48000)
    #expect(raw[Int(0.14 * 48000) * 2 ..< Int(0.2 * 48000) * 2].contains { $0 != 0 })
    // V01 turns it off, and V00 on.
    let off = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x1F, 0x01)))]], instruments: [short], echo: ([true, false], [0x40, 0x80, 0x80, 0xFF])))
    let on = try heard(dbm([[(0, 0, .note(4, 0, instrument: 1, (0x1F, 0x00)))]], instruments: [short]))
    #expect(loudness(off.left, 0.14, 0.2) == 0 && loudness(on.left, 0.14, 0.2) > 0.005)
}

@Test func dbmKeyOffCommandIsDigiBoosterPros() throws {
    // K02 lets the key go two ticks into the row, as DigiBooster Pro did; the replayer passes it over.
    let file = dbm([[(0, 0, .note(4, 0, instrument: 1, (0x14, 0x02)))]])
    let sound = try heard(file)
    #expect(loudness(sound.left, 0, 0.035) > 0.01 && loudness(sound.left, 0.05, 1) == 0)
    let raw = (try TuneLoader.load(file, format: .dbm) as! DBMRenderer).renderRaw(frames: 48000)
    #expect(raw[24000 ..< 26000].contains { $0 != 0 })
}

@Test func dbmCommandsLeftOutAndCutFilesAreSaidSo() throws {
    let file = dbm([[(0, 0, .note(4, 0, instrument: 1, (0x1C, 0x80))), (1, 0, .command((0x15, 0x10)))]])
    let renderer = try TuneLoader.load(file, format: .dbm)
    #expect(renderer.info.shortfalls == ["Two of its commands are left out, which DigiBooster 3's replayer does not play: "
            + "setting how far into an envelope a note is and setting the tempo in beats a minute."])
    // A file that ends part of the way into its sample.
    let long = dbm([[(0, 0, .note())]], instruments: [Instrument(frames: [Int16](repeating: 4000, count: 20000), loops: false)])
    let cut = try TuneLoader.load(Array(long.prefix(long.count - 5000)), format: .dbm)
    #expect(cut.info.shortfalls == ["The file is cut short: its last sample ends in silence."])
}

@Test func dbmDamagedFileIsPlayedOrRefusedAndNeverTraps() throws {
    var instruments = [Instrument(), Instrument(frames: (0 ..< 3000).map { Int16($0 % 200) * 100 }, loops: false, panning: 40)]
    instruments[0].volume = 40
    let file = dbm([[(0, 0, .note()), (1, 1, .note(5, 3, instrument: 2, (0x04, 0x37), (0x0A, 0x01))), (3, 0, .keyOff),
                     (6, 1, .command((0x0E, 0x30), (0x09, 0x02))), (9, 0, .note(3, 0, instrument: 1, (0x1F, 0x00)))],
                    [(0, 1, .note(4, 0, instrument: 1, (0x03, 0x10))), (5, 0, .command((0x0D, 0x10)))]],
                   rows: [16, 32], songs: [[0, 1, 0]], instruments: instruments,
                   volumeEnvelopes: [envelope(instrument: 1, points: [(0, 64), (4, 0), (4, 60)], sustain: 1)], echo: ([true, true], [0x10, 0xF0, 0x80, 0x40]))
    // Cut off anywhere, the file is played or refused.
    for end in stride(from: 0, to: file.count, by: 7) {
        if let renderer = try? TuneLoader.load(Array(file.prefix(end)), format: .dbm) {
            var buffer = [Float](repeating: 0, count: 2 * 4800)
            buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        }
    }
    // And with bytes changed at random.
    var generator = SystemRandomNumberGenerator()
    for _ in 0 ..< 300 {
        var damaged = file
        for _ in 0 ..< 8 { damaged[Int.random(in: 8 ..< damaged.count, using: &generator)] = UInt8.random(in: 0 ... 255, using: &generator) }
        if let renderer = try? TuneLoader.load(damaged, format: .dbm) {
            var buffer = [Float](repeating: 0, count: 2 * 9600)
            buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 9600) }
        }
    }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("DBM0".utf8) + [2, 0, 0, 0], format: .dbm) }
}

@Test func dbmTrackLeftOutIsNotHeardAndPlaysOn() throws {
    /// Half a second of what is heard, and how loud each track was said to be.
    func played(_ renderer: any Renderer) -> (left: [Float], right: [Float], levels: [Float]) {
        var buffer = [Float](repeating: 0, count: 24000 * 2), levels = [Float](repeating: 0, count: renderer.channelCount)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 24000) }
        renderer.takeChannelLevels(into: &levels)
        return (stride(from: 0, to: buffer.count, by: 2).map { buffer[$0] }, stride(from: 1, to: buffer.count, by: 2).map { buffer[$0] }, levels)
    }
    func fresh(_ file: [UInt8]) throws -> any Renderer { try TuneLoader.load(file, format: .dbm, options: options()) }
    // A note on the first track, hard left, and the octave above on the second, with an echo, hard
    // right; and the first alone.
    let instruments = [Instrument(panning: -128), Instrument(panning: 128)]
    let both = dbm([[(0, 0, .note()), (0, 1, .note(5, 0, instrument: 2))]], instruments: instruments, echo: ([false, true], [0x40, 0x80, 0x80, 0x00]))
    let whole = played(try fresh(both)), alone = played(try fresh(dbm([[(0, 0, .note())]], instruments: instruments)))
    #expect(whole.levels[0] > 0.2 && whole.levels[1] > 0.2 && whole.right.map(abs).max()! > 0.01)

    // The second left out: the tune without its note, to the sample, with nothing on the right, and
    // the track is said to be as loud as it was.
    let renderer = try fresh(both)
    renderer.setMuted([false, true])
    let without = played(renderer)
    #expect(without.left == alone.left && without.right.allSatisfy { $0 == 0 })
    #expect(without.levels == whole.levels)
    // A song started again is started without the track; and with it brought back, as it ever was.
    renderer.select(subsong: 0)
    #expect(played(renderer).left == without.left)
    renderer.setMuted([])
    renderer.select(subsong: 0)
    let again = played(renderer)
    #expect(again.left == whole.left && again.right == whole.right)
    // Its pitch, and where it is.
    var pitches = [Float](repeating: 0, count: 2), struck = [Bool](repeating: false, count: 2), sides = [Float](repeating: 0, count: 2)
    renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
    renderer.takeChannelSides(into: &sides)
    #expect(abs(pitches[1] - pitches[0] - 12) < 0.01 && sides == [-1, 1])
}

// MARK: Scopes

/// Each track's scope after so long, its sound kept from the start.
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

@Test func dbmTracksHaveScopes() throws {
    // A square wave as loud as a sample goes: at full volume on the first of three tracks, hard
    // left; at a quarter of it on the second, in the middle; and nothing on the third.
    let loudest = (0 ..< 32).map { Int16($0 < 16 ? 32767 : -32767) }
    let instruments = [Instrument(frames: loudest, panning: -128, sixteen: true), Instrument(frames: loudest, sixteen: true)]
    let file = dbm([[(0, 0, .note()), (0, 1, .note(4, 0, instrument: 2, (0x0C, 0x10)))]], tracks: 3, instruments: instruments)
    func fresh() throws -> any Renderer { try TuneLoader.load(file, format: .dbm, options: options()) }
    let heard = scopes(try fresh())
    #expect(height(heard[0]) > 120)
    // (A quarter of the swing is half the height.)
    #expect(height(heard[1]) > 55 && height(heard[1]) < 75)
    #expect(heard[2].allSatisfy { $0 == 128 })

    // A track left out still has its scope.
    let muted = try fresh()
    muted.setMuted([true])
    #expect(height(scopes(muted)[0]) > 120)

    // And the sound is the same, its tracks kept or not; and so is what the replayer writes.
    let plain = try fresh(), kept = try fresh()
    #expect(kept.keepChannelWaves() != nil)
    var a = [Float](repeating: 0, count: 48000 * 2), b = a
    a.withUnsafeMutableBufferPointer { plain.render(into: $0.baseAddress!, frames: 48000) }
    b.withUnsafeMutableBufferPointer { kept.render(into: $0.baseAddress!, frames: 48000) }
    #expect(a == b)
    let raw = try DBMRenderer(file, options: options())
    let before = raw.renderRaw(frames: 9600)
    #expect(raw.keepChannelWaves() != nil)
    #expect(raw.renderRaw(frames: 9600) == before)
}
