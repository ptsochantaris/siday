// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/ac1d.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// The AC1D packer, which marks its files with the two bytes $AC $1D. A file has the length of the
/// order, where the samples are, ProTracker's descriptions of the samples without their names, where
/// each pattern is, and the order; then the patterns, each voice of them in turn, a line in two or
/// three bytes (two when the effect is 7, as if it were none) and a run of empty lines in one; then
/// the samples.
enum AC1DPacker {
    /// Whether a file is one of AC1D's. (`test_ac1d`)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 896) { return more }

        // The mark.
        if ProWizard.byte(data, 2) != 0xAC || ProWizard.byte(data, 3) != 0x1D { return -1 }

        // The length of the order.
        if ProWizard.byte(data, 0) > 0x7F { return -1 }

        // The samples' fine tunes.
        for i in 0 ..< 31 where ProWizard.byte(data, 10 + 8 * i) > 0x0F { return -1 }

        // The order.
        for i in 0 ..< 128 where ProWizard.byte(data, 768 + i) > 0x7F { return -1 }

        return 0
    }

    /// Unpacks a file of AC1D's. (`depack_ac1d`)
    static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        // Whether the last seek was to before the start of the file, which libxmp remembers until it
        // is asked or a read fails: unlike a read past the end, a seek does not clear it. (See `go`.)
        var refused = false

        let length = input.read8()
        let noiseTrackerByte = input.read8()
        _ = input.read16b() // the mark
        let samples = Int(Int32(bitPattern: input.read32b())) // where they are

        output.writeZero(20) // the title

        var sampleBytes = 0
        for _ in 0 ..< 31 {
            output.writeZero(22) // the name
            let size = input.read16b()
            output.write16b(size)
            sampleBytes += Int(size) * 2
            output.write8(input.read8()) // the fine tune
            output.write8(input.read8()) // the volume
            output.write16b(input.read16b()) // where the loop starts
            output.write16b(input.read16b()) // how long it is
        }

        // Where each pattern is, up to the first nought. (The last before it is not a pattern.)
        var starts = [Int](repeating: 0, count: 128)
        var patterns = 0
        while patterns < 128 {
            starts[patterns] = Int(Int32(bitPattern: input.read32b()))
            if starts[patterns] == 0 { break }
            patterns += 1
        }
        guard patterns != 0 else { throw failure() }
        patterns -= 1

        output.write8(length)
        output.write8(noiseTrackerByte)

        input.go(to: 0x300, &refused) // the order
        output.move(128, from: &input)

        output.write32b(ProWizard.proTrackerLetters)

        var pattern = [UInt8](repeating: 0, count: 1024)
        for i in 0 ..< patterns {
            input.go(to: starts[i], &refused)
            _ = input.read32b() // the sizes of the first three voices
            _ = input.read32b()
            _ = input.read32b()

            for at in pattern.indices { pattern[at] = 0 }
            for voice in 0 ..< 4 {
                // A pattern that is not all in the file ends at the voice after the read past its end,
                // and so does one at a place before its start. (`hio_error`, which forgets either)
                let failed = input.takeError()
                if failed || refused {
                    refused = false
                    break
                }

                var line = 0
                while line < 64 {
                    let at = line * 16 + voice * 4
                    let first = input.read8()
                    // A run of empty lines.
                    if first & 0x80 != 0 {
                        line += Int(first & 0x7F)
                        continue
                    }

                    let second = input.read8()
                    let sample = (first & 0xC0) >> 2 | second >> 4 & 0x0F
                    // The note, 12 for the first of ProTracker's and 63 for none. One from 1 to 10
                    // comes to more than ProTracker has (as a byte, wrapping round) and is left out;
                    // nought and 11, as ProWizard has it, become the first note.
                    var note = first & 0x3F
                    if note == 0x3F {
                        note = 0xFF
                    } else if note != 0 {
                        note &-= 0x0B
                    }
                    if note == 0 { note += 1 }

                    pattern[at] = sample & 0xF0
                    if note != 0xFF, ProWizard.isNote(Int(note)) {
                        pattern[at] |= ProWizard.notes[Int(note)].0
                        pattern[at + 1] = ProWizard.notes[Int(note)].1
                    }

                    // An effect of 7 is kept in two bytes, without a value.
                    if second & 0x0F == 0x07 {
                        pattern[at + 2] = sample << 4
                        line += 1
                        continue
                    }

                    let value = input.read8()
                    pattern[at + 2] = sample << 4 | second & 0x0F
                    pattern[at + 3] = value
                    line += 1
                }
            }
            output.write(pattern)
        }

        input.go(to: samples, &refused)
        guard !refused else { throw failure() }
        output.move(sampleBytes, from: &input)
    }

    private static func failure() -> TuneError { .malformed("an AC1D file that does not unpack") }
}

fileprivate extension PackedReader {
    /// Goes to a place in the file, as `hio_seek` does, keeping what libxmp remembers of a seek to
    /// before the start in `refused`. There, fseek fails and the place stays as it was; libxmp remembers
    /// the failure as it does a read past the end, but a later seek does not clear it. Unlike the
    /// frame's mark of such a seek, it is cleared when it is asked about (`hio_error`), and a read past
    /// the end after it takes its place, which the next seek then clears; so the frame is never given
    /// a place before the start here.
    mutating func go(to place: Int, _ refused: inout Bool) {
        // (A read past the end since a refused seek has taken its place.)
        if failed { refused = false }
        if place < 0 {
            _ = takeError()
            refused = true
        } else {
            seek(place)
        }
    }
}
