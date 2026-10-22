// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaTrackers
@testable import SidayFoundation
import Testing

// Checks of the unpackers for ProPacker, Pha Packer, ProRunner, Tracker Packer 3 and Game Music
// Creator. Each test packs a small song as the packer would, here, and unpacks it again into the
// ProTracker module it is to be. The thorough check is made outside the package, against ProWizard
// itself on the packed modules of a collection: each is to be unpacked into the very same bytes.

private func be16(_ value: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

private func be32(_ value: Int) -> [UInt8] {
    be16(value >> 16) + be16(value)
}

private func zeros(_ count: Int) -> [UInt8] {
    [UInt8](repeating: 0, count: count)
}

/// A note as ProTracker has it: the instrument, the note's number in ProTracker's table (nought for
/// none), the command and its parameter.
private struct Note: Equatable {
    var instrument = 0
    var note = 0
    var command = 0
    var parameter = 0

    var isEmpty: Bool { self == Note() }

    /// ProTracker's four bytes.
    var bytes: [UInt8] {
        let period = ProWizard.notes[note]
        return [UInt8(instrument & 0xF0) | period.0, period.1, UInt8((instrument & 0x0F) << 4 | command), UInt8(parameter)]
    }
}

/// A pattern: the notes on its 64 lines of four voices, line after line.
private struct Pattern {
    var notes = [Note](repeating: Note(), count: 256)

    init(_ placed: [(line: Int, voice: Int, note: Note)]) {
        for (line, voice, note) in placed {
            notes[line * 4 + voice] = note
        }
    }

    /// The notes of a voice, from the first line to the last.
    func track(_ voice: Int) -> [Note] {
        (0 ..< 64).map { notes[$0 * 4 + voice] }
    }

    var bytes: [UInt8] { notes.flatMap(\.bytes) }
}

/// A sample: its length, finetune, volume and loop, the lengths in words, and the sound in it.
private struct Sample {
    var words: Int
    var finetune = 0
    var volume = 64
    var loopStart = 0
    var loopWords = 1

    var header: [UInt8] {
        be16(words) + [UInt8(finetune), UInt8(volume)] + be16(loopStart) + be16(loopWords)
    }

    /// A square wave, different for each sample.
    func sound(_ seed: Int) -> [UInt8] {
        (0 ..< words * 2).map { UInt8(truncatingIfNeeded: ($0 / 8 % 2 == 0 ? 0x40 : 0xC0) + seed) }
    }
}

private func sounds(_ samples: [Sample]) -> [UInt8] {
    samples.enumerated().flatMap { $0.element.sound($0.offset) }
}

/// The song packed: two samples and two patterns, with notes of instruments up to 17 and commands of
/// most kinds.
private let samples = [Sample(words: 512, volume: 64), Sample(words: 32, finetune: 3, volume: 40, loopStart: 8, loopWords: 16)]
private let patterns = [
    Pattern([
        (0, 0, Note(instrument: 1, note: 13, command: 0xC, parameter: 0x20)),
        (0, 1, Note(instrument: 2, note: 25)),
        (4, 1, Note(instrument: 2, note: 20, command: 0xF, parameter: 0x06)),
        (8, 2, Note(instrument: 17, note: 1, command: 0xA, parameter: 0x02)),
        (9, 2, Note(command: 0xA, parameter: 0x30)),
        (10, 2, Note(command: 0x0, parameter: 0x37)),
        (16, 3, Note(instrument: 1, note: 36, command: 0xE, parameter: 0x01)),
        (17, 3, Note(instrument: 1, note: 36, command: 0xE, parameter: 0x01)),
        (32, 0, Note(command: 0xD, parameter: 0x00)),
    ]),
    Pattern([
        (0, 1, Note(instrument: 1, note: 13)),
        (0, 2, Note(instrument: 2, note: 25, command: 0x3, parameter: 0x10)),
        (1, 2, Note(instrument: 2, note: 25, command: 0x3, parameter: 0x10)),
        (2, 2, Note(instrument: 2, note: 25, command: 0x3, parameter: 0x10)),
        (63, 3, Note(instrument: 1, note: 1, command: 0xB, parameter: 0x00)),
    ]),
]

/// The ProTracker module a packed song is to be unpacked into.
private func proTracker(title: [UInt8] = zeros(20), headers: [[UInt8]], length: Int, restart: UInt8 = 0x7F, order: [Int], patterns: [Pattern], sound: [UInt8]) -> [UInt8] {
    var module = title
    for header in headers {
        module += header
    }
    module += [UInt8(length), restart] + order.map { UInt8($0) } + zeros(128 - order.count)
    module += Array("M.K.".utf8)
    for pattern in patterns {
        module += pattern.bytes
    }
    return module + sound
}

/// ProTracker's header of a sample without a name; and of one that is not there, as each packer
/// writes it.
private func header(_ sample: Sample) -> [UInt8] { zeros(22) + sample.header }
private let noSample = zeros(30)
private let noSampleWithALoop = zeros(29) + [1]

/// Checks that a packed file is found to be the packer's, and is unpacked into the module.
private func expectUnpacked(_ file: [UInt8], _ packer: ProWizard.Packer, _ module: [UInt8]) {
    #expect(ProWizard.packer(of: file) == packer)
    let unpacked = ProWizard.unpack(file)
    #expect(unpacked?.packer == packer.name)
    #expect(unpacked?.module.count == module.count)
    #expect(unpacked?.module == module)
}

/// A file cut short anywhere, or changed here and there, does no harm.
private func expectNoHarm(_ file: [UInt8]) {
    let step = max(1, file.count / 300)
    for end in stride(from: 0, to: file.count, by: step) {
        _ = ProWizard.unpack(Array(file[..<end]))
    }
    var seed: UInt32 = 0x1234_5678
    func next() -> Int {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Int(seed >> 8)
    }
    for _ in 0 ..< 300 {
        var changed = file
        for _ in 0 ..< 1 + next() % 8 {
            changed[next() % changed.count] = UInt8(truncatingIfNeeded: next())
        }
        _ = ProWizard.unpack(changed)
    }
}

// MARK: ProPacker

/// The song as ProPacker packs it: tracks, each kept once, of places in a table of the notes.
private func proPacker(three: Bool, order: [Int]) -> [UInt8] {
    var file = [UInt8]()
    for sample in samples {
        file += sample.header
    }
    file += zeros(8 * (31 - samples.count))
    file += [UInt8(order.count), 0x7F]

    var table: [Note] = [Note()]
    var tracks: [[Int]] = []
    var trackOf = [[UInt8]](repeating: zeros(128), count: 4)
    for (place, pattern) in order.enumerated() {
        for voice in 0 ..< 4 {
            let track = patterns[pattern].track(voice).map { note in
                if let at = table.firstIndex(of: note) { return at }
                table.append(note)
                return table.count - 1
            }
            if let at = tracks.firstIndex(of: track) {
                trackOf[voice][place] = UInt8(at)
            } else {
                tracks.append(track)
                trackOf[voice][place] = UInt8(tracks.count - 1)
            }
        }
    }
    file += trackOf.flatMap { $0 }
    for track in tracks {
        for place in track {
            file += be16(three ? place * 4 : place)
        }
    }
    file += be32(table.count * 4)
    file += table.flatMap(\.bytes)
    return file + sounds(samples)
}

@Test func proPackerIsUnpacked() {
    // Each place in the order has a pattern of its own.
    let order = [0, 1, 0]
    let module = proTracker(headers: samples.map(header) + Array(repeating: noSample, count: 29), length: 3, order: [0, 1, 2],
                            patterns: order.map { patterns[$0] }, sound: sounds(samples))
    expectUnpacked(proPacker(three: false, order: order), .proPacker21, module)
    expectUnpacked(proPacker(three: true, order: order), .proPacker30, module)
}

@Test func proPackerDoesNoHarm() {
    expectNoHarm(proPacker(three: false, order: [0, 1, 0]))
    expectNoHarm(proPacker(three: true, order: [1, 0]))
    // A table that is said to be longer than the file, or to be of a length with the highest bit
    // set, which the test would not let through.
    var file = proPacker(three: false, order: [0, 1])
    let tableAt = 762 + (Int(file[250 ..< 762].max() ?? 0) + 1) * 64 * 2
    #expect(ProWizard.word(file, tableAt + 2) == (file.count - tableAt - 4 - sounds(samples).count))
    for length in [0x7FFF_FFF0, 0xFFFF_FFF0, 0] {
        file.replaceSubrange(tableAt ..< tableAt + 4, with: be32(length))
        var input = PackedReader(file)
        var output = ModuleWriter()
        #expect(throws: TuneError.self) { try ProPacker.depack21(&input, &output) }
    }
}

// MARK: Pha Packer

/// The song as Pha Packer packs it: the samples' headers, with where the sample is; the order, as
/// the places of the patterns; the samples; and the notes, a voice's last note told to be played
/// again for so many lines more.
private func phaPacker() -> [UInt8] {
    var file = [UInt8]()
    var at = 960
    for index in 0 ..< 31 {
        let sample = index < samples.count ? samples[index] : Sample(words: 0, volume: 0, loopWords: 0)
        // The finetune is kept less 11.
        let finetune = sample.finetune == 0 ? 0 : (sample.finetune - 11) & 0xFF
        file += be16(sample.words) + [0, UInt8(sample.volume)] + be16(sample.loopStart) + be16(sample.loopWords)
        file += be32(at) + [0, UInt8(finetune)]
        at += sample.words * 2
    }
    file += zeros(14)

    var notes = [UInt8]()
    var starts: [Int] = []
    for pattern in patterns {
        starts.append(notes.count)
        var skipping = [Int](repeating: 0, count: 4)
        for line in 0 ..< 64 {
            for voice in 0 ..< 4 {
                if skipping[voice] > 0 {
                    skipping[voice] -= 1
                    continue
                }
                let note = pattern.notes[line * 4 + voice]
                notes += [UInt8(note.instrument), UInt8(note.note * 2), UInt8(note.command), UInt8(note.parameter)]
                var same = 0
                while line + same + 1 < 64, pattern.notes[(line + same + 1) * 4 + voice] == note {
                    same += 1
                }
                if same > 0 {
                    notes += [0xFF, UInt8(0xFF - same)]
                    skipping[voice] = same
                }
            }
        }
    }
    let patternsAt = 960 + sounds(samples).count
    let order = [patternsAt + starts[0], patternsAt + starts[1]]
    for place in 0 ..< 128 {
        file += be32(place < order.count ? order[place] : order[0])
    }
    return file + sounds(samples) + notes
}

@Test func phaPackerIsUnpacked() {
    let headers = samples.map(header) + Array(repeating: noSample, count: 29)
    expectUnpacked(phaPacker(), .pha, proTracker(headers: headers, length: 2, order: [0, 1], patterns: patterns, sound: sounds(samples)))
}

@Test func phaPackerDoesNoHarm() {
    expectNoHarm(phaPacker())
}

// MARK: ProRunner

/// The song as ProRunner 1.0 packs it: a ProTracker module with "SNT.", each note its instrument, its
/// number in ProTracker's table, the command and its parameter.
private func proRunner1(_ headers: [[UInt8]], _ title: [UInt8]) -> [UInt8] {
    var file = title + headers.flatMap { $0 } + [3, 0x7F, 0, 1, 0] + zeros(125) + Array("SNT.".utf8)
    for pattern in patterns {
        for note in pattern.notes {
            file += [UInt8(note.instrument), UInt8(note.note), UInt8(note.command), UInt8(note.parameter)]
        }
    }
    return file + sounds(samples)
}

/// The song as ProRunner 2.0 packs it: "SNT!", the samples' headers without names, the order, and the
/// notes in three bytes, or one for nothing or for the voice's last note again.
private func proRunner2() -> [UInt8] {
    var file = Array("SNT!".utf8) + be32(0)
    for sample in samples {
        file += sample.header
    }
    file += zeros(8 * (31 - samples.count))
    file += [3, 0x7F, 0, 1, 0] + zeros(125)
    file += zeros(770 - file.count)
    var last = [Note](repeating: Note(), count: 4)
    for pattern in patterns {
        for (index, note) in pattern.notes.enumerated() {
            let voice = index & 3
            if note.isEmpty {
                file.append(0x80)
            } else if note == last[voice] {
                file.append(0xC0)
            } else {
                file += [UInt8(note.note << 1 | note.instrument & 0x01), UInt8((note.instrument & 0x1E) << 3 | note.command), UInt8(note.parameter)]
                last[voice] = note
            }
        }
    }
    return file + sounds(samples)
}

@Test func proRunnerIsUnpacked() {
    // Version 1.0 keeps the title and the samples' names.
    let title = Array("a song for a game".utf8) + zeros(3)
    let named = samples.enumerated().map { Array("sample \($0.offset + 1)".utf8) + zeros(14) + $0.element.header }
    let headers = named + Array(repeating: noSample, count: 29)
    expectUnpacked(proRunner1(headers, title), .proRunner1,
                   proTracker(title: title, headers: headers, length: 3, order: [0, 1, 0], patterns: patterns, sound: sounds(samples)))

    let module = proTracker(headers: samples.map(header) + Array(repeating: noSample, count: 29), length: 3, order: [0, 1, 0],
                            patterns: patterns, sound: sounds(samples))
    expectUnpacked(proRunner2(), .proRunner2, module)
}

@Test func proRunnerDoesNoHarm() {
    expectNoHarm(proRunner1(samples.map(header) + Array(repeating: noSample, count: 29), zeros(20)))
    expectNoHarm(proRunner2())
}

// MARK: Tracker Packer 3

/// A command's parameter as Tracker Packer keeps it: a volume slide's as a number with a sign.
private func trackerPackerParameter(_ note: Note) -> UInt8 {
    guard note.command == 0x5 || note.command == 0x6 || note.command == 0xA else { return UInt8(note.parameter) }
    return note.parameter & 0x0F != 0 ? UInt8(0x100 - note.parameter & 0x0F) : UInt8(note.parameter >> 4)
}

/// The song as Tracker Packer 3 packs it: "CPLX_TP3", the title, the samples' headers, the order,
/// where each pattern's tracks are, and the tracks, a line in as few bytes as it needs; the samples
/// on an even byte after them.
private func trackerPacker3(_ title: [UInt8]) -> [UInt8] {
    var file = Array("CPLX_TP3".utf8) + title + be16(samples.count * 8)
    for sample in samples {
        file += [UInt8(sample.finetune), UInt8(sample.volume)] + be16(sample.words) + be16(sample.loopStart) + be16(sample.loopWords)
    }
    file += [0, 3] + be16(0) + be16(8) + be16(0)

    var tracks: [[UInt8]] = []
    var places: [Int] = []
    var trackPlaces: [Int] = []
    var length = 0
    for pattern in patterns {
        for voice in 0 ..< 4 {
            let notes = pattern.track(voice)
            var track = [UInt8]()
            var line = 0
            while line < 64 {
                let note = notes[line]
                // A command of nought with a parameter is kept as 8, for nought is no command.
                let command = note.command == 0 && note.parameter != 0 ? 8 : note.command
                if note.isEmpty {
                    var run = 1
                    while line + run < 64, notes[line + run].isEmpty {
                        run += 1
                    }
                    track.append(UInt8(0x100 - run))
                    line += run
                    continue
                }
                if note.instrument == 0 && note.note == 0 {
                    track += [UInt8(0x80 | command << 1), trackerPackerParameter(note)]
                } else {
                    track.append(UInt8(note.instrument & 0x10 != 0 ? 0x7F - note.note : note.note))
                    track.append(UInt8((note.instrument & 0x0F) << 4 | command))
                    if command != 0 { track.append(trackerPackerParameter(note)) }
                }
                line += 1
            }
            if let at = tracks.firstIndex(of: track) {
                places.append(trackPlaces[at])
            } else {
                tracks.append(track)
                trackPlaces.append(length)
                places.append(length)
                length += track.count
            }
        }
    }
    for place in places {
        file += be16(place)
    }
    file += zeros(2)
    file += tracks.flatMap { $0 }
    if file.count & 1 != 0 { file.append(0) }
    return file + sounds(samples)
}

@Test func trackerPacker3IsUnpacked() {
    let title = Array("tracked and packed".utf8) + zeros(2)
    let file = trackerPacker3(title)
    let headers = samples.map(header) + Array(repeating: noSampleWithALoop, count: 29)
    expectUnpacked(file, .trackerPacker3, proTracker(title: title, headers: headers, length: 3, order: [0, 1, 0], patterns: patterns, sound: sounds(samples)))
}

@Test func trackerPacker3DoesNoHarm() {
    expectNoHarm(trackerPacker3(zeros(20)))
}

// MARK: Game Music Creator

/// A song of Game Music Creator's, with its commands as it numbers them.
private let gameMusicCreatorPatterns = [
    Pattern([
        (0, 0, Note(instrument: 1, note: 13, command: 3, parameter: 0x30)),
        (4, 1, Note(instrument: 2, note: 25, command: 8, parameter: 0x06)),
        (8, 2, Note(instrument: 1, note: 1, command: 1, parameter: 0x04)),
        (16, 3, Note(command: 6, parameter: 0x01)),
        (17, 3, Note(command: 7, parameter: 0x00)),
    ]),
    Pattern([
        (0, 0, Note(instrument: 2, note: 36, command: 5, parameter: 0x02)),
        (2, 1, Note(command: 4, parameter: 0x10)),
    ]),
]

/// The song as Game Music Creator writes it: fifteen samples, each with where it is and where its
/// loop is, the order as the places of the patterns, the patterns, and the samples.
private func gameMusicCreator() -> [UInt8] {
    let samples = [Sample(words: 512, volume: 64, loopWords: 0), Sample(words: 32, volume: 48, loopWords: 16)]
    var file = [UInt8]()
    for index in 0 ..< 15 {
        let sample = index < samples.count ? samples[index] : Sample(words: 0, volume: 0, loopWords: 0)
        file += be32(0) + be16(sample.words) + [0, UInt8(sample.volume)] + be32(0) + be16(sample.loopWords) + be16(0)
    }
    file += [0, 0, 0, 3] + be16(0) + be16(1024) + be16(0) + zeros(194)
    for pattern in gameMusicCreatorPatterns {
        file += pattern.bytes
    }
    return file + sounds(samples)
}

@Test func gameMusicCreatorIsUnpacked() {
    // A loop is at the end of its sample, and the commands are ProTracker's.
    let samples = [Sample(words: 512, volume: 64, loopStart: 0, loopWords: 1), Sample(words: 32, volume: 48, loopStart: 16, loopWords: 16)]
    let patterns = [
        Pattern([
            (0, 0, Note(instrument: 1, note: 13, command: 0xC, parameter: 0x30)),
            (4, 1, Note(instrument: 2, note: 25, command: 0xF, parameter: 0x06)),
            (8, 2, Note(instrument: 1, note: 1, command: 1, parameter: 0x04)),
            (16, 3, Note(command: 0xE, parameter: 0x01)),
            (17, 3, Note(command: 0xE, parameter: 0x00)),
        ]),
        Pattern([
            (0, 0, Note(instrument: 2, note: 36, command: 0xB, parameter: 0x02)),
            (2, 1, Note(command: 0xD, parameter: 0x10)),
        ]),
    ]
    let headers = samples.map(header) + Array(repeating: zeros(22) + be16(0) + [0, 0] + be16(0) + be16(1), count: 13)
        + Array(repeating: noSampleWithALoop, count: 16)
    expectUnpacked(gameMusicCreator(), .gameMusicCreator,
                   proTracker(headers: headers, length: 3, order: [0, 1, 0], patterns: patterns, sound: sounds(samples)))
}

@Test func gameMusicCreatorDoesNoHarm() {
    expectNoHarm(gameMusicCreator())
}

@Test func randomBytesAreNotTakenForPackedModules() {
    var seed: UInt32 = 0x9E37_79B9
    for round in 0 ..< 200 {
        var file = [UInt8](repeating: 0, count: 100 + round * 37)
        for index in file.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            file[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        _ = ProWizard.unpack(file)
    }
}
