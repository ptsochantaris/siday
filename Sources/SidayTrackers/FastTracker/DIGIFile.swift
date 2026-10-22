// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the DIGI loader of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see
// THIRD-PARTY.md).

import SidayFoundation

/// A module of DIGI Booster, Tomasz and Waldemar Piasta's tracker for the Amiga, in its versions
/// before DigiBooster Pro: a file that begins "DIGI Booster module".
///
/// It is a MOD file widened to eight channels, which the tracker mixed two to each of the Amiga's
/// four voices, with samples as long as they like: the same 31 samples with a volume and a fine
/// tuning, the same patterns of 64 rows of periods and ProTracker's commands, and a few commands of
/// its own. A pattern may be packed, a row at a time, with a byte to say which channels have
/// anything; one that is not packed has its channels one after another, and not its rows.
///
/// This player has no replayer of DIGI Booster's. The file is read into what FastTracker 2 plays
/// (see `ForeignModule`), which plays ProTracker's commands on more than four channels with the
/// slides and the memory of their values that OpenMPT plays these files with; and DIGI Booster's
/// own ways are played as OpenMPT plays them (`ForeignModule.playsAsDigiBooster`).
enum DIGIFile {
    private static let headerLength = 610, patternsAt = 610 + 32 + 31 * 30

    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= headerLength && data.starts(with: Array("DIGI Booster module".utf8)) && data[19] == 0
    }

    static func read(_ data: [UInt8]) throws -> ForeignModule {
        guard isOne(data) else { throw TuneError.malformed("not a DIGI Booster module") }
        let f = ByteReader(data)
        let channels = Int(data[25]), packed = data[26] != 0, patternCount = Int(data[46]) + 1, orderCount = Int(data[47]) + 1
        guard channels >= 1, channels <= 8, orderCount <= 128 else {
            throw TuneError.malformed("a DIGI Booster module with more channels or orders than DIGI Booster had")
        }
        var module = ForeignModule(format: "DIGI")
        let version = data[24]
        module.tracker = "DIGI Booster \(version >> 4).\(version & 15)"
        module.title = f.dos(at: headerLength, length: 32)
        module.channels = channels
        module.orders = (0 ..< orderCount).map { data[48 + $0] }
        // OpenMPT has the channels all in the middle, as FastTracker plays a MOD file's.
        module.panning = [UInt8](repeating: 128, count: channels)
        module.playsAsDigiBooster = true
        module.loudness = loudness

        // MARK: Samples

        var at = patternsAt
        // (The patterns come first, and the samples after them.)
        var patternBytes: [(start: Int, length: Int)] = []
        for _ in 0 ..< patternCount {
            let length = packed ? f.u16be(at) : 4 * 64 * channels
            if packed { at += 2 }
            patternBytes.append((at, length))
            at += length
        }
        var cutShort = Shortfall.CutShort()
        var samples: [ForeignModule.Sample?] = []
        for index in 0 ..< 31 {
            let length = f.size32be(176 + index * 4)
            var sample = ForeignModule.Sample()
            sample.data = f.sample(at: at, length: length)
            cutShort.add(length: length, there: data.count - at)
            at += min(length, max(0, data.count - at))
            let loopStart = f.size32be(300 + index * 4), loopLength = f.size32be(424 + index * 4)
            let loopEnd = min(sample.data.count, loopStart + loopLength)
            if loopLength > 0, loopEnd > loopStart {
                sample.repeatStart = loopStart
                sample.repeatLength = loopEnd - loopStart
            }
            sample.volume = min(64, data[548 + index])
            // A fine tuning of ProTracker's, in eighths of a semitone from -8 to 7, made FastTracker's.
            sample.fineTune = Int8(truncatingIfNeeded: 8 * ((2 * (Int(data[579 + index] & 15) ^ 8)) - 16))
            samples.append(sample.data.isEmpty ? nil : sample)
        }

        // MARK: Patterns

        var found = Found()
        var reversed: [Reversal: UInt8] = [:]
        // The speed and tempo as the patterns are gone through, for how long a note lasts in rows.
        var speed = 6, tempo = 125
        for (start, length) in patternBytes {
            var notes = [FT2Note](repeating: FT2Note(), count: 64 * channels)
            var cell = start
            func entry(_ row: Int, _ channel: Int) {
                notes[row * channels + channel] = note(f, cell, &found)
                cell += 4
            }
            if packed {
                // A byte for each row, a bit for each channel from the top, says which have a note.
                cell = start + 64
                for row in 0 ..< 64 {
                    let mask = f[start + row]
                    for channel in 0 ..< channels where mask & (0x80 >> UInt8(channel)) != 0 { entry(row, channel) }
                }
                if cell > start + length { found.cutShort = true }
            } else {
                for channel in 0 ..< channels {
                    for row in 0 ..< 64 { entry(row, channel) }
                }
            }
            // A sample played backwards is a sample of its own, its sound turned round.
            for row in 0 ..< 64 {
                for channel in 0 ..< channels where notes[row * channels + channel].effTyp == 0xF {
                    let value = Int(notes[row * channels + channel].eff)
                    if value < 0x20 { speed = value } else { tempo = value }
                }
                for channel in 0 ..< channels {
                    let i = row * channels + channel
                    guard notes[i].effTyp == backwards else { continue }
                    let loops = notes[i].eff != 0
                    // DIGI Booster turned a note on one of a voice's two channels round again when a
                    // note started on the other; on the same row, after it, that is at once, and a
                    // note that does not go round runs off its end: it is not heard.
                    if !loops, channel & 1 == 0, channel + 1 < channels, notes[i + 1].ton != 0 {
                        notes[i].effTyp = 0xE
                        notes[i].eff = 0xC0
                        continue
                    }
                    notes[i].effTyp = 0
                    notes[i].eff = 0
                    // (Of the note beside it, and its sample, which it is always written with.)
                    let instrument = Int(notes[i].instr)
                    guard notes[i].ton != 0, instrument >= 1, instrument <= 31, let sample = samples[instrument - 1] else {
                        found.backwardsLeftOut += 1
                        continue
                    }
                    let key = Reversal(sample: instrument, loops: loops)
                    if reversed[key] == nil, samples.count < 128 {
                        var turned = sample
                        turned.data = sample.data.reversed()
                        // Back to its start, and then, if asked, back and forth over the whole of it.
                        turned.repeatStart = 0
                        turned.repeatLength = loops ? turned.data.count : 0
                        turned.backAndForth = loops
                        samples.append(turned)
                        reversed[key] = UInt8(samples.count)
                    }
                    guard let number = reversed[key] else {
                        found.backwardsLeftOut += 1
                        continue
                    }
                    notes[i].instr = number
                    // On a later row that is not done: the note goes on backwards, if it has not
                    // come to its end by then. (How long it lasts is reckoned from its period and
                    // the speed and tempo of the patterns as they come in the file.)
                    let period = Double(ft2AmigaPeriod[max(0, min(95, Int(notes[i].ton) - 1))])
                    let seconds = loops ? Double.infinity : Double(sample.data.count) * period / 3_546_895
                    let rows = Int(min(64, seconds / (Double(max(1, speed)) * 2.5 / Double(max(32, tempo)))))
                    for later in row + 1 ..< min(64, row + 1 + rows) {
                        let mine = notes[later * channels + channel], beside = notes[later * channels + (channel ^ 1)]
                        if mine.ton != 0 { break }
                        if channel ^ 1 < channels, beside.ton != 0 {
                            found.turnedRound = true
                            break
                        }
                    }
                }
            }
            module.patterns.append(ForeignModule.Pattern(rows: 64, notes: notes))
        }
        module.samples = samples
        found.cutShort = found.cutShort || cutShort.sentence != nil
        module.shortfalls = found.sentences(cutShort)
        return module
    }

    /// A sample turned round, as one of its own: which, and whether it goes back and forth after.
    private struct Reversal: Hashable {
        var sample: Int, loops: Bool
    }

    /// A command number that no command has, for E3x until it is seen to.
    private static let backwards: UInt8 = 0xFF

    /// What is met in a file that is not played as it asks, for `ForeignModule.shortfalls`.
    private struct Found {
        var robot = false, highOffsets = false, turnedRound = false, cutShort = false
        var backwardsLeftOut = 0

        func sentences(_ samples: Shortfall.CutShort) -> [String] {
            var sentences: [String] = []
            if robot { sentences.append("Its robot voice (8xx) is left out, as OpenMPT leaves it out.") }
            if highOffsets { sentences.append("Its starts further into a sample than 64 KB (E8x) are left out.") }
            if backwardsLeftOut > 0 {
                sentences.append(Shortfall.some(backwardsLeftOut, one: "commands to play a sample backwards has no note to play, and is left out.",
                                                many: "commands to play a sample backwards have no note to play, and are left out."))
            }
            if turnedRound { sentences.append("Its notes played backwards go on backwards when a note starts on the channel beside, which DIGI Booster turned round.") }
            if let sentence = samples.sentence { sentences.append(sentence) } else if cutShort { sentences.append("The file is cut short in its patterns.") }
            return sentences
        }
    }

    /// The four bytes of a note, as a MOD file has them: the sample's upper half and the period,
    /// the sample's lower half and the command, and the command's value.
    private static func note(_ f: ByteReader, _ at: Int, _ found: inout Found) -> FT2Note {
        var note = FT2Note()
        let period = UInt16(f[at] & 0x0F) << 8 | UInt16(f[at + 1])
        if period != 0 {
            for k in 0 ..< 96 where period >= ft2AmigaPeriod[k] {
                note.ton = UInt8(k + 1)
                break
            }
        }
        note.instr = (f[at] & 0xF0) | (f[at + 2] >> 4)
        let command = f[at + 2] & 0x0F, value = f[at + 3]
        switch command {
        case 0x8:
            // DIGI Booster's robot voice, which nobody plays.
            found.robot = true
        case 0xC:
            note.effTyp = command
            note.eff = min(64, value)
        case 0xE:
            switch value >> 4 {
            // The Amiga's filter, which FastTracker has no part of.
            case 0x0: break
            // Backwards, to the start (E30) or back and forth over the whole sample.
            case 0x3:
                note.effTyp = backwards
                note.eff = value & 15
            // E40 stops the note, and what is beside it is nothing (see `FT2Player.digiBoosterStop`).
            case 0x4:
                if value & 15 == 0 {
                    note.ton = 0
                    note.instr = 0
                }
                note.effTyp = command
                note.eff = value
            // How far beyond 64 KB into its sample the next start into one is.
            case 0x8:
                if value & 15 != 0 { found.highOffsets = true }
            default:
                note.effTyp = command
                note.eff = value
            }
        case 0xF:
            // (A speed of nothing stops FastTracker, and does nothing in OpenMPT.)
            if value != 0 {
                note.effTyp = command
                note.eff = value
            }
        default:
            // (A slide by nothing is the last slide again, as OpenMPT plays these files, and not
            // nothing, as a MOD file's would be.)
            note.effTyp = command
            note.eff = value
        }
        return note
    }

    /// How loud these files are played, beside an XM file: set by measure, so that the middle one of
    /// them is about as loud as the middle one of other modules.
    private static let loudness: Float = 0.82
}
