// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from it2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): his C port of the replayer of Impulse Tracker 2.15, made from that tracker's
// own assembly. The names are the original's, as in the other ports here.
//
// The few lines that are there for an MPTM file, and say so, are derived from OpenMPT, Copyright (c)
// 2004-2026 OpenMPT Project Developers and Contributors and Copyright (c) 1997-2003 Olivier Lapicque,
// used under the BSD 3-Clause licence (see THIRD-PARTY.md, and `IT2OpenMPT.swift`).

/// How fast the volume column's Gx slides, for x from 1 to 9.
private let SlideTable: [UInt8] = [1, 4, 8, 16, 32, 64, 96, 128, 255]

/// The effects: what each does when its row is read (the `Init` routines), what it does on the
/// ticks after (the others), and the volume column's own.
///
/// An effect has sixteen bytes of its channel to work in, `MiscEfxData`, which mean something
/// different to each; some keep sixteen-bit numbers there, low byte first.
extension IT2Player {
    // MARK: Which routine an effect is

    /// An effect as its row is read.
    func InitCommand(_ hc: IT2HostPointer) {
        switch hc.pointee.Cmd & 31 {
        case 1: InitCommandA(hc)
        case 2: InitCommandB(hc)
        case 3: InitCommandC(hc)
        case 4: InitCommandD(hc)
        case 5: InitCommandE(hc)
        case 6: InitCommandF(hc)
        case 7: InitCommandG(hc)
        case 8: InitCommandH(hc)
        case 9: InitCommandI(hc)
        case 10: InitCommandJ(hc)
        case 11: InitCommandK(hc)
        case 12: InitCommandL(hc)
        case 13: InitCommandM(hc)
        case 14: InitCommandN(hc)
        case 15: InitCommandO(hc)
        case 16: InitCommandP(hc)
        case 17: InitCommandQ(hc)
        case 18: InitCommandR(hc)
        case 19: InitCommandS(hc)
        case 20: InitCommandT(hc)
        case 21: InitCommandU(hc)
        case 22: InitCommandV(hc)
        case 23: InitCommandW(hc)
        case 24: InitCommandX(hc)
        case 25: InitCommandY(hc)
        case 26: InitCommandZ(hc)
        case IT2Player.xTrackerVolume where module.playsAsXTracker: InitCommandXTrackerVolume(hc) // X-Tracker's volume
        case 27 where module.velvetStudio: InitCommandVelvetKeyOff(hc) // Velvet Studio's key let go
        case 28 where smoothMacros: InitCommandSmoothMacro(hc) // ModPlug Tracker's \xx
        case 29 where module.openMPT != nil: InitCommandDelayCut(hc) // an MPTM file's :xy
        case 30 where module.openMPT != nil: InitCommandBend(hc, smooth: false) // and its finetune, + and *
        case 31 where module.openMPT != nil: InitCommandBend(hc, smooth: true)
        case IT2Player.xTrackerFinetune where module.playsAsXTracker: InitCommandXTrackerFinetune(hc) // and its tuning
        default: InitNoCommand(hc)
        }
    }

    /// An effect on the ticks after its row's first. (The original's table has thirty entries for
    /// thirty-two numbers; the two beyond it do nothing here.)
    func Command(_ hc: IT2HostPointer) {
        switch hc.pointee.Cmd & 31 {
        case 4: CommandD(hc)
        case 5: CommandE(hc)
        case 6: CommandF(hc)
        case 7: CommandG(hc)
        case 8, 21: CommandH(hc) // U, the fine vibrato, is H's
        case 9: CommandI(hc)
        case 10: CommandJ(hc)
        case 11: CommandK(hc)
        case 12: CommandL(hc)
        case 14: CommandN(hc)
        case 16: CommandP(hc)
        case 17: CommandQ(hc)
        case 18: CommandR(hc)
        case 19: CommandS(hc)
        case 20: CommandT(hc)
        case 23: CommandW(hc)
        case 25: CommandY(hc)
        case 28 where smoothMacros: CommandSmoothMacro(hc)
        case 29 where module.openMPT != nil: CommandDelayCut(hc)
        case 31 where module.openMPT != nil: CommandBend(hc)
        default: NoCommand(hc)
        }
    }

    /// The volume column's effect on the ticks after its row's first.
    func VolumeEffect(_ hc: IT2HostPointer) {
        switch hc.pointee.VolCmd & 7 {
        case 2: VolumeCommandC(hc)
        case 3: VolumeCommandD(hc)
        case 4: VolumeCommandE(hc)
        case 5: VolumeCommandF(hc)
        case 6: VolumeCommandG(hc)
        case 7: CommandH(hc)
        default: NoCommand(hc)
        }
    }

    func NoCommand(_: IT2HostPointer) {}

    // MARK: Shared by several

    /// A sixteen-bit number among an effect's working bytes.
    @inline(__always) private func MiscEfxWord(_ hc: IT2HostPointer, _ at: Int) -> UInt16 {
        UInt16(hc.pointee.MiscEfxData[at]) | (UInt16(hc.pointee.MiscEfxData[at + 1]) << 8)
    }

    @inline(__always) private func SetMiscEfxWord(_ hc: IT2HostPointer, _ at: Int, _ value: UInt16) {
        hc.pointee.MiscEfxData[at] = UInt8(truncatingIfNeeded: value)
        hc.pointee.MiscEfxData[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    /// The rate a voice's sample is played at for a note (which is below 120). An instrument of an
    /// MPTM file may have a tuning of its own, and then the note's rate is what that makes of it
    /// (and what the note does after that is worked out otherwise: see `openMPTTunedPitch`).
    @inline(__always) private func noteFrequency(_ sc: IT2SlavePointer, _ note: UInt8) -> Int32 {
        let s = sc.pointee.SmpPtr
        // (And a note for the FM chip is kept sixteen times finer than a sample's rate needs to be:
        // see `OpenMPTAdLib.fineShift`.)
        let fine = fineFMPitch && s?.AdLib != nil
        if module.playsAsDigitrakker { return digitrakkerFrequency(sc, note) }
        if let tuning = sc.pointee.InsPtr?.Tuning, sc.pointee.Ins != 0xFF {
            let ratio = tuning.ratio(Int(note) - 60)
            return openMPTTunedFrequency(s, fine ? ratio * Float(1 << OpenMPTAdLib.fineShift) : ratio)
        }
        if pitchesArePeriods { return openMPTPeriodFrequency(sc, note) }
        return Int32(truncatingIfNeeded: (UInt64(s?.C5Speed ?? 0) &* UInt64(it2PitchTable[Int(note)])) >> (fine ? 16 - OpenMPTAdLib.fineShift : 16))
    }

    private func CommandEChain(_ hc: IT2HostPointer, _ SlideValue: UInt16) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        PitchSlideDown(hc, sc, Int16(bitPattern: SlideValue))
        sc.pointee.FrequencySet = sc.pointee.Frequency
    }

    private func CommandFChain(_ hc: IT2HostPointer, _ SlideValue: UInt16) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        PitchSlideUp(hc, sc, Int16(bitPattern: SlideValue))
        sc.pointee.FrequencySet = sc.pointee.Frequency
    }

    private func CommandD2(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ vol: UInt8) {
        hc.pointee.VolSet = vol
        sc.pointee.VolSet = vol
        sc.pointee.Vol = vol
        sc.pointee.Flags |= SF_RECALC_VOL
    }

    /// The first tick of a vibrato. With "old effects" it does not move on, but plays where it was.
    private func InitVibrato(_ hc: IT2HostPointer) {
        if module.madTracker { return madTrackerVibrato(hc, moving: false) }
        if module.openMPTForeign { return foreignVibrato(hc, movesOn: false) }
        if module.playsAsDigitrakker {
            digitrakkerVibrato(hc, movesOn: false)
        } else if module.playsAsXTracker {
            xTrackerVibrato(hc)
        } else if module.Flags & ITF_OLD_EFFECTS != 0 {
            guard let sc = hc.pointee.SlaveChnPtr else { return }
            sc.pointee.Flags |= SF_FREQ_CHANGE
            CommandH5(hc, sc, hc.pointee.LastVibratoData)
        } else {
            CommandH(hc)
        }
    }

    /// Sets a volume slide going from what D, K and L remember between them.
    private func InitCommandD7(_ hc: IT2HostPointer, _ sc: IT2SlavePointer) {
        sc.pointee.Flags |= SF_RECALC_VOL
        // (One of Digitrakker's that is finer or faster than these: see `IT2DigitrakkerSlide`.)
        if module.playsAsDigitrakker, digitrakkerInitSlide(hc, sc) { return }

        let hi = hc.pointee.EfxMem_DKL & 0xF0
        let lo = hc.pointee.EfxMem_DKL & 0x0F

        if lo == 0 {
            // Up. (DF0 slides on the first tick as well.)
            hc.pointee.VolSlideDelta = Int8(hi >> 4)
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            // (Not in a module of Digitrakker's, whose slides are by more than fifteen and never
            // on a row's first tick: see `MDLFile.convert`.)
            if hc.pointee.VolSlideDelta == 15, !module.playsAsDigitrakker { CommandD(hc) }
        } else if hi == 0 {
            // Down. (And so does D0F.)
            hc.pointee.VolSlideDelta = -Int8(lo)
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            if hc.pointee.VolSlideDelta == -15, !module.playsAsDigitrakker { CommandD(hc) }
        } else if lo == 0x0F {
            // Up, once.
            hc.pointee.VolSlideDelta = 0
            var vol = sc.pointee.VolSet &+ (hi >> 4)
            if vol > 64 { vol = 64 }
            hc.pointee.VolSet = vol
            sc.pointee.VolSet = vol
            sc.pointee.Vol = vol
        } else if hi == 0xF0 {
            // Down, once.
            hc.pointee.VolSlideDelta = 0
            var vol = sc.pointee.VolSet &- lo
            if Int8(bitPattern: vol) < 0 { vol = 0 }
            hc.pointee.VolSet = vol
            sc.pointee.VolSet = vol
            sc.pointee.Vol = vol
        } else if module.openMPTForeign {
            // (Impulse Tracker does nothing with both halves; OpenMPT, for a module of Imago
            // Orpheus's or Velvet Studio's, slides down by the second.)
            hc.pointee.VolSlideDelta = -Int8(lo)
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
        }
    }

    // MARK: The volume column

    /// The volume column's effect as its row is read. They are numbered from 0: fine slides of
    /// volume up and down (done here and now), slides of volume up and down, of pitch down and up,
    /// a slide to the note, and vibrato. The first four remember their value together; the slides of
    /// pitch share E, F and G's.
    private func InitVolumeEffect(_ hc: IT2HostPointer) {
        if hc.pointee.NotePackMask & 0x44 == 0 { return }
        // (In an MPTM file these are where in its sample a note starts, and nothing more.)
        if module.openMPT != nil, hc.pointee.RawVolColumn >= 213, hc.pointee.RawVolColumn <= 232 { return }
        // (And in a module of X-Tracker's, beyond them, the way a sample plays, and faster slides of
        // pitch: see `xTrackerColumn`.)
        if module.playsAsXTracker, xTrackerPlayDirection(hc) { return }

        var volCmd = Int(hc.pointee.RawVolColumn & 0x7F) - 65
        if volCmd < 0 { return }
        if hc.pointee.RawVolColumn & 0x80 != 0 { volCmd += 60 }

        var cmd = UInt8(volCmd / 10)
        var val = UInt8(volCmd % 10)
        if module.playsAsXTracker, let wide = xTrackerColumn(hc) { (cmd, val) = wide }

        // Numbers over 7 can be written in a file; they are kept, and it is the low three bits that
        // choose what runs on the later ticks.
        hc.pointee.VolCmd = cmd

        if val > 0 {
            if cmd < 4 {
                hc.pointee.VolCmdVal = val
            } else if cmd < 6 {
                hc.pointee.EfxMem_EFG = val << 2
            } else if cmd == 6 {
                if module.Flags & ITF_COMPAT_GXX != 0 {
                    hc.pointee.EfxMem_G_Compat = SlideTable[Int(val) - 1]
                } else {
                    hc.pointee.EfxMem_EFG = SlideTable[Int(val) - 1]
                }
            }
        }

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            if cmd > 1 {
                hc.pointee.Flags |= HF_UPDATE_VOLEFX_IF_CHAN_ON

                if cmd > 6 {
                    if val != 0 {
                        hc.pointee.VibratoDepth = val << 2
                        // (As deep as the command's, to OpenMPT, in a module it does not take for an IT file.)
                        if module.openMPTForeign, module.Flags & ITF_OLD_EFFECTS != 0 { hc.pointee.VibratoDepth <<= 1 }
                    }
                    if hc.pointee.Flags & HF_CHAN_ON != 0 { InitVibrato(hc) }
                } else if cmd == 6 {
                    InitCommandG11(hc)
                    if tuning(of: hc) != nil { VolumeCommandG(hc) }
                } else if cmd >= 4, tuning(of: hc) != nil {
                    // (OpenMPT's slides, for an instrument with a tuning of its own, start on the first tick.)
                    if cmd == 4 { VolumeCommandE(hc) } else { VolumeCommandF(hc) }
                }
            } else if cmd == 1 {
                // Fine slide down.
                guard let sc = hc.pointee.SlaveChnPtr else { return }
                var vol = Int8(bitPattern: sc.pointee.VolSet &- hc.pointee.VolCmdVal)
                if vol < 0 { vol = 0 }
                CommandD2(hc, sc, UInt8(bitPattern: vol))
            } else {
                // Fine slide up.
                guard let sc = hc.pointee.SlaveChnPtr else { return }
                var vol = Int8(bitPattern: sc.pointee.VolSet &+ hc.pointee.VolCmdVal)
                if vol > 64 { vol = 64 }
                CommandD2(hc, sc, UInt8(bitPattern: vol))
            }
        } else if cmd == 7 {
            // A vibrato on a channel that is not playing still has its depth remembered. (The
            // original goes on to start it if the channel is playing, which here it is not.)
            if val != 0 { hc.pointee.VibratoDepth = val << 2 }
        }
    }

    func VolumeCommandC(_ hc: IT2HostPointer) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        var vol = Int8(bitPattern: sc.pointee.VolSet &+ hc.pointee.VolCmdVal)
        if vol > 64 {
            hc.pointee.Flags &= ~HF_UPDATE_VOLEFX_IF_CHAN_ON // it has got there
            vol = 64
        }
        CommandD2(hc, sc, UInt8(bitPattern: vol))
    }

    func VolumeCommandD(_ hc: IT2HostPointer) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        var vol = Int8(bitPattern: sc.pointee.VolSet &- hc.pointee.VolCmdVal)
        if vol < 0 {
            hc.pointee.Flags &= ~HF_UPDATE_VOLEFX_IF_CHAN_ON // it has got there
            vol = 0
        }
        CommandD2(hc, sc, UInt8(bitPattern: vol))
    }

    func VolumeCommandE(_ hc: IT2HostPointer) {
        if tuning(of: hc) != nil { return openMPTTunedSlide(hc, -Int32(hc.pointee.EfxMem_EFG), alwaysWhole: true) }
        CommandEChain(hc, UInt16(hc.pointee.EfxMem_EFG) << 2)
    }

    func VolumeCommandF(_ hc: IT2HostPointer) {
        if tuning(of: hc) != nil { return openMPTTunedSlide(hc, Int32(hc.pointee.EfxMem_EFG), alwaysWhole: true) }
        CommandFChain(hc, UInt16(hc.pointee.EfxMem_EFG) << 2)
    }

    func VolumeCommandG(_ hc: IT2HostPointer) {
        if tuning(of: hc) != nil { return openMPTTunedSlideToNote(hc, module.Flags & ITF_COMPAT_GXX != 0 ? hc.pointee.EfxMem_G_Compat : hc.pointee.EfxMem_EFG) }
        if hc.pointee.Flags & HF_PITCH_SLIDE_ONGOING == 0 { return }

        let SlideValue = Int16(module.Flags & ITF_COMPAT_GXX != 0 ? hc.pointee.EfxMem_G_Compat : hc.pointee.EfxMem_EFG) << 2
        if SlideValue == 0 { return }

        guard let sc = hc.pointee.SlaveChnPtr else { return }

        if hc.pointee.MiscEfxData[2] == 1 {
            // Up.
            PitchSlideUp(hc, sc, SlideValue)
            sc.pointee.FrequencySet = sc.pointee.Frequency

            if sc.pointee.Flags & SF_NOTE_STOP != 0 || sc.pointee.Frequency >= hc.pointee.PortaFreq {
                // There (or past what a slide can reach, which stops the note: it is started again).
                sc.pointee.Flags &= ~SF_NOTE_STOP
                hc.pointee.Flags |= HF_CHAN_ON

                sc.pointee.Frequency = hc.pointee.PortaFreq
                sc.pointee.FrequencySet = hc.pointee.PortaFreq
                hc.pointee.Flags &= ~(HF_PITCH_SLIDE_ONGOING | HF_UPDATE_VOLEFX_IF_CHAN_ON)
            }
        } else {
            // Down.
            PitchSlideDown(hc, sc, SlideValue)

            if sc.pointee.Frequency <= hc.pointee.PortaFreq {
                sc.pointee.Frequency = hc.pointee.PortaFreq
                hc.pointee.Flags &= ~(HF_PITCH_SLIDE_ONGOING | HF_UPDATE_VOLEFX_IF_CHAN_ON)
            }

            sc.pointee.FrequencySet = sc.pointee.Frequency
        }
    }

    // MARK: A row's note, instrument and volume

    /// The last of a row's note: the channel's flags are settled (their low byte is carried about
    /// in `hcFlags` while the note is seen to), the instrument's random swings applied to a note
    /// just started, and the volume column's effect begun.
    private func InitNoCommand3(_ hc: IT2HostPointer, _ hcFlags: UInt8) {
        let ApplyRandomVolume = hc.pointee.Flags & HF_APPLY_RANDOM_VOL != 0

        hc.pointee.Flags = (hc.pointee.Flags & 0xFF00) | UInt16(hcFlags)

        // (A note struck again in OpenMPT's own way, after its sample has ended, has no new swing.)
        if ApplyRandomVolume { if restriking { hc.pointee.Flags &= ~HF_APPLY_RANDOM_VOL } else { ApplyRandomValues(hc) } }

        InitVolumeEffect(hc)
    }

    /// The volume a row gives: the volume column's if it is one, else the sample's own if the row
    /// names an instrument.
    func NoOldEffect(_ hc: IT2HostPointer, _ hcFlags: UInt8) {
        var vol = hc.pointee.RawVolColumn
        if hc.pointee.NotePackMask & 0x44 == 0 || vol > 64 {
            if hc.pointee.NotePackMask & 0x44 != 0, vol & 0x7F < 65 {
                // The volume column is a place between the speakers.
                hc.pointee.Flags = (hc.pointee.Flags & 0xFF00) | UInt16(hcFlags)
                InitCommandX2(hc, vol &- 128, by: .roughly)
            }

            if hc.pointee.NotePackMask & 0x22 == 0 || hc.pointee.Smp == 0 {
                InitNoCommand3(hc, hcFlags)
                return
            }

            // (A sample there is none of, as a MIDI note's, has no volume. The original reads past
            // its table.)
            let s = module.playsAsDigitrakker ? digitrakkerRowSample(hc) : module.sample(Int(hc.pointee.Smp) - 1)
            vol = s.map { $0.hasVolume ? $0.Vol : hc.pointee.VolSet } ?? 0
        }

        hc.pointee.VolSet = vol

        if hcFlags & UInt8(HF_CHAN_ON) != 0, let sc = hc.pointee.SlaveChnPtr {
            sc.pointee.VolSet = vol
            sc.pointee.Vol = vol
            sc.pointee.Flags |= SF_RECALC_VOL
        }

        InitNoCommand3(hc, hcFlags)
    }

    private func InitNoCommand11(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ hcFlags: UInt8) {
        GetLoopInformation(sc)

        if hc.pointee.NotePackMask & (0x22 + 0x44) == 0 {
            InitNoCommand3(hc, hcFlags)
            return
        }

        // With "old effects" an instrument named on a row starts its envelopes again.
        if module.Flags & (ITF_INSTR_MODE | ITF_OLD_EFFECTS) == ITF_INSTR_MODE + ITF_OLD_EFFECTS {
            if hc.pointee.NotePackMask & 0x22 != 0, hc.pointee.Ins != 255 {
                sc.pointee.FadeOut = 1024
                InitPlayInstrument(hc, sc, module.instrument(Int(hc.pointee.Ins) - 1))
            }
        }

        NoOldEffect(hc, hcFlags)
    }

    /// What a row does that has no effect, and what every effect's row does besides: its note is
    /// started (or released, cut or faded), and its volume set.
    func InitNoCommand(_ hc: IT2HostPointer) {
        // (Digitrakker's instrument named alone is otherwise: see `digitrakkerInstrumentAlone`.)
        if module.playsAsDigitrakker, hc.pointee.NotePackMask & 0x11 == 0, hc.pointee.NotePackMask & 0x22 != 0, !digitrakkerAlone {
            digitrakkerInstrumentAlone(hc)
            return
        }
        var hcFlags = UInt8(truncatingIfNeeded: hc.pointee.Flags)

        if hc.pointee.NotePackMask & 0x33 == 0 {
            NoOldEffect(hc, hcFlags)
            return
        }

        // Not a note to play: a release (255), a cut (254) or a fade (any other).
        if hc.pointee.TranslatedNote >= 120 {
            if hcFlags & UInt8(HF_CHAN_ON) != 0, let sc = hc.pointee.SlaveChnPtr {
                if hc.pointee.TranslatedNote == 255 {
                    // (MadTracker's, to a note with no envelope for its volume, is silence: see
                    // `madTrackerLetGo`. The row's instrument is then no instrument.)
                    if module.madTracker, !madTrackerLetGo(hc, sc) {
                        let mask = hc.pointee.NotePackMask
                        hc.pointee.NotePackMask &= ~0x22
                        NoOldEffect(hc, hcFlags)
                        hc.pointee.NotePackMask = mask
                        return
                    }
                    sc.pointee.Flags |= SF_NOTE_OFF
                    sc.pointee.ForeignRevived = false
                    InitNoCommand11(hc, sc, hcFlags)
                    return
                } else if hc.pointee.TranslatedNote == 254 {
                    hcFlags &= ~UInt8(HF_CHAN_ON)
                    // The driver ramps volumes, so the voice is told to stop and left to it.
                    sc.pointee.Flags |= SF_NOTE_STOP
                } else {
                    sc.pointee.Flags |= SF_FADEOUT
                }
            }

            NoOldEffect(hc, hcFlags)
            return
        }

        // (In an MPTM file, an instrument alone may start nothing at all: see `openMPTInstrumentAlone`.)
        if ways.instrumentAloneSwapsSample, hc.pointee.NotePackMask & 0x11 == 0 {
            openMPTInstrumentAlone(hc, hcFlags)
            return
        }
        // An instrument alone, the same as is playing and at the same note, starts nothing.
        if hcFlags & UInt8(HF_CHAN_ON) != 0, let sc = hc.pointee.SlaveChnPtr {
            if hc.pointee.NotePackMask & 0x11 == 0, sc.pointee.Note == hc.pointee.RawNote, sc.pointee.Ins == hc.pointee.Ins {
                // (Though in MadTracker's it starts the instrument's envelopes again.)
                if module.madTracker { madTrackerInstrumentAgain(sc) }
                NoOldEffect(hc, hcFlags)
                return
            }
        }
        // (Nor does it ever, in a module of a tracker where it never did: not Impulse Tracker's own.)
        if module.instrumentAloneStartsNothing, hc.pointee.NotePackMask & 0x11 == 0 {
            NoOldEffect(hc, hcFlags)
            return
        }

        // With a slide to the note in the volume column, the note is where to slide to.
        let volColumnPortamento = hc.pointee.RawVolColumn >= 193 && hc.pointee.RawVolColumn <= 202
        if hc.pointee.NotePackMask & 0x44 != 0, volColumnPortamento, hc.pointee.Flags & HF_CHAN_ON != 0 {
            InitVolumeEffect(hc)
            return
        }

        guard let sc = AllocateChannel(hc, &hcFlags) else {
            NoOldEffect(hc, hcFlags)
            return
        }

        // A voice was found for it.
        let s = sc.pointee.SmpPtr

        sc.pointee.VolSet = hc.pointee.VolSet
        sc.pointee.Vol = hc.pointee.VolSet

        if module.Flags & ITF_INSTR_MODE == 0, let s, s.DefPan & 0x80 != 0 {
            var pan = s.DefPan & 127
            placeInSurround(hc, sc, &pan, given: true)
            sc.pointee.Pan = pan
            // (In Disorder Tracker's, as OpenMPT has it, for the note alone.)
            if !module.playsAsDisorderTracker {
                hc.pointee.ChnPan = pan
                hc.pointee.SurroundPanned = sc.pointee.SurroundPanned
            }
        }

        sc.pointee.SamplingPosition = 0
        sc.pointee.Frac32 = 0
        sc.pointee.Frac64 = 0
        sc.pointee.HasLooped = false
        sc.pointee.FrequencySet = noteFrequency(sc, hc.pointee.TranslatedNote)
        sc.pointee.Frequency = sc.pointee.FrequencySet
        // (Digitrakker's vibrato and tremolo start their waves again with every note.)
        if module.playsAsDigitrakker {
            hc.pointee.VibratoPos = 0
            hc.pointee.TremoloPos = 0
            digitrakkerSamples[Int(hc.pointee.HostChnNum) & 63] = s
            digitrakkerNotes[Int(hc.pointee.HostChnNum) & 63] = hc.pointee.RawNote
        }

        hcFlags |= UInt8(HF_CHAN_ON)
        hcFlags &= ~UInt8(HF_PITCH_SLIDE_ONGOING)
        // (OpenMPT starts a vibrato's wave again with every note, in these files.)
        if module.madTracker || module.openMPTForeign { hc.pointee.VibratoPos = 0 }

        InitNoCommand11(hc, sc, hcFlags)
        if module.velvetStudio, s?.reversed == true { velvetBackwards(sc) }
        if module.openMPT != nil { OpenMPTVolumeColumnOffset(hc, sc) }
    }

    // MARK: Effects as their row is read

    /// Axx: the speed, in ticks to a row.
    func InitCommandA(_ hc: IT2HostPointer) {
        if hc.pointee.CmdVal != 0 {
            CurrentTick = (CurrentTick &- CurrentSpeed) &+ UInt16(hc.pointee.CmdVal)
            CurrentSpeed = UInt16(hc.pointee.CmdVal)
        }

        InitNoCommand(hc)
    }

    /// Bxx: on to another place in the list of patterns.
    func InitCommandB(_ hc: IT2HostPointer) {
        // (From the top of the list; but in an MPTM file from the top of the song's own, and by a
        // number that may be more than a byte holds.)
        ProcessOrder = UInt16(truncatingIfNeeded: orderBase + openMPTLongValue(hc)) &- 1
        ProcessRow = 0xFFFE

        InitNoCommand(hc)
    }

    /// Cxx: on to a row of the next pattern.
    func InitCommandC(_ hc: IT2HostPointer) {
        if !PatternLooping {
            BreakRow = UInt16(truncatingIfNeeded: openMPTLongValue(hc))
            ProcessRow = 0xFFFE
        }

        InitNoCommand(hc)
    }

    /// Dxy: a slide of volume.
    func InitCommandD(_ hc: IT2HostPointer) {
        InitNoCommand(hc)

        var CmdVal = hc.pointee.CmdVal
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_DKL }
        hc.pointee.EfxMem_DKL = CmdVal

        if hc.pointee.Flags & HF_CHAN_ON == 0 { return }
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        InitCommandD7(hc, sc)
    }

    /// Exx: a slide of pitch down; EFx and EEx are fine and extra fine ones, done once and now.
    func InitCommandE(_ hc: IT2HostPointer) {
        InitNoCommand(hc)
        if module.playsAsDisorderTracker { disorderTrackerSlidAway(hc, up: false) }

        var CmdVal = hc.pointee.CmdVal
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_EFG }
        hc.pointee.EfxMem_EFG = CmdVal

        if hc.pointee.Flags & HF_CHAN_ON == 0 || hc.pointee.EfxMem_EFG == 0 { return }

        // (OpenMPT's, from the first tick, for an instrument with a tuning of its own.)
        if tuning(of: hc) != nil {
            openMPTTunedSlide(hc, -Int32(hc.pointee.EfxMem_EFG))
            if hc.pointee.EfxMem_EFG & 0xF0 != 0xE0 { hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON }
            return
        }

        if hc.pointee.EfxMem_EFG & 0xF0 < 0xE0 {
            SetMiscEfxWord(hc, 0, UInt16(hc.pointee.EfxMem_EFG) << 2)
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            return
        }

        if hc.pointee.EfxMem_EFG & 0x0F == 0 { return }

        var SlideVal = UInt16(hc.pointee.EfxMem_EFG & 0x0F)
        if hc.pointee.EfxMem_EFG & 0xF0 != 0xE0 { SlideVal <<= 2 }

        guard let sc = hc.pointee.SlaveChnPtr else { return }
        PitchSlideDown(hc, sc, Int16(bitPattern: SlideVal))
        sc.pointee.FrequencySet = sc.pointee.Frequency
    }

    /// Fxx: a slide of pitch up, with its fine and extra fine ones as E's.
    func InitCommandF(_ hc: IT2HostPointer) {
        InitNoCommand(hc)
        if module.playsAsDisorderTracker { disorderTrackerSlidAway(hc, up: true) }

        var CmdVal = hc.pointee.CmdVal
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_EFG }
        hc.pointee.EfxMem_EFG = CmdVal

        if hc.pointee.Flags & HF_CHAN_ON == 0 || hc.pointee.EfxMem_EFG == 0 { return }

        // (OpenMPT's, from the first tick, for an instrument with a tuning of its own.)
        if tuning(of: hc) != nil {
            openMPTTunedSlide(hc, Int32(hc.pointee.EfxMem_EFG))
            if hc.pointee.EfxMem_EFG & 0xF0 != 0xE0 { hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON }
            return
        }

        if hc.pointee.EfxMem_EFG & 0xF0 < 0xE0 {
            SetMiscEfxWord(hc, 0, UInt16(hc.pointee.EfxMem_EFG) << 2)
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            return
        }

        if hc.pointee.EfxMem_EFG & 0x0F == 0 { return }

        var SlideVal = UInt16(hc.pointee.EfxMem_EFG & 0x0F)
        if hc.pointee.EfxMem_EFG & 0xF0 != 0xE0 { SlideVal <<= 2 }

        guard let sc = hc.pointee.SlaveChnPtr else { return }
        PitchSlideUp(hc, sc, Int16(bitPattern: SlideVal))
        sc.pointee.FrequencySet = sc.pointee.Frequency
    }

    /// A slide to a note that names another sample: the voice goes over to it, from its start.
    /// False if there is no such sample, when the voice is stopped.
    private func Gxx_ChangeSample(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ sample: UInt8) -> Bool {
        sc.pointee.Flags &= ~(SF_NOTE_STOP | SF_LOOP_CHANGED | SF_CHN_MUTED | SF_VOLENV_ON | SF_PANENV_ON | SF_PITCHENV_ON | SF_PAN_CHANGED)
        sc.pointee.Flags |= SF_NEW_NOTE

        let s = module.sample(Int(sample))
        sc.pointee.SmpPtr = s
        sc.pointee.Smp = sample
        sc.pointee.AutoVibratoDepth = 0
        sc.pointee.LoopDirection = 0
        sc.pointee.Backwards = 0
        sc.pointee.Frac32 = 0
        sc.pointee.Frac64 = 0
        sc.pointee.HasLooped = false
        sc.pointee.SamplingPosition = 0
        sc.pointee.SmpVol = (s?.GlobVol ?? 0) &* 2

        guard let s, s.Flags & SMPF_ASSOCIATED_WITH_HEADER != 0 else {
            sc.pointee.Flags = SF_NOTE_STOP
            hc.pointee.Flags &= ~HF_CHAN_ON
            return false
        }

        sc.pointee.SmpIs16Bit = s.Flags & SMPF_16BIT != 0
        GetLoopInformation(sc)

        return true
    }

    /// A slide to a note is begun: by Gxx, by Lxx and by the volume column's Gx.
    private func InitCommandG11(_ hc: IT2HostPointer) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }

        if hc.pointee.NotePackMask & 0x22 != 0, hc.pointee.Smp > 0 {
            // Does the row name another sample or instrument than is playing?
            var ChangeInstrument = false

            if module.Flags & ITF_COMPAT_GXX != 0, openMPTSlideTakesSample(hc, sc) {
                // (OpenMPT's own, where the file asks for it: the slide goes on with the new sample
                // from its start. See `openMPTSlideTakesSample`.)
                if !Gxx_ChangeSample(hc, sc, hc.pointee.Smp - 1) { return }
                ChangeInstrument = true
            } else if module.Flags & ITF_COMPAT_GXX != 0 || module.playsAsDisorderTracker {
                // "Compatible Gxx": the sample stays, and the instrument's envelopes start again.
                // (And in Disorder Tracker's, which has no instruments, the sample stays.)
                hc.pointee.Smp = sc.pointee.Smp &+ 1
                sc.pointee.SmpVol = (module.sample(Int(sc.pointee.Smp))?.GlobVol ?? 0) &* 2

                ChangeInstrument = true
            } else if hc.pointee.Smp != midiSample { // a MIDI note's note is left alone
                let hcSmp = hc.pointee.Smp &- 1
                let oldSlaveIns = sc.pointee.Ins

                sc.pointee.Note = hc.pointee.RawNote
                sc.pointee.Ins = hc.pointee.Ins

                if sc.pointee.Ins != oldSlaveIns {
                    if sc.pointee.Smp != hcSmp {
                        if !Gxx_ChangeSample(hc, sc, hcSmp) { return }
                    }

                    ChangeInstrument = true
                } else if sc.pointee.Smp != hcSmp {
                    if !Gxx_ChangeSample(hc, sc, hcSmp) { return }

                    ChangeInstrument = true
                }
            }

            if module.Flags & ITF_INSTR_MODE != 0, ChangeInstrument {
                let ins = module.instrument(Int(hc.pointee.Ins) - 1)

                sc.pointee.FadeOut = 1024

                let oldSCFlags = sc.pointee.Flags
                InitPlayInstrument(hc, sc, ins)

                // A voice that was sounding carries on from where its sample had got to.
                if oldSCFlags & SF_CHAN_ON != 0 { sc.pointee.Flags &= ~SF_NEW_NOTE }

                sc.pointee.SmpVol = UInt8(truncatingIfNeeded: (Int(ins.GlobVol) * Int(sc.pointee.SmpVol)) >> 7)
            } else if slideRestartsEnvelopes, module.Flags & (ITF_INSTR_MODE | ITF_COMPAT_GXX) == ITF_INSTR_MODE, hc.pointee.Ins >= 1, hc.pointee.Ins != 255,
                      sc.pointee.Flags & SF_CHAN_ON != 0 {
                // (As ModPlug Tracker had it, the envelopes of an instrument that has none for
                // volume start again, though the note slides on.)
                let ins = module.instrument(Int(hc.pointee.Ins) - 1)
                if ins.VolEnv.Flags & ENVF_ENABLED == 0 { restartEnvelopes(sc, ins) }
            }
        }

        // (In Digitrakker, as OpenMPT plays it, a slide with no note goes on to where the last
        // slide was going, if it has not got there, and nowhere after a note.)
        if module.Flags & ITF_INSTR_MODE != 0 && !module.playsAsDigitrakker || hc.pointee.NotePackMask & 0x11 != 0 {
            // Where the slide is to end.
            if hc.pointee.TranslatedNote < 120 {
                if hc.pointee.Smp != midiSample { sc.pointee.Note = hc.pointee.TranslatedNote }
                if module.openMPTForeign { foreignSlideRevives(hc, sc) }

                hc.pointee.PortaFreq = noteFrequency(sc, hc.pointee.TranslatedNote)
                hc.pointee.Flags |= HF_PITCH_SLIDE_ONGOING
            } else if hc.pointee.Flags & HF_CHAN_ON != 0 {
                if hc.pointee.TranslatedNote == 255 {
                    if !module.madTracker || madTrackerLetGo(hc, sc) {
                        sc.pointee.Flags |= SF_NOTE_OFF
                        sc.pointee.ForeignRevived = false
                        GetLoopInformation(sc)
                    }
                } else if hc.pointee.TranslatedNote == 254 {
                    hc.pointee.Flags &= ~HF_CHAN_ON
                    sc.pointee.Flags = SF_NOTE_STOP
                } else {
                    sc.pointee.Flags |= SF_FADEOUT
                }
            }
        }

        var volFromVolColumn = false
        var vol: UInt8 = 0

        if hc.pointee.NotePackMask & 0x44 != 0 {
            if hc.pointee.RawVolColumn <= 64 {
                vol = hc.pointee.RawVolColumn
                volFromVolColumn = true
            } else if hc.pointee.RawVolColumn & 0x7F < 65 {
                InitCommandX2(hc, hc.pointee.RawVolColumn &- 128, by: .roughly)
            }
        }

        if volFromVolColumn || hc.pointee.NotePackMask & 0x22 != 0 {
            if !volFromVolColumn { vol = sc.pointee.SmpPtr.map { $0.hasVolume ? $0.Vol : hc.pointee.VolSet } ?? 0 }

            sc.pointee.Flags |= SF_RECALC_VOL
            hc.pointee.VolSet = vol
            sc.pointee.VolSet = vol
            sc.pointee.Vol = vol
        }

        if hc.pointee.Flags & HF_PITCH_SLIDE_ONGOING != 0 {
            // How fast, and which way. These are left where Gxx's later ticks look for them (and
            // the way where the volume column's do).
            let SlideSpeed = UInt16(module.Flags & ITF_COMPAT_GXX != 0 ? hc.pointee.EfxMem_G_Compat : hc.pointee.EfxMem_EFG) << 2
            if SlideSpeed > 0 {
                SetMiscEfxWord(hc, 0, SlideSpeed)

                if sc.pointee.FrequencySet != hc.pointee.PortaFreq {
                    hc.pointee.MiscEfxData[2] = sc.pointee.FrequencySet > hc.pointee.PortaFreq ? 0 : 1 // down, or up

                    if hc.pointee.Flags & HF_UPDATE_VOLEFX_IF_CHAN_ON == 0 { hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON }
                }
            }
        }

        // The volume column's effect is not begun if it is what brought us here.
        if hc.pointee.Flags & HF_UPDATE_VOLEFX_IF_CHAN_ON == 0 { InitVolumeEffect(hc) }
    }

    /// Gxx: a slide to the row's note.
    func InitCommandG(_ hc: IT2HostPointer) {
        if module.playsAsDisorderTracker { disorderTrackerKeepSample(hc) }
        if hc.pointee.CmdVal != 0 {
            if module.Flags & ITF_COMPAT_GXX != 0 {
                hc.pointee.EfxMem_G_Compat = hc.pointee.CmdVal
            } else {
                hc.pointee.EfxMem_EFG = hc.pointee.CmdVal
            }
        }

        if hc.pointee.Flags & HF_CHAN_ON == 0 || openMPTSlideStartsNote(hc) {
            InitNoCommand(hc)
            return
        }

        InitCommandG11(hc)
        if tuning(of: hc) != nil {
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            CommandG(hc)
        }
        if module.playsAsDisorderTracker { disorderTrackerFineSlide(hc) }
    }

    /// Hxy: vibrato.
    func InitCommandH(_ hc: IT2HostPointer) {
        // (H00 stops a vibrato in a module of Symphonie's, which goes on by itself otherwise: see `symphonieRow`.)
        if module.playsAsSymphonie, hc.pointee.CmdVal == 0 { return InitNoCommand(hc) }
        if hc.pointee.NotePackMask & 0x11 != 0, hc.pointee.RawNote < 120 {
            hc.pointee.LastVibratoData = 0
            hc.pointee.VibratoPos = 0
        }

        let speed = (hc.pointee.CmdVal >> 4) << 2
        var depth = (hc.pointee.CmdVal & 0x0F) << 2

        if speed > 0 { hc.pointee.VibratoSpeed = speed }

        if depth > 0 {
            if module.Flags & ITF_OLD_EFFECTS != 0 { depth <<= 1 }
            hc.pointee.VibratoDepth = depth
        }

        InitNoCommand(hc)

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            InitVibrato(hc)
        }
    }

    /// Ixy: tremor, the note on for x ticks and silent for y.
    func InitCommandI(_ hc: IT2HostPointer) {
        InitNoCommand(hc)

        let CmdVal = hc.pointee.CmdVal
        if CmdVal > 0 { hc.pointee.EfxMem_I = CmdVal }

        if ways.ownTremor {
            guard hc.pointee.Flags & HF_CHAN_ON != 0 else { return }
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            return openMPTTremor(hc)
        }
        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON

            var OffTime = hc.pointee.EfxMem_I & 0x0F
            var OnTime = hc.pointee.EfxMem_I >> 4

            if module.Flags & ITF_OLD_EFFECTS != 0 {
                OffTime += 1
                OnTime += 1
            }

            hc.pointee.MiscEfxData[0] = OffTime
            hc.pointee.MiscEfxData[1] = OnTime

            CommandI(hc)
        }
    }

    /// Jxy: an arpeggio of the note, x semitones above it and y above it.
    func InitCommandJ(_ hc: IT2HostPointer) {
        InitNoCommand(hc)

        SetMiscEfxWord(hc, 0, 0) // which of the three the tick is at

        var CmdVal = hc.pointee.CmdVal
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_J }
        hc.pointee.EfxMem_J = CmdVal

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON

            // The two other notes, as entries in the table of pitches, whose entry 60 multiplies by one.
            SetMiscEfxWord(hc, 2, 60 + UInt16(hc.pointee.EfxMem_J >> 4))
            SetMiscEfxWord(hc, 4, 60 + UInt16(hc.pointee.EfxMem_J & 0x0F))
            if tuning(of: hc) != nil { openMPTTunedArpeggio(hc) }
        }
    }

    /// Kxy: vibrato as it was, with a slide of volume.
    func InitCommandK(_ hc: IT2HostPointer) {
        if hc.pointee.CmdVal > 0 { hc.pointee.EfxMem_DKL = hc.pointee.CmdVal }

        InitNoCommand(hc)

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            InitVibrato(hc)
            if let sc = hc.pointee.SlaveChnPtr { InitCommandD7(hc, sc) }

            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        }
    }

    /// Lxy: a slide to the note as it was, with a slide of volume. (On a channel that is not
    /// playing, the row's note is not started.)
    func InitCommandL(_ hc: IT2HostPointer) {
        if module.playsAsDisorderTracker { disorderTrackerKeepSample(hc) }
        let CmdVal = hc.pointee.CmdVal
        if CmdVal > 0 { hc.pointee.EfxMem_DKL = CmdVal }

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            if openMPTSlideStartsNote(hc) { InitNoCommand(hc) } else { InitCommandG11(hc) }
            if let sc = hc.pointee.SlaveChnPtr { InitCommandD7(hc, sc) }
        }
    }

    private func InitCommandM2(_ hc: IT2HostPointer, _ vol: UInt8) {
        if hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr {
            sc.pointee.ChnVol = vol
            sc.pointee.Flags |= SF_RECALC_VOL
        }

        hc.pointee.ChnVol = vol
    }

    /// Mxx: the channel's volume.
    func InitCommandM(_ hc: IT2HostPointer) {
        InitNoCommand(hc)

        if hc.pointee.CmdVal <= 0x40 { InitCommandM2(hc, hc.pointee.CmdVal) }
    }

    /// Nxy: a slide of the channel's volume.
    func InitCommandN(_ hc: IT2HostPointer) {
        let CmdVal = hc.pointee.CmdVal
        if CmdVal > 0 { hc.pointee.EfxMem_N = CmdVal }

        InitNoCommand(hc)

        let hi = hc.pointee.EfxMem_N & 0xF0
        let lo = hc.pointee.EfxMem_N & 0x0F

        if lo == 0 {
            hc.pointee.MiscEfxData[0] = hi >> 4
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        } else if hi == 0 {
            hc.pointee.MiscEfxData[0] = 0 &- lo
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        } else if lo == 0x0F {
            var vol = hc.pointee.ChnVol &+ (hi >> 4)
            if vol > 64 { vol = 64 }
            InitCommandM2(hc, vol)
        } else if hi == 0xF0 {
            var vol = hc.pointee.ChnVol &- lo
            if Int8(bitPattern: vol) < 0 { vol = 0 }
            InitCommandM2(hc, vol)
        }
    }

    /// Oxx: the note starts from further into its sample.
    func InitCommandO(_ hc: IT2HostPointer) {
        var CmdVal = hc.pointee.CmdVal
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_O }
        hc.pointee.EfxMem_O = CmdVal

        InitNoCommand(hc)

        if module.playsAsDigitrakker {
            digitrakkerOffset(hc)
            return
        }
        if module.playsAsDisorderTracker { return disorderTrackerOffset(hc) }
        if hc.pointee.NotePackMask & 0x33 != 0, hc.pointee.TranslatedNote < 120, hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr {
            if module.openMPT != nil { // whose offsets are longer, and are reckoned with the volume column's
                OpenMPTCommandO(hc, sc)
                return
            }
            var offset = ((Int32(hc.pointee.HighSmpOffs) << 8) | Int32(hc.pointee.EfxMem_O)) << 8
            if offset >= sc.pointee.LoopEnd {
                // Past the end: ignored, or with "old effects" the very end.
                if module.Flags & ITF_OLD_EFFECTS == 0 { return }
                offset = sc.pointee.LoopEnd &- 1
            }

            sc.pointee.SamplingPosition = offset
            sc.pointee.Frac32 = 0
            sc.pointee.Frac64 = 0
        }
    }

    /// Pxy: a slide of the place between the speakers.
    func InitCommandP(_ hc: IT2HostPointer) {
        let CmdVal = hc.pointee.CmdVal
        if CmdVal > 0 { hc.pointee.EfxMem_P = CmdVal }

        InitNoCommand(hc)

        var pan = hc.pointee.ChnPan
        if hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr { pan = sc.pointee.PanSet }

        // (Surround is in the middle, and slides from there where it is heard where it is put.)
        if pan == PAN_SURROUND {
            guard surroundIsPlaced else { return }
            pan = 32
        }

        let hi = hc.pointee.EfxMem_P & 0xF0
        let lo = hc.pointee.EfxMem_P & 0x0F

        if lo == 0 {
            hc.pointee.MiscEfxData[0] = 0 &- (hi >> 4)
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        } else if hi == 0 {
            hc.pointee.MiscEfxData[0] = lo
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        } else if lo == 0x0F {
            pan &-= hi >> 4
            if Int8(bitPattern: pan) < 0 { pan = 0 }
            InitCommandX2(hc, pan, by: .slide)
        } else if hi == 0xF0 {
            pan &+= lo
            if pan > 64 { pan = 64 }
            InitCommandX2(hc, pan, by: .slide)
        } else if module.openMPTForeign {
            // (As a slide of volume with both halves: by the second, to the right.)
            hc.pointee.MiscEfxData[0] = lo
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        }
    }

    /// Qxy: the note struck again every y ticks, its volume changed each time as x says.
    func InitCommandQ(_ hc: IT2HostPointer) {
        InitNoCommand(hc)

        if hc.pointee.CmdVal > 0 { hc.pointee.EfxMem_Q = hc.pointee.CmdVal }
        if ways.ownRetrigger { return openMPTInitRetrigger(hc) }

        if hc.pointee.Flags & HF_CHAN_ON == 0 { return }

        hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON

        if hc.pointee.NotePackMask & 0x11 != 0 {
            hc.pointee.RetrigCount = hc.pointee.EfxMem_Q & 0x0F
        } else {
            CommandQ(hc)
        }
    }

    /// The first tick of a tremolo, which with "old effects" does not move on, as vibrato's.
    private func InitTremolo(_ hc: IT2HostPointer) {
        if module.openMPTForeign { return foreignTremolo(hc, movesOn: false) }
        if module.playsAsDigitrakker {
            digitrakkerTremolo(hc, movesOn: false)
        } else if module.playsAsXTracker {
            xTrackerTremolo(hc, movesOn: false)
        } else if module.Flags & ITF_OLD_EFFECTS != 0 {
            guard let sc = hc.pointee.SlaveChnPtr else { return }
            sc.pointee.Flags |= SF_UPDATE_MIXERVOL
            CommandR2(hc, sc, hc.pointee.LastTremoloData)
        } else {
            CommandR(hc)
        }
    }

    /// Rxy: tremolo.
    func InitCommandR(_ hc: IT2HostPointer) {
        let speed = hc.pointee.CmdVal >> 4
        let depth = hc.pointee.CmdVal & 0x0F

        if speed > 0 { hc.pointee.TremoloSpeed = speed << 2 }
        if depth > 0 { hc.pointee.TremoloDepth = depth << 1 }
        // (And one of no depth stops a tremolo there.)
        if module.playsAsSymphonie, depth == 0 { return InitNoCommand(hc) }

        InitNoCommand(hc)

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            InitTremolo(hc)
        }
    }

    /// Sxy: sixteen lesser effects.
    func InitCommandS(_ hc: IT2HostPointer) {
        var CmdVal = hc.pointee.CmdVal
        // (S00 is the last S again, but in a module of Imago Orpheus's or Velvet Studio's, to OpenMPT.)
        if CmdVal == 0, !module.openMPTForeign { CmdVal = hc.pointee.EfxMem_S }
        hc.pointee.EfxMem_S = CmdVal

        let cmd = CmdVal & 0xF0
        let val = CmdVal & 0x0F

        hc.pointee.MiscEfxData[0] = cmd
        hc.pointee.MiscEfxData[1] = val

        switch cmd {
        case 0x30: // the wave of vibrato
            if val <= 3 { hc.pointee.VibratoWaveform = val }
            InitNoCommand(hc)

        case 0x40: // of tremolo
            if val <= 3 { hc.pointee.TremoloWaveform = val }
            InitNoCommand(hc)

        case 0x50: // of panbrello
            if ownVibrato {
                // (OpenMPT's own way takes any, and goes on from where the wave was.)
                if val <= 7 { hc.pointee.PanbrelloWaveform = val }
            } else if val <= 3 {
                hc.pointee.PanbrelloWaveform = val
                hc.pointee.PanbrelloPos = 0
            }
            InitNoCommand(hc)

        case 0x60: // the row lasts some ticks more
            CurrentTick &+= UInt16(val)
            ProcessTick &+= UInt16(val)
            InitNoCommand(hc)

        case 0x70: // to do with instruments
            switch val {
            case 0x0: // the notes this channel has let go of are cut (which the driver ramps down)
                InitNoCommand(hc)

                let targetHostChnNum = hc.pointee.HostChnNum | CHN_DISOWNED
                for i in 0 ..< MAX_SLAVE_CHANNELS where sChn[i].HostChnNum == targetHostChnNum { sChn[i].Flags |= SF_NOTE_STOP }

            case 0x1: // or released
                InitNoCommand(hc)

                let targetHostChnNum = hc.pointee.HostChnNum | CHN_DISOWNED
                for i in 0 ..< MAX_SLAVE_CHANNELS where sChn[i].HostChnNum == targetHostChnNum { sChn[i].Flags |= SF_NOTE_OFF }

            case 0x2: // or faded
                InitNoCommand(hc)

                let targetHostChnNum = hc.pointee.HostChnNum | CHN_DISOWNED
                for i in 0 ..< MAX_SLAVE_CHANNELS where sChn[i].HostChnNum == targetHostChnNum { sChn[i].Flags |= SF_FADEOUT }

            case 0x3, 0x4, 0x5, 0x6: // what becomes of this note when the next comes: cut, continue, off or fade
                InitNoCommand(hc)
                if hc.pointee.Flags & HF_CHAN_ON != 0 { hc.pointee.SlaveChnPtr?.pointee.NNA = val - 3 }

            case 0x7: // the volume envelope off
                InitNoCommand(hc)
                if hc.pointee.Flags & HF_CHAN_ON != 0 { hc.pointee.SlaveChnPtr?.pointee.Flags &= ~SF_VOLENV_ON }

            case 0x8: // and on
                InitNoCommand(hc)
                if hc.pointee.Flags & HF_CHAN_ON != 0 { hc.pointee.SlaveChnPtr?.pointee.Flags |= SF_VOLENV_ON }

            case 0x9: // the panning envelope off
                InitNoCommand(hc)
                if hc.pointee.Flags & HF_CHAN_ON != 0 { hc.pointee.SlaveChnPtr?.pointee.Flags &= ~SF_PANENV_ON }

            case 0xA: // and on
                InitNoCommand(hc)
                if hc.pointee.Flags & HF_CHAN_ON != 0 { hc.pointee.SlaveChnPtr?.pointee.Flags |= SF_PANENV_ON }

            case 0xB: // the pitch envelope off
                InitNoCommand(hc)
                if hc.pointee.Flags & HF_CHAN_ON != 0 { hc.pointee.SlaveChnPtr?.pointee.Flags &= ~SF_PITCHENV_ON }

            case 0xC: // and on
                InitNoCommand(hc)
                if hc.pointee.Flags & HF_CHAN_ON != 0 { hc.pointee.SlaveChnPtr?.pointee.Flags |= SF_PITCHENV_ON }

            default:
                InitNoCommand(hc)
            }

        case 0x80: // the place between the speakers, of sixteen
            let pan = UInt8(truncatingIfNeeded: (((Int(val) << 4) | Int(val)) + 2) >> 2)
            InitNoCommand(hc)
            InitCommandX2(hc, pan, by: .roughly)

        case 0x90: // S91: surround
            InitNoCommand(hc)
            // (And S98 and S99, in a file with ModPlug's own reverb, take a channel out of it and put it in.)
            if reverbs, val == 8 || val == 9 { hc.pointee.Reverb = val == 9 }
            if speakerCommands, val >= 0xA, val <= 0xD {
                // ModPlug Tracker's: see `speakerCommands`.
                if val < 0xC { surroundPanning = val == 0xB } else { filterWaits = val == 0xD }
                // (A channel in surround that is somewhere is heard in the middle again after S9A, and
                // one in the middle may be moved after S9B.)
                for i in 0 ..< MAX_HOST_CHANNELS where hChn[i].SurroundPanned != surroundIsPlaced {
                    if hChn[i].SurroundPanned || hChn[i].ChnPan == PAN_SURROUND { InitCommandX2(hChn + i, PAN_SURROUND) }
                }
            } else if val == 1 {
                InitCommandX2(hc, PAN_SURROUND)
            } else if val == 0, module.openMPT != nil || speakerCommands {
                // S90 in a file of ModPlug Tracker's or OpenMPT's takes surround away again: theirs
                // is a channel with one side turned over, in the middle unless it is put
                // elsewhere, and where it is is where it is left.
                if hc.pointee.ChnPan == PAN_SURROUND { InitCommandX2(hc, 32, by: .surroundOff) } else if hc.pointee.SurroundPanned { leaveSurround(hc) }
            } else if module.openMPT != nil {
                // An MPTM file's S9E and S9F play a sample forwards and backwards.
                OpenMPTCommandS9(hc, val)
            } else if playsBackwards, val >= 0xE {
                // And so do those two in an IT file that a later tracker made.
                OpenMPTCommandS9(hc, val)
            }

        case 0xA0: // the high part of Oxx's offset
            hc.pointee.HighSmpOffs = val
            InitNoCommand(hc)

        case 0xB0: // a loop within the pattern: SB0 marks its start, SBx goes back to it x times
            InitNoCommand(hc)

            // (The row is kept in a byte, as Impulse Tracker keeps it, but for an MPTM file: see `rowMask`.)
            if val == 0 {
                hc.pointee.PattLoopStartRow = CurrentRow & rowMask
            } else if hc.pointee.PattLoopCount == 0 {
                hc.pointee.PattLoopCount = val
                hc.pointee.PattLoopStay = stay
                ProcessRow = hc.pointee.PattLoopStartRow &- 1
                LoopBackRow = ProcessRow
                PatternLooping = true
            } else {
                hc.pointee.PattLoopCount &-= 1
                if hc.pointee.PattLoopCount != 0 {
                    // (A count that goes on being counted here is one of this stay's, wherever it was begun.)
                    hc.pointee.PattLoopStay = stay
                    ProcessRow = hc.pointee.PattLoopStartRow &- 1
                    LoopBackRow = ProcessRow
                    PatternLooping = true
                } else {
                    // Done: a later loop without a start of its own starts after this one.
                    hc.pointee.PattLoopStartRow = ((CurrentRow & rowMask) &+ 1) & rowMask
                }
            }

        case 0xC0: // the note is cut after some ticks
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            InitNoCommand(hc)
            // (Digitrakker's SC0 cuts it now; and so do Imago Orpheus's and Velvet Studio's, to OpenMPT.)
            if module.playsAsDigitrakker, val == 0 {
                hc.pointee.Flags &= ~HF_UPDATE_EFX_IF_CHAN_ON
                silenceCut(hc)
            } else if module.openMPTForeign, val == 0 {
                hc.pointee.Flags &= ~HF_UPDATE_EFX_IF_CHAN_ON
                if hc.pointee.Flags & HF_CHAN_ON != 0 {
                    hc.pointee.Flags &= ~HF_CHAN_ON
                    hc.pointee.SlaveChnPtr?.pointee.Flags |= SF_NOTE_STOP
                }
            }

        case 0xD0: // the note is started after some ticks, and not now
            // (Digitrakker's SD0 starts it now, and Imago Orpheus's and Velvet Studio's, to OpenMPT.)
            if module.playsAsDigitrakker || module.openMPTForeign, val == 0 {
                InitNoCommand(hc)
            } else {
                hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
            }

        case 0xE0: // the row is played some times more
            if !RowDelayOn {
                RowDelay = val + 1
                RowDelayOn = true
            }
            InitNoCommand(hc)

        case 0xF0: // which of the MIDI settings' macros Zxx sends
            hc.pointee.EfxMem_SFx = val
            InitNoCommand(hc)

        // (S1x and S2x are something only for an instrument with a tuning of its own, as OpenMPT
        // plays one: a slide to a note by whole notes, and so many fine steps from each note.)
        case 0x10 where tunings:
            hc.pointee.Tuned.glissando = val != 0
            InitNoCommand(hc)

        case 0x20 where tuning(of: hc) != nil:
            InitNoCommand(hc)
            hc.pointee.Tuned.fine = Int32(val) - 8
            hc.pointee.Tuned.again = true

        default: // S0x, S1x and S2x do nothing
            InitNoCommand(hc)
        }
    }

    /// Txx: the tempo, or below T20 a slide of it.
    func InitCommandT(_ hc: IT2HostPointer) {
        var CmdVal = hc.pointee.CmdVal
        // (T00 is the last T again, but in a module of Imago Orpheus's or Velvet Studio's, to OpenMPT, for which it
        // does nothing.)
        if CmdVal == 0, module.openMPTForeign { return InitNoCommand(hc) }
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_T }
        hc.pointee.EfxMem_T = CmdVal

        // (An MPTM file's tempo can be higher than a byte holds, and is a whole number once set.)
        let long = module.openMPT == nil ? 0 : openMPTLongValue(hc)
        if CmdVal >= 0x20 || long > 0xFF {
            Tempo = UInt16(CmdVal)
            if module.openMPT != nil {
                Tempo = UInt16(min(Int(tempoCeiling), long > 0xFF ? long : Int(CmdVal)))
                TempoFraction = 0
            }
            Music_InitTempo()
            InitNoCommand(hc)
        } else {
            InitNoCommand(hc)
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        }
    }

    /// Uxy: a fine vibrato, a quarter as deep as H's.
    func InitCommandU(_ hc: IT2HostPointer) {
        if hc.pointee.NotePackMask & 0x11 != 0 {
            hc.pointee.LastVibratoData = 0
            hc.pointee.VibratoPos = 0
        }

        let speed = (hc.pointee.CmdVal >> 4) << 2
        var depth = hc.pointee.CmdVal & 0x0F

        if speed > 0 { hc.pointee.VibratoSpeed = speed }

        if depth > 0 {
            if module.Flags & ITF_OLD_EFFECTS != 0 { depth <<= 1 }
            hc.pointee.VibratoDepth = depth
        }

        InitNoCommand(hc)

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            InitVibrato(hc)
        }
    }

    /// Vxx: the volume of the whole song.
    func InitCommandV(_ hc: IT2HostPointer) {
        // (Above the top it does nothing; but in a module of Imago Orpheus's or Velvet Studio's, to OpenMPT, it is the top.)
        if hc.pointee.CmdVal <= 0x80 || module.openMPTForeign {
            GlobalVolume = UInt16(min(hc.pointee.CmdVal, 0x80))
            RecalculateAllVolumes()
        }

        InitNoCommand(hc)
    }

    /// Wxy: a slide of it.
    func InitCommandW(_ hc: IT2HostPointer) {
        InitNoCommand(hc)

        if hc.pointee.CmdVal > 0 { hc.pointee.EfxMem_W = hc.pointee.CmdVal }

        if hc.pointee.EfxMem_W == 0 { return }

        let hi = hc.pointee.EfxMem_W & 0xF0
        let lo = hc.pointee.EfxMem_W & 0x0F

        if lo == 0 {
            hc.pointee.MiscEfxData[0] = hi >> 4
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        } else if hi == 0 {
            hc.pointee.MiscEfxData[0] = 0 &- lo
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        } else if lo == 0x0F {
            var vol = GlobalVolume &+ UInt16(hi >> 4)
            if vol > 128 { vol = 128 }

            GlobalVolume = vol
            RecalculateAllVolumes()
        } else if hi == 0xF0 {
            var vol = GlobalVolume &- UInt16(lo)
            if Int16(bitPattern: vol) < 0 { vol = 0 }

            GlobalVolume = vol
            RecalculateAllVolumes()
        }
    }

    /// Puts the channel, and the note it is playing, at a place between the speakers: 0 to 64, or
    /// surround.
    private func InitCommandX2(_ hc: IT2HostPointer, _ given: UInt8, by placing: Placing = .command) {
        // (A channel in surround may stay in it where it is put, or in the middle: see `keepsSurround`.)
        var pan = given
        let inSurround = hc.pointee.ChnPan == PAN_SURROUND || hc.pointee.SurroundPanned
        hc.pointee.SurroundPanned = false
        if pan == PAN_SURROUND, surroundIsPlaced {
            pan = 32
            hc.pointee.SurroundPanned = true
        } else if pan != PAN_SURROUND, inSurround, keepsSurround(placing) {
            if surroundIsPlaced { hc.pointee.SurroundPanned = true } else { pan = PAN_SURROUND }
        }
        if hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr {
            sc.pointee.PanSet = pan
            sc.pointee.Pan = pan
            sc.pointee.SurroundPanned = hc.pointee.SurroundPanned
            sc.pointee.Flags |= SF_RECALC_PAN | SF_UPDATE_MIXERVOL
        }

        hc.pointee.ChnPan = pan
    }

    /// S90 for a channel in surround that is somewhere between the speakers: it stays there, out of
    /// surround.
    private func leaveSurround(_ hc: IT2HostPointer) {
        hc.pointee.SurroundPanned = false
        if hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr {
            sc.pointee.SurroundPanned = false
            sc.pointee.Flags |= SF_RECALC_PAN | SF_UPDATE_MIXERVOL
        }
    }

    /// Xxx: the place between the speakers.
    func InitCommandX(_ hc: IT2HostPointer) {
        InitNoCommand(hc)

        let pan = UInt8(truncatingIfNeeded: (Int(hc.pointee.CmdVal) + 2) >> 2)
        InitCommandX2(hc, pan)
    }

    /// Yxy: panbrello.
    func InitCommandY(_ hc: IT2HostPointer) {
        let speed = hc.pointee.CmdVal >> 4
        let depth = hc.pointee.CmdVal & 0x0F

        if speed > 0 { hc.pointee.PanbrelloSpeed = speed }
        if depth > 0 { hc.pointee.PanbrelloDepth = depth << 1 }

        InitNoCommand(hc)

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            CommandY(hc)
        }
    }

    /// Zxx: one of the MIDI settings' macros is sent, which is how a tune sets the filter. From Z80
    /// up it is a macro of its own; below, the one SFx chose, with xx as its value.
    func InitCommandZ(_ hc: IT2HostPointer, comingTo: Bool = false) {
        InitNoCommand(hc)
        sendMacro(hc, comingTo: comingTo)
    }

    // MARK: Effects on the ticks after

    func CommandD(_ hc: IT2HostPointer) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        if module.playsAsDigitrakker, digitrakkerSlides[Int(hc.pointee.HostChnNum) & 63].active {
            digitrakkerVolumeSlide(hc, sc)
            return
        }

        var vol = sc.pointee.VolSet &+ UInt8(bitPattern: hc.pointee.VolSlideDelta)
        if Int8(bitPattern: vol) < 0 {
            hc.pointee.Flags &= ~HF_UPDATE_EFX_IF_CHAN_ON
            vol = 0
        } else if vol > 64 {
            hc.pointee.Flags &= ~HF_UPDATE_EFX_IF_CHAN_ON
            vol = 64
        }

        CommandD2(hc, sc, vol)
    }

    func CommandE(_ hc: IT2HostPointer) {
        if tuning(of: hc) != nil { return openMPTTunedSlide(hc, -Int32(hc.pointee.EfxMem_EFG)) }
        CommandEChain(hc, MiscEfxWord(hc, 0))
    }

    func CommandF(_ hc: IT2HostPointer) {
        if tuning(of: hc) != nil { return openMPTTunedSlide(hc, Int32(hc.pointee.EfxMem_EFG)) }
        CommandFChain(hc, MiscEfxWord(hc, 0))
    }

    func CommandG(_ hc: IT2HostPointer) {
        if tuning(of: hc) != nil { return openMPTTunedSlideToNote(hc, module.Flags & ITF_COMPAT_GXX != 0 ? hc.pointee.EfxMem_G_Compat : hc.pointee.EfxMem_EFG) }
        if hc.pointee.Flags & HF_PITCH_SLIDE_ONGOING == 0 { return }

        let SlideValue = Int16(bitPattern: MiscEfxWord(hc, 0))
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        let bent = module.openMPTForeign && hc.pointee.VolCmd & 7 == 7 && hc.pointee.Flags & HF_UPDATE_VOLEFX_IF_CHAN_ON != 0
        if bent { sc.pointee.Frequency = sc.pointee.FrequencySet }

        if hc.pointee.MiscEfxData[2] == 1 {
            // Up, while the note has not been stopped (by sliding past what can be reached) and
            // is below where it is going.
            PitchSlideUp(hc, sc, SlideValue)

            if sc.pointee.Flags & SF_NOTE_STOP == 0, sc.pointee.Frequency < hc.pointee.PortaFreq {
                sc.pointee.FrequencySet = sc.pointee.Frequency
            } else {
                sc.pointee.Flags &= ~SF_NOTE_STOP
                hc.pointee.Flags |= HF_CHAN_ON

                sc.pointee.FrequencySet = hc.pointee.PortaFreq
                sc.pointee.Frequency = hc.pointee.PortaFreq
                hc.pointee.Flags &= ~(HF_UPDATE_EFX_IF_CHAN_ON | HF_ALWAYS_UPDATE_EFX | HF_PITCH_SLIDE_ONGOING)
            }
        } else {
            // Down, while it is above.
            PitchSlideDown(hc, sc, SlideValue)

            if sc.pointee.Frequency > hc.pointee.PortaFreq {
                sc.pointee.FrequencySet = sc.pointee.Frequency
            } else {
                sc.pointee.FrequencySet = hc.pointee.PortaFreq
                sc.pointee.Frequency = hc.pointee.PortaFreq
                hc.pointee.Flags &= ~(HF_UPDATE_EFX_IF_CHAN_ON | HF_ALWAYS_UPDATE_EFX | HF_PITCH_SLIDE_ONGOING)
            }
        }
        // (The volume column's vibrato, which has bent the pitch this tick before the slide, bends
        // it from where the slide has got to, and not where the slide is to go on from: so OpenMPT
        // has it, in a module it does not take for an IT file.)
        if bent {
            sc.pointee.Frequency = sc.pointee.FrequencySet
            CommandH5(hc, sc, hc.pointee.LastVibratoData)
        }
    }

    /// Bends the pitch by a step of the vibrato's wave times its depth. The result is cut to eight
    /// bits, as the original's is. (OpenMPT divides it towards nought, where Impulse Tracker rounds.)
    func CommandH5(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ VibratoData: Int8) {
        if tuning(of: hc) != nil { return openMPTTunedVibrato(hc, VibratoData) }
        if ownVibrato { return openMPTOwnVibrato(hc, sc) }
        let bent = (Int(VibratoData) * Int(Int8(bitPattern: hc.pointee.VibratoDepth))) << 2
        var VibratoData = Int8(truncatingIfNeeded: module.openMPT != nil || module.playsAsXTracker ? bent / 256 : (bent + 128) >> 8)
        if module.Flags & ITF_OLD_EFFECTS != 0 { VibratoData = 0 &- VibratoData }

        if VibratoData < 0 {
            PitchSlideDown(hc, sc, -Int16(VibratoData), lasting: false)
        } else {
            PitchSlideUp(hc, sc, Int16(VibratoData), lasting: false)
        }
    }

    func CommandH(_ hc: IT2HostPointer) {
        if module.madTracker { return madTrackerVibrato(hc, moving: true) }
        if module.openMPTForeign { return foreignVibrato(hc, movesOn: true) }
        if module.playsAsDigitrakker {
            digitrakkerVibrato(hc, movesOn: true)
            return
        }
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_FREQ_CHANGE

        hc.pointee.VibratoPos &+= hc.pointee.VibratoSpeed

        let VibratoData: Int8
        if hc.pointee.VibratoWaveform == 3 {
            VibratoData = Int8(truncatingIfNeeded: Int(Random() & 127) - 64)
        } else {
            VibratoData = it2FineSineData[(Int(hc.pointee.VibratoWaveform) << 8) + Int(hc.pointee.VibratoPos)]
        }

        hc.pointee.LastVibratoData = VibratoData
        CommandH5(hc, sc, VibratoData)
    }

    func CommandI(_ hc: IT2HostPointer) {
        if ways.ownTremor { return openMPTTremor(hc) }
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_RECALC_VOL

        hc.pointee.TremorCount &-= 1
        if Int8(bitPattern: hc.pointee.TremorCount) <= 0 {
            hc.pointee.TremorOnOff ^= 1
            hc.pointee.TremorCount = hc.pointee.MiscEfxData[Int(hc.pointee.TremorOnOff) & 15]
        }

        if hc.pointee.TremorOnOff != 1 { sc.pointee.Vol = 0 }
    }

    func CommandJ(_ hc: IT2HostPointer) {
        if tuning(of: hc) != nil { return openMPTTunedArpeggio(hc) }
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        var tick = MiscEfxWord(hc, 0)

        sc.pointee.Flags |= SF_FREQ_CHANGE

        // The tick counts in twos, as Impulse Tracker's did into a table of sixteen-bit numbers;
        // on every third the note is its own.
        tick &+= 2
        if tick >= 6 {
            SetMiscEfxWord(hc, 0, 0)
            return
        }
        SetMiscEfxWord(hc, 0, tick)

        let arpNote = Int(MiscEfxWord(hc, Int(tick)))
        // (Digitrakker's, as OpenMPT has it, is by its period: see `digitrakkerArpeggio`.)
        if module.playsAsDigitrakker {
            digitrakkerArpeggio(sc, semitones: arpNote - 60)
            return
        }
        if pitchesArePeriods { return openMPTPeriodArpeggio(sc, semitones: arpNote - 60) }
        if openMPTHertz { return openMPTFrequencyArpeggio(sc, semitones: arpNote - 60) }
        let multiplier = arpNote < it2PitchTable.count ? it2PitchTable[arpNote] : 0

        // (The original widens the rate, a signed number, to sixty-four bits before it multiplies.)
        let freq = UInt64(bitPattern: Int64(sc.pointee.Frequency)) &* UInt64(multiplier)
        if freq & 0xFFFF_0000_0000_0000 != 0 {
            sc.pointee.Frequency = 0 // too high to play
        } else {
            sc.pointee.Frequency = Int32(bitPattern: UInt32(truncatingIfNeeded: freq >> 16))
        }
    }

    func CommandK(_ hc: IT2HostPointer) {
        CommandH(hc)
        CommandD(hc)
    }

    func CommandL(_ hc: IT2HostPointer) {
        if hc.pointee.Flags & HF_PITCH_SLIDE_ONGOING != 0 {
            CommandG(hc)
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON // which the slide takes away on arriving
        }

        CommandD(hc)
    }

    func CommandN(_ hc: IT2HostPointer) {
        var vol = hc.pointee.ChnVol &+ hc.pointee.MiscEfxData[0]

        if Int8(bitPattern: vol) < 0 {
            vol = 0
        } else if vol > 64 {
            vol = 64
        }

        InitCommandM2(hc, vol)
    }

    func CommandP(_ hc: IT2HostPointer) {
        var pan = hc.pointee.ChnPan
        if hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr { pan = sc.pointee.PanSet }
        if pan == PAN_SURROUND { pan = 32 }

        pan &+= hc.pointee.MiscEfxData[0]

        if Int8(bitPattern: pan) < 0 {
            pan = 0
        } else if pan > 64 {
            pan = 64
        }

        InitCommandX2(hc, pan, by: .slide)
    }

    func CommandQ(_ hc: IT2HostPointer) {
        if ways.ownRetrigger { return openMPTRetrigger(hc) }
        hc.pointee.RetrigCount &-= 1
        if Int8(bitPattern: hc.pointee.RetrigCount) > 0 { return }

        hc.pointee.RetrigCount = hc.pointee.EfxMem_Q & 0x0F
        retrigger(hc)
    }

    /// Qxy's note struck again, and its volume moved as y says.
    func retrigger(_ hc: IT2HostPointer) {
        // Time to strike it again. The driver ramps volumes, so the note as it is goes to another
        // voice to be ramped down while this one starts over.
        guard var sc = hc.pointee.SlaveChnPtr else { return }
        if module.Flags & ITF_INSTR_MODE != 0 {
            for i in 0 ..< MAX_SLAVE_CHANNELS where sChn[i].Flags & SF_CHAN_ON == 0 {
                // A voice not in use takes the note on, and the old one is let go of and stopped.
                let scTmp = sChn + i
                scTmp.pointee = sc.pointee
                sc.pointee.Flags |= SF_NOTE_STOP
                sc.pointee.HostChnNum |= CHN_DISOWNED

                sc = scTmp
                hc.pointee.SlaveChnPtr = scTmp
                break
            }
        } else if sc - sChn < MAX_SLAVE_CHANNELS - MAX_HOST_CHANNELS {
            // Without instruments each channel has a voice of its own, and a second 64 on for this.
            let scTmp = sc + MAX_HOST_CHANNELS
            scTmp.pointee = sc.pointee
            scTmp.pointee.Flags |= SF_NOTE_STOP
            scTmp.pointee.HostChnNum |= CHN_DISOWNED
        }

        sc.pointee.Frac32 = 0
        sc.pointee.Frac64 = 0
        sc.pointee.HasLooped = false
        sc.pointee.SamplingPosition = 0

        sc.pointee.Flags |= SF_UPDATE_MIXERVOL | SF_NEW_NOTE | SF_LOOP_CHANGED
        if module.playsAsSymphonie { sc.pointee.Paused = false }
        if ways.ownRetrigger {
            // (OpenMPT's own strikes the note anew, and with instruments at its own pitch, not where
            // a slide has taken it.)
            if module.Flags & ITF_INSTR_MODE != 0, hc.pointee.TranslatedNote < 120, sc.pointee.InsPtr?.Tuning == nil {
                sc.pointee.FrequencySet = noteFrequency(sc, hc.pointee.TranslatedNote)
                sc.pointee.Frequency = sc.pointee.FrequencySet
                sc.pointee.Flags |= SF_FREQ_CHANGE
            }
            return openMPTRetriggerVolume(hc, sc)
        }

        var vol = sc.pointee.VolSet
        switch hc.pointee.EfxMem_Q >> 4 {
        case 0x1: vol &-= 1
        case 0x2: vol &-= 2
        case 0x3: vol &-= 4
        case 0x4: vol &-= 8
        case 0x5: vol &-= 16
        case 0x6: vol = UInt8(truncatingIfNeeded: (Int(vol) << 1) / 3)
        case 0x7: vol >>= 1
        case 0x9: vol &+= 1
        case 0xA: vol &+= 2
        case 0xB: vol &+= 4
        case 0xC: vol &+= 8
        case 0xD: vol &+= 16
        case 0xE: vol = UInt8(truncatingIfNeeded: (Int(vol) * 3) >> 1)
        case 0xF: vol = UInt8(truncatingIfNeeded: Int(vol) << 1)
        default: return // 0 and 8: the volume stays (and a MIDI note is not told to stop)
        }

        if Int8(bitPattern: vol) < 0 {
            vol = 0
        } else if vol > 64 {
            vol = 64
        }

        hc.pointee.VolSet = vol
        sc.pointee.Vol = vol
        sc.pointee.VolSet = vol
        sc.pointee.Flags |= SF_RECALC_VOL

        if hc.pointee.Smp == midiSample { MIDITranslate(hc, sc, 0x0080) } // the MIDI settings' "stop note"
    }

    /// Moves the volume by a step of the tremolo's wave times its depth, for this tick only.
    func CommandR2(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ TremoloData: Int8) {
        if ownVibrato { return openMPTOwnTremolo(hc, sc) }
        let TremoloData = Int8(truncatingIfNeeded: (((Int(TremoloData) * Int(Int8(bitPattern: hc.pointee.TremoloDepth))) << 2) + 128) >> 8)

        var vol = Int16(sc.pointee.Vol) + Int16(TremoloData)
        if vol < 0 {
            vol = 0
        } else if vol > 64 {
            vol = 64
        }

        sc.pointee.Vol = UInt8(truncatingIfNeeded: vol)
    }

    func CommandR(_ hc: IT2HostPointer) {
        if module.openMPTForeign { return foreignTremolo(hc, movesOn: true) }
        if module.playsAsDigitrakker {
            digitrakkerTremolo(hc, movesOn: true)
            return
        }
        if module.playsAsXTracker { return xTrackerTremolo(hc, movesOn: true) }
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_RECALC_VOL

        hc.pointee.TremoloPos &+= hc.pointee.TremoloSpeed

        let TremoloData: Int8
        if hc.pointee.TremoloWaveform == 3 {
            TremoloData = Int8(truncatingIfNeeded: Int(Random() & 127) - 64)
        } else {
            TremoloData = it2FineSineData[(Int(hc.pointee.TremoloWaveform) << 8) + Int(hc.pointee.TremoloPos)]
        }

        hc.pointee.LastTremoloData = TremoloData
        CommandR2(hc, sc, TremoloData)
    }

    /// The two of S's effects that wait some ticks: the delayed note and the cut.
    /// A cut that turns the note's volume to nought, and leaves it playing, so that a volume given
    /// after brings it back.
    func silenceCut(_ hc: IT2HostPointer) {
        hc.pointee.VolSet = 0
        guard hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.VolSet = 0
        sc.pointee.Vol = 0
        sc.pointee.Flags |= SF_RECALC_VOL
    }

    func CommandS(_ hc: IT2HostPointer) {
        let SCmd = hc.pointee.MiscEfxData[0]
        if SCmd == 0xD0 {
            // The delayed note: when its tick comes, the row's note is started as any is.
            hc.pointee.MiscEfxData[1] &-= 1
            if Int8(bitPattern: hc.pointee.MiscEfxData[1]) > 0 { return }

            hc.pointee.Flags &= ~(HF_UPDATE_EFX_IF_CHAN_ON | HF_ALWAYS_UPDATE_EFX)
            if tunings { openMPTTunedRow(hc) }
            if module.openMPT != nil { openMPTRow(hc) } else if ownVibrato || ways.countsStartWithNotes { modPlugRow(hc) }
            if module.playsAsXTracker { xTrackerRow(hc) }
            InitNoCommand(hc)
            hc.pointee.Flags |= HF_ROW_UPDATED

            let ChannelMuted = module.ChnlPan[Int(hc.pointee.HostChnNum) & 63] & 128 != 0
            if ChannelMuted, hc.pointee.Flags & HF_FREEPLAY_NOTE == 0, hc.pointee.Flags & HF_CHAN_ON != 0 {
                hc.pointee.SlaveChnPtr?.pointee.Flags |= SF_CHN_MUTED
            }
        } else if SCmd == 0xC0 {
            // The cut.
            if hc.pointee.Flags & HF_CHAN_ON == 0 { return }

            hc.pointee.MiscEfxData[1] &-= 1
            if Int8(bitPattern: hc.pointee.MiscEfxData[1]) > 0 { return }

            // (Digitrakker's cut turns the note down, and it plays on; and so does OpenMPT's own, in
            // an MPTM file that does not ask for Impulse Tracker's, switch 30.)
            if module.playsAsDigitrakker || ways.cutsOnlySilence {
                hc.pointee.Flags &= ~HF_UPDATE_EFX_IF_CHAN_ON
                silenceCut(hc)
                return
            }
            hc.pointee.Flags &= ~HF_CHAN_ON

            // The driver ramps volumes, so the voice is told to stop and left to it.
            hc.pointee.SlaveChnPtr?.pointee.Flags |= SF_NOTE_STOP
        }
    }

    /// A slide of tempo: T1x up, T0x down.
    func CommandT(_ hc: IT2HostPointer) {
        var NewTempo = Int16(bitPattern: Tempo)

        if hc.pointee.EfxMem_T & 0xF0 != 0 {
            NewTempo = Int16(truncatingIfNeeded: Int(NewTempo) + Int(hc.pointee.EfxMem_T) - 16)
            if NewTempo > tempoCeiling { // 255, but for an MPTM file that says otherwise
                NewTempo = tempoCeiling
                TempoFraction = 0
            }
        } else {
            NewTempo = Int16(truncatingIfNeeded: Int(NewTempo) - Int(hc.pointee.EfxMem_T))
            if NewTempo < 32 {
                NewTempo = 32
                TempoFraction = 0
            } else if NewTempo > tempoCeiling { // an MPTM file's, which can start higher than it may be slid to
                NewTempo = tempoCeiling
                TempoFraction = 0
            }
        }

        Tempo = UInt16(bitPattern: NewTempo)
        Music_InitTempo()
    }

    func CommandW(_ hc: IT2HostPointer) {
        var vol = UInt16(truncatingIfNeeded: Int(GlobalVolume) + Int(Int8(bitPattern: hc.pointee.MiscEfxData[0])))

        if Int16(bitPattern: vol) < 0 {
            vol = 0
        } else if vol > 128 {
            vol = 128
        }

        GlobalVolume = vol
        RecalculateAllVolumes()
    }

    func CommandY(_ hc: IT2HostPointer) {
        if hc.pointee.Flags & HF_CHAN_ON == 0 { return }

        guard let sc = hc.pointee.SlaveChnPtr else { return }
        if ownVibrato { return openMPTOwnPanbrello(hc, sc) }
        if !panbrelloHolds { hc.pointee.PanbrelloMoved = true }

        var panData: Int8
        if hc.pointee.PanbrelloWaveform >= 3, ways.randomPanbrelloMoves {
            // (A new place each tick.)
            panData = Int8(truncatingIfNeeded: Int(Random() & 127) - 64)
        } else if hc.pointee.PanbrelloWaveform >= 3 {
            // At random: the speed is how many ticks each place is kept for.
            hc.pointee.PanbrelloPos &-= 1
            if Int8(bitPattern: hc.pointee.PanbrelloPos) <= 0 {
                hc.pointee.PanbrelloPos = hc.pointee.PanbrelloSpeed
                panData = Int8(truncatingIfNeeded: Int(Random() & 127) - 64)
                hc.pointee.LastPanbrelloData = UInt8(bitPattern: panData)
            } else {
                panData = Int8(bitPattern: hc.pointee.LastPanbrelloData)
            }
        } else {
            hc.pointee.PanbrelloPos &+= hc.pointee.PanbrelloSpeed
            panData = it2FineSineData[(Int(hc.pointee.PanbrelloWaveform) << 8) + Int(hc.pointee.PanbrelloPos)]
        }

        if sc.pointee.PanSet != PAN_SURROUND {
            panData = Int8(truncatingIfNeeded: (((Int(panData) * Int(Int8(bitPattern: hc.pointee.PanbrelloDepth))) << 2) + 128) >> 8)
            panData = Int8(truncatingIfNeeded: Int(panData) + Int(sc.pointee.PanSet))

            if panData < 0 {
                panData = 0
            } else if panData > 64 {
                panData = 64
            }

            sc.pointee.Flags |= SF_RECALC_PAN
            sc.pointee.Pan = UInt8(bitPattern: panData)
        }
    }
}
