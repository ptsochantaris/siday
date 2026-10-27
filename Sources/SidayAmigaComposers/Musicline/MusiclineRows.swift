// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the Musicline Editor's replay routine, as UADE carries it
// (amigasrc/players/other/musicline_editor/mlineplayer102.asm): its reading of the tunes' lists and the
// parts' rows, and the starting of notes. The names given are that source's labels.

import SidayChips
import SidayFoundation

extension MusiclinePlayer {
    /// A counter of one of the instruments' ways of making its waveform (transform, phase, mix, resonance
    /// and filter: `cnt_counter` and on): where it is, its speed, the two places it goes between, how
    /// many times more it turns (below nought, no more), its delay, whether it moves only at notes (the
    /// high byte of `cnt_step`), and where it was at the note.
    struct Counter {
        var counter: UInt16 = 0
        var speed: UInt16 = 0
        var repeatStart: UInt16 = 0
        var repeatEnd: UInt16 = 0
        var turns: UInt16 = 0
        var delay: UInt16 = 0
        var step: UInt16 = 0
        var saved: UInt16 = 0
    }

    /// A voice of the player (`ch_CustomAddress` and on), named as the source names its fields.
    struct Voice {
        var paulaVoice = 0
        var dmaChannel: UInt16 = 0
        var voiceOff: UInt8 = 0
        var channelOff: UInt8 = 0
        var spd: UInt8 = 0, grv: UInt8 = 0, spdPart: UInt8 = 0, grvPart: UInt8 = 0
        var spdCnt: UInt8 = 0, arpSpdCnt: UInt8 = 0, partGrv: UInt8 = 0, arpgGrv: UInt8 = 0
        var wsNumber: UInt8 = 0, wsNumberOld: UInt8 = 0
        /// `ch_InstPtr` and `ch_WsPtr`: the instrument's number and the sample's, nought for none.
        var instrument = 0
        var wsSample = 0
        var partNote: UInt8 = 0, partInst: UInt8 = 0
        /// The row's five effects (`ch_PartEffectNum` and `ch_PartEffects`): numbers and parameters.
        var effectNumbers = InlineArray<5, UInt8>(repeating: 0)
        var effectParameters = InlineArray<5, UInt8>(repeating: 0)
        var arp: UInt8 = 0, arpPos: UInt8 = 0, arpTab: UInt8 = 0, arpWait: UInt8 = 0
        var arpgNote: UInt8 = 0, arpVolSld: UInt8 = 0, arpPchSld: UInt8 = 0, arpPchSldType: UInt8 = 0
        var arpNote: UInt16 = 0
        var tunePos: UInt8 = 0, partPos: UInt8 = 0, partPosWork: UInt8 = 0
        var tuneJumpCount: UInt8 = 0, partJmpCnt: UInt8 = 0
        var wsRepPtrOrg = 0, wsPointer = 0, wsRepPointer = 0
        var wsLength: UInt16 = 0, wsRepLength: UInt16 = 0
        var volume1: UInt16 = 0, volume2: UInt16 = 0, volume3: UInt16 = 0
        var note: UInt16 = 0, period1: UInt16 = 0, period2: UInt16 = 0
        var transpose: UInt16 = 0, semiTone: UInt16 = 0, fineTune: UInt16 = 0
        var smpOfs: UInt8 = 0, smplOfs: UInt8 = 0, oldInst: UInt8 = 0, restart: UInt8 = 0
        var volAdd: UInt8 = 0, volSld: UInt8 = 0, cVolSld: UInt8 = 0, mVolSld: UInt8 = 0
        var volSet: UInt16 = 0, cVolume: UInt16 = 0
        var volAddNum: UInt16 = 0, cVolAddNum: UInt16 = 0, mVolAddNum: UInt16 = 0
        var volSldSpd: UInt16 = 0, cVolSldSpd: UInt16 = 0, mVolSldSpd: UInt16 = 0
        var volSldVol: UInt16 = 0, cVolSldVol: UInt16 = 0, mVolSldVol: UInt16 = 0
        var volSldToVol: UInt16 = 0, cVolSldToVol: UInt16 = 0, mVolSldToVol: UInt16 = 0
        var volSldType: UInt8 = 0, cVolSldType: UInt8 = 0, mVolSldType: UInt8 = 0
        var volSldToVolOff: UInt8 = 0, cVolSldToVolOff: UInt8 = 0, mVolSldToVolOff: UInt8 = 0
        var vol: UInt8 = 0
        var instPchSld: UInt8 = 0, mixResFilBoost: UInt8 = 0
        var transposeNum: UInt8 = 0
        var partNum: UInt16 = 0
        var pchSld: UInt8 = 0, pchSldType: UInt8 = 0
        var pchSldSpd: UInt16 = 0, pchSldNote: UInt16 = 0, pchSldToNote: UInt16 = 0, pchAdd: UInt16 = 0
        var arpVolSldSpd: UInt16 = 0, arpPchSldSpd: UInt16 = 0, arpPchSldToNote: UInt16 = 0, arpPchSldNote: UInt16 = 0
        var ptPchSld: UInt8 = 0, ptPchSldType: UInt8 = 0
        var ptPchSldSpd: UInt16 = 0, ptPchSldSpd2: UInt16 = 0, ptPchSldNote: UInt16 = 0, ptPchSldToNote: UInt16 = 0, ptPchAdd: UInt16 = 0
        var effects1: UInt8 = 0, effects2: UInt8 = 0, effectsPar1: UInt8 = 0, effectsPar2: UInt8 = 0
        var adsrVolume: UInt16 = 0
        var adsrData = InlineArray<12, UInt16>(repeating: 0)
        var play: UInt8 = 0, waveOrSample: UInt8 = 0
        var phaInit: UInt8 = 0, filInit: UInt8 = 0, traInit: UInt8 = 0, tuneWait: UInt8 = 0
        var vib: UInt8 = 0, vibDir: UInt8 = 0, vibWaveNum: UInt8 = 0, partVibWaveNum: UInt8 = 0
        var vibCount: UInt16 = 0, vibCmdSpeed: UInt16 = 0, vibCmdDepth: UInt16 = 0, vibCmdDelay: UInt16 = 0
        var vibAtkSpeed: UInt16 = 0, vibAtkLength: UInt16 = 0, vibDepth: UInt16 = 0, vibNote: UInt16 = 0
        var ptTrePos: UInt8 = 0, ptTreCmd: UInt8 = 0, ptTreWave: UInt8 = 0
        var ptVibPos: UInt8 = 0, ptVibCmd: UInt8 = 0, ptVibWave: UInt8 = 0
        var ptVibNote: UInt16 = 0
        var tre: UInt8 = 0, treDir: UInt8 = 0, treWaveNum: UInt8 = 0, partTreWaveNum: UInt8 = 0
        var treCount: UInt16 = 0, treCmdSpeed: UInt16 = 0, treCmdDepth: UInt16 = 0, treCmdDelay: UInt16 = 0
        var treAtkSpeed: UInt16 = 0, treAtkLength: UInt16 = 0, treDepth: UInt16 = 0
        var filLastSample: UInt8 = 0, resLastSample: UInt8 = 0, filLastInit: UInt8 = 0, resLastInit: UInt8 = 0
        var resAmp: UInt8 = 0, resInit: UInt8 = 0, phaType: UInt8 = 0, filType: UInt8 = 0
        var tra = Counter(), pha = Counter(), mix = Counter(), res = Counter(), fil = Counter()
        var traSpd: UInt16 = 0, phaSpd: UInt16 = 0, mixSpd: UInt16 = 0, resSpd: UInt16 = 0, filSpd: UInt16 = 0
        var mixWaveNum: UInt8 = 0, mixInit: UInt8 = 0
        var traWsPtrs = InlineArray<6, UInt8>(repeating: 0)
        var playError: UInt8 = 0, looInit: UInt8 = 0
        var looRepeat: UInt16 = 0, looRepEnd: UInt16 = 0, looLength: UInt16 = 0
        var looStep: UInt32 = 0
        var looWait: UInt16 = 0, looWaitCounter: UInt16 = 0, looDelay: UInt16 = 0, looTurns: UInt16 = 0
        var looCounter: UInt16 = 0, looCounterSave: UInt16 = 0, looWsCounterMax: UInt16 = 0, looSpd: UInt16 = 0
        var looWsPointer = 0
    }

    // The effects' numbers, as the source's EffectsMac.i names them.
    static let fxPortamento: UInt8 = 0x03
    static let fxVolumeSlideUp: UInt8 = 0x11, fxVolumeSlideDown: UInt8 = 0x12, fxVolumeSlideToVol: UInt8 = 0x14
    static let fxChannelVolSlideUp: UInt8 = 0x21, fxChannelVolSlideDown: UInt8 = 0x22, fxChannelVolSlideToVol: UInt8 = 0x24
    static let fxMasterVolSlideUp: UInt8 = 0x31, fxMasterVolSlideDown: UInt8 = 0x32, fxMasterVolSlideToVol: UInt8 = 0x34
    static let fxPTPortamento: UInt8 = 0xE3, fxPTVolSlideUp: UInt8 = 0xE6, fxPTVolSlideDown: UInt8 = 0xE7
    static let fxPTTremolo: UInt8 = 0xE8, fxPTVibrato: UInt8 = 0xEA

    // The bits of an instrument's two bytes of effects and of its two of their settings.
    static let adsr: UInt8 = 1, vibrato: UInt8 = 2, tremolo: UInt8 = 4, arpeggio: UInt8 = 8, loop: UInt8 = 0x10
    static let loopStop: UInt8 = 0x20, wsLoop: UInt8 = 0x80
    static let transform: UInt8 = 1, phase: UInt8 = 2, mixing: UInt8 = 4, resonance: UInt8 = 8, filter: UInt8 = 0x10
    // (`inst_EnvTraPhaFilBits`, the voice's `ch_EffectsPar1`.)
    static let adsrHoldSustain: UInt8 = 1, transformInit: UInt8 = 2, transformStep: UInt8 = 4, phaseInit: UInt8 = 8
    static let phaseStep: UInt8 = 0x10, phaseFill: UInt8 = 0x20, filterInit: UInt8 = 0x40, filterStep: UInt8 = 0x80
    // (`inst_MixResLooBits`, the voice's `ch_EffectsPar2`.)
    static let mixInit: UInt8 = 1, mixStep: UInt8 = 2, mixBuff: UInt8 = 4, mixCounter: UInt8 = 8
    static let resonanceInit: UInt8 = 0x10, resonanceStep: UInt8 = 0x20, loopInit: UInt8 = 0x40, loopStep: UInt8 = 0x80

    // MARK: The lists and the rows

    /// `PlayTune`: each of the four voices' lists and rows (and, for eight voices, the other four's).
    mutating func playTune<Output: TFMXOutput>(_ output: inout Output) {
        for c in 0 ..< (playMode == 0 ? 4 : 8) { playVoice(c, &output) }
    }

    /// A word of the voice's list, at a place in it (a byte: the list goes round at 256 words).
    private func listWord(_ c: Int, _ place: UInt8) -> UInt16 {
        guard let list = tunes[song].lists[c] else { return 0 }
        return UInt16(list[2 * Int(place)]) << 8 | UInt16(list[2 * Int(place) + 1])
    }

    /// `PlayVoice`: the voice's speed counted down, and at nought its next row read: through its list's
    /// commands (to end, to jump back so many times or for ever, and to wait), and in its part through
    /// the rows that jump; then its instrument, effects and note (`CheckInst`).
    private mutating func playVoice<Output: TFMXOutput>(_ c: Int, _ output: inout Output) {
        if voices[c].voiceOff != 0 { return }
        voices[c].spdCnt &-= 1
        if voices[c].spdCnt != 0 { return }
        voices[c].partPosWork = voices[c].partPos
        loopError = 256
        var d0 = voices[c].spd
        voices[c].partGrv = ~voices[c].partGrv
        if voices[c].partGrv != 0, voices[c].grv != 0 { d0 = voices[c].grv }
        voices[c].spdCnt = d0
        voices[c].spdPart = 0
        voices[c].grvPart = 0
        restart: while true {
            // (`_LoopError`: a list that goes round for ever without a part.)
            if loopError == 0 { return }
            loopError -= 1
            let place = voices[c].tunePos
            // (`_TunePos`, the place the player starts from, is the start.)
            if place == 0 { voices[c].playError |= 2 }
            // siday's: a voice past its list has come to its end.
            if Int(place) >= tunes[song].lengths[c], finished[c] == 0 { finished[c] = 1 }
            let w = listWord(c, place)
            let d5 = UInt8(w & 0x1F)
            let target = UInt8(w >> 8)
            if w & 0x20 != 0 {
                switch (w & 0xC0) >> 6 {
                case 1:
                    voices[c].voiceOff = 1
                    voices[c].playError |= 1
                    if finished[c] == 0 { finished[c] = 1 }
                    return
                case 2:
                    if voices[c].tuneJumpCount != 0 {
                        voices[c].tuneJumpCount -= 1
                        if voices[c].tuneJumpCount == 0 {
                            voices[c].tunePos &+= 1
                        } else {
                            voices[c].tunePos = target
                        }
                        continue restart
                    }
                    if place <= target {
                        voices[c].tunePos &+= 1
                        continue restart
                    }
                    voices[c].tuneJumpCount = d5
                    if d5 == 0 {
                        voices[c].playError |= 1
                        finished[c] = 2
                    }
                    voices[c].tunePos = target
                    continue restart
                case 3:
                    if voices[c].tuneWait != 0 {
                        voices[c].tuneWait -= 1
                        if voices[c].tuneWait == 0 {
                            voices[c].tunePos &+= 1
                            continue restart
                        }
                        return
                    }
                    voices[c].tuneWait = target
                    if target == 0 {
                        voices[c].tunePos &+= 1
                        continue restart
                    }
                    voices[c].ptPchSld = 0
                    voices[c].pchSld = 0
                    voices[c].volSld = 0
                    voices[c].partNote = 0
                    voices[c].partInst = 0
                    if d5 == 0 { return }
                    voices[c].spd = d5
                    voices[c].spdCnt = d5
                    return
                default:
                    break
                }
            }
            // A part: its number (ten bits), and its transposition, in semitones from -16.
            let number = Int(w >> 8) | Int((w << 2) & 0x300)
            voices[c].partNum = UInt16(number)
            let transposition = d5 &- 0x10
            voices[c].transposeNum = transposition
            let transposeWord = UInt16(bitPattern: Int16(Int8(bitPattern: transposition)) << 5)
            while true {
                let row = voices[c].partPos
                voices[c].partPos = (voices[c].partPos &+ 1) & 0x7F
                if voices[c].partPos == 0 {
                    voices[c].tunePos &+= 1
                    voices[c].spd = tuneSpeed
                    voices[c].grv = tuneGroove
                }
                // (A part not in the file the player reads from the Amiga's first bytes: nought.)
                let rows = parts[number]
                func rowByte(_ k: Int) -> UInt8 { rows.map { $0[12 * Int(row) + k] } ?? 0 }
                voices[c].partNote = rowByte(0)
                voices[c].partInst = rowByte(1)
                for k in 0 ..< 5 {
                    voices[c].effectNumbers[k] = rowByte(2 + 2 * k)
                    voices[c].effectParameters[k] = rowByte(3 + 2 * k)
                }
                var d1 = voices[c].partNote
                if d1 == 61 {
                    // The part's end: at its first row, the player stops (`StopPlay`).
                    if row == 0 {
                        stopPlay(&output)
                        return
                    }
                    voices[c].partPos = 0
                    voices[c].partPosWork = 0
                    voices[c].spd = tuneSpeed
                    voices[c].grv = tuneGroove
                    voices[c].spdCnt = voices[c].spd
                    voices[c].tunePos &+= 1
                    continue restart
                }
                if d1 & 0x80 != 0 {
                    // A jump in the part, back to a row, so many times or for ever.
                    d1 &= 0x7F
                    if voices[c].partJmpCnt != 0 {
                        voices[c].partJmpCnt -= 1
                        if voices[c].partJmpCnt == 0 { continue }
                        voices[c].partPos = d1
                        voices[c].partPosWork = d1
                        continue
                    }
                    if row <= d1 { continue }
                    voices[c].partJmpCnt = voices[c].partInst
                    if voices[c].partInst == 0 { voices[c].playError |= 1 }
                    voices[c].partPos = d1
                    voices[c].partPosWork = d1
                    continue
                }
                if d1 != 0 { voices[c].transpose = transposeWord }
                checkInst(c, &output)
                return
            }
        }
    }

    /// `CheckInst`: the row's instrument taken up (its arpeggio and slide cleared if it is another), then
    /// its effects (`PlayPartFx`), its arpeggio (`PlayArpg`) and its note (`PlayInst`).
    private mutating func checkInst<Output: TFMXOutput>(_ c: Int, _ output: inout Output) {
        let number = voices[c].partInst
        if number != 0, Int(number) < instruments.count, instruments[Int(number)] != nil {
            voices[c].instrument = Int(number)
            if number != voices[c].oldInst {
                voices[c].arp = 0
                voices[c].instPchSld = 0
                voices[c].oldInst = number
            }
        }
        playPartFx(c, &output)
        playArpg(c)
        playInst(c, &output)
    }

    /// `PlayPartFx`: the voice's effects of the row before cleared, and each of the row's five done.
    private mutating func playPartFx<Output: TFMXOutput>(_ c: Int, _ output: inout Output) {
        voices[c].play |= 2
        voices[c].effects1 &= ~0x40
        voices[c].vib = 0
        voices[c].vibNote = 0
        voices[c].ptVibNote = 0
        voices[c].tre = 0
        voices[c].vol = 0
        voices[c].volAdd = 0
        voices[c].volSld = 0
        voices[c].cVolSld = 0
        voices[c].mVolSld = 0
        voices[c].pchSld = 0
        voices[c].ptPchSld = 0
        voices[c].smpOfs = 0
        voices[c].restart = 0
        voices[c].arp &= 0xF5
        if voices[c].arp & 0x10 != 0 {
            voices[c].arp = 0
            voices[c].arpVolSld = 0
            voices[c].arpPchSld = 0
            voices[c].arpPchSldNote = 0
        }
        if voices[c].partNote != 0 {
            voices[c].pchSldToNote = 0xFFFF
            voices[c].ptPchSldToNote = 0xFFFF
        }
        for k in 0 ..< 5 { partEffect(c, voices[c].effectNumbers[k], voices[c].effectParameters[k], &output) }
    }

    /// One of a row's effects (`FX_JumpTable`): its number (which the routines keep as the kind of their
    /// slide) and its parameter.
    private mutating func partEffect<Output: TFMXOutput>(_ c: Int, _ d0: UInt8, _ par: UInt8, _ output: inout Output) {
        let p16 = UInt16(par)
        switch d0 {
        case 0x01: // `pfx_SlideUp`
            voices[c].pchSld = d0
            voices[c].pchSldType = 0
            if par != 0 { voices[c].pchSldSpd = p16 }
            voices[c].pchSldToNote = 59 * 32 + 32
        case 0x02: // `pfx_SlideDown`
            voices[c].pchSld = d0
            voices[c].pchSldType = 0xFF
            if par != 0 { voices[c].pchSldSpd = p16 }
            voices[c].pchSldToNote = 0
        case 0x03: // `pfx_Portamento`
            voices[c].pchSld = d0
            if par != 0 { voices[c].pchSldSpd = p16 }
            let d1 = voices[c].note &+ voices[c].pchSldNote
            if voices[c].partNote != 0 {
                let d2 = UInt16(voices[c].partNote) << 5
                voices[c].partNote = 0
                voices[c].pchSldToNote = d2
                if d2 == d1 {
                    voices[c].pchSldToNote = 0xFFFF
                } else {
                    voices[c].pchSldType = (d2 &- d1) & 0x8000 != 0 ? 0xFF : 0
                    return
                }
            }
            if voices[c].pchSldToNote == 0xFFFF { voices[c].pchSld = 0 }
        case 0x04: // `pfx_InitInstrumentPortamento`
            voices[c].instPchSld = 0
        case 0x05: // `pfx_PitchUp`
            if par != 0 { voices[c].pchAdd &+= p16 }
        case 0x06: // `pfx_PitchDown`
            if par != 0 { voices[c].pchAdd &-= p16 }
        case 0x07: // `pfx_VibratoSpeed`
            if par != 0 { voices[c].vibCmdSpeed = p16 }
        case 0x08, 0x09: // `pfx_VibratoUp`, `pfx_VibratoDown`
            voices[c].vib = d0
            if voices[c].partNote != 0 {
                voices[c].vibDir = d0 == 0x08 ? 1 : 0
                voices[c].vibCount = 0
                voices[c].vibCmdDepth = 0
                voices[c].vibCmdDelay = 0
                voices[c].vibAtkSpeed = 0
                voices[c].vibAtkLength = 0
            }
            if par != 0 { voices[c].vibDepth = p16 << 8 }
            voices[c].vibWaveNum = voices[c].partVibWaveNum
        case 0x0A: // `pfx_VibratoWave`
            if par <= 3 {
                voices[c].vibWaveNum = par
                voices[c].partVibWaveNum = par
            }
        case 0x0B: // `pfx_SetFinetune`
            let value = Int8(bitPattern: par)
            let clamped = value < 0 ? max(value, -31) : min(value, 31)
            voices[c].fineTune = UInt16(bitPattern: Int16(clamped))
            voices[c].play |= 4
        case 0x10: // `pfx_Volume`
            voices[c].vol = d0
            voices[c].volSet = p16 << 4
        case 0x11, 0x12: // `pfx_VolumeSlideUp`, `pfx_VolumeSlideDown`
            voices[c].volSld = d0
            if par != 0 { voices[c].volSldSpd = p16 }
        case 0x13: // `pfx_VolumeSlideToVolSet`
            voices[c].volSldToVol = p16 << 4
        case 0x14: // `pfx_VolumeSlideToVol`
            voices[c].volSld = d0
            if par != 0 { voices[c].volSldSpd = p16 }
            let d1 = voices[c].volume1
            voices[c].volSldVol = d1
            let d2 = voices[c].volSldToVol
            if d2 == d1 {
                voices[c].volSldToVolOff = 1
            } else {
                voices[c].volSldType = (d2 &- d1) & 0x8000 != 0 ? 0xFF : 0
                voices[c].volSldToVolOff = 0
            }
        case 0x15: // `pfx_VolumeAdd`
            voices[c].volAdd = d0
            if par != 0 { voices[c].volAddNum = p16 << 4 }
        case 0x16: // `pfx_VolumeSub`
            voices[c].volAdd = d0
            if par != 0 { voices[c].volAddNum = 0 &- (p16 << 4) }
        case 0x17: // `pfx_TremoloSpeed`
            if par != 0 { voices[c].treCmdSpeed = p16 }
        case 0x18, 0x19: // `pfx_TremoloUp`, `pfx_TremoloDown`
            voices[c].tre = d0
            if voices[c].partNote != 0 {
                voices[c].treDir = d0 == 0x18 ? 1 : 0
                voices[c].treCount = 0
                voices[c].treCmdDepth = 0
                voices[c].treCmdDelay = 0
                voices[c].treAtkSpeed = 0
                voices[c].treAtkLength = 0
            }
            if par != 0 { voices[c].treDepth = p16 << 8 }
            voices[c].treWaveNum = voices[c].partTreWaveNum
        case 0x1A: // `pfx_TremoloWave`
            if par <= 3 {
                voices[c].treWaveNum = par
                voices[c].partTreWaveNum = par
            }
        case 0x20: // `pfx_ChannelVol`
            voices[c].cVolume = p16 << 4
        case 0x21, 0x22: // `pfx_ChannelVolSlideUp`, `pfx_ChannelVolSlideDown`
            voices[c].cVolSld = d0
            if par != 0 { voices[c].cVolSldSpd = p16 }
        case 0x23: // `pfx_ChannelVolSlideToVolSet`
            voices[c].cVolSldToVol = p16 << 4
        case 0x24: // `pfx_ChannelVolSlideToVol`
            voices[c].cVolSld = d0
            if par != 0 { voices[c].cVolSldSpd = p16 }
            let d1 = voices[c].cVolume
            voices[c].cVolSldVol = d1
            let d2 = voices[c].cVolSldToVol
            if d2 == d1 {
                voices[c].cVolSldToVolOff = 1
            } else {
                voices[c].cVolSldType = (d2 &- d1) & 0x8000 != 0 ? 0xFF : 0
                voices[c].cVolSldToVolOff = 0
            }
        case 0x25: // `pfx_ChannelVolAdd`
            if par != 0 { voices[c].cVolAddNum = p16 << 4 }
            voices[c].cVolume &+= voices[c].cVolAddNum
            if voices[c].cVolume > 64 * 16 { voices[c].cVolume = 64 * 16 }
        case 0x26: // `pfx_ChannelVolSub`
            if par != 0 { voices[c].cVolAddNum = p16 << 4 }
            voices[c].cVolume &-= voices[c].cVolAddNum
            if voices[c].cVolume & 0x8000 != 0 { voices[c].cVolume = 0 }
        case 0x27: // `pfx_AllChannelVol`
            for k in 0 ..< (playMode == 0 ? 4 : 8) { voices[k].cVolume = p16 << 4 }
        case 0x30: // `pfx_MasterVol`
            masterVolume = p16 << 4
        case 0x31, 0x32: // `pfx_MasterVolSlideUp`, `pfx_MasterVolSlideDown`
            voices[c].mVolSld = d0
            if par != 0 { voices[c].mVolSldSpd = p16 }
        case 0x33: // `pfx_MasterVolSlideToVolSet`
            voices[c].mVolSldToVol = p16 << 4
        case 0x34: // `pfx_MasterVolSlideToVol`
            voices[c].mVolSld = d0
            if par != 0 { voices[c].mVolSldSpd = p16 }
            // (The routine compares with D1, which holds the effect's number times four: not the volume.)
            let d1 = UInt16(d0) << 2
            voices[c].mVolSldVol = d1
            let d2 = voices[c].mVolSldToVol
            if d2 == d1 {
                voices[c].mVolSldToVolOff = 1
            } else {
                voices[c].mVolSldType = (d2 &- d1) & 0x8000 != 0 ? 0xFF : 0
                voices[c].mVolSldToVolOff = 0
            }
        case 0x35: // `pfx_MasterVolAdd`
            if par != 0 { voices[c].mVolAddNum = p16 << 4 }
            masterVolume &+= voices[c].mVolAddNum
            if masterVolume > 64 * 16 { masterVolume = 64 * 16 }
        case 0x36: // `pfx_MasterVolSub`
            if par != 0 { voices[c].mVolAddNum = p16 << 4 }
            masterVolume &-= voices[c].mVolAddNum
            if masterVolume & 0x8000 != 0 { masterVolume = 0 }
        case 0x40: // `pfx_SpeedPart`
            guard par != 0 else { return }
            let speed = min(par, 0x1F)
            voices[c].spdPart = 1
            voices[c].spd = speed
            if voices[c].grv == 0 || voices[c].partGrv == 0 { voices[c].spdCnt = speed }
        case 0x41: // `pfx_GroovePart`
            guard par != 0 else { return }
            let groove = min(par, 0x1F)
            voices[c].grvPart = 1
            voices[c].grv = groove
            if voices[c].partGrv != 0 { voices[c].spdCnt = groove }
        case 0x42: // `pfx_SpeedAll`: a speed, or from $20 a tempo, the CIA's timer set for it.
            guard par != 0 else { return }
            if par >= 0x20 {
                tuneTempo = p16
                timerA = Self.timerValue(tempo: p16)
                return
            }
            tuneSpeed = par
            for k in 0 ..< (playMode == 0 ? 4 : 8) {
                // (The voices after this one, which have still to read their rows, take the speed; this one
                // and those before it, unless their part has a speed of its own, take it and count it.)
                if k > c {
                    voices[k].spd = par
                } else if voices[k].spdPart == 0 {
                    voices[k].spd = par
                    if voices[k].grv == 0 || voices[k].partGrv == 0 { voices[k].spdCnt = par }
                }
            }
        case 0x43: // `pfx_GrooveAll`
            guard par != 0 else { return }
            let groove = par & 0x1F
            tuneGroove = groove
            for k in 0 ..< (playMode == 0 ? 4 : 8) {
                if k > c {
                    voices[k].grv = groove
                } else if voices[k].grvPart == 0 {
                    voices[k].grv = groove
                    if groove != 0, voices[k].partGrv == 0 { voices[k].spdCnt = groove }
                }
            }
        case 0x44: // `pfx_ArpeggioList`
            voices[c].arp |= 4
            voices[c].arpTab = par
        case 0x45: // `pfx_ArpeggioListOneStep`
            voices[c].arp |= 0x14
            voices[c].arpTab = par
        case 0x46: // `pfx_HoldSustain`
            voices[c].effects1 |= 0x40
            voices[c].effectsPar1 &= ~Self.adsrHoldSustain
            if par != 0 { voices[c].effectsPar1 |= Self.adsrHoldSustain }
        case 0x47: // `pfx_Filter`: the Amiga's filter, by its power light (on for 1).
            lightFilter = par != 0
        case 0x48: // `pfx_SampleOffset`
            voices[c].smpOfs = d0
            if par != 0 { voices[c].smplOfs = par }
        case 0x49: // `pfx_RestartNoVolume`
            if voices[c].partInst == 0 { voices[c].restart = 1 }
        case 0x4A: // `pfx_WaveSample`
            guard par != 0, Int(par) < samples.count, samples[Int(par)] != nil else { return }
            voices[c].wsSample = Int(par)
            voices[c].arp |= 8
        case 0x4B: // `pfx_InitInstrument`
            voices[c].phaInit = 0
            voices[c].resInit = 0
            voices[c].filInit = 0
            voices[c].traInit = 0
            voices[c].mixInit = 0
            voices[c].looInit = 0
        case 0xE1: // `pfx_PTSlideUp`
            voices[c].ptPchSld = d0
            voices[c].ptPchSldType = 0
            if par != 0 { voices[c].ptPchSldSpd = p16 }
            voices[c].ptPchSldToNote = 106
        case 0xE2: // `pfx_PTSlideDown`
            voices[c].ptPchSld = d0
            voices[c].ptPchSldType = 0xFF
            if par != 0 { voices[c].ptPchSldSpd = p16 }
            voices[c].ptPchSldToNote = 3591
        case 0xE3: // `pfx_PTPortamento`
            voices[c].pchSld = Self.fxPortamento
            voices[c].ptPchSld = d0
            if par != 0 { voices[c].ptPchSldSpd2 = p16 }
            let d2 = periodOfNote(c, voices[c].note) &+ voices[c].ptPchSldNote
            if voices[c].partNote != 0 {
                let d0 = periodOfNote(c, UInt16(voices[c].partNote) << 5)
                voices[c].partNote = 0
                voices[c].ptPchSldToNote = d0
                if d0 == d2 {
                    voices[c].ptPchSldToNote = 0xFFFF
                } else {
                    voices[c].ptPchSldType = (d2 &- d0) & 0x8000 != 0 ? 0xFF : 0
                    return
                }
            }
            if voices[c].ptPchSldToNote == 0xFFFF {
                voices[c].ptPchSld = 0
                voices[c].pchSld = 0
            }
        case 0xE4: // `pfx_PTFineSlideUp`
            if par != 0 { voices[c].ptPchAdd &-= p16 & 0xF }
        case 0xE5: // `pfx_PTFineSlideDown`
            if par != 0 { voices[c].ptPchAdd &+= p16 & 0xF }
        case 0xE6: // `pfx_PTVolSlideUp`
            voices[c].volSld = d0
            if par != 0 { voices[c].volSldSpd = p16 }
        case 0xE7: // `pfx_PTVolSlideDown`
            voices[c].volSld = d0
            if par != 0 { voices[c].volSldSpd = p16 }
        case 0xE8: // `pfx_PTTremolo`
            voices[c].tre = d0
            guard par != 0 else { return }
            var d2 = voices[c].ptTreCmd
            if par & 0x0F != 0 { d2 = d2 & 0xF0 | par & 0x0F }
            if par & 0xF0 != 0 { d2 = d2 & 0x0F | par & 0xF0 }
            voices[c].ptTreCmd = d2
        case 0xE9: // `pfx_PTTremoloWave`
            voices[c].ptTreWave = par & 0x0F
        case 0xEA: // `pfx_PTVibrato`
            voices[c].vib = d0
            guard par != 0 else { return }
            var d2 = voices[c].ptVibCmd
            if par & 0x0F != 0 { d2 = d2 & 0xF0 | par & 0x0F }
            if par & 0xF0 != 0 { d2 = d2 & 0x0F | par & 0xF0 }
            voices[c].ptVibCmd = d2
        case 0xEB: // `pfx_PTVibratoWave`
            voices[c].ptVibWave = par & 0x0F
        default: // `pfx_UNUSED`, `pfx_UserCommand`
            break
        }
    }

    // MARK: Arpeggios

    /// The arpeggio's number, as the routine finds it in `ArpgList`: the instrument's word, or with an
    /// arpeggio list asked for by the row (`ch_Arp` bit 2), that word's low byte replaced by the row's;
    /// times four as a signed word, an index into the list. nil for one past it.
    private func arpeggioRows(_ c: Int) -> [UInt8]? {
        guard let instrument = instruments[voices[c].instrument] else { return nil }
        var d0 = instrument.word(Instrument.arpTable)
        if voices[c].arp & 4 != 0 { d0 = d0 & 0xFF00 | UInt16(voices[c].arpTab) }
        let index = Int(Int16(bitPattern: d0 << 2)) >> 2
        guard index >= 0, index < arpeggios.count else { return nil }
        return arpeggios[index]
    }

    /// `PlayArpg`: at a row's note with a new instrument (or a restart), the instrument's arpeggio, or the
    /// row's, started from its first row: up to a row with a note.
    private mutating func playArpg(_ c: Int) {
        guard voices[c].partNote != 0, voices[c].instrument != 0, let instrument = instruments[voices[c].instrument] else { return }
        voices[c].arpWait = 0
        if voices[c].arp & 4 == 0, voices[c].arp & 1 == 0 {
            guard instrument.byte(Instrument.effects1) & Self.arpeggio != 0 else { return }
            voices[c].arp |= 1
        }
        if voices[c].restart == 0, voices[c].partInst == 0 { return }
        voices[c].arp |= 2
        guard let rows = arpeggioRows(c) else { return }
        voices[c].arpPos = 0
        voices[c].arpWait = 0
        voices[c].arpVolSld = 0
        voices[c].arpPchSld = 0
        voices[c].arpPchSldNote = 0
        voices[c].arpSpdCnt = instrument.byte(Instrument.arpSpeed)
        while true {
            let place = Int(voices[c].arpPos)
            voices[c].arpPos = (voices[c].arpPos &+ 1) & 0x7F
            let row = 6 * place
            voices[c].arpgNote = voices[c].partNote
            var d0 = rows[row]
            if d0 == 0 {
                // (`WaitArpg`)
                voices[c].arpWait |= 1
                return
            }
            if d0 == 61 {
                voices[c].effects1 &= ~Self.arpeggio
                return
            }
            if d0 == 62 { continue }
            let d1 = rows[row + 1]
            voices[c].wsNumber = d1 != 0 ? d1 : instrument.byte(Instrument.smplNumber)
            for k in 0 ..< 2 {
                let fx = rows[row + 2 + 2 * k]
                if fx <= 5 { arpEffect(c, fx, rows[row + 3 + 2 * k]) }
            }
            if d0 & 0x80 == 0 {
                voices[c].arp |= 0x20
            } else {
                d0 = d0 &+ 61 &+ voices[c].arpgNote
            }
            let note = UInt16(bitPattern: Int16(Int8(bitPattern: d0)) << 5)
            voices[c].note = note
            voices[c].arpNote = note
            arpWaitStart(c, d1)
            return
        }
    }

    /// `ArpWaitStart`: the arpeggio row's sample, if it has one, as the voice's (`ch_WsPtr`).
    mutating func arpWaitStart(_ c: Int, _ number: UInt8) {
        guard number != 0, Int(number) < samples.count, samples[Int(number)] != nil else { return }
        voices[c].wsSample = Int(number)
        voices[c].arp |= 8
    }

    /// One of an arpeggio row's two effects (`ArpFx_JmpTab`): 1 and 2 slides up and down, 3 a volume, 4 and
    /// 5 volume slides, 6 a restart of the instrument's waveforms (which only the arpeggio's later rows do).
    mutating func arpEffect(_ c: Int, _ d2: UInt8, _ par: UInt8) {
        let d3 = UInt16(par)
        switch d2 {
        case 1: // `ArpSldUp`
            voices[c].arpPchSld = d2
            voices[c].arpPchSldType = 0
            if par != 0 {
                voices[c].arpPchSldSpd = d3
                voices[c].arpPchSldToNote = 59 * 32 + 32
            }
        case 2: // `ArpSldDwn`
            voices[c].arpPchSld = d2
            voices[c].arpPchSldType = 0xFF
            if par != 0 {
                voices[c].arpPchSldSpd = d3
                voices[c].arpPchSldToNote = 0
            }
        case 3: // `ArpSetVol`
            voices[c].restart |= 4
            voices[c].volume1 = d3 << 4
            voices[c].volume2 = d3 << 4
            voices[c].volume3 = d3 << 4
        case 4, 5: // `ArpSldVol`
            voices[c].arpVolSld = d2
            if par != 0 { voices[c].arpVolSldSpd = d3 }
        case 6: // `ArpRestart`
            voices[c].restart |= 2
            let bits = voices[c].effectsPar1
            if bits & Self.phaseInit != 0 { voices[c].phaInit = 0 }
            if bits & Self.resonanceInit != 0 { voices[c].resInit = 0 }
            if bits & Self.filterInit != 0 { voices[c].filInit = 0 }
            if bits & Self.transformInit != 0 { voices[c].traInit = 0 }
            if bits & Self.mixInit != 0 { voices[c].mixInit = 0 }
            if voices[c].effectsPar2 & Self.loopInit != 0 { voices[c].looInit = 0 }
        default:
            break
        }
    }

    // MARK: Notes

    /// `PlayInst`: the voice's instrument's sample or waveform, or the sample its arpeggio or the row
    /// chose, taken up, with the instrument's effects; its volume; and its note (and its slide to it, for
    /// an instrument that slides), and then its effects started (`InstPlay`).
    mutating func playInst<Output: TFMXOutput>(_ c: Int, _ output: inout Output) {
        if voices[c].arpWait & 1 != 0 { return }
        guard voices[c].instrument != 0, let instrument = instruments[voices[c].instrument] else { return }
        var source = sound(instrument: voices[c].instrument)
        var takeVolume = true
        var takeSound = false
        var d1: UInt8 = 0
        if voices[c].restart & 3 != 0 {
            takeSound = true
            voices[c].wsNumber = instrument.byte(Instrument.smplNumber)
            d1 = instrument.byte(Instrument.smplType)
        } else if voices[c].partInst == 0 {
            takeVolume = false
        } else if voices[c].pchSld == Self.fxPortamento || voices[c].partNote == 0 {
            // (`.getvol`: the volume, and not the sound.)
        } else {
            takeSound = true
            if voices[c].arp & 8 == 0 {
                voices[c].wsNumber = instrument.byte(Instrument.smplNumber)
                d1 = instrument.byte(Instrument.smplType)
            } else {
                guard voices[c].wsSample != 0 else { return }
                source = sound(sample: voices[c].wsSample)
                d1 = source.type
                if d1 != 0 { d1 = instrument.byte(Instrument.smplType) }
            }
        }
        if takeSound {
            // (`.ws`)
            var d0 = source.pointer
            if d0 == 0 { return }
            if instrument.byte(Instrument.transpose) == 0 { voices[c].transpose = 0 }
            var d3 = instrument.byte(Instrument.envTraPhaFilBits)
            if voices[c].effects1 & 0x40 != 0 {
                d3 &= 0xFE
                voices[c].effectsPar1 &= 1
                d3 |= voices[c].effectsPar1
            }
            voices[c].effectsPar1 = d3
            voices[c].effectsPar2 = instrument.byte(Instrument.mixResLooBits)
            voices[c].effects1 = instrument.byte(Instrument.effects1)
            voices[c].effects2 = instrument.byte(Instrument.effects2)
            voices[c].waveOrSample = d1
            if d1 != 0 {
                fixWaveLength(c, d0, d1, instrument)
            } else {
                var length = source.length
                if voices[c].smpOfs != 0 {
                    let offset = UInt16(voices[c].smplOfs) << 7
                    if offset < length {
                        length -= offset
                        d0 += 2 * Int(offset)
                    } else {
                        length = 1
                    }
                }
                voices[c].wsPointer = d0
                voices[c].wsLength = length
                var loop = source.repPointer
                var loopLength = source.repLength
                let loops = voices[c].arp & 8 != 0 ? loopLength != 0 : instrument.byte(Instrument.effects1) & Self.wsLoop != 0
                if !loops {
                    loop = Self.zeroSample
                    loopLength = 1
                }
                voices[c].wsRepPointer = loop
                voices[c].wsRepPtrOrg = loop
                voices[c].wsRepLength = loopLength
            }
            // (`.getvolume`)
            voices[c].restart &= 7
            if voices[c].restart != 0 { takeVolume = false }
        }
        if takeVolume { voices[c].volume1 = instrument.word(Instrument.volume) << 4 }
        // (`.playnote`)
        var d1v = voices[c].volume1
        if voices[c].vol != 0 { d1v = voices[c].volSet }
        if voices[c].volAdd != 0 {
            d1v &+= voices[c].volAddNum
            if d1v & 0x8000 != 0 { d1v = 0 }
            if d1v > 64 * 16 { d1v = 64 * 16 }
        }
        voices[c].volume1 = d1v
        voices[c].volume2 = d1v
        voices[c].volume3 = d1v
        if voices[c].pchSld == Self.fxPortamento { return }
        let slideSpeed = instrument.byte(Instrument.slideSpeed)
        if slideSpeed != 0, voices[c].partNote != 0 {
            voices[c].pchSldSpd = voices[c].pchSldSpd & 0xFF00 | UInt16(slideSpeed)
            let from = voices[c].note &+ voices[c].pchSldNote
            let to = UInt16(voices[c].partNote) << 5
            voices[c].pchSldToNote = to
            voices[c].pchSldType = (to &- from) & 0x8000 != 0 ? 0xFF : 0
            if voices[c].instPchSld != 0 {
                instPlay(c, &output)
                return
            }
            voices[c].instPchSld = Self.fxPortamento
        }
        // (`.noteplay`)
        if voices[c].arp & 2 != 0 {
            voices[c].arp &= ~2
        } else {
            guard voices[c].partNote != 0 else { return }
            voices[c].note = UInt16(voices[c].partNote) << 5
            voices[c].arpVolSld = 0
            voices[c].arpPchSld = 0
            voices[c].arpPchSldNote = 0
        }
        voices[c].semiTone = source.semiTone << 5
        if voices[c].play & 4 == 0 { voices[c].fineTune = source.fineTune }
        voices[c].ptPchSldNote = 0
        voices[c].pchSldNote = 0
        voices[c].ptVibNote = 0
        voices[c].ptTrePos = 0
        voices[c].ptVibPos = 0
        voices[c].vibNote = 0
        voices[c].ptPchAdd = 0
        voices[c].pchAdd = 0
        if voices[c].partInst != 0 || voices[c].restart & 3 != 0 { instPlay(c, &output) }
    }

    /// `FixWaveLength`: a waveform played at its size (1 for 16 bytes, 2 for 32, 3 for 64, 4 for 128 and
    /// more for 256): its copy of that size, as far into its sound as the copy is, and its length, the
    /// instrument's length shifted down to it.
    mutating func fixWaveLength(_ c: Int, _ pointer: Int, _ type: UInt8, _ instrument: Instrument) {
        let (offset, shift): (Int, UInt16) = switch type {
        case ...1: (256 + 128 + 64 + 32, 4)
        case 2: (256 + 128 + 64, 3)
        case 3: (256 + 128, 2)
        case 4: (256, 1)
        default: (0, 0)
        }
        let at = pointer + offset
        voices[c].wsPointer = at
        voices[c].wsRepPointer = at
        voices[c].wsRepPtrOrg = at
        let length = instrument.word(Instrument.smplLength) >> shift
        voices[c].wsLength = length
        voices[c].wsRepLength = length
    }

    /// `InstPlay`: the note started (`ch_Play` bit 0), and the instrument's effects with it: its vibrato,
    /// tremolo and envelope, unless the row has its own; its counters for the waveforms it makes, each
    /// started afresh, or at a note of the same instrument kept going if it says so; and its loop through
    /// its sample.
    private mutating func instPlay<Output: TFMXOutput>(_ c: Int, _ output: inout Output) {
        guard let instrument = instruments[voices[c].instrument] else { return }
        if voices[c].pchSld == Self.fxPortamento || voices[c].arpWait & 1 != 0 {
            sexit(c)
            return
        }
        voices[c].play |= 1
        if voices[c].vib == 0, voices[c].effects1 & Self.vibrato != 0 {
            voices[c].vibCount = 0
            voices[c].vibCmdDepth = 0
            voices[c].vibCmdSpeed = instrument.word(Instrument.vibSpeed)
            voices[c].vibCmdDelay = instrument.word(Instrument.vibDelay)
            voices[c].vibAtkSpeed = instrument.word(Instrument.vibAtkSpd)
            voices[c].vibAtkLength = instrument.word(Instrument.vibAttack)
            voices[c].vibDepth = instrument.word(Instrument.vibDepth)
            voices[c].vibWaveNum = instrument.byte(Instrument.vibWaveNum)
            voices[c].vibDir = instrument.byte(Instrument.vibDir)
        }
        if voices[c].tre == 0, voices[c].effects1 & Self.tremolo != 0 {
            voices[c].treCount = 0
            voices[c].treCmdDepth = 0
            voices[c].treCmdSpeed = instrument.word(Instrument.treSpeed)
            voices[c].treCmdDelay = instrument.word(Instrument.treDelay)
            voices[c].treAtkSpeed = instrument.word(Instrument.treAtkSpd)
            voices[c].treAtkLength = instrument.word(Instrument.treAttack)
            voices[c].treDepth = instrument.word(Instrument.treDepth)
            voices[c].treWaveNum = instrument.byte(Instrument.treWaveNum)
            voices[c].treDir = instrument.byte(Instrument.treDir)
        }
        if voices[c].effects1 & Self.adsr != 0 {
            voices[c].adsrVolume = 0
            for k in 0 ..< 12 { voices[c].adsrData[k] = instrument.word(Instrument.envelope + 2 * k) }
        }
        let partInst = voices[c].partInst
        // (A counter started: at its start, going towards its other end, after its delay.)
        func started(_ counter: inout Counter, _ start: Int, keep: Bool) {
            if !keep {
                counter.counter = instrument.word(start)
                counter.speed = instrument.word(start + 6)
                counter.repeatStart = instrument.word(start + 2)
                counter.repeatEnd = instrument.word(start + 4)
                if Int16(bitPattern: counter.counter) > Int16(bitPattern: counter.repeatStart) { counter.speed = 0 &- counter.speed }
            }
            counter.delay = instrument.word(start + 10)
        }
        // (Whether a counter that keeps going at a note of the same instrument does: its last
        // instrument's number set to this one's, and kept going if it was this one.)
        func kept(_ last: inout UInt8) -> Bool {
            let was = last
            last = partInst
            return was == partInst
        }
        if voices[c].effects2 & Self.phase != 0 {
            voices[c].phaType = instrument.byte(Instrument.phaType + 1)
            let step = voices[c].effectsPar1 & Self.phaseStep != 0
            voices[c].pha.step = voices[c].pha.step & 0xFF | (step ? 0xFF00 : 0)
            var keep: Bool
            if step {
                voices[c].phaSpd = instrument.word(Instrument.phaTurns)
                voices[c].pha.turns = 0
                keep = kept(&voices[c].phaInit)
            } else {
                voices[c].pha.turns = instrument.word(Instrument.phaTurns)
                if voices[c].effectsPar1 & Self.phaseInit != 0 {
                    keep = kept(&voices[c].phaInit)
                } else {
                    voices[c].phaInit = 0
                    keep = false
                }
            }
            started(&voices[c].pha, Instrument.phaStart, keep: keep)
        }
        voices[c].mixResFilBoost = instrument.byte(Instrument.mixResFilBoost)
        if voices[c].effects2 & Self.resonance != 0 {
            voices[c].resAmp = instrument.byte(Instrument.resAmp)
            let step = voices[c].effectsPar2 & Self.resonanceStep != 0
            voices[c].res.step = voices[c].res.step & 0xFF | (step ? 0xFF00 : 0)
            var keep: Bool
            if step {
                voices[c].resSpd = instrument.word(Instrument.resTurns)
                voices[c].res.turns = 0
                keep = kept(&voices[c].resInit)
            } else {
                voices[c].res.turns = instrument.word(Instrument.resTurns)
                if voices[c].effectsPar2 & Self.resonanceInit != 0 {
                    keep = kept(&voices[c].resInit)
                } else {
                    voices[c].resInit = 0
                    keep = false
                }
            }
            if !keep { voices[c].resLastInit = 1 }
            started(&voices[c].res, Instrument.resStart, keep: keep)
        }
        if voices[c].effects2 & Self.filter != 0 {
            voices[c].filType = instrument.byte(Instrument.filType)
            let step = voices[c].effectsPar1 & Self.filterStep != 0
            voices[c].fil.step = voices[c].fil.step & 0xFF | (step ? 0xFF00 : 0)
            var keep: Bool
            if step {
                voices[c].filSpd = instrument.word(Instrument.filTurns)
                voices[c].fil.turns = 0
                keep = kept(&voices[c].filInit)
            } else {
                voices[c].fil.turns = instrument.word(Instrument.filTurns)
                if voices[c].effectsPar1 & Self.filterInit != 0 {
                    keep = kept(&voices[c].filInit)
                } else {
                    voices[c].filInit = 0
                    keep = false
                }
            }
            if !keep { voices[c].filLastInit = 1 }
            started(&voices[c].fil, Instrument.filStart, keep: keep)
        }
        if voices[c].effects2 & Self.mixing != 0 {
            voices[c].mixWaveNum = instrument.byte(Instrument.mixWaveNum)
            let step = voices[c].effectsPar2 & Self.mixStep != 0
            voices[c].mix.step = voices[c].mix.step & 0xFF | (step ? 0xFF00 : 0)
            var keep: Bool
            if step {
                voices[c].mixSpd = instrument.word(Instrument.mixTurns)
                voices[c].mix.turns = 0
                keep = kept(&voices[c].mixInit)
            } else {
                voices[c].mix.turns = instrument.word(Instrument.mixTurns)
                if voices[c].effectsPar2 & Self.mixInit != 0 {
                    keep = kept(&voices[c].mixInit)
                } else {
                    voices[c].mixInit = 0
                    keep = false
                }
            }
            started(&voices[c].mix, Instrument.mixStart, keep: keep)
        }
        if voices[c].effects2 & Self.transform != 0 {
            voices[c].traWsPtrs[0] = instrument.byte(Instrument.smplNumber)
            for k in 0 ..< 5 { voices[c].traWsPtrs[k + 1] = instrument.byte(Instrument.traWaveNums + k) }
            let step = voices[c].effectsPar1 & Self.transformStep != 0
            voices[c].tra.step = voices[c].tra.step & 0xFF | (step ? 0xFF00 : 0)
            var keep: Bool
            if step {
                voices[c].traSpd = instrument.word(Instrument.traTurns)
                voices[c].tra.turns = 0
                keep = kept(&voices[c].traInit)
            } else {
                voices[c].tra.turns = instrument.word(Instrument.traTurns)
                if voices[c].effectsPar1 & Self.transformInit != 0 {
                    keep = kept(&voices[c].traInit)
                } else {
                    voices[c].traInit = 0
                    keep = false
                }
            }
            started(&voices[c].tra, Instrument.traStart, keep: keep)
        }
        // (`.playloop`) The loop through the sample, for a sample of an instrument that has one.
        if voices[c].effects1 & Self.loop != 0 {
            if instrument.byte(Instrument.smplType) != 0 || instrument.word(Instrument.looLength) == 0 {
                voices[c].effects1 &= ~Self.loop
            } else {
                var keep: Bool
                if voices[c].effectsPar2 & Self.loopStep != 0 {
                    voices[c].looSpd = instrument.word(Instrument.looTurns)
                    voices[c].looTurns = 0
                    keep = kept(&voices[c].looInit)
                } else {
                    voices[c].looTurns = instrument.word(Instrument.looTurns)
                    if voices[c].effectsPar2 & Self.loopInit != 0 {
                        keep = kept(&voices[c].looInit)
                    } else {
                        voices[c].looInit = 0
                        keep = false
                    }
                }
                if keep {
                    // (`.plskip`: the note not started again.)
                    voices[c].play &= ~1
                } else {
                    let sample = sound(sample: Int(instrument.byte(Instrument.smplNumber)))
                    voices[c].looWsPointer = sample.pointer
                    let start = instrument.word(Instrument.looStart)
                    voices[c].looCounter = start
                    voices[c].looCounterSave = start
                    let length = instrument.word(Instrument.looLength)
                    voices[c].looWsCounterMax = UInt16(truncatingIfNeeded: UInt32(sample.length) &- UInt32(length))
                    voices[c].looLength = length
                    voices[c].looRepEnd = instrument.word(Instrument.looRepEnd)
                    voices[c].looWait = instrument.word(Instrument.looWait)
                    voices[c].looStep = UInt32(instrument.word(Instrument.looLpStep))
                    let repeatStart = instrument.word(Instrument.looRepeat)
                    voices[c].looRepeat = repeatStart
                    if Int16(bitPattern: start) > Int16(bitPattern: repeatStart) { voices[c].looStep = 0 &- voices[c].looStep }
                }
                // (`.plgo`)
                voices[c].looDelay = instrument.word(Instrument.looDelay)
                voices[c].looWaitCounter = 0
                let at = voices[c].looWsPointer + 2 * Int(voices[c].looCounterSave)
                voices[c].wsPointer = at
                voices[c].wsRepPointer = at
                voices[c].wsRepPtrOrg = at
                voices[c].wsLength = voices[c].looLength
                voices[c].wsRepLength = voices[c].looLength
            }
        }
        sexit(c)
    }

    /// `Sexit`: the waveform-making effects left on only for a loop of 8, 16, 32, 64 or 128 words.
    func sexitKeeps(_ length: UInt16) -> Bool { [8, 16, 32, 64, 128].contains(length) }

    mutating func sexit(_ c: Int) {
        if !sexitKeeps(voices[c].wsRepLength) { voices[c].effects2 = 0 }
    }

    // MARK: Periods

    /// `Per`: the voice's period: its note in 32nds of a semitone, with its vibrato, slides, transposition,
    /// fine tuning and pitch added (its transposition not for an arpeggio's own note), kept from a semitone
    /// below the table to its end; the table's period, with the ProTracker effects' slide, vibrato and pitch
    /// added, kept from 106 to 3,591.
    mutating func periodOf(_ c: Int) {
        var d0 = voices[c].note &+ voices[c].vibNote &+ voices[c].pchSldNote &+ voices[c].arpPchSldNote &+ voices[c].semiTone
            &+ voices[c].fineTune &+ voices[c].pchAdd
        if voices[c].arp & 0x20 == 0 { d0 &+= voices[c].transpose }
        var period = Self.pitch(d0) &+ voices[c].ptPchSldNote &+ voices[c].ptVibNote &+ voices[c].ptPchAdd
        let signed = Int16(bitPattern: period)
        if signed < 106 { period = 106 } else if signed > 3591 { period = 3591 }
        voices[c].period1 = period
        voices[c].period2 = period
    }

    /// `GetPeriod2`: the period of a note (and the voice's vibrato, slides, fine tuning, pitch and
    /// transposition), from the table, unbounded by the ProTracker effects.
    func periodOfNote(_ c: Int, _ note: UInt16) -> UInt16 {
        var d0 = note &+ voices[c].vibNote &+ voices[c].pchSldNote &+ voices[c].arpPchSldNote &+ voices[c].semiTone
            &+ voices[c].fineTune &+ voices[c].pchAdd
        d0 &+= voices[c].transpose
        return Self.pitch(d0)
    }

    /// The table's period at a place (`PalPitchTable`), kept from -32 to 1,920: a place below the table
    /// reads the bytes before it, the last of the square wave's, as the player has them.
    static func pitch(_ place: UInt16) -> UInt16 {
        let index = min(max(Int(Int16(bitPattern: place)), -32), 5 * 12 * 32)
        if index < 0 { return 0x4040 }
        return MusiclineTables.pitches[index]
    }
}
