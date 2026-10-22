// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Steve Turner's sound driver for Graftgold's games of 1989 and 1990 (Wanted Team took theirs from Off
// Road Racer), as Wanted Team (Mr.Larmer) adapted it for EaglePlayer ("Steve Turner player module V1.3 (17 June
// 2001)"), carried by UADE as players/SteveTurner, whose source UADE also carries as
// amigasrc/players/wanted_team/SteveTurner/src/Steve Turner_v4.asm. The labels given are that source's; the places
// in the player's table are given as it gives them, from $1242.

import SidayChips
import SidayFoundation

/// Steve Turner's music for Graftgold's games, his own for Rainbow Islands and Jason Page's for Paradroid 90,
/// Simulcra and Ivan "Ironman" Stewart's Super Off Road: the driver's data as the games loaded it, which begins
/// with 46 bytes of the 68000's code that tell the driver where its tables are (four `move.l #place,x(a5)`, each
/// a place in the game's memory: of the instruments, which follow the code, the songs, the patterns and the
/// samples) and call it. Nothing runs that code; the player reads the places from it.
///
/// A song is twelve bytes: its priority, its speed (in ticks to a step), the song to go on to at its end and a
/// byte unused, and the places of its four voices' lists of patterns (from the songs' own, nought for a voice it
/// leaves alone); the songs are those from the first whose priority is nought and whose speed is under 16. A list
/// is of patterns' numbers, to $FF (the song's end) or $FE (the voice's). A pattern is of bytes: a note (to $7F),
/// how many steps the next notes last ($80 to $AF, one to 48), an instrument begun with no note ($B0 to $CF), the
/// instrument of the notes ($D0 to $EF), a slide to each note ($F0 to $F8, nought for none: how far it moves is
/// the distance halved so many times), a rest ($FE) and the pattern's end (any other). An instrument is 48 bytes:
/// up to three parts of a sequence of periods (each from its own period or the note's, moved by a step that
/// itself grows, so many times, so many times over, each part every so many ticks, and then put back, turned
/// round or quickened), its priority and sample, an envelope of volume (up for so many ticks, down for so many,
/// held with a tremolo for so many, and down to silence, and that done so many times or the sample played once),
/// how far its periods are shifted down, a vibrato and an instrument that follows it.
///
/// This is the driver itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. Its module sets the CIA's timer to $1BC0 (`InitSound`), and so a tick is 35,525 of
/// Paula's clocks, a hundred times a second and a little less. On every tick each voice reads its pattern, at
/// its steps' end, and moves its envelope, its periods and its slide; and then a song asked for is begun. A note
/// is begun on the tick it is read: its sample is told Paula and its voice turned off; it is turned on with the
/// volume nought on the tick after; and on the tick after that, for a sample played once, told to go on with
/// silence. Everything is told at the tick's start.
///
/// Wanted Team's player differs from the game's in two ways that are heard, which are kept only if they are asked
/// for (`asWantedTeam`). It does not make the voices ready as the game did as it began (`lbC0005C2`), and so the
/// voices a song leaves alone are taken for the game's sound effects and play the first instrument on the first
/// tick and again on the 256th. And it has every song begin again at its end, where the game's driver goes on to
/// the song the song names, or for one that names none, stops (lines 974 to 976, taken out by Wanted Team as a
/// "looping song fix"). Rainbow Islands' song 8 goes on to song 1; ten of Super Off Road's nineteen songs,
/// eight of Rainbow Islands' fifteen and two of Paradroid 90's six go on to none.
///
/// A song comes to its end when it goes back to a song it has played (itself, mostly), and stops once no voice
/// has anything left to read or to sound. Where the player would read past the file it reads nought; where it
/// would write past its own table (an instrument of more than three parts) it writes nothing.
struct SteveTurnerPlayer: ~Copyable {
    /// The file and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: noughts after the file (as the player's own `lbL0004B0`,
    /// four bytes of nought).
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where the instruments ($124A, byte 46), the songs ($1242), the patterns' table ($1246) and the samples'
    /// ($124E) are: the places the code at the file's head gives, less the instruments', and 46.
    private let instruments: Int
    private let songs: Int
    private let patterns: Int
    private let samples: Int
    let songCount: Int
    private(set) var song = 0
    /// How many samples the file has, as `InitPlayer` counts them (the places in their table that are not nought).
    let sampleCount: Int
    /// Whether it is played as Wanted Team's player plays it (see the type's comment).
    let asWantedTeam: Bool

    /// A part of an instrument's sequence of periods, as a voice keeps it (8 bytes from 0, 8 and 16): the period
    /// it is at and began at, its step, and how many times it steps before its count is taken again.
    private struct Part {
        var period: UInt16 = 0
        var start: UInt16 = 0
        var step: UInt16 = 0
        var count: UInt8 = 0
    }

    /// What the voice's envelope does on each tick (the routine at $26).
    private enum Envelope {
        /// Nothing (`lbC000744`).
        case none
        /// The voice turned off (`lbC000942`), on the tick its note is begun.
        case stopping
        /// The voice turned on, and the envelope begun (`lbC000952`).
        case starting
        /// A sample played once told to go on with silence (`lbC0009AA`), and the envelope's rise.
        case looping
        /// Its rise (`lbC0009CE`), its fall (`lbC0009F0`), its hold with a tremolo (`lbC000A1C`) and its fall to
        /// silence (`lbC000A3E`).
        case attack
        case decay
        case sustain
        case release
    }

    /// What the voice's periods do on each tick (the routine at $38): nothing, a part begun (`lbC000B22`), its
    /// period held (`lbC000B3C`) and stepped (`lbC000B52`).
    private enum Periods {
        case none
        case part
        case holding
        case stepping
    }

    /// What the voice's reading does on each tick (the routine at $4C): nothing, its list read (`lbC0007A4`), or
    /// its steps counted (`lbC0008BC`).
    private enum Reading {
        case none
        case list
        case waiting
    }

    /// What the player keeps for each voice ($6C bytes each, from $1264).
    private struct Voice {
        var parts = InlineArray<3, Part>(repeating: Part())
        /// How many more times the envelope is to be gone through ($18).
        var again: UInt8 = 0
        /// The game's two asks for a sound effect on the voice: one for the next tick, and one for when a count
        /// of ticks comes to nought; each a flag or count, a priority, and an instrument's place among theirs
        /// (negative for none). ($1A to $21.)
        var effectFlag: UInt8 = 0
        var effectPriority: UInt8 = 0
        var effect: UInt16 = 0
        var laterCount: UInt8 = 0
        var laterPriority: UInt8 = 0
        var later: UInt16 = 0
        /// The instrument it is playing: its number and one, its priority, and its place among the instruments
        /// ($22 to $25); and its place in memory ($30).
        var number: UInt8 = 0
        var priority: UInt8 = 0
        var instrumentOffset: UInt16 = 0
        var instrument = 0
        /// The envelope: what it does, its count of ticks, its step (signed), the tremolo's count, and the
        /// volume, to 255 ($26 to $2F).
        var envelope = Envelope.none
        var envelopeCount: UInt16 = 0
        var rate: UInt8 = 0
        var tremolo: UInt8 = 0
        var level: UInt16 = 0
        /// The periods: what they do, the part's place among the voice's and the instrument's (`D4` and `D3`,
        /// kept at $40 and $42), its number from one, and its counts ($38 to $47).
        var periods = Periods.none
        var part: UInt16 = 0
        var partData: UInt16 = 0
        var partNumber: UInt8 = 0
        var inner: UInt8 = 0
        var outer: UInt8 = 0
        var hold: UInt8 = 0
        /// The vibrato: its delay, its count of ticks to turning, and how far it moves the period ($48 to $4A).
        var vibratoDelay: UInt8 = 0
        var vibratoCount: UInt8 = 0
        var vibrato: UInt8 = 0
        /// The reading: what it does, where it is in its list and in its pattern, how many steps its notes last
        /// and are left of this one ($4C to $59).
        var reading = Reading.none
        var list = 0
        var pattern = 0
        var steps: UInt8 = 0
        var stepsLeft: UInt8 = 0
        /// The slide: whether it moves (the routine at $3C), the period it goes to, and its halvings ($5A, $5C).
        var sliding = false
        var target: UInt16 = 0
        var slide: UInt8 = 0
        /// The instrument of its notes: its priority and its place among them ($5D, $5E).
        var notePriority: UInt8 = 0
        var noteInstrument: UInt16 = 0
        /// The instrument's count of envelopes, nought for a sample played once ($60).
        var times: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The song to begin at the tick's end, nought for none ($125C); the song playing, and its priority, and
    /// the song it goes on to ($125E to $1260); and the speed and the count of ticks to the next step ($1262,
    /// $1263).
    private var asked: UInt16 = 0
    private var current: UInt8 = 0
    private var currentPriority: UInt8 = 0
    private var next: UInt8 = 0
    private var speed: UInt8 = 0
    private var speedCount: UInt8 = 0
    /// The songs begun since the song was started, by their numbers (to know an end).
    private var played = InlineArray<2, UInt64>(repeating: 0)

    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// Each song's length, found as the player is made.
    private var lengths: [UInt64?] = []

    /// How long each tick is (see the type's comment).
    static let tickClocks = (0x1BC0 + 1) * 5
    /// A song that has not come to its end in an hour is taken never to; and once the songs played through to
    /// find their lengths have taken four hours in all, the rest are too (only a broken file has so many songs
    /// that never end).
    private static let mostTicks = 100 * 60 * 60
    private static let mostTicksInAll = 4 * mostTicks
    /// The most bytes a voice reads of its list and patterns in a tick before it is taken to have nothing to
    /// play: only a broken file has a list of patterns that are all ended at once (where the driver would read on
    /// through memory).
    private static let mostRead = 1 << 16

    /// The volume all envelopes are bound by ($1256): `Initialize` asks for 255 at a step of 255, and the first
    /// `lbC000626` (from `InitSound`) brings it there; nothing changes it after.
    private static let fullVolume: UInt16 = 255

    /// The table of periods (`lbW000000`): seven octaves, from the lowest, each shifted down by the instrument's
    /// own count.
    static let periodTable: [UInt16] = [
        0xEEE4, 0xE17B, 0xD4D4, 0xC8E1, 0xBD9C, 0xB2F6, 0xA8EC, 0x9F71, 0x967D, 0x8E0B, 0x8612, 0x7E8C,
        0x7772, 0x70BE, 0x6A6A, 0x6471, 0x5ECE, 0x597B, 0x5476, 0x4FB9, 0x4B3F, 0x4706, 0x4309, 0x3F46,
        0x3BB9, 0x385F, 0x3535, 0x3239, 0x2F67, 0x2CBE, 0x2A3B, 0x27DD, 0x25A0, 0x2383, 0x2185, 0x1FA3,
        0x1DDD, 0x1C30, 0x1A9B, 0x191D, 0x17B4, 0x165F, 0x151E, 0x13EF, 0x12D0, 0x11C2, 0x10C3, 0x0FD2,
        0x0EEF, 0x0E18, 0x0D4E, 0x0C8F, 0x0BDA, 0x0B30, 0x0A8F, 0x09F8, 0x0968, 0x08E1, 0x0862, 0x07E9,
        0x0778, 0x070C, 0x06A7, 0x0648, 0x05ED, 0x0598, 0x0548, 0x04FC, 0x04B4, 0x0471, 0x0431, 0x03F5,
        0x03BC, 0x0386, 0x0354, 0x0324, 0x02F7, 0x02CC, 0x02A4, 0x027E, 0x025A, 0x0239, 0x0219, 0x01FB,
    ]

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        guard at >= 0, at + 1 < data.count else { return 0 }
        return UInt16(data[at]) << 8 | UInt16(data[at + 1])
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2))
    }

    /// A place the code at the file's head gives, as a place in the file: its long at `at` less the instruments'
    /// (at byte 2), and 46 (`InitPlayer`, in 32 bits).
    private static func place(_ data: [UInt8], _ at: Int) -> Int {
        Int(Int32(bitPattern: long(data, at) &- long(data, 2) &+ 0x2E))
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): the code at its head, four `move.l #x,y(a5)`, a
    /// `move.w #$FF,d0`, `move.w d0,d1`, a `jsr` and an `rts`.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 0x2E && word(data, 0) == 0x2B7C && word(data, 8) == 0x2B7C && word(data, 0x10) == 0x2B7C
            && word(data, 0x18) == 0x2B7C && long(data, 0x20) == 0x303C_00FF && long(data, 0x24) == 0x3200_4EB9
            && word(data, 0x2C) == 0x4E75
    }

    /// The file's length as `InitPlayer` finds it: past the first $FF from the farthest of the patterns' places
    /// (at least ten) in their table, to its end ($F0FF); nil if there is none.
    private static func findLength(_ data: [UInt8], patterns: Int) -> Int? {
        guard patterns >= 0 else { return nil }
        var at = patterns, farthest: UInt16 = 10
        while at + 1 < data.count {
            let value = word(data, at)
            if value == 0xF0FF { break }
            at += 2
            if value > farthest { farthest = value }
        }
        // (`add.w`: the farthest taken as signed.)
        var scan = patterns + Int(Int16(bitPattern: farthest))
        guard scan >= 0 else { return nil }
        while scan < data.count {
            scan += 1
            if data[scan - 1] == 0xFF { return scan }
        }
        return nil
    }

    /// Reads the file and starts the song asked for (of `songCount`, nought the first).
    init(_ data: [UInt8], song: Int = 0, asWantedTeam: Bool = false) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        self.asWantedTeam = asWantedTeam
        instruments = 0x2E
        songs = Self.place(data, 10)
        patterns = Self.place(data, 0x12)
        samples = Self.place(data, 0x1A)
        let length = Self.findLength(data, patterns: patterns)
        // (`NoFix`: Wanted Team's mending of a Rainbow Islands of 6,802 bytes, whose last song, kept from being
        // heard by lists that end at once, is given the list of its first song's fourth voice for all four.
        // UnExoticA's file is found to be of 6,803, and is not mended, as in UADE: its fifteenth song is silent.)
        if length == 6802, Self.long(data, 3650) == 0x019F_019F {
            for (i, b) in [UInt8]([1, 0xA0, 1, 0xA0, 1, 0xA0, 1, 0xA0]).enumerated() { memory[3650 + i] = b }
        }
        // The songs (`loops`): from the first, those whose first word is under 16; five in Paradroid 90's file
        // of 17,213 bytes, whose sixth is not whole (`SubOK`). (No more than the file holds, nor than 127, the
        // most the driver can name.)
        var count = 0
        while count < 127, songs >= 0, songs + 12 * count + 1 < data.count, Self.word(data, songs + 12 * count) & 0xFFF0 == 0 {
            count += 1
        }
        if length == 17213 { count = min(count, 5) }
        songCount = max(1, count)
        // The samples (`InitPlayer`): of the places in their table, as many as its length (before it, 26 bytes
        // back) says, those not nought.
        let entries = Int(min(4096, Self.long(data, samples - 26) / 4))
        var found = 0
        for e in 0 ..< entries where Self.long(data, samples + 4 * e) != 0 { found += 1 }
        sampleCount = found
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not Steve Turner's music") }
        guard count > 0 else { throw .malformed("it has no songs") }

        // Each song's length, from a playing of it in silence to its end or its stop.
        var budget = Self.mostTicksInAll
        for s in 0 ..< songCount {
            self.song = s
            start()
            var none = TFMXSilentOutput()
            var ticks = 0
            while endings == 0, stops == 0, ticks < min(Self.mostTicks, budget) {
                _ = run(&none)
                ticks += 1
            }
            budget -= ticks
            lengths.append(endings > 0 || stops > 0 ? UInt64(ticks) * UInt64(Self.tickClocks) : nil)
        }
        self.song = max(0, min(songCount - 1, song))
        lengthClocks = lengths[self.song]
        start()
    }

    deinit { memory.deallocate() }

    /// `InitSound`: the voices made ready as the game made them (`lbC0005C2`; but for Wanted Team's player), and
    /// the song begun.
    private mutating func start() {
        voices = .init(repeating: Voice())
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        asked = 0
        current = 0
        currentPriority = 0
        next = 0
        speed = 0
        speedCount = 0
        played = .init(repeating: 0)
        endings = 0
        stops = 0
        var none = TFMXSilentOutput()
        if !asWantedTeam {
            for v in 0 ..< 4 { ready(v, &none) }
        }
        begin(song: UInt16(song + 1), &none)
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        lengthClocks = lengths[song]
        start()
    }

    /// `ChangeVolume`: the envelope's volume over four, seven bits of it, times EaglePlayer's volume, 64, over 64.
    private mutating func writeVolume(_ v: Int, _ level: UInt16) {
        volumes[v] = (level >> 2) & 0x7F
    }

    /// Runs the player for a tick (`Interrupt`: `lbC0006BE` and then `lbC000626`), telling `output` what Paula is
    /// to do, in the order the player tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        play(&output)
        afterwards(&output)
        if stops == 0, asked == 0 {
            var quiet = true
            for v in 0 ..< 4 where voices[v].reading != .none || voices[v].envelope != .none { quiet = false }
            if quiet { stops += 1 }
        }
        return 10
    }

    /// `lbC0006BE`: each voice's sound effect to come counted, its reading, envelope, periods and slide moved;
    /// and the count of ticks to the next step.
    private mutating func play<Output: TFMXOutput>(_ output: inout Output) {
        speedCount &-= 1
        for v in 0 ..< 4 {
            voices[v].laterCount &-= 1
            if voices[v].laterCount == 0, Int16(bitPattern: voices[v].later) >= 0 {
                if voices[v].laterPriority >= voices[v].priority {
                    begin(v, voices[v].later, priority: voices[v].laterPriority, &output)
                }
                voices[v].laterCount = 0
                voices[v].laterPriority = 0
                voices[v].later = 0xFFFF
            }
            switch voices[v].reading {
            case .none: break
            case .list: readList(v, &output)
            case .waiting: wait(v, &output)
            }
            envelope(v, &output)
            movePeriods(v)
            if voices[v].sliding { slide(v) }
        }
        if speedCount == 0 {
            // (`$1261`, which nothing sets, and then the speed.)
            speedCount = speed
        }
    }

    /// `lbC000626`: the song asked for begun; or else the sound effects asked for on each voice begun or kept for
    /// later. (Its fading, from 255 to 255, does nothing.)
    private mutating func afterwards<Output: TFMXOutput>(_ output: inout Output) {
        if asked != 0 {
            begin(song: asked, &output)
            asked = 0
            return
        }
        for v in 0 ..< 4 {
            let effect = voices[v].effect
            guard Int16(bitPattern: effect) >= 0 else { continue }
            let priority = byte(instruments &+ Int(effect) &+ 0x1E)
            if voices[v].effectFlag == 0 {
                if priority >= voices[v].priority { begin(v, effect, priority: priority, &output) }
            } else if priority >= voices[v].laterPriority {
                voices[v].laterCount = voices[v].effectFlag
                voices[v].laterPriority = voices[v].effectPriority
                voices[v].later = effect
            }
            voices[v].effectFlag = 0
            voices[v].effectPriority = 0
            voices[v].effect = 0xFFFF
        }
    }

    /// `lbC000746`: a song (of its number's seven bits) begun, if its priority is no less than the one playing's:
    /// its speed taken, and each voice it has a list for made ready and set to read it.
    private mutating func begin<Output: TFMXOutput>(song number: UInt16, _ output: inout Output) {
        let entry = songs &+ Int(UInt32((number & 0x7F) &- 1) &* 12)
        let priority = byte(entry)
        guard priority >= currentPriority else { return }
        current = UInt8(truncatingIfNeeded: number)
        currentPriority = priority
        speed = byte(entry &+ 1)
        speedCount = speed
        next = byte(entry &+ 2)
        for v in 0 ..< 4 {
            let list = word(entry &+ 4 &+ 2 * v)
            guard list != 0 else { continue }
            voices[v].list = songs &+ Int(Int16(bitPattern: list))
            ready(v, &output)
            voices[v].reading = .list
        }
        played[Int(number & 0x7F) >> 6] |= 1 << UInt64(number & 0x3F)
    }

    /// `lbC0005F0`: a voice made ready: no sound effect asked for, no instrument, nothing done, no slide, and
    /// turned off.
    private mutating func ready<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        voices[v].effectFlag = 0
        voices[v].effectPriority = 0
        voices[v].effect = 0xFFFF
        voices[v].laterCount = 0
        voices[v].laterPriority = 0
        voices[v].later = 0xFFFF
        voices[v].number = 0
        voices[v].priority = 0
        voices[v].instrumentOffset = 0xFFFF
        voices[v].reading = .none
        voices[v].envelope = .none
        voices[v].periods = .none
        voices[v].sliding = false
        voices[v].slide = 0
        output.off(v)
    }

    // MARK: - Reading the lists and patterns

    /// `lbC0007A4`: the voice's next pattern read from its list, or its end ($FE), or the song's ($FF).
    private mutating func readList<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        var read = 0
        while read < Self.mostRead {
            let number = byte(voices[v].list)
            voices[v].list &+= 1
            read += 1
            if number == 0xFE {
                voices[v].reading = .none
                return
            }
            if number == 0xFF {
                songEnd()
                return
            }
            // (`lbC0007F6`: its place in the table, a signed word from the table's.)
            let place = patterns &+ Int(Int16(bitPattern: word(patterns &+ 2 * Int(number))))
            if readPattern(v, from: place, &read, &output) { return }
        }
        voices[v].reading = .none
    }

    /// `lbC0007C6`: every voice's reading stopped, and the song to go on to asked for: the one playing again
    /// for Wanted Team's player, as for one whose number has its top bit set, and else the one it names, if any.
    private mutating func songEnd() {
        for v in 0 ..< 4 { voices[v].reading = .none }
        currentPriority = 0
        let number = asWantedTeam || current & 0x80 != 0 ? current : next
        if number != 0 {
            asked = UInt16(number)
            // (Going back to a song played is the end; Wanted Team's player tells EaglePlayer so at every end.)
            if asWantedTeam || played[Int(number & 0x7F) >> 6] & 1 << UInt64(number & 0x3F) != 0 { endings += 1 }
        }
        current = 0
    }

    /// `lbC000806`: the voice's pattern read from `place`, to its next note, instrument, rest or end. True if it
    /// has come to one that it waits after; false for the pattern's end.
    private mutating func readPattern<Output: TFMXOutput>(_ v: Int, from place: Int, _ read: inout Int, _ output: inout Output) -> Bool {
        var at = place
        while read < Self.mostRead {
            let what = byte(at)
            at &+= 1
            read += 1
            switch what {
            case 0 ..< 0x80:
                // A note (`lbC000882`), if its instrument's priority is no less than the voice's: the
                // instrument begun, and its period and slide.
                voices[v].pattern = at
                if voices[v].notePriority >= voices[v].priority {
                    begin(v, voices[v].noteInstrument, priority: voices[v].notePriority, &output)
                    let index = Int(what)
                    note(v, index < Self.periodTable.count ? Self.periodTable[index] : 0)
                }
                waitFrom(v)
                return true
            case 0x80 ..< 0xB0:
                voices[v].steps = what &- 0x7F
            case 0xB0 ..< 0xD0:
                // An instrument begun with no note (`lbC000862`), if its priority is no less than the voice's.
                voices[v].pattern = at
                let offset = UInt16(what &- 0xB0) &* 0x30
                let priority = byte(instruments &+ Int(offset) &+ 0x1E)
                if priority >= voices[v].priority { begin(v, offset, priority: priority, &output) }
                waitFrom(v)
                return true
            case 0xD0 ..< 0xF0:
                // The notes' instrument (`lbC000842`).
                voices[v].noteInstrument = UInt16(what &- 0xD0) &* 0x30
                voices[v].notePriority = byte(instruments &+ Int(voices[v].noteInstrument) &+ 0x1E)
            case 0xF0 ..< 0xF9:
                voices[v].slide = what &- 0xF0
            case 0xFE:
                // A rest.
                voices[v].pattern = at
                waitFrom(v)
                return true
            default:
                return false
            }
        }
        return false
    }

    /// `lbC0008AC`: the voice's count of steps taken from its notes' length.
    private mutating func waitFrom(_ v: Int) {
        voices[v].stepsLeft = voices[v].steps
        voices[v].reading = .waiting
    }

    /// `lbC0008BC`: on a step's first tick the count of steps down by one, and at nought (or on any tick, once
    /// it is nought) the pattern read on (`lbC000802`).
    private mutating func wait<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        if speedCount != 0 {
            guard voices[v].stepsLeft == 0 else { return }
        } else {
            voices[v].stepsLeft &-= 1
            guard voices[v].stepsLeft == 0 else { return }
        }
        var read = 0
        if !readPattern(v, from: voices[v].pattern, &read, &output) {
            readList(v, &output)
        }
    }

    // MARK: - Instruments

    /// `lbC0008D6`: the instrument at `offset` among them begun on the voice at `priority`: its sample told
    /// Paula (but for one whose sample's number is negative, the driver's noise, which the game's driver makes
    /// and Wanted Team's leaves out, `lbC000C5E`), the voice to be turned off, and its periods begun.
    private mutating func begin<Output: TFMXOutput>(_ v: Int, _ offset: UInt16, priority: UInt8, _ output: inout Output) {
        voices[v].instrumentOffset = offset
        voices[v].priority = priority
        voices[v].number = UInt8(truncatingIfNeeded: offset / 0x30 &+ 1)
        // (`adda.w`: the place a signed word.)
        let instrument = instruments &+ Int(Int16(bitPattern: offset))
        voices[v].instrument = instrument
        voices[v].envelope = .stopping
        voices[v].periods = .none
        voices[v].sliding = false
        let sample = Int8(bitPattern: byte(instrument &+ 0x1F))
        if sample >= 0 {
            let place = samples &+ Int(Int32(bitPattern: long(samples &+ 4 * Int(sample))))
            output.takeNextBuffer(v, start: place &+ 2, length: word(place) >> 1)
        }
        // `lbC000AD0`: the instrument's parts copied (to three), and the first begun.
        voices[v].vibratoDelay = byte(instrument &+ 0x2C)
        voices[v].vibrato = 0
        voices[v].partNumber = 1
        voices[v].part = 0
        voices[v].partData = 0
        let parts = Int(byte(instrument &+ 0x2B))
        for p in 0 ..< min(parts, 3) {
            let from = instrument &+ 10 * p
            voices[v].parts[p].period = word(from)
            voices[v].parts[p].start = word(from)
            voices[v].parts[p].step = word(from &+ 2)
            voices[v].parts[p].count = byte(from &+ 5)
        }
        voices[v].periods = .part
    }

    /// `lbC000C0E`: the note's period, slid to from the last note's if the voice slides.
    private mutating func note(_ v: Int, _ period: UInt16) {
        if voices[v].slide != 0 {
            voices[v].parts[0].period = voices[v].target
            voices[v].target = period
            voices[v].sliding = true
            voices[v].parts[0].start = period
        } else {
            voices[v].target = period
            voices[v].parts[0].period = period
            voices[v].parts[0].start = period
            voices[v].sliding = false
        }
    }

    /// `lbC000C3E`: the first part's period moved toward the note's by the distance halved so many times, and
    /// when that is nought, put there.
    private mutating func slide(_ v: Int) {
        let distance = Int16(bitPattern: voices[v].target &- voices[v].parts[0].period) >> Int16(voices[v].slide & 63)
        if distance == 0 {
            voices[v].parts[0].period = voices[v].target
            voices[v].sliding = false
        } else {
            voices[v].parts[0].period &+= UInt16(bitPattern: distance)
        }
    }

    // MARK: - Envelopes

    /// The voice's envelope moved on, from `lbC000942` to `lbC000A6E`.
    private mutating func envelope<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let instrument = voices[v].instrument
        switch voices[v].envelope {
        case .none:
            break
        case .stopping:
            output.off(v)
            voices[v].envelope = .starting
        case .starting:
            // (`lbC000952`: the volume nought, the voice on; for a sample played once, its envelope from the
            // full volume, gone through once, and for the rest from nought, so many times.)
            volumes[v] = 0
            output.on(v)
            let times = byte(instrument &+ 0x20)
            voices[v].again = times
            voices[v].times = times
            if times == 0 {
                voices[v].level = Self.fullVolume
                writeVolume(v, Self.fullVolume)
                voices[v].again &+= 1
            } else {
                voices[v].level = 0
            }
            envelopeBegun(v)
        case .looping:
            if voices[v].times == 0 { output.takeNextBuffer(v, start: silenceAt, length: 1) }
            voices[v].envelope = .attack
            attack(v)
        case .attack:
            attack(v)
        case .decay:
            step(v)
            voices[v].envelopeCount &-= 1
            if voices[v].envelopeCount == 0 {
                // (`lbC0009FC`.)
                voices[v].envelopeCount = word(instrument &+ 0x26)
                voices[v].rate = byte(instrument &+ 0x28)
                voices[v].envelope = .sustain
                turnTremolo(v)
            }
        case .sustain:
            step(v)
            voices[v].envelopeCount &-= 1
            if voices[v].envelopeCount == 0 {
                voices[v].rate = byte(instrument &+ 0x2A)
                voices[v].envelope = .release
            } else {
                voices[v].tremolo &-= 1
                if voices[v].tremolo == 0 { turnTremolo(v) }
            }
        case .release:
            step(v)
            guard voices[v].level == 0 else { return }
            // (`lbC000A4A`: gone through again, or the instrument that follows begun, or the voice silenced.)
            voices[v].again &-= 1
            if voices[v].again != 0 {
                voices[v].level = 0
                envelopeBegun(v)
                return
            }
            let follower = byte(instrument &+ 0x2F)
            if follower != 0 {
                // (`ext.w`, less one, times 48: a word.)
                let offset = (UInt16(bitPattern: Int16(Int8(bitPattern: follower))) &- 1) &* 0x30
                begin(v, offset, priority: byte(instruments &+ Int(Int16(bitPattern: offset)) &+ 0x1E), &output)
                return
            }
            volumes[v] = 0
            output.off(v)
            voices[v].envelope = .none
            voices[v].periods = .none
            voices[v].sliding = false
            voices[v].number = 0
            voices[v].priority = 0
            voices[v].instrumentOffset = 0xFFFF
        }
    }

    /// `lbC000990`: the envelope's rise begun, on the next tick.
    private mutating func envelopeBegun(_ v: Int) {
        voices[v].envelopeCount = UInt16(byte(voices[v].instrument &+ 0x21))
        voices[v].rate = byte(voices[v].instrument &+ 0x22)
        voices[v].envelope = .looping
    }

    /// `lbC0009CE`: the rise, for so many ticks, and then the fall begun.
    private mutating func attack(_ v: Int) {
        step(v)
        voices[v].envelopeCount &-= 1
        if voices[v].envelopeCount == 0 {
            voices[v].envelopeCount = UInt16(byte(voices[v].instrument &+ 0x23))
            voices[v].rate = byte(voices[v].instrument &+ 0x24)
            voices[v].envelope = .decay
        }
    }

    /// `lbC000A10`: the tremolo's count taken again, and its step turned round.
    private mutating func turnTremolo(_ v: Int) {
        voices[v].tremolo = byte(voices[v].instrument &+ 0x29)
        voices[v].rate = 0 &- voices[v].rate
    }

    /// `lbC000AA6`: the volume moved by the step, kept from nought to the full volume, and told Paula.
    private mutating func step(_ v: Int) {
        var level = Int16(Int8(bitPattern: voices[v].rate)) &+ Int16(bitPattern: voices[v].level)
        if level < 0 {
            level = 0
        } else if level > Int16(Self.fullVolume) {
            level = Int16(Self.fullVolume)
        }
        voices[v].level = UInt16(level)
        writeVolume(v, voices[v].level)
    }

    // MARK: - Periods

    /// The voice's part `part` (from the place `D4`), if it is one of its three.
    private func partIndex(_ v: Int) -> Int? {
        let index = Int(voices[v].part) / 8
        return index < 3 ? index : nil
    }

    /// The voice's periods moved on, from `lbC000B22` to `lbC000BB8`.
    private mutating func movePeriods(_ v: Int) {
        enum Next { case part, inner, hold, holding, stepping }
        var next: Next
        switch voices[v].periods {
        case .none: return
        case .part: next = .part
        case .holding: next = .holding
        case .stepping: next = .stepping
        }
        let instrument = voices[v].instrument
        // (Each way through ends in `lbC000B3C`, which returns; the count is only a guard.)
        for _ in 0 ..< 8 {
            let data = instrument &+ Int(voices[v].partData)
            switch next {
            case .part:
                voices[v].outer = byte(data &+ 4)
                next = .inner
            case .inner:
                if let p = partIndex(v) { voices[v].inner = voices[v].parts[p].count } else { voices[v].inner = 0 }
                next = .hold
            case .hold:
                voices[v].hold = byte(data &+ 6)
                voices[v].periods = .holding
                next = .holding
            case .holding:
                vibrate(v)
                voices[v].hold &-= 1
                if voices[v].hold == 0 { voices[v].periods = .stepping }
                return
            case .stepping:
                if let p = partIndex(v) {
                    voices[v].parts[p].period &+= voices[v].parts[p].step
                    voices[v].parts[p].step &+= UInt16(bitPattern: Int16(Int8(bitPattern: byte(data &+ 7))))
                }
                voices[v].inner &-= 1
                if voices[v].inner != 0 {
                    next = .hold
                    continue
                }
                // (`lbC000B78`: the part's period put back, its step turned round, its count less one if over
                // eight.)
                let flags = byte(data &+ 8)
                if let p = partIndex(v) {
                    if flags & 1 != 0 { voices[v].parts[p].period = voices[v].parts[p].start }
                    if flags & 2 != 0 { voices[v].parts[p].step = 0 &- voices[v].parts[p].step }
                    if flags & 4 != 0, voices[v].parts[p].count > 8 { voices[v].parts[p].count &-= 1 }
                }
                voices[v].outer &-= 1
                if voices[v].outer != 0 {
                    next = .inner
                    continue
                }
                // The next part, or after the last the first.
                if voices[v].partNumber == byte(instrument &+ 0x2B) {
                    voices[v].partNumber = 1
                    voices[v].part = 0
                    voices[v].partData = 0
                } else {
                    voices[v].partNumber &+= 1
                    voices[v].part &+= 8
                    voices[v].partData &+= 10
                }
                next = .part
            }
        }
    }

    /// `lbC000BC4`: the vibrato, after its delay, added to the part's period, turning every so many ticks and
    /// growing by one each second turn to its depth; and the period, shifted down, told Paula.
    private mutating func vibrate(_ v: Int) {
        let instrument = voices[v].instrument
        let speed = byte(instrument &+ 0x2D)
        let p = partIndex(v)
        if speed != 0 {
            if voices[v].vibratoDelay != 0 {
                voices[v].vibratoDelay &-= 1
            } else {
                let moved = Int8(bitPattern: voices[v].vibrato)
                if let p { voices[v].parts[p].period &+= UInt16(bitPattern: Int16(moved)) }
                voices[v].vibratoCount &-= 1
                if voices[v].vibratoCount == 0 {
                    voices[v].vibratoCount = speed
                    var turned = 0 &- moved
                    if turned >= 0, turned < Int8(bitPattern: byte(instrument &+ 0x2E)) { turned &+= 1 }
                    voices[v].vibrato = UInt8(bitPattern: turned)
                }
            }
        }
        let shift = byte(instrument &+ 0x25) & 63
        var period: UInt16 = 0
        if let p { period = voices[v].parts[p].period }
        periods[v] = shift < 16 ? period >> UInt16(shift) : 0
    }

    /// Paula's period for the voice as the player has left it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice as the player has left it.
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }
    /// What the player last gave Paula's period register for the voice.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Steve Turner's music, played on Paula by `PaulaTickRenderer`.
extension SteveTurnerPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Steve Turner")
        info.detail = "Graftgold's driver; \(sampleCount) sample\(sampleCount == 1 ? "" : "s")"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -17.8 dB.)
    var gain: Float { 0.22 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
