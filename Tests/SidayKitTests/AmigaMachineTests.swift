// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Checks of the emulated Amiga that composers' own players are run on, with little programs assembled
// here by hand: what they write to Paula and when, their waits on the beam, the filter, the CIAs'
// timers, programs that go wrong, and the loading of AmigaDOS programs.

/// 68000 code, a word at a time, with labels for its displacements and addresses.
struct AmigaCode {
    var words: [UInt16] = []
    private var labels: [String: Int] = [:]
    private var relative: [(at: Int, label: String)] = []
    private var absolute: [(at: Int, label: String)] = []
    /// Where the code is to be put, for its absolute addresses.
    var origin: UInt32

    init(at origin: UInt32) { self.origin = origin }

    var here: Int { words.count * 2 }

    mutating func label(_ name: String) { labels[name] = here }
    mutating func w(_ values: UInt16...) { words += values }
    mutating func bytes(_ values: [UInt8]) {
        var values = values
        if values.count % 2 == 1 { values.append(0) }
        for i in stride(from: 0, to: values.count, by: 2) { words.append(UInt16(values[i]) << 8 | UInt16(values[i + 1])) }
    }

    /// A displacement to `label` from this word's own place, as a BSR.W, a DBcc and a LEA d16(PC) have it.
    mutating func to(_ name: String) {
        relative.append((words.count, name))
        words.append(0)
    }

    /// The label's address, as a long.
    mutating func address(_ name: String) {
        absolute.append((words.count, name))
        words += [0, 0]
    }

    func offset(_ name: String) -> Int { labels[name]! }

    func assembled() -> [UInt8] {
        var words = self.words
        for (at, name) in relative { words[at] = UInt16(truncatingIfNeeded: labels[name]! - at * 2) }
        for (at, name) in absolute {
            let address = origin + UInt32(labels[name]!)
            words[at] = UInt16(address >> 16)
            words[at + 1] = UInt16(address & 0xFFFF)
        }
        return words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}

private let origin: UInt32 = 0x2000
private let stack: UInt32 = 0x1F00

private func machine(_ code: AmigaCode) -> AmigaMachine {
    let m = AmigaMachine(chipRAM: 0x10000)
    m.load(code.assembled(), at: code.origin)
    return m
}

@Test func amigaProgramsWritePaulaInOrderAndInTime() {
    var code = AmigaCode(at: origin)
    code.w(0x33FC, 0x0100, 0x00DF, 0xF0A6) // MOVE.W #$100,$DFF0A6
    code.w(0x33FC, 0x0040, 0x00DF, 0xF0A8) // MOVE.W #$40,$DFF0A8
    code.w(0x23FC, 0x0000, 0x3000, 0x00DF, 0xF0A0) // MOVE.L #$3000,$DFF0A0
    code.w(0x33FC, 0x0010, 0x00DF, 0xF0A4) // MOVE.W #$10,$DFF0A4
    code.w(0x33FC, 0x8201, 0x00DF, 0xF096) // MOVE.W #$8201,$DFF096
    code.w(0x4E75)
    var m = machine(code)
    #expect(m.call(origin, stack: stack, budget: 10000) == .returned)
    var writes: [AmigaWrite] = []
    m.takeWrites(into: &writes)
    #expect(writes.map { $0.register } == [0xA6, 0xA8, 0xA0, 0xA2, 0xA4, 0x96])
    #expect(writes.map { $0.value } == [0x100, 0x40, 0, 0x3000, 0x10, 0x8201])
    // Each MOVE.W to an absolute address is four words fetched and one written: twenty cycles; the
    // MOVE.L writes its upper word, then its lower.
    #expect(writes.map { $0.cycles } == [20, 40, 64, 68, 88, 108])
    #expect(m.chips.dmacon == 0x201)

    // Told to Paula, each at its moment.
    var feed = AmigaPaulaFeed(memorySize: m.memorySize)
    var told = Told()
    feed.beginTick()
    feed.tell(writes, &told)
    #expect(told.events == ["at 10", "period 0 256", "at 20", "volume 0 64", "at 32", "buffer 0 0 0", "at 34", "buffer 0 12288 0",
                            "at 44", "buffer 0 12288 16", "at 54", "on 0"])
    // As the tick began, nothing; as the next does, what was written.
    #expect(feed.periods[0] == 0)
    feed.beginTick()
    #expect(feed.periods[0] == 0x100)
    #expect(feed.volumes[0] == 64)
}

private struct Told: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func timed(at clocks: Int) { events.append("at \(clocks)") }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { events.append("period \(voice) \(period)") }
    mutating func writeVolume(_ voice: Int, _ volume: UInt16) { events.append("volume \(voice) \(volume)") }
    mutating func writeLightFilter(_ on: Bool) { events.append("filter \(on)") }
}

@Test func amigaProgramsWaitOnTheBeam() {
    // The DMA turned off, nine lines of the beam waited for (as UADE's host's `wait_audio_dma` waits),
    // and turned on.
    var code = AmigaCode(at: origin)
    code.w(0x33FC, 0x0001, 0x00DF, 0xF096) // MOVE.W #1,$DFF096
    code.w(0x7008) // MOVEQ #8,D0
    code.label("line")
    code.w(0x1239, 0x00DF, 0xF006) // MOVE.B $DFF006,D1
    code.label("same")
    code.w(0xB239, 0x00DF, 0xF006) // CMP.B $DFF006,D1
    code.w(0x67F8) // BEQ.S same
    code.w(0x57C8)
    code.to("line") // DBEQ D0,line
    code.w(0x33FC, 0x8201, 0x00DF, 0xF096) // MOVE.W #$8201,$DFF096
    code.w(0x4E75)
    var m = machine(code)
    #expect(m.call(origin, stack: stack, budget: 100_000) == .returned)
    var writes: [AmigaWrite] = []
    m.takeWrites(into: &writes)
    #expect(writes.count == 2)
    let waited = (writes[1].cycles - writes[0].cycles) / 2
    // Eight whole lines and part of a ninth (the first change ends the line it began in).
    #expect(waited > 8 * AmigaChips.lineClocks && waited <= 9 * AmigaChips.lineClocks + 40)
    // VHPOSR is the line (its lower eight bits) and the place along it; VPOSR the line's ninth bit.
    let (line, position) = AmigaChips.beam(at: 312 * 227 + 100)
    #expect(line == 312 && position == 100)
    m.advance(clocks: 312 * 227 + 100)
    #expect(m.chips.read16(AmigaChips.custom + 6, at: 0) == 0x3864)
    #expect(m.chips.read16(AmigaChips.custom + 4, at: 0) == 0x8001)
}

@Test func amigaProgramsSetTheFilter() {
    var code = AmigaCode(at: origin)
    code.w(0x08B9, 0x0001, 0x00BF, 0xE001) // BCLR #1,$BFE001
    code.w(0x08F9, 0x0001, 0x00BF, 0xE001) // BSET #1,$BFE001
    code.w(0x08F9, 0x0001, 0x00BF, 0xE001) // BSET #1,$BFE001 (no change)
    code.w(0x4E75)
    var m = machine(code)
    #expect(!m.chips.lightFilter)
    #expect(m.call(origin, stack: stack, budget: 10000) == .returned)
    var writes: [AmigaWrite] = []
    m.takeWrites(into: &writes)
    #expect(writes.map { $0.register } == [AmigaWrite.filter, AmigaWrite.filter])
    #expect(writes.map { $0.value } == [1, 0])
}

@Test func amigaTimersCountTheEClock() {
    var cia = AmigaCIA()
    // Timer A from 99, continuously; let through.
    cia.write(AmigaCIA.Register.talo.rawValue, 99)
    cia.write(AmigaCIA.Register.tahi.rawValue, 0)
    cia.write(AmigaCIA.Register.icr.rawValue, 0x81)
    cia.write(AmigaCIA.Register.cra.rawValue, 0x11)
    cia.advance(by: 99)
    #expect(!cia.interrupting)
    #expect(cia.counter(0) == 0)
    // It runs out on the count after nought, and starts again from its latch.
    cia.advance(by: 1)
    #expect(cia.interrupting)
    #expect(cia.counter(0) == 99)
    #expect(cia.read(AmigaCIA.Register.icr.rawValue) == 0x81)
    #expect(!cia.interrupting)
    // Two and a half periods more: twice.
    cia.advance(by: 250)
    #expect(cia.interrupting)
    #expect(cia.counter(0) == 49)
    // One-shot: it stops when it runs out; writing its high byte starts it.
    cia.write(AmigaCIA.Register.crb.rawValue, 0x08)
    cia.write(AmigaCIA.Register.tblo.rawValue, 9)
    cia.write(AmigaCIA.Register.tbhi.rawValue, 0)
    _ = cia.read(AmigaCIA.Register.icr.rawValue)
    cia.advance(by: 30)
    #expect(cia.read(AmigaCIA.Register.icr.rawValue) & 2 == 2)
    #expect(cia.read(AmigaCIA.Register.crb.rawValue) & 1 == 0)
    // And through the bus, at the machine's time: a fifth of Paula's clock.
    let m = AmigaMachine(chipRAM: 0x10000)
    m.chips.write8(0xBFE401, 0x10)
    m.chips.write8(0xBFE501, 0x00)
    m.chips.write8(0xBFEE01, 0x11)
    m.chips.clock = 5 * 10
    #expect(m.chips.read8(0xBFE401, at: 0) == 6)
}

@Test func amigaProgramsThatGoWrongAreStopped() {
    // One that never comes back, one that divides by nought, and one that is not code.
    for program: [UInt16] in [[0x60FE], [0x7000, 0x80C0, 0x4E75], [0xFFFF]] {
        var code = AmigaCode(at: origin)
        for word in program { code.w(word) }
        var m = machine(code)
        #expect(m.call(origin, stack: stack, budget: 10000) == .failed)
    }
    // A library routine nobody has given it is as bad; one it has been given comes back.
    var code = AmigaCode(at: origin)
    code.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
    code.w(0x4EAE, 0xFF3A) // JSR -198(A6)
    code.w(0x4E75)
    code.label("routine")
    code.w(0x7001, 0x4E75) // MOVEQ #1,D0; RTS
    var m = machine(code)
    #expect(m.call(origin, stack: stack, budget: 10000) == .failed)
    m.setLibraryRoutine(198, to: origin + UInt32(code.offset("routine")))
    #expect(m.call(origin, stack: stack, budget: 10000) == .returned)
    #expect(m.cpu.registers[0] == 1)
    #expect(m.peek32(4) == AmigaMachine.execBase)
}

@Test func amigaProgramsAreLoadedAndRelocated() throws {
    func long(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    // A header of three hunks (code of 2 longs, data of 1, BSS of 4); the code's second long points
    // into the data, 2 bytes in, and the data's long at the code.
    var file = long(0x3F3) + long(0) + long(3) + long(0) + long(2) + long(2) + long(1) + long(4)
    file += long(0x3E9) + long(2) + [0x4E, 0x71, 0x4E, 0x75] + long(2)
    file += long(0x3EC) + long(1) + long(1) + long(4) + long(0) + long(0x3F2)
    file += long(0x3EA) + long(1) + long(0x10)
    file += long(0x3EC) + long(1) + long(0) + long(0) + long(0) + long(0x3F2)
    file += long(0x3EB) + long(4) + long(0x3F2)
    #expect(AmigaHunks.isOne(file))
    #expect(try AmigaHunks.sizes(file) == [8, 4, 16])
    let m = AmigaMachine(chipRAM: 0x10000)
    m.poke32(0x4010, 0xFFFF_FFFF)
    let segments = try AmigaHunks.load(file, at: 0x4000, into: m.memory, capacity: m.memorySize)
    #expect(segments.map { $0.address } == [0x4000, 0x4008, 0x4010])
    #expect(segments.map { $0.kind } == [.code, .data, .bss])
    #expect(m.peek32(0x4000) == 0x4E71_4E75)
    #expect(m.peek32(0x4004) == 0x4008 + 2)
    #expect(m.peek32(0x4008) == 0x4000 + 0x10)
    #expect(m.peek32(0x4010) == 0)
    // Cut short anywhere, or pointing outside its hunk, it is refused.
    for cut in 0 ..< file.count {
        #expect(throws: TuneError.self) {
            try AmigaHunks.load(Array(file.prefix(cut)), at: 0x4000, into: m.memory, capacity: m.memorySize)
        }
    }
    var wrong = file
    wrong[63] = 8
    #expect(throws: TuneError.self) { try AmigaHunks.load(wrong, at: 0x4000, into: m.memory, capacity: m.memorySize) }
    #expect(throws: TuneError.self) { try AmigaHunks.load(file, at: 0xFFF0, into: m.memory, capacity: m.memorySize) }
}

// MARK: Running as the hardware runs

/// A machine whose chips ask for interrupts, its program at `origin` in supervisor mode with its
/// interrupts let through, and `handler` set in the vector of `level`.
private func interrupting(_ code: AmigaCode, level: Int, handler: String) -> AmigaMachine {
    var m = machine(code)
    m.chips.interrupts = true
    m.poke32(UInt32(0x60 + level * 4), code.origin + UInt32(code.offset(handler)))
    m.cpu.registers[15] = stack
    m.cpu.setStatus(0x2000)
    m.jump(to: code.origin)
    return m
}

/// The times, in Paula's clocks, at which the program wrote `register`.
private func times(_ m: inout AmigaMachine, _ register: UInt16) -> [Int] {
    var writes: [AmigaWrite] = []
    m.takeWrites(into: &writes)
    return writes.filter { $0.register == register }.map { $0.cycles / 2 }
}

/// The main program waits; the handler counts its calls into $3000, writes the count to AUD1PER (so
/// that its moment is kept), clears its request (`request`) and comes back.
private func waitingProgram(_ setUp: [UInt16], request: UInt16, reading icr: UInt32? = nil) -> AmigaCode {
    var c = AmigaCode(at: origin)
    for word in setUp { c.w(word) }
    c.label("loop")
    c.w(0x4E72, 0x2000, 0x60FA) // STOP #$2000; BRA.S loop
    c.label("handler")
    c.w(0x5279, 0x0000, 0x3000) // ADDQ.W #1,$3000
    if let icr { c.w(0x1039, UInt16(icr >> 16), UInt16(icr & 0xFFFF)) } // MOVE.B icr,D0
    c.w(0x33FC, request, 0x00DF, 0xF09C) // MOVE.W #request,$DFF09C
    c.w(0x33F9, 0x0000, 0x3000, 0x00DF, 0xF0B6) // MOVE.W $3000,$DFF0B6
    c.w(0x4E73) // RTE
    return c
}

@Test func amigaTimersInterruptAsTheyRunOut() {
    // CIA-B's timer A from 99 (a hundred ticks of the E clock, 500 of Paula's), continuously, its
    // interrupt let through, and the CIA's let through to level 6.
    let code = waitingProgram([0x13FC, 0x0063, 0x00BF, 0xD400, 0x13FC, 0x0000, 0x00BF, 0xD500,
                               0x13FC, 0x0081, 0x00BF, 0xDD00, 0x13FC, 0x0011, 0x00BF, 0xDE00,
                               0x33FC, 0xE000, 0x00DF, 0xF09A], request: 0x2000, reading: 0xBFDD00)
    var m = interrupting(code, level: 6, handler: "handler")
    #expect(m.run(until: 5_250) == .reached)
    #expect(m.peek16(0x3000) == 10)
    let at = times(&m, 0xB6)
    #expect(at.count == 10)
    // Every 500 clocks, and each the handler's few instructions after its timer ran out.
    for i in 1 ..< at.count { #expect(at[i] - at[i - 1] == 500) }
    let waiting = m.waiting
    #expect(waiting)
}

@Test func amigaFramesInterrupt() {
    let code = waitingProgram([0x33FC, 0xC020, 0x00DF, 0xF09A], request: 0x0020)
    var m = interrupting(code, level: 3, handler: "handler")
    // (Short frames, of 312 lines, as UADE's are.)
    let frame = UInt64(AmigaChips.lineClocks * AmigaChips.shortFrameLines)
    #expect(m.chips.frameClocks == frame)
    #expect(m.run(until: frame * 7 / 2) == .reached)
    #expect(m.peek16(0x3000) == 3)
    let at = times(&m, 0xB6)
    #expect(at.count == 3 && at.allSatisfy { $0 % Int(frame) < 100 })
}

@Test func amigaVoicesInterruptAsTheyTakeUpTheirBlocks() {
    // Voice 0 playing four words from $4000 at a period of 200, its interrupt let through.
    let setUp: [UInt16] = [0x23FC, 0x0000, 0x4000, 0x00DF, 0xF0A0, 0x33FC, 0x0004, 0x00DF, 0xF0A4,
                           0x33FC, 0x00C8, 0x00DF, 0xF0A6, 0x33FC, 0xC080, 0x00DF, 0xF09A,
                           0x33FC, 0x8201, 0x00DF, 0xF096]
    var m = interrupting(waitingProgram(setUp, request: 0x0080), level: 4, handler: "handler")
    #expect(m.run(until: 20000) == .reached)
    var at = times(&m, 0xB6)
    // The first as the voice starts, at the next line; then each time it takes up its block again,
    // as its last word begins: a block of four words, each played for two periods of 200 clocks.
    #expect(at.count >= 10)
    for i in 2 ..< at.count { #expect(at[i] - at[i - 1] == 1600) }
    // Played faster than the lines come (a period of 16), a word is fetched each line: four lines a
    // block, the first as long as the rest.
    var fast = setUp
    fast[12] = 0x0010
    m = interrupting(waitingProgram(fast, request: 0x0080), level: 4, handler: "handler")
    #expect(m.run(until: 20000) == .reached)
    at = times(&m, 0xB6)
    for i in 1 ..< at.count { #expect(at[i] - at[i - 1] == 4 * AmigaChips.lineClocks) }
}

@Test func amigaChipsAskForNothingUnlessToldTo() {
    // As a player whose host calls its code itself has them: the requests only as written, whatever
    // time passes.
    let m = AmigaMachine(chipRAM: 0x10000)
    m.chips.write16(AmigaChips.custom + 0x9A, 0xE028)
    m.chips.write8(0xBFD400, 1)
    m.chips.write8(0xBFD500, 0)
    m.chips.write8(0xBFDD00, 0x81)
    m.chips.write8(0xBFDE00, 0x11)
    m.chips.clock = 1_000_000
    m.chips.catchUp(0)
    #expect(m.chips.read16(AmigaChips.custom + 0x1E) == 0)
    #expect(m.chips.interruptLevel == 0)
}

@Test func amigaInterruptsWaitForTheMask() {
    // A frame's interrupt asked for while the processor's mask is at 3 is taken once the mask comes
    // down (here by MOVE to SR, after a long wait at level 7).
    var c = AmigaCode(at: origin)
    c.w(0x33FC, 0xC020, 0x00DF, 0xF09A) // MOVE.W #$C020,$DFF09A
    c.w(0x46FC, 0x2700) // MOVE.W #$2700,SR
    c.w(0x203C, 0x0000, 0x9000) // MOVE.L #$9000,D0
    c.label("spin")
    c.w(0x5380, 0x66FC) // SUBQ.L #1,D0; BNE.S spin
    c.w(0x33FC, 0x0001, 0x00DF, 0xF0A6) // MOVE.W #1,$DFF0A6
    c.w(0x46FC, 0x2000) // MOVE.W #$2000,SR
    c.label("loop")
    c.w(0x60FE) // BRA.S loop
    c.label("handler")
    c.w(0x33FC, 0x0020, 0x00DF, 0xF09C, 0x33FC, 0x0002, 0x00DF, 0xF0A6, 0x4E73)
    var m = interrupting(c, level: 3, handler: "handler")
    #expect(m.run(until: 400_000) == .reached)
    var writes: [AmigaWrite] = []
    m.takeWrites(into: &writes)
    let marks = writes.filter { $0.register == 0xA6 }
    #expect(marks.count >= 2 && marks[0].value == 1 && marks[1].value == 2)
    #expect(marks[1].cycles - marks[0].cycles < 200)
}
