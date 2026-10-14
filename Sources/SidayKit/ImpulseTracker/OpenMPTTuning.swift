// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors, used
// under the BSD 3-Clause licence (see THIRD-PARTY.md): its tunings (`soundlib/tuning.cpp`).

/// A scale an instrument of an MPTM file can be tuned to, in place of the twelve equal steps to the
/// octave that a module's notes otherwise are: as OpenMPT reads one from the file and works out its
/// pitches, in its arithmetic, which is of 32-bit floating point.
///
/// A scale gives each of its notes a ratio to middle C, and between each note and the next it has
/// so many "fine steps", which are what OpenMPT slides such an instrument's notes by. It is of one of
/// three kinds: every note given ("general"); a group of notes given, and every other note that group
/// again, higher or lower by the group's ratio (a twelve-note scale repeated at the octave, say);
/// and every step the same, so many to a ratio ("geometric": 24 to the octave, or 11 to an octave
/// and a fifth).
struct OpenMPTTuning {
    enum Kind: Int {
        case general = 0, groupGeometric = 1, geometric = 3
    }

    let kind: Kind
    /// The lowest note the table has, counted from middle C.
    let lowest: Int
    /// The ratio of each note to middle C, from `lowest` up.
    let ratios: [Float]
    /// How many notes to a group, for the two kinds that have one.
    let groupSize: Int
    /// How many fine steps lie between a note and the next: so many and one more go from the one to the other.
    let fineSteps: Int
    /// What each fine step from a note makes of it, for the two kinds that have groups and not too many
    /// steps between them; for a group, those of each of its notes in turn.
    let fineRatios: [Float]

    /// OpenMPT's ratio for a note there is none for.
    private static let fallback: Float = 1

    /// The scale as OpenMPT makes it from what the file says, or nil where OpenMPT would not read it.
    ///   - kind: the file's number for it.
    ///   - given: the ratios the file holds: every note's, or the group's, or none.
    ///   - lowest: the note the table starts at; `notes`, how many it has, for the kinds with groups.
    init?(kind number: Int, given: [Float], lowest: Int, notes: Int, groupSize: Int, groupRatio: Float, fineSteps: Int) {
        guard let kind = Kind(rawValue: number), groupRatio.isFinite, !given.contains(where: { !$0.isFinite }), lowest >= -300, lowest <= 300 else { return nil }
        let groupRatio = min(max(abs(groupRatio), 1e-15), 1e7)
        self.kind = kind
        self.lowest = lowest
        self.fineSteps = min(max(fineSteps, 0), 0xFFFF)
        var ratios: [Float]
        var size = groupSize
        switch kind {
        case .general:
            ratios = given
        case .groupGeometric:
            // The group is put at the bottom of the table, and each note above it is the note a
            // group below times the group's ratio.
            guard notes >= 1, notes <= 0x7FFF, !given.isEmpty, given.count <= notes, !given.contains(where: { $0 < 0 }) else { return nil }
            size = given.count
            ratios = given + [Float](repeating: 0, count: notes - given.count)
            for i in size ..< notes { ratios[i] = groupRatio * ratios[i - size] }
        case .geometric:
            guard notes >= 1, notes <= 0x7FFF, groupSize >= 1, groupRatio > 0.02 else { return nil }
            let step = powf(groupRatio, 1 / Float(groupSize))
            ratios = (0 ..< notes).map { powf(step, Float(lowest + $0)) }
        }
        self.ratios = ratios
        self.groupSize = size
        fineRatios = Self.fineRatios(kind, ratios, lowest: lowest, groupSize: size, fineSteps: self.fineSteps)
    }

    /// OpenMPT's table of what the fine steps from a note make of it, where it keeps one.
    private static func fineRatios(_ kind: Kind, _ ratios: [Float], lowest: Int, groupSize: Int, fineSteps: Int) -> [Float] {
        guard fineSteps > 0 else { return [] }
        func ratio(_ note: Int) -> Float {
            let index = note - lowest
            guard index >= 0, index < ratios.count, ratios[index] > 1e-15 else { return fallback }
            return ratios[index]
        }
        switch kind {
        case .general:
            return []
        case .geometric:
            guard fineSteps <= 1000 else { return [] }
            let step = powf(ratio(lowest + 1) / ratio(lowest), 1 / Float(fineSteps + 1))
            return (1 ... fineSteps).map { powf(step, Float($0)) }
        case .groupGeometric:
            guard groupSize <= 1000 / fineSteps else { return [] }
            var table = [Float](repeating: 0, count: groupSize * fineSteps)
            // (Each note of the group is taken at its place in the group, from nought.)
            for note in 0 ..< groupSize {
                let step = powf(ratio(note + 1) / ratio(note), 1 / Float(fineSteps + 1))
                for j in 1 ... fineSteps { table[fineSteps * note + j - 1] = powf(step, Float(j)) }
            }
            return table
        }
    }

    private func has(_ note: Int) -> Bool { note >= lowest && note < lowest + ratios.count }

    /// What the scale makes of a note, counted from middle C.
    func ratio(_ note: Int) -> Float {
        guard has(note), ratios[note - lowest] > 1e-15 else { return Self.fallback }
        return ratios[note - lowest]
    }

    /// What the scale makes of a note and so many fine steps from it, either way.
    func ratio(_ note: Int, fine: Int) -> Float {
        if fineSteps == 0 || fine == 0 { return ratio(note + fine) }
        // (A fine step below a note is the last one above the note below it.)
        let per = fineSteps + 1
        let whole = fine >= 0 ? fine / per : -((-fine + per - 1) / per)
        let note = note + whole, step = fine - whole * per
        guard has(note) else { return Self.fallback }
        if step == 0 { return ratios[note - lowest] }
        let fineRatio: Float
        if kind == .geometric, !fineRatios.isEmpty {
            fineRatio = fineRatios[step - 1]
        } else if kind == .groupGeometric, !fineRatios.isEmpty {
            let place = note >= 0 ? note % groupSize : (groupSize - (-note % groupSize)) % groupSize
            fineRatio = fineRatios[place * fineSteps + step - 1]
        } else {
            fineRatio = powf(ratio(note + 1) / ratio(note), Float(step) / Float(per))
        }
        return ratios[note - lowest] * fineRatio
    }
}

/// OpenMPT's wave for a sample's vibrato "at random", which is a table it goes round.
let openMPTRandomWave: [Int8] = [
    98, -127, -43, 88, 102, 41, -65, -94, 125, 20, -71, -86, -70, -32, -16, -96,
    17, 72, 107, -5, 116, -69, -62, -40, 10, -61, 65, 109, -18, -38, -13, -76,
    -23, 88, 21, -94, 8, 106, 21, -112, 6, 109, 20, -88, -30, 9, -127, 118,
    42, -34, 89, -4, -51, -72, 21, -29, 112, 123, 84, -101, -92, 98, -54, -95,
]

/// OpenMPT's sine for a vibrato in its own way, which is ProTracker's (see `OpenMPTSong.itVibrato`).
let openMPTSineWave: [Int8] = [
    0, 12, 25, 37, 49, 60, 71, 81, 90, 98, 106, 112, 117, 122, 125, 126,
    127, 126, 125, 122, 117, 112, 106, 98, 90, 81, 71, 60, 49, 37, 25, 12,
    0, -12, -25, -37, -49, -60, -71, -81, -90, -98, -106, -112, -117, -122, -125, -126,
    -127, -126, -125, -122, -117, -112, -106, -98, -90, -81, -71, -60, -49, -37, -25, -12,
]
