// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the EaglePlayer "Action Amics SoundTools V0.1 player module V1.1 (05 April 93)" ("Michael Kleps ???,
// Testversion by Turbo/IFT & Eagleeye/DEFECT"), carried by UADE as players/ActionAmics, whose source is not given:
// what it does is read from its code, and the addresses given are of its hunk in UADE's file.

import SidayChips
import SidayFoundation

/// The music of Action Amics' Sound Tool, as Dyna Blaster carries it (Eike Steffen's): a file that says "ACTIONAMICS
/// SOUND TOOL" at byte 62, after a word and the lengths of fifteen parts, which follow from there one after another:
/// the name, the file's length, three tables of four voices' 68 bytes for each place in the song (the pattern, a
/// transposition and an instrument's offset), the instruments (32 bytes each), the samples' sequences (16 bytes), the
/// tables of notes and of steps of the pitch (16 bytes), two parts not used here, the songs (32 of four bytes: the
/// first place, the last, the one to go back to, and the speed), one more, the samples (64 bytes each, of which
/// the player keeps their places and its own counts), and the places of the patterns, whose bytes follow; the
/// samples themselves are at the file's end.
///
/// A voice's pattern is of bytes, a row each: a note (below $70), an instrument and an effect and its value; or
/// only a note and an instrument, or a note, or an effect and its value (from $70); and a byte from $80, as many rows
/// with nothing after it as its bits inverted say. The effects from $70 are an arpeggio, slides up and down, a
/// slide of the volume, a vibrato (all four on the ticks after the row's), the pattern's length, a sample's offset,
/// a note's delay and its cutting, a retrigger, a tremolo, the pattern's end, the volume, a slide of the volume
/// from the instrument's, a slide of the volume with the vibrato, and the speed; one below $70 is a slide to that
/// note. An instrument has its envelope (up, down, held and down again), a sequence of samples played one after
/// another, of notes and of steps of the pitch, a slide of its own, and its transposition; and a sample may have a
/// stretch of its bytes inverted, a byte at a time, going up and down or round, as it plays.
///
/// This is the player itself, as UADE runs it: what it tells Paula is what that player tells her, tick by tick. It
/// sets no timer of its own (it has only `DTP_Interrupt`), and so is run by DeliTracker's, which UADE runs from a
/// CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second and a little less. On every tick each voice's
/// envelope, sequences, effects and slides are moved, its volume and period told Paula, and its sample's place and
/// length (its loop's, after the first); and on the row's tick the row is read first, and the voices of its notes
/// turned off before they are begun, to be turned on as the tick ends.
///
/// The player's range of songs is all 32; here they are those up to the last that is not the tool's empty one (the
/// first place, the last and the one to go back to all nought, and the speed 4). A song comes to its end at its last
/// place's pattern's end, and is said to have done so as it begins again. Where the player would read outside the
/// file it reads nought; and a note past its table of periods has the period nought, which it makes its least.
struct ActionAmicsPlayer: ~Copyable {
    /// The file, as the player has changed it, and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: noughts, after the file.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    /// The address the file is at (any but nought, which the player takes for no instrument).
    static let base = 0x10000
    private let fileSize: Int
    /// The file as it was loaded, before any song has changed it.
    private let loaded: [UInt8]
    /// Where its parts begin, as addresses (`L466` to `L4A2`): sixteen, the last the patterns' bytes.
    private let parts: [Int]
    let songCount: Int
    private(set) var song = 0
    let sampleCount: Int

    /// What the player keeps for each voice (`L1080` and the three after it, 98 bytes each), byte for byte, as its
    /// words and bytes overlap: the voice's offset into the song's tables (0), its sample's place and length (4, 8),
    /// its period (10) and volume (12), the bit it has in DMACON (14) and its registers' offset (16), the envelope's
    /// part (18) and count (20), its instrument (22), its loop's place and length (26, 30), the note (32), the
    /// counts and places of the instrument's sequences (34 to 45), the row's note, instrument, effect and value
    /// (46 to 53), the slide's count (54), its own slide (58), the slide to a note's goal and step (60, 62), the
    /// pattern's place (64), how many empty rows are left (69), the place's transposition (71) and instrument's offset
    /// (57), the sample's number (72), the vibrato (74, 75), the period without it (76), a word that is a sound
    /// effect's for the fourth voice (78), the tremolo (80 to 82), the sample's offset (84), the delay of a note (86)
    /// and the retrigger (88 to 95), and its volume's scale (96).
    private var voices = [UInt8](repeating: 0, count: 4 * 98)
    /// The player's variables (`L120E`): the song's last place, the speed, the place, the row, the tick's count,
    /// the rows of a pattern, the count of three ticks the arpeggio goes by, the place to go back to.
    private var lastPlace: UInt8 = 0
    private var speed: UInt8 = 0
    private var place: UInt8 = 0
    private var row: UInt8 = 0
    private var tickCount: UInt8 = 0
    private var rows: UInt8 = 0
    private var phase: UInt8 = 0
    private var restart: UInt8 = 0
    /// DMACON as it is put together in a tick (`Lfec`).
    private var dma: UInt16 = 0
    /// The arpeggio's three steps (`Lb92`): the value's top half, nought, its bottom half.
    private var arpeggio: (UInt8, UInt8, UInt8) = (0, 0, 0)
    /// Whether the song has come to its end and not yet begun again.
    private var ending = false

    /// What Paula's period and volume registers were last given, for each voice.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    private var songLengths: [UInt64?] = []

    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to; and once the songs played through to find
    /// their lengths have taken four hours in all, the rest are too.
    private static let mostTicks = 50 * 60 * 60
    private static let mostTicksInAll = 4 * mostTicks

    /// The player's periods (`L121A`), from the note nought's, nought. (What follows them in its hunk, which a note
    /// past them would read, is its room for its own places, and is taken as nought.)
    static let periodTable: [UInt16] = [
        0x0000, 0x1680, 0x1530, 0x1400, 0x12E0, 0x11D0, 0x10D0, 0x0FE0, 0x0F00, 0x0E20, 0x0D60, 0x0CA0, 0x0BE8,
        0x0B40, 0x0A98, 0x0A00, 0x0970, 0x08E8, 0x0868, 0x07F0, 0x0780, 0x0710, 0x06B0, 0x0650, 0x05F4,
        0x05A0, 0x054C, 0x0500, 0x04B8, 0x0474, 0x0434, 0x03F8, 0x03C0, 0x0388, 0x0358, 0x0328, 0x02FA,
        0x02D0, 0x02A6, 0x0280, 0x025C, 0x023A, 0x021A, 0x01FC, 0x01E0, 0x01C5, 0x01AC, 0x0194, 0x017D,
        0x0168, 0x0153, 0x0140, 0x012E, 0x011D, 0x010D, 0x00FE, 0x00F0, 0x00E2, 0x00D6, 0x00CA, 0x00BE,
        0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F, 0x0078, 0x0071, 0x006B, 0x0065, 0x005F,
    ]

    /// The vibrato's and tremolo's sine (`Lc88`).
    private static let sine: [UInt8] = [
        0x00, 0x18, 0x31, 0x4A, 0x61, 0x78, 0x8D, 0xA1, 0xB4, 0xC5, 0xD4, 0xE0, 0xEB, 0xF4, 0xFA, 0xFD,
        0xFF, 0xFD, 0xFA, 0xF4, 0xEB, 0xE0, 0xD4, 0xC5, 0xB4, 0xA1, 0x8D, 0x78, 0x61, 0x4A, 0x31, 0x18,
    ]

    /// The text the player's check looks for (`L187`).
    private static let mark: [UInt8] = Array("ACTIONAMICS SOUND TOOL".utf8)

    // MARK: - Memory

    @inline(__always) private func byte(_ address: Int) -> UInt8 {
        let at = address &- Self.base
        return at >= 0 && at < fileSize ? memory[at] : 0
    }

    @inline(__always) private func word(_ address: Int) -> UInt16 { UInt16(byte(address)) << 8 | UInt16(byte(address &+ 1)) }
    @inline(__always) private func long(_ address: Int) -> Int {
        Int(Int32(bitPattern: UInt32(word(address)) << 16 | UInt32(word(address &+ 2))))
    }

    @inline(__always) private func poke(_ address: Int, _ value: UInt8) {
        let at = address &- Self.base
        if at >= 0, at < fileSize { memory[at] = value }
    }

    private func pokeWord(_ address: Int, _ value: UInt16) {
        poke(address, UInt8(value >> 8))
        poke(address &+ 1, UInt8(truncatingIfNeeded: value))
    }

    private func pokeLong(_ address: Int, _ value: Int) {
        let bits = UInt32(truncatingIfNeeded: value)
        pokeWord(address, UInt16(bits >> 16))
        pokeWord(address &+ 2, UInt16(truncatingIfNeeded: bits))
    }

    /// A voice's bytes, words and longs (see `voices`).
    @inline(__always) private func b(_ v: Int, _ at: Int) -> UInt8 { voices[v * 98 + at] }
    @inline(__always) private mutating func setB(_ v: Int, _ at: Int, _ value: UInt8) { voices[v * 98 + at] = value }
    @inline(__always) private func w(_ v: Int, _ at: Int) -> UInt16 { UInt16(b(v, at)) << 8 | UInt16(b(v, at + 1)) }
    @inline(__always) private mutating func setW(_ v: Int, _ at: Int, _ value: UInt16) {
        setB(v, at, UInt8(value >> 8))
        setB(v, at + 1, UInt8(truncatingIfNeeded: value))
    }

    @inline(__always) private func l(_ v: Int, _ at: Int) -> Int { Int(Int32(bitPattern: UInt32(w(v, at)) << 16 | UInt32(w(v, at + 2)))) }
    @inline(__always) private mutating func setL(_ v: Int, _ at: Int, _ value: Int) {
        let bits = UInt32(truncatingIfNeeded: value)
        setW(v, at, UInt16(bits >> 16))
        setW(v, at + 2, UInt16(truncatingIfNeeded: bits))
    }

    private static func long(_ data: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at < data.count - 3 else { return 0 }
        return Int(Int32(bitPattern: UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])))
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`, $1A4): "ACTIONAMICS SOUND TOOL" at byte 62.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 62 + mark.count && data[62 ..< 62 + mark.count].elementsEqual(mark)
    }

    /// Reads the file and starts the song asked for (of `songCount`, nought the first).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        // `InitSound` ($314): the parts' places, from byte 62 on, and the samples', back from the file's end as its
        // second part says it is, in their order.
        var parts = [Self.base + 62]
        for i in 0 ..< 15 { parts.append(parts[i] &+ Self.long(data, 2 + 4 * i)) }
        self.parts = parts
        var loaded = data
        let samples = parts[13], count = max(0, min(4096, (parts[14] &- parts[13]) >> 6))
        sampleCount = count
        var total = 0
        for i in 0 ..< count {
            let at = samples &- Self.base &+ 64 * i &+ 4
            total &+= at >= 0 && at < data.count - 1 ? (Int(data[at]) << 8 | Int(data[at + 1])) * 2 : 0
        }
        var address = Self.long(data, parts[1] &- Self.base) &+ Self.base &- total
        for i in 0 ..< count {
            let at = samples &- Self.base &+ 64 * i
            guard at >= 0, at < loaded.count - 5 else { continue }
            let bits = UInt32(truncatingIfNeeded: address)
            loaded[at] = UInt8(bits >> 24)
            loaded[at + 1] = UInt8(truncatingIfNeeded: bits >> 16)
            loaded[at + 2] = UInt8(truncatingIfNeeded: bits >> 8)
            loaded[at + 3] = UInt8(truncatingIfNeeded: bits)
            address &+= (Int(loaded[at + 4]) << 8 | Int(loaded[at + 5])) * 2
        }
        self.loaded = loaded
        // The songs, to the last that is not the tool's empty one.
        var last = 0
        for i in 0 ..< 32 {
            let at = parts[11] &- Self.base &+ 4 * i
            guard at >= 0, at < data.count - 3 else { break }
            if data[at] != 0 || data[at + 1] != 0 || data[at + 2] != 0 || data[at + 3] != 4 { last = i }
        }
        songCount = last + 1
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not an Action Amics file") }

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
            // (The tick it came to its end in is the first of it again.)
            songLengths.append(endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil)
        }
        self.song = max(0, min(songCount - 1, song))
        lengthClocks = songLengths[self.song]
        start()
    }

    deinit { memory.deallocate() }

    /// `InitSound` ($314): the file as it was loaded, the voices as nothing, and the song's places, speed and first
    /// patterns.
    private mutating func start() {
        for i in 0 ..< fileSize { memory[i] = loaded[i] }
        voices = .init(repeating: 0, count: 4 * 98)
        for v in 0 ..< 4 {
            setW(v, 14, 1 << UInt16(v))
            setW(v, 16, 0xA0 + 16 * UInt16(v))
            setW(v, 96, 0x4041)
        }
        let entry = parts[11] &+ 4 * (song & 0x1F)
        place = byte(entry)
        lastPlace = byte(entry &+ 1)
        restart = byte(entry &+ 2)
        speed = byte(entry &+ 3)
        row = 0
        tickCount = 0
        rows = 0x40
        phase = 0
        dma = 0
        arpeggio = (0, 0, 0)
        ending = false
        // (Each voice's offset into the song's tables: a quarter of the first's length.)
        let quarter = (parts[3] &- parts[2]) >> 2
        for v in 0 ..< 4 {
            setL(v, 0, v * quarter)
            loadPlace(v)
        }
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        endings = 0
        stops = 0
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        lengthClocks = songLengths[song]
        start()
    }

    /// `L884`: the voice's pattern, transposition and instrument's offset at the song's place.
    private mutating func loadPlace(_ v: Int) {
        let offset = l(v, 0) &+ Int(place)
        let pattern = Int(byte(parts[2] &+ offset)) * 2
        setL(v, 64, Int(word(parts[14] &+ pattern)) &+ parts[15])
        setB(v, 71, byte(parts[3] &+ offset))
        setB(v, 57, byte(parts[4] &+ offset))
        setB(v, 69, 0)
    }

    // MARK: - Playing

    private mutating func writePeriod<Output: TFMXOutput>(_ v: Int, _ period: UInt16, _ output: inout Output) {
        periods[v] = period
        output.writePeriod(v, period)
    }

    /// `L22A`: the volume told Paula, its seven bits (times EaglePlayer's, 64, over 64).
    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume & 0x7F
        output.writeVolume(v, volumes[v])
    }

    /// The volume from its word at 12, as the player scales it: times $4041 (the word at 96), its top word.
    private mutating func tellVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        writeVolume(v, UInt16(truncatingIfNeeded: (UInt32(volume) &* UInt32(w(v, 96))) >> 16), &output)
    }

    /// Paula's location and length registers, told an address and a length: silence for one outside the file.
    private func tellPlace<Output: TFMXOutput>(_ v: Int, _ address: Int, _ length: UInt16, _ output: inout Output) {
        let at = address &- Self.base
        output.takeNextBuffer(v, start: at >= 0 && at < fileSize ? at : silenceAt, length: length)
    }

    private static func period(_ index: Int) -> UInt16 { index >= 0 && index < periodTable.count ? periodTable[index] : 0 }

    /// Runs the player for a tick (`Interrupt` and `L4FA`), telling `output` what Paula is to do, in the order the
    /// player tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        phase &+= 1
        if phase == 3 { phase = 0 }
        tickCount &+= 1
        if tickCount == speed {
            // The row's tick: each voice's row read, the voices of its notes turned off, and the notes begun.
            if ending {
                ending = false
                endings += 1
            }
            tickCount = 0
            phase = 0
            dma = 0
            for v in 0 ..< 4 { readRow(v) }
            for v in 0 ..< 4 where dma & 1 << UInt16(v) != 0 { output.off(v) }
            dma &+= 0x8000
            for v in 0 ..< 4 { begin(v) }
            invert()
            row &+= 1
            if row == rows {
                row = 0
                let was = place
                place &+= 1
                if was == lastPlace {
                    ending = true
                    place = restart
                }
                for v in 0 ..< 4 { loadPlace(v) }
            }
        }
        for v in 0 ..< 4 {
            // (The fourth voice is left out while it plays a sound effect: never, here.)
            // A retrigger's count: at its end, the sample from where it was, its voice turned off.
            if w(v, 88) != 0 {
                setW(v, 88, w(v, 88) &- 1)
                if w(v, 88) == 0 {
                    setL(v, 4, l(v, 90))
                    setW(v, 8, w(v, 94))
                    output.off(v)
                }
            }
            effects(v, &output)
            // A note's delay's count; once it is over, the sample told Paula, and its loop after it from then on, and
            // the voice to be turned on.
            let delay = w(v, 86) &- 1
            if Int16(bitPattern: delay) >= 0 {
                setW(v, 86, delay)
            } else {
                tellPlace(v, l(v, 4), w(v, 8), &output)
                writePeriod(v, w(v, 10), &output)
                setL(v, 4, l(v, 26))
                setW(v, 8, w(v, 30))
                dma |= w(v, 14) | (v == 0 ? 0x8000 : 0)
            }
        }
        if tickCount != 0 { invert() }
        // DMACON: the voices turned on.
        if dma & 0x8000 != 0 {
            for v in 0 ..< 4 where dma & 1 << UInt16(v) != 0 { output.on(v) }
        } else {
            for v in 0 ..< 4 where dma & 1 << UInt16(v) != 0 { output.off(v) }
        }
        return 20
    }

    /// `L8C8` and `L902`: the voice's row: its note, instrument, effect and value, or a count of empty rows.
    private mutating func readRow(_ v: Int) {
        var at = l(v, 64)
        setL(v, 46, 0)
        setL(v, 50, 0)
        if b(v, 69) != 0 {
            setB(v, 69, b(v, 69) &- 1)
        } else {
            read: do {
                var value = byte(at)
                at &+= 1
                if value >= 0x80 {
                    setB(v, 69, ~value)
                    break read
                }
                if value >= 0x70 {
                    setB(v, 51, value)
                    setB(v, 53, byte(at))
                    at &+= 1
                    break read
                }
                setB(v, 47, value)
                value = byte(at)
                at &+= 1
                if value >= 0x80 {
                    setB(v, 69, ~value)
                    break read
                }
                if value >= 0x70 {
                    setB(v, 51, value)
                    setB(v, 53, byte(at))
                    at &+= 1
                    break read
                }
                setB(v, 49, value)
                value = byte(at)
                at &+= 1
                if value >= 0x80 {
                    setB(v, 69, ~value)
                    break read
                }
                setB(v, 51, value)
                setB(v, 53, byte(at))
                at &+= 1
            }
        }
        setL(v, 64, at)
        // (`L8EC`) A note: its voice's bit in DMACON, and its transposition.
        let note = w(v, 46)
        if note != 0 {
            dma &+= w(v, 14)
            setW(v, 46, note & 0xFF00 | UInt16(UInt8(truncatingIfNeeded: note) &+ b(v, 71)))
        }
    }

    /// `L95E`: a note begun: its instrument, its sample (the first of the instrument's sequence), and its period.
    private mutating func begin(_ v: Int) {
        setW(v, 58, 0)
        var note = w(v, 46)
        guard note != 0 else { return }
        setW(v, 12, 0)
        setL(v, 34, 0)
        setW(v, 38, 0)
        setL(v, 40, 0)
        setW(v, 44, 0)
        setW(v, 54, 0)
        setW(v, 62, 0)
        setW(v, 18, 4)
        setW(v, 20, 0)
        let number = w(v, 48)
        if number != 0 {
            let index = UInt16(UInt8(truncatingIfNeeded: number) &- 1 &+ b(v, 57)) | number & 0xFF00
            setL(v, 22, parts[5] &+ Int(index &<< 5))
        }
        let instrument = l(v, 22)
        note = note & 0xFF00 | UInt16(UInt8(truncatingIfNeeded: note) &+ byte(instrument &+ 14))
        setW(v, 32, note)
        let sample = byte(parts[6] &+ Int(byte(instrument)) << 4)
        setB(v, 73, sample)
        let entry = parts[13] &+ Int(sample) << 6
        setL(v, 4, long(entry))
        setW(v, 8, word(entry &+ 4))
        setL(v, 26, long(entry) &+ Int(word(entry &+ 6)) * 2)
        setW(v, 30, word(entry &+ 8))
        let transpose = Int8(bitPattern: byte(parts[7] &+ Int(byte(entry &+ 12)) << 4))
        let index = Int(Int16(bitPattern: note &+ UInt16(bitPattern: Int16(transpose))))
        let period = Self.period(index)
        setW(v, 76, period)
        setW(v, 10, period)
    }

    /// `L7CA`: each voice's sample's stretch of inverted bytes: every so many ticks, a byte of it inverted, and the
    /// place moved on (up or down, back from its ends or round), once a tick for each sample.
    private mutating func invert() {
        var entries = InlineArray<4, Int>(repeating: 0)
        for v in 0 ..< 4 {
            let entry = parts[13] &+ Int(w(v, 72) &<< 6)
            entries[v] = entry
            guard word(entry &+ 26) == 0 else { continue }
            pokeWord(entry &+ 26, 0xFFFF)
            let count = word(entry &+ 24)
            if count != 0 {
                pokeWord(entry &+ 24, (count &- 1) & 0x1F)
                continue
            }
            pokeWord(entry &+ 24, word(entry &+ 14))
            let mode = word(entry &+ 16)
            guard mode != 0 else { continue }
            let range = Int(word(entry &+ 12)) * 2 &- 1
            let at = long(entry) &+ Int(word(entry &+ 10)) * 2 &+ long(entry &+ 20)
            poke(at, ~byte(at))
            var step = Int(Int16(bitPattern: word(entry &+ 18)))
            var position = Int32(truncatingIfNeeded: long(entry &+ 20) &+ step)
            pokeLong(entry &+ 20, Int(position))
            if position < 0 {
                if mode == 2 {
                    pokeLong(entry &+ 20, range)
                    continue
                }
            } else {
                if UInt32(truncatingIfNeeded: range) >= UInt32(bitPattern: position) { continue }
                if mode == 1 {
                    pokeLong(entry &+ 20, 0)
                    continue
                }
            }
            // (Back from the end it came to.)
            step = -step
            position = Int32(truncatingIfNeeded: Int(position) &+ step)
            pokeLong(entry &+ 20, Int(position))
            pokeWord(entry &+ 18, 0 &- word(entry &+ 18))
        }
        for v in 0 ..< 4 { pokeWord(entries[v] &+ 26, 0) }
    }

    /// `La1A`: a voice's tick: its envelope and volume, its sequence of samples, its effect, its sequences of notes and
    /// of steps of the pitch, its slides, and its period.
    private mutating func effects<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        envelope(v)
        setW(v, 80, w(v, 12))
        tellVolume(v, w(v, 12), &output)
        let instrument = l(v, 22)
        if instrument != 0 {
            sampleSequence(v, instrument, &output)
        }
        effect(v, &output)
        if instrument != 0 {
            noteSequence(v, instrument)
            pitchSequence(v, instrument)
            // (`La6A`) The instrument's own slide, once its delay is over.
            let slide = byte(instrument &+ 12)
            if slide != 0 {
                if byte(instrument &+ 13) == b(v, 55) {
                    setW(v, 58, w(v, 58) &+ UInt16(bitPattern: Int16(Int8(bitPattern: slide))))
                } else {
                    setB(v, 55, b(v, 55) &+ 1)
                }
            }
        }
        portamento(v, instrument)
        var period = Int16(bitPattern: w(v, 10) &+ w(v, 58))
        if period <= 0x5F {
            period = 0x5F
        } else if period >= 0x1680 {
            period = 0x1680
        }
        setW(v, 10, UInt16(bitPattern: period))
        writePeriod(v, UInt16(bitPattern: period), &output)
    }

    /// `Lf48`: the envelope: up to its first volume, down to its second, held, and down to its last.
    private mutating func envelope(_ v: Int) {
        let instrument = l(v, 22)
        guard instrument != 0 else { return }
        let at = instrument &+ 16
        let volume = Int16(bitPattern: w(v, 12))
        switch w(v, 18) {
        case 4:
            let goal = Int16(byte(at)), step = Int16(byte(at &+ 1))
            let next = volume &+ step
            setW(v, 12, UInt16(bitPattern: next))
            if goal <= next {
                setW(v, 12, UInt16(bitPattern: goal))
                setW(v, 18, 3)
            }
        case 3, 1:
            let first = w(v, 18) == 3 ? 2 : 5
            let goal = Int16(byte(at &+ first)), step = Int16(byte(at &+ first &+ 1))
            if step != 0 {
                let next = volume &- step
                setW(v, 12, UInt16(bitPattern: next))
                guard goal >= next else { return }
                setW(v, 12, UInt16(bitPattern: goal))
            }
            setW(v, 18, w(v, 18) &- 1)
        case 2:
            if UInt16(byte(at &+ 4)) != w(v, 20) {
                setW(v, 20, w(v, 20) &+ 1)
            } else {
                setW(v, 18, 1)
            }
        default:
            break
        }
    }

    /// `Leb8`: the instrument's sequence of samples: every so many ticks the next, told Paula as the loop.
    private mutating func sampleSequence<Output: TFMXOutput>(_ v: Int, _ instrument: Int, _ output: inout Output) {
        let length = byte(instrument &+ 1)
        guard length != 0 else { return }
        let delay = byte(instrument &+ 3)
        guard delay == b(v, 35) else {
            setB(v, 35, b(v, 35) &+ 1)
            return
        }
        setB(v, 35, delay &- byte(instrument &+ 2))
        if length == b(v, 37) { setB(v, 37, 0xFF) }
        setB(v, 37, b(v, 37) &+ 1)
        let sample = byte(parts[6] &+ Int(UInt16(byte(instrument)) << 4 &+ w(v, 36)))
        guard Int8(bitPattern: sample) >= 0 else {
            setB(v, 37, b(v, 37) &- 1)
            return
        }
        setB(v, 73, sample)
        let entry = parts[13] &+ Int(sample) << 6
        setL(v, 26, long(entry))
        setW(v, 30, word(entry &+ 4))
        tellPlace(v, l(v, 26), w(v, 30), &output)
    }

    /// `Le50`: the instrument's sequence of notes, from the voice's note.
    private mutating func noteSequence(_ v: Int, _ instrument: Int) {
        let length = byte(instrument &+ 5)
        guard length != 0 else { return }
        let delay = byte(instrument &+ 7)
        guard delay == b(v, 39) else {
            setB(v, 39, b(v, 39) &+ 1)
            return
        }
        setB(v, 39, delay &- byte(instrument &+ 6))
        if length == b(v, 41) { setB(v, 41, 0xFF) }
        setB(v, 41, b(v, 41) &+ 1)
        let step = Int8(bitPattern: byte(parts[7] &+ Int(UInt16(byte(instrument &+ 4)) << 4 &+ w(v, 40))))
        let index = Int16(bitPattern: UInt16(bitPattern: Int16(step)) &+ w(v, 32))
        setW(v, 10, Self.period(Int(index)))
    }

    /// `Ldf6`: the instrument's sequence of steps of the pitch.
    private mutating func pitchSequence(_ v: Int, _ instrument: Int) {
        let length = byte(instrument &+ 9)
        guard length != 0 else { return }
        let delay = byte(instrument &+ 11)
        guard delay == b(v, 43) else {
            setB(v, 43, b(v, 43) &+ 1)
            return
        }
        setB(v, 43, delay &- byte(instrument &+ 10))
        if length == b(v, 45) { setB(v, 45, 0xFF) }
        setB(v, 45, b(v, 45) &+ 1)
        let step = Int8(bitPattern: byte(parts[8] &+ Int(UInt16(byte(instrument &+ 8)) << 4 &+ w(v, 44))))
        setW(v, 10, w(v, 10) &+ UInt16(bitPattern: Int16(step)))
    }

    /// `Lae0`: a slide to the note an effect below $70 names, by its value a tick.
    private mutating func portamento(_ v: Int, _ instrument: Int) {
        let effect = w(v, 50), value = w(v, 52)
        if effect != 0, effect < 0x70, value != 0 {
            let note = UInt8(truncatingIfNeeded: effect) &+ b(v, 71) &+ byte(instrument &+ 14)
            let goal = Self.period(Int(note))
            setW(v, 60, goal)
            let difference = Int16(bitPattern: goal &- w(v, 10))
            guard difference != 0 else { return }
            setW(v, 62, difference > 0 ? value : 0 &- value)
        }
        let step = Int16(bitPattern: w(v, 62))
        guard step != 0 else { return }
        let period = Int16(bitPattern: w(v, 10) &+ UInt16(bitPattern: step))
        setW(v, 10, UInt16(bitPattern: period))
        let goal = Int16(bitPattern: w(v, 60))
        if step > 0 ? period >= goal : period <= goal {
            setW(v, 62, 0)
            setW(v, 10, w(v, 60))
            setW(v, 76, w(v, 10))
        }
    }

    /// `La92`: the row's effect from $70: the first five on the ticks after the row's, the rest on every tick.
    private mutating func effect<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let effect = w(v, 50)
        guard effect >= 0x70 else { return }
        let command = effect & 15
        guard tickCount != 0 || command >= 5 else { return }
        let value = w(v, 52), low = b(v, 53)
        switch command {
        case 0:
            // The arpeggio: the note, and the value's halves above it, a tick each (the top half first).
            arpeggio = (UInt8(truncatingIfNeeded: value >> 4), arpeggio.1, low & 15)
            let add = phase == 0 ? arpeggio.0 : phase == 1 ? arpeggio.1 : arpeggio.2
            setW(v, 10, Self.period(Int(Int16(bitPattern: UInt16(add) &+ w(v, 32)))))
        case 1, 2:
            // A slide up or down: by the value, on the period and on the period without the vibrato.
            let step = command == 1 ? 0 &- value : value
            setW(v, 58, step)
            setW(v, 76, w(v, 76) &+ step)
        case 3:
            if w(v, 18) == 0 { volumeSlide(v, fromInstrument: tickCount == 0 && w(v, 48) != 0) }
        case 4:
            if low != 0 { setB(v, 74, merge(b(v, 74), low)) }
            vibrato(v)
        case 5:
            rows = low
        case 6:
            // A sample's offset: so many 128ths of words into it, or the last word of it if that is past it.
            if value != 0 { setW(v, 84, value) }
            let offset = w(v, 84) &<< 7
            if Int16(bitPattern: offset) < Int16(bitPattern: w(v, 8)) {
                setW(v, 8, w(v, 8) &- offset)
                setL(v, 4, l(v, 4) &+ Int(UInt16(offset &<< 1)))
            } else {
                setW(v, 8, 1)
            }
        case 7:
            // A note's delay: the effect taken away, and the voice not turned on.
            if value != 0 {
                setL(v, 50, 0)
                setW(v, 86, value)
                dma &= ~w(v, 14)
            }
        case 8:
            // A note cut on a tick of the row.
            if low != 0, low == tickCount {
                setW(v, 12, 0)
                setW(v, 80, 0)
                writeVolume(v, 0, &output)
            }
        case 9:
            // A retrigger: the sample's place kept, to go back to after so many ticks.
            if value != 0 {
                setL(v, 50, 0)
                setW(v, 88, value)
                setL(v, 90, l(v, 4))
                setW(v, 94, w(v, 8))
            }
        case 10:
            tremolo(v, &output)
        case 11:
            row = rows &- 1
        case 12:
            var volume = value &<< 2
            if volume >= 0xFF { volume = 0xFF }
            setW(v, 12, volume)
            tellVolume(v, volume, &output)
        case 13:
            volumeSlide(v, fromInstrument: tickCount == 0)
        case 14:
            if w(v, 18) == 0 { volumeSlide(v, fromInstrument: tickCount == 0 && w(v, 48) != 0) }
            vibrato(v)
        default:
            if low < 0x1F { speed = low }
        }
    }

    /// The value's halves that are not nought put into a byte of an effect's (its speed and depth).
    private func merge(_ byte: UInt8, _ value: UInt8) -> UInt8 {
        var result = byte
        if value & 15 != 0 { result = result & 0xF0 | value & 15 }
        if value & 0xF0 != 0 { result = result & 15 | value & 0xF0 }
        return result
    }

    /// `Lbbc` to `Lc1e`: a slide of the volume, from the instrument's first if asked: down by four times the value if
    /// its bottom half is not nought (to nought), else up by four times its top half (to $FF).
    private mutating func volumeSlide(_ v: Int, fromInstrument: Bool) {
        if fromInstrument {
            let instrument = l(v, 22)
            guard instrument != 0 else { return }
            setB(v, 13, byte(instrument &+ 17))
        }
        let value = w(v, 52)
        var volume = Int16(bitPattern: w(v, 12))
        if value & 15 != 0 {
            volume = volume &- Int16(bitPattern: value &<< 2)
            if volume < 0 { volume = 0 }
        } else {
            volume = volume &+ Int16(bitPattern: (value >> 4) &<< 2)
            if volume >= 0x100 { volume = 0xFF }
        }
        setW(v, 12, UInt16(bitPattern: volume))
        setW(v, 80, UInt16(bitPattern: volume))
    }

    /// `Lc4e`: the vibrato's step: the period without it, less or more its sine times its depth.
    private mutating func vibrato(_ v: Int) {
        let position = b(v, 75)
        var size = (UInt16(Self.sine[Int(position >> 2) & 0x1F]) * UInt16(b(v, 74) & 15)) >> 7
        if Int8(bitPattern: position) >= 0 { size = 0 &- size }
        setW(v, 10, w(v, 76) &- size)
        setB(v, 75, position &+ (b(v, 74) >> 2))
    }

    /// `Lca8`: the tremolo (on the bytes of the volume's copy at 80, as the player has it).
    private mutating func tremolo<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let low = b(v, 53)
        if low != 0 { setB(v, 80, merge(b(v, 80), low)) }
        let position = b(v, 81)
        var size = (UInt16(Self.sine[Int(position >> 2) & 0x1F]) * UInt16(b(v, 80) & 15)) >> 6
        if Int8(bitPattern: position) >= 0 { size = 0 &- size }
        var volume = Int16(bitPattern: w(v, 82) &- size)
        if volume < 0 { volume = 0 }
        if volume >= 0x40 { volume = 0x40 }
        var scaled = UInt16(volume) << 2
        if scaled == 0x100 { scaled = 0xFF }
        setW(v, 12, scaled)
        tellVolume(v, scaled, &output)
        setB(v, 81, position &+ ((b(v, 80) >> 2) & 0x3C))
    }

    /// What the player last gave Paula's period register for the voice.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Action Amics' music, played on Paula by `PaulaTickRenderer`.
extension ActionAmicsPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Action Amics")
        info.detail = "\(sampleCount) sample\(sampleCount == 1 ? "" : "s")"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -23.2 dB.)
    var gain: Float { 0.41 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
