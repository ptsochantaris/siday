// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of 669 files. The thorough check is made outside the package, against
// libopenmpt: every channel's pitch and volume on every tick of each file to hand, and what is heard.

private func long(_ value: Int) -> [UInt8] { (0 ..< 4).map { UInt8(value >> ($0 * 8) & 0xFF) } }

/// What a channel has on a row: a note of a sample at a volume, a volume alone, or neither; and a
/// command, or none.
private struct Cell {
    var note: Int?, sample = 0, volume: Int?
    var command: UInt8 = 0xFF

    static func note(_ note: Int = 24, sample: Int = 0, volume: Int = 15, _ command: Character? = nil, _ value: UInt8 = 0) -> Cell {
        Cell(note: note, sample: sample, volume: volume, command: byte(command, value))
    }

    static func command(_ command: Character, _ value: UInt8, volume: Int? = nil) -> Cell {
        Cell(volume: volume, command: byte(command, value))
    }

    private static func byte(_ command: Character?, _ value: UInt8) -> UInt8 {
        command.map { ($0.asciiValue! - 97) << 4 | value } ?? 0xFF
    }

    var bytes: [UInt8] {
        if let note { return [UInt8(note << 2 | sample >> 4), UInt8((sample & 15) << 4 | (volume ?? 15)), command] }
        if let volume { return [0xFE, UInt8(volume), command] }
        return [0xFF, 0, command]
    }
}

/// A 669 file: by default one pattern, at four ticks to the row, and one sample, a square wave of
/// 32 samples that goes round, so that the C the trackers play at 8,363 samples a second is 261 Hz.
/// - Parameters:
///   - patterns: for each pattern its cells, by row and channel.
///   - speeds: each pattern's ticks to the row, and `lastRows` the row each ends after.
///   - samples: for each sample its sound, unsigned as the file has it, and whether it goes round.
private func file669(_ patterns: [[(row: Int, channel: Int, cell: Cell)]], orders: [UInt8] = [0], restart: UInt8 = 0, speeds: [UInt8] = [], lastRows: [UInt8] = [],
                     samples: [(sound: [UInt8], loops: Bool)] = [((0 ..< 32).map { $0 < 16 ? 0xFF : 0x01 }, true)], extended: Bool = false) -> [UInt8] {
    var file = Array((extended ? "JN" : "if").utf8)
    file += Array("a square wave".utf8) + [UInt8](repeating: 0x20, count: 108 - 13)
    file += [UInt8(samples.count), UInt8(patterns.count), restart]
    file += orders + [UInt8](repeating: 0xFF, count: 128 - orders.count)
    file += (0 ..< 128).map { $0 < speeds.count ? speeds[$0] : 4 }
    file += (0 ..< 128).map { $0 < lastRows.count ? lastRows[$0] : 63 }
    for sample in samples {
        file += Array("square.voc".utf8) + [0, 0, 0] + long(sample.sound.count) + long(0) + long(sample.loops ? sample.sound.count : 0xFFFFF)
    }
    for pattern in patterns {
        var rows = [UInt8](repeating: 0xFF, count: 64 * 8 * 3)
        for i in stride(from: 1, to: rows.count, by: 3) { rows[i] = 0 }
        for (row, channel, cell) in pattern { rows.replaceSubrange((row * 8 + channel) * 3 ..< (row * 8 + channel) * 3 + 3, with: cell.bytes) }
        file += rows
    }
    for sample in samples { file += sample.sound }
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

private func heard(_ file: [UInt8], seconds: Double = 1) throws -> (left: [Float], right: [Float]) {
    var options = LoadOptions()
    options.stereo = .abc
    return stereo(try TuneLoader.load(file, format: .composer669, options: options), seconds: seconds)
}

/// The samples a second the first channel is played at, and how loud of 1, on each of so many ticks.
private func ticks(_ file: [UInt8], _ count: Int, channel: Int = 0) throws -> [(rate: Int, volume: Float, playing: Bool)] {
    var player = Composer669Player(try Composer669Module(file))
    return (0 ..< count).map { _ in
        _ = player.runTick()
        return (Int(player.mixer.rate(of: channel)), player.mixer.volume(of: channel), player.mixer.isPlaying(channel))
    }
}

@Test func composer669NoteSoundsAtItsPitchAndOnItsSide() throws {
    #expect(TuneFormat(fileExtension: "669") == .composer669)
    let first = try heard(file669([[(0, 0, .note())]]))
    // The C of the third octave, 8,363 samples a second, is 261 Hz with this sample; an octave up is twice that.
    #expect(abs(crossings(first.left[4800...]) * 10 / 9 - 261) <= 2)
    let higher = try heard(file669([[(0, 0, .note(36))]]))
    #expect(abs(crossings(higher.left[4800...]) * 10 / 9 - 523) <= 3)
    // The first channel is to the left and the second to the right, each as far as the other.
    let second = try heard(file669([[(0, 1, .note())]]))
    #expect(loudness(first.left[4800...]) > loudness(first.right[4800...]) * 3)
    #expect(abs(loudness(first.left[4800...]) - loudness(second.right[4800...])) < 0.001)
    #expect(abs(loudness(first.right[4800...]) - loudness(second.left[4800...])) < 0.001)
    // A volume is of fifteen.
    let quiet = try heard(file669([[(0, 0, .note(volume: 5))]]))
    #expect(abs(loudness(quiet.left[4800...]) * 3 - loudness(first.left[4800...])) < 0.002)
    #expect(loudness(try heard(file669([[(0, 0, .note(volume: 0))]])).left[4800...]) == 0)
    // Heard in mono, the sides are the same.
    let mono = stereo(try TuneLoader.load(file669([[(0, 0, .note())]]), format: .composer669), seconds: 0.5)
    #expect(mono.left == mono.right)
}

@Test func composer669SlidesAreInSamplesASecond() throws {
    // a3 beside a note: 240 more on every tick, the first too, and on through the rows after.
    let up = try ticks(file669([[(0, 0, .note(24, "a", 3))]]), 9)
    #expect(up.map(\.rate) == (1 ... 9).map { 8363 + 240 * $0 })
    // b the other way; and a command that comes later ends it, whatever the command.
    let down = try ticks(file669([[(0, 0, .note(36, "b", 1)), (1, 0, .command("f", 4))]]), 8)
    #expect(down.map(\.rate) == [16646, 16566, 16486, 16406, 16406, 16406, 16406, 16406])
    // And so does a note.
    let renewed = try ticks(file669([[(0, 0, .note(24, "a", 1)), (1, 0, .note(24))]]), 6)
    #expect(renewed.map(\.rate) == [8443, 8523, 8603, 8683, 8363, 8363])

    // c beside a note slides to that note, 40 for each one of its value on every tick, and stops
    // there. The note is not struck, and takes its volume from the row.
    var player = Composer669Player(try Composer669Module(file669([[(0, 0, .note(24)), (1, 0, .note(26, volume: 7, "c", 5))]])))
    var notes = TickNotes(voices: 8)
    var rates: [Int] = [], struck: [Bool] = []
    for _ in 0 ..< 12 {
        _ = player.runTick()
        player.takeNotes(into: &notes)
        rates.append(Int(player.mixer.rate(of: 0)))
        struck.append(notes.struck[0])
        notes.struck[0] = false
    }
    #expect(rates[..<4].allSatisfy { $0 == 8363 })
    #expect(rates[4...] == [8563, 8763, 8963, 9163, 9363, 9387, 9387, 9387])
    #expect(struck == [true] + [Bool](repeating: false, count: 11))
    #expect(abs(player.mixer.volume(of: 0) - 7.0 / 15) < 0.001)
    // With nothing sounding to slide from, the note is played.
    #expect(try ticks(file669([[(0, 0, .note(26, "c", 5))]]), 1)[0].rate == 9387)

    // d plays its note sharp, by 80 for each one, for as long as the note lasts.
    let sharp = try ticks(file669([[(0, 0, .note(24, "d", 2)), (2, 0, .note(24))]]), 9)
    #expect(sharp.map(\.rate) == [8523, 8523, 8523, 8523, 8523, 8523, 8523, 8523, 8363])

    // e is a trill: every other tick the note is 668 higher for each one, until another command.
    let trill = try ticks(file669([[(0, 0, .note(24, "e", 2)), (2, 0, .command("e", 0))]]), 10)
    #expect(trill.map(\.rate) == [8363, 9699, 8363, 9699, 8363, 9699, 8363, 9699, 8363, 8363])
}

@Test func composer669KeepsTimeByItsPatternsAndItsCommand() throws {
    // A pattern has its own ticks to the row and its own last row, and f sets the ticks until the
    // next pattern begins. A tick is 2.5 seconds over 78.
    let tick = 2.5 / 78
    func length(_ file: [UInt8]) throws -> Double { try #require(try TuneLoader.load(file, format: .composer669).knownLength) }
    #expect(abs(try length(file669([[(0, 0, .note())]])) - 64 * 4 * tick) < 0.001)
    #expect(abs(try length(file669([[(0, 0, .note())]], speeds: [6], lastRows: [15])) - 16 * 6 * tick) < 0.001)
    let two = file669([[(0, 0, .note()), (4, 3, .command("f", 2))], [(0, 0, .note())]], orders: [0, 1], speeds: [5, 3], lastRows: [7, 7])
    #expect(abs(try length(two) - Double(4 * 5 + 4 * 2 + 8 * 3) * tick) < 0.001)
    // The list may have places with nothing to play, which are passed over, and the tune goes on
    // from where the file says when the list is done.
    let passed = file669([[(0, 0, .note())], [(0, 0, .note())]], orders: [0, 0xFE, 1], restart: 2, lastRows: [3, 3])
    var player = Composer669Player(try Composer669Module(passed))
    var places: [Int] = []
    var cameRound = -1
    for tick in 0 ..< 48 {
        if !player.runTick(), cameRound < 0 { cameRound = tick }
        if tick % 16 == 0 { places.append(player.order) }
    }
    #expect(places == [0, 2, 2] && cameRound == 32)
    // What comes after the mark that ends the list is no part of it.
    let renderer = try TuneLoader.load(file669([[(0, 0, .note())], [(0, 0, .note())]], orders: [0, 0xFF, 1], lastRows: [63, 31]), format: .composer669)
    #expect(renderer.subsongCount == 1)
    #expect(renderer.info.format == "Composer 669" && renderer.info.title == "a square wave" && renderer.channelCount == 8)
}

@Test func composer669SampleGoesRoundOrEnds() throws {
    let once: [(sound: [UInt8], loops: Bool)] = [((0 ..< 3200).map { $0 % 32 < 16 ? 0xFF : 0x01 }, false)]
    // 3,200 samples at 8,363 a second are over in two fifths of a second.
    let sound = try heard(file669([[(0, 0, .note())]], samples: once))
    #expect(loudness(sound.left[4800 ..< 14400]) > 0.01 && loudness(sound.left[24000...]) == 0)
    // A note of a sample the file has not got is the end of what the channel was playing.
    let stopped = try ticks(file669([[(0, 0, .note()), (1, 0, .note(24, sample: 9))]]), 5)
    #expect(stopped.map(\.playing) == [true, true, true, true, false])
}

@Test func composer669OfUNISHasTwoCommandsMore() throws {
    // g moves the channel a little to one side on every row, and h strikes the note again.
    func side(_ extended: Bool) throws -> Float {
        var player = Composer669Player(try Composer669Module(file669([[(0, 0, .note(24, "g", 1))]], extended: extended)))
        for _ in 0 ..< 32 { _ = player.runTick() }
        return player.mixer.side(of: 0)
    }
    #expect(try side(false) == -0.625)
    #expect(abs(try side(true) - (-0.625 + 8 * 4.0 / 128)) < 0.001)
    var player = Composer669Player(try Composer669Module(file669([[(0, 0, .note(24, "h", 2))]], extended: true)))
    var notes = TickNotes(voices: 8)
    var struck: [Bool] = []
    for _ in 0 ..< 8 {
        _ = player.runTick()
        player.takeNotes(into: &notes)
        struck.append(notes.struck[0])
        notes.struck[0] = false
    }
    #expect(struck == [true, false, true, false, false, false, false, false])
    #expect(try TuneLoader.load(file669([[(0, 0, .note())]], extended: true), format: .composer669).info.format == "UNIS 669")
}

@Test func composer669ChannelLeftOutIsNotHeardAndPlaysOn() throws {
    var options = LoadOptions()
    options.stereo = .abc
    /// Half a second of what is heard, and how loud each channel was said to be.
    func played(_ renderer: any Renderer) -> (sound: (left: [Float], right: [Float]), levels: [Float]) {
        let sound = stereo(renderer, seconds: 0.5)
        var levels = [Float](repeating: 0, count: renderer.channelCount)
        renderer.takeChannelLevels(into: &levels)
        return (sound, levels)
    }
    func fresh(_ file: [UInt8]) throws -> any Renderer { try TuneLoader.load(file, format: .composer669, options: options) }
    // A note on the first channel, to the left, and the octave above on the second, to the right;
    // and the first alone.
    let both = file669([[(0, 0, .note()), (0, 1, .note(36))]])
    let whole = played(try fresh(both)), alone = played(try fresh(file669([[(0, 0, .note())]])))
    #expect(whole.levels[0] > 0.2 && whole.levels[1] > 0.2 && whole.sound != alone.sound)

    // The second left out: the tune without its note, to the sample, and the channel is said to be
    // as loud as it was.
    let renderer = try fresh(both)
    renderer.setMuted([false, true])
    let without = played(renderer)
    #expect(without.sound == alone.sound && without.levels == whole.levels)

    // A song started again is started without the channel; and with it brought back, as it ever was.
    renderer.select(subsong: 0)
    #expect(played(renderer).sound == without.sound)
    renderer.setMuted([])
    renderer.select(subsong: 0)
    #expect(played(renderer).sound == whole.sound)

    // A note that another takes the place of dies away on a voice of its own, which is its
    // channel's too; and every channel left out is silence.
    let twice = try fresh(file669([[(0, 0, .note()), (1, 0, .note(36)), (0, 1, .note(36))]]))
    twice.setMuted([true, true, true, true, true, true, true, true])
    let none = played(twice)
    #expect(none.sound.left.allSatisfy { $0 == 0 } && none.sound.right.allSatisfy { $0 == 0 })
    #expect(none.levels[0] > 0.2 && none.levels[1] > 0.2)
}

@Test func composer669SaysWhatItLeavesOut() throws {
    func shortfalls(_ file: [UInt8]) throws -> [String] { try TuneLoader.load(file, format: .composer669).info.shortfalls }
    #expect(try shortfalls(file669([[(0, 0, .note(24, "a", 1)), (1, 0, .command("f", 3))]])).isEmpty)
    // A command neither program is said to have had; and UNIS 669's fastest tempo.
    #expect(try shortfalls(file669([[(0, 0, .note(24, "k", 1))]])) == ["It has commands that Composer 669 is not known to have had, and they are left out."])
    #expect(try shortfalls(file669([[(0, 0, .note(24, "g", 1))]])).count == 1)
    #expect(try shortfalls(file669([[(0, 0, .note(24, "g", 1))]], extended: true)).isEmpty)
    #expect(try shortfalls(file669([[(0, 0, .command("f", 0))]], extended: true)) == ["It asks for UNIS 669's fastest tempo, and is left at the tempo it had."])
    #expect(try shortfalls(file669([[(0, 0, .command("f", 0))]])).isEmpty)
    // A file that ends before its sample does.
    let long: [(sound: [UInt8], loops: Bool)] = [([UInt8](repeating: 0x80, count: 4000), false)]
    #expect(try shortfalls(Array(file669([[(0, 0, .note())]], samples: long).dropLast(3000))) == ["The file is cut short: its last sample ends in silence."])
}

@Test func composer669FileThatIsCutOrDamagedIsReadOrRefused() throws {
    let whole = file669([[(0, 0, .note(24, "a", 1)), (1, 1, .note(30, "c", 2)), (2, 2, .note(40, "e", 3))], [(0, 0, .note())]], orders: [0, 1, 0xFE, 0])
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .composer669) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("ifnot a module at all".utf8), format: .composer669) }
    // Cut anywhere, it is refused or played, and never anything else.
    for length in stride(from: 0, to: whole.count, by: 37) {
        if let renderer = try? TuneLoader.load(Array(whole[..<length]), format: .composer669) { _ = stereo(renderer, seconds: 0.2) }
    }
    // And with any of its bytes changed: a number that is too much is refused, and the rest are played.
    var seed: UInt32 = 12345
    func random() -> Int {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Int(seed >> 8)
    }
    for _ in 0 ..< 400 {
        var damaged = whole
        for _ in 0 ..< 1 + random() % 6 { damaged[random() % min(damaged.count, 497 + 25 + 400)] = UInt8(random() & 0xFF) }
        if let renderer = try? TuneLoader.load(damaged, format: .composer669) {
            for song in 0 ..< renderer.subsongCount {
                renderer.select(subsong: song)
                _ = stereo(renderer, seconds: 0.1)
            }
        }
    }
}
