// Copyright (C) 2021, 2024 nukeykt; (C) 2024-2026 J.C. Moyer
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A Swift port of Nuked SC-55's emulation of Roland's PCM chip (pcm.cpp, as jcmoyer's fork of Nuked SC-55 keeps
// it), worked out from John McMaster's photographs of the decapped chip, free software under the GNU General
// Public License, version 2 or any later version (see THIRD-PARTY.md).

/// Roland's PCM chip of the SC-55: up to 24 voices read from the wave ROMs (compressed: 8-bit differences with a
/// 4-bit shift to each 16 of them), interpolated, filtered and given their two envelopes, panned and sent to
/// the reverb and chorus, which it runs too, in its own RAM, as its controller's firmware programs them.
/// Every time round its slots it gives two frames of output (it oversamples), 20 bits a side.
final class SC55PCM {
    unowned(unsafe) var mcu: SC55MCU!

    /// Each slot's registers: 8 of 20 bits (addresses, filter state) and 16 of 16 bits (pitch, envelopes,
    /// pan, sends), 32 slots; slots 28 to 31 are the effects'.
    let ram1: UnsafeMutablePointer<UInt32>
    let ram2: UnsafeMutablePointer<UInt16>
    /// The effects' RAM, 16K words of 14 bits and a 2-bit shift.
    let eram: UnsafeMutablePointer<UInt16>
    /// The wave ROMs, unscrambled, one after another, a megabyte to each bank.
    let waves: UnsafeMutablePointer<UInt8>
    let waveBanks: Int

    @exclusivity(unchecked) var cycles: UInt64 = 0
    @exclusivity(unchecked) var voiceMask: UInt32 = 0
    @exclusivity(unchecked) var voiceMaskPending: UInt32 = 0
    @exclusivity(unchecked) var writeLatch: UInt32 = 0
    @exclusivity(unchecked) var readLatch: UInt32 = 0
    @exclusivity(unchecked) var waveReadAddress: UInt32 = 0
    @exclusivity(unchecked) var tvCounter: UInt16 = 0
    @exclusivity(unchecked) var waveByteLatch: UInt8 = 0
    @exclusivity(unchecked) var selectChannel = 0
    @exclusivity(unchecked) var config3C: UInt8 = 0
    @exclusivity(unchecked) var config3D: UInt8 = 0
    @exclusivity(unchecked) var irqChannel: UInt8 = 0
    @exclusivity(unchecked) var irqAssert = false
    @exclusivity(unchecked) var voiceMaskUpdating = false
    @exclusivity(unchecked) var nfs = false
    @exclusivity(unchecked) var accumL: Int32 = 0
    @exclusivity(unchecked) var accumR: Int32 = 0
    @exclusivity(unchecked) var rcsum0: Int32 = 0, rcsum1: Int32 = 0

    // The configuration register 0x3C, worked out.
    @exclusivity(unchecked) var orValue: Int32 = 0
    @exclusivity(unchecked) var noiseMask: Int32 = 0
    @exclusivity(unchecked) var writeMask: Int32 = 0
    @exclusivity(unchecked) var oversampling = false
    @exclusivity(unchecked) var slots = 1

    /// The frames made and not yet taken: left and right, 32 bits each, the 20-bit samples shifted up 12.
    let output: UnsafeMutablePointer<Int32>
    static let outputCapacity = 8192
    @exclusivity(unchecked) var outputCount = 0

    // MARK: Parts

    /// Where the firmware keeps the part each slot plays, a byte to a slot (0 for the rhythm part, part 10, 1
    /// to 9 for parts 1 to 9, 10 to 15 for parts 11 to 16, as GS numbers its blocks), when the parts' sound is
    /// watched or some are muted; nil while neither, when nothing is done that the chip itself does not.
    @exclusivity(unchecked) var partTable: UnsafeMutablePointer<UInt8>?
    /// The parts not heard, a bit for each (by the firmware's numbers).
    @exclusivity(unchecked) var mutedParts: UInt32 = 0
    /// Each round, each part's sound, its slots' after their envelopes added (before their pan), kept for
    /// the parts' scopes while `partRounds` is not nil: 16 a round, `partRoundCount` rounds of them.
    @exclusivity(unchecked) var partRounds: UnsafeMutablePointer<Int32>?
    @exclusivity(unchecked) var partRoundCount = 0
    static let partRoundCapacity = 4096
    /// The loudest each part's sound has been since they were last taken.
    let partPeaks: UnsafeMutablePointer<Int32>

    /// For each of the envelopes' five ways of counting, the low bits it adds this round and whether it
    /// moves this round (1 or 0), from the envelopes' counter (`prepareEnvelopes`).
    let envelopeAddLow: UnsafeMutablePointer<Int32>
    let envelopeMoves: UnsafeMutablePointer<Bool>

    init(waves waveData: [[UInt8]]) {
        ram1 = .allocate(capacity: 32 * 8)
        ram1.initialize(repeating: 0, count: 32 * 8)
        ram2 = .allocate(capacity: 32 * 16)
        ram2.initialize(repeating: 0, count: 32 * 16)
        eram = .allocate(capacity: 0x4000)
        eram.initialize(repeating: 0, count: 0x4000)
        waveBanks = 3
        waves = .allocate(capacity: 3 << 20)
        waves.initialize(repeating: 0, count: 3 << 20)
        for (bank, data) in waveData.prefix(3).enumerated() {
            Self.unscramble(data, into: waves + (bank << 20), count: min(data.count, 1 << 20))
        }
        output = .allocate(capacity: Self.outputCapacity * 2)
        output.initialize(repeating: 0, count: Self.outputCapacity * 2)
        partPeaks = .allocate(capacity: 16)
        partPeaks.initialize(repeating: 0, count: 16)
        envelopeAddLow = .allocate(capacity: 5)
        envelopeAddLow.initialize(repeating: 0, count: 5)
        envelopeMoves = .allocate(capacity: 5)
        envelopeMoves.initialize(repeating: false, count: 5)
    }

    deinit {
        ram1.deallocate()
        ram2.deallocate()
        eram.deallocate()
        waves.deallocate()
        output.deallocate()
        partPeaks.deallocate()
        partRounds?.deallocate()
        envelopeAddLow.deallocate()
        envelopeMoves.deallocate()
        envelopeSpeeds.deallocate()
    }

    /// The wave ROMs' address and data lines are wired out of order; this puts their bytes back as the chip
    /// reads them (Nuked SC-55's `unscramble`).
    static func unscramble(_ source: [UInt8], into destination: UnsafeMutablePointer<UInt8>, count: Int) {
        let addressBits = [2, 0, 3, 4, 1, 9, 13, 10, 18, 17, 6, 15, 11, 16, 8, 5, 12, 7, 14, 19]
        let dataBits = [2, 0, 4, 5, 7, 6, 3, 1]
        var dataTable = [UInt8](repeating: 0, count: 256)
        for value in 0 ..< 256 {
            var data = 0
            for j in 0 ..< 8 where value & (1 << dataBits[j]) != 0 { data |= 1 << j }
            dataTable[value] = UInt8(data)
        }
        // Where each of the low ten and the high ten address lines go, worked out once for each half.
        var low = [Int](repeating: 0, count: 1024), high = [Int](repeating: 0, count: 1024)
        for value in 0 ..< 1024 {
            for j in 0 ..< 10 where value & (1 << j) != 0 {
                low[value] |= 1 << addressBits[j]
                high[value] |= 1 << addressBits[j + 10]
            }
        }
        source.withUnsafeBufferPointer { source in
            for i in 0 ..< count {
                let address = i & ~0xFFFFF | low[i & 1023] | high[(i >> 10) & 1023]
                destination[i] = address < source.count ? dataTable[Int(source[address])] : 0
            }
        }
    }

    @inline(__always) func readROM(_ address: UInt32) -> UInt8 {
        let bank = Int(config3D & 0x20 != 0 ? (address >> 21) & 7 : (address >> 19) & 7)
        guard bank < waveBanks else { return 0 }
        return waves[bank << 20 | Int(address & 0xFFFFF)]
    }

    // MARK: Registers, as the controller sees them

    func write(_ address: UInt32, _ data: UInt8) {
        let a = Int(address & 0x3F)
        if a < 0x4 {
            let shift = UInt32(3 - a) * 8
            let mask: UInt32 = a == 0 ? 0xF : 0xFF
            voiceMaskPending &= ~(mask << shift)
            voiceMaskPending |= (UInt32(data) & mask) << shift
            voiceMaskUpdating = true
        } else if a >= 0x20, a < 0x24 {
            switch a & 3 {
            case 1:
                waveReadAddress &= ~0xFF0000
                waveReadAddress |= UInt32(data) << 16
            case 2:
                waveReadAddress &= ~0xFF00
                waveReadAddress |= UInt32(data) << 8
            case 3:
                waveReadAddress &= ~0xFF
                waveReadAddress |= UInt32(data)
                waveByteLatch = readROM(waveReadAddress)
            default: break
            }
        } else if a == 0x3C {
            config3C = data
            configure(data)
        } else if a == 0x3D {
            config3D = data
            slots = Int(data & 31) + 1
        } else if a == 0x3E {
            selectChannel = Int(data & 0x1F)
        } else if (a >= 0x4 && a < 0x10) || (a >= 0x24 && a < 0x30) {
            switch a & 3 {
            case 1:
                writeLatch &= ~0xF0000
                writeLatch |= (UInt32(data) & 0xF) << 16
            case 2:
                writeLatch &= ~0xFF00
                writeLatch |= UInt32(data) << 8
            case 3:
                writeLatch &= ~0xFF
                writeLatch |= UInt32(data)
                var ix = 0
                if a & 32 != 0 { ix |= 1 }
                if a & 8 == 0 { ix |= 4 }
                if a & 4 == 0 { ix |= 2 }
                ram1[selectChannel * 8 + ix] = writeLatch
            default: break
            }
        } else if (a >= 0x10 && a < 0x20) || (a >= 0x30 && a < 0x38) {
            if a & 1 == 0 {
                writeLatch &= ~0xFF00
                writeLatch |= UInt32(data) << 8
            } else {
                writeLatch &= ~0xFF
                writeLatch |= UInt32(data)
                var ix = (a >> 1) & 7
                if a & 32 != 0 { ix |= 8 }
                ram2[selectChannel * 16 + ix] = UInt16(truncatingIfNeeded: writeLatch)
            }
        }
    }

    func read(_ address: UInt32) -> UInt8 {
        let a = Int(address & 0x3F)
        if a < 0x4 {
            if voiceMaskUpdating { voiceMask = voiceMaskPending }
            voiceMaskUpdating = false
        } else if a == 0x3C || a == 0x3E {
            if a == 0x3E, irqAssert {
                irqAssert = false
                mcu.setInterrupt(SC55MCU.Interrupt.irq0, false)
            }
            return irqChannel | (voiceMaskUpdating ? 32 : 0)
        } else if a == 0x3F {
            return waveByteLatch
        } else if (a >= 0x4 && a < 0x10) || (a >= 0x24 && a < 0x30) {
            if a & 3 == 1 {
                var ix = 0
                if a & 32 != 0 { ix |= 1 }
                if a & 8 == 0 { ix |= 4 }
                if a & 4 == 0 { ix |= 2 }
                readLatch = ram1[selectChannel * 8 + ix]
            }
        } else if (a >= 0x10 && a < 0x20) || (a >= 0x30 && a < 0x38) {
            if a & 1 == 0 {
                var ix = (a >> 1) & 7
                if a & 32 != 0 { ix |= 8 }
                readLatch = UInt32(ram2[selectChannel * 16 + ix])
            }
        } else if a >= 0x39, a <= 0x3B {
            switch a & 3 {
            case 1: return UInt8((readLatch >> 16) & 0xF)
            case 2: return UInt8((readLatch >> 8) & 0xFF)
            default: return UInt8(readLatch & 0xFF)
            }
        }
        return 0
    }

    private func configure(_ byte: UInt8) {
        // (Nuked SC-55's PCM_GetConfig: the OR value and the oversampling are only ever added to.)
        if byte & 0x30 != 0 {
            switch (byte >> 2) & 3 {
            case 1: noiseMask = 3
            case 2: noiseMask = 7
            case 3: noiseMask = 15
            default: break
            }
            switch byte & 3 {
            case 1: orValue |= 1 << 8
            case 2: orValue |= 1 << 10
            default: break
            }
            writeMask = 15
        } else {
            switch (byte >> 2) & 3 {
            case 2: noiseMask = 1
            case 3: noiseMask = 3
            default: break
            }
            switch byte & 3 {
            case 1: orValue |= 1 << 6
            case 2: orValue |= 1 << 8
            default: break
            }
            writeMask = 3
        }
        if byte & 0x80 == 0 { writeMask = 0 }
        if byte & 0x30 == 0x30 { orValue |= 1 << 12 }
        if byte & 0x40 != 0 { oversampling = true }
    }

    // MARK: Arithmetic, as the chip's 20-bit adders and multipliers do it

    @inline(__always) static func sx20(_ x: Int32) -> Int32 { (x &<< 12) >> 12 }

    @inline(__always) static func addclip20(_ a: Int32, _ b: Int32, _ carry: Int32) -> Int32 {
        sx20(a) &+ sx20(b) &+ carry
    }

    @inline(__always) static func multi(_ a: Int32, _ b: Int8) -> Int32 { sx20(a) &* Int32(b) }

    @inline(__always) static func multi(_ a: UInt32, _ b: Int8) -> Int32 { sx20(Int32(bitPattern: a)) &* Int32(b) }

    @inline(__always) static func high(_ v: Int) -> Int8 { Int8(truncatingIfNeeded: v >> 8) }

    @inline(__always) static func low(_ v: Int) -> Int8 { Int8(truncatingIfNeeded: v) }

    @inline(__always) func eramUnpack(_ address: Int, _ type: Int32 = 0) -> Int32 {
        let data = Int32(eram[address & 0x3FFF])
        let value = (data & 0x3FFF) &<< 18
        let sh = (data >> 14) & 3
        return value >> (18 - sh * 2 + type)
    }

    @inline(__always) func eramPack(_ address: Int, _ value: UInt32) {
        var top = Int((value >> 13) & 0x7F)
        if top & 0x40 != 0 { top ^= 0x7F }
        let sh: UInt32 = top >= 16 ? 3 : top >= 4 ? 2 : top >= 1 ? 1 : 0
        let data = (value >> (sh * 2)) & 0x3FFF | sh << 14
        eram[address & 0x3FFF] = UInt16(data)
    }

    static let interpolation: [[Int32]] = [
        [3385, 3401, 3417, 3432, 3448, 3463, 3478, 3492, 3506, 3521, 3535, 3548, 3562, 3575, 3588, 3601,
         3614, 3626, 3638, 3650, 3662, 3673, 3685, 3696, 3707, 3718, 3728, 3739, 3749, 3759, 3768, 3778,
         3787, 3796, 3805, 3814, 3823, 3831, 3839, 3847, 3855, 3863, 3870, 3878, 3885, 3892, 3899, 3905,
         3912, 3918, 3924, 3930, 3936, 3942, 3948, 3953, 3958, 3963, 3968, 3973, 3978, 3983, 3987, 3991,
         3995, 4000, 4004, 4007, 4011, 4015, 4018, 4022, 4025, 4028, 4031, 4034, 4037, 4040, 4042, 4045,
         4047, 4050, 4052, 4054, 4057, 4059, 4061, 4063, 4064, 4066, 4068, 4070, 4071, 4073, 4074, 4076,
         4077, 4078, 4079, 4081, 4082, 4083, 4084, 4085, 4086, 4086, 4087, 4088, 4089, 4089, 4090, 4091,
         4091, 4092, 4092, 4093, 4093, 4094, 4094, 4094, 4094, 4095, 4095, 4095, 4095, 4095, 4095, 4095],
        [710, 726, 742, 758, 775, 792, 809, 826, 844, 861, 879, 897, 915, 933, 952, 971,
         990, 1009, 1028, 1047, 1067, 1087, 1106, 1126, 1147, 1167, 1188, 1208, 1229, 1250, 1271, 1292,
         1314, 1335, 1357, 1379, 1400, 1423, 1445, 1467, 1489, 1512, 1534, 1557, 1580, 1602, 1625, 1648,
         1671, 1695, 1718, 1741, 1764, 1788, 1811, 1835, 1858, 1882, 1906, 1929, 1953, 1977, 2000, 2024,
         2048, 2071, 2095, 2119, 2143, 2166, 2190, 2214, 2237, 2261, 2284, 2308, 2331, 2355, 2378, 2401,
         2425, 2448, 2471, 2494, 2517, 2539, 2562, 2585, 2607, 2630, 2652, 2674, 2696, 2718, 2740, 2762,
         2783, 2805, 2826, 2847, 2868, 2889, 2910, 2931, 2951, 2971, 2991, 3011, 3031, 3051, 3070, 3089,
         3108, 3127, 3146, 3164, 3182, 3200, 3218, 3236, 3253, 3271, 3288, 3304, 3321, 3338, 3354, 3370],
        [0, 0, 0, 1, 1, 1, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6,
         6, 7, 8, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
         20, 22, 23, 24, 26, 27, 29, 30, 32, 34, 36, 38, 40, 42, 44, 46,
         49, 51, 53, 56, 59, 62, 65, 68, 71, 74, 77, 81, 84, 88, 92, 96,
         100, 104, 109, 113, 118, 122, 127, 132, 137, 143, 148, 154, 160, 165, 171, 178,
         184, 191, 197, 204, 211, 219, 226, 234, 241, 249, 257, 266, 274, 283, 292, 301,
         310, 319, 329, 339, 349, 359, 369, 380, 391, 402, 413, 424, 436, 448, 460, 472,
         484, 497, 510, 523, 536, 549, 563, 577, 591, 605, 619, 634, 648, 663, 679, 694],
    ]

    /// The three interpolation curves, one after another, 128 each.
    let interpolation: UnsafeMutablePointer<Int32> = {
        let table = UnsafeMutablePointer<Int32>.allocate(capacity: 384)
        for (n, curve) in SC55PCM.interpolation.enumerated() {
            for (i, value) in curve.enumerated() { table[n * 128 + i] = value }
        }
        return table
    }()

    // MARK: Envelopes

    /// An envelope's speed byte worked out (as `calc_tv` works it out each time): which of the five ways it
    /// counts, whether it is of the second kind, and its shift and, for the second kind, its step.
    struct EnvelopeSpeed {
        var way: Int
        var second: Bool
        var shift: Int32
        var preshift: Int32
    }

    /// Every speed byte's, without `nfs` and then with it.
    let envelopeSpeeds = SC55PCM.makeEnvelopeSpeeds()

    private static func makeEnvelopeSpeeds() -> UnsafeMutablePointer<EnvelopeSpeed> {
        let table = UnsafeMutablePointer<EnvelopeSpeed>.allocate(capacity: 512)
        for nfs in [false, true] {
            for speed in 0 ..< 256 {
                let w1 = speed & 0xF0 == 0
                let w2 = w1 || speed & 0x10 != 0
                let w3 = nfs && (speed & 0x80 == 0 || (speed & 0x40 == 0 && (!w2 || speed & 0x20 == 0)))
                var type = (w2 ? 1 : 0) | (w3 ? 8 : 0)
                if speed & 0x20 != 0 { type |= 2 }
                if speed & 0x80 == 0 || speed & 0x40 == 0 { type |= 4 }
                let second = type & 8 != 0
                let shift = second ? (10 - (Int32((speed >> 4) & 14) | (w2 ? 1 : 0))) & 15 : Int32((10 - (speed & 15)) & 15)
                let preshift = Int32(speed & 15) << 9 | (w1 ? 0 : 0x2000)
                (table + (nfs ? 256 : 0) + speed).initialize(to: EnvelopeSpeed(way: type & 4 != 0 ? 4 : type & 3, second: second, shift: shift, preshift: preshift))
            }
        }
        return table
    }

    /// Works out, for the envelopes' counter this round, what each way of counting adds and whether it moves.
    @inline(__always) func prepareEnvelopes() {
        let tv = Int32(tvCounter)
        @inline(__always) func reversed(_ bits: Int32) -> Int32 {
            (bits & 8) >> 3 | (bits & 4) >> 1 | (bits & 2) << 1 | (bits & 1) << 3
        }
        envelopeAddLow[0] = reversed((tv >> 2) & 15)
        envelopeAddLow[1] = reversed((tv >> 4) & 15)
        envelopeAddLow[2] = reversed((tv >> 6) & 15)
        envelopeAddLow[3] = reversed((tv >> 8) & 15)
        envelopeAddLow[4] = reversed(tv & 15)
        envelopeMoves[0] = tv & 3 == 0
        envelopeMoves[1] = tv & 15 == 0
        envelopeMoves[2] = tv & 63 == 0
        envelopeMoves[3] = tv & 127 == 0
        envelopeMoves[4] = true
    }

    /// One of a slot's three envelopes (Nuked SC-55's `calc_tv`): `e` 0 and 1 the volume envelopes, which
    /// give their level; 2 the filter's. (Its speed is worked out from `envelopeSpeeds`, and the counter's
    /// part from what `prepareEnvelopes` has worked out for this round.)
    @inline(__always) func envelope(_ e: Int, _ adjust: Int, _ levelCurrent: inout UInt16, _ active: Bool) -> Int32 {
        levelCurrent &= 0x7FFF
        let speed = envelopeSpeeds[(nfs ? 256 : 0) + (adjust & 0xFF)]
        let target = Int32((adjust >> 8) & 0xFF)
        let write = !active || envelopeMoves[speed.way]
        let addLow = envelopeAddLow[speed.way]

        let level = Int32(levelCurrent)
        if !speed.second {
            let shift = speed.shift
            var sum1 = target &<< 11
            if e != 2 || active { sum1 &-= level &<< 4 }
            var shifted = sum1 >> shift
            shifted &-= sum1
            let sum2 = (target &<< 11) &+ addLow &+ shifted
            if write, nfs { levelCurrent = UInt16((sum2 >> 4) & 0x7FFF) }
            return (sum2 >> 4) & 0x7FFE
        } else {
            let shift = speed.shift
            var sum1 = target &<< 11
            if e != 2 || active { sum1 &-= level &<< 4 }
            let negative = sum1 & 0x80000 != 0
            var preshift = speed.preshift
            if negative { preshift ^= ~0x3F }
            var sum2 = preshift >> shift
            if e != 2 || active { sum2 &+= (level &<< 4) | addLow }
            let sum2L = sum2 >> 4
            let sum3 = (target &<< 11) &- (sum2L &<< 4)
            let negative2 = sum3 & 0x80000 != 0
            let same = negative2 == negative
            if write, nfs { levelCurrent = same ? UInt16(truncatingIfNeeded: sum2L & 0x7FFF) : UInt16(truncatingIfNeeded: target &<< 7) }
            if e == 1, !same { return target &<< 7 }
            return sum2L & 0x7FFE
        }
    }
}
