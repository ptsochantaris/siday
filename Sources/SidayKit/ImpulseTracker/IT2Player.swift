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
    /// The rows that have been played while a loop inside a pattern was counting, each with the
    /// counts it was played under (see `rowIsRead`).
    private var loopVisits: [Int: [UInt64]] = [:]
    /// How many times the tune has moved to another place in the list of patterns, and the place
    /// it is at: a stay at a place has a number, which a loop's count is marked with.
    private(set) var stay: UInt32 = 1
    private var stayAt: UInt16 = 0xFFFF
    /// True when the tick just run began a row that has been played before.
    private(set) var cameRound = false
    private(set) var ordersPlayed: [Bool]
    var playedNote = false
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let songNumber: UInt8
    private var metEarlierSong = false
    private(set) var ledIntoEarlierSong = false
    private var offTheEnd = false
    /// True once the song has run off the end of the list of patterns, into a song before it: it is
    /// over, and no more of it is read. What is sounding then is left to die away.
    private(set) var over = false
    /// How many places the list of patterns has, and how many rows of each are kept track of in the
    /// table of who played a row first: 256 of each, but for an MPTM file, whose list can be longer
    /// and whose patterns have up to 1024 rows. (A pattern of any other file can be longer than
    /// 256; its rows beyond that are not kept track of.)
    private let orderRoom: Int, rowRoom: Int
    /// How many rows the table of who played a row first has for a module.
    static func rowsInAll(of module: IT2Module) -> Int {
        module.Orders.count * (module.openMPT == nil ? 256 : 1024)
    }

    // An MPTM file's: see `OpenMPTSong`. For any other module they are what Impulse Tracker has
    // and no more: a list of patterns that is one song and starts again from its top, rows that a
    // byte can count, and a tempo of 255 at the most.
    /// Where in the list the song being played starts, which is where its Bxx counts from, and
    /// where it goes on from when it comes to its end.
    private(set) var orderBase = 0
    private var restartOrder = 0
    /// What a row that a channel keeps is held to.
    let rowMask: UInt16
    let tempoCeiling: Int16
    /// The part of the tempo that is less than one, in ten-thousandths.
    var TempoFraction: UInt32 = 0
    /// The row that the loop last gone back round goes back to, less one, as `ProcessRow` is kept.
    var LoopBackRow: UInt16 = 0
    /// What has been cut off the ticks so far to make each a whole number of frames.
    var TickRemainder = 0.0

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
    /// The channels that have a slide to a note going on by itself: see `carryOnSlideToNote`.
    private var slidesCarried: UInt64 = 0
    /// True if that voice's key had been let go, or it was fading, before the new note came.
    private var lastWasLetGo = false
    /// True while a Digitrakker instrument named alone is being seen to: see `digitrakkerInstrumentAlone`.
    var digitrakkerAlone = false
    /// True while an MPTM file's note is struck again after its sample has ended: see `openMPTRestrike`.
    var restriking = false
    /// For a module of Digitrakker's (and made for no other): the sample each channel last started
    /// a note of, and the note.
    lazy var digitrakkerSamples = [IT2Sample?](repeating: nil, count: MAX_HOST_CHANNELS)
    lazy var digitrakkerNotes = [UInt8](repeating: 0, count: MAX_HOST_CHANNELS)
    /// For a module whose pitches are periods: each voice's last rates and their periods (see
    /// `rememberedFrequency`).
    lazy var knownPeriods = [(frequency: Int32, period: Int64)](repeating: (0, 0), count: MAX_SLAVE_CHANNELS * (IT2Player.periodsKept + 1))
    lazy var nextKnownPeriod = [UInt8](repeating: 0, count: MAX_SLAVE_CHANNELS)
    /// And each channel's slide of volume, if it is one of Digitrakker's own (see `IT2DigitrakkerSlide`).
    lazy var digitrakkerSlides = [IT2DigitrakkerSliding](repeating: IT2DigitrakkerSliding(), count: MAX_HOST_CHANNELS)

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
        // (A byte that says the same as the last is not sent again, as on a MIDI port; but where a
        // plug-in's setting is named, in a file with plug-ins that are played, it is not that kind of byte.)
        if Data >= 0x80, Data < 0xF0, !(sound != nil && MIDIInterpretState == 2) {
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
            } else if sound != nil, Data == 3 || Data >= 0x80 {
                // (In a file of ModPlug Tracker's or OpenMPT's with plug-ins that are played, such
                // a message is for the channel's plug-in.)
                MIDIInterpretType = Data
                MIDIInterpretState += 1
            } else {
                MIDIInterpretState = 0
            }
        } else if MIDIInterpretState == 3 {
            if Data <= 0x7F {
                if MIDIInterpretType >= 2 {
                    modPlugMacro(hc, code: MIDIInterpretType, value: Data)
                } else if MIDIInterpretType == 1 {
                    // (As OpenMPT once had it, a note's random swing goes on being added to
                    // whatever its filter is set to; as it has it now, the swing is over with.)
                    let swing = oldFilterSwing ? Int(hc.pointee.ResSwing) : 0
                    FilterParameters[(64 + Int(hc.pointee.HostChnNum)) & 127] = UInt8(max(0, min(127, Int(Data) + swing)))
                    hc.pointee.RestoreResonance = swing != 0 ? Data + 1 : 0
                } else {
                    let swing = oldFilterSwing ? Int(hc.pointee.CutSwing) : 0
                    FilterParameters[Int(hc.pointee.HostChnNum) & 127] = UInt8(max(0, min(127, Int(Data) + swing)))
                    hc.pointee.RestoreCutoff = swing != 0 ? Data + 1 : 0
                }
                if let sc {
                    sc.pointee.Flags |= SF_UPDATE_MIXERVOL
                    // (The voice is the last the channel had, which another channel may have by now.)
                    if MIDIInterpretType < 2, sc.pointee.HostChnNum == hc.pointee.HostChnNum { sc.pointee.FilterSet = true }
                }
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
            let separation = asImpulseTracker ? ins.PitchPanSep : ins.PitchPanSepAsModPlug ?? ins.PitchPanSep
            let newPan = Int(pan) + ((Int(Int8(bitPattern: hc.pointee.RawNote &- ins.PitchPanCenter)) * Int(Int8(bitPattern: separation))) >> 3)
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
        sc.pointee.ReleaseLevel = -1
        if ins.FilterMode != IT2Instrument.sameFilter, modPlugInstruments { hc.pointee.HighPass = ins.FilterMode == 1 }
        sc.pointee.HighPass = hc.pointee.HighPass

        sc.pointee.Flags = SF_CHAN_ON + SF_RECALC_PAN + SF_RECALC_VOL + SF_FREQ_CHANGE + SF_NEW_NOTE
        if ins.VolEnv.Flags & ENVF_ENABLED != 0 { sc.pointee.Flags |= SF_VOLENV_ON }
        if ins.PanEnv.Flags & ENVF_ENABLED != 0 { sc.pointee.Flags |= SF_PANENV_ON }
        if ins.PitchEnv.Flags & ENVF_ENABLED != 0 { sc.pointee.Flags |= SF_PITCHENV_ON }

        // (As ModPlug Tracker had it, nothing carries on from a note whose key has been let go
        // or that is fading, if the row names its instrument.)
        let startsAgain = ownEnvelopeCarry && hc.pointee.NotePackMask & 0x22 != 0 && lastWasLetGo
        if let lastSC = LastSlaveChannel, !startsAgain {
            // An envelope that carries on from the note before.
            if ins.VolEnv.Flags & (ENVF_ENABLED | ENVF_CARRY) == ENVF_ENABLED + ENVF_CARRY { sc.pointee.VolEnvState = lastSC.pointee.VolEnvState }
            if ins.PanEnv.Flags & (ENVF_ENABLED | ENVF_CARRY) == ENVF_ENABLED + ENVF_CARRY { sc.pointee.PanEnvState = lastSC.pointee.PanEnvState }
            if ins.PitchEnv.Flags & (ENVF_ENABLED | ENVF_CARRY) == ENVF_ENABLED + ENVF_CARRY { sc.pointee.PitchEnvState = lastSC.pointee.PitchEnvState }
        }

        hc.pointee.Flags |= HF_APPLY_RANDOM_VOL

        restoreFilter(hc)
        if hc.pointee.MIDIChn == 0 {
            sc.pointee.MIDIBank = 0x00FF // the filter wide open and without resonance
            if ins.FilterCutoff & 0x80 != 0 { SetFilterCutoff(hc, sc, ins.FilterCutoff & 0x7F) }
            if ins.FilterResonance & 0x80 != 0 {
                let filterQ = ins.FilterResonance & 0x7F
                sc.pointee.MIDIBank = (UInt16(filterQ) << 8) | (sc.pointee.MIDIBank & 0x00FF)
                SetFilterResonance(hc, sc, filterQ)
            }
        }
        // (What an instrument sets its filter to is not a macro's doing.)
        sc.pointee.FilterSet = false
        sc.pointee.FilterEnvelope = false
        sc.pointee.FilterFromStart = FilterParameters[Int(hc.pointee.HostChnNum) & 63] < 127
    }

    /// Starts a voice's envelopes again from their beginnings, those its instrument has.
    func restartEnvelopes(_ sc: IT2SlavePointer, _ ins: IT2Instrument) {
        sc.pointee.VolEnvState = IT2EnvState(Value: 64 << 16, CurNode: sc.pointee.VolEnvState.CurNode & Int16(bitPattern: 0xFF00))
        sc.pointee.PanEnvState = IT2EnvState()
        sc.pointee.PitchEnvState = IT2EnvState()
        if ins.VolEnv.Flags & ENVF_ENABLED != 0 { sc.pointee.Flags |= SF_VOLENV_ON }
        if ins.PanEnv.Flags & ENVF_ENABLED != 0 { sc.pointee.Flags |= SF_PANENV_ON }
        if ins.PitchEnv.Flags & ENVF_ENABLED != 0 { sc.pointee.Flags |= SF_PITCHENV_ON }
    }

    /// Puts a channel's filter back as it was before the last note's random swing moved it.
    private func restoreFilter(_ hc: IT2HostPointer) {
        let channel = Int(hc.pointee.HostChnNum) & 63
        if hc.pointee.RestoreCutoff > 0 { FilterParameters[channel] = hc.pointee.RestoreCutoff - 1 }
        if hc.pointee.RestoreResonance > 0 { FilterParameters[64 + channel] = hc.pointee.RestoreResonance - 1 }
        hc.pointee.RestoreCutoff = 0
        hc.pointee.RestoreResonance = 0
        hc.pointee.CutSwing = 0
        hc.pointee.ResSwing = 0
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
        restoreFilter(hc)
        sc.pointee.FilterSet = false
        sc.pointee.FilterEnvelope = false
        sc.pointee.FilterFromStart = FilterParameters[Int(hc.pointee.HostChnNum) & 63] < 127
        sc.pointee.Note = hc.pointee.RawNote
        sc.pointee.Ins = hc.pointee.Ins
        sc.pointee.Flags = SF_CHAN_ON + SF_RECALC_PAN + SF_RECALC_VOL + SF_FREQ_CHANGE + SF_NEW_NOTE
        sc.pointee.Started &+= 1

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
        sc.pointee.Backwards = 0
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
        sc.pointee.Backwards = 0
        sc.pointee.Started &+= 1

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
            if sc.pointee.InsPtr === ins {
                LastSlaveChannel = sc
                lastWasLetGo = sc.pointee.Flags & (SF_NOTE_OFF | SF_FADEOUT) != 0
            }
            NNA = sc.pointee.NNA
            if NNA != NNA_NOTE_CUT { sc.pointee.HostChnNum |= CHN_DISOWNED }
            scInitialized = true
        }

        while true { // what becomes of the old note
            if scInitialized {
                if NNA != NNA_NOTE_CUT, sc.pointee.VolSet > 0, sc.pointee.ChnVol > 0, sc.pointee.SmpVol > 0 {
                    if NNA == NNA_NOTE_OFF {
                        sc.pointee.Flags |= SF_NOTE_OFF
                        if module.madTracker { madTrackerFade(sc) }
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
        // (A voice that an MPTM file is playing backwards has been given a loop for the purpose.)
        if sc.pointee.Backwards != 0 { return }
        var LoopMode: UInt8
        var LoopBegin: Int32, LoopEnd: Int32
        let LoopEnabled = s.Flags & (SMPF_USE_LOOP | SMPF_USE_SUSTAINLOOP) != 0
        let SustainLoopOnlyAndNoteOff = s.Flags & SMPF_USE_SUSTAINLOOP != 0 && sc.pointee.Flags & SF_NOTE_OFF != 0 && s.Flags & SMPF_USE_LOOP == 0
        if adLib != nil, s.AdLib != nil {
            // A note for the FM chip has no sample to come to the end of: its voice goes round a
            // loop with nothing in it for as long as the note lasts.
            LoopBegin = 0
            LoopEnd = 4
            LoopMode = LOOP_FORWARDS
        } else if !LoopEnabled || SustainLoopOnlyAndNoteOff {
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
        // (As an older OpenMPT meant the two numbers, in a file it made: see `IT2Module`.)
        let randVol = asImpulseTracker ? ins.RandVol : ins.RandVolAsModPlug ?? ins.RandVol
        let randPan = asImpulseTracker ? ins.RandPan : ins.RandPanAsModPlug ?? ins.RandPan
        if randVol != 0 {
            var vol = ((Int(Int8(bitPattern: randVol)) * value) >> 6) + 1
            vol = Int(sc.pointee.SmpVol) + Int(Int16(truncatingIfNeeded: vol * Int(sc.pointee.SmpVol))) / 199
            sc.pointee.SmpVol = UInt8(max(0, min(128, vol)))
        }
        value = Int(Int8(bitPattern: Random()))
        if randPan != 0, sc.pointee.Pan != PAN_SURROUND {
            let pan = Int(sc.pointee.Pan) + ((Int(Int8(bitPattern: randPan)) * value) >> 7)
            sc.pointee.Pan = UInt8(max(0, min(64, pan)))
            sc.pointee.PanSet = sc.pointee.Pan
        }
        // ModPlug Tracker's and OpenMPT's: the filter, by as much as so many 64ths of where it is.
        // (What it was is kept, to be put back for the next note.)
        guard ins.CutSwing | ins.ResSwing != 0, modPlugInstruments else { return }
        let channel = Int(hc.pointee.HostChnNum) & 63
        func swing(_ most: UInt8, of setting: UInt8) -> Int {
            guard most != 0 else { return 0 }
            return (Int(most) * (Int(Int8(bitPattern: Random())) + 1) / 128 * Int(setting) + 1) / 128
        }
        let cutoff = FilterParameters[channel], resonance = FilterParameters[64 + channel]
        hc.pointee.CutSwing = Int16(swing(ins.CutSwing, of: cutoff))
        hc.pointee.ResSwing = Int16(swing(ins.ResSwing, of: resonance))
        if ins.CutSwing != 0 {
            hc.pointee.RestoreCutoff = cutoff + 1
            FilterParameters[channel] = UInt8(max(0, min(127, Int(cutoff) + Int(hc.pointee.CutSwing))))
        }
        if ins.ResSwing != 0 {
            hc.pointee.RestoreResonance = resonance + 1
            FilterParameters[64 + channel] = UInt8(max(0, min(127, Int(resonance) + Int(hc.pointee.ResSwing))))
        }
        sc.pointee.Flags |= SF_UPDATE_MIXERVOL
    }

    // MARK: Slides of pitch, in whole numbers as Impulse Tracker had them before its version 2.15

    /// - Parameter lasting: false for a slide of this tick alone, as a vibrato's, which matters
    ///   only where pitches are periods (see `openMPTPeriodSlide`).
    func PitchSlideUp(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ SlideValue: Int16, lasting: Bool = true) {
        if module.madTracker { return madTrackerSlide(sc, Int(SlideValue)) }
        if module.openMPT?.pitchesArePeriods == true { return openMPTPeriodSlide(sc, Int(SlideValue), lasting: lasting) }
        if module.Flags & ITF_LINEAR_FRQ != 0 {
            PitchSlideUpLinear(hc, sc, SlideValue)
            return
        }
        // The Amiga's way: by periods.
        sc.pointee.Flags |= SF_FREQ_CHANGE
        // (Digitrakker's are its own: see `digitrakkerSlide`.)
        if module.playsAsDigitrakker {
            digitrakkerSlide(sc, SlideValue)
            return
        }
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

    func PitchSlideDown(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, _ SlideValue: Int16, lasting: Bool = true) {
        PitchSlideUp(hc, sc, 0 &- SlideValue, lasting: lasting)
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
                // (Impulse Tracker takes an instrument beside a note-off for the sample of its
                // number, whose volume the note is given; OpenMPT, in an MT2 file, for the sample
                // the instrument plays the last note on.)
                if module.madTracker, hc.pointee.RawNote >= 120, hc.pointee.Ins != 0, module.Flags & ITF_INSTR_MODE != 0 {
                    let last = hc.pointee.SlaveChnPtr.map { Int($0.pointee.Note) } ?? 60
                    hc.pointee.Smp = UInt8(module.instrument(Int(hc.pointee.Ins) - 1).SmpNoteTable[min(119, last)] >> 8)
                }
            } else {
                let ins = module.instrument(Int(hc.pointee.Ins) - 1)
                let entry = ins.SmpNoteTable[Int(hc.pointee.RawNote)]
                hc.pointee.TranslatedNote = UInt8(entry & 0xFF)
                // (Over 128 is a plug-in of ModPlug Tracker's, not a MIDI channel.) An instrument
                // with a MIDI channel is one Impulse Tracker sends to a synthesiser, and plays no
                // sample for. ModPlug Tracker and OpenMPT went on playing its sample, and a file
                // of theirs is played as they played it: see `samplesPlayForMIDI`.
                if ins.MIDIChn == 0 || ins.MIDIChn > 128 || samplesPlayForMIDI {
                    hc.pointee.Smp = UInt8(entry >> 8)
                } else {
                    hc.pointee.MIDIChn = ins.MIDIChn == 17 ? (hc.pointee.HostChnNum & 0x0F) + 1 : ins.MIDIChn
                    hc.pointee.MIDIProg = ins.MIDIProg
                    hc.pointee.Smp = midiSample
                }
                if hc.pointee.Smp == 0 {
                    // A note its instrument has no sample for: Impulse Tracker does nothing with the
                    // row at all. OpenMPT, until its version 1.32, left the note out and did the rest.
                    if module.openMPT?.unmappedNotesKeepCommands == true {
                        let mask = hc.pointee.NotePackMask
                        hc.pointee.NotePackMask &= 0xCC
                        InitCommand(hc)
                        hc.pointee.NotePackMask = mask
                        hc.pointee.Flags |= HF_ROW_UPDATED
                    }
                    return
                }
            }
        }

        // (For an instrument with a tuning of its own, the note is seen to as OpenMPT sees to it, now,
        // or when a note that is put off comes.)
        if tunings, !delaysNote(hc) { openMPTTunedRow(hc) }
        if module.openMPT != nil, !delaysNote(hc) { openMPTRow(hc) }
        InitCommand(hc)
        // (And for a module of Digitrakker's, a place between the speakers that had no room.)
        if module.playsAsDigitrakker { digitrakkerRowPan(hc) }

        hc.pointee.Flags |= HF_ROW_UPDATED
        let ChannelMuted = module.ChnlPan[Int(hc.pointee.HostChnNum)] & 128 != 0
        if ChannelMuted, hc.pointee.Flags & HF_FREEPLAY_NOTE == 0, hc.pointee.Flags & HF_CHAN_ON != 0 {
            hc.pointee.SlaveChnPtr?.pointee.Flags |= SF_CHN_MUTED
        }
    }

    /// True if the row's note is put off to a later tick, by SDx or an MPTM file's :xy.
    private func delaysNote(_ hc: IT2HostPointer) -> Bool {
        guard hc.pointee.NotePackMask & 0x88 != 0 else { return false }
        if hc.pointee.Cmd == 19 {
            let value = hc.pointee.CmdVal != 0 ? hc.pointee.CmdVal : hc.pointee.EfxMem_S
            return value & 0xF0 == 0xD0 && !(module.playsAsDigitrakker && value == 0xD0)
        }
        return hc.pointee.Cmd == 29 && module.openMPT != nil && hc.pointee.CmdVal >> 4 != 0
    }

    /// For a module whose slides to a note go on by themselves (`IT2Module.slidesToNotesCarryOn`):
    /// takes note of a slide that a row begins, or of the note that ends one; and on a row that
    /// does neither, while one is going, gives the row the slide, as the command if it has none
    /// and else as the volume column's if that is free.
    private func carryOnSlideToNote(_ hc: IT2HostPointer) {
        let bit: UInt64 = 1 << UInt64(hc.pointee.HostChnNum & 63)
        let mask = hc.pointee.NotePackMask
        let hasCommand = mask & 0x88 != 0, hasVolume = mask & 0x44 != 0
        let slides = hasCommand && (hc.pointee.Cmd == 7 || hc.pointee.Cmd == 12) || hasVolume && hc.pointee.RawVolColumn >= 193 && hc.pointee.RawVolColumn <= 202
        if slides {
            slidesCarried |= bit
        } else if mask & 0x11 != 0 {
            slidesCarried &= ~bit
        } else if slidesCarried & bit != 0 {
            if !hasCommand {
                hc.pointee.NotePackMask |= 8
                hc.pointee.Cmd = 7
                hc.pointee.CmdVal = 0
            } else if !hasVolume {
                hc.pointee.NotePackMask |= 4
                hc.pointee.RawVolColumn = 193
            }
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
        RowJustRead = true
        PatternLooping = false
        DecodeExpectedRow &+= 1
        if CurrentPattern != DecodeExpectedPattern || DecodeExpectedRow != CurrentRow { UpdateGOTONote() }
        rowIsRead()

        for i in 0 ..< MAX_HOST_CHANNELS {
            hChn[i].Flags &= ~(HF_UPDATE_EFX_IF_CHAN_ON | HF_ALWAYS_UPDATE_EFX | HF_ROW_UPDATED | HF_UPDATE_VOLEFX_IF_CHAN_ON)
        }
        // (The row a song that is over has come to is another song's, and is not read.)
        if over { return }
        let orderBefore = ProcessOrder, breakBefore = BreakRow
        var onTheRow: UInt64 = 0
        while true {
            let chnNum = patternByte()
            if chnNum == 0 { break }
            let hc = readChannel(chnNum, command: true)
            if hc.pointee.NotePackMask & 1 != 0, hc.pointee.RawNote < 120 { playedNote = true }
            if module.madTracker { madTrackerRow(hc) }
            if module.slidesToNotesCarryOn {
                onTheRow |= 1 << UInt64(hc.pointee.HostChnNum & 63)
                carryOnSlideToNote(hc)
            }
            PreInitCommand(hc)
        }
        // (A channel that has a slide to a note going, and nothing on this row, has the slide.)
        if slidesCarried & ~onTheRow != 0 {
            for i in 0 ..< MAX_HOST_CHANNELS where (slidesCarried & ~onTheRow) & (1 << UInt64(i)) != 0 {
                let hc = hChn + i
                hc.pointee.NotePackMask = 8
                hc.pointee.Cmd = 7
                hc.pointee.CmdVal = 0
                PreInitCommand(hc)
            }
        }
        // In Impulse Tracker a jump on the row of a loop that goes back ends the loop. In OpenMPT,
        // unless a file asks for Impulse Tracker's way, the loop goes back and the jump is forgotten.
        if PatternLooping, module.openMPT?.loopsOutlastJumps == true {
            ProcessOrder = orderBefore
            BreakRow = breakBefore
            ProcessRow = LoopBackRow
        }
    }

    /// One tick of the song.
    private func UpdateData() {
        tickOfRow += 1
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
                        if NewOrder >= orderRoom {
                            // Beyond the list is its top; or, for an MPTM file, where its song
                            // starts again, unless this is the place before the first, which a jump
                            // to the top and the start of playing both come by way of.
                            NewOrder = NewOrder == 0x1_0000 ? 0 : restartOrder
                            continue
                        }
                        let NewPattern = module.Orders[NewOrder]
                        if Int(NewPattern) >= module.patternLimit {
                            if NewPattern == 0xFE, looked < 1024 { // a mark between songs, passed over
                                NewOrder += 1
                            } else {
                                NewOrder = restartOrder
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
                tickOfRow = 0
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
        if module.playsAsDigitrakker {
            digitrakkerAutoVibrato(sc)
            return
        }
        guard let smp = sc.pointee.SmpPtr, smp.AutoVibratoDepth != 0 else { return }
        if tunings, sc.pointee.Ins != 0xFF, sc.pointee.InsPtr?.Tuning != nil { return openMPTTunedAutoVibrato(sc, smp) }
        if module.madTracker { return madTrackerAutoVibrato(sc, smp) }
        if let song = module.openMPT { return song.itVibrato ? openMPTAutoVibrato(sc, smp) : openMPTOwnAutoVibrato(sc, smp) }
        sc.pointee.AutoVibratoDepth &+= UInt16(asImpulseTracker ? smp.AutoVibratoRate : smp.AutoVibratoRateAsModPlug ?? smp.AutoVibratoRate)
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
        // (Twenty-five points, but for an MPTM file's envelope, which can have more.)
        func magnitude(_ node: Int) -> Int32 { node < env.Magnitude.count ? Int32(env.Magnitude[node]) : 0 }
        func tick(_ node: Int) -> Int16 { node < env.Tick.count ? Int16(bitPattern: env.Tick[node]) : 0 }
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
                // (An MPTM file's volume envelope may have somewhere to go when the key is let go.)
                if SustainReleased, ins.VolEnv.ReleaseNode != IT2Envelope.noReleaseNode, sc.pointee.ReleaseLevel < 0, sc.pointee.Flags & SF_VOLENV_ON != 0 {
                    openMPTRelease(sc, ins.VolEnv)
                }

                // The envelope that is for pitch, or for the filter.
                let followed = sc.pointee.Flags & SF_PITCHENV_ON != 0
                if followed, UpdateEnvelope(asImpulseTracker ? ins.PitchEnv : ins.PitchEnvAsModPlug ?? ins.PitchEnv, &sc.pointee.PitchEnvState, SustainReleased) {
                    sc.pointee.Flags &= ~SF_PITCHENV_ON
                }
                if module.playsAsDigitrakker {
                    // (Digitrakker's goes a little more than a third as far.)
                    digitrakkerPitchEnvelope(sc)
                } else if ins.Tuning != nil, ins.PitchEnv.Flags & ENVF_TYPE_FILTER == 0 {
                    if ins.PitchEnv.Flags & ENVF_ENABLED != 0 { openMPTTunedPitchEnvelope(sc) }
                } else if module.openMPT?.pitchesArePeriods == true, ins.PitchEnv.Flags & ENVF_TYPE_FILTER == 0 {
                    openMPTPeriodPitchEnvelope(sc)
                } else if ins.PitchEnv.Flags & ENVF_TYPE_FILTER == 0 {
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
                    if followed {
                        sc.pointee.FilterSet = true
                        sc.pointee.FilterEnvelope = true
                    }
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
                        // (In Digitrakker it stays where it ended, and only a fade already begun goes on.)
                        sc.pointee.Flags &= ~SF_VOLENV_ON
                        if module.madTracker {
                            // (In MadTracker's way, as FastTracker's, a note whose key is held stays
                            // at the envelope's last level, and one the channel has let go of ends
                            // there if that is nothing.)
                            if sc.pointee.VolEnvState.Value & 0x00FF_0000 == 0, sc.pointee.HostChnNum & CHN_DISOWNED != 0 {
                                TurnOffCh = true
                            } else if SustainReleased {
                                sc.pointee.Flags |= SF_FADEOUT
                                HandleNoteFade = true
                            }
                        } else if module.playsAsDigitrakker {
                            HandleNoteFade = sc.pointee.Flags & SF_FADEOUT != 0
                        } else if sc.pointee.VolEnvState.Value & 0x00FF_0000 == 0 {
                            TurnOffCh = true
                        } else {
                            sc.pointee.Flags |= SF_FADEOUT
                            HandleNoteFade = true
                        }
                    } else if sc.pointee.Flags & SF_FADEOUT == 0 {
                        // A key let go while the envelope loops: the note fades. (In Digitrakker,
                        // whatever the envelope does.)
                        if SustainReleased, ins.VolEnv.Flags & ENVF_LOOP != 0 || module.playsAsDigitrakker {
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
                    if module.madTracker {
                        if !madTrackerFadeStep(sc, ins) { TurnOffCh = true }
                    } else if module.playsAsDigitrakker {
                        // (A Digitrakker instrument's fade is of 65,536 a tick: see `digitrakkerFade`.)
                        digitrakkerFade(sc, ins)
                    } else {
                        sc.pointee.FadeOut &-= ins.FadeOut
                    }
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
                if sc.pointee.ReleaseLevel >= 0, sc.pointee.Ins != 0xFF, let ins = sc.pointee.InsPtr {
                    // An MPTM file's envelope that has gone on from its release node, which can make
                    // a note louder than it was, though no louder than a note can be.
                    let level = openMPTReleasedLevel(sc, ins.VolEnv, Int(UInt16(truncatingIfNeeded: UInt32(bitPattern: sc.pointee.VolEnvState.Value) >> 8)))
                    volume = UInt16(min(32768, (Int(volume) * level) >> 14))
                } else {
                    volume = UInt16(truncatingIfNeeded: (Int(volume) * Int(UInt16(truncatingIfNeeded: UInt32(bitPattern: sc.pointee.VolEnvState.Value) >> 8))) >> 14)
                }
                sc.pointee.VolNoGlobal = volume
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
            if tunings { openMPTTunedPitch(sc) }
            if module.openMPT != nil { openMPTBend(sc) }
            if reverbs, sc.pointee.HostChnNum & CHN_DISOWNED == 0, let hc = sc.pointee.HostChnPtr { sc.pointee.Reverb = hc.pointee.Reverb }
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
                sc.pointee.VolNoGlobal = UInt16(truncatingIfNeeded: (Int(sc.pointee.Vol) * Int(sc.pointee.ChnVol) * Int(sc.pointee.SmpVol)) >> 4)
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
            if reverbs, sc.pointee.HostChnNum & CHN_DISOWNED == 0, let hc = sc.pointee.HostChnPtr { sc.pointee.Reverb = hc.pointee.Reverb }
        }
    }

    /// One tick: the song is moved on, and every voice's volume, place and pitch settled for the mixer.
    func Update() {
        cameRound = false
        RowJustRead = false
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
        // (A tuned instrument's vibrato and arpeggio are the tick's own: see `openMPTTunedPitch`.)
        if tunings {
            for i in 0 ..< MAX_HOST_CHANNELS {
                hChn[i].Tuned.vibrato = 1
                hChn[i].Tuned.arpeggio = 0
            }
        }
        // A song that is over reads no more rows: its notes go on, envelopes and fades and all.
        if !over { UpdateData() }
        // (An MPTM file keeps time in OpenMPT's ways, and its tick is as long as they make it.)
        if let song = module.openMPT {
            mixer.setTickFrames(openMPTTickFrames(song))
            mixer.setMusicTempo(UInt64(Tempo) * UInt64(OpenMPTSong.tempoUnit) + UInt64(TempoFraction))
        }
        if module.Flags & ITF_INSTR_MODE != 0 { UpdateInstruments() } else { UpdateSamples() }
        // (And for a file of ModPlug Tracker's or OpenMPT's with FM instruments or plug-ins: see `ModPlugSound`.)
        if sound != nil {
            if let song = module.openMPT, !song.parameterNotes.isEmpty { openMPTParameterNotes(song) }
            adLib?.update(self)
            mixer.GlobalVolume = GlobalVolume
        }
    }

    // MARK: Starting

    /// True if an instrument that has a MIDI channel plays its sample all the same: for a file made
    /// by ModPlug Tracker or OpenMPT, which did so, unless it is to be played as Impulse Tracker
    /// itself would play it.
    private let samplesPlayForMIDI: Bool
    /// True if S9E and S9F play a sample forwards and backwards, which they do in the trackers that
    /// came after Impulse Tracker and do not in it: for a file that says another tracker made it.
    let playsBackwards: Bool
    /// True if the command after Z in the alphabet sends a macro a little at a time over its row
    /// (see `CommandSmoothMacro`): for a file of ModPlug Tracker's or OpenMPT's, whose command it is.
    let smoothMacros: Bool
    let oldFilterSwing: Bool
    /// See `IT2Module.ModPlugWays`.
    let ownEnvelopeCarry: Bool, slideRestartsEnvelopes: Bool
    /// True if nothing is done for a file because another tracker than Impulse Tracker made it.
    let asImpulseTracker: Bool
    /// True unless what ModPlug Tracker and OpenMPT add to an IT file's instruments is to be
    /// left out: a filter the other way up, and one moved at random.
    let modPlugInstruments: Bool
    /// The file's plug-ins and FM instruments, if it has any that are played and is not to be played
    /// as Impulse Tracker would play it; and the FM chip, if it has instruments for that.
    let sound: ModPlugSound?
    let adLib: OpenMPTAdLib?
    /// True if the rate of a note for the FM chip is kept in sixteenths: see `OpenMPTAdLib.fineShift`.
    let fineFMPitch: Bool
    /// True if an instrument has a tuning of its own (see `openMPTTunedPitch`); and how many ticks
    /// the row has been playing, as OpenMPT counts them for such an instrument's slides, through
    /// the ticks that SEx and S6x add.
    let tunings: Bool
    var tickOfRow = 0
    /// True for a file whose patterns put channels in ModPlug's reverb, which is played (see `IT2Module.reverb`).
    let reverbs: Bool
    /// True for a tick on which a row was read; and the plug-in settings that the row being played
    /// is sliding (see `openMPTParameterNotes`).
    var RowJustRead = false
    var parameterSlides: [ParameterSlide] = []
    /// While a macro is being sent a little at a time over a row: how many ticks of the row are
    /// left, this one among them; nought while one is sent at once. See `sendMacro`.
    var macroTicksLeft = 0

    /// - Parameters:
    ///   - order: where in the list of patterns to start.
    ///   - firstPlayedBy: for a file of several songs, which of them first played each row.
    ///   - songNumber: which of them this is.
    ///   - asImpulseTracker: with nothing done for a file because another tracker made it: what the
    ///     player this is ported from does, for setting the two side by side.
    ///   - forSound: true if what it plays is to be heard, and not only followed to find how long
    ///     a tune is: then a file's plug-ins are made ready.
    init(_ module: IT2Module, order: Int = 0, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil, songNumber: UInt8 = 0, asImpulseTracker: Bool = false,
         forSound: Bool = false) {
        samplesPlayForMIDI = module.madeByModPlug && !asImpulseTracker
        playsBackwards = module.openMPT != nil || !module.madeByImpulseTracker && !asImpulseTracker
        smoothMacros = module.openMPT != nil || module.madeByModPlug && !asImpulseTracker
        oldFilterSwing = module.modPlug.oldFilterSwing
        ownEnvelopeCarry = module.modPlug.ownEnvelopeCarry && !asImpulseTracker
        slideRestartsEnvelopes = module.modPlug.slideRestartsEnvelopes && !asImpulseTracker
        self.asImpulseTracker = asImpulseTracker
        modPlugInstruments = !asImpulseTracker || module.openMPT != nil
        sound = asImpulseTracker ? nil : module.sound
        adLib = sound?.adLib.map { OpenMPTAdLib(behaviour: $0) }
        fineFMPitch = adLib != nil && module.Flags & ITF_LINEAR_FRQ != 0
        tunings = module.Flags & ITF_INSTR_MODE != 0 && (0 ..< module.InsNum).contains { module.instrument($0).Tuning != nil }
        reverbs = module.reverb != nil && !asImpulseTracker
        self.module = module
        midiSample = module.midiSample
        midiVoiceSample = module.midiVoiceSample
        sampleLimit = module.sampleLimit
        self.firstPlayedBy = firstPlayedBy
        self.songNumber = songNumber
        orderRoom = module.Orders.count
        rowRoom = module.openMPT == nil ? 256 : 1024
        rowMask = module.openMPT == nil ? 0xFF : 0xFFFF
        tempoCeiling = Int16(module.openMPT?.tempoCeiling ?? 255)
        ordersPlayed = [Bool](repeating: false, count: module.Orders.count)
        hChn = .allocate(capacity: MAX_HOST_CHANNELS)
        hChn.initialize(repeating: IT2HostChannel(), count: MAX_HOST_CHANNELS)
        sChn = .allocate(capacity: MAX_SLAVE_CHANNELS)
        sChn.initialize(repeating: IT2SlaveChannel(), count: MAX_SLAVE_CHANNELS)
        FilterParameters = .allocate(capacity: 128)
        FilterParameters.initialize(repeating: 0, count: 128)
        visited = .allocate(capacity: Self.rowsInAll(of: module))
        visited.initialize(repeating: false, count: Self.rowsInAll(of: module))
        // (An IT file that asks for OpenMPT's way of 1.17 of adding up has its way of placing channels too.)
        mixer = IT2Mixer(module: module, voices: sChn, filterParameters: FilterParameters, sound: sound, reverb: reverbs ? module.reverb : nil,
                         filter: asImpulseTracker ? .impulseTrackers : module.filter,
                         softPanning: module.modPlugLevels.map { $0.mixLevels == 3 && !asImpulseTracker })
        mixer.adLib = adLib
        if forSound { mixer.playsPlugIns() }

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
        // (A place in the list is one of Impulse Tracker's 256, but in an MPTM file, whose list can
        // be longer and can be several songs' lists end to end, each with a speed and a tempo of its own.)
        var order = order & 0xFF
        if let song = module.openMPT {
            order = max(0, min(module.Orders.count - 1, order))
            let sequence = song.sequence(at: order)
            orderBase = sequence.first
            restartOrder = sequence.restart
            ProcessTick = UInt16(sequence.speed)
            CurrentSpeed = UInt16(sequence.speed)
            Tempo = UInt16(sequence.tempo / OpenMPTSong.tempoUnit)
            TempoFraction = UInt32(sequence.tempo % OpenMPTSong.tempoUnit)
        } else {
            restartOrder = module.restartOrder
        }
        CurrentOrder = UInt16(order)
        ProcessOrder = UInt16(truncatingIfNeeded: order - 1)
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
        guard Int(CurrentRow) < rowRoom, Int(CurrentOrder) < orderRoom else { return }
        let at = Int(CurrentOrder) * rowRoom + Int(CurrentRow)
        // A row played while a loop inside a pattern is being counted down is not the same row
        // again unless the counts are the same too: a tune can send itself back by a jump from
        // inside such a loop, to rows it has played, and come out of them differently each time
        // until the counts run out. (OpenMPT tells a tune's end this way, and a tune made to be a
        // puzzle of jumps and loops is played to its real end.) Only a loop begun since the tune
        // last came to this place in the list counts for that: one that was jumped out of leaves
        // its count behind, and a tune that goes back to its start with such a count is going round.
        if CurrentOrder != stayAt {
            stayAt = CurrentOrder
            stay &+= 1
        }
        let counts = loopCounts()
        if counts != 0 {
            if loopVisits[at]?.contains(counts) == true {
                cameRound = true
                visited.update(repeating: false, count: orderRoom * rowRoom)
                loopVisits.removeAll(keepingCapacity: true)
            }
            // (The rows a loop plays again are played under its count, and so are not taken for
            // the tune coming round; what they were played under the first time stays as it was.)
            loopVisits[at, default: []].append(counts)
            if let firstPlayedBy, firstPlayedBy[at] == ModuleSongs.unplayed { firstPlayedBy[at] = songNumber }
            ordersPlayed[Int(CurrentOrder)] = true
            return
        }
        if visited[at] {
            cameRound = true
            visited.update(repeating: false, count: orderRoom * rowRoom)
            loopVisits.removeAll(keepingCapacity: true)
        } else if let firstPlayedBy, !metEarlierSong, firstPlayedBy[at] < songNumber {
            metEarlierSong = true
            if offTheEnd {
                // Off the end of the list and round to its top, which a song before this one played:
                // this one is over.
                cameRound = true
                over = true
                visited.update(repeating: false, count: orderRoom * rowRoom)
            } else {
                // On into what a song before this one played, which from here is part of this one.
                ledIntoEarlierSong = true
            }
        }
        visited[at] = true
        if let firstPlayedBy, firstPlayedBy[at] == ModuleSongs.unplayed { firstPlayedBy[at] = songNumber }
        ordersPlayed[Int(CurrentOrder)] = true
    }

    /// The counts of every channel's loop inside the pattern that was begun in this stay at this
    /// place in the list, as one number: nought if none is counting. (Each channel that is counting adds its place and its count, mixed so that two
    /// different sets of counts do not come to the same number but by the rarest chance.)
    private func loopCounts() -> UInt64 {
        var counts: UInt64 = 0
        for channel in 0 ..< MAX_HOST_CHANNELS where hChn[channel].PattLoopCount != 0 && hChn[channel].PattLoopStay == stay {
            counts = (counts ^ (UInt64(channel) << 8 | UInt64(hChn[channel].PattLoopCount))) &* 0x0000_0100_0000_01B3
            counts |= 1
        }
        return counts
    }

}
