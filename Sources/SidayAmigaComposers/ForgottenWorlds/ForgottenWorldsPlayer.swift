// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the replay routine of Forgotten Worlds (ARC Developments' Amiga version of Capcom's game, 1989,
// its music by Mark Cooksey) as Psygore adapted it for EaglePlayer ("Forgotten Worlds module player V1.1
// (22 April 98)"), carried by UADE as players/ForgottenWorlds_Game, of which there is no source: what is said
// here was read from its code, and the addresses given are that code's (its first hunk's).

import SidayChips
import SidayFoundation

/// The music of Forgotten Worlds, in files that begin "FWMP": the game's tunes, each of four voices, each
/// voice a stream of bytes. After the mark, three longs give where (from the file's sixteenth byte) the table
/// of called streams, the instruments and the samples are; and from the sixteenth byte four words give where
/// each voice's stream begins. A byte under $80 is a note (into a table of periods of four octaves) and the
/// byte after it how many ticks it lasts; $84 and a byte choose the instrument; $86 and a byte rest for so many
/// ticks; $88 and a byte go to a stream of the table and $8A comes back from it; $82 goes back to the voice's
/// beginning and $80 stops it. An instrument is eight bytes: the sample (a place in the table of samples, which
/// gives where its sound and its loop are and their lengths in words), and a volume's envelope: the level it
/// falls to and stays at, how fast it rises (from what it begins at, which is that too) to 64 and falls to that
/// level, for how many ticks it stays there (none: no envelope, the volume stays as it began), and how fast it
/// falls after.
///
/// This is the game's player, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`), and so is run by
/// EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second
/// and a little less. On every tick each voice's count of ticks comes down, and at nought the voice reads its
/// stream to its next note or rest; a note is started at once (`$2FA`): the voice is turned off, its period set
/// to 1 and its volume to nought, and once Paula has said (by her interrupt) that she has let go of it, it is
/// told its sample, period and volume and turned on, and once she has said she has begun it, its loop. Between
/// notes the envelope moves the volume (`$1FC`, `$2A6`).
///
/// Each voice's writes are told Paula at their moments in the tick (`TFMXOutput.timed(at:)`), near where they
/// fall in UADE's dumps: some 150 of Paula's clocks for a voice's envelope, and for a note some 380 clocks of waiting on
/// her before its sample is told, and 740 before the next voice is begun.
///
/// Its tunes go round for ever, each voice by itself (in the title's two voices are a little shorter than the
/// other two): the song is said here to have come to its end once each voice has gone back to its beginning, or
/// stopped, at least once since it began or last ended; and to have stopped there, if every voice has stopped
/// or goes round with nothing but rests. Where the player would read past the file it reads nought; a command
/// its table has not got (which would crash the machine), and a stream that goes round without a note or a rest
/// (which would hang it), stop the voice for the tick, as $80 does.
struct ForgottenWorldsPlayer: ~Copyable {
    /// The file and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed, and where the player's two words of silence (`$A0` in
    /// its data, where it points the voices as it begins) are: the noughts after the file.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where the four streams' words are (the file's sixteenth byte, `$DA`), and the tables of called streams
    /// (`$DE`), instruments (`$E2`) and samples (`$E6`).
    private let base: Int
    private let calls: Int
    private let instruments: Int
    private let samples: Int

    /// What the player keeps for each voice, in its data's 40 bytes for it.
    private struct Voice {
        /// Its count of ticks to its next reading of its stream (byte 1), and where it reads (byte 2) and where
        /// it began (byte 36), and where a called stream comes back to (byte 26).
        var count: UInt8 = 0
        var stream = 0
        var beginning = 0
        var returnTo = 0
        /// Its instrument's eight bytes (byte 6; none, whose bytes are noughts, before it is given one), and
        /// its note's period (byte 10) and volume (word 12).
        var instrument: Int?
        var period: UInt16 = 0
        var volume: UInt16 = 0
        /// Its sample's sound and loop (bytes 14 to 24), the places in memory and the lengths in words.
        var start = -1
        var length: UInt16 = 0
        var loopStart = -1
        var loopLength: UInt16 = 0
        /// Where its envelope is (the routine at byte 30), and its count of ticks at the level (byte 34).
        var envelope = Envelope.rising
        var held: UInt8 = 0
        /// For the song's end: whether it has gone back to its beginning or stopped since the song began or
        /// last ended, whether it has stopped, and whether it has had a note since it last went round.
        var reached = false
        var stopped = false
        var noted = false
        var quiet = false
    }

    /// The envelope's four parts (`$2A6`, `$2BE`, `$2DC`, `$2EC`), and its end (the `rts` at `$2EA`).
    private enum Envelope { case rising, falling, held, dying, done }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// What each of Paula's period and volume registers was last given, and what they held as the tick just
    /// run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told at their
    /// moments).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// How many instruments the file has (from the table's size, which the next table follows).
    let instrumentCount: Int

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60
    /// How many bytes of commands a voice may read in a tick before it is taken to have gone round without
    /// a note (the collection's streams read fewer than ten).
    private static let mostCommands = 1024

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (near the medians of its dumps of
    /// the five tunes, with the player's first voices' DMA put on as it begins, without which UADE's Paula never
    /// lets the first note's wait end): the first voice's after the interrupt begins (a guess: only the distances between the
    /// voices are heard); the next voice's after a voice's envelope; after a voice with nothing to tell; a
    /// note's sample and its DMA turned on, and its loop, after it is begun; and the next voice's after it.
    static let firstWrite = 300
    static let envelopeClocks = 155
    static let idleClocks = 100
    static let sampleClocks = 380
    static let onClocks = 440
    static let loopClocks = 590
    static let noteClocks = 740

    /// The table of periods (`$40E`): from $6B0, four octaves less two notes, and a nought.
    static let periodTable: [UInt16] = [
        0x6B0, 0x650, 0x5F0, 0x5A0, 0x550, 0x500, 0x4B8, 0x478, 0x438, 0x3F8, 0x3C0, 0x388,
        0x358, 0x328, 0x2F8, 0x2D0, 0x2A8, 0x280, 0x25C, 0x23C, 0x21C, 0x1FC, 0x1E0, 0x1C4,
        0x1AC, 0x194, 0x17C, 0x168, 0x154, 0x140, 0x12E, 0x11E, 0x10E, 0x0FE, 0x0F0, 0x0E2,
        0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0,
    ]

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func signedWord(_ at: Int) -> Int { Int(Int16(bitPattern: word(at))) }

    /// A byte of the voice's instrument; nought before it has one.
    @inline(__always) private func instrumentByte(_ v: Int, _ k: Int) -> UInt8 {
        guard let instrument = voices[v].instrument else { return 0 }
        return byte(instrument &+ k)
    }

    private static func long(_ data: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at + 3 < data.count else { return 0 }
        return Int(Int32(bitPattern: UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])))
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`$F8`): one that begins "FWMP".
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 4 && data[0] == 0x46 && data[1] == 0x57 && data[2] == 0x4D && data[3] == 0x50
    }

    /// Reads the file and starts its song (it has one: `song` is taken for that one, whatever it is).
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        // (`InitPlayer`, `$10A`: the places from the sixteenth byte.)
        base = 16
        calls = 16 &+ Self.long(data, 4)
        instruments = 16 &+ Self.long(data, 8)
        samples = 16 &+ Self.long(data, 12)
        instrumentCount = max(0, min(256, (samples - instruments) / 8))
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Forgotten Worlds file") }
        guard data.count >= 24 else { throw .malformed("too short for its four voices") }

        start()
        // The song's length, from a playing of it in silence to its end.
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, stops == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again.)
        lengthClocks = endings > 0 || stops > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        start()
    }

    deinit { memory.deallocate() }

    /// `InitSound` (`$37C`): each voice set to read its stream on the first tick, and Paula's four pointed at
    /// two words of silence at period $7C and volume nought.
    private mutating func start() {
        voices = .init(repeating: Voice())
        for v in 0 ..< 4 {
            let stream = base + Int(word(base + 2 * v))
            voices[v].stream = stream
            voices[v].beginning = stream
            voices[v].count = 1
        }
        periods = .init(repeating: 0x7C)
        volumes = .init(repeating: 0)
        periodsBefore = periods
        volumesBefore = volumes
        endings = 0
        stops = 0
    }

    var songCount: Int { 1 }
    var song: Int { 0 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    /// Runs the player for a tick (`$186`), telling `output` what Paula is to do, in the order the player tells
    /// her: all four voices' DMA turned on (as it does on every tick), and then each voice's note or envelope.
    /// Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        for v in 0 ..< 4 { output.on(v) }
        var at = Self.firstWrite
        voicesLoop: for v in 0 ..< 4 {
            voices[v].count &-= 1
            guard voices[v].count == 0 else {
                // (`$1FC`: no envelope for an instrument held for no ticks.)
                guard instrumentByte(v, 4) != 0 else {
                    at += Self.idleClocks
                    continue
                }
                envelope(v)
                output.timed(at: at)
                volumes[v] = voices[v].volume
                output.writeVolume(v, volumes[v])
                at += Self.envelopeClocks
                continue
            }
            var stream = voices[v].stream
            var commands = 0
            while true {
                let command = byte(stream)
                stream &+= 1
                guard command >= 0x80 else {
                    // A note: its period, how long it lasts, and its instrument's volume to begin at.
                    let index = Int(command) * 2
                    voices[v].period = index < Self.periodTable.count * 2 ? Self.periodTable[Int(command)] : 0
                    voices[v].count = byte(stream)
                    voices[v].stream = stream &+ 1
                    voices[v].volume = voices[v].volume & 0xFF00 | UInt16(instrumentByte(v, 2))
                    voices[v].noted = true
                    play(v, at: at, &output)
                    voices[v].envelope = .rising
                    at += Self.noteClocks
                    continue voicesLoop
                }
                commands += 1
                switch commands < Self.mostCommands ? command : 0x80 {
                case 0x82:
                    // Back to the voice's beginning (`$23C`).
                    stream = voices[v].beginning
                    voices[v].quiet = !voices[v].noted
                    voices[v].noted = false
                    reached(v)
                case 0x84:
                    // An instrument (`$244`): its eight bytes, and its sample's four words, its sound's place
                    // and length and its loop's, from the table of samples. (The sample's byte is put into the
                    // low byte of what found the instrument, eight times its number.)
                    let number = UInt16(bitPattern: Int16(Int8(bitPattern: byte(stream))) << 3)
                    stream &+= 1
                    let instrument = instruments &+ Int(Int16(bitPattern: number))
                    voices[v].instrument = instrument
                    let entry = samples &+ Int(Int16(bitPattern: number & 0xFF00 | UInt16(byte(instrument))))
                    voices[v].start = samples &+ signedWord(entry)
                    voices[v].length = word(entry &+ 2)
                    voices[v].loopStart = voices[v].start &+ signedWord(entry &+ 4)
                    voices[v].loopLength = word(entry &+ 6)
                case 0x86:
                    // A rest (`$27C`), for so many ticks.
                    voices[v].count = byte(stream)
                    voices[v].stream = stream &+ 1
                    at += Self.idleClocks
                    continue voicesLoop
                case 0x88:
                    // A called stream (`$288`), from the table of them.
                    let number = Int(Int8(bitPattern: byte(stream))) * 2
                    stream &+= 1
                    voices[v].returnTo = stream
                    stream = calls &+ signedWord(calls &+ number)
                case 0x8A:
                    // Back from it (`$29E`).
                    stream = voices[v].returnTo
                default:
                    // $80 (`$238`): the rest of the tick is not played. (Its `clr.w (a5)` clears a word of
                    // EaglePlayer's that nothing here reads.) The voice reads the $80 again when its count of
                    // ticks next comes to nought, 256 ticks on.
                    voices[v].stopped = true
                    reached(v)
                    break voicesLoop
                }
            }
        }
        return 20
    }

    /// `$2FA`: a note started on its voice, its sample, period and volume told Paula once she has let go of what
    /// it played, and its loop once she has begun it.
    private mutating func play<Output: TFMXOutput>(_ v: Int, at: Int, _ output: inout Output) {
        output.timed(at: at)
        output.off(v)
        periods[v] = 1
        output.writePeriod(v, 1)
        volumes[v] = 0
        output.writeVolume(v, 0)
        output.timed(at: at + Self.sampleClocks)
        output.takeNextBuffer(v, start: voices[v].start < 0 ? silenceAt : voices[v].start, length: voices[v].length)
        periods[v] = voices[v].period
        output.writePeriod(v, periods[v])
        // (`$3FA`: the volume times EaglePlayer's, 64, over 64.)
        volumes[v] = voices[v].volume
        output.writeVolume(v, volumes[v])
        output.timed(at: at + Self.onClocks)
        output.on(v)
        output.timed(at: at + Self.loopClocks)
        output.takeNextBuffer(v, start: voices[v].loopStart < 0 ? silenceAt : voices[v].loopStart, length: voices[v].loopLength)
    }

    /// The envelope moved on a tick (the routine at the voice's byte 30), on its volume's low byte: up by the
    /// instrument's third byte to 64, down by its fourth to its second, held for its fifth's ticks, and down by
    /// its sixth until it would go below nought, where it is nought and stays so.
    private mutating func envelope(_ v: Int) {
        var level = UInt8(truncatingIfNeeded: voices[v].volume)
        switch voices[v].envelope {
        case .rising:
            level &+= instrumentByte(v, 2)
            if level >= 0x40 {
                level = 0x40
                voices[v].envelope = .falling
            }
        case .falling:
            level &+= instrumentByte(v, 3)
            if level <= instrumentByte(v, 1) {
                level = instrumentByte(v, 1)
                voices[v].held = instrumentByte(v, 4)
                voices[v].envelope = .held
            }
        case .held:
            voices[v].held &-= 1
            if voices[v].held == 0 { voices[v].envelope = .dying }
        case .dying:
            level &+= instrumentByte(v, 5)
            if level >= 0x80 {
                voices[v].envelope = .done
                voices[v].volume = 0
                return
            }
        case .done:
            return
        }
        voices[v].volume = voices[v].volume & 0xFF00 | UInt16(level)
    }

    /// A voice that has gone back to its beginning or stopped: once all four have, the song's end (and its
    /// stop, if none of them has a note to play).
    private mutating func reached(_ v: Int) {
        voices[v].reached = true
        for w in 0 ..< 4 where !voices[w].reached { return }
        endings += 1
        var silent = true
        for w in 0 ..< 4 {
            if !voices[w].stopped, !voices[w].quiet { silent = false }
            voices[w].reached = voices[w].stopped
        }
        if silent { stops += 1 }
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

/// Forgotten Worlds' music, played on Paula by `PaulaTickRenderer`.
extension ForgottenWorldsPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Forgotten Worlds")
        let plural = instrumentCount == 1 ? "" : "s"
        info.detail = "FWMP, the game's own replayer; \(instrumentCount) instrument\(plural)"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -18.3 dB.)
    var gain: Float { 0.23 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
