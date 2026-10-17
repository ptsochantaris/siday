// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/prun1.c, prun2.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// ProRunner, by Cosmos of Sanity: two versions, each with a replayer of its own.
///
/// Version 1.0 hardly packs at all. The file is a ProTracker module with "SNT." for "M.K.", and each
/// note's period given as its number in ProTracker's table, the instrument's number all in the first
/// byte.
///
/// Version 2.0, which begins "SNT!", packs each note into three bytes, or one for a line with no note
/// or for the same note as the voice had last; and drops the names of the module and its samples.
enum ProRunner {
    /// Whether a file is ProRunner 1.0's. (`test_pru1`)
    static func test1(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 1084) { return more }
        // "SNT." where ProTracker has "M.K.", or "KURT", which Ultimate Pinball Quest's modules have in
        // its place (the player's own, not ProWizard's: unpacked as if they said "SNT.", they are as
        // UADE plays them),
        if ProWizard.long(data, 1080) != 0x534E_542E, ProWizard.long(data, 1080) != 0x4B55_5254 { return -1 }
        // NoiseTracker's restart where ProTracker has 127,
        if ProWizard.byte(data, 951) != 0x7F { return -1 }
        // and no more than 127 patterns in the order.
        if ProWizard.byte(data, 950) > 0x7F { return -1 }
        return 0
    }

    /// Unpacks a file of ProRunner 1.0's. (`depack_pru1`)
    static func depack1(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        // The title and the samples' headers, as they are.
        let header = padded(input.read(950), to: 950)
        output.write(header)
        var sampleBytes = 0
        for i in 0 ..< 31 {
            sampleBytes += ProWizard.word(header, i * 30 + 42) * 2
        }

        // The length of the order, NoiseTracker's restart and the order, as they are.
        output.write8(input.read8())
        let order = padded(input.read(129), to: 129)
        output.write(order)
        output.write32b(ProWizard.proTrackerLetters)
        var highest: UInt8 = 0
        for i in 1 ..< 129 where order[i] > highest {
            highest = order[i]
        }

        // The patterns: each note is the instrument's number, the note's number in ProTracker's
        // table, the command, and its parameter.
        input.seek(1084)
        for _ in 0 ... Int(highest) {
            for _ in 0 ..< 256 {
                let instrument = input.read8()
                let note = Int(input.read8())
                let command = input.read8()
                let parameter = input.read8()
                guard ProWizard.isNote(note) else { throw .malformed("a ProRunner module with a note not known") }
                output.write8(instrument & 0xF0 | ProWizard.notes[note].0)
                output.write8(ProWizard.notes[note].1)
                output.write8((instrument & 0x0F) << 4 | command)
                output.write8(parameter)
            }
        }

        // The samples, as they are.
        output.move(sampleBytes, from: &input)
    }

    /// Whether a file is ProRunner 2.0's. (`test_pru2`)
    static func test2(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 12 + 31 * 8) { return more }
        // "SNT!"
        if ProWizard.long(data, 0) != 0x534E_5421 { return -1 }
        // No volume above 64,
        for i in 0 ..< 31 where ProWizard.byte(data, 11 + i * 8) > 0x40 {
            return -1
        }
        // and no finetune above 15.
        for i in 0 ..< 31 where ProWizard.byte(data, 10 + i * 8) > 0x0F {
            return -1
        }
        return 0
    }

    /// Unpacks a file of ProRunner 2.0's. (`depack_pru2`)
    static func depack2(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        // No title, and the samples have no names.
        output.writeZero(20)
        input.seek(8)
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

        output.write8(input.read8()) // the length of the order
        output.write8(input.read8()) // NoiseTracker's restart
        var highest: UInt8 = 0
        for _ in 0 ..< 128 {
            let pattern = input.read8()
            output.write8(pattern)
            if pattern > highest { highest = pattern }
        }
        output.write32b(ProWizard.proTrackerLetters)

        // The patterns. A line of a voice is 0x80 for nothing, 0xC0 for the voice's last note again,
        // or three bytes: the note's number in ProTracker's table times two, with the lowest bit of
        // the instrument's number; the rest of the instrument and the command; and the parameter.
        var last = [UInt8](repeating: 0, count: 16)
        input.seek(770)
        for _ in 0 ... Int(highest) {
            for line in 0 ..< 256 {
                let voice = line & 3
                let first = input.read8()
                if first == 0x80 {
                    output.write32b(0)
                } else if first == 0xC0 {
                    output.write(last[voice * 4 ..< voice * 4 + 4])
                } else if !ProWizard.isNote(Int(first >> 1)) {
                    throw .malformed("a ProRunner module with a note not known")
                } else {
                    let second = input.read8()
                    let third = input.read8()
                    let note = Int(first >> 1)
                    let bytes: [UInt8] = [
                        (second & 0x80) >> 3 | ProWizard.notes[note].0,
                        ProWizard.notes[note].1,
                        (second & 0x70) << 1 | (first & 0x01) << 4 | second & 0x0F,
                        third,
                    ]
                    output.write(bytes)
                    last[voice * 4 ..< voice * 4 + 4] = bytes[0 ..< 4]
                }
            }
        }

        // The samples, as they are.
        output.move(sampleBytes, from: &input)
    }

    /// What was read, with noughts after it to make it as long as was asked for, as a read into a
    /// buffer cleared beforehand leaves it.
    private static func padded(_ bytes: [UInt8], to count: Int) -> [UInt8] {
        bytes.count < count ? bytes + [UInt8](repeating: 0, count: count - bytes.count) : bytes
    }
}
