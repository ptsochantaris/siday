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
    var behaviours: [Int] = [0, 7] + Array(8 ... 48) + [50]
    var version = 0x0130_0000
    /// Whether its slides of pitch are linear, and not the Amiga's.
    var linear = true
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
///   - carry: whether a note's volume envelope carries on from where the note before had got to.
private func mptm(_ patterns: [Pattern], song: Song = Song(), orders: [UInt8]? = nil,
                  sequences: [(orders: [Int], restart: Int?, speed: Int, tempo: Int)]? = nil, samples: [Sample] = [.sound(square, loops: true)],
                  instruments: [(sample: UInt8, volumeEnvelope: [(tick: Int, level: Int)], fade: Int)] = [],
                  instrumentExtras: [(name: String, size: Int, values: [[UInt8]])] = [], patternExtras: [Int: (rowsPerBeat: Int, swing: [Int])] = [:],
                  cues: [Int: [Int]] = [:], tunings: [(name: String, steps: Int)] = [], tuned: [Int] = [], plugins: Int = 0, cutoff: UInt8 = 0,
                  temperament: [Float] = [], plugInPieces: [[UInt8]] = [], channelPlugIns: [Int] = [], parameterNotes: [Int: [UInt8]] = [:],
                  macros: [Int: String] = [:], carry: Bool = false) -> [UInt8] {
    let orders = orders ?? patterns.indices.map { UInt8($0) }
    var file = text("IMPM") + padded(text("a square wave"), to: 26) + [UInt8(song.rowsPerBeat), 16]
    file += word(orders.count) + word(instruments.count) + word(samples.count) + word(patterns.count) + word(0x0891) + word(0x0888)
    file += word((song.linear ? 0x0009 : 0x0001) | (instruments.isEmpty ? 0 : 4)) + word(macros.isEmpty ? 4 : 12)
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
            bytes += [points.isEmpty ? 0 : carry ? 9 : 1, UInt8(min(points.count, 25)), 0, 0, 0, 0]
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

/// The steepest step from one sample of a sound to the next: how sharp its edges are.
private func edge(_ samples: ArraySlice<Float>) -> Float {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

/// OpenMPT's ways of playing that the files here ask for, less some.
private func ways(without left: Int...) -> Song {
    var song = Song()
    song.behaviours.removeAll { left.contains($0) }
    return song
}

@Test func mptmThatDoesNotAskForImpulseTrackersFilterHasOpenMPTsOwn() throws {
    var options = LoadOptions()
    options.stereo = .abc
    // Z7F on a note's row sets the filter wide open. To Impulse Tracker that is no filter; to
    // OpenMPT's own, which a file has unless it asks for the other (its way of playing 36), it is
    // a filter that takes the top off the sound at five kilohertz, and a square wave's edges with it.
    let pattern = Pattern([(0, 0, .note(60, "Z", 0x7F))])
    let asked = stereo(try player(mptm([pattern]), options: options), seconds: 0.5).left
    let plain = stereo(try player(mptm([Pattern([(0, 0, .note())])]), options: options), seconds: 0.5).left
    let own = stereo(try player(mptm([pattern], song: ways(without: 36)), options: options), seconds: 0.5).left
    #expect(asked == plain)
    #expect(edge(own[4800...]) < edge(plain[4800...]) * 0.75)
    #expect(abs(loudness(own[4800...]) - loudness(plain[4800...])) < loudness(plain[4800...]) * 0.1)
    // Without the command the note has no filter in either, for its cutoff is at the top.
    #expect(stereo(try player(mptm([Pattern([(0, 0, .note())])], song: ways(without: 36)), options: options), seconds: 0.5).left == plain)

    // Set low, the two are not the same filter: OpenMPT's own lets less through about its cutoff.
    func low(_ song: Song) throws -> [Float] {
        stereo(try player(mptm([Pattern([(0, 0, .note(36))])], song: song, instruments: [(1, [], 0)], cutoff: 0x80 | 30), options: options), seconds: 0.5).left
    }
    let impulseTrackers = try low(Song()), openMPTs = try low(ways(without: 36))
    #expect(loudness(openMPTs[4800...]) < loudness(impulseTrackers[4800...]) * 0.95)
    #expect(loudness(openMPTs[4800...]) > loudness(impulseTrackers[4800...]) * 0.5)
}

@Test func mptmFilterIsMovedAtRandomFromNoteToNote() throws {
    var options = LoadOptions()
    options.stereo = .abc
    // Four notes of an instrument whose filter is set a little above them. With a random swing of
    // its cutoff ("CS..", of 64) they are not all as loud as each other; without, they are.
    let pattern = Pattern((0 ..< 4).map { (row: $0 * 4, channel: 0, cell: Cell.note()) })
    func notes(_ extras: [(name: String, size: Int, values: [[UInt8]])]) throws -> [Float] {
        let file = mptm([pattern], instruments: [(1, [], 0)], instrumentExtras: extras, cutoff: 0x80 | 30)
        #expect(try player(file).info.shortfalls.isEmpty)
        let sound = stereo(try player(file, options: options), seconds: 2).left
        // (A row is 0.12 seconds, 5760 samples.)
        return (0 ..< 4).map { loudness(sound[($0 * 4 + 1) * 5760 ..< ($0 * 4 + 3) * 5760]) }
    }
    let steady = try notes([]), swung = try notes([("CS..", 1, [[64]])])
    #expect(steady.allSatisfy { abs($0 - steady[0]) < steady[0] * 0.001 })
    #expect(swung.max()! > swung.min()! * 1.01)
    #expect(swung.allSatisfy { $0 > 0.001 })
    // What the cutoff is for each note, a quarter of the way through it: as the instrument has
    // it, and moved by as much as a half of that either way.
    func cutoffs(_ extras: [(name: String, size: Int, values: [[UInt8]])]) throws -> [UInt8] {
        let player = IT2Player(try player(mptm([pattern], instruments: [(1, [], 0)], instrumentExtras: extras, cutoff: 0x80 | 30)).module)
        var seen: [UInt8] = []
        for tick in 0 ..< 96 {
            player.Update()
            if tick % 24 == 6 { seen.append(player.FilterParameters[0]) }
        }
        return seen
    }
    #expect(try cutoffs([]) == [30, 30, 30, 30])
    let moved = try cutoffs([("CS..", 1, [[64]])])
    #expect(Set(moved).count >= 3 && moved.allSatisfy { $0 >= 15 && $0 <= 45 })
}

@Test func mptmEnvelopeCarriesOnAsTheFileAsks() throws {
    var options = LoadOptions()
    options.stereo = .abc
    // A volume envelope that grows slowly from nothing, and is to carry on from the note before.
    // The first note's key is let go, and then comes another: as Impulse Tracker has it (OpenMPT's
    // way of playing 19) the second goes on from where the first had got to, and as ModPlug Tracker
    // had it a note after one that was let go starts again.
    let envelope = [(tick: 0, level: 0), (tick: 60, level: 64), (tick: 61, level: 64)]
    let pattern = Pattern([(0, 0, .note()), (6, 0, Cell(note: 255)), (8, 0, .note())])
    func second(_ song: Song) throws -> Float {
        let sound = stereo(try player(mptm([pattern], song: song, instruments: [(1, envelope, 0)], carry: true), options: options), seconds: 1.2).left
        // (The second note's first row.)
        return loudness(sound[8 * 5760 + 600 ..< 9 * 5760])
    }
    let carried = try second(Song()), begun = try second(ways(without: 19))
    #expect(carried > 0.02)
    #expect(begun < carried * 0.3)
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
    // What it asks of four speakers is left out. (A command that bends a pitch, a macro slid over a
    // row, and the reverb, are played, and so are nothing to speak of.)
    let commands = Pattern([(0, 0, .note()), (1, 0, Cell(command: "^", value: 1)), (2, 0, .command("\\", 0x10)), (3, 0, .command("S", 0x99)),
                            (4, 0, .command("S", 0x9B))])
    let said = try player(mptm([commands])).info.shortfalls
    #expect(said == ["Its settings for four speakers and for how a note's filter starts are left out."])
}

@Test func mptmVibratoStartsFromTheTopWithEveryNote() throws {
    // OpenMPT starts a channel's vibrato from the top of its wave whenever a note is struck, where
    // Impulse Tracker does only for a vibrato on the note's own row: so a vibrato begun after a
    // note goes the same whether or not another went before it on the channel.
    func rates(_ cells: [(row: Int, channel: Int, cell: Cell)]) throws -> [Int] {
        try player(mptm([Pattern(cells)], instruments: [(1, [], 0)])).ticks(seconds: 1).map { $0.rates.max() ?? 0 }
    }
    let after = try rates([(0, 0, .note(60, "H", 0x48)), (1, 0, .command("H", 0)), (4, 0, .note()), (6, 0, .command("H", 0x48))])
    let alone = try rates([(4, 0, .note()), (6, 0, .command("H", 0x48))])
    #expect(after[24] == 8363 && Array(after[36 ..< 42]) == Array(alone[36 ..< 42]) && after[37] != 8363)
}

@Test func mptmChannelPutInTheReverbIsHeardInIt() throws {
    // A note cut on its third row: with S99 the reverb goes on after it, with S98 or without either
    // there is nothing then; and the shortfalls say nothing of it.
    func tail(_ command: UInt8?) throws -> Float {
        var cells: [(row: Int, channel: Int, cell: Cell)] = [(0, 0, .note()), (2, 0, Cell(note: 254))]
        if let command { cells[0].cell = .note(60, "S", command) }
        let renderer = try player(mptm([Pattern(cells)], instruments: [(1, [], 0)]))
        #expect(renderer.info.shortfalls.isEmpty)
        let sound = stereo(renderer, seconds: 1.5)
        return loudness(sound.left[24000 ..< 48000]) + loudness(sound.right[24000 ..< 48000])
    }
    let dry = try tail(nil), off = try tail(0x98), wet = try tail(0x99)
    #expect(dry < 0.0001 && off < 0.0001 && wet > 0.001)
}

@Test func mptmVibratoIsOpenMPTsOwnWhereTheFileAsksForIt() throws {
    // A file that does not ask for Impulse Tracker's vibratos (switch 21) has OpenMPT's own: on
    // ProTracker's wave, as deep, but begun a quarter of the way along and the other way about, so
    // that the note is at its lowest at once, where Impulse Tracker's goes up from the middle.
    func rates(itVibrato: Bool) throws -> [Int] {
        var song = Song()
        if !itVibrato { song.behaviours.removeAll { $0 == 21 } }
        let file = mptm([Pattern([(0, 0, .note(60, "H", 0x48))])], song: song, instruments: [(1, [], 0)])
        return try player(file).ticks(seconds: 0.3).map { $0.rates.max() ?? 0 }
    }
    let impulse = try rates(itVibrato: true), own = try rates(itVibrato: false)
    #expect(impulse[0] > 8363 && impulse[0] < impulse[3] && own[0] < 8363 && own[0] == own.min())
    // (Down by about as much as Impulse Tracker's goes up: half a semitone, 31 of 768ths of an octave.)
    #expect(abs(Double(own[0]) - 8363 * pow(2.0, -31.0 / 768)) < 25 && abs(Double(impulse[3]) - 8363 * pow(2.0, 32.0 / 768)) < 25)
}

@Test func mptmSampleNamedAloneTakesThePlaceOfTheOnePlaying() throws {
    // A row that names a sample and no note: Impulse Tracker starts the note again with it. OpenMPT,
    // in a file that does not ask for that (switch 11), starts nothing, and the note goes on in the
    // new sample from where it was. So a short sample named a row after the note ends a row sooner
    // than one started again; and named on a channel playing nothing, it starts nothing.
    let long = (0 ..< 8000).map { square[$0 % 32] }, short = (0 ..< 4000).map { square[$0 % 32] }
    func voices(impulseTrackers: Bool) throws -> [Int] {
        var song = Song()
        if !impulseTrackers { song.behaviours.removeAll { $0 == 11 } }
        let file = mptm([Pattern([(0, 0, .note()), (0, 1, Cell(instrument: 1)), (1, 0, Cell(instrument: 2))])], song: song,
                        samples: [.sound(long, loops: false), .sound(short, loops: false)])
        return try player(file).ticks(seconds: 1).map { $0.rates.count { $0 > 0 } }
    }
    let impulse = try voices(impulseTrackers: true), own = try voices(impulseTrackers: false)
    // (A tick is a fiftieth of a second, a row six of them, and the short sample is 0.48 seconds.
    // Impulse Tracker's way starts the other channel's note as well, which outlasts both.)
    #expect(own.max() == 1 && abs(own.count { $0 > 0 } - 24) <= 1)
    #expect(abs(impulse.count { $0 == 2 } - 30) <= 1)
}

@Test func mptmCutLeavesTheNotePlayingUnlessTheFileAsksForImpulseTrackers() throws {
    // SCx stops a note in Impulse Tracker; OpenMPT's own (switch 30 not asked for) turns it down to
    // nothing and leaves it playing, so that a volume on a later row brings it back.
    func heard(impulseTrackers: Bool) throws -> [Bool] {
        var song = Song()
        if !impulseTrackers { song.behaviours.removeAll { $0 == 30 } }
        let file = mptm([Pattern([(0, 0, .note(60, "S", 0xC2)), (2, 0, Cell(volume: 64))])], song: song)
        return try player(file).ticks(seconds: 0.5).map { $0.rates.contains { $0 > 0 } }
    }
    // (Six ticks to a row: cut on the third tick, and the volume on the thirteenth.)
    let impulse = try heard(impulseTrackers: true), own = try heard(impulseTrackers: false)
    #expect(impulse[0] && !impulse[3] && !impulse[13])
    #expect(own[0] && !own[3] && own[13])
}

@Test func mptmVibratoIsDividedTowardsNought() throws {
    // OpenMPT divides a step of a vibrato's wave times its depth towards nought, where Impulse
    // Tracker rounds it: H44 on its third tick is at a point of the wave where the two differ.
    let file = mptm([Pattern([(0, 0, .note(60, "H", 0x44))])], instruments: [(1, [], 0)])
    let rates = try player(file).ticks(seconds: 0.3).map { $0.rates.max() ?? 0 }
    let bent = Int(it2FineSineData[48]) * 16 * 4
    #expect(bent % 256 >= 128 && bent / 256 < 16)
    #expect(rates[2] == Int((UInt64(8363) * UInt64(it2FineLinearSlideUpTable[bent / 256])) >> 16))
}

@Test func mptmOfAnOlderOpenMPTKeepsItsPitchesAsPeriods() throws {
    // OpenMPT kept a note's pitch as a period, a whole number, before its version 1.24 for a song
    // with linear slides (and before 1.30 for one without), and still does for a file that does
    // not ask for pitches in Hertz (switch 7). A high note's period is small, and moves in large
    // steps: C-9's is 107, which the least slide up moves to 106; and B-9's is 56, which without
    // linear slides it takes four from. The rate is 1,712 times the sample's over the period.
    func rates(_ song: Song, _ note: UInt8) throws -> [Int] {
        let file = mptm([Pattern([(0, 0, .note(note, "F", 0xF1))])], song: song, samples: [.sound(square, loops: true)])
        return try player(file).ticks(seconds: 0.2).map { $0.rates.max() ?? 0 }
    }
    var old = Song(), asked = Song(), amiga = Song(), hertz = Song()
    old.version = 0x0123_0000
    asked.behaviours.removeAll { $0 == 7 }
    amiga.linear = false
    amiga.version = 0x0128_0000
    for song in [old, asked] { #expect(try rates(song, 108).last == (8363 * 1712 + 53) / 106) }
    #expect(try rates(amiga, 119).last == (8363 * 1712 + 26) / 52)
    // (In Hertz the slide is a sixty-fourth of a semitone, and B-9 is nearer its true pitch.)
    #expect(try rates(hertz, 108).last! < (8363 * 1712) / 106 - 500)
    hertz.linear = false
    #expect(try rates(hertz, 119).last! < (8363 * 1712) / 52 - 2000)
}

@Test func mptmFinetuneBendsTheNoteAsFarAsItsInstrumentAllows() throws {
    // The file's pitch wheel depth is two semitones, so a finetune of C0, a quarter of the way up
    // from the middle at 80, bends the note up by one; and 40 bends it down by one.
    func rates(_ cells: [(row: Int, channel: Int, cell: Cell)]) throws -> [Int] {
        var file = mptm([Pattern(cells)], instruments: [(1, [], 0)])
        file[0x35] = 2
        return try player(file).ticks(seconds: 1).map { $0.rates.max() ?? 0 }
    }
    let up = 8363 * pow(2.0, 1.0 / 12), down = 8363 / pow(2.0, 1.0 / 12)
    let bent = try rates([(0, 0, .note()), (1, 0, .command("^", 0xC0)), (2, 0, .command("^", 0x40)), (3, 0, .note()), (4, 0, .command("^", 0x80))])
    #expect(bent[0] == 8363 && abs(Double(bent[6]) - up) <= 1 && abs(Double(bent[11]) - up) <= 1 && abs(Double(bent[12]) - down) <= 1)
    // A note with its instrument named takes the bend away; and 80 is no bend at all.
    #expect(bent[18] == 8363 && bent[24] == 8363)
    // The smooth one goes a share of the way each tick, and is there at the row's end.
    let smooth = try rates([(0, 0, .note()), (1, 0, .command("_", 0xC0))])
    #expect((7 ... 11).allSatisfy { smooth[$0] > smooth[$0 - 1] } && abs(Double(smooth[11]) - up) <= 1)
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

@Test func mptmFileInAnotherTuningIsPlayedInIt() throws {
    // Nineteen equal steps to the octave, each of sixteen fine steps: a note is the sample's rate at
    // middle C by so many nineteenths of an octave.
    func rates(_ cells: [(row: Int, channel: Int, cell: Cell)], seconds: Double = 2) throws -> [Int] {
        let file = mptm([Pattern(cells)], instruments: [(1, [], 0)], tunings: [("nineteen", 19)], tuned: [1])
        let renderer = try player(file)
        #expect(renderer.info.shortfalls.isEmpty)
        return renderer.ticks(seconds: seconds).map { $0.rates.max() ?? 0 }
    }
    func near(_ rate: Int, _ wanted: Double) -> Bool { abs(Double(rate) - wanted) <= 1 }
    let step = pow(2.0, 1.0 / 19)
    let notes = try rates([(0, 0, .note(60)), (4, 0, .note(61)), (8, 0, .note(79)), (12, 0, .note(57))])
    #expect(notes[0] == 8363 && near(notes[24], 8363 * step) && near(notes[48], 8363 * 2) && near(notes[72], 8363 / pow(step, 3)))

    // F01 slides up by a fine step every tick, the first of the row among them; so a row of six
    // ticks and ten more of them (F0A) go sixteen fine steps, which is a whole step.
    let up = try rates([(0, 0, .note(60)), (1, 0, .command("F", 1)), (2, 0, .command("F", 0x0A))])
    #expect((7 ... 11).allSatisfy { up[$0] > up[$0 - 1] } && near(up[11], 8363 * pow(step, 6.0 / 16)))
    #expect(near(up[12], 8363 * pow(step, 16.0 / 16)) && up[17] > up[12])
    // FF8 goes eight fine steps over the row, a share each tick; FE3 three, at once.
    let fine = try rates([(0, 0, .note(60)), (1, 0, .command("F", 0xF8)), (2, 0, .command("F", 0xE3))])
    #expect(near(fine[11], 8363 * pow(step, 8.0 / 16)) && fine[7] < fine[11] && near(fine[12], 8363 * pow(step, 11.0 / 16)) && fine[17] == fine[12])

    // An arpeggio is by whole steps of the scale.
    let arpeggio = try rates([(0, 0, .note(60, "J", 0x35))])
    #expect(arpeggio[0] == 8363 && near(arpeggio[1], 8363 * pow(step, 3)) && near(arpeggio[2], 8363 * pow(step, 5)) && arpeggio[3] == 8363)

    // A slide to a note goes so many fine steps a row: G10 sixteen, half the way from 60 to 62.
    let slide = try rates([(0, 0, .note(60)), (1, 0, .note(62, "G", 0x10)), (2, 0, .command("G", 0))])
    #expect(slide[6] < slide[11] && near(slide[11], 8363 * step) && near(slide[17], 8363 * step * step) && slide[18] == slide[17])

    // And a vibrato moves the pitch by up to a fortieth either way at its deepest.
    let vibrato = try rates([(0, 0, .note(60, "H", 0x8F))], seconds: 0.5)
    let highest = Double(vibrato.max()!), lowest = Double(vibrato.min()!)
    #expect(highest > 8363 * 1.024 && highest <= 8363 * 1.025 + 1 && lowest < 8363 / 1.024 + 1 && lowest >= 8363 * 0.975 - 1)

    // A tuning the file carries and no instrument uses changes nothing.
    let carried = mptm([Pattern([(0, 0, .note())])], instruments: [(1, [], 0)], tunings: [("nineteen", 19)], tuned: [0])
    #expect(try player(carried).ticks(seconds: 0.1).allSatisfy { $0.rates.max() == 8363 })
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
    steps[9] *= Float(pow(2.0, 0.3 / 12)) // and an A further out than that
    let notes = Pattern([(0, 0, .note(60)), (4, 0, .note(64)), (8, 0, .note(79)), (12, 0, .note(52))])
    let file = mptm([notes], instruments: [(1, [], 0)], tunings: [("well tempered", 12)], tuned: [1], temperament: steps)
    let renderer = try player(file)
    #expect(renderer.info.shortfalls.isEmpty)
    // Each note's rate is the sample's own by what the tuning makes of the note.
    let rates = renderer.ticks(seconds: 2).enumerated().filter { $0.offset % 24 == 0 }.map { $0.element.rates.max() ?? 0 }
    let wanted = [steps[0], steps[4], steps[7] * 2, steps[4] / 2].map { 8363 * Double($0) }
    #expect(zip(rates.prefix(4), wanted).allSatisfy { abs(Double($0) - $1) <= 1 })
    #expect(rates[1] != Int((8363 * equal[4]).rounded()))
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
    // And by the same macro sent a little at a time over the row: the echo is on its way there for
    // the row's six ticks, and there from the next row on.
    let smooth = try player(mptm([Pattern(held.cells + [(4, 0, .command("\\", 0))])], plugInPieces: [delay()], channelPlugIns: [1, 1], macros: [9: "F0F080z"]))
    #expect(smooth.info.shortfalls.isEmpty)
    let slid = stereo(smooth, seconds: 1).left
    #expect(apart(dry, slid, later: 48, to: row - 48) < 1e-5)
    #expect(apart(sound, slid, from: row + 960, to: row + 5 * 960) > 0.001)
    #expect(apart(dry, slid, from: row + 6 * 960 + 96) < 1e-5)
    // The same macro again on a later row, from the other channel that goes through the echo, is
    // sent again: the echo is back to giving what it has kept.
    let twice = try player(mptm([Pattern(held.cells + [(4, 0, .command("Z", 0)), (8, 1, .command("Z", 0x7F))])],
                                plugInPieces: [delay()], channelPlugIns: [1, 1], macros: [9: "F0F080z"]))
    let back = stereo(twice, seconds: 1.5).left, longer = stereo(try player(mptm([held])), seconds: 1.5).left
    #expect(apart(longer, back, from: row + 96, to: 2 * row - 48) < 1e-5)
    #expect(apart(longer, back, later: 48, from: 2 * row + 96) < 1e-5)
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

// MARK: Voices left out

/// In stereo, so that a channel on one side can be told from a channel on the other.
private let inStereo: LoadOptions = {
    var options = LoadOptions()
    options.stereo = .abc
    return options
}()

/// A file with its first channel put all on the left and its second all on the right.
private func sided(_ file: [UInt8]) -> [UInt8] {
    var file = file
    file[0x40] = 0
    file[0x41] = 64
    return file
}

/// What a player makes of its tune from where it is, each side apart, and how loud it said each
/// voice was in it.
private func played(_ renderer: any Renderer, seconds: Double = 1) -> (left: [Float], right: [Float], levels: [Float]) {
    let sound = stereo(renderer, seconds: seconds)
    var levels = [Float](repeating: 0, count: renderer.channelCount)
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    return (sound.left, sound.right, levels)
}

private func silent(_ samples: [Float]) -> Bool { samples.allSatisfy { $0 == 0 } }

@Test func itChannelLeftOutTakesTheNotesItHasLetGoWithIt() throws {
    // An IT file of Impulse Tracker's, with an instrument. The first channel, on the left, plays a
    // note and four rows later another; the second holds a note on the right.
    let pattern = Pattern([(0, 0, .note(60)), (0, 1, .note(72)), (4, 0, .note(67))])
    /// - Parameter action: what becomes of the instrument's note when the next arrives: 0 for cut, 1 for played on.
    func renderer(action: UInt8) throws -> any Renderer {
        var file = sided(mptm([pattern], instruments: [(1, [], 0)]))
        file.replaceSubrange(file.count - 4 ..< file.count, with: [0, 0, 0, 0])
        file.replaceSubrange(0x28 ..< 0x2C, with: word(0x0214) + word(0x0200))
        file[try #require(file.firstRange(of: text("IMPI"))).lowerBound + 0x11] = action
        let renderer = try TuneLoader.load(file, format: .it, options: inStereo)
        #expect(renderer.info.format == "IT" && renderer.channelCount == 2)
        return renderer
    }
    // The second note begins on the 24th tick, of 960 frames. With the first played on beneath it
    // the channel is two voices of the mixer's from there, and is not what it is with the first cut.
    let whole = played(try renderer(action: 1)), cut = played(try renderer(action: 0))
    #expect(apart(whole.left, cut.left, to: 23040) == 0 && apart(whole.left, cut.left, from: 24000) > 0.01)
    #expect(whole.right == cut.right && loudness(whole.right[...]) > 0.01)

    // The channel left out: neither of its notes is heard, the other channel is what it was to the
    // last bit, and the channel is said to be as loud as ever.
    let without = try renderer(action: 1)
    without.setMuted([true, false])
    let rest = played(without)
    #expect(silent(rest.left) && rest.right == whole.right && rest.levels == whole.levels && rest.levels[0] > 0.05)

    // Left out once the second note has begun, with the first ringing on: both are gone from the
    // next tick. Brought back later, both are where they would have been.
    let late = try renderer(action: 1)
    let before = played(late, seconds: 0.5)
    late.setMuted([true])
    let during = played(late, seconds: 0.3)
    late.setMuted([])
    let after = played(late, seconds: 0.2)
    #expect(before.left == Array(whole.left[..<24000]) && silent(during.left) && after.left == Array(whole.left[38400...]))
    #expect(loudness(after.left[...]) > 0.01 && before.right + during.right + after.right == whole.right)
}

@Test func mptmChannelLeftOutLeavesNothingBehindWhenItsSampleEnds() throws {
    // A square wave that does not go round ends where it is loudest, and what it last put out dies
    // away over the ticks after it. That is its channel's sound too, and goes with it; as it does
    // when the channel is sent through a plug-in.
    let pattern = Pattern([(0, 0, .note(60, instrument: 1)), (0, 1, .note(72, instrument: 2))])
    for wired in [false, true] {
        func renderer() throws -> ITRenderer {
            try player(sided(mptm([pattern], samples: [.sound(square, loops: false), .sound(square, loops: true)],
                                  plugInPieces: wired ? [delay()] : [], channelPlugIns: wired ? [1, 0] : [])), options: inStereo)
        }
        let whole = played(try renderer(), seconds: 0.2)
        #expect(abs(whole.left[2000]) > 0.001 && abs(whole.left[2001]) < abs(whole.left[2000]))
        let without = try renderer()
        without.setMuted([true, false])
        let rest = played(without, seconds: 0.2)
        #expect(silent(rest.left) && rest.right == whole.right && rest.levels == whole.levels)
    }
}

@Test func mptmChannelLeftOutIsLeftOffTheFMChipToo() throws {
    // The first channel plays the FM chip: a note, another four rows later while the first is let
    // go and still sounding (two of the chip's voices), and a cut, which leaves the chip a little
    // of the note to die away. The second channel plays a sample.
    let chip: [(row: Int, channel: Int, cell: Cell)] = [(0, 0, .note(60, instrument: 1)), (4, 0, .note(67, instrument: 1)), (8, 0, Cell(note: 254))]
    let sample: [(row: Int, channel: Int, cell: Cell)] = [(0, 1, .note(72, instrument: 2))]
    func renderer(_ cells: [(row: Int, channel: Int, cell: Cell)]) throws -> ITRenderer {
        var file = mptm([Pattern(cells)], song: fmSong, samples: [.fm, .sound(square, loops: true)],
                        instruments: [(1, [(0, 64), (10, 64), (40, 0)], 64), (2, [], 0)])
        file[try #require(file.firstRange(of: text("IMPI"))).lowerBound + 0x11] = 2 // the first instrument's "new note action": note off
        return try player(file, options: inStereo)
    }
    let whole = played(try renderer(chip + sample)), chipAlone = played(try renderer(chip)), sampleAlone = played(try renderer(sample))
    #expect(loudness(chipAlone.left[...]) > 0.005 && loudness(sampleAlone.left[...]) > 0.005)
    #expect(whole.levels.count == 2 && whole.levels[0] > 0.05 && whole.levels[1] > 0.05)

    // With the chip's channel left out, what is heard is the tune without that channel's notes, to
    // the last bit; and the same for the sample's. Either is said to be as loud as when it is heard.
    let noChip = try renderer(chip + sample)
    noChip.setMuted([true, false])
    let rest = played(noChip)
    #expect(rest.left == sampleAlone.left && rest.right == sampleAlone.right && rest.levels == whole.levels)
    let noSample = try renderer(chip + sample)
    noSample.setMuted([false, true])
    let other = played(noSample)
    #expect(other.left == chipAlone.left && other.right == chipAlone.right && other.levels == whole.levels)

    // Both left out is silence, and a song started again is started without them.
    let neither = try renderer(chip + sample)
    neither.setMuted([true, true])
    let nothing = played(neither)
    #expect(silent(nothing.left) && silent(nothing.right) && nothing.levels == whole.levels)
    noChip.select(subsong: 0)
    #expect(played(noChip).left == sampleAlone.left)
    noChip.setMuted([])
    noChip.select(subsong: 0)
    #expect(played(noChip).left == whole.left)
}

@Test func mptmChannelLeftOutIsNotSentToItsPlugIn() throws {
    // Two channels, each a note, and the first another later. Beside it the same with the second
    // channel's note at no volume: what the tune is without that channel.
    let alone = Pattern([(0, 0, .note(60)), (0, 1, .note(67, volume: 0)), (8, 0, .note(64))])
    // Both channels through one plug-in; with some of what it is given heard beside what it makes;
    // through two, one after the other; a plug-in on the whole sound; and one that only the channel
    // left out is sent through.
    let wirings: [(pieces: [[UInt8]], channels: [Int])] = [
        ([delay()], [1, 1]), ([delay(dry: 0.25, gain: 20)], [1, 1]), ([delay(output: 0x81), delay()], [1, 1]), ([delay(flags: 1)], []), ([delay()], [0, 1]),
    ]
    for wiring in wirings {
        func renderer(_ pattern: Pattern) throws -> ITRenderer {
            try player(mptm([pattern], plugInPieces: wiring.pieces, channelPlugIns: wiring.channels), options: inStereo)
        }
        let whole = played(try renderer(held)), expected = played(try renderer(alone))
        #expect(apart(whole.left, expected.left) > 0.01)
        let without = try renderer(held)
        without.setMuted([false, true])
        let rest = played(without)
        #expect(rest.left == expected.left && rest.right == expected.right)
        #expect(rest.levels == whole.levels && rest.levels[1] > 0.05)
        // And with both left out the plug-in is given nothing, and gives nothing.
        without.setMuted([true, true])
        without.select(subsong: 0)
        let nothing = played(without)
        #expect(silent(nothing.left) && silent(nothing.right))
    }
}

@Test func mptmInstrumentTiedToTheTempoIsAsMuchHigherAsTheSongIsFaster() throws {
    // An instrument tied to 125 beats a minute and a quarter (its whole part, and its ten-thousandths
    // under a name written the other way round), in a song at 150: a fifth again as fast as it would be.
    let note = Pattern([(0, 0, .note(60))])
    var song = Song()
    song.tempo = 150
    let plain = try player(mptm([note], song: song, instruments: [(1, [], 0)]))
    let tied = try player(mptm([note], song: song, instruments: [(1, [], 0)],
                               instrumentExtras: [("PTTL", 2, [word(125)]), ("FTTP", 2, [word(2500)])]))
    #expect(plain.info.shortfalls.isEmpty && tied.info.shortfalls.isEmpty)
    let low = crossings(stereo(plain, seconds: 1).left[4800 ..< 43200])
    let high = crossings(stereo(tied, seconds: 1).left[4800 ..< 43200])
    #expect(low > 100)
    #expect(abs(Double(high) / Double(low) - 150.0 / 125.25) < 0.01)
}
