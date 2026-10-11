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
private func mptm(_ patterns: [Pattern], song: Song = Song(), orders: [UInt8]? = nil,
                  sequences: [(orders: [Int], restart: Int?, speed: Int, tempo: Int)]? = nil, samples: [Sample] = [.sound(square, loops: true)],
                  instruments: [(sample: UInt8, volumeEnvelope: [(tick: Int, level: Int)], fade: Int)] = [],
                  instrumentExtras: [(name: String, size: Int, values: [[UInt8]])] = [], patternExtras: [Int: (rowsPerBeat: Int, swing: [Int])] = [:],
                  cues: [Int: [Int]] = [:], tunings: [(name: String, steps: Int)] = [], tuned: [Int] = [], plugins: Int = 0, cutoff: UInt8 = 0) -> [UInt8] {
    let orders = orders ?? patterns.indices.map { UInt8($0) }
    var file = text("IMPM") + padded(text("a square wave"), to: 26) + [UInt8(song.rowsPerBeat), 16]
    file += word(orders.count) + word(instruments.count) + word(samples.count) + word(patterns.count) + word(0x0891) + word(0x0888)
    file += word(0x0009 | (instruments.isEmpty ? 0 : 4)) + word(4)
    file += [128, 48, UInt8(song.speed), UInt8(min(song.tempo, 255)), 128, 0] + word(0) + long(0) + text("OMPT")
    file += [UInt8](repeating: 32, count: 64) + [UInt8](repeating: 64, count: 64)
    #expect(file.count == 192)
    file += orders

    // The plug-ins, which are named between the header and what its lists point at.
    var pluginChunks: [UInt8] = []
    for plugin in 0 ..< plugins {
        let info = long(0x5653_5450) + long(0x1234_0000 + plugin) + [UInt8](repeating: 0, count: 120)
        pluginChunks += text("FX0\(plugin)") + long(info.count + 8) + info + long(0) + long(0)
    }

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
            (name: text("2"), data: chunk("CTB244RTI", [(text("0"), adaptive(tuning.name.utf8.count) + text(tuning.name)), (text("2"), word(3)), (text("4"), long(15)),
                                                        (text("RTI1"), word(0x10000 - 64)), (text("RTI2"), word(tuning.steps)),
                                                        (text("RTI3"), long(Int(Float(2).bitPattern))), (text("RTI4"), word(128))]))
        }
        items.append((text("0"), chunk("TC", all)))
        var map = word(tunings.count)
        for (index, tuning) in tunings.enumerated() { map += [UInt8(tuning.name.utf8.count)] + text(tuning.name) + word(index + 1) }
        for which in tuned { map += word(which) }
        items.append((text("1"), map))
    }
    if !patternExtras.isEmpty {
        var all: [(name: [UInt8], data: [UInt8])] = patternExtras.sorted(by: { $0.key < $1.key }).map { index, extra in
            var parts: [(name: [UInt8], data: [UInt8])] = [(text("RPB."), long(extra.rowsPerBeat)), (text("RPM."), long(extra.rowsPerBeat * 4))]
            if !extra.swing.isEmpty { parts.append((text("SWNG"), word(extra.swing.count) + extra.swing.flatMap(long))) }
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
    // Three instruments: a sample's, a plug-in's and an FM patch; and a second plug-in that is an effect.
    let pattern = Pattern((0 ..< 8).map { (row: $0, channel: 0, cell: Cell.note(60, instrument: $0 == 2 ? 2 : $0 == 5 ? 3 : 1)) })
    let file = mptm([pattern], samples: [.sound(square, loops: true), .fm], instruments: [(1, [], 0), (0, [], 0), (2, [], 0)],
                    instrumentExtras: [("MiP.", 1, [[0], [1], [0]])], plugins: 2)
    let renderer = try player(file)
    #expect(renderer.info.shortfalls == ["One of its instruments plays through a plug-in, and is not heard.",
                                    "One of its instruments is for the AdLib's FM chip, and is not heard.",
                                    "Two plug-ins are left out, and it is heard without what they do to its sound."])
    #expect(renderer.info.detail == "OpenMPT 1.30.00")
    // What is said is only what the file uses.
    let unused = mptm([Pattern([(0, 0, .note())])], samples: [.sound(square, loops: true), .fm], instruments: [(1, [], 0), (2, [], 0)])
    #expect(try player(unused).info.shortfalls.isEmpty)
    // A command that bends a pitch is taken out, and a macro slid over a row is sent at once.
    let commands = Pattern([(0, 0, .note()), (1, 0, Cell(command: "^", value: 1)), (2, 0, .command("\\", 0x10)), (3, 0, .command("S", 0x99))])
    let said = try player(mptm([commands])).info.shortfalls
    #expect(said == ["Where it slides its filter over a row, the filter is moved in one step at the row's start.",
                     "One command that bends a note's pitch is left out.", "Its reverb is left out."])
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
    // Half its notes are for a plug-in, or for the FM chip, or for a sample that is not in the file.
    let pattern = Pattern((0 ..< 8).map { (row: $0, channel: 0, cell: Cell.note(60, instrument: $0 % 2 == 0 ? 2 : 1)) })
    let plugin = mptm([pattern], instruments: [(1, [], 0), (0, [], 0)], instrumentExtras: [("MiP.", 1, [[0], [1]])], plugins: 1)
    #expect(refusal(plugin) == "unsupported: an MPTM file that is mostly for plug-ins")
    let fm = mptm([pattern], samples: [.sound(square, loops: true), .fm], instruments: [(1, [], 0), (2, [], 0)])
    #expect(refusal(fm) == "unsupported: an MPTM file that is mostly for the AdLib's FM chip")
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
