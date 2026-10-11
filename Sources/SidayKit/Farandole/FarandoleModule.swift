// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday from the description of the file that came with Farandole Composer, and from
// what libxmp and OpenMPT make of such a file (see THIRD-PARTY.md).

/// A FAR file: a module of Farandole Composer, which Megan Potter of Digital Infinity wrote for
/// the PC and the Gravis Ultrasound in 1994.
///
/// There are sixteen channels, each at any of sixteen places between the speakers; up to 64
/// samples, of eight bits or sixteen, each of which may go round; up to 256 patterns, each as long
/// as it likes up to 256 rows; and a list of which pattern to play when. A note is a pitch, a
/// sample and a volume from 0 to 15, and beside it there may be one command.
final class FarandoleModule {
    static let channels = 16
    /// The most rows a pattern can have, and how many one has that the file has nothing of.
    static let mostRows = 256, emptyRows = 64
    private static let header = 98, lists = 771, sampleHeader = 48

    struct Pattern {
        /// Where its cells are among the module's; -1 for a pattern the file has nothing of.
        var at = -1
        var rows = FarandoleModule.emptyRows
        /// The last of its rows that is played.
        var lastRow = FarandoleModule.emptyRows - 1
    }

    let title: String
    /// The tempo the tune starts at, from 0 to 15.
    let tempo: Int
    /// The list of patterns, as long as the file says it is.
    let orders: [UInt8]
    /// Where in the list the tune goes on from when it has come to the end.
    let restart: Int
    let patterns: [Pattern]
    private let cells: [UInt8]
    /// Where each channel is, of sixteen places from the left, and whether it is heard at all.
    let pans: [UInt8], heard: [Bool]
    /// The samples, by their numbers from 0; none where the file has none.
    let bank = SoundBank()
    let shortfalls: [String]

    init(_ data: [UInt8]) throws {
        let file = ByteReader(data)
        guard data.count >= Self.header + Self.lists, data[0] == 0x46, data[1] == 0x41, data[2] == 0x52, data[3] == 0xFE,
              data[44] == 0x0D, data[45] == 0x0A, data[46] == 0x1A, data[75] < 16
        else { throw TuneError.malformed("not a FAR file") }
        title = file.ascii(at: 4, length: 40)
        tempo = Int(data[75])
        heard = (0 ..< Self.channels).map { data[50 + $0] != 0 }
        pans = (0 ..< Self.channels).map { data[76 + $0] & 15 }
        let textLength = file.u16le(96)
        let listsAt = Self.header + textLength
        guard data.count >= listsAt + Self.lists else { throw TuneError.malformed("a FAR file that ends before its list of patterns") }
        let length = Int(data[listsAt + 257])
        orders = Array(data[listsAt ..< listsAt + length])
        let restart = Int(data[listsAt + 258])
        self.restart = restart < length ? restart : 0

        // The patterns follow the header, which says how long it is: longer than this much of it,
        // in a file of some later kind that has more there.
        var at = max(listsAt + Self.lists, file.u16le(47))
        var patterns = [Pattern](repeating: Pattern(), count: 256)
        var cells: [UInt8] = []
        for pattern in 0 ..< 256 {
            let size = file.u16le(listsAt + 259 + pattern * 2)
            guard size != 0 else { continue }
            // (Two bytes before the rows: the row before the last that is played, and one that
            // nothing uses.)
            let rows = min(Self.mostRows, (size - 2) / (Self.channels * 4))
            if rows > 0, at < data.count {
                var one = Pattern(at: cells.count, rows: rows, lastRow: rows - 1)
                let last = Int(file[at]) + 1
                if last > 1, last < rows - 1 { one.lastRow = last }
                patterns[pattern] = one
                for i in 0 ..< rows * Self.channels * 4 { cells.append(file[at + 2 + i]) }
            }
            at += size
        }
        self.patterns = patterns
        self.cells = cells

        // The samples: eight bytes that say which of the 64 there are, and then each with its sound.
        let which = at
        at += 8
        var cut = Shortfall.CutShort()
        for sample in 0 ..< 64 {
            guard file[which + sample >> 3] & (1 << (sample & 7)) != 0, at + Self.sampleHeader <= data.count else {
                bank.add([])
                continue
            }
            // (Four bytes, of which a whole number in a browser has room for all but one bit: a
            // length too great to be one is brought down to what is still far too great.)
            let length = file.u16le(at + 34) >= 0x100 ? 0x100_0000 : file.u32le(at + 32)
            let sixteen = file[at + 46] & 1 != 0, loops = file[at + 47] & 8 != 0
            var loopStart = max(0, file.u32le(at + 38)), loopEnd = max(0, file.u32le(at + 42))
            at += Self.sampleHeader
            let there = max(0, min(length, data.count - at))
            cut.add(length: length, there: data.count - at)
            // What the file has lost of a sample is silence.
            if sixteen {
                var frames = [Int16](repeating: 0, count: length / 2)
                for i in 0 ..< there / 2 { frames[i] = Int16(truncatingIfNeeded: file.u16le(at + i * 2)) }
                loopStart /= 2
                loopEnd /= 2
                bank.add(frames, loop: loops && loopEnd > loopStart ? (loopStart, loopEnd) : nil)
            } else {
                var frames = [Int8](repeating: 0, count: length)
                for i in 0 ..< there { frames[i] = Int8(bitPattern: data[at + i]) }
                bank.add(eightBit: frames, loop: loops && loopEnd > loopStart ? (loopStart, loopEnd) : nil)
            }
            at += length
        }
        shortfalls = cut.sentence.map { [$0] } ?? []
    }

    /// What a channel has on a row of a pattern: four bytes, as the file has them.
    @inline(__always)
    func cell(pattern: Int, row: Int, channel: Int) -> (note: UInt8, sample: UInt8, volume: UInt8, command: UInt8) {
        let one = patterns[pattern & 255]
        guard one.at >= 0, row < one.rows else { return (0, 0, 0, 0) }
        let at = one.at + (row * Self.channels + channel) * 4
        return (cells[at], cells[at + 1], cells[at + 2], cells[at + 3])
    }

    /// The rows of all the places in the list together, for telling which song first played each.
    var rowsInAll: Int { max(1, orders.count) * Self.mostRows }
}
