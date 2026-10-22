// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaTrackers
@testable import SidayFoundation
import Testing

// Checks of the Amiga's music read since the survey of what was not played: AMOS's music banks, MED modules packed for a game, Promizer 1.8a, SoundTracker 2.6, The Player's
// packed samples, ProRunner's other letters, old Soundtracker modules with leftovers in their order, and
// Startrekker's synthesised instruments. Each builds a small file as its maker would.

private func be16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
private func be32(_ value: Int) -> [UInt8] { be16(value >> 16) + be16(value) }
private func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }
private func text(_ s: String, _ count: Int) -> [UInt8] { Array((Array(s.utf8) + zeros(count)).prefix(count)) }

@Test func namesOfTheNewKindsAreKnown() {
    #expect(TuneFormat(fileExtension: "abk") == .mod)
    #expect(TuneFormat(fileExtension: "mmdc") == .med)
    #expect(TuneFormat(fileExtension: "pr1") == .mod)
    #expect(TuneFormat(fileExtension: "st26") == .mod)
    #expect(TuneFormat(fileExtension: "pro") == .mod)
}

// MARK: AMOS

/// An AMOS music bank of one instrument, one song and one pattern, whose first voice plays a note
/// with vibrato for two lines, then another for one with the vibrato stopped, and ends.
private func amosBank() -> [UInt8] {
    var instruments = be16(1)
    // Where its sample is, where its loop is, its length (here unused), no loop, its volume, its
    // length in words, and its name.
    instruments += be32(34) + be32(34) + be16(0) + be16(0) + be16(0x40) + be16(2) + text("drum", 16)
    let sample: [UInt8] = [0x10, 0x20, 0x30, 0x40]

    // The song: four lists of patterns from the song, its tempo, a word, its name; then the lists.
    var song = be16(28) + be16(32) + be16(36) + be16(40) + be16(17) + be16(0) + text("anthem", 16)
    for _ in 0 ..< 4 { song += be16(0) + be16(0xFFFE) }
    // The patterns: their count, each voice's place, and the voices.
    let first: [Int] = [0x8900, 0x31AC, 0x8C34, 0x9002, 0x30FE, 0x8400, 0x9001, 0x8000]
    let rest: [Int] = [0x8000]
    let firstAt = 10, restAt = 10 + first.count * 2
    var patterns = be16(1) + be16(firstAt) + be16(restAt) + be16(restAt) + be16(restAt)
    patterns += first.flatMap(be16) + rest.flatMap(be16)

    let instrumentsAt = 16
    let songsAt = instrumentsAt + instruments.count + sample.count
    let songsSection = be16(1) + be32(6) + song
    let patternsAt = songsAt + songsSection.count
    var bank = Array("AmBk".utf8) + be16(3) + be16(0) + be32(0x8000_0000) + Array("Music   ".utf8)
    bank += be32(instrumentsAt) + be32(songsAt) + be32(patternsAt) + be32(0)
    bank += instruments + sample + songsSection + patterns
    return bank
}

@Test func amosMusicBankIsMadeTheProTrackerModuleUADEMakes() throws {
    let bank = amosBank()
    #expect(AMOSBankFile.isOne(bank))
    let module = try AMOSBankFile.module(bank)
    #expect(Array(module[0 ..< 6]) == Array("anthem".utf8))
    #expect(Array(module[20 ..< 24]) == Array("drum".utf8))
    #expect(Array(module[42 ..< 50]) == [0, 2, 0, 0x40, 0, 0, 0, 1])
    #expect(module[950] == 1)
    #expect(Array(module[1080 ..< 1084]) == Array("M.K.".utf8))
    func cell(_ line: Int, _ voice: Int) -> [UInt8] { Array(module[1084 + line * 16 + voice * 4 ..< 1084 + line * 16 + voice * 4 + 4]) }
    // The note, its sample, and vibrato; the vibrato again on the line it waits; the next note,
    // which has the line's command (the vibrato's, as UADE leaves it) made the end of the pattern.
    #expect(cell(0, 0) == [0x01, 0xAC, 0x14, 0x34])
    #expect(cell(1, 0) == [0x00, 0x00, 0x04, 0x34])
    #expect(cell(2, 0) == [0x00, 0xFE, 0x0D, 0x00])
    #expect(cell(3, 0) == [0, 0, 0, 0])
    #expect(Array(module.suffix(4)) == [0x10, 0x20, 0x30, 0x40])
    let renderer = try MODRenderer(module, options: LoadOptions())
    #expect(renderer.info.title == "anthem")
}

@Test func amosMusicBankCutShortOrNonsenseDoesNotTrap() {
    let bank = amosBank()
    for length in stride(from: 0, to: bank.count, by: 3) {
        _ = try? AMOSBankFile.module(Array(bank.prefix(length)))
    }
    var random = SplitMix(seed: 7)
    for _ in 0 ..< 300 {
        var damaged = bank
        for _ in 0 ..< 4 { damaged[Int(random.next() % UInt64(damaged.count))] = UInt8(truncatingIfNeeded: random.next()) }
        _ = try? AMOSBankFile.module(damaged)
    }
}

// MARK: MMDC

@Test func medModulePackedForAGameIsUnpackedToMMD0() throws {
    // A header, a song whose count of blocks is at 504, a list of blocks, and one block of one track of
    // two lines: three bytes kept as they are, then three noughts.
    var file = Array("MMDC".utf8) + be32(0) + be32(52) + be32(0) + be32(52 + 508)
    file += zeros(52 - file.count)
    file += zeros(504) + be16(1) + zeros(2)
    file += be32(52 + 508 + 4)
    file += [1, 1] + [0x02, 0x02, 0x1A, 0x34] + [0xFD]
    #expect(MMDCFile.isOne(file))
    let unpacked = try MMDCFile.mmd0(file)
    #expect(Array(unpacked[0 ..< 4]) == Array("MMD0".utf8))
    let place = Int(unpacked[52 + 508]) << 24 | Int(unpacked[52 + 509]) << 16 | Int(unpacked[52 + 510]) << 8 | Int(unpacked[52 + 511])
    #expect(place >= file.count)
    #expect(Array(unpacked[place ..< place + 8]) == [1, 1, 0x02, 0x1A, 0x34, 0, 0, 0])
    // Cut short in its notes, it is refused.
    #expect(throws: TuneError.self) { try MMDCFile.mmd0(Array(file.dropLast(2)) + [0x05]) }
}

// MARK: Promizer 1.8a

@Test func promizerPatternsAreTakenFromWhereTheyAreFirstPlayed() throws {
    // The replayer's first bytes and the byte that says 1.8a; then, past the replayer, where the samples
    // are and how long the patterns are.
    var file: [UInt8] = [0x60, 0x38, 0x60, 0x00, 0x00, 0xA0, 0x60, 0x00, 0x01, 0x3E, 0x60, 0x00, 0x01, 0x0C, 0x48, 0xE7]
    file += zeros(4456 - file.count)
    file[21] = 0xD2
    file[36] = 0x11
    let patternBytes = 2 * 512
    let tableAt = 5226 + patternBytes
    let table = be32(0) + [0x01, 0xAC, 0x10, 0x00] + [0x00, 0xFE, 0x10, 0x00] // nothing; C-2 and C-3 of sample 1
    file += be32(tableAt + table.count - 4460) + be32(patternBytes)
    // One sample of two words, at full volume.
    file += be16(2) + [0, 0x40] + be16(0) + be16(1)
    for _ in 1 ..< 31 { file += be16(0) + [0, 0] + be16(0) + be16(1) }
    // The order: the first pattern twice, then the second.
    file += be16(3 * 4) + be32(0) + be32(0) + be32(512)
    for _ in 3 ..< 128 { file += be32(0) }
    #expect(file.count == 5226)
    // The patterns: the first a C-2 on its first line, the second a C-3.
    var first = zeros(512), second = zeros(512)
    first[1] = 1
    second[1] = 2
    file += first + second + table + [0x7F, 0x80, 0x7F, 0x80]
    #expect(Promizer.test(file, file.count) == 0)
    var input = PackedReader(file)
    var output = ModuleWriter()
    try Promizer.depack(&input, &output)
    let module = output.bytes
    #expect(module[950] == 3)
    #expect(Array(module[952 ..< 955]) == [0, 0, 1])
    #expect(Array(module[1084 ..< 1088]) == [0x01, 0xAC, 0x10, 0x00])
    #expect(Array(module[1084 + 1024 ..< 1088 + 1024]) == [0x00, 0xFE, 0x10, 0x00])
    #expect(Array(module.suffix(4)) == [0x7F, 0x80, 0x7F, 0x80])
}

// MARK: SoundTracker 2.6

@Test func soundTracker26TracksAreMadePatterns() throws {
    // One sample of two words; an order of two places that play the same four tracks, then other four.
    var file = text("tracks", 20) + text("lead", 22) + be16(2) + [0, 0x40] + be16(0) + be16(1)
    for _ in 1 ..< 31 { file += zeros(22) + be16(0) + [0, 0] + be16(0) + be16(1) }
    file += [3, 3]
    file += [0, 1, 2, 1] + [0, 1, 2, 1] + [2, 1, 0, 1]
    file += zeros(1464 - file.count) + Array("MTN".utf8) + [0]
    var tracks = zeros(3 * 256)
    for track in 0 ..< 3 { tracks[track * 256 + 1] = UInt8(0x10 + track) }
    file += tracks + [1, 2, 3, 4]
    #expect(IceTracker.test(file, file.count) == 0)
    var input = PackedReader(file)
    var output = ModuleWriter()
    try IceTracker.depack(&input, &output)
    let module = output.bytes
    #expect(module[950] == 3)
    #expect(Array(module[952 ..< 955]) == [0, 0, 1])
    #expect(module.count == 1084 + 2 * 1024 + 4)
    #expect(Array(module[1084 ..< 1100].enumerated().filter { $0.offset % 4 == 1 }.map(\.element)) == [0x10, 0x11, 0x12, 0x11])
    #expect(Array(module[2108 ..< 2124].enumerated().filter { $0.offset % 4 == 1 }.map(\.element)) == [0x12, 0x11, 0x10, 0x11])
    // A track the store does not have is not one of these.
    var wrong = file
    wrong[952] = 9
    #expect(IceTracker.test(wrong, wrong.count) == -1)
}

// MARK: The Player, ProRunner

@Test func thePlayersPackedSampleIsUnpackedInSteps() {
    // 1, 2, -1 and nought steps down from nought.
    #expect(ThePlayer.unpackSample([0x12, 0xF0]) == [0xFF, 0xFD, 0xFE, 0xFE])
}

@Test func proRunnerTakesWinterOlympicsLetters() {
    var file = zeros(1084)
    file[950] = 1
    file[951] = 0x7F
    for letters in ["SNT.", "KURT", "+SNT"] {
        file.replaceSubrange(1080 ..< 1084, with: Array(letters.utf8))
        #expect(ProRunner.test1(file, file.count) == 0)
    }
    file.replaceSubrange(1080 ..< 1084, with: Array("M.K.".utf8))
    #expect(ProRunner.test1(file, file.count) == -1)
}

// MARK: Old modules

/// A module of Soundtracker's 15 samples: one sample of two words; a song of one place, its order
/// with numbers left after it of patterns the file does not have; one pattern.
@Test func soundtrackerModuleWithLeftoversInItsOrderPlaysThePatternsItHas() throws {
    var file = text("leftovers", 20) + text("st-01:drum", 22) + be16(2) + [0, 0x40] + be16(0) + be16(1)
    for _ in 1 ..< 15 { file += zeros(22) + be16(0) + [0, 0] + be16(0) + be16(1) }
    file += [1, 120] + [0, 1, 2, 3, 63] + zeros(123)
    var pattern = zeros(1024)
    pattern[0] = 0x11
    pattern[1] = 0xAC
    file += pattern + [0x10, 0x20, 0x30, 0x40]
    let renderer = try MODRenderer(file, options: LoadOptions())
    #expect(renderer.info.title == "leftovers")
}

@Test func startrekkerModuleWithItsSynthesisedInstrumentsElsewhereSaysSo() throws {
    // A Startrekker module whose notes play two samples with nothing in them.
    var file = text("synth", 20)
    for _ in 0 ..< 31 { file += zeros(22) + be16(0) + [0, 0x40] + be16(0) + be16(1) }
    file += [1, 0x7F] + zeros(128) + Array("FLT4".utf8)
    var pattern = zeros(1024)
    pattern[0] = 0x01
    pattern[1] = 0xAC
    pattern[2] = 0x10
    pattern[4] = 0x01
    pattern[5] = 0xAC
    pattern[6] = 0x20
    file += pattern
    let renderer = try MODRenderer(file, options: LoadOptions())
    #expect(renderer.info.shortfalls.contains { $0.contains("Startrekker") })
    // And its file of them is said to be no tune.
    let instruments = Array("ST1.3 ModuleINFO".utf8) + zeros(200)
    #expect(throws: TuneError.self) { try TuneLoader.load(instruments, format: .mod) }
}

/// A small generator of numbers that are the same from run to run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
