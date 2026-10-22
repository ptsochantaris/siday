// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaTrackers
@testable import SidayFoundation
import Testing

// Fast checks of the reading of ChipTracker's modules. The thorough check is made outside the package,
// against ChipTracker's own replayer in Wanted Team's player for EaglePlayer, run by UADE: the first
// minute of each of the 41 files in UnExoticA's collection, by how loud each side is from moment to
// moment.

/// A note on a track: its place in ChipTracker's table (nil for none), its sample, command and value.
private typealias Event = (note: Int?, sample: Int, command: Int, value: Int)

/// A ChipTracker module: the tracks, the song's places (each four tracks and how far each is moved),
/// and one sample of eight bytes, its loop beginning at byte 4.
private func chipTracker(tracks: [[Int: Event]], places: [[(track: Int, move: Int)]], restart: Int = 0) -> [UInt8] {
    var file = Array("A ChipTracker song".utf8) + [UInt8](repeating: 0, count: 2) + [0, 0]
    for sample in 0 ..< 31 {
        var header = [UInt8](repeating: 0, count: 30)
        if sample == 0 {
            header[0 ..< 6] = [0x6C, 0x65, 0x61, 0x64, 0x20, 0x31] // "lead 1"
            header[23] = 4 // eight bytes
            header[24] = 5 // a finetune, which is not used
            header[25] = 48
            header[27] = 4 // the loop begins 4 bytes in
            header[29] = 2 // and is four bytes long
        } else {
            header[29] = 1
        }
        file += header
    }
    file += Array("KRIS".utf8) + [UInt8(places.count), UInt8(restart)]
    var list = [UInt8](repeating: 0, count: 1024)
    for (place, four) in places.enumerated() {
        for (voice, entry) in four.enumerated() {
            list[(place * 4 + voice) * 2] = UInt8(entry.track)
            list[(place * 4 + voice) * 2 + 1] = UInt8(bitPattern: Int8(entry.move))
        }
    }
    file += list + [0, 0]
    for track in tracks {
        for row in 0 ..< 64 {
            let event = track[row]
            file += [UInt8(event.flatMap { $0.note.map { $0 * 2 } } ?? 0xA8), UInt8(event?.sample ?? 0),
                     UInt8(event?.command ?? 0), UInt8(event?.value ?? 0)]
        }
    }
    return file + [0, 10, 20, 30, 40, 50, 60, 70]
}

/// The four bytes of a row's note on a voice, in a ProTracker module's pattern.
private func cell(_ module: [UInt8], pattern: Int, row: Int, voice: Int) -> [UInt8] {
    let at = 1084 + pattern * 1024 + (row * 4 + voice) * 4
    return Array(module[at ..< at + 4])
}

@Test func chipTrackerModuleIsReadIntoAProTrackerOne() throws {
    let file = chipTracker(
        tracks: [[0: (36, 1, 0x0C, 40), 4: (60, 1, 0x03, 8)], [2: (40, 1, 0x00, 0x37), 63: (nil, 0, 0x0F, 3)]],
        places: [[(0, 0), (1, 0), (0, 0), (1, 0)], [(0, 2), (1, -12), (0, 0), (1, 0)], [(0, 0), (1, 0), (0, 0), (1, 0)]],
        restart: 1)
    #expect(ChipTrackerFile.isOne(file))
    let module = try ChipTrackerFile.module(file)
    #expect(Array(module[0 ..< 18]) == Array("A ChipTracker song".utf8))
    // The sample as ProTracker has it: no finetune, and its loop begun in words, not bytes.
    #expect(Array(module[20 ..< 26]) == Array("lead 1".utf8))
    #expect(Array(module[42 ..< 50]) == [0, 4, 0, 48, 0, 2, 0, 2])
    // The song: three places, the third the same as the first, and so sharing its pattern.
    #expect(module[950] == 3 && module[951] == 1)
    #expect(Array(module[952 ..< 956]) == [0, 1, 0, 0])
    #expect(Array(module[1080 ..< 1084]) == Array("M.K.".utf8))
    #expect(module.count == 1084 + 2 * 1024 + 8)
    #expect(Array(module.suffix(8)) == [0, 10, 20, 30, 40, 50, 60, 70])

    // Notes by ChipTracker's table: its 36th is ProTracker's C of 856, its 40th 678, its 60th 214.
    #expect(cell(module, pattern: 0, row: 0, voice: 0) == [0x03, 0x58, 0x1C, 40])
    #expect(cell(module, pattern: 0, row: 4, voice: 2) == [0x00, 0xD6, 0x13, 8])
    #expect(cell(module, pattern: 0, row: 2, voice: 1) == [0x02, 0xA6, 0x10, 0x37])
    #expect(cell(module, pattern: 0, row: 63, voice: 3) == [0, 0, 0x0F, 3])
    #expect(cell(module, pattern: 0, row: 1, voice: 0) == [0, 0, 0, 0])
    // Moved up two semitones, and down an octave, below ProTracker's lowest.
    #expect(cell(module, pattern: 1, row: 0, voice: 0) == [0x02, 0xFA, 0x1C, 40])
    #expect(cell(module, pattern: 1, row: 2, voice: 1) == [0x05, 0x4C, 0x10, 0x37])

    // And it is played as a module, said to be ChipTracker's.
    let renderer = try TuneLoader.load(file, format: .mod)
    #expect(renderer.info.format == "MOD" && renderer.info.detail == "ChipTracker")
    var buffer = [Float](repeating: 0, count: 9600)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
    #expect(buffer.contains { $0 != 0 })
}

@Test func chipTrackerNoteMovedOffTheTableIsNoNote() throws {
    let file = chipTracker(tracks: [[0: (70, 1, 0, 0)]], places: [[(0, 5), (0, -71), (0, 0), (0, 0)]])
    let module = try ChipTrackerFile.module(file)
    #expect(cell(module, pattern: 0, row: 0, voice: 0) == [0, 0, 0x10, 0])
    #expect(cell(module, pattern: 0, row: 0, voice: 1) == [0, 0, 0x10, 0])
    #expect(cell(module, pattern: 0, row: 0, voice: 2) == [0, 0x78, 0x10, 0])
}

@Test func chipTrackerModuleCutShortOrNonsenseDoesNotTrap() throws {
    let file = chipTracker(tracks: [[0: (36, 1, 0, 0)], [:]], places: [[(0, 0), (1, 0), (0, 0), (1, 0)]])
    for length in stride(from: 0, through: file.count, by: 37) {
        _ = try? ChipTrackerFile.module(Array(file.prefix(length)))
        _ = try? TuneLoader.load(Array(file.prefix(length)), format: .mod)
    }
    // A song of no places, or of more than there is room for.
    var empty = file
    empty[956] = 0
    #expect(throws: TuneError.self) { try ChipTrackerFile.module(empty) }
    var long = file
    long[956] = 200
    #expect(throws: TuneError.self) { try ChipTrackerFile.module(long) }
    // Tracks said to be there that the file has no room for.
    var far = file
    far[958] = 250
    #expect(throws: TuneError.self) { try ChipTrackerFile.module(far) }
}
