// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from it2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): his C port of the replayer of Impulse Tracker 2.15, made from that tracker's
// own assembly. The names are the original's, as in the other ports here.

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

    /// The rate a sample is played at for a note (which is below 120).
    @inline(__always) private func noteFrequency(_ s: IT2Sample?, _ note: UInt8) -> Int32 {
        Int32(truncatingIfNeeded: (UInt64(s?.C5Speed ?? 0) &* UInt64(it2PitchTable[Int(note)])) >> 16)
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
        if module.Flags & ITF_OLD_EFFECTS != 0 {
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

        let hi = hc.pointee.EfxMem_DKL & 0xF0
        let lo = hc.pointee.EfxMem_DKL & 0x0F

        if lo == 0 {
            // Up. (DF0 slides on the first tick as well.)
            hc.pointee.VolSlideDelta = Int8(hi >> 4)
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            if hc.pointee.VolSlideDelta == 15 { CommandD(hc) }
        } else if hi == 0 {
            // Down. (And so does D0F.)
            hc.pointee.VolSlideDelta = -Int8(lo)
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            if hc.pointee.VolSlideDelta == -15 { CommandD(hc) }
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
        }
    }

    // MARK: The volume column

    /// The volume column's effect as its row is read. They are numbered from 0: fine slides of
    /// volume up and down (done here and now), slides of volume up and down, of pitch down and up,
    /// a slide to the note, and vibrato. The first four remember their value together; the slides of
    /// pitch share E, F and G's.
    private func InitVolumeEffect(_ hc: IT2HostPointer) {
        if hc.pointee.NotePackMask & 0x44 == 0 { return }

        var volCmd = Int(hc.pointee.RawVolColumn & 0x7F) - 65
        if volCmd < 0 { return }
        if hc.pointee.RawVolColumn & 0x80 != 0 { volCmd += 60 }

        let cmd = UInt8(volCmd / 10)
        let val = UInt8(volCmd % 10)

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
                    if val != 0 { hc.pointee.VibratoDepth = val << 2 }
                    if hc.pointee.Flags & HF_CHAN_ON != 0 { InitVibrato(hc) }
                } else if cmd == 6 {
                    InitCommandG11(hc)
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
        CommandEChain(hc, UInt16(hc.pointee.EfxMem_EFG) << 2)
    }

    func VolumeCommandF(_ hc: IT2HostPointer) {
        CommandFChain(hc, UInt16(hc.pointee.EfxMem_EFG) << 2)
    }

    func VolumeCommandG(_ hc: IT2HostPointer) {
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

        if ApplyRandomVolume { ApplyRandomValues(hc) }

        InitVolumeEffect(hc)
    }

    /// The volume a row gives: the volume column's if it is one, else the sample's own if the row
    /// names an instrument.
    private func NoOldEffect(_ hc: IT2HostPointer, _ hcFlags: UInt8) {
        var vol = hc.pointee.RawVolColumn
        if hc.pointee.NotePackMask & 0x44 == 0 || vol > 64 {
            if hc.pointee.NotePackMask & 0x44 != 0, vol & 0x7F < 65 {
                // The volume column is a place between the speakers.
                hc.pointee.Flags = (hc.pointee.Flags & 0xFF00) | UInt16(hcFlags)
                InitCommandX2(hc, vol &- 128)
            }

            if hc.pointee.NotePackMask & 0x22 == 0 || hc.pointee.Smp == 0 {
                InitNoCommand3(hc, hcFlags)
                return
            }

            // (A sample there is none of, as a MIDI note's, has no volume. The original reads past
            // its table.)
            vol = module.sample(Int(hc.pointee.Smp) - 1)?.Vol ?? 0
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
        var hcFlags = UInt8(truncatingIfNeeded: hc.pointee.Flags)

        if hc.pointee.NotePackMask & 0x33 == 0 {
            NoOldEffect(hc, hcFlags)
            return
        }

        // Not a note to play: a release (255), a cut (254) or a fade (any other).
        if hc.pointee.TranslatedNote >= 120 {
            if hcFlags & UInt8(HF_CHAN_ON) != 0, let sc = hc.pointee.SlaveChnPtr {
                if hc.pointee.TranslatedNote == 255 {
                    sc.pointee.Flags |= SF_NOTE_OFF
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

        // An instrument alone, the same as is playing and at the same note, starts nothing.
        if hcFlags & UInt8(HF_CHAN_ON) != 0, let sc = hc.pointee.SlaveChnPtr {
            if hc.pointee.NotePackMask & 0x11 == 0, sc.pointee.Note == hc.pointee.RawNote, sc.pointee.Ins == hc.pointee.Ins {
                NoOldEffect(hc, hcFlags)
                return
            }
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
            sc.pointee.Pan = s.DefPan & 127
            hc.pointee.ChnPan = s.DefPan & 127
        }

        sc.pointee.SamplingPosition = 0
        sc.pointee.Frac32 = 0
        sc.pointee.Frac64 = 0
        sc.pointee.HasLooped = false
        sc.pointee.FrequencySet = noteFrequency(s, hc.pointee.TranslatedNote)
        sc.pointee.Frequency = sc.pointee.FrequencySet

        hcFlags |= UInt8(HF_CHAN_ON)
        hcFlags &= ~UInt8(HF_PITCH_SLIDE_ONGOING)

        InitNoCommand11(hc, sc, hcFlags)
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
        ProcessOrder = UInt16(hc.pointee.CmdVal) &- 1
        ProcessRow = 0xFFFE

        InitNoCommand(hc)
    }

    /// Cxx: on to a row of the next pattern.
    func InitCommandC(_ hc: IT2HostPointer) {
        if !PatternLooping {
            BreakRow = UInt16(hc.pointee.CmdVal)
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

        var CmdVal = hc.pointee.CmdVal
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_EFG }
        hc.pointee.EfxMem_EFG = CmdVal

        if hc.pointee.Flags & HF_CHAN_ON == 0 || hc.pointee.EfxMem_EFG == 0 { return }

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

        var CmdVal = hc.pointee.CmdVal
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_EFG }
        hc.pointee.EfxMem_EFG = CmdVal

        if hc.pointee.Flags & HF_CHAN_ON == 0 || hc.pointee.EfxMem_EFG == 0 { return }

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

            if module.Flags & ITF_COMPAT_GXX != 0 {
                // "Compatible Gxx": the sample stays, and the instrument's envelopes start again.
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
            }
        }

        if module.Flags & ITF_INSTR_MODE != 0 || hc.pointee.NotePackMask & 0x11 != 0 {
            // Where the slide is to end.
            if hc.pointee.TranslatedNote < 120 {
                if hc.pointee.Smp != midiSample { sc.pointee.Note = hc.pointee.TranslatedNote }

                hc.pointee.PortaFreq = noteFrequency(sc.pointee.SmpPtr, hc.pointee.TranslatedNote)
                hc.pointee.Flags |= HF_PITCH_SLIDE_ONGOING
            } else if hc.pointee.Flags & HF_CHAN_ON != 0 {
                if hc.pointee.TranslatedNote == 255 {
                    sc.pointee.Flags |= SF_NOTE_OFF
                    GetLoopInformation(sc)
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
                InitCommandX2(hc, hc.pointee.RawVolColumn &- 128)
            }
        }

        if volFromVolColumn || hc.pointee.NotePackMask & 0x22 != 0 {
            if !volFromVolColumn { vol = sc.pointee.SmpPtr?.Vol ?? 0 }

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
        if hc.pointee.CmdVal != 0 {
            if module.Flags & ITF_COMPAT_GXX != 0 {
                hc.pointee.EfxMem_G_Compat = hc.pointee.CmdVal
            } else {
                hc.pointee.EfxMem_EFG = hc.pointee.CmdVal
            }
        }

        if hc.pointee.Flags & HF_CHAN_ON == 0 {
            InitNoCommand(hc)
            return
        }

        InitCommandG11(hc)
    }

    /// Hxy: vibrato.
    func InitCommandH(_ hc: IT2HostPointer) {
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
        let CmdVal = hc.pointee.CmdVal
        if CmdVal > 0 { hc.pointee.EfxMem_DKL = CmdVal }

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            InitCommandG11(hc)
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

        if hc.pointee.NotePackMask & 0x33 != 0, hc.pointee.TranslatedNote < 120, hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr {
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

        if pan == PAN_SURROUND { return }

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
            InitCommandX2(hc, pan)
        } else if hi == 0xF0 {
            pan &+= lo
            if pan > 64 { pan = 64 }
            InitCommandX2(hc, pan)
        }
    }

    /// Qxy: the note struck again every y ticks, its volume changed each time as x says.
    func InitCommandQ(_ hc: IT2HostPointer) {
        InitNoCommand(hc)

        if hc.pointee.CmdVal > 0 { hc.pointee.EfxMem_Q = hc.pointee.CmdVal }

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
        if module.Flags & ITF_OLD_EFFECTS != 0 {
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

        InitNoCommand(hc)

        if hc.pointee.Flags & HF_CHAN_ON != 0 {
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            InitTremolo(hc)
        }
    }

    /// Sxy: sixteen lesser effects.
    func InitCommandS(_ hc: IT2HostPointer) {
        var CmdVal = hc.pointee.CmdVal
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_S }
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
            if val <= 3 {
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
            InitCommandX2(hc, pan)

        case 0x90: // S91: surround
            InitNoCommand(hc)
            if val == 1 { InitCommandX2(hc, PAN_SURROUND) }

        case 0xA0: // the high part of Oxx's offset
            hc.pointee.HighSmpOffs = val
            InitNoCommand(hc)

        case 0xB0: // a loop within the pattern: SB0 marks its start, SBx goes back to it x times
            InitNoCommand(hc)

            if val == 0 {
                hc.pointee.PattLoopStartRow = UInt8(truncatingIfNeeded: CurrentRow)
            } else if hc.pointee.PattLoopCount == 0 {
                hc.pointee.PattLoopCount = val
                ProcessRow = UInt16(hc.pointee.PattLoopStartRow) &- 1
                PatternLooping = true
                rowsWillRepeat(from: Int(hc.pointee.PattLoopStartRow))
            } else {
                hc.pointee.PattLoopCount &-= 1
                if hc.pointee.PattLoopCount != 0 {
                    ProcessRow = UInt16(hc.pointee.PattLoopStartRow) &- 1
                    PatternLooping = true
                    rowsWillRepeat(from: Int(hc.pointee.PattLoopStartRow))
                } else {
                    // Done: a later loop without a start of its own starts after this one.
                    hc.pointee.PattLoopStartRow = UInt8(truncatingIfNeeded: CurrentRow) &+ 1
                }
            }

        case 0xC0: // the note is cut after some ticks
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
            InitNoCommand(hc)

        case 0xD0: // the note is started after some ticks, and not now
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX

        case 0xE0: // the row is played some times more
            if !RowDelayOn {
                RowDelay = val + 1
                RowDelayOn = true
            }
            InitNoCommand(hc)

        case 0xF0: // which of the MIDI settings' macros Zxx sends
            hc.pointee.EfxMem_SFx = val
            InitNoCommand(hc)

        default: // S0x, S1x and S2x do nothing
            InitNoCommand(hc)
        }
    }

    /// Txx: the tempo, or below T20 a slide of it.
    func InitCommandT(_ hc: IT2HostPointer) {
        var CmdVal = hc.pointee.CmdVal
        if CmdVal == 0 { CmdVal = hc.pointee.EfxMem_T }
        hc.pointee.EfxMem_T = CmdVal

        if CmdVal >= 0x20 {
            Tempo = UInt16(CmdVal)
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
        if hc.pointee.CmdVal <= 0x80 {
            GlobalVolume = UInt16(hc.pointee.CmdVal)
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
    private func InitCommandX2(_ hc: IT2HostPointer, _ pan: UInt8) {
        if hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr {
            sc.pointee.PanSet = pan
            sc.pointee.Pan = pan
            sc.pointee.Flags |= SF_RECALC_PAN | SF_UPDATE_MIXERVOL
        }

        hc.pointee.ChnPan = pan
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
    func InitCommandZ(_ hc: IT2HostPointer) {
        InitNoCommand(hc)

        // (The voice is whichever the channel last had, playing or not.)
        let sc = hc.pointee.SlaveChnPtr

        if hc.pointee.CmdVal >= 0x80 {
            MIDITranslate(hc, sc, 0x320 + (UInt16(hc.pointee.CmdVal & 0x7F) << 5))
        } else {
            MIDITranslate(hc, sc, 0x120 + (UInt16(hc.pointee.EfxMem_SFx & 0xF) << 5))
        }
    }

    // MARK: Effects on the ticks after

    func CommandD(_ hc: IT2HostPointer) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }

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
        CommandEChain(hc, MiscEfxWord(hc, 0))
    }

    func CommandF(_ hc: IT2HostPointer) {
        CommandFChain(hc, MiscEfxWord(hc, 0))
    }

    func CommandG(_ hc: IT2HostPointer) {
        if hc.pointee.Flags & HF_PITCH_SLIDE_ONGOING == 0 { return }

        let SlideValue = Int16(bitPattern: MiscEfxWord(hc, 0))
        guard let sc = hc.pointee.SlaveChnPtr else { return }

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
    }

    /// Bends the pitch by a step of the vibrato's wave times its depth. The result is cut to eight
    /// bits, as the original's is.
    private func CommandH5(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ VibratoData: Int8) {
        var VibratoData = Int8(truncatingIfNeeded: (((Int(VibratoData) * Int(Int8(bitPattern: hc.pointee.VibratoDepth))) << 2) + 128) >> 8)
        if module.Flags & ITF_OLD_EFFECTS != 0 { VibratoData = 0 &- VibratoData }

        if VibratoData < 0 {
            PitchSlideDown(hc, sc, -Int16(VibratoData))
        } else {
            PitchSlideUp(hc, sc, Int16(VibratoData))
        }
    }

    func CommandH(_ hc: IT2HostPointer) {
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

        pan &+= hc.pointee.MiscEfxData[0]

        if Int8(bitPattern: pan) < 0 {
            pan = 0
        } else if pan > 64 {
            pan = 64
        }

        InitCommandX2(hc, pan)
    }

    func CommandQ(_ hc: IT2HostPointer) {
        hc.pointee.RetrigCount &-= 1
        if Int8(bitPattern: hc.pointee.RetrigCount) > 0 { return }

        hc.pointee.RetrigCount = hc.pointee.EfxMem_Q & 0x0F

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
    private func CommandR2(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ TremoloData: Int8) {
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
    func CommandS(_ hc: IT2HostPointer) {
        let SCmd = hc.pointee.MiscEfxData[0]
        if SCmd == 0xD0 {
            // The delayed note: when its tick comes, the row's note is started as any is.
            hc.pointee.MiscEfxData[1] &-= 1
            if Int8(bitPattern: hc.pointee.MiscEfxData[1]) > 0 { return }

            hc.pointee.Flags &= ~(HF_UPDATE_EFX_IF_CHAN_ON | HF_ALWAYS_UPDATE_EFX)
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
            if NewTempo > 255 { NewTempo = 255 }
        } else {
            NewTempo = Int16(truncatingIfNeeded: Int(NewTempo) - Int(hc.pointee.EfxMem_T))
            if NewTempo < 32 { NewTempo = 32 }
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

        var panData: Int8
        if hc.pointee.PanbrelloWaveform >= 3 {
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
