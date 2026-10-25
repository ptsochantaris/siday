// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after DeliTracker's player "Dave Lowe's Sound System" ("Dave Lowe DeliPlayer V1.0 (3/9/97) by
// DARKNESS/SYNERGY", carried by UADE as players/DaveLowe_Deli, of which there is no source; "Player
// ripped, Module-ized and adapted" by him, as it says): its replay routine, Dave Lowe's own, read from a
// disassembly of it. The addresses given are of that player's file in UADE: those in its first code hunk
// (its interface to DeliTracker) marked so, the rest in its second (the replay routine, from `Init` at $0).

import SidayChips
import SidayFoundation

/// Dave Lowe's music for the Amiga, as DARKNESS of Synergy ripped it in 1996 and 1997 (UnExoticA's "Older
/// DL Version"s, of Frontier: Elite II and of MicroProse's Formula One Grand Prix): the music alone, as one
/// hunk of an AmigaDOS program, played by the replay routine of DeliTracker's player. The hunk begins
/// `MOVEQ #-1,D0; RTS` (it is not to be run) and "DAVELOWE", a byte of version and one of revision, a
/// word of how many songs it has, and for each song 22 bytes: the addresses of its four voices' lists
/// of the stretches of commands they play in turn, of its name, and a word of how slowly it fades in
/// (nought for not at all). The stretches, the instruments, the volume envelopes and the samples
/// follow, in the form that Dave Lowe's later music has (`DaveLoweNewPlayer`'s), but with addresses,
/// which the program's relocations make, where that has offsets.
///
/// The same music ripped later, by Wanted Team with the code that played it in the game, is
/// `DaveLoweCodePlayer`'s: what the two tell Paula, tick by tick, is the same, song for song and to each
/// song's end (as UADE plays each; checked 2026-10-25), but for the order of Frontier's songs (this
/// rip's first is the other's tenth, and its others the other's first to eighth; the other's ninth,
/// a moment's silence, is not here), the first song's start, which fades in here where the other's
/// waits six seconds, and the last chord of Blue Danube, a second and a half shorter here.
///
/// It owns the memory Paula plays from: a few words of the player's own, the hunk after them, loaded
/// and relocated as LoadSeg would, and room after that. Where the player would read past it, it reads
/// noughts; where it would go round for ever within a tick, or jump to no command, it is done as said
/// where it is done (see `fetch`).
struct DaveLoweSoundSystemPlayer: ~Copyable {
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// How many bytes the program's hunks take in memory.
    let size: Int
    /// Where the hunk is loaded in `memory`: after the player's own words.
    static let moduleAt = 32
    /// Where Paula starts a voice that has not been told where to: the room after the hunks.
    var silenceAt: Int { Self.moduleAt + size }
    /// Room after that, as for any player of `PaulaTickRenderer`'s, for no mixing: far enough after the
    /// hunks that a sample told a length, however long, reads only silence.
    var mixingAt: Int { Self.moduleAt + size + 0x20000 }
    static let mixingSpace = 2048
    /// The most the program may take: the most chip memory an Amiga of its day had (siday's choice).
    static let mostSize = 0x20_0000

    /// The player's own words, before the hunk: the envelope of a rest ($48E, nine words of nought and
    /// then $FF, which holds the last); the first command a voice is given ($4AA, 8, on to the next
    /// stretch of its list); and the list it is given first ($4A2, nought, which is its end, and so sends
    /// it to the start of its song's own).
    static let restAt = 0
    static let firstCommandAt = 20
    static let firstListAt = 24

    /// One voice of the four, as the player keeps them (68 bytes each, cleared by `Init`), the offsets
    /// of each in its record given. Places are in `memory`.
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
        /// Where it is in its volume envelope (18), where its commands are (22), where in its song's list
        /// it is and where that list starts (26, 30), and where its envelope starts (34).
        var envelope = DaveLoweSoundSystemPlayer.restAt
        var commands = DaveLoweSoundSystemPlayer.firstCommandAt
        var list = DaveLoweSoundSystemPlayer.firstListAt
        var listStart = 0
        var envelopeStart = DaveLoweSoundSystemPlayer.restAt
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
        /// What is added to every word of the envelope (64, the second word of the long before the
        /// envelope, which command 12 keeps at 62), while it is to be (66, set by command 52, cleared
        /// with each stretch of commands read).
        var envelopeLift: UInt16 = 0
        var lifted = false
    }

    private(set) var voices = InlineArray<4, Voice>(repeating: Voice())
    /// What was last written to each of Paula's period and volume registers.
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)

    /// The fading in of a song (the player's bytes and words at 6 to 15 of its data): how far it has
    /// come, of 64; by how much it comes on each step; and how many of the writes of a volume are let go
    /// by between steps, and are left of them. The volume of the two sides (at 0 and 1), which
    /// DeliTracker's volume and balance set and UADE leaves at 64, is 64.
    private var fade: UInt8 = 64
    private var fadeStep: UInt8 = 0
    private var fadeWait: UInt16 = 0
    private var fadeCount: UInt16 = 0
    private static let sideVolume: UInt32 = 64

    /// Where the songs' entries start in `memory` (each 22 bytes), and each song's name.
    private let songTable: Int
    let songCount: Int
    let songNames: [String]
    private(set) var song = 0
    /// The most songs taken: more than any file has, and fewer than a broken one can count (siday's
    /// choice).
    static let mostSongs = 64

    /// When the song has come to its end. The player itself says so at a command that starts the song
    /// again (60 or 64), with which each of Frontier's songs ends; in siday's reckoning, as Wanted Team's
    /// player has it for the same music ripped with its code (`DaveLoweCodePlayer`), a voice also comes
    /// to its end when it comes to the end of its list of stretches (as Formula One Grand Prix's do), or
    /// to a note or rest of a negative length. A byte for each voice is counted up from $FE each time
    /// (its first list, the player's own, is ended at once) and kept at nought once it gets there; once
    /// all four are nought, the song has come to its end, and they are set to $FF, to count again.
    private var endBytes = InlineArray<4, UInt8>(repeating: 0xFE)
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?

    /// How long each tick is: the player is run by DeliTracker's timer (it has an interrupt and does
    /// not start one of its own), which UADE's runs on a CIA's timer from $376B, its count for fifty a
    /// second (score.s, `cia_timer_base_value`): 70,940 of Paula's clocks.
    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60
    /// The most commands read for a voice in a tick, more than any file's stretch has between two
    /// notes: a file whose commands go round without a note (which would hang the player) is let go of
    /// there, the voice left as if at a command of nought (siday's choice).
    private static let mostCommands = 4096

    /// True for a file the player's check takes (`Check1`, $12E of its first hunk): an AmigaDOS program
    /// (its first long $3F3) with, 32 bytes in, where a program of one hunk has its hunk, `MOVEQ #-1,D0;
    /// RTS` and "DAVELOWE", then a version no later than the player's, 1.0.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 46 && long(data, 0) == 0x3F3 && long(data, 32) == 0x70FF_4E75 && long(data, 36) == 0x4441_5645
            && long(data, 40) == 0x4C4F_5745 && data[44] <= 1 && data[45] == 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= data.count else { return 0 }
        return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
    }

    /// Loads the program, as the player's `InitPlayer` has it loaded ($172 of its first hunk: LoadSeg,
    /// and its count of songs the word 14 bytes into its first hunk, its songs' entries after it), and
    /// starts song `song` (counting from nought, as the player's do from one).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        var refusal: TuneError?
        var total = 0
        if !Self.isOne(data) {
            refusal = .malformed("not a module of Dave Lowe's Sound System")
        } else {
            do throws(TuneError) {
                total = try AmigaHunks.sizes(data).reduce(0) { ($0 + $1 + 7) & ~7 }
                if total > Self.mostSize {
                    total = 0
                    refusal = .malformed("a module of Dave Lowe's larger than the Amiga's memory")
                }
            } catch {
                refusal = error
            }
        }
        size = total
        memoryCapacity = Self.moduleAt + total + 0x20000 + Self.mixingSpace
        let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        self.memory = memory
        memory[Self.restAt + 19] = 0xFF
        memory[Self.firstCommandAt + 1] = 8
        memory[Self.firstListAt + 7] = 1

        var base = Self.moduleAt
        if refusal == nil {
            do throws(TuneError) {
                let segments = try AmigaHunks.load(data, at: UInt32(Self.moduleAt), into: memory,
                                                   capacity: Self.moduleAt + total)
                base = Int(segments.first?.address ?? UInt32(Self.moduleAt))
            } catch {
                refusal = error
            }
        }
        func word(_ at: Int) -> UInt16 { at >= 0 && at + 1 < total + Self.moduleAt ? UInt16(memory[at]) << 8 | UInt16(memory[at + 1]) : 0 }
        func long(_ at: Int) -> Int { Int(UInt32(word(at)) << 16 | UInt32(word(at + 2))) }
        let count = refusal == nil ? Int(word(base + 14)) : 0
        if refusal == nil, count == 0 { refusal = .malformed("a module of Dave Lowe's with no songs") }
        songTable = base + 16
        songCount = max(1, min(Self.mostSongs, count))
        // Each song's name: as many printable characters as there are at the place its entry gives.
        var names: [String] = []
        for s in 0 ..< songCount {
            var at = long(base + 16 + 22 * s + 16)
            var name: [UInt8] = []
            if refusal == nil {
                while name.count < 64, at > 0, at < total + Self.moduleAt, memory[at] >= 0x20, memory[at] < 0x7F {
                    name.append(memory[at])
                    at += 1
                }
            }
            names.append(String(decoding: name, as: UTF8.self))
        }
        songNames = names
        // (Refused only once it is all made, that it may be undone as a whole.)
        if let refusal { throw refusal }
        begin(song)
    }

    deinit { memory.deallocate() }

    private func word(_ at: Int) -> UInt16 {
        guard at >= 0, at + 1 < memoryCapacity else { return 0 }
        return UInt16(memory[at]) << 8 | UInt16(memory[at + 1])
    }

    /// A long, as an address in `memory` (the program's are, as LoadSeg relocated them).
    private func long(_ at: Int) -> Int { Int(UInt32(word(at)) << 16 | UInt32(word(at + 2))) }

    mutating func select(song: Int) throws(TuneError) { begin(song) }

    /// Starts song `song`, as a player newly loaded would; and finds how long it is.
    private mutating func begin(_ song: Int) {
        self.song = song >= 0 && song < songCount ? song : 0
        initialise()
        var none = Unheard()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        initialise()
    }

    /// The player's `InitSound` ($1C8 of its first hunk) and `Init` ($0, from $1A): Paula's voices
    /// stopped and quiet (`Stop`, $C6), the four voices cleared, each given its list of the song from
    /// its entry and sent to it by the first command; and the song's fade, from the word 20 bytes into
    /// its entry: for nought, none; otherwise from nought, one step every so many writes and one.
    private mutating func initialise() {
        voices = .init(repeating: Voice())
        paulaVolumes = .init(repeating: 0)
        endBytes = .init(repeating: 0xFE)
        endings = 0
        stops = 0
        startSong()
        paulaPeriods = .init(repeating: 0)
    }

    /// `Init` from $1A: the voices given their lists, and the fade set, for the song; Paula's volumes
    /// nought.
    private mutating func startSong() {
        voices = .init(repeating: Voice())
        paulaVolumes = .init(repeating: 0)
        let entry = songTable + 22 * song
        for v in 0 ..< 4 {
            voices[v].number = UInt16(v + 1)
            voices[v].listStart = long(entry + 4 * v)
        }
        let wait = word(entry + 20)
        if wait == 0 {
            fade = 64
            fadeCount = 0
            fadeWait = 0
        } else {
            fade = 0
            fadeStep = 1
            fadeWait = wait
            fadeCount = wait
        }
    }

    /// What a voice's tick leaves Paula's DMA for it as.
    private enum Ending { case on, off, restarted }

    /// Runs the player for a tick (`Interrupt`, $EE), telling `output` what Paula is to do, in the order
    /// the player tells her: each voice's tick, then its DMA turned on (or, at the last tick of a note of
    /// an instrument with a loop, off), every tick. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        for v in 0 ..< 4 {
            switch play(v, &output) {
            case .on:
                output.on(v)
            case .off:
                output.off(v)
            case .restarted:
                // (`SongEnd` at $3DC: DeliTracker told, and the song started again from `Init`'s $1A, in
                // the middle of the tick: Paula's four voices stopped, as `Stop` does, then this voice's
                // DMA turned on again, as after any voice's tick, and the voices after it played.)
                endings += 1
                endBytes = .init(repeating: 0xFE)
                for u in 0 ..< 4 { output.off(u) }
                startSong()
                output.on(v)
            }
        }
        return 20
    }

    /// The voice's tick ($172): its next note, or its note going on, and its effects and envelope.
    private mutating func play<Output: TFMXOutput>(_ v: Int, _ output: inout Output) -> Ending {
        guard voices[v].number != 0 else { return .on }
        if voices[v].ticks == 0 { return fetch(v, &output) }
        var ending = Ending.on
        if voices[v].ticks == 1 {
            // ($37C) The note's last tick: a sample with a loop is stopped.
            if voices[v].kind != 0 { ending = .off }
        } else if voices[v].kind == 3 {
            // ($300) The tick after the note began: Paula is told the loop.
            output.takeNextBuffer(v, start: voices[v].loop, length: voices[v].loopLength)
            voices[v].kind = 1
        }
        voices[v].ticks &-= 1
        effects(v)
        envelope(v)
        return ending
    }

    /// $196: the slide and the vibrato, and the period they make told to Paula if either changed it.
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

    /// $264: the envelope's next word, its volume (with the voice's lift added, while it is lifted), its
    /// last held, unlifted, where it is followed by $FF.
    private mutating func envelope(_ v: Int) {
        var at = voices[v].envelope
        let volume: UInt16
        if word(at) == 0xFF {
            volume = word(at - 2)
        } else {
            volume = voices[v].lifted ? word(at) &+ voices[v].envelopeLift : word(at)
            at += 2
        }
        setVolume(v, volume)
        voices[v].envelope = at
    }

    /// $28E: a volume told to Paula, turned down by its side's volume and the song's fade (each as a part
    /// of 64, and the product's low word taken, as the player's MULU and LSR.W do), and the fade taken a
    /// step on, with each volume written of each voice.
    private mutating func setVolume(_ v: Int, _ volume: UInt16) {
        let turned = UInt16(truncatingIfNeeded: Self.sideVolume * UInt32(fade)) >> 6
        paulaVolumes[v] = UInt16(truncatingIfNeeded: UInt32(volume) * UInt32(turned)) >> 6
        if fade != 64 {
            if fadeCount != 0 {
                fadeCount &-= 1
            } else {
                fadeCount = fadeWait
                fade &+= fadeStep
            }
        }
    }

    /// $318: the voice's commands, up to its next note or rest, and that begun.
    private mutating func fetch<Output: TFMXOutput>(_ v: Int, _ output: inout Output) -> Ending {
        voices[v].lifted = false
        var at = voices[v].commands
        for _ in 0 ..< Self.mostCommands {
            let command = word(at)
            at += 2
            if command > 100 {
                // ($32A) A note: its period and how many ticks it lasts; its envelope and vibrato
                // started again, and its sample (`$2EC`, for one with a loop) started.
                voices[v].period = command
                paulaPeriods[v] = command
                let ticks = word(at)
                voices[v].ticks = ticks &- 1
                at += 2
                if ticks & 0x8000 != 0 { songEndTest(v) }
                voices[v].commands = at
                voices[v].envelope = voices[v].envelopeStart
                voices[v].vibratoDelay = voices[v].vibratoDelayReload
                if voices[v].vibrato != 0 { voices[v].vibrato = 1 }
                if voices[v].kind != 0 {
                    voices[v].kind = 3
                    output.takeNextBuffer(v, start: voices[v].start, length: voices[v].startLength)
                }
                envelope(v)
                return .on
            }
            // The commands (the table at $398, read by the command as an offset into it), each a
            // multiple of four up to 64; another is taken as nought (siday's choice: the player would
            // jump to an address read from between its table's entries or from the code after it).
            switch command <= 64 && command & 3 == 0 ? command : 0 {
            case 4:
                // ($3F4) The instrument, 14 bytes: its kind, and a sample played once, told to Paula
                // now; or a start and a loop, kept for its notes.
                let instrument = long(at)
                at += 4
                let kind = word(instrument)
                voices[v].kind = kind
                if kind == 0 {
                    output.takeNextBuffer(v, start: long(instrument + 2), length: word(instrument + 6))
                } else {
                    voices[v].start = long(instrument + 2)
                    voices[v].startLength = word(instrument + 6)
                    voices[v].loop = long(instrument + 8)
                    voices[v].loopLength = word(instrument + 12)
                }
            case 8:
                // ($41C) On to the next stretch of the voice's list; at its end, nought, to its first
                // again ($478), which is the voice's end of the song, in Wanted Team's reckoning.
                var entry = voices[v].list
                if long(entry) == 0 {
                    entry = voices[v].listStart
                    songEndTest(v)
                }
                voices[v].list = entry + 4
                at = long(entry)
            case 12:
                // ($42E) The volume envelope, after a long whose second word is its lift.
                let envelope = long(at)
                at += 4
                voices[v].envelopeLift = word(envelope + 2)
                voices[v].envelopeStart = envelope + 4
            case 16:
                // ($43C) A slide: its way, step, target and delay.
                voices[v].slide = word(at)
                voices[v].slideStep = word(at + 2)
                voices[v].slideTarget = word(at + 4)
                voices[v].slideDelay = word(at + 6)
                at += 8
            case 20:
                // ($448) A vibrato, started.
                voices[v].vibrato = 1
                voices[v].vibratoCount = word(at)
                voices[v].vibratoReload = word(at + 2)
                voices[v].vibratoUp = word(at + 4)
                voices[v].vibratoDown = word(at + 6)
                voices[v].vibratoDelay = word(at + 8)
                voices[v].vibratoDelayReload = word(at + 10)
                at += 12
            case 24:
                // ($45E) No slide.
                voices[v].slide = 0
            case 28:
                // ($466) No vibrato.
                voices[v].vibrato = 0
            case 32:
                // ($35E) A rest, of so many ticks: Paula's volume nought, and the rest's envelope begun
                // (which a lift still lifts). One of a negative length is also the voice's end of the
                // song, in Wanted Team's reckoning.
                let ticks = word(at)
                at += 2
                if ticks & 0x8000 != 0 { songEndTest(v) }
                voices[v].ticks = ticks &- 1
                voices[v].commands = at
                voices[v].envelope = Self.restAt
                paulaVolumes[v] = 0
                envelope(v)
                return .on
            case 44, 48:
                // ($3F0) Nothing.
                break
            case 52:
                // ($46E) The envelope lifted, for the note to come.
                voices[v].lifted = true
            case 56:
                // ($3EA) On to another place in the module.
                at = long(at)
            case 60, 64:
                // ($3DC) The song's end, and its start again.
                return .restarted
            default:
                // Nought ($3E6), and 36 and 40 ($3E8): nothing done, and the commands left where they
                // were, to be read again at the next tick (and those before it in the stretch done again).
                return .on
            }
        }
        // (Commands that go round without a note: let go of, as at nought.)
        return .on
    }

    /// Wanted Team's `SongEndTest`, as `DaveLoweCodePlayer` has it, for the voice that has come to its
    /// end (see `endings`).
    private mutating func songEndTest(_ v: Int) {
        if endBytes[v] != 0 { endBytes[v] &+= 1 }
        if endBytes[0] == 0, endBytes[1] == 0, endBytes[2] == 0, endBytes[3] == 0 {
            endBytes = .init(repeating: 0xFF)
            endings += 1
        }
    }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    /// Paula's volume for the voice, as the player last set it: the seven bits of it that she keeps.
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] & 0x7F }

    private struct Unheard: TFMXOutput {
        mutating func on(_: Int) {}
        mutating func off(_: Int) {}
        mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
        func loopCount(_: Int) -> UInt16 { 0 }
    }
}

/// Dave Lowe's music, played on Paula by `PaulaTickRenderer`.
extension DaveLoweSoundSystemPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Dave Lowe")
        info.author = "Dave Lowe"
        let plural = songCount == 1 ? "" : "s"
        info.detail = "Dave Lowe's Sound System, as DARKNESS of Synergy ripped it; \(songCount) song\(plural)"
        return info
    }

    /// As loud as the same music ripped with its code (`DaveLoweCodePlayer`), which it is.
    var gain: Float { 0.24 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
