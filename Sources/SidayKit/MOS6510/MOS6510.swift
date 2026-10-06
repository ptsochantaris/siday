// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// MOS 6510 CPU. Each instruction performs exactly the bus accesses of the real chip, one per cycle,
// including the dummy reads and writes, so the bus can count cycles and keep timers in step.
// Undocumented opcodes are implemented; the JAM opcodes stop the CPU.

/// Class-bound so the generic CPU specialises and calls it directly.
protocol MOS6510Bus: AnyObject {
    /// One cycle: read.
    func read(_ address: UInt16) -> UInt8
    /// One cycle: write.
    func write(_ address: UInt16, _ value: UInt8)
    /// IRQ line as it stood one cycle ago, which is when the CPU samples it for the instruction now ending.
    var irqSampled: Bool { get }
    /// True once for each falling edge on the NMI line.
    func takeNMI() -> Bool
}

struct MOS6510<Bus: MOS6510Bus> {
    var a: UInt8 = 0, x: UInt8 = 0, y: UInt8 = 0, s: UInt8 = 0xFD
    var pc: UInt16 = 0
    var n = false, v = false, d = false, i = true, z = false, c = false
    /// Set when a JAM opcode has stopped the CPU.
    var jammed = false

    var status: UInt8 {
        get { (n ? 0x80 : 0) | (v ? 0x40 : 0) | 0x20 | (d ? 0x08 : 0) | (i ? 0x04 : 0) | (z ? 0x02 : 0) | (c ? 0x01 : 0) }
        set {
            n = newValue & 0x80 != 0; v = newValue & 0x40 != 0; d = newValue & 0x08 != 0
            i = newValue & 0x04 != 0; z = newValue & 0x02 != 0; c = newValue & 0x01 != 0
        }
    }

    // MARK: Bus helpers

    @inline(__always) private mutating func fetch(_ bus: Bus) -> UInt8 {
        let value = bus.read(pc)
        pc &+= 1
        return value
    }

    @inline(__always) private mutating func push(_ bus: Bus, _ value: UInt8) {
        bus.write(0x100 | UInt16(s), value)
        s &-= 1
    }

    @inline(__always) private mutating func pull(_ bus: Bus) -> UInt8 {
        s &+= 1
        return bus.read(0x100 | UInt16(s))
    }

    @inline(__always) private mutating func nz(_ value: UInt8) {
        n = value & 0x80 != 0
        z = value == 0
    }

    // MARK: Addressing. Each returns the effective address after performing the mode's cycles.

    @inline(__always) private mutating func zp(_ bus: Bus) -> UInt16 { UInt16(fetch(bus)) }

    @inline(__always) private mutating func zpIndexed(_ bus: Bus, _ index: UInt8) -> UInt16 {
        let base = fetch(bus)
        _ = bus.read(UInt16(base))
        return UInt16(base &+ index)
    }

    @inline(__always) private mutating func abs(_ bus: Bus) -> UInt16 {
        let lo = UInt16(fetch(bus))
        return lo | UInt16(fetch(bus)) << 8
    }

    /// `always` forces the extra cycle that stores and read-modify-write instructions take.
    @inline(__always) private mutating func absIndexed(_ bus: Bus, _ index: UInt8, always: Bool) -> UInt16 {
        let base = abs(bus)
        let address = base &+ UInt16(index)
        if always || (address ^ base) & 0xFF00 != 0 {
            _ = bus.read((base & 0xFF00) | (address & 0x00FF))
        }
        return address
    }

    @inline(__always) private mutating func izx(_ bus: Bus) -> UInt16 {
        let base = fetch(bus)
        _ = bus.read(UInt16(base))
        let pointer = base &+ x
        let lo = UInt16(bus.read(UInt16(pointer)))
        return lo | UInt16(bus.read(UInt16(pointer &+ 1))) << 8
    }

    @inline(__always) private mutating func izy(_ bus: Bus, always: Bool) -> UInt16 {
        let pointer = fetch(bus)
        let lo = UInt16(bus.read(UInt16(pointer)))
        let base = lo | UInt16(bus.read(UInt16(pointer &+ 1))) << 8
        let address = base &+ UInt16(y)
        if always || (address ^ base) & 0xFF00 != 0 {
            _ = bus.read((base & 0xFF00) | (address & 0x00FF))
        }
        return address
    }

    // MARK: Operations

    @inline(__always) private mutating func adc(_ value: UInt8) {
        let carry: UInt16 = c ? 1 : 0
        if d {
            var al = UInt16(a & 0x0F) + UInt16(value & 0x0F) + carry
            if al > 9 { al += 6 }
            var ah = UInt16(a >> 4) + UInt16(value >> 4) + (al > 0x0F ? 1 : 0)
            z = (UInt16(a) + UInt16(value) + carry) & 0xFF == 0
            n = ah & 8 != 0
            v = ((UInt16(a) ^ (ah << 4)) & 0x80 != 0) && ((a ^ value) & 0x80 == 0)
            if ah > 9 { ah += 6 }
            c = ah > 15
            a = UInt8(truncatingIfNeeded: (ah << 4) | (al & 0x0F))
        } else {
            let sum = UInt16(a) + UInt16(value) + carry
            v = (~(UInt16(a) ^ UInt16(value)) & (UInt16(a) ^ sum) & 0x80) != 0
            c = sum > 0xFF
            a = UInt8(truncatingIfNeeded: sum)
            nz(a)
        }
    }

    @inline(__always) private mutating func sbc(_ value: UInt8) {
        let borrow: Int = c ? 0 : 1
        let difference = Int(a) - Int(value) - borrow
        let result = UInt8(truncatingIfNeeded: difference)
        let overflow = ((a ^ value) & (a ^ result) & 0x80) != 0
        if d {
            var al = Int(a & 0x0F) - Int(value & 0x0F) - borrow
            var ah = Int(a >> 4) - Int(value >> 4)
            if al & 0x10 != 0 {
                al -= 6
                ah -= 1
            }
            if ah & 0x10 != 0 { ah -= 6 }
            a = UInt8(truncatingIfNeeded: (ah << 4) | (al & 0x0F))
        } else {
            a = result
        }
        // Flags always come from the binary result.
        c = difference >= 0
        v = overflow
        nz(result)
    }

    @inline(__always) private mutating func compare(_ register: UInt8, _ value: UInt8) {
        c = register >= value
        nz(register &- value)
    }

    @inline(__always) private mutating func asl(_ value: UInt8) -> UInt8 {
        c = value & 0x80 != 0
        let r = value << 1
        nz(r)
        return r
    }

    @inline(__always) private mutating func lsr(_ value: UInt8) -> UInt8 {
        c = value & 1 != 0
        let r = value >> 1
        nz(r)
        return r
    }

    @inline(__always) private mutating func rol(_ value: UInt8) -> UInt8 {
        let r = (value << 1) | (c ? 1 : 0)
        c = value & 0x80 != 0
        nz(r)
        return r
    }

    @inline(__always) private mutating func ror(_ value: UInt8) -> UInt8 {
        let r = (value >> 1) | (c ? 0x80 : 0)
        c = value & 1 != 0
        nz(r)
        return r
    }

    @inline(__always) private mutating func bit(_ value: UInt8) {
        n = value & 0x80 != 0
        v = value & 0x40 != 0
        z = a & value == 0
    }

    private enum Modify { case asl, lsr, rol, ror, inc, dec, slo, rla, sre, rra, dcp, isc }

    /// Read-modify-write: read, write the old value back, write the new one.
    @inline(__always) private mutating func modify(_ bus: Bus, _ address: UInt16, _ op: Modify) {
        var value = bus.read(address)
        bus.write(address, value)
        switch op {
        case .asl: value = asl(value)
        case .lsr: value = lsr(value)
        case .rol: value = rol(value)
        case .ror: value = ror(value)
        case .inc: value &+= 1; nz(value)
        case .dec: value &-= 1; nz(value)
        case .slo: value = asl(value); a |= value; nz(a)
        case .rla: value = rol(value); a &= value; nz(a)
        case .sre: value = lsr(value); a ^= value; nz(a)
        case .rra: value = ror(value); adc(value)
        case .dcp: value &-= 1; compare(a, value)
        case .isc: value &+= 1; sbc(value)
        }
        bus.write(address, value)
    }

    @inline(__always) private mutating func branch(_ bus: Bus, _ taken: Bool) {
        let offset = fetch(bus)
        guard taken else { return }
        _ = bus.read(pc)
        let target = pc &+ UInt16(bitPattern: Int16(Int8(bitPattern: offset)))
        if (target ^ pc) & 0xFF00 != 0 {
            _ = bus.read((pc & 0xFF00) | (target & 0x00FF))
        }
        pc = target
    }

    /// The unstable "store register AND (high byte + 1)" group: SHA, SHX, SHY, TAS.
    @inline(__always) private mutating func storeHighAnd(_ bus: Bus, _ base: UInt16, _ index: UInt8, _ register: UInt8) {
        let address = base &+ UInt16(index)
        _ = bus.read((base & 0xFF00) | (address & 0x00FF))
        let value = register & (UInt8(truncatingIfNeeded: base >> 8) &+ 1)
        // When the index carries into the high byte, the value is what ends up on the high address lines.
        let target = (address ^ base) & 0xFF00 != 0 ? (UInt16(value) << 8) | (address & 0x00FF) : address
        bus.write(target, value)
    }

    // MARK: Interrupts and reset

    mutating func reset(_ bus: Bus) {
        jammed = false
        i = true
        s = 0xFD
        let lo = UInt16(bus.read(0xFFFC))
        pc = lo | UInt16(bus.read(0xFFFD)) << 8
    }

    @inline(__always) private mutating func interrupt(_ bus: Bus, vector: UInt16) {
        _ = bus.read(pc)
        _ = bus.read(pc)
        push(bus, UInt8(truncatingIfNeeded: pc >> 8))
        push(bus, UInt8(truncatingIfNeeded: pc))
        push(bus, status & ~0x10)
        i = true
        let lo = UInt16(bus.read(vector))
        pc = lo | UInt16(bus.read(vector &+ 1)) << 8
    }

    // MARK: Execution

    /// Runs one instruction, then takes a pending interrupt if there is one.
    @inline(__always) mutating func step(_ bus: Bus) {
        if jammed {
            _ = bus.read(pc)
            return
        }
        // CLI, SEI and PLP change the I flag too late to affect the interrupt check that follows them.
        var pollI = i
        let opcode = fetch(bus)
        execute(bus, opcode)
        if opcode != 0x58 && opcode != 0x78 && opcode != 0x28 { pollI = i }
        if bus.takeNMI() {
            interrupt(bus, vector: 0xFFFA)
        } else if !pollI && bus.irqSampled {
            interrupt(bus, vector: 0xFFFE)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private mutating func execute(_ bus: Bus, _ opcode: UInt8) {
        switch opcode {
        // LDA
        case 0xA9: a = fetch(bus); nz(a)
        case 0xA5: a = bus.read(zp(bus)); nz(a)
        case 0xB5: a = bus.read(zpIndexed(bus, x)); nz(a)
        case 0xAD: a = bus.read(abs(bus)); nz(a)
        case 0xBD: a = bus.read(absIndexed(bus, x, always: false)); nz(a)
        case 0xB9: a = bus.read(absIndexed(bus, y, always: false)); nz(a)
        case 0xA1: a = bus.read(izx(bus)); nz(a)
        case 0xB1: a = bus.read(izy(bus, always: false)); nz(a)
        // LDX
        case 0xA2: x = fetch(bus); nz(x)
        case 0xA6: x = bus.read(zp(bus)); nz(x)
        case 0xB6: x = bus.read(zpIndexed(bus, y)); nz(x)
        case 0xAE: x = bus.read(abs(bus)); nz(x)
        case 0xBE: x = bus.read(absIndexed(bus, y, always: false)); nz(x)
        // LDY
        case 0xA0: y = fetch(bus); nz(y)
        case 0xA4: y = bus.read(zp(bus)); nz(y)
        case 0xB4: y = bus.read(zpIndexed(bus, x)); nz(y)
        case 0xAC: y = bus.read(abs(bus)); nz(y)
        case 0xBC: y = bus.read(absIndexed(bus, x, always: false)); nz(y)
        // STA
        case 0x85: bus.write(zp(bus), a)
        case 0x95: bus.write(zpIndexed(bus, x), a)
        case 0x8D: bus.write(abs(bus), a)
        case 0x9D: bus.write(absIndexed(bus, x, always: true), a)
        case 0x99: bus.write(absIndexed(bus, y, always: true), a)
        case 0x81: bus.write(izx(bus), a)
        case 0x91: bus.write(izy(bus, always: true), a)
        // STX, STY
        case 0x86: bus.write(zp(bus), x)
        case 0x96: bus.write(zpIndexed(bus, y), x)
        case 0x8E: bus.write(abs(bus), x)
        case 0x84: bus.write(zp(bus), y)
        case 0x94: bus.write(zpIndexed(bus, x), y)
        case 0x8C: bus.write(abs(bus), y)
        // Transfers
        case 0xAA: _ = bus.read(pc); x = a; nz(x)
        case 0xA8: _ = bus.read(pc); y = a; nz(y)
        case 0x8A: _ = bus.read(pc); a = x; nz(a)
        case 0x98: _ = bus.read(pc); a = y; nz(a)
        case 0xBA: _ = bus.read(pc); x = s; nz(x)
        case 0x9A: _ = bus.read(pc); s = x
        // Stack
        case 0x48: _ = bus.read(pc); push(bus, a)
        case 0x08: _ = bus.read(pc); push(bus, status | 0x10)
        case 0x68: _ = bus.read(pc); _ = bus.read(0x100 | UInt16(s)); a = pull(bus); nz(a)
        case 0x28: _ = bus.read(pc); _ = bus.read(0x100 | UInt16(s)); status = pull(bus)
        // AND
        case 0x29: a &= fetch(bus); nz(a)
        case 0x25: a &= bus.read(zp(bus)); nz(a)
        case 0x35: a &= bus.read(zpIndexed(bus, x)); nz(a)
        case 0x2D: a &= bus.read(abs(bus)); nz(a)
        case 0x3D: a &= bus.read(absIndexed(bus, x, always: false)); nz(a)
        case 0x39: a &= bus.read(absIndexed(bus, y, always: false)); nz(a)
        case 0x21: a &= bus.read(izx(bus)); nz(a)
        case 0x31: a &= bus.read(izy(bus, always: false)); nz(a)
        // ORA
        case 0x09: a |= fetch(bus); nz(a)
        case 0x05: a |= bus.read(zp(bus)); nz(a)
        case 0x15: a |= bus.read(zpIndexed(bus, x)); nz(a)
        case 0x0D: a |= bus.read(abs(bus)); nz(a)
        case 0x1D: a |= bus.read(absIndexed(bus, x, always: false)); nz(a)
        case 0x19: a |= bus.read(absIndexed(bus, y, always: false)); nz(a)
        case 0x01: a |= bus.read(izx(bus)); nz(a)
        case 0x11: a |= bus.read(izy(bus, always: false)); nz(a)
        // EOR
        case 0x49: a ^= fetch(bus); nz(a)
        case 0x45: a ^= bus.read(zp(bus)); nz(a)
        case 0x55: a ^= bus.read(zpIndexed(bus, x)); nz(a)
        case 0x4D: a ^= bus.read(abs(bus)); nz(a)
        case 0x5D: a ^= bus.read(absIndexed(bus, x, always: false)); nz(a)
        case 0x59: a ^= bus.read(absIndexed(bus, y, always: false)); nz(a)
        case 0x41: a ^= bus.read(izx(bus)); nz(a)
        case 0x51: a ^= bus.read(izy(bus, always: false)); nz(a)
        // ADC
        case 0x69: adc(fetch(bus))
        case 0x65: adc(bus.read(zp(bus)))
        case 0x75: adc(bus.read(zpIndexed(bus, x)))
        case 0x6D: adc(bus.read(abs(bus)))
        case 0x7D: adc(bus.read(absIndexed(bus, x, always: false)))
        case 0x79: adc(bus.read(absIndexed(bus, y, always: false)))
        case 0x61: adc(bus.read(izx(bus)))
        case 0x71: adc(bus.read(izy(bus, always: false)))
        // SBC (0xEB is the undocumented duplicate)
        case 0xE9, 0xEB: sbc(fetch(bus))
        case 0xE5: sbc(bus.read(zp(bus)))
        case 0xF5: sbc(bus.read(zpIndexed(bus, x)))
        case 0xED: sbc(bus.read(abs(bus)))
        case 0xFD: sbc(bus.read(absIndexed(bus, x, always: false)))
        case 0xF9: sbc(bus.read(absIndexed(bus, y, always: false)))
        case 0xE1: sbc(bus.read(izx(bus)))
        case 0xF1: sbc(bus.read(izy(bus, always: false)))
        // CMP
        case 0xC9: compare(a, fetch(bus))
        case 0xC5: compare(a, bus.read(zp(bus)))
        case 0xD5: compare(a, bus.read(zpIndexed(bus, x)))
        case 0xCD: compare(a, bus.read(abs(bus)))
        case 0xDD: compare(a, bus.read(absIndexed(bus, x, always: false)))
        case 0xD9: compare(a, bus.read(absIndexed(bus, y, always: false)))
        case 0xC1: compare(a, bus.read(izx(bus)))
        case 0xD1: compare(a, bus.read(izy(bus, always: false)))
        // CPX, CPY
        case 0xE0: compare(x, fetch(bus))
        case 0xE4: compare(x, bus.read(zp(bus)))
        case 0xEC: compare(x, bus.read(abs(bus)))
        case 0xC0: compare(y, fetch(bus))
        case 0xC4: compare(y, bus.read(zp(bus)))
        case 0xCC: compare(y, bus.read(abs(bus)))
        // BIT
        case 0x24: bit(bus.read(zp(bus)))
        case 0x2C: bit(bus.read(abs(bus)))
        // Shifts on A
        case 0x0A: _ = bus.read(pc); a = asl(a)
        case 0x4A: _ = bus.read(pc); a = lsr(a)
        case 0x2A: _ = bus.read(pc); a = rol(a)
        case 0x6A: _ = bus.read(pc); a = ror(a)
        // Shifts and INC/DEC on memory
        case 0x06: modify(bus, zp(bus), .asl)
        case 0x16: modify(bus, zpIndexed(bus, x), .asl)
        case 0x0E: modify(bus, abs(bus), .asl)
        case 0x1E: modify(bus, absIndexed(bus, x, always: true), .asl)
        case 0x46: modify(bus, zp(bus), .lsr)
        case 0x56: modify(bus, zpIndexed(bus, x), .lsr)
        case 0x4E: modify(bus, abs(bus), .lsr)
        case 0x5E: modify(bus, absIndexed(bus, x, always: true), .lsr)
        case 0x26: modify(bus, zp(bus), .rol)
        case 0x36: modify(bus, zpIndexed(bus, x), .rol)
        case 0x2E: modify(bus, abs(bus), .rol)
        case 0x3E: modify(bus, absIndexed(bus, x, always: true), .rol)
        case 0x66: modify(bus, zp(bus), .ror)
        case 0x76: modify(bus, zpIndexed(bus, x), .ror)
        case 0x6E: modify(bus, abs(bus), .ror)
        case 0x7E: modify(bus, absIndexed(bus, x, always: true), .ror)
        case 0xE6: modify(bus, zp(bus), .inc)
        case 0xF6: modify(bus, zpIndexed(bus, x), .inc)
        case 0xEE: modify(bus, abs(bus), .inc)
        case 0xFE: modify(bus, absIndexed(bus, x, always: true), .inc)
        case 0xC6: modify(bus, zp(bus), .dec)
        case 0xD6: modify(bus, zpIndexed(bus, x), .dec)
        case 0xCE: modify(bus, abs(bus), .dec)
        case 0xDE: modify(bus, absIndexed(bus, x, always: true), .dec)
        // Register INC/DEC
        case 0xE8: _ = bus.read(pc); x &+= 1; nz(x)
        case 0xC8: _ = bus.read(pc); y &+= 1; nz(y)
        case 0xCA: _ = bus.read(pc); x &-= 1; nz(x)
        case 0x88: _ = bus.read(pc); y &-= 1; nz(y)
        // Flags
        case 0x18: _ = bus.read(pc); c = false
        case 0x38: _ = bus.read(pc); c = true
        case 0x58: _ = bus.read(pc); i = false
        case 0x78: _ = bus.read(pc); i = true
        case 0xB8: _ = bus.read(pc); v = false
        case 0xD8: _ = bus.read(pc); d = false
        case 0xF8: _ = bus.read(pc); d = true
        // Branches
        case 0x10: branch(bus, !n)
        case 0x30: branch(bus, n)
        case 0x50: branch(bus, !v)
        case 0x70: branch(bus, v)
        case 0x90: branch(bus, !c)
        case 0xB0: branch(bus, c)
        case 0xD0: branch(bus, !z)
        case 0xF0: branch(bus, z)
        // Jumps and subroutines
        case 0x4C: pc = abs(bus)
        case 0x6C:
            let pointer = abs(bus)
            let lo = UInt16(bus.read(pointer))
            // The pointer's high byte does not carry.
            pc = lo | UInt16(bus.read((pointer & 0xFF00) | ((pointer &+ 1) & 0x00FF))) << 8
        case 0x20:
            let lo = UInt16(fetch(bus))
            _ = bus.read(0x100 | UInt16(s))
            push(bus, UInt8(truncatingIfNeeded: pc >> 8))
            push(bus, UInt8(truncatingIfNeeded: pc))
            pc = lo | UInt16(bus.read(pc)) << 8
        case 0x60:
            _ = bus.read(pc)
            _ = bus.read(0x100 | UInt16(s))
            let lo = UInt16(pull(bus))
            pc = lo | UInt16(pull(bus)) << 8
            _ = bus.read(pc)
            pc &+= 1
        case 0x40:
            _ = bus.read(pc)
            _ = bus.read(0x100 | UInt16(s))
            status = pull(bus)
            let lo = UInt16(pull(bus))
            pc = lo | UInt16(pull(bus)) << 8
        case 0x00:
            _ = fetch(bus)
            push(bus, UInt8(truncatingIfNeeded: pc >> 8))
            push(bus, UInt8(truncatingIfNeeded: pc))
            push(bus, status | 0x10)
            i = true
            let lo = UInt16(bus.read(0xFFFE))
            pc = lo | UInt16(bus.read(0xFFFF)) << 8
        // NOP and its undocumented forms
        case 0xEA, 0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA: _ = bus.read(pc)
        case 0x80, 0x82, 0x89, 0xC2, 0xE2: _ = fetch(bus)
        case 0x04, 0x44, 0x64: _ = bus.read(zp(bus))
        case 0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4: _ = bus.read(zpIndexed(bus, x))
        case 0x0C: _ = bus.read(abs(bus))
        case 0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC: _ = bus.read(absIndexed(bus, x, always: false))

        // Undocumented: LAX
        case 0xA7: a = bus.read(zp(bus)); x = a; nz(a)
        case 0xB7: a = bus.read(zpIndexed(bus, y)); x = a; nz(a)
        case 0xAF: a = bus.read(abs(bus)); x = a; nz(a)
        case 0xBF: a = bus.read(absIndexed(bus, y, always: false)); x = a; nz(a)
        case 0xA3: a = bus.read(izx(bus)); x = a; nz(a)
        case 0xB3: a = bus.read(izy(bus, always: false)); x = a; nz(a)
        // SAX
        case 0x87: bus.write(zp(bus), a & x)
        case 0x97: bus.write(zpIndexed(bus, y), a & x)
        case 0x8F: bus.write(abs(bus), a & x)
        case 0x83: bus.write(izx(bus), a & x)
        // SLO, RLA, SRE, RRA, DCP, ISC share the same seven addressing modes.
        case 0x07: modify(bus, zp(bus), .slo)
        case 0x17: modify(bus, zpIndexed(bus, x), .slo)
        case 0x0F: modify(bus, abs(bus), .slo)
        case 0x1F: modify(bus, absIndexed(bus, x, always: true), .slo)
        case 0x1B: modify(bus, absIndexed(bus, y, always: true), .slo)
        case 0x03: modify(bus, izx(bus), .slo)
        case 0x13: modify(bus, izy(bus, always: true), .slo)
        case 0x27: modify(bus, zp(bus), .rla)
        case 0x37: modify(bus, zpIndexed(bus, x), .rla)
        case 0x2F: modify(bus, abs(bus), .rla)
        case 0x3F: modify(bus, absIndexed(bus, x, always: true), .rla)
        case 0x3B: modify(bus, absIndexed(bus, y, always: true), .rla)
        case 0x23: modify(bus, izx(bus), .rla)
        case 0x33: modify(bus, izy(bus, always: true), .rla)
        case 0x47: modify(bus, zp(bus), .sre)
        case 0x57: modify(bus, zpIndexed(bus, x), .sre)
        case 0x4F: modify(bus, abs(bus), .sre)
        case 0x5F: modify(bus, absIndexed(bus, x, always: true), .sre)
        case 0x5B: modify(bus, absIndexed(bus, y, always: true), .sre)
        case 0x43: modify(bus, izx(bus), .sre)
        case 0x53: modify(bus, izy(bus, always: true), .sre)
        case 0x67: modify(bus, zp(bus), .rra)
        case 0x77: modify(bus, zpIndexed(bus, x), .rra)
        case 0x6F: modify(bus, abs(bus), .rra)
        case 0x7F: modify(bus, absIndexed(bus, x, always: true), .rra)
        case 0x7B: modify(bus, absIndexed(bus, y, always: true), .rra)
        case 0x63: modify(bus, izx(bus), .rra)
        case 0x73: modify(bus, izy(bus, always: true), .rra)
        case 0xC7: modify(bus, zp(bus), .dcp)
        case 0xD7: modify(bus, zpIndexed(bus, x), .dcp)
        case 0xCF: modify(bus, abs(bus), .dcp)
        case 0xDF: modify(bus, absIndexed(bus, x, always: true), .dcp)
        case 0xDB: modify(bus, absIndexed(bus, y, always: true), .dcp)
        case 0xC3: modify(bus, izx(bus), .dcp)
        case 0xD3: modify(bus, izy(bus, always: true), .dcp)
        case 0xE7: modify(bus, zp(bus), .isc)
        case 0xF7: modify(bus, zpIndexed(bus, x), .isc)
        case 0xEF: modify(bus, abs(bus), .isc)
        case 0xFF: modify(bus, absIndexed(bus, x, always: true), .isc)
        case 0xFB: modify(bus, absIndexed(bus, y, always: true), .isc)
        case 0xE3: modify(bus, izx(bus), .isc)
        case 0xF3: modify(bus, izy(bus, always: true), .isc)
        // Immediate-mode combinations
        case 0x0B, 0x2B: a &= fetch(bus); nz(a); c = n
        case 0x4B: a &= fetch(bus); a = lsr(a)
        case 0x6B:
            let t = a & fetch(bus)
            var r = (t >> 1) | (c ? 0x80 : 0)
            if d {
                n = c
                z = r == 0
                v = (t ^ r) & 0x40 != 0
                if (t & 0x0F) + (t & 0x01) > 5 { r = (r & 0xF0) | ((r &+ 6) & 0x0F) }
                if UInt16(t & 0xF0) + UInt16(t & 0x10) > 0x50 {
                    r &+= 0x60
                    c = true
                } else {
                    c = false
                }
            } else {
                nz(r)
                c = r & 0x40 != 0
                v = ((r >> 6) ^ (r >> 5)) & 1 != 0
            }
            a = r
        case 0xCB:
            let value = fetch(bus)
            let t = a & x
            c = t >= value
            x = t &- value
            nz(x)
        case 0x8B: a = (a | 0xEE) & x & fetch(bus); nz(a)
        case 0xAB: a = (a | 0xEE) & fetch(bus); x = a; nz(a)
        // LAS
        case 0xBB:
            let value = bus.read(absIndexed(bus, y, always: false)) & s
            a = value; x = value; s = value
            nz(value)
        // SHA, SHX, SHY, TAS
        case 0x9F: let base = abs(bus); storeHighAnd(bus, base, y, a & x)
        case 0x93:
            let pointer = fetch(bus)
            let lo = UInt16(bus.read(UInt16(pointer)))
            let base = lo | UInt16(bus.read(UInt16(pointer &+ 1))) << 8
            storeHighAnd(bus, base, y, a & x)
        case 0x9E: let base = abs(bus); storeHighAnd(bus, base, y, x)
        case 0x9C: let base = abs(bus); storeHighAnd(bus, base, x, y)
        case 0x9B:
            let base = abs(bus)
            s = a & x
            storeHighAnd(bus, base, y, s)
        // JAM
        default:
            jammed = true
        }
    }
}
