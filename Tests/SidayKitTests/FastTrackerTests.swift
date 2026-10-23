// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayFoundation
@testable import SidayTrackers
import Foundation
import Testing

// Fast checks of the FastTracker path. The thorough check is made outside the package, against the
// player it is ported from (ft2play): `siday --raw out.raw tune.xm` writes the tune as that player
// would write it to a file, and the two are to agree to the sample.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ text: String, _ length: Int) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: length - text.utf8.count) }

/// An XM file of one pattern and one instrument: a square wave of 32 samples, looping.
/// - Parameters:
///   - notes: the packed bytes of the pattern's first row, a note for each channel.
///   - pan: where the sample sits, from 0 (left) to 255 (right).
///   - pattern: the whole pattern in place of that: how many rows, and its packed bytes.
///   - settings: bytes of the instrument's header to set, by their place in it.
private func xm(channels: Int = 2, notes: [UInt8]? = nil, pan: UInt8 = 128, tempo: Int = 6, pattern: (rows: Int, data: [UInt8])? = nil,
                settings: [Int: UInt8] = [:]) -> [UInt8]
{
    var file = Array("Extended Module: ".utf8) + padded("a square wave", 20) + [0x1A] + padded("siday", 20) + word(0x0104)
    file += long(276) + word(1) + word(0) + word(channels) + word(1) + word(1) + word(1) + word(tempo) + word(125)
    file += [UInt8](repeating: 0, count: 256)

    // The pattern: C-4 on instrument 1 in the first channel of the first row, and nothing else.
    var rows = notes ?? ([0x83, 49, 1] + [UInt8](repeating: 0x80, count: channels - 1))
    rows += [UInt8](repeating: 0x80, count: 63 * channels)
    file += long(9) + [0] + word(pattern?.rows ?? 64) + word((pattern?.data ?? rows).count) + (pattern?.data ?? rows)

    var instrument = long(263) + padded("square", 22) + [0] + word(1) + long(40)
    instrument += [UInt8](repeating: 0, count: 263 - instrument.count)
    for (place, value) in settings { instrument[place] = value }
    file += instrument
    file += long(32) + long(0) + long(32) + [64, 0, 1, pan, 0, 0] + padded("square", 22)
    // The sample, as the differences from one value to the next: up to 127, and later down to -128.
    var sample = [UInt8](repeating: 0, count: 32)
    sample[0] = 127
    sample[16] = 1
    return file + sample
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

@Test func xmNoteSoundsAtItsPitchWhereItIsPlaced() throws {
    // C-4 plays a sample at 8363 samples a second, and the square wave is 32 of them: 261 Hz.
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try TuneLoader.load(xm(pan: 0), format: .xm, options: options)
    #expect(renderer.info.format == "XM")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "FastTracker 2, 2 channels")

    let sound = stereo(renderer, seconds: 1)
    #expect(abs(crossings(sound.left[4800...]) * 10 / 9 - 261) <= 2)
    #expect(sound.left[4800...].map(abs).max()! > 0.05)
    // Placed hard left, there is none of it on the right.
    #expect(sound.right.map(abs).max()! < 0.0001)

    // In the middle it is the same on both sides, and in mono too wherever it is placed.
    let middle = stereo(try TuneLoader.load(xm(), format: .xm, options: options), seconds: 0.5)
    #expect(middle.left == middle.right)
    let mono = stereo(try TuneLoader.load(xm(pan: 0), format: .xm), seconds: 0.5)
    #expect(mono.left == mono.right)
    #expect(mono.left[4800...].map(abs).max()! > 0.02)
}

@Test func xmKnowsHowLongItIs() throws {
    // 64 rows of 6 ticks, and a tick at 125 beats a minute is 960 samples: 7.68 seconds.
    let plain = try TuneLoader.load(xm(), format: .xm)
    #expect(abs(plain.knownLength! - 7.68) < 0.001)
    #expect(plain.endsByLooping)
    #expect(abs(try TuneLoader.load(xm(tempo: 3), format: .xm).knownLength! - 3.84) < 0.001)

    // A jump back to the first order on the first row: one row, and it counts each time round.
    let short = try TuneLoader.load(xm(notes: [0x9B, 49, 1, 0x0B, 0, 0x80]), format: .xm)
    #expect(abs(short.knownLength! - 0.12) < 0.001)
    #expect(short.loopCount == 0)
    _ = stereo(short, seconds: 0.5)
    #expect(short.loopCount == 4)
    #expect(!short.hasEnded)

    // A speed of nothing stops the song.
    let stopping = try TuneLoader.load(xm(notes: [0x9B, 49, 1, 0x0F, 0, 0x80]), format: .xm)
    _ = stereo(stopping, seconds: 0.2)
    #expect(stopping.hasEnded)
}

@Test func xmOfAnyNumberOfChannelsIsPlayed() throws {
    // FastTracker reads an even number up to 32; other trackers write what they like.
    #expect(try TuneLoader.load(xm(channels: 3), format: .xm).info.detail == "FastTracker 2, 3 channels")
    #expect(try TuneLoader.load(xm(channels: 64), format: .xm).knownLength != nil)
    #expect(throws: TuneError.self) { try TuneLoader.load(xm(channels: 200), format: .xm) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(xm().prefix(300)), format: .xm) }
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x41, count: 4000), format: .xm) }
}

/// A MOD file of six channels: a PC tracker's, with one sample and one note.
/// - Parameter second: whether its second channel has a note too, an octave above the first's.
private func sixChannelMOD(second: Bool = false) -> [UInt8] {
    var file = padded("six channels", 20)
    for sample in 0 ..< 31 {
        var header = [UInt8](repeating: 0, count: 30)
        if sample == 0 {
            header[22 ... 23] = [0, 16]
            header[25] = 64
            header[26 ... 29] = [0, 0, 0, 16]
        } else {
            header[29] = 1
        }
        file += header
    }
    file += [1, 0] + [UInt8](repeating: 0, count: 128) + Array("6CHN".utf8)
    var pattern = [UInt8](repeating: 0, count: 64 * 6 * 4)
    pattern.replaceSubrange(0 ..< 4, with: [0x01, 0xAC, 0x10, 0x00]) // period 428, sample 1
    if second { pattern.replaceSubrange(4 ..< 8, with: [0x00, 0xD6, 0x10, 0x00]) } // period 214
    return file + pattern + [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16)
}

@Test func modOfMoreThanFourChannelsGoesToFastTracker() throws {
    let renderer = try TuneLoader.load(sixChannelMOD(), format: .mod)
    #expect(renderer.info.format == "MOD")
    #expect(renderer.info.title == "six channels")
    #expect(renderer.info.detail == "FastTracker 2, 6 channels")
    #expect(abs(renderer.knownLength! - 7.68) < 0.001)
    let sound = stereo(renderer, seconds: 1)
    // Period 428 is the same C: 8287 bytes a second here, 32 to the wave, 259 Hz.
    #expect(abs(crossings(sound.left[4800...]) * 10 / 9 - 259) <= 2)
}

@Test func xmPatternIsUnpackedWhereItLiesAsFastTrackerDoes() throws {
    // One row of two channels: nothing in the first, and in the second a note written out in full
    // behind a byte that says all of it follows, which is six bytes for a note of five. FastTracker
    // unpacks a pattern in the memory it was read into, and here the first note, unpacked, lands on
    // top of the second before that has been read: so there is no second note, and the row is silent.
    var options = LoadOptions()
    options.stereo = .abc
    let overrun = try TuneLoader.load(xm(pattern: (1, [0x80, 0x9F, 49, 1, 0, 0, 0])), format: .xm, options: options)
    #expect(stereo(overrun, seconds: 0.5).left.map(abs).max()! < 0.0001)
    // The same note packed down to the three bytes it needs is left alone, and sounds.
    let packed = try TuneLoader.load(xm(pattern: (1, [0x80, 0x83, 49, 1])), format: .xm, options: options)
    #expect(stereo(packed, seconds: 0.5).left.map(abs).max()! > 0.05)
}

@Test func xmEnvelopeThatLoopsToAPointItHasNotGotIsPlayed() throws {
    // A volume envelope of two points that loops back to its twenty-first. FastTracker reads whatever
    // is in its memory there, which is the instrument's other settings; the tune must play all the same.
    let settings: [Int: UInt8] = [233: 1 | 4, 225: 2, 228: 20, 229: 0, 129 + 2: 64, 129 + 4: 1, 129 + 6: 32]
    let renderer = try TuneLoader.load(xm(settings: settings), format: .xm)
    let sound = stereo(renderer, seconds: 2)
    #expect(sound.left.allSatisfy { $0.isFinite })
    #expect(renderer.knownLength != nil)
    // And an envelope that says it has more points than there is room for.
    _ = stereo(try TuneLoader.load(xm(settings: [233: 1, 225: 200]), format: .xm), seconds: 1)
    _ = stereo(try TuneLoader.load(xm(notes: [0x9B, 49, 1, 21, 200, 0x80], settings: [233: 3, 225: 255]), format: .xm), seconds: 1)
}

@Test func xmWithMoreThanOneSongHasThemAll() throws {
    // A pattern of 32 rows that stops the song on its last, twice in the list: the second time is
    // never reached from the first, and is a song of its own.
    let rows: [UInt8] = [0x83, 49, 1, 0x80] + [UInt8](repeating: 0x80, count: 30 * 2) + [0x98, 0x0F, 0, 0x80]
    var file = xm(pattern: (32, rows))
    #expect(try TuneLoader.load(file, format: .xm).subsongCount == 1)
    file[64] = 2 // the list is two long
    let renderer = try TuneLoader.load(file, format: .xm)
    #expect(renderer.subsongCount == 2)
    #expect(abs(renderer.songs[1].length! - renderer.songs[0].length!) < 0.001)
    renderer.select(subsong: 1)
    #expect(renderer.currentSubsong == 1)
    let sound = stereo(renderer, seconds: 5).left
    #expect(abs(crossings(sound[4800 ..< 48000]) * 10 / 9 - 261) <= 2)
    #expect(renderer.hasEnded)
}

// MARK: What is not played as the file asks

@Test func xmSampleInStereoIsPlayedWithItsSidesApart() throws {
    // The square wave made twice as long and said to be in stereo: its left side is then the
    // wave's first half, which is high, and its right the second, which is low. Played as the
    // trackers that make such samples play them, the left side is heard on the left and the right
    // on the right, and in mono the two together are silence; played as FastTracker would, one
    // after the other, they are the square wave still.
    var file = xm()
    file[file.count - 32 - 40 + 14] |= 0x20
    // (Each side is stored as differences of its own, so the right side begins at -128 and stays.)
    file[file.count - 16] = 0x80
    var options = LoadOptions()
    options.stereo = .abc
    let apart = stereo(try TuneLoader.load(file, format: .xm, options: options), seconds: 0.5)
    #expect(apart.left[4800...].allSatisfy { $0 > 0.05 } && apart.right[4800...].allSatisfy { $0 < -0.05 })
    // (And it goes on for as long as it is held, and not for a tick only.)
    #expect(apart.left[20000] > 0.05)
    // At the far left, its right side is not heard at all.
    var leftmost = file
    leftmost[leftmost.count - 32 - 40 + 15] = 0
    let left = stereo(try TuneLoader.load(leftmost, format: .xm, options: options), seconds: 0.5)
    #expect(left.left[4800...].allSatisfy { $0 > 0.05 } && left.right[4800...].map(abs).max()! < 0.001)
    let renderer = try #require(try TuneLoader.load(file, format: .xm) as? XMRenderer)
    let heard = stereo(renderer, seconds: 0.5)
    #expect(heard.left[4800...].map(abs).max()! < 0.001)
    let asFastTracker = renderer.renderRaw(frames: 24000)
    #expect(asFastTracker.map { abs(Int($0)) }.max()! > 1000)
    // And afterwards it is played as before.
    #expect(stereo(renderer, seconds: 0.5).left[4800...].map(abs).max()! < 0.001)

    // Sixteen bits to a sample: two samples to a side, and the same again.
    var wide = xm()
    wide[wide.count - 32 - 40 + 14] |= 0x30
    wide.removeLast(32)
    wide += word(20000) + word(0) + word(0) + word(0) + [UInt8](repeating: 0, count: 8) + word(-20000 & 0xFFFF) + [UInt8](repeating: 0, count: 14)
    #expect(stereo(try TuneLoader.load(wide, format: .xm), seconds: 0.5).left[4800...].map(abs).max()! < 0.001)
}

/// A file as FastTracker 2 itself would write it: it says so, and its name is padded with spaces.
private func byFastTracker(_ file: [UInt8]) -> [UInt8] {
    var file = file
    file.replaceSubrange(17 ..< 37, with: Array("a square wave       ".utf8))
    file.replaceSubrange(38 ..< 58, with: Array("FastTracker v2.00   ".utf8))
    return file
}

@Test func xmOfOtherTrackersHasTheirArpeggio() throws {
    /// How many times the note crosses nought on the row's second tick (a tick is 960 samples).
    func secondTick(_ tracker: String?) throws -> Int {
        // C-4 with an arpeggio of an octave and nothing.
        var file = xm(notes: [0x93, 49, 1, 0xC0, 0x80])
        if let tracker { file.replaceSubrange(38 ..< 58, with: padded(tracker, 20)) } else { file = byFastTracker(file) }
        let left = stereo(try TuneLoader.load(file, format: .xm), seconds: 0.1).left
        return crossings(left[1060 ..< 1920])
    }
    // FastTracker 2 counts a row's ticks down, and at six to the row plays the octave on the third.
    #expect(try secondTick(nil) <= 5)
    // ModPlug Tracker, which says it is FastTracker but leaves its marks, did as the others did.
    #expect(try secondTick("FastTracker v2.00   ") >= 8)
    // MadTracker 2, as the other trackers, counts them up: the octave is on the second.
    #expect(try secondTick("MadTracker 2.0") >= 8)
    #expect(try secondTick("Skale Tracker") >= 8)
    // And so does OpenMPT in a file of a version that had not yet FastTracker's, but not after it.
    #expect(try secondTick("OpenMPT 1.17.02.48") >= 8)
    #expect(try secondTick("OpenMPT 1.28.00.00") <= 5)
}

@Test func xmOfModPlugTrackersHasItsSamplesFinetuneHeardWhole() throws {
    /// The sound of a file with its sample's finetune set, by FastTracker or by ModPlug Tracker.
    func sound(_ fine: Int8, byFastTracker own: Bool) throws -> [Float] {
        var file = xm()
        file[file.count - 32 - 40 + 13] = UInt8(bitPattern: fine)
        if own { file = byFastTracker(file) } else { file.replaceSubrange(38 ..< 58, with: Array("FastTracker v2.00   ".utf8)) }
        return stereo(try TuneLoader.load(file, format: .xm), seconds: 4).left
    }
    // FastTracker drops a finetune's lowest three bits: -28 is heard as -32.
    #expect(try sound(-28, byFastTracker: true) == sound(-32, byFastTracker: true))
    // ModPlug Tracker did not, nor does OpenMPT in its files: -28 is a little higher than -32.
    let whole = try sound(-28, byFastTracker: false), dropped = try sound(-32, byFastTracker: false)
    #expect(whole != dropped)
    #expect(crossings(whole[4800...]) >= crossings(dropped[4800...]))
}

@Test func xmOfModPlugTrackersHasItsXCommandsPlayed() throws {
    /// A file as ModPlug Tracker wrote one, with a command on the first row's note; its sample a ramp
    /// from the bottom to the top, round and round.
    func modPlug(_ command: UInt8, _ value: UInt8) -> [UInt8] {
        var file = xm(notes: [0x9B, 49, 1, command, value, 0x80])
        file.replaceSubrange(38 ..< 58, with: Array("FastTracker v2.00   ".utf8))
        file.replaceSubrange(file.count - 32 ..< file.count, with: [0x80] + [UInt8](repeating: 8, count: 31))
        return file
    }
    /// How much more of the note rises from one sample to the next than falls.
    func rising(_ file: [UInt8]) throws -> Int {
        let left = stereo(try TuneLoader.load(file, format: .xm), seconds: 0.3).left[4800...]
        return zip(left, left.dropFirst()).reduce(0) { $0 + ($1.1 > $1.0 ? 1 : $1.1 < $1.0 ? -1 : 0) }
    }
    // The ramp rises, in steps, and falls at once at the end of each time round.
    #expect(try rising(modPlug(0, 0)) > 3000)
    // X9F plays it backwards, round and round, so that it falls.
    #expect(try rising(modPlug(33, 0x9F)) < -3000)
    // FastTracker 2's own file has no such command.
    var own = modPlug(33, 0x9F)
    own = byFastTracker(own)
    #expect(try rising(own) > 3000)

    // X91 puts the channel in surround: in the middle, and its right side turned over.
    var options = LoadOptions()
    options.stereo = .abc
    let surround = stereo(try TuneLoader.load(modPlug(33, 0x91), format: .xm, options: options), seconds: 0.3)
    #expect(zip(surround.left[4800...], surround.right[4800...]).allSatisfy { abs($0 + $1) < 0.0001 })
    #expect(surround.left[4800...].map(abs).max()! > 0.01)
    // In mono that would be nothing at all, so there it is not turned over.
    let mono = stereo(try TuneLoader.load(modPlug(33, 0x91), format: .xm), seconds: 0.3)
    #expect(mono.left[4800...].map(abs).max()! > 0.01)

    // X6x makes the row longer by so many ticks: here fifteen, of 960 samples each.
    let plain = try TuneLoader.load(modPlug(0, 0), format: .xm).knownLength!
    #expect(abs(try TuneLoader.load(modPlug(33, 0x6F), format: .xm).knownLength! - plain - 0.3) < 0.001)
}

@Test func xmFromALaterTrackerSweepsFromSideToSide() throws {
    var options = LoadOptions()
    options.stereo = .abc
    /// How loud each side is over the ticks of the first row after the first, and after the row.
    func sides(_ file: [UInt8]) throws -> (during: (left: Float, right: Float), after: (left: Float, right: Float)) {
        let sound = stereo(try TuneLoader.load(file, format: .xm, options: options), seconds: 0.5)
        func peak(_ side: [Float], _ range: Range<Int>) -> Float { side[range].map(abs).max()! }
        return ((peak(sound.left, 1500 ..< 5500), peak(sound.right, 1500 ..< 5500)), (peak(sound.left, 12000 ..< 24000), peak(sound.right, 12000 ..< 24000)))
    }
    // Y8F on the note's row: the wave begins by going to the right, as far as there is.
    let swept = xm(notes: [0x9B, 49, 1, 34, 0x8F, 0x80])
    let heard = try sides(swept)
    #expect(heard.during.right > heard.during.left * 3)
    // After the row the note is in the middle again.
    #expect(abs(heard.after.right - heard.after.left) < heard.after.left * 0.02)
    // In a file of FastTracker's own the letter is nothing, as it is to FastTracker.
    let itsOwn = try sides(byFastTracker(swept))
    #expect(abs(itsOwn.during.right - itsOwn.during.left) < itsOwn.during.left * 0.02)
    #expect(try TuneLoader.load(byFastTracker(swept), format: .xm).info.shortfalls.isEmpty)
    // And so it is in the other when that is played as the player this is ported from plays it.
    let renderer = try #require(try TuneLoader.load(swept, format: .xm, options: options) as? XMRenderer)
    let raw = renderer.renderRaw(frames: 5500)
    let left = stride(from: 3000, to: raw.count, by: 2).map { abs(Int(raw[$0])) }.max()!
    let right = stride(from: 3001, to: raw.count, by: 2).map { abs(Int(raw[$0])) }.max()!
    #expect(left > 100 && abs(left - right) < left / 50)
}

@Test func xmFromALaterTrackerHasItsFilterPlayed() throws {
    func loudness(_ samples: ArraySlice<Float>) -> Float { (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot() }
    func heard(_ file: [UInt8]) throws -> [Float] { stereo(try TuneLoader.load(file, format: .xm), seconds: 1).left }
    let open = try heard(xm())
    // Z20 on the note's row closes the filter to some 330 Hz, a little above the note: the square
    // wave's harmonics go, and it is a good deal quieter, though still there and at its pitch.
    let closed = try heard(xm(notes: [0x9B, 49, 1, 35, 0x20, 0x80]))
    #expect(abs(crossings(closed[9600...]) * 10 / 8 - 261) <= 3)
    #expect(loudness(closed[9600...]) < loudness(open[9600...]) * 0.8)
    #expect(loudness(closed[9600...]) > loudness(open[9600...]) * 0.3)
    // The command after it brings the filter there a little at a time, over the six ticks of the
    // row: the note begins brighter than with Z, and ends the same.
    let slid = try heard(xm(notes: [0x9B, 49, 1, 36, 0x20, 0x80]))
    #expect(loudness(slid[200 ..< 900]) > loudness(closed[200 ..< 900]) * 1.2)
    #expect(abs(loudness(slid[9600...]) - loudness(closed[9600...])) < loudness(closed[9600...]) * 0.05)
    // A note begun later on the channel has the filter still: it belongs to the channel. (Here,
    // on the second row, with no command of its own.)
    var rows: [UInt8] = [0x9B, 49, 1, 35, 0x20, 0x80, 0x83, 49, 1, 0x80] + [UInt8](repeating: 0x80, count: 62 * 2)
    let again = try heard(xm(pattern: (64, rows)))
    #expect(loudness(again[9600...]) < loudness(open[9600...]) * 0.8)
    // But one begun with the filter fully open has none, though the channel's was on before.
    rows = [0x9B, 49, 1, 35, 0x7F, 0x80, 0x83, 49, 1, 0x80] + [UInt8](repeating: 0x80, count: 62 * 2)
    let opened = try heard(xm(pattern: (64, rows)))
    #expect(abs(loudness(opened[9600...]) - loudness(open[9600...])) < loudness(open[9600...]) * 0.02)
    // In a file of FastTracker's own the letter is nothing, and so it is when the other file is
    // played as the player this is ported from plays it.
    let itsOwn = try heard(byFastTracker(xm(notes: [0x9B, 49, 1, 35, 0x20, 0x80])))
    #expect(abs(loudness(itsOwn[9600...]) - loudness(open[9600...])) < loudness(open[9600...]) * 0.02)
    func raw(_ file: [UInt8]) throws -> [Int16] { try #require(try TuneLoader.load(file, format: .xm) as? XMRenderer).renderRaw(frames: 9600) }
    #expect(try raw(xm(notes: [0x9B, 49, 1, 35, 0x20, 0x80])) == raw(xm()))
}

@Test func xmFromALaterTrackerSaysWhatFastTrackerDoesNotPlay() throws {
    func shortfalls(_ file: [UInt8]) throws -> [String] { try TuneLoader.load(file, format: .xm).info.shortfalls }
    #expect(try shortfalls(xm()).isEmpty)

    // A sample said to be in stereo, which is played so: nothing is missing.
    var stereo = xm()
    stereo[stereo.count - 32 - 40 + 14] |= 0x20
    #expect(try shortfalls(stereo).isEmpty)
    // One packed as ModPlug Tracker packed them.
    var packed = xm()
    packed[packed.count - 32 - 40 + 17] = 0xAD
    #expect(try shortfalls(packed).first?.hasPrefix("One of its samples is packed in a way of ModPlug Tracker's own") == true)

    // A command of ModPlug Tracker's: Z, which is its 35th, and sets a channel's filter unless
    // the file has macros of its own that say it does something else. The filter is played, and a
    // macro for anything else is not. In a file of FastTracker's own Z is a letter that means
    // nothing, and nothing is said of it.
    let withZ = xm(notes: [0x9B, 49, 1, 35, 0x40, 0x80])
    #expect(try shortfalls(withZ).isEmpty)
    func macros(_ first: String) -> [UInt8] {
        Array("MIDI".utf8) + long(4896) + [UInt8](repeating: 0, count: 9 * 32) + padded(first, 32) + [UInt8](repeating: 0, count: 143 * 32)
    }
    #expect(try shortfalls(withZ + macros("F0F000z")).isEmpty)
    #expect(try shortfalls(withZ + macros("F0F080z"))
        == ["One of its commands is left out, which FastTracker 2 did not have: the setting of a filter or a plug-in."])
    #expect(try shortfalls(byFastTracker(withZ)).isEmpty)

    // An instrument sent through a plug-in, which is written after all that FastTracker reads: it
    // has a sample, and that is heard; the plug-in, which is not one of OpenMPT's own, is not, and
    // that is said whether anything is sent through it or not, as for an IT file. Sent through a
    // place with no plug-in in it, it loses nothing more.
    func extras(plugIn: UInt8) -> [UInt8] {
        var bytes = Array("FX00".utf8) + long(128) + [1, 2, 3, 4] + [UInt8](repeating: 0, count: 124)
        bytes += Array("XTPM".utf8) + Array(".PiM".utf8) + word(1) + [plugIn]
        return bytes
    }
    #expect(try shortfalls(xm() + extras(plugIn: 1)) == ["Its plug-in is left out, and it is heard without what that does to its sound."])
    #expect(try shortfalls(xm() + extras(plugIn: 2)) == ["Its plug-in is left out, and it is heard without what that does to its sound."])

    // And a file that ends before its sample does.
    #expect(try shortfalls(Array(xm().dropLast(32))) == ["The file is cut short: one of its samples is missing, and is silent."])
    #expect(try shortfalls(Array(xm().dropLast(1))).isEmpty)
}

@Test func xmOfOpenMPTsLetsASampleThatEndsLoudDieAway() throws {
    // The square wave played once, and not round its loop, ends at its lowest. FastTracker's mixer
    // stops it dead there; OpenMPT's lets what it last put out die away, by a 256th a frame.
    func played(madeWith tracker: String) throws -> [Float] {
        var file = xm()
        file.replaceSubrange(38 ..< 58, with: padded(tracker, 20))
        file[file.count - 32 - 40 + 14] = 0 // the sample's loop: none
        return stereo(try TuneLoader.load(file, format: .xm), seconds: 0.1).left
    }
    let stopped = try played(madeWith: "siday"), dying = try played(madeWith: "OpenMPT 1.30.00.00")
    let end = try #require(stopped.lastIndex { $0 != 0 }) + 1
    #expect(end > 100 && end < 1000)
    #expect(stopped[end...].allSatisfy { $0 == 0 })
    // (The two are read between the sample's points each in its own tracker's way, and end at
    // the same frame, at levels a little apart.)
    let last = dying[end - 1]
    #expect(stopped[end - 1] < 0 && last < stopped[end - 1] * 0.9)
    #expect(abs(dying[end] - last * 255 / 256) < abs(last) * 0.01)
    #expect(abs(dying[end + 255] - last * 0.368) < abs(last) * 0.02)
    #expect(abs(dying[end + 2000]) < abs(last) * 0.001)
}

@Test func xmOfOpenMPTsIsReadBetweenItsSamplesPointsAsOpenMPTReadsIt() throws {
    func played(madeWith tracker: String, way: UInt8? = nil) throws -> ArraySlice<Float> {
        var file = xm()
        file.replaceSubrange(38 ..< 58, with: padded(tracker, 20))
        if let way { file += Array("XTPM".utf8) + Array("...R".utf8) + word(1) + [way] }
        return stereo(try TuneLoader.load(file, format: .xm), seconds: 0.2).left[4800...]
    }
    // FastTracker's line from one point to the next never goes past the square wave's top; OpenMPT's
    // sinc, which its file has unless an instrument asks for another way, rings past it at the
    // edges; and an instrument that asks for no smoothing at all is heard at two levels, the wave's own.
    let line = try played(madeWith: "siday"), sinc = try played(madeWith: "OpenMPT 1.30.00.00")
    let top = line.map(abs).max()!
    #expect(sinc.map(abs).max()! > top * 1.05)
    #expect(Set(try played(madeWith: "OpenMPT 1.30.00.00", way: 0)).count == 2)
    #expect(try played(madeWith: "OpenMPT 1.30.00.00", way: 1).map(abs).max()! <= top * 1.001)
}

@Test func xmInstrumentIsHeardThroughItsPlugIn() throws {
    // OpenMPT's echo, set to give back what it is given a thousandth of a second later (48 frames)
    // and nothing else, in the first place, and the instrument sent through it.
    var piece = long(0x4458_4D4F) + long(0xEF3E_932C) + [0, 0, 0, 0] + long(0) + [UInt8](repeating: 0, count: 16)
    piece += [UInt8](repeating: 0, count: 32) + Array("Echo".utf8) + [UInt8](repeating: 0, count: 60)
    let settings = long(0) + [Float(1), 0, 0, 0, 0].flatMap { long(Int($0.bitPattern)) }
    piece += long(settings.count) + settings + long(0)
    let file = xm() + Array("FX00".utf8) + long(piece.count) + piece + Array("XTPM".utf8) + Array(".PiM".utf8) + word(1) + [1]
    var options = LoadOptions()
    options.stereo = .abc
    let echoed = try TuneLoader.load(file, format: .xm, options: options)
    #expect(echoed.info.shortfalls.isEmpty)
    let wet = stereo(echoed, seconds: 0.5).left
    let dry = stereo(try TuneLoader.load(xm(), format: .xm, options: options), seconds: 0.5).left
    // What is heard is the instrument 48 frames late, but for the last place or so of its numbers.
    #expect(wet[..<40].allSatisfy { abs($0) < 0.0001 })
    #expect(dry.map(abs).max()! > 0.05)
    #expect((1000 ..< 20000).allSatisfy { abs(wet[$0 + 48] - dry[$0]) < 0.001 })
}

/// How loud a player says each of its voices has been since it was last asked.
private func levels(_ renderer: any Renderer) -> [Float] {
    var levels = [Float](repeating: 0, count: renderer.channelCount)
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    return levels
}

@Test func xmChannelLeftOutIsNotHeardAndPlaysOn() throws {
    // C-4 on the first channel, put hard left by its command, and the C above on the second, put
    // as far right as FastTracker goes; and the same tune with the first of them alone.
    var options = LoadOptions()
    options.stereo = .abc
    func fresh(_ notes: [UInt8]) throws -> any Renderer { try TuneLoader.load(xm(notes: notes), format: .xm, options: options) }
    let both: [UInt8] = [0x9B, 49, 1, 8, 0x00, 0x9B, 61, 1, 8, 0xFF], first: [UInt8] = [0x9B, 49, 1, 8, 0x00, 0x80]
    let whole = try fresh(both)
    let wholeSound = stereo(whole, seconds: 0.5), wholeLevels = levels(whole)
    #expect(wholeSound.left.map(abs).max()! > 0.05 && wholeSound.right.map(abs).max()! > 0.05)
    #expect(wholeLevels[0] > 0.2 && wholeLevels[1] > 0.2)

    // The second channel left out: what is heard is the tune without its note, to the sample (the
    // mixing is in whole numbers), and the channel is still said to be as loud as it was.
    let alone = stereo(try fresh(first), seconds: 0.5)
    let renderer = try fresh(both)
    renderer.setMuted([false, true])
    let without = stereo(renderer, seconds: 0.5)
    #expect(without == alone && without.left != wholeSound.left)
    #expect(without.right.allSatisfy { $0 == 0 })
    #expect(levels(renderer) == wholeLevels)

    // A song started again is started without the channel; and with it brought back, as it ever was.
    renderer.select(subsong: 0)
    #expect(stereo(renderer, seconds: 0.5) == without)
    renderer.setMuted([])
    renderer.select(subsong: 0)
    #expect(stereo(renderer, seconds: 0.5) == wholeSound)

    // Every channel left out is silence, and each is as loud as ever by its own account.
    renderer.setMuted([true, true])
    renderer.select(subsong: 0)
    #expect(stereo(renderer, seconds: 0.5).left.allSatisfy { $0 == 0 })
    #expect(levels(renderer) == wholeLevels)

    // A note cut short by the next dies away on a voice of its own, which is its channel's too:
    // with the channel left out there is nothing of either.
    let cut: [UInt8] = [0x83, 49, 1, 0x80, 0x83, 61, 1, 0x80] + [UInt8](repeating: 0x80, count: 62 * 2)
    let twice = try TuneLoader.load(xm(pattern: (64, cut)), format: .xm, options: options)
    twice.setMuted([true])
    #expect(stereo(twice, seconds: 0.5).left.allSatisfy { $0 == 0 })
}

@Test func modOfMoreThanFourChannelsHasItsChannelsLeftOut() throws {
    // The second channel of the six left out: the tune without its note.
    let whole = try TuneLoader.load(sixChannelMOD(second: true), format: .mod)
    let wholeSound = stereo(whole, seconds: 0.5), wholeLevels = levels(whole)
    let alone = stereo(try TuneLoader.load(sixChannelMOD(), format: .mod), seconds: 0.5)
    let renderer = try TuneLoader.load(sixChannelMOD(second: true), format: .mod)
    renderer.setMuted([false, true])
    let without = stereo(renderer, seconds: 0.5)
    #expect(without == alone && without != wholeSound)
    #expect(levels(renderer) == wholeLevels && wholeLevels[1] > 0.2)
    renderer.setMuted([true, true, true, true, true, true])
    renderer.select(subsong: 0)
    #expect(stereo(renderer, seconds: 0.5).left.allSatisfy { $0 == 0 })
}

@Test func xmFromOpenMPTIsAsLoudAsItsPreAmpMakesIt() throws {
    // A song's own extras, as OpenMPT and ModPlug Tracker put them at a file's end: which way of
    // adding the channels up, and the pre-amp. The pre-amp is followed, against OpenMPT's usual
    // 48; the way is not, so that such files are about as loud as all the others.
    func extras(mixLevels: Int, preAmp: Int?) -> [UInt8] {
        var bytes = Array("STPM".utf8) + Array(".MMP".utf8) + word(4) + long(mixLevels)
        if let preAmp { bytes += Array(".APS".utf8) + word(4) + long(preAmp) }
        return bytes
    }
    func loud(_ file: [UInt8]) throws -> Float {
        let left = stereo(try TuneLoader.load(file, format: .xm), seconds: 0.5).left[4800...]
        return (left.reduce(0) { $0 + $1 * $1 } / Float(left.count)).squareRoot()
    }
    // (Such a file is read between its samples' points as OpenMPT reads it, and FastTracker's own
    // through its line from one to the next, which the square wave is a little louder through.)
    let own = try loud(xm()), usual = try loud(xm() + extras(mixLevels: 5, preAmp: nil))
    #expect(own > 0.01)
    #expect(abs(usual / own - 1) < 0.05, "\(usual / own)")
    for mode in [0, 4, 5] {
        #expect(abs(try loud(xm() + extras(mixLevels: mode, preAmp: nil)) / usual - 1) < 0.01)
        #expect(abs(try loud(xm() + extras(mixLevels: mode, preAmp: 96)) / usual - 2) < 0.02)
    }
    // In OpenMPT 1.17's ways the usual pre-amp is 128.
    #expect(abs(try loud(xm() + extras(mixLevels: 3, preAmp: 128)) / usual - 1) < 0.01)
}

@Test func xmChannelPutInTheReverbIsHeardInItInALaterTrackersFile() throws {
    // A note cut on its third row, with X99 beside it: in a file of ModPlug Tracker's the reverb
    // goes on after it; without X99, or in a file of FastTracker's own, there is nothing then.
    func file(_ effect: [UInt8]) -> [UInt8] {
        let rows = [0x83 | (effect.isEmpty ? 0 : 0x18), 49, 1] + effect + [0x80] + [0x80, 0x80] + [0x81, 97, 0x80] + [UInt8](repeating: 0x80, count: 61 * 2)
        var file = xm(pattern: (64, rows))
        file.replaceSubrange(38 ..< 58, with: Array("FastTracker v2.00   ".utf8))
        return file
    }
    func tail(_ file: [UInt8]) throws -> Float {
        let sound = stereo(try TuneLoader.load(file, format: .xm), seconds: 1.5)
        let part = sound.left[24000 ..< 48000] + sound.right[24000 ..< 48000]
        return (part.reduce(0) { $0 + $1 * $1 } / Float(part.count)).squareRoot()
    }
    let wet = try tail(file([33, 0x99])), dry = try tail(file([])), off = try tail(file([33, 0x98])), own = try tail(byFastTracker(file([33, 0x99])))
    #expect(wet > 0.001 && dry < 0.0001 && off < 0.0001 && own < 0.0001)
}

@Test func xmPlugInHearsTheVoicesAsLoudAsOpenMPTsWayOfAddingUpHasThem() throws {
    // OpenMPT's distortion, at its most, on the square wave's instrument, in files of OpenMPT's
    // that add up in one or another of its ways. How much louder the distorted wave is than the
    // wave without it is what libopenmpt makes it (measured beside it): the voices go to the
    // plug-in as loud as each way has them, and what it makes comes back as much quieter.
    var piece = long(0x4458_4D4F) + long(0xEF11_4C90) + [0, 0, 0, 0] + long(0) + [UInt8](repeating: 0, count: 16)
    piece += [UInt8](repeating: 0, count: 32) + Array("Distortion".utf8) + [UInt8](repeating: 0, count: 54)
    let settings = long(0) + [Float(1), 1, 1, 0.284, 0.663].flatMap { long(Int($0.bitPattern)) }
    piece += long(settings.count) + settings + long(0)
    func file(way: UInt8, distorted: Bool) -> [UInt8] {
        var file = xm(channels: 8, notes: [0x87, 49, 1, 0x50] + [UInt8](repeating: 0x80, count: 7))
        file.replaceSubrange(38 ..< 58, with: padded("OpenMPT 1.30.00.00", 20))
        if distorted { file += Array("FX00".utf8) + long(piece.count) + piece + Array("XTPM".utf8) + Array(".PiM".utf8) + word(1) + [1] }
        file += Array("STPM".utf8) + Array(".MMP".utf8) + word(1) + [way] + Array(".APS".utf8) + word(4) + long(48)
        return file + Array("...C".utf8) + word(4) + long(8)
    }
    func louder(way: UInt8) throws -> Float {
        func loudness(_ distorted: Bool) throws -> Float {
            let left = stereo(try TuneLoader.load(file(way: way, distorted: distorted), format: .xm), seconds: 0.8).left[9600...]
            return (left.reduce(0) { $0 + $1 * $1 } / Float(left.count)).squareRoot()
        }
        return 20 * log10(try loudness(true) / loudness(false))
    }
    // The third way of OpenMPT 1.17 has the voices twice as loud as the compatible way, and ModPlug
    // Tracker's own way and the first of 1.17 give a plug-in a half and a sixteenth of them.
    #expect(abs(try louder(way: 4) - louder(way: 3) - 5.74) < 0.1)
    #expect(abs(try louder(way: 1) - louder(way: 0) - 1.82) < 0.1)
    #expect(abs(try louder(way: 5) - louder(way: 4) + 2.86) < 0.1)
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

@Test func xmChannelsHaveScopes() throws {
    // C-4 at full volume on the first channel, in the middle; the C above at a quarter of that on
    // the second; and nothing on the third.
    let file = xm(channels: 3, notes: [0x83, 49, 1, 0x87, 61, 1, 0x20, 0x80])
    let heard = try scopes(file, format: .xm)
    #expect(heard.same)
    for scopes in [heard.now, heard.again] {
        #expect(height(scopes[0]) > 115)
        // (A quarter of the swing is half the height.)
        #expect(height(scopes[1]) > 50 && height(scopes[1]) < 80)
        #expect(scopes[2].allSatisfy { $0 == 128 })
    }
    // A channel left out is still seen to play, and one to a side is as tall as one in the middle.
    let without = try scopes(file, format: .xm, muted: [true])
    #expect(without.same && height(without.now[0]) > 115 && height(without.again[0]) > 115)
    let aside = try scopes(xm(pan: 0), format: .xm)
    #expect(aside.same && height(aside.now[0]) > 115)
    // And what is made to be set beside the player this is ported from is made as it was, with the
    // scopes kept on afterwards.
    let kept = try #require(try TuneLoader.load(file, format: .xm) as? XMRenderer)
    let waves = try #require(kept.keepChannelWaves())
    #expect(kept.renderRaw(frames: 12000) == (try #require(try TuneLoader.load(file, format: .xm) as? XMRenderer)).renderRaw(frames: 12000))
    var buffer = [Float](repeating: 0, count: 12000 * 2), scope = [UInt8](repeating: 0, count: ChannelWaves.points)
    buffer.withUnsafeMutableBufferPointer { kept.render(into: $0.baseAddress!, frames: 12000) }
    scope.withUnsafeMutableBufferPointer { waves.take(0, pitch: 0, periodic: false, behind: 0, into: $0.baseAddress!) }
    #expect(height(scope[...]) > 115)
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

@Test func xmLightIsOfWhatIsHeard() throws {
    // A note of a sample that does not go round, and ends at nought, a fraction of the way into
    // its first tick: the light is lit for what gives out its sound, and for nothing after.
    var file = xm()
    file[file.count - 32 - 22 - 4] = 0
    file[file.count - 2] = 0x80
    let calls = try heardAndLit(file, format: .xm, calls: 12, frames: 50)
    #expect(calls.contains { $0.heard } && calls.contains { !$0.heard })
    #expect(calls.allSatisfy { $0.heard == $0.lit })
    // And a note that is let go dies away at the start of its tick, and its light with it.
    let letGo: [UInt8] = [0x83, 49, 1, 0x80] + [0x81, 97, 0x80] + [UInt8](repeating: 0x80, count: 62 * 2)
    let whole = try heardAndLit(xm(pattern: (64, letGo)), format: .xm, calls: 80)
    #expect(whole.contains { !$0.heard } && whole.allSatisfy { $0.heard == $0.lit })
}
