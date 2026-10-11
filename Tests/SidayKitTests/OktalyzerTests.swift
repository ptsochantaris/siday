// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of the player for Oktalyzer modules. The thorough check is made outside the package,
// against Oktalyzer's own replay routine run in an emulated Amiga: `SIDAY_OKT_TRACE=1 siday --raw
// /dev/null tune.okt` writes what this player tells the sound chip, tick by tick, and what it mixes
// for the chip goes to the file `SIDAY_OKT_MIXED` names; the two are to be the same.

/// What a track has on a line of a pattern: a note (1 is the lowest C), an instrument (counted from
/// nought) and a command.
private struct Entry {
    var line: Int
    var track: Int
    var note: Int = 0
    var instrument: Int = 0
    var command: Int = 0
    var data: Int = 0
    var pattern = 0
}

private func bytes(_ value: Int, _ count: Int) -> [UInt8] {
    (0 ..< count).map { UInt8(truncatingIfNeeded: value >> ((count - 1 - $0) * 8)) }
}

private func piece(_ name: String, _ body: [UInt8]) -> [UInt8] {
    Array(name.utf8) + bytes(body.count, 4) + body
}

/// The samples of the module that is made: a ramp of 256 bytes that goes up by one (for either kind
/// of voice, repeating over 32 words from its 16th); the same at half the size and a volume of 40,
/// for a whole voice only, that does not repeat; and a ramp that goes down by two, for a split voice
/// only.
private let ramp: [UInt8] = (0 ..< 256).map { UInt8(truncatingIfNeeded: $0 - 128) }
private let short: [UInt8] = (0 ..< 128).map { UInt8(truncatingIfNeeded: $0 - 64) }
private let falling: [UInt8] = (0 ..< 256).map { UInt8(truncatingIfNeeded: 100 - 2 * $0) }

/// An Oktalyzer module of one or more patterns of eight lines.
/// - Parameters:
///   - split: which of the four voices have two tracks.
///   - order: which pattern is played at each place.
private func module(_ entries: [Entry], split: [Bool] = [false, false, false, false], order: [Int] = [0], speed: Int = 3, lines: Int = 8) -> [UInt8] {
    let tracks = 4 + split.filter { $0 }.count
    var file = Array("OKTASONG".utf8) + piece("CMOD", split.flatMap { bytes($0 ? 1 : 0, 2) })
    func instrument(_ name: String, length: Int, repeatStart: Int, repeatWords: Int, volume: Int, use: Int) -> [UInt8] {
        Array(name.utf8) + [UInt8](repeating: 0, count: 20 - name.utf8.count) + bytes(length, 4) + bytes(repeatStart, 2) + bytes(repeatWords, 2)
            + [0, UInt8(volume)] + bytes(use, 2)
    }
    var headers = instrument("a ramp", length: 256, repeatStart: 16, repeatWords: 32, volume: 64, use: 2)
    headers += instrument("a shorter one", length: 128, repeatStart: 0, repeatWords: 0, volume: 40, use: 1)
    headers += instrument("and one down", length: 256, repeatStart: 0, repeatWords: 0, volume: 64, use: 0)
    headers += [UInt8](repeating: 0, count: 33 * 32)
    file += piece("SAMP", headers) + piece("SPEE", bytes(speed, 2))
    let patterns = (order.max() ?? 0) + 1
    file += piece("SLEN", bytes(patterns, 2)) + piece("PLEN", bytes(order.count, 2))
    file += piece("PATT", order.map { UInt8($0) } + [UInt8](repeating: 0, count: 128 - order.count))
    for pattern in 0 ..< patterns {
        var body = bytes(lines, 2) + [UInt8](repeating: 0, count: lines * tracks * 4)
        for entry in entries where entry.pattern == pattern {
            let at = 2 + (entry.line * tracks + entry.track) * 4
            body.replaceSubrange(at ..< at + 4, with: [UInt8(entry.note), UInt8(entry.instrument), UInt8(entry.command), UInt8(entry.data)])
        }
        file += piece("PBOD", body)
    }
    return file + piece("SBOD", ramp) + piece("SBOD", short) + piece("SBOD", falling)
}

private func ticks(_ file: [UInt8], seconds: Double = 2, wordsSeen: [[Int]]? = nil) throws -> [OktalyzerTick] {
    try OktalyzerRenderer(file, options: LoadOptions()).registerTicks(seconds: seconds, wordsSeen: wordsSeen)
}

/// What was written to a register of a voice on a tick, in order.
private func written(_ tick: OktalyzerTick, _ voice: Int, _ register: OktalyzerTick.Register) -> [Int] {
    tick.writes.filter { $0.voice == voice && $0.register == register }.map { $0.value }
}

/// Where a sample is in a module: the place of the nth piece of that name.
private func place(of name: String, _ number: Int, in file: [UInt8]) -> Int {
    var at = 8, found = 0
    while at + 8 <= file.count {
        let length = Int(file[at + 4]) << 24 | Int(file[at + 5]) << 16 | Int(file[at + 6]) << 8 | Int(file[at + 7])
        if Array(file[at ..< at + 4]) == Array(name.utf8) {
            if found == number { return at + 8 }
            found += 1
        }
        at += 8 + length
    }
    return -1
}

/// At a speed of three the first line is read on the third tick, and a whole voice is given its
/// note on the tick after: that is the first tick of the line, for a whole voice.
private func first(ofLine line: Int, speed: Int = 3) -> Int { speed + line * speed }

@Test func oktalyzerModuleIsRead() throws {
    let file = module([Entry(line: 0, track: 0, note: 13)], split: [true, false, true, false], order: [0, 1, 0])
    let read = try OktalyzerModule(file)
    #expect(read.split == [true, false, true, false] && read.trackCount == 6 && read.speed == 3 && read.positions == [0, 1, 0])
    #expect(read.patterns.count == 2 && read.patterns[0].lines == 8 && read.rowsInAll == 24)
    #expect(read.instruments[0].name == "a ramp" && read.instruments[0].length == 256 && read.instruments[0].use == .either)
    #expect(read.instruments[0].repeatStart == 16 && read.instruments[0].repeatWords == 32 && read.instruments[1].volume == 40)
    #expect(read.instruments[1].use == .whole && read.instruments[2].use == .split && read.instruments[3].place == nil)
    #expect(read.instruments[0].place == place(of: "SBOD", 0, in: file) && read.instruments[2].place == place(of: "SBOD", 2, in: file))
    #expect(read.cell(position: 0, line: 0, track: 0).note == 13)

    let renderer = try TuneLoader.load(file, format: .okt)
    #expect(renderer.info.format == "Oktalyzer" && renderer.info.detail == "6 tracks" && renderer.isPlayedOnAnAmiga)
    #expect(renderer.channelCount == 6 && renderer.endsByLooping)
    // Three patterns of eight lines of three ticks, after the three ticks before the first line is
    // read, each tick 14,212 counts of a timer that counts a fifth as fast as the sound chip's clock.
    #expect(abs((renderer.knownLength ?? 0) - 75 * 14212.0 * 5 / (28_375_160.0 / 8)) < 0.001)
}

@Test func whatIsNotAnOktalyzerModuleIsRefused() throws {
    var file = module([])
    file[0] = 0x58
    #expect(throws: TuneError.self) { try OktalyzerRenderer(file, options: LoadOptions()) }
    // A voice that is neither whole nor split.
    file = module([])
    file[17] = 2
    #expect(throws: TuneError.self) { try OktalyzerRenderer(file, options: LoadOptions()) }
    #expect(throws: TuneError.self) { try OktalyzerRenderer(Array(module([])[0 ..< 40]), options: LoadOptions()) }
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .okt) }
}

@Test func oktalyzerWholeVoiceIsToldItsNoteAndSetGoingATickLater() throws {
    let file = module([Entry(line: 0, track: 1, note: 13, instrument: 0), Entry(line: 2, track: 1, note: 25, instrument: 1)])
    let played = try ticks(file)
    let ramp = place(of: "SBOD", 0, in: file), short = place(of: "SBOD", 1, in: file)
    // Until then every voice is told its volume on every tick, and nothing else.
    #expect(played[0 ..< 3].allSatisfy { tick in tick.writes.allSatisfy { $0.register == .volume && $0.value == 64 } && tick.writes.count == 4 })
    #expect(played[0].clocks == 14212 * 5)
    // The note: from the start of the sample to the end of the part that repeats, 48 words.
    let told = played[first(ofLine: 0)]
    #expect(written(told, 1, .location) == [ramp] && written(told, 1, .length) == [48] && written(told, 1, .period) == [428])
    #expect(written(told, 1, .volume) == [64])
    // And on the tick after, where it is to go on from: the part that repeats.
    let going = played[first(ofLine: 0) + 1]
    #expect(written(going, 1, .location) == [ramp + 32] && written(going, 1, .length) == [32] && written(going, 1, .period).isEmpty)
    // A sample that does not repeat is played whole, at its own volume, and goes on with a word of silence.
    let other = played[first(ofLine: 2)]
    #expect(written(other, 1, .location) == [short] && written(other, 1, .length) == [64] && written(other, 1, .period) == [214])
    #expect(written(other, 1, .volume) == [40])
    #expect(written(played[first(ofLine: 2) + 1], 1, .location) == [-1] && written(played[first(ofLine: 2) + 1], 1, .length) == [1])
}

@Test func oktalyzerInstrumentForASplitVoiceIsNotPlayedOnAWholeOne() throws {
    let played = try ticks(module([Entry(line: 0, track: 0, note: 13, instrument: 2)]))
    #expect(played.allSatisfy { written($0, 0, .period).isEmpty && written($0, 0, .location).isEmpty })
}

@Test func oktalyzerSlidesAndArpeggiosOfAWholeVoice() throws {
    let played = try ticks(module([
        // The period down by 5 a tick, and up by 7: on every tick of the line, its first too.
        Entry(line: 0, track: 0, note: 13, command: 1, data: 5),
        Entry(line: 1, track: 0, command: 2, data: 7),
        // The three arpeggios, of the notes three below and four above the C of 428: 508 and 339.
        Entry(line: 2, track: 0, note: 13, command: 10, data: 0x34),
        Entry(line: 3, track: 0, command: 11, data: 0x34),
        Entry(line: 4, track: 0, command: 12, data: 0x34),
    ], speed: 4), seconds: 3)
    func periods(_ line: Int) -> [[Int]] { (0 ..< 4).map { written(played[first(ofLine: line, speed: 4) + $0], 0, .period) } }
    #expect(periods(0) == [[428, 423], [418], [413], [408]])
    #expect(periods(1) == [[415], [422], [429], [436]])
    #expect(periods(2) == [[428, 508], [428], [339], [508]])
    #expect(periods(3) == [[428], [339], [428], [508]])
    // (The third kind goes up by both its digits, to 360 and 339, and does nothing on the first tick.)
    #expect(periods(4) == [[], [360], [339], [428]])
}

@Test func oktalyzerNoteSlidesMoveTheNoteItself() throws {
    let played = try ticks(module([
        Entry(line: 0, track: 0, note: 13, command: 30, data: 1),
        Entry(line: 1, track: 0, command: 17, data: 2),
        Entry(line: 2, track: 0, command: 13, data: 1),
        Entry(line: 3, track: 0, command: 21, data: 2),
        // Off the top of the three octaves it stays on the highest note.
        Entry(line: 4, track: 0, note: 36, command: 30, data: 5),
    ]), seconds: 3)
    func periods(_ line: Int) -> [[Int]] { (0 ..< 3).map { written(played[first(ofLine: line) + $0], 0, .period) } }
    #expect(periods(0) == [[428, 404], [381], [360]])
    #expect(periods(1) == [[320], [], []])
    #expect(periods(2) == [[339], [360], [381]])
    #expect(periods(3) == [[428], [], []])
    #expect(periods(4) == [[113, 113], [113], [113]])
}

@Test func oktalyzerVolumeCommands() throws {
    let played = try ticks(module([
        Entry(line: 0, track: 0, note: 13, command: 31, data: 0x20),
        // Down by 3 on every tick, up by 2 on every tick, down by 5 and up by 4 on the first tick only.
        Entry(line: 1, track: 0, command: 31, data: 0x43),
        Entry(line: 2, track: 0, command: 31, data: 0x52),
        Entry(line: 3, track: 0, command: 31, data: 0x65),
        Entry(line: 4, track: 0, command: 31, data: 0x74),
        // A note that keeps the volume the voice had, where its instrument's would be 64.
        Entry(line: 5, track: 0, note: 13, command: 24, data: 0),
        Entry(line: 6, track: 0, note: 13),
    ]), seconds: 3)
    func volumes(_ line: Int) -> [Int] { (0 ..< 3).flatMap { written(played[first(ofLine: line) + $0], 0, .volume) } }
    #expect(volumes(0) == [32, 32, 32])
    #expect(volumes(1) == [29, 26, 23])
    #expect(volumes(2) == [25, 27, 29])
    #expect(volumes(3) == [24, 24, 24])
    #expect(volumes(4) == [28, 28, 28])
    #expect(volumes(5) == [28, 28, 28])
    #expect(volumes(6) == [64, 64, 64])
}

@Test func oktalyzerSpeedAndTheWayOnToAnotherPlace() throws {
    // The speed becomes two; then from the first pattern's third line to place 12 of the order,
    // which is written as it is said: 0x12.
    var order = [Int](repeating: 0, count: 13)
    order[12] = 1
    var there = Entry(line: 0, track: 2, note: 13)
    there.pattern = 1
    let played = try ticks(module([Entry(line: 0, track: 0, command: 28, data: 2), Entry(line: 2, track: 0, command: 25, data: 0x12), there],
                                  order: order), seconds: 3)
    // Line 0 is read on the third tick, and its command is carried out on the tick after, as a
    // whole voice's are; so lines 1 and 2 are read two ticks apart from there, and then place 12.
    #expect(played[2].line == 0 && played[4].line == 1 && played[6].line == 2 && played[8].position == 12 && played[8].line == 0)
    #expect(written(played[9], 2, .period) == [428])

    // A file's songs: the first two patterns go round by a jump, and the third is never reached
    // from them.
    var second = Entry(line: 0, track: 0, note: 13)
    second.pattern = 2
    var back = Entry(line: 7, track: 0, command: 25, data: 0)
    back.pattern = 1
    var round = Entry(line: 7, track: 0, command: 25, data: 2)
    round.pattern = 2
    let renderer = try OktalyzerRenderer(module([Entry(line: 0, track: 0, note: 13), back, second, round], order: [0, 1, 2], speed: 15, lines: 8),
                                         options: LoadOptions())
    #expect(renderer.subsongCount == 2)
    let tick = 14212.0 * 5 / (28_375_160.0 / 8)
    // (Each is as long as its lines, and the line's worth of ticks before its first line is read.)
    #expect(abs((renderer.songs[0].length ?? 0) - 17 * 15 * tick) < 0.001 && abs((renderer.songs[1].length ?? 0) - 9 * 15 * tick) < 0.001)
}

@Test func oktalyzerSplitVoiceBeginsOnSilenceAndIsGivenAWordMoreWhenTheChipIsAhead() throws {
    let played = try ticks(module([], split: [true, false, false, false]))
    // Nothing to mix is 41 words of silence at the lowest note's period, which the chip gets
    // through in a little less than a tick: so on the ticks that find it ahead, 42.
    #expect(played[0].mixed[0] == [Int8](repeating: 0, count: 82) && played[0].mixed[1].isEmpty)
    #expect(written(played[0], 0, .period).isEmpty && written(played[0], 0, .length) == [41])
    #expect(written(played[1], 0, .period) == [856])
    let lengths = played[0 ..< 60].flatMap { written($0, 0, .length) }
    #expect(lengths.allSatisfy { $0 == 41 || $0 == 42 } && lengths[1] == 42)
    // In the long run a tick's worth of words is played in a tick.
    let words = played[1 ..< 81].flatMap { written($0, 0, .length) }.reduce(0, +)
    #expect(abs(words * 2 * 856 - 80 * 14212 * 5) < 3 * 856)
}

@Test func oktalyzerOneTrackOfASplitVoiceIsCopiedAsItIs() throws {
    // The C of 428: 83 words to a tick. The voice is not told a volume by the note, nor where its
    // sample is: only the period of what was mixed, a tick later.
    let file = module([Entry(line: 0, track: 0, note: 13, instrument: 2)], split: [true, false, false, false])
    let seen = [[Int]](repeating: [0], count: 40)
    let played = try ticks(file, wordsSeen: seen)
    let read = played[2]
    #expect(read.line == 0 && read.mixed[0].count == 166 && read.mixed[0] == falling[0 ..< 166].map { Int8(bitPattern: $0) })
    #expect(written(read, 0, .length) == [83] && written(played[3], 0, .period) == [428])
    // The sample has 256 bytes: the second tick's worth would need more than are left, so what is
    // left is played, with silence after it, and the note is over.
    #expect(played[3].mixed[0] == falling[166 ..< 256].map { Int8(bitPattern: $0) } + [Int8](repeating: 0, count: 76))
    #expect(played[4].mixed[0] == [Int8](repeating: 0, count: 82) && written(played[5], 0, .period) == [856])
    // An instrument for a whole voice only is not played on a split one.
    let other = try ticks(module([Entry(line: 0, track: 0, note: 13, instrument: 1)], split: [true, false, false, false]))
    #expect(other[0 ..< 10].allSatisfy { $0.mixed[0].allSatisfy { $0 == 0 } })
}

@Test func oktalyzerTwoTracksAreMixedAtThePeriodOfTheHigherNote() throws {
    // The C of 428 on the ramp that goes up, and the C an octave above it, of 214, on the one that
    // goes down: the voice is played at 214, 166 words to a tick, and the lower note is stretched
    // to it, each of its bytes used twice.
    let file = module([Entry(line: 0, track: 0, note: 13, instrument: 0), Entry(line: 0, track: 1, note: 25, instrument: 2)],
                      split: [true, false, false, false])
    let played = try ticks(file, wordsSeen: [[Int]](repeating: [0], count: 40))
    let mixed = played[2].mixed[0]
    #expect(mixed.count == 332 && written(played[3], 0, .period) == [214])
    // The higher note has 128 words: they are added four bytes at a time, as one number, so a
    // byte that overflows carries into the byte before it.
    var expected = [UInt8](repeating: 0, count: 332)
    for i in 0 ..< 332 { expected[i] = ramp[i / 2] }
    for long in 0 ..< 64 {
        var sum: UInt32 = 0, add: UInt32 = 0
        for k in 0 ..< 4 {
            sum = sum << 8 | UInt32(expected[long * 4 + k])
            add = add << 8 | UInt32(falling[long * 4 + k])
        }
        sum &+= add
        for k in 0 ..< 4 { expected[long * 4 + k] = UInt8(truncatingIfNeeded: sum >> UInt32((3 - k) * 8)) }
    }
    #expect(mixed == expected.map { Int8(bitPattern: $0) })
    // (And they do carry: adding byte by byte gives something else.)
    #expect(mixed != (0 ..< 332).map { Int8(bitPattern: ramp[$0 / 2] &+ ($0 < 256 ? falling[$0] : 0)) })
    // The higher note is over; the lower goes on by itself at its own period, from the byte it
    // had got to: 166 of its bytes are used.
    #expect(written(played[4], 0, .period) == [428])
    #expect(Array(played[3].mixed[0].prefix(4)) == ramp[166 ..< 170].map { Int8(bitPattern: $0) })
}

@Test func oktalyzerSplitVoiceGoesNoHigherThanItsLengthsDo() throws {
    // The highest note of all is played as the A below it, of period 127: 279 words to a tick.
    let played = try ticks(module([Entry(line: 0, track: 0, note: 36, instrument: 0)], split: [true, false, false, false]),
                           wordsSeen: [[Int]](repeating: [0], count: 40))
    #expect(written(played[3], 0, .period) == [127] && written(played[2], 0, .length) == [279])
}

@Test func oktalyzerIsHeardOnEveryTrack() throws {
    let entries = [
        Entry(line: 0, track: 0, note: 13, instrument: 0), Entry(line: 0, track: 1, note: 20, instrument: 2),
        Entry(line: 0, track: 2, note: 13, instrument: 0), Entry(line: 0, track: 3, note: 25, instrument: 1),
        Entry(line: 0, track: 4, note: 13, instrument: 0),
    ]
    let renderer = try OktalyzerRenderer(module(entries, split: [true, false, false, false], speed: 2), options: LoadOptions())
    #expect(renderer.channelCount == 5)
    var buffer = [Float](repeating: 0, count: 2 * 2400)
    var levels = [Float](repeating: 0, count: 5)
    var most = [Float](repeating: 0, count: 5)
    var pitches = [Float](repeating: 0, count: 5)
    var struck = [Bool](repeating: false, count: 5)
    var strikes = [Int](repeating: 0, count: 5)
    var heard = false
    for _ in 0 ..< 30 {
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 2400) }
        heard = heard || buffer.contains { abs($0) > 0.02 }
        #expect(buffer.allSatisfy { abs($0) <= 1 })
        renderer.takeChannelLevels(into: &levels)
        renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
        for track in 0 ..< 5 {
            most[track] = max(most[track], levels[track])
            if struck[track] { strikes[track] += 1 }
        }
    }
    #expect(heard && most.allSatisfy { $0 > 0.05 })
    // The pattern is eight lines of two ticks, a third of a second: it comes round four times in a
    // second and a half, and each track's note is begun each time.
    #expect(renderer.loopCount == 4 && strikes.allSatisfy { $0 >= 4 && $0 <= 5 })
}

@Test func oktalyzerFileThatIsCutShortOrIsNonsenseDoesNotTrap() throws {
    let whole = module([Entry(line: 0, track: 0, note: 13, instrument: 0, command: 10, data: 0x47), Entry(line: 1, track: 1, note: 30, instrument: 2),
                        Entry(line: 0, track: 2, note: 13, instrument: 1)], split: [true, false, true, false], order: [0, 1])
    var buffer = [Float](repeating: 0, count: 2 * 4800)
    for length in stride(from: 0, to: whole.count, by: 61) {
        guard let renderer = try? OktalyzerRenderer(Array(whole[0 ..< length]), options: LoadOptions()) else { continue }
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
    }
    var generator = SystemRandomNumberGenerator()
    for _ in 0 ..< 200 {
        var file = whole
        for _ in 0 ..< 40 {
            // (Anywhere but the letters that say what it is, which would only have it refused.)
            let at = Int.random(in: 8 ..< file.count, using: &generator)
            file[at] = UInt8.random(in: 0 ... 255, using: &generator)
        }
        guard let renderer = try? OktalyzerRenderer(file, options: LoadOptions()) else { continue }
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        _ = renderer.registerTicks(seconds: 3)
    }
}
