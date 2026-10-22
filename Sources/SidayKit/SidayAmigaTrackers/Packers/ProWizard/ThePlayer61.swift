// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/p61a.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// Modules packed by The Player 6.1a, the last version of Jarno Paananen's replayer. The file is laid
/// out as 6.0a's is (see `ThePlayer`), but a note takes one to four bytes: its top bits say whether it
/// has a note and instrument, an effect, or both, and whether a byte follows saying how many rows are
/// empty after it or how many times more it is played. 0x7F is an empty row, and 0xFF either so many
/// empty rows or so many rows read again from so many bytes back.
enum ThePlayer61 {
    /// ProWizard's test: the counts, the samples' headers, where the tracks start, the order, and then
    /// every note up to the samples. (`test_p61a`)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        func byte(_ at: Int) -> Int { ProWizard.byte(data, at) }
        func word(_ at: Int) -> Int { ProWizard.word(data, at) }

        if let more = ProWizard.request(size, 4) { return more }

        let patterns = byte(2)
        if patterns > 0x7F || patterns == 0 { return -1 }
        let samples = byte(3) & 0x3F
        if samples > 0x1F || samples == 0 { return -1 }
        // A module with samples packed has the length of them all unpacked before the samples'
        // headers, and the top bit of a packed sample's fine tuning set. (This is UADE's converter's,
        // Deli-Wizard's `CheckP50A`; libxmp's test does not know of them.)
        let base = byte(3) & 0x40 != 0 ? 8 : 4
        let tuning = byte(3) & 0x40 != 0 ? 0x7F : 0xFF

        if let more = ProWizard.request(size, base + samples * 6) { return more }
        for i in 0 ..< samples {
            if byte(base + 3 + i * 6) > 0x40 { return -1 }
            if byte(base + 2 + i * 6) & tuning > 0x0F { return -1 }
        }

        // A size above 0xFFDF is a sample that is another's.
        for i in 0 ..< samples {
            let length = word(base + i * 6)
            if (length <= 0xFFDF && length > 0x8000) || length == 0 { return -1 }
            let start = word(base + 4 + i * 6)
            if start != 0xFFFF && start >= length { return -1 }
            if length > 0xFFDF && 0xFFFF - length > samples { return -1 }
        }

        let patternData = base + samples * 6 + patterns * 8
        let sampleData = word(0)
        if sampleData < patternData { return -1 }

        if let more = ProWizard.request(size, patternData) { return more }
        for i in 0 ..< patterns * 4 where word(base + samples * 6 + i * 2) + patternData > sampleData {
            return -1
        }

        if let more = ProWizard.request(size, sampleData) { return more }
        var i = 0
        while i < 128 {
            if patternData + i >= sampleData { return -1 }
            if byte(patternData + i) == 0xFF { break }
            if byte(patternData + i) > patterns - 1 { return -1 }
            i += 1
        }
        if i == 0 || i == 128 { return -1 }

        // The notes, from after the order's end up to the byte before the samples.
        var n = patternData + i + 1
        while n < sampleData - 1 {
            defer { n += 1 }
            let d = byte(n)
            let e = byte(n + 1)
            if d == 0xFF {
                if e & 0xC0 == 0x00 {
                    n += 1
                    continue
                }
                if e & 0xC0 == 0x40 {
                    n += 2
                    continue
                }
                if e & 0xC0 == 0xC0 {
                    n += 3
                    continue
                }
            }
            if d == 0x7F { continue }
            // A note and instrument, and no effect.
            if d & 0xF0 == 0xF0 {
                if e & 0x1F > samples { return -1 }
                n += 2
                continue
            }
            if d & 0xF0 == 0x70 {
                if e & 0x1F > samples { return -1 }
                n += 1
                continue
            }
            // An effect, and no note nor instrument.
            if d & 0xF0 == 0xE0 {
                n += 2
                continue
            }
            if d & 0xF0 == 0x60 {
                n += 1
                continue
            }
            if d & 0x80 == 0x80 {
                if ((d << 4) & 0x10) | ((e >> 4) & 0x0F) > samples { return -1 }
                n += 3
                continue
            }
            if ((d << 4) & 0x10) | ((e >> 4) & 0x0F) > samples { return -1 }
            n += 2
        }
        return 0
    }

    /// A slide of volume, kept as a signed byte, as ProTracker's two halves; other effects' values as
    /// they are.
    private static func value(_ command: UInt8, _ value: UInt8) -> UInt8 {
        guard command == 0x05 || command == 0x06 || command == 0x0A, value > 0x7F else { return value }
        return UInt8(truncatingIfNeeded: (0x100 - Int(value)) << 4)
    }

    /// The patterns' bytes, written only where they are: every place written is in a pattern's 64 rows,
    /// but the check keeps a mistake from trapping.
    private struct Tracks {
        var bytes = [UInt8](repeating: 0, count: 512 * 256)

        /// Where a row of a channel of a pattern is, each channel's 64 rows together.
        static func place(_ pattern: Int, _ channel: Int, _ row: Int) -> Int {
            (pattern * 4 + channel) * 256 + row * 4
        }

        subscript(_ at: Int) -> UInt8 {
            get { at >= 0 && at < bytes.count ? bytes[at] : 0 }
            set { if at >= 0 && at < bytes.count { bytes[at] = newValue } }
        }

        /// A note and instrument with no effect.
        mutating func note(_ at: Int, _ index: UInt8, _ c2: UInt8) {
            self[at] = (c2 & 0x10) | ProWizard.notes[Int(index / 2)].0
            self[at + 1] = ProWizard.notes[Int(index / 2)].1
            self[at + 2] = (c2 << 4) & 0xF0
        }
    }

    /// Unpacks a module. (`depack_p61a`)
    static func depack(_ file: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        var sizes = [Int](repeating: 0, count: 31)
        var lengths = [Int](repeating: 0, count: 31)
        var starts = [Int](repeating: 0, count: 31)
        // Which are packed, each of its bytes two of the sample's, and so how many bytes each takes in
        // the file.
        var packed = [Bool](repeating: false, count: 31)
        var kept = [Int](repeating: 0, count: 31)

        let sampleData = Int(file.read16b())
        let patternCount = Int(file.read8())
        if patternCount >= 128 { throw .malformed("too many patterns") }
        var sampleCount = Int(file.read8())
        let delta = sampleCount & 0x80 != 0
        // Samples packed, which libxmp does not unpack, are unpacked as UADE's converter does
        // (Deli-Wizard's `CheckP50A` and `P50A_Copy_Samples`): after the length of them all unpacked,
        // which is not needed, each sample's header says by the top bit of its fine tuning whether it
        // is packed.
        let packing = sampleCount & 0x40 != 0
        if packing { _ = file.read32b() }
        sampleCount &= 0x3F
        // (The C does not look, and would write past its tables; the test lets no more than 31 by.)
        if sampleCount > 31 { throw .malformed("too many samples") }

        output.writeZero(20)
        for i in 0 ..< sampleCount {
            output.writeZero(22)
            var j = Int(file.read16b())
            let tuning = file.read8()
            sizes[i] = j
            if j > 0xFF00 {
                // A sample that is another's. (The test lets the other be one past the last of the 31,
                // where the C reads whatever lies after its tables; this takes it as empty.)
                let other = 0xFFFF - j
                lengths[i] = other < 31 ? lengths[other] : 0
                sizes[i] = other < 31 ? sizes[other] : 0
                starts[i] = other < 31 ? starts[other] : 0
                packed[i] = other < 31 ? packed[other] : false
                kept[i] = other < 31 ? kept[other] : 0
            } else {
                if i > 0 { starts[i] = starts[i - 1] + kept[i - 1] }
                lengths[i] = j * 2
                packed[i] = packing && tuning & 0x80 != 0
                kept[i] = packed[i] ? j : j * 2
            }
            j = lengths[i] / 2
            output.write16b(UInt16(truncatingIfNeeded: sizes[i]))
            output.write8(tuning & 0x3F)
            output.write8(file.read8())
            let loop = Int(file.read16b())
            if loop == 0xFFFF {
                output.write16b(0)
                output.write16b(1)
                continue
            }
            output.write16b(UInt16(truncatingIfNeeded: loop))
            output.write16b(UInt16(truncatingIfNeeded: j - loop))
        }
        for _ in sampleCount ..< 31 {
            output.writeZero(29)
            output.write8(1)
        }

        var trackStarts = [[Int]](repeating: [0, 0, 0, 0], count: 128)
        for i in 0 ..< patternCount {
            for j in 0 ..< 4 { trackStarts[i][j] = Int(file.read16b()) }
        }

        var order = [UInt8](repeating: 0, count: 128)
        var length = 0
        while length < 128 {
            let pattern = file.read8()
            if pattern == 0xFF { break }
            order[length] = pattern
            length += 1
        }
        output.write8(UInt8(length))
        output.write8(0x7F)
        output.write(order)
        output.write32b(ProWizard.proTrackerLetters)

        let trackData = file.position
        var tracks = Tracks()
        // A pattern ends at the row of the first break or jump found in any of its tracks, and tracks
        // read after that one stop there too.
        for i in 0 ..< patternCount {
            var lastRow = 63
            channels: for j in 0 ..< 4 {
                file.seek(trackStarts[i][j] + trackData)
                var k = 0
                while k <= lastRow {
                    // As the C's loop does, every way on to the next row counts the row. (A break
                    // counts it too, but the row is not looked at again.)
                    defer { k += 1 }
                    var x = Tracks.place(i, j, k)
                    var c1 = file.read8()

                    // A note and instrument, and no effect: two bytes, and one more if the top bit
                    // is set.
                    if c1 & 0x70 == 0x70 && c1 != 0xFF && c1 != 0x7F {
                        let c2 = file.read8()
                        let c6 = ((c1 << 4) & 0xF0) | ((c2 >> 4) & 0x0E)
                        if file.takeError() || !ProWizard.isNote(Int(c6 / 2)) { throw .malformed("not a note") }
                        tracks.note(x, c6, c2)
                        if c1 & 0x80 != 0 {
                            let c3 = file.read8()
                            if c3 < 0x80 {
                                k += Int(c3)
                                continue
                            }
                            let c4 = c3 - 0x80
                            var l = 0
                            while l < c4 && k < lastRow {
                                k += 1
                                tracks.note(Tracks.place(i, j, k), c6, c2)
                                l += 1
                            }
                        }
                        continue
                    }

                    // An effect, and no note nor instrument.
                    if c1 & 0x70 == 0x60 && c1 != 0xFF {
                        var c2 = file.read8()
                        let c6 = c1 & 0x0F
                        if c6 == 0x08 { c1 -= 0x08 }
                        x += 2
                        tracks[x] = c1 & 0x0F
                        c2 = value(c6, c2)
                        tracks[x + 1] = c2
                        if c6 == 0x0D || c6 == 0x0B {
                            lastRow = k
                            break
                        }
                        if c1 & 0x80 != 0 {
                            let c3 = file.read8()
                            if c3 < 0x80 {
                                k += Int(c3)
                                continue
                            }
                            let c4 = c3 - 0x80
                            var l = 0
                            while l < c4 && k < lastRow {
                                k += 1
                                let at = Tracks.place(i, j, k) + 2
                                tracks[at] = c1 & 0x0F
                                tracks[at + 1] = c2
                                l += 1
                            }
                        }
                        continue
                    }

                    // A note, an instrument and an effect, and a byte for the rows after.
                    if c1 & 0x80 == 0x80 && c1 != 0xFF {
                        var c2 = file.read8()
                        var c3 = file.read8()
                        var c4 = file.read8()
                        c1 &= 0x7F
                        if file.takeError() || !ProWizard.isNote(Int(c1 / 2)) { throw .malformed("not a note") }
                        tracks[x] = ((c1 << 4) & 0x10) | ProWizard.notes[Int(c1 / 2)].0
                        tracks[x + 1] = ProWizard.notes[Int(c1 / 2)].1
                        var c6 = c2 & 0x0F
                        if c6 == 0x08 { c2 -= 0x08 }
                        tracks[x + 2] = c2
                        c3 = value(c6, c3)
                        tracks[x + 3] = c3
                        if c6 == 0x0D || c6 == 0x0B {
                            lastRow = k
                            break
                        }
                        if c4 < 0x80 {
                            k += Int(c4)
                            continue
                        }
                        c4 -= 0x80
                        var l = 0
                        while l < c4 && k < lastRow {
                            k += 1
                            let at = Tracks.place(i, j, k)
                            tracks[at] = ((c1 << 4) & 0x10) | ProWizard.notes[Int(c1 / 2)].0
                            tracks[at + 1] = ProWizard.notes[Int(c1 / 2)].1
                            // (The C works the effect out again for each row, on what it made of it
                            // the time before, so a slide of volume may come out otherwise.)
                            c6 = c2 & 0x0F
                            if c6 == 0x08 { c2 -= 0x08 }
                            tracks[at + 2] = c2
                            c3 = value(c6, c3)
                            tracks[at + 3] = c3
                            l += 1
                        }
                        continue
                    }

                    if c1 & 0x7F == 0x7F {
                        // 0x7F: an empty row.
                        if c1 & 0x80 == 0 { continue }
                        // 0xFF: so many empty rows, or so many rows read again from so many bytes back.
                        var c2 = file.read8()
                        if c2 < 0x40 {
                            k += Int(c2)
                            continue
                        }
                        c2 -= 0x40
                        let c3 = file.read8()
                        var back = Int(c3)
                        if c2 >= 0x80 {
                            c2 -= 0x80
                            let c4 = file.read8()
                            back = (Int(c3) << 8) + Int(c4)
                        }
                        let resume = file.position
                        let count = Int(c2)
                        file.skip(-back)

                        var l = 0
                        while l <= count && k <= lastRow {
                            var d1 = file.read8()
                            x = Tracks.place(i, j, k)

                            if d1 & 0x70 == 0x70 && d1 != 0xFF && d1 != 0x7F {
                                let d2 = file.read8()
                                let d6 = ((d1 << 4) & 0xF0) | ((d2 >> 4) & 0x0E)
                                if file.takeError() || !ProWizard.isNote(Int(d6 / 2)) { throw .malformed("not a note") }
                                tracks.note(x, d6, d2)
                                if d1 & 0x80 != 0 {
                                    let d3 = file.read8()
                                    if d3 < 0x80 {
                                        k += Int(d3) + 1
                                        l += 1
                                        continue
                                    }
                                    let d4 = d3 - 0x80
                                    var b = 0
                                    while b < d4 && k < lastRow {
                                        k += 1
                                        tracks.note(Tracks.place(i, j, k), d6, d2)
                                        b += 1
                                    }
                                }
                                k += 1
                                l += 1
                                continue
                            }

                            // (Here the C tests 0x60 alone; the case of 0x70 is the one before.)
                            if d1 & 0x60 == 0x60 && d1 != 0xFF && d1 != 0x7F {
                                var d2 = file.read8()
                                let d6 = d1 & 0x0F
                                if d6 == 0x08 { d1 -= 0x08 }
                                x += 2
                                tracks[x] = d1 & 0x0F
                                d2 = value(d6, d2)
                                tracks[x + 1] = d2
                                if d6 == 0x0D || d6 == 0x0B {
                                    // The track ends here, and the C does not go back to where it was.
                                    lastRow = k
                                    continue channels
                                }
                                if d1 & 0x80 != 0 {
                                    let d3 = file.read8()
                                    if d3 < 0x80 {
                                        k += Int(d3) + 1
                                        l += 1
                                        continue
                                    }
                                    let d4 = d3 - 0x80
                                    var b = 0
                                    while b < d4 && k < lastRow {
                                        k += 1
                                        let at = Tracks.place(i, j, k) + 2
                                        tracks[at] = d1 & 0x0F
                                        tracks[at + 1] = d2
                                        b += 1
                                    }
                                }
                                k += 1
                                l += 1
                                continue
                            }

                            if d1 & 0x80 != 0 && d1 != 0xFF && d1 != 0x7F {
                                var d2 = file.read8()
                                var d3 = file.read8()
                                var d4 = file.read8()
                                d1 &= 0x7F
                                if file.takeError() || !ProWizard.isNote(Int(d1 / 2)) { throw .malformed("not a note") }
                                tracks[x] = ((d1 << 4) & 0x10) | ProWizard.notes[Int(d1 / 2)].0
                                tracks[x + 1] = ProWizard.notes[Int(d1 / 2)].1
                                var d6 = d2 & 0x0F
                                if d6 == 0x08 { d2 -= 0x08 }
                                tracks[x + 2] = d2
                                d3 = value(d6, d3)
                                tracks[x + 3] = d3
                                if d6 == 0x0D || d6 == 0x0B {
                                    lastRow = k
                                    continue channels
                                }
                                if d4 < 0x80 {
                                    k += Int(d4) + 1
                                    l += 1
                                    continue
                                }
                                d4 -= 0x80
                                var b = 0
                                while b < d4 && k < lastRow {
                                    k += 1
                                    let at = Tracks.place(i, j, k)
                                    tracks[at] = ((d1 << 4) & 0x10) | ProWizard.notes[Int(d1 / 2)].0
                                    tracks[at + 1] = ProWizard.notes[Int(d1 / 2)].1
                                    d6 = d2 & 0x0F
                                    if d6 == 0x08 { d2 -= 0x08 }
                                    tracks[at + 2] = d2
                                    d3 = value(d6, d3)
                                    tracks[at + 3] = d3
                                    b += 1
                                }
                                k += 1
                                l += 1
                                continue
                            }

                            if d1 & 0x7F == 0x7F {
                                // Rows read again are not read again from further back: 0xFF is taken
                                // only as empty rows.
                                if d1 & 0x80 != 0 {
                                    let d2 = file.read8()
                                    if d2 < 0x40 { k += Int(d2) }
                                }
                                k += 1
                                l += 1
                                continue
                            }

                            // A note, an instrument and an effect, in three bytes. (Here the C does
                            // not look for a break.)
                            var d2 = file.read8()
                            var d3 = file.read8()
                            if file.takeError() || !ProWizard.isNote(Int(d1 / 2)) { throw .malformed("not a note") }
                            tracks[x] = ((d1 << 4) & 0x10) | ProWizard.notes[Int(d1 / 2)].0
                            tracks[x + 1] = ProWizard.notes[Int(d1 / 2)].1
                            let d6 = d2 & 0x0F
                            if d6 == 0x08 { d2 -= 0x08 }
                            tracks[x + 2] = d2
                            d3 = value(d6, d3)
                            tracks[x + 3] = d3
                            k += 1
                            l += 1
                        }
                        file.seek(resume)
                        k -= 1
                        continue
                    }

                    // A note, an instrument and an effect, in three bytes.
                    var c2 = file.read8()
                    var c3 = file.read8()
                    if file.takeError() || !ProWizard.isNote(Int(c1 / 2)) { throw .malformed("not a note") }
                    tracks[x] = ((c1 << 4) & 0x10) | ProWizard.notes[Int(c1 / 2)].0
                    tracks[x + 1] = ProWizard.notes[Int(c1 / 2)].1
                    let c6 = c2 & 0x0F
                    if c6 == 0x08 { c2 -= 0x08 }
                    tracks[x + 2] = c2
                    c3 = value(c6, c3)
                    tracks[x + 3] = c3
                    if c6 == 0x0D || c6 == 0x0B {
                        lastRow = k
                        break
                    }
                }
            }
        }

        for i in 0 ..< patternCount {
            var pattern = [UInt8](repeating: 0, count: 1024)
            for j in 0 ..< 64 {
                for k in 0 ..< 4 {
                    let from = Tracks.place(i, k, j)
                    for b in 0 ..< 4 { pattern[j * 16 + k * 4 + b] = tracks[from + b] }
                }
            }
            output.write(pattern)
        }

        file.seek(sampleData)
        for i in 0 ..< sampleCount {
            file.seek(sampleData + starts[i])
            if packed[i] {
                output.write(ThePlayer.unpackSample(ThePlayer.readWhole(&file, lengths[i] / 2)))
                continue
            }
            var sample = ThePlayer.readWhole(&file, lengths[i])
            if delta {
                // Each byte after the first was kept as how much the running sum of those before it,
                // the first not counted, is above it.
                var sum: UInt8 = 0
                var j = 1
                while j < sample.count {
                    sum = (0 &- sample[j]) &+ sum
                    sample[j] = sum
                    j += 1
                }
            }
            output.write(sample)
        }
    }
}
