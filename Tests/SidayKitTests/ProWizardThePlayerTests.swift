// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Checks of the unpacking of modules packed by The Player 4.x, 5.0a, 6.0a and 6.1a. Each packed file
// here is made up, laid out as ProWizard reads one, with a pattern or two of a few notes and effects,
// and the ProTracker module it should unpack to is set out beside it. The thorough check is made
// outside the package, against ProWizard itself on every such file in the collection.

private func be16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
private func be32(_ value: Int) -> [UInt8] { be16(value >> 16) + be16(value) }

/// A sample's header in a ProTracker module.
private func header(words: Int, fine: UInt8, volume: UInt8, loopStart: Int, loopWords: Int) -> [UInt8] {
    [UInt8](repeating: 0, count: 22) + be16(words) + [fine, volume] + be16(loopStart) + be16(loopWords)
}

/// A ProTracker module, of the samples' headers given and the rest empty, the order, the patterns as
/// rows of four notes of four bytes, and the samples' data.
private func proTracker(_ headers: [[UInt8]], order: [Int], patterns: [[Int: [[UInt8]]]], samples: [UInt8]) -> [UInt8] {
    var module = [UInt8](repeating: 0, count: 20)
    for headerBytes in headers { module += headerBytes }
    for _ in headers.count ..< 31 { module += header(words: 0, fine: 0, volume: 0, loopStart: 0, loopWords: 1) }
    module += [UInt8(order.count), 0x7F] + order.map { UInt8($0) } + [UInt8](repeating: 0, count: 128 - order.count)
    module += Array("M.K.".utf8)
    for pattern in patterns {
        for row in 0 ..< 64 {
            let notes = pattern[row] ?? [[], [], [], []]
            for channel in 0 ..< 4 { module += notes[channel].isEmpty ? [0, 0, 0, 0] : notes[channel] }
        }
    }
    return module + samples
}

/// The rows of a pattern with notes in one channel only.
private func rows(_ channel: Int, _ notes: [Int: [UInt8]]) -> [Int: [[UInt8]]] {
    notes.mapValues { note in (0 ..< 4).map { $0 == channel ? note : [] } }
}

/// A small generator of the same numbers every time.
private struct Numbers: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Unpacks the file cut short at every length, and with bytes changed at random, and with random
/// bytes after its first few: none may trap, and each either unpacks or does not.
private func neverTraps(_ file: [UInt8]) {
    for length in 0 ..< file.count { _ = ProWizard.unpack(Array(file.prefix(length))) }
    var numbers = Numbers(state: 0x9E37_79B9_7F4A_7C15)
    for _ in 0 ..< 2000 {
        var changed = file
        for _ in 0 ..< Int.random(in: 1 ... 6, using: &numbers) {
            changed[Int.random(in: 0 ..< changed.count, using: &numbers)] = UInt8.random(in: 0 ... 255, using: &numbers)
        }
        _ = ProWizard.unpack(changed)
    }
    for _ in 0 ..< 500 {
        let keep = Int.random(in: 0 ... min(8, file.count), using: &numbers)
        let random = (0 ..< Int.random(in: 0 ... 600, using: &numbers)).map { _ in UInt8.random(in: 0 ... 255, using: &numbers) }
        _ = ProWizard.unpack(Array(file.prefix(keep)) + random)
    }
}

// MARK: The Player 4.x

/// A module of The Player 4.0a: two samples, an order of two places, each with its tracks; the first
/// pattern's first channel and the second's last are the one track, which reads three of its rows
/// from elsewhere.
private let player4: (packed: [UInt8], module: [UInt8]) = {
    let trackData = 68, trackTable = 52, sampleData = 88
    var file = Array("P40A".utf8) + [2, 2, 2, 0] + be32(trackData - 4) + be32(trackTable - 4) + be32(sampleData - 4)
    // Where each sample and its loop start, from the start of the samples, its length and its loop's
    // in words, the finetune times 74, a nought and the volume.
    file += be32(0) + be16(4) + be32(4) + be16(2) + be16(3 * 74) + [0, 64]
    file += be32(8) + be16(2) + be32(8) + be16(1) + be16(-74) + [0, 32]
    // The tracks: an empty one, and one of a note, then one taken from 16 bytes into the tracks and
    // played twice more, then a change of speed and 59 rows empty.
    let empty = 0, track = 4
    file += [track, empty, empty, empty, empty, empty, empty, track].flatMap { be16($0) }
    file += [0x00, 0x00, 0x00, 63]
    file += [26, 0x1C, 0x20, 0x00] + [0x80, 0x00] + be16(16) + [0x00, 0x0F, 0x06, 59]
    file += [50, 0x2A, 0x82, 0xFE]
    precondition(file.count == sampleData)
    let samples: [UInt8] = [0, 40, 80, 120, 80, 40, 0, 0xD8, 0x7F, 0x81, 0x7F, 0x81]
    file += samples

    // A volume slide of 0x82 is turned into a slide up of 2.
    let tune: [Int: [UInt8]] = [0: [0x01, 0xAC, 0x1C, 0x20], 1: [0x00, 0xD6, 0x2A, 0x20], 2: [0x00, 0xD6, 0x2A, 0x20],
                                3: [0x00, 0xD6, 0x2A, 0x20], 4: [0x00, 0x00, 0x0F, 0x06]]
    let module = proTracker([header(words: 4, fine: 3, volume: 64, loopStart: 2, loopWords: 2),
                             header(words: 2, fine: 0xFF, volume: 32, loopStart: 0, loopWords: 1)],
                            order: [0, 1], patterns: [rows(0, tune), rows(3, tune)], samples: samples)
    return (file, module)
}()

@Test func thePlayer4IsFoundAndUnpacked() throws {
    #expect(ProWizard.packer(of: player4.packed) == .player4)
    let unpacked = try #require(ProWizard.unpack(player4.packed))
    #expect(unpacked.packer == "The Player 4.x")
    #expect(unpacked.module == player4.module)
    // 4.1a has its finetune after the volume.
    var later = player4.packed
    later.replaceSubrange(0 ..< 4, with: Array("P41A".utf8))
    later.replaceSubrange(32 ..< 36, with: [0, 64] + be16(3 * 74))
    later.replaceSubrange(48 ..< 52, with: [0, 32] + be16(-74))
    #expect(ProWizard.unpack(later)?.module == player4.module)
    // And the four letters are all the test looks at.
    var other = player4.packed
    other[3] = 0x43
    #expect(ProWizard.packer(of: other) != .player4)
}

@Test func thePlayer4LastSampleMayRunPastTheEnd() throws {
    // As a game's does: what there is of it is kept.
    let short = Array(player4.packed.dropLast(3))
    #expect(ProWizard.unpack(short)?.module == Array(player4.module.dropLast(3)))
    // But a sample said to start past the end is not.
    var far = player4.packed
    far.replaceSubrange(36 ..< 40, with: be32(200))
    #expect(ProWizard.unpack(far) == nil)
}

@Test func thePlayer4NeverTraps() {
    neverTraps(player4.packed)
}

// MARK: The Player 5.0a and 6.0a

/// A module of The Player 6.0a or 5.0a: two samples, the second the first again with a loop of its
/// own; two patterns, the first played twice. (5.0a counts its patterns in twos, so a pattern of an
/// odd number is what tells 6.0a's apart.) The first pattern's first channel has a note and an empty
/// row, a note with a volume slide, two rows read again from 11 bytes back, and a break on the
/// seventh row, which ends every channel there. Its third channel, and the second pattern's first,
/// have a note played three times.
private func player6(version: Int, delta: Bool) -> (packed: [UInt8], module: [UInt8]) {
    let samples = 2, patterns = 2
    let headers = 4 + samples * 6 + patterns * 8
    let order: [UInt8] = [0, 1, 0]
    let empty: [UInt8] = [0xFF, 0x00, 0x00, 0x3F]
    let first: [UInt8] = [0xFF - 26, 0x1C, 0x30, 0x01] + [50, 0x2A, 0xFE] + [0x80, 0x01, 0x00, 11] + [0x00, 0x0D, 0x00]
    let third: [UInt8] = [0xFF - 2, 0x10, 0x00, 0xFE] + empty
    let tracks = empty + first + third
    let sampleData = headers + order.count + 1 + tracks.count

    var file = be16(sampleData) + [UInt8(patterns), UInt8(samples | (delta ? 0x80 : 0))]
    // Each sample's length in words (or 0xFFFF less the number of the sample it is), finetune,
    // volume, and where its loop starts in words, 0xFFFF for none.
    file += be16(64) + [0, 64] + be16(0xFFFF)
    file += be16(0xFFFF) + [1, 32] + be16(2)
    let third0 = empty.count + first.count
    file += [empty.count, 0, third0, 0, third0, 0, 0, 0].flatMap { be16($0) }
    file += order.map { version >= 0x60 ? $0 : $0 * 2 } + [0xFF]
    file += tracks
    precondition(file.count == sampleData)
    // (The test asks for 128 bytes after the headers, so a file shorter than that is not taken.)
    let wave = (0 ..< 128).map { UInt8(truncatingIfNeeded: $0 * 37) }
    // Kept as differences, each byte as how much the one before it is above it.
    file += delta ? [wave[0]] + (1 ..< wave.count).map { wave[$0 - 1] &- wave[$0] } : wave

    var pattern = rows(0, [0: [0x01, 0xAC, 0x1C, 0x30], 2: [0x00, 0xD6, 0x2A, 0x20], 3: [0x01, 0xAC, 0x1C, 0x30],
                           5: [0x00, 0xD6, 0x2A, 0x20], 6: [0x00, 0x00, 0x0D, 0x00]])
    for row in 0 ..< 3 { pattern[row, default: [[], [], [], []]][2] = [0x03, 0x58, 0x10, 0x00] }
    let second = rows(0, [0: [0x03, 0x58, 0x10, 0x00], 1: [0x03, 0x58, 0x10, 0x00], 2: [0x03, 0x58, 0x10, 0x00]])
    let module = proTracker([header(words: 64, fine: 0, volume: 64, loopStart: 0, loopWords: 1),
                             header(words: 64, fine: 1, volume: 32, loopStart: 2, loopWords: 62)],
                            order: [0, 1, 0], patterns: [pattern, second], samples: wave + wave)
    return (file, module)
}

@Test func thePlayer6IsFoundAndUnpacked() throws {
    for delta in [false, true] {
        let tune = player6(version: 0x60, delta: delta)
        #expect(ProWizard.packer(of: tune.packed) == .player60)
        let unpacked = try #require(ProWizard.unpack(tune.packed))
        #expect(unpacked.packer == "The Player 6.0a")
        #expect(unpacked.module == tune.module)
    }
}

@Test func thePlayer5IsFoundAndUnpacked() throws {
    for delta in [false, true] {
        let tune = player6(version: 0x50, delta: delta)
        #expect(ProWizard.packer(of: tune.packed) == .player50)
        let unpacked = try #require(ProWizard.unpack(tune.packed))
        #expect(unpacked.packer == "The Player 5.0a")
        #expect(unpacked.module == tune.module)
    }
}

@Test func thePlayer6RefusesWhatItCannotUnpack() {
    // Samples packed by The Player itself.
    var packed = player6(version: 0x60, delta: false).packed
    packed[3] |= 0x40
    #expect(ProWizard.unpack(packed) == nil)
    // A last sample cut short: libxmp takes the file to be broken.
    #expect(ProWizard.unpack(Array(player6(version: 0x60, delta: false).packed.dropLast(1))) == nil)
    // And a sample of nothing, here the first said to be itself, which libxmp's reading takes as an
    // error too.
    packed = player6(version: 0x60, delta: false).packed
    packed.replaceSubrange(4 ..< 6, with: be16(0xFFFF))
    #expect(ProWizard.packer(of: packed) == .player60)
    #expect(ProWizard.unpack(packed) == nil)
    // A sample said to be another, that is not there.
    packed = player6(version: 0x60, delta: false).packed
    packed.replaceSubrange(10 ..< 12, with: be16(0xFFFF - 5))
    #expect(ProWizard.packer(of: packed) != .player60)
}

@Test func thePlayer6NeverTraps() {
    neverTraps(player6(version: 0x60, delta: true).packed)
    neverTraps(player6(version: 0x50, delta: false).packed)
}

// MARK: The Player 6.1a

/// A module of The Player 6.1a: two samples, one pattern played twice. The first channel has a
/// note, an empty row, a note with no effect played twice, an effect with no note, two rows read
/// again from 13 bytes back, five empty rows, and a break on the fourteenth row. The third channel
/// has a note with a volume slide played three times, which ProWizard works out again for each row.
private func player61(delta: Bool) -> (packed: [UInt8], module: [UInt8]) {
    let samples = 2, patterns = 1
    let headers = 4 + samples * 6 + patterns * 8
    let order: [UInt8] = [0, 0]
    let empty: [UInt8] = [0xFF, 0x3F]
    let first: [UInt8] = [0x9A, 0x1C, 0x40, 0x00] + [0x7F] + [0xF3, 0x22, 0x81] + [0x6A, 0xFE] + [0xFF, 0x41, 13] + [0xFF, 0x05]
        + [0x00, 0x0D, 0x00]
    let third: [UInt8] = [0x82, 0x1A, 0x83, 0x82] + empty
    let tracks = empty + first + third
    let sampleData = headers + order.count + 1 + tracks.count

    var file = be16(sampleData) + [UInt8(patterns), UInt8(samples | (delta ? 0x80 : 0))]
    file += be16(4) + [0, 64] + be16(0xFFFF)
    file += be16(2) + [2, 32] + be16(1)
    file += [empty.count, 0, empty.count + first.count, 0].flatMap { be16($0) }
    file += order + [0xFF]
    file += tracks
    precondition(file.count == sampleData)
    let wave: [UInt8] = [0, 40, 80, 120, 0x90, 0xD0, 0xF0, 0xFF, 7, 0x10, 0x20, 0x30]
    if delta {
        // Each sample is kept as differences from a running sum that leaves its first byte out.
        for start in [0, 8] {
            var sum: UInt8 = 0
            file.append(wave[start])
            for j in start + 1 ..< (start == 0 ? 8 : 12) {
                file.append(sum &- wave[j])
                sum = wave[j]
            }
        }
    } else {
        file += wave
    }

    var pattern = rows(0, [0: [0x01, 0xAC, 0x1C, 0x40], 2: [0x00, 0xD6, 0x20, 0x00], 3: [0x00, 0xD6, 0x20, 0x00],
                           4: [0x00, 0x00, 0x0A, 0x20], 5: [0x01, 0xAC, 0x1C, 0x40], 13: [0x00, 0x00, 0x0D, 0x00]])
    pattern[0, default: [[], [], [], []]][2] = [0x03, 0x58, 0x1A, 0xD0]
    pattern[1, default: [[], [], [], []]][2] = [0x03, 0x58, 0x1A, 0x00]
    pattern[2, default: [[], [], [], []]][2] = [0x03, 0x58, 0x1A, 0x00]
    let module = proTracker([header(words: 4, fine: 0, volume: 64, loopStart: 0, loopWords: 1),
                             header(words: 2, fine: 2, volume: 32, loopStart: 1, loopWords: 1)],
                            order: [0, 0], patterns: [pattern], samples: wave)
    return (file, module)
}

@Test func thePlayer61IsFoundAndUnpacked() throws {
    for delta in [false, true] {
        let tune = player61(delta: delta)
        #expect(ProWizard.packer(of: tune.packed) == .player61)
        let unpacked = try #require(ProWizard.unpack(tune.packed))
        #expect(unpacked.packer == "The Player 6.1a")
        #expect(unpacked.module == tune.module)
    }
}

@Test func thePlayer61RefusesWhatItCannotUnpack() {
    var packed = player61(delta: false).packed
    packed[3] |= 0x40
    #expect(ProWizard.unpack(packed) == nil)
    #expect(ProWizard.unpack(Array(player61(delta: false).packed.dropLast(1))) == nil)
    // A note of an instrument there is not.
    packed = player61(delta: false).packed
    packed[packed.count - 12 - 6 + 1] = 0x3A
    #expect(ProWizard.packer(of: packed) != .player61)
}

@Test func thePlayer61NeverTraps() {
    neverTraps(player61(delta: true).packed)
}

