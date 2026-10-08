// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Motorola 68000, written against the processor's documented behaviour (the M68000 Family
// Programmer's Reference Manual). It is what an Atari ST tune's player needs and no more: every
// instruction of the 68000 does what it should to registers, memory and flags, but nothing here keeps
// the processor's bus timing. Time is counted roughly, four cycles for each word that crosses the bus,
// which is close to the truth for a processor that does little else, and is used only to give up on a
// program that never comes back.
//
// There are no address errors and no instruction prefetch, and the flags the manual leaves undefined
// after decimal arithmetic follow Musashi's, the core the reference player uses.

/// What a 68000 is connected to beyond its RAM: the hardware registers. Addresses are 24 bits.
public protocol M68000Bus: AnyObject {
    func read8(_ address: UInt32) -> UInt8
    func read16(_ address: UInt32) -> UInt16
    func write8(_ address: UInt32, _ value: UInt8)
    func write16(_ address: UInt32, _ value: UInt16)
}

/// Why the processor stopped running.
public enum M68000Stop: Equatable, Sendable {
    /// It used the time it was given.
    case outOfTime
    /// It executed RESET, which is how a program run from here says it has finished.
    case reset
    /// It met something that is not an instruction.
    case illegal
    /// It executed TRAP with this number, and waits to be told what came of it: `resume` goes on after
    /// the instruction, as if the system had answered, and `takeTrap` first takes the exception.
    case trap(Int)
    /// It executed STOP, and waits for an interrupt that will not come.
    case stopped
}

public struct M68000<Bus: M68000Bus>: ~Copyable {
    /// D0 to D7, then A0 to A7. A7 is the stack pointer of the mode the processor is in.
    public var registers = InlineArray<16, UInt32>(repeating: 0)
    public var pc: UInt32 = 0
    private var x = false, n = false, z = false, v = false, c = false
    private var supervisor = true
    private var trace = false
    private var interruptMask: UInt32 = 7
    /// The stack pointer that is not in use: the user's in supervisor mode, the supervisor's in user mode.
    private var otherStack: UInt32 = 0

    private let ram: UnsafeMutablePointer<UInt8>
    private let ramSize: UInt32
    private let bus: Bus
    /// Cycles used since `run` was last called.
    public private(set) var cycles = 0
    private var stop: M68000Stop?

    /// - Parameter ram: the memory at address 0, `ramSize` bytes of it. Everything above is the bus's.
    public init(ram: UnsafeMutablePointer<UInt8>, ramSize: Int, bus: Bus) {
        self.ram = ram
        self.ramSize = UInt32(ramSize)
        self.bus = bus
    }

    // MARK: Memory

    @inline(__always) public mutating func read8(_ address: UInt32) -> UInt32 {
        cycles &+= 4
        let a = address & 0xFF_FFFF
        return a < ramSize ? UInt32(ram[Int(a)]) : UInt32(bus.read8(a))
    }

    @inline(__always) public mutating func read16(_ address: UInt32) -> UInt32 {
        cycles &+= 4
        let a = address & 0xFF_FFFF
        return a < ramSize &- 1 ? UInt32(ram[Int(a)]) << 8 | UInt32(ram[Int(a) + 1]) : UInt32(bus.read16(a))
    }

    @inline(__always) public mutating func read32(_ address: UInt32) -> UInt32 {
        let high = read16(address)
        return high << 16 | read16(address &+ 2)
    }

    @inline(__always) public mutating func write8(_ address: UInt32, _ value: UInt32) {
        cycles &+= 4
        let a = address & 0xFF_FFFF
        if a < ramSize { ram[Int(a)] = UInt8(truncatingIfNeeded: value) } else { bus.write8(a, UInt8(truncatingIfNeeded: value)) }
    }

    @inline(__always) public mutating func write16(_ address: UInt32, _ value: UInt32) {
        cycles &+= 4
        let a = address & 0xFF_FFFF
        if a < ramSize &- 1 {
            ram[Int(a)] = UInt8(truncatingIfNeeded: value >> 8)
            ram[Int(a) + 1] = UInt8(truncatingIfNeeded: value)
        } else {
            bus.write16(a, UInt16(truncatingIfNeeded: value))
        }
    }

    @inline(__always) public mutating func write32(_ address: UInt32, _ value: UInt32) {
        write16(address, value >> 16)
        write16(address &+ 2, value)
    }

    @inline(__always) private mutating func fetch16() -> UInt32 {
        let value = read16(pc)
        pc &+= 2
        return value
    }

    @inline(__always) private mutating func fetch32() -> UInt32 {
        let high = fetch16()
        return high << 16 | fetch16()
    }

    @inline(__always) private mutating func push32(_ value: UInt32) {
        registers[15] &-= 4
        write32(registers[15], value)
    }

    @inline(__always) private mutating func push16(_ value: UInt32) {
        registers[15] &-= 2
        write16(registers[15], value)
    }

    @inline(__always) private mutating func pop32() -> UInt32 {
        let value = read32(registers[15])
        registers[15] &+= 4
        return value
    }

    @inline(__always) private mutating func pop16() -> UInt32 {
        let value = read16(registers[15])
        registers[15] &+= 2
        return value
    }

    // MARK: Status

    private var ccr: UInt32 {
        get { (x ? 16 : 0) | (n ? 8 : 0) | (z ? 4 : 0) | (v ? 2 : 0) | (c ? 1 : 0) }
        set {
            x = newValue & 16 != 0
            n = newValue & 8 != 0
            z = newValue & 4 != 0
            v = newValue & 2 != 0
            c = newValue & 1 != 0
        }
    }

    public var statusRegister: UInt32 {
        (trace ? 0x8000 : 0) | (supervisor ? 0x2000 : 0) | interruptMask << 8 | ccr
    }

    private mutating func setSupervisor(_ on: Bool) {
        guard on != supervisor else { return }
        let other = otherStack
        otherStack = registers[15]
        registers[15] = other
        supervisor = on
    }

    private mutating func setStatusRegister(_ value: UInt32) {
        setSupervisor(value & 0x2000 != 0)
        trace = value & 0x8000 != 0
        interruptMask = (value >> 8) & 7
        ccr = value
    }

    /// Takes an exception: the status and the place to come back to go on the supervisor's stack.
    private mutating func exception(_ vector: UInt32, returningTo address: UInt32) {
        let status = statusRegister
        setSupervisor(true)
        trace = false
        push32(address)
        push16(status)
        pc = read32(vector &* 4)
    }

    // MARK: Running

    /// Puts the processor as it is when the power comes on: every register empty. (The zero flag is
    /// set, which is how the reference player's processor starts, and a tune can tell.)
    public mutating func powerOn() {
        registers = InlineArray(repeating: 0)
        otherStack = 0
        pc = 0
        supervisor = true
        trace = false
        interruptMask = 7
        ccr = 4
    }

    /// Starts as the processor does when it is reset: supervisor mode, interrupts masked, the stack
    /// pointer from address 0 and the program counter from address 4. The other registers are left alone.
    public mutating func reset() {
        setSupervisor(true)
        trace = false
        interruptMask = 7
        registers[15] = read32(0)
        pc = read32(4)
    }

    /// Runs until something stops it, or until `budget` cycles have been used in this call.
    public mutating func run(cycles budget: Int) -> M68000Stop {
        cycles = 0
        return resume(cycles: budget)
    }

    /// Goes on after a stop, with what is left of `budget` since `run` was called.
    public mutating func resume(cycles budget: Int) -> M68000Stop {
        stop = nil
        while cycles < budget {
            execute()
            if let stop { return stop }
        }
        return .outOfTime
    }

    /// Takes the exception of the TRAP the processor has just stopped at, for a trap nobody answers.
    public mutating func takeTrap(_ number: Int) {
        exception(32 &+ UInt32(number), returningTo: pc)
    }

    // MARK: Operands

    /// Where an operand is: a register, by its place in `registers`, or an address in memory.
    private struct Operand {
        var inMemory: Bool
        var at: UInt32
    }

    @inline(__always) private static func mask(_ size: UInt32) -> UInt32 {
        size == 0 ? 0xFF : size == 1 ? 0xFFFF : 0xFFFF_FFFF
    }

    @inline(__always) private static func sign(_ size: UInt32) -> UInt32 {
        size == 0 ? 0x80 : size == 1 ? 0x8000 : 0x8000_0000
    }

    @inline(__always) private static func extend16(_ value: UInt32) -> UInt32 {
        UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: value)))
    }

    @inline(__always) private static func extend8(_ value: UInt32) -> UInt32 {
        UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: value)))
    }

    /// An address register plus an index register plus a small displacement.
    @inline(__always) private mutating func indexed(_ base: UInt32) -> UInt32 {
        let word = fetch16()
        var index = registers[Int(word >> 12)]
        if word & 0x800 == 0 { index = Self.extend16(index) }
        return base &+ index &+ Self.extend8(word)
    }

    /// Works out where the operand of an addressing mode is, reading any extension words and moving
    /// the address register of a postincrement or predecrement mode. `size` is 0, 1 or 2 for a byte,
    /// a word or a long.
    private mutating func operand(_ mode: UInt32, _ register: UInt32, _ size: UInt32) -> Operand {
        let a = Int(register) + 8
        switch mode {
        case 0: return Operand(inMemory: false, at: register)
        case 1: return Operand(inMemory: false, at: register + 8)
        case 2: return Operand(inMemory: true, at: registers[a])
        case 3:
            let address = registers[a]
            // The stack pointer stays on a word boundary.
            registers[a] = address &+ (size == 0 ? (register == 7 ? 2 : 1) : size == 1 ? 2 : 4)
            return Operand(inMemory: true, at: address)
        case 4:
            let address = registers[a] &- (size == 0 ? (register == 7 ? 2 : 1) : size == 1 ? 2 : 4)
            registers[a] = address
            return Operand(inMemory: true, at: address)
        case 5:
            return Operand(inMemory: true, at: registers[a] &+ Self.extend16(fetch16()))
        case 6:
            return Operand(inMemory: true, at: indexed(registers[a]))
        default:
            switch register {
            case 0: return Operand(inMemory: true, at: Self.extend16(fetch16()))
            case 1: return Operand(inMemory: true, at: fetch32())
            case 2:
                let base = pc
                return Operand(inMemory: true, at: base &+ Self.extend16(fetch16()))
            case 3:
                let base = pc
                return Operand(inMemory: true, at: indexed(base))
            case 4:
                // The value follows the instruction. A byte is the low half of a word.
                let address = pc
                pc &+= size == 2 ? 4 : 2
                return Operand(inMemory: true, at: size == 0 ? address &+ 1 : address)
            default:
                stop = .illegal
                return Operand(inMemory: true, at: 0)
            }
        }
    }

    @inline(__always) private mutating func read(_ operand: Operand, _ size: UInt32) -> UInt32 {
        guard operand.inMemory else { return registers[Int(operand.at)] & Self.mask(size) }
        return size == 0 ? read8(operand.at) : size == 1 ? read16(operand.at) : read32(operand.at)
    }

    @inline(__always) private mutating func write(_ operand: Operand, _ size: UInt32, _ value: UInt32) {
        if operand.inMemory {
            if size == 0 { write8(operand.at, value) } else if size == 1 { write16(operand.at, value) } else { write32(operand.at, value) }
        } else {
            let mask = Self.mask(size)
            registers[Int(operand.at)] = registers[Int(operand.at)] & ~mask | value & mask
        }
    }

    // MARK: Arithmetic

    /// Adds, setting the flags. With `extended`, X is added in and Z is only ever cleared, so that it
    /// tells of the whole of a number added a part at a time.
    @inline(__always) private mutating func add(_ source: UInt32, _ destination: UInt32, _ size: UInt32, extended: Bool = false) -> UInt32 {
        let mask = Self.mask(size), sign = Self.sign(size)
        let wide = UInt64(source & mask) &+ UInt64(destination & mask) &+ (extended && x ? 1 : 0)
        let result = UInt32(truncatingIfNeeded: wide) & mask
        c = wide > UInt64(mask)
        x = c
        v = (source ^ result) & (destination ^ result) & sign != 0
        n = result & sign != 0
        z = extended ? z && result == 0 : result == 0
        return result
    }

    /// Subtracts `source` from `destination`, setting the flags; a comparison leaves X as it was.
    @inline(__always) private mutating func subtract(_ source: UInt32, _ destination: UInt32, _ size: UInt32, extended: Bool = false, comparing: Bool = false) -> UInt32 {
        let mask = Self.mask(size), sign = Self.sign(size)
        let borrow: UInt64 = extended && x ? 1 : 0
        let result = UInt32(truncatingIfNeeded: UInt64(destination & mask) &- UInt64(source & mask) &- borrow) & mask
        c = UInt64(source & mask) &+ borrow > UInt64(destination & mask)
        if !comparing { x = c }
        v = (source ^ destination) & (result ^ destination) & sign != 0
        n = result & sign != 0
        z = extended ? z && result == 0 : result == 0
        return result
    }

    /// The flags after a move or a logical operation.
    @inline(__always) private mutating func logic(_ result: UInt32, _ size: UInt32) {
        n = result & Self.sign(size) != 0
        z = result & Self.mask(size) == 0
        v = false
        c = false
    }

    @inline(__always) private func condition(_ code: UInt32) -> Bool {
        switch code {
        case 0: true
        case 1: false
        case 2: !c && !z
        case 3: c || z
        case 4: !c
        case 5: c
        case 6: !z
        case 7: z
        case 8: !v
        case 9: v
        case 10: !n
        case 11: n
        case 12: n == v
        case 13: n != v
        case 14: !z && n == v
        default: z || n != v
        }
    }

    /// Shifts and rotates, a bit at a time. `kind` is 0 arithmetic, 1 logical, 2 rotate through X, 3 rotate.
    private mutating func shift(_ kind: UInt32, left: Bool, _ value: UInt32, count: UInt32, _ size: UInt32) -> UInt32 {
        let mask = Self.mask(size), sign = Self.sign(size)
        var value = value & mask
        v = false
        c = false
        cycles &+= Int(count) &* 2
        for _ in 0 ..< count {
            if left {
                let out = value & sign != 0
                switch kind {
                case 0:
                    value = (value << 1) & mask
                    // Overflow if the sign changes at any point on the way.
                    if (value & sign != 0) != out { v = true }
                    x = out
                case 1:
                    value = (value << 1) & mask
                    x = out
                case 2:
                    value = (value << 1 | (x ? 1 : 0)) & mask
                    x = out
                default:
                    value = (value << 1 | (out ? 1 : 0)) & mask
                }
                c = out
            } else {
                let out = value & 1 != 0
                switch kind {
                case 0:
                    value = value >> 1 | value & sign
                    x = out
                case 1:
                    value >>= 1
                    x = out
                case 2:
                    value = value >> 1 | (x ? sign : 0)
                    x = out
                default:
                    value = value >> 1 | (out ? sign : 0)
                }
                c = out
            }
        }
        if kind == 2, count == 0 { c = x }
        n = value & sign != 0
        z = value == 0
        return value
    }

    // MARK: Instructions

    private mutating func execute() {
        let start = pc
        let op = fetch16()
        let mode = (op >> 3) & 7, register = op & 7
        let upper = (op >> 9) & 7
        let size = (op >> 6) & 3

        switch op >> 12 {
        case 0x0:
            if op & 0x100 != 0 {
                if mode == 1 {
                    movep(op)
                } else {
                    bit(size, number: registers[Int(upper)], mode, register)
                }
            } else if upper == 4 {
                let number = fetch16()
                bit(size, number: number, mode, register)
            } else if upper == 7 || size == 3 {
                stop = .illegal
            } else {
                let immediate = size == 0 ? fetch16() & 0xFF : size == 1 ? fetch16() : fetch32()
                if mode == 7, register == 4 {
                    // To the condition codes, or to the whole status register.
                    let old = size == 0 ? ccr : statusRegister
                    let new: UInt32
                    switch upper {
                    case 0: new = old | immediate
                    case 1: new = old & immediate
                    case 5: new = old ^ immediate
                    default:
                        stop = .illegal
                        return
                    }
                    if size == 0 {
                        ccr = new
                    } else if supervisor {
                        setStatusRegister(new)
                    } else {
                        exception(8, returningTo: start)
                    }
                    return
                }
                let target = operand(mode, register, size)
                let value = read(target, size)
                switch upper {
                case 0:
                    let result = value | immediate
                    logic(result, size)
                    write(target, size, result)
                case 1:
                    let result = value & immediate
                    logic(result, size)
                    write(target, size, result)
                case 2: write(target, size, subtract(immediate, value, size))
                case 3: write(target, size, add(immediate, value, size))
                case 5:
                    let result = value ^ immediate
                    logic(result, size)
                    write(target, size, result)
                default: _ = subtract(immediate, value, size, comparing: true)
                }
            }

        case 0x1, 0x2, 0x3:
            // MOVE: a byte, a long, a word.
            let size: UInt32 = op >> 12 == 1 ? 0 : op >> 12 == 3 ? 1 : 2
            let value = read(operand(mode, register, size), size)
            let targetMode = (op >> 6) & 7
            if targetMode == 1 {
                registers[Int(upper) + 8] = size == 1 ? Self.extend16(value) : value
            } else {
                let target = operand(targetMode, upper, size)
                logic(value, size)
                write(target, size, value)
            }

        case 0x4:
            miscellaneous(op, start)

        case 0x5:
            if size == 3 {
                if mode == 1 {
                    // DBcc: count down and go round until the condition is true or the count runs out.
                    let base = pc
                    let displacement = Self.extend16(fetch16())
                    if !condition((op >> 8) & 15) {
                        let count = (registers[Int(register)] &- 1) & 0xFFFF
                        registers[Int(register)] = registers[Int(register)] & 0xFFFF_0000 | count
                        if count != 0xFFFF { pc = base &+ displacement }
                    }
                } else {
                    let target = operand(mode, register, 0)
                    write(target, 0, condition((op >> 8) & 15) ? 0xFF : 0)
                }
            } else {
                let quick = upper == 0 ? 8 : upper
                if mode == 1 {
                    // On an address register the whole register changes and the flags do not.
                    let a = Int(register) + 8
                    registers[a] = op & 0x100 != 0 ? registers[a] &- quick : registers[a] &+ quick
                } else {
                    let target = operand(mode, register, size)
                    let value = read(target, size)
                    write(target, size, op & 0x100 != 0 ? subtract(quick, value, size) : add(quick, value, size))
                }
            }

        case 0x6:
            let base = pc
            var displacement = Self.extend8(op)
            if op & 0xFF == 0 { displacement = Self.extend16(fetch16()) }
            let code = (op >> 8) & 15
            if code == 1 {
                push32(pc)
                pc = base &+ displacement
            } else if condition(code) {
                pc = base &+ displacement
            }

        case 0x7:
            guard op & 0x100 == 0 else {
                stop = .illegal
                return
            }
            let value = Self.extend8(op)
            registers[Int(upper)] = value
            logic(value, 2)

        case 0x8:
            let opmode = (op >> 6) & 7
            if opmode == 3 || opmode == 7 {
                divide(signed: opmode == 7, Int(upper), mode, register)
            } else if opmode == 4, mode < 2 {
                decimal(subtracting: true, mode, register, upper)
            } else {
                logical(0, opmode, Int(upper), mode, register)
            }

        case 0x9, 0xD:
            let adding = op >> 12 == 0xD
            let opmode = (op >> 6) & 7
            if opmode == 3 || opmode == 7 {
                // On an address register: the whole register, and no flags.
                let size: UInt32 = opmode == 3 ? 1 : 2
                var value = read(operand(mode, register, size), size)
                if size == 1 { value = Self.extend16(value) }
                let a = Int(upper) + 8
                registers[a] = adding ? registers[a] &+ value : registers[a] &- value
            } else if opmode >= 4, mode < 2 {
                // With X, for numbers longer than a register: register to register, or memory to memory
                // working down from the far end.
                let source = operand(mode == 0 ? 0 : 4, register, size)
                let value = read(source, size)
                let target = operand(mode == 0 ? 0 : 4, upper, size)
                let other = read(target, size)
                write(target, size, adding ? add(value, other, size, extended: true) : subtract(value, other, size, extended: true))
            } else if opmode < 3 {
                let value = read(operand(mode, register, size), size)
                let target = Operand(inMemory: false, at: upper)
                let other = read(target, size)
                write(target, size, adding ? add(value, other, size) : subtract(value, other, size))
            } else {
                let value = registers[Int(upper)]
                let target = operand(mode, register, size)
                let other = read(target, size)
                write(target, size, adding ? add(value, other, size) : subtract(value, other, size))
            }

        case 0xB:
            let opmode = (op >> 6) & 7
            if opmode == 3 || opmode == 7 {
                let size: UInt32 = opmode == 3 ? 1 : 2
                var value = read(operand(mode, register, size), size)
                if size == 1 { value = Self.extend16(value) }
                _ = subtract(value, registers[Int(upper) + 8], 2, comparing: true)
            } else if opmode < 3 {
                let value = read(operand(mode, register, size), size)
                _ = subtract(value, registers[Int(upper)], size, comparing: true)
            } else if mode == 1 {
                // CMPM: memory with memory, both moving on.
                let value = read(operand(3, register, size), size)
                let other = read(operand(3, upper, size), size)
                _ = subtract(value, other, size, comparing: true)
            } else {
                logical(2, opmode, Int(upper), mode, register)
            }

        case 0xC:
            let opmode = (op >> 6) & 7
            if opmode == 3 || opmode == 7 {
                let value = read(operand(mode, register, 1), 1)
                let other = registers[Int(upper)] & 0xFFFF
                let result = opmode == 7
                    ? UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: value)) &* Int32(Int16(truncatingIfNeeded: other)))
                    : value &* other
                registers[Int(upper)] = result
                logic(result, 2)
                cycles &+= 40
            } else if opmode == 4, mode < 2 {
                decimal(subtracting: false, mode, register, upper)
            } else if opmode == 5, mode < 2 {
                // EXG: two data registers, or two address registers.
                let first = Int(upper) + (mode == 1 ? 8 : 0), second = Int(register) + (mode == 1 ? 8 : 0)
                let held = registers[first]
                registers[first] = registers[second]
                registers[second] = held
            } else if opmode == 6, mode == 1 {
                // EXG: a data register and an address register.
                let held = registers[Int(upper)]
                registers[Int(upper)] = registers[Int(register) + 8]
                registers[Int(register) + 8] = held
            } else {
                logical(1, opmode, Int(upper), mode, register)
            }

        case 0xE:
            let left = op & 0x100 != 0
            if size == 3 {
                // In memory: a word, by one place.
                guard op & 0x800 == 0 else {
                    stop = .illegal
                    return
                }
                let target = operand(mode, register, 1)
                let value = read(target, 1)
                write(target, 1, shift(upper & 3, left: left, value, count: 1, 1))
            } else {
                let count = op & 0x20 != 0 ? registers[Int(upper)] & 63 : (upper == 0 ? 8 : upper)
                let target = Operand(inMemory: false, at: register)
                let value = read(target, size)
                write(target, size, shift(mode & 3, left: left, value, count: count, size))
            }

        default:
            // Opcodes that begin 1010 or 1111 belong to no instruction and each has an exception of its own.
            exception(op >> 12 == 0xA ? 10 : 11, returningTo: start)
        }
    }

    /// OR (0), AND (1) and EOR (2), between a data register and an operand.
    @inline(__always) private mutating func logical(_ kind: Int, _ opmode: UInt32, _ data: Int, _ mode: UInt32, _ register: UInt32) {
        let size = opmode & 3
        guard size != 3 else {
            stop = .illegal
            return
        }
        let target = opmode < 3 && kind != 2 ? Operand(inMemory: false, at: UInt32(data)) : operand(mode, register, size)
        let value = opmode < 3 && kind != 2 ? read(operand(mode, register, size), size) : registers[data] & Self.mask(size)
        let other = read(target, size)
        let result = kind == 0 ? value | other : kind == 1 ? value & other : value ^ other
        logic(result, size)
        write(target, size, result)
    }

    /// BTST (0), BCHG (1), BCLR (2) and BSET (3): one bit of a data register's 32, or of a byte of memory.
    private mutating func bit(_ kind: UInt32, number: UInt32, _ mode: UInt32, _ register: UInt32) {
        if mode == 0 {
            let mask: UInt32 = 1 << (number & 31)
            let value = registers[Int(register)]
            z = value & mask == 0
            switch kind {
            case 1: registers[Int(register)] = value ^ mask
            case 2: registers[Int(register)] = value & ~mask
            case 3: registers[Int(register)] = value | mask
            default: break
            }
        } else {
            let mask: UInt32 = 1 << (number & 7)
            let target = operand(mode, register, 0)
            let value = read(target, 0)
            z = value & mask == 0
            switch kind {
            case 1: write(target, 0, value ^ mask)
            case 2: write(target, 0, value & ~mask)
            case 3: write(target, 0, value | mask)
            default: break
            }
        }
    }

    /// MOVEP: a data register to or from every other byte of memory, for peripherals on half the bus.
    private mutating func movep(_ op: UInt32) {
        let data = Int((op >> 9) & 7)
        var address = registers[Int(op & 7) + 8] &+ Self.extend16(fetch16())
        let long = op & 0x40 != 0
        if op & 0x80 != 0 {
            let value = registers[data]
            for place in stride(from: long ? 24 : 8, through: 0, by: -8) {
                write8(address, value >> UInt32(place))
                address &+= 2
            }
        } else {
            var value: UInt32 = 0
            for _ in 0 ..< (long ? 4 : 2) {
                value = value << 8 | read8(address)
                address &+= 2
            }
            registers[data] = long ? value : registers[data] & 0xFFFF_0000 | value
        }
    }

    private mutating func divide(signed: Bool, _ data: Int, _ mode: UInt32, _ register: UInt32) {
        let divisor = read(operand(mode, register, 1), 1)
        cycles &+= 140
        guard divisor != 0 else {
            exception(5, returningTo: pc)
            return
        }
        let dividend = registers[data]
        if signed {
            let bottom = Int32(Int16(truncatingIfNeeded: divisor)), top = Int32(bitPattern: dividend)
            if dividend == 0x8000_0000, bottom == -1 {
                registers[data] = 0
                n = false; z = true; v = false; c = false
                return
            }
            let quotient = top / bottom, remainder = top % bottom
            guard quotient == Int32(Int16(truncatingIfNeeded: quotient)) else {
                v = true
                return
            }
            registers[data] = UInt32(bitPattern: remainder) << 16 | UInt32(bitPattern: quotient) & 0xFFFF
            n = quotient < 0
            z = quotient == 0
        } else {
            let quotient = dividend / divisor
            guard quotient <= 0xFFFF else {
                v = true
                return
            }
            registers[data] = (dividend % divisor) << 16 | quotient
            n = quotient & 0x8000 != 0
            z = quotient == 0
        }
        v = false
        c = false
    }

    /// ABCD and SBCD: one byte of two decimal digits, with X, register to register or memory to memory.
    private mutating func decimal(subtracting: Bool, _ mode: UInt32, _ register: UInt32, _ upper: UInt32) {
        let source = operand(mode == 0 ? 0 : 4, register, 0)
        let value = read(source, 0)
        let target = operand(mode == 0 ? 0 : 4, upper, 0)
        let other = read(target, 0)
        var result: UInt32
        var overflow: UInt32
        if subtracting {
            result = (other & 15) &- (value & 15) &- (x ? 1 : 0)
            overflow = ~result
            if result > 9 { result &-= 6 }
            result = result &+ (other & 0xF0) &- (value & 0xF0)
            c = result > 0x99
            if c { result &+= 0xA0 }
        } else {
            result = (value & 15) + (other & 15) + (x ? 1 : 0)
            overflow = ~result
            if result > 9 { result += 6 }
            result += (value & 0xF0) + (other & 0xF0)
            c = result > 0x99
            if c { result &-= 0xA0 }
        }
        x = c
        result &= 0xFF
        overflow &= result
        v = overflow & 0x80 != 0
        n = result & 0x80 != 0
        if result != 0 { z = false }
        write(target, 0, result)
    }

    /// Everything whose opcode begins with 4.
    private mutating func miscellaneous(_ op: UInt32, _ start: UInt32) {
        let mode = (op >> 3) & 7, register = op & 7
        let size = (op >> 6) & 3

        if op & 0x100 != 0 {
            let data = Int((op >> 9) & 7)
            if size == 3 {
                // LEA
                registers[data + 8] = operand(mode, register, 2).at
            } else if size == 2 {
                // CHK: a bound on a data register, and an exception if it is outside.
                let bound = Int16(truncatingIfNeeded: read(operand(mode, register, 1), 1))
                let value = Int16(truncatingIfNeeded: registers[data])
                if value < 0 || value > bound {
                    n = value < 0
                    exception(6, returningTo: pc)
                }
            } else {
                stop = .illegal
            }
            return
        }

        switch (op >> 8) & 15 {
        case 0x0:
            let target = operand(mode, register, size == 3 ? 1 : size)
            if size == 3 {
                write(target, 1, statusRegister)
            } else {
                let value = read(target, size)
                write(target, size, subtract(value, 0, size, extended: true))
            }
        case 0x2:
            guard size != 3 else {
                stop = .illegal
                return
            }
            let target = operand(mode, register, size)
            logic(0, size)
            write(target, size, 0)
        case 0x4:
            if size == 3 {
                ccr = read(operand(mode, register, 1), 1)
            } else {
                let target = operand(mode, register, size)
                let value = read(target, size)
                write(target, size, subtract(value, 0, size))
            }
        case 0x6:
            if size == 3 {
                let value = read(operand(mode, register, 1), 1)
                if supervisor { setStatusRegister(value) } else { exception(8, returningTo: start) }
            } else {
                let target = operand(mode, register, size)
                let result = ~read(target, size) & Self.mask(size)
                logic(result, size)
                write(target, size, result)
            }
        case 0x8:
            switch size {
            case 0:
                // NBCD: a decimal byte taken from nothing.
                let target = operand(mode, register, 0)
                let value = read(target, 0)
                var result = (0x9A &- value &- (x ? 1 : 0)) & 0xFF
                if result != 0x9A {
                    var overflow = ~result
                    if result & 15 == 10 { result = (result & 0xF0) &+ 0x10 }
                    result &= 0xFF
                    overflow &= result
                    v = overflow & 0x80 != 0
                    write(target, 0, result)
                    if result != 0 { z = false }
                    c = true
                } else {
                    v = false
                    c = false
                }
                x = c
                n = result & 0x80 != 0
            case 1:
                if mode == 0 {
                    // SWAP: the two halves of a data register.
                    let value = registers[Int(register)]
                    let result = value << 16 | value >> 16
                    registers[Int(register)] = result
                    logic(result, 2)
                } else {
                    // PEA
                    let address = operand(mode, register, 2).at
                    push32(address)
                }
            default:
                if mode == 0 {
                    // EXT: a byte to a word, or a word to a long.
                    let value = registers[Int(register)]
                    if size == 2 {
                        let result = Self.extend8(value) & 0xFFFF
                        registers[Int(register)] = value & 0xFFFF_0000 | result
                        logic(result, 1)
                    } else {
                        let result = Self.extend16(value)
                        registers[Int(register)] = result
                        logic(result, 2)
                    }
                } else {
                    moveMultiple(toMemory: true, long: size == 3, mode, register)
                }
            }
        case 0xA:
            if size == 3 {
                guard op != 0x4AFC else {
                    stop = .illegal
                    return
                }
                // TAS: test a byte and set its top bit.
                let target = operand(mode, register, 0)
                let value = read(target, 0)
                logic(value, 0)
                write(target, 0, value | 0x80)
            } else {
                logic(read(operand(mode, register, size), size), size)
            }
        case 0xC:
            guard size >= 2 else {
                stop = .illegal
                return
            }
            moveMultiple(toMemory: false, long: size == 3, mode, register)
        case 0xE:
            switch size {
            case 1:
                switch mode {
                case 0, 1:
                    stop = .trap(Int(op & 15))
                case 2:
                    // LINK: a frame on the stack, with the address register pointing at it.
                    let a = Int(register) + 8
                    if a == 15 {
                        registers[15] &-= 4
                        write32(registers[15], registers[15])
                    } else {
                        push32(registers[a])
                        registers[a] = registers[15]
                    }
                    registers[15] &+= Self.extend16(fetch16())
                case 3:
                    // UNLK
                    let a = Int(register) + 8
                    registers[15] = registers[a]
                    registers[a] = pop32()
                case 4, 5:
                    guard supervisor else {
                        exception(8, returningTo: start)
                        return
                    }
                    if mode == 4 { otherStack = registers[Int(register) + 8] } else { registers[Int(register) + 8] = otherStack }
                case 6:
                    switch register {
                    case 0: stop = .reset
                    case 1: break
                    case 2:
                        guard supervisor else {
                            exception(8, returningTo: start)
                            return
                        }
                        setStatusRegister(fetch16())
                        stop = .stopped
                    case 3:
                        guard supervisor else {
                            exception(8, returningTo: start)
                            return
                        }
                        let status = pop16()
                        let address = pop32()
                        setStatusRegister(status)
                        pc = address
                    case 5:
                        pc = pop32()
                    case 6:
                        if v { exception(7, returningTo: pc) }
                    case 7:
                        ccr = pop16()
                        pc = pop32()
                    default:
                        stop = .illegal
                    }
                default:
                    stop = .illegal
                }
            case 2:
                // JSR
                let address = operand(mode, register, 2).at
                push32(pc)
                pc = address
            case 3:
                // JMP
                pc = operand(mode, register, 2).at
            default:
                stop = .illegal
            }
        default:
            stop = .illegal
        }
    }

    /// MOVEM: the registers a mask picks out, to memory or back. Words come back sign-extended.
    private mutating func moveMultiple(toMemory: Bool, long: Bool, _ mode: UInt32, _ register: UInt32) {
        let mask = fetch16()
        let step: UInt32 = long ? 4 : 2
        let a = Int(register) + 8
        if toMemory {
            if mode == 4 {
                // Downwards, and then the mask is the other way round: A7 first.
                var address = registers[a]
                for place in 0 ..< 16 where mask & (1 << UInt32(place)) != 0 {
                    address &-= step
                    if long { write32(address, registers[15 - place]) } else { write16(address, registers[15 - place]) }
                }
                registers[a] = address
            } else {
                var address = operand(mode, register, 2).at
                for place in 0 ..< 16 where mask & (1 << UInt32(place)) != 0 {
                    if long { write32(address, registers[place]) } else { write16(address, registers[place]) }
                    address &+= step
                }
            }
        } else {
            var address = mode == 3 ? registers[a] : operand(mode, register, 2).at
            for place in 0 ..< 16 where mask & (1 << UInt32(place)) != 0 {
                registers[place] = long ? read32(address) : Self.extend16(read16(address))
                address &+= step
            }
            if mode == 3 { registers[a] = address }
        }
    }
}
