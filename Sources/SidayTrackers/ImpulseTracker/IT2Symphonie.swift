// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// what its player does for a module of Symphonie's that it does for no file of its own
// (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`, `soundlib/Fastmix.cpp`, `soundlib/ModChannel.cpp`).

/// What OpenMPT makes of a cell of Symphonie's that an IT file's cell has no room for, kept beside it
/// (see `IT2Module.symphonieCells`).
struct IT2SymphonieCell {
    /// Nought to stop the channel's sample where it is, one to let it go on from there.
    var playControl: UInt8?
    /// How far into its sample the row's note starts, in 256ths of it (or of its loop's end).
    var offset: UInt8?
    /// True for a slide to the row's note that is there at once.
    var atOnce = false
}

/// What OpenMPT does for a module of Symphonie's that no file of its own asks for, which is played
/// here too (see `SymMODFile` and `IT2Module.playsAsSymphonie`):
///  - A channel's sample can be stopped where it is, and let go on again from there: the voice is
///    neither heard nor moved on while it is stopped (see `IT2SlaveChannel.Paused`), and a note
///    lets it go.
///  - A note can start so many 256ths of the way into its sample; and beside a slide to it, the
///    sound that is playing goes on from there, sliding.
///  - A note can be slid to in no time, which changes the pitch of the sound that is playing and
///    does not start it again.
///  - A vibrato and a tremolo, once given a depth, go on by themselves on the rows after, under
///    whatever else those rows say, until one of no depth or a note stops them.
///  - A macro can turn the filter about, to let the high through and not the low, or back.
extension IT2Player {
    /// What a row of such a module does besides what its cells do, once they have done it: for each
    /// of the 64 channels, and `read` saying which had a cell on the row.
    func symphonieRow(read: UInt64) {
        let pattern = Int(CurrentPattern), row = Int(CurrentRow)
        symphonieOwnEffects = 0
        for channel in 0 ..< MAX_HOST_CHANNELS {
            let bit: UInt64 = 1 << UInt64(channel)
            let hc = hChn + channel
            let mask = read & bit != 0 ? hc.pointee.NotePackMask : 0
            let hasNote = mask & 0x11 != 0 && hc.pointee.RawNote < 120
            if hasNote {
                // A note stops the vibrato and tremolo that were going on by themselves, and lets
                // a stopped sample go on.
                symphonieVibratos &= ~bit
                symphonieTremolos &= ~bit
                if hc.pointee.Flags & HF_CHAN_ON != 0 { hc.pointee.SlaveChnPtr?.pointee.Paused = false }
            }
            if mask & 0x88 != 0 {
                if hc.pointee.Cmd == 8 {
                    symphonieOwnEffects |= bit
                    if hc.pointee.CmdVal != 0 { symphonieVibratos |= bit } else { symphonieVibratos &= ~bit }
                } else if hc.pointee.Cmd == 18 {
                    symphonieOwnEffects |= bit
                    if hc.pointee.CmdVal & 0x0F != 0 { symphonieTremolos |= bit } else { symphonieTremolos &= ~bit }
                }
            }

            if let cell = module.symphonieCells[OpenMPTSong.place(pattern: pattern, row: row, channel: channel)],
               hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr {
                if cell.atOnce, hasNote, hc.pointee.Flags & HF_PITCH_SLIDE_ONGOING != 0 {
                    sc.pointee.Frequency = hc.pointee.PortaFreq
                    sc.pointee.FrequencySet = hc.pointee.PortaFreq
                    sc.pointee.Flags |= SF_FREQ_CHANGE
                    hc.pointee.Flags &= ~(HF_PITCH_SLIDE_ONGOING | HF_UPDATE_EFX_IF_CHAN_ON)
                }
                if let control = cell.playControl {
                    if control == 0 { sc.pointee.Paused = true } else if control == 1 { sc.pointee.Paused = false }
                }
                if let offset = cell.offset, hasNote || mask & 0x22 != 0 {
                    // Within what is played of the sample: past it, from its start.
                    let length = Int64(max(0, sc.pointee.LoopEnd))
                    var at = length * Int64(offset) / 256
                    if at >= length { at = 0 }
                    sc.pointee.SamplingPosition = Int32(truncatingIfNeeded: at)
                    sc.pointee.Frac32 = 0
                    sc.pointee.Frac64 = 0
                }
            }
            symphonieTick(hc)
        }
    }

    /// A tick of the vibrato and the tremolo that go on by themselves, for a channel that has no
    /// vibrato or tremolo of its own on this row.
    func symphonieTick(_ hc: IT2HostPointer) {
        let bit: UInt64 = 1 << UInt64(hc.pointee.HostChnNum & 63)
        guard (symphonieVibratos | symphonieTremolos) & bit != 0, symphonieOwnEffects & bit == 0, hc.pointee.Flags & HF_CHAN_ON != 0 else { return }
        if symphonieVibratos & bit != 0 { CommandH(hc) }
        if symphonieTremolos & bit != 0 { CommandR(hc) }
    }

    /// F0F002xx: the channel's filter lets the low through for x below 16, and the high for x from
    /// 16 to 31.
    func symphonieFilterMode(_ hc: IT2HostPointer, _ sc: IT2SlavePointer?, _ value: UInt8) {
        guard value < 0x20 else { return }
        hc.pointee.HighPass = value >> 4 == 1
        guard let sc, sc.pointee.HostChnNum == hc.pointee.HostChnNum else { return }
        sc.pointee.HighPass = hc.pointee.HighPass
        sc.pointee.FilterSet = true
        sc.pointee.Flags |= SF_UPDATE_MIXERVOL
    }
}
