// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayTrackers
import Testing

// Fast checks of the PLM files that Impulse Tracker's replayer plays. The thorough check is made
// outside the package, against libopenmpt: every channel's pitch, volume and place on every tick of
// each file to hand, and what is heard.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count)) }

/// One channel's part of a row: a note (its octave in the upper half and its place in the octave in
/// the lower; 0 for none), a sample, a volume (255 for none) and a command.
private struct Cell {
    var note: UInt8 = 0, sample: UInt8 = 0, volume: UInt8 = 255, command: UInt8 = 0, value: UInt8 = 0

    /// C of the fourth octave, which plays a sample at its own rate.
    static func note(_ note: UInt8 = 0x40, _ sample: UInt8 = 1, _ command: UInt8 = 0, _ value: UInt8 = 0) -> Cell {
        Cell(note: note, sample: sample, command: command, value: value)
    }

    static func command(_ command: UInt8, _ value: UInt8) -> Cell { Cell(command: command, value: value) }

    var bytes: [UInt8] { [note, sample, volume, command, value] }
}

/// A pattern: so many rows of so many channels, and what is on them.
private struct Pattern {
    var rows = 64, channels = 2
    var cells: [(row: Int, channel: Int, cell: Cell)] = []
}

/// A sample: a square wave of 32 samples, without a sign, eight bits, at 8,363 samples a second, so
/// that C-5 is 261 Hz.
private struct Sound {
    var frames: [UInt8] = (0 ..< 32).map { $0 < 16 ? 255 : 1 }
    var rate = 8363
    var pan: UInt8 = 255
    var loops = true
}

/// A PLM file: its patterns, and the list that lays each at a row of the song and a channel.
private func plm(_ patterns: [Pattern], items: [(x: Int, y: Int, pattern: Int)] = [(0, 0, 0)], channels: Int = 2, pans: [UInt8] = [],
                 sounds: [Sound] = [Sound()]) -> [UInt8] {
    var file = Array("PLM".utf8) + [0x1A, 96, 0x10] + padded(Array("a square wave".utf8), to: 48)
    file += [UInt8(channels), 0, 64, 64, 125, 6]
    file += (0 ..< 32).map { $0 < pans.count ? pans[$0] : 7 }
    file += [UInt8(sounds.count), UInt8(patterns.count)] + word(items.count)
    for item in items { file += word(item.x) + [UInt8(item.y), UInt8(item.pattern)] }
    let patternBytes = patterns.map { pattern -> [UInt8] in
        var rows = [[UInt8]](repeating: [UInt8](repeating: 0, count: 5 * pattern.channels), count: pattern.rows)
        for row in rows.indices {
            for channel in 0 ..< pattern.channels { rows[row].replaceSubrange(channel * 5 ..< channel * 5 + 5, with: Cell().bytes) }
        }
        for (row, channel, cell) in pattern.cells { rows[row].replaceSubrange(channel * 5 ..< channel * 5 + 5, with: cell.bytes) }
        return long(32 + 5 * pattern.rows * pattern.channels) + [UInt8(pattern.rows), UInt8(pattern.channels), 0] + [UInt8](repeating: 0, count: 25) + rows.flatMap { $0 }
    }
    let soundBytes = sounds.map { sound -> [UInt8] in
        Array("PLS".utf8) + [0x1A, 71, 0x10] + padded(Array("square".utf8), to: 32) + [UInt8](repeating: 0, count: 12)
            + [sound.pan, 64, 0] + word(sound.rate) + [0, 0, 0, 0] + long(0) + long(sound.loops ? sound.frames.count : 0) + long(sound.frames.count) + sound.frames
    }
    var at = file.count + 4 * (patterns.count + sounds.count)
    for bytes in patternBytes + soundBytes {
        file += long(at)
        at += bytes.count
    }
    return file + patternBytes.flatMap { $0 } + soundBytes.flatMap { $0 }
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
    return stereo(try TuneLoader.load(file, format: .plm, options: options), seconds: seconds)
}

/// What a channel's voice is at on each of so many ticks: samples a second, where in its sample it
/// is, and whether it is sounding.
private func ticks(_ file: [UInt8], _ count: Int, channel: Int = 0) throws -> [(rate: Int, position: Int, sounding: Bool)] {
    let renderer = try #require(try TuneLoader.load(file, format: .plm) as? ITRenderer)
    let player = IT2Player(renderer.module, forSound: true)
    return (0 ..< count).map { _ in
        player.Update()
        defer { _ = player.mixer.mixTick() }
        guard let voice = player.hChn[channel].SlaveChnPtr, voice.pointee.Flags & SF_CHAN_ON != 0, voice.pointee.Flags & SF_NOTE_STOP == 0 else { return (0, 0, false) }
        return (Int(voice.pointee.Frequency), Int(voice.pointee.SamplingPosition), true)
    }
}

@Test func plmNoteSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "PLM") == .plm)
    let file = plm([Pattern(cells: [(0, 0, .note())])])
    let renderer = try TuneLoader.load(file, format: .plm)
    #expect(renderer.info.format == "PLM" && renderer.info.title == "a square wave" && renderer.info.shortfalls.isEmpty)
    #expect(abs(crossings(try heard(file).left[4800...]) * 10 / 9 - 261) <= 2)
    #expect(abs(crossings(try heard(plm([Pattern(cells: [(0, 0, .note(0x50))])])).left[4800...]) * 10 / 9 - 523) <= 3)
    // Each channel at one of sixteen places; and a sample may have one of its own, for its notes.
    let left = try heard(plm([Pattern(cells: [(0, 1, .note())])], pans: [15, 0]))
    #expect(loudness(left.left[4800...]) > loudness(left.right[4800...]) * 10)
    let own = try heard(plm([Pattern(cells: [(0, 1, .note())])], pans: [15, 0], sounds: [Sound(pan: 15)]))
    #expect(loudness(own.right[4800...]) > loudness(own.left[4800...]) * 10)
    // Not a PLM file at all.
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(file.prefix(60)), format: .plm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("PLM".utf8) + [0x1A, 96, 0x11] + Array(file.dropFirst(6)), format: .plm) }
}

@Test func plmPatternsLieOnTheSongWhereTheListSays() throws {
    // Two patterns of 16 rows, one at row 0 on the first channel and one at row 72 on the second:
    // the song is cut into patterns of 64 rows, the second of them 24 rows long.
    let a = Pattern(rows: 16, channels: 1, cells: [(0, 0, .note())]), b = Pattern(rows: 16, channels: 1, cells: [(3, 0, .note(0x42, 1, 0x0B, 0))])
    let renderer = try #require(try TuneLoader.load(plm([a, b], items: [(0, 0, 0), (72, 1, 1)]), format: .plm) as? ITRenderer)
    let listing = renderer.listing()
    #expect(listing.orders.prefix(3) == [0, 1, 255])
    #expect(renderer.module.pattern(1).rows == 24)
    func cell(row: Int, channel: Int) -> ModuleListing.Cell? {
        listing.cells.first { (cell: ModuleListing.Cell) -> Bool in cell.pattern == 1 && cell.row == row && cell.channel == channel }
    }
    let laid = try #require(cell(row: 11, channel: 1))
    #expect(laid.note == 62)
    // A jump to the first item of the list: to its pattern, and a break to its row in the channel
    // the file has not got.
    #expect(laid.command == 2 && laid.value == 0)
    let breaks = try #require(cell(row: 11, channel: 2))
    #expect(breaks.command == 3 && breaks.value == 0)
}

@Test func plmStartsIntoASampleAsDisorderTrackerDoes() throws {
    let long = Sound(frames: (0 ..< 2048).map { UInt8($0 & 0xFF) })
    // By 256ths of its length: 0x80 is half way.
    let half = try ticks(plm([Pattern(cells: [(0, 0, .note(0x40, 1, 0x16, 0x80))])], sounds: [long]), 1)
    #expect(half[0].sounding && half[0].position == 1024)
    // With no note, it moves the note that is playing (and a start of 0x04 is 1,024 samples in).
    // (The note is laid by another item of the list: within one, a start with no note is one into
    // the item's last note on the channel, which is started again.)
    let note = Pattern(rows: 1, channels: 1, cells: [(0, 0, .note())]), start = Pattern(rows: 1, channels: 1, cells: [(0, 0, .command(0x0D, 0x04))])
    let moved = try ticks(plm([note, start], items: [(0, 0, 0), (1, 0, 1)], sounds: [long]), 7)
    #expect(moved[6].sounding && moved[6].position == 1024)
}

@Test func plmSlidesToNotesAsDisorderTrackerDoes() throws {
    // A slide to a note from F0 is a fine one, once, on the row's first tick.
    let fine = try ticks(plm([Pattern(cells: [(0, 0, .note()), (1, 0, .note(0x47, 0, 0x03, 0xF4))])]), 12)
    #expect(fine[6].rate > fine[0].rate && fine[11].rate == fine[6].rate && fine[11].rate < 12_000)
    // After a slide up, a slide to a note with none of its own goes on up.
    let away = try ticks(plm([Pattern(cells: [(0, 0, .note()), (1, 0, .command(0x01, 0x04)), (2, 0, .command(0x03, 0x10))])]), 18)
    #expect(away[11].rate > away[6].rate && away[17].rate > away[12].rate)
    // A slide that names another sample goes on with the one that is sounding.
    let other = Sound(frames: (0 ..< 32).map { $0 < 16 ? 255 : 1 }, rate: 16726)
    let kept = try ticks(plm([Pattern(cells: [(0, 0, .note()), (1, 0, .note(0x40, 2, 0x03, 0x10))])], sounds: [Sound(), other]), 12)
    #expect(kept[11].rate == kept[0].rate)
}

@Test func plmDamagedFilesDoNotTrap() throws {
    let whole = plm([Pattern(cells: [(0, 0, .note()), (2, 1, .note(0x42, 1, 0x16, 0x40)), (4, 0, .command(0x0B, 3))])], items: [(0, 0, 0), (40, 1, 0)])
    for length in stride(from: 0, to: whole.count, by: 7) {
        if let renderer = try? TuneLoader.load(Array(whole[..<length]), format: .plm) { _ = stereo(renderer, seconds: 0.1) }
    }
    var seed: UInt32 = 1
    for _ in 0 ..< 200 {
        var damaged = whole
        for _ in 0 ..< 4 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            damaged[Int(seed >> 8) % damaged.count] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        if let renderer = try? TuneLoader.load(damaged, format: .plm) { _ = stereo(renderer, seconds: 0.05) }
    }
}
