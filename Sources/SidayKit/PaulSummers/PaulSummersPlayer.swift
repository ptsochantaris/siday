// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Paul Summers's music ("Paul Summers player module V1.2 (2 Nov 2003)"),
// carried by UADE as players/PaulSummers, and after the source of its version before ("V1.1 (25 Jan 2002)"), which
// UADE also carries as amigasrc/players/wanted_team/PaulSummers/src/Paul Summers_v2.asm. Where the two differ, the
// binary is followed: the addresses given are of its code hunk, the labels the source's. The game drivers in the
// files themselves were read too, where the player departs from them.

/// Paul Summers's and Mike Chilton's music as their games carried it on the Amiga (Fighting Soccer, P47
/// Thunderbolt, Postman Pat, Everton F.C. Intelligensia): each file is the game's music driver, its 68000 code and
/// its data, from its address nought. The player finds what it needs in the code: from byte 650, the place of the
/// table of the samples (after the first `LEA d(PC),A2`), of the songs (after the first `MULU #20,D0`, by the
/// `LEA` after it) and of the periods (by the `LEA` after the next `NEG.L D0`). A song is twenty bytes: the places
/// of its four voices' streams, from the songs' table, and a long whose low word is the CIA's timer for its ticks
/// (nought for the player's own) and whose top byte changes its tempo (see below).
///
/// A voice's stream is of bytes: a note (from nought to $7F), whose instrument is the one of the voice's table of
/// instruments whose range takes it, followed by its length in ticks; or a command, from $80: a rest and its
/// length ($80), a jump, a call and its return ($81 to $83: the first two with a long, its distance from itself),
/// a loop of so many times and its end ($84, with a word, and $85), the table of instruments ($86, and its
/// distance), the top byte of the next length ($87), a slide of the pitch ($88, and $F8 and $F7 after it), its
/// depth ($89), the volume ($8E), and the voice's end ($8F). An instrument is fourteen bytes: the distance from it
/// to its sample, the sample's length in words, the note its sample is of, and the lowest and highest note it
/// takes. The periods are longs, of which a word is the period and the other its fraction (for the slides), from
/// the note nought down.
///
/// This is the player itself, as UADE runs it: what it tells Paula is what that player tells her, tick by tick
/// (but see `wantedTeamsWay`). It is run by DeliTracker's timer, which it sets to the song's (or which UADE runs
/// from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second and a little less); and a song may
/// play an extra tick every so many (a top byte from 1 to $7F), or leave one out (from $80, every so many less one).
/// A note's sample is begun (its period, length and place told Paula, `DMAWait` waited for, its voice turned on,
/// and the wait again: nine of the beam's lines each) and then a sample of silence told her as what follows it, so
/// that it is heard once; it ends with its length, as the voice is turned off. Each of the player's writes is told
/// Paula at its moment in the tick (`TFMXOutput.timed(at:)`), near where it falls in UADE's dumps.
///
/// Wanted Team's player tells Paula the silence after a note's sample on the fourth voice only if a bit of what it
/// keeps of the first voice's room for its calls is clear (it means to look at a bit of its own for each voice,
/// but takes the fourth's from the wrong place), which it is not as UADE has it, and so that voice's samples go
/// round; and it leaves out a tick of a song that asks for it, which Everton's driver, the only one that has the
/// change, does not (it looks at the change again where it means its count). Both are done only if asked for
/// (`wantedTeamsWay`), as the games' own drivers do not: Postman Pat's tells Paula a word of silence after every
/// sample, and the others the sample's first word (by its audio interrupt, or at once after turning the voice on),
/// which in each of their samples is nought.
///
/// A song comes to its end when every voice has come to its end, as the player says it does (only for a song of
/// four voices), and stops; or, here, once every voice has either come to its end or jumped back to a place it has
/// been. Where the player would read outside the file it reads nought; a call or loop deeper than a voice's room
/// for them (128 bytes) is not kept; and a voice that reads 65,536 bytes in a tick without coming to a note's
/// length, or whose slide's step would never come to its end, is taken to have come to its end (only a broken file
/// has one, which the player would go on with for ever).
struct PaulSummersPlayer: ~Copyable {
    /// The file, the player's sample of silence (`lbL000D20`) after it, and what follows them, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where the samples' table, the songs and the periods are, as the player finds them.
    let samplesAt: Int
    let songsAt: Int
    let periodsAt: Int
    let songCount: Int
    private(set) var song = 0
    /// Whether the fourth voice's samples go round, and a tick is left out, as in Wanted Team's player (see the
    /// type's comment).
    let wantedTeamsWay: Bool

    /// What the player keeps for each voice (`lbL00000A`, 32 bytes each).
    private struct Voice {
        /// Where its stream is (0), its room for calls and loops (4, as a count of longs, and the longs), the
        /// note's ticks to come (8), its flags (10: bit 7 its end, 6 its end told Paula, 5 a note's ticks being
        /// counted, 1 a rest's, 0 a slide going), the top byte of the next length (12).
        var stream = 0
        var depth = 0
        var room = InlineArray<32, Int>(repeating: 0)
        var length: UInt16 = 0
        var flags: UInt8 = 0
        var lengthHigh: UInt16 = 0
        /// The slide: where its steps are read (14), its count of ticks (18), its step (20), its depth and the size of
        /// its steps (22, 23), and the note it is of, from the instrument's own (24).
        var slideAt = 0
        var slideCount: UInt16 = 0
        var slideStep: UInt8 = 0
        var slideDepth: UInt8 = 0
        var slideSize: UInt8 = 0
        var note = 0
        /// The table of instruments (28).
        var instruments = PaulSummersPlayer.nowhere
        /// (Not the player's: whether the voice has jumped back since the song began or last came to its end.)
        var wentBack = false
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The player's song (`lbL000000`'s first word, its top bit set for a song to be begun), and its tempo's change
    /// and count (`L4EA`).
    private var songWord: UInt16 = 0
    private var tempo: UInt8 = 0
    private var tempoCount: UInt8 = 0
    /// Which voices the song has (those whose places are in the file), and the song's timer.
    private var started: UInt8 = 0
    private var timer = 0
    /// What Paula's period and volume registers were last given, for each voice, and what they held as the tick just
    /// run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told at their moments).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start (kept within a whole number of the beam's lines, of
    /// 227 clocks and of 227.5: a count of every clock would outgrow a whole number in a browser); and how far into
    /// the tick the player's next write falls.
    private var clock = 0
    private var moment = 0

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    private var songLengths: [UInt64?] = []
    private var stopped = false

    /// A place that is nowhere in the file: where a voice's table of instruments is before it is given one (the
    /// player's nought, Amiga's memory at nought, which is not the file's).
    static let nowhere = -0x4000_0000
    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (near its dumps): the first after the
    /// interrupt begins (a guess: only the distances between them are heard), how long the song's beginning takes,
    /// and each voice's tick before its writes.
    static let firstWrite = 300
    static let beginClocks = 460
    static let voiceClocks = 240

    /// When `DMAWait` begun at the moment it is in the tick returns: once the beam's line (227 of Paula's clocks) has
    /// changed nine times, the first at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 80 - clock
    }

    /// UADE's timer for a player that sets none.
    static let defaultTimer = 0x376B
    /// A song that has not come to its end in an hour is taken never to; and once the songs played through to
    /// find their lengths have taken four hours in all, the rest are too.
    private static let mostTicks = 50 * 60 * 60
    private static let mostTicksInAll = 4 * mostTicks
    /// The most bytes a voice reads in a tick, and the most steps of a slide's step, before it is taken to have
    /// come to its end (see the type's comment).
    private static let mostRead = 1 << 16
    private static let mostSteps = 256

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: Int) -> Int {
        Int(Int32(bitPattern: UInt32(word(at)) << 16 | UInt32(word(at &+ 2))))
    }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        at >= 0 && at < data.count - 1 ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 { UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2)) }

    /// The place a `LEA d(PC)`'s distance at `at` points to.
    private static func target(_ data: [UInt8], _ at: Int) -> Int { at + Int(Int16(bitPattern: word(data, at))) }

    /// Where the next word of a value is, from `at` (an even place) on; nil if there is none.
    private static func find(_ data: [UInt8], _ value: UInt16, from at: Int) -> Int? {
        var at = at
        while at + 1 < data.count {
            if word(data, at) == value { return at }
            at += 2
        }
        return nil
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`, $2A0): longer than 3,000 bytes, with, within ten words of
    /// byte 650, either `MOVE #$2700,SR` (and after it an `RTE` and a `LEA d(PC)`, after which the next `LEA d(PC)`
    /// is of the file's start), or a `LEA d(PC)` and four `MOVE.B #$88,d(A0)` (and the next `LEA d(PC)` likewise).
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count > 3000 else { return false }
        var at = 650
        for _ in 0 ..< 10 {
            if long(data, at) == 0x46FC_2700 {
                // An `RTE` and a `LEA` after it, before a long of nought.
                while true {
                    guard long(data, at) != 0 else { return false }
                    at += 2
                    guard word(data, at - 2) == 0x4E73 else { continue }
                    at += 2
                    if word(data, at - 2) == 0x41FA { break }
                }
                return leaOfStart(data, from: at)
            }
            if word(data, at) == 0x41FA {
                at += 4
                for _ in 0 ..< 4 {
                    guard long(data, at) == 0x117C_0088 else { return false }
                    at += 6
                }
                return leaOfStart(data, from: at)
            }
            at += 2
        }
        return false
    }

    /// The next `LEA d(PC)` from `at` on is of the file's start.
    private static func leaOfStart(_ data: [UInt8], from at: Int) -> Bool {
        guard let lea = find(data, 0x41FA, from: at) else { return false }
        return target(data, lea + 2) == 0
    }

    /// Reads the file and starts the song asked for (of `songCount`, nought the first, which is the player's 1).
    init(_ data: [UInt8], song: Int = 0, wantedTeamsWay: Bool = false) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        self.wantedTeamsWay = wantedTeamsWay
        // `InitPlayer` ($308): Fighting Soccer's song that it puts right, and the parts found from byte 650.
        if data.count > 0x36B0, Self.word(data, 13836) == 0xF87F {
            memory[13836] = 0
            memory[13837] = 0
        }
        var samples = 0, songs = 0, periods = 0, count = 0
        var found = false
        if let lea = Self.find(data, 0x45FA, from: 650), let mulu = Self.find(data, 0xC0FC, from: lea + 2) {
            samples = Self.target(data, lea + 2)
            songs = Self.target(data, mulu + 6)
            if let neg = Self.find(data, 0x4480, from: mulu + 6) {
                periods = Self.target(data, neg + 4)
                found = true
            }
            // The songs: as many as fit between the songs' table and the samples', or as the code compares with
            // (the word before the `MULU`'s), less the first.
            let between = samples - songs
            // (The remainder of the player's division would be in its count's top word: none of UnExoticA's has one.)
            count = between >= 0 ? between / 20 : Int(Self.word(data, mulu - 6))
        }
        samplesAt = samples
        songsAt = songs
        periodsAt = periods
        songCount = max(1, min(15, count - 1))
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Paul Summers file") }
        guard found, count > 1 else { throw .malformed("its songs or periods are not where the player finds them") }

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
            songLengths.append(endings > 0 ? UInt64(ticks - 1) * UInt64(tickClocks) : nil)
        }
        self.song = max(0, min(songCount - 1, song))
        lengthClocks = songLengths[self.song]
        start()
    }

    deinit { memory.deallocate() }

    /// The length of the song's ticks: its timer's, or UADE's own.
    var tickClocks: Int { (timer + 1) * 5 }

    /// `InitSound` ($380) and `Init` ($77A): the voices as nothing, and the song to be begun on the first tick; its
    /// timer and its tempo's change.
    private mutating func start() {
        voices = .init(repeating: Voice())
        for v in 0 ..< 4 { voices[v].flags = 0x88 }
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = periods
        volumesBefore = volumes
        clock = 0
        endings = 0
        stops = 0
        stopped = false
        let number = song + 1
        songWord = UInt16(truncatingIfNeeded: number) &+ 0xFF00
        let entry = songsAt &+ 20 &* number
        let rate = long(entry &+ 16)
        timer = rate & 0xFFFF == 0 ? Self.defaultTimer : rate & 0xFFFF
        tempo = UInt8(truncatingIfNeeded: rate >> 24)
        tempoCount = UInt8(truncatingIfNeeded: rate >> 16)
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        lengthClocks = songLengths[song]
        start()
    }

    // MARK: - Playing

    private mutating func writePeriod<Output: TFMXOutput>(_ v: Int, _ period: UInt16, _ output: inout Output) {
        periods[v] = period
        output.writePeriod(v, period)
    }

    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume
        output.writeVolume(v, volume)
    }

    /// Paula's location and length registers, told a place and a length: silence for a place outside the file.
    private func place<Output: TFMXOutput>(_ v: Int, _ at: Int, _ length: UInt16, _ output: inout Output) {
        output.takeNextBuffer(v, start: at >= 0 && at < fileSize ? at : silenceAt, length: length)
    }

    /// `lbC000768` ($A78): the period's long for a note, and the next note's (from the note nought down).
    private func periodLongs(_ note: Int) -> (Int, Int) {
        let at = periodsAt &+ Int(Int32(truncatingIfNeeded: note) &* -4)
        return (long(at), long(at &+ 4))
    }

    /// Runs the player for a tick (`Interrupt`), telling `output` what Paula is to do, in the order the player tells
    /// her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        moment = Self.firstWrite
        defer { clock = (clock + tickClocks) % 103_285 }
        // ($7BE) The tempo's change: a tick played twice every so many, or one left out.
        var times = 1
        if tempo != 0 {
            if Int8(bitPattern: tempo) < 0 {
                if tempoCount != 0 {
                    tempoCount &+= 1
                } else {
                    tempoCount = tempo
                    // (The games' drivers look at the change again where they mean its count, and never leave out.)
                    if wantedTeamsWay { times = 0 }
                }
            } else if tempoCount != 0 {
                tempoCount &-= 1
            } else {
                tempoCount = tempo
                times = 2
            }
        }
        for _ in 0 ..< times { play(&output) }
        // (Not the player's: the song's end, once every voice has come to its end or gone back; once it has begun.)
        guard Int16(bitPattern: songWord) >= 0 else { return 20 }
        var round = true, ended = true
        for v in 0 ..< 4 where started & 1 << UInt8(v) != 0 && voices[v].flags & 0x80 == 0 {
            ended = false
            if !voices[v].wentBack { round = false }
        }
        if !stopped, round {
            endings += 1
            if ended {
                stopped = true
                stops += 1
            }
            for v in 0 ..< 4 { voices[v].wentBack = false }
        }
        return Int((UInt64(tickClocks) * 1000 + 1_773_447) / 3_546_895)
    }

    /// `lbC000408` ($7F4): the song begun, if it is to be, and each voice's tick.
    private mutating func play<Output: TFMXOutput>(_ output: inout Output) {
        if Int16(bitPattern: songWord) < 0 {
            output.timed(at: moment)
            moment += Self.beginClocks
            for v in 0 ..< 4 { output.off(v) }
            songWord &= 15
            let entry = songsAt &+ 20 &* Int(songWord)
            started = 0
            for v in 0 ..< 4 {
                voices[v].flags = 0x88
                let distance = long(entry &+ 4 &* v)
                // (A distance of nought, or Fighting Soccer's $1EF8, or one to before the file, is no voice.)
                let at = songsAt &+ distance
                if distance != 0, distance != 0x1EF8, at > 0 {
                    voices[v].stream = at
                    voices[v].flags = 1
                    voices[v].length = 0
                    voices[v].lengthHigh = 0
                    started |= 1 << UInt8(v)
                }
                voices[v].depth = 0
            }
            for v in 0 ..< 4 { writeVolume(v, 0, &output) }
            for v in 0 ..< 4 { output.off(v) }
        }
        for v in 0 ..< 4 { tick(v, &output) }
    }

    /// A voice's tick ($8A6 to $A60).
    private mutating func tick<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        moment += Self.voiceClocks
        output.timed(at: moment)
        if voices[v].flags & 0x80 != 0 {
            // Its end: the voice turned off once.
            if voices[v].flags & 0x40 == 0 {
                voices[v].flags |= 0x40
                output.off(v)
            }
            return
        }
        var reading = voices[v].flags & 0x20 == 0
        var count = 0
        while true {
            if reading {
                // ($8CC) The voice turned off, unless it rests; and its stream read to a note's length.
                if voices[v].flags & 0x02 == 0 { output.off(v) }
                voices[v].flags &= ~0x23
                guard read(v, &count, &output) else { return }
            }
            // ($99C) The note's ticks counted: none, and the stream is read on.
            if voices[v].length == 0 {
                reading = true
                count += 1
                if count > Self.mostRead {
                    voices[v].flags = 0xC8
                    return
                }
                continue
            }
            break
        }
        voices[v].length &-= 1
        if voices[v].length == 0 {
            voices[v].flags &= 0xDC
            output.off(v)
        }
        // ($9B6) The slide, every so many ticks.
        guard voices[v].flags & 0x01 != 0 else { return }
        if voices[v].slideCount != 0 {
            voices[v].slideCount &-= 1
            if voices[v].slideCount != 0 { return }
        }
        slide(v, &output)
    }

    /// $8EE to $996: the stream read to a note's or a rest's length. False if the voice has come to its end.
    private mutating func read<Output: TFMXOutput>(_ v: Int, _ count: inout Int, _ output: inout Output) -> Bool {
        var at = voices[v].stream
        while true {
            count += 1
            if count > Self.mostRead {
                voices[v].flags = 0xC8
                return false
            }
            let value = byte(at)
            let from = at
            at &+= 1
            if value < 0x80 {
                note(v, Int(value), at, &output)
                return true
            }
            switch value & 15 {
            case 0:
                // A rest: the voice turned off, and the rest's length.
                voices[v].flags |= 0x02
                output.off(v)
                note(v, -1, at, &output)
                return true
            case 1:
                // A jump, by a distance from itself.
                let to = at &+ long(at)
                if to <= from { voices[v].wentBack = true }
                at = to
                continue
            case 2:
                // A call, likewise; where to return to kept.
                push(v, at &+ 4)
                at = at &+ long(at)
                continue
            case 3:
                at = pop(v)
                continue
            case 4:
                // A loop of so many times: its start and its count kept (as `MOVEM.L D2/A1,-(A0)` keeps them).
                let times = Int(word(at))
                at &+= 2
                push(v, at)
                push(v, times)
                continue
            case 5:
                // The loop's end: back to its start until its count is done.
                let times = UInt16(truncatingIfNeeded: pop(v)) &- 1
                let start = pop(v)
                if times != 0 {
                    push(v, start)
                    push(v, Int(times))
                    at = start
                }
                continue
            case 6:
                voices[v].instruments = at &+ long(at)
                at &+= 4
                continue
            case 7:
                voices[v].lengthHigh = UInt16(byte(at)) << 8
                at &+= 1
                continue
            case 8:
                // A slide (`Label_2`): its first step and count, and its steps read from here on; or, if one is
                // going, its next step passed over.
                if voices[v].flags & 0x01 != 0 {
                    at &+= 2
                } else {
                    voices[v].flags |= 0x01
                    voices[v].slideStep = byte(at)
                    voices[v].slideCount = voices[v].lengthHigh | UInt16(byte(at &+ 1))
                    voices[v].lengthHigh = 0
                    at &+= 2
                    voices[v].slideAt = at
                }
                continue
            case 9:
                let depth = byte(at)
                at &+= 1
                voices[v].slideDepth = depth
                if depth != 0 { voices[v].slideSize = UInt8(truncatingIfNeeded: 64 / Int(depth)) }
                continue
            case 14:
                writeVolume(v, UInt16(byte(at) & 0x7F), &output)
                at &+= 1
                continue
            case 15:
                // The voice's end (`Label_C`).
                voices[v].flags |= 0x80
                voices[v].stream = at
                return false
            default:
                continue
            }
        }
    }

    /// The note's or rest's length (`lbC000666`, $986), and the note's sample begun ($8FA to $984).
    private mutating func note<Output: TFMXOutput>(_ v: Int, _ value: Int, _ after: Int, _ output: inout Output) {
        var at = after
        if value >= 0 { sample(v, value, &output) }
        voices[v].length = voices[v].lengthHigh | UInt16(byte(at))
        voices[v].lengthHigh = 0
        at &+= 1
        voices[v].stream = at
        voices[v].flags |= 0x20
    }

    /// The instrument that takes the note, and its sample told Paula and begun, and silence after it.
    private mutating func sample<Output: TFMXOutput>(_ v: Int, _ value: Int, _ output: inout Output) {
        let table = voices[v].instruments
        let count = Int(word(table))
        guard count != 0 else { return }
        var entry = table &+ 2
        for _ in 0 ..< count {
            let low = Int(Int16(bitPattern: word(entry &+ 10))), high = Int(Int16(bitPattern: word(entry &+ 12)))
            if value >= low, value <= high { break }
            entry &+= 14
            if entry == table &+ 2 &+ 14 * count { return }
        }
        let note = value &- Int(word(entry &+ 8))
        voices[v].note = note
        let (period, _) = periodLongs(note)
        output.timed(at: moment)
        place(v, entry &+ long(entry), word(entry &+ 6), &output)
        writePeriod(v, UInt16(truncatingIfNeeded: period >> 16), &output)
        moment = afterWait(moment)
        output.timed(at: moment)
        output.on(v)
        moment = afterWait(moment)
        output.timed(at: moment)
        // (Wanted Team's player looks for the fourth voice at a byte of what it keeps of the first's room for calls,
        // as UADE has it at $F6 into a page of memory, less the room taken.)
        if wantedTeamsWay, v == 3, (0xF6 &- 4 &* voices[0].depth) & 0x40 != 0 { return }
        place(v, silenceAt, 1, &output)
    }

    /// $9CE to $A5A: the slide's step: the period between the note's and the next's by as many 64ths as its step
    /// says, and its next step read.
    private mutating func slide<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        var note = voices[v].note &- Int(voices[v].slideDepth)
        var step = voices[v].slideStep
        let size = voices[v].slideSize
        var steps = 0
        while Int8(bitPattern: step) >= Int8(bitPattern: size) {
            step &-= size
            note &+= 1
            steps += 1
            if steps > Self.mostSteps {
                voices[v].flags = 0xC8
                return
            }
        }
        // (The step times the depth, a word.)
        var times: UInt16 = 0
        for _ in 0 ... Int(voices[v].slideDepth) { times &+= UInt16(step) }
        times &-= UInt16(step)
        let (here, next) = periodLongs(note)
        let difference = UInt32(truncatingIfNeeded: next &- here)
        // (The player's multiplication, which loses the low half's carry into the top.)
        let top = (difference >> 16) &* UInt32(times) & 0xFFFF
        let bottom = (difference & 0xFFFF) &* UInt32(times) & 0xFFFF
        let part = (top << 16 | bottom) >> 6
        let period = UInt32(truncatingIfNeeded: here) &- part
        writePeriod(v, UInt16(truncatingIfNeeded: period >> 16), &output)
        var at = voices[v].slideAt
        while true {
            let value = byte(at)
            at &+= 1
            if value == 0xF7 {
                voices[v].lengthHigh = UInt16(byte(at)) << 8
                at &+= 1
                continue
            }
            if value == 0xF8 {
                voices[v].slideStep = byte(at)
                voices[v].slideCount = voices[v].lengthHigh | UInt16(byte(at &+ 1))
                voices[v].lengthHigh = 0
                voices[v].slideAt = at &+ 2
                return
            }
            voices[v].flags &= ~0x01
            return
        }
    }

    /// The voice's room for its calls and loops (`4(A2)`, 128 bytes of the player's): what is put past it is lost,
    /// and what is taken from before it is nought.
    private mutating func push(_ v: Int, _ value: Int) {
        let depth = voices[v].depth
        if depth >= 0, depth < 32 { voices[v].room[depth] = value }
        voices[v].depth = depth &+ 1
    }

    private mutating func pop(_ v: Int) -> Int {
        let depth = voices[v].depth &- 1
        voices[v].depth = depth
        return depth >= 0 && depth < 32 ? voices[v].room[depth] : 0
    }

    /// Paula's period for the voice as the tick just run began (its writes in the tick are told at their moments).
    func period(_ voice: Int) -> UInt16 { periodsBefore[voice] }
    /// Paula's volume for the voice as the tick just run began.
    func volume(_ voice: Int) -> UInt16 { volumesBefore[voice] }
    /// What the player last gave Paula's period register for the voice.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Paul Summers's music, played on Paula by `PaulaTickRenderer`.
extension PaulSummersPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Paul Summers")
        info.detail = "the game's own music driver"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { tickClocks }
}
