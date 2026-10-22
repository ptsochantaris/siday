// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayTrackers
import Testing

// Fast checks of the player of STM files. The thorough check is made outside the package, against
// st2play, which this is a port of: every sample of each file to hand, for half an hour of it.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func padded(_ text: String, to length: Int) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: max(0, length - text.utf8.count)) }

/// What a channel has on a row: a note (its octave in the high half, the note of twelve in the
/// low; 255 for none and 254 to cut the one that is playing), a sample, a volume (65 for none),
/// and a command by its letter.
private struct Cell {
    var note: UInt8 = 0xFF, sample: UInt8 = 0, volume: UInt8 = 65, command: UInt8 = 0, value: UInt8 = 0

    static func note(_ note: UInt8 = 0x20, sample: UInt8 = 1, volume: UInt8 = 65, _ command: Character? = nil, _ value: UInt8 = 0) -> Cell {
        Cell(note: note, sample: sample, volume: volume, command: command.map { $0.asciiValue! - 64 } ?? 0, value: value)
    }

    static func command(_ command: Character, _ value: UInt8, volume: UInt8 = 65) -> Cell {
        Cell(volume: volume, command: command.asciiValue! - 64, value: value)
    }

    var bytes: [UInt8] { [note, sample << 3 | volume & 7, (volume & 0x78) << 1 | command, value] }
}

/// A sample: by default a square wave of 32 samples that goes round, so that the C of the second
/// octave, which Scream Tracker 2.3 plays at 8,287 samples a second, is 259 Hz.
private struct Sound {
    var frames: [Int8] = (0 ..< 32).map { $0 < 16 ? 100 : -100 }
    /// Where it goes round from and to; to nought for a sample that does not.
    var loop: (Int, Int)? = (0, 32)
    var volume: UInt8 = 64
    var rate = 8192
}

/// An STM file of one or more patterns, at six ticks to the row unless it says otherwise.
private func stm(_ patterns: [[(row: Int, channel: Int, cell: Cell)]], orders: [UInt8] = [0], tempo: UInt8 = 0x60, sounds: [Sound] = [Sound()],
                 type: UInt8 = 2, version: (UInt8, UInt8) = (2, 21), tracker: String = "!Scream!", volume: UInt8 = 64) -> [UInt8] {
    var packed: [UInt8] = []
    for pattern in patterns {
        var cells = [[UInt8]](repeating: [0xFC], count: 256)
        for (row, channel, cell) in pattern { cells[row * 4 + channel] = cell.bytes }
        packed += cells.flatMap { $0 }
    }
    var file = padded("a square wave", to: 20) + Array(tracker.utf8) + [0x1A, type, version.0, version.1, tempo, UInt8(patterns.count), volume]
    file += [UInt8](repeating: 0, count: 13)
    var place = (48 + 31 * 32 + 128 + packed.count + 15) / 16
    var sound: [UInt8] = []
    for number in 0 ..< 31 {
        guard number < sounds.count else {
            file += [UInt8](repeating: 0, count: 32)
            continue
        }
        let one = sounds[number]
        file += padded("square.smp", to: 12) + [0, 0] + word(place) + word(one.frames.count) + word(one.loop?.0 ?? 0) + word(one.loop?.1 ?? 0)
        file += [one.volume, 0] + word(one.rate) + [0, 0, 0, 0, 0, 0]
        let bytes = one.frames.map { UInt8(bitPattern: $0) }
        sound += bytes + [UInt8](repeating: 0, count: (16 - bytes.count % 16) % 16)
        place += (bytes.count + 15) / 16
    }
    file += orders + [UInt8](repeating: 99, count: 128 - orders.count)
    file += packed
    file += [UInt8](repeating: 0, count: (16 - file.count % 16) % 16)
    return file + sound
}

/// What Scream Tracker itself made of a file: so many seconds of its one channel, at its own
/// 23,863 samples a second, about nought.
private func made(_ file: [UInt8], seconds: Double = 1) throws -> [Float] {
    let renderer = try #require(try TuneLoader.load(file, format: .stm) as? STMRenderer)
    return renderer.renderRaw(frames: Int(seconds * Double(ST2Player.mixRate))).map { Float($0 - 128) / 128 }
}

private func heard(_ file: [UInt8], seconds: Double = 1) throws -> (left: [Float], right: [Float]) {
    let renderer = try TuneLoader.load(file, format: .stm)
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

/// How many times a second a sound goes up through nought, over a stretch of it given in seconds.
private func pitch(_ samples: [Float], _ from: Double, _ to: Double, rate: Int = ST2Player.mixRate) -> Double {
    let part = samples[Int(from * Double(rate)) ..< Int(to * Double(rate))]
    return Double(zip(part, part.dropFirst()).count { $0 < 0 && $1 >= 0 }) / (to - from)
}

private func loudness(_ samples: [Float], _ from: Double, _ to: Double, rate: Int = ST2Player.mixRate) -> Float {
    let part = samples[Int(from * Double(rate)) ..< Int(to * Double(rate))]
    return (part.reduce(0) { $0 + $1 * $1 } / Float(part.count)).squareRoot()
}

/// How long a row lasts at six ticks to it and no factor, in seconds: a tick is a fiftieth of a
/// second, to the sample below.
private let row = 6.0 * 477 / 23863

@Test func stmNoteSoundsAtItsPitch() throws {
    #expect(TuneFormat(fileExtension: "STM") == .stm)
    let renderer = try TuneLoader.load(stm([[(0, 0, .note())]]), format: .stm)
    #expect(renderer.info.format == "STM" && renderer.info.title == "a square wave" && renderer.info.shortfalls.isEmpty)
    #expect(renderer.channelCount == 4)
    let sound = try made(stm([[(0, 0, .note())]]))
    #expect(abs(pitch(sound, 0.1, 1) - 259) <= 2)
    // An octave up is twice that, and so is a sample that is to be played twice as fast.
    #expect(abs(pitch(try made(stm([[(0, 0, .note(0x30))]])), 0.1, 1) - 518) <= 3)
    #expect(abs(pitch(try made(stm([[(0, 0, .note())]], sounds: [Sound(rate: 16384)])), 0.1, 1) - 518) <= 3)
    // What is heard is that, the same on both sides.
    let both = try heard(stm([[(0, 0, .note())]]))
    #expect(abs(pitch(both.left, 0.1, 1, rate: outputSampleRate) - 259) <= 2)
    #expect(both.left == both.right && loudness(both.left, 0.1, 1, rate: outputSampleRate) > 0.05)
    // The tune's own volume, and a note's.
    let quiet = try made(stm([[(0, 0, .note())]], volume: 32)), quieter = try made(stm([[(0, 0, .note(volume: 16))]]))
    #expect(abs(loudness(quiet, 0.1, 1) * 2 - loudness(sound, 0.1, 1)) < 0.02 && abs(loudness(quieter, 0.1, 1) * 4 - loudness(sound, 0.1, 1)) < 0.03)
}

@Test func stmTempoIsTicksToTheRowAndAFactor() throws {
    func length(_ file: [UInt8]) throws -> Double { try #require(try TuneLoader.load(file, format: .stm).knownLength) }
    // 64 rows of six ticks, each a fiftieth of a second; and a tick of nothing before the first.
    #expect(abs(try length(stm([[(0, 0, .note())]])) - 64 * row) < 0.03)
    #expect(abs(try length(stm([[(0, 0, .note())]], tempo: 0x30)) - 32 * row) < 0.03)
    #expect(abs(try length(stm([[(0, 0, .note(0x20, sample: 1, volume: 65, "A", 0x30))]])) - 32 * row) < 0.03)
    // The low half of a tempo makes every tick longer: at six ticks to the row, by eight, a
    // forty-seventh of a second.
    #expect(abs(try length(stm([[(0, 0, .note())]], tempo: 0x68)) - 64 * 6 * 507.0 / 23863) < 0.03)
    // A file of before 2.21 has its tempo as it was typed, in tens and units.
    #expect(abs(try length(stm([[(0, 0, .note())]], tempo: 30, version: (2, 20))) - 32 * row) < 0.03)
}

@Test func stmListIsPlayedToItsEnd() throws {
    func length(_ file: [UInt8]) throws -> Double { try #require(try TuneLoader.load(file, format: .stm).knownLength) }
    let two: [[(row: Int, channel: Int, cell: Cell)]] = [[(0, 0, .note())], [(0, 1, .note(0x30))]]
    #expect(abs(try length(stm(two, orders: [0, 1])) - 128 * row) < 0.03)
    // C ends a pattern after its row.
    #expect(abs(try length(stm([[(0, 0, .note()), (3, 0, .command("C", 0))], two[1]], orders: [0, 1])) - 68 * row) < 0.03)
    // B says which place in the list is next, and does not end the pattern: here the second
    // pattern is passed over.
    #expect(abs(try length(stm([[(0, 0, .note()), (3, 0, .command("B", 2))], two[1], two[1]], orders: [0, 1, 2])) - 128 * row) < 0.03)
    // A pattern the file has none of is one with nothing in it: the note before it sounds on.
    let rings = stm([[(0, 0, .note())]], orders: [0, 7])
    #expect(abs(try length(rings) - 128 * row) < 0.03)
    #expect(loudness(try made(rings, seconds: 10), 9, 10) > 0.1)
    // A number in the list that is no pattern's is the list's end, and nothing after it is played.
    let file = try TuneLoader.load(stm(two, orders: [0, 255, 1, 1]), format: .stm)
    let itsLength = try #require(file.knownLength)
    #expect(file.subsongCount == 1 && abs(itsLength - 64 * row) < 0.03)
}

@Test func stmCommandsCountInTens() throws {
    // A slide of pitch by two is by twenty of the period, every tick but the first of the row.
    let up = try made(stm([[(0, 0, .note(0x20, sample: 1, volume: 65, "F", 0x02))] + (1 ..< 16).map { ($0, 0, .command("F", 0x02)) }]), seconds: 1.5)
    #expect(pitch(up, 1.2, 1.5) > pitch(up, 0.05, 0.3) * 1.3)
    let down = try made(stm([[(0, 0, .note(0x30, sample: 1, volume: 65, "E", 0x02))] + (1 ..< 16).map { ($0, 0, .command("E", 0x02)) }]), seconds: 1.5)
    #expect(pitch(down, 1.2, 1.5) < pitch(down, 0.05, 0.3) * 0.8)
    // A slide to a note stops there, and with no value of its own goes on at the last.
    let slide = try made(stm([[(0, 0, .note()), (1, 0, .note(0x30, sample: 0, volume: 65, "G", 0x10))] + (2 ..< 8).map { ($0, 0, .command("G", 0)) }]), seconds: 2)
    #expect(abs(pitch(slide, 1.2, 2) - 518) <= 3)
    // (And a slide that is let go before it is there is there at once: Scream Tracker's own way.)
    let letGo = try made(stm([[(0, 0, .note()), (1, 0, .note(0x30, sample: 0, volume: 65, "G", 0x01))]]), seconds: 2)
    #expect(pitch(letGo, 0.13, 0.22) < 290 && abs(pitch(letGo, 1.2, 2) - 518) <= 3)
    // A slide of volume: down if it has anything in its low half.
    let fades = try made(stm([[(0, 0, .note(0x20, sample: 1, volume: 65, "D", 0x04))] + (1 ..< 4).map { ($0, 0, .command("D", 0x04)) }]), seconds: 1)
    #expect(loudness(fades, 0.6, 1) < 0.001 && loudness(fades, 0.03, 0.1) > 0.1)
    let swells = try made(stm([[(0, 0, .note(0x20, sample: 1, volume: 4, "D", 0x40))] + (1 ..< 4).map { ($0, 0, .command("D", 0x40)) }]), seconds: 1)
    #expect(loudness(swells, 0.6, 1) > loudness(swells, 0.03, 0.1) * 4)
    // A vibrato moves the pitch about the note and leaves it there, and an arpeggio plays three notes.
    let wavers = try made(stm([[(0, 0, .note(0x20, sample: 1, volume: 65, "H", 0x4F))] + (1 ..< 8).map { ($0, 0, .command("H", 0)) }]), seconds: 1.5)
    let plain = try made(stm([[(0, 0, .note())]]), seconds: 1.5)
    #expect(wavers[..<20000] != plain[..<20000] && abs(pitch(wavers, 1.1, 1.5) - 259) <= 3)
    let chord = try made(stm([(0 ..< 16).map { ($0, 0, $0 == 0 ? .note(0x20, sample: 1, volume: 65, "J", 0x47) : .command("J", 0x47)) }]), seconds: 1.5)
    #expect(pitch(chord, 0.1, 1.5) > 290 && pitch(chord, 0.1, 1.5) < 370)
    // Tremor turns the note off and on.
    let tremor = try made(stm([(0 ..< 16).map { ($0, 0, $0 == 0 ? .note(0x20, sample: 1, volume: 65, "I", 0x22) : .command("I", 0x22)) }]), seconds: 1.5)
    #expect(loudness(tremor, 0.1, 1.5) < loudness(plain, 0.1, 1.5) * 0.85 && loudness(tremor, 0.1, 1.5) > loudness(plain, 0.1, 1.5) * 0.4)
}

@Test func stmNoteIsCutAndAVolumeTooGreatIsSilence() throws {
    let cut = try made(stm([[(0, 0, .note()), (4, 0, Cell(note: 0xFE))]]), seconds: 1)
    #expect(loudness(cut, 0.05, 0.4) > 0.1 && loudness(cut, 0.6, 1) == 0)
    // Scream Tracker mixed no channel whose volume was over 64, and a row can say 66.
    #expect(loudness(try made(stm([[(0, 0, .note(volume: 66))]])), 0.1, 1) == 0)
    // A sample with no volume of its own is not loaded, and its notes are silence.
    #expect(loudness(try made(stm([[(0, 0, .note(volume: 40))]], sounds: [Sound(volume: 0)])), 0.1, 1) == 0)
    // A sample that does not go round ends.
    let once = try made(stm([[(0, 0, .note())]], sounds: [Sound(frames: [Int8](repeating: 90, count: 4000), loop: nil)]))
    #expect(loudness(once, 0.05, 0.3) > 0.1 && loudness(once, 0.7, 1) == 0)
}

@Test func stmSampleThatGoesRoundPastItsEndGoesOnIntoTheNext() throws {
    // Scream Tracker did not look: a sample said to go round from past its end played on into
    // whatever came next, which is the next sample. st2play brings the end in.
    let file = stm([[(0, 0, .note())]], sounds: [Sound(loop: (0, 48)), Sound(frames: [Int8](repeating: 100, count: 32))])
    let asItIs = try ST2Module(file), broughtIn = try ST2Module(file, asST2Play: true)
    #expect(asItIs.samples[1].loopEnd == 48 && broughtIn.samples[1].loopEnd == 32)
    #expect(abs(pitch(try made(file), 0.1, 1) - 259) <= 2)
    #expect(abs(pitch(try heard(file).left, 0.1, 1, rate: outputSampleRate) - 259.0 * 32 / 48) <= 3)
}

@Test func stmLightsFollowTheChannels() throws {
    let renderer = try TuneLoader.load(stm([[(0, 1, .note())]]), format: .stm)
    var buffer = [Float](repeating: 0, count: 9600 * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 9600) }
    var levels = [Float](repeating: 0, count: 4), pitches = [Float](repeating: 0, count: 4), sides = [Float](repeating: 1, count: 4)
    var struck = [Bool](repeating: false, count: 4)
    renderer.takeChannelLevels(into: &levels)
    renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
    renderer.takeChannelSides(into: &sides)
    #expect(levels[1] > 0.5 && levels[0] == 0 && struck == [false, true, false, false] && sides == [0, 0, 0, 0])
    #expect(abs(pitches[1] - ChannelPitch.note(ofRate: 8287)) < 0.05 && pitches[0] == 0)
}

@Test func stmChannelLeftOutIsNotHeardAndPlaysOn() throws {
    /// Half a second of what is heard, which is the same on both sides, and how loud each channel was said to be.
    func played(_ renderer: any Renderer) -> (sound: [Float], levels: [Float]) {
        var buffer = [Float](repeating: 0, count: 24000 * 2), levels = [Float](repeating: 0, count: 4)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 24000) }
        renderer.takeChannelLevels(into: &levels)
        return (stride(from: 0, to: buffer.count, by: 2).map { buffer[$0] }, levels)
    }
    // A note on the first channel and the octave above on the second; and the first alone.
    let both = stm([[(0, 0, .note()), (0, 1, .note(0x30))]])
    let whole = played(try TuneLoader.load(both, format: .stm))
    let alone = played(try TuneLoader.load(stm([[(0, 0, .note())]]), format: .stm))
    #expect(whole.levels[0] > 0.5 && whole.levels[1] > 0.5 && whole.sound != alone.sound)

    // The second left out: the tune without its note, to the sample (the four channels are added
    // in whole numbers), and the channel is said to be as loud as it was.
    let renderer = try #require(try TuneLoader.load(both, format: .stm) as? STMRenderer)
    renderer.setMuted([false, true])
    let without = played(renderer)
    #expect(without.sound == alone.sound && without.levels == whole.levels)

    // A song started again is started without the channel, and Scream Tracker's own samples are
    // made without it; with it brought back, the sound is as it ever was.
    renderer.select(subsong: 0)
    #expect(played(renderer).sound == without.sound)
    #expect(renderer.renderRaw(frames: 12000) == (try #require(try TuneLoader.load(stm([[(0, 0, .note())]]), format: .stm) as? STMRenderer)).renderRaw(frames: 12000))
    renderer.setMuted([])
    renderer.select(subsong: 0)
    #expect(played(renderer).sound == whole.sound)

    // Every channel left out is silence.
    renderer.setMuted([true, true, true, true])
    renderer.select(subsong: 0)
    let none = played(renderer)
    #expect(none.sound.allSatisfy { $0 == 0 } && none.levels == whole.levels)
}

@Test func stmFileThatIsCutOrDamagedIsReadOrRefused() throws {
    let whole = stm([[(0, 0, .note(0x20, sample: 1, volume: 40, "H", 0x47)), (1, 1, .note(0x3B, sample: 2, volume: 65, "J", 0x37)), (2, 0, .command("A", 0x1F))], [(0, 2, .note())]],
                    orders: [0, 1, 9, 98], sounds: [Sound(), Sound(frames: [Int8](repeating: 60, count: 300), loop: (200, 9000))])
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .stm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("a square wave       !Scream! and no more".utf8), format: .stm) }
    // A song is a tune without its samples; and these are other things than Scream Tracker 2's.
    #expect(throws: TuneError.self) { try TuneLoader.load(stm([[(0, 0, .note())]], type: 1), format: .stm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(stm([[(0, 0, .note())]], version: (3, 0)), format: .stm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(stm([[(0, 0, .note())]], tracker: "\u{1}Scream!"), format: .stm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(stm([[(0, 0, .note())]], orders: [0, 70]), format: .stm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(stm([[(0, 0, .note())]], volume: 70), format: .stm) }
    func play(_ file: [UInt8]) {
        guard let renderer = try? TuneLoader.load(file, format: .stm) else { return }
        var buffer = [Float](repeating: 0, count: 4800 * 2)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        #expect(buffer.allSatisfy { $0.isFinite && abs($0) < 2 })
    }
    for length in stride(from: 0, to: whole.count, by: 23) { play(Array(whole[..<length])) }
    // And with anything at all for its patterns and its samples' headers.
    var seed: UInt32 = 2221
    func random() -> UInt8 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: seed >> 16)
    }
    for _ in 0 ..< 150 {
        var file = whole
        for number in 0 ..< 31 {
            for i in 13 ..< 32 where random() < 80 { file[48 + number * 32 + i] = random() }
        }
        file[32] = random()
        for i in 48 + 31 * 32 + 128 ..< file.count where random() < 60 { file[i] = random() }
        play(file)
    }
}

@Test func stmThatComesRoundByAJumpIsFadedAndEnds() throws {
    // A note that goes on sounding, and at the start of the second pattern a jump back to the first:
    // the tune comes round by the jump, not by the end of its list. As it is played, that is the
    // tune coming round, as it is when its length is found, and it fades and ends.
    let file = stm([[(0, 0, .note())], [(0, 0, .command("B", 0))]], orders: [0, 1])
    let renderer = try TuneLoader.load(file, format: .stm)
    let length = try #require(renderer.knownLength)
    let session = TuneSession(renderer: renderer, policy: PlaybackPolicy())
    var block = [Float](repeating: 0, count: 1024)
    while !session.finished, session.elapsed < 120 { _ = block.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: 512) } }
    #expect(session.finished)
    #expect(session.elapsed < length * 2 + 1)
}

/// A tune played through a session that keeps its voices' scopes, with `muted` voices left out:
/// each voice's scope after a quarter of a second, and again after the song is started afresh; and
/// whether what was heard was the same, to the bit, as from a session that keeps none.
private func scopes(_ file: [UInt8], format: TuneFormat, muted: [Bool] = []) throws
    -> (now: [ArraySlice<UInt8>], again: [ArraySlice<UInt8>], same: Bool)
{
    func session() throws -> TuneSession {
        let renderer = try TuneLoader.load(file, format: format, options: LoadOptions())
        renderer.setMuted(muted)
        return TuneSession(renderer: renderer, policy: PlaybackPolicy())
    }
    let kept = try session(), plain = try session()
    #expect(kept.keepChannelWaves())
    var same = true
    func play() -> [ArraySlice<UInt8>] {
        var with = [Float](repeating: 0, count: 1000 * 2), without = with
        for _ in 0 ..< 12 {
            _ = with.withUnsafeMutableBufferPointer { kept.render(into: $0.baseAddress!, frames: 1000) }
            _ = without.withUnsafeMutableBufferPointer { plain.render(into: $0.baseAddress!, frames: 1000) }
            if with != without { same = false }
        }
        let voices = kept.renderer.channelCount
        var scopes = [UInt8](repeating: 0, count: voices * ChannelWaves.points)
        scopes.withUnsafeMutableBufferPointer { kept.takeChannelWaves(into: $0.baseAddress!, behind: 0) }
        return (0 ..< voices).map { scopes[$0 * ChannelWaves.points ..< ($0 + 1) * ChannelWaves.points] }
    }
    let now = play()
    kept.renderer.select(subsong: 0)
    plain.renderer.select(subsong: 0)
    return (now, play(), same)
}

/// A scope's distance from the middle at its highest.
private func height(_ scope: ArraySlice<UInt8>) -> Int { scope.map { abs(Int($0) - 128) }.max() ?? 0 }

@Test func stmChannelsHaveScopes() throws {
    // A note at full volume on the first channel and one at a quarter of it on the second, of a
    // square wave as loud as a sample can be; the others silent.
    let loud = Sound(frames: (0 ..< 32).map { $0 < 16 ? 127 : -128 })
    let file = stm([[(0, 0, .note()), (0, 1, .note(0x30, volume: 16))]], sounds: [loud])
    let heard = try scopes(file, format: .stm)
    #expect(heard.same)
    for scopes in [heard.now, heard.again] {
        #expect(height(scopes[0]) > 115)
        // (A quarter of the swing is half the height.)
        #expect(height(scopes[1]) > 50 && height(scopes[1]) < 80)
        #expect(scopes[2...].allSatisfy { $0.allSatisfy { $0 == 128 } })
    }
    // A channel left out is still seen to play.
    let without = try scopes(file, format: .stm, muted: [true])
    #expect(without.same && height(without.now[0]) > 115 && height(without.again[0]) > 115)
    // And what Scream Tracker made is made as it was.
    let kept = try #require(try TuneLoader.load(file, format: .stm) as? STMRenderer)
    #expect(kept.keepChannelWaves() != nil)
    #expect(kept.renderRaw(frames: 12000) == (try #require(try TuneLoader.load(file, format: .stm) as? STMRenderer)).renderRaw(frames: 12000))
}

/// A tune played a little at a time: for each of so many calls for sound, whether anything was
/// heard in it, and whether the first voice's light was lit for it.
private func heardAndLit(_ file: [UInt8], format: TuneFormat, calls: Int = 60, frames: Int = 200) throws -> [(heard: Bool, lit: Bool)] {
    let renderer = try TuneLoader.load(file, format: format, options: LoadOptions())
    var buffer = [Float](repeating: 0, count: frames * 2), levels = [Float](repeating: 0, count: renderer.channelCount)
    return (0 ..< calls).map { _ in
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
        levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
        let swing = (buffer.max() ?? 0) - (buffer.min() ?? 0)
        return (swing > 0.002, ChannelLight.brightness(of: levels[0]) > 0)
    }
}

@Test func stmLightIsOfWhatIsHeard() throws {
    // A note, cut four rows on: the light is lit for what gives out its sound, from the first of
    // it, and for nothing after.
    let calls = try heardAndLit(stm([[(0, 0, .note()), (4, 0, Cell(note: 0xFE))]]), format: .stm, calls: 150)
    #expect(calls.contains { $0.heard } && calls.last.map { !$0.heard } == true)
    #expect(calls.allSatisfy { $0.heard == $0.lit })
    // A sample that holds one level is silent, and so is its light, once the step to it is past.
    let held = try heardAndLit(stm([[(0, 0, .note())]], sounds: [Sound(frames: [Int8](repeating: 100, count: 32))]), format: .stm, calls: 20)
    #expect(held.count { $0.lit } <= 1 && held.dropFirst(6).allSatisfy { !$0.lit })
}
