// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Richard Joseph and Andi Smithers' "RJ Replayer Version 1.7A (10.07.93)",
// from the game Ruff'n'Tumble, as Wanted Team adapted it for EaglePlayer ("Richard Joseph Player V1.7A
// module replayer V1.1 (3 May 2001)", carried by UADE as players/RichardJoseph_Player, whose source UADE
// also carries as amigasrc/players/wanted_team/RichardJosephPlayer/src/Richard Joseph Player_v2.asm).
// The addresses given are of that player's code hunk, as UADE 3.05 carries it; the labels its source's.

/// Richard Joseph's player, in which he wrote the music of the games of Sensible Software (Cannon Fodder,
/// Sensible World of Soccer, Sensible Golf), the Bitmap Brothers' Chaos Engine, Millennium's James Pond 2
/// and 3, Flight of the Amazon Queen and others (and Jason Page that of Ruff'n'Tumble): a module
/// ("RJP1SMOD") of seven parts,
/// its samples in a file of their own beside it ("RJP1" and the sounds), in the collection the module's
/// name with .smp (`title.rjp`, `title.smp`), or one file for several modules (James Pond 2's AGA
/// version, `set.smp`).
///
/// The module's parts, each its length first: the samples, 32 bytes each (where the sound is in the
/// sample file, and two tables of it that move the period and the volume, its volume, its loop and an
/// envelope); the envelopes, six bytes each (a level to begin at, a level and a count of ticks to reach
/// it, another and another count, and the ticks to fall to nought when the note is let go); the songs,
/// four bytes each, for each voice a sequence or nought for none; where each sequence is, and each
/// pattern; the sequences, each a list of patterns ended by a nought and what follows it (another
/// nought to stop, a count of bytes to go back by, or $80 or more and a sequence to go on into); and the
/// patterns, their notes (even, into a table of three octaves of periods) and commands: $80 the pattern's
/// end, $81 the note let go, $82 the ticks a row lasts, $83 the rows a note lasts, $84 the instrument,
/// $85 the volume, $86 a slide of the period, and $87 a row of nothing.
///
/// This is the player itself, as Wanted Team's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`), and so is
/// run by EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty
/// times a second and a little less. Its speed is set once (`Init_Speed` with 13, at $57E), which is one
/// step of the patterns a tick. It owns the memory Paula plays from: the module, whose places in the
/// sample file `Init_Data` makes into the Amiga's addresses, and the sample file, into which the player
/// writes nought at the first word of where each note begins, before the note is played.
///
/// Where the player would read past the module or its samples it reads nought. Where it would go round
/// a sequence for ever in a tick (and so stop the machine), the voice is stopped (see `mostReads`).
struct RichardJosephPlayer: ~Copyable {
    /// The module and its samples, as Paula reads them (see `samplesAt`).
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: past the samples, where nothing is written.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    /// Where the sample file is in `memory` (the module is at nought): its sounds begin four bytes in,
    /// after "RJP1" (`Init_Data`, $784, adds four to its address).
    let samplesAt: Int
    let sampleFileSize: Int
    /// `memory` below `silenceAt` once the module has been set up, for each song to begin from.
    private var image: [UInt8] = []

    /// Where each of the module's seven parts is (`lbL000F8A` + 4 to + 28, `Init_Data`'s), and the length
    /// of the first, the samples, as the module gives it (which `lbC0008C8` compares an instrument with).
    private var sampleTable: UInt32 = 0
    private var envelopes: UInt32 = 0
    private var songTable: UInt32 = 0
    private var sequenceTable: UInt32 = 0
    private var patternTable: UInt32 = 0
    private var sequences: UInt32 = 0
    private var patterns: UInt32 = 0
    private var sampleTableLength: UInt32 = 0
    /// How many instruments the module has (`MI_Samples`), and how much of the sample file those its
    /// songs choose play (see `init`).
    let instrumentCount: Int
    let samplesNeeded: Int64

    /// The songs, four bytes each in the module (`DTP_SubSongRange`): no more than 64, as `Init_Song`
    /// ($978) takes the number in six bits.
    let songCount: Int
    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// Each voice's mark for the song's end (`SongEnd`, a byte each, nought once the voice has come to
    /// the end of its sequence), the marks as the song began (`SongEndTemp`, nought for a voice the song
    /// has no sequence for), and how many voices the song has (`MI_Voices`).
    private var endMarks = InlineArray<4, Bool>(repeating: false)
    private var endMarksAtStart = InlineArray<4, Bool>(repeating: false)
    private var voicesUsed = 0
    /// Whether every voice has stopped and the song with them.
    private var stopped = false

    /// One voice, as the player keeps it (`lbL000CCA` and the three after it, $B0 bytes each; only the
    /// first $5C are the music's, the rest being for sound effects, which EaglePlayer never starts),
    /// named by what its fields are, at their offsets.
    struct Voice {
        /// The sound's address ($4), its tables of periods' and volumes' moves ($8, $C; nought for none),
        /// and its envelope ($10).
        var sound: UInt32 = 0
        var vibratoTable: UInt32 = 0
        var volumeTable: UInt32 = 0
        var envelope: UInt32 = 0
        /// The loop, in words from the sound's start, and its length ($16, $18).
        var loopStart: UInt16 = 0
        var loopLength: UInt16 = 0
        /// Each table's place, its end and where it goes round to: the periods' ($20, $1C, $1A) and the
        /// volumes' ($2A, $26, $24); the ends and the places in bytes, the loops in words.
        var vibratoAt: UInt32 = 0
        var vibratoEnd: UInt32 = 0
        var vibratoLoop: UInt16 = 0
        var volumeAt: UInt32 = 0
        var volumeEnd: UInt32 = 0
        var volumeLoop: UInt16 = 0
        /// The instrument's volume ($30), and the volume being worked out ($32).
        var instrumentVolume: UInt16 = 0
        var level: UInt16 = 0
        /// The note's period ($34) and the period as its table moves it ($36).
        var notePeriod: UInt16 = 0
        var period: UInt16 = 0
        /// A note has been begun, and its DMA is to be turned on ($38); its DMA has been turned on, and
        /// its loop is to be told Paula ($39). (Bit 0 of each.)
        var started: UInt8 = 0
        var looping: UInt8 = 0
        /// The envelope: its stage ($3A: 4 rising, 2 falling to the sustain, $FF let go, 0 held), the
        /// distance it moves in the stage ($3B), the ticks left of it ($3C) and all of them ($3D), the
        /// level it goes to ($3E) and the level it is at ($3F).
        var stage: UInt8 = 0
        var distance: UInt8 = 0
        var ticksLeft: UInt8 = 0
        var ticks: UInt8 = 0
        var target: UInt8 = 0
        var envelopeLevel: UInt8 = 0
        /// The slide: its ticks left ($40), whether the row set it ($41), how far a tick ($42) and how far
        /// it has gone ($46), in 65,536ths of a period.
        var slideTicks: UInt8 = 0
        var slideSet: UInt8 = 0
        var slideStep: UInt32 = 0
        var slide: UInt32 = 0
        /// The instrument's entry among the samples ($4A, nought for none yet), where the sequence is read
        /// next ($4E) and the pattern ($52, nought for none).
        var instrument: UInt32 = 0
        var sequenceAt: UInt32 = 0
        var patternAt: UInt32 = 0
        /// The ticks a row lasts and the count of them ($56, $57), the rows a note lasts and the count of
        /// them ($58, $59), the instrument's number ($5A), and whether the voice plays ($5B).
        var speed: UInt8 = 0
        var speedCount: UInt8 = 0
        var rows: UInt8 = 0
        var rowCount: UInt8 = 0
        var instrumentNumber: UInt8 = 0
        var active = false
    }

    private(set) var voices = InlineArray<4, Voice>(repeating: Voice())
    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60
    /// How many bytes of the patterns and sequences a voice may read in a tick before it is taken to be
    /// going round for ever, which on the Amiga would stop the machine (a sequence that goes back onto
    /// its own end, say), and is stopped; far more than any module reads.
    static let mostReads = 0x10000

    /// The table of periods (`lbW000C82`, at $1228): three octaves, the lowest first, each from its B down
    /// to its C (ProTracker's periods), read by the note, which is a byte's offset into it.
    static let periodTable: [UInt16] = [
        0x1C5, 0x1E0, 0x1FC, 0x21A, 0x23A, 0x25C, 0x280, 0x2A6, 0x2D0, 0x2FA, 0x328, 0x358,
        0x0E2, 0x0F0, 0x0FE, 0x10D, 0x11D, 0x12E, 0x140, 0x153, 0x168, 0x17D, 0x194, 0x1AC,
        0x071, 0x078, 0x07F, 0x087, 0x08F, 0x097, 0x0A0, 0x0AA, 0x0B4, 0x0BE, 0x0CA, 0x0D6,
    ]

    // MARK: - Memory, as the 68000 reads and writes it

    /// (As the 68000 has them, addresses of 24 bits.)
    @inline(__always) func byte(_ a: UInt32) -> UInt8 {
        let i = Int(a & 0xFF_FFFF)
        return i < memoryCapacity ? memory[i] : 0
    }

    @inline(__always) func word(_ a: UInt32) -> UInt16 { UInt16(byte(a)) << 8 | UInt16(byte(a &+ 1)) }
    @inline(__always) func long(_ a: UInt32) -> UInt32 { UInt32(word(a)) << 16 | UInt32(word(a &+ 2)) }

    /// Writes go anywhere below the silence (which is never written, that it stays silent).
    @inline(__always) func setByte(_ a: UInt32, _ v: UInt8) {
        let i = Int(a & 0xFF_FFFF)
        if i < silenceAt { memory[i] = v }
    }

    @inline(__always) func setWord(_ a: UInt32, _ v: UInt16) {
        setByte(a, UInt8(v >> 8))
        setByte(a &+ 1, UInt8(truncatingIfNeeded: v))
    }

    @inline(__always) func setLong(_ a: UInt32, _ v: UInt32) {
        setWord(a, UInt16(v >> 16))
        setWord(a &+ 2, UInt16(truncatingIfNeeded: v))
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`, $36C): "RJP" and any byte, then "SMOD", and
    /// the module's first sample at nought in the sample file (a module the game had not yet set up).
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 16 else { return false }
        return data[0] == 0x52 && data[1] == 0x4A && data[2] == 0x50
            && data[4] == 0x53 && data[5] == 0x4D && data[6] == 0x4F && data[7] == 0x44
            && data[12] == 0 && data[13] == 0 && data[14] == 0 && data[15] == 0
    }

    /// Reads the module and its samples (the sample file, "RJP1" first, which the player does not check)
    /// and starts song `song` (the first, if it has no such song). A module given no samples (an empty
    /// file) is refused, as the player refuses it when its `ExtLoad` finds no sample file beside it.
    init(_ data: [UInt8], samples: [UInt8], song: Int = 0) throws(TuneError) {
        // (Read as 64 bits, that a length or place a long gives does not overflow where `Int` has 32.)
        let end = Int64(data.count)
        func byte(_ i: Int64) -> UInt8 { i >= 0 && i < end ? data[Int(i)] : 0 }
        func word(_ i: Int64) -> Int64 { Int64(byte(i)) << 8 | Int64(byte(i &+ 1)) }
        func long(_ i: Int64) -> Int64 { word(i) << 16 | word(i &+ 2) }
        var refusal: TuneError?
        if !Self.isOne(data) { refusal = .unsupported("not a Richard Joseph Player module") }

        // `InitPlayer` ($482): the seven parts, each its length and then itself, all within the file.
        var parts = InlineArray<7, Int64>(repeating: 0), lengths = InlineArray<7, Int64>(repeating: 0)
        var size: Int64 = 8
        for k in 0 ..< 7 where refusal == nil {
            lengths[k] = long(size)
            parts[k] = size + 4
            size += 4 + lengths[k]
            if size > end { refusal = .malformed("it is cut short") }
        }
        // (`Init_Data` goes through the samples 32 bytes at a time until its count, a word, comes to
        // nought: for a length not a whole number of them it never does.)
        if refusal == nil, lengths[0] == 0 { refusal = .malformed("it has no samples") }
        if refusal == nil, lengths[0] % 32 != 0 { refusal = .malformed("its table of samples is not a whole number of them") }
        let songs = Int(min(64, lengths[2] / 4))
        if refusal == nil, songs == 0 { refusal = .malformed("it has no songs") }
        if refusal == nil, samples.isEmpty {
            refusal = .missingCompanion("A Richard Joseph Player module keeps its samples in a file of their own, which was not given with it.")
        }
        // How much of the sample file the instruments the songs choose play: each one's sound to the end
        // of its first part and of its loop, and its tables to their ends; and its four bytes of header.
        // (Only for saying so, should the file be shorter: the player does not look. Five of UnExoticA's
        // modules have instruments past their files, which none of their songs chooses.)
        let count = refusal == nil ? Int(lengths[0] / 32) : 0
        var chosen = InlineArray<256, Bool>(repeating: false)
        if refusal == nil {
            // The patterns of the sequences the songs give the voices, and of those they go on into.
            var seen = InlineArray<256, Bool>(repeating: false), played = InlineArray<256, Bool>(repeating: false)
            var todo: [Int] = []
            for i in 0 ..< Int64(4 * songs) where byte(parts[2] + i) != 0 { todo.append(Int(byte(parts[2] + i))) }
            while let sequence = todo.popLast() {
                guard !seen[sequence] else { continue }
                seen[sequence] = true
                var at = parts[5] + long(parts[3] + 4 * Int64(sequence))
                while at < end, byte(at) != 0 {
                    played[Int(byte(at))] = true
                    at += 1
                }
                if byte(at + 1) & 0x80 != 0 { todo.append(Int(byte(at + 2))) }
            }
            // The instruments their $84 commands choose (or the first, for one past them).
            for pattern in 0 ..< 256 where played[pattern] {
                var at = parts[6] + long(parts[4] + 4 * Int64(pattern))
                while at < end, byte(at) != 0x80 {
                    let b = byte(at)
                    if b == 0x84, byte(at + 1) != 0 { chosen[32 * Int64(byte(at + 1)) < lengths[0] ? Int(byte(at + 1)) : 0] = true }
                    at += 1
                    switch b {
                    case 0x82, 0x83, 0x84: at += 1
                    case 0x85: at += 2
                    case 0x86: at += 5
                    default: break
                    }
                }
            }
        }
        var needed: Int64 = 0
        for i in 0 ..< min(count, 256) where chosen[i] {
            let entry = parts[0] + 32 * Int64(i)
            let sound = long(entry)
            needed = max(needed, sound + 2 * (word(entry + 16) + word(entry + 18)), sound + 2 * (word(entry + 20) + word(entry + 22)))
            if long(entry + 4) != 0 { needed = max(needed, long(entry + 4) + 2 * word(entry + 26)) }
            if long(entry + 8) != 0 { needed = max(needed, long(entry + 8) + 2 * word(entry + 30)) }
        }
        instrumentCount = count
        samplesNeeded = count > 0 ? needed + 4 : 0
        songCount = max(1, songs)

        // Where everything goes: the module at nought, the sample file after it, then the silence.
        func aligned(_ n: Int) -> Int { (n + 15) & ~15 }
        samplesAt = aligned(max(data.count, 16))
        sampleFileSize = samples.count
        silenceAt = aligned(samplesAt + samples.count + 4)
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        for (i, b) in samples.enumerated() { memory[samplesAt + i] = b }
        if refusal == nil {
            sampleTable = UInt32(parts[0])
            sampleTableLength = UInt32(lengths[0])
            envelopes = UInt32(parts[1])
            songTable = UInt32(parts[2])
            sequenceTable = UInt32(parts[3])
            patternTable = UInt32(parts[4])
            sequences = UInt32(parts[5])
            patterns = UInt32(parts[6])
            fixUp(size: Int(size))
            setUp()
        }
        image = Array(UnsafeBufferPointer(start: memory, count: silenceAt))
        if let refusal { throw refusal }
        try select(song: song >= 0 && song < songCount ? song : 0)
    }

    deinit { memory.deallocate() }

    /// What `InitPlayer` ($4DE, $4F2) mends in two modules by their sizes: Crazy Football's title (9,506
    /// bytes), a word of 2 at 2,650 made nought; and Cannon Fodder 2's (2,989 bytes), a long of
    /// $08050706 at 1,192.
    private func fixUp(size: Int) {
        if size == 9506, word(2650) == 2 { setWord(2650, 0) }
        if size == 2989, long(1192) == 0x0805_0706 { setLong(1192, 0) }
    }

    /// `Init_Data`'s setting up of the samples ($7E2): each one's places in the sample file (its sound,
    /// and its two tables if it has them) made the addresses they are, and the place in it its notes
    /// begin at, in words, made bytes; 32 bytes at a time while a count from the samples' length, in a
    /// word, comes down to nought by 32. And the module marked as set up ("MODS" for "SMOD").
    private func setUp() {
        let base = UInt32(samplesAt + 4)
        var entry = sampleTable
        var left = UInt16(truncatingIfNeeded: sampleTableLength)
        repeat {
            setLong(entry, long(entry) &+ base)
            for field in [UInt32(4), 8] where long(entry &+ field) != 0 {
                setLong(entry &+ field, long(entry &+ field) &+ base)
            }
            setWord(entry &+ 16, word(entry &+ 16) &* 2)
            entry &+= 32
            left &-= 32
        } while left != 0
        setLong(4, 0x4D4F_4453)
    }
}

// MARK: - Playing

extension RichardJosephPlayer {
    /// Starts song `song`, as `InitSound` ($564) does; and finds how long it is, played through for up to
    /// an hour.
    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        start()
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

    /// The song from its beginning: the module and samples as they were set up, the voices cleared
    /// (`lbC0002B8`, from `Init_Data`), and `Init_Song` ($978): each voice the song gives a sequence
    /// begun on its first pattern (`lbC00041E`, $9DC), and the voices it gives none marked as at their end.
    private mutating func start() {
        image.withUnsafeBufferPointer { memory.update(from: $0.baseAddress!, count: $0.count) }
        voices = .init(repeating: Voice())
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        endings = 0
        stops = 0
        stopped = false
        voicesUsed = 0
        let entry = songTable &+ 4 &* UInt32(song & 0x3F)
        for v in 0 ..< 4 {
            let sequence = byte(entry &+ UInt32(v))
            endMarksAtStart[v] = sequence != 0
            guard sequence != 0 else { continue }
            voicesUsed += 1
            var at = sequenceTable &+ 4 &* UInt32(sequence)
            at = long(at) &+ sequences
            let pattern = byte(at)
            voices[v].sequenceAt = at &+ 1
            voices[v].patternAt = long(patternTable &+ 4 &* UInt32(pattern)) &+ patterns
            voices[v].speed = 6
            voices[v].speedCount = 1
            voices[v].rowCount = 1
            voices[v].active = true
        }
        endMarks = endMarksAtStart
    }

    /// The player's interrupt (`Interrupt`, $1EA), for a tick: a song with no voices has come to its end
    /// (and so, here, stopped); then `Play` ($A44), each voice in turn. Returns the tick's length in
    /// milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        guard !stopped else { return 20 }
        let endingsBefore = endings
        if voicesUsed == 0 { endings += 1 }
        for v in 0 ..< 4 where voices[v].active { voiceTick(v, &output) }
        // Once no voice plays, the player does nothing more: the song has come to its end (or, for a
        // voice taken to go round for ever, there). It has stopped if nothing is left sounding; a voice
        // left on a loop at some volume goes on sounding it, as it does on the Amiga, and the song is
        // faded as one that goes on is.
        if !(0 ..< 4).contains(where: { voices[$0].active }) {
            stopped = true
            if endings == endingsBefore { endings += 1 }
            if !(0 ..< 4).contains(where: { volumes[$0] > 0 && voices[$0].loopLength > 1 }) { stops += 1 }
        }
        return 20
    }

    /// `lbC000580` ($AEE), for a voice that plays: its loop told Paula a tick after its DMA was turned on
    /// (`lbC00059C`, $B0A), its DMA turned on a tick after its note was begun (`lbC0005C4`, $B32), its
    /// patterns read (`lbC0005DE`, $B4C), its volume (`lbC0006E0`, $C52) and its period (`lbC0007F8`,
    /// $D74) worked out and told her.
    private mutating func voiceTick<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        // (`lbC000554`, $AC2: a slide is the row's that sets it, and the note's that row begins.)
        voices[v].slideSet = 0
        if voices[v].looping & 1 != 0 {
            voices[v].looping &= ~1
            output.takeNextBuffer(v, start: Int((voices[v].sound &+ UInt32(voices[v].loopStart) &* 2) & 0xFF_FFFF), length: voices[v].loopLength)
        }
        if voices[v].started & 1 != 0 {
            voices[v].started &= ~1
            voices[v].looping = 0xFF
            output.on(v)
        }
        readPatterns(v, &output)
        envelope(v)
        volumeTable(v)
        setVolume(v)
        setPeriod(v)
    }

    /// `lbC0005DE` ($B4C): the voice's count of ticks down, and at its end its count of rows; at the end of
    /// that, its next row read from its pattern (`lbC000600`, $B6E), commands until a note, a let-go or a
    /// row of nothing; the counts begun again.
    private mutating func readPatterns<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        guard voices[v].patternAt != 0 else { return }
        voices[v].speedCount &-= 1
        guard voices[v].speedCount == 0 else { return }
        voices[v].rowCount &-= 1
        if voices[v].rowCount == 0 {
            var at = voices[v].patternAt
            var reads = 0
            row: while true {
                reads += 1
                if reads > Self.mostReads {
                    // (Going round for ever: the voice is stopped.)
                    voices[v].active = false
                    at = 0
                    break row
                }
                let b = byte(at)
                at &+= 1
                if b & 0x80 == 0 {
                    // A note: its period from the table. (A note past it, which the player would read from
                    // its own variables, is the table's last; an odd one, on which the 68000 would stop,
                    // the one below it. No module of UnExoticA's has either.)
                    let index = min(Int(b >> 1), Self.periodTable.count - 1)
                    noteOn(v, period: Self.periodTable[index], &output)
                    break row
                }
                // The command's jump (`lbC0005FA`, $B68, into the table at $B9C): $88 lands on $81's
                // routine; one past it in the middle of the player's own code, here a row of nothing.
                switch b {
                case 0x80:
                    // `lbC000684` ($BF2): the pattern's end, the sequence's next pattern; at its end, the
                    // song's end told (`SongEndTest`, $230), and the sequence stopped, gone back by a count
                    // of bytes, or gone on into another.
                    var seq = voices[v].sequenceAt
                    voices[v].rows = 1
                    while true {
                        reads += 1
                        if reads > Self.mostReads { break }
                        let pattern = byte(seq)
                        seq &+= 1
                        if pattern != 0 {
                            voices[v].sequenceAt = seq
                            at = long(patternTable &+ 4 &* UInt32(pattern)) &+ patterns
                            continue row
                        }
                        songEndTest(v)
                        let then = byte(seq)
                        if then == 0 {
                            at = 0
                            voices[v].active = false
                            break row
                        }
                        if then & 0x80 != 0 {
                            seq = long(sequenceTable &+ 4 &* UInt32(byte(seq &+ 1))) &+ sequences
                        } else {
                            seq &-= UInt32(then)
                        }
                    }
                    voices[v].active = false
                    at = 0
                    break row
                case 0x81, 0x88: release(v); break row
                case 0x82:
                    voices[v].speed = byte(at)
                    at &+= 1
                case 0x83:
                    voices[v].rows = byte(at)
                    at &+= 1
                case 0x84:
                    let number = byte(at)
                    at &+= 1
                    if number != 0 { setInstrument(v, number) }
                case 0x85:
                    voices[v].instrumentVolume = UInt16(byte(at))
                    at &+= 2
                case 0x86:
                    voices[v].slideSet = 0xFF
                    voices[v].slideTicks = byte(at)
                    voices[v].slideStep = long(at &+ 1)
                    voices[v].slide = 0
                    at &+= 5
                default: break row
                }
            }
            voices[v].patternAt = at
            voices[v].rowCount = voices[v].rows
        }
        voices[v].speedCount = voices[v].speed
    }

    /// `SongEndTest` ($230): the voice's mark taken off; once every voice's is, the song has come to its
    /// end, and the marks are put back as the song began.
    private mutating func songEndTest(_ v: Int) {
        endMarks[v] = false
        guard !(0 ..< 4).contains(where: { endMarks[$0] }) else { return }
        endMarks = endMarksAtStart
        endings += 1
    }

    /// `lbC000856` ($DD6): a note begun, if the voice has an instrument: its period, its slide put by
    /// unless the row has set one, its envelope begun; Paula's DMA turned off, the first word of where it
    /// begins in the sound written nought, and Paula told to play from there, for the length of its first
    /// part; its DMA to be turned on in the next tick.
    private mutating func noteOn<Output: TFMXOutput>(_ v: Int, period: UInt16, _ output: inout Output) {
        let entry = voices[v].instrument
        guard entry != 0 else { return }
        voices[v].notePeriod = period
        voices[v].period = period
        if voices[v].slideSet == 0 {
            voices[v].slide = 0
            voices[v].slideTicks = 0
        }
        let envelope = envelopes &+ UInt32(bitPattern: Int32(Int16(bitPattern: word(entry &+ 12))))
        voices[v].envelope = envelope
        voices[v].target = byte(envelope &+ 1)
        voices[v].distance = byte(envelope &+ 1) &- byte(envelope)
        voices[v].ticks = byte(envelope &+ 2)
        voices[v].ticksLeft = byte(envelope &+ 2)
        voices[v].stage = 4
        output.off(v)
        let begin = voices[v].sound &+ UInt32(word(entry &+ 16))
        setWord(begin, 0)
        output.takeNextBuffer(v, start: Int(begin & 0xFF_FFFF), length: word(entry &+ 18))
        voices[v].started = 0xFF
    }

    /// `lbC0008C8` ($E4C): the instrument, if it is not the voice's already: its entry among the samples
    /// (the first, for one past them), its sound, loop, tables and volume.
    private mutating func setInstrument(_ v: Int, _ number: UInt8) {
        guard number != voices[v].instrumentNumber else { return }
        voices[v].instrumentNumber = number
        var offset = UInt32(number) << 5
        if Int32(bitPattern: offset) >= Int32(bitPattern: sampleTableLength) { offset = 0 }
        let entry = sampleTable &+ offset
        voices[v].instrument = entry
        voices[v].loopStart = word(entry &+ 0x14)
        voices[v].loopLength = word(entry &+ 0x16)
        voices[v].instrumentVolume = word(entry &+ 0x0E)
        voices[v].vibratoLoop = word(entry &+ 0x18)
        voices[v].vibratoAt = 0
        voices[v].vibratoEnd = UInt32(word(entry &+ 0x1A)) &* 2
        voices[v].volumeLoop = word(entry &+ 0x1C)
        voices[v].volumeAt = 0
        voices[v].volumeEnd = UInt32(word(entry &+ 0x1E)) &* 2
        voices[v].sound = long(entry)
        voices[v].vibratoTable = long(entry &+ 4)
        voices[v].volumeTable = long(entry &+ 8)
    }

    /// `lbC0007D0` ($D4C): the note let go: its envelope falls from where it is to nought, over the
    /// envelope's last count of ticks.
    private mutating func release(_ v: Int) {
        let envelope = voices[v].envelope
        guard envelope != 0 else { return }
        voices[v].target = 0
        voices[v].distance = 0 &- voices[v].envelopeLevel
        voices[v].ticks = byte(envelope &+ 5)
        voices[v].ticksLeft = byte(envelope &+ 5)
        voices[v].stage = 0xFF
    }

    /// `lbC000744` ($CBA): the envelope's level, the distance of its stage short of where it goes by the
    /// part of its ticks left (nought ticks being none); at the stage's end, the next: from rising, falling
    /// to the sustain (`lbC0007A4`, $D20), and from that or from being let go, held. The level is the
    /// volume worked out from (`lbC000786`, $CFE).
    private mutating func envelope(_ v: Int) {
        var voice = voices[v]
        if voice.stage != 0 {
            let product = Int32(Int16(Int8(bitPattern: voice.distance))) * Int32(voice.ticksLeft)
            let part = voice.ticks == 0 ? 0 : product / Int32(voice.ticks)
            voice.envelopeLevel = voice.target &- UInt8(truncatingIfNeeded: part)
            voice.ticksLeft &-= 1
            if voice.ticksLeft == 0xFF {
                if voice.stage & 0x80 != 0 {
                    // (At the end of letting go, the player's `BMI` to `lbC00079E`, $CF8, returns from
                    // the routine itself: the volume is not taken from the level in this tick, and is what
                    // the last tick worked out, before it was kept to 64.)
                    voice.stage = 0
                    voices[v] = voice
                    return
                } else if voice.stage == 2 {
                    voice.stage = 0
                } else if voice.stage == 4, voice.envelope != 0 {
                    let at = voice.envelope
                    voice.target = byte(at &+ 3)
                    voice.distance = byte(at &+ 3) &- byte(at &+ 1)
                    voice.ticks = byte(at &+ 4)
                    voice.ticksLeft = byte(at &+ 4)
                    voice.stage = 2
                }
            }
        }
        voice.level = UInt16(voice.envelopeLevel)
        voices[v] = voice
    }

    /// `lbC000712` ($C88): the volume moved by the instrument's table of volumes, by its byte's part of
    /// 128 of it; the table read on a byte a tick, round from its loop at its end.
    private mutating func volumeTable(_ v: Int) {
        let table = voices[v].volumeTable
        guard table != 0 else { return }
        let move = Int32(Int8(bitPattern: byte(table &+ voices[v].volumeAt))) * Int32(Int16(bitPattern: voices[v].level))
        voices[v].level &+= UInt16(bitPattern: Int16(truncatingIfNeeded: move) >> 7)
        var at = voices[v].volumeAt &+ 1
        if at == voices[v].volumeEnd { at = UInt32(voices[v].volumeLoop) &* 2 }
        voices[v].volumeAt = at
    }

    /// `lbC0006EA` ($C5C): the volume times the instrument's, over 64, times the voice's own (64, as
    /// EaglePlayer sets it), over 64, each in a word; told Paula as no more than 64 and no less than nought
    /// (and through EaglePlayer's volume and balance, at their fullest, which leave it be).
    private mutating func setVolume(_ v: Int) {
        let first = Int16(truncatingIfNeeded: Int32(Int16(bitPattern: voices[v].level)) * Int32(Int16(bitPattern: voices[v].instrumentVolume))) >> 6
        let second = Int16(truncatingIfNeeded: Int32(first) * 64) >> 6
        voices[v].level = UInt16(bitPattern: second)
        let volume: UInt16 = UInt16(bitPattern: second) <= 64 ? UInt16(bitPattern: second) : second > 64 ? 64 : 0
        volumes[v] = volume & 0x7F
    }

    /// `lbC0007F8` ($D74): the period moved by the instrument's table of periods, by its byte's part of
    /// 128 of the note's period (upwards by half as much as downwards), read on a byte a tick, round from
    /// its loop at its end; the slide moved on; told Paula as the two together.
    private mutating func setPeriod(_ v: Int) {
        var voice = voices[v]
        let table = voice.vibratoTable
        if table != 0 {
            let product = Int32(Int8(bitPattern: byte(table &+ voice.vibratoAt))) * Int32(Int16(bitPattern: voice.notePeriod))
            var move = 0 &- Int16(truncatingIfNeeded: product >> 7)
            if move < 0 { move >>= 1 }
            voice.period = UInt16(bitPattern: move) &+ voice.notePeriod
            var at = voice.vibratoAt &+ 1
            if at == voice.vibratoEnd { at = UInt32(voice.vibratoLoop) &* 2 }
            voice.vibratoAt = at
        }
        if voice.slideTicks != 0 {
            voice.slide &+= voice.slideStep
            voice.slideTicks &-= 1
        }
        periods[v] = UInt16(truncatingIfNeeded: voice.slide >> 16) &+ voice.period
        voices[v] = voice
    }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as the player last set it (never more than 64).
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Richard Joseph's player, played on Paula by `PaulaTickRenderer`.
extension RichardJosephPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Richard Joseph")
        let plural = instrumentCount == 1 ? "" : "s"
        info.detail = "Richard Joseph and Andi Smithers' RJ Replayer 1.7A; \(instrumentCount) instrument\(plural)"
        if Int64(sampleFileSize) < samplesNeeded {
            info.shortfalls.append("Its sample file is shorter than its instruments' sounds, and what is missing of them is silent.")
        }
        return info
    }

    /// Richard Joseph's music is quieter on the Amiga's chip than ProTracker's is, by 3.1 dB in the
    /// middle of UnExoticA's 108 modules that make a sound, and is turned up by that (2026-10-19).
    var gain: Float { 0.66 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
