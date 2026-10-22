// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of PumaTracker's player (by Jean-Charles Meyrignac and Pierre-Eric
// Loriaux, 1991), as Wanted Team's EaglePlayer module of it ("PumaTracker player module V1.1 (12 Apr
// 2006)", carried by UADE as `PumaTracker`) has it. The addresses given are of that module's code hunk.

import SidayChips
import SidayFoundation

/// PumaTracker's music (from 1991; in UnExoticA's collection, that of Toki, Liquid Kids, Snow Bros and
/// Elf). A module is its song, a list of orders each giving each of the four voices a pattern of
/// 32 rows and transposes for its notes and instruments, and the order's speed; its patterns, packed;
/// its instruments, each two scripts run on every tick, one for the volume and the wave Paula plays
/// (a sample of the module's ten, or one of the player's 42 waveforms, which it can sweep through),
/// one for the pitch; and its samples.
///
/// This is the player's own code, as it tells Paula what to do, tick by tick: what it tells her is the
/// same as UADE's running of that code for the files of UnExoticA's collection. It owns the memory
/// Paula plays from: the module, room after it, and the waveforms.
///
/// Where the player would read past its tables or the module, or would hang or stop the machine, it is
/// done as said where it is done (see `nowhere`, `wave(_:)`, `period(at:)` and `playScripts`).
struct PumaPlayer: ~Copyable {
    /// The module and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of `memory` are the module's.
    let size: Int
    /// Where Paula starts a voice that has not been told where to: the room after the module.
    var silenceAt: Int { size }
    /// Room after the module, as for any player of `PaulaTickRenderer`'s, for no mixing: far enough
    /// after the module that a sample told a length, however long, reads only silence.
    var mixingAt: Int { size + 0x20000 }
    static let mixingSpace = 2048
    /// Where the player's waveforms are, after the room, with as much silence before them as a sweep
    /// can go back by.
    var wavesAt: Int { mixingAt + Self.mixingSpace + 4096 }
    /// How many bytes Paula may read of `memory`.
    let memoryCapacity: Int

    /// What an instrument or a pattern that the module has not points to: the Amiga's address nought,
    /// where what there is is none of the module's, and is read as noughts, and for Paula as silence.
    /// (No module of UnExoticA's has one.)
    static let nowhere = -0x4000_0000

    /// One voice of the four, as the player keeps it (at $D74, $DB0, $DEC and $E28, 60 bytes each).
    struct Voice {
        /// Where Paula is to play from and for how many words (4 and 8), and the period (10).
        var sample = 0
        var length: UInt16 = 0
        var period: UInt16 = 0
        /// The instrument's volume (13).
        var volume: UInt8 = 0
        /// The row being played: an offset into the module (14).
        var row = 0
        /// How many rows are left before the voice's next (18).
        var rowsLeft: UInt8 = 0
        /// The volume its row gives it, which $40 leaves as it is (21).
        var rowVolume: UInt8 = 0
        /// The order's transposes of the voice's instruments and notes (24, 25).
        var instrumentTranspose: UInt8 = 0
        var noteTranspose: UInt8 = 0
        /// The instrument's two scripts (26, 30) and where in each it is (36, 37).
        var volumeScript = PumaPlayer.nowhere
        var pitchScript = PumaPlayer.nowhere
        var volumeAt: UInt8 = 0
        var pitchAt: UInt8 = 0
        /// Its marks (34): 1, that the volume script's command is to begin; 2, the pitch script's; 4,
        /// that it plays; 8, that what it plays is a sample, played once.
        var flags: UInt8 = 0
        /// A volume ramp's ticks left, its error and the size of its change, and its direction (38 to 42).
        var rampTicks: UInt8 = 0
        var rampError: UInt8 = 0
        var rampChange: UInt8 = 0
        var rampDirection: UInt8 = 0
        /// A pitch command's ticks left (41), and a pitch ramp's period, in 65,536ths, and its step (44,
        /// 48).
        var pitchTicks: UInt8 = 0
        var pitch: Int32 = 0
        var pitchStep: Int32 = 0
        /// A sweep through the waves: its step, where it is and how far it goes (52 to 54).
        var waveStep: UInt8 = 0
        var waveAt: UInt8 = 0
        var waveLimit: UInt8 = 0
        /// The row's slide of the period, added on every tick (56).
        var slide: UInt16 = 0
        /// The note, transposed (58).
        var note: UInt8 = 0
    }

    private(set) var voices = InlineArray<4, Voice>(repeating: Voice())
    /// What was last written to each of Paula's period and volume registers.
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)

    /// The module's header: how many orders, patterns and instruments it has.
    let orderCount: Int
    let patternCount: Int
    let instrumentCount: Int
    /// Where each pattern's rows begin (after its "patt"), and one more: where the marker after the
    /// last is followed (the player's table at $100A).
    private let patternStarts: [Int]
    /// Each instrument's volume and pitch scripts (after its "inst" and "insf"; the table at $F02).
    private let instruments: [(volume: Int, pitch: Int)]
    /// The module's title, from its first twelve bytes.
    let title: String

    /// Where the song is: its order (at $E66), its row (32 when the next order is due, $E65), its speed
    /// and the ticks left until the next row ($796, $E64).
    private var position: UInt8 = 0xFF
    private var rowCounter: UInt8 = 0x20
    private var speed: UInt8 = 2
    private var speedCounter: UInt8 = 1
    /// True from when the player has said that the song has ended, as it begins its last order's last
    /// row, until its first row is played again, when it is counted.
    private var ending = false
    private var begun = false
    private(set) var endings = 0
    /// The song's length, in ticks, as the player plays it through before it begins; nil for one that
    /// does not come back to its beginning in 59 minutes (which none does).
    private(set) var lengthTicks: Int?

    /// True for a file that the player takes for one of its modules (its check, at $55A): no more than
    /// 256 orders, after them "patt", a first pattern whose rows' lengths come to 32 (counted down in a
    /// byte, and given up on when it goes below nought), and "patt" after it.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 80, data[12] == 0 else { return false }
        var at = 80 + (Int(data[13]) + 1) * 14
        guard at + 4 <= data.count, data[at ..< at + 4].elementsEqual(Self.patt) else { return false }
        at += 4
        var rows: UInt8 = 32
        while at + 4 <= data.count {
            let count = data[at + 3]
            guard count != 0 else { return false }
            rows &-= count
            if rows == 0 { return at + 8 <= data.count && data[at + 4 ..< at + 8].elementsEqual(Self.patt) }
            guard rows & 0x80 == 0 else { return false }
            at += 4
        }
        return false
    }

    private static let patt: [UInt8] = Array("patt".utf8)
    private static let inst: [UInt8] = Array("inst".utf8)
    private static let insf: [UInt8] = Array("insf".utf8)

    /// Reads the module, as the player's setting up does ($5AE and $7FC), and starts its song (it has
    /// one: `song` is not looked at).
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        let layout = try Self.layout(data)
        orderCount = layout.orders
        patternCount = layout.patterns.count - 1
        instrumentCount = layout.instruments.count
        patternStarts = layout.patterns
        instruments = layout.instruments
        sampleStarts = layout.sampleStarts
        sampleLengths = layout.sampleLengths
        size = data.count
        title = String(decoding: data[0 ..< 12].prefix { $0 != 0 }, as: UTF8.self)
        memoryCapacity = data.count + 0x20000 + Self.mixingSpace + 4096 + PumaTables.waveforms.count
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        let waves = data.count + 0x20000 + Self.mixingSpace + 4096
        for (i, b) in PumaTables.waveforms.enumerated() { memory[waves + i] = b }
        lengthTicks = playThrough()
        start()
    }

    private struct Layout {
        var orders = 0
        var patterns: [Int] = []
        var instruments: [(volume: Int, pitch: Int)] = []
        var sampleStarts: [Int] = []
        var sampleLengths: [UInt16] = []
    }

    /// Where the module's parts are, as the player's setting up finds them ($5AE and $7FC); or why it
    /// is not played.
    private static func layout(_ data: [UInt8]) throws(TuneError) -> Layout {
        guard isOne(data) else { throw .unsupported("not a PumaTracker module") }
        func word(_ at: Int) -> Int { at >= 0 && at + 2 <= data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : 0 }
        func long(_ at: Int) -> Int { word(at) << 16 | word(at + 2) }
        func marker(_ marker: [UInt8], at: Int) -> Bool {
            at >= 0 && at + 4 <= data.count && data[at ..< at + 4].elementsEqual(marker)
        }
        var layout = Layout()
        layout.orders = word(12) + 1
        let patterns = word(14), instruments = word(16)
        // (Its tables have room for 128 patterns and 32 instruments; for none, it would set up 65,536.)
        guard patterns <= 128 else { throw .unsupported("more patterns than PumaTracker's player has room for") }
        guard (1 ... 32).contains(instruments) else { throw .malformed("PumaTracker module with \(instruments) instruments") }
        // The patterns, each after a "patt", looked for a long word at a time ($854); and the marker
        // after the last.
        var at = 80 + layout.orders * 14
        for _ in 0 ... patterns {
            while at + 4 <= data.count, !marker(patt, at: at) { at += 4 }
            guard at + 4 <= data.count else { throw .malformed("PumaTracker module cut short in its patterns") }
            at += 4
            layout.patterns.append(at)
        }
        // The instruments, each an "inst" and an "insf", looked for a word at a time ($88C).
        at -= 2
        for _ in 0 ..< instruments {
            at += 2
            while at + 4 <= data.count, !marker(inst, at: at) { at += 2 }
            guard at + 4 <= data.count else { throw .malformed("PumaTracker module cut short in its instruments") }
            let volume = at + 4
            at += 2
            repeat { at += 2 } while at + 4 <= data.count && !marker(insf, at: at)
            guard at + 4 <= data.count else { throw .malformed("PumaTracker module cut short in its instruments") }
            at += 4
            layout.instruments.append((volume, at))
        }
        // The player refuses a module whose samples go past its end ($642), or, with none, whose
        // instruments' last "inst" is not in it ($61A).
        layout.sampleStarts = (0 ..< 10).map { long(20 + 4 * $0) }
        layout.sampleLengths = (0 ..< 10).map { UInt16(word(60 + 2 * $0)) }
        if layout.sampleStarts.allSatisfy({ $0 == 0 }) {
            var look = 80, found = 0
            while found <= instruments {
                guard look < data.count else { throw .malformed("PumaTracker module cut short in its instruments") }
                look += 2
                guard word(look - 2) == 0x696E else { continue } // "in"
                look += 2
                guard word(look - 2) == 0x7374 else { continue } // "st"
                found += 1
            }
        } else {
            var end = 0
            for i in 0 ..< 10 where layout.sampleStarts[i] != 0 {
                end = max(end, layout.sampleStarts[i] + Int(layout.sampleLengths[i] & ~1) * 2)
            }
            guard end <= data.count else { throw .malformed("PumaTracker module whose samples go past its end") }
        }
        return layout
    }

    deinit { memory.deallocate() }

    /// The module's ten samples, where they are and how many words long (the tables at $120E and $12DE).
    private let sampleStarts: [Int]
    private let sampleLengths: [UInt16]

    /// The song from its beginning, as the player's setting up of its sound has it ($6C2 and $798),
    /// with its voices as they are when the player is new.
    mutating func start() {
        voices = InlineArray(repeating: Voice())
        paulaPeriods = InlineArray(repeating: 0)
        paulaVolumes = InlineArray(repeating: 0)
        for v in 0 ..< 4 { voices[v].rowsLeft = 1 }
        position = 0xFF
        rowCounter = 0x20
        speed = 2
        speedCounter = 1
        ending = false
        begun = false
        endings = 0
    }

    /// The song is played through, without a sound, for its length; and started again.
    private mutating func playThrough() -> Int? {
        start()
        var none = Unheard()
        var ticks = 0
        while ticks < Self.longest {
            run(&none)
            if endings > 0 { return ticks }
            ticks += 1
        }
        return nil
    }

    /// The most ticks a song is played through for: 59 minutes.
    static let longest = Int(UInt64(59 * 60) * 3_546_895 / UInt64(tickClocks))

    /// How long a tick is, in Paula's clocks: the player is run by UADE's timer, a CIA's, of $376B,
    /// which comes round every 14,188 of its clocks (fifty times a second, and a little less), each
    /// five of Paula's. (Measured in UADE's dumps of Paula's registers: 70,940 between ticks.)
    static let tickClocks = 14188 * 5

    /// One byte of the module, or nought for one outside it.
    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < size ? memory[at] : 0 }

    /// The period of note `n`, read as the player reads its table (at $E68), by a byte offset. What
    /// follows the table there is eight bytes of nought ($EFA), and then the player's table of the
    /// instruments' scripts ($F02), of their addresses, which a few notes beyond the table are played
    /// with (in toki3_1, toki7 and arcade10 of UnExoticA's modules), as a very low period: the module is
    /// taken to be where UADE puts it, at $15000. (An odd note would stop the 68000, which reads words
    /// only at even addresses: it is taken as the even one below it.)
    private func period(at n: UInt8) -> UInt16 {
        let i = Int(n) >> 1
        if i < PumaTables.periods.count { return PumaTables.periods[i] }
        let word = i - PumaTables.periods.count - 4
        guard word >= 0 else { return 0 }
        let entry = word >> 2
        guard entry < instruments.count else { return 0 }
        let address = Self.moduleAddress + (word & 2 == 0 ? instruments[entry].volume : instruments[entry].pitch)
        return UInt16(truncatingIfNeeded: word & 1 == 0 ? address >> 16 : address)
    }

    /// Where UADE puts a module in the Amiga's memory, as its dumps of Paula's registers show.
    static let moduleAddress = 0x15000

    /// Where wave `n` of an instrument's script is and its length in words: one of the module's
    /// samples (0 to 9) or of the player's waveforms (10 to 51). For one beyond those the player reads
    /// on past its tables (no module of UnExoticA's has one): it is played as silence, sixteen words.
    private func wave(_ n: Int) -> (start: Int, length: UInt16) {
        if n < 10 { return (sampleStarts[n], sampleLengths[n]) }
        if n < 52 { return (wavesAt + (n - 10) * 32, 16) }
        return (Self.nowhere, 16)
    }

    /// The scripts of instrument `n` (0 to 31): nought has none, and nor has one beyond the module's.
    private func instrument(_ n: Int) -> (volume: Int, pitch: Int) {
        n >= 1 && n <= instruments.count ? instruments[n - 1] : (Self.nowhere, Self.nowhere)
    }

    /// Runs the player for one tick ($8A8), telling `output` what Paula is to do. Returns the tick's
    /// length in Paula's clocks.
    @discardableResult
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if rowCounter == 0x20 {
            // The next order. After the last, the first: the player's song end ($762).
            // (For 256 orders, the player says so as it begins too, which is not counted.)
            position &+= 1
            if UInt8(truncatingIfNeeded: orderCount) == position {
                position = 0
                for v in 0 ..< 4 { voices[v].flags &= ~4 }
                ending = begun
            }
            begun = true
            rowCounter = 0
            let at = 80 + Int(position) * 14
            for v in 0 ..< 4 {
                let pattern = Int(byte(at + 3 * v))
                voices[v].row = (pattern < patternStarts.count ? patternStarts[pattern] : Self.nowhere) - 4
                voices[v].instrumentTranspose = byte(at + 3 * v + 1)
                voices[v].noteTranspose = byte(at + 3 * v + 2)
                voices[v].rowsLeft = 1
            }
            let speed = byte(at + 12)
            if speed != 0 { self.speed = speed }
        }
        speedCounter &-= 1
        if speedCounter == 0 {
            if ending {
                ending = false
                endings += 1
            }
            rowCounter &+= 1
            speedCounter = speed
            for v in 0 ..< 4 {
                voices[v].rowsLeft &-= 1
                if voices[v].rowsLeft == 0 {
                    voices[v].row += 4
                    playRow(v, &output)
                }
            }
        }
        // Each voice that plays runs its scripts, and Paula's DMA is turned off for the others and on for
        // those ($A70).
        var playing: UInt16 = 0
        for v in 0 ..< 4 where voices[v].flags & 4 != 0 {
            playing |= 1 << v
            playScripts(v, &output)
        }
        for v in 0 ..< 4 where playing & 1 << v == 0 { output.off(v) }
        for v in 0 ..< 4 where playing & 1 << v != 0 { output.on(v) }
        return Self.tickClocks
    }

    /// A voice's next row ($AF0): its note, which starts its instrument afresh, Paula's DMA being
    /// turned off for it; how many rows it lasts; and its command, which sets the row's volume (by its
    /// top three bits, $20 or above $60) or a slide of its period (down $40, up $60).
    private mutating func playRow<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let at = voices[v].row
        let note = byte(at)
        if note != 0 {
            output.off(v)
            voices[v].note = note &+ voices[v].noteTranspose
            let scripts = instrument(Int((byte(at + 1) &+ voices[v].instrumentTranspose) & 31))
            voices[v].volumeScript = scripts.volume
            voices[v].pitchScript = scripts.pitch
            voices[v].flags = 7
            voices[v].volumeAt = 0
            voices[v].pitchAt = 0
        }
        voices[v].rowsLeft = byte(at + 3)
        let parameter = byte(at + 2)
        switch byte(at + 1) & 0xE0 {
        case 0:
            voices[v].rowVolume = 0x40
            voices[v].slide = 0
        case 0x60:
            voices[v].slide = 0 &- UInt16(parameter)
            voices[v].rowVolume = 0x40
        case 0x40:
            voices[v].slide = UInt16(parameter)
            voices[v].rowVolume = 0x40
        default:
            voices[v].rowVolume = parameter
            voices[v].slide = 0
        }
    }

    /// The most commands of a script run in one tick without coming to one that ends it: one more would
    /// be a script going round for ever, which would hang the player, and is taken as its end ($E0).
    static let mostSteps = 64

    /// A voice's two scripts, run for the tick ($B78), and what they make of it told to Paula.
    ///
    /// The volume script's commands: $A0 from, to, ticks, a ramp of the volume; $B0 to, a jump; $C0 wave,
    /// step, limit, the wave Paula plays and a sweep through those that follow it; any other ends the
    /// voice, its volume nought (after this tick). The pitch script's: $A0 from, to, ticks, a ramp of the
    /// period from the note's, by semitones; $B0 to; $D0 by, ticks, the note's period transposed; any
    /// other holds what it has.
    private mutating func playScripts<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        var flags = voices[v].flags
        var at = voices[v].volumeAt
        var steps = 0
        volume: while true {
            steps += 1
            let s = voices[v].volumeScript + Int(at)
            let command = steps > Self.mostSteps ? 0 : byte(s)
            switch command {
            case 0xB0:
                at = byte(s + 1)
            case 0xC0:
                let wave = wave(Int(byte(s + 1)))
                voices[v].waveStep = byte(s + 2)
                voices[v].waveAt = byte(s + 2)
                voices[v].waveLimit = byte(s + 3)
                voices[v].length = wave.length
                // (A sample, at least $50 words long, is played once: see below.)
                if (wave.length &- 0x50) & 0x8000 == 0 { flags |= 8 }
                voices[v].sample = wave.start
                at &+= 4
                flags |= 1
            case 0xA0:
                if flags & 1 != 0 {
                    // The ramp begins: at its first volume, for its ticks and one more.
                    flags &= ~1
                    let from = byte(s + 1), to = byte(s + 2)
                    voices[v].rampTicks = byte(s + 3) &+ 1
                    voices[v].volume = from
                    voices[v].rampError = 0
                    voices[v].rampDirection = 1
                    var change = to &- from
                    if to < from {
                        change = 0 &- change
                        voices[v].rampDirection = 0xFF
                    }
                    voices[v].rampChange = change
                    break volume
                }
                voices[v].rampTicks &-= 1
                if voices[v].rampTicks == 0 {
                    at &+= 4
                    flags |= 1
                    continue
                }
                // A step of the volume in proportion, as a line is drawn: its error kept in a byte, and
                // the loop below ending when it goes below nought (which it never would for ticks of
                // nought, which no ramp left to run has).
                let ticks = byte(s + 3)
                var error = (voices[v].rampError &+ voices[v].rampChange) &- ticks
                if error & 0x80 == 0 {
                    var change: UInt8 = 0
                    var count = 0
                    repeat {
                        change &+= voices[v].rampDirection
                        error &-= ticks
                        count += 1
                    } while error & 0x80 == 0 && count < 256
                    voices[v].volume &+= change
                }
                voices[v].rampError = error &+ ticks
                break volume
            default:
                voices[v].volume = 0
                flags &= ~4
                break volume
            }
        }
        voices[v].volumeAt = at

        at = voices[v].pitchAt
        steps = 0
        pitch: while true {
            steps += 1
            let s = voices[v].pitchScript + Int(at)
            let command = steps > Self.mostSteps ? 0 : byte(s)
            switch command {
            case 0xB0:
                at = byte(s + 1)
            case 0xD0:
                if flags & 2 != 0 {
                    flags &= ~2
                    voices[v].pitchTicks = byte(s + 3)
                    voices[v].period = period(at: byte(s + 1) &+ voices[v].note)
                    break pitch
                }
                voices[v].pitchTicks &-= 1
                if voices[v].pitchTicks != 0 { break pitch }
                flags |= 2
                at &+= 4
            case 0xA0:
                if flags & 2 != 0 {
                    flags &= ~2
                    let base = Int16(bitPattern: period(at: voices[v].note))
                    let from = Int16(Int8(bitPattern: byte(s + 1))) &+ base
                    let to = Int16(Int8(bitPattern: byte(s + 2))) &+ base
                    voices[v].pitchTicks = byte(s + 3)
                    voices[v].period = UInt16(bitPattern: from)
                    voices[v].pitch = Int32(from) << 16
                    voices[v].pitchStep = Self.rampStep(Int32(to &- from), ticks: Int32(voices[v].pitchTicks))
                    break pitch
                }
                voices[v].pitchTicks &-= 1
                if voices[v].pitchTicks == 0 {
                    flags |= 2
                    at &+= 4
                    continue
                }
                voices[v].pitch &+= voices[v].pitchStep
                voices[v].period = UInt16(truncatingIfNeeded: voices[v].pitch >> 16)
                break pitch
            default:
                break pitch
            }
        }
        voices[v].pitchAt = at

        // Paula is told where to play from, how long, the period and the volume ($D12).
        voices[v].period &+= voices[v].slide
        var start = voices[v].sample
        if voices[v].waveStep != 0 {
            // The sweep goes back the way it came at nought and at its limit.
            var step = voices[v].waveStep
            let now = voices[v].waveAt
            if now == 0 || now & 0x80 != 0 || (now &- voices[v].waveLimit) & 0x80 == 0 {
                step = 0 &- step
                voices[v].waveStep = step
            }
            voices[v].waveAt = now &+ step
            start += Int(Int8(bitPattern: voices[v].waveAt)) * 32
        }
        output.takeNextBuffer(v, start: start, length: voices[v].length)
        paulaPeriods[v] = voices[v].period
        if flags & 8 != 0 {
            // A sample is played once, and then its first word over and over.
            flags &= ~8
            voices[v].length = 1
        }
        let volume = (voices[v].volume &+ voices[v].rowVolume) &- 0x40
        paulaVolumes[v] = volume & 0x80 != 0 ? 0 : UInt16(volume & 0x7F)
        voices[v].flags = flags
    }

    /// A pitch ramp's step on each tick, in 65,536ths of the period, as the 68000 divides ($CD8): to
    /// 256ths of the period, or, if that is too big for a word, to whole periods. (For ticks of nought
    /// the 68000 would stop, for its division by nought: the period is held.)
    static func rampStep(_ difference: Int32, ticks: Int32) -> Int32 {
        guard ticks != 0 else { return 0 }
        let fine = (difference << 8) / ticks
        if fine >= -32768, fine <= 32767 { return fine << 8 }
        return Int32(truncatingIfNeeded: (difference / ticks) << 16)
    }

    /// One song.
    var songCount: Int { 1 }
    var song: Int { 0 }
    var stops: Int { 0 }
    /// Paula's period and volume for the voice, as the player last set them (the volume, for any module,
    /// up to 127, of which Paula hears no more than 64).
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] }
}

/// Paula told nothing, for playing a song through for its length.
private struct Unheard: TFMXOutput {
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
}

/// PumaTracker's modules, played on Paula by `PaulaTickRenderer`.
extension PumaPlayer: PaulaTickPlayer {
    var lengthClocks: UInt64? { lengthTicks.map { UInt64($0) * UInt64(Self.tickClocks) } }
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "PUMA")
        info.detail = "PumaTracker"
        info.title = title
        return info
    }

    /// PumaTracker's modules are louder on the Amiga's chip than ProTracker's are, by 3.5 dB in the
    /// middle of UnExoticA's 45, and are turned down by that (2026-10-18).
    var gain: Float { 0.31 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
