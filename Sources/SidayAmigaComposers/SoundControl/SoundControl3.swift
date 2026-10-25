// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// SoundControl 3.0's and 3.2's routines, as Wanted Team's player has them (see SoundControlPlayer.swift):
// 3.0's from Dynatech's UNDERWATER (`Play_3`, `Init_3`), 3.2's from its ELEVEN6 (`Play_32`, `Init_32`).

import SidayChips
import SidayFoundation

extension SoundControlPlayer {
    /// `Init_3` and `Init_32`: the table of periods made, eight octaves of the routine's sixteen words,
    /// each shifted down a place more than the last, from two; (3.2's) the first byte of the positions,
    /// the first track's pattern there, set to one; the song's first position's tracks; and every voice's
    /// DMA turned on (`$800F`).
    mutating func initialise3<Output: TFMXOutput>(_ output: inout Output) {
        var at = Self.periods3At
        for shift in 2 ..< 10 {
            for period in Self.octave {
                poke16(at, period >> UInt16(shift))
                at += 2
            }
        }
        if version == .v32 { poke8(positionsAt, 1) }
        position = startPosition
        loadTracks()
        poke16(0xDFF096, 0x800F, &output)
    }

    /// `Play_3` and `Play_32`, at each of the host's ticks: the routine's half step (`lbC018406`,
    /// `lbC0057B4`) once, and twice at every third tick (3.0's) or every second (3.2's), as the games did
    /// on a PAL Amiga (Wanted Team's player always takes it to be one); and at every second half step a
    /// step of the song. 3.0's song goes on two steps in every three ticks, 3.2's three in every four.
    mutating func interrupt3<Output: TFMXOutput>(_ output: inout Output) {
        frames &+= 1
        if frames == (version == .v30 ? 3 : 2) {
            halfStep3(&output)
            frames = 0
        }
        if failure == nil { halfStep3(&output) }
    }

    private mutating func halfStep3<Output: TFMXOutput>(_ output: inout Output) {
        halves &+= 1
        if halves == 2 {
            step3(&output)
            halves = 0
        }
    }

    /// A step of the song (`lbC0185F8`, `lbC00599A`): (3.2's) the transposing track's, and each voice's
    /// track's in turn, a row read where its last note's steps are over. A row of $FF ends the
    /// position, and the step is begun again at the next; a row of nought is a rest; any other is a note,
    /// its sample and its volume (3.2's sample $FF the first sample, at no volume, and the row read again
    /// at the next step). A note of the volume $80 is kept, unheard, with the voice's chord (a routine of
    /// the games' that plays it, which Wanted Team's player has, is never called); one of any other is
    /// played, and the notes kept made the chord to come (`lbC018660`).
    private mutating func step3<Output: TFMXOutput>(_ output: inout Output) {
        var positions = 0
        nextPosition: while true {
            if version == .v32 { transposingTrack3() }
            for v in 0 ..< 4 {
                let a2 = tracks[v]
                if counters[v] != 0 {
                    counters[v] &-= 1
                    continue
                }
                counters[v] = UInt16(peek8(a2 &+ 1)) &- 1
                tracks[v] = a2 &+ 4
                if peek8(a2) == 0xFF {
                    positions += 1
                    if positions > Self.mostPositions {
                        failure = "the song's positions go round without a note"
                        return
                    }
                    endOfPosition()
                    continue nextPosition
                }
                if peek8(a2) == 0 { continue }
                var note = peek8(a2)
                if version == .v32 {
                    // (`lbC005A56`) Transposed by the voice's transposition less one, a semitone at a time
                    // (each octave sixteen notes, of which the last four are passed over).
                    var steps = UInt8(truncatingIfNeeded: transposes[v]) &+ 0xFF
                    while steps != 0 {
                        if steps & 0x80 != 0 {
                            steps &+= 1
                            note &-= 1
                            if note & 15 == 15 { note &-= 4 }
                        } else {
                            steps &-= 1
                            note &+= 1
                            if note & 15 == 12 { note &+= 4 }
                        }
                    }
                }
                var sample = peek8(a2 &+ 2), volume: UInt8
                if version == .v32, sample == 0xFF {
                    sample = 1
                    volume = 0
                    counters[v] = 0
                } else {
                    volume = peek8(a2 &+ 3)
                }
                let a5 = Self.voices3At + UInt32(v) * Self.voice3Size
                if volume == 0x80 {
                    poke8(a5 &- 3, 1)
                    keepInChord(a5, note, sample)
                    continue
                }
                if peek16(a5) != 0 {
                    poke8(a5 &- 1, 1)
                    poke8(a5 &- 2, volume)
                    poke8(a5 &- 3, 0)
                    keepInChord(a5, note, sample)
                    poke32(a5 &+ 0x12, peek32(a5 &- 2))
                    poke32(a5 &+ 0x16, peek32(a5 &+ 2))
                    poke32(a5 &+ 0x1A, peek32(a5 &+ 6))
                    poke16(a5 &+ 0x1E, peek16(a5 &+ 10))
                    for offset: UInt32 in [0, 4, 8, 12] { poke32(a5 &- 2 &+ offset, 0) }
                } else {
                    poke8(a5 &- 1, 0)
                    poke8(a5 &+ 0x13, 0)
                }
                let header = samplesAt &+ peek32(samplesAt &+ UInt32(sample) << 2)
                play3(v, header: header, note: note, volume: volume, &output)
                if failure != nil { return }
            }
            return
        }
    }

    /// (`lbC0186EA`) The end of a position: the next, and at the song's last, its first again, and the
    /// song's end told.
    private mutating func endOfPosition() {
        position &+= 12
        if position == endPosition {
            songEnd()
            position = startPosition
        }
        loadTracks()
    }

    /// 3.2's transposing track (the sixth), at each step: unless at $FF, where it stays, a row read where
    /// the last one's steps are over; one not nought sets the transposition of the voice its third byte
    /// says (one to four, five for all of them) to its fourth's low six bits.
    private mutating func transposingTrack3() {
        let a2 = tracks[5]
        guard peek8(a2) != 0xFF else { return }
        if counters[5] != 0 {
            counters[5] &-= 1
            return
        }
        counters[5] = UInt16(peek8(a2 &+ 1)) &- 1
        tracks[5] = a2 &+ 4
        guard peek8(a2) != 0 else { return }
        // (Its `ORI.W #$FF10` for a negative transposition, at bit 6, is never reached: the bit has been
        // cleared.)
        let amount = UInt16(peek8(a2 &+ 3) & 0x3F)
        let voice = peek8(a2 &+ 2) &- 1
        if voice == 4 { transposes = .init(repeating: amount) }
        transposes[Int(voice & 3)] = amount
    }

    /// `lbC01871E`: a note and its sample kept in the first free word of the voice's seven.
    private mutating func keepInChord(_ a5: UInt32, _ note: UInt8, _ sample: UInt8) {
        var a4 = a5
        for _ in 0 ..< 7 {
            let free = peek16(a4) == 0
            a4 &+= 2
            if free { break }
        }
        poke8(a4 &- 2, note)
        poke8(a4 &- 1, sample)
    }

    /// A note played (`lbC0184F0`, `lbC0058AC`): moved up by its sample's transposition (the word at
    /// 42), its period from the table; Paula told the sample (at 64 from its header) to play a word at
    /// the period 1 while the voice's DMA is turned off, then its volume (its low seven bits), period,
    /// length (the word at 16, in bytes) and place, the sample's first long cleared, and the DMA on; and
    /// then its loop (from the words at 18 and 20, from the start and to the end), or a sample with none
    /// set to go round on the word it has cleared.
    private mutating func play3<Output: TFMXOutput>(_ v: Int, header a1: UInt32, note: UInt8, volume: UInt8,
                                                    _ output: inout Output)
    {
        var note = note
        var steps = Int(peek16(a1 &+ 0x2A))
        // (Once among the notes of the octaves, in at most three, a note goes round them in 192.)
        if steps > 196 { steps = 4 + (steps - 4) % 192 }
        for _ in 0 ..< steps {
            note &+= 1
            if note & 15 == 12 { note &+= 4 }
        }
        let period = peek16(Self.periods3At &+ 2 * UInt32(note))
        let a0 = 0xDFF0A0 + 16 * UInt32(v)
        let bit = UInt16(1) << UInt16(v)
        let data = a1 &+ 0x40
        poke32(a0, data, &output)
        poke32(a0 + 4, 0x0001_0001, &output)
        poke16(0xDFF096, bit, &output)
        poke16(a0 + 8, UInt16(volume & 0x7F), &output)
        poke16(a0 + 6, period, &output)
        poke16(a0 + 4, peek16(data &- 0x30) >> 1, &output)
        poke32(a0, data, &output)
        poke32(data, 0)
        poke16(0xDFF096, bit | 0x8200, &output)
        let loopStart = peek16(a1 &+ 0x12)
        if loopStart == 0 {
            poke16(a0 + 4, 1, &output)
            return
        }
        poke16(a0 + 4, (peek16(a1 &+ 0x14) &- loopStart) >> 1, &output)
        poke32(a0, data &+ wide(loopStart), &output)
    }
}

/// A word as the 68000 takes it as an index or a displacement: sign-extended to a long.
private func wide(_ value: UInt16) -> UInt32 { UInt32(bitPattern: Int32(Int16(bitPattern: value))) }
