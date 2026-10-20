// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after JamCrackerPro's play routine (M. Gemmel, optimised by Xag of Betrayal) as Buggs of DEFECT
// adapted it for EaglePlayer: its source, "JamCracker player module V1.1 (JAN/28/93)", which UADE carries
// as amigasrc/players/defect/jamcracker/JamCracker.s, and the player UADE runs, players/JamCracker
// ("V1.2 (JAN/04/95)"), whose replay is the same but for its waits for Paula's DMA, which it asks of
// EaglePlayer (`dtg_WaitAudioDMA`), and its silence, which it keeps in a hunk of its own. The labels given
// are the source's; the addresses, the V1.2 player's code's.

/// JamCracker, the tracker of M. Gemmel and Xag of Betrayal, whose modules ('BeEp') UnExoticA has from
/// Roll or Die (Ingmar Hansch) and Paramax (Martin Tykesson): instruments that are samples or waves of
/// 32 words that the player mixes afresh at every tick (its "AM" instruments), and patterns of rows of
/// four notes, each with its own speed, arpeggio, vibrato, phase, volume and portamento.
///
/// The file: 'BeEp'; the instruments, a word of how many and 40 bytes of each (a name of 31 bytes, its
/// flags, bit 0 for one that goes round and bit 1 for a wave, and its size, a long, and a long the player
/// fills in with where it is); the patterns, a word of how many and six bytes of each (its rows, a word,
/// and a long for where it is); the song, a word of its length and a word for each of its patterns; then
/// the patterns' rows, 32 bytes of each (eight bytes for each voice: its note, nought for none, the
/// instrument, the speed in the low four bits (nought for no change) and in bit 6 a portamento to the note
/// and in bit 7 a volume set, the arpeggio, vibrato, phase, volume and portamento); and the instruments'
/// samples, one after the other. A wave is its sample's first 64 bytes, and each voice mixes its own copy
/// of it into the sample, the first voice's at 128 bytes into it, the second's at 192, and so on: each
/// tick its phase moves on, and the wave is mixed with itself shifted by a quarter of it.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It has no timer of its own (only `DTP_Interrupt`), and so is run by
/// EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a
/// second and a little less. A row is read on the first tick and then every so many, six to begin with:
/// the voices with notes turned off, after a wait for Paula's DMA told their samples and periods, turned
/// on, and after another wait every voice told what it goes on to (its sample again, its wave, or the
/// player's silence for a sample that does not go round). At every tick each voice's period, its
/// arpeggio's three in turn bent by its portamento and vibrato, and its volume, sliding, are told Paula,
/// and a wave is mixed afresh.
///
/// Each voice's writes are told Paula at their moments in the tick (`TFMXOutput.timed(at:)`), as they fall
/// in UADE: the waits are for the beam to begin ten lines (`wait_audio_dma` in UADE's score.s, of
/// `dmawaitconstant` 10).
///
/// A song goes round at its end, and is said here to have come to it as its first row is read again (the
/// player tells EaglePlayer so as it reads the last). Where the player would read past the file it reads
/// nought; it would read its own variables for a note past its tables of periods, and reads nought for
/// them here; and an instrument past the file's, which it would take from whatever is there, is taken to
/// have no sample.
struct JamCrackerPlayer: ~Copyable {
    /// The file and what follows it, as Paula reads them; and the file as it was loaded, which the waves
    /// the player mixes into it are put back to as the song is started.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    private let loaded: [UInt8]
    /// Where a voice with nothing to play is pointed, and the player's silence (`pp_nullwave`): the
    /// noughts after the file.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where the instruments' table, the patterns' table and the song are in the file (`instable`,
    /// `patttable`, `songtable`), how many there are of each, where each instrument's sample and each
    /// pattern's rows are (what `pp_init` fills the tables in with), and the song's length (`songlen`).
    private let instrumentTable: Int
    let instrumentCount: Int
    private let patternTable: Int
    let patternCount: Int
    private let songTable: Int
    let songLength: UInt16
    private let instrumentPlaces: [Int]
    private let patternPlaces: [Int]
    /// How many of its instruments are waves.
    let waveCount: Int
    /// What is said of a file that ends before its patterns or samples do (see `TuneInfo.shortfalls`).
    let shortfalls: [String]

    var songCount: Int { 1 }
    var song: Int { 0 }
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// A voice (`pv_`, 48 bytes in the V1.2 player at $E30), its fields named as the source names them:
    /// where in an instrument its wave is (`pv_waveoffset`) and its bit of DMACON; what it plays next, in
    /// words and where (-1 for nowhere, as the player's are before it has played anything); its note, as a
    /// place in the table of periods (`pv_peraddress`), and the arpeggio's three periods, the first of which
    /// is heard and moved round each tick (`pv_pers`); its portamento, the amount it moves by and the period
    /// it moves to; its vibrato, the amount, the ticks left before it turns and how many it has; its
    /// volume, the amount it slides by and the level a note begins at; its wave's phase and the amount that
    /// moves by; and its instrument's flags.
    struct Voice {
        var waveOffset: Int16 = 0
        var dmacon: UInt16 = 0
        var length: UInt16 = 0
        var place = -1
        var note = 0
        var periods = InlineArray<3, UInt16>(repeating: 0)
        var portamento: Int16 = 0
        var portamentoStep: Int16 = 0
        var portamentoLevel: Int16 = 0
        var vibrato: Int16 = 0
        var vibratoStep: Int16 = 0
        var volume: Int16 = 0
        var volumeStep: Int16 = 0
        var volumeLevel: Int16 = 0
        var phase: Int16 = 0
        var phaseStep: Int16 = 0
        var vibratoCount: UInt8 = 0
        var vibratoTicks: UInt8 = 0
        var flags: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The ticks a row lasts (`pp_wait`) and those left of it (`pp_waitcnt`); the rows left of the pattern
    /// (`pp_notecnt`) and where the next is (`pp_address`); where the song is (`pp_songptr`) and the patterns
    /// left of it (`pp_songcnt`); and the voices whose notes begin in the row (`pp_tmpdmacon`).
    private var speed: UInt8 = 6
    private var ticksLeft: UInt8 = 1
    private var rowsLeft: UInt8 = 0
    private var row = 0
    private var songPlace = 0
    private var patternsLeft: UInt16 = 0
    private var starting: UInt16 = 0
    /// Where the rows of a pattern past the table are taken to be: far past the file, all noughts.
    private static let nowhere = Int.max / 4
    /// Whether the song has come to its end and goes round with the next row it reads.
    private var goesRound = false
    /// What each of Paula's period and volume registers was last given, and what they held as the tick
    /// just run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the waits.
    private var clock = 0

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (the medians of its dumps of
    /// UnExoticA's files, whose moments are those of its samples, some 80 clocks apart): where it begins
    /// (a guess: only the distances between its writes are heard); how long reading a row takes, to where
    /// it turns the voices of its notes off, how much longer one with notes takes, and longer again for
    /// each note; the look at each voice
    /// after the first wait, and the writing of a note's place and period there (longer for each voice
    /// further on); from the last of those to turning the voices on; between one voice's loop and the
    /// next's, after the second wait; between a voice's period and its volume at every tick, and its volume
    /// and the next voice's period; and how long mixing a wave takes.
    static let firstWrite = 300
    static let rowClocks = 390
    static let notesClocks = 210
    static let readNoteClocks = 220
    static let lookClocks = 24
    static let noteClocks = 110
    static let noteVoiceClocks = 12
    static let onClocks = 40
    static let loopClocks = 24
    static let volumeClocks = 200
    static let voiceClocks = 180
    static let waveClocks = 1530

    /// When the wait for Paula's DMA (UADE's `wait_audio_dma`) begun `at` clocks into the tick returns:
    /// once the beam's line (227 of Paula's clocks and a half) has changed ten times, the first at the next
    /// line's start; and some clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return ((now * 2 / 455 + 10) * 455) / 2 + 100 - clock
    }

    /// The table of periods (`pp_periods`, at $D42), three octaves and fifteen of its last; and after it
    /// in the player another (at $DA8, for EaglePlayer's analyser), which notes past the first read.
    static let periodTable: [UInt16] = [
        1019, 962, 908, 857, 809, 763, 720, 680, 642, 606, 572, 540,
        509, 481, 454, 428, 404, 381, 360, 340, 321, 303, 286, 270,
        254, 240, 227, 214, 202, 190, 180, 170, 160, 151, 143, 135,
        135, 135, 135, 135, 135, 135, 135, 135, 135, 135, 135, 135, 135, 135, 135,
        0x358, 0x358, 0x358, 0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A,
        0x1FC, 0x1E0, 0x1C5, 0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D,
        0xFE, 0xF0, 0xE2, 0xD6, 0xCA, 0xBE, 0xB4, 0xAA, 0xA0, 0x97, 0x8F, 0x87,
        0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x87,
    ]

    /// The period at `index` words into the table; past both, the player's variables, taken as nought.
    private static func period(_ index: Int) -> UInt16 {
        index >= 0 && index < periodTable.count ? periodTable[index] : 0
    }

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 { UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2)) }

    /// The player's `adda.w`: a word's worth of bytes, with its sign.
    @inline(__always) private static func signed(_ value: Int) -> Int { Int(Int16(truncatingIfNeeded: value)) }

    // MARK: - Loading

    /// True for a file the player's check takes (`checkmod`): 'BeEp' at its start.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 4 && data[0] == 0x42 && data[1] == 0x65 && data[2] == 0x45 && data[3] == 0x70
    }

    /// Reads the file and starts its song (it has one: `song` is taken for that one, whatever it is). A file
    /// whose tables run past its end is refused.
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        loaded = data
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        // `pp_init`: the tables one after the other (each added on as a word, with its sign), then the
        // patterns' rows, then the samples.
        var at = 4
        let instruments = Int(Self.word(data, at))
        at += 2
        instrumentTable = at
        instrumentCount = instruments
        at += Self.signed(instruments * 40)
        let patterns = Int(Self.word(data, at))
        at += 2
        patternTable = at
        patternCount = patterns
        at += Self.signed(patterns * 6)
        songLength = Self.word(data, at)
        at += 2
        songTable = at
        at += Self.signed(Int(songLength) * 2)
        let tablesEnd = max(instrumentTable, patternTable, songTable, at)
        var patternPlaces: [Int] = []
        patternPlaces.reserveCapacity(min(patterns, 0x1_0000))
        for p in 0 ..< patterns {
            patternPlaces.append(at)
            at += Self.signed(Int(Self.word(data, patternTable + 6 * p)) * 32)
        }
        let rowsEnd = at
        var instrumentPlaces: [Int] = []
        instrumentPlaces.reserveCapacity(min(instruments, 0x1_0000))
        var waves = 0
        var cut = Shortfall.CutShort()
        for i in 0 ..< instruments {
            instrumentPlaces.append(at)
            let size = Int(Int32(bitPattern: Self.long(data, instrumentTable + 40 * i + 32)))
            cut.add(length: size, there: data.count - at)
            at = at &+ size
            if instrumentTable + 40 * i + 31 < data.count, data[instrumentTable + 40 * i + 31] & 2 != 0 { waves += 1 }
        }
        self.patternPlaces = patternPlaces
        self.instrumentPlaces = instrumentPlaces
        waveCount = waves
        if rowsEnd > data.count {
            shortfalls = [Shortfall.cutShort("Its patterns are not all there, and what is missing of them is silent.")]
        } else {
            shortfalls = cut.sentence.map { [$0] } ?? []
        }
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a JamCracker module") }
        guard tablesEnd <= data.count, instrumentTable + 40 * instruments <= data.count,
              patternTable + 6 * patterns <= data.count
        else { throw .malformed("the module is cut short") }
        guard patterns > 0, songLength > 0 else { throw .malformed("the module has no song") }

        start()
        // The song's length, from a playing of it in silence to its end.
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        start()
    }

    deinit { memory.deallocate() }
}

// MARK: - Playing

extension JamCrackerPlayer {
    mutating func select(song _: Int) throws(TuneError) { start() }

    /// `pp_init`: the song from its first pattern, read at the first tick; each voice's wave at its place,
    /// its note the table's first and its arpeggio 1019 alone, its volume's level 64, and the rest nought.
    /// (The waves mixed into the file are put back as they were.)
    private mutating func start() {
        for i in 0 ..< fileSize { memory[i] = loaded[i] }
        songPlace = songTable
        patternsLeft = songLength
        let pattern = Int(word(songPlace))
        rowsLeft = pattern < patternCount ? byte(patternTable + 6 * pattern + 1) : 0
        row = pattern < patternCount ? patternPlaces[pattern] : Self.nowhere
        speed = 6
        ticksLeft = 1
        starting = 0
        goesRound = false
        for v in 0 ..< 4 {
            var voice = Voice()
            voice.waveOffset = Int16(0x80 + 0x40 * v)
            voice.dmacon = 1 << UInt16(v)
            voice.periods[0] = 1019
            voice.volumeLevel = 0x40
            voices[v] = voice
        }
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = .init(repeating: 0)
        volumesBefore = .init(repeating: 0)
        clock = 0
        endings = 0
    }

    /// The player's interrupt (`pp_play`), for a tick: the next row read once the row's ticks are over
    /// (`pp_nwnt`), and each voice moved on (`pp_uvs`). Returns the tick's length in milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        var at = Self.firstWrite
        ticksLeft &-= 1
        if ticksLeft == 0 {
            nextRow(&at, &output)
            ticksLeft = speed
        }
        for v in 0 ..< 4 { moveOn(v, &at, &output) }
        // (Kept within a whole number of the beam's lines, of 227 clocks and of 227.5, which is all the
        // waits ask of it: a count of every clock would outgrow a whole number in a browser.)
        clock = (clock + Self.tickClocks) % 103_285
        return 20
    }

    /// `pp_nwnt`: the row read and the place moved on, at a pattern's end to the song's next (and at the
    /// song's end back to its first); each voice's note read (`pp_nnt`); those with notes turned off, told
    /// their samples and periods (`pp_scr`) and turned on; and each told what it goes on to.
    private mutating func nextRow<Output: TFMXOutput>(_ at: inout Int, _ output: inout Output) {
        if goesRound {
            goesRound = false
            endings += 1
        }
        let notes = row
        row &+= 32
        rowsLeft &-= 1
        if rowsLeft == 0 {
            songPlace &+= 2
            patternsLeft &-= 1
            if patternsLeft == 0 {
                // (`dtg_SongEnd`: the song goes round, from the row after this one.)
                goesRound = true
                songPlace = songTable
                patternsLeft = songLength
            }
            let pattern = Int(word(songPlace))
            rowsLeft = pattern < patternCount ? byte(patternTable + 6 * pattern + 1) : 0
            row = pattern < patternCount ? patternPlaces[pattern] : Self.nowhere
        }
        starting = 0
        for v in 0 ..< 4 { readNote(v, at: notes &+ 8 * v) }
        at += Self.rowClocks
        if starting != 0 { at += Self.notesClocks + Self.readNoteClocks * starting.nonzeroBitCount }
        output.timed(at: at)
        for v in 0 ..< 4 where starting & voices[v].dmacon != 0 { output.off(v) }
        at = afterWait(at)
        for v in 0 ..< 4 {
            at += Self.lookClocks
            guard starting & voices[v].dmacon != 0 else { continue }
            output.timed(at: at)
            output.takeNextBuffer(v, start: voices[v].place, length: voices[v].length)
            periods[v] = voices[v].periods[0]
            output.writePeriod(v, periods[v])
            // (A sample that does not go round goes on to the player's silence, a word of it.)
            if voices[v].flags & 1 == 0 {
                voices[v].place = silenceAt
                voices[v].length = 1
            }
            at += Self.noteClocks + Self.noteVoiceClocks * v
        }
        at += Self.onClocks
        output.timed(at: at)
        for v in 0 ..< 4 where starting & voices[v].dmacon != 0 { output.on(v) }
        at = afterWait(at)
        for v in 0 ..< 4 {
            output.timed(at: at)
            output.takeNextBuffer(v, start: voices[v].place, length: voices[v].length)
            at += Self.loopClocks
        }
    }

    /// `pp_nnt`: a voice's eight bytes of the row (at `place`): its note and instrument, or
    /// with bit 6 of the speed the period its portamento goes to; the speed; the arpeggio; the vibrato;
    /// the phase; the volume; and the portamento.
    private mutating func readNote(_ v: Int, at place: Int) {
        let note = byte(place)
        let control = byte(place &+ 2)
        var voice = voices[v]
        if note != 0 {
            let index = Int(note) - 1
            if control & 0x40 != 0 {
                voice.portamentoLevel = Int16(bitPattern: Self.period(index))
            } else {
                starting |= voice.dmacon
                voice.note = index
                let period = Self.period(index)
                voice.periods = .init(repeating: period)
                voice.portamento = 0
                // (The instrument's number with its sign; one past the file's is taken to have no sample.)
                let instrument = Int(Int8(bitPattern: byte(place &+ 1)))
                if instrument < 0 || instrument >= instrumentCount {
                    voice.place = silenceAt
                    voice.length = 1
                    voice.flags = 0
                } else {
                    let entry = instrumentTable + 40 * instrument
                    let flags = byte(entry + 31)
                    var sample = instrumentPlaces[instrument]
                    if flags & 2 == 0 {
                        let size = UInt32(word(entry + 32)) << 16 | UInt32(word(entry + 34))
                        voice.length = UInt16(truncatingIfNeeded: size >> 1)
                    } else {
                        sample &+= Int(voice.waveOffset)
                        voice.length = 0x20
                    }
                    voice.place = sample
                    voice.flags = flags
                    voice.volume = voice.volumeLevel
                }
            }
        }
        if control & 0x0F != 0 { speed = control & 0x0F }
        let arpeggio = byte(place &+ 3)
        if arpeggio == 0xFF {
            voice.periods = .init(repeating: Self.period(voice.note))
        } else if arpeggio != 0 {
            voice.periods[2] = Self.period(voice.note + Int(arpeggio & 0x0F))
            voice.periods[1] = Self.period(voice.note + Int(arpeggio >> 4))
            voice.periods[0] = Self.period(voice.note)
        }
        let vibrato = byte(place &+ 4)
        if vibrato == 0xFF {
            voice.vibrato = 0
            voice.vibratoStep = 0
            voice.vibratoCount = 0
        } else if vibrato != 0 {
            voice.vibrato = 0
            voice.vibratoStep = Int16(vibrato & 0x0F)
            voice.vibratoTicks = vibrato >> 4
            voice.vibratoCount = voice.vibratoTicks >> 1
        }
        let phase = byte(place &+ 5)
        if phase == 0xFF {
            voice.phase = 0
            voice.phaseStep = -1
        } else if phase != 0 {
            voice.phaseStep = Int16(phase & 0x0F)
            voice.phase = 0
        }
        let volume = byte(place &+ 6)
        if volume == 0xFF {
            voice.volumeStep = 0
        } else if volume != 0 || control & 0x80 != 0 {
            if control & 0x80 != 0 {
                // (Its low byte only: the high is nought.)
                voice.volume = Int16(UInt16(bitPattern: voice.volume) & 0xFF00 | UInt16(volume))
                voice.volumeLevel = Int16(UInt16(bitPattern: voice.volumeLevel) & 0xFF00 | UInt16(volume))
                voice.volumeStep = 0
            } else {
                // A slide: bit 7 for down.
                let amount = volume & 0x7F
                voice.volumeStep = Int16(Int8(bitPattern: volume & 0x80 != 0 ? 0 &- amount : amount))
            }
        }
        let portamento = byte(place &+ 7)
        if portamento == 0xFF {
            voice.portamento = 0
            voice.portamentoStep = 0
        } else if portamento != 0 {
            voice.portamento = 0
            var step = portamento
            if control & 0x40 != 0 {
                // To the note: towards its period, from the first of the arpeggio's.
                if !(voice.portamentoLevel > Int16(bitPattern: voice.periods[0])) { step = 0 &- step }
            } else if step & 0x80 == 0 {
                // Up, as far as 135; bit 7 for down, as far as 1019.
                step = 0 &- step
                voice.portamentoLevel = 135
            } else {
                step &= 0x7F
                voice.portamentoLevel = 1019
            }
            voice.portamentoStep = Int16(Int8(bitPattern: step))
        }
        voices[v] = voice
    }

    /// The arpeggio moved round (`pp_rot`).
    private static func turn(_ voice: inout Voice) {
        let first = voice.periods[0]
        voice.periods[0] = voice.periods[1]
        voice.periods[1] = voice.periods[2]
        voice.periods[2] = first
    }

    /// `pp_uvs`: the voice's period, the arpeggio's first that is not nought, bent by its portamento (no
    /// further than where it goes to) and vibrato, between 135 and 1019, told Paula, and the arpeggio
    /// moved round; the portamento and vibrato moved on; the volume told Paula and slid on; and a wave
    /// mixed: its first 64 bytes with themselves from a quarter of its phase on, halved, into the voice's
    /// copy, and the phase moved on.
    private mutating func moveOn<Output: TFMXOutput>(_ v: Int, _ at: inout Int, _ output: inout Output) {
        var voice = voices[v]
        // (An arpeggio of noughts alone, for which the player would turn for ever, gives nought.)
        for _ in 0 ..< 3 where voice.periods[0] == 0 { Self.turn(&voice) }
        var period = Int16(bitPattern: voice.periods[0]) &+ voice.portamento
        if voice.portamento < 0 {
            if period < voice.portamentoLevel { period = voice.portamentoLevel }
        } else if voice.portamento > 0 {
            if period > voice.portamentoLevel { period = voice.portamentoLevel }
        }
        period &+= voice.vibrato
        period = period < 135 ? 135 : min(1019, period)
        periods[v] = UInt16(period)
        output.timed(at: at)
        output.writePeriod(v, periods[v])
        Self.turn(&voice)
        voice.portamento &+= voice.portamentoStep
        voice.portamento = voice.portamento < -1019 ? -1019 : min(1019, voice.portamento)
        if voice.vibratoCount != 0 {
            voice.vibrato &+= voice.vibratoStep
            voice.vibratoCount &-= 1
            if voice.vibratoCount == 0 {
                voice.vibratoStep = 0 &- voice.vibratoStep
                voice.vibratoCount = voice.vibratoTicks
            }
        }
        // (`JC_SetVoices`: seven bits, times EaglePlayer's volume, 64, over 64.)
        volumes[v] = UInt16(bitPattern: voice.volume) & 0x7F
        at += Self.volumeClocks
        output.timed(at: at)
        output.writeVolume(v, volumes[v])
        voice.volume &+= voice.volumeStep
        voice.volume = voice.volume < 0 ? 0 : min(0x40, voice.volume)
        if voice.flags & 2 != 0, voice.phaseStep != 0 {
            if voice.phaseStep < 0 { voice.phaseStep = 0 }
            mixWave(voice)
            voice.phase &+= voice.phaseStep
            if voice.phase >= 0x100 { voice.phase &-= 0x100 }
            at += Self.waveClocks
        }
        voices[v] = voice
        at += Self.voiceClocks
    }

    /// The wave mixed into the voice's copy of it (`.lb`), as bytes with their signs. (The player would
    /// write past the file for an instrument that ends too soon; only the file is written here.)
    private func mixWave(_ voice: Voice) {
        let into = voice.place
        let wave = into &- Int(voice.waveOffset)
        let shifted = wave &+ Int(UInt16(bitPattern: voice.phase) >> 2)
        for i in 0 ..< 64 {
            let a = Int16(Int8(bitPattern: byte(wave &+ i)))
            let b = Int16(Int8(bitPattern: byte(shifted &+ i)))
            let to = into &+ i
            if to >= 0, to < fileSize { memory[to] = UInt8(truncatingIfNeeded: (a + b) >> 1) }
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

/// JamCracker, played on Paula by `PaulaTickRenderer`.
extension JamCrackerPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "JamCracker")
        let plural = instrumentCount == 1 ? "" : "s"
        let waves = waveCount == 0 ? "" : waveCount == instrumentCount ? ", all waves" : ", \(waveCount) of them waves"
        info.detail = "JamCrackerPro's player; \(instrumentCount) instrument\(plural)\(waves)"
        info.shortfalls = shortfalls
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -21.4 dB.)
    var gain: Float { 0.33 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
