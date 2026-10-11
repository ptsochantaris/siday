// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday. What SoundFX's own replay routine does was learned by running it, in an emulated
// Amiga, beside this one and comparing what each told the sound chip, tick by tick, and by reading how
// it goes about it. None of its code is here. Its table of periods is here, because a tune is only
// played as it was with the same one: ProTracker's (from pt2-clone, Copyright (c) Olav Sørensen, used
// under the BSD 3-Clause licence; see THIRD-PARTY.md) with SoundFX's own two octaves and a bit below it.

/// What the player told the sound chip in one tick: for setting beside what SoundFX's own routine
/// tells it, which is how this one is checked.
public struct SoundFXTick: Sendable {
    public enum Register: Sendable {
        case period, volume
        /// Where to play from: a place in the file, or -1 for nowhere.
        case location
        /// How far, in words.
        case length
    }

    public struct Write: Sendable {
        public var voice: Int
        public var register: Register
        public var value: Int
    }

    /// Everything written, in the order it was written.
    public var writes: [Write] = []
    /// The voices that were started on this tick, a bit each.
    public var started = 0
    /// How long the tick lasted, in the colour clocks the sound chip counts.
    public var clocks = 0
    /// Where the tune was: the place in the order of playing and the line whose commands were
    /// carried out, and which tick of the line it was.
    public var position = 0
    public var line = 0
    public var tickOfLine = 0
}

/// The player for SoundFX modules: what SoundFX did, each time its timer fired, to turn a module's
/// patterns into what it told Paula.
///
/// A line lasts six ticks, always: the tempo is in how long a tick is. On the first of them the
/// line is read. An instrument named on it sets its voice's volume, whether or not there is a note,
/// and a note is started. Then every voice is told again where its instrument repeats, note or no
/// note, so that naming another instrument under a note that is sounding changes what the note goes
/// on with when it next comes round. On the other five ticks the commands are carried out.
///
/// It is an early routine and an odd one, and tunes were written by ear against its oddities, so
/// they are kept. A slide towards a note, once begun, goes on over the lines that follow until a new
/// note stops it, and while it goes on no other command of its voice is looked at. A bend works on
/// the period written on its own line and not on the note that is sounding, so that on a line
/// without a note it starts from nothing. A volume command counts from the instrument's volume and
/// only where the line names the instrument. And in place of a note a line may have one of two
/// marks: one stops the voice by turning it down, and one does nothing but keep the line's command
/// from being carried out.
struct SoundFXPlayer: ~Copyable {
    /// The timer that keeps the tempo counts cycles of a clock a fifth as fast as the sound chip's.
    static let clocksPerTimerCount = 5
    static let chipClock = Int(Paula.clockHz)
    static let ticksPerLine = 6

    /// The periods SoundFX has below ProTracker's lowest: sixteen that are all the lowest of all,
    /// for a slide that asks for a note off the bottom, and then two octaves and two notes.
    private static let below: [UInt16] = [
        3836, 3621, 3418, 3226, 3045, 2874, 2713, 2561, 2417, 2281, 2153, 2032,
        1918, 1810, 1708, 1612, 1522, 1437, 1356, 1280, 1208, 1140, 1076, 1016, 960, 906,
    ]
    private static let lowest: UInt16 = 4064, bottomPad = 16
    /// Above ProTracker's highest the highest is repeated this many times, for the same reason.
    private static let topPad = 30
    /// Where in the table a note is looked for from: the lowest four that can be written, then
    /// ProTracker's three octaves, then the padding.
    private static let firstNote = bottomPad + below.count - 4
    private static let noteCount = 4 + 36 + topPad
    /// In place of a note's period: stop the voice, and do nothing at all.
    private static let stopMark: UInt16 = 0xFFFE, idleMark: UInt16 = 0xFFFD

    private struct Voice {
        /// What the line has for this voice: the period as written (which a bend then changes), and
        /// the command.
        var period: UInt16 = 0
        var command: UInt8 = 0
        var data: UInt8 = 0
        /// Its instrument's sample: where a note starts and how far it goes, and where it goes on
        /// from after that. -1 is nowhere: no instrument has been named yet.
        var start = -1
        var words: UInt16 = 0
        var loop = -1
        var loopWords: UInt16 = 0
        var volume: UInt16 = 0
        /// The period of its last note, which an arpeggio counts from.
        var note: UInt16 = 0
        /// A slide towards a note: how much a tick (nought for no slide), where it has got to, and
        /// where it is going.
        var slide: Int16 = 0
        var slidePeriod: UInt16 = 0
        var slideTarget: UInt16 = 0
        /// A vibrato in steps of eight: the period it swings about (nought for none), its speed and
        /// depth as the command gave them, where it has got to, which way it is going, and how many
        /// ticks it has waited to move.
        var centre: UInt16 = 0
        var swing: UInt16 = 0
        var swingPeriod: UInt16 = 0
        var falling = false
        var waited: UInt16 = 0
    }

    let module: SoundFXModule
    var paula: Paula
    private var voices = InlineArray<4, Voice>(repeating: Voice())
    private let periods: UnsafeMutablePointer<UInt16>
    private var tick = 0
    private var position: Int
    private var line = 0
    /// The song being played: where in the order of playing it begins, and the place after its last.
    private let first: Int, end: Int
    /// The line whose commands are being carried out.
    private var lineNow = 0, positionNow = 0
    /// True once the tune has gone back to its beginning, until the pass that did it is over.
    private var wrapped = false
    /// The voices that were stopped, and not started, on the line just read.
    private var stopped: UInt16 = 0
    private(set) var playedNote = false

    /// For the comparison with SoundFX's own routine: when this is not nil, each tick is written down.
    var record: SoundFXTick?

    /// How long a tick is, in the sound chip's clocks: the timer takes one count more than it is
    /// given to come round.
    var tickClocks: Int { (module.timer + 1) * Self.clocksPerTimerCount }

    /// - Parameters:
    ///   - first: where in the order of playing to begin, and to come back to.
    ///   - end: the place after the last to be played; nil for the end of the order.
    init(_ module: SoundFXModule, model: AmigaModel, first: Int = 0, end: Int? = nil) {
        self.module = module
        self.first = max(0, min(module.positions.count - 1, first))
        self.end = max(self.first + 1, min(module.positions.count, end ?? module.positions.count))
        position = self.first
        positionNow = self.first
        paula = Paula(rate: Double(outputSampleRate * 2), model: model, memory: UnsafePointer(module.memory), size: module.memorySize,
                      silence: module.silence)
        let count = Self.bottomPad + Self.below.count + 36 + Self.topPad
        periods = .allocate(capacity: count)
        for i in 0 ..< count {
            let note = i - Self.bottomPad
            if note < 0 {
                periods[i] = Self.lowest
            } else if note < Self.below.count {
                periods[i] = Self.below[note]
            } else {
                periods[i] = UInt16(proTrackerPeriods[min(35, note - Self.below.count)])
            }
        }
    }

    deinit {
        periods.deallocate()
    }

    // MARK: The sound chip

    private mutating func write(_ voice: Int, _ register: SoundFXTick.Register, _ value: Int) {
        switch register {
        case .period: paula.setPeriod(voice, UInt16(truncatingIfNeeded: value))
        case .volume: paula.setVolume(voice, UInt16(truncatingIfNeeded: value))
        case .location: paula.setLocation(voice, value)
        case .length: paula.setLength(voice, UInt16(truncatingIfNeeded: value))
        }
        record?.writes.append(SoundFXTick.Write(voice: voice, register: register, value: value))
    }

    /// Where a period is among the notes; nil if it is not the period of any.
    private func note(ofPeriod period: UInt16) -> Int? {
        for i in 0 ..< Self.noteCount where periods[Self.firstNote + i] == period { return Self.firstNote + i }
        return nil
    }

    // MARK: Lines

    /// Reads the line the tune is at, starts its notes, and moves the tune on to the line after.
    private mutating func playLine() {
        let pattern = Int(module.positions[position])
        positionNow = position
        lineNow = line
        var starting: UInt16 = 0
        stopped = 0
        for v in 0 ..< 4 {
            let cell = module.cell(pattern: pattern, line: line, voice: v)
            voices[v].period = cell.period
            voices[v].command = cell.command
            voices[v].data = cell.data
            if cell.period == Self.idleMark {
                // Nothing is to happen on this line: not its instrument, and not its command.
                voices[v].command = 0
                voices[v].data = 0
                continue
            }
            if cell.instrument != 0 {
                let instrument = module.instruments[Int(cell.instrument) - 1]
                voices[v].start = instrument.start
                voices[v].words = instrument.words
                voices[v].volume = instrument.volume
                voices[v].loop = instrument.start + instrument.repeatStart
                voices[v].loopWords = instrument.repeatWords
                // The two volume commands: so much above the instrument's volume, or below it.
                var volume = Int16(bitPattern: instrument.volume)
                if cell.command == 5 {
                    volume &+= Int16(cell.data)
                    if volume > 64 { volume = 64 }
                } else if cell.command == 6 {
                    volume &-= Int16(cell.data)
                    if volume < 0 { volume = 0 }
                }
                write(v, .volume, Int(volume) & 0x7F)
            }
            guard cell.period != 0 else { continue }
            voices[v].slide = 0
            voices[v].centre = 0
            voices[v].note = cell.period
            paula.stop(voices: 1 << v)
            if cell.period == Self.stopMark {
                // The voice is turned down, and then set going again like any other: on whatever it
                // was last told to go on with, where it cannot be heard.
                write(v, .volume, 0)
                stopped |= 1 << v
            } else {
                write(v, .location, voices[v].start)
                write(v, .length, Int(voices[v].words))
                write(v, .period, Int(cell.period))
                playedNote = true
            }
            starting |= 1 << v
        }
        paula.start(voices: starting)
        record?.started = Int(starting)
        // Every voice is told where to go on from when it gets to the end of what it is playing,
        // whether or not it has just been started: the last voice first.
        for v in (0 ..< 4).reversed() {
            write(v, .location, voices[v].loop)
            write(v, .length, Int(voices[v].loopWords))
        }

        line += 1
        if line == SoundFXModule.linesInPattern {
            line = 0
            position += 1
            if position >= end {
                position = first
                wrapped = true
            }
        }
    }

    // MARK: Commands

    /// What is done to a voice on a tick that is not the first of its line.
    private mutating func alter(_ v: Int) {
        if voices[v].slide != 0 {
            // A slide that has begun is all that happens to its voice, on this line and after it.
            var period = voices[v].slidePeriod &+ UInt16(bitPattern: voices[v].slide)
            let target = voices[v].slideTarget
            if voices[v].slide > 0 {
                if target <= period { period = target }
            } else if Int16(bitPattern: target) >= Int16(bitPattern: period) {
                period = target
            }
            write(v, .period, Int(period))
            voices[v].slidePeriod = period
            return
        }
        let speed = voices[v].swing & 15
        if voices[v].centre != 0, speed != 0 {
            // And so is a vibrato: up eight at a time to as far above the note as its depth says,
            // then down to as far below, a step every so many ticks.
            voices[v].waited &+= 1
            guard voices[v].waited == speed else { return }
            voices[v].waited = 0
            let depth = (voices[v].swing >> 4) << 3
            if voices[v].falling {
                voices[v].swingPeriod &-= 8
                write(v, .period, Int(voices[v].swingPeriod))
                if voices[v].centre &- depth == voices[v].swingPeriod { voices[v].falling = false }
            } else {
                voices[v].swingPeriod &+= 8
                write(v, .period, Int(voices[v].swingPeriod))
                if voices[v].centre &+ depth == voices[v].swingPeriod { voices[v].falling = true }
            }
            return
        }

        let data = voices[v].data
        switch voices[v].command {
        case 1:
            // An arpeggio: the note so many above the last one played, by which tick of the line
            // it is. (A voice whose last note is none of the notes is left alone. The routine goes
            // looking for it through whatever lies after its table.)
            let above = tick == 3 ? 0 : Int(tick == 1 || tick == 5 ? data >> 4 : data & 15)
            if tick == 3 {
                write(v, .period, Int(voices[v].note))
            } else if let found = note(ofPeriod: voices[v].note) {
                write(v, .period, Int(periods[found + above]))
            }
        case 2:
            // A bend: of the period the line has, down in pitch by the first digit or up by the second.
            if data >> 4 != 0 {
                voices[v].period &+= UInt16(data >> 4)
                write(v, .period, Int(voices[v].period))
            } else if data & 15 != 0 {
                voices[v].period &-= UInt16(data & 15)
                write(v, .period, Int(voices[v].period))
            }
        case 3:
            // The Amiga's filter, which its power light shows the state of: off, and on.
            paula.setLightFilter(false)
        case 4:
            paula.setLightFilter(true)
        case 7, 8:
            // A slide begins: from the period the line has, so much a tick, to the note so many
            // below it or above it. (From a period that is none of the notes it goes nowhere.)
            let down = voices[v].command == 7
            voices[v].slidePeriod = voices[v].period
            voices[v].slide = down ? Int16(data & 15) : -Int16(data & 15)
            if let found = note(ofPeriod: voices[v].period) {
                voices[v].slideTarget = periods[found + (down ? -Int(data >> 4) : Int(data >> 4))]
            } else {
                voices[v].slideTarget = voices[v].period
            }
        case 9:
            voices[v].centre = voices[v].period
            voices[v].swing = UInt16(data)
            voices[v].swingPeriod = voices[v].period
            voices[v].falling = false
            voices[v].waited = 0
        default:
            break
        }
    }

    // MARK: Ticks

    /// One tick of the player's timer. False when the tick is the last of a pass through the tune:
    /// the next begins the tune again.
    mutating func runTick() -> Bool {
        if record != nil { record = SoundFXTick() }
        tick += 1
        if tick == Self.ticksPerLine {
            tick = 0
            playLine()
        } else {
            for v in 0 ..< 4 { alter(v) }
        }
        if record != nil {
            record!.clocks = tickClocks
            record!.position = positionNow
            record!.line = lineNow
            record!.tickOfLine = tick
        }
        if wrapped, tick == Self.ticksPerLine - 1 {
            wrapped = false
            return false
        }
        return true
    }

    /// What each voice is playing. A voice that was stopped has not begun a note, though the chip
    /// was started to stop it.
    mutating func takeNotes(into notes: inout TickNotes) {
        let before = (notes.struck[0], notes.struck[1], notes.struck[2], notes.struck[3])
        paula.takeNotes(into: &notes)
        if stopped & 1 != 0 { notes.struck[0] = before.0 }
        if stopped & 2 != 0 { notes.struck[1] = before.1 }
        if stopped & 4 != 0 { notes.struck[2] = before.2 }
        if stopped & 8 != 0 { notes.struck[3] = before.3 }
        stopped = 0
    }
}
