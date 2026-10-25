// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of Ron Klaren's player, on tiny modules made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what Wanted Team's player of his music tells her in
// UADE, for every song of UnExoticA's files.

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// Where the parts of the modules made here are, from the start of their code.
private let songsAt = 0x200, samplesAt = 0x240, headersAt = 0x2C0, arpeggiosAt = 0x2E0, listsAt = 0x300
private let patternsAt = 0x400, silenceAt = 0x500, sampleAt = 0x520

/// A module whose four voices each play `patterns[v]` (bytes, ended by $FF), from a list of that
/// pattern alone played `times` times; with the routine's code the player looks for (its timer `timer`,
/// and, as the player finds the module's origin, its tick at 140), sample 0 two words of silence and
/// sample 1 a sample of 32 words played once, with the envelope `targets` and `steps`. As an AmigaDOS
/// program of one hunk, if `program`, its pointers from its hunk's start; otherwise from its own. With
/// `gameLow`, the timer's low byte is set as the games set it, by a `MOVE.B` before the high byte's.
private func module(_ patterns: [[UInt8]], times: Int = 1, timer: Int = 0x3481, targets: [UInt8] = [63, 32, 32, 0],
                    steps: [UInt8] = [16, 8, 0, 0], program: Bool = false, gameLow: Int? = nil) -> [UInt8] {
    var code = [UInt8](repeating: 0, count: 3200)
    func put(_ at: Int, _ bytes: [UInt8]) { for (i, b) in bytes.enumerated() { code[at + i] = b } }
    if program {
        put(0, [0x70, 0xFF, 0x4E, 0x75] + long(3200) + Array("RON_KLAREN_SOUNDMODULE!".utf8))
    } else {
        put(0, word(0x6000) + word(0x40) + word(0x6000) + word(0x40)) // BRA.W, BRA.W
    }
    put(64, long(0x4228_0030) + long(0x4228_0031) + long(0x4228_0032)) // CLR.B $30(A0) to $32(A0)
    put(80, word(0xD041) + word(0x49FA) + word(arpeggiosAt - 84)) // ADD.W D1,D0; LEA arpeggios(PC),A4
    if let gameLow {
        put(88, word(0x13FC) + word(gameLow) + long(0x00BF_D400)) // MOVE.B #lo,$BFD400
        put(116, long(0x42A8_001C) + word(0x43FA) + word(samplesAt - 122))
    } else {
        put(88, long(0x42A8_001C) + word(0x43FA) + word(samplesAt - 94)) // CLR.L $1C(A0); LEA samples(PC),A1
    }
    // MOVE.B #hi,$BFD500; MOVE.B #lo,$BFDD00; and later MOVE.L #tick,x
    put(96, word(0x13FC) + word(timer >> 8) + long(0x00BF_D500) + word(0x13FC) + word(timer & 0xFF) + long(0x00BF_DD00))
    put(128, word(0x21FC) + long(140))
    put(140, long(0x48E7_F8FC) + word(0x41FA) + word(songsAt - 146)) // MOVEM.L ...; LEA songs(PC),A0
    put(150, long(0x1AC0_1940)) // the routine's periods
    // One song, its four lists, and the long that begins the routine's own first voice.
    for v in 0 ..< 4 { put(songsAt + 4 * v, long(listsAt + 32 * v)) }
    put(songsAt + 16, long(0x00DF_F0A0))
    for v in 0 ..< 4 {
        put(listsAt + 32 * v, long(patternsAt + 64 * v) + word(0) + word(0) + word(0) + word(times))
        put(listsAt + 32 * v + 12, long(-1))
        put(patternsAt + 64 * v, (v < patterns.count ? patterns[v] : [0, 63]) + [0xFF])
    }
    // The samples: 0, silence; 1, 32 words played once, with its envelope; and the end of them.
    put(samplesAt, long(headersAt))
    put(samplesAt + 32, long(headersAt + 8) + long(headersAt) + [1, 0, 0, 0, 0, 0] + targets + steps)
    put(samplesAt + 64 + 28, long(1))
    put(headersAt, long(silenceAt) + word(2))
    put(headersAt + 8, long(sampleAt) + word(32))
    for i in 0 ..< 64 { code[sampleAt + i] = UInt8(truncatingIfNeeded: i * 9 + 1) }
    guard program else { return code }
    return long(0x3F3) + long(0) + long(1) + long(0) + long(0) + long(3200 / 4) + long(0x3E9) + long(3200 / 4) + code + long(0x3F2)
}

/// Runs `ticks` ticks, keeping what the player wrote to Paula in each.
private func play(_ player: inout RonKlarenPlayer, ticks: Int) -> [[(register: UInt16, value: UInt16)]] {
    var told: [[(register: UInt16, value: UInt16)]] = []
    var none = TFMXSilentOutput()
    player.writes = []
    for _ in 0 ..< ticks {
        _ = player.run(&none)
        told.append(player.writes ?? [])
    }
    return told
}

private func written(_ writes: [(register: UInt16, value: UInt16)], _ register: UInt16) -> [UInt16] {
    writes.filter { $0.register == register }.map(\.value)
}

@Test func ronKlarenDetection() throws {
    let file = module([[0x82, 1, 24, 2]])
    #expect(RonKlarenPlayer.isOne(file) && RonKlarenPlayer.passesCheck(file))
    let program = module([[0x82, 1, 24, 2]], program: true)
    #expect(RonKlarenPlayer.isOne(program) && !RonKlarenPlayer.passesCheck(program) && RonKlarenPlayer.isProgram(program))
    // No more than 3,000 bytes; another start; the routine's start of a voice not there.
    #expect(!RonKlarenPlayer.isOne(Array(file.prefix(3000))))
    var other = file
    other[4] = 0x4E
    #expect(!RonKlarenPlayer.isOne(other))
    var noClear = file
    noClear[64 + 9] = 0x31
    #expect(!RonKlarenPlayer.isOne(noClear))
    // The tables not found: refused.
    var noSamples = file
    noSamples[88] = 0
    #expect(!RonKlarenPlayer.isOne(noSamples))
    #expect(throws: TuneError.self) { _ = try RonKlarenPlayer(noSamples) }
    // Or not in the module, as in one cut short.
    #expect(throws: TuneError.self) { _ = try RonKlarenPlayer(Array(file.prefix(songsAt))) }

    let player = try RonKlarenPlayer(file)
    #expect(player.songCount == 1 && player.sampleCount == 2 && player.synthCount == 0)
    #expect(player.layout.origin == 0)
    #expect(player.tickClocks == (0x3481 + 1) * 5)
    // As the games set their timer: the low byte from its own `MOVE.B`, not from the next one's.
    #expect(try RonKlarenPlayer(module([[0x82, 1, 24, 2]], gameLow: 0x50)).tickClocks == (0x3450 + 1) * 5)
    #expect(player.tuneInfo.format == "Ron Klaren" && player.tuneInfo.author == "Ron Klaren")
    // A program's pointers are from its hunk's start, after its header of 32 bytes.
    #expect(try RonKlarenPlayer(program).layout.origin == UInt32(bitPattern: -32))
}

/// The song's start tells each voice the first sample, at the first tick, which is the timer's first
/// count; then a note's sample is started (its DMA off, its place, its length, its period), and at the
/// next tick its DMA on and its length made one word, to be played once; its envelope goes up by its
/// step and down to its next target, a step a tick, and holds.
@Test func ronKlarenNoteReachesPaula() throws {
    for program in [false, true] {
        var player = try RonKlarenPlayer(module([[0x82, 1, 24, 4]], program: program))
        let base = program ? 0xF020 : 0xF000
        let told = play(&player, ticks: 14)
        #expect(written(told[0], 0xA2) == [UInt16(base + silenceAt)] && written(told[0], 0xA4) == [2])
        #expect(written(told[0], 0xD2) == [UInt16(base + silenceAt)])
        // The routine's first tick: DMA on, the first sample's length one word, and the note.
        #expect(written(told[1], 0x96).filter { $0 & 1 != 0 } == [0x8001, 0x0001, 0x0001])
        #expect(written(told[1], 0xA2) == [UInt16(base + sampleAt), UInt16(base + sampleAt)])
        #expect(written(told[1], 0xA4) == [1, 32, 32])
        #expect(written(told[1], 0xA6) == [RonKlarenPlayer.periods[24]])
        #expect(written(told[1], 0xA8) == [])
        #expect(written(told[2], 0x96).filter { $0 & 1 != 0 } == [0x8001] && written(told[2], 0xA4) == [1])
        #expect(written(told[2], 0xA6) == [RonKlarenPlayer.periods[24]])
        let volumes = told[2 ..< 14].flatMap { written($0, 0xA8) }
        #expect(volumes == [16, 32, 48, 63, 55, 47, 39, 32, 32, 32, 32, 32])
        // (The other voices play silence, at a volume of nought.)
        #expect(written(told[1], 0xB8) == [] && written(told[2], 0xB8) == [0])
    }
}

/// A note lasts four ticks for each of its count; at the end of its pattern, played its number of
/// times, a voice goes on to the next in its list, and after the last to its first again; once every
/// voice has, the song has come to its end.
@Test func ronKlarenSongEnds() throws {
    var player = try RonKlarenPlayer(module([[24, 1], [24, 1], [24, 1], [24, 1]], times: 2))
    // The first tick, the start's; two of the note, of four ticks each; and the song's end in the next.
    #expect(player.lengthClocks == UInt64(9 * player.tickClocks))
    let told = play(&player, ticks: 11)
    #expect(told[1 ... 9].map { written($0, 0xA2).count } == [1, 0, 0, 0, 1, 0, 0, 0, 1])
    #expect(player.endings == 1 && player.stops == 0)
}

/// A command to stop ($83 or $85) stops the routine, and the song with it.
@Test func ronKlarenStops() throws {
    for command: UInt8 in [0x83, 0x85] {
        var player = try RonKlarenPlayer(module([[24, 1, command]]))
        #expect(player.lengthClocks == UInt64(5 * player.tickClocks))
        let told = play(&player, ticks: 8)
        #expect(player.stops == 1)
        #expect(told[6].isEmpty && told[7].isEmpty)
    }
}

/// A slide goes to its note by its speed a tick; an arpeggio adds its steps to the note, its first and
/// then counting down from its twelfth.
@Test func ronKlarenSlideAndArpeggio() throws {
    var slide = try RonKlarenPlayer(module([[0x82, 1, 24, 0, 0x81, 23, 40, 2]]))
    let periods = play(&slide, ticks: 6).flatMap { written($0, 0xA6) }
    let from = RonKlarenPlayer.periods[24], to = RonKlarenPlayer.periods[23]
    #expect(periods == [from, from + 40, from + 80, to, to])

    var file = module([[0x80, 1, 0x82, 1, 24, 8]])
    for (i, step) in [0, 12, 7, 4].enumerated() { file[arpeggiosAt + 12 + i] = UInt8(step) }
    var arpeggio = try RonKlarenPlayer(file)
    let notes = play(&arpeggio, ticks: 16).flatMap { written($0, 0xA6) }
    #expect(notes == [24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 28, 31, 36, 24, 24].map { RonKlarenPlayer.periods[$0] })
}

/// A voice whose commands go round without a note would hang the player: the song is stopped there.
@Test func ronKlarenCommandsWithoutANote() throws {
    var player = try RonKlarenPlayer(module([[24, 0, 0x84, 1]]))
    #expect(player.lengthClocks == UInt64(player.tickClocks))
    _ = play(&player, ticks: 3)
    #expect(player.stops == 1 && player.failure != nil)
}

/// Cut short or changed anywhere, a module is refused, or plays, or stops: never a trap or a hang.
@Test func ronKlarenDamagedModules() throws {
    let file = module([[0x82, 1, 24, 2, 0x80, 0, 25, 1], [0x84, 2, 30, 3], [24, 1], [0x81, 30, 9, 1]], times: 2)
    var copies: [[UInt8]] = stride(from: 0, to: file.count, by: 15).map { Array(file.prefix($0)) }
    var seed: UInt32 = 2026
    for _ in 0 ..< 15 {
        var copy = file
        for _ in 0 ..< 4 {
            seed = seed &* 1_103_515_245 &+ 12345
            copy[Int(seed >> 8) % 0x600] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        copies.append(copy)
    }
    for copy in copies {
        guard var player = try? RonKlarenPlayer(copy) else { continue }
        var none = TFMXSilentOutput()
        for song in 0 ..< player.songCount {
            try player.select(song: song)
            for _ in 0 ..< 200 { _ = player.run(&none) }
        }
    }
}
