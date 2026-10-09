// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from it2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): his C port of the replayer of Impulse Tracker 2.15, made from that tracker's
// own assembly. The names are the original's, as in the other ports here.

typealias IT2HostPointer = UnsafeMutablePointer<IT2HostChannel>
typealias IT2SlavePointer = UnsafeMutablePointer<IT2SlaveChannel>

let MAX_HOST_CHANNELS = 64
let MAX_SLAVE_CHANNELS = 256

private let NNA_NOTE_CUT: UInt8 = 0, NNA_CONTINUE: UInt8 = 1, NNA_NOTE_OFF: UInt8 = 2, NNA_NOTE_FADE: UInt8 = 3
private let DCT_DISABLED: UInt8 = 0, DCT_NOTE: UInt8 = 1, DCT_SAMPLE: UInt8 = 2, DCT_INSTRUMENT: UInt8 = 3
private let DCA_NOTE_CUT: UInt8 = 0

/// Impulse Tracker's replayer.
///
/// A pattern has 64 channels, and a note on one of them is played by a voice, of which there are
/// 256. A channel can let go of a voice and start another while the first plays on, fades or is
/// released, as its instrument says (its "new note action"), so one channel can have many voices
/// sounding; when there are none to spare, the quietest that nobody owns is taken.
///
/// The sound driver is the one the port this is made from adds to Impulse Tracker's own: it ramps
/// volumes, has the resonant filter, and does everything a driver can be asked, so the questions the
/// replayer puts to its driver are answered here as that driver answers them.
final class IT2Player {
    let module: IT2Module
    let hChn: IT2HostPointer
    let sChn: IT2SlavePointer

    // The song as it plays.
    var CurrentOrder: UInt16 = 0, CurrentPattern: UInt16 = 0, CurrentRow: UInt16 = 0, ProcessOrder: UInt16 = 0, ProcessRow: UInt16 = 0
    var BreakRow: UInt16 = 0
    var RowDelay: UInt8 = 0
    var RowDelayOn = false, StopSong = false, PatternLooping = false
    var NumberOfRows: UInt16 = 0, CurrentTick: UInt16 = 0, CurrentSpeed: UInt16 = 0, ProcessTick: UInt16 = 0
    var Tempo: UInt16 = 0, GlobalVolume: UInt16 = 0
    var DecodeExpectedPattern: UInt16 = 0, DecodeExpectedRow: UInt16 = 0
    /// The packed pattern being played, and where in it the next row is.
    var PatternData: [UInt8] = []
    var PatternOffset = 0
    var LastMIDIByte: UInt8 = 0
    var Playing = false

    // The driver's.
    /// The filter's setting for each channel, as last sent to it: 64 cutoffs, then 64 resonances.
    let FilterParameters: UnsafeMutablePointer<UInt8>
    let NumChannels = MAX_SLAVE_CHANNELS
    let mixer: IT2Mixer

    // Coming round, and the songs of a file that has several: see `ModuleSongs`.
    private let visited: UnsafeMutablePointer<Bool>
    /// True when the tick just run began a row that has been played before.
    private(set) var cameRound = false
    private(set) var ordersPlayed = [Bool](repeating: false, count: 256)
    var playedNote = false
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let songNumber: UInt8
    private var metEarlierSong = false
    private(set) var ledIntoEarlierSong = false
    private var offTheEnd = false
    /// How many rows the table of who played a row first has: 256 for each of 256 places. (A
    /// pattern can be longer; its rows beyond that are not kept track of.)
    static let rowsInAll = 256 * 256

    private var MIDIInterpretState: UInt8 = 0, MIDIInterpretType: UInt8 = 0
    private var RandSeed1: UInt16 = 0x1234, RandSeed2: UInt16 = 0x5678
    /// The text of the tracker's MIDI settings: 9 commands, 16 macros for SFx and 128 for Zxx, each
    /// 32 characters. Only what they say about the filter is acted on.
    var MIDIDataArea = [UInt8](repeating: 0, count: (9 + 16 + 128) * 32)

    private var ChannelCountTable = [UInt8](repeating: 0, count: 256), ChannelVolumeTable = [UInt8](repeating: 0, count: 256)
    private var ChannelLocationTable = [IT2SlavePointer?](repeating: nil, count: 256)
    /// See `IT2Module`: the numbers that stand for a MIDI note, and how many samples there is room for.
    let midiSample: UInt8, midiVoiceSample: UInt8
    private let sampleLimit: Int
    var LastSlaveChannel: IT2SlavePointer?

    func RecalculateAllVolumes() {
        for i in 0 ..< NumChannels { sChn[i].Flags |= SF_RECALC_PAN | SF_RECALC_VOL }
    }

    /// The MIDI settings a file has when it brings none of its own, which are what make Zxx and SFx
    /// work the filter.
    func Music_SetDefaultMIDIDataArea() {
        MIDIDataArea = [UInt8](repeating: 0, count: (9 + 16 + 128) * 32)
        func put(_ slot: Int, _ text: String) {
            for (i, byte) in text.utf8.enumerated() { MIDIDataArea[slot * 32 + i] = byte }
        }
        put(0, "FF")
        put(1, "FC")
        put(3, "9c n v")
        put(4, "9c n 0")
        put(7, "Bc 0 a 20 b")
        put(8, "Cc p")
        put(9, "F0F000z") // SF0: the cutoff
        // Z80 to Z8F: sixteen resonances.
        for i in 0 ..< 16 {
            let value = i * 8
            let digits = Array("0123456789ABCDEF".utf8)
            put(25 + i, "F0F001" + String(decoding: [digits[value >> 4], digits[value & 15]], as: UTF8.self))
        }
    }

    /// A byte on its way to a MIDI port. There is none: the bytes are watched for the messages that
    /// set the filter, as Impulse Tracker's own software drivers watch them.
    private func MIDISendFilter(_ hc: IT2HostPointer, _ sc: IT2SlavePointer?, _ Data: UInt8) {
        if Data >= 0x80, Data < 0xF0 {
            if Data == LastMIDIByte { return }
            LastMIDIByte = Data
        }
        if MIDIInterpretState < 2 {
            if Data == 0xF0 {
                MIDIInterpretState += 1
            } else {
                if Data == 0xFA || Data == 0xFC || Data == 0xFF {
                    // The filters are reset.
                    for i in 0 ..< MAX_HOST_CHANNELS {
                        FilterParameters[i] = 127
                        FilterParameters[64 + i] = 0
                    }
                }
                MIDIInterpretState = 0
            }
        } else if MIDIInterpretState == 2 {
            if Data < 2 { // cutoff or resonance
                MIDIInterpretType = Data
                MIDIInterpretState += 1
            } else {
                MIDIInterpretState = 0
            }
        } else if MIDIInterpretState == 3 {
            if Data <= 0x7F {
                if MIDIInterpretType == 1 {
                    FilterParameters[(64 + Int(hc.pointee.HostChnNum)) & 127] = Data
                } else {
                    FilterParameters[Int(hc.pointee.HostChnNum) & 127] = Data
                }
                if let sc { sc.pointee.Flags |= SF_UPDATE_MIXERVOL }
            }
            MIDIInterpretState = 0
        }
    }

    func SetFilterCutoff(_ hc: IT2HostPointer, _ sc: IT2SlavePointer?, _ value: UInt8) {
        MIDISendFilter(hc, sc, 0xF0)
        MIDISendFilter(hc, sc, 0xF0)
        MIDISendFilter(hc, sc, 0x00)
        MIDISendFilter(hc, sc, value)
    }

    func SetFilterResonance(_ hc: IT2HostPointer, _ sc: IT2SlavePointer?, _ value: UInt8) {
        MIDISendFilter(hc, sc, 0xF0)
        MIDISendFilter(hc, sc, 0xF0)
        MIDISendFilter(hc, sc, 0x01)
        MIDISendFilter(hc, sc, value)
    }

    /// Sends one of the MIDI settings' lines: pairs of hexadecimal digits are bytes, and small
    /// letters stand for things about the note.
    func MIDITranslate(_ hc: IT2HostPointer, _ sc: IT2SlavePointer?, _ Input: UInt16) {
        if Input >= 0xF000 { return }
        if Int(Input) / 32 >= 9 + 16 + 128 { return }
        var Input = Int(Input)
        var MIDIData: UInt8 = 0
        var CharsParsed: UInt8 = 0

        func digit(_ value: UInt8) {
            MIDIData = (MIDIData << 4) | value
            CharsParsed += 1
            if CharsParsed >= 2 {
                MIDISendFilter(hc, sc, MIDIData)
                CharsParsed = 0
                MIDIData = 0
            }
        }

        while true {
            var Byte = Input < MIDIDataArea.count ? Int(MIDIDataArea[Input]) : 0
            Input += 1
            if Byte == 0 {
                if CharsParsed > 0 { MIDISendFilter(hc, sc, MIDIData) }
                break
            }
            if Byte == 0x20 {
                if CharsParsed > 0 { MIDISendFilter(hc, sc, MIDIData) }
                continue
            }
            Byte -= 0x30 // '0'
            if Byte < 0 { continue }
            if Byte <= 9 {
                digit(UInt8(Byte))
                continue
            }
            Byte -= 0x41 - 0x30 // 'A'
            if Byte < 0 { continue }
            if Byte <= 5 {
                digit(UInt8(Byte + 10))
                continue
            }
            Byte -= 0x61 - 0x41 // 'a'
            if Byte < 0 { continue }
            if Byte > 25 { continue }
            if Byte == 2 { // c: the MIDI channel
                guard let sc else { continue }
                digit(sc.pointee.MIDIChn &- 1)
                continue
            }
            if CharsParsed > 0 {
                MIDISendFilter(hc, sc, MIDIData)
                MIDIData = 0
            }
            if Byte == 25 { // z: the effect's value
                MIDISendFilter(hc, sc, hc.pointee.CmdVal)
            } else if Byte == 14 { // o: the sample offset
                MIDISendFilter(hc, sc, hc.pointee.EfxMem_O)
            } else if let sc {
                switch Byte {
                case 13: MIDISendFilter(hc, sc, sc.pointee.Note) // n
                case 12: MIDISendFilter(hc, sc, sc.pointee.LoopDirection) // m
                case 21: // v: velocity
                    if sc.pointee.Flags & SF_CHN_MUTED != 0 {
                        MIDISendFilter(hc, sc, 0)
                    } else {
                        let volume = UInt16(truncatingIfNeeded: (Int(sc.pointee.VolSet) * Int(GlobalVolume) * Int(sc.pointee.ChnVol)) >> 4)
                        var value = UInt8(truncatingIfNeeded: (Int(volume) * Int(sc.pointee.SmpVol)) >> 15)
                        if value == 0 { value = 1 } else if value >= 128 { value -= 1 }
                        MIDISendFilter(hc, sc, value)
                    }
                case 20: // u: volume
                    if sc.pointee.Flags & SF_CHN_MUTED != 0 {
                        MIDISendFilter(hc, sc, 0)
                    } else {
                        var value = sc.pointee.FinalVol128
                        if value == 0 { value = 1 } else if value >= 128 { value -= 1 }
                        MIDISendFilter(hc, sc, value)
                    }
                case 7: MIDISendFilter(hc, sc, sc.pointee.HostChnNum & 0x7F) // h
                case 23: // x: the place between the speakers
                    var value = sc.pointee.Pan &* 2
                    if value >= 128 { value -= 1 }
                    if value >= 128 { value = 64 }
                    MIDISendFilter(hc, sc, value)
                case 15: MIDISendFilter(hc, sc, sc.pointee.MIDIProg) // p
                case 1: MIDISendFilter(hc, sc, UInt8(sc.pointee.MIDIBank & 0xFF)) // b
                case 0: MIDISendFilter(hc, sc, UInt8(sc.pointee.MIDIBank >> 8)) // a
                default: break
                }
            }
            MIDIData = 0
            CharsParsed = 0
        }
    }

    func InitPlayInstrument(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ ins: IT2Instrument) {
        sc.pointee.InsPtr = ins
        sc.pointee.NNA = ins.NNA
        sc.pointee.DCT = ins.DCT
        sc.pointee.DCA = ins.DCA
        if hc.pointee.MIDIChn != 0 {
            sc.pointee.MIDIChn = ins.MIDIChn
            sc.pointee.MIDIProg = ins.MIDIProg
            sc.pointee.MIDIBank = ins.MIDIBank
            sc.pointee.LoopDirection = hc.pointee.RawNote // for a MIDI note this is the note
        }
        sc.pointee.ChnVol = hc.pointee.ChnVol

        var pan = ins.DefPan & 0x80 != 0 ? hc.pointee.ChnPan : ins.DefPan
        if hc.pointee.Smp != 0, let s = module.sample(Int(hc.pointee.Smp) - 1), s.DefPan & 0x80 != 0 { pan = s.DefPan & 127 }
        if pan != PAN_SURROUND {
            // Higher notes further to one side, if the instrument says so.
            let newPan = Int(pan) + ((Int(Int8(bitPattern: hc.pointee.RawNote &- ins.PitchPanCenter)) * Int(Int8(bitPattern: ins.PitchPanSep))) >> 3)
            pan = UInt8(max(0, min(64, newPan)))
        }
        sc.pointee.Pan = pan
        sc.pointee.PanSet = pan

        sc.pointee.VolEnvState.Value = 64 << 16
        sc.pointee.VolEnvState.Tick = 0
        sc.pointee.VolEnvState.NextTick = 0
        sc.pointee.VolEnvState.CurNode = 0
        sc.pointee.PanEnvState.Value = 0
        sc.pointee.PanEnvState.Tick = 0
        sc.pointee.PanEnvState.NextTick = 0
        sc.pointee.PanEnvState.CurNode = 0
        sc.pointee.PitchEnvState.Value = 0
        sc.pointee.PitchEnvState.Tick = 0
        sc.pointee.PitchEnvState.NextTick = 0
        sc.pointee.PitchEnvState.CurNode = 0

        sc.pointee.Flags = SF_CHAN_ON + SF_RECALC_PAN + SF_RECALC_VOL + SF_FREQ_CHANGE + SF_NEW_NOTE
        if ins.VolEnv.Flags & ENVF_ENABLED != 0 { sc.pointee.Flags |= SF_VOLENV_ON }
        if ins.PanEnv.Flags & ENVF_ENABLED != 0 { sc.pointee.Flags |= SF_PANENV_ON }
        if ins.PitchEnv.Flags & ENVF_ENABLED != 0 { sc.pointee.Flags |= SF_PITCHENV_ON }

        if let lastSC = LastSlaveChannel {
            // An envelope that carries on from the note before.
            if ins.VolEnv.Flags & (ENVF_ENABLED | ENVF_CARRY) == ENVF_ENABLED + ENVF_CARRY { sc.pointee.VolEnvState = lastSC.pointee.VolEnvState }
            if ins.PanEnv.Flags & (ENVF_ENABLED | ENVF_CARRY) == ENVF_ENABLED + ENVF_CARRY { sc.pointee.PanEnvState = lastSC.pointee.PanEnvState }
            if ins.PitchEnv.Flags & (ENVF_ENABLED | ENVF_CARRY) == ENVF_ENABLED + ENVF_CARRY { sc.pointee.PitchEnvState = lastSC.pointee.PitchEnvState }
        }

        hc.pointee.Flags |= HF_APPLY_RANDOM_VOL

        if hc.pointee.MIDIChn == 0 {
            sc.pointee.MIDIBank = 0x00FF // the filter wide open and without resonance
            if ins.FilterCutoff & 0x80 != 0 { SetFilterCutoff(hc, sc, ins.FilterCutoff & 0x7F) }
            if ins.FilterResonance & 0x80 != 0 {
                let filterQ = ins.FilterResonance & 0x7F
                sc.pointee.MIDIBank = (UInt16(filterQ) << 8) | (sc.pointee.MIDIBank & 0x00FF)
                SetFilterResonance(hc, sc, filterQ)
            }
        }
    }

    /// A voice for a note of a tune that has samples and no instruments: each channel has its own.
    private func AllocateChannelSample(_ hc: IT2HostPointer, _ hcFlags: inout UInt8) -> IT2SlavePointer? {
        let sc = sChn + Int(hc.pointee.HostChnNum)
        if sc.pointee.Flags & SF_CHAN_ON != 0 {
            // The note that was playing is moved aside, to be ramped down out of the way.
            sc.pointee.Flags |= SF_NOTE_STOP
            sc.pointee.HostChnNum |= CHN_DISOWNED
            (sc + MAX_HOST_CHANNELS).pointee = sc.pointee
        }
        hc.pointee.SlaveChnPtr = sc
        sc.pointee.HostChnPtr = hc
        sc.pointee.HostChnNum = hc.pointee.HostChnNum
        sc.pointee.ChnVol = hc.pointee.ChnVol
        sc.pointee.Pan = hc.pointee.ChnPan
        sc.pointee.PanSet = hc.pointee.ChnPan
        sc.pointee.FadeOut = 1024
        sc.pointee.VolEnvState.Value = (64 << 16) | (sc.pointee.VolEnvState.Value & 0xFFFF)
        sc.pointee.MIDIBank = 0x00FF
        sc.pointee.Note = hc.pointee.RawNote
        sc.pointee.Ins = hc.pointee.Ins
        sc.pointee.Flags = SF_CHAN_ON + SF_RECALC_PAN + SF_RECALC_VOL + SF_FREQ_CHANGE + SF_NEW_NOTE

        guard hc.pointee.Smp > 0 else {
            sc.pointee.Flags = SF_NOTE_STOP
            hcFlags &= ~UInt8(HF_CHAN_ON)
            return nil
        }
        sc.pointee.Smp = hc.pointee.Smp - 1
        let s = module.sample(Int(sc.pointee.Smp))
        sc.pointee.SmpPtr = s
        sc.pointee.SmpIs16Bit = false
        sc.pointee.AutoVibratoDepth = 0
        sc.pointee.AutoVibratoPos = 0
        sc.pointee.PanEnvState.Value &= 0xFFFF
        sc.pointee.PitchEnvState.Value &= 0xFFFF
        sc.pointee.LoopDirection = DIR_FORWARDS
        guard let s, s.Length != 0, s.Flags & SMPF_ASSOCIATED_WITH_HEADER != 0 else {
            sc.pointee.Flags = SF_NOTE_STOP
            hcFlags &= ~UInt8(HF_CHAN_ON)
            return nil
        }
        sc.pointee.SmpIs16Bit = s.Flags & SMPF_16BIT != 0
        sc.pointee.SmpVol = s.GlobVol &* 2
        return sc
    }

    private func AllocateChannelInstrument(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ ins: IT2Instrument, _ hcFlags: inout UInt8) -> IT2SlavePointer? {
        hc.pointee.SlaveChnPtr = sc
        sc.pointee.HostChnNum = hc.pointee.HostChnNum
        sc.pointee.HostChnPtr = hc
        sc.pointee.SmpIs16Bit = false
        sc.pointee.AutoVibratoDepth = 0
        sc.pointee.AutoVibratoPos = 0
        sc.pointee.LoopDirection = DIR_FORWARDS

        InitPlayInstrument(hc, sc, ins)

        sc.pointee.SmpVol = ins.GlobVol
        sc.pointee.FadeOut = 1024
        sc.pointee.Note = hc.pointee.Smp == midiSample ? hc.pointee.TranslatedNote : hc.pointee.RawNote
        sc.pointee.Ins = hc.pointee.Ins

        guard hc.pointee.Smp != 0 else {
            sc.pointee.Flags = SF_NOTE_STOP
            hcFlags &= ~UInt8(HF_CHAN_ON)
            return nil
        }
        sc.pointee.Smp = hc.pointee.Smp - 1
        let s = module.sample(Int(sc.pointee.Smp))
        sc.pointee.SmpPtr = s
        guard let s, s.Length != 0, s.Flags & SMPF_ASSOCIATED_WITH_HEADER != 0 else {
            sc.pointee.Flags = SF_NOTE_STOP
            hcFlags &= ~UInt8(HF_CHAN_ON)
            return nil
        }
        sc.pointee.SmpIs16Bit = s.Flags & SMPF_16BIT != 0
        sc.pointee.SmpVol = UInt8(truncatingIfNeeded: (Int(s.GlobVol) * Int(sc.pointee.SmpVol)) >> 6)
        return sc
    }

    /// Looks among the voices for a note that the new one is to take the place of: the same note,
    /// sample or instrument on the same channel, as the instrument asks. Leaves `sc` at the voice
    /// it stopped on.
    private func DuplicateCheck(_ sc: inout IT2SlavePointer, _ hc: IT2HostPointer, _ hostChnNum: UInt8, _ ins: IT2Instrument, _ DCT: UInt8, _ DCVal: UInt8) -> Bool {
        for i in 0 ..< NumChannels {
            sc = sChn + i
            if sc.pointee.Flags & SF_CHAN_ON == 0 || (hc.pointee.Smp != midiSample && sc.pointee.HostChnNum != hostChnNum) || sc.pointee.Ins != hc.pointee.Ins { continue }
            if DCT == DCT_NOTE, sc.pointee.Note != DCVal { continue }
            if DCT == DCT_SAMPLE, sc.pointee.Smp != DCVal { continue }
            if DCT == DCT_INSTRUMENT, sc.pointee.Ins != DCVal { continue }
            if hc.pointee.Smp == midiSample {
                if sc.pointee.Smp == midiVoiceSample, sc.pointee.MIDIChn == hostChnNum {
                    sc.pointee.Flags |= SF_NOTE_STOP
                    if sc.pointee.HostChnNum & CHN_DISOWNED == 0 {
                        sc.pointee.HostChnNum |= CHN_DISOWNED
                        sc.pointee.HostChnPtr?.pointee.Flags &= ~HF_CHAN_ON
                    }
                }
            } else if sc.pointee.DCA == ins.DCA {
                return true
            }
        }
        return false
    }

    /// Finds a voice for a channel's new note, doing to the note it was playing what its instrument
    /// says is to be done, and taking a voice from another note if none is free.
    func AllocateChannel(_ hc: IT2HostPointer, _ hcFlags: inout UInt8) -> IT2SlavePointer? {
        LastSlaveChannel = nil
        if module.Flags & ITF_INSTR_MODE == 0 || hc.pointee.Ins == 255 { return AllocateChannelSample(hc, &hcFlags) }
        if hc.pointee.Ins == 0 { return nil }
        let ins = module.instrument(Int(hc.pointee.Ins) - 1)

        var NNA: UInt8 = 0
        var sc = sChn
        var scInitialized = false
        if hcFlags & UInt8(HF_CHAN_ON) != 0, let playing = hc.pointee.SlaveChnPtr {
            sc = playing
            if sc.pointee.InsPtr === ins { LastSlaveChannel = sc }
            NNA = sc.pointee.NNA
            if NNA != NNA_NOTE_CUT { sc.pointee.HostChnNum |= CHN_DISOWNED }
            scInitialized = true
        }

        while true { // what becomes of the old note
            if scInitialized {
                if NNA != NNA_NOTE_CUT, sc.pointee.VolSet > 0, sc.pointee.ChnVol > 0, sc.pointee.SmpVol > 0 {
                    if NNA == NNA_NOTE_OFF {
                        sc.pointee.Flags |= SF_NOTE_OFF
                        GetLoopInformation(sc)
                    } else if NNA >= NNA_NOTE_FADE {
                        sc.pointee.Flags |= SF_FADEOUT
                    }
                } else {
                    // It is cut (or was silent anyway).
                    if sc.pointee.Smp == midiVoiceSample {
                        sc.pointee.Flags |= SF_NOTE_STOP
                        sc.pointee.HostChnNum |= CHN_DISOWNED
                        if hc.pointee.Smp != midiSample { break }
                    } else {
                        // Its voice ramps down while another is found for the new note.
                        sc.pointee.Flags |= SF_NOTE_STOP
                        sc.pointee.HostChnNum |= CHN_DISOWNED
                        break
                    }
                }
            }

            var hostChnNum: UInt8 = 0, DCT: UInt8 = 0, DCVal: UInt8 = 0
            var doDupeCheck = false
            if hc.pointee.Smp == midiSample {
                hostChnNum = hc.pointee.MIDIChn
                DCT = DCT_NOTE
                DCVal = hc.pointee.TranslatedNote
                doDupeCheck = true
            } else if ins.DCT != DCT_DISABLED {
                hostChnNum = hc.pointee.HostChnNum | CHN_DISOWNED // only among those the channel has let go
                DCT = ins.DCT
                if ins.DCT == DCT_NOTE {
                    DCVal = hc.pointee.RawNote
                } else if ins.DCT == DCT_INSTRUMENT {
                    DCVal = hc.pointee.Ins
                } else {
                    DCVal = hc.pointee.Smp &- 1
                    // No sample, or none that Impulse Tracker could have: no such check. (A file with
                    // more samples than Impulse Tracker has room for has them up to 253.)
                    if hc.pointee.Smp == 0 || (sampleLimit <= IT2Module.MAX_SAMPLES && Int8(bitPattern: DCVal) < 0) { break }
                }
                doDupeCheck = true
            }

            if doDupeCheck {
                sc = sChn
                if DuplicateCheck(&sc, hc, hostChnNum, ins, DCT, DCVal) {
                    scInitialized = true
                    if ins.DCA == DCA_NOTE_CUT {
                        NNA = NNA_NOTE_CUT
                    } else {
                        sc.pointee.DCT = DCT_DISABLED
                        sc.pointee.DCA = DCA_NOTE_CUT
                        NNA = ins.DCA + 1
                    }
                    continue
                }
            }
            break
        }

        // A voice that is not sounding.
        if hc.pointee.Smp != midiSample {
            for i in 0 ..< NumChannels where sChn[i].Flags & SF_CHAN_ON == 0 { return AllocateChannelInstrument(hc, sChn + i, ins, &hcFlags) }
        } else {
            for i in 0 ..< NumChannels where sChn[i].Flags & SF_CHAN_ON == 0 {
                let hcTmp = sChn[i].HostChnPtr
                if hcTmp == nil || hcTmp?.pointee.SlaveChnPtr != sChn + i { return AllocateChannelInstrument(hc, sChn + i, ins, &hcFlags) }
            }
        }

        // None: the quietest let-go voice of the sample that has the most voices, if one has more than two.
        for i in 0 ..< sampleLimit {
            ChannelCountTable[i] = 0
            ChannelVolumeTable[i] = 255
            ChannelLocationTable[i] = nil
        }
        for i in 0 ..< NumChannels {
            let smp = Int(sChn[i].Smp)
            if smp >= sampleLimit { continue }
            ChannelCountTable[smp] &+= 1
            if sChn[i].HostChnNum & CHN_DISOWNED != 0, sChn[i].FinalVol128 < ChannelVolumeTable[smp] {
                ChannelLocationTable[smp] = sChn + i
                ChannelVolumeTable[smp] = sChn[i].FinalVol128
            }
        }
        var found: IT2SlavePointer?
        var count: UInt8 = 2
        for i in 0 ..< sampleLimit where ChannelCountTable[i] > count {
            count = ChannelCountTable[i]
            found = ChannelLocationTable[i]
        }
        if let found { return AllocateChannelInstrument(hc, found, ins, &hcFlags) }

        // Or from the channel that has let go of the most voices, the quietest whose sample is
        // playing somewhere else as well.
        for i in 0 ..< MAX_HOST_CHANNELS { ChannelCountTable[i] = 0 }
        for i in 0 ..< NumChannels { ChannelCountTable[Int(sChn[i].HostChnNum & 63)] &+= 1 }
        var lowestVol: UInt8
        while true {
            var hostChnNum: UInt8 = 0
            count = 1
            for i in 0 ..< MAX_HOST_CHANNELS where ChannelCountTable[i] > count {
                count = ChannelCountTable[i]
                hostChnNum = UInt8(i)
            }
            if count <= 1 {
                // Or the quietest let-go voice of all.
                found = nil
                lowestVol = 255
                for i in 0 ..< NumChannels where sChn[i].HostChnNum & CHN_DISOWNED != 0 && sChn[i].FinalVol128 <= lowestVol {
                    found = sChn + i
                    lowestVol = sChn[i].FinalVol128
                }
                guard let found else {
                    hcFlags &= ~UInt8(HF_CHAN_ON)
                    return nil
                }
                return AllocateChannelInstrument(hc, found, ins, &hcFlags)
            }

            hostChnNum |= CHN_DISOWNED
            found = nil
            lowestVol = 255
            let targetSmp = hc.pointee.Smp &- 1
            for i in 0 ..< NumChannels {
                let scTmp = sChn + i
                if scTmp.pointee.HostChnNum != hostChnNum || scTmp.pointee.FinalVol128 >= lowestVol { continue }
                if scTmp.pointee.Smp == targetSmp {
                    found = scTmp
                    lowestVol = scTmp.pointee.FinalVol128
                    continue
                }
                let scSmp = scTmp.pointee.Smp
                scTmp.pointee.Smp = 255
                for j in 0 ..< NumChannels where sChn[j].Smp == targetSmp || sChn[j].Smp == scSmp {
                    found = scTmp
                    lowestVol = scTmp.pointee.FinalVol128
                    break
                }
                scTmp.pointee.Smp = scSmp
            }
            if found != nil { break }
            ChannelCountTable[Int(hostChnNum & 63)] = 0
        }

        guard var target = found else { return nil }
        lowestVol = 255
        for i in 0 ..< NumChannels where sChn[i].Smp == target.pointee.Smp && sChn[i].HostChnNum & CHN_DISOWNED != 0 && sChn[i].FinalVol128 < lowestVol {
            target = sChn + i
            lowestVol = sChn[i].FinalVol128
        }
        return AllocateChannelInstrument(hc, target, ins, &hcFlags)
    }

    /// Impulse Tracker's random numbers.
    func Random() -> UInt8 {
        var r1 = RandSeed1
        var r2 = RandSeed2, r3 = RandSeed2, r4 = RandSeed2
        r1 &+= r2
        r1 = (r1 << (r3 & 15)) | (r1 >> ((16 &- r3) & 15))
        r1 ^= r4
        r3 = (r3 >> 8) | (r3 << 8)
        r2 &+= r3
        r4 &+= r2
        r3 &+= r1
        r1 &-= r4 &+ (r2 & 1)
        r2 = (r2 << 15) | (r2 >> 1)
        RandSeed2 = r4
        RandSeed1 = r1
        return UInt8(truncatingIfNeeded: r1)
    }

    /// Which loop a voice's sample is in now: its loop, the loop it holds while its key is down, or none.
    func GetLoopInformation(_ sc: IT2SlavePointer) {
        guard let s = sc.pointee.SmpPtr else { return }
        var LoopMode: UInt8
        var LoopBegin: Int32, LoopEnd: Int32
        let LoopEnabled = s.Flags & (SMPF_USE_LOOP | SMPF_USE_SUSTAINLOOP) != 0
        let SustainLoopOnlyAndNoteOff = s.Flags & SMPF_USE_SUSTAINLOOP != 0 && sc.pointee.Flags & SF_NOTE_OFF != 0 && s.Flags & SMPF_USE_LOOP == 0
        if !LoopEnabled || SustainLoopOnlyAndNoteOff {
            LoopBegin = 0
            LoopEnd = Int32(truncatingIfNeeded: s.Length)
            LoopMode = 0
        } else {
            LoopBegin = Int32(truncatingIfNeeded: s.LoopBegin)
            LoopEnd = Int32(truncatingIfNeeded: s.LoopEnd)
            LoopMode = s.Flags
            if s.Flags & SMPF_USE_SUSTAINLOOP != 0, sc.pointee.Flags & SF_NOTE_OFF == 0 {
                LoopBegin = Int32(truncatingIfNeeded: s.SustainLoopBegin)
                LoopEnd = Int32(truncatingIfNeeded: s.SustainLoopEnd)
                LoopMode >>= 1
            }
            LoopMode = LoopMode & SMPF_LOOP_PINGPONG != 0 ? LOOP_PINGPONG : LOOP_FORWARDS
        }
        if sc.pointee.LoopMode != LoopMode || sc.pointee.LoopBegin != LoopBegin || sc.pointee.LoopEnd != LoopEnd {
            sc.pointee.LoopMode = LoopMode
            sc.pointee.LoopBegin = LoopBegin
            sc.pointee.LoopEnd = LoopEnd
            sc.pointee.Flags |= SF_LOOP_CHANGED
            if sc.pointee.SamplingPosition < sc.pointee.LoopBegin { sc.pointee.HasLooped = false }
        }
    }

    func ApplyRandomValues(_ hc: IT2HostPointer) {
        guard let sc = hc.pointee.SlaveChnPtr, let ins = sc.pointee.InsPtr else { return }
        hc.pointee.Flags &= ~HF_APPLY_RANDOM_VOL
        var value = Int(Int8(bitPattern: Random()))
        if ins.RandVol != 0 {
            var vol = ((Int(Int8(bitPattern: ins.RandVol)) * value) >> 6) + 1
            vol = Int(sc.pointee.SmpVol) + Int(Int16(truncatingIfNeeded: vol * Int(sc.pointee.SmpVol))) / 199
            sc.pointee.SmpVol = UInt8(max(0, min(128, vol)))
        }
        value = Int(Int8(bitPattern: Random()))
        if ins.RandPan != 0, sc.pointee.Pan != PAN_SURROUND {
            let pan = Int(sc.pointee.Pan) + ((Int(Int8(bitPattern: ins.RandPan)) * value) >> 7)
            sc.pointee.Pan = UInt8(max(0, min(64, pan)))
            sc.pointee.PanSet = sc.pointee.Pan
        }
    }

    // MARK: Slides of pitch, in whole numbers as Impulse Tracker had them before its version 2.15

    func PitchSlideUp(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ SlideValue: Int16) {
        if module.Flags & ITF_LINEAR_FRQ != 0 {
            PitchSlideUpLinear(hc, sc, SlideValue)
            return
        }
        // The Amiga's way: by periods.
        sc.pointee.Flags |= SF_FREQ_CHANGE
        let PeriodBase: UInt32 = 1712 * 8363
        func stop() {
            sc.pointee.Flags |= SF_NOTE_STOP
            hc.pointee.Flags &= ~HF_CHAN_ON
        }
        // (Widened with its sign, as the original widens it.)
        let Frequency = UInt64(bitPattern: Int64(sc.pointee.Frequency))
        if SlideValue < 0 {
            var FreqSlide64 = Frequency &* UInt64(UInt32(-Int32(SlideValue)))
            if FreqSlide64 > UInt64(UInt32.max) { return stop() }
            FreqSlide64 += UInt64(PeriodBase)
            var ShiftValue: UInt64 = 0
            while FreqSlide64 > UInt64(UInt32.max) {
                FreqSlide64 >>= 1
                ShiftValue += 1
            }
            let Temp32 = UInt32(FreqSlide64)
            var Temp64 = Frequency &* UInt64(PeriodBase)
            if ShiftValue > 0 { Temp64 >>= ShiftValue }
            if UInt64(Temp32) <= Temp64 >> 32 { return stop() }
            sc.pointee.Frequency = Int32(bitPattern: UInt32(truncatingIfNeeded: Temp64 / UInt64(Temp32)))
        } else {
            let FreqSlide64 = Frequency &* UInt64(UInt32(SlideValue))
            if FreqSlide64 > UInt64(UInt32.max) { return stop() }
            let Temp32 = PeriodBase &- UInt32(FreqSlide64)
            if Int32(bitPattern: Temp32) <= 0 { return stop() }
            let Temp64 = Frequency &* UInt64(PeriodBase)
            if UInt64(Temp32) <= Temp64 >> 32 { return stop() }
            sc.pointee.Frequency = Int32(bitPattern: UInt32(truncatingIfNeeded: Temp64 / UInt64(Temp32)))
        }
    }

    func PitchSlideUpLinear(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ SlideValue: Int16) {
        sc.pointee.Flags |= SF_FREQ_CHANGE
        var SlideValue = Int(SlideValue)
        // (Widened with its sign, as the original widens it.)
        let Frequency = UInt64(bitPattern: Int64(sc.pointee.Frequency))
        if SlideValue < 0 {
            SlideValue = -SlideValue
            let factor: UInt64
            if SlideValue <= 15 {
                factor = UInt64(it2FineLinearSlideDownTable[SlideValue])
            } else {
                factor = UInt64(it2LinearSlideDownTable[min(256, SlideValue >> 2)])
            }
            sc.pointee.Frequency = Int32(bitPattern: UInt32(truncatingIfNeeded: (Frequency &* factor) >> 16))
        } else {
            let factor: UInt64
            if SlideValue <= 15 {
                factor = UInt64(it2FineLinearSlideUpTable[SlideValue])
            } else {
                factor = UInt64(it2LinearSlideUpTable[min(256, SlideValue >> 2)])
            }
            let slid = (Frequency &* factor) >> 16
            if slid & 0xFFFF_0000_0000_0000 != 0 {
                sc.pointee.Flags |= SF_NOTE_STOP
                hc.pointee.Flags &= ~HF_CHAN_ON
            } else {
                sc.pointee.Frequency = Int32(bitPattern: UInt32(truncatingIfNeeded: slid))
            }
        }
    }

    func PitchSlideDown(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ SlideValue: Int16) {
        PitchSlideUp(hc, sc, 0 &- SlideValue)
    }

    // MARK: Reading patterns

    /// The next byte of the pattern being played; nought beyond its end.
    @inline(__always) private func patternByte() -> UInt8 {
        let byte = PatternOffset < PatternData.count ? PatternData[PatternOffset] : 0
        PatternOffset += 1
        return byte
    }

    private func PreInitCommand(_ hc: IT2HostPointer) {
        if hc.pointee.NotePackMask & 0x33 != 0 {
            if module.Flags & ITF_INSTR_MODE == 0 || hc.pointee.RawNote >= 120 || hc.pointee.Ins == 0 {
                hc.pointee.TranslatedNote = hc.pointee.RawNote
                hc.pointee.Smp = hc.pointee.Ins
            } else {
                let ins = module.instrument(Int(hc.pointee.Ins) - 1)
                let entry = ins.SmpNoteTable[Int(hc.pointee.RawNote)]
                hc.pointee.TranslatedNote = UInt8(entry & 0xFF)
                // (Over 128 is a plug-in of ModPlug Tracker's, not a MIDI channel.)
                if ins.MIDIChn == 0 || ins.MIDIChn > 128 {
                    hc.pointee.Smp = UInt8(entry >> 8)
                } else {
                    hc.pointee.MIDIChn = ins.MIDIChn == 17 ? (hc.pointee.HostChnNum & 0x0F) + 1 : ins.MIDIChn
                    hc.pointee.MIDIProg = ins.MIDIProg
                    hc.pointee.Smp = midiSample
                }
                if hc.pointee.Smp == 0 { return }
            }
        }

        InitCommand(hc)

        hc.pointee.Flags |= HF_ROW_UPDATED
        let ChannelMuted = module.ChnlPan[Int(hc.pointee.HostChnNum)] & 128 != 0
        if ChannelMuted, hc.pointee.Flags & HF_FREEPLAY_NOTE == 0, hc.pointee.Flags & HF_CHAN_ON != 0 {
            hc.pointee.SlaveChnPtr?.pointee.Flags |= SF_CHN_MUTED
        }
    }

    /// Reads a row's worth of what each channel is told into `hc`, and says which channel.
    @inline(__always) private func readChannel(_ chnNum: UInt8, command: Bool) -> IT2HostPointer {
        let hc = hChn + ((Int(chnNum & 0x7F) - 1) & 63)
        if chnNum & 0x80 != 0 { hc.pointee.NotePackMask = patternByte() }
        if hc.pointee.NotePackMask & 1 != 0 { hc.pointee.RawNote = patternByte() }
        if hc.pointee.NotePackMask & 2 != 0 { hc.pointee.Ins = patternByte() }
        if hc.pointee.NotePackMask & 4 != 0 { hc.pointee.RawVolColumn = patternByte() }
        if hc.pointee.NotePackMask & 8 != 0 {
            hc.pointee.OldCmd = patternByte()
            hc.pointee.OldCmdVal = patternByte()
            if command {
                hc.pointee.Cmd = hc.pointee.OldCmd
                hc.pointee.CmdVal = hc.pointee.OldCmdVal
            }
        } else if command {
            if hc.pointee.NotePackMask & 128 != 0 {
                hc.pointee.Cmd = hc.pointee.OldCmd
                hc.pointee.CmdVal = hc.pointee.OldCmdVal
            } else {
                hc.pointee.Cmd = 0
                hc.pointee.CmdVal = 0
            }
        }
        return hc
    }

    /// Finds a row that is not the one after the last: the pattern is read from its top, since a
    /// row only says what has changed since the row before.
    private func UpdateGOTONote() {
        DecodeExpectedPattern = CurrentPattern
        let pattern = module.pattern(Int(CurrentPattern))
        PatternData = pattern.data
        NumberOfRows = pattern.rows
        PatternOffset = 0
        if ProcessRow >= NumberOfRows { ProcessRow = 0 }
        CurrentRow = ProcessRow
        DecodeExpectedRow = ProcessRow

        var rowsTodo = ProcessRow
        while rowsTodo > 0, PatternOffset < PatternData.count {
            let chnNum = patternByte()
            if chnNum == 0 {
                rowsTodo -= 1
                continue
            }
            _ = readChannel(chnNum, command: false)
        }
    }

    private func UpdateNoteData() {
        PatternLooping = false
        DecodeExpectedRow &+= 1
        if CurrentPattern != DecodeExpectedPattern || DecodeExpectedRow != CurrentRow { UpdateGOTONote() }
        rowIsRead()

        for i in 0 ..< MAX_HOST_CHANNELS {
            hChn[i].Flags &= ~(HF_UPDATE_EFX_IF_CHAN_ON | HF_ALWAYS_UPDATE_EFX | HF_ROW_UPDATED | HF_UPDATE_VOLEFX_IF_CHAN_ON)
        }
        while true {
            let chnNum = patternByte()
            if chnNum == 0 { break }
            let hc = readChannel(chnNum, command: true)
            if hc.pointee.NotePackMask & 1 != 0, hc.pointee.RawNote < 120 { playedNote = true }
            PreInitCommand(hc)
        }
    }

    /// One tick of the song.
    private func UpdateData() {
        ProcessTick &-= 1
        CurrentTick &-= 1
        if CurrentTick == 0 {
            ProcessTick = CurrentSpeed
            CurrentTick = CurrentSpeed
            RowDelay &-= 1
            if RowDelay == 0 {
                RowDelay = 1
                RowDelayOn = false
                var NewRow = ProcessRow &+ 1
                if NewRow >= NumberOfRows {
                    // The next place in the list that is a pattern.
                    var NewOrder = Int(ProcessOrder) + 1
                    var looked = 0
                    while true {
                        looked += 1
                        if NewOrder >= 256 {
                            NewOrder = 0
                            continue
                        }
                        let NewPattern = module.Orders[NewOrder]
                        if Int(NewPattern) >= module.patternLimit {
                            if NewPattern == 0xFE, looked < 1024 { // a mark between songs, passed over
                                NewOrder += 1
                            } else {
                                NewOrder = 0
                                StopSong = true
                                offTheEnd = true
                                if looked >= 1024 { // a list with no pattern in it
                                    CurrentPattern = 0
                                    break
                                }
                            }
                        } else {
                            CurrentPattern = UInt16(NewPattern)
                            break
                        }
                    }
                    CurrentOrder = UInt16(NewOrder)
                    ProcessOrder = UInt16(NewOrder)
                    NewRow = BreakRow
                    BreakRow = 0
                }
                CurrentRow = NewRow
                ProcessRow = NewRow
                UpdateNoteData()
            } else {
                // A row held up by a delay: its effects are started again.
                for i in 0 ..< MAX_HOST_CHANNELS {
                    let hc = hChn + i
                    if hc.pointee.Flags & HF_ROW_UPDATED == 0 || hc.pointee.NotePackMask & 0x88 == 0 { continue }
                    let OldNotePackMask = hc.pointee.NotePackMask
                    hc.pointee.NotePackMask &= 0x88
                    InitCommand(hc)
                    hc.pointee.NotePackMask = OldNotePackMask
                }
            }
        } else {
            for i in 0 ..< MAX_HOST_CHANNELS {
                let hc = hChn + i
                let flags = hc.pointee.Flags
                if flags & HF_CHAN_ON != 0, flags & HF_UPDATE_VOLEFX_IF_CHAN_ON != 0 { VolumeEffect(hc) }
                if flags & (HF_UPDATE_EFX_IF_CHAN_ON | HF_ALWAYS_UPDATE_EFX) != 0, hc.pointee.Flags & HF_ALWAYS_UPDATE_EFX != 0 || hc.pointee.Flags & HF_CHAN_ON != 0 {
                    Command(hc)
                }
            }
        }
    }

    /// The vibrato a sample has of its own.
    private func UpdateAutoVibrato(_ sc: IT2SlavePointer) {
        guard let smp = sc.pointee.SmpPtr, smp.AutoVibratoDepth != 0 else { return }
        sc.pointee.AutoVibratoDepth &+= UInt16(smp.AutoVibratoRate)
        if sc.pointee.AutoVibratoDepth >> 8 > UInt16(smp.AutoVibratoDepth) {
            sc.pointee.AutoVibratoDepth = (UInt16(smp.AutoVibratoDepth) << 8) | (sc.pointee.AutoVibratoDepth & 0xFF)
        }
        if smp.AutoVibratoSpeed == 0 { return }
        var VibratoData: Int
        if smp.AutoVibratoWaveform == 3 {
            VibratoData = Int(Random() & 127) - 64
        } else {
            sc.pointee.AutoVibratoPos &+= smp.AutoVibratoSpeed
            switch smp.AutoVibratoWaveform {
            case 0 ... 2:
                VibratoData = Int(it2FineSineData[(Int(smp.AutoVibratoWaveform) << 8) + Int(sc.pointee.AutoVibratoPos)])
            case 4:
                // Not one of Impulse Tracker's, which has three and would read past them: OpenMPT's
                // ramp upwards, which is the ramp downwards the other way round.
                VibratoData = Int(it2FineSineData[256 + 255 - Int(sc.pointee.AutoVibratoPos)])
            default:
                VibratoData = Int(it2FineSineData[Int(sc.pointee.AutoVibratoPos)])
            }
        }
        VibratoData = (VibratoData * Int(sc.pointee.AutoVibratoDepth >> 8)) >> 6
        if VibratoData != 0, let hc = sc.pointee.HostChnPtr { PitchSlideUpLinear(hc, sc, Int16(truncatingIfNeeded: VibratoData)) }
    }

    /// Moves an envelope on by a tick. True once it has run past its last point.
    private func UpdateEnvelope(_ env: borrowing IT2Envelope, _ envState: inout IT2EnvState, _ SustainReleased: Bool) -> Bool {
        if envState.Tick < envState.NextTick {
            envState.Tick &+= 1
            envState.Value &+= envState.Delta
            return false
        }
        func magnitude(_ node: Int) -> Int32 { node < 25 ? Int32(env.Magnitude[node]) : 0 }
        func tick(_ node: Int) -> Int16 { node < 25 ? Int16(bitPattern: env.Tick[node]) : 0 }
        let current = Int(envState.CurNode & 0x00FF)
        envState.Value = magnitude(current) << 16
        let NextNode = current + 1

        if env.Flags & (ENVF_LOOP | ENVF_SUSTAINLOOP) != 0 {
            var LoopBegin = env.LoopBegin, LoopEnd = env.LoopEnd
            var Looping = true
            if env.Flags & ENVF_SUSTAINLOOP != 0 {
                if !SustainReleased {
                    LoopBegin = env.SustainLoopBegin
                    LoopEnd = env.SustainLoopEnd
                } else if env.Flags & ENVF_LOOP == 0 {
                    Looping = false
                }
            }
            if Looping, NextNode > Int(LoopEnd) {
                envState.CurNode = (envState.CurNode & Int16(bitPattern: 0xFF00)) | Int16(LoopBegin)
                envState.Tick = tick(Int(LoopBegin))
                envState.NextTick = envState.Tick
                return false
            }
        }
        if NextNode >= Int(env.Num) { return true }

        envState.NextTick = tick(NextNode)
        envState.Tick = tick(current) &+ 1
        var TickDelta = envState.NextTick &- tick(current)
        if TickDelta == 0 { TickDelta = 1 }
        let Delta = magnitude(NextNode) - magnitude(current)
        envState.Delta = (Delta << 16) / Int32(TickDelta)
        envState.CurNode = (envState.CurNode & Int16(bitPattern: 0xFF00)) | Int16(UInt8(truncatingIfNeeded: NextNode))
        return false
    }

    // MARK: After the row: envelopes, fades, volumes and places

    private func UpdateInstruments() {
        for i in 0 ..< MAX_SLAVE_CHANNELS {
            let sc = sChn + i
            if sc.pointee.Flags & SF_CHAN_ON == 0 { continue }

            if sc.pointee.Ins != 0xFF, let ins = sc.pointee.InsPtr {
                let SustainReleased = sc.pointee.Flags & SF_NOTE_OFF != 0

                // The envelope that is for pitch, or for the filter.
                if sc.pointee.Flags & SF_PITCHENV_ON != 0, UpdateEnvelope(ins.PitchEnv, &sc.pointee.PitchEnvState, SustainReleased) {
                    sc.pointee.Flags &= ~SF_PITCHENV_ON
                }
                if ins.PitchEnv.Flags & ENVF_TYPE_FILTER == 0 {
                    let EnvVal = Int16(truncatingIfNeeded: UInt32(bitPattern: sc.pointee.PitchEnvState.Value) >> 8) >> 3
                    if EnvVal != 0, let hc = sc.pointee.HostChnPtr {
                        PitchSlideUpLinear(hc, sc, EnvVal)
                        sc.pointee.Flags |= SF_FREQ_CHANGE
                    }
                } else if sc.pointee.Smp != midiVoiceSample {
                    var EnvVal = Int16(truncatingIfNeeded: UInt32(bitPattern: sc.pointee.PitchEnvState.Value) >> 8) >> 6
                    // To 0...255, as the original's arithmetic has it.
                    EnvVal &+= 128
                    if UInt16(bitPattern: EnvVal) & 0xFF00 != 0 { EnvVal &-= 1 }
                    sc.pointee.MIDIBank = (sc.pointee.MIDIBank & 0xFF00) | UInt16(UInt8(truncatingIfNeeded: EnvVal))
                    sc.pointee.Flags |= SF_UPDATE_MIXERVOL
                }

                if sc.pointee.Flags & SF_PANENV_ON != 0 {
                    sc.pointee.Flags |= SF_RECALC_PAN
                    if UpdateEnvelope(ins.PanEnv, &sc.pointee.PanEnvState, SustainReleased) { sc.pointee.Flags &= ~SF_PANENV_ON }
                }

                var HandleNoteFade = false, TurnOffCh = false
                if sc.pointee.Flags & SF_VOLENV_ON != 0 {
                    sc.pointee.Flags |= SF_RECALC_VOL
                    if UpdateEnvelope(ins.VolEnv, &sc.pointee.VolEnvState, SustainReleased) {
                        // The envelope is over: at nothing the note is too, and otherwise it fades.
                        sc.pointee.Flags &= ~SF_VOLENV_ON
                        if sc.pointee.VolEnvState.Value & 0x00FF_0000 == 0 {
                            TurnOffCh = true
                        } else {
                            sc.pointee.Flags |= SF_FADEOUT
                            HandleNoteFade = true
                        }
                    } else if sc.pointee.Flags & SF_FADEOUT == 0 {
                        // A key let go while the envelope loops: the note fades.
                        if SustainReleased, ins.VolEnv.Flags & ENVF_LOOP != 0 {
                            sc.pointee.Flags |= SF_FADEOUT
                            HandleNoteFade = true
                        }
                    } else {
                        HandleNoteFade = true
                    }
                } else if sc.pointee.Flags & SF_FADEOUT != 0 {
                    HandleNoteFade = true
                } else if sc.pointee.Flags & SF_NOTE_OFF != 0 {
                    sc.pointee.Flags |= SF_FADEOUT
                    HandleNoteFade = true
                }

                if HandleNoteFade {
                    sc.pointee.FadeOut &-= ins.FadeOut
                    if Int16(bitPattern: sc.pointee.FadeOut) <= 0 {
                        sc.pointee.FadeOut = 0
                        TurnOffCh = true
                    }
                    sc.pointee.Flags |= SF_RECALC_VOL
                }
                if TurnOffCh {
                    if sc.pointee.HostChnNum & CHN_DISOWNED == 0 {
                        sc.pointee.HostChnNum |= CHN_DISOWNED
                        sc.pointee.HostChnPtr?.pointee.Flags &= ~HF_CHAN_ON
                    }
                    sc.pointee.Flags |= SF_RECALC_VOL | SF_NOTE_STOP
                }
            }

            if sc.pointee.Flags & SF_RECALC_VOL != 0 {
                sc.pointee.Flags &= ~SF_RECALC_VOL
                sc.pointee.Flags |= SF_UPDATE_MIXERVOL
                var volume = UInt16(truncatingIfNeeded: (Int(sc.pointee.Vol) * Int(sc.pointee.ChnVol) * Int(sc.pointee.FadeOut)) >> 7)
                volume = UInt16(truncatingIfNeeded: (Int(volume) * Int(sc.pointee.SmpVol)) >> 7)
                volume = UInt16(truncatingIfNeeded: (Int(volume) * Int(UInt16(truncatingIfNeeded: UInt32(bitPattern: sc.pointee.VolEnvState.Value) >> 8))) >> 14)
                volume = UInt16(truncatingIfNeeded: (Int(volume) * Int(GlobalVolume)) >> 7)
                sc.pointee.FinalVol32768 = volume
                sc.pointee.FinalVol128 = UInt8(truncatingIfNeeded: volume >> 8)
            }

            if sc.pointee.Flags & SF_RECALC_PAN != 0 {
                sc.pointee.Flags &= ~SF_RECALC_PAN
                sc.pointee.Flags |= SF_PAN_CHANGED
                if sc.pointee.Pan == PAN_SURROUND {
                    sc.pointee.FinalPan = sc.pointee.Pan
                } else {
                    // The envelope moves it by as much as there is room for on the nearer side.
                    var PanVal = Int8(truncatingIfNeeded: 32 - Int(sc.pointee.Pan))
                    if PanVal < 0 {
                        PanVal = Int8(truncatingIfNeeded: Int(PanVal) ^ 255)
                        PanVal = Int8(truncatingIfNeeded: Int(PanVal) - 255)
                    }
                    PanVal = Int8(truncatingIfNeeded: -Int(PanVal))
                    PanVal = Int8(truncatingIfNeeded: Int(PanVal) + 32)
                    let PanEnvVal = Int(Int8(truncatingIfNeeded: sc.pointee.PanEnvState.Value >> 16))
                    PanVal = Int8(truncatingIfNeeded: Int(sc.pointee.Pan) + ((Int(PanVal) * PanEnvVal) >> 5))
                    PanVal = Int8(truncatingIfNeeded: Int(PanVal) - 32)
                    sc.pointee.FinalPan = UInt8(truncatingIfNeeded: ((Int(PanVal) * Int(Int8(bitPattern: module.PanSep >> 1))) >> 6) + 32)
                }
            }
            UpdateAutoVibrato(sc)
        }
    }

    /// The same for a tune of samples without instruments: no envelopes and no fades.
    private func UpdateSamples() {
        for i in 0 ..< NumChannels {
            let sc = sChn + i
            if sc.pointee.Flags & SF_CHAN_ON == 0 { continue }
            if sc.pointee.Flags & SF_RECALC_VOL != 0 {
                sc.pointee.Flags &= ~SF_RECALC_VOL
                sc.pointee.Flags |= SF_UPDATE_MIXERVOL
                let volume = UInt16(truncatingIfNeeded: (((Int(sc.pointee.Vol) * Int(sc.pointee.ChnVol) * Int(sc.pointee.SmpVol)) >> 4) * Int(GlobalVolume)) >> 7)
                sc.pointee.FinalVol32768 = volume
                sc.pointee.FinalVol128 = UInt8(truncatingIfNeeded: volume >> 8)
            }
            if sc.pointee.Flags & SF_RECALC_PAN != 0 {
                sc.pointee.Flags &= ~SF_RECALC_PAN
                sc.pointee.Flags |= SF_PAN_CHANGED
                if sc.pointee.Pan == PAN_SURROUND {
                    sc.pointee.FinalPan = sc.pointee.Pan
                } else {
                    sc.pointee.FinalPan = UInt8(truncatingIfNeeded: (((Int(Int8(bitPattern: sc.pointee.Pan)) - 32) * Int(Int8(bitPattern: module.PanSep >> 1))) >> 6) + 32)
                }
            }
            UpdateAutoVibrato(sc)
        }
    }

    /// One tick: the song is moved on, and every voice's volume, place and pitch settled for the mixer.
    func Update() {
        cameRound = false
        for i in 0 ..< MAX_SLAVE_CHANNELS {
            let sc = sChn + i
            if sc.pointee.Flags & SF_CHAN_ON == 0 { continue }
            if sc.pointee.Vol != sc.pointee.VolSet {
                sc.pointee.Vol = sc.pointee.VolSet
                sc.pointee.Flags |= SF_RECALC_VOL
            }
            if sc.pointee.Frequency != sc.pointee.FrequencySet {
                sc.pointee.Frequency = sc.pointee.FrequencySet
                sc.pointee.Flags |= SF_FREQ_CHANGE
            }
        }
        UpdateData()
        if module.Flags & ITF_INSTR_MODE != 0 { UpdateInstruments() } else { UpdateSamples() }
    }

    // MARK: Starting

    /// - Parameters:
    ///   - order: where in the list of patterns to start.
    ///   - firstPlayedBy: for a file of several songs, which of them first played each row.
    ///   - songNumber: which of them this is.
    init(_ module: IT2Module, order: Int = 0, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil, songNumber: UInt8 = 0) {
        self.module = module
        midiSample = module.midiSample
        midiVoiceSample = module.midiVoiceSample
        sampleLimit = module.sampleLimit
        self.firstPlayedBy = firstPlayedBy
        self.songNumber = songNumber
        hChn = .allocate(capacity: MAX_HOST_CHANNELS)
        hChn.initialize(repeating: IT2HostChannel(), count: MAX_HOST_CHANNELS)
        sChn = .allocate(capacity: MAX_SLAVE_CHANNELS)
        sChn.initialize(repeating: IT2SlaveChannel(), count: MAX_SLAVE_CHANNELS)
        FilterParameters = .allocate(capacity: 128)
        FilterParameters.initialize(repeating: 0, count: 128)
        visited = .allocate(capacity: Self.rowsInAll)
        visited.initialize(repeating: false, count: Self.rowsInAll)
        mixer = IT2Mixer(module: module, voices: sChn, filterParameters: FilterParameters)

        if let own = module.midiData {
            for i in 0 ..< min(own.count, MIDIDataArea.count) { MIDIDataArea[i] = own[i] }
        } else {
            Music_SetDefaultMIDIDataArea()
        }

        // Music_Stop
        DecodeExpectedPattern = 0xFFFE
        DecodeExpectedRow = 0xFFFE
        RowDelay = 1
        CurrentTick = 1
        for i in 0 ..< MAX_HOST_CHANNELS {
            hChn[i].HostChnNum = UInt8(i)
            hChn[i].ChnPan = module.ChnlPan[i] & 0x7F
            hChn[i].ChnVol = module.ChnlVol[i]
        }
        for i in 0 ..< MAX_SLAVE_CHANNELS { sChn[i].Flags = SF_NOTE_STOP }
        GlobalVolume = UInt16(module.GlobalVol)
        ProcessTick = UInt16(module.InitialSpeed)
        CurrentSpeed = UInt16(module.InitialSpeed)
        Tempo = UInt16(module.InitialTempo)
        mixer.setTempo(UInt8(truncatingIfNeeded: Tempo))

        // Music_PlaySong: the filters open, and the place to start.
        if ST3Player.repeatsReferenceSlips {
            // The player this is ported from leaves it to the MIDI settings' lines for stopping and
            // starting to open the filters, which the usual settings do. A file that brings settings
            // of its own with those lines blank is left with every filter shut, and is played
            // muffled from end to end; Impulse Tracker's drivers start with them open. That is
            // repeated only for comparing the two players.
            MIDITranslate(hChn, nil, 0x0020)
            MIDITranslate(hChn, nil, 0x0000)
            MIDIInterpretState = 0
            MIDIInterpretType = 0
        } else {
            for i in 0 ..< MAX_HOST_CHANNELS {
                FilterParameters[i] = 127
                FilterParameters[64 + i] = 0
            }
        }
        CurrentOrder = UInt16(order & 0xFF)
        ProcessOrder = UInt16(truncatingIfNeeded: (order & 0xFF) - 1)
        ProcessRow = 0xFFFE
        Playing = true
    }

    deinit {
        hChn.deinitialize(count: MAX_HOST_CHANNELS)
        hChn.deallocate()
        sChn.deinitialize(count: MAX_SLAVE_CHANNELS)
        sChn.deallocate()
        FilterParameters.deallocate()
        visited.deallocate()
    }

    func Music_InitTempo() {
        mixer.setTempo(UInt8(truncatingIfNeeded: Tempo))
    }

    // MARK: Coming round

    /// A row is about to be played: has it been played before?
    private func rowIsRead() {
        defer {
            offTheEnd = false
            StopSong = false
        }
        guard CurrentRow < 256 else { return }
        let at = Int(CurrentOrder & 0xFF) << 8 | Int(CurrentRow)
        if visited[at] {
            cameRound = true
            visited.update(repeating: false, count: Self.rowsInAll)
        } else if let firstPlayedBy, !metEarlierSong, firstPlayedBy[at] < songNumber {
            metEarlierSong = true
            if offTheEnd {
                // Off the end of the list and round to its top, which a song before this one played:
                // this one is over.
                cameRound = true
                visited.update(repeating: false, count: Self.rowsInAll)
            } else {
                // On into what a song before this one played, which from here is part of this one.
                ledIntoEarlierSong = true
            }
        }
        visited[at] = true
        if let firstPlayedBy, firstPlayedBy[at] == ModuleSongs.unplayed { firstPlayedBy[at] = songNumber }
        ordersPlayed[Int(CurrentOrder & 0xFF)] = true
    }

    /// A loop inside a pattern goes back: the rows it plays again have not been played for the last time.
    func rowsWillRepeat(from row: Int) {
        var again = max(0, row)
        while again <= min(255, Int(CurrentRow)) {
            visited[Int(CurrentOrder & 0xFF) << 8 | again] = false
            again += 1
        }
    }
}
