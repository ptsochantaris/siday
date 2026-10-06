// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Start-up state, ROM stand-ins and timing rules follow libsidplayfp (GPL-2.0-or-later; see THIRD-PARTY.md).

import Foundation

/// The parts of a C64 a SID tune can see: RAM, the bank switch at $01, stand-ins for the BASIC and KERNAL
/// ROMs, both CIAs, the VIC's raster counter and interrupt, and the SID. No real ROM images are needed.
///
/// The CPU makes one bus access per cycle, so this class is also the clock: every read or write advances
/// time by one cycle and runs whatever timer or raster events fall due.
final class C64Machine: MOS6510Bus {
    let ram: UnsafeMutablePointer<UInt8>
    private let kernal: UnsafeMutablePointer<UInt8>
    private let colorRAM: UnsafeMutablePointer<UInt8>
    private let vicRegisters: UnsafeMutablePointer<UInt8>

    private(set) var clock = 0
    private var nextEvent = Int.max

    // Bank switching, decoded from the processor port.
    private var portData: UInt8 = 0x37
    private var portDirection: UInt8 = 0x2F
    private var basicVisible = true
    private var kernalVisible = true
    private var ioVisible = true

    // Interrupt lines.
    private var irqLine = false
    private(set) var irqSampled = false
    private var nmiLatch = false
    /// The NMI latch as it stood one cycle ago; like IRQ, an edge in the last cycle of an instruction is
    /// only acted on after the next one.
    private var nmiSampled = false

    private var cia1: CIA
    private var cia2: CIA

    // VIC raster.
    let cyclesPerLine: Int
    let linesPerFrame: Int
    private var rasterCompare = 0
    private var vicInterruptFlags: UInt8 = 0
    private var vicInterruptMask: UInt8 = 0
    private var nextRasterEvent = Int.max
    /// Cycle at which the next scanline reaches the point where the VIC may halt the CPU.
    private var nextBadLineCheck = 0

    // SID and its output. Exactly one of the two engines exists.
    private let residfp: UnsafeMutablePointer<ReSIDfpChip>?
    private let resid: UnsafeMutablePointer<SIDChip>?
    private var sidClock = 0
    private let samples: UnsafeMutablePointer<Int16>
    private let sampleCapacity = 16384
    private(set) var sampleCount = 0

    /// Optional log of SID writes as (cycle, register, value), for comparison against reference players.
    var writeLog: [(Int, UInt8, UInt8)]?
    /// Optional record of the first value read from each I/O or ROM address, for diagnosing tunes that
    /// depend on hardware or ROM contents.
    var hardwareReads: [UInt16: UInt8]?

    init(clockHz: Double, ntsc: Bool, model: SIDModel, engine: SIDEngineChoice = .residfp, filterCurve: Double = 0.5) {
        ram = .allocate(capacity: 65536)
        kernal = .allocate(capacity: 8192)
        colorRAM = .allocate(capacity: 1024)
        vicRegisters = .allocate(capacity: 64)
        samples = .allocate(capacity: sampleCapacity)
        cyclesPerLine = ntsc ? 65 : 63
        linesPerFrame = ntsc ? 263 : 312
        cia1 = CIA(clockHz: clockHz)
        cia2 = CIA(clockHz: clockHz)
        switch engine {
        case .residfp:
            let chip = UnsafeMutablePointer<ReSIDfpChip>.allocate(capacity: 1)
            chip.initialize(to: ReSIDfpChip(model: model, clockHz: clockHz, sampleRate: Double(outputSampleRate), sampling: .resample))
            if filterCurve != 0.5 { chip.pointee.setFilter6581Curve(min(max(filterCurve, 0), 1)) }
            residfp = chip
            resid = nil
        case .resid:
            let chip = UnsafeMutablePointer<SIDChip>.allocate(capacity: 1)
            chip.initialize(to: SIDChip(model: model, clockHz: clockHz, sampleRate: Double(outputSampleRate)))
            resid = chip
            residfp = nil
        }
        buildKernalStub()
        reset(booted: false)
    }

    deinit {
        if let residfp {
            residfp.pointee.deallocate()
            residfp.deinitialize(count: 1)
            residfp.deallocate()
        }
        if let resid {
            resid.pointee.deallocate()
            resid.deinitialize(count: 1)
            resid.deallocate()
        }
        ram.deallocate()
        kernal.deallocate()
        colorRAM.deallocate()
        vicRegisters.deallocate()
        samples.deallocate()
    }

    /// A minimal KERNAL: the interrupt entry and exit paths tunes rely on, and RTS everywhere else.
    /// The main paths are the ones libsidplayfp's ROM-less stub provides, with the same instructions, so
    /// interrupt timing matches the player tunes are tested against. The extra exits are for tunes that
    /// jump into the middle of the real handlers.
    private func buildKernalStub() {
        kernal.initialize(repeating: 0x60, count: 8192)
        func put(_ address: Int, _ bytes: [UInt8]) {
            for (i, b) in bytes.enumerated() { kernal[address - 0xE000 + i] = b }
        }
        let leaveInterrupt: [UInt8] = [0x68, 0xA8, 0x68, 0xAA, 0x68, 0x40] // PLA TAY PLA TAX PLA RTI
        // $EA31: the standard IRQ handler, here just its exit: acknowledge CIA 1 and return.
        put(0xEA31, [0x4C, 0x7E, 0xEA]) // JMP $EA7E
        put(0xEA34, [UInt8](repeating: 0xEA, count: 0xEA7E - 0xEA34)) // entries part-way in slide down to the exit
        put(0xEA7E, [0x0C, 0x0D, 0xDC]) // NOP $DC0D: a read that acknowledges the timer interrupt
        put(0xEA81, leaveInterrupt)
        put(0xFCE2, [0x02]) // reset: halt
        // $FE43: NMI entry. $FE47: the standard NMI handler, which here returns at once.
        put(0xFE43, [0x78, 0x6C, 0x18, 0x03]) // SEI, JMP ($0318)
        put(0xFE47, [0x40]) // RTI
        put(0xFE48, [UInt8](repeating: 0xEA, count: 0xFEBC - 0xFE48))
        put(0xFE66, [0x4C, 0x81, 0xEA]) // BRK and warm start: leave the interrupt
        put(0xFEBC, leaveInterrupt)
        // $FF48: IRQ/BRK entry.
        put(0xFF48, [0x48, 0x8A, 0x48, 0x98, 0x48, 0x6C, 0x14, 0x03]) // PHA TXA PHA TYA PHA, JMP ($0314)
        put(0xFFFA, [0x43, 0xFE, 0xE2, 0xFC, 0x48, 0xFF])
    }

    /// Returns the machine to its power-on state. Memory starts with the pattern C64 RAM chips typically
    /// power up with (as VICE and libsidplayfp model it) and a cleared first kilobyte; `booted` then fills
    /// that kilobyte the way the KERNAL and BASIC leave it, which is what an RSID tune expects to find.
    func reset(booted: Bool) {
        var fill: UInt8 = 0x00
        for block in stride(from: 0, to: 0x10000, by: 0x4000) {
            (ram + block).initialize(repeating: fill, count: 0x4000)
            fill = ~fill
            for i in stride(from: 0x02, to: 0x4000, by: 0x08) {
                (ram + block + i).initialize(repeating: fill, count: 4)
            }
        }
        ram.initialize(repeating: 0, count: 0x400)
        if booted {
            for (i, byte) in c64PowerOnMemory.enumerated() { ram[i] = byte }
        }
        colorRAM.initialize(repeating: 0, count: 1024)
        vicRegisters.initialize(repeating: 0, count: 64)
        clock = 0
        nextBadLineCheck = 12
        portData = 0x37
        portDirection = 0x2F
        updateBanking()
        irqLine = false
        irqSampled = false
        nmiLatch = false
        nmiSampled = false
        let clockHz = Double(cia1.cyclesPerTenth * 10)
        cia1 = CIA(clockHz: clockHz)
        cia2 = CIA(clockHz: clockHz)
        vicRegisters[0x11] = 0x1B
        rasterCompare = 0
        vicInterruptFlags = 0
        vicInterruptMask = 0
        residfp?.pointee.reset()
        resid?.pointee.reset()
        sidClock = 0
        sampleCount = 0
        writeLog = writeLog == nil ? nil : []

        scheduleRaster()
        reschedule()
    }

    // MARK: Clock and events

    private func updateBanking() {
        // Port bits configured as inputs read high.
        let port = (portData | ~portDirection) & 0x07
        let loram = port & 1 != 0, hiram = port & 2 != 0, charen = port & 4 != 0
        basicVisible = loram && hiram
        kernalVisible = hiram
        ioVisible = charen && (loram || hiram)
    }

    @inline(__always) private func currentRaster() -> Int {
        (clock / cyclesPerLine) % linesPerFrame
    }

    private func scheduleRaster() {
        guard rasterCompare < linesPerFrame else {
            nextRasterEvent = Int.max
            return
        }
        let frameCycles = cyclesPerLine * linesPerFrame
        let frameStart = clock - clock % frameCycles
        var at = frameStart + rasterCompare * cyclesPerLine
        if at <= clock { at += frameCycles }
        nextRasterEvent = at
    }

    private func reschedule() {
        nextEvent = min(min(nextRasterEvent, nextBadLineCheck), min(cia1.nextEvent, cia2.nextEvent))
    }

    private func updateInterruptLines() {
        irqLine = cia1.interruptLine || (vicInterruptFlags & vicInterruptMask & 0x0F) != 0
    }

    private func runEvents() {
        if clock >= nextBadLineCheck {
            // With the display on, every eighth line of the text area is a "bad line": the VIC takes the
            // bus to fetch character data and the CPU stands still for about 40 cycles. Time passes for
            // the timers and the SID, so code that waits in loops runs that much slower.
            let line = (nextBadLineCheck / cyclesPerLine) % linesPerFrame
            nextBadLineCheck += cyclesPerLine
            let control = Int(vicRegisters[0x11])
            if control & 0x10 != 0, line >= 0x30, line <= 0xF7, line & 7 == control & 7 {
                clock += 40
            }
        }
        if clock >= nextRasterEvent {
            vicInterruptFlags |= 0x01
            nextRasterEvent += cyclesPerLine * linesPerFrame
        }
        cia1.runEvents(clock)
        let nmiBefore = cia2.interruptLine
        cia2.runEvents(clock)
        if cia2.interruptLine, !nmiBefore { nmiLatch = true }
        updateInterruptLines()
        reschedule()
    }

    @inline(__always) private func tick() {
        irqSampled = irqLine
        nmiSampled = nmiLatch
        clock &+= 1
        if clock >= nextEvent { runEvents() }
    }

    func takeNMI() -> Bool {
        guard nmiSampled else { return false }
        nmiLatch = false
        nmiSampled = false
        return true
    }

    /// True when no interrupt can be taken before the next scheduled event, so an idle CPU can skip ahead.
    func quiet(interruptsMasked: Bool) -> Bool { !nmiLatch && (!irqLine || interruptsMasked) }

    /// Jumps the clock forward to just before the next event, but not beyond `limit`.
    func skipIdle(until limit: Int) {
        let target = min(nextEvent, limit) - 1
        if target > clock { clock = target }
    }

    // MARK: SID

    /// Brings the SID up to the current cycle, collecting its output.
    func syncSID() {
        var pending = clock - sidClock
        while pending > 0, sampleCount < sampleCapacity {
            let before = pending
            let room = sampleCapacity - sampleCount
            if let residfp {
                sampleCount += residfp.pointee.clock(&pending, into: samples + sampleCount, maxSamples: room)
            } else if let resid {
                sampleCount += resid.pointee.clock(&pending, into: samples + sampleCount, maxSamples: room)
            }
            if pending == before { break }
        }
        sidClock = clock - pending
    }

    /// Moves up to `count` samples out, as stereo floats.
    func drain(into buffer: UnsafeMutablePointer<Float>, count: Int, gain: Float) -> Int {
        let n = min(count, sampleCount)
        for i in 0 ..< n {
            let v = Float(samples[i]) * gain
            buffer[i * 2] = v
            buffer[i * 2 + 1] = v
        }
        if n < sampleCount {
            samples.update(from: samples + n, count: sampleCount - n)
        }
        sampleCount -= n
        return n
    }

    // MARK: Bus

    @inline(__always) func read(_ address: UInt16) -> UInt8 {
        tick()
        let a = Int(address)
        if a < 0xA000 {
            if a < 2 { return a == 0 ? portDirection : (portData | ~portDirection) & 0x3F | 0x10 }
            return ram[a]
        }
        let value: UInt8
        switch a >> 12 {
        case 0xA, 0xB:
            guard basicVisible else { return ram[a] }
            value = 0x60
        case 0xD:
            guard ioVisible else { return ram[a] }
            value = readIO(a)
        case 0xE, 0xF:
            guard kernalVisible else { return ram[a] }
            value = kernal[a - 0xE000]
        default:
            return ram[a]
        }
        if hardwareReads != nil, hardwareReads?[address] == nil { hardwareReads?[address] = value }
        return value
    }

    @inline(__always) func write(_ address: UInt16, _ value: UInt8) {
        tick()
        let a = Int(address)
        if a < 2 {
            if a == 0 { portDirection = value } else { portData = value }
            updateBanking()
            return
        }
        if a >> 12 == 0xD, ioVisible {
            writeIO(a, value)
        } else {
            ram[a] = value
        }
    }

    private func readIO(_ a: Int) -> UInt8 {
        switch (a >> 8) & 0x0F {
        case 0x0 ... 0x3:
            let r = a & 0x3F
            switch r {
            case 0x11: return (vicRegisters[0x11] & 0x7F) | (currentRaster() > 255 ? 0x80 : 0)
            case 0x12: return UInt8(currentRaster() & 0xFF)
            case 0x19:
                let active = vicInterruptFlags & vicInterruptMask & 0x0F != 0
                return vicInterruptFlags | 0x70 | (active ? 0x80 : 0)
            case 0x1A: return vicInterruptMask | 0xF0
            // Bits the VIC does not implement read as 1.
            case 0x16: return vicRegisters[r] | 0xC0
            case 0x18: return vicRegisters[r] | 0x01
            case 0x20 ... 0x2E: return vicRegisters[r] | 0xF0
            default: return r < 0x2F ? vicRegisters[r] : 0xFF
            }
        case 0x4 ... 0x7:
            syncSID()
            if let residfp { return residfp.pointee.read(a & 0x1F) }
            if let resid { return resid.pointee.read(a & 0x1F) }
            return 0xFF
        case 0x8 ... 0xB:
            return colorRAM[a & 0x3FF] | 0xF0
        case 0xC:
            let value = cia1.read(a, clock: clock)
            if a & 0x0F == 0x0D { updateInterruptLines() }
            return value
        case 0xD:
            return cia2.read(a, clock: clock)
        default:
            return 0xFF
        }
    }

    private func writeIO(_ a: Int, _ value: UInt8) {
        switch (a >> 8) & 0x0F {
        case 0x0 ... 0x3:
            let r = a & 0x3F
            switch r {
            case 0x11, 0x12:
                vicRegisters[r] = value
                rasterCompare = Int(vicRegisters[0x12]) | (Int(vicRegisters[0x11]) & 0x80) << 1
                scheduleRaster()
                reschedule()
            case 0x19:
                vicInterruptFlags &= ~(value & 0x0F)
                updateInterruptLines()
            case 0x1A:
                vicInterruptMask = value & 0x0F
                updateInterruptLines()
            default:
                if r < 0x2F { vicRegisters[r] = value }
            }
        case 0x4 ... 0x7:
            syncSID()
            let r = a & 0x1F
            residfp?.pointee.write(r, value)
            resid?.pointee.write(r, value)
            if r <= 0x18 { writeLog?.append((clock, UInt8(r), value)) }
        case 0x8 ... 0xB:
            colorRAM[a & 0x3FF] = value & 0x0F
        case 0xC:
            cia1.write(a, value, clock: clock)
            updateInterruptLines()
            reschedule()
        case 0xD:
            let before = cia2.interruptLine
            cia2.write(a, value, clock: clock)
            if cia2.interruptLine, !before { nmiLatch = true }
            reschedule()
        default:
            break
        }
    }
}
