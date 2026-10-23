// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayAmigaTrackers
@testable import SidayFoundation
import Testing

// Checks of the reading of MED4 files into MMD0 modules. The thorough check is made outside the
// package: what libxmp reads of each file to hand beside what it reads of the module made of it,
// and OctaMED's own player, in an emulated Amiga, playing that module beside this one playing the
// MED4 file.

private func bytes(_ value: Int, _ count: Int) -> [UInt8] {
    (0 ..< count).map { UInt8(truncatingIfNeeded: value >> ((count - 1 - $0) * 8)) }
}

/// What is on a line of a block: a note (1 the lowest C), an instrument, and a command.
private struct Entry {
    var line: Int, track: Int
    var note: UInt8 = 13, instrument: UInt8 = 1, command: UInt8 = 0, data: UInt8 = 0
    /// False for a command alone.
    var hasNote = true
}

private struct Block {
    var tracks = 4, lines = 64
    var entries: [Entry]
}

private struct Sound {
    var name = "square"
    var volume: UInt8 = 64
    var transpose: Int8 = 0
    /// In words, as MED keeps them.
    var repeatStart = 0, repeatLength = 16
    var type: Int16 = 0
    var frames: [UInt8] = [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16)
}

/// A MED4 file: the instruments, the song, the blocks packed a nibble at a time, the samples, and
/// MED's version.
private func med4(_ blocks: [Block], orders: [UInt8] = [0], sounds: [Sound] = [Sound()], soundsAt: [Int]? = nil, tempo: Int = 33, ticks: Int = 6,
                  flags: UInt8 = 0x18, version: Int? = 0x0300, chunks: [UInt8] = []) -> [UInt8] {
    let places = soundsAt ?? Array(sounds.indices)
    var file: [UInt8] = Array("MED".utf8) + [4]
    var mask: UInt64 = 0
    for place in places { mask |= 1 << UInt64(63 - place) }
    file += [0xFF] + bytes(Int(mask >> 32), 4) + bytes(Int(mask & 0xFFFF_FFFF), 4)
    for sound in sounds {
        // Each field is left out when it is as it would be by default, but the repeat.
        var absent: UInt8 = 0x04 | 0x08
        if sound.volume == 64 { absent |= 0x20 }
        if sound.transpose == 0 { absent |= 0x40 }
        file += [absent, UInt8(sound.name.utf8.count)] + Array(sound.name.utf8)
        file += bytes(sound.repeatStart, 2) + bytes(sound.repeatLength, 2)
        if sound.volume != 64 { file.append(sound.volume) }
        if sound.transpose != 0 { file.append(UInt8(bitPattern: sound.transpose)) }
    }
    file += bytes(blocks.count, 2) + bytes(orders.count, 2) + orders
    file += bytes(tempo, 2) + [0, flags] + bytes(ticks, 2) + [UInt8](repeating: 0, count: 20) + [UInt8](repeating: 64, count: 16) + [64]

    for block in blocks {
        var notes = [[Entry?]](repeating: [Entry?](repeating: nil, count: block.tracks), count: block.lines)
        var commands = notes
        for entry in block.entries {
            if entry.hasNote { notes[entry.line][entry.track] = entry }
            if entry.command != 0 || entry.data != 0 { commands[entry.line][entry.track] = entry }
        }
        // The control: whether each 32 lines have notes and commands on all their lines, on none,
        // or on some, which a mask then says.
        var control = [UInt8](repeating: 0, count: (block.lines + 63) / 64), masks: [UInt8] = []
        for part in 0 ..< (block.lines + 31) / 32 {
            let shift = UInt8(4 * (part % 2))
            for (kind, all, none) in [(notes, UInt8(0x80), UInt8(0x40)), (commands, 0x20, 0x10)] {
                let lines = (part * 32 ..< min(block.lines, part * 32 + 32)).map { line in kind[line].contains { $0 != nil } }
                if lines.allSatisfy({ $0 }) && lines.count == 32 {
                    control[part / 2] |= all >> shift
                } else if !lines.contains(true) {
                    control[part / 2] |= none >> shift
                } else {
                    var bits = 0
                    for (i, on) in lines.enumerated() where on { bits |= 1 << (31 - i) }
                    masks += bytes(bits, 4)
                }
            }
        }
        var nibbles: [Int] = []
        func put(_ value: Int, _ count: Int) { for i in (0 ..< count).reversed() { nibbles.append(value >> (4 * i) & 15) } }
        for line in 0 ..< block.lines {
            for (kind, isNote) in [(notes, true), (commands, false)] where kind[line].contains(where: { $0 != nil }) {
                var present = 0
                for track in 0 ..< block.tracks where kind[line][track] != nil { present |= 0x8000 >> track }
                let count = max(1, (block.tracks + 3) / 4)
                put(present >> (16 - 4 * count), count)
                for track in 0 ..< block.tracks {
                    guard let entry = kind[line][track] else { continue }
                    if isNote {
                        let first = Int(entry.note) | Int(entry.instrument & 0x10) << 3 | Int(entry.instrument & 0x20) << 1
                        put(first << 4 | Int(entry.instrument & 0x0F), 3)
                    } else {
                        put(Int(entry.command) << 8 | Int(entry.data), 3)
                    }
                }
            }
        }
        if nibbles.count % 2 == 1 { nibbles.append(0) }
        let stream = stride(from: 0, to: nibbles.count, by: 2).map { UInt8(nibbles[$0] << 4 | nibbles[$0 + 1]) }
        let head = [UInt8(block.tracks), UInt8(block.lines - 1)] + bytes(stream.count, 2) + control + masks
        file += [UInt8(head.count)] + head + stream
    }

    var samples: UInt64 = 0
    for place in places { samples |= 1 << UInt64(62 - place) }
    file += bytes(Int(samples >> 32), 4) + bytes(Int(samples & 0xFFFF_FFFF), 4)
    for sound in sounds { file += bytes(sound.frames.count, 4) + bytes(Int(UInt16(bitPattern: sound.type)), 2) + sound.frames }
    file += chunks
    if let version { file += Array("MEDV".utf8) + bytes(4, 4) + bytes(version, 4) }
    return file
}

/// The same tune as an MMD0 module, as MED 3.00 would have saved it.
private func mmd0(_ blocks: [Block], orders: [UInt8] = [0], sounds: [Sound] = [Sound()], tempo: Int = 33, ticks: UInt8 = 6, flags: UInt8 = 0x18) -> [UInt8] {
    var file = Array("MMD0".utf8) + [UInt8](repeating: 0, count: 48)
    func put(_ value: Int, _ count: Int, at place: Int) { file.replaceSubrange(place ..< place + count, with: bytes(value, count)) }
    let song = file.count
    put(song, 4, at: 8)
    file += [UInt8](repeating: 0, count: 788)
    for (i, sound) in sounds.enumerated() {
        put(sound.repeatStart, 2, at: song + i * 8)
        put(sound.repeatLength, 2, at: song + i * 8 + 2)
        file[song + i * 8 + 6] = sound.volume
        file[song + i * 8 + 7] = UInt8(bitPattern: sound.transpose)
    }
    put(blocks.count, 2, at: song + 504)
    put(orders.count, 2, at: song + 506)
    for (i, order) in orders.enumerated() { file[song + 508 + i] = order }
    put(tempo, 2, at: song + 764)
    file[song + 767] = flags
    file[song + 769] = ticks
    for track in 0 ..< 16 { file[song + 770 + track] = 64 }
    file[song + 786] = 64
    file[song + 787] = UInt8(sounds.count)
    let table = file.count
    put(table, 4, at: 16)
    file += [UInt8](repeating: 0, count: blocks.count * 4)
    for (number, block) in blocks.enumerated() {
        put(file.count, 4, at: table + number * 4)
        let at = file.count
        file += [UInt8(block.tracks), UInt8(block.lines - 1)] + [UInt8](repeating: 0, count: block.tracks * block.lines * 3)
        for entry in block.entries {
            let p = at + 2 + (entry.line * block.tracks + entry.track) * 3
            if entry.hasNote {
                file[p] = entry.note | (entry.instrument & 0x10) << 3 | (entry.instrument & 0x20) << 1
                file[p + 1] = entry.instrument << 4
            }
            file[p + 1] |= entry.command
            file[p + 2] = entry.data
        }
        if file.count % 2 == 1 { file.append(0) }
    }
    let samples = file.count
    put(samples, 4, at: 24)
    file += [UInt8](repeating: 0, count: sounds.count * 4)
    for (i, sound) in sounds.enumerated() {
        put(file.count, 4, at: samples + i * 4)
        file += bytes(sound.frames.count, 4) + bytes(Int(UInt16(bitPattern: sound.type)), 2) + sound.frames
        if file.count % 2 == 1 { file.append(0) }
    }
    put(file.count, 4, at: 4)
    return file
}

private func heard(_ file: [UInt8], seconds: Double = 3, muted: [Bool] = []) throws -> [Float] {
    let renderer = try TuneLoader.load(file, format: .med)
    renderer.setMuted(muted)
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return buffer
}

/// Two blocks with something of each kind of line in them: a long one of five tracks, whose lines
/// past the 64th need a second control byte, and one with every line full.
private let tune: [Block] = [
    Block(tracks: 5, lines: 100, entries: [
        Entry(line: 0, track: 0), Entry(line: 0, track: 4, note: 25, instrument: 2, command: 0x0C, data: 0x20),
        Entry(line: 5, track: 2, note: 20, instrument: 2), Entry(line: 9, track: 1, command: 0x0D, data: 0x02, hasNote: false),
        Entry(line: 40, track: 3, note: 30, instrument: 1, command: 0x01, data: 0x03), Entry(line: 70, track: 0, note: 18, instrument: 2),
        Entry(line: 99, track: 4, command: 0x0F, data: 0x00, hasNote: false),
    ]),
    Block(tracks: 4, lines: 32, entries: (0 ..< 32).flatMap { [Entry(line: $0, track: $0 % 4, note: UInt8(13 + $0 % 12), command: 0x0C, data: UInt8($0))] }),
]
private let sounds = [Sound(), Sound(name: "lower", volume: 40, transpose: -12, repeatStart: 8, repeatLength: 24,
                                    frames: (0 ..< 64).map { UInt8(truncatingIfNeeded: $0 * 5) })]

@Test func med4IsReadIntoTheModuleMEDWouldHaveSaved() throws {
    let file = med4(tune, orders: [0, 1, 0], sounds: sounds)
    let renderer = try #require(try TuneLoader.load(file, format: .med) as? MEDRenderer)
    #expect(renderer.info.format == "MED" && renderer.info.detail == "MED4, from MED 3.00" && renderer.info.shortfalls.isEmpty)
    let module = try MEDModule(file)
    let song = module.songs[0]
    #expect(song.blocks.count == 2 && song.blocks[0].tracks == 5 && song.blocks[0].lines == 100 && song.blocks[1].lines == 32)
    #expect(song.sequences == [[0, 1, 0]] && song.tempo == 33 && song.ticksPerLine == 6 && song.hexVolumes)
    #expect(song.instruments[0].name == "square" && song.instruments[1].name == "lower")
    #expect(song.instruments[1].volume == 40 && song.instruments[1].transpose == -12 && song.instruments[1].repeatStart == 16 && song.instruments[1].repeatLength == 48)
    #expect(song.instruments[1].length == 64 && song.instruments[1].kind == .sample && song.instruments[0].loops)
    for (number, block) in tune.enumerated() {
        for entry in block.entries {
            let cell = module.cell(song.blocks[number], line: entry.line, track: entry.track)
            let command = module.command(song.blocks[number], page: 0, line: entry.line, track: entry.track)
            if entry.hasNote { #expect(cell.note == entry.note && cell.instrument == entry.instrument) }
            #expect(command.number == entry.command && command.data == entry.data)
        }
    }
    #expect(module.cell(song.blocks[0], line: 6, track: 2).note == 0)
    // And it is played as that module is, to the sample.
    let asModule = try heard(mmd0(tune, orders: [0, 1, 0], sounds: sounds))
    #expect(asModule.contains { $0 != 0 })
    #expect(try heard(file) == asModule)
    // Its tracks can be left out, as any module's.
    #expect(try heard(file, muted: [true, false, false, false, false]) == (try heard(mmd0(tune, orders: [0, 1, 0], sounds: sounds), muted: [true, false, false, false, false])))
    #expect(try heard(file, muted: [true, false, false, false, false]) != asModule)
}

@Test func med4InstrumentsAboveTheFifteenthAndOfMED2() throws {
    // An instrument's number has two more bits beside the note, as in an MMD0 module.
    var many = [Sound](repeating: Sound(), count: 40)
    many[37] = Sound(name: "thirty-eighth", volume: 30)
    let high = [Block(entries: [Entry(line: 0, track: 0, note: 13, instrument: 38)])]
    let module = try MEDModule(med4(high, sounds: many))
    #expect(module.cell(module.songs[0].blocks[0], line: 0, track: 0).instrument == 38 && module.songs[0].instruments[37].volume == 30)
    // A song of MED 2 did not keep its ticks to the line: five with the trackers' sliding, and six without.
    #expect(try MEDModule(med4(high, sounds: many, ticks: 3, version: nil)).songs[0].ticksPerLine == 6)
    #expect(try MEDModule(med4(high, sounds: many, ticks: 3, flags: 0x38, version: nil)).songs[0].ticksPerLine == 5)
    #expect(try TuneLoader.load(med4(high, sounds: many, version: nil), format: .med).info.detail == "MED4, from MED 2.10")
    // Sounds that are not samples are not where an MMD0 module has them, and are not read.
    let shortfalls = try TuneLoader.load(med4(high, sounds: many.enumerated().map { $0.offset == 37 ? Sound(type: -1) : $0.element }), format: .med).info.shortfalls
    #expect(shortfalls.count == 1 && shortfalls[0].contains("synthetic"))
    #expect(try TuneLoader.load(med4(high, sounds: many.enumerated().map { $0.offset == 3 ? Sound(type: -1) : $0.element }), format: .med).info.shortfalls.isEmpty)
    // Nor are the hold and decay of notes, which are said where they are not nought.
    let held = med4(high, sounds: many, chunks: Array("HLDC".utf8) + bytes(4, 4) + [0, 3, 0, 0])
    #expect(try TuneLoader.load(held, format: .med).info.shortfalls.count == 1)
    let none = med4(high, sounds: many, chunks: Array("HLDC".utf8) + bytes(4, 4) + [0, 0, 0, 0])
    #expect(try TuneLoader.load(none, format: .med).info.shortfalls.isEmpty)
}

@Test func med4FileThatIsCutOrDamagedIsReadOrRefused() throws {
    let whole = med4(tune, orders: [0, 1, 0], sounds: sounds + [Sound(type: -2)], chunks: Array("ANNO".utf8) + bytes(5, 4) + Array("notes".utf8))
    #expect(try TuneLoader.load(whole, format: .med).info.comment == "notes")
    func reason(_ file: [UInt8]) -> String {
        do {
            _ = try TuneLoader.load(file, format: .med)
            return "played"
        } catch let error as TuneError {
            if case .unsupported(let why) = error { return why }
            return "malformed"
        } catch {
            return "?"
        }
    }
    // A song whose instruments are in files of their own, and the earlier formats.
    #expect(reason(med4(tune, sounds: sounds, flags: 0x10)).contains("files of their own"))
    #expect(reason(Array("MED".utf8) + [3] + [UInt8](repeating: 0, count: 2000)).contains("MED's first formats"))
    #expect(reason(Array("MED".utf8) + [4] + [UInt8](repeating: 0, count: 2000)) == "malformed")
    func play(_ file: [UInt8]) {
        guard let renderer = try? TuneLoader.load(file, format: .med) else { return }
        var buffer = [Float](repeating: 0, count: 4800 * 2)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
        #expect(buffer.allSatisfy { $0.isFinite && abs($0) < 4 })
    }
    for length in stride(from: 0, to: whole.count, by: 3) { play(Array(whole[..<length])) }
    // Cut in its samples, it says what it has lost of them, as a module does.
    let long = [Sound(frames: [UInt8](repeating: 0x40, count: 4000)), Sound(frames: [UInt8](repeating: 0x40, count: 4000))]
    let both = med4(tune, sounds: long, version: nil)
    func shortfalls(_ file: [UInt8]) throws -> [String] { try TuneLoader.load(file, format: .med).info.shortfalls }
    #expect(try shortfalls(both).isEmpty)
    #expect(try shortfalls(Array(both.dropLast(3000))) == ["The file is cut short: its last sample ends in silence."])
    #expect(try shortfalls(Array(both.dropLast(6000))) == ["The file is cut short: one of its samples is missing, and another ends in silence."])
    var seed: UInt32 = 1990
    func random() -> UInt8 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: seed >> 16)
    }
    for _ in 0 ..< 300 {
        var file = whole
        for i in 4 ..< file.count where random() < 10 { file[i] = random() }
        play(file)
    }
}
