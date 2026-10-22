// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/theplayer.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// Modules packed by The Player 5.0a and 6.0a, Jarno Paananen's replayer for demos and games. A file
/// has no name for itself: it starts with where its samples are, how many patterns and samples it
/// has, the samples' headers, where each pattern's four tracks start, and the order; then the tracks,
/// each note in two to four bytes, with runs of the same note and references back to rows already
/// written; then the samples, which may be kept as the differences between one byte and the next. The
/// two versions differ only in how the order counts its patterns. (6.0a could also pack the samples
/// themselves, into half their size; ProWizard does not unpack those, and they are unpacked here as
/// UADE's converter does.)
enum ThePlayer {
    /// ProWizard's test for The Player 5.0a. (`test_p50a`)
    static func test50(_ data: [UInt8], _ size: Int) -> Int {
        test(data, size, version: 0x50)
    }

    /// ProWizard's test for The Player 6.0a. (`test_p60a`)
    static func test60(_ data: [UInt8], _ size: Int) -> Int {
        test(data, size, version: 0x60)
    }

    /// Unpacks a module of The Player 5.0a. (`depack_p50a`)
    static func depack50(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        try depack(&input, &output, version: 0x50)
    }

    /// Unpacks a module of The Player 6.0a. (`depack_p60a`)
    static func depack60(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        try depack(&input, &output, version: 0x60)
    }

    /// The test both versions share: the counts, the samples' headers, where the tracks start, the
    /// order, and then every note up to the samples. (`theplayer_test`)
    private static func test(_ data: [UInt8], _ size: Int, version: Int) -> Int {
        func byte(_ at: Int) -> Int { ProWizard.byte(data, at) }
        func word(_ at: Int) -> Int { ProWizard.word(data, at) }

        if let more = ProWizard.request(size, 4) { return more }

        let patterns = byte(2)
        if patterns == 0 || patterns > 0x7F { return -1 }
        let samples = byte(3) & 0x3F
        if samples == 0 || samples > 0x1F { return -1 }
        // A module of 6.0a's with samples packed has the length of them all unpacked before the
        // samples' headers, and the top bit of a packed sample's fine tuning set. (This is UADE's
        // converter's, Deli-Wizard's `CheckP50A`; libxmp's test does not know of them.)
        let packing = version >= 0x60 && byte(3) & 0x40 != 0
        let base = packing ? 8 : 4
        let tuning = packing ? 0x7F : 0xFF

        if let more = ProWizard.request(size, samples * 6 + base) { return more }
        for i in 0 ..< samples {
            if byte(i * 6 + base + 3) > 0x40 { return -1 }
            if byte(i * 6 + base + 2) & tuning > 0x0F { return -1 }
        }

        // A size above 0xFFDF is a sample that is another's: the one so many before the last sample's
        // number.
        for i in 0 ..< samples {
            let length = word(i * 6 + base)
            if (length <= 0xFFDF && length > 0x8000) || length == 0 { return -1 }
            let start = word(i * 6 + base + 4)
            if start != 0xFFFF && start >= length { return -1 }
            if length > 0xFFDF && 0xFFFF - length > samples { return -1 }
        }

        let headers = samples * 6 + base + patterns * 8
        let sampleData = word(0)
        if sampleData < headers { return -1 }

        if let more = ProWizard.request(size, headers) { return more }
        for i in 0 ..< patterns * 4 where word(base + samples * 6 + i * 2) + headers > sampleData {
            return -1
        }

        if let more = ProWizard.request(size, headers + 128) { return more }
        var length = 0
        while length < 128 {
            let pattern = byte(headers + length)
            if pattern == 0xFF { break }
            if version >= 0x60 {
                if pattern > patterns - 1 { return -1 }
            } else {
                // The Player 5.0a counts its patterns in twos.
                if pattern & 0x01 != 0 { return -1 }
                if pattern > patterns * 2 { return -1 }
            }
            length += 1
        }
        if headers + length > sampleData { return -1 }
        if length == 0 || length == 128 { return -1 }

        // The notes, from after the order's end up to the samples: one with its top bit clear is a
        // note of three bytes, whose instrument must be one there is; any other is taken as four.
        if let more = ProWizard.request(size, sampleData + 1) { return more }
        length += 1
        var i = headers + length
        while i < sampleData {
            let first = byte(i)
            if first & 0x80 == 0 {
                if first > 0x49 { return -1 }
                let instrument = ((first << 4) & 0x10) | ((byte(i + 1) >> 4) & 0x0F)
                if instrument > samples { return -1 }
                i += 2
            } else {
                i += 3
            }
            i += 1
        }
        return 0
    }

    /// Writes a note of The Player's into the patterns as ProTracker's four bytes, and gives the
    /// number of its effect. (`set_event` in theplayer.c)
    /// - Parameters:
    ///   - note: twice the note's number in ProTracker's table, with the instrument's high bit below.
    ///   - effect: the instrument's low four bits and the effect, as ProTracker has them.
    ///   - value: the effect's value; a slide of volume is kept as a signed byte, and is turned back
    ///     into ProTracker's two halves.
    @discardableResult
    private static func setEvent(_ patterns: inout [UInt8], _ at: Int, _ note: UInt8, _ effect: UInt8, _ value: UInt8) -> UInt8 {
        guard at >= 0, at + 4 <= patterns.count else { return effect & 0x0F }
        var effect = effect, value = value
        let index = Int(note / 2)
        if ProWizard.isNote(index) {
            patterns[at] = ((note << 4) & 0x10) | ProWizard.notes[index].0
            patterns[at + 1] = ProWizard.notes[index].1
        } else {
            patterns[at] = (note << 4) & 0x10
            patterns[at + 1] = 0
        }
        let command = effect & 0x0F
        // The Player has no use for effect 8, and the packer let it stand for nothing.
        if command == 0x08 { effect -= 0x08 }
        patterns[at + 2] = effect
        if command == 0x05 || command == 0x06 || command == 0x0A {
            value = value > 0x7F ? UInt8(truncatingIfNeeded: (0x100 - Int(value)) << 4) : value
        }
        patterns[at + 3] = value
        return command
    }

    /// Where a row of a channel of a pattern is in the patterns, as ProTracker lays them out.
    private static func place(_ pattern: Int, _ channel: Int, _ row: Int) -> Int {
        pattern * 1024 + row * 16 + channel * 4
    }

    /// Reads every pattern's four tracks into ProTracker's patterns. A pattern ends at the row of the
    /// first break or jump found in any of its tracks, and tracks read after that one stop there too.
    /// (`decode_pattern`)
    private static func decodePatterns(_ file: inout PackedReader, _ count: Int, _ trackStarts: [[Int]]) -> [UInt8] {
        var patterns = [UInt8](repeating: 0, count: count * 1024)
        let tracks = file.position
        for i in 0 ..< count {
            var lastRow = 63
            for j in 0 ..< 4 {
                file.seek(trackStarts[i][j] + tracks)
                var k = 0
                while k <= lastRow {
                    // As the C's loop does, every way on to the next row counts the row. (A break
                    // counts it too, but the row is not looked at again.)
                    defer { k += 1 }
                    var c1 = file.read8()
                    let c2 = file.read8()
                    let c3 = file.read8()

                    // A note of four bytes, the fourth saying how many rows are empty after it, or how
                    // many times more it is played.
                    if c1 & 0x80 != 0 && c1 != 0x80 {
                        var c4 = file.read8()
                        c1 = 0xFF - c1
                        let effect = setEvent(&patterns, place(i, j, k), c1, c2, c3)
                        if effect == 0x0D || effect == 0x0B {
                            lastRow = k
                            break
                        }
                        if c4 < 0x80 {
                            k += Int(c4)
                            continue
                        }
                        c4 = 0 &- c4
                        for _ in 0 ..< Int(c4) {
                            k += 1
                            if k >= 64 { break }
                            setEvent(&patterns, place(i, j, k), c1, c2, c3)
                        }
                        continue
                    }

                    // 0x80: so many rows more, read again from so many bytes back.
                    if c1 == 0x80 {
                        let c4 = file.read8()
                        let resume = file.position
                        let lines = Int(c2)
                        file.skip(-((Int(c3) << 8) + Int(c4)))
                        var l = 0
                        while l <= lines && k < 64 {
                            let at = place(i, j, k)
                            var d1 = file.read8()
                            let d2 = file.read8()
                            let d3 = file.read8()
                            if d1 & 0x80 != 0 && d1 != 0x80 {
                                var d4 = file.read8()
                                d1 = 0xFF - d1
                                let effect = setEvent(&patterns, at, d1, d2, d3)
                                if effect == 0x0D || effect == 0x0B {
                                    // The C ends both loops by setting both counts past their ends.
                                    lastRow = k
                                    k = 9999 + 1
                                    l = 9999 + 1
                                    continue
                                }
                                if d4 < 0x80 {
                                    k += Int(d4) + 1
                                    l += 1
                                    continue
                                }
                                d4 = 0 &- d4
                                while d4 != 0 {
                                    d4 -= 1
                                    k += 1
                                    if k >= 64 { break }
                                    setEvent(&patterns, place(i, j, k), d1, d2, d3)
                                }
                                // (And on, to write the last of the run again.)
                            }
                            if k >= 64 { break }
                            setEvent(&patterns, place(i, j, k), d1, d2, d3)
                            l += 1
                            k += 1
                        }
                        file.seek(resume)
                        k -= 1
                        continue
                    }

                    // A note of three bytes.
                    let effect = setEvent(&patterns, place(i, j, k), c1, c2, c3)
                    if effect == 0x0D || effect == 0x0B {
                        lastRow = k
                        break
                    }
                }
            }
        }
        return patterns
    }

    /// Unpacks a module of either version. (`theplayer_depack`)
    private static func depack(_ file: inout PackedReader, _ output: inout ModuleWriter, version: Int) throws(TuneError) {
        var sizes = [Int](repeating: 0, count: 31)
        var lengths = [Int](repeating: 0, count: 31)
        var starts = [Int](repeating: 0, count: 31)
        // Which are packed (see `unpackSample`), and so how many bytes each takes in the file.
        var packed = [Bool](repeating: false, count: 31)
        var kept = [Int](repeating: 0, count: 31)

        let sampleData = Int(file.read16b())
        let patternCount = Int(file.read8())
        if patternCount > 128 { throw .malformed("too many patterns") }
        var sampleCount = Int(file.read8())
        let delta = sampleCount & 0x80 != 0
        // Samples packed, which libxmp does not unpack, are unpacked as UADE's converter does
        // (Deli-Wizard's `CheckP50A` and `P50A_Copy_Samples`): after the length of them all unpacked,
        // which is not needed, each sample's header says by the top bit of its fine tuning whether it
        // is packed.
        let packing = version >= 0x60 && sampleCount & 0x40 != 0
        if packing { _ = file.read32b() }
        sampleCount &= 0x3F
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
            } else {
                output.write16b(UInt16(truncatingIfNeeded: loop))
                output.write16b(UInt16(truncatingIfNeeded: j - loop))
            }
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
            order[length] = version >= 0x60 ? pattern : pattern / 2
            length += 1
        }
        output.write8(UInt8(length))
        output.write8(0x7F)
        output.write(order)
        output.write32b(ProWizard.proTrackerLetters)

        output.write(decodePatterns(&file, patternCount, trackStarts))

        for i in 0 ..< sampleCount {
            file.seek(sampleData + starts[i])
            if packed[i] {
                output.write(unpackSample(readWhole(&file, lengths[i] / 2)))
                continue
            }
            var sample = readWhole(&file, lengths[i])
            if delta {
                // Each byte was kept as how much the one before it is above it.
                var j = 1
                while j < sample.count {
                    sample[j] = sample[j - 1] &- sample[j]
                    j += 1
                }
            }
            output.write(sample)
        }
    }

    /// A sample The Player packed: each byte two of the sample's, its high half first, each a step
    /// down from the one before by its place in a table of steps, from nought. (Deli-Wizard's
    /// `P50A_Copy_Samples` and its `.d4tab`)
    static func unpackSample(_ bytes: [UInt8]) -> [UInt8] {
        let steps: [UInt8] = [0, 1, 2, 4, 8, 16, 32, 64, 128, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE, 0xFF]
        var sample = [UInt8](repeating: 0, count: bytes.count * 2)
        var level: UInt8 = 0
        for (k, byte) in bytes.enumerated() {
            level = level &- steps[Int(byte >> 4)]
            sample[k * 2] = level
            level = level &- steps[Int(byte & 0x0F)]
            sample[k * 2 + 1] = level
        }
        return sample
    }

    /// `count` bytes read as one piece, just after a seek: as many as there are, and noughts after
    /// them if the file ends first, which is a read past the end. (`hio_read(buffer, count, 1)` into a
    /// cleared buffer)
    static func readWhole(_ file: inout PackedReader, _ count: Int) -> [UInt8] {
        guard count > 0 else {
            // The C library counts a piece of nought bytes as no piece read, and libxmp takes that
            // as an error that a seek does not clear but a later read past the end replaces: the
            // error a seek to before the start leaves, which is how it is left here.
            file.seek(-1)
            return []
        }
        var bytes = file.read(count)
        if bytes.count < count { bytes += [UInt8](repeating: 0, count: count - bytes.count) }
        return bytes
    }
}
