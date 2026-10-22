// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ASAP (Another Slight Atari Player), Copyright (C) 2010-2026 Piotr Fusik, used under
// the GNU General Public License, version 2 or later (see THIRD-PARTY.md).
//
// The 6502 of the 8-bit Atari, as ASAP has it. It is not the C64's 6510 of MOS6510.swift, which
// makes each of its bus accesses in its own cycle: this one runs an instruction whole and counts
// its cycles first, so that what it writes to the POKEY is heard at the cycle ASAP hears it at,
// and the tunes sound as they do there. The undocumented instructions are as they were found on
// the Atari 800XL and 65XE, which are the C64's but for 0x8B and 0xAB; the twelve that stop a
// 6502 wait here for whatever happens next, which is how the way back from the tune's code is made.

private let vFlag = 0x40, dFlag = 0x08, iFlag = 0x04, zFlag = 0x02

/// How many cycles each instruction takes, before any page it crosses or branch it takes.
private let opcodeCycles: [UInt8] = [
    // 0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
    7, 6, 2, 8, 3, 3, 5, 5, 3, 2, 2, 2, 4, 4, 6, 6, // 0x
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 1x
    6, 6, 2, 8, 3, 3, 5, 5, 4, 2, 2, 2, 4, 4, 6, 6, // 2x
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 3x
    6, 6, 2, 8, 3, 3, 5, 5, 3, 2, 2, 2, 3, 4, 6, 6, // 4x
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 5x
    6, 6, 2, 8, 3, 3, 5, 5, 4, 2, 2, 2, 5, 4, 6, 6, // 6x
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // 7x
    2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4, // 8x
    2, 6, 2, 6, 4, 4, 4, 4, 2, 5, 2, 5, 5, 5, 5, 5, // 9x
    2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4, // Ax
    2, 5, 2, 5, 4, 4, 4, 4, 2, 4, 2, 4, 4, 4, 4, 4, // Bx
    2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6, // Cx
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // Dx
    2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6, // Ex
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7, // Fx
]

extension SAPMachine {
    @inline(__always) private func mem(_ addr: Int) -> Int {
        Int(memory[addr & 0xFFFF])
    }

    @inline(__always) private func fetch() -> Int {
        let value = Int(memory[pc])
        pc = (pc + 1) & 0xFFFF
        return value
    }

    @inline(__always) private func peek(_ addr: Int) -> Int {
        addr & 0xF900 == 0xD000 ? peekHardware(addr) : Int(memory[addr])
    }

    @inline(__always) private func poke(_ addr: Int, _ data: Int) {
        if addr & 0xF900 == 0xD000 {
            pokeHardware(addr, data)
        } else {
            memory[addr] = UInt8(truncatingIfNeeded: data)
        }
    }

    /// The first half of a read-modify-write: of a POKEY's register, the value is written back as
    /// it was read, a cycle before the new one, as the 6502 does.
    @inline(__always) private func peekReadModifyWrite(_ addr: Int) -> Int {
        if addr >> 8 == 0xD2 {
            cycle -= 1
            let data = peekHardware(addr)
            pokeHardware(addr, data)
            cycle += 1
            return data
        }
        return Int(memory[addr])
    }

    @inline(__always) private func pull() -> Int {
        s = (s + 1) & 0xFF
        return Int(memory[0x100 + s])
    }

    private func pullFlags() {
        let data = pull()
        nz = ((data & 0x80) << 1) + (~data & zFlag)
        c = data & 1
        vdi = data & (vFlag | dFlag | iFlag)
    }

    @inline(__always) private func push(_ data: Int) {
        memory[0x100 + s] = UInt8(truncatingIfNeeded: data)
        s = (s - 1) & 0xFF
    }

    func pushPC() {
        push(pc >> 8)
        push(pc & 0xFF)
    }

    private func pushFlags(_ b: Int) {
        var b = b + ((nz | nz >> 1) & 0x80) + vdi + c
        if nz & 0xFF == 0 { b += zFlag }
        push(b)
    }

    private func addWithCarry(_ data: Int) {
        let a = self.a
        var tmp = a + data + c
        nz = tmp & 0xFF
        if vdi & dFlag == 0 {
            vdi = (vdi & (dFlag | iFlag)) + (((~(data ^ a) & (a ^ tmp)) >> 1) & vFlag)
            c = tmp >> 8
            self.a = nz
        } else {
            let al = (a & 0x0F) + (data & 0x0F) + c
            if al >= 10 {
                tmp += al < 26 ? 6 : -10
                // N from the sum so far; Z stays as it was, as nought can only become 6.
                if nz != 0 { nz = (tmp & 0x80) + 1 }
            }
            vdi = (vdi & (dFlag | iFlag)) + (((~(data ^ a) & (a ^ tmp)) >> 1) & vFlag)
            if tmp >= 0xA0 {
                c = 1
                self.a = (tmp - 0xA0) & 0xFF
            } else {
                c = 0
                self.a = tmp
            }
        }
    }

    private func subtractWithCarry(_ data: Int) {
        let a = self.a
        let borrow = c - 1
        let tmp = a - data + borrow
        let al = (a & 0x0F) - (data & 0x0F) + borrow
        vdi = (vdi & (dFlag | iFlag)) + ((((data ^ a) & (a ^ tmp)) >> 1) & vFlag)
        c = tmp >= 0 ? 1 : 0
        self.a = tmp & 0xFF
        nz = self.a
        if vdi & dFlag != 0 {
            if al < 0 { self.a += al < -10 ? 10 : -6 }
            if c == 0 { self.a = (self.a - 0x60) & 0xFF }
        }
    }

    private func arithmeticShiftLeft(_ addr: Int) -> Int {
        var data = peekReadModifyWrite(addr)
        c = data >> 7
        data = (data << 1) & 0xFF
        poke(addr, data)
        return data
    }

    private func rotateLeft(_ addr: Int) -> Int {
        var data = (peekReadModifyWrite(addr) << 1) + c
        c = data >> 8
        data &= 0xFF
        poke(addr, data)
        return data
    }

    private func logicalShiftRight(_ addr: Int) -> Int {
        var data = peekReadModifyWrite(addr)
        c = data & 1
        data >>= 1
        poke(addr, data)
        return data
    }

    private func rotateRight(_ addr: Int) -> Int {
        var data = (c << 8) + peekReadModifyWrite(addr)
        c = data & 1
        data >>= 1
        poke(addr, data)
        return data
    }

    private func decrement(_ addr: Int) -> Int {
        let data = (peekReadModifyWrite(addr) - 1) & 0xFF
        poke(addr, data)
        return data
    }

    private func increment(_ addr: Int) -> Int {
        let data = (peekReadModifyWrite(addr) + 1) & 0xFF
        poke(addr, data)
        return data
    }

    private func executeIRQ(_ b: Int) {
        pushPC()
        pushFlags(b)
        vdi |= iFlag
        pc = Int(memory[0xFFFE]) + Int(memory[0xFFFF]) << 8
    }

    private func checkIRQ() {
        if vdi & iFlag == 0, isIRQ {
            cycle += 7
            executeIRQ(0x20) // B clear
        }
    }

    /// The unstable "store a register AND the high byte plus one" instructions.
    private func shx(_ index: Int, _ data: Int) {
        var addr = index + fetch()
        var hi = fetch()
        let data = data & (hi + 1)
        if addr >= 0x100 { hi = data - 1 }
        addr += hi << 8
        poke(addr & 0xFFFF, data)
    }

    /// Runs the processor up to the given cycle of the frame, stopping between instructions for
    /// each thing that happens (see `handleEvent`).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func runCPU(until cycleLimit: Int) {
        while cycle < cycleLimit {
            if cycle >= nextEventCycle {
                handleEvent()
                checkIRQ()
            }
            let data = fetch()
            cycle += Int(opcodeCycles[data])
            var addr = 0

            // First the instructions with an addressing mode of their own, which are done here;
            // for the rest the address is worked out, and they are done below.
            switch data {
            case 0x00: // BRK
                pc = (pc + 1) & 0xFFFF
                executeIRQ(0x30) // B set
                continue
            case 0x01, 0x03, 0x21, 0x23, 0x41, 0x43, 0x61, 0x63, 0x81, 0x83, 0xA1, 0xA3, 0xC1, 0xC3, 0xE1, 0xE3: // (ab,x)
                addr = (fetch() + x) & 0xFF
                addr = Int(memory[addr]) + Int(memory[(addr + 1) & 0xFF]) << 8
            case 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xB2, 0xD2, 0xF2: // CIM: wait
                pc = (pc - 1) & 0xFFFF
                cycle = nextEventCycle
                continue
            case 0x04, 0x44, 0x64, 0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4, 0x80, 0x82, 0x89, 0xC2, 0xE2: // NOP ab, ab,x, #ab
                pc = (pc + 1) & 0xFFFF
                continue
            case 0x05, 0x06, 0x07, 0x24, 0x25, 0x26, 0x27, 0x45, 0x46, 0x47, 0x65, 0x66, 0x67,
                 0x84, 0x85, 0x86, 0x87, 0xA4, 0xA5, 0xA6, 0xA7, 0xC4, 0xC5, 0xC6, 0xC7, 0xE4, 0xE5, 0xE6, 0xE7: // ab
                addr = fetch()
            case 0x08: // PHP
                pushFlags(0x30) // B set
                continue
            case 0x09, 0x29, 0x49, 0x69, 0xA0, 0xA2, 0xA9, 0xC0, 0xC9, 0xE0, 0xE9, 0xEB: // #ab
                addr = pc
                pc = (pc + 1) & 0xFFFF
            case 0x0A: // ASL
                c = a >> 7
                a = (a << 1) & 0xFF
                nz = a
                continue
            case 0x0B, 0x2B: // ANC #ab
                a &= fetch()
                nz = a
                c = nz >> 7
                continue
            case 0x0C: // NOP abcd
                pc = (pc + 2) & 0xFFFF
                continue
            case 0x0D, 0x0E, 0x0F, 0x2C, 0x2D, 0x2E, 0x2F, 0x4D, 0x4E, 0x4F, 0x6C, 0x6D, 0x6E, 0x6F,
                 0x8C, 0x8D, 0x8E, 0x8F, 0xAC, 0xAD, 0xAE, 0xAF, 0xCC, 0xCD, 0xCE, 0xCF, 0xEC, 0xED, 0xEE, 0xEF: // abcd
                addr = fetch()
                addr += fetch() << 8
            case 0x10: // BPL
                if nz < 0x80 { break }
                pc = (pc + 1) & 0xFFFF
                continue
            case 0x11, 0x31, 0x51, 0x71, 0xB1, 0xB3, 0xD1, 0xF1: // (ab),y, a cycle more across a page
                let zp = fetch()
                addr = Int(memory[zp]) + y
                if addr >= 0x100 { cycle += 1 }
                addr = (addr + Int(memory[(zp + 1) & 0xFF]) << 8) & 0xFFFF
            case 0x13, 0x33, 0x53, 0x73, 0x91, 0xD3, 0xF3: // (ab),y
                addr = fetch()
                addr = (Int(memory[addr]) + Int(memory[(addr + 1) & 0xFF]) << 8 + y) & 0xFFFF
            case 0x15, 0x16, 0x17, 0x35, 0x36, 0x37, 0x55, 0x56, 0x57, 0x75, 0x76, 0x77,
                 0x94, 0x95, 0xB4, 0xB5, 0xD5, 0xD6, 0xD7, 0xF5, 0xF6, 0xF7: // ab,x
                addr = (fetch() + x) & 0xFF
            case 0x18: // CLC
                c = 0
                continue
            case 0x19, 0x39, 0x59, 0x79, 0xB9, 0xBB, 0xBE, 0xBF, 0xD9, 0xF9: // abcd,y, a cycle more across a page
                addr = fetch() + y
                if addr >= 0x100 { cycle += 1 }
                addr = (addr + fetch() << 8) & 0xFFFF
            case 0x1B, 0x3B, 0x5B, 0x7B, 0x99, 0xDB, 0xFB: // abcd,y
                addr = fetch() + y
                addr = (addr + fetch() << 8) & 0xFFFF
            case 0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC: // NOP abcd,x
                if Int(memory[pc]) + x >= 0x100 { cycle += 1 }
                pc = (pc + 2) & 0xFFFF
                continue
            case 0x1D, 0x3D, 0x5D, 0x7D, 0xBC, 0xBD, 0xDD, 0xFD: // abcd,x, a cycle more across a page
                addr = fetch() + x
                if addr >= 0x100 { cycle += 1 }
                addr = (addr + fetch() << 8) & 0xFFFF
            case 0x1E, 0x1F, 0x3E, 0x3F, 0x5E, 0x5F, 0x7E, 0x7F, 0x9D, 0xDE, 0xDF, 0xFE, 0xFF: // abcd,x
                addr = fetch() + x
                addr = (addr + fetch() << 8) & 0xFFFF
            case 0x20: // JSR abcd
                addr = fetch()
                pushPC()
                pc = addr + Int(memory[pc]) << 8
                continue
            case 0x28: // PLP
                pullFlags()
                checkIRQ()
                continue
            case 0x2A: // ROL
                a = (a << 1) + c
                c = a >> 8
                a &= 0xFF
                nz = a
                continue
            case 0x30: // BMI
                if nz >= 0x80 { break }
                pc = (pc + 1) & 0xFFFF
                continue
            case 0x38: // SEC
                c = 1
                continue
            case 0x40: // RTI
                pullFlags()
                pc = pull()
                pc += pull() << 8
                checkIRQ()
                continue
            case 0x48: // PHA
                push(a)
                continue
            case 0x4A: // LSR
                c = a & 1
                a >>= 1
                nz = a
                continue
            case 0x4B: // ALR #ab
                a &= fetch()
                c = a & 1
                a >>= 1
                nz = a
                continue
            case 0x4C: // JMP abcd
                addr = fetch()
                pc = addr + Int(memory[pc]) << 8
                continue
            case 0x50: // BVC
                if vdi & vFlag == 0 { break }
                pc = (pc + 1) & 0xFFFF
                continue
            case 0x58: // CLI
                vdi &= vFlag | dFlag
                checkIRQ()
                continue
            case 0x60: // RTS
                pc = pull()
                pc = (pc + (pull() << 8) + 1) & 0xFFFF
                continue
            case 0x68: // PLA
                a = pull()
                nz = a
                continue
            case 0x6A: // ROR
                nz = (c << 7) + (a >> 1)
                c = a & 1
                a = nz
                continue
            case 0x6B: // ARR #ab
                let data = a & fetch()
                a = (data >> 1) + (c << 7)
                nz = a
                vdi = (vdi & (dFlag | iFlag)) + ((a ^ data) & vFlag)
                if vdi & dFlag == 0 {
                    c = data >> 7
                } else {
                    if data & 0xF >= 5 { a = (a & 0xF0) + ((a + 6) & 0xF) }
                    if data >= 0x50 {
                        a = (a + 0x60) & 0xFF
                        c = 1
                    } else {
                        c = 0
                    }
                }
                continue
            case 0x70: // BVS
                if vdi & vFlag != 0 { break }
                pc = (pc + 1) & 0xFFFF
                continue
            case 0x78: // SEI
                vdi |= iFlag
                continue
            case 0x88: // DEY
                y = (y - 1) & 0xFF
                nz = y
                continue
            case 0x8A: // TXA
                a = x
                nz = a
                continue
            case 0x8B: // ANE #ab
                let data = fetch()
                a &= (data | 0xEF) & x
                nz = a & data
                continue
            case 0x90: // BCC
                if c == 0 { break }
                pc = (pc + 1) & 0xFFFF
                continue
            case 0x93: // SHA (ab),y
                addr = fetch()
                var hi = Int(memory[(addr + 1) & 0xFF])
                addr = Int(memory[addr])
                let data = (hi + 1) & a & x
                addr += y
                if addr >= 0x100 { hi = data - 1 }
                addr += hi << 8
                poke(addr & 0xFFFF, data)
                continue
            case 0x96, 0x97, 0xB6, 0xB7: // ab,y
                addr = (fetch() + y) & 0xFF
            case 0x98: // TYA
                a = y
                nz = a
                continue
            case 0x9A: // TXS
                s = x
                continue
            case 0x9B: // SHS abcd,y
                s = a & x
                shx(y, s)
                continue
            case 0x9C: // SHY abcd,x
                shx(x, y)
                continue
            case 0x9E: // SHX abcd,y
                shx(y, x)
                continue
            case 0x9F: // SHA abcd,y
                shx(y, a & x)
                continue
            case 0xA8: // TAY
                y = a
                nz = y
                continue
            case 0xAA: // TAX
                x = a
                nz = x
                continue
            case 0xAB: // ANX #ab
                a &= fetch()
                x = a
                nz = a
                continue
            case 0xB0: // BCS
                if c != 0 { break }
                pc = (pc + 1) & 0xFFFF
                continue
            case 0xB8: // CLV
                vdi &= dFlag | iFlag
                continue
            case 0xBA: // TSX
                x = s
                nz = x
                continue
            case 0xC8: // INY
                y = (y + 1) & 0xFF
                nz = y
                continue
            case 0xCA: // DEX
                x = (x - 1) & 0xFF
                nz = x
                continue
            case 0xCB: // SBX #ab
                nz = fetch()
                x &= a
                c = x >= nz ? 1 : 0
                x = (x - nz) & 0xFF
                nz = x
                continue
            case 0xD0: // BNE
                if nz & 0xFF != 0 { break }
                pc = (pc + 1) & 0xFFFF
                continue
            case 0xD8: // CLD
                vdi &= vFlag | iFlag
                continue
            case 0xE8: // INX
                x = (x + 1) & 0xFF
                nz = x
                continue
            case 0xEA, 0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA: // NOP
                continue
            case 0xF0: // BEQ
                if nz & 0xFF == 0 { break }
                pc = (pc + 1) & 0xFFFF
                continue
            case 0xF8: // SED
                vdi |= dFlag
                continue
            default:
                continue
            }

            // Then those whose address has been worked out.
            switch data {
            case 0x01, 0x05, 0x09, 0x0D, 0x11, 0x15, 0x19, 0x1D: // ORA
                a |= peek(addr)
                nz = a
            case 0x03, 0x07, 0x0F, 0x13, 0x17, 0x1B, 0x1F: // ASO
                a |= arithmeticShiftLeft(addr)
                nz = a
            case 0x06, 0x0E, 0x16, 0x1E: // ASL
                nz = arithmeticShiftLeft(addr)
            case 0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0: // a branch taken
                addr = (Int(memory[pc]) ^ 0x80) - 0x80
                pc += 1
                addr += pc
                cycle += (addr ^ pc) >> 8 != 0 ? 2 : 1
                pc = addr & 0xFFFF
            case 0x21, 0x25, 0x29, 0x2D, 0x31, 0x35, 0x39, 0x3D: // AND
                a &= peek(addr)
                nz = a
            case 0x23, 0x27, 0x2F, 0x33, 0x37, 0x3B, 0x3F: // RLA
                a &= rotateLeft(addr)
                nz = a
            case 0x24, 0x2C: // BIT
                nz = peek(addr)
                vdi = (vdi & (dFlag | iFlag)) + (nz & vFlag)
                nz = ((nz & 0x80) << 1) + (nz & a)
            case 0x26, 0x2E, 0x36, 0x3E: // ROL
                nz = rotateLeft(addr)
            case 0x41, 0x45, 0x49, 0x4D, 0x51, 0x55, 0x59, 0x5D: // EOR
                a ^= peek(addr)
                nz = a
            case 0x43, 0x47, 0x4F, 0x53, 0x57, 0x5B, 0x5F: // LSE
                a ^= logicalShiftRight(addr)
                nz = a
            case 0x46, 0x4E, 0x56, 0x5E: // LSR
                nz = logicalShiftRight(addr)
            case 0x61, 0x65, 0x69, 0x6D, 0x71, 0x75, 0x79, 0x7D: // ADC
                addWithCarry(peek(addr))
            case 0x63, 0x67, 0x6F, 0x73, 0x77, 0x7B, 0x7F: // RRA
                addWithCarry(rotateRight(addr))
            case 0x66, 0x6E, 0x76, 0x7E: // ROR
                nz = rotateRight(addr)
            case 0x6C: // JMP (abcd), which does not cross a page for its high byte
                pc = Int(memory[addr])
                addr += 1
                if addr & 0xFF == 0 { addr -= 0xFF }
                pc += Int(memory[addr & 0xFFFF]) << 8
            case 0x81, 0x85, 0x8D, 0x91, 0x95, 0x99, 0x9D: // STA
                poke(addr, a)
            case 0x83, 0x87, 0x8F, 0x97: // SAX
                poke(addr, a & x)
            case 0x84, 0x8C, 0x94: // STY
                poke(addr, y)
            case 0x86, 0x8E, 0x96: // STX
                poke(addr, x)
            case 0xA0, 0xA4, 0xAC, 0xB4, 0xBC: // LDY
                y = peek(addr)
                nz = y
            case 0xA1, 0xA5, 0xA9, 0xAD, 0xB1, 0xB5, 0xB9, 0xBD: // LDA
                a = peek(addr)
                nz = a
            case 0xA2, 0xA6, 0xAE, 0xB6, 0xBE: // LDX
                x = peek(addr)
                nz = x
            case 0xA3, 0xA7, 0xAF, 0xB3, 0xB7, 0xBF: // LAX
                a = peek(addr)
                x = a
                nz = a
            case 0xBB: // LAS
                s &= peek(addr)
                a = s
                x = s
                nz = s
            case 0xC0, 0xC4, 0xCC: // CPY
                nz = peek(addr)
                c = y >= nz ? 1 : 0
                nz = (y - nz) & 0xFF
            case 0xC1, 0xC5, 0xC9, 0xCD, 0xD1, 0xD5, 0xD9, 0xDD: // CMP
                nz = peek(addr)
                c = a >= nz ? 1 : 0
                nz = (a - nz) & 0xFF
            case 0xC3, 0xC7, 0xCF, 0xD3, 0xD7, 0xDB, 0xDF: // DCM
                let data = decrement(addr)
                c = a >= data ? 1 : 0
                nz = (a - data) & 0xFF
            case 0xC6, 0xCE, 0xD6, 0xDE: // DEC
                nz = decrement(addr)
            case 0xE0, 0xE4, 0xEC: // CPX
                nz = peek(addr)
                c = x >= nz ? 1 : 0
                nz = (x - nz) & 0xFF
            case 0xE1, 0xE5, 0xE9, 0xEB, 0xED, 0xF1, 0xF5, 0xF9, 0xFD: // SBC
                subtractWithCarry(peek(addr))
            case 0xE3, 0xE7, 0xEF, 0xF3, 0xF7, 0xFB, 0xFF: // INS
                subtractWithCarry(increment(addr))
            case 0xE6, 0xEE, 0xF6, 0xFE: // INC
                nz = increment(addr)
            default:
                break
            }
        }
    }
}
