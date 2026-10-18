// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Michael Kleps' player of SidMon II, as DEFECT adapted it for EaglePlayer
// ("Sidmon-II Eagleplayer V1.8 (30 Aug 93)", carried by UADE as players/SIDMon2.0). The addresses
// given are of that player's code hunk.

/// SidMon II ("SIDMON II - THE MIDI VERSION", Michael Kleps' tracker of 1990, after Reinier van Vliet's
/// SidMon): in UnExoticA's collection, the music of Cobra, Cubulus and Ice Runner. A module is a song
/// of up to 256 positions, each giving each of the four voices a pattern and transposes for its notes
/// and instruments; patterns packed, a row in one to four bytes; instruments of 32 bytes, each of four
/// lists run on every tick (of waves, the samples the voice plays in turn; of notes, an arpeggio; and of
/// the vibrato's steps), a pitch bend and an envelope of attack, decay, sustain and release; and its
/// samples, any of which the player can keep turning over a byte at a time as it plays (the "negation"
/// of SidMon's synthesis), which is what makes its instruments sound as they do.
///
/// This is the player's own code, as it tells Paula what to do, tick by tick, and as it rewrites its
/// samples as it plays: what it tells her is the same as UADE's running of that code. It runs fifty
/// times a second, its row every sixth tick unless the song sets another speed.
///
/// It owns the memory Paula plays from: the module, and after it the room `PaulaTickRenderer` wants
/// (whose first bytes, nought, are silence). The places the player keeps as the Amiga's addresses
/// (where each sample is, which it writes into the module's table of samples) are places in that
/// memory here, the module being at nought. What the player changes of the module as it plays (its
/// samples, the table of samples, an instrument's attack) is put back as it was each time a song is
/// started.
struct SidMon2Player: ~Copyable {
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    var silenceAt: Int { fileSize }
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { fileSize + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// The module as it was loaded, to be put back when a song is started.
    private let original: [UInt8]

    // Where the module's parts are (the player's table at $462, found by `InitSound`, $32A): the
    // positions' patterns, note transposes and instrument transposes (four voices' lists, one after
    // the other), the instruments, the lists of waves, of arpeggios and of vibratos, the samples, the
    // patterns' places and the patterns.
    private let positions: Int, noteTransposes: Int, instrumentTransposes: Int
    private let instruments: Int, waveLists: Int, arpeggios: Int, vibratos: Int
    private let samples: Int, patternTable: Int, patterns: Int
    /// How many samples there are, less one (`$E6A`).
    private let lastSample: Int
    /// The last position (the module's byte 2), and the speed the song starts at (byte 3).
    private let lastPosition: UInt8
    private let startSpeed: UInt8

    /// One voice of the four, as the player keeps it (at $C9C, $CE6, $D30 and $D7A, 74 bytes each): each
    /// is named by what it is, and its offset there.
    private struct Voice {
        /// Where the voice's lists in the positions begin (0).
        var track = 0
        /// What a note starts Paula on: where the sample is and its length in words (4, 8).
        var sampleStart: UInt32 = 0
        var sampleLength: UInt16 = 0
        /// The period (10) and the volume, in 256ths (12).
        var period: Int16 = 0
        var volume: Int16 = 0
        /// The voice's bit in DMACON, and its registers' place after $DFF000 (14, 16).
        var dmaBit: UInt16 = 0
        var register: UInt16 = 0
        /// The envelope's phase, 4 attack to 1 release, nought done (18); the sustain's ticks so far (20).
        var phase: UInt16 = 0
        var sustain: UInt16 = 0
        /// The instrument, as a place in the memory (22).
        var instrument = 0
        /// Where Paula is to go on from when she comes to the end of what she plays, and for how long (26, 30).
        var loopStart: UInt32 = 0
        var loopLength: UInt16 = 0
        /// The note, transposed, with the arpeggio's first step (32).
        var note: Int16 = 0
        /// Each of the three lists' delays and places (35 and 37, 39 and 41, 43 and 45).
        var waveDelay: UInt8 = 0, waveAt: UInt8 = 0
        var arpeggioDelay: UInt8 = 0, arpeggioAt: UInt8 = 0
        var vibratoDelay: UInt8 = 0, vibratoAt: UInt8 = 0
        /// The row: its note (46, a word, transposed once it is read), instrument (49), effect (51) and
        /// the effect's parameter (53).
        var rowNote: UInt16 = 0
        var rowInstrument: UInt8 = 0
        var rowEffect: UInt8 = 0
        var rowParameter: UInt8 = 0
        /// The pitch bend's delay so far (55) and the change it makes to the period on every tick (58).
        var bendDelay: UInt8 = 0
        var bend: Int16 = 0
        /// The instrument transpose of the position (57).
        var instrumentTranspose: UInt8 = 0
        /// A slide to a note: its period and the step on every tick (60, 62).
        var slideTarget: Int16 = 0
        var slideStep: Int16 = 0
        /// The next row of the voice's pattern (64), and how many empty rows are still to come (69).
        var pattern = 0
        var emptyRows: UInt8 = 0
        /// The note transpose of the position (71).
        var noteTranspose: UInt8 = 0
        /// The sample number the voice was last told (73).
        var sampleNumber: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())

    // The song's place (`$E6E` on): its speed (1), position (2), row (3), tick (4), the length of a
    // pattern (5) and which of the arpeggio's three notes is played (6).
    private var speed: UInt8 = 0
    private var position: UInt8 = 0
    private var row: UInt8 = 0
    private var tick: UInt8 = 0
    private var patternLength: UInt8 = 64
    private var arpeggioStep: UInt8 = 0

    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    /// True once the song has come to its end, until the row that starts it again is played.
    private var ending = false
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// How long each tick is: the player is run by EaglePlayer's timer (it has an interrupt, `$492`, and
    /// starts no timer of its own), which UADE's runs on a CIA's timer from $376B, fifty times a second
    /// and a little less: 70,940 of Paula's clocks.
    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// The text the player's check looks for (`Check2`, $1EE): 28 bytes at 58.
    private static let mark: [UInt8] = Array("SIDMON II - THE MIDI VERSION".utf8)

    /// True for a file the player's check takes ($1EE): "SIDMON II - THE MIDI VERSION" at 58.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 58 + mark.count && data[58 ..< 58 + mark.count].elementsEqual(mark)
    }

    /// Reads the module, and starts its song (it has one: `song` is taken for that one, whatever it is).
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        original = data
        memoryCapacity = data.count + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        func long(_ at: Int) -> UInt32 {
            guard at >= 0, at + 4 <= data.count else { return 0 }
            return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        }
        // `InitSound` ($32A): each part after the last, by the lengths in the header, from the text at 58
        // (first the text's own length, then that of four bytes the player does not read).
        var parts = InlineArray<11, Int>(repeating: 0)
        var at: UInt32 = 58
        for i in 0 ..< 11 {
            at &+= long(6 + 4 * i)
            parts[i] = Int(at)
        }
        positions = parts[1]
        noteTransposes = parts[2]
        instrumentTransposes = parts[3]
        instruments = parts[4]
        waveLists = parts[5]
        arpeggios = parts[6]
        vibratos = parts[7]
        samples = parts[8]
        patternTable = parts[9]
        patterns = parts[10]
        lastPosition = data.count > 2 ? data[2] : 0
        startSpeed = data.count > 3 ? data[3] : 0
        let sampleWords = data.count > 5 ? Int(data[4]) << 8 | Int(data[5]) : 0
        lastSample = (sampleWords >> 6) - 1
        // (Refused only once it is all made, that it may be undone as a whole.) A module of no samples
        // the player would take for one of 65,536.
        guard Self.isOne(data) else { throw .malformed("not a SidMon II module") }
        guard lastSample >= 0 else { throw .malformed("SidMon II module of no samples") }
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

    // MARK: The memory, as the 68000 reads and writes it

    @inline(__always) private func byte(_ at: Int) -> UInt8 {
        at >= 0 && at < memoryCapacity ? memory[at] : 0
    }

    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }

    @inline(__always) private func setByte(_ at: Int, _ value: UInt8) {
        if at >= 0, at < fileSize { memory[at] = value }
    }

    @inline(__always) private func setWord(_ at: Int, _ value: UInt16) {
        setByte(at, UInt8(value >> 8))
        setByte(at + 1, UInt8(value & 0xFF))
    }

    @inline(__always) private func setLong(_ at: Int, _ value: UInt32) {
        setWord(at, UInt16(value >> 16))
        setWord(at + 2, UInt16(value & 0xFFFF))
    }

    /// A place the player keeps as a long, as a place in the memory.
    @inline(__always) private static func place(_ address: UInt32) -> Int { Int(Int32(bitPattern: address)) }

    /// The period of note `n` (a word with a sign), from the player's table ($DC4): nought, then the 72
    /// notes from $1680 down to $5F. Past the table the player reads its own variables, which hold
    /// nothing of the song for which a note is wanted (no module of UnExoticA's goes there): read as
    /// nought, which the player then plays at its highest period, $5F.
    private static func period(_ n: Int) -> Int16 {
        n >= 0 && n < SidMon2Tables.periods.count ? Int16(bitPattern: SidMon2Tables.periods[n]) : 0
    }

    // MARK: Starting

    /// The song from its beginning, as the player's `InitSound` ($32A) has it, on the module as it was
    /// loaded.
    private mutating func start() {
        for (i, b) in original.enumerated() { memory[i] = b }
        for i in fileSize ..< memoryCapacity { memory[i] = 0 }
        voices = InlineArray(repeating: Voice())
        for v in 0 ..< 4 {
            voices[v].dmaBit = 1 << UInt16(v)
            voices[v].register = 0xA0 + 0x10 * UInt16(v)
        }
        speed = startSpeed
        position = 0
        row = 0
        tick = 0
        patternLength = 64
        arpeggioStep = 0
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        ending = false
        endings = 0
        // Each voice's lists, one after the last, and its pattern of the first position.
        for v in 0 ..< 4 {
            voices[v].sampleNumber = 0
            voices[v].track = v * (Int(lastPosition) + 1)
            readPosition(v)
        }
        // The samples follow the patterns, from the end of the last in the table: the player reads it
        // through, 64 rows as the first voice reads them, and leaves what it read of the last row in
        // that voice's row (which its first ticks play the effect of).
        let last = patterns + Int(word(patterns - 2))
        var at = last
        for _ in 0 ..< 64 { readRow(0, &at) }
        voices[0].emptyRows = 0
        var sampleAt = (at + 1) & ~1
        for s in 0 ... lastSample {
            let entry = samples + 64 * s
            setLong(entry, UInt32(truncatingIfNeeded: sampleAt))
            sampleAt += 2 * Int(word(entry + 4))
        }
        // Each voice is given the instrument its position's transpose names, and that instrument's
        // first wave.
        for v in 0 ..< 4 {
            voices[v].volume = 0
            voices[v].waveDelay = 0
            voices[v].waveAt = 0
            voices[v].arpeggioDelay = 0
            voices[v].arpeggioAt = 0
            voices[v].vibratoDelay = 0
            voices[v].vibratoAt = 0
            voices[v].bendDelay = 0
            voices[v].bend = 0
            voices[v].slideStep = 0
            voices[v].phase = 4
            voices[v].sustain = 0
            voices[v].instrument = instruments + Int(voices[v].instrumentTranspose) << 5
            takeWave(v, list: Int(byte(voices[v].instrument)))
        }
    }

    /// The first wave of a list, as a note or the start of a song gives the voice ($422 and $7DA): the
    /// sample, where it begins, its length, and where its loop is and its length.
    private mutating func takeWave(_ v: Int, list: Int) {
        let number = byte(waveLists + list << 4)
        voices[v].sampleNumber = number
        let entry = samples + Int(number) << 6
        voices[v].sampleStart = long(entry)
        voices[v].sampleLength = word(entry + 4)
        voices[v].loopStart = long(entry) &+ 2 &* UInt32(word(entry + 6))
        voices[v].loopLength = word(entry + 8)
    }

    /// The voice's part of the position (`$6C2`): its pattern, and its note and instrument transposes.
    private mutating func readPosition(_ v: Int) {
        let at = voices[v].track + Int(position)
        let pattern = Int(byte(positions + at))
        voices[v].pattern = patterns + Int(word(patternTable + 2 * pattern))
        voices[v].noteTranspose = byte(noteTransposes + at)
        voices[v].instrumentTranspose = byte(instrumentTransposes + at)
        voices[v].emptyRows = 0
    }

    /// The voice's next row (`$726`), read from `at`: a note, its instrument and an effect and its
    /// parameter, any of them left out; or a count of empty rows to come.
    private mutating func readRow(_ v: Int, _ at: inout Int) {
        voices[v].rowNote = 0
        voices[v].rowInstrument = 0
        voices[v].rowEffect = 0
        voices[v].rowParameter = 0
        if voices[v].emptyRows != 0 {
            voices[v].emptyRows &-= 1
            return
        }
        func next() -> UInt8 {
            defer { at += 1 }
            return byte(at)
        }
        var b = next()
        if b == 0 {
            voices[v].rowEffect = next()
            voices[v].rowParameter = next()
            return
        }
        if b & 0x80 != 0 {
            voices[v].emptyRows = ~b
            return
        }
        if b >= 0x70 {
            voices[v].rowEffect = b
            voices[v].rowParameter = next()
            return
        }
        voices[v].rowNote = UInt16(b)
        b = next()
        if b & 0x80 != 0 {
            voices[v].emptyRows = ~b
            return
        }
        if b >= 0x70 {
            voices[v].rowEffect = b
            voices[v].rowParameter = next()
            return
        }
        voices[v].rowInstrument = b
        b = next()
        if b & 0x80 != 0 {
            voices[v].emptyRows = ~b
            return
        }
        voices[v].rowEffect = b
        voices[v].rowParameter = next()
    }

    var songCount: Int { 1 }
    var song: Int { 0 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    // MARK: Playing

    /// Runs the player for a tick (its interrupt, `$492`), telling `output` what Paula is to do, in the
    /// order the player tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        arpeggioStep &+= 1
        if arpeggioStep == 3 { arpeggioStep = 0 }
        tick &+= 1
        if Int8(bitPattern: tick) >= Int8(bitPattern: speed) {
            tick = 0
            arpeggioStep = 0
            if ending {
                ending = false
                endings += 1
            }
            // The row: each voice's read, the voices with a note turned off, their notes begun, the
            // samples turned over, and the voices turned on again; then each told where to go on from.
            var mask: UInt16 = 0
            for v in 0 ..< 4 {
                var at = voices[v].pattern
                readRow(v, &at)
                voices[v].pattern = at
                // (`$706`: the note is transposed in its low byte.)
                let note = voices[v].rowNote
                if note != 0 {
                    mask &+= voices[v].dmaBit
                    voices[v].rowNote = UInt16(UInt8(truncatingIfNeeded: note) &+ voices[v].noteTranspose)
                }
            }
            for v in 0 ..< 4 where mask & 1 << v != 0 { output.off(v) }
            for v in 0 ..< 4 { startNote(v, &output) }
            negate()
            for v in 0 ..< 4 where mask & 1 << v != 0 { output.on(v) }
            for v in 0 ..< 4 {
                output.takeNextBuffer(v, start: Self.place(voices[v].loopStart), length: voices[v].loopLength)
            }
            // The next row; after the pattern's last, the next position, and after the last position the
            // first, the song's end (`dtg_SongEnd`).
            row &+= 1
            if row == patternLength {
                row = 0
                if position == lastPosition {
                    position = 0xFF
                    ending = true
                }
                position &+= 1
                for v in 0 ..< 4 { readPosition(v) }
            }
        }
        for v in 0 ..< 4 { everyTick(v, &output) }
        if tick != 0 { negate() }
        return 20
    }

    /// `$78E`: the row's note begun, if it has one: its instrument's first wave (or the last
    /// instrument's, for a note without one), its envelope from the start, and Paula told where the
    /// sample is, its length and the note's period.
    private mutating func startNote<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        voices[v].bend = 0
        let note = voices[v].rowNote
        guard note != 0 else { return }
        voices[v].volume = 0
        voices[v].waveDelay = 0
        voices[v].waveAt = 0
        voices[v].arpeggioDelay = 0
        voices[v].arpeggioAt = 0
        voices[v].vibratoDelay = 0
        voices[v].vibratoAt = 0
        voices[v].bendDelay = 0
        voices[v].slideStep = 0
        voices[v].phase = 4
        voices[v].sustain = 0
        let instrument = voices[v].rowInstrument
        if instrument != 0 {
            let n = (instrument &- 1) &+ voices[v].instrumentTranspose
            voices[v].instrument = instruments + Int(n) << 5
            takeWave(v, list: Int(byte(voices[v].instrument)))
        }
        // The first step of the instrument's arpeggio is added to the note.
        let list = Int(byte(voices[v].instrument + 4))
        let step = Int16(Int8(bitPattern: byte(arpeggios + list << 4)))
        voices[v].note = Int16(bitPattern: note) &+ step
        voices[v].period = Self.period(Int(voices[v].note))
        output.takeNextBuffer(v, start: Self.place(voices[v].sampleStart), length: voices[v].sampleLength)
        periods[v] = UInt16(bitPattern: voices[v].period)
    }

    /// `$85C`, on every tick for each voice: its envelope and volume, its lists of waves, arpeggio and
    /// vibrato, the row's effect, the pitch bend and the slide to a note; then the period, bent and kept
    /// between $5F and $1680.
    private mutating func everyTick<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        envelope(v)
        waveList(v, &output)
        arpeggioList(v)
        effect(v)
        vibrato(v)
        pitchBend(v)
        slide(v)
        var period = voices[v].period &+ voices[v].bend
        if period <= 0x5F { period = 0x5F } else if period >= 0x1680 { period = 0x1680 }
        voices[v].period = period
        periods[v] = UInt16(bitPattern: period)
    }

    /// `$BE0` and `$BF6`: the envelope, from its attack to its release, and Paula given the volume.
    private mutating func envelope(_ v: Int) {
        let i = voices[v].instrument + 16
        if voices[v].instrument != 0, voices[v].phase != 0 {
            var volume = voices[v].volume
            switch voices[v].phase {
            case 4:
                let top = Int16(byte(i)), step = Int16(byte(i + 1))
                volume &+= step
                if top <= volume {
                    volume = top
                    voices[v].phase -= 1
                }
            case 3:
                let bottom = Int16(byte(i + 2)), step = Int16(byte(i + 3))
                if step == 0 {
                    voices[v].phase -= 1
                } else {
                    volume &-= step
                    if bottom >= volume {
                        volume = bottom
                        voices[v].phase -= 1
                    }
                }
            case 2:
                if UInt16(byte(i + 4)) == voices[v].sustain {
                    voices[v].phase -= 1
                } else {
                    voices[v].sustain &+= 1
                }
            case 1:
                let bottom = Int16(byte(i + 5)), step = Int16(byte(i + 6))
                if step == 0 {
                    voices[v].phase -= 1
                } else {
                    volume &-= step
                    if bottom >= volume {
                        volume = bottom
                        voices[v].phase -= 1
                    }
                }
            default: break
            }
            voices[v].volume = volume
        }
        // (`$28A`: the volume times EaglePlayer's for the voice, 64, over 64.)
        volumes[v] = UInt16(bitPattern: voices[v].volume) >> 2
    }

    /// One of an instrument's three lists, as the player steps through each (`$B64`, `$AFC`, `$AA2`):
    /// after its delay, a step every `speed` ticks, from the list's second entry to the entry `length`
    /// and round again from its first. Returns the entry's place in the list, or nil for no step.
    private static func step(length: UInt8, speed: UInt8, delay: UInt8, _ counter: inout UInt8, _ at: inout UInt8) -> Int? {
        guard length != 0 else { return nil }
        if counter != delay {
            counter &+= 1
            return nil
        }
        counter = delay &- speed
        if at == length { at = 0xFF }
        at &+= 1
        return Int(at)
    }

    /// `$B64`: the next of the instrument's waves, which Paula plays from its beginning when she comes to
    /// the end of what she plays (and is told so at once). An entry of $80 or more holds the list where it
    /// is.
    private mutating func waveList<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let i = voices[v].instrument
        guard i != 0 else { return }
        var counter = voices[v].waveDelay, place = voices[v].waveAt
        let stepped = Self.step(length: byte(i + 1), speed: byte(i + 2), delay: byte(i + 3), &counter, &place)
        voices[v].waveDelay = counter
        voices[v].waveAt = place
        guard let at = stepped else { return }
        let number = byte(waveLists + Int(byte(i)) << 4 + at)
        if number & 0x80 != 0 {
            voices[v].waveAt &-= 1
            return
        }
        voices[v].sampleNumber = number
        let entry = samples + Int(number) << 6
        voices[v].loopStart = long(entry)
        voices[v].loopLength = word(entry + 4)
        output.takeNextBuffer(v, start: Self.place(voices[v].loopStart), length: voices[v].loopLength)
    }

    /// `$AFC`: the next note of the instrument's arpeggio, played from the note.
    private mutating func arpeggioList(_ v: Int) {
        let i = voices[v].instrument
        guard i != 0 else { return }
        var counter = voices[v].arpeggioDelay, place = voices[v].arpeggioAt
        let stepped = Self.step(length: byte(i + 5), speed: byte(i + 6), delay: byte(i + 7), &counter, &place)
        voices[v].arpeggioDelay = counter
        voices[v].arpeggioAt = place
        guard let at = stepped else { return }
        let step = Int16(Int8(bitPattern: byte(arpeggios + Int(byte(i + 4)) << 4 + at)))
        voices[v].period = Self.period(Int(step &+ voices[v].note))
    }

    /// `$AA2`: the next step of the instrument's vibrato, added to the period.
    private mutating func vibrato(_ v: Int) {
        let i = voices[v].instrument
        guard i != 0 else { return }
        var counter = voices[v].vibratoDelay, place = voices[v].vibratoAt
        let stepped = Self.step(length: byte(i + 9), speed: byte(i + 10), delay: byte(i + 11), &counter, &place)
        voices[v].vibratoDelay = counter
        voices[v].vibratoAt = place
        guard let at = stepped else { return }
        voices[v].period &+= Int16(Int8(bitPattern: byte(vibratos + Int(byte(i + 8)) << 4 + at)))
    }

    /// `$8AC`: after its delay, the instrument's pitch bend added to the change made to the period on
    /// every tick.
    private mutating func pitchBend(_ v: Int) {
        let i = voices[v].instrument
        guard i != 0 else { return }
        let speed = Int16(Int8(bitPattern: byte(i + 12)))
        guard speed != 0 else { return }
        if byte(i + 13) != voices[v].bendDelay {
            voices[v].bendDelay &+= 1
            return
        }
        voices[v].bend &+= speed
    }

    /// `$922`: a slide of the period to the note the row's effect names (an effect below $70), by the
    /// parameter on every tick until it is there.
    private mutating func slide(_ v: Int) {
        let effect = voices[v].rowEffect
        if effect != 0, effect < 0x70, voices[v].rowParameter != 0 {
            voices[v].slideTarget = Self.period(Int(effect))
            let difference = voices[v].slideTarget &- voices[v].period
            guard difference != 0 else { return }
            let step = Int16(voices[v].rowParameter)
            voices[v].slideStep = difference > 0 ? step : 0 &- step
        }
        let step = voices[v].slideStep
        guard step != 0 else { return }
        voices[v].period &+= step
        if step > 0 ? voices[v].period >= voices[v].slideTarget : voices[v].period <= voices[v].slideTarget {
            voices[v].slideStep = 0
            voices[v].period = voices[v].slideTarget
        }
    }

    /// `$8D4`: the row's effect ($70 to $7F). Those below $75 are done on every tick but the row's own;
    /// the rest on every tick.
    private mutating func effect(_ v: Int) {
        let effect = voices[v].rowEffect
        guard effect >= 0x70 else { return }
        let parameter = voices[v].rowParameter
        switch effect & 0x0F {
        case _ where tick == 0 && effect & 0x0F < 5: return
        case 0:
            // `$98E`: an arpeggio of the note, the parameter's high four bits above it and its low four,
            // with the note itself between them.
            let steps: InlineArray<3, UInt8> = [parameter >> 4, 0, parameter & 0x0F]
            voices[v].period = Self.period(Int(steps[Int(arpeggioStep)]) + Int(voices[v].note))
        case 1:
            voices[v].bend = 0 &- Int16(parameter)
        case 2:
            voices[v].bend = Int16(parameter)
        case 3:
            // `$9DA`: the volume up, once the envelope is done, by four times the parameter, to no more
            // than $FF.
            guard voices[v].phase == 0 else { return }
            let volume = voices[v].volume &+ Int16(parameter) * 4
            voices[v].volume = volume >= 0x100 ? 0xFF : volume
        case 4:
            // `$A18`: and down, to no less than nought.
            guard voices[v].phase == 0 else { return }
            let volume = voices[v].volume &- Int16(parameter) * 4
            voices[v].volume = volume < 0 ? 0 : volume
        case 5:
            // `$A50`: the instrument's attack, its height and its step, set (in the module, for as long
            // as it plays).
            let i = voices[v].instrument
            guard i != 0 else { return }
            setByte(i + 16, parameter)
            setByte(i + 17, parameter)
        case 6:
            // `$A66`: the length of the patterns.
            patternLength = parameter
        case 0xC:
            // `$A6E`: the volume, given to Paula at once, and as the envelope's (four times it, no more
            // than $FF).
            volumes[v] = UInt16(parameter)
            let volume = Int16(parameter) * 4
            voices[v].volume = volume >= 0xFF ? 0xFF : volume
        case 0xF:
            // `$A92`: the speed, but for nought.
            let speed = parameter & 0x0F
            if speed != 0 { self.speed = speed }
        default:
            break
        }
    }

    /// `$608`, once a tick: the samples the voices play turned over a byte at a time. Each sample of the
    /// four the voices were last told (but once each, however many play it) that has a mode for it,
    /// every so many ticks (its speed, counted in five bits), has the byte at its place in a stretch of
    /// it turned over (each bit the other way), and its place moved on by its step: at the stretch's end
    /// back to its beginning (mode 1), or to its end from before its beginning (mode 2), or otherwise
    /// turned round. All of this is kept in the sample's entry in the module's table of samples.
    private mutating func negate() {
        var done = InlineArray<4, Int>(repeating: -1)
        for v in 0 ..< 4 {
            let entry = samples + Int(voices[v].sampleNumber) << 6
            done[v] = entry
            guard word(entry + 26) == 0 else { continue }
            setWord(entry + 26, 0xFFFF)
            let counter = word(entry + 24)
            if counter != 0 {
                setWord(entry + 24, (counter &- 1) & 0x1F)
                continue
            }
            setWord(entry + 24, word(entry + 14))
            let mode = word(entry + 16)
            guard mode != 0 else { continue }
            let first = 2 * UInt32(word(entry + 10))
            let last = 2 * UInt32(word(entry + 12)) &- 1
            var at = long(entry + 20)
            let place = Self.place(long(entry) &+ first &+ at)
            setByte(place, ~byte(place))
            let step = UInt32(bitPattern: Int32(Int16(bitPattern: word(entry + 18))))
            at &+= step
            if Int32(bitPattern: at) < 0 {
                if mode == 2 {
                    setLong(entry + 20, last)
                    continue
                }
            } else {
                if last >= at {
                    setLong(entry + 20, at)
                    continue
                }
                if mode == 1 {
                    setLong(entry + 20, 0)
                    continue
                }
            }
            // Turned round.
            setLong(entry + 20, at &- step)
            setWord(entry + 18, 0 &- word(entry + 18))
        }
        for v in 0 ..< 4 { setWord(done[v] + 26, 0) }
    }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as she takes what the player last gave her: seven bits, 64 or more
    /// being full.
    func volume(_ voice: Int) -> UInt16 { min(64, volumes[voice] & 0x7F) }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// SidMon II, played on Paula by `PaulaTickRenderer`.
extension SidMon2Player: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "SID2")
        info.detail = "SidMon 2.0"
        return info
    }

    /// SidMon II's music is louder on the Amiga's chip than ProTracker's is, by 3.6 dB in the middle of
    /// UnExoticA's twelve files, and is turned down by that (2026-10-18).
    var gain: Float { 0.30 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}

/// The tables of SidMon's players.
enum SidMon2Tables {
    /// The periods of SidMon II's player ($DC4): nought for no note, then six octaves from $1680.
    static let periods: [UInt16] = [
        0x0000, 0x1680, 0x1530, 0x1400, 0x12E0, 0x11D0, 0x10D0, 0x0FE0, 0x0F00, 0x0E20, 0x0D60, 0x0CA0,
        0x0BE8, 0x0B40, 0x0A98, 0x0A00, 0x0970, 0x08E8, 0x0868, 0x07F0, 0x0780, 0x0710, 0x06B0, 0x0650,
        0x05F4, 0x05A0, 0x054C, 0x0500, 0x04B8, 0x0474, 0x0434, 0x03F8, 0x03C0, 0x0388, 0x0358, 0x0328,
        0x02FA, 0x02D0, 0x02A6, 0x0280, 0x025C, 0x023A, 0x021A, 0x01FC, 0x01E0, 0x01C5, 0x01AC, 0x0194,
        0x017D, 0x0168, 0x0153, 0x0140, 0x012E, 0x011D, 0x010D, 0x00FE, 0x00F0, 0x00E2, 0x00D6, 0x00CA,
        0x00BE, 0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F, 0x0078, 0x0071, 0x006B, 0x0065,
        0x005F,
    ]
}
