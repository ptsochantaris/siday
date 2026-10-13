// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from HivelyTracker, Copyright (c) Pete Gordon, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): the replayer of HivelyTracker 1.9.

/// The periods of five octaves of notes, the first of them for no note at all.
private let hvlPeriods: [Int32] = [
    0,
    3424, 3232, 3048, 2880, 2712, 2560, 2416, 2280, 2152, 2032, 1920, 1812,
    1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 906,
    856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
    428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
    214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
]

/// A sine wave, for vibrato.
private let hvlVibrato: [Int32] = [
    0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
    255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24,
    0, -24, -49, -74, -97, -120, -141, -161, -180, -197, -212, -224, -235, -244, -250, -253,
    -255, -253, -250, -244, -235, -224, -212, -197, -180, -161, -141, -120, -97, -74, -49, -24,
]

/// How much of a voice goes to the left, by where it is placed from 0, hard left, to 255, hard
/// right: a quarter of a sine wave, so that a voice is as loud wherever it is. The tracker works
/// these out as it starts, in floating point, and what it arrives at is written out here, so that
/// they are the same numbers wherever this runs. (Its sine falls a hair short of one, which is why
/// the most there is of a voice is 254 parts in 256 and not 255.)
private let hvlPanLeft: [UInt8] = [
    254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 253,
    253, 253, 253, 253, 253, 252, 252, 252, 252, 252, 251, 251, 251, 250, 250, 250,
    250, 249, 249, 249, 248, 248, 248, 247, 247, 246, 246, 246, 245, 245, 244, 244,
    244, 243, 243, 242, 242, 241, 241, 240, 240, 239, 239, 238, 237, 237, 236, 236,
    235, 234, 234, 233, 233, 232, 231, 231, 230, 229, 229, 228, 227, 227, 226, 225,
    224, 224, 223, 222, 221, 221, 220, 219, 218, 217, 217, 216, 215, 214, 213, 212,
    212, 211, 210, 209, 208, 207, 206, 205, 204, 203, 202, 201, 201, 200, 199, 198,
    197, 196, 195, 194, 193, 192, 191, 189, 188, 187, 186, 185, 184, 183, 182, 181,
    180, 179, 178, 176, 175, 174, 173, 172, 171, 170, 168, 167, 166, 165, 164, 162,
    161, 160, 159, 158, 156, 155, 154, 153, 151, 150, 149, 148, 146, 145, 144, 142,
    141, 140, 139, 137, 136, 135, 133, 132, 131, 129, 128, 127, 125, 124, 122, 121,
    120, 118, 117, 116, 114, 113, 111, 110, 109, 107, 106, 104, 103, 101, 100, 99,
    97, 96, 94, 93, 91, 90, 88, 87, 85, 84, 82, 81, 79, 78, 77, 75,
    74, 72, 71, 69, 68, 66, 64, 63, 61, 60, 58, 57, 55, 54, 52, 51,
    49, 48, 46, 45, 43, 42, 40, 38, 37, 35, 34, 32, 31, 29, 28, 26,
    24, 23, 21, 20, 18, 17, 15, 14, 12, 10, 9, 7, 6, 4, 3, 0,
]

/// And how much goes to the right.
private let hvlPanRight: [UInt8] = [
    0, 1, 3, 4, 6, 7, 9, 10, 12, 14, 15, 17, 18, 20, 21, 23,
    24, 26, 28, 29, 31, 32, 34, 35, 37, 38, 40, 42, 43, 45, 46, 48,
    49, 51, 52, 54, 55, 57, 58, 60, 61, 63, 64, 66, 68, 69, 71, 72,
    74, 75, 77, 78, 79, 81, 82, 84, 85, 87, 88, 90, 91, 93, 94, 96,
    97, 99, 100, 101, 103, 104, 106, 107, 109, 110, 111, 113, 114, 116, 117, 118,
    120, 121, 122, 124, 125, 127, 128, 129, 131, 132, 133, 135, 136, 137, 139, 140,
    141, 142, 144, 145, 146, 148, 149, 150, 151, 153, 154, 155, 156, 158, 159, 160,
    161, 162, 164, 165, 166, 167, 168, 170, 171, 172, 173, 174, 175, 176, 178, 179,
    180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 191, 192, 193, 194, 195, 196,
    197, 198, 199, 200, 201, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211,
    212, 212, 213, 214, 215, 216, 217, 217, 218, 219, 220, 221, 221, 222, 223, 224,
    224, 225, 226, 227, 227, 228, 229, 229, 230, 231, 231, 232, 233, 233, 234, 234,
    235, 236, 236, 237, 237, 238, 239, 239, 240, 240, 241, 241, 242, 242, 243, 243,
    244, 244, 244, 245, 245, 246, 246, 246, 247, 247, 248, 248, 248, 249, 249, 249,
    250, 250, 250, 250, 251, 251, 251, 252, 252, 252, 252, 252, 253, 253, 253, 253,
    253, 253, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254,
]

/// Where the voices that start on the left are placed, and those on the right, by how far apart
/// the file says its voices start.
private let hvlStereoLeft: [UInt32] = [128, 96, 64, 32, 0]
private let hvlStereoRight: [UInt32] = [128, 160, 193, 225, 255]

/// HivelyTracker's replayer: what the tracker does fifty times a second, or a few times that, to
/// turn a file's tracks and instruments into sound, and the mixer that makes the sound.
///
/// It is AHX's replayer with more to it, and with nothing of the Amiga under it. Each voice has a
/// buffer of 640 bytes to go round, as AHX gave each of Paula's; but it is the tracker itself that
/// goes round them, at the rate of its output, taking for each sample the byte it has got to and
/// nothing in between, and placing each voice between the two speakers. An instrument can have its
/// wave multiplied by a second one, a triangle or a sawtooth at a pitch of its own, which is ring
/// modulation.
///
/// It is the tracker's, mistakes and all: the numbers are of the widths the tracker's are and go
/// round where they do, because tunes were written by ear against what came of it.
struct HVLReplayer: ~Copyable {
    /// The four waves an instrument's list can choose between.
    private enum Wave {
        static let triangle: UInt8 = 0, sawtooth: UInt8 = 1, square: UInt8 = 2, noise: UInt8 = 3
    }

    /// One of the voices. The names are the tracker's own, spelled out.
    private struct Voice {
        var track: Int16 = 0, nextTrack: Int16 = 0
        var transpose: Int16 = 0
        /// The transposition a voice keeps into the next position, when it is asked to: 1000 for none.
        var overrideTranspose: Int16 = 1000

        // The envelope: its level, with eight bits after the point, and for each of its four parts
        // how many ticks are left of it and how much the level moves in each.
        var envelope: Int32 = 0
        var attackFrames: Int16 = 0, decayFrames: Int16 = 0, sustainFrames: Int16 = 0, releaseFrames: Int16 = 0
        var attackStep: Int16 = 0, decayStep: Int16 = 0, releaseStep: Int16 = 0

        /// The number of its instrument, and 0 for none yet.
        var instrument = 0
        var wave: UInt8 = 0
        var waveLength: UInt16 = 0
        var instrumentPeriod: UInt16 = 0, trackPeriod: UInt16 = 0, vibratoPeriod: UInt16 = 0
        var noteMaxVolume: Int16 = 0
        var listVolume: UInt16 = 0
        var trackMasterVolume: UInt8 = 0x40

        var newWave = false, plantSquare = false, ignoreSquare = false, plantPeriod = false, fixedNote = false

        var volumeSlideUp: Int16 = 0, volumeSlideDown: Int16 = 0

        var hardCut: Int16 = 0
        var hardCutRelease = false
        var hardCutReleaseFrames: Int16 = 0

        var periodSlideSpeed: Int16 = 0, periodSlidePeriod: Int16 = 0, periodSlideLimit: Int16 = 0
        var periodSlideOn = false, periodSlideWithLimit = false

        var listSlideSpeed: Int16 = 0, listSlidePeriod: Int16 = 0
        var listSlideOn = false

        var vibratoDelay: Int16 = 0, vibratoCurrent: Int16 = 0, vibratoDepth: Int16 = 0, vibratoSpeed: Int16 = 0

        var squareOn = false, squareInit = false
        var squareWait: Int16 = 0, squareLowerLimit: Int16 = 0, squareUpperLimit: Int16 = 0, squarePosition: Int16 = 0
        var squareSign: Int16 = 0
        var squareSlidingIn = false

        var filterOn = false, filterInit = false
        var filterWait: Int16 = 0, filterLowerLimit: Int16 = 0, filterUpperLimit: Int16 = 0, filterPosition: Int16 = 0
        var filterSign: Int16 = 0
        var filterSpeed: Int16 = 0
        var filterSlidingIn = false
        /// Both a mark and a number: a filter setting from the track, to be used in place of the
        /// next one the instrument's list asks for.
        var ignoreFilter: Int16 = 0

        // The instrument's list: which entry is next, how long each lasts, and whether there is one.
        var listCurrent: Int16 = 0, listSpeed: Int16 = 0, listWait: Int16 = 0
        var hasList = false

        var noteDelayWait: Int16 = 0
        var noteDelayOn = false
        var noteCutWait: Int16 = 0
        var noteCutOn = false

        /// The wave to be copied into the voice's buffer, and nil for none.
        var source: UnsafePointer<Int8>?
        var audioPeriod: Int16 = 0, audioVolume: Int16 = 0
        /// Stirred each time a stretch of noise is chosen. Every voice has its own.
        var noiseSeed: Int32 = 0x280

        // What the mixer goes by: where the voice is in its buffer and how far it moves each
        // sample, with sixteen bits after the point; how loud it is; and how much of it goes to
        // each side.
        var samplePosition: UInt32 = 0, delta: UInt32 = 1
        var voiceVolume: UInt8 = 0
        /// Where it is between the speakers, and where the track last put it: an instrument's list
        /// can move it for the length of a note.
        var pan: UInt32 = 128, setPan: UInt32 = 128
        var panLeft: UInt32 = 0, panRight: UInt32 = 0

        // Ring modulation: the second wave, the buffer it goes round, and its own pitch.
        var ringOn = false
        var ringPosition: UInt32 = 0, ringDelta: UInt32 = 0
        var ringSource: UnsafePointer<Int8>?
        var ringNewWave = false, ringPlantPeriod = false, ringFixedPeriod = false
        var ringWave: UInt8 = 0
        var ringBasePeriod: Int16 = 0, ringAudioPeriod: Int16 = 0

        /// For the lights: the least and the most the voice has been in the tick just mixed.
        var low: Int32 = 0, high: Int32 = 0
    }

    /// How long the buffer is that each voice goes round, and the same with sixteen bits after the point.
    static let voiceSpace = 0x280
    private static let span: UInt32 = 0x280 << 16
    private static let squareSpace = 0x80
    /// What each voice has of `memory`: its buffer, the buffer of its second wave, and a square
    /// wave, made up afresh as its width or its filter moves.
    private static let voiceMemory = 2 * voiceSpace + squareSpace
    /// The Amiga's clock, as the tracker has it: a note's period is still a count of this.
    static let clockHz = 3_546_895.0

    let module: HVLModule
    private let waves: AHXWaves
    private let memory: UnsafeMutablePointer<Int8>
    private let visited: UnsafeMutablePointer<Bool>
    private var voices = InlineArray<16, Voice>(repeating: Voice())
    private let channels: Int

    /// How many ticks are left of the row being played.
    private var stepWait: UInt16 = 0
    private var newPosition = true
    private(set) var tempo: Int16 = 6
    private var patternBreak = false
    private var jumpPosition: UInt16 = 0, jumpRow: UInt16 = 0
    private var row: Int16 = 0
    /// Where in the list of positions it is.
    private(set) var position: Int16 = 0

    /// True once the tune has stopped itself, with a tempo of nothing.
    var stopped: Bool { tempo == 0 }
    /// Whether a note has been played.
    private(set) var playedNote = false
    /// For the lights: which voices have had a note started on them, until `takeNotes`.
    private var struck = InlineArray<16, Bool>(repeating: false)
    /// The voices that are left out of the sound: they play on, and are given to neither side.
    private var muted = InlineArray<16, Bool>(repeating: false)

    /// - Parameter position: where in the list of positions to start.
    init(_ module: HVLModule, waves: AHXWaves, position start: UInt16 = 0) {
        self.module = module
        self.waves = waves
        channels = module.channels
        memory = .allocate(capacity: HVLModule.mostChannels * Self.voiceMemory)
        memory.initialize(repeating: 0, count: HVLModule.mostChannels * Self.voiceMemory)
        visited = .allocate(capacity: HVLModule.mostPositions * (HVLModule.rows + 1))
        visited.initialize(repeating: false, count: HVLModule.mostPositions * (HVLModule.rows + 1))
        position = start < module.positionCount ? Int16(start) : 0

        // The voices start as the Amiga had them: of each four, the first and last to the left
        // and the middle two to the right, as far out as the file says.
        for v in 0 ..< HVLModule.mostChannels {
            let pan = v & 3 == 0 || v & 3 == 3 ? hvlStereoLeft[module.stereo] : hvlStereoRight[module.stereo]
            voices[v].setPan = pan
            place(v, at: pan)
        }
    }

    deinit {
        memory.deallocate()
        visited.deallocate()
    }

    /// Puts a voice somewhere between the speakers. One that is left out of the sound is put
    /// there too, and given to neither side: the mixer goes through it as through any other.
    @inline(__always) private mutating func place(_ v: Int, at pan: UInt32) {
        voices[v].pan = pan
        voices[v].panLeft = muted[v] ? 0 : UInt32(hvlPanLeft[Int(pan & 255)])
        voices[v].panRight = muted[v] ? 0 : UInt32(hvlPanRight[Int(pan & 255)])
    }

    /// Sixteen bits of a number that may not fit in them, as the tracker keeps it.
    @inline(__always) private static func word(_ value: Int32) -> Int16 { Int16(truncatingIfNeeded: value) }

    /// The period of a note. (One past the five octaves there are is read by the tracker out of
    /// whatever follows its table. Here it has no period.)
    @inline(__always) private static func period(_ note: Int32) -> Int32 {
        note >= 0 && note < Int32(hvlPeriods.count) ? hvlPeriods[Int(note)] : 0
    }

    /// How far through its buffer a voice moves each sample to play a period: the Amiga's clock
    /// over the period is how many bytes a second, and that over the rate of the output, with
    /// sixteen bits after the point. It is worked out in the tracker's mixture of single and double
    /// precision, which is where the last of those bits come from.
    @inline(__always) private static func delta(_ period: Int16) -> UInt32 {
        // (A second wave that is taken off again in the entry that asked for it leaves its period
        // to be worked out from nothing. What comes of that is never used.)
        guard period > 0 else { return 1 }
        let frequency = Float(3_546_895) * 65536.0 / Float(period)
        var delta = UInt32(Double(frequency) / Double(outputSampleRate))
        if delta > span { delta -= span }
        return delta == 0 ? 1 : delta
    }

    // MARK: Rows

    /// The first things a row's command does, before any instrument is started: those that are
    /// about the whole tune, and where the voice is placed.
    private mutating func firstCommand(_ v: Int, _ command: UInt8, _ parameter: Int32) {
        switch command {
        case 0x0:
            // The hundreds of a position to jump to.
            if parameter & 0x0F > 0, parameter & 0x0F <= 9 { jumpPosition = UInt16(parameter & 0xF) }
        case 0x5, 0xA:
            voices[v].volumeSlideDown = Int16(parameter & 0x0F)
            voices[v].volumeSlideUp = Int16(parameter >> 4)
        case 0x7:
            // Where the voice is, as a number with a sign: nothing is the middle.
            let pan = UInt32((parameter > 127 ? parameter - 256 : parameter) + 128)
            voices[v].setPan = pan
            place(v, at: pan)
        case 0xB:
            jumpPosition = jumpPosition &* 100 &+ UInt16(parameter & 0x0F) &+ UInt16(parameter >> 4) &* 10
            patternBreak = true
        case 0xD:
            // On to the next position, at a row that is written in decimal. (The row after a
            // track's last can be asked for, and is played.)
            jumpPosition = UInt16(truncatingIfNeeded: Int32(position) + 1)
            jumpRow = UInt16(parameter & 0x0F) + UInt16(parameter >> 4) * 10
            patternBreak = true
            if jumpRow > UInt16(module.trackLength) { jumpRow = 0 }
        case 0xE:
            if parameter >> 4 == 0xC, parameter & 0x0F < Int32(tempo) {
                // A note to be cut short, so many ticks into the row.
                voices[v].noteCutWait = Int16(parameter & 0x0F)
                if voices[v].noteCutWait != 0 {
                    voices[v].noteCutOn = true
                    voices[v].hardCutRelease = false
                }
            }
        case 0xF:
            tempo = Int16(parameter)
        default:
            break
        }
    }

    /// What a row's command does once an instrument has been started and before the note is taken:
    /// the square wave's width, and a slide to the note in place of playing it.
    private mutating func secondCommand(_ v: Int, _ command: UInt8, _ parameter: Int32, _ note: inout Int32) {
        switch command {
        case 0x9:
            // The square wave's width, which the instrument's list is then not to set.
            voices[v].squarePosition = Self.word(parameter >> (5 - Int32(voices[v].waveLength)))
            voices[v].ignoreSquare = true
        case 0x3, 0x5:
            if command == 0x3, parameter != 0 { voices[v].periodSlideSpeed = Int16(parameter) }
            if note != 0 {
                let difference = Self.period(Int32(voices[v].trackPeriod)) - Self.period(note)
                if difference + Int32(voices[v].periodSlidePeriod) != 0 { voices[v].periodSlideLimit = Self.word(0 - difference) }
            }
            voices[v].periodSlideOn = true
            voices[v].periodSlideWithLimit = true
            note = 0
        default:
            break
        }
    }

    /// And what it does after the note is taken: slides, the filter, volumes and the rest.
    private mutating func thirdCommand(_ v: Int, _ command: UInt8, _ parameter: Int32) {
        switch command {
        case 0x1:
            voices[v].periodSlideSpeed = Int16(0 - parameter)
            voices[v].periodSlideOn = true
            voices[v].periodSlideWithLimit = false
        case 0x2:
            voices[v].periodSlideSpeed = Int16(parameter)
            voices[v].periodSlideOn = true
            voices[v].periodSlideWithLimit = false
        case 0x4:
            // The filter: a setting to be used when the instrument's list next asks for one, or,
            // from 0x41 up, where it is to be now.
            if parameter == 0 || parameter == 0x40 || parameter > 0x7F { break }
            if parameter < 0x40 {
                voices[v].ignoreFilter = Int16(parameter)
            } else {
                voices[v].filterPosition = Int16(parameter - 0x40)
            }
        case 0xC:
            // One command for three volumes, by how large its number is: the note's, every voice's,
            // or this voice's.
            var volume = parameter
            if volume <= 0x40 {
                voices[v].noteMaxVolume = Int16(volume)
                break
            }
            volume -= 0x50
            if volume < 0 { break }
            if volume <= 0x40 {
                for voice in 0 ..< channels { voices[voice].trackMasterVolume = UInt8(volume) }
                break
            }
            volume -= 0xA0 - 0x50
            if volume >= 0, volume <= 0x40 { voices[v].trackMasterVolume = UInt8(volume) }
        case 0xE:
            let low = Int16(parameter & 0x0F)
            switch parameter >> 4 {
            case 0x1:
                voices[v].periodSlidePeriod &-= low
                voices[v].plantPeriod = true
            case 0x2:
                voices[v].periodSlidePeriod &+= low
                voices[v].plantPeriod = true
            case 0x4:
                voices[v].vibratoDepth = low
            case 0xA:
                voices[v].noteMaxVolume &+= low
                if voices[v].noteMaxVolume > 0x40 { voices[v].noteMaxVolume = 0x40 }
            case 0xB:
                voices[v].noteMaxVolume &-= low
                if voices[v].noteMaxVolume < 0 { voices[v].noteMaxVolume = 0 }
            case 0xF:
                // From HivelyTracker 1.5: the voice keeps the transposition it has into the next
                // position, until its next note.
                if module.version >= 1, low == 1 { voices[v].overrideTranspose = voices[v].transpose }
            default:
                break
            }
        default:
            break
        }
    }

    /// Reads a voice's row of its track and does what it says. This is where a note begins.
    private mutating func processStep(_ v: Int) {
        voices[v].volumeSlideUp = 0
        voices[v].volumeSlideDown = 0

        let step = module.step(Int(module.track(Int(position), v)), Int(row))
        var note = Int32(step.note)
        let first = Int32(step.parameter), second = Int32(step.secondParameter)

        // A note to be held back so many ticks: the row is left for now, and read again then.
        // Either command can ask for it, and the second is looked at only if the first has not
        // just been answered.
        var delayed = false
        if step.command == 0xE, first & 0xF0 == 0xD0 {
            if voices[v].noteDelayOn {
                voices[v].noteDelayOn = false
                delayed = true
            } else if first & 0x0F < Int32(tempo) {
                voices[v].noteDelayWait = Int16(first & 0x0F)
                if voices[v].noteDelayWait != 0 {
                    voices[v].noteDelayOn = true
                    return
                }
            }
        }
        if !delayed, step.secondCommand == 0xE, second & 0xF0 == 0xD0 {
            if voices[v].noteDelayOn {
                voices[v].noteDelayOn = false
            } else if second & 0x0F < Int32(tempo) {
                voices[v].noteDelayWait = Int16(second & 0x0F)
                if voices[v].noteDelayWait != 0 {
                    voices[v].noteDelayOn = true
                    return
                }
            }
        }

        if note != 0 { voices[v].overrideTranspose = 1000 }

        firstCommand(v, step.command, first)
        firstCommand(v, step.secondCommand, second)

        if step.instrument != 0, Int(step.instrument) <= module.instrumentCount {
            playedNote = true
            struck[v] = true
            let instrument = module.instruments[Int(step.instrument)]

            // Back to where the track last put the voice, if an instrument's list has moved it.
            place(v, at: voices[v].setPan)

            voices[v].periodSlideSpeed = 0
            voices[v].periodSlidePeriod = 0
            voices[v].periodSlideLimit = 0
            voices[v].listVolume = 0x40
            voices[v].instrument = Int(step.instrument)
            voices[v].samplePosition = 0

            // The envelope starts from nothing. The step of each of its parts is kept in sixteen
            // bits, and a part that is asked to move further than those can say goes wrong.
            voices[v].envelope = 0
            let attack = Int32(instrument.attackVolume), decay = Int32(instrument.decayVolume), release = Int32(instrument.releaseVolume)
            voices[v].attackFrames = instrument.attackFrames
            voices[v].attackStep = Self.word(instrument.attackFrames != 0 ? attack * 256 / Int32(instrument.attackFrames) : attack * 256)
            voices[v].decayFrames = instrument.decayFrames
            voices[v].decayStep = Self.word(instrument.decayFrames != 0 ? (decay - attack) * 256 / Int32(instrument.decayFrames) : decay * 256)
            voices[v].sustainFrames = instrument.sustainFrames
            voices[v].releaseFrames = instrument.releaseFrames
            voices[v].releaseStep = Self.word(instrument.releaseFrames != 0 ? (release - decay) * 256 / Int32(instrument.releaseFrames) : release * 256)

            voices[v].waveLength = UInt16(instrument.waveLength)
            voices[v].noteMaxVolume = Int16(instrument.volume)

            voices[v].vibratoCurrent = 0
            voices[v].vibratoDelay = Int16(instrument.vibratoDelay)
            voices[v].vibratoDepth = Int16(instrument.vibratoDepth)
            voices[v].vibratoSpeed = Int16(instrument.vibratoSpeed)
            voices[v].vibratoPeriod = 0

            voices[v].hardCutRelease = instrument.hardCutRelease
            voices[v].hardCut = Int16(instrument.hardCutReleaseFrames)

            voices[v].ignoreSquare = false
            voices[v].squareSlidingIn = false
            voices[v].squareWait = 0
            voices[v].squareOn = false
            // A square wave's width is kept for the wave's length: 32 steps for the longest, and half
            // as many for each length shorter.
            let shift = 5 - instrument.waveLength
            let lower = Int16(instrument.squareLowerLimit >> shift), upper = Int16(instrument.squareUpperLimit >> shift)
            voices[v].squareLowerLimit = min(lower, upper)
            voices[v].squareUpperLimit = max(lower, upper)

            voices[v].ignoreFilter = 0
            voices[v].filterWait = 0
            voices[v].filterOn = false
            voices[v].filterSlidingIn = false
            voices[v].filterSpeed = Int16(instrument.filterSpeed)
            voices[v].filterLowerLimit = Int16(min(instrument.filterLowerLimit, instrument.filterUpperLimit))
            voices[v].filterUpperLimit = Int16(max(instrument.filterLowerLimit, instrument.filterUpperLimit))
            voices[v].filterPosition = 32

            voices[v].listWait = 0
            voices[v].listCurrent = 0
            voices[v].listSpeed = instrument.listSpeed
            voices[v].hasList = true

            // No second wave, until the instrument's list asks for one.
            voices[v].ringOn = false
            voices[v].ringPosition = 0
            voices[v].ringPlantPeriod = false
            voices[v].ringNewWave = false
        }

        voices[v].periodSlideOn = false

        secondCommand(v, step.command, first, &note)
        secondCommand(v, step.secondCommand, second, &note)

        if note != 0 {
            playedNote = true
            voices[v].trackPeriod = UInt16(note)
            voices[v].plantPeriod = true
        }

        thirdCommand(v, step.command, first)
        thirdCommand(v, step.secondCommand, second)
    }

    // MARK: Instruments

    /// One of the two commands of an entry in an instrument's list.
    private mutating func listCommand(_ v: Int, _ command: UInt8, _ value: UInt8) {
        var parameter = Int32(value)
        switch command {
        case 0:
            // Where the filter is set, unless the track has said where.
            guard parameter > 0, parameter < 0x40 else { return }
            if voices[v].ignoreFilter != 0 {
                voices[v].filterPosition = voices[v].ignoreFilter
                voices[v].ignoreFilter = 0
            } else {
                voices[v].filterPosition = Int16(parameter)
            }
            voices[v].newWave = true
        case 1:
            voices[v].listSlideSpeed = Int16(parameter)
            voices[v].listSlideOn = true
        case 2:
            voices[v].listSlideSpeed = Int16(0 - parameter)
            voices[v].listSlideOn = true
        case 3:
            // How wide the square wave is, unless the track has said how wide.
            if voices[v].ignoreSquare {
                voices[v].ignoreSquare = false
            } else {
                voices[v].squarePosition = Self.word(parameter >> (5 - Int32(voices[v].waveLength)))
            }
        case 4:
            // Starts or stops the sweep of the square wave's width, of the filter, or of both.
            if parameter == 0 {
                voices[v].squareOn.toggle()
                voices[v].squareInit = voices[v].squareOn
                voices[v].squareSign = 1
            } else {
                if parameter & 0x0F != 0 {
                    voices[v].squareOn.toggle()
                    voices[v].squareInit = voices[v].squareOn
                    voices[v].squareSign = parameter & 0x0F == 0x0F ? -1 : 1
                }
                if parameter & 0xF0 != 0 {
                    voices[v].filterOn.toggle()
                    voices[v].filterInit = voices[v].filterOn
                    voices[v].filterSign = parameter & 0xF0 == 0xF0 ? -1 : 1
                }
            }
        case 5:
            // On from another entry of the list; or, if there is no such entry, the end of it.
            voices[v].listCurrent = Int16(parameter)
        case 7, 8:
            // Ring modulation, with a triangle or with a sawtooth: at a note of its own, or at one
            // counted from the track's note; and any other number takes it off again.
            if parameter >= 1, parameter <= 0x3C {
                voices[v].ringBasePeriod = Int16(parameter)
                voices[v].ringFixedPeriod = true
            } else if parameter >= 0x81, parameter <= 0xBC {
                voices[v].ringBasePeriod = Int16(parameter - 0x80)
                voices[v].ringFixedPeriod = false
            } else {
                voices[v].ringBasePeriod = 0
                voices[v].ringFixedPeriod = false
                voices[v].ringNewWave = false
                voices[v].ringSource = nil
                voices[v].ringOn = false
                return
            }
            voices[v].ringWave = command == 7 ? Wave.triangle : Wave.sawtooth
            voices[v].ringNewWave = true
            voices[v].ringPlantPeriod = true
        case 9:
            // Where the voice is, for as long as this note lasts.
            place(v, at: UInt32((parameter > 127 ? parameter - 256 : parameter) + 128))
        case 12:
            if parameter <= 0x40 {
                voices[v].noteMaxVolume = Int16(parameter)
                return
            }
            parameter -= 0x50
            if parameter < 0 { return }
            if parameter <= 0x40 {
                voices[v].listVolume = UInt16(parameter)
                return
            }
            parameter -= 0xA0 - 0x50
            if parameter >= 0, parameter <= 0x40 { voices[v].trackMasterVolume = UInt8(parameter) }
        case 15:
            voices[v].listSpeed = Int16(parameter)
            voices[v].listWait = Int16(parameter)
        default:
            break
        }
    }

    /// The period of a note of an instrument: with the track's and the position's added unless the
    /// instrument's is to stand alone, and with the slides and the vibrato.
    private func period(_ v: Int, of note: Int32, fixed: Bool) -> Int16 {
        var note = note
        if !fixed {
            let transpose = voices[v].overrideTranspose != 1000 ? voices[v].overrideTranspose : voices[v].transpose
            note = Int32(Self.word(note + Int32(transpose) + Int32(voices[v].trackPeriod) - 1))
        }
        var period = hvlPeriods[Int(max(0, min(5 * 12, note)))]
        if !fixed { period = Int32(Self.word(period + Int32(voices[v].periodSlidePeriod))) }
        // (The vibrato's is kept without a sign, and comes right again when the sum is cut to sixteen bits.)
        period = Int32(Self.word(period + Int32(voices[v].listSlidePeriod) + Int32(voices[v].vibratoPeriod)))
        return Int16(max(0x0071, min(0x0D60, period)))
    }

    /// What is done to a voice on every tick: its envelope, its slides and vibrato, the next entry
    /// of its instrument's list when that is due, the sweeps of its square wave and its filter; and
    /// from all of them the wave, the period and the volume the mixer is to be given.
    private mutating func processFrame(_ v: Int) {
        if voices[v].noteDelayOn {
            if voices[v].noteDelayWait <= 0 {
                processStep(v)
            } else {
                voices[v].noteDelayWait -= 1
            }
        }

        if voices[v].hardCut != 0 {
            // If the next row starts an instrument, this note is cut off some ticks before it.
            let next: UInt8 = Int32(row) + 1 < Int32(module.trackLength)
                ? module.step(Int(voices[v].track), Int(row) + 1).instrument
                : module.step(Int(voices[v].nextTrack), 0).instrument
            if next != 0 {
                let wait = max(0, Int32(tempo) - Int32(voices[v].hardCut))
                if !voices[v].noteCutOn {
                    voices[v].noteCutOn = true
                    voices[v].noteCutWait = Self.word(wait)
                    voices[v].hardCutReleaseFrames = Self.word(Int32(tempo) - wait)
                } else {
                    voices[v].hardCut = 0
                }
            }
        }

        let instrument = module.instruments[voices[v].instrument]

        if voices[v].noteCutOn {
            if voices[v].noteCutWait <= 0 {
                voices[v].noteCutOn = false
                if voices[v].hardCutRelease {
                    // Not silenced at once, but let go: the envelope's release from where it is.
                    voices[v].releaseFrames = voices[v].hardCutReleaseFrames
                    voices[v].releaseStep = 0
                    if voices[v].releaseFrames > 0 {
                        let fall = voices[v].envelope &- (Int32(instrument.releaseVolume) << 8)
                        voices[v].releaseStep = Self.word((0 &- fall) / Int32(voices[v].releaseFrames))
                    }
                    voices[v].attackFrames = 0
                    voices[v].decayFrames = 0
                    voices[v].sustainFrames = 0
                } else {
                    voices[v].noteMaxVolume = 0
                }
            } else {
                voices[v].noteCutWait -= 1
            }
        }

        // The envelope.
        if voices[v].attackFrames != 0 {
            voices[v].envelope &+= Int32(voices[v].attackStep)
            voices[v].attackFrames &-= 1
            if voices[v].attackFrames <= 0 { voices[v].envelope = Int32(instrument.attackVolume) << 8 }
        } else if voices[v].decayFrames != 0 {
            voices[v].envelope &+= Int32(voices[v].decayStep)
            voices[v].decayFrames &-= 1
            if voices[v].decayFrames <= 0 { voices[v].envelope = Int32(instrument.decayVolume) << 8 }
        } else if voices[v].sustainFrames != 0 {
            voices[v].sustainFrames &-= 1
        } else if voices[v].releaseFrames != 0 {
            voices[v].envelope &+= Int32(voices[v].releaseStep)
            voices[v].releaseFrames &-= 1
            if voices[v].releaseFrames <= 0 { voices[v].envelope = Int32(instrument.releaseVolume) << 8 }
        }

        // The track's slide of the volume.
        voices[v].noteMaxVolume = max(0, min(0x40, voices[v].noteMaxVolume &+ voices[v].volumeSlideUp &- voices[v].volumeSlideDown))

        // And of the pitch: to a note, where it stops, or for as long as it is asked for.
        if voices[v].periodSlideOn {
            if voices[v].periodSlideWithLimit {
                let away = Int32(voices[v].periodSlidePeriod) - Int32(voices[v].periodSlideLimit)
                var speed = Int32(voices[v].periodSlideSpeed)
                if away > 0 { speed = 0 - speed }
                if away != 0 {
                    // If the step would take it past the note, the two differ in sign.
                    if (away + speed) ^ away >= 0 {
                        voices[v].periodSlidePeriod = Self.word(Int32(voices[v].periodSlidePeriod) + speed)
                    } else {
                        voices[v].periodSlidePeriod = voices[v].periodSlideLimit
                    }
                    voices[v].plantPeriod = true
                }
            } else {
                voices[v].periodSlidePeriod &+= voices[v].periodSlideSpeed
                voices[v].plantPeriod = true
            }
        }

        if voices[v].vibratoDepth != 0 {
            if voices[v].vibratoDelay <= 0 {
                voices[v].vibratoPeriod = UInt16(truncatingIfNeeded: (hvlVibrato[Int(voices[v].vibratoCurrent) & 63] * Int32(voices[v].vibratoDepth)) >> 7)
                voices[v].plantPeriod = true
                voices[v].vibratoCurrent = (voices[v].vibratoCurrent &+ voices[v].vibratoSpeed) & 0x3F
            } else {
                voices[v].vibratoDelay -= 1
            }
        }

        // The instrument's list.
        if voices[v].hasList {
            if voices[v].instrument != 0, voices[v].listCurrent < instrument.listLength {
                // A speed of 128 is no wait at all: the Amiga's count, taken as a number with a
                // sign, overflowed on its way down from there, and that read as time up. There are
                // tunes that count on it.
                let overflows = voices[v].listWait == 128
                voices[v].listWait &-= 1
                if overflows || Int8(truncatingIfNeeded: voices[v].listWait) <= 0 {
                    let entry = module.entries[instrument.list + Int(voices[v].listCurrent)]
                    voices[v].listCurrent += 1
                    voices[v].listWait = voices[v].listSpeed
                    if entry.wave != 0 {
                        voices[v].wave = entry.wave - 1
                        voices[v].newWave = true
                        voices[v].listSlideSpeed = 0
                        voices[v].listSlidePeriod = 0
                    }
                    voices[v].listSlideOn = false
                    listCommand(v, entry.command, entry.parameter)
                    listCommand(v, entry.secondCommand, entry.secondParameter)
                    if entry.note != 0 {
                        // A note of the instrument's own: added to the track's, or in place of it.
                        voices[v].instrumentPeriod = UInt16(entry.note)
                        voices[v].plantPeriod = true
                        voices[v].fixedNote = entry.fixed
                    }
                }
            } else if voices[v].listWait != 0 {
                // At its end. The slide it may have left going is stopped once the last entry's time is up.
                voices[v].listWait &-= 1
            } else {
                voices[v].listSlideSpeed = 0
            }
        }

        if voices[v].listSlideOn {
            voices[v].listSlidePeriod &-= voices[v].listSlideSpeed
            if voices[v].listSlidePeriod != 0 { voices[v].plantPeriod = true }
        }

        // The sweep of the square wave's width, to and fro between its limits.
        if voices[v].wave == Wave.square, voices[v].squareOn {
            voices[v].squareWait &-= 1
            if voices[v].squareWait <= 0 {
                let lower = Int32(voices[v].squareLowerLimit), upper = Int32(voices[v].squareUpperLimit)
                var width = Int32(voices[v].squarePosition)
                if voices[v].squareInit {
                    voices[v].squareInit = false
                    // Starting from outside the limits, it first comes in to them.
                    if width <= lower {
                        voices[v].squareSlidingIn = true
                        voices[v].squareSign = 1
                    } else if width >= upper {
                        voices[v].squareSlidingIn = true
                        voices[v].squareSign = -1
                    }
                }
                if width == lower || width == upper {
                    if voices[v].squareSlidingIn {
                        voices[v].squareSlidingIn = false
                    } else {
                        voices[v].squareSign = 0 &- voices[v].squareSign
                    }
                }
                width += Int32(voices[v].squareSign)
                voices[v].squarePosition = Self.word(width)
                voices[v].plantSquare = true
                voices[v].squareWait = Int16(instrument.squareSpeed)
            }
        }

        // And of the filter, in the same way.
        if voices[v].filterOn {
            voices[v].filterWait &-= 1
            if voices[v].filterWait <= 0 {
                let lower = Int32(voices[v].filterLowerLimit), upper = Int32(voices[v].filterUpperLimit)
                var setting = Int32(voices[v].filterPosition)
                if voices[v].filterInit {
                    voices[v].filterInit = false
                    if setting <= lower {
                        voices[v].filterSlidingIn = true
                        voices[v].filterSign = 1
                    } else if setting >= upper {
                        voices[v].filterSlidingIn = true
                        voices[v].filterSign = -1
                    }
                }
                // The fastest speeds move it more than one step at a time.
                let steps = voices[v].filterSpeed < 4 ? 5 - Int(voices[v].filterSpeed) : 1
                for _ in 0 ..< steps {
                    if setting == lower || setting == upper {
                        if voices[v].filterSlidingIn {
                            voices[v].filterSlidingIn = false
                        } else {
                            voices[v].filterSign = 0 &- voices[v].filterSign
                        }
                    }
                    setting += Int32(voices[v].filterSign)
                }
                voices[v].filterPosition = Int16(max(1, min(63, setting)))
                voices[v].newWave = true
                voices[v].filterWait = max(1, voices[v].filterSpeed - 3)
            }
        }

        // The set of waves the filter is at. (It is always one of the sets there are once an
        // instrument has been started, and nothing is read from them before.)
        let set = Int(max(1, min(63, voices[v].filterPosition))) - 1
        let filtered = waves.samples + set * AHXWaves.setLength
        let waveLength = Int(voices[v].waveLength)
        let square = memory + v * Self.voiceMemory + 2 * Self.voiceSpace

        if voices[v].wave == Wave.square || voices[v].plantSquare {
            // The square wave of the width wanted, from the set the filter is at, at the length
            // wanted: of the 128 bytes it is kept as, every second, fourth or more.
            var which = Int32(voices[v].squarePosition) << Int32(5 - waveLength)
            // Past half way the widths come down again. (The wave should then be turned over, and is not.)
            if which > 0x20 { which = 0x40 - which }
            let from = filtered + AHXWaves.squares + (which > 0 ? Int(which - 1) << 7 : 0)
            let step = 32 >> waveLength
            for i in 0 ..< (1 << waveLength) * 4 { square[i] = from[i * step] }
            voices[v].newWave = true
            voices[v].wave = Wave.square
            voices[v].plantSquare = false
        }

        // Noise is a new stretch of noise on every tick.
        if voices[v].wave == Wave.noise { voices[v].newWave = true }

        if voices[v].ringNewWave {
            // The second wave is never filtered.
            if voices[v].ringWave > 1 { voices[v].ringWave = 1 }
            let plain = waves.samples + AHXWaves.plain + (voices[v].ringWave == Wave.triangle ? AHXWaves.triangles : AHXWaves.sawtooths)
            voices[v].ringSource = UnsafePointer(plain + AHXWaves.offsets[waveLength])
        }

        // (Once a voice has been given a wave this mark is never taken off again, so from then on
        // the wave is looked up afresh, and copied afresh, on every tick.)
        if voices[v].newWave {
            switch voices[v].wave {
            case Wave.triangle:
                voices[v].source = UnsafePointer(filtered + AHXWaves.triangles + AHXWaves.offsets[waveLength])
            case Wave.sawtooth:
                voices[v].source = UnsafePointer(filtered + AHXWaves.sawtooths + AHXWaves.offsets[waveLength])
            case Wave.square:
                voices[v].source = UnsafePointer(square)
            case Wave.noise:
                // From a place in the noise chosen by a number that is stirred each time.
                var seed = voices[v].noiseSeed
                voices[v].source = UnsafePointer(filtered + AHXWaves.noise + (Int(seed & (2 * 0x280 - 1)) & ~1))
                seed &+= 2_239_384
                seed = ((((seed >> 8) | (seed << 24)) &+ 782_323) ^ 75) &- 6735
                voices[v].noiseSeed = seed
            default:
                // (A wave above the four there are is taken, by the tracker, from wherever a
                // pointer it never set happens to lead. Here it is silence.)
                voices[v].source = nil
            }
        }

        if voices[v].ringSource != nil {
            voices[v].ringAudioPeriod = period(v, of: Int32(voices[v].ringBasePeriod), fixed: voices[v].ringFixedPeriod)
        }
        voices[v].audioPeriod = period(v, of: Int32(Int16(truncatingIfNeeded: voices[v].instrumentPeriod)), fixed: voices[v].fixedNote)

        // The volume: the envelope's, scaled by the note's, the list's and the voice's.
        var volume = (voices[v].envelope >> 8) &* Int32(voices[v].noteMaxVolume)
        volume = (volume >> 6) &* Int32(voices[v].listVolume)
        volume = (volume >> 6) &* Int32(voices[v].trackMasterVolume)
        voices[v].audioVolume = Self.word(volume >> 6)
    }

    // MARK: Ticks

    /// Gives the mixer what the tick worked out for a voice. A new wave is copied into the voice's
    /// buffer as many times as fill it; noise fills it once.
    private mutating func setAudio(_ v: Int) {
        // (Only the bottom eight bits of the volume are the mixer's.)
        voices[v].voiceVolume = UInt8(truncatingIfNeeded: voices[v].audioVolume)

        if voices[v].plantPeriod {
            voices[v].plantPeriod = false
            voices[v].delta = Self.delta(voices[v].audioPeriod)
        }

        let length = 4 << Int(voices[v].waveLength)
        if voices[v].newWave {
            let buffer = memory + v * Self.voiceMemory
            if let source = voices[v].source {
                if voices[v].wave == Wave.noise {
                    buffer.update(from: source, count: Self.voiceSpace)
                } else {
                    for i in 0 ..< Self.voiceSpace { buffer[i] = source[i & (length - 1)] }
                }
            } else {
                buffer.update(repeating: 0, count: Self.voiceSpace)
            }
        }

        if voices[v].ringPlantPeriod {
            voices[v].ringPlantPeriod = false
            voices[v].ringDelta = Self.delta(voices[v].ringAudioPeriod)
        }

        if voices[v].ringNewWave, let source = voices[v].ringSource {
            let buffer = memory + v * Self.voiceMemory + Self.voiceSpace
            for i in 0 ..< Self.voiceSpace { buffer[i] = source[i & (length - 1)] }
            voices[v].ringOn = true
        }
    }

    /// One tick of the tracker's timer. False when the tick is the last of a pass through the tune:
    /// the next would play a row that has been played before.
    mutating func runTick() -> Bool {
        if stepWait == 0 {
            if newPosition {
                let next = Int(position) + 1 == Int(module.positionCount) ? 0 : Int(position) + 1
                for v in 0 ..< channels {
                    voices[v].track = Int16(module.track(Int(position), v))
                    voices[v].transpose = Int16(module.transpose(Int(position), v))
                    voices[v].nextTrack = Int16(module.track(next, v))
                }
                newPosition = false
            }
            visited[Int(position) * (HVLModule.rows + 1) + Int(row)] = true
            for v in 0 ..< channels { processStep(v) }
            stepWait = UInt16(truncatingIfNeeded: tempo)
        }

        for v in 0 ..< channels { processFrame(v) }

        // (A tempo of nothing leaves no ticks to count, and the count goes round: the tune stands
        // where it is for 65,535 ticks, which is how it is stopped.)
        var more = true
        stepWait &-= 1
        if stepWait == 0 {
            if !patternBreak {
                row += 1
                if row >= Int16(module.trackLength) {
                    jumpPosition = UInt16(truncatingIfNeeded: Int32(position) + 1)
                    jumpRow = 0
                    patternBreak = true
                }
            }
            if patternBreak {
                patternBreak = false
                position = Int16(truncatingIfNeeded: jumpPosition)
                row = Int16(truncatingIfNeeded: jumpRow)
                if position == Int16(module.positionCount) { position = Int16(module.restart) }
                // (A jump past the end of the list takes the tracker out of the list, to play
                // whatever its memory holds there. Here it is a jump to the top.)
                if position < 0 || position > Int16(module.positionCount) { position = 0 }
                jumpRow = 0
                jumpPosition = 0
                newPosition = true
            }
            // The row that comes next: is it one that has been played?
            if visited[Int(position) * (HVLModule.rows + 1) + Int(row)] {
                visited.update(repeating: false, count: HVLModule.mostPositions * (HVLModule.rows + 1))
                more = false
            }
        }

        for v in 0 ..< channels { setAudio(v) }
        return more
    }

    // MARK: Sound

    /// Moves a voice that is not heard through its buffer as the mixer would have.
    @inline(__always) private static func advance(_ position: inout UInt32, by delta: UInt32, count: Int) {
        var left = count
        while left > 0 {
            if position >= span { position %= span }
            let run = min(left, Int((span - position - 1) / delta) + 1)
            position &+= UInt32(run) &* delta
            left -= run
        }
    }

    /// Mixes the sound of a tick: `count` samples of the left and of the right, in sixteen bits and
    /// clipped where they are too loud for them, at the loudness the file asks for.
    ///
    /// Each voice goes round its buffer by whole bytes, with no smoothing between one and the
    /// next, and when it has gone past the end it is taken back by the buffer's length the next time
    /// it is looked at. (The tracker looks at all the voices together, each time any of them comes
    /// to its end. A voice at a time, as here, comes to the same.)
    mutating func mix(left: UnsafeMutablePointer<Int32>, right: UnsafeMutablePointer<Int32>, count: Int) {
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        for v in 0 ..< channels {
            let buffer = UnsafePointer(memory + v * Self.voiceMemory)
            var position = voices[v].samplePosition
            let delta = voices[v].delta
            let volume = Int32(voices[v].voiceVolume)
            let panLeft = Int32(voices[v].panLeft), panRight = Int32(voices[v].panRight)
            var low: Int32 = 0, high: Int32 = 0
            if volume == 0 {
                Self.advance(&position, by: delta, count: count)
                if voices[v].ringOn {
                    var ringPosition = voices[v].ringPosition
                    Self.advance(&ringPosition, by: max(1, voices[v].ringDelta), count: count)
                    voices[v].ringPosition = ringPosition
                }
            } else if voices[v].ringOn {
                let ring = buffer + Self.voiceSpace
                var ringPosition = voices[v].ringPosition
                let ringDelta = max(1, voices[v].ringDelta)
                var done = 0
                while done < count {
                    if position >= Self.span { position %= Self.span }
                    if ringPosition >= Self.span { ringPosition %= Self.span }
                    let run = min(count - done, Int((Self.span - position - 1) / delta) + 1, Int((Self.span - ringPosition - 1) / ringDelta) + 1)
                    for i in done ..< done + run {
                        let sample = ((Int32(buffer[Int(position >> 16)]) &* Int32(ring[Int(ringPosition >> 16)])) >> 7) &* volume
                        low = min(low, sample)
                        high = max(high, sample)
                        left[i] &+= (sample &* panLeft) >> 7
                        right[i] &+= (sample &* panRight) >> 7
                        position &+= delta
                        ringPosition &+= ringDelta
                    }
                    done += run
                }
                voices[v].ringPosition = ringPosition
            } else {
                var done = 0
                while done < count {
                    if position >= Self.span { position %= Self.span }
                    let run = min(count - done, Int((Self.span - position - 1) / delta) + 1)
                    for i in done ..< done + run {
                        let sample = Int32(buffer[Int(position >> 16)]) &* volume
                        low = min(low, sample)
                        high = max(high, sample)
                        left[i] &+= (sample &* panLeft) >> 7
                        right[i] &+= (sample &* panRight) >> 7
                        position &+= delta
                    }
                    done += run
                }
            }
            voices[v].samplePosition = position
            voices[v].low = low
            voices[v].high = high
        }
        let gain = module.mixGain
        for i in 0 ..< count {
            left[i] = max(-0x8000, min(0x7FFF, (left[i] &* gain) >> 8))
            right[i] = max(-0x8000, min(0x7FFF, (right[i] &* gain) >> 8))
        }
    }

    /// Leaves voices out of the sound, or brings them back: see `Renderer.setMuted`. A mark for
    /// each voice, true for one not to be heard; a voice with no mark is heard.
    mutating func setMuted(_ muted: [Bool]) {
        for v in 0 ..< channels {
            self.muted[v] = v < muted.count && muted[v]
            place(v, at: voices[v].pan)
        }
    }

    // MARK: Lights

    /// Where a voice lies between the two sides, from -1 on the left to 1 on the right.
    func side(ofVoice v: Int) -> Float { max(-1, min(1, (Float(voices[v].pan & 255) - 128) / 127)) }

    /// How far each voice swung in the tick just mixed, where 1 is as far as a voice at full
    /// volume can.
    func takeLevels(into levels: inout [Float]) {
        for v in 0 ..< channels {
            levels[v] = min(1, Float(voices[v].high - voices[v].low) * (0.5 / (128.0 * 64.0)))
        }
    }

    /// What each voice is playing: its pitch, from its period and the length of its wave, and
    /// whether an instrument has been started on it since this was last asked. Noise has no pitch,
    /// and nor has a voice that is silent.
    mutating func takeNotes(into notes: inout TickNotes) {
        for v in 0 ..< channels {
            let sounding = voices[v].instrument != 0 && voices[v].voiceVolume > 0 && voices[v].wave <= Wave.square
            let cycle = Double(Int(voices[v].audioPeriod) * (4 << Int(voices[v].waveLength)))
            notes.pitches[v] = sounding ? ChannelPitch.note(ofHz: Self.clockHz / cycle) : 0
            if struck[v] { notes.struck[v] = true }
            struck[v] = false
        }
    }
}
