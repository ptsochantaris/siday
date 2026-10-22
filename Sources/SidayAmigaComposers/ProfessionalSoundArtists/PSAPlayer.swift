// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the replay routine of Professional Sound Artists (as the game The Punisher carries it), as Wanted
// Team adapted it for EaglePlayer ("Professional Sound Artists player module V1.1 (21 Apr 2003)"), carried by
// UADE as players/ProfessionalSoundArtists, whose source UADE also carries as
// amigasrc/players/wanted_team/PSA/PSA_v2.asm. The labels given are that source's.

import SidayChips
import SidayFoundation

/// Professional Sound Artists' music (UnExoticA's file says "By Steve/PSA"; Wanted Team's player credits Dave
/// "Sinbad" Hasler), of which UnExoticA has The Punisher's: a file that begins "PSA" and a nought, a name, its
/// length, and from byte 40 the places of its instruments, its list of patterns and its patterns; and from byte 56
/// its songs, eight bytes each (the places in the list, in bytes, of its first pattern, of the one after its last,
/// and of the one it goes back to, or $FFFF for none).
///
/// A pattern is 64 rows of four voices' four bytes: a note (nought for none, else one of three octaves), an
/// instrument, an effect and its value. An effect with its top bit set has its note played on without its
/// instrument begun again; the effects are 0 an arpeggio, 1 and 2 a slide, 3 a slide to the note, 4 a vibrato, 5
/// the envelope's held part let go, 10 a slide of the volume, 12 the volume, 13 the pattern's end and 15 the speed.
/// An instrument is 64 bytes: its sample and its length, its loop, its volume, whether it is one of the player's
/// waves (a square of 256 bytes of $80 and 256 of $7F, whose start moves up and down for its width, as many steps
/// of so many bytes every so many ticks each way), its envelope (up so many times by so much every so many ticks,
/// down likewise, held for so many ticks or until let go, and down again) and its name.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`), and so is run by
/// EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second and a
/// little less. On every tick the speed's count comes down, and below nought the row is read (its notes begun with
/// their voices turned off); the effects move the periods and volumes of all four voices, the waves' starts move
/// and the envelopes the volumes; and once `DMAWait` has waited for the beam to begin nine lines (of 227 of Paula's
/// clocks), the voices of the notes begun are turned on, and after nine lines more their samples' loops are told.
/// (The game's own player did these last in the interrupt of a CIA's timer, which it started as it read the row;
/// Wanted Team's waits instead.) Each of its writes is told Paula at its moment in the tick
/// (`TFMXOutput.timed(at:)`), near where it falls in UADE's dumps.
///
/// A song comes to its end at its last pattern's end, and is said to have done so as it begins again; one that goes
/// back to none stops once its last row has had its ticks (the player stops at once, but the notes of that row go
/// on sounding). Where the player would read past the file it reads nought, and a note past its table of periods
/// has the period nought; where it would read its own memory before or after its waves (an instrument of a wave
/// longer than 128 words), it reads silence.
struct PSAPlayer: ~Copyable {
    /// The file, the player's waves and what follows them, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the player's four bytes of noughts (`Empty`), just after its
    /// waves, and noughts after them.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048
    /// Where the second half of the player's square (`lbL0009AC`, 256 bytes of $7F after 256 of $80) is.
    let squareAt: Int

    private let fileSize: Int
    /// Where the instruments, the list of patterns and the patterns are (`$24`, `$28` and `$2C` of the player's
    /// variables, from bytes 40, 44 and 48).
    private let instruments: Int
    private let positions: Int
    private let patterns: Int
    let songCount: Int
    private(set) var song = 0
    /// How many instruments it has, and of them how many are the player's waves (as `InitPlayer` counts them,
    /// from the places of the instruments and the list, those whose sample's place is nought).
    let instrumentCount: Int
    let syntheticCount: Int
    let title: String

    /// What the player keeps for each voice (`lbL0006F2` and the three after it, 92 bytes each).
    private struct Voice {
        /// Where its loop is (byte 0; for a wave, where the wave begins for its length), the loop's length in
        /// words (4), its period (6), its note (8, from nought), the step and goal of its slide to a note (10,
        /// 12), and its volume (14).
        var loopPlace = 0
        var loopLength: UInt16 = 0
        var period: UInt16 = 0
        var note: UInt16 = 0
        var slide: UInt16 = 0
        var target: UInt16 = 0
        var volume: UInt16 = 0
        /// The vibrato (16 to 21): its step, how far it has gone, and its count of ticks and every how many.
        var vibratoStep: UInt16 = 0
        var vibrato: UInt16 = 0
        var vibratoCount: UInt8 = 0
        var vibratoEvery: UInt8 = 0
        /// The wave (22 to 32, from the instrument's bytes 14 to 21): whether it is one, how far into the
        /// square it starts, its steps up and down, every how many ticks and how many times; its counts, and
        /// which way it is going.
        var synth: UInt8 = 0
        var synthOffset: UInt8 = 0
        var upStep: UInt8 = 0
        var upDelay: UInt8 = 0
        var upCount: UInt8 = 0
        var downStep: UInt8 = 0
        var downDelay: UInt8 = 0
        var downCount: UInt8 = 0
        var synthCount: UInt8 = 0
        var synthDelay: UInt8 = 0
        var synthDown: UInt8 = 0
        /// The envelope (33 to 44, from the instrument's bytes 22 to 32): its count of ticks and its part (1 up,
        /// 2 down, 3 held, any other down again, nought done); for each part its step, every how many ticks and
        /// how many times; and how many ticks it is held (nought for until it is let go).
        var envelopeDelay: UInt8 = 0
        var envelope: UInt8 = 0
        var attackStep: UInt8 = 0
        var attackDelay: UInt8 = 0
        var attackCount: UInt8 = 0
        var decayStep: UInt8 = 0
        var decayDelay: UInt8 = 0
        var decayCount: UInt8 = 0
        var sustain: UInt8 = 0
        var releaseStep: UInt8 = 0
        var releaseDelay: UInt8 = 0
        var releaseCount: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The player's variables (`lbL0006C2`): whether it is playing, the speed's count and the speed, the row, the
    /// place in the list (in bytes) and the song's three, where the next row and the row read last are, the
    /// voices to be turned on, the count of ticks in three that the arpeggios go by, and the voices whose loops
    /// are to be told.
    private var playing = false
    private var counter: UInt8 = 0
    private var speed: UInt8 = 6
    private var row: UInt8 = 0
    private var position: UInt16 = 0
    private var first: UInt16 = 0
    private var last: UInt16 = 0
    private var restart: UInt16 = 0
    private var next = 0
    private var current = 0
    private var turnOn: UInt16 = 0
    private var phase: UInt8 = 0
    private var loopDue: UInt16 = 0
    /// Whether the song has come to its end (`SongEnd`) and not yet begun again; whether the player has stopped
    /// and its last row not yet had its ticks.
    private var ending = false
    private var stopping = false

    /// Paula's location and length registers, as last written; and what each of her period and volume registers
    /// was last given, and what they held as the tick just run began (what `PaulaTickRenderer` sets Paula to
    /// then, before the tick's writes are told at their moments).
    private var places = InlineArray<4, Int>(repeating: 0)
    private var lengths = InlineArray<4, UInt16>(repeating: 0)
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the waits.
    private var clock = 0

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// Each song's length, found as the player is made.
    private var songLengths: [UInt64?] = []

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to; and once the songs played through
    /// to find their lengths have taken four hours in all, the rest are too (only a broken file has so many
    /// songs that never end).
    private static let mostTicks = 50 * 60 * 60
    private static let mostTicksInAll = 4 * mostTicks

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (near the medians of its dumps): the
    /// first after the interrupt begins (a guess: only the distances between them are heard); for the row, how
    /// long a voice with no note takes, and one with a note to its sample, its volume and its period; for the
    /// effects, how long a voice's takes, its wave's start and its envelope; and the turning on and each loop.
    static let firstWrite = 300
    static let quietRowClocks = 160
    static let sampleClocks = 160
    static let volumeClocks = 70
    static let noteClocks = 170
    static let effectClocks = 180
    static let waveClocks = 120
    static let envelopeClocks = 60
    static let onClocks = 40
    static let loopClocks = 40

    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's clocks) has
    /// changed nine times, the first at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 80 - clock
    }

    /// The table of periods (`lbL000862`): three octaves, ProTracker's, and $6B.
    static let periodTable: [UInt16] = [
        0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC, 0x1E0, 0x1C5,
        0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0, 0x0E2,
        0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0x078, 0x071,
        0x06B,
    ]

    /// The period of a note from nought (a word, doubled as a word and taken as a signed offset into the table);
    /// nought for one past it, where the player would read what follows its table.
    private static func period(_ note: UInt16) -> UInt16 {
        let index = Int(Int16(bitPattern: note &<< 1)) / 2
        return index >= 0 && index < periodTable.count ? periodTable[index] : 0
    }

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: Int) -> Int {
        Int(Int32(bitPattern: UInt32(word(at)) << 16 | UInt32(word(at &+ 2))))
    }

    private static func long(_ data: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at + 3 < data.count else { return 0 }
        return Int(Int32(bitPattern: UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])))
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): "PSA" and a nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 4 && data[0] == 0x50 && data[1] == 0x53 && data[2] == 0x41 && data[3] == 0
    }

    /// Reads the file and starts the song asked for (of `songCount`, nought the first).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        fileSize = data.count
        // (The player's square after room for what it would read before it, and its four bytes of noughts.)
        squareAt = ((data.count + 15) & ~15) + 0x8000 + 256
        silenceAt = squareAt + 256
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        for i in 0 ..< 256 {
            memory[squareAt - 256 + i] = 0x80
            memory[squareAt + i] = 0x7F
        }
        instruments = Self.long(data, 40)
        positions = Self.long(data, 44)
        patterns = Self.long(data, 48)
        // (`InitPlayer`: the songs, from the instruments' place; the instruments, from theirs to the list's.)
        songCount = max(1, min(256, (Self.long(data, 40) - 56) / 8))
        let count = max(0, min(1024, (Self.long(data, 44) - Self.long(data, 40)) / 64))
        var synthetic = 0
        for i in 0 ..< count where Self.long(data, instruments + 64 * i) == 0 { synthetic += 1 }
        instrumentCount = count
        syntheticCount = synthetic
        var name = ""
        for b in data.dropFirst(4).prefix(32) where b >= 0x20 && b < 0x7F { name.unicodeScalars.append(Unicode.Scalar(b)) }
        while name.hasSuffix(" ") { name.removeLast() }
        title = name
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Professional Sound Artists file") }
        guard data.count >= 56 + 8 * songCount else { throw .malformed("too short for its songs") }

        // Each song's length, from a playing of it in silence to its end.
        var budget = Self.mostTicksInAll
        for s in 0 ..< songCount {
            self.song = s
            start()
            var none = TFMXSilentOutput()
            var ticks = 0
            while endings == 0, ticks < min(Self.mostTicks, budget) {
                _ = run(&none)
                ticks += 1
            }
            budget -= ticks
            // (The tick it came to its end in is the first of it again, or one not heard.)
            songLengths.append(endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil)
        }
        self.song = max(0, min(songCount - 1, song))
        lengthClocks = songLengths[self.song]
        start()
    }

    deinit { memory.deallocate() }

    /// `InitSound` and `Init`: the song's places in the list, and its first pattern to be read on the first tick.
    private mutating func start() {
        voices = .init(repeating: Voice())
        speed = 6
        counter = 0
        playing = true
        let entry = 56 + 8 * song
        first = word(entry)
        last = word(entry + 2)
        restart = word(entry + 4)
        position = first
        next = patterns &+ Int(word(positions &+ Int(Int16(bitPattern: position)))) &* 1024
        current = next
        row = 0
        turnOn = 0
        loopDue = 0
        phase = 0
        ending = false
        stopping = false
        places = .init(repeating: 0)
        lengths = .init(repeating: 0)
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = periods
        volumesBefore = volumes
        clock = 0
        endings = 0
        stops = 0
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        lengthClocks = songLengths[song]
        start()
    }

    private mutating func writePeriod<Output: TFMXOutput>(_ v: Int, _ period: UInt16, _ output: inout Output) {
        periods[v] = period
        output.writePeriod(v, period)
    }

    /// `PSA_SetVoices`: seven bits, times EaglePlayer's volume, 64, over 64.
    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume & 0x7F
        output.writeVolume(v, volumes[v])
    }

    /// The voice's volume set (as byte 14) and told Paula.
    private mutating func setVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        voices[v].volume = volume
        writeVolume(v, volume, &output)
    }

    /// `SetAdr` and `SetLen`: Paula's location and length registers.
    private mutating func place<Output: TFMXOutput>(_ v: Int, _ place: Int, _ length: UInt16, _ output: inout Output) {
        places[v] = place
        lengths[v] = length
        output.takeNextBuffer(v, start: place, length: length)
    }

    /// Runs the player for a tick (`Interrupt`), telling `output` what Paula is to do, in the order the player
    /// tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        var at = Self.firstWrite
        if playing {
            // `Play_1`: the row, when the speed's count comes below nought, and every voice's effects.
            counter &-= 1
            if Int8(bitPattern: counter) < 0 { readRow(&output, &at) }
            phase &+= 1
            if phase == 3 { phase = 0 }
            for v in 0 ..< 4 { effects(v, &output, &at) }
        } else if stopping {
            // (Stopped: once the last row has had its ticks, as the speed's count would have counted them.)
            counter &-= 1
            if Int8(bitPattern: counter) < 0 {
                stopping = false
                endings += 1
                stops += 1
            }
        }
        // `DMAWait`, and `Play_2`: the voices of the notes begun turned on, the wait again, and their loops told.
        at = afterWait(at)
        if turnOn != 0 {
            output.timed(at: at)
            for v in 0 ..< 4 where turnOn & 1 << UInt16(v) != 0 { output.on(v) }
            turnOn = 0
        }
        at = afterWait(at + Self.onClocks)
        for v in 0 ..< 4 where loopDue & 1 << UInt16(v) != 0 {
            output.timed(at: at)
            place(v, voices[v].loopPlace, voices[v].loopLength, &output)
            at += Self.loopClocks
        }
        loopDue = 0
        // (Kept within a whole number of the beam's lines, of 227 clocks and of 227.5, which is all the
        // waits ask of it: a count of every clock would outgrow a whole number in a browser.)
        clock = (clock + Self.tickClocks) % 103_285
        return 20
    }

    /// `lbC000254`: the row read for the four voices, and the next one found (`SetPosition`).
    private mutating func readRow<Output: TFMXOutput>(_ output: inout Output, _ at: inout Int) {
        if ending {
            ending = false
            endings += 1
        }
        current = next
        for v in 0 ..< 4 where rowVoice(v, current &+ 4 * v, &output, &at) { loopDue |= 1 << UInt16(v) }
        row = (row &+ 1) & 0x3F
        var after = current &+ 16
        if row == 0 {
            var place = position &+ 2
            if place == last {
                ending = true
                place = restart
                if place == 0xFFFF {
                    // (`lbC000192`: the player stopped, its voices turned off and their volumes nought.)
                    ending = false
                    playing = false
                    stopping = true
                    output.timed(at: at)
                    for v in 0 ..< 4 {
                        output.off(v)
                        writeVolume(v, 0, &output)
                    }
                    next = after
                    counter = speed
                    return
                }
            }
            position = place
            after = patterns &+ Int(word(positions &+ Int(Int16(bitPattern: place)))) &* 1024
        }
        next = after
        counter = speed
    }

    /// `lbC0002F2`: a voice's four bytes of the row. True for a voice whose loop is to be told after it is turned
    /// on (a sample's note begun).
    private mutating func rowVoice<Output: TFMXOutput>(_ v: Int, _ from: Int, _ output: inout Output, _ at: inout Int) -> Bool {
        let note = byte(from)
        let number = byte(from &+ 1)
        let effect = byte(from &+ 2)
        let value = byte(from &+ 3)
        var sample = false
        if note != 0 {
            if effect == 3 {
                // A slide to the note: its period the goal, the step the value, down or up to it.
                let target = Self.period(UInt16(note) &- 1)
                voices[v].target = target
                voices[v].slide = Int16(bitPattern: target &- voices[v].period) >= 0 ? 0 &- UInt16(value) : UInt16(value)
                at += Self.quietRowClocks
                return false
            }
            if Int8(bitPattern: effect) >= 0 {
                // A note begun (`lbC000338`): its voice turned off, to be turned on at the tick's end; its
                // instrument's wave or sample, volume, loop, envelope.
                output.timed(at: at)
                output.off(v)
                turnOn |= 1 << UInt16(v)
                let instrument = instruments &+ Int(number) * 64
                voices[v].envelopeDelay = 1
                voices[v].envelope = byte(instrument &+ 22)
                voices[v].attackStep = byte(instrument &+ 23)
                voices[v].attackDelay = byte(instrument &+ 24)
                voices[v].attackCount = byte(instrument &+ 25)
                voices[v].decayStep = byte(instrument &+ 26)
                voices[v].decayDelay = byte(instrument &+ 27)
                voices[v].decayCount = byte(instrument &+ 28)
                voices[v].sustain = byte(instrument &+ 29)
                voices[v].releaseStep = byte(instrument &+ 30)
                voices[v].releaseDelay = byte(instrument &+ 31)
                voices[v].releaseCount = byte(instrument &+ 32)
                voices[v].synth = byte(instrument &+ 14)
                voices[v].synthOffset = byte(instrument &+ 15)
                voices[v].upStep = byte(instrument &+ 16)
                voices[v].upDelay = byte(instrument &+ 17)
                voices[v].upCount = byte(instrument &+ 18)
                voices[v].downStep = byte(instrument &+ 19)
                voices[v].downDelay = byte(instrument &+ 20)
                voices[v].downCount = byte(instrument &+ 21)
                let length = word(instrument &+ 4)
                at += Self.sampleClocks
                output.timed(at: at)
                if voices[v].synth != 0 {
                    // The player's square, from as far before its middle as twice its length (a word, doubled as
                    // a word and taken as a signed one), and as far into it as the instrument says.
                    voices[v].synthDown = 0
                    voices[v].synthDelay = voices[v].upDelay
                    voices[v].synthCount = voices[v].upCount
                    let wave = squareAt - Int(Int16(bitPattern: length &<< 1))
                    voices[v].loopPlace = wave
                    place(v, wave + Int(voices[v].synthOffset), length, &output)
                    at += Self.volumeClocks
                    output.timed(at: at)
                    setVolume(v, effect == 12 ? UInt16(value) : word(instrument &+ 12), &output)
                } else {
                    sample = true
                    place(v, long(instrument), length, &output)
                    at += Self.volumeClocks
                    output.timed(at: at)
                    setVolume(v, effect == 12 ? UInt16(value) : word(instrument &+ 12), &output)
                    let loop = long(instrument &+ 6)
                    voices[v].loopPlace = loop == 0 ? silenceAt : loop
                }
                voices[v].loopLength = word(instrument &+ 10)
            }
            // The note's period (`lbC000418`).
            voices[v].note = UInt16(note) &- 1
            let period = Self.period(voices[v].note)
            at += Self.noteClocks
            output.timed(at: at)
            writePeriod(v, period, &output)
            voices[v].period = period
        } else {
            at += Self.quietRowClocks
        }
        // The effects of the row (`lbC00042C`).
        switch effect {
        case 5:
            voices[v].sustain = 1
        default:
            break
        }
        switch effect {
        case 12:
            output.timed(at: at)
            setVolume(v, UInt16(value), &output)
        case 13:
            row = 0x3F
        case 15:
            speed = value
        default:
            break
        }
        return sample
    }

    /// `lbC000464`: a voice's effect on the tick, its wave's start moved (`lbC0005D4`) and its envelope
    /// (`lbC00062E`).
    private mutating func effects<Output: TFMXOutput>(_ v: Int, _ output: inout Output, _ at: inout Int) {
        let effect = byte(current &+ 4 * v &+ 2) & 0x7F
        let value = byte(current &+ 4 * v &+ 3)
        output.timed(at: at)
        if value != 0, effect == 0 {
            // An arpeggio: the note, and the notes the value's two halves above it, a tick each.
            if phase == 0 {
                writePeriod(v, voices[v].period, &output)
            } else {
                let add = phase == 2 ? value & 15 : value >> 4
                writePeriod(v, Self.period(voices[v].note &+ UInt16(add)), &output)
            }
        } else if effect == 4 {
            // A vibrato, its step and its depth taken on the row's first tick.
            if counter == speed, value != 0 {
                voices[v].vibratoStep = UInt16(value >> 4)
                voices[v].vibratoCount = value & 15
                voices[v].vibratoEvery = (value & 15) &<< 1
                voices[v].vibrato = 0
            }
            voices[v].vibrato &+= voices[v].vibratoStep
            writePeriod(v, voices[v].vibrato &+ voices[v].period, &output)
            voices[v].vibratoCount &-= 1
            if voices[v].vibratoCount == 0 {
                voices[v].vibratoCount = voices[v].vibratoEvery
                voices[v].vibratoStep = 0 &- voices[v].vibratoStep
            }
        } else {
            writePeriod(v, voices[v].period, &output)
            switch effect {
            case 10:
                // A slide of the volume: down by the value's seven bits, to nought; or up by it, its low byte
                // made $40 if it is from $40 to $BF.
                var volume: UInt16
                if value & 0x80 != 0 {
                    volume = voices[v].volume &- UInt16(value & 0x7F)
                    if Int16(bitPattern: volume) < 0 { volume = 0 }
                } else {
                    volume = voices[v].volume &+ UInt16(value)
                    if Int8(bitPattern: UInt8(truncatingIfNeeded: volume) &- 0x40) >= 0 { volume = volume & 0xFF00 | 0x40 }
                }
                setVolume(v, volume, &output)
            case 1:
                voices[v].period &-= UInt16(value)
                writePeriod(v, voices[v].period, &output)
            case 2:
                voices[v].period &+= UInt16(value)
                writePeriod(v, voices[v].period, &output)
            case 3:
                // A slide to its goal, and at it no further.
                let step = voices[v].slide
                if step != 0 {
                    let period = voices[v].period &- step
                    let short = Int16(bitPattern: period &- voices[v].target) < 0
                    if Int16(bitPattern: step) < 0 ? short : !short {
                        writePeriod(v, period, &output)
                        voices[v].period = period
                    } else {
                        writePeriod(v, voices[v].target, &output)
                        voices[v].period = voices[v].target
                        voices[v].slide = 0
                    }
                }
            default:
                break
            }
        }
        at += Self.effectClocks
        if voices[v].synth != 0 {
            voices[v].synthDelay &-= 1
            if voices[v].synthDelay == 0 {
                var offset = voices[v].synthOffset
                if voices[v].synthDown == 0 {
                    voices[v].synthDelay = voices[v].upDelay
                    offset &+= voices[v].upStep
                    voices[v].synthCount &-= 1
                    if voices[v].synthCount == 0 {
                        voices[v].synthCount = voices[v].downCount
                        voices[v].synthDown = ~voices[v].synthDown
                    }
                } else {
                    voices[v].synthDelay = voices[v].downDelay
                    offset &-= voices[v].downStep
                    voices[v].synthCount &-= 1
                    if voices[v].synthCount == 0 {
                        voices[v].synthCount = voices[v].upCount
                        voices[v].synthDown = ~voices[v].synthDown
                    }
                }
                voices[v].synthOffset = offset
                // (Only Paula's location: her length is as it was.)
                output.timed(at: at)
                place(v, voices[v].loopPlace + Int(offset), lengths[v], &output)
                at += Self.waveClocks
            }
        }
        envelope(v, &output, &at)
    }

    /// `lbC00062E`: the voice's envelope, every so many ticks: up, down, held, and down again.
    private mutating func envelope<Output: TFMXOutput>(_ v: Int, _ output: inout Output, _ at: inout Int) {
        let part = voices[v].envelope
        guard part != 0 else { return }
        voices[v].envelopeDelay &-= 1
        guard voices[v].envelopeDelay == 0 else { return }
        // (Its steps on the volume's low byte.)
        var volume = voices[v].volume
        func low(_ step: UInt8, up: Bool) {
            let byte = UInt8(truncatingIfNeeded: volume)
            volume = volume & 0xFF00 | UInt16(up ? byte &+ step : byte &- step)
        }
        switch part {
        case 1:
            voices[v].envelopeDelay = voices[v].attackDelay
            low(voices[v].attackStep, up: true)
            voices[v].attackCount &-= 1
            if voices[v].attackCount == 0 { voices[v].envelope &+= 1 }
        case 2:
            voices[v].envelopeDelay = voices[v].decayDelay
            low(voices[v].decayStep, up: false)
            voices[v].decayCount &-= 1
            if voices[v].decayCount == 0 { voices[v].envelope &+= 1 }
        case 3:
            // Held: until let go (by effect 5), or for as many ticks as it says; the volume not told.
            voices[v].envelopeDelay = 1
            if voices[v].sustain != 0 {
                voices[v].sustain &-= 1
                if voices[v].sustain == 0 { voices[v].envelope &+= 1 }
            }
            return
        default:
            voices[v].envelopeDelay = voices[v].releaseDelay
            low(voices[v].releaseStep, up: false)
            voices[v].releaseCount &-= 1
            if voices[v].releaseCount == 0 { voices[v].envelope = 0 }
        }
        if Int8(bitPattern: UInt8(truncatingIfNeeded: volume)) < 0 { volume = 0 }
        output.timed(at: at)
        setVolume(v, volume, &output)
        at += Self.envelopeClocks
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

/// Professional Sound Artists' music, played on Paula by `PaulaTickRenderer`.
extension PSAPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Professional Sound Artists")
        info.title = title
        let samples = instrumentCount - syntheticCount
        info.detail = "\(samples) sampled instrument\(samples == 1 ? "" : "s"), \(syntheticCount) of the player's waves"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 its one file is -19.8 dB.)
    var gain: Float { 0.28 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
