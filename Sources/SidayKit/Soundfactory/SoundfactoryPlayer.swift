// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the replayer of Soundfactory ("Profiteam-Soundfactory V1.0", by Zuheir Urwani and Thomas Kolbe,
// 1989), as Wanted Team adapted it for EaglePlayer ("Soundfactory 1.0 player module V1.1 (12 Aug 2001)", carried
// by UADE as players/SoundFactory, whose source UADE also carries as
// amigasrc/players/wanted_team/Soundfactory/src/Soundfactory_v2.asm). The labels given are that source's.

/// The music of Soundfactory, an editor of Profiteam's (most of its tunes by Oliver Becker and Michael Volz of
/// Master Control Program; UnExoticA has one, Danger Castle's, whose composer is not known): for each of its
/// songs, four voices' streams of notes and commands, the instruments defined in them, each its sample and how
/// it is played.
///
/// The file: its length (a long), a mask of the voices each of its 16 songs plays (a byte each; a song of none
/// is none), and each song's four streams, where each begins (a long each, from the file's start); then the
/// streams. A note is a byte under $80 (with the voice's transposition added, a semitone of an octave of
/// twelve) and its length in ticks (a word; its top bit set to go on from the note before without starting
/// its envelope again); a command is $80 and its number, and what it takes: to wait; to scale the voice's
/// volume, or add to its period; to choose an instrument, or define one (`$84`, its number and its length in
/// words, and the instrument, read in place); to call a part of the stream, return, jump or go back to its
/// start, or repeat a part; to fade the music out or in; to count, or wait for the count; to change the
/// instrument's envelope, its repeat and its effects; to turn the voice off; and the Amiga's filter. An
/// instrument is 38 bytes and its sample: its length, the period it is tuned to, what it does (a byte of
/// eight flags: played once, vibrato, an octave up and down, its sample smoothed, a slide to each note, held
/// until the next, a tremolo, and its sample's shape bent), their settings, its envelope (attack, decay,
/// sustain, release), and its loop.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It runs fifty times a second (it has no timer of its own: EaglePlayer's,
/// which UADE runs from $376B), its voices last to first, and their DMA turned on at the end of the tick for
/// the notes begun in it, after the player's wait for the beam. An instrument whose sample is smoothed or bent
/// plays it from a buffer of the voice's own (256 bytes each, after the module here), which is made again as
/// its settings move. A song ends when every voice has gone back (jumped, or to its start) since it last did;
/// or as one turns itself off; one whose voices are all off, or that has faded out, has stopped.
struct SoundfactoryPlayer: ~Copyable {
    /// The module, the player's instrument for a voice that has none, the voices' buffers, and silence, as Paula
    /// reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed (`lbW000E2C`: the noughts after the buffers).
    let silenceAt: Int
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// The module as it was loaded (its instruments are changed as it plays), and the player's instrument.
    private let original: [UInt8]
    /// Where the player's own instrument is (`lbW0002A8`), and the voices' buffers (`lbW000FCA`).
    private let ownInstrumentAt: Int
    private let buffersAt: Int
    /// The voices each song plays.
    private let masks: [UInt8]
    /// The instruments the file defines (`InitPlayer` counts them).
    let instrumentCount: Int

    let songCount: Int
    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// The Amiga's filter, as the song sets it (it is on as a song starts).
    private(set) var lightFilter = true

    // MARK: The player's variables (from `lbW000066`), named as its source names them.

    /// The count (-$46), the voices playing (-$45) and those whose DMA is turned on (124), and those started in
    /// the tick (114).
    private var count: UInt8 = 0
    private var active: UInt8 = 0
    private var dmaMask: UInt8 = 0
    private var started: UInt8 = 0
    /// The fade: out (88) or in (92), its fraction (89), level (90) and speed (91).
    private var fadeOut: UInt8 = 0
    private var fadeIn: UInt8 = 0
    private var fadeFraction: UInt8 = 0
    private var fadeLevel: UInt8 = 0
    private var fadeSpeed: UInt8 = 0
    /// For each voice whether it has gone back since the song last ended (`Songend`), and as the song began.
    private var notBack = InlineArray<4, Bool>(repeating: false)
    private var notBackAtStart = InlineArray<4, Bool>(repeating: false)

    private struct Voice {
        /// Where its stream begins (-$44) and is read from (-$34), the ticks it waits (-$24), its instrument
        /// (-$1C), its volume's scale (-$18), what is added to its period (-$14), its note's period (-$10) and
        /// note (-8), and its stack (-4, `lbW000168`).
        var begin = 0
        var at = 0
        var wait: UInt16 = 1
        var instrument: UInt8 = 0
        var volumeScale: UInt8 = 0
        var detune: UInt8 = 0
        var period: UInt16 = 0
        var note: UInt8 = 0
        var stackTop: UInt8 = 0
        /// The tremolo's count (0), step (4) and level (8); the slide's period (12) and count (20); the octave's
        /// count (24) and flip (28); the vibrato's wait (32), count (36), offset (40), step (48) and turns (52).
        var tremoloCount: UInt8 = 0
        var tremoloStep: UInt8 = 0
        var tremoloLevel: UInt8 = 0
        var slidePeriod: UInt16 = 0
        var slideCount: UInt8 = 0
        var flipCount: UInt8 = 0
        var flip: UInt8 = 0
        var vibratoWait: UInt8 = 0
        var vibratoCount: UInt8 = 0
        var vibratoOffset: UInt16 = 0
        var vibratoStep: UInt8 = 0
        var vibratoTurns: UInt8 = 0
        /// The envelope: its stage (56), fraction (60), the ticks it is held (64) and its level (72).
        var stage: UInt8 = 0
        var fraction: UInt8 = 0
        var hold: UInt16 = 0
        var level: UInt8 = 0
        /// The smoothing's count (76), step (80) and distance (84); the bending's count (94), amount (98) and
        /// step (102).
        var smoothCount: UInt8 = 0
        var smoothStep: UInt8 = 0
        var smoothDistance: UInt8 = 0
        var bendCount: UInt8 = 0
        var bend: UInt8 = 0
        var bendStep: UInt8 = 0
        /// Whether a note began this tick (106) and the tick before (110); its transposition (126); the period
        /// last written (116).
        var struck: UInt8 = 0
        var struckBefore: UInt8 = 0
        var transpose: UInt8 = 0
        var periodWritten: UInt16 = 0
        /// Paula's location and length registers, as last written.
        var location = 0
        var length: UInt16 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The instruments by number (`lbW0000E8`), as places in `memory` (the player's own for those not defined).
    private var instruments = [Int](repeating: 0, count: 64)
    /// The voices' stacks, of calls and repeats.
    private var stacks = [UInt8](repeating: 0, count: 4 * 256)

    /// What each of Paula's period and volume registers was last given, and what they held as the tick just run
    /// began.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)

    /// How long each tick is: EaglePlayer's timer, which UADE runs on a CIA's timer from $376B.
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60
    /// The most commands a voice is let read in a tick: a stream that reads on for ever (a broken file's) is
    /// turned off.
    private static let mostCommands = 4096

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (the medians of its dumps of the
    /// music): the first voice's (the fourth), the next voice's after one that has begun a note or after one
    /// that has not, and the DMA turned on after the last, once the player has waited for the beam.
    static let firstVoice = 300
    static let noteClocks = 950
    static let voiceClocks = 380
    static let onClocks = 1400

    /// The player's instrument for a voice that has none (`lbW0002A8`): a sample of one word.
    private static let ownInstrument: [UInt8] = [
        0x84, 0x00, 0xFF, 0xFF, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0x01, 0x00, 0x40, 0x1E, 0, 0, 0, 0, 0x01, 0x00, 0x01, 0x32, 0x02, 0x00, 0, 0, 0, 0, 0x64, 0x9C,
    ]
    /// The periods of an octave, for an instrument tuned by its length (`lbW000ED4`), and the steps of a
    /// semitone (`lbW000EBC`, a fraction of a word).
    private static let lengthPeriods: [UInt16] = [0xD5C8, 0xC9C8, 0xBE75, 0xB3C4, 0xA9AD, 0xA027, 0x972A, 0x8EAE, 0x86AC, 0x7F1D, 0x77FB, 0x7124]
    private static let semitones: [UInt16] = [0x8000, 0x78D1, 0x7209, 0x6BA3, 0x6598, 0x5FE5, 0x5A83, 0x556E, 0x50A3, 0x4C1C, 0x47D7, 0x43CF]

    // MARK: - Reading

    @inline(__always) private static func byte(_ data: [UInt8], _ at: Int) -> UInt8 { at >= 0 && at < data.count ? data[at] : 0 }
    @inline(__always) private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        UInt16(byte(data, at)) << 8 | UInt16(byte(data, at + 1))
    }
    @inline(__always) private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2))
    }

    /// Memory as the player reads it: the module, its own instrument and the buffers (nought past them).
    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < silenceAt ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }
    /// Writes into an instrument (as its commands change it), in the module or the player's own.
    @inline(__always) private func set(_ at: Int, _ value: UInt8) {
        if at >= 0, at < buffersAt { memory[at] = value }
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`; it has no mark): a length of no more than 2 MB, the
    /// songs' 16 masks each no more than 15, and the 64 places their streams begin each no more than 2 MB, the
    /// least of them 276 (the streams follow the table).
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 276 else { return false }
        guard long(data, 0) <= 0x20_0000 else { return false }
        for i in 4 ..< 20 where data[i] > 15 { return false }
        var least = UInt32.max
        for i in 0 ..< 64 {
            let place = long(data, 20 + 4 * i)
            guard place <= 0x20_0000 else { return false }
            least = min(least, place)
        }
        return least == 0x114
    }

    /// Reads the module and starts song `song` (the first, if it has no such song). A module shorter than the
    /// length it gives is refused, as `InitPlayer` refuses it.
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        fileSize = data.count
        ownInstrumentAt = (data.count + 15) & ~15
        buffersAt = ownInstrumentAt + 48
        silenceAt = buffersAt + 1024
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        var original = data + [UInt8](repeating: 0, count: ownInstrumentAt - data.count)
        original += Self.ownInstrument
        self.original = original
        masks = (0 ..< 16).map { Self.byte(data, 4 + $0) }
        // (`InitPlayer`: the songs, to the last with a mask; and the instruments, found a word at a time from
        // the streams' start to the module's end, less eight.)
        var songs = 16
        while songs > 0, masks[songs - 1] == 0 { songs -= 1 }
        songCount = songs
        var found = 0
        var at = 276
        let end = Int(min(Self.long(data, 0), UInt32(data.count))) - 8
        while at < end {
            if data[at] == 0x84, Self.byte(data, at + 1) <= 31 {
                found += 1
                let length = Int(Self.word(data, at + 2)) * 2
                at += max(2, length)
            } else {
                at += 2
            }
        }
        instrumentCount = found
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Soundfactory module") }
        guard Self.long(data, 0) <= UInt32(data.count) else { throw .malformed("the module is cut short") }
        guard songs > 0 else { throw .malformed("the module has no song") }
        try select(song: song >= 0 && song < songCount ? song : 0)
    }

    deinit { memory.deallocate() }
}

// MARK: - Playing

extension SoundfactoryPlayer {
    /// Starts song `song`; and finds how long it is, played through to its end for up to an hour.
    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        start()
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, stops == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (It ends as the tick that says so is run: what follows it is the song again.)
        lengthClocks = endings > 0 || stops > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        start()
    }

    /// `InitSound` and `InitSong`: the module as it was loaded, the song's streams from their starts, each
    /// voice's first to be read at the first tick; the instruments the player's own; the filter on.
    private mutating func start() {
        for (i, b) in original.enumerated() { memory[i] = b }
        for i in buffersAt ..< silenceAt { memory[i] = 0 }
        let mask = masks[song]
        // (`InitSound`: which voices are to have gone back for the song to end, the last of those playing and
        // all before it.)
        var last = 3
        while last >= 0, mask & 1 << UInt8(last) == 0 { last -= 1 }
        for v in 0 ..< 4 { notBackAtStart[v] = v <= last }
        notBack = notBackAtStart
        count = 0
        active = mask
        dmaMask = mask
        started = 0
        fadeOut = 0
        fadeIn = 0
        fadeFraction = 0
        fadeLevel = 0
        fadeSpeed = 0
        voices = .init(repeating: Voice())
        for v in 0 ..< 4 {
            let begin = Int(long(20 + 16 * song + 4 * v))
            voices[v].begin = begin
            voices[v].at = begin
        }
        instruments = .init(repeating: ownInstrumentAt, count: 64)
        stacks = .init(repeating: 0, count: 4 * 256)
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = .init(repeating: 0)
        volumesBefore = .init(repeating: 0)
        lightFilter = true
        endings = 0
        stops = 0
    }

    /// The player's interrupt (`Interrupt` and `Play`), for a tick: the fade, then each voice playing, the
    /// fourth first, and the DMA turned on for the notes begun. Returns the tick's length in milliseconds
    /// (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        guard active & 15 != 0 || stops == 0 else { return 20 }
        if masks[song] & 15 == 0 {
            // (A song of no voices: the song's end said at every tick, and nothing played.)
            endings += 1
            stops += 1
            return 20
        }
        if fadeIn != 0 || fadeOut != 0 {
            let sum = fadeFraction &+ fadeSpeed
            fadeFraction = sum & 3
            let step = sum >> 2
            if fadeIn != 0 {
                let (level, over) = fadeLevel.addingReportingOverflow(step)
                if over {
                    fadeIn = 0
                    fadeLevel = 0
                } else {
                    fadeLevel = level
                }
            } else if fadeLevel == 0 {
                fadeLevel = 0 &- step
            } else if fadeLevel > step {
                fadeLevel -= step
            } else {
                // `End`: faded out, every voice stopped.
                output.timed(at: Self.firstVoice)
                endAll(&output)
                return 20
            }
        }
        started = 0
        var at = Self.firstVoice
        for v in (0 ..< 4).reversed() where active & 1 << UInt8(v) != 0 {
            output.timed(at: at)
            playVoice(v, &output)
            at += started & 1 << UInt8(v) != 0 ? Self.noteClocks : Self.voiceClocks
        }
        let on = started & dmaMask & 15
        if on != 0 {
            output.timed(at: at + Self.onClocks)
            for v in 0 ..< 4 where on & 1 << UInt8(v) != 0 { output.on(v) }
        }
        if active & 15 == 0 { stops += 1 }
        return 20
    }

    /// `End`: every voice turned off and silent, and nothing more played.
    private mutating func endAll<Output: TFMXOutput>(_ output: inout Output) {
        active = 0
        fadeOut = 0
        fadeIn = 0
        for v in 0 ..< 4 {
            output.off(v)
            writeVolume(v, 0, &output)
        }
        stops += 1
    }

    // MARK: A voice's tick

    /// `lbC000502`: the voice's tick: its stream read once its wait is over, else its effects; a voice about
    /// to read a command or a note it does not go on into, playing low (a period of $1AD or more), is turned
    /// off a tick early.
    private mutating func playVoice<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        voices[v].wait &-= 1
        if voices[v].wait == 0 {
            readStream(v, &output)
            return
        }
        if voices[v].wait == 1, voices[v].periodWritten >= 0x1AD {
            let next = byte(voices[v].at)
            if next != 0x80, next > 0x80 || byte(voices[v].at + 1) & 0x80 == 0 { output.off(v) }
        }
        effects(v, &output)
    }

    /// The voice's instrument (`lbC0005DC`).
    private func instrument(_ v: Int) -> Int { instruments[Int(voices[v].instrument << 2) >> 2] }

    @inline(__always) private mutating func next(_ v: Int) -> UInt8 {
        let b = byte(voices[v].at)
        voices[v].at += 1
        return b
    }

    @inline(__always) private mutating func nextWord(_ v: Int) -> UInt16 { UInt16(next(v)) << 8 | UInt16(next(v)) }

    @inline(__always) private mutating func nextLong(_ v: Int) -> UInt32 { UInt32(nextWord(v)) << 16 | UInt32(nextWord(v)) }

    private mutating func push(_ v: Int, _ value: UInt8) {
        stacks[v * 256 + Int(voices[v].stackTop)] = value
        voices[v].stackTop &+= 2
    }

    private mutating func push(_ v: Int, long value: Int) {
        let bits = UInt32(truncatingIfNeeded: value)
        for k in 0 ..< 4 { stacks[v * 256 + Int(voices[v].stackTop &+ UInt8(k))] = UInt8(truncatingIfNeeded: bits >> (24 - 8 * UInt32(k))) }
        voices[v].stackTop &+= 4
    }

    private mutating func pop(_ v: Int) -> UInt8 {
        voices[v].stackTop &-= 2
        return stacks[v * 256 + Int(voices[v].stackTop)]
    }

    private mutating func popLong(_ v: Int) -> Int {
        voices[v].stackTop &-= 4
        var bits: UInt32 = 0
        for k in 0 ..< 4 { bits = bits << 8 | UInt32(stacks[v * 256 + Int(voices[v].stackTop &+ UInt8(k))]) }
        return Int(Int32(bitPattern: bits))
    }

    /// `lbC000558`: the voice's stream read, its commands done, up to a note, a wait, or a command that ends
    /// the reading.
    private mutating func readStream<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        for _ in 0 ..< Self.mostCommands {
            let b = next(v)
            if b < 0x80 {
                if note(v, b, &output) { return }
                continue
            }
            if !command(v, b & 0x7F, &output) { return }
        }
        // (A stream that reads on for ever.)
        voiceOff(v, &output)
    }

    /// A command (`lbW000582`); false if the reading ends with it.
    private mutating func command<Output: TFMXOutput>(_ v: Int, _ c: UInt8, _ output: inout Output) -> Bool {
        let a = instrument(v)
        switch c {
        case 0:
            voices[v].wait = nextWord(v)
            return false
        case 1: voices[v].volumeScale = next(v)
        case 2: voices[v].detune = next(v)
        case 3: voices[v].instrument = next(v)
        case 4:
            // An instrument defined where it is read, and passed over.
            let number = Int(next(v) << 2) >> 2
            let place = voices[v].at - 2
            instruments[number] = place
            voices[v].at = place + Int(nextWord(v)) * 2
        case 5: voices[v].at = popLong(v)
        case 6:
            let offset = Int(Int32(bitPattern: nextLong(v)))
            push(v, long: voices[v].at)
            voices[v].at += offset
        case 7:
            voices[v].at += Int(Int32(bitPattern: nextLong(v)))
            wentBack(v)
        case 8:
            push(v, next(v))
            push(v, long: voices[v].at)
        case 9:
            let place = popLong(v)
            let times = pop(v) &- 1
            if times != 0 {
                voices[v].at = place
                push(v, times)
                push(v, long: place)
            }
        case 10:
            fadeSpeed = next(v)
            fadeIn = 0
            fadeFraction = 0
            fadeOut = 1
        case 11: break
        case 12: count &+= 1
        case 13:
            voices[v].at = voices[v].begin
            wentBack(v)
        case 14:
            voiceOff(v, &output)
            return false
        case 15:
            fadeSpeed = next(v)
            fadeIn = 1
            if fadeLevel == 0 { fadeLevel = 1 }
            fadeFraction = 0
            fadeOut = 0
        case 16:
            set(a + 0x14, next(v))
            set(a + 0x15, next(v))
            set(a + 0x16, next(v))
            if next(v) == 0 {
                set(a + 8, byte(a + 8) | 0x20)
            } else {
                set(a + 8, byte(a + 8) & ~0x20)
                set(a + 0x17, next(v))
            }
        case 17: set(a + 8, byte(a + 8) | 1)
        case 18: set(a + 8, byte(a + 8) & ~1)
        case 19: flag(a, 2, v, [0x10, 0x11, 0x12, 0x13])
        case 20: flag(a, 4, v, [15])
        case 21: flag(a, 8, v, [0x18, 0x19, 0x1A, 0x1B])
        case 22:
            if next(v) == 0 {
                set(a + 8, byte(a + 8) & ~0x10)
            } else {
                set(a + 8, byte(a + 8) | 0x10)
                set(a + 14, next(v))
                set(a + 12, next(v))
                set(a + 13, next(v))
            }
        case 23: flag(a, 0x40, v, [9, 10, 11])
        case 24: flag(a, 0x80, v, [0x1E, 0x1F, 0x20])
        case 25:
            voices[v].wait = nextWord(v)
            output.off(v)
            return false
        case 26:
            lightFilter = next(v) != 0
            output.writeLightFilter(lightFilter)
        case 27:
            if next(v) != count {
                voices[v].at -= 2
                voices[v].wait = 1
                return false
            }
        case 28: voices[v].transpose = next(v)
        default:
            // (Past the player's table of commands: a broken stream, turned off.)
            voiceOff(v, &output)
            return false
        }
        return true
    }

    /// A command that sets an effect of the instrument's on (and its settings) or, given nought, off.
    private mutating func flag(_ a: Int, _ bit: UInt8, _ v: Int, _ settings: [Int]) {
        if next(v) == 0 {
            set(a + 8, byte(a + 8) & ~bit)
        } else {
            set(a + 8, byte(a + 8) | bit)
            for s in settings { set(a + s, next(v)) }
        }
    }

    /// `SongEndTest`: the voice has gone back; once every voice has since the song last ended, it ends again.
    private mutating func wentBack(_ v: Int) {
        notBack[v] = false
        if !notBack[0], !notBack[1], !notBack[2], !notBack[3] {
            notBack = notBackAtStart
            endings += 1
        }
    }

    /// `lbC00070A`: the voice turned off and silent, played no more, and the song's end said.
    private mutating func voiceOff<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        output.off(v)
        writeVolume(v, 0, &output)
        active &= ~(1 << UInt8(v))
        endings += 1
    }

    /// `lbC000938`: a note: the voice turned off, the note's period found, its length and its effects begun,
    /// its envelope begun unless it goes on from the note before, its sample or buffer given Paula, and its DMA
    /// to be turned on at the tick's end. False for a note of no length, which is passed over.
    private mutating func note<Output: TFMXOutput>(_ v: Int, _ b: UInt8, _ output: inout Output) -> Bool {
        let a = instrument(v)
        let note = (b &+ voices[v].transpose) & 0x7F
        output.off(v)
        voices[v].note = note
        let flags = byte(a + 8)
        if flags & 0x10 != 0 {
            voices[v].slidePeriod = voices[v].period
            voices[v].slideCount = 1
        }
        voices[v].period = period(a, note)
        let length = nextWord(v)
        guard length & 0x7FFF != 0 else { return false }
        voices[v].wait = length & 0x7FFF
        voices[v].hold = (length & 0x7FFF) >> 1
        voices[v].struck = 1
        if flags & 4 != 0 {
            voices[v].flip = 0
            voices[v].flipCount = byte(a + 15)
        }
        if flags & 2 != 0 {
            voices[v].vibratoWait = byte(a + 0x10)
            if voices[v].vibratoWait == 0 {
                voices[v].vibratoStep = byte(a + 0x12)
                voices[v].vibratoOffset = 0
                voices[v].vibratoCount = byte(a + 0x11)
                voices[v].vibratoTurns = byte(a + 0x13)
            }
        }
        if flags & 0x40 != 0 {
            voices[v].tremoloCount = 1
            voices[v].tremoloStep = 0 &- byte(a + 10)
            voices[v].tremoloLevel = 0
        }
        if length & 0x8000 == 0 {
            voices[v].fraction = 0
            if byte(a + 0x14) != 0 {
                voices[v].level = 0
                voices[v].stage = 0
            } else if byte(a + 0x15) != 0, byte(a + 0x16) != 0x40 {
                voices[v].level = 0x40
                voices[v].stage = 1
            } else {
                voices[v].stage = 2
                voices[v].level = byte(a + 0x16)
            }
        }
        var place = a + 0x26
        if flags & 8 != 0 {
            voices[v].smoothCount = byte(a + 0x1A)
            voices[v].smoothStep = byte(a + 0x1B)
            voices[v].smoothDistance = byte(a + 0x18)
            smooth(v, a)
            place = buffersAt + 256 * v
        }
        if flags & 0x80 != 0 {
            voices[v].bendCount = byte(a + 0x20)
            voices[v].bend = byte(a + 0x1E)
            voices[v].bendStep = 1
            bendShape(v, a)
            place = buffersAt + 256 * v
        }
        voices[v].location = place
        voices[v].length = long(a + 0x22) != 0 ? word(a + 0x24) : word(a + 4)
        output.takeNextBuffer(v, start: voices[v].location, length: voices[v].length)
        heard(v, a, flags, &output)
        started |= 1 << UInt8(v)
        return true
    }

    /// `lbC000E2E`: a note's period: of an instrument tuned by its length (no period of its own), the
    /// octave's period times its multiple (28) over its length; else its period moved by the semitone, and an
    /// octave at a time from its own octave (29).
    private func period(_ a: Int, _ note: UInt8) -> UInt16 {
        var octave = note / 12
        let semitone = Int(note % 12)
        let tuned = word(a + 6)
        if tuned == 0 {
            var p = UInt32(Self.lengthPeriods[semitone])
            let multiple = byte(a + 0x1C)
            if multiple != 1 { p = UInt32(UInt16(truncatingIfNeeded: p)) * UInt32(multiple) }
            let length = word(a + 4)
            if length != 1 {
                // (DIVU.W: by nought, or to more than a word, leaves it as it was.)
                if length != 0, p / UInt32(length) <= 0xFFFF { p = p / UInt32(length) }
                p &= 0xFFFF
            }
            while octave != 0 {
                p >>= 1
                octave -= 1
            }
            return UInt16(truncatingIfNeeded: p << 1)
        }
        var p = UInt16(truncatingIfNeeded: ((UInt32(tuned) * UInt32(Self.semitones[semitone])) << 1) >> 16)
        var own = byte(a + 0x1D)
        while own != octave {
            if own < octave {
                p >>= 1
                own &+= 1
            } else {
                p <<= 1
                own &-= 1
            }
        }
        return p
    }

    /// `lbC000A84`: the voice's effects, a tick after its note has begun: its sample's loop given Paula, or
    /// silence for one played once; then its tremolo, slide, octave, vibrato, envelope, smoothing and bending.
    private mutating func effects<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let a = instrument(v)
        let flags = byte(a + 8)
        if voices[v].struckBefore != 0 {
            if voices[v].struckBefore == 2 || long(a + 0x22) == 0 && flags & 1 != 0 {
                voices[v].location = silenceAt
                voices[v].length = 1
                output.takeNextBuffer(v, start: silenceAt, length: 1)
            } else if long(a + 0x22) != 0 {
                voices[v].location = a + 0x26 + Int(word(a + 0x22)) * 2
                voices[v].length = word(a + 0x24) &- word(a + 0x22)
                output.takeNextBuffer(v, start: voices[v].location, length: voices[v].length)
            }
        }
        voices[v].struckBefore = voices[v].struck
        voices[v].struck = 0
        if flags & 0x40 != 0 {
            voices[v].tremoloCount &-= 1
            if voices[v].tremoloCount == 0 {
                voices[v].tremoloCount = byte(a + 9)
                voices[v].tremoloLevel &+= voices[v].tremoloStep
                if byte(a + 11) >= voices[v].tremoloLevel { voices[v].tremoloStep = 0 &- voices[v].tremoloStep }
            }
        }
        if flags & 0x10 != 0, voices[v].period != voices[v].slidePeriod {
            voices[v].slideCount &-= 1
            if voices[v].slideCount == 0 {
                voices[v].slideCount = byte(a + 14)
                let step = word(a + 12)
                let target = voices[v].period
                if target < voices[v].slidePeriod {
                    voices[v].slidePeriod &-= step
                    if target >= voices[v].slidePeriod { voices[v].slidePeriod = target }
                } else {
                    voices[v].slidePeriod &+= step
                    if target < voices[v].slidePeriod { voices[v].slidePeriod = target }
                }
            }
        }
        if flags & 4 != 0 {
            voices[v].flipCount &-= 1
            if voices[v].flipCount == 0 {
                voices[v].flipCount = byte(a + 15)
                voices[v].flip ^= 1
            }
        }
        if flags & 2 != 0 {
            if voices[v].vibratoWait != 0 {
                voices[v].vibratoWait -= 1
                if voices[v].vibratoWait == 0 {
                    voices[v].vibratoCount = 1
                    voices[v].vibratoOffset = 0
                    voices[v].vibratoStep = byte(a + 0x12)
                    voices[v].vibratoTurns = byte(a + 0x13)
                }
            } else {
                voices[v].vibratoCount &-= 1
                if voices[v].vibratoCount == 0 {
                    voices[v].vibratoCount = byte(a + 0x11)
                    voices[v].vibratoOffset &+= UInt16(bitPattern: Int16(Int8(bitPattern: voices[v].vibratoStep)))
                    voices[v].vibratoTurns &-= 1
                    if voices[v].vibratoTurns == 0 {
                        voices[v].vibratoTurns = byte(a + 0x13) << 1
                        voices[v].vibratoStep = 0 &- voices[v].vibratoStep
                    }
                }
            }
        }
        envelope(v, a, flags, &output)
        var changed = false
        if flags & 8 != 0 {
            voices[v].smoothCount &-= 1
            if voices[v].smoothCount == 0 {
                voices[v].smoothCount = byte(a + 0x1A)
                let distance = Int(voices[v].smoothDistance) + Int(Int8(bitPattern: voices[v].smoothStep))
                voices[v].smoothDistance = UInt8(truncatingIfNeeded: distance)
                if distance < 0 || distance >= Int(byte(a + 0x19)) || distance <= Int(byte(a + 0x18)) {
                    voices[v].smoothStep = 0 &- voices[v].smoothStep
                }
                changed = true
            }
        }
        if flags & 0x80 != 0 {
            voices[v].bendCount &-= 1
            if voices[v].bendCount == 0 {
                voices[v].bendCount = byte(a + 0x20)
                voices[v].bend &+= voices[v].bendStep
                if voices[v].bend == byte(a + 0x1E) || voices[v].bend == byte(a + 0x1F) { voices[v].bendStep = 0 &- voices[v].bendStep }
                changed = true
            }
        }
        if changed {
            if flags & 8 != 0 { smooth(v, a) }
            if flags & 0x80 != 0 { bendShape(v, a) }
        }
        heard(v, a, flags, &output)
    }

    /// The envelope's tick (`lbC000BBA`): attack to full (or to the sustain's level, with no decay), decay to
    /// the sustain's level, held for half the note's length (unless the instrument holds it to the next), and
    /// released to nought, each at its rate; a looped sample let go plays its end then.
    private mutating func envelope<Output: TFMXOutput>(_ v: Int, _ a: Int, _ flags: UInt8, _ output: inout Output) {
        let attack = byte(a + 0x14), decay = byte(a + 0x15), sustain = byte(a + 0x16), release = byte(a + 0x17)
        if voices[v].stage == 3 {
            guard voices[v].level != 0 else { return }
            let (sum, over) = voices[v].fraction.addingReportingOverflow(max(1, sustain >> 1))
            voices[v].fraction = sum
            var skip = over
            while skip || voices[v].fraction >= release {
                skip = false
                voices[v].fraction &-= release
                voices[v].level &-= 1
                if voices[v].level == 0 { break }
            }
            return
        }
        if flags & 0x20 == 0 {
            var due = true
            if voices[v].hold != 0 {
                voices[v].hold -= 1
                due = voices[v].hold == 0
            }
            if due, voices[v].stage == 2 {
                voices[v].stage = 3
                voices[v].fraction = 0
                if flags & 1 != 0, long(a + 0x22) != 0 {
                    voices[v].length = word(a + 4) &- word(a + 0x22)
                    output.takeNextBuffer(v, start: voices[v].location, length: voices[v].length)
                    voices[v].struck = 2
                }
                return
            }
        }
        switch voices[v].stage {
        case 1:
            voices[v].fraction &+= 0x40 &- sustain
            while voices[v].fraction >= decay {
                voices[v].fraction &-= decay
                voices[v].level &-= 1
                if voices[v].level == 0 { break }
            }
            if sustain >= voices[v].level { voices[v].stage = 2 }
        case 0:
            let top: UInt8 = decay == 0 ? sustain : 0x40
            let (sum, over) = voices[v].fraction.addingReportingOverflow(top)
            voices[v].fraction = sum
            var skip = over
            while skip || voices[v].fraction >= attack {
                skip = false
                if attack == 0 { break }
                voices[v].fraction &-= attack
                voices[v].level &+= 1
            }
            if voices[v].level == top {
                if decay == 0 {
                    voices[v].stage = 2
                } else {
                    voices[v].fraction = 0
                    voices[v].stage = sustain == 0x40 ? 2 : 1
                }
            }
        default: break
        }
    }

    /// `lbC000D5A`: the voice's volume (its envelope's level, scaled by its tremolo, its own scale and the fade)
    /// and period (its note's, or the slide's, with its vibrato, an octave up if its flip says so, and what is
    /// added to it) told Paula.
    private mutating func heard<Output: TFMXOutput>(_ v: Int, _ a: Int, _ flags: UInt8, _ output: inout Output) {
        var volume = UInt16(voices[v].level)
        if flags & 0x40 != 0, voices[v].tremoloLevel != 0 { volume = (volume * UInt16(voices[v].tremoloLevel)) >> 8 }
        if voices[v].volumeScale != 0 { volume = (volume * UInt16(voices[v].volumeScale)) >> 8 }
        if fadeOut != 0 || fadeIn != 0, fadeLevel != 0 { volume = (volume * UInt16(fadeLevel)) >> 8 }
        writeVolume(v, volume & 0x7F, &output)
        var period = flags & 0x10 != 0 ? voices[v].slidePeriod : voices[v].period
        if flags & 2 != 0, voices[v].vibratoWait == 0 { period &+= voices[v].vibratoOffset }
        if flags & 4 != 0, voices[v].flip != 0 { period >>= 1 }
        period &+= UInt16(voices[v].detune)
        periods[v] = period
        voices[v].periodWritten = period
        output.writePeriod(v, period)
    }

    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume
        output.writeVolume(v, volume)
    }

    // MARK: The buffers

    /// A byte of a voice's buffer written, if it is within the buffers.
    @inline(__always) private func buffer(_ v: Int, _ index: Int, _ value: UInt8) {
        let at = buffersAt + 256 * v + index
        if at >= buffersAt, at < silenceAt { memory[at] = value }
    }

    /// `lbC000DD2`: the sample smoothed into the voice's buffer: each byte the mean of itself and the one so
    /// far before it (the smoothing's distance), going round.
    private func smooth(_ v: Int, _ a: Int) {
        let size = Int(word(a + 4) << 1)
        let sample = a + 0x26
        var from = Int(Int16(truncatingIfNeeded: size - Int(voices[v].smoothDistance)))
        var to = 0
        repeat {
            let sum = Int(Int8(bitPattern: byte(sample + from))) + Int(Int8(bitPattern: byte(sample + to)))
            buffer(v, to, UInt8(truncatingIfNeeded: sum >> 1))
            from += 1
            if from == size { from = 0 }
            to = (to + 1) & 0xFFFF
        } while to != size
    }

    /// `lbC000EEC`: the sample (or its smoothing) bent into the voice's buffer: means of as many bytes as the
    /// bending's amount, joined by straight lines; of one, copied as it is.
    private func bendShape(_ v: Int, _ a: Int) {
        let size = Int(word(a + 4) << 1) & 0xFFFF
        let amount = Int(voices[v].bend)
        let own = buffersAt + 256 * v
        let source = byte(a + 8) & 8 != 0 ? own : a + 0x26
        if amount == 1 {
            guard source != own else { return }
            var longs = UInt8(truncatingIfNeeded: size >> 2)
            if longs != 0x40 { longs &+= 1 }
            var k = 0
            repeat {
                for i in 0 ..< 4 { buffer(v, k + i, byte(source + k + i)) }
                k += 4
                longs &-= 1
            } while longs != 0
            return
        }
        // (A mean of no bytes would be a division by nought, which the 68000 would not live through.)
        guard amount != 0 else { return }
        func mean(_ from: Int) -> (Int, Int) {
            var i = from, sum = 0
            for _ in 0 ..< amount {
                sum += Int(Int8(bitPattern: byte(source + i)))
                i += 1
                if i == size { i = 0 }
            }
            return (Int(Int16(truncatingIfNeeded: sum)) / amount, i)
        }
        var to = amount >> 1
        var (level, _) = mean(0)
        var round = false
        repeat {
            var from = (amount >> 1) + to
            if from >= size { from -= size }
            let (target, _) = mean(from)
            var rise = target - level
            let sign = rise < 0 ? -1 : 1
            if rise < 0 { rise = -rise }
            var error = 0
            for _ in 0 ..< amount {
                buffer(v, to, UInt8(truncatingIfNeeded: level))
                error += rise
                while error >= amount {
                    error -= amount
                    level += sign
                }
                to += 1
                if to >= size {
                    to -= size
                    round = true
                }
            }
            level = target
        } while !round
    }

    /// Paula's period for the voice as the tick just run began (its writes in the tick are told at their
    /// moments).
    func period(_ voice: Int) -> UInt16 { periodsBefore[voice] }
    /// Paula's volume for the voice as the tick just run began, as she takes it: no more than 64.
    func volume(_ voice: Int) -> UInt16 { min(64, volumesBefore[voice]) }
    /// What the player last gave Paula's period register for the voice.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Soundfactory's music, played on Paula by `PaulaTickRenderer`.
extension SoundfactoryPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Soundfactory")
        let plural = instrumentCount == 1 ? "" : "s"
        info.detail = "Profiteam's Soundfactory, its own replayer; \(instrumentCount) instrument\(plural)"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
