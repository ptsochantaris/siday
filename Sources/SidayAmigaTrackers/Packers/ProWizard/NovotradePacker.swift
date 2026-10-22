// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/novotrade.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

import SidayFoundation

/// Novotrade's packer, of the Hungarian developer's games. A file is in three parts, marked "MODU",
/// "BODY" and "SAMP": the first has the title, the samples used (each with its number), the order and
/// where each pattern begins; the second the patterns, each line of them a word saying which of the
/// four voices have something, followed by ProTracker's four bytes for each that does; and the third
/// the samples.
enum NovotradePacker {
    /// Whether a file is one of Novotrade's: it says so in its three marks. (`test_ntp`)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 64) { return more }
        if ProWizard.long(data, 0) != 0x4D4F_4455 { return -1 } // "MODU"

        let body = ProWizard.word(data, 20) + 4
        let samples = ProWizard.word(data, 28) + body + 4

        if let more = ProWizard.request(size, body + 4) { return more }
        if ProWizard.long(data, body) != 0x424F_4459 { return -1 } // "BODY"

        if let more = ProWizard.request(size, samples + 4) { return more }
        if ProWizard.long(data, samples) != 0x5341_4D50 { return -1 } // "SAMP"

        return 0
    }

    /// Unpacks a file of Novotrade's. (`depack_ntp`)
    static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        // Whether the last seek was to before the start of the file, which libxmp remembers until it
        // is asked or a read fails: unlike a read past the end, a seek does not clear it. (See `go`.)
        var refused = false

        _ = input.read32b() // "MODU"

        output.move(16, from: &input) // the title
        output.write32b(0)

        // (C keeps these five in numbers of sixteen bits with a sign, and so do these.)
        let body = Int(Int16(truncatingIfNeeded: Int(input.read16b()) + 4)) // where "BODY" is
        let sampleCount = Int(Int16(bitPattern: input.read16b()))
        let length = Int(Int16(bitPattern: input.read16b())) // of the order
        let patterns = Int(Int16(bitPattern: input.read16b())) // stored
        let samples = Int(Int16(truncatingIfNeeded: Int(input.read16b()) + body + 4)) // where "SAMP" is

        guard patterns <= 128, length <= 128 else { throw failure() }

        var buffer = [UInt8](repeating: 0, count: 1024)

        // The samples, each with its number, which says which of ProTracker's it is.
        // (Up to 32,767 samples can be given, and their sizes add up to more than 32 bits with a sign
        // hold; C's sum wraps round, as this one does, and a sum that has come to less than nought
        // fails, as C's copying of so many bytes does.)
        var sampleBytes: Int32 = 0
        for _ in 0 ..< max(0, sampleCount) {
            let number = Int(input.read8())
            if number > 30 {
                input.go(to: input.position + 7, &refused)
                continue
            }
            let at = number * 30
            buffer[at + 25] = input.read8() // the volume
            let size = input.read16b()
            buffer[at + 22] = UInt8(size >> 8)
            buffer[at + 23] = UInt8(size & 0xFF)
            sampleBytes &+= Int32(size) &* 2
            buffer[at + 26] = input.read8() // where the loop starts
            buffer[at + 27] = input.read8()
            buffer[at + 28] = input.read8() // how long it is
            buffer[at + 29] = input.read8()
        }
        output.write(buffer[0 ..< 930])

        output.write8(UInt8(truncatingIfNeeded: length))
        output.write8(0x7F)

        // The order.
        for at in 0 ..< 128 { buffer[at] = 0 }
        for i in 0 ..< max(0, length) {
            let pattern = Int(input.read16b())
            guard pattern < patterns else { throw failure() }
            buffer[i] = UInt8(pattern)
        }
        output.write(buffer[0 ..< 128])

        // Where each pattern begins, from the end of the mark "BODY".
        var starts = [Int](repeating: 0, count: 128)
        for i in 0 ..< max(0, patterns) { starts[i] = Int(input.read16b()) }

        output.write32b(ProWizard.proTrackerLetters)

        for i in 0 ..< max(0, patterns) {
            input.go(to: body + 4 + starts[i], &refused)
            for at in buffer.indices { buffer[at] = 0 }
            for line in 0 ..< 64 {
                let voices = input.read16b()
                for voice in 0 ..< 4 where voices & 1 << voice != 0 {
                    let note = input.read(4)
                    let at = line * 16 + voice * 4
                    buffer.replaceSubrange(at ..< at + note.count, with: note)
                }
            }
            output.write(buffer)
        }

        input.go(to: samples, &refused)
        guard sampleBytes >= 0 else { throw failure() }
        output.move(Int(sampleBytes), from: &input)
        if refused { throw failure() }
    }

    private static func failure() -> TuneError { .malformed("a Novotrade file that does not unpack") }
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
