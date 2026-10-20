// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Checks of the reading of Channel Player's music, on small files made here in each of its three
// versions. The thorough check is made outside the package: the modules made of Fury of the Furries'
// nine tunes are played by UADE's ProTracker player the same to the tick as UADE plays the files
// themselves, through Deli-Wizard.

private func be16(_ value: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

private func be32(_ value: Int) -> [UInt8] {
    be16(value >> 16) + be16(value)
}

/// A sample: its length and its loop's in words, its volume, where its loop begins in bytes, and its
/// finetune.
private struct Sample {
    var length: Int
    var volume = 64
    var loop = 0
    var loopLength = 1
    var finetune = 0
}

/// A file of Channel Player's: the samples' headers, the order (each place's bytes), the notes, and the
/// samples, each sample's bytes counting up from its number times sixteen.
private func channelFile(_ samples: [Sample], places: [[UInt8]], notes: [UInt8]) -> [UInt8] {
    let order = places.flatMap { $0 }
    let sampleBytes = samples.reduce(0) { $0 + $1.length * 2 }
    var file = be16(10 + samples.count * 16) + be16(order.count) + be16(notes.count) + be32(sampleBytes)
    var start = 0
    for sample in samples {
        file += be32(start) + be16(sample.length) + be16(sample.volume) + be32(start + sample.loop) + be16(sample.loopLength) + be16(sample.finetune * 72)
        start += sample.length * 2
    }
    file += order + notes
    for (number, sample) in samples.enumerated() {
        file += (0 ..< sample.length * 2).map { UInt8(truncatingIfNeeded: number * 16 + $0) }
    }
    return file
}

/// A note of the module made, from its four bytes: the period, the sample, the command and its parameter.
private func note(_ module: [UInt8], pattern: Int, line: Int, voice: Int) -> (period: Int, sample: Int, command: Int, parameter: Int) {
    let at = 1084 + pattern * 1024 + line * 16 + voice * 4
    return ((Int(module[at]) & 0x0F) << 8 | Int(module[at + 1]), Int(module[at]) & 0xF0 | Int(module[at + 2]) >> 4, Int(module[at + 2]) & 0x0F, Int(module[at + 3]))
}

private let twoSamples = [Sample(length: 4, volume: 40, loop: 2, loopLength: 3, finetune: 2), Sample(length: 2, finetune: 13)]

/// The first version: tracks by number, three bytes a line. Track 0 has notes and commands of each
/// kind; track 1 the highest notes and one past the table.
private let versionOne: [UInt8] = {
    var track0 = [UInt8](repeating: 0, count: 0xC0)
    let lines: [[UInt8]] = [
        [2, 0x10, 0x00], // C-1 (856), sample 1
        [27, 0x2D, 60], // C-2 (428) of sample 18, a break to line 60
        [0, 0x0A, 0xF6], // the volume down by 10
        [0, 0x05, 0x23], // the volume up by 3, with a slide to the note
        [0, 0x06, 0xF0], // nothing up, nothing down
        [0, 0x0F, 0x06], // speed 6
        [1, 0x00, 0x00], // a sample above the fifteenth, of no note
    ]
    for (line, bytes) in lines.enumerated() { track0.replaceSubrange(line * 3 ..< line * 3 + 3, with: bytes) }
    var track1 = [UInt8](repeating: 0, count: 0xC0)
    track1[0] = 72 // B-3 (113)
    track1[3] = 80 // past B-3: B-3 again
    track1[6] = 92 // past the table
    return channelFile(twoSamples, places: [[0, 1, 0, 1], [1, 1, 1, 1], [0, 1, 0, 1]], notes: track0 + track1)
}()

/// The second version: tracks by where they begin, lines of two bytes or three.
private let versionTwo: [UInt8] = {
    var a: [UInt8] = [0x02, 0x1C, 0x40] // C-1, sample 1, volume 64
    a += [0x80, 0x0D] // a command alone: break
    a += [0x80 + 24, 0x23] // B-1 (453), sample 2 and command 3
    a += [UInt8](repeating: 0, count: 61 * 3)
    // A track of commands alone, of nothing.
    var bTrack: [UInt8] = []
    for _ in 0 ..< 64 { bTrack += [0x80, 0x00] }
    let place = be16(0) + be16(a.count) + be16(a.count) + be16(0)
    return channelFile(twoSamples, places: [place, place], notes: a + bTrack)
}()

/// The third version: and lines of a byte.
private let versionThree: [UInt8] = {
    var c: [UInt8] = [0x80, 0x80, 0x80, 0x80, 0x80] // lines 0 to 4: nothing
    c += [0x00, 0x0A, 0x02] // no note, the volume up by 2
    c += [0x82] // C-1 alone
    c += [0x04, 0x1C, 0x20] // D-1 (808), sample 1, volume 32
    c += [UInt8](repeating: 0x80, count: 56)
    let place = be16(0) + be16(0) + be16(0) + be16(0)
    return channelFile(twoSamples, places: [place], notes: c)
}()

@Test func channelPlayerIsAskedLast() {
    #expect(ProWizard.Packer.allCases.last == .channelPlayer)
    #expect(TuneFormat(fileExtension: "chan") == .mod)
}

@Test func channelPlayerVersionsAreTold() {
    #expect(ChannelPlayer.version(versionOne) == .one)
    #expect(ChannelPlayer.version(versionTwo) == .two)
    #expect(ChannelPlayer.version(versionThree) == .three)
    for file in [versionOne, versionTwo, versionThree] {
        #expect(ProWizard.packer(of: file) == .channelPlayer)
    }
}

@Test func channelPlayerFirstVersionIsUnpacked() throws {
    let (name, module) = try #require(ProWizard.unpack(versionOne))
    #expect(name == "Channel Player")
    // Two patterns, and the samples after them.
    #expect(module.count == 1084 + 2 * 1024 + 12)
    #expect(Array(module[1080 ..< 1084]) == Array("M.K.".utf8))
    #expect(module[950] == 3 && module[951] == 0x7F)
    #expect(Array(module[952 ..< 956]) == [0, 1, 0, 0])
    #expect(module[0 ..< 20].allSatisfy { $0 == 0 })

    // The samples' headers: the loop from where it is, the finetune from its multiple of 72, and the
    // rest of the 31 of no length and a loop of a word.
    #expect(Array(module[42 ..< 50]) == [0, 4, 2, 40, 0, 1, 0, 3])
    #expect(Array(module[72 ..< 80]) == [0, 2, 13, 64, 0, 0, 0, 1])
    #expect(Array(module[102 ..< 110]) == [0, 0, 0, 0, 0, 0, 0, 1])
    #expect(Array(module[1084 + 2048 ..< module.count]) == [0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19])

    // Pattern 0, the tracks 0, 1, 0, 1.
    #expect(note(module, pattern: 0, line: 0, voice: 0) == (856, 1, 0, 0))
    #expect(note(module, pattern: 0, line: 1, voice: 0) == (428, 18, 0xD, 0x60))
    #expect(note(module, pattern: 0, line: 2, voice: 0) == (0, 0, 0xA, 0x0A))
    #expect(note(module, pattern: 0, line: 3, voice: 0) == (0, 0, 0x5, 0x30))
    #expect(note(module, pattern: 0, line: 4, voice: 0) == (0, 0, 0x6, 0x00))
    #expect(note(module, pattern: 0, line: 5, voice: 0) == (0, 0, 0xF, 0x06))
    #expect(note(module, pattern: 0, line: 6, voice: 0) == (0, 16, 0, 0))
    #expect(note(module, pattern: 0, line: 1, voice: 2) == (428, 18, 0xD, 0x60))
    #expect(note(module, pattern: 0, line: 0, voice: 1) == (113, 0, 0, 0))
    #expect(note(module, pattern: 0, line: 1, voice: 1) == (113, 0, 0, 0))
    #expect(note(module, pattern: 0, line: 2, voice: 1) == (0, 0, 0, 0))
    // Pattern 1, track 1 four times.
    for voice in 0 ..< 4 {
        #expect(note(module, pattern: 1, line: 0, voice: voice) == (113, 0, 0, 0))
    }
}

@Test func channelPlayerSecondVersionIsUnpacked() throws {
    let (_, module) = try #require(ProWizard.unpack(versionTwo))
    #expect(module.count == 1084 + 1024 + 12)
    #expect(module[950] == 2 && Array(module[952 ..< 954]) == [0, 0])
    for voice in [0, 3] {
        #expect(note(module, pattern: 0, line: 0, voice: voice) == (856, 1, 0xC, 0x40))
        #expect(note(module, pattern: 0, line: 1, voice: voice) == (0, 0, 0xD, 0))
        #expect(note(module, pattern: 0, line: 2, voice: voice) == (453, 2, 3, 0))
        #expect(note(module, pattern: 0, line: 3, voice: voice) == (0, 0, 0, 0))
    }
    for voice in [1, 2] {
        #expect(note(module, pattern: 0, line: 0, voice: voice) == (0, 0, 0, 0))
        #expect(note(module, pattern: 0, line: 63, voice: voice) == (0, 0, 0, 0))
    }
}

@Test func channelPlayerThirdVersionIsUnpacked() throws {
    let (_, module) = try #require(ProWizard.unpack(versionThree))
    #expect(module.count == 1084 + 1024 + 12)
    for voice in 0 ..< 4 {
        #expect(note(module, pattern: 0, line: 4, voice: voice) == (0, 0, 0, 0))
        #expect(note(module, pattern: 0, line: 5, voice: voice) == (0, 0, 0xA, 0x20))
        #expect(note(module, pattern: 0, line: 6, voice: voice) == (856, 0, 0, 0))
        #expect(note(module, pattern: 0, line: 7, voice: voice) == (808, 1, 0xC, 0x20))
        #expect(note(module, pattern: 0, line: 8, voice: voice) == (0, 0, 0, 0))
    }
}

@Test func channelPlayerFilesAreTakenAsDeliWizardTakesThem() {
    // Up to 256 bytes of the samples may be missing, and are noughts.
    let short = Array(versionOne.dropLast(12))
    #expect(ProWizard.packer(of: short) == .channelPlayer)
    #expect(ProWizard.unpack(short)?.module.suffix(12).allSatisfy { $0 == 0 } == true)
    // Not more than that.
    var shorter = versionOne
    shorter[2 ... 3] = [0x01, 0x10]
    #expect(ChannelPlayer.version(shorter) == nil)

    func changed(_ at: Int, _ value: UInt8) -> [UInt8] {
        var file = versionOne
        file[at] = value
        return file
    }
    #expect(ChannelPlayer.version(changed(1, 0x0B)) == nil) // not ten bytes and sixteen a sample
    #expect(ChannelPlayer.version(changed(0, 0x10)) == nil)
    #expect(ChannelPlayer.version(changed(10 + 7, 65)) == nil) // too loud
    #expect(ChannelPlayer.version(changed(10 + 15, 73)) == nil) // a finetune not of 72s
    #expect(ChannelPlayer.version(changed(9, 14)) == nil) // the samples' length together
    #expect(ChannelPlayer.version(changed(10 + 4, 0x80)) == nil) // a sample too long
    #expect(ChannelPlayer.version(changed(3, 0)) == nil) // an order of nothing...
    #expect(ChannelPlayer.version(changed(3, 3)) == nil) // ...or of no places
    #expect(ChannelPlayer.version(changed(10 + 16, 0x10)) == nil) // a sample far away
}

@Test func channelPlayerModulesPlay() throws {
    for file in [versionOne, versionTwo, versionThree] {
        let renderer = try TuneLoader.load(file, format: .mod)
        #expect(renderer.info.detail == "packed by Channel Player")
        var buffer = [Float](repeating: 0, count: 2 * 4410)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4410) }
        #expect(buffer.allSatisfy { $0.isFinite })
    }
}

/// The same random bytes every time.
private struct Shuffle: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ z >> 30) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ z >> 27) &* 0x94D0_49BB_1331_11EB
        return z ^ z >> 31
    }
}

@Test func channelPlayerFilesCutShortOrChangedDoNotTrap() {
    var random = Shuffle(state: 0xC4A7)
    for file in [versionOne, versionTwo, versionThree] {
        for end in 0 ..< file.count {
            let cut = Array(file[0 ..< end])
            _ = ChannelPlayer.test(cut, cut.count)
            _ = try? ChannelPlayer.module(cut)
        }
        for _ in 0 ..< 400 {
            var changed = file
            for _ in 0 ..< Int.random(in: 1 ... 8, using: &random) {
                changed[Int.random(in: 0 ..< changed.count, using: &random)] = UInt8.random(in: 0 ... 255, using: &random)
            }
            // Mostly in the header and the order, where the reading is steered.
            if Bool.random(using: &random) {
                changed[Int.random(in: 0 ..< 60, using: &random)] = UInt8.random(in: 0 ... 255, using: &random)
            }
            _ = ChannelPlayer.test(changed, changed.count)
            if let module = try? ChannelPlayer.module(changed) {
                #expect(module.count >= 1084 + 1024)
            }
        }
    }
}
