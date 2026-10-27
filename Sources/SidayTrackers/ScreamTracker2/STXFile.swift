// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the STX loaders of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence,
// and of libxmp, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito Carraro Jr, used under the
// MIT licence (see THIRD-PARTY.md). The checks a file is held to before it is taken for one are
// OpenMPT's.

import SidayFoundation

/// An STX file: a module for the Scream Tracker Music Interface Kit, the library that Future Crew
/// gave out in the early 1990s for putting Scream Tracker's music into other people's programs.
///
/// The kit's documentation calls the format a beta of Scream Tracker 3's, and so it looks: an S3M
/// file's header, its samples' headers and its way of packing a pattern, row by row with only the
/// channels that have something in them. But what is packed is an STM file's: the kit came with a
/// converter, STM2STX, and its music was written in Scream Tracker 2. There are four channels,
/// the commands are Scream Tracker 2's under Scream Tracker 2's letters (A sets the tempo in its
/// two halves, there are no fine slides, and nothing is remembered from one command to the next),
/// and the tempo in the header is Scream Tracker 2's. OpenMPT and Schism Tracker both play it as
/// an STM file for that reason, and so it is here: it is read into the shape of one, and Scream
/// Tracker 2's replayer plays it. (libxmp plays it with Scream Tracker 3's ways instead, which gives
/// its A command only the ticks to a row and keeps what each command was last given.) The kit's
/// own replayer has never been published.
///
/// What an STM file has no room for:
///  - More than four channels, more than 31 samples, samples longer than 65,535 bytes or of
///    sixteen bits or in stereo, and more than 128 places in the list. The converter made none of
///    these, and a file that has them, and uses them, says so.
///  - A volume over 64, which Scream Tracker 2 plays as silence and an S3M file has no use for: it
///    is taken for 64, as OpenMPT takes it.
enum STXFile {
    private static let channels = ST2Module.channels, rows = ST2Module.rows
    /// An STM file's header and samples' headers, the length of its list, and of a pattern.
    private static let stmHeader = 48, stmSampleHeader = 32, stmSamples = 31, stmOrders = 128
    private static let stmPattern = rows * channels * 4

    /// An STX file read into an STM file, with what the STM file could not hold.
    static func stm(_ data: [UInt8]) throws -> (file: [UInt8], shortfalls: [String]) {
        let f = ByteReader(data)
        func refuse() -> TuneError { TuneError.malformed("not an STX file") }
        guard data.count >= 64, data[60 ..< 64].elementsEqual([0x53, 0x43, 0x52, 0x4D]) else { throw refuse() }
        let patternSize = f.u16le(28)
        let patterns = f.u16le(48), sampleCount = f.u16le(50), orderCount = f.u16le(52)
        guard data[20 ..< 28].allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
              patternSize >= 64 || patternSize == 0x1A, patternSize <= 0x840,
              data[42] <= 64 || data[42] == 0x58,
              patterns <= 64, sampleCount <= 96, orderCount <= 0x81 || orderCount == 0x101,
              f.u16le(30) == 0, f.u32le(38) == 0, f.u32le(44) == 1
        else { throw refuse() }
        let patternTable = f.u16le(32) << 4, sampleTable = f.u16le(34) << 4, channelTable = f.u16le(36) << 4

        // The list, five bytes to a place, of which the first is the pattern.
        var orders = [UInt8](repeating: ST2Module.end, count: stmOrders)
        for place in 0 ..< orderCount {
            let order = f[channelTable + 32 + place * 5]
            guard order <= 63 || order == ST2Module.end || order == ST2Module.endToTop || order == 255 else { throw refuse() }
            if place < stmOrders { orders[place] = order }
        }
        let listEnd = orders.firstIndex { $0 > 63 } ?? stmOrders
        var shortfalls: [String] = []
        if listEnd == stmOrders, orderCount > stmOrders, (stmOrders ..< orderCount).contains(where: { f[channelTable + 32 + $0 * 5] <= 63 }) {
            shortfalls.append("Its list of patterns is longer than Scream Tracker 2 had room for, and is played to the 128th place.")
        }

        // The patterns, into four bytes a cell: the note; the sample and the low bits of the
        // volume; the rest of the volume and the command; and the command's value.
        var cells = [UInt8](repeating: 0, count: patterns * stmPattern)
        for cell in 0 ..< patterns * rows * channels {
            (cells[cell * 4], cells[cell * 4 + 1], cells[cell * 4 + 2], cells[cell * 4 + 3]) = (0xFF, 0x01, 0x80, 0)
        }
        // A file of the converter's first version gives each pattern's length before it, as an
        // S3M file does: known by the first pattern's being the length the header says.
        let first = f.u16le(patternTable) << 4
        let lengthFirst = patterns > 0 && patternSize != 0x1A && f.u16le(first) == patternSize
        var unheardChannels = false
        var tooHigh = Set<Int>()
        var partsLost = 0
        for pattern in 0 ..< patterns {
            let pointer = f.u16le(patternTable + pattern * 2)
            guard pointer != 0 else { continue }
            var at = (pointer << 4) + (lengthFirst ? 2 : 0), row = 0
            while row < rows, at < data.count {
                let what = data[at]
                at += 1
                guard what != 0 else { row += 1; continue }
                let channel = Int(what & 0x1F)
                var note: UInt8 = 0xFF, sample = 0, volume: UInt8 = 65, command: UInt8 = 0, value: UInt8 = 0
                if what & 0x20 != 0 {
                    note = f[at]
                    sample = Int(f[at + 1])
                    at += 2
                    // (A number that is no note's is none, as OpenMPT reads it.)
                    if note >= 0xF0, note != 0xFE { note = 0xFF }
                }
                if what & 0x40 != 0 {
                    volume = min(f[at], 64)
                    at += 1
                }
                if what & 0x80 != 0 {
                    command = f[at] & 0x0F
                    value = f[at + 1]
                    at += 2
                }
                guard channel < channels else {
                    if what & 0xE0 != 0 { unheardChannels = true }
                    continue
                }
                if sample > stmSamples {
                    tooHigh.insert(sample)
                    sample = 0
                }
                let to = pattern * stmPattern + (row * channels + channel) * 4
                cells[to] = note
                cells[to + 1] = UInt8(sample << 3) | volume & 7
                cells[to + 2] = (volume & 0x78) << 1 | command
                cells[to + 3] = value
            }
            // (What the file has lost of a pattern is rows with nothing in them.)
            if row < rows, at >= data.count { partsLost += 1 }
        }
        if unheardChannels {
            shortfalls.append("It has more channels than Scream Tracker 2's four, and those after the fourth are not heard.")
        }

        // Which samples the tune plays, to say only what matters of them.
        var used = [Bool](repeating: false, count: 256)
        for place in 0 ..< listEnd where Int(orders[place]) < patterns {
            for cell in 0 ..< rows * channels {
                used[Int(cells[Int(orders[place]) * stmPattern + cell * 4 + 1] >> 3)] = true
            }
        }
        // (A sample past the 31st was taken off its notes above; that it was asked for is enough.)
        for number in tooHigh { used[number] = true }

        // The samples, each into the place of one of an STM file's, and its sound after the patterns.
        var header = [UInt8](repeating: 0, count: stmHeader + stmSamples * stmSampleHeader)
        var sound: [UInt8] = []
        let soundAt = header.count + stmOrders + cells.count
        var cut = Shortfall.CutShort()
        var unplayable = 0
        func u16(_ value: Int) -> Int { value < 0 || value > 0xFFFF ? 0xFFFF : value }
        for index in 0 ..< sampleCount {
            let number = index + 1
            let at = f.u16le(sampleTable + index * 2) << 4
            // (A sample the tune plays whose header the file ends before is missing.)
            if at + 0x50 > data.count, used[number] {
                cut.addMissing()
                continue
            }
            let kind = f[at], flags = f[at + 31]
            let length = f.u32le(at + 16), volume = min(f[at + 28], 64)
            let playable = kind == 1 && flags & 6 == 0 && length >= 0 && length <= 0xFFFF && number <= stmSamples
            if !playable {
                if used[number], kind != 0, length != 0, volume != 0 { unplayable += 1 }
                continue
            }
            let to = stmHeader + (number - 1) * stmSampleHeader
            for i in 0 ..< 12 { header[to + i] = f[at + 1 + i] }
            header[to + 12] = 0
            let loopStart = u16(f.u32le(at + 20)), loopEnd = flags & 1 != 0 ? u16(f.u32le(at + 24)) : 0xFFFF
            let count = loopEnd != 0xFFFF ? max(length, loopEnd) : length
            let from = (Int(f[at + 13]) << 16 | f.u16le(at + 14)) << 4
            // (The STM file says where a sample's sound is in sixteens of bytes, in two bytes.)
            guard (soundAt + sound.count) >> 4 <= 0xFFFF else {
                if used[number], length != 0, volume != 0 { unplayable += 1 }
                continue
            }
            let place = (soundAt + sound.count) >> 4
            (header[to + 14], header[to + 15]) = (UInt8(place & 0xFF), UInt8(place >> 8))
            (header[to + 16], header[to + 17]) = (UInt8(length & 0xFF), UInt8(length >> 8))
            (header[to + 18], header[to + 19]) = (UInt8(loopStart & 0xFF), UInt8(loopStart >> 8))
            (header[to + 20], header[to + 21]) = (UInt8(loopEnd & 0xFF), UInt8(loopEnd >> 8))
            header[to + 22] = volume
            let c2spd = f.u16le(at + 32)
            (header[to + 24], header[to + 25]) = (UInt8(c2spd & 0xFF), UInt8(c2spd >> 8))
            // What Scream Tracker 2 loads of a sample is all it plays, a sample that goes round past
            // its end included: there it plays on into what follows it in the file, which is what
            // follows it here too.
            if volume != 0, length != 0 {
                for i in 0 ..< count { sound.append(f[from + i]) }
                while sound.count & 15 != 0 { sound.append(0) }
                if used[number] { cut.add(length: length, there: data.count - from) }
            }
        }
        if unplayable > 0 {
            shortfalls.append(Shortfall.some(unplayable, one: "samples is of a kind Scream Tracker 2 could not play, and is silent.",
                                             many: "samples are of a kind Scream Tracker 2 could not play, and are silent."))
        }
        if let sentence = cut.sentence { shortfalls.append(sentence) }
        if partsLost > 0 || patternTable + patterns * 2 > data.count {
            shortfalls.append(Shortfall.patternsLost(samplesToo: cut.sentence != nil))
        } else if cut.sentence == nil, sampleTable + sampleCount * 2 > data.count || channelTable + 32 + orderCount * 5 > data.count {
            shortfalls.append(Shortfall.cutShort("Some of what it has is not there."))
        }

        // The STM file's header: of version 2.21, whose tempo is as it stands, as an STX file's is.
        for i in 0 ..< 20 { header[i] = f[i] }
        for i in 20 ..< 28 { header[i] = f[i] }
        header[28] = 0x1A
        (header[29], header[30], header[31]) = (2, 2, 21)
        header[32] = data[43]
        header[33] = UInt8(patterns)
        header[34] = min(data[42], 64)
        return (header + orders + cells + sound, shortfalls)
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> STMRenderer {
        let (file, shortfalls) = try stm(data)
        return try STMRenderer(file, format: "STX", detail: "Scream Tracker Music Interface Kit, on Scream Tracker 2.3's replayer", shortfalls: shortfalls)
    }
}
