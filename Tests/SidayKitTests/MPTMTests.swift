// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the MPTM files that Impulse Tracker's replayer plays. The thorough checks are made
// outside the package, against libopenmpt: what is read from every file is set beside what it reads,
// where the tune is on every tick and how long the tick lasts beside where it is, and what is heard
// beside what it plays.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count)) }
private func text(_ string: String) -> [UInt8] { Array(string.utf8) }

/// A number as OpenMPT writes one in as few of 1, 2, 4 or 8 bytes as hold it, or in as many as it is told to.
private func adaptive(_ value: Int, bytes: Int? = nil) -> [UInt8] {
    let size = bytes ?? (value < 1 << 6 ? 1 : value < 1 << 14 ? 2 : value < 1 << 30 ? 4 : 8)
    let whole = UInt64(value) << 2 | UInt64([1: 0, 2: 1, 4: 2, 8: 3][size]!)
    return (0 ..< size).map { UInt8(truncatingIfNeeded: whole >> UInt64($0 * 8)) }
}

/// OpenMPT's way of putting named things one after another: a heading, the things, and a list of
/// where each is and what it is called.
private func chunk(_ name: String, _ items: [(name: [UInt8], data: [UInt8])]) -> [UInt8] {
    var head = text("228") + [UInt8(name.utf8.count)] + text(name) + [0x1F, 2 << 2, 0, 1] + adaptive(0x0130_0000) + [1]
    head += adaptive(items.count, bytes: 2)
    let start = head.count + 8
    var data: [UInt8] = [], map: [UInt8] = []
    for item in items {
        map += [UInt8(item.name.count << 1)] + item.name + adaptive(start + data.count) + adaptive(item.data.count)
        data += item.data
    }
    return head + adaptive(start + data.count, bytes: 8) + data + map
}

/// One channel's part of a row: a note, an instrument, the volume column and a command, each or none.
private struct Cell {
    var note: UInt8?, instrument: UInt8?, volume: UInt8?
    var command: Character?, value: UInt8 = 0

    static func note(_ note: UInt8 = 60, instrument: UInt8 = 1, volume: UInt8? = nil, _ command: Character? = nil, _ value: UInt8 = 0) -> Cell {
        Cell(note: note, instrument: instrument, volume: volume, command: command, value: value)
    }

    static func command(_ command: Character, _ value: UInt8) -> Cell {
        Cell(command: command, value: value)
    }
}

/// The number an MPTM file gives a command: Impulse Tracker's letters from A as 1, and after them
/// OpenMPT's own, of which # is 27, \ is 28 and : is 29.
private func commandNumber(_ command: Character) -> UInt8 {
    switch command {
    case "#": 27
    case "\\": 28
    case ":": 29
    default: command.asciiValue! - 64
    }
}

private struct Pattern {
    var rows = 16
    var cells: [(row: Int, channel: Int, cell: Cell)] = []

    init(rows: Int = 16, _ cells: [(row: Int, channel: Int, cell: Cell)]) {
        self.rows = rows
        self.cells = cells
    }

    var packed: [UInt8] {
        var bytes: [UInt8] = []
        for row in 0 ..< rows {
            for (_, channel, cell) in cells.filter({ $0.row == row }).sorted(by: { $0.channel < $1.channel }) {
                let mask: UInt8 = (cell.note != nil ? 1 : 0) | (cell.instrument != nil ? 2 : 0) | (cell.volume != nil ? 4 : 0) | (cell.command != nil ? 8 : 0)
                bytes += [UInt8(channel + 1) | 0x80, mask]
                if let note = cell.note { bytes.append(note) }
                if let instrument = cell.instrument { bytes.append(instrument) }
                if let volume = cell.volume { bytes.append(volume) }
                if let command = cell.command { bytes += [commandNumber(command), cell.value] }
            }
            bytes.append(0)
        }
        return bytes
    }
}

/// A square wave of 32 samples; and one of 4000 that grows from nothing to its loudest, so that
/// it does not sound the same backwards, and ends in silence, so that its ending leaves nothing behind.
private let square: [UInt8] = (0 ..< 32).map { $0 < 16 ? 0x7F : 0x81 }
private let swell: [UInt8] = (0 ..< 4000).map { (index: Int) -> UInt8 in
    if index >= 3984 { return 0 }
    let height = index * 127 / 3999
    return UInt8(bitPattern: Int8(index % 32 < 16 ? height : -height))
}

private enum Sample {
    case sound([UInt8], loops: Bool)
    /// A patch for the AdLib's FM chip.
    case fm
    /// A sample kept in a file of its own.
    case elsewhere
}

private struct Song {
    var mode = 0
    var tempo = 125, fraction = 0, speed = 6
    var rowsPerBeat = 4
    var swing: [Int] = []
    var restart: Int?
    var mixLevels = 4
    /// OpenMPT's ways of playing that the file asks for, by their numbers.
    var behaviours: [Int] = [0] + Array(8 ... 48) + [50]
    var version = 0x0130_0000
}

/// An MPTM file: an IT file's header, instruments, samples and patterns, and after them the song's
/// "extended properties" and OpenMPT's own last part, with the place of that part in the last four bytes.
/// - Parameters:
///   - sequences: the file's lists of patterns, each with a place to start again, a speed and a
///     tempo in ten-thousandths; one list of every pattern in order if none is given.
///   - instruments: for each instrument the sample its notes play; none for a file of samples alone.
///   - instrumentExtras: the instruments' "extended properties": a name, a size and the bytes for each.
///   - patternExtras: a pattern's own rows to a beat and swing, by its number.
///   - tunings: the names of the file's tunings with the steps to an octave each has, and which of
///     them each instrument is tuned to (by its place among them from 1; nought for none).
///   - temperament: if given, every tuning is twelve steps to the octave that are these against the first.
///   - plugInPieces: the pieces of the file that keep its plug-ins, the first place first (see
///     `plugInPiece`); `plugins` more follow them, which are somebody else's programs.
///   - channelPlugIns: the plug-in each channel is sent through, counted from 1.
///   - parameterNotes: the rows of a pattern that change a plug-in's setting, as OpenMPT packs them.
///   - macros: MIDI macros that are other than the tracker's own, by their places among the 153.
private func mptm(_ patterns: [Pattern], song: Song = Song(), orders: [UInt8]? = nil,
                  sequences: [(orders: [Int], restart: Int?, speed: Int, tempo: Int)]? = nil, samples: [Sample] = [.sound(square, loops: true)],
                  instruments: [(sample: UInt8, volumeEnvelope: [(tick: Int, level: Int)], fade: Int)] = [],
                  instrumentExtras: [(name: String, size: Int, values: [[UInt8]])] = [], patternExtras: [Int: (rowsPerBeat: Int, swing: [Int])] = [:],
                  cues: [Int: [Int]] = [:], tunings: [(name: String, steps: Int)] = [], tuned: [Int] = [], plugins: Int = 0, cutoff: UInt8 = 0,
                  temperament: [Float] = [], plugInPieces: [[UInt8]] = [], channelPlugIns: [Int] = [], parameterNotes: [Int: [UInt8]] = [:],
                  macros: [Int: String] = [:]) -> [UInt8] {
    let orders = orders ?? patterns.indices.map { UInt8($0) }
    var file = text("IMPM") + padded(text("a square wave"), to: 26) + [UInt8(song.rowsPerBeat), 16]
    file += word(orders.count) + word(instruments.count) + word(samples.count) + word(patterns.count) + word(0x0891) + word(0x0888)
    file += word(0x0009 | (instruments.isEmpty ? 0 : 4)) + word(macros.isEmpty ? 4 : 12)
    file += [128, 48, UInt8(song.speed), UInt8(min(song.tempo, 255)), 128, 0] + word(0) + long(0) + text("OMPT")
    file += [UInt8](repeating: 32, count: 64) + [UInt8](repeating: 64, count: 64)
    #expect(file.count == 192)
    file += orders

    // The plug-ins, which are named between the header and what its lists point at.
    var pluginChunks: [UInt8] = []
    if !macros.isEmpty {
        // (The MIDI settings come first: the tracker's own, with these in their places.)
        var settings = IT2Module.defaultMIDIData()
        for (place, macro) in macros { settings.replaceSubrange(place * 32 ..< place * 32 + 32, with: padded(text(macro), to: 32)) }
        pluginChunks += settings
    }
    for (place, piece) in plugInPieces.enumerated() { pluginChunks += text("FX0\(place)") + long(piece.count) + piece }
    for plugin in 0 ..< plugins {
        let info = long(0x5653_5450) + long(0x1234_0000 + plugin) + [UInt8](repeating: 0, count: 120)
        pluginChunks += text("FX0\(plugInPieces.count + plugin)") + long(info.count + 8) + info + long(0) + long(0)
    }
    if !channelPlugIns.isEmpty { pluginChunks += text("CHFX") + long(channelPlugIns.count * 4) + channelPlugIns.flatMap(long) }

    let count = instruments.count + samples.count + patterns.count
    let base = file.count + count * 4 + pluginChunks.count
    var body: [UInt8] = [], places: [Int] = []
    for instrument in instruments {
        places.append(base + body.count)
        var bytes = text("IMPI") + [UInt8](repeating: 0, count: 13) + [0, 0, 0] + word(instrument.fade) + [0, 60, 128, 32 | 128, 0, 0] + word(0x0214) + [1, 0]
        bytes += [UInt8](repeating: 0, count: 26) + [cutoff, 0, 0, 0xFF] + word(0xFFFF)
        for note in 0 ..< 120 { bytes += [UInt8(note), instrument.sample] }
        for which in 0 ..< 3 {
            let points = which == 0 ? instrument.volumeEnvelope : []
            bytes += [points.isEmpty ? 0 : 1, UInt8(min(points.count, 25)), 0, 0, 0, 0]
            for index in 0 ..< 25 { bytes += index < points.count ? [UInt8(points[index].level)] + word(points[index].tick) : [0, 0, 0] }
            bytes.append(0)
        }
        body += padded(bytes, to: 554)
    }
    var sampleHeadersAt: [Int] = []
    for _ in samples {
        places.append(base + body.count)
        sampleHeadersAt.append(body.count)
        body += [UInt8](repeating: 0, count: 80)
    }
    for pattern in patterns {
        places.append(base + body.count)
        let packed = pattern.packed
        body += word(packed.count) + word(pattern.rows) + long(0) + packed
    }
    for (index, sample) in samples.enumerated() {
        let at = base + body.count
        var length = 0, flags: UInt8 = 1, convert: UInt8 = 1, loopEnd = 0
        switch sample {
        case .sound(let sound, let loops):
            length = sound.count
            loopEnd = loops ? sound.count : 0
            flags = loops ? 0x11 : 0x01
            body += sound
        case .fm:
            length = 12
            convert = 0x40
            body += [0x21, 0x21, 0x10, 0x00, 0xF2, 0xF2, 0x74, 0x74, 0, 0, 0x0E, 0]
        case .elsewhere:
            length = 1000
            convert = 0x80
            body += [9] + text("other.wav")
        }
        let header = text("IMPS") + [UInt8](repeating: 0, count: 13) + [64, flags, 64] + [UInt8](repeating: 0, count: 26) + [convert, 32]
            + long(length) + long(0) + long(loopEnd) + long(8363) + long(0) + long(0) + long(at) + [0, 0, 0, 0]
        #expect(header.count == 80)
        body.replaceSubrange(sampleHeadersAt[index] ..< sampleHeadersAt[index] + 80, with: header)
    }
    for place in places { file += long(place) }
    file += pluginChunks + body

    if !instrumentExtras.isEmpty {
        file += text("XTPM")
        for extra in instrumentExtras {
            file += text(extra.name).reversed() + word(extra.size)
            for value in extra.values { file += padded(value, to: extra.size) }
        }
    }
    file += text("STPM")
    func field(_ name: String, _ data: [UInt8], reversed: Bool = true) {
        file += (reversed ? text(name).reversed() : text(name)) + word(data.count) + data
    }
    if song.tempo > 255 { field("DT..", long(song.tempo)) }
    if song.fraction != 0 { field("DTFR", long(song.fraction), reversed: false) }
    if song.mode != 0 { field("TM..", [UInt8(song.mode)]) }
    field("PMM.", long(song.mixLevels))
    field("LSWV", long(song.version))
    if let restart = song.restart { field("RP..", word(restart)) }
    if !song.swing.isEmpty { field("SWNG", word(song.swing.count) + song.swing.flatMap(long), reversed: false) }
    for (sample, places) in cues.sorted(by: { $0.key < $1.key }) { field("CUES", word(sample) + padded(places.flatMap(long), to: 36), reversed: false) }
    var bits = [UInt8](repeating: 0, count: 18)
    for behaviour in song.behaviours { bits[behaviour >> 3] |= 1 << UInt8(behaviour & 7) }
    field("MSF.", bits)

    // OpenMPT's own last part.
    let ownAt = file.count
    var items: [(name: [UInt8], data: [UInt8])] = []
    if !tunings.isEmpty {
        // Each tuning is of equal steps, so many to an octave, with sixteen parts to a step.
        let all = tunings.map { tuning in
            guard temperament.count == 12 else {
                return (name: text("2"), data: chunk("CTB244RTI", [(text("0"), adaptive(tuning.name.utf8.count) + text(tuning.name)), (text("2"), word(3)), (text("4"), long(15)),
                                                                   (text("RTI1"), word(0x10000 - 64)), (text("RTI2"), word(tuning.steps)),
                                                                   (text("RTI3"), long(Int(Float(2).bitPattern))), (text("RTI4"), word(128))]))
            }
            // A temperament: twelve steps given, from the lowest note there is (64 below middle C,
            // which is the eighth step of an octave six below), and the rest of the scale those again.
            let steps = (0 ..< 12).map { step -> Float in temperament[(8 + step) % 12] / Float(step < 4 ? 64 : 32) }
            return (name: text("2"), data: chunk("CTB244RTI", [(text("0"), adaptive(tuning.name.utf8.count) + text(tuning.name)), (text("2"), word(1)), (text("4"), long(15)),
                                                               (text("RTI0"), adaptive(12) + steps.flatMap { long(Int($0.bitPattern)) }),
                                                               (text("RTI1"), word(0x10000 - 64)), (text("RTI3"), long(Int(Float(2).bitPattern))), (text("RTI4"), word(128))]))
        }
        items.append((text("0"), chunk("TC", all)))
        var map = word(tunings.count)
        for (index, tuning) in tunings.enumerated() { map += [UInt8(tuning.name.utf8.count)] + text(tuning.name) + word(index + 1) }
        for which in tuned { map += word(which) }
        items.append((text("1"), map))
    }
    if !patternExtras.isEmpty || !parameterNotes.isEmpty {
        var all: [(name: [UInt8], data: [UInt8])] = Set(patternExtras.keys).union(parameterNotes.keys).sorted().map { index in
            var parts: [(name: [UInt8], data: [UInt8])] = []
            if let notes = parameterNotes[index] { parts.append((text("data"), notes)) }
            if let extra = patternExtras[index] {
                parts += [(text("RPB."), long(extra.rowsPerBeat)), (text("RPM."), long(extra.rowsPerBeat * 4))]
                if !extra.swing.isEmpty { parts.append((text("SWNG"), word(extra.swing.count) + extra.swing.flatMap(long))) }
            }
            return (word(index), chunk("mptP", parts))
        }
        all.append((text("num"), word(patterns.count)))
        items.append((text("mptPc"), chunk("mptPc", all)))
    }
    let lists = sequences ?? [(orders.map { $0 >= 254 ? 0xFF00 | Int($0) : Int($0) }, nil, song.speed, song.tempo * 10000 + song.fraction)]
    var all: [(name: [UInt8], data: [UInt8])] = [(text("n"), [UInt8(lists.count)]), (text("c"), [0])]
    for (index, list) in lists.enumerated() {
        var parts: [(name: [UInt8], data: [UInt8])] = [(text("l"), word(list.orders.count)), (text("a"), list.orders.flatMap(word))]
        if let restart = list.restart { parts.append((text("r"), word(restart))) }
        parts += [(text("t"), long(list.tempo)), (text("s"), long(list.speed))]
        all.append(([UInt8(index)], chunk("mptSeq", parts)))
    }
    items.append((text("mptSeqC"), chunk("mptSeqC", all)))
    return file + chunk("mptm", items) + long(ownAt)
}

private func player(_ file: [UInt8], options: LoadOptions = LoadOptions()) throws -> ITRenderer {
    try #require(try TuneLoader.load(file, format: .mptm, options: options) as? ITRenderer)
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
    (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
}

/// The rows a tune plays, each with how many ticks it had and how many frames they came to.
private func rows(_ renderer: ITRenderer, seconds: Double = 60) -> [(order: Int, row: Int, ticks: Int, frames: Int)] {
    var rows: [(order: Int, row: Int, ticks: Int, frames: Int)] = []
    for tick in renderer.ticks(seconds: seconds) {
        if let last = rows.last, last.order == tick.order, last.row == tick.row {
            rows[rows.count - 1].ticks += 1
            rows[rows.count - 1].frames += tick.frames
        } else {
            rows.append((tick.order, tick.row, 1, tick.frames))
        }
    }
    return rows
}

private let tune = Pattern((0 ..< 4).map { (row: $0 * 4, channel: 0, cell: Cell.note(UInt8(60 + $0 * 2))) })

// MARK: The file

@Test func mptmNoteSoundsAtItsPitch() throws {
    // C-5 plays a sample at its own rate, 8363 samples a second, and the square wave is 32 of them: 261 Hz.
    let renderer = try player(mptm([Pattern([(0, 0, .note())])]))
    #expect(renderer.info.format == "MPTM")
    #expect(renderer.info.title == "a square wave")
    #expect(renderer.info.detail == "OpenMPT 1.30.00")
    #expect(renderer.info.shortfalls.isEmpty)
    let sound = stereo(renderer, seconds: 1).left
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 261) <= 2)
    #expect(sound[4800...].map(abs).max()! > 0.02)
}

@Test func itFileUnderAnMPTMNameIsAnITFile() throws {
    // Without OpenMPT's own last part it is an IT file whatever it is called, and is played as one.
    var file = mptm([Pattern([(0, 0, .note())])])
    file.replaceSubrange(file.count - 4 ..< file.count, with: [0, 0, 0, 0])
    file.replaceSubrange(0x28 ..< 0x2C, with: word(0x0214) + word(0x0200))
    let renderer = try #require(try TuneLoader.load(file, format: .mptm) as? ITRenderer)
    #expect(renderer.info.format == "IT")
    #expect(!MPTMFile.isOne(file) && MPTMFile.isOne(mptm([tune])))
}

@Test func mptmFileCutShortAnywhereIsReadOrRefused() throws {
    // Whatever is missing, nothing is read from beyond the end.
    let file = mptm([tune, Pattern(rows: 300, [(299, 0, .note())])], song: Song(mode: 2, swing: [1 << 24, 1 << 23]),
                    instruments: [(1, [(0, 64), (10, 0)], 32)], instrumentExtras: [("VERN", 1, [[1]]), ("MiP.", 1, [[1]])],
                    patternExtras: [1: (3, [1 << 24, 1 << 24, 1 << 23])], tunings: [("twelve", 12)], tuned: [1], plugins: 1)
    _ = try player(file)
    for length in stride(from: 0, to: file.count, by: 7) {
        _ = try? TuneLoader.load(Array(file[..<length]), format: .mptm)
        var end = Array(file[..<length])
        end += long(max(0, length - 40))
        _ = try? TuneLoader.load(end, format: .mptm)
    }
    // And a file of noise after its header is no worse.
    var noise = file
    var seed: UInt32 = 12345
    for index in 192 ..< noise.count - 4 where index % 3 == 0 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        noise[index] = UInt8(truncatingIfNeeded: seed >> 24)
    }
    if let renderer = try? TuneLoader.load(noise, format: .mptm) { _ = stereo(renderer, seconds: 0.5) }
}

// MARK: Time

@Test func mptmKeepsTimeInOpenMPTsThreeWays() throws {
    // Classic, as Impulse Tracker: a tick is two and a half seconds over the tempo, and a row six of them.
    let classic = rows(try player(mptm([tune], song: Song(mode: 0))))
    #expect(classic[0].ticks == 6 && classic[0].frames == 6 * 960)
    // Alternative: a tick is a second over the tempo.
    let alternative = rows(try player(mptm([tune], song: Song(mode: 1))))
    #expect(alternative[0].ticks == 6 && alternative[0].frames == 6 * 384)
    // Modern: the tempo is beats a minute and a beat is four rows, whatever the speed.
    let modern = rows(try player(mptm([tune], song: Song(mode: 2))))
    #expect(modern[0].ticks == 6 && modern[0].frames == 5760)
    let faster = rows(try player(mptm([tune], song: Song(mode: 2, speed: 3))))
    #expect(faster[0].ticks == 3 && faster[0].frames == 5760)
    let finer = rows(try player(mptm([tune], song: Song(mode: 2, rowsPerBeat: 8))))
    #expect(finer[0].frames == 2880)
    // A tick is a whole number of frames, and what is cut off is made up later: 7 ticks to a row of 5760.
    let uneven = try player(mptm([tune], song: Song(mode: 2, speed: 7))).ticks(seconds: 1).prefix(7).map(\.frames)
    #expect(uneven == [822, 823, 823, 823, 823, 823, 823])
}

@Test func mptmTempoCanBeAFractionAndMoreThanAByteHolds() throws {
    // 133.3333 beats a minute: a row is 60 × 48000 ÷ (133.3333 × 4) frames.
    let fraction = rows(try player(mptm([tune], song: Song(mode: 2, tempo: 133, fraction: 3333))))
    #expect(fraction[0].frames + fraction[1].frames == 10800)
    let high = rows(try player(mptm([tune], song: Song(tempo: 480, speed: 3))))
    #expect(high[0].frames == 3 * 250)
    // T01 with #90 below it is tempo 0x190, where T01 alone would be a slide; a file that says
    // so holds what a command asks for to 255, and one that does not lets a slide go on past it.
    let pattern = Pattern([(0, 0, .note()), (1, 1, .command("T", 1)), (2, 1, .command("#", 0x90)), (4, 1, .command("T", 0x1F))])
    let free = try player(mptm([pattern], song: Song(behaviours: [0]))).ticks(seconds: 2)
    #expect(free.first { $0.row == 1 }?.tempo == 400)
    #expect(free.last { $0.row == 4 }?.tempo == 475)
    let held = try player(mptm([pattern], song: Song(behaviours: [0, 8]))).ticks(seconds: 2)
    #expect(held.first { $0.row == 1 }?.tempo == 255)
}

@Test func mptmRowsOfABeatCanBeSwung() throws {
    // The song's swing: the first row of each beat half as long again, the second half as long.
    let unity = 1 << 24
    let swung = rows(try player(mptm([tune], song: Song(mode: 2, swing: [unity * 3 / 2, unity / 2, unity, unity]))))
    #expect(swung.prefix(4).map(\.frames) == [8640, 2880, 5760, 5760])
    // A pattern with rows to a beat and a swing of its own.
    let own = rows(try player(mptm([tune, tune], song: Song(mode: 2), patternExtras: [1: (2, [unity * 3 / 2, unity / 2])])))
    let second = own.filter { $0.order == 1 }
    #expect(own[0].frames == 5760 && second.prefix(2).map(\.frames) == [17280, 5760])
}

// MARK: Patterns and lists longer than Impulse Tracker's

@Test func mptmPatternCanHaveMoreRowsThanAByteCounts() throws {
    // A loop that starts at row 300 and goes back to it twice from row 303; and a break to row
    // 0x190 of the next pattern, which a byte could not name.
    let pattern = Pattern(rows: 1024, [(0, 0, .note()), (300, 1, .command("S", 0xB0)), (303, 1, .command("S", 0xB2)),
                                       (600, 1, .command("C", 1)), (601, 1, .command("#", 0x90))])
    let played = rows(try player(mptm([pattern, pattern], song: Song(speed: 1))), seconds: 30)
    #expect(played.count { $0.order == 0 && $0.row == 300 } == 3)
    #expect(played.contains { $0.order == 0 && $0.row == 600 } && !played.contains { $0.order == 0 && $0.row == 601 })
    #expect(played.first { $0.order == 1 }?.row == 0x190)
    // 1024 rows of a tick each, at 50 ticks a second.
    #expect(try player(mptm([Pattern(rows: 1024, [(0, 0, .note())])], song: Song(speed: 1))).knownLength.map { abs($0 - 20.48) < 0.01 } == true)
}

@Test func mptmListCanBeLongerThanImpulseTrackers() throws {
    // 300 places, the last of which jumps to place 260 (B01 with #04 below it).
    let last = Pattern(rows: 4, [(0, 0, .note()), (0, 1, .command("B", 1)), (1, 1, .command("#", 4))])
    let short = Pattern(rows: 2, [(0, 0, .note())])
    let played = rows(try player(mptm([short, last], song: Song(speed: 1), orders: [UInt8](repeating: 0, count: 299) + [1])), seconds: 30)
    #expect(played.contains { $0.order == 298 } && played.contains { $0.order == 299 })
    #expect(played.last?.order == 299)
}

@Test func mptmSongStartsAgainWhereItSays() throws {
    // Three places, and from the end back to the second: the tune comes round there and not at its top.
    let other = Pattern([(0, 0, .note(67))])
    let renderer = try player(mptm([tune, other], sequences: [([0, 1, 1], 1, 6, 1_250_000)]))
    #expect(renderer.knownLength.map { abs($0 - 48 * 0.12) < 0.01 } == true)
    var frames = 0
    let player = IT2Player(renderer.module)
    var orders: [Int] = []
    while frames < 48000 * 9 {
        player.Update()
        if orders.last != Int(player.CurrentOrder) { orders.append(Int(player.CurrentOrder)) }
        frames += player.mixer.skipTick()
    }
    #expect(orders.starts(with: [0, 1, 2, 1, 2]))
}

@Test func mptmListsAreItsSongs() throws {
    // Two lists: the first one pattern at speed 6 and tempo 125; the second another at speed 3 and
    // tempo 75, which jumps to its own top, and not to the file's.
    let other = Pattern([(0, 0, .note(67)), (15, 1, .command("B", 0))])
    let renderer = try player(mptm([tune, other], sequences: [([0], nil, 6, 1_250_000), ([1], nil, 3, 750_000)]))
    #expect(renderer.subsongCount == 2)
    #expect(renderer.songs.map { $0.length.map { ($0 * 100).rounded() / 100 } } == [1.92, 1.6])
    renderer.select(subsong: 1)
    let sound = stereo(renderer, seconds: 0.5).left
    // G-5, a fifth above the first song's C.
    #expect(abs(crossings(sound[4800...]) * 10 / 4 - 392) <= 5)
}

// MARK: Commands that are OpenMPT's own

@Test func mptmNoteCanBeDelayedAndCut() throws {
    // :23 at speed 6: silent for two ticks, heard for three, silent again.
    let renderer = try player(mptm([Pattern([(0, 0, .note(60, nil as Character? ?? ":", 0x23))])]))
    let sound = stereo(renderer, seconds: 0.12).left
    #expect(loudness(sound[0 ..< 1800]) < 0.001)
    #expect(loudness(sound[2400 ..< 4300]) > 0.02)
    #expect(loudness(sound[5300 ..< 5760]) < 0.004)
}

@Test func mptmSampleCanBePlayedBackwardsFromACuePoint() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let samples = [Sample.sound(swell, loops: false)]
    // Forwards it grows; with S9F it is played from its end and dies away, and ends at its start.
    // (4000 samples at 8363 a second are 22,958 frames.)
    let forwards = stereo(try player(mptm([Pattern([(0, 0, .note())])], samples: samples), options: options), seconds: 0.7).left
    let backwards = stereo(try player(mptm([Pattern([(0, 0, .note(60, "S", 0x9F))])], samples: samples), options: options), seconds: 0.7).left
    #expect(loudness(forwards[16000 ..< 20000]) > 3 * loudness(forwards[2000 ..< 6000]))
    #expect(loudness(backwards[2000 ..< 6000]) > 3 * loudness(backwards[16000 ..< 20000]))
    #expect(loudness(forwards[24000...]) < 0.001 && loudness(backwards[24000...]) < 0.001)
    // The volume column starts a note at one of the places its sample names: here 3000 samples in,
    // which leaves 1000 to play forwards and 3000 backwards.
    let cues = [1: [1000, 3000, 3900]]
    let late = stereo(try player(mptm([Pattern([(0, 0, .note(60, volume: 223 + 2))])], samples: samples, cues: cues), options: options), seconds: 0.4).left
    #expect(loudness(late[4000 ..< 5000]) > 0.01 && loudness(late[6500 ..< 9000]) < 0.001)
    let lateBackwards = stereo(try player(mptm([Pattern([(0, 0, .note(60, volume: 223 + 2, "S", 0x9F))])], samples: samples, cues: cues), options: options), seconds: 0.5).left
    #expect(loudness(lateBackwards[14000 ..< 16500]) > 0.002 && loudness(lateBackwards[18500...]) < 0.001)
}

@Test func mptmLoopOutlastsAJumpUnlessTheFileAsksForImpulseTrackers() throws {
    // SB1 and B01 on one row. OpenMPT goes round the loop and then takes the jump; Impulse Tracker
    // takes the jump at once.
    let pattern = Pattern(rows: 8, [(0, 0, .note()), (0, 1, .command("S", 0xB0)), (3, 1, .command("S", 0xB1)), (3, 2, .command("B", 1))])
    let other = Pattern(rows: 8, [(0, 0, .note(67))])
    let own = rows(try player(mptm([pattern, other])))
    #expect(own.prefix(9).map(\.row) == [0, 1, 2, 3, 0, 1, 2, 3, 0] && own[8].order == 1)
    let asImpulseTracker = rows(try player(mptm([pattern, other], song: Song(behaviours: [0, 103]))))
    #expect(asImpulseTracker.prefix(5).map(\.order) == [0, 0, 0, 0, 1])
}

// MARK: Instruments

@Test func mptmEnvelopeGoesToItsReleaseNodeWhenTheKeyIsLetGo() throws {
    var options = LoadOptions()
    options.stereo = .abc
    // An envelope that falls slowly, with a point to go to when the key is let go from which it
    // falls fast: without that point a key let go leaves it falling slowly.
    let envelope = [(tick: 0, level: 64), (tick: 100, level: 56), (tick: 101, level: 32), (tick: 110, level: 0)]
    let pattern = Pattern([(0, 0, .note()), (2, 0, Cell(note: 255))])
    let plain = stereo(try player(mptm([pattern], instruments: [(1, envelope, 0)]), options: options), seconds: 0.6).left
    let released = stereo(try player(mptm([pattern], instruments: [(1, envelope, 0)], instrumentExtras: [("VERN", 1, [[2]])]), options: options), seconds: 0.6).left
    #expect(loudness(plain[20000 ..< 24000]) > 0.02)
    #expect(loudness(released[23000 ..< 27000]) < 0.001)
    #expect(loudness(released[6000 ..< 9000]) > 0.01)
}

@Test func mptmEnvelopeCanHaveMoreThanTwentyFivePoints() throws {
    // Thirty points, given whole in the instruments' extras.
    let points = (0 ..< 30).map { (tick: $0 * 4, level: $0 % 2 == 0 ? 64 : 24) }
    let file = mptm([Pattern([(0, 0, .note())])], instruments: [(1, Array(points[..<25]), 0)],
                    instrumentExtras: [("VE..", 4, [long(30)]), ("VP[.", 60, [points.flatMap { word($0.tick) }]), ("VE[.", 30, [points.map { UInt8($0.level) }])])
    let envelope = try #require(try player(file).listing().instruments.first?.volume)
    #expect(envelope.ticks.count == 30 && envelope.ticks.last == 116 && envelope.levels.last == 24)
}

@Test func mptmFilterCanLetTheHighThroughInsteadOfTheLow() throws {
    var options = LoadOptions()
    options.stereo = .abc
    // A square wave at 65 Hz through a filter set low: the usual filter leaves its lowest part, and
    // the other way up it takes that away and leaves the edges.
    let pattern = Pattern([(0, 0, .note(36))])
    func played(_ mode: UInt8?) throws -> [Float] {
        let extras: [(name: String, size: Int, values: [[UInt8]])] = mode.map { [("FM..", 1, [[$0]])] } ?? []
        return stereo(try player(mptm([pattern], instruments: [(1, [], 0)], instrumentExtras: extras, cutoff: 0x80 | 30), options: options), seconds: 0.5).left
    }
    let low = try played(nil), alsoLow = try played(0), high = try played(1)
    #expect(low == alsoLow)
    #expect(loudness(low[4800...]) > 1.5 * loudness(high[4800...]) && loudness(high[4800...]) > 0.001)
    // And what the two let through between them is the whole of what went in.
    let whole = stereo(try player(mptm([pattern], instruments: [(1, [], 0)]), options: options), seconds: 0.5).left
    let together = zip(low, high).map { $0 + $1 }
    #expect(zip(whole[4800...], together[4800...]).allSatisfy { abs($0 - $1) < 0.01 })
}

// MARK: What is not played

@Test func mptmSaysWhatItLeavesOut() throws {
    // Three instruments: a sample's, a plug-in's and an FM patch; and a second plug-in, neither of them OpenMPT's own.
    let pattern = Pattern((0 ..< 8).map { (row: $0, channel: 0, cell: Cell.note(60, instrument: $0 == 2 ? 2 : $0 == 5 ? 3 : 1)) })
    let file = mptm([pattern], samples: [.sound(square, loops: true), .fm], instruments: [(1, [], 0), (0, [], 0), (2, [], 0)],
                    instrumentExtras: [("MiP.", 1, [[0], [1], [0]])], plugins: 2)
    let renderer = try player(file)
    #expect(renderer.info.shortfalls == ["One of its instruments plays through a plug-in, and is not heard.",
                                    "Its two plug-ins are left out, and it is heard without what they do to its sound."])
    #expect(renderer.info.detail == "OpenMPT 1.30.00")
    // What is said is only what the file uses.
    let unused = mptm([Pattern([(0, 0, .note())])], samples: [.sound(square, loops: true), .fm], instruments: [(1, [], 0), (2, [], 0)])
    #expect(try player(unused).info.shortfalls.isEmpty)
    // A command that bends a pitch is taken out. (A macro slid over a row is played, and so is
    // nothing to speak of.)
    let commands = Pattern([(0, 0, .note()), (1, 0, Cell(command: "^", value: 1)), (2, 0, .command("\\", 0x10)), (3, 0, .command("S", 0x99))])
    let said = try player(mptm([commands])).info.shortfalls
    #expect(said == ["One command that bends a note's pitch is left out.", "Its reverb is left out."])
}

@Test func mptmFileThatIsMostlyNotHeardIsRefused() throws {
    func refusal(_ file: [UInt8]) -> String {
        do {
            _ = try TuneLoader.load(file, format: .mptm)
            return ""
        } catch {
            return "\(error)"
        }
    }
    // Half its notes are for a plug-in that is not here, or for a sample that is not in the file.
    let pattern = Pattern((0 ..< 8).map { (row: $0, channel: 0, cell: Cell.note(60, instrument: $0 % 2 == 0 ? 2 : 1)) })
    let plugin = mptm([pattern], instruments: [(1, [], 0), (0, [], 0)], instrumentExtras: [("MiP.", 1, [[0], [1]])], plugins: 1)
    #expect(refusal(plugin) == "unsupported: an MPTM file that is mostly for plug-ins")
    // (One that is for the AdLib's FM chip is played.)
    let fm = mptm([pattern], samples: [.sound(square, loops: true), .fm], instruments: [(1, [], 0), (2, [], 0)])
    #expect(refusal(fm) == "")
    let elsewhere = mptm([pattern], samples: [.sound(square, loops: true), .elsewhere], instruments: [(1, [], 0), (2, [], 0)])
    #expect(refusal(elsewhere) == "unsupported: an MPTM file most of whose samples are in other files")
    // An instrument with no sample and no plug-in is silent in OpenMPT too, and is nothing to refuse a file for.
    #expect(refusal(mptm([pattern], instruments: [(1, [], 0), (0, [], 0)])) == "")
}

@Test func mptmFileInAnotherTuningIsRefused() throws {
    // Twelve equal steps to the octave is what every module has, and is played; nineteen is not.
    let pattern = Pattern([(0, 0, .note())])
    let twelve = mptm([pattern], instruments: [(1, [], 0)], tunings: [("twelve", 12)], tuned: [1])
    #expect(try player(twelve).info.shortfalls.isEmpty)
    let nineteen = mptm([pattern], instruments: [(1, [], 0)], tunings: [("nineteen", 19)], tuned: [1])
    #expect(throws: TuneError.self) { try TuneLoader.load(nineteen, format: .mptm) }
    // A tuning the file carries and no instrument uses is no reason to refuse it.
    let carried = mptm([pattern], instruments: [(1, [], 0)], tunings: [("nineteen", 19)], tuned: [0])
    #expect(try player(carried).info.shortfalls.isEmpty)
}

@Test func mptmChannelToOneSideIsNoLouderThanOneInTheMiddle() throws {
    var options = LoadOptions()
    options.stereo = .abc
    // OpenMPT's way since 1.17: a note to the left is as loud on the left as one in the middle, and
    // quieter on the right. Impulse Tracker's, which OpenMPT also has, makes its left louder.
    func sides(_ mixLevels: Int, pan: UInt8) throws -> (left: Float, right: Float) {
        let sound = stereo(try player(mptm([Pattern([(0, 0, .note(60, "X", pan))])], song: Song(mixLevels: mixLevels)), options: options), seconds: 0.4)
        return (loudness(sound.left[4800...]), loudness(sound.right[4800...]))
    }
    let softMiddle = try sides(3, pan: 0x80), softLeft = try sides(3, pan: 0x20)
    #expect(abs(softLeft.left / softMiddle.left - 1) < 0.02 && softLeft.right < softMiddle.right * 0.3)
    let middle = try sides(4, pan: 0x80), left = try sides(4, pan: 0x20)
    #expect(left.left > middle.left * 1.6 && left.right < middle.right * 0.3)
    // And that way is twice as loud.
    #expect(abs(softMiddle.left / middle.left - 2) < 0.05)
}

@Test func mptmFormatIsKnownByItsName() {
    #expect(TuneFormat(fileExtension: "MPTM") == .mptm)
    #expect(!Setting.chip.changes(.mptm) && Setting.loops.changes(.mptm))
}

@Test func itFileIsPlayedAsTheTrackerThatMadeItPlayedIt() throws {
    // An IT file with one instrument, which has a MIDI channel as well as a sample. Impulse Tracker
    // sends such an instrument's notes to a synthesiser and plays no sample for them; ModPlug
    // Tracker and OpenMPT played the sample all the same.
    func file(madeBy tracker: [UInt8]) throws -> [UInt8] {
        var file = mptm([Pattern([(0, 0, .note(60, instrument: 1))])], instruments: [(1, [], 0)])
        file.replaceSubrange(file.count - 4 ..< file.count, with: [0, 0, 0, 0])
        file.replaceSubrange(0x28 ..< 0x2C, with: tracker)
        let instrument = try #require(file.firstRange(of: Array("IMPI".utf8))).lowerBound
        file[instrument + 0x3C] = 10
        return file
    }
    // Made by Impulse Tracker 2.14: no sound, and the file says why.
    let own = try TuneLoader.load(try file(madeBy: word(0x0214) + word(0x0200)), format: .it)
    #expect(own.info.shortfalls == ["One of its instruments is sent to a MIDI synthesiser, and is not heard."])
    #expect(loudness(stereo(own, seconds: 0.5).left[4800...]) < 0.0001)
    // Made by OpenMPT 1.30: its sample is heard, and there is nothing to say.
    let later = try #require(try TuneLoader.load(try file(madeBy: word(0x5130) + word(0x0214)), format: .it) as? ITRenderer)
    #expect(later.info.detail.hasPrefix("OpenMPT"))
    #expect(later.info.shortfalls.isEmpty)
    #expect(loudness(stereo(later, seconds: 0.5).left[4800...]) > 0.01)
    // But written out for setting beside the player this is ported from, it is as that plays it.
    #expect(later.renderRaw(frames: 24000).allSatisfy { abs(Int($0)) < 4 })
}

// MARK: Temperaments

@Test func mptmTemperamentIsPlayedAtItsOwnPitches() throws {
    // Twelve steps to the octave that are not quite equal: each a few hundredths of a semitone out.
    let equal = (0 ..< 12).map { Float(pow(2.0, Double($0) / 12)) }
    var steps = equal
    steps[4] *= Float(pow(2.0, -0.14 / 12)) // an E fourteen hundredths flat
    steps[7] *= Float(pow(2.0, 0.02 / 12))
    let notes = Pattern([(0, 0, .note(60)), (4, 0, .note(64)), (8, 0, .note(79)), (12, 0, .note(52))])
    let file = mptm([notes], instruments: [(1, [], 0)], tunings: [("well tempered", 12)], tuned: [1], temperament: steps)
    let renderer = try player(file)
    #expect(renderer.info.shortfalls == ["It is tuned to \"well tempered\", which is nowhere more than fourteen hundredths of a semitone from the usual tuning: "
            + "its notes start at that tuning's pitches, and its slides and arpeggios move by the usual tuning's steps."])
    // Each note's rate is the sample's own by what the tuning makes of the note.
    let rates = renderer.ticks(seconds: 2).enumerated().filter { $0.offset % 24 == 0 }.map { $0.element.rates.max() ?? 0 }
    let wanted = [steps[0], steps[4], steps[7] * 2, steps[4] / 2].map { Int((8363 * $0).rounded()) }
    #expect(Array(rates.prefix(4)) == wanted)
    #expect(wanted[1] != Int((8363 * equal[4]).rounded()))
    // One that is further out than a quarter of a semitone anywhere is still refused.
    steps[9] *= Float(pow(2.0, 0.3 / 12))
    let far = mptm([notes], instruments: [(1, [], 0)], tunings: [("far", 12)], tuned: [1], temperament: steps)
    #expect(throws: TuneError.self) { try TuneLoader.load(far, format: .mptm) }
}

// MARK: The FM chip

/// A song that asks for OpenMPT's ways with the FM chip since its version 1.30: a note that is fading
/// is still told its level, and a note that its channel lets go keeps its voice of the chip.
private let fmSong: Song = {
    var song = Song()
    song.behaviours += [99, 105]
    return song
}()

/// What a player sets the FM chip's registers to, tick by tick, for as many ticks as asked.
private func chipWrites(_ renderer: ITRenderer, ticks: Int) -> [[(register: Int, value: UInt8)]] {
    let player = IT2Player(renderer.module)
    player.adLib?.log = []
    return (0 ..< ticks).map { _ in
        player.Update()
        let writes = (player.adLib?.log ?? []).map { (register: Int($0 >> 8), value: UInt8(truncatingIfNeeded: $0)) }
        player.adLib?.log = []
        _ = player.mixer.skipTick()
        return writes
    }
}

@Test func mptmInstrumentForTheFMChipIsPlayedOnIt() throws {
    // A note of an FM patch, let go on the fifth row and cut on the ninth; nothing else.
    let pattern = Pattern([(0, 0, .note(60, instrument: 1)), (4, 0, Cell(note: 255)), (8, 0, .note(60, instrument: 1, volume: 32)), (12, 0, Cell(note: 254))])
    let file = mptm([pattern], song: fmSong, samples: [.fm], instruments: [(1, [], 0)])
    let renderer = try player(file)
    #expect(renderer.info.shortfalls.isEmpty)

    // The chip is given the patch, and the note: middle C is 261.625 Hz, which is 690 in the chip's third octave.
    let ticks = chipWrites(renderer, ticks: 80)
    let first = Dictionary(ticks[0].map { ($0.register, $0.value) }, uniquingKeysWith: { _, last in last })
    #expect(first[0x20] == 0x21 && first[0x23] == 0x21 && first[0x40] == 0x10 && first[0x60] == 0xF2 && first[0x63] == 0xF2 && first[0x80] == 0x74)
    #expect(first[0xA0] == 0xB2 && first[0xB0] == 0x2E)
    #expect(first[0x43] == 0x00 && first[0xC0] == 0x3E)
    // Its key is let go when the note is, and it is cut when the note is cut: let go, and turned right down.
    #expect(ticks[23].last { $0.register == 0xB0 }?.value == 0x2E)
    #expect(ticks[24].last { $0.register == 0xB0 }?.value == 0x0E)
    // A note at half volume has the operator that is heard turned down by as much.
    #expect(ticks[48].last { $0.register == 0xB0 }?.value == 0x2E)
    #expect(ticks[48].last { $0.register == 0x43 }?.value == 31)
    #expect(ticks[72].last { $0.register == 0xB0 }?.value == 0x0E && ticks[72].last { $0.register == 0x43 }?.value == 0x3F)

    // And it is heard, at its pitch, with a light and a note for the pictures.
    let sound = stereo(renderer, seconds: 0.4)
    #expect(loudness(sound.left[2400...]) > 0.01 && loudness(sound.right[2400...]) > 0.01)
    var levels = [Float](repeating: 0, count: renderer.channelCount), pitches = levels
    var struck = [Bool](repeating: false, count: renderer.channelCount)
    renderer.takeChannelLevels(into: &levels)
    renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
    #expect(renderer.channelCount == 1 && levels[0] > 0.05 && abs(pitches[0] - 60) < 0.1 && struck[0])

    // Written out for setting beside Impulse Tracker's own player, there is no FM: that had none.
    #expect(renderer.renderRaw(frames: 9600).allSatisfy { abs(Int($0)) < 4 })
}

@Test func mptmFMNoteThatIsLetGoKeepsItsVoiceWhileTheNextStarts() throws {
    // An instrument whose notes are let go, and not cut, when the next arrives: the first note keeps
    // its voice of the chip with its key up, and the second takes another.
    let pattern = Pattern([(0, 0, .note(60, instrument: 1)), (4, 0, .note(67, instrument: 1))])
    func writes(_ song: Song) throws -> [(register: Int, value: UInt8)] {
        var file = mptm([pattern], song: song, samples: [.fm], instruments: [(1, [(0, 64), (10, 64), (40, 0)], 64)])
        let instrument = try #require(file.firstRange(of: Array("IMPI".utf8))).lowerBound
        file[instrument + 0x11] = 2 // its "new note action": note off
        return chipWrites(try player(file), ticks: 30)[24]
    }
    let now = try writes(fmSong)
    #expect(now.contains { $0.register == 0xB0 && $0.value & 0x20 == 0 })
    #expect(now.contains { $0.register == 0xB1 && $0.value & 0x20 != 0 })
    // Before OpenMPT 1.30 the first note gave its voice up to the second.
    let once = try writes(Song())
    #expect(once.last { $0.register == 0xB0 }.map { $0.value & 0x20 != 0 } == true && !once.contains { $0.register == 0xB1 })
}

// MARK: Plug-ins

/// The piece of a file that keeps one of OpenMPT's own effects: which it is, how it is wired, and its settings.
private func plugInPiece(_ second: UInt32, _ name: String, flags: UInt8 = 0, mixMode: UInt8 = 0, gain: UInt8 = 0, output: Int = 0, dry: Float? = nil,
                         settings: [Float]) -> [UInt8] {
    var piece = long(0x4458_4D4F) + long(Int(second)) + [flags, mixMode, gain, 0] + long(output) + [UInt8](repeating: 0, count: 16)
    piece += [UInt8](repeating: 0, count: 32) + padded(text(name), to: 64)
    let data = long(0) + settings.flatMap { long(Int($0.bitPattern)) }
    let more = dry.map { text("DWRT") + long(Int($0.bitPattern)) } ?? []
    return piece + long(data.count) + data + long(more.count) + more
}

/// OpenMPT's echo, set to give back what it is given a thousandth of a second later (48 frames) and nothing else.
private func delay(flags: UInt8 = 0, output: Int = 0, dry: Float? = nil, gain: UInt8 = 0) -> [UInt8] {
    plugInPiece(0xEF3E_932C, "Echo", flags: flags, gain: gain, output: output, dry: dry, settings: [1, 0, 0, 0, 0])
}

/// How far two sounds are apart at the most, the second taken so many frames later than the first.
private func apart(_ a: [Float], _ b: [Float], later: Int = 0, from: Int = 0, to: Int? = nil) -> Float {
    var most: Float = 0
    for n in from ..< min(to ?? a.count, a.count, b.count - later) { most = max(most, abs(a[n] - b[n + later])) }
    return most
}

private let held = Pattern([(0, 0, .note(60)), (0, 1, .note(67)), (8, 0, .note(64))])

@Test func mptmChannelIsHeardThroughItsPlugIn() throws {
    let dry = stereo(try player(mptm([held])), seconds: 1).left
    #expect(loudness(dry[...]) > 0.01)
    // Both channels through the echo: all that is heard is what the echo gives back.
    let both = try player(mptm([held], plugInPieces: [delay()], channelPlugIns: [1, 1]))
    #expect(both.info.shortfalls.isEmpty)
    let wet = stereo(both, seconds: 1).left
    #expect(apart(dry, wet, later: 48) < 1e-5 && loudness(wet[..<48]) == 0)
    #expect(apart(dry, wet) > 0.01)
    // As much of what it was given beside that as the file says, and as loud.
    let mixed = stereo(try player(mptm([held], plugInPieces: [delay(dry: 0.25, gain: 20)], channelPlugIns: [1, 1])), seconds: 1).left
    #expect((48 ..< 40000).allSatisfy { abs(mixed[$0] - 2 * (0.75 * dry[$0 - 48] + 0.25 * dry[$0])) < 1e-5 })
    // A plug-in that is switched off passes on what it is given.
    #expect(apart(dry, stereo(try player(mptm([held], plugInPieces: [delay(flags: 2)], channelPlugIns: [1, 1])), seconds: 1).left) < 1e-5)
    // One whose sound goes on to another plug-in is heard through both.
    let chain = stereo(try player(mptm([held], plugInPieces: [delay(output: 0x81), delay()], channelPlugIns: [1, 1])), seconds: 1).left
    #expect(apart(dry, chain, later: 96) < 1e-5)
    // One that is on the whole sound has everything through it, whatever was sent where.
    let master = stereo(try player(mptm([held], plugInPieces: [delay(flags: 1)])), seconds: 1).left
    #expect(apart(dry, master, later: 48) < 1e-5)
}

@Test func mptmInstrumentIsHeardThroughItsPlugInBeforeItsChannels() throws {
    // One instrument with a sample and a plug-in, and a channel sent through another: the instrument's counts.
    let pattern = Pattern([(0, 0, .note(60, instrument: 1))])
    let dry = stereo(try player(mptm([pattern], instruments: [(1, [], 0)])), seconds: 0.5).left
    let file = mptm([pattern], instruments: [(1, [], 0)], instrumentExtras: [("MiP.", 1, [[2]])], plugInPieces: [delay(output: 0x81), delay()], channelPlugIns: [1])
    #expect(apart(dry, stereo(try player(file), seconds: 0.5).left, later: 48) < 1e-5)
}

@Test func mptmPlugInThatIsNotOpenMPTsOwnIsLeftOutAndSaidToBe() throws {
    // The channel is sent through somebody's program, which is not here: it is heard as it is.
    let dry = stereo(try player(mptm([held])), seconds: 0.5).left
    let other = try player(mptm([held], plugins: 1, channelPlugIns: [1, 1]))
    #expect(apart(dry, stereo(other, seconds: 0.5).left) == 0)
    #expect(other.info.shortfalls == ["Its plug-in is left out, and it is heard without what that does to its sound."])
    // With one of OpenMPT's own beside it, that one is played and the other is named, if it has a name.
    var named = plugInPiece(0x1234_5678, "Classic Reverb", settings: [])
    named.replaceSubrange(0 ..< 4, with: long(0x5673_7450))
    let two = try player(mptm([held], plugInPieces: [delay(), named], channelPlugIns: [1, 2]))
    #expect(two.info.shortfalls == ["One of its two plug-ins (Classic Reverb) is left out, and it is heard without what that does to its sound."])
    #expect(apart(dry, stereo(two, seconds: 0.5).left) > 0.01)
}

@Test func mptmRowCanChangeAPlugInsSetting() throws {
    let dry = stereo(try player(mptm([held])), seconds: 1).left
    // On the fifth row the echo is told to pass on what it is given and none of what it has kept:
    // by a note that is for that, and then by a macro that is.
    let row = 4 * 6 * 960
    let note: [UInt8] = [0, 0, 0, 0, 0x83, 0x3F, 0xFC, 1, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 11)
    let byNote = stereo(try player(mptm([held], plugInPieces: [delay()], channelPlugIns: [1, 1], parameterNotes: [0: note])), seconds: 1).left
    #expect(apart(dry, byNote, later: 48, to: row - 48) < 1e-5 && apart(dry, byNote, from: row + 96) < 1e-5)
    let macro = Pattern(held.cells + [(4, 0, .command("Z", 0))])
    let byMacro = try player(mptm([macro], plugInPieces: [delay()], channelPlugIns: [1, 1], macros: [9: "F0F080z"]))
    #expect(byMacro.info.shortfalls.isEmpty)
    let sound = stereo(byMacro, seconds: 1).left
    #expect(apart(dry, sound, later: 48, to: row - 48) < 1e-5 && apart(dry, sound, from: row + 96) < 1e-5)
}

@Test func itFileOfOpenMPTsIsHeardThroughItsPlugIns() throws {
    func file(madeBy tracker: [UInt8], plugIn: Bool) -> [UInt8] {
        var file = plugIn ? mptm([held], plugInPieces: [delay()], channelPlugIns: [1, 1]) : mptm([held])
        file.replaceSubrange(file.count - 4 ..< file.count, with: [0, 0, 0, 0])
        file.replaceSubrange(0x28 ..< 0x2C, with: tracker)
        return file
    }
    let openMPT = word(0x5130) + word(0x0214), impulseTracker = word(0x0214) + word(0x0200)
    let dry = try #require(try TuneLoader.load(file(madeBy: openMPT, plugIn: false), format: .it) as? ITRenderer)
    let wet = try #require(try TuneLoader.load(file(madeBy: openMPT, plugIn: true), format: .it) as? ITRenderer)
    #expect(wet.info.format == "IT" && wet.info.shortfalls.isEmpty)
    #expect(apart(stereo(dry, seconds: 0.5).left, stereo(wet, seconds: 0.5).left, later: 48) < 1e-5)
    // Written out for setting beside Impulse Tracker's own player, it is as that plays it: no plug-in.
    #expect(wet.renderRaw(frames: 9600) == dry.renderRaw(frames: 9600))
    // And a file that says Impulse Tracker made it is played as Impulse Tracker plays it, whatever else is in it.
    let own = try TuneLoader.load(file(madeBy: impulseTracker, plugIn: true), format: .it)
    let plain = try TuneLoader.load(file(madeBy: impulseTracker, plugIn: false), format: .it)
    #expect(stereo(own, seconds: 0.5).left == stereo(plain, seconds: 0.5).left)
}
