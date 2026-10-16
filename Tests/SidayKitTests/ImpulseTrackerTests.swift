// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the Impulse Tracker path. The thorough check is made outside the package, against
// the player it is ported from (it2play): `siday --raw out.raw tune.it` writes the tune as that
// player would write it to a file, and the two are to agree to the sample.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0, count: length - bytes.count) }

/// An IT file of one pattern and one sample, a square wave of 32 samples, looping, with C-5 on the
/// first channel of the first row.
/// - Parameters:
///   - row: the packed bytes of the first row, in place of that note.
///   - pan: where the first channel sits, from 0 (left) to 64 (right).
///   - orders: the list of patterns to play, where 255 is its end.
///   - emptySample: whether there is a second sample, of no length, whose sound is said to be at the
///     end of the file: ModPlug Tracker's way of writing an empty one.
///   - before: how many samples of nothing come before the square wave, which the note then plays
///     by its number.
private func it(row: [UInt8]? = nil, pan: UInt8 = 32, orders: [UInt8] = [0, 255], emptySample: Bool = false, before: Int = 0) -> [UInt8] {
    let samples = before + (emptySample ? 2 : 1)
    var file = Array("IMPM".utf8) + padded(Array("a square wave".utf8), to: 26) + [4, 16]
    file += word(orders.count) + word(0) + word(samples) + word(1) + word(0x0214) + word(0x0200) + word(1) + word(0)
    file += [128, 48, 6, 125, 128, 0] + word(0) + long(0) + long(0)
    file += [pan] + [UInt8](repeating: 32, count: 63) + [UInt8](repeating: 64, count: 64)
    file += orders
    let tables = file.count + samples * 4 + 4
    let sampleHeader = tables, pattern = sampleHeader + samples * 0x50
    let rows = (row ?? [0x81, 0x03, 60, UInt8(before + 1)]) + [UInt8](repeating: 0, count: 64)
    let sound = pattern + 8 + rows.count
    for i in 0 ..< samples { file += long(sampleHeader + i * 0x50) }
    file += long(pattern)

    var header = Array("IMPS".utf8) + [UInt8](repeating: 0, count: 13) + [64, 0x11, 64] + padded(Array("square".utf8), to: 26) + [1, 0]
    header += long(32) + long(0) + long(32) + long(8363) + long(0) + long(0) + long(sound) + [0, 0, 0, 0]
    for _ in 0 ..< before { file += padded(Array("IMPS".utf8), to: 0x50) }
    file += header
    if emptySample {
        var empty = Array("IMPS".utf8) + [UInt8](repeating: 0, count: 13) + [64, 0x01, 64] + [UInt8](repeating: 0, count: 26) + [1, 0]
        empty += long(0) + long(0) + long(0) + long(8363) + long(0) + long(0) + long(sound + 32) + [0, 0, 0, 0]
        file += empty
    }
    file += word(rows.count) + word(64) + long(0) + rows
    // Signed, as Impulse Tracker has them: the top of the range, then the bottom.
    file += (0 ..< 32).map { $0 < 16 ? 0x7F : 0x81 }
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

@Test func itNoteSoundsAtItsPitch() throws {
    // C-5 plays a sample at the rate it gives, 8363 samples a second, and the square wave is 32 of
    // them: 261 Hz.
    let renderer = try TuneLoader.load(it(), format: .it)
    #expect(renderer.info.format == "IT")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "Impulse Tracker 2.14")
    let sound = stereo(renderer, seconds: 1).left
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 261) <= 2)
    #expect(sound[4800...].map(abs).max()! > 0.02)
    // An octave up is twice that.
    let higher = stereo(try TuneLoader.load(it(row: [0x81, 0x03, 72, 1]), format: .it), seconds: 1).left
    #expect(abs(crossings(higher[4800...]) * 10 / 9 - 523) <= 3)
}

@Test func itChannelIsHeardWhereItIsPlaced() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let left = stereo(try TuneLoader.load(it(pan: 0), format: .it, options: options), seconds: 0.5)
    #expect(left.left[4800...].map(abs).max()! > 0.02)
    #expect(left.right[4800...].map(abs).max()! < left.left[4800...].map(abs).max()! * 0.05)
    let right = stereo(try TuneLoader.load(it(pan: 64), format: .it, options: options), seconds: 0.5)
    #expect(right.left[4800...].map(abs).max()! < right.right[4800...].map(abs).max()! * 0.05)
    // In mono both sides are the same.
    let mono = stereo(try TuneLoader.load(it(pan: 0), format: .it), seconds: 0.5)
    #expect(mono.left == mono.right)
    #expect(mono.left[4800...].map(abs).max()! > 0.01)
}

@Test func itKnowsHowLongItIsAndHowManySongsItHas() throws {
    // 64 rows of 6 ticks at fifty ticks a second.
    let plain = try TuneLoader.load(it(), format: .it)
    #expect(abs(plain.knownLength! - 7.68) < 0.01)
    #expect(plain.endsByLooping)
    #expect(plain.subsongCount == 1)
    // A break on the first row: one row, and it counts each time round.
    let short = try TuneLoader.load(it(row: [0x81, 0x0B, 60, 1, 3, 0]), format: .it)
    #expect(abs(short.knownLength! - 0.12) < 0.01)
    _ = stereo(short, seconds: 0.5)
    #expect(short.loopCount == 4)
    // The pattern again after the end of the list, where nothing leads to it, is a second song.
    let two = try TuneLoader.load(it(orders: [0, 255, 0, 255]), format: .it)
    #expect(two.subsongCount == 2)
    two.select(subsong: 1)
    #expect(abs(two.knownLength! - 7.68) < 0.01)
    #expect(stereo(two, seconds: 0.5).left[4800...].map(abs).max()! > 0.02)
    // It is over where it runs off the end of the list into the first song, and ends there.
    #expect(abs(sessionLength(try TuneLoader.load(it(orders: [0, 255, 0, 255]), format: .it), song: 1) - 7.68) < 0.4)
    #expect(sessionLength(try TuneLoader.load(it(orders: [0, 255, 0, 255]), format: .it), song: 0) > 12)
}

@Test func itFilterTakesTheEdgeOffASquareWave() throws {
    // Z08 on the note's row closes the filter to some 160 Hz, below the note: its harmonics go
    // and the note itself is a good deal quieter, though still there and still at its pitch.
    let open = stereo(try TuneLoader.load(it(), format: .it), seconds: 1).left
    let closed = stereo(try TuneLoader.load(it(row: [0x81, 0x0B, 60, 1, 26, 0x08]), format: .it), seconds: 1).left
    #expect(abs(crossings(closed[9600...]) * 10 / 8 - 261) <= 3)
    #expect(loudness(closed[9600...]) < loudness(open[9600...]) * 0.7)
    #expect(loudness(closed[9600...]) > loudness(open[9600...]) * 0.05)
}

@Test func itFilesThatAreOddOrNotITAtAll() throws {
    // ModPlug Tracker's empty sample, said to lie at the end of the file, is no reason not to play.
    let renderer = try TuneLoader.load(it(emptySample: true), format: .it)
    #expect(stereo(renderer, seconds: 0.5).left[4800...].map(abs).max()! > 0.02)
    // Cut short in its sample, it plays what it has.
    #expect((try? TuneLoader.load(Array(it().dropLast(20)), format: .it)) != nil)
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x41, count: 4000), format: .it) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(it().prefix(0x60)), format: .it) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("ziRCONia".utf8) + [UInt8](repeating: 0, count: 400), format: .it) }
}

@Test func itFileWithMoreSamplesThanImpulseTrackerHadRoomForIsPlayed() throws {
    // Impulse Tracker holds a hundred samples, and uses the number after them to mean a note sent
    // out by MIDI. Later trackers wrote files with more: here the hundred-and-first is the one
    // that is played, and then the two-hundredth.
    for before in [100, 199] {
        let renderer = try TuneLoader.load(it(before: before), format: .it)
        let sound = stereo(renderer, seconds: 1).left
        #expect(abs(crossings(sound[4800...]) * 10 / 9 - 261) <= 2)
        #expect(sound[4800...].map(abs).max()! > 0.02)
    }
    // More than a byte can number is more than an IT file can have.
    #expect(throws: TuneError.self) { try TuneLoader.load(it(before: 253), format: .it) }
}

// MARK: What is not played as the file asks

/// A file as OpenMPT 1.29 would sign it: the tracker a file says made it is two bytes of its header.
private func byOpenMPT(_ file: [UInt8]) -> [UInt8] {
    var file = file
    file[40 ... 41] = [0x29, 0x51]
    return file
}

@Test func itFromALaterTrackerPlaysASampleBackwards() throws {
    /// The file with its square wave made a ramp that climbs from the bottom of the range to the
    /// top: forwards the note begins by climbing, and backwards by falling. (It is a loop of 32
    /// samples, and a loop is gone through backwards once and then forwards as before, so it is
    /// the first of the note that tells: 32 samples of the wave are 180 of the sound.)
    func ramp(_ file: [UInt8]) -> [UInt8] { Array(file.dropLast(32)) + (0 ..< 32).map { UInt8(truncatingIfNeeded: $0 * 8 - 128) } }
    /// How much the sound climbs from one sample to the next, over the first of the note.
    func climb(_ sound: [Float]) -> Float { (sound[150] - sound[30]) / 120 }
    let row: [UInt8] = [0x81, 0x0B, 60, 1, 19, 0x9F]
    let forwards = climb(stereo(try TuneLoader.load(ramp(byOpenMPT(it())), format: .it), seconds: 0.1).left)
    #expect(forwards > 0.0005)
    // S9F on the note's row, in a file that OpenMPT made.
    let renderer = try #require(try TuneLoader.load(ramp(byOpenMPT(it(row: row))), format: .it) as? ITRenderer)
    let backwards = climb(stereo(renderer, seconds: 0.1).left)
    #expect(backwards < -0.0005 && abs(backwards + forwards) < forwards * 0.2)
    // In a file that Impulse Tracker made it is nothing, as it is to Impulse Tracker; and so it is
    // in the other when that is played as the player this is ported from plays it.
    let itsOwn = climb(stereo(try TuneLoader.load(ramp(it(row: row)), format: .it), seconds: 0.1).left)
    #expect(abs(itsOwn - forwards) < forwards * 0.05)
    let raw = renderer.renderRaw(frames: 4800)
    #expect(climb(stride(from: 0, to: raw.count, by: 2).map { Float(raw[$0]) }) > 0)
}

@Test func itFromModPlugSlidesItsFilterOverARow() throws {
    // The filter closed to some 160 Hz on the note's row, as in the test above: at once with Z,
    // and with the command after it a little at a time, over the six ticks of the row, so that
    // the note begins nearly as bright as it would have been and ends as dull.
    func sound(_ command: UInt8, _ file: ([UInt8]) -> [UInt8] = byOpenMPT) throws -> [Float] {
        stereo(try TuneLoader.load(file(it(row: [0x81, 0x0B, 60, 1, command, 0x08])), format: .it), seconds: 1).left
    }
    let open = stereo(try TuneLoader.load(byOpenMPT(it()), format: .it), seconds: 1).left
    let atOnce = try sound(26), slid = try sound(28)
    // The first tick is a fiftieth of a second, 960 samples.
    #expect(loudness(slid[200 ..< 900]) > loudness(atOnce[200 ..< 900]) * 1.5)
    #expect(loudness(slid[200 ..< 900]) > loudness(open[200 ..< 900]) * 0.6)
    // By the end of the row, and from then on, the two are the same.
    #expect(abs(loudness(slid[9600...]) - loudness(atOnce[9600...])) < loudness(atOnce[9600...]) * 0.05)
    #expect(loudness(slid[9600...]) < loudness(open[9600...]) * 0.7)
    // In a file that Impulse Tracker made, the command is nothing.
    let itsOwn = try sound(28) { $0 }
    #expect(abs(loudness(itsOwn[9600...]) - loudness(open[9600...])) < loudness(open[9600...]) * 0.02)
}

/// A file as ModPlug Tracker signed one, and as an OpenMPT of these two figures (0x29 for 1.29)
/// signs one that it saves to be played as it plays it itself.
private func byModPlugTracker(_ file: [UInt8]) -> [UInt8] {
    var file = file
    file[40 ... 43] = [0x14, 0x02, 0x02, 0x02]
    return file
}

private func asOpenMPTPlays(_ file: [UInt8], version: UInt8) -> [UInt8] {
    var file = file
    file[40 ... 41] = [version, 0x51]
    file[60 ... 63] = Array("OMPT".utf8)[...]
    return file
}

@Test func itThatJumpsBackInsideALoopIsPlayedToItsEnd() throws {
    // A tune made as a puzzle. Its first row jumps to its third, which jumps back to its second;
    // the second has a loop of two more turns, which takes it to the first again. So the first
    // three rows are played three times over, out of order and by jumps as well as by the loop,
    // and none of that is the tune coming round: it goes on to its fourth row when the loop's
    // count has run out, and ends when it runs off the end of its list, 70 rows of 0.12 seconds
    // after it began.
    func effect(_ channel: UInt8, _ command: UInt8, _ value: UInt8) -> [UInt8] { [0x80 | channel, 0x08, command, value] }
    let jumpToStart = effect(3, 2, 0)
    let rows = [0x81, 0x03, 60, 1] + jumpToStart + effect(4, 3, 2) + [0]
        + effect(2, 19, 0xB2) + jumpToStart + effect(4, 3, 3) + [0]
        + effect(2, 19, 0xB0) + jumpToStart + effect(4, 3, 1) + [0]
    let renderer = try TuneLoader.load(it(row: rows), format: .it)
    #expect(abs(try #require(renderer.knownLength) - 70 * 0.12) < 0.05)
    #expect(renderer.subsongCount == 1)
    // And a tune that only goes round and round, with nothing counting, is still known for one:
    // its fourth row jumps back to its second, and it has come round after four rows.
    let round = [0x81, 0x03, 60, 1] + [0] + [0] + [0] + jumpToStart + effect(4, 3, 1) + [0]
    let endless = try TuneLoader.load(it(row: round), format: .it)
    #expect(abs(try #require(endless.knownLength) - 4 * 0.12) < 0.05)
}

@Test func itFromOpenMPTIsAsLoudAsOpenMPTPlaysIt() throws {
    func heard(_ file: [UInt8]) throws -> Float { loudness(stereo(try TuneLoader.load(file, format: .it), seconds: 0.5).left[4800...]) }
    func level(_ file: [UInt8]) throws -> Float { IT2Mixer.modPlugLevel(of: try #require(try TuneLoader.load(file, format: .it) as? ITRenderer).module) }
    // The song's own extras, as OpenMPT puts them at a file's end: which of its ways of adding
    // the channels up, how many channels it has, and a pre-amp of more than the header holds.
    func extras(mixLevels: Int? = nil, channels: Int? = nil, preAmp: Int? = nil) -> [UInt8] {
        var bytes = Array("STPM".utf8)
        if let mixLevels { bytes += Array(".MMP".utf8) + word(4) + long(mixLevels) }
        if let channels { bytes += Array("...C".utf8) + word(2) + word(channels) }
        if let preAmp { bytes += Array(".APS".utf8) + word(4) + long(preAmp) }
        return bytes
    }
    let own = try heard(it())
    // Impulse Tracker's own file is as it was, and so is one that OpenMPT saved to be played as
    // Impulse Tracker would play it.
    #expect(try level(it()) == 1)
    #expect(try level(byOpenMPT(it())) == 1)
    // OpenMPT's way of 1.17 is twice as loud.
    #expect(try level(asOpenMPTPlays(it() + extras(mixLevels: 3), version: 0x17)) == 2)
    #expect(abs(try heard(asOpenMPTPlays(it() + extras(mixLevels: 3), version: 0x17)) / own - 2) < 0.05)
    // Its oldest way, ModPlug Tracker's, OpenMPT plays quieter the more channels the song has;
    // here it is not followed, so that such files are about as loud as all the others, which by how
    // loud they are heard puts them 1.4 dB below Impulse Tracker's. A file with no word of its way
    // is played the oldest way.
    #expect(try level(asOpenMPTPlays(it(), version: 0x17)) == 0.85)
    #expect(abs(try heard(asOpenMPTPlays(it() + extras(mixLevels: 0, channels: 16), version: 0x17)) / own - 0.85) < 0.02)
    // Its way of 1.17 that comes before that one is followed, by those channels its patterns use,
    // or those the file says it has, if that is more: measured, it leaves its files as loud as the rest.
    #expect(try level(asOpenMPTPlays(it() + extras(mixLevels: 2, channels: 32), version: 0x28)) == 64.0 / 0xBC)
    // The ways that are like Impulse Tracker's are as loud as Impulse Tracker; and a pre-amp of
    // more than the header can hold is that much more.
    #expect(try level(asOpenMPTPlays(it() + extras(mixLevels: 4), version: 0x28)) == 1)
    #expect(try level(asOpenMPTPlays(it() + extras(mixLevels: 4, preAmp: 96), version: 0x28)) == 2)
    // ModPlug Tracker's own files the mixer turns down itself, as the player it is ported from
    // does; that is taken out again, and they are as loud as any other of that way.
    #expect(try level(byModPlugTracker(it())) > 1)
    #expect(abs(try heard(byModPlugTracker(it())) / own - 0.85) < 0.02)
    // Set beside the player this one is ported from, none of it is done.
    let reference = try #require(try TuneLoader.load(asOpenMPTPlays(it() + extras(mixLevels: 3), version: 0x17), format: .it) as? any ReferenceComparable)
    let itsOwn = try #require(try TuneLoader.load(it(), format: .it) as? any ReferenceComparable)
    #expect(reference.renderRaw(frames: 20000) == itsOwn.renderRaw(frames: 20000))
}

@Test func itSampleVibratoComesInAtOnceForAnOldOpenMPT() throws {
    // A sample with a vibrato of its own, and nought for how fast it comes in. To Impulse Tracker
    // that is never; to ModPlug Tracker and to OpenMPT before 1.20 it was at once, and a file of
    // theirs is played so.
    var file = it()
    let sample = try #require(file.indices.first { file[$0...].starts(with: Array("IMPS".utf8)) })
    file[sample + 0x4C ... sample + 0x4F] = [24, 32, 0, 0]
    func heard(_ file: [UInt8]) throws -> [Float] { stereo(try TuneLoader.load(file, format: .it), seconds: 1).left }
    let plain = try heard(it())
    // Impulse Tracker's own file, and one of an OpenMPT that had put it right: no vibrato at all.
    #expect(try heard(file) == plain)
    // (Each is set beside the same file with no vibrato in it, signed the same way: a file of
    // OpenMPT's is as loud as OpenMPT plays it, which is not as loud as Impulse Tracker.)
    #expect(try heard(asOpenMPTPlays(file, version: 0x29)) == heard(asOpenMPTPlays(it(), version: 0x29)))
    // The older tracker's file wobbles, from the start.
    #expect(try heard(asOpenMPTPlays(file, version: 0x19)) != heard(asOpenMPTPlays(it(), version: 0x19)))
    #expect(try heard(byModPlugTracker(file)) != heard(byModPlugTracker(it())))
    let module = try #require(try TuneLoader.load(asOpenMPTPlays(file, version: 0x19), format: .it) as? ITRenderer).module
    #expect(module.sample(0)?.AutoVibratoRate == 0)
    #expect(module.sample(0)?.AutoVibratoRateAsModPlug == 255)
    // And set beside the player this one is ported from, the file's own number stands.
    let reference = try #require(try TuneLoader.load(asOpenMPTPlays(file, version: 0x19), format: .it) as? any ReferenceComparable)
    let itsOwn = try #require(try TuneLoader.load(file, format: .it) as? any ReferenceComparable)
    #expect(reference.renderRaw(frames: 20000) == itsOwn.renderRaw(frames: 20000))
}

@Test func itIsPlayedWithTheFilterOfTheTrackerThatMadeIt() throws {
    func filter(_ file: [UInt8]) throws -> IT2Module.Filter { try #require(try TuneLoader.load(file, format: .it) as? ITRenderer).module.filter }
    #expect(try filter(it()) == .impulseTrackers)
    // ModPlug Tracker had a filter of its own, and OpenMPT has it still for a file that does not
    // ask to be played as Impulse Tracker would play it; a file saved to be played so asks for
    // Impulse Tracker's filter if the OpenMPT that saved it had it, which is from 1.20.
    #expect(try filter(byModPlugTracker(it())) == .openMPTs)
    #expect(try filter(asOpenMPTPlays(it(), version: 0x29)) == .openMPTs)
    #expect(try filter(byOpenMPT(it())) == .impulseTrackers)
    var before = byOpenMPT(it())
    before[40] = 0x19
    #expect(try filter(before) == .openMPTs)
    // And the wider range of cutoffs, which is ModPlug Tracker's, is on OpenMPT's curve whoever asks.
    var wide = it()
    wide[45] |= 0x10
    #expect(try filter(wide) == .openMPTsCurve)
    #expect(try filter(byModPlugTracker(wide)) == .openMPTs)

    // What the file lists settles it, where it has a list: "compatible play" alone, from a
    // version before 1.26, asks for whatever of Impulse Tracker's ways that version had.
    typealias Ways = IT2Module.ModPlugWays
    func asked(_ behaviours: [Int]) -> [Bool] { (0 ..< 64).map { behaviours.contains($0) } }
    #expect(Ways(asked: asked([0]), savedWith: 0x0122_0000, wideRange: false).filter == .impulseTrackers)
    #expect(Ways(asked: asked([0]), savedWith: 0x0119_0400, wideRange: false).filter == .openMPTs)
    #expect(Ways(asked: asked([0]), savedWith: 0x0128_0000, wideRange: false).filter == .openMPTs)
    #expect(Ways(asked: asked([0, 36]), savedWith: 0x0128_0000, wideRange: false).filter == .impulseTrackers)
    #expect(Ways(asked: asked([0]), savedWith: 0x0118_0000, wideRange: false).ownEnvelopeCarry == false)
    #expect(Ways(asked: asked([]), savedWith: 0x0118_0000, wideRange: false).ownEnvelopeCarry)
    #expect(Ways(asked: asked([0]), savedWith: 0x0118_0000, wideRange: false).slideRestartsEnvelopes)
    #expect(Ways().filter == .impulseTrackers && !Ways().ownEnvelopeCarry && !Ways().slideRestartsEnvelopes)
}

@Test func itFromModPlugTrackerIsHeardThroughModPlugTrackersFilter() throws {
    /// The steepest step from one sample of a sound to the next: how sharp its edges are.
    func edge(_ samples: ArraySlice<Float>) -> Float { zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }
    // Z7F on the note's row: the filter wide open, which to Impulse Tracker is no filter, and to
    // ModPlug Tracker one that takes the top off the sound at five kilohertz.
    let row: [UInt8] = [0x81, 0x0B, 60, 1, 26, 0x7F]
    let open = stereo(try TuneLoader.load(it(), format: .it), seconds: 0.5).left
    #expect(stereo(try TuneLoader.load(it(row: row), format: .it), seconds: 0.5).left == open)
    let renderer = try #require(try TuneLoader.load(byModPlugTracker(it(row: row)), format: .it) as? ITRenderer)
    let without = try #require(try TuneLoader.load(byModPlugTracker(it()), format: .it) as? ITRenderer)
    let dulled = stereo(renderer, seconds: 0.5).left, plain = stereo(without, seconds: 0.5).left
    #expect(edge(dulled[4800...]) < edge(plain[4800...]) * 0.75)
    #expect(abs(loudness(dulled[4800...]) - loudness(plain[4800...])) < loudness(plain[4800...]) * 0.1)
    // Played as the player this is ported from plays it, the command is nothing in that file too.
    #expect(renderer.renderRaw(frames: 9600) == without.renderRaw(frames: 9600))
}

@Test func modPlugsExtrasSayHowAnInstrumentsFilterIsSet() {
    // The instruments' extras, as they are at the end of an IT file of three instruments: which
    // way up each one's filter is, and how far its cutoff and its resonance are moved at random.
    var bytes = Array("XTPM".utf8)
    bytes += Array("..MF".utf8) + word(1) + [1, 0xFF, 0]
    bytes += Array("..SC".utf8) + word(1) + [0, 40, 99]
    bytes += Array("..SR".utf8) + word(1) + [0, 0, 0]
    var extras = ModPlugExtras()
    extras.readInstrumentExtras(ByteReader(bytes), from: 0, instruments: 3)
    #expect(extras.filterModes == [1, 0xFF, 0])
    #expect(extras.cutoffSwings == [0, 40, 64])
    #expect(extras.resonanceSwings.isEmpty)
}

@Test func modPlugsExtrasAreFoundWhereTheRestOfTheFileEnds() {
    // They follow whatever of the file ends last: here, the sample's sound. The letters that begin
    // them can be in a sound, and are not taken for them there.
    var file = it()
    let end = IT2Module.extrasPlace(ByteReader(file), 192 + 2, 0, 1, 1)
    #expect(end == file.count)
    let extras = Array("XTPM".utf8) + Array("..MF".utf8) + word(1) + [1]
    file.replaceSubrange(file.count - 32 ..< file.count - 32 + extras.count, with: extras)
    var found = ModPlugExtras()
    found.readInstrumentExtras(ByteReader(file), from: IT2Module.extrasPlace(ByteReader(file), 194, 0, 1, 1), instruments: 1, exactly: true)
    #expect(found.filterModes.isEmpty)
    file += Array("XTPM".utf8) + Array("..MF".utf8) + word(1) + [0]
    found.readInstrumentExtras(ByteReader(file), from: end, instruments: 1, exactly: true)
    #expect(found.filterModes == [0])
    // A cut-short file does not trap.
    for length in 0 ..< file.count { _ = IT2Module.extrasPlace(ByteReader(Array(file[..<length])), 194, 0, 1, 1) }
}

@Test func modPlugsOldWayOfNamingAnInstrumentsPlugInIsRead() {
    // An instrument (its 554 bytes) and after it ModPlug Tracker's piece that names its plug-in.
    let instrument = Array("IMPI".utf8) + [UInt8](repeating: 0, count: 550)
    let piece = Array("MSNI".utf8) + long(5) + Array("GULP".utf8) + [3]
    #expect(IT2Module.oldPlugIn(ByteReader([9, 9] + instrument + piece), after: 2) == 3)
    #expect(IT2Module.oldPlugIn(ByteReader(instrument + Array("MSNI".utf8) + long(5) + Array("GULP".utf8) + [0]), after: 0) == nil)
    #expect(IT2Module.oldPlugIn(ByteReader(instrument), after: 0) == nil)
    for length in 0 ..< piece.count { _ = IT2Module.oldPlugIn(ByteReader(instrument + piece.prefix(length)), after: 0) }
}

@Test func itFromALaterTrackerSaysWhatImpulseTrackerDoesNotPlay() throws {
    func shortfalls(_ file: [UInt8]) throws -> [String] { try TuneLoader.load(file, format: .it).info.shortfalls }
    #expect(try shortfalls(it()).isEmpty)
    #expect(try shortfalls(it(emptySample: true)).isEmpty)

    // ModPlug Tracker's command to play a sample backwards is nothing to Impulse Tracker, and is
    // nothing here in a file of Impulse Tracker's; in a file of a later tracker's it is played.
    #expect(try shortfalls(it(row: [0x81, 0x0B, 60, 1, 19, 0x9F])).isEmpty)
    #expect(try shortfalls(byOpenMPT(it(row: [0x81, 0x0B, 60, 1, 19, 0x9F]))).isEmpty)
    // Its command to send a macro a little at a time is played in a file of its own, and left out
    // of one that some other tracker made.
    #expect(try shortfalls(byOpenMPT(it(row: [0x81, 0x0B, 60, 1, 28, 0x08]))).isEmpty)
    var schism = it(row: [0x81, 0x0B, 60, 1, 28, 0x08])
    schism[40 ... 41] = [0x00, 0x10]
    #expect(try shortfalls(schism)
        == ["One of its commands is left out, which Impulse Tracker did not have: a smooth change to a filter or a plug-in's setting."])
    // Its S9B (four speakers) is left out of a file of its own, and nothing in Impulse Tracker's;
    // its reverb, S99, is played.
    #expect(try shortfalls(byOpenMPT(it(row: [0x81, 0x0B, 60, 1, 19, 0x9B])))
        == ["One of its commands is left out, which Impulse Tracker did not have: settings for four speakers and for how a note's filter starts."])
    #expect(try shortfalls(it(row: [0x81, 0x0B, 60, 1, 19, 0x9B])).isEmpty)
    #expect(try shortfalls(byOpenMPT(it(row: [0x81, 0x0B, 60, 1, 19, 0x99]))).isEmpty)
    // A sample kept in a form that is not read (here, with its bytes the other way round), which a
    // note plays; and the same sample with no note to play it, which is nobody's loss.
    var odd = it()
    let convert = try #require(odd.firstRange(of: Array("IMPS".utf8))).lowerBound + 0x2E
    #expect(odd[convert] == 1)
    odd[convert] = 3
    #expect(try shortfalls(odd) == ["One of its samples is kept in a form this player does not read, and is silent."])
    var unplayed = it(row: [0x81, 0x08, 1, 0x06])
    unplayed[try #require(unplayed.firstRange(of: Array("IMPS".utf8))).lowerBound + 0x2E] = 3
    #expect(try shortfalls(unplayed).isEmpty)
    // A file that ends before its sample's sound begins.
    #expect(try shortfalls(Array(it().dropLast(32))) == ["The file is cut short: one of its samples is missing, and is silent."])
}

// MARK: Voices left out

/// What a player makes of its tune from the start, each side apart, and how loud it said each
/// voice was in it.
private func played(_ renderer: any Renderer, seconds: Double = 0.5) -> (left: [Float], right: [Float], levels: [Float]) {
    let sound = stereo(renderer, seconds: seconds)
    var levels = [Float](repeating: 0, count: renderer.channelCount)
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    return (sound.left, sound.right, levels)
}

@Test func itChannelLeftOutIsNotHeardAndPlaysOn() throws {
    // Two channels: the first all on the left, and the second, an octave up, all on the right.
    func file(_ row: [UInt8]) -> [UInt8] {
        var file = it(row: row, pan: 0)
        file[0x41] = 64
        return file
    }
    let both = file([0x81, 0x03, 60, 1, 0x82, 0x03, 72, 1])
    var options = LoadOptions()
    options.stereo = .abc
    func fresh() throws -> any Renderer { try TuneLoader.load(both, format: .it, options: options) }

    let whole = played(try fresh())
    #expect(whole.levels.count == 2)
    #expect(whole.left.map(abs).max()! > 0.02 && whole.right.map(abs).max()! > 0.02)

    // The second left out: the right is silent, the left is what it was to the last bit (nothing
    // is added to it for a voice all on the other side), and the voice is said to be as loud as ever.
    let renderer = try fresh()
    renderer.setMuted([false, true])
    let without = played(renderer)
    #expect(without.right.allSatisfy { $0 == 0 })
    #expect(without.left == whole.left)
    #expect(without.levels == whole.levels && without.levels[1] > 0.05)

    // A song started again is started without the voice; and with it brought back, as it ever was.
    renderer.select(subsong: 0)
    let again = played(renderer)
    #expect(again.left == without.left && again.right == without.right)
    renderer.setMuted([])
    renderer.select(subsong: 0)
    let back = played(renderer)
    #expect(back.left == whole.left && back.right == whole.right)

    // The first left out is the other way about, and a mark too few is a voice heard.
    let other = try fresh()
    other.setMuted([true])
    let second = played(other)
    #expect(second.left.allSatisfy { $0 == 0 } && second.right == whole.right && second.levels == whole.levels)

    // Every voice left out is silence.
    let silent = try fresh()
    silent.setMuted([true, true])
    let nothing = played(silent)
    #expect(nothing.left.allSatisfy { $0 == 0 } && nothing.right.allSatisfy { $0 == 0 } && nothing.levels == whole.levels)

    // In mono, where the two sides are added up, what is left is the tune without that channel's note.
    let mono = try TuneLoader.load(both, format: .it)
    mono.setMuted([false, true])
    #expect(played(mono).left == played(try TuneLoader.load(file([0x81, 0x03, 60, 1]), format: .it)).left)

    // A voice left out while it sounds is gone from the next tick (here the tenth, of 960 frames),
    // and one brought back is back at the next.
    let late = try fresh()
    let before = played(late, seconds: 0.2)
    late.setMuted([false, true])
    let during = played(late, seconds: 0.2)
    late.setMuted([])
    let after = played(late, seconds: 0.1)
    #expect(before.right == Array(whole.right[..<9600]) && during.right.allSatisfy { $0 == 0 } && after.right == Array(whole.right[19200...]))
    #expect(before.left + during.left + after.left == whole.left)
}

/// How long a session plays a song of a tune for, in seconds, with the tune played once through.
private func sessionLength(_ renderer: any Renderer, song: Int) -> Double {
    renderer.select(subsong: song)
    let session = TuneSession(renderer: renderer, policy: PlaybackPolicy())
    var block = [Float](repeating: 0, count: 1024)
    while !session.finished, session.elapsed < 60 { _ = block.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: 512) } }
    return session.elapsed
}
