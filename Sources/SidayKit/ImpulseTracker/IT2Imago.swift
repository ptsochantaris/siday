// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// what its player does for a module of Imago Orpheus's that it does not for an IT file
// (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`, `soundlib/Snd_flt.cpp`).

/// What OpenMPT does otherwise than for an IT file, for a module of Imago Orpheus's (see `IMFFile`
/// and `IT2Module.imagoOrpheus`). OpenMPT reads these files into the shape of an IT file and plays
/// them by Impulse Tracker's rules, but where its player asks whether a file is an IT file, and
/// these are not; so these few things are as its player has them for other kinds of file:
///  - A vibrato and a tremolo play the wave where it is on a row's first tick, and move on only
///    on the ticks after (and a tremolo after it has played); and a note starts a vibrato's wave
///    again.
///  - An instrument named alone plays the channel's last note that had a sample of its instrument,
///    and on a channel that has played nothing, or has had its key let go since, nothing.
///  - A slide to a note brings back a note whose key has been let go: it stops fading and is
///    whole again (see `imagoSlideRevives`).
///  - A slide of volume or of the place between the speakers with both halves of its value goes
///    by the second, down or to the right, where Impulse Tracker's does nothing; S00 and T00 are
///    nothing, and not the last again; SC0 cuts the note at once, and SD0 does not hold it up; and
///    a global volume above the top is the top, where Impulse Tracker's is nothing.
///  - A fade is finer, as OpenMPT keeps it (see `madTrackerFadeStep`).
///  - The filter's cutoffs are as OpenMPT has them for these files (see `IT2Module.Filter.imagoOrpheus`).
extension IT2Player {
    /// A slide to a note, beside its note, on a voice that is sounding: as OpenMPT plays these files,
    /// a voice whose key has been let go stops fading, and is whole again; and beside an instrument,
    /// its key is held again. One whose key is still let go goes on without fading until its
    /// envelope for volume has ended.
    func imagoSlideRevives(_ hc: IT2HostPointer, _ sc: IT2SlavePointer) {
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
        sc.pointee.ImagoRevived = sc.pointee.Flags & SF_NOTE_OFF != 0
    }

    /// An instrument named alone, as its row is read: for the channel's last note (see `imagoNotes`).
    func imagoInstrumentAlone(_ hc: IT2HostPointer) {
        if hc.pointee.NotePackMask & 0x11 == 0, hc.pointee.NotePackMask & 0x22 != 0 {
            hc.pointee.RawNote = imagoNotes[Int(hc.pointee.HostChnNum) & 63]
        }
    }

    /// A channel's part of a row as it is read, once its note has been found a sample: the note is
    /// the channel's from then on.
    func imagoRow(_ hc: IT2HostPointer) {
        if hc.pointee.NotePackMask & 0x11 != 0 { imagoNotes[Int(hc.pointee.HostChnNum) & 63] = hc.pointee.RawNote }
    }

    /// A vibrato's or a tremolo's wave where it is: Impulse Tracker's, but one at random that is new
    /// each time.
    private func imagoWave(_ waveform: UInt8, _ position: UInt8) -> Int8 {
        if waveform == 3 { return Int8(truncatingIfNeeded: Int(Random() & 127) - 64) }
        return it2FineSineData[(Int(waveform & 3) << 8) + Int(position)]
    }

    /// A tick of vibrato (H, K, U or the volume column's): moved on first, but on a row's first tick.
    func imagoVibrato(_ hc: IT2HostPointer, movesOn: Bool) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_FREQ_CHANGE
        if movesOn { hc.pointee.VibratoPos &+= hc.pointee.VibratoSpeed }
        let data = imagoWave(hc.pointee.VibratoWaveform, hc.pointee.VibratoPos)
        hc.pointee.LastVibratoData = data
        CommandH5(hc, sc, data)
    }

    /// A tick of tremolo: moved on after it has played, but on a row's first tick.
    func imagoTremolo(_ hc: IT2HostPointer, movesOn: Bool) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_RECALC_VOL
        let data = imagoWave(hc.pointee.TremoloWaveform, hc.pointee.TremoloPos)
        hc.pointee.LastTremoloData = data
        CommandR2(hc, sc, data)
        if movesOn { hc.pointee.TremoloPos &+= hc.pointee.TremoloSpeed }
    }
}
