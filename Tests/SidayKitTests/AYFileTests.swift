// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of the Z80 core and the ZXAYEMUL path. The full instruction exercisers are run
// outside the package: `siday --zex zexdoc.com` (and zexall.com) must print 67 lines ending in OK.

private final class RecordingBus: Z80Bus {
    var writes: [(port: UInt16, value: UInt8, tstate: Int)] = []
    var reads: [UInt16] = []
    var input: UInt8 = 0xFF

    func portIn(_ port: UInt16, tstate _: Int) -> UInt8 {
        reads.append(port)
        return input
    }

    func portOut(_ port: UInt16, value: UInt8, tstate: Int) {
        writes.append((port, value, tstate))
    }
}

/// A Z80 with 64 KB of zeroed memory and a program at address 0.
private final class TestCPU {
    let memory: UnsafeMutablePointer<UInt8>
    let bus = RecordingBus()
    var cpu: Z80<RecordingBus>

    init(_ program: [UInt8]) {
        memory = .allocate(capacity: 65536)
        memory.initialize(repeating: 0, count: 65536)
        for (offset, byte) in program.enumerated() { memory[offset] = byte }
        cpu = Z80(memory: memory, bus: bus)
        cpu.sp = 0xFF00
    }

    deinit { memory.deallocate() }

    func step(_ count: Int) {
        for _ in 0 ..< count { cpu.step() }
    }

    func interrupt() -> Bool { cpu.interrupt() }
}

@Test func z80ArithmeticFlags() {
    // LD A,7Fh; ADD A,1 — overflow into the sign bit.
    var t = TestCPU([0x3E, 0x7F, 0xC6, 0x01])
    t.step(2)
    #expect(t.cpu.a == 0x80)
    #expect(t.cpu.f == Z80Flag.s | Z80Flag.h | Z80Flag.pv)
    #expect(t.cpu.tstates == 14)

    // LD A,0; SUB 1 — borrow everywhere, undocumented bits copied from the result.
    t = TestCPU([0x3E, 0x00, 0xD6, 0x01])
    t.step(2)
    #expect(t.cpu.a == 0xFF)
    #expect(t.cpu.f == Z80Flag.s | Z80Flag.y | Z80Flag.h | Z80Flag.x | Z80Flag.n | Z80Flag.c)

    // LD A,15h; ADD A,27h; DAA — 15 + 27 = 42 in BCD.
    t = TestCPU([0x3E, 0x15, 0xC6, 0x27, 0x27])
    t.step(3)
    #expect(t.cpu.a == 0x42)
    #expect(t.cpu.f == Z80Flag.h | Z80Flag.pv)
    #expect(t.cpu.tstates == 18)

    // LD A,5; CP 28h — X and Y come from the operand, not the result.
    t = TestCPU([0x3E, 0x05, 0xFE, 0x28])
    t.step(2)
    #expect(t.cpu.a == 0x05)
    #expect(t.cpu.f & (Z80Flag.x | Z80Flag.y) == 0x28)
    #expect(t.cpu.f & Z80Flag.c != 0)
}

@Test func z80UndocumentedInstructions() {
    // LD B,80h; SLL B
    var t = TestCPU([0x06, 0x80, 0xCB, 0x30])
    t.step(2)
    #expect(t.cpu.b == 0x01)
    #expect(t.cpu.f == Z80Flag.c)
    #expect(t.cpu.tstates == 15)

    // LD IX,1234h; LD A,IXH; INC IXL
    t = TestCPU([0xDD, 0x21, 0x34, 0x12, 0xDD, 0x7C, 0xDD, 0x2C])
    t.step(3)
    #expect(t.cpu.a == 0x12)
    #expect(t.cpu.ix == 0x1235)
    #expect(t.cpu.tstates == 14 + 8 + 8)

    // LD IX,8000h; RLC (IX+5),B — the result goes to memory and to B.
    t = TestCPU([0xDD, 0x21, 0x00, 0x80, 0xDD, 0xCB, 0x05, 0x00])
    t.memory[0x8005] = 0x81
    t.step(2)
    #expect(t.memory[0x8005] == 0x03)
    #expect(t.cpu.b == 0x03)
    #expect(t.cpu.f & Z80Flag.c != 0)
    #expect(t.cpu.tstates == 14 + 23)

    // LD HL,4000h; BIT 7,(HL) after LD A,(DE)-style MEMPTR change is covered by ZEXALL; here the basic flags.
    t = TestCPU([0x21, 0x00, 0x40, 0xCB, 0x7E])
    t.memory[0x4000] = 0x80
    t.step(2)
    #expect(t.cpu.f & Z80Flag.z == 0)
    #expect(t.cpu.f & Z80Flag.s != 0)
    #expect(t.cpu.tstates == 10 + 12)

    // A run of prefixes costs four T-states each and then applies to the instruction that follows.
    t = TestCPU([0xDD, 0xFD, 0xDD, 0x21, 0x78, 0x56])
    t.step(3)
    #expect(t.cpu.ix == 0x5678)
    #expect(t.cpu.tstates == 4 + 4 + 14)
}

@Test func z80BlockInstructionsAndTiming() {
    // LD HL,0100h; LD DE,0200h; LD BC,3; LDIR
    let t = TestCPU([0x21, 0x00, 0x01, 0x11, 0x00, 0x02, 0x01, 0x03, 0x00, 0xED, 0xB0])
    t.memory[0x100] = 0xAA; t.memory[0x101] = 0xBB; t.memory[0x102] = 0xCC
    t.step(3)
    t.cpu.run(until: 30 + 21 + 21 + 16)
    #expect(t.cpu.tstates == 30 + 58)
    #expect(t.cpu.pc == 11)
    #expect(t.cpu.bc == 0)
    #expect(t.memory[0x200] == 0xAA && t.memory[0x201] == 0xBB && t.memory[0x202] == 0xCC)
    #expect(t.cpu.f & Z80Flag.pv == 0)
}

@Test func z80PortAccess() {
    // LD A,12h; OUT (FEh),A — A goes on the top half of the address bus.
    var t = TestCPU([0x3E, 0x12, 0xD3, 0xFE])
    t.step(2)
    #expect(t.bus.writes.count == 1)
    #expect(t.bus.writes[0].port == 0x12FE)
    #expect(t.bus.writes[0].value == 0x12)
    #expect(t.bus.writes[0].tstate == 7 + 8)

    // LD BC,C0FDh; LD HL,0010h; OUTI — B is decremented before the port is addressed.
    t = TestCPU([0x01, 0xFD, 0xC0, 0x21, 0x10, 0x00, 0xED, 0xA3])
    t.memory[0x10] = 0x5A
    t.step(3)
    #expect(t.bus.writes[0].port == 0xBFFD)
    #expect(t.bus.writes[0].value == 0x5A)
    #expect(t.cpu.hl == 0x11)
    #expect(t.cpu.tstates == 36)

    // LD BC,FFFDh; IN E,(C)
    t = TestCPU([0x01, 0xFD, 0xFF, 0xED, 0x58])
    t.bus.input = 0x00
    t.step(2)
    #expect(t.bus.reads == [0xFFFD])
    #expect(t.cpu.e == 0)
    #expect(t.cpu.f & Z80Flag.z != 0)
}

@Test func z80Interrupts() {
    // EI; NOP; HALT, with a mode 2 vector at 80FFh pointing to 9000h.
    let t = TestCPU([0xFB, 0x00, 0x76])
    t.memory[0x80FF] = 0x00; t.memory[0x8100] = 0x90
    t.cpu.i = 0x80
    t.cpu.interruptMode = 2
    #expect(!t.interrupt()) // interrupts are still off
    t.step(1)
    #expect(!t.interrupt()) // not straight after EI
    t.step(1)
    #expect(t.cpu.acceptsInterrupt)
    t.step(1)
    #expect(t.cpu.halted)
    t.cpu.run(until: 100) // a halted CPU idles in four T-state steps
    #expect(t.cpu.tstates == 100)
    #expect(t.interrupt())
    #expect(!t.cpu.halted)
    #expect(t.cpu.pc == 0x9000)
    #expect(t.cpu.tstates == 119)
    #expect(!t.cpu.iff1)
    // The return address is the instruction after HALT.
    #expect(t.memory[0xFEFE] == 0x03 && t.memory[0xFEFF] == 0x00)

    // Mode 1 goes to 38h in 13 T-states.
    let u = TestCPU([0xFB, 0x00])
    u.cpu.interruptMode = 1
    u.step(2)
    #expect(u.interrupt())
    #expect(u.cpu.pc == 0x38)
    #expect(u.cpu.tstates == 8 + 13)
}

// MARK: ZXAYEMUL

/// Builds a one-song ZXAYEMUL file around `code`, which is loaded at 8000h.
private func makeAYFile(code: [UInt8], initOffset: Int, interruptOffset: Int?, length: Int = 500, fade: Int = 50) -> [UInt8] {
    var bytes = [UInt8]("ZXAYEMUL".utf8) + [0, 3, 0, 0]
    func word(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    let author = 52, misc = 59, name = 64, data = 69
    bytes += word(author - 12) + word(misc - 14) // offsets 12 and 14
    bytes += [0, 0] // one song, first song 0
    bytes += word(20 - 18) // song table at 20
    bytes += word(name - 20) + word(24 - 22) // song entry: name, data at 24
    bytes += [0, 1, 2, 3] + word(length) + word(fade) + [0x12, 0x34] // song data at 24
    bytes += word(38 - 34) + word(44 - 36) // points at 38, blocks at 44
    bytes += word(0xF000) + word(0x8000 + initOffset) + word(interruptOffset.map { 0x8000 + $0 } ?? 0)
    bytes += word(0x8000) + word(code.count) + word(data - 48) + [0, 0] // one block, then the terminator
    bytes += [UInt8]("Tester\0".utf8) + [UInt8]("misc\0".utf8) + [UInt8]("Tiny\0".utf8)
    precondition(bytes.count == data)
    return bytes + code
}

/// Init sets the mixer and channel A's volume; the interrupt routine writes the tone period each frame
/// and counts frames into register 11 with OUTI.
private func spectrumTune() -> [UInt8] {
    let initCode: [UInt8] = [
        0x3E, 0x07, 0x01, 0xFD, 0xFF, 0xED, 0x79, // LD A,7; LD BC,FFFDh; OUT (C),A
        0x06, 0xBF, 0x3E, 0x3E, 0xED, 0x79, // LD B,BFh; LD A,3Eh; OUT (C),A
        0x06, 0xFF, 0x3E, 0x08, 0xED, 0x79, // LD B,FFh; LD A,8; OUT (C),A
        0x06, 0xBF, 0x3E, 0x0F, 0xED, 0x79, // LD B,BFh; LD A,0Fh; OUT (C),A
        0xC9,
    ]
    var interrupt: [UInt8] = [
        0x01, 0xFD, 0xFF, 0xAF, 0xED, 0x79, // LD BC,FFFDh; XOR A; OUT (C),A
        0x06, 0xBF, 0x3E, 0xFC, 0xED, 0x79, // LD B,BFh; LD A,FCh; OUT (C),A
        0x06, 0xFF, 0x3E, 0x0B, 0xED, 0x79, // LD B,FFh; LD A,11; OUT (C),A
        0x21, 0, 0, 0x34, // LD HL,counter; INC (HL)
        0x06, 0xC0, 0xED, 0xA3, // LD B,C0h; OUTI
        0xC9,
    ]
    let counter = 0x8000 + initCode.count + interrupt.count
    interrupt[19] = UInt8(counter & 0xFF)
    interrupt[20] = UInt8(counter >> 8)
    return makeAYFile(code: initCode + interrupt + [0], initOffset: 0, interruptOffset: initCode.count)
}

@Test func ayFileParsesAndBuildsMemory() throws {
    let file = try AYFile(spectrumTune())
    #expect(file.author == "Tester")
    #expect(file.misc == "misc")
    #expect(file.songs.count == 1)
    let song = file.songs[0]
    #expect(song.name == "Tiny")
    #expect(song.lengthFrames == 500 && song.fadeFrames == 50)
    #expect(song.stack == 0xF000 && song.initAddress == 0x8000 && song.interruptAddress == 0x801A)
    #expect(song.highRegister == 0x12 && song.lowRegister == 0x34)
    #expect(song.blocks.count == 1 && song.blocks[0].address == 0x8000)

    let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
    defer { memory.deallocate() }
    file.buildMemory(song: 0, into: memory)
    // DI; CALL 8000h; IM 1; EI; HALT; CALL 801Ah; JR -9
    #expect((0 ..< 13).map { memory[$0] } == [0xF3, 0xCD, 0x00, 0x80, 0xED, 0x56, 0xFB, 0x76, 0xCD, 0x1A, 0x80, 0x18, 0xF7])
    #expect(memory[0x38] == 0xFB && memory[0x39] == 0xC9)
    #expect(memory[0x100] == 0xFF && memory[0x3FFF] == 0xFF && memory[0x4000] == 0)
    #expect(memory[0x8000] == 0x3E && memory[0x8001] == 0x07)
}

@Test func ayFilePlaysASpectrumTune() throws {
    let renderer = try AYFileRenderer(spectrumTune())
    #expect(renderer.info.format == "AY")
    #expect(renderer.info.title == "Tiny" && renderer.info.author == "Tester")
    #expect(renderer.info.detail == "ZX Spectrum")
    #expect(renderer.knownLength == 10)
    #expect(renderer.fileFade == 1)
    #expect(renderer.subsongCount == 1 && renderer.defaultSubsong == 0)

    let (events, states) = renderer.portLog(frames: 6)
    #expect(states.count == 6)
    // Frame 0 is the init routine; from frame 1 the interrupt routine runs once per frame.
    #expect(states[0][7] == 0x3E && states[0][8] == 0x0F && states[0][0] == 0)
    #expect(states[5][0] == 0xFC && states[5][11] == 5)
    let perFrame = (1 ... 5).map { frame in events.filter { $0.frame == frame } }
    #expect(perFrame.allSatisfy { $0.count == 2 && $0[0].register == 0 && $0[1].register == 11 })
    // The interrupt is taken at the start of every frame, give or take the four T-state grain of HALT.
    let times = perFrame.map { $0[0].tstate }
    #expect((times.max() ?? 0) - (times.min() ?? 0) <= 3)
    #expect((times.max() ?? 0) < 200)

    // Tone period 252 is 439.8 Hz: count rising zero crossings over 0.9 s.
    var samples = [Float](repeating: 0, count: 48000 * 2)
    samples.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 48000) }
    var crossings = 0
    for i in 4801 ..< 48000 where samples[(i - 1) * 2] < 0 && samples[i * 2] >= 0 { crossings += 1 }
    #expect(abs(crossings - 396) <= 2)
}

@Test func ayFileRecognisesACPCTune() throws {
    func out(_ port: Int) -> [UInt8] { [0x01, UInt8(port & 0xFF), UInt8(port >> 8), 0xED, 0x49] } // LD BC,port; OUT (C),C
    // Select register 7 through the 8255, then write 3Eh to it.
    let code = out(0xF407) + out(0xF6C0) + out(0xF600) + out(0xF43E) + out(0xF680) + out(0xF600) + [0xC9, 0xC9]
    let renderer = try AYFileRenderer(makeAYFile(code: code, initOffset: 0, interruptOffset: code.count - 1, length: 0, fade: 0))
    #expect(renderer.machineKind == .cpc)
    #expect(renderer.info.detail == "Amstrad CPC")
    // The file gives no length; the tune stops touching the chip at once, which is found by running it.
    #expect((renderer.knownLength ?? 9) < 1 && renderer.fileFade == nil)
    let (events, states) = renderer.portLog(frames: 2)
    // The 8255 writes with an even low byte also look like speaker writes until the machine is known.
    let writes = events.filter { $0.register < 16 }
    #expect(writes.count == 1 && writes[0].register == 7 && writes[0].value == 0x3E)
    #expect(states[1][7] == 0x3E)
    #expect(states[1][14] == 0)
}

@Test func ayFileBeeperIsHeard() throws {
    // DI; loop: XOR 10h; OUT (FEh),A; LD B,0; DJNZ $; JR loop — a square wave from the speaker bit.
    let code: [UInt8] = [0xF3, 0xEE, 0x10, 0xD3, 0xFE, 0x06, 0x00, 0x10, 0xFE, 0x18, 0xF6]
    let renderer = try AYFileRenderer(makeAYFile(code: code, initOffset: 0, interruptOffset: nil))
    #expect(renderer.machineKind == .undetected)
    #expect(renderer.info.detail == "ZX Spectrum beeper")
    var samples = [Float](repeating: 0, count: 4800 * 2)
    samples.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
    let low = samples.min() ?? 0, high = samples.max() ?? 0
    #expect(high - low > 0.1)
    let sane = samples.allSatisfy { $0.isFinite && abs($0) < 1 }
    #expect(sane)
}

@Test func ayFileRejectsDamageWithoutTrapping() throws {
    let good = spectrumTune()
    #expect(throws: TuneError.self) { _ = try AYFile([UInt8]("ZXAYAMAD".utf8) + [UInt8](repeating: 0, count: 40)) }
    #expect(throws: TuneError.self) { _ = try AYFile(Array(good.prefix(19))) }
    var buffer = [Float](repeating: 0, count: 512)
    var quick = LoadOptions()
    quick.findsMissingLengths = false
    // Every truncation either fails to load or plays.
    for length in stride(from: 0, to: good.count, by: 3) {
        if let renderer = try? AYFileRenderer(Array(good.prefix(length)), options: quick) {
            buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 256) }
        }
    }
    // Pointers and lengths replaced by junk, one field at a time.
    var seed: UInt32 = 12345
    for offset in stride(from: 12, to: 52, by: 2) {
        var damaged = good
        seed = seed &* 1_664_525 &+ 1_013_904_223
        damaged[offset] = UInt8(truncatingIfNeeded: seed >> 24)
        damaged[offset + 1] = UInt8(truncatingIfNeeded: seed >> 16)
        if let renderer = try? AYFileRenderer(damaged, options: quick) {
            for song in 0 ..< min(renderer.subsongCount, 3) {
                renderer.select(subsong: song)
                buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 256) }
            }
        }
    }
    let finite = buffer.allSatisfy { $0.isFinite }
    #expect(finite)
}

@Test func ayFileLengthFinder() {
    // Signatures stand in for what each 1/50 s frame did to the sound hardware.
    let intro: [UInt64] = (0 ..< 300).map { 1000 + $0 }
    let loop: [UInt64] = (0 ..< 2000).map { 5000 + $0 }
    let rest = [UInt64](repeating: 7, count: 18000)

    // A tune that plays for six seconds and then leaves the hardware alone has ended there.
    let jingle = Array((intro + rest).prefix(18000))
    #expect(AYFileRenderer.lengthInFrames(of: jingle, frameHz: 50) == 300 + 25)

    // A lead-in followed by a loop is as long as the lead-in plus one pass.
    var looping = intro
    while looping.count < 18000 { looping += loop }
    looping = Array(looping.prefix(18000))
    #expect(AYFileRenderer.lengthInFrames(of: looping, frameHz: 50) == 300 + 2000)

    // A phrase played four times before the tune moves on is not the loop.
    let phrase: [UInt64] = (0 ..< 400).map { 9000 + $0 }
    let unfinished = (0 ..< 16400).map { UInt64(20000 + $0) } + phrase + phrase + phrase + phrase
    #expect(AYFileRenderer.lengthInFrames(of: unfinished, frameHz: 50) == nil)

    // Nothing that neither ends nor repeats has a length.
    #expect(AYFileRenderer.lengthInFrames(of: (0 ..< 18000).map { UInt64($0) }, frameHz: 50) == nil)
}
