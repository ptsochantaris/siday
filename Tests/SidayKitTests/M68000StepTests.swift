// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayM68000
import Testing

// The 68000 runs most of its opcodes by steps made for their addressing modes (M68000Steps.swift, made
// by Scripts/m68000-steps.swift). Each must do exactly as the step that works the modes out as it runs:
// to the registers, the flags, the memory, the bus and the count of cycles.

/// What the bus was asked, in order, with when; and pseudo-random answers to its reads, the same for the
/// same question at the same moment.
private final class LoggingBus: M68000Bus {
    var log: [UInt64] = []
    var seed: UInt64 = 0
    var asks = false

    private func answer(_ address: UInt32, _ cycles: Int) -> UInt64 {
        var h = seed ^ UInt64(address) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(UInt(bitPattern: cycles)) &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 29
        return h
    }

    private func note(_ address: UInt32, _ cycles: Int, _ kind: UInt64, _ value: UInt64 = 0) {
        log.append(UInt64(address) << 32 | UInt64(UInt32(truncatingIfNeeded: cycles)) << 8 | kind)
        log.append(value)
    }

    override func read8(_ address: UInt32, at cycles: Int) -> UInt8 {
        note(address, cycles, 1)
        return UInt8(truncatingIfNeeded: answer(address, cycles))
    }

    override func read16(_ address: UInt32, at cycles: Int) -> UInt16 {
        note(address, cycles, 2)
        return UInt16(truncatingIfNeeded: answer(address, cycles))
    }

    override func write8(_ address: UInt32, _ value: UInt8, at cycles: Int) {
        note(address, cycles, 3, UInt64(value))
        if address & 0x100 != 0 { asks = true }
    }

    override func write16(_ address: UInt32, _ value: UInt16, at cycles: Int) {
        note(address, cycles, 4, UInt64(value))
        if address & 0x100 != 0 { asks = true }
    }

    override func read8(_ address: UInt32) -> UInt8 { read8(address, at: -1) }
    override func read16(_ address: UInt32) -> UInt16 { read16(address, at: -1) }
    override func write8(_ address: UInt32, _ value: UInt8) { write8(address, value, at: -1) }
    override func write16(_ address: UInt32, _ value: UInt16) { write16(address, value, at: -1) }
    override var asksToBeLookedAt: Bool { asks }
}

@Test func m68000StepsMadeForModesDoAsTheGeneralOnes() {
    let size = 4096
    let first = UnsafeMutablePointer<UInt8>.allocate(capacity: size), second = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    defer {
        first.deallocate()
        second.deallocate()
    }
    var random: UInt64 = 0x1234_5678_9ABC_DEF1
    func next() -> UInt64 {
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return random
    }
    var compared = 0, differ: [UInt32] = []
    for op in UInt32(0) ..< 65536 where M68000Step.table[Int(op)] != M68000Step.general(op) {
        for _ in 0 ..< 3 {
            var word = 0
            while word < size {
                let value = next()
                for byte in 0 ..< 8 { first[word + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
                word += 8
            }
            let pc = UInt32(next() % UInt64(size - 16)) & ~1
            first[Int(pc)] = UInt8(op >> 8)
            first[Int(pc) + 1] = UInt8(op & 0xFF)
            second.update(from: first, count: size)
            let firstBus = LoggingBus(), secondBus = LoggingBus()
            firstBus.seed = next()
            secondBus.seed = firstBus.seed
            var general = M68000(ram: first, ramSize: size, bus: firstBus)
            var made = M68000(ram: second, ramSize: size, bus: secondBus)
            for r in 0 ..< 16 {
                // Address registers mostly in the memory, and now and then beyond it, on the bus.
                var value = UInt32(truncatingIfNeeded: next())
                if r >= 8, next() % 4 != 0 { value %= UInt32(size) }
                general.registers[r] = value
                made.registers[r] = value
            }
            let status = UInt32(truncatingIfNeeded: next()) & 0xA71F
            general.setStatus(status)
            made.setStatus(status)
            general.pc = pc
            made.pc = pc
            let stops = (general.runOne(general: true), made.runOne(general: false))
            var same = stops.0 == stops.1 && general.pc == made.pc && general.cycles == made.cycles
                && general.statusRegister == made.statusRegister && general.userStack == made.userStack
                && firstBus.log == secondBus.log
            for r in 0 ..< 16 where general.registers[r] != made.registers[r] { same = false }
            var byte = 0
            while same, byte < size {
                if first[byte] != second[byte] { same = false }
                byte += 1
            }
            if !same, differ.count < 10 { differ.append(op) }
            compared += 1
        }
    }
    #expect(compared > 100_000)
    #expect(differ.isEmpty, "opcodes that differ: \(differ.map { String($0, radix: 16) })")
}
