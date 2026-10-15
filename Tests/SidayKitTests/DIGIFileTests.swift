// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of DIGI Booster's modules, which FastTracker 2's replayer plays. The thorough check is
// made outside the package, against libopenmpt: every channel's pitch and volume on every tick of
// each file to hand, every sample's sound, and what is heard.

private func long(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count)) }

/// One channel's part of a row: a period (428 is C-2, which plays a sample at 8,287 Hz; 0 for
/// none), a sample and a command, as a MOD file has them.
private struct Cell {
    var period = 0, sample = 0, command: UInt8 = 0, value: UInt8 = 0

    static func note(_ period: Int = 428, _ sample: Int = 1, _ command: UInt8 = 0, _ value: UInt8 = 0) -> Cell {
        Cell(period: period, sample: sample, command: command, value: value)
    }

    static func command(_ command: UInt8, _ value: UInt8) -> Cell { Cell(command: command, value: value) }

    var bytes: [UInt8] { [UInt8(sample & 0xF0) | UInt8(period >> 8 & 15), UInt8(period & 0xFF), UInt8(sample & 15) << 4 | command, value] }
}

/// A sample: a square wave of 32 samples, signed, that goes round.
private struct Sound {
    var frames: [Int8] = (0 ..< 32).map { $0 < 16 ? 100 : -100 }
    var loops = true
}

private func digi(_ cells: [(row: Int, channel: Int, cell: Cell)], channels: Int = 4, packed: Bool = false, sounds: [Sound] = [Sound()]) -> [UInt8] {
    var file = Array("DIGI Booster module".utf8) + [0] + Array("V1.7".utf8) + [0x17, UInt8(channels), packed ? 1 : 0]
    file += [UInt8](repeating: 0, count: 19) + [0, 0] + [UInt8](repeating: 0, count: 128)
    for i in 0 ..< 31 { file += long(i < sounds.count ? sounds[i].frames.count : 0) }
    for _ in 0 ..< 31 { file += long(0) }
    for i in 0 ..< 31 { file += long(i < sounds.count && sounds[i].loops ? sounds[i].frames.count : 0) }
    file += [UInt8](repeating: 64, count: 31) + [UInt8](repeating: 0, count: 31)
    file += padded(Array("a square wave".utf8), to: 32) + [UInt8](repeating: 0, count: 31 * 30)
    var grid = [[Cell]](repeating: [Cell](repeating: Cell(), count: channels), count: 64)
    for (row, channel, cell) in cells { grid[row][channel] = cell }
    if packed {
        var masks: [UInt8] = [], notes: [UInt8] = []
        for row in grid {
            var mask: UInt8 = 0
            for (channel, cell) in row.enumerated() where cell.bytes != [0, 0, 0, 0] {
                mask |= 0x80 >> UInt8(channel)
                notes += cell.bytes
            }
            masks.append(mask)
        }
        let length = 64 + notes.count
        file += [UInt8(length >> 8), UInt8(length & 0xFF)] + masks + notes
    } else {
        // A channel at a time, and not a row.
        for channel in 0 ..< channels {
            for row in 0 ..< 64 { file += grid[row][channel].bytes }
        }
    }
    for sound in sounds { file += sound.frames.map { UInt8(bitPattern: $0) } }
    return file
}

private func stereo(_ renderer: any Renderer, seconds: Double) -> (left: [Float], right: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

private func crossings(_ samples: ArraySlice<Float>) -> Int {
    zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
}

private func loudness(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

private func heard(_ file: [UInt8], seconds: Double = 1) throws -> [Float] {
    stereo(try TuneLoader.load(file, format: .digi), seconds: seconds).left
}

/// What a channel is at on each of so many ticks: its period, and its volume of 64.
private func ticks(_ file: [UInt8], _ count: Int, channel: Int = 0) throws -> [(period: Int, volume: Int)] {
    let player = FT2Player(try FT2Module(DIGIFile.read(file)))
    return (0 ..< count).map { _ in
        _ = player.runTick()
        return (Int(player.stm[channel].finalPeriod), Int(player.stm[channel].outVol))
    }
}

@Test func digiNoteSoundsAtItsPitchOnAnAmiga() throws {
    #expect(TuneFormat(fileExtension: "DIGI") == .digi)
    let file = digi([(0, 0, .note())])
    let renderer = try TuneLoader.load(file, format: .digi)
    #expect(renderer.info.format == "DIGI" && renderer.info.title == "a square wave" && renderer.info.shortfalls.isEmpty)
    // A period of the Amiga's PAL clock: 3,546,895 Hz over 428, and the square wave is 32 samples.
    #expect(abs(crossings(try heard(file)[4800...]) * 10 / 9 - 259) <= 2)
    // A packed pattern is the same tune.
    let cells: [(row: Int, channel: Int, cell: Cell)] = [(0, 0, .note()), (4, 2, .note(214)), (8, 1, .note(320, 1, 0xC, 0x20))]
    #expect(try heard(digi(cells)) == heard(digi(cells, packed: true)))
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(file.prefix(400)), format: .digi) }
}

@Test func digiCommandsOfItsOwn() throws {
    // E30 plays the sample backwards, as a sample of its own turned round.
    let turned = Sound(frames: (0 ..< 32).map { Int8($0) }, loops: false)
    let module = try DIGIFile.read(digi([(0, 0, .note(428, 1, 0xE, 0x30))], sounds: [turned]))
    #expect(module.samples.count == 32)
    #expect(module.samples[31]?.data == (0 ..< 32).reversed().map { UInt8($0) } && module.samples[31]?.repeatLength == 0)
    #expect(module.patterns[0].notes[0].instr == 32)
    // E40 stops the note, and an instrument with no note after it starts nothing.
    let stopped = try heard(digi([(0, 0, .note()), (4, 0, .command(0xE, 0x40)), (6, 0, .note(0, 1))]), seconds: 1)
    #expect(loudness(stopped[1000 ..< 4000]) > 0.01 && loudness(stopped[24000 ..< 34000]) < 0.0001 && loudness(stopped[36000...]) < 0.0001)
    // An arpeggio is the second note on the row's first tick, the note itself on the next, then the first.
    let arpeggio = try ticks(digi([(0, 0, .note(428, 1, 0, 0x47))]), 4)
    let c = 428 * 4, e = 340 * 4, g = 285 * 4
    #expect(abs(arpeggio[0].period - g) <= 8 && abs(arpeggio[1].period - c) <= 8 && abs(arpeggio[2].period - e) <= 8 && abs(arpeggio[3].period - g) <= 8)
    // DIGI Booster's robot voice is said to be left out.
    #expect(try TuneLoader.load(digi([(0, 0, .note(428, 1, 0x8, 0x10))]), format: .digi).info.shortfalls == ["Its robot voice (8xx) is left out, as OpenMPT leaves it out."])
}

@Test func digiDamagedFilesDoNotTrap() throws {
    let whole = digi([(0, 0, .note()), (2, 1, .note(214, 1, 0xE, 0x31)), (4, 0, .command(0xE, 0x62)), (5, 3, .command(0xB, 7))], packed: true)
    for length in stride(from: 0, to: whole.count, by: 11) {
        if let renderer = try? TuneLoader.load(Array(whole[..<length]), format: .digi) { _ = stereo(renderer, seconds: 0.1) }
    }
    var seed: UInt32 = 1
    for _ in 0 ..< 200 {
        var damaged = whole
        for _ in 0 ..< 4 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            damaged[Int(seed >> 8) % damaged.count] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        if let renderer = try? TuneLoader.load(damaged, format: .digi) { _ = stereo(renderer, seconds: 0.05) }
    }
}
