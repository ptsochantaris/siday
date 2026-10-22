// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ft2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): his C port of the replayer and mixer of FastTracker 2.09, which is itself a
// direct port of that tracker's assembly and Pascal.
//
// The names are the original's, as they are in the two ports of reSID: FastTracker was written in
// Sweden and abbreviates in Swedish (ant is a count, ton a note, typ a kind, pek a pointer, nr a
// number), and a port that can be read beside its source is worth more than one that reads well alone.

/// One sample of an instrument.
struct FT2Sample {
    var len: Int32 = 0, repS: Int32 = 0, repL: Int32 = 0
    var vol: UInt8 = 0
    var fine: Int8 = 0
    var typ: UInt8 = 0, pan: UInt8 = 0
    var relTon: Int8 = 0
    /// The sample's data, eight bits or sixteen to a sample, with room after it for the mixer to read
    /// one sample past the end.
    var pek: UnsafeMutableRawPointer?
    /// For a sample in stereo, from a later tracker's file: its right side, as `pek` is then its left.
    var pekR: UnsafeMutableRawPointer?
    /// For a sample from another tracker's file, which says how fast each of its samples was
    /// recorded: the rate it is played at where FastTracker would play one of its own at 8363 Hz.
    /// Nought for FastTracker's own, which have no such thing.
    var rate: UInt32 = 0
}

/// An instrument: up to sixteen samples, which notes play which of them, and what is done to a note
/// while it sounds.
final class FT2Instrument {
    var ta = [UInt8](repeating: 0, count: 96)
    /// The volume and panning envelopes: up to twelve points each, a time and a level.
    var envVP = [Int16](repeating: 0, count: 24), envPP = [Int16](repeating: 0, count: 24)
    var envVPAnt: UInt8 = 0, envPPAnt: UInt8 = 0
    var envVSust: UInt8 = 0, envVRepS: UInt8 = 0, envVRepE: UInt8 = 0
    var envPSust: UInt8 = 0, envPRepS: UInt8 = 0, envPRepE: UInt8 = 0
    var envVTyp: UInt8 = 0, envPTyp: UInt8 = 0
    var vibTyp: UInt8 = 0, vibSweep: UInt8 = 0, vibDepth: UInt8 = 0, vibRate: UInt8 = 0
    var fadeOut: UInt16 = 0
    var mute: UInt8 = 0
    var antSamp: Int16 = 0
    var samp = [FT2Sample](repeating: FT2Sample(), count: 16)

    /// A word of the envelopes, counted from the first point of the volume envelope. A file can
    /// send FastTracker to a point beyond the twelfth, and what it reads there is whatever comes
    /// next in its memory: the other envelope, and then the instrument's settings. A tune made that
    /// way sounds as it does because of it, so the same is found here.
    func envelopeWord(_ at: Int) -> Int16 {
        func pair(_ low: UInt8, _ high: UInt8) -> Int16 { Int16(bitPattern: UInt16(low) | UInt16(high) << 8) }
        switch at {
        case 0 ..< 24: return envVP[at]
        case 24 ..< 48: return envPP[at - 24]
        case 48: return pair(envVPAnt, envPPAnt)
        case 49: return pair(envVSust, envVRepS)
        case 50: return pair(envVRepE, envPSust)
        case 51: return pair(envPRepS, envPRepE)
        case 52: return pair(envVTyp, envPTyp)
        case 53: return pair(vibTyp, vibSweep)
        case 54: return pair(vibDepth, vibRate)
        case 55: return Int16(bitPattern: fadeOut)
        case 56: return pair(mute, 0)
        case 57: return antSamp
        default: return 0
        }
    }
}

/// A channel of the song as the replayer keeps it.
final class FT2Channel {
    var status: UInt8 = 0
    var relTonNr: Int8 = 0, fineTune: Int8 = 0
    /// The note the channel was last given, with its sample's own transposing in it, counted from 1:
    /// for an arpeggio as the other trackers had it (see `FT2Player.arpeggiatesAsOtherTrackers`).
    var realNote: UInt8 = 0
    /// For a file whose X commands are ModPlug Tracker's: whether the channel is in surround (X91),
    /// and the last XAx, which 9xx starts that many times 64K further into a sample.
    var surround = false, highOffset: UInt8 = 0
    var sampleNr: UInt8 = 0, instrNr: UInt8 = 0, effTyp: UInt8 = 0, eff: UInt8 = 0, smpOffset: UInt8 = 0
    var tremorSave: UInt8 = 0, tremorPos: UInt8 = 0
    var globVolSlideSpeed: UInt8 = 0, panningSlideSpeed: UInt8 = 0, mute: UInt8 = 0, waveCtrl: UInt8 = 0, portaDir: UInt8 = 0
    var glissFunk: UInt8 = 0, vibPos: UInt8 = 0, tremPos: UInt8 = 0, vibSpeed: UInt8 = 0, vibDepth: UInt8 = 0
    var tremSpeed: UInt8 = 0, tremDepth: UInt8 = 0
    var pattPos: UInt8 = 0, loopCnt: UInt8 = 0, volSlideSpeed: UInt8 = 0, fVolSlideUpSpeed: UInt8 = 0, fVolSlideDownSpeed: UInt8 = 0
    var fPortaUpSpeed: UInt8 = 0, fPortaDownSpeed: UInt8 = 0, ePortaUpSpeed: UInt8 = 0, ePortaDownSpeed: UInt8 = 0
    var portaUpSpeed: UInt8 = 0, portaDownSpeed: UInt8 = 0, retrigSpeed: UInt8 = 0, retrigCnt: UInt8 = 0, retrigVol: UInt8 = 0
    var volKolVol: UInt8 = 0, tonNr: UInt8 = 0, envPPos: UInt8 = 0, eVibPos: UInt8 = 0, envVPos: UInt8 = 0
    var realVol: UInt8 = 0, oldVol: UInt8 = 0, outVol: UInt8 = 0
    var oldPan: UInt8 = 0, outPan: UInt8 = 0, finalPan: UInt8 = 0
    /// For a file that a later tracker made (see `FT2Player.playsLaterCommands`): a sweep from
    /// side to side, how far through its wave it is, how fast it goes and how far, which wave it
    /// is, and whether the last tick was swept.
    var sweepPos: UInt8 = 0, sweepSpeed: UInt8 = 0, sweepDepth: UInt8 = 0, sweepWave: UInt8 = 0
    var swept = false
    /// And true from X99, which puts its notes in ModPlug's reverb, until X98.
    var reverb = false
    /// And its filter: where it closes, of 127, and how it rings; whether it is on, which it is
    /// from the first setting of either until the next note, and for a note begun with it closed
    /// at all; and whether the mixer has still to be told.
    var cutoff: UInt8 = 127, resonance: UInt8 = 0
    var filtered = false, filterChanged = false
    var envSustainActive = false
    var envVIPValue: Int16 = 0, envPIPValue: Int16 = 0
    var outPeriod: UInt16 = 0, realPeriod: UInt16 = 0, finalPeriod: UInt16 = 0, finalVol: UInt16 = 0
    var tonTyp: UInt16 = 0, wantPeriod: UInt16 = 0, portaSpeed: UInt16 = 0
    var envVCnt: UInt16 = 0, envVAmp: UInt16 = 0, envPCnt: UInt16 = 0, envPAmp: UInt16 = 0, eVibAmp: UInt16 = 0, eVibSweep: UInt16 = 0
    var fadeOutAmp: UInt16 = 0, fadeOutSpeed: UInt16 = 0
    var smpStartPos: Int32 = 0
    /// The rate of the sample being played, where it has one of its own (see `FT2Sample.rate`).
    var sampleRate: UInt32 = 0
    var instrSeg: FT2Instrument
    /// Which of the mixer's channels this is.
    let nr: Int

    init(nr: Int, instrument: FT2Instrument) {
        self.nr = nr
        instrSeg = instrument
    }
}

/// A note of a pattern.
struct FT2Note {
    var ton: UInt8 = 0, instr: UInt8 = 0, vol: UInt8 = 0, effTyp: UInt8 = 0, eff: UInt8 = 0
}

/// The song as the replayer keeps it.
struct FT2Song {
    var antChn: UInt8 = 0, pattDelTime: UInt8 = 0, pattDelTime2: UInt8 = 0, pBreakPos: UInt8 = 0
    var songTab = [UInt8](repeating: 0, count: 256)
    var pBreakFlag = false, posJumpFlag = false
    var songPos: Int16 = 0, pattNr: Int16 = 0, pattPos: Int16 = 0, pattLen: Int16 = 0
    var len: UInt16 = 0, repS: UInt16 = 0, speed: UInt16 = 0, tempo: UInt16 = 0, globVol: UInt16 = 0, timer: UInt16 = 0, ver: UInt16 = 0
    var antInstrs: UInt16 = 0
}

// Flags on a channel: what of it has changed and is to be told to the mixer.
let IS_Vol: UInt8 = 1, IS_Period: UInt8 = 2, IS_NyTon: UInt8 = 4, IS_Pan: UInt8 = 8, IS_QuickVol: UInt8 = 16
let NOTE_KEYOFF: UInt8 = 97
let ENV_ENABLED: UInt8 = 1, ENV_SUSTAIN: UInt8 = 2, ENV_LOOP: UInt8 = 4
private let MAX_FRQ = 32000
private let MAX_NOTES = 10 * 12 * 16 + 16

extension FT2Player {
    // MARK: Notes

    func retrigVolume(_ ch: FT2Channel) {
        ch.realVol = ch.oldVol
        ch.outVol = ch.oldVol
        ch.outPan = ch.oldPan
        ch.status |= IS_Vol + IS_Pan + IS_QuickVol
    }

    func retrigEnvelopeVibrato(_ ch: FT2Channel) {
        // (DIGI Booster's vibrato goes on along its wave.)
        if ch.waveCtrl & 0x04 == 0, !playsAsDigiBooster { ch.vibPos = 0 }
        // FastTracker itself hangs here if the tremolo is set not to restart; the port resets it safely.
        if ch.waveCtrl & 0x40 == 0 { ch.tremPos = 0 }
        ch.retrigCnt = 0
        ch.tremorPos = 0
        ch.envSustainActive = true

        let ins = ch.instrSeg
        if ins.envVTyp & ENV_ENABLED != 0 {
            ch.envVCnt = 65535 // goes to 0 as the envelope is next handled
            ch.envVPos = 0
        }
        if ins.envPTyp & ENV_ENABLED != 0 {
            ch.envPCnt = 65535
            ch.envPPos = 0
        }
        ch.fadeOutSpeed = ins.fadeOut
        // The fade-out's range is 0 to 32768, whatever the description of the format says.
        ch.fadeOutAmp = 32768
        if ins.vibDepth > 0 {
            ch.eVibPos = 0
            if ins.vibSweep > 0 {
                ch.eVibAmp = 0
                ch.eVibSweep = UInt16(truncatingIfNeeded: (Int(ins.vibDepth) << 8) / Int(ins.vibSweep))
            } else {
                ch.eVibAmp = UInt16(ins.vibDepth) << 8
                ch.eVibSweep = 0
            }
        }
    }

    func keyOff(_ ch: FT2Channel) {
        let ins = ch.instrSeg
        // A mistake of FastTracker's: this is done when the panning envelope is off, not on.
        if ins.envPTyp & ENV_ENABLED == 0 {
            let x = ins.envelopeWord(24 + Int(ch.envPPos) * 2)
            if ch.envPCnt >= UInt16(bitPattern: x) { ch.envPCnt = UInt16(bitPattern: x &- 1) }
        }
        if ins.envVTyp & ENV_ENABLED != 0 {
            let x = ins.envelopeWord(Int(ch.envVPos) * 2)
            if ch.envVCnt >= UInt16(bitPattern: x) { ch.envVCnt = UInt16(bitPattern: x &- 1) }
        } else {
            ch.realVol = 0
            ch.outVol = 0
            ch.status |= IS_Vol + IS_QuickVol
        }
        ch.envSustainActive = false
    }

    /// A period as the mixer's step through a sample, in 65536ths.
    func getFrequenceValue(_ period: UInt16) -> UInt32 {
        if period == 0 { return 0 }
        if linearFrqTab {
            let invPeriod = UInt16(12 * 192 * 4) &- period // goes below nothing on purpose, as FastTracker does
            let quotient = UInt32(invPeriod / 768), remainder = Int(invPeriod % 768)
            let octShift = UInt32(bitPattern: 14 &- Int32(quotient)) & 31
            let delta = UInt32(truncatingIfNeeded: (Int64(ft2LogTab[remainder]) * Int64(Int32(bitPattern: frequenceMulFactor))) >> 24)
            return delta >> octShift
        }
        return frequenceDivFactor / UInt32(period)
    }

    func startTone(_ note: UInt8, _ effTyp: UInt8, _ eff: UInt8, _ ch: FT2Channel) {
        var ton = note
        if ton == NOTE_KEYOFF {
            keyOff(ch)
            return
        }
        // Coming from a retrigger, the note has not been looked at yet.
        if ton == 0 {
            ton = ch.tonNr
            if ton == 0 { return }
        }
        ch.tonNr = ton

        let ins = instr[Int(ch.instrNr)] ?? instr[0]!
        ch.instrSeg = ins
        ch.mute = ins.mute

        let smp = ins.ta[Int(ton) - 1] & 0xF
        ch.sampleNr = smp
        let s = ins.samp[Int(smp)]
        ch.relTonNr = s.relTon

        ton = ton &+ UInt8(bitPattern: ch.relTonNr)
        if ton >= 10 * 12 { return }
        ch.realNote = ton

        ch.sampleRate = s.rate
        ch.oldVol = s.vol
        // (In a module of another tracker's the place between the speakers is the channel's, not the sample's.)
        if !panningIsOfChannels {
            ch.oldPan = s.pan
            panEndsSurround(ch, always: false)
        }
        if effTyp == 0x0E, eff & 0xF0 == 0x50 {
            ch.fineTune = Int8(truncatingIfNeeded: (Int(eff & 0x0F) << 4) - 128)
        } else {
            ch.fineTune = s.fine
        }
        if ton != 0 {
            let tmpTon = ((Int(ton) - 1) << 4) + ((Int(ch.fineTune) >> 3) + 16)
            if tmpTon < MAX_NOTES {
                ch.realPeriod = notePeriod(tmpTon, ch)
                ch.outPeriod = ch.realPeriod
            }
        }
        ch.status |= IS_Period + IS_Vol + IS_Pan + IS_NyTon + IS_QuickVol

        if effTyp == 9 {
            if eff != 0 { ch.smpOffset = ch.eff }
            ch.smpStartPos = Int32(ch.smpOffset) << 8 | Int32(ch.highOffset) << 16
        } else {
            ch.smpStartPos = 0
        }
        P_StartTone(s, ch.smpStartPos, ch.nr)
    }

    // MARK: Effects on the first tick of a row

    func finePortaUp(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.fPortaUpSpeed }
        ch.fPortaUpSpeed = param
        ch.realPeriod &-= UInt16(param) << 2
        if Int16(bitPattern: ch.realPeriod) < 1 { ch.realPeriod = 1 }
        ch.outPeriod = ch.realPeriod
        ch.status |= IS_Period
    }

    func finePortaDown(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.fPortaDownSpeed }
        ch.fPortaDownSpeed = param
        ch.realPeriod &+= UInt16(param) << 2
        // Compared as a signed number, which is FastTracker's mistake.
        if Int16(bitPattern: ch.realPeriod) > Int16(MAX_FRQ - 1) { ch.realPeriod = UInt16(MAX_FRQ - 1) }
        ch.outPeriod = ch.realPeriod
        ch.status |= IS_Period
    }

    func jumpLoop(_ ch: FT2Channel, _ param: UInt8) {
        if param == 0 {
            ch.pattPos = UInt8(truncatingIfNeeded: song.pattPos)
        } else if ch.loopCnt == 0 {
            // (In DIGI Booster's, as OpenMPT plays it, a loop is not begun while another channel's is going.)
            if playsAsDigiBooster, stm.contains(where: { $0 !== ch && $0.loopCnt > 0 }) { return }
            ch.loopCnt = param
            song.pBreakPos = ch.pattPos
            song.pBreakFlag = true
            rowsWillRepeat(from: ch.pattPos)
        } else {
            ch.loopCnt &-= 1
            if ch.loopCnt > 0 {
                song.pBreakPos = ch.pattPos
                song.pBreakFlag = true
                rowsWillRepeat(from: ch.pattPos)
            }
        }
    }

    func volFineUp(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.fVolSlideUpSpeed }
        ch.fVolSlideUpSpeed = param
        ch.realVol &+= param
        if ch.realVol > 64 { ch.realVol = 64 }
        ch.outVol = ch.realVol
        ch.status |= IS_Vol
    }

    func volFineDown(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.fVolSlideDownSpeed }
        ch.fVolSlideDownSpeed = param
        ch.realVol &-= param
        if Int8(bitPattern: ch.realVol) < 0 { ch.realVol = 0 }
        ch.outVol = ch.realVol
        ch.status |= IS_Vol
    }

    func noteCut0(_ ch: FT2Channel, _ param: UInt8) {
        if param == 0 {
            ch.realVol = 0
            ch.outVol = 0
            ch.status |= IS_Vol + IS_QuickVol
        }
    }

    func E_Effects_TickZero(_ ch: FT2Channel, _ value: UInt8) {
        let param = value & 0x0F
        switch value >> 4 {
        case 0x1: finePortaUp(ch, param)
        case 0x2: finePortaDown(ch, param)
        case 0x3: ch.glissFunk = param
        // (E40 in a module of DIGI Booster's stops the note.)
        case 0x4 where playsAsDigiBooster && param == 0: digiBoosterStop(ch)
        case 0x4: ch.waveCtrl = (ch.waveCtrl & 0xF0) | param
        case 0x6: jumpLoop(ch, param)
        case 0x7: ch.waveCtrl = (param << 4) | (ch.waveCtrl & 0x0F)
        case 0xA: volFineUp(ch, param)
        case 0xB: volFineDown(ch, param)
        case 0xC: noteCut0(ch, param)
        case 0xE:
            if song.pattDelTime2 == 0 { song.pattDelTime = param &+ 1 }
        default: break
        }
    }

    func posJump(_ param: UInt8) {
        song.songPos = Int16(param) - 1
        song.pBreakPos = 0
        song.posJumpFlag = true
    }

    func pattBreak(_ value: UInt8) {
        song.posJumpFlag = true
        let param = (value >> 4) &* 10 &+ (value & 0x0F)
        song.pBreakPos = param <= 63 ? param : 0
    }

    func setSpeed(_ param: UInt8) {
        if param >= 32 {
            song.speed = UInt16(param)
            P_SetSpeed(song.speed)
            // (MultiTracker's way, for a module of its own: see `FT2Module.speedAndTempoUndoEachOther`.)
            if speedAndTempoUndoEachOther {
                song.tempo = 6
                song.timer = 6
            }
        } else {
            song.tempo = UInt16(param)
            song.timer = UInt16(param)
            if speedAndTempoUndoEachOther {
                song.speed = 125
                P_SetSpeed(song.speed)
            }
        }
    }

    func setGlobaVol(_ value: UInt8) {
        song.globVol = UInt16(min(64, value))
        for i in 0 ..< Int(song.antChn) { stm[i].status |= IS_Vol }
    }

    /// Where on an envelope a number of ticks falls: for the effect that puts an envelope there.
    private func envelopePosition(_ param: UInt8, _ ins: FT2Instrument, _ base: Int, _ ant: UInt8) -> (pos: UInt8, ipValue: Int16, amp: UInt16)? {
        var point: Int8 = 0
        var envUpdate = true
        var tick = Int16(param)
        var ipValue: Int16 = 0
        var amp: UInt16 = 0
        func x(_ i: Int8) -> Int16 { ins.envelopeWord(base + Int(i) * 2) }
        func y(_ i: Int8) -> Int16 { ins.envelopeWord(base + Int(i) * 2 + 1) }

        if ant > 1 {
            point &+= 1
            for _ in 0 ..< Int(ant) - 1 {
                if tick < x(point) {
                    point &-= 1
                    tick &-= x(point)
                    if tick == 0 { // FastTracker does not ask whether it is below nothing
                        envUpdate = false
                        break
                    }
                    let xDiff = x(point &+ 1) &- x(point)
                    if xDiff <= 0 {
                        envUpdate = true
                        break
                    }
                    let y0 = y(point), y1 = y(point &+ 1)
                    let yDiff = Int8(truncatingIfNeeded: y1 &- y0)
                    ipValue = Int16(truncatingIfNeeded: (Int(yDiff) << 8) / Int(xDiff))
                    amp = UInt16(truncatingIfNeeded: (Int(Int8(truncatingIfNeeded: y0)) << 8) + Int(Int16(truncatingIfNeeded: Int(ipValue) * (Int(tick) - 1))))
                    point &+= 1
                    envUpdate = false
                    break
                }
                point &+= 1
            }
            if envUpdate { point &-= 1 }
        }
        if envUpdate {
            ipValue = 0
            amp = UInt16(truncatingIfNeeded: Int(Int8(truncatingIfNeeded: y(point))) << 8)
        }
        if point >= Int8(truncatingIfNeeded: ant) {
            point = Int8(truncatingIfNeeded: ant) &- 1
            if point < 0 { point = 0 }
        }
        return (UInt8(bitPattern: point), ipValue, amp)
    }

    func setEnvelopePos(_ ch: FT2Channel, _ param: UInt8) {
        let ins = ch.instrSeg
        if ins.envVTyp & ENV_ENABLED != 0 {
            ch.envVCnt = UInt16(truncatingIfNeeded: Int(param) - 1)
            if let found = envelopePosition(param, ins, 0, ins.envVPAnt) {
                ch.envVPos = found.pos
                ch.envVIPValue = found.ipValue
                ch.envVAmp = found.amp
            }
        }
        // FastTracker looks at the wrong envelope's flags here, and at the wrong flag.
        if ins.envVTyp & ENV_SUSTAIN != 0 {
            ch.envPCnt = UInt16(truncatingIfNeeded: Int(param) - 1)
            if let found = envelopePosition(param, ins, 24, ins.envPPAnt) {
                ch.envPPos = found.pos
                ch.envPIPValue = found.ipValue
                ch.envPAmp = found.amp
            }
        }
    }

    // MARK: The volume column

    // On the first tick of a row. The value is handed on, changed, to a quirk of the multi-retrigger.

    func v_SetVibSpeed(_ ch: FT2Channel, _ volKol: inout UInt8) {
        volKol = (ch.volKolVol & 0x0F) << 2
        if volKol != 0 { ch.vibSpeed = volKol }
    }

    func v_Volume(_ ch: FT2Channel, _ volKol: inout UInt8) {
        volKol &-= 16
        if volKol > 64 { volKol = 64 }
        ch.realVol = volKol
        ch.outVol = volKol
        ch.status |= IS_Vol + IS_QuickVol
    }

    func v_FineSlideDown(_ ch: FT2Channel, _ volKol: inout UInt8) {
        volKol = (0 &- (ch.volKolVol & 0x0F)) &+ ch.realVol
        if Int8(bitPattern: volKol) < 0 { volKol = 0 }
        ch.realVol = volKol
        ch.outVol = volKol
        ch.status |= IS_Vol
    }

    func v_FineSlideUp(_ ch: FT2Channel, _ volKol: inout UInt8) {
        volKol = (ch.volKolVol & 0x0F) &+ ch.realVol
        if volKol > 64 { volKol = 64 }
        ch.realVol = volKol
        ch.outVol = volKol
        ch.status |= IS_Vol
    }

    func v_SetPan(_ ch: FT2Channel, _ volKol: inout UInt8) {
        panEndsSurround(ch, always: false)
        volKol <<= 4
        ch.outPan = volKol
        if panningIsOfChannels { ch.oldPan = volKol }
        ch.status |= IS_Pan
    }

    // On the ticks after the first.

    func v_SlideDown(_ ch: FT2Channel) {
        var newVol = (0 &- (ch.volKolVol & 0x0F)) &+ ch.realVol
        if Int8(bitPattern: newVol) < 0 { newVol = 0 }
        ch.realVol = newVol
        ch.outVol = newVol
        ch.status |= IS_Vol
    }

    func v_SlideUp(_ ch: FT2Channel) {
        var newVol = (ch.volKolVol & 0x0F) &+ ch.realVol
        if newVol > 64 { newVol = 64 }
        ch.realVol = newVol
        ch.outVol = newVol
        ch.status |= IS_Vol
    }

    func v_Vibrato(_ ch: FT2Channel) {
        let param = ch.volKolVol & 0xF
        if param > 0 { ch.vibDepth = param }
        vibrato2(ch)
    }

    func v_PanSlideLeft(_ ch: FT2Channel) {
        var tmp16 = UInt16(0 &- (ch.volKolVol & 0x0F)) + UInt16(ch.outPan)
        // With FastTracker's mistake in it: a slide of nothing to the left sets the panning hard left.
        if tmp16 < 256 { tmp16 = 0 }
        ch.outPan = UInt8(truncatingIfNeeded: tmp16)
        ch.status |= IS_Pan
    }

    func v_PanSlideRight(_ ch: FT2Channel) {
        let tmp16 = min(255, UInt16(ch.volKolVol & 0x0F) + UInt16(ch.outPan))
        ch.outPan = UInt8(tmp16)
        ch.status |= IS_Pan
    }

    func volumeColumnTickNonZero(_ ch: FT2Channel) {
        switch ch.volKolVol >> 4 {
        case 0x6: v_SlideDown(ch)
        case 0x7: v_SlideUp(ch)
        case 0xB: v_Vibrato(ch)
        case 0xD: v_PanSlideLeft(ch)
        case 0xE: v_PanSlideRight(ch)
        case 0xF: tonePorta(ch)
        default: break
        }
    }

    func volumeColumnTickZero(_ ch: FT2Channel, _ volKol: inout UInt8) {
        switch ch.volKolVol >> 4 {
        case 0x1, 0x2, 0x3, 0x4, 0x5: v_Volume(ch, &volKol)
        case 0x8: v_FineSlideDown(ch, &volKol)
        case 0x9: v_FineSlideUp(ch, &volKol)
        case 0xA: v_SetVibSpeed(ch, &volKol)
        case 0xC: v_SetPan(ch, &volKol)
        default: break
        }
    }

    // MARK: More effects of the first tick

    /// A channel put somewhere is taken out of surround, in a file whose X commands are ModPlug
    /// Tracker's, as OpenMPT has it: always by 8xx, and by a sample or the volume column where
    /// the file goes by FastTracker's way with them (see `FT2Module.panningEndsSurround`); never
    /// after X9B.
    func panEndsSurround(_ ch: FT2Channel, always: Bool) {
        guard ch.surround, !surroundPans, always || module.panningEndsSurround else { return }
        setSurround(ch.nr, false)
    }

    func setPan(_ ch: FT2Channel, _ param: UInt8) {
        panEndsSurround(ch, always: true)
        ch.outPan = param
        // (Where the place is the channel's, it stays there for the notes that follow.)
        if panningIsOfChannels { ch.oldPan = param }
        ch.status |= IS_Pan
    }

    func setVol(_ ch: FT2Channel, _ value: UInt8) {
        let param = min(64, value)
        ch.realVol = param
        ch.outVol = param
        ch.status |= IS_Vol + IS_QuickVol
    }

    func xFinePorta(_ ch: FT2Channel, _ value: UInt8) {
        let type = value >> 4
        var param = value & 0x0F
        // (ModPlug Tracker's own, in a file in which OpenMPT plays them: see `playsModPlugXCommands`.)
        if playsModPlugXCommands {
            switch type {
            case 0x5: ch.sweepWave = param & 7 // the wave of a sweep from side to side
            case 0x6: // ticks more on the row, added up over its channels
                song.timer &+= UInt16(param)
                frameDelay &+= UInt16(param)
            case 0x9:
                switch param {
                case 0x0, 0x1:
                    setSurround(ch.nr, param == 1)
                    if param == 1 {
                        ch.outPan = 128
                        if panningIsOfChannels { ch.oldPan = 128 }
                        ch.status |= IS_Pan
                    }
                case 0xA, 0xB: surroundPans = param == 0xB // four speakers, or two
                case 0x8, 0x9: ch.reverb = param == 9 // ModPlug's reverb, out and in
                case 0xE: playForwards(ch.nr)
                case 0xF: playBackwards(ch.nr, noteOnRow: ch.status & IS_NyTon != 0)
                default: break
                }
            case 0xA:
                ch.highOffset = param
                if ch.status & IS_NyTon != 0 { startHigh(ch.nr, param) }
            default: break
            }
        }
        if type == 0x1 {
            if param == 0 { param = ch.ePortaUpSpeed }
            ch.ePortaUpSpeed = param
            var newPeriod = ch.realPeriod &- UInt16(param)
            if Int16(bitPattern: newPeriod) < 1 { newPeriod = 1 }
            ch.realPeriod = newPeriod
            ch.outPeriod = newPeriod
            ch.status |= IS_Period
        } else if type == 0x2 {
            if param == 0 { param = ch.ePortaDownSpeed }
            ch.ePortaDownSpeed = param
            var newPeriod = ch.realPeriod &+ UInt16(param)
            if Int16(bitPattern: newPeriod) > Int16(MAX_FRQ - 1) { newPeriod = UInt16(MAX_FRQ - 1) }
            ch.realPeriod = newPeriod
            ch.outPeriod = newPeriod
            ch.status |= IS_Period
        }
    }

    func doMultiRetrig(_ ch: FT2Channel) {
        let cnt = ch.retrigCnt &+ 1
        if cnt < ch.retrigSpeed {
            ch.retrigCnt = cnt
            return
        }
        ch.retrigCnt = 0

        var vol = Int(ch.realVol)
        switch ch.retrigVol {
        case 0x1: vol -= 1
        case 0x2: vol -= 2
        case 0x3: vol -= 4
        case 0x4: vol -= 8
        case 0x5: vol -= 16
        case 0x6: vol = (vol >> 1) + (vol >> 3) + (vol >> 4)
        case 0x7: vol >>= 1
        case 0x9: vol += 1
        case 0xA: vol += 2
        case 0xB: vol += 4
        case 0xC: vol += 8
        case 0xD: vol += 16
        case 0xE: vol = (vol >> 1) + vol
        case 0xF: vol += vol
        default: break
        }
        vol = max(0, min(64, vol))
        ch.realVol = UInt8(vol)
        ch.outVol = ch.realVol

        if ch.volKolVol >= 0x10, ch.volKolVol <= 0x50 {
            ch.outVol = ch.volKolVol - 0x10
            ch.realVol = ch.outVol
        } else if ch.volKolVol >= 0xC0, ch.volKolVol <= 0xCF {
            ch.outPan = (ch.volKolVol & 0x0F) << 4
        }
        startTone(0, 0, 0, ch)
    }

    func multiRetrig(_ ch: FT2Channel, _ param: UInt8, _ volumeColumnData: UInt8) {
        var tmpParam = param & 0x0F
        if tmpParam == 0 { tmpParam = ch.retrigSpeed }
        ch.retrigSpeed = tmpParam
        tmpParam = param >> 4
        if tmpParam == 0 { tmpParam = ch.retrigVol }
        ch.retrigVol = tmpParam
        if volumeColumnData == 0 { doMultiRetrig(ch) }
    }

    /// The effects of the first tick of a row.
    func checkEffects(_ ch: FT2Channel) {
        // What the volume column leaves of its value decides whether a multi-retrigger fires: a quirk.
        var newVolKol = ch.volKolVol
        volumeColumnTickZero(ch, &newVolKol)

        let param = ch.eff
        if playsLaterCommands, ch.effTyp == 36 { sendFilterMacro(ch, param, comingTo: true) }
        if (ch.effTyp == 0 && param == 0) || ch.effTyp > 35 { return }
        switch ch.effTyp {
        // (DIGI Booster's arpeggio and tremolo are heard on the row's first tick too.)
        case 0: if playsAsDigiBooster { digiBoosterArpeggio(ch, param) }
        case 7:
            if playsAsDigiBooster {
                setTremolo(ch, param)
                digiBoosterTremolo(ch, movesOn: false)
            }
        case 35: if playsLaterCommands { sendFilterMacro(ch, param, comingTo: false) }
        case 27: multiRetrig(ch, param, newVolKol)
        case 8: setPan(ch, param)
        case 11: posJump(param)
        case 12: setVol(ch, param)
        case 13: pattBreak(param)
        case 14: E_Effects_TickZero(ch, param)
        case 15: setSpeed(param)
        case 16: setGlobaVol(param)
        case 21: setEnvelopePos(ch, param)
        case 33: xFinePorta(ch, param)
        case 34:
            // Yxy in a later tracker's file: a sweep from side to side, x its speed and y its depth,
            // and a digit of nothing the last there was.
            if playsLaterCommands {
                if param & 0x0F != 0 { ch.sweepDepth = param & 0x0F }
                if param & 0xF0 != 0 { ch.sweepSpeed = param >> 4 }
            }
        default: break
        }
    }

    /// Zxx in a file that a later tracker made, and the command after it: a macro, which is how
    /// such a file sets a channel's filter, as OpenMPT plays one in an XM file.
    /// - Parameter comingTo: true for the command after Z, which is sent on every tick of its row
    ///   and brings the filter only as far towards what the macro sets as the ticks left of the
    ///   row allow: a part of the way that is one over their number.
    func sendFilterMacro(_ ch: FT2Channel, _ param: UInt8, comingTo: Bool) {
        guard let macro = module.filterMacros[Int(param)] else { return }
        let value = macro.value ?? param
        guard value < 0x80 else { return }
        let left = Int(song.timer)
        func nearer(_ from: UInt8) -> UInt8 {
            guard comingTo, left > 1 else { return value }
            return UInt8(max(0, min(127, Int((Float(from) + Float(Int(value) - Int(from)) / Float(left)).rounded()))))
        }
        if macro.sets == 0 { ch.cutoff = nearer(ch.cutoff) } else { ch.resonance = nearer(ch.resonance) }
        ch.filtered = true
        ch.filterChanged = true
    }

    /// A sweep from side to side, in a file that a later tracker made, as OpenMPT plays one in an
    /// XM file: on every tick of a row that has the command, the channel is moved from where it
    /// is by the wave's height there (of 127) times the depth, over eight; and the wave is gone
    /// through a quarter as fast as the speed says, of the 64 places it has.
    func sweepFromSideToSide(_ ch: FT2Channel) {
        guard ch.effTyp == 34 else {
            // (Where it was before the sweep is where it is again, and the mixer is told so.)
            if ch.swept { ch.status |= IS_Pan }
            ch.swept = false
            return
        }
        let place = ((Int(ch.sweepPos) + 0x10) >> 2) & 0x3F
        let height: Int
        switch ch.sweepWave & 3 {
        case 1: height = (place < 32 ? 0 : 255) - place * 4
        case 2: height = place < 32 ? 127 : -127
        case 3: height = Int(ft2SweepRandom[place])
        default: height = Int(ft2SweepSine[place])
        }
        ch.sweepPos &+= ch.sweepSpeed
        ch.finalPan = UInt8(max(0, min(255, Int(ch.finalPan) + (height * Int(ch.sweepDepth) + 2) / 8)))
        ch.status |= IS_Pan
        ch.swept = true
    }

    func fixTonePorta(_ ch: FT2Channel, _ p: FT2Note, _ inst: UInt8) {
        if p.ton > 0 {
            if p.ton == NOTE_KEYOFF {
                keyOff(ch)
            } else {
                let portaTmp = UInt16(truncatingIfNeeded: (((Int(p.ton) - 1) + Int(ch.relTonNr)) << 4) + ((Int(ch.fineTune) >> 3) + 16))
                ch.realNote = UInt8(max(1, min(10 * 12 - 1, Int(p.ton) + Int(ch.relTonNr))))
                if portaTmp < UInt16(MAX_NOTES) {
                    ch.wantPeriod = notePeriod(Int(portaTmp), ch)
                    if ch.wantPeriod == ch.realPeriod {
                        ch.portaDir = 0
                    } else if ch.wantPeriod > ch.realPeriod {
                        ch.portaDir = 1
                    } else {
                        ch.portaDir = 2
                    }
                }
            }
        }
        if inst > 0 {
            retrigVolume(ch)
            if p.ton != NOTE_KEYOFF { retrigEnvelopeVibrato(ch) }
        }
    }

    /// A row's note for a channel, on the first tick of the row.
    func getNewNote(_ ch: FT2Channel, _ p: FT2Note) {
        ch.volKolVol = p.vol
        if ch.effTyp == 0 {
            // An arpeggio was running: back to the note itself.
            if ch.eff != 0 {
                ch.outPeriod = ch.realPeriod
                ch.status |= IS_Period
            }
        } else if (ch.effTyp == 4 || ch.effTyp == 6) && (p.effTyp != 4 && p.effTyp != 6 || playsAsDigiBooster) {
            // And so for a vibrato that ends with the row before. (DIGI Booster's is at the note
            // itself on every row's first tick.)
            ch.outPeriod = ch.realPeriod
            ch.status |= IS_Period
        }

        ch.effTyp = p.effTyp
        ch.eff = p.eff
        ch.tonTyp = UInt16(p.instr) << 8 | UInt16(p.ton)

        var inst = p.instr
        if inst > 0 {
            if inst <= 128 {
                ch.instrNr = inst
            } else {
                inst = 0
            }
        }

        var checkEfx = true
        if p.effTyp == 0x0E {
            if p.eff >= 0xD1, p.eff <= 0xDF { return } // a delayed note is not for now
            if p.eff == 0x90 { checkEfx = false } // a retrigger with nothing to count
        }

        if checkEfx {
            if ch.volKolVol & 0xF0 == 0xF0 {
                let volKolParam = ch.volKolVol & 0x0F
                if volKolParam > 0 { ch.portaSpeed = UInt16(volKolParam) << 6 }
                fixTonePorta(ch, p, inst)
                checkEffects(ch)
                return
            }
            if p.effTyp == 3 || p.effTyp == 5 {
                if p.effTyp != 5, p.eff != 0 { ch.portaSpeed = UInt16(p.eff) << 2 }
                fixTonePorta(ch, p, inst)
                checkEffects(ch)
                return
            }
            if p.effTyp == 0x14, p.eff == 0 {
                keyOff(ch)
                if inst != 0 { retrigVolume(ch) }
                checkEffects(ch)
                return
            }
            if p.ton == 0 {
                if inst > 0 {
                    retrigVolume(ch)
                    retrigEnvelopeVibrato(ch)
                }
                checkEffects(ch)
                return
            }
        }

        if p.ton == NOTE_KEYOFF {
            keyOff(ch)
        } else {
            startTone(p.ton, p.effTyp, p.eff, ch)
        }
        if inst > 0 {
            retrigVolume(ch)
            if p.ton != NOTE_KEYOFF { retrigEnvelopeVibrato(ch) }
        }
        checkEffects(ch)
    }

    // MARK: Envelopes and the instrument's own vibrato

    /// Moves an envelope on by a tick and gives its level, in 256ths.
    private func stepEnvelope(_ ins: FT2Instrument, _ base: Int, _ typ: UInt8, _ ant: UInt8, _ sust: UInt8, _ repS: UInt8, _ repE: UInt8, _ sustainActive: Bool,
                              cnt: inout UInt16, pos: inout UInt8, amp: inout UInt16, ip: inout Int16) -> Int16
    {
        func x(_ i: Int) -> Int16 { ins.envelopeWord(base + i * 2) }
        func y(_ i: Int) -> Int16 { ins.envelopeWord(base + i * 2 + 1) }
        func level(_ i: Int) -> UInt16 { UInt16(truncatingIfNeeded: Int(Int8(truncatingIfNeeded: y(i))) << 8) }
        var envVal: Int16 = 0
        var envDidInterpolate = false
        var envPos = pos

        cnt &+= 1
        if Int(cnt) == Int(x(Int(envPos))) {
            amp = level(Int(envPos))
            envPos &+= 1
            if typ & ENV_LOOP != 0 {
                envPos &-= 1
                if envPos == repE, typ & ENV_SUSTAIN == 0 || envPos != sust || sustainActive {
                    envPos = repS
                    cnt = UInt16(bitPattern: x(Int(envPos)))
                    amp = level(Int(envPos))
                }
                envPos &+= 1
            }

            if envPos < ant {
                var envInterpolateFlag = true
                if typ & ENV_SUSTAIN != 0, sustainActive, Int(envPos) - 1 == Int(sust) {
                    envPos &-= 1
                    ip = 0
                    envInterpolateFlag = false
                }
                if envInterpolateFlag {
                    pos = envPos
                    let xDiff = x(Int(envPos)) &- x(Int(envPos) - 1)
                    if xDiff > 0 {
                        let yDiff = Int8(truncatingIfNeeded: y(Int(envPos)) &- y(Int(envPos) - 1))
                        ip = Int16(truncatingIfNeeded: (Int(yDiff) << 8) / Int(xDiff))
                        envVal = Int16(bitPattern: amp)
                        envDidInterpolate = true
                    } else {
                        ip = 0
                    }
                }
            } else {
                ip = 0
            }
        }

        if !envDidInterpolate {
            amp &+= UInt16(bitPattern: ip)
            envVal = Int16(bitPattern: amp)
            // FastTracker tests the upper byte, and as an unsigned one.
            let envHiByte = UInt8(truncatingIfNeeded: envVal >> 8)
            if envHiByte > 64 {
                envVal = envHiByte <= 160 ? 64 * 256 : 0
                ip = 0
            }
        }
        return envVal
    }

    /// What a channel finally sounds like on this tick: its volume, panning and period after the
    /// instrument's envelopes, its fade-out and its own vibrato.
    func fixaEnvelopeVibrato(_ ch: FT2Channel) {
        let ins = ch.instrSeg

        if !ch.envSustainActive {
            ch.status |= IS_Vol
            if ch.fadeOutSpeed > ch.fadeOutAmp {
                ch.fadeOutAmp = 0
                ch.fadeOutSpeed = 0
            } else {
                ch.fadeOutAmp -= ch.fadeOutSpeed
            }
        }

        if ch.mute == 0 {
            var vol: UInt32
            if ins.envVTyp & ENV_ENABLED != 0 {
                var envVal = stepEnvelope(ins, 0, ins.envVTyp, ins.envVPAnt, ins.envVSust, ins.envVRepS, ins.envVRepE, ch.envSustainActive,
                                          cnt: &ch.envVCnt, pos: &ch.envVPos, amp: &ch.envVAmp, ip: &ch.envVIPValue)
                envVal >>= 8
                vol = UInt32(bitPattern: (Int32(envVal) &* Int32(ch.outVol) &* Int32(ch.fadeOutAmp)) >> (16 + 2))
                vol = (vol &* UInt32(song.globVol)) >> 7
                ch.status |= IS_Vol // with an envelope, the volume is told to the mixer on every tick
            } else {
                vol = UInt32((Int32(ch.outVol) << 4) &* Int32(ch.fadeOutAmp)) >> 16
                vol = (vol &* UInt32(song.globVol)) >> 7
            }
            ch.finalVol = UInt16(truncatingIfNeeded: vol) // 0 to 256
        } else {
            ch.finalVol = 0
        }

        if ins.envPTyp & ENV_ENABLED != 0 {
            var envVal = stepEnvelope(ins, 24, ins.envPTyp, ins.envPPAnt, ins.envPSust, ins.envPRepS, ins.envPRepE, ch.envSustainActive,
                                      cnt: &ch.envPCnt, pos: &ch.envPPos, amp: &ch.envPAmp, ip: &ch.envPIPValue)
            var panTmp = Int16(ch.outPan) - 128
            if panTmp > 0 { panTmp = 0 - panTmp }
            panTmp += 128
            panTmp <<= 3
            envVal &-= 32 * 256
            let panAdd = Int8(truncatingIfNeeded: (Int32(envVal) * Int32(panTmp)) >> 16)
            ch.finalPan = UInt8(truncatingIfNeeded: Int(ch.outPan) + Int(panAdd))
            ch.status |= IS_Pan
        } else {
            ch.finalPan = ch.outPan
        }
        if playsLaterCommands { sweepFromSideToSide(ch) }

        if ins.vibDepth > 0 {
            var autoVibAmp: UInt16
            if ch.eVibSweep > 0 {
                autoVibAmp = ch.eVibSweep
                if ch.envSustainActive {
                    autoVibAmp &+= ch.eVibAmp
                    if autoVibAmp >> 8 > UInt16(ins.vibDepth) {
                        autoVibAmp = UInt16(ins.vibDepth) << 8
                        ch.eVibSweep = 0
                    }
                    ch.eVibAmp = autoVibAmp
                }
            } else {
                autoVibAmp = ch.eVibAmp
            }
            ch.eVibPos &+= ins.vibRate

            var autoVibVal: Int16
            switch ins.vibTyp {
            case 1: autoVibVal = ch.eVibPos > 127 ? 64 : -64
            case 2: autoVibVal = Int16(((Int(ch.eVibPos >> 1) + 64) & 127) - 64)
            case 3: autoVibVal = Int16(((-Int(ch.eVibPos >> 1) + 64) & 127) - 64)
            default: autoVibVal = Int16(ft2VibSineTab[Int(ch.eVibPos)])
            }
            autoVibVal <<= 2
            var tmpPeriod = UInt16(truncatingIfNeeded: (Int32(autoVibVal) * Int32(Int16(bitPattern: autoVibAmp))) >> 16)
            tmpPeriod &+= ch.outPeriod
            if tmpPeriod >= UInt16(MAX_FRQ) { tmpPeriod = 0 } // yes, FastTracker does this
            ch.finalPeriod = tmpPeriod
            ch.status |= IS_Period
        } else {
            ch.finalPeriod = ch.outPeriod
        }
    }

    // MARK: Effects of the ticks after the first

    /// The period of the note a period is nearest, a number of semitones up: for arpeggio, and for a
    /// portamento that goes by semitones.
    func relocateTon(_ period: UInt16, _ arpNote: UInt8, _ ch: FT2Channel) -> UInt16 {
        let fineTune = (Int(ch.fineTune) >> 3) + 16
        // FastTracker's mistake: this should be ten octaves, and notes above the eighth go wrong.
        var hiPeriod = 8 * 12 * 16
        var loPeriod = 0
        for _ in 0 ..< 8 {
            let tmpPeriod = (((loPeriod + hiPeriod) >> 1) & ~15) + fineTune
            let lookUp = max(0, tmpPeriod - 8)
            if period >= note2Period(lookUp) {
                hiPeriod = (tmpPeriod - fineTune) & ~15
            } else {
                loPeriod = (tmpPeriod - fineTune) & ~15
            }
        }
        var tmpPeriod = loPeriod + fineTune + (Int(arpNote) << 4)
        if tmpPeriod >= (8 * 12 * 16 + 15) - 1 { tmpPeriod = (8 * 12 * 16 + 16) - 1 }
        return notePeriod(tmpPeriod, ch)
    }

    func vibrato2(_ ch: FT2Channel) {
        if playsAsDigiBooster { return digiBoosterVibrato(ch) }
        var tmpVib = (ch.vibPos >> 2) & 0x1F
        switch ch.waveCtrl & 3 {
        case 0: tmpVib = ft2VibTab[Int(tmpVib)]
        case 1:
            tmpVib <<= 3
            if Int8(bitPattern: ch.vibPos) < 0 { tmpVib = ~tmpVib }
        default: tmpVib = 255
        }
        tmpVib = UInt8(truncatingIfNeeded: (Int(tmpVib) * Int(ch.vibDepth)) >> vibratoShift)
        if Int8(bitPattern: ch.vibPos) < 0 {
            ch.outPeriod = ch.realPeriod &- UInt16(tmpVib)
        } else {
            ch.outPeriod = ch.realPeriod &+ UInt16(tmpVib)
        }
        ch.status |= IS_Period
        ch.vibPos &+= ch.vibSpeed
    }

    func arp(_ ch: FT2Channel, _ param: UInt8) {
        if arpeggiatesAsOtherTrackers { return arpAsOtherTrackers(ch, param) }
        // FastTracker's table has sixteen entries and is read beyond them; what it finds there is here.
        let tick = ft2ArpTab[Int(song.timer & 0xFF)]
        if tick == 0 {
            ch.outPeriod = ch.realPeriod
        } else {
            ch.outPeriod = relocateTon(ch.realPeriod, tick == 1 ? param >> 4 : param & 0x0F, ch)
        }
        ch.status |= IS_Period
    }

    /// An arpeggio as the trackers other than FastTracker had it, as OpenMPT plays it for their XM
    /// files: by the ticks of the row counted up, nought, the first digit and the second, and so
    /// round again, where FastTracker counts them down and goes the other way round at most speeds;
    /// and up from the note the channel was given, not from the nearest note to where a slide has
    /// taken it; on the ticks between, the pitch is where it was.
    private func arpAsOtherTrackers(_ ch: FT2Channel, _ param: UInt8) {
        let tick = Int(ticksIn) % 3
        let up = tick == 1 ? Int(param >> 4) : tick == 2 ? Int(param & 0x0F) : 0
        if up == 0 || ch.realNote == 0 {
            ch.outPeriod = ch.realPeriod
        } else {
            let tmpTon = ((Int(ch.realNote) + up - 1) << 4) + ((Int(ch.fineTune) >> 3) + 16)
            ch.outPeriod = notePeriod(min(tmpTon, MAX_NOTES - 1), ch)
        }
        ch.status |= IS_Period
    }

    func portaUp(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.portaUpSpeed }
        ch.portaUpSpeed = param
        // (DIGI Booster's slides up and down remember one value between them.)
        if playsAsDigiBooster { ch.portaDownSpeed = param }
        ch.realPeriod &-= UInt16(param) << 2
        if Int16(bitPattern: ch.realPeriod) < 1 { ch.realPeriod = 1 }
        ch.outPeriod = ch.realPeriod
        ch.status |= IS_Period
    }

    func portaDown(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.portaDownSpeed }
        ch.portaDownSpeed = param
        if playsAsDigiBooster { ch.portaUpSpeed = param }
        ch.realPeriod &+= UInt16(param) << 2
        if Int16(bitPattern: ch.realPeriod) > Int16(MAX_FRQ - 1) { ch.realPeriod = UInt16(MAX_FRQ - 1) }
        ch.outPeriod = ch.realPeriod
        ch.status |= IS_Period
    }

    func tonePorta(_ ch: FT2Channel) {
        if ch.portaDir == 0 { return }
        if ch.portaDir > 1 {
            ch.realPeriod &-= ch.portaSpeed
            if Int16(bitPattern: ch.realPeriod) <= Int16(bitPattern: ch.wantPeriod) {
                ch.portaDir = 1
                ch.realPeriod = ch.wantPeriod
            }
        } else {
            ch.realPeriod &+= ch.portaSpeed
            if ch.realPeriod >= ch.wantPeriod {
                ch.portaDir = 1
                ch.realPeriod = ch.wantPeriod
            }
        }
        ch.outPeriod = ch.glissFunk != 0 ? relocateTon(ch.realPeriod, 0, ch) : ch.realPeriod
        ch.status |= IS_Period
    }

    func vibrato(_ ch: FT2Channel, _ param: UInt8) {
        if ch.eff > 0 {
            var tmp8 = param & 0x0F
            if tmp8 > 0 { ch.vibDepth = tmp8 }
            tmp8 = (param & 0xF0) >> 2
            if tmp8 > 0 { ch.vibSpeed = tmp8 }
        }
        vibrato2(ch)
    }

    func setTremolo(_ ch: FT2Channel, _ param: UInt8) {
        if param > 0 {
            var tmp8 = param & 0x0F
            if tmp8 > 0 { ch.tremDepth = tmp8 }
            tmp8 = (param & 0xF0) >> 2
            if tmp8 > 0 { ch.tremSpeed = tmp8 }
        }
    }

    func tremolo(_ ch: FT2Channel, _ param: UInt8) {
        setTremolo(ch, param)
        if playsAsDigiBooster { return digiBoosterTremolo(ch, movesOn: true) }
        var tmpTrem = (ch.tremPos >> 2) & 0x1F
        switch (ch.waveCtrl >> 4) & 3 {
        case 0: tmpTrem = ft2VibTab[Int(tmpTrem)]
        case 1:
            tmpTrem <<= 3
            // FastTracker looks at the vibrato's place here where it means the tremolo's.
            if Int8(bitPattern: ch.vibPos) < 0 { tmpTrem = ~tmpTrem }
        default: tmpTrem = 255
        }
        tmpTrem = UInt8(truncatingIfNeeded: (Int(tmpTrem) * Int(ch.tremDepth)) >> 6)

        let tremVol: Int
        if Int8(bitPattern: ch.tremPos) < 0 {
            tremVol = max(0, Int(ch.realVol) - Int(tmpTrem))
        } else {
            tremVol = min(64, Int(ch.realVol) + Int(tmpTrem))
        }
        ch.outVol = UInt8(truncatingIfNeeded: tremVol)
        ch.status |= IS_Vol
        ch.tremPos &+= ch.tremSpeed
    }

    /// A volume slide.
    func volume(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.volSlideSpeed }
        ch.volSlideSpeed = param
        var newVol = ch.realVol
        if param & 0xF0 == 0 {
            newVol &-= param
            if Int8(bitPattern: newVol) < 0 { newVol = 0 }
        } else {
            newVol &+= param >> 4
            if newVol > 64 { newVol = 64 }
        }
        ch.realVol = newVol
        ch.outVol = newVol
        ch.status |= IS_Vol
    }

    func globalVolSlide(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.globVolSlideSpeed }
        ch.globVolSlideSpeed = param
        var newVol = UInt8(truncatingIfNeeded: song.globVol)
        if param & 0xF0 == 0 {
            newVol &-= param
            if Int8(bitPattern: newVol) < 0 { newVol = 0 }
        } else {
            newVol &+= param >> 4
            if newVol > 64 { newVol = 64 }
        }
        song.globVol = UInt16(newVol)
        for i in 0 ..< Int(song.antChn) { stm[i].status |= IS_Vol }
    }

    /// How many ticks of the row have gone.
    /// How many ticks of the row have gone, counting those X6x added.
    private var ticksIn: UInt8 { UInt8(truncatingIfNeeded: song.tempo &+ frameDelay &- song.timer) }

    func keyOffCmd(_ ch: FT2Channel, _ param: UInt8) {
        if ticksIn == param & 31 { keyOff(ch) }
    }

    func panningSlide(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.panningSlideSpeed }
        ch.panningSlideSpeed = param
        var newPan = Int(ch.outPan)
        if param & 0xF0 == 0 {
            newPan = max(0, newPan - Int(param))
        } else {
            newPan = min(255, newPan + Int(param >> 4))
        }
        ch.outPan = UInt8(newPan)
        ch.status |= IS_Pan
    }

    func tremor(_ ch: FT2Channel, _ value: UInt8) {
        var param = value
        if param == 0 { param = ch.tremorSave }
        ch.tremorSave = param
        var tremorSign = ch.tremorPos & 0x80
        var tremorData = ch.tremorPos & 0x7F
        tremorData &-= 1
        if Int8(bitPattern: tremorData) < 0 {
            if tremorSign == 0x80 {
                tremorSign = 0x00
                tremorData = param & 0x0F
            } else {
                tremorSign = 0x80
                tremorData = param >> 4
            }
        }
        ch.tremorPos = tremorSign | tremorData
        ch.outVol = tremorSign == 0x80 ? ch.realVol : 0
        ch.status |= IS_Vol + IS_QuickVol
    }

    func retrigNote(_ ch: FT2Channel, _ param: UInt8) {
        if param == 0 { return } // with nothing to count, it was done as the row was read
        if Int(ticksIn) % Int(param) == 0 {
            startTone(0, 0, 0, ch)
            retrigEnvelopeVibrato(ch)
        }
    }

    func noteCut(_ ch: FT2Channel, _ param: UInt8) {
        if ticksIn == param {
            ch.realVol = 0
            ch.outVol = 0
            ch.status |= IS_Vol + IS_QuickVol
        }
    }

    func noteDelay(_ ch: FT2Channel, _ param: UInt8) {
        guard ticksIn == param else { return }
        startTone(UInt8(ch.tonTyp & 0xFF), 0, 0, ch)
        if ch.tonTyp & 0xFF00 > 0 { retrigVolume(ch) }
        retrigEnvelopeVibrato(ch)
        if ch.volKolVol >= 0x10, ch.volKolVol <= 0x50 {
            ch.outVol = ch.volKolVol - 16
            ch.realVol = ch.outVol
        } else if ch.volKolVol >= 0xC0, ch.volKolVol <= 0xCF {
            ch.outPan = (ch.volKolVol & 0x0F) << 4
        }
    }

    /// The effects of the ticks after the first.
    func doEffects(_ ch: FT2Channel) {
        if ch.volKolVol >> 4 > 0 { volumeColumnTickNonZero(ch) }
        if playsLaterCommands, ch.effTyp == 36 { sendFilterMacro(ch, ch.eff, comingTo: true) }
        if (ch.eff == 0 && ch.effTyp == 0) || ch.effTyp > 35 { return }
        let param = ch.eff
        switch ch.effTyp {
        case 0: if playsAsDigiBooster { digiBoosterArpeggio(ch, param) } else { arp(ch, param) }
        case 1: portaUp(ch, param)
        case 2: portaDown(ch, param)
        case 3: tonePorta(ch)
        case 4: vibrato(ch, param)
        case 5:
            tonePorta(ch)
            volume(ch, param)
        case 6:
            vibrato2(ch)
            volume(ch, param)
        case 7: tremolo(ch, param)
        case 10: volume(ch, param)
        case 14:
            switch param >> 4 {
            case 0x9: retrigNote(ch, param & 0xF)
            case 0xC: noteCut(ch, param & 0xF)
            case 0xD: noteDelay(ch, param & 0xF)
            default: break
            }
        case 17: globalVolSlide(ch, param)
        case 20: keyOffCmd(ch, param)
        case 25: panningSlide(ch, param)
        case 27: doMultiRetrig(ch)
        case 29: tremor(ch, param)
        default: break
        }
    }

    // MARK: The song

    func getNextPos() {
        song.pattPos += 1
        if song.pattDelTime > 0 {
            song.pattDelTime2 = song.pattDelTime
            song.pattDelTime = 0
        }
        if song.pattDelTime2 > 0 {
            song.pattDelTime2 -= 1
            if song.pattDelTime2 > 0 { song.pattPos -= 1 }
        }
        if song.pBreakFlag {
            song.pBreakFlag = false
            song.pattPos = Int16(song.pBreakPos)
            // FastTracker goes on remembering the row, and starts the next pattern on it: a mistake
            // of its own, which a module from another tracker was not written around.
            if loopsLeaveNothingBehind, !song.posJumpFlag { song.pBreakPos = 0 }
        }
        if song.pattPos >= song.pattLen || song.posJumpFlag {
            song.pattPos = Int16(song.pBreakPos)
            song.pBreakPos = 0
            song.posJumpFlag = false
            song.songPos &+= 1
            if song.songPos >= Int16(bitPattern: song.len) {
                song.songPos = Int16(bitPattern: song.repS)
                offTheEnd = true
            }
            song.pattNr = Int16(song.songTab[Int(UInt8(truncatingIfNeeded: song.songPos))])
            song.pattLen = Int16(bitPattern: module.pattLens[Int(UInt8(truncatingIfNeeded: song.pattNr))])
        }
    }

    /// One tick of the song.
    func mainPlayer() {
        var tickZero = false
        song.timer &-= 1
        if song.timer == 0 {
            song.timer = song.tempo
            frameDelay = 0
            tickZero = true
        }

        // (A song that is over reads no more rows, and its notes go on as they are, envelopes and all.)
        if over {
            for i in 0 ..< Int(song.antChn) { fixaEnvelopeVibrato(stm[i]) }
            return
        }
        if tickZero, song.pattDelTime2 == 0 {
            rowIsRead()
            if over {
                for i in 0 ..< Int(song.antChn) { fixaEnvelopeVibrato(stm[i]) }
                return
            }
            let row = module.patt[Int(UInt8(truncatingIfNeeded: song.pattNr))]
            let first = Int(song.pattPos) * Int(song.antChn)
            for i in 0 ..< Int(song.antChn) {
                let note = row.map { first + i < $0.count ? $0[first + i] : FT2Note() } ?? FT2Note()
                if note.ton >= 1, note.ton <= 96 { playedNote = true }
                getNewNote(stm[i], note)
                fixaEnvelopeVibrato(stm[i])
            }
        } else {
            for i in 0 ..< Int(song.antChn) {
                doEffects(stm[i])
                fixaEnvelopeVibrato(stm[i])
            }
        }
        if song.timer == 1 { getNextPos() }
    }
}
