// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Steve Hasler's replay routine for his Leggless Music Editor (as the game Punisher carries it), as
// Wanted Team adapted it for EaglePlayer ("Leggless Music Editor player module V1.2 (5 Dec 2008)"), carried by
// UADE as players/LegglessMusicEditor, whose source UADE also carries as
// amigasrc/players/wanted_team/LME/src/LMEv3.asm. The labels given are that source's.

/// The Leggless Music Editor, Steve "Leggless" Hasler's, whose music for Ninja Spirit (of seventeen songs) and
/// The Punisher is among UnExoticA's: a file that begins "LME" and a nought, a name, and from byte 40 the places
/// (from byte 40) of its instruments, its table of patterns, its patterns, its samples and, from byte 56, its
/// songs, each four places of the four voices' lists of patterns (a word each, $FFFF their end; a pattern's with
/// its top bit set has a transposition after it).
///
/// A pattern is a list of events, each a word of what it has and the words it has, to a word with its top bit
/// set: bit 0 a rest of so many ticks (the voice turned off), bit 1 an instrument, bit 4 an arpeggio (how many
/// notes, every how many ticks, and the notes after the first), bit 3 a note tied to the last (not started
/// again), bit 2 a slide (from the event's own note to the one it gives, in so many ticks, after so many), and
/// then how many ticks the note lasts and the note. An instrument is 58 bytes: its sample (its place from the
/// samples', or for one whose wave's word is not nought, a wave the player makes, a square of a width that
/// grows and shrinks between two bounds) and its length and volume and loop, a vibrato (a step, two bounds and a delay), a volume's envelope (up to a level,
/// held for so many ticks, down to a level), the wave's widths and its two levels, and every how many ticks the
/// sample is started again.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`), and so is run by
/// EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second
/// and a little less. On every tick the loops of the notes started on the tick before are told, the slides,
/// vibratos and arpeggios move the periods, the envelopes set every voice's volume, the samples to be started
/// again are, each voice's count of ticks comes down and at nought it reads its next event, the waves are made
/// for the tick, and once `DMAWait` has waited for the beam to begin nine lines (of 227 of Paula's clocks), the
/// voices with notes begun are turned on. Wanted Team's player sets the volume of a note it has just begun to
/// eight times its voice's number (its `LME_SetVoices` is called with the wrong register), until the envelope
/// sets it on the tick after: that is done only if it is asked for (`wantedTeamsVolumes`), as Steve Hasler's own
/// player does not.
///
/// Each voice's writes are told Paula at their moments in the tick (`TFMXOutput.timed(at:)`), near where they
/// fall in UADE's dumps.
///
/// A song comes to its end when all four voices have come to the end of their lists of patterns and gone back
/// to the beginning (as the player tells EaglePlayer so). Where the player would read past the file it reads
/// nought, and where it would write past its own tables it writes nothing; a slide in no ticks (a division by
/// nought, which would crash the machine) does not move.
struct LMEPlayer: ~Copyable {
    /// The file, the waves the player makes, and what follows them, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: noughts after the waves.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048
    /// Where the player's 512 bytes for its waves are (`lbL0008EA`, in chip memory), 128 for each voice.
    let wavesAt: Int

    private let fileSize: Int
    /// Where the instruments (`lbL000AEA`), the table of patterns (`lbL000AEE`), the patterns (`lbL000AF2`) and
    /// the samples (`lbL000AF6`) are: each from byte 40.
    private let instruments: Int
    private let patternTable: Int
    private let patterns: Int
    private let samples: Int
    let songCount: Int
    private(set) var song = 0
    /// How many instruments it has, and of them how many are the player's waves, as `InitPlayer` counts them
    /// (those whose sample's place is nought).
    let instrumentCount: Int
    let syntheticCount: Int
    /// Whether a note's volume is set as Wanted Team's player sets it (see the type's comment).
    let wantedTeamsVolumes: Bool

    /// A voice's copy of its instrument (`lbW000782`, 90 bytes each: the instrument's 58 and 32 more, which
    /// nothing reads), with its sample's places made into places in memory, and what the player changes of it.
    private struct Instrument {
        /// Its sound and its loop: places in memory (nil for none, before an instrument), and lengths in words;
        /// and its volume.
        var place: Int?
        var length: UInt16 = 0
        var volume: UInt16 = 0
        var loopPlace: Int?
        var loopLength: UInt16 = 0
        /// The vibrato (bytes 14 to 25): where it is, its step, which way it goes, its bounds and its delay.
        var vibrato: UInt16 = 0
        var vibratoStep: UInt16 = 0
        var vibratoDown: UInt16 = 0
        var vibratoTop: UInt16 = 0
        var vibratoBottom: UInt16 = 0
        var vibratoDelay: UInt16 = 0
        /// The envelope (bytes 26 to 37): its part (1 up, 2 held, 3 down), its step up and level, how long it is
        /// held, and its step down and level.
        var envelope: UInt16 = 0
        var attack: UInt16 = 0
        var attackLevel: UInt16 = 0
        var hold: UInt16 = 0
        var release: UInt16 = 0
        var releaseLevel: UInt16 = 0
        /// The wave (bytes 38 to 53): nought for a sample, else 2 for its width shrinking and anything else for
        /// it growing; its width, its steps and bounds, and its two levels (the low bytes of two words).
        var wave: UInt16 = 0
        var width: UInt16 = 0
        var widthUp: UInt16 = 0
        var widthTop: UInt16 = 0
        var widthDown: UInt16 = 0
        var widthBottom: UInt16 = 0
        var high: UInt16 = 0
        var low: UInt16 = 0
        /// The count of ticks to starting it again, and every how many (bytes 54 to 57; nought for never).
        var retrigger: UInt16 = 0
        var retriggerEvery: UInt16 = 0
    }

    /// What the player keeps for each voice.
    private struct Voice {
        /// Its count of ticks to its next event (`lbW00066A`), where it reads its pattern (`lbL000672`; nil for
        /// the $FFFF it begins at), where its list of patterns is and begins (`lbL000682`, `lbL000692`), its
        /// transposition (`lbL000770`) and its instrument's place in their table (`lbL000768`, 58 times its
        /// number), and its note's period (`lbL0006E6`).
        var count: UInt16 = 1
        var event: Int?
        var list = 0
        var listStart = 0
        var transposition: UInt16 = 0
        var instrument: UInt16 = 0
        var period: UInt16 = 0
        /// Whether it has come to the end of its list (the bytes of `Songend`, cleared).
        var ended = false
        /// The loop to be told on the next tick (`lbL0006A6`).
        var loopDue = false
        var loopPlace: Int?
        var loopLength: UInt16 = 0
        /// The slide (`lbL0006C6`): its step, its count of ticks, where it ends and its delay.
        var slide: UInt16 = 0
        var slideCount: UInt16 = 0
        var slideTo: UInt16 = 0
        var slideDelay: UInt16 = 0
        var copy = Instrument()
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The four voices' arpeggios (`lbL0006F6`), 28 bytes each and one after the other: where it is, its
    /// length (twice its notes), its count of ticks and every how many, its first note's period (the voice's
    /// own) and the others'.
    private var arpeggios = InlineArray<56, UInt16>(repeating: 0)
    /// The voices to be turned on at the tick's end (`lbW000668`).
    private var turnOn: UInt16 = 0

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
    /// Each song's length, found as the player is made.
    private var lengths: [UInt64?] = []

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to; and once the songs played through
    /// to find their lengths have taken four hours in all, the rest are too (only a broken file has so many
    /// songs that never end).
    private static let mostTicks = 50 * 60 * 60
    private static let mostTicksInAll = 4 * mostTicks

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (near the medians of its dumps): the
    /// first after the interrupt begins (a guess: only the distances between them are heard); after a loop
    /// told, a period moved, and a voice's envelope; and for the events, a voice's that has none, how long one
    /// with an instrument and one without take to their note, and how long after a note the next voice is
    /// begun.
    static let firstWrite = 300
    static let loopClocks = 40
    static let periodClocks = 120
    static let envelopeClocks = 220
    static let quietClocks = 60
    static let instrumentClocks = 600
    static let eventClocks = 300
    static let noteClocks = 100

    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's clocks) has
    /// changed nine times, the first at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 80 - clock
    }

    /// The table of periods (`lbW000606`): three octaves, ProTracker's, and $6B.
    static let periodTable: [UInt16] = [
        0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC, 0x1E0, 0x1C5,
        0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0, 0x0E2,
        0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0x078, 0x071,
        0x06B,
    ]

    /// The period of a note (a word, doubled as a word and taken as a signed offset into the table); nought
    /// for one past it, where the player would read its own variables.
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

    /// True for a file the player's check takes (`Check2`): "LME" and a nought, and a nought long at byte 36.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 40 && data[0] == 0x4C && data[1] == 0x4D && data[2] == 0x45 && data[3] == 0
            && data[36] | data[37] | data[38] | data[39] == 0
    }

    /// Reads the file and starts the song asked for (of `songCount`, nought the first).
    init(_ data: [UInt8], song: Int = 0, wantedTeamsVolumes: Bool = false) throws(TuneError) {
        fileSize = data.count
        wavesAt = (data.count + 15) & ~15
        silenceAt = wavesAt + 1024
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        self.wantedTeamsVolumes = wantedTeamsVolumes
        instruments = 0x28 &+ Self.long(data, 0x28)
        patternTable = 0x28 &+ Self.long(data, 0x2C)
        patterns = 0x28 &+ Self.long(data, 0x30)
        samples = 0x28 &+ Self.long(data, 0x34)
        // (`InitPlayer`: the songs, from the instruments' place; the instruments, from theirs to byte 56's, and
        // of those the ones whose sample's place is nought, the player's own waves.)
        songCount = max(1, min(256, (Self.long(data, 0x28) - 16) / 16))
        let count = max(0, min(1024, (Self.long(data, 56) - Self.long(data, 40)) / 58))
        var synthetic = 0
        for i in 0 ..< count where Self.long(data, instruments + 58 * i) == 0 { synthetic += 1 }
        instrumentCount = count
        syntheticCount = synthetic
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Leggless Music Editor file") }
        guard data.count >= 0x38 + 16 * songCount else { throw .malformed("too short for its songs") }

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
            // (The tick it came to its end in is the first of it again.)
            lengths.append(endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil)
        }
        self.song = max(0, min(songCount - 1, song))
        lengthClocks = lengths[self.song]
        start()
    }

    deinit { memory.deallocate() }

    /// `InitSound` and `Init`: each voice set to read the first pattern of its list on the first tick.
    private mutating func start() {
        voices = .init(repeating: Voice())
        for v in 0 ..< 4 {
            let list = 0x28 &+ long(0x38 &+ 16 * song &+ 4 * v)
            voices[v].list = list
            voices[v].listStart = list
        }
        arpeggios = .init(repeating: 0)
        turnOn = 0
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = periods
        volumesBefore = volumes
        for p in 0 ..< 512 { memory[wavesAt + p] = 0 }
        clock = 0
        endings = 0
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        lengthClocks = lengths[song]
        start()
    }

    private mutating func writePeriod<Output: TFMXOutput>(_ v: Int, _ period: UInt16, _ output: inout Output) {
        periods[v] = period
        output.writePeriod(v, period)
    }

    /// `LME_SetVoices`: seven bits, times EaglePlayer's volume, 64, over 64.
    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume & 0x7F
        output.writeVolume(v, volumes[v])
    }

    /// Runs the player for a tick (`Play`), telling `output` what Paula is to do, in the order the player tells
    /// her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        var at = Self.firstWrite
        // The loops of the notes begun on the tick before.
        for v in 0 ..< 4 where voices[v].loopDue {
            voices[v].loopDue = false
            output.timed(at: at)
            output.takeNextBuffer(v, start: voices[v].loopPlace ?? silenceAt, length: voices[v].loopLength)
            at += Self.loopClocks
        }
        turnOn = 0
        slides(&output, &at)
        vibratos(&output, &at)
        arpeggiate(&output, &at)
        envelopes(&output, &at)
        retriggers(&output, &at)
        for v in 0 ..< 4 {
            voices[v].count &-= 1
            if voices[v].count == 0 {
                event(v, &output, &at)
            } else {
                at += Self.quietClocks
            }
        }
        makeWaves()
        if turnOn != 0 {
            output.timed(at: afterWait(at))
            for v in 0 ..< 4 where turnOn & 1 << UInt16(v) != 0 { output.on(v) }
        }
        // (Kept within a whole number of the beam's lines, of 227 clocks and of 227.5, which is all the
        // waits ask of it: a count of every clock would outgrow a whole number in a browser.)
        clock = (clock + Self.tickClocks) % 103_285
        return 20
    }

    /// `lbC0000F0`: the voice's next event read and done.
    private mutating func event<Output: TFMXOutput>(_ v: Int, _ output: inout Output, _ at: inout Int) {
        // (The arpeggio ended.)
        arpeggios[14 * v + 1] = 0
        var reading = voices[v].event
        var what = reading.map { word($0) } ?? 0xFFFF
        if reading != nil { reading! &+= 2 }
        if what & 0x8000 != 0 {
            // The pattern's end: the next of the list, and at the list's end its first again, and once all
            // four have come to theirs the song's end.
            var list = voices[v].list
            var pattern = word(list)
            list &+= 2
            if pattern == 0xFFFF {
                voices[v].ended = true
                var all = true
                for w in 0 ..< 4 where !voices[w].ended { all = false }
                if all {
                    for w in 0 ..< 4 { voices[w].ended = false }
                    endings += 1
                }
                list = voices[v].listStart
                pattern = word(list)
                list &+= 2
            }
            voices[v].transposition = 0
            if pattern & 0x8000 != 0 {
                pattern &= 0x7FFF
                voices[v].transposition = word(list)
                list &+= 2
            }
            voices[v].list = list
            var place = patterns &+ long(patternTable &+ Int(Int16(bitPattern: pattern &<< 2)))
            what = word(place)
            place &+= 2
            reading = place
        }
        var place = reading ?? 0
        if what & 1 != 0 {
            // A rest (`lbC00028E`): the voice turned off for so many ticks.
            voices[v].count = word(place)
            output.timed(at: at)
            output.off(v)
            voices[v].event = place &+ 2
            at += Self.eventClocks
            return
        }
        var took = Self.eventClocks
        if what & 2 != 0 {
            // An instrument (`lbC0002B0`): its 58 bytes copied whole, its places made into memory's (or its
            // wave's, for one of none).
            let number = word(place)
            place &+= 2
            let offset = number &* 58
            voices[v].instrument = offset
            let from = instruments &+ Int(Int16(bitPattern: offset))
            copy(v, from: from, whole: true)
            if voices[v].copy.wave == 0 {
                voices[v].copy.place = samples &+ long(from)
                voices[v].copy.loopPlace = samples &+ long(from &+ 8)
            } else {
                voices[v].copy.place = wavesAt + 128 * v
                voices[v].copy.loopPlace = wavesAt + 128 * v
                voices[v].copy.loopLength = voices[v].copy.length
            }
            took = Self.instrumentClocks
        }
        if what & 16 != 0 {
            // An arpeggio (`lbC0003B6`): its notes' periods, after the voice's own.
            let count = word(place)
            let transposition = voices[v].transposition
            let entry = 14 * v
            arpeggios[entry] = 0
            arpeggios[entry + 1] = count &<< 1
            arpeggios[entry + 2] = 1
            arpeggios[entry + 3] = word(place &+ 2)
            place &+= 4
            // (`dbra` from the count (its length halved again, as a word) less two: as many notes as the count
            // less one, or for a count of nought or one, the most a word counts.)
            let notes = Int(((count &<< 1) >> 1) &- 2) + 1
            // (Those that would be written past the four arpeggios are read past and not written.)
            for k in 0 ..< min(notes, 56) where entry + 5 + k < 56 {
                arpeggios[entry + 5 + k] = Self.period(word(place &+ 2 * k) &+ transposition)
            }
            place &+= 2 * notes
        }
        var tied = false
        if what & 8 != 0 {
            tied = true
        } else {
            // (`lbC000182`: the instrument's volume and all from its vibrato on copied again.)
            copy(v, from: instruments &+ Int(Int16(bitPattern: voices[v].instrument)), whole: false)
        }
        var sliding = false
        if what & 4 != 0 {
            // A slide (`lbC00031C`): to the period of the note given, in so many ticks, after so many.
            let target = Self.period(word(place) &+ voices[v].transposition)
            voices[v].slideCount = word(place &+ 2)
            voices[v].slideTo = target
            voices[v].slide = target
            voices[v].slideDelay = word(place &+ 4)
            place &+= 6
            sliding = true
        }
        // The note: how long, and its period.
        voices[v].count = word(place)
        let period = Self.period(word(place &+ 2) &+ voices[v].transposition)
        place &+= 4
        voices[v].period = period
        if sliding {
            // (`lbC00034E`: the step, the distance over the ticks, `divs.w`: its quotient, or for one too big
            // for a word the distance as it was; and for no ticks, none.)
            let distance = Int(voices[v].slide) - Int(period)
            let ticks = Int(Int16(bitPattern: voices[v].slideCount))
            if ticks == 0 {
                voices[v].slide = 0
            } else {
                let quotient = distance / ticks
                voices[v].slide = quotient >= -32768 && quotient <= 32767 ? UInt16(truncatingIfNeeded: quotient) : UInt16(truncatingIfNeeded: distance)
            }
        }
        voices[v].event = place
        at += took
        output.timed(at: at)
        if tied {
            // (`lbC000222`: only the period.)
            writePeriod(v, period, &output)
            at += Self.noteClocks
            return
        }
        // The note begun (`lbC000238`), its loop to be told on the next tick.
        output.off(v)
        let copy = voices[v].copy
        output.takeNextBuffer(v, start: copy.place ?? silenceAt, length: copy.length)
        writePeriod(v, period, &output)
        writeVolume(v, copy.volume, &output)
        if wantedTeamsVolumes { writeVolume(v, UInt16(8 * v), &output) }
        voices[v].loopDue = true
        voices[v].loopPlace = copy.loopPlace
        voices[v].loopLength = copy.loopLength
        turnOn |= 1 << UInt16(v)
        at += Self.noteClocks
    }

    /// The instrument at `from` copied into the voice's own: whole, or (for a note not tied) its volume and all
    /// from its vibrato on.
    private mutating func copy(_ v: Int, from: Int, whole: Bool) {
        if whole {
            voices[v].copy.length = word(from &+ 4)
            voices[v].copy.loopLength = word(from &+ 12)
        }
        voices[v].copy.volume = word(from &+ 6)
        voices[v].copy.vibrato = word(from &+ 14)
        voices[v].copy.vibratoStep = word(from &+ 16)
        voices[v].copy.vibratoDown = word(from &+ 18)
        voices[v].copy.vibratoTop = word(from &+ 20)
        voices[v].copy.vibratoBottom = word(from &+ 22)
        voices[v].copy.vibratoDelay = word(from &+ 24)
        voices[v].copy.envelope = word(from &+ 26)
        voices[v].copy.attack = word(from &+ 28)
        voices[v].copy.attackLevel = word(from &+ 30)
        voices[v].copy.hold = word(from &+ 32)
        voices[v].copy.release = word(from &+ 34)
        voices[v].copy.releaseLevel = word(from &+ 36)
        voices[v].copy.wave = word(from &+ 38)
        voices[v].copy.width = word(from &+ 40)
        voices[v].copy.widthUp = word(from &+ 42)
        voices[v].copy.widthTop = word(from &+ 44)
        voices[v].copy.widthDown = word(from &+ 46)
        voices[v].copy.widthBottom = word(from &+ 48)
        voices[v].copy.high = word(from &+ 50)
        voices[v].copy.low = word(from &+ 52)
        voices[v].copy.retrigger = word(from &+ 54)
        voices[v].copy.retriggerEvery = word(from &+ 56)
    }

    /// `lbC000370`: each slide's step added to its voice's period after its delay, and at its last tick the
    /// period it ends at.
    private mutating func slides<Output: TFMXOutput>(_ output: inout Output, _ at: inout Int) {
        for v in 0 ..< 4 where voices[v].slide != 0 {
            if Int16(bitPattern: voices[v].slideDelay) >= 0 {
                voices[v].slideDelay &-= 1
                if Int16(bitPattern: voices[v].slideDelay) >= 0 { continue }
            }
            output.timed(at: at)
            voices[v].period &+= voices[v].slide
            writePeriod(v, voices[v].period, &output)
            voices[v].slideCount &-= 1
            if voices[v].slideCount == 0 {
                voices[v].period = voices[v].slideTo
                writePeriod(v, voices[v].period, &output)
                voices[v].slide = 0
            }
            at += Self.periodClocks
        }
    }

    /// `lbC000452`: each vibrato moved by its step between its bounds after its delay, and added to the voice's
    /// period (but for a voice with an arpeggio, which adds it itself).
    private mutating func vibratos<Output: TFMXOutput>(_ output: inout Output, _ at: inout Int) {
        for v in 0 ..< 4 where voices[v].copy.vibratoStep != 0 {
            if Int16(bitPattern: voices[v].copy.vibratoDelay) >= 0 {
                voices[v].copy.vibratoDelay &-= 1
                if Int16(bitPattern: voices[v].copy.vibratoDelay) >= 0 { continue }
            }
            var value = voices[v].copy.vibrato
            if voices[v].copy.vibratoDown == 0 {
                value &+= voices[v].copy.vibratoStep
                voices[v].copy.vibrato = value
                // (`bset #0` of the word's high byte.)
                if value == voices[v].copy.vibratoTop { voices[v].copy.vibratoDown |= 0x100 }
            } else {
                value &-= voices[v].copy.vibratoStep
                voices[v].copy.vibrato = value
                if value == voices[v].copy.vibratoBottom { voices[v].copy.vibratoDown &= ~0x100 }
            }
            if arpeggios[14 * v + 1] == 0 {
                output.timed(at: at)
                writePeriod(v, value &+ voices[v].period, &output)
                at += Self.periodClocks
            }
        }
    }

    /// `lbC0003FE`: each arpeggio's first note made its voice's period, and every so many ticks the next of its
    /// notes, with the vibrato's place added.
    private mutating func arpeggiate<Output: TFMXOutput>(_ output: inout Output, _ at: inout Int) {
        for v in 0 ..< 4 {
            let entry = 14 * v
            arpeggios[entry + 4] = voices[v].period
            guard arpeggios[entry + 1] != 0 else { continue }
            arpeggios[entry + 2] &-= 1
            guard arpeggios[entry + 2] == 0 else { continue }
            arpeggios[entry + 2] = arpeggios[entry + 3]
            let index = arpeggios[entry]
            // (Its notes from the first's word, the place a signed word of bytes; past the four arpeggios, nought.)
            let note = entry + 4 + Int(Int16(bitPattern: index)) / 2
            let period = note >= 0 && note < 56 ? arpeggios[note] : 0
            output.timed(at: at)
            writePeriod(v, period &+ voices[v].copy.vibrato, &output)
            at += Self.periodClocks
            arpeggios[entry] = index &+ 2
            if arpeggios[entry] == arpeggios[entry + 1] { arpeggios[entry] = 0 }
        }
    }

    /// `lbC0004C4`: each voice's envelope moved, up to its level, held, and down to its level; and its volume
    /// told Paula, on every tick.
    private mutating func envelopes<Output: TFMXOutput>(_ output: inout Output, _ at: inout Int) {
        for v in 0 ..< 4 {
            var volume = voices[v].copy.volume
            switch voices[v].copy.envelope {
            case 1:
                volume &+= voices[v].copy.attack
                // (`bmi`: the difference's sign.)
                if Int16(bitPattern: volume &- voices[v].copy.attackLevel) >= 0 {
                    volume = voices[v].copy.attackLevel
                    voices[v].copy.envelope &+= 1
                }
            case 2:
                voices[v].copy.hold &-= 1
                if Int16(bitPattern: voices[v].copy.hold) < 0 { voices[v].copy.envelope &+= 1 }
            case 3:
                volume &-= voices[v].copy.release
                if Int16(bitPattern: volume) <= Int16(bitPattern: voices[v].copy.releaseLevel) {
                    volume = voices[v].copy.releaseLevel
                    voices[v].copy.envelope &+= 1
                }
            default:
                break
            }
            output.timed(at: at)
            writeVolume(v, volume, &output)
            voices[v].copy.volume = volume
            at += Self.envelopeClocks
        }
    }

    /// `lbC0005AA`: each sample to be started again every so many ticks started again (turned off now and on
    /// at the tick's end, and its loop told on the next).
    private mutating func retriggers<Output: TFMXOutput>(_ output: inout Output, _ at: inout Int) {
        for v in 0 ..< 4 where voices[v].copy.retriggerEvery != 0 {
            voices[v].copy.retrigger &-= 1
            guard voices[v].copy.retrigger == 0 else { continue }
            voices[v].copy.retrigger = voices[v].copy.retriggerEvery
            turnOn |= 1 << UInt16(v)
            output.timed(at: at)
            output.off(v)
            output.takeNextBuffer(v, start: voices[v].copy.place ?? silenceAt, length: voices[v].copy.length)
            voices[v].loopDue = true
            voices[v].loopPlace = voices[v].copy.loopPlace
            voices[v].loopLength = voices[v].copy.loopLength
            at += Self.quietClocks
        }
    }

    /// `lbC000532`: each voice's wave made for the tick, its width grown or shrunk by its step to its bound: as
    /// many bytes of its high level as its width less one, and then of its low to twice its length in all.
    private mutating func makeWaves() {
        for v in 0 ..< 4 where voices[v].copy.wave != 0 {
            var width: UInt16
            if voices[v].copy.wave == 2 {
                width = voices[v].copy.width &- voices[v].copy.widthDown
                if Int16(bitPattern: width) <= Int16(bitPattern: voices[v].copy.widthBottom) {
                    width = voices[v].copy.widthBottom
                    voices[v].copy.wave &-= 1
                }
            } else {
                width = voices[v].copy.width &+ voices[v].copy.widthUp
                if Int16(bitPattern: width &- voices[v].copy.widthTop) >= 0 {
                    width = voices[v].copy.widthTop
                    voices[v].copy.wave &+= 1
                }
            }
            voices[v].copy.width = width
            // (Written where the voice's copy says its sound is, which is its wave's place unless it has none;
            // and no further than the player's 512 bytes.)
            guard let place = voices[v].copy.place, place >= wavesAt, place < wavesAt + 512 else { continue }
            let end = wavesAt + 512
            var into = place
            let high = UInt8(truncatingIfNeeded: voices[v].copy.high)
            let low = UInt8(truncatingIfNeeded: voices[v].copy.low)
            let rest = (voices[v].copy.length &<< 1) &- width
            let first = width &- 2
            // (`dbra`: a word's count and one more; the high level's skipped for a width under two.)
            if Int16(bitPattern: first) >= 0 {
                for _ in 0 ... Int(first) {
                    guard into < end else { break }
                    memory[into] = high
                    into += 1
                }
                if Int16(bitPattern: rest) < 0 { continue }
            }
            for _ in 0 ... Int(rest) {
                guard into < end else { break }
                memory[into] = low
                into += 1
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

/// The Leggless Music Editor, played on Paula by `PaulaTickRenderer`.
extension LMEPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Leggless Music Editor")
        let samples = instrumentCount - syntheticCount
        info.detail = "Steve Hasler's editor; \(samples) sampled instrument\(samples == 1 ? "" : "s"), \(syntheticCount) of the player's waves"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -18.2 dB.)
    var gain: Float { 0.23 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
