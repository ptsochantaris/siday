// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// what its player does for an MT2 file that it does not for an IT file (`soundlib/Snd_fx.cpp`,
// `soundlib/Sndmix.cpp`).

/// The few ways in which OpenMPT plays an MT2 file otherwise than an IT file, which are ways of
/// FastTracker's that MadTracker had (see `MT2File`): each is reached only for such a module
/// (`IT2Module.madTracker`).
extension IT2Player {
    /// A note's key let go on a row, as FastTracker lets one go: a note whose instrument has no
    /// envelope for its volume is silenced, and goes on silent (a volume given it later brings it
    /// back); and any other starts to fade as soon as its key is let go, if its instrument fades,
    /// where Impulse Tracker's fades only once its envelope is past its loop. False for the first,
    /// which is not let go at all.
    func madTrackerLetGo(_ hc: IT2HostPointer, _ sc: IT2SlavePointer) -> Bool {
        guard sc.pointee.Ins != 0xFF, let ins = sc.pointee.InsPtr, ins.VolEnv.Flags & ENVF_ENABLED != 0 else {
            hc.pointee.VolSet = 0
            sc.pointee.VolSet = 0
            sc.pointee.Vol = 0
            sc.pointee.Flags |= SF_RECALC_VOL
            return false
        }
        madTrackerFade(sc)
        return true
    }

    /// A channel's part of a row as it is read. An instrument named without a note is, to
    /// Impulse Tracker, for the last note the channel was given, which may be a note-off; to
    /// OpenMPT, in an MT2 file, it is for the last that was a note.
    func madTrackerRow(_ hc: IT2HostPointer) {
        let mask = hc.pointee.NotePackMask
        if mask & 0x11 != 0, hc.pointee.RawNote < 120 {
            hc.pointee.LastNote = hc.pointee.RawNote
        } else if mask & 0x11 == 0, mask & 0x22 != 0, hc.pointee.RawNote >= 120, hc.pointee.LastNote < 120 {
            hc.pointee.RawNote = hc.pointee.LastNote
        }
    }

    /// An instrument named again on a row without a note, as FastTracker takes one: the note's
    /// envelopes and its own vibrato start again, and a note that was fading is whole again.
    func madTrackerInstrumentAgain(_ sc: IT2SlavePointer) {
        guard sc.pointee.Ins != 0xFF, let ins = sc.pointee.InsPtr else { return }
        restartEnvelopes(sc, ins)
        sc.pointee.Flags &= ~SF_FADEOUT
        sc.pointee.Flags |= SF_RECALC_VOL
        sc.pointee.FadeOut = 1024
        sc.pointee.AutoVibratoDepth = 0
        sc.pointee.AutoVibratoPos = 0
    }

    /// A tick of a note's fade, as OpenMPT fades one: an instrument of these files has its fade as
    /// OpenMPT has it, by so much of 32,768 a tick, where Impulse Tracker's is of 1,024 and would
    /// cut the slower fades to a whole step or to nothing. False once the note has faded away.
    func madTrackerFadeStep(_ sc: IT2SlavePointer, _ ins: IT2Instrument) -> Bool {
        let fine = Int(sc.pointee.FadeOut) * 64 + Int(sc.pointee.FadeFraction) - Int(ins.FadeOut) * 2
        guard fine > 0 else {
            sc.pointee.FadeOut = 0
            sc.pointee.FadeFraction = 0
            return false
        }
        sc.pointee.FadeOut = UInt16(min(1024, fine >> 6))
        sc.pointee.FadeFraction = UInt8(fine & 63)
        return true
    }

    /// A note let go, which fades from then on if its instrument fades.
    func madTrackerFade(_ sc: IT2SlavePointer) {
        if sc.pointee.Ins != 0xFF, let ins = sc.pointee.InsPtr, ins.FadeOut != 0 { sc.pointee.Flags |= SF_FADEOUT }
    }

    /// A slide of pitch, or a vibrato's step, by so many 64ths of a semitone, as OpenMPT makes one:
    /// rounded to the nearest whole number of hertz, where Impulse Tracker's is cut down to the one
    /// below, and by one at the least; and down by seven 64ths by the right amount, where Impulse
    /// Tracker's table has a slip. (Over a long slide the two come apart by some hundredths of a
    /// semitone, which is as near as both stay to the note they are going to.)
    func madTrackerSlide(_ sc: IT2SlavePointer, _ value: Int) {
        guard value != 0, sc.pointee.Frequency > 0 else { return }
        sc.pointee.Flags |= SF_FREQ_CHANGE
        let up = value > 0
        var amount = abs(value)
        let before = Int64(sc.pointee.Frequency)
        var frequency = before
        func times(_ factor: Int64) { frequency = (frequency * factor + 32768) / 65536 }
        if amount < 16 {
            times(up ? Int64(it2FineLinearSlideUpTable[amount]) : amount == 7 ? 65123 : Int64(it2FineLinearSlideDownTable[amount]))
        } else {
            amount /= 4
            while amount > 0 {
                let step = min(amount, 255)
                times(up ? Int64(it2LinearSlideUpTable[step]) : Int64(it2LinearSlideDownTable[step]))
                amount -= step
            }
        }
        if frequency == before { frequency += up ? 1 : -1 }
        sc.pointee.Frequency = Int32(max(1, min(Int64(Int32.max), frequency)))
    }

    /// A step of a vibrato (H, K, U or the volume column's), as OpenMPT makes it in these files: on
    /// the row's first tick where the wave is, without moving on, as FastTracker does; and by
    /// OpenMPT's reckoning of how far that is, and its waves, which are Impulse Tracker's but for
    /// the square, which is above the note and back to it.
    func madTrackerVibrato(_ hc: IT2HostPointer, moving: Bool) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_FREQ_CHANGE
        if moving { hc.pointee.VibratoPos &+= hc.pointee.VibratoSpeed }
        let position = Int(hc.pointee.VibratoPos)
        let wave: Int
        switch hc.pointee.VibratoWaveform & 3 {
        case 1: wave = 64 - (position + 1) / 2
        case 2: wave = position < 128 ? 64 : 0
        case 3: wave = Int(Random() & 127) - 64
        default: wave = Int(it2FineSineData[position])
        }
        hc.pointee.LastVibratoData = Int8(clamping: wave)
        madTrackerSlide(sc, wave * Int(hc.pointee.VibratoDepth) / 64)
    }

    /// A sample's own vibrato, as OpenMPT plays MadTracker's: the depth it is to have comes in over
    /// so many ticks (its "sweep", as FastTracker's does, and stops coming in when the key is let
    /// go), and the wave is a sine that starts at its top and stays above the note, so that the
    /// note is never flatter than it is.
    func madTrackerAutoVibrato(_ sc: IT2SlavePointer, _ smp: IT2Sample) {
        let full = Int(smp.AutoVibratoDepth) * 256
        var depth = Int(sc.pointee.AutoVibratoDepth)
        let sweep = Int(smp.AutoVibratoRate)
        if sweep == 0 {
            depth = full
        } else {
            if sc.pointee.Flags & SF_NOTE_OFF == 0, depth <= full {
                depth += full / sweep
                sc.pointee.AutoVibratoDepth = UInt16(min(0xFFFF, depth))
            }
            depth = min(depth, full)
        }
        sc.pointee.AutoVibratoPos &+= smp.AutoVibratoSpeed
        let position = Int(sc.pointee.AutoVibratoPos)
        let wave: Int
        switch smp.AutoVibratoWaveform {
        case 1: wave = position & 128 != 0 ? 64 : -64 // square
        case 2: wave = ((0x40 + position / 2) & 0x7F) - 0x40 // a ramp up
        case 3: wave = ((0x40 - position / 2) & 0x7F) - 0x40 // and down
        default: wave = (-Int(it2FineSineData[(position + 192) & 0xFF]) + 64) / 2
        }
        // In sixteenths of a semitone, and 64ths of one of those between them.
        var amount = wave * depth / 256
        let down = amount < 0
        amount = abs(amount)
        let step = min(amount / 256, 255)
        func factor(_ index: Int) -> Int {
            let index = min(index, 256)
            if down { return index == 0 ? 65536 : Int(it2LinearSlideDownTable[min(index, it2LinearSlideDownTable.count - 1)]) }
            return Int(it2LinearSlideUpTable[min(index, it2LinearSlideUpTable.count - 1)])
        }
        let first = factor(step), second = factor(step + 1)
        let ratio = first + (second - first) * ((amount / 4) & 0x3F) / 64
        let frequency = Int64(sc.pointee.Frequency) * Int64(ratio) / 65536
        sc.pointee.Frequency = Int32(truncatingIfNeeded: max(0, min(Int64(Int32.max), frequency)))
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }
}
