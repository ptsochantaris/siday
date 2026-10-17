// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/gmc.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// Game Music Creator, a tracker of its own rather than a packer, whose modules were made to be
/// played in games. It has fifteen samples, an order of up to 100 patterns given as their places
/// among the patterns, and patterns as ProTracker's, but with commands numbered otherwise: 3 sets the
/// volume, 4 breaks the pattern, 5 jumps in the order, 6 and 7 turn the filter on and off, and 8 sets
/// the speed. A sample's loop is given by its length, and is at its end.
enum GameMusicCreator {
    /// Whether a file is Game Music Creator's. (`test_GMC`)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 1024) { return more }

        var sampleBytes = 0
        for i in 0 ..< 15 {
            let at = 16 * i
            // No volume above 64, and no loop longer than its sample.
            if ProWizard.byte(data, at + 7) > 0x40 { return -1 }
            let length = ProWizard.word(data, at + 4) << 1
            let loopLength = ProWizard.word(data, at + 12)
            if length > 0xFFFF { return -1 }
            if loopLength > length { return -1 }
            sampleBytes += length
        }
        if sampleBytes <= 4 { return -1 }

        // Between one and 100 patterns in the order,
        let orderLength = ProWizard.byte(data, 243)
        if orderLength > 0x64 || orderLength == 0 { return -1 }

        // and each a pattern's place, 1024 bytes apart, with more than one pattern among them.
        var patterns = 0
        var place = 0
        for i in 0 ..< 100 {
            place = ProWizard.word(data, 244 + i * 2)
            if place & 0x03FF != 0 { return -1 }
            if place >> 10 > patterns { patterns = place >> 10 }
        }
        patterns += 1
        if patterns == 1 || patterns > 100 { return -1 }

        // (The C asks for enough of the file to hold as many patterns as the place of the last in
        // the order, in bytes, says, which can be far more than the file has.)
        if let more = ProWizard.request(size, 444 + place * 1024 + 100 * 4 + 3) { return more }

        // The commands' parameters are of a sense.
        for pattern in 0 ..< patterns {
            for note in 0 ..< 256 {
                let at = 444 + pattern * 1024 + note * 4
                if let more = ProWizard.request(size, at + 4) { return more }
                if at > 0x10000 - 4 { return -1 }
                let command = ProWizard.byte(data, at + 2) & 0x0F
                let parameter = ProWizard.byte(data, at + 3)
                // No volume above 64, no break past line 99, no jump past the order's end, and the
                // filter on or off.
                if command == 3 && parameter > 0x40 { return -1 }
                if command == 4 && parameter > 0x63 { return -1 }
                if command == 5 && parameter > orderLength + 1 { return -1 }
                if command == 6 && parameter >= 0x02 { return -1 }
                if command == 7 && parameter >= 0x02 { return -1 }
            }
        }
        return 0
    }

    /// Unpacks a file of Game Music Creator's. (`depack_GMC`)
    static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        // No title, and the samples have no names.
        output.writeZero(20)
        var sampleBytes = 0
        for _ in 0 ..< 15 {
            output.writeZero(22)
            _ = input.read32b() // where the sample is
            let length = input.read16b()
            output.write16b(length)
            sampleBytes += Int(length) * 2
            _ = input.read8()
            output.write8(0) // finetune
            output.write8(input.read8()) // volume
            _ = input.read32b() // where the loop is
            // The loop, at the end of the sample; one of a word or less is none.
            let loopLength = input.read16b()
            output.write16b(loopLength > 2 ? length &- loopLength : 0)
            output.write16b(loopLength <= 2 ? 1 : loopLength)
            _ = input.read16b()
        }
        // The other sixteen are empty, a loop of one word as ProTracker has it.
        var empty = [UInt8](repeating: 0, count: 30)
        empty[29] = 0x01
        for _ in 0 ..< 16 {
            output.write(empty)
        }

        input.seekForgettingTheEnd(0xF3)
        output.write8(input.read8()) // the length of the order
        output.write8(0x7F) // NoiseTracker's restart

        // The order, from the patterns' places.
        var order = [UInt8](repeating: 0, count: 128)
        for i in 0 ..< 100 {
            order[i] = UInt8(truncatingIfNeeded: input.read16b() / 1024)
        }
        output.write(order)
        let highest = order.max() ?? 0
        output.write32b(ProWizard.proTrackerLetters)

        // The patterns, with the commands numbered as ProTracker numbers them: 3 to C, 4 to D, 5 to
        // B, 6 and 7 to E, whose parameter of nought or one then sets the filter, and 8 to F.
        input.seekForgettingTheEnd(444)
        for _ in 0 ... Int(highest) {
            var pattern = input.read(1024)
            if pattern.count < 1024 { pattern += [UInt8](repeating: 0, count: 1024 - pattern.count) }
            for note in 0 ..< 256 {
                let at = note * 4 + 2
                switch pattern[at] & 0x0F {
                case 3, 4: pattern[at] &+= 0x09
                case 5: pattern[at] &+= 0x06
                case 6: pattern[at] &+= 0x08
                case 7, 8: pattern[at] &+= 0x07
                default: break
                }
            }
            output.write(pattern)
        }

        // The samples, as they are.
        output.move(sampleBytes, from: &input)
    }
}

fileprivate extension PackedReader {
    /// Goes to a place in the file, and forgets that the file was read past its end, as libxmp's
    /// seek does on success. (`hio_seek`)
    mutating func seekForgettingTheEnd(_ place: Int) {
        self = PackedReader(data)
        seek(place)
    }
}
