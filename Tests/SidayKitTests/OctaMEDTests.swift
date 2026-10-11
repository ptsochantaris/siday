// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of the player for MED modules. The thorough check is made outside the package, against
// OctaMED's own players run in an emulated Amiga: `SIDAY_MED_TRACE=1 siday --raw /dev/null tune.med`
// writes what this player tells the sound chip, tick by tick (or what it mixes for the chip, or what
// it tells its mixer), and the two are to be the same.

/// What is on a line of a block: a note (1 is the lowest C), an instrument and a command.
private struct Entry {
    var line: Int
    var track: Int
    var note: UInt8 = 0
    var instrument: UInt8 = 0
    var command: UInt8 = 0
    var data: UInt8 = 0
}

/// One song of a module to be made: a block of 64 lines and four tracks (or more), played once.
private struct Tune {
    var entries: [Entry]
    var title = "a square wave"
    var tempo = 33
    var ticksPerLine: UInt8 = 6
    var flags: UInt8 = 0
    var flags2: UInt8 = 0
    /// More commands for the same lines, on a second page.
    var secondPage: [Entry] = []
    /// Of the instrument: how long its notes are held, how fast they then fade, its kind, and how
    /// long its sample is (its repeat is the first 32 bytes).
    var hold: UInt8 = 0
    var decay: UInt8 = 0
    var type: Int16 = 0
    var sampleLength = 32
    var tracks = 4
    /// The whole of the instrument as it lies in the file, in place of the square wave.
    var instrument: [UInt8]?
    /// For mixing mode: how many channels, whether in stereo (1) and with tracks placed freely (2),
    /// and where each track lies between left (-16) and right (16).
    var channels = 0
    var mixing: UInt8 = 0
    var pans: [Int8] = []
}

private func bytes(_ value: Int, _ count: Int) -> [UInt8] {
    (0 ..< count).map { UInt8(truncatingIfNeeded: value >> ((count - 1 - $0) * 8)) }
}

/// A MED module with one instrument: a square wave of 32 bytes, all of it looping, at full volume.
/// - Parameter version: which of the four kinds of file, 0 to 3.
private func module(version: Int = 1, _ tunes: [Tune]) -> [UInt8] {
    var file: [UInt8] = []
    func put(_ value: Int, _ count: Int, at place: Int) { file.replaceSubrange(place ..< place + count, with: bytes(value, count)) }
    func even() { if file.count % 2 == 1 { file.append(0) } }

    // The sample, which every song shares, comes first, then the songs one after another.
    var headers: [Int] = []
    var sampleTable = 0
    for (number, tune) in tunes.enumerated() {
        let header = file.count
        headers.append(header)
        file += Array((number == 0 ? "MMD" : "MCN").utf8) + [UInt8(0x30 + version)] + [UInt8](repeating: 0, count: 48)
        file[header + 51] = UInt8(tunes.count - 1)

        let song = file.count
        put(song, 4, at: header + 8)
        file += [UInt8](repeating: 0, count: 788)
        put(16, 2, at: song + 2) // the instrument repeats for 16 words from its start
        file[song + 6] = 64 // and is as loud as it goes
        put(1, 2, at: song + 504) // one block
        put(1, 2, at: song + 506) // played once
        put(tune.tempo, 2, at: song + 764)
        file[song + 767] = tune.flags
        file[song + 768] = tune.flags2
        file[song + 769] = tune.ticksPerLine
        for track in 0 ..< 16 { file[song + 770 + track] = 64 }
        file[song + 786] = 64
        file[song + 787] = 1
        if version >= 2 {
            // The later kinds have the order of playing outside the song: a list of sections, each
            // naming a sequence of blocks, and the track volumes in a list of their own.
            let sequence = file.count
            file += [UInt8](repeating: 0, count: 40) + bytes(1, 2) + bytes(0, 2)
            let sequences = file.count
            file += bytes(sequence, 4)
            let sections = file.count
            file += bytes(0, 2)
            let volumes = file.count
            file += [UInt8](repeating: 64, count: tune.tracks)
            put(sequences, 4, at: song + 508)
            put(sections, 4, at: song + 512)
            put(volumes, 4, at: song + 516)
            put(tune.tracks, 2, at: song + 520)
            put(1, 2, at: song + 522)
            if !tune.pans.isEmpty {
                put(file.count, 4, at: song + 524)
                file += tune.pans.map { UInt8(bitPattern: $0) }
                even()
            }
            file[song + 531] = tune.mixing
            put(tune.channels, 2, at: song + 534)
        }

        let blocks = file.count
        put(blocks, 4, at: header + 16)
        file += bytes(blocks + 4, 4)
        let block = file.count
        if version == 0 {
            file += [4, 63] + [UInt8](repeating: 0, count: 64 * 4 * 3)
            for entry in tune.entries {
                let at = block + 2 + (entry.line * 4 + entry.track) * 3
                file[at] = entry.note | (entry.instrument & 0x10) << 3 | (entry.instrument & 0x20) << 1
                file[at + 1] = entry.instrument << 4 | entry.command
                file[at + 2] = entry.data
            }
        } else {
            file += bytes(tune.tracks, 2) + bytes(63, 2) + bytes(0, 4) + [UInt8](repeating: 0, count: 64 * tune.tracks * 4)
            for entry in tune.entries {
                let at = block + 8 + (entry.line * tune.tracks + entry.track) * 4
                file.replaceSubrange(at ..< at + 4, with: [entry.note, entry.instrument, entry.command, entry.data])
            }
            if !tune.secondPage.isEmpty {
                let about = file.count
                put(about, 4, at: block + 4)
                file += [UInt8](repeating: 0, count: 36)
                let table = file.count
                put(table, 4, at: about + 12)
                file += bytes(1, 2) + bytes(0, 2) + bytes(table + 8, 4)
                let page = file.count
                file += [UInt8](repeating: 0, count: 64 * 4 * 2)
                for entry in tune.secondPage {
                    file[page + (entry.line * 4 + entry.track) * 2] = entry.command
                    file[page + (entry.line * 4 + entry.track) * 2 + 1] = entry.data
                }
            }
        }

        if number == 0 {
            sampleTable = file.count
            file += bytes(sampleTable + 4, 4)
            if let instrument = tune.instrument {
                file += instrument
                even()
            } else {
                file += bytes(tune.sampleLength, 4) + bytes(Int(UInt16(bitPattern: tune.type)), 2)
                for _ in 0 ..< tune.sampleLength / 32 { file += [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16) }
            }
        }
        put(sampleTable, 4, at: header + 24)
    }
    // What is said of each song beyond its structure: where the next song is, and its name; and for
    // the first, how the instrument is held.
    var expansions: [Int] = []
    for (number, tune) in tunes.enumerated() {
        even()
        let expansion = file.count
        expansions.append(expansion)
        put(expansion, 4, at: headers[number] + 32)
        file += [UInt8](repeating: 0, count: 84)
        if number == 0 {
            put(file.count, 4, at: expansion + 4)
            put(1, 2, at: expansion + 8)
            put(4, 2, at: expansion + 10)
            file += [tune.hold, tune.decay, 0, 0]
        }
        put(file.count, 4, at: expansion + 44)
        put(tune.title.utf8.count + 1, 4, at: expansion + 48)
        file += Array(tune.title.utf8) + [0]
    }
    for number in 0 ..< tunes.count - 1 { put(headers[number + 1], 4, at: expansions[number]) }
    put(file.count, 4, at: 4)
    return file
}

private func module(version: Int = 1, _ entries: [Entry]) -> [UInt8] {
    module(version: version, [Tune(entries: entries)])
}

/// The C an octave above the lowest, on the one instrument: period 428.
private func c(line: Int = 0, track: Int = 0, command: UInt8 = 0, data: UInt8 = 0) -> Entry {
    Entry(line: line, track: track, note: 13, instrument: 1, command: command, data: data)
}

private func ticks(_ file: [UInt8], seconds: Double = 2) throws -> [MEDRegisterTick] {
    try MEDRenderer(file, options: LoadOptions()).registerTicks(seconds: seconds)
}

private func stereo(_ renderer: any Renderer, seconds: Double) -> (left: [Float], right: [Float]) {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return (stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }, stride(from: 1, to: frames * 2, by: 2).map { buffer[$0] })
}

@Test func medModuleOfEachKindIsRead() throws {
    for version in 0 ... 3 {
        let renderer = try TuneLoader.load(module(version: version, [c()]), format: .med)
        #expect(renderer.info.format == "MED")
        #expect(renderer.info.title == "a square wave")
        #expect(renderer.info.detail == "MMD\(version)")
        #expect(renderer.subsongCount == 1 && renderer.channelCount == 4)

        // The note on the first tick: the sample from its start, all sixteen words of it, at the
        // period of its C and the instrument's own volume; and it goes round from its start again.
        let first = try #require(try ticks(module(version: version, [c()])).first)
        #expect(first.voices[0].period == 428 && first.voices[0].volume == 64)
        let start = try #require(first.voices[0].start), loop = try #require(first.voices[0].loop)
        #expect(start.instrument == 1 && start.offset == 0 && start.words == 16)
        #expect(loop.instrument == 1 && loop.offset == 0 && loop.words == 16)
        // The other voices are told a period and a volume too, of nothing.
        #expect(first.voices[1].period == 0 && first.voices[1].volume == 0 && first.voices[1].start == nil)
    }
    // A module is as often named for its first four letters. And one that has been named as if it
    // were a MOD file is still known for what it is.
    for name in ["med", "MED", "mmd0", "MMD1", "mmd2", "mmd3"] { #expect(TuneFormat(fileExtension: name) == .med) }
    #expect(TuneFormat(fileExtension: "mmd4") == nil)
    #expect(try TuneLoader.load(module([c()]), format: .mod).info.format == "MED")
    #expect(Setting.amiga.changes(.med) && Setting.amigaSeparation.changes(.med) && !Setting.clock.changes(.med))
}

@Test func medNoteSoundsAtItsPitchOnItsSide() throws {
    // Period 428 is 3,546,895 / 428 = 8287 bytes a second, and the square wave is 32 of them long:
    // 259 Hz. The first track has the first voice, which is wired to the left.
    var options = LoadOptions()
    options.stereo = .abc
    options.amigaSeparation = 1
    let sound = stereo(try TuneLoader.load(module([c()]), format: .med, options: options), seconds: 1)
    let pitch = sound.left[4800...].indices.dropLast().count { sound.left[$0] < 0 && sound.left[$0 + 1] >= 0 } * 10 / 9
    #expect(abs(pitch - 259) <= 2)
    #expect(sound.left[4800...].map(abs).max()! > 0.2)
    #expect(sound.right.map(abs).max()! < 0.001)

    let other = stereo(try TuneLoader.load(module([c(track: 1)]), format: .med, options: options), seconds: 1)
    #expect(other.left.map(abs).max()! < 0.001 && other.right[4800...].map(abs).max()! > 0.2)
    // In mono both ears have the same.
    let mono = stereo(try TuneLoader.load(module([c()]), format: .med), seconds: 0.5)
    #expect(mono.left == mono.right)
}

@Test func medTempoIsTheTimersInBothItsKinds() throws {
    // A tempo as such is what 470,000 is divided by for the timer, which counts a fifth as fast as
    // the sound chip and takes one count more than it is given: 470,000 / 33 = 14,242.
    let plain = try ticks(module([c()]))
    #expect(plain[0].clocks == 14243 * 5 && plain[1].clocks == 14243 * 5)
    // 64 lines of 6 ticks.
    let length = try #require(try TuneLoader.load(module([c()]), format: .med).knownLength)
    #expect(abs(length - 384.0 * 71215.0 / 3_546_895.0) < 0.001)

    // The tempos up to ten are the speeds of the older trackers, each with a count of its own.
    #expect(try ticks(module([Tune(entries: [c()], tempo: 6)]))[0].clocks == 14501 * 5)

    // In beats a minute the timer fires four times a tick: 125 beats of four lines is 500 lines a
    // minute, and 1,773,447 / 500 = 3546.
    let beats = try ticks(module([Tune(entries: [c()], tempo: 125, flags2: 0x20 | 3)]))
    #expect(beats[0].clocks == 4 * 3547 * 5)

    // A change of tempo is taken up by the timer when it next runs out: the tick that sets it is as
    // long as the one before.
    let changed = try ticks(module([c(), Entry(line: 1, track: 0, command: 0x0F, data: 100)]))
    #expect(changed[6].clocks == 14243 * 5 && changed[7].clocks == 4701 * 5)
    // And in beats a minute, the first of that tick's four turns of the timer is still the old one.
    let beatsChanged = try ticks(module([Tune(entries: [c(), Entry(line: 1, track: 0, command: 0x0F, data: 240)], tempo: 125, flags2: 0x20 | 3)]))
    #expect(beatsChanged[6].clocks == (3547 + 3 * 1848) * 5 && beatsChanged[7].clocks == 4 * 1848 * 5)

    // The other half of the tempo is how many ticks a line has.
    let slow = try ticks(module([c(command: 0x09, data: 3), c(line: 1, track: 1)]))
    #expect(slow[2].voices[1].start == nil && slow[3].voices[1].start != nil)
}

@Test func medCommandsDoWhatOctaMEDsDid() throws {
    // A volume is two decimal digits, unless the song says its volumes are hexadecimal.
    #expect(try ticks(module([c(command: 0x0C, data: 0x32)]))[0].voices[0].volume == 32)
    #expect(try ticks(module([Tune(entries: [c(command: 0x0C, data: 0x20)], flags: 0x10)]))[0].voices[0].volume == 32)

    // A slide up takes its number from the period on every tick, the first too, unless the song
    // asks for the older trackers' way.
    let slide = try ticks(module([c(command: 0x01, data: 4)]))
    #expect(slide[0].voices[0].period == 424 && slide[5].voices[0].period == 404)
    let older = try ticks(module([Tune(entries: [c(command: 0x01, data: 4)], flags: 0x20)]))
    #expect(older[0].voices[0].period == 428 && older[5].voices[0].period == 408)

    // An arpeggio goes through the two notes above and then the note itself. Four and seven
    // semitones above this C are periods 339 and 285.
    let arpeggio = try ticks(module([c(command: 0x00, data: 0x47)]))
    #expect(arpeggio[0 ... 3].map { $0.voices[0].period } == [339, 285, 428, 339])

    // A slide to a note does not start it.
    let toNote = try ticks(module([c(), Entry(line: 1, track: 0, note: 25, instrument: 1, command: 0x03, data: 10)]))
    #expect(toNote[6].voices[0].start == nil)
    #expect(toNote[6].voices[0].period == 418 && toNote[11].voices[0].period == 368)

    // A note cut short, a note started three times over, and a note that comes late.
    let cut = try ticks(module([c(command: 0x18, data: 2)]))
    #expect(cut[1].voices[0].volume == 64 && cut[2].voices[0].volume == 0)
    let again = try ticks(module([c(command: 0x1F, data: 0x02)]))
    #expect(again[0 ... 5].map { $0.voices[0].start != nil } == [true, false, true, false, true, false])
    let late = try ticks(module([c(command: 0x1F, data: 0x30)]))
    #expect(late[0 ... 5].map { $0.voices[0].start != nil } == [false, false, false, true, false, false])

    // A command on a second page is carried out with the first.
    let two = try ticks(module([Tune(entries: [c(command: 0x0C, data: 0x32)], secondPage: [Entry(line: 0, track: 0, command: 0x01, data: 4)])]))
    #expect(two[0].voices[0].volume == 32 && two[0].voices[0].period == 424)

    // A note held for two ticks and then let fade, eight to the tick.
    let held = try ticks(module([Tune(entries: [c()], hold: 2, decay: 8)]))
    #expect(held[0 ... 4].map { $0.voices[0].volume } == [64, 64, 56, 48, 40])
}

@Test func medPlayerKeepsOctaMEDsOddities() throws {
    // A command that starts a note leaves OctaMED's player with the wrong count of pages, and the
    // pages after that one are passed over on that tick. Here the note comes on the fourth tick,
    // and the slide on the second page misses that tick and no other.
    let late = Entry(line: 0, track: 0, note: 13, instrument: 1, command: 0x1F, data: 0x30)
    let passed = try ticks(module([Tune(entries: [late], secondPage: [Entry(line: 0, track: 0, command: 0x02, data: 1)])]))
    #expect(passed[3].voices[0].start != nil)
    #expect(passed[0 ... 5].map { $0.voices[0].period } == [1, 2, 3, 428, 429, 430])

    // A command numbered past the thirty-two there are is taken, on the ticks of a line, for the
    // one it is thirty-two past: 0x21 slides the pitch up as 0x01 does.
    #expect(try ticks(module([c(command: 0x21, data: 4)]))[1].voices[0].period == 420)

    // A note above the top of the table of periods is played an octave lower, once: the highest C
    // there is, and the C two octaves above it, come out as the same note.
    let top = try ticks(module([Entry(line: 0, track: 0, note: 61, instrument: 1), Entry(line: 0, track: 1, note: 73, instrument: 1)]))
    #expect(top[0].voices[0].period == 214 && top[0].voices[1].period == 214)
}

@Test func medSampleRecordedAtSeveralOctavesIsPlayedFromTheRightOne() throws {
    // Three recordings: 32 bytes, then 64 an octave lower, then 128 lower still. Low notes are
    // played from the longest and high ones from the shortest, each at a period from the middle
    // of the table, where the chip is at its best.
    func note(_ note: UInt8) throws -> MEDRegisterTick.Voice {
        try ticks(module([Tune(entries: [Entry(line: 0, track: 0, note: note, instrument: 1)], type: 2, sampleLength: 32 * 7)]))[0].voices[0]
    }
    let low = try note(1), middle = try note(25), high = try note(49)
    #expect(low.start?.offset == 96 && low.start?.words == 64 && low.period == 856)
    #expect(middle.start?.offset == 32 && middle.start?.words == 32 && middle.period == 428)
    #expect(high.start?.offset == 0 && high.start?.words == 16 && high.period == 214)
    // The part that repeats is twice as long, and twice as far in, for each octave down.
    #expect(low.loop?.offset == 96 && low.loop?.words == 64 && high.loop?.words == 16)

    // And a sample of the kind that goes two octaves lower than others has its notes two octaves down.
    let extended = try ticks(module([Tune(entries: [c()], type: 7)]))[0].voices[0]
    #expect(extended.period == 428 * 4)
}

@Test func medModuleKnowsWhereItEnds() throws {
    // A break on the eighth line goes round to the top: eight lines of six ticks.
    let short = try TuneLoader.load(module([c(), Entry(line: 7, track: 0, command: 0x0F, data: 0)]), format: .med)
    #expect(abs(short.knownLength! - 48.0 * 71215.0 / 3_546_895.0) < 0.001)
    #expect(short.endsByLooping && short.loopCount == 0)
    _ = stereo(short, seconds: 2)
    #expect(short.loopCount == 2 && !short.hasEnded)

    // And a module can tell the player to stop.
    let stops = try TuneLoader.load(module([c(), Entry(line: 4, track: 0, command: 0x0F, data: 0xFE)]), format: .med)
    #expect(abs(stops.knownLength! - 25.0 * 71215.0 / 3_546_895.0) < 0.001)
    _ = stereo(stops, seconds: 1)
    #expect(stops.hasEnded)
}

@Test func medFileOfSeveralSongsHasThemAll() throws {
    let file = module([Tune(entries: [c()], title: "the first"), Tune(entries: [c(track: 1)], title: "the second", ticksPerLine: 3)])
    let renderer = try TuneLoader.load(file, format: .med)
    #expect(renderer.subsongCount == 2)
    #expect(renderer.songs.map { $0.title } == ["the first", "the second"])
    #expect(abs(renderer.songs[1].length! * 2 - renderer.songs[0].length!) < 0.001)
    renderer.select(subsong: 1)
    #expect(renderer.currentSubsong == 1)
    var options = LoadOptions()
    options.stereo = .abc
    options.amigaSeparation = 1
    let second = try TuneLoader.load(file, format: .med, options: options)
    second.select(subsong: 1)
    let sound = stereo(second, seconds: 0.5)
    #expect(sound.left.map(abs).max()! < 0.001 && sound.right[4800...].map(abs).max()! > 0.2)
}

/// A synthetic sound: a volume list, a waveform list, and one waveform, a square wave of 32 bytes.
/// - Parameter sample: for a hybrid sound, whose first waveform is a sample with a sample's words before it.
private func synthetic(volumes: [UInt8], waves: [UInt8], hybrid: Bool = false) -> [UInt8] {
    let square = [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16)
    var sound = bytes(272, 4) + bytes(hybrid ? 0xFFFE : 0xFFFF, 2) + [UInt8](repeating: 0, count: 8) + bytes(volumes.count, 2) + bytes(waves.count, 2)
    sound += [1, 1] + bytes(1, 2)
    sound += volumes + [UInt8](repeating: 0xFF, count: 128 - volumes.count) + waves + [UInt8](repeating: 0xFF, count: 128 - waves.count)
    sound += bytes(278 + 256, 4) + [UInt8](repeating: 0, count: 252)
    sound += hybrid ? bytes(32, 4) + bytes(0, 2) + square : bytes(16, 2) + square
    return sound
}

@Test func medSyntheticSoundFollowsItsTwoLists() throws {
    // Its volume list: 64, wait two ticks, 32. Its waveform list: the first waveform.
    let sound = synthetic(volumes: [0x40, 0xF1, 0x02, 0x20], waves: [0x00])
    let played = try ticks(module([Tune(entries: [c()], instrument: sound)]))
    // The waveform is given on the first tick: its 32 bytes lie after the lists, the table of
    // where the waveforms are, and the two bytes of its length. No sample is started.
    let waveform = try #require(played[0].voices[0].waveform)
    #expect(waveform.words == 16 && played[0].voices[0].start == nil && played[1].voices[0].waveform == nil)
    // A synthetic sound's notes are two octaves below a sample's: this C is period 1712.
    #expect(played[0].voices[0].period == 1712)
    #expect(played[0 ... 5].map { $0.voices[0].volume } == [64, 64, 64, 32, 32, 32])

    // The waveform list can bend the pitch: so many periods on every tick, from the tick after.
    let sliding = try ticks(module([Tune(entries: [c()], instrument: synthetic(volumes: [0x40], waves: [0xF2, 0x03, 0x00]))]))
    #expect(sliding[0 ... 3].map { $0.voices[0].period } == [1712, 1715, 1718, 1721])
    // And it can play a run of notes over and over, one a tick: here the note, and a fourth above.
    let run = try ticks(module([Tune(entries: [c()], instrument: synthetic(volumes: [0x40], waves: [0xFC, 0x00, 0x05, 0xFD, 0x00]))]))
    #expect(run[0 ... 3].map { $0.voices[0].period } == [1712, 1280, 1712, 1280])

    // A note that is let go is sent to the place in the volume list that its decay names.
    let held = try ticks(module([Tune(entries: [c()], hold: 2, decay: 3, instrument: sound)]))
    #expect(held[0 ... 3].map { $0.voices[0].volume } == [64, 64, 32, 32])

    // It sounds: the square wave, at 3,546,895 / 1712 = 2072 bytes a second, 32 to the turn.
    var options = LoadOptions()
    options.stereo = .abc
    options.amigaSeparation = 1
    let heard = stereo(try TuneLoader.load(module([Tune(entries: [c()], instrument: sound)]), format: .med, options: options), seconds: 1)
    let pitch = heard.left[4800...].indices.dropLast().count { heard.left[$0] < 0 && heard.left[$0 + 1] >= 0 } * 10 / 9
    #expect(abs(pitch - 65) <= 2 && heard.left[4800...].map(abs).max()! > 0.05)
}

@Test func medHybridSoundIsASampleWithLists() throws {
    // The sample is started as a sample is, and the volume list sets how loud it is.
    let played = try ticks(module([Tune(entries: [c()], instrument: synthetic(volumes: [0x20, 0x10], waves: [], hybrid: true))]))
    let start = try #require(played[0].voices[0].start)
    #expect(start.instrument == 1 && start.offset == 0 && start.words == 16)
    #expect(played[0].voices[0].period == 428)
    #expect(played[0 ... 2].map { $0.voices[0].volume } == [32, 16, 16])
}

@Test func medFiveToEightChannelsAreMixedInPairs() throws {
    // The first track and the fifth share the first voice: a note on each, an octave apart.
    let high = Entry(line: 0, track: 4, note: 25, instrument: 1)
    let file = module([Tune(entries: [c(), high], flags: 0x40, tracks: 8)])
    let renderer = try MEDRenderer(file, options: LoadOptions())
    #expect(renderer.channelCount == 8 && renderer.isPlayedOnAnAmiga)
    // (The mixing of eight tracks was set beside OctaMED's own, and there is nothing to say of it.)
    #expect(renderer.info.shortfalls.isEmpty)
    let played = renderer.registerTicks(seconds: 1)
    // Any tempo but the nine fast ones is the tenth: 366 words are mixed for a tick, and a tick
    // lasts as long as a voice takes to play them, a byte every 124 of the chip's clocks.
    #expect(played[0].mixedWords == 366 && played[0].mixed[0].count == 732 && played[1].clocks == 732 * 124)
    // What is mixed on a tick is the notes of the tick before: nothing at first, then the two
    // square waves added, as bytes that go round when they are too large. The lower note steps
    // through its sample at 124/428 of a byte for each byte mixed, the higher at 124/214.
    #expect(played[0].mixed[0].allSatisfy { $0 == 0 })
    let mixed = played[1].mixed[0]
    #expect(mixed[0] == Int8(bitPattern: 0x7F &+ 0x7F))
    // (So the higher note reaches the second half of its wave at the 28th byte mixed.)
    #expect(mixed[27] == Int8(bitPattern: 0x7F &+ 0x7F) && mixed[28] == Int8(bitPattern: 0x7F &+ 0x81))
    // The other voices have nothing to mix, and every voice is turned full up by its instrument.
    #expect(played[1].mixed[1].allSatisfy { $0 == 0 })
    #expect(played[1].voices[0].volume == 64 && played[0].voices[0].volume == 0)

    // A volume is the voice's, whichever of its two tracks asks; and the tempo is how much is mixed.
    let quiet = try MEDRenderer(module([Tune(entries: [c(), Entry(line: 0, track: 4, command: 0x0C, data: 0x32)], flags: 0x40, tracks: 8)]),
                                options: LoadOptions()).registerTicks(seconds: 1)
    #expect(quiet[1].voices[0].volume == 32)
    let fast = try MEDRenderer(module([Tune(entries: [c()], tempo: 1, flags: 0x40, tracks: 8)]), options: LoadOptions()).registerTicks(seconds: 1)
    #expect(fast[0].mixedWords == 202)

    // And it is heard, on the side its voice is wired to.
    var options = LoadOptions()
    options.stereo = .abc
    options.amigaSeparation = 1
    let heard = stereo(try TuneLoader.load(file, format: .med, options: options), seconds: 1)
    #expect(heard.left[9600...].map(abs).max()! > 0.05 && heard.right.map(abs).max()! < 0.001)
}

@Test func medMixingModeMixesEveryTrackWhereTheSongPutsIt() throws {
    // Beats a minute: 125 of four lines each, so a tick is a fiftieth of a second.
    let notes = [c(), c(line: 8, track: 1), c(line: 16, track: 2)]
    let tune = Tune(entries: notes, tempo: 125, flags2: 0x80 | 0x20 | 3, tracks: 4, channels: 4, mixing: 1, pans: [-16, 16, 0, 0])
    let file = module(version: 3, [tune])
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try MEDRenderer(file, options: options)
    #expect(renderer.channelCount == 4 && !renderer.isPlayedOnAnAmiga)
    #expect(abs(renderer.knownLength! - 384 * 0.02) < 0.001)
    // The Amiga's settings are nothing to such a song, though they are to another MED file.
    #expect(!Setting.amiga.changes(.med, played: renderer) && !Setting.amigaSeparation.changes(.med, played: renderer))
    #expect(Setting.amiga.changes(.med, played: try TuneLoader.load(module([c()]), format: .med)))

    // What the mixer is told: the sample, all 32 bytes of it going round; the volume, and where
    // the track lies; and a rate. The lowest C is 1046 samples a second, and this is the C above.
    let events = renderer.mixEvents(seconds: 0.1)
    let note = try #require(events.first { $0.kind == .note })
    #expect(note.track == 0 && note.c == 0 && note.d == 32 && note.e == 32 && note.f == 1)
    let volume = try #require(events.first { $0.kind == .volume && $0.track == 0 })
    #expect(volume.b == -16)
    #expect(events.first { $0.kind == .rate && $0.track == 0 }?.a == 2090)
    #expect(renderer.mixSettings[0] == 4 && renderer.mixSettings[1] == 1)

    // The first track is on the left and no other is playing yet; the second comes in on the right;
    // the third is in the middle, the same on both sides. 2090 samples a second of a wave 32 long is 65 Hz.
    let sound = stereo(renderer, seconds: 3)
    let first = 0 ..< 48000 * 8 * 6 / 50
    #expect(sound.left[first].map(abs).max()! > 0.05 && sound.right[first].map(abs).max()! < 0.0001)
    let pitch = sound.left[0 ..< 48000].indices.dropLast().count { sound.left[$0] < 0 && sound.left[$0 + 1] >= 0 }
    #expect(abs(pitch - 65) <= 2)
    #expect(sound.right[96000...].map(abs).max()! > 0.05)
    // In mono both ears have the same.
    let mono = stereo(try TuneLoader.load(file, format: .med), seconds: 1)
    #expect(mono.left == mono.right && mono.left.map(abs).max()! > 0.02)

    // A slide is still written in periods of the sound chip: the rate is turned into one, slid, and
    // turned back. 3,579,545 / 2090 is 1712, less four is 1708, and that is 2095 samples a second.
    let slid = try MEDRenderer(module(version: 3, [Tune(entries: [c(command: 0x01, data: 4)], tempo: 125, flags2: 0xA3, channels: 4, mixing: 1)]),
                               options: options).mixEvents(seconds: 0.1)
    #expect(slid.first { $0.kind == .rate && $0.track == 0 }?.a == 2095)

    // A sample of sixteen bits is played here, where the chip's four voices could not play it.
    let wide = module(version: 3, [Tune(entries: [c()], tempo: 125, flags2: 0xA3, type: 0x10, sampleLength: 64, channels: 4, mixing: 1)])
    let heard = stereo(try TuneLoader.load(wide, format: .med, options: options), seconds: 0.5)
    #expect(heard.left.map(abs).max()! > 0.02)
    #expect(try TuneLoader.load(wide, format: .med).info.format == "MED")
}

@Test func medModuleThatCannotBePlayedIsRefused() throws {
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
    // A sample of sixteen bits is more than the chip's own voices can play.
    #expect(reason(module([Tune(entries: [c()], type: 0x10)])).contains("sixteen-bit"))
    #expect(reason(module([Tune(entries: [c()], flags: 0x40, type: 0x10, tracks: 8)])).contains("sixteen-bit"))
    #expect(reason(module([Tune(entries: [c()], type: -3)])).contains("does not know"))
    // A sound of a kind that is not played does no harm if no note asks for it.
    #expect(reason(module([Tune(entries: [], type: 0x10)])) == "played")
    // And the songs MED saved before it had modules are not modules.
    #expect(reason([0x4D, 0x45, 0x44, 0x04] + [UInt8](repeating: 0, count: 2000)).contains("MED's first formats"))
}

@Test func medFileCutShortIsRefusedOrPlayedAndNeverTraps() throws {
    let file = module(version: 2, [Tune(entries: [c(), c(line: 3, track: 2, command: 0x1F, data: 0x11)], hold: 3, decay: 2)])
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(file.prefix(40)), format: .med) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(file.prefix(600)), format: .med) }
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x41, count: 4000), format: .med) }
    // Cut anywhere, it is either refused or played.
    for length in stride(from: 1, to: file.count, by: 13) {
        if let renderer = try? TuneLoader.load(Array(file.prefix(length)), format: .med) { _ = stereo(renderer, seconds: 0.2) }
    }
    // And so is one whose every pointer points somewhere it should not.
    for seed in 0 ..< 40 {
        var damaged = file
        var state = UInt32(seed) &* 2_654_435_761 &+ 1
        for _ in 0 ..< 12 {
            state = state &* 1_664_525 &+ 1_013_904_223
            let at = 4 + Int(state >> 8) % (damaged.count - 4)
            state = state &* 1_664_525 &+ 1_013_904_223
            damaged[at] = UInt8(truncatingIfNeeded: state >> 16)
        }
        if let renderer = try? TuneLoader.load(damaged, format: .med) { _ = stereo(renderer, seconds: 0.2) }
    }
}
