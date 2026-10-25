// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of SoundControl's player, on tiny modules made here. The thorough check is made outside the
// package: what it tells Paula, tick by tick, against what Wanted Team's player of SoundControl tells her
// in UADE, for every song of UnExoticA's files.

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

private func long(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// A sample of a module made here: its sound, its loop (from its start and to its end, in bytes) and its
/// transposition.
private struct Sample {
    var sound: [UInt8]
    var loopStart = 0
    var loopEnd = 0
    var transpose = 0
}

/// Where the parts of a module made here are, as `module` lays them out.
private struct Layout {
    var samplesAt = 0, positionsAt = 0, instrumentsAt = 0
    /// Each sample's sound, from the module's start.
    var sounds: [Int] = []
}

/// A module: its patterns (each its rows, four bytes each, ended by $FF), its positions (the six tracks'
/// patterns of each), its samples (sample 0 four bytes of silence, then these) and, for 4.0 and 5.0, its
/// instruments (each its eight bytes of envelope, from 18, and its commands, three words each); the tempo,
/// and the samples part padded by `padding` bytes (to make the module the size of one the player knows).
private func module(_ patterns: [[UInt8]], positions: [[Int]], samples: [Sample], instruments: [([UInt8], [[Int]])]? = nil,
                    tempo: Int = 0, padding: Int = 0) -> ([UInt8], Layout) {
    var layout = Layout()
    // The patterns: a table of 256 words, and each after it (16 bytes and its rows), ending in $FFFF.
    var patternPart = [UInt8](repeating: 0, count: 512)
    for (i, rows) in patterns.enumerated() {
        patternPart.replaceSubrange(2 * i ..< 2 * i + 2, with: word(patternPart.count))
        patternPart += [UInt8](repeating: 0, count: 16) + rows + [0xFF]
    }
    if patternPart.count % 2 != 0 { patternPart.append(0) }
    patternPart += [0xFF, 0xFF]
    // The samples: a table of 256 longs, the first $400; each 64 bytes of its header and its sound.
    var samplePart = [UInt8](repeating: 0, count: 1024)
    let all = [Sample(sound: [0, 0, 0, 0])] + samples
    let samplesAt = 64 + patternPart.count
    for (i, sample) in all.enumerated() {
        samplePart.replaceSubrange(4 * i ..< 4 * i + 4, with: long(samplePart.count))
        var header = [UInt8](repeating: 0, count: 64)
        header.replaceSubrange(16 ..< 22, with: word(sample.sound.count) + word(sample.loopStart) + word(sample.loopEnd))
        header.replaceSubrange(42 ..< 44, with: word(sample.transpose))
        header.replaceSubrange(60 ..< 64, with: long(64 + sample.sound.count + (i == all.count - 1 ? padding : 0)))
        layout.sounds.append(samplesAt + samplePart.count + 64)
        samplePart += header + sample.sound
    }
    samplePart += [UInt8](repeating: 0, count: padding)
    let positionPart: [UInt8] = positions.flatMap { tracks in (0 ..< 6).flatMap { k -> [UInt8] in [UInt8(k < tracks.count ? tracks[k] : 0), 0] } }
    // The instruments: a table of 256 words; each 48 bytes, its envelope at 18, and its commands.
    var instrumentPart: [UInt8] = []
    if let instruments {
        instrumentPart = [UInt8](repeating: 0, count: 512)
        for (i, (envelope, commands)) in instruments.enumerated() {
            instrumentPart.replaceSubrange(2 * i ..< 2 * i + 2, with: word(instrumentPart.count))
            var header = [UInt8](repeating: 0, count: 48)
            header.replaceSubrange(18 ..< 18 + envelope.count, with: envelope)
            instrumentPart += header + commands.flatMap { $0.flatMap(word) }
        }
    }
    var head = [UInt8](repeating: 0x20, count: 16)
    head.replaceSubrange(0 ..< 4, with: Array("TEST".utf8))
    for part in [patternPart, samplePart, positionPart, instrumentPart] { head += long(part.count) }
    head += word(instruments == nil ? 2 : 3)
    head += word(tempo)
    head += [UInt8](repeating: 0, count: 64 - head.count)
    layout.samplesAt = samplesAt
    layout.positionsAt = samplesAt + samplePart.count
    layout.instrumentsAt = layout.positionsAt + positionPart.count
    var file = head
    for part in [patternPart, samplePart, positionPart, instrumentPart] { file += part }
    return (file, layout)
}

/// Runs `ticks` ticks, keeping what the player wrote to Paula in each.
private func play(_ player: inout SoundControlPlayer, ticks: Int) -> [[(register: UInt16, value: UInt16)]] {
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

/// The routines' period of a note: eight octaves of sixteen (3.0, 3.2) or twelve (4.0, 5.0) notes.
private func period(_ note: Int, sixteen: Bool) -> UInt16 {
    let octave: [UInt16] = [0xD600, 0xCA00, 0xBE80, 0xB400, 0xA980, 0xA000, 0x9700, 0x8E80, 0x8680, 0x7F00, 0x7800, 0x7100,
                            0x6B00, 0, 0, 0]
    let size = sixteen ? 16 : 12
    return octave[note % size] >> UInt16(note / size + 2)
}

private let at = Int(SoundControlPlayer.moduleAt)
private let sound = (0 ..< 64).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
/// A pattern of a rest of 255 steps, for a track with nothing to play.
private let rest: [UInt8] = [0, 0xFF, 0, 0]

@Test func soundControlDetection() throws {
    let (file, _) = module([[0x30, 4, 1, 40]], positions: [[0, 0, 0, 0, 0, 0]], samples: [Sample(sound: sound)])
    #expect(SoundControlPlayer.isOne(file))
    let player = try SoundControlPlayer(file)
    #expect(player.version == .v30 && player.songCount == 1 && player.sampleCount == 2)
    #expect(player.tuneInfo.format == "SoundControl" && player.tuneInfo.title == "TEST")
    // A version word of 2 with instruments; of another; a patterns' part of an odd size; not ending in
    // $FFFF; the samples' table not beginning with $400.
    let patterns = Int(file[18]) << 8 | Int(file[19])
    for (offset, value) in [(31, 1), (33, 4), (19, Int(file[19] ^ 1)), (64 + patterns - 1, 0), (64 + patterns + 2, 5)] {
        var other = file
        other[offset] = UInt8(value)
        #expect(!SoundControlPlayer.isOne(other))
    }
    // Cut short, its parts adding up to more than it has: refused.
    #expect(throws: TuneError.self) { _ = try SoundControlPlayer(Array(file.dropLast())) }
    // With instruments, version 3: 5.0's.
    let (five, _) = module([[0x30, 4, 0, 40]], positions: [[0, 0, 0, 0, 0, 0]], samples: [Sample(sound: sound)],
                           instruments: [([0, 0, 0, 0, 0, 0, 0, 0], [[0, 0, 0]])], tempo: 0x2F)
    #expect(try SoundControlPlayer(five).version == .v50)
}

/// 3.0's song goes on two steps in every three ticks (the first tick the start's): a note is played with
/// its sample's place and a word at the period 1, its DMA off, its volume, period, length and place, and
/// its DMA on; then, with no loop, a word to go round on, the sample's first long cleared for it. A
/// sample's transposition moves the note up, past the four notes at the end of each octave of sixteen.
@Test func soundControl30NoteReachesPaula() throws {
    let rows: [UInt8] = [0x30, 1, 1, 40, 0x3B, 1, 2, 0x45, 0, 1, 0, 0, 0x30, 1, 1, 0xC0]
    let (file, layout) = module([rows, rest], positions: [[0, 1, 1, 1, 1, 1]],
                                samples: [Sample(sound: sound), Sample(sound: sound, loopStart: 8, loopEnd: 40, transpose: 1)])
    var player = try SoundControlPlayer(file)
    let told = play(&player, ticks: 10)
    let steps = told.indices.filter { !written(told[$0], 0xA6).isEmpty }
    #expect(steps == [2, 3, 6, 8, 9])
    let sample1 = UInt16((at + layout.sounds[1]) & 0xFFFF), sample2 = UInt16((at + layout.sounds[2]) & 0xFFFF)
    #expect(written(told[2], 0xA2) == [sample1, sample1] && written(told[2], 0xA4) == [1, 32, 1])
    #expect(written(told[2], 0xA6) == [1, period(0x30, sixteen: true)] && written(told[2], 0xA8) == [40])
    #expect(written(told[2], 0x96) == [0x0001, 0x8201])
    #expect(player.memory[at + layout.sounds[1]] == 0 && player.memory[at + layout.sounds[1] + 4] == sound[4])
    // $3B moved up one is $40 (an octave's notes are its first twelve of sixteen); the loop; the volume's low
    // seven bits.
    #expect(written(told[3], 0xA6) == [1, period(0x40, sixteen: true)] && written(told[3], 0xA8) == [0x45])
    #expect(written(told[3], 0xA4) == [1, 32, 16] && written(told[3], 0xA2) == [sample2, sample2, sample2 + 8])
    // A rest; the note again, its volume $C0 told as $40; and at the position's end, its first.
    #expect(written(told[6], 0xA8) == [0x40])
    #expect(written(told[8], 0xA6) == [1, period(0x30, sixteen: true)] && player.endings == 1)
}

/// 3.2's notes are transposed by the voice's transposition less one: down a semitone where none is set,
/// and by what the transposing track sets (for one voice, or for all of them with a voice of five). (Its
/// start sets the first track's pattern at the first position to 1.)
@Test func soundControl32Transposes() throws {
    let rows: [UInt8] = [0x40, 1, 1, 40, 0x40, 1, 1, 40, 0x40, 1, 1, 40]
    let transposing: [UInt8] = [0, 1, 0, 0, 1, 1, 1, 3, 1, 1, 5, 2, 0xFF]
    var (file, _) = module([rest, rows, transposing], positions: [[0, 0, 0, 0, 0, 2]], samples: [Sample(sound: sound)])
    // (A module the size of Dynatech's ELEVEN6 is 3.2's.)
    (file, _) = module([rest, rows, transposing], positions: [[0, 0, 0, 0, 0, 2]], samples: [Sample(sound: sound)],
                       padding: 103_808 - file.count)
    var player = try SoundControlPlayer(file)
    #expect(player.version == .v32 && player.songCount == 1)
    // (3.2's steps: three in every four ticks.)
    let told = play(&player, ticks: 5)
    let periods = told.flatMap { written($0, 0xA6) }.filter { $0 != 1 }
    // ($40 down one is $3B; up two from $40 is $42; up one, $41.)
    #expect(periods == [period(0x3B, sixteen: true), period(0x42, sixteen: true), period(0x41, sixteen: true)])
}

/// A song ends at its last position, and goes back to its first: the player's songs of the files it knows
/// start and end at positions of its own (Penthouse Hot Numbers' NUMBER9, the size of which this is padded
/// to: three songs, of positions 0 to 39, 40 to 59 and 60 to 79).
@Test func soundControlSongsEnd() throws {
    let positions = (0 ..< 80).map { [$0 % 2, 2, 2, 2, 2, 2] }
    var (file, _) = module([[0x30, 2, 1, 40], [0, 2, 0, 0], rest], positions: positions, samples: [Sample(sound: sound)])
    (file, _) = module([[0x30, 2, 1, 40], [0, 2, 0, 0], rest], positions: positions, samples: [Sample(sound: sound)],
                       padding: 126_446 - file.count)
    var player = try SoundControlPlayer(file)
    #expect(player.version == .v30 && player.songCount == 3)
    // Each position lasts two steps (its row of two, and the $FF that ends it read with the next's first
    // row), after the first step: 40 positions end at the 81st step, the 122nd tick (two steps in three).
    let tick = UInt64(SoundControlPlayer.tickClocks)
    #expect(player.lengthClocks == 122 * tick)
    try player.select(song: 1)
    #expect(player.lengthClocks == 62 * tick)
    _ = play(&player, ticks: 123)
    #expect(player.endings == 2 && player.stops == 0)
}

/// 4.0's and 5.0's instruments: command 1 sets the sample and the note's period, and command 15 plays it,
/// over three ticks (the sample's place and DMA on, at the period 1 and no volume; then the DMA off and on
/// again, with its period and length; then its loop). The volume is the note's times the envelope's over
/// 256: a rise of 64 a tick, every other tick, to 256, and a fall of 32 to 128.
@Test func soundControl50InstrumentPlays() throws {
    let envelope: [UInt8] = [1, 64, 0, 32, 0, 128, 0, 0]
    let commands = [[1, 1, 0], [15, 0, 0], [0, 0, 0]]
    let (file, layout) = module([[0x24, 40, 0, 64], rest], positions: [[0, 1, 1, 1, 1, 1]],
                                samples: [Sample(sound: sound, loopStart: 16, loopEnd: 48)], instruments: [(envelope, commands)], tempo: 0xB9)
    var player = try SoundControlPlayer(file)
    #expect(player.version == .v50)
    let told = play(&player, ticks: 12)
    // (5.0's tempo of $B9 passes 46 four times a tick, and a step is taken at every fourth: one a tick. The
    // note $24, octave 2's fifth, is 28; command 1 leaves twice it, $38, for command 15's DMA.)
    let sample = UInt16((at + layout.sounds[1]) & 0xFFFF)
    #expect(written(told[1], 0xA2) == [sample] && written(told[1], 0xA4) == [1] && written(told[1], 0xA6) == [1])
    #expect(written(told[1], 0x96) == [0x8238])
    #expect(written(told[2], 0x96) == [0x0001, 0x8201])
    #expect(written(told[2], 0xA6) == [period(2 * 12 + 4, sixteen: false)] && written(told[2], 0xA4) == [32])
    #expect(written(told[3], 0xA4) == [16] && written(told[3], 0xA2) == [sample + 16])
    let volumes = told[1 ..< 12].map { written($0, 0xA8).last ?? 0xFFFF }
    #expect(volumes == [0, 16, 16, 32, 32, 48, 48, 64, 64, 56, 48])
}

/// Command 1 leaves the routine's D4, the voice's DMA bit, as twice its note: command 15's first part, in
/// the same tick, turns on the DMA of the voices that has the bits of, as the games' routine did; its second,
/// at the next tick, has the bit again.
@Test func soundControlCommandOneLeavesItsNote() throws {
    let commands = [[1, 1, 0], [15, 0, 0], [0, 0, 0]]
    let (file, _) = module([[0x13, 40, 0, 64], rest], positions: [[1, 0, 1, 1, 1, 1]], samples: [Sample(sound: sound)],
                           instruments: [([0, 0, 0, 0, 0, 0, 0, 0], commands)], tempo: 0xBC)
    var player = try SoundControlPlayer(file)
    let told = play(&player, ticks: 4)
    // (Voice 2's note, $13, is 15; twice it is 30, $1E: voices 2, 3 and 4.)
    #expect(written(told[1], 0x96) == [0x821E])
    #expect(written(told[2], 0x96) == [0x0002, 0x8202])
}

/// A loop of commands (10 and 11) goes round while its register has not passed its count, and a wait (2)
/// holds the voice for so many ticks.
@Test func soundControlInstrumentLoops() throws {
    // Start (register 1 from 0), a period up by 4, a wait of 1, the loop's end (register 1 up by 1, to 3).
    let commands = [[1, 1, 0], [15, 0, 0], [10, 1, 0], [7, 4, 0], [2, 1, 0], [11, 3, 1], [0, 0, 0]]
    let (file, _) = module([[0x24, 40, 0, 64], rest], positions: [[0, 1, 1, 1, 1, 1]], samples: [Sample(sound: sound)],
                           instruments: [([0, 0, 0, 0, 0, 0, 0, 0], commands)], tempo: 0xBC)
    var player = try SoundControlPlayer(file)
    let told = play(&player, ticks: 14)
    let base = period(2 * 12 + 4, sixteen: false)
    let periods = told[3...].flatMap { written($0, 0xA6) }
    #expect(periods == [base + 4, base + 8, base + 12, base + 16])
}

/// 4.0's songs of Hot Numbers Deluxe's HNDINTRO, the size of which this is padded to: four, the game's 4
/// to 7, of positions of their own and tempos of their own.
@Test func soundControl40Songs() throws {
    let positions = (0 ..< 132).map { _ in [0, 1, 1, 1, 1, 1] }
    let commands = [[0, 0, 0]]
    var (file, _) = module([[0x24, 1, 0, 64], rest], positions: positions, samples: [Sample(sound: sound)],
                           instruments: [([0, 0, 0, 0, 0, 0, 0, 0], commands)], tempo: 0xBC)
    (file, _) = module([[0x24, 1, 0, 64], rest], positions: positions, samples: [Sample(sound: sound)],
                       instruments: [([0, 0, 0, 0, 0, 0, 0, 0], commands)], tempo: 0xBC, padding: 81906 - file.count)
    var player = try SoundControlPlayer(file)
    #expect(player.version == .v40 && player.songCount == 4)
    #expect(player.startPosition == 0x330 && player.position == 0x330 && player.endPosition == 0x3F0 && player.tempo == 0x1B3)
    try player.select(song: 3)
    #expect(player.startPosition == 0 && player.endPosition == 0x330 && player.tempo == 0x124)
}

/// Cut short or changed anywhere, a module is refused, or plays, or stops: never a trap or a hang.
@Test func soundControlDamagedModules() throws {
    let commands = [[1, 1, 0], [15, 0, 0], [10, 1, 0], [8, 1, 0], [2, 1, 0], [11, 3, 1], [9, 2, 0],
                    [0x4000 | 12, 1, 2], [0, 0, 0]]
    let files = [
        module([[0x30, 1, 1, 40, 0x3B, 2, 1, 0x45], [0x31, 1, 1, 0]], positions: [[0, 1, 0, 1, 0, 1], [1, 0, 1, 0, 1, 0]],
               samples: [Sample(sound: sound, loopStart: 8, loopEnd: 40, transpose: 2)]).0,
        module([[0x24, 3, 0, 64, 0x25, 1, 0, 32], [0, 1, 1, 1, 1, 2, 1, 3]], positions: [[0, 0, 0, 0, 0, 1], [0, 0, 0, 0, 0, 0]],
               samples: [Sample(sound: sound, loopStart: 16, loopEnd: 48)], instruments: [([1, 64, 1, 32, 0, 128, 1, 8], commands)],
               tempo: 0xC0).0,
    ]
    for file in files {
        var copies: [[UInt8]] = stride(from: 0, to: file.count, by: 7).map { Array(file.prefix($0)) }
        var seed: UInt32 = 2026
        for _ in 0 ..< 40 {
            var copy = file
            for _ in 0 ..< 3 {
                seed = seed &* 1_103_515_245 &+ 12345
                copy[Int(seed >> 8) % min(copy.count, 0x700)] = UInt8(truncatingIfNeeded: seed >> 20)
            }
            copies.append(copy)
        }
        for copy in copies {
            guard var player = try? SoundControlPlayer(copy) else { continue }
            var none = TFMXSilentOutput()
            for song in 0 ..< player.songCount {
                try player.select(song: song)
                for _ in 0 ..< 200 { _ = player.run(&none) }
            }
        }
    }
}
