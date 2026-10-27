// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday from the descriptions of the file format that came with Composer 669 and with
// UNIS 669, and from what OpenMPT and libxmp make of such a file (see THIRD-PARTY.md). The checks a
// file is held to before it is taken for one are OpenMPT's.

import SidayFoundation

/// A 669 file: a module of eight channels made with Composer 669, which Tran of Renaissance wrote
/// for the PC in 1992, or with UNIS 669, which came after it and added a little.
///
/// There are up to 64 samples, of eight bits, each of which may go round; up to 128 patterns of 64
/// rows; and a list of which pattern to play when. A pattern has a speed of its own, which is how
/// many ticks each of its rows lasts, and a row that is its last, so that it need not run to all
/// 64. A note is a pitch, a sample and a volume from 0 to 15, and beside it there may be one of a
/// handful of commands.
final class Composer669Module {
    static let channels = 8
    static let rows = 64
    private static let header = 497, sampleHeader = 25, patternSize = rows * channels * 3
    /// A file that says a sample is longer than this is not a 669 file: the two letters such a
    /// file begins with are too little to know it by.
    private static let longestSample = 0x400_0000

    let title: String
    /// True for a file of UNIS 669's own kind, which has two commands more.
    let extended: Bool
    /// The list of patterns, as far as its end.
    let orders: [UInt8]
    /// Where in the list the tune goes on from when it has come to the end.
    let restart: Int
    let patternCount: Int
    /// Each pattern's speed and its last row.
    let speeds: [UInt8], lastRows: [UInt8]
    private let cells: [UInt8]
    let bank = SoundBank()
    let sampleCount: Int
    let shortfalls: [String]

    /// In the list of patterns: nothing to play at this place, and the end of the list.
    static let skip: UInt8 = 0xFE, end: UInt8 = 0xFF

    init(_ data: [UInt8]) throws {
        let file = ByteReader(data)
        guard data.count >= Self.header, data[0] == 0x69 && data[1] == 0x66 || data[0] == 0x4A && data[1] == 0x4E else {
            throw TuneError.malformed("not a 669 file")
        }
        extended = data[0] == 0x4A
        let samples = Int(data[110]), patterns = Int(data[111])
        guard samples <= 64, patterns <= 128, data[112] < 128 else { throw TuneError.malformed("not a 669 file") }
        // (A message is three lines of text: a file with much in it that is not, is something else.)
        guard data[2 ..< 110].count(where: { $0 > 0 && $0 <= 31 }) <= 40 else { throw TuneError.malformed("not a 669 file") }
        var orders: [UInt8] = []
        var ended = false
        for i in 0 ..< 128 {
            let order = data[113 + i], speed = data[241 + i], lastRow = data[369 + i]
            guard order < 128 || order >= Self.skip, order >= 128 || speed != 0, speed <= 15, lastRow < 64 else {
                throw TuneError.malformed("not a 669 file")
            }
            if order == Self.end { ended = true }
            if !ended { orders.append(order) }
        }
        self.orders = orders
        speeds = Array(data[241 ..< 369])
        lastRows = Array(data[369 ..< 497])
        patternCount = patterns
        sampleCount = samples
        let restart = Int(data[112])
        self.restart = restart < orders.count && orders[restart] < patterns ? restart : 0
        // (The first of the message's three lines is the nearest thing to a title that there is.)
        title = file.dos(at: 2, length: 36)

        let patternsAt = Self.header + samples * Self.sampleHeader
        var soundAt = patternsAt + patterns * Self.patternSize
        guard data.count >= soundAt else { throw TuneError.malformed("a 669 file that ends before its patterns do") }
        cells = Array(data[patternsAt ..< soundAt])

        var cut = Shortfall.CutShort()
        var sounds = false
        for sample in 0 ..< samples {
            let at = Self.header + sample * Self.sampleHeader
            let length = file.u32le(at + 13), loopStart = file.u32le(at + 17)
            var loopEnd = file.u32le(at + 21)
            // (In a browser a whole number has 32 bits, and a length that fills them is less than nothing.)
            guard length >= 0, length < Self.longestSample else { throw TuneError.malformed("not a 669 file") }
            // (A sample that does not go round says so with an end past its own, or with none.)
            if loopEnd > length, loopStart == 0 { loopEnd = 0 }
            let there = max(0, min(length, data.count - soundAt))
            cut.add(length: length, there: data.count - soundAt)
            // Unsigned in the file. What the file has lost of a sample is silence.
            var frames = [Int8](repeating: 0, count: length)
            for i in 0 ..< there { frames[i] = Int8(bitPattern: data[soundAt + i] ^ 0x80) }
            if !sounds { sounds = Shortfall.sounds(frames) }
            bank.add(eightBit: frames, loop: loopEnd != 0 ? (loopStart, loopEnd) : nil)
            soundAt += length
        }
        guard sounds else { throw Shortfall.nothingToHear }

        var shortfalls: [String] = []
        if let sentence = cut.sentence { shortfalls.append(sentence) }
        // UNIS 669 has a tempo faster than the fastest, which nothing says the speed of. And a
        // few files have commands that neither program is said to have had.
        var fastest = false, unknown = false
        for place in orders where place < patterns {
            for cell in 0 ..< Self.rows * Self.channels {
                let command = cells[Int(place) * Self.patternSize + cell * 3 + 2]
                if command == 0x50 { fastest = true }
                if command != 0xFF, command >> 4 >= (extended ? 8 : 6) { unknown = true }
            }
        }
        if fastest, extended { shortfalls.append("It asks for UNIS 669's fastest tempo, and is left at the tempo it had.") }
        if unknown { shortfalls.append("It has commands that Composer 669 is not known to have had, and they are left out.") }
        self.shortfalls = shortfalls
    }

    /// What a channel has on a row of a pattern: three bytes, as the file has them.
    @inline(__always)
    func cell(pattern: Int, row: Int, channel: Int) -> (UInt8, UInt8, UInt8) {
        let at = pattern * Self.patternSize + (row * Self.channels + channel) * 3
        guard pattern >= 0, pattern < patternCount, at + 2 < cells.count else { return (0xFF, 0, 0xFF) }
        return (cells[at], cells[at + 1], cells[at + 2])
    }

    /// The rows of all the patterns together, for telling which song first played each.
    var rowsInAll: Int { 128 * Self.rows }
}
