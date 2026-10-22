// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Dave Lowe's replay routines of 1993 and 1995, as Wanted Team adapted them for EaglePlayer
// ("Dave Lowe New player module V1.1 (8 June 2001)", carried by UADE as players/DaveLoweNew, whose
// source UADE also carries as amigasrc/players/wanted_team/DaveLoweNew/src/Dave Lowe New_v2.asm). The
// names given are that source's labels, and the addresses those of the code hunk of the module UADE
// runs, which is the one built from that source.

import SidayChips
import SidayFoundation

/// The music Dave Lowe (of Uncle Art) wrote for games from 1993 to 1995, ripped from them as data that
/// his player reads (in UnExoticA's collection, that of King's Quest VI, Beneath a Steel Sky's CD32
/// edition and Super Street Fighter II: The New Challengers). A file starts with a table of offsets
/// into it: its songs, each a list for each of the four voices of the stretches of commands it plays
/// in turn; the stretches themselves, words of notes (a period and a duration in ticks) and of commands
/// before them (an instrument, a volume envelope, a slide, a vibrato, a rest); the instruments, a
/// sample played once or a start and a loop; the envelopes, a word of volume for each tick; and the
/// samples.
///
/// There are two formats, as there were two players: that of Flink (1993), which King's Quest VI and
/// Beneath a Steel Sky have too, which plays every tick; and that of Super Street Fighter II (1995),
/// whose songs each give a number of ticks after which one tick is let go by, unplayed. Its check
/// tells them apart by the long at 24, which only the first has other than nought.
///
/// This is the player's own code, as it tells Paula what to do, tick by tick: what it tells her is the
/// same as UADE's running of that code for the files of UnExoticA's collection. It owns the memory
/// Paula plays from: a few words of the player's own, the module after them, and room after that.
///
/// Where the player would read past the module, it reads noughts; where it would go round for ever
/// within a tick, or jump to no command, it is done as said where it is done (see `fetch`).
struct DaveLoweNewPlayer: ~Copyable {
    /// The player's own words, the module and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of `memory` Paula may read.
    let memoryCapacity: Int
    /// How many bytes the module is.
    let size: Int
    /// Where the module starts in `memory`: after the player's own words (see `restAt`).
    static let moduleAt = 32
    /// Where Paula starts a voice that has not been told where to (the player's `Empty`, 32 bytes of
    /// nought, which `End` points every voice at): the room after the module.
    var silenceAt: Int { Self.moduleAt + size }
    /// Room after the module, as for any player of `PaulaTickRenderer`'s, for no mixing: far enough
    /// after the module that a sample told a length, however long, reads only silence.
    var mixingAt: Int { Self.moduleAt + size + 0x20000 }
    static let mixingSpace = 2048

    /// The player's own words, before the module: the envelope of a rest (`lbL023C12`, eight words of
    /// nought and then $FF, which holds the last); the first command a voice is given (`lbW0231E8`, 8,
    /// on to the next stretch of its list); and the list it is given first (`lbL0231E0`, nought, which
    /// is its end, and so sends it to the start of its song's own). An envelope never given, which the
    /// player would read from the Amiga's address nought, is read from the rest's: silence (siday's
    /// choice; no file of UnExoticA's plays a note before giving its envelope).
    static let restAt = 0
    static let firstCommandAt = 18
    static let firstListAt = 20

    /// Which of the two players the file is for.
    enum Format {
        /// Flink's, of 1993 (`Play`, `lbC0231EA`, $91A), which plays every tick.
        case flink
        /// Super Street Fighter II's, of 1995 (`Play_2`, `lbC009C7C`, $161E), which lets a tick go by
        /// after as many as its song says.
        case streetFighter

        var name: String {
            switch self {
            case .flink: "Flink's player, of 1993"
            case .streetFighter: "Super Street Fighter II's player, of 1995"
            }
        }
    }

    let format: Format

    /// One voice of the four, as the player keeps it (68 bytes each, from `lbL0239F2` or `lbL00A5A4`),
    /// the offsets of each in its record given. Places are in `memory`.
    struct Voice {
        /// Which voice it is, 1 to 4, nought for none (0).
        var number: UInt16 = 0
        /// The ticks left of its note or rest, less one (2).
        var ticks: UInt16 = 0
        /// Its instrument's kind (4): nought for a sample played once, told to Paula as the instrument
        /// is given and never stopped; otherwise a sample with a start and a loop, whose start is told
        /// with each note, its loop at the next tick (while this is 3), and which is stopped at the
        /// note's last tick.
        var kind: UInt16 = 0
        /// The period (6).
        var period: UInt16 = 0
        /// A slide of the period (8 to 14): its way (1 up, any other down; nought for none), its step,
        /// the period it stops at, and the ticks before it starts.
        var slide: UInt16 = 0
        var slideStep: UInt16 = 0
        var slideTarget: UInt16 = 0
        var slideDelay: UInt16 = 0
        /// The vibrato's step through its four (16): 1 and 2 take `vibratoDown` off the period, 3 and 4
        /// add `vibratoUp`; nought for none.
        var vibrato: UInt16 = 0
        /// Where it is in its volume envelope (18), where its commands are (22), where in its song's
        /// list it is and where that list starts (26, 30), and where its envelope starts (34).
        var envelope = DaveLoweNewPlayer.restAt
        var commands = DaveLoweNewPlayer.firstCommandAt
        var list = DaveLoweNewPlayer.firstListAt
        var listStart = 0
        var envelopeStart = DaveLoweNewPlayer.restAt
        /// The instrument's start and loop, and their lengths in words (38 to 48).
        var start = 0
        var startLength: UInt16 = 0
        var loop = 0
        var loopLength: UInt16 = 0
        /// The vibrato's ticks left before its next step and how many it waits each time (50, 52), its
        /// steps up and down (54, 56), and its ticks left before it starts with each note, and how many
        /// that is (58, 60).
        var vibratoCount: UInt16 = 0
        var vibratoReload: UInt16 = 0
        var vibratoUp: UInt16 = 0
        var vibratoDown: UInt16 = 0
        var vibratoDelay: UInt16 = 0
        var vibratoDelayReload: UInt16 = 0
        // (The long at 62, the first of an envelope's, and the word at 66, set by command 52 and
        // cleared with each note, the player keeps and never reads.)

        /// siday's, not the player's (see `endings`): the places of the jumps (command 56) the voice has
        /// taken since it last came to its end, and whether it is now silent or held for good, as far as
        /// the song goes: in a note or rest that lasts for good, or held at a command that stops it.
        var jumps = InlineArray<8, Int>(repeating: -1)
        var jumpCount = 0
        var resting = false
    }

    private(set) var voices = InlineArray<4, Voice>(repeating: Voice())
    /// What was last written to each of Paula's period and volume registers.
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 1)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)
    private(set) var lightFilter = false

    /// The songs, as the player counts them (`InitPlayer`, $532), and the one being played (counting
    /// from nought).
    let songCount: Int
    private(set) var song = 0
    /// How many samples the player's module information counts (for `tuneInfo`).
    let sampleCount: Int

    /// Super Street Fighter II's: the ticks played since one was let go by (`lbL0097CC`), and how many
    /// are played before one is (`lbL0097D0`, the song's first long).
    private(set) var counted: UInt32 = 0
    private var tempo: UInt32 = 0

    /// What the player tells EaglePlayer of the song's end (`SongEnd`, `SongEndTest`, $4BC): a byte for
    /// each voice, counted up from $FE each time it comes to the end of its list (or to a rest of a
    /// negative length) and kept at nought once it gets there. Once all four are nought, the song has
    /// come to its end, and they are set to $FF, to count again.
    ///
    /// In siday's reckoning, which the player does not tell, a voice also comes to its end when it takes
    /// a jump it has taken since it last came to its end: it is going round within a stretch, as five
    /// of King's Quest VI's songs have a voice do, which otherwise never come to their ends; and when
    /// it starts a note, or a rest of nought, that lasts for good (see `isForGood`), as Super Street
    /// Fighter II's songs end with notes of 65,000 ticks, nearly 22 minutes, at no volume (and one of
    /// King's Quest VI's with a note of nought, held). A song that comes to its end with each of its
    /// voices silent or held for good (in such a note or rest, the player's own rests of a negative
    /// length being 65,000 ticks in every file of UnExoticA's, or held at a command that stops it) has
    /// stopped, as the jingles do.
    private var endBytes = InlineArray<4, UInt8>(repeating: 0xFE)
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?

    /// How long each tick is: the player is run by EaglePlayer's timer (it has an interrupt and does
    /// not start one of its own), which UADE's runs on a CIA's timer from $376B, its count for fifty a
    /// second (score.s, `cia_timer_base_value`): 70,940 of Paula's clocks.
    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60
    /// The most commands read for a voice in a tick, more than any file's stretch has between two
    /// notes: a file whose commands go round without a note (which would hang the player) is let go of
    /// there, the voice left as if at a command of nought (siday's choice).
    private static let mostCommands = 4096
    /// The most songs taken: more than any file has, and fewer than a broken table can count (siday's
    /// choice).
    static let mostSongs = 64

    /// True for a file the player's check takes (`Check2`, $3C2): a first word of 8, or of 4 (the song
    /// table's place); four longs at the song table (or, for the second format, after the song's first
    /// long) each an offset less than 32K, even and not nought, which are the first song's lists; and,
    /// from the first of those on, a list whose first entry is an offset as those are, to a stretch
    /// that starts (after a command 48, if it has one) with a command 12 and then a command 4, the
    /// instrument, whose offset is kept for `init`. (The check counts its way through the lists by the
    /// offset it has just read, not by four, as its ripper does: it goes on past the fourth, into what
    /// follows, until one is found or one fails.)
    static func isOne(_ data: [UInt8]) -> Bool { firstInstrument(data) != nil }

    /// What `Check2` finds: the offset of the first song's first instrument, and the format.
    private static func firstInstrument(_ data: [UInt8]) -> (Int, Format)? {
        func word(_ at: Int) -> UInt16? {
            at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : nil
        }
        func long(_ at: Int) -> UInt32? {
            guard let high = word(at), let low = word(at + 2) else { return nil }
            return UInt32(high) << 16 | UInt32(low)
        }
        /// An offset as the check takes one: a long whose first word is nought and whose second is
        /// positive, even and not nought.
        func isOffset(_ value: UInt32) -> Bool {
            let low = UInt16(truncatingIfNeeded: value)
            return value >> 16 == 0 && low != 0 && low & 0x8001 == 0
        }
        guard let first = word(0), first == 8 || first == 4, let at24 = long(24) else { return nil }
        let format: Format = at24 != 0 ? .flink : .streetFighter
        let lists = first == 4 && at24 != 0 ? 4 : 8
        for i in 0 ..< 4 {
            guard let value = long(lists + 4 * i), isOffset(value) else { return nil }
        }
        var at = lists
        while true {
            guard let list = long(at), let stretch = long(Int(list)), isOffset(stretch) else { return nil }
            at += 4
            var command = Int(stretch)
            if word(command) == 0x30 { command += 2 }
            if word(command) == 12 {
                command += 6
                if word(command) == 4, let instrument = long(command + 2) { return (Int(instrument), format) }
            }
        }
    }

    /// Reads the module and starts song `song` (counting from nought; one past the last is the first).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        size = data.count
        memoryCapacity = Self.moduleAt + data.count + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        memory[Self.restAt + 17] = 0xFF
        memory[Self.firstCommandAt + 1] = 8
        memory[Self.firstListAt + 7] = 1
        for (i, byte) in data.enumerated() { memory[Self.moduleAt + i] = byte }

        let found = Self.firstInstrument(data)
        format = found?.1 ?? .flink
        func word(_ at: Int) -> UInt16 { at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0 }
        func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }

        // `InitPlayer` ($532): the songs, for the first format as many as there are offsets at the song
        // table, in fours (as for the check, but for a sign); for the second, the table's length from
        // the next one's place, the file's second word, at 32 bytes a song.
        var count: UInt32 = 0
        if format == .flink {
            var at = Int(Int16(bitPattern: word(0)))
            while at + 3 < data.count, word(at) == 0, word(at + 2) != 0, word(at + 2) & 1 == 0 {
                count += 1
                at += 4
            }
            count >>= 2
        } else {
            count = (UInt32(word(2)) &- 8) >> 5
        }
        songCount = max(1, min(Self.mostSongs, Int(count)))

        // The samples the module information counts: from the instrument the check found, back through
        // those before it (each 14 bytes, starting with the word 1), and so on while they go on.
        var samples = 0
        var refusal: TuneError?
        if let (instrument, _) = found, word(instrument) == 1 {
            var at = instrument, first = instrument
            repeat {
                first = at
                at -= 14
            } while at >= 0 && word(at) == 1
            if word(first - 2) != 8, word(first - 2) != 0 { first += 14 }
            while first + 1 < data.count, word(first) == 1 {
                samples += 1
                first += 14
            }
        } else {
            refusal = .malformed("not Dave Lowe's music")
        }
        sampleCount = samples
        // Wanted Team's mend of the data of one of Beneath a Steel Sky's songs, which it knows by its 18
        // samples, five songs and the long at 56, $74: three of its lists' entries, an offset and what
        // follows it, made nought and 1.
        if samples == 18, count & 0xFFFF == 5, long(56) == 0x74 {
            for at in [124, 188, 284] {
                for i in 0 ..< 8 { memory[Self.moduleAt + at + i] = i == 7 ? 1 : 0 }
            }
        }

        // (Refused only once it is all made, that it may be undone as a whole.)
        if let refusal { throw refusal }
        begin(song)
    }

    deinit { memory.deallocate() }

    private func word(_ at: Int) -> UInt16 {
        guard at >= 0, at + 1 < memoryCapacity else { return 0 }
        return UInt16(memory[at]) << 8 | UInt16(memory[at + 1])
    }

    private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }

    /// A place in the module, from an offset the module gives (which the player adds to the module's
    /// address, as a long).
    private func place(_ offset: UInt32) -> Int { Self.moduleAt + Int(offset) }

    mutating func select(song: Int) throws(TuneError) { begin(song) }

    /// Starts song `song`, as a player newly loaded would; and finds how long it is.
    private mutating func begin(_ song: Int) {
        self.song = song >= 0 && song < songCount ? song : 0
        initialise()
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        initialise()
    }

    /// `InitSound` ($608) and the player's `Init` (`lbC023098`, $7DA, or `lbC009B30`, $14D4): Paula's
    /// voices stopped, quiet and at a period of 1 (`End`), the four voices cleared, each given its list
    /// of the song from the song table (16 bytes a song for the first format; for the second, 32,
    /// whose first long is its tempo), and sent to it by the first command.
    private mutating func initialise() {
        voices = .init(repeating: Voice())
        paulaPeriods = .init(repeating: 1)
        paulaVolumes = .init(repeating: 0)
        lightFilter = false
        endBytes = .init(repeating: 0xFE)
        endings = 0
        stops = 0
        counted = 0
        let table = place(0) + Int(Int16(bitPattern: word(place(0))))
        var at: Int
        if format == .flink {
            at = table + 16 * song
            tempo = 0
        } else {
            at = table + 32 * song
            tempo = long(at)
            at += 4
        }
        for v in 0 ..< 4 {
            voices[v].number = UInt16(v + 1)
            voices[v].listStart = place(long(at + 4 * v))
        }
    }

    /// Runs the player for a tick (`Play` or `Play_2`), telling `output` what Paula is to do, in the
    /// order the player tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if format == .streetFighter {
            // A tick is let go by once as many as the song's tempo have been played.
            counted &+= 1
            if counted > tempo {
                counted = 0
                return 20
            }
        }
        for v in 0 ..< 4 { play(v, &output) }
        return 20
    }

    /// The voice's tick (`lbC0235EC`, $CE4; `lbC00A186`, $1B08, is the same): its next note, or its note
    /// going on, and its effects and envelope.
    private mutating func play<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        guard voices[v].number != 0 else { return }
        if voices[v].ticks == 0 {
            voices[v].resting = false
            fetch(v, &output)
            return
        }
        if voices[v].ticks == 1 {
            // (`lbC0237E0`, $EEA) The note's last tick: a sample with a loop is stopped.
            if voices[v].kind != 0 { output.off(v) }
        } else if voices[v].kind == 3 {
            // (`lbC023750`, $E4E) The tick after the note began: Paula is told the loop.
            output.takeNextBuffer(v, start: voices[v].loop, length: voices[v].loopLength)
            voices[v].kind = 1
        }
        voices[v].ticks &-= 1
        effects(v)
        envelope(v)
    }

    /// `lbC023614` ($D0C): the slide and the vibrato, and the period they make told to Paula if either
    /// changed it.
    private mutating func effects(_ v: Int) {
        var period = voices[v].period
        var changed = false
        if voices[v].slide != 0 {
            if voices[v].slideDelay != 0 {
                voices[v].slideDelay &-= 1
            } else {
                changed = true
                let target = voices[v].slideTarget
                if voices[v].slide == 1 {
                    period &+= voices[v].slideStep
                    if target < period {
                        period = target
                        voices[v].slide = 0
                    }
                } else {
                    period &-= voices[v].slideStep
                    if target >= period {
                        period = target
                        voices[v].slide = 0
                    }
                }
            }
        }
        if voices[v].vibrato != 0 {
            if voices[v].vibratoDelay != 0 {
                voices[v].vibratoDelay &-= 1
            } else if voices[v].vibratoCount != 0 {
                voices[v].vibratoCount &-= 1
            } else {
                voices[v].vibratoCount = voices[v].vibratoReload
                changed = true
                if voices[v].vibrato < 3 {
                    period &-= voices[v].vibratoDown
                    voices[v].vibrato &+= 1
                } else {
                    period &+= voices[v].vibratoUp
                    voices[v].vibrato &+= 1
                    if voices[v].vibrato == 5 { voices[v].vibrato = 1 }
                }
            }
        }
        if changed {
            voices[v].period = period
            paulaPeriods[v] = period
        }
    }

    /// `lbC0236E0` ($DE2): the envelope's next word, its volume, its last held where it is followed by
    /// $FF. (The player would take off its fade, which EaglePlayer's never sets, and EaglePlayer's
    /// volume, 64 of 64; what Paula is told is the word's low seven bits, `ChangeVolume`.)
    private mutating func envelope(_ v: Int) {
        var at = voices[v].envelope
        if word(at) == 0xFF { at -= 2 }
        paulaVolumes[v] = word(at) & 0x7F
        voices[v].envelope = at + 2
    }

    /// `lbC023768` ($E66): the voice's commands, up to its next note or rest, and that begun.
    private mutating func fetch<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        var at = voices[v].commands
        for _ in 0 ..< Self.mostCommands {
            let command = word(at)
            at += 2
            if command > 100 {
                // A note: its period and how many ticks it lasts; its envelope and vibrato started
                // again, and its sample (`lbC023736`, $E1C, for one with a loop) started.
                voices[v].period = command
                paulaPeriods[v] = command
                let ticks = word(at)
                voices[v].ticks = ticks &- 1
                at += 2
                if Self.isForGood(ticks) {
                    voices[v].resting = true
                    songEndTest(v)
                }
                voices[v].commands = at
                voices[v].envelope = voices[v].envelopeStart
                voices[v].vibratoDelay = voices[v].vibratoDelayReload
                if voices[v].vibrato != 0 { voices[v].vibrato = 1 }
                if voices[v].kind != 0 {
                    voices[v].kind = 3
                    output.takeNextBuffer(v, start: voices[v].start, length: voices[v].startLength)
                }
                output.on(v)
                envelope(v)
                return
            }
            // The commands (the table at $F16), each a multiple of four; one of 60 or more is taken as
            // nought.
            switch command < 60 ? command : 0 {
            case 4:
                // (`lbC02386A`, $F7A) The instrument, 14 bytes: its kind, and a sample played once,
                // told to Paula now; or a start and a loop, kept for its notes.
                let instrument = place(long(at))
                at += 4
                let kind = word(instrument)
                voices[v].kind = kind
                if kind == 0 {
                    output.takeNextBuffer(v, start: place(long(instrument + 2)), length: word(instrument + 6))
                } else {
                    voices[v].start = place(long(instrument + 2))
                    voices[v].startLength = word(instrument + 6)
                    voices[v].loop = place(long(instrument + 8))
                    voices[v].loopLength = word(instrument + 12)
                }
            case 8:
                // (`lbC0238C4`, $FE0) On to the next stretch of the voice's list; at its end, nought, to
                // its first again (`lbC0239D0`, $10FC), which is the voice's end of the song.
                var entry = voices[v].list
                if long(entry) == 0 {
                    entry = voices[v].listStart
                    voices[v].list = entry + 4
                    songEndTest(v)
                } else {
                    voices[v].list = entry + 4
                }
                at = place(long(entry))
            case 12:
                // (`lbC0238E6`, $1014) The volume envelope, after a long the player keeps and never reads.
                voices[v].envelopeStart = place(long(at)) + 4
                at += 4
            case 16:
                // (`lbC0238FC`, $1028) A slide: its way, step, target and delay.
                voices[v].slide = word(at)
                voices[v].slideStep = word(at + 2)
                voices[v].slideTarget = word(at + 4)
                voices[v].slideDelay = word(at + 6)
                at += 8
            case 20:
                // (`lbC023908`, $1034) A vibrato, started.
                voices[v].vibrato = 1
                voices[v].vibratoCount = word(at)
                voices[v].vibratoReload = word(at + 2)
                voices[v].vibratoUp = word(at + 4)
                voices[v].vibratoDown = word(at + 6)
                voices[v].vibratoDelay = word(at + 8)
                voices[v].vibratoDelayReload = word(at + 10)
                at += 12
            case 24:
                // (`lbC02391E`, $104A) No slide.
                voices[v].slide = 0
            case 28:
                // (`lbC023926`, $1052) No vibrato.
                voices[v].vibrato = 0
            case 32:
                // (`lbC0237C2`, $EC4) A rest, of so many ticks, quiet: one of a negative length (as
                // Wanted Team's player has it), or of nought (in siday's reckoning), is also the voice's
                // end of the song.
                let ticks = word(at)
                at += 2
                if Self.isForGood(ticks) {
                    voices[v].resting = true
                    songEndTest(v)
                }
                voices[v].ticks = ticks &- 1
                voices[v].commands = at
                voices[v].envelope = Self.restAt
                paulaVolumes[v] = 0
                envelope(v)
                return
            case 36, 40:
                // (`lbC02392E`, $105A) The voice stopped and quiet, and the period of Paula's first
                // voice (whichever voice this is, for the four of the music) set to 1. Its commands
                // stay where they were, to be read again at the next tick.
                output.off(v)
                paulaPeriods[0] = 1
                paulaVolumes[v] = 0
                voices[v].resting = true
                return
            case 44:
                // (`lbC023852`, $F62) The power light on, and the filter with it.
                lightFilter = true
            case 48:
                // (`lbC02385E`, $F6E) The light off, and the filter.
                lightFilter = false
            case 52:
                // (`lbC0239C6`, $10F2) A mark the player never reads.
                break
            case 56:
                // (`lbC023844`, $F56) On to another place in the module. (A jump taken again is the
                // voice's end, in siday's reckoning: see `endings`.)
                let jump = at - 2
                if (0 ..< voices[v].jumpCount).contains(where: { voices[v].jumps[$0] == jump }) {
                    songEndTest(v)
                } else if voices[v].jumpCount < 8 {
                    voices[v].jumps[voices[v].jumpCount] = jump
                    voices[v].jumpCount += 1
                }
                at = place(long(at))
            default:
                // Nought (`lbC023840`, $F52): nothing done, the commands left where they were, to be
                // read again at the next tick. (One between, not a multiple of four, would have the
                // player jump to no command, and is taken as nought.)
                voices[v].resting = true
                return
            }
        }
        // (Commands that go round without a note: let go of, as at nought.)
        voices[v].resting = true
    }

    /// A note or rest of so many ticks lasts for good, in siday's reckoning (see `endings`): 32,768 or
    /// more (over ten minutes), or nought, which the player counts down from 65,535.
    private static func isForGood(_ ticks: UInt16) -> Bool { ticks == 0 || ticks & 0x8000 != 0 }

    /// `SongEndTest` ($4BC), for the voice that has come to its end (or, for a jump taken again or a note
    /// that lasts for good, has in siday's reckoning: see `endings`).
    private mutating func songEndTest(_ v: Int) {
        voices[v].jumpCount = 0
        if endBytes[v] != 0 { endBytes[v] &+= 1 }
        if endBytes[0] == 0, endBytes[1] == 0, endBytes[2] == 0, endBytes[3] == 0 {
            endBytes = .init(repeating: 0xFF)
            endings += 1
            if voices[0].resting, voices[1].resting, voices[2].resting, voices[3].resting { stops += 1 }
        }
    }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    /// Paula's volume for the voice, as the player last set it (no more than 127; Paula takes 64 or more
    /// as full).
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] }
}

/// Dave Lowe's music, played on Paula by `PaulaTickRenderer`.
extension DaveLoweNewPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Dave Lowe New")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Dave Lowe's music, \(format.name); \(sampleCount) sample\(plural)"
        return info
    }

    /// Dave Lowe's music is louder on the Amiga's chip than ProTracker's is, by 1.5 dB in the middle
    /// of UnExoticA's 41 files, and is turned down by that (2026-10-19).
    var gain: Float { 0.39 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
