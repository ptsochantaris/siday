// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayFoundation
import Testing

// How far a song is turned up or down when tunes are levelled, and how it is measured to find out.

@Test func aSongIsBroughtToTheCommonLoudness() {
    let quiet = SongLevel(loudness: -26.95, truePeak: -12)
    #expect(abs(quiet.change(.full) - 4) < 1e-9)
    #expect(abs(quiet.change(.partial) - 2) < 1e-9)
    #expect(quiet.change(.off) == 0)
    let loud = SongLevel(loudness: -12.95, truePeak: 0.5)
    #expect(abs(loud.change(.full) + 10) < 1e-9)
    #expect(abs(loud.change(.partial) + 5) < 1e-9)
    #expect(abs(loud.gain(.full) - 0.31623) < 1e-4)
}

@Test func aQuietSongIsTurnedUpOnlySoFar() {
    // No more than 6 dB, however quiet it is.
    #expect(SongLevel(loudness: -40, truePeak: -30).change(.full) == 6)
    #expect(SongLevel(loudness: -40, truePeak: -30).change(.partial) == 6)
    // And not so far that its peaks come within 1 dB of the top.
    #expect(abs(SongLevel(loudness: -27, truePeak: -3.5).change(.full) - 2.5) < 1e-9)
    // A song that peaks there already is left as it is, and not turned down for it.
    #expect(SongLevel(loudness: -27, truePeak: -0.2).change(.full) == 0)
}

@Test func aSilentSongIsLeftAsItIs() {
    let silent = SongLevel(loudness: nil, truePeak: -240)
    #expect(silent.change(.full) == 0)
    #expect(silent.gain(.partial) == 1)
}

/// A song of a steady 997 Hz tone, at a level that can change once along the way.
private final class Tone: Renderer {
    let info = TuneInfo(format: "TEST")
    let knownLength: Double?
    private let before: Double, after: Double, change: Double
    private var frame = 0

    /// - Parameters:
    ///   - before: its peak in dB of full scale until `change` seconds in, and `after` it from then on.
    init(length: Double?, before: Double, after: Double? = nil, change: Double = 0) {
        knownLength = length
        self.before = pow(10, before / 20)
        self.after = pow(10, (after ?? before) / 20)
        self.change = change
    }

    var hasEnded: Bool { knownLength.map { Double(frame) / 48000 >= $0 } ?? false }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0 ..< frames {
            let t = Double(frame + i) / 48000
            let v = Float((t < change ? before : after) * sin(2 * Double.pi * 997 * t))
            buffer[2 * i] = v
            buffer[2 * i + 1] = v
        }
        frame += frames
    }

    func setMuted(_: [Bool]) {}
}

@Test func aSongIsMeasuredAsItIsPlayed() throws {
    var policy = PlaybackPolicy()
    policy.defaultTime = 8
    let level = SongMeasurement.measure(Tone(length: 10, before: -20), policy: policy)
    let loudness = try #require(level.loudness)
    #expect(abs(loudness + 20) < 0.1)
    #expect(abs(level.truePeak + 20) < 0.05)
    // One of no known length is measured for as long as it is played, and its fade: here eight
    // seconds and twenty of fading, all but the quietest end of which is counted.
    let unknown = try #require(SongMeasurement.measure(Tone(length: nil, before: -20), policy: policy).loudness)
    #expect(unknown > -22.5 && unknown < -21)
}

@Test func theWholeSongIsMeasured() throws {
    // Quiet for its first three seconds, then loud to its end: it is as loud as its loud part, nearly.
    let level = SongMeasurement.measure(Tone(length: 20, before: -40, after: -20, change: 3), policy: PlaybackPolicy())
    let loudness = try #require(level.loudness)
    #expect(loudness > -20.5 && loudness < -20)
}

@Test func aSongMeasuredALittleAtATimeIsMeasuredTheSame() throws {
    let whole = SongMeasurement.measure(Tone(length: 6, before: -30, after: -18, change: 2), policy: PlaybackPolicy())
    let measurement = SongMeasurement(renderer: Tone(length: 6, before: -30, after: -18, change: 2), policy: PlaybackPolicy())
    var steps = 0
    while measurement.measure(frames: 1000) == nil { steps += 1 }
    #expect(steps > 100)
    #expect(measurement.level == whole)
}

@Test func aLevelIsKeptAsText() {
    for level in [SongLevel(loudness: -22.95, truePeak: -1.25), SongLevel(loudness: nil, truePeak: -240)] {
        let kept = SongLevel(text: level.text)
        #expect(kept?.loudness == level.loudness)
    }
    #expect(SongLevel(text: "-18500 -3200") == SongLevel(loudness: -18.5, truePeak: -3.2))
    #expect(SongLevel(text: "") == nil)
    #expect(SongLevel(text: "loud -3200") == nil)
}

@Test func aLevelIsKeptForTheSongAndHowItIsPlayed() {
    let file: [UInt8] = [1, 2, 3]
    var options = LoadOptions(), policy = PlaybackPolicy()
    let key = SongLevel.key(of: file, song: 0, options: options, policy: policy)
    #expect(key == SongLevel.key(of: file, song: 0, options: options, policy: policy))
    #expect(key != SongLevel.key(of: [1, 2, 4], song: 0, options: options, policy: policy))
    #expect(key != SongLevel.key(of: file, song: 1, options: options, policy: policy))
    options.amigaModel = .a500
    #expect(key != SongLevel.key(of: file, song: 0, options: options, policy: policy))
    options = LoadOptions()
    policy.loops = 2
    #expect(key != SongLevel.key(of: file, song: 0, options: options, policy: policy))
}

@Test func theGainGlidesToWhereTheSongNeedsIt() {
    var gain = LevelGain()
    var block = [Float](repeating: 1, count: 2 * 48000)
    block.withUnsafeMutableBufferPointer { gain.apply($0.baseAddress!, frames: 48000) }
    #expect(block.allSatisfy { $0 == 1 })
    gain.glide(to: 0.5)
    block = [Float](repeating: 1, count: 2 * 48000)
    block.withUnsafeMutableBufferPointer { gain.apply($0.baseAddress!, frames: 24000) }
    // Halfway there after half a second, and there after a second.
    #expect(abs(block[2 * 23999] - 0.75) < 0.001)
    block = [Float](repeating: 1, count: 2 * 48000)
    block.withUnsafeMutableBufferPointer { gain.apply($0.baseAddress!, frames: 48000) }
    #expect(abs(block[2 * 24001] - 0.5) < 1e-6)
    #expect(block[2 * 47999] == 0.5 && block[2 * 47999 + 1] == 0.5)
    #expect(gain.gain == 0.5)
    #expect(LevelGain(2).gain == 2)
}

@Test func aLevelIsKeptForTheSoundItWasMeasuredFrom() {
    // A level measured before a player was changed is not the level of what is heard now.
    let key = SongLevel.key(of: [1, 2, 3], song: 0, options: LoadOptions(), policy: PlaybackPolicy())
    #expect(key.hasPrefix("\(SongLevel.soundVersion) "))
}

@Test func aSongPartlyMeasuredHasALevelToStartAt() throws {
    let measurement = SongMeasurement(renderer: Tone(length: 30, before: -20, after: -30, change: 10), policy: PlaybackPolicy())
    #expect(measurement.provisional == nil)
    measurement.measure(frames: 48000)
    #expect(measurement.provisional == nil)
    measurement.measure(frames: 4 * 48000)
    // Five seconds in, it is as loud as those five seconds; measured whole, it is quieter.
    let early = try #require(measurement.provisional?.loudness)
    #expect(abs(early + 20) < 0.2)
    while measurement.measure(frames: 48000) == nil {}
    #expect(measurement.provisional == measurement.level)
    #expect(try #require(measurement.level?.loudness) < early - 1)
}

@Test func aSongHeardBeforeItIsMeasuredWholeComesToItsLevelBySteps() throws {
    // Quiet (volume 8) for the first half of its pattern, then loud (64).
    var file = squareModule()
    file[1084 + 2] = 0x1C
    file[1084 + 3] = 0x08
    file[1084 + 32 * 16 + 2] = 0x0C
    file[1084 + 32 * 16 + 3] = 0x40
    let player = TunePlayer()
    var values = Setting.standards
    values[Setting.levelling.rawValue] = 1
    _ = player.setSettings(values)
    #expect(player.load(file, name: "steps.mod"))
    // (Room for the most pulled or presented at once: three seconds.)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: outputSampleRate * 3 * 2)
    defer { buffer.deallocate() }
    func pull(_ seconds: Double) { _ = player.pull(into: buffer, frames: Int(seconds * Double(outputSampleRate))) }
    // What a sample of one comes out as, a while on: the gain then.
    func gain(after seconds: Double) -> Float {
        let count = Int(seconds * Double(outputSampleRate))
        buffer.update(repeating: 1, count: count * 2)
        player.present(buffer, frames: count)
        return buffer[count * 2 - 1]
    }
    // It starts at about the level of its quiet half, turned up.
    pull(3)
    player.startAtProvisionalLevel()
    let started = gain(after: 0.05)
    #expect(started > 1.5)
    // Once its loud half has been measured too, though not yet the whole of it, it is turned down.
    pull(3)
    #expect(player.waitsForLevel)
    #expect(gain(after: 1.5) < started * 0.7)
}
