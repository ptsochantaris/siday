// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// How a call into a program's code on the machine (`AmigaMachine.call`) came out.
enum AmigaCall: Equatable {
    /// It came back.
    case returned
    /// It executed TRAP with this number, and waits: the host answers it and goes on (`resume`), or
    /// gives up.
    case trap(Int)
    /// It did not come back in the time it was given, met something that is not an instruction, took
    /// an exception, or stopped to wait for an interrupt: the program has gone wrong.
    case failed
}

/// How a stretch of the machine's running as the hardware runs it (`AmigaMachine.run(until:)`) came out.
enum AmigaRun: Equatable {
    /// It ran until the time it was given.
    case reached
    /// It executed RESET: a call into the program's code has come back to `AmigaMachine.returnAddress`.
    case returned
    /// It executed TRAP with this number, and waits for the host to answer it (and run on), or to take
    /// it as the 68000 would (`M68000.takeTrap`).
    case trap(Int)
    /// It met something that is not an instruction, or took an exception: the program has gone wrong.
    case failed
}

/// As much of an Amiga as music needs whose player is a composer's own code: a 68000 (`M68000`), its
/// chip RAM, from which Paula plays, and the chips above it (`AmigaChips`).
///
/// The machine does not run continuously. The host calls into the program's code, which runs until it
/// comes back: to start a song, and once on each tick of its player, as an EaglePlayer or DeliTracker
/// calls a player's interrupt routine from its timer. What the code does to Paula is kept with the
/// moment it did it (`AmigaChips.writes`), to be heard at that moment within the tick. Between calls the
/// host moves the machine's time on (`advance(clocks:)`), as the rest of the tick passes.
///
/// The bottom of the memory is the machine's own: the 68000's exception vectors, every one pointing
/// at an ILLEGAL (`faultAddress`), so that an exception ends the call as having failed; a RESET
/// (`returnAddress`), which a call returns to and which ends it; a word of silence (`silence`); and the
/// pointer at address 4 to the system's library (`execBase`), whose every routine (a JMP each, below
/// it) is that ILLEGAL until the host gives it one (`setLibraryRoutine`). The library, the silence and
/// the ILLEGAL are where UADE's host has its library, its silence and its handler of exceptions
/// (`score.s`, which UADE puts at $1000), so that a driver that reads the bottom of the memory where
/// it should not (as one of Whittaker's does, for a voice's envelope it has not yet been given) reads
/// what it would read in UADE. The host's own code, a stack, and the program are put above it all,
/// where the host chooses (`hostSpace` is free).
struct AmigaMachine: ~Copyable {
    static let returnAddress: UInt32 = 0x400
    static let execBase: UInt32 = 0xD00
    static let silence: UInt32 = 0x12CA
    static let faultAddress: UInt32 = 0x1348
    /// How many routines the library has room for: as many as UADE gives it.
    static let libraryRoutines = 210
    /// From here up to the program is the host's, for its own code and its stack.
    static let hostSpace: UInt32 = 0x1400
    /// The 68000's cycles in a fiftieth of a second (a PAL frame), two to each of Paula's clocks.
    static let frameCycles = AmigaChips.lineClocks * AmigaChips.frameLines * 2

    let memory: UnsafeMutablePointer<UInt8>
    let memorySize: Int
    let chips: AmigaChips
    var cpu: M68000
    /// True while the processor waits, after a STOP, for an interrupt (see `run(until:)`).
    private(set) var waiting = false
    /// The processor's cycles it has spent waiting so, all told.
    private(set) var waitedCycles = 0

    /// - Parameter chipRAM: how many bytes of chip RAM, from address 0 (at least 64 KB).
    init(chipRAM: Int) {
        memorySize = max(0x10000, min(chipRAM, 0x20_0000))
        memory = .allocate(capacity: memorySize)
        chips = AmigaChips()
        cpu = M68000(ram: memory, ramSize: memorySize, bus: chips)
        powerOn()
    }

    deinit {
        memory.deallocate()
    }

    /// Everything as it is when the machine is switched on: the memory empty but for the machine's
    /// own, the chips quiet, and the processor in supervisor mode with its interrupts masked.
    mutating func powerOn() {
        memory.initialize(repeating: 0, count: memorySize)
        chips.reset()
        cpu.powerOn()
        for vector in 2 ..< 256 { poke32(UInt32(vector * 4), Self.faultAddress) }
        poke16(Self.returnAddress, 0x4E70)
        poke16(Self.faultAddress, 0x4AFC)
        poke32(4, Self.execBase)
        for routine in 1 ... Self.libraryRoutines { setLibraryRoutine(routine * 6, to: Self.faultAddress) }
        waiting = false
    }

    /// Makes the library's routine at `offset` below its base (as a program calls it, `JSR -offset(A6)`)
    /// jump to `address`.
    func setLibraryRoutine(_ offset: Int, to address: UInt32) {
        let at = Self.execBase &- UInt32(offset)
        poke16(at, 0x4EF9)
        poke32(at &+ 2, address)
    }

    /// Sets Paula as UADE's host sets her before a player starts (`score.s`): the DMA of every voice
    /// off and its master bit on, no voice modulating another, and each voice silent, pointed at a word
    /// of silence one word long, at a period of 150. Made as writes, so that they are heard.
    func quietPaula() {
        chips.write16(AmigaChips.custom + 0x96, 0x7FFF)
        chips.write16(AmigaChips.custom + 0x9E, 0x00FF)
        for v in 0 ..< 4 {
            let at = AmigaChips.custom + 0xA0 + UInt32(v * 16)
            chips.write16(at + 8, 0)
            chips.write16(at, UInt16(Self.silence >> 16))
            chips.write16(at + 2, UInt16(Self.silence & 0xFFFF))
            chips.write16(at + 4, 1)
            chips.write16(at + 6, 150)
        }
        chips.write16(AmigaChips.custom + 0x96, 0x8200)
    }

    // MARK: Memory

    /// Puts bytes into the memory at an address. False, and nothing put, if they do not fit.
    @discardableResult
    func load(_ bytes: [UInt8], at address: UInt32) -> Bool {
        guard Int(address) + bytes.count <= memorySize else { return false }
        for (i, byte) in bytes.enumerated() { memory[Int(address) + i] = byte }
        return true
    }

    func peek8(_ address: UInt32) -> UInt8 { Int(address) < memorySize ? memory[Int(address)] : 0 }
    func peek16(_ address: UInt32) -> UInt16 { UInt16(peek8(address)) << 8 | UInt16(peek8(address &+ 1)) }
    func peek32(_ address: UInt32) -> UInt32 { UInt32(peek16(address)) << 16 | UInt32(peek16(address &+ 2)) }

    func poke8(_ address: UInt32, _ value: UInt8) {
        if Int(address) < memorySize { memory[Int(address)] = value }
    }

    func poke16(_ address: UInt32, _ value: UInt16) {
        poke8(address, UInt8(truncatingIfNeeded: value >> 8))
        poke8(address &+ 1, UInt8(truncatingIfNeeded: value))
    }

    func poke32(_ address: UInt32, _ value: UInt32) {
        poke16(address, UInt16(truncatingIfNeeded: value >> 16))
        poke16(address &+ 2, UInt16(truncatingIfNeeded: value))
    }

    // MARK: Running

    /// Calls a subroutine at `address`, with the stack below `stack`, the registers as they are (set
    /// them first through `cpu.registers`), for at most `budget` of the processor's cycles; the
    /// subroutine's RTS comes back to the RESET at `returnAddress`, which ends the call.
    mutating func call(_ address: UInt32, stack: UInt32, budget: Int) -> AmigaCall {
        poke32(stack &- 4, Self.returnAddress)
        cpu.registers[15] = stack &- 4
        cpu.pc = address
        return outcome(cpu.run(cycles: budget))
    }

    /// Goes on after a TRAP the host has answered, with what is left of the call's budget.
    mutating func resume(budget: Int) -> AmigaCall {
        outcome(cpu.resume(cycles: budget))
    }

    private func outcome(_ stop: M68000Stop) -> AmigaCall {
        switch stop {
        case .reset: .returned
        case let .trap(number): .trap(number)
        case .outOfTime, .illegal, .stopped: .failed
        }
    }

    /// The processor's cycles used in the current call (or the last).
    var cycles: Int { cpu.cycles }

    /// Moves the machine's time on, as time passes between calls: `clocks` of Paula's after the
    /// moment the last call began.
    mutating func advance(clocks: Int) {
        chips.clock &+= UInt64(max(0, clocks))
        chips.catchUp(0)
    }

    /// The writes to Paula and the DMA made since this was last asked, in order (see `AmigaChips`).
    mutating func takeWrites(into list: inout [AmigaWrite]) {
        list.removeAll(keepingCapacity: true)
        swap(&list, &chips.writes)
    }

    // MARK: Running as the hardware runs

    // A player that sets its own timers, takes over the interrupts, or feeds its voices from Paula's
    // interrupts cannot be called a tick at a time: the machine is run as the Amiga runs, its processor
    // going on from where it is and taking each interrupt as the chips ask for it (`AmigaChips.interrupts`
    // on), and time passing as it goes.

    /// Starts a stretch of time: the time the processor has reached becomes the moment its cycles, and
    /// the times of the writes it makes from now (`takeWrites`), are counted from (`chips.clock`).
    mutating func beginStretch() {
        let used = cpu.cycles
        chips.clock &+= UInt64(max(0, used) / 2)
        _ = cpu.run(cycles: 0)
        cpu.wait(cycles: used & 1)
    }

    /// The time the processor has reached, in Paula's clocks since the machine was switched on.
    var now: UInt64 { chips.now(cpu.cycles) }

    /// Sends the processor to `address`, as the start of a call, a return or an interrupt the host makes:
    /// it no longer waits, if it was.
    mutating func jump(to address: UInt32) {
        cpu.pc = address
        waiting = false
    }

    /// Runs the processor from where it is until the time `end`, as the hardware runs it: each interrupt
    /// the chips ask for is taken between two instructions as soon as it comes due and the processor's
    /// mask lets it through, and after a STOP nothing runs until one is. It stops before then for a RESET,
    /// a TRAP, or code that has gone wrong. A program that never comes back is no matter: time still
    /// runs to `end`.
    mutating func run(until end: UInt64) -> AmigaRun {
        // (After an instruction that wrote to what asks for interrupts, one more is run before an
        // interrupt is taken, as UAE takes it.)
        var oneMore = false
        while true {
            chips.catchUp(cpu.cycles)
            let time = now
            if time >= end { return .reached }
            if chips.wroteInterrupts {
                chips.wroteInterrupts = false
                oneMore = !waiting
            }
            let level = chips.interruptLevel
            if oneMore {
                oneMore = false
                switch cpu.resume(cycles: cpu.cycles + 1) {
                case .outOfTime: continue
                case .stopped: waiting = true
                case .reset: return .returned
                case let .trap(number): return .trap(number)
                case .illegal: return .failed
                }
                continue
            }
            if level > 0, cpu.interrupt(level: level) {
                waiting = false
                continue
            }
            // (While nothing is asked for that the mask holds back, where the processor is looked at
            // changes nothing until something asks, and it is run until then; otherwise as below.)
            let exact = level == 0 ? chips.nextRequest(after: time, by: end) : nil
            let next = exact ?? min(end, chips.nextInterrupt(after: time))
            if waiting {
                let idle = max(2, Int(min(next - time, 1 << 30)) * 2)
                cpu.wait(cycles: idle)
                waitedCycles &+= idle
                continue
            }
            // No further than the next interrupt that may come due, and no more than a few lines' worth
            // between looks (a write may have set one going sooner); a few instructions at a time while
            // one is asked for that the mask holds back, to take it as soon as the mask comes down.
            let most = level > 0 ? 64 : exact != nil ? 1 << 30 : 1024
            let span = Int(min(next - time, UInt64(most / 2))) * 2
            switch cpu.resume(cycles: cpu.cycles + max(2, span)) {
            case .outOfTime: continue
            case .stopped: waiting = true
            case .reset: return .returned
            case let .trap(number): return .trap(number)
            case .illegal: return .failed
            }
        }
    }

    /// What the host's code has told it through its port since this was last asked.
    mutating func takeSignals(into list: inout [AmigaWrite]) {
        list.removeAll(keepingCapacity: true)
        swap(&list, &chips.signals)
    }
}
