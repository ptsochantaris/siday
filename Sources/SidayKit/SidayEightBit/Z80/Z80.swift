// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Cycle-count tables after superzazu/z80, Copyright (c) 2019 Nicolas Allemand, used under the MIT licence
// (see THIRD-PARTY.md).
//
// Zilog Z80 CPU, instruction-stepped with T-state counts per instruction.
//
// Covers the documented and undocumented instruction set (IX/IY halves, SLL, the ED mirrors, the
// DDCB/FDCB forms that also copy their result to a register) and the undocumented X/Y flag bits
// including the MEMPTR-derived ones, so both ZEXDOC and ZEXALL pass. Cycle counts follow the
// tables of superzazu/z80 (MIT licence) and are checked against that core.
//
// Memory is a flat 64 KB block reached through a pointer; port I/O goes through a class-bound
// bus the struct is generic over, so the calls specialise and inline.

public protocol Z80Bus: AnyObject {
    /// `tstate` is the CPU's T-state counter when the request line goes active, one T-state into the
    /// I/O machine cycle (T-state 8 of the 11 that `OUT (n),A` takes).
    func portIn(_ port: UInt16, tstate: Int) -> UInt8
    func portOut(_ port: UInt16, value: UInt8, tstate: Int)
}

/// Flag bits of the F register.
public enum Z80Flag {
    public static let c: UInt8 = 0x01
    public static let n: UInt8 = 0x02
    public static let pv: UInt8 = 0x04
    public static let x: UInt8 = 0x08
    public static let h: UInt8 = 0x10
    public static let y: UInt8 = 0x20
    public static let z: UInt8 = 0x40
    public static let s: UInt8 = 0x80
}

private let flagC: UInt8 = 0x01, flagN: UInt8 = 0x02, flagPV: UInt8 = 0x04, flagX: UInt8 = 0x08
private let flagH: UInt8 = 0x10, flagY: UInt8 = 0x20, flagZ: UInt8 = 0x40, flagS: UInt8 = 0x80
private let flagXY: UInt8 = 0x28

// Offsets into the shared table block.
private let tableSZ = 0 // S, Z, Y, X of a byte
private let tableSZP = 256 // the same plus parity
private let tableMain = 512 // T-states, unprefixed
private let tableED = 768 // T-states, ED-prefixed (whole instruction)
private let tableIndex = 1024 // T-states, DD/FD-prefixed (whole instruction; 4 = prefix only)

/// Flag and timing tables, built once and never freed.
private nonisolated(unsafe) let z80Tables: UnsafePointer<UInt8> = {
    let t = UnsafeMutablePointer<UInt8>.allocate(capacity: 1280)
    for i in 0 ..< 256 {
        var f = UInt8(i) & (flagS | flagXY)
        if i == 0 { f |= flagZ }
        t[tableSZ + i] = f
        t[tableSZP + i] = f | (i.nonzeroBitCount & 1 == 0 ? flagPV : 0)
    }
    let main: [UInt8] = [
        4, 10, 7, 6, 4, 4, 7, 4, 4, 11, 7, 6, 4, 4, 7, 4,
        8, 10, 7, 6, 4, 4, 7, 4, 12, 11, 7, 6, 4, 4, 7, 4,
        7, 10, 16, 6, 4, 4, 7, 4, 7, 11, 16, 6, 4, 4, 7, 4,
        7, 10, 13, 6, 11, 11, 10, 4, 7, 11, 13, 6, 4, 4, 7, 4,
        4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
        4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
        4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
        7, 7, 7, 7, 7, 7, 4, 7, 4, 4, 4, 4, 4, 4, 7, 4,
        4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
        4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
        4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
        4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
        5, 10, 10, 10, 10, 11, 7, 11, 5, 10, 10, 0, 10, 17, 7, 11,
        5, 10, 10, 11, 10, 11, 7, 11, 5, 4, 10, 11, 10, 0, 7, 11,
        5, 10, 10, 19, 10, 11, 7, 11, 5, 4, 10, 4, 10, 0, 7, 11,
        5, 10, 10, 4, 10, 11, 7, 11, 5, 6, 10, 4, 10, 0, 7, 11,
    ]
    for i in 0 ..< 256 { t[tableMain + i] = main[i] }
    for i in 0 ..< 256 {
        var cycles: UInt8 = 8
        if i >= 0x40, i < 0x80 {
            switch i & 7 {
            case 0, 1: cycles = 12
            case 2: cycles = 15
            case 3: cycles = 20
            case 5: cycles = 14
            case 7: cycles = i < 0x60 ? 9 : (i < 0x70 ? 18 : 8)
            default: cycles = 8
            }
        } else if i >= 0xA0, i < 0xC0, i & 7 < 4 {
            cycles = 16
        }
        t[tableED + i] = cycles
    }
    for i in 0 ..< 256 {
        var cycles: UInt8 = 4
        switch i {
        case 0x09, 0x19, 0x29, 0x39: cycles = 15
        case 0x21: cycles = 14
        case 0x22, 0x2A: cycles = 20
        case 0x23, 0x2B: cycles = 10
        case 0x24, 0x25, 0x2C, 0x2D: cycles = 8
        case 0x26, 0x2E: cycles = 11
        case 0x34, 0x35: cycles = 23
        case 0x36: cycles = 19
        case 0x76: cycles = 4
        case 0x40 ..< 0xC0:
            let source = i & 7, target = (i >> 3) & 7
            if source == 6 || (i < 0x80 && target == 6) {
                cycles = 19
            } else if source == 4 || source == 5 || (i < 0x80 && (target == 4 || target == 5)) {
                cycles = 8
            }
        case 0xCB: cycles = 0 // 20 or 23, added by the DDCB handler
        case 0xE1: cycles = 14
        case 0xE3: cycles = 23
        case 0xE5: cycles = 15
        case 0xE9: cycles = 8
        case 0xF9: cycles = 10
        default: break
        }
        t[tableIndex + i] = cycles
    }
    return UnsafePointer(t)
}()

public struct Z80<Bus: Z80Bus> {
    public var a: UInt8 = 0xFF
    public var f: UInt8 = 0xFF
    public var bc: UInt16 = 0xFFFF
    public var de: UInt16 = 0xFFFF
    public var hl: UInt16 = 0xFFFF
    public var ix: UInt16 = 0xFFFF
    public var iy: UInt16 = 0xFFFF
    public var sp: UInt16 = 0xFFFF
    public var pc: UInt16 = 0
    /// Internal MEMPTR register; visible only through the X/Y flags of `BIT n,(HL)`.
    public var wz: UInt16 = 0
    public var altAF: UInt16 = 0xFFFF
    public var altBC: UInt16 = 0xFFFF
    public var altDE: UInt16 = 0xFFFF
    public var altHL: UInt16 = 0xFFFF
    public var i: UInt8 = 0
    /// Low seven bits count opcode fetches; bit 7 is kept in `rHigh`.
    private var rCounter: UInt8 = 0
    private var rHigh: UInt8 = 0
    public var iff1 = false
    public var iff2 = false
    public var interruptMode: UInt8 = 0
    public var halted = false
    /// Running T-state counter. The owner may rebase it with `rebase(by:)`.
    public var tstates = 0
    /// Value of `tstates` when the last EI finished: an interrupt is not accepted at that boundary.
    private var eiEnd = -1

    public let memory: UnsafeMutablePointer<UInt8>
    private unowned(unsafe) let bus: Bus
    private let tables: UnsafePointer<UInt8>

    /// `memory` must point at 65,536 bytes and, like `bus`, outlive the CPU.
    public init(memory: UnsafeMutablePointer<UInt8>, bus: Bus) {
        self.memory = memory
        self.bus = bus
        tables = z80Tables
    }

    // MARK: Register views

    public var b: UInt8 {
        @inline(__always) get { UInt8(truncatingIfNeeded: bc >> 8) }
        @inline(__always) set { bc = (bc & 0x00FF) | UInt16(newValue) << 8 }
    }

    public var c: UInt8 {
        @inline(__always) get { UInt8(truncatingIfNeeded: bc) }
        @inline(__always) set { bc = (bc & 0xFF00) | UInt16(newValue) }
    }

    public var d: UInt8 {
        @inline(__always) get { UInt8(truncatingIfNeeded: de >> 8) }
        @inline(__always) set { de = (de & 0x00FF) | UInt16(newValue) << 8 }
    }

    public var e: UInt8 {
        @inline(__always) get { UInt8(truncatingIfNeeded: de) }
        @inline(__always) set { de = (de & 0xFF00) | UInt16(newValue) }
    }

    public var h: UInt8 {
        @inline(__always) get { UInt8(truncatingIfNeeded: hl >> 8) }
        @inline(__always) set { hl = (hl & 0x00FF) | UInt16(newValue) << 8 }
    }

    public var l: UInt8 {
        @inline(__always) get { UInt8(truncatingIfNeeded: hl) }
        @inline(__always) set { hl = (hl & 0xFF00) | UInt16(newValue) }
    }

    public var af: UInt16 {
        @inline(__always) get { UInt16(a) << 8 | UInt16(f) }
        @inline(__always) set {
            a = UInt8(truncatingIfNeeded: newValue >> 8)
            f = UInt8(truncatingIfNeeded: newValue)
        }
    }

    public var r: UInt8 {
        get { (rCounter & 0x7F) | (rHigh & 0x80) }
        set {
            rCounter = newValue
            rHigh = newValue
        }
    }

    // MARK: Memory

    @inline(__always) private func read(_ address: UInt16) -> UInt8 {
        memory[Int(address)]
    }

    @inline(__always) private func write(_ address: UInt16, _ value: UInt8) {
        memory[Int(address)] = value
    }

    @inline(__always) private func readWord(_ address: UInt16) -> UInt16 {
        UInt16(memory[Int(address)]) | UInt16(memory[Int(address &+ 1)]) << 8
    }

    @inline(__always) private func writeWord(_ address: UInt16, _ value: UInt16) {
        memory[Int(address)] = UInt8(truncatingIfNeeded: value)
        memory[Int(address &+ 1)] = UInt8(truncatingIfNeeded: value >> 8)
    }

    @inline(__always) private mutating func fetch() -> UInt8 {
        let value = memory[Int(pc)]
        pc &+= 1
        return value
    }

    @inline(__always) private mutating func fetchWord() -> UInt16 {
        let value = readWord(pc)
        pc &+= 2
        return value
    }

    @inline(__always) private mutating func push(_ value: UInt16) {
        sp &-= 2
        writeWord(sp, value)
    }

    @inline(__always) private mutating func pop() -> UInt16 {
        let value = readWord(sp)
        sp &+= 2
        return value
    }

    /// Register by its three-bit instruction encoding; 6 is (HL).
    @inline(__always) private func register(_ index: UInt8) -> UInt8 {
        switch index & 7 {
        case 0: return b
        case 1: return c
        case 2: return d
        case 3: return e
        case 4: return h
        case 5: return l
        case 6: return read(hl)
        default: return a
        }
    }

    @inline(__always) private mutating func setRegister(_ index: UInt8, _ value: UInt8) {
        switch index & 7 {
        case 0: b = value
        case 1: c = value
        case 2: d = value
        case 3: e = value
        case 4: h = value
        case 5: l = value
        case 6: write(hl, value)
        default: a = value
        }
    }

    @inline(__always) private func condition(_ index: UInt8) -> Bool {
        switch index & 7 {
        case 0: return f & flagZ == 0
        case 1: return f & flagZ != 0
        case 2: return f & flagC == 0
        case 3: return f & flagC != 0
        case 4: return f & flagPV == 0
        case 5: return f & flagPV != 0
        case 6: return f & flagS == 0
        default: return f & flagS != 0
        }
    }

    // MARK: Arithmetic

    @inline(__always) private mutating func add(_ value: UInt8, carry: UInt8) {
        let x = Int(a), y = Int(value)
        let result = x &+ y &+ Int(carry)
        var flags = tables[tableSZ + (result & 0xFF)]
        flags |= UInt8(truncatingIfNeeded: result >> 8) & flagC
        flags |= UInt8(truncatingIfNeeded: x ^ y ^ result) & flagH
        flags |= UInt8(truncatingIfNeeded: ((x ^ result) & (y ^ result) & 0x80) >> 5)
        a = UInt8(truncatingIfNeeded: result)
        f = flags
    }

    @inline(__always) private mutating func subtract(_ value: UInt8, carry: UInt8) {
        a = compare(value, carry: carry, xyFromOperand: false)
    }

    /// A - value - carry with flags set; returns the result without storing it.
    @inline(__always) private mutating func compare(_ value: UInt8, carry: UInt8, xyFromOperand: Bool) -> UInt8 {
        let x = Int(a), y = Int(value)
        let result = x &- y &- Int(carry)
        var flags = tables[tableSZ + (result & 0xFF)] | flagN
        flags |= UInt8(truncatingIfNeeded: result >> 8) & flagC
        flags |= UInt8(truncatingIfNeeded: x ^ y ^ result) & flagH
        flags |= UInt8(truncatingIfNeeded: ((x ^ y) & (x ^ result) & 0x80) >> 5)
        if xyFromOperand { flags = (flags & ~flagXY) | (value & flagXY) }
        f = flags
        return UInt8(truncatingIfNeeded: result)
    }

    @inline(__always) private mutating func arithmetic(_ operation: UInt8, _ value: UInt8) {
        switch operation & 7 {
        case 0: add(value, carry: 0)
        case 1: add(value, carry: f & flagC)
        case 2: subtract(value, carry: 0)
        case 3: subtract(value, carry: f & flagC)
        case 4:
            a &= value
            f = tables[tableSZP + Int(a)] | flagH
        case 5:
            a ^= value
            f = tables[tableSZP + Int(a)]
        case 6:
            a |= value
            f = tables[tableSZP + Int(a)]
        default:
            _ = compare(value, carry: 0, xyFromOperand: true)
        }
    }

    @inline(__always) private mutating func increment(_ value: UInt8) -> UInt8 {
        let result = value &+ 1
        var flags = (f & flagC) | tables[tableSZ + Int(result)]
        if result & 0x0F == 0 { flags |= flagH }
        if result == 0x80 { flags |= flagPV }
        f = flags
        return result
    }

    @inline(__always) private mutating func decrement(_ value: UInt8) -> UInt8 {
        let result = value &- 1
        var flags = (f & flagC) | flagN | tables[tableSZ + Int(result)]
        if value & 0x0F == 0 { flags |= flagH }
        if result == 0x7F { flags |= flagPV }
        f = flags
        return result
    }

    @inline(__always) private mutating func add16(_ target: UInt16, _ value: UInt16) -> UInt16 {
        let x = Int(target), y = Int(value)
        let result = x &+ y
        var flags = f & (flagS | flagZ | flagPV)
        flags |= UInt8(truncatingIfNeeded: result >> 16) & flagC
        flags |= UInt8(truncatingIfNeeded: result >> 8) & flagXY
        flags |= UInt8(truncatingIfNeeded: (x ^ y ^ result) >> 8) & flagH
        f = flags
        wz = target &+ 1
        return UInt16(truncatingIfNeeded: result)
    }

    @inline(__always) private mutating func addCarry16(_ value: UInt16) {
        let x = Int(hl), y = Int(value)
        let result = x &+ y &+ Int(f & flagC)
        var flags = UInt8(truncatingIfNeeded: result >> 16) & flagC
        flags |= UInt8(truncatingIfNeeded: result >> 8) & (flagS | flagXY)
        if result & 0xFFFF == 0 { flags |= flagZ }
        flags |= UInt8(truncatingIfNeeded: (x ^ y ^ result) >> 8) & flagH
        flags |= UInt8(truncatingIfNeeded: ((x ^ result) & (y ^ result) & 0x8000) >> 13)
        f = flags
        wz = hl &+ 1
        hl = UInt16(truncatingIfNeeded: result)
    }

    @inline(__always) private mutating func subtractCarry16(_ value: UInt16) {
        let x = Int(hl), y = Int(value)
        let result = x &- y &- Int(f & flagC)
        var flags = (UInt8(truncatingIfNeeded: result >> 16) & flagC) | flagN
        flags |= UInt8(truncatingIfNeeded: result >> 8) & (flagS | flagXY)
        if result & 0xFFFF == 0 { flags |= flagZ }
        flags |= UInt8(truncatingIfNeeded: (x ^ y ^ result) >> 8) & flagH
        flags |= UInt8(truncatingIfNeeded: ((x ^ y) & (x ^ result) & 0x8000) >> 13)
        f = flags
        wz = hl &+ 1
        hl = UInt16(truncatingIfNeeded: result)
    }

    private mutating func decimalAdjust() {
        var correction: UInt8 = 0
        var carry = f & flagC
        if f & flagH != 0 || a & 0x0F > 9 { correction = 6 }
        if carry != 0 || a > 0x99 { correction |= 0x60 }
        if a > 0x99 { carry = flagC }
        if f & flagN != 0 {
            subtract(correction, carry: 0)
        } else {
            add(correction, carry: 0)
        }
        f = (f & ~(flagC | flagPV)) | carry | (tables[tableSZP + Int(a)] & flagPV)
    }

    /// The eight CB-prefixed rotates and shifts.
    @inline(__always) private mutating func rotate(_ operation: UInt8, _ value: UInt8) -> UInt8 {
        var result: UInt8
        var carry: UInt8
        switch operation & 7 {
        case 0: // RLC
            result = value << 1 | value >> 7
            carry = value >> 7
        case 1: // RRC
            result = value >> 1 | value << 7
            carry = value & 1
        case 2: // RL
            result = value << 1 | (f & flagC)
            carry = value >> 7
        case 3: // RR
            result = value >> 1 | (f & flagC) << 7
            carry = value & 1
        case 4: // SLA
            result = value << 1
            carry = value >> 7
        case 5: // SRA
            result = (value & 0x80) | value >> 1
            carry = value & 1
        case 6: // SLL (undocumented)
            result = value << 1 | 1
            carry = value >> 7
        default: // SRL
            result = value >> 1
            carry = value & 1
        }
        f = tables[tableSZP + Int(result)] | carry
        return result
    }

    /// Flags of BIT; X and Y come from `xy`.
    @inline(__always) private mutating func testBit(_ bit: UInt8, _ value: UInt8, xy: UInt8) {
        var flags = (f & flagC) | flagH | (xy & flagXY)
        let masked = value & (1 << (bit & 7))
        if masked == 0 { flags |= flagZ | flagPV }
        flags |= masked & flagS
        f = flags
    }

    // MARK: Control

    @inline(__always) private mutating func jumpRelative() {
        let offset = Int8(bitPattern: fetch())
        pc = pc &+ UInt16(bitPattern: Int16(offset))
        wz = pc
    }

    /// Restores the reset state apart from memory.
    public mutating func reset() {
        a = 0xFF; f = 0xFF
        bc = 0xFFFF; de = 0xFFFF; hl = 0xFFFF
        ix = 0xFFFF; iy = 0xFFFF; sp = 0xFFFF
        altAF = 0xFFFF; altBC = 0xFFFF; altDE = 0xFFFF; altHL = 0xFFFF
        pc = 0; wz = 0; i = 0; r = 0
        iff1 = false; iff2 = false; interruptMode = 0; halted = false
        tstates = 0; eiEnd = -1
    }

    /// Subtracts `amount` from the T-state counter, typically one frame at each frame boundary.
    @inline(__always) public mutating func rebase(by amount: Int) {
        tstates &-= amount
        eiEnd = eiEnd >= amount ? eiEnd &- amount : -1
    }

    /// True when a maskable interrupt raised now would be taken (not masked, not straight after EI).
    public var acceptsInterrupt: Bool {
        @inline(__always) get { iff1 && tstates != eiEnd }
    }

    /// Requests a maskable interrupt with `data` on the bus. Returns false if it was not accepted.
    @discardableResult
    public mutating func interrupt(data: UInt8 = 0xFF) -> Bool {
        guard iff1, tstates != eiEnd else { return false }
        halted = false
        iff1 = false
        iff2 = false
        rCounter &+= 1
        switch interruptMode {
        case 2:
            push(pc)
            pc = readWord(UInt16(i) << 8 | UInt16(data))
            wz = pc
            tstates &+= 19
        case 1:
            push(pc)
            pc = 0x38
            wz = pc
            tstates &+= 13
        default:
            // Mode 0 executes the byte the device supplies; a floating bus gives RST 38h (13 T-states).
            tstates &+= 2
            executeMain(data)
        }
        return true
    }

    public mutating func nonMaskableInterrupt() {
        halted = false
        iff1 = false
        rCounter &+= 1
        push(pc)
        pc = 0x66
        wz = pc
        tstates &+= 11
    }

    /// Executes one instruction, or one four T-state idle cycle while halted.
    @inline(__always) public mutating func step() {
        rCounter &+= 1
        if halted {
            tstates &+= 4
            return
        }
        executeMain(fetch())
    }

    /// Runs until the T-state counter reaches `limit`. A halted CPU is advanced in one go.
    @inline(__always) public mutating func run(until limit: Int) {
        while tstates < limit {
            if halted {
                let idle = (limit &- tstates &+ 3) >> 2
                tstates &+= idle << 2
                rCounter &+= UInt8(truncatingIfNeeded: idle)
                return
            }
            rCounter &+= 1
            executeMain(fetch())
        }
    }

    // MARK: Unprefixed instructions

    private mutating func executeMain(_ opcode: UInt8) {
        tstates &+= Int(tables[tableMain + Int(opcode)])
        switch opcode {
        case 0x00: // NOP
            break
        case 0x01: bc = fetchWord()
        case 0x11: de = fetchWord()
        case 0x21: hl = fetchWord()
        case 0x31: sp = fetchWord()

        case 0x02: // LD (BC),A
            write(bc, a)
            wz = ((bc &+ 1) & 0xFF) | UInt16(a) << 8
        case 0x12: // LD (DE),A
            write(de, a)
            wz = ((de &+ 1) & 0xFF) | UInt16(a) << 8
        case 0x0A: // LD A,(BC)
            a = read(bc)
            wz = bc &+ 1
        case 0x1A: // LD A,(DE)
            a = read(de)
            wz = de &+ 1
        case 0x22: // LD (nn),HL
            let address = fetchWord()
            writeWord(address, hl)
            wz = address &+ 1
        case 0x2A: // LD HL,(nn)
            let address = fetchWord()
            hl = readWord(address)
            wz = address &+ 1
        case 0x32: // LD (nn),A
            let address = fetchWord()
            write(address, a)
            wz = ((address &+ 1) & 0xFF) | UInt16(a) << 8
        case 0x3A: // LD A,(nn)
            let address = fetchWord()
            a = read(address)
            wz = address &+ 1

        case 0x03: bc &+= 1
        case 0x13: de &+= 1
        case 0x23: hl &+= 1
        case 0x33: sp &+= 1
        case 0x0B: bc &-= 1
        case 0x1B: de &-= 1
        case 0x2B: hl &-= 1
        case 0x3B: sp &-= 1

        case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C: // INC r
            let index = opcode >> 3
            setRegister(index, increment(register(index)))
        case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D: // DEC r
            let index = opcode >> 3
            setRegister(index, decrement(register(index)))
        case 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x36, 0x3E: // LD r,n
            setRegister(opcode >> 3, fetch())

        case 0x07: // RLCA
            a = a << 1 | a >> 7
            f = (f & (flagS | flagZ | flagPV)) | (a & (flagXY | flagC))
        case 0x0F: // RRCA
            f = (f & (flagS | flagZ | flagPV)) | (a & flagC)
            a = a >> 1 | a << 7
            f |= a & flagXY
        case 0x17: // RLA
            let old = a
            a = a << 1 | (f & flagC)
            f = (f & (flagS | flagZ | flagPV)) | (a & flagXY) | old >> 7
        case 0x1F: // RRA
            let old = a
            a = a >> 1 | (f & flagC) << 7
            f = (f & (flagS | flagZ | flagPV)) | (a & flagXY) | (old & flagC)

        case 0x08: // EX AF,AF'
            let swap = af
            af = altAF
            altAF = swap

        case 0x09: hl = add16(hl, bc)
        case 0x19: hl = add16(hl, de)
        case 0x29: hl = add16(hl, hl)
        case 0x39: hl = add16(hl, sp)

        case 0x10: // DJNZ
            b = b &- 1
            if b != 0 {
                jumpRelative()
                tstates &+= 5
            } else {
                pc &+= 1
            }
        case 0x18: // JR
            jumpRelative()
        case 0x20, 0x28, 0x30, 0x38: // JR cc
            if condition((opcode >> 3) & 3) {
                jumpRelative()
                tstates &+= 5
            } else {
                pc &+= 1
            }

        case 0x27: decimalAdjust()
        case 0x2F: // CPL
            a = ~a
            f = (f & (flagC | flagPV | flagZ | flagS)) | (a & flagXY) | flagN | flagH
        case 0x37: // SCF
            f = (f & (flagPV | flagZ | flagS)) | (a & flagXY) | flagC
        case 0x3F: // CCF
            f = (f & (flagPV | flagZ | flagS)) | (f & flagC != 0 ? flagH : flagC) | (a & flagXY)

        case 0x76: // HALT
            halted = true
        case 0x40 ... 0x7F: // LD r,r'
            setRegister(opcode >> 3, register(opcode))
        case 0x80 ... 0xBF:
            arithmetic(opcode >> 3, register(opcode))

        case 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8: // RET cc
            if condition(opcode >> 3) {
                pc = pop()
                wz = pc
                tstates &+= 6
            }
        case 0xC9: // RET
            pc = pop()
            wz = pc
        case 0xC1: bc = pop()
        case 0xD1: de = pop()
        case 0xE1: hl = pop()
        case 0xF1: af = pop()
        case 0xC5: push(bc)
        case 0xD5: push(de)
        case 0xE5: push(hl)
        case 0xF5: push(af)

        case 0xC2, 0xCA, 0xD2, 0xDA, 0xE2, 0xEA, 0xF2, 0xFA: // JP cc,nn
            let target = fetchWord()
            wz = target
            if condition(opcode >> 3) { pc = target }
        case 0xC3: // JP nn
            pc = fetchWord()
            wz = pc
        case 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC: // CALL cc,nn
            let target = fetchWord()
            wz = target
            if condition(opcode >> 3) {
                push(pc)
                pc = target
                tstates &+= 7
            }
        case 0xCD: // CALL nn
            let target = fetchWord()
            wz = target
            push(pc)
            pc = target
        case 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE: // arithmetic with n
            arithmetic(opcode >> 3, fetch())
        case 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF: // RST
            push(pc)
            pc = UInt16(opcode & 0x38)
            wz = pc

        case 0xD3: // OUT (n),A
            let low = fetch()
            let port = UInt16(a) << 8 | UInt16(low)
            wz = UInt16(low &+ 1) | UInt16(a) << 8
            bus.portOut(port, value: a, tstate: tstates &- 3)
        case 0xDB: // IN A,(n)
            let port = UInt16(a) << 8 | UInt16(fetch())
            wz = port &+ 1
            a = bus.portIn(port, tstate: tstates &- 3)
        case 0xD9: // EXX
            var swap = bc; bc = altBC; altBC = swap
            swap = de; de = altDE; altDE = swap
            swap = hl; hl = altHL; altHL = swap
        case 0xE3: // EX (SP),HL
            let value = readWord(sp)
            writeWord(sp, hl)
            hl = value
            wz = value
        case 0xE9: pc = hl // JP (HL)
        case 0xEB: // EX DE,HL
            let swap = de
            de = hl
            hl = swap
        case 0xF3: // DI
            iff1 = false
            iff2 = false
        case 0xFB: // EI
            iff1 = true
            iff2 = true
            eiEnd = tstates
        case 0xF9: sp = hl

        case 0xCB: executeCB()
        case 0xED: executeED()
        case 0xDD: executeIndexed(useIY: false)
        default: executeIndexed(useIY: true) // 0xFD
        }
    }

    // MARK: CB prefix

    private mutating func executeCB() {
        let opcode = fetch()
        rCounter &+= 1
        let index = opcode & 7
        let bit = (opcode >> 3) & 7
        switch opcode >> 6 {
        case 0:
            tstates &+= index == 6 ? 15 : 8
            setRegister(index, rotate(bit, register(index)))
        case 1:
            if index == 6 {
                tstates &+= 12
                testBit(bit, read(hl), xy: UInt8(truncatingIfNeeded: wz >> 8))
            } else {
                tstates &+= 8
                let value = register(index)
                testBit(bit, value, xy: value)
            }
        case 2:
            tstates &+= index == 6 ? 15 : 8
            setRegister(index, register(index) & ~(1 << bit))
        default:
            tstates &+= index == 6 ? 15 : 8
            setRegister(index, register(index) | (1 << bit))
        }
    }

    // MARK: ED prefix

    private mutating func executeED() {
        let opcode = fetch()
        rCounter &+= 1
        tstates &+= Int(tables[tableED + Int(opcode)])
        switch opcode {
        case 0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78: // IN r,(C); 0x70 only sets flags
            let value = bus.portIn(bc, tstate: tstates &- 3)
            wz = bc &+ 1
            f = (f & flagC) | tables[tableSZP + Int(value)]
            let index = opcode >> 3
            if index & 7 != 6 { setRegister(index, value) }
        case 0x41, 0x49, 0x51, 0x59, 0x61, 0x69, 0x71, 0x79: // OUT (C),r; 0x71 writes zero
            let index = opcode >> 3
            let value = index & 7 == 6 ? 0 : register(index)
            wz = bc &+ 1
            bus.portOut(bc, value: value, tstate: tstates &- 3)
        case 0x42: subtractCarry16(bc)
        case 0x52: subtractCarry16(de)
        case 0x62: subtractCarry16(hl)
        case 0x72: subtractCarry16(sp)
        case 0x4A: addCarry16(bc)
        case 0x5A: addCarry16(de)
        case 0x6A: addCarry16(hl)
        case 0x7A: addCarry16(sp)
        case 0x43, 0x53, 0x63, 0x73: // LD (nn),rr
            let address = fetchWord()
            let value: UInt16
            switch opcode {
            case 0x43: value = bc
            case 0x53: value = de
            case 0x63: value = hl
            default: value = sp
            }
            writeWord(address, value)
            wz = address &+ 1
        case 0x4B, 0x5B, 0x6B, 0x7B: // LD rr,(nn)
            let address = fetchWord()
            let value = readWord(address)
            switch opcode {
            case 0x4B: bc = value
            case 0x5B: de = value
            case 0x6B: hl = value
            default: sp = value
            }
            wz = address &+ 1
        case 0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C: // NEG
            let value = a
            a = 0
            subtract(value, carry: 0)
        case 0x45, 0x4D, 0x55, 0x5D, 0x65, 0x6D, 0x75, 0x7D: // RETN, RETI
            iff1 = iff2
            pc = pop()
            wz = pc
        case 0x46, 0x4E, 0x66, 0x6E: interruptMode = 0
        case 0x56, 0x76: interruptMode = 1
        case 0x5E, 0x7E: interruptMode = 2
        case 0x47: i = a
        case 0x4F: r = a
        case 0x57: // LD A,I
            a = i
            f = (f & flagC) | tables[tableSZ + Int(a)] | (iff2 ? flagPV : 0)
        case 0x5F: // LD A,R
            a = r
            f = (f & flagC) | tables[tableSZ + Int(a)] | (iff2 ? flagPV : 0)
        case 0x67: // RRD
            let value = read(hl)
            write(hl, a << 4 | value >> 4)
            a = (a & 0xF0) | (value & 0x0F)
            f = (f & flagC) | tables[tableSZP + Int(a)]
            wz = hl &+ 1
        case 0x6F: // RLD
            let value = read(hl)
            write(hl, value << 4 | (a & 0x0F))
            a = (a & 0xF0) | value >> 4
            f = (f & flagC) | tables[tableSZP + Int(a)]
            wz = hl &+ 1

        case 0xA0, 0xA8, 0xB0, 0xB8: // LDI, LDD, LDIR, LDDR
            let value = read(hl)
            write(de, value)
            let step: UInt16 = opcode & 8 == 0 ? 1 : 0xFFFF
            hl &+= step
            de &+= step
            bc &-= 1
            let sum = value &+ a
            f = (f & (flagC | flagZ | flagS)) | (bc != 0 ? flagPV : 0) | (sum & flagX) | (sum & 0x02 != 0 ? flagY : 0)
            if opcode & 0x10 != 0, bc != 0 {
                pc &-= 2
                wz = pc &+ 1
                tstates &+= 5
            }
        case 0xA1, 0xA9, 0xB1, 0xB9: // CPI, CPD, CPIR, CPDR
            let value = read(hl)
            let result = a &- value
            let half = (a ^ value ^ result) & flagH
            let step: UInt16 = opcode & 8 == 0 ? 1 : 0xFFFF
            hl &+= step
            wz &+= step
            bc &-= 1
            var flags = (f & flagC) | flagN | half | (result & flagS)
            if bc != 0 { flags |= flagPV }
            if result == 0 { flags |= flagZ }
            let spill = half != 0 ? result &- 1 : result
            flags |= (spill & flagX) | (spill & 0x02 != 0 ? flagY : 0)
            f = flags
            if opcode & 0x10 != 0, bc != 0, result != 0 {
                pc &-= 2
                wz = pc &+ 1
                tstates &+= 5
            }
        case 0xA2, 0xAA, 0xB2, 0xBA: // INI, IND, INIR, INDR
            let value = bus.portIn(bc, tstate: tstates &- 6)
            write(hl, value)
            let step: UInt16 = opcode & 8 == 0 ? 1 : 0xFFFF
            wz = bc &+ step
            b = b &- 1
            hl &+= step
            let sum = Int(value) &+ Int(c &+ UInt8(truncatingIfNeeded: step))
            blockIOFlags(value: value, sum: sum)
            if opcode & 0x10 != 0, b != 0 {
                pc &-= 2
                tstates &+= 5
            }
        case 0xA3, 0xAB, 0xB3, 0xBB: // OUTI, OUTD, OTIR, OTDR
            let value = read(hl)
            let step: UInt16 = opcode & 8 == 0 ? 1 : 0xFFFF
            // B is decremented before it appears on the address bus.
            b = b &- 1
            wz = bc &+ step
            bus.portOut(bc, value: value, tstate: tstates &- 3)
            hl &+= step
            let sum = Int(value) &+ Int(l)
            blockIOFlags(value: value, sum: sum)
            if opcode & 0x10 != 0, b != 0 {
                pc &-= 2
                tstates &+= 5
            }
        default: // the rest of the ED page does nothing
            break
        }
    }

    @inline(__always) private mutating func blockIOFlags(value: UInt8, sum: Int) {
        var flags = tables[tableSZ + Int(b)]
        if value & 0x80 != 0 { flags |= flagN }
        if sum > 255 { flags |= flagH | flagC }
        flags |= tables[tableSZP + Int(UInt8(truncatingIfNeeded: sum & 7) ^ b)] & flagPV
        f = flags
    }

    // MARK: DD and FD prefixes

    private mutating func executeIndexed(useIY: Bool) {
        let opcode = fetch()
        rCounter &+= 1
        tstates &+= Int(tables[tableIndex + Int(opcode)])
        var index = useIY ? iy : ix
        let high = UInt8(truncatingIfNeeded: index >> 8)
        let low = UInt8(truncatingIfNeeded: index)

        switch opcode {
        case 0x09: index = add16(index, bc)
        case 0x19: index = add16(index, de)
        case 0x29: index = add16(index, index)
        case 0x39: index = add16(index, sp)
        case 0x21: index = fetchWord()
        case 0x22:
            let address = fetchWord()
            writeWord(address, index)
            wz = address &+ 1
        case 0x2A:
            let address = fetchWord()
            index = readWord(address)
            wz = address &+ 1
        case 0x23: index &+= 1
        case 0x2B: index &-= 1
        case 0x24: index = (index & 0x00FF) | UInt16(increment(high)) << 8
        case 0x25: index = (index & 0x00FF) | UInt16(decrement(high)) << 8
        case 0x26: index = (index & 0x00FF) | UInt16(fetch()) << 8
        case 0x2C: index = (index & 0xFF00) | UInt16(increment(low))
        case 0x2D: index = (index & 0xFF00) | UInt16(decrement(low))
        case 0x2E: index = (index & 0xFF00) | UInt16(fetch())
        case 0x34:
            let address = displaced(index)
            write(address, increment(read(address)))
        case 0x35:
            let address = displaced(index)
            write(address, decrement(read(address)))
        case 0x36:
            let address = displaced(index)
            write(address, fetch())

        case 0x46, 0x4E, 0x56, 0x5E, 0x66, 0x6E, 0x7E: // LD r,(I+d)
            let address = displaced(index)
            setRegister(opcode >> 3, read(address))
        case 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x77: // LD (I+d),r
            let address = displaced(index)
            write(address, register(opcode))
        case 0x44, 0x4C, 0x54, 0x5C, 0x7C: setRegister(opcode >> 3, high)
        case 0x45, 0x4D, 0x55, 0x5D, 0x7D: setRegister(opcode >> 3, low)
        case 0x60, 0x61, 0x62, 0x63, 0x67: index = (index & 0x00FF) | UInt16(register(opcode)) << 8
        case 0x68, 0x69, 0x6A, 0x6B, 0x6F: index = (index & 0xFF00) | UInt16(register(opcode))
        case 0x64, 0x6D: break // LD IXH,IXH and LD IXL,IXL
        case 0x65: index = (index & 0x00FF) | (index & 0x00FF) << 8
        case 0x6C: index = (index & 0xFF00) | index >> 8

        case 0x84, 0x8C, 0x94, 0x9C, 0xA4, 0xAC, 0xB4, 0xBC: arithmetic(opcode >> 3, high)
        case 0x85, 0x8D, 0x95, 0x9D, 0xA5, 0xAD, 0xB5, 0xBD: arithmetic(opcode >> 3, low)
        case 0x86, 0x8E, 0x96, 0x9E, 0xA6, 0xAE, 0xB6, 0xBE:
            let address = displaced(index)
            arithmetic(opcode >> 3, read(address))

        case 0xE1: index = pop()
        case 0xE5: push(index)
        case 0xE3:
            let value = readWord(sp)
            writeWord(sp, index)
            index = value
            wz = value
        case 0xE9: pc = index
        case 0xF9: sp = index

        case 0xCB:
            let address = displaced(index)
            let operation = fetch()
            let target = operation & 7
            let bit = (operation >> 3) & 7
            let value = read(address)
            switch operation >> 6 {
            case 1:
                tstates &+= 20
                testBit(bit, value, xy: UInt8(truncatingIfNeeded: address >> 8))
            case 0:
                tstates &+= 23
                let result = rotate(bit, value)
                write(address, result)
                if target != 6 { setRegister(target, result) }
            case 2:
                tstates &+= 23
                let result = value & ~(1 << bit)
                write(address, result)
                if target != 6 { setRegister(target, result) }
            default:
                tstates &+= 23
                let result = value | (1 << bit)
                write(address, result)
                if target != 6 { setRegister(target, result) }
            }

        case 0xDD, 0xFD:
            // A prefix followed by another prefix: the first one only costs four T-states. The second
            // is left to be fetched as the next instruction (no recursion, so a run of prefixes cannot
            // overflow the stack), with interrupts held off in between as on the real chip.
            pc &-= 1
            rCounter &-= 1
            eiEnd = tstates
            return

        default:
            // Not an index instruction: the prefix costs four T-states and the opcode runs unchanged.
            executeMain(opcode)
            return
        }
        if useIY { iy = index } else { ix = index }
    }

    @inline(__always) private mutating func displaced(_ base: UInt16) -> UInt16 {
        let offset = Int8(bitPattern: fetch())
        let address = base &+ UInt16(bitPattern: Int16(offset))
        wz = address
        return address
    }
}
