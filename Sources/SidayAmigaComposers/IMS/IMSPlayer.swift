// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Images Software's player (of 1990, from the game Hunt for Red October), as Wanted Team
// adapted it for EaglePlayer ("Images Music System player module V1.2 (18 Nov 2001)", carried by UADE
// as players/ImagesMusicSystem, whose source UADE also carries as amigasrc/players/wanted_team/
// ImagesMusicSystem/src/Images Music System_v3.asm). The addresses given are of that player's code.

import SidayChips
import SidayFoundation

/// Images Music System, Images Software's own tracker, in which Matthew Simmonds and Jolyon Myers
/// wrote the music of the games the company brought to the Amiga about 1990 (as Wanted Team's notes to
/// their player have it): a module much as a SoundTracker's, of 31 samples, an order of up to 128 patterns and 64 rows of four notes, but each note in three bytes,
/// a note of the player's own table of periods (63 for none), a sample and a command. 0 plays two
/// notes above the note in turn, on every tick; 1 and 2 slide the period, A the volume, on every tick
/// from the row's own; B jumps in the order and D to the next entry; C sets the volume, E the filter
/// and F the speed.
///
/// This is the player itself, as EaglePlayer's Images Music System runs it, tick by tick: what it
/// tells Paula is what that player tells her. It runs fifty times a second, its row every sixth tick
/// unless the song sets another speed. Each B in the module ends a song, and the next begins after it:
/// the songs are where they begin in the order (Wanted Team's, as the player module finds them; and
/// for Beast Busters, which has more than its jumps tell, theirs as they listed them).
///
/// It owns the memory Paula plays from: the module, and after it the room `PaulaTickRenderer` wants
/// (whose first bytes, nought, are silence). Places the player keeps as the Amiga's addresses are
/// places in that memory here, the module being at nought; and what of its own it reads past its
/// tables (a sample of a number past 31, a note past its table's end) is what it would read there,
/// from a copy of its tables and of what follows them (`tables`).
struct IMSPlayer: ~Copyable {
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    var silenceAt: Int { fileSize }
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { fileSize + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    let title: String
    /// The filter the power light shows, as the E command last set it (`PaulaTickRenderer` plays it).
    private(set) var lightFilter = false

    /// The player's tables, from its table of periods ($ECA) to the end of its code ($11D8): the 48
    /// periods, the samples to be started this row ($F2A, twelve bytes each: where, how long, where the
    /// loop is and how long), the 31 samples ($F5A, sixteen bytes each: those four, then the volume
    /// and a word of nought), Wanted Team's list of Beast Busters' songs ($114A) and the songs as found
    /// in the module ($1156). (What is past them, here, is nought.)
    private var tables = InlineArray<782, UInt8>(repeating: 0)
    private static let startsAt = 0x60, samplesAt = 0x90, beastAt = 0x280, songsAt = 0x28C

    private static let periods: [UInt16] = [
        0x6B0, 0x650, 0x5F4, 0x5A0, 0x54C, 0x500, 0x4B8, 0x474, 0x434, 0x3F8, 0x3C0, 0x38A,
        0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC, 0x1E0, 0x1C5,
        0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0, 0x0E2,
        0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0x078, 0x071,
    ]
    private static let beastBusters: [UInt8] = [0, 4, 5, 7, 0x16, 0x17, 0x1F, 0x23, 0x25, 0x26, 0x29, 0]

    /// Where the module's songs begin, as places in `tables`, and how many there are.
    private var songTable = 0
    let songCount: Int
    private(set) var song = 0

    /// A voice's part of the player's variables (`lbL00075C` and the three after it, 28 bytes each),
    /// named by what they are.
    private struct Voice {
        var instrument: UInt16 = 0
        var note: UInt16 = 0
        var period: UInt16 = 0
        var volume: UInt16 = 0
        /// The volume a C command gave the row, or $FFFF for none.
        var givenVolume: UInt16 = 0
        /// The volume's slide: 1 up, $FFFF down, 0 none; and by how much.
        var volumeSlide: UInt16 = 0
        var volumeStep: UInt16 = 0
        var slide: UInt16 = 0
        /// The arpeggio, when not nought: the two notes above the note, the one played next last.
        var arpeggio: UInt16 = 0
        var arpeggioNotes: UInt32 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    // The rest of the player's variables (`lbL000734`, $E32).
    private var orderAt = 952, patternsAt = 1084
    private var rowAt = 0
    private var position: UInt16 = 0
    private var length: UInt16 = 0
    private var restart: UInt16 = 0
    private var row: UInt16 = 0
    private var speed: UInt16 = 6
    private var countdown: UInt16 = 0
    /// The voices with a note this row (as Paula's DMA bits), and where the next of them goes in the
    /// list of samples to be started.
    private var starting: UInt16 = 0
    private var startAt = startsAt
    private var jump: UInt16 = 0
    private var jumpTo: UInt16 = 0xFFFF
    /// What each of Paula's volume and period registers was last given.
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periods = InlineArray<4, UInt16>(repeating: 0)

    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// How long each tick is: a frame, as Images Software ran the player, from the frame's interrupt (the
    /// replay's own handler at $6C, which tests INTREQR for the frame's bit before it plays: Wanted Team's
    /// source of it, `Images Music System_v3.asm`). EaglePlayer's has an interrupt and starts none of its
    /// own, and so in UADE it is run by a CIA's timer from $376B, its count for fifty a second (score.s,
    /// `cia_timer_base_value`), 70,940 of Paula's clocks apart, a little faster.
    static let tickClocks = TFMXTiming.frame
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// True for a file the player's check takes (`Check2`, $420): more than 1852 bytes; the samples'
    /// place (the long at 1080) less than 64K, and 1084 and a whole number of patterns of 768 bytes;
    /// an order of fewer than 128 entries (the byte at 950), of which, and of the one after them, none
    /// is 128 or more and the highest is the last pattern.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count > 1852, data[1080] == 0, data[1081] == 0 else { return false }
        let samples = Int(data[1082]) << 8 | Int(data[1083])
        guard samples >= 1084, (samples - 1084) % 768 == 0 else { return false }
        let patterns = (samples - 1084) / 768
        let length = Int(data[950])
        guard length < 0x80 else { return false }
        var highest = 0
        for i in 0 ... length {
            let entry = Int(data[952 + i])
            guard entry < 0x80 else { return false }
            highest = max(highest, entry)
        }
        return highest == patterns - 1
    }

    /// Reads the module and starts its song `song` (counting from nought).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        fileSize = data.count
        memoryCapacity = data.count + 0x20000 + Self.mixingSpace
        let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, byte) in data.enumerated() { memory[i] = byte }
        self.memory = memory
        let capacity = memoryCapacity
        func byte(_ at: Int) -> UInt8 { at >= 0 && at < capacity ? memory[at] : 0 }
        func word(_ at: Int) -> Int { Int(byte(at)) << 8 | Int(byte(at + 1)) }

        // (What is not played is refused only once all is made, that it may be undone as a whole.)
        var refusal: TuneError?
        // As `InitPlayer` ($472): the samples must be in the file, all of them.
        let samplesAt = word(1082)
        var sampleWords = 0
        for s in 0 ..< 31 { sampleWords += word(42 + 30 * s) }
        if !Self.isOne(data) {
            refusal = .malformed("not an Images Music System module")
        } else if samplesAt + 2 * sampleWords > data.count {
            refusal = .malformed("its samples run past the end of the file")
        } else if data[950] == 0 {
            // (An order of no entries the player would read the rest of its memory as.)
            refusal = .malformed("its order is empty")
        }

        var name = String.UnicodeScalarView()
        for byte in data.prefix(20) where byte != 0 { name.append(Unicode.Scalar(byte >= 0x20 && byte <= 0x7E ? byte : 0x20)) }
        title = String(name).trimmed()

        // Wanted Team's mend of Shadow Dancer's tune am11 (their "unused voice fix", $4C6): the note on
        // its first row's fourth voice, a voice the tune does not otherwise use, is taken out.
        let calculated = samplesAt + 2 * sampleWords
        if calculated == 30652, byte(1092) == 0x00, byte(1093) == 0x0C, byte(1094) == 0x7C, byte(1095) == 0x15 {
            memory[1093] = 0x3F
            memory[1094] = 0
            memory[1095] = 0
        }

        for (i, period) in Self.periods.enumerated() {
            tables[2 * i] = UInt8(period >> 8)
            tables[2 * i + 1] = UInt8(period & 0xFF)
        }
        for (i, byte) in Self.beastBusters.enumerated() { tables[Self.beastAt + i] = byte }

        // The songs (`InitPlayer`, from $4FC): one after each entry of the order whose pattern has a B
        // in it, the first at the start; a module with no B has one. Beast Busters' are Wanted Team's.
        var count = 0, entries = 0
        for i in 0 ..< Int(byte(950)) {
            let pattern = 1084 + Int(byte(952 + i)) * 768
            var cell = pattern + 1
            var found = false
            while cell < pattern + 768 {
                if cell < data.count, byte(cell) & 0x0F == 0x0B {
                    found = true
                    break
                }
                cell += 3
            }
            entries += 1
            if found {
                if Self.songsAt + 1 + count < 782 { tables[Self.songsAt + 1 + count] = UInt8(truncatingIfNeeded: entries) }
                count += 1
            }
        }
        songTable = Self.songsAt
        if calculated == 41630 {
            count = 11
            songTable = Self.beastAt
        }
        songCount = max(1, count)

        if let refusal { throw refusal }
        begin(song)
    }

    deinit { memory.deallocate() }

    private func byte(_ at: Int) -> UInt8 { at >= 0 && at < memoryCapacity ? memory[at] : 0 }
    private func table(_ at: Int) -> UInt8 { at >= 0 && at < 782 ? tables[at] : 0 }
    private func tableWord(_ at: Int) -> UInt16 { UInt16(table(at)) << 8 | UInt16(table(at + 1)) }
    private func tableLong(_ at: Int) -> UInt32 { UInt32(tableWord(at)) << 16 | UInt32(tableWord(at + 2)) }

    private mutating func setTable(_ at: Int, word: UInt16) {
        tables[at] = UInt8(word >> 8)
        tables[at + 1] = UInt8(word & 0xFF)
    }

    private mutating func setTable(_ at: Int, long: UInt32) {
        setTable(at, word: UInt16(long >> 16))
        setTable(at + 2, word: UInt16(truncatingIfNeeded: long))
    }

    /// Starts song `song` (counting from nought; one past the last is the first), as a player newly
    /// loaded would; and finds how long it is.
    mutating func select(song: Int) throws(TuneError) { begin(song) }

    private mutating func begin(_ song: Int) {
        self.song = song >= 0 && song < songCount ? song : 0
        initialise()
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (It comes to its end at a row, whose jump is made for the next row, which is the first of it
        // again: as many ticks on as are left to count down.)
        lengthClocks = endings > 0 ? UInt64(ticks + Int(countdown)) * UInt64(Self.tickClocks) : nil
        initialise()
    }

    /// The player's `Init` ($7C0), for the song chosen: the samples' table made, the song set to its
    /// first entry of the order, and Paula's voices turned off and quiet. (The voices' own variables
    /// the player leaves as they were, from a song played before: here they are as a player newly
    /// loaded has them.)
    private mutating func initialise() {
        voices = .init(repeating: Voice())
        lightFilter = false
        for i in Self.startsAt ..< Self.beastAt { tables[i] = 0 }
        var at = UInt32(memory[1082]) << 8 | UInt32(memory[1083])
        for s in 0 ..< 31 {
            let header = 42 + 30 * s
            func word(_ i: Int) -> UInt16 { UInt16(memory[header + i]) << 8 | UInt16(memory[header + i + 1]) }
            let entry = Self.samplesAt + 16 * s
            setTable(entry, long: at)
            setTable(entry + 4, word: word(0))
            // (Lengths are doubled in a word, as the player doubles them.)
            setTable(entry + 6, long: at &+ UInt32(word(4) &<< 1))
            setTable(entry + 10, word: word(6))
            setTable(entry + 12, word: word(2))
            at = at &+ UInt32(word(0) &<< 1)
        }
        length = UInt16(memory[950])
        restart = UInt16(memory[951])
        row = 0
        speed = 6
        countdown = 0
        position = UInt16(table(songTable + song))
        rowAt = patternsAt + Self.patternPlace(byte(orderAt + Int(Int16(bitPattern: position))))
        jump = 0
        jumpTo = 0xFFFF
        starting = 0
        startAt = Self.startsAt
        volumes = .init(repeating: 0)
        periods = .init(repeating: 0)
        endings = 0
    }

    /// Where a pattern is among the patterns: 768 bytes each, in a word.
    private static func patternPlace(_ pattern: UInt8) -> Int { Int((UInt16(pattern) &* 3) &<< 8) }

    /// Runs the player for a tick (`Play`, $8CC), telling `output` what Paula is to do, in the order
    /// the player tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if countdown == 0 {
            startAt = Self.startsAt
            starting = 0
            for v in 0 ..< 4 { readNote(v, at: rowAt + 3 * v) }
            startNotes(&output)
            rowAt += 12
            countdown = speed
            // A jump (B, or D's to the next entry) is made after the row; a B tells EaglePlayer the song
            // has come to its end (`dtg_SongEnd`, $942), as does coming past the order's last entry.
            var next: UInt16?
            if jump != 0 {
                jump = 0
                if jumpTo & 0x8000 == 0 {
                    next = jumpTo
                    jumpTo = 0xFFFF
                    endings += 1
                } else {
                    next = nextEntry()
                }
            } else {
                row &+= 1
                if row == 0x40 { next = nextEntry() }
            }
            if let next { setPosition(next) }
        }
        tickEffects()
        countdown &-= 1
        return 20
    }

    /// The order's next entry, or after its last the restart's, the song having come to its end.
    private mutating func nextEntry() -> UInt16 {
        let next = position &+ 1
        if next != length { return next }
        endings += 1
        return restart
    }

    private mutating func setPosition(_ entry: UInt16) {
        position = entry
        rowAt = patternsAt + Self.patternPlace(byte(orderAt + Int(Int16(bitPattern: entry))))
        row = 0
    }

    /// `lbC0004B4` ($BAE): a voice's part of the row. Its sample, if it gives one (kept for the notes
    /// after it); its command; its note, if it has one (63 for none, the whole byte, so that a sample
    /// of sixteen or more with note 63 still plays it); and its volume set, note or none.
    private mutating func readNote(_ v: Int, at: Int) {
        let b0 = byte(at), b1 = byte(at + 1), b2 = byte(at + 2)
        let instrument = UInt16(b1 >> 4 | (b0 & 0xC0) >> 2)
        if instrument != 0 { voices[v].instrument = instrument }
        voices[v].slide = 0
        voices[v].arpeggio = 0
        voices[v].volumeSlide = 0
        let command = b1 & 0x0F, parameter = UInt16(b2)
        if command == 0x0F {
            // (Which leaves the volume the row before gave, if it gave one, to this row's note.)
            speed = parameter
        } else {
            voices[v].givenVolume = 0xFFFF
            switch command {
            case 0x0C:
                voices[v].givenVolume = min(parameter, 0x40)
                voices[v].volume = voices[v].givenVolume
            case 0x0D: jump = 0xFFFF
            case 0x0B:
                jump = 0xFFFF
                jumpTo = parameter
            // The filter, through the power light ($C3E): on for an even parameter (`BCLR #1,$BFE001`),
            // off for an odd one.
            case 0x0E: lightFilter = parameter & 1 == 0
            case 0x01: voices[v].slide = 0 &- parameter
            case 0x02: voices[v].slide = parameter
            case 0x0A:
                voices[v].volumeStep = parameter & 0x0F | parameter >> 4
                voices[v].volumeSlide = parameter < 0x10 ? 0xFFFF : 1
            case 0x00 where parameter != 0:
                voices[v].arpeggioNotes = UInt32(parameter & 0x0F) << 16 | UInt32(parameter >> 4)
                voices[v].arpeggio = 0xFFFF
            default: break
            }
        }
        if b0 != 0x3F { playNote(v, b0 & 0x3F) }
        // `ChangeVolume` ($5F8): seven bits of it, times EaglePlayer's volume, 64, over 64.
        volumes[v] = voices[v].volume & 0x7F
    }

    /// `lbC0005E0` ($CE0): a note. Its period from the table, the volume its sample has unless the row
    /// gave one, and the sample put on the list to be started.
    private mutating func playNote(_ v: Int, _ note: UInt8) {
        voices[v].note = UInt16(note)
        let period = tableWord(2 * Int(note))
        voices[v].period = period
        // (Sample nought, a voice's before it has been given one, is 64K on in the player's memory,
        // its own being of its number less one, in a word, times sixteen.)
        let entry = Self.samplesAt + Int((voices[v].instrument &- 1) &<< 4)
        var volume = tableWord(entry + 12)
        if voices[v].givenVolume & 0x8000 == 0 { volume = voices[v].givenVolume }
        voices[v].volume = volume
        starting |= 1 << v
        for i in 0 ..< 12 { tables[startAt + i] = table(entry + i) }
        startAt += 12
        periods[v] = period
    }

    /// `lbC000638` ($D3E): the voices with a note this row turned off, told where their samples are,
    /// turned on again after waiting for Paula (`dtg_WaitAudioDMA`), and, after waiting again, told
    /// where their loops are, for when they come to their samples' ends.
    private mutating func startNotes<Output: TFMXOutput>(_ output: inout Output) {
        for v in 0 ..< 4 where starting & 1 << v != 0 { output.off(v) }
        var at = Self.startsAt
        for v in 0 ..< 4 where starting & 1 << v != 0 {
            output.takeNextBuffer(v, start: Int(tableLong(at)), length: tableWord(at + 4))
            at += 12
        }
        for v in 0 ..< 4 where starting & 1 << v != 0 { output.on(v) }
        at = Self.startsAt + 6
        for v in 0 ..< 4 where starting & 1 << v != 0 {
            output.takeNextBuffer(v, start: Int(tableLong(at)), length: tableWord(at + 4))
            at += 12
        }
    }

    /// What is done on every tick, the row's own too (from $98E): each voice's arpeggio, then its
    /// volume's slide, then its period's.
    private mutating func tickEffects() {
        for v in 0 ..< 4 where voices[v].arpeggio != 0 {
            // The two notes in turn: the one in the lower word, which is then swapped with the other.
            let notes = voices[v].arpeggioNotes
            voices[v].arpeggioNotes = notes << 16 | notes >> 16
            let index = (UInt16(truncatingIfNeeded: notes) &+ voices[v].note) &<< 1
            voices[v].period = tableWord(Int(Int16(bitPattern: index)))
        }
        for v in 0 ..< 4 where voices[v].volumeSlide != 0 {
            var volume: UInt16
            if voices[v].volumeSlide & 0x8000 == 0 {
                volume = voices[v].volume &+ voices[v].volumeStep
                if Int16(bitPattern: volume) > 0x40 { volume = 0x40 }
            } else {
                volume = voices[v].volume &- voices[v].volumeStep
                if Int16(bitPattern: volume) < 0 { volume = 0 }
            }
            voices[v].volume = volume
            // (`SetVoice1` to 4, from $604: the volume times 64 over 64, in a word, all of it.)
            volumes[v] = UInt16(truncatingIfNeeded: UInt32(volume) &* 64) >> 6
        }
        for v in 0 ..< 4 {
            voices[v].period &+= voices[v].slide
            periods[v] = voices[v].period
        }
    }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as she takes what the player last gave her: seven bits, 64 or
    /// more being full.
    func volume(_ voice: Int) -> UInt16 { min(64, volumes[voice] & 0x7F) }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Images Music System, played on Paula by `PaulaTickRenderer`.
extension IMSPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "IMS")
        info.title = title
        info.detail = "Images Music System"
        return info
    }

    /// Images Music System's modules are louder on the Amiga's chip than ProTracker's are, by 7.8 dB in
    /// the middle of UnExoticA's 12, and are turned down by that (2026-10-18).
    var gain: Float { 0.19 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
