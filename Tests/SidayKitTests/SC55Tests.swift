// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
@testable import SidayEightBit
@testable import SidayFoundation
@testable import SidayPlayer
@testable import SidaySC55
import Testing

// Fast checks of the Sound Canvas's side, with no ROMs (siday has none of its own): the digest its ROMs are known
// by, which synthesiser a MIDI file is played on, and the parts of the controller and the PCM chip that need no
// firmware. The thorough check is made outside the package, against Nuked SC-55 given the same bytes at the same
// frames: the two make the same output, sample for sample.

@Test func sha256MatchesTheStandardsExamples() {
    #expect(SHA256.hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(SHA256.hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(SHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(SHA256.hex([UInt8](repeating: 0x61, count: 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}

/// Made-up ROMs of an SC-55, and a table of them as Nuked SC-55's has the real ones.
private struct MadeUpCanvas {
    let program = (0 ..< 32768).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) }
    let extra = (0 ..< 262_144).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 7) }
    let waves = (0 ..< 3).map { n in (0 ..< 1_048_576).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761 &+ n) >> 9) } }

    var table: [SC55ROMFile] {
        [SC55ROMFile(role: .program(versions: ["1.21"]), part: "P", size: 32768, sha256: SHA256.hex(program)),
         SC55ROMFile(role: .extraProgram(version: "1.21"), part: "E", size: 262_144, sha256: SHA256.hex(extra))]
            + (0 ..< 3).map { SC55ROMFile(role: .wave($0), part: "W\($0)", size: 1_048_576, sha256: SHA256.hex(waves[$0])) }
    }
}

@Test func sc55ROMsAreKnownByContentAndMakeASetOnlyWhenWhole() {
    let roms = MadeUpCanvas()
    let table = roms.table
    let noise = (0 ..< 1000).map { UInt8(truncatingIfNeeded: $0) }
    // In any order, among other files.
    let set = SC55ROMSet.assemble([roms.waves[2], noise, roms.extra, roms.waves[0], roms.program, roms.waves[1]], table: table)
    #expect(set?.version == "1.21")
    #expect(set?.program == roms.program)
    #expect(set?.extraProgram == roms.extra)
    #expect(set?.waves == roms.waves)
    // The same files again, with the set they made before, give that set back as it is (its synthesiser
    // not started again: a set marked as started otherwise keeps its mark); other files make another.
    let marked = set.map { SC55ROMSet(version: $0.version, program: $0.program, extraProgram: $0.extraProgram, waves: $0.waves, started: [1, 2, 3]) }
    #expect(SC55ROMSet.assemble([roms.program, roms.extra] + roms.waves, table: table, reusing: marked)?.started == [1, 2, 3])
    var otherWave = roms.waves[1]
    otherWave[7] ^= 1
    let otherTable = table.map { $0.role == .wave(1) ? SC55ROMFile(role: $0.role, part: $0.part, size: $0.size, sha256: SHA256.hex(otherWave)) : $0 }
    #expect(SC55ROMSet.assemble([roms.program, roms.extra, roms.waves[0], otherWave, roms.waves[2]], table: otherTable, reusing: marked)?.started.count == set?.started.count)
    // Not without a wave ROM, nor without either program ROM.
    #expect(SC55ROMSet.assemble([roms.extra, roms.program, roms.waves[0], roms.waves[1]], table: table) == nil)
    #expect(SC55ROMSet.assemble([roms.program] + roms.waves, table: table) == nil)
    // A file of the right size but other content is not one.
    var changed = roms.program
    changed[100] ^= 1
    #expect(SC55ROMFile.identify(changed, in: table) == nil)
    // Nor, against the real table, are made-up ones; but their sizes are looked at.
    #expect(SC55ROMFile.identify(roms.program) == nil)
    #expect(KeptFile.recognise(roms.waves[0]) == nil)
    #expect(KeptFile.mayBe(size: 262_144, start: []))
}

@Test func eachMIDIFileGoesToTheSynthesiserOfItsKindWhoseROMsAreHad() {
    for mt32 in [false, true] {
        for canvas in [false, true] {
            // A file written for the MT-32: its own synthesiser first, then the Sound Canvas, then FM.
            #expect(MIDISynthesiser.choose(writtenForMT32: true, mt32ROMs: mt32, sc55ROMs: canvas) == (mt32 ? .la32 : canvas ? .sc55 : .fm))
            // Any other (General MIDI, GS, XG): the Sound Canvas if it is had, never the MT-32.
            #expect(MIDISynthesiser.choose(writtenForMT32: false, mt32ROMs: mt32, sc55ROMs: canvas) == (canvas ? .sc55 : .fm))
        }
    }
}

private func be32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

/// A MIDI file of one track: these events, then a note.
private func midi(_ events: [UInt8]) -> [UInt8] {
    let body = events + [0x00, 0x91, 60, 100, 0x60, 0x81, 60, 0, 0x00, 0xFF, 0x2F, 0x00]
    return Array("MThd".utf8) + be32(6) + [0, 0, 0, 1, 0, 96] + Array("MTrk".utf8) + be32(body.count) + body
}

private let mt32Message: [UInt8] = [0x00, 0xF0, 0x09, 0x41, 0x10, 0x16, 0x12, 0x10, 0x00, 0x01, 0x02, 0x6D, 0xF7]
private let gsReset: [UInt8] = [0x00, 0xF0, 0x0A, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]
private let xgOn: [UInt8] = [0x00, 0xF0, 0x08, 0x43, 0x10, 0x4C, 0x00, 0x00, 0x7E, 0x00, 0xF7]

@Test func withAnSC55sROMsMIDIFilesPlayOnItAndSayWhatTheyLose() throws {
    // ROMs of nothing (the controller runs through nothing, and the chip is silent): enough to see where a file
    // goes and what is said of it.
    var options = LoadOptions()
    options.sc55ROMs = SC55ROMSet(version: "1.21", program: [UInt8](repeating: 0, count: 32768), extraProgram: [UInt8](repeating: 0, count: 262_144),
                                  waves: [[UInt8]](repeating: [UInt8](repeating: 0, count: 1_048_576), count: 3))
    let gs = try TuneLoader.load(midi(gsReset), format: .mid, options: options)
    #expect(gs.info.chips == [.sc55])
    #expect(gs.info.shortfalls.isEmpty)
    #expect(gs.channelCount == 16)
    let plain = try TuneLoader.load(midi([]), format: .mid, options: options)
    #expect(plain.info.chips == [.sc55])
    let xg = try TuneLoader.load(midi(xgOn), format: .mid, options: options)
    #expect(xg.info.shortfalls.contains { $0.contains("XG") })
    let mt32 = try TuneLoader.load(midi(mt32Message), format: .mid, options: options)
    #expect(mt32.info.chips == [.sc55])
    #expect(mt32.info.detail.contains("MT-32 sounds"))
    #expect(mt32.info.shortfalls.contains { $0.contains("SCMODE") })
    // Without them, on FM, as before.
    #expect(try TuneLoader.load(midi(gsReset), format: .mid).info.chips == [.opl3])
    // The level kept for a song says it was played on the SC-55.
    var buffer = [Float](repeating: 0, count: 2048)
    buffer.withUnsafeMutableBufferPointer { gs.render(into: $0.baseAddress!, frames: 1024) }
    #expect(SongLevel.playedOn(gs, options: options) == "sc55_1.21")
}

/// A controller with a program of its own in its ROM, run until it sleeps.
private func run(_ program: [UInt8: [UInt8]], vectors: [Int: UInt32] = [:], steps: Int = 40) -> SC55MCU {
    var rom = [UInt8](repeating: 0, count: 32768)
    for (vector, address) in vectors.merging([0: 0x100], uniquingKeysWith: { a, _ in a }) {
        for i in 0 ..< 4 { rom[vector * 4 + i] = UInt8(truncatingIfNeeded: address >> UInt32(24 - i * 8)) }
    }
    for (page, code) in program { for (i, byte) in code.enumerated() { rom[Int(page) << 8 + i] = byte } }
    let mcu = SC55MCU(rom1: rom, rom2: [UInt8](repeating: 0, count: 262_144), pcm: SC55PCM(waves: []))
    mcu.reset()
    for _ in 0 ..< steps { mcu.step() }
    return mcu
}

@Test func theControllersInstructionsDoWhatTheH8500Does() {
    // MOV:I, ADD.W into an overflow: 7FFF + 1 is 8000, negative, overflowed, no carry.
    let add = run([1: [0x5F, 0xFE, 0x00, 0x58, 0x7F, 0xFF, 0x59, 0x00, 0x01, 0xA9, 0x20, 0x1A]])
    #expect(add.r[0] == 0x8000)
    #expect(add.sr & SC55MCU.statusV != 0)
    #expect(add.sr & SC55MCU.statusN != 0)
    #expect(add.sr & SC55MCU.statusC == 0)
    #expect(add.sleeping)
    // MULXU.W into a pair of registers, and DIVXU.W back: 1234 x 10 = 12340, and back with nothing over.
    let multiply = run([1: [0x5A, 0x12, 0x34, 0x59, 0x00, 0x10, 0xA9, 0xAA, 0x1A]])
    #expect(multiply.r[2] == 0x0001)
    #expect(multiply.r[3] == 0x2340)
    let divide = run([1: [0x5A, 0x12, 0x34, 0x59, 0x00, 0x10, 0xA9, 0xAA, 0xA9, 0xBA, 0x1A]])
    #expect(divide.r[2] == 0)
    #expect(divide.r[3] == 0x1234)
    // A word read at an odd address is an address error: its vector's handler runs (here it sets R5 and
    // returns), as the SC-55's firmware meets once as it starts.
    let odd = run([1: [0x5F, 0xFE, 0x00, 0x5B, 0x00, 0x01, 0xFB, 0x80, 0x00, 0x84, 0x1A], 2: [0x55, 0x77, 0x0A]], vectors: [8: 0x200])
    #expect(odd.r[5] == 0x77)
    #expect(odd.pc == 0x10B)
    #expect(odd.sleeping)
}

@Test func thePCMChipsArithmeticIsItsTwentyBitOwn() {
    #expect(SC55PCM.sx20(0x80000) == -524_288)
    #expect(SC55PCM.sx20(0x7FFFF) == 524_287)
    // Its adders do not clip, for all their name: they wrap at twenty bits only as their inputs are read.
    #expect(SC55PCM.addclip20(0x7FFFF, 1, 0) == 0x80000)
    #expect(SC55PCM.multi(Int32(0xFFFFF), 127) == -127)
    // The effects' RAM keeps 14 bits and a shift: small values exactly, large ones to their top 14 bits.
    let pcm = SC55PCM(waves: [])
    for value: Int32 in [0x123, -256, 0x1FFF, 0x40000, -0x40000] {
        pcm.eramPack(5, UInt32(bitPattern: value) & 0xFFFFF)
        #expect(pcm.eramUnpack(5) == value)
    }
    pcm.eramPack(6, 0x40001)
    #expect(pcm.eramUnpack(6) == 0x40000)
}

@Test func theWaveROMsLinesArePutBackInOrder() {
    // The chip's address line 0 is the ROM's line 2, and its data line 0 the ROM's line 2.
    var source = [UInt8](repeating: 0, count: 1 << 20)
    source[4] = 0x04
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    defer { destination.deallocate() }
    SC55PCM.unscramble(source, into: destination, count: 1 << 20)
    #expect(destination[1] == 0x01)
    #expect(destination[0] == 0)
    #expect(destination[4] == 0)
}

@Test func aSynthesiserStartedOnceIsTheSameEachTimeItIsPutBack() {
    // ROMs of made-up bytes: run as a program, they touch much of what the controller and the chip keep.
    var random: UInt32 = 0x1234_5678
    func bytes(_ count: Int) -> [UInt8] {
        (0 ..< count).map { _ in
            random ^= random << 13
            random ^= random >> 17
            random ^= random << 5
            return UInt8(truncatingIfNeeded: random)
        }
    }
    let plain = SC55ROMSet(version: "1.21", program: bytes(32768), extraProgram: bytes(262_144), waves: [bytes(1 << 20), bytes(1 << 20), bytes(1 << 20)])
    let first = SC55Synth(roms: plain)
    first.start()
    let started = SC55ROMSet(version: "1.21", program: plain.program, extraProgram: plain.extraProgram, waves: plain.waves,
                             unscrambledWaves: first.unscrambledWaves, started: first.state)
    let again = SC55Synth(roms: started)
    again.start()
    #expect(again.state == first.state)
    // And the two go on the same, given the same bytes.
    let a = UnsafeMutablePointer<Int32>.allocate(capacity: 6400 * 2), b = UnsafeMutablePointer<Int32>.allocate(capacity: 6400 * 2)
    defer {
        a.deallocate()
        b.deallocate()
    }
    for synth in [first, again] { synth.schedule([0x90, 60, 100], at: 10) }
    first.render(into: a, frames: 6400)
    again.render(into: b, frames: 6400)
    #expect((0 ..< 6400 * 2).allSatisfy { a[$0] == b[$0] })
    #expect(again.state == first.state)
}
