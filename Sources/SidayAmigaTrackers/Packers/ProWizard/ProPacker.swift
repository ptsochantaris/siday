// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/pp21.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

import SidayFoundation

/// ProPacker: versions 2.1 and 3.0, which pack a module alike. Each voice of each pattern is a track
/// of its own, and a track that is the same as another is kept once; a track is a list of 64 places
/// in a table, and the table holds each different note of the module once, in ProTracker's own four
/// bytes. The file is the samples' headers without their names, the number of
/// patterns in the order, the order of tracks for each of the four voices, the tracks, the table, and
/// the samples. Version 3.0 differs only in giving each place in the table as the place of its first
/// byte, four times the number of the note.
///
/// The order of the patterns is not kept: each place in the order has its own pattern, made again
/// from its four tracks, and so the module unpacked is played as the packed one was, though it may be
/// larger than the one that was packed.
enum ProPacker {
    /// Whether a file is ProPacker 2.1's. (`test_pp21`)
    static func test21(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 762) { return more }
        guard let tracks = trackCount(data) else { return -1 }
        let words = tracks << 6
        if let more = ProWizard.request(size, words * 2 + 4 + 762) { return more }

        // No place in the table is above 0x4000, and the table is as long as the highest place
        // needs.
        var highest = 0
        for i in 0 ..< words {
            let place = ProWizard.word(data, i * 2 + 762)
            if place > 0x4000 { return -1 }
            if place > highest { highest = place }
        }
        // (The C compares the length, read as four bytes without a sign, with a number of its own,
        // and so compares the two without a sign.)
        let length = UInt32(truncatingIfNeeded: ProWizard.long(data, (words << 1) + 762))
        if length != UInt32((highest + 1) * 4) { return -1 }
        return 0
    }

    /// Whether a file is ProPacker 3.0's. (`test_pp30`)
    static func test30(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 762) { return more }
        guard let tracks = trackCount(data) else { return -1 }
        let words = tracks << 6
        if let more = ProWizard.request(size, words * 2 + 4 + 762) { return more }

        // Each place in the table is a multiple of four, the place of a note's first byte.
        var highest = 0
        for i in 0 ..< words {
            let place = ProWizard.word(data, i * 2 + 762)
            if place > highest { highest = place }
            if place & 0x0003 != 0 { return -1 }
        }
        highest >>= 2

        // The table is as long as the highest place needs, and no longer than 0xFFFF bytes. (The C
        // reads its length into a number with a sign: one with the highest bit set is below 0xFFFF,
        // and is then not the length wanted.)
        var notes = Int(Int32(bitPattern: UInt32(truncatingIfNeeded: ProWizard.long(data, (words << 1) + 762))))
        if notes > 0xFFFF { return -1 }
        if notes != (highest + 1) << 2 { return -1 }
        notes >>= 2
        if let more = ProWizard.request(size, notes * 4 + words * 2 + 4 + 762) { return more }

        // The notes in the table are ones ProTracker knows.
        for i in 0 ..< notes {
            let at = words * 2 + 766 + i * 4
            let command = ProWizard.byte(data, at + 2) & 0x0F
            let parameter = ProWizard.byte(data, at + 3)
            // No volume above 0x41,
            if command == 0x0C && parameter > 0x41 { return -1 }
            // no break to a line past 64, which is written in decimal, a digit to each four bits,
            if command == 0x0D && (parameter > 0x64 || parameter & 0x0F > 9) { return -1 }
            // no jump past 128,
            if command == 0x0B && parameter > 0x7F { return -1 }
            // and no sample past the 31st.
            if ProWizard.byte(data, at) & 0xF0 > 0x10 { return -1 }
        }
        return 0
    }

    /// What the two versions' tests begin with: whether the samples' headers are sound, and the
    /// number of tracks there are, one more than the highest in the order; nil if the file is not
    /// ProPacker's. (The first part of `test_pp21` and of `test_pp30`, which are the same.)
    private static func trackCount(_ data: [UInt8]) -> Int? {
        var sampleBytes = 0
        for i in 0 ..< 31 {
            let at = i * 8
            let length = ProWizard.word(data, at) << 1
            let loopStart = ProWizard.word(data, at + 4) << 1
            sampleBytes += length
            // No finetune above 15, no volume above 64, and no loop that starts past the sample's end.
            if ProWizard.byte(data, at + 2) > 0x0F { return nil }
            if ProWizard.byte(data, at + 3) > 0x40 { return nil }
            if loopStart > length { return nil }
        }
        if sampleBytes <= 2 { return nil }

        // Somewhere between one and 127 patterns in the order.
        let patterns = ProWizard.byte(data, 248)
        if patterns == 0 || patterns > 127 { return nil }

        var highest = 0
        for i in 0 ..< 512 {
            let track = ProWizard.byte(data, 250 + i)
            if track > highest { highest = track }
        }
        return highest + 1
    }

    /// Unpacks a file of ProPacker 2.1's. (`depack_pp21`)
    static func depack21(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        try depack(&input, &output, isThree: false)
    }

    /// Unpacks a file of ProPacker 3.0's. (`depack_pp30`)
    static func depack30(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        try depack(&input, &output, isThree: true)
    }

    /// Unpacks a file of either version's. (`depack_pp21_pp30`)
    private static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter, isThree: Bool) throws(TuneError) {
        // No title, and the samples have no names.
        output.writeZero(20)
        var sampleBytes = 0
        for _ in 0 ..< 31 {
            output.writeZero(22)
            let length = input.read16b()
            output.write16b(length)
            sampleBytes += Int(length) * 2
            output.write8(input.read8()) // finetune
            output.write8(input.read8()) // volume
            output.write16b(input.read16b()) // loop start
            output.write16b(input.read16b()) // loop length
        }

        let patterns = input.read8()
        guard patterns <= 128 else { throw .malformed("a ProPacker module of more than 128 patterns") }
        output.write8(patterns)
        output.write8(input.read8()) // NoiseTracker's restart

        // The tracks of each voice, one for each place in the order.
        var tracks = [UInt8](repeating: 0, count: 4 * 128)
        var highest = 0
        for voice in 0 ..< 4 {
            for place in 0 ..< 128 {
                let track = input.read8()
                tracks[voice * 128 + place] = track
                if Int(track) > highest { highest = Int(track) }
            }
        }

        // The order is each pattern in turn, one for each place.
        for place in 0 ..< Int(patterns) {
            output.write8(UInt8(place))
        }
        output.writeZero(128 - Int(patterns))
        output.write32b(ProWizard.proTrackerLetters)

        // Each track's places in the table.
        var places = [Int](repeating: 0, count: 256 * 64)
        for track in 0 ... highest {
            for line in 0 ..< 64 {
                var place = Int(input.read16b())
                if isThree { place >>= 2 }
                places[track * 64 + line] = place
            }
        }

        // The table. (The C reads its length into a number with a sign and allocates that much: a
        // length with the highest bit set cannot be allocated, and a table longer than the rest of the
        // file is not read whole; either way the file does not unpack.)
        let tableLength = Int(Int32(bitPattern: input.read32b()))
        guard tableLength != 0 else { throw .malformed("a ProPacker module without notes") }
        guard tableLength > 0, tableLength <= input.size - input.position else { throw .malformed("a ProPacker module cut short") }
        let table = input.read(tableLength)

        for place in 0 ..< Int(patterns) {
            var pattern = [UInt8](repeating: 0, count: 1024)
            for line in 0 ..< 64 {
                for voice in 0 ..< 4 {
                    let note = places[Int(tracks[voice * 128 + place]) * 64 + line] * 4
                    // (A place past the end of the table is read from past the end of the C's buffer;
                    // here it is left as no note. The tests do not let such a file through.)
                    guard note + 4 <= table.count else { continue }
                    let at = line * 16 + voice * 4
                    pattern[at ..< at + 4] = table[note ..< note + 4]
                }
            }
            output.write(pattern)
        }

        // The samples, as they are.
        output.move(sampleBytes, from: &input)
    }
}
