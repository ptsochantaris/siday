// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaTrackers
import Testing

// Checks of the unpacking of NoisePacker's three versions, Novotrade's packer, AC1D's and Digital
// Illusions'. The thorough check is made outside the package, against ProWizard itself on the files
// of games: each is to unpack to the same bytes. Here each packer has a small file made as the packer
// made them, of two samples and two patterns, which is to unpack to the ProTracker module written out
// beside it; and files cut short, changed at random or made of random bytes are not to stop anything.

/// The files made for these tests, and the modules they are to unpack to.
enum ProWizardBSamples {
    static func be16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }

    static func be32(_ value: Int) -> [UInt8] { be16(value >> 16) + be16(value) }

    /// A sample, as ProTracker describes it: its length, and where its loop starts and how long it is,
    /// in words.
    struct Sample {
        var words: Int
        var fine: UInt8
        var volume: UInt8
        var loopStart: Int
        var loopWords: Int

        /// ProTracker's thirty bytes for it, without a name.
        var header: [UInt8] {
            [UInt8](repeating: 0, count: 22) + be16(words) + [fine, volume] + be16(loopStart) + be16(loopWords)
        }
    }

    /// The two samples of each file: one that does not loop and one that does.
    static let samples = [
        Sample(words: 16, fine: 0, volume: 64, loopStart: 0, loopWords: 1),
        Sample(words: 8, fine: 3, volume: 32, loopStart: 4, loopWords: 4),
    ]

    /// The sound of the two samples, one after the other.
    static let sound: [UInt8] = (0 ..< 48).map { UInt8(truncatingIfNeeded: $0 * 37 + 5) }

    /// ProTracker's four bytes for a note.
    static func cell(note: Int, sample: Int, effect: Int, value: Int) -> [UInt8] {
        let period = ProWizard.notes[note]
        return [UInt8(sample & 0xF0) | period.0, period.1, UInt8(sample << 4 & 0xF0 | effect), UInt8(value)]
    }

    /// A pattern of ProTracker's with these on it, at these lines and voices.
    static func pattern(_ cells: [(line: Int, voice: Int, cell: [UInt8])]) -> [UInt8] {
        var pattern = [UInt8](repeating: 0, count: 1024)
        for (line, voice, cell) in cells {
            pattern.replaceSubrange(line * 16 + voice * 4 ..< line * 16 + voice * 4 + 4, with: cell)
        }
        return pattern
    }

    /// A ProTracker module.
    static func module(title: [UInt8] = [UInt8](repeating: 0, count: 20), headers: [[UInt8]], length: UInt8, restart: UInt8,
                       order: [UInt8], patterns: [[UInt8]], sound: [UInt8]) -> [UInt8] {
        var module = title
        for header in headers { module += header }
        module += [length, restart] + order + [UInt8](repeating: 0, count: 128 - order.count)
        module += Array("M.K.".utf8)
        for pattern in patterns { module += pattern }
        return module + sound
    }

    /// NoisePacker's headers for the samples ProTracker does not have here, which NoisePacker leaves out.
    static let unused = [UInt8](repeating: 0, count: 29) + [1]

    // MARK: NoisePacker 1 and 2

    /// A track of NoisePacker's first two versions, of 64 lines of three bytes, with a few notes and
    /// effects: their bytes in the file, and in ProTracker's pattern for each line.
    static func noisePackerTrack(version: Int) -> (packed: [UInt8], cells: [(line: Int, cell: [UInt8])]) {
        var track = [UInt8](repeating: 0, count: 192)
        var cells: [(line: Int, cell: [UInt8])] = []
        func put(_ line: Int, _ bytes: [UInt8], _ cell: [UInt8]) {
            track.replaceSubrange(line * 3 ..< line * 3 + 3, with: bytes)
            cells.append((line, cell))
        }
        // A note (twice its number) with its sample and a volume.
        put(0, [26, 0x1C, 0x40], cell(note: 13, sample: 1, effect: 0x0C, value: 0x40))
        // A slide of the volume down with a note held, which ProTracker calls A; NoisePacker calls it 7.
        put(4, [50, 0x27, 0xFE], cell(note: 25, sample: 2, effect: 0x0A, value: 0x02))
        // A slide of the volume up, with a vibrato held.
        put(8, [0, 0x06, 0x03], cell(note: 0, sample: 0, effect: 0x06, value: 0x30))
        // A jump, whose place NoisePacker keeps doubled less four.
        put(12, [2, 0x1B, 0x06], cell(note: 1, sample: 1, effect: 0x0B, value: 0x05))
        // An extended effect, whose value the second version keeps one more.
        put(16, [0, 0x0E, 0x01], cell(note: 0, sample: 0, effect: 0x0E, value: version == 2 ? 0x00 : 0x01))
        // An effect of 8, which ProTracker does not have, is left out.
        put(20, [72, 0x28, 0x00], cell(note: 36, sample: 2, effect: 0, value: 0))
        // A slide of the volume down.
        put(28, [0, 0x05, 0xFD], cell(note: 0, sample: 0, effect: 0x05, value: 0x03))
        put(63, [0, 0x0D, 0x00], cell(note: 0, sample: 0, effect: 0x0D, value: 0))
        return (track, cells)
    }

    /// A file of NoisePacker 1's or 2's, and the module it is to unpack to: two patterns, the first
    /// with the track of notes on its first voice, the second on its second, and an empty track on
    /// the others.
    static func noisePacker(version: Int) -> (file: [UInt8], module: [UInt8]) {
        let (track, cells) = noisePackerTrack(version: version)
        var file: [UInt8] = [0x00, 0x2C] + be16(4) + be16(0) + be16(384)
        for sample in samples {
            file += be32(0) + be16(sample.words) + [sample.fine, sample.volume] + be32(0) + be16(sample.loopWords)
            // (The first version keeps where the loop starts in bytes.)
            file += be16(version == 1 ? sample.loopStart * 2 : sample.loopStart)
        }
        file += be16(2) + be16(0)
        file += be16(0) + be16(8) // the order: patterns 0 and 1
        // Where each pattern's tracks begin, the last voice's first: the track of notes at nought, the
        // empty one after it.
        file += be16(192) + be16(192) + be16(192) + be16(0)
        file += be16(192) + be16(192) + be16(0) + be16(192)
        file += track + [UInt8](repeating: 0, count: 192) + sound

        let module = module(headers: samples.map(\.header) + Array(repeating: unused, count: 29), length: 2, restart: 0x7F,
                            order: [0, 1], patterns: [pattern(cells.map { ($0.line, 0, $0.cell) }), pattern(cells.map { ($0.line, 1, $0.cell) })],
                            sound: sound)
        return (file, module)
    }

    // MARK: NoisePacker 3

    /// A file of NoisePacker 3's, and the module it is to unpack to. Its tracks leave out runs of
    /// empty lines, and one ends at a jump to the next pattern: the first pattern has a track of a few
    /// notes on its first voice; the second has it on its second voice, and a track of many notes on
    /// its third; the rest are a track that is one run of 64 empty lines.
    static func noisePacker3() -> (file: [UInt8], module: [UInt8]) {
        var few: [UInt8] = []
        var fewCells: [(line: Int, cell: [UInt8])] = []
        few += [26, 0x1C, 0x20]
        fewCells.append((0, cell(note: 13, sample: 1, effect: 0x0C, value: 0x20)))
        few += [0xFD] // three empty lines
        // An extended effect, whose value NoisePacker 3's unpacking always makes 1.
        few += [50, 0x2E, 0x05]
        fewCells.append((4, cell(note: 25, sample: 2, effect: 0x0E, value: 0x01)))
        few += [0, 0x15, 0x02]
        fewCells.append((5, cell(note: 0, sample: 1, effect: 0x05, value: 0x20)))
        few += [0xF6] // ten empty lines
        few += [0, 0x1B, 0x02]
        fewCells.append((16, cell(note: 0, sample: 1, effect: 0x0B, value: 0x03)))
        // The jump to the next pattern, after which the track ends.
        few += [2, 0x1D, 0x00]
        fewCells.append((17, cell(note: 1, sample: 1, effect: 0x0D, value: 0)))

        var many: [UInt8] = []
        var manyCells: [(line: Int, cell: [UInt8])] = []
        for line in 0 ..< 21 {
            let note = line % 36 + 1, sample = 1 + line % 2
            many += [UInt8(note * 2), UInt8(sample << 4)]
            many += [0]
            manyCells.append((line, cell(note: note, sample: sample, effect: 0, value: 0)))
        }
        many += [0xD5] // the other 43 lines empty

        let empty: [UInt8] = [0xC0]
        let tracks = few + empty + many // 17, 1 and 64 bytes
        var file: [UInt8] = [0x00, 0x2C] + be16(4) + be16(0) + be16(tracks.count)
        for sample in samples {
            file += [sample.fine, sample.volume] + be32(0) + be16(sample.words) + be32(0) + be16(sample.loopWords) + be16(sample.loopStart)
        }
        file += be16(2) + be16(0)
        file += be16(0) + be16(8)
        file += be16(17) + be16(17) + be16(17) + be16(0)
        file += be16(17) + be16(18) + be16(0) + be16(17)
        file += tracks + sound

        let second = fewCells.map { ($0.line, 1, $0.cell) } + manyCells.map { ($0.line, 2, $0.cell) }
        let module = module(headers: samples.map(\.header) + Array(repeating: unused, count: 29), length: 2, restart: 0x7F,
                            order: [0, 1], patterns: [pattern(fewCells.map { ($0.line, 0, $0.cell) }), pattern(second)], sound: sound)
        return (file, module)
    }

    // MARK: Novotrade

    /// A file of Novotrade's packer, and the module it is to unpack to. Its samples are given with
    /// their numbers, the second as ProTracker's fourth, and a third with a number ProTracker does
    /// not have is passed over. Its lines say which voices have something.
    static func novotrade() -> (file: [UInt8], module: [UInt8]) {
        let title = Array("novotrade test!!".utf8)
        let rows: [(line: Int, voices: Int, cells: [[UInt8]])] = [
            (0, 0b1001, [cell(note: 13, sample: 1, effect: 0x0C, value: 0x20), cell(note: 25, sample: 4, effect: 0, value: 0)]),
            (10, 0b0110, [cell(note: 1, sample: 1, effect: 0x0F, value: 6), cell(note: 0, sample: 0, effect: 0x0A, value: 0x10)]),
            (63, 0b0001, [cell(note: 0, sample: 0, effect: 0x0D, value: 0)]),
        ]
        func packed(_ shift: Int) -> [UInt8] {
            var bytes: [UInt8] = []
            for line in 0 ..< 64 {
                guard let row = rows.first(where: { ($0.line + shift) % 64 == line }) else {
                    bytes += be16(0)
                    continue
                }
                bytes += be16(row.voices)
                for cell in row.cells { bytes += cell }
            }
            return bytes
        }
        func unpacked(_ shift: Int) -> [UInt8] {
            var cells: [(line: Int, voice: Int, cell: [UInt8])] = []
            for row in rows {
                var next = 0
                for voice in 0 ..< 4 where row.voices & 1 << voice != 0 {
                    cells.append(((row.line + shift) % 64, voice, row.cells[next]))
                    next += 1
                }
            }
            return pattern(cells)
        }
        let first = packed(0), second = packed(5)

        let instruments: [UInt8] = [0, 64] + be16(16) + be16(0) + be16(1) + [3, 32] + be16(8) + be16(4) + be16(4) + [31, 9, 9, 9, 9, 9, 9, 9]
        let order = be16(0) + be16(1)
        let starts = be16(0) + be16(first.count)
        let body = 30 + instruments.count + order.count + starts.count
        let samplesAt = body + 4 + first.count + second.count
        var file = Array("MODU".utf8) + title + be16(body - 4) + be16(3) + be16(2) + be16(2) + be16(samplesAt - body - 4)
        file += instruments + order + starts + Array("BODY".utf8) + first + second
        // The samples, read (as ProWizard reads them) from the mark "SAMP" on.
        let stored = Array("SAMP".utf8) + sound
        file += stored

        var headers = Array(repeating: [UInt8](repeating: 0, count: 30), count: 31)
        headers[0] = Sample(words: 16, fine: 0, volume: 64, loopStart: 0, loopWords: 1).header
        headers[3] = Sample(words: 8, fine: 0, volume: 32, loopStart: 4, loopWords: 4).header
        let module = module(title: title + [0, 0, 0, 0], headers: headers, length: 2, restart: 0x7F, order: [0, 1],
                            patterns: [unpacked(0), unpacked(5)], sound: Array(stored[0 ..< 48]))
        return (file, module)
    }

    // MARK: AC1D

    /// A track of AC1D's, with runs of empty lines and a note without an effect's value, and the
    /// notes in ProTracker's pattern; and a track that is one run of 64 empty lines.
    static let ac1dTrack: (packed: [UInt8], cells: [(line: Int, cell: [UInt8])]) = (
        [24, 0x1C, 0x30, 0x83, 0x3F, 0x27, 0x4C, 0x1F, 0x06, 0x00, 0x00, 0x00, 0xB9],
        [
            (0, cell(note: 13, sample: 1, effect: 0x0C, value: 0x30)),
            // No note, and an effect of 7 kept in two bytes, which is left out.
            (4, cell(note: 0, sample: 2, effect: 0, value: 0)),
            // ProTracker's seventeenth sample.
            (5, cell(note: 1, sample: 17, effect: 0x0F, value: 0x06)),
            // A note of nought, which ProWizard makes the first note.
            (6, cell(note: 1, sample: 0, effect: 0, value: 0)),
        ]
    )

    /// A file of AC1D's, and the module it is to unpack to: two patterns, the track of notes on the
    /// first voice of the first and the third of the second.
    static func ac1d() -> (file: [UInt8], module: [UInt8]) {
        let empty: [UInt8] = [0xC0]
        let sizes = [UInt8](repeating: 0, count: 12)
        let first = sizes + ac1dTrack.packed + empty + empty + empty
        let second = sizes + empty + empty + ac1dTrack.packed + empty
        let samplesAt = 896 + first.count + second.count
        var file: [UInt8] = [2, 0x7F, 0xAC, 0x1D] + be32(samplesAt)
        for sample in samples { file += be16(sample.words) + [sample.fine, sample.volume] + be16(sample.loopStart) + be16(sample.loopWords) }
        file += [UInt8](repeating: 0, count: 29 * 8)
        // Where the patterns are, then one more (not a pattern), then nought.
        file += be32(896) + be32(896 + first.count) + be32(samplesAt)
        file += [UInt8](repeating: 0, count: 768 - file.count)
        file += [0, 1] + [UInt8](repeating: 0, count: 126)
        file += first + second + sound

        let module = module(headers: samples.map(\.header) + Array(repeating: [UInt8](repeating: 0, count: 30), count: 29), length: 2,
                            restart: 0x7F, order: [0, 1],
                            patterns: [pattern(ac1dTrack.cells.map { ($0.line, 0, $0.cell) }), pattern(ac1dTrack.cells.map { ($0.line, 2, $0.cell) })],
                            sound: sound)
        return (file, module)
    }

    // MARK: Digital Illusions

    /// A note as Digital Illusions keeps it: in two bytes without an effect's value, or three with.
    static func di(note: Int, sample: Int, effect: Int, value: Int?) -> [UInt8] {
        let first = UInt8(sample << 2 | note >> 4), second = UInt8((note & 0x0F) << 4 | effect)
        guard let value else { return [first, second] }
        return [0x80 | first, second, UInt8(value)]
    }

    /// A file of Digital Illusions', and the module it is to unpack to.
    static func digitalIllusions() -> (file: [UInt8], module: [UInt8]) {
        // Each pattern's lines, all four voices of each in turn; $FF is a voice with nothing.
        var first: [UInt8] = []
        first += di(note: 13, sample: 1, effect: 0x0C, value: 0x20) + di(note: 25, sample: 2, effect: 0, value: nil) + [0xFF, 0xFF]
        // A note higher than ProTracker's, which is left out.
        first += di(note: 37, sample: 1, effect: 0, value: nil) + [0xFF, 0xFF, 0xFF]
        first += [0xFF, 0xFF, 0xFF] + di(note: 1, sample: 17, effect: 0x0F, value: 6)
        first += [UInt8](repeating: 0xFF, count: 61 * 4)
        let second = [UInt8](repeating: 0xFF, count: 63 * 4 + 2) + di(note: 0, sample: 0, effect: 0x0D, value: 0) + [0xFF]

        let order: [UInt8] = [0, 1, 0xFF]
        let orderAt = 14 + 2 * 8 + 4
        let patternsAt = orderAt + order.count
        let samplesAt = patternsAt + first.count + second.count
        var file = be16(2) + be32(orderAt) + be32(patternsAt) + be32(samplesAt)
        for sample in samples { file += be16(sample.words) + [sample.fine, sample.volume] + be16(sample.loopStart) + be16(sample.loopWords) }
        file += be16(patternsAt) + be16(patternsAt + first.count)
        file += order + first + second + sound

        let firstCells = [
            (0, 0, cell(note: 13, sample: 1, effect: 0x0C, value: 0x20)), (0, 1, cell(note: 25, sample: 2, effect: 0, value: 0)),
            (2, 3, cell(note: 1, sample: 17, effect: 0x0F, value: 6)),
        ]
        let module = module(headers: samples.map(\.header) + Array(repeating: [UInt8](repeating: 0, count: 30), count: 29), length: 2,
                            restart: 0x7F, order: [0, 1],
                            patterns: [pattern(firstCells), pattern([(63, 2, cell(note: 0, sample: 0, effect: 0x0D, value: 0))])], sound: sound)
        return (file, module)
    }

    /// Each packer's file, and the module it is to unpack to.
    static var all: [(packer: ProWizard.Packer, file: [UInt8], module: [UInt8])] {
        [
            (.noisePacker1, noisePacker(version: 1).file, noisePacker(version: 1).module),
            (.noisePacker2, noisePacker(version: 2).file, noisePacker(version: 2).module),
            (.noisePacker3, noisePacker3().file, noisePacker3().module),
            (.novotrade, novotrade().file, novotrade().module),
            (.ac1d, ac1d().file, ac1d().module),
            (.digitalIllusions, digitalIllusions().file, digitalIllusions().module),
        ]
    }

    /// The packers of these tests.
    static let packers: [ProWizard.Packer] = [.noisePacker1, .noisePacker2, .noisePacker3, .novotrade, .ac1d, .digitalIllusions]
}

/// The same random bytes every time.
private struct Shuffle: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ z >> 30) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ z >> 27) &* 0x94D0_49BB_1331_11EB
        return z ^ z >> 31
    }
}

/// Asks each packer of these tests whether a file is its, and has each unpack it whatever they say.
private func tryEveryPacker(_ data: [UInt8]) {
    for packer in ProWizardBSamples.packers {
        _ = packer.test(data, data.count)
        var input = PackedReader(data)
        var output = ModuleWriter()
        try? packer.depack(&input, &output)
    }
}

@Test(arguments: ProWizardBSamples.all.indices)
func proWizardGroupBUnpacksAsProTrackerModule(_ index: Int) throws {
    let (packer, file, module) = ProWizardBSamples.all[index]
    #expect(ProWizard.packer(of: file) == packer)
    let (name, unpacked) = try #require(ProWizard.unpack(file))
    #expect(name == packer.name)
    #expect(unpacked.count == module.count)
    #expect(unpacked == module)
    // (Where they first differ, for when they do.)
    if let at = (0 ..< min(unpacked.count, module.count)).first(where: { unpacked[$0] != module[$0] }) { Issue.record("first difference at \(at)") }
}

@Test func proWizardGroupBUnpackedModulesPlay() throws {
    for (packer, file, _) in ProWizardBSamples.all {
        let renderer = try TuneLoader.load(file, format: .mod)
        #expect(renderer.info.detail == "packed by \(packer.name)")
        var buffer = [Float](repeating: 0, count: 2 * 4410)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4410) }
        #expect(buffer.allSatisfy { $0.isFinite })
    }
}

@Test func proWizardGroupBFilesCutShortOrChangedDoNotTrap() {
    var random = Shuffle(state: 0x51DA_7B)
    for (_, file, _) in ProWizardBSamples.all {
        for end in 0 ..< file.count {
            let cut = Array(file[0 ..< end])
            _ = ProWizard.unpack(cut)
            tryEveryPacker(cut)
        }
        for _ in 0 ..< 300 {
            var changed = file
            for _ in 0 ..< Int.random(in: 1 ... 8, using: &random) {
                changed[Int.random(in: 0 ..< changed.count, using: &random)] = UInt8.random(in: 0 ... 255, using: &random)
            }
            _ = ProWizard.unpack(changed)
            tryEveryPacker(changed)
        }
    }
}

@Test func proWizardGroupBRandomBytesDoNotTrap() {
    var random = Shuffle(state: 0xAC1D)
    for _ in 0 ..< 3000 {
        let count = Int.random(in: 0 ... 1200, using: &random)
        var data = (0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &random) }
        // Some made to look more like the packers' files, to get further into their tests.
        if count > 4, Bool.random(using: &random) {
            switch Int.random(in: 0 ..< 4, using: &random) {
            case 0: data[1] = data[1] & 0xF0 | 0x0C
            case 1: data.replaceSubrange(0 ..< 4, with: Array("MODU".utf8))
            case 2: data[2] = 0xAC; data[3] = 0x1D
            default: data[0] = 0; data[1] &= 0x1F
            }
        }
        _ = ProWizard.unpack(data)
        tryEveryPacker(data)
    }
}
