// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md): how it
// plays a module of DIGI Booster's (`soundlib/Sndmix.cpp`, `soundlib/Snd_fx.cpp`).

/// What DIGI Booster does otherwise than FastTracker 2, for one of its modules (see `DIGIFile` and
/// `ForeignModule.playsAsDigiBooster`). Its replayer has not been ported; this is how OpenMPT plays
/// these files, which is as DigiBooster Pro after it played its own:
///  - An arpeggio is a step behind ProTracker's: the second note on a row's first tick, the note
///    itself on the next, then the first. Its notes are counted from the channel's note, and the
///    last it plays is where the pitch stays when the row is over.
///  - Vibrato and tremolo go by DIGI Booster's own wave, a sine of 32 steps that is not quite
///    even, and its vibrato's wave does not start again with a note. The vibrato is not heard on
///    a row's first tick, which is at the note itself; the tremolo is.
///  - A slide up and a slide down remember one value between them.
///  - A loop within a pattern (E6x) is not begun while another channel's is going: of several on
///    one row, each goes round in turn.
///  - E40 stops the note (see `digiBoosterStop`).
///  - A period is of the Amiga's own clock, a PAL machine's, and not of the one FastTracker reckons
///    a MOD file's periods by: notes are some sixteen cents lower.
extension FT2Player {
    /// DIGI Booster's wave for vibrato and tremolo, of 32 steps, as OpenMPT has it.
    private static let digiBoosterSine: [Int8] = [
        33, 52, 69, 84, 96, 107, 116, 122, 125, 127, 125, 122, 116, 107, 96, 84,
        69, 52, 33, 13, -8, -31, -54, -79, -104, -128, -104, -79, -54, -31, -8, 13,
    ]

    /// Where in the wave a place is: FastTracker counts 256 to a wave of 64 steps, which DIGI
    /// Booster's has two at a time.
    private func digiBoosterWave(_ position: UInt8) -> Int {
        Int(Self.digiBoosterSine[Int(position >> 3) & 31])
    }

    /// 0xy on every tick of its row, the first too.
    func digiBoosterArpeggio(_ ch: FT2Channel, _ param: UInt8) {
        let tempo = Int(song.tempo), tick = (tempo - Int(song.timer) + tempo) % max(1, tempo)
        var ton = Int(ch.tonNr) + Int(ch.relTonNr)
        switch (tick + 2) % 3 {
        case 1: ton += Int(param >> 4)
        case 2: ton += Int(param & 0x0F)
        default: break
        }
        guard ton >= 1, ton < 10 * 12 else { return }
        let tmpTon = ((ton - 1) << 4) + ((Int(ch.fineTune) >> 3) + 16)
        guard tmpTon < 10 * 12 * 16 + 16 else { return }
        ch.realPeriod = note2Period(tmpTon)
        ch.outPeriod = ch.realPeriod
        ch.status |= IS_Period
    }

    /// E40, which stops the note: what is named beside it starts nothing, and nor does an
    /// instrument named after it with no note.
    func digiBoosterStop(_ ch: FT2Channel) {
        ch.realVol = 0
        ch.outVol = 0
        ch.status |= IS_Vol + IS_QuickVol
        P_StopTone(ch.nr)
    }

    /// The vibrato of 4xy and 6xy, on the ticks after a row's first.
    func digiBoosterVibrato(_ ch: FT2Channel) {
        let swing = -digiBoosterWave(ch.vibPos) * Int(ch.vibDepth) * 4 / 64
        ch.outPeriod = UInt16(truncatingIfNeeded: max(1, Int(ch.realPeriod) - swing))
        ch.status |= IS_Period
        ch.vibPos &+= ch.vibSpeed
    }

    /// The tremolo of 7xy: on a row's first tick at the place it is at, and on the ticks after
    /// moving on.
    func digiBoosterTremolo(_ ch: FT2Channel, movesOn: Bool) {
        if ch.realVol > 0 {
            let swing = digiBoosterWave(ch.tremPos) * Int(ch.tremDepth) * 4 / 64
            ch.outVol = UInt8(max(0, min(64, (Int(ch.realVol) * 4 + swing) / 4)))
            ch.status |= IS_Vol
        }
        if movesOn { ch.tremPos &+= ch.tremSpeed }
    }
}
