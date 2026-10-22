// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the replay routine of Synth Dream, Laurens "Lotus" Tummers' and John Tonnard's (as the game Monster
// Business carries it), as Wanted Team adapted it for EaglePlayer ("Synth Dream player module V1.1 (28 Apr
// 2007)"), carried by UADE as players/SynthDream, whose source UADE also carries as
// amigasrc/players/wanted_team/SynthDream/src/Synth Dream_v2.asm. The labels given are that source's.

import SidayChips
import SidayFoundation

/// Synth Dream, the music system of Laurens Tummers and John Tonnard, whose music for Monster Business (Eclipse,
/// 1991) is among UnExoticA's: eight files of a song each, beside the file of samples they share, `set.smp`.
///
/// The file: the place of its instruments (from its start, as every place in it is), of a table of the places of
/// volume tables and of one of pitch tables; then the songs, sixteen bytes each (the places of their four voices'
/// tracks), as many as fit before the first table. A track is a list of twelve bytes for each pattern it plays:
/// the pattern's place, a transposition, how many more times it is played, an instrument to be played as another
/// (its number and the other's), and a byte taken from its volume; and its end, $FEFF to go round or $FFFF to
/// stop. A pattern is a list of rows to a byte $FF, each a command (a word: twice its number) and its words, and
/// any of six commands more that follow it: a row sets how many ticks it lasts, its note, its volume, its
/// instrument, any of them, or is a rest; or slides the note's period by a factor every tick, after so many; or
/// sets a volume or pitch table to be taken up after so many ticks; or ties the notes that follow, or unties them.
///
/// An instrument is 32 bytes: whether its notes are transposed, a fine tuning (a byte's place into a table of
/// factors), the places of its tables of volumes, pitches (factors of its period), notes added and waves (or
/// nought for none), and its sample's place in the sample file, length, loop and loop's length. Each table is a
/// list of parts, each a count of values and how many more times they are played, then the values; a count of $FF
/// goes back to its first. An instrument with a table of waves is synthesised: each tick the player copies one of
/// its sixteen square waves of sixteen bytes into the voice's own sixteen in chip memory and takes a value from
/// the byte where its edge is, and Paula plays those.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick, at the tick's start. It sets no timer of its own (it has only `DTP_Interrupt`), and so
/// is run by EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a
/// second and a little less. A note's first tick tells Paula its sample and turns the voice on; its second tells
/// her its loop; its last turns the voice off (unless it is tied), so that the next note begins on a voice that has
/// been off for a tick; and every tick tells her its period and volume.
///
/// A song comes to its end when all four voices have come to the end of their tracks (gone round or stopped) since
/// it last did, as the player tells EaglePlayer so; once all four have stopped, it stops. Where the player would
/// read past the file it reads nought, and past its own tables nought; a voice whose patterns are all empty, for
/// which it would go round for ever within a tick, is stopped, as is one that comes to a command the player does
/// not have; and a slide over no ticks (a division by nought, which would crash the machine) does not move. A word
/// at an odd place in the player's tables, which a fine tuning or a slide's step can ask for (and which would stop
/// a 68000), is read as a later processor reads it. Wanted Team's player looks for the end of a pitch table where
/// it is, as the game's could not (it adds only the low word of the file's place to the table's, so that where it
/// looks depends on where the file was loaded): this is done as Wanted Team's does it.
struct SynthDreamPlayer: ~Copyable {
    /// The file, the samples, the voices' waves and what follows them, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where the sample file is, and the player's 64 bytes for its waves (`Buffy`, in chip memory), sixteen for
    /// each voice (with room after them, as the player's taking a value from a wave can write past them).
    let samplesAt: Int
    let wavesAt: Int
    static let wavesSpace = 512
    /// Where a voice with nothing to play is pointed: noughts after the waves.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where the instruments (`lbL0007CE`), the volume tables' places (`lbL0007D2`) and the pitch tables'
    /// (`lbL0007D6`) are: the file's first three longs.
    private let instruments: UInt32
    private let volumeTables: UInt32
    private let pitchTables: UInt32
    let songCount: Int
    private(set) var song = 0
    /// How many instruments it has, as `InitPlayer` counts them (those up to the first whose first byte is not
    /// nought): samples (of a length that is not nought) and synthesised.
    let sampleCount: Int
    let synthCount: Int
    /// What is said of a file cut short in its tracks or patterns, or whose songs' samples run past the sample file.
    let shortfalls: [String]

    /// What the player keeps for each voice (`lbL000494` and the three after it, 206 bytes each), named by what
    /// they are: its track's start and where it is (+2, +6), its pattern's start and where it is (+10, +14).
    private struct Voice {
        var trackStart: UInt32 = 0
        var track: UInt32 = 0
        var patternStart: UInt32 = 0
        var pattern: UInt32 = 0
        /// The track's eight bytes for the pattern (+18): its transposition, how many more times it is played,
        /// the instrument played as another and that other, and the byte taken from its volume (+23).
        var transposition: UInt8 = 0
        var repeats: UInt8 = 0
        var swapFrom: UInt8 = 0
        var swapTo: UInt8 = 0
        var quieter: UInt8 = 0
        /// Its count of ticks to its next row (+26), how many a row lasts (+28), its note (+30) and the volume
        /// its rows set (+32, whose low byte is taken from the tables' volume).
        var count: UInt16 = 0
        var duration: UInt16 = 0
        var note: UInt16 = 0
        var volume: UInt16 = 0
        /// Its instrument (+38, the 32 bytes copied there): whether its notes are left untransposed (+39), its
        /// fine tuning (+40), its four tables (+42: volumes, pitches, notes added and waves), its sample's place
        /// and length (+58, +62) and its loop's (+64, +68).
        var untransposed: UInt8 = 0
        var tuning: UInt16 = 0
        var tables = InlineArray<4, UInt32>(repeating: 0)
        var sample: UInt32 = 0
        var sampleLength: UInt16 = 0
        var loop: UInt32 = 0
        var loopLength: UInt16 = 0
        /// Where each table is read (+70), and of each the values left of its part (+86), how many more times
        /// the part is played (+90), and its count of values (the low bytes of +98 to +105).
        var places = InlineArray<4, UInt32>(repeating: 0)
        var left = InlineArray<4, UInt8>(repeating: 0)
        var again = InlineArray<4, UInt8>(repeating: 0)
        var lengths = InlineArray<4, UInt8>(repeating: 0)
        /// The slide's factor (+94: nought for none, $2000 as one begins), the note its table of notes adds (+96),
        /// and whether the row is a rest (+97).
        var slide: UInt16 = 0
        var added: UInt8 = 0
        var resting = false
        /// The period and volume told Paula (+106, +109).
        var period: UInt16 = 0
        var level: UInt8 = 0
        /// The slide's step (+118, a factor) and the ticks before it begins (+172); whether the voice has stopped
        /// (+120); a volume table and a pitch table to be taken up (+176, +182) after so many ticks (+174, +180);
        /// and whether its notes are tied (+202).
        var slideStep: UInt16 = 0
        var slideDelay: UInt16 = 0
        var stopped = false
        var newVolumes: UInt32 = 0
        var volumesDelay: UInt16 = 0
        var newPitches: UInt32 = 0
        var pitchesDelay: UInt16 = 0
        var tied = false
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The voices that have not come to the end of their tracks since the song last came to its end (`SongEnd`),
    /// and those that have not at its start, which are all but those with empty tracks (`SongEndTemp`).
    private var unfinished = InlineArray<4, Bool>(repeating: true)
    private var unfinishedAtStart = InlineArray<4, Bool>(repeating: true)

    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// Each song's length, found as the player is made.
    private var lengths: [UInt64?] = []

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to; and once the songs played through to
    /// find their lengths have taken four hours in all, the rest are too.
    private static let mostTicks = 50 * 60 * 60
    private static let mostTicksInAll = 4 * mostTicks
    /// How many patterns a voice may come to the end of in a tick before it is taken to have none that is not
    /// empty.
    private static let mostEmptyPatterns = 0x1_0000

    // MARK: - The player's tables

    /// The periods of its notes (`lbL000FB6`, 144 of them), then the factors of $2000 below and above it
    /// (`lbL0010D6`, `lbL0013F6`, 400 each) and its sixteen waves (`lbL001716`, 256 bytes), as they lie one after
    /// the other in the player: places in them are bytes from the first.
    private static let periodsAt = 0
    private static let downAt = 288
    private static let upAt = 1088
    private static let wavesTableAt = 1888
    private static let tablesEnd = 2144

    /// A word of the tables, `at` bytes from their start; nought past them, where the player would read its own
    /// code or what follows it.
    private static func tableWord(_ at: Int) -> UInt16 {
        UInt16(tableByte(at)) << 8 | UInt16(tableByte(at &+ 1))
    }

    private static func tableByte(_ at: Int) -> UInt8 {
        guard at >= 0, at < tablesEnd else { return 0 }
        if at >= wavesTableAt {
            // The waves: the first so many bytes of wave n (as many as n) $81, the rest $7F.
            let wave = (at - wavesTableAt) >> 4, i = (at - wavesTableAt) & 15
            return i < wave ? 0x81 : 0x7F
        }
        let word = factorsAndPeriods[at >> 1]
        return at & 1 == 0 ? UInt8(word >> 8) : UInt8(word & 0xFF)
    }

    /// `mulu` and a shift of 13: a word times a factor of $2000, as a word.
    @inline(__always) private static func scaled(_ value: UInt16, by factor: UInt16) -> UInt16 {
        UInt16(truncatingIfNeeded: (UInt32(value) * UInt32(factor)) >> 13)
    }

    // MARK: - Reading

    @inline(__always) private func byte(_ at: UInt32) -> UInt8 { at < UInt32(fileSize) ? memory[Int(at)] : 0 }
    @inline(__always) private func word(_ at: UInt32) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: UInt32) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }

    /// The 68000's adding of a word, with its sign, to an address.
    @inline(__always) private static func plus(_ at: UInt32, _ offset: UInt16) -> UInt32 {
        at &+ UInt32(bitPattern: Int32(Int16(bitPattern: offset)))
    }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 { UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2)) }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): its first long the place of its instruments, within
    /// it, not nought and even, with $FFFF in the word before it; its second and third, the places of its tables,
    /// a whole number of longs under 32K; and its first song's four tracks' places, even and under 32K, each
    /// either at byte 40 or after the $FEFF or $FFFF that ends another.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 28 else { return false }
        let first = long(data, 0)
        guard first != 0, first < UInt32(data.count), first & 0x8000_0001 == 0, word(data, Int(first) - 2) == 0xFFFF else { return false }
        for at in [4, 8] {
            let value = long(data, at)
            guard value != 0, value < 0x8000, value & 3 == 0 else { return false }
        }
        for v in 0 ..< 4 {
            let track = long(data, 12 + 4 * v)
            guard track != 0, track < 0x8000, track & 1 == 0 else { return false }
            if track != 40 {
                let end = word(data, Int(track) - 2)
                guard end == 0xFEFF || end == 0xFFFF else { return false }
            }
        }
        return true
    }

    /// How many words follow each command (`lbW000C40`'s), in its number's order.
    private static let argumentCounts: [Int] = [0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 5, 3, 4, 1, 6, 6, 2, 0, 0, 2, 2, 2]

    /// Which of its words is the instrument, for each command that chooses one.
    private static func instrumentArgument(_ command: Int) -> Int? {
        switch command {
        case 4: 0
        case 7, 9: 1
        case 11, 13: 2
        case 14: 3
        case 16, 17: 5
        default: nil
        }
    }

    /// What its songs' tracks and patterns are found to have (only for saying so): whether the file ends before
    /// they do, and the places of the instruments they choose (each track's instrument played as another taken
    /// as it is).
    private static func survey(_ data: [UInt8], songs: Int) -> (cut: Bool, chosen: [UInt32]) {
        var seen: [(pattern: Int, from: UInt8, to: UInt8)] = []
        var chosen: [UInt32] = []
        var cut = false
        let instruments = long(data, 0)
        for s in 0 ..< songs {
            for v in 0 ..< 4 {
                var entry = Int(long(data, 12 + 16 * s + 4 * v))
                for _ in 0 ..< 1024 {
                    guard entry < data.count else {
                        cut = true
                        break
                    }
                    if data[entry] >= 0xFE { break }
                    guard entry + 12 <= data.count else {
                        cut = true
                        break
                    }
                    let pattern = Int(long(data, entry)), from = data[entry + 6], to = data[entry + 7]
                    entry += 12
                    guard !seen.contains(where: { $0.pattern == pattern && $0.from == from && $0.to == to }), seen.count < 4096 else { continue }
                    seen.append((pattern, from, to))
                    // Its rows, each a command, its words and any of those from $24 that follow it, to its $FF, or to
                    // a command the player does not have (past which it reads nothing).
                    var at = pattern
                    rows: for _ in 0 ..< 0x1_0000 {
                        guard at < data.count else {
                            cut = true
                            break
                        }
                        if data[at] == 0xFF { break }
                        var first = true
                        while first || (word(data, at) >= 0x24 && word(data, at) < 0x8024) {
                            first = false
                            let what = word(data, at)
                            guard what & 1 == 0, what <= 0x2E else { break rows }
                            let command = Int(what >> 1)
                            if let k = instrumentArgument(command) {
                                var number = word(data, at + 2 + 2 * k)
                                if UInt8(number & 0xFF) == from { number = number & 0xFF00 | UInt16(to) }
                                let place = plus(instruments, number &<< 5)
                                if !chosen.contains(place), chosen.count < 4096 { chosen.append(place) }
                            }
                            at += 2 + 2 * argumentCounts[command]
                            guard at <= data.count else {
                                cut = true
                                break rows
                            }
                        }
                    }
                }
            }
        }
        return (cut, chosen)
    }

    /// Reads the file and its samples (the sample file, `set.smp` beside it) and starts the song asked for (of
    /// `songCount`, nought the first). A file given no samples (an empty file) is refused, as the player refuses it
    /// when its `ExtLoad` finds no sample file beside it; and one shorter than the long its `InitPlayer` checks
    /// its length against (the second of the volume tables' places), as that does.
    init(_ data: [UInt8], samples: [UInt8], song: Int = 0) throws(TuneError) {
        fileSize = data.count
        func aligned(_ n: Int) -> Int { (n + 15) & ~15 }
        samplesAt = aligned(max(data.count, 16))
        wavesAt = aligned(samplesAt + samples.count)
        silenceAt = wavesAt + Self.wavesSpace
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        for (i, b) in samples.enumerated() { memory[samplesAt + i] = b }
        instruments = Self.long(data, 0)
        volumeTables = Self.long(data, 4)
        pitchTables = Self.long(data, 8)
        // (`InitPlayer`: the songs, sixteen bytes each from byte 12 to the volume tables' places.)
        songCount = max(1, min(256, (Int(volumeTables) - 12) >> 4))
        // (The instruments, to the first whose first byte is not nought; of them those with a table of waves,
        // and of the rest those whose length is not nought.)
        var samplesCounted = 0, synths = 0
        var at = Int(instruments)
        while at >= 0, at < data.count, data[at] == 0 {
            if Self.long(data, at + 16) != 0 {
                synths += 1
            } else if Self.word(data, at + 24) != 0 {
                samplesCounted += 1
            }
            at += 32
        }
        sampleCount = samplesCounted
        synthCount = synths
        // (Of the sampled instruments the songs choose, those that run past the end of the sample file are said to,
        // as `Shortfall.CutShort` counts them.)
        let found = Self.survey(data, songs: songCount)
        var past = 0
        for place in found.chosen where Int(exactly: place).map({ $0 + 32 <= data.count }) ?? false {
            let entry = Int(place)
            guard Self.long(data, entry + 16) == 0 else { continue }
            let start = Int64(Self.long(data, entry + 20)), length = 2 * Int64(Self.word(data, entry + 24))
            let lost = length - max(0, min(length, Int64(samples.count) - start))
            if lost >= 32, lost >= 2048 || lost * 16 >= length { past += 1 }
        }
        var said: [String] = []
        if found.cut {
            said.append(Shortfall.cutShort("Its tracks and patterns are not all there; what is missing of them is read as noughts."))
        }
        if past > 0, !samples.isEmpty {
            said.append(Shortfall.some(past, one: "samples runs past the end of the sample file, and is silent there.",
                                       many: "samples run past the end of the sample file, and are silent there."))
        }
        shortfalls = said
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Synth Dream file") }
        guard Int64(data.count) > Int64(Int32(bitPattern: Self.long(data, Int(volumeTables) + 4))) else {
            throw .malformed("it is too short")
        }
        guard !samples.isEmpty else {
            throw .missingCompanion("A Synth Dream file keeps its samples in a file of their own, set.smp, which was not given with it.")
        }

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
            // (The tick it came to its end in is the first of it again, or the first of its silence.)
            lengths.append(endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil)
        }
        self.song = max(0, min(songCount - 1, song))
        lengthClocks = lengths[self.song]
        start()
    }

    deinit { memory.deallocate() }

    /// `InitSound` and `Init`: each voice at its track's first pattern, read on the first tick; one whose track
    /// begins with a byte $FF stopped from the start (and so taken to have come to its end). The rest of what the
    /// player keeps begins at nought, as it is when the player is loaded.
    private mutating func start() {
        voices = .init(repeating: Voice())
        for v in 0 ..< 4 {
            let entry = Self.plus(0, UInt16(truncatingIfNeeded: 16 * song + 4 * v + 12))
            let track = long(entry)
            var voice = Voice()
            voice.trackStart = track
            load(&voice, entry: track)
            if byte(track) == 0xFF { voice.stopped = true }
            unfinishedAtStart[v] = !voice.stopped
            voices[v] = voice
        }
        unfinished = unfinishedAtStart
        for p in 0 ..< Self.wavesSpace { memory[wavesAt + p] = 0 }
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        endings = 0
        stops = 0
    }

    /// A track's twelve bytes for a pattern (`lbC0000B2`) taken up: its place, its eight bytes, and the track
    /// moved on past them.
    private func load(_ voice: inout Voice, entry: UInt32) {
        voice.patternStart = long(entry)
        voice.pattern = voice.patternStart
        voice.transposition = byte(entry &+ 4)
        voice.repeats = byte(entry &+ 5)
        voice.swapFrom = byte(entry &+ 6)
        voice.swapTo = byte(entry &+ 7)
        voice.quieter = byte(entry &+ 9)
        voice.track = entry &+ 12
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        lengthClocks = lengths[song]
        start()
    }

    /// Runs the player for a tick (`Play`), telling `output` what Paula is to do, in the order the player tells
    /// her: each voice that has not stopped in turn. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        var playing = false
        for v in 0 ..< 4 where !voices[v].stopped {
            tick(v, &output)
            playing = true
        }
        if playing, !voices[0].stopped || !voices[1].stopped || !voices[2].stopped || !voices[3].stopped {
            return 20
        }
        // (All four stopped, in this tick or before: the song is over, and nothing more is heard.)
        if playing { stops += 1 }
        if !playing, stops == 0 {
            // (A song whose four tracks are empty: it is over before it begins.)
            endings += 1
            stops += 1
        }
        return 20
    }

    /// `SongEndTest`: the voice has come to the end of its track; once all four have since the song last came to
    /// its end, it has again.
    private mutating func finished(_ v: Int) {
        unfinished[v] = false
        if !unfinished[0], !unfinished[1], !unfinished[2], !unfinished[3] {
            endings += 1
            unfinished = unfinishedAtStart
        }
    }

    /// `lbC000060`: a voice's tick: its next row read if its count of ticks has come to nought, and then its
    /// tables moved on and Paula told.
    private mutating func tick<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        var voice = voices[v]
        if voice.count == 0 {
            readRow(v, &voice)
            if voice.stopped {
                voices[v] = voice
                return
            }
        }
        // `lbC00010E`: a rest turns the voice off on every tick of it.
        if voice.resting {
            output.off(v)
            voice.count &-= 1
            voices[v] = voice
            return
        }
        // A volume or pitch table to be taken up, once its ticks are over (its place's high word then cleared,
        // which leaves it to be taken up again after a word's count of ticks more).
        if voice.newVolumes != 0 {
            if voice.volumesDelay == 0 {
                voice.places[0] = voice.newVolumes
                voice.newVolumes &= 0xFFFF
                voice.left[0] = 0
                voice.again[0] = 0
            }
            voice.volumesDelay &-= 1
        }
        if voice.newPitches != 0 {
            if voice.pitchesDelay == 0 {
                voice.places[1] = voice.newPitches
                voice.newPitches &= 0xFFFF
                voice.left[1] = 0
                voice.again[1] = 0
            }
            voice.pitchesDelay &-= 1
        }
        // The volume: its table's next value, or 64, less the low byte of the row's and the track's byte (a
        // byte's difference, nought should it have its top bit set).
        var level: UInt8 = 0x40
        if voice.tables[0] != 0 { level = byte(next(&voice, 0, size: 1)) }
        level = level &- UInt8(voice.volume & 0xFF) &- voice.quieter
        if level & 0x80 != 0 { level = 0 }
        voice.level = level
        // The note its table of notes adds.
        if voice.tables[2] != 0 { voice.added = byte(next(&voice, 2, size: 1)) }
        // The period: the note's, transposed (unless the instrument says not) and with the note added (in its
        // low byte alone), from the table of periods as a signed word's place; and times its table's factor of
        // $2000, if it has a table of pitches (a positive word's place in the factors above, a negative one's
        // in those below).
        var index = voice.note
        if voice.untransposed == 0 { index = index & 0xFF00 | UInt16(UInt8(index & 0xFF) &+ voice.transposition) }
        index = index & 0xFF00 | UInt16(UInt8(index & 0xFF) &+ voice.added)
        let notePeriod = Self.tableWord(Self.periodsAt + Int(Int16(bitPattern: index &<< 1)))
        if voice.tables[1] != 0 {
            let pitch = word(next(&voice, 1, size: 2))
            let factor = Int16(bitPattern: pitch) >= 0
                ? Self.tableWord(Self.upAt + Int(Int16(bitPattern: pitch &<< 1)))
                : Self.tableWord(Self.downAt + Int(Int16(bitPattern: (0 &- pitch) &<< 1)))
            voice.period = Self.scaled(notePeriod, by: factor)
        } else {
            voice.period = notePeriod
        }
        // `lbC000328`: the slide, after its ticks of delay: its factor times its step, and the period times that.
        if voice.slide != 0 {
            if voice.slideDelay != 0 {
                voice.slideDelay &-= 1
            } else {
                voice.slide = Self.scaled(voice.slide, by: voice.slideStep)
                voice.period = Self.scaled(voice.period, by: voice.slide)
            }
        }
        // What Paula plays: for an instrument with a table of waves, the wave its next value says copied into the
        // voice's sixteen bytes, and the value taken from the byte where its edge is (as a place from them, which
        // can be past them); else its sample and loop, from the sample file.
        var start: Int, length: UInt16, loop: Int, loopLength: UInt16
        if voice.tables[3] != 0 {
            let value = word(next(&voice, 3, size: 2))
            let wave = Int(value >> 8), taken = UInt8(value & 0xFF)
            let into = wavesAt + 16 * v
            for i in 0 ..< 16 { memory[into + i] = Self.tableByte(Self.wavesTableAt + 16 * wave + i) }
            if 16 * v + wave < Self.wavesSpace { memory[into + wave] &-= taken }
            start = into
            length = 8
            loop = into
            loopLength = 8
        } else {
            start = sampleAddress(voice.sample)
            length = voice.sampleLength
            loop = sampleAddress(voice.loop)
            loopLength = voice.loopLength
        }
        // `lbC0003EC`: the fine tuning, a factor of $2000 (a word's place, in bytes, in those above for one that is
        // positive, below for one that is negative).
        if voice.tuning != 0 {
            let factor = Int16(bitPattern: voice.tuning) > 0
                ? Self.tableWord(Self.upAt + Int(Int16(bitPattern: voice.tuning)))
                : Self.tableWord(Self.downAt + Int(Int16(bitPattern: 0 &- voice.tuning)))
            voice.period = Self.scaled(voice.period, by: factor)
        }
        // `lbC00041E`: on the row's first tick its sound and the voice turned on; on its second its loop, and on
        // again; after that its period and volume alone, and on its last tick the voice turned off (unless its
        // notes are tied), or else on.
        let second = voice.duration &- 1
        if second < voice.count {
            output.takeNextBuffer(v, start: start, length: length)
            tell(v, voice)
            output.on(v)
        } else if second == voice.count {
            output.takeNextBuffer(v, start: loop, length: loopLength)
            tell(v, voice)
            output.on(v)
        } else {
            tell(v, voice)
            if voice.count == 1, !voice.tied {
                output.off(v)
            } else {
                output.on(v)
            }
        }
        voice.count &-= 1
        voices[v] = voice
    }

    /// The period and volume told Paula (the volume, through `ChangeVolume`, times EaglePlayer's 64 over 64).
    private mutating func tell(_ v: Int, _ voice: Voice) {
        periods[v] = voice.period
        volumes[v] = UInt16(voice.level & 0x7F)
    }

    /// A place in the sample file, in memory: past memory for one past it.
    private func sampleAddress(_ offset: UInt32) -> Int {
        offset < UInt32(memoryCapacity) ? samplesAt + Int(offset) : memoryCapacity
    }

    /// A table's next value's place (`size` bytes of it), and the table moved on past it: at a part's start its
    /// count and how many more times it is played (or for a count of $FF the table's first part again), and at
    /// its end, while it is to be played again, its start.
    private func next(_ voice: inout Voice, _ k: Int, size: UInt32) -> UInt32 {
        var place = voice.places[k]
        if voice.left[k] == 0 {
            if voice.again[k] != 0 {
                place &-= UInt32(voice.lengths[k]) * size
                voice.left[k] = voice.lengths[k]
                voice.again[k] &-= 1
            } else {
                if byte(place) == 0xFF { place = voice.tables[k] }
                voice.left[k] = byte(place)
                voice.lengths[k] = byte(place)
                voice.again[k] = byte(place &+ 1)
                place &+= 2
            }
        }
        let value = place
        voice.places[k] = place &+ size
        voice.left[k] &-= 1
        return value
    }

    /// `lbC0000C4`: the voice's next row read: at a pattern's end the pattern again, as many times as the track
    /// says, and then the track's next (at its end its first again, or for a track that stops, the voice
    /// stopped); then the row's command and those that follow it.
    private mutating func readRow(_ v: Int, _ voice: inout Voice) {
        var empty = 0
        while true {
            voice.slide = 0
            voice.added = 0
            voice.resting = false
            voice.left = .init(repeating: 0)
            voice.again = .init(repeating: 0)
            let at = voice.pattern
            guard byte(at) == 0xFF else { break }
            empty += 1
            if empty > Self.mostEmptyPatterns {
                voice.stopped = true
                return
            }
            if voice.repeats != 0 {
                voice.repeats &-= 1
                voice.pattern = voice.patternStart
                continue
            }
            voice.newVolumes = 0
            voice.newPitches = 0
            var entry = voice.track
            let mark = byte(entry)
            if mark > 0xFE {
                voice.stopped = true
                finished(v)
                return
            }
            if mark == 0xFE {
                entry = voice.trackStart
                finished(v)
            }
            load(&voice, entry: entry)
        }
        var at = voice.pattern
        guard command(&voice, &at, first: true) else {
            voice.stopped = true
            return
        }
        while true {
            let next = word(at)
            guard next >= 0x24, next < 0x8024 else { break }
            guard command(&voice, &at, first: false) else {
                voice.stopped = true
                return
            }
        }
        voice.pattern = at
    }

    /// A command (`lbW000C40`, at `at`, the place moved on past it and its words), false for one the player does
    /// not have. The first of a row's is any; those that follow it are those from $24.
    private func command(_ voice: inout Voice, _ at: inout UInt32, first: Bool) -> Bool {
        let what = word(at)
        at &+= 2
        func take() -> UInt16 {
            let value = word(at)
            at &+= 2
            return value
        }
        func fromTables() { voice.places = voice.tables }
        func again() { voice.count = voice.duration }
        func lasting() {
            voice.duration = take()
            voice.count = voice.duration
        }
        guard what & 1 == 0, what <= 0x2E else { return false }
        switch what >> 1 {
        case 0:
            again()
            fromTables()
        case 1:
            lasting()
            fromTables()
        case 2:
            again()
            voice.note = take()
            fromTables()
        case 3:
            again()
            voice.volume = take()
            fromTables()
        case 4:
            again()
            instrument(&voice, take())
        case 5:
            lasting()
            voice.note = take()
            fromTables()
        case 6:
            lasting()
            voice.volume = take()
            fromTables()
        case 7:
            lasting()
            instrument(&voice, take())
        case 8:
            again()
            voice.note = take()
            voice.volume = take()
            fromTables()
        case 9:
            again()
            voice.note = take()
            instrument(&voice, take())
        case 10:
            lasting()
            voice.note = take()
            voice.volume = take()
            fromTables()
        case 11:
            lasting()
            voice.note = take()
            instrument(&voice, take())
        case 12:
            // `lbC000E60`: a slide, over the row's ticks less its delay.
            lasting()
            fromTables()
            voice.note = take()
            slide(&voice, up: take() == 0xFD00, amount: take(), delay: take())
        case 13:
            again()
            voice.note = take()
            voice.volume = take()
            instrument(&voice, take())
        case 14:
            lasting()
            voice.note = take()
            voice.volume = take()
            instrument(&voice, take())
        case 15:
            // `lbC000F32`: a rest.
            voice.resting = true
            lasting()
            fromTables()
        case 16, 17:
            // `lbC000F4C`: a slide, and an instrument.
            lasting()
            voice.note = take()
            slide(&voice, up: take() == 0xFD00, amount: take(), delay: take())
            instrument(&voice, take())
        case 18:
            // `lbC000CB4`: a volume table to be taken up after so many ticks.
            voice.volumesDelay = take()
            voice.newVolumes = long(Self.plus(volumeTables, take()))
        case 19:
            voice.tied = false
        case 20:
            voice.tied = true
        case 21, 22:
            // `lbC000C70`, `lbC000C8A`: a slide by a factor of its own (a word's place in bytes among those below,
            // or above), after so many ticks.
            voice.slideDelay = take()
            let place = Int(Int16(bitPattern: take()))
            voice.slideStep = Self.tableWord((what >> 1 == 21 ? Self.downAt : Self.upAt) + place)
            voice.slide = 0x2000
        default:
            // `lbC000CC8`: a pitch table to be taken up after so many ticks.
            voice.pitchesDelay = take()
            voice.newPitches = long(Self.plus(pitchTables, take()))
        }
        return true
    }

    /// A slide's step: the factor (above for `up`, for $FD00, else below) that is the amount over the ticks it
    /// lasts (the row's less its delay; `divu`, its quotient, doubled as a word's place); none, over none.
    private func slide(_ voice: inout Voice, up: Bool, amount: UInt16, delay: UInt16) {
        voice.slideDelay = delay
        let ticks = voice.duration &- delay
        guard ticks != 0 else { return }
        let quotient = UInt16(truncatingIfNeeded: UInt32(amount) / UInt32(ticks))
        voice.slideStep = Self.tableWord((up ? Self.upAt : Self.downAt) + Int(Int16(bitPattern: quotient &<< 1)))
        voice.slide = 0x2000
    }

    /// An instrument's 32 bytes copied into the voice (the number its track says is to be played as another, in
    /// its low byte, as that), and its tables read from their first.
    private func instrument(_ voice: inout Voice, _ number: UInt16) {
        var number = number
        if UInt8(number & 0xFF) == voice.swapFrom { number = number & 0xFF00 | UInt16(voice.swapTo) }
        let entry = Self.plus(instruments, number &<< 5)
        voice.untransposed = byte(entry &+ 1)
        voice.tuning = word(entry &+ 2)
        for k in 0 ..< 4 { voice.tables[k] = long(entry &+ 4 &+ 4 * UInt32(k)) }
        voice.sample = long(entry &+ 20)
        voice.sampleLength = word(entry &+ 24)
        voice.loop = long(entry &+ 26)
        voice.loopLength = word(entry &+ 30)
        voice.places = voice.tables
    }

    /// Paula's period for the voice as the player last told it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice as the player last told it.
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Synth Dream, played on Paula by `PaulaTickRenderer`.
extension SynthDreamPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Synth Dream")
        info.detail = "Laurens Tummers and John Tonnard's player; \(sampleCount) sample\(sampleCount == 1 ? "" : "s"), \(synthCount) synthesised instrument\(synthCount == 1 ? "" : "s")"
        info.shortfalls = shortfalls
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -18.3 dB.)
    var gain: Float { 0.23 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}

extension SynthDreamPlayer {
    /// The player's tables of periods (`lbL000FB6`) and of factors of $2000 below and above it (`lbL0010D6`,
    /// `lbL0013F6`), one after the other.
    private static let factorsAndPeriods: [UInt16] = [
        // lbL000FB6 (the periods)
        0xD0AD, 0xC4F7, 0xB9E9, 0xAF79, 0xA5A0, 0x9C54, 0x938E, 0x8B46, 0x8375, 0x7C14, 0x751D, 0x6E8B,
        0x6856, 0x627B, 0x5CF4, 0x57BD, 0x52D0, 0x4E2A, 0x49C7, 0x45A3, 0x41BA, 0x3E0A, 0x3A8F, 0x3745,
        0x342B, 0x313E, 0x2E7A, 0x2BDE, 0x2968, 0x2715, 0x24E4, 0x22D2, 0x20DD, 0x1F05, 0x1D47, 0x1BA3,
        0x1A16, 0x189F, 0x173D, 0x15EF, 0x14B4, 0x138B, 0x1272, 0x1169, 0x106F, 0x0F83, 0x0EA4, 0x0DD1,
        0x0D0B, 0x0C4F, 0x0B9F, 0x0AF8, 0x0A5A, 0x09C5, 0x0939, 0x08B4, 0x0837, 0x07C1, 0x0752, 0x06E9,
        0x0685, 0x0628, 0x05CF, 0x057C, 0x052D, 0x04E3, 0x049C, 0x045A, 0x041C, 0x03E1, 0x03A9, 0x0374,
        0x0343, 0x0314, 0x02E8, 0x02BE, 0x0297, 0x0271, 0x024E, 0x022D, 0x020E, 0x01F0, 0x01D4, 0x01BA,
        0x01A1, 0x018A, 0x0174, 0x015F, 0x014B, 0x0139, 0x0127, 0x0117, 0x0107, 0x00F8, 0x00EA, 0x00DD,
        0x00D1, 0x00C5, 0x00BA, 0x00AF, 0x00A6, 0x009C, 0x0094, 0x008B, 0x0083, 0x007C, 0x0075, 0x006F,
        0x0068, 0x0062, 0x005D, 0x0058, 0x0053, 0x004E, 0x004A, 0x0046, 0x0042, 0x003E, 0x003B, 0x0037,
        0x0034, 0x0031, 0x002E, 0x002C, 0x0029, 0x0027, 0x0025, 0x0023, 0x0021, 0x001F, 0x001D, 0x001C,
        0x001A, 0x0019, 0x0017, 0x0016, 0x0015, 0x0014, 0x0012, 0x0011, 0x0010, 0x0010, 0x000F, 0x000E,
        // lbL0010D6 (the factors below)
        0x2000, 0x1FFF, 0x1FFE, 0x1FFC, 0x1FFB, 0x1FFA, 0x1FF9, 0x1FF8, 0x1FF7, 0x1FF5, 0x1FF4, 0x1FF3,
        0x1FF2, 0x1FF1, 0x1FEF, 0x1FEE, 0x1FED, 0x1FEC, 0x1FEB, 0x1FEA, 0x1FE8, 0x1FE7, 0x1FE6, 0x1FE5,
        0x1FE4, 0x1FE2, 0x1FE1, 0x1FE0, 0x1FDF, 0x1FDE, 0x1FDD, 0x1FDB, 0x1FDA, 0x1FD9, 0x1FD8, 0x1FD7,
        0x1FD6, 0x1FD4, 0x1FD3, 0x1FD2, 0x1FD1, 0x1FD0, 0x1FCE, 0x1FCD, 0x1FCC, 0x1FCB, 0x1FCA, 0x1FC9,
        0x1FC7, 0x1FC6, 0x1FC5, 0x1FC4, 0x1FC3, 0x1FC2, 0x1FC0, 0x1FBF, 0x1FBE, 0x1FBD, 0x1FBC, 0x1FBB,
        0x1FB9, 0x1FB8, 0x1FB7, 0x1FB6, 0x1FB5, 0x1FB3, 0x1FB2, 0x1FB1, 0x1FB0, 0x1FAF, 0x1FAE, 0x1FAC,
        0x1FAB, 0x1FAA, 0x1FA9, 0x1FA8, 0x1FA7, 0x1FA5, 0x1FA4, 0x1FA3, 0x1FA2, 0x1FA1, 0x1FA0, 0x1F9E,
        0x1F9D, 0x1F9C, 0x1F9B, 0x1F9A, 0x1F99, 0x1F97, 0x1F96, 0x1F95, 0x1F94, 0x1F93, 0x1F92, 0x1F90,
        0x1F8F, 0x1F8E, 0x1F8D, 0x1F8C, 0x1F8B, 0x1F89, 0x1F88, 0x1F87, 0x1F86, 0x1F85, 0x1F84, 0x1F82,
        0x1F81, 0x1F80, 0x1F7F, 0x1F7E, 0x1F7D, 0x1F7B, 0x1F7A, 0x1F79, 0x1F78, 0x1F77, 0x1F76, 0x1F74,
        0x1F73, 0x1F72, 0x1F71, 0x1F70, 0x1F6F, 0x1F6D, 0x1F6C, 0x1F6B, 0x1F6A, 0x1F69, 0x1F68, 0x1F66,
        0x1F65, 0x1F64, 0x1F63, 0x1F62, 0x1F61, 0x1F60, 0x1F5E, 0x1F5D, 0x1F5C, 0x1F5B, 0x1F5A, 0x1F59,
        0x1F57, 0x1F56, 0x1F55, 0x1F54, 0x1F53, 0x1F52, 0x1F50, 0x1F4F, 0x1F4E, 0x1F4D, 0x1F4C, 0x1F4B,
        0x1F4A, 0x1F48, 0x1F47, 0x1F46, 0x1F45, 0x1F44, 0x1F43, 0x1F41, 0x1F40, 0x1F3F, 0x1F3E, 0x1F3D,
        0x1F3C, 0x1F3A, 0x1F39, 0x1F38, 0x1F37, 0x1F36, 0x1F35, 0x1F34, 0x1F32, 0x1F31, 0x1F30, 0x1F2F,
        0x1F2E, 0x1F2D, 0x1F2C, 0x1F2A, 0x1F29, 0x1F28, 0x1F27, 0x1F26, 0x1F25, 0x1F23, 0x1F22, 0x1F21,
        0x1F20, 0x1F1F, 0x1F1E, 0x1F1D, 0x1F1B, 0x1F1A, 0x1F19, 0x1F18, 0x1F17, 0x1F16, 0x1F14, 0x1F13,
        0x1F12, 0x1F11, 0x1F10, 0x1F0F, 0x1F0E, 0x1F0C, 0x1F0B, 0x1F0A, 0x1F09, 0x1F08, 0x1F07, 0x1F06,
        0x1F04, 0x1F03, 0x1F02, 0x1F01, 0x1F00, 0x1EFF, 0x1EFE, 0x1EFC, 0x1EFB, 0x1EFA, 0x1EF9, 0x1EF8,
        0x1EF7, 0x1EF6, 0x1EF4, 0x1EF3, 0x1EF2, 0x1EF1, 0x1EF0, 0x1EEF, 0x1EEE, 0x1EEC, 0x1EEB, 0x1EEA,
        0x1EE9, 0x1EE8, 0x1EE7, 0x1EE6, 0x1EE4, 0x1EE3, 0x1EE2, 0x1EE1, 0x1EE0, 0x1EDF, 0x1EDE, 0x1EDC,
        0x1EDB, 0x1EDA, 0x1ED9, 0x1ED8, 0x1ED7, 0x1ED6, 0x1ED4, 0x1ED3, 0x1ED2, 0x1ED1, 0x1ED0, 0x1ECF,
        0x1ECE, 0x1ECC, 0x1ECB, 0x1ECA, 0x1EC9, 0x1EC8, 0x1EC7, 0x1EC6, 0x1EC4, 0x1EC3, 0x1EC2, 0x1EC1,
        0x1EC0, 0x1EBF, 0x1EBE, 0x1EBD, 0x1EBB, 0x1EBA, 0x1EB9, 0x1EB8, 0x1EB7, 0x1EB6, 0x1EB5, 0x1EB3,
        0x1EB2, 0x1EB1, 0x1EB0, 0x1EAF, 0x1EAE, 0x1EAD, 0x1EAB, 0x1EAA, 0x1EA9, 0x1EA8, 0x1EA7, 0x1EA6,
        0x1EA5, 0x1EA4, 0x1EA2, 0x1EA1, 0x1EA0, 0x1E9F, 0x1E9E, 0x1E9D, 0x1E9C, 0x1E9A, 0x1E99, 0x1E98,
        0x1E97, 0x1E96, 0x1E95, 0x1E94, 0x1E93, 0x1E91, 0x1E90, 0x1E8F, 0x1E8E, 0x1E8D, 0x1E8C, 0x1E8B,
        0x1E8A, 0x1E88, 0x1E87, 0x1E86, 0x1E85, 0x1E84, 0x1E83, 0x1E82, 0x1E81, 0x1E7F, 0x1E7E, 0x1E7D,
        0x1E7C, 0x1E7B, 0x1E7A, 0x1E79, 0x1E78, 0x1E76, 0x1E75, 0x1E74, 0x1E73, 0x1E72, 0x1E71, 0x1E70,
        0x1E6E, 0x1E6D, 0x1E6C, 0x1E6B, 0x1E6A, 0x1E69, 0x1E68, 0x1E67, 0x1E66, 0x1E64, 0x1E63, 0x1E62,
        0x1E61, 0x1E60, 0x1E5F, 0x1E5E, 0x1E5D, 0x1E5B, 0x1E5A, 0x1E59, 0x1E58, 0x1E57, 0x1E56, 0x1E55,
        0x1E54, 0x1E52, 0x1E51, 0x1E50, 0x1E4F, 0x1E4E, 0x1E4D, 0x1E4C, 0x1E4B, 0x1E49, 0x1E48, 0x1E47,
        0x1E46, 0x1E45, 0x1E44, 0x1E43, 0x1E42, 0x1E41, 0x1E3F, 0x1E3E, 0x1E3D, 0x1E3C, 0x1E3B, 0x1E3A,
        0x1E39, 0x1E38, 0x1E36, 0x1E35,
        // lbL0013F6 (the factors above)
        0x2000, 0x2001, 0x2002, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200B, 0x200C, 0x200D,
        0x200E, 0x200F, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2017, 0x2018, 0x2019, 0x201A, 0x201B,
        0x201C, 0x201E, 0x201F, 0x2020, 0x2021, 0x2022, 0x2024, 0x2025, 0x2026, 0x2027, 0x2028, 0x202A,
        0x202B, 0x202C, 0x202D, 0x202E, 0x202F, 0x2031, 0x2032, 0x2033, 0x2034, 0x2035, 0x2037, 0x2038,
        0x2039, 0x203A, 0x203B, 0x203D, 0x203E, 0x203F, 0x2040, 0x2041, 0x2043, 0x2044, 0x2045, 0x2046,
        0x2047, 0x2048, 0x204A, 0x204B, 0x204C, 0x204D, 0x204E, 0x2050, 0x2051, 0x2052, 0x2053, 0x2054,
        0x2056, 0x2057, 0x2058, 0x2059, 0x205A, 0x205C, 0x205D, 0x205E, 0x205F, 0x2060, 0x2062, 0x2063,
        0x2064, 0x2065, 0x2066, 0x2068, 0x2069, 0x206A, 0x206B, 0x206C, 0x206E, 0x206F, 0x2070, 0x2071,
        0x2072, 0x2074, 0x2075, 0x2076, 0x2077, 0x2078, 0x207A, 0x207B, 0x207C, 0x207D, 0x207E, 0x2080,
        0x2081, 0x2082, 0x2083, 0x2084, 0x2086, 0x2087, 0x2088, 0x2089, 0x208A, 0x208C, 0x208D, 0x208E,
        0x208F, 0x2090, 0x2092, 0x2093, 0x2094, 0x2095, 0x2096, 0x2098, 0x2099, 0x209A, 0x209B, 0x209C,
        0x209E, 0x209F, 0x20A0, 0x20A1, 0x20A2, 0x20A4, 0x20A5, 0x20A6, 0x20A7, 0x20A9, 0x20AA, 0x20AB,
        0x20AC, 0x20AD, 0x20AF, 0x20B0, 0x20B1, 0x20B2, 0x20B3, 0x20B5, 0x20B6, 0x20B7, 0x20B8, 0x20B9,
        0x20BB, 0x20BC, 0x20BD, 0x20BE, 0x20BF, 0x20C1, 0x20C2, 0x20C3, 0x20C4, 0x20C6, 0x20C7, 0x20C8,
        0x20C9, 0x20CA, 0x20CC, 0x20CD, 0x20CE, 0x20CF, 0x20D0, 0x20D2, 0x20D3, 0x20D4, 0x20D5, 0x20D7,
        0x20D8, 0x20D9, 0x20DA, 0x20DB, 0x20DD, 0x20DE, 0x20DF, 0x20E0, 0x20E1, 0x20E3, 0x20E4, 0x20E5,
        0x20E6, 0x20E8, 0x20E9, 0x20EA, 0x20EB, 0x20EC, 0x20EE, 0x20EF, 0x20F0, 0x20F1, 0x20F2, 0x20F4,
        0x20F5, 0x20F6, 0x20F7, 0x20F9, 0x20FA, 0x20FB, 0x20FC, 0x20FD, 0x20FF, 0x2100, 0x2101, 0x2102,
        0x2104, 0x2105, 0x2106, 0x2107, 0x2108, 0x210A, 0x210B, 0x210C, 0x210D, 0x210F, 0x2110, 0x2111,
        0x2112, 0x2113, 0x2115, 0x2116, 0x2117, 0x2118, 0x211A, 0x211B, 0x211C, 0x211D, 0x211E, 0x2120,
        0x2121, 0x2122, 0x2123, 0x2125, 0x2126, 0x2127, 0x2128, 0x2129, 0x212B, 0x212C, 0x212D, 0x212E,
        0x2130, 0x2131, 0x2132, 0x2133, 0x2135, 0x2136, 0x2137, 0x2138, 0x2139, 0x213B, 0x213C, 0x213D,
        0x213E, 0x2140, 0x2141, 0x2142, 0x2143, 0x2144, 0x2146, 0x2147, 0x2148, 0x2149, 0x214B, 0x214C,
        0x214D, 0x214E, 0x2150, 0x2151, 0x2152, 0x2153, 0x2154, 0x2156, 0x2157, 0x2158, 0x2159, 0x215B,
        0x215C, 0x215D, 0x215E, 0x2160, 0x2161, 0x2162, 0x2163, 0x2165, 0x2166, 0x2167, 0x2168, 0x2169,
        0x216B, 0x216C, 0x216D, 0x216E, 0x2170, 0x2171, 0x2172, 0x2173, 0x2175, 0x2176, 0x2177, 0x2178,
        0x217A, 0x217B, 0x217C, 0x217D, 0x217E, 0x2180, 0x2181, 0x2182, 0x2183, 0x2185, 0x2186, 0x2187,
        0x2188, 0x218A, 0x218B, 0x218C, 0x218D, 0x218F, 0x2190, 0x2191, 0x2192, 0x2194, 0x2195, 0x2196,
        0x2197, 0x2199, 0x219A, 0x219B, 0x219C, 0x219D, 0x219F, 0x21A0, 0x21A1, 0x21A2, 0x21A4, 0x21A5,
        0x21A6, 0x21A7, 0x21A9, 0x21AA, 0x21AB, 0x21AC, 0x21AE, 0x21AF, 0x21B0, 0x21B1, 0x21B3, 0x21B4,
        0x21B5, 0x21B6, 0x21B8, 0x21B9, 0x21BA, 0x21BB, 0x21BD, 0x21BE, 0x21BF, 0x21C0, 0x21C2, 0x21C3,
        0x21C4, 0x21C5, 0x21C7, 0x21C8, 0x21C9, 0x21CA, 0x21CC, 0x21CD, 0x21CE, 0x21CF, 0x21D1, 0x21D2,
        0x21D3, 0x21D4, 0x21D6, 0x21D7, 0x21D8, 0x21D9, 0x21DB, 0x21DC, 0x21DD, 0x21DE, 0x21E0, 0x21E1,
        0x21E2, 0x21E3, 0x21E5, 0x21E6,
    ]
}
