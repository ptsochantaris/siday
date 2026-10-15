// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the DMF files that Impulse Tracker's replayer plays as X-Tracker's. The thorough
// check is made outside the package, against libopenmpt: what each file's samples and patterns are
// read as, and every channel's pitch, volume and place on every tick of each file to hand.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count)) }
private func chunk(_ letters: String, _ body: [UInt8]) -> [UInt8] { Array(letters.utf8) + long(body.count) + body }

/// One channel's part of a row: a note (1 is the lowest C, 37 middle C), an instrument, a volume of
/// 255, and a command for each of the three columns (the sample's, the note's and the volume's),
/// each a number and a value.
private struct Cell {
    var note: UInt8 = 0, instrument: UInt8 = 0, volume: UInt8?
    var sample: (UInt8, UInt8)?, pitch: (UInt8, UInt8)?, loudness: (UInt8, UInt8)?

    static func note(_ note: UInt8 = 37, instrument: UInt8 = 1, volume: UInt8? = nil, sample: (UInt8, UInt8)? = nil, pitch: (UInt8, UInt8)? = nil,
                     loudness: (UInt8, UInt8)? = nil) -> Cell {
        Cell(note: note, instrument: instrument, volume: volume, sample: sample, pitch: pitch, loudness: loudness)
    }

    /// As a track has it: what follows, and then each that is there.
    var bytes: [UInt8] {
        var what: UInt8 = 0, rest: [UInt8] = []
        if instrument != 0 { what |= 0x40; rest.append(instrument) }
        if note != 0 { what |= 0x20; rest.append(note) }
        if let volume { what |= 0x10; rest.append(volume) }
        if let sample { what |= 0x08; rest += [sample.0, sample.1] }
        if let pitch { what |= 0x04; rest += [pitch.0, pitch.1] }
        if let loudness { what |= 0x02; rest += [loudness.0, loudness.1] }
        return [what] + rest
    }
}

/// A sample: a square wave of 32 samples, signed, eight bits, at 8,363 samples a second for middle C,
/// going round from its start while its key is held.
private struct Sound {
    var frames: [Int8] = (0 ..< 32).map { $0 < 16 ? 127 : -127 }
    var loops = true
    var rate = 8363
    var volume: UInt8 = 255
    /// Its bytes in the file and the flag that says so, if they are packed.
    var packed: [UInt8]?
}

/// A DMF file of X-Tracker's own version of one or more patterns of 64 rows, each a list of cells,
/// and of commands on the tempo's track (a number and a value) by their rows.
private func dmf(_ patterns: [[(row: Int, channel: Int, cell: Cell)]], tempos: [[Int: (UInt8, UInt8)]] = [], channels: Int = 2, orders: [Int] = [0],
                 sounds: [Sound] = [Sound()]) -> [UInt8] {
    var file = Array("DDMF".utf8) + [8] + Array("XTRACKER".utf8)
    file += padded(Array("a square wave".utf8), to: 30) + padded(Array("somebody".utf8), to: 20) + [15, 10, 95]
    file += chunk("SEQU", word(0) + word(orders.count - 1) + orders.flatMap { word($0) })

    var patt = word(patterns.count) + [UInt8(channels)]
    for (number, pattern) in patterns.enumerated() {
        var data: [UInt8] = []
        for row in 0 ..< 64 {
            if let tempo = number < tempos.count ? tempos[number][row] : nil { data += [tempo.0, tempo.1] } else { data.append(0) }
            // (Channel 0 is the tempo's track: the tracks of notes are 1 and on.)
            for channel in 1 ... channels {
                data += pattern.first { $0.row == row && $0.channel == channel }?.cell.bytes ?? [0]
            }
        }
        patt += [UInt8(channels), 0] + word(64) + long(data.count) + data
    }
    file += chunk("PATT", patt)

    var smpi: [UInt8] = [UInt8(sounds.count)], smpd: [UInt8] = []
    for sound in sounds {
        let flags: UInt8 = (sound.loops ? 1 : 0) | (sound.packed != nil ? 4 : 0)
        smpi += [6] + Array("square".utf8) + long(sound.frames.count) + long(0) + long(sound.frames.count) + word(sound.rate) + [sound.volume, flags]
        smpi += padded([], to: 8) + padded([], to: 6)
        let bytes = sound.packed ?? sound.frames.map { UInt8(bitPattern: $0) }
        smpd += long(bytes.count) + bytes
    }
    file += chunk("SMPI", smpi) + chunk("SMPD", smpd) + Array("ENDE".utf8)
    return file
}

private func load(_ file: [UInt8]) throws -> ITRenderer {
    try #require(try TuneLoader.load(file, format: .dmf) as? ITRenderer)
}

/// What a channel's voice is at on each of so many ticks: samples a second, its note's own volume of
/// 64, and whether it is sounding.
private func ticks(_ file: [UInt8], _ count: Int, channel: Int = 1) throws -> [(rate: Int, own: Int, sounding: Bool)] {
    let player = IT2Player(try load(file).module, forSound: true)
    return (0 ..< count).map { _ in
        player.Update()
        defer { _ = player.mixer.mixTick() }
        guard let voice = player.hChn[channel].SlaveChnPtr, voice.pointee.Flags & SF_CHAN_ON != 0, voice.pointee.Flags & SF_NOTE_STOP == 0 else { return (0, 0, false) }
        return (Int(voice.pointee.Frequency), Int(voice.pointee.Vol), true)
    }
}

@Test func dmfNoteSoundsAtItsPitch() throws {
    #expect(TuneFormat(fileExtension: "DMF") == .dmf && TuneFormat.dmf.chapter == "DMF")
    let renderer = try load(dmf([[(0, 1, .note())]]))
    #expect(renderer.info.format == "DMF" && renderer.info.title == "a square wave" && renderer.info.author == "somebody")
    #expect(renderer.info.detail == "X-Tracker" && renderer.info.shortfalls.isEmpty)
    // The first channel is the tempo's track; a sample's rate is for middle C, and an octave up is twice it.
    #expect(try ticks(dmf([[(0, 1, .note())]]), 1)[0].rate == 8363)
    #expect(try ticks(dmf([[(0, 1, .note(49))]]), 1)[0].rate == 16726)
    #expect(try ticks(dmf([[(0, 1, .note(37, volume: 128))]]), 1)[0].own == 32)
}

@Test func dmfTempoIsMadeOfASpeedAndATempo() throws {
    // Thirty-two quarters of a row a second is as near as can be 12 ticks a row at a tempo of 240.
    let player = IT2Player(try load(dmf([[(0, 1, .note())]], tempos: [[0: (1, 31)]])).module, forSound: true)
    player.Update()
    #expect(player.CurrentSpeed == 12 && player.Tempo == 240)
}

@Test func dmfSampleLoopsUntilItsKeyIsLetGo() throws {
    let held = try ticks(dmf([[(0, 1, .note())]]), 60)
    #expect(held.allSatisfy { $0.sounding })
    // The sample's command 2 lets the loop go: the sample plays to its end, which at 8,363 a second
    // and 32 samples is soon.
    let letGo = try ticks(dmf([[(0, 1, .note()), (1, 1, Cell(sample: (2, 0)))]]), 60)
    #expect(letGo[3].sounding && !letGo[59].sounding)
}

@Test func dmfPackedSampleIsUnpacked() throws {
    // A tree of three: a root with nought, and below it 1 to the left and 2 to the right; then three
    // differences, +1, +2 and -2 (that is, 1 turned over), each a sign and one turn.
    var bits: [Bool] = []
    func put(_ value: Int, _ count: Int) { for k in 0 ..< count { bits.append(value >> k & 1 != 0) } }
    put(0, 7); put(1, 1); put(1, 1)
    put(1, 7); put(0, 1); put(0, 1)
    put(2, 7); put(0, 1); put(0, 1)
    put(0, 1); put(0, 1)
    put(0, 1); put(1, 1)
    put(1, 1); put(0, 1)
    var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
    for (index, bit) in bits.enumerated() where bit { bytes[index / 8] |= 1 << UInt8(index % 8) }
    #expect(DMFFile.unpack(bytes, 0 ..< bytes.count, count: 3) == [1, 3, 1])
    let song = try DMFFile.song(dmf([[(0, 1, .note())]], sounds: [Sound(frames: [0, 0, 0], loops: false, packed: bytes)]))
    #expect(song.samples[0].sound == [1, 3, 1])
}

@Test func dmfVolumeGoesToTheCommandWhereTheColumnIsTaken() throws {
    // A note with no instrument is slid to at once, by the volume column, and its volume then goes to
    // the command, which the replayer has for these files alone.
    let renderer = try load(dmf([[(0, 1, .note()), (1, 1, .note(41, instrument: 0, volume: 128))]]))
    let cell = try #require(renderer.listing().cells.first { $0.row == 1 && $0.channel == 1 })
    #expect(cell.volume == 193 + 9 && cell.command == Int(IT2Player.xTrackerVolume) && cell.value == 32)
    let own = try ticks(dmf([[(0, 1, .note()), (1, 1, .note(41, instrument: 0, volume: 128))]]), 7).map(\.own)
    #expect(own[0] == 64 && own[6] == 32)
}

@Test func dmfTuneBendsTheNote() throws {
    // Note effect 1 tunes by sixteenths of a semitone: eight is half a semitone up.
    let rate = try ticks(dmf([[(0, 1, .note(pitch: (1, 8)))]]), 1)[0].rate
    #expect(abs(Double(rate) - 8363 * pow(2.0, 1.0 / 24)) < 2)
    // And sixteen a whole one, which is the next note.
    #expect(try ticks(dmf([[(0, 1, .note(pitch: (1, 16)))]]), 1)[0].rate == 8860)
}

@Test func dmfTremoloOnlyTurnsTheNoteDown() throws {
    // A tremolo of a sine over a row, as deep as it goes.
    let own = try ticks(dmf([[(0, 1, .note(loudness: (4, 0x1F)))]]), 6).map(\.own)
    #expect(own.allSatisfy { $0 <= 64 } && own.contains { $0 < 64 })
    // The first two ticks are at the same place on the wave.
    #expect(own[0] == own[1])
}

@Test func dmfFastVolumeColumnSlideIsKeptWhole() throws {
    // A slide up of 200 a row is forty of the replayer's units a tick at six ticks a row, which with
    // a slide of volume beside it goes to the volume column, where Impulse Tracker has nine at most.
    let both = try ticks(dmf([[(0, 1, .note(pitch: (4, 200), loudness: (2, 0x40)))]]), 6).map(\.rate)
    let alone = try ticks(dmf([[(0, 1, .note(pitch: (4, 200)))]]), 6).map(\.rate)
    #expect(both == alone && both[5] > both[0])
}

@Test func dmfNoteAboveImpulseTrackersHighestIsPlayed() throws {
    // OpenMPT's notes go an octave and two thirds higher than Impulse Tracker's.
    let rate = try ticks(dmf([[(0, 1, .note(100))]]), 1)[0].rate
    #expect(abs(Double(rate) - 8363 * pow(2.0, 63.0 / 12)) < 8363 * pow(2.0, 63.0 / 12) / 1000)
    #expect(try load(dmf([[(0, 1, .note(100))]])).info.shortfalls.isEmpty)
}

@Test func dmfSaysWhatItLeavesOut() throws {
    // Three commands to a note, none of which the volume column can take: one is left out.
    let crowded = dmf([[(0, 1, .note(sample: (6, 0x10), pitch: (8, 0x44), loudness: (10, 0x44)))]])
    #expect(try load(crowded).info.shortfalls == ["One of its notes has more commands than Impulse Tracker's replayer has room for, and one is left out."])
}

@Test func dmfDamagedFilesAreRefusedOrPlayed() throws {
    let file = dmf([[(0, 1, .note()), (1, 1, .note(41, instrument: 0, volume: 128))]])
    for length in stride(from: 0, to: file.count, by: 7) {
        if let renderer = try? TuneLoader.load(Array(file.prefix(length)), format: .dmf) {
            var buffer = [Float](repeating: 0, count: 2048)
            buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 1024) }
        }
    }
    #expect(throws: TuneError.self) { _ = try TuneLoader.load(Array("DDMF".utf8) + [0], format: .dmf) }
}
