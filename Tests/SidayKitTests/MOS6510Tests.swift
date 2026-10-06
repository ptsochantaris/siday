// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

/// Flat 64 KB of RAM that records each bus cycle.
private final class RecordingBus: MOS6510Bus {
    var ram = [UInt8](repeating: 0, count: 65536)
    var cycles: [(address: UInt16, value: UInt8, write: Bool)] = []
    var irq = false
    func read(_ address: UInt16) -> UInt8 {
        cycles.append((address, ram[Int(address)], false))
        return ram[Int(address)]
    }

    func write(_ address: UInt16, _ value: UInt8) {
        ram[Int(address)] = value
        cycles.append((address, value, true))
    }

    var irqSampled: Bool { irq }
    func takeNMI() -> Bool { false }

    func load(_ bytes: [UInt8], at address: Int) {
        for (i, b) in bytes.enumerated() { ram[address + i] = b }
    }
}

// The full conformance run (SingleStepTests/65x02, 3,000 cases per opcode, every bus cycle checked) is an
// external check; these keep the essentials from regressing.

@Test func decimalAdditionFollowsTheNMOSChip() {
    let bus = RecordingBus()
    bus.load([0xF8, 0x18, 0xA9, 0x58, 0x69, 0x46], at: 0x1000) // SED, CLC, LDA #$58, ADC #$46
    var cpu = MOS6510<RecordingBus>()
    cpu.pc = 0x1000
    for _ in 0 ..< 4 { cpu.step(bus) }
    #expect(cpu.a == 0x04)
    #expect(cpu.c)
}

@Test func indexedStoreAlwaysTakesTheExtraCycle() {
    let bus = RecordingBus()
    bus.load([0x9D, 0xF0, 0x20], at: 0x1000) // STA $20F0,X
    var cpu = MOS6510<RecordingBus>()
    cpu.pc = 0x1000
    cpu.a = 0x55
    cpu.x = 0x20
    cpu.step(bus)
    #expect(bus.cycles.count == 5)
    #expect(bus.cycles[3].address == 0x2010 && !bus.cycles[3].write) // dummy read before the carry is applied
    #expect(bus.cycles[4].address == 0x2110 && bus.cycles[4].write)
    #expect(bus.ram[0x2110] == 0x55)
}

@Test func undocumentedLAXAndSAX() {
    let bus = RecordingBus()
    bus.load([0xA7, 0x10, 0xA2, 0x0F, 0x87, 0x11], at: 0x1000) // LAX $10, LDX #$0F, SAX $11
    bus.ram[0x10] = 0xC3
    var cpu = MOS6510<RecordingBus>()
    cpu.pc = 0x1000
    cpu.step(bus)
    #expect(cpu.a == 0xC3 && cpu.x == 0xC3)
    cpu.step(bus)
    cpu.step(bus)
    #expect(bus.ram[0x11] == 0x03)
}

@Test func interruptIsTakenOneInstructionAfterCLI() {
    let bus = RecordingBus()
    bus.load([0x58, 0xEA, 0xEA], at: 0x1000) // CLI, NOP, NOP
    bus.load([0x00, 0x30], at: 0xFFFE)
    bus.irq = true
    var cpu = MOS6510<RecordingBus>()
    cpu.pc = 0x1000
    cpu.step(bus) // CLI: the interrupt check still sees the old flag
    #expect(cpu.pc == 0x1001)
    cpu.step(bus) // NOP, then the interrupt
    #expect(cpu.pc == 0x3000)
    #expect(cpu.i)
}
