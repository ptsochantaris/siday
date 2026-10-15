// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// what its player does for a module of Imago Orpheus's or of Velvet Studio's that it does not for an IT file
// (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`, `soundlib/Snd_flt.cpp`).

/// What OpenMPT does otherwise than for an IT file, for a module of Imago Orpheus's or of Velvet
/// Studio's (see `IMFFile`, `AMSFile` and `IT2Module.openMPTForeign`). OpenMPT reads these files into
/// the shape of an IT file and plays them by Impulse Tracker's rules, but where its player asks
/// whether a file is an IT file, and these are not; so these few things are as its player has them
/// for other kinds of file:
///  - A vibrato and a tremolo play the wave where it is on a row's first tick, and move on only
///    on the ticks after (and a tremolo after it has played); and a note starts a vibrato's wave
///    again.
///  - An instrument named alone plays the channel's last note that had a sample of its instrument,
///    and on a channel that has played nothing, or has had its key let go since, nothing.
///  - A slide to a note brings back a note whose key has been let go: it stops fading and is
///    whole again (see `foreignSlideRevives`).
///  - A slide of volume or of the place between the speakers with both halves of its value goes
///    by the second, down or to the right, where Impulse Tracker's does nothing; S00 and T00 are
///    nothing, and not the last again; SC0 cuts the note at once, and SD0 does not hold it up; and
///    a global volume above the top is the top, where Impulse Tracker's is nothing.
///  - A fade is finer, as OpenMPT keeps it (see `madTrackerFadeStep`).
///  - The filter's cutoffs of Imago Orpheus's are as OpenMPT has them (see `IT2Module.Filter.imagoOrpheus`).
extension IT2Player {
    /// A slide to a note, beside its note, on a voice that is sounding: as OpenMPT plays these files,
    /// a voice whose key has been let go stops fading, and is whole again; and beside an instrument,
    /// its key is held again. One whose key is still let go goes on without fading until its
    /// envelope for volume has ended.
    func foreignSlideRevives(_ hc: IT2HostPointer, _ sc: IT2SlavePointer) {
        if hc.pointee.NotePackMask & 0x22 != 0, sc.pointee.Flags & SF_NOTE_OFF != 0 {
            sc.pointee.Flags &= ~SF_NOTE_OFF
            GetLoopInformation(sc)
        }
        if sc.pointee.Flags & SF_FADEOUT != 0 || sc.pointee.FadeOut != 1024 {
            sc.pointee.Flags &= ~SF_FADEOUT
            sc.pointee.FadeOut = 1024
            sc.pointee.FadeFraction = 0
            sc.pointee.Flags |= SF_RECALC_VOL
        }
        sc.pointee.ForeignRevived = sc.pointee.Flags & SF_NOTE_OFF != 0
    }

    /// An instrument named alone, as its row is read: for the channel's last note (see `foreignNotes`).
    func foreignInstrumentAlone(_ hc: IT2HostPointer) {
        if hc.pointee.NotePackMask & 0x11 == 0, hc.pointee.NotePackMask & 0x22 != 0 {
            hc.pointee.RawNote = foreignNotes[Int(hc.pointee.HostChnNum) & 63]
        }
    }

    /// A channel's part of a row as it is read, once its note has been found a sample: the note is
    /// the channel's from then on.
    func foreignRow(_ hc: IT2HostPointer) {
        if hc.pointee.NotePackMask & 0x11 != 0 { foreignNotes[Int(hc.pointee.HostChnNum) & 63] = hc.pointee.RawNote }
    }

    // MARK: Velvet Studio's own

    /// Velvet Studio's key let go (its command 20xx, which says after so many ticks): to OpenMPT, at
    /// once, on the row's first tick, after the row's note if it has one.
    func InitCommandVelvetKeyOff(_ hc: IT2HostPointer) {
        InitNoCommand(hc)
        guard hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_NOTE_OFF
        sc.pointee.ForeignRevived = false
        GetLoopInformation(sc)
    }

    /// A tick of the envelope for pitch of an instrument of Velvet Studio's, as OpenMPT plays one:
    /// its level of 255, whose middle is 128, as up to 32 sixteenths of a semitone either way. (Its
    /// points are kept less 128, which Impulse Tracker's levels have room for.)
    func velvetPitchEnvelope(_ sc: IT2SlavePointer) {
        let level = Int64(sc.pointee.PitchEnvState.Value) + (128 << 16)
        let steps = Int((max(0, min(65536, level / 255)) * 64 + 32768) >> 16) - 32
        guard steps != 0, let hc = sc.pointee.HostChnPtr else { return }
        PitchSlideUpLinear(hc, sc, Int16(steps * 4))
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// A note just started of a sample that Velvet Studio plays backwards: from the end of its loop,
    /// round which it goes backwards (or back and forth, from there, for one that loops so).
    func velvetBackwards(_ sc: IT2SlavePointer) {
        GetLoopInformation(sc)
        guard sc.pointee.LoopMode != 0, sc.pointee.LoopEnd > 0 else { return }
        sc.pointee.SamplingPosition = sc.pointee.LoopEnd &- 1
        sc.pointee.Frac64 = 0xFFFF_FFFF
        if sc.pointee.LoopMode != LOOP_PINGPONG { sc.pointee.Backwards = BACKWARDS_LOOP }
        sc.pointee.LoopMode = LOOP_PINGPONG
        sc.pointee.LoopDirection = DIR_BACKWARDS
        sc.pointee.Flags |= SF_LOOP_CHANGED
    }

    // MARK: Waves

    /// A vibrato's or a tremolo's wave where it is: Impulse Tracker's, but one at random that is new
    /// each time.
    private func foreignWave(_ waveform: UInt8, _ position: UInt8) -> Int8 {
        if waveform == 3 { return Int8(truncatingIfNeeded: Int(Random() & 127) - 64) }
        return it2FineSineData[(Int(waveform & 3) << 8) + Int(position)]
    }

    /// A tick of vibrato (H, K, U or the volume column's): moved on first, but on a row's first tick.
    func foreignVibrato(_ hc: IT2HostPointer, movesOn: Bool) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_FREQ_CHANGE
        if movesOn { hc.pointee.VibratoPos &+= hc.pointee.VibratoSpeed }
        let data = foreignWave(hc.pointee.VibratoWaveform, hc.pointee.VibratoPos)
        hc.pointee.LastVibratoData = data
        CommandH5(hc, sc, data)
    }

    /// A tick of tremolo: moved on after it has played, but on a row's first tick.
    func foreignTremolo(_ hc: IT2HostPointer, movesOn: Bool) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_RECALC_VOL
        let data = foreignWave(hc.pointee.TremoloWaveform, hc.pointee.TremoloPos)
        hc.pointee.LastTremoloData = data
        CommandR2(hc, sc, data)
        if movesOn { hc.pointee.TremoloPos &+= hc.pointee.TremoloSpeed }
    }
}
