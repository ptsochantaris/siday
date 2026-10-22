// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/pha.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

import SidayFoundation

/// Pha Packer. The file is the samples' headers, each with the place of its sample in the file, the
/// places of the patterns in the order, the samples, and then the patterns, which are packed: a note
/// is ProTracker's four bytes in another arrangement, its period given as its number in ProTracker's
/// table, and a voice may be told to play its last note again for so many lines more.
///
/// The order gives the patterns by where they are in the file, and the patterns are numbered again
/// here in the order of their places, with a number kept after a gap too large for one pattern to
/// have filled, for a pattern that is there but never played.
enum PhaPacker {
    /// Whether a file is Pha Packer's. (`test_pha`)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 451 + 128 * 4) { return more }

        // The first sample is just after the order, at 0x3C0.
        if ProWizard.byte(data, 10) != 0x03 || ProWizard.byte(data, 11) != 0xC0 { return -1 }

        var sampleBytes = 0
        for i in 0 ..< 31 {
            let at = i * 14
            sampleBytes += ProWizard.word(data, at) << 1
            // No volume above 64; no loop that starts past the samples so far (which is what the C
            // compares it with); and no sample before the end of the headers.
            if ProWizard.byte(data, at + 3) > 0x40 { return -1 }
            if ProWizard.word(data, at + 4) << 1 > sampleBytes { return -1 }
            if UInt32(truncatingIfNeeded: ProWizard.long(data, at + 8)) < 0x3C0 { return -1 }
        }
        if sampleBytes <= 2 || sampleBytes > 31 * 65535 { return -1 }

        // No pattern before the end of the samples. (The C reads a pattern's place into a number with
        // a sign.)
        for i in 0 ..< 128 {
            let place = Int(Int32(bitPattern: UInt32(truncatingIfNeeded: ProWizard.long(data, 448 + i * 4))))
            if place < sampleBytes + 960 - 2 { return -1 }
        }
        return 0
    }

    /// Unpacks a file of Pha Packer's. (`depack_pha`)
    static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        // No title, and the samples have no names.
        output.writeZero(20)
        var sampleBytes = 0
        for _ in 0 ..< 31 {
            output.writeZero(22)
            let length = input.read16b()
            output.write16b(length)
            sampleBytes += Int(length) * 2
            _ = input.read8()
            let volume = input.read8()
            let loopStart = input.read16b()
            let loopLength = input.read16b()
            _ = input.read32b() // where the sample is
            _ = input.read8()
            // The finetune, less 11 unless it is nought.
            var finetune = Int(input.read8())
            if finetune != 0 { finetune += 11 }
            output.write8(UInt8(truncatingIfNeeded: finetune))
            output.write8(volume)
            output.write16b(loopStart)
            output.write16b(loopLength)
        }
        input.skip(14)

        // The order, as places in the file. (The C reads each into a number with a sign.)
        var addresses = [Int](repeating: 0, count: 128)
        for i in 0 ..< 128 {
            addresses[i] = Int(Int32(bitPattern: input.read32b()))
        }

        // The places, from the lowest to the highest, each once. (The C first numbers the patterns
        // in the order they are first played, and sorts those numbers along with the places, but
        // then numbers them again from the places alone, and so the first numbering is not needed.)
        let sorted = addresses.sorted()
        var distinct = [Int](repeating: 0, count: 128)
        var last = 0
        distinct[0] = sorted[0]
        for i in 1 ..< 128 where sorted[i] != distinct[last] {
            last += 1
            distinct[last] = sorted[i]
        }

        // A pattern is 1024 bytes when unpacked, and one whose packed notes are further than that
        // from the next is taken to be followed by one that is never played, for which a number is
        // kept. (Only the first 120 places are looked at, which leaves room for eight of these.)
        var numbered = [Int](repeating: 0, count: 128)
        var count = 0
        for i in 0 ..< 120 {
            numbered[count] = distinct[i]
            count += 1
            if count >= 128 { break }
            if distinct[i + 1] - distinct[i] > 1024 {
                numbered[count] = distinct[i] + 1024
                count += 1
                if count >= 128 { break }
            }
        }

        // Each place in the order has the number of its place; of two numbers for the same place, the
        // later.
        var order = [UInt8](repeating: 0, count: 128)
        for i in 0 ..< 128 {
            for number in 0 ..< 128 where addresses[i] == numbered[number] {
                order[i] = UInt8(number)
            }
        }
        var patternsAt = 999_999
        for address in addresses where address < patternsAt {
            patternsAt = address
        }

        // The length of the order is to its last pattern other than the first, and there are as many
        // patterns as the highest number in it.
        var length = 128
        while length > 0, order[length - 1] == 0 {
            length -= 1
        }
        output.write8(UInt8(length))
        var patterns = 0
        for i in 0 ..< length where Int(order[i]) > patterns {
            patterns = Int(order[i])
        }
        patterns += 1
        output.write8(0x7F) // NoiseTracker's restart
        output.write(order)
        output.write32b(ProWizard.proTrackerLetters)

        // The patterns' notes, read for as many patterns as there are; which is more than the file
        // has if the last of them is short, and the C forgets that it read past the end.
        let samplesAt = input.position
        input.seek(patternsAt)
        let packed = input.read(patterns * 1024)
        let packedCount = packed.count
        let unpackedCount = patterns * 1024
        var unpacked = [UInt8](repeating: 0, count: unpackedCount)

        // The last note of each voice, and how many lines more it is to be played for.
        var held = [UInt8](repeating: 0, count: 16)
        var repeats = [Int](repeating: 0, count: 4)
        func put(_ at: Int, _ instrument: UInt8, _ note: UInt8, _ command: UInt8, _ parameter: UInt8) {
            unpacked[at] = instrument & 0xF0
            if ProWizard.isNote(Int(note / 2)) {
                unpacked[at] |= ProWizard.notes[Int(note / 2)].0
                unpacked[at + 1] = ProWizard.notes[Int(note / 2)].1
            }
            unpacked[at + 2] = instrument << 4 & 0xF0 | command
            unpacked[at + 3] = parameter
        }
        var i = 0, at = 0, voice = 0
        while i < packedCount, at < unpackedCount {
            if packed[i] == 0xFF {
                // How many times the note of the voice before this is to be played again.
                i += 1
                guard i < packedCount else { throw .malformed("a Pha Packer module cut short") }
                repeats[(voice + 3) % 4] = 0xFF - Int(packed[i])
                i += 1
                continue
            }
            let v = voice % 4
            if repeats[v] != 0 {
                // The voice's last note again, with nothing read.
                repeats[v] -= 1
                put(at, held[v * 4], held[v * 4 + 1], held[v * 4 + 2], held[v * 4 + 3])
                voice += 1
                at += 4
                continue
            }
            guard i + 3 < packedCount else { throw .malformed("a Pha Packer module cut short") }
            // A note: the instrument, the note's number times two, the command and its parameter.
            for b in 0 ..< 4 {
                held[v * 4 + b] = packed[i + b]
            }
            put(at, packed[i], packed[i + 1], packed[i + 2], packed[i + 3])
            i += 4
            voice += 1
            at += 4
        }
        output.write(unpacked)

        // The samples, as they are.
        input.seek(samplesAt)
        output.move(sampleBytes, from: &input)
    }
}
