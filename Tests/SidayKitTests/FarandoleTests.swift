// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayFoundation
import Testing

// Fast checks of the player of FAR files. The thorough check is made outside the package, against
// libxmp: every channel's pitch, volume and place on every tick of each file to hand.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ text: String, to length: Int) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: max(0, length - text.utf8.count)) }

/// What a channel has on a row: a note (1 is the lowest C; 0 for none), a sample, a volume from 0
/// to 15 (nil for none), and a command with its value, each a hexadecimal digit.
private struct Cell {
    var note: UInt8 = 0, sample: UInt8 = 0, volume: UInt8?, command: UInt8 = 0

    static func note(_ note: UInt8 = 25, sample: UInt8 = 0, volume: UInt8? = 15, _ command: UInt8 = 0) -> Cell {
        Cell(note: note, sample: sample, volume: volume, command: command)
    }

    static func command(_ command: UInt8, volume: UInt8? = nil) -> Cell { Cell(volume: volume, command: command) }

    var bytes: [UInt8] { [note, sample, volume.map { $0 + 1 } ?? 0, command] }
}

/// A sample: by default a square wave of 32 samples that goes round, so that the C a FAR file
/// plays at 16,726 samples a second is 523 Hz.
private struct Sound {
    var frames: [Int16] = (0 ..< 32).map { $0 < 16 ? 100 : -100 }
    var loops = true
    var sixteen = false
}

/// A FAR file: by default one pattern of 64 rows, at the tempo of four.
private func far(_ patterns: [[(row: Int, channel: Int, cell: Cell)]], rows: [Int] = [], orders: [UInt8] = [0], restart: UInt8 = 0, tempo: UInt8 = 4,
                 pans: [UInt8] = [], sounds: [Sound] = [Sound()]) -> [UInt8] {
    var file: [UInt8] = [0x46, 0x41, 0x52, 0xFE] + padded("a square wave", to: 40) + [0x0D, 0x0A, 0x1A] + word(869) + [0x10]
    file += [UInt8](repeating: 1, count: 16) + [UInt8](repeating: 0, count: 9) + [tempo]
    file += (0 ..< 16).map { $0 < pans.count ? pans[$0] : 8 } + [0, 0, 0, 0] + word(0)
    file += orders + [UInt8](repeating: 0xFF, count: 256 - orders.count) + [UInt8(patterns.count), UInt8(orders.count), restart]
    var bodies: [[UInt8]] = []
    for (index, pattern) in patterns.enumerated() {
        let count = index < rows.count ? rows[index] : 64
        var body = [UInt8](repeating: 0, count: count * 64)
        for (row, channel, cell) in pattern { body.replaceSubrange((row * 16 + channel) * 4 ..< (row * 16 + channel) * 4 + 4, with: cell.bytes) }
        bodies.append([UInt8(count - 2), 0] + body)
    }
    file += (0 ..< 256).flatMap { word($0 < bodies.count ? bodies[$0].count : 0) }
    file += bodies.flatMap { $0 }
    file += (0 ..< 8).map { byte in (0 ..< 8).reduce(UInt8(0)) { $0 | (byte * 8 + $1 < sounds.count ? 1 << $1 : 0) } }
    for sound in sounds {
        let bytes: [UInt8] = sound.sixteen ? sound.frames.flatMap { word(Int(UInt16(bitPattern: $0 * 256))) } : sound.frames.map { UInt8(truncatingIfNeeded: $0) }
        file += padded("square", to: 32) + long(bytes.count) + [0, 15] + long(0) + long(bytes.count) + [sound.sixteen ? 1 : 0, sound.loops ? 8 : 0]
        file += bytes
    }
    return file
}

private func heard(_ file: [UInt8], seconds: Double = 1) throws -> (left: [Float], right: [Float]) {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try TuneLoader.load(file, format: .far, options: options)
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

/// How long a row lasts at the tempo of four, in seconds: four ticks of 37,414 counts of the PC's timer.
private let row = 4.0 * 37414 / 1_193_182

@Test func farNoteSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "FAR") == .far)
    let renderer = try TuneLoader.load(far([[(0, 0, .note())]]), format: .far)
    #expect(renderer.info.format == "FAR" && renderer.info.title == "a square wave" && renderer.info.shortfalls.isEmpty && renderer.channelCount == 16)
    let sound = try heard(far([[(0, 0, .note())]]))
    #expect(abs(pitch(sound.left, 0.1, 1) - 523) <= 3)
    #expect(abs(pitch(try heard(far([[(0, 0, .note(37))]])).left, 0.1, 1) - 1045) <= 5)
    // A sample of sixteen bits is the same sound.
    let wide = try heard(far([[(0, 0, .note())]], sounds: [Sound(sixteen: true)]))
    #expect(abs(pitch(wide.left, 0.1, 1) - 523) <= 3 && abs(loudness(wide.left, 0.1, 1) - loudness(sound.left, 0.1, 1)) < 0.002)
    // Each channel is where the file puts it, of sixteen places, and B moves it.
    let left = try heard(far([[(0, 0, .note())]], pans: [0, 15])), right = try heard(far([[(0, 1, .note())]], pans: [0, 15]))
    #expect(loudness(left.right, 0.1, 1) < 0.0005 && loudness(right.left, 0.1, 1) < 0.0005 && loudness(left.left, 0.1, 1) > 0.01)
    let moved = try heard(far([[(0, 0, .note(25, sample: 0, volume: 15, 0xBF))]], pans: [0, 15]))
    #expect(loudness(moved.left, 0.1, 1) < 0.0005 && loudness(moved.right, 0.1, 1) > 0.01)
    // A note with no volume beside it is silent, and so is one of a sample there is none of.
    #expect(loudness(try heard(far([[(0, 0, .note(volume: nil))]])).left, 0.1, 1) == 0)
    #expect(loudness(try heard(far([[(0, 0, .note(25, sample: 5))]])).left, 0.1, 1) == 0)
}

@Test func farTempoIsTicksASecond() throws {
    func length(_ file: [UInt8]) throws -> Double { try #require(try TuneLoader.load(file, format: .far).knownLength) }
    // The tempo of four is eight rows a second, all but a little; of two, twice as many.
    #expect(abs(try length(far([[(0, 0, .note())]])) - 64 * row) < 0.01)
    #expect(abs(try length(far([[(0, 0, .note())]], tempo: 2)) - 32 * row) < 0.01)
    #expect(abs(try length(far([[(0, 0, .note(25, sample: 0, volume: 15, 0xF2))]])) - 32 * row) < 0.01)
    // The fine tempo adds to the ticks a second, which at four are 32: with four more, 36.
    #expect(abs(try length(far([[(0, 0, .note(25, sample: 0, volume: 15, 0xE4))]])) - 64 * 4 * 33257.0 / 1_193_182) < 0.01)
    #expect(abs(try length(far([[(0, 0, .note(25, sample: 0, volume: 15, 0xE4)), (32, 0, .command(0xD4))]])) - (32 * 4 * 33257.0 / 1_193_182 + 32 * row)) < 0.01)
    // A tick too long for the PC's timer is halved, and the row given more of them.
    #expect(abs(try length(far([[(0, 0, .note())]], tempo: 15)) - 64 * 7 * 37414.0 / 1_193_182) < 0.01)
}

@Test func farPatternsAreAsLongAsTheySay() throws {
    func length(_ file: [UInt8]) throws -> Double { try #require(try TuneLoader.load(file, format: .far).knownLength) }
    let two: [[(row: Int, channel: Int, cell: Cell)]] = [[(0, 0, .note())], [(0, 1, .note(37))]]
    #expect(abs(try length(far(two, rows: [8, 100], orders: [0, 1])) - 108 * row) < 0.02)
    // A pattern the file has nothing of is 64 rows of nothing.
    #expect(abs(try length(far(two, rows: [8, 8], orders: [0, 9, 1])) - 80 * row) < 0.02)
    // A list with nothing in it is no tune, but is not refused.
    #expect(try TuneLoader.load(far(two, orders: []), format: .far).subsongCount == 1)
}

@Test func farSlidesGoOnByThemselves() throws {
    // A slide to the C above, over four rows: it is asked for once, and stops when it is there.
    let slide = try heard(far([[(0, 0, .note()), (1, 0, .note(37, sample: 0, volume: 15, 0x34))]]), seconds: 2)
    #expect(pitch(slide.left, 0.0, 0.12) < 560 && pitch(slide.left, 0.3, 0.4) > 600 && pitch(slide.left, 0.3, 0.4) < 1000)
    #expect(abs(pitch(slide.left, 1, 2) - 1045) <= 5)
    // A slide to a volume: from nothing to all of it over two rows, and no further.
    let swell = try heard(far([[(0, 0, .note(volume: 0)), (1, 0, .command(0xA4, volume: 15))]]), seconds: 2)
    #expect(loudness(swell.left, 0.02, 0.1) == 0 && loudness(swell.left, 0.2, 0.3) > 0.005)
    let full = try heard(far([[(0, 0, .note())]]), seconds: 2)
    #expect(abs(loudness(swell.left, 1, 2) - loudness(full.left, 1, 2)) < 0.002)
    // 1 and 2 move the pitch once, by so many steps of the Ultrasound's frequency: 567 samples a
    // second for four of them.
    let sharp = try heard(far([[(0, 0, .note(25, sample: 0, volume: 15, 0x14))]]))
    #expect(abs(pitch(sharp.left, 0.2, 1) - 523 * (16726 + 567.5) / 16726) <= 3)
    let flat = try heard(far([[(0, 0, .note(25, sample: 0, volume: 15, 0x24))]]))
    #expect(abs(pitch(flat.left, 0.2, 1) - 523 * (16726 - 567.5) / 16726) <= 3)
    // 7 and 8 move the volume once.
    let quieter = try heard(far([[(0, 0, .note(25, sample: 0, volume: 15, 0x85))]]))
    #expect(abs(loudness(quieter.left, 0.2, 1) * 1.5 - loudness(full.left, 0.2, 1)) < 0.003)
    let louder = try heard(far([[(0, 0, .note(25, sample: 0, volume: 5, 0x75))]]))
    #expect(abs(loudness(louder.left, 0.2, 1) - loudness(quieter.left, 0.2, 1)) < 0.002)
}

@Test func farNoteIsStruckAgainAndWavers() throws {
    // A sample that does not go round, struck four times in its row: there is sound in every quarter of it.
    let once = [Sound(frames: [Int16](repeating: 90, count: 300), loops: false)]
    let plain = try heard(far([[(0, 0, .note())]], sounds: once), seconds: 0.2)
    let again = try heard(far([[(0, 0, .note(25, sample: 0, volume: 15, 0x44))]], sounds: once), seconds: 0.2)
    #expect(loudness(plain.left, 0.07, 0.12) < 0.0005 && loudness(again.left, 0.07, 0.12) > 0.005)
    // C strikes it once more, so many ticks in.
    let twice = try heard(far([[(0, 0, .note(25, sample: 0, volume: 15, 0xC2))]], sounds: once), seconds: 0.2)
    #expect(loudness(twice.left, 0.035, 0.06) < 0.0005 && loudness(twice.left, 0.064, 0.08) > 0.005 && loudness(twice.left, 0.1, 0.12) < 0.0005)
    // A vibrato lasts its row, and 9 keeps one going until it is given a speed of nought.
    func crossings(_ sound: [Float], _ from: Double, _ to: Double) -> Double { pitch(sound, from, to) }
    let still = try heard(far([[(0, 0, .note())]]), seconds: 1.5)
    let wavers = try heard(far([[(0, 0, .note(25, sample: 0, volume: 15, 0x5F)), (1, 0, .command(0x94)), (6, 0, .command(0x90))]]), seconds: 1.5)
    #expect(wavers.left[9000 ..< 30000] != still.left[9000 ..< 30000])
    #expect(abs(crossings(wavers.left, 1, 1.5) - 523) <= 3)
}

@Test func farChannelLeftOutIsNotHeardAndPlaysOn() throws {
    var options = LoadOptions()
    options.stereo = .abc
    /// Half a second of what is heard, and how loud each channel was said to be.
    func played(_ renderer: any Renderer) -> (left: [Float], right: [Float], levels: [Float]) {
        var buffer = [Float](repeating: 0, count: 24000 * 2), levels = [Float](repeating: 0, count: renderer.channelCount)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 24000) }
        renderer.takeChannelLevels(into: &levels)
        return (stride(from: 0, to: buffer.count, by: 2).map { buffer[$0] }, stride(from: 1, to: buffer.count, by: 2).map { buffer[$0] }, levels)
    }
    func fresh(_ file: [UInt8]) throws -> any Renderer { try TuneLoader.load(file, format: .far, options: options) }
    // A note on the first channel, hard left, and the octave above on the second, hard right; and
    // the first alone.
    let both = far([[(0, 0, .note()), (0, 1, .note(37))]], pans: [0, 15])
    let whole = played(try fresh(both)), alone = played(try fresh(far([[(0, 0, .note())]], pans: [0, 15])))
    #expect(whole.levels[0] > 0.2 && whole.levels[1] > 0.2 && whole.right.map(abs).max()! > 0.01)

    // The second left out: the tune without its note, to the sample, with nothing on the right,
    // and the channel is said to be as loud as it was.
    let renderer = try fresh(both)
    renderer.setMuted([false, true])
    let without = played(renderer)
    #expect(without.left == alone.left && without.right == alone.right && without.right.allSatisfy { $0 == 0 })
    #expect(without.levels == whole.levels)

    // A song started again is started without the channel; and with it brought back, as it ever was.
    renderer.select(subsong: 0)
    #expect(played(renderer).left == without.left)
    renderer.setMuted([])
    renderer.select(subsong: 0)
    let again = played(renderer)
    #expect(again.left == whole.left && again.right == whole.right)

    // Every channel left out is silence.
    renderer.setMuted([Bool](repeating: true, count: 16))
    renderer.select(subsong: 0)
    let none = played(renderer)
    #expect(none.left.allSatisfy { $0 == 0 } && none.right.allSatisfy { $0 == 0 } && none.levels == whole.levels)
}

@Test func farFileThatIsCutOrDamagedIsReadOrRefused() throws {
    let whole = far([[(0, 0, .note(25, sample: 0, volume: 15, 0x34)), (1, 1, .note(40, sample: 1, volume: 9, 0x43)), (2, 0, .command(0xFF)), (3, 2, .command(0xDF))], [(0, 2, .note())]],
                    rows: [10, 3], orders: [0, 1, 7], restart: 1, sounds: [Sound(), Sound(frames: [Int16](repeating: 60, count: 300), sixteen: true)])
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .far) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("FAR and no more".utf8), format: .far) }
    func play(_ file: [UInt8]) {
        guard let renderer = try? TuneLoader.load(file, format: .far) else { return }
        var buffer = [Float](repeating: 0, count: 4800 * 2)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        #expect(buffer.allSatisfy { $0.isFinite && abs($0) < 4 })
    }
    for length in stride(from: 0, to: whole.count, by: 31) { play(Array(whole[..<length])) }
    // And with anything at all for its lists, its patterns and its samples' headers.
    var seed: UInt32 = 1994
    func random() -> UInt8 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: seed >> 16)
    }
    for _ in 0 ..< 150 {
        var file = whole
        for i in 47 ..< file.count where i != 75 && random() < 50 { file[i] = random() }
        play(file)
    }
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

@Test func farChannelsHaveScopes() throws {
    // A note at full volume on the first channel and one at a quarter of it on the second, of a
    // square wave as loud as a sample can be; the others silent.
    let loud = Sound(frames: (0 ..< 32).map { $0 < 16 ? 127 : -127 })
    let file = far([[(0, 0, .note()), (0, 1, .note(32, volume: 4))]], sounds: [loud])
    let heard = try scopes(file, format: .far)
    #expect(heard.same)
    for scopes in [heard.now, heard.again] {
        #expect(height(scopes[0]) > 115)
        // (A quarter of the swing is half the height.)
        #expect(height(scopes[1]) > 50 && height(scopes[1]) < 80)
        #expect(scopes[2...].allSatisfy { $0.allSatisfy { $0 == 128 } })
    }
    // A channel left out is still seen to play.
    let without = try scopes(file, format: .far, muted: [true])
    #expect(without.same && height(without.now[0]) > 115 && height(without.again[0]) > 115)
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

@Test func farLightIsOfWhatIsHeard() throws {
    // A note of a sample that does not go round: the light is lit for what gives out its sound,
    // and for nothing after.
    let once = Sound(frames: (0 ..< 640).map { $0 % 32 < 16 ? 100 : -100 } + [0, 0], loops: false)
    let calls = try heardAndLit(far([[(0, 0, .note())]], sounds: [once]), format: .far, calls: 30, frames: 100)
    #expect(calls.contains { $0.heard } && calls.contains { !$0.heard })
    #expect(calls.allSatisfy { $0.heard == $0.lit })
    // A sample that holds one level is silent, and so is its light once its first tick, in which
    // it is brought in, is past.
    let held = Sound(frames: [Int16](repeating: 100, count: 8000), loops: false)
    #expect(try heardAndLit(far([[(0, 0, .note())]], sounds: [held]), format: .far, calls: 20).dropFirst(10).allSatisfy { !$0.lit })
}

@Test func farWithNothingToHearIsRefusedAndOneCutShortSaysWhatItHasLost() throws {
    func refusal(_ file: [UInt8]) -> String {
        do {
            _ = try TuneLoader.load(file, format: .far)
            return ""
        } catch {
            return "\(error)"
        }
    }
    // Its only sample silent, or the file ending before it: nothing to be heard by.
    #expect(refusal(far([[(0, 0, .note())]], sounds: [Sound(frames: [Int16](repeating: 0, count: 32))])) == "\(Shortfall.nothingToHear)")
    #expect(refusal(Array(far([[(0, 0, .note())]]).dropLast(32 + 20))) == "\(Shortfall.nothingToHear)")
    // Ending in the second sample's header, which is all of that sample lost: the first is heard,
    // and the second is said to be missing.
    let two = Array(far([[(0, 0, .note()), (1, 1, .note(sample: 1))]], sounds: [Sound(), Sound()]).dropLast(32 + 20))
    #expect(try TuneLoader.load(two, format: .far).info.shortfalls == ["The file is cut short: one of its samples is missing, and is silent."])
    #expect(loudness(try heard(two).left, 0.1, 1) > 0.01)
}
