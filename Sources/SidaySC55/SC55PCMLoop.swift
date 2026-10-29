// Copyright (C) 2021, 2024 nukeykt; (C) 2024-2026 J.C. Moyer
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A Swift port of Nuked SC-55's PCM chip's work round its slots (PCM_Update of pcm.cpp, as jcmoyer's fork of
// Nuked SC-55 keeps it), free software under the GNU General Public License, version 2 or any later version
// (see THIRD-PARTY.md). The numbered steps are Nuked SC-55's, which follow the chip's own.

extension SC55PCM {
    /// Runs the chip round its slots until it has caught up with the controller's `cycles`, each round 25
    /// cycles a slot and one more slot's worth, giving two frames of output a round (one without oversampling).
    func update(to target: UInt64) {
        while cycles < target {
            if mk2 { round(SC55PCMModelMk2.self) } else { round(SC55PCMModelSC55.self) }
            cycles &+= UInt64(slots + 1) * 25
        }
    }

    @inline(__always) private func r1(_ slot: Int, _ i: Int) -> Int32 { Int32(bitPattern: ram1[slot &* 8 &+ i]) }
    @inline(__always) private func setR1(_ slot: Int, _ i: Int, _ value: Int32) { ram1[slot &* 8 &+ i] = UInt32(bitPattern: value) }
    @inline(__always) private func r2(_ slot: Int, _ i: Int) -> Int { Int(ram2[slot &* 16 &+ i]) }
    @inline(__always) private func setR2(_ slot: Int, _ i: Int, _ value: Int) { ram2[slot &* 16 &+ i] = UInt16(truncatingIfNeeded: value) }

    @inline(__always) private func emit(_ left: Int32, _ right: Int32) {
        if outputCount < Self.outputCapacity {
            output[outputCount &* 2] = left
            output[outputCount &* 2 &+ 1] = right
            outputCount &+= 1
        }
    }

    /// The effects' RAM at a slot's address register plus the counter that runs through it.
    @inline(__always) private func unpackAt(_ slot: Int, _ i: Int, _ type: Int32 = 0, plus: Int = 0) -> Int32 {
        eramUnpack(r2(slot, i) &+ Int(tvCounter) &+ plus, type)
    }

    @inline(__always) private func packAt(_ slot: Int, _ i: Int, _ value: Int32) {
        eramPack(r2(slot, i) &+ Int(tvCounter), UInt32(bitPattern: value))
    }

    private func round<Model: SC55PCMModel>(_: Model.Type) {
        let voiceActive = voiceMask & voiceMaskPending
        typealias S = SC55PCM
        // Final mixing.
        do {
            var shifter = r2(30, 10)
            var xr = ((shifter >> 0) ^ (shifter >> 1) ^ (shifter >> 7) ^ (shifter >> 12)) & 1
            shifter = (shifter >> 1) | (xr << 15)
            setR2(30, 10, shifter)

            accumL = S.addclip20(accumL, r1(30, 0), 0)
            accumR = S.addclip20(accumR, r1(30, 1), 0)
            let noise = Int32(shifter & 0xFFFF) & noiseMask
            setR1(30, 2, S.addclip20(accumL, orValue | noise, 0))
            setR1(30, 4, S.addclip20(accumR, orValue | noise, 0))
            setR1(30, 0, accumL & writeMask)
            setR1(30, 1, accumR & writeMask)
            emit(Int32(bitPattern: (ram1[30 * 8 + 2] & ~UInt32(bitPattern: writeMask)) << 12),
                 Int32(bitPattern: (ram1[30 * 8 + 4] & ~UInt32(bitPattern: writeMask)) << 12))

            xr = ((shifter >> 0) ^ (shifter >> 1) ^ (shifter >> 7) ^ (shifter >> 12)) & 1
            shifter = (shifter >> 1) | (xr << 15)
            accumL = S.addclip20(accumL, r1(30, 0), 0)
            accumR = S.addclip20(accumR, r1(30, 1), 0)
            let noise2 = Int32(shifter & 0xFFFF) & noiseMask
            setR1(30, 3, S.addclip20(accumL, orValue | noise2, 0))
            setR1(30, 5, S.addclip20(accumR, orValue | noise2, 0))
            if oversampling {
                setR2(30, 10, shifter)
                setR1(30, 0, accumL & writeMask)
                setR1(30, 1, accumR & writeMask)
                emit(Int32(bitPattern: (ram1[30 * 8 + 3] & ~UInt32(bitPattern: writeMask)) << 12),
                     Int32(bitPattern: (ram1[30 * 8 + 5] & ~UInt32(bitPattern: writeMask)) << 12))
            }
        }

        // The global counter for the envelopes.
        if !nfs { tvCounter = ram2[31 * 16 + 8] }
        tvCounter = (tvCounter &- 1) & 0x3FFF
        prepareEnvelopes()

        // Chorus and reverb.
        do {
            let r318 = r2(31, 8)
            if r318 & 0x8000 != 0 { setR2(31, 9, r318 & 0x7FFF) } else { setR2(31, 10, r318 & 0x7FFF) }
            let other = (0x4000 &- r318)
            if other & 0x8000 != 0 { setR2(31, 10, other & 0x7FFF) } else { setR2(31, 9, other & 0x7FFF) }
        }
        do {
            let v1 = r2(31, 1)
            let m1 = S.multi(r1(29, 1), S.high(v1)) >> 5 // 14
            let m2 = S.multi(rcsum1, S.low(v1)) >> 5 // 15
            setR1(29, 1, S.addclip20(m1 >> 1, m2 >> 1, (m1 | m2) & 1)) // 16
        }
        do {
            let active = r2(31, 7) & 0x20 != 0
            var level = ram2[30 * 16 + 9]
            _ = envelope(1, r2(30, 0), &level, active)
            ram2[30 * 16 + 9] = level
        }
        do {
            let v1 = r2(30, 1)
            let m1 = S.multi(r1(29, 0), S.high(v1)) >> 5 // 17
            let m2 = S.multi(rcsum0, S.low(v1)) >> 5 // 18
            setR1(29, 0, S.addclip20(m1 >> 1, m2 >> 1, (m1 | m2) & 1)) // 19
        }

        var rcadd0: Int32 = 0, rcadd1: Int32 = 0, rcadd2: Int32 = 0, rcadd3: Int32 = 0, rcadd4: Int32 = 0, rcadd5: Int32 = 0
        var rcaddB0: Int32 = 0, rcaddB1: Int32 = 0, rcaddB2: Int32 = 0, rcaddB3: Int32 = 0, rcaddB4: Int32 = 0, rcaddB5: Int32 = 0

        do {
            do { // 1
                let v1 = r2(30, 4)
                let m1 = S.multi(r1(29, 0), S.high(v1)) >> 6
                let s1 = unpackAt(28, 1, 1), s2 = unpackAt(28, 1)
                let v2: Int32 = v1 & 0x30 != 0 ? s1 : 0
                let v3 = S.addclip20(m1, v2 ^ 0xFFFFF, 1)
                setR1(29, 4, v3)
                let m2 = S.multi(v3, S.low(v1)) >> 5
                setR1(29, 5, S.addclip20(m2 >> 1, s2, m2 & 1))
            }
            do { // 2
                let v1 = r2(30, 4)
                let s1 = unpackAt(28, 2, 1), s2 = unpackAt(28, 2)
                let v2: Int32 = v1 & 0x30 != 0 ? s1 : 0
                let v3 = S.addclip20(r1(29, 5), v2 ^ 0xFFFFF, 1)
                setR1(29, 5, v3)
                let m2 = S.multi(v3, S.low(v1)) >> 5
                setR1(28, 0, S.addclip20(m2 >> 1, s2, m2 & 1))
            }
            do { // 3
                let v1 = r2(30, 4)
                let s1 = unpackAt(28, 3, 1), s2 = unpackAt(28, 3)
                let v2: Int32 = v1 & 0x30 != 0 ? s1 : 0
                let v3 = S.addclip20(r1(28, 0), v2 ^ 0xFFFFF, 1)
                setR1(28, 0, v3)
                let m2 = S.multi(v3, S.low(v1)) >> 5
                setR1(28, 1, S.addclip20(m2 >> 1, s2, m2 & 1))
                setR1(28, 2, unpackAt(28, 5))
            }
            do { // 4
                let v1 = r2(30, 5)
                let s1 = unpackAt(28, 4, 1), s2 = unpackAt(28, 4)
                let v2: Int32 = v1 & 0x30 != 0 ? s1 : 0
                let v3 = S.addclip20(r1(28, 1), v2 ^ 0xFFFFF, 1)
                setR1(28, 1, v3)
                let m2 = S.multi(v3, S.low(v1)) >> 5
                setR1(28, 3, S.addclip20(m2 >> 1, s2, m2 & 1))
                setR1(28, 4, unpackAt(29, 1))
            }
            do { // 5
                let v1 = r2(30, 7)
                let m1 = S.multi(r1(29, 2), S.high(v1)) >> 5
                let s1 = unpackAt(29, 0)
                let m2 = S.multi(s1, S.low(v1)) >> 5
                setR1(29, 2, S.addclip20(m1 >> 1, m2 >> 1, (m1 | m2) & 1))
                packAt(28, 0, r1(29, 4))
            }
            do { // 6
                let v1 = r2(30, 8)
                let m1 = S.multi(r1(29, 3), S.high(v1)) >> 5
                let s1 = unpackAt(29, 8)
                let m2 = S.multi(s1, S.low(v1)) >> 5
                setR1(29, 3, S.addclip20(m1 >> 1, m2 >> 1, (m1 | m2) & 1))
                packAt(28, 1, r1(29, 5))
                packAt(28, 2, r1(28, 0))
            }
            do { // 7
                let v1 = r2(30, 9)
                let v2 = r1(28, 3)
                let m1 = S.multi(r1(29, 2), S.high(v1)) >> 5
                let m2 = S.multi(r1(29, 3), S.high(v1)) >> 5
                setR1(28, 3, S.addclip20(v2, m1 >> 1, m1 & 1))
                setR1(28, 5, S.addclip20(v2, m2 >> 1, m2 & 1))
                packAt(28, 3, r1(28, 1))
            }
            do { // 8
                let v1 = r2(30, 6)
                let m1 = S.multi(r1(28, 2), S.high(v1)) >> 5
                let v2 = S.addclip20(r1(28, 3), m1 >> 1, m1 & 1)
                setR1(28, 3, v2)
                let m2 = S.multi(v2, S.low(v1)) >> 5
                setR1(28, 2, S.addclip20(r1(28, 2), m2 >> 1, m2 & 1))
                setR1(28, 1, unpackAt(28, 9))
            }
            do { // 9
                let v1 = r2(30, 6)
                let m1 = S.multi(r1(28, 4), S.high(v1)) >> 5
                let v2 = S.addclip20(r1(28, 5), m1 >> 1, m1 & 1)
                setR1(28, 5, v2)
                let m2 = S.multi(v2, S.low(v1)) >> 5
                setR1(28, 4, S.addclip20(r1(28, 4), m2 >> 1, m2 & 1))
                setR1(29, 4, unpackAt(29, 5))
            }
            do { // 10
                let v1 = r2(30, 6)
                let v2 = r1(28, 1)
                let m1 = S.multi(v2, S.high(v1)) >> 5
                let s1 = unpackAt(28, 8)
                let v3 = S.addclip20(m1 >> 1, s1, m1 & 1)
                setR1(28, 1, v3)
                let m2 = S.multi(v3, S.low(v1)) >> 5
                setR1(29, 5, S.addclip20(m2 >> 1, v2, m2 & 1))
                packAt(28, 4, r1(28, 3))
            }
            do { // 11
                let v1 = r2(30, 6)
                let v2 = r1(29, 4)
                let m1 = S.multi(v2, S.high(v1)) >> 5
                let s1 = unpackAt(29, 4)
                let v3 = S.addclip20(m1 >> 1, s1, m1 & 1)
                setR1(29, 4, v3)
                let m2 = S.multi(v3, S.low(v1)) >> 5
                setR1(28, 0, S.addclip20(m2 >> 1, v2, m2 & 1))
                packAt(28, 5, r1(28, 2))
                packAt(29, 0, r1(28, 5))
            }
            // 12
            setR1(28, 5, unpackAt(28, 6))
            do { // 13
                let s1 = unpackAt(28, 10)
                setR1(28, 5, S.addclip20(r1(28, 5), s1, 0))
                setR1(28, 2, unpackAt(29, 2))
            }
            do { // 14
                let s1 = unpackAt(29, 6)
                let t1 = S.addclip20(s1, r1(28, 2), 0)
                setR1(28, 5, S.addclip20(t1, r1(28, 5), 0))
                setR1(28, 2, unpackAt(28, 7))
            }
            do { // 15
                let s1 = unpackAt(28, 11)
                setR1(28, 2, S.addclip20(r1(28, 2), s1, 0))
                setR1(28, 3, unpackAt(29, 3))
            }
            do { // 16
                let s1 = unpackAt(29, 7)
                let t1 = S.addclip20(s1, r1(28, 2), 0)
                setR1(28, 2, S.addclip20(t1, r1(28, 3), 0))
                packAt(29, 1, r1(28, 4))
                packAt(28, 8, r1(28, 1))
            }
            do { // 17
                let v1 = r2(30, 2)
                let v2 = r1(28, 5)
                rcadd0 = S.multi(v2, S.high(v1)) >> 5
                rcaddB0 = S.multi(v2, S.low(v1)) >> 5
                let t1 = unpackAt(29, 10, plus: 1)
                packAt(28, 9, r1(29, 5))
                setR1(29, 5, t1)
            }
            do { // 18
                let v1 = r2(30, 3)
                let v2 = r1(28, 2)
                rcadd1 = S.multi(v2, S.high(v1)) >> 5
                rcaddB1 = S.multi(v2, S.low(v1)) >> 5
                setR1(28, 1, unpackAt(29, 11, plus: 1))
            }
            do { // 19
                let v1 = r2(31, 9)
                let s1 = unpackAt(29, 10)
                packAt(29, 4, r1(29, 4))
                let m1 = S.multi(s1, S.high(v1)) >> 5
                let m2 = S.multi(r1(29, 5), S.high(v1)) >> 5
                let t2 = S.addclip20(s1, (m1 >> 1) ^ 0xFFFFF, 1)
                setR1(29, 5, S.addclip20(t2, m2 >> 1, m2 & 1))
            }
            do { // 20
                let v1 = r2(31, 10)
                let s1 = unpackAt(29, 11)
                packAt(29, 5, r1(28, 0))
                let m1 = S.multi(s1, S.high(v1)) >> 5
                let m2 = S.multi(r1(28, 1), S.high(v1)) >> 5
                let t2 = S.addclip20(s1, (m1 >> 1) ^ 0xFFFFF, 1)
                setR1(28, 1, S.addclip20(t2, m2 >> 1, m2 & 1))
                packAt(29, 9, r1(29, 1))
            }
            do { // 21
                let v1 = r2(31, 2)
                let v2 = r1(29, 5)
                rcadd2 = S.multi(v2, S.high(v1)) >> 5
                rcaddB2 = S.multi(v2, S.low(v1)) >> 5
            }
            do { // 22
                let v1 = r2(31, 3)
                let v2 = r1(29, 5)
                rcadd3 = S.multi(v2, S.high(v1)) >> 5
                rcaddB3 = S.multi(v2, S.low(v1)) >> 5
            }
            do { // 23
                let v1 = r2(31, 4)
                let v2 = r1(28, 1)
                rcadd4 = S.multi(v2, S.high(v1)) >> 5
                rcaddB4 = S.multi(v2, S.low(v1)) >> 5
            }
            do { // 31
                let v1 = r2(31, 5)
                let v2 = r1(28, 1)
                rcadd5 = S.multi(v2, S.high(v1)) >> 5
                rcaddB5 = S.multi(v2, S.low(v1)) >> 5
                effectsAddressGenerator()
            }
        }

        ram1[31 * 8 + 1] = 0
        ram1[31 * 8 + 3] = 0
        rcsum0 = 0
        rcsum1 = 0
        // (As constants, so that `mix` reads them without the checks a captured variable is given.)
        let returns = (rcadd0, rcadd1, rcadd2, rcadd3, rcadd4, rcadd5)
        let returnsB = (rcaddB0, rcaddB1, rcaddB2, rcaddB3, rcaddB4, rcaddB5)

        let lastSlot = slots - 1
        let partTable = partTable
        var partRound: UnsafeMutablePointer<Int32>?
        if partTable != nil, let rounds = partRounds, partRoundCount < Self.partRoundCapacity {
            partRound = rounds + partRoundCount * 16
            partRound!.update(repeating: 0, count: 16)
            partRoundCount += 1
        }

        /// A slot's sound and sends into the mix, and the effects' returns at the slots that follow theirs.
        @inline(__always) func mix(_ slot: Int, _ sampleL: Int32, _ sampleR: Int32, _ rc0: Int32, _ rc1: Int32) {
            let slot2 = slot == lastSlot ? 31 : slot + 1
            switch slot2 {
            case 17: setR1(31, 1, S.addclip20(r1(31, 1), returns.0 >> 1, returns.0 & 1))
            case 18: setR1(31, 3, S.addclip20(r1(31, 3), returns.1 >> 1, returns.1 & 1))
            case 21: setR1(31, 1, S.addclip20(r1(31, 1), returns.2 >> 1, returns.2 & 1))
            case 22: setR1(31, 3, S.addclip20(r1(31, 3), returns.3 >> 1, returns.3 & 1))
            case 23: setR1(31, 1, S.addclip20(r1(31, 1), returns.4 >> 1, returns.4 & 1))
            case 31: setR1(31, 3, S.addclip20(r1(31, 3), returns.5 >> 1, returns.5 & 1))
            default: break
            }

            let sumL = S.addclip20(r1(31, 1), sampleL >> 6, (sampleL >> 5) & 1)
            let sumR = S.addclip20(r1(31, 3), sampleR >> 6, (sampleR >> 5) & 1)

            switch slot2 {
            case 17: rcsum1 = S.addclip20(rcsum1, returnsB.0 >> 1, returnsB.0 & 1)
            case 18: rcsum1 = S.addclip20(rcsum1, returnsB.1 >> 1, returnsB.1 & 1)
            case 21: rcsum0 = S.addclip20(rcsum0, returnsB.2 >> 1, returnsB.2 & 1)
            case 22: rcsum1 = S.addclip20(rcsum1, returnsB.3 >> 1, returnsB.3 & 1)
            case 23: rcsum0 = S.addclip20(rcsum0, returnsB.4 >> 1, returnsB.4 & 1)
            case 31: rcsum1 = S.addclip20(rcsum1, returnsB.5 >> 1, returnsB.5 & 1)
            default: break
            }

            rcsum0 = S.addclip20(rcsum0, rc0 >> 1, rc0 & 1)
            rcsum1 = S.addclip20(rcsum1, rc1 >> 1, rc1 & 1)

            if slot != lastSlot {
                setR1(31, 1, sumL)
                setR1(31, 3, sumR)
            } else {
                accumL = sumL
                accumR = sumR
            }
        }

        for slot in 0 ..< slots {
            let base1 = slot &* 8, base2 = slot &* 16
            let okey = ram2[base2 + 7] & 0x20 != 0
            let key = (voiceActive >> UInt32(slot)) & 1 != 0
            let active = okey && key
            let kon = key && !okey

            if !key, nfs, slot < 28 {
                // A slot not keyed on is not active, and its pan and sends are taken as nothing: it adds
                // nothing to the mix, and all it works out but its filter's envelope is cleared at the end
                // of its turn, as below. So that is all that is done.
                var level11 = ram2[base2 + 11]
                _ = envelope(2, Int(ram2[base2 + 5]), &level11, false)
                ram2[base2 + 11] = level11
                mix(slot, 0, 0, 0, 0)
                ram1[base1 + 1] = 0
                ram1[base1 + 3] = 0
                ram1[base1 + 5] = 0
                ram2[base2 + 8] = 0
                ram2[base2 + 9] = 0
                ram2[base2 + 10] = 0
                continue
            }

            // The address generator.
            var b15 = ram2[base2 + 8] & 0x8000 != 0
            let b6 = ram2[base2 + 7] & 0x40 != 0
            let b7 = ram2[base2 + 7] & 0x80 != 0
            let hiaddr = Int32((ram2[base2 + 7] >> 8) & 15)
            let oldNibble = Int32((ram2[base2 + 7] >> 12) & 15)

            let address = Int32(bitPattern: ram1[base1 + 4])
            let addressEnd = Int32(bitPattern: ram1[base1 + 0])
            let addressLoop = Int32(bitPattern: ram1[base1 + 2])

            var cmp1 = b15 ? addressLoop : addressEnd
            let nibbleCmp1 = cmp1 & 0xFFFF0 == address & 0xFFFF0
            var irqFlag: Bool
            if kon {
                irqFlag = (cmp1 &+ addressLoop) & 0x100000 != 0
            } else {
                irqFlag = (address &+ ((0 &- addressLoop) & 0xFFFFF)) & 0x100000 != 0
            }
            irqFlag = irqFlag != b7

            let nibbleAddress = !b6 && nibbleCmp1 ? addressLoop : address
            let addressB4 = nibbleAddress & 0x10 != 0
            var waveAddress = nibbleAddress >> 5
            let xor2 = addressB4 != b7
            let check1 = xor2 && active
            let xor1 = b15 != !nibbleCmp1
            let nibbleAdd = b6 ? check1 && xor1 : (!nibbleCmp1 && check1)
            let nibbleSubtract = b6 && !xor1 && active && !xor2
            let nibbleStep = Int32(nibbleAdd ? 1 : 0) &- Int32(nibbleSubtract ? 1 : 0)
            waveAddress = b7 ? waveAddress &- nibbleStep : waveAddress &+ nibbleStep
            waveAddress &= 0xFFFFF

            var newNibble = Int32(readROM(UInt32(bitPattern: hiaddr << 20 | waveAddress), Model.self))
            let newNibbleSelect = addressB4 != ((b6 || !nibbleCmp1) && okey)
            newNibble = newNibbleSelect ? (newNibble >> 4) & 15 : newNibble & 15

            var subPhase = Int(ram2[base2 + 8] & 0x3FFF)
            let interpRatio = (subPhase >> 7) & 127
            subPhase &+= Int(ram2[Int(ram2[base2 + 7] & 31) * 16])
            let subPhaseOverflow = (subPhase >> 14) & 7
            if nfs {
                ram2[base2 + 8] &= ~0x3FFF
                ram2[base2 + 8] |= UInt16(subPhase & 0x3FFF)
            }

            // The four samples from the slot's address on, and where it goes next: the address generator
            // stepped four times (Nuked SC-55's steps 11 to 23).
            let samp0, samp1, samp2, samp3: Int32
            let nibbleCmp3, nibbleCmp4, nibbleCmp5: Bool
            var nextAddress: Int32, useNew: Bool, nextB15: Bool
            let endOffset = (addressEnd &- address) & 0xFFFFF
            if !b6, !b7, !b15, !kon, address <= 0xFFFFB, endOffset > 3 {
                // Forwards, its end not among the four: each step is a sample on, and no comparison holds.
                let at = UInt32(bitPattern: hiaddr << 20 | address)
                samp0 = Int32(Int8(bitPattern: readROM(at, Model.self)))
                samp1 = Int32(Int8(bitPattern: readROM(at &+ 1, Model.self)))
                samp2 = Int32(Int8(bitPattern: readROM(at &+ 2, Model.self)))
                samp3 = Int32(Int8(bitPattern: readROM(at &+ 3, Model.self)))
                let sixteen = address & 0xFFFF0
                nibbleCmp3 = sixteen == (address &+ 1) & 0xFFFF0
                nibbleCmp4 = sixteen == (address &+ 2) & 0xFFFF0
                nibbleCmp5 = sixteen == (address &+ 3) & 0xFFFF0
                let steps = min(subPhaseOverflow, 4)
                nextAddress = address &+ Int32(steps)
                useNew = steps > 0 && sixteen != nextAddress & 0xFFFF0
                nextB15 = false
            } else {
                var addressCount = address
                samp0 = Int32(Int8(bitPattern: readROM(UInt32(bitPattern: hiaddr << 20 | addressCount), Model.self)))
                cmp1 = b15 ? addressLoop : addressEnd
                var addressCmp = cmp1 & 0xFFFFF == addressCount & 0xFFFFF
                nextAddress = addressCount
                // (Whether the first sample's address is in another 16 than the slot's: it is the same address.)
                useNew = false
                nextB15 = b15

                addressCount = Self.advance(addressCount, compared: addressCmp, b6: b6, b7: b7, b15: b15, kon: kon, loop: addressLoop) // 11
                b15 = b6 && (b15 != addressCmp)
                samp1 = Int32(Int8(bitPattern: readROM(UInt32(bitPattern: hiaddr << 20 | addressCount), Model.self)))
                nibbleCmp3 = address & 0xFFFF0 == addressCount & 0xFFFF0
                cmp1 = b15 ? addressLoop : addressEnd
                addressCmp = cmp1 & 0xFFFFF == addressCount & 0xFFFFF
                if subPhaseOverflow >= 1 {
                    nextAddress = addressCount
                    useNew = !nibbleCmp3
                    nextB15 = b15
                }

                addressCount = Self.advance(addressCount, compared: addressCmp, b6: b6, b7: b7, b15: b15, kon: kon, loop: addressLoop) // 15
                b15 = b6 && (b15 != addressCmp)
                samp2 = Int32(Int8(bitPattern: readROM(UInt32(bitPattern: hiaddr << 20 | addressCount), Model.self)))
                nibbleCmp4 = address & 0xFFFF0 == addressCount & 0xFFFF0
                cmp1 = b15 ? addressLoop : addressEnd
                addressCmp = cmp1 & 0xFFFFF == addressCount & 0xFFFFF
                if subPhaseOverflow >= 2 {
                    nextAddress = addressCount
                    useNew = !nibbleCmp4
                    nextB15 = b15
                }

                addressCount = Self.advance(addressCount, compared: addressCmp, b6: b6, b7: b7, b15: b15, kon: kon, loop: addressLoop) // 19
                b15 = b6 && (b15 != addressCmp)
                samp3 = Int32(Int8(bitPattern: readROM(UInt32(bitPattern: hiaddr << 20 | addressCount), Model.self)))
                nibbleCmp5 = address & 0xFFFF0 == addressCount & 0xFFFF0
                cmp1 = b15 ? addressLoop : addressEnd
                addressCmp = cmp1 & 0xFFFFF == addressCount & 0xFFFFF
                if subPhaseOverflow >= 3 {
                    nextAddress = addressCount
                    useNew = !nibbleCmp5
                    nextB15 = b15
                }

                addressCount = Self.advance(addressCount, compared: addressCmp, b6: b6, b7: b7, b15: b15, kon: kon, loop: addressLoop) // 23
                let nibbleCmp6 = address & 0xFFFF0 == addressCount & 0xFFFF0
                if subPhaseOverflow >= 4 {
                    nextAddress = addressCount
                    useNew = !nibbleCmp6
                }
            }

            if active, nfs { ram1[base1 + 4] = UInt32(bitPattern: nextAddress) }
            if nfs {
                ram2[base2 + 8] &= ~0x8000
                if nextB15 { ram2[base2 + 8] |= 0x8000 }
            }

            // DPCM.
            var reference = Int32(bitPattern: ram1[base1 + 5])
            let shift0 = (10 &- oldNibble) & 15
            let shift1 = (10 &- (nibbleCmp3 ? oldNibble : newNibble)) & 15
            let shift2 = (10 &- (nibbleCmp4 ? oldNibble : newNibble)) & 15
            let shift3 = (10 &- (nibbleCmp5 ? oldNibble : newNibble)) & 15
            var shifted = ((samp0 &<< 10) &<< 1) >> shift0
            if subPhaseOverflow >= 1 { reference = S.addclip20(reference, shifted >> 1, shifted & 1) }
            shifted = ((samp1 &<< 10) &<< 1) >> shift1
            if subPhaseOverflow >= 2 { reference = S.addclip20(reference, shifted >> 1, shifted & 1) }
            shifted = ((samp2 &<< 10) &<< 1) >> shift2
            if subPhaseOverflow >= 3 { reference = S.addclip20(reference, shifted >> 1, shifted & 1) }
            shifted = ((samp3 &<< 10) &<< 1) >> shift3
            if subPhaseOverflow >= 4 { reference = S.addclip20(reference, shifted >> 1, shifted & 1) }

            // Interpolation.
            var test = Int32(bitPattern: ram1[base1 + 5])
            var step = S.multi(interpolation[interpRatio] &<< 6, Int8(truncatingIfNeeded: samp0)) >> 8
            step = (step &<< 1) >> shift0
            test = S.addclip20(test, step >> 1, step & 1)
            step = S.multi(interpolation[128 + interpRatio] &<< 6, Int8(truncatingIfNeeded: samp1)) >> 8
            step = (step &<< 1) >> shift1
            test = S.addclip20(test, step >> 1, step & 1)
            step = S.multi(interpolation[256 + interpRatio] &<< 6, Int8(truncatingIfNeeded: samp2)) >> 8
            step = (step &<< 1) >> shift2

            let reg1 = Int32(bitPattern: ram1[base1 + 1])
            let reg3 = Int32(bitPattern: ram1[base1 + 3])
            let reg26 = Int8(truncatingIfNeeded: (ram2[base2 + 6] >> 8) & 127)

            test = S.addclip20(test, step >> 1, step & 1)

            // The filter (the SC-55's, in the chip's 20-bit arithmetic; the SC-55mkII's in 32 bits, as Nuked
            // SC-55 has it, "to avoid overflow": its registers as they are, the sample brought to 32 bits from 20).
            let filter = Int(ram2[base2 + 11])
            let v3: Int32
            if Model.mk2 {
                let mult1 = reg1 &* Int32(S.high(filter)) // 8
                let mult2 = reg1 &* Int32((filter >> 1) & 127) // 9
                let mult3 = reg1 &* Int32(reg26) // 10
                let v2 = reg3 &+ (mult1 >> 6) &+ ((mult1 >> 5) & 1) // 9
                let v1 = v2 &+ (mult2 >> 13) &+ ((mult2 >> 12) & 1) // 10
                let subvar = v1 &+ (mult3 >> 6) &+ ((mult3 >> 5) & 1) // 11
                ram1[base1 + 3] = UInt32(bitPattern: v1)
                v3 = ((test &<< 12) >> 12) &- subvar // 12
                let mult4 = v3 &* Int32(S.high(filter))
                let mult5 = v3 &* Int32((filter >> 1) & 127)
                let v4 = reg1 &+ (mult4 >> 6) &+ ((mult4 >> 5) & 1) // 14
                let v5 = v4 &+ (mult5 >> 13) &+ ((mult5 >> 12) & 1) // 15
                ram1[base1 + 1] = UInt32(bitPattern: v5)
            } else {
                let mult1 = S.multi(reg1, S.high(filter)) // 8
                let mult2 = S.multi(reg1, Int8(truncatingIfNeeded: (filter >> 1) & 127)) // 9
                let mult3 = S.multi(reg1, reg26) // 10
                let v2 = S.addclip20(reg3, mult1 >> 6, (mult1 >> 5) & 1) // 9
                let v1 = S.addclip20(v2, mult2 >> 13, (mult2 >> 12) & 1) // 10
                let subvar = S.addclip20(v1, mult3 >> 6, (mult3 >> 5) & 1) // 11
                ram1[base1 + 3] = UInt32(bitPattern: v1)
                v3 = S.addclip20(test, subvar ^ 0xFFFFF, 1) // 12
                let mult4 = S.multi(v3, S.high(filter))
                let mult5 = S.multi(v3, Int8(truncatingIfNeeded: (filter >> 1) & 127))
                let v4 = S.addclip20(reg1, mult4 >> 6, (mult4 >> 5) & 1) // 14
                let v5 = S.addclip20(v4, mult5 >> 13, (mult5 >> 12) & 1) // 15
                ram1[base1 + 1] = UInt32(bitPattern: v5)
            }

            ram1[base1 + 5] = UInt32(bitPattern: reference)

            if active, ram2[base2 + 6] & 1 != 0, ram2[base2 + 8] & 0x4000 == 0, !irqAssert, irqFlag {
                if nfs { ram2[base2 + 8] |= 0x4000 }
                irqAssert = true
                irqChannel = UInt8(slot)
                mcu.setInterrupt(SC55MCU.Interrupt.irq0, true)
            }

            var level9 = ram2[base2 + 9], level10 = ram2[base2 + 10], level11 = ram2[base2 + 11]
            let volume1 = envelope(0, Int(ram2[base2 + 3]), &level9, active)
            let volume2 = envelope(1, Int(ram2[base2 + 4]), &level10, active)
            _ = envelope(2, Int(ram2[base2 + 5]), &level11, active)
            ram2[base2 + 9] = level9
            ram2[base2 + 10] = level10
            ram2[base2 + 11] = level11

            let sample = ram2[base2 + 6] & 2 == 0 ? Int32(bitPattern: ram1[base1 + 3]) : v3

            let multiv1 = S.multi(sample, Int8(truncatingIfNeeded: volume1 >> 8))
            let multiv2 = S.multi(sample, Int8(truncatingIfNeeded: (volume1 >> 1) & 127))
            let sample2 = S.addclip20(multiv1 >> 6, multiv2 >> 13, ((multiv2 >> 12) | (multiv1 >> 5)) & 1)
            let multiv3 = S.multi(sample2, Int8(truncatingIfNeeded: volume2 >> 8))
            let multiv4 = S.multi(sample2, Int8(truncatingIfNeeded: (volume2 >> 1) & 127))
            var sample3 = S.addclip20(multiv3 >> 6, multiv4 >> 13, ((multiv4 >> 12) | (multiv3 >> 5)) & 1)
            if let partTable, active {
                // (Only for the listener: the parts' lamps and scopes, and a part muted.)
                let part = Int(partTable[slot] & 15)
                if mutedParts & (1 << UInt32(part)) != 0 {
                    sample3 = 0
                } else {
                    partRound?[part] &+= sample3
                    let size = sample3 < 0 ? 0 &- sample3 : sample3
                    if size > partPeaks[part] { partPeaks[part] = size }
                }
            }

            let pan = active ? Int(ram2[base2 + 1]) : 0
            let rc = active ? Int(ram2[base2 + 2]) : 0
            let sampleL = S.multi(sample3, S.high(pan))
            let sampleR = S.multi(sample3, S.low(pan))
            let rc0 = S.multi(sample3, S.high(rc)) >> 5 // reverb
            let rc1 = S.multi(sample3, S.low(rc)) >> 5 // chorus

            mix(slot, sampleL, sampleR, rc0, rc1)

            if key, nfs {
                ram2[base2 + 7] &= ~0xF020
                ram2[base2 + 7] |= UInt16(truncatingIfNeeded: (useNew || kon ? newNibble : oldNibble) << 12)
                ram2[base2 + 7] |= 0x20
            }

            if !active {
                if nfs {
                    ram1[base1 + 1] = 0
                    ram1[base1 + 3] = 0
                    ram1[base1 + 5] = 0
                }
                ram2[base2 + 8] = 0
                ram2[base2 + 9] = 0
                ram2[base2 + 10] = 0
            }
        }

        if nfs { ram2[31 * 16 + 7] |= 0x20 }
        nfs = true
    }

    /// A slot's address, a sample on (or back), or to its loop from its end (Nuked SC-55's address generator).
    @inline(__always) private static func advance(_ address: Int32, compared: Bool, b6: Bool, b7: Bool, b15: Bool, kon: Bool, loop: Int32) -> Int32 {
        let c1 = !b6 && compared ? loop : address
        var count2 = kon || (!b6 && compared) ? c1 : address
        let add = (!compared && b6 && !b15) || (!compared && !b6)
        let sub = !compared && b6 && b15
        let delta = Int32(add ? 1 : 0) &- Int32(sub ? 1 : 0)
        count2 = b7 ? count2 &- delta : count2 &+ delta
        return count2 & 0xFFFFF
    }

    /// The address generator of slot 31, which runs the effects' delay lines.
    private func effectsAddressGenerator() {
        let okey = ram2[31 * 16 + 7] & 0x20 != 0
        let active = okey
        let kon = !okey

        var b15 = ram2[31 * 16 + 8] & 0x8000 != 0
        let b6 = ram2[31 * 16 + 7] & 0x40 != 0
        let b7 = ram2[31 * 16 + 7] & 0x80 != 0

        let address = Int32(bitPattern: ram1[31 * 8 + 4])
        let addressEnd = Int32(bitPattern: ram1[31 * 8 + 0])
        let addressLoop = Int32(bitPattern: ram1[31 * 8 + 2])

        var subPhase = Int(ram2[31 * 16 + 8] & 0x3FFF)
        subPhase &+= Int(ram2[Int(ram2[31 * 16 + 7] & 31) * 16])
        let subPhaseOverflow = (subPhase >> 14) & 7
        if nfs {
            ram2[31 * 16 + 8] &= ~0x3FFF
            ram2[31 * 16 + 8] |= UInt16(subPhase & 0x3FFF)
        }

        var addressCount = address
        var cmp1 = b15 ? addressLoop : addressEnd
        var addressCmp = cmp1 & 0xFFFFF == addressCount & 0xFFFFF
        var nextB15 = b15
        var nextAddress = addressCount

        cmp1 = !b6 && addressCmp ? addressLoop : addressCount
        var count2 = kon || (!b6 && addressCmp) ? cmp1 : addressCount
        let add = (!addressCmp && b6 && !b15) || (!addressCmp && !b6)
        let sub = !addressCmp && b6 && b15
        let delta = Int32(add ? 1 : 0) &- Int32(sub ? 1 : 0)
        count2 = b7 ? count2 &- delta : count2 &+ delta
        addressCount = count2 & 0xFFFFF
        b15 = b6 && (b15 != addressCmp)

        cmp1 = b15 ? addressLoop : addressEnd
        addressCmp = cmp1 & 0xFFFFF == addressCount & 0xFFFFF
        _ = addressCmp

        if subPhaseOverflow >= 1 {
            nextAddress = addressCount
            nextB15 = b15
        }
        if active, nfs { ram1[31 * 8 + 4] = UInt32(bitPattern: nextAddress) }
        if nfs {
            ram2[31 * 16 + 8] &= ~0x8000
            if nextB15 { ram2[31 * 16 + 8] |= 0x8000 }
        }

        let t2 = Int32(bitPattern: ram1[31 * 8 + 4]) &- addressLoop
        let t3 = addressEnd &- t2
        let t4 = Int32(bitPattern: ram1[31 * 8 + 4])
        ram2[29 * 16 + 10] = UInt16(truncatingIfNeeded: t3)
        ram2[29 * 16 + 11] = UInt16(truncatingIfNeeded: t4)
    }
}
