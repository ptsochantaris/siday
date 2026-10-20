// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Andrew Parton's replayer of B-17 Flying Fortress (MicroProse, 1993), as Wanted Team adapted
// it for EaglePlayer ("Andrew Parton player module V1.1 (30 Apr 2014)", carried by UADE as
// players/Andrew_Parton, whose source UADE also carries as amigasrc/players/wanted_team/Andrew Parton/
// SRC_AndrewParton/Andrew Parton_v2.asm). The labels given are that source's; the player's variables are
// named by their offsets from its `Base`.

/// Andrew Parton's music for B-17 Flying Fortress, the only game known to have used it: a bank of up to
/// twenty samples, each with an envelope and a vibrato, and a stream of events much like a MIDI file's.
///
/// The file: 'BANK'; twenty places (nought for a sample that is not there), twenty lengths, twenty
/// lengths of loops (nought for none) and twenty places where they begin, as longs; four bytes for each
/// sample's envelope (how fast it rises, how fast it falls to its level, the level, and how fast it
/// dies away) and four for its vibrato (the ticks before it begins, how deep it is and how fast); then
/// the samples, each after a name of 16 bytes; and the stream. That is a byte to wait before it, and then
/// events, each followed by the ticks to wait after it: $9n a note (its number and how hard it is
/// struck, half of which is the height of its envelope; nought or one for none, which lets the voice's
/// note die away), $8n the voice's note let die away, $Cn the sample (the program) for voice n, `C0 7E`
/// back to the start, and $FF the end. The voice is n's last two bits; a byte under $80 repeats the last
/// event's kind (running status).
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It runs fifty times a second. A note is started at once: the voice
/// turned off, told the sample, its length and the note's period (from a table of six octaves), turned
/// on, and told its loop (or silence, for a sample without one); its volume is set by its envelope, from
/// nought, at every tick after; and its period is bent by its vibrato, once it has begun.
///
/// Each voice's writes are told Paula at their moments in the tick (`TFMXOutput.timed(at:)`), as they fall
/// in UADE: a note waits for the beam to begin nine lines (`DMAWait`) before its DMA is turned on and
/// again before it is told its loop, and so each note in a tick comes some 4,500 of Paula's clocks after
/// the one before, and the envelopes and vibratos after them all.
///
/// A song that comes back to its start goes round; one that comes to its end ($FF) has stopped once each
/// of its voices has died away (the player goes on moving the voices' envelopes, and only stops reading
/// the stream), or five seconds after its end, if one is still held. (UADE stops running the player once
/// it has told EaglePlayer of the end, and holds its voices as they are.) Where the stream would be read past
/// the file, or read for ever in a tick, it has come to its end.
struct AndrewPartonPlayer: ~Copyable {
    /// The file and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the noughts after the file. (A sample without a loop
    /// is given the file's first four bytes, which the player clears to be its silence.)
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where the stream is (`MusicBase`), and its first event (the byte after its first wait).
    let musicAt: Int
    let sampleCount: Int
    /// The player's tables, as `StartMusic` copies them from the file to its `Base`, the samples' places
    /// made places in the memory (-1 for a sample that is not there).
    private let header: [UInt8]
    private let places: [Int]

    var songCount: Int { 1 }
    var song: Int { 0 }
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?

    /// A voice (16 bytes from `Base`+$1E2), its fields at their offsets: its envelope's speeds and level
    /// (0 to 3), its state (4: 0 rising, 1 falling to its level, 2 held, $64 dying away, $FF done), its
    /// volume (5), whether it is sounding (6), its height (7), its note's period (8), and its vibrato's
    /// ticks before it begins (10), depth (11), place in its wave (12) and speed (13).
    struct Voice {
        var attack: UInt8 = 0
        var decay: UInt8 = 0
        var sustain: UInt8 = 0
        var release: UInt8 = 0
        var state: UInt8 = 0
        var volume: UInt8 = 0
        var sounding: UInt8 = 0
        var peak: UInt8 = 0
        var period: UInt16 = 0
        var delay: UInt8 = 0
        var depth: UInt8 = 0
        var phase: UInt8 = 0
        var speed: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// Where the stream is read next (`$23C`), whether it is being read (`$248`), the ticks before it is
    /// (`$249`), the last event's kind (`$24A`) and each MIDI channel's program (`$24B`).
    private var pointer = 0
    private var playing = false
    private var wait: UInt8 = 1
    private var status: UInt8 = 0
    private var programs = InlineArray<16, UInt8>(repeating: 0)
    /// The ticks since the stream came to its end ($FF), while it has not stopped.
    private var sinceEnd = -1
    /// What each of Paula's period and volume registers was last given, and what they held as the tick
    /// just run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the waits.
    private var clock = 0

    /// How long each tick is: the player is run by EaglePlayer's timer (it has an interrupt and does not
    /// start one of its own), which UADE's runs on a CIA's timer from $376B (score.s,
    /// `cia_timer_base_value`), 70,940 of Paula's clocks.
    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in an hour is taken never to; one that has, but holds a note,
    /// has stopped five seconds after.
    private static let mostTicks = 50 * 60 * 60
    private static let heldTicks = 50 * 5
    /// How many bytes of its stream the player may read in a tick before it is taken to be reading it for
    /// ever; far more than any file has.
    private static let mostReads = 0x10000

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (the medians of its dumps of
    /// the game's music): where it begins to read the stream (a guess: only the distances between its
    /// writes are heard); the time an event that starts no note takes; how long after the player begins to
    /// read a note its sample is told; how long after the last event the envelopes begin; a voice's volume
    /// after its period; and the next voice's first write after the last of the one before (or, for one
    /// that writes nothing, after where it would have).
    static let firstWrite = 300
    static let eventClocks = 150
    static let noteClocks = 480
    static let effectsClocks = 120
    static let volumeClocks = 200
    static let voiceClocks = 190
    static let quietVoiceClocks = 40

    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's
    /// clocks) has changed nine times, the first at the next line's start; and some clocks for the code
    /// around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 147 - clock
    }

    /// The table of periods (`Periods`): six octaves, from note 48. A note outside them reads what is
    /// around the table in the player: before it its own tables (`MidiBytes`, `Bits`, `SinWave`) and
    /// the last of its channels' programs, after it its code (`IntBits`).
    static let periodTable: [UInt16] = [
        0x7F0, 0x780, 0x710, 0x6B0, 0x650, 0x5F0, 0x5A0, 0x550, 0x500, 0x4B0, 0x470, 0x430,
        0x3F8, 0x3C0, 0x388, 0x358, 0x328, 0x2F8, 0x2D0, 0x2A8, 0x280, 0x258, 0x238, 0x218,
        0x1FC, 0x1E0, 0x1C4, 0x1AC, 0x194, 0x17C, 0x168, 0x154, 0x140, 0x12C, 0x11C, 0x10C,
        0xFE, 0xF0, 0xE2, 0xD6, 0xCA, 0xBE, 0xB4, 0xAA, 0xA0, 0x96, 0x8E, 0x86,
        0x7F, 0x78, 0x71, 0x6B, 0x65, 0x5F, 0x5A, 0x55, 0x50, 0x4B, 0x47, 0x43,
        0x3F, 0x3C, 0x38, 0x35, 0x32, 0x2F, 0x2D, 0x2A, 0x28, 0x25, 0x23, 0x21,
        // (`IntBits`, assembled: BSR.W PlayRoutine, BSR.W NoteFX, RTS, and `PlayNote`'s first words.)
        0x6100, 0x0310, 0x6100, 0x0156, 0x4E75, 0x48E7, 0xFEFE, 0x4DFA,
    ]
    /// The vibrato's wave (`SinWave`), and the player's tables before the periods: `Bits` and
    /// `MidiBytes`, as words.
    static let sineWave: [UInt16] = [
        0, 1, 1, 2, 3, 4, 4, 5, 5, 4, 3, 2, 2, 1, 1, 0,
        0, 0, 0xFFFF, 0xFFFF, 0xFFFE, 0xFFFD, 0xFFFC, 0xFFFC, 0xFFFB, 0xFFFC, 0xFFFC, 0xFFFD, 0xFFFE, 0xFFFE, 0xFFFF, 0xFFFF,
    ]
    static let beforePeriods: [UInt16] = [0x0102, 0x0408, 0, 0, 0, 0, 0x0101, 0x0001, 0x0000, 0x0100]
    /// How many bytes follow each kind of event, by its top four bits, for the kinds the player reads none
    /// of itself (`MidiBytes`).
    static let midiBytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0]

    // MARK: - Reading

    @inline(__always) private static func byte(_ data: [UInt8], _ at: Int) -> UInt8 { at >= 0 && at < data.count ? data[at] : 0 }
    @inline(__always) private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        UInt32(byte(data, at)) << 24 | UInt32(byte(data, at + 1)) << 16 | UInt32(byte(data, at + 2)) << 8 | UInt32(byte(data, at + 3))
    }

    @inline(__always) private func headerByte(_ at: Int) -> UInt8 { at >= 0 && at < header.count ? header[at] : 0 }
    @inline(__always) private func headerLong(_ at: Int) -> UInt32 {
        UInt32(headerByte(at)) << 24 | UInt32(headerByte(at + 1)) << 16 | UInt32(headerByte(at + 2)) << 8 | UInt32(headerByte(at + 3))
    }

    /// The word of the period table at `index` (from note 48), or of what is around it.
    private func periodWord(_ index: Int) -> UInt16 {
        if index >= 0 { return index < Self.periodTable.count ? Self.periodTable[index] : 0 }
        let before = index + Self.beforePeriods.count
        if before >= 0 { return Self.beforePeriods[before] }
        let wave = before + Self.sineWave.count
        if wave >= 0 { return Self.sineWave[wave] }
        // (`Base`+$250 on: the programs of channels 5 to 15, and a nought.)
        let at = 2 * (wave + 6)
        let first = 5 + at, second = 6 + at
        return UInt16(first < 16 ? programs[first] : 0) << 8 | UInt16(second < 16 ? programs[second] : 0)
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): 'BANK', twenty places under 2M (the Amiga's
    /// largest chip memory) and forty lengths under 64K.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 4 + 60 * 4, Array(data[0 ..< 4]) == Array("BANK".utf8) else { return false }
        for i in 0 ..< 20 where long(data, 4 + 4 * i) >= 0x20_0000 { return false }
        for i in 0 ..< 40 where long(data, 0x54 + 4 * i) >= 0x1_0000 { return false }
        return true
    }

    /// Reads the file and starts its song. A file whose stream begins past its end, or that has no end
    /// ($FF and $2F), is refused, as `InitPlayer` refuses it.
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        // (`InitPlayer` clears the first long, the 'BANK', to be the silence of a sample without a loop.)
        for i in 0 ..< min(4, data.count) { memory[i] = 0 }
        header = (0 ..< 480).map { Self.byte(data, 4 + $0) }
        // The samples, each after its name, one after the other, from the end of the tables
        // (`StartMusic`, `InitPlayer`); and the stream after them.
        var at = 484
        var places: [Int] = []
        var count = 0
        for i in 0 ..< 20 {
            if Self.long(data, 4 + 4 * i) != 0 {
                places.append(at + 16)
                at += 16 + Int(Self.long(data, 0x54 + 4 * i))
                count += 1
            } else {
                places.append(-1)
            }
        }
        self.places = places
        sampleCount = count
        musicAt = at
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not an Andrew Parton module") }
        guard musicAt <= data.count else { throw .malformed("the module is cut short") }
        guard let end = data[musicAt...].firstIndex(of: 0xFF), end + 1 < data.count else {
            throw .malformed("the module is cut short")
        }
        guard data[end + 1] == 0x2F else { throw .malformed("the module's music has no end") }
        start()
        // The song's length, from a playing of it in silence to its end, or to its stopping.
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, stops == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it went round or stopped in is the first of it again, or silent.)
        lengthClocks = endings > 0 || stops > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        start()
    }

    deinit { memory.deallocate() }
}

// MARK: - Playing

extension AndrewPartonPlayer {
    mutating func select(song _: Int) throws(TuneError) { start() }

    /// `InitSound` and `StartMusic`: the stream from its start, read at the first tick, every voice
    /// silent. (The player clears none of its voices; they are as it was loaded.)
    private mutating func start() {
        voices = .init(repeating: Voice())
        pointer = musicAt + 1
        playing = true
        wait = 1
        status = 0
        programs = .init(repeating: 0)
        sinceEnd = -1
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = .init(repeating: 0)
        volumesBefore = .init(repeating: 0)
        clock = 0
        endings = 0
        stops = 0
    }

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }

    /// The player's interrupt (`IntBits`), for a tick: the stream read (`PlayRoutine`), and the voices'
    /// envelopes and vibratos moved (`NoteFX`). Returns the tick's length in milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        for v in 0 ..< 4 { volumesBefore[v] = min(64, volumes[v] & 0x7F) }
        var at = Self.firstWrite
        readStream(&at, &output)
        at += Self.effectsClocks
        effects(at: at, &output)
        clock += Self.tickClocks
        if sinceEnd >= 0 {
            sinceEnd += 1
            if (0 ..< 4).allSatisfy({ volumes[$0] == 0 }) || sinceEnd >= Self.heldTicks {
                // The stream has come to its end and every voice has died away: nothing more is heard.
                sinceEnd = -1
                stops += 1
                endings += 1
            }
        }
        return 20
    }

    /// `PlayRoutine`: once the ticks to wait are over, the stream's events, until one that is followed by
    /// a wait.
    private mutating func readStream<Output: TFMXOutput>(_ at: inout Int, _ output: inout Output) {
        guard playing else { return }
        wait &-= 1
        guard wait == 0 else { return }
        var p = pointer
        var reads = 0
        while true {
            reads += 1
            // (A stream read past the file, or for ever, has come to its end.)
            guard p < fileSize, reads < Self.mostReads else {
                comeToEnd()
                return
            }
            var data = byte(p)
            p += 1
            if data & 0x80 != 0 {
                status = data
                data = byte(p)
                p += 1
            }
            let kind = status & 0xF0
            if kind == 0x90 {
                let velocity = byte(p)
                p += 1
                if velocity == 0 {
                    release(Int(status & 3))
                    at += Self.eventClocks
                } else {
                    let program = Int(programs[Int(status & 15)] & 0x1F)
                    playNote(Int(status & 3), note: data, velocity: velocity, program: program, at: &at, &output)
                }
            } else if kind == 0x80 {
                p += 1
                release(Int(status & 3))
                at += Self.eventClocks
            } else if kind == 0xC0 {
                if data == 0x7E {
                    // Back to the start, read on at once: the song goes round.
                    p = musicAt + 2
                    endings += 1
                    continue
                }
                programs[Int(status & 15)] = data
                at += Self.eventClocks
            } else if status == 0xFF {
                // The end (`SongEnd`): the stream is read no more; the voices go on dying away.
                comeToEnd()
                at += Self.eventClocks
            } else if kind == 0xB0 {
                // (The player's `TST.B (A6)+` here would move its own base a byte along for the rest of the
                // tick; none of UnExoticA's files has the event, and that is not followed.)
                at += Self.eventClocks
            } else {
                if Self.midiBytes[Int(status >> 4)] != 0 { p += 1 }
                at += Self.eventClocks
            }
            guard p < fileSize else {
                comeToEnd()
                return
            }
            let delta = byte(p)
            p += 1
            if delta != 0 {
                wait = delta
                pointer = p
                return
            }
        }
    }

    private mutating func comeToEnd() {
        if playing, sinceEnd < 0 { sinceEnd = 0 }
        playing = false
    }

    /// `PlayNote` for a note of strength nought: the voice's note dies away.
    private mutating func release(_ v: Int) {
        voices[v].state = 0x64
    }

    /// `PlayNote`: a note on voice `v` of the program's sample, its envelope and vibrato from the start,
    /// its height half how hard it is struck (and for nought, the voice's note dies away instead); Paula's
    /// voice turned off, told the sample, its length and the period, after a wait turned on, and after
    /// another told the loop.
    private mutating func playNote<Output: TFMXOutput>(_ v: Int, note: UInt8, velocity: UInt8, program: Int,
                                                       at: inout Int, _ output: inout Output) {
        let height = (velocity & 0x7F) >> 1
        guard height != 0 else {
            release(v)
            at += Self.eventClocks
            return
        }
        let d3 = 4 * program
        var voice = voices[v]
        voice.peak = height
        voice.volume = 0
        voice.state = 0
        voice.sounding = 1
        voice.attack = headerByte(0x140 + d3)
        voice.decay = headerByte(0x141 + d3)
        voice.sustain = headerByte(0x142 + d3)
        voice.release = headerByte(0x143 + d3)
        voice.delay = headerByte(0x190 + d3)
        voice.depth = headerByte(0x191 + d3)
        voice.speed = headerByte(0x192 + d3)
        voice.phase = 0
        voice.sustain = UInt8(truncatingIfNeeded: (UInt16(voice.sustain) * UInt16(height)) >> 6)
        let length = UInt16(truncatingIfNeeded: headerLong(0x50 + d3)) >> 1
        // (A program of 20 or more, which none of the files has, names no sample here.)
        let place = program < 20 && places[program] >= 0 ? places[program] : silenceAt
        let period = periodWord(Int(note & 0x7F) - 0x30)
        voice.period = period
        voices[v] = voice
        periods[v] = period
        let told = at + Self.noteClocks
        output.timed(at: told)
        output.off(v)
        output.takeNextBuffer(v, start: place, length: length)
        output.writePeriod(v, period)
        let on = afterWait(told)
        output.timed(at: on)
        output.on(v)
        let looped = afterWait(on)
        output.timed(at: looped)
        let loopLength = headerLong(0xA0 + d3)
        if loopLength != 0 {
            let loop = place == silenceAt ? silenceAt : place + Int(headerLong(0xF0 + d3) & 0x1F_FFFF)
            output.takeNextBuffer(v, start: loop, length: UInt16(truncatingIfNeeded: loopLength) >> 1)
        } else {
            output.takeNextBuffer(v, start: 0, length: 2)
        }
        at = looped
    }

    /// `NoteFX`: each voice's vibrato, once its ticks before it are over, bending its note's period; and
    /// its envelope, rising to its height, falling (or rising) to its level and held there, or dying away;
    /// each told Paula as it is moved. (Its bytes are compared with their signs, as the player's are.)
    private mutating func effects<Output: TFMXOutput>(at start: Int, _ output: inout Output) {
        var at = start
        for v in 0 ..< 4 {
            var voice = voices[v]
            var writes = false
            if voice.delay != 0 {
                voice.delay &-= 1
            } else {
                // (`MULU`: the wave's word, taken without its sign, and the period added to the low word.)
                let bent = UInt32(Self.sineWave[Int(voice.phase & 0x1F)]) &* UInt32(voice.depth)
                periods[v] = UInt16(truncatingIfNeeded: bent) &+ voice.period
                output.timed(at: at)
                output.writePeriod(v, periods[v])
                writes = true
                voice.phase = (voice.phase &+ voice.speed) & 0x1F
            }
            var put = false
            switch voice.state {
            case 0:
                voice.volume &+= voice.attack
                if Int8(bitPattern: voice.volume) > 0x3F { voice.volume = 0x3F }
                if Int8(bitPattern: voice.peak) <= Int8(bitPattern: voice.volume) {
                    voice.state &+= 1
                    voice.volume = voice.peak
                }
                put = true
            case 1:
                let level = Int8(bitPattern: voice.sustain)
                if voice.sustain == voice.volume {
                    voice.state &+= 1
                } else if level > Int8(bitPattern: voice.volume) {
                    voice.volume &+= voice.decay
                    if level <= Int8(bitPattern: voice.volume) { voice.volume = voice.sustain }
                    put = true
                } else {
                    voice.volume &-= voice.decay
                    if Int8(bitPattern: voice.volume) < 0 { voice.volume = 0 }
                    if level >= Int8(bitPattern: voice.volume) { voice.volume = voice.sustain }
                    put = true
                }
            case 0x64:
                voice.volume &-= voice.release
                if Int8(bitPattern: voice.volume) < 0 { voice.volume = 0 }
                if voice.volume == 0 {
                    voice.state = 0xFF
                    voice.sounding = 0
                }
                put = true
            default:
                break
            }
            var last = at
            if put {
                volumes[v] = UInt16(voice.volume & 0x3F)
                if writes { last += Self.volumeClocks }
                output.timed(at: last)
                output.writeVolume(v, volumes[v])
            }
            voices[v] = voice
            at = writes || put ? last + Self.voiceClocks : at + Self.quietVoiceClocks
        }
    }

    /// Paula's period for the voice as the tick just run began (its writes in the tick are told at their
    /// moments).
    func period(_ voice: Int) -> UInt16 { periodsBefore[voice] }
    /// Paula's volume for the voice as the tick just run began.
    func volume(_ voice: Int) -> UInt16 { volumesBefore[voice] }
    /// What the player last gave Paula's period register for the voice.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Andrew Parton's music, played on Paula by `PaulaTickRenderer`.
extension AndrewPartonPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Andrew Parton")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Andrew Parton's music for B-17 Flying Fortress, the game's own replayer; \(sampleCount) sample\(plural)"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
