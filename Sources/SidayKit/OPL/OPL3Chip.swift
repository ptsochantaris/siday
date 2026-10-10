// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A Swift port of Nuked OPL3 1.8, Copyright (C) 2013-2020 Nuke.YKT, which is free software under
// the GNU Lesser General Public License, version 2.1 or any later version, and is used here under
// the GNU General Public License as that licence allows (see THIRD-PARTY.md). Its own thanks:
//
//      MAME Development Team (Jarek Burczynski, Tatsuyuki Satoh):
//          Feedback and Rhythm part calculation information.
//      forums.submarine.org.uk (carbon14, opl3):
//          Tremolo and phase generator calculation information.
//      OPLx decapsulated (Matthew Gambrell, Olli Niemitalo):
//          OPL2 ROMs.
//      siliconpr0n.org (John McMaster, digshadow):
//          YMF262 and VRC VII decaps and die shots.
//
// The names are the original's, as in the other ports here.

/// Yamaha's YMF262, the OPL3: the FM chip of the Sound Blaster 16 and its kind, which also plays
/// everything written for the chip before it, the YM3812 or OPL2 of the AdLib card and the first
/// Sound Blasters.
///
/// It has thirty-six operators, each a sine wave read from a table of logarithms, shaped by an
/// envelope and able to bend the phase of another. They are paired into eighteen channels of two, six
/// of which can be joined into channels of four, and three of the first nine can be turned into five
/// drums. Until it is told otherwise it behaves as an OPL2: nine channels, four waveforms and one
/// output. This is a model of the chip itself, made by its author from the chip's own ROMs and
/// circuits, and gives the numbers the chip gives.
///
/// The chip makes one sample for every 288 ticks of its 14.318 MHz clock, which is 49,716 a second;
/// bringing that to another rate is left to whoever uses it.
struct OPL3Chip: ~Copyable {
    /// The samples a second the chip makes: the clock of the PC's bus, 157.5 MHz / 11, over 288.
    static let rate = 157_500_000.0 / 11.0 / 288.0

    struct Slot {
        var channel: UnsafeMutablePointer<Channel>
        /// What it gives out, and what of that it feeds back into itself.
        let out: UnsafeMutablePointer<Int16>, fbmod: UnsafeMutablePointer<Int16>
        var mod: UnsafeMutablePointer<Int16>
        var prout: Int16 = 0
        var eg_rout: UInt16 = 0x1FF, eg_out: UInt16 = 0x1FF
        var eg_gen: UInt8 = OPL3Chip.envelope_gen_num_release
        var eg_ksl: UInt8 = 0
        var trem: UnsafeMutablePointer<UInt8>
        var reg_vib: UInt8 = 0, reg_type: UInt8 = 0, reg_ksr: UInt8 = 0, reg_mult: UInt8 = 0, reg_ksl: UInt8 = 0, reg_tl: UInt8 = 0
        var reg_ar: UInt8 = 0, reg_dr: UInt8 = 0, reg_sl: UInt8 = 0, reg_rr: UInt8 = 0, reg_wf: UInt8 = 0
        var key: UInt8 = 0
        var pg_reset = false
        var pg_phase: UInt32 = 0
        var pg_phase_out: UInt16 = 0
        let slot_num: UInt8
    }

    struct Channel {
        var slotz: (UnsafeMutablePointer<Slot>, UnsafeMutablePointer<Slot>)
        /// The channel it makes four operators with, for those that can.
        var pair: UnsafeMutablePointer<Channel>
        var out: (UnsafeMutablePointer<Int16>, UnsafeMutablePointer<Int16>, UnsafeMutablePointer<Int16>, UnsafeMutablePointer<Int16>)
        var chtype: UInt8 = OPL3Chip.ch_2op
        var f_num: UInt16 = 0, f_num_reg: UInt16 = 0
        var block: UInt8 = 0, block_reg: UInt8 = 0
        var fb: UInt8 = 0, con: UInt8 = 0, alg: UInt8 = 0, ksv: UInt8 = 0
        var cha: UInt16 = 0xFFFF, chb: UInt16 = 0xFFFF, chc: UInt16 = 0, chd: UInt16 = 0
        let ch_num: UInt8
    }

    private struct WriteBuf {
        var time: UInt64 = 0
        var reg: UInt16 = 0
        var data: UInt8 = 0
    }

    // Channel types.
    private static let ch_2op: UInt8 = 0, ch_4op: UInt8 = 1, ch_4op2: UInt8 = 2, ch_drum: UInt8 = 3
    // Envelope key types.
    private static let egk_norm: UInt8 = 0x01, egk_drum: UInt8 = 0x02
    private static let envelope_gen_num_attack: UInt8 = 0, envelope_gen_num_decay: UInt8 = 1
    private static let envelope_gen_num_sustain: UInt8 = 2, envelope_gen_num_release: UInt8 = 3

    private static let OPL_WRITEBUF_SIZE = 1024
    private static let OPL_WRITEBUF_DELAY: UInt64 = 2

    private let channel: UnsafeMutablePointer<Channel>
    private let slot: UnsafeMutablePointer<Slot>
    /// What every operator gives out, then what every operator feeds back, then a nought for those
    /// that are bent by nothing.
    private let signals: UnsafeMutablePointer<Int16>
    private var zeromod: UnsafeMutablePointer<Int16> { signals + 72 }
    /// How deep the tremolo is at the moment, and a nought for the operators that have none.
    private let tremolo: UnsafeMutablePointer<UInt8>
    private let logsinrom: UnsafeMutablePointer<UInt16>, exprom: UnsafeMutablePointer<UInt16>
    private let mt: UnsafeMutablePointer<UInt8>
    private let writebuf: UnsafeMutablePointer<WriteBuf>

    private var timer: UInt16 = 0
    private var eg_timer: UInt64 = 0
    private var eg_timerrem: UInt8 = 0, eg_state: UInt8 = 0, eg_add: UInt8 = 0, eg_timer_lo: UInt8 = 0
    private var newm: UInt8 = 0, nts: UInt8 = 0, rhy: UInt8 = 0
    /// For the lights: the lowest and highest each channel has been, of late.
    private var lows = InlineArray<18, Int16>(repeating: .max), highs = InlineArray<18, Int16>(repeating: .min)
    /// The channels whose keys are down, a bit for each, and those whose keys have gone down (or, in
    /// the rhythm mode, whose drums have been struck) since the notes were last asked for.
    private var keysDown: UInt32 = 0, keysStruck: UInt32 = 0
    private var vibpos: UInt8 = 0, vibshift: UInt8 = 1
    private var tremolopos: UInt8 = 0, tremoloshift: UInt8 = 4
    private var noise: UInt32 = 1
    private var mixbuff: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    private var rm_hh_bit2: UInt8 = 0, rm_hh_bit3: UInt8 = 0, rm_hh_bit7: UInt8 = 0, rm_hh_bit8: UInt8 = 0
    private var rm_tc_bit3: UInt8 = 0, rm_tc_bit5: UInt8 = 0

    /// False until something is written to the second of the chip's two sets of registers, which an
    /// OPL2 does not have. Until then the eighteen operators that set belongs to are at rest and
    /// stay so, and are not worked through. (This is not in the original; it changes no number.)
    private var secondSetUsed = false

    private var writebuf_samplecnt: UInt64 = 0
    private var writebuf_cur = 0, writebuf_last = 0
    private var writebuf_lasttime: UInt64 = 0

    /// The chip as it is after a reset: silent, and behaving as an OPL2.
    init() {
        channel = .allocate(capacity: 18)
        slot = .allocate(capacity: 36)
        signals = .allocate(capacity: 73)
        signals.initialize(repeating: 0, count: 73)
        tremolo = .allocate(capacity: 2)
        tremolo.initialize(repeating: 0, count: 2)
        logsinrom = .allocate(capacity: 256)
        exprom = .allocate(capacity: 256)
        for i in 0 ..< 256 {
            logsinrom[i] = opl3LogSinROM[i]
            exprom[i] = opl3ExpROM[i]
        }
        mt = .allocate(capacity: 16)
        for i in 0 ..< 16 { mt[i] = Self.frequencyMultiples[i] }
        writebuf = .allocate(capacity: Self.OPL_WRITEBUF_SIZE)
        writebuf.initialize(repeating: WriteBuf(), count: Self.OPL_WRITEBUF_SIZE)

        let zero = signals + 72
        for slotnum in 0 ..< 36 {
            (slot + slotnum).initialize(to: Slot(channel: channel, out: signals + slotnum, fbmod: signals + 36 + slotnum, mod: zero,
                                                 trem: tremolo + 1, slot_num: UInt8(slotnum)))
        }
        for channum in 0 ..< 18 {
            let local_ch_slot = Int(Self.ch_slot[channum])
            let pair: UnsafeMutablePointer<Channel>
            switch channum % 9 {
            case 0 ..< 3: pair = channel + channum + 3
            case 3 ..< 6: pair = channel + channum - 3
            default: pair = channel + channum // it has none, and is never asked for it
            }
            (channel + channum).initialize(to: Channel(slotz: (slot + local_ch_slot, slot + local_ch_slot + 3), pair: pair,
                                                       out: (zero, zero, zero, zero), ch_num: UInt8(channum)))
            slot[local_ch_slot].channel = channel + channum
            slot[local_ch_slot + 3].channel = channel + channum
        }
        for channum in 0 ..< 18 { OPL3_ChannelSetupAlg(channel + channum) }
    }

    deinit {
        channel.deallocate()
        slot.deallocate()
        signals.deallocate()
        tremolo.deallocate()
        logsinrom.deallocate()
        exprom.deallocate()
        mt.deallocate()
        writebuf.deallocate()
    }

    /// The multiples of its channel's pitch an operator can play at, each doubled: a half, one, two…
    private static let frequencyMultiples: [UInt8] = [1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30]
    private static let kslrom: [UInt8] = [0, 32, 40, 45, 48, 51, 53, 55, 56, 58, 59, 60, 61, 62, 63, 64]
    /// Which operator a register belongs to, by the last five bits of its number; -1 for none.
    private static let ad_slot: [Int8] = [
        0, 1, 2, 3, 4, 5, -1, -1, 6, 7, 8, 9, 10, 11, -1, -1,
        12, 13, 14, 15, 16, 17, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    ]
    /// The first operator of each channel; its second is three further on.
    private static let ch_slot: [UInt8] = [0, 1, 2, 6, 7, 8, 12, 13, 14, 18, 19, 20, 24, 25, 26, 30, 31, 32]

    // MARK: Envelope generator

    @inline(__always) private func OPL3_EnvelopeCalcExp(_ level: UInt32) -> Int16 {
        let level = min(level, 0x1FFF)
        return Int16(truncatingIfNeeded: (Int32(exprom[Int(level & 0xFF)]) << 1) >> Int32(level >> 8))
    }

    /// One sample of one of the chip's eight waveforms, at a level. The first four are the OPL2's: a
    /// sine, its upper half, both halves turned upwards, and the rising quarters.
    @inline(__always) private func envelope_sin(_ waveform: UInt8, _ phase: UInt16, _ envelope: UInt16) -> Int16 {
        var phase = phase & 0x3FF
        var out: UInt32 = 0
        var neg: Int16 = 0
        switch waveform {
        case 0:
            if phase & 0x200 != 0 { neg = -1 }
            out = UInt32(logsinrom[Int(phase & 0x100 != 0 ? (phase & 0xFF) ^ 0xFF : phase & 0xFF)])
        case 1:
            if phase & 0x200 != 0 {
                out = 0x1000
            } else {
                out = UInt32(logsinrom[Int(phase & 0x100 != 0 ? (phase & 0xFF) ^ 0xFF : phase & 0xFF)])
            }
        case 2:
            out = UInt32(logsinrom[Int(phase & 0x100 != 0 ? (phase & 0xFF) ^ 0xFF : phase & 0xFF)])
        case 3:
            out = phase & 0x100 != 0 ? 0x1000 : UInt32(logsinrom[Int(phase & 0xFF)])
        case 4:
            if phase & 0x300 == 0x100 { neg = -1 }
            if phase & 0x200 != 0 {
                out = 0x1000
            } else if phase & 0x80 != 0 {
                out = UInt32(logsinrom[Int(((phase ^ 0xFF) << 1) & 0xFF)])
            } else {
                out = UInt32(logsinrom[Int((phase << 1) & 0xFF)])
            }
        case 5:
            if phase & 0x200 != 0 {
                out = 0x1000
            } else if phase & 0x80 != 0 {
                out = UInt32(logsinrom[Int(((phase ^ 0xFF) << 1) & 0xFF)])
            } else {
                out = UInt32(logsinrom[Int((phase << 1) & 0xFF)])
            }
        case 6:
            if phase & 0x200 != 0 { neg = -1 }
        default:
            if phase & 0x200 != 0 {
                neg = -1
                phase = (phase & 0x1FF) ^ 0x1FF
            }
            out = UInt32(phase) << 3
        }
        return OPL3_EnvelopeCalcExp(out + (UInt32(envelope) << 3)) ^ neg
    }

    private func OPL3_EnvelopeUpdateKSL(_ slot: UnsafeMutablePointer<Slot>) {
        let channel = slot.pointee.channel
        let ksl = (Int(Self.kslrom[Int(channel.pointee.f_num >> 6) & 15]) << 2) - ((0x08 - Int(channel.pointee.block)) << 5)
        slot.pointee.eg_ksl = UInt8(truncatingIfNeeded: max(0, ksl))
    }

    @inline(__always) private mutating func OPL3_EnvelopeCalc(_ slot: UnsafeMutablePointer<Slot>) {
        let rout = slot.pointee.eg_rout, gen = slot.pointee.eg_gen, key = slot.pointee.key != 0
        // How much quieter the higher notes are made, by a shift of 8 (not at all), 1, 2 or 0.
        let kslShift = (0x0002_0108 >> (Int(slot.pointee.reg_ksl) << 3)) & 0xFF
        slot.pointee.eg_out = UInt16(truncatingIfNeeded: Int(rout) + (Int(slot.pointee.reg_tl) << 2)
            + (Int(slot.pointee.eg_ksl) >> kslShift) + Int(slot.pointee.trem.pointee))

        var reg_rate: UInt8 = 0
        var reset = false
        if key, gen == Self.envelope_gen_num_release {
            reset = true
            reg_rate = slot.pointee.reg_ar
        } else {
            switch gen {
            case Self.envelope_gen_num_attack: reg_rate = slot.pointee.reg_ar
            case Self.envelope_gen_num_decay: reg_rate = slot.pointee.reg_dr
            case Self.envelope_gen_num_sustain: if slot.pointee.reg_type == 0 { reg_rate = slot.pointee.reg_rr }
            default: reg_rate = slot.pointee.reg_rr
            }
        }
        slot.pointee.pg_reset = reset
        let ks = slot.pointee.channel.pointee.ksv >> ((slot.pointee.reg_ksr ^ 1) << 1)
        let nonzero = reg_rate != 0
        let rate = ks &+ (reg_rate << 2)
        var rate_hi = rate >> 2
        let rate_lo = rate & 0x03
        if rate_hi & 0x10 != 0 { rate_hi = 0x0F }
        let eg_shift = rate_hi &+ eg_add
        var shift: UInt8 = 0
        if nonzero {
            if rate_hi < 12 {
                if eg_state != 0 {
                    switch eg_shift {
                    case 12: shift = 1
                    case 13: shift = (rate_lo >> 1) & 0x01
                    case 14: shift = rate_lo & 0x01
                    default: break
                    }
                }
            } else {
                // Which of four samples a rate between two steps takes the larger step on.
                shift = (rate_hi & 0x03) + UInt8((0x7510 >> ((Int(rate_lo) << 2) + Int(eg_timer_lo))) & 1)
                if shift & 0x04 != 0 { shift = 0x03 }
                if shift == 0 { shift = eg_state }
            }
        }
        var eg_rout = rout
        var eg_inc: Int32 = 0
        // An instant attack.
        if reset, rate_hi == 0x0F { eg_rout = 0x00 }
        // The envelope is off.
        let eg_off = rout & 0x1F8 == 0x1F8
        if gen != Self.envelope_gen_num_attack, !reset, eg_off { eg_rout = 0x1FF }
        switch gen {
        case Self.envelope_gen_num_attack:
            if rout == 0 {
                slot.pointee.eg_gen = Self.envelope_gen_num_decay
            } else if key, shift > 0, rate_hi != 0x0F {
                eg_inc = ~Int32(rout) >> Int32(4 - shift)
            }
        case Self.envelope_gen_num_decay:
            if rout >> 4 == UInt16(slot.pointee.reg_sl) {
                slot.pointee.eg_gen = Self.envelope_gen_num_sustain
            } else if !eg_off, !reset, shift > 0 {
                eg_inc = 1 << Int32(shift - 1)
            }
        default:
            if !eg_off, !reset, shift > 0 { eg_inc = 1 << Int32(shift - 1) }
        }
        slot.pointee.eg_rout = UInt16(truncatingIfNeeded: (Int32(eg_rout) + eg_inc) & 0x1FF)
        if reset { slot.pointee.eg_gen = Self.envelope_gen_num_attack }
        // Key off.
        if !key { slot.pointee.eg_gen = Self.envelope_gen_num_release }
    }

    // MARK: Phase generator

    @inline(__always) private mutating func OPL3_PhaseGenerate(_ slot: UnsafeMutablePointer<Slot>) {
        let channel = slot.pointee.channel
        var f_num = channel.pointee.f_num
        if slot.pointee.reg_vib != 0 {
            var range = Int16((f_num >> 7) & 7)
            if vibpos & 3 == 0 {
                range = 0
            } else if vibpos & 1 != 0 {
                range >>= 1
            }
            range >>= Int16(vibshift)
            if vibpos & 4 != 0 { range = -range }
            f_num &+= UInt16(bitPattern: range)
        }
        let basefreq = (UInt32(f_num) << UInt32(channel.pointee.block)) >> 1
        let phase = UInt16(truncatingIfNeeded: slot.pointee.pg_phase >> 9)
        if slot.pointee.pg_reset { slot.pointee.pg_phase = 0 }
        slot.pointee.pg_phase &+= (basefreq &* UInt32(mt[Int(slot.pointee.reg_mult)])) >> 1
        // Rhythm mode.
        let noise = noise
        slot.pointee.pg_phase_out = phase
        let slot_num = slot.pointee.slot_num
        if slot_num == 13 { // the hi-hat
            rm_hh_bit2 = UInt8((phase >> 2) & 1)
            rm_hh_bit3 = UInt8((phase >> 3) & 1)
            rm_hh_bit7 = UInt8((phase >> 7) & 1)
            rm_hh_bit8 = UInt8((phase >> 8) & 1)
        }
        if slot_num == 17, rhy & 0x20 != 0 { // the top cymbal
            rm_tc_bit3 = UInt8((phase >> 3) & 1)
            rm_tc_bit5 = UInt8((phase >> 5) & 1)
        }
        if rhy & 0x20 != 0 {
            let rm_xor = UInt16((rm_hh_bit2 ^ rm_hh_bit7) | (rm_hh_bit3 ^ rm_tc_bit5) | (rm_tc_bit3 ^ rm_tc_bit5))
            switch slot_num {
            case 13: // the hi-hat
                slot.pointee.pg_phase_out = (rm_xor << 9) | (rm_xor ^ UInt16(noise & 1) != 0 ? 0xD0 : 0x34)
            case 16: // the snare drum
                slot.pointee.pg_phase_out = (UInt16(rm_hh_bit8) << 9) | ((UInt16(rm_hh_bit8) ^ UInt16(noise & 1)) << 8)
            case 17: // the top cymbal
                slot.pointee.pg_phase_out = (rm_xor << 9) | 0x80
            default:
                break
            }
        }
        let n_bit = ((noise >> 14) ^ noise) & 0x01
        self.noise = (noise >> 1) | (n_bit << 22)
    }

    // MARK: Slot

    private func OPL3_SlotWrite20(_ slot: UnsafeMutablePointer<Slot>, _ data: UInt8) {
        slot.pointee.trem = (data >> 7) & 0x01 != 0 ? tremolo : tremolo + 1
        slot.pointee.reg_vib = (data >> 6) & 0x01
        slot.pointee.reg_type = (data >> 5) & 0x01
        slot.pointee.reg_ksr = (data >> 4) & 0x01
        slot.pointee.reg_mult = data & 0x0F
    }

    private func OPL3_SlotWrite40(_ slot: UnsafeMutablePointer<Slot>, _ data: UInt8) {
        slot.pointee.reg_ksl = (data >> 6) & 0x03
        slot.pointee.reg_tl = data & 0x3F
        OPL3_EnvelopeUpdateKSL(slot)
    }

    private func OPL3_SlotWrite60(_ slot: UnsafeMutablePointer<Slot>, _ data: UInt8) {
        slot.pointee.reg_ar = (data >> 4) & 0x0F
        slot.pointee.reg_dr = data & 0x0F
    }

    private func OPL3_SlotWrite80(_ slot: UnsafeMutablePointer<Slot>, _ data: UInt8) {
        slot.pointee.reg_sl = (data >> 4) & 0x0F
        if slot.pointee.reg_sl == 0x0F { slot.pointee.reg_sl = 0x1F }
        slot.pointee.reg_rr = data & 0x0F
    }

    private func OPL3_SlotWriteE0(_ slot: UnsafeMutablePointer<Slot>, _ data: UInt8) {
        slot.pointee.reg_wf = data & 0x07
        if newm == 0x00 { slot.pointee.reg_wf &= 0x03 }
    }

    @inline(__always) private mutating func OPL3_ProcessSlot(_ slot: UnsafeMutablePointer<Slot>) {
        // What it feeds back to itself.
        let out = slot.pointee.out.pointee
        let fb = slot.pointee.channel.pointee.fb
        slot.pointee.fbmod.pointee = fb != 0x00 ? Int16(truncatingIfNeeded: (Int32(slot.pointee.prout) + Int32(out)) >> Int32(0x09 - fb)) : 0
        slot.pointee.prout = out
        OPL3_EnvelopeCalc(slot)
        OPL3_PhaseGenerate(slot)
        slot.pointee.out.pointee = envelope_sin(slot.pointee.reg_wf,
                                                UInt16(truncatingIfNeeded: Int32(slot.pointee.pg_phase_out) + Int32(slot.pointee.mod.pointee)),
                                                slot.pointee.eg_out)
    }

    // MARK: Channel

    private mutating func OPL3_ChannelUpdateRhythm(_ data: UInt8) {
        rhy = data & 0x3F
        if rhy & 0x20 != 0 {
            let channel6 = channel + 6, channel7 = channel + 7, channel8 = channel + 8
            channel6.pointee.out = (channel6.pointee.slotz.1.pointee.out, channel6.pointee.slotz.1.pointee.out, zeromod, zeromod)
            channel7.pointee.out = (channel7.pointee.slotz.0.pointee.out, channel7.pointee.slotz.0.pointee.out,
                                    channel7.pointee.slotz.1.pointee.out, channel7.pointee.slotz.1.pointee.out)
            channel8.pointee.out = (channel8.pointee.slotz.0.pointee.out, channel8.pointee.slotz.0.pointee.out,
                                    channel8.pointee.slotz.1.pointee.out, channel8.pointee.slotz.1.pointee.out)
            for chnum in 6 ..< 9 { channel[chnum].chtype = Self.ch_drum }
            OPL3_ChannelSetupAlg(channel6)
            OPL3_ChannelSetupAlg(channel7)
            OPL3_ChannelSetupAlg(channel8)
            func key(_ slot: UnsafeMutablePointer<Slot>, _ on: Bool) {
                if on { slot.pointee.key |= Self.egk_drum } else { slot.pointee.key &= ~Self.egk_drum }
            }
            key(channel7.pointee.slotz.0, rhy & 0x01 != 0) // the hi-hat
            key(channel8.pointee.slotz.1, rhy & 0x02 != 0) // the top cymbal
            key(channel8.pointee.slotz.0, rhy & 0x04 != 0) // the tom-tom
            key(channel7.pointee.slotz.1, rhy & 0x08 != 0) // the snare drum
            key(channel6.pointee.slotz.0, rhy & 0x10 != 0) // the bass drum
            key(channel6.pointee.slotz.1, rhy & 0x10 != 0)
        } else {
            for chnum in 6 ..< 9 {
                channel[chnum].chtype = Self.ch_2op
                OPL3_ChannelSetupAlg(channel + chnum)
                channel[chnum].slotz.0.pointee.key &= ~Self.egk_drum
                channel[chnum].slotz.1.pointee.key &= ~Self.egk_drum
            }
        }
    }

    private func OPL3_ChannelUpdateFrequency(_ channel: UnsafeMutablePointer<Channel>) {
        channel.pointee.ksv = (channel.pointee.block << 1) | UInt8((channel.pointee.f_num >> UInt16(0x09 - nts)) & 0x01)
        OPL3_EnvelopeUpdateKSL(channel.pointee.slotz.0)
        OPL3_EnvelopeUpdateKSL(channel.pointee.slotz.1)
    }

    private func OPL3_ChannelRestoreFrequency(_ channel: UnsafeMutablePointer<Channel>) {
        channel.pointee.f_num = channel.pointee.f_num_reg
        channel.pointee.block = channel.pointee.block_reg
        OPL3_ChannelUpdateFrequency(channel)
    }

    private func OPL3_ChannelSync4Op(_ channel: UnsafeMutablePointer<Channel>) {
        channel.pointee.pair.pointee.f_num = channel.pointee.f_num
        channel.pointee.pair.pointee.block = channel.pointee.block
        OPL3_ChannelUpdateFrequency(channel.pointee.pair)
    }

    private func OPL3_ChannelWriteA0(_ channel: UnsafeMutablePointer<Channel>, _ data: UInt8) {
        channel.pointee.f_num_reg = (channel.pointee.f_num_reg & 0x300) | UInt16(data)
        if channel.pointee.chtype == Self.ch_4op2 { return }
        OPL3_ChannelRestoreFrequency(channel)
        if channel.pointee.chtype == Self.ch_4op { OPL3_ChannelSync4Op(channel) }
    }

    private func OPL3_ChannelWriteB0(_ channel: UnsafeMutablePointer<Channel>, _ data: UInt8) {
        channel.pointee.f_num_reg = (channel.pointee.f_num_reg & 0xFF) | (UInt16(data & 0x03) << 8)
        channel.pointee.block_reg = (data >> 2) & 0x07
        if channel.pointee.chtype == Self.ch_4op2 { return }
        OPL3_ChannelRestoreFrequency(channel)
        if channel.pointee.chtype == Self.ch_4op { OPL3_ChannelSync4Op(channel) }
    }

    /// Wires a channel's operators together in the way that is set for it: which bends which, and
    /// which are heard.
    private func OPL3_ChannelSetupAlg(_ channel: UnsafeMutablePointer<Channel>) {
        let zeromod = zeromod
        let slot0 = channel.pointee.slotz.0, slot1 = channel.pointee.slotz.1
        if channel.pointee.chtype == Self.ch_drum {
            if channel.pointee.ch_num == 7 || channel.pointee.ch_num == 8 {
                slot0.pointee.mod = zeromod
                slot1.pointee.mod = zeromod
                return
            }
            slot0.pointee.mod = slot0.pointee.fbmod
            slot1.pointee.mod = channel.pointee.alg & 0x01 == 0 ? slot0.pointee.out : zeromod
            return
        }
        if channel.pointee.alg & 0x08 != 0 { return }
        if channel.pointee.alg & 0x04 != 0 {
            let pair = channel.pointee.pair
            let pair0 = pair.pointee.slotz.0, pair1 = pair.pointee.slotz.1
            pair.pointee.out = (zeromod, zeromod, zeromod, zeromod)
            switch channel.pointee.alg & 0x03 {
            case 0x00:
                pair0.pointee.mod = pair0.pointee.fbmod
                pair1.pointee.mod = pair0.pointee.out
                slot0.pointee.mod = pair1.pointee.out
                slot1.pointee.mod = slot0.pointee.out
                channel.pointee.out = (slot1.pointee.out, zeromod, zeromod, zeromod)
            case 0x01:
                pair0.pointee.mod = pair0.pointee.fbmod
                pair1.pointee.mod = pair0.pointee.out
                slot0.pointee.mod = zeromod
                slot1.pointee.mod = slot0.pointee.out
                channel.pointee.out = (pair1.pointee.out, slot1.pointee.out, zeromod, zeromod)
            case 0x02:
                pair0.pointee.mod = pair0.pointee.fbmod
                pair1.pointee.mod = zeromod
                slot0.pointee.mod = pair1.pointee.out
                slot1.pointee.mod = slot0.pointee.out
                channel.pointee.out = (pair0.pointee.out, slot1.pointee.out, zeromod, zeromod)
            default:
                pair0.pointee.mod = pair0.pointee.fbmod
                pair1.pointee.mod = zeromod
                slot0.pointee.mod = pair1.pointee.out
                slot1.pointee.mod = zeromod
                channel.pointee.out = (pair0.pointee.out, slot0.pointee.out, slot1.pointee.out, zeromod)
            }
        } else if channel.pointee.alg & 0x01 == 0 {
            slot0.pointee.mod = slot0.pointee.fbmod
            slot1.pointee.mod = slot0.pointee.out
            channel.pointee.out = (slot1.pointee.out, zeromod, zeromod, zeromod)
        } else {
            slot0.pointee.mod = slot0.pointee.fbmod
            slot1.pointee.mod = zeromod
            channel.pointee.out = (slot0.pointee.out, slot1.pointee.out, zeromod, zeromod)
        }
    }

    private func OPL3_ChannelUpdateAlg(_ channel: UnsafeMutablePointer<Channel>) {
        channel.pointee.alg = channel.pointee.con
        if channel.pointee.chtype == Self.ch_4op {
            channel.pointee.pair.pointee.alg = 0x04 | (channel.pointee.con << 1) | channel.pointee.pair.pointee.con
            channel.pointee.alg = 0x08
            OPL3_ChannelSetupAlg(channel.pointee.pair)
        } else if channel.pointee.chtype == Self.ch_4op2 {
            channel.pointee.alg = 0x04 | (channel.pointee.pair.pointee.con << 1) | channel.pointee.con
            channel.pointee.pair.pointee.alg = 0x08
            OPL3_ChannelSetupAlg(channel)
        } else {
            OPL3_ChannelSetupAlg(channel)
        }
    }

    private func OPL3_ChannelWriteC0(_ channel: UnsafeMutablePointer<Channel>, _ data: UInt8) {
        channel.pointee.fb = (data & 0x0E) >> 1
        channel.pointee.con = data & 0x01
        OPL3_ChannelUpdateAlg(channel)
        if newm != 0 {
            channel.pointee.cha = (data >> 4) & 0x01 != 0 ? 0xFFFF : 0
            channel.pointee.chb = (data >> 5) & 0x01 != 0 ? 0xFFFF : 0
            channel.pointee.chc = (data >> 6) & 0x01 != 0 ? 0xFFFF : 0
            channel.pointee.chd = (data >> 7) & 0x01 != 0 ? 0xFFFF : 0
        } else {
            channel.pointee.cha = 0xFFFF
            channel.pointee.chb = 0xFFFF
            channel.pointee.chc = 0
            channel.pointee.chd = 0
        }
    }

    private func OPL3_ChannelKey(_ channel: UnsafeMutablePointer<Channel>, _ on: Bool) {
        func key(_ slot: UnsafeMutablePointer<Slot>) {
            if on { slot.pointee.key |= Self.egk_norm } else { slot.pointee.key &= ~Self.egk_norm }
        }
        if channel.pointee.chtype == Self.ch_4op {
            key(channel.pointee.slotz.0)
            key(channel.pointee.slotz.1)
            key(channel.pointee.pair.pointee.slotz.0)
            key(channel.pointee.pair.pointee.slotz.1)
        } else if channel.pointee.chtype == Self.ch_2op || channel.pointee.chtype == Self.ch_drum {
            key(channel.pointee.slotz.0)
            key(channel.pointee.slotz.1)
        }
    }

    private func OPL3_ChannelSet4Op(_ data: UInt8) {
        for bit in 0 ..< 6 {
            let chnum = bit >= 3 ? bit + 9 - 3 : bit
            if (data >> UInt8(bit)) & 0x01 != 0 {
                channel[chnum].chtype = Self.ch_4op
                channel[chnum + 3].chtype = Self.ch_4op2
                OPL3_ChannelSync4Op(channel + chnum)
                OPL3_ChannelUpdateAlg(channel + chnum)
            } else {
                channel[chnum].chtype = Self.ch_2op
                channel[chnum + 3].chtype = Self.ch_2op
                OPL3_ChannelRestoreFrequency(channel + chnum + 3)
                OPL3_ChannelUpdateAlg(channel + chnum)
                OPL3_ChannelUpdateAlg(channel + chnum + 3)
            }
        }
    }

    // MARK: Sound

    @inline(__always) private static func OPL3_ClipSample(_ sample: Int32) -> Int16 {
        Int16(max(-32768, min(32767, sample)))
    }

    /// One sample from each of the chip's four outputs. An OPL2's music comes out of the first two
    /// alike; the other two are the second pair of outputs the OPL3 has, which few cards connected.
    ///
    /// Some of the operators are a sample late on the left and others on the right, as they are on
    /// the chip, which works through them in turn and gives out its sides at different moments.
    mutating func OPL3_Generate4Ch() -> (Int16, Int16, Int16, Int16) {
        let buf1 = Self.OPL3_ClipSample(mixbuff.1), buf3 = Self.OPL3_ClipSample(mixbuff.3)

        for ii in 0 ..< 15 { OPL3_ProcessSlot(slot + ii) }

        let channels = secondSetUsed ? 18 : 9
        var mix0: Int32 = 0, mix1: Int32 = 0
        for ii in 0 ..< channels {
            let channel = channel + ii
            let out = channel.pointee.out
            let accm = UInt16(truncatingIfNeeded: Int32(out.0.pointee) + Int32(out.1.pointee) + Int32(out.2.pointee) + Int32(out.3.pointee))
            mix0 += Int32(Int16(bitPattern: accm & channel.pointee.cha))
            mix1 += Int32(Int16(bitPattern: accm & channel.pointee.chc))
            let level = Int16(bitPattern: accm)
            if level < lows[unchecked: ii] { lows[unchecked: ii] = level }
            if level > highs[unchecked: ii] { highs[unchecked: ii] = level }
        }
        mixbuff.0 = mix0
        mixbuff.2 = mix1

        for ii in 15 ..< 18 { OPL3_ProcessSlot(slot + ii) }

        let buf0 = Self.OPL3_ClipSample(mixbuff.0), buf2 = Self.OPL3_ClipSample(mixbuff.2)

        if secondSetUsed {
            for ii in 18 ..< 33 { OPL3_ProcessSlot(slot + ii) }
        }

        mix0 = 0
        mix1 = 0
        for ii in 0 ..< channels {
            let channel = channel + ii
            let out = channel.pointee.out
            let accm = UInt16(truncatingIfNeeded: Int32(out.0.pointee) + Int32(out.1.pointee) + Int32(out.2.pointee) + Int32(out.3.pointee))
            mix0 += Int32(Int16(bitPattern: accm & channel.pointee.chb))
            mix1 += Int32(Int16(bitPattern: accm & channel.pointee.chd))
        }
        mixbuff.1 = mix0
        mixbuff.3 = mix1

        if secondSetUsed {
            for ii in 33 ..< 36 { OPL3_ProcessSlot(slot + ii) }
        } else {
            // All that operators at rest do is move the noise on, once each.
            var noise = noise
            for _ in 0 ..< 18 { noise = (noise >> 1) | ((((noise >> 14) ^ noise) & 0x01) << 22) }
            self.noise = noise
        }

        // The slow waves: tremolo and vibrato.
        if timer & 0x3F == 0x3F { tremolopos = (tremolopos + 1) % 210 }
        tremolo.pointee = tremolopos < 105 ? tremolopos >> tremoloshift : (210 - tremolopos) >> tremoloshift
        if timer & 0x3FF == 0x3FF { vibpos = (vibpos + 1) & 7 }
        timer &+= 1

        // The envelopes' clock.
        if eg_state != 0 {
            let shift = min(13, eg_timer.trailingZeroBitCount)
            eg_add = shift > 12 ? 0 : UInt8(shift + 1)
            eg_timer_lo = UInt8(eg_timer & 0x3)
        }
        if eg_timerrem != 0 || eg_state != 0 {
            if eg_timer == 0xF_FFFF_FFFF {
                eg_timer = 0
                eg_timerrem = 1
            } else {
                eg_timer += 1
                eg_timerrem = 0
            }
        }
        eg_state ^= 1

        // The writes that were waiting for this moment.
        while writebuf[writebuf_cur].time <= writebuf_samplecnt {
            if writebuf[writebuf_cur].reg & 0x200 == 0 { break }
            writebuf[writebuf_cur].reg &= 0x1FF
            OPL3_WriteReg(writebuf[writebuf_cur].reg, writebuf[writebuf_cur].data)
            writebuf_cur = (writebuf_cur + 1) % Self.OPL_WRITEBUF_SIZE
        }
        writebuf_samplecnt += 1
        return (buf0, buf1, buf2, buf3)
    }

    /// One sample of the chip's left and right.
    @inline(__always) mutating func OPL3_Generate() -> (left: Int16, right: Int16) {
        let samples = OPL3_Generate4Ch()
        return (samples.0, samples.1)
    }

    /// How far each of the first `count` channels has swung since this was last asked, where 1 is half
    /// as far as one operator at full level goes: tunes keep well below that, to leave room for nine
    /// voices. (In the rhythm mode the last three channels are the drums.)
    mutating func takeLevels(into levels: UnsafeMutablePointer<Float>, count: Int) {
        for channel in 0 ..< min(18, count) {
            let low = lows[channel], high = highs[channel]
            levels[channel] = high > low ? min(1, Float(Int32(high) - Int32(low)) / 4084) : 0
            lows[channel] = .max
            highs[channel] = .min
        }
    }

    /// What each of the first `count` channels is playing: the pitch it is set to, and whether its key
    /// has gone down since this was last asked. In the rhythm mode the last two channels are drums
    /// with no pitch to speak of.
    mutating func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>, count: Int) {
        for index in 0 ..< min(18, count) {
            let number = Double(channel[index].f_num), block = Int(channel[index].block)
            let drum = rhy & 0x20 != 0 && (index == 7 || index == 8)
            pitches[index] = number > 0 && !drum ? ChannelPitch.note(ofHz: number * Self.rate / Double(1 << (20 - block))) : 0
            struck[index] = keysStruck & (1 << UInt32(index)) != 0
        }
        keysStruck = 0
    }

    // MARK: Registers

    /// Sets a register, at once. The register's number is nine bits: the ninth chooses the second of
    /// the chip's two sets, which an OPL2 does not have.
    mutating func OPL3_WriteReg(_ reg: UInt16, _ v: UInt8) {
        let high = Int((reg >> 8) & 0x01)
        let regm = Int(reg & 0xFF)
        if high != 0 { secondSetUsed = true }
        let slotnum = Int(Self.ad_slot[regm & 0x1F])
        switch regm & 0xF0 {
        case 0x00:
            if high != 0 {
                switch regm & 0x0F {
                case 0x04: OPL3_ChannelSet4Op(v)
                case 0x05: newm = v & 0x01
                default: break
                }
            } else if regm & 0x0F == 0x08 {
                nts = (v >> 6) & 0x01
            }
        case 0x20, 0x30:
            if slotnum >= 0 { OPL3_SlotWrite20(slot + 18 * high + slotnum, v) }
        case 0x40, 0x50:
            if slotnum >= 0 { OPL3_SlotWrite40(slot + 18 * high + slotnum, v) }
        case 0x60, 0x70:
            if slotnum >= 0 { OPL3_SlotWrite60(slot + 18 * high + slotnum, v) }
        case 0x80, 0x90:
            if slotnum >= 0 { OPL3_SlotWrite80(slot + 18 * high + slotnum, v) }
        case 0xE0, 0xF0:
            if slotnum >= 0 { OPL3_SlotWriteE0(slot + 18 * high + slotnum, v) }
        case 0xA0:
            if regm & 0x0F < 9 { OPL3_ChannelWriteA0(channel + 9 * high + (regm & 0x0F), v) }
        case 0xB0:
            if regm == 0xBD, high == 0 {
                if v & 0x20 != 0 {
                    // The bass drum is the seventh channel, the snare and hi-hat the eighth, the
                    // tom-tom and cymbal the ninth.
                    let struck = v & ~rhy & 0x1F
                    if struck & 0x10 != 0 { keysStruck |= 1 << 6 }
                    if struck & 0x09 != 0 { keysStruck |= 1 << 7 }
                    if struck & 0x06 != 0 { keysStruck |= 1 << 8 }
                }
                tremoloshift = (((v >> 7) ^ 1) << 1) + 2
                vibshift = ((v >> 6) & 0x01) ^ 1
                OPL3_ChannelUpdateRhythm(v)
            } else if regm & 0x0F < 9 {
                let key = UInt32(1) << UInt32(9 * high + (regm & 0x0F))
                if v & 0x20 == 0 {
                    keysDown &= ~key
                } else if keysDown & key == 0 {
                    keysDown |= key
                    keysStruck |= key
                }
                OPL3_ChannelWriteB0(channel + 9 * high + (regm & 0x0F), v)
                OPL3_ChannelKey(channel + 9 * high + (regm & 0x0F), v & 0x20 != 0)
            }
        case 0xC0:
            if regm & 0x0F < 9 { OPL3_ChannelWriteC0(channel + 9 * high + (regm & 0x0F), v) }
        default:
            break
        }
    }

    /// Sets a register as a program on a computer would have: no sooner than two samples after the
    /// write before it, which is about as fast as a card could be written to. A program that ends a
    /// note and starts the next in one go relies on the chip seeing the gap.
    mutating func OPL3_WriteRegBuffered(_ reg: UInt16, _ v: UInt8) {
        let last = writebuf_last
        if writebuf[last].reg & 0x200 != 0 {
            // No room: the oldest write happens now.
            OPL3_WriteReg(writebuf[last].reg & 0x1FF, writebuf[last].data)
            writebuf_cur = (last + 1) % Self.OPL_WRITEBUF_SIZE
            writebuf_samplecnt = writebuf[last].time
        }
        writebuf[last].reg = reg | 0x200
        writebuf[last].data = v
        let time = max(writebuf_lasttime + Self.OPL_WRITEBUF_DELAY, writebuf_samplecnt)
        writebuf[last].time = time
        writebuf_lasttime = time
        writebuf_last = (last + 1) % Self.OPL_WRITEBUF_SIZE
    }
}
