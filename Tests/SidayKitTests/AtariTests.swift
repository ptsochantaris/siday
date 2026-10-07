// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of the 68000 core and the Atari ST path. The thorough check is made outside the package,
// against the reference player (AtariAudio): `siday --raw out.raw tune.sndh` writes the machine's
// output as that player makes it, and the two are to agree to the sample.

private final class RecordingBus: M68000Bus {
    var writes: [(address: UInt32, value: UInt32)] = []

    func read8(_: UInt32) -> UInt8 { 0xFF }
    func read16(_: UInt32) -> UInt16 { 0xFFFF }
    func write8(_ address: UInt32, _ value: UInt8) { writes.append((address, UInt32(value))) }
    func write16(_ address: UInt32, _ value: UInt16) { writes.append((address, UInt32(value))) }
}

/// A 68000 with 64 KB of memory and a program at 0x1000, run from reset until it stops.
private func run(_ program: [UInt16], cycles: Int = 100_000) -> (stop: M68000Stop, registers: [UInt32], bus: RecordingBus) {
    let size = 65536
    let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    memory.initialize(repeating: 0, count: size)
    defer { memory.deallocate() }
    let bus = RecordingBus()
    var cpu = M68000(ram: memory, ramSize: size, bus: bus)
    defer { cpu.deallocate() }
    cpu.write32(0, 0x8000)
    cpu.write32(4, 0x1000)
    for (index, word) in program.enumerated() { cpu.write16(0x1000 + UInt32(index) * 2, UInt32(word)) }
    cpu.powerOn()
    cpu.reset()
    let stop = cpu.run(cycles: cycles)
    return (stop, (0 ..< 16).map { cpu.registers[$0] }, bus)
}

@Test func m68000AddsLoopsMultipliesAndDivides() {
    let result = run([
        0x7000, // moveq #0,d0
        0x7209, // moveq #9,d1
        0xD041, // loop: add.w d1,d0
        0x51C9, 0xFFFC, // dbra d1,loop: 9 + 8 + ... + 0 = 45
        0xC0FC, 0x0003, // mulu #3,d0: 135
        0x80FC, 0x0007, // divu #7,d0: 19, remainder 2
        0x4840, // swap d0
        0xE388, // lsl.l #1,d0
        0x48E7, 0xC000, // movem.l d0-d1,-(sp)
        0x4CDF, 0x000C, // movem.l (sp)+,d2-d3
        0x6100, 0x0004, // bsr.w sub
        0x4E70, // reset
        0x5282, // sub: addq.l #1,d2
        0x4E75, // rts
    ])
    #expect(result.stop == .reset)
    #expect(result.registers[0] == 0x0026_0004)
    #expect(result.registers[1] == 0x0000_FFFF)
    #expect(result.registers[2] == 0x0026_0005)
    #expect(result.registers[3] == 0x0000_FFFF)
    // The stack is back where it started.
    #expect(result.registers[15] == 0x8000)
}

@Test func m68000ReachesHardwareAndStopsAtWhatItCannotRun() {
    let result = run([
        0x41F9, 0x00FF, 0x8800, // lea $ff8800,a0
        0x10BC, 0x0007, // move.b #7,(a0)
        0x117C, 0x003E, 0x0002, // move.b #$3e,2(a0)
        0x31FC, 0x1234, 0x8802, // move.w #$1234,$ffff8802.w
        0x4E41, // trap #1
    ])
    #expect(result.stop == .trap(1))
    #expect(result.bus.writes.map(\.address) == [0xFF8800, 0xFF8802, 0xFF8802])
    #expect(result.bus.writes.map(\.value) == [7, 0x3E, 0x1234])

    #expect(run([0x4AFC]).stop == .illegal)
    // A loop that never ends is given up on.
    #expect(run([0x60FE], cycles: 1000).stop == .outOfTime)
}

@Test func m68000KeepsItsFlags() {
    // Each line sets D7 to 1 if the branch that should be taken is.
    let result = run([
        0x7E00, // moveq #0,d7
        0x303C, 0x7FFF, // move.w #$7fff,d0
        0x5240, // addq.w #1,d0: overflows into the sign
        0x6802, // bvc.s skip
        0x5247, // addq.w #1,d7
        0x7000, // skip: moveq #0,d0
        0x5340, // subq.w #1,d0: borrows
        0x6402, // bcc.s skip
        0x5247, // addq.w #1,d7
        0x0C40, 0xFFFF, // skip: cmpi.w #$ffff,d0
        0x6602, // bne.s skip
        0x5247, // addq.w #1,d7
        0x72FF, // skip: moveq #-1,d1
        0xE249, // lsr.w #1,d1: the bit that falls off is the carry
        0x6402, // bcc.s skip
        0x5247, // addq.w #1,d7
        0x4E70, // skip: reset
    ])
    #expect(result.stop == .reset)
    #expect(result.registers[7] == 4)
    #expect(result.registers[1] == 0xFFFF_7FFF)
}

/// Packs bytes as Ice would if it found nothing to squeeze: one run of bytes as they are.
private func icePacked(_ bytes: [UInt8]) -> [UInt8] {
    precondition((15 ..< 270).contains(bytes.count))
    // Read from the far end, top bit first: a run follows; its length is too long for the first four
    // ways of writing one (1, 11, 11, 111) and is given in eight bits, less fifteen.
    var bits: [Int] = [1, 1, 1, 1, 1, 1, 1, 1, 1]
    for place in stride(from: 7, through: 0, by: -1) { bits.append((bytes.count - 15) >> place & 1) }
    // The last byte holds seven of them above a marker; the bytes before it hold eight each.
    var commands: [UInt8] = []
    var last: UInt8 = 1
    for (place, bit) in bits.prefix(7).enumerated() where bit != 0 { last |= 0x80 >> UInt8(place) }
    commands.append(last)
    var rest = Array(bits.dropFirst(7))
    while !rest.isEmpty {
        var byte: UInt8 = 0
        for (place, bit) in rest.prefix(8).enumerated() where bit != 0 { byte |= 0x80 >> UInt8(place) }
        commands.insert(byte, at: 0)
        rest = Array(rest.dropFirst(8))
    }
    let size = 12 + bytes.count + commands.count
    func long(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 255), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)] }
    return Array("ICE!".utf8) + long(size) + long(bytes.count) + bytes + commands
}

/// A tune for the Atari ST, by hand: it sets channel A to a square wave of 492 Hz and leaves it there.
private func testTone() -> [UInt8] {
    func words(_ values: [UInt16]) -> [UInt8] { values.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] } }
    var header = Array("SNDH".utf8) + Array("TITL".utf8) + Array("Test tone".utf8) + [0]
    header += Array("COMM".utf8) + Array("siday".utf8) + [0]
    header += Array("YEAR".utf8) + Array("2026".utf8) + [0]
    header += Array("##01".utf8) + Array("TC50".utf8) + [0]
    header += Array("TIME".utf8)
    if (12 + header.count) & 1 != 0 { header.append(0) }
    header += [0, 3] + Array("HDNS".utf8)
    if header.count & 1 != 0 { header.append(0) }
    let start = 12 + header.count
    let code = words([
        0x41F9, 0x00FF, 0x8800, // lea $ff8800,a0
        0x10BC, 0x0000, 0x117C, 0x00FE, 0x0002, // tone A, low byte: 254, which is 125,000 / 254 Hz
        0x10BC, 0x0001, 0x117C, 0x0000, 0x0002, // tone A, high byte
        0x10BC, 0x0007, 0x117C, 0x003E, 0x0002, // only channel A's tone is on
        0x10BC, 0x0008, 0x117C, 0x000F, 0x0002, // at full volume
        0x4E75, // rts
    ])
    let exit = start + code.count - 2
    // Three ways in: start a song, stop, play a tick. The last two only return.
    return words([0x6000, UInt16(start - 2), 0x6000, UInt16(exit - 6), 0x6000, UInt16(exit - 10)]) + header + code
}

/// How much of a signal is at one frequency.
private func strength(_ samples: [Float], at hz: Double) -> Double {
    var real = 0.0, imaginary = 0.0
    for (index, sample) in samples.enumerated() {
        let angle = 2 * Double.pi * hz * Double(index) / Double(outputSampleRate)
        real += Double(sample) * Foundation.cos(angle)
        imaginary += Double(sample) * Foundation.sin(angle)
    }
    return (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
}

@Test func sndhTunePlaysAndSaysWhatItIs() throws {
    let renderer = try TuneLoader.load(testTone(), format: .sndh)
    #expect(renderer.info.format == "SNDH")
    #expect(renderer.info.title == "Test tone")
    #expect(renderer.info.author == "siday")
    #expect(renderer.info.detail == "2026, Atari ST")
    #expect(renderer.subsongCount == 1)
    #expect(renderer.knownLength == 3)

    let frames = outputSampleRate
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    let left = stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }
    let right = stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] }
    #expect(left == right)
    #expect(left.allSatisfy { $0.isFinite && abs($0) < 1 })
    // The note is there, and nothing much anywhere it is not.
    let note = strength(left, at: 125_000.0 / 254)
    #expect(note > 0.02)
    #expect(strength(left, at: 700) < note / 100)
    #expect(!renderer.hasEnded)
}

@Test func sndhTuneUnpacksFromIce() throws {
    let tune = testTone()
    let packed = icePacked(tune)
    #expect(ICE.isPacked(packed))
    #expect(ICE.unpack(packed) == tune)
    #expect(try TuneLoader.load(packed, format: .sndh).info.title == "Test tone")
    // A packed file cut short is refused, not read past its end.
    #expect(ICE.unpack(Array(packed.dropLast(3))) == nil)
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(packed.prefix(20)), format: .sndh) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("not a tune at all, whatever it says".utf8), format: .sndh) }
}

@Test func stSoundChipFilterKeepsFoldedTonesOut() {
    // A square wave of 13.9 kHz has a third harmonic at 41.7 kHz, which a host running at 48 kHz
    // hears, if it is let through, as a tone of 6.3 kHz that nobody played.
    func tone(filtered: Bool) -> [Float] {
        var chip = STSoundChip(hostRate: outputSampleRate)
        defer { chip.deallocate() }
        for (register, value) in [(0, 9), (1, 0), (7, 0x3E), (8, 15)] as [(UInt8, UInt8)] {
            chip.writePort(0, register)
            chip.writePort(2, value)
        }
        // Past the start, where the level is still settling to its centre.
        var samples: [Float] = []
        for index in 0 ..< 24000 {
            let sample = filtered ? chip.nextFiltered() : Float(chip.nextSample())
            if index >= 8000 { samples.append(sample / 32768) }
        }
        return samples
    }
    let note = 125_000.0 / 9, folded = 48000 - 3 * note
    let plain = tone(filtered: false), filtered = tone(filtered: true)
    // The note itself comes through either way, at much the same strength.
    #expect(strength(filtered, at: note) > strength(plain, at: note) * 0.7)
    // The plain average lets the folded tone through at a few hundredths of the note; the filter does not.
    #expect(strength(plain, at: folded) > strength(plain, at: note) / 100)
    #expect(strength(filtered, at: folded) < strength(filtered, at: note) / 3000)
}

// MARK: YM files

private func long(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 255), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)] }
private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 255), UInt8(value & 255)] }

/// A YM6 file of 100 ticks that holds channel A open at full volume with no tone: a steady level,
/// unless something is done to it between ticks.
/// - Parameter sidVoice: ask for the SID-voice effect on channel A, from a timer firing 3,072 times a second.
private func ym6(clock: Int, sidVoice: Bool) -> [UInt8] {
    var file = Array("YM6!LeOnArD!".utf8) + long(100) + long(0) + word(0) + long(clock) + word(50) + long(0) + word(0)
    file += Array("A level".utf8) + [0] + Array("siday".utf8) + [0] + [0]
    for _ in 0 ..< 100 {
        var registers = [UInt8](repeating: 0, count: 16)
        registers[7] = 0x3F
        registers[8] = 15
        registers[13] = 0xFF
        if sidVoice {
            registers[1] = 0x10 // the effect is on channel A
            registers[6] = 1 << 5 // the timer runs at a quarter of its clock
            registers[14] = 200 // and counts 200 of those: 2,457,600 / 4 / 200
        }
        file += registers
    }
    return file + Array("End!".utf8)
}

private func rendered(_ renderer: any Renderer, seconds: Double = 1) -> [Float] {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }
}

@Test func ymFilesFromTheAtariGoToTheAtari() throws {
    // Recorded at the ST's clock: the ST's to play.
    #expect(try TuneLoader.load(ym6(clock: 2_000_000, sidVoice: false), format: .ym) is STYMRenderer)
    // Another machine's clock and no effects: a plain recording, for any chip.
    #expect(!(try TuneLoader.load(ym6(clock: 1_000_000, sidVoice: false), format: .ym) is STYMRenderer))
    // Another clock, but with an effect only the ST's player does.
    #expect(try TuneLoader.load(ym6(clock: 1_000_000, sidVoice: true), format: .ym) is STYMRenderer)
    // And a chip asked for by name gets the plain recording whatever the file is.
    var options = LoadOptions()
    options.chipType = .ay
    #expect(!(try TuneLoader.load(ym6(clock: 2_000_000, sidVoice: true), format: .ym, options: options) is STYMRenderer))

    // The oldest kinds are the ST's by definition.
    var registers = [UInt8](repeating: 0, count: 14)
    registers[0] = 254
    registers[7] = 0x3E
    registers[8] = 15
    registers[13] = 0xFF
    // A register at a time: fifty ticks of register 0, then fifty of register 1, and so on.
    let old = Array("YM3!".utf8) + registers.flatMap { [UInt8](repeating: $0, count: 50) }
    let renderer = try TuneLoader.load(old, format: .ym)
    #expect(renderer is STYMRenderer)
    #expect(renderer.info.format == "YM3")
    #expect(renderer.info.detail == "Atari ST")
    #expect(abs((renderer.knownLength ?? 0) - 1) < 0.01)
    let sound = rendered(renderer)
    #expect(strength(sound, at: 125_000.0 / 254) > 0.02)
}

@Test func ymSidVoiceIsPlayedBetweenTicks() throws {
    // The timer switches the channel's volume between full and nothing each time it fires, which
    // makes a square wave of half its rate out of a level that the registers alone leave steady.
    let note = 2_457_600.0 / 4 / 200 / 2
    let with = rendered(try TuneLoader.load(ym6(clock: 2_000_000, sidVoice: true), format: .ym))
    let without = rendered(try TuneLoader.load(ym6(clock: 2_000_000, sidVoice: false), format: .ym))
    #expect(strength(with, at: note) > 0.02)
    #expect(strength(without, at: note) < 0.0005)
}

@Test func ymFilesOfSamplesArePlayedAsSamples() throws {
    // A digi-mix of one piece: a square wave of 500 Hz sampled 8,000 times a second, played four times over.
    let wave = (0 ..< 800).map { UInt8(bitPattern: $0 / 8 % 2 == 0 ? 100 : -100) }
    var file = Array("MIX1LeOnArD!".utf8) + long(1) + long(wave.count) + long(1)
    file += long(0) + long(wave.count) + word(4) + word(8000)
    file += Array("Square".utf8) + [0] + Array("siday".utf8) + [0] + [0]
    file += wave
    let renderer = try TuneLoader.load(file, format: .ym)
    #expect(renderer is STSampleRenderer)
    #expect(renderer.info.format == "MIX1")
    #expect(renderer.info.title == "Square")
    #expect(abs((renderer.knownLength ?? 0) - 0.4) < 0.001)
    let sound = rendered(renderer, seconds: 0.5)
    #expect(strength(sound, at: 500) > 0.05)
    #expect(strength(sound, at: 700) < 0.005)
    // It has been once round its list of pieces by now.
    #expect(renderer.loopCount == 1)
}
