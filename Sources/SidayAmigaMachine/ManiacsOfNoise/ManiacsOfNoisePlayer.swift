// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Heikki Orsila's player of these modules for UADE ("MON player module V0.1 for UADE
// (01.01.2002)", carried by UADE as players/ManiacsOfNoise, whose source is UADE's
// amigasrc/players/uade/mon/ManiacsOfNoise.asm: its routines are named here as it names them), and UADE's
// host for such players (amigasrc/score/score.s), which calls them and keeps the positions its
// `UadeSongEndHelperStep` is given (src/uade.c, `AMIGAMSG_SONG_END_HELPER_STEP`). The addresses given in
// a module are those of the driver of Charles Deenen's "The Lord of the Rings" (its title), as a
// disassembly of it has them; the others' are laid out the same, a few bytes further on or back.

import SidayChips
import SidayFoundation
import SidayM68000

/// The music of the Maniacs of Noise, the Dutch group of Charles Deenen and Jeroen Tel, from about 1990
/// on, played by Charles Deenen's own driver: each module is the 68000 code he wrote to play it, which
/// writes Paula's registers itself, with the music and the samples after it. It is run on an emulated
/// Amiga (`AmigaMachine`), as UADE runs it: started by its routine for that, and then its routine for a
/// tick called fifty times a second (a little less: by the CIA's timer DeliTracker and UADE set for a
/// player that has no timer of its own, `TFMXTiming.fiftyTimes`). What it writes to Paula is heard at
/// the moment it writes it within the tick.
///
/// A module begins with three jumps, each a `JMP (PC)`: to its routine that readies the driver, to the
/// one that plays a tick, and to the one that starts a song (with its number, from one, in D0, and in
/// D1 how fast it is to be faded in, or nought) or with nought stops the music. The driver's
/// variables are kept after its code, from where its first routine's `LEA (PC),A5` points; a song is a
/// list of patterns for each voice, a pattern a list of notes and commands of a byte or two, with envelopes
/// of volume and of vibrato for each instrument, and a song may fade in, fade out and stop.
///
/// A song has come to its end when the place every voice is at, in its list of patterns and in its
/// pattern, how long it waits for its next note, and how many times its pattern is still to be played,
/// is a place they were all at together before, since the song began; and the song has stopped when the
/// driver stops the music, as it does once it has faded out or is told to stop. The positions are the
/// player's (`Interrupt`), read before each tick, and its end is UADE's, which keeps them. (The player
/// as UADE's source has it, and built there: an earlier build of it, which some installations of UADE
/// still carry, never ends a song, which plays on until UADE's time for a song is up.) Each song's
/// length is found by playing it through in silence.
struct ManiacsOfNoisePlayer: ~Copyable {
    /// Where the module is put: anywhere would do, for the driver's code is all relative to itself.
    static let moduleAddress: UInt32 = 0x11000
    private static let stackTop: UInt32 = 0x10000
    /// The room after the module that is kept empty, and where a voice that is pointed nowhere plays.
    private static let room = 0x20000 + 2048
    static let tickClocks = TFMXTiming.fiftyTimes
    /// How long a song is played through to find its end, at most: ten minutes, which is longer than
    /// UADE plays a song that does not end (512 seconds).
    private static let mostTicks = 50 * 60 * 10
    /// The processor's time a call is given: a song's start a fifth of a second, and a tick the whole of
    /// its frame, more than which no Amiga had to give it (the busiest of UnExoticA's modules takes a
    /// tenth of it).
    private static let startBudget = 10 * AmigaMachine.frameCycles
    private static let tickBudget = AmigaMachine.frameCycles
    /// The processor's time a song's playing through in silence is given, and all of a module's songs':
    /// many times what UnExoticA's busiest takes for ten minutes, and no more, for a module that is broken.
    private static let dryRunBudget: Int64 = 600_000_000
    private static let dryRunsBudget: Int64 = 3_000_000_000

    let layout: Layout
    private let data: [UInt8]
    private var machine: AmigaMachine
    private var feed: AmigaPaulaFeed
    private(set) var writes: [AmigaWrite] = []
    /// What the song's start wrote to Paula (and the filter), heard as its first tick begins.
    private(set) var startWrites: [AmigaWrite] = []
    /// The places the voices have been at together since the song began.
    private var positions = Set<Position>()
    /// The word the player's volume is put into: the driver's own volume of the music, which the first
    /// routine leaves A1 pointing at (`InitPlayer` keeps it as `volumeptr`).
    private var volumeAt: UInt32?
    /// The processor's cycles the last tick took, and all the playings through so far.
    private(set) var tickCycles = 0
    private(set) var dryRuns: Int64 = 0

    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    private var lengths: [UInt64??]

    var memory: UnsafeMutablePointer<UInt8> { machine.memory }
    var memoryCapacity: Int { machine.memorySize }
    var silenceAt: Int { Int(Self.moduleAddress) + data.count + Self.room / 2 }
    var mixingAt: Int { silenceAt }
    var songCount: Int { layout.songCount }

    /// True for a module the player's check (`Check2`) takes.
    static func isOne(_ data: [UInt8]) -> Bool { (try? Layout(data)) != nil }

    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        var refusal: TuneError?
        let layout: Layout
        do {
            layout = try Layout(data)
        } catch {
            layout = .none
            refusal = error
        }
        self.layout = layout
        self.data = data
        let size = (Int(Self.moduleAddress) + data.count + Self.room + 0xFFF) & ~0xFFF
        machine = AmigaMachine(chipRAM: size)
        feed = AmigaPaulaFeed(memorySize: machine.memorySize)
        lengths = [UInt64??](repeating: nil, count: layout.songCount)
        // (Refused only once it is all made.)
        if let refusal { throw refusal }
        guard Int(Self.moduleAddress) + data.count + Self.room <= machine.memorySize else {
            throw .unsupported("a module of the Maniacs of Noise larger than the Amiga's chip RAM")
        }
        try select(song: song >= 0 && song < layout.songCount ? song : 0)
    }

    // MARK: The module

    /// What the player's check (`Check2`) finds in a module.
    struct Layout {
        /// Offsets into the module of the routines the three jumps go to.
        var initAt: Int
        var playAt: Int
        var songAt: Int
        /// Where the driver's variables are (its first routine's `LEA (PC),A5`), and the offset in them
        /// of its flags, whose bit 0 is set while it plays (the `BCLR #0` that routine begins with).
        var variables: Int
        var flags: Int
        /// The layout of the driver's variables for each voice, as the player has them for its three
        /// kinds of driver (`format_variant_constants`), which it tells by the offset of the flags.
        var voicesAt: Int
        var voiceSize: Int
        var waitAt: Int
        var repeatsAt: Int
        var songCount: Int
        /// What the module says of itself, between its jumps and its first routine.
        var text: String

        static let none = Layout(initAt: 0, playAt: 0, songAt: 0, variables: 0, flags: 0, voicesAt: 0,
                                 voiceSize: 0, waitAt: 0, repeatsAt: 0, songCount: 0, text: "")

        private init(initAt: Int, playAt: Int, songAt: Int, variables: Int, flags: Int, voicesAt: Int,
                     voiceSize: Int, waitAt: Int, repeatsAt: Int, songCount: Int, text: String)
        {
            self.initAt = initAt
            self.playAt = playAt
            self.songAt = songAt
            self.variables = variables
            self.flags = flags
            self.voicesAt = voicesAt
            self.voiceSize = voiceSize
            self.waitAt = waitAt
            self.repeatsAt = repeatsAt
            self.songCount = songCount
            self.text = text
        }

        /// The check: three `JMP (PC)`s at the module's start, the first to a routine that begins with
        /// a `LEA (PC),A5` and a `BCLR #0,d16(A5)`; and the number of songs, from the routine that starts
        /// one, whose `CMP.B d16(A5),D0` ($DA) compares the song asked for with a byte of the variables.
        init(_ data: [UInt8]) throws(TuneError) {
            let bad = TuneError.malformed("not a module of the Maniacs of Noise, or one cut short")
            func word(_ at: Int) throws(TuneError) -> Int {
                guard at >= 0, at + 1 < data.count else { throw bad }
                return Int(data[at]) << 8 | Int(data[at + 1])
            }
            func signed(_ at: Int) throws(TuneError) -> Int { Int(Int16(truncatingIfNeeded: try word(at))) }
            guard try word(0) == 0x4EFA, try word(4) == 0x4EFA, try word(8) == 0x4EFA else { throw bad }
            initAt = try 2 + signed(2)
            playAt = try 6 + signed(6)
            songAt = try 10 + signed(10)
            guard try word(initAt) == 0x4BFA, try word(initAt + 4) == 0x08AD, try word(initAt + 6) == 0 else { throw bad }
            variables = try initAt + 2 + signed(initAt + 2)
            flags = try word(initAt + 8)
            // (Of the kind of the first, the kind any other is taken for: as the player takes it.)
            switch flags {
            case 0x122: (voicesAt, voiceSize, waitAt, repeatsAt) = (32, 64, 0x1C, 0x32)
            case 0x13A: (voicesAt, voiceSize, waitAt, repeatsAt) = (56, 64, 0x1C, 0x32)
            default: (voicesAt, voiceSize, waitAt, repeatsAt) = (72, 84, 0x24, 0x3D)
            }
            guard try word(songAt + 0x16) == 0xB02D else {
                throw .unsupported("a module of the Maniacs of Noise whose number of songs the player does not find")
            }
            let count = try variables + word(songAt + 0x18)
            guard count >= 0, count < data.count else { throw bad }
            songCount = Int(data[count])
            guard songCount > 0 else { throw .malformed("a module of the Maniacs of Noise with no songs") }
            for at in [variables + flags, variables + voicesAt + 4 * voiceSize] where at < 0 || at > data.count {
                throw bad
            }
            var text = ""
            for at in stride(from: 12, to: min(initAt, data.count), by: 1) {
                let byte = data[at]
                if byte >= 0x20, byte < 0x7F { text.append(Character(Unicode.Scalar(byte))) } else if !text.isEmpty { break }
            }
            var trimmed = Substring(text)
            while trimmed.first == " " { trimmed.removeFirst() }
            while trimmed.last == " " { trimmed.removeLast() }
            self.text = String(trimmed)
        }
    }

    /// The place the voices are at, as the player tells it (`Interrupt`): for each voice, how far it is
    /// into its list of patterns and into its pattern (the pointers at 4 and 12 of its variables, less
    /// the starts at 0 and 8), how long it waits for its next note (a word), and how many times its
    /// pattern is still to be played (a byte): twelve bytes, with a byte of nought.
    private struct Position: Hashable {
        var longs = InlineArray<12, UInt32>(repeating: 0)

        static func == (a: Position, b: Position) -> Bool {
            for i in 0 ..< 12 where a.longs[i] != b.longs[i] { return false }
            return true
        }

        func hash(into hasher: inout Hasher) {
            for i in 0 ..< 12 { hasher.combine(longs[i]) }
        }
    }

    private func position() -> Position {
        var p = Position()
        var at = Self.moduleAddress &+ UInt32(layout.variables + layout.voicesAt)
        for v in 0 ..< 4 {
            p.longs[v * 3] = machine.peek32(at &+ 4) &- machine.peek32(at)
            p.longs[v * 3 + 1] = machine.peek32(at &+ 12) &- machine.peek32(at &+ 8)
            p.longs[v * 3 + 2] = UInt32(machine.peek16(at &+ UInt32(layout.waitAt))) << 16
                | UInt32(machine.peek8(at &+ UInt32(layout.repeatsAt))) << 8
            at = at &+ UInt32(layout.voiceSize)
        }
        return p
    }

    /// True while the driver plays.
    private var playing: Bool {
        machine.peek8(Self.moduleAddress &+ UInt32(layout.variables + layout.flags)) & 1 != 0
    }

    // MARK: Playing

    /// Starts a song afresh, as UADE does: the machine switched on, the module put into it, and the
    /// song started as the player's `InitPlayer` and `InitSound` start it: the driver readied (the first
    /// jump, with nought in D0: not to drop one tick in six, as it would for an American Amiga's sixty),
    /// and again, the song's routine called with its number in D0 and nought in D1 (not faded in), and
    /// the player's volume, all of it, put into the driver's own (`Volume`), which the song's start has
    /// set to the song's (a module of "Mysterious Worlds" has one of its songs at 50).
    private mutating func start(_ song: Int) throws(TuneError) {
        machine.powerOn()
        machine.load(data, at: Self.moduleAddress)
        machine.quietPaula()
        feed.reset()
        positions.removeAll(keepingCapacity: true)
        endings = 0
        stops = 0
        var used = 0
        try call(0, d0: 0, budget: Self.startBudget)
        used += machine.cycles
        let a1 = machine.cpu.registers[9]
        volumeAt = a1 & 1 == 0 && Int(a1) + 2 <= machine.memorySize ? a1 : nil
        try call(0, d0: 0, budget: Self.startBudget)
        used += machine.cycles
        try call(8, d0: UInt32(song + 1), budget: Self.startBudget)
        used += machine.cycles
        if let volumeAt { machine.poke16(volumeAt, 64) }
        machine.takeWrites(into: &startWrites)
        for i in startWrites.indices { startWrites[i].cycles = 0 }
        machine.advance(clocks: used / 2)
    }

    private mutating func call(_ offset: Int, d0: UInt32, budget: Int) throws(TuneError) {
        for r in 0 ..< 16 { machine.cpu.registers[r] = 0 }
        machine.cpu.registers[0] = d0
        let address = Self.moduleAddress &+ UInt32(offset)
        machine.cpu.registers[8] = Self.moduleAddress
        let outcome = machine.call(address, stack: Self.stackTop, budget: budget)
        guard outcome == .returned else { throw .malformed("the driver of the Maniacs of Noise did not come back as it should") }
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < layout.songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        if lengths[song] == nil {
            // Played through in silence to its end: the tick it ends in is the first of it again, or the
            // first of the silence after it.
            try start(song)
            var none = Unheard()
            var ticks = 0
            var used: Int64 = 0
            while endings == 0, stops == 0, ticks < Self.mostTicks, used < Self.dryRunBudget, dryRuns < Self.dryRunsBudget {
                _ = run(&none)
                ticks += 1
                used += Int64(tickCycles)
                dryRuns += Int64(tickCycles)
            }
            lengths[song] = .some(endings > 0 || stops > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil)
        }
        lengthClocks = lengths[song] ?? nil
        try start(song)
    }

    /// Runs a tick, as the player's `Interrupt` does: the voices' place told (and the song's end, if it
    /// is one they have been at before), then the driver's routine for a tick called (the second jump).
    /// What it wrote is told `output` at the moments it wrote it. Returns the tick's length in
    /// milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        feed.beginTick()
        if !startWrites.isEmpty {
            feed.tell(startWrites, &output)
            startWrites.removeAll(keepingCapacity: true)
        }
        // (Once the driver has stopped, its place stays where it is: the song has ended, and does not
        // end again.)
        let wasPlaying = playing
        if wasPlaying {
            let place = position()
            if !positions.insert(place).inserted {
                // (And the places kept afresh from here, so that it ends again when it has gone round again.)
                endings += 1
                positions.removeAll(keepingCapacity: true)
                positions.insert(place)
            }
        }
        var failed = false
        do throws(TuneError) {
            try call(4, d0: 0, budget: Self.tickBudget)
        } catch {
            failed = true
        }
        tickCycles = machine.cycles
        machine.takeWrites(into: &writes)
        feed.tell(writes, &output)
        machine.advance(clocks: Self.tickClocks)
        if failed {
            // (Code that does not come back has gone wrong, and the song is over.)
            stops += 1
        } else if wasPlaying, !playing {
            // The driver has stopped the music: once faded out, with every voice's DMA turned off, which
            // is the song's stopping; or told to by a command of its list, which turns off the DMA of
            // voices of no meaning (the low bits of the high byte of its first variable, an address, none
            // in UADE or here) and leaves the rest sounding as they were, which is the song's end, with
            // its last notes still heard.
            let dmacon = machine.chips.dmacon
            if dmacon & 0x200 == 0 || dmacon & 0xF == 0 { stops += 1 } else { endings += 1 }
        }
        return 20
    }

    private struct Unheard: TFMXOutput {
        mutating func on(_: Int) {}
        mutating func off(_: Int) {}
        mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
        func loopCount(_: Int) -> UInt16 { 0 }
    }
}

/// The music of the Maniacs of Noise, played on Paula by `PaulaTickRenderer`.
extension ManiacsOfNoisePlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Maniacs of Noise")
        info.comment = layout.text
        return info
    }

    /// The Maniacs of Noise's music is quieter on the Amiga's chip than ProTracker's is, by 1.7 dB in the middle of
    /// UnExoticA's 21 files, and is turned up by that (2026-10-19).
    var gain: Float { 0.56 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }

    /// What Paula's registers held as the tick began (see `AmigaPaulaFeed`).
    func period(_ voice: Int) -> UInt16 { feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { feed.volumes[voice] }
    var lightFilter: Bool { feed.lightFilter }
}
