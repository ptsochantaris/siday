// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after N.J. Luuring jr's "PLAY - module for Packed TME song-files" (1/1/90), the replay routine of The
// Musical Enlightenment, as Wanted Team adapted it for EaglePlayer ("The Musical Enlightenment 2.0 player module
// V1.2 (17 Feb 2002)"), carried by UADE as players/TheMusicalEnlightenment, whose source UADE also carries as
// amigasrc/players/wanted_team/TME/src/TME_v3.s. The labels given are that source's.

import SidayChips
import SidayFoundation

/// The Musical Enlightenment, N.J. Luuring jr's editor (1989 and 1990), whose music for Labyrinth is among
/// UnExoticA's: a file of a fixed head (its length; sixteen tunes, each its first entry, the one after its last,
/// its speed and its voices; 32 instruments of 128 bytes; 64 arpeggios of nine bytes; sixteen waves of 128 for the
/// vibratos and tremolos; how many entries, events and instructions it has, and its name), then its table of
/// entries, its events, its lists of instructions and its samples.
///
/// An entry is a track for each voice, with an instrument and a note to be added to the track's; a track is 32
/// events of six bytes: a note (nought for none, 127 its voice turned off, 126 its envelope let go; with its top
/// bit set it is played on, not begun again), an instrument, a list of instructions (nought for the instrument's
/// own), a volume to be added, flags (an arpeggio, played once or begun again with every note of it; a slide by a
/// step, or to the note after, which is then not played; the entry's instrument or note not added) and a value for
/// them. An instrument is its sample (its length, the part of it played first, and its loop), its name (none for no
/// sample), its volume, an envelope of three parts (each so many ticks to a level, and held after the second) and
/// its own list of instructions. The instructions, read to one that waits, set where the vibrato and the tremolo go
/// to (in so many ticks, and on which of the waves) and how fast, or wait so many ticks, or go to another list, or
/// end.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`, its author's vertical blank),
/// and so is run by EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty
/// times a second and a little less. On every tick the voices of the notes begun on the tick before are turned on,
/// and `DMAWait` waits for the beam to begin nine lines (of 227 of Paula's clocks); every so many ticks the next
/// event of each voice is read (its note begun with its voice turned off), the lists of instructions are walked,
/// the periods and volumes are made, and Paula is told the place, length, period and volume of each of the tune's
/// voices. Each of its writes is told Paula at its moment in the tick (`TFMXOutput.timed(at:)`), near where it
/// falls in UADE's dumps. A tune whose voices' byte has its fifth bit clear has the Amiga's filter on.
///
/// A tune comes to its end as its last entry ends, and is said to have done so as it begins again. Where the player
/// would read past the file it reads nought, and a note past its table of periods has one of the three words after
/// it or nought (and so the least period, 113); an instrument without a sample (without a name) is played from
/// silence, where its place (nought) would be in the Amiga's own memory; an instruction the player does not know
/// (it would jump into its own code), or a list of them that goes round without waiting (it would never return),
/// ends its list.
struct TMEPlayer: ~Copyable {
    /// The file, and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: noughts after the file.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where the table of entries (`tableentry`), the events (`event`) and each of the 256 lists of instructions
    /// (`fx`) are.
    private let entries: Int
    private let events: Int
    private var lists = [Int](repeating: 0, count: 256)
    let songCount: Int
    private(set) var song = 0
    /// How many of its instruments have samples (names), and its name.
    let sampleCount: Int
    let title: String

    /// The places of the parts of the head (`song_instr`, `song_arpeggio`, `song_lfo`).
    static let instrumentsAt = 68
    static let arpeggiosAt = 4164
    static let wavesAt = 4740

    /// A vibrato's or a tremolo's working (`fxda_`): the period or volume it moves (from) and has made (to); where
    /// its level and speed are going and are; where it is in its wave; how many ticks its level and its speed
    /// have to go; and its wave.
    private struct Effect {
        var from: UInt16 = 0
        var to: UInt16 = 0
        var toLevel: UInt8 = 0
        var level: UInt8 = 0
        var toSpeed: UInt8 = 0
        var speed: UInt8 = 0
        var pointer = 0
        var levelCount: UInt16 = 0
        var speedCount: UInt16 = 0
        var wave = 0
    }

    /// What the player keeps for each voice (`voice`, `voic_SIZE` each).
    private struct Voice {
        /// What Paula is to be told of it (`voic_shadow`): its place, length, period and volume.
        var place = 0
        var length: UInt16 = 0
        var shadowPeriod: UInt16 = 0
        var shadowVolume: UInt16 = 0
        var vibrato = Effect()
        var tremolo = Effect()
        /// The "special" one, set by its instructions but used for nothing.
        var special = Effect()
        /// Its instrument (nought for none yet), its next event, its list of instructions, and the entry's adds
        /// (`voic_add`: the instrument's, then the note's).
        var instrument = 0
        var event = 0
        var instructions = 0
        var adds = 0
        /// The envelope's part (0 up, 1 down, 2 let go, 3 held), the sample's (2 to begin, 1 its loop, 0 done),
        /// where the arpeggio is, the count of ticks of the list of instructions and of the slide to a note.
        var egPhase: UInt16 = 0
        var startPhase: UInt16 = 0
        var arpAt: UInt16 = 0
        var fxCount: UInt16 = 0
        var glideCount: UInt32 = 0
        var egCount: UInt32 = 0
        var toPeriod: UInt16 = 0
        var egVolume: UInt16 = 0
        var baseVolume: UInt16 = 0
        var egToVolume: UInt16 = 0
        var glideAdd: UInt16 = 0
        var dma: UInt16 = 0
        /// The arpeggio: where its notes are, how many, and its flags and counts.
        var arpeggio = 0
        var arpLength: UInt16 = 0
        var noUse: UInt8 = 0
        var doArpeggio: UInt8 = 0
        var arpBlow: UInt8 = 0
        var waitForFx: UInt8 = 0
        var baseArpNote: UInt8 = 0
        var arpCount: UInt8 = 0
        var arpOnce: UInt8 = 0
        var arpSpeed: UInt8 = 0

        /// The vibrato, the tremolo and the special, by number.
        subscript(_ e: Int) -> Effect {
            get { e == 0 ? vibrato : e == 1 ? tremolo : special }
            set {
                if e == 0 { vibrato = newValue } else if e == 1 { tremolo = newValue } else { special = newValue }
            }
        }
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The tune, its first and last entries, the next, the speed's count, the count of events to the track's end,
    /// and the voices to be turned on.
    private var tune = 0
    private var firstEntry = 0
    private var lastEntry = 0
    private var entry = 0
    private var speedCount: UInt8 = 0
    private var trackCount: UInt32 = 0
    private var dmacon: UInt16 = 0
    /// Whether the tune has come to its end (`SongEnd`, as its last entry is begun) and not yet begun again.
    private var ending = false
    private var filter = true

    /// What each of Paula's period and volume registers was last given, and what they held as the tick just
    /// run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told at their
    /// moments).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the wait.
    private var clock = 0

    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?
    /// Each tune's length, found as the player is made.
    private var lengths: [UInt64?] = []

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A tune that has not come to its end in an hour is taken never to; and once the tunes played through to
    /// find their lengths have taken four hours in all, the rest are too.
    private static let mostTicks = 50 * 60 * 60
    private static let mostTicksInAll = 4 * mostTicks
    /// The most instructions a list is followed through in a tick (see the type's comment).
    private static let mostInstructions = 4096

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (near the medians of its dumps): the
    /// first after the interrupt begins (a guess: only the distances between them are heard); how long the
    /// voices' events, instructions and making take; and each voice's writes, and how long they take.
    static let firstWrite = 300
    static let onClocks = 40
    static let eventClocks = 150
    static let makeClocks = 250
    static let writeClocks = 240
    static let periodClocks = 80
    static let volumeClocks = 150

    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's clocks) has
    /// changed nine times, the first at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 80 - clock
    }

    /// The table of periods (`NoteTable`): three octaves, from 856.
    static let noteTable: [UInt16] = [
        856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
        428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
        214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
    ]

    /// The period of a note from nought (a byte); past the table, the three words that follow it (`tabel`), and
    /// past them nought, where the player would read its own code.
    private static func period(_ note: UInt8) -> UInt16 {
        let index = Int(note)
        if index < noteTable.count { return noteTable[index] }
        if index < noteTable.count + 3 { return phaseAdds[index - noteTable.count] }
        return 0
    }

    /// What the envelope's part goes on by when its level is reached (`tabel`): up to down, down to held, let go
    /// to held.
    static let phaseAdds: [UInt16] = [1, 2, 1]

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: Int) -> Int {
        Int(Int32(bitPattern: UInt32(word(at)) << 16 | UInt32(word(at &+ 2))))
    }
    /// A byte of the voice's instrument; nought for none (where the player would read the Amiga's own memory).
    @inline(__always) private func instrumentByte(_ instrument: Int, _ at: Int) -> UInt8 {
        instrument == 0 ? 0 : byte(instrument &+ at)
    }

    private static func byte(_ data: [UInt8], _ at: Int) -> UInt8 { at >= 0 && at < data.count ? data[at] : 0 }
    private static func word(_ data: [UInt8], _ at: Int) -> Int { Int(byte(data, at)) << 8 | Int(byte(data, at + 1)) }
    private static func long(_ data: [UInt8], _ at: Int) -> Int {
        Int(Int32(bitPattern: UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2))))
    }

    /// Where the file's lists of instructions end and its samples begin (`MUSIC_InitData`, `GetSize`): after the
    /// head, the entries, the events and 256 lists, each to an instruction of nought. And where each list begins.
    private static func lists(_ data: [UInt8]) -> (lists: [Int], end: Int) {
        var at = 6826 + 12 * word(data, 6788) + 6 * word(data, 6790)
        var lists = [Int](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            lists[i] = at
            // (Past the file, noughts: each list ends at once.)
            repeat { at += 4 } while byte(data, at - 4) != 0
        }
        return (lists, at)
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): a nought byte first, at least 7,000 bytes, and a
    /// length that is not nought; and either the empty tunes (nought to nought at speed 5 on four voices) at
    /// bytes 60 and 64, or three longs the editor leaves, or a length that is the length of its parts and samples.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 7000, data[0] == 0, long(data, 0) != 0 else { return false }
        if long(data, 0x3C) == 0x50F, long(data, 0x40) == 0x50F { return true }
        if long(data, 0x1284) == 0x40B11, long(data, 0x1188) == 0x181E_2329, long(data, 0x128C) == 0x2F36_3C41 { return true }
        var size = lists(data).end
        for i in 0 ..< 32 where byte(data, instrumentsAt + 128 * i + 24) != 0 {
            size = Int(Int32(truncatingIfNeeded: size + long(data, instrumentsAt + 128 * i + 4)))
        }
        return size == long(data, 0)
    }

    /// Reads the file and starts the tune asked for (of `songCount`, nought the first).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        entries = 6826
        events = 6826 + 12 * Self.word(data, 6788)
        let (lists, end) = Self.lists(data)
        self.lists = lists
        // (`MUSIC_InitData`: each instrument with a name given its sample's place, one after the other from the
        // lists' end; those without, silence.)
        var at = end
        var samples = 0
        for i in 0 ..< 32 {
            let instrument = Self.instrumentsAt + 128 * i
            let place: Int
            if Self.byte(data, instrument + 24) != 0 {
                place = at
                at = Int(Int32(truncatingIfNeeded: at + Self.long(data, instrument + 4)))
                samples += 1
            } else {
                place = silenceAt
            }
            for k in 0 ..< 4 where instrument + k < data.count {
                memory[instrument + k] = UInt8(truncatingIfNeeded: place >> (24 - 8 * k))
            }
        }
        sampleCount = samples
        // (`InitPlayer`: the tunes, to the first whose first and last are nought.)
        var count = 0
        while count < 16, Self.word(data, 4 + 4 * count) != 0 { count += 1 }
        songCount = max(1, count)
        var name = ""
        for b in data.dropFirst(6794).prefix(32).prefix(while: { $0 != 0 }) where b >= 0x20 && b < 0x7F {
            name.unicodeScalars.append(Unicode.Scalar(b))
        }
        title = name
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Musical Enlightenment file") }
        guard count > 0 else { throw .malformed("it has no tunes") }
        // (`InitPlayer`: a file shorter than its length is refused.)
        guard Self.long(data, 0) <= data.count else { throw .malformed("cut short") }

        // Each tune's length, from a playing of it in silence to its end.
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
            // (The tick it came to its end in is the first of it again.)
            lengths.append(endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil)
        }
        self.song = max(0, min(songCount - 1, song))
        lengthClocks = lengths[self.song]
        start()
    }

    deinit { memory.deallocate() }

    /// `MUSIC_Play` and `MUSIC_Continue`: the tune's entries, its first track read, and its first events to be
    /// read on the first tick.
    private mutating func start() {
        voices = .init(repeating: Voice())
        for v in 0 ..< 4 {
            voices[v].dma = 1 << UInt16(v)
            voices[v].place = silenceAt
        }
        tune = 4 + 4 * song
        firstEntry = entries + 12 * Int(byte(tune))
        lastEntry = entries + 12 * Int(byte(tune + 1))
        // (The speed's count is the long's first byte, which is cleared; the tune's speed goes into its last.)
        speedCount = 0
        dmacon = 0
        ending = false
        endings = 0
        entry = firstEntry
        newTrack()
        trackCount &+= 1
        filter = byte(tune + 3) & 16 == 0
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = periods
        volumesBefore = volumes
        clock = 0
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no tune \(song + 1)") }
        self.song = song
        lengthClocks = lengths[song]
        start()
    }

    private mutating func writePeriod<Output: TFMXOutput>(_ v: Int, _ period: UInt16, _ output: inout Output) {
        periods[v] = period
        output.writePeriod(v, period)
    }

    /// `ChangeVolume`: seven bits, times EaglePlayer's volume, 64, over 64.
    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume & 0x7F
        output.writeVolume(v, volumes[v])
    }

    /// Runs the player for a tick (`MUSIC_Player`), telling `output` what Paula is to do, in the order the player
    /// tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        let mask = UInt16(byte(tune + 3))
        var at = Self.firstWrite
        if dmacon != 0 {
            // The voices of the notes begun on the tick before turned on, and `DMAWait`.
            output.timed(at: at)
            for v in 0 ..< 4 where dmacon & 1 << UInt16(v) != 0 { output.on(v) }
            dmacon = 0
            at = afterWait(at + Self.onClocks)
        }
        if speedCount == 0 {
            speedCount = byte(tune + 2)
            trackCount &-= 1
            if trackCount == 0 { newTrack() }
            newNotes(mask, &output, &at)
        } else {
            speedCount -= 1
        }
        tryNewFx()
        makeAll(mask, &output, &at)
        for v in 0 ..< 4 where mask & voices[v].dma != 0 {
            output.timed(at: at)
            output.takeNextBuffer(v, start: voices[v].place, length: voices[v].length)
            output.timed(at: at + Self.periodClocks)
            writePeriod(v, voices[v].shadowPeriod, &output)
            output.timed(at: at + Self.volumeClocks)
            writeVolume(v, voices[v].shadowVolume, &output)
            at += Self.writeClocks
        }
        // (Kept within a whole number of the beam's lines, of 227 clocks and of 227.5, which is all the
        // waits ask of it: a count of every clock would outgrow a whole number in a browser.)
        clock = (clock + Self.tickClocks) % 103_285
        return 20
    }

    /// `NewTrack`: each voice's track of the next entry, and the entry after it (the first, after the last).
    private mutating func newTrack() {
        if ending {
            ending = false
            endings += 1
        }
        trackCount = 32
        var at = entry
        for v in 0 ..< 4 {
            voices[v].event = events &+ Int(byte(at)) * 192
            voices[v].adds = at &+ 1
            at &+= 3
        }
        if at == lastEntry {
            ending = true
            at = firstEntry
        }
        entry = at
    }

    /// `NewNotes`: each voice's next event.
    private mutating func newNotes<Output: TFMXOutput>(_ mask: UInt16, _ output: inout Output, _ at: inout Int) {
        for v in 0 ..< 4 {
            let event = voices[v].event
            let adds = voices[v].adds
            var instrument = voices[v].instrument
            voices[v].event &+= 6
            at += Self.eventClocks
            if voices[v].noUse != 0 {
                // (The note a slide went to.)
                voices[v].noUse = 0
                continue
            }
            var note = byte(event) & 127
            if note == 0 { continue }
            if note == 127 {
                // Its voice turned off.
                if mask & voices[v].dma != 0 {
                    output.timed(at: at)
                    output.off(v)
                }
                continue
            }
            if note == 126 {
                // Its envelope let go.
                voices[v].egPhase = 2
                continue
            }
            let flags = byte(event &+ 4)
            if flags & 4 == 0 { note &+= byte(adds &+ 1) }
            if note == 0 { continue }
            note -= 1
            voices[v].baseArpNote = note
            voices[v].vibrato.from = Self.period(note)
            let value = byte(event &+ 5)
            voices[v].glideAdd = flags & 2 != 0 ? UInt16(bitPattern: Int16(Int8(bitPattern: value))) : 0
            voices[v].doArpeggio = 0
            if flags & 16 != 0 {
                // A slide to the next event's note (which is then not played), in the value's ticks and one.
                var to = byte(event &+ 6) & 127
                if flags & 4 == 0 { to &+= byte(adds &+ 1) }
                if to == 0 {
                    voices[v].glideCount = 0
                } else {
                    voices[v].toPeriod = Self.period(to - 1)
                    voices[v].glideCount = UInt32(value) + 1
                    voices[v].noUse = 1
                }
            } else {
                if flags & 1 != 0 {
                    // An arpeggio: the value's, its length and speed in the byte before its notes.
                    voices[v].arpOnce = flags & 32 != 0 ? 1 : 0
                    voices[v].arpBlow = flags & 64
                    voices[v].arpeggio = Self.arpeggiosAt + 1 + Int(value) * 9
                    let lengthAndSpeed = byte(voices[v].arpeggio - 1)
                    voices[v].arpSpeed = lengthAndSpeed & 15
                    voices[v].arpCount = voices[v].arpSpeed + 1
                    var length = UInt16(lengthAndSpeed >> 4)
                    if length == 0 { length = 8 }
                    voices[v].arpLength = length
                    voices[v].doArpeggio = UInt8(truncatingIfNeeded: length - 1)
                    voices[v].arpAt = 0
                }
                voices[v].glideCount = 0
            }
            if byte(event) & 128 == 0 {
                // The note begun: the envelope and the sample from their starts, the instrument (the event's
                // and the entry's added), the voice turned off, to be turned on on the next tick, and the list
                // of instructions from its start.
                voices[v].egPhase = 0
                voices[v].egVolume = 0
                voices[v].egCount = 0
                voices[v].startPhase = 2
                var number = byte(event &+ 1)
                if number != 0 {
                    number -= 1
                    if flags & 8 == 0 { number = (number &+ byte(adds)) & 0x1F }
                    instrument = Self.instrumentsAt + Int(number) * 128
                    voices[v].instrument = instrument
                }
                let dma = voices[v].dma & mask
                dmacon |= dma
                if dma != 0 {
                    output.timed(at: at)
                    output.off(v)
                }
                let list = byte(event &+ 2)
                voices[v].instructions = list != 0 ? lists[Int(list)] : instrument == 0 ? -1 : instrument &+ 64
                for e in 0 ..< 3 {
                    voices[v][e].level = 0
                    voices[v][e].speed = 0
                    voices[v][e].pointer = 0
                }
                voices[v].waitForFx = 1
                voices[v].fxCount = 0
            }
            voices[v].baseVolume = UInt16(bitPattern: Int16(Int8(bitPattern: instrumentByte(instrument, 56) &+ byte(event &+ 3))))
        }
    }

    /// `TryNewFx`: each voice's list of instructions, when its count of ticks has run out: its vibrato's,
    /// tremolo's and special's levels and speeds set, to a wait.
    private mutating func tryNewFx() {
        for v in 0 ..< 4 where voices[v].waitForFx != 0 {
            let count = voices[v].fxCount
            voices[v].fxCount &-= 1
            guard count == 0 else { continue }
            var at = voices[v].instructions
            var walked = 0
            walking: while true {
                walked += 1
                let instruction = byte(at)
                let operation = Int(instruction >> 4)
                guard walked < Self.mostInstructions else {
                    voices[v].waitForFx = 0
                    break walking
                }
                switch operation {
                case 1, 3, 5:
                    // A level to go to, in so many ticks and one, on one of the sixteen waves.
                    let e = (operation - 1) / 2
                    voices[v][e].toLevel = byte(at &+ 1)
                    voices[v][e].levelCount = word(at &+ 2) &+ 1
                    voices[v][e].wave = Self.wavesAt + Int(instruction & 15) * 128
                    at &+= 4
                case 2, 4, 6:
                    // A speed to go to, in so many ticks and one.
                    let e = (operation - 2) / 2
                    voices[v][e].toSpeed = byte(at &+ 1)
                    voices[v][e].speedCount = word(at &+ 2) &+ 1
                    at &+= 4
                case 7:
                    // A wait of so many ticks.
                    voices[v].fxCount = word(at &+ 2)
                    voices[v].instructions = at &+ 4
                    break walking
                case 8:
                    // On from another list.
                    at = lists[Int(byte(at &+ 1))]
                default:
                    // The end (and an instruction it does not know).
                    voices[v].waitForFx = 0
                    break walking
                }
            }
        }
    }

    /// The quotient of `divs.w`, a word: for one too big for a word, the dividend's low word as it was (the
    /// 68000 leaves it).
    private static func divs(_ dividend: Int, _ divisor: UInt16) -> UInt16 {
        let by = Int(Int16(bitPattern: divisor))
        guard by != 0 else { return UInt16(truncatingIfNeeded: dividend) }
        let quotient = dividend / by
        return quotient >= -32768 && quotient <= 32767 ? UInt16(truncatingIfNeeded: quotient) : UInt16(truncatingIfNeeded: dividend)
    }

    /// `CalcFxData`: a vibrato's or tremolo's level and speed moved toward theirs, and what it makes of its
    /// source: its wave's value times its level, shifted down, added; for one going to no level, its source.
    private func calculate(_ effect: inout Effect, shift: UInt32) {
        guard effect.toLevel != 0 else {
            effect.to = effect.from
            return
        }
        if effect.levelCount != 0 {
            let quotient = Self.divs(Int(Int8(bitPattern: effect.toLevel &- effect.level)), effect.levelCount)
            effect.level &+= UInt8(truncatingIfNeeded: quotient)
            effect.levelCount &-= 1
        }
        if effect.speedCount != 0 {
            let quotient = Self.divs(Int(Int8(bitPattern: effect.toSpeed &- effect.speed)), effect.speedCount)
            effect.speed &+= UInt8(truncatingIfNeeded: quotient)
            effect.speedCount &-= 1
        }
        let value = Int32(Int8(bitPattern: byte(effect.wave &+ effect.pointer)))
        // (`muls.w` by the level, and `lsr.l`: a logical shift of the long.)
        let product = UInt32(bitPattern: value * Int32(effect.level))
        effect.to = UInt16(truncatingIfNeeded: product >> shift) &+ effect.from
        effect.pointer = Int(UInt8(truncatingIfNeeded: effect.pointer) &+ effect.speed) & 127
    }

    /// `CalcFx`: each voice's period (its slide by a step or to a note, or its arpeggio, and its vibrato), its
    /// volume (its envelope, of its base, and its tremolo) and its sample's place and length.
    private mutating func makeAll<Output: TFMXOutput>(_ mask: UInt16, _ output: inout Output, _ at: inout Int) {
        for v in 0 ..< 4 {
            at += Self.makeClocks
            let instrument = voices[v].instrument
            guard instrument != 0 else { continue }
            voices[v].vibrato.from &+= voices[v].glideAdd
            if voices[v].glideCount != 0 {
                let distance = Int(voices[v].toPeriod) - Int(voices[v].vibrato.from)
                voices[v].vibrato.from &+= Self.divs(distance, UInt16(truncatingIfNeeded: voices[v].glideCount))
                voices[v].glideCount -= 1
            } else if voices[v].doArpeggio != 0 {
                var arpAt = voices[v].arpAt
                let count = voices[v].arpCount
                voices[v].arpCount &-= 1
                if count == 0 {
                    // The next of its notes, every so many ticks and one; and begun again, if it is to be.
                    arpAt = UInt16((Int(arpAt) + 1) % Int(max(1, voices[v].arpLength)))
                    voices[v].arpAt = arpAt
                    voices[v].arpCount = voices[v].arpSpeed
                    voices[v].doArpeggio &-= voices[v].arpOnce
                    if voices[v].arpBlow != 0 {
                        voices[v].startPhase = 2
                        voices[v].egPhase = 0
                        voices[v].egCount = 0
                        voices[v].egVolume = 0
                        let dma = voices[v].dma & mask
                        dmacon |= dma
                        if dma != 0 {
                            output.timed(at: at)
                            output.off(v)
                        }
                    }
                }
                let note = voices[v].baseArpNote &+ byte(voices[v].arpeggio &+ Int(Int16(bitPattern: arpAt)))
                voices[v].vibrato.from = Self.period(note)
            }
            var vibrato = voices[v].vibrato
            calculate(&vibrato, shift: 7)
            voices[v].vibrato = vibrato
            let period = vibrato.to
            voices[v].shadowPeriod = Int16(bitPattern: period) < 113 ? 113 : period
            // The envelope: so many ticks to its part's level, and on to the next part.
            if voices[v].egCount != 0 {
                let distance = Int(voices[v].egToVolume) - Int(voices[v].egVolume)
                voices[v].egVolume &+= Self.divs(distance, UInt16(truncatingIfNeeded: voices[v].egCount))
                voices[v].egCount -= 1
            } else if voices[v].egPhase != 3 {
                let part = Int(voices[v].egPhase)
                voices[v].egCount = UInt32(byte(instrument &+ 58 &+ part)) + 1
                voices[v].egToVolume = voices[v].egToVolume & 0xFF00 | UInt16(byte(instrument &+ 61 &+ part))
                voices[v].egPhase &+= part < 3 ? Self.phaseAdds[part] : 0
            }
            // (`muls.w`, and `asr.w` of the product's low word.)
            let product = Int32(Int16(bitPattern: voices[v].baseVolume)) * Int32(Int16(bitPattern: voices[v].egVolume))
            voices[v].tremolo.from = UInt16(bitPattern: Int16(truncatingIfNeeded: product) >> 8)
            var tremolo = voices[v].tremolo
            calculate(&tremolo, shift: 9)
            voices[v].tremolo = tremolo
            let volume = tremolo.to
            voices[v].shadowVolume = Int16(bitPattern: volume) > 64 ? 64 : volume
            switch voices[v].startPhase {
            case 0:
                break
            case 2:
                // The sample's first part, and on the next tick its loop.
                voices[v].place = long(instrument)
                voices[v].length = word(instrument &+ 10)
                voices[v].startPhase = 1
            default:
                voices[v].place = Int(Int32(truncatingIfNeeded: long(instrument) &+ long(instrument &+ 12) &* 2))
                voices[v].length = word(instrument &+ 18)
                voices[v].startPhase = 0
            }
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

/// The Musical Enlightenment's music, played on Paula by `PaulaTickRenderer`.
extension TMEPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }
    var lightFilter: Bool { filter }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "The Musical Enlightenment")
        info.title = title
        info.detail = "N.J. Luuring jr's editor; \(sampleCount) sampled instrument\(sampleCount == 1 ? "" : "s")"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 its one file is -22.3 dB.)
    var gain: Float { 0.37 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
