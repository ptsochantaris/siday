// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaTrackers
@testable import SidayFoundation
import Foundation
import Testing

// Fast checks of the player for SoundFX modules. The thorough check is made outside the package,
// against SoundFX's own replay routine run in an emulated Amiga: `SIDAY_SFX_TRACE=1 siday --raw
// /dev/null tune.sfx` writes what this player tells the sound chip, tick by tick, and the two are to
// be the same.

/// What a voice has on a line of a pattern.
private struct Entry {
    var line: Int
    var voice: Int
    var period: Int = 0
    var instrument: Int = 0
    var command: Int = 0
    var data: Int = 0
    var pattern = 0
}

private func bytes(_ value: Int, _ count: Int) -> [UInt8] {
    (0 ..< count).map { UInt8(truncatingIfNeeded: value >> ((count - 1 - $0) * 8)) }
}

/// A SoundFX module with two instruments, each a square wave of 64 bytes: the first at full volume
/// and repeating over its second half, the second at a volume of 40 and repeating over its first two
/// bytes, which is how a sample that does not repeat is written.
/// - Parameters:
///   - order: which pattern is played at each place.
///   - timer: what the timer counts from for a tick.
private func module(_ entries: [Entry], order: [Int] = [0], timer: Int = 14565) -> [UInt8] {
    var file = bytes(64, 4) + bytes(64, 4) + [UInt8](repeating: 0, count: 52)
    file += Array("SONG".utf8) + bytes(timer, 2) + [UInt8](repeating: 0, count: 14)
    func instrument(_ name: String, volume: Int, repeatStart: Int, repeatWords: Int) -> [UInt8] {
        Array(name.utf8) + [UInt8](repeating: 0, count: 22 - name.utf8.count) + bytes(32, 2) + bytes(volume, 2) + bytes(repeatStart, 2)
            + bytes(repeatWords, 2)
    }
    file += instrument("a square wave", volume: 64, repeatStart: 32, repeatWords: 16)
    file += instrument("and a quieter", volume: 40, repeatStart: 0, repeatWords: 1)
    file += [UInt8](repeating: 0, count: 13 * 30)
    file += [UInt8(order.count), 0] + order.map { UInt8($0) } + [UInt8](repeating: 0, count: 128 - order.count)
    let patterns = (order.max() ?? 0) + 1
    let first = file.count
    file += [UInt8](repeating: 0, count: patterns * 1024)
    for entry in entries {
        let at = first + entry.pattern * 1024 + entry.line * 16 + entry.voice * 4
        file.replaceSubrange(at ..< at + 4, with: bytes(entry.period, 2) + [UInt8(entry.instrument << 4 | entry.command), UInt8(entry.data)])
    }
    for _ in 0 ..< 2 {
        for _ in 0 ..< 2 { file += [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16) }
    }
    return file
}

/// Where the first instrument's sample is in a module of one pattern.
private let sample = 660 + 1024

private func ticks(_ file: [UInt8], seconds: Double = 2) throws -> [SoundFXTick] {
    try SoundFXRenderer(file, options: LoadOptions()).registerTicks(seconds: seconds)
}

/// What was written to a register of a voice on a tick, in order.
private func written(_ tick: SoundFXTick, _ voice: Int, _ register: SoundFXTick.Register) -> [Int] {
    tick.writes.filter { $0.voice == voice && $0.register == register }.map { $0.value }
}

/// The first tick of a line: a line lasts six, and the first is read on the sixth tick.
private func first(ofLine line: Int) -> Int { 5 + line * 6 }

@Test func soundFXModuleIsRead() throws {
    let file = module([Entry(line: 0, voice: 0, period: 428, instrument: 1), Entry(line: 0, voice: 0, period: 428, pattern: 1)], order: [0, 1, 0])
    let read = try SoundFXModule(file)
    #expect(read.positions == [0, 1, 0] && read.patternCount == 2 && read.timer == 14565)
    #expect(read.instruments[0].name == "a square wave" && read.instruments[0].words == 32 && read.instruments[0].volume == 64)
    #expect(read.instruments[0].start == 660 + 2048 && read.instruments[1].start == 660 + 2048 + 64)
    #expect(read.instruments[0].repeatStart == 32 && read.instruments[0].repeatWords == 16)
    // The routine clears the first four bytes of every sample.
    #expect((0 ..< 6).map { read.byte(read.instruments[0].start + $0) } == [0, 0, 0, 0, 0x7F, 0x7F])

    let renderer = try TuneLoader.load(file, format: .sfx)
    #expect(renderer.info.format == "SoundFX" && renderer.isPlayedOnAnAmiga && renderer.channelCount == 4 && renderer.endsByLooping)
    // Three patterns of 64 lines of six ticks, each tick 14,566 counts of a timer that counts a
    // fifth as fast as the sound chip's clock.
    let tick = 14566.0 * 5 / (28_375_160.0 / 8)
    #expect(abs((renderer.knownLength ?? 0) - 3 * 64 * 6 * tick) < 0.001)
}

@Test func whatIsNotASoundFXModuleIsRefused() throws {
    var file = module([])
    file[60] = 0x58
    #expect(throws: TuneError.self) { try SoundFXRenderer(file, options: LoadOptions()) }
    // The later SoundFX, of 31 instruments, says what it is 124 bytes in.
    var later = [UInt8](repeating: 0, count: 2000)
    later.replaceSubrange(124 ..< 128, with: Array("SO31".utf8))
    #expect(throws: TuneError.self) { try SoundFXRenderer(later, options: LoadOptions()) }
    // A sample of an odd length, and a timer of nothing.
    file = module([])
    file[3] = 65
    #expect(throws: TuneError.self) { try SoundFXRenderer(file, options: LoadOptions()) }
    file = module([], timer: 0)
    #expect(throws: TuneError.self) { try SoundFXRenderer(file, options: LoadOptions()) }
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .sfx) }
}

@Test func soundFXStartsANoteAndSaysWhereItGoesOnFrom() throws {
    let played = try ticks(module([Entry(line: 0, voice: 1, period: 428, instrument: 1), Entry(line: 2, voice: 1, period: 214)]))
    // Nothing is said on the five ticks before the first line.
    #expect(played[0 ..< 5].allSatisfy { $0.writes.isEmpty })
    let line = played[first(ofLine: 0)]
    #expect(line.clocks == 14566 * 5 && line.line == 0 && line.tickOfLine == 0)
    // The instrument's volume; then the note from the start of the sample, all of it; and then
    // where it repeats.
    #expect(written(line, 1, .volume) == [64] && written(line, 1, .period) == [428] && line.started == 2)
    #expect(written(line, 1, .location) == [sample, sample + 32] && written(line, 1, .length) == [32, 16])
    // Every voice is told where to go on from on every line, note or no note; a voice that has
    // had no instrument has nowhere.
    #expect(written(line, 0, .location) == [-1] && written(line, 0, .length) == [0])
    let next = played[first(ofLine: 1)]
    #expect(written(next, 1, .location) == [sample + 32] && written(next, 1, .length) == [16] && next.started == 0)
    #expect(written(next, 1, .volume).isEmpty && written(next, 1, .period).isEmpty)
    // A note with no instrument is played on the one the voice has, and its volume is not said again.
    let again = played[first(ofLine: 2)]
    #expect(written(again, 1, .period) == [214] && written(again, 1, .volume).isEmpty && written(again, 1, .location) == [sample, sample + 32])
}

@Test func soundFXInstrumentWithoutANoteChangesWhatTheNoteGoesOnWith() throws {
    let played = try ticks(module([Entry(line: 0, voice: 0, period: 428, instrument: 1), Entry(line: 1, voice: 0, instrument: 2)]))
    let line = played[first(ofLine: 1)]
    #expect(written(line, 0, .volume) == [40] && written(line, 0, .period).isEmpty && line.started == 0)
    #expect(written(line, 0, .location) == [sample + 64] && written(line, 0, .length) == [1])
}

@Test func soundFXVolumeCommandsCountFromTheInstrumentsVolume() throws {
    let played = try ticks(module([
        Entry(line: 0, voice: 0, period: 428, instrument: 2, command: 5, data: 10),
        Entry(line: 1, voice: 0, instrument: 2, command: 5, data: 60),
        Entry(line: 2, voice: 0, instrument: 2, command: 6, data: 15),
        Entry(line: 3, voice: 0, instrument: 2, command: 6, data: 60),
        // Without the instrument beside it the command does nothing.
        Entry(line: 4, voice: 0, command: 5, data: 10),
    ]))
    #expect((0 ..< 5).map { written(played[first(ofLine: $0)], 0, .volume) } == [[50], [64], [25], [0], []])
}

@Test func soundFXArpeggioPlaysTheNotesAboveByTheTickOfTheLine() throws {
    // Four and seven notes above the C of period 428, which are 339 and 285.
    let played = try ticks(module([Entry(line: 0, voice: 0, period: 428, instrument: 1, command: 1, data: 0x47)]))
    let at = first(ofLine: 0)
    #expect((1 ... 5).map { written(played[at + $0], 0, .period) } == [[339], [285], [428], [285], [339]])
    // The line after has no command, and the voice is left alone.
    #expect((6 ... 11).allSatisfy { written(played[at + $0], 0, .period).isEmpty })
}

@Test func soundFXBendWorksOnThePeriodOfItsOwnLine() throws {
    let played = try ticks(module([
        Entry(line: 0, voice: 0, period: 428, instrument: 1, command: 2, data: 0x30),
        Entry(line: 1, voice: 0, period: 428, command: 2, data: 0x05),
        // On a line with no note it starts from nothing.
        Entry(line: 2, voice: 0, command: 2, data: 0x20),
    ]))
    #expect((1 ... 5).map { written(played[first(ofLine: 0) + $0], 0, .period) } == [[431], [434], [437], [440], [443]])
    #expect((1 ... 5).map { written(played[first(ofLine: 1) + $0], 0, .period) } == [[423], [418], [413], [408], [403]])
    #expect((1 ... 5).map { written(played[first(ofLine: 2) + $0], 0, .period) } == [[2], [4], [6], [8], [10]])
}

@Test func soundFXSlideGoesOnOverTheLinesThatFollowUntilANewNote() throws {
    // Down to the note two below the C of 428, which is 480, by 9 a tick; and on the line after
    // an arpeggio that is never looked at, because the slide has the voice.
    let played = try ticks(module([
        Entry(line: 0, voice: 0, period: 428, instrument: 1, command: 7, data: 0x29),
        Entry(line: 1, voice: 0, command: 1, data: 0x47),
        Entry(line: 3, voice: 0, period: 428, command: 8, data: 0x1F),
    ]))
    let at = first(ofLine: 0)
    // (The first tick only sets it going.)
    #expect((1 ... 5).map { written(played[at + $0], 0, .period) } == [[], [437], [446], [455], [464]])
    #expect((7 ... 11).map { written(played[at + $0], 0, .period) } == [[473], [480], [480], [480], [480]])
    // A new note ends it; and the other slide goes up, to the note one above, 404.
    let up = first(ofLine: 3)
    #expect((1 ... 5).map { written(played[up + $0], 0, .period) } == [[], [413], [404], [404], [404]])
}

@Test func soundFXVibratoSwingsInStepsOfEight() throws {
    // Two steps either side of the note, a step every tick.
    let played = try ticks(module([Entry(line: 0, voice: 0, period: 428, instrument: 1, command: 9, data: 0x21)]))
    let at = first(ofLine: 0)
    let periods = (1 ... 11).flatMap { written(played[at + $0], 0, .period) }
    #expect(periods == [436, 444, 436, 428, 420, 412, 420, 428, 436])
}

@Test func soundFXMarksInPlaceOfANote() throws {
    let played = try ticks(module([
        Entry(line: 0, voice: 0, period: 428, instrument: 1),
        // Stop: the voice is turned down, and set going again on what it was to go on with.
        Entry(line: 1, voice: 0, period: 0xFFFE),
        // Nothing: and the line's instrument and command are not looked at either.
        Entry(line: 2, voice: 0, period: 0xFFFD, instrument: 2, command: 2, data: 0x30),
    ]))
    let stop = played[first(ofLine: 1)]
    #expect(written(stop, 0, .volume) == [0] && written(stop, 0, .period).isEmpty && stop.started == 1)
    #expect(written(stop, 0, .location) == [sample + 32])
    let nothing = first(ofLine: 2)
    #expect(written(played[nothing], 0, .volume).isEmpty && played[nothing].started == 0)
    #expect((1 ... 5).allSatisfy { played[nothing + $0].writes.isEmpty })

    // A voice that is stopped has not begun a note, for the lights.
    let renderer = try SoundFXRenderer(module([Entry(line: 0, voice: 0, period: 428, instrument: 1), Entry(line: 4, voice: 0, period: 0xFFFE)]),
                                       options: LoadOptions())
    var buffer = [Float](repeating: 0, count: 2 * 4800)
    var pitches = [Float](repeating: 0, count: 4)
    var struck = [Bool](repeating: false, count: 4)
    var strikes = 0
    for _ in 0 ..< 10 {
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
        if struck[0] { strikes += 1 }
    }
    #expect(strikes == 1)
}

@Test func soundFXFileIsDividedAtAPatternOfSilence() throws {
    let note = Entry(line: 0, voice: 0, period: 428, instrument: 1)
    var other = note
    other.pattern = 2
    // Pattern 1 is empty: the order 0 0 1 2 2 is two songs, of two patterns each.
    let renderer = try SoundFXRenderer(module([note, other], order: [0, 0, 1, 2, 2]), options: LoadOptions())
    #expect(renderer.subsongCount == 2 && renderer.defaultSubsong == 0)
    let pattern = 64 * 6 * 14566.0 * 5 / (28_375_160.0 / 8)
    #expect(renderer.songs.allSatisfy { abs(($0.length ?? 0) - 2 * pattern) < 0.001 })
    renderer.select(subsong: 1)
    let played = renderer.registerTicks(seconds: 1)
    #expect(played[first(ofLine: 0)].position == 3 && written(played[first(ofLine: 0)], 0, .period) == [428])
    // An empty pattern with nothing after it parts nothing; and where the ticks come fast, and a
    // pattern is short, an empty one is a pause.
    #expect(try SoundFXRenderer(module([note], order: [0, 1]), options: LoadOptions()).subsongCount == 1)
    #expect(try SoundFXRenderer(module([note, other], order: [0, 0, 1, 2, 2], timer: 7094), options: LoadOptions()).subsongCount == 1)
}

@Test func soundFXIsHeardAndComesRound() throws {
    let renderer = try SoundFXRenderer(module([Entry(line: 0, voice: 0, period: 428, instrument: 1), Entry(line: 0, voice: 1, period: 214, instrument: 1)],
                                              timer: 2000), options: LoadOptions())
    let frames = Int(5 * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    #expect(buffer.contains { abs($0) > 0.05 } && buffer.allSatisfy { abs($0) <= 1 })
    // The pattern is 64 lines of six ticks of 10,005 clocks: a little over a second.
    #expect(renderer.loopCount == 4)
    var levels = [Float](repeating: 0, count: 4)
    renderer.takeChannelLevels(into: &levels)
    #expect(levels[0] > 0.5 && levels[1] > 0.5 && levels[2] == 0 && levels[3] == 0)
}

@Test func soundFXFileThatIsCutShortOrIsNonsenseDoesNotTrap() throws {
    let whole = module([Entry(line: 0, voice: 0, period: 428, instrument: 1, command: 1, data: 0x47)], order: [0, 1])
    var buffer = [Float](repeating: 0, count: 2 * 4800)
    for length in stride(from: 0, to: whole.count, by: 97) {
        guard let renderer = try? SoundFXRenderer(Array(whole[0 ..< length]), options: LoadOptions()) else { continue }
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
    }
    var generator = SystemRandomNumberGenerator()
    for _ in 0 ..< 200 {
        var file = whole
        for _ in 0 ..< 40 {
            // (Anywhere but the letters that say what it is, which would only have it refused.)
            let at = Int.random(in: 0 ..< file.count, using: &generator)
            if at < 60 || at >= 64 { file[at] = UInt8.random(in: 0 ... 255, using: &generator) }
        }
        guard let renderer = try? SoundFXRenderer(file, options: LoadOptions()) else { continue }
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        _ = renderer.registerTicks(seconds: 3)
    }
}

// MARK: What is not played as the file asks

@Test func soundFXFileShorterThanItsSamplesSaysSo() throws {
    let whole = module([Entry(line: 0, voice: 0, period: 428, instrument: 1)])
    #expect(try SoundFXRenderer(whole, options: LoadOptions()).info.shortfalls.isEmpty)
    #expect(try SoundFXRenderer(Array(whole.dropLast(40)), options: LoadOptions()).info.shortfalls == ["The file is cut short: its last sample ends in silence."])
    #expect(try SoundFXRenderer(Array(whole.dropLast(64)), options: LoadOptions()).info.shortfalls
        == ["The file is cut short: one of its samples is missing, and is silent."])
}

// MARK: Voices left out

/// What a player makes of its tune from where it is, the two sides apart, and what it then says of
/// each voice: how loud it has been, and its pitch.
private func listened(_ renderer: any Renderer, seconds: Double = 0.5) -> (left: [Float], right: [Float], levels: [Float], pitches: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    var levels = [Float](repeating: 0, count: renderer.channelCount)
    var pitches = levels
    var struck = [Bool](repeating: false, count: renderer.channelCount)
    renderer.takeChannelLevels(into: &levels)
    renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] }, levels, pitches)
}

private func loudest(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }
/// The most that two sounds differ by at any sample.
private func apart(_ a: [Float], _ b: [Float]) -> Float { a.count == b.count ? zip(a, b).map { abs($0 - $1) }.max() ?? 0 : .infinity }

@Test func soundFXVoiceLeftOutIsNotHeardAndPlaysOn() throws {
    // A note on the first voice, which the Amiga has on the left, and one on the second, on the right.
    var options = LoadOptions()
    options.stereo = .abc
    options.amigaSeparation = 1
    let file = module([Entry(line: 0, voice: 0, period: 428, instrument: 1), Entry(line: 0, voice: 1, period: 214, instrument: 1)], timer: 2000)
    func fresh() throws -> any Renderer { try TuneLoader.load(file, format: .sfx, options: options) }
    let whole = listened(try fresh())
    #expect(loudest(whole.left) > 0.2 && loudest(whole.right) > 0.2)

    // The second voice left out: the right is silent, the left is what it was (to the last place
    // or two of a number: the two sides are brought together and parted again on the way out), and
    // the voice is still said to be as loud as it was, at the pitch it was.
    let renderer = try fresh()
    renderer.setMuted([false, true])
    let without = listened(renderer)
    #expect(loudest(without.right) == 0)
    #expect(apart(without.left, whole.left) < 1e-5)
    #expect(without.levels == whole.levels && without.levels[1] > 0.5)
    #expect(without.pitches == whole.pitches && without.pitches[1] > 0)

    // A song started again is started without the voice; and with it brought back, as it ever was.
    renderer.select(subsong: 0)
    let again = listened(renderer)
    #expect(again.left == without.left && again.right == without.right)
    renderer.setMuted([])
    renderer.select(subsong: 0)
    let back = listened(renderer)
    #expect(back.left == whole.left && back.right == whole.right)

    // Every voice left out is silence, and the lights are as they were.
    let silent = try fresh()
    silent.setMuted([true, true, true, true])
    let nothing = listened(silent)
    #expect(loudest(nothing.left) == 0 && loudest(nothing.right) == 0)
    #expect(nothing.levels == whole.levels)
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

@Test func soundFXVoicesHaveScopes() throws {
    // A note at full volume on the first voice, one at a quarter of it on the second, and nothing
    // on the others.
    let file = module([
        Entry(line: 0, voice: 0, period: 428, instrument: 1),
        Entry(line: 0, voice: 1, period: 428, instrument: 1, command: 6, data: 48),
    ])
    func fresh() throws -> any Renderer { try TuneLoader.load(file, format: .sfx, options: LoadOptions()) }
    let heard = scopes(try fresh())
    // The chip's band-limited steps overshoot a square's edges by a third, and a scope is as tall
    // as all of it: the square's own level is three quarters of the way up.
    #expect(height(heard[0]) > 90)
    // A quarter of the swing is half the height, or a little more, of the overshoot too.
    let part = Double(height(heard[1])) / Double(height(heard[0]))
    #expect(part > 0.45 && part < 0.75)
    #expect(heard[2].allSatisfy { $0 == 128 } && heard[3].allSatisfy { $0 == 128 })

    // A voice left out still has its scope.
    let muted = try fresh()
    muted.setMuted([true])
    #expect(height(scopes(muted)[0]) == height(heard[0]))

    // And the sound is the same, its voices kept or not.
    let plain = try fresh(), kept = try fresh()
    #expect(kept.keepChannelWaves() != nil)
    let without = listened(plain, seconds: 1), with = listened(kept, seconds: 1)
    #expect(with.left == without.left && with.right == without.right)
}
