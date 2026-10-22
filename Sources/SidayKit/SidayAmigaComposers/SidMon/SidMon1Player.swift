// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Reinier van Vliet's player of SidMon (1988), as it is in the files that
// carry it before their music, and as mld's EaglePlayer module for UADE ("SIDMon 1.0 player module for
// UADE (23 Dec. 2001)", carried by UADE as players/SIDMon1.0, whose source UADE carries as
// amigasrc/players/uade/sidmon1/SIDMon1.0.s) finds and runs it. The addresses given are of the
// player's code in the files, counted from its first instruction (`$0`): of the earlier player's
// (game_complete.sid), but where the later player's are said to be.

/// SidMon ("SID-MON BY R.v.VLIET (c) 1988"), Reinier van Vliet's tracker after the sound of the
/// Commodore 64's SID: in UnExoticA's collection, Ramon Braumuller's music for Venom Wing. Its music
/// was kept with its player before it, the player's code, its tables and its variables, and then the
/// module: four voices' lists of positions (a pattern and a transpose each), patterns of rows of five
/// bytes (a note, an instrument, an effect, its parameter, and how many rows it lasts), instruments of
/// 32 bytes (a list of waves, an arpeggio of sixteen notes, an envelope of attack, decay, sustain and
/// release, a vibrato from a wave, a pitch fall and a choice of tunings), waves of 32 bytes, and
/// samples. The player plays the instrument's waves in turn, 32 bytes over and over; a later player of
/// the two in the collection also mixes two of its waves into a third as it plays, and turns a byte of
/// its first wave over (to its negative) on every tick.
///
/// This is that player, as UADE runs it, tick by tick: what it tells Paula is what the player in the
/// file tells her, and the waves it rewrites are rewritten as it rewrites them. The player is not run:
/// its two versions in the collection are known by their code, and played as each plays (`Version`);
/// a file with another of its code is refused. It runs fifty times a second (UADE's timer, as
/// EaglePlayer's module has an interrupt and starts no timer of its own), its rows every so many ticks
/// that the song gives.
///
/// It owns the memory Paula plays from: the whole file, with its player, and after it the room
/// `PaulaTickRenderer` wants (whose first bytes, nought, are silence). The places the player keeps as
/// the Amiga's addresses are places in that memory here, the file being at nought; and what it changes
/// of the file as it plays (its waves, an instrument's attack, the song's speed and the length of its
/// patterns) is put back as it was each time the song is started.
struct SidMon1Player: ~Copyable {
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    var silenceAt: Int { fileSize }
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { fileSize + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    private let original: [UInt8]

    /// The two versions of the player found in UnExoticA's collection, by what each does: where its
    /// variables and tables are, from its first instruction, and what it does that the other does not.
    struct Version {
        /// Where the module is, from the player's first instruction (each part of it is found from the
        /// eleven long words before it), and where the player's routine of a tick begins.
        let module: Int
        let tick: Int
        /// The range of the player's code, from the routine of a tick on, that is checked to know it
        /// (one or two ranges, each from and to), and the check (FNV-1a, of 32 bits).
        let code: [(from: Int, to: Int)]
        let check: UInt32
        /// The tables of periods (each of 67 words, one for each tuning an instrument may choose).
        let periods: Int
        /// Where a sample with nothing to go on to is pointed: eight bytes of nought in the player.
        let empty: Int
        /// What a sample's loop is given as when it has none.
        let noLoop: UInt32
        /// True for the player that starts each voice's new pattern from its first row (clearing what
        /// was left of the row being played).
        let restartsRows: Bool
        /// Where the player keeps two mixings' counts and places, if it mixes waves; and the long word it
        /// adds to the song's speed on every tick, if it does.
        let mixing: Int?
        let speedChange: Int?
        /// True for the player that reads the keyboard after each voice.
        let readsKeys: Bool
        /// Where the player keeps whether the voices are to go on to their next position and to their
        /// first, and the ticks since the last row, if its setting up leaves them as they are in the file
        /// (the later player's does: it ends before them, at $F6, and the routine that would set them,
        /// $F8, is not called). Nil for the player that sets them (to no, no and the song's speed).
        let counters: Int?
        let name: String
    }

    /// Venom Wing's game_complete.sid: the routine of a tick at $118, its mixing ($B02) left out (its
    /// call is two NOPs, at $232).
    static let earlier = Version(module: 0x1172, tick: 0x118, code: [(0x118, 0xACE)], check: 0xE659_9101,
                                 periods: 0xD82, empty: 0xAFA, noLoop: 0x1869F, restartsRows: false,
                                 mixing: nil, speedChange: nil, readsKeys: false, counters: nil, name: "earlier")
    /// Venom Wing's title.sid and intro.sid: the routine of a tick at $16A, which mixes ($BDE) and turns
    /// a byte over ($BCC) on every tick, and adds to the speed what a sequence of keys sets, which none
    /// sets here ($DBA, nought; $884 reads the keyboard).
    static let later = Version(module: 0x125C, tick: 0x16A, code: [(0x16A, 0x29C), (0x2A2, 0xB98), (0xBCC, 0xDA6)],
                               check: 0x27E2_F434, periods: 0xE6C, empty: 0xBC4, noLoop: 0, restartsRows: true,
                               mixing: 0xDA6, speedChange: 0xDBA, readsKeys: true, counters: 0x1218, name: "later")
    static let versions = [earlier, later]

    let version: Version
    /// Where the player's first instruction is in the file (where its check found it), and the module.
    private let start: Int
    private let module: Int

    /// The module's parts, as places in the memory: each voice's positions, the instruments, the waves,
    /// the song's settings, the lists of waves, the rows, the patterns' places among the rows, and the
    /// samples' table.
    private let tracks: InlineArray<4, Int>
    private let instruments: Int, waves: Int, settings: Int, waveLists: Int, rows: Int, patterns: Int, samples: Int

    /// One voice of the four, as the player keeps it (32 bytes each, at $CF2 in the earlier player):
    /// each named by what it is, and its offset there.
    private struct Voice {
        /// Its place in its positions (0), its next row (4), its instrument (8).
        var track = 0
        var row = 0
        var instrument = 0
        /// The period (12), the note being slid to and the slide's speed (14, 15), the note, doubled
        /// (16), the arpeggio's place (17).
        var period: UInt16 = 0
        var slideNote: UInt8 = 0
        var slideSpeed: UInt8 = 0
        var note: UInt8 = 0
        var arpeggioAt: UInt8 = 0
        /// The envelope's phase (18: 0 attack, 2 decay, 4 sustain, 6 release, 8 done), the rows left of
        /// the row (19), the volume (20), the sustain's ticks left (21).
        var phase: UInt8 = 0
        var rowsLeft: UInt8 = 0
        var volume: UInt8 = 0
        var sustain: UInt8 = 0
        /// The slide's change to the period so far (22), the vibrato's place and delay (24, 25), the
        /// pitch fall so far (26).
        var slide: UInt16 = 0
        var vibratoAt: UInt8 = 0
        var vibratoDelay: UInt8 = 0
        var fall: UInt16 = 0
        /// The list of waves: the place in it, its number, the ticks left of the wave (28 to 30); and the
        /// sample's state (31): 1 just started, 2, then 3 once Paula has been told its loop; nought for
        /// a wave.
        var waveAt: UInt8 = 0
        var waveList: UInt8 = 0
        var waveTicks: UInt8 = 0
        var sample: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The ticks since the last row (`$1136`), the row of the pattern (`$CEA`), the position, from one
    /// (`$CEE`); whether the voices are to go on to their next position, and to their first (`$112E`,
    /// `$1132`).
    private var ticks: UInt32 = 0
    private var rowCount: UInt32 = 0
    private var position: UInt32 = 0
    private var nextPattern: UInt32 = 0
    private var firstPattern: UInt32 = 0
    /// Each voice's sample's loop, as it is to be told Paula (`$AD2`, eight bytes each).
    private var loops = InlineArray<4, (start: UInt32, length: UInt32)>(repeating: (0, 0))
    /// The two mixings' ticks left and places (the later player's `$DA6`).
    private var mixTicks = InlineArray<2, UInt32>(repeating: 0)
    private var mixAt = InlineArray<2, UInt32>(repeating: 0)
    /// What the player leaves in d1 as it is done with a voice, which a voice's next sample looks at.
    private var d1: UInt32 = 0

    /// What each of Paula's registers was last given: where and how long, the period and the volume.
    private var locations = InlineArray<4, UInt32>(repeating: 0)
    private var lengths = InlineArray<4, UInt16>(repeating: 0)
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var begun = false

    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// How long each tick is: UADE's timer (a CIA's, from $376B), fifty times a second and a little
    /// less: 70,940 of Paula's clocks.
    static let tickClocks = (0x376B + 1) * 5
    private static let mostTicks = 50 * 60 * 60
    /// The order the player takes the voices in: Paula's first, second, fourth and third.
    private static let order: InlineArray<4, Int> = [0, 1, 3, 2]

    /// Where the player's check (`SID1_Check` of EaglePlayer's module) finds the player's first
    /// instruction: at an even place, of as many as the file's length counts in its low sixteen bits
    /// (and one more), the start of the player's setting up: `lea` (41FA), and at 6, 12, 18 and 22
    /// FFD4 43FA, 2288 41FA, D1E8 FFD8 and 43FA. Nil for a file that is not one.
    static func playerStart(_ data: [UInt8]) -> Int? {
        func word(_ at: Int) -> UInt16 { UInt16(data[at]) << 8 | UInt16(data[at + 1]) }
        let count = data.count & 0xFFFF
        var at = 0
        for _ in 0 ... count {
            guard at + 0x18 <= data.count else { return nil }
            if word(at) == 0x41FA, word(at + 6) == 0xFFD4, word(at + 8) == 0x43FA, word(at + 12) == 0x2288,
               word(at + 14) == 0x41FA, word(at + 18) == 0xD1E8, word(at + 20) == 0xFFD8, word(at + 22) == 0x43FA {
                return at
            }
            at += 2
        }
        return nil
    }

    /// True for a file the player's check takes (see `playerStart`).
    static func isOne(_ data: [UInt8]) -> Bool { playerStart(data) != nil }

    /// The version of the player a file has, found where its check found its start; nil for one of
    /// another code.
    static func version(of data: [UInt8], at start: Int) -> Version? {
        versions.first { v in
            guard start + v.module <= data.count else { return false }
            var hash: UInt32 = 0x811C_9DC5
            for range in v.code {
                guard start + range.to <= data.count else { return false }
                for i in start + range.from ..< start + range.to { hash = (hash ^ UInt32(data[i])) &* 0x0100_0193 }
            }
            // (The module is where the setting up's first `lea` says.)
            let lea = start + 2 + Int(Int16(bitPattern: UInt16(data[start + 2]) << 8 | UInt16(data[start + 3])))
            return hash == v.check && lea == start + v.module
        }
    }

    /// Reads the file, and starts its song (it has one: `song` is taken for that one, whatever it is).
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        original = data
        memoryCapacity = data.count + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        let found = Self.playerStart(data)
        let start = found ?? 0
        self.start = start
        let known = found.flatMap { Self.version(of: data, at: $0) }
        let version = known ?? Self.earlier
        self.version = version
        let module = start + version.module
        self.module = module
        func long(_ at: Int) -> UInt32 {
            guard at >= 0, at + 4 <= data.count else { return 0 }
            return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        }
        func part(_ n: Int) -> Int { Self.place(UInt32(truncatingIfNeeded: module) &+ long(module - 44 + 4 * n)) }
        tracks = [part(0), part(1), part(2), part(3)]
        instruments = part(4)
        waves = part(5)
        settings = part(6)
        waveLists = part(7)
        rows = part(8)
        patterns = part(9)
        samples = part(10)
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard found != nil else { throw .malformed("not a SidMon module with its player") }
        guard known != nil else {
            throw .unsupported("SidMon module with a player of its own, not one of the two known")
        }
        reset()
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        reset()
    }

    deinit { memory.deallocate() }

    // MARK: The memory, as the 68000 reads and writes it

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < memoryCapacity ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }

    @inline(__always) private func setByte(_ at: Int, _ value: UInt8) {
        if at >= 0, at < fileSize { memory[at] = value }
    }

    /// A place the player keeps as a long word, as a place in the memory.
    @inline(__always) private static func place(_ address: UInt32) -> Int { Int(Int32(bitPattern: address)) }
    @inline(__always) private static func address(_ place: Int) -> UInt32 { UInt32(truncatingIfNeeded: place) }

    // MARK: Starting

    /// The player's setting up (`$0`): each voice at its first position, with the first row's
    /// instrument, its envelope done; the song from its first row (due at the second tick for the earlier
    /// player, and for the later when the ticks it keeps from the file pass the speed: in intro.sid,
    /// whose file has them a tick short of its speed, at the third); Paula's voices given 16 words to play, at no volume, and started. The two mixings'
    /// counts and places are as the file has them.
    private mutating func reset() {
        for (i, b) in original.enumerated() { memory[i] = b }
        for i in fileSize ..< memoryCapacity { memory[i] = 0 }
        for v in 0 ..< 4 {
            var voice = Voice()
            voice.track = tracks[v]
            voice.row = patternStart(voice.track)
            voice.instrument = instruments + Int(byte(voice.row + 1) &- 1) * 32
            voice.period = 0x9999
            voice.phase = 8
            voices[v] = voice
        }
        rowCount = 0xFFFF_FFFF
        position = 1
        if let counters = version.counters {
            nextPattern = long(start + counters)
            firstPattern = long(start + counters + 4)
            ticks = long(start + counters + 8)
        } else {
            nextPattern = 0
            firstPattern = 0
            ticks = long(settings + 0x20)
        }
        loops = .init(repeating: (0, 0))
        if let mixing = version.mixing {
            mixTicks = [long(start + mixing), long(start + mixing + 4)]
            mixAt = [long(start + mixing + 8), long(start + mixing + 12)]
        }
        d1 = 0
        locations = .init(repeating: Self.address(fileSize))
        lengths = .init(repeating: 0x10)
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        begun = false
        endings = 0
    }

    /// The first row of the pattern a voice's position names: the pattern's place among the rows, from
    /// the table of their places.
    private func patternStart(_ track: Int) -> Int {
        let n = long(track)
        return Self.place(Self.address(rows) &+ long(Self.place(Self.address(patterns) &+ (n << 2))))
    }

    var songCount: Int { 1 }

    mutating func select(song _: Int) throws(TuneError) { reset() }

    // MARK: Playing

    /// Runs the player for a tick (`$118` in the earlier player, `$16A` in the later), telling `output`
    /// what Paula is to do, in the order the player tells her. Returns the tick's length in
    /// milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if !begun {
            // (The setting up's: each voice 16 words long, from where Paula last was, and started.)
            begun = true
            for v in 0 ..< 4 {
                tell(v, &output)
                output.on(v)
            }
        }
        // (What is in d1 as the player is called is EaglePlayer's, taken as nought.)
        d1 = 0
        for i in 0 ..< 4 { voiceTick(Self.order[i], &output) }
        // The ticks since the last row, and the rows of the pattern; after its last, the next position,
        // and after the song's last, its first.
        if let change = version.speedChange { setLong(settings + 0x20, long(settings + 0x20) &+ long(start + change)) }
        ticks &+= 1
        if long(settings + 0x20) < ticks { ticks = 0 }
        nextPattern = 0
        firstPattern = 0
        if ticks == 0 {
            rowCount &+= 1
            if rowCount == long(settings + 0x18) {
                rowCount = 0
                nextPattern = 1
                position &+= 1
                if long(settings + 0x1C) <= position {
                    position = 1
                    firstPattern = 1
                }
            }
        }
        if version.mixing != nil {
            mix(0)
            mix(1)
            // `$BCC`: a byte of the first wave turned over, at the first mixing's place.
            let at = Self.place(Self.address(waves) &+ mixAt[0])
            setByte(at, 0 &- byte(at))
        }
        tellLoops(&output)
        return 20
    }

    @inline(__always) private mutating func setLong(_ at: Int, _ value: UInt32) {
        setByte(at, UInt8(value >> 24))
        setByte(at + 1, UInt8(value >> 16 & 0xFF))
        setByte(at + 2, UInt8(value >> 8 & 0xFF))
        setByte(at + 3, UInt8(value & 0xFF))
    }

    /// What one call of the voice's routine tells Paula, kept until its end (`$CDA` to `$CE6`): where
    /// she is to play from, whether she is to be given the period and the volume, and the length.
    private struct Told {
        var location: UInt32?
        var period: UInt16 = 0
        var volume: UInt16 = 0
        var length: UInt16 = 0
        /// True once a sample has been set to be played, which a list of waves leaves alone (`$ACE`).
        var sampled = false
    }

    /// The voice's routine (`$240`), once a tick: its next position and row when they are due, the
    /// row's note, instrument and effect; then its envelope, arpeggio, slide, vibrato, pitch fall and
    /// list of waves; and Paula told what has changed.
    private mutating func voiceTick<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        var told = Told()
        if ticks == 0 {
            if nextPattern == 1 {
                if version.restartsRows { voices[v].rowsLeft = 0 }
                voices[v].track += 6
                if firstPattern == 1 {
                    voices[v].track = tracks[v]
                    // (EaglePlayer's module tells UADE that the song has ended here: `SongEndPatch2`.)
                    if v == 0 { endings += 1 }
                }
                voices[v].row = patternStart(voices[v].track)
            }
            if voices[v].rowsLeft != 0 {
                voices[v].rowsLeft &-= 1
            } else {
                readRow(v, &told, &output)
            }
        }
        effects(v, &told)
        // `$7D0`: Paula told what has changed, of what is not nought; and all four voices on.
        if let location = told.location {
            locations[v] = location
            tell(v, &output)
        }
        if told.period != 0 { periods[v] = voices[v].period }
        if told.volume != 0 { volumes[v] = UInt16(bitPattern: Int16(bitPattern: told.volume) >> 2) }
        if told.length != 0 {
            lengths[v] = told.length
            tell(v, &output)
        }
        // (The later player reads the keyboard here, `$884`, leaving the place it reads it at in d1.)
        if version.readsKeys { d1 = 0xBF_EC01 }
        for w in 0 ..< 4 { output.on(w) }
    }

    /// `$2B2` on: the voice's row, and its instrument (a wave, or a sample, `$82C`) and note.
    private mutating func readRow<Output: TFMXOutput>(_ v: Int, _ told: inout Told, _ output: inout Output) {
        let row = voices[v].row
        let number = byte(row + 1)
        var toNote = false
        if number != 0 {
            let instrument = instruments + Int(number &- 1) << 5
            told.length = 0x10
            if voices[v].sample != 0 { output.off(v) }
            voices[v].sample = 0
            let wave = long(instrument)
            if UInt8(truncatingIfNeeded: wave) >= 0x10 {
                startSample(v, wave, &told, &output)
                // (Back from it, the player goes on to the note as for a row without an instrument if d1,
                // as the voice before left it, is 1: `$93C`.)
                toNote = d1 == 1
            }
            if !toNote {
                // `$30A`: the instrument's list of waves from its first.
                voices[v].waveAt = 0
                voices[v].waveList = UInt8(truncatingIfNeeded: wave)
                let list = Self.place(Self.address(waveLists) &+ ((wave & 0xFFFF_FF00 | UInt32(UInt8(truncatingIfNeeded: wave) &- 1)) << 4))
                voices[v].waveTicks = byte(list + 1)
                let first = Self.address(waves) &+ ((UInt32(byte(list)) &- 1) << 5)
                if !told.sampled { told.location = first }
                voices[v].instrument = instrument
                voices[v].phase = 0
                voices[v].fall = 0
                voices[v].slide = 0
                voices[v].rowsLeft = byte(row + 4)
            }
        } else if byte(row) != 0 {
            // `$36E`: a note without an instrument; a sample's played again from its start.
            voices[v].rowsLeft = byte(row + 4)
            if voices[v].sample != 0 { startSample(v, UInt32(voices[v].waveList), &told, &output) }
        }
        // `$396`: the note, if the row has one ($FF for none, which lasts as long as one).
        let note = byte(row)
        if note == 0xFF {
            voices[v].rowsLeft = byte(row + 4)
        } else if note != 0 {
            voices[v].rowsLeft = byte(row + 4)
            let doubled = UInt32(note &+ byte(voices[v].track + 5)) << 1
            let i = voices[v].instrument
            let table = start + version.periods + Int(byte(i + 30)) * 0x86
            let period = word(table + 2 + Int(doubled))
            voices[v].period = period
            voices[v].note = UInt8(truncatingIfNeeded: doubled)
            told.period = period
            voices[v].phase = 0
            voices[v].volume = 0
            voices[v].sustain = 0
            voices[v].slide = 0
            voices[v].fall = 0
            voices[v].slideSpeed = 0
            let effect = byte(row + 2), parameter = byte(row + 3)
            switch effect {
            case 0:
                // The instrument's attack, its step and its height, set (in the module, for as long as it
                // plays), if the parameter is not nought.
                if parameter != 0 {
                    setByte(i + 21, parameter)
                    setByte(i + 20, parameter)
                    voices[v].waveTicks = 0
                }
            case 2:
                // The song's speed (the low byte of its long word).
                setByte(settings + 0x23, parameter)
                voices[v].waveTicks = 0
            case 3:
                // The length of the patterns.
                setByte(settings + 0x1B, parameter)
                voices[v].waveTicks = 0
            default:
                // A slide to the note the effect names, transposed, at the parameter's speed.
                voices[v].slideNote = effect &+ byte(voices[v].track + 5)
                voices[v].slideSpeed = parameter
            }
            voices[v].vibratoDelay = byte(i + 29)
        }
        voices[v].row = row + 5
    }

    /// `$82C`: a sample (an instrument whose wave is $10 or more, the sample that less $10), started from
    /// its beginning: Paula told where it is and its length, its loop kept to be told her two ticks on
    /// (`tellLoops`).
    private mutating func startSample<Output: TFMXOutput>(_ v: Int, _ wave: UInt32, _ told: inout Told,
                                                          _ output: inout Output) {
        if voices[v].sample != 0 { output.off(v) }
        let table = Self.address(samples) &+ 4
        let entry = Self.place(table &+ ((wave &- 0x10) << 5))
        let base = table &+ long(samples)
        let location = base &+ long(entry)
        told.location = location
        told.sampled = true
        let loop = long(entry + 4) == version.noLoop ? 0xFFFF_FFFF : base &+ long(entry + 4)
        let end = long(entry + 8)
        loops[v] = (loop, UInt32(bitPattern: Int32(bitPattern: base &+ end &- loop) >> 1))
        told.length = UInt16(truncatingIfNeeded: Int32(bitPattern: end &- (location &- base)) >> 1)
        voices[v].sample = 1
    }

    /// `$4F2` on, on every tick: the envelope, the arpeggio, a slide, the vibrato, the pitch fall and the
    /// list of waves.
    private mutating func effects(_ v: Int, _ told: inout Told) {
        let i = voices[v].instrument
        // The envelope: in steps from nought to the attack's height, down to the decay's, held for the
        // sustain, and down to the release's. Paula is told the volume (only if it is not nought).
        let volume = UInt16(voices[v].volume)
        switch voices[v].phase {
        case 0:
            let step = UInt16(byte(i + 20)), top = UInt16(byte(i + 21))
            var now = volume &+ step
            if now > top {
                voices[v].phase &+= 2
                now = top
            }
            told.volume = now
            voices[v].volume = UInt8(truncatingIfNeeded: now)
        case 2:
            let step = UInt16(byte(i + 22)), bottom = UInt16(byte(i + 23))
            var now = volume &- step
            if now <= bottom || now >= 0xFF00 {
                voices[v].phase &+= 2
                now = bottom
                voices[v].sustain = byte(i + 24)
            }
            told.volume = now
            voices[v].volume = UInt8(truncatingIfNeeded: now)
        case 4:
            told.volume = volume
            voices[v].sustain &-= 1
            if voices[v].sustain == 0 { voices[v].phase &+= 2 }
        case 6:
            let step = UInt16(byte(i + 26)), bottom = UInt16(byte(i + 27))
            var now = volume &- step
            if now <= bottom || now > 0xFF00 {
                voices[v].phase &+= 2
                now = bottom
            }
            told.volume = now
            voices[v].volume = UInt8(truncatingIfNeeded: now)
        default:
            break
        }
        // `$5F0`: the arpeggio's next note, of sixteen, added to the note, both doubled, in a byte; its
        // period from the instrument's tuning.
        voices[v].arpeggioAt = (voices[v].arpeggioAt &+ 1) & 0x0F
        let arpeggio = byte(i + 4 + Int(voices[v].arpeggioAt))
        d1 = UInt32(arpeggio) << 1
        let index = Int(voices[v].note &+ (arpeggio &<< 1))
        let tuning = start + version.periods + Int(byte(i + 30)) * 0x86
        voices[v].period = word(tuning + index)
        told.period = voices[v].period
        // `$63C`: a slide to a note, faster on every tick, until it is there.
        if voices[v].slideSpeed != 0 {
            let step = UInt16(bitPattern: Int16(Int8(bitPattern: 0 &- voices[v].slideSpeed)))
            let target = word(tuning + Int(voices[v].slideNote) * 2)
            voices[v].slide &+= step
            voices[v].period &+= voices[v].slide
            let there = step & 0x8000 != 0 ? target >= voices[v].period : target <= voices[v].period
            if there {
                voices[v].note = voices[v].slideNote &<< 1
                voices[v].period = target
                voices[v].slide = 0
                voices[v].slideSpeed = 0
            }
        }
        // `$6DA`: the vibrato, after its delay: a step through the instrument's wave of it, a quarter of
        // each of its bytes added to the period.
        let vibrato = byte(i + 28)
        if vibrato != 0 {
            if voices[v].vibratoDelay != 0 {
                voices[v].vibratoDelay &-= 1
            } else {
                let wave = Self.place(Self.address(waves) &+ (UInt32(vibrato &- 1) << 5))
                voices[v].vibratoAt = (voices[v].vibratoAt &+ 1) & 0x1F
                let value = Int16(Int8(bitPattern: byte(wave + Int(voices[v].vibratoAt))))
                d1 = UInt32(bitPattern: Int32(value)) & 0xFFFF_0000 | UInt32(UInt16(bitPattern: value >> 2))
                voices[v].period &+= UInt16(bitPattern: value >> 2)
            }
        }
        // `$736`: the instrument's pitch fall, faster on every tick.
        voices[v].fall &+= 0 &- UInt16(bitPattern: Int16(Int8(bitPattern: byte(i + 31))))
        voices[v].period &+= voices[v].fall
        // `$74E`: the next wave of the list, when its ticks are done, for a voice not playing a sample.
        // An entry of $FF goes back to the place its next byte gives; the list's end is its sixteenth byte.
        guard voices[v].sample == 0 else { return }
        if voices[v].waveTicks != 0 {
            voices[v].waveTicks &-= 1
            return
        }
        guard voices[v].waveAt != 0x10 else { return }
        let list = Self.place(Self.address(waveLists) &+ (UInt32(voices[v].waveList &- 1) << 4)) + Int(voices[v].waveAt)
        if byte(list) == 0xFF {
            voices[v].waveAt = byte(list + 1) & 0xFE
            return
        }
        told.location = Self.address(waves) &+ (UInt32(byte(list) &- 1) << 5)
        voices[v].waveTicks = byte(list + 1)
        voices[v].waveAt &+= 2
    }

    /// Paula told where the voice is to play from and its length, as she keeps them: her registers of
    /// where hold no odd place (the low bit of AUDxLCL is not kept), and the player's samples may begin at
    /// odd places (as in title.sid).
    private func tell<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        output.takeNextBuffer(v, start: Self.place(locations[v]) & ~1, length: lengths[v])
    }

    /// `$94A`, after the voices: each voice's sample, two ticks after it was started, told its loop (or
    /// eight bytes of silence, if it has none).
    private mutating func tellLoops<Output: TFMXOutput>(_ output: inout Output) {
        for v in 0 ..< 4 {
            if voices[v].sample == 1 {
                voices[v].sample = 2
            } else if voices[v].sample == 2 {
                voices[v].sample = 3
                if loops[v].start == 0xFFFF_FFFF {
                    locations[v] = Self.address(start + version.empty)
                    lengths[v] = 2
                } else {
                    locations[v] = loops[v].start
                    lengths[v] = UInt16(truncatingIfNeeded: loops[v].length)
                }
                tell(v, &output)
            }
        }
    }

    /// The later player's mixing (`$BDE`): every so many ticks (the song's long words at $24 and $28, for
    /// the two; none for nought), the waves the song names (at 0 and 8, and at 4 and 12) mixed into a
    /// third (at 16, and 20), half of each, the second read round from a place that moves on by one at
    /// each mixing.
    private mutating func mix(_ n: Int) {
        let speed = long(settings + 0x24 + 4 * n)
        guard speed != 0 else { return }
        if mixTicks[n] == 0 {
            mixTicks[n] = speed
            func wave(_ at: Int) -> Int { Self.place(Self.address(waves) &+ ((long(settings + at) &- 1) << 5)) }
            let first = wave(4 * n), second = wave(8 + 4 * n)
            mixAt[n] = (mixAt[n] &+ 1) & 0x1F
            let into = wave(0x10 + 4 * n)
            var at = Int(mixAt[n])
            for i in stride(from: 31, through: 0, by: -1) {
                let a = UInt16(byte(first + i) &+ 0x80), b = UInt16(byte(second + at) &+ 0x80)
                setByte(into + i, UInt8(truncatingIfNeeded: (a + b) >> 1) &- 0x80)
                at = (at - 1) & 0x1F
            }
        }
        mixTicks[n] &-= 1
    }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as she takes what the player last gave her: seven bits, 64 or more
    /// being full.
    func volume(_ voice: Int) -> UInt16 { min(64, volumes[voice] & 0x7F) }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// SidMon, played on Paula by `PaulaTickRenderer`.
extension SidMon1Player: PaulaTickPlayer {
    var song: Int { 0 }
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "SID1")
        info.detail = "SidMon 1.0"
        return info
    }

    /// SidMon's music is louder on the Amiga's chip than ProTracker's is, by 5.6 dB in the middle of
    /// Venom Wing's three files, and is turned down by that (2026-10-18).
    var gain: Float { 0.24 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
