// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how it plays a module of Disorder Tracker 2's (`soundlib/Snd_fx.cpp`).

/// What Disorder Tracker 2 does otherwise than Impulse Tracker, for one of its modules (see `PLMFile`
/// and `IT2Module.playsAsDisorderTracker`). Its replayer has never been published; OpenMPT plays these
/// files by Impulse Tracker's rules, with its "old effects", but for these:
///  - A slide to a note remembers its speed with the slides up and down, as Impulse Tracker's does
///    without "compatible Gxx"; and yet one to a note of another sample goes on with the sample the
///    channel last played, as it does with it, which stays the channel's sample from then on.
///  - After a slide up or down, a slide to a note with none of its own goes on the same way, as
///    far as a slide can, whatever note it was going to (see `disorderTrackerSlidAway`). A slide
///    to a note from F0 up is a fine one, by the rest, made once at the row's start.
///  - A sample's place between the speakers is its notes', and not the channel's from then on.
///  - A start into a sample (Oxx) with no note moves the note that is playing; and there is a start
///    by so many 256ths of the sample's length (see `IT2Module.disorderTrackerOffsets`).
extension IT2Player {
    /// A slide to a note (Gxx or Lxy) on a row that names a sample: the sample the channel last
    /// played stays, if it has played one, and is the channel's sample from then on, whether its
    /// note is still sounding or not. (If not, it is started again at the row's note.)
    func disorderTrackerKeepSample(_ hc: IT2HostPointer) {
        guard hc.pointee.NotePackMask & 0x22 != 0, hc.pointee.Ins != 0, let sc = hc.pointee.SlaveChnPtr, sc.pointee.SmpPtr != nil else { return }
        hc.pointee.Smp = sc.pointee.Smp &+ 1
        hc.pointee.Ins = UInt8(truncatingIfNeeded: hc.pointee.Smp)
    }

    /// A slide up or down (Fxx or Exx) leaves a slide to a note with none of its own to go on the
    /// same way, as far as a slide can: up to 65,535 Hz after a slide up, and down to 1 Hz after one
    /// down. That is what OpenMPT means it to do ("a follow-up tone portamento" goes "the same
    /// direction"), by a period of 1 and one of 65,535; but these files' pitches are rates to it and
    /// not periods, and so its own slide goes the other way. (No file to hand has such a slide.)
    func disorderTrackerSlidAway(_ hc: IT2HostPointer, up: Bool) {
        hc.pointee.PortaFreq = up ? 65535 : 1
        hc.pointee.Flags |= HF_PITCH_SLIDE_ONGOING
    }

    /// Gxx (or Lxy) of F0 or more: a fine slide to the note by the rest, made now, and not on the
    /// row's later ticks.
    func disorderTrackerFineSlide(_ hc: IT2HostPointer) {
        let speed = hc.pointee.EfxMem_EFG
        guard speed >= 0xF0, hc.pointee.Flags & HF_CHAN_ON != 0 else { return }
        hc.pointee.Flags &= ~(HF_UPDATE_EFX_IF_CHAN_ON | HF_ALWAYS_UPDATE_EFX)
        guard hc.pointee.Flags & HF_PITCH_SLIDE_ONGOING != 0, let sc = hc.pointee.SlaveChnPtr, sc.pointee.FrequencySet != hc.pointee.PortaFreq else { return }
        hc.pointee.MiscEfxData[0] = (speed - 0xF0) << 2
        hc.pointee.MiscEfxData[1] = 0
        hc.pointee.MiscEfxData[2] = sc.pointee.FrequencySet > hc.pointee.PortaFreq ? 0 : 1
        CommandG(hc)
    }

    /// Oxx, once its row's note (if it has one) has been started: where in the sample the voice is to
    /// be, from Oxx and SAx, or by 256ths of its length (up to its loop's end) if the file says so.
    /// Without a note it moves the note that is playing. Past the end, it is at the very end, as
    /// with Impulse Tracker's "old effects".
    func disorderTrackerOffset(_ hc: IT2HostPointer) {
        guard hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr, sc.pointee.SmpPtr != nil else { return }
        let end = Int64(max(0, sc.pointee.LoopEnd))
        var offset: Int64
        if let share = module.disorderTrackerOffsets[OpenMPTSong.place(pattern: Int(CurrentPattern), row: Int(CurrentRow), channel: Int(hc.pointee.HostChnNum))] {
            offset = end * Int64(share) / 256
        } else {
            offset = ((Int64(hc.pointee.HighSmpOffs) << 8) | Int64(hc.pointee.EfxMem_O)) << 8
        }
        if offset >= end { offset = max(0, end - 1) }
        sc.pointee.SamplingPosition = Int32(truncatingIfNeeded: offset)
        sc.pointee.Frac32 = 0
        sc.pointee.Frac64 = 0
    }
}
