// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// After libxmp's loader of these modules (src/loaders/ice_load.c), Copyright (C) 1996-2021 Claudio
// Matsuoka and Hipolito Carraro Jr, used under the MIT licence (see THIRD-PARTY.md), and the converter
// UADE plays them with (Deli-Wizard's `CheckST26` and `ConvertST26`, by Nicolas Franck).

/// SoundTracker 2.6 and Ice Tracker: a ProTracker module's header, but each place
/// in the order is not a pattern but four tracks of 64 lines, one for each voice, from a store of
/// them that follows; "MTN\0" (SoundTracker 2.6) or "IT10" (Ice Tracker) where ProTracker has
/// "M.K.". It is made a ProTracker module of again with a pattern for each different four tracks the
/// order plays, as UADE's converter makes it. (A speed command with both its digits set, which
/// SoundTracker 2.6 takes as two speeds in turn from line to line, as libxmp plays it, is left as
/// ProTracker reads it; UADE's converter makes a speed and a tempo of one of more than 31. No file
/// here has one.)
enum IceTracker {
    /// Whether a file is one of these: the letters, an order no longer than ProTracker's, and every
    /// track it plays in the store. (`ice_test`, and `ice_load`'s checks)
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        if let more = ProWizard.request(size, 1468) { return more }
        let letters = ProWizard.long(data, 1464)
        if letters != 0x4D54_4E00, letters != 0x4954_3130 { return -1 }
        let length = ProWizard.byte(data, 950), tracks = ProWizard.byte(data, 951)
        if length == 0 || length > 128 { return -1 }
        for i in 0 ..< length * 4 where ProWizard.byte(data, 952 + i) >= tracks { return -1 }
        return 0
    }

    /// Makes a ProTracker module of one.
    static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        // The title and the samples' headers, as they are.
        let header = input.read(950)
        guard header.count == 950 else { throw .malformed("a SoundTracker 2.6 module cut short") }
        output.write(header)
        var sampleBytes = 0
        for i in 0 ..< 31 {
            sampleBytes += ProWizard.word(header, 20 + i * 30 + 22) * 2
        }
        let length = Int(input.read8()), tracks = Int(input.read8())
        let places = input.read(512)

        // A pattern for each different four tracks, numbered as they are first played.
        var order = [UInt8](repeating: 0, count: 128)
        var patterns: [Int] = []
        for i in 0 ..< length {
            let four = Int(places[i * 4]) << 24 | Int(places[i * 4 + 1]) << 16 | Int(places[i * 4 + 2]) << 8 | Int(places[i * 4 + 3])
            if let earlier = patterns.firstIndex(of: four) {
                order[i] = UInt8(earlier)
            } else {
                order[i] = UInt8(patterns.count)
                patterns.append(four)
            }
        }
        output.write8(UInt8(length))
        output.write8(0x7F) // NoiseTracker's restart
        output.write(order)
        output.write32b(ProWizard.proTrackerLetters)

        // The tracks, 256 bytes each, after the letters; each pattern their lines side by side.
        input.seek(1468)
        let store = input.read(tracks * 256)
        guard store.count == tracks * 256 else { throw .malformed("a SoundTracker 2.6 module cut short") }
        for four in patterns {
            let voices = [four >> 24 & 0xFF, four >> 16 & 0xFF, four >> 8 & 0xFF, four & 0xFF]
            for line in 0 ..< 64 {
                for track in voices {
                    output.write(store[(track * 256 + line * 4) ..< (track * 256 + line * 4 + 4)])
                }
            }
        }

        // The samples, as they are.
        output.move(sampleBytes, from: &input)
    }
}
