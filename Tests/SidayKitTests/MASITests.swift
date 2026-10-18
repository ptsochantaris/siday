// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Epic MegaGames' MASI files, which Scream Tracker 3's replayer plays, and which share
// their name, PSM, with Pro Sound Maker's for the ZX Spectrum. The thorough check is made outside the
// package, against libopenmpt: every sample's sound, and every channel's pitch, volume and place on
// every tick of every song of each file to hand, and what is heard.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { Array((bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count))).prefix(length)) }
private func text(_ string: String, _ length: Int) -> [UInt8] { padded(Array(string.utf8), to: length) }
private func chunk(_ tag: String, _ body: [UInt8]) -> [UInt8] { Array(tag.utf8) + long(body.count) + body }

/// One channel's part of a row: a note (0x40 is C-4 in the newer kind, which plays a sample at its own
/// rate), a sample counted from nought, a volume of 127 and a command by MASI's numbers.
private struct Cell {
    var note: UInt8?, sample: UInt8?, volume: UInt8?
    var command: (UInt8, UInt8)?

    static func note(_ note: UInt8 = 0x40, _ sample: UInt8 = 0, _ command: (UInt8, UInt8)? = nil) -> Cell {
        Cell(note: note, sample: sample, command: command)
    }
}

/// A sample: a square wave of 32 samples at 8,363 samples a second, so that C-4 is 261 Hz, looped.
private struct Sound {
    var bytes: [UInt8] = (0 ..< 32).map { $0 < 16 ? 0x7F : 0x81 }
    var loops = true
    var rate = 8363
}

/// A song: its name, its patterns, speed and tempo, the place it goes back to, and each channel's
/// place and kind (0 a place, 2 surround, 4 the middle).
private struct Song {
    var name = "MAINSONG"
    var orders = [0]
    var speed = 6, tempo = 125
    var restart: Int?
    var places: [(UInt8, UInt8)] = [(0x80, 0), (0x7F, 0)]
}

private typealias Pattern = [(row: Int, channel: Int, cell: Cell)]

/// A file of the newer kind; Sinaria's, if asked.
private func newer(_ patterns: [Pattern], songs: [Song] = [Song()], sounds: [Sound] = [Sound()], sinaria: Bool = false) -> [UInt8] {
    var body = Array("FILE".utf8) + chunk("SDFT", Array("MAINSONG".utf8))
    func patternName(_ number: Int) -> [UInt8] { sinaria ? Array("PATT".utf8) + text("\(number)", 4) : text("P\(number)", 4) }
    for song in songs {
        var program: [UInt8] = [0x0C, 0, 0xFF, 0, 0, 1, 0, 0x07, UInt8(song.speed), 0x08, UInt8(song.tempo)]
        var count = 3
        if !sinaria {
            for (channel, place) in song.places.enumerated() { program += [0x0D, UInt8(channel), place.0, place.1] }
            count += song.places.count
        }
        let first = count
        for order in song.orders { program += [0x01] + patternName(order) }
        count += song.orders.count
        if let restart = song.restart { program += [0x04] + word(first + restart) }
        program.append(0)
        var parts = chunk("OPLH", word(count) + program)
        if sinaria { parts += chunk("PPAN", song.places.flatMap { [$0.1, $0.0] }) }
        body += chunk("SONG", text(song.name, 9) + [1, UInt8(song.places.count)] + parts)
    }
    for (number, cells) in patterns.enumerated() {
        var rows: [UInt8] = []
        for row in 0 ..< 64 {
            var bytes: [UInt8] = []
            for (_, channel, cell) in cells.filter({ $0.row == row }) {
                var flag: UInt8 = 0
                if cell.note != nil { flag |= 0x80 }
                if cell.sample != nil { flag |= 0x40 }
                if cell.volume != nil { flag |= 0x20 }
                if cell.command != nil { flag |= 0x10 }
                bytes += [flag, UInt8(channel)] + [cell.note, cell.sample, cell.volume].compactMap { $0 }
                if let (command, value) = cell.command { bytes += [command, value] + (command == 0x29 ? [0, 0] : []) }
            }
            rows += word(bytes.count + 2) + bytes
        }
        let inner = patternName(number) + word(64) + rows
        body += chunk("PBOD", long(inner.count + 4) + inner)
    }
    for (number, sound) in sounds.enumerated() {
        var differences: [UInt8] = []
        var last: UInt8 = 0
        for byte in sound.bytes {
            differences.append(byte &- last)
            last = byte
        }
        let header: [UInt8]
        if sinaria {
            header = [sound.loops ? 0x80 : 0] + text("SQUARE", 8) + text("INS\(number)", 8) + text("square", 33) + [0, 0, 0, 0, 0, 0xFF] + word(number)
                + long(sound.bytes.count) + long(0) + long(sound.bytes.count) + word(0) + [0, 127] + long(0) + word(sound.rate) + [UInt8](repeating: 0, count: 16)
        } else {
            header = [sound.loops ? 0x80 : 0] + text("SQUARE", 8) + text("INS\(number)", 4) + text("square", 33) + [0, 0, 0, 0, 0, 0xFF] + word(number)
                + long(sound.bytes.count) + long(0) + long(sound.bytes.count - 1) + [0, 0, 127] + long(0) + long(sound.rate) + [UInt8](repeating: 0, count: 19)
        }
        body += chunk("DSMP", header + differences)
    }
    return Array("PSM ".utf8) + long(body.count) + body
}

/// A file of the older kind, of one song.
private func older(_ cells: Pattern, channels: Int = 2, pans: [UInt8] = [15, 0], sound: Sound = Sound(), flags: UInt8 = 0x80) -> [UInt8] {
    var pattern: [UInt8] = []
    for row in 0 ..< 64 {
        for (_, channel, cell) in cells.filter({ $0.row == row }) {
            var flag = UInt8(channel)
            if cell.note != nil { flag |= 0x80 }
            if cell.volume != nil { flag |= 0x40 }
            if cell.command != nil { flag |= 0x20 }
            pattern += [flag]
            if let note = cell.note { pattern += [note, cell.sample ?? 0] }
            if let volume = cell.volume { pattern.append(volume) }
            if let (command, value) = cell.command { pattern += [command, value] }
        }
        pattern.append(0)
    }
    let patternBytes = padded(word(pattern.count + 4) + [64, UInt8(channels)] + pattern, to: (pattern.count + 4 + 15) & ~15)
    let orderAt = 146 + 4, panAt = orderAt + 1 + 4, sampleAt = panAt + channels + 4, patternAt = sampleAt + 64 + 4, soundAt = patternAt + patternBytes.count
    var header = Array("PSM".utf8) + [0xFE] + text("an old square", 59) + [0x1A, 0, 0x10, 0, 6, 125, 64]
    header += word(1) + word(1) + word(1) + word(1) + word(channels) + word(channels)
    header += long(orderAt) + long(panAt) + long(patternAt) + long(sampleAt) + long(0) + long(patternBytes.count) + [UInt8](repeating: 0, count: 40)
    var differences: [UInt8] = []
    var last: UInt8 = 0
    for byte in sound.bytes {
        differences.append(byte &- last)
        last = byte
    }
    let sample = text("SQUARE.SMP", 13) + text("square", 24) + long(soundAt) + long(0) + word(1) + [flags] + long(sound.bytes.count) + long(0)
        + long(sound.bytes.count) + [0x70, 64] + word(sound.rate)
    return header + Array("PORD".utf8) + [0] + Array("PPAN".utf8) + pans + Array("PSAH".utf8) + sample + Array("PPAT".utf8) + patternBytes + differences
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

private func heard(_ file: [UInt8], seconds: Double = 1, mono: Bool = false) throws -> (left: [Float], right: [Float]) {
    var options = LoadOptions()
    options.stereo = mono ? .mono : .abc
    return stereo(try TuneLoader.load(file, format: .psm, options: options), seconds: seconds)
}

@Test func masiFilesAreToldFromProSoundMakersByHowTheyBegin() throws {
    let file = newer([[(0, 0, .note())]])
    #expect(TuneFormat(fileExtension: "PSM") == .psm && TuneFormat(fileExtension: "masi") == nil)
    #expect(TuneFormat.psm.refined(byLeading: Array(file.prefix(TuneFormat.leadingBytes))) == .masi)
    #expect(TuneFormat.psm.refined(byLeading: Array(older([]).prefix(TuneFormat.leadingBytes))) == .masi)
    #expect(TuneFormat.masi.chapter == "MASI" && TuneFormat.psm.chapter == "PT3")
    // Pro Sound Maker's begin with four pointers, and are not taken for these; nor is a file that only
    // begins with the letters.
    #expect(TuneFormat.psm.refined(byLeading: [0x0C, 0x00, 0x40, 0x01, 0x80, 0x01, 0x90, 0x01] + text("psm1", 56)) == .psm)
    #expect(TuneFormat.psm.refined(byLeading: Array("PSM ".utf8) + [UInt8](repeating: 0, count: 60)) == .psm)
    #expect(TuneFormat.dsm.refined(byLeading: Array(file.prefix(64))) == .dsm)
}

@Test func masiNoteSoundsAtItsPitchAndInItsPlace() throws {
    let file = newer([[(0, 0, .note())]])
    let renderer = try TuneLoader.load(file, format: .psm)
    #expect(renderer.info.format == "MASI" && renderer.info.shortfalls.isEmpty && renderer.subsongCount == 1)
    #expect(abs(crossings(try heard(file).left[4800...]) * 10 / 9 - 261) <= 2)
    #expect(abs(crossings(try heard(newer([[(0, 0, .note(0x50))]])).left[4800...]) * 10 / 9 - 523) <= 3)
    // Each channel where its song puts it: the first to the left, the second to the right.
    let left = try heard(file), right = try heard(newer([[(0, 1, .note())]]))
    #expect(loudness(left.left[4800...]) > loudness(left.right[4800...]) * 2)
    #expect(loudness(right.right[4800...]) > loudness(right.left[4800...]) * 2)
}

@Test func masiChannelInSurroundIsUpsideDownOnOneSide() throws {
    var song = Song()
    song.places = [(0, 2), (0, 0)]
    let file = newer([[(0, 0, .note())]], songs: [song])
    let both = try heard(file)
    #expect(loudness(both.left[4800...]) > 0.01)
    let sum = zip(both.left[4800...], both.right[4800...]).map { $0 + $1 }
    #expect(loudness(sum[...]) < loudness(both.left[4800...]) * 0.05)
    // Heard as one, it is in the middle, and not lost.
    #expect(loudness(try heard(file, mono: true).left[4800...]) > 0.01)
    #expect(try TuneLoader.load(file, format: .psm).info.shortfalls.isEmpty)
}

@Test func masiSongsEachKeepTheirOwnSettings() throws {
    // Two songs: the second of two patterns, faster, going back to its second when it ends.
    var second = Song(name: "BONUS1XX", orders: [1, 2], speed: 3, tempo: 150, restart: 1)
    second.places = [(0x7F, 0), (0x80, 0)]
    let file = newer([[(0, 0, .note())], [(0, 0, .note())], [(0, 0, .note(0x50))]], songs: [Song(), second])
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try TuneLoader.load(file, format: .psm, options: options)
    #expect(renderer.subsongCount == 2 && renderer.songs.map(\.title) == ["MAINSONG", "BONUS1XX"])
    // The first song is a pattern at speed 6 and tempo 125; the second two at speed 3 and tempo 150.
    #expect(abs((renderer.songs[0].length ?? 0) - 64 * 6 / 50) < 0.05)
    #expect(abs((renderer.songs[1].length ?? 0) - 128 * 3 / 60) < 0.05)
    let read = try MASIFile.read(file)
    #expect(read.songs.map(\.start) == [0, 2] && read.songs.map(\.restart) == [0, 3])
    #expect(read.songs.map { $0.pans[0] } == [0x20, 0x2F])
    // At its end it goes back to its own second pattern, and not to the top of the file.
    let module = try ST3Module(read.s3m)
    module.songs = read.songs
    let player = ST3Player(module, card: .gus, order: 2)
    #expect(player.zchn[0].apanpos == 0xFF && player.musicmax == 3 && player.tempo == 150)
    for _ in 0 ..< 128 * 3 + 1 { player.tick() }
    #expect(player.np_ord - 1 == 3)
    // The second song's first channel is on the right.
    renderer.select(subsong: 1)
    let sound = stereo(renderer, seconds: 0.5)
    #expect(loudness(sound.right[4800...]) > loudness(sound.left[4800...]) * 2)
}

@Test func masiCommandsAreReadAsOpenMPTReadsThem() throws {
    // A note cut at once (SC0) is silence, as OpenMPT has it, where Scream Tracker would play on.
    #expect(loudness(try heard(newer([[(0, 0, .note(0x40, 0, (0x2B, 0)))]])).left[4800...]) < 0.0001)
    // (SC4, a cut on the fourth tick, is Scream Tracker's, which stops the sample where it is.)
    #expect(crossings(try heard(newer([[(0, 0, .note(0x40, 0, (0x2B, 4)))]])).left[9600...]) == 0)
    // A volume of 63 of 127 is half.
    let half = Cell(note: 0x40, sample: 0, volume: 63)
    let ratio = loudness(try heard(newer([[(0, 0, half)]])).left[4800...]) / loudness(try heard(newer([[(0, 0, .note())]])).left[4800...])
    #expect(ratio > 0.4 && ratio < 0.6)
    // Speed (3D) and pattern break (34) together: a pattern of one row of speed 3, played twice.
    let file = newer([[(0, 0, .note(0x40, 0, (0x3D, 3))), (0, 1, Cell(command: (0x34, 0x10)))]])
    #expect(abs((try TuneLoader.load(file, format: .psm).knownLength ?? 0) - 3.0 / 50) < 0.01)
}

@Test func sinariaFilesAndOlderFilesAreRead() throws {
    // Sinaria's: its notes counted three octaves lower, so that 25 plays a sample at its own rate.
    let sinaria = newer([[(0, 0, .note(25))]], songs: [Song()], sinaria: true)
    #expect(abs(crossings(try heard(sinaria).left[4800...]) * 10 / 9 - 261) <= 2)
    // The older kind: its notes counted so too, its samples as differences, and fifteen to the left.
    let old = older([(0, 0, .note(25, 1))])
    let renderer = try TuneLoader.load(old, format: .psm)
    #expect(renderer.info.title == "an old square" && renderer.info.shortfalls.isEmpty)
    let sound = try heard(old)
    #expect(abs(crossings(sound.left[4800...]) * 10 / 9 - 261) <= 2)
    #expect(loudness(sound.left[4800...]) > loudness(sound.right[4800...]) * 2)
    let module = try ST3Module(MASIFile.read(old).s3m)
    #expect((0 ..< 4).map { module.samples[module.ins[0].baseptr + $0] } == [0x7F00, 0x7F00, 0x7F00, 0x7F00])
    #expect(module.samples[module.ins[0].baseptr + 16] == -0x7F00)
    // A loop that goes back and forth is said to be played forwards.
    #expect(try TuneLoader.load(older([(0, 0, .note(25, 1))], flags: 0xA0), format: .psm).info.shortfalls.count == 1)
}

@Test func masiDamagedFilesDoNotTrap() throws {
    var song = Song(orders: [0, 1], restart: 1)
    song.places = [(0, 2), (0x40, 0)]
    for whole in [newer([[(0, 0, .note(0x40, 0, (0x29, 0)))], [(3, 1, .note(0x32, 1, (0x0F, 0x10)))]], songs: [song, Song()], sounds: [Sound(), Sound(loops: false)]),
                  newer([[(0, 0, .note(25))]], sinaria: true), older([(0, 0, .note(25, 1, (0x0E, 4))), (4, 1, .note(32, 1))])] {
        for length in stride(from: 0, to: whole.count, by: 7) {
            if let renderer = try? TuneLoader.load(Array(whole[..<length]), format: .psm) { _ = stereo(renderer, seconds: 0.05) }
        }
        var seed: UInt32 = 1
        for _ in 0 ..< 200 {
            var damaged = whole
            for _ in 0 ..< 4 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                damaged[Int(seed >> 8) % damaged.count] = UInt8(truncatingIfNeeded: seed >> 24)
            }
            if let renderer = try? TuneLoader.load(damaged, format: .psm) { _ = stereo(renderer, seconds: 0.05) }
        }
    }
}
