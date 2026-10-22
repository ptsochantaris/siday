// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how it plays a module of X-Tracker's (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`).

import SidayFoundation

/// What X-Tracker does otherwise than Impulse Tracker, for a module of X-Tracker's (see `DMFFile` and
/// `IT2Module.playsAsXTracker`). X-Tracker's replayer has never been published; this is how OpenMPT
/// plays these files, which is as Impulse Tracker plays its own but for these:
///  - Two commands Impulse Tracker has not: a note's volume set from the command (which OpenMPT has
///    room for where the volume column is taken), and a note tuned by up to a semitone either way,
///    which a note struck on an instrument takes away again.
///  - The volume column's slides of pitch go up to 63, not nine; and it can play a sample backwards
///    or forwards, as S9F and S9E do.
///  - A vibrato plays where its wave is on a row's first tick, and moves on along it only after; and
///    every note struck starts the wave again, whether or not its row has a vibrato.
///  - A tremolo only ever turns a note down, by a share of its volume, and moves on along its wave
///    after each tick but a row's first, so that the first two are alike.
///  - A note that is cut is turned down to nothing as well, so that the next note on a sample with no
///    volume of its own is silent until it is given one.
///  - A tick lasts a whole number of frames, what is over cut off, as in OpenMPT's "classic" timing.
extension IT2Player {
    /// The numbers the replayer knows two commands by that Impulse Tracker has not: the volume, and
    /// the tuning (which is the number of an MPTM file's finetune).
    static let xTrackerVolume: UInt8 = 27, xTrackerFinetune: UInt8 = 30
    /// The volume column's bytes beyond Impulse Tracker's: slides of pitch down and up faster than
    /// nine, whose speeds are kept beside them (`IT2Module.xTrackerSlides`); and from this, the
    /// sample played forwards and then backwards.
    static let xTrackerWideDown: UInt8 = 233, xTrackerWideUp: UInt8 = 234, xTrackerForwards: UInt8 = 245

    /// Where a cell is, as a number: its pattern, its row (of up to 4,096) and its channel.
    static func xTrackerPlace(pattern: Int, row: Int, channel: Int) -> Int {
        (pattern << 18) | (row << 6) | channel
    }

    /// A row's note and instrument, as OpenMPT sees to them for these files: an instrument named
    /// takes the tuning away, unless the note is slid to on the same sample; and a cut turns the
    /// channel's volume down.
    func xTrackerRow(_ hc: IT2HostPointer) {
        let mask = hc.pointee.NotePackMask
        if mask & 0x22 != 0, hc.pointee.Bend != 0 {
            let sameSample = hc.pointee.SlaveChnPtr.map { Int($0.pointee.Smp) + 1 == Int(hc.pointee.Ins) } ?? false
            if !slides(hc) || !sameSample || hc.pointee.Flags & HF_CHAN_ON == 0 { hc.pointee.Bend = 0 }
        }
        if mask & 0x11 != 0, hc.pointee.RawNote == 254 { hc.pointee.VolSet = 0 }
        // A note struck starts the vibrato's wave again, whether or not its row has a vibrato.
        if mask & 0x11 != 0, hc.pointee.RawNote < 120, !slides(hc) || hc.pointee.Flags & HF_CHAN_ON == 0 { hc.pointee.VibratoPos = 0 }
    }

    /// True if the row slides to its note, by the command or the volume column.
    private func slides(_ hc: IT2HostPointer) -> Bool {
        let mask = hc.pointee.NotePackMask
        return mask & 0x88 != 0 && (hc.pointee.Cmd == 7 || hc.pointee.Cmd == 12) || mask & 0x44 != 0 && hc.pointee.RawVolColumn >= 193 && hc.pointee.RawVolColumn <= 202
    }

    /// A step of the wave of vibrato or tremolo where it is.
    private func xTrackerWave(_ waveform: UInt8, _ position: UInt8) -> Int8 {
        waveform == 3 ? Int8(truncatingIfNeeded: Int(Random() & 127) - 64) : it2FineSineData[(Int(waveform & 3) << 8) + Int(position)]
    }

    /// The first tick of a vibrato, which plays where the wave is and does not move it on.
    func xTrackerVibrato(_ hc: IT2HostPointer) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_FREQ_CHANGE
        let data = xTrackerWave(hc.pointee.VibratoWaveform, hc.pointee.VibratoPos)
        hc.pointee.LastVibratoData = data
        CommandH5(hc, sc, data)
    }

    /// A tick of tremolo, which only ever turns the note down: by as much of its volume as the depth
    /// says, and more where the wave is lower. It moves on along its wave after every tick but a row's first.
    func xTrackerTremolo(_ hc: IT2HostPointer, movesOn: Bool) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_RECALC_VOL
        let data = Int(xTrackerWave(hc.pointee.TremoloWaveform, hc.pointee.TremoloPos))
        hc.pointee.LastTremoloData = Int8(data)
        // (Reckoned in 256ths, as OpenMPT keeps a volume, with its depth, which is twice what is kept here.)
        var vol = Int(sc.pointee.Vol) * 4
        vol -= vol * Int(hc.pointee.TremoloDepth) * 2 * (64 - data) / (128 * 64)
        sc.pointee.Vol = UInt8(max(0, min(64, (vol + 2) / 4)))
        if movesOn { hc.pointee.TremoloPos &+= hc.pointee.TremoloSpeed }
    }

    /// The volume, from the command.
    func InitCommandXTrackerVolume(_ hc: IT2HostPointer) {
        InitNoCommand(hc)
        let vol = min(hc.pointee.CmdVal, 64)
        hc.pointee.VolSet = vol
        if hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr {
            sc.pointee.VolSet = vol
            sc.pointee.Vol = vol
            sc.pointee.Flags |= SF_RECALC_VOL
        }
    }

    /// The tuning: the channel's notes bent by so many 128ths of a semitone from the middle, 128.
    func InitCommandXTrackerFinetune(_ hc: IT2HostPointer) {
        InitNoCommand(hc)
        hc.pointee.Bend = Int16(Int(hc.pointee.CmdVal) << 8 - 0x8000)
    }

    /// A voice's pitch, bent by its channel's tuning at the end of a tick, after everything else has
    /// moved it: a semitone at the most either way.
    func xTrackerBend(_ sc: IT2SlavePointer) {
        if sc.pointee.HostChnNum & CHN_DISOWNED == 0, let hc = sc.pointee.HostChnPtr { sc.pointee.Bend = hc.pointee.Bend }
        guard sc.pointee.Bend != 0 else { return }
        let rate = (Double(sc.pointee.Frequency) * pow(2.0, Double(sc.pointee.Bend) / (12 * 256 * 128))).rounded()
        sc.pointee.Frequency = rate >= 0 && rate < Double(Int32.max) ? Int32(rate) : Int32.max
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// For the volume column's bytes beyond Impulse Tracker's that are slides of pitch: the slide, as
    /// Impulse Tracker's numbering of the column's effects has it (4 down and 5 up), and its speed;
    /// nil for any other byte.
    func xTrackerColumn(_ hc: IT2HostPointer) -> (command: UInt8, value: UInt8)? {
        let raw = hc.pointee.RawVolColumn
        guard raw == Self.xTrackerWideDown || raw == Self.xTrackerWideUp else { return nil }
        let speed = module.xTrackerSlides[Self.xTrackerPlace(pattern: Int(CurrentPattern), row: Int(CurrentRow), channel: Int(hc.pointee.HostChnNum))]
        return (raw == Self.xTrackerWideDown ? 4 : 5, speed ?? 0)
    }

    /// For the volume column's bytes beyond Impulse Tracker's that play a sample forwards or
    /// backwards: does that, and says it has.
    func xTrackerPlayDirection(_ hc: IT2HostPointer) -> Bool {
        let raw = hc.pointee.RawVolColumn
        guard raw == Self.xTrackerForwards || raw == Self.xTrackerForwards + 1 else { return false }
        OpenMPTCommandS9(hc, raw == Self.xTrackerForwards ? 0xE : 0xF)
        return true
    }
}
