// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Motorola 68000, written against the processor's documented behaviour (the M68000 Family
// Programmer's Reference Manual). It is what the player of an Atari ST's or an Amiga's tune needs and
// no more: every instruction of the 68000 does what it should to registers, memory and flags, but
// nothing here keeps the processor's bus timing. Time is counted roughly, four cycles for each word
// that crosses the bus, which is close to the truth for a processor that does little else (and is how
// UADE's UAE counts it, two of Paula's clocks to a word), and is used to give up on a program that
// never comes back, and on the Amiga to place in time what a program writes to the hardware (see
// `AmigaChips`).
//
// There are no address errors and no instruction prefetch, and the flags the manual leaves undefined
// after decimal arithmetic follow Musashi's, the core the reference player uses.
//
// It is built to run quickly. Each of the 65,536 opcodes is worked out once, for every processor, to the
// step that runs it (`M68000Step`), so that an instruction is one look in a table rather than a chain of
// questions about its bits; and for the instructions a tune's code runs most, there is a step made for
// each of their addressing modes (and sizes, conditions and kinds), which does that one's work and no
// other's. The steps are functions of their own, made by Scripts/m68000-steps.swift into
// M68000Steps.swift, and each is given what changes at nearly every step (the program counter, the
// count of cycles and the condition codes, `M68000Pace`) and gives it back, a value the compiler keeps
// in the host's registers rather than in memory, where each instruction would wait for the last's.

/// What a 68000 is connected to beyond its RAM: the hardware registers, which a machine's hardware
/// gives by overriding these. Addresses are 24 bits. As it is, a bus with nothing on it.
///
/// (A class rather than a protocol: the processor is not generic over its bus (see `M68000`), and
/// reaching a class's override costs one indirect call, where reaching a protocol's witness through an
/// existential first asks the runtime for the object's type.)
class M68000Bus {
    func read8(_: UInt32) -> UInt8 { 0xFF }
    func read16(_: UInt32) -> UInt16 { 0xFFFF }
    func write8(_: UInt32, _: UInt8) {}
    func write16(_: UInt32, _: UInt16) {}

    /// The same, told when: `cycles` is the processor's count of its cycles since it was last set
    /// running (`M68000.cycles`), this access's included. For hardware that keeps time with the
    /// processor, as the Amiga's does (see `AmigaChips`). A bus that does not leaves them to the four
    /// above.
    func read8(_ address: UInt32, at _: Int) -> UInt8 { read8(address) }
    func read16(_ address: UInt32, at _: Int) -> UInt16 { read16(address) }
    func write8(_ address: UInt32, _ value: UInt8, at _: Int) { write8(address, value) }
    func write16(_ address: UInt32, _ value: UInt16, at _: Int) { write16(address, value) }

    /// True when what the processor has just done may have asked for an interrupt (for hardware that
    /// interrupts it, as the Amiga's does): the processor stops after the instruction, for its host to
    /// look. A bus that never interrupts leaves it false. It can only become true when the processor
    /// reaches the bus.
    var asksToBeLookedAt: Bool { false }
}

/// Why the processor stopped running.
enum M68000Stop: Equatable, Sendable {
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

/// What the processor changes at nearly every step. While it runs (`M68000.resume`) this is a value of
/// the run's own, three words that go from one instruction's step to the next in the host's registers;
/// between runs it is kept in the processor.
struct M68000Pace {
    var pc: UInt32 = 0
    /// The condition codes, X N Z V C from bit 4 down as the status register has them, and above them
    /// two of the run's own: that the processor has reached the bus, and that it is to stop. (A word of
    /// its own, rather than half of one shared with `pc`, which would cost a shift and a mask at each step.)
    var flags: UInt = 0
    /// Cycles used since `run` was last called.
    var cycles = 0

    static let reachedBusFlag: UInt = 0x100
    static let haltedFlag: UInt = 0x200

    @inline(__always) private mutating func set(_ bit: UInt, _ on: Bool) {
        flags = on ? flags | bit : flags & ~bit
    }

    /// Sets all five condition codes at once.
    @inline(__always) mutating func setConditions(x: Bool, n: Bool, z: Bool, v: Bool, c: Bool) {
        flags = flags & ~0x1F | (x ? 16 : 0) | (n ? 8 : 0) | (z ? 4 : 0) | (v ? 2 : 0) | (c ? 1 : 0)
    }

    /// Sets the four that are not X.
    @inline(__always) mutating func setConditions(n: Bool, z: Bool, v: Bool, c: Bool) {
        flags = flags & ~0xF | (n ? 8 : 0) | (z ? 4 : 0) | (v ? 2 : 0) | (c ? 1 : 0)
    }

    var x: Bool {
        @inline(__always) get { flags & 16 != 0 }
        @inline(__always) set { set(16, newValue) }
    }

    var n: Bool {
        @inline(__always) get { flags & 8 != 0 }
        @inline(__always) set { set(8, newValue) }
    }

    var z: Bool {
        @inline(__always) get { flags & 4 != 0 }
        @inline(__always) set { set(4, newValue) }
    }

    var v: Bool {
        @inline(__always) get { flags & 2 != 0 }
        @inline(__always) set { set(2, newValue) }
    }

    var c: Bool {
        @inline(__always) get { flags & 1 != 0 }
        @inline(__always) set { set(1, newValue) }
    }

    /// True once the processor has reached past its RAM to the bus, which may then ask to be looked at.
    var reachedBus: Bool {
        @inline(__always) get { flags & Self.reachedBusFlag != 0 }
        @inline(__always) set { set(Self.reachedBusFlag, newValue) }
    }

    /// True once the processor is to stop (and why is `M68000.stop`).
    var halted: Bool {
        @inline(__always) get { flags & Self.haltedFlag != 0 }
        @inline(__always) set { set(Self.haltedFlag, newValue) }
    }

    var ccr: UInt32 {
        @inline(__always) get { UInt32(truncatingIfNeeded: flags & 0x1F) }
        @inline(__always) set { flags = flags & ~0x1F | UInt(newValue & 0x1F) }
    }
}

// (Not generic over its bus: a generic processor's every step would be made again for each machine, and
// in the web player's Embedded Swift written whole into SidayKit's module for its users to specialise,
// which made the module too big for the compiler to read back. The bus is reached only for the hardware,
// and an indirect call to it is little beside what the hardware then does.)
struct M68000: ~Copyable {
    /// D0 to D7, then A0 to A7. A7 is the stack pointer of the mode the processor is in.
    var registers = InlineArray<16, UInt32>(repeating: 0)
    private var pace: M68000Pace
    private var supervisor = true
    private var trace = false
    private var interruptMask: UInt32 = 7
    /// The stack pointer that is not in use: the user's in supervisor mode, the supervisor's in user mode.
    private var otherStack: UInt32 = 0
    private let ram: UnsafeMutablePointer<UInt8>
    private let ramSize: UInt32
    private let bus: M68000Bus
    /// Why the processor stopped, once it has.
    private var stop: M68000Stop?

    var pc: UInt32 {
        get { pace.pc }
        set { pace.pc = newValue }
    }

    /// Cycles used since `run` was last called.
    var cycles: Int { pace.cycles }

    /// - Parameter ram: the memory at address 0, `ramSize` bytes of it. Everything above is the bus's.
    init(ram: UnsafeMutablePointer<UInt8>, ramSize: Int, bus: M68000Bus) {
        pace = M68000Pace()
        self.ram = ram
        self.ramSize = UInt32(ramSize)
        self.bus = bus
    }

    // MARK: Memory

    // (Each is given the pace of the run it is part of. Those without one, for the processor's host
    // while it is not running, use the processor's own.)

    @inline(__always) private mutating func read8(_ address: UInt32, _ k: inout M68000Pace) -> UInt32 {
        k.cycles &+= 4
        let a = address & 0xFF_FFFF
        if a < ramSize { return UInt32(ram[Int(a)]) }
        k.reachedBus = true
        return UInt32(bus.read8(a, at: k.cycles))
    }

    @inline(__always) private mutating func read16(_ address: UInt32, _ k: inout M68000Pace) -> UInt32 {
        k.cycles &+= 4
        let a = address & 0xFF_FFFF
        if a < ramSize &- 1 { return UInt32(UInt16(bigEndian: UnsafeRawPointer(ram + Int(a)).loadUnaligned(as: UInt16.self))) }
        k.reachedBus = true
        return UInt32(bus.read16(a, at: k.cycles))
    }

    @inline(__always) private mutating func read32(_ address: UInt32, _ k: inout M68000Pace) -> UInt32 {
        let high = read16(address, &k)
        return high << 16 | read16(address &+ 2, &k)
    }

    @inline(__always) private mutating func write8(_ address: UInt32, _ value: UInt32, _ k: inout M68000Pace) {
        k.cycles &+= 4
        let a = address & 0xFF_FFFF
        if a < ramSize {
            ram[Int(a)] = UInt8(truncatingIfNeeded: value)
        } else {
            k.reachedBus = true
            bus.write8(a, UInt8(truncatingIfNeeded: value), at: k.cycles)
        }
    }

    @inline(__always) private mutating func write16(_ address: UInt32, _ value: UInt32, _ k: inout M68000Pace) {
        k.cycles &+= 4
        let a = address & 0xFF_FFFF
        if a < ramSize &- 1 {
            UnsafeMutableRawPointer(ram + Int(a)).storeBytes(of: UInt16(truncatingIfNeeded: value).bigEndian, as: UInt16.self)
        } else {
            k.reachedBus = true
            bus.write16(a, UInt16(truncatingIfNeeded: value), at: k.cycles)
        }
    }

    @inline(__always) private mutating func write32(_ address: UInt32, _ value: UInt32, _ k: inout M68000Pace) {
        write16(address, value >> 16, &k)
        write16(address &+ 2, value, &k)
    }

    mutating func read8(_ address: UInt32) -> UInt32 {
        var k = pace
        defer { pace = k }
        return read8(address, &k)
    }

    mutating func read16(_ address: UInt32) -> UInt32 {
        var k = pace
        defer { pace = k }
        return read16(address, &k)
    }

    mutating func read32(_ address: UInt32) -> UInt32 {
        var k = pace
        defer { pace = k }
        return read32(address, &k)
    }

    mutating func write8(_ address: UInt32, _ value: UInt32) {
        var k = pace
        write8(address, value, &k)
        pace = k
    }

    mutating func write16(_ address: UInt32, _ value: UInt32) {
        var k = pace
        write16(address, value, &k)
        pace = k
    }

    mutating func write32(_ address: UInt32, _ value: UInt32) {
        var k = pace
        write32(address, value, &k)
        pace = k
    }

    @inline(__always) private mutating func fetch16(_ k: inout M68000Pace) -> UInt32 {
        let at = k.pc
        let value = read16(at, &k)
        k.pc &+= 2
        return value
    }

    @inline(__always) private mutating func fetch32(_ k: inout M68000Pace) -> UInt32 {
        let high = fetch16(&k)
        return high << 16 | fetch16(&k)
    }

    @inline(__always) private mutating func push32(_ value: UInt32, _ k: inout M68000Pace) {
        registers[15] &-= 4
        write32(registers[15], value, &k)
    }

    @inline(__always) private mutating func push16(_ value: UInt32, _ k: inout M68000Pace) {
        registers[15] &-= 2
        write16(registers[15], value, &k)
    }

    @inline(__always) private mutating func pop32(_ k: inout M68000Pace) -> UInt32 {
        let value = read32(registers[15], &k)
        registers[15] &+= 4
        return value
    }

    @inline(__always) private mutating func pop16(_ k: inout M68000Pace) -> UInt32 {
        let value = read16(registers[15], &k)
        registers[15] &+= 2
        return value
    }

    // MARK: Status

    // (Those that read the registers are mutating, though some change nothing: a read of a register
    // from a processor that is only borrowed copies all of them first.)

    @inline(__always) private mutating func statusRegister(_ k: M68000Pace) -> UInt32 {
        (trace ? 0x8000 : 0) | (supervisor ? 0x2000 : 0) | interruptMask << 8 | k.ccr
    }

    var statusRegister: UInt32 { (trace ? 0x8000 : 0) | (supervisor ? 0x2000 : 0) | interruptMask << 8 | pace.ccr }

    @inline(__always) private mutating func setSupervisor(_ on: Bool) {
        guard on != supervisor else { return }
        let other = otherStack
        otherStack = registers[15]
        registers[15] = other
        supervisor = on
    }

    @inline(__always) private mutating func setStatusRegister(_ value: UInt32, _ k: inout M68000Pace) {
        setSupervisor(value & 0x2000 != 0)
        trace = value & 0x8000 != 0
        interruptMask = (value >> 8) & 7
        k.ccr = value
    }

    /// Has the processor stop after this instruction, for `why`.
    @inline(__always) private mutating func halt(_ why: M68000Stop, _ k: inout M68000Pace) {
        stop = why
        k.halted = true
    }

    /// Takes an exception: the status and the place to come back to go on the supervisor's stack.
    private mutating func exception(_ vector: UInt32, returningTo address: UInt32, _ k: inout M68000Pace) {
        let status = statusRegister(k)
        setSupervisor(true)
        trace = false
        push32(address, &k)
        push16(status, &k)
        k.pc = read32(vector &* 4, &k)
    }

    // MARK: Running

    /// Puts the processor as it is when the power comes on: every register empty. (The zero flag is
    /// set, which is how the reference player's processor starts, and a tune can tell.)
    mutating func powerOn() {
        registers = InlineArray(repeating: 0)
        otherStack = 0
        pace.pc = 0
        supervisor = true
        trace = false
        interruptMask = 7
        pace.ccr = 4
    }

    /// Starts as the processor does when it is reset: supervisor mode, interrupts masked, the stack
    /// pointer from address 0 and the program counter from address 4. The other registers are left alone.
    mutating func reset() {
        setSupervisor(true)
        trace = false
        interruptMask = 7
        var k = pace
        registers[15] = read32(0, &k)
        k.pc = read32(4, &k)
        pace = k
    }

    /// Runs until something stops it, or until `budget` cycles have been used in this call.
    mutating func run(cycles budget: Int) -> M68000Stop {
        pace.cycles = 0
        return resume(cycles: budget)
    }

    /// Goes on after a stop, with what is left of `budget` since `run` was called.
    @export(interface) mutating func resume(cycles budget: Int) -> M68000Stop {
        let steps = M68000Step.table
        stop = nil
        var k = pace
        // (Whether the bus asks to be looked at is asked after the first instruction, for what it may
        // have come to before the processor was set going, and then after each that reaches it.)
        k.reachedBus = true
        while k.cycles < budget {
            let start = k.pc
            let op = fetch16(&k)
            let step = steps[Int(op)]
            k = run(step, op, start, k)
            if k.flags & (M68000Pace.reachedBusFlag | M68000Pace.haltedFlag) != 0 {
                if k.halted {
                    k.halted = false
                    pace = k
                    return stop ?? .outOfTime
                }
                k.reachedBus = false
                if bus.asksToBeLookedAt {
                    pace = k
                    return .outOfTime
                }
            }
        }
        pace = k
        return .outOfTime
    }

    /// Runs the one instruction at the program counter, by the step that works out its modes as it runs
    /// if `general`, or else as `resume` runs it: for the tests, which see that the two agree.
    @export(interface) mutating func runOne(general: Bool) -> M68000Stop {
        stop = nil
        var k = pace
        let start = k.pc
        let op = fetch16(&k)
        k = run(general ? M68000Step.general(op) : M68000Step.table[Int(op)], op, start, k)
        let halted = k.halted
        k.halted = false
        k.reachedBus = false
        pace = k
        return halted ? stop ?? .outOfTime : .outOfTime
    }

    /// Takes the exception of the TRAP the processor has just stopped at, for a trap nobody answers.
    mutating func takeTrap(_ number: Int) {
        var k = pace
        exception(32 &+ UInt32(number), returningTo: k.pc, &k)
        pace = k
    }

    // MARK: For a machine whose hardware interrupts the processor

    // (The Amiga's, `AmigaMachine`, whose host runs the program and its interrupts as the hardware asks
    // for them. Nothing else here uses these, and nothing they do happens unless they are called.)

    /// Takes an interrupt that the hardware asks for at `level` (1 to 7), as the 68000 does between two
    /// instructions, if its mask lets that level through (level 7 always goes through): the status and
    /// the place to come back to go on the supervisor's stack, the mask is raised to the level, and it
    /// goes on from the level's autovector. It takes the 68000's 44 cycles. True if it was taken.
    mutating func interrupt(level: Int) -> Bool {
        guard level >= 1, level <= 7, UInt32(level) > interruptMask || level == 7 else { return false }
        var k = pace
        let used = k.cycles
        exception(24 &+ UInt32(level), returningTo: k.pc, &k)
        interruptMask = UInt32(level)
        k.cycles = used &+ 44
        pace = k
        return true
    }

    /// Counts cycles that pass with the processor doing nothing, as it waits after a STOP.
    mutating func wait(cycles more: Int) {
        pace.cycles &+= max(0, more)
    }

    /// Whether MULU and MULS take as long as the 68000's do, by their source's bits (as UADE's processor
    /// has them), rather than a time of their own. Off unless asked for.
    var timesMultiplies = false

    /// The level below which the processor lets no interrupt through.
    var interruptLevel: Int { Int(interruptMask) }

    /// Sets the whole status register, as MOVE to SR does (the stack pointer swapped with the mode).
    mutating func setStatus(_ value: UInt32) {
        var k = pace
        setStatusRegister(value, &k)
        pace = k
    }

    /// The user's stack pointer, whichever mode the processor is in.
    var userStack: UInt32 {
        get { supervisor ? otherStack : registers[15] }
        set {
            if supervisor { otherStack = newValue } else { registers[15] = newValue }
        }
    }

    // MARK: Operands

    /// Where an operand is: a register, by its place in `registers`, or an address in memory.
    struct Operand {
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
    @inline(__always) private mutating func indexed(_ base: UInt32, _ k: inout M68000Pace) -> UInt32 {
        let word = fetch16(&k)
        var index = registers[Int(word >> 12)]
        if word & 0x800 == 0 { index = Self.extend16(index) }
        return base &+ index &+ Self.extend8(word)
    }

    /// Works out where the operand of an addressing mode is, reading any extension words and moving
    /// the address register of a postincrement or predecrement mode. `size` is 0, 1 or 2 for a byte,
    /// a word or a long. The mode is given by a number of its own: 0 to 6 the modes of those numbers,
    /// with `register`, and 7 to 11 mode 7's five, which its register tells apart (absolute word,
    /// absolute long, relative to the program counter, the same with an index, and immediate).
    @inline(__always) mutating func locate(_ mode: UInt32, _ register: UInt32, _ size: UInt32, _ k: inout M68000Pace) -> Operand {
        let a = Int(register & 7) + 8
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
            return Operand(inMemory: true, at: registers[a] &+ Self.extend16(fetch16(&k)))
        case 6:
            return Operand(inMemory: true, at: indexed(registers[a], &k))
        case 7: return Operand(inMemory: true, at: Self.extend16(fetch16(&k)))
        case 8: return Operand(inMemory: true, at: fetch32(&k))
        case 9:
            let base = k.pc
            return Operand(inMemory: true, at: base &+ Self.extend16(fetch16(&k)))
        case 10:
            let base = k.pc
            return Operand(inMemory: true, at: indexed(base, &k))
        case 11:
            // The value follows the instruction. A byte is the low half of a word.
            let address = k.pc
            k.pc &+= size == 2 ? 4 : 2
            return Operand(inMemory: true, at: size == 0 ? address &+ 1 : address)
        default:
            halt(.illegal, &k)
            return Operand(inMemory: true, at: 0)
        }
    }

    /// The same, by the mode and register as an opcode gives them.
    @inline(__always) private mutating func operand(_ mode: UInt32, _ register: UInt32, _ size: UInt32, _ k: inout M68000Pace) -> Operand {
        locate(M68000Step.mode(mode, register), register, size, &k)
    }

    @inline(__always) private mutating func read(_ operand: Operand, _ size: UInt32, _ k: inout M68000Pace) -> UInt32 {
        guard operand.inMemory else { return registers[Int(operand.at)] & Self.mask(size) }
        return size == 0 ? read8(operand.at, &k) : size == 1 ? read16(operand.at, &k) : read32(operand.at, &k)
    }

    @inline(__always) private mutating func write(_ operand: Operand, _ size: UInt32, _ value: UInt32, _ k: inout M68000Pace) {
        if operand.inMemory {
            if size == 0 { write8(operand.at, value, &k) } else if size == 1 { write16(operand.at, value, &k) } else { write32(operand.at, value, &k) }
        } else {
            let mask = Self.mask(size)
            registers[Int(operand.at)] = registers[Int(operand.at)] & ~mask | value & mask
        }
    }

    // MARK: Arithmetic

    /// Adds, setting the flags. With `extended`, X is added in and Z is only ever cleared, so that it
    /// tells of the whole of a number added a part at a time.
    @inline(__always) private func add(_ source: UInt32, _ destination: UInt32, _ size: UInt32, extended: Bool = false, _ k: inout M68000Pace) -> UInt32 {
        let mask = Self.mask(size), sign = Self.sign(size)
        let wide = UInt64(source & mask) &+ UInt64(destination & mask) &+ (extended && k.x ? 1 : 0)
        let result = UInt32(truncatingIfNeeded: wide) & mask
        let carry = wide > UInt64(mask)
        k.setConditions(x: carry, n: result & sign != 0, z: extended ? k.z && result == 0 : result == 0,
                        v: (source ^ result) & (destination ^ result) & sign != 0, c: carry)
        return result
    }

    /// Subtracts `source` from `destination`, setting the flags; a comparison leaves X as it was.
    @inline(__always) private func subtract(_ source: UInt32, _ destination: UInt32, _ size: UInt32, extended: Bool = false, comparing: Bool = false, _ k: inout M68000Pace) -> UInt32 {
        let mask = Self.mask(size), sign = Self.sign(size)
        let borrow: UInt64 = extended && k.x ? 1 : 0
        let result = UInt32(truncatingIfNeeded: UInt64(destination & mask) &- UInt64(source & mask) &- borrow) & mask
        let carry = UInt64(source & mask) &+ borrow > UInt64(destination & mask)
        let n = result & sign != 0, z = extended ? k.z && result == 0 : result == 0
        let v = (source ^ destination) & (result ^ destination) & sign != 0
        if comparing {
            k.setConditions(n: n, z: z, v: v, c: carry)
        } else {
            k.setConditions(x: carry, n: n, z: z, v: v, c: carry)
        }
        return result
    }

    /// The flags after a move or a logical operation.
    @inline(__always) private func logic(_ result: UInt32, _ size: UInt32, _ k: inout M68000Pace) {
        k.setConditions(n: result & Self.sign(size) != 0, z: result & Self.mask(size) == 0, v: false, c: false)
    }

    @inline(__always) private func condition(_ code: UInt32, _ k: M68000Pace) -> Bool {
        switch code {
        case 0: true
        case 1: false
        case 2: !k.c && !k.z
        case 3: k.c || k.z
        case 4: !k.c
        case 5: k.c
        case 6: !k.z
        case 7: k.z
        case 8: !k.v
        case 9: k.v
        case 10: !k.n
        case 11: k.n
        case 12: k.n == k.v
        case 13: k.n != k.v
        case 14: !k.z && k.n == k.v
        default: k.z || k.n != k.v
        }
    }

    /// Shifts and rotates, a bit at a time. `kind` is 0 arithmetic, 1 logical, 2 rotate through X, 3 rotate.
    @inline(__always) private func shift(_ kind: UInt32, left: Bool, _ value: UInt32, count: UInt32, _ size: UInt32, _ k: inout M68000Pace) -> UInt32 {
        let mask = Self.mask(size), sign = Self.sign(size)
        var value = value & mask
        var x = k.x, v = false, c = false
        k.cycles &+= Int(count) &* 2
        var toLeft = left ? count : 0, toRight = left ? 0 : count
        while toLeft > 0 {
            toLeft -= 1
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
        }
        while toRight > 0 {
            toRight -= 1
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
        if kind == 2, count == 0 { c = x }
        k.setConditions(x: x, n: value & sign != 0, z: value == 0, v: v, c: c)
        return value
    }

    // MARK: Instructions

    // (Each instruction's work, for the steps that run it to call (`M68000Steps.swift`). An operand's
    // addressing mode is given by its number (`locate`): worked out from the opcode, in a step that runs
    // every mode, or a constant, in a step made for one, which the compiler then holds to that mode
    // alone. The same goes for a size, a condition and a kind of operation.)

    /// The number a quick instruction carries in its opcode, 1 to 8.
    @inline(__always) private static func quick(_ op: UInt32) -> UInt32 {
        let upper = (op >> 9) & 7
        return upper == 0 ? 8 : upper
    }

    /// ORI (0), ANDI (1), SUBI (2), ADDI (3), EORI (5) and CMPI (6) to an operand: not to the condition
    /// codes or the status register, which are `immediateToStatus`.
    @inline(__always) mutating func immediate(_ op: UInt32, _ kind: UInt32, _ size: UInt32, to mode: UInt32, _ k: inout M68000Pace) {
        let immediate = size == 0 ? fetch16(&k) & 0xFF : size == 1 ? fetch16(&k) : fetch32(&k)
        let target = locate(mode, op & 7, size, &k)
        let value = read(target, size, &k)
        switch kind {
        case 0:
            let result = value | immediate
            logic(result, size, &k)
            write(target, size, result, &k)
        case 1:
            let result = value & immediate
            logic(result, size, &k)
            write(target, size, result, &k)
        case 2: write(target, size, subtract(immediate, value, size, &k), &k)
        case 3: write(target, size, add(immediate, value, size, &k), &k)
        case 5:
            let result = value ^ immediate
            logic(result, size, &k)
            write(target, size, result, &k)
        default: _ = subtract(immediate, value, size, comparing: true, &k)
        }
    }

    /// MOVE: a byte, a word or a long, from one operand to another.
    @inline(__always) mutating func move(_ op: UInt32, _ size: UInt32, from: UInt32, to: UInt32, _ k: inout M68000Pace) {
        let source = locate(from, op & 7, size, &k)
        let value = read(source, size, &k)
        let target = locate(to, (op >> 9) & 7, size, &k)
        logic(value, size, &k)
        write(target, size, value, &k)
    }

    /// MOVEA: to the whole of an address register, a word sign-extended, and no flags.
    @inline(__always) mutating func moveAddress(_ op: UInt32, _ size: UInt32, from: UInt32, _ k: inout M68000Pace) {
        let source = locate(from, op & 7, size, &k)
        let value = read(source, size, &k)
        registers[Int((op >> 9) & 7) + 8] = size == 1 ? Self.extend16(value) : value
    }

    /// MOVEQ: a byte in the opcode, sign-extended, to a whole data register.
    @inline(__always) mutating func moveQuick(_ op: UInt32, _ k: inout M68000Pace) {
        let value = Self.extend8(op)
        registers[Int((op >> 9) & 7)] = value
        logic(value, 2, &k)
    }

    /// LEA: an operand's address to an address register.
    @inline(__always) mutating func loadAddress(_ op: UInt32, from: UInt32, _ k: inout M68000Pace) {
        registers[Int((op >> 9) & 7) + 8] = locate(from, op & 7, 2, &k).at
    }

    /// PEA: an operand's address to the stack.
    @inline(__always) mutating func pushAddress(_ op: UInt32, from: UInt32, _ k: inout M68000Pace) {
        let address = locate(from, op & 7, 2, &k).at
        push32(address, &k)
    }

    @inline(__always) mutating func clear(_ op: UInt32, _ size: UInt32, to: UInt32, _ k: inout M68000Pace) {
        let target = locate(to, op & 7, size, &k)
        logic(0, size, &k)
        write(target, size, 0, &k)
    }

    @inline(__always) mutating func test(_ op: UInt32, _ size: UInt32, from: UInt32, _ k: inout M68000Pace) {
        let source = locate(from, op & 7, size, &k)
        logic(read(source, size, &k), size, &k)
    }

    /// NEG: an operand taken from nothing.
    @inline(__always) mutating func negate(_ op: UInt32, _ size: UInt32, to: UInt32, _ k: inout M68000Pace) {
        let target = locate(to, op & 7, size, &k)
        let value = read(target, size, &k)
        write(target, size, subtract(value, 0, size, &k), &k)
    }

    /// NOT: every bit of an operand the other way.
    @inline(__always) mutating func complement(_ op: UInt32, _ size: UInt32, to: UInt32, _ k: inout M68000Pace) {
        let target = locate(to, op & 7, size, &k)
        let result = ~read(target, size, &k) & Self.mask(size)
        logic(result, size, &k)
        write(target, size, result, &k)
    }

    /// SWAP: the two halves of a data register.
    @inline(__always) mutating func swapHalves(_ op: UInt32, _ k: inout M68000Pace) {
        let r = Int(op & 7)
        let value = registers[r]
        let result = value << 16 | value >> 16
        registers[r] = result
        logic(result, 2, &k)
    }

    /// EXT: a byte to a word, or a word to a long.
    @inline(__always) mutating func extend(_ op: UInt32, long: Bool, _ k: inout M68000Pace) {
        let r = Int(op & 7)
        let value = registers[r]
        if long {
            let result = Self.extend16(value)
            registers[r] = result
            logic(result, 2, &k)
        } else {
            let result = Self.extend8(value) & 0xFFFF
            registers[r] = value & 0xFFFF_0000 | result
            logic(result, 1, &k)
        }
    }

    @inline(__always) mutating func returnFromSubroutine(_ k: inout M68000Pace) {
        k.pc = pop32(&k)
    }

    /// RTE, which only the supervisor may run.
    @inline(__always) mutating func returnFromException(_ op: UInt32, _ start: UInt32, _ k: inout M68000Pace) {
        if supervisor {
            let status = pop16(&k)
            let address = pop32(&k)
            setStatusRegister(status, &k)
            k.pc = address
        } else {
            k = seldom(.rte, op, start, k)
        }
    }

    @inline(__always) mutating func jumpToSubroutine(_ op: UInt32, from: UInt32, _ k: inout M68000Pace) {
        let address = locate(from, op & 7, 2, &k).at
        push32(k.pc, &k)
        k.pc = address
    }

    @inline(__always) mutating func jump(_ op: UInt32, from: UInt32, _ k: inout M68000Pace) {
        k.pc = locate(from, op & 7, 2, &k).at
    }

    /// ADDQ and SUBQ to an address register: the whole register changes and the flags do not.
    @inline(__always) mutating func quickAddress(_ op: UInt32, subtracting: Bool, _ k: inout M68000Pace) {
        let a = Int(op & 7) + 8
        registers[a] = subtracting ? registers[a] &- Self.quick(op) : registers[a] &+ Self.quick(op)
    }

    /// ADDQ and SUBQ to an operand that is not an address register.
    @inline(__always) mutating func quick(_ op: UInt32, _ size: UInt32, subtracting: Bool, to: UInt32, _ k: inout M68000Pace) {
        let target = locate(to, op & 7, size, &k)
        let value = read(target, size, &k)
        let quick = Self.quick(op)
        write(target, size, subtracting ? subtract(quick, value, size, &k) : add(quick, value, size, &k), &k)
    }

    /// DBcc: count down and go round until the condition is true or the count runs out.
    @inline(__always) mutating func decrementAndBranch(_ op: UInt32, _ code: UInt32, _ k: inout M68000Pace) {
        let base = k.pc
        let displacement = Self.extend16(fetch16(&k))
        guard !condition(code, k) else { return }
        let r = Int(op & 7)
        let count = (registers[r] &- 1) & 0xFFFF
        registers[r] = registers[r] & 0xFFFF_0000 | count
        if count != 0xFFFF { k.pc = base &+ displacement }
    }

    /// Scc: a byte of ones if the condition is true, of noughts if not.
    @inline(__always) mutating func set(_ op: UInt32, _ code: UInt32, to: UInt32, _ k: inout M68000Pace) {
        let target = locate(to, op & 7, 0, &k)
        write(target, 0, condition(code, k) ? 0xFF : 0, &k)
    }

    /// Bcc, BRA and BSR (`code` 1), by an 8-bit displacement in the opcode or, if that is nought, a
    /// 16-bit one after it.
    @inline(__always) mutating func branch(_ op: UInt32, _ code: UInt32, _ k: inout M68000Pace) {
        let base = k.pc
        var displacement = Self.extend8(op)
        if op & 0xFF == 0 { displacement = Self.extend16(fetch16(&k)) }
        if code == 1 {
            push32(k.pc, &k)
            k.pc = base &+ displacement
        } else if condition(code, k) {
            k.pc = base &+ displacement
        }
    }

    enum Combination { case or, and, eor, add, subtract }

    /// OR, AND, EOR, ADD and SUB between a data register and an operand: into the register, or into
    /// the operand.
    @inline(__always) mutating func combine(_ op: UInt32, _ kind: Combination, _ size: UInt32, intoRegister: Bool, _ mode: UInt32, _ k: inout M68000Pace) {
        let data = Int((op >> 9) & 7)
        let target: Operand, value: UInt32
        if intoRegister {
            target = Operand(inMemory: false, at: UInt32(data))
            value = read(locate(mode, op & 7, size, &k), size, &k)
        } else {
            target = locate(mode, op & 7, size, &k)
            value = kind == .add || kind == .subtract ? registers[data] : registers[data] & Self.mask(size)
        }
        let other = read(target, size, &k)
        let result: UInt32
        switch kind {
        case .or:
            result = value | other
            logic(result, size, &k)
        case .and:
            result = value & other
            logic(result, size, &k)
        case .eor:
            result = value ^ other
            logic(result, size, &k)
        case .add: result = add(value, other, size, &k)
        case .subtract: result = subtract(value, other, size, &k)
        }
        write(target, size, result, &k)
    }

    /// ADDX and SUBX, with X, for numbers longer than a register: register to register, or memory to
    /// memory working down from the far end.
    @inline(__always) mutating func extended(_ op: UInt32, adding: Bool, _ size: UInt32, memory: Bool, _ k: inout M68000Pace) {
        let source = locate(memory ? 4 : 0, op & 7, size, &k)
        let value = read(source, size, &k)
        let target = locate(memory ? 4 : 0, (op >> 9) & 7, size, &k)
        let other = read(target, size, &k)
        write(target, size, adding ? add(value, other, size, extended: true, &k) : subtract(value, other, size, extended: true, &k), &k)
    }

    @inline(__always) mutating func compare(_ op: UInt32, _ size: UInt32, from: UInt32, _ k: inout M68000Pace) {
        let value = read(locate(from, op & 7, size, &k), size, &k)
        _ = subtract(value, registers[Int((op >> 9) & 7)], size, comparing: true, &k)
    }

    @inline(__always) mutating func compareAddress(_ op: UInt32, _ size: UInt32, from: UInt32, _ k: inout M68000Pace) {
        var value = read(locate(from, op & 7, size, &k), size, &k)
        if size == 1 { value = Self.extend16(value) }
        _ = subtract(value, registers[Int((op >> 9) & 7) + 8], 2, comparing: true, &k)
    }

    /// ADDA and SUBA: on an address register, the whole register, and no flags.
    @inline(__always) mutating func addAddress(_ op: UInt32, _ size: UInt32, subtracting: Bool, from: UInt32, _ k: inout M68000Pace) {
        var value = read(locate(from, op & 7, size, &k), size, &k)
        if size == 1 { value = Self.extend16(value) }
        let a = Int((op >> 9) & 7) + 8
        registers[a] = subtracting ? registers[a] &- value : registers[a] &+ value
    }

    @inline(__always) mutating func multiply(_ op: UInt32, signed: Bool, from: UInt32, _ k: inout M68000Pace) {
        let data = Int((op >> 9) & 7)
        let value = read(locate(from, op & 7, 1, &k), 1, &k)
        let other = registers[data] & 0xFFFF
        let result = signed
            ? UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: value)) &* Int32(Int16(truncatingIfNeeded: other)))
            : value &* other
        registers[data] = result
        logic(result, 2, &k)
        if timesMultiplies {
            // 38 cycles and two for each one in the source (MULU), or for each change between
            // its bits from below a nought (MULS), the instruction's fetch among them.
            let bits = signed ? (value << 1 ^ value) & 0xFFFF : value & 0xFFFF
            k.cycles &+= 34 &+ bits.nonzeroBitCount &* 2
        } else {
            k.cycles &+= 40
        }
    }

    /// BTST (0), BCHG (1), BCLR (2) and BSET (3), the bit's number in a data register.
    @inline(__always) mutating func bitDynamic(_ op: UInt32, _ kind: UInt32, to: UInt32, _ k: inout M68000Pace) {
        bit(kind, number: registers[Int((op >> 9) & 7)], to, op & 7, &k)
    }

    /// The same, the bit's number in the word after the opcode.
    @inline(__always) mutating func bitStatic(_ op: UInt32, _ kind: UInt32, to: UInt32, _ k: inout M68000Pace) {
        let number = fetch16(&k)
        bit(kind, number: number, to, op & 7, &k)
    }

    /// One bit of a data register's 32, or of a byte of memory.
    @inline(__always) private mutating func bit(_ kind: UInt32, number: UInt32, _ mode: UInt32, _ register: UInt32, _ k: inout M68000Pace) {
        if mode == 0 {
            let mask: UInt32 = 1 << (number & 31)
            let value = registers[Int(register)]
            k.z = value & mask == 0
            switch kind {
            case 1: registers[Int(register)] = value ^ mask
            case 2: registers[Int(register)] = value & ~mask
            case 3: registers[Int(register)] = value | mask
            default: break
            }
        } else {
            let mask: UInt32 = 1 << (number & 7)
            let target = locate(mode, register, 0, &k)
            let value = read(target, 0, &k)
            k.z = value & mask == 0
            switch kind {
            case 1: write(target, 0, value ^ mask, &k)
            case 2: write(target, 0, value & ~mask, &k)
            case 3: write(target, 0, value | mask, &k)
            default: break
            }
        }
    }

    /// ASL/ASR (`kind` 0), LSL/LSR (1), ROXL/ROXR (2) and ROL/ROR (3) of a data register, by a count in the
    /// opcode (1 to 8) or in another data register.
    @inline(__always) mutating func shiftRegister(_ op: UInt32, _ kind: UInt32, left: Bool, _ size: UInt32, byRegister: Bool, _ k: inout M68000Pace) {
        let upper = (op >> 9) & 7
        let count = byRegister ? registers[Int(upper)] & 63 : (upper == 0 ? 8 : upper)
        let target = Operand(inMemory: false, at: op & 7)
        let value = read(target, size, &k)
        write(target, size, shift(kind, left: left, value, count: count, size, &k), &k)
    }

    /// MOVEM: the registers a mask picks out, to memory or back. Words come back sign-extended.
    @inline(__always) mutating func moveMultiple(toMemory: Bool, long: Bool, _ op: UInt32, _ k: inout M68000Pace) {
        let mode = (op >> 3) & 7, register = op & 7
        let mask = fetch16(&k)
        let step: UInt32 = long ? 4 : 2
        let a = Int(register) + 8
        // (The registers picked out, lowest first.)
        var picked = mask & 0xFFFF
        if toMemory {
            if mode == 4 {
                // Downwards, and then the mask is the other way round: A7 first.
                var address = registers[a]
                while picked != 0 {
                    let place = 15 - picked.trailingZeroBitCount & 15
                    picked &= picked &- 1
                    address &-= step
                    if long { write32(address, registers[place], &k) } else { write16(address, registers[place], &k) }
                }
                registers[a] = address
            } else {
                var address = operand(mode, register, 2, &k).at
                while picked != 0 {
                    let place = picked.trailingZeroBitCount & 15
                    picked &= picked &- 1
                    if long { write32(address, registers[place], &k) } else { write16(address, registers[place], &k) }
                    address &+= step
                }
            }
        } else {
            var address = mode == 3 ? registers[a] : operand(mode, register, 2, &k).at
            while picked != 0 {
                let place = picked.trailingZeroBitCount & 15
                picked &= picked &- 1
                registers[place] = long ? read32(address, &k) : Self.extend16(read16(address, &k))
                address &+= step
            }
            if mode == 3 { registers[a] = address }
        }
    }

    // MARK: Instructions run out of line

    // (Those a tune's code seldom runs, all in one step.)

    @export(interface) @inline(never) mutating func seldom(_ step: M68000Step, _ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        let mode = (op >> 3) & 7, register = op & 7
        let upper = (op >> 9) & 7
        let size = (op >> 6) & 3

        switch step {
        case .movep:
            // MOVEP: a data register to or from every other byte of memory, for peripherals on half the bus.
            let data = Int(upper)
            var address = registers[Int(register) + 8] &+ Self.extend16(fetch16(&k))
            let long = op & 0x40 != 0
            if op & 0x80 != 0 {
                let value = registers[data]
                var place: UInt32 = long ? 24 : 8
                while true {
                    write8(address, value >> place, &k)
                    address &+= 2
                    if place == 0 { break }
                    place -= 8
                }
            } else {
                var value: UInt32 = 0
                var left = long ? 4 : 2
                while left > 0 {
                    left -= 1
                    value = value << 8 | read8(address, &k)
                    address &+= 2
                }
                registers[data] = long ? value : registers[data] & 0xFFFF_0000 | value
            }

        case .immediateToStatus:
            // To the condition codes, or to the whole status register.
            let immediate = size == 0 ? fetch16(&k) & 0xFF : size == 1 ? fetch16(&k) : fetch32(&k)
            let old = size == 0 ? k.ccr : statusRegister(k)
            let new: UInt32
            switch upper {
            case 0: new = old | immediate
            case 1: new = old & immediate
            case 5: new = old ^ immediate
            default:
                halt(.illegal, &k)
                return k
            }
            if size == 0 {
                k.ccr = new
            } else if supervisor {
                setStatusRegister(new, &k)
            } else {
                exception(8, returningTo: start, &k)
            }

        case .chk:
            // CHK: a bound on a data register, and an exception if it is outside.
            let bound = Int16(truncatingIfNeeded: read(operand(mode, register, 1, &k), 1, &k))
            let value = Int16(truncatingIfNeeded: registers[Int(upper)])
            if value < 0 || value > bound {
                k.n = value < 0
                exception(6, returningTo: k.pc, &k)
            }

        case .moveFromStatus:
            let target = operand(mode, register, 1, &k)
            write(target, 1, statusRegister(k), &k)

        case .negx:
            let target = operand(mode, register, size, &k)
            let value = read(target, size, &k)
            write(target, size, subtract(value, 0, size, extended: true, &k), &k)

        case .moveToConditions:
            k.ccr = read(operand(mode, register, 1, &k), 1, &k)

        case .moveToStatus:
            let value = read(operand(mode, register, 1, &k), 1, &k)
            if supervisor { setStatusRegister(value, &k) } else { exception(8, returningTo: start, &k) }

        case .nbcd:
            // NBCD: a decimal byte taken from nothing.
            let target = operand(mode, register, 0, &k)
            let value = read(target, 0, &k)
            var result = (0x9A &- value &- (k.x ? 1 : 0)) & 0xFF
            if result != 0x9A {
                var overflow = ~result
                if result & 15 == 10 { result = (result & 0xF0) &+ 0x10 }
                result &= 0xFF
                overflow &= result
                k.v = overflow & 0x80 != 0
                write(target, 0, result, &k)
                if result != 0 { k.z = false }
                k.c = true
            } else {
                k.v = false
                k.c = false
            }
            k.x = k.c
            k.n = result & 0x80 != 0

        case .tas:
            // TAS: test a byte and set its top bit.
            let target = operand(mode, register, 0, &k)
            let value = read(target, 0, &k)
            logic(value, 0, &k)
            write(target, 0, value | 0x80, &k)

        case .trap:
            halt(.trap(Int(op & 15)), &k)

        case .link:
            // LINK: a frame on the stack, with the address register pointing at it.
            let a = Int(register) + 8
            if a == 15 {
                registers[15] &-= 4
                write32(registers[15], registers[15], &k)
            } else {
                push32(registers[a], &k)
                registers[a] = registers[15]
            }
            registers[15] &+= Self.extend16(fetch16(&k))

        case .unlink:
            let a = Int(register) + 8
            registers[15] = registers[a]
            registers[a] = pop32(&k)

        case .moveUserStack:
            guard supervisor else {
                exception(8, returningTo: start, &k)
                return k
            }
            if mode == 4 { otherStack = registers[Int(register) + 8] } else { registers[Int(register) + 8] = otherStack }

        case .resetInstruction:
            halt(.reset, &k)

        case .stopInstruction:
            guard supervisor else {
                exception(8, returningTo: start, &k)
                return k
            }
            setStatusRegister(fetch16(&k), &k)
            halt(.stopped, &k)

        case .rte:
            // (In user mode: the return from an exception is the supervisor's, and was not allowed.)
            exception(8, returningTo: start, &k)

        case .trapv:
            if k.v { exception(7, returningTo: k.pc, &k) }

        case .rtr:
            k.ccr = pop16(&k)
            k.pc = pop32(&k)

        case .divide:
            divide(signed: (op >> 6) & 7 == 7, Int(upper), mode, register, &k)

        case .decimal:
            decimal(subtracting: op >> 12 == 0x8, mode, register, upper, &k)

        case .cmpm:
            // CMPM: memory with memory, both moving on.
            let value = read(operand(3, register, size, &k), size, &k)
            let other = read(operand(3, upper, size, &k), size, &k)
            _ = subtract(value, other, size, comparing: true, &k)

        case .exchange:
            if (op >> 6) & 7 == 5 {
                // EXG: two data registers, or two address registers.
                let first = Int(upper) + (mode == 1 ? 8 : 0), second = Int(register) + (mode == 1 ? 8 : 0)
                let held = registers[first]
                registers[first] = registers[second]
                registers[second] = held
            } else {
                // EXG: a data register and an address register.
                let held = registers[Int(upper)]
                registers[Int(upper)] = registers[Int(register) + 8]
                registers[Int(register) + 8] = held
            }

        case .shiftMemory:
            // In memory: a word, by one place.
            let target = operand(mode, register, 1, &k)
            let value = read(target, 1, &k)
            write(target, 1, shift(upper & 3, left: op & 0x100 != 0, value, count: 1, 1, &k), &k)

        case .unimplemented:
            // Opcodes that begin 1010 or 1111 belong to no instruction and each has an exception of its own.
            exception(op >> 12 == 0xA ? 10 : 11, returningTo: start, &k)

        default:
            halt(.illegal, &k)
        }
        return k
    }

    private mutating func divide(signed: Bool, _ data: Int, _ mode: UInt32, _ register: UInt32, _ k: inout M68000Pace) {
        let divisor = read(operand(mode, register, 1, &k), 1, &k)
        k.cycles &+= 140
        guard divisor != 0 else {
            exception(5, returningTo: k.pc, &k)
            return
        }
        let dividend = registers[data]
        if signed {
            let bottom = Int32(Int16(truncatingIfNeeded: divisor)), top = Int32(bitPattern: dividend)
            if dividend == 0x8000_0000, bottom == -1 {
                registers[data] = 0
                k.n = false; k.z = true; k.v = false; k.c = false
                return
            }
            let quotient = top / bottom, remainder = top % bottom
            guard quotient == Int32(Int16(truncatingIfNeeded: quotient)) else {
                k.v = true
                return
            }
            registers[data] = UInt32(bitPattern: remainder) << 16 | UInt32(bitPattern: quotient) & 0xFFFF
            k.n = quotient < 0
            k.z = quotient == 0
        } else {
            let quotient = dividend / divisor
            guard quotient <= 0xFFFF else {
                k.v = true
                return
            }
            registers[data] = (dividend % divisor) << 16 | quotient
            k.n = quotient & 0x8000 != 0
            k.z = quotient == 0
        }
        k.v = false
        k.c = false
    }

    /// ABCD and SBCD: one byte of two decimal digits, with X, register to register or memory to memory.
    private mutating func decimal(subtracting: Bool, _ mode: UInt32, _ register: UInt32, _ upper: UInt32, _ k: inout M68000Pace) {
        let source = operand(mode == 0 ? 0 : 4, register, 0, &k)
        let value = read(source, 0, &k)
        let target = operand(mode == 0 ? 0 : 4, upper, 0, &k)
        let other = read(target, 0, &k)
        var result: UInt32
        var overflow: UInt32
        if subtracting {
            result = (other & 15) &- (value & 15) &- (k.x ? 1 : 0)
            overflow = ~result
            if result > 9 { result &-= 6 }
            result = result &+ (other & 0xF0) &- (value & 0xF0)
            k.c = result > 0x99
            if k.c { result &+= 0xA0 }
        } else {
            result = (value & 15) + (other & 15) + (k.x ? 1 : 0)
            overflow = ~result
            if result > 9 { result += 6 }
            result += (value & 0xF0) + (other & 0xF0)
            k.c = result > 0x99
            if k.c { result &-= 0xA0 }
        }
        k.x = k.c
        result &= 0xFF
        overflow &= result
        k.v = overflow & 0x80 != 0
        k.n = result & 0x80 != 0
        if result != 0 { k.z = false }
        write(target, 0, result, &k)
    }
}

/// What runs each opcode (`M68000.resume`): the steps are in `M68000Steps.swift`, made by a script, and
/// here is which runs which, worked out once for all 65,536 opcodes by the questions the manual's tables
/// of opcodes ask of their bits: a step that runs an instruction of every mode, then the one made for the
/// opcode's modes, if there is one.
extension M68000Step {
    /// The number (`M68000.locate`) of an addressing mode, as an opcode gives it in a mode and a register.
    @inline(__always) static func mode(_ mode: UInt32, _ register: UInt32) -> UInt32 {
        mode < 7 ? mode : 7 &+ register
    }

    /// The number of the addressing mode in an opcode's lowest six bits.
    @inline(__always) static func sourceMode(_ op: UInt32) -> UInt32 {
        mode((op >> 3) & 7, op & 7)
    }

    /// The number of a MOVE's target mode, in its bits 6 to 11, the register first.
    @inline(__always) static func targetMode(_ op: UInt32) -> UInt32 {
        mode((op >> 6) & 7, (op >> 9) & 7)
    }

    // (Written once, as it is made, and only read after.)
    nonisolated(unsafe) static let table: UnsafeMutablePointer<M68000Step> = {
        let table = UnsafeMutablePointer<M68000Step>.allocate(capacity: 65536)
        var op: UInt32 = 0
        while op < 65536 {
            let step = general(op)
            (table + Int(op)).initialize(to: specialised(step, op) ?? step)
            op += 1
        }
        return table
    }()

    private static func sized(_ size: UInt32, _ byte: M68000Step, _ word: M68000Step, _ long: M68000Step) -> M68000Step {
        size == 0 ? byte : size == 1 ? word : long
    }

    /// The step that runs an opcode's instruction in every mode it has.
    @export(interface) static func general(_ op: UInt32) -> M68000Step {
        let mode = (op >> 3) & 7, register = op & 7
        let upper = (op >> 9) & 7
        let size = (op >> 6) & 3
        let opmode = (op >> 6) & 7

        switch op >> 12 {
        case 0x0:
            if op & 0x100 != 0 { return mode == 1 ? .movep : .bitDynamic }
            if upper == 4 { return .bitStatic }
            if upper == 7 || size == 3 { return .illegal }
            if mode == 7, register == 4 { return .immediateToStatus }
            switch upper {
            case 0: return sized(size, .oriB, .oriW, .oriL)
            case 1: return sized(size, .andiB, .andiW, .andiL)
            case 2: return sized(size, .subiB, .subiW, .subiL)
            case 3: return sized(size, .addiB, .addiW, .addiL)
            case 5: return sized(size, .eoriB, .eoriW, .eoriL)
            default: return sized(size, .cmpiB, .cmpiW, .cmpiL)
            }

        case 0x1, 0x2, 0x3:
            let size: UInt32 = op >> 12 == 1 ? 0 : op >> 12 == 3 ? 1 : 2
            return opmode == 1 ? sized(size, .moveaB, .moveaW, .moveaL) : sized(size, .moveB, .moveW, .moveL)

        case 0x4:
            if op & 0x100 != 0 { return size == 3 ? .lea : size == 2 ? .chk : .illegal }
            switch (op >> 8) & 15 {
            case 0x0: return size == 3 ? .moveFromStatus : .negx
            case 0x2: return size == 3 ? .illegal : sized(size, .clrB, .clrW, .clrL)
            case 0x4: return size == 3 ? .moveToConditions : .neg
            case 0x6: return size == 3 ? .moveToStatus : .not
            case 0x8:
                switch size {
                case 0: return .nbcd
                case 1: return mode == 0 ? .swap : .pea
                default:
                    if mode == 0 { return size == 2 ? .extW : .extL }
                    return size == 3 ? .movemStoreL : .movemStoreW
                }
            case 0xA: return size == 3 ? (op == 0x4AFC ? .illegal : .tas) : sized(size, .tstB, .tstW, .tstL)
            case 0xC: return size >= 2 ? (size == 3 ? .movemLoadL : .movemLoadW) : .illegal
            case 0xE:
                switch size {
                case 1:
                    switch mode {
                    case 0, 1: return .trap
                    case 2: return .link
                    case 3: return .unlink
                    case 4, 5: return .moveUserStack
                    case 6:
                        switch register {
                        case 0: return .resetInstruction
                        case 1: return .nop
                        case 2: return .stopInstruction
                        case 3: return .rte
                        case 5: return .rts
                        case 6: return .trapv
                        case 7: return .rtr
                        default: return .illegal
                        }
                    default: return .illegal
                    }
                case 2: return .jsr
                case 3: return .jmp
                default: return .illegal
                }
            default: return .illegal
            }

        case 0x5:
            if size == 3 {
                if mode == 1 { return (op >> 8) & 15 == 1 ? .dbra : .dbcc }
                return .scc
            }
            if mode == 1 { return op & 0x100 != 0 ? .subqA : .addqA }
            return op & 0x100 != 0 ? sized(size, .subqB, .subqW, .subqL) : sized(size, .addqB, .addqW, .addqL)

        case 0x6:
            let steps: [M68000Step] = [.bra, .bsr, .bhi, .bls, .bcc, .bcs, .bne, .beq, .bvc, .bvs, .bpl, .bmi, .bge, .blt, .bgt, .ble]
            return steps[Int((op >> 8) & 15)]

        case 0x7:
            return op & 0x100 != 0 ? .illegal : .moveq

        case 0x8:
            if opmode == 3 || opmode == 7 { return .divide }
            if opmode == 4, mode < 2 { return .decimal }
            return opmode < 3 ? sized(size, .orB, .orW, .orL) : sized(opmode & 3, .orEaB, .orEaW, .orEaL)

        case 0x9, 0xD:
            let adding = op >> 12 == 0xD
            if opmode == 3 || opmode == 7 { return adding ? (opmode == 3 ? .addaW : .addaL) : (opmode == 3 ? .subaW : .subaL) }
            if opmode >= 4, mode < 2 { return adding ? sized(size, .addxB, .addxW, .addxL) : sized(size, .subxB, .subxW, .subxL) }
            if opmode < 3 { return adding ? sized(size, .addB, .addW, .addL) : sized(size, .subB, .subW, .subL) }
            return adding ? sized(size, .addEaB, .addEaW, .addEaL) : sized(size, .subEaB, .subEaW, .subEaL)

        case 0xB:
            if opmode == 3 || opmode == 7 { return opmode == 3 ? .cmpaW : .cmpaL }
            if opmode < 3 { return sized(size, .cmpB, .cmpW, .cmpL) }
            if mode == 1 { return .cmpm }
            return sized(opmode & 3, .eorB, .eorW, .eorL)

        case 0xC:
            if opmode == 3 || opmode == 7 { return opmode == 3 ? .mulu : .muls }
            if opmode == 4, mode < 2 { return .decimal }
            if opmode == 5, mode < 2 { return .exchange }
            if opmode == 6, mode == 1 { return .exchange }
            return opmode < 3 ? sized(size, .andB, .andW, .andL) : sized(opmode & 3, .andEaB, .andEaW, .andEaL)

        case 0xE:
            if size == 3 { return op & 0x800 != 0 ? .illegal : .shiftMemory }
            return .shiftRegister

        default:
            return .unimplemented
        }
    }
}
