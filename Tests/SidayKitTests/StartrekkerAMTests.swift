// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayAmigaTrackers
@testable import SidayFoundation
import Testing

// Fast checks of Startrekker's synthesised instruments, on tiny modules made here. The thorough check
// is made outside the package, against ASREPLAY, the routine Startrekker's makers gave away to play
// their modules with, in UADE's AudioSculpture player: the periods and volumes it gives Paula on each
// tick of the first 40 seconds of the 27 modules in the collection that have the file beside them,
// and how loud each side is from moment to moment over their first minute.

/// One synthesised instrument's record, of 120 bytes, as the file beside the module has it.
private func record(start: Int, attack: (Int, Int), secondAttack: (Int, Int), sustain: (level: Int, decay: Int, time: Int),
                    release: Int, waveform: Int = 2, pitchFall: Int = 0, vibrato: (depth: Int, speed: Int) = (0, 0),
                    octave: Int = 0) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 120)
    bytes[0] = 0x41 // "AM"
    bytes[1] = 0x4D
    let words = [start, attack.0, attack.1, secondAttack.0, secondAttack.1, sustain.level, sustain.decay, sustain.time, 0,
                 release, waveform, pitchFall, vibrato.depth, vibrato.speed, octave]
    for (i, word) in words.enumerated() {
        bytes[6 + i * 2] = UInt8(truncatingIfNeeded: word >> 8)
        bytes[7 + i * 2] = UInt8(truncatingIfNeeded: word)
    }
    return bytes
}

/// The file of instruments Startrekker 1.3 kept beside a module: its mark, what it kept that is not
/// the instruments, and a record for each of the 31 samples (those not given, not synthesised).
private func instruments(_ records: [Int: [UInt8]], mark: String = "ST1.3 ModuleINFO") -> [UInt8] {
    var file = Array(mark.utf8) + [UInt8](repeating: 0x18, count: 128)
    for sample in 1 ... 31 { file += records[sample] ?? [UInt8](repeating: 0, count: 120) }
    return file
}

/// A module of Startrekker's of one pattern, whose samples are all empty, but for the notes given:
/// (row, voice, period, sample).
private func module(_ notes: [(row: Int, voice: Int, period: Int, sample: Int)], tag: String = "FLT4") -> [UInt8] {
    var file = Array("synthesised".utf8) + [UInt8](repeating: 0, count: 9)
    for _ in 0 ..< 31 { file += [UInt8](repeating: 0, count: 22) + [0, 0, 0, 64, 0, 0, 0, 1] }
    file += [1, 0] + [UInt8](repeating: 0, count: 128) + Array(tag.utf8)
    var pattern = [UInt8](repeating: 0, count: 1024)
    for note in notes {
        let at = (note.row * 4 + note.voice) * 4
        pattern[at] = UInt8(note.sample & 0xF0) | UInt8(note.period >> 8)
        pattern[at + 1] = UInt8(note.period & 0xFF)
        pattern[at + 2] = UInt8(note.sample & 0x0F) << 4
    }
    return file + pattern
}

/// The sound of a module, mono, in ticks of 960 samples (a fiftieth of a second): how loud each
/// tick is, and how many times it crosses nothing.
private func ticks(_ data: [UInt8], synthesised: [UInt8]?, count: Int) throws -> [(level: Float, crossings: Int)] {
    let renderer = try MODRenderer(data, options: LoadOptions(), synthesised: synthesised)
    var buffer = [Float](repeating: 0, count: count * 960 * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: count * 960) }
    var out: [(Float, Int)] = []
    for tick in 0 ..< count {
        var sum: Float = 0, crossings = 0
        var last: Float = 0
        for i in 0 ..< 960 {
            let x = buffer[(tick * 960 + i) * 2]
            sum += x * x
            if (x > 0.001 && last < -0.001) || (x < -0.001 && last > 0.001) { crossings += 1 }
            if abs(x) > 0.001 { last = x }
        }
        out.append(((sum / 960).squareRoot(), crossings))
    }
    return out
}

@Test func startrekkerInstrumentsAreRead() throws {
    let file = instruments([3: record(start: 10, attack: (200, 5), secondAttack: (150, 6), sustain: (100, 7, 8), release: 9,
                                      waveform: 1, pitchFall: -2, vibrato: (3, 4), octave: 1)])
    #expect(StartrekkerSynth.isOne(file))
    #expect(StartrekkerSynth.isOne(instruments([:], mark: "ST1.2 ModuleINFO")))
    #expect(StartrekkerSynth.isOne(instruments([:], mark: "AudioSculpture10")))
    #expect(!StartrekkerSynth.isOne(instruments([:], mark: "ST1.4 ModuleINFO")))
    #expect(!StartrekkerSynth.isOne(Array("ST1.3".utf8)))
    let synth = try #require(StartrekkerSynth(file))
    #expect(synth.instrument(1) == nil && synth.instrument(0) == nil && synth.instrument(32) == nil)
    let one = try #require(synth.instrument(3))
    #expect(one.startLevel == 10 && one.attackLevel == 200 && one.attackSpeed == 5)
    #expect(one.secondAttackLevel == 150 && one.secondAttackSpeed == 6)
    #expect(one.sustainLevel == 100 && one.decaySpeed == 7 && one.sustainTime == 8 && one.releaseSpeed == 9)
    #expect(one.waveform == 1 && one.pitchFall == -2 && one.vibratoDepth == 3 && one.vibratoSpeed == 4 && one.octave == 1)
    #expect(synth.hasAny)
    // A file cut off in a record has nothing where it ends; one cut off before a record's mark has
    // no instrument there.
    let cut = try #require(StartrekkerSynth(Array(file[0 ..< 144 + 2 * 120 + 24])))
    #expect(cut.instrument(3)?.startLevel == 10 && cut.instrument(3)?.releaseSpeed == 0)
    #expect(try #require(StartrekkerSynth(Array(file[0 ..< 144 + 2 * 120 + 1]))).hasAny == false)
    #expect(StartrekkerSynth(Array(file[0 ..< 15])) == nil)
}

@Test func startrekkerSynthesisedNoteSoundsAndDiesAway() throws {
    // A square wave at full level at once, held for ten ticks after the tick it gets there, then let
    // go of at 63 a tick: four ticks of release.
    let square = record(start: 252, attack: (252, 1), secondAttack: (252, 1), sustain: (252, 1, 10), release: 63)
    let data = module([(0, 0, 428, 1)])
    let notes = instruments([1: square])

    // Without the file, the sample is empty and nothing would be heard: the module is not played.
    #expect(throws: TuneError.self) { try ticks(data, synthesised: nil, count: 30) }
    // (One sample used empty is not enough to take it to have instruments elsewhere; two are, and
    // then it wants the file of them.)
    let two = module([(0, 0, 428, 1), (0, 1, 428, 2)])
    do {
        _ = try MODRenderer(two, options: LoadOptions())
        Issue.record("played without its instruments")
    } catch let TuneError.missingCompanion(said) {
        #expect(said == "its synthesised instruments")
    }
    #expect(try MODRenderer(two, options: LoadOptions(), synthesised: notes).info.shortfalls.isEmpty)

    let heard = try ticks(data, synthesised: notes, count: 30)
    // Stages 1 to 3 take a tick each, the sustain 11, the release 4: the sound lasts 17 ticks, and the
    // voice is then stopped.
    for tick in 1 ..< 16 { #expect(heard[tick].level > 0.02, "tick \(tick)") }
    for tick in 19 ..< 30 { #expect(heard[tick].level < 0.0005, "tick \(tick)") }
    // Its release: quieter on each tick.
    #expect(heard[17].level < heard[13].level * 0.8)
    // 32 bytes a cycle, at a period of 428: 3,546,895 / (428 * 32) = 259 cycles a second, or 5.2 a
    // tick, and twice as many crossings.
    #expect((9 ... 12).contains(heard[8].crossings))

    // An octave down: the period is doubled, and the pitch is halved.
    let lower = record(start: 252, attack: (252, 1), secondAttack: (252, 1), sustain: (252, 1, 10), release: 63, octave: 1)
    let low = try ticks(data, synthesised: instruments([1: lower]), count: 12)
    #expect((4 ... 6).contains(low[8].crossings))
}

@Test func startrekkerSynthesisedAttackRises() throws {
    // From nothing to full, 4 a tick: 63 ticks of attack, then held a long while.
    let rising = record(start: 0, attack: (252, 4), secondAttack: (252, 1), sustain: (252, 1, 1000), release: 1, waveform: 0)
    let heard = try ticks(module([(0, 2, 214, 5)]), synthesised: instruments([5: rising]), count: 80)
    #expect(heard[10].level < heard[30].level)
    #expect(heard[30].level < heard[55].level)
    #expect(abs(heard[70].level - heard[75].level) < heard[75].level * 0.05)
    #expect(heard[70].level > heard[55].level)
}

@Test func startrekkerInstrumentsAreForStartrekkerModulesAlone() throws {
    // ProTracker's modules are not Startrekker's, and take no file beside them: this one, whose
    // sample is empty, has nothing to be heard by, and is not played.
    let square = record(start: 252, attack: (252, 1), secondAttack: (252, 1), sustain: (252, 1, 10), release: 63)
    func refusal(_ data: [UInt8], _ synthesised: [UInt8]) -> String {
        do {
            _ = try ticks(data, synthesised: synthesised, count: 10)
            return ""
        } catch {
            return "\(error)"
        }
    }
    #expect(refusal(module([(0, 0, 428, 1)], tag: "M.K."), instruments([1: square])) == "\(Shortfall.nothingToHear)")
    // A file that is not one of instruments is no file of them.
    #expect(refusal(module([(0, 0, 428, 1)]), [1, 2, 3]) == "\(Shortfall.nothingToHear)")
}

@Test func startrekkerNoiseAndWildValuesDoNotTrap() throws {
    // Noise, a waveform past the four, and words at their ends: every sum wraps as the 68000's do.
    let records: [Int: [UInt8]] = [
        1: record(start: 0x7FFF, attack: (-0x8000, 0x7FFF), secondAttack: (0x7FFF, -1), sustain: (-1, 0x7FFF, 0x7FFF),
                  release: -0x8000, waveform: 3, pitchFall: 0x7FFF, vibrato: (-0x8000, 0x7FFF), octave: 0xFFFF),
        2: record(start: 100, attack: (200, 3), secondAttack: (50, 2), sustain: (80, 1, 3), release: 2, waveform: 0xFFFF,
                  pitchFall: -0x8000, vibrato: (0x7FFF, -0x8000), octave: 15),
        3: record(start: 252, attack: (252, 1), secondAttack: (252, 1), sustain: (252, 1, 5), release: 9, waveform: 3,
                  vibrato: (60, 90), octave: 2),
    ]
    let data = module([(0, 0, 428, 1), (0, 1, 113, 2), (0, 2, 856, 3), (8, 3, 428, 3), (16, 0, 0xFFF, 2)])
    let heard = try ticks(data, synthesised: instruments(records), count: 200)
    #expect(heard.count == 200)
}
