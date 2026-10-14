// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Checks of the reading of STX files into STM files. The thorough check is made outside the
// package: siday's samples of each file to hand beside st2play's of the STM file it was read into.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16) }
private func padded(_ text: String, to length: Int) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: max(0, length - text.utf8.count)) }
private func aligned(_ bytes: inout [UInt8]) { bytes += [UInt8](repeating: 0, count: (16 - bytes.count % 16) % 16) }

/// What a channel has on a row: a note (its octave in the high half; 255 for none, 254 to cut), a
/// sample, a volume (nil for none), and a command by its letter.
private struct Event {
    var row: Int, channel: Int
    var note: UInt8 = 0x20, sample: UInt8 = 1, volume: UInt8? = nil, command: Character? = nil, value: UInt8 = 0
}

/// A sample: a square wave of 32 bytes that goes round, unless it says otherwise.
private struct Sound {
    var frames: [Int8] = (0 ..< 32).map { $0 < 16 ? 100 : -100 }
    var loop: (Int, Int)? = (0, 32)
    var volume: UInt8 = 64
    var rate = 8192
    /// An S3M sample's flags: 1 to go round, 2 for stereo, 4 for sixteen bits.
    var flags: UInt8? = nil
    var length: Int? = nil
}

/// An STX file, as STM2STX made them: of its second version unless `lengthFirst`, in which each
/// pattern begins with its length.
private func stx(_ patterns: [[Event]], orders: [UInt8] = [0], tempo: UInt8 = 0x60, sounds: [Sound] = [Sound()], volume: UInt8 = 64,
                 lengthFirst: Bool = false, sampleSlots: Int? = nil) -> [UInt8] {
    var packed: [[UInt8]] = []
    for pattern in patterns {
        var bytes: [UInt8] = []
        for row in 0 ..< 64 {
            for event in pattern where event.row == row {
                var what = UInt8(event.channel) | 0x20
                if event.volume != nil { what |= 0x40 }
                if event.command != nil { what |= 0x80 }
                bytes += [what, event.note, event.sample]
                if let volume = event.volume { bytes.append(volume) }
                if let command = event.command { bytes += [command.asciiValue! - 64, event.value] }
            }
            bytes.append(0)
        }
        packed.append(bytes)
    }
    let slots = sampleSlots ?? sounds.count
    // The header, then the tables of where the patterns and samples are, then the channels and
    // the list, then the samples' headers, the patterns and the sound.
    var file: [UInt8] = []
    let patternSize = lengthFirst ? (packed.first?.count ?? 0) + 2 : 0x1A
    func header(_ patternTable: Int, _ sampleTable: Int, _ channelTable: Int) -> [UInt8] {
        var h = padded("a square wave", to: 20) + Array("!Scream!".utf8) + word(patternSize) + word(0)
        h += word(patternTable) + word(sampleTable) + word(channelTable) + long(0) + [volume, tempo] + long(1)
        h += word(patterns.count) + word(slots) + word(orders.count) + [0, 0, 0, 0, 0, 0] + Array("SCRM".utf8)
        return h
    }
    let patternTable = 4, sampleTable = patternTable + (patterns.count * 2 + 15) / 16
    let channelTable = sampleTable + (slots * 2 + 15) / 16
    let listParagraphs = (32 + orders.count * 5 + 15) / 16
    var at = channelTable + listParagraphs
    let samplesAt = at
    at += slots * 5
    var patternPlaces: [Int] = []
    for bytes in packed {
        patternPlaces.append(at)
        at += (bytes.count + (lengthFirst ? 2 : 0) + 15) / 16
    }
    var soundPlaces: [Int] = []
    for sound in sounds {
        soundPlaces.append(at)
        at += (sound.frames.count + 15) / 16
    }
    file = header(patternTable, sampleTable, channelTable)
    aligned(&file)
    file += patternPlaces.flatMap(word)
    aligned(&file)
    file += (0 ..< slots).flatMap { word(samplesAt + $0 * 5) }
    aligned(&file)
    file += [UInt8](repeating: 0, count: 32) + orders.flatMap { [$0, 0, 0, 0, 0] }
    aligned(&file)
    for slot in 0 ..< slots {
        guard slot < sounds.count else {
            file += [UInt8](repeating: 0, count: 80)
            continue
        }
        let one = sounds[slot], place = soundPlaces[slot]
        file += [1] + padded("square.smp", to: 12) + [UInt8(place >> 16), UInt8(place & 0xFF), UInt8(place >> 8 & 0xFF)]
        file += long(one.length ?? one.frames.count) + long(one.loop?.0 ?? 0) + long(one.loop?.1 ?? 0)
        file += [one.volume, 0, 0, one.flags ?? (one.loop == nil ? 0 : 1)] + long(one.rate) + [UInt8](repeating: 0, count: 12)
        file += padded("a square wave", to: 28) + Array("SCRS".utf8)
    }
    for bytes in packed {
        if lengthFirst { file += word(bytes.count + 2) }
        file += bytes
        aligned(&file)
    }
    for sound in sounds {
        file += sound.frames.map { UInt8(bitPattern: $0) }
        aligned(&file)
    }
    return file
}

/// The same tune as an STM file.
private func stm(_ patterns: [[Event]], orders: [UInt8] = [0], tempo: UInt8 = 0x60, sounds: [Sound] = [Sound()], volume: UInt8 = 64) -> [UInt8] {
    var packed: [UInt8] = []
    for pattern in patterns {
        var cells = [[UInt8]](repeating: [0xFF, 0x01, 0x80, 0], count: 256)
        for event in pattern {
            let volume = event.volume ?? 65, command = event.command.map { $0.asciiValue! - 64 } ?? 0
            cells[event.row * 4 + event.channel] = [event.note, event.sample << 3 | volume & 7, (volume & 0x78) << 1 | command, event.value]
        }
        packed += cells.flatMap { $0 }
    }
    var file = padded("a square wave", to: 20) + Array("!Scream!".utf8) + [0x1A, 2, 2, 21, tempo, UInt8(patterns.count), volume]
    file += [UInt8](repeating: 0, count: 13)
    var place = (48 + 31 * 32 + 128 + packed.count + 15) / 16
    var sound: [UInt8] = []
    for number in 0 ..< 31 {
        guard number < sounds.count else {
            file += [UInt8](repeating: 0, count: 32)
            continue
        }
        let one = sounds[number]
        file += padded("square.smp", to: 12) + [0, 0] + word(place) + word(one.frames.count) + word(one.loop?.0 ?? 0) + word(one.loop?.1 ?? 0)
        file += [one.volume, 0] + word(one.rate) + [0, 0, 0, 0, 0, 0]
        sound += one.frames.map { UInt8(bitPattern: $0) }
        aligned(&sound)
        place += (one.frames.count + 15) / 16
    }
    file += orders + [UInt8](repeating: 99, count: 128 - orders.count)
    file += packed
    aligned(&file)
    return file + sound
}

private func raw(_ file: [UInt8], format: TuneFormat, seconds: Double = 2, muted: [Bool] = []) throws -> [Int16] {
    let renderer = try #require(try TuneLoader.load(file, format: format) as? STMRenderer)
    renderer.setMuted(muted)
    return renderer.renderRaw(frames: Int(seconds * Double(ST2Player.mixRate)))
}

/// A tune of two patterns with something of most of what a row can have in it.
private let busy: [[Event]] = [
    [Event(row: 0, channel: 0), Event(row: 0, channel: 1, note: 0x34, sample: 2, volume: 40, command: "H", value: 0x46),
     Event(row: 4, channel: 2, note: 0x27, sample: 1, command: "J", value: 0x37), Event(row: 8, channel: 0, note: 0xFF, sample: 0, volume: 20),
     Event(row: 12, channel: 3, note: 0x31, sample: 2, command: "D", value: 0x04), Event(row: 16, channel: 1, note: 0xFE, sample: 0),
     Event(row: 20, channel: 0, note: 0x40, sample: 1, command: "F", value: 0x03), Event(row: 30, channel: 2, note: 0xFF, sample: 0, command: "A", value: 0x48)],
    [Event(row: 0, channel: 2, note: 0x22, sample: 2), Event(row: 2, channel: 0, note: 0x29, sample: 1, command: "G", value: 0x10),
     Event(row: 10, channel: 3, note: 0xFF, sample: 0, command: "C", value: 0)],
]
private let busySounds = [Sound(), Sound(frames: (0 ..< 200).map { Int8(truncatingIfNeeded: $0 * 7) }, loop: (100, 200), volume: 50, rate: 9000)]

@Test func stxIsPlayedAsTheSTMItWasMadeFrom() throws {
    #expect(TuneFormat(fileExtension: "STX") == .stx && TuneFormat.stx.chapter == "STM")
    let file = stx(busy, orders: [0, 1, 0], sounds: busySounds)
    let renderer = try TuneLoader.load(file, format: .stx)
    #expect(renderer.info.format == "STX" && renderer.info.title == "a square wave" && renderer.info.shortfalls.isEmpty)
    #expect(renderer.channelCount == 4)
    // To the sample, as the STM file it stands for; and of either version of the converter.
    let asSTM = try raw(stm(busy, orders: [0, 1, 0], sounds: busySounds), format: .stm, seconds: 6)
    #expect(asSTM.contains { $0 != 128 })
    #expect(try raw(file, format: .stx, seconds: 6) == asSTM)
    #expect(try raw(stx(busy, orders: [0, 1, 0], sounds: busySounds, lengthFirst: true), format: .stx, seconds: 6) == asSTM)
    // The tempo is Scream Tracker 2's, ticks to the row and a factor, in the header and in A.
    #expect(try raw(stx(busy, tempo: 0x48, sounds: busySounds), format: .stx) == (try raw(stm(busy, tempo: 0x48, sounds: busySounds), format: .stm)))
    #expect(renderer.knownLength == (try TuneLoader.load(stm(busy, orders: [0, 1, 0], sounds: busySounds), format: .stm).knownLength))
}

@Test func stxChannelLeftOutIsNotHeard() throws {
    let file = stx([[Event(row: 0, channel: 0), Event(row: 0, channel: 1, note: 0x30)]])
    let alone = try raw(stx([[Event(row: 0, channel: 0)]]), format: .stx)
    #expect(try raw(file, format: .stx) != alone)
    #expect(try raw(file, format: .stx, muted: [false, true]) == alone)
    let renderer = try TuneLoader.load(file, format: .stx)
    var buffer = [Float](repeating: 0, count: 9600 * 2), levels = [Float](repeating: 0, count: 4)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 9600) }
    renderer.takeChannelLevels(into: &levels)
    #expect(levels[0] > 0.5 && levels[1] > 0.5 && levels[2] == 0)
}

@Test func stxSaysWhatAnSTMFileHasNoRoomFor() throws {
    func shortfalls(_ file: [UInt8]) throws -> [String] { try TuneLoader.load(file, format: .stx).info.shortfalls }
    // A fifth channel, which is not heard.
    let five = stx([[Event(row: 0, channel: 0), Event(row: 0, channel: 4, note: 0x30)]])
    #expect(try shortfalls(five) == ["It has more channels than Scream Tracker 2's four, and those after the fourth are not heard."])
    #expect(try raw(five, format: .stx) == (try raw(stx([[Event(row: 0, channel: 0)]]), format: .stx)))
    // A sample of sixteen bits, and one past the 31st, when the tune plays them; not when it does not.
    let wide = [Sound(), Sound(flags: 4)]
    #expect(try shortfalls(stx([[Event(row: 0, channel: 0, sample: 2)]], sounds: wide)).count == 1)
    #expect(try shortfalls(stx([[Event(row: 0, channel: 0)]], sounds: wide)).isEmpty)
    let many = [Sound](repeating: Sound(), count: 33)
    #expect(try shortfalls(stx([[Event(row: 0, channel: 0, sample: 33)]], sounds: many)).count == 1)
    #expect(try shortfalls(stx([[Event(row: 0, channel: 0, sample: 31)]], sounds: many)).isEmpty)
    // A list longer than an STM file's is played to its 128th place.
    let long = stx([[Event(row: 0, channel: 0)]], orders: [UInt8](repeating: 0, count: 129))
    #expect(try shortfalls(long).count == 1)
    // And a file cut short in its samples says so.
    let whole = stx([[Event(row: 0, channel: 0)]], sounds: [Sound(frames: [Int8](repeating: 50, count: 4000), loop: nil)])
    #expect(try shortfalls(Array(whole[..<(whole.count - 3000)])).first?.hasPrefix("The file is cut short") == true)
}

@Test func stxFileThatIsCutOrDamagedIsReadOrRefused() throws {
    let whole = stx(busy, orders: [0, 1, 9, 98], sounds: busySounds, lengthFirst: true, sampleSlots: 40)
    #expect(throws: TuneError.self) { try TuneLoader.load([], format: .stx) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(whole[..<63]), format: .stx) }
    // An S3M file, and a list with a number in it that is neither a pattern's nor an end's.
    var s3m = whole
    s3m[60] = 0
    #expect(throws: TuneError.self) { try TuneLoader.load(s3m, format: .stx) }
    #expect(throws: TuneError.self) { try TuneLoader.load(stx(busy, orders: [0, 70]), format: .stx) }
    func play(_ file: [UInt8]) {
        guard let renderer = try? TuneLoader.load(file, format: .stx) else { return }
        var buffer = [Float](repeating: 0, count: 4800 * 2)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        #expect(buffer.allSatisfy { $0.isFinite && abs($0) < 2 })
    }
    for length in stride(from: 0, to: whole.count, by: 7) { play(Array(whole[..<length])) }
    var seed: UInt32 = 1991
    func random() -> UInt8 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: seed >> 16)
    }
    for _ in 0 ..< 300 {
        var file = whole
        for i in 64 ..< file.count where random() < 12 { file[i] = random() }
        play(file)
    }
}
