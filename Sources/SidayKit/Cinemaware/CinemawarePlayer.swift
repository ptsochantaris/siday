// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the music player of Cinemaware's Wings (1990), as Wanted Team adapted it for EaglePlayer ("Cinemaware
// player module V1.0 (24 Apr 2004)"), carried by UADE as players/Cinemaware, whose source UADE also carries as
// amigasrc/players/wanted_team/Cinemaware/src/Cinemaware.asm: the game's own compiled code, with Wanted Team's
// calls to EaglePlayer put in. The labels given are that source's.

/// Cinemaware's music for Wings (1990), by Gregory Haggard: a file of its instruments ('IBLK') and a list of events
/// much as a MIDI file has them ('ASEQ'), whose sounds are IFF 8SVX files of their own, in a folder `Instruments`
/// beside it.
///
/// The file is 'IBLK', how many instruments it has and a byte the player does not read, and then the instruments, of
/// 138 bytes each: its number (the program that plays it), its name, a transposition, a velocity to be added, a
/// vibrato's depth and speed, how far a bend of the pitch goes, an envelope of the pitch and one of the volume (each
/// eight levels, and how fast each is gone to, the part it is let go to and the last of those it goes round while
/// the note is held), and three waves: each the name of its 8SVX file (none, for none), the notes it plays (the
/// first of them whose notes take the note plays it), the frequency of its sound, and where in its BODY the sound
/// begins, loops (none, if less than nought) and ends. After them, which of Paula's voices each of the sixteen
/// channels plays on (more than 3 for any, taken as it is free or has been playing longest), and then 'ASEQ' and the
/// events: five bytes each, how many ticks after the one before it comes, and a MIDI message: a note begun or let
/// go, a controller (1 the modulation, 7 the channel's volume, 64 the sustain pedal), a program, a bend of the
/// pitch (its high byte), or the song's end ($10).
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It is run sixty times a second (`InitSound` sets EaglePlayer's timer to five sixths of
/// UADE's $376B: (11822 + 1) * 5 = 59,115 of Paula's clocks), as the game ran it on a CIA's timer of NTSC's sixty
/// times a second. On every tick the events that have come are acted on (a note is begun with its voice turned
/// off and told its sound, its period $80 and its volume nought), and then each voice playing is moved on: its two
/// envelopes and its vibrato, its period (from a table of 240 steps to an octave, as the wave's frequency over a
/// frequency of the note), its loop told Paula on its second tick, its volume, a wait for the beam to begin nine
/// lines (`DMAWait`) and its voice turned on (or off, if its envelope has come to its end). Each of its writes is
/// told Paula at its moment in the tick (`TFMXOutput.timed(at:)`), near where it falls in UADE's dumps.
///
/// The song comes to its end at its end's event; the player then turns all of Paula's voices off for 25 ticks and
/// begins it again. The player's check takes a file only if that event is in it. Where it would read past the
/// file it reads nought; an instrument numbered 128 or more (which the player would put before its own table of
/// them), or a program that has none (it would read the Amiga's own memory at nought), plays nothing, and a note
/// whose pitch comes below nought (where the player would read its own code for a frequency) has the frequency it
/// takes for nought, one. A wave whose file is not in the folder, or is not an 8SVX, is not heard (the player would not load the
/// song).
struct CinemawarePlayer: ~Copyable {
    /// The file, the instruments' files after it, and silence after them, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: noughts after the files (`lbL00EC9A`).
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where each program's instrument is (`lbL00ECB2`), nought for none; the channels' table of voices
    /// (`lbL00ECA6`); and the first event.
    private var instruments = [Int](repeating: 0, count: 128)
    private let channelTable: Int
    private let sequence: Int
    /// The song's end's event, the last the player can come to.
    private let lastRow: Int
    let songCount = 1
    let song = 0
    /// How many instruments the file has, how many waves with sounds, the files of those not found, and the
    /// instruments' names.
    let instrumentCount: Int
    let waveCount: Int
    let missingWaves: [String]
    /// Where each wave's file found was put in `memory`: its name, its sound (after its BODY's length), and how
    /// many bytes of the file are from there on.
    let places: [Place]

    struct Place {
        var name: String
        var sound: Int, size: Int
    }

    /// What the player keeps for each of the sixteen channels (`lbB00EBAE`, six bytes each): its program, the
    /// high byte of its bend (64 for none), its modulation (kept, but used for nothing), its volume and its
    /// sustain pedal.
    private struct Channel {
        var program: UInt8 = 0
        var bend: UInt8 = 0x40
        var modulation: UInt8 = 0
        var volume: UInt8 = 0x7F
        var sustain: UInt8 = 0
    }

    /// What the player keeps for each voice (`lbL00EC0E`, 26 bytes each).
    private struct Voice {
        /// The channel it plays for (less than nought, none: it is free), its note, program and velocity; its
        /// wave's frequency; the pitch's envelope (from $80) and the volume's (from nought), and their parts.
        var channel: Int8 = -1
        var note: UInt8 = 0
        var program: UInt8 = 0
        var velocity: UInt8 = 0
        var frequency: UInt16 = 0
        var pitch: UInt16 = 0x80
        var level: UInt16 = 0
        var pitchPart: Int8 = 0
        var levelPart: Int8 = 0
        /// Counted down from 255 with every tick it plays: how long it has played, for a voice to be taken.
        var age: UInt8 = 0
        /// Bit 1 while its note is held, bit 0 while the sustain pedal is down.
        var flags: UInt8 = 0
        /// Its loop, told Paula as `loopCount` comes to nought (on the note's second tick).
        var loopAt = 0
        var loopLength: UInt16 = 0
        var vibrato: UInt16 = 0
        var vibratoStep: UInt16 = 0
        var loopCount: UInt16 = 0
    }

    private var channels = InlineArray<16, Channel>(repeating: Channel())
    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The next event (`lbL00EC90`), the ticks to it (`lbW00EC98`), and the ticks of silence left after the song's
    /// end (`lbW00ECB0`).
    private var row = 0
    private var wait: UInt16 = 0
    private var silentTicks: UInt16 = 0
    /// What each of Paula's period and volume registers was last given, and what they held as the tick just
    /// run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told at their
    /// moments).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the wait.
    private var clock = 0
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?
    /// How long each tick is (see the type's comment).
    static let tickClocks = (0x376B * 5 / 6 + 1) * 5
    /// A song longer than an hour is taken never to end.
    private static let mostTicks = 60 * 60 * 60
    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (near the medians of its dumps): the
    /// first after the interrupt begins (a guess: only the distances between them are heard); how long an event
    /// takes, and a note begun its writes; and how long each voice takes to be made, its writes, and its turning on
    /// after the wait.
    static let firstWrite = 300
    static let eventClocks = 150
    static let noteFind = 300
    static let noteVolume = 1200
    static let noteSound = 1440
    static let noteClocks = 2340
    static let makeClocks = 1100
    static let loopClocks = 60
    static let volumeClocks = 250
    static let onClocks = 80
    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's clocks) has
    /// changed nine times, the first at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 80 - clock
    }

    /// The frequencies of the 240 steps of an octave (`lbW00B7DE`): $8000 times two to the step over 240.
    static let frequencies: [UInt16] = [
        0x8000, 0x805E, 0x80BD, 0x811D, 0x817C, 0x81DC, 0x823C, 0x829D, 0x82FD, 0x835E, 0x83C0, 0x8421,
        0x8483, 0x84E5, 0x8548, 0x85AA, 0x860D, 0x8670, 0x86D4, 0x8738, 0x879C, 0x8800, 0x8865, 0x88CA,
        0x892F, 0x8995, 0x89FB, 0x8A61, 0x8AC7, 0x8B2E, 0x8B95, 0x8BFD, 0x8C64, 0x8CCC, 0x8D34, 0x8D9D,
        0x8E06, 0x8E6F, 0x8ED8, 0x8F42, 0x8FAC, 0x9017, 0x9081, 0x90EC, 0x9158, 0x91C3, 0x922F, 0x929B,
        0x9308, 0x9375, 0x93E2, 0x9450, 0x94BD, 0x952C, 0x959A, 0x9609, 0x9678, 0x96E7, 0x9757, 0x97C7,
        0x9837, 0x98A8, 0x9919, 0x998B, 0x99FC, 0x9A6E, 0x9AE1, 0x9B53, 0x9BC6, 0x9C3A, 0x9CAD, 0x9D21,
        0x9D96, 0x9E0A, 0x9E7F, 0x9EF5, 0x9F6A, 0x9FE0, 0xA057, 0xA0CE, 0xA145, 0xA1BC, 0xA234, 0xA2AC,
        0xA324, 0xA39D, 0xA416, 0xA490, 0xA50A, 0xA584, 0xA5FE, 0xA679, 0xA6F5, 0xA770, 0xA7EC, 0xA868,
        0xA8E5, 0xA962, 0xA9E0, 0xAA5D, 0xAADC, 0xAB5A, 0xABD9, 0xAC58, 0xACD8, 0xAD58, 0xADD8, 0xAE59,
        0xAEDA, 0xAF5B, 0xAFDD, 0xB05F, 0xB0E2, 0xB165, 0xB1E8, 0xB26C, 0xB2F0, 0xB375, 0xB3FA, 0xB47F,
        0xB504, 0xB58A, 0xB611, 0xB698, 0xB71F, 0xB7A7, 0xB82E, 0xB8B7, 0xB940, 0xB9C9, 0xBA52, 0xBADC,
        0xBB67, 0xBBF1, 0xBC7D, 0xBD08, 0xBD94, 0xBE20, 0xBEAD, 0xBF3A, 0xBFC8, 0xC056, 0xC0E4, 0xC173,
        0xC203, 0xC292, 0xC322, 0xC3B3, 0xC444, 0xC4D5, 0xC567, 0xC5F9, 0xC68B, 0xC71E, 0xC7B2, 0xC846,
        0xC8DA, 0xC96F, 0xCA04, 0xCA99, 0xCB2F, 0xCBC6, 0xCC5D, 0xCCF4, 0xCD8C, 0xCE24, 0xCEBD, 0xCF56,
        0xCFEF, 0xD089, 0xD124, 0xD1BE, 0xD25A, 0xD2F6, 0xD392, 0xD42E, 0xD4CC, 0xD569, 0xD607, 0xD6A6,
        0xD744, 0xD7E4, 0xD884, 0xD924, 0xD9C5, 0xDA66, 0xDB08, 0xDBAA, 0xDC4D, 0xDCF0, 0xDD93, 0xDE37,
        0xDEDC, 0xDF81, 0xE026, 0xE0CC, 0xE173, 0xE21A, 0xE2C1, 0xE369, 0xE411, 0xE4BA, 0xE564, 0xE60E,
        0xE6B8, 0xE763, 0xE80E, 0xE8BA, 0xE966, 0xEA13, 0xEAC0, 0xEB6E, 0xEC1C, 0xECCB, 0xED7B, 0xEE2A,
        0xEEDB, 0xEF8C, 0xF03D, 0xF0EF, 0xF1A1, 0xF254, 0xF308, 0xF3BC, 0xF470, 0xF525, 0xF5DB, 0xF691,
        0xF747, 0xF7FE, 0xF8B6, 0xF96E, 0xFA27, 0xFAE0, 0xFB9A, 0xFC54, 0xFD0F, 0xFDCA, 0xFE86, 0xFF43,
    ]

    /// The parts of an instrument (its offsets).
    private enum At {
        static let transpose = 0x12
        static let velocity = 0x14
        static let vibratoDepth = 0x15
        static let vibratoSpeed = 0x16
        static let bendRange = 0x17
        static let pitchRelease = 0x18
        static let pitchLoop = 0x19
        static let pitchLevels = 0x1A
        static let pitchRates = 0x22
        static let levelRelease = 0x2A
        static let levelLoop = 0x2B
        static let levels = 0x2C
        static let levelRates = 0x34
        /// The first wave, and each wave's parts: its file's name, its sound (in the file, any long not nought for
        /// one; put there by the player as its file's BODY), its notes, frequency, and its sound's start, loop
        /// and end, in bytes.
        static let waves = 0x3C
        static let waveSize = 26
        static let sound = 6
        static let low = 10
        static let high = 11
        static let frequency = 12
        static let start = 14
        static let loop = 18
        static let end = 22
    }

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < memoryCapacity ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: Int) -> Int32 {
        Int32(bitPattern: UInt32(word(at)) << 16 | UInt32(word(at &+ 2)))
    }
    private static func byte(_ data: [UInt8], _ at: Int) -> UInt8 { at >= 0 && at < data.count ? data[at] : 0 }
    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        (0 ..< 4).reduce(0) { $0 << 8 | UInt32(byte(data, at + $1)) }
    }
    private static func tag(_ data: [UInt8], _ at: Int, _ name: String) -> Bool {
        at >= 0 && at + 4 <= data.count && Array(name.utf8).elementsEqual(data[at ..< at + 4])
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): 'IBLK', one to 128 instruments, and 'ASEQ' at an even
    /// place in the 256 bytes from the sixteenth after them.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard tag(data, 0, "IBLK") else { return false }
        let count = Int(byte(data, 4))
        guard count != 0, count <= 0x80 else { return false }
        let from = 22 + 138 * count
        return stride(from: from, to: from + 256, by: 2).contains { tag(data, $0, "ASEQ") }
    }

    /// The names of the waves' files, as `ExtLoad` loads them: in the order of the instruments in the file, each
    /// wave with a sound (`Instruments/` and its name, to its first nought, without the spaces at its end).
    static func waveNames(_ data: [UInt8]) -> [String] {
        guard tag(data, 0, "IBLK") else { return [] }
        var names: [String] = []
        for i in 0 ..< Int(byte(data, 4)) {
            for w in 0 ..< 3 {
                let wave = 6 + 138 * i + At.waves + At.waveSize * w
                guard long(data, wave + At.sound) != 0 else { continue }
                names.append(name(data, wave))
            }
        }
        return names
    }

    /// A wave's file's name (`CopyName`), to its first nought (within its wave), without spaces at its end.
    private static func name(_ data: [UInt8], _ at: Int) -> String {
        var bytes: [UInt8] = []
        for k in 0 ..< At.waveSize {
            let b = byte(data, at + k)
            if b == 0 { break }
            bytes.append(b)
        }
        while bytes.last == 0x20 { bytes.removeLast() }
        var name = ""
        for b in bytes { name.unicodeScalars.append(Unicode.Scalar(b)) }
        return name
    }

    /// The name of a file, as it is looked for: without regard to case, as the Amiga's disks find them.
    private static func key(_ name: String) -> String {
        var key = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            key.append(scalar.value >= 0x41 && scalar.value <= 0x5A ? Unicode.Scalar(scalar.value + 0x20)! : scalar)
        }
        return String(key)
    }

    /// Where an 8SVX file's sound is (`InstallBody`): it must begin 'FORM', and its BODY is looked for a word at a
    /// time from its ninth byte; the sound is after the BODY's length. Nil for a file that is not one.
    private static func body(_ file: [UInt8]) -> Int? {
        guard tag(file, 0, "FORM") else { return nil }
        var at = 8
        while at + 8 <= file.count {
            if tag(file, at, "BODY") { return at + 8 }
            at += 2
        }
        return nil
    }

    /// Reads the file and its instruments, which are every file of the Instruments folder beside it, by name
    /// (`ExtLoad`, `InitPlayer`): a wave whose file is not among them is not heard (`missingWaves`); a file none of
    /// whose waves is found is refused.
    init(_ data: [UInt8], instruments files: [(name: String, bytes: [UInt8])]) throws(TuneError) {
        fileSize = data.count
        let count = Int(Self.byte(data, 4))
        instrumentCount = count
        channelTable = 6 + 138 * count
        // (`InitPlayer`: 'ASEQ' looked for a word at a time from the channels' table, and its events from after
        // it, to the song's end, which must be in the file.)
        var aseq = channelTable
        while aseq + 4 <= data.count, !Self.tag(data, aseq, "ASEQ") { aseq += 2 }
        sequence = aseq + 4
        var end = sequence
        var ended = false
        while end + 5 <= data.count {
            if data[end + 2] == 0x10, data[end + 3] == 0x2F, data[end + 4] == 0 {
                ended = true
                break
            }
            end += 5
        }
        lastRow = end

        // The waves' files, in the order `ExtLoad` loads them, and where each goes: after the file, each whole, an
        // even number of bytes from the last.
        var byKey = [String: [UInt8]]()
        for file in files { byKey[Self.key(file.name)] = file.bytes }
        let names = Self.isOne(data) ? Self.waveNames(data) : []
        var loaded: [(at: Int, body: Int, bytes: [UInt8])?] = []
        var missing: [String] = []
        var at = (data.count + 15) & ~15
        for name in names {
            if let bytes = byKey[Self.key(name)], let body = Self.body(bytes) {
                loaded.append((at, body, bytes))
                at += (bytes.count + 15) & ~15
            } else {
                loaded.append(nil)
                if !missing.contains(name) { missing.append(name) }
            }
        }
        missingWaves = missing
        var places: [Place] = []
        for (name, file) in zip(names, loaded) {
            if let file { places.append(Place(name: name, sound: file.at + file.body, size: file.bytes.count - file.body)) }
        }
        self.places = places
        silenceAt = at
        memoryCapacity = at + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        for file in loaded {
            guard let file else { continue }
            for (i, b) in file.bytes.enumerated() { memory[file.at + i] = b }
        }

        // (`InstallSamples`: each instrument put in the table at its number, a later one of a number in place of
        // an earlier; then the table's, in order, given the files' sounds in turn, each wave that has one.)
        for i in 0 ..< count {
            let instrument = 6 + 138 * i
            let number = Int(Self.byte(data, instrument))
            if number < 128 { instruments[number] = instrument }
        }
        var next = 0
        var waves = 0
        for instrument in instruments where instrument != 0 {
            for w in 0 ..< 3 {
                let wave = instrument + At.waves + At.waveSize * w
                guard Self.long(data, wave + At.sound) != 0 else { continue }
                let file = next < loaded.count ? loaded[next] : nil
                next += 1
                let sound = file.map { $0.at + $0.body } ?? 0
                if sound != 0 { waves += 1 }
                for k in 0 ..< 4 { memory[wave + At.sound + k] = UInt8(truncatingIfNeeded: sound >> (24 - 8 * k)) }
            }
        }
        waveCount = waves

        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Cinemaware file") }
        guard ended else { throw .malformed("cut short: its song has no end") }
        guard waves > 0 else {
            throw .missingCompanion("Its instruments, which are kept in an Instruments folder beside it, were not given with it.")
        }
        // Its length: the ticks to its end's event, each event's wait (one less than nought, none) added, and the
        // tick it comes on.
        var ticks = 0
        var r = sequence
        while r <= end {
            ticks += max(0, Int(Int16(bitPattern: UInt16(data[r]) << 8 | UInt16(data[r + 1]))))
            r += 5
        }
        lengthClocks = ticks < Self.mostTicks ? UInt64(ticks + 1) * UInt64(Self.tickClocks) : nil
        begin()
    }

    deinit { memory.deallocate() }

    /// `Init` (and `InitSound`): the voices freed, the channels as they begin (each its own number's program), and
    /// the first event's wait.
    private mutating func begin() {
        for v in 0 ..< 4 {
            voices[v].channel = -1
            voices[v].flags = 0
        }
        for c in 0 ..< 16 { channels[c] = Channel(program: UInt8(c)) }
        row = sequence
        wait = word(row)
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song == 0 else { throw .unsupported("there is no song \(song + 1)") }
        voices = .init(repeating: Voice())
        silentTicks = 0
        endings = 0
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = periods
        volumesBefore = volumes
        clock = 0
        begin()
    }

    private mutating func writePeriod<Output: TFMXOutput>(_ v: Int, _ period: UInt16, _ output: inout Output) {
        periods[v] = period
        output.writePeriod(v, period)
    }

    /// `ChangeVolume`: seven bits, times EaglePlayer's volume, 64, over 64.
    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume & 0x7F
        output.writeVolume(v, volumes[v])
    }

    /// Runs the player for a tick (`lbC004438`), telling `output` what Paula is to do, in the order the player
    /// tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        defer {
            // (Kept within a whole number of the beam's lines, of 227 clocks and of 227.5, which is all the
            // waits ask of it: a count of every clock would outgrow a whole number in a browser.)
            clock = (clock + Self.tickClocks) % 103_285
        }
        var at = Self.firstWrite
        if silentTicks != 0 {
            // After the song's end, every voice turned off.
            output.timed(at: at)
            for v in 0 ..< 4 { output.off(v) }
            silentTicks -= 1
            return 17
        }
        // The events that have come, each after the wait for it (one of nought or less, none).
        while Int16(bitPattern: wait) <= 0 {
            event(&output, &at)
            if silentTicks != 0 { return 17 }
            // (The song's end is always come to, at the last: this only makes sure.)
            guard row < lastRow else {
                wait = 1
                break
            }
            row &+= 5
            wait = word(row)
        }
        wait &-= 1
        for v in 0 ..< 4 { make(v, &output, &at) }
        return 17
    }

    /// `lbC00511A`: the event at `row`.
    private mutating func event<Output: TFMXOutput>(_ output: inout Output, _ at: inout Int) {
        let status = byte(row &+ 2)
        let first = byte(row &+ 3)
        let second = byte(row &+ 4)
        let channel = Int(status & 15)
        at += Self.eventClocks
        switch status >> 4 {
        case 1:
            // The song's end (`lbC0050AE`): said, every voice turned off for 25 ticks, and begun again.
            endings += 1
            silentTicks = 25
            begin()
        case 8:
            noteOff(note: first, channel: channel)
        case 9:
            if second == 0 {
                noteOff(note: first, channel: channel)
            } else {
                noteOn(program: channels[channel].program, note: first, velocity: second, channel: channel, &output, &at)
            }
        case 11:
            switch first {
            case 1: channels[channel].modulation = second
            case 7: channels[channel].volume = second
            case 64:
                channels[channel].sustain = second
                pedal(second, channel: channel)
            default: break
            }
        case 12: channels[channel].program = first
        case 14: channels[channel].bend = second
        default: break
        }
    }

    /// The instrument a voice's program plays, nought for none.
    @inline(__always) private func instrument(_ program: UInt8) -> Int { program < 128 ? instruments[Int(program)] : 0 }

    /// `lbC004B9A`: a note begun, on the channel's voice or on the voice most fit to be taken: one free, one let
    /// go, one of the channel's playing the note, one playing the note, and the one playing longest, in that
    /// order of weight; in the voice, the first of the program's waves whose notes take it.
    private mutating func noteOn<Output: TFMXOutput>(program: UInt8, note: UInt8, velocity: UInt8, channel: Int, _ output: inout Output, _ at: inout Int) {
        var v = Int(byte(channelTable &+ channel))
        if v > 3 {
            var best = -1
            var bestScore = 0
            var oldest = 0xFF
            for k in 0 ..< 4 {
                let voice = voices[k]
                var score = 0
                if voice.channel < 0 { score |= 16 }
                if voice.flags & 2 == 0 {
                    score |= 8
                    if Int(voice.channel) == channel, byte(channelTable &+ 15) == 0 { score |= 0x30 }
                }
                if Int(voice.channel) == channel {
                    score |= 4
                    if Int(Int8(bitPattern: voice.note)) == Int(note) { score |= 8 }
                }
                if Int(Int8(bitPattern: voice.note)) == Int(note) { score |= 2 }
                if Int(voice.age) < oldest {
                    oldest = Int(voice.age)
                    score |= 1
                }
                if bestScore < score {
                    bestScore = score
                    best = k
                }
            }
            guard best >= 0 else { return }
            v = best
        }
        let instrument = instrument(program)
        guard instrument != 0 else { return }
        var wave = -1
        for w in 0 ..< 3 {
            let here = instrument + At.waves + At.waveSize * w
            let low = UInt16(bitPattern: Int16(Int8(bitPattern: byte(here + At.low))))
            let high = UInt16(bitPattern: Int16(Int8(bitPattern: byte(here + At.high))))
            if UInt16(note) >= low, UInt16(note) <= high {
                wave = here
                break
            }
        }
        guard wave >= 0 else { return }
        let sound = Int(long(wave + At.sound))
        guard sound != 0 else { return }
        voices[v].channel = -1
        output.timed(at: at + Self.noteFind)
        writePeriod(v, 0x80, &output)
        output.off(v)
        let start = Int(long(wave + At.start))
        let loop = Int(long(wave + At.loop))
        let end = Int(long(wave + At.end))
        if loop >= 0 {
            voices[v].loopAt = sound &+ loop / 2 * 2
            voices[v].loopLength = UInt16(truncatingIfNeeded: (end &- loop) / 2)
        } else {
            voices[v].loopAt = silenceAt
            voices[v].loopLength = 2
        }
        voices[v].loopCount = 2
        voices[v].note = note
        voices[v].program = program
        voices[v].velocity = velocity
        voices[v].frequency = word(wave + At.frequency)
        voices[v].pitchPart = 0
        voices[v].pitch = 0x80
        voices[v].levelPart = 0
        voices[v].level = 0
        voices[v].age = 0xFF
        voices[v].vibrato = 0
        voices[v].vibratoStep = UInt16(byte(instrument + At.vibratoSpeed))
        voices[v].flags = (channels[channel].sustain != 0 ? 1 : 0) + 2
        voices[v].channel = Int8(channel)
        // (Its volume written to Paula herself, not through EaglePlayer's.)
        output.timed(at: at + Self.noteVolume)
        volumes[v] = 0
        output.writeVolume(v, 0)
        output.timed(at: at + Self.noteSound)
        output.takeNextBuffer(v, start: sound &+ start / 2 * 2, length: UInt16(truncatingIfNeeded: (end &- start) / 2))
        at += Self.noteClocks
    }

    /// `lbC004F58`: the channel's voices holding the note let go.
    private mutating func noteOff(note: UInt8, channel: Int) {
        for v in 0 ..< 4 where Int(Int8(bitPattern: voices[v].note)) == Int(note) && Int(voices[v].channel) == channel && voices[v].flags & 2 != 0 {
            release(v)
        }
    }

    /// `lbC004EEA`: the sustain pedal of the channel's voices: kept, for those held; for those let go, its being
    /// lifted lets them go again.
    private mutating func pedal(_ value: UInt8, channel: Int) {
        for v in 0 ..< 4 where Int(voices[v].channel) == channel {
            if voices[v].flags & 2 != 0 {
                voices[v].flags = voices[v].flags & 2 | (value != 0 ? 1 : 0)
            } else if value == 0, voices[v].flags & 1 != 0 {
                release(v)
                voices[v].flags = 0
            }
        }
    }

    /// `lbC004FAC`: a voice let go: its envelopes to their parts for it, and no longer held.
    private mutating func release(_ v: Int) {
        let instrument = instrument(voices[v].program)
        voices[v].levelPart = Int8(bitPattern: byte(instrument + At.levelRelease))
        voices[v].pitchPart = Int8(bitPattern: byte(instrument + At.pitchRelease))
        voices[v].flags &= 1
    }

    /// The voice moved on by a tick (the loop of `lbC00450A`): its envelopes, vibrato, period, loop and volume, and
    /// turned on (or off, if its volume's envelope has ended).
    private mutating func make<Output: TFMXOutput>(_ v: Int, _ output: inout Output, _ at: inout Int) {
        var voice = voices[v]
        let channel = Int(voice.channel)
        guard channel >= 0 else { return }
        if voice.age != 0 { voice.age -= 1 }
        let held = voice.flags & 2 != 0
        let instrument = instrument(voice.program)

        // The volume's envelope: up or down at its part's rate (one, if nought, once let go) to its level, and on
        // to the next part; the voice freed if it comes below one going down.
        let levelPart = Int(voice.levelPart)
        var rate = Int16(byte(instrument &+ At.levelRates &+ levelPart))
        if !held, rate == 0 { rate = 1 }
        let target = Int16(byte(instrument &+ At.levels &+ levelPart))
        var level = Int16(bitPattern: voice.level)
        if target > level {
            level &+= rate
            if target <= level {
                level = target
                voice.levelPart &+= 1
            }
        } else {
            level &-= rate
            if target >= level {
                level = target
                voice.levelPart &+= 1
            }
            if level < 1 {
                voice.channel = -1
                voice.flags &= 1
            }
        }
        voice.level = UInt16(bitPattern: level)
        if held, voice.levelPart > Int8(bitPattern: byte(instrument &+ At.levelLoop)) { voice.levelPart = 0 }
        if voice.levelPart > 7 {
            voice.level = 0
            voice.channel = -1
        }

        // The pitch's envelope, the same, of eight parts, its levels and the pitch unsigned.
        if voice.pitchPart < 8 {
            let part = Int(voice.pitchPart)
            let to = UInt16(byte(instrument &+ At.pitchLevels &+ part))
            let by = UInt16(byte(instrument &+ At.pitchRates &+ part))
            if to > voice.pitch {
                voice.pitch &+= by
                if to <= voice.pitch {
                    voice.pitch = to
                    voice.pitchPart &+= 1
                }
            } else {
                voice.pitch &-= by
                if to >= voice.pitch {
                    voice.pitch = to
                    voice.pitchPart &+= 1
                }
            }
            if held, voice.pitchPart > Int8(bitPattern: byte(instrument &+ At.pitchLoop)) { voice.pitchPart = 0 }
        }

        // The vibrato: a triangle from nought to its depth.
        let speed = UInt16(byte(instrument &+ At.vibratoSpeed))
        voice.vibrato &+= voice.vibratoStep
        if Int16(bitPattern: voice.vibrato) < 0 {
            voice.vibrato = 0
            voice.vibratoStep = speed
        }
        let depth = UInt16(byte(instrument &+ At.vibratoDepth))
        if voice.vibrato > depth {
            voice.vibrato = depth
            voice.vibratoStep = 0 &- speed
        }

        // The pitch, in 240ths of an octave (twenty to a note): the note (60, for an instrument whose bend goes
        // 255) and the instrument's transposition, the vibrato, the envelope and the channel's bend; its period
        // the wave's frequency, times 2^20, over the frequency of the pitch.
        let range = byte(instrument &+ At.bendRange)
        let transpose = Int(Int8(bitPattern: byte(instrument &+ At.transpose)))
        let note = range == 0xFF ? 60 : Int(Int8(bitPattern: voice.note))
        var pitch = Int16(truncatingIfNeeded: (note + transpose) * 20)
        pitch &+= Int16(bitPattern: voice.vibrato) / 5
        pitch &+= Int16(bitPattern: (voice.pitch &- 0x80) &<< 2)
        let bend = UInt16(truncatingIfNeeded: Int(channels[channel].bend) - 0x40)
        let bent = UInt16(truncatingIfNeeded: UInt32(UInt16(truncatingIfNeeded: UInt32(bend) * UInt32(range))) * 20)
        pitch &+= Int16(bitPattern: bent) >> 6
        let step = Int(pitch) % 240
        let octave = UInt32(truncatingIfNeeded: Int(pitch) / 240) & 63
        let base = step >= 0 ? UInt32(Self.frequencies[step]) : 0
        var frequency = octave >= 32 ? 0 : base << octave
        if frequency == 0 { frequency = 1 }
        let numerator = Int64(Int32(bitPattern: UInt32(voice.frequency) << 20))
        let period = UInt16(truncatingIfNeeded: numerator / Int64(Int32(bitPattern: frequency)))
        at += Self.makeClocks
        output.timed(at: at)
        writePeriod(v, period, &output)

        // The loop, on the note's second tick.
        if voice.loopCount != 0 {
            voice.loopCount -= 1
            if voice.loopCount == 0 {
                output.timed(at: at + Self.loopClocks)
                output.takeNextBuffer(v, start: voice.loopAt, length: voice.loopLength)
            }
        }

        // The volume: the velocity and the instrument's (to 127), times the channel's volume, over 128, times the
        // envelope, over 512.
        var velocity = Int16(Int8(bitPattern: voice.velocity)) &+ Int16(byte(instrument &+ At.velocity))
        if velocity > 0x7F { velocity = 0x7F }
        let scaled = UInt16(truncatingIfNeeded: UInt32(channels[channel].volume) * UInt32(UInt16(bitPattern: velocity))) >> 7
        let volume = UInt16(truncatingIfNeeded: UInt32(scaled) * UInt32(voice.level)) >> 9
        at += Self.volumeClocks
        output.timed(at: at)
        writeVolume(v, volume, &output)
        voices[v] = voice

        if voice.channel < 0 {
            output.off(v)
        } else {
            at = afterWait(at + 30)
            output.timed(at: at)
            output.on(v)
            at += Self.onClocks
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

/// Cinemaware's music, played on Paula by `PaulaTickRenderer`.
extension CinemawarePlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Cinemaware")
        info.detail = "\(instrumentCount) instrument\(instrumentCount == 1 ? "" : "s"), \(waveCount) sampled wave\(waveCount == 1 ? "" : "s")"
        if !missingWaves.isEmpty {
            info.shortfalls.append(Shortfall.some(missingWaves.count, one: "sounds was not found in the folder of instruments beside it, and is not heard: ",
                                                  many: "sounds were not found in the folder of instruments beside it, and are not heard: ")
                + Shortfall.list(missingWaves) + ".")
        }
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
