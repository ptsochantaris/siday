// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayTrackers
import Testing

// Fast checks of the MT2 files that Impulse Tracker's replayer plays, on files made here. The
// thorough check is made outside the package, against libopenmpt: where every file is on each
// tick, every channel's pitch, volume and place on every tick of each file to hand, and what is heard.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] { Array((bytes + [UInt8](repeating: 0, count: length)).prefix(length)) }

/// One track's part of a row, as an MT2 file has it: a note (1 is the lowest C, 49 is C-5, 97 lets
/// the key go), an instrument, the volume column (0x10 to 0x90 a volume, 0xA0 to 0xDF slides), a
/// place between the speakers (0 for none), and a command with two values.
private struct Cell {
    var note = 0, instrument = 0, volume = 0, pan = 0, command = 0, value1 = 0, value2 = 0

    static func note(_ note: Int = 49, _ instrument: Int = 1, volume: Int = 0, pan: Int = 0) -> Cell {
        Cell(note: note, instrument: instrument, volume: volume, pan: pan)
    }

    /// FastTracker's command, by its number, with its value.
    static func fastTracker(_ command: Int, _ value: Int) -> Cell { Cell(command: 0, value1: value, value2: command) }

    var bytes: [UInt8] { [note, instrument, volume, pan, command, value1, value2].map { UInt8($0) } }
    var isEmpty: Bool { bytes.allSatisfy { $0 == 0 } }
}

/// A sample: a square wave of 32 frames, of sixteen bits, played at 8,192 a second at C-5, which is
/// its own note: so that C-5 is 256 Hz.
private struct Sound {
    var left: [Int] = (0 ..< 32).map { $0 < 16 ? 16000 : -16000 }
    var right: [Int]?
    var sixteen = true
    /// 0 for none, 1 forwards, 2 back and forth.
    var loop = 1
    var volume = 0x8000, pan = 0
    var rate = 8192
}

/// An envelope of up to sixteen points, each a tick and a level from 0 to 64.
private struct Envelope {
    var points: [(Int, Int)]
    var sustain: Int?
    var loop: (Int, Int)?

    var bytes: [UInt8] {
        var b: [UInt8] = [UInt8(1 | (sustain != nil ? 2 : 0) | (loop != nil ? 4 : 0)), UInt8(points.count), UInt8(sustain ?? 0), UInt8(loop?.0 ?? 0), UInt8(loop?.1 ?? 0), 0, 0, 0]
        for i in 0 ..< 16 { b += i < points.count ? word(points[i].0) + word(points[i].1) : [0, 0, 0, 0] }
        return b
    }
}

/// An instrument: its sample on every note, and what else it has.
private struct Instrument {
    var sample = 1
    var groupVolume = 32
    var fadeOut = 0
    var newNote = 0
    var volumeEnvelope: Envelope?
    /// A plug-in in place of samples.
    var plugIn = false
}

/// An MT2 file of version 2.05, its patterns packed unless `packed` is false.
private struct MT2 {
    var title = "a square wave"
    var channels = 2
    var patterns: [[(row: Int, channel: Int, cell: Cell)]] = [[(0, 0, .note())]]
    var rows = 64
    var orders: [Int] = [0]
    var restart = 0
    var speed = 6, linesPerBeat = 4
    /// 882 makes the tempo 125, and a tick 960 frames.
    var samplesPerTick = 882
    var packed = true
    var instruments: [Instrument] = [Instrument()]
    var sounds: [Sound] = [Sound()]
    /// The tracks' volumes (32,768 is unity), and which have an effect of their own.
    var trackVolumes: [Int]?
    var trackEffects: [Bool] = []
    var plugIns: [String] = []
    var automation = false
    /// Eight drums' samples, from nought, and a drum pattern of so many rows: each row a byte to say
    /// which drums play (bit 0 the first), all at the volume given.
    var drums: (samples: [Int], rows: [Int], volume: Int)?

    var bytes: [UInt8] {
        var f = Array("MT20".utf8) + long(0) + word(0x205) + padded(Array("MadTracker 2.0".utf8), to: 32) + padded(Array(title.utf8), to: 64)
        f += word(orders.count) + word(restart) + word(patterns.count) + word(channels) + word(samplesPerTick) + [UInt8(speed), UInt8(linesPerBeat)]
        f += long((packed ? 1 : 0) | (automation ? 2 : 0)) + word(instruments.count) + word(sounds.count)
        f += padded(orders.map { UInt8($0) }, to: 256)
        if let drums {
            f += word(274) + word(1) + drums.samples.flatMap { word($0) } + [UInt8](repeating: 0, count: 256)
        } else {
            f += word(0)
        }
        // The chunks after the header.
        var extra: [UInt8] = []
        if trackVolumes != nil || !trackEffects.isEmpty {
            var trks = word(0x8000)
            for track in 0 ..< channels + (drums == nil ? 0 : 8) {
                let volume = track < (trackVolumes?.count ?? 0) ? trackVolumes![track] : 0x8000
                trks += word(volume) + [track < trackEffects.count && trackEffects[track] ? 1 : 0, 0] + word(0) + [UInt8](repeating: 0, count: 1024)
            }
            extra += Array("TRKS".utf8) + long(trks.count) + trks
        }
        if !plugIns.isEmpty {
            var vst = long(plugIns.count)
            for name in plugIns { vst += padded(Array(name.utf8), to: 64) + [UInt8](repeating: 0, count: 28) + long(0) + long(0) + long(0) + [0, 0, 0] + [UInt8](repeating: 0, count: 17) + long(0) }
            extra += Array("VST2".utf8) + long(vst.count) + vst
        }
        extra += Array("SUM\0".utf8) + long(6 + 6) + [0, 0, 0, 0, 0, 0] + Array("Somebody".utf8).prefix(5) + [0]
        f += long(extra.count) + extra
        // The patterns: a track at a time, a cell given once for the rows after it that are the same.
        for pattern in patterns {
            var cells = [[Cell]](repeating: [Cell](repeating: Cell(), count: rows), count: channels)
            for (row, channel, cell) in pattern { cells[channel][row] = cell }
            var data: [UInt8] = []
            if packed {
                for channel in 0 ..< channels {
                    var row = 0
                    while row < rows {
                        let cell = cells[channel][row]
                        var run = 1
                        while row + run < rows, cells[channel][row + run].bytes == cell.bytes { run += 1 }
                        var mask = 0
                        for (bit, byte) in cell.bytes.enumerated() where byte != 0 { mask |= 1 << bit }
                        data += run > 1 ? [0xFF, UInt8(run - 1), UInt8(mask)] : [UInt8(mask)]
                        data += cell.bytes.filter { $0 != 0 }
                        row += run
                    }
                }
            } else {
                for row in 0 ..< rows { for channel in 0 ..< channels { data += cells[channel][row].bytes } }
            }
            if data.count & 1 != 0 { data.append(0) }
            f += word(rows) + long(data.count) + data
        }
        if let drums {
            f += word(drums.rows.count)
            for which in drums.rows { for drum in 0 ..< 8 { f += which & (1 << drum) != 0 ? [0x80, UInt8(drums.volume), 0, 0] : [0, 0, 0, 0] } }
        }
        if automation {
            // For each pattern and track an envelope's flags and its effect, and one envelope for the first.
            for _ in patterns {
                for track in 0 ..< channels {
                    f += long(track == 0 ? 1 : 0) + long(0)
                    if track == 0 { f += long(0) + [UInt8](repeating: 0, count: 4 * 64) }
                }
            }
        }
        // 255 instruments: a name, a length and what it has.
        for index in 0 ..< 255 {
            f += padded(Array("instrument".utf8), to: 32)
            guard index < instruments.count else {
                f += long(0)
                continue
            }
            let ins = instruments[index]
            var body = word(1) + [UInt8](repeating: 0, count: 96) + [0, 0, 0, 0] + word(ins.fadeOut) + word(ins.newNote)
            body += word(ins.plugIn ? 4 : 0) + long(ins.volumeEnvelope == nil ? 0 : 1)
            if let envelope = ins.volumeEnvelope { body += envelope.bytes }
            if ins.plugIn { body += [0, 0] + word(11000) + [0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 16) }
            // (The length given is four less than what follows it, which a reader adds back.)
            f += long(body.count - 4) + body
        }
        // 256 samples.
        for index in 0 ..< 256 {
            f += padded(Array("sample".utf8), to: 32)
            guard index < sounds.count else {
                f += long(0)
                continue
            }
            let s = sounds[index]
            let sides = s.right == nil ? 1 : 2, size = s.sixteen ? 2 : 1
            let header = long(s.left.count * sides * size) + long(s.rate) + [UInt8(size), UInt8(sides), 0, UInt8(s.loop)] + long(0) + long(s.left.count)
                + word(s.volume) + [UInt8(bitPattern: Int8(s.pan)), 49] + word(0)
            f += long(header.count) + header
        }
        // Each instrument's group: its sample, volume and tuning.
        for ins in instruments { f += [UInt8(ins.sample - 1), UInt8(ins.groupVolume), 0, 0, 0, 0, 0, 0] }
        // The sound, each sample as differences from the frame before.
        for s in sounds {
            for side in [s.left] + (s.right.map { [$0] } ?? []) {
                var last = 0
                for (k, value) in side.enumerated() {
                    // (The right is kept as how far it is from the left.)
                    let v = side == s.left || s.right == nil ? value : value - s.left[k]
                    let delta = v - last
                    last = v
                    f += s.sixteen ? word(delta & 0xFFFF) : [UInt8(delta & 0xFF)]
                }
            }
        }
        return f
    }
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

private func load(_ file: MT2) throws -> any Renderer {
    var options = LoadOptions()
    options.stereo = .abc
    return try TuneLoader.load(file.bytes, format: .mt2, options: options)
}

private func heard(_ file: MT2, seconds: Double = 1) throws -> (left: [Float], right: [Float]) {
    stereo(try load(file), seconds: seconds)
}

/// What a channel's voice is at on each of so many ticks: samples a second, its volume of 128
/// (before the tune's), and whether it is sounding.
private func ticks(_ file: MT2, _ count: Int, channel: Int = 0) throws -> [(rate: Int, volume: Int, sounding: Bool)] {
    let renderer = try #require(try load(file) as? ITRenderer)
    let player = IT2Player(renderer.module, forSound: true)
    return (0 ..< count).map { _ in
        player.Update()
        defer { _ = player.mixer.mixTick() }
        guard let voice = player.hChn[channel].SlaveChnPtr, voice.pointee.Flags & SF_CHAN_ON != 0, voice.pointee.Flags & SF_NOTE_STOP == 0 else { return (0, 0, false) }
        return (Int(voice.pointee.Frequency), Int(voice.pointee.VolNoGlobal) >> 8, true)
    }
}

@Test func mt2NoteSoundsAtItsPitchAndInItsPlace() throws {
    #expect(TuneFormat(fileExtension: "MT2") == .mt2)
    let renderer = try load(MT2())
    #expect(renderer.info.format == "MT2" && renderer.info.title == "a square wave" && renderer.info.author == "Someb")
    #expect(renderer.info.detail == "MadTracker 2.0" && renderer.info.shortfalls.isEmpty)
    // C-5 is the sample's own note, at its own rate: 256 Hz; an octave up is twice that.
    #expect(abs(crossings(try heard(MT2()).left[4800...]) * 10 / 9 - 256) <= 2)
    #expect(abs(crossings(try heard(MT2(patterns: [[(0, 0, .note(61))]])).left[4800...]) * 10 / 9 - 512) <= 3)
    // A sample says where it is between the speakers, from -127 to 127.
    let left = try heard(MT2(sounds: [Sound(pan: -127)])), right = try heard(MT2(sounds: [Sound(pan: 127)]))
    #expect(loudness(left.left[4800...]) > loudness(left.right[4800...]) * 10 && loudness(right.right[4800...]) > loudness(right.left[4800...]) * 10)
    // And so does a cell, which puts it at the left with 1 and the right with 255.
    let placed = try heard(MT2(patterns: [[(0, 0, .note(pan: 255))]]))
    #expect(loudness(placed.right[4800...]) > loudness(placed.left[4800...]) * 10)
    // A pattern packed or not is the same tune, and a sample of eight bits is a sample of sixteen.
    #expect(try heard(MT2(packed: false)).left == heard(MT2()).left)
    let eight = Sound(left: (0 ..< 32).map { $0 < 16 ? 62 : -62 }, sixteen: false)
    #expect(abs(crossings(try heard(MT2(sounds: [eight])).left[4800...]) * 10 / 9 - 256) <= 2)
}

@Test func mt2StereoSampleIsPlayedInStereo() throws {
    // A sample with a right side of its own, kept as how far it is from the left: here the left
    // is the square wave and the right silence.
    let sound = Sound(right: [Int](repeating: 0, count: 32))
    let both = try heard(MT2(sounds: [sound]))
    #expect(loudness(both.left[4800...]) > 0.05 && loudness(both.right[4800...]) < 0.001)
}

@Test func mt2KeepsTimeAsOpenMPTDoes() throws {
    // Its tempo comes from how many samples a tick lasts at 44.1 kHz, the ticks of a line and the
    // lines of a beat: 125 here, which is a tick of 960 frames, and a row of six.
    let renderer = try #require(try load(MT2(rows: 16)) as? ITRenderer)
    let times = renderer.ticks(seconds: 0.5)
    #expect(times.first?.frames == 960 && times.first?.speed == 6)
    // Half the samples to a tick is twice the tempo, whatever the speed.
    let faster = try #require(try load(MT2(rows: 16, samplesPerTick: 441)) as? ITRenderer)
    #expect(faster.ticks(seconds: 0.5).first?.frames == 480)
    // A whole song of one pattern of 16 rows, six ticks each.
    #expect(abs((renderer.knownLength ?? 0) - 16 * 6 * 0.02) < 0.001)
    // FastTracker's Fxx sets the speed below 32 and the tempo from there; MadTracker's 0x0F sets
    // the speed by its first value's low half or the tempo by its second.
    let speed = try #require(try load(MT2(patterns: [[(0, 0, .fastTracker(0xF, 3))]], rows: 16)) as? ITRenderer)
    #expect(speed.ticks(seconds: 0.2).first?.speed == 3)
    let own = try #require(try load(MT2(patterns: [[(0, 0, Cell(command: 0x0F, value1: 0x04, value2: 0))]], rows: 16)) as? ITRenderer)
    #expect(own.ticks(seconds: 0.2).first?.speed == 4)
}

@Test func mt2VolumesAndSlides() throws {
    // The volume column: 0x10 is nothing and 0x90 the whole; FastTracker's Cxx sets it too.
    let half = try ticks(MT2(patterns: [[(0, 0, .note(volume: 0x50))]]), 2)
    let whole = try ticks(MT2(), 2)
    #expect(half[1].volume * 2 == whole[1].volume)
    let set = try ticks(MT2(patterns: [[(0, 0, Cell(note: 49, instrument: 1, command: 0, value1: 0x20, value2: 0xC))]]), 2)
    #expect(set[1].volume * 2 == whole[1].volume)
    // FastTracker's Axy slides by its first half where both are set, as MadTracker took it: up.
    let slid = try ticks(MT2(patterns: [[(0, 0, .note(volume: 0x50)), (1, 0, .fastTracker(0xA, 0x21))]]), 12)
    #expect(slid[11].volume > slid[5].volume)
    // A slide of the volume column by more than nine goes by the whole of it, as a command.
    let column = try ticks(MT2(patterns: [[(0, 0, .note(volume: 0x90)), (1, 0, Cell(volume: 0xAF))]]), 12)
    #expect(column[11].volume < column[5].volume / 2)
}

@Test func mt2KeyLetGo() throws {
    // A key let go of a note whose instrument has no envelope for its volume is silence at once,
    // and the note goes on, silent.
    let file = MT2(patterns: [[(0, 0, .note()), (1, 0, Cell(note: 97))]])
    let silenced = try ticks(file, 8)
    #expect(silenced[2].volume > 0 && silenced[7].sounding && silenced[7].volume == 0)
    // One that has an envelope is let go and fades as soon as it is, if its instrument fades.
    let envelope = Envelope(points: [(0, 64), (10, 64)], sustain: 0)
    let fading = MT2(patterns: [[(0, 0, .note()), (1, 0, Cell(note: 97))]], instruments: [Instrument(fadeOut: 4096, volumeEnvelope: envelope)])
    let faded = try ticks(fading, 14)
    #expect(faded[6].volume < faded[5].volume && faded[13].volume < faded[6].volume)
}

@Test func mt2InstrumentAloneStartsItsEnvelopeAgain() throws {
    // An envelope that falls to nothing over ten ticks; the instrument named again on the third
    // row brings it back to the top, as FastTracker and MadTracker have it.
    let envelope = Envelope(points: [(0, 64), (10, 0)])
    let file = MT2(patterns: [[(0, 0, .note()), (2, 0, Cell(instrument: 1))]], instruments: [Instrument(volumeEnvelope: envelope)])
    let volumes = try ticks(file, 14).map(\.volume)
    #expect(volumes[11] < volumes[1] / 4 && volumes[12] > volumes[11] * 3)
}

@Test func mt2Drums() throws {
    // The drums are eight tracks after the others, each a sample at C-5: the first drum on every
    // other row, on the third track of a file of two.
    let file = MT2(patterns: [[]], drums: (samples: [0, 0, 0, 0, 0, 0, 0, 0], rows: (0 ..< 64).map { $0 % 2 == 0 ? 1 : 0 }, volume: 128))
    let renderer = try load(file)
    #expect(renderer.channelCount == 1)
    #expect(abs(crossings(stereo(renderer, seconds: 1).left[4800...]) * 10 / 9 - 256) <= 3)
}

@Test func mt2SaysWhatItLeavesOut() throws {
    let marked = try load(MT2(trackEffects: [true, false], plugIns: ["SomeReverb.dll"], automation: true)).info.shortfalls
    #expect(marked.contains("Its plug-in (SomeReverb) is left out, and it is heard without what that does to its sound."))
    #expect(marked.contains("One of its tracks has an effect of MadTracker's own on its sound, which is left out."))
    #expect(marked.contains { $0.contains("automation") })
    // A command OpenMPT does not know is left out, and said to be.
    let unknown = try load(MT2(patterns: [[(0, 0, .note()), (1, 0, Cell(command: 0xF2, value1: 1, value2: 2))]])).info.shortfalls
    #expect(unknown == ["One of its commands is left out: MadTracker's commands that OpenMPT does not play either."])
    // An instrument that is a plug-in plays nothing; a file whose notes are mostly for such is refused.
    let mostly = MT2(patterns: [[(0, 0, .note(49, 2)), (4, 0, .note(49, 2)), (8, 0, .note(49, 1))]], instruments: [Instrument(), Instrument(plugIn: true)])
    #expect(throws: TuneError.self) { try load(mostly) }
    let some = MT2(patterns: [[(0, 0, .note(49, 2)), (4, 0, .note(49, 1)), (8, 0, .note(49, 1))]], instruments: [Instrument(), Instrument(plugIn: true)])
    #expect(try load(some).info.shortfalls == ["One of its instruments is a plug-in, and is not heard."])
}

@Test func mt2SongsAndTheListOfPatterns() throws {
    // A place in the list that names a pattern the file has not got is passed over; the song goes on.
    let file = MT2(patterns: [[(0, 0, .note())], [(0, 1, .note())]], rows: 16, orders: [0, 7, 1])
    let renderer = try #require(try load(file) as? ITRenderer)
    #expect(abs((renderer.knownLength ?? 0) - 2 * 16 * 6 * 0.02) < 0.001)
    #expect(renderer.subsongCount == 1)
}

@Test func mt2MutedVoiceIsLeftOut() throws {
    // Two tracks, one at the left and one at the right. With either left out, what is heard is the
    // file without that track's note, to the last bit or two, and each is still said to be as loud
    // as when it is heard; with nothing left out it is the whole again.
    func played(_ steps: [(row: Int, channel: Int, cell: Cell)], muted: [Bool] = []) throws -> (left: [Float], right: [Float], levels: [Float]) {
        let renderer = try load(MT2(channels: 2, patterns: [steps]))
        renderer.setMuted(muted)
        let sound = stereo(renderer, seconds: 0.5)
        var levels = [Float](repeating: 0, count: renderer.channelCount)
        levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
        return (sound.left, sound.right, levels)
    }
    let left = (0, 0, Cell.note(pan: 1)), right = (0, 1, Cell.note(61, pan: 255))
    let whole = try played([left, right]), leftAlone = try played([left]), rightAlone = try played([right])
    #expect(whole.levels.count == 2 && whole.levels[0] > 0.05 && whole.levels[1] > 0.05)
    #expect(loudness(whole.right[2400...]) > 0.05 && loudness(whole.left[2400...]) > 0.05)
    func apart(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
    let withoutRight = try played([left, right], muted: [false, true])
    #expect(apart(withoutRight.left, leftAlone.left) < 1e-5 && apart(withoutRight.right, leftAlone.right) < 1e-5)
    #expect(withoutRight.levels == whole.levels)
    let withoutLeft = try played([left, right], muted: [true, false])
    #expect(apart(withoutLeft.right, rightAlone.right) < 1e-5 && apart(withoutLeft.left, rightAlone.left) < 1e-5)
    #expect(try played([left, right], muted: [false, false]).left == whole.left)
    let silent = try played([left, right], muted: [true, true])
    #expect(loudness(silent.left[...]) < 1e-4 && loudness(silent.right[...]) < 1e-4)
}

@Test func mt2DamagedFilesAreTurnedAwayOrPlayed() throws {
    // Cut short anywhere, or with its lengths and counts made nonsense, a file is played as far as
    // it goes or refused, and never brings the player down.
    let whole = MT2(patterns: [[(0, 0, .note()), (4, 1, .fastTracker(0xA, 0x0F))]], trackVolumes: [0x8000, 0x4000], drums: (samples: [0, 0, 0, 0, 0, 0, 0, 0], rows: [1, 0, 1, 0], volume: 200)).bytes
    var tried = 0
    for end in stride(from: 0, to: whole.count, by: 29) {
        if let renderer = try? TuneLoader.load(Array(whole[..<end]), format: .mt2) {
            _ = stereo(renderer, seconds: 0.05)
            tried += 1
        }
    }
    #expect(tried > 0)
    var random = SystemRandomNumberGenerator()
    for _ in 0 ..< 60 {
        var bytes = whole
        for _ in 0 ..< 8 { bytes[Int.random(in: 0 ..< bytes.count, using: &random)] = UInt8.random(in: 0 ... 255, using: &random) }
        // (Big counts and lengths where they are read.)
        for at in [102, 106, 110, 112, 114, 122, 124, 384, 388] where Bool.random(using: &random) { bytes[at] = 0xFF; bytes[at + 1] = 0xFF }
        if let renderer = try? TuneLoader.load(bytes, format: .mt2) { _ = stereo(renderer, seconds: 0.05) }
    }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("MT20".utf8) + [UInt8](repeating: 0, count: 100), format: .mt2) }
}
