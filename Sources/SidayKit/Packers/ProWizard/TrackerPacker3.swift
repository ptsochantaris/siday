// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/tp3.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// Tracker Packer, version 3, whose files begin "CPLX_TP3". The file is the title, the samples'
/// headers without their names (only as many as there are samples), the order, the places of each
/// pattern's four tracks, the tracks, and the samples. A track is a voice of a pattern, in as few
/// bytes a line as it needs: one for a run of empty lines, two for a command alone or a note alone,
/// three for both; and a slide's parameter is kept as a number with a sign, which ProTracker writes
/// as two numbers of four bits, one for up and one for down.
///
/// (ProWizard reads version 2's files, which begin "MEXX_TP2", with the same code, and there are
/// none of those among the files this is for; only version 3 is here.)
enum TrackerPacker3 {
    /// Whether a file is Tracker Packer 3's. (`test_tp3` and `test_tp23`)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 1024) { return more }
        if !data.starts(with: Array("CPLX_TP3".utf8)) { return -1 }

        // The samples' headers are eight bytes each, and there are between one and 31.
        var samples = ProWizard.word(data, 28)
        if samples == 0 || samples & 0x07 != 0 || samples >> 3 > 31 { return -1 }
        samples >>= 3

        // No finetune above 15, and no volume above 64.
        for i in 0 ..< samples {
            if ProWizard.byte(data, i * 8 + 30) > 0x0F { return -1 }
            if ProWizard.byte(data, i * 8 + 31) > 0x40 { return -1 }
        }

        // The lengths and loops fit in ProTracker's, and each loop is in its sample.
        var sampleBytes = 0
        for i in 0 ..< samples {
            let at = i * 8
            let length = ProWizard.word(data, at + 32) << 1
            let loopStart = ProWizard.word(data, at + 34) << 1
            let loopLength = ProWizard.word(data, at + 36) << 1
            if length > 0xFFFF || loopStart > 0xFFFF || loopLength > 0xFFFF { return -1 }
            if loopStart + loopLength > length + 2 { return -1 }
            if loopStart != 0 && loopLength == 0 { return -1 }
            sampleBytes += length
        }
        if sampleBytes <= 4 { return -1 }

        // Between one and 128 patterns in the order.
        let patterns = ProWizard.byte(data, samples * 8 + 31)
        if patterns == 0 || patterns > 128 { return -1 }
        return 0
    }

    /// Unpacks a file of Tracker Packer 3's. (`depack_tp3` and `depack_tp23`)
    static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        // The title, as it is.
        input.seekForgettingTheEnd(input.position + 8)
        output.move(20, from: &input)

        // The samples, which have no names. (The C keeps their number in a byte.)
        let samples = Int(UInt8(truncatingIfNeeded: input.read16b() / 8))
        var sampleBytes = 0
        for _ in 0 ..< samples {
            output.writeZero(22)
            let finetune = input.read8()
            let volume = input.read8()
            let length = input.read16b()
            output.write16b(length)
            sampleBytes += Int(length) * 2
            output.write8(finetune)
            output.write8(volume)
            output.write16b(input.read16b()) // loop start
            output.write16b(input.read16b()) // loop length
        }
        // The rest are empty, a loop of one word as ProTracker has it.
        var empty = [UInt8](repeating: 0, count: 30)
        empty[29] = 0x01
        for _ in samples ..< max(samples, 31) {
            output.write(empty)
        }

        _ = input.read8()
        let length = input.read8()
        output.write8(length)
        guard length < 128 else { throw .malformed("a Tracker Packer module with too long an order") }
        output.write8(0x7F) // NoiseTracker's restart

        // The order, as places in the list of patterns' tracks, eight bytes to a pattern. (The C keeps
        // each in a byte.)
        var order = [UInt8](repeating: 0, count: 128)
        var highest: UInt8 = 0
        for i in 0 ..< Int(length) {
            order[i] = UInt8(truncatingIfNeeded: input.read16b() / 8)
            if order[i] > highest { highest = order[i] }
        }
        guard highest < 128 else { throw .malformed("a Tracker Packer module of more than 128 patterns") }
        let patterns = Int(highest) + 1

        // Where each pattern's four tracks begin, from the end of this list; the furthest is kept to
        // find the samples by, along with the ends of the tracks.
        var tracks = [Int](repeating: 0, count: patterns * 4)
        var furthest = 0
        for i in 0 ..< patterns * 4 {
            tracks[i] = Int(input.read16b())
            if tracks[i] > furthest { furthest = tracks[i] }
        }
        output.write(order)
        output.write32b(ProWizard.proTrackerLetters)

        let tracksAt = input.position + 2
        for pattern in 0 ..< patterns {
            var unpacked = [UInt8](repeating: 0, count: 1024)
            for voice in 0 ..< 4 {
                // (A seek forgets a read past the end of the file, and so does each one here.)
                input.seekForgettingTheEnd(tracksAt + tracks[pattern * 4 + voice])
                var line = 0
                while line >= 0 && line < 64 {
                    let at = line * 16 + voice * 4
                    let first = input.read8()
                    if first & 0xC0 == 0xC0 {
                        // So many empty lines, less one.
                        line += 0x100 - Int(first) - 1
                        line += 1
                        continue
                    }
                    if first & 0xC0 == 0x80 {
                        // A command alone.
                        var command = first >> 1 & 0x0F
                        let parameter = slide(command, input.read8())
                        if command == 0x08 { command = 0x00 }
                        unpacked[at + 2] = command
                        unpacked[at + 3] = parameter
                        line += 1
                        continue
                    }

                    // A note, with the instrument's number split between the two bytes; then the
                    // command's parameter if there is a command.
                    let second = input.read8()
                    let instrument = second >> 4 & 0x0F | first >> 2 & 0x10
                    let note = Int(first & 0x40 == 0x40 ? 0x7F &- first : first & 0x3F)
                    guard ProWizard.isNote(note) else { throw .malformed("a Tracker Packer module with a note not known") }
                    var command = second & 0x0F
                    if command == 0x00 {
                        unpacked[at] = instrument & 0xF0 | ProWizard.notes[note].0
                        unpacked[at + 1] = ProWizard.notes[note].1
                        unpacked[at + 2] = instrument << 4 & 0xF0
                        line += 1
                        continue
                    }
                    let third = input.read8()
                    if command == 0x08 { command = 0x00 }
                    let parameter = slide(command, third)
                    unpacked[at] = instrument & 0xF0 | ProWizard.notes[note].0
                    unpacked[at + 1] = ProWizard.notes[note].1
                    unpacked[at + 2] = instrument << 4 & 0xF0 | command
                    unpacked[at + 3] = parameter
                    line += 1
                }
                // (The C compares the end of a track, a place in the file, with the beginnings of
                // the tracks, which are from where the tracks begin.)
                if input.position > furthest { furthest = input.position }
            }
            output.write(unpacked)
        }

        // The samples, after the furthest of those, on an even byte.
        if furthest & 0x01 != 0 { furthest += 1 }
        input.seekForgettingTheEnd(furthest)
        output.move(sampleBytes, from: &input)
    }

    /// A command's parameter as ProTracker has it: for a volume slide, alone or with a portamento or
    /// vibrato, a number with a sign becomes the four bits of the slide up or down.
    private static func slide(_ command: UInt8, _ parameter: UInt8) -> UInt8 {
        guard command == 0x05 || command == 0x06 || command == 0x0A else { return parameter }
        return parameter > 0x80 ? 0 &- parameter : parameter << 4 & 0xF0
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
