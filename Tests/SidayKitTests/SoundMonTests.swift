// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaComposers
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the player of Brian Postma's SoundMon, on tiny modules made here. The thorough check is
// made outside the package: what it tells Paula, tick by tick, and what it writes into its waveforms,
// against UADE's running of SoundMon 2.0's and 2.2's players, for every module of UnExoticA's collection.

/// What Paula is told, as a list.
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

/// A sample instrument's 32 bytes: a name, then its length in words, its loop's place in bytes and
/// length in words, and its volume.
private func sample(length: Int, loop: Int = 0, loopLength: Int = 1, volume: Int = 64) -> [UInt8] {
    Array("sample".utf8) + [UInt8](repeating: 0, count: 18) + word(length) + word(loop) + word(loopLength) + word(volume)
}

/// A synthesised instrument's 32 bytes: $FF, then the bytes given by their places.
private func synth(_ fields: [Int: Int]) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 32)
    bytes[0] = 0xFF
    for (at, value) in fields { bytes[at] = UInt8(value & 0xFF) }
    return bytes
}

/// A row: a note, an instrument, an option and its parameter.
private typealias Row = (note: Int, instrument: Int, option: Int, parameter: Int)

/// A SoundMon module ("V.2" for 2.0's player, "V.3" for 2.2's): its steps, each four entries of a
/// pattern (from 1) and transposes, in the file's order (the last is Paula's first voice); its patterns
/// of sixteen rows (those not given are empty); its tables and its samples' bytes.
private func soundMon(version: Character = "2", instruments: [[UInt8]], steps: [[Int]], patterns: [[Int: Row]],
                      tables: [[UInt8]] = [], samples: [UInt8] = []) -> [UInt8] {
    var bytes = Array("tiny".utf8) + [UInt8](repeating: 0, count: 22)
    bytes += Array("V.".utf8) + [UInt8(version.asciiValue!), UInt8(tables.count)] + word(steps.count)
    for i in 0 ..< 15 { bytes += i < instruments.count ? instruments[i] : sample(length: 0) }
    for step in steps {
        for entry in 0 ..< 4 { bytes += word(step[entry]) + [0, 0] }
    }
    for pattern in patterns {
        for r in 0 ..< 16 {
            let row = pattern[r] ?? (0, 0, 0, 0)
            bytes += [UInt8(row.note & 0xFF), UInt8((row.instrument << 4 | row.option) & 0xFF), UInt8(row.parameter & 0xFF)]
        }
    }
    for table in tables { bytes += table + [UInt8](repeating: 0, count: 64 - table.count) }
    return bytes + samples
}

/// One step: Paula's first voice plays pattern 1, the others pattern 2 (empty).
private let oneStep = [[2, 2, 2, 1]]

@Test func soundMonModulesAreKnown() throws {
    let two = soundMon(instruments: [sample(length: 100)], steps: oneStep, patterns: [[:], [:]], samples: [UInt8](repeating: 1, count: 200))
    #expect(SoundMonPlayer.isOne(two))
    #expect(try SoundMonPlayer(two).tuneInfo.detail == "SoundMon 2.0")
    var three = two
    three[28] = 0x33
    #expect(SoundMonPlayer.isOne(three))
    #expect(try SoundMonPlayer(three).tuneInfo.detail == "SoundMon 2.2")
    #expect(try SoundMonPlayer(three).tuneInfo.format == "BP")
    #expect(try SoundMonPlayer(three).title == "tiny")
    // Neither player takes another mark, as SoundMon 1's "BPSM", nor a file too short for it.
    var one = two
    one[26 ..< 30] = [0x42, 0x50, 0x53, 0x4D]
    #expect(!SoundMonPlayer.isOne(one))
    #expect(throws: TuneError.self) { try SoundMonPlayer(one) }
    #expect(!SoundMonPlayer.isOne(Array(two.prefix(29))))
}

@Test func soundMonVoicesReadTheStepsLastFirst() throws {
    let module = soundMon(instruments: [sample(length: 100, volume: 40)], steps: oneStep, patterns: [[0: (25, 1, 0, 0)], [:]],
                          samples: [UInt8](repeating: 1, count: 200))
    var player = try SoundMonPlayer(module)
    var out = Recorder()
    _ = player.run(&out)
    let silence = player.silenceAt, at = module.count - 200
    // Each voice is told where it plays on every tick; then the note of the step's last entry is begun
    // on Paula's first voice, its DMA off and on again.
    #expect(out.events == (0 ..< 4).map { "buffer \($0) \(silence) 1" } + ["off 0", "buffer 0 \(at) 100", "on 0"])
    #expect(player.period(0) == SoundMonPlayer.periodTable[25 - 1 + 36])
    #expect(player.volumeWritten(0) == 40)
    // A sample without a loop is played once, and then silence.
    var next = Recorder()
    _ = player.run(&next)
    #expect(next.events.first == "buffer 0 \(silence) 1")
}

@Test func soundMonLoopsAsEachPlayerDoes() throws {
    // A sample of 200 words, its loop of 50 words from its 100th byte.
    var module = soundMon(instruments: [sample(length: 200, loop: 100, loopLength: 50)], steps: oneStep,
                          patterns: [[0: (25, 1, 0, 0)], [:]], samples: [UInt8](repeating: 1, count: 400))
    let at = module.count - 400
    for version in [UInt8(0x32), 0x33] {
        module[28] = version
        var player = try SoundMonPlayer(module)
        var out = Recorder()
        _ = player.run(&out)
        let begun = Array(out.events.drop { $0 != "off 0" })
        // 2.0 starts the sample at its loop; 2.2 plays it from its start to its loop's end.
        #expect(begun == (version == 0x32
                ? ["off 0", "buffer 0 \(at) 200", "buffer 0 \(at + 100) 50", "on 0"]
                : ["off 0", "buffer 0 \(at) 200", "buffer 0 \(at) 100", "on 0"]))
        var next = Recorder()
        _ = player.run(&next)
        #expect(next.events.first == "buffer 0 \(at + 100) 50")
    }
}

@Test func soundMonEnvelopeTurnsTheWaveformOver() throws {
    // 2.0's EG: its table of nought, (0 + 128) / 8, turns the first 16 bytes over on each of its steps,
    // which the next note puts back.
    let wave = (0 ..< 64).map { UInt8($0 * 2 + 1) }
    let instrument = synth([1: 0, 2: 0, 3: 16, 17: 2, 18: 1, 21: 64, 24: 1, 25: 64])
    let module = soundMon(instruments: [instrument], steps: oneStep, patterns: [[0: (25, 1, 0, 0), 2: (25, 1, 0, 0)], [:]],
                          tables: [wave, []])
    var player = try SoundMonPlayer(module)
    let tables = module.count - 128
    var out = Recorder()
    _ = player.run(&out)
    #expect(out.events.contains("buffer 0 \(tables) 16"))
    #expect(player.memory[tables] == 1)
    _ = player.run(&out)
    for i in 0 ..< 32 { #expect(player.memory[tables + i] == (i < 16 ? 0 &- wave[i] : wave[i])) }
    // The next note, at the third row, puts the waveform back as it was, and the EG begins again.
    for _ in 2 ... 12 { _ = player.run(&out) }
    #expect(player.memory[tables] == wave[0])
    _ = player.run(&out)
    #expect(player.memory[tables] == 0 &- wave[0])
    // And the module is as it was when the song is begun again.
    try player.select(song: 0)
    for i in 0 ..< 64 { #expect(player.memory[tables + i] == wave[i]) }
}

@Test func soundMonEffectSmoothsTheWaveform() throws {
    // 2.2's effect 1, the waveform's first 32 bytes each the mean of its neighbours, on every tick.
    let square = (0 ..< 64).map { UInt8(bitPattern: $0 & 1 == 0 ? 100 : -100) }
    let instrument = synth([1: 0, 2: 0, 3: 16, 22: 1, 23: 1, 29: 64])
    let module = soundMon(version: "3", instruments: [instrument], steps: oneStep, patterns: [[0: (25, 1, 0, 0)], [:]],
                          tables: [square])
    var player = try SoundMonPlayer(module)
    let tables = module.count - 64
    var out = Recorder()
    _ = player.run(&out)
    #expect(player.memory[tables] == 100)
    _ = player.run(&out)
    // The first byte, from the one before the table (the last of the patterns, nought) and the second.
    #expect(Int8(bitPattern: player.memory[tables]) == -50)
    var loudest = 0
    for i in 0 ..< 31 { loudest = max(loudest, abs(Int(Int8(bitPattern: player.memory[tables + i])))) }
    #expect(loudest < 100)
    // Past the 32 bytes it smooths, the waveform is as it was.
    #expect(player.memory[tables + 40] == square[40])
}

@Test func soundMonSongLengthAndEnd() throws {
    let module = soundMon(instruments: [sample(length: 100)], steps: oneStep, patterns: [[0: (25, 1, 0, 0)], [:]],
                          samples: [UInt8](repeating: 1, count: 200))
    var player = try SoundMonPlayer(module)
    // Sixteen rows of six ticks.
    #expect(player.lengthClocks == UInt64(96 * 70940))
    var out = Recorder()
    for _ in 0 ..< 96 { _ = player.run(&out) }
    #expect(player.endings == 0)
    _ = player.run(&out)
    #expect(player.endings == 1)
}

@Test func soundMonJumpsBackEndTheSong() throws {
    // 2.2: three steps, the last jumping back to the second at its last row, which goes round for ever.
    let jump = soundMon(version: "3", instruments: [sample(length: 100)], steps: [[2, 2, 2, 1], [2, 2, 2, 1], [2, 2, 2, 3]],
                        patterns: [[0: (25, 1, 0, 0)], [:], [15: (0, 0, 7, 1)]], samples: [UInt8](repeating: 1, count: 200))
    #expect(try SoundMonPlayer(jump).lengthClocks == UInt64(3 * 96 * 70940))
    // 2.0: a count of two, then a jump at the second step's last row, to the first (the step after it
    // being the one played next): taken once, and the song goes on to its end, four steps in all.
    let repeated = soundMon(instruments: [sample(length: 100)], steps: [[2, 2, 2, 1], [2, 2, 2, 3], [2, 2, 2, 1]],
                            patterns: [[0: (25, 1, 6, 2)], [:], [15: (0, 0, 7, 0)]], samples: [UInt8](repeating: 1, count: 200))
    #expect(try SoundMonPlayer(repeated).lengthClocks == UInt64(4 * 96 * 70940))
}

@Test func soundMonOddModulesNeitherHangNorTrap() throws {
    // Notes past the table of periods, either way; instruments nought and past fifteen; a pattern of
    // nought; a speed of nought; a synthesised sound of a waveform past the module, of 65,535 words,
    // its tables of no length; and 2.0's EG of a first value below 8.
    let odd = synth([1: 255, 2: 0xFF, 3: 0xFF, 4: 2, 5: 9, 9: 2, 10: 9, 11: 3, 17: 2, 18: 9, 19: 3, 22: 1, 25: 0x80, 26: 9, 29: 0x7F])
    let rows: [Int: Row] = [0: (100, 1, 10, 0xF0), 1: (0x90, 2, 0, 0x7F), 2: (5, 0, 9, 0xFF), 3: (10, 15, 11, 1),
                            4: (40, 2, 2, 0), 5: (1, 3, 13, 0)]
    for version: Character in ["2", "3"] {
        var module = soundMon(version: version, instruments: [sample(length: 0xFFFF, loop: 0xFFFF, loopLength: 0xFFFF), odd, odd],
                              steps: [[0, 1, 1, 1], [1, 0, 1, 1]], patterns: [rows], tables: [[1, 2, 3]], samples: [7, 7])
        module[512 + 2] = 0xF3 // A transpose of the instruments past fifteen.
        var player = try SoundMonPlayer(module)
        var out = Recorder()
        for _ in 0 ..< 3000 { _ = player.run(&out) }
        for v in 0 ..< 4 { #expect(player.volume(v) <= 64) }
    }
    // Steps that the file is far too short for.
    var short = soundMon(instruments: [], steps: oneStep, patterns: [[:]])
    short[30 ..< 32] = [0xFF, 0xFF]
    var player = try SoundMonPlayer(short)
    var out = Recorder()
    for _ in 0 ..< 300 { _ = player.run(&out) }
}

/// Option 3 turns the filter on for anything but nought, and off for nought; a song starts with it off.
@Test func soundMonOptionThreeTurnsTheFilter() throws {
    let on = soundMon(instruments: [sample(length: 100)], steps: oneStep, patterns: [[0: (25, 1, 3, 1)], [:]],
                      samples: [UInt8](repeating: 1, count: 200))
    var player = try SoundMonPlayer(on)
    var states = [player.lightFilter]
    var out = Recorder()
    _ = player.run(&out)
    states.append(player.lightFilter)
    try player.select(song: 0)
    states.append(player.lightFilter)
    let off = soundMon(instruments: [sample(length: 100)], steps: oneStep, patterns: [[0: (25, 1, 3, 0)], [:]],
                       samples: [UInt8](repeating: 1, count: 200))
    var other = try SoundMonPlayer(off)
    _ = other.run(&out)
    states.append(other.lightFilter)
    #expect(states == [false, true, false, false])
}

@Test func soundMonPlaysThroughTheRenderer() throws {
    let module = soundMon(instruments: [sample(length: 100, loop: 0, loopLength: 100)], steps: oneStep,
                          patterns: [[0: (25, 1, 0, 0)], [:]], samples: (0 ..< 200).map { UInt8(bitPattern: Int8($0 % 2 == 0 ? 90 : -90)) })
    let renderer = try PaulaTickRenderer(try SoundMonPlayer(module), options: LoadOptions())
    #expect(renderer.info.format == "BP")
    #expect(renderer.info.detail == "SoundMon 2.0")
    #expect(renderer.info.title == "tiny")
    let frames = 4800
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.01)
    #expect(renderer.songs.first?.length != nil)
}

/// Each voice but Paula's first plays the empty pattern `empty`; her first, pattern `pattern`.
private func step(_ pattern: Int, empty: Int) -> [Int] { [empty, empty, empty, pattern] }

@Test func soundMonFindsTheSongsAModuleHolds() throws {
    // 2.2: two steps that each go round on themselves (its jump is to the step given, from its first
    // row), and a third that plays on to the end of the list.
    let module = soundMon(version: "3", instruments: [sample(length: 100)],
                          steps: [step(1, empty: 4), step(2, empty: 4), step(3, empty: 4)],
                          patterns: [[0: (25, 1, 0, 0), 15: (0, 0, 7, 0)], [0: (27, 1, 0, 0), 15: (0, 0, 7, 1)], [0: (29, 1, 0, 0)], [:]],
                          samples: [UInt8](repeating: 1, count: 200))
    var player = try SoundMonPlayer(module)
    #expect(player.songCount == 3)
    #expect(player.songStarts == [0, 1, 2])
    for (song, note) in [(0, 25), (1, 27), (2, 29)] {
        try player.select(song: song)
        #expect(player.song == song)
        #expect(player.lengthClocks == UInt64(96 * 70940))
        // Each song is begun as the player is set up, but at its own step.
        var out = Recorder()
        _ = player.run(&out)
        #expect(player.period(0) == SoundMonPlayer.periodTable[note - 1 + 36])
        for _ in 0 ..< 96 { _ = player.run(&out) }
        #expect(player.endings == 1)
    }
    #expect(throws: TuneError.self) { try player.select(song: 3) }
    // A player made for a song starts with it, and one made for a song there is not, with the first.
    #expect(try SoundMonPlayer(module, song: 2).song == 2)
    #expect(try SoundMonPlayer(module, song: 7).song == 0)
    let renderer = try PaulaTickRenderer(try SoundMonPlayer(module), options: LoadOptions())
    #expect(renderer.subsongCount == 3)
    #expect(renderer.currentSubsong == 0)
    #expect(renderer.songs.count == 3)
}

@Test func soundMonSongsAreFoundByTwoPointNoughtsJumps() throws {
    // 2.0, whose jump lands on the row after the one it is at: from a step's last row, on the step after
    // the one it names. An intro, then a step that goes round on itself; and another step that does.
    // Each is begun with the count of repeats `bpinit` sets, one; each sets its own count, here.
    let module = soundMon(instruments: [sample(length: 100)],
                          steps: [step(1, empty: 4), step(2, empty: 4), step(3, empty: 4)],
                          patterns: [[0: (25, 1, 6, 255)], [0: (27, 1, 6, 255), 15: (0, 0, 7, 0)],
                                     [0: (29, 1, 6, 255), 15: (0, 0, 7, 1)], [:]],
                          samples: [UInt8](repeating: 1, count: 200))
    var player = try SoundMonPlayer(module)
    #expect(player.songStarts == [0, 2])
    #expect(player.lengthClocks == UInt64(2 * 96 * 70940))
    try player.select(song: 1)
    #expect(player.lengthClocks == UInt64(96 * 70940))
}

@Test func soundMonKeepsOnlyWhatIsASong() throws {
    // 2.2. Step 0 goes round on itself. Step 1 plays on into step 2, a step of silence going round on
    // itself. Step 3 is a jingle that ends in that silence: a song. Step 4 is a short way into the
    // first song, and is not one; nor is step 5, empty, after which the list comes round to the first
    // step's note.
    let module = soundMon(version: "3", instruments: [sample(length: 100)],
                          steps: [step(1, empty: 6), step(2, empty: 6), step(3, empty: 6), step(4, empty: 6), step(5, empty: 6),
                                  step(6, empty: 6)],
                          patterns: [[0: (25, 1, 0, 0), 15: (0, 0, 7, 0)], [0: (27, 1, 0, 0)], [15: (0, 0, 7, 2)],
                                     [0: (29, 1, 0, 0), 15: (0, 0, 7, 2)], [0: (31, 1, 0, 0), 15: (0, 0, 7, 0)], [:]],
                          samples: [UInt8](repeating: 1, count: 200))
    var player = try SoundMonPlayer(module)
    #expect(player.songStarts == [0, 1, 3])
    for song in 1 ... 2 {
        try player.select(song: song)
        #expect(player.lengthClocks == UInt64(2 * 96 * 70940))
    }
}
