// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Reinier van Vliet's Digital Mugician players (1990), as Wanted Team keep
// them in their EaglePlayer modules ("Mugician player module V1.1 (29 Nov 2001)" and "Mugician II player
// module V1.7 (3 May 2014)", carried by UADE as `Mugician` and `MugicianII`), whose sources UADE also
// carries (amigasrc/players/wanted_team/Mugician/src/Mugician_v2.asm and MugicianII/src/Mugician
// II_v8.asm). Labels are those sources'; the first's are given, but for what is the second's alone.

/// Digital Mugician, Reinier van Vliet's tracker (in UnExoticA's collection, the music of Borobodur,
/// Winter Camp, Bump 'n' Burn, Hoi and Quest of Agravain), and Mugician II, its seven-voice successor
/// (Clockwiser, and Borobodur's CX5-ZAD).
///
/// A module has eight songs, each a list of positions giving each voice a pattern of 64 rows and a
/// transpose; patterns, of a note, an instrument, and a command or a note to slide to on each row;
/// instruments, each a waveform of the module's 128-byte ones or one of its samples, with a volume
/// envelope and a vibrato read from waveforms, an arpeggio, a fine tune, and an effect that rewrites its
/// waveform as it plays (smoothing it, morphing it into another, shifting it round, and so on).
///
/// A Mugician II song is two of the module's: its first three voices are the first's, played by Paula,
/// and four more are the second's, which the player mixes by the processor into one buffer that Paula's
/// first voice plays (`mix`).
///
/// This is the players' own code, as it tells Paula what to do, tick by tick: what it tells her is
/// what UADE's running of those players tells her for UnExoticA's modules. It owns the memory Paula plays
/// from, which is the module, as the players have it, with room after it (and Mugician II's two
/// buffers after that). The players write into the module as they play, rewriting waveforms and
/// instruments' places in their effects: that is done here in this memory, for Paula to play what she
/// would.
struct MugicianPlayer: ~Copyable {
    /// Which of the two players.
    enum Kind: Sendable {
        case one, two
    }

    let kind: Kind
    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of `memory` are the module's.
    let size: Int
    /// Where Paula starts a voice that has not been told where to: the room after the module, of noughts.
    var silenceAt: Int { size }
    /// Room after the module, as for any player of `PaulaTickRenderer`'s, which mixes nothing in it:
    /// far enough after the module that a sample told a length, however long, reads only silence.
    var mixingAt: Int { size + 0x20000 }
    static let mixingSpace = 2048
    /// Mugician II's two buffers that Paula's first voice plays in turn (`lbL010FB4` and `lbL0111B4`),
    /// after the room.
    var buffersAt: Int { mixingAt + Self.mixingSpace }
    static let bufferBytes = 592
    let memoryCapacity: Int
    /// The module as it is in its file, for the players' writes to be undone when a song starts again.
    private let original: [UInt8]

    /// The parts of the module, as the players' setting up finds them ($6D8A): the instruments
    /// (`lbL00855C`), the waveforms (`lbL008564`), the samples' headers (`lbL00856C`), the patterns
    /// (`lbL008568`), the samples (`lbL008570`), the arpeggios (`lbL008560`), and where each song's
    /// positions are.
    private let instruments: Int
    private let waveforms: Int
    private let sampleHeaders: Int
    private let patterns: Int
    private let samples: Int
    private let arpeggios: Int
    private let positions: InlineArray<8, Int>
    /// The songs as EaglePlayer's modules count them, each the number of the module's song it begins with.
    private let songStarts: [Int]
    private(set) var song = 0
    /// The songs' names, as the module has them.
    private let titles: [String]

    /// A voice, as the players keep it (48 bytes each from `lbL008400`), named by what each variable
    /// is; the numbers are their offsets.
    struct Voice {
        /// The pattern (3), the instrument (5), the note (7) and the position's transpose (9).
        var pattern: UInt8 = 0
        var instrument: UInt8 = 0
        var note: UInt8 = 0
        var transpose: UInt8 = 0
        /// The row's third byte, a note to slide to (11); its fourth, the command's parameter or the
        /// slide's speed (13); and the command (15): 1 for a note, or $40 to $4B less $3E.
        var slideNote: UInt8 = 0
        var parameter: UInt8 = 0
        var command: UInt8 = 0
        /// The period (16), the instrument's fine tune (19).
        var period: UInt16 = 0
        var fineTune: UInt8 = 0
        /// True while the next tick is to start a sample's loop (20).
        var loopNext = false
        /// The volume envelope: where it is (22) and the ticks left until its next step (24).
        var envelopeAt: UInt16 = 0
        var envelopeTicks: UInt16 = 0
        /// Where the arpeggio is (26).
        var arpeggioAt: UInt16 = 0
        /// The vibrato: ticks before it begins (29), and where it is in its waveform (30).
        var vibratoDelay: UInt8 = 0
        var vibratoAt: UInt16 = 0
        /// The sample being played, its header (32).
        var sample = 0
        /// The volume, as the envelope last set it (36).
        var volume: UInt16 = 0
        /// Ticks before the instrument's effect is next run (41).
        var effectTicks: UInt8 = 0
        /// The period a slide goes to (42), and how far it has come (44).
        var target: UInt16 = 0
        var slide: UInt16 = 0
    }

    private(set) var voices = InlineArray<7, Voice>(repeating: Voice())

    /// The song's own variables (`lbW0083EC` on): ticks left until the next row (0), whether the next
    /// tick begins a position (2) and a row (4), the position (6), the row (8), the speed, of two
    /// nibbles played in turn (14), the song's length in positions (16), and its patterns' length in
    /// rows (18).
    private var counter: UInt16 = 0
    private var newPosition = false
    private var newRow = false
    private var position: UInt16 = 0
    private var row: UInt16 = 0
    private var speed: UInt16 = 0
    private var length: UInt16 = 0
    private var patternLength: UInt16 = 0x40
    /// The song's header (`lbL008554`), its positions (`lbL008558`), and for Mugician II those of the
    /// second song, its mixed voices' (`lbL010F90`).
    private var header = 0
    private var sequence = 0
    private var mixedSequence = 0

    /// The filter the power light shows, as the module's commands last set it (`PaulaTickRenderer`
    /// does not play it); and whether a song turns it on, in its playing through for its length.
    private(set) var lightFilter = false
    private(set) var turnsFilterOn = false

    /// What each of Paula's voices was last told.
    private var paulaStarts = InlineArray<4, Int>(repeating: 0)
    private var paulaLengths = InlineArray<4, UInt16>(repeating: 1)
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)

    /// One of Mugician II's four mixed voices, as its mixer keeps them (`lbL010AD0` on): where it is
    /// and where its sample ends, how long its loop is, whether it is silent, the period its step was
    /// last worked out for, and the step, its fraction in the top byte and its whole in the bottom.
    struct MixedVoice {
        var at = 0
        var end = 0
        var loop = 0
        var silent = true
        var period: UInt16 = 0
        var step: UInt32 = 0
    }

    private(set) var mixed = InlineArray<4, MixedVoice>(repeating: MixedVoice())
    /// Which of the two buffers is mixed into next (`lbL01097E`), as an offset into `memory`.
    private var nextBuffer = 0
    private var ticks = 0
    /// Mugician II's mixing: how many words are mixed for each tick (`MixLength`), and the period Paula's
    /// first voice plays them at (`lbW010BD2`).
    let mixWords: Int
    let mixPeriod: UInt16

    /// True from when the song has come to its end until its next position is played, when it is counted.
    private var ending = false
    private(set) var endings = 0
    /// Each song's length in ticks, as it is played through before it begins; nil for one that does not
    /// come round in 59 minutes.
    private(set) var lengths: [Int?] = []
    /// While a song is played through for its length, what is only heard is not done.
    private var heard = true

    private static let mugician: [UInt8] = Array(" MUGICIAN/SOFTEYES 1990 ".utf8) + [0, 1]
    private static let mugicianTwo: [UInt8] = Array(" MUGICIAN2/SOFTEYES 1990".utf8) + [0, 1]

    /// Which player takes a file for one of its modules (their checks, `Check2`): its first 26 bytes,
    /// " MUGICIAN/SOFTEYES 1990 " or " MUGICIAN2/SOFTEYES 1990" and a word of 1.
    static func kind(of data: [UInt8]) -> Kind? {
        guard data.count >= 26 else { return nil }
        if data[0 ..< 26].elementsEqual(mugician) { return .one }
        if data[0 ..< 26].elementsEqual(mugicianTwo) { return .two }
        return nil
    }

    static func isOne(_ data: [UInt8]) -> Bool { kind(of: data) != nil }

    /// The mixing rate Mugician II's player is set to, in kHz (its `MixRate`): what UADE's settings for
    /// it say (players/ENV/EaglePlayer/EP-Mugician_II.cfg, "WT" and 22), which is how UADE plays it.
    static let mixingRate = 22
    /// The period for each rate (`PeriodsTable`).
    private static let mixingPeriods: [UInt16] = [
        0, 3580, 1790, 1193, 895, 716, 597, 511, 447, 398, 358, 325, 298, 275, 256, 239, 224, 211, 199, 188,
        179, 170, 163, 156, 149, 143, 138, 133, 128, 121,
    ]

    /// Reads the module, as the players' setting up does (`InitPlayer`, $6D8A), and starts song `song`
    /// (of those EaglePlayer's modules count).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        let kind = Self.kind(of: data) ?? .one
        self.kind = kind
        size = data.count
        original = data
        memoryCapacity = data.count + 0x20000 + Self.mixingSpace + 2 * Self.bufferBytes
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        func word(_ at: Int) -> Int { at >= 0 && at + 2 <= data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : 0 }
        func long(_ at: Int) -> Int { word(at) << 16 | word(at + 2) }
        // The parts, one after another ($6D8A): the eight songs' positions, eight bytes each, after
        // their headers, then the instruments, the waveforms, the samples' headers, the patterns, the
        // samples and the arpeggios.
        var at = 204
        var positions = InlineArray<8, Int>(repeating: 0)
        var lengths: [Int] = []
        for s in 0 ..< 8 {
            positions[s] = at
            lengths.append(long(28 + 4 * s))
            at += lengths[s] << 3
        }
        self.positions = positions
        instruments = at
        waveforms = instruments + long(60) << 4
        sampleHeaders = waveforms + long(64) << 7
        patterns = sampleHeaders + long(68) << 5
        samples = patterns + word(26) << 8
        arpeggios = samples + long(72)
        // The songs, as EaglePlayer's modules count them (`InitPlayer`, `InitSound`).
        var starts: [Int] = []
        switch kind {
        case .one:
            // Up to the first whose header begins with a long of nought, but for those of one position
            // that is all noughts.
            for s in 0 ..< 8 {
                guard long(76 + 16 * s) != 0 else { break }
                if lengths[s] == 1, long(positions[s]) == 0, long(positions[s] + 4) == 0 { continue }
                starts.append(s)
            }
        case .two:
            // Four, less one for each sixteen bytes of noughts at the end of the positions (as two
            // songs of one position each make), each song two of the module's.
            var count = 4
            var end = instruments
            while count > 0, (0 ..< 4).allSatisfy({ long(end - 16 + 4 * $0) == 0 }) {
                count -= 1
                end -= 16
            }
            starts = (0 ..< count).map { $0 * 2 }
        }
        songStarts = starts
        titles = (0 ..< 8).map { s in String(decoding: data[min(data.count, 80 + 16 * s) ..< min(data.count, 92 + 16 * s)].prefix { $0 != 0 }, as: UTF8.self) }
        // Mugician II's mixing: words to a tick of fifty a second by the CIA's E clock, made a little
        // longer for one module, Moon Child's (`InitData`).
        let period = Self.mixingPeriods[Self.mixingRate]
        mixPeriod = period
        var words = 71591 / Int(period) + 1
        let calculated = 460 + word(26) << 8 + lengths.reduce(0, +) << 3 + long(60) << 4 + long(64) << 7 + long(68) << 5 + long(72)
        if kind == .two, calculated == 625_381 { words = words * 130 / 210 }
        mixWords = words >> 1
        guard Self.kind(of: data) != nil else { throw .unsupported("not a Digital Mugician module") }
        guard calculated <= data.count else { throw .malformed("Digital Mugician module cut short") }
        guard !starts.isEmpty else { throw .malformed("Digital Mugician module with no songs") }
        self.song = starts.indices.contains(song) ? song : 0
        for s in starts.indices {
            start(s)
            heard = false
            self.lengths.append(playThrough())
            heard = true
        }
        start(self.song)
    }

    deinit { memory.deallocate() }

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < memoryCapacity ? memory[at] : 0 }
    @inline(__always) private func sbyte(_ at: Int) -> Int { Int(Int8(bitPattern: byte(at))) }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    @inline(__always) private func long(_ at: Int) -> Int { Int(word(at)) << 16 | Int(word(at + 2)) }

    /// A write of the players' into the module; none outside it is done, which would be into the silence
    /// after it (and which none of UnExoticA's modules makes).
    @inline(__always) private func store(_ value: UInt8, at: Int) {
        if at >= 0, at < size { memory[at] = value }
    }

    /// Song `n` from its beginning, as `Init` ($6E78) has it, with the module as it is in its file.
    private mutating func start(_ n: Int) {
        for (i, b) in original.enumerated() { memory[i] = b }
        for i in size ..< memoryCapacity { memory[i] = 0 }
        let number = songStarts[n]
        header = 76 + 16 * number
        sequence = positions[number]
        mixedSequence = number < 7 ? positions[number + 1] : instruments
        voices = InlineArray(repeating: Voice())
        mixed = InlineArray(repeating: MixedVoice())
        for v in 0 ..< 4 { mixed[v].at = silenceAt }
        nextBuffer = buffersAt
        ticks = 0
        // Paula as `Init` leaves her: the first player sets each voice's length to $7C; the second
        // sets its own three's periods to $7C and their lengths to 2, and its first voice to play a
        // buffer of silence, at its full volume.
        paulaStarts = InlineArray(repeating: silenceAt)
        paulaLengths = InlineArray(repeating: kind == .one ? 0x7C : 2)
        paulaVolumes = InlineArray(repeating: 0)
        paulaPeriods = InlineArray(repeating: kind == .one ? 0 : 0x7C)
        length = UInt16(byte(header + 3))
        let first = byte(header + 2)
        counter = UInt16(first)
        speed = UInt16((first & 15) << 4 | (first & 15))
        newPosition = true
        newRow = true
        patternLength = 0x40
        row = 0
        position = 0
        lightFilter = false
        ending = false
        endings = 0
        if kind == .two {
            paulaPeriods[0] = mixPeriod
            paulaVolumes[0] = 64
            paulaLengths[0] = UInt16(mixWords)
        }
    }

    /// The song is played through, without a sound, for its length.
    private mutating func playThrough() -> Int? {
        var none = Unheard()
        var ticks = 0
        while ticks < Self.longest {
            run(&none)
            if lightFilter { turnsFilterOn = true }
            if endings > 0 { return ticks }
            ticks += 1
        }
        return nil
    }

    /// The most ticks a song is played through for: 59 minutes.
    static let longest = 59 * 60 * 50

    /// How long a tick is, in Paula's clocks. The first player is run by UADE's timer, a CIA's, of
    /// $376B, which comes round every 14,188 of its clocks, each five of Paula's (as UADE's dumps of
    /// Paula's registers show: 70,940 between ticks). Mugician II's is run as Paula's first voice
    /// begins each buffer of its mixing (`Interrupt`, Aud0's), and lasts as long as she plays one.
    var tickClocks: Int { kind == .one ? 14188 * 5 : mixWords * 2 * Int(mixPeriod) }

    /// Paula's voice for each of the players' voices: the first player's in order; Mugician II's first
    /// three on her fourth, second and third, and the rest mixed onto her first.
    private func paulaVoice(_ v: Int) -> Int? {
        kind == .one ? v : v < 3 ? [3, 1, 2][v] : nil
    }

    /// Paula is told where to play from or how long, and both are said, as she then has them.
    private mutating func tell<Output: TFMXOutput>(_ v: Int, start: Int? = nil, length: UInt16? = nil, _ output: inout Output) {
        if let start { paulaStarts[v] = start }
        if let length { paulaLengths[v] = length }
        output.takeNextBuffer(v, start: paulaStarts[v], length: paulaLengths[v])
    }

    /// The period of note `d` (a word, as the players add it up) at fine tune `fineTune`, read as the
    /// players read their table, by a byte offset of a word. Beyond the table it is nought: what the
    /// players read there is not theirs (64 KB on, for a note below nought, as the offset is a word in a
    /// long). In UnExoticA's collection only one voice reads there, CX5-ZAD's second song's third, which
    /// has had no note and is silent: UADE's Paula is told $1418.
    private func period(fineTune: UInt8, note d: UInt16) -> UInt16 {
        let at = MugicianTables.noteNought * 2 + Int(fineTune) * 128 + Int(d &* 2)
        return at >> 1 < MugicianTables.periods.count ? MugicianTables.periods[at >> 1] : 0
    }

    /// Runs the player for one tick (`Play`, $7140; Mugician II's `Interrupt` and `Play`), telling
    /// `output` what Paula is to do. Returns the tick's length in Paula's clocks.
    @discardableResult
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if kind == .two, heard {
            // Paula's first voice plays each buffer the tick after it is mixed (see `mix`). On the first
            // tick she is started on part of a buffer of silence (`leadWords`).
            if ticks == 0 {
                tell(0, start: buffersAt + Self.bufferBytes, length: UInt16(Self.leadWords), &output)
                output.on(0)
            }
        }
        if ending {
            // The position the song goes back to is played: it has come round.
            ending = false
            endings += 1
        }
        // A sample's loop is begun on the tick after it ($7E96).
        for v in 0 ..< (kind == .one ? 4 : 3) where voices[v].loopNext {
            voices[v].loopNext = false
            guard let p = paulaVoice(v) else { continue }
            let header = voices[v].sample
            if long(header + 8) != 0 {
                tell(p, start: samples + long(header + 8), length: UInt16(truncatingIfNeeded: (long(header + 4) - long(header + 8)) >> 1), &output)
            } else {
                // (Eight bytes of nought in chip memory; the second player plays four of them.)
                tell(p, start: silenceAt, length: kind == .one ? 4 : 2, &output)
            }
        }
        for v in 0 ..< (kind == .one ? 4 : 7) {
            let column = kind == .one ? v * 2 : (v < 3 ? v * 2 : (v - 3) * 2)
            let list = kind == .two && v >= 3 ? mixedSequence : sequence
            if let started = playRow(v, column: column, sequence: list, &output), kind == .two, v >= 3 {
                // A mixed voice told a sample takes it up (`Play`, after `lbC00FF9A`).
                mixed[v - 3].at = started.start
                mixed[v - 3].end = started.end
                mixed[v - 3].loop = started.loop
                mixed[v - 3].silent = false
            }
        }
        var done = InlineArray<8, UInt8>(repeating: 0x80)
        var doneCount = 0
        for v in 0 ..< (kind == .one ? 4 : 7) { tick(v, done: &done, count: &doneCount) }
        if kind == .two, heard { mix(&output) }
        advance()
        ticks += 1
        for v in 0 ..< (kind == .one ? 4 : 3) { output.on(paulaVoice(v) ?? 0) }
        return tickClocks
    }

    /// How many words of silence Paula's first voice begins Mugician II's song with, so that its buffers
    /// begin as long after its other voices' notes as they do in the player's own time. There, a tick
    /// begins as a buffer does, and its notes as Paula's DMA is turned on at the end of the player, after
    /// its mixing: 39,500 of her clocks into the tick of 71,720 (as UADE's dumps of her registers show),
    /// 32,220 before the next buffer. `PaulaTickRenderer` begins the notes as the tick begins: the
    /// buffers begin 99 words, 32,274 clocks, after.
    static let leadWords = 99

    /// The song moves on ($71C4): after its speed's ticks, a row; after its patterns' length, a position;
    /// after its length, the position it goes back to, as the song ends.
    private mutating func advance() {
        newPosition = false
        newRow = false
        counter &-= 1
        guard counter == 0 else { return }
        counter = speed & 15
        speed = (speed & 15) << 4 | (speed & 0xF0) >> 4
        newRow = true
        row &+= 1
        guard row == 0x40 || row == patternLength else { return }
        row = 0
        newPosition = true
        position &+= 1
        guard position == length else { return }
        // EaglePlayer's module says that the song has ended (`SongEnd`), and it goes back.
        position = UInt16(byte(header + 1))
        ending = true
    }

    /// What a voice told a sample takes up: where it begins and ends, and its loop's length in bytes.
    private struct Started {
        var start: Int
        var end: Int
        var loop: Int
    }

    /// A voice's row ($752E): at the beginning of a position, its pattern and transpose; on a tick that
    /// begins a row, the row's note, which starts its instrument afresh, Paula's DMA being turned off for
    /// it; and on every tick, the commands that last the row. Returns what a sample started takes up.
    private mutating func playRow<Output: TFMXOutput>(_ v: Int, column: Int, sequence list: Int, _ output: inout Output) -> Started? {
        let p = paulaVoice(v)
        var started: Started?
        if newPosition {
            let at = list + Int((UInt16(column) &+ position &<< 3))
            voices[v].pattern = byte(at)
            voices[v].transpose = byte(at + 1)
        }
        rows: if newRow {
            let at = patterns + Int(voices[v].pattern) << 8 + Int(row &<< 2)
            guard byte(at) != 0 else { break rows }
            let command = byte(at + 2)
            if command != 0x4A {
                voices[v].note = byte(at)
                if byte(at + 1) != 0 { voices[v].instrument = byte(at + 1) &- 1 }
            }
            voices[v].instrument &= 0x3F
            voices[v].command = command >= 0x40 ? command &- 0x3E : 1
            voices[v].parameter = byte(at + 3)
            let instrument = instruments + Int(voices[v].instrument) << 4
            voices[v].fineTune = byte(instrument + 8)
            let transpose = UInt16(bitPattern: Int16(Int8(bitPattern: voices[v].transpose)))
            if voices[v].command == 12 {
                // ($4A: the note is one to slide to, the voice's own going on.)
                voices[v].slideNote = byte(at)
                voices[v].target = period(fineTune: voices[v].fineTune, note: UInt16(voices[v].slideNote) &+ transpose)
            } else {
                voices[v].slideNote = command
                if voices[v].command == 1 {
                    voices[v].target = period(fineTune: voices[v].fineTune, note: UInt16(voices[v].slideNote) &+ transpose)
                }
            }
            // ($49 gives the instrument the arpeggio its parameter says, in the module.)
            if voices[v].command == 11 { store(voices[v].parameter & 7, at: instrument + 4) }
            let wave = byte(instrument)
            if voices[v].command != 12 {
                if wave >= 0x20 {
                    // A sample ($7E2A): played from its beginning to its end, then its loop, if it has one.
                    let header = sampleHeaders + Int(wave - 0x20) << 5
                    voices[v].sample = header
                    voices[v].loopNext = true
                    let start = samples + long(header)
                    if let p {
                        tell(p, start: start, length: UInt16(truncatingIfNeeded: (long(header + 4) - long(header)) >> 1), &output)
                        output.off(p)
                    }
                    if kind == .two {
                        let loop = long(header + 8) != 0 ? long(header + 4) - long(header + 8) : 0
                        started = Started(start: start, end: samples + long(header + 4), loop: loop)
                    }
                } else {
                    // A waveform, which Paula is turned off and on for ($4A and $48 leave her playing), and
                    // made afresh from the one its effect begins from, unless $40 or $42 say not.
                    if let p {
                        tell(p, start: waveforms + Int(wave) << 7, length: UInt16(byte(instrument + 1)), &output)
                        if voices[v].command != 10 { output.off(p) }
                    }
                    if byte(instrument + 11) != 0, voices[v].command != 2, voices[v].command != 4 {
                        let from = waveforms + Int(byte(instrument + 12)) << 7, to = waveforms + Int(wave) << 7
                        for i in 0 ..< 128 { store(byte(from + i), at: to + i) }
                        store(0, at: instrument + 6)
                        voices[v].effectTicks = byte(instrument + 14)
                    }
                }
            }
            // The envelope begins again, unless $41 or $42 say not ($773E).
            if voices[v].command != 3, voices[v].command != 4, voices[v].command != 12 {
                voices[v].envelopeTicks = 1
                voices[v].envelopeAt = 0
            }
            voices[v].slide = 0
            voices[v].vibratoDelay = byte(instrument + 7)
            voices[v].vibratoAt = 0
            voices[v].arpeggioAt = 0
        }
        // The commands that last as long as the row ($7778): $43 the patterns' length, $44 the speed,
        // $45 and $46 the filter, $4B the speed of two nibbles.
        let parameter = voices[v].parameter
        switch voices[v].command {
        case 5:
            if parameter != 0, parameter <= 0x40 { patternLength = UInt16(parameter) }
        case 6:
            let nibble = parameter & 15
            if nibble != 0 { speed = UInt16(nibble << 4 | nibble) }
        case 7:
            lightFilter = true
        case 8:
            lightFilter = false
        case 13:
            voices[v].command = 0
            if parameter & 15 != 0, parameter & 0xF0 != 0 { speed = UInt16(parameter) }
        default:
            break
        }
        return started
    }

    /// A voice's tick ($7832): $47 turns the filter over; the instrument's effect, run on its waveform
    /// once a tick whichever voices play it (as the players keep a list of four); the volume envelope;
    /// and the period, with the arpeggio, the slide and the vibrato.
    private mutating func tick(_ v: Int, done: inout InlineArray<8, UInt8>, count: inout Int) {
        if voices[v].command == 9 { lightFilter.toggle() }
        let instrument = instruments + Int(voices[v].instrument) << 4
        if byte(instrument + 11) != 0, byte(instrument) < 0x20 {
            let mark = voices[v].instrument &+ 1
            let seen = (0 ..< 4).contains { done[$0] == mark }
            if !seen {
                if count < 8 { done[count] = mark }
                count += 1
                if voices[v].effectTicks == 0 {
                    voices[v].effectTicks = byte(instrument + 14)
                    effect(instrument)
                } else {
                    voices[v].effectTicks &-= 1
                }
            }
        }

        // The envelope ($78EC): a step of the instrument's envelope waveform every so many ticks, read
        // as a volume ($80 the loudest, $7F silence); after 128, it stops, or goes round if the
        // instrument says so.
        if voices[v].envelopeTicks != 0 {
            voices[v].envelopeTicks &-= 1
            if voices[v].envelopeTicks == 0 {
                voices[v].envelopeTicks = UInt16(byte(instrument + 3))
                voices[v].envelopeAt = (voices[v].envelopeAt &+ 1) & 0x7F
                if voices[v].envelopeAt == 0, byte(instrument + 15) & 2 == 0 {
                    voices[v].envelopeTicks = 0
                } else {
                    let level = byte(waveforms + Int(UInt16(byte(instrument + 2)) &<< 7 &+ voices[v].envelopeAt))
                    let volume = UInt16((0 &- (level &+ 0x81)) >> 2)
                    if let p = paulaVoice(v) {
                        // (As EaglePlayer's modules write it: of seven bits, at their full volume.)
                        paulaVolumes[p] = volume & 0x7F
                    }
                    voices[v].volume = volume
                }
            }
        }

        // The period ($795A): the note, the arpeggio's step added in a byte, and the transpose.
        var note = UInt16(voices[v].note)
        let arpeggio = byte(instrument + 4)
        if arpeggio != 0 {
            let step = byte(arpeggios + Int(arpeggio) << 5 + Int(voices[v].arpeggioAt))
            note = note & 0xFF00 | UInt16(UInt8(note & 0xFF) &+ step)
            voices[v].arpeggioAt = (voices[v].arpeggioAt &+ 1) & 0x1F
        }
        note &+= UInt16(bitPattern: Int16(Int8(bitPattern: voices[v].transpose)))
        let base = period(fineTune: voices[v].fineTune, note: note)
        var period = base
        if voices[v].command == 12 || voices[v].command == 1 {
            // A slide, by the row's parameter on each tick, to the note it gives, where it stops (on the
            // tick after it has gone past it).
            let by = 0 &- UInt16(bitPattern: Int16(Int8(bitPattern: voices[v].parameter)))
            voices[v].slide &+= by
            period = base &+ voices[v].slide
            if voices[v].parameter != 0 {
                let past = by & 0x8000 != 0 ? period <= voices[v].target : period >= voices[v].target
                if past {
                    voices[v].slide = voices[v].target &- base
                    voices[v].parameter = 0
                }
            }
        }
        // The vibrato ($7A1E), from a waveform, after a delay, going round from where the instrument says.
        let vibrato = byte(instrument + 5)
        if vibrato != 0 {
            if voices[v].vibratoDelay != 0 {
                voices[v].vibratoDelay &-= 1
            } else {
                let at = voices[v].vibratoAt
                voices[v].vibratoAt = (voices[v].vibratoAt &+ 1) & 0x7F
                if voices[v].vibratoAt == 0 { voices[v].vibratoAt = UInt16(byte(instrument + 9)) }
                period &-= UInt16(bitPattern: Int16(sbyte(waveforms + Int(vibrato) << 7 + Int(at))))
            }
        }
        voices[v].period = period
        if let p = paulaVoice(v) { paulaPeriods[p] = period }
    }

    /// The instrument's effect on its waveform ($7AFC on, by the table at $7A7C), of fifteen: each reads
    /// and writes the waveforms in memory, as the players do.
    private mutating func effect(_ instrument: Int) {
        let wave = waveforms + Int(byte(instrument)) << 7
        let first = waveforms + Int(byte(instrument + 12)) << 7
        let second = waveforms + Int(byte(instrument + 13)) << 7
        let place = instrument + 6
        // How many bytes the instrument's waveform has: its length's words, counted in a byte, less
        // one in a word (so that a length of nought or 128 is 65,536).
        let bytes = Int(UInt16(byte(instrument + 1) &* 2) &- 1) + 1
        func set(_ at: Int, _ value: Int) { store(UInt8(truncatingIfNeeded: value), at: at) }
        switch byte(instrument + 11) {
        case 1:
            smooth(wave)
        case 2:
            // Half of each of two waveforms, the second going round as it is read.
            var at = Int(byte(place))
            store((byte(place) &+ 1) & 0x7F, at: place)
            for i in 0 ..< bytes {
                set(wave + i, (sbyte(first + i) + sbyte(second + at)) >> 1)
                at = (at + 1) & 0x7F
            }
        case 3:
            // Shifted round by a byte, to the left.
            let kept = byte(wave)
            for i in 0 ..< 127 { store(byte(wave + i + 1), at: wave + i) }
            store(kept, at: wave + 127)
        case 4:
            // And to the right.
            let kept = byte(wave + 127)
            for i in stride(from: 126, through: 0, by: -1) { store(byte(wave + i), at: wave + i + 1) }
            store(kept, at: wave)
        case 5:
            halve(wave)
        case 6:
            // Each byte of its first half made two: an octave down.
            for j in 0 ..< 64 {
                let value = byte(wave + 63 - j)
                store(value, at: wave + 127 - 2 * j)
                store(value, at: wave + 126 - 2 * j)
            }
        case 7:
            // A byte turned upside down, one more each tick, round the waveform's length.
            let at = Int(byte(place))
            set(wave + at, -sbyte(wave + at))
            store(byte(place) &+ 1, at: place)
            if !(byte(instrument + 1) &* 2 > byte(place)) { store(0, at: place) }
        case 8:
            // A slope added, its steepness read from the second waveform, one place more each tick.
            store((byte(place) &+ 1) & 0x7F, at: place)
            let by = byte(second + Int(byte(place)))
            var add: UInt8 = 3
            for i in 0 ..< bytes {
                store(byte(wave + i) &+ add, at: wave + i)
                add &+= by
            }
        case 9:
            // The second waveform added.
            for i in 0 ..< bytes { store(byte(wave + i) &+ byte(second + i), at: wave + i) }
        case 10:
            // Smoothed, three parts of the byte before to one of the byte after.
            for i in 0 ..< 126 { set(wave + i + 1, (sbyte(wave + i) * 3 + sbyte(wave + i + 2)) >> 2) }
        case 11, 12:
            // Morphed from one waveform into the other and back, in 128 ticks (or, for 12, 32).
            let steps: UInt8 = byte(instrument + 11) == 11 ? 0x7F : 0x1F
            let half = (steps &+ 1) >> 1, top = half &- 1, shift = steps == 0x7F ? 6 : 4
            store((byte(place) &+ 1) & steps, at: place)
            var by = byte(place), other: UInt8
            if by < half {
                other = ~by & top
            } else {
                by = steps &- by
                other = ~by & top
            }
            for i in 0 ..< bytes {
                let sum = Int16(truncatingIfNeeded: sbyte(first + i) * Int(by) + sbyte(second + i) * Int(other))
                set(wave + i, Int(sum >> shift))
            }
        case 13:
            // Smoothed, the byte before and the byte after.
            for i in 0 ..< 126 { set(wave + i + 1, (sbyte(wave + i) + sbyte(wave + i + 2)) >> 1) }
        case 14:
            // Two bytes turned upside down, apart by the instrument's thirteenth byte.
            let at = byte(place)
            set(wave + Int(at), -sbyte(wave + Int(at)))
            let mask = UInt8(truncatingIfNeeded: UInt16(byte(instrument + 1) &* 2) &- 1)
            let other = Int((at &+ byte(instrument + 13)) & mask)
            set(wave + other, -sbyte(wave + other))
            store(at &+ 1, at: place)
            if !(byte(instrument + 1) &* 2 > byte(place)) { store(0, at: place) }
        case 15:
            // Smoothed every tick, and every so many ticks an octave up.
            smooth(wave)
            store(byte(place) &+ 1, at: place)
            if byte(place) == byte(instrument + 13) {
                store(0, at: place)
                halve(wave)
            }
        default:
            // (Nought is none; those of 16 to 31 do nothing; one past them would send the player into
            // what follows its table, and none of UnExoticA's modules has one.)
            break
        }
    }

    /// Smoothed, each byte and the one after (effect 1, $7DCC).
    private func smooth(_ wave: Int) {
        for i in 0 ..< 127 { store(UInt8(truncatingIfNeeded: (sbyte(wave + i) + sbyte(wave + i + 1)) >> 1), at: wave + i) }
    }

    /// Every other byte, twice over: an octave up (effect 5, $7C46).
    private func halve(_ wave: Int) {
        for i in 0 ..< 64 { store(byte(wave + 2 * i), at: wave + i) }
        for i in 0 ..< 64 { store(byte(wave + i), at: wave + 64 + i) }
    }

    /// Mugician II's mixing of its four voices into a buffer (`lbC010982`), which Paula's first voice is
    /// told to play next.
    ///
    /// Each voice steps through its sample by its period against the mixing's, in 256ths, the fraction
    /// carried within the tick only; each of its bytes is turned down by its volume from a table
    /// (`MugicianTables.volumes`), and the four are added and clipped to a byte. At the end of the tick,
    /// a voice past its sample's end goes back by its loop, once, or is silent from then on if it has
    /// none; one of no period is silent too.
    private mutating func mix<Output: TFMXOutput>(_ output: inout Output) {
        let into = nextBuffer
        nextBuffer = nextBuffer == buffersAt ? buffersAt + Self.bufferBytes : buffersAt
        var volumes = InlineArray<4, Int>(repeating: 0)
        var whole = InlineArray<4, Int>(repeating: 0)
        var fraction = InlineArray<4, UInt32>(repeating: 0)
        for i in 0 ..< 4 {
            let period = voices[3 + i].period
            if period == 0 {
                mixed[i].silent = true
                mixed[i].step = 0
            } else if period != mixed[i].period {
                mixed[i].period = period
                mixed[i].step = Self.step(period: period, mixing: mixPeriod)
            }
            volumes[i] = mixed[i].silent ? 0 : Int(voices[3 + i].volume & 0x3F)
            whole[i] = Int(mixed[i].step & 0xFFFF)
            fraction[i] = mixed[i].step >> 24
        }
        var carried = InlineArray<4, UInt32>(repeating: 0)
        let table = MugicianTables.volumes
        for n in 0 ..< mixWords * 2 {
            var sum = 0
            for i in 0 ..< 4 { sum += Int(table[volumes[i] << 8 | Int(byte(mixed[i].at))]) }
            memory[into + n] = UInt8(bitPattern: Int8(clamping: sum - 512))
            for i in 0 ..< 4 {
                carried[i] += fraction[i]
                let carry = Int(carried[i] >> 8)
                carried[i] &= 0xFF
                mixed[i].at += Int(Int16(truncatingIfNeeded: whole[i] + carry))
            }
        }
        for i in 0 ..< 4 where mixed[i].at >= mixed[i].end {
            if mixed[i].loop != 0 { mixed[i].at -= mixed[i].loop } else { mixed[i].silent = true }
        }
        tell(0, start: into, length: UInt16(mixWords), &output)
    }

    /// A mixed voice's step through its sample for each byte mixed (`lbC010B00`): 256 over the period's
    /// 256ths of the mixing's period, its whole and its fraction in 256ths, as the 68000 divides (a
    /// quotient too big for a word leaving what was divided as it was, and a division by nought, which
    /// would stop the machine, taken as no step).
    static func step(period: UInt16, mixing: UInt16) -> UInt32 {
        let divided = UInt32(period) << 8
        var d1 = divided
        let quotient = divided / UInt32(mixing)
        if quotient <= 0xFFFF { d1 = (divided % UInt32(mixing)) << 16 | quotient }
        let by = d1 & 0xFFFF
        guard by != 0 else { return 0 }
        let whole = 256 / by, remainder = 256 % by
        guard whole <= 0xFFFF else { return 0 }
        let fraction = (remainder << 8) / by
        return (fraction & 0xFF) << 24 | (whole & 0xFF)
    }

    var songCount: Int { songStarts.count }
    var stops: Int { 0 }
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] }
}

/// Paula told nothing, for playing a song through for its length.
private struct Unheard: TFMXOutput {
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
}

private extension String {
    var trimmingTrailingSpaces: String {
        var bytes = Array(utf8)
        while bytes.last == 0x20 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Digital Mugician's modules, played on Paula by `PaulaTickRenderer`.
extension MugicianPlayer: PaulaTickPlayer {
    var lengthClocks: UInt64? {
        guard lengths.indices.contains(song), let ticks = lengths[song] else { return nil }
        return UInt64(ticks) * UInt64(tickClocks)
    }

    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "MUG")
        info.detail = kind == .one ? "Digital Mugician" : "Digital Mugician II"
        info.title = titles[songStarts[song]].trimmingTrailingSpaces
        if turnsFilterOn {
            info.shortfalls = ["Its commands to turn the Amiga's filter on are not played: it is heard with the filter off."]
        }
        return info
    }

    var gain: Float { 0.46 }

    mutating func select(song: Int) throws(TuneError) {
        guard songStarts.indices.contains(song) else { throw .unsupported("no song \(song + 1)") }
        self.song = song
        start(song)
    }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { tickClocks }
}
