// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// SoundControl 4.0's and 5.0's routines, as Wanted Team's player has them (see SoundControlPlayer.swift):
// 4.0's from Hot Numbers Deluxe (`Init_4`, `Play_4`), 5.0's from Biing! (`Init_5`, `Play_5`). The two are
// the same but for their tempo's count and that 5.0's has no songs of its own.

import SidayChips
import SidayFoundation

extension SoundControlPlayer {
    /// The table of periods (`lbC008902`, `lbC066676`): eight octaves of the routine's twelve notes, each
    /// shifted down a place more than the last, from two.
    private mutating func makePeriods4() {
        var at = Self.periods4At
        for shift in 2 ..< 10 {
            for period in Self.octave.prefix(12) {
                poke16(at, period >> UInt16(shift))
                at += 2
            }
        }
    }

    /// `Init_4`, given the game's number of the song (EaglePlayer's song, counting from nought, and the
    /// number of songs, `InitSound`): its tempo the module's, and its first and last positions, but for
    /// the songs the routine has its own for. 1 is all of a module's 22 positions (Hot Numbers Deluxe's
    /// HNDTITLE); 2 and 3 HNDONGAME2's, its 25th position (which then goes on to its first) and the 24
    /// before it; 4 to 7 HNDINTRO's, with tempos of their own. Then the song's first position's tracks,
    /// and every voice's DMA turned on (`$800F`).
    mutating func initialise4<Output: TFMXOutput>(_ number: UInt16, _ output: inout Output) {
        makePeriods4()
        tempo = headerTempo
        startPosition = 0
        position = 0
        endPosition = 0x108
        switch number {
        case 1: break
        case 7: (tempo, endPosition) = (0x124, 0x330)
        case 4: (startPosition, position, endPosition, tempo) = (0x330, 0x330, 0x3F0, 0x1B3)
        case 5: (startPosition, position, endPosition, tempo) = (0x3F0, 0x3F0, 0x4E0, 0xD2)
        case 6: (startPosition, position, endPosition, tempo) = (0x4E0, 0x4E0, 0x630, 0xB5)
        case 2: (position, endPosition) = (0x120, 0x12C)
        default: (position, endPosition) = (startPosition, 0x120)
        }
        loadTracks()
        poke16(0xDFF096, 0x800F, &output)
    }

    /// `Init_5`: the module's tempo, and all its positions. (It leaves Paula's DMA as it is.)
    mutating func initialise5<Output: TFMXOutput>(_: inout Output) {
        makePeriods4()
        tempo = headerTempo
        startPosition = 0
        position = 0
        endPosition = positionsEnd
        loadTracks()
    }

    /// `Play_4` and `Play_5`, at each of the host's ticks: the tempo added up, and for every 187 of it
    /// (4.0's, `lbC0088C2`), or every fourth 46 (5.0's, `lbC066620`), a step of the song; then each
    /// voice's instrument's commands, and its volume envelope.
    mutating func interrupt4<Output: TFMXOutput>(_ output: inout Output) {
        tempoSum &+= tempo
        let each: UInt16 = version == .v40 ? 0xBB : 0x2E
        while tempoSum > each {
            tempoSum &-= each
            quarters &+= 1
            if version == .v40 || quarters & 3 == 0 { step4() }
            if failure != nil { return }
        }
        var bit: UInt16 = 1
        for v in 0 ..< 4 {
            commands4(v, bit: bit, &output)
            if failure != nil { return }
            bit <<= 1
        }
        envelopes4(&output)
    }

    private func voice4(_ v: Int) -> UInt32 { Self.voices4At + Self.voice4Offsets[v] }

    /// A step of the song (`lbC008B4E`, `lbC0668C4`): the transposing track's, and each voice's track's in
    /// turn, a row read where its last note's steps are over. A row of $FF, or of the instrument $FF, ends
    /// the position, and the step is begun again at the next; a row of nought is a rest; any other starts
    /// its instrument on its note at its volume.
    private mutating func step4() {
        var positions = 0
        nextPosition: while true {
            transposingTrack4()
            for v in 0 ..< 4 {
                let a2 = tracks[v]
                if counters[v] != 0 {
                    counters[v] &-= 1
                    continue
                }
                counters[v] = UInt16(peek8(a2 &+ 1)) &- 1
                tracks[v] = a2 &+ 4
                let note = peek8(a2), instrument = peek8(a2 &+ 2)
                if note == 0 { continue }
                if note == 0xFF || instrument == 0xFF {
                    positions += 1
                    if positions > Self.mostPositions {
                        failure = "the song's positions go round without a note"
                        return
                    }
                    position &+= 12
                    if position == endPosition {
                        songEnd()
                        position = startPosition
                    }
                    loadTracks()
                    continue nextPosition
                }
                start4(v, note: note, volume: peek8(a2 &+ 3), instrument: instrument)
            }
            return
        }
    }

    /// The transposing track (the sixth, `lbC008C64`, `lbC0669B8`), at each step: a row read where the
    /// last one's steps are over; one not nought, nor $FF (where it stays), sets the transposition of the
    /// voice its third byte says (one to four, five for all of them) to its fourth's low six bits.
    private mutating func transposingTrack4() {
        let a2 = tracks[5]
        if counters[5] != 0 {
            counters[5] &-= 1
            return
        }
        counters[5] = UInt16(peek8(a2 &+ 1)) &- 1
        tracks[5] = a2 &+ 4
        guard peek8(a2) != 0 else { return }
        if peek8(a2) == 0xFF {
            tracks[5] = a2
            return
        }
        // (Its `OR.W #$FF10` for a negative transposition, at bit 6, is never reached: the bit has been
        // cleared.)
        let amount = UInt16(peek8(a2 &+ 3) & 0x3F)
        let voice = peek8(a2 &+ 2) &- 1
        if voice == 4 {
            transposes = .init(repeating: amount)
        } else {
            transposes[Int(voice & 3)] = amount
        }
    }

    /// An instrument started (`lbC008AE0`, `lbC066852`): its commands (from 48 in it), the note's volume,
    /// the note (its high four bits its octave, the low its note in it) with the voice's transposition,
    /// and its volume envelope from the start, a tick from now.
    private mutating func start4(_ v: Int, note: UInt8, volume: UInt8, instrument: UInt8) {
        let a5 = voice4(v)
        let offset = peek16(instrumentsAt &+ 2 * UInt32(instrument))
        poke16(a5 &+ 6, UInt16(instrument))
        poke32(a5, instrumentsAt &+ wide(offset) &+ 0x30)
        poke16(a5 &+ 0x10, UInt16(volume))
        poke16(a5 &+ 0x1C, 0)
        poke16(a5 &+ 4, 0)
        poke32(a5 &+ 0x26, a5 &+ 0x2A)
        let d0 = UInt16(note)
        poke16(a5 &+ 0xC, (d0 & 15) &+ (d0 & 0xF0) >> 2 &* 3 &+ transposes[v])
        poke16(a5 &+ 0x22, 0)
        poke16(a5 &+ 0x20, 1)
        poke16(a5 &+ 0x1E, 0)
        poke16(a5 &+ 0x24, 0)
    }

    /// A voice's instrument's commands, at each tick (`lbC008E14`, `lbC066B6C`), until one that waits: each
    /// six bytes, a word of the command (in its low five bits; its bit 14 to take its first value from the
    /// voice's register it names, bit 15 its second) and two of values. The voice's DMA bit, which some
    /// commands write to DMACON, is kept in the routine's D4, which command 1 uses for its note and leaves
    /// with twice it; and a command that writes DMACON after it in the same tick writes that, as the games'
    /// routine did.
    private mutating func commands4<Output: TFMXOutput>(_ v: Int, bit: UInt16, _ output: inout Output) {
        let a5 = voice4(v)
        let a4 = 0xDFF0A0 + 16 * UInt32(v)
        var a0 = peek32(a5)
        if a0 == 0 { return }
        var d4 = bit
        var read = 0
        while true {
            if peek16(a5 &+ 4) != 0 {
                poke16(a5 &+ 4, peek16(a5 &+ 4) &- 1)
                poke32(a5, a0)
                return
            }
            read += 1
            if read > Self.mostCommands {
                failure = "an instrument's commands go round without a wait"
                return
            }
            var a1 = a0
            let d0 = peek16(a0)
            var d5 = peek16(a0 &+ 2), d6 = peek16(a0 &+ 4)
            if failure != nil { return }
            if d0 & 0x4000 != 0 { d5 = peek16(a5 &+ 0x3A &+ wide(d5 &+ d5)) }
            if d0 & 0x8000 != 0 { d6 = peek16(a5 &+ 0x3A &+ wide(d6 &+ d6)) }
            switch d0 & 0x1F {
            case 0:
                // (`lbC008EF4`) Held here: the same command at the next tick.
                a1 &-= 6
                poke16(a5 &+ 4, 1)
            case 1:
                // (`lbC008EFE`) A sample, its length, and the note's period, moved by the sample's
                // transposition (its word at 42).
                poke16(a5 &+ 8, d5)
                let header = samplesAt &+ peek32(samplesAt &+ wide(d5 << 2))
                poke32(a5 &+ 0x16, header)
                poke16(a5 &+ 0x1A, peek16(header &+ 0x10))
                d4 = peek16(a5 &+ 0xC) &+ peek16(header &+ 0x2A)
                poke16(a5 &+ 0xE, d4)
                d4 = d4 &+ d4
                poke16(a5 &+ 0xA, peek16(Self.periods4At &+ wide(d4)))
                poke32(a5 &+ 0x12, header &+ 0x40)
            case 2:
                // (`lbC008F3A`) A wait of so many ticks.
                poke16(a5 &+ 4, d5)
            case 3:
                // (`lbC008F40`) Paula's place, so far into the sample.
                poke32(a4, peek32(a5 &+ 0x16) &+ 0x40 &+ wide(d5), &output)
            case 4:
                // (`lbC008F4E`) A sample, and Paula told its place.
                poke16(a5 &+ 8, d5)
                let data = samplesAt &+ peek32(samplesAt &+ wide(d5 << 2)) &+ 0x40
                poke32(a5 &+ 0x16, data &- 0x40)
                poke32(a4, data, &output)
                poke32(a5 &+ 0x12, data)
            case 5:
                // (`lbC008F6C`) A length, in bytes, and Paula told it.
                poke16(a5 &+ 0x1A, d5)
                poke16(a4 &+ 4, d5 >> 1, &output)
            case 6:
                // (`lbC008F7A`) A sample, and Paula told its length.
                poke16(a5 &+ 8, d5)
                let header = samplesAt &+ peek32(samplesAt &+ wide(d5 << 2))
                poke32(a5 &+ 0x16, header)
                let length = peek16(header &+ 0x10)
                poke16(a5 &+ 0x1A, length)
                poke16(a4 &+ 4, length >> 1, &output)
            case 7:
                // (`lbC008F9C`) The period moved by so much.
                let period = peek16(a5 &+ 0xA) &+ d5
                poke16(a4 &+ 6, period, &output)
                poke16(a5 &+ 0xA, period)
            case 8:
                // (`lbC008FAC`) The note moved by so many semitones, and its period told.
                let note = peek16(a5 &+ 0xE) &+ d5
                poke16(a5 &+ 0xE, note)
                let period = peek16(Self.periods4At &+ wide(note &+ note))
                poke16(a5 &+ 0xA, period)
                poke16(a4 &+ 6, period, &output)
            case 9:
                // (`lbC008FCC`) The note's volume moved by so much, within nought and 64.
                var volume = peek16(a5 &+ 0x10) &+ d5
                if volume & 0x8000 != 0 { volume = 0 }
                if volume >= 0x40 { volume = 0x40 }
                poke16(a5 &+ 0x10, volume)
            case 10:
                // (`lbC008FE6`) A loop's start: where it is kept on the voice's stack (from 42 in its
                // record, four bytes each), and the register it counts in set.
                let top = peek32(a5 &+ 0x26) &+ 4
                poke32(top, a0)
                poke32(a5 &+ 0x26, top)
                poke16(a5 &+ 0x3A &+ wide(d5 &+ d5), d6)
            case 11:
                // (`lbC008FFE`) A loop's end: its register (the one its start named) moved by the second
                // value, and back to its start's next command while it has not passed the first (going
                // up) or come to it (going down); and off the stack once it has.
                let start = peek32(peek32(a5 &+ 0x26))
                let register = a5 &+ 0x3A &+ wide(peek16(start &+ 2) &* 2)
                poke16(register, peek16(register) &+ d6)
                let done = d6 & 0x8000 == 0 ? d5 < peek16(register) : d5 >= peek16(register)
                if done {
                    poke32(a5 &+ 0x26, peek32(a5 &+ 0x26) &- 4)
                } else {
                    a1 = start
                }
            case 12:
                // (`lbC009030`) A register moved by so much.
                let register = a5 &+ 0x3A &+ wide(d5 &+ d5)
                poke16(register, peek16(register) &+ d6)
            case 13:
                // (`lbC00903C`) A register set.
                poke16(a5 &+ 0x3A &+ wide(d5 &+ d5), d6)
            case 15:
                // (`lbC00904A`) The sample played: at its first tick, Paula told its place, its DMA
                // turned on, and told to play a word at the period 1 and no volume; at its second, the
                // DMA turned off, its period and length told, its first long cleared, and the DMA turned
                // on; and at its third, its loop told, or a sample with none set to go round on the long
                // it has cleared.
                let part = peek16(a5 &+ 0x1C)
                poke16(a5 &+ 0x1C, part &+ 4)
                switch part {
                case 0:
                    poke32(a4, peek32(a5 &+ 0x12), &output)
                    d4 |= 0x8200
                    poke16(0xDFF096, d4, &output)
                    d4 &= 15
                    poke32(a4 &+ 4, 0x0001_0001, &output)
                    poke16(a4 &+ 8, 0, &output)
                    poke16(a5 &+ 4, 1)
                    a1 &-= 6
                case 4:
                    poke16(0xDFF096, d4, &output)
                    poke16(a4 &+ 6, peek16(a5 &+ 0xA), &output)
                    poke16(a4 &+ 4, peek16(a5 &+ 0x1A) >> 1, &output)
                    poke32(peek32(a5 &+ 0x16) &+ 0x40, 0)
                    d4 |= 0x8200
                    poke16(0xDFF096, d4, &output)
                    d4 &= 15
                    poke16(a5 &+ 4, 1)
                    a1 &-= 6
                case 8:
                    poke16(a5 &+ 0x1C, 0)
                    let header = peek32(a5 &+ 0x16)
                    let loopEnd = peek16(header &+ 0x14)
                    if loopEnd == 0 {
                        poke16(a4 &+ 4, 2, &output)
                    } else {
                        let loopStart = peek16(header &+ 0x12)
                        poke16(a4 &+ 4, (loopEnd &- loopStart) >> 1, &output)
                        poke32(a4, header &+ 0x40 &+ wide(loopStart), &output)
                    }
                default:
                    // (Past the routine's three, its table of them would be read on into its code.)
                    failure = "an instrument's sample was played in a part the routine does not have"
                    return
                }
            default:
                // (14, and 16 to 31: nothing.)
                break
            }
            if failure != nil { return }
            a0 = a1 &+ 6
        }
    }

    /// The volume envelopes, at each tick (`lbC008CDC`, `lbC066A28`): each voice's, its instrument's
    /// first bytes (from 18: the ticks between steps and the step of its rise, to 256, of its fall, to the
    /// level at 23, and of its release, which nothing starts: the hold before it waits for a word that
    /// nothing sets), a step whenever its ticks are over; and Paula's volume the note's times the
    /// envelope's, over 256 (its low seven bits).
    private mutating func envelopes4<Output: TFMXOutput>(_ output: inout Output) {
        for v in 0 ..< 4 {
            let a5 = voice4(v)
            let wait = peek16(a5 &+ 0x20)
            if wait != 0 {
                poke16(a5 &+ 0x20, wait &- 1)
            } else {
                let instrument = instrumentsAt &+ wide(peek16(instrumentsAt &+ wide(peek16(a5 &+ 6) &* 2)))
                let stage = peek16(a5 &+ 0x1E)
                var level = peek16(a5 &+ 0x22)
                switch stage {
                case 0:
                    level &+= UInt16(peek8(instrument &+ 0x13))
                    poke16(a5 &+ 0x22, level)
                    if Int16(bitPattern: level) >= 0x100 {
                        poke16(a5 &+ 0x22, 0x100)
                        poke16(a5 &+ 0x1E, stage &+ 1)
                    }
                    poke16(a5 &+ 0x20, UInt16(peek8(instrument &+ 0x12)))
                case 1:
                    level &-= UInt16(peek8(instrument &+ 0x15))
                    poke16(a5 &+ 0x22, level)
                    let sustain = UInt16(peek8(instrument &+ 0x17))
                    if Int16(bitPattern: sustain) >= Int16(bitPattern: level) {
                        poke16(a5 &+ 0x22, sustain)
                        poke16(a5 &+ 0x1E, stage &+ 1)
                    }
                    poke16(a5 &+ 0x20, UInt16(peek8(instrument &+ 0x14)))
                case 2:
                    if peek16(a5 &+ 0x24) == 0x80 { poke16(a5 &+ 0x1E, stage &+ 1) }
                case 3:
                    let step = UInt16(peek8(instrument &+ 0x19))
                    poke16(a5 &+ 0x22, level < step ? 0 : level &- step)
                    poke16(a5 &+ 0x20, UInt16(peek8(instrument &+ 0x18)))
                case 4:
                    break
                default:
                    // (Past the routine's five, its table of them would be read on into its code.)
                    failure = "a volume envelope came to a stage the routine does not have"
                    return
                }
            }
            let product = UInt32(peek16(a5 &+ 0x10)) &* UInt32(peek16(a5 &+ 0x22))
            let volume = UInt16(truncatingIfNeeded: product) >> 8
            poke16(0xDFF0A8 + 16 * UInt32(v), volume & 0x7F, &output)
            if failure != nil { return }
        }
    }
}

/// A word as the 68000 takes it as an index or a displacement: sign-extended to a long.
private func wide(_ value: UInt16) -> UInt32 { UInt32(bitPattern: Int32(Int16(bitPattern: value))) }
