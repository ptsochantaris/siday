// Copyright (C) 2021, 2024 nukeykt; (C) 2024-2026 J.C. Moyer
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A Swift port of Nuked SC-55's emulation of the Sound Canvas's controller, a Hitachi H8/532 (mcu.cpp,
// mcu_interrupt.cpp and mcu_timer.cpp, as jcmoyer's fork of Nuked SC-55 keeps them with its original
// interpreter), free software under the GNU General Public License, version 2 or any later version (see
// THIRD-PARTY.md). Only what the SC-55 plays with is ported: not its display or buttons, nor the other models'
// sub-processor and boards.

/// The H8/532 of the SC-55: its registers, its memory and what is mapped into it, its timers, its serial
/// port (the MIDI in), its converter from analogue and its interrupts. It runs the firmware of the ROMs a
/// step at a time, an instruction to a step, and each step is counted as twelve of its cycles, as Nuked
/// SC-55 counts it; after each, the PCM chip and the timers are brought up to its time.
final class SC55MCU {
    // MARK: Registers

    /// The eight general registers, R0 to R7 (R7 the stack pointer).
    let r: UnsafeMutablePointer<UInt16>
    var r6: UInt16 {
        @inline(__always) get { r[6] }
        @inline(__always) set { r[6] = newValue }
    }

    var r7: UInt16 {
        @inline(__always) get { r[7] }
        @inline(__always) set { r[7] = newValue }
    }

    @exclusivity(unchecked) var pc: UInt16 = 0
    @exclusivity(unchecked) var sr: UInt16 = 0
    /// The page registers: code, data, extended, stack, and the base register of short addresses.
    @exclusivity(unchecked) var cp: UInt8 = 0, dp: UInt8 = 0, ep: UInt8 = 0, tp: UInt8 = 0, br: UInt8 = 0
    @exclusivity(unchecked) var sleeping = false
    /// Set by an instruction after which no interrupt is taken before the next (RTE, LDC and the like).
    @exclusivity(unchecked) var exceptionIgnored = false
    /// The exception waiting to be taken, or -1.
    @exclusivity(unchecked) var exceptionPending: Int = -1
    /// The interrupts asked for, a bit for each source (see `Interrupt`), and the TRAPA instructions'.
    @exclusivity(unchecked) var interruptsPending: UInt32 = 0
    @exclusivity(unchecked) var trapsPending: UInt16 = 0
    @exclusivity(unchecked) var cycles: UInt64 = 0

    static let statusMask: UInt16 = 0x870F
    static let statusT: UInt16 = 0x8000, statusN: UInt16 = 0x08, statusZ: UInt16 = 0x04, statusV: UInt16 = 0x02, statusC: UInt16 = 0x01

    // MARK: Memory

    let rom1: UnsafeMutablePointer<UInt8>
    let rom2: UnsafeMutablePointer<UInt8>
    let rom2Mask: UInt32
    /// The on-chip RAM (at 0xFB80) and the board's static RAM (at 0x8000 and on page 5).
    let ram: UnsafeMutablePointer<UInt8>
    let sram: UnsafeMutablePointer<UInt8>
    /// The on-chip devices' registers, 0xFF80 to 0xFFFF.
    let devices: UnsafeMutablePointer<UInt8>

    static let rom1Size = 0x8000, ramSize = 0x400, sramSize = 0x8000

    // The devices' registers, as offsets from 0xFF80.
    static let p9DDR = 0x7E, p9DR = 0x7F, p1CR = 0x7C, ramCR = 0x79
    static let ipra = 0x70, iprb = 0x71, iprc = 0x72, iprd = 0x73
    static let smr = 0x58, brr = 0x59, scr = 0x5A, tdr = 0x5B, ssr = 0x5C, rdr = 0x5D
    static let addrAH = 0x60, adcsr = 0x68, p7DR = 0x0E

    // MARK: Board

    let pcm: SC55PCM
    @exclusivity(unchecked) var ioSelect: UInt8 = 0
    /// The gate array's interrupt lines, and which it raises.
    @exclusivity(unchecked) var gateLines: UInt8 = 0
    @exclusivity(unchecked) var gateEnable: UInt8 = 0
    @exclusivity(unchecked) var gateTrigger: UInt8 = 0
    @exclusivity(unchecked) var lcdCounter = 0
    @exclusivity(unchecked) var analogReadFlag = false
    @exclusivity(unchecked) var analogEndTime: UInt64 = 0
    @exclusivity(unchecked) var serialStatusRead: UInt8 = 0

    // MARK: Serial port

    /// Bytes posted to the MIDI in, waiting for the serial port to take them.
    let uartBuffer: UnsafeMutablePointer<UInt8>
    static let uartBufferSize = 8192
    @exclusivity(unchecked) var uartWrite = 0, uartRead = 0
    @exclusivity(unchecked) var uartByte: UInt8 = 0
    @exclusivity(unchecked) var uartRxDelay: UInt64 = 0, uartTxDelay: UInt64 = 0

    // MARK: Operands of the instruction being run

    @exclusivity(unchecked) var operandType = 0
    @exclusivity(unchecked) var operandEA: UInt16 = 0
    @exclusivity(unchecked) var operandEP: UInt8 = 0
    @exclusivity(unchecked) var operandWord = false
    @exclusivity(unchecked) var operandReg = 0
    @exclusivity(unchecked) var operandData: UInt16 = 0
    @exclusivity(unchecked) var opcodeExtended = false

    static let direct = 0, indirect = 1, absolute = 2, immediate = 3

    // MARK: Timers

    /// The three 16-bit free-running timers and the 8-bit timer, each stepped when the count of half the
    /// processor's cycles passes its deadline, as jcmoyer's fork steps them. A tick that only counts is not
    /// made when it is due: the ticks are made, all at once, when one would match, overflow or raise an
    /// interrupt (`timerEvent`), or when the firmware reads or writes a timer.
    struct FreeRunningTimer {
        var deadline: UInt64 = 0
        var tcr: UInt8 = 0, tcsr: UInt8 = 0
        var frc: UInt16 = 0, ocra: UInt16 = 0xFFFF, ocrb: UInt16 = 0xFFFF, icr: UInt16 = 0
        var statusRead: UInt8 = 0
        var stride: UInt64 = 4
    }

    struct EightBitTimer {
        var deadline: UInt64 = .max
        var stride: UInt64 = 0
        var tcr: UInt8 = 0, tcsr: UInt8 = 0x10, tcora: UInt8 = 0xFF, tcorb: UInt8 = 0xFF, tcnt: UInt8 = 0
        var statusRead: UInt8 = 0
    }

    let frts: UnsafeMutablePointer<FreeRunningTimer>
    @exclusivity(unchecked) var tmr = EightBitTimer()
    @exclusivity(unchecked) var timerCycles: UInt64 = 0
    /// The deadline of the next tick that does more than count, of any timer.
    @exclusivity(unchecked) var timerEvent: UInt64 = 0
    @exclusivity(unchecked) var timerTemp: UInt8 = 0
    /// The SC-55's step tables, indexed by the clock-select bits.
    static let frtSteps: [UInt64] = [4, 8, 32, 4]
    static let tmrSteps: [UInt64] = [0, 8, 64, 1024, 0, 4, 4, 4]

    // MARK: Interrupt sources, in the order they are looked at

    enum Interrupt {
        static let nmi = 0, irq0 = 1, irq1 = 2
        static let frt0OCIA = 4, frt0OCIB = 5, frt0FOVI = 6
        static let frt1OCIA = 8, frt1OCIB = 9, frt1FOVI = 10
        static let frt2OCIA = 12, frt2OCIB = 13, frt2FOVI = 14
        static let timerCMIA = 15, timerCMIB = 16, timerOVI = 17
        static let analog = 18, uartRX = 19, uartTX = 20
    }

    static let exceptionAddressError = 0, exceptionInvalidInstruction = 1, exceptionTrace = 2

    init(rom1 rom1Data: [UInt8], rom2 rom2Data: [UInt8], pcm: SC55PCM) {
        r = .allocate(capacity: 8)
        r.initialize(repeating: 0, count: 8)
        let program = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.rom1Size)
        program.initialize(repeating: 0, count: Self.rom1Size)
        for i in 0 ..< min(rom1Data.count, Self.rom1Size) { program[i] = rom1Data[i] }
        rom1 = program
        let extra = UnsafeMutablePointer<UInt8>.allocate(capacity: rom2Data.count)
        for i in 0 ..< rom2Data.count { extra[i] = rom2Data[i] }
        rom2 = extra
        rom2Mask = UInt32(rom2Data.count - 1)
        ram = .allocate(capacity: Self.ramSize)
        ram.initialize(repeating: 0, count: Self.ramSize)
        sram = .allocate(capacity: Self.sramSize)
        sram.initialize(repeating: 0, count: Self.sramSize)
        devices = .allocate(capacity: 0x80)
        devices.initialize(repeating: 0, count: 0x80)
        uartBuffer = .allocate(capacity: Self.uartBufferSize)
        uartBuffer.initialize(repeating: 0, count: Self.uartBufferSize)
        frts = .allocate(capacity: 3)
        frts.initialize(repeating: FreeRunningTimer(), count: 3)
        self.pcm = pcm
        pcm.mcu = self
    }

    deinit {
        r.deallocate()
        rom1.deallocate()
        rom2.deallocate()
        ram.deallocate()
        sram.deallocate()
        devices.deallocate()
        uartBuffer.deallocate()
        frts.deallocate()
    }

    // MARK: Reset

    func reset() {
        r.update(repeating: 0, count: 8)
        sr = 0x700
        cp = 0; dp = 0; ep = 0; tp = 0; br = 0
        let address = read32(0)
        cp = UInt8(truncatingIfNeeded: address >> 16)
        pc = UInt16(truncatingIfNeeded: address)
        exceptionPending = -1
        resetDevices()
        gateEnable = 255
    }

    private func resetDevices() {
        let d = devices
        d[0x00] = 0x03; d[0x02] = 0; d[Self.p1CR] = 0x87
        d[0x01] = 0xE0; d[0x03] = 0xE0
        d[0x04] = 0; d[0x06] = 0
        d[0x05] = 0; d[0x07] = 0
        d[0x08] = 0; d[0x0A] = 0
        d[0x09] = 0xF0; d[0x0B] = 0xF0
        d[0x0C] = 0; d[0x0E] = 0
        d[0x0F] = 0
        d[Self.p9DDR] = 0; d[Self.p9DR] = 0
        frts.update(repeating: FreeRunningTimer(), count: 3)
        tmr = EightBitTimer()
        timerEvent = 0
        d[Self.rdr] = 0; d[Self.tdr] = 0xFF; d[Self.smr] = 0x04; d[Self.scr] = 0x0C; d[Self.ssr] = 0x87; d[Self.brr] = 0xFF
        for i in 0 ..< 9 { d[Self.addrAH + i] = 0 }
        d[Self.ipra] = 0; d[Self.iprb] = 0; d[Self.iprc] = 0; d[Self.iprd] = 0
        d[0x74] = 0; d[0x75] = 0; d[0x76] = 0; d[0x77] = 0
        d[0x78] = 0xF3
        d[Self.ramCR] = 0x80
    }

    // MARK: Registers by number

    @inline(__always) func register(_ n: Int) -> UInt16 { r[n] }

    @inline(__always) func setRegister(_ n: Int, _ value: UInt16) { r[n] = value }

    @inline(__always) func pageForRegister(_ n: Int) -> UInt8 {
        n >= 6 ? tp : n >= 4 ? ep : dp
    }

    // MARK: Memory map (the SC-55's)

    func read(_ address: UInt32) -> UInt8 {
        var addressROM = address & 0x3FFFF
        if address & 0x80000 != 0 { addressROM |= 0x40000 }
        let page = (address >> 16) & 0xF
        let a = address & 0xFFFF
        switch page {
        case 0:
            if a & 0x8000 == 0 { return rom1[Int(a & 0x7FFF)] }
            // (The static RAM first, as most reads are of it: the places below are each in their own range.)
            if a < 0xE000 { return sram[Int(a & 0x7FFF)] }
            if a >= 0xE000, a < 0xE040 { return pcm.read(a & 0x3F) }
            if a >= 0xFF80 { return deviceRead(Int(a & 0x7F)) }
            if a >= 0xFB80, a < 0xFF80, devices[Self.ramCR] & 0x80 != 0 { return ram[Int((a - 0xFB80) & 0x3FF)] }
            if a >= 0xF000, a < 0xF100 {
                // The buttons, read a row at a time; none is pressed.
                ioSelect = UInt8(a & 0xFF)
                return 0xFF
            }
            if a == 0xF106 {
                let value = gateTrigger
                gateTrigger = 0
                setInterrupt(Interrupt.irq1, false)
                return value
            }
            return 0xFF
        case 1, 2, 3, 4, 8, 9, 14, 15: return rom2[Int(addressROM & rom2Mask)]
        case 5: return sram[Int(a & 0x7FFF)]
        case 10, 11, 12, 13: return 0xFF
        default: return 0
        }
    }

    @inline(__always) func read16(_ address: UInt32) -> UInt16 {
        let a = address & ~1
        return UInt16(read(a)) << 8 | UInt16(read(a + 1))
    }

    func read32(_ address: UInt32) -> UInt32 {
        let a = address & ~3
        return UInt32(read(a)) << 24 | UInt32(read(a + 1)) << 16 | UInt32(read(a + 2)) << 8 | UInt32(read(a + 3))
    }

    func write(_ address: UInt32, _ value: UInt8) {
        let page = (address >> 16) & 0xF
        let a = address & 0xFFFF
        if page == 0 {
            guard a & 0x8000 != 0 else { return }
            if a < 0xE000 {
                sram[Int(a & 0x7FFF)] = value
            } else if a < 0xE040 {
                pcm.write(a & 0x3F, value)
            } else if a >= 0xFF80 {
                deviceWrite(Int(a & 0x7F), value)
            } else if a >= 0xFB80, a < 0xFF80, devices[Self.ramCR] & 0x80 != 0 {
                ram[Int((a - 0xFB80) & 0x3FF)] = value
            } else if a >= 0xF000, a < 0xF100 {
                ioSelect = UInt8(a & 0xFF)
            } else if a == 0xF105 || a == 0xF104 {
                // The display; its controller tells the gate array when it is done.
                lcdCounter = 500
            } else if a == 0xF107 {
                ioSelect = value
            }
        } else if page == 5 {
            sram[Int(a & 0x7FFF)] = value
        }
    }

    @inline(__always) func write16(_ address: UInt32, _ value: UInt16) {
        let a = address & ~1
        write(a, UInt8(truncatingIfNeeded: value >> 8))
        write(a + 1, UInt8(truncatingIfNeeded: value))
    }

    @inline(__always) func readCodeAdvance() -> UInt8 {
        let value = cp == 0 && pc < 0x8000 ? rom1[Int(pc)] : read(UInt32(cp) << 16 | UInt32(pc))
        pc &+= 1
        return value
    }

    // MARK: Devices

    private func deviceWrite(_ address: Int, _ data: UInt8) {
        if address >= 0x10, address < 0x40 {
            catchUpTimers(timerCycles)
            writeFRT(address, data)
            timerEvent = nextTimerEvent()
            return
        }
        if address >= 0x50, address < 0x55 {
            catchUpTimers(timerCycles)
            writeTMR(address, data)
            timerEvent = nextTimerEvent()
            return
        }
        switch address {
        case Self.adcsr:
            devices[address] &= ~0x7F
            devices[address] |= data & 0x7F
            if data & 0x80 == 0, analogReadFlag {
                devices[address] &= ~0x80
                setInterrupt(Interrupt.analog, false)
            }
            if data & 0x40 == 0 { setInterrupt(Interrupt.analog, false) }
            return
        case Self.ssr:
            if data & 0x80 == 0, serialStatusRead & 0x80 != 0 {
                devices[address] &= ~0x80
                uartTxDelay = cycles &+ 3000
                setInterrupt(Interrupt.uartTX, false)
            }
            if data & 0x40 == 0, serialStatusRead & 0x40 != 0 {
                uartRxDelay = cycles &+ 3000
                devices[address] &= ~0x40
                setInterrupt(Interrupt.uartRX, false)
            }
            if data & 0x20 == 0, serialStatusRead & 0x20 != 0 { devices[address] &= ~0x20 }
            if data & 0x10 == 0, serialStatusRead & 0x10 != 0 { devices[address] &= ~0x10 }
        default: break
        }
        devices[address] = data
    }

    private func deviceRead(_ address: Int) -> UInt8 {
        if address >= 0x10, address < 0x40 {
            catchUpTimers(timerCycles)
            return readFRT(address)
        }
        if address >= 0x50, address < 0x55 {
            catchUpTimers(timerCycles)
            return readTMR(address)
        }
        switch address {
        case Self.adcsr:
            analogReadFlag = devices[address] & 0x80 != 0
            return devices[address]
        case Self.ssr:
            serialStatusRead = devices[address]
            return devices[address]
        case Self.rdr: return uartByte
        case 0x00: return 0xFF
        case Self.p7DR: return 0xFF
        case Self.p9DR:
            // The SC-55's configuration pins read 0 where they are inputs.
            let direction = devices[Self.p9DDR]
            return devices[Self.p9DR] & direction
        default: return devices[address]
        }
    }

    /// The analogue inputs: the battery on pin 7, nothing on the others (the remote control unit's pins).
    private func analogSample(_ channel: Int) {
        let value: UInt16 = channel == 7 ? 0x2A0 : 0
        let dest = (channel << 1) & 6
        devices[Self.addrAH + dest] = UInt8(truncatingIfNeeded: value >> 2)
        devices[Self.addrAH + 1 + dest] = UInt8(truncatingIfNeeded: (value << 6) & 0xC0)
    }

    @inline(__always) private func updateAnalog() {
        let control = devices[Self.adcsr]
        guard control & 0x20 != 0 else {
            analogEndTime = 0
            return
        }
        if analogEndTime == 0 {
            analogEndTime = cycles &+ 200
        } else if analogEndTime < cycles {
            if control & 16 != 0 {
                let base = Int(control & 4)
                for i in 0 ... Int(control & 3) { analogSample(base + i) }
                analogEndTime = cycles &+ 200
            } else {
                analogSample(Int(control & 7))
                devices[Self.adcsr] &= ~0x20
                analogEndTime = 0
            }
            devices[Self.adcsr] |= 0x80
            if control & 0x40 != 0 { setInterrupt(Interrupt.analog, true) }
        }
    }

    func setGateLine(_ line: Int, _ value: Bool) {
        let bit: UInt8 = 1 << line
        if value, gateLines & bit == 0, gateEnable & bit != 0 { gateTrigger = UInt8(line) }
        gateLines = value ? gateLines | bit : gateLines & ~bit
        setInterrupt(Interrupt.irq1, gateTrigger != 0)
    }

    // MARK: Serial port

    /// Hands a byte to the MIDI in.
    func post(_ byte: UInt8) {
        uartBuffer[uartWrite] = byte
        uartWrite = (uartWrite + 1) % Self.uartBufferSize
    }

    @inline(__always) private func updateSerial() {
        let control = devices[Self.scr]
        if control & 16 != 0, uartWrite != uartRead, devices[Self.ssr] & 0x40 == 0, cycles >= uartRxDelay {
            uartByte = uartBuffer[uartRead]
            uartRead = (uartRead + 1) % Self.uartBufferSize
            devices[Self.ssr] |= 0x40
            setInterrupt(Interrupt.uartRX, control & 0x40 != 0)
        }
        if control & 32 != 0, devices[Self.ssr] & 0x80 == 0, cycles >= uartTxDelay {
            devices[Self.ssr] |= 0x80
            setInterrupt(Interrupt.uartTX, control & 0x80 != 0)
        }
    }

    // MARK: Interrupts

    @inline(__always) func setInterrupt(_ source: Int, _ on: Bool) {
        if on { interruptsPending |= 1 << UInt32(source) } else { interruptsPending &= ~(1 << UInt32(source)) }
    }

    @inline(__always) func raise(_ exception: Int) { exceptionPending = exception }

    private func startVector(_ vector: Int, mask: Int) {
        let address = read32(UInt32(vector * 4))
        push(pc)
        push(UInt16(cp))
        push(sr)
        sr &= ~Self.statusT
        if mask >= 0 {
            sr &= ~0x700
            sr |= UInt16(mask) << 8
        }
        sleeping = false
        cp = UInt8(truncatingIfNeeded: address >> 16)
        pc = UInt16(truncatingIfNeeded: address)
    }

    /// The vector and level of an interrupt source, by the priority registers; nil for one that is masked
    /// off or has no vector.
    private func vectorAndLevel(_ source: Int) -> (Int, Int)? {
        let d = devices
        switch source {
        case Interrupt.irq0: return d[Self.p1CR] & 0x20 == 0 ? nil : (32, Int(d[Self.ipra] >> 4) & 7)
        case Interrupt.irq1: return d[Self.p1CR] & 0x40 == 0 ? nil : (33, Int(d[Self.ipra]) & 7)
        case Interrupt.frt0OCIA: return (37, Int(d[Self.iprb] >> 4) & 7)
        case Interrupt.frt0OCIB: return (38, Int(d[Self.iprb] >> 4) & 7)
        case Interrupt.frt0FOVI: return (39, Int(d[Self.iprb] >> 4) & 7)
        case Interrupt.frt1OCIA: return (41, Int(d[Self.iprb]) & 7)
        case Interrupt.frt1OCIB: return (42, Int(d[Self.iprb]) & 7)
        case Interrupt.frt1FOVI: return (43, Int(d[Self.iprb]) & 7)
        case Interrupt.frt2OCIA: return (45, Int(d[Self.iprc] >> 4) & 7)
        case Interrupt.frt2OCIB: return (46, Int(d[Self.iprc] >> 4) & 7)
        case Interrupt.frt2FOVI: return (47, Int(d[Self.iprc] >> 4) & 7)
        case Interrupt.timerCMIA: return (48, Int(d[Self.iprc]) & 7)
        case Interrupt.timerCMIB: return (49, Int(d[Self.iprc]) & 7)
        case Interrupt.timerOVI: return (50, Int(d[Self.iprc]) & 7)
        case Interrupt.analog: return (56, Int(d[Self.iprd]) & 7)
        case Interrupt.uartRX: return (53, Int(d[Self.iprd] >> 4) & 7)
        case Interrupt.uartTX: return (54, Int(d[Self.iprd] >> 4) & 7)
        default: return nil
        }
    }

    /// True if an interrupt would be taken at the start of the next step (see `handleInterrupts`).
    @inline(__always) private func interruptDue() -> Bool {
        if trapsPending != 0 || exceptionPending >= 0 || interruptsPending & 1 != 0 { return true }
        let mask = Int(sr >> 8) & 7
        var pending = interruptsPending
        while pending != 0 {
            let source = pending.trailingZeroBitCount
            pending &= pending - 1
            if let (_, level) = vectorAndLevel(source), mask < level { return true }
        }
        return false
    }

    private func handleInterrupts() {
        if trapsPending != 0 {
            let n = trapsPending.trailingZeroBitCount
            trapsPending &= ~(1 << UInt16(n))
            startVector(16 + n, mask: -1)
            return
        }
        if exceptionPending >= 0 {
            switch exceptionPending {
            case Self.exceptionAddressError: startVector(8, mask: -1)
            case Self.exceptionInvalidInstruction: startVector(2, mask: -1)
            default: startVector(9, mask: -1)
            }
            exceptionPending = -1
            return
        }
        if interruptsPending & 1 != 0 {
            startVector(11, mask: 7)
            return
        }
        let mask = Int(sr >> 8) & 7
        var pending = interruptsPending
        while pending != 0 {
            let source = pending.trailingZeroBitCount
            pending &= pending - 1
            if let (vector, level) = vectorAndLevel(source), mask < level {
                startVector(vector, mask: level)
                return
            }
        }
    }

    // MARK: Stack

    @inline(__always) func push(_ value: UInt16) {
        if r7 & 1 != 0 { raise(Self.exceptionAddressError) }
        r7 &-= 2
        write16(UInt32(r7), value)
    }

    @inline(__always) func pop() -> UInt16 {
        if r7 & 1 != 0 { raise(Self.exceptionAddressError) }
        let value = read16(UInt32(r7))
        r7 &+= 2
        return value
    }

    // MARK: Running

    /// One step: an interrupt taken if one is due, one instruction (unless asleep), and the rest of the
    /// board brought up to the processor's time. Asleep, the steps before the next in which anything can
    /// happen are made first, all at once, up to `most` in all (see `quietSteps`).
    /// - Returns: how many steps were made.
    @inline(__always) @discardableResult func step(most: Int = .max) -> Int {
        var made = 1
        if sleeping, !exceptionIgnored, most > 1 {
            let quiet = min(quietSteps(), UInt64(most - 1))
            if quiet > 0 {
                cycles &+= 12 * quiet
                timerCycles = cycles / 2
                if lcdCounter != 0 { lcdCounter -= Int(quiet) }
                made += Int(quiet)
            }
        }
        if exceptionIgnored {
            exceptionIgnored = false
        } else if trapsPending != 0 || exceptionPending >= 0 || interruptsPending != 0 {
            handleInterrupts()
        }
        if !sleeping {
            execute()
            if sr & Self.statusT != 0 { raise(Self.exceptionTrace) }
        }
        cycles &+= 12
        if pcm.cycles < cycles { pcm.update(to: cycles) }
        clockTimers()
        updateSerial()
        updateAnalog()
        if lcdCounter != 0 {
            lcdCounter -= 1
            if lcdCounter == 0 {
                setGateLine(1, false)
                setGateLine(1, true)
            }
        }
        return made
    }

    /// While the processor sleeps and no interrupt is due, how many steps from now do nothing but count
    /// its cycles: those before the PCM chip's next round, the timers' next tick that does more than count
    /// (`timerEvent`), the serial port's taking or sending a byte, the analogue converter's finishing, and
    /// the display's telling the gate array it is done. Nothing else changes while it sleeps.
    @inline(__always) private func quietSteps() -> UInt64 {
        guard !interruptDue() else { return 0 }
        // (The cycles are a multiple of twelve, and the timers count half of them.)
        guard pcm.cycles >= cycles, timerEvent >= cycles / 2 else { return 0 }
        var quiet = min((pcm.cycles - cycles) / 12, (timerEvent - cycles / 2) / 6)
        let control = devices[Self.scr]
        if control & 16 != 0, uartWrite != uartRead, devices[Self.ssr] & 0x40 == 0 {
            guard uartRxDelay > cycles else { return 0 }
            quiet = min(quiet, (uartRxDelay - cycles - 1) / 12)
        }
        if control & 32 != 0, devices[Self.ssr] & 0x80 == 0 {
            guard uartTxDelay > cycles else { return 0 }
            quiet = min(quiet, (uartTxDelay - cycles - 1) / 12)
        }
        if devices[Self.adcsr] & 0x20 != 0 {
            guard analogEndTime != 0, analogEndTime >= cycles else { return 0 }
            quiet = min(quiet, (analogEndTime - cycles) / 12)
        }
        if lcdCounter != 0 { quiet = min(quiet, UInt64(lcdCounter - 1)) }
        return quiet
    }

    // MARK: Timers

    @inline(__always) private static func alignForward(_ value: UInt64, _ interval: UInt64) -> UInt64 {
        (value &+ (interval - 1)) & ~(interval - 1)
    }

    private func writeFRT(_ address: Int, _ data: UInt8) {
        let t = (address >> 4) - 1
        guard t >= 0, t <= 2 else { return }
        let frt = frts + t
        switch address & 0x0F {
        case 0x00:
            frt.pointee.tcr = data
            let stride = Self.frtSteps[Int(data & 3)]
            frt.pointee.deadline = Self.alignForward(timerCycles, stride)
            frt.pointee.stride = stride
        case 0x01:
            frt.pointee.tcsr &= ~0xF
            frt.pointee.tcsr |= data & 0xF
            if data & 0x10 == 0, frt.pointee.statusRead & 0x10 != 0 {
                frt.pointee.tcsr &= ~0x10
                frt.pointee.statusRead &= ~0x10
                setInterrupt(Interrupt.frt0FOVI + t * 4, false)
            }
            if data & 0x20 == 0, frt.pointee.statusRead & 0x20 != 0 {
                frt.pointee.tcsr &= ~0x20
                frt.pointee.statusRead &= ~0x20
                setInterrupt(Interrupt.frt0OCIA + t * 4, false)
            }
            if data & 0x40 == 0, frt.pointee.statusRead & 0x40 != 0 {
                frt.pointee.tcsr &= ~0x40
                frt.pointee.statusRead &= ~0x40
                setInterrupt(Interrupt.frt0OCIB + t * 4, false)
            }
        case 0x02, 0x04, 0x06, 0x08: timerTemp = data
        case 0x03: frt.pointee.frc = UInt16(timerTemp) << 8 | UInt16(data)
        case 0x05: frt.pointee.ocra = UInt16(timerTemp) << 8 | UInt16(data)
        case 0x07: frt.pointee.ocrb = UInt16(timerTemp) << 8 | UInt16(data)
        case 0x09: frt.pointee.icr = UInt16(timerTemp) << 8 | UInt16(data)
        default: break
        }
    }

    private func readFRT(_ address: Int) -> UInt8 {
        let t = (address >> 4) - 1
        guard t >= 0, t <= 2 else { return 0xFF }
        let frt = frts + t
        switch address & 0x0F {
        case 0x00: return frt.pointee.tcr
        case 0x01:
            frt.pointee.statusRead |= frt.pointee.tcsr & 0xF0
            return frt.pointee.tcsr
        case 0x02:
            timerTemp = UInt8(truncatingIfNeeded: frt.pointee.frc)
            return UInt8(truncatingIfNeeded: frt.pointee.frc >> 8)
        case 0x04:
            timerTemp = UInt8(truncatingIfNeeded: frt.pointee.ocra)
            return UInt8(truncatingIfNeeded: frt.pointee.ocra >> 8)
        case 0x06:
            timerTemp = UInt8(truncatingIfNeeded: frt.pointee.ocrb)
            return UInt8(truncatingIfNeeded: frt.pointee.ocrb >> 8)
        case 0x08:
            timerTemp = UInt8(truncatingIfNeeded: frt.pointee.icr)
            return UInt8(truncatingIfNeeded: frt.pointee.icr >> 8)
        case 0x03, 0x05, 0x07, 0x09: return timerTemp
        default: return 0xFF
        }
    }

    private func writeTMR(_ address: Int, _ data: UInt8) {
        switch address {
        case 0x50:
            tmr.tcr = data
            let stride = Self.tmrSteps[Int(data & 7)]
            tmr.deadline = stride == 0 ? .max : Self.alignForward(timerCycles, stride)
            tmr.stride = stride
        case 0x51:
            tmr.tcsr &= ~0xF
            tmr.tcsr |= data & 0xF
            if data & 0x20 == 0, tmr.statusRead & 0x20 != 0 {
                tmr.tcsr &= ~0x20
                tmr.statusRead &= ~0x20
                setInterrupt(Interrupt.timerOVI, false)
            }
            if data & 0x40 == 0, tmr.statusRead & 0x40 != 0 {
                tmr.tcsr &= ~0x40
                tmr.statusRead &= ~0x40
                setInterrupt(Interrupt.timerCMIA, false)
            }
            if data & 0x80 == 0, tmr.statusRead & 0x80 != 0 {
                tmr.tcsr &= ~0x80
                tmr.statusRead &= ~0x80
                setInterrupt(Interrupt.timerCMIB, false)
            }
        case 0x52: tmr.tcora = data
        case 0x53: tmr.tcorb = data
        case 0x54: tmr.tcnt = data
        default: break
        }
    }

    private func readTMR(_ address: Int) -> UInt8 {
        switch address {
        case 0x50: return tmr.tcr
        case 0x51:
            tmr.statusRead |= tmr.tcsr & 0xE0
            return tmr.tcsr
        case 0x52: return tmr.tcora
        case 0x53: return tmr.tcorb
        case 0x54: return tmr.tcnt
        default: return 0xFF
        }
    }

    private func clockFRT(_ n: Int) {
        let frt = frts + n
        let matchA = frt.pointee.frc == frt.pointee.ocra, matchB = frt.pointee.frc == frt.pointee.ocrb
        if frt.pointee.tcsr & 0x01 != 0, matchA {
            frt.pointee.frc = 0
        } else {
            frt.pointee.frc &+= 1
            if frt.pointee.frc == 0 { frt.pointee.tcsr |= 0x10 }
        }
        if matchA { frt.pointee.tcsr |= 0x20 }
        if matchB { frt.pointee.tcsr |= 0x40 }
        let tcr = frt.pointee.tcr, tcsr = frt.pointee.tcsr
        if tcr & 0x10 != 0, tcsr & 0x10 != 0 { setInterrupt(Interrupt.frt0FOVI + n * 4, true) }
        if tcr & 0x20 != 0, tcsr & 0x20 != 0 { setInterrupt(Interrupt.frt0OCIA + n * 4, true) }
        if tcr & 0x40 != 0, tcsr & 0x40 != 0 { setInterrupt(Interrupt.frt0OCIB + n * 4, true) }
    }

    private func clockTMR() {
        let matchA = tmr.tcnt == tmr.tcora, matchB = tmr.tcnt == tmr.tcorb
        let clear = tmr.tcr & 0x18
        if clear == 0x08, matchA {
            tmr.tcnt = 0
        } else if clear == 0x10, matchB {
            tmr.tcnt = 0
        } else {
            tmr.tcnt &+= 1
            if tmr.tcnt == 0 { tmr.tcsr |= 0x20 }
        }
        if matchA { tmr.tcsr |= 0x40 }
        if matchB { tmr.tcsr |= 0x80 }
        if tmr.tcr & 0x20 != 0, tmr.tcsr & 0x20 != 0 { setInterrupt(Interrupt.timerOVI, true) }
        if tmr.tcr & 0x40 != 0, tmr.tcsr & 0x40 != 0 { setInterrupt(Interrupt.timerCMIA, true) }
        if tmr.tcr & 0x80 != 0, tmr.tcsr & 0x80 != 0 { setInterrupt(Interrupt.timerCMIB, true) }
    }

    @inline(__always) private func clockTimers() {
        let target = cycles / 2
        timerCycles = target
        if timerEvent < target { catchUpTimers(target) }
    }

    /// Makes every tick due before `target`: those that only count all at once, the others one by one.
    private func catchUpTimers(_ target: UInt64) {
        for n in 0 ..< 3 {
            let frt = frts + n
            while frt.pointee.deadline < target {
                let stride = frt.pointee.stride
                let due = (target - frt.pointee.deadline + stride - 1) / stride
                let quiet = UInt64(quietTicks(frt: n))
                if quiet >= due {
                    frt.pointee.frc &+= UInt16(truncatingIfNeeded: due)
                    frt.pointee.deadline &+= due * stride
                    break
                }
                frt.pointee.frc &+= UInt16(truncatingIfNeeded: quiet)
                frt.pointee.deadline &+= quiet * stride
                clockFRT(n)
                frt.pointee.deadline &+= stride
            }
        }
        while tmr.deadline < target {
            let stride = tmr.stride
            let due = (target - tmr.deadline + stride - 1) / stride
            if let period = quietCycleTMR() {
                tmr.tcnt = UInt8(truncatingIfNeeded: (UInt64(tmr.tcnt) + due) % period)
                tmr.deadline &+= due * stride
                break
            }
            let quiet = UInt64(quietTicksTMR())
            if quiet >= due {
                tmr.tcnt &+= UInt8(truncatingIfNeeded: due)
                tmr.deadline &+= due * stride
                break
            }
            tmr.tcnt &+= UInt8(truncatingIfNeeded: quiet)
            tmr.deadline &+= quiet * stride
            clockTMR()
            tmr.deadline &+= stride
        }
        timerEvent = nextTimerEvent()
    }

    /// How many of a free-running timer's next ticks only count: before the one at which it matches either
    /// compare register or overflows, or none if a flag it has set is to raise an interrupt not yet raised.
    @inline(__always) private func quietTicks(frt n: Int) -> UInt16 {
        let frt = frts[n]
        let raising = frt.tcr & frt.tcsr
        if raising & 0x10 != 0, interruptsPending & (1 << UInt32(Interrupt.frt0FOVI + n * 4)) == 0 { return 0 }
        if raising & 0x20 != 0, interruptsPending & (1 << UInt32(Interrupt.frt0OCIA + n * 4)) == 0 { return 0 }
        if raising & 0x40 != 0, interruptsPending & (1 << UInt32(Interrupt.frt0OCIB + n * 4)) == 0 { return 0 }
        return min(frt.ocra &- frt.frc, frt.ocrb &- frt.frc, 0xFFFF &- frt.frc)
    }

    /// The same for the 8-bit timer.
    @inline(__always) private func quietTicksTMR() -> UInt8 {
        let raising = tmr.tcr & tmr.tcsr
        if raising & 0x20 != 0, interruptsPending & (1 << UInt32(Interrupt.timerOVI)) == 0 { return 0 }
        if raising & 0x40 != 0, interruptsPending & (1 << UInt32(Interrupt.timerCMIA)) == 0 { return 0 }
        if raising & 0x80 != 0, interruptsPending & (1 << UInt32(Interrupt.timerCMIB)) == 0 { return 0 }
        return min(tmr.tcora &- tmr.tcnt, tmr.tcorb &- tmr.tcnt, 0xFF &- tmr.tcnt)
    }

    /// The length of the 8-bit timer's cycle, if it is counting round from 0 to its first compare register
    /// and back to 0 and each time round only sets flags that are already set and raises no interrupt that
    /// is not raised already: then its count is all that changes. (The firmware sets it so, to clear on a
    /// match every few ticks, its flag long since set.)
    @inline(__always) private func quietCycleTMR() -> UInt64? {
        guard tmr.tcr & 0x18 == 0x08, tmr.tcnt <= tmr.tcora, tmr.tcsr & 0x40 != 0,
              tmr.tcorb > tmr.tcora || tmr.tcsr & 0x80 != 0 else { return nil }
        let raising = tmr.tcr & tmr.tcsr
        if raising & 0x20 != 0, interruptsPending & (1 << UInt32(Interrupt.timerOVI)) == 0 { return nil }
        if raising & 0x40 != 0, interruptsPending & (1 << UInt32(Interrupt.timerCMIA)) == 0 { return nil }
        if raising & 0x80 != 0, interruptsPending & (1 << UInt32(Interrupt.timerCMIB)) == 0 { return nil }
        return UInt64(tmr.tcora) + 1
    }

    /// The deadline of the next tick, of any timer, that does more than count.
    private func nextTimerEvent() -> UInt64 {
        var next = UInt64.max
        for n in 0 ..< 3 {
            let frt = frts[n]
            next = min(next, frt.deadline &+ UInt64(quietTicks(frt: n)) * frt.stride)
        }
        if tmr.stride != 0, quietCycleTMR() == nil { next = min(next, tmr.deadline &+ UInt64(quietTicksTMR()) * tmr.stride) }
        return next
    }
}
