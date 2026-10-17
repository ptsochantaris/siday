// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/np1.c, np2.c, np3.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// NoisePacker, by Twins of Phenomena, in three versions. A file begins with how many samples it has
/// and how long its order is, then each sample's description, the order (each place the pattern's
/// number times eight), and for each pattern where its four tracks begin; then the tracks, each line
/// of a voice in three bytes (a note and part of the sample, the rest of the sample and the effect,
/// and the effect's value), and the samples. The voices are kept in the reverse order, and some
/// effects' values are kept differently from ProTracker's. The third version leaves out runs of
/// empty lines, in a byte of their own, and ends a track early at a jump to the next pattern.
enum NoisePacker {
    /// Whether a file is one of NoisePacker 1's. (`test_np1`)
    static func test1(_ data: [UInt8], _ size: Int) -> Int { test12(data, size, version: 1) }

    /// Whether a file is one of NoisePacker 2's. (`test_np2`)
    static func test2(_ data: [UInt8], _ size: Int) -> Int { test12(data, size, version: 2) }

    /// The tests of the first two versions, which differ in a few of their checks. (`test_np1` and
    /// `test_np2`)
    private static func test12(_ data: [UInt8], _ size: Int, version: Int) -> Int {
        if let more = ProWizard.request(size, 10) { return more }

        // The length of the order, in bytes.
        let orderSize = ProWizard.word(data, 2)
        if orderSize == 0 || orderSize & 1 != 0 || orderSize > 0xFF { return -1 }

        // The number of samples, the low nibble of whose second byte is always 12.
        if ProWizard.byte(data, 1) & 0x0F != 0x0C { return -1 }
        let samples = ProWizard.byte(data, 0) << 4 & 0xF0 | ProWizard.byte(data, 1) >> 4 & 0x0F
        if samples == 0 || samples > 0x1F { return -1 }

        if let more = ProWizard.request(size, 15 + samples * 16) { return more }

        for i in 0 ..< samples where ProWizard.byte(data, 15 + i * 16) > 0x40 { return -1 }

        var sampleBytes = 0
        for i in 0 ..< samples {
            let at = i * 16
            let length = ProWizard.word(data, at + 12) << 1
            let start = ProWizard.word(data, at + 20) << 1
            // (The first version keeps the length of a sample's loop in bytes, the second in words.)
            let loop = version == 1 ? ProWizard.word(data, at + 22) : ProWizard.word(data, at + 22) << 1
            if length > 0xFFFF || start > 0xFFFF || loop > 0xFFFF { return -1 }
            if start + loop > length + 2 { return -1 }
            if start == 0, loop != 0 { return -1 }
            sampleBytes += length
        }
        if sampleBytes <= 4 { return -1 }

        // The header up to the end of the descriptions of the samples.
        var header = samples * 16 + 8 + 4

        if let more = ProWizard.request(size, header + orderSize + 2) { return more }

        // Each place of the order is a pattern's number times eight; the first version takes no more
        // than 127 patterns, the second 128.
        var highest = 0
        for i in stride(from: 0, to: orderSize, by: 2) {
            let place = ProWizard.word(data, header + i)
            if place & 0x07 != 0 || (version == 1 ? place >= 0x400 : place > 0x400) { return -1 }
            highest = max(highest, place)
        }

        // The header up to the end of where the tracks of the last pattern begin.
        header += orderSize + highest + 8

        let trackSize = ProWizard.word(data, 6)
        if trackSize < 192 || trackSize & 0x3F != 0 { return -1 }

        if let more = ProWizard.request(size, header + trackSize + (version == 1 ? 0 : 16)) { return more }

        for i in stride(from: 0, to: trackSize, by: 3) {
            let at = header + i
            if ProWizard.byte(data, at) > 0x49 { return -1 }
            if version == 2 {
                if ProWizard.byte(data, at) << 4 & 0x10 | ProWizard.byte(data, at + 1) >> 4 & 0x0F > samples { return -1 }
                if ProWizard.byte(data, at + 1) & 0x0F == 0, ProWizard.byte(data, at + 2) != 0 { return -1 }
            }
        }
        return 0
    }

    /// Whether a file is one of NoisePacker 3's. (`test_np3`)
    static func test3(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 10) { return more }

        let orderSize = ProWizard.word(data, 2)
        if orderSize == 0 || orderSize & 0x01 != 0 || orderSize > 0xFF { return -1 }

        if ProWizard.byte(data, 1) & 0x0F != 0x0C { return -1 }
        let samples = ProWizard.byte(data, 0) << 4 & 0xF0 | ProWizard.byte(data, 1) >> 4 & 0x0F
        if samples == 0 || samples > 0x1F { return -1 }

        if let more = ProWizard.request(size, 15 + samples * 16) { return more }

        for i in 0 ..< samples where ProWizard.byte(data, 9 + i * 16) > 0x40 { return -1 }

        var sampleBytes = 0
        for i in 0 ..< samples {
            let at = i * 16
            let length = ProWizard.word(data, at + 14) << 1
            let start = ProWizard.word(data, at + 20) << 1
            let loop = ProWizard.word(data, at + 22) << 1
            if length > 0xFFFF || start > 0xFFFF || loop > 0xFFFF { return -1 }
            if start + loop > length + 2 { return -1 }
            if start == 0, loop != 0 { return -1 }
            sampleBytes += length
        }
        if sampleBytes <= 4 { return -1 }

        var header = samples * 16 + 8 + 4

        if let more = ProWizard.request(size, header + orderSize + 2) { return more }

        var highest = 0
        for i in stride(from: 0, to: orderSize, by: 2) {
            let place = ProWizard.word(data, header + i)
            if place & 0x07 != 0 || place >= 0x400 { return -1 }
            highest = max(highest, place)
        }

        header += orderSize + highest + 8

        let trackSize = ProWizard.word(data, 6)
        if trackSize <= 63 { return -1 }

        if let more = ProWizard.request(size, header + trackSize + 2) { return more }

        // The lines of the tracks: a byte with its top bit set is a run of empty lines, and the rest
        // are lines of three bytes. Two things wrong are allowed, as Shadow Fighter's title and its
        // twelfth tune in the game each have a sample's number that is too high.
        var wrong = 0
        var i = 0
        while i < trackSize {
            let at = header + i
            let first = ProWizard.byte(data, at), second = ProWizard.byte(data, at + 1), third = ProWizard.byte(data, at + 2)
            if first & 0x80 != 0 {
                i += 1
                continue
            }
            // A note too high, or an effect of 10, which NoisePacker keeps as something else.
            if first > 0x49 || second & 0x0F == 0x0A { wrong += 1 }
            // A volume of more than 64.
            if second & 0x0F == 0x0D, third > 0x40 { wrong += 1 }
            // A sample that is not there.
            if first << 4 & 0x10 | second >> 4 & 0x0F > samples { wrong += 1 }
            // A line with nothing on it, which would have been a run of empty lines.
            if first == 0, second == 0, third == 0, i < trackSize - 3 { wrong += 1 }
            if wrong > 1 { return -1 }
            i += 3
        }
        return 0
    }

    /// Unpacks a file of NoisePacker 1's. (`depack_np1`)
    static func depack1(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        try depack12(&input, &output, version: 1)
    }

    /// Unpacks a file of NoisePacker 2's. (`depack_np2`)
    static func depack2(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        try depack12(&input, &output, version: 2)
    }

    /// The unpacking of the first two versions, which differ in where a sample's loop starts, in the
    /// number of patterns allowed, and in one effect. (`depack_np1` and `depack_np2`)
    private static func depack12(_ input: inout PackedReader, _ output: inout ModuleWriter, version: Int) throws(TuneError) {
        let first = input.read8(), second = input.read8()
        let samples = Int(first) << 4 & 0xF0 | Int(second) >> 4 & 0x0F

        output.writeZero(20) // the title

        let length = Int(input.read16b()) >> 1
        guard length <= 128 else { throw refused() }

        _ = input.read16b() // two bytes not known
        _ = input.read16b() // the size of the tracks

        var sampleBytes = 0
        for _ in 0 ..< samples {
            _ = input.read32b() // four bytes not known
            output.writeZero(22) // the name
            let size = input.read16b()
            output.write16b(size)
            sampleBytes += Int(size) * 2
            output.write8(input.read8()) // the fine tune
            output.write8(input.read8()) // the volume
            _ = input.read32b() // four bytes not known
            let loop = input.read16b()
            let start = input.read16b()
            // (The first version keeps where the loop starts in bytes, the second in words.)
            output.write16b(version == 1 ? start / 2 : start)
            output.write16b(loop)
        }
        writeEmptySamples(from: samples, &output)

        output.write8(UInt8(truncatingIfNeeded: length))
        output.write8(0x7F) // NoiseTracker's byte

        input.skip(2) // always 2?
        input.skip(2) // not known

        let (order, patterns) = readOrder(length, &input)
        // (The second version's test lets through a place of 128; the first's does not, and its
        // unpacking has no such check, but writes past the end of its table of tracks if it is.)
        guard patterns <= 128 else { throw refused() }

        output.write(order)
        output.write32b(ProWizard.proTrackerLetters)

        let (tracks, last) = readTracks(patterns, &input)
        let start = input.position

        var pattern = [UInt8](repeating: 0, count: 1024)
        for i in 0 ..< patterns {
            for at in pattern.indices { pattern[at] = 0 }
            for voice in 0 ..< 4 {
                input.seek(start + tracks[i * 4 + 3 - voice])
                for line in 0 ..< 64 {
                    let at = line * 16 + voice * 4
                    let a = input.read8()
                    var b = input.read8(), c = input.read8()
                    let note = Int(a & 0xFE) / 2
                    if input.takeError() || !ProWizard.isNote(note) { throw refused() }
                    pattern[at] = a << 4 & 0x10 | ProWizard.notes[note].0
                    pattern[at + 1] = ProWizard.notes[note].1
                    switch b & 0x0F {
                    case 0x08: b &= 0xF0
                    case 0x07:
                        b = (b & 0xF0) &+ 0x0A
                        c = slide(c)
                    case 0x06, 0x05: c = slide(c)
                    case 0x0E where version == 2: c &-= 1
                    case 0x0B: c = UInt8((Int(c) + 4) / 2)
                    default: break
                    }
                    pattern[at + 2] = b
                    pattern[at + 3] = c
                }
            }
            output.write(pattern)
        }

        input.seek(last + 192 + start)
        output.move(sampleBytes, from: &input)
    }

    /// Unpacks a file of NoisePacker 3's. (`depack_np3`)
    static func depack3(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        // (In C this buffer is not cleared first; a description of a sample cut short would leave in
        // it what was there before, but the test has seen that every description is in the file.)
        var buffer = [UInt8](repeating: 0, count: 1024)

        let first = input.read8(), second = input.read8()
        let samples = Int(first) << 4 & 0xF0 | Int(second) >> 4 & 0x0F

        output.writeZero(20) // the title

        let length = Int(input.read16b()) >> 1
        guard length <= 128 else { throw refused() }
        _ = input.read16b() // two bytes not known
        _ = input.read16b() // the size of the tracks

        var sampleBytes = 0
        for _ in 0 ..< samples {
            let description = input.read(16)
            buffer.replaceSubrange(0 ..< description.count, with: description)
            output.writeZero(22) // the name
            let size = UInt16(buffer[6]) << 8 | UInt16(buffer[7])
            output.write16b(size)
            sampleBytes += Int(size) * 2
            output.write8(buffer[0]) // the fine tune
            output.write8(buffer[1]) // the volume
            output.write(buffer[14 ..< 16]) // where the loop starts
            output.write(buffer[12 ..< 14]) // how long it is
        }
        writeEmptySamples(from: samples, &output)

        output.write8(UInt8(truncatingIfNeeded: length))
        output.write8(0x7F) // NoiseTracker's byte

        input.skip(2) // always 2?
        input.skip(2) // not known

        let (order, patterns) = readOrder(length, &input)
        // (C has no such check, and would write past the end of its table of tracks; the test lets
        // no place of more than 127 through.)
        guard patterns <= 128 else { throw refused() }

        output.write(order)
        output.write32b(ProWizard.proTrackerLetters)

        let (tracks, _) = readTracks(patterns, &input)
        let start = input.position

        // The samples follow the track that ends furthest into the file.
        var samplesAt = 0
        for i in 0 ..< patterns {
            for at in buffer.indices { buffer[at] = 0 }
            for voice in 0 ..< 4 {
                input.seek(start + tracks[i * 4 + 3 - voice])
                var line = 0
                while line < 64 {
                    let at = line * 16 + voice * 4
                    let a = input.read8()
                    // A run of empty lines. (So is a read past the end of the file, which is not
                    // noticed here: a seek forgets it.)
                    if a >= 0x80 {
                        line += 0x100 - Int(a)
                        continue
                    }
                    var b = input.read8(), c = input.read8()
                    let note = Int(a & 0xFE) / 2
                    if input.takeError() || !ProWizard.isNote(note) { throw refused() }
                    buffer[at] = a << 4 & 0x10 | ProWizard.notes[note].0
                    buffer[at + 1] = ProWizard.notes[note].1
                    switch b & 0x0F {
                    case 0x08: b &= 0xF0
                    case 0x07:
                        b = (b & 0xF0) &+ 0x0A
                        c = slide(c)
                    case 0x06, 0x05: c = slide(c)
                    case 0x0E: c = 1
                    case 0x0B: c = UInt8((Int(c) + 4) / 2)
                    default: break
                    }
                    buffer[at + 2] = b
                    buffer[at + 3] = c
                    // A jump to the next pattern ends the track.
                    if b & 0x0F == 0x0D { break }
                    line += 1
                }
                samplesAt = max(samplesAt, input.position)
            }
            output.write(buffer)
        }

        if samplesAt & 1 != 0 { samplesAt += 1 }
        input.seek(samplesAt)
        output.move(sampleBytes, from: &input)
    }

    private static func refused() -> TuneError { .malformed("a NoisePacker file that does not unpack") }

    /// The descriptions of the samples not used, up to ProTracker's 31: nothing, and a loop of a word.
    private static func writeEmptySamples(from count: Int, _ output: inout ModuleWriter) {
        var empty = [UInt8](repeating: 0, count: 30)
        empty[29] = 0x01
        for _ in min(count, 31) ..< 31 { output.write(empty) }
    }

    /// The order, each place kept as the pattern's number times eight, and the number of patterns,
    /// one more than the highest in it. (A number is kept in a byte, as C keeps it.)
    private static func readOrder(_ length: Int, _ input: inout PackedReader) -> ([UInt8], Int) {
        var order = [UInt8](repeating: 0, count: 128)
        var highest = 0
        for i in 0 ..< length {
            order[i] = UInt8(truncatingIfNeeded: input.read16b() >> 3)
            highest = max(highest, Int(order[i]))
        }
        return (order, highest + 1)
    }

    /// Where each pattern's four tracks begin, measured from the end of this table, and the furthest.
    private static func readTracks(_ patterns: Int, _ input: inout PackedReader) -> ([Int], Int) {
        var tracks = [Int](repeating: 0, count: 128 * 4)
        var last = 0
        for i in 0 ..< patterns * 4 {
            tracks[i] = Int(input.read16b())
            last = max(last, tracks[i])
        }
        return (tracks, last)
    }

    /// The value of a slide of the volume, which NoisePacker keeps as a byte with a sign (less than
    /// nought for down) and ProTracker as two nibbles, up and down.
    private static func slide(_ value: UInt8) -> UInt8 {
        value > 0x80 ? 0 &- value : value << 4
    }
}
