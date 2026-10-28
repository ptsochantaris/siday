// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
@testable import SidayEightBit
import SidayFiles
@testable import SidayFoundation
@testable import SidayMT32
@testable import SidayPlayer
import Testing

// Fast checks of the MT-32's side, with no ROMs (siday has none of its own): the digests ROMs are known by,
// how the halves of a split ROM are joined, the files siday keeps and where, which synthesiser a MIDI file
// is played on, and the parts of the synthesiser that need no ROM. The thorough check is made outside the
// package, against Munt's libmt32emu given the same messages at the same samples: the two make the same
// output, sample for sample.

@Test func sha1MatchesTheStandardsExamples() {
    #expect(SHA1.hex([]) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    #expect(SHA1.hex(Array("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    #expect(SHA1.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    #expect(SHA1.hex([UInt8](repeating: 0x61, count: 1_000_000)) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
}

/// Made-up ROMs, and a table of them as Munt's has the real ones: a control ROM, whole, and a PCM ROM in two
/// halves, and a control ROM in even and odd bytes.
private struct MadeUpROMs {
    let control = (0 ..< 65536).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
    // (Of no period, so that its halves differ.)
    let pcm = (0 ..< 1_048_576).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }
    var low: [UInt8] { Array(pcm[..<524_288]) }
    var high: [UInt8] { Array(pcm[524_288...]) }
    var even: [UInt8] { stride(from: 0, to: 65536, by: 2).map { control[$0] } }
    var odd: [UInt8] { stride(from: 1, to: 65536, by: 2).map { control[$0] } }

    var table: [MT32ROMFile] {
        [
            MT32ROMFile(id: "ctrl_cm32l_1_00", name: "control", kind: .control, piece: .full, size: 65536, sha1: SHA1.hex(control), whole: "ctrl_cm32l_1_00"),
            MT32ROMFile(id: "ctrl_cm32l_1_02", name: "other control", kind: .control, piece: .full, size: 65536, sha1: SHA1.hex(control.reversed()), whole: "ctrl_cm32l_1_02"),
            MT32ROMFile(id: "ctrl_mt32_1_07_a", name: "even", kind: .control, piece: .evenBytes, size: 32768, sha1: SHA1.hex(even), whole: "ctrl_cm32l_1_02"),
            MT32ROMFile(id: "ctrl_mt32_1_07_b", name: "odd", kind: .control, piece: .oddBytes, size: 32768, sha1: SHA1.hex(odd), whole: "ctrl_cm32l_1_02"),
            MT32ROMFile(id: "pcm_cm32l", name: "pcm", kind: .pcm, piece: .full, size: 1_048_576, sha1: SHA1.hex(pcm), whole: "pcm_cm32l"),
            MT32ROMFile(id: "pcm_mt32", name: "pcm first half", kind: .pcm, piece: .full, size: 524_288, sha1: SHA1.hex(low), whole: "pcm_mt32"),
            MT32ROMFile(id: "pcm_cm32l_h", name: "pcm second half", kind: .pcm, piece: .secondHalf, size: 524_288, sha1: SHA1.hex(high), whole: "pcm_cm32l"),
        ]
    }
}

@Test func romsAreKnownByContentAndHalvesAreJoinedAsMuntJoinsThem() {
    let roms = MadeUpROMs()
    let table = roms.table
    // Whole files, in any order and among others.
    let whole = MT32ROMSet.assemble([[1, 2, 3], roms.pcm, roms.control], controls: [.cm32l_1_00], table: table)
    #expect(whole?.control == .cm32l_1_00)
    #expect(whole?.pcmData == roms.pcm)
    // The PCM ROM as the MT-32's whole one and the CM-32L's second half, appended in that order.
    let halves = MT32ROMSet.assemble([roms.high, roms.control, roms.low], controls: [.cm32l_1_00], table: table)
    #expect(halves?.pcmData == roms.pcm)
    // Without its second half, no set.
    #expect(MT32ROMSet.assemble([roms.control, roms.low], controls: [.cm32l_1_00], table: table) == nil)
    // A control ROM joined from even and odd bytes is kept only if what is joined is the whole ROM it
    // should be: here it is not (the made-up whole of that name is another), so there is no set of it.
    #expect(MT32ROMSet.assemble([roms.even, roms.odd, roms.pcm], controls: [.cm32l_1_02], table: table) == nil)
    // Names count for nothing: the real table knows none of these bytes.
    #expect(MT32ROMFile.identify(roms.control) == nil)
    #expect(MT32ROMFile.identify([UInt8](repeating: 0, count: 65536)) == nil)
    // Every ROM Munt knows is in the real table once, by size and digest.
    #expect(Set(MT32ROMFile.known.map { "\($0.size) \($0.sha1) \($0.id)" }).count == MT32ROMFile.known.count)
    #expect(MT32ROMFile.identify(size: 65536, sha1: "73683d585cd6948cc19547942ca0e14a0319456d")?.id == "ctrl_cm32l_1_00")
    #expect(MT32ROMFile.identify(size: 524_288, sha1: "3ad889fde5db5b6437cbc2eb6e305312fec3df93")?.whole == "pcm_cm32l")
}

/// A list of song lengths, as HVSC writes them.
private let songLengths = Array("[Database]\r\n; /MUSICIANS/X/Tune.sid\r\n0123456789abcdef0123456789abcdef=1:30 0:45\r\n".utf8)

@Test func keptFilesAreKeptByContentInTheirFolderAndForgotten() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("siday-kept-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = KeptFileStore(folder: folder)
    var kept = store.load()
    #expect(kept.files.isEmpty)
    #expect(kept.summary.isEmpty)
    // Not a file siday keeps: nothing is written.
    #expect(try store.keep(Array("hello".utf8), in: &kept) == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    // A list of song lengths, kept under its digest, and read back by a store of the same folder.
    let added = try #require(try store.keep(songLengths, in: &kept))
    #expect(added.file.kind == .songLengths)
    #expect(added.file.keptName == "songlengths-" + SHA1.hex(songLengths))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [added.file.keptName])
    #expect(try store.keep(songLengths, in: &kept) == nil)
    let again = KeptFileStore(folder: folder).load()
    #expect(again.files == [added.file])
    #expect(again.songLengths != nil)
    // A newer list replaces it.
    let newer = songLengths + Array("fedcba9876543210fedcba9876543210=2:00\r\n".utf8)
    let replacing = try #require(try store.keep(newer, in: &kept))
    #expect(replacing.replaced == [added.file])
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [replacing.file.keptName])
    // Forgotten, file and all.
    store.forgetAll(in: &kept)
    #expect(kept.files.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
}

@Test func aReadOnlyStoreIsNeverWritten() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("siday-kept-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // Files of any names in it are known by what is in them.
    try Data(songLengths).write(to: folder.appendingPathComponent("anything.txt"))
    let store = KeptFileStore(folder: folder, readOnly: true)
    var kept = store.load()
    #expect(kept.files.map(\.kind) == [.songLengths])
    store.forgetAll(in: &kept)
    #expect(kept.files.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["anything.txt"])
    let newer = songLengths + Array("fedcba9876543210fedcba9876543210=2:00\r\n".utf8)
    #expect(try store.keep(newer, in: &kept) != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["anything.txt"])
}

private func be32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

/// A MIDI file of one track: these events, then a note.
private func midi(_ events: [UInt8]) -> [UInt8] {
    let body = events + [0x00, 0x91, 60, 100, 0x60, 0x81, 60, 0, 0x00, 0xFF, 0x2F, 0x00]
    return Array("MThd".utf8) + be32(6) + [0, 0, 0, 1, 0, 96] + Array("MTrk".utf8) + be32(body.count) + body
}

/// A DT1 to the MT-32: its reverb, at 10 00 01.
private let mt32Message: [UInt8] = [0x00, 0xF0, 0x09, 0x41, 0x10, 0x16, 0x12, 0x10, 0x00, 0x01, 0x02, 0x6D, 0xF7]
/// A GS reset.
private let gsReset: [UInt8] = [0x00, 0xF0, 0x0A, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]

@Test func onlyFilesWrittenForTheMT32GoToItsSynthesiserAndWithoutROMsAllPlayOnFM() throws {
    #expect(MIDIFMRenderer.isWrittenForMT32(midi(mt32Message), companion: nil))
    #expect(!MIDIFMRenderer.isWrittenForMT32(midi([]), companion: nil))
    // Roland's own GS files that set an MT-32 up beside the Sound Canvas are GS files.
    #expect(!MIDIFMRenderer.isWrittenForMT32(midi(gsReset + mt32Message), companion: nil))
    // A file of no messages of its own, with the MT-32's beside it.
    #expect(MIDIFMRenderer.isWrittenForMT32(midi([]), companion: [0xF0, 0x41, 0x10, 0x16, 0x12, 0x10, 0x00, 0x01, 0x02, 0x6D, 0xF7]))
    // With no ROMs, on the OPL3, saying how the ROMs are given.
    let renderer = try TuneLoader.load(midi(mt32Message), format: .mid)
    #expect(renderer.info.chips == [.opl3])
    #expect(renderer.info.shortfalls.contains { $0.contains("--roms") })
}

@Test func theLevelsKeySaysTheSynthesiserOnlyWhereItIsTheMT32s() {
    let options = LoadOptions()
    let policy = PlaybackPolicy()
    let plain = SongLevel.key(digest: "d", song: 0, options: options, policy: policy)
    #expect(SongLevel.key(digest: "d", song: 0, options: options, policy: policy, playedOn: nil) == plain)
    #expect(SongLevel.key(digest: "d", song: 0, options: options, policy: policy, playedOn: "ctrl_cm32l_1_00") == plain + " on=ctrl_cm32l_1_00")
}

@Test func la32RampsAndArithmeticAreTheChipsOwn() {
    // A ramp up at the fastest reaches its target in under a hundred samples, and tells the controller
    // seven samples later.
    var ramp = LA32Ramp()
    ramp.startRamp(100, 127)
    var steps = 0
    while ramp.nextValue() < 100 << 18 { steps += 1 }
    var told = 0
    while !ramp.checkInterrupt() {
        _ = ramp.nextValue()
        told += 1
    }
    #expect(steps > 0 && steps < 100)
    #expect(told == 7)
    // A speed of nought changes nothing, and never ends.
    ramp.startRamp(0, 0)
    for _ in 0 ..< 100 {
        let value = ramp.nextValue()
        #expect(value == 100 << 18)
    }
    let raised = ramp.checkInterrupt()
    #expect(!raised)
    // Nought in the logarithm is the loudest; each 4,096 more halves it.
    #expect(LA32Maths.unlog(LogSample(logValue: 0, negative: false)) == 8189)
    #expect(LA32Maths.unlog(LogSample(logValue: 4096, negative: true)) == -4094)
    #expect(LA32Maths.unlog(.silence) == 0)
}

@Test func theAccurateAnalogueStageMakesThreeSamplesOfTwo() {
    var filter = MT32LowPassFilter(mode: .accurate, oldMT32: false)
    #expect(filter.inputCount(for: 3) == 2)
    #expect(filter.inputCount(for: 48000) == 32000)
    // Silence in, silence out.
    for _ in 0 ..< 30 {
        let value = filter.process(0)
        #expect(value == 0)
    }
    var coarse = MT32LowPassFilter(mode: .coarse, oldMT32: false)
    #expect(coarse.inputCount(for: 100) == 100)
    // A step through the short filter settles at its gain, a little under one (its taps add up to 16,301
    // sixteen-thousand-three-hundred-and-eighty-fourths).
    var last: Int32 = 0
    for _ in 0 ..< 20 { last = coarse.process(10000) }
    #expect(last == 9949)
}

@Test func theBossReverbIsQuietForQuietAndRingsAfterASound() {
    let reverb = BossReverb(mode: 0, mt32Compatible: false)
    reverb.open()
    reverb.setParameters(time: 5, level: 3)
    var left = [Int16](repeating: 0, count: 4000), right = left
    let zeros = [Int16](repeating: 0, count: 4000)
    reverb.process(inLeft: zeros, inRight: zeros, outLeft: &left, outRight: &right, count: 4000)
    #expect(left.allSatisfy { $0 == 0 } && right.allSatisfy { $0 == 0 })
    #expect(!reverb.isActive)
    var click = zeros
    click[0] = 16000
    reverb.process(inLeft: click, inRight: click, outLeft: &left, outRight: &right, count: 4000)
    #expect(left.contains { $0 != 0 })
    #expect(reverb.isActive)
}
