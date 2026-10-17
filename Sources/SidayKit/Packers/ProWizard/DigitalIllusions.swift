// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/di.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// The packer of Digital Illusions, the Swedish group who made Pinball Dreams. A file has the number
/// of samples, where the order, the patterns and the samples are, ProTracker's descriptions of the
/// samples without their names, and where each pattern is; then the order, ended by $FF; then the
/// patterns, each line of all four voices in turn, a note in one byte when it is empty, two when it
/// has no effect's value and three when it has; then the samples.
enum DigitalIllusions {
    /// Whether a file is one of Digital Illusions'. (`test_di`)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 14) { return more }

        let samples = ProWizard.word(data, 0)
        if samples > 31 { return -1 }

        if let more = ProWizard.request(size, 14 + samples * 8) { return more }

        // The fine tunes, the volumes and the sizes of the samples.
        var sampleBytes = 0
        for i in 0 ..< samples {
            let at = i * 8
            let length = ProWizard.word(data, at + 14) << 1
            let start = ProWizard.word(data, at + 18) << 1
            let loop = ProWizard.word(data, at + 20) << 1
            if length > 0xFFFF || start > 0xFFFF || loop > 0xFFFF { return -1 }
            if start + loop > length { return -1 }
            if ProWizard.byte(data, at + 16) > 0x0F { return -1 }
            if ProWizard.byte(data, at + 17) > 0x40 { return -1 }
            sampleBytes += length
        }
        if sampleBytes <= 2 { return -1 }

        // Where the order, the patterns and the samples are, in that order, the order just after the
        // descriptions of the samples or further on. (These are numbers of 32 bits with a sign in C.)
        let header = samples * 8 + 2
        let order = Int(Int32(truncatingIfNeeded: ProWizard.long(data, 2)))
        let patterns = Int(Int32(truncatingIfNeeded: ProWizard.long(data, 6)))
        let sampleData = Int(Int32(truncatingIfNeeded: ProWizard.long(data, 10)))

        if order < header { return -1 }
        if patterns <= order || sampleData <= order || sampleData <= patterns { return -1 }
        if patterns - order > 128 { return -1 }

        // (A file cannot have as much as this, so the request could not be met; asked for, the rounding
        // of the request up to a step of 4 KB would not fit in the 32 bits of WebAssembly's numbers.)
        if patterns > Int(Int32.max) - 0x1000 { return -1 }
        if let more = ProWizard.request(size, patterns) { return more }

        // The order, which ends with $FF.
        for i in order ..< patterns - 1 where ProWizard.byte(data, i) > 0x80 { return -1 }
        if ProWizard.byte(data, patterns - 1) != 0xFF { return -1 }

        if sampleData > 65535 { return -1 }

        return 0
    }

    /// Unpacks a file of Digital Illusions'. (`depack_di`)
    static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        output.writeZero(20) // the title

        // (C keeps the number of samples in a byte.)
        let samples = Int(UInt8(truncatingIfNeeded: input.read16b()))
        guard samples <= 31 else { throw failure() }

        let orderAt = Int(Int32(bitPattern: input.read32b()))
        _ = input.read32b() // where the patterns are
        let samplesAt = Int(Int32(bitPattern: input.read32b()))

        var sampleBytes = 0
        for _ in 0 ..< samples {
            output.writeZero(22) // the name
            let size = input.read16b()
            output.write16b(size)
            sampleBytes += Int(size) * 2
            output.write8(input.read8()) // the fine tune
            output.write8(input.read8()) // the volume
            output.write16b(input.read16b()) // where the loop starts
            output.write16b(input.read16b()) // how long it is
        }
        output.writeZero((31 - samples) * 30)

        // Where each pattern is, which follows the descriptions of the samples.
        let starts = input.position
        // (Neither place can be before the start of the file, which the test has seen.)
        guard orderAt >= 0, samplesAt >= 0 else { throw failure() }
        input.seek(orderAt)

        var order = [UInt8](repeating: 0, count: 128)
        var count = 0
        var place: UInt8
        repeat {
            place = input.read8()
            // (C would write past the end of its order; the test has seen an $FF in the first 128.)
            guard count < 128 else { throw failure() }
            order[count] = place
            count += 1
        } while place != 0xFF
        order[count - 1] = 0
        output.write8(UInt8(count - 1))

        output.write8(0x7F)

        var highest: UInt8 = 0
        for place in order {
            output.write8(place)
            highest = max(highest, place)
        }
        guard highest < 128 else { throw failure() }

        output.write32b(ProWizard.proTrackerLetters)

        input.seek(starts)
        var patterns = [Int](repeating: 0, count: 128)
        for i in 0 ... Int(highest) { patterns[i] = Int(input.read16b()) }

        for i in 0 ... Int(highest) {
            input.seek(patterns[i])
            // Each line, the four voices in turn.
            for _ in 0 ..< 256 {
                let first = input.read8()
                if first & 0x80 == 0 {
                    let second = input.read8()
                    writeNote(first, second, 0, &output)
                } else if first == 0xFF {
                    output.write32b(0)
                } else {
                    let second = input.read8()
                    let value = input.read8()
                    writeNote(first, second, value, &output)
                }
            }
        }

        input.seek(samplesAt)
        output.move(sampleBytes, from: &input)
    }

    /// A note in ProTracker's four bytes, from Digital Illusions' two and the effect's value. A note
    /// higher than ProTracker's highest is left empty: ProWizard's notes say that a tune called
    /// nightmare has a note of 49. (`write_event`)
    private static func writeNote(_ first: UInt8, _ second: UInt8, _ value: UInt8, _ output: inout ModuleWriter) {
        let note = Int(first << 4 & 0x30 | second >> 4 & 0x0F)
        guard ProWizard.isNote(note) else {
            output.write32b(0)
            return
        }
        let sample = first >> 2 & 0x1F
        output.write8(ProWizard.notes[note].0 | sample & 0xF0)
        output.write8(ProWizard.notes[note].1)
        output.write8(sample << 4 | second & 0x0F)
        output.write8(value)
    }

    private static func failure() -> TuneError { .malformed("a Digital Illusions file that does not unpack") }
}
