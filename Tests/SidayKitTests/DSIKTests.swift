// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the DSM files of the Digital Sound Interface Kit, which Scream Tracker 3's replayer
// plays. The thorough check is made outside the package, against libopenmpt: every channel's pitch,
// volume and place on every tick of each file to hand, every sample's sound, and what is heard.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count)) }
private func chunk(_ tag: String, _ body: [UInt8]) -> [UInt8] { Array(tag.utf8) + long(body.count) + body }

/// One channel's part of a row: a note (49 is C-4, which plays a sample at its own rate), a sample,
/// a volume and a command, ProTracker's by number.
private struct Cell {
    var note: UInt8?, sample: UInt8?, volume: UInt8?
    var command: (UInt8, UInt8)?

    static func note(_ note: UInt8 = 49, _ sample: UInt8 = 1, _ command: (UInt8, UInt8)? = nil) -> Cell {
        Cell(note: note, sample: sample, command: command)
    }

    static func command(_ command: UInt8, _ value: UInt8) -> Cell { Cell(command: (command, value)) }
}

/// A sample: a square wave of 32 samples at 8,363 samples a second, so that C-4 is 261 Hz.
/// Its flags: 1 for a loop, 2 for a sign, 4 for sixteen bits, 0x40 for differences.
private struct Sound {
    var bytes: [UInt8] = (0 ..< 32).map { $0 < 16 ? 0xFF : 0x01 }
    var flags = 1
    var rate = 8363
}

private func dsm(_ cells: [(row: Int, channel: Int, cell: Cell)], channels: Int = 2, pans: [UInt8] = [0x40, 0x40], sounds: [Sound] = [Sound()],
                 riff: Bool = true) -> [UInt8] {
    var song = padded(Array("a square wave".utf8), to: 28) + word(0) + word(0) + word(0) + word(0)
    song += word(1) + word(sounds.count) + word(1) + word(channels) + [64, 0x30, 6, 125]
    song += (0 ..< 16).map { $0 < pans.count ? pans[$0] : 0x40 } + [0] + [UInt8](repeating: 0xFF, count: 127)
    var pattern: [UInt8] = []
    for row in 0 ..< 64 {
        for (_, channel, cell) in cells.filter({ $0.row == row }) {
            var flag = UInt8(channel)
            if cell.note != nil { flag |= 0x80 }
            if cell.sample != nil { flag |= 0x40 }
            if cell.volume != nil { flag |= 0x20 }
            if cell.command != nil { flag |= 0x10 }
            pattern += [flag] + [cell.note, cell.sample, cell.volume].compactMap { $0 }
            if let (command, value) = cell.command { pattern += [command, value] }
        }
        pattern.append(0)
    }
    var body = Array("DSMF".utf8) + chunk("SONG", song) + chunk("PATT", word(pattern.count + 2) + pattern)
    for sound in sounds {
        let frames = sound.bytes.count / (sound.flags & 4 != 0 ? 2 : 1)
        body += chunk("INST", padded(Array("SQUARE.SMP".utf8), to: 13) + word(sound.flags) + [64] + long(frames) + long(0) + long(frames) + long(0)
            + long(sound.rate) + padded(Array("square".utf8), to: 28) + sound.bytes)
    }
    return riff ? Array("RIFF".utf8) + long(body.count) + body : Array("DSMF".utf8) + [0, 0, 0, 0] + long(body.count) + body
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

private func heard(_ file: [UInt8], seconds: Double = 1) throws -> (left: [Float], right: [Float]) {
    var options = LoadOptions()
    options.stereo = .abc
    return stereo(try TuneLoader.load(file, format: .dsm, options: options), seconds: seconds)
}

@Test func dsmNoteSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "DSM") == .dsm)
    let file = dsm([(0, 0, .note())])
    let renderer = try TuneLoader.load(file, format: .dsm)
    #expect(renderer.info.format == "DSM" && renderer.info.title == "a square wave" && renderer.info.shortfalls.isEmpty)
    #expect(abs(crossings(try heard(file).left[4800...]) * 10 / 9 - 261) <= 2)
    #expect(abs(crossings(try heard(dsm([(0, 0, .note(61))])).left[4800...]) * 10 / 9 - 523) <= 3)
    // The other way a file can begin.
    #expect(abs(crossings(try heard(dsm([(0, 0, .note())], riff: false)).left[4800...]) * 10 / 9 - 261) <= 2)
    // Each channel where the song says, from 00 to 80; and 8xx moves it.
    let left = try heard(dsm([(0, 1, .note())], pans: [0x80, 0]))
    #expect(loudness(left.left[4800...]) > loudness(left.right[4800...]) * 10)
    let moved = try heard(dsm([(0, 1, .note(49, 1, (8, 0x80)))], pans: [0x80, 0]))
    #expect(loudness(moved.right[4800...]) > loudness(moved.left[4800...]) * 10)
    // Surround is in the middle, and said to be.
    let surround = try TuneLoader.load(dsm([(0, 1, .note(49, 1, (8, 0xA4)))], pans: [0x80, 0]), format: .dsm)
    #expect(surround.info.shortfalls == ["Its surround sound (8A4) is played in the middle."])
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(file.prefix(14)), format: .dsm) }
}

@Test func dsmSamplesAreReadInEveryKind() throws {
    let unsigned = Sound(bytes: [0xFF, 0x00, 0x80], flags: 0), signed = Sound(bytes: [0x7F, 0x80, 0x00], flags: 2)
    let differences = Sound(bytes: [0x10, 0x10, 0xE0], flags: 0x42), sixteen = Sound(bytes: [0x34, 0x12, 0xFF, 0xFF], flags: 6)
    let module = try ST3Module(DSMFile.read(dsm([(0, 0, .note())], sounds: [unsigned, signed, differences, sixteen])).s3m)
    func sound(_ i: Int) -> [Int16] { (0 ..< Int(module.ins[i].length)).map { module.samples[module.ins[i].baseptr + $0] } }
    #expect(sound(0) == [0x7F00, -0x8000, 0])
    #expect(sound(1) == [0x7F00, -0x8000, 0])
    #expect(sound(2) == [0x1000, 0x2000, 0])
    #expect(sound(3) == [0x1234, -1])
}

@Test func dsmSlidesToNotesAsOpenMPTPlaysThem() throws {
    // A slide to a note that names another sample goes on with the one that is sounding, at its rate.
    let faster = Sound(bytes: (0 ..< 4000).map { $0 % 32 < 16 ? 0xFF : 0x01 }, rate: 16726)
    let long = Sound(bytes: (0 ..< 4000).map { $0 % 32 < 16 ? 0xFF : 0x01 })
    let module = try ST3Module(DSMFile.read(dsm([(0, 0, .note()), (1, 0, .note(49, 2, (3, 0x10)))], sounds: [long, faster])).s3m)
    module.playsAsDSIK = true
    let player = ST3Player(module, card: .gus)
    var speeds: [Int16] = []
    for _ in 0 ..< 12 {
        player.tick()
        speeds.append(player.zchn[0].aspd)
    }
    #expect(speeds[11] == speeds[0])
}

@Test func dsmDamagedFilesDoNotTrap() throws {
    let whole = dsm([(0, 0, .note()), (1, 1, .note(52, 2, (0xE, 0x93))), (3, 0, .command(0xD, 0x10))], sounds: [Sound(), Sound(flags: 6)])
    for length in stride(from: 0, to: whole.count, by: 5) {
        if let renderer = try? TuneLoader.load(Array(whole[..<length]), format: .dsm) { _ = stereo(renderer, seconds: 0.1) }
    }
    var seed: UInt32 = 1
    for _ in 0 ..< 200 {
        var damaged = whole
        for _ in 0 ..< 4 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            damaged[Int(seed >> 8) % damaged.count] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        if let renderer = try? TuneLoader.load(damaged, format: .dsm) { _ = stereo(renderer, seconds: 0.05) }
    }
}
