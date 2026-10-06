// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// Runs a CP/M `.com` program on the Z80 core with just enough of BDOS to print text.
/// This exists so the instruction exercisers ZEXDOC and ZEXALL can be run against the core
/// (`siday --zex zexdoc.com`); nothing in playback uses it.
public enum Z80CPM {
    public struct Result: Sendable {
        public var output: String
        public var tstates: Int
        public var instructions: Int
        /// False when the instruction limit was reached before the program returned to address 0.
        public var finished: Bool
    }

    private final class IdleBus: Z80Bus {
        func portIn(_: UInt16, tstate _: Int) -> UInt8 { 0xFF }
        func portOut(_: UInt16, value _: UInt8, tstate _: Int) {}
    }

    /// Loads `program` at 0x100 and runs it until it jumps to address 0.
    /// Console output (BDOS functions 2 and 9) is collected and also passed to `onOutput` as it appears.
    ///
    /// The low-memory stubs are the ones superzazu/z80's test harness uses — `OUT (0),A` at 0 and
    /// `IN A,(0)`, `RET` at 5 — and they are executed, so T-state totals are directly comparable
    /// with that core's.
    public static func run(program: [UInt8], maxInstructions: Int = .max, onOutput: ((String) -> Void)? = nil) -> Result {
        let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        memory.initialize(repeating: 0, count: 65536)
        defer { memory.deallocate() }
        for (offset, byte) in program.prefix(65536 - 0x100).enumerated() { memory[0x100 + offset] = byte }
        memory[0] = 0xD3; memory[1] = 0x00
        memory[5] = 0xDB; memory[6] = 0x00; memory[7] = 0xC9

        let bus = IdleBus()
        var cpu = Z80(memory: memory, bus: bus)
        cpu.reset()
        cpu.pc = 0x100
        var output = ""
        var instructions = 0
        var finished = false
        while instructions < maxInstructions {
            if cpu.pc == 5 {
                var text = ""
                if cpu.c == 2 {
                    text = String(UnicodeScalar(cpu.e))
                } else if cpu.c == 9 {
                    var address = cpu.de
                    var count = 0
                    while memory[Int(address)] != 0x24, count < 65536 {
                        text.unicodeScalars.append(UnicodeScalar(memory[Int(address)]))
                        address &+= 1
                        count += 1
                    }
                }
                if !text.isEmpty {
                    output += text
                    onOutput?(text)
                }
            }
            let atExit = cpu.pc == 0
            cpu.step()
            instructions += 1
            if atExit {
                finished = true
                break
            }
        }
        return Result(output: output, tstates: cpu.tstates, instructions: instructions, finished: finished)
    }
}
