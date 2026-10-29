// Copyright (C) 2021, 2024 nukeykt; (C) 2024-2026 J.C. Moyer
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A Swift port of Nuked SC-55's interpreter of the H8/532's instructions (mcu_opcodes.cpp, the original one, as
// jcmoyer's fork of Nuked SC-55 keeps it), free software under the GNU General Public License, version 2 or any
// later version (see THIRD-PARTY.md). What it does to the flags, its quirks included, is Nuked SC-55's: the
// firmware is heard as it plays there.

extension SC55MCU {
    // MARK: Flags

    @inline(__always) func setFlag(_ on: Bool, _ mask: UInt16) {
        sr = on ? sr | mask : sr & ~mask
    }

    /// N and Z from a result of the operand's size, and V cleared.
    @inline(__always) func setFlagsCommon(_ value: UInt32, word: Bool) {
        let v = word ? value & 0xFFFF : value & 0xFF
        let n: UInt16 = v & (word ? 0x8000 : 0x80) != 0 ? Self.statusN : 0
        let z: UInt16 = v == 0 ? Self.statusZ : 0
        sr = sr & ~(Self.statusN | Self.statusZ | Self.statusV) | n | z
    }

    /// N, Z, V and C at once.
    @inline(__always) func setFlags(n: Bool, z: Bool, v: Bool, c: Bool) {
        let flags = (n ? Self.statusN : 0) | (z ? Self.statusZ : 0) | (v ? Self.statusV : 0) | (c ? Self.statusC : 0)
        sr = sr & ~(Self.statusN | Self.statusZ | Self.statusV | Self.statusC) | flags
    }

    @inline(__always) func subtract(_ a: Int32, _ b: Int32, carry: Int32, word: Bool) -> Int32 {
        var t1: Int32, s1: Int32
        let c: Bool, v: Bool, n: Bool, z: Bool
        if word {
            s1 = Int32(Int16(truncatingIfNeeded: a)) &- Int32(Int16(truncatingIfNeeded: b)) &- carry
            t1 = Int32(UInt16(truncatingIfNeeded: a)) &- Int32(UInt16(truncatingIfNeeded: b)) &- carry
            c = (t1 >> 16) & 1 != 0
            t1 &= 0xFFFF
            n = t1 & 0x8000 != 0
            v = s1 < Int32(Int16.min) || s1 > Int32(Int16.max)
        } else {
            s1 = Int32(Int8(truncatingIfNeeded: a)) &- Int32(Int8(truncatingIfNeeded: b)) &- carry
            t1 = Int32(UInt8(truncatingIfNeeded: a)) &- Int32(UInt8(truncatingIfNeeded: b)) &- carry
            c = (t1 >> 8) & 1 != 0
            t1 &= 0xFF
            n = t1 & 0x80 != 0
            v = s1 < Int32(Int8.min) || s1 > Int32(Int8.max)
        }
        z = t1 == 0
        setFlags(n: n, z: z, v: v, c: c)
        return t1
    }

    @inline(__always) func add(_ a: Int32, _ b: Int32, carry: Int32, word: Bool) -> Int32 {
        var t1: Int32, s1: Int32
        let c: Bool, v: Bool, n: Bool, z: Bool
        if word {
            s1 = Int32(Int16(truncatingIfNeeded: a)) &+ Int32(Int16(truncatingIfNeeded: b)) &+ carry
            t1 = Int32(UInt16(truncatingIfNeeded: a)) &+ Int32(UInt16(truncatingIfNeeded: b)) &+ carry
            c = (t1 >> 16) & 1 != 0
            t1 &= 0xFFFF
            n = t1 & 0x8000 != 0
            v = s1 < Int32(Int16.min) || s1 > Int32(Int16.max)
        } else {
            s1 = Int32(Int8(truncatingIfNeeded: a)) &+ Int32(Int8(truncatingIfNeeded: b)) &+ carry
            t1 = Int32(UInt8(truncatingIfNeeded: a)) &+ Int32(UInt8(truncatingIfNeeded: b)) &+ carry
            c = (t1 >> 8) & 1 != 0
            t1 &= 0xFF
            n = t1 & 0x80 != 0
            v = s1 < Int32(Int8.min) || s1 > Int32(Int8.max)
        }
        z = t1 == 0
        setFlags(n: n, z: z, v: v, c: c)
        return t1
    }

    // MARK: Control registers

    func controlRegisterWrite(_ reg: Int, word: Bool, _ data: UInt32) {
        if word {
            switch reg {
            case 0: sr = UInt16(truncatingIfNeeded: data) & Self.statusMask
            case 5: dp = UInt8(truncatingIfNeeded: data)
            case 4: ep = UInt8(truncatingIfNeeded: data)
            case 3: br = UInt8(truncatingIfNeeded: data)
            default: break
            }
        } else {
            switch reg {
            case 1:
                sr &= ~0xFF
                sr |= UInt16(data & 0xFF)
                sr &= Self.statusMask
            case 3: br = UInt8(truncatingIfNeeded: data)
            case 4: ep = UInt8(truncatingIfNeeded: data)
            case 5: dp = UInt8(truncatingIfNeeded: data)
            case 7: tp = UInt8(truncatingIfNeeded: data)
            default: break
            }
        }
    }

    func controlRegisterRead(_ reg: Int, word: Bool) -> UInt32 {
        if word {
            switch reg {
            case 0: return UInt32(sr & Self.statusMask)
            case 5: return UInt32(dp) | UInt32(dp) << 8
            case 4: return UInt32(ep) | UInt32(ep) << 8
            case 3: return UInt32(br) | UInt32(br) << 8
            default: return 0
            }
        }
        switch reg {
        case 1: return UInt32(sr & Self.statusMask) & 0xFF
        case 3: return UInt32(br)
        case 4: return UInt32(ep)
        case 5: return UInt32(dp)
        case 7: return UInt32(tp)
        default: return 0
        }
    }

    // MARK: General operands

    @inline(__always) func operandRead() -> UInt32 {
        switch operandType {
        case Self.direct:
            let value = register(operandReg)
            return operandWord ? UInt32(value) : UInt32(value & 0xFF)
        case Self.immediate:
            return UInt32(operandData)
        default:
            let address = UInt32(operandEP) << 16 | UInt32(operandEA)
            if operandWord {
                if operandEA & 1 != 0 { raise(Self.exceptionAddressError) }
                return UInt32(read16(address))
            }
            return UInt32(read(address))
        }
    }

    @inline(__always) func operandWrite(_ data: UInt32) {
        switch operandType {
        case Self.direct:
            if operandWord {
                setRegister(operandReg, UInt16(truncatingIfNeeded: data))
            } else {
                setRegister(operandReg, register(operandReg) & 0xFF00 | UInt16(data & 0xFF))
            }
        case Self.immediate:
            raise(Self.exceptionInvalidInstruction)
        default:
            let address = UInt32(operandEP) << 16 | UInt32(operandEA)
            if operandWord {
                if operandEA & 1 != 0 { raise(Self.exceptionAddressError) }
                write16(address, UInt16(truncatingIfNeeded: data))
            } else {
                write(address, UInt8(truncatingIfNeeded: data))
            }
        }
    }

    /// Sets a register's low byte (byte size) or all of it (word size).
    @inline(__always) func setRegister(_ n: Int, sized value: UInt32, word: Bool) {
        if word {
            setRegister(n, UInt16(truncatingIfNeeded: value))
        } else {
            setRegister(n, register(n) & 0xFF00 | UInt16(value & 0xFF))
        }
    }

    // MARK: Running an instruction

    func execute() {
        let operand = readCodeAdvance()
        switch operand {
        case 0x00: break
        case 0x01, 0x06, 0x07, 0x10, 0x11: jump(operand)
        case 0x02: // LDM
            let list = readCodeAdvance()
            for i in 0 ..< 8 where list & (1 << i) != 0 {
                let data = pop()
                if i != 7 { setRegister(i, data) }
            }
        case 0x03: // PJSR
            let page = readCodeAdvance()
            var address = UInt16(readCodeAdvance()) << 8
            address |= UInt16(readCodeAdvance())
            push(pc)
            push(UInt16(cp))
            cp = page
            pc = address
        case 0x04, 0x05, 0x0C, 0x0D, 0x15, 0x1D, 0xA0 ... 0xFF: general(operand)
        case 0x08: // TRAPA
            let code = readCodeAdvance()
            if code & 0xF0 == 0x10 { trapsPending |= 1 << UInt16(code & 0x0F) }
        case 0x0A: // RTE
            sr = pop()
            cp = UInt8(truncatingIfNeeded: pop())
            pc = pop()
            exceptionIgnored = true
        case 0x0E, 0x1E: // BSR
            let disp: UInt16
            if operand == 0x0E {
                disp = UInt16(bitPattern: Int16(Int8(bitPattern: readCodeAdvance())))
            } else {
                var d = UInt16(readCodeAdvance()) << 8
                d |= UInt16(readCodeAdvance())
                disp = d
            }
            push(pc)
            pc &+= disp
        case 0x12: // STM
            let list = readCodeAdvance()
            for i in (0 ..< 8).reversed() where list & (1 << i) != 0 {
                var data = register(i)
                if i == 7 { data &-= 2 }
                push(data)
            }
        case 0x13: // PJMP
            let page = readCodeAdvance()
            var address = UInt16(readCodeAdvance()) << 8
            address |= UInt16(readCodeAdvance())
            cp = page
            pc = address
        case 0x14, 0x1C: // RTD
            let imm = Int16(Int8(bitPattern: readCodeAdvance()))
            pc = pop()
            if operand == 0x14 { r7 = UInt16(bitPattern: Int16(bitPattern: r7) &+ imm) }
        case 0x18: // JSR
            var address = UInt16(readCodeAdvance()) << 8
            address |= UInt16(readCodeAdvance())
            push(pc)
            pc = address
        case 0x19: // RTS
            pc = pop()
        case 0x1A: // SLEEP
            sleeping = true
        case 0x20 ... 0x3F: branch(operand)
        case 0x40 ... 0x4F: // CMP:E / CMP:I
            let reg = Int(operand & 7)
            let word = operand & 0x08 != 0
            var t2: Int32
            if word {
                t2 = Int32(readCodeAdvance()) << 8
                t2 |= Int32(readCodeAdvance())
            } else {
                t2 = Int32(readCodeAdvance())
            }
            _ = subtract(Int32(register(reg)), t2, carry: 0, word: word)
        case 0x50 ... 0x57: // MOV:E
            let reg = Int(operand & 7)
            let data = readCodeAdvance()
            setRegister(reg, register(reg) & 0xFF00 | UInt16(data))
            setFlagsCommon(UInt32(data), word: false)
        case 0x58 ... 0x5F: // MOV:I
            let reg = Int(operand & 7)
            var data = UInt16(readCodeAdvance()) << 8
            data |= UInt16(readCodeAdvance())
            setRegister(reg, data)
            setFlagsCommon(UInt32(data), word: true)
        case 0x60 ... 0x6F: // MOV:L
            let reg = Int(operand & 7)
            let address = UInt16(br) << 8 | UInt16(readCodeAdvance())
            if operand & 0x08 != 0 {
                if address & 1 != 0 { raise(Self.exceptionAddressError) }
                let data = read16(UInt32(address))
                setRegister(reg, data)
                setFlagsCommon(UInt32(data), word: true)
            } else {
                let data = read(UInt32(address))
                setRegister(reg, register(reg) & 0xFF00 | UInt16(data))
                setFlagsCommon(UInt32(data), word: false)
            }
        case 0x70 ... 0x7F: // MOV:S
            let reg = Int(operand & 7)
            let address = UInt16(br) << 8 | UInt16(readCodeAdvance())
            if operand & 0x08 != 0 {
                if address & 1 != 0 { raise(Self.exceptionAddressError) }
                let data = register(reg)
                write16(UInt32(address), data)
                setFlagsCommon(UInt32(data), word: true)
            } else {
                let data = register(reg) & 0xFF
                write(UInt32(address), UInt8(data))
                setFlagsCommon(UInt32(data), word: false)
            }
        case 0x80 ... 0x9F: // MOV:F
            let reg = Int(operand & 7)
            let size = operand & 0x08 != 0
            let disp = Int8(bitPattern: readCodeAdvance())
            let address = UInt32(UInt16(bitPattern: Int16(bitPattern: r6) &+ Int16(disp))) | UInt32(tp) << 16
            if operand & 0x10 == 0 {
                if size {
                    // (As Nuked SC-55 has it: a word read, put over the register's low byte.)
                    let data = read16(address)
                    setRegister(reg, register(reg) & 0xFF00 | data)
                    setFlagsCommon(UInt32(data), word: false)
                } else {
                    let data = UInt16(read(address))
                    setRegister(reg, data)
                    setFlagsCommon(UInt32(data), word: true)
                }
            } else {
                if size {
                    let data = register(reg) & 0xFF
                    write(address, UInt8(data))
                    setFlagsCommon(UInt32(data), word: false)
                } else {
                    let data = register(reg)
                    write16(address, data)
                    setFlagsCommon(UInt32(data), word: true)
                }
            }
        default: break
        }
    }

    private func branch(_ operand: UInt8) {
        let disp: UInt16
        if operand & 0x10 != 0 {
            var d = UInt16(readCodeAdvance()) << 8
            d |= UInt16(readCodeAdvance())
            disp = d
        } else {
            disp = UInt16(bitPattern: Int16(Int8(bitPattern: readCodeAdvance())))
        }
        let n = sr & Self.statusN != 0, c = sr & Self.statusC != 0, z = sr & Self.statusZ != 0, v = sr & Self.statusV != 0
        let taken: Bool
        switch operand & 0x0F {
        case 0x0: taken = true
        case 0x1: taken = false
        case 0x2: taken = !(c || z)
        case 0x3: taken = c || z
        case 0x4: taken = !c
        case 0x5: taken = c
        case 0x6: taken = !z
        case 0x7: taken = z
        case 0x8: taken = !v
        case 0x9: taken = v
        case 0xA: taken = !n
        case 0xB: taken = n
        case 0xC: taken = n == v
        case 0xD: taken = n != v
        case 0xE: taken = !(z || n != v)
        default: taken = z || n != v
        }
        if taken { pc &+= disp }
    }

    private func jump(_ operand: UInt8) {
        switch operand {
        case 0x11:
            let code = readCodeAdvance()
            let high = code >> 3
            var low = Int(code & 7)
            if code == 0x19 { // PRTS
                cp = UInt8(truncatingIfNeeded: pop())
                pc = pop()
            } else if high == 0x19 { // PJSR @Rn
                push(pc)
                push(UInt16(cp))
                low &= ~1
                cp = UInt8(truncatingIfNeeded: register(low))
                pc = register(low + 1)
            } else if high == 0x1A { // JMP @Rn
                pc = register(low)
            } else if high == 0x1B { // JSR @Rn
                push(pc)
                pc = register(low)
            }
        case 0x01, 0x06, 0x07: // SCB/F, SCB/EQ, SCB/NE
            let code = readCodeAdvance()
            let reg = Int(code & 7)
            guard code >> 3 == 0x17 else { return }
            let disp = UInt16(bitPattern: Int16(Int8(bitPattern: readCodeAdvance())))
            let z = sr & Self.statusZ != 0
            if operand == 0x01 || (operand == 0x06 && z) || (operand == 0x07 && !z) {
                let value = register(reg) &- 1
                setRegister(reg, value)
                if value != 0xFFFF { pc &+= disp }
            }
        case 0x10: // JMP @aa:16
            var address = UInt16(readCodeAdvance()) << 8
            address |= UInt16(readCodeAdvance())
            pc = address
        default: break
        }
    }

    private func general(_ operand: UInt8) {
        var type = Self.direct
        var disp: UInt32 = 0
        var increase = 0
        let word = operand & 0x08 != 0
        let reg = Int(operand & 0x07)
        var data: UInt16 = 0
        var address: UInt32 = 0
        var addressPage: UInt8 = 0
        var ea: UInt16 = 0
        var ep: UInt8 = 0
        switch operand & 0xF0 {
        case 0xA0: type = Self.direct
        case 0xD0: type = Self.indirect
        case 0xE0:
            type = Self.indirect
            disp = UInt32(bitPattern: Int32(Int8(bitPattern: readCodeAdvance())))
        case 0xF0:
            type = Self.indirect
            disp = UInt32(readCodeAdvance()) << 8
            disp |= UInt32(readCodeAdvance())
        case 0xB0:
            type = Self.indirect
            increase = -1
        case 0xC0:
            type = Self.indirect
            increase = 1
        case 0x00:
            if reg == 5 {
                type = Self.absolute
                address = UInt32(br) << 8 | UInt32(readCodeAdvance())
                addressPage = 0
            } else if reg == 4 {
                type = Self.immediate
                data = UInt16(readCodeAdvance())
                if word {
                    data <<= 8
                    data |= UInt16(readCodeAdvance())
                }
            }
        case 0x10:
            if reg == 5 {
                type = Self.absolute
                address = UInt32(readCodeAdvance()) << 8
                address |= UInt32(readCodeAdvance())
                addressPage = dp
            }
        default: break
        }
        if type == Self.indirect {
            if increase < 0 { setRegister(reg, register(reg) &- (word || reg == 7 ? 2 : 1)) }
            ea = UInt16(truncatingIfNeeded: UInt32(register(reg)) &+ disp)
            if increase > 0 { setRegister(reg, register(reg) &+ (word || reg == 7 ? 2 : 1)) }
            ep = pageForRegister(reg)
        } else if type == Self.absolute {
            ea = UInt16(truncatingIfNeeded: address)
            ep = addressPage
        }
        var opcode = readCodeAdvance()
        opcodeExtended = opcode == 0
        if opcodeExtended { opcode = readCodeAdvance() }
        let opcodeReg = Int(opcode & 7)
        opcode >>= 3
        operandType = type
        operandEA = ea
        operandEP = ep
        operandWord = word
        operandReg = reg
        operandData = data
        operation(Int(opcode), opcodeReg)
    }

    private func operation(_ opcode: Int, _ opcodeReg: Int) {
        let word = operandWord
        let memory = operandType == Self.indirect || operandType == Self.absolute
        switch opcode {
        case 0x00: // MOV:G #xx, CMP:G #xx
            if opcodeReg == 6, memory {
                let data = UInt32(bitPattern: Int32(Int8(bitPattern: readCodeAdvance())))
                operandWrite(data)
                setFlagsCommon(data, word: word)
            } else if opcodeReg == 7, memory {
                var data = UInt32(readCodeAdvance()) << 8
                data |= UInt32(readCodeAdvance())
                operandWrite(data)
                setFlagsCommon(data, word: word)
            } else if opcodeReg == 4, memory, !word {
                let t1 = operandRead()
                let t2 = UInt32(readCodeAdvance())
                _ = subtract(Int32(bitPattern: t1), Int32(bitPattern: t2), carry: 0, word: false)
            } else if opcodeReg == 4, memory, word {
                let t1 = operandRead()
                let t2 = UInt32(UInt16(bitPattern: Int16(Int8(bitPattern: readCodeAdvance()))))
                _ = subtract(Int32(bitPattern: t1), Int32(bitPattern: t2), carry: 0, word: true)
            } else if opcodeReg == 5, memory, word {
                let t1 = operandRead()
                var t2 = UInt32(readCodeAdvance()) << 8
                t2 |= UInt32(readCodeAdvance())
                _ = subtract(Int32(bitPattern: t1), Int32(bitPattern: t2), carry: 0, word: true)
            } else if opcodeReg == 5, memory, !word {
                let t1 = operandRead()
                var t2 = UInt32(readCodeAdvance()) << 8
                t2 |= UInt32(readCodeAdvance())
                _ = subtract(Int32(bitPattern: t1), Int32(bitPattern: t2), carry: 0, word: false)
            }
        case 0x01: // ADD:Q
            let t1 = Int32(bitPattern: operandRead())
            var t2: Int32 = 0
            switch opcodeReg {
            case 0: t2 = 1
            case 1: t2 = 2
            case 4: t2 = -1
            case 5: t2 = -2
            default: break
            }
            operandWrite(UInt32(bitPattern: add(t1, t2, carry: 0, word: word)))
        case 0x02:
            clearGroup(opcodeReg)
        case 0x03:
            shiftGroup(opcodeReg)
        case 0x04: // ADD
            let t1 = add(Int32(register(opcodeReg)), Int32(bitPattern: operandRead()), carry: 0, word: word)
            setRegister(opcodeReg, sized: UInt32(bitPattern: t1), word: word)
        case 0x05: // ADDS
            var data = operandRead()
            if !word { data = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: data))) }
            setRegister(opcodeReg, UInt16(truncatingIfNeeded: UInt32(register(opcodeReg)) &+ data))
        case 0x06: // SUB
            let t1 = subtract(Int32(register(opcodeReg)), Int32(bitPattern: operandRead()), carry: 0, word: word)
            setRegister(opcodeReg, sized: UInt32(bitPattern: t1), word: word)
        case 0x07: // SUBS
            let t1 = Int32(register(opcodeReg)), t2 = Int32(bitPattern: operandRead())
            if word {
                setRegister(opcodeReg, UInt16(truncatingIfNeeded: t1 &- t2))
            } else {
                setRegister(opcodeReg, UInt16(truncatingIfNeeded: t1 &- Int32(Int8(truncatingIfNeeded: t2))))
            }
        case 0x08: // OR
            let value = register(opcodeReg) | UInt16(truncatingIfNeeded: operandRead())
            setRegister(opcodeReg, value)
            setFlagsCommon(UInt32(value), word: word)
        case 0x09: // ORC, BSET Rn
            if operandType == Self.immediate {
                let value = controlRegisterRead(opcodeReg, word: word) | operandRead()
                controlRegisterWrite(opcodeReg, word: word, value)
                if opcodeReg >= 2 { setFlagsCommon(value, word: word) }
                exceptionIgnored = true
            } else {
                var data = operandRead()
                let bit = UInt32(register(opcodeReg) & 0x0F)
                setFlag(data & (1 << bit) == 0, Self.statusZ)
                data |= 1 << bit
                operandWrite(data)
            }
        case 0x0A: // AND
            let data = UInt32(register(opcodeReg)) & operandRead()
            setRegister(opcodeReg, sized: data, word: word)
            setFlagsCommon(UInt32(register(opcodeReg)), word: word)
        case 0x0B: // ANDC, BCLR Rn
            if operandType == Self.immediate {
                let value = controlRegisterRead(opcodeReg, word: word) & operandRead()
                controlRegisterWrite(opcodeReg, word: word, value)
                if opcodeReg >= 2 { setFlagsCommon(value, word: word) }
                exceptionIgnored = true
            } else {
                var data = operandRead()
                let bit = UInt32(register(opcodeReg) & 0x0F)
                setFlag(data & (1 << bit) == 0, Self.statusZ)
                data &= ~(1 << bit)
                operandWrite(data)
            }
        case 0x0C: // XOR
            let value = register(opcodeReg) ^ UInt16(truncatingIfNeeded: operandRead())
            setRegister(opcodeReg, value)
            setFlagsCommon(UInt32(value), word: word)
        case 0x0E: // CMP
            _ = subtract(Int32(register(opcodeReg)), Int32(bitPattern: operandRead()), carry: 0, word: word)
        case 0x0F: // BTST Rn
            if operandType != Self.immediate {
                let data = operandRead()
                let bit = UInt32(register(opcodeReg) & 0x0F)
                setFlag(data & (1 << bit) == 0, Self.statusZ)
            }
        case 0x10, 0x12: // MOV:G, XCH
            guard !opcodeExtended else { return }
            if opcode & 2 != 0 {
                if operandType == Self.direct {
                    if word {
                        let a = register(opcodeReg), b = register(operandReg)
                        setRegister(opcodeReg, b)
                        setRegister(operandReg, a)
                    }
                } else {
                    let data = UInt32(register(opcodeReg))
                    operandWrite(data)
                    setFlagsCommon(data, word: word)
                }
            } else {
                let data = operandRead()
                setRegister(opcodeReg, sized: data, word: word)
                setFlagsCommon(data, word: word)
            }
        case 0x11: // LDC
            controlRegisterWrite(opcodeReg, word: word, operandRead())
            exceptionIgnored = true
        case 0x13: // STC
            operandWrite(controlRegisterRead(opcodeReg, word: word))
        case 0x14: // ADDX
            let c: Int32 = sr & Self.statusC != 0 ? 1 : 0
            let z = sr & Self.statusZ != 0
            let t1 = add(Int32(register(opcodeReg)), Int32(bitPattern: operandRead()), carry: c, word: word)
            if !z { setFlag(false, Self.statusZ) }
            setRegister(opcodeReg, sized: UInt32(bitPattern: t1), word: word)
        case 0x15: // MULXU
            var t1 = operandRead()
            var t2 = UInt32(register(opcodeReg))
            if !word { t2 &= 0xFF }
            t1 = t1 &* t2
            let n: Bool
            if word {
                let pair = opcodeReg & ~1
                setRegister(pair, UInt16(truncatingIfNeeded: t1 >> 16))
                setRegister(pair | 1, UInt16(truncatingIfNeeded: t1))
                n = t1 & 0x8000_0000 != 0
            } else {
                t1 &= 0xFFFF
                setRegister(opcodeReg, UInt16(t1))
                n = t1 & 0x8000 != 0
            }
            setFlag(n, Self.statusN)
            setFlag(t1 == 0, Self.statusZ)
            setFlag(false, Self.statusV)
            setFlag(false, Self.statusC)
        case 0x16: // SUBX
            let c: Int32 = sr & Self.statusC != 0 ? 1 : 0
            let t1 = subtract(Int32(register(opcodeReg)), Int32(bitPattern: operandRead()), carry: c, word: word)
            setRegister(opcodeReg, sized: UInt32(bitPattern: t1), word: word)
        case 0x17: // DIVXU
            let t1 = operandRead()
            guard t1 != 0 else {
                setFlag(false, Self.statusN)
                setFlag(true, Self.statusZ)
                setFlag(false, Self.statusV)
                setFlag(false, Self.statusC)
                return
            }
            if word {
                let pair = opcodeReg & ~1
                let t2 = UInt32(register(pair)) << 16 | UInt32(register(pair | 1))
                let remainder = t2 % t1, quotient = t2 / t1
                if quotient > 0xFFFF {
                    setFlag(false, Self.statusN)
                    setFlag(false, Self.statusZ)
                    setFlag(true, Self.statusV)
                    setFlag(false, Self.statusC)
                } else {
                    setRegister(pair, UInt16(truncatingIfNeeded: remainder))
                    setRegister(pair | 1, UInt16(truncatingIfNeeded: quotient))
                    setFlagsCommon(quotient, word: true)
                    setFlag(false, Self.statusC)
                }
            } else {
                let t2 = UInt32(register(opcodeReg))
                let remainder = t2 % t1, quotient = t2 / t1
                if quotient > 0xFF {
                    setFlag(false, Self.statusN)
                    setFlag(false, Self.statusZ)
                    setFlag(true, Self.statusV)
                    setFlag(false, Self.statusC)
                } else {
                    setRegister(opcodeReg, UInt16((remainder & 0xFF) << 8 | (quotient & 0xFF)))
                    setFlagsCommon(quotient, word: false)
                    setFlag(false, Self.statusC)
                }
            }
        case 0x18, 0x19: // BSET #
            guard operandType != Self.immediate else { return }
            var data = operandRead()
            let bit = UInt32(opcodeReg) | UInt32(opcode & 1) << 3
            setFlag(data & (1 << bit) == 0, Self.statusZ)
            data |= 1 << bit
            operandWrite(data)
        case 0x1A, 0x1B: // BCLR #
            guard operandType != Self.immediate else { return }
            var data = operandRead()
            let bit = UInt32(opcodeReg) | UInt32(opcode & 1) << 3
            setFlag(data & (1 << bit) == 0, Self.statusZ)
            data &= ~(1 << bit)
            operandWrite(data)
        case 0x1C, 0x1D: // BNOT #
            guard operandType != Self.immediate else { return }
            var data = operandRead()
            let bit = UInt32(opcodeReg) | UInt32(opcode & 1) << 3
            setFlag(data & (1 << bit) == 0, Self.statusZ)
            data ^= 1 << bit
            operandWrite(data)
        case 0x1E, 0x1F: // BTST #
            guard operandType != Self.immediate else { return }
            let data = operandRead()
            let bit = UInt32(opcodeReg) | UInt32(opcode & 1) << 3
            setFlag(data & (1 << bit) == 0, Self.statusZ)
        default: break
        }
    }

    private func clearGroup(_ opcodeReg: Int) {
        let word = operandWord
        switch opcodeReg {
        case 3 where operandType != Self.immediate: // CLR
            operandWrite(0)
            setFlag(false, Self.statusN)
            setFlag(true, Self.statusZ)
            setFlag(false, Self.statusV)
            setFlag(false, Self.statusC)
        case 6 where operandType != Self.immediate: // TST
            setFlagsCommon(operandRead(), word: word)
            setFlag(false, Self.statusC)
        case 2 where operandType == Self.direct && !word: // EXTU
            let data = register(operandReg) & 0xFF
            setRegister(operandReg, data)
            setFlag(false, Self.statusN)
            setFlag(data == 0, Self.statusZ)
            setFlag(false, Self.statusV)
            setFlag(false, Self.statusC)
        case 0 where operandType == Self.direct && !word: // SWAP
            let data = register(operandReg)
            let swapped = data << 8 | data >> 8
            setRegister(operandReg, swapped)
            setFlagsCommon(UInt32(swapped), word: true)
        case 5 where operandType != Self.immediate: // NOT
            let data = ~operandRead()
            operandWrite(data)
            setFlagsCommon(data, word: word)
        case 4 where operandType != Self.immediate: // NEG
            let data = subtract(0, Int32(bitPattern: operandRead()), carry: 0, word: word)
            operandWrite(UInt32(bitPattern: data))
        case 1 where operandType == Self.direct && !word: // EXTS
            let data = register(operandReg)
            setRegister(operandReg, UInt16(bitPattern: Int16(Int8(truncatingIfNeeded: data))))
            // (The flags are of the register before it is extended, as Nuked SC-55 has them.)
            setFlagsCommon(UInt32(data), word: true)
        default: break
        }
    }

    private func shiftGroup(_ opcodeReg: Int) {
        guard operandType != Self.immediate else { return }
        let word = operandWord
        let top: UInt32 = word ? 0x8000 : 0x80
        var data = operandRead()
        let c: Bool
        switch opcodeReg {
        case 0x03: // SHLR
            c = data & 1 != 0
            data >>= 1
        case 0x02, 0x00: // SHLL, SHAL
            c = data & top != 0
            data <<= 1
        case 0x06: // ROTXL
            let bit: UInt32 = sr & Self.statusC != 0 ? 1 : 0
            c = data & top != 0
            data = data << 1 | bit
        case 0x04: // ROTL
            c = data & top != 0
            data = data << 1 | (c ? 1 : 0)
        case 0x01: // SHAR
            c = data & 1 != 0
            let msb = data & top
            data &= word ? 0xFFFF : 0xFF
            data = data >> 1 | msb
        case 0x05: // ROTR
            c = data & 1 != 0
            data >>= 1
            if c { data |= word ? 0x8000 : 0x80 }
        default: return
        }
        operandWrite(data)
        setFlag(c, Self.statusC)
        setFlagsCommon(data, word: word)
    }
}
