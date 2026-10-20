// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/pm18a.c), Copyright (C) 1997 Asle / ReDoX,
// modified by Claudio Matsuoka and Alice Rowan, used under the MIT licence (see THIRD-PARTY.md).

/// Promizer 1.8a, by MC68000 of Masters. The file begins with Promizer's own replayer, 4,460 bytes
/// of it; then where the samples are, the samples' headers, the order as the places of its patterns,
/// the patterns, a table of the different notes they play, and the samples. A note in a pattern is
/// two bytes, its number in the table, where each is ProTracker's four bytes; and a note's period is
/// written for its sample's fine tuning, which ProTracker's module gives as the period with none.
enum Promizer {
    /// Whether a file is Promizer 1.8a's: its replayer's first instructions, and the byte of it that
    /// says which Promizer it is. (`test_p18a`)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 22) { return more }
        let replayer: [UInt8] = [0x60, 0x38, 0x60, 0x00, 0x00, 0xA0, 0x60, 0x00, 0x01, 0x3E, 0x60, 0x00, 0x01, 0x0C, 0x48, 0xE7]
        for i in 0 ..< 16 where ProWizard.byte(data, i) != Int(replayer[i]) { return -1 }
        if ProWizard.byte(data, 21) != 0xD2 { return -1 }

        // The length of the order, as the places of its patterns: four bytes for each.
        if let more = ProWizard.request(size, 4714) { return more }
        if ProWizard.word(data, 4712) & 0x03 != 0 { return -1 }
        if ProWizard.byte(data, 36) != 0x11 || ProWizard.byte(data, 37) != 0x00 { return -1 }
        return 0
    }

    /// Unpacks a file of Promizer 1.8a's. (`depack_p18a`)
    static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        output.writeZero(20) // the title

        // Past the replayer, how long the patterns are, and the samples' headers.
        input.seek(4460)
        let patternBytes = Int(Int32(bitPattern: input.read32b()))
        guard patternBytes >= 0 else { throw .malformed("a Promizer module with no patterns") }
        var tunings = [Int](repeating: 0, count: 31)
        var sampleBytes = 0
        for i in 0 ..< 31 {
            output.writeZero(22) // the sample's name
            let length = input.read16b()
            output.write16b(length)
            sampleBytes += Int(length) * 2
            let tuning = input.read8()
            tunings[i] = Int(tuning)
            output.write8(tuning)
            output.write8(input.read8()) // the volume
            output.write16b(input.read16b()) // where its loop begins
            output.write16b(input.read16b()) // and its length
        }

        let length = Int(input.read16b()) / 4
        guard length <= 128 else { throw .malformed("a Promizer module with too long an order") }
        output.write8(UInt8(length))
        output.write8(0x7F) // NoiseTracker's restart

        // The order, as the places of the patterns after the start of them (5,226 bytes in).
        var places = [Int](repeating: 0, count: 128)
        for i in 0 ..< 128 {
            places[i] = Int(Int32(bitPattern: input.read32b()))
            guard places[i] >= 0, places[i] - 5226 <= patternBytes else {
                throw .malformed("a Promizer module with a pattern out of place")
            }
        }

        // The patterns numbered in the order they are first played. Each is unpacked from the place
        // where it is first played. (libxmp's takes the pattern of each number from that place in the
        // order instead, and so plays the wrong patterns of a song that plays one again before the
        // last is first heard; UADE's converter, Deli-Wizard's, plays them as here.)
        var order = [UInt8](repeating: 0, count: 128)
        var firstPlaces = [0]
        for i in 1 ..< max(1, length) {
            if let earlier = (0 ..< i).first(where: { places[$0] == places[i] }) {
                order[i] = order[earlier]
            } else {
                order[i] = UInt8(firstPlaces.count)
                firstPlaces.append(places[i])
            }
        }
        output.write(order)
        output.write32b(ProWizard.proTrackerLetters)

        // The highest number any note has in the table, to know how long the table is.
        var highest = 0
        for _ in stride(from: 0, to: patternBytes, by: 2) {
            let number = Int(input.read16b())
            if input.takeError() { throw .malformed("a Promizer module cut short") }
            highest = max(highest, number)
        }
        let table = input.read((highest + 1) * 4)
        guard table.count == (highest + 1) * 4 else { throw .malformed("a Promizer module cut short") }

        // The patterns: each note from the table, its period put back to the one with no fine tuning,
        // and the rest of a pattern left empty after a line that jumps or breaks.
        var lastInstruments = [Int](repeating: 0, count: 4)
        for place in firstPlaces {
            var pattern = [UInt8](repeating: 0, count: 1024)
            input.seek(place + 5226)
            lines: for line in 0 ..< 64 {
                var ends = false
                for voice in 0 ..< 4 {
                    let at = line * 16 + voice * 4
                    let number = Int(input.read16b()) << 2
                    if number >= table.count || input.takeError() { throw .malformed("a Promizer module with a note not known") }
                    for b in 0 ..< 4 {
                        pattern[at + b] = table[number + b]
                    }
                    let instrument = Int(pattern[at + 2]) >> 4 & 0x0F | Int(pattern[at]) & 0xF0
                    if instrument != 0 { lastInstruments[voice] = instrument }
                    let period = (Int(pattern[at]) & 0x0F) << 8 | Int(pattern[at + 1])
                    let command = pattern[at + 2] & 0x0F
                    let last = lastInstruments[voice]
                    let tuning = last > 0 && last < 32 ? tunings[last - 1] : 0
                    guard tuning < 16 else { throw .malformed("a Promizer module with a sample tuned out of range") }
                    if period != 0, last > 0, tuning != 0 {
                        for note in 0 ..< 36 where Int(proTrackerPeriods[tuning * 37 + note]) == period {
                            pattern[at] = pattern[at] & 0xF0 | ProWizard.notes[note + 1].0
                            pattern[at + 1] = ProWizard.notes[note + 1].1
                            break
                        }
                    }
                    if command == 0x0D || command == 0x0B { ends = true }
                }
                if ends { break lines }
            }
            output.write(pattern)
        }

        // The samples, where the file says they are.
        input.seek(4456)
        let samplesAt = Int(Int32(bitPattern: input.read32b()))
        input.seek(4460 + samplesAt)
        output.move(sampleBytes, from: &input)
    }
}
