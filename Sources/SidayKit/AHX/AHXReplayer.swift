// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ahx2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): his C port of the replayer of AHX 2.3d-sp3.

/// The periods of five octaves of notes, the first of them for no note at all. A note is six bits,
/// so there can be three notes more than there are periods, and a slide towards one of those reads
/// past the end: into the vibrato's table, which comes next, and whose first three numbers are
/// therefore here too.
private let ahxPeriods: [Int16] = [
    0,
    3424, 3232, 3048, 2880, 2712, 2560, 2416, 2280, 2152, 2032, 1920, 1812,
    1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 906,
    856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
    428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
    214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
    0, 24, 49,
]

/// What AHX on the Amiga had in memory before its table of periods: 129 words of its own code. A
/// note moved far enough down comes out below the lowest there is, the tracker does not stop it, and
/// what it found here is the pitch such a note has.
private let ahxBelowPeriods: [UInt16] = [
    0xF6F2, 0xEEEA, 0xE6E3, 0x201B, 0x1612, 0x0E0A, 0x0603, 0x00FD, 0xFAF8, 0xF6F4,
    0xF2F1, 0x100D, 0x0A08, 0x0604, 0x0201, 0x00FF, 0xFEFE, 0xFEFE, 0xFEFF, 0x4A30,
    0x0170, 0x0000, 0x0027, 0x66FF, 0x0000, 0x00B2, 0x4A30, 0x0170, 0x0000, 0x0026,
    0x6712, 0x3770, 0x0170, 0x0000, 0x0064, 0x0006, 0x51F0, 0x0170, 0x0000, 0x0026,
    0x4A30, 0x0170, 0x0000, 0x0022, 0x67FF, 0x0000, 0x007C, 0x48E7, 0x3F68, 0x2470,
    0x0170, 0x0000, 0x005C, 0x0C30, 0x0003, 0x0170, 0x0000, 0x0014, 0x67FF, 0x0000,
    0x0042, 0x7C01, 0x7405, 0x9430, 0x0170, 0x0000, 0x0015, 0xE56E, 0xCCFC, 0x0005,
    0x5346, 0x2270, 0x0170, 0x0000, 0x0060, 0x7E01, 0x7400, 0x1430, 0x0170, 0x0000,
    0x0015, 0xE52F, 0x5347, 0x2619, 0x24C3, 0x51CF, 0xFFFA, 0x51CE, 0xFFDE, 0x60FF,
    0x0000, 0x0016, 0x2270, 0x0170, 0x0000, 0x0060, 0x7E4F, 0x24D9, 0x24D9, 0x51CF,
    0xFFFA, 0x4CDF, 0x16FC, 0x51F0, 0x0170, 0x0000, 0x0022, 0x3770, 0x0170, 0x0000,
    0x0066, 0x0008, 0x4E75, 0x377C, 0x0000, 0x0008, 0x4E75, 0x0004, 0x0000, 0x0001,
    0x0000, 0x0015, 0x4C70, 0x0015, 0x4D6C, 0x000E, 0xA9C4, 0x0015, 0x5E68,
]

/// A sine wave, for vibrato.
private let ahxVibrato: [Int16] = [
    0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
    255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24,
    0, -24, -49, -74, -97, -120, -141, -161, -180, -197, -212, -224, -235, -244, -250, -253,
    -255, -253, -250, -244, -235, -224, -212, -197, -180, -161, -141, -120, -97, -74, -49, -24,
]

/// AHX's replayer: what the tracker did on every tick of its timer to turn a file's tracks and
/// instruments into what it told Paula. It gives each of Paula's voices a buffer of 640 bytes to go
/// round, sets its period and its volume, and whenever the wave is to change, which with a filter
/// sweeping or a square wave's width moving is many times a second, copies a new one into the buffer.
///
/// It is the tracker's, mistakes and all: the numbers are of the widths the Amiga's were and go
/// round where the Amiga's did, because tunes were written by ear against what came of it.
struct AHXReplayer: ~Copyable {
    /// The four waves an instrument's list can choose between.
    private enum Wave {
        static let triangle: UInt8 = 0, sawtooth: UInt8 = 1, square: UInt8 = 2, noise: UInt8 = 3
    }

    /// One of the four voices. The names are the tracker's own, spelled out.
    private struct Voice {
        /// The track it is playing and how far that is moved up or down, and the track it plays next.
        var track: UInt8 = 0, nextTrack: UInt8 = 0
        var transpose: Int8 = 0

        // The envelope: its level, with eight bits either side of the point, and for each of its
        // four parts how many ticks are left of it and how much the level moves in each.
        var envelope: Int16 = 0
        var attackFrames: UInt8 = 0, decayFrames: UInt8 = 0, sustainFrames: UInt8 = 0, releaseFrames: UInt8 = 0
        var attackStep: Int16 = 0, decayStep: Int16 = 0, releaseStep: Int16 = 0

        /// Where its instrument is among the module's, and -1 for none yet.
        var instrument = -1
        var wave: UInt8 = 0
        /// Which of the six lengths of wave: 4 bytes, doubling to 128.
        var wavelength: UInt8 = 0
        var instrumentPeriod: Int16 = 0, trackPeriod: Int16 = 0, vibratoPeriod: Int16 = 0
        var noteMaxVolume: UInt8 = 0, listVolume: UInt8 = 0, trackMasterVolume: UInt8 = 64

        var newWave = false, plantSquare = false, ignoreSquare = false, plantPeriod = false, fixedNote = false

        var volumeSlideUp: UInt8 = 0, volumeSlideDown: UInt8 = 0

        var hardCut: UInt8 = 0
        var hardCutRelease = false
        var hardCutReleaseFrames: UInt8 = 0

        var periodSlideSpeed: Int16 = 0, periodSlidePeriod: Int16 = 0, periodSlideLimit: Int16 = 0
        var periodSlideOn = false, periodSlideWithLimit = false

        var listSlideSpeed: Int16 = 0, listSlidePeriod: Int16 = 0
        var listSlideOn = false

        var vibratoDelay: UInt8 = 0, vibratoCurrent: UInt8 = 0, vibratoDepth: UInt8 = 0, vibratoSpeed: UInt8 = 0

        var squareOn = false, squareInit = false
        var squareWait: UInt8 = 0, squareLowerLimit: UInt8 = 1, squareUpperLimit: UInt8 = 63, squarePosition: UInt8 = 0
        var squareSign: Int8 = 1
        var squareSlidingIn = false

        var filterOn = false, filterInit = false
        var filterWait: UInt8 = 0, filterLowerLimit: UInt8 = 0, filterUpperLimit: UInt8 = 0, filterPosition: UInt8 = 0
        var filterSign: Int8 = 0
        var filterSpeed: UInt8 = 0
        var filterSlidingIn = false
        /// Both a mark and a number: a filter setting from the track, to be used in place of the
        /// next one the instrument's list asks for.
        var ignoreFilter: UInt8 = 0

        // The instrument's list: which entry is next, how long each lasts, and where the next is
        // among the module's instruments.
        var listCurrent: UInt8 = 0, listSpeed: UInt8 = 0, listWait: UInt8 = 0
        var list = 0

        var noteDelayWait: UInt8 = 0
        var noteDelayOn = false
        var noteCutWait: UInt8 = 0
        var noteCutOn = false

        /// The wave to be copied into the voice's buffer, and nil for none.
        var source: UnsafePointer<Int8>?
        var period: UInt16 = 0, volume: UInt16 = 0
    }

    /// How long the buffer is that each of Paula's voices goes round.
    static let voiceSpace = 0x280
    private static let squareSpace = 0x80
    /// The most positions a file's list can have, and the size of the table of rows played.
    private static let mostPositions = 1024

    let module: AHXModule
    private let waves: AHXWaves
    var paula: Paula
    /// The voices' buffers, which are what Paula plays; after them a square wave for each voice,
    /// made up afresh as its width or its filter moves; and then a buffer's length of silence.
    private let memory: UnsafeMutablePointer<Int8>
    private let visited: UnsafeMutablePointer<Bool>
    private var voices = InlineArray<4, Voice>(repeating: Voice())

    /// How many ticks are left of the row being played.
    private var stepWait: UInt16 = 0
    private var newPosition = true
    private(set) var tempo: UInt8 = 6
    private var patternBreak = false
    private var jumpPosition: UInt16 = 0, jumpRow: UInt16 = 0
    private var noiseSeed: UInt32 = 0
    private var row: UInt16 = 0
    /// Where in the list of positions it is.
    private(set) var position: UInt16 = 0

    /// True once the tune has stopped itself, with a tempo of nothing.
    var stopped: Bool { tempo == 0 }
    /// Whether a note has been played.
    private(set) var playedNote = false
    /// For the lights: which voices have had a note started on them, until Paula is given it.
    private var struck = InlineArray<4, Bool>(repeating: false)
    /// And what each voice is heard playing, which is what Paula was last given: its pitch, and
    /// whether a note has been started on it since `takeNotes`.
    private var heardPitches = InlineArray<4, Float>(repeating: 0)
    private var heardStruck = InlineArray<4, Bool>(repeating: false)

    /// - Parameters:
    ///   - rate: the rate Paula makes samples at.
    ///   - position: where in the list of positions to start.
    init(_ module: AHXModule, waves: AHXWaves, model: AmigaModel, rate: Double, position start: UInt16 = 0) {
        self.module = module
        self.waves = waves
        let silence = 4 * (Self.voiceSpace + Self.squareSpace), size = silence + Self.voiceSpace
        memory = .allocate(capacity: size)
        memory.initialize(repeating: 0, count: size)
        visited = .allocate(capacity: Self.mostPositions * AHXModule.rows)
        visited.initialize(repeating: false, count: Self.mostPositions * AHXModule.rows)
        paula = Paula(rate: rate, model: model, memory: UnsafePointer(memory), size: size, silence: silence)
        position = start

        // Every voice is set going round its buffer, in silence, and stays so: from here on a note
        // is a change to what is in the buffer.
        for voice in 0 ..< 4 {
            paula.setPeriod(voice, 0x88)
            paula.setLocation(voice, voice * Self.voiceSpace)
            paula.setVolume(voice, 0)
            paula.setLength(voice, UInt16(Self.voiceSpace / 2))
        }
        paula.start(voices: 15)
    }

    deinit {
        memory.deallocate()
        visited.deallocate()
    }

    // MARK: Rows

    /// A byte of a voice's instrument: of the one a note is given when it has none, if it has none.
    @inline(__always) private func instrument(_ v: Int, _ field: Int) -> UInt8 {
        module.instruments[max(0, voices[v].instrument) + field]
    }

    /// Sixteen bits of a number that may not fit in them, as the Amiga kept it.
    @inline(__always) private static func word(_ value: Int) -> Int16 { Int16(truncatingIfNeeded: value) }

    /// Reads a voice's row of its track and does what it says. This is where a note begins.
    private mutating func processStep(_ v: Int) {
        voices[v].volumeSlideUp = 0
        voices[v].volumeSlideDown = 0

        var note: UInt8 = 0, instrument: UInt8 = 0, command: UInt8 = 0, parameter: UInt8 = 0
        // (A position can name a track the file does not have, and it is an empty one.)
        if voices[v].track <= module.highestTrack {
            let at = ((Int(voices[v].track) << 6) + Int(row)) * 3
            note = (module.track(at) >> 2) & 0x3F
            instrument = ((module.track(at) & 3) << 4) | (module.track(at + 1) >> 4)
            command = module.track(at + 1) & 0xF
            parameter = module.track(at + 2)
        }
        let high = parameter >> 4, low = parameter & 0xF

        if command == 0xE {
            if high == 0xC, low < tempo {
                // A note to be cut short, so many ticks into the row.
                voices[v].noteCutWait = low
                voices[v].noteCutOn = true
                voices[v].hardCutRelease = false
            }
            if high == 0xD {
                // A note to be held back so many ticks: the row is left for now, and read again then.
                if voices[v].noteDelayOn {
                    voices[v].noteDelayOn = false
                } else if low < tempo {
                    voices[v].noteDelayWait = low
                    if low != 0 {
                        voices[v].noteDelayOn = true
                        return
                    }
                }
            }
        }

        if command == 0x0, parameter != 0, low <= 9 {
            // The hundreds of a position to jump to. (It forgets the rest of what was there.)
            jumpPosition = UInt16(low) << 8
        }
        if command == 0xD {
            // On to the next position, at a row that is written in decimal.
            jumpPosition = position &+ 1
            jumpRow = UInt16(high) * 10 + UInt16(low)
            if jumpRow >= module.trackLength { jumpRow = 0 }
            patternBreak = true
        }
        if command == 0xB {
            jumpPosition = jumpPosition &* 100 &+ UInt16(high) * 10 &+ UInt16(low)
            patternBreak = true
        }
        if command == 0xF { tempo = parameter }
        if command == 0x5 || command == 0xA {
            voices[v].volumeSlideDown = low
            voices[v].volumeSlideUp = high
        }

        if instrument > 0 {
            playedNote = true
            struck[v] = true
            voices[v].listVolume = 64
            voices[v].listSlideSpeed = 0
            voices[v].periodSlidePeriod = 0
            voices[v].periodSlideLimit = 0

            let base = module.instrument(Int(instrument))
            let bytes = module.instruments + base
            typealias Field = AHXModule.Field

            // The envelope starts from nothing. The step of each of its parts is worked out here, in
            // sixteen bits, and a part that is asked to move further than those can say goes wrong.
            voices[v].envelope = 0
            voices[v].attackFrames = bytes[Field.attackFrames]
            var step = Self.word(Int(bytes[Field.attackVolume]) << 8)
            if voices[v].attackFrames != 0 { step = Self.word(Int(step) / Int(voices[v].attackFrames)) }
            voices[v].attackStep = step

            voices[v].decayFrames = bytes[Field.decayFrames]
            step = Self.word((Int(Int8(bitPattern: bytes[Field.decayVolume])) - Int(Int8(bitPattern: bytes[Field.attackVolume]))) << 8)
            if voices[v].decayFrames != 0 { step = Self.word(Int(step) / Int(voices[v].decayFrames)) }
            voices[v].decayStep = step

            voices[v].sustainFrames = bytes[Field.sustainFrames]

            voices[v].releaseFrames = bytes[Field.releaseFrames]
            step = Self.word((Int(Int8(bitPattern: bytes[Field.releaseVolume])) - Int(Int8(bitPattern: bytes[Field.decayVolume]))) << 8)
            if voices[v].releaseFrames != 0 { step = Self.word(Int(step) / Int(voices[v].releaseFrames)) }
            voices[v].releaseStep = step

            voices[v].wavelength = min(5, bytes[Field.filterSpeedAndWavelength] & 7)
            voices[v].noteMaxVolume = bytes[Field.volume]

            voices[v].vibratoCurrent = 0
            voices[v].vibratoDelay = bytes[Field.vibratoDelay]
            voices[v].vibratoDepth = bytes[Field.vibratoDepth] & 0x0F
            voices[v].vibratoSpeed = bytes[Field.vibratoSpeed]
            voices[v].vibratoPeriod = 0
            // The rest of that byte says whether the note is to be cut off before the next one, and how soon.
            voices[v].hardCutRelease = bytes[Field.vibratoDepth] & 128 != 0
            voices[v].hardCut = (bytes[Field.vibratoDepth] & 0x70) >> 4

            voices[v].ignoreSquare = false
            voices[v].squareSlidingIn = false
            voices[v].squareWait = 0
            voices[v].squareOn = false
            // A square wave's width is kept for the wave's length: 32 steps for the longest, and half
            // as many for each length shorter.
            let shift = 5 - voices[v].wavelength
            var lower = bytes[Field.squareLowerLimit] >> shift, upper = bytes[Field.squareUpperLimit] >> shift
            voices[v].squareLowerLimit = min(lower, upper)
            voices[v].squareUpperLimit = max(lower, upper)

            voices[v].ignoreFilter = 0
            voices[v].filterWait = 0
            voices[v].filterOn = false
            voices[v].filterSlidingIn = false
            voices[v].filterSpeed = bytes[Field.filterSpeedAndWavelength] >> 3
            lower = bytes[Field.filterLowerLimit]
            upper = bytes[Field.filterUpperLimit]
            // Two more bits of the filter's speed are kept at the top of its limits.
            if lower & 128 != 0 { voices[v].filterSpeed |= 32 }
            if upper & 128 != 0 { voices[v].filterSpeed |= 64 }
            lower &= 0x7F
            upper &= 0x7F
            voices[v].filterLowerLimit = min(lower, upper)
            voices[v].filterUpperLimit = max(lower, upper)
            voices[v].filterPosition = 32

            voices[v].listWait = 0
            voices[v].listSpeed = bytes[Field.listSpeed]
            voices[v].listCurrent = 0
            voices[v].instrument = base
            voices[v].list = base + Field.list
        }

        if command == 0x9 {
            // The square wave's width, which the instrument's list is then not to set.
            voices[v].squarePosition = parameter >> (5 - voices[v].wavelength)
            voices[v].plantSquare = true
            voices[v].ignoreSquare = true
        }
        if command == 0x4 {
            if parameter < 0x40 {
                voices[v].ignoreFilter = parameter
            } else {
                voices[v].filterPosition = parameter &- 0x40
            }
        }

        voices[v].periodSlideOn = false
        if command == 0x3 || command == 0x5 {
            // A slide to the note, in place of playing it.
            if command == 0x3, parameter != 0 { voices[v].periodSlideSpeed = Int16(parameter) }
            var slides = true
            if note != 0 {
                let limit = ahxPeriods[Int(voices[v].trackPeriod) & 63] &- ahxPeriods[Int(note)]
                if limit &+ voices[v].periodSlidePeriod == 0 {
                    // It is there already.
                    slides = false
                } else {
                    voices[v].periodSlideLimit = 0 &- limit
                }
            }
            if slides {
                voices[v].periodSlideOn = true
                voices[v].periodSlideWithLimit = true
                note = 0
            }
        }

        if note != 0 {
            playedNote = true
            voices[v].trackPeriod = Int16(note)
            voices[v].plantPeriod = true
        }

        if command == 0x1 {
            voices[v].periodSlideSpeed = 0 &- Int16(parameter)
            voices[v].periodSlideOn = true
            voices[v].periodSlideWithLimit = false
        }
        if command == 0x2 {
            voices[v].periodSlideSpeed = Int16(parameter)
            voices[v].periodSlideOn = true
            voices[v].periodSlideWithLimit = false
        }

        if command == 0xE {
            switch high {
            case 0x1:
                voices[v].periodSlidePeriod &-= Int16(low)
                voices[v].plantPeriod = true
            case 0x2:
                voices[v].periodSlidePeriod &+= Int16(low)
                voices[v].plantPeriod = true
            case 0x4:
                voices[v].vibratoDepth = low
            case 0xA:
                voices[v].noteMaxVolume &+= low
                if voices[v].noteMaxVolume > 0x40 { voices[v].noteMaxVolume = 0x40 }
            case 0xB:
                voices[v].noteMaxVolume &-= low
                if Int8(bitPattern: voices[v].noteMaxVolume) < 0 { voices[v].noteMaxVolume = 0 }
            default:
                break
            }
        }

        if command == 0xC {
            // One command for three volumes, by how large its number is: the note's, every voice's,
            // or this voice's.
            var volume = Int(parameter)
            if volume <= 0x40 {
                voices[v].noteMaxVolume = UInt8(volume)
            } else {
                volume -= 0x50
                if volume >= 0 {
                    if volume <= 0x40 {
                        for voice in 0 ..< 4 { voices[voice].trackMasterVolume = UInt8(volume) }
                    } else {
                        volume -= 0xA0 - 0x50
                        if volume >= 0, volume <= 0x40 { voices[v].trackMasterVolume = UInt8(volume) }
                    }
                }
            }
        }
    }

    // MARK: Instruments

    /// One of the two commands of an entry in an instrument's list.
    private mutating func listCommand(_ v: Int, _ command: UInt8, _ parameter: UInt8) {
        switch command {
        case 0x0:
            // Where the filter is set, unless the track has said where.
            guard parameter != 0 else { return }
            if voices[v].ignoreFilter > 0 {
                voices[v].filterPosition = voices[v].ignoreFilter
                voices[v].ignoreFilter = 0
            } else {
                voices[v].filterPosition = parameter
                voices[v].newWave = true
            }
        case 0x1:
            voices[v].listSlideSpeed = Int16(parameter)
            voices[v].listSlideOn = true
        case 0x2:
            voices[v].listSlideSpeed = 0 &- Int16(parameter)
            voices[v].listSlideOn = true
        case 0x3:
            // How wide the square wave is, unless the track has said how wide.
            if voices[v].ignoreSquare {
                voices[v].ignoreSquare = false
            } else {
                voices[v].squarePosition = parameter >> (5 - voices[v].wavelength)
            }
        case 0x4:
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
        case 0x5:
            // On from another entry of the list. Nothing looks to see whether the list is that long.
            // If it is not, the entries past its end are read, which are empty, until the count of
            // them has gone all the way round to where the list does end.
            voices[v].listCurrent = parameter &- 1
            voices[v].list = max(0, voices[v].instrument) + AHXModule.Field.list - 4 + (Int(parameter) << 2)
        case 0x6:
            var volume = Int(parameter)
            if volume <= 0x40 {
                voices[v].noteMaxVolume = UInt8(volume)
            } else {
                volume -= 0x50
                if volume >= 0 {
                    if volume <= 0x40 {
                        voices[v].listVolume = UInt8(volume)
                    } else {
                        volume -= 0xA0 - 0x50
                        if volume >= 0, volume <= 0x40 { voices[v].trackMasterVolume = UInt8(volume) }
                    }
                }
            }
        case 0x7:
            voices[v].listSpeed = parameter
            voices[v].listWait = parameter
        default:
            break
        }
    }

    /// What is done to a voice on every tick: its envelope, its slides and vibrato, the next entry
    /// of its instrument's list when that is due, the sweeps of its square wave and its filter; and
    /// from all of them the wave, the period and the volume Paula is to be given on the next tick.
    private mutating func processFrame(_ v: Int) {
        typealias Field = AHXModule.Field

        if voices[v].hardCut != 0 {
            // If the next row starts an instrument, this note is cut off some ticks before it.
            var track = voices[v].track
            var next = row &+ 1
            if next == module.trackLength {
                next = 0
                track = voices[v].nextTrack
            }
            let at = ((Int(track) << 6) + Int(next)) * 3
            if ((module.track(at) & 3) << 4) | (module.track(at + 1) >> 4) != 0 {
                let range = max(0, Int8(truncatingIfNeeded: Int(tempo) - Int(voices[v].hardCut)))
                if !voices[v].noteCutOn {
                    voices[v].noteCutOn = true
                    voices[v].noteCutWait = UInt8(range)
                    voices[v].hardCutReleaseFrames = tempo &- voices[v].noteCutWait
                }
                voices[v].hardCut = 0
            }
        }

        if voices[v].noteCutOn {
            if voices[v].noteCutWait == 0 {
                voices[v].noteCutOn = false
                if voices[v].hardCutRelease {
                    // Not silenced at once, but let go: the envelope's release from where it is.
                    voices[v].releaseFrames = voices[v].hardCutReleaseFrames
                    voices[v].releaseStep = 0
                    if voices[v].releaseFrames > 0 {
                        let fall = Int(voices[v].envelope) - (Int(instrument(v, Field.releaseVolume)) << 8)
                        voices[v].releaseStep = Self.word(0 - fall / Int(voices[v].releaseFrames))
                    }
                    voices[v].attackFrames = 0
                    voices[v].decayFrames = 0
                    voices[v].sustainFrames = 0
                } else {
                    voices[v].noteMaxVolume = 0
                }
            }
            voices[v].noteCutWait &-= 1
        }

        if voices[v].noteDelayOn {
            if voices[v].noteDelayWait == 0 {
                processStep(v)
            } else {
                voices[v].noteDelayWait -= 1
            }
        }

        // The envelope.
        if voices[v].attackFrames != 0 {
            voices[v].envelope &+= voices[v].attackStep
            voices[v].attackFrames -= 1
            if voices[v].attackFrames == 0 { voices[v].envelope = Self.word(Int(instrument(v, Field.attackVolume)) << 8) }
        } else if voices[v].decayFrames != 0 {
            voices[v].envelope &+= voices[v].decayStep
            voices[v].decayFrames -= 1
            if voices[v].decayFrames == 0 { voices[v].envelope = Self.word(Int(instrument(v, Field.decayVolume)) << 8) }
        } else if voices[v].sustainFrames != 0 {
            voices[v].sustainFrames -= 1
        } else if voices[v].releaseFrames != 0 {
            voices[v].envelope &+= voices[v].releaseStep
            voices[v].releaseFrames -= 1
            if voices[v].releaseFrames == 0 { voices[v].envelope = Self.word(Int(instrument(v, Field.releaseVolume)) << 8) }
        }

        // The track's slide of the volume.
        voices[v].noteMaxVolume = voices[v].noteMaxVolume &- voices[v].volumeSlideDown &+ voices[v].volumeSlideUp
        voices[v].noteMaxVolume = UInt8(max(0, min(0x40, Int8(bitPattern: voices[v].noteMaxVolume))))

        // And of the pitch: to a note, where it stops, or for as long as it is asked for.
        if voices[v].periodSlideOn {
            if voices[v].periodSlideWithLimit {
                var speed = voices[v].periodSlideSpeed
                let away = voices[v].periodSlidePeriod &- voices[v].periodSlideLimit
                if away != 0 {
                    if away > 0 { speed = 0 &- speed }
                    // If the step would take it past the note, the two differ in sign.
                    if Self.word((Int(away) + Int(speed)) ^ Int(away)) >= 0 {
                        voices[v].periodSlidePeriod &+= speed
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
            if voices[v].vibratoDelay != 0 {
                voices[v].vibratoDelay -= 1
            } else {
                voices[v].vibratoPeriod = Self.word((Int(ahxVibrato[Int(voices[v].vibratoCurrent) & 63]) * Int(voices[v].vibratoDepth)) >> 7)
                voices[v].plantPeriod = true
                voices[v].vibratoCurrent = (voices[v].vibratoCurrent &+ voices[v].vibratoSpeed) & 63
            }
        }

        // The instrument's list.
        if voices[v].instrument >= 0 {
            if voices[v].listCurrent == instrument(v, Field.listLength) {
                // At its end. The slide it may have left going is stopped once the last entry's time is up.
                if voices[v].listWait != 0 {
                    voices[v].listWait -= 1
                } else {
                    voices[v].listSlideSpeed = 0
                }
            } else {
                // A speed of 128 is no wait at all: the Amiga's count, taken as a number with a
                // sign, overflows on its way down from there, and that reads as time up. There are
                // tunes that count on it.
                let overflows = voices[v].listWait == 128
                voices[v].listWait &-= 1
                if overflows || Int8(bitPattern: voices[v].listWait) <= 0 {
                    let entry = module.instruments + voices[v].list
                    let second = (entry[0] >> 5) & 7, first = (entry[0] >> 2) & 7
                    var wave = ((entry[0] << 1) & 6) | (entry[1] >> 7)
                    let note = entry[1] & 0x3F
                    if wave != 0 {
                        // (A wave above the four there are is taken, in the player this is ported
                        // from, out of memory that is not its own. Here it is silence.)
                        if wave > 4 { wave = 0 }
                        voices[v].wave = wave &- 1
                        voices[v].newWave = true
                        voices[v].listSlideSpeed = 0
                        voices[v].listSlidePeriod = 0
                    }
                    voices[v].listSlideOn = false
                    listCommand(v, first, entry[2])
                    listCommand(v, second, entry[3])
                    if note != 0 {
                        // A note of the instrument's own: added to the track's, or in place of it.
                        voices[v].instrumentPeriod = Int16(note)
                        voices[v].plantPeriod = true
                        voices[v].fixedNote = (entry[1] >> 6) & 1 != 0
                    }
                    voices[v].list += 4
                    voices[v].listCurrent &+= 1
                    voices[v].listWait = voices[v].listSpeed
                }
            }
        }

        if voices[v].listSlideOn {
            voices[v].listSlidePeriod &-= voices[v].listSlideSpeed
            if voices[v].listSlidePeriod != 0 { voices[v].plantPeriod = true }
        }

        // The sweep of the square wave's width, to and fro between its limits.
        if voices[v].wave == Wave.square, voices[v].squareOn {
            voices[v].squareWait &-= 1
            if Int8(bitPattern: voices[v].squareWait) <= 0 {
                if voices[v].squareInit {
                    voices[v].squareInit = false
                    // Starting from outside the limits, it first comes in to them.
                    if Int8(bitPattern: voices[v].squarePosition) <= Int8(bitPattern: voices[v].squareLowerLimit) {
                        voices[v].squareSlidingIn = true
                        voices[v].squareSign = 1
                    } else if Int8(bitPattern: voices[v].squarePosition) >= Int8(bitPattern: voices[v].squareUpperLimit) {
                        voices[v].squareSlidingIn = true
                        voices[v].squareSign = -1
                    }
                }
                if voices[v].squarePosition == voices[v].squareLowerLimit || voices[v].squarePosition == voices[v].squareUpperLimit {
                    if voices[v].squareSlidingIn {
                        voices[v].squareSlidingIn = false
                    } else {
                        voices[v].squareSign = 0 &- voices[v].squareSign
                    }
                }
                voices[v].squarePosition &+= UInt8(bitPattern: voices[v].squareSign)
                voices[v].plantSquare = true
                voices[v].squareWait = instrument(v, Field.squareSpeed)
            }
        }

        // And of the filter, in the same way.
        if voices[v].filterOn {
            voices[v].filterWait &-= 1
            if Int8(bitPattern: voices[v].filterWait) <= 0 {
                if voices[v].filterInit {
                    voices[v].filterInit = false
                    if Int8(bitPattern: voices[v].filterPosition) <= Int8(bitPattern: voices[v].filterLowerLimit) {
                        voices[v].filterSlidingIn = true
                        voices[v].filterSign = 1
                    } else if Int8(bitPattern: voices[v].filterPosition) >= Int8(bitPattern: voices[v].filterUpperLimit) {
                        voices[v].filterSlidingIn = true
                        voices[v].filterSign = -1
                    }
                }
                // The fastest speeds move it more than one step at a time.
                let steps = voices[v].filterSpeed < 4 ? 5 - Int(voices[v].filterSpeed) : 1
                for _ in 0 ..< steps {
                    if voices[v].filterPosition == voices[v].filterLowerLimit || voices[v].filterPosition == voices[v].filterUpperLimit {
                        if voices[v].filterSlidingIn {
                            voices[v].filterSlidingIn = false
                        } else {
                            voices[v].filterSign = 0 &- voices[v].filterSign
                        }
                    }
                    voices[v].filterPosition &+= UInt8(bitPattern: voices[v].filterSign)
                }
                voices[v].newWave = true
                voices[v].filterWait = UInt8(max(1, Int(voices[v].filterSpeed) - 3))
            }
        }

        // A filter set outside the sets there are is brought within them. (The Amiga read on into
        // whatever came after its waves.)
        let set = Int(max(1, min(63, voices[v].filterPosition))) - 1
        let square = memory + 4 * Self.voiceSpace + v * Self.squareSpace

        if voices[v].wave == Wave.square || voices[v].plantSquare {
            // The square wave of the width wanted, from the set the filter is at, at the length
            // wanted: of the 128 bytes it is kept as, every second, fourth or more.
            var which = voices[v].squarePosition << (5 - voices[v].wavelength)
            // Past half way the widths come down again. (The wave should then be turned over, and is not.)
            if Int8(bitPattern: which) > 0x20 { which = 0x40 &- which }
            which &-= 1
            if Int8(bitPattern: which) < 0 { which = 0 }
            let from = waves.samples + set * AHXWaves.setLength + AHXWaves.squares + (Int(which) << 7)
            let step = (1 << 5) >> Int(voices[v].wavelength)
            for i in 0 ..< (1 << Int(voices[v].wavelength)) << 2 { square[i] = from[i * step] }
            voices[v].newWave = true
            voices[v].plantSquare = false
        }

        // Noise is a new stretch of noise on every tick.
        if voices[v].wave == Wave.noise { voices[v].newWave = true }

        if voices[v].newWave {
            let filtered = waves.samples + set * AHXWaves.setLength
            switch voices[v].wave {
            case Wave.triangle:
                voices[v].source = UnsafePointer(filtered + AHXWaves.triangles + AHXWaves.offsets[Int(voices[v].wavelength)])
            case Wave.sawtooth:
                voices[v].source = UnsafePointer(filtered + AHXWaves.sawtooths + AHXWaves.offsets[Int(voices[v].wavelength)])
            case Wave.square:
                voices[v].source = UnsafePointer(square)
            case Wave.noise:
                // From a place in the noise chosen by a number that is stirred each time.
                var seed = noiseSeed
                voices[v].source = UnsafePointer(filtered + AHXWaves.noise + Int(seed & UInt32(AHXWaves.noiseLength - Self.voiceSpace - 1)))
                seed &+= 2_239_384
                seed = (seed >> 8) | (seed << 24)
                seed &+= 782_323
                seed ^= 0b100_1011
                seed &-= 6735
                noiseSeed = seed
            default:
                voices[v].source = nil
            }
        }

        // The period: of the instrument's note, with the track's and the position's added unless the
        // instrument's is to stand alone.
        var note = voices[v].instrumentPeriod
        if !voices[v].fixedNote {
            note &+= Int16(voices[v].transpose)
            note &+= voices[v].trackPeriod &- 1
        }
        if note > 5 * 12 { note = 5 * 12 }
        var period = note < 0 ? Int16(bitPattern: ahxBelowPeriods[Int(max(-129, note)) + 129]) : ahxPeriods[Int(note)]
        if !voices[v].fixedNote { period &+= voices[v].periodSlidePeriod }
        period &+= voices[v].listSlidePeriod
        period &+= voices[v].vibratoPeriod
        voices[v].period = UInt16(max(113, min(3424, period)))

        // The volume: the envelope's, scaled by the note's, the list's and the voice's.
        var volume = UInt16(truncatingIfNeeded: Int(voices[v].envelope) >> 8)
        volume = UInt16(truncatingIfNeeded: (Int(volume) * Int(voices[v].noteMaxVolume)) >> 6)
        volume = UInt16(truncatingIfNeeded: (Int(volume) * Int(voices[v].listVolume)) >> 6)
        voices[v].volume = UInt16(truncatingIfNeeded: (Int(volume) * Int(voices[v].trackMasterVolume)) >> 6)
    }

    // MARK: Ticks

    /// Gives Paula what the last tick worked out for a voice. A new wave is copied into the voice's
    /// buffer as many times as fill it; noise fills it once.
    private mutating func setAudio(_ v: Int) {
        if voices[v].plantPeriod {
            paula.setPeriod(v, voices[v].period)
            voices[v].plantPeriod = false
        }
        if voices[v].newWave {
            let buffer = memory + v * Self.voiceSpace
            if let source = voices[v].source {
                if voices[v].wave == Wave.noise {
                    buffer.update(from: source, count: Self.voiceSpace)
                } else {
                    let mask = (4 << Int(voices[v].wavelength)) - 1
                    for i in 0 ..< Self.voiceSpace { buffer[i] = source[i & mask] }
                }
            } else {
                buffer.update(repeating: 0, count: Self.voiceSpace)
            }
            voices[v].newWave = false
        }
        paula.setVolume(v, voices[v].volume)
    }

    /// One tick of the tracker's timer. False when the tick is the last of a pass through the tune:
    /// the next would play a row that has been played before.
    mutating func runTick() -> Bool {
        // What the last tick worked out is what is heard during this one, and what the lights tell of.
        for v in 0 ..< 4 {
            setAudio(v)
            heardPitches[v] = pitch(v)
            if struck[v] { heardStruck[v] = true }
            struck[v] = false
        }

        if stepWait == 0 {
            if newPosition {
                let next = position &+ 1 == module.positionCount ? 0 : Int(position &+ 1)
                for v in 0 ..< 4 {
                    voices[v].track = module.position(Int(position), v << 1)
                    voices[v].transpose = Int8(bitPattern: module.position(Int(position), (v << 1) + 1))
                    voices[v].nextTrack = module.position(next, v << 1)
                }
                newPosition = false
            }
            if Int(position) < Self.mostPositions, Int(row) < AHXModule.rows {
                visited[Int(position) * AHXModule.rows + Int(row)] = true
            }
            for v in 0 ..< 4 { processStep(v) }
            stepWait = UInt16(tempo)
        }

        for v in 0 ..< 4 { processFrame(v) }

        // (A tempo of nothing leaves no ticks to count, and the count goes round: the tune stands
        // where it is for 65,535 ticks, which is how it is stopped.)
        stepWait &-= 1
        guard stepWait == 0 else { return true }

        if !patternBreak {
            row &+= 1
            if row == module.trackLength {
                jumpPosition = position &+ 1
                patternBreak = true
            }
        }
        if patternBreak {
            patternBreak = false
            row = jumpRow
            jumpRow = 0
            position = jumpPosition
            jumpPosition = 0
            if position == module.positionCount { position = module.restart }
            if position >= module.positionCount { position = 0 }
            newPosition = true
        }

        // The row that comes next: is it one that has been played?
        if Int(position) < Self.mostPositions, Int(row) < AHXModule.rows, visited[Int(position) * AHXModule.rows + Int(row)] {
            visited.update(repeating: false, count: Self.mostPositions * AHXModule.rows)
            return false
        }
        return true
    }

    // MARK: Lights

    /// The pitch a voice has, from its period and the length of its wave. Noise has none, and nor
    /// has a voice that is silent.
    private func pitch(_ v: Int) -> Float {
        let sounding = voices[v].instrument >= 0 && voices[v].volume > 0 && voices[v].wave <= Wave.square
        let cycle = Double(Int(voices[v].period) * (4 << Int(voices[v].wavelength)))
        return sounding ? ChannelPitch.note(ofHz: Paula.clockHz / cycle) : 0
    }

    /// What each voice is playing, as it is heard: its pitch, and whether an instrument has been
    /// started on it since this was last asked. (A tick works out what Paula is given on the next,
    /// and it is then that it is heard.)
    mutating func takeNotes(into notes: inout TickNotes) {
        for v in 0 ..< 4 {
            notes.pitches[v] = heardPitches[v]
            if heardStruck[v] { notes.struck[v] = true }
            heardStruck[v] = false
        }
    }
}
