// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the replay routine of Tord "Blade" Jansson's Blade Packer (as the preview of the game Obsession carries
// it), as Wanted Team adapted it for EaglePlayer ("Blade Packer player module V1.1 (13 Nov 2002)"), carried by UADE
// as players/BladePacker, whose source UADE also carries as amigasrc/players/wanted_team/BladePacker/src/Blade
// Packer_v2.asm. The labels given are that source's.

/// Blade Packer, Tord Jansson's packed tracker modules (from the Atari ST, where he wrote it, 1991 to 1996), whose
/// music for Obsession (Unique Development Sweden, 1995) is among UnExoticA's: a file of patterns beside a file of
/// samples (`<name>.smp`), each file of many songs, one after the other.
///
/// The file: "S\u{8F}NG." and a 'B' for patterns whose rows are bytes or anything else for words, a '4' for four
/// voices or anything else for eight, and the position the song goes back to at its end ($7F for the first); then
/// the positions, a pattern's number for each voice, to a word $DD48; the patterns, 64 rows each, each row a cell's
/// number in a dictionary, to a word $D8F1; and the dictionary, four bytes to a cell: a note (twice its number),
/// an instrument, a command (four times its number) and the command's byte. The commands are ProTracker's, nearly:
/// arpeggio, slides, portamento to a note, vibrato, tremolo, sample offset, volume slides, position jump, volume,
/// pattern break, speed, the E commands (fine slides, which go the other way, waveforms, fine tuning, retrigger,
/// fine volume, cut, delay and pattern delay); and 8, which ends the song and starts it again. The sample file:
/// "SPLS" (or nothing, for one that begins with the long $1F4), and sixteen bytes for each sample (its start and
/// end, from four bytes before the table, its loop's length, its volume and its fine tuning), then the samples.
/// Each song begins at the position after one with a position jump or an 8 command (the first, at the first), as
/// Wanted Team's player finds them.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`), and so is run by
/// EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second and a
/// little less. Its replayer, made for the Atari ST, keeps a copy of Paula's registers for each of its four voices,
/// and keeps up with where in its sample each voice is, by an estimate (a tick's worth of bytes, $1151A over the
/// period, added each tick); and it tells Paula what is in the copy as the next tick begins: so all it plays is a
/// tick late. A voice whose place in its sample the replayer has set anew is turned off, then all four are told
/// their periods and volumes, and once `DMAWait` has waited for the beam to begin nine lines, those set anew are
/// told their samples and turned on, and after another wait, their loops (or a word of silence). Its third and
/// fourth voices are Paula's fourth and third.
///
/// Each of the player's writes is told Paula at its moment in the tick (`TFMXOutput.timed(at:)`), near where it falls
/// in UADE's dumps.
///
/// A song comes to its end at a position jump, at an 8 command, or at the end of the positions (from where it goes
/// back to the one the file says), as the player tells EaglePlayer so; it is said here to have come to it as the row
/// after is read. Where the player would read past the file it reads nought, past its tables of periods and waves
/// nought, and past the sample file nought (a note before any instrument, for which it would read the start of
/// memory, plays nothing); a command past the sixteen does nothing but play the cell's note; a loop with a negative
/// length is taken as none (the player would go round it for ever); and a word at an odd place in its tables, which
/// a note can ask for (and which would stop a 68000), is read as a later processor reads it.
struct BladePackerPlayer: ~Copyable {
    /// The file, the sample file, a word of silence and what follows them, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where the sample file is, and where its table of samples begins (`lbL062FD2`: past "SPLS").
    let samplesAt: Int
    private let sampleTable: UInt32
    /// Where a voice with nothing to play is pointed, and the player's word of silence (`lbL03A5F4`).
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    private let sampleFileSize: Int
    /// Whether rows are bytes (`lbW062FBE` 1) or words (2); how many voices the positions have (`lbW062FC0`, of
    /// which the player plays four); where the positions are, the one gone back to at the end (`lbL062FC6`), and where
    /// the patterns and the dictionary begin (`lbL062FCA`, `lbL062FCE`).
    private let rowSize: UInt16
    let voiceCount: Int
    private let restartPosition: UInt32
    private let patterns: UInt32
    private let dictionary: UInt32
    /// The positions each song begins at (`SongTable`).
    private let songStarts: [UInt16]
    var songCount: Int { songStarts.count }
    private(set) var song = 0
    /// How many samples its sample file has (those whose start and end differ, as `InitPlayer` counts them).
    let sampleCount: Int
    let shortfalls: [String]

    /// What a voice is doing on the ticks after a row's first (`lbL0631BC`, the routine each of the four calls).
    private enum Effect {
        case none, arpeggio, slideUp, slideDown, toNote, vibrato, toNoteAndVolume, vibratoAndVolume, tremolo
        case volumeSlide, delay, retrigger, cut
    }

    /// The vibrato's and tremolo's waves: a sine, a ramp and a square (`lbW0356BC`, `lbL03573C`, `lbW0356FC`), as
    /// places in the player's tables.
    private static let sine = 1152
    private static let square = 1216
    private static let ramp = 1280

    /// What the player keeps for each voice (`lbL062FFC`, 56 bytes each), named by what they are: its sample's place
    /// in the sample file's table (+0), its period (+4), its slide's step (+6), its volume slide down and up (+12,
    /// +14), its portamento's period and step (+16, +18), its arpeggio's three periods and which is next (+20 to
    /// +29), its note (+30), and the period its arpeggio gives (+32).
    private struct Voice {
        var entry: UInt32 = 0
        var period: UInt16 = 0
        var slideStep: UInt16 = 0
        var down: UInt16 = 0
        var up: UInt16 = 0
        var target: UInt16 = 0
        var toNoteStep: UInt16 = 0
        var arpeggio = InlineArray<3, UInt16>(repeating: 0)
        /// (Nought to two for the three; three for the place of this itself; anything else for nowhere, as it is
        /// before the voice has had an arpeggio.)
        var arpeggioAt = Voice.nowhere
        static let nowhere = 1000
        var note: UInt16 = 0
        var arpeggioPeriod: UInt16 = 0
        /// Its vibrato (+34): where in its wave, its step, whether a note has begun since, its depth; and the period
        /// it gives (+38, $FFFF for none).
        var vibratoAt: UInt8 = 0
        var vibratoStep: UInt8 = 0
        var vibratoAgain: UInt8 = 0
        var vibratoDepth: UInt8 = 0
        var vibratoPeriod: UInt16 = 0
        /// The cell kept for a retrigger or delay (+40), the place its sample begins at in the sample file (+44), its
        /// fine tuning (+48).
        var saved: UInt32 = 0
        var start: UInt32 = 0
        var tuning: UInt16 = 0
        /// Its tremolo (+50): where in its wave, its step, its depth, whether it goes on from the row before, and the
        /// volume it is about.
        var tremoloAt: UInt8 = 0
        var tremoloStep: UInt8 = 0
        var tremoloDepth: UInt16 = 0
        var tremoloAgain: UInt8 = 0
        var tremoloLevel: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The routines the four call on the ticks after a row's first, and the voices' vibrato's and tremolo's waves.
    private var effects = InlineArray<4, Effect>(repeating: .none)
    private var vibratoWaves = InlineArray<4, Int>(repeating: Self.sine)
    private var tremoloWaves = InlineArray<4, Int>(repeating: Self.sine)

    /// The replayer's copy of Paula, for each voice (`lbW0347E8` and after): its period, where in its sample it is
    /// taken to be and where it was at the end of the last tick, where the sample ends, its loop's length, and its
    /// volume.
    private var copiedPeriods = InlineArray<4, UInt16>(repeating: 0x11C)
    private var places = InlineArray<4, UInt32>(repeating: 0)
    private var lastPlaces = InlineArray<4, UInt32>(repeating: 0)
    private var ends = InlineArray<4, UInt32>(repeating: 0)
    private var loopLengths = InlineArray<4, UInt32>(repeating: 0)
    private var levels = InlineArray<4, UInt8>(repeating: 0)

    /// The pattern delay's count (`lbW062FB8`) and the mask a row's cells are read through (`lbW062FBA`: all of a
    /// cell, or while the pattern is delayed its command alone); where the positions are read (`lbL062FC2`) and each
    /// voice's pattern (`lbL062FDC`, eight); the rows left of the pattern (`lbW062FD6`); the speed, less one
    /// (`lbB062FD9`), and the ticks left of the row (`lbB062FDA`).
    private var delayCount: UInt16 = 0
    private var mask: UInt32 = 0xFFFF_FFFF
    private var position: UInt32 = 8
    private var rows = InlineArray<8, UInt32>(repeating: 0)
    private var rowsLeft: UInt16 = 0
    private var speed: UInt8 = 5
    private var ticksLeft: UInt16 = 0
    /// The position the song is to start again from on the next tick (`lbW0351BA`, nil for none), and the one it
    /// began at (`RepeatVal`).
    private var restartAt: UInt16?
    private var songStart: UInt16 = 0
    /// Whether the song has come to its end, to be said as the next row is read.
    private var goesRound = false

    /// What each of Paula's period and volume registers was last given, and what they held as the tick just run
    /// began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told at their moments).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the waits; and how many ticks
    /// Paula has been told of (as far as two).
    private var clock = 0
    private var told: UInt8 = 0
    /// Which of Paula's voices the player has turned on.
    private var playing = InlineArray<4, Bool>(repeating: false)

    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?
    private var lengths: [UInt64?] = []

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to; and once the songs played through to find
    /// their lengths have taken four hours in all, the rest are too.
    private static let mostTicks = 50 * 60 * 60
    private static let mostTicksInAll = 4 * mostTicks
    /// Which of Paula's voices each of the player's plays.
    private static let channels: InlineArray<4, Int> = [0, 1, 3, 2]

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (near the medians of its dumps): the
    /// first after the interrupt begins (a guess: only the distances between them are heard); between one voice's
    /// period and its volume, and its volume and the next voice's period; and between one voice's sample and the
    /// next's, after the waits.
    static let firstWrite = 300
    static let volumeClocks = 30
    static let voiceClocks = 60
    static let sampleClocks = 50

    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's clocks) has
    /// changed nine times, the first at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 80 - clock
    }

    // MARK: - The player's tables

    /// A word of the player's tables from `at` bytes past `lbB03523A`, the label two bytes before its periods (whose
    /// places begin from it): nought before them and past the waves, where it would read its own code or what
    /// follows it.
    private static func tableWord(_ at: Int) -> UInt16 {
        UInt16(tableByte(at &- 2)) << 8 | UInt16(tableByte(at &- 1))
    }

    /// A byte of the periods and waves, from the first period.
    private static func tableByte(_ at: Int) -> UInt8 {
        guard at >= 0, at < 2 * tables.count else { return 0 }
        let word = tables[at >> 1]
        return at & 1 == 0 ? UInt8(word >> 8) : UInt8(word & 0xFF)
    }

    // MARK: - Reading

    @inline(__always) private func byte(_ at: UInt32) -> UInt8 { at < UInt32(fileSize) ? memory[Int(at)] : 0 }
    @inline(__always) private func word(_ at: UInt32) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: UInt32) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }

    /// The sample file's bytes, at their places in memory; nought elsewhere.
    @inline(__always) private func sampleByte(_ at: UInt32) -> UInt8 {
        let start = UInt32(samplesAt)
        return at >= start && at - start < UInt32(sampleFileSize) ? memory[Int(at)] : 0
    }

    @inline(__always) private func sampleLong(_ at: UInt32) -> UInt32 {
        var value: UInt32 = 0
        for k in 0 ..< 4 { value = value << 8 | UInt32(sampleByte(at &+ UInt32(k))) }
        return value
    }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 { UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2)) }

    /// The place of the word after the first `mark` found from `from`, a word at a time; nil for none.
    private static func after(_ mark: UInt16, in data: [UInt8], from: Int) -> Int? {
        var at = from
        while at + 1 < data.count {
            if word(data, at) == mark { return at + 2 }
            at += 2
        }
        return nil
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): "S\u{8F}NG.".
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 5 && data[0] == 0x53 && data[1] == 0x8F && data[2] == 0x4E && data[3] == 0x47 && data[4] == 0x2E
    }

    /// Reads the file and its samples (the sample file, `<name>.smp` beside it) and starts the song asked for (of
    /// `songCount`, nought the first). A file with no $DD48 after its positions or no $D8F1 after its patterns, or
    /// shorter than the dictionary its patterns ask for, is refused, as `InitPlayer` refuses it; and one given no
    /// samples, or a sample file that begins with neither "SPLS" nor the long $1F4.
    init(_ data: [UInt8], samples: [UInt8], song: Int = 0) throws(TuneError) {
        fileSize = data.count
        sampleFileSize = samples.count
        func aligned(_ n: Int) -> Int { (n + 15) & ~15 }
        samplesAt = aligned(max(data.count, 16))
        silenceAt = aligned(samplesAt + samples.count)
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        for (i, b) in samples.enumerated() { memory[samplesAt + i] = b }
        let headed = samples.count >= 4 && samples[0] == 0x53 && samples[1] == 0x50 && samples[2] == 0x4C && samples[3] == 0x53
        sampleTable = UInt32(samplesAt + (headed ? 4 : 0))
        // `Init1` and `InitPlayer`: the kind of rows and how many voices; the positions to $DD48, the patterns to
        // $D8F1, and the dictionary, as long as the largest cell's number its patterns have.
        rowSize = data.count > 5 && data[5] == 0x42 ? 1 : 2
        voiceCount = data.count > 6 && data[6] == 0x34 ? 4 : 8
        let back = data.count > 7 && data[7] != 0x7F ? Int(data[7]) : 0
        restartPosition = UInt32(8 + back * voiceCount)
        let patternsAt = Self.after(0xDD48, in: data, from: 0)
        let dictionaryAt = patternsAt.flatMap { Self.after(0xD8F1, in: data, from: $0) }
        patterns = UInt32(patternsAt ?? 0)
        dictionary = UInt32(dictionaryAt ?? 0)
        var largest = 0
        if let patternsAt, let dictionaryAt {
            var at = patternsAt
            while at < dictionaryAt - 2 {
                if rowSize == 1 {
                    largest = max(largest, Int(data[at]), Int(data[at + 1]))
                } else {
                    largest = max(largest, Int(Self.word(data, at)))
                }
                at += 2
            }
        }
        // (The samples, from the long at the table's start, sixteen bytes each, those whose start and end differ.)
        var count = 0
        let entries = Int(min(4096, Self.long(samples, Int(sampleTable) - samplesAt) >> 4))
        for k in 0 ..< entries where Self.long(samples, Int(sampleTable) - samplesAt + 16 * k) != Self.long(samples, Int(sampleTable) - samplesAt + 16 * k + 4) {
            count += 1
        }
        sampleCount = count
        // (`InitPlayer`: each position whose patterns have a position jump or an 8 command begins a song at the next.)
        var starts: [UInt16] = [0]
        if let patternsAt, let dictionaryAt {
            let ends = patternsAt - 2
            var p = 0
            positions: while 8 + (p + 1) * voiceCount <= ends, starts.count < 128 {
                let first = 8 + p * voiceCount
                p += 1
                for k in 0 ..< voiceCount {
                    let pattern = Int(data[first + k])
                    var row = patternsAt + (pattern << (rowSize == 1 ? 6 : 7))
                    for _ in 0 ..< 64 {
                        let index = rowSize == 1 ? Int(row < data.count ? data[row] : 0) : Int(Self.word(data, row))
                        row += Int(rowSize)
                        let cell = dictionaryAt + Int(Int16(truncatingIfNeeded: index * 4))
                        let what = cell + 2 >= 0 && cell + 2 < data.count ? data[cell + 2] : 0
                        if what == 0x2C || what == 0x20 {
                            starts.append(UInt16(p))
                            continue positions
                        }
                    }
                }
            }
        }
        // (As many songs as it found, the first counted for the last.)
        if starts.count > 1 { starts.removeLast() }
        songStarts = starts
        shortfalls = []
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Blade Packer module") }
        guard let dictionaryAt else { throw .malformed("its positions or patterns have no end") }
        guard dictionaryAt + 4 * (largest + 1) <= data.count else { throw .malformed("it is cut short") }
        guard !samples.isEmpty else {
            throw .missingCompanion("A Blade Packer module keeps its samples in a file of their own, which was not given with it.")
        }
        guard headed || Self.long(samples, 0) == 0x1F4 else { throw .malformed("its sample file is not one of Blade Packer's") }

        // Each song's length, from a playing of it in silence to its end.
        var budget = Self.mostTicksInAll
        for s in 0 ..< songStarts.count {
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
        self.song = max(0, min(songStarts.count - 1, song))
        lengthClocks = lengths[self.song]
        start()
    }

    deinit { memory.deallocate() }

    /// `InitSound`, `Init1` and `Init2`: all the player keeps at nought, but for the mask (all of a cell), the speed
    /// (six), the waves (sines) and Paula's copies (each voice at the player's silence, its period $11C, its volume
    /// nought); and the song to start from its position on the first tick.
    private mutating func start() {
        voices = .init(repeating: Voice())
        effects = .init(repeating: .none)
        vibratoWaves = .init(repeating: Self.sine)
        tremoloWaves = .init(repeating: Self.sine)
        copiedPeriods = .init(repeating: 0x11C)
        places = .init(repeating: UInt32(silenceAt))
        lastPlaces = .init(repeating: 0)
        ends = .init(repeating: UInt32(silenceAt + 2))
        loopLengths = .init(repeating: 0)
        levels = .init(repeating: 0)
        delayCount = 0
        mask = 0xFFFF_FFFF
        position = 8
        rows = .init(repeating: 0)
        rowsLeft = 0
        speed = 5
        ticksLeft = 0
        songStart = songStarts[song]
        restartAt = songStart
        goesRound = false
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = periods
        volumesBefore = volumes
        clock = 0
        told = 0
        playing = .init(repeating: false)
        endings = 0
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songStarts.count else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        lengthClocks = lengths[song]
        start()
    }

    /// Runs the player for a tick (`Interrupt`): Paula told what its copy of her holds (`Play1`), and then the tick
    /// played into the copy (`Play2`). Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        tellPaula(&output)
        play()
        // (Kept within a whole number of the beam's lines, of 227 clocks and of 227.5, which is all the waits ask
        // of it: a count of every clock would outgrow a whole number in a browser.)
        clock = (clock + Self.tickClocks) % 103_285
        return 20
    }
}

// MARK: - Paula

extension BladePackerPlayer {
    /// `Play1` (`lbC034A26`): each voice whose place in its sample has been set anew since the last tick is turned
    /// off; all four told their periods and volumes; once the beam has begun nine lines, those set anew told their
    /// samples (from their places, made even, to their ends) and turned on; nine lines more, and told their loops
    /// (or a word of silence). Then each voice's place moved on by a tick's worth of its sample (`lbC034D8C`).
    private mutating func tellPaula<Output: TFMXOutput>(_ output: inout Output) {
        // (The replayer's fifth voice, for the game's sound effects, is started as the song begins, on Paula's first
        // voice and on the player's silence, as the first voice is; on the next tick it is let go, which clears what
        // the first voice's place was taken to be, and so starts the first voice again: `lbC034A62`.)
        if told == 1 { lastPlaces[0] = 0 }
        if told < 2 { told += 1 }
        var starting: UInt16 = 0
        var starts = InlineArray<4, UInt32>(repeating: 0), lengths = InlineArray<4, UInt16>(repeating: 0)
        var loops = InlineArray<4, UInt32>(repeating: 0), loopWords = InlineArray<4, UInt16>(repeating: 0)
        for v in 0 ..< 4 where places[v] != lastPlaces[v] {
            let c = Self.channels[v]
            let place = places[v] & ~1
            starting |= 1 << UInt16(c)
            starts[c] = place
            lengths[c] = UInt16(truncatingIfNeeded: (ends[v] &- place) >> 1)
            if loopLengths[v] != 0 {
                loops[c] = ends[v] &- loopLengths[v]
                loopWords[c] = UInt16(truncatingIfNeeded: loopLengths[v]) >> 1
            } else {
                loops[c] = UInt32(silenceAt)
                loopWords[c] = 1
            }
        }
        // (Paula turns a voice off only once the word it is playing is over, and a voice turned on again before then
        // goes on as it was. Paula's `stop` is at once; so a voice playing at a period of nought, a word of 65,536
        // clocks, as every voice that has had no note yet is (the player gives those nought), is not turned off and
        // on, and goes on to what it is told after: the loop, as the word ends after the second wait.)
        var held: UInt16 = 0
        for c in 0 ..< 4 where starting & 1 << UInt16(c) != 0 && playing[c] && periods[c] == 0 { held |= 1 << UInt16(c) }
        let turning = starting & ~held
        var at = Self.firstWrite
        output.timed(at: at)
        for c in 0 ..< 4 where turning & 1 << UInt16(c) != 0 { output.off(c) }
        for c in 0 ..< 4 {
            let v = Self.channels[c]
            at += Self.voiceClocks
            output.timed(at: at)
            periods[c] = copiedPeriods[v]
            output.writePeriod(c, periods[c])
            at += Self.volumeClocks
            output.timed(at: at)
            // (`Left1` and the rest: the byte, times EaglePlayer's volume, 64, over 64; Paula's seven bits of it.)
            volumes[c] = UInt16(levels[v]) & 0x7F
            output.writeVolume(c, volumes[c])
        }
        at = afterWait(at)
        for c in 0 ..< 4 where starts[c] != 0 {
            output.timed(at: at)
            output.takeNextBuffer(c, start: address(starts[c]), length: lengths[c])
            at += Self.sampleClocks
        }
        output.timed(at: at)
        for c in 0 ..< 4 where turning & 1 << UInt16(c) != 0 {
            output.on(c)
            playing[c] = true
        }
        at = afterWait(at)
        for c in 0 ..< 4 where loops[c] != 0 {
            output.timed(at: at)
            output.takeNextBuffer(c, start: address(loops[c]), length: loopWords[c])
            at += Self.sampleClocks
        }
        // Each place moved on by $1151A over the period (`divu`: its quotient, with its sign as a word's; the
        // dividend, as a word, for a period too small; the whole of it for a period of nought); at the sample's end,
        // back by its loop's length until it is within it, or for a sample with no loop, to the player's silence.
        for v in 0 ..< 4 {
            var step: UInt32 = 0x1151A
            let period = UInt32(copiedPeriods[v])
            if period != 0 {
                let quotient = 0x1151A / period
                if quotient <= 0xFFFF { step = (0x1151A % period) << 16 | quotient }
                step = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: step)))
            }
            var place = step &+ places[v]
            if Int32(bitPattern: place) >= Int32(bitPattern: ends[v]) {
                let loop = Int32(bitPattern: loopLengths[v])
                if loop > 0 {
                    let over = Int64(Int32(bitPattern: place)) - Int64(Int32(bitPattern: ends[v]))
                    place = UInt32(truncatingIfNeeded: Int64(Int32(bitPattern: place)) - (over / Int64(loop) + 1) * Int64(loop))
                } else {
                    place = UInt32(silenceAt)
                    ends[v] = UInt32(silenceAt + 2)
                }
            }
            places[v] = place
            lastPlaces[v] = place
        }
    }

    /// A place the player gives Paula, in memory: past memory for one past it.
    private func address(_ place: UInt32) -> Int {
        place < UInt32(memoryCapacity) ? Int(place) : memoryCapacity
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

// MARK: - The replayer

extension BladePackerPlayer {
    /// `Play2` (`lbC02583E`): the song started again if it is to be; then, once the row's ticks are over, the next
    /// row read (or while the pattern is delayed, the same row's commands again), else each voice's effect moved on;
    /// and each voice's period put into Paula's copy.
    private mutating func play() {
        if let restart = restartAt {
            // `lbC025618`: from the position asked for, its first row on this tick, the volumes nought.
            levels = .init(repeating: 0)
            rowsLeft = 0
            ticksLeft = 0
            position = 8 &+ UInt32(restart) * UInt32(voiceCount)
            restartAt = nil
        }
        if ticksLeft != 0 {
            ticksLeft -= 1
            for v in 0 ..< 4 { effect(v) }
            copyPeriods(firstTick: false)
            return
        }
        if delayCount != 0 {
            // (The row read again: each voice's pattern back by a row, the first time, and its cells' commands alone.)
            if mask & 0x8000_0000 != 0 {
                for k in 0 ..< 8 { rows[k] &-= UInt32(rowSize) }
                mask = 0x0000_FFFF
            }
            delayCount -= 1
        } else {
            if mask & 0x8000_0000 == 0 {
                for k in 0 ..< 8 { rows[k] &+= UInt32(rowSize) }
            }
            mask = 0xFFFF_FFFF
            if rowsLeft == 0 {
                nextPosition()
                rowsLeft = 0x3F
            } else {
                rowsLeft -= 1
            }
        }
        readRow()
        copyPeriods(firstTick: true)
    }

    /// The next position's patterns, one for each voice (at the end of the positions, the one the file goes back to,
    /// and the song's end).
    private mutating func nextPosition() {
        var at = position
        if word(at) == 0xDD48 {
            at = restartPosition
            goesRound = true
        }
        for k in 0 ..< voiceCount {
            rows[k] = patterns &+ (UInt32(byte(at)) << UInt32(rowSize + 5))
            at &+= 1
        }
        position = at
    }

    /// `lbC02593C`: each voice's cell read (through the mask) and its command done.
    private mutating func readRow() {
        ticksLeft = UInt16(speed)
        if goesRound {
            goesRound = false
            endings += 1
        }
        // (Each command but 8 sets the routine of the next of the four in turn: after an 8, the voices after it set
        // those of the voices before them, as the player's do.)
        var slot = 0
        for v in 0 ..< 4 {
            var at = rows[v]
            let index = rowSize == 1 ? UInt32(byte(at)) : UInt32(word(at))
            at &+= UInt32(rowSize)
            if mask & 0x8000_0000 != 0 { rows[v] = at }
            let cell = Self.plus(dictionary, UInt16(truncatingIfNeeded: index &* 4))
            command(v, &slot, what: byte(cell &+ 2), long(cell) & mask)
        }
    }

    /// The 68000's adding of a word, with its sign, to an address.
    @inline(__always) private static func plus(_ at: UInt32, _ offset: UInt16) -> UInt32 {
        at &+ UInt32(bitPattern: Int32(Int16(bitPattern: offset)))
    }

    /// `lbC0259FA`: each voice's period into Paula's copy: on a row's later ticks the arpeggio's, for a voice whose
    /// routine is the arpeggio's; else its vibrato's, if it has one, or its own.
    private mutating func copyPeriods(firstTick: Bool) {
        for v in 0 ..< 4 {
            if effects[v] == .arpeggio, !firstTick {
                copiedPeriods[v] = voices[v].arpeggioPeriod
            } else {
                let vibrato = voices[v].vibratoPeriod
                copiedPeriods[v] = Int16(bitPattern: vibrato) < 0 ? voices[v].period : vibrato
            }
        }
    }

    private mutating func use(_ effect: Effect, _ slot: inout Int) {
        if slot < 4 { effects[slot] = effect }
        slot += 1
    }

    /// `lbC025F1E`: a cell's note and instrument taken up: the vibrato and tremolo begun afresh; an instrument's
    /// sample, its place, volume and fine tuning; and a note's period (from its fine tuning's table) and its sample
    /// set going from its place, in Paula's copy.
    private mutating func play(_ v: Int, _ cell: UInt32) {
        var voice = voices[v]
        voice.tremoloAgain = 0xFF
        voice.vibratoPeriod = 0xFFFF
        let note = UInt16(cell >> 24)
        if note != 0 { voice.note = note }
        let instrument = UInt16(cell >> 16 & 0xFF)
        if instrument != 0 {
            let entry = sampleTable &+ UInt32((instrument - 1) << 4)
            voice.entry = entry
            voice.start = sampleLong(entry)
            levels[v] = sampleByte(entry &+ 12)
            voice.tuning = voice.tuning & 0xFF00 | UInt16(sampleByte(entry &+ 13))
        }
        if note != 0 {
            voice.vibratoAgain = 0xFF
            let base = sampleTable &- 4
            places[v] = voice.start &+ base
            ends[v] = sampleLong(voice.entry &+ 4) &+ base
            loopLengths[v] = sampleLong(voice.entry &+ 8)
            let index = UInt16(truncatingIfNeeded: UInt32(voice.tuning) &* 72) &+ note
            voice.period = Self.tableWord(Int(Int16(bitPattern: index)))
        }
        voices[v] = voice
    }

    /// A row's command (`lbL0351BC`, by its byte, four times its number) for voice `v`, with its cell.
    private mutating func command(_ v: Int, _ slot: inout Int, what: UInt8, _ cell: UInt32) {
        let value = UInt8(cell & 0xFF)
        let high = UInt16(value >> 4), low = UInt16(value & 15)
        guard what & 3 == 0, what <= 0x3C else {
            use(.none, &slot)
            play(v, cell)
            return
        }
        switch what >> 2 {
        case 0:
            // `lbC025A4A`: an arpeggio (its periods from the table of the fine tuning the byte after the sample's
            // entry's end says, as the player reads it); or with no byte, a note.
            guard cell & 0xFFFF != 0 else {
                use(.none, &slot)
                play(v, cell)
                return
            }
            play(v, cell)
            use(.arpeggio, &slot)
            voices[v].arpeggioAt = 1
            let base = Int(Int16(truncatingIfNeeded: Int(sampleByte(voices[v].entry &+ 17)) * 72)) + Int(Int16(bitPattern: voices[v].note))
            if Int8(bitPattern: value) >= 0x10 {
                if low != 0 {
                    voices[v].arpeggio = [Self.tableWord(base), Self.tableWord(base + 2 * Int(high)), Self.tableWord(base + 2 * Int(low))]
                } else {
                    voices[v].arpeggio = [Self.tableWord(base + 2 * Int(high)), Self.tableWord(base), 0xFFFF]
                }
            } else {
                voices[v].arpeggio = [Self.tableWord(base), Self.tableWord(base + 2 * Int(low)), 0xFFFF]
            }
        case 1:
            voices[v].slideStep = UInt16(value)
            use(.slideUp, &slot)
            play(v, cell)
        case 2:
            voices[v].slideStep = UInt16(value)
            use(.slideDown, &slot)
            play(v, cell)
        case 3:
            // `lbC025B14`: a portamento to the note's period (from the first table, whatever the tuning), the note
            // not begun; an instrument's volume taken.
            let note = UInt16(cell >> 24)
            if note != 0 { voices[v].target = Self.tableWord(Int(note)) }
            if value != 0 { voices[v].toNoteStep = UInt16(value) }
            let instrument = UInt16(cell >> 16 & 0xFF)
            if instrument != 0 { levels[v] = sampleByte(sampleTable &+ UInt32((instrument - 1) << 4) &+ 12) }
            voices[v].vibratoPeriod = 0xFFFF
            voices[v].tremoloAgain = 0xFF
            use(.toNote, &slot)
        case 4, 6:
            // `lbC025B64`, `lbC025BB0`: a vibrato (begun again for a new note), with a volume slide for 6.
            if what >> 2 == 6 {
                use(.vibratoAndVolume, &slot)
                voices[v].down = low
                voices[v].up = high
            }
            let kept = voices[v].vibratoPeriod
            play(v, cell)
            voices[v].vibratoPeriod = kept
            if voices[v].vibratoAgain != 0 {
                voices[v].vibratoAt = 0
                voices[v].vibratoPeriod = 0xFFFF
                voices[v].vibratoAgain = 0
            }
            if what >> 2 == 4 {
                use(.vibrato, &slot)
                if value != 0 {
                    voices[v].vibratoStep = UInt8(high)
                    voices[v].vibratoDepth = UInt8(low)
                }
            }
        case 5:
            use(.toNoteAndVolume, &slot)
            voices[v].down = low
            voices[v].up = high
            play(v, cell)
        case 7:
            // `lbC025BEE`: a tremolo, from its wave's start and the note's volume unless it goes on from the row
            // before (and then from them only for a new note, or a new instrument).
            if Int8(bitPattern: voices[v].tremoloAgain) < 0 {
                voices[v].tremoloAt = 0
                play(v, cell)
                voices[v].tremoloLevel = levels[v]
            } else {
                play(v, cell)
                if cell & 0xFF00_0000 != 0 { voices[v].tremoloAt = 0 }
                if cell & 0x00FF_0000 != 0 { voices[v].tremoloLevel = levels[v] }
            }
            use(.tremolo, &slot)
            voices[v].tremoloAgain = 0
            if value != 0 {
                voices[v].tremoloStep = UInt8(high)
                voices[v].tremoloDepth = low
            }
        case 8:
            // `lbC025D8A`: the song's end, and the song started again on the next tick (the routine left as it was).
            goesRound = true
            restartAt = songStart
            play(v, cell)
        case 9:
            // `lbC025C56`: the sample from 256 times the byte into it (from its start, for a place past its end).
            play(v, cell)
            let entry = voices[v].entry
            var start = UInt32(value) << 8 &+ sampleLong(entry)
            if Int32(bitPattern: start) >= Int32(bitPattern: sampleLong(entry &+ 4)) { start = sampleLong(entry) }
            voices[v].start = start
            if cell & 0xFF00_0000 != 0 { places[v] = start &+ sampleTable &- 4 }
            use(.none, &slot)
        case 10:
            use(.volumeSlide, &slot)
            voices[v].down = low
            voices[v].up = high
            play(v, cell)
        case 11:
            // `lbC025CAC`: a position jump, the song's end.
            rowsLeft = 0
            position = 8 &+ UInt32(value) * UInt32(voiceCount)
            goesRound = true
            use(.none, &slot)
            play(v, cell)
        case 12:
            play(v, cell)
            levels[v] = value
            use(.none, &slot)
        case 13:
            // `lbC025CE4`: a pattern break: to the next position's row the byte says, at once (so that the voices
            // after this one read that row now, and this one and those before it on the next).
            if value != 0 {
                rowsLeft = UInt16(UInt8(0x3F) &- value)
                let offset = UInt32(value) * UInt32(rowSize)
                var at = position
                if word(at) == 0xDD48 {
                    at = restartPosition
                    goesRound = true
                }
                for k in 0 ..< voiceCount {
                    rows[k] = patterns &+ offset &+ (UInt32(byte(at)) << UInt32(rowSize + 5))
                    at &+= 1
                }
                position = at
            } else {
                rowsLeft = 0
            }
            use(.none, &slot)
            play(v, cell)
        case 14:
            extended(v, &slot, high: high, low: low, cell)
        default:
            // `lbC025D72`: the speed (the byte less one, and this row's ticks with it).
            speed = value &- 1
            ticksLeft = ticksLeft & 0xFF00 | UInt16(speed)
            use(.none, &slot)
            play(v, cell)
        }
    }

    /// `lbC025D5E`: the E commands, by the byte's high four bits.
    private mutating func extended(_ v: Int, _ slot: inout Int, high: UInt16, low: UInt16, _ cell: UInt32) {
        switch high {
        case 1:
            // A fine slide: the period up, as far as $38B.
            play(v, cell)
            let period = low &+ voices[v].period
            voices[v].period = Int16(bitPattern: period) > 0x38B ? 0x38B : period
            use(.none, &slot)
        case 2:
            // And down, as far as $6C.
            play(v, cell)
            let period = voices[v].period &- low
            voices[v].period = Int16(bitPattern: period) < 0x6C ? 0x6C : period
            use(.none, &slot)
        case 4, 7:
            // The vibrato's or tremolo's wave (of the routine's voice).
            let wave = low == 0 ? Self.sine : low == 1 ? Self.ramp : Self.square
            if slot < 4 {
                if high == 4 { vibratoWaves[slot] = wave } else { tremoloWaves[slot] = wave }
            }
            if high == 4 { voices[v].vibratoPeriod = 0xFFFF }
            use(.none, &slot)
            play(v, cell)
        case 5:
            // The fine tuning, and the note taken up again with it.
            play(v, cell)
            voices[v].tuning = low
            use(.none, &slot)
            play(v, cell & 0xFF00_0000)
        case 9:
            use(.retrigger, &slot)
            voices[v].saved = cell
            play(v, cell)
        case 10:
            play(v, cell)
            let level = UInt8(low) &+ levels[v]
            levels[v] = Int8(bitPattern: level) > 0x40 ? 0x40 : level
            use(.none, &slot)
        case 11:
            play(v, cell)
            let level = levels[v] &- UInt8(low)
            levels[v] = Int8(bitPattern: level) < 0 ? 0 : level
            use(.none, &slot)
        case 12:
            play(v, cell)
            if low != 0 {
                voices[v].down = low
                use(.cut, &slot)
            } else {
                levels[v] = 0
                use(.none, &slot)
            }
        case 13:
            // A note delayed: the instrument taken now, the note kept.
            use(.delay, &slot)
            voices[v].saved = cell
            play(v, cell & 0x00FF_FFFF)
        case 14:
            // A pattern delay (unless the pattern is being delayed).
            use(.none, &slot)
            if mask & 0x8000_0000 != 0 { delayCount = low }
            play(v, cell)
        default:
            use(.none, &slot)
            play(v, cell)
        }
    }

    /// A voice's routine on a row's later ticks (`lbC0259B8`).
    private mutating func effect(_ v: Int) {
        switch effects[v] {
        case .none:
            break
        case .arpeggio:
            // `lbC025FAA`: the next of its periods, round to the first after the last (or at $FFFF).
            var at = voices[v].arpeggioAt
            if at == 3 { at = 0 }
            if at >= 0, at < 3, voices[v].arpeggio[at] == 0xFFFF { at = 0 }
            voices[v].arpeggioPeriod = at >= 0 && at < 3 ? voices[v].arpeggio[at] : 0
            voices[v].arpeggioAt = at + 1
        case .slideUp:
            let period = voices[v].period &- voices[v].slideStep
            voices[v].period = Int16(bitPattern: period) < 0x6C ? 0x6C : period
        case .slideDown:
            let period = voices[v].period &+ voices[v].slideStep
            voices[v].period = Int16(bitPattern: period) > 0x38B ? 0x38B : period
        case .toNote:
            toNote(v)
        case .vibrato:
            vibrato(v)
        case .toNoteAndVolume:
            toNote(v)
            volumeSlide(v)
        case .vibratoAndVolume:
            vibrato(v)
            volumeSlide(v)
        case .tremolo:
            // `lbC02607A`: the volume, about its level by the wave times the depth over 64, between nought and 64
            // (as bytes, with their signs), and its place in the wave moved on.
            let at = voices[v].tremoloAt
            let swing = UInt16(truncatingIfNeeded: UInt32(Self.tableByte(tremoloWaves[v] + Int(at))) * UInt32(voices[v].tremoloDepth)) >> 6
            var level = voices[v].tremoloLevel
            level = Int8(bitPattern: at) >= 0x1F ? level &- UInt8(truncatingIfNeeded: swing) : level &+ UInt8(truncatingIfNeeded: swing)
            if Int8(bitPattern: level) > 0x40 { level = 0x40 }
            if Int8(bitPattern: level) < 0 { level = 0 }
            levels[v] = level
            voices[v].tremoloAt = (at &+ voices[v].tremoloStep) & 0x3F
        case .volumeSlide:
            volumeSlide(v)
        case .delay:
            // `lbC0260E2`: the kept note begun once its ticks are over.
            let ticks = UInt16(speed) &- ticksLeft
            let saved = voices[v].saved
            guard ticks != 0, UInt8(truncatingIfNeeded: ticks) == UInt8(saved & 0x0F), saved >> 24 != 0 else { return }
            play(v, saved)
        case .retrigger:
            // `lbC02611E`: the kept cell taken up again every so many ticks.
            let every = UInt32(voices[v].saved & 0x0F)
            guard every != 0 else { return }
            let ticks = UInt16(speed) &- ticksLeft
            guard ticks != 0 || voices[v].saved & 0xFF == 0 else { return }
            if UInt32(ticks) % every == 0 { play(v, voices[v].saved) }
        case .cut:
            voices[v].down &-= 1
            if voices[v].down == 0 { levels[v] = 0 }
        }
    }

    /// `lbC025FFA`: the period moved towards the portamento's by its step, and no further.
    private mutating func toNote(_ v: Int) {
        let target = Int16(bitPattern: voices[v].target)
        var period = Int16(bitPattern: voices[v].period)
        if period < target {
            period &+= Int16(bitPattern: voices[v].toNoteStep)
            voices[v].period = UInt16(bitPattern: period < target ? period : target)
        } else {
            period &-= Int16(bitPattern: voices[v].toNoteStep)
            voices[v].period = UInt16(bitPattern: period < target ? target : period)
        }
    }

    /// `lbC026022`: the vibrato's period, the voice's own and the wave times the depth over 128 (less, in the wave's
    /// second half), between $6C and $38B; and its place in the wave moved on.
    private mutating func vibrato(_ v: Int) {
        let at = voices[v].vibratoAt
        let swing = Int16(truncatingIfNeeded: (UInt32(Self.tableByte(vibratoWaves[v] + Int(at))) * UInt32(voices[v].vibratoDepth)) >> 7)
        var period = Int16(bitPattern: voices[v].period)
        period = Int8(bitPattern: at) >= 0x1F ? period &- swing : period &+ swing
        if period > 0x38B { period = 0x38B }
        if period < 0x6C { period = 0x6C }
        voices[v].vibratoPeriod = UInt16(bitPattern: period)
        voices[v].vibratoAt = (at &+ voices[v].vibratoStep) & 0x3F
    }

    /// `lbC0260C0`: the volume slid up and down by the two, between nought and 64.
    private mutating func volumeSlide(_ v: Int) {
        var level = Int16(levels[v]) &+ Int16(bitPattern: voices[v].up) &- Int16(bitPattern: voices[v].down)
        if level > 0x40 { level = 0x40 }
        if level < 0 { level = 0 }
        levels[v] = UInt8(level)
    }
}

/// Blade Packer, played on Paula by `PaulaTickRenderer`.
extension BladePackerPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Blade Packer")
        let kind = voiceCount == 4 ? "" : ", eight voices of which it plays four"
        info.detail = "Tord Jansson's player; \(sampleCount) sample\(sampleCount == 1 ? "" : "s")\(kind)"
        info.shortfalls = shortfalls
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}

extension BladePackerPlayer {
    /// The player's tables of periods, sixteen of 36 for the fine tunings (from `lbB03523A`'s two bytes on), and
    /// after them its waves: the sine (`lbW0356BC`), the square (`lbW0356FC`), the ramp (`lbL03573C`) and the table
    /// after them (`lbL03577C`), which a vibrato past them reads.
    private static let tables: [UInt16] = [
        0x0358, 0x0328, 0x02FA, 0x02D0, 0x02A6, 0x0280, 0x025C, 0x023A, 0x021A, 0x01FC, 0x01E0, 0x01C5,
        0x01AC, 0x0194, 0x017D, 0x0168, 0x0153, 0x0140, 0x012E, 0x011D, 0x010D, 0x00FE, 0x00F0, 0x00E2,
        0x00D6, 0x00CA, 0x00BE, 0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F, 0x0078, 0x0071,
        0x0352, 0x0322, 0x02F5, 0x02CB, 0x02A2, 0x027D, 0x0259, 0x0237, 0x0217, 0x01F9, 0x01DD, 0x01C2,
        0x01A9, 0x0191, 0x017B, 0x0165, 0x0151, 0x013E, 0x012C, 0x011C, 0x010C, 0x00FD, 0x00EF, 0x00E1,
        0x00D5, 0x00C9, 0x00BD, 0x00B3, 0x00A9, 0x009F, 0x0096, 0x008E, 0x0086, 0x007E, 0x0077, 0x0071,
        0x034C, 0x031C, 0x02F0, 0x02C5, 0x029E, 0x0278, 0x0255, 0x0233, 0x0214, 0x01F6, 0x01DA, 0x01BF,
        0x01A6, 0x018E, 0x0178, 0x0163, 0x014F, 0x013C, 0x012A, 0x011A, 0x010A, 0x00FB, 0x00ED, 0x00E0,
        0x00D3, 0x00C7, 0x00BC, 0x00B1, 0x00A7, 0x009E, 0x0095, 0x008D, 0x0085, 0x007D, 0x0076, 0x0070,
        0x0346, 0x0317, 0x02EA, 0x02C0, 0x0299, 0x0274, 0x0250, 0x022F, 0x0210, 0x01F2, 0x01D6, 0x01BC,
        0x01A3, 0x018B, 0x0175, 0x0160, 0x014C, 0x013A, 0x0128, 0x0118, 0x0108, 0x00F9, 0x00EB, 0x00DE,
        0x00D1, 0x00C6, 0x00BB, 0x00B0, 0x00A6, 0x009D, 0x0094, 0x008C, 0x0084, 0x007D, 0x0076, 0x006F,
        0x0340, 0x0311, 0x02E5, 0x02BB, 0x0294, 0x026F, 0x024C, 0x022B, 0x020C, 0x01EF, 0x01D3, 0x01B9,
        0x01A0, 0x0188, 0x0172, 0x015E, 0x014A, 0x0138, 0x0126, 0x0116, 0x0106, 0x00F7, 0x00E9, 0x00DC,
        0x00D0, 0x00C4, 0x00B9, 0x00AF, 0x00A5, 0x009C, 0x0093, 0x008B, 0x0083, 0x007C, 0x0075, 0x006E,
        0x033A, 0x030B, 0x02E0, 0x02B6, 0x028F, 0x026B, 0x0248, 0x0227, 0x0208, 0x01EB, 0x01CF, 0x01B5,
        0x019D, 0x0186, 0x0170, 0x015B, 0x0148, 0x0135, 0x0124, 0x0114, 0x0104, 0x00F5, 0x00E8, 0x00DB,
        0x00CE, 0x00C3, 0x00B8, 0x00AE, 0x00A4, 0x009B, 0x0092, 0x008A, 0x0082, 0x007B, 0x0074, 0x006D,
        0x0334, 0x0306, 0x02DA, 0x02B1, 0x028B, 0x0266, 0x0244, 0x0223, 0x0204, 0x01E7, 0x01CC, 0x01B2,
        0x019A, 0x0183, 0x016D, 0x0159, 0x0145, 0x0133, 0x0122, 0x0112, 0x0102, 0x00F4, 0x00E6, 0x00D9,
        0x00CD, 0x00C1, 0x00B7, 0x00AC, 0x00A3, 0x009A, 0x0091, 0x0089, 0x0081, 0x007A, 0x0073, 0x006D,
        0x032E, 0x0300, 0x02D5, 0x02AC, 0x0286, 0x0262, 0x023F, 0x021F, 0x0201, 0x01E4, 0x01C9, 0x01AF,
        0x0197, 0x0180, 0x016B, 0x0156, 0x0143, 0x0131, 0x0120, 0x0110, 0x0100, 0x00F2, 0x00E4, 0x00D8,
        0x00CC, 0x00C0, 0x00B5, 0x00AB, 0x00A1, 0x0098, 0x0090, 0x0088, 0x0080, 0x0079, 0x0072, 0x006C,
        0x038B, 0x0358, 0x0328, 0x02FA, 0x02D0, 0x02A6, 0x0280, 0x025C, 0x023A, 0x021A, 0x01FC, 0x01E0,
        0x01C5, 0x01AC, 0x0194, 0x017D, 0x0168, 0x0153, 0x0140, 0x012E, 0x011D, 0x010D, 0x00FE, 0x00F0,
        0x00E2, 0x00D6, 0x00CA, 0x00BE, 0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F, 0x0078,
        0x0384, 0x0352, 0x0322, 0x02F5, 0x02CB, 0x02A3, 0x027C, 0x0259, 0x0237, 0x0217, 0x01F9, 0x01DD,
        0x01C2, 0x01A9, 0x0191, 0x017B, 0x0165, 0x0151, 0x013E, 0x012C, 0x011C, 0x010C, 0x00FD, 0x00EE,
        0x00E1, 0x00D4, 0x00C8, 0x00BD, 0x00B3, 0x00A9, 0x009F, 0x0096, 0x008E, 0x0086, 0x007E, 0x0077,
        0x037E, 0x034C, 0x031C, 0x02F0, 0x02C5, 0x029E, 0x0278, 0x0255, 0x0233, 0x0214, 0x01F6, 0x01DA,
        0x01BF, 0x01A6, 0x018E, 0x0178, 0x0163, 0x014F, 0x013C, 0x012A, 0x011A, 0x010A, 0x00FB, 0x00ED,
        0x00DF, 0x00D3, 0x00C7, 0x00BC, 0x00B1, 0x00A7, 0x009E, 0x0095, 0x008D, 0x0085, 0x007D, 0x0076,
        0x0377, 0x0346, 0x0317, 0x02EA, 0x02C0, 0x0299, 0x0274, 0x0250, 0x022F, 0x0210, 0x01F2, 0x01D6,
        0x01BC, 0x01A3, 0x018B, 0x0175, 0x0160, 0x014C, 0x013A, 0x0128, 0x0118, 0x0108, 0x00F9, 0x00EB,
        0x00DE, 0x00D1, 0x00C6, 0x00BB, 0x00B0, 0x00A6, 0x009D, 0x0094, 0x008C, 0x0084, 0x007D, 0x0076,
        0x0371, 0x0340, 0x0311, 0x02E5, 0x02BB, 0x0294, 0x026F, 0x024C, 0x022B, 0x020C, 0x01EE, 0x01D3,
        0x01B9, 0x01A0, 0x0188, 0x0172, 0x015E, 0x014A, 0x0138, 0x0126, 0x0116, 0x0106, 0x00F7, 0x00E9,
        0x00DC, 0x00D0, 0x00C4, 0x00B9, 0x00AF, 0x00A5, 0x009C, 0x0093, 0x008B, 0x0083, 0x007B, 0x0075,
        0x036B, 0x033A, 0x030B, 0x02E0, 0x02B6, 0x028F, 0x026B, 0x0248, 0x0227, 0x0208, 0x01EB, 0x01CF,
        0x01B5, 0x019D, 0x0186, 0x0170, 0x015B, 0x0148, 0x0135, 0x0124, 0x0114, 0x0104, 0x00F5, 0x00E8,
        0x00DB, 0x00CE, 0x00C3, 0x00B8, 0x00AE, 0x00A4, 0x009B, 0x0092, 0x008A, 0x0082, 0x007B, 0x0074,
        0x0364, 0x0334, 0x0306, 0x02DA, 0x02B1, 0x028B, 0x0266, 0x0244, 0x0223, 0x0204, 0x01E7, 0x01CC,
        0x01B2, 0x019A, 0x0183, 0x016D, 0x0159, 0x0145, 0x0133, 0x0122, 0x0112, 0x0102, 0x00F4, 0x00E6,
        0x00D9, 0x00CD, 0x00C1, 0x00B7, 0x00AC, 0x00A3, 0x009A, 0x0091, 0x0089, 0x0081, 0x007A, 0x0073,
        0x035E, 0x032E, 0x0300, 0x02D5, 0x02AC, 0x0286, 0x0262, 0x023F, 0x021F, 0x0201, 0x01E4, 0x01C9,
        0x01AF, 0x0197, 0x0180, 0x016B, 0x0156, 0x0143, 0x0131, 0x0120, 0x0110, 0x0100, 0x00F2, 0x00E4,
        0x00D8, 0x00CB, 0x00C0, 0x00B5, 0x00AB, 0x00A1, 0x0098, 0x0090, 0x0088, 0x0080, 0x0079, 0x0072,
        0x0018, 0x314A, 0x6178, 0x8DA1, 0xB4C5, 0xD4E0, 0xEBF4, 0xFAFD, 0xFFFD, 0xFAF4, 0xEBE0, 0xD4C5,
        0xB4A1, 0x8D78, 0x614A, 0x3118, 0x0018, 0x314A, 0x6178, 0x8DA1, 0xB4C5, 0xD4E0, 0xEBF4, 0xFAFD,
        0xFFFD, 0xFAF4, 0xEBE0, 0xD4C5, 0xB4A1, 0x8D78, 0x614A, 0x3118, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF,
        0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF,
        0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF,
        0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0x0008, 0x1018, 0x2028, 0x3038, 0x4048, 0x5058, 0x6068, 0x7078,
        0x8088, 0x9098, 0xA0A8, 0xB0B8, 0xC0C8, 0xD0D8, 0xE0E8, 0xF0F8, 0xFFF8, 0xF0E8, 0xE0D8, 0xD0C8,
        0xC0B8, 0xB0A8, 0xA098, 0x9088, 0x8078, 0x7068, 0x6058, 0x5048, 0x4038, 0x3028, 0x2018, 0x1008,
        0x006C, 0x0071, 0x0078, 0x007F, 0x0087, 0x008F, 0x0097, 0x00A0, 0x00AA, 0x00B4, 0x00BE, 0x00CA,
        0x00D6, 0x00E2, 0x00F0, 0x00FE, 0x010D, 0x011D, 0x012E, 0x0140, 0x0153, 0x0168, 0x017D, 0x0194,
        0x01AC, 0x01C5, 0x01E0, 0x01FC, 0x021A, 0x023A, 0x025C, 0x0280, 0x02A6, 0x02D0, 0x02FA, 0x0328,
        0x0358, 0x038B,
    ]
}
