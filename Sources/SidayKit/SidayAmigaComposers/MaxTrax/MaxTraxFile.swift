// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the MaxTrax Music Driver of Talin (David Joiner) and Joe Pearce (1991-93), whose source
// Joe Pearce released under the GNU Lesser General Public Licence 2.1 or later, as UADE carries it
// (amigasrc/players/other/max_trax: max.asm, shared.asm, driver.i). Its routines are named here as
// it names them.

/// One event of a MaxTrax score, as the driver keeps it (`CookedEvent`, driver.i): a command, a byte
/// for it, when it comes after the event before it, and a word more (for a note, how long it lasts).
struct MaxTraxEvent {
    var command: UInt8
    var data: UInt8
    var start: UInt16
    var stop: UInt16
}

/// A step of an instrument's envelope (`EnvelopeData`): how long it takes, in milliseconds, and the
/// volume it comes to, $8000 being full.
struct MaxTraxEnvelope {
    var duration: UInt16
    var volume: UInt16
}

/// One octave of an instrument's sample (`SampleData`): where it is in the file, how long its attack
/// and its sustain are, in bytes, and the next octave down, if there is one (-1 for none).
struct MaxTraxSample {
    var waveform: Int
    var attack: Int
    var sustain: Int
    var next: Int
}

/// An instrument (`PatchData`): its first octave's sample (-1 for none), its attack and release
/// envelopes (where they begin among the envelopes, -1 for none, and how many steps), its volume and
/// its tuning (in 24ths of a semitone).
struct MaxTraxPatch {
    var sample = -1
    var attack = -1
    var release = -1
    var attackCount: UInt16 = 0
    var releaseCount: UInt16 = 0
    var volume: UInt16 = 0
    var tune: Int16 = 0
}

/// A MaxTrax file, as the driver's `LoadPerf` reads it: "MXTX"; the tempo the songs start at and a
/// word of flags (the Amiga's filter on, the notes' own volumes heard, a table of microtonal tunings
/// after it, which this driver passes over); the scores, each a count of events and the events; and
/// the instruments, each its number, tuning, volume, octaves, the lengths of its attack and sustain,
/// its envelopes and its samples, an octave after another, each twice as long as the one before.
///
/// A game may keep its scores in one file and its instruments in another, which the driver loads
/// one after the other (as `LoadPerf` with `PERF_SCORE` and `PERF_SAMPLES`): the scores and their
/// tempo and flags from the one, the instruments from the other.
struct MaxTraxFile {
    var tempo: UInt16 = 120
    var flags: UInt16 = 0
    var events: [MaxTraxEvent] = []
    /// Where each score's events begin among `events`, and how many it has.
    var scoreStarts: [Int] = []
    var scoreCounts: [Int] = []
    var patches = InlineArray<64, MaxTraxPatch>(repeating: MaxTraxPatch())
    var envelopes: [MaxTraxEnvelope] = []
    var samples: [MaxTraxSample] = []
    /// How many instruments the file has.
    var instrumentCount = 0
    /// Why the file cannot be played, if it cannot.
    var refusal: TuneError?

    /// The scores of `data`, and its tempo and flags.
    mutating func readScores(_ data: [UInt8]) {
        var at = 4
        guard let offset = readHead(data, &at) else { return }
        at = offset
        guard let count = word(data, at) else {
            refusal = .malformed("it is cut short")
            return
        }
        at += 2
        for _ in 0 ..< count {
            guard let high = word(data, at), let low = word(data, at + 2) else {
                refusal = .malformed("it is cut short")
                return
            }
            let number = Int(high) << 16 | Int(low)
            at += 4
            guard number <= (data.count - at) / 6 else {
                refusal = .malformed("it is cut short")
                return
            }
            scoreStarts.append(events.count)
            scoreCounts.append(number)
            events.reserveCapacity(events.count + number)
            for i in 0 ..< number {
                let e = at + 6 * i
                events.append(MaxTraxEvent(command: data[e], data: data[e + 1], start: UInt16(data[e + 2]) << 8 | UInt16(data[e + 3]),
                                           stop: UInt16(data[e + 4]) << 8 | UInt16(data[e + 5])))
            }
            at += 6 * number
        }
    }

    /// The instruments of `data`, passing over its scores.
    mutating func readInstruments(_ data: [UInt8]) {
        var at = 4
        guard let offset = readHead(data, &at, keep: false) else { return }
        at = offset
        guard let count = word(data, at) else {
            refusal = .malformed("it is cut short")
            return
        }
        at += 2
        for _ in 0 ..< count {
            guard let high = word(data, at), let low = word(data, at + 2) else {
                refusal = .malformed("it is cut short")
                return
            }
            let number = Int(high) << 16 | Int(low)
            guard number <= (data.count - at - 4) / 6 else {
                refusal = .malformed("it is cut short")
                return
            }
            at += 4 + 6 * number
        }
        guard let instruments = word(data, at) else {
            refusal = .malformed("it is cut short")
            return
        }
        at += 2
        for _ in 0 ..< instruments {
            // `DiskSample`: number, tune, volume, octaves, attack and sustain lengths, envelope counts.
            guard at + 20 <= data.count, let number = word(data, at), let tune = word(data, at + 2), let volume = word(data, at + 4),
                  let octaves = word(data, at + 6), let attackCount = word(data, at + 16), let releaseCount = word(data, at + 18)
            else {
                refusal = .malformed("it is cut short")
                return
            }
            let attack = Int(word(data, at + 8)!) << 16 | Int(word(data, at + 10)!)
            let sustain = Int(word(data, at + 12)!) << 16 | Int(word(data, at + 14)!)
            at += 20
            // (The driver keeps 64 instruments, and would write past them for a number of 64 or more.)
            guard number < 64 else {
                refusal = .malformed("an instrument is numbered past the 64 its player has room for")
                return
            }
            let envelopeCount = Int(attackCount) + Int(releaseCount)
            guard at + 4 * envelopeCount <= data.count else {
                refusal = .malformed("it is cut short")
                return
            }
            let p = Int(number)
            patches[p].tune = Int16(bitPattern: tune)
            patches[p].volume = volume
            // (An instrument of no envelope steps, of which the files have none, is given none: the driver
            // goes straight to its sustain, or to silence for its release.)
            patches[p].attack = attackCount == 0 ? -1 : envelopes.count
            patches[p].attackCount = attackCount
            for i in 0 ..< Int(attackCount) {
                envelopes.append(MaxTraxEnvelope(duration: word(data, at + 4 * i)!, volume: word(data, at + 4 * i + 2)!))
            }
            at += 4 * Int(attackCount)
            patches[p].release = releaseCount == 0 ? -1 : envelopes.count
            patches[p].releaseCount = releaseCount
            for i in 0 ..< Int(releaseCount) {
                envelopes.append(MaxTraxEnvelope(duration: word(data, at + 4 * i)!, volume: word(data, at + 4 * i + 2)!))
            }
            at += 4 * Int(releaseCount)
            // Each octave twice the length of the one before; an instrument numbered again keeps the
            // first one's samples (`LoadPerf`: the sample is put in the patch only if it has none).
            var octaveAttack = attack, octaveSustain = sustain
            var previous = -1
            for _ in 0 ..< Int(octaves) {
                let length = octaveAttack + octaveSustain
                guard length >= 0, length <= data.count - at else {
                    refusal = .malformed("it is cut short")
                    return
                }
                samples.append(MaxTraxSample(waveform: at, attack: octaveAttack, sustain: octaveSustain, next: -1))
                if previous >= 0 { samples[previous].next = samples.count - 1 }
                previous = samples.count - 1
                if patches[p].sample < 0 { patches[p].sample = previous }
                at += length
                octaveAttack <<= 1
                octaveSustain <<= 1
                guard octaveAttack < 1 << 30, octaveSustain < 1 << 30 else { break }
            }
            instrumentCount += 1
        }
    }

    /// Reads the header: "MXTX", the tempo and flags (kept only from the file of scores), and the
    /// microtonal table's room. Returns where the scores begin. (Loading instruments alone, the driver
    /// tests for that table a register that its reading last left, not the file's flags (`LoadPerf`,
    /// at `.l1`); here it is the file's own flag that is taken, which is clear in every file of
    /// instruments alone there is.)
    private mutating func readHead(_ data: [UInt8], _ at: inout Int, keep: Bool = true) -> Int? {
        guard data.count >= 8, data[0] == 0x4D, data[1] == 0x58, data[2] == 0x54, data[3] == 0x58 else {
            refusal = .malformed("not a MaxTrax file")
            return nil
        }
        let flags = word(data, 6)!
        if keep {
            tempo = word(data, 4)!
            self.flags = flags
        }
        return flags & 0x8000 != 0 ? 8 + 256 : 8
    }

    private func word(_ data: [UInt8], _ at: Int) -> UInt16? {
        guard at >= 0, at + 2 <= data.count else { return nil }
        return UInt16(data[at]) << 8 | UInt16(data[at + 1])
    }
}
