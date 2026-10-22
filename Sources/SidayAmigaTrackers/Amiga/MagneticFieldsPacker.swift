// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Read as libxmp 4.6.3 reads these files (src/loaders/mfp_load.c), Copyright (C) 1996-2021 Claudio
// Matsuoka and Hipolito Carraro Jr, used under the MIT licence (see THIRD-PARTY.md), but for its table
// of patterns, which is read as the format's own replayer reads it.

import SidayFoundation

/// A module packed by the Magnetic Fields Packer, Shaun Southern's, which some games' music was kept
/// in: a ProTracker module, its notes in one file and its samples in another (see `Companions`).
/// The song keeps the samples' particulars without their names, the order, and each voice of each
/// pattern as a tree: four bytes that each lead to four, that each lead to four, that each lead to a
/// note, so that a stretch of rows like another is kept once. It is read into the ProTracker module it
/// was, and played as one.
///
/// The table that says where each voice's tree begins has an entry for each place in the song, not
/// for each pattern: the order the song keeps beside it is the one the module had, and is not what is
/// played. (libxmp took the table to be by pattern until its release 4.7.1, and so played a song whose
/// patterns are not in the order of their numbers out of order; the format's replayer, in Wanted
/// Team's player for EaglePlayer run by UADE, plays it by place, and so does this.) Places that play
/// the same four trees share a pattern.
enum MagneticFieldsPacker {
    /// True for a file that is one of these songs, by libxmp's test: NoiseTracker's restart where it
    /// goes, samples' particulars that make sense, and the song's length given three times over.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 384, data[249] == 0x7F else { return false }
        func word(_ at: Int) -> Int { Int(data[at]) << 8 | Int(data[at + 1]) }
        for sample in 0 ..< 31 {
            let at = sample * 8
            let length = word(at), loopStart = word(at + 4), loopLength = word(at + 6)
            if length > 0x7FFF || data[at + 2] & 0xF0 != 0 || data[at + 3] > 0x40 { return false }
            if loopStart > length || loopStart + loopLength - 1 > length { return false }
            if length > 0, loopLength == 0 { return false }
        }
        return Int(data[248]) == word(378) && word(378) == word(380)
    }

    /// The ProTracker module the song and its samples were. (Without the samples the song's notes
    /// cannot be heard, and it is not played: see `Companions`.)
    static func module(_ data: [UInt8], samples: [UInt8]) throws(TuneError) -> [UInt8] {
        guard isOne(data) else { throw .malformed("not a Magnetic Fields Packer song") }
        func word(_ at: Int) -> Int { at + 1 < data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : 0 }
        let length = Int(data[248])
        guard length > 0, length <= 128 else { throw .malformed("a Magnetic Fields Packer song of no length") }
        let tableSize = word(378)
        let patternsAt = 382 + tableSize * 8
        guard length <= tableSize, patternsAt <= data.count else { throw .malformed("a Magnetic Fields Packer song cut short") }

        var module = [UInt8](repeating: 0, count: 20)
        var sampleBytes = 0
        for sample in 0 ..< 31 {
            let at = sample * 8
            module += [UInt8](repeating: 0, count: 22)
            module += data[at ..< at + 8]
            sampleBytes += word(at) * 2
        }
        // Each place's four trees; the places that have the same four, a pattern between them.
        var firstPlaces: [Int] = []
        var order: [UInt8] = []
        for place in 0 ..< length {
            let entry = data[382 + place * 8 ..< 382 + place * 8 + 8]
            if let same = firstPlaces.firstIndex(where: { data[382 + $0 * 8 ..< 382 + $0 * 8 + 8] == entry }) {
                order.append(UInt8(same))
            } else {
                order.append(UInt8(firstPlaces.count))
                firstPlaces.append(place)
            }
        }
        module += [UInt8(length), 0x7F]
        for place in 0 ..< 128 { module.append(place < length ? order[place] : 0) }
        module += [0x4D, 0x2E, 0x4B, 0x2E] // "M.K."

        // Each voice of each place, a tree of four levels, read from where the table says it begins:
        // each level a byte that says where the next is, the last where the note's four bytes are, at
        // twice its value. (As libxmp, from at most 1,024 bytes on.)
        for place in firstPlaces {
            var notes = [UInt8](repeating: 0, count: 1024)
            for voice in 0 ..< 4 {
                let start = patternsAt + word(382 + place * 8 + voice * 2)
                guard start < data.count else { throw .malformed("a Magnetic Fields Packer song cut short in its patterns") }
                let tree = data[start ..< min(data.count, start + 1024)]
                let count = tree.count
                func at(_ i: Int) -> Int { Int(tree[tree.startIndex + i]) }
                var row = 0
                for k in 0 ..< 4 {
                    for x in 0 ..< 4 {
                        for y in 0 ..< 4 {
                            guard k < count, at(k) + x < count, at(at(k) + x) + y < count,
                                  at(at(at(k) + x) + y) * 2 + 4 <= count
                            else { throw .malformed("a Magnetic Fields Packer song cut short in its patterns") }
                            let note = at(at(at(k) + x) + y) * 2
                            for b in 0 ..< 4 { notes[(row * 4 + voice) * 4 + b] = tree[tree.startIndex + note + b] }
                            row += 1
                        }
                    }
                }
            }
            module += notes
        }
        module += samples.prefix(sampleBytes)
        return module
    }
}
