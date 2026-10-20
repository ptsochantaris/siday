// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// After libxmp's reading of these files (src/loaders/mmd1_load.c), Copyright (C) 1996-2021 Claudio
// Matsuoka and Hipolito Carraro Jr, used under the MIT licence (see THIRD-PARTY.md).

/// A MED module packed for a game ("MED Packer", whose player Wanted Team took from Knightmare and
/// credit to Antony 'Ratt' Crowther, 1991): an MMD0 module, "MMDC" where it says "MMD0", each of whose
/// blocks has its notes packed. The packing is of runs: a byte with its top bit set is so many noughts
/// (256 less it), and any other is so many bytes, one more than it, kept as they are.
enum MMDCFile {
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 52 && data[0] == 0x4D && data[1] == 0x4D && data[2] == 0x44 && data[3] == 0x43
    }

    /// The MMD0 module it was packed from: its blocks unpacked, each put after the end of the file,
    /// and the list of them made to point there; the rest, the samples too, where it was.
    static func mmd0(_ data: [UInt8]) throws(TuneError) -> [UInt8] {
        func long(_ at: Int) -> Int {
            guard at >= 0, at + 4 <= data.count else { return 0 }
            return Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3])
        }
        var file = data
        file[3] = 0x30
        let song = long(8), blocks = long(16)
        guard song > 0, song + 506 <= data.count, blocks > 0 else { throw .malformed("a MED module packed with MMDC with no song") }
        let count = Int(data[song + 504]) << 8 | Int(data[song + 505])
        for number in 0 ..< count {
            let pointer = blocks + number * 4
            let at = long(pointer)
            guard pointer + 4 <= data.count, at > 0, at + 2 <= data.count else { continue }
            let tracks = Int(data[at]), lines = Int(data[at + 1])
            let size = tracks * (lines + 1) * 3
            var notes = [UInt8](repeating: 0, count: size)
            var from = at + 2, to = 0
            while to < size {
                guard from < data.count else { throw .malformed("a MED module packed with MMDC cut short") }
                let pack = Int(data[from])
                from += 1
                if pack & 0x80 != 0 {
                    to += 256 - pack
                    continue
                }
                let run = min(pack + 1, size - to)
                guard from + run <= data.count else { throw .malformed("a MED module packed with MMDC cut short") }
                notes.replaceSubrange(to ..< to + run, with: data[from ..< from + run])
                from += run
                to += run
            }
            if file.count & 1 != 0 { file.append(0) }
            let place = file.count
            file.append(contentsOf: [UInt8(tracks), UInt8(lines)])
            file.append(contentsOf: notes)
            for i in 0 ..< 4 { file[pointer + i] = UInt8(truncatingIfNeeded: place >> (24 - i * 8)) }
        }
        return file
    }
}
