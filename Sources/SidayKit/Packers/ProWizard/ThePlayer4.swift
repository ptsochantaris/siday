// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/p40.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// Modules packed by The Player 4.0a, 4.0b and 4.1a, the versions of Jarno Paananen's replayer before
/// 5.0a. A file starts with "P40A", "P40B" or "P41A", the counts, and where its tracks, its table of
/// tracks and its samples are, counted from after those four letters; then the samples' headers, in
/// an order that depends on the version. Each note is four bytes, the fourth saying how many rows are
/// empty after it or how many times more it is played; or, starting with 0x80, so many notes read
/// again from elsewhere in the tracks. Every place in the order plays a pattern of its own.
enum ThePlayer4 {
    private static let magic40A: UInt32 = 0x5034_3041
    private static let magic40B: UInt32 = 0x5034_3042
    private static let magic41A: UInt32 = 0x5034_3141

    /// ProWizard's test, which is only of the four letters. (`test_p4x`)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 8) { return more }
        let id = UInt32(truncatingIfNeeded: ProWizard.long(data, 0))
        if id != magic40A && id != magic40B && id != magic41A { return -1 }
        return 0
    }

    /// Writes a note of The Player's into the tracks as ProTracker's four bytes. (`set_event` in
    /// p40.c)
    /// - Parameters:
    ///   - note: twice the note's number in ProTracker's table, with the instrument's high bit below;
    ///     a note not in the table makes the whole note nothing, as there may be anything in the
    ///     tracks after a break.
    ///   - effect: the instrument's low four bits and the effect, as ProTracker has them.
    ///   - value: the effect's value; a slide of volume above 0x7F is turned into ProTracker's slide
    ///     up of its low four bits.
    private static func setEvent(_ tracks: inout [UInt8], _ at: Int, _ note: UInt8, _ effect: UInt8, _ value: UInt8) {
        guard at >= 0, at + 4 <= tracks.count else { return }
        var note = note, effect = effect, value = value
        var index = note & 0x7F
        if !ProWizard.isNote(Int(index / 2)) {
            index = 0
            note = 0
            effect = 0
            value = 0
        }
        tracks[at] = ((note << 4) & 0x10) | ProWizard.notes[Int(index / 2)].0
        tracks[at + 1] = ProWizard.notes[Int(index / 2)].1
        let command = effect & 0x0F
        if command == 0x08 { effect -= 0x08 }
        tracks[at + 2] = effect
        if command == 0x05 || command == 0x06 || command == 0x0A {
            value = value > 0x7F ? (value << 4) & 0xF0 : value
        }
        tracks[at + 3] = value
    }

    /// Where a row of a channel of a pattern is in the tracks, each channel's 64 rows together.
    /// (`track` in p40.c)
    private static func place(_ pattern: Int, _ channel: Int, _ row: Int) -> Int {
        (pattern * 4 + channel) * 256 + row * 4
    }

    /// Plays a note as many times more as the fourth byte of a note says, if it says so, and gives
    /// the row of the last written. (A run may go past the end of the track, where it stops.)
    private static func run(_ tracks: inout [UInt8], _ k: Int, _ i: Int, _ j: Int, _ c1: UInt8, _ c2: UInt8, _ c3: UInt8, _ c4: UInt8) -> Int {
        var k = k
        if c4 > 0x00 && c4 < 0x80 { k += Int(c4) }
        if c4 > 0x7F {
            k += 1
            var l = 256
            while l > Int(c4) {
                if k >= 64 { break }
                setEvent(&tracks, place(i, j, k), c1, c2, c3)
                k += 1
                l -= 1
            }
            k -= 1
        }
        return k
    }

    /// Unpacks a module. (`depack_p4x`)
    static func depack(_ file: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        var sampleStarts = [Int](repeating: 0, count: 31)
        var sampleLengths = [Int](repeating: 0, count: 31)

        let id = file.read32b()
        _ = file.read8()
        let length = Int(file.read8())
        if length >= 128 { throw .malformed("too long an order") }
        let sampleCount = Int(file.read8())
        if sampleCount > 31 { throw .malformed("too many samples") }
        _ = file.read8()
        // (The C adds four to each and keeps it in an int, so a place of 0xFFFFFFFC or more is taken as
        // before the start.)
        let trackData = Int(Int32(truncatingIfNeeded: file.read32b() &+ 4))
        let trackTable = Int(Int32(truncatingIfNeeded: file.read32b() &+ 4))
        let sampleData = Int(Int32(truncatingIfNeeded: file.read32b() &+ 4))
        if file.takeError() || trackData < 4 || trackTable < 4 || sampleData < 4 {
            throw .malformed("places out of the file")
        }
        let size = file.size
        if trackData >= size || trackTable >= size || sampleData >= size { throw .malformed("places out of the file") }

        output.writeZero(20)
        for i in 0 ..< sampleCount {
            let start = Int(Int32(truncatingIfNeeded: file.read32b()))
            sampleStarts[i] = start
            let words = file.read16b()
            sampleLengths[i] = Int(words) * 2
            let loopStart = Int(Int32(truncatingIfNeeded: file.read32b()))
            let loopWords = file.read16b()
            var fine: Int16 = 0
            if id == magic40A || id == magic40B { fine = Int16(bitPattern: file.read16b()) }
            _ = file.read8()
            let volume = file.read8()
            if id == magic41A { fine = Int16(bitPattern: file.read16b()) }

            if start < 0 || loopStart < 0 || loopStart < start || start > size - sampleData {
                throw .malformed("a sample out of the file")
            }

            output.writeZero(22)
            output.write16b(words)
            output.write8(UInt8(truncatingIfNeeded: Int(fine) / 74))
            output.write8(volume)
            output.write16b(UInt16(truncatingIfNeeded: (loopStart - start) / 2))
            output.write16b(loopWords)
        }
        for _ in sampleCount ..< 31 {
            output.writeZero(29)
            output.write8(1)
        }

        output.write8(UInt8(length))
        output.write8(0x7F)
        file.seek(trackTable)
        for i in 0 ..< 128 { output.write8(i < length ? UInt8(i) : 0) }
        output.write32b(ProWizard.proTrackerLetters)

        // (Kept in sixteen bits, as the C keeps them.)
        var trackStarts = [[UInt16]](repeating: [0, 0, 0, 0], count: 128)
        for i in 0 ..< length {
            for j in 0 ..< 4 { trackStarts[i][j] = UInt16(truncatingIfNeeded: Int(file.read16b()) + trackData) }
        }

        file.seek(trackData)
        var tracks = [UInt8](repeating: 0, count: 512 * 256)

        for i in 0 ..< length {
            for j in 0 ..< 4 {
                file.seek(Int(trackStarts[i][j]))
                var k = 0
                while k < 64 {
                    var c1 = file.read8()
                    var c2 = file.read8()
                    var c3 = file.read8()
                    var c4 = file.read8()

                    if c1 != 0x80 {
                        if file.takeError() { throw .malformed("read past the end") }
                        setEvent(&tracks, place(i, j, k), c1, c2, c3)
                        k = run(&tracks, k, i, j, c1, c2, c3, c4) + 1
                        continue
                    }

                    // 0x80: so many notes and more, read from another place in the tracks.
                    let resume = file.position
                    let count = Int(c2)
                    file.seek((Int(c3) << 8) + Int(c4) + trackData)
                    var c = 0
                    while c <= count {
                        if k >= 64 { break }
                        let at = place(i, j, k)
                        c1 = file.read8()
                        c2 = file.read8()
                        c3 = file.read8()
                        c4 = file.read8()
                        if file.takeError() { throw .malformed("read past the end") }
                        setEvent(&tracks, at, c1, c2, c3)
                        k = run(&tracks, k, i, j, c1, c2, c3, c4) + 1
                        c += 1
                    }
                    k -= 1
                    file.seek(resume)
                    k += 1
                }
            }
        }

        for i in 0 ..< length {
            var pattern = [UInt8](repeating: 0, count: 1024)
            for j in 0 ..< 64 {
                for k in 0 ..< 4 {
                    let from = place(i, k, j)
                    for b in 0 ..< 4 { pattern[j * 16 + k * 4 + b] = tracks[from + b] }
                }
            }
            output.write(pattern)
        }

        for i in 0 ..< sampleCount {
            file.seek(sampleStarts[i] + sampleData)
            output.write(file.read(sampleLengths[i]))
        }

        // The C forgets a read past the end here, as there is a game whose last sample runs past the
        // end of its file (The Lost Vikings).
        _ = file.takeError()
    }
}
