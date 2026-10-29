// Copyright (C) 2021, 2024 nukeykt
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A Swift port of Nuked SC-55's emulation of the SC-55mkII's second processor, a Mitsubishi M37450 (submcu.cpp,
// as jcmoyer's fork of Nuked SC-55 keeps it), free software under the GNU General Public License, version 2 or
// any later version (see THIRD-PARTY.md).

/// The SC-55mkII's second processor: a Mitsubishi M37450, of the 6502's kind, running its own 4 KB program. It
/// takes the MIDI in at its serial port and hands it to the controller through the 192 bytes of RAM they share,
/// raising the controller's interrupt through the gate array's line 5 when there is something there.
///
/// It runs as Nuked SC-55 runs it, 48 of its cycles an instruction, five of its cycles to each of the
/// controller's, so 1.25 of its instructions to each of the controller's steps. It is brought up to the
/// controller's time only when it has to be (`catchUp`): when the controller reads or writes their shared side,
/// when a byte is posted to the MIDI in, and at the controller's steps from when it may next raise that line on.
/// Most of its time it goes round a loop that changes nothing, waiting for a byte or its 1 ms timer: once it
/// has been seen to come round to the same place with everything the same, as many times round as there is
/// room for before anything can come of it are made at once, its timer counted on, as they would have been one
/// by one.
final class SC55SubMCU {
    unowned(unsafe) var mcu: SC55MCU!

    // MARK: Registers

    @exclusivity(unchecked) var pc: UInt16 = 0
    @exclusivity(unchecked) var a: UInt8 = 0, x: UInt8 = 0, y: UInt8 = 0, s: UInt8 = 0, sr: UInt8 = 0
    @exclusivity(unchecked) var sleeping = false
    @exclusivity(unchecked) var cycles: UInt64 = 0

    static let statusC: UInt8 = 1, statusZ: UInt8 = 2, statusI: UInt8 = 4, statusD: UInt8 = 8
    static let statusT: UInt8 = 32, statusN: UInt8 = 128

    // MARK: Memory

    /// Its program, at 0x1000 (its vectors at the top, from 0x1FEC).
    let rom: UnsafeMutablePointer<UInt8>
    /// Everything of it that is memory, one block (so that it is copied and compared at once): its RAM at 0
    /// (128 bytes), the RAM it shares with the controller (192 bytes, at 0x200 on its side, 0xEC00 on the
    /// controller's), a bit for each byte of that saying it has been written and not read (24 bytes, at 0xC0),
    /// and its devices' registers (32, at 0xE0).
    let memory: UnsafeMutablePointer<UInt8>
    static let shared = 128, access = 320, devices = 344, memorySize = 376
    @exclusivity(unchecked) var p0Direction: UInt8 = 0, p1Direction: UInt8 = 0
    /// True while a byte taken from the MIDI in has not been read.
    @exclusivity(unchecked) var holdsByte = false

    // Its devices' registers, as offsets from 0xE0.
    static let ramDirection = 0x02, uart1Control = 0x06, uart2Data = 0x08, uart2Control = 0x0A
    static let uart3Status = 0x0D, uart3Control = 0x0E, ipcm0 = 0x10, ipce0 = 0x14, semaphore = 0x19
    static let collision = 0x1A, interruptEnable = 0x1B, interruptRequest = 0x1C, prescaler = 0x1D, timer = 0x1E, timerControl = 0x1F

    // MARK: Timer

    @exclusivity(unchecked) var timerCycles: UInt64 = 0
    @exclusivity(unchecked) var prescalerCount: UInt8 = 0
    @exclusivity(unchecked) var timerCount: UInt8 = 0

    // MARK: Loops

    /// How long the loop it is going round takes, in its cycles, once it has been seen to come round to
    /// `watchPC` at `watchCycles` with nothing changed; 0 while it is not known to be in one.
    @exclusivity(unchecked) var period: UInt64 = 0
    @exclusivity(unchecked) var watchPC: UInt16 = 0
    @exclusivity(unchecked) var watchCycles: UInt64 = 0
    @exclusivity(unchecked) var watchSteps = 0
    /// Set when something has happened since the watch began that coming round to the same place with the
    /// same memory does not show: an interrupt taken, a byte taken, the timer running out, a register read
    /// that changes with time.
    @exclusivity(unchecked) var disturbed = true
    /// Set when it changes the RAM it shares with the controller, or a register (`changedShared`), since the
    /// watch began; and whether the loop it is known to be going round never does (`keepsShared`).
    @exclusivity(unchecked) var changedShared = false
    @exclusivity(unchecked) var keepsShared = false
    /// Its memory and registers as they were at the watch's start.
    let watched: UnsafeMutablePointer<UInt8>
    static let watchedSize = memorySize + 10

    init(rom romData: [UInt8]) {
        rom = .allocate(capacity: 4096)
        rom.initialize(repeating: 0, count: 4096)
        for i in 0 ..< min(romData.count, 4096) { rom[i] = romData[i] }
        memory = .allocate(capacity: Self.memorySize)
        memory.initialize(repeating: 0, count: Self.memorySize)
        watched = .allocate(capacity: Self.watchedSize)
        watched.initialize(repeating: 0, count: Self.watchedSize)
    }

    deinit {
        rom.deallocate()
        memory.deallocate()
        watched.deallocate()
    }

    func reset() {
        pc = vector(9)
        a = 0; x = 0; y = 0; s = 0; sr = 0
        cycles = 0
        sleeping = false
        period = 0
        disturbed = true
    }

    @inline(__always) func device(_ n: Int) -> UInt8 { memory[Self.devices + n] }

    @inline(__always) func setDevice(_ n: Int, _ value: UInt8) { memory[Self.devices + n] = value }

    // MARK: Its memory map

    func read(_ address: UInt16) -> UInt8 {
        let a = Int(address & 0x1FFF)
        if a & 0x1000 != 0 { return rom[a & 0xFFF] }
        if a < 0x80 { return memory[a] }
        if a >= 0xC0, a < 0xD8 { return memory[Self.access + (a & 0x1F)] }
        if a >= 0xE0, a < 0x100 { return deviceRead(a & 0x1F) }
        if a >= 0x200, a < 0x2C0 {
            let n = a & 0xFF
            if device(Self.ramDirection) & (1 << (n >> 5)) != 0 {
                let bit: UInt8 = 1 << UInt8(n & 7)
                if memory[Self.access + (n >> 3)] & bit != 0 { changedShared = true }
                memory[Self.access + (n >> 3)] &= ~bit
            }
            return memory[Self.shared + n]
        }
        return 0
    }

    func write(_ address: UInt16, _ data: UInt8) {
        let a = Int(address & 0x1FFF)
        if a < 0x80 {
            memory[a] = data
        } else if a >= 0xE0, a < 0x100 {
            deviceWrite(a & 0x1F, data)
        } else if a >= 0x200, a < 0x2C0 {
            let n = a & 0xFF
            let bit: UInt8 = 1 << UInt8(n & 7)
            if memory[Self.access + (n >> 3)] & bit == 0 || memory[Self.shared + n] != data { changedShared = true }
            memory[Self.access + (n >> 3)] |= bit
            memory[Self.shared + n] = data
        }
    }

    private func deviceRead(_ n: Int) -> UInt8 {
        switch n {
        case Self.uart2Data:
            holdsByte = false
            disturbed = true
            return mcu.uartByte
        case 0x05, Self.uart3Status: return 5
        case 0x09: return (holdsByte ? 2 : 0) | 5
        // (Port 1 is the buttons' rows, read through the controller's: none is pressed.)
        case 0x00: return 0xFF
        case 0x01: return p1Direction
        case Self.prescaler:
            disturbed = true
            return prescalerCount
        case Self.timer:
            disturbed = true
            return timerCount
        default: return device(n)
        }
    }

    private func deviceWrite(_ n: Int, _ data: UInt8) {
        let before = device(n)
        defer { if device(n) != before { changedShared = true } }
        switch n {
        // (Port 1's data goes to the buttons' rows, which nothing reads back.)
        case 0x00: break
        case 0x01: p1Direction = data
        case Self.interruptRequest: memory[Self.devices + n] &= data
        case Self.collision:
            var value = device(n) & ~0x7F | data & 0x7F
            if data & 0x80 == 0 { value &= ~0x80 }
            setDevice(n, value)
        default: setDevice(n, data)
        }
        if n == Self.uart3Status || n == Self.uart3Control {
            mcu.setGateLine(5, device(Self.uart3Status) & 0x80 != 0 && device(Self.uart3Control) & 0x20 == 0)
        }
    }

    // MARK: The controller's side (0xEC00 to 0xEFFF)

    /// A write by the controller, `address` the low byte of where it writes.
    func controllerWrite(_ address: Int, _ data: UInt8) {
        period = 0
        disturbed = true
        if address < 0xC0 {
            memory[Self.access + (address >> 3)] |= 1 << UInt8(address & 7)
            memory[Self.shared + address] = data
        } else if address >= 0xF8, address < 0xFC {
            setDevice(Self.ipcm0 + (address & 3), data)
            if address & 3 == 0 {
                memory[Self.devices + Self.interruptRequest] |= 0x10
                memory[Self.devices + Self.semaphore] &= ~0x80
            }
        } else if address == 0xFF {
            setDevice(Self.semaphore, device(Self.semaphore) & ~0x1F | data & 0x1F)
        } else if address == 0xF7 {
            p0Direction = data
        }
        // (0xF5 and 0xF6, ports 1 and 0, drive the buttons' rows, which nothing reads back.)
    }

    /// True if a read by the controller would change nothing, and what it reads is as it would be had the
    /// second processor been brought up to the time: while it goes round a loop that leaves the RAM they share
    /// and its registers as they are, a read of the RAM that clears no bit, or of a register that is not
    /// changed by being read. (The loop does not end before its `due`, before which the controller is not
    /// let run on without bringing it up to the time.)
    func readsQuietly(_ address: Int) -> Bool {
        guard period != 0, keepsShared else { return false }
        if address < 0xC0 {
            return device(Self.ramDirection) & (1 << (address >> 5)) != 0 || memory[Self.access + (address >> 3)] & (1 << UInt8(address & 7)) == 0
        }
        return address < 0xF8 || address >= 0xFC
    }

    /// A read by the controller.
    func controllerRead(_ address: Int) -> UInt8 {
        if address < 0xC0 {
            if device(Self.ramDirection) & (1 << (address >> 5)) == 0 {
                let bit: UInt8 = 1 << UInt8(address & 7)
                if memory[Self.access + (address >> 3)] & bit != 0 {
                    memory[Self.access + (address >> 3)] &= ~bit
                    period = 0
                    disturbed = true
                }
            }
            return memory[Self.shared + address]
        }
        if address >= 0xF8, address < 0xFC {
            period = 0
            disturbed = true
            if address & 3 == 0 { memory[Self.devices + Self.interruptRequest] |= 0x10 }
            let value = device(Self.ipce0 + (address & 3))
            setDevice(Self.ipce0 + (address & 3), 0)
            return value
        }
        switch address {
        case 0xFF: return device(Self.semaphore)
        case 0xF5, 0xF6: return 0xFF
        case 0xF7: return p0Direction
        default: return 0
        }
    }

    // MARK: Running

    /// Runs it until it has been brought up to the controller's `mcuCycles` (five of its cycles to each), as
    /// Nuked SC-55 runs it after each of the controller's steps.
    func catchUp(to mcuCycles: UInt64) {
        let target = mcuCycles &* 5
        while cycles < target {
            if period != 0, pc == watchPC, (cycles &- watchCycles) % period == 0 { skipLoops(before: target) }
            guard cycles < target else { return }
            step()
            if period == 0 { watch() }
        }
    }

    /// Goes round the loop it is known to be in as many times as can be made before `target`, or before
    /// anything can come of its going round: its timer running out, or a byte it is to take.
    private func skipLoops(before target: UInt64) {
        // (After each step the timer is brought up to the time and a byte looked for: the last step made at
        // once has to end before the tick that runs the timer out, and before a byte's time.)
        let wake = wake
        guard wake > 0 else { return }
        let limit = min(target, wake - 1)
        guard limit > cycles else { return }
        let times = (limit - cycles) / period
        guard times > 0 else { return }
        cycles &+= times * period
        guard cycles > timerCycles else { return }
        let ticks = (cycles - timerCycles + 15) / 16
        if device(Self.timerControl) & 0x20 == 0, !sleeping { countTimer(ticks) }
        timerCycles &+= ticks * 16
    }

    /// Its cycle count at or after which its going round the loop may end: the tick at which its timer runs
    /// out, if it is counting, and when a byte waiting at the MIDI in may be taken. (Bytes posted later bring
    /// it up to the time before they are posted.)
    var wake: UInt64 {
        var wake = UInt64.max
        if device(Self.timerControl) & 0x20 == 0, !sleeping {
            let reload = UInt64(device(Self.prescaler)) + 1
            let ticks = UInt64(prescalerCount) + 1 + UInt64(timerCount) * reload
            wake = timerCycles &+ (ticks - 1) * 16
        }
        if device(Self.uart1Control) & 4 != 0, mcu.uartWrite != mcu.uartRead, !holdsByte { wake = min(wake, mcu.uartRxDelay) }
        return wake
    }

    /// The controller's cycle count from which it may raise the controller's interrupt, and so has to be
    /// kept up with the controller step by step; while it is going round its loop, a little before its loop
    /// may end.
    var due: UInt64 {
        guard period != 0 else { return 0 }
        let wake = wake
        guard wake != .max else { return .max }
        return wake > 96 ? (wake - 96) / 5 : 0
    }

    /// Counts `ticks` of the timer, which do not run it out: the prescaler counts down to 0, and at each tick
    /// it is found at 0 it is set again and the timer counts down one.
    private func countTimer(_ ticks: UInt64) {
        guard ticks > 0 else { return }
        let p = UInt64(prescalerCount)
        if ticks <= p {
            prescalerCount = UInt8(p - ticks)
            return
        }
        let reload = UInt64(device(Self.prescaler)) + 1
        let after = ticks - p
        let reloads = (after - 1) / reload + 1
        prescalerCount = UInt8(reload - 1 - (after - 1) % reload)
        timerCount = UInt8(UInt64(timerCount) - reloads)
    }

    /// Looks for its having come round to the same place with nothing changed.
    private func watch() {
        watchSteps += 1
        if pc == watchPC, !disturbed, same() {
            period = cycles - watchCycles
            watchCycles = cycles
            keepsShared = !changedShared
            return
        }
        if pc == watchPC || watchSteps >= 48 || disturbed { startWatch() }
    }

    private func startWatch() {
        watchPC = pc
        watchCycles = cycles
        watchSteps = 0
        disturbed = false
        changedShared = false
        watched.update(from: memory, count: Self.memorySize)
        let registers = watched + Self.memorySize
        registers[0] = a; registers[1] = x; registers[2] = y; registers[3] = s; registers[4] = sr
        registers[5] = sleeping ? 1 : 0; registers[6] = holdsByte ? 1 : 0
        registers[7] = p0Direction; registers[8] = p1Direction
    }

    private func same() -> Bool {
        let registers = watched + Self.memorySize
        guard registers[0] == a, registers[1] == x, registers[2] == y, registers[3] == s, registers[4] == sr,
              registers[5] == (sleeping ? 1 : 0), registers[6] == (holdsByte ? 1 : 0),
              registers[7] == p0Direction, registers[8] == p1Direction else { return false }
        for i in 0 ..< Self.memorySize where watched[i] != memory[i] { return false }
        return true
    }

    /// One of its instructions, as Nuked SC-55's SM_Update makes it: an interrupt taken if one is due, the
    /// instruction (unless it is asleep), 48 cycles, its timer brought up to the time, and the MIDI in looked at.
    @inline(__always) func step() {
        if sr & Self.statusI == 0 { handleInterrupts() }
        if !sleeping { execute(fetch()) }
        cycles &+= 48
        updateTimer()
        updateSerial()
    }

    private func updateTimer() {
        while timerCycles < cycles {
            if device(Self.timerControl) & 0x20 == 0, !sleeping {
                if prescalerCount == 0 {
                    prescalerCount = device(Self.prescaler)
                    if timerCount == 0 {
                        timerCount = device(Self.timer)
                        memory[Self.devices + Self.interruptRequest] |= 0x08
                        period = 0
                        disturbed = true
                    } else {
                        timerCount &-= 1
                    }
                } else {
                    prescalerCount &-= 1
                }
            }
            timerCycles &+= 16
        }
    }

    /// Takes the next byte posted to the MIDI in, once the one before has been read and its time is up
    /// (12,000 of its cycles after the last: the controller's, as Nuked SC-55's fork has it).
    private func updateSerial() {
        guard device(Self.uart1Control) & 4 != 0, mcu.uartWrite != mcu.uartRead, !holdsByte, cycles >= mcu.uartRxDelay else { return }
        mcu.uartByte = mcu.uartBuffer[mcu.uartRead]
        mcu.uartRead = (mcu.uartRead + 1) % SC55MCU.uartBufferSize
        holdsByte = true
        memory[Self.devices + Self.interruptRequest] |= 0x40
        mcu.uartRxDelay = cycles &+ 3000 * 4
        period = 0
        disturbed = true
    }

    // MARK: Interrupts

    @inline(__always) private func vector(_ n: Int) -> UInt16 {
        UInt16(read(UInt16(0x1FEC + n * 2))) | UInt16(read(UInt16(0x1FEC + n * 2 + 1))) << 8
    }

    private func startVector(_ n: Int) {
        push(UInt8(truncatingIfNeeded: pc >> 8))
        push(UInt8(truncatingIfNeeded: pc))
        push(sr)
        sr |= Self.statusI
        sleeping = false
        pc = vector(n)
        period = 0
        disturbed = true
    }

    @inline(__always) private func handleInterrupts() {
        let enable = device(Self.interruptEnable), request = device(Self.interruptRequest)
        guard enable & request != 0 || device(Self.collision) & 0xC0 == 0xC0 else { return }
        let ir = Self.devices + Self.interruptRequest
        if device(Self.uart1Control) & 0x08 != 0, enable & 0x80 != 0, request & 0x80 != 0 {
            memory[ir] &= ~0x80
            startVector(8)
        } else if device(Self.uart2Control) & 0x08 != 0, enable & 0x40 != 0, request & 0x40 != 0 {
            memory[ir] &= ~0x40
            startVector(7)
        } else if device(Self.uart3Control) & 0x08 != 0, enable & 0x20 != 0, request & 0x20 != 0 {
            memory[ir] &= ~0x20
            startVector(6)
        } else if device(Self.timerControl) & 0x80 != 0, enable & 0x10 != 0, request & 0x10 != 0 {
            memory[ir] &= ~0x10
            startVector(5)
        } else if device(Self.timerControl) & 0x40 != 0, enable & 0x08 != 0, request & 0x08 != 0 {
            memory[ir] &= ~0x08
            startVector(4)
        } else if device(Self.collision) & 0xC0 == 0xC0 {
            memory[Self.devices + Self.collision] &= ~0x80
            startVector(3)
        } else if device(Self.uart1Control) & 0x10 == 0, enable & 0x04 != 0, request & 0x04 != 0 {
            // (Each sends when its control register's bit 4 is clear, or when its clear-to-send is set,
            // which nothing sets.)
            memory[ir] &= ~0x04
            startVector(2)
        } else if device(Self.uart2Control) & 0x10 == 0, enable & 0x02 != 0, request & 0x02 != 0 {
            memory[ir] &= ~0x02
            startVector(1)
        } else if device(Self.uart3Control) & 0x10 == 0, enable & 0x01 != 0, request & 0x01 != 0 {
            memory[ir] &= ~0x01
            startVector(0)
        }
    }

    // MARK: Instructions

    @inline(__always) private func fetch() -> UInt8 {
        let value = pc & 0x1000 != 0 ? rom[Int(pc & 0xFFF)] : read(pc)
        pc &+= 1
        return value
    }

    @inline(__always) private func fetch16() -> UInt16 {
        let low = UInt16(fetch())
        return low | UInt16(fetch()) << 8
    }

    /// A word read from memory as Nuked SC-55 reads it: the same byte twice.
    @inline(__always) private func read16(_ address: UInt16) -> UInt16 {
        let low = UInt16(read(address))
        return low | UInt16(read(address)) << 8
    }

    @inline(__always) private func push(_ value: UInt8) {
        write(UInt16(s), value)
        s &-= 1
    }

    @inline(__always) private func pop() -> UInt8 {
        s &+= 1
        return read(UInt16(s))
    }

    @inline(__always) private func setNZ(_ value: UInt8) {
        sr = sr & ~(Self.statusZ | Self.statusN) | (value == 0 ? Self.statusZ : 0) | (value & 0x80 != 0 ? Self.statusN : 0)
    }

    @inline(__always) private func setFlag(_ flag: UInt8, _ on: Bool) {
        sr = on ? sr | flag : sr & ~flag
    }

    @inline(__always) private func branch(if taken: Bool) {
        let displacement = Int8(bitPattern: fetch())
        if taken { pc &+= UInt16(bitPattern: Int16(displacement)) }
    }

    @inline(__always) private func compare(_ register: UInt8, _ operand: UInt8) {
        let difference = Int(register) - Int(operand)
        setFlag(Self.statusC, difference & 0x100 == 0)
        setNZ(UInt8(truncatingIfNeeded: difference))
    }

    /// The operand of LDA, CMP, ORA and AND, by the low bits of the opcode (the 6502's group one).
    @inline(__always) private func groupOneOperand(_ opcode: UInt8) -> UInt8 {
        switch opcode & 0x1F {
        case 0x09: return fetch()
        case 0x05: return read(UInt16(fetch()))
        case 0x15: return read(UInt16(fetch() &+ x))
        case 0x0D: return read(fetch16())
        case 0x1D: return read(fetch16() &+ UInt16(x))
        case 0x19: return read(fetch16() &+ UInt16(y))
        case 0x01: return read(read16(UInt16(fetch() &+ x)))
        default: return read(read16(UInt16(fetch())) &+ UInt16(y))
        }
    }

    /// ORA and AND: on the accumulator, or with the T flag set, on the byte X points at.
    @inline(__always) private func logical(_ opcode: UInt8, or: Bool) {
        let t = sr & Self.statusT != 0
        var value = t ? read(UInt16(x)) : a
        let operand = groupOneOperand(opcode)
        value = or ? value | operand : value & operand
        if t {
            write(UInt16(x), value)
        } else {
            a = value
            setNZ(value)
        }
    }

    private func execute(_ opcode: UInt8) {
        switch opcode {
        case 0x78: setFlag(Self.statusI, true) // SEI
        case 0x58: setFlag(Self.statusI, false) // CLI
        case 0xD8: setFlag(Self.statusD, false) // CLD
        case 0x12: setFlag(Self.statusT, false) // CLT
        case 0x38: setFlag(Self.statusC, true) // SEC
        case 0x18: setFlag(Self.statusC, false) // CLC
        case 0xEA: break // NOP
        case 0x42: sleeping = true // STP
        case 0xA2, 0xA6, 0xAE, 0xB6, 0xBE: // LDX
            let value: UInt8
            switch opcode {
            case 0xA2: value = fetch()
            case 0xA6: value = read(UInt16(fetch()))
            case 0xB6: value = read(UInt16(fetch() &+ y))
            case 0xAE: value = read(fetch16())
            default: value = read(fetch16() &+ UInt16(y))
            }
            x = value
            setNZ(value)
        case 0xA0, 0xA4, 0xAC, 0xB4, 0xBC: // LDY
            let value: UInt8
            switch opcode {
            case 0xA0: value = fetch()
            case 0xA4: value = read(UInt16(fetch()))
            case 0xAC: value = read(fetch16())
            case 0xB4: value = read(UInt16(fetch() &+ x))
            default: value = read(fetch16() &+ UInt16(x))
            }
            y = value
            setNZ(value)
        case 0x9A: s = x // TXS
        case 0x8A: // TXA
            a = x
            setNZ(a)
        case 0xAA: // TAX
            x = a
            setNZ(x)
        case 0x81, 0x85, 0x8D, 0x91, 0x95, 0x99, 0x9D: // STA
            let address: UInt16
            switch opcode {
            case 0x85: address = UInt16(fetch())
            // (Not kept to page zero, as Nuked SC-55 has it.)
            case 0x95: address = UInt16(fetch()) + UInt16(x)
            case 0x8D: address = fetch16()
            case 0x9D: address = fetch16() &+ UInt16(x)
            case 0x99: address = fetch16() &+ UInt16(y)
            case 0x81: address = read16(UInt16(fetch() &+ x))
            default: address = read16(UInt16(fetch())) &+ UInt16(y)
            }
            write(address, a)
        case 0x86, 0x8E, 0x96: // STX
            let address: UInt16
            switch opcode {
            case 0x86: address = UInt16(fetch())
            case 0x8E: address = fetch16()
            // (X, not Y, and not kept to page zero, as Nuked SC-55 has it.)
            default: address = UInt16(fetch()) + UInt16(x)
            }
            write(address, x)
        case 0x84, 0x8C, 0x94: // STY
            let address: UInt16
            switch opcode {
            case 0x84: address = UInt16(fetch())
            case 0x8C: address = fetch16()
            default: address = UInt16(fetch() &+ x)
            }
            write(address, y)
        case 0xE8: // INX
            x &+= 1
            setNZ(x)
        case 0xC8: // INY
            y &+= 1
            setNZ(y)
        case 0x1A: // DEC A
            a &-= 1
            setNZ(a)
        case 0x3A: // INC A
            a &+= 1
            setNZ(a)
        case 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE: // DEC, INC
            let address: UInt16
            switch opcode & 0x1F {
            case 0x06: address = UInt16(fetch())
            case 0x16: address = UInt16(fetch() &+ x)
            case 0x0E: address = fetch16()
            default: address = fetch16() &+ UInt16(x)
            }
            var value = read(address)
            value = opcode < 0xE0 ? value &- 1 : value &+ 1
            write(address, value)
            setNZ(value)
        case 0xE0, 0xE4, 0xEC: // CPX
            let operand = opcode == 0xE0 ? fetch() : opcode == 0xE4 ? read(UInt16(fetch())) : read(fetch16())
            compare(x, operand)
        case 0xC0, 0xC4, 0xCC: // CPY
            let operand = opcode == 0xC0 ? fetch() : opcode == 0xC4 ? read(UInt16(fetch())) : read(fetch16())
            compare(y, operand)
        case 0xC1, 0xC5, 0xC9, 0xCD, 0xD1, 0xD5, 0xD9, 0xDD: // CMP
            compare(a, groupOneOperand(opcode))
        case 0xA1, 0xA5, 0xA9, 0xAD, 0xB1, 0xB5, 0xB9, 0xBD: // LDA
            let value = groupOneOperand(opcode)
            if sr & Self.statusT == 0 {
                a = value
                setNZ(value)
            } else {
                write(UInt16(x), value)
            }
        case 0x01, 0x05, 0x09, 0x0D, 0x11, 0x15, 0x19, 0x1D: logical(opcode, or: true) // ORA
        case 0x21, 0x25, 0x29, 0x2D, 0x31, 0x35, 0x39, 0x3D: logical(opcode, or: false) // AND
        case 0xF0: branch(if: sr & Self.statusZ != 0) // BEQ
        case 0xD0: branch(if: sr & Self.statusZ == 0) // BNE
        case 0x90: branch(if: sr & Self.statusC == 0) // BCC
        case 0xB0: branch(if: sr & Self.statusC != 0) // BCS
        case 0x10: branch(if: sr & Self.statusN == 0) // BPL
        case 0x80: branch(if: true) // BRA
        case 0x3C: // LDM
            let value = fetch()
            write(UInt16(fetch()), value)
        case 0x48: push(a) // PHA
        case 0x68: // PLA
            a = pop()
            setNZ(a)
        case 0x40: // RTI
            sr = pop()
            pc = UInt16(pop())
            pc |= UInt16(pop()) << 8
        case 0x60: // RTS
            pc = UInt16(pop())
            pc |= UInt16(pop()) << 8
        case 0x20, 0x02, 0x22: // JSR
            let target: UInt16
            switch opcode {
            case 0x20: target = fetch16()
            case 0x02: target = read16(UInt16(fetch()))
            default: target = 0xFF00 | UInt16(fetch())
            }
            push(UInt8(truncatingIfNeeded: pc >> 8))
            push(UInt8(truncatingIfNeeded: pc))
            pc = target
        case 0x4C: pc = fetch16() // JMP
        case 0x6C: pc = read16(fetch16())
        case 0xB2: pc = read16(UInt16(fetch()))
        default:
            switch opcode & 0x0F {
            case 0x03, 0x07: // BBS, BBC: a bit of the accumulator or of page zero
                let bit = (opcode >> 5) & 7
                let value = opcode & 4 != 0 ? read(UInt16(fetch())) : a
                let clearWanted = (opcode >> 4) & 1
                branch(if: (value >> bit) & 1 != clearWanted)
            case 0x0B, 0x0F: // SEB, CLB
                let bit: UInt8 = 1 << ((opcode >> 5) & 7)
                let clear = (opcode >> 4) & 1 != 0
                if opcode & 4 != 0 {
                    let address = UInt16(fetch())
                    let value = read(address)
                    write(address, clear ? value & ~bit : value | bit)
                } else {
                    a = clear ? a & ~bit : a | bit
                }
            // (Any other is one that Nuked SC-55 does not have: one byte that does nothing.)
            default: break
            }
        }
    }
}
