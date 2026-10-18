// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the MaxTrax Music Driver of Talin (David Joiner) and Joe Pearce (1991-93), whose source
// Joe Pearce released under the GNU Lesser General Public Licence 2.1 or later, as UADE carries it
// (amigasrc/players/other/max_trax: max.asm, shared.asm, driver.i). Its routines are named here as
// it names them, and the places in them by their labels.

/// MaxTrax, the music driver Talin (David Joiner) and Joe Pearce wrote, and The Dreamers Guild
/// licensed to the makers of Amiga games in the early 1990s, for scores made in Music-X (`LoadPerf`
/// is "load a Music-X score"): Westwood's Dune II and The Legend of Kyrandia, SSI's Gold Box games,
/// Might and Magic III, SimAnt and SimEarth, A-Train, Contraption Zack, Darkseed.
/// It is not a tracker: a score is a stream of MIDI's events (notes with how long they last, the
/// instrument, the pitch's bend, controllers, the tempo) on sixteen channels, which the driver plays on
/// Paula's four voices, choosing a voice for each note as it comes; each instrument is a sample of
/// an attack and a sustain, in as many octaves as it was saved with, and envelopes of its volume.
///
/// This is the driver itself, as it runs on each vertical blank (`MusicServer`, from `MusicVBlank`):
/// the notes whose time has come are ended, the score's events up to the time are done, and then
/// each voice's envelope, portamento and pitch (`EnvelopeManager`). It tells Paula what to do as the
/// driver tells the Amiga's audio.device, which tells her: a note's attack and its sustain written
/// one after the other (`CMD_WRITE`, the attack once and the sustain for ever; for an instrument of
/// no sustain, silence after its attack, the device having nothing more to play), a voice silenced
/// (`CMD_FLUSH`), and its period and volume changed at once (`ADCMD_PERVOL`).
///
/// It owns the memory Paula plays from: the file of the instruments (the tune's own file, or the
/// one beside it its instruments are in), and after it the room `PaulaTickRenderer` wants (whose
/// first bytes, nought, are silence).
struct MaxTraxPlayer: ~Copyable {
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    var silenceAt: Int { samplesSize }
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { samplesSize + 0x20000 }
    static let mixingSpace = 2048

    private let samplesSize: Int
    private var file: MaxTraxFile
    /// The scores' events as the file has them, which the driver may write into as it plays (see
    /// `ControlCh`'s portamento), for each song to start from.
    private let originalEvents: [MaxTraxEvent]
    /// What of the tune is not heard as it asks (see `TuneInfo.shortfalls`).
    let shortfalls: [String]

    let songCount: Int
    private(set) var song = 0
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// The tempos The Legend of Kyrandia gives its scores, if this is one of its files.
    private let gameTempos: [UInt8]

    /// How long each tick is: the driver runs on the vertical blank (its server, `MusicVBlank`, added
    /// by `InitMusicTagList`), which on a PAL Amiga comes every frame of 313 lines of 227 of Paula's
    /// clocks, 49.92 times a second. (Its timing takes the frame to be a fiftieth of a second, as
    /// `SysBase->VBlankFrequency` says.)
    static let tickClocks = 313 * 227
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    // The driver's own: its voices (`_voice`), channels (`_channel`) and globals (`_globaldata`).
    var voices = InlineArray<4, Voice>(repeating: Voice())
    var channels = InlineArray<16, Channel>(repeating: Channel())
    var global = Global()
    /// The bounce bytes of `pick_voice1`, for the right side and the left (`right_round`, `left_round`).
    var rounds = InlineArray<2, UInt8>(repeating: 0)
    /// The period and volume each voice was last given (by `CMD_WRITE`'s or `ADCMD_PERVOL`'s).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    /// The Amiga's filter, as the driver last set it (`SetAudioFilter`).
    private(set) var lightFilter = false

    /// True for a file the driver's `LoadPerf` takes: one that begins "MXTX".
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 4 && data[0] == 0x4D && data[1] == 0x58 && data[2] == 0x54 && data[3] == 0x58
    }

    /// True for a file that has no instruments of its own, whose instruments are in another beside it
    /// (in the collections, `set.smpl`), and which is not played without it.
    static func needsInstruments(_ data: [UInt8]) -> Bool {
        var probe = MaxTraxFile()
        probe.readInstruments(data)
        return probe.refusal == nil && probe.instrumentCount == 0
    }

    /// Reads the file and starts its score `song` (counting from nought). A file of scores alone takes
    /// its instruments from `instruments`, the file beside it that holds them.
    init(_ data: [UInt8], instruments: [UInt8]? = nil, song: Int = 0) throws(TuneError) {
        var file = MaxTraxFile()
        file.readScores(data)
        var refusal = file.refusal
        if refusal == nil {
            file.readInstruments(data)
            refusal = file.refusal
        }
        var samplesFrom = data
        if refusal == nil, file.instrumentCount == 0 {
            // Scores alone: the instruments are loaded from the other file (`LoadPerf` with `PERF_SAMPLES`).
            if let instruments {
                if !Self.isOne(instruments) {
                    refusal = .malformed("the file of its instruments is not one of MaxTrax's")
                } else {
                    file.readInstruments(instruments)
                    refusal = file.refusal
                    samplesFrom = instruments
                }
            } else if !file.scoreCounts.isEmpty {
                refusal = .missingCompanion("its instruments are in a file of their own, set.smpl, which was not given with it")
            }
        }
        if refusal == nil, file.scoreCounts.isEmpty {
            refusal = .malformed(file.instrumentCount > 0 ? "it holds instruments and no score to play" : "it holds no score to play")
        }
        // (`LoadPerf` fails a file with no instrument that has a sample.)
        if refusal == nil, !(0 ..< 64).contains(where: { file.patches[$0].sample >= 0 }) {
            refusal = .malformed("none of its instruments has a sample")
        }

        samplesSize = samplesFrom.count
        memoryCapacity = samplesFrom.count + 0x20000 + Self.mixingSpace
        let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, byte) in samplesFrom.enumerated() { memory[i] = byte }
        self.memory = memory
        songCount = max(1, file.scoreCounts.count)
        gameTempos = Self.kyrandiaTempos(file)
        shortfalls = Self.shortfalls(of: file)
        originalEvents = file.events
        self.file = file
        if let refusal { throw refusal }
        begin(song)
    }

    deinit { memory.deallocate() }

    // MARK: The driver's structures

    /// A voice's part of the driver (`VoiceData`), named as there.
    struct Voice {
        /// The channel it plays for, or -1 when it is free.
        var channel = -1
        var patch = 0
        /// The envelope step it is in, among the file's envelopes, or -1 for none.
        var envelope = -1
        var ticksLeft: Int32 = 0
        var portaTicks: Int32 = 0
        var incrVolume: Int32 = 0
        var periodOffset: Int32 = 0
        /// The octave's sample it was started on.
        var sample = -1
        var envelopeLeft: UInt16 = 0
        var noteVolume: UInt16 = 0
        var baseVolume: UInt16 = 0
        var lastPeriod: UInt16 = 0
        var baseNote: UInt8 = 0
        var endNote: UInt8 = 0
        var priority: UInt8 = 0
        var status: UInt8 = 0
        var flags: UInt8 = 0
        var lastVolume: UInt8 = 0
    }

    /// A channel's part of the driver (`ChannelData`), named as there.
    struct Channel {
        var patch = 0
        var rpn: UInt16 = 0
        var portamentoTime: UInt16 = 0
        var pitchBend: UInt16 = 0
        var realBend: UInt16 = 0
        var pitchBendRange: UInt8 = 0
        var volume: UInt8 = 0
        var voicesActive: UInt8 = 0
        var number: UInt8 = 0
        var flags: UInt8 = 0
        var lastNote: UInt8 = 0
    }

    /// When a voice's note is to end (`StopEvent`): its note ($FF for none), its channel, and the time
    /// left, in 256ths of the score's time.
    struct StopEvent {
        var command: UInt8 = 0xFF
        var data: UInt8 = 0
        var stopTime: Int32 = 0
    }

    /// The driver's globals (`GlobalData`) that music needs, named as there.
    struct Global {
        var ticks: Int32 = 0
        var tickUnit: Int32 = 0
        var tempoTime: Int32 = 0
        var tempoTicks: Int32 = 0
        var currentTime: Int32 = 0
        /// The score playing and the event it is at.
        var score = 0
        var current = 0
        var repeatPoint = InlineArray<4, Int>(repeating: 0)
        var noteOff = InlineArray<4, StopEvent>(repeating: StopEvent())
        var volume: UInt16 = 64
        var filter: UInt16 = 1
        var tempo: UInt16 = 120
        var currentTempo: UInt16 = 0
        var startTempo: UInt16 = 0
        var deltaTempo: UInt16 = 0
        var repeatCount = InlineArray<4, UInt8>(repeating: 0)
        var repeatTotal: UInt8 = 0
        var lastVoice: UInt8 = 0
        var flags: UInt8 = 0
    }

    // `ENV_` (driver.i).
    static let envFree: UInt8 = 0, envHalt: UInt8 = 1, envDecay: UInt8 = 2, envRelease: UInt8 = 3
    static let envSustain: UInt8 = 4, envAttack: UInt8 = 5, envStart: UInt8 = 6
    // `VOICE_`.
    static let voiceStolen: UInt8 = 1 << 0, voicePortamento: UInt8 = 1 << 1, voiceDamper: UInt8 = 1 << 2
    static let voiceBlocked: UInt8 = 1 << 3, voiceRecalc: UInt8 = 1 << 4
    // `CHAN_`.
    static let chanPan: UInt8 = 1 << 0, chanMono: UInt8 = 1 << 1, chanPortamento: UInt8 = 1 << 2
    static let chanDamper: UInt8 = 1 << 3, chanMicrotonal: UInt8 = 1 << 4, chanAltered: UInt8 = 1 << 7
    // `MUSIC_`.
    static let musicPlaying: UInt8 = 1 << 0, musicAddedNote: UInt8 = 1 << 1, musicVelocity: UInt8 = 1 << 3
    static let musicLoop: UInt8 = 1 << 4

    /// The time of a frame, in 256ths of a millisecond (`glob_FrameUnit`): (1000 << 8) over the 50 frames
    /// a second `SysBase->VBlankFrequency` says there are.
    static let frameUnit: Int32 = (1000 << 8) / 50
    static let frequency: UInt32 = 50

    // MARK: Songs

    /// Starts song `song` (counting from nought; one past the last is the first), as a player newly
    /// loaded would; and finds how long it is.
    mutating func select(song: Int) throws(TuneError) { begin(song) }

    private mutating func begin(_ song: Int) {
        self.song = song >= 0 && song < songCount ? song : 0
        initialise()
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (It comes to its end in a tick, and the tick after begins it again.)
        lengthClocks = endings > 0 ? UInt64(ticks) * UInt64(Self.tickClocks) : nil
        initialise()
    }

    /// The driver as `OpenMusic` first sets it up, then the score chosen (`SelectScore`) and started
    /// going round (`LoopSong`, which is `PlaySong` from its start, with `MUSIC_LOOP` set).
    private mutating func initialise() {
        file.events = originalEvents
        voices = .init(repeating: Voice())
        channels = .init(repeating: Channel())
        global = Global()
        rounds = .init(repeating: 0)
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        endings = 0
        // `OpenMusic`: each channel on the instrument of its own number.
        for c in 0 ..< 16 {
            channels[c].patch = c
            channels[c].number = UInt8(c)
            resetChannel(c)
        }
        // From the file, as `LoadPerf` keeps them: the tempo, the filter (its flags' lowest bit), and
        // whether the notes' own volumes are heard (their second).
        global.tempo = file.tempo
        global.filter = file.flags & 1
        if file.flags & 2 != 0 { global.flags |= Self.musicVelocity }
        // `PlaySong`.
        var none = TFMXSilentOutput()
        systemReset(&none)
        global.score = song
        global.current = 0
        for v in 0 ..< 4 { global.noteOff[v].command = 0xFF }
        setTempo(global.tempo << 4)
        setAudioFilter(global.filter)
        global.repeatTotal = 0
        global.currentTime = 0
        global.tempoTime = 0
        global.ticks = 0
        global.flags |= Self.musicPlaying | Self.musicLoop
        // The Legend of Kyrandia sets each score's tempo as it starts it.
        if song < gameTempos.count { setTempo(UInt16(gameTempos[song]) << 4) }
    }

    /// The score's event `index`; past its last, an end (where the driver would read on into whatever
    /// follows the score in memory).
    private func event(_ index: Int) -> MaxTraxEvent {
        guard global.score < file.scoreCounts.count, index >= 0, index < file.scoreCounts[global.score] else {
            return MaxTraxEvent(command: 0xFF, data: 0, start: 0, stop: 0)
        }
        return file.events[file.scoreStarts[global.score] + index]
    }

    // MARK: A tick

    /// Runs the driver for a tick (`MusicServer`), telling `output` what Paula is to do, in the order
    /// the driver tells audio.device. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        global.ticks &+= global.tickUnit
        let now = Int32(bitPattern: UInt32(bitPattern: global.ticks) >> 8)

        // The notes whose time is up are ended, each voice's in turn (`.l1`).
        for v in 0 ..< 4 {
            global.lastVoice = UInt8(v)
            guard voices[v].channel >= 0, global.noteOff[v].command & 0x80 == 0 else { continue }
            let left = global.noteOff[v].stopTime
            global.noteOff[v].stopTime = left &- global.tickUnit
            if left > global.tickUnit { continue }
            noteOff(Int(global.noteOff[v].data & 0x0F), note: global.noteOff[v].command)
            global.noteOff[v].command = 0xFF
        }

        if global.flags & Self.musicPlaying != 0 {
            // The events whose time has come (`.l5`). (The driver also stops early in a frame whose beam
            // has passed line 128 by then, so as not to spend too long in the interrupt; a whole frame's
            // events take it nowhere near so long, and are all done here.)
            var at = global.current
            events: while true {
                let e = event(at)
                let time = global.currentTime &+ Int32(e.start)
                if Self.negative(now &- time) { break }
                global.currentTime = time
                if e.command & 0x80 == 0 {
                    global.flags &= ~Self.musicAddedNote
                    noteOn(Int(e.data & 0x0F), note: e.command, velocity: (e.data >> 1) & 0x78, priority: 0, &output)
                    if global.flags & Self.musicAddedNote != 0 {
                        // Its end, as a time from now: its length, less how late it is.
                        let v = Int(global.lastVoice & 3)
                        global.noteOff[v].command = e.command
                        global.noteOff[v].data = e.data & 0x0F
                        global.noteOff[v].stopTime = (Int32(e.stop) &+ global.currentTime &- now) << 8
                    }
                } else {
                    switch e.command {
                    case 0x80:
                        // TEMPO: at once if it is to take less than a tick's time, else over that time.
                        if !Self.negative16(UInt16(truncatingIfNeeded: UInt32(bitPattern: global.tickUnit) >> 8) &- e.stop) {
                            setTempo(UInt16(e.data) << 4)
                            global.tempoTime = 0
                        } else {
                            global.startTempo = global.currentTempo
                            global.deltaTempo = (UInt16(e.data) << 4) &- global.currentTempo
                            global.tempoTime = Int32(e.stop) << 8
                            global.tempoTicks = 0
                        }
                    case 0xFF:
                        // END: back to the score's start, from a time of nought, or the music stopped; and no
                        // more events this tick.
                        endings += 1
                        if global.flags & Self.musicLoop != 0 {
                            at = 0
                            global.ticks = 0
                            global.currentTime = 0
                        } else {
                            global.flags &= ~Self.musicPlaying
                        }
                        break events
                    case 0xE0:
                        pitchBend(Int(e.data & 0x0F), lsb: UInt8(e.stop & 0x7F), msb: UInt8(e.stop >> 8 & 0x7F))
                    case 0xB0:
                        controlChange(Int(e.data & 0x0F), number: UInt8(e.stop >> 8), value: UInt8(e.stop & 0xFF), at: at, &output)
                    case 0xC0:
                        // PROGRAM (`ProgramCh`): the instrument, of the 64.
                        channels[Int(e.data & 0x0F)].patch = Int(e.stop & 0x3F)
                    case 0xA0:
                        let value = UInt8(e.stop & 0xFF)
                        switch e.stop >> 8 {
                        case 0x02:
                            // SPECIAL_BEGINREP: the event after it is where to go back to, so many times more.
                            let total = Int(global.repeatTotal)
                            if total != 4 {
                                global.repeatTotal &+= 1
                                global.repeatCount[total] = value
                                global.repeatPoint[total] = at + 1
                            }
                        case 0x03:
                            // SPECIAL_ENDREP: back, from a time of nought, and no more events this tick; or, the
                            // last time round, on.
                            let total = Int(global.repeatTotal)
                            if total != 0 {
                                if global.repeatCount[total - 1] != 0 {
                                    global.repeatCount[total - 1] &-= 1
                                    at = global.repeatPoint[total - 1]
                                    global.ticks = 0
                                    global.currentTime = 0
                                    break events
                                }
                                global.repeatTotal = UInt8(total - 1)
                            }
                        default:
                            // SPECIAL_SYNC signals the game's task, and SPECIAL_MARK is where `PlaySong` may
                            // begin: neither is heard.
                            break
                        }
                    default:
                        break
                    }
                }
                at += 1
            }
            global.current = at

            // A change of tempo over time (`.l80`).
            if global.tempoTime != 0 {
                global.tempoTicks &+= global.tickUnit
                if !Self.negative(global.tempoTicks &- global.tempoTime) {
                    setTempo(global.startTempo &+ global.deltaTempo)
                    global.tempoTime = 0
                } else {
                    // (The change is taken as a word without its sign: a tempo that falls rises by 65,536
                    // in part, of which the lower word is kept, until the change is over.)
                    let product = UInt32(global.deltaTempo) &* UInt32(bitPattern: global.tempoTicks)
                    let part = Self.divs(Int32(bitPattern: product), global.tempoTime)
                    setTempo(UInt16(truncatingIfNeeded: part) &+ global.startTempo)
                }
            }
        }

        envelopeManager(&output)
        return 20
    }

    /// `SetTempo`: the tempo, in 16ths of a beat a minute, as the score's time a frame, in 256ths of
    /// its units (192 to a beat): (tempo >> 4) × (192 << 8) over 60 × the frames a second.
    mutating func setTempo(_ tempo: UInt16) {
        global.currentTempo = tempo
        global.tickUnit = Int32(bitPattern: UInt32(tempo >> 4) * (192 << 8) / (60 * Self.frequency))
    }

    /// `SetAudioFilter`: the Amiga's filter on for anything but nought.
    mutating func setAudioFilter(_ on: UInt16) {
        lightFilter = on != 0
    }

    /// The $FF the driver writes into the lower byte of the length of event `index` of the score
    /// playing, if it has one.
    mutating func clobberEvent(_ index: Int) {
        guard global.score < file.scoreCounts.count, index >= 0, index < file.scoreCounts[global.score] else { return }
        let at = file.scoreStarts[global.score] + index
        file.events[at].stop = file.events[at].stop & 0xFF00 | 0xFF
    }

    // MARK: The 68000's arithmetic

    /// True if a long's sign bit is set, as the 68000's N flag shows it.
    static func negative(_ value: Int32) -> Bool { value < 0 }
    static func negative16(_ value: UInt16) -> Bool { value & 0x8000 != 0 }
    static func negative8(_ value: UInt8) -> Bool { value & 0x80 != 0 }

    /// The 68000's DIVS.W: a long over a word, the quotient in the lower word and the remainder in the
    /// upper; a quotient too big for a word leaves the long as it was (as here does a divisor of
    /// nought, which on the 68000 is a trap).
    static func divsWord(_ dividend: Int32, _ divisor: Int16) -> Int32 {
        guard divisor != 0 else { return dividend }
        let quotient = Int64(dividend) / Int64(divisor)
        guard quotient >= -32768, quotient <= 32767 else { return dividend }
        let remainder = Int64(dividend) - quotient * Int64(divisor)
        return Int32(bitPattern: UInt32(UInt16(truncatingIfNeeded: remainder)) << 16 | UInt32(UInt16(truncatingIfNeeded: quotient)))
    }

    /// The 68000's DIVU.W, as `divsWord` but without signs.
    static func divuWord(_ dividend: UInt32, _ divisor: UInt16) -> UInt32 {
        guard divisor != 0 else { return dividend }
        let quotient = dividend / UInt32(divisor)
        guard quotient <= 0xFFFF else { return dividend }
        return (dividend % UInt32(divisor)) << 16 | quotient
    }

    /// The driver's `divs`: a long over a long, with signs, as its `comdivide` does it exactly.
    static func divs(_ dividend: Int32, _ divisor: Int32) -> Int32 {
        guard divisor != 0 else { return dividend }
        let quotient = UInt32(dividend.magnitude) / UInt32(divisor.magnitude)
        let result = Int32(bitPattern: quotient)
        return (dividend < 0) != (divisor < 0) ? 0 &- result : result
    }

    // MARK: What Paula is told

    /// Paula's period for the voice, as audio.device last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as audio.device last set it (never more than 64).
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }

    /// `ADCMD_PERVOL`: a voice's period and volume, at once.
    mutating func setPeriodAndVolume(_ voice: Int, period: UInt16, volume: UInt16) {
        periods[voice] = period
        volumes[voice] = volume
    }

    /// The file's sample memory, for the voices to start their notes from.
    func sample(_ index: Int) -> MaxTraxSample? { index >= 0 && index < file.samples.count ? file.samples[index] : nil }
    func patch(_ index: Int) -> MaxTraxPatch { file.patches[index & 63] }
    func envelope(_ index: Int) -> MaxTraxEnvelope {
        index >= 0 && index < file.envelopes.count ? file.envelopes[index] : MaxTraxEnvelope(duration: 0, volume: 0)
    }

    // MARK: What is said of the tune

    /// The Legend of Kyrandia's files, known by their scores' lengths, and the tempos the game sets for
    /// each score as it starts it (in place of the file's own), as ScummVM's Kyra engine has them from
    /// the game (`SoundAmiga_LoK::playTrack`: `tempoIntro`, `tempoIngame`, `tempoFinal`).
    private static func kyrandiaTempos(_ file: MaxTraxFile) -> [UInt8] {
        let intro = [96, 292, 216, 213], finale = [785, 521, 2087]
        let game = [4, 4, 4, 4, 125, 38, 271, 14, 12, 30, 2027, 317]
        if file.scoreCounts == intro { return [0x46, 0x55, 0x3C, 0x41] }
        if file.scoreCounts == finale { return [0x78, 0x50] }
        if file.scoreCounts.count == 23, Array(file.scoreCounts.prefix(game.count)) == game {
            return [0x64, 0x64, 0x64, 0x64, 0x64, 0x73, 0x4B, 0x64, 0x64, 0x64, 0x55, 0x9C,
                    0x6E, 0x91, 0x78, 0x84, 0x32, 0x64, 0x64, 0x6E, 0x3C, 0xD8, 0xAF]
        }
        return []
    }

    /// What the tune asks for and does not have: instruments its notes are played on that are not in
    /// the file (whose notes the driver leaves out, `NoteOn` finding no sample); and a score with no
    /// end, which the driver would read on past.
    private static func shortfalls(of file: MaxTraxFile) -> [String] {
        var missing: UInt64 = 0
        var endless = 0
        for s in file.scoreCounts.indices {
            var programs = Array(0 ..< 16)
            var ended = false
            for i in 0 ..< file.scoreCounts[s] {
                let e = file.events[file.scoreStarts[s] + i]
                if e.command == 0xFF {
                    ended = true
                    break
                }
                if e.command == 0xC0 {
                    programs[Int(e.data & 0x0F)] = Int(e.stop & 0x3F)
                } else if e.command < 0x80, e.data & 0xF0 != 0 {
                    let patch = programs[Int(e.data & 0x0F)]
                    if file.patches[patch].sample < 0 { missing |= 1 << UInt64(patch) }
                }
            }
            if !ended { endless += 1 }
        }
        var sentences: [String] = []
        if missing != 0 {
            sentences.append(Shortfall.some(missing.nonzeroBitCount, one: "instruments is not in the file, and its notes are not heard.",
                                            many: "instruments are not in the file, and their notes are not heard."))
        }
        if endless > 0 {
            let whose = file.scoreCounts.count == 1 ? "Its score has" : Shortfall.some(endless, one: "scores has", many: "scores have")
            sentences.append(whose + " no end, past which its player would read on into whatever followed it: it is played to its last event and begun again.")
        }
        return sentences
    }
}

/// MaxTrax, played on Paula by `PaulaTickRenderer`.
extension MaxTraxPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "MXTX")
        info.shortfalls = shortfalls
        info.detail = "MaxTrax"
        return info
    }

    /// MaxTrax's music is as loud on the Amiga's chip as ProTracker's is, in the middle of UnExoticA's
    /// 77 files that play (-24.1 dB against -24.2), and is left as it is (2026-10-18).
    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
