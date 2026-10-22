// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Andy Silva's DeliTracker player "Follin Player II" ("Tim Follin / Mike D., adapted by Andy Silva"),
// carried by UADE as players/TimFollin, and after its source, which UADE also carries as
// amigasrc/players/other/timfollin/DP_TimFollin.asm. UADE's binary is a later build than that source (it has its
// own `DTP_SubSongRange`, and takes the song from DeliTracker's number as it is): where they differ, the binary is
// followed, and the addresses given are of its code hunk; the labels are the source's. Its replay routine is the
// game's own, as Puzznic's file carries it with its code (its routine that begins a voice's wave again, at $12326 of
// MUZ0.tf, writes from the instrument's third byte on, as the player's does at $942, which only adds a check that
// the voice has an instrument).

/// Tim Follin's music as Ghouls 'n Ghosts, Sly Spy and Puzznic carried it on the Amiga: data for a player of four
/// voices, each a stream of bytes that the voice reads as it goes, of notes and of commands that set how the notes
/// that follow are played.
///
/// A file is of one of two kinds. Puzznic's is the game's own: it begins with six or more `JMP`s into its code,
/// the first to the address the file was made to be loaded at, and its data begins at $432. The others are the
/// data alone, after a header of 28 bytes of Atari's ($601A) or none: $1010 or $1012, and then the data, whose
/// song nought's four voices all begin at one place, the bytes `81 04 32 02 8F 00`, by which the address the file
/// was made for is found. The data begins with the places of each song's voices (sixteen bytes a song, from byte
/// 4), the places of each song's table of instruments (from byte $104), each song's count of voices, three or four
/// (from $144), and a list, ended by a nought, of instruments whose word at 2 is a place (from $194). Every place
/// is an address of the file as it was made, which the player moves to where it is: those at the data's start,
/// up to the first long whose top byte is not nought, and those of the list, as it starts; the rest as it reads
/// them. An instrument is a word, its length in words, and 48 bytes more, before its sample.
///
/// A note is a byte from 1 to $7F, transposed, and is followed by its length in ticks unless a length has been
/// fixed. The commands are bytes from $80: none ($80), an instrument (1), a call and its return (2, 3), a loop of
/// so many times and its end (4, 5), the envelope (6: the volume it starts at and holds at, how many ticks it
/// waits between steps up and down, and the part it starts in), a slide to each note (7), a trill (8), a vibrato
/// (9), the transposition (10), a length fixed (11), the envelope on (12), a byte of flags (13: an instrument to be
/// told Paula as the note's loop, if bit 6 is set; the voice turned off a tick before the next note, if bit 7), a
/// wave whose width changes (14: the first four instruments' samples are waves, a step of which is made every so
/// many ticks), the voice's end (15), the envelope's step (16), the next note not transposed (17), and a jump (18).
///
/// This is the player itself, as UADE runs it: what it tells Paula is what that player tells her, tick by tick. It
/// sets no timer of its own (it has only `DTP_Interrupt`), and so is run by DeliTracker's, which UADE runs from a
/// CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second and a little less. On every tick the loops
/// asked for in the tick before are told Paula, and then each voice's wave, envelope, vibrato or trill, and slide
/// are moved, and once a note's ticks are done the voice reads on.
///
/// The player has no end of its own; here a song comes to its end once every voice has either come to its end or
/// gone back to a place it has been, by a jump back or by a call made again before it has returned (as each of
/// UnExoticA's songs that goes round does: Puzznic's fifth by calls, and so it is heard round twice before its end),
/// and stops if every voice has come to its end.
///
/// The player keeps the voices' calls in four longs each, one after another, and one long more after them: a voice's
/// fifth call goes into the next one's room, as the player's does, and one past them all is not kept. (Puzznic's
/// fifth song's calls, which never return, go on past them: in UADE, as it goes round for the seventh time, into
/// the player's song number, and so its instruments are another song's, and as it goes round for the eighth, into
/// the count of its fade, after which it begins song nought, and is silent from 7 minutes 11 seconds. Here the song
/// goes on round as it began.) Where the player would read outside the file it reads nought; a byte from $93 up,
/// which the player would take as a command past its table of them (and go astray), is taken as the voice's end;
/// and a voice that reads 65,536 bytes in a tick without coming to a note is taken to have come to its end (only a
/// broken file has one, which the player would read on through memory).
struct TimFollinPlayer: ~Copyable {
    /// The file, as the player has changed it, and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: noughts, after the file.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    /// The address the file is at, as UADE loads it: what its places are moved to, so that the file in memory is
    /// as it is in UADE's.
    static let base = 0x10000
    private let fileSize: Int
    /// The file as the player has moved its places, before any song has changed it.
    private let moved: [UInt8]
    /// Where the data begins (`begadr`, as an address), and the distance from the address the file was made for
    /// to where it is (`dx`).
    private let dataAt: Int
    private let distance: Int
    /// Whether the file is the game's own, with its code (`mode` nought).
    let withCode: Bool
    let songCount: Int
    private(set) var song = 0

    /// What the player keeps for each voice, in its 256 bytes from `tmp` (by its offset from `tmp` + $80; the
    /// bytes at -$0C and -$28, which only song 13 would look at, are never set, and so are left out).
    private struct Voice {
        /// The places, as addresses: of the stream (0), of a loop's start (16), of the voice's room for calls
        /// (32, as a count of longs into `calls`) and of the instrument (48); the period (72, a word).
        var stream = 0
        var loopStart = 0
        var callAt = 0
        var instrument = 0
        var period: UInt16 = 0
        /// The instrument's number (-4); whether the loop is to be told on the next tick (-8); whether the voice
        /// is playing (-16, its top bit); the volume (-20); the wave's count of ticks and every how many (-24,
        /// -28); the flags (-32); a length fixed (-44); whether the next note is not transposed (-48); the
        /// transposition (-52); a loop's count (-56).
        var instrumentNumber: UInt8 = 0
        var loopNext: UInt8 = 0
        var active: UInt8 = 0
        var volume: UInt8 = 0
        var waveCount: UInt8 = 0
        var waveSpeed: UInt8 = 0
        var flags: UInt8 = 0
        var fixedLength: UInt8 = 0
        var untransposed: UInt8 = 0
        var transpose: UInt8 = 0
        var loopCount: UInt8 = 0
        /// The envelope: the volume it starts at (-60), the part it starts in (-64), whether it is on (-68), its
        /// step (-80), its part (96), its count of ticks (100), every how many ticks it goes up and down (104, 108)
        /// and the volume it holds at (112).
        var envelopeStart: UInt8 = 0
        var envelopeFirst: UInt8 = 0
        var envelopeOn: UInt8 = 0
        var envelopeStep: UInt8 = 0
        var envelope: UInt8 = 0
        var envelopeCount: UInt8 = 0
        var attackDelay: UInt8 = 0
        var decayDelay: UInt8 = 0
        var sustain: UInt8 = 0
        /// The note's ticks to come (-76), the note (-92), and the slide's goal and step (-84, -88).
        var length: UInt8 = 0
        var note: UInt8 = 0
        var slideTarget: UInt8 = 0
        var slideSpeed: UInt8 = 0
        /// The trill: how far (-96), its counts after going up and down (-100, 124) and its count (-104).
        var trillInterval: UInt8 = 0
        var trillUp: UInt8 = 0
        var trillDown: UInt8 = 0
        var trillCount: UInt8 = 0
        /// The vibrato: its delay (116) and count of it (120), its step (-120), how many steps each way (-108)
        /// and their count (-112), and the way it starts (-72). Which way it and the trill are going (-116).
        var vibratoDelay: UInt8 = 0
        var vibratoDelayCount: UInt8 = 0
        var vibratoStep: UInt8 = 0
        var vibratoLength: UInt8 = 0
        var vibratoCount: UInt8 = 0
        var vibratoFirst: UInt8 = 0
        var direction: UInt8 = 0
        /// The wave: which way its width is going (88) and where its edge is (92).
        var waveDown: UInt8 = 0
        var waveAt: UInt8 = 0
        /// (Not the player's: whether the voice has jumped back since the song began or last came to its end.)
        var wentBack = false
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The player's room for the voices' calls (`L_12A2` to `L_12D2` and the long after them): four longs a voice.
    private var calls = InlineArray<17, Int>(repeating: 0)
    /// What Paula's period and volume registers were last given, for each voice.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    private var songLengths: [UInt64?] = []
    /// Whether every voice has come to its end, and that told.
    private var stopped = false

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to; and once the songs played through to
    /// find their lengths have taken four hours in all, the rest are too.
    private static let mostTicks = 50 * 60 * 60
    private static let mostTicksInAll = 4 * mostTicks
    /// The most bytes a voice reads in a tick before it is taken to have come to its end (see the type's comment).
    private static let mostRead = 1 << 16

    /// The player's table of periods (`Periodes`, $A16): its 97 periods, and as many words more as a note up to
    /// $7F reads of what follows them in its hunk (its last, past the hunk's end, nought).
    static let periodTable: [UInt16] = [
        0x0EEE, 0x0E18, 0x0D4D, 0x0C8E, 0x0BDA, 0x0B2F, 0x0A8F, 0x09F7, 0x0968, 0x08E1, 0x0861, 0x07E9,
        0x0777, 0x070C, 0x06A7, 0x0647, 0x05ED, 0x0598, 0x0547, 0x04FC, 0x04B4, 0x0470, 0x0431, 0x03F4,
        0x03BC, 0x0386, 0x0353, 0x0324, 0x02F6, 0x02CC, 0x02A4, 0x027E, 0x025A, 0x0238, 0x0218, 0x01FA,
        0x01DE, 0x01C3, 0x01AA, 0x0192, 0x017B, 0x0166, 0x0152, 0x013F, 0x012D, 0x011C, 0x010C, 0x00FD,
        0x00EF, 0x00E1, 0x00D5, 0x00C9, 0x00BE, 0x00B3, 0x00A9, 0x009F, 0x0096, 0x008E, 0x0086, 0x007F,
        0x0077, 0x0071, 0x006A, 0x0064, 0x005F, 0x0059, 0x0054, 0x0050, 0x004B, 0x0047, 0x0043, 0x003F,
        0x003C, 0x0038, 0x0035, 0x0032, 0x002F, 0x002D, 0x002A, 0x0028, 0x0026, 0x0024, 0x0022, 0x0020,
        0x001E, 0x001C, 0x001B, 0x0019, 0x0018, 0x0016, 0x0015, 0x0014, 0x0013, 0x0012, 0x0011, 0x0010,
        0x0008, 0x0A14, 0x1E28, 0x323C, 0x4650, 0x0A14, 0x1E28, 0x323C, 0x4650, 0x204D, 0x494B, 0x452F,
        0x5469, 0x6D20, 0x466F, 0x6C6C, 0x696E, 0x2C20, 0x696D, 0x7072, 0x6F76, 0x6564, 0x2062, 0x7920,
        0x414E, 0x4459, 0x2053, 0x494C, 0x5641, 0x2000, 0x0000, 0x0000,
    ]

    // MARK: - Reading

    /// A byte, word or long at an address, as the player reads it: of the file as it now is, and nought outside it.
    @inline(__always) private func byte(_ address: Int) -> UInt8 {
        let at = address &- Self.base
        return at >= 0 && at < fileSize ? memory[at] : 0
    }

    @inline(__always) private func word(_ address: Int) -> UInt16 { UInt16(byte(address)) << 8 | UInt16(byte(address &+ 1)) }
    @inline(__always) private func long(_ address: Int) -> Int {
        Int(Int32(bitPattern: UInt32(word(address)) << 16 | UInt32(word(address &+ 2))))
    }

    /// A byte written by the player, where it falls in the file (and nowhere else).
    @inline(__always) private func poke(_ address: Int, _ value: UInt8) {
        let at = address &- Self.base
        if at >= 0, at < fileSize { memory[at] = value }
    }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        at >= 0 && at < data.count - 1 ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> Int {
        Int(Int32(bitPattern: UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2))))
    }

    private static func put(_ data: inout [UInt8], _ at: Int, _ value: Int) {
        guard at >= 0, at < data.count - 3 else { return }
        let bits = UInt32(truncatingIfNeeded: value)
        for i in 0 ..< 4 { data[at + i] = UInt8(truncatingIfNeeded: bits >> UInt32(24 - 8 * i)) }
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Checky`): six `JMP`s, at every sixth byte from the start; or
    /// $1010 or $1012 (after a header of Atari's, $601A and 26 bytes more, or none) and the four longs after the
    /// one that follows it the same.
    static func isOne(_ data: [UInt8]) -> Bool {
        if word(data, 0) == 0x4EF9 {
            return data.count >= 0x432 && (1 ..< 6).allSatisfy { word(data, 6 * $0) == 0x4EF9 }
        }
        let at = word(data, 0) == 0x601A ? 28 : 0
        guard word(data, at) == 0x1010 || word(data, at) == 0x1012 else { return false }
        let first = long(data, at + 6)
        return data.count >= at + 2 + 0x194 && long(data, at + 10) == first && long(data, at + 14) == first
            && long(data, at + 18) == first
    }

    /// Reads the file and starts the song asked for (of `songCount`, nought the first).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        let isOne = Self.isOne(data)
        withCode = Self.word(data, 0) == 0x4EF9
        // `ReCalcMod` ($21A): where the data is, and the distance to move the places by.
        var begin = 0
        var distance: Int?
        if withCode {
            begin = 0x432
            distance = Self.base &- Self.long(data, 2)
        } else {
            begin = (Self.word(data, 0) == 0x601A ? 28 : 0) + 2
            var at = begin
            while at + 6 <= data.count {
                if Self.long(data, at) == Int(Int32(bitPattern: 0x8104_3202)), Self.word(data, at + 4) == 0x8F00 {
                    distance = Self.base &+ at &- Self.long(data, begin + 4)
                    break
                }
                at += 2
            }
        }
        dataAt = Self.base + begin
        self.distance = distance ?? 0
        var moved = data
        if let distance {
            // The places at the data's start, up to the first long whose top byte is not nought.
            var at = begin
            while at + 3 < moved.count, moved[at] == 0 {
                Self.put(&moved, at, Self.long(moved, at) &+ distance)
                at += 4
            }
            // The list of instruments whose word at 2 is a place, to a long whose top word is nought.
            at = begin + 0x194
            while at + 3 < moved.count, Self.word(moved, at) != 0 {
                let instrument = Self.long(moved, at) &+ distance
                Self.put(&moved, at, instrument)
                let inner = instrument &- Self.base &+ 2
                Self.put(&moved, inner, Self.long(moved, inner) &+ distance)
                at += 4
            }
        }
        self.moved = moved
        // `DTP_SubSongRange` ($1F0): as many songs as the file has `JMP`s among its first fifteen sixths, or one.
        var count = 0
        if withCode { for i in 0 ..< 15 where Self.word(data, 6 * i) == 0x4EF9 { count += 1 } }
        songCount = max(1, count)
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard isOne else { throw .malformed("not a Tim Follin file") }
        guard distance != nil else { throw .malformed("its song nought, by which its places are found, is missing") }

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
            // (The tick it came to its end in is the first of it again, or one not heard.)
            songLengths.append(endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil)
        }
        self.song = max(0, min(songCount - 1, song))
        lengthClocks = songLengths[self.song]
        start()
    }

    deinit { memory.deallocate() }

    /// The player's number for the song: DeliTracker's, from one.
    private var number: Int { (song + 1) & 15 }

    /// `InitSound` ($1A2) and `_init` ($292): the file as it was moved, and the song's voices at their starts.
    private mutating func start() {
        for i in 0 ..< fileSize { memory[i] = moved[i] }
        voices = .init(repeating: Voice())
        calls = .init(repeating: 0)
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        endings = 0
        stops = 0
        stopped = false
        let four = byte(dataAt &+ 0x144 &+ number) == 4
        // (Song 14's voices are not begun.)
        let on: UInt8 = number == 14 ? 0 : 0xFF
        for v in 0 ..< (four ? 4 : 3) {
            voices[v].stream = long(dataAt &+ 4 &+ 16 * number &+ 4 * v)
            voices[v].active = on
            voices[v].length = 1
        }
        for v in 0 ..< 4 { voices[v].callAt = 4 * v }
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        lengthClocks = songLengths[song]
        start()
    }

    // MARK: - Playing

    private mutating func writePeriod<Output: TFMXOutput>(_ v: Int, _ period: UInt16, _ output: inout Output) {
        periods[v] = period
        output.writePeriod(v, period)
    }

    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume
        output.writeVolume(v, volume)
    }

    /// Paula's location and length registers, told an address and a length: silence for an address outside the file.
    private func place<Output: TFMXOutput>(_ v: Int, _ address: Int, _ length: UInt16, _ output: inout Output) {
        let at = address &- Self.base
        output.takeNextBuffer(v, start: at >= 0 && at < fileSize ? at : silenceAt, length: length)
    }

    /// The address of the song's instrument of a number: from its table (whose place has been moved), moved.
    private func instrument(_ index: UInt8) -> Int {
        long(long(dataAt &+ 0x104 &+ 4 * number) &+ 4 * Int(index)) &+ distance
    }

    private static func period(_ note: UInt8) -> UInt16 { periodTable[Int(note & 0x7F)] }

    /// Runs the player for a tick (`Play`), telling `output` what Paula is to do, in the order the player tells
    /// her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        // `_play2` ($3DC): the loops asked for on the tick before, from the instrument the flags name.
        for v in 0 ..< 4 where voices[v].loopNext != 0 {
            voices[v].loopNext = 0
            let loop = instrument(voices[v].flags & 0x3F)
            place(v, loop &+ 0x32, word(loop), &output)
            output.on(v)
        }
        // `_play1` ($38E): each voice. (Its fade is never begun, as nothing sets its count.)
        for v in 0 ..< 4 { tick(v, &output) }
        // (Not the player's: the song's end, once every voice has come to its end or gone back.)
        var round = true, ended = true
        for v in 0 ..< 4 where Int8(bitPattern: voices[v].active) < 0 {
            ended = false
            if !voices[v].wentBack { round = false }
        }
        if !stopped, round {
            endings += 1
            if ended {
                stopped = true
                stops += 1
            }
            for v in 0 ..< 4 { voices[v].wentBack = false }
        }
        return 20
    }

    /// `L_E1E` ($4E6): a playing voice's tick.
    private mutating func tick<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        guard Int8(bitPattern: voices[v].active) < 0 else { return }
        // The wave of the first four instruments: its edge moved by a byte, up to $1E and down to 4, every so
        // many ticks.
        if Int8(bitPattern: voices[v].instrumentNumber) < 4 {
            voices[v].waveCount &-= 1
            if voices[v].waveCount == 0 {
                voices[v].waveCount = voices[v].waveSpeed
                let wave = voices[v].instrument &+ 0x32
                var at = voices[v].waveAt
                if voices[v].waveDown == 0 {
                    at &+= 1
                    if at == 0x1E { voices[v].waveDown = 0xFF }
                    poke(wave &+ Int(at), 0x80)
                } else {
                    at &-= 1
                    if at == 4 { voices[v].waveDown = 0 }
                    poke(wave &+ Int(at), 0)
                }
                voices[v].waveAt = at
            }
        }
        // The envelope: up by its step to $3F, every so many ticks; then down to where it holds.
        switch voices[v].envelope {
        case 0:
            voices[v].envelopeCount &-= 1
            if Int8(bitPattern: voices[v].envelopeCount) < 0 {
                voices[v].envelopeCount = voices[v].attackDelay
                voices[v].volume &+= voices[v].envelopeStep
                if voices[v].volume == 0x3F {
                    voices[v].envelope = 1
                    voices[v].envelopeCount = voices[v].decayDelay
                }
            }
        case 1:
            voices[v].envelopeCount &-= 1
            if Int8(bitPattern: voices[v].envelopeCount) < 0 {
                voices[v].envelopeCount = voices[v].decayDelay
                if voices[v].volume == voices[v].sustain {
                    voices[v].envelope = 2
                } else {
                    voices[v].volume &-= voices[v].envelopeStep
                    if Int8(bitPattern: voices[v].volume) < 0 { voices[v].envelope = 2 }
                }
            }
        default:
            break
        }
        // (`L_DE2`: its byte, as a word.)
        writeVolume(v, UInt16(voices[v].volume), &output)
        // The vibrato, once its delay is over; or else the trill; and the slide, but after a trill's step.
        var vibrato = false
        if voices[v].vibratoDelay != 0 {
            if voices[v].vibratoDelayCount == 0 {
                vibrato = true
            } else {
                voices[v].vibratoDelayCount &-= 1
                vibrato = voices[v].vibratoDelayCount == 0
            }
        }
        if vibrato {
            let step = UInt16(voices[v].vibratoStep)
            let period = voices[v].direction != 0 ? voices[v].period &+ step : voices[v].period &- step
            voices[v].period = period
            writePeriod(v, period, &output)
            voices[v].vibratoCount &-= 1
            if voices[v].vibratoCount == 0, voices[v].vibratoLength != 0 {
                voices[v].vibratoCount = voices[v].vibratoLength &<< 1
                voices[v].direction ^= 1
            }
            slide(v, &output)
        } else if trill(v) {
            // A step of the trill: up from the note, and back.
            voices[v].direction ^= 1
            var note = voices[v].note
            if voices[v].direction != 0 {
                note &+= voices[v].trillInterval
                voices[v].trillCount = voices[v].trillUp
            } else {
                note &-= voices[v].trillInterval
                voices[v].trillCount = voices[v].trillDown
            }
            setNote(v, note, &output)
        } else {
            slide(v, &output)
        }
        // The note's ticks: on its last but one the voice turned off, if the flags say so; after its last, the
        // stream read on.
        voices[v].length &-= 1
        if voices[v].length == 1 {
            if Int8(bitPattern: voices[v].flags) < 0 { output.off(v) }
            return
        }
        guard voices[v].length == 0 else { return }
        read(v, &output)
    }

    /// The trill's count, if it is going: true once it has come down to nought (`L_F5E`, $626).
    private mutating func trill(_ v: Int) -> Bool {
        guard voices[v].trillCount != 0 else { return false }
        voices[v].trillCount &-= 1
        return voices[v].trillCount == 0
    }

    /// `L_F98` ($660): a slide's step, to its goal and no further.
    private mutating func slide<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let speed = voices[v].slideSpeed, target = voices[v].slideTarget
        guard speed != 0 else { return }
        var note = voices[v].note
        guard note != target else { return }
        if note < target {
            note &+= speed
            if note >= target { note = target }
        } else {
            note &-= speed
            if note < target { note = target }
        }
        setNote(v, note, &output)
    }

    /// `L_FD0` ($698): the note and its period.
    private mutating func setNote<Output: TFMXOutput>(_ v: Int, _ note: UInt8, _ output: inout Output) {
        voices[v].note = note
        let period = Self.period(note)
        voices[v].period = period
        writePeriod(v, period, &output)
    }

    /// `L_101A` ($6E0): the voice's stream read to its next note, or its end.
    private mutating func read<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        var at = voices[v].stream
        var count = 0
        while true {
            count += 1
            let value = byte(at)
            at &+= 1
            if value != 0, value < 0x80 {
                play(v, value, &at, &output)
                return
            }
            if count > Self.mostRead {
                voices[v].active = 0
                return
            }
            switch value & 0x7F {
            case 0:
                break
            case 1:
                // An instrument.
                let number = byte(at)
                at &+= 1
                voices[v].instrumentNumber = number
                voices[v].instrument = instrument(number)
            case 2:
                // A call: its place, at the next even address, moved; where to return to kept in the voice's room.
                if at & 1 != 0 { at &+= 1 }
                let to = long(at) &+ distance
                at &+= 4
                let slot = voices[v].callAt
                // (Not the player's: a call made again before it has returned, as Puzznic's fifth song goes
                // round, is the voice going back.)
                for kept in max(0, 4 * v) ..< max(4 * v, min(slot, 17)) where calls[kept] == at { voices[v].wentBack = true }
                if slot >= 0, slot < 17 { calls[slot] = at }
                voices[v].callAt = slot &+ 1
                at = to
            case 3:
                // The call's return.
                let slot = voices[v].callAt &- 1
                voices[v].callAt = slot
                at = slot >= 0 && slot < 17 ? calls[slot] : 0
            case 4:
                voices[v].loopCount = byte(at)
                at &+= 1
                voices[v].loopStart = at
            case 5:
                voices[v].loopCount &-= 1
                if voices[v].loopCount != 0 { at = voices[v].loopStart }
            case 6:
                // The envelope: the volume it starts at and holds at (fours), its waits up and down, its first part.
                let first = byte(at)
                voices[v].envelopeStart = (first >> 4) &<< 2
                voices[v].sustain = (first & 15) &<< 2
                let second = byte(at &+ 1)
                voices[v].attackDelay = second >> 4
                voices[v].decayDelay = second & 15
                voices[v].envelopeFirst = byte(at &+ 2)
                at &+= 3
            case 7:
                voices[v].slideSpeed = byte(at)
                at &+= 1
            case 8:
                voices[v].trillInterval = byte(at)
                voices[v].trillUp = byte(at &+ 1)
                voices[v].trillDown = byte(at &+ 2)
                at &+= 3
            case 9:
                voices[v].vibratoDelay = byte(at)
                voices[v].vibratoStep = byte(at &+ 1)
                voices[v].vibratoLength = byte(at &+ 2)
                voices[v].vibratoFirst = byte(at &+ 3)
                at &+= 4
            case 10:
                voices[v].transpose = byte(at)
                at &+= 1
            case 11:
                voices[v].fixedLength = byte(at)
                at &+= 1
            case 12:
                voices[v].envelopeOn = byte(at)
                at &+= 1
            case 13:
                voices[v].flags = byte(at)
                at &+= 1
            case 14:
                // The wave begun again (`L_1226`, $942): its edge at 7 and going up, and the instrument's bytes 2 to
                // 33 made eight of $80 and 24 noughts.
                let speed = byte(at)
                at &+= 1
                voices[v].waveSpeed = speed
                voices[v].waveCount = speed
                voices[v].waveDown = 0
                voices[v].waveAt = 7
                let instrument = voices[v].instrument
                if instrument != 0 {
                    for i in 0 ..< 32 { poke(instrument &+ 2 &+ i, i < 8 ? 0x80 : 0) }
                }
            case 16:
                voices[v].envelopeStep = byte(at)
                at &+= 1
            case 17:
                voices[v].untransposed = 0xFF
            case 18:
                // A jump, to a place at the next even address, moved.
                let from = at &- 1
                if at & 1 != 0 { at &+= 1 }
                at = long(at) &+ distance
                if at <= from { voices[v].wentBack = true }
            default:
                // The voice's end (15): turned off, its volume nought. (Or a command past the player's table.)
                voices[v].active = 0
                output.off(v)
                writeVolume(v, 0, &output)
                return
            }
        }
    }

    /// `L_103E` ($74E): a note begun: its period, its instrument told Paula and the voice turned on, its length,
    /// and its trill, vibrato and envelope begun again.
    private mutating func play<Output: TFMXOutput>(_ v: Int, _ value: UInt8, _ at: inout Int, _ output: inout Output) {
        var note: UInt8 = 0
        if voices[v].untransposed != 0 {
            voices[v].untransposed = 0
        } else {
            note = voices[v].transpose
        }
        note &+= value
        if voices[v].slideSpeed != 0 {
            voices[v].slideTarget = note
            note = voices[v].note
        }
        voices[v].note = note
        let period = Self.period(note)
        voices[v].period = period
        // (`L_D8E`, $458.)
        let instrument = voices[v].instrument
        place(v, instrument &+ 0x32, word(instrument), &output)
        output.on(v)
        if voices[v].flags & 0x40 != 0 { voices[v].loopNext = 1 }
        writePeriod(v, period, &output)
        var length = voices[v].fixedLength
        if length == 0 {
            length = byte(at)
            at &+= 1
        }
        voices[v].length = length
        voices[v].stream = at
        voices[v].trillCount = voices[v].trillUp
        var direction: UInt8 = 0
        if voices[v].vibratoDelay != 0 {
            voices[v].vibratoDelayCount = voices[v].vibratoDelay
            voices[v].vibratoCount = voices[v].vibratoLength
            direction = voices[v].vibratoFirst
        }
        voices[v].direction = direction
        if voices[v].envelopeOn != 0 {
            voices[v].envelope = voices[v].envelopeFirst
            voices[v].envelopeCount = voices[v].envelope == 0 ? voices[v].attackDelay : voices[v].decayDelay
            voices[v].volume = voices[v].envelopeStart
        }
    }

    /// What the player last gave Paula's period register for the voice.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Tim Follin's music, played on Paula by `PaulaTickRenderer`.
extension TimFollinPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Tim Follin")
        info.author = "Tim Follin"
        info.detail = withCode ? "the game's own file, with its code" : "the music's data"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -21.9 dB.)
    var gain: Float { 0.35 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
