// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AtariAudio, Copyright (c) Arnaud Carré, used under the MIT licence (see THIRD-PARTY.md).

/// The Atari ST's hardware registers, as far as its music touches them: the sound chip, the timer
/// chip and the STE's sample player, and a few places a player's code looks at to see what kind of
/// machine it is on.
final class STHardware: M68000Bus {
    var chip: STSoundChip
    var timers: MFP
    var samples: STESound

    init(hostRate: Int) {
        chip = STSoundChip(hostRate: hostRate)
        timers = MFP(hostRate: hostRate)
        samples = STESound(hostRate: hostRate)
    }

    deinit {
        chip.deallocate()
        timers.deallocate()
        samples.deallocate()
    }

    func reset() {
        chip.reset()
        timers.reset()
        samples.reset()
    }

    func read8(_ address: UInt32) -> UInt8 {
        switch address {
        case 0xFF8800 ..< 0xFF8900: chip.readPort(address & 255)
        // A colour screen, at fifty frames a second.
        case 0xFF8260: 0
        case 0xFF820A: 2
        case 0xFFFA00 ..< 0xFFFA26: timers.read8(address - 0xFFFA00)
        case 0xFF8900 ..< 0xFF8926: samples.read8(address - 0xFF8900)
        // The keyboard and MIDI ports have nothing to say.
        case 0xFFFC00 ... 0xFFFC06: 0
        default: 0xFF
        }
    }

    func read16(_ address: UInt32) -> UInt16 {
        switch address {
        case 0xFF8800 ..< 0xFF8900: UInt16(chip.readPort(address & 0xFE)) << 8
        case 0xFFFA00 ..< 0xFFFA26: timers.read16(address - 0xFFFA00)
        case 0xFF8900 ..< 0xFF8926: samples.read16(address - 0xFF8900)
        case 0xFFFC00 ... 0xFFFC06: 0
        default: 0xFFFF
        }
    }

    func write8(_ address: UInt32, _ value: UInt8) {
        switch address {
        // The chip's two ports each appear twice over.
        case 0xFF8800 ..< 0xFF8900: chip.writePort(address & 0xFE, value)
        case 0xFFFA00 ..< 0xFFFA26: timers.write8(address - 0xFFFA00, value)
        case 0xFF8900 ..< 0xFF8926: samples.write8(address - 0xFF8900, value)
        default: break
        }
    }

    func write16(_ address: UInt32, _ value: UInt16) {
        switch address {
        case 0xFF8800 ..< 0xFF8900: chip.writePort(address & 0xFE, UInt8(truncatingIfNeeded: value >> 8))
        case 0xFFFA00 ..< 0xFFFA26: timers.write16(address - 0xFFFA00, value)
        case 0xFF8900 ..< 0xFF8926: samples.write16(address - 0xFF8900, value)
        default: break
        }
    }
}

/// As much of an Atari ST as a tune needs: a 68000, four megabytes of memory, the sound hardware, and
/// the few things a player's code asks of the operating system.
///
/// The machine does not run continuously. A tune's code is called and runs to its end in no time at
/// all, as far as the sound is concerned: once to start a song, once for each tick of the player, and
/// once for each interrupt of a timer the tune has set going. The timers are moved on a sample of the
/// output at a time, and that is as finely as an interrupt is placed.
final class STMachine {
    static let ramSize = 4 * 1024 * 1024
    /// Where a tune is put. Some will not play lower down, and some not on a 64 KB boundary.
    static let loadAddress: UInt32 = 0x10002
    /// One instruction each, for code to come back to: a return from an exception, and RESET, which
    /// is how the machine knows that what it called has finished.
    private static let rteAddress: UInt32 = 0x500
    private static let resetAddress: UInt32 = 0x502
    /// The top megabyte is what a tune gets when it asks the system for memory.
    private static let heapStart = UInt32(ramSize - 0x100000)
    /// The interrupt vectors of timers A to D and of the sample player's line.
    private static let vectors: [UInt32] = [0x134, 0x120, 0x114, 0x110, 0x13C]
    /// The processor's cycles in a fiftieth of a second: 313 lines of 512.
    private static let frameCycles = 512 * 313

    private let ram: UnsafeMutablePointer<UInt8>
    private let hardware: STHardware
    private var cpu: M68000<STHardware>
    private var heap: UInt32 = 0
    /// The system's own way of feeding the sound chip from a list, which a few tunes use: where it
    /// has got to, the value it is stepping, and how many ticks it is waiting.
    private var soundList: UInt32 = 0
    private var soundListValue: UInt8 = 0
    private var soundListDelay: UInt8 = 0

    init(hostRate: Int) {
        ram = .allocate(capacity: Self.ramSize)
        hardware = STHardware(hostRate: hostRate)
        cpu = M68000(ram: ram, ramSize: Self.ramSize, bus: hardware)
    }

    deinit {
        cpu.deallocate()
        ram.deallocate()
    }

    /// Switches the machine on with a tune in its memory.
    func start(_ image: [UInt8]) -> Bool {
        guard !image.isEmpty, Int(Self.loadAddress) + image.count <= Self.ramSize else { return false }
        ram.initialize(repeating: 0, count: Self.ramSize)
        cpu.powerOn()
        hardware.reset()
        heap = Self.heapStart
        image.withUnsafeBufferPointer { (ram + Int(Self.loadAddress)).update(from: $0.baseAddress!, count: image.count) }

        // What the system says of the machine, for the players that ask: it has the sound chip and the
        // STE's sample player, and it is an STE.
        cpu.write32(0x900, 0x5F53_4E44) // _SND
        cpu.write32(0x904, 3)
        cpu.write32(0x908, 0x5F4D_4348) // _MCH
        cpu.write32(0x90C, 0x0001_0000)
        cpu.write32(0x910, 0)
        cpu.write32(0x5A0, 0x900)

        cpu.write16(Self.resetAddress, 0x4E70)
        cpu.write16(Self.rteAddress, 0x4E73)
        // Some tunes put the timer chip back as the system had it, with timer C running: its interrupt
        // has somewhere harmless to go.
        cpu.write32(0x114, Self.rteAddress)

        soundList = 0
        soundListValue = 0
        soundListDelay = 0
        return true
    }

    /// Runs code from `address` until it comes back to the RESET planted for it, for at most `frames`
    /// fiftieths of a second of the processor's time. False if it never came back.
    private func run(from address: UInt32, frames: Int) -> Bool {
        // A division by nothing is shrugged off.
        cpu.write32(0x14, Self.rteAddress)
        cpu.write32(4, address)
        cpu.reset()
        let budget = frames * Self.frameCycles
        var stop = cpu.run(cycles: budget)
        while true {
            switch stop {
            case .reset:
                return true
            case let .trap(number):
                if !system(trap: number) { cpu.takeTrap(number) }
                stop = cpu.resume(cycles: budget)
            case .outOfTime, .illegal, .stopped:
                return false
            }
        }
    }

    /// Calls a subroutine with a value in D0. It is given ten seconds.
    func call(_ address: UInt32, d0: UInt32) -> Bool {
        cpu.write32(UInt32(Self.ramSize - 4), Self.resetAddress)
        cpu.write32(0, UInt32(Self.ramSize - 4))
        cpu.registers[0] = d0
        return run(from: address, frames: 50 * 10)
    }

    /// One tick of the tune's player.
    func tick(_ address: UInt32) -> Bool {
        stepSoundList()
        return call(address, d0: 0)
    }

    /// The next sample of the machine's sound, exactly as the reference player makes it. Any timer that
    /// comes due has its interrupt code run.
    @inline(__always) func nextSample() -> Int16 {
        var level = Int32(hardware.chip.nextSample())
        level += Int32(hardware.samples.nextSample(ram: ram, ramSize: UInt32(Self.ramSize), mfp: &hardware.timers))
        let output = Int16(truncatingIfNeeded: max(-32768, min(32767, level)))
        return runTimers() ? output : 0
    }

    /// The next sample of the machine's sound for listening to, on the same scale: the sound chip's
    /// part of it comes through a better filter (see `STSoundChip`).
    @inline(__always) func nextFiltered() -> Float {
        var level = hardware.chip.nextFiltered()
        level += Float(hardware.samples.nextSample(ram: ram, ramSize: UInt32(Self.ramSize), mfp: &hardware.timers))
        let output = max(-32768, min(32767, level))
        return runTimers() ? output : 0
    }

    /// Moves the timers on by a sample and runs the interrupt code of any that come due. False if some
    /// of that code did not come back.
    @inline(__always) private func runTimers() -> Bool {
        var sound = true
        for line in 0 ..< 5 where hardware.timers.tick(line) {
            let handler = cpu.read32(Self.vectors[line])
            // The handler ends with a return from exception, which finds the RESET.
            cpu.write32(UInt32(Self.ramSize - 4), Self.resetAddress)
            cpu.write16(UInt32(Self.ramSize - 6), 0x2300)
            cpu.write32(0, UInt32(Self.ramSize - 6))
            hardware.chip.insideTimerInterrupt(true)
            if !run(from: handler, frames: 1) { sound = false }
            hardware.chip.insideTimerInterrupt(false)
        }
        return sound
    }

    // MARK: The operating system

    /// Answers a call to the system. False for one this machine has no answer to.
    private func system(trap: Int) -> Bool {
        let stack = cpu.registers[15]
        let function = cpu.read16(stack)
        switch trap {
        case 1:
            // GEMDOS.
            switch function {
            case 0x48:
                // A request for memory: handed out from the top megabyte and never taken back.
                let size = cpu.read32(stack &+ 2)
                if size == 0xFFFF_FFFF {
                    cpu.registers[0] = UInt32(Self.ramSize) &- heap
                } else {
                    cpu.registers[0] = heap
                    heap = (heap &+ size &+ 1) & ~1
                }
            case 0x30:
                // The system's version.
                cpu.registers[0] = 0
            default:
                break
            }
            return true
        case 14:
            // XBIOS.
            switch function {
            case 31:
                // Set a timer going, with the code it is to call.
                let timer = Int(cpu.read16(stack &+ 2))
                let control = UInt8(truncatingIfNeeded: cpu.read16(stack &+ 4))
                let data = UInt8(truncatingIfNeeded: cpu.read16(stack &+ 6))
                let handler = cpu.read32(stack &+ 8)
                guard timer < 4 else { break }
                cpu.write32(Self.vectors[timer], handler)
                switch timer {
                case 0: setTimer(control: 0x19, data: 0x1F, enable: 0x07, bit: 5, keep: 0x00, control, data)
                case 1: setTimer(control: 0x1B, data: 0x21, enable: 0x07, bit: 0, keep: 0x00, control, data)
                case 2: setTimer(control: 0x1D, data: 0x23, enable: 0x09, bit: 5, keep: 0x0F, (control & 0x0F) << 4, data)
                default: setTimer(control: 0x1D, data: 0x25, enable: 0x09, bit: 4, keep: 0xF0, control & 0x0F, data)
                }
            case 32:
                // Play a list of sound-chip commands, a step each tick.
                soundList = cpu.read32(stack &+ 2)
            case 38:
                // Run a subroutine in supervisor mode: as if it had been called from where the trap was.
                let routine = cpu.read32(stack &+ 2)
                cpu.registers[15] = stack &- 4
                cpu.write32(stack &- 4, cpu.pc)
                cpu.pc = routine
            case 64:
                // The blitter: there and switched on.
                cpu.registers[0] = 3
            default:
                break
            }
            return true
        default:
            return false
        }
    }

    private func setTimer(control: UInt32, data: UInt32, enable: UInt32, bit: UInt8, keep: UInt8, _ controlValue: UInt8, _ dataValue: UInt8) {
        let kept = hardware.timers.read8(control) & keep
        hardware.timers.write8(control, kept)
        hardware.timers.write8(data, dataValue)
        hardware.timers.write8(control, kept | controlValue)
        // The system enables the timer's interrupt whatever it was asked, even to stop it.
        hardware.timers.write8(enable, hardware.timers.read8(enable) | 1 << bit)
        hardware.timers.write8(enable + 12, hardware.timers.read8(enable + 12) | 1 << bit)
    }

    /// One tick of the system's sound list.
    private func stepSoundList() {
        guard soundList != 0 else { return }
        if soundListDelay > 0 {
            soundListDelay -= 1
            return
        }
        // A list that never waits would never let go.
        for _ in 0 ..< 4096 {
            let command = UInt8(truncatingIfNeeded: cpu.read8(soundList))
            if command < 0x80 {
                hardware.chip.writePort(0, command & 15)
                hardware.chip.writePort(2, UInt8(truncatingIfNeeded: cpu.read8(soundList &+ 1)))
                soundList &+= 2
            } else if command == 0x80 {
                soundListValue = UInt8(truncatingIfNeeded: cpu.read8(soundList &+ 1))
                soundList &+= 2
            } else if command == 0x81 {
                hardware.chip.writePort(0, UInt8(truncatingIfNeeded: cpu.read8(soundList &+ 1)) & 15)
                soundListValue &+= UInt8(truncatingIfNeeded: cpu.read8(soundList &+ 2))
                hardware.chip.writePort(2, soundListValue)
                if soundListValue == UInt8(truncatingIfNeeded: cpu.read8(soundList &+ 3)) { soundList &+= 4 }
                return
            } else {
                soundListDelay = UInt8(truncatingIfNeeded: cpu.read8(soundList &+ 1))
                if soundListDelay == 0 { soundList = 0 }
                return
            }
        }
        soundList = 0
    }
}
