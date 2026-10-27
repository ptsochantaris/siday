// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayTrackers
import Testing

// Fast checks of the ULT files that Impulse Tracker's replayer plays. The thorough check is made
// outside the package, against libopenmpt: every channel's pitch and volume on every tick of each
// file to hand, and what is heard.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0x20, count: max(0, length - bytes.count)) }

/// One channel's part of a row: a note (1 is the lowest C; 0 for none), a sample, and two
/// commands, each a number and a value.
private struct Cell: Equatable {
    var note: UInt8 = 0, sample: UInt8 = 0
    var first: (UInt8, UInt8) = (0, 0), second: (UInt8, UInt8) = (0, 0)

    static func == (a: Cell, b: Cell) -> Bool { a.bytes == b.bytes }

    static func note(_ note: UInt8 = 25, sample: UInt8 = 1, _ first: (UInt8, UInt8) = (0, 0), _ second: (UInt8, UInt8) = (0, 0)) -> Cell {
        Cell(note: note, sample: sample, first: first, second: second)
    }

    static func commands(_ first: (UInt8, UInt8), _ second: (UInt8, UInt8) = (0, 0)) -> Cell {
        Cell(first: first, second: second)
    }

    var bytes: [UInt8] { [note, sample, second.0 << 4 | first.0, first.1, second.1] }
}

/// A sample: a square wave of 32 samples, signed, eight bits, played at 8,363 samples a second for
/// the C of the second octave, so that that C is 261 Hz.
private struct Sound {
    var frames: [Int8] = (0 ..< 32).map { $0 < 16 ? 127 : -127 }
    /// 8 if it goes round, 16 more if back and forth, and 4 for a sample of sixteen bits.
    var flags: UInt8 = 8
    var loop: (Int, Int)?
    var volume: UInt8 = 255
    var rate = 8363
}

/// A ULT file of one or more patterns.
/// - Parameters:
///   - version: 1 for a file of before UltraTracker 1.4, and 2, 3 and 4 for one of 1.4, 1.5 and 1.6.
///   - pans: where each channel is, of sixteen places; they are in a file only from 1.5.
private func ult(_ patterns: [[(row: Int, channel: Int, cell: Cell)]], version: UInt8 = 4, channels: Int = 2, orders: [UInt8] = [0], pans: [UInt8] = [],
                 sounds: [Sound] = [Sound()]) -> [UInt8] {
    var file = Array("MAS_UTrack_V00".utf8) + [0x30 + version] + padded(Array("a square wave".utf8), to: 32) + [1]
    file += padded(Array("a line of text".utf8), to: 32)
    file.append(UInt8(sounds.count))
    var place = 32
    for sound in sounds {
        file += padded(Array("square".utf8), to: 32) + padded(Array("SQUARE.SMP".utf8), to: 12)
        let loop = sound.loop ?? (0, sound.frames.count)
        file += long(loop.0) + long(loop.1) + long(place) + long(place + sound.frames.count)
        place += sound.frames.count
        file += [sound.volume, sound.flags]
        if version >= 4 { file += word(sound.rate) }
        file += word(0)
    }
    file += orders + [UInt8](repeating: 0xFF, count: 256 - orders.count)
    file += [UInt8(channels - 1), UInt8(patterns.count - 1)]
    if version >= 3 { file += (0 ..< channels).map { $0 < pans.count ? pans[$0] : 7 } }
    // A channel at a time, and a cell that is the same as those after it once, with how many times.
    for channel in 0 ..< channels {
        for pattern in patterns {
            var cells = [Cell](repeating: Cell(), count: 64)
            for (row, where_, cell) in pattern where where_ == channel { cells[row] = cell }
            var row = 0
            while row < 64 {
                var run = 1
                while row + run < 64, cells[row + run] == cells[row] { run += 1 }
                let bytes = cells[row].bytes
                file += run > 1 ? [0xFC, UInt8(run)] + bytes : bytes
                row += run
            }
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

private func heard(_ file: [UInt8], seconds: Double = 1) throws -> (left: [Float], right: [Float]) {
    var options = LoadOptions()
    options.stereo = .abc
    return stereo(try TuneLoader.load(file, format: .ult, options: options), seconds: seconds)
}

/// What the first channel's voice is at on each of so many ticks: samples a second, its volume
/// of 64, and whether it is sounding.
private func ticks(_ file: [UInt8], _ count: Int, channel: Int = 0) throws -> [(rate: Int, volume: Int, sounding: Bool)] {
    let renderer = try #require(try TuneLoader.load(file, format: .ult) as? ITRenderer)
    let player = IT2Player(renderer.module, forSound: true)
    return (0 ..< count).map { _ in
        player.Update()
        defer { _ = player.mixer.mixTick() }
        guard let voice = player.hChn[channel].SlaveChnPtr, voice.pointee.Flags & SF_CHAN_ON != 0, voice.pointee.Flags & SF_NOTE_STOP == 0 else { return (0, 0, false) }
        return (Int(voice.pointee.Frequency), Int(voice.pointee.FinalVol128) / 2, true)
    }
}

@Test func ultNoteSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "ULT") == .ult)
    let renderer = try TuneLoader.load(ult([[(0, 0, .note())]]), format: .ult)
    #expect(renderer.info.format == "ULT" && renderer.info.title == "a square wave" && renderer.info.shortfalls.isEmpty)
    // The C of the second octave is the one a sample's rate is for: 261 Hz with this sample.
    let sound = try heard(ult([[(0, 0, .note())]]))
    #expect(abs(crossings(sound.left[4800...]) * 10 / 9 - 261) <= 2)
    #expect(abs(crossings(try heard(ult([[(0, 0, .note(37))]])).left[4800...]) * 10 / 9 - 523) <= 3)
    // A file of 1.6 gives each sample a rate; before that every sample was at 8,363.
    let slower = [Sound(rate: 4181)]
    #expect(abs(crossings(try heard(ult([[(0, 0, .note())]], sounds: slower)).left[4800...]) * 10 / 9 - 131) <= 2)
    #expect(abs(crossings(try heard(ult([[(0, 0, .note())]], version: 2, sounds: slower)).left[4800...]) * 10 / 9 - 261) <= 2)
    // From 1.5 a file says where each channel is, of sixteen places; before, they were to the
    // left and the right by turns.
    let left = try heard(ult([[(0, 0, .note())]], pans: [0, 15])), right = try heard(ult([[(0, 1, .note())]], pans: [0, 15]))
    #expect(loudness(left.left[4800...]) > loudness(left.right[4800...]) * 10 && loudness(right.right[4800...]) > loudness(right.left[4800...]) * 10)
    let old = try heard(ult([[(0, 1, .note())]], version: 1))
    #expect(loudness(old.right[4800...]) > loudness(old.left[4800...]) * 1.5)
}

@Test func ultNoteHasTwoCommands() throws {
    // A volume and a place between the speakers, both on the one note.
    let both = try heard(ult([[(0, 0, .note(25, (0xC, 0x80), (0xB, 0x0F)))]]))
    let plain = try heard(ult([[(0, 0, .note())]]))
    #expect(loudness(both.left[4800...]) < 0.0005)
    #expect(abs(loudness(both.right[4800...]) * 2 - (loudness(plain.left[4800...]) + loudness(plain.right[4800...]))) < 0.01)
    // A slide of volume beside a slide of pitch: the volume column takes the one, the command the other.
    let slid = try ticks(ult([[(0, 0, .note(25, (0xA, 0x02), (0x1, 0x10)))]]), 6)
    #expect(slid.map(\.volume) == [64, 62, 60, 58, 56, 54])
    #expect(slid[5].rate > slid[0].rate + 100)
    // A speed and a tempo are two commands under the one number: three ticks to the row, at 250 to the minute.
    let renderer = try TuneLoader.load(ult([[(0, 0, .commands((0xF, 0x03), (0xF, 0xFA)))]]), format: .ult)
    #expect(abs(try #require(renderer.knownLength) - 64 * 3 * 0.01) < 0.01)
    #expect(renderer.info.shortfalls.isEmpty)
    // And a value of nought puts both back as a tune starts with them.
    let back = try TuneLoader.load(ult([[(0, 0, .commands((0xF, 0x03), (0xF, 0xFA))), (32, 0, .commands((0xF, 0)))]]), format: .ult)
    let expected: Double = 32 * 3 * 0.01 + 32 * 6 * 0.02
    #expect(abs(try #require(back.knownLength) - expected) < 0.02)
    // What has nowhere to go is left out, and the file says so: here an arpeggio beside a start further in.
    let crowded = try TuneLoader.load(ult([[(0, 0, .note(25, (0x0, 0x37), (0x9, 0x01)))]]), format: .ult)
    #expect(crowded.info.shortfalls == ["One of its notes has two commands that Impulse Tracker's replayer has no room for, and the second is left out."])
}

@Test func ultInstrumentWithNoNoteLeavesRoomForTwoCommands() throws {
    // An instrument named with no note is its volume again. Beside a slide of volume and a place
    // between the speakers, all three are done: the volume is back, slides, and is on the right.
    let swept = ult([[(0, 0, .note(25, (0xC, 0x40))), (2, 0, .note(0, (0xA, 0x02), (0xB, 0x0F)))]])
    #expect(try TuneLoader.load(swept, format: .ult).info.shortfalls.isEmpty)
    let volumes = try ticks(swept, 18).map(\.volume)
    #expect(volumes[..<12].allSatisfy { $0 == 16 } && Array(volumes[12...]) == [64, 62, 60, 58, 56, 54])
    let sound = try heard(swept)
    #expect(loudness(sound.right[19200...]) > loudness(sound.left[19200...]) * 10)
    // And it starts nothing, where the note is over: Impulse Tracker would have played it again.
    let short = [Sound(frames: [Int8](repeating: 100, count: 256), flags: 0)]
    let over = try ticks(ult([[(0, 0, .note()), (4, 0, .note(0, (0xA, 0x02), (0xB, 0x0F)))]], sounds: short), 36)
    #expect(over[0].sounding && over[24...].allSatisfy { !$0.sounding })
    // A slide of volume that goes on with the last, beside another command, goes on with the last.
    let goesOn = ult([[(0, 0, .note(25, (0xA, 0x02))), (1, 0, .commands((0xA, 0x00), (0x7, 0x00)))]])
    #expect(try TuneLoader.load(goesOn, format: .ult).info.shortfalls.isEmpty)
    #expect(try ticks(goesOn, 12).map(\.volume) == [64, 62, 60, 58, 56, 54, 54, 52, 50, 48, 46, 44])
    // And a vibrato that goes on, beside an arpeggio, still wavers.
    let wavers = ult([[(0, 0, .note(25, (0x4, 0x84))), (1, 0, .commands((0x4, 0x00), (0x0, 0x37)))]], channels: 1)
    #expect(try TuneLoader.load(wavers, format: .ult).info.shortfalls.isEmpty)
    let alone = try ticks(ult([[(0, 0, .note(25, (0x4, 0x84))), (1, 0, .commands((0x0, 0x37)))]], channels: 1), 12).map(\.rate)
    let together = try ticks(wavers, 12).map(\.rate)
    #expect(alone[6...] != together[6...] && alone[..<6] == together[..<6])
    // A vibrato that gives way to another command wavers as far as it would have alone.
    let deep = try ticks(ult([[(0, 0, .note(25, (0x4, 0x82))), (1, 0, .commands((0x4, 0x04)))]]), 12).map(\.rate)
    let beside = try ticks(ult([[(0, 0, .note(25, (0x4, 0x82))), (1, 0, .commands((0x4, 0x04), (0x7, 0x11)))]]), 12).map(\.rate)
    #expect(deep == beside && Set(deep[6...]).count > 3)
}

@Test func ultSlideToANoteGoesOnByItself() throws {
    // A slide to the C above, asked for once: it goes on through the rows after, and stops there.
    let file = ult([[(0, 0, .note()), (1, 0, .note(37, sample: 0, (0x3, 0x20)))]])
    let slide = try ticks(file, 60)
    #expect(slide[..<6].allSatisfy { $0.rate == 8363 })
    #expect(slide[8].rate > slide[7].rate && slide[13].rate > slide[12].rate)
    #expect(slide[59].rate == 16726)
    // Another note ends it.
    let ended = try ticks(ult([[(0, 0, .note()), (1, 0, .note(37, sample: 0, (0x3, 0x04))), (3, 0, .note())]]), 30)
    #expect(ended[29].rate == 8363)
}

@Test func ultSampleGoesRoundWhileItsNoteIsHeld() throws {
    // A sample of a twentieth of a second that goes round: held, it goes on; let go by 5xC, it plays
    // to its end and is over. (It ends away from the middle, and what is heard takes a while to
    // settle from there.)
    let long = [Sound(frames: (0 ..< 832).map { $0 % 32 < 16 ? 127 : -127 })]
    let held = try heard(ult([[(0, 0, .note())]], sounds: long), seconds: 1.5)
    let letGo = try heard(ult([[(0, 0, .note()), (4, 0, .commands((0x5, 0x0C)))]], sounds: long), seconds: 1.5)
    #expect(loudness(held.left[48000...]) > 0.01)
    #expect(loudness(letGo.left[..<19200]) > 0.01 && loudness(letGo.left[60000...]) < 0.0001)
    // 5x2 plays it backwards: a ramp that rises is then one that falls.
    let ramp = [Sound(frames: (0 ..< 256).map { Int8($0 - 128) }, flags: 0)]
    func climb(_ sound: [Float]) -> Float { sound[600] - sound[300] }
    let forwards = climb(try heard(ult([[(0, 0, .note())]], sounds: ramp), seconds: 0.1).left)
    let backwards = climb(try heard(ult([[(0, 0, .note(25, (0x5, 0x02)))]], sounds: ramp), seconds: 0.1).left)
    #expect(forwards > 0.001 && backwards < -0.001)
}

@Test func ultSaysWhatItLeavesOut() throws {
    func shortfalls(_ file: [UInt8]) throws -> [String] { try TuneLoader.load(file, format: .ult).info.shortfalls }
    #expect(try shortfalls(ult([[(0, 0, .note(25, (0x5, 0x01)))]])) == ["One of its commands is left out: playing a note without its sample's loop."])
    #expect(try shortfalls(ult([[(0, 0, .note(25, (0xE, 0x03), (0x5, 0x01)))]])).first?.hasPrefix("Two of its commands are left out") == true)
    #expect(try shortfalls(ult([[(0, 0, .note(25, (0x9, 0x80)))]])) == ["One of its notes is to start further into its sample than can be asked for, and starts sooner."])
    #expect(try shortfalls(ult([[(0, 0, .note(25, (0x9, 0x10), (0x9, 0x00)))]])).isEmpty)
    // An arpeggio came with 1.5 and a tremolo with 1.6: before, the numbers were nothing, and are nothing here.
    #expect(try shortfalls(ult([[(0, 0, .note(25, (0x0, 0x37), (0x7, 0x44)))]], version: 2)).isEmpty)
    let long = [Sound(frames: (0 ..< 4000).map { $0 & 8 == 0 ? 40 : -40 }, flags: 0)]
    #expect(try shortfalls(Array(ult([[(0, 0, .note())]], sounds: long).dropLast(3000))) == ["The file is cut short: its last sample ends in silence."])
}

@Test func ultFileThatIsCutOrDamagedIsReadOrRefused() throws {
    let whole = ult([[(0, 0, .note(25, (0x3, 0x10), (0xA, 0x20))), (1, 1, .note(40, (0x9, 0x04), (0x9, 0x40))), (2, 0, .commands((0xD, 0x12)))], [(0, 0, .note())]],
                    orders: [0, 1, 0xFE, 0], sounds: [Sound(), Sound(frames: [Int8](repeating: 60, count: 300), flags: 4 | 8 | 16)])
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .ult) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("MAS_UTrack_V009 and no more".utf8), format: .ult) }
    for length in stride(from: 0, to: whole.count, by: 29) {
        if let renderer = try? TuneLoader.load(Array(whole[..<length]), format: .ult) { _ = stereo(renderer, seconds: 0.2) }
    }
    var seed: UInt32 = 54321
    func random() -> Int {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Int(seed >> 8)
    }
    for _ in 0 ..< 300 {
        var damaged = whole
        for _ in 0 ..< 1 + random() % 6 { damaged[15 + random() % (damaged.count - 15)] = UInt8(random() & 0xFF) }
        if let renderer = try? TuneLoader.load(damaged, format: .ult) {
            for song in 0 ..< renderer.subsongCount {
                renderer.select(subsong: song)
                _ = stereo(renderer, seconds: 0.1)
            }
        }
    }
}
