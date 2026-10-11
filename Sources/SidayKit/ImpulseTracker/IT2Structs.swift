// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from it2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): his C port of the replayer of Impulse Tracker 2.15, made from that tracker's
// own assembly. The names are the original's, as in the other ports here.

let CHN_DISOWNED: UInt8 = 128
let DIR_FORWARDS: UInt8 = 0
let DIR_BACKWARDS: UInt8 = 1
let PAN_SURROUND: UInt8 = 100
let LOOP_PINGPONG: UInt8 = 24
let BACKWARDS_ONCE: UInt8 = 1
let BACKWARDS_LOOP: UInt8 = 2
let LOOP_FORWARDS: UInt8 = 8

// Envelope flags.
let ENVF_ENABLED: UInt8 = 1
let ENVF_LOOP: UInt8 = 2
let ENVF_SUSTAINLOOP: UInt8 = 4
let ENVF_CARRY: UInt8 = 8
let ENVF_TYPE_FILTER: UInt8 = 128 // of the pitch envelope only

// Sample flags.
let SMPF_ASSOCIATED_WITH_HEADER: UInt8 = 1
let SMPF_16BIT: UInt8 = 2
let SMPF_STEREO: UInt8 = 4
let SMPF_COMPRESSED: UInt8 = 8
let SMPF_USE_LOOP: UInt8 = 16
let SMPF_USE_SUSTAINLOOP: UInt8 = 32
let SMPF_LOOP_PINGPONG: UInt8 = 64
let SMPF_SUSTAINLOOP_PINGPONG: UInt8 = 128

// Host channel flags.
let HF_UPDATE_EFX_IF_CHAN_ON: UInt16 = 1
let HF_ALWAYS_UPDATE_EFX: UInt16 = 2
let HF_CHAN_ON: UInt16 = 4
let HF_CHAN_CUT: UInt16 = 8
let HF_PITCH_SLIDE_ONGOING: UInt16 = 16
let HF_FREEPLAY_NOTE: UInt16 = 32
let HF_ROW_UPDATED: UInt16 = 64
let HF_APPLY_RANDOM_VOL: UInt16 = 128
let HF_UPDATE_VOLEFX_IF_CHAN_ON: UInt16 = 256
let HF_ALWAYS_VOLEFX: UInt16 = 512

// Slave channel flags.
let SF_CHAN_ON: UInt16 = 1
let SF_RECALC_PAN: UInt16 = 2
let SF_NOTE_OFF: UInt16 = 4
let SF_FADEOUT: UInt16 = 8
let SF_RECALC_VOL: UInt16 = 16
let SF_FREQ_CHANGE: UInt16 = 32
let SF_UPDATE_MIXERVOL: UInt16 = 64
let SF_CENTRAL_PAN: UInt16 = 128
let SF_NEW_NOTE: UInt16 = 256
let SF_NOTE_STOP: UInt16 = 512
let SF_LOOP_CHANGED: UInt16 = 1024
let SF_CHN_MUTED: UInt16 = 2048
let SF_VOLENV_ON: UInt16 = 4096
let SF_PANENV_ON: UInt16 = 8192
let SF_PITCHENV_ON: UInt16 = 16384
let SF_PAN_CHANGED: UInt16 = 32768

// Flags in the file's header.
let ITF_STEREO: UInt16 = 1
let ITF_VOL0_OPTIMIZATION: UInt16 = 2
let ITF_INSTR_MODE: UInt16 = 4
let ITF_LINEAR_FRQ: UInt16 = 8
let ITF_OLD_EFFECTS: UInt16 = 16
let ITF_COMPAT_GXX: UInt16 = 32
let ITF_USE_MIDI_PITCH_CNTRL: UInt16 = 64
let ITF_REQ_MIDI_CFG: UInt16 = 128
let ITF_MPT_EXT_FILTER_RANGE: UInt16 = 4096 // ModPlug Tracker's

/// An envelope: up to twenty-five points, each a level at a tick, with a loop and a loop that
/// holds while the key is down. (An MPTM file's can have more points, and then these two lists are
/// as long as it needs; and it can name a point to go to when the key is let go, which no other has.)
struct IT2Envelope {
    var Flags: UInt8 = 0, Num: UInt8 = 0, LoopBegin: UInt8 = 0, LoopEnd: UInt8 = 0, SustainLoopBegin: UInt8 = 0, SustainLoopEnd: UInt8 = 0
    var Magnitude = [Int8](repeating: 0, count: 25)
    var Tick = [UInt16](repeating: 0, count: 25)
    /// OpenMPT's "release node"; `noReleaseNode` for none, which is all an IT file has.
    var ReleaseNode: UInt8 = IT2Envelope.noReleaseNode
    static let noReleaseNode: UInt8 = 255
}

/// An instrument: which sample each note plays, envelopes for its volume, its place and its pitch
/// or filter, and what becomes of a note of it when the next arrives on its channel.
final class IT2Instrument {
    var NNA: UInt8 = 0, DCT: UInt8 = 0, DCA: UInt8 = 0
    var FadeOut: UInt16 = 0
    var PitchPanSep: UInt8 = 0, PitchPanCenter: UInt8 = 60, GlobVol: UInt8 = 128, DefPan: UInt8 = 32 | 128, RandVol: UInt8 = 0, RandPan: UInt8 = 0
    var FilterCutoff: UInt8 = 0, FilterResonance: UInt8 = 0, MIDIChn: UInt8 = 0, MIDIProg: UInt8 = 0
    var MIDIBank: UInt16 = 0
    /// For each of 120 notes: the note to play in the low byte, the sample to play it on in the high.
    var SmpNoteTable = [UInt16](repeating: 0, count: 120)
    var VolEnv = IT2Envelope(), PanEnv = IT2Envelope(), PitchEnv = IT2Envelope()
    /// For an MPTM file's instrument only: 1 if its filter lets the high through and not the low,
    /// 0 if the low, and `sameFilter` to leave its channel's filter as the last instrument had it,
    /// which is all an IT file's instrument does.
    var FilterMode: UInt8 = IT2Instrument.sameFilter
    static let sameFilter: UInt8 = 255
    /// For an instrument of ModPlug Tracker's or OpenMPT's only: how far its filter's cutoff and
    /// resonance are moved at random from one note to the next, of 64 (see `ApplyRandomValues`).
    var CutSwing: UInt8 = 0, ResSwing: UInt8 = 0
    /// For an instrument of an IT file that ModPlug Tracker or an OpenMPT before 1.20 made: its
    /// envelope for pitch or the filter as that tracker played it, which was as FastTracker plays
    /// one (see `MPTMFile.asFastTrackerLooped`). Nil for any other.
    var PitchEnvAsModPlug: IT2Envelope?
    /// For an MPTM file's instrument only, and of those only one tuned to a scale of its own that is
    /// near enough the usual one to be played (see `MPTMFile`): what each of the 120 notes is to
    /// middle C, where the usual tuning has a semitone between each and the next. Nil for the usual.
    var Tuning: [Float]?
    /// For a file of ModPlug Tracker's or OpenMPT's: the plug-in its notes are sent through, counted
    /// from 1; nought for none, which is all any other file's instrument has.
    var MixPlug: UInt8 = 0
}

/// A sample. Its sound is held with room either side for the mixer to read past its ends, which is
/// filled in before mixing according to how it loops.
final class IT2Sample {
    var GlobVol: UInt8 = 0, Flags: UInt8 = 0, Vol: UInt8 = 0
    var Cvt: UInt8 = 0, DefPan: UInt8 = 0
    var Length: UInt32 = 0, LoopBegin: UInt32 = 0, LoopEnd: UInt32 = 0, C5Speed: UInt32 = 0
    var SustainLoopBegin: UInt32 = 0, SustainLoopEnd: UInt32 = 0, OffsetInFile: UInt32 = 0
    var AutoVibratoSpeed: UInt8 = 0, AutoVibratoDepth: UInt8 = 0, AutoVibratoRate: UInt8 = 0, AutoVibratoWaveform: UInt8 = 0
    /// The first sample of its sound, left (or only) and right; nil for none. `OrigData` is what was
    /// allocated, which starts before it.
    var Data: UnsafeMutableRawPointer?, OrigData: UnsafeMutableRawPointer?
    var DataR: UnsafeMutableRawPointer?, OrigDataR: UnsafeMutableRawPointer?
    /// The places in it that an MPTM file's volume column can start a note from; none in any other file.
    var cues: [UInt32] = []
    /// For a file of OpenMPT's: the eleven numbers of a patch for the AdLib's FM chip, and one to
    /// spare, if that is what the sample is in place of a sound (see `OpenMPTAdLib`). Nil for a sample.
    var AdLib: [UInt8]?

    deinit {
        OrigData?.deallocate()
        OrigDataR?.deallocate()
    }
}

/// A channel of the pattern: what was last read into it and what its effects remember. (These and
/// the voices are kept in memory of the player's own and passed about by address, as the original
/// passes them.)
struct IT2HostChannel {
    var Flags: UInt16 = 0
    var NotePackMask: UInt8 = 0, RawNote: UInt8 = 0, Ins: UInt8 = 0, RawVolColumn: UInt8 = 0, Cmd: UInt8 = 0, CmdVal: UInt8 = 0
    var OldCmd: UInt8 = 0, OldCmdVal: UInt8 = 0, VolCmd: UInt8 = 0, VolCmdVal: UInt8 = 0
    var MIDIChn: UInt8 = 0, MIDIProg: UInt8 = 0, TranslatedNote: UInt8 = 0, Smp: UInt8 = 0
    var EfxMem_DKL: UInt8 = 0, EfxMem_EFG: UInt8 = 0, EfxMem_O: UInt8 = 0, EfxMem_I: UInt8 = 0, EfxMem_J: UInt8 = 0, EfxMem_N: UInt8 = 0
    var EfxMem_P: UInt8 = 0, EfxMem_Q: UInt8 = 0, EfxMem_T: UInt8 = 0, EfxMem_S: UInt8 = 0, EfxMem_W: UInt8 = 0, EfxMem_G_Compat: UInt8 = 0
    var EfxMem_SFx: UInt8 = 0
    var HighSmpOffs: UInt8 = 0
    var HostChnNum: UInt8 = 0, VolSet: UInt8 = 0
    /// The voice that is playing its note, if one is.
    var SlaveChnPtr: UnsafeMutablePointer<IT2SlaveChannel>?
    /// (Impulse Tracker keeps the row in a byte, and it is held to one for every module but an MPTM
    /// file's, whose patterns are longer than a byte can count.)
    var PattLoopStartRow: UInt16 = 0
    var PattLoopCount: UInt8 = 0
    var PanbrelloWaveform: UInt8 = 0, PanbrelloPos: UInt8 = 0, PanbrelloDepth: UInt8 = 0, PanbrelloSpeed: UInt8 = 0, LastPanbrelloData: UInt8 = 0
    var LastVibratoData: Int8 = 0, LastTremoloData: Int8 = 0
    var ChnPan: UInt8 = 0, ChnVol: UInt8 = 0
    var VolSlideDelta: Int8 = 0
    var TremorCount: UInt8 = 0, TremorOnOff: UInt8 = 0, RetrigCount: UInt8 = 0
    var PortaFreq: Int32 = 0
    var VibratoWaveform: UInt8 = 0, VibratoPos: UInt8 = 0, VibratoDepth: UInt8 = 0, VibratoSpeed: UInt8 = 0
    var TremoloWaveform: UInt8 = 0, TremoloPos: UInt8 = 0, TremoloDepth: UInt8 = 0, TremoloSpeed: UInt8 = 0
    var MiscEfxData = InlineArray<16, UInt8>(repeating: 0)
    /// For an MPTM file only: where its last note was started from within its sample, for a note
    /// that asks to start where the last did.
    var OffsetMemory: UInt32 = 0
    /// For an MPTM file only: true if its filter lets the high through. See `IT2Instrument`.
    var HighPass = false
    /// For an instrument whose filter is moved at random (see `IT2Instrument.CutSwing`): what the
    /// channel's cutoff and resonance were before the note's were moved, and one more, to be put
    /// back when the next note comes, or nought for nothing to put back; and how far they were moved.
    var RestoreCutoff: UInt8 = 0, RestoreResonance: UInt8 = 0
    var CutSwing: Int16 = 0, ResSwing: Int16 = 0
}

/// Where an envelope has got to.
struct IT2EnvState {
    var Value: Int32 = 0, Delta: Int32 = 0
    var Tick: Int16 = 0, CurNode: Int16 = 0, NextTick: Int16 = 0
}

/// A voice: a note that is sounding, whether its channel still owns it or has gone on to another.
struct IT2SlaveChannel {
    var SmpIs16Bit = false
    var Flags: UInt16 = 0
    /// Which of the mixer's routines plays it.
    var MixOffset: UInt32 = 0
    var LoopMode: UInt8 = 0, LoopDirection: UInt8 = 0
    /// For an MPTM file only, whose S9F plays a sample backwards: nought for a voice left to play as
    /// its sample says, `BACKWARDS_ONCE` for one playing backwards to its start, where it ends, and
    /// `BACKWARDS_LOOP` for one whose loop is being gone round the other way.
    var Backwards: UInt8 = 0
    /// For an MPTM file only: what a volume envelope was at, of 256, when its key was let go and it
    /// went on from its "release node"; less than nought until then, and for ever in any other file.
    var ReleaseLevel: Int16 = -1
    /// For an MPTM file only: its channel's `HighPass` as it was when the note began.
    var HighPass = false
    /// For a file played with OpenMPT's own filter only (see `IT2Module.Filter`). `FilterSet` is
    /// true once a macro or the instrument's envelope has set the voice's filter since its note
    /// began, and `FilterEnvelope` once that envelope has been followed; `FilterOn` is the mixer's,
    /// and true from when the voice's filter is first on, after which it is not off again.
    var FilterSet = false, FilterEnvelope = false, FilterOn = false
    /// And true if the note began with its channel's cutoff below the top, which is when a note
    /// has that filter from its start.
    var FilterFromStart = false
    /// How many notes the voice has been given, as far as a byte counts: for telling a new note
    /// on it from the note it had. Only what plays the FM chip looks.
    var Started: UInt8 = 0
    /// `FinalVol32768` as it was before the song's volume went into it. OpenMPT applies the song's
    /// volume to the whole sound, after its plug-ins, and plays the FM chip's notes without it.
    var VolNoGlobal: UInt16 = 0
    var LeftVolume: Int32 = 0, RightVolume: Int32 = 0
    var Frequency: Int32 = 0, FrequencySet: Int32 = 0
    var AutoVibratoPos: UInt8 = 0
    var AutoVibratoDepth: UInt16 = 0
    var OldLeftVolume: Int32 = 0, OldRightVolume: Int32 = 0
    var FinalVol128: UInt8 = 0, Vol: UInt8 = 0, VolSet: UInt8 = 0, ChnVol: UInt8 = 0, SmpVol: UInt8 = 0, FinalPan: UInt8 = 0
    var FadeOut: UInt16 = 0
    var DCT: UInt8 = 0, DCA: UInt8 = 0, Pan: UInt8 = 0, PanSet: UInt8 = 0
    var InsPtr: IT2Instrument?
    var SmpPtr: IT2Sample?
    var Note: UInt8 = 0, Ins: UInt8 = 0
    var Smp: UInt8 = 0
    var HostChnPtr: UnsafeMutablePointer<IT2HostChannel>?
    var HostChnNum: UInt8 = 0, NNA: UInt8 = 0, MIDIChn: UInt8 = 0, MIDIProg: UInt8 = 0
    var MIDIBank: UInt16 = 0
    var LoopBegin: Int32 = 0, LoopEnd: Int32 = 0
    var Frac32: UInt32 = 0
    var FinalVol32768: UInt16 = 0
    var SamplingPosition: Int32 = 0
    var filtera: Int32 = 0, filterb: Int32 = 0, filterc: Int32 = 0
    var VolEnvState = IT2EnvState(), PanEnvState = IT2EnvState(), PitchEnvState = IT2EnvState()

    // For the mixer.
    var fOldSamples: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var fFiltera: Float = 0, fFilterb: Float = 0, fFilterc: Float = 0
    var HasLooped = false
    var fOldLeftVolume: Float = 0, fOldRightVolume: Float = 0, fLeftVolume: Float = 0, fRightVolume: Float = 0
    var fDestVolL: Float = 0, fDestVolR: Float = 0, fCurrVolL: Float = 0, fCurrVolR: Float = 0
    var Frac64: UInt64 = 0, Delta64: UInt64 = 0

    // What lay where the mixer's room either side of a loop was filled in, to put back.
    var leftTmpSamples16: (Int16, Int16, Int16) = (0, 0, 0), rightTmpSamples16: (Int16, Int16, Int16, Int16) = (0, 0, 0, 0)
    var leftTmpSamples8: (Int8, Int8, Int8) = (0, 0, 0), rightTmpSamples8: (Int8, Int8, Int8, Int8) = (0, 0, 0, 0)
    var leftTmpSamples16_R: (Int16, Int16, Int16) = (0, 0, 0), rightTmpSamples16_R: (Int16, Int16, Int16, Int16) = (0, 0, 0, 0)
    var leftTmpSamples8_R: (Int8, Int8, Int8) = (0, 0, 0), rightTmpSamples8_R: (Int8, Int8, Int8, Int8) = (0, 0, 0, 0)
}
