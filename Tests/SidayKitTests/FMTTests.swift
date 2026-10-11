// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of FMT files, the songs of Davey W Taylor's FM Tracker, on files made here. There is
// no player of the tracker's own to hold this one to: what it is held to is OpenMPT, whose loader is
// all that is written down of the format. The thorough check is made outside the package: every
// register this player sets and the tick it sets it on, against the same worked out from OpenMPT's
// loader and its arithmetic for pitch.

private func padded(_ text: String, _ length: Int) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: length - text.utf8.count) }

/// A voice of a pattern with nothing in it: one byte, for all its rows.
private func empty(_ rows: Int) -> [UInt8] { [0x80 | UInt8(rows - 1)] }

/// An FMT file whose eight instruments are plain sines that hold.
/// - Parameters:
///   - patterns: each pattern's number, and its voices' bytes as they are in the file, the first
///     voices: the rest are empty. If none are given there is one pattern, with one note at its start.
private func fmt(
    title: String = "one note", rows: Int = 4, orders: [UInt8] = [0], delays: [UInt8] = [3],
    patterns given: [(number: UInt8, voices: [[UInt8]])]? = nil
) -> [UInt8] {
    let patterns = given ?? [(0, [[49, 0x80 | UInt8(rows - 2)]])]
    var file = Array("FMTracker".utf8) + [1, 1] + padded("The FM Tracker!", 20) + padded(title, 32)
    for voice in 0 ..< 8 {
        // The first operator silent and the second at full level, both holding, joined so that only the second is heard.
        file += padded("SINE\(voice)", 8) + [0x21, 0x21, 0x3F, 0x00, 0xF0, 0xF0, 0x0F, 0x0F, 0x00, 0x00, 0x00]
    }
    file += [UInt8(rows - 1), UInt8(orders.count - 1), UInt8(patterns.count - 1)]
    file += orders + delays + patterns.map { $0.number }
    for pattern in patterns {
        for voice in 0 ..< 8 { file += voice < pattern.voices.count ? pattern.voices[voice] : empty(rows) }
    }
    return file
}

private func mono(_ renderer: any Renderer, seconds: Double) -> [Float] {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }
}

private func crossings(_ samples: ArraySlice<Float>) -> Int {
    zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
}

private func loudest(_ samples: ArraySlice<Float>) -> Float { samples.map(abs).max() ?? 0 }

/// A file played through with no chip: every register its player sets, and the tick it is set on.
/// The first of them, before any row, set the chip up; they are given apart.
private func registers(_ file: [UInt8]) throws -> (setUp: [(register: Int, value: UInt8)], played: [(tick: Int, register: Int, value: UInt8)], ticks: Int) {
    var tick = -1
    var setUp: [(register: Int, value: UInt8)] = [], played: [(tick: Int, register: Int, value: UInt8)] = []
    let tune = FMTTune(try FMTFile(file)) { register, value in
        if tick < 0 { setUp.append((register, value)) } else { played.append((tick, register, value)) }
    }
    tick = 0
    while tune.tick() != nil { tick += 1 }
    return (setUp, played, tick)
}

/// A second of the PC's timer left alone is this many ticks.
private let ticksASecond = 1_193_181.8181 / 65536

@Test func fmtLoadsAndSaysWhatItIs() throws {
    let renderer = try TuneLoader.load(fmt(), format: .fmt)
    #expect(renderer.info.format == "FMT")
    #expect(renderer.info.title == "one note")
    #expect(renderer.info.detail == "The FM Tracker!")
    #expect(renderer.channelCount == 8)
    #expect(!renderer.endsByLooping)
    // Four rows of three ticks, and a second for the last note to die away.
    #expect(abs(renderer.knownLength! - (12 / ticksASecond + 1)) < 0.001)
    #expect(TuneFormat(fileExtension: "FMT") == .fmt)

    // The instruments go to the chip before anything is played: each voice's eleven numbers.
    let setUp = try registers(fmt()).setUp
    #expect(setUp.count == 1 + 8 * 11)
    #expect(setUp[0] == (0x01, 0x20))
    // The eighth voice's two operators are the chip's seventeenth and twentieth.
    #expect(setUp.contains { $0 == (0x20 + 0x11, 0x21) } && setUp.contains { $0 == (0x40 + 0x11, 0x3F) })
    #expect(setUp.contains { $0 == (0x40 + 0x14, 0x00) } && setUp.contains { $0 == (0x60 + 0x14, 0xF0) })
    #expect(setUp.contains { $0 == (0x80 + 0x14, 0x0F) } && setUp.contains { $0 == (0xC7, 0x00) })
}

@Test func fmtNoteIsGivenToTheChipAsOpenMPTGivesIt() throws {
    // The file's 49 is OpenMPT's C-5, which with middle C at 8,215 is 257.1 Hz: number 678 in the
    // chip's fourth octave.
    // (The third thing its player sets is the key let up, when the song is over.)
    let played = try registers(fmt()).played
    #expect(played.count == 3)
    #expect(played[0] == (0, 0xA0, 0xA6) && played[1] == (0, 0xB0, 0x2E) && played[2] == (12, 0xB0, 0x0E))
    // On the fifth voice it is that voice's registers.
    let fifth = try registers(fmt(patterns: [(0, [empty(4), empty(4), empty(4), empty(4), [0x80, 37, 0x81]])])).played
    #expect(fifth.count == 3)
    #expect(fifth[0] == (3, 0xA4, 0xA6) && fifth[1] == (3, 0xB4, 0x2A) && fifth[2] == (12, 0xB4, 0x0A))

    // The lowest note and the highest, and where OpenMPT goes from one of the chip's octaves to the next.
    #expect(FMTTune.pitch(of: 2) == 359)
    #expect(FMTTune.pitch(of: 20) == 1018 && FMTTune.pitch(of: 21) == 1 << 10 | 539)
    #expect(FMTTune.pitch(of: 61) == 4 << 10 | 678)
    #expect(FMTTune.pitch(of: 97) == 7 << 10 | 683)
    // Every note is the one it should be with the scale tuned as OpenMPT has it, to within what
    // OpenMPT's whole numbers lose: a twentieth of a semitone, and at the very top a sixth.
    for note in UInt8(2) ... 97 {
        let pitch = FMTTune.pitch(of: note)
        let sounds = Double(pitch & 0x3FF) * OPL3Chip.rate / Double(1 << (20 - Int(pitch >> 10)))
        let meant = 261.625 * 8215 / 8363 * pow(2, (Double(note) - 49) / 12)
        let cents = 1200 * log(sounds / meant) / log(2)
        #expect(abs(cents) < (note < 49 ? 5 : note < 73 ? 7.5 : note < 85 ? 10.5 : 17), "note \(note) is \(cents) cents out")
    }

    // And it is what is heard.
    let renderer = try TuneLoader.load(fmt(rows: 40), format: .fmt)
    let sound = mono(renderer, seconds: 1)
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 257) <= 2)
    #expect(loudest(sound[4800...]) > 0.05)

    // The light for its voice shows it, and that it was struck; the others show nothing.
    #expect(renderer.channelCount == 8)
    var pitches = [Float](repeating: -1, count: 8), struck = [Bool](repeating: false, count: 8), levels = [Float](repeating: -1, count: 8)
    pitches.withUnsafeMutableBufferPointer { p in struck.withUnsafeMutableBufferPointer { s in renderer.takeChannelNotes(pitches: p.baseAddress!, struck: s.baseAddress!) } }
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    #expect(abs(pitches[0] - ChannelPitch.note(ofHz: 257.1)) < 0.02 && struck[0] && levels[0] > 0.2)
    #expect(pitches[1...].allSatisfy { $0 == 0 } && !struck[1...].contains(true) && levels[1...].allSatisfy { $0 == 0 })
    pitches.withUnsafeMutableBufferPointer { p in struck.withUnsafeMutableBufferPointer { s in renderer.takeChannelNotes(pitches: p.baseAddress!, struck: s.baseAddress!) } }
    #expect(!struck[0])
}

@Test func fmtRowLastsForTheDelayOfThePatternTheNextRowIsIn() throws {
    // Two patterns of three rows with a note on every row, the first at two ticks to the row and
    // the second at five. The last row of each is played at the other's speed.
    let notes: [UInt8] = [40, 41, 42]
    let file = fmt(rows: 3, orders: [0, 1], delays: [2, 5], patterns: [(0, [notes]), (1, [notes])])
    let (_, played, ticks) = try registers(file)
    #expect(played.filter { $0.register == 0xA0 }.map { $0.tick } == [0, 2, 4, 9, 14, 19])
    #expect(ticks == 21)
    let renderer = try TuneLoader.load(file, format: .fmt)
    #expect(abs(renderer.knownLength! - (21 / ticksASecond + 1)) < 0.001)

    // The ticks are the PC's timer's, 18.2 a second and a little more, to the sample.
    let tune = FMTTune(try FMTFile(file)) { _, _ in }
    var samples = 0
    while let more = tune.tick() { samples += more }
    #expect(samples == 21 * 65536 / 24)

    // A pattern played twice running keeps its own speed throughout, and one of a single row is
    // played at the speed of whatever follows it.
    let twice = try registers(fmt(rows: 3, orders: [0, 0, 1], delays: [2, 2, 5], patterns: [(0, [notes]), (1, [notes])]))
    #expect(twice.played.filter { $0.register == 0xA0 }.map { $0.tick } == [0, 2, 4, 6, 8, 10, 15, 20, 25])
    #expect(twice.ticks == 27)
    let single = try registers(fmt(rows: 1, orders: [0, 1, 0], delays: [1, 4, 8], patterns: [(0, [[40]]), (1, [[41]])]))
    #expect(single.played.filter { $0.register == 0xA0 }.map { $0.tick } == [0, 4, 12])
    #expect(single.ticks == 13)
}

@Test func fmtNoteIsStoppedWithAPitchOfNothing() throws {
    // A note, a row of nothing, its end, and another note straight after one that still sounds.
    let file = fmt(rows: 6, delays: [4], patterns: [(0, [[49, 0, 1, 50, 51, 0]])])
    let (_, played, ticks) = try registers(file)
    #expect(ticks == 24)
    let expected: [(Int, Int, UInt8)] = [
        (0, 0xA0, 0xA6), (0, 0xB0, 0x2E),
        // Stopped: no pitch, and the key up.
        (8, 0xA0, 0x00), (8, 0xB0, 0x00),
        // Nothing sounds, so the next is simply struck.
        (12, 0xA0, 0xCE), (12, 0xB0, 0x2E),
        // And the one after lets that one's key up first, at the pitch it had.
        (16, 0xB0, 0x0E), (16, 0xA0, 0xF9), (16, 0xB0, 0x2E),
        // At the end of the song the key is let up.
        (24, 0xB0, 0x0E),
    ]
    #expect(played.count == expected.count)
    for (was, should) in zip(played, expected) { #expect(was == should) }

    // What is heard: the note, then nothing, then the others.
    let renderer = try TuneLoader.load(file, format: .fmt)
    let tick = Double(outputSampleRate) / ticksASecond
    let sound = mono(renderer, seconds: 3)
    #expect(loudest(sound[Int(2 * tick) ..< Int(7 * tick)]) > 0.05)
    #expect(loudest(sound[Int(9 * tick) ..< Int(11.5 * tick)]) < 0.002)
    #expect(loudest(sound[Int(13 * tick) ..< Int(23 * tick)]) > 0.05)
    // The song over, its last note dies away within the second it is given.
    #expect(loudest(sound[Int(24 * tick) + 24000 ..< Int(24 * tick) + 48000]) < 0.001)
    #expect(renderer.hasEnded)
    // And it can be played again.
    renderer.select(subsong: 0)
    #expect(!renderer.hasEnded)
    #expect(mono(renderer, seconds: 1) == Array(sound[..<48000]))
}

@Test func fmtPatternsAreUnpackedAVoiceAtATime() throws {
    // Eight rows. The first voice: a note, three rows passed over in one byte, a note's end, one
    // row passed over, a byte that means nothing, a note. The second: all its rows in one byte.
    // The third: two notes and then more rows passed over than there are, which stops at the
    // pattern's end and leaves the fourth voice to start at its own first row.
    let voices: [[UInt8]] = [[97, 0x82, 1, 0x80, 120, 2], [0x87], [10, 11, 0xFF], [0x86, 12]]
    let file = try FMTFile(fmt(rows: 8, orders: [5, 9], delays: [1, 1], patterns: [(5, voices)]))
    #expect(file.rows == 8 && file.orders == [5, 9] && file.delays == [1, 1])
    #expect(file.title == "one note" && file.tracker == "The FM Tracker!")
    #expect(file.instruments.count == 8 && file.instruments[3] == [0x21, 0x21, 0x3F, 0x00, 0xF0, 0xF0, 0x0F, 0x0F, 0x00, 0x00, 0x00])
    func voice(_ voice: Int, order: Int = 0) -> [UInt8] { (0 ..< 8).map { file.cell(order: order, row: $0, voice: voice) } }
    #expect(voice(0) == [97, 0, 0, 0, 1, 0, 0, 2])
    #expect(voice(1) == [0, 0, 0, 0, 0, 0, 0, 0])
    #expect(voice(2) == [10, 11, 0, 0, 0, 0, 0, 0])
    #expect(voice(3) == [0, 0, 0, 0, 0, 0, 0, 12])
    #expect(voice(7) == [0, 0, 0, 0, 0, 0, 0, 0])
    // A place in the song that asks for a pattern the file has not got is an empty one.
    for at in 0 ..< 8 { #expect(voice(at, order: 1) == [0, 0, 0, 0, 0, 0, 0, 0]) }

    // Patterns are known by the numbers the file gives them, in whatever order they come.
    let two = try FMTFile(fmt(rows: 2, orders: [3, 200], delays: [1, 1], patterns: [(200, [[20, 21]]), (3, [[30, 31]])]))
    #expect(two.cell(order: 0, row: 1, voice: 0) == 31 && two.cell(order: 1, row: 0, voice: 0) == 20)
}

@Test func fmtThatIsNotOneOrIsCutShortIsRefusedOrPlayedAsFarAsItGoes() throws {
    let whole = fmt(rows: 8, patterns: [(0, [[49, 50, 51, 52, 53, 54, 55, 56], [61, 62, 63, 64, 65, 66, 67, 68]])])
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x41, count: 400), format: .fmt) }
    // Another version of the format, if there ever was one, is not this one.
    var other = whole
    other[10] = 2
    #expect(throws: TuneError.self) { try TuneLoader.load(other, format: .fmt) }
    // Cut off in its header, or before its patterns begin.
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(whole.prefix(100)), format: .fmt) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(whole.prefix(218)), format: .fmt) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(whole.prefix(221)), format: .fmt) }
    // A delay is from one to eight.
    for delay: UInt8 in [0, 9, 255] {
        #expect(throws: TuneError.self) { try TuneLoader.load(fmt(delays: [delay]), format: .fmt) }
    }

    // Cut off part way through its second voice, the first is all there and the rest is empty.
    let cut = try FMTFile(Array(whole.prefix(whole.count - 10)))
    #expect((0 ..< 8).map { cut.cell(order: 0, row: $0, voice: 0) } == [49, 50, 51, 52, 53, 54, 55, 56])
    #expect((0 ..< 8).map { cut.cell(order: 0, row: $0, voice: 1) } == [61, 62, 63, 64, 0, 0, 0, 0])
    #expect((0 ..< 8).map { cut.cell(order: 0, row: $0, voice: 7) } == [0, 0, 0, 0, 0, 0, 0, 0])
    let renderer = try TuneLoader.load(Array(whole.prefix(whole.count - 10)), format: .fmt)
    #expect(renderer.knownLength != nil)
    #expect(loudest(mono(renderer, seconds: 1)[4800...]) > 0.05)

    // The most a file can ask for: 256 places in the song, each of 256 rows at eight ticks to the
    // row, and as many patterns, here with nothing in them. It is eight hours of nothing, which is
    // taken to have no end, as any tune for the chip is that has not ended in an hour.
    var most = Array(fmt().prefix(215)) + [255, 255, 255]
    most += [UInt8](repeating: 0, count: 256) + [UInt8](repeating: 8, count: 256) + (0 ... 255).map { UInt8($0) }
    most += [UInt8](repeating: 0xFF, count: 256 * 8)
    let long = try TuneLoader.load(most, format: .fmt)
    #expect(long.knownLength == nil)
    #expect(loudest(mono(long, seconds: 0.5)[...]) == 0)
}
