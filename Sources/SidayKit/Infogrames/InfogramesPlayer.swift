// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Infogrames' replay routine as Andy Silva ripped it (in 1994) and adapted it for DeliTracker
// ("Infogrames (RobHubbard2), adapted by Andy Silva"), as UADE carries it: players/Infogrames, whose
// source UADE also carries as amigasrc/players/uade/infogrames/Infogrames.asm (a disassembly, with UADE's
// choice of timer added) beside Andy Silva's own DP_Infogrames.s. The labels given are that source's.

/// Infogrames' music of the late 1980s and early 1990s, whose player the DeliTracker module calls Rob
/// Hubbard's second: the music of Bob Morane Ocean (and Operation and Project Neptune, which carry the
/// same), Bivouac (and Chamonix Challenge and Final Assault), Stir Crazy featuring Bobo and Captain Blood
/// among UnExoticA's, its score in one file (`.dum`) and its instruments in another (`.ins`).
///
/// The score: a table of where each song is, its first word being its length too (the songs are that
/// over two); each song eight words, its tempo, where its two tables of envelopes are (of volumes and of
/// periods, thirteen bytes each), where each voice's sequence is, and one more; and after them where each
/// pattern is, from the song's start. A sequence is a list of patterns, ended by $FF. A pattern is
/// bytes: under $80 a note (nought for none, else a semitone, the voice's transposition added, into a
/// table of eight octaves of periods), $80 to $9F the rows a note lasts, $A0 to $BF the sample to start,
/// $C0 to $DF the volume envelope, $E0 the transposition (a byte after it), $E1 and $E2 the period
/// envelope (a byte after it; $E1's goes round, $E2's does not), and $FF the pattern's end. An envelope is
/// a byte of how far each round moves it (for the volume's, and $80 for it to go round) and four steps of
/// three bytes: how many times, how far, and every how many ticks; the first is the attack, played once,
/// the other three go round. The sample file: a long (its size) and a table of sixteen bytes for each of
/// up to 32 samples, where its sound and its loop are, from the table's start, and their lengths in words.
///
/// This is the player itself, as the DeliTracker module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. Its timer is set to $1A00 (UADE's choice, `determine_timer_value`),
/// 106.6 times a second, but for a few other games' scores it knows by their sums (Gobliins 2 and 3,
/// Horror Zombies and Ween, none of them UnExoticA's). On every tick each voice's envelopes move its
/// volume and period, and each row (every so many ticks, the tempo) its count of rows comes down, and at
/// nought it reads its pattern until a note. A sample is started at once: Paula's voice is told it, turned
/// off and on, and told its loop.
///
/// Each voice's writes are told Paula at their moments in the tick (`TFMXOutput.timed(at:)`), as the
/// player's code makes them fall in UADE: a voice's volume and period some 456 of Paula's clocks after the
/// voice before's, and a sample's DMA turned on, and its loop told, each after UADE's `wait_audio_dma`,
/// which waits for the beam to begin ten lines (of 227 clocks), and so a voice that starts one comes some
/// 5,250 clocks after the one before (as measured in UADE's dumps). Its scores often have two or four
/// voices play one sample a little out of tune with each other, whose sound depends on how far apart
/// they begin.
///
/// Each voice plays its sequence once, and then is silent (the player's flag for going round, bit 5, is
/// set only by the game's calls for sound effects, which DeliTracker never makes); once all four are, the
/// song has stopped. Where the player would read past the score or the sample file it reads nought; where
/// it would read a voice's patterns for ever in a tick (a sequence of empty patterns), or jump to where
/// its table of commands has none (a command $E4 to $E7, which would crash the machine), the voice is
/// stopped.
struct InfogramesPlayer: ~Copyable {
    /// The sample file and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the noughts after the sample file.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let score: [UInt8]
    let sampleFileSize: Int
    /// The samples the sample file has room for in its table, of the 32 a pattern can choose.
    let sampleCount: Int

    /// The songs (`InitPlayer`: the first word, over two); no more than 64 are taken.
    let songCount: Int
    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// The CIA timer's count (`dtg_Timer`) and the tick it makes, in Paula's clocks: the timer counts down
    /// from it to nought and starts again, at a fifth of her clock.
    let timer: UInt16
    let tickClocks: Int

    /// A voice's envelope as it moves (16 bytes in the player, `lbL000AA8` and the others), its fields at
    /// their offsets: how far it has gone down (0) and up (2), where its steps are (4), how far each
    /// round goes down (8), the step it is at (10, a byte's offset), its flags (11: bit 0 to move by the
    /// step's distance, bit 2 at its end, bit 7 to go round), the ticks (12) and the times (13) of the step.
    struct Envelope {
        var down: UInt16 = 0
        var up: UInt16 = 0
        var steps = Int.min / 2
        var round: UInt8 = 0
        var at: UInt8 = 0
        var flags: UInt8 = 0
        var ticks: UInt8 = 0
        var times: UInt8 = 0

        /// What a note does to it: the envelope from its first step.
        mutating func restart() {
            at = 0
            up = 0
            down = 0
            times = 0
            ticks = 0
            flags |= 1
            flags &= ~4
        }
    }

    /// One voice (`lbL000A78` and the three after it, $50 bytes each), its fields at their offsets: where
    /// its sequence begins (0), its pattern (8) and sequence (12) are read next, its envelopes of volume
    /// ($30) and period ($40), its note's period ($20), its flags ($26: bit 0 to begin its sequence at the
    /// next tick, bit 6 silent), the rows left of its note ($28) and all of them ($29), and its
    /// transposition ($2A). (Its volume, $2B, and the level it fades to, $2F, are $3F, and its sound-effect
    /// voice, $1C, is never started, but by the game's calls for sound effects.)
    struct Voice {
        var sequenceStart = 0
        var pattern = Int.min / 2
        var sequence = Int.min / 2
        var volume = Envelope()
        var period = Envelope()
        var note: UInt16 = 0
        var flags: UInt16 = 0
        var rowsLeft: UInt8 = 0
        var rows: UInt8 = 0
        var transpose: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The player's own (`lbL000A24`): the song's start (12), its envelopes of volume (4) and of period
    /// (8), where its patterns are (16), its tempo ($1C) and the ticks left of its row ($1B), and the
    /// sample a voice has asked for in the tick ($18, $FF for none).
    private var base = 0
    private var volumeEnvelopes = 0
    private var periodEnvelopes = 0
    private var patternTable = 0
    private var tempo: UInt8 = 0
    private var tempoLeft: UInt8 = 0
    private var sampleToStart: UInt8 = 0xFF
    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    /// What they held as the tick just run began (what `PaulaTickRenderer` sets Paula to then, before the
    /// tick's writes are told at their moments).
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the waits.
    private var clock = 0
    private var stopped = false

    /// A song that has not stopped in an hour is taken never to.
    private var mostTicks: Int { 3600 * Int(Paula.clockHz) / tickClocks }
    /// How many bytes of its sequence and patterns a voice may read in a tick before it is taken to be
    /// going round for ever; far more than any score reads.
    static let mostReads = 0x10000

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (the medians of its dumps of
    /// Stir Crazy's music): the first voice's volume after the interrupt begins (a guess: only the distances
    /// between the voices are heard); the next voice's, for a voice that starts no sample; a sample's place
    /// after the voice's volume; and the next voice's volume after a sample's loop is told.
    static let firstWrite = 300
    static let voiceClocks = 456
    static let placeClocks = 141
    static let afterLoopClocks = 600

    /// When `wait_audio_dma` (UADE's `dtg_WaitAudioDMA`, its `dmawaitconstant` of 10) begun `at` clocks
    /// into the tick returns: once the beam's line (227 of Paula's clocks) has changed ten times, the first
    /// at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 10) * 227 + 80 - clock
    }

    /// The table of periods (`lbW000D1A`): eight octaves, the lowest first, and two noughts; and what
    /// follows it in the player, to its end, which a note past them reads (a table of the kinds of
    /// characters, from a C library).
    static let periodTable: [UInt16] = [
        0x6ACC, 0x64CC, 0x5F25, 0x59CE, 0x54C3, 0x5003, 0x4B86, 0x4747, 0x4346, 0x3F8B, 0x3BF3, 0x3892,
        0x3568, 0x3269, 0x2F93, 0x2CEA, 0x2A66, 0x2801, 0x2566, 0x23A5, 0x21AF, 0x1FC4, 0x1DFE, 0x1C4E,
        0x1ABC, 0x1936, 0x17CC, 0x1676, 0x1533, 0x1401, 0x12E4, 0x11D5, 0x10D4, 0x0FE3, 0x0EFE, 0x0E26,
        0x0D5B, 0x0C9B, 0x0BE5, 0x0B3B, 0x0A9B, 0x0A02, 0x0972, 0x08E9, 0x0869, 0x07F1, 0x077F, 0x0713,
        0x06AD, 0x064D, 0x05F2, 0x059D, 0x054D, 0x0500, 0x04B8, 0x0475, 0x0435, 0x03F8, 0x03BF, 0x038A,
        0x0356, 0x0326, 0x02F9, 0x02CF, 0x02A6, 0x0280, 0x025C, 0x023A, 0x021A, 0x01FC, 0x01E0, 0x01C5,
        0x01AB, 0x0193, 0x017D, 0x0167, 0x0153, 0x0140, 0x012E, 0x011D, 0x010D, 0x00FE, 0x00F0, 0x00E2,
        0x00D6, 0x00CA, 0x00BE, 0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F, 0x0078, 0x0070,
        0x0060, 0x0050, 0x0040, 0x0030, 0x0020, 0x0010, 0x0000, 0x0000, 0x0020, 0x2020, 0x2020, 0x2020,
        0x2020, 0x3030, 0x3030, 0x3020, 0x2020, 0x2020, 0x2020, 0x2020, 0x2020, 0x2020, 0x2020, 0x2020,
        0x2090, 0x4040, 0x4040, 0x4040, 0x4040, 0x4040, 0x4040, 0x4040, 0x400C, 0x0C0C, 0x0C0C, 0x0C0C,
        0x0C0C, 0x0C40, 0x4040, 0x4040, 0x4040, 0x0909, 0x0909, 0x0909, 0x0101, 0x0101, 0x0101, 0x0101,
        0x0101, 0x0101, 0x0101, 0x0101, 0x0101, 0x0101, 0x4040, 0x4040, 0x4040, 0x0A0A, 0x0A0A, 0x0A0A,
        0x0202, 0x0202, 0x0202, 0x0202, 0x0202, 0x0202, 0x0202, 0x0202, 0x0202, 0x0202, 0x4040, 0x4040,
        0x2000,
    ]

    /// The rows a note lasts (`lbW000A58`), by the command's low four bits: twelve, and then the first
    /// bytes of the table after it (`lbW000A64`: a word of $800, and an address, whose first byte is
    /// nought and whose second is where the player is in the machine's memory, taken here as nought).
    static let rowsTable: [UInt8] = [2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 8, 0, 0, 0]

    /// The timers the player knows other games' scores by (`timerlist`): the sum of the score's longs
    /// (the last, if it is cut short, made up with noughts), its size, and the timer.
    static let knownTimers: [(sum: UInt32, size: Int, timer: UInt16)] = [
        (0x752A_B846, 2850, 0x24FF), (0xC069_1337, 3634, 0x24FF), (0xE19F_E7A1, 4211, 0x24FF), (0x0B0F_2EBA, 3305, 0x24FF),
        (0xABDF_F091, 3433, 0x24FF), (0xC55B_87E3, 2605, 0x24FF), (0xF8AC_972A, 2180, 0x24FF),
        (0xBFF9_C6C1, 3234, 0x1B66),
        (0xCD05_9F22, 3160, 0x24FF), (0x0990_733E, 2614, 0x24FF), (0xEB38_A5F3, 2183, 0x24FF), (0xB3E5_589E, 2179, 0x24FF),
    ]

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < score.count ? score[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    /// A word of the score taken as a distance, with its sign, as the 68000's `lea (a1,d0.w)` takes it.
    @inline(__always) private func offset(_ at: Int) -> Int { Int(Int16(bitPattern: word(at))) }

    @inline(__always) private func sampleByte(_ at: Int) -> UInt8 { at >= 0 && at < sampleFileSize ? memory[at] : 0 }
    @inline(__always) private func sampleWord(_ at: Int) -> UInt16 { UInt16(sampleByte(at)) << 8 | UInt16(sampleByte(at + 1)) }
    @inline(__always) private func sampleLong(_ at: Int) -> UInt32 { UInt32(sampleWord(at)) << 16 | UInt32(sampleWord(at + 2)) }

    // MARK: - Loading

    /// True for a score the player's check takes (`CheckFormat`): a first word that is even and not
    /// nought, within the file; and where the first song's first word (which is the first song, the table
    /// being as long as that word) says its envelopes of volume are, a nought and then 15 (the first
    /// envelope's going round and how many times its first step moves, as every score's are).
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 4 else { return false }
        let first = Int(data[0]) << 8 | Int(data[1])
        guard first != 0, first & 1 == 0, first < 0x8000, data.count > first, first + 3 < data.count else { return false }
        let envelopes = first + Int(Int16(bitPattern: UInt16(data[first + 2]) << 8 | UInt16(data[first + 3])))
        guard envelopes >= 0, envelopes + 1 < data.count else { return false }
        return data[envelopes] == 0 && data[envelopes + 1] == 15
    }

    /// Reads the score and its sample file (the `.ins` beside it) and starts song `song` (the first, if
    /// it has no such song). A score given no samples (an empty file) is refused, as the player's
    /// `LoadFiles` refuses it when it finds no sample file.
    init(_ data: [UInt8], samples: [UInt8], song: Int = 0) throws(TuneError) {
        score = data
        sampleFileSize = samples.count
        silenceAt = (samples.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in samples.enumerated() { memory[i] = b }
        let first = data.count >= 2 ? Int(data[0]) << 8 | Int(data[1]) : 0
        songCount = max(1, min(64, first / 2))
        sampleCount = max(0, min(32, (samples.count - 4) / 16))
        // The timer, by the score's sum and size (`determine_timer_value`): its longs added up, and the
        // last few bytes, if there are any, as the top of one.
        var sum: UInt32 = 0
        var at = 0
        while at + 4 <= data.count {
            sum &+= UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
            at += 4
        }
        var last: UInt32 = 0
        for i in 0 ..< data.count - at { last |= UInt32(data[at + i]) << (24 - 8 * UInt32(i)) }
        sum &+= last
        timer = Self.knownTimers.first { $0.sum == sum && $0.size == data.count }?.timer ?? 0x1A00
        tickClocks = (Int(timer) + 1) * 5
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not an Infogrames score") }
        guard !samples.isEmpty else {
            throw .missingCompanion("An Infogrames score keeps its instruments in a file of their own, with .ins for .dum, which was not given with it.")
        }
        try select(song: song >= 0 && song < songCount ? song : 0)
    }

    deinit { memory.deallocate() }
}

// MARK: - Playing

extension InfogramesPlayer {
    /// Starts song `song`; and finds how long it is, played through for up to an hour.
    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        start()
        var none = TFMXSilentOutput()
        var ticks = 0
        while stops == 0, ticks < mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it stopped in is silent.)
        lengthClocks = stops > 0 ? UInt64(ticks - 1) * UInt64(tickClocks) : nil
        start()
    }

    /// `InitSound`: the song begun as `lbC0003DE` (`_InitDum`) begins it, each voice silent, then started by
    /// `lbC00049E` (`_SndFunc`) with $80, which sets every voice's flags to $81: to begin its sequence at
    /// the next tick. (The DeliTracker module's own `InitSound` takes the song it was given at its start,
    /// which is the last; siday's songs are the score's, in its order.)
    private mutating func start() {
        voices = .init(repeating: Voice())
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = .init(repeating: 0)
        volumesBefore = .init(repeating: 0)
        clock = 0
        endings = 0
        stops = 0
        stopped = false
        sampleToStart = 0xFF
        base = offset(2 * song)
        tempo = UInt8(truncatingIfNeeded: word(base))
        tempoLeft = tempo
        volumeEnvelopes = base + offset(base + 2)
        periodEnvelopes = base + offset(base + 4)
        for v in 0 ..< 4 {
            voices[v].sequenceStart = base + offset(base + 6 + 2 * v)
            voices[v].flags = 0x81
        }
        patternTable = base + 16
    }

    /// The player's interrupt (`lbC000586`, `_Play`), for a tick: the tempo's count down; each voice in
    /// turn played (`lbC000726`) and its volume and period told Paula, and the sample it asked for, if it
    /// did, started: Paula told where it is and how long, turned off, after a wait on, and after another
    /// told its loop (`Wait_Audio_DMA_Hardware_To_Reset`); each at its moment in the tick (see the type's
    /// comment). Returns the tick's length in milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        tempoLeft &-= 1
        sampleToStart = 0xFF
        periodsBefore = periods
        for v in 0 ..< 4 { volumesBefore[v] = min(64, volumes[v] & 0x7F) }
        var at = Self.firstWrite
        for v in 0 ..< 4 {
            let (volume, period) = play(v)
            volumes[v] = volume
            periods[v] = period
            output.timed(at: at)
            output.writeVolume(v, min(64, volume & 0x7F))
            output.writePeriod(v, period)
            guard sampleToStart != 0xFF else {
                at += Self.voiceClocks
                continue
            }
            let entry = 4 + 16 * Int(sampleToStart)
            sampleToStart = 0xFF
            // (A place is the table's address and the entry's long, added in 32 bits.)
            let start = Int(Int32(bitPattern: 4 &+ sampleLong(entry)))
            let loop = Int(Int32(bitPattern: 4 &+ sampleLong(entry + 4)))
            output.timed(at: at + Self.placeClocks)
            output.takeNextBuffer(v, start: start, length: sampleWord(entry + 12))
            output.off(v)
            let on = afterWait(at + Self.placeClocks)
            output.timed(at: on)
            output.on(v)
            let looped = afterWait(on)
            output.timed(at: looped)
            output.takeNextBuffer(v, start: loop, length: sampleWord(entry + 14))
            at = looped + Self.afterLoopClocks
        }
        clock += tickClocks
        if tempoLeft == 0 { tempoLeft = tempo }
        if !stopped, (0 ..< 4).allSatisfy({ voices[$0].flags & 0x40 != 0 }) {
            // Every voice has come to its end: nothing more is heard.
            stopped = true
            endings += 1
            stops += 1
        }
        return 1000 * tickClocks / Int(Paula.clockHz)
    }

    /// `lbC000726`: a voice's tick, unless it is silent: at its start or once its note's rows are over
    /// (counted down at each row), its pattern read until a note; its envelopes moved. Returns the volume
    /// and period it gives Paula (each nought, for a voice silent).
    private mutating func play(_ v: Int) -> (UInt16, UInt16) {
        guard voices[v].flags & 0x40 == 0 else { return (0, 0) }
        var reads = 0
        if voices[v].flags & 1 != 0 {
            voices[v].flags &= ~1
            // (`lbC0007D6`: the sequence from its start.)
            voices[v].sequence = voices[v].sequenceStart
        } else {
            if tempoLeft == 0 { voices[v].rowsLeft &-= 1 }
            guard voices[v].rowsLeft == 0 else { return envelopes(v) }
            voices[v].rowsLeft = voices[v].rows
            // (`lbC000788`: the pattern first.)
            if !readPattern(v, &reads) { return envelopes(v) }
        }
        while true {
            // `lbC000794`: the next pattern of the sequence, or at its end ($FF) the voice silent.
            let at = voices[v].sequence
            let number = byte(at)
            reads += 1
            if number == 0xFF || reads > Self.mostReads {
                voices[v].flags |= 0x40
                return (0, 0)
            }
            voices[v].sequence = at + 1
            voices[v].pattern = base + offset(patternTable + 2 * Int(number))
            if !readPattern(v, &reads) { return envelopes(v) }
        }
    }

    /// `lbC000788`: the voice's pattern read until a note (`lbC000802`), which is false; or to its end,
    /// true, for the sequence to be read on. A voice that reads too much, or a command with nowhere to
    /// go, is made silent (and the sequence's end is said to be read).
    private mutating func readPattern(_ v: Int, _ reads: inout Int) -> Bool {
        while true {
            reads += 1
            if reads > Self.mostReads { return stop(v) }
            let at = voices[v].pattern
            let command = byte(at)
            if command == 0xFF { return true }
            voices[v].pattern = at + 1
            switch command {
            case 0x00 ..< 0x80:
                // A note: its period, both envelopes from their starts.
                var note = command
                if note != 0 { note &+= voices[v].transpose }
                voices[v].note = Int(note) < Self.periodTable.count ? Self.periodTable[Int(note)] : 0
                voices[v].volume.restart()
                voices[v].period.restart()
                return false
            case 0x80 ..< 0xA0:
                let rows = Self.rowsTable[Int(command & 15)]
                voices[v].rows = rows
                voices[v].rowsLeft = rows
            case 0xA0 ..< 0xC0:
                sampleToStart = command & 0x1F
            case 0xC0 ..< 0xE0:
                // The volume envelope: its first byte the distance of a round, and bit 7 to go round.
                let envelope = volumeEnvelopes + 13 * Int(command & 0x1F)
                let first = byte(envelope)
                voices[v].volume.flags = first & 0x80
                voices[v].volume.round = first & 0x7F
                voices[v].volume.restart()
                voices[v].volume.steps = envelope + 1
            default:
                // `lbL000A44`, by the low three bits.
                switch command & 7 {
                case 0:
                    // `lbC000976`: the transposition.
                    voices[v].transpose = byte(voices[v].pattern)
                    voices[v].pattern += 1
                case 1, 2:
                    // `lbC0009D0` and `lbC000986`: the period envelope, going round or not.
                    let envelope = periodEnvelopes + 13 * Int(byte(voices[v].pattern))
                    voices[v].pattern += 1
                    voices[v].period.flags = command & 7 == 1 ? 0x80 : 0
                    voices[v].period.round = 0
                    voices[v].period.restart()
                    voices[v].period.steps = envelope + 1
                case 3:
                    // `lbC000A1C`: nothing.
                    break
                default:
                    // (The table's fifth entry is the long $01020408, and those after it the player's
                    // code: on the Amiga, a crash.)
                    return stop(v)
                }
            }
        }
    }

    /// A voice made silent, as at its sequence's end.
    private mutating func stop(_ v: Int) -> Bool {
        voices[v].flags |= 0x40
        voices[v].pattern = Int.min / 2
        voices[v].sequence = Int.min / 2
        return false
    }

    /// `lbC00090E`: the volume, its envelope's (`lbC000692`) from nought, less what the voice's volume is
    /// under $3F, which is nothing (and so the low byte of it); the period, the note's moved by its
    /// envelope.
    private mutating func envelopes(_ v: Int) -> (UInt16, UInt16) {
        guard voices[v].flags & 0x40 == 0 else { return (0, 0) }
        var envelope = voices[v].volume
        let volume = move(&envelope, from: 0) & 0xFF
        voices[v].volume = envelope
        envelope = voices[v].period
        let period = move(&envelope, from: voices[v].note)
        voices[v].period = envelope
        return (volume, period)
    }

    /// `lbC000692`: an envelope moved on a tick, and the value it makes of `value`: the value and how far
    /// it has gone up and down, nought if that is under it. At a step's start (bit 0) it goes up by the
    /// step's distance; every so many ticks the step is done once more; after so many times, the next
    /// step, and after the last, the second again, the whole having gone down by its round's distance; or,
    /// for one that does not go round, it is at its end, and moves no more.
    private func move(_ e: inout Envelope, from value: UInt16) -> UInt16 {
        let step = e.steps &+ Int(e.at)
        if e.flags & 1 != 0 {
            e.flags &= ~1
            e.up &+= UInt16(bitPattern: Int16(Int8(bitPattern: byte(step &+ 1))))
        }
        var result = value &+ e.up &- e.down
        if result & 0x8000 != 0 { result = 0 }
        guard e.flags & 4 == 0 else { return result }
        e.ticks &+= 1
        guard byte(step &+ 2) == e.ticks else { return result }
        e.times &+= 1
        e.ticks = 0
        if byte(step) == e.times {
            e.times = 0
            var next = e.at &+ 3
            if next == 12 {
                if e.flags == 0 {
                    e.flags |= 4
                    return result
                }
                e.times = 0
                e.down &+= UInt16(bitPattern: Int16(Int8(bitPattern: e.round)))
                next = 3
            }
            e.at = next
        }
        e.flags |= 1
        return result
    }

    /// Paula's period for the voice as the tick just run began (its writes in the tick are told at their
    /// moments).
    func period(_ voice: Int) -> UInt16 { periodsBefore[voice] }
    /// Paula's volume for the voice as the tick just run began, as she takes what the player gave her:
    /// seven bits, 64 or more being full.
    func volume(_ voice: Int) -> UInt16 { volumesBefore[voice] }
    /// What the player last gave Paula's period register for the voice.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Infogrames' music, played on Paula by `PaulaTickRenderer`.
extension InfogramesPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Infogrames")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Infogrames' player (Rob Hubbard's second, as DeliTracker has it); \(sampleCount) sample\(plural)"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { tickClocks }
}
