// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer of Holger Gehrmann's SoundControl ("Soundcontrol 3.0/3.2/4.0/5.0
// player module V1.2 (25 Mar 2002)", carried by UADE as players/SoundControl, whose source UADE also
// carries as amigasrc/players/wanted_team/Soundcontrol/src/Soundcontrol_v3.asm). The player has four replay
// routines in it, each taken from a game: 3.0's from Dynatech (its UNDERWATER), 3.2's from Dynatech (its
// ELEVEN6), 4.0's from Hot Numbers Deluxe and 5.0's from Biing! (its "Bipro v1.01" file). The names given
// are that source's labels.

import SidayChips
import SidayFoundation

/// Holger Gehrmann's SoundControl, the music system he wrote first for the VIC-20 in 1982 and used on the
/// C64, the PC and the Amiga, as the Amiga's games had it: in UnExoticA's collection his own music for
/// Dynatech, Domination, Dyter-07, Hot Numbers and Sexy Droids, and Biing!; Allan Pedersen's for North Sea
/// Inferno; and Silvio Tognazzi's for Penthouse Hot Numbers Deluxe.
///
/// A module is one file, its samples in it. After 16 bytes of its name, four longs give the sizes of its
/// four parts, and a word its version (2 or 3, and 3 for any with the fourth part), and another its tempo; then,
/// from 64, its patterns (a table of 256 words, the offset of each pattern from the table, and the
/// patterns, each 16 bytes and then rows of four bytes: a note, how many steps it lasts, a sample or an
/// instrument, and a volume); its samples (a table of 256 longs, the offset of each from the table, and
/// the samples, each 64 bytes of its name, length, loop and transposition, and its sound); its list of
/// positions, twelve bytes each, two for each of six tracks, the first the track's pattern (the tracks
/// four voices', an unused one's and, from 3.2 on, one's that transposes them); and from 4.0 on, its instruments (a table of 256 words, and each 48
/// bytes of a volume envelope and then a list of commands, six bytes each, that set its sample and play
/// it, change its period and volume, wait and go round).
///
/// Which routine a module is played by the player tells by its size, as it does the songs it has: one,
/// except in the files of UnExoticA's collection that it knows (its "fix for NUMBER9" and the like), the
/// songs of which it starts and ends at positions it has for them. A module with no instruments is 3.0's,
/// or 3.2's if it is Dynatech's DYNATSONG or ELEVEN6; one with them is 5.0's, or 4.0's if it is one of Hot
/// Numbers Deluxe's three. This plays each as that routine does, tick by tick, as it tells Paula what to
/// do: 3.0, two steps of the song in every three of the host's ticks, and 3.2 three in every four; 4.0 and
/// 5.0, the song's steps at its tempo, and their instruments' commands and volume envelopes at every tick.
///
/// It owns the memory Paula plays from: the routines' tables and voices where it has put them (below
/// $13000), and the module at $13000, where UADE puts it, with room after it. The routines change the
/// module as they play (they clear the first long of each sample as it is started, to go round on as
/// silence), and so each song starts from the module as it was given.
///
/// A song ends where the player tells EaglePlayer it has (`SongEnd`): when it comes to its last position,
/// and goes back to its first.
struct SoundControlPlayer: ~Copyable {
    /// The memory Paula plays from: the Amiga's from nought, past the module.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// The module as it was given, put back at each song's start.
    private let module: [UInt8]

    /// Where UADE puts the module (as its dump of Paula's writes shows, by the places of the samples).
    static let moduleAt: UInt32 = 0x13000
    /// Room after the module, read as silence by a voice told a length that runs past it.
    private static let room = 0x20000 + 2048

    /// Where Paula starts a voice that has not been told where to: in the room after the module.
    var silenceAt: Int { Int(Self.moduleAt) + module.count + 1024 }
    var mixingAt: Int { silenceAt }

    /// The four routines.
    enum Version: CustomStringConvertible {
        case v30, v32, v40, v50

        var description: String {
            switch self {
            case .v30: "3.0"
            case .v32: "3.2"
            case .v40: "4.0"
            case .v50: "5.0"
            }
        }
    }

    let version: Version
    /// The module's size as `InitPlayer` works it out (`CalcSize`): its header and its four parts.
    let calculatedSize: UInt32
    let title: String
    let songCount: Int
    private(set) var song = 0
    /// The samples the player's module information counts.
    let sampleCount: Int

    /// Where the module's parts are: its patterns' table, its samples' table, its positions and its
    /// instruments' table.
    let patternsAt: UInt32
    let samplesAt: UInt32
    let positionsAt: UInt32
    let instrumentsAt: UInt32
    /// The low word of the size of the positions, the end of the song in all but the songs the player
    /// knows; and the tempo, the word at 34.
    let positionsEnd: UInt16
    let headerTempo: UInt16

    // MARK: The routines' own variables

    /// 3.0's and 3.2's table of periods (`lbL017F58`, 256 bytes: eight octaves of sixteen words, the last
    /// three of each nought) and the voices' records after it (`lbL018258`, 40 bytes each), which the two
    /// share; 4.0's and 5.0's periods (`Buffer`, eight octaves of twelve words), and their voices' records
    /// (`lbL00893A` and on, of 200, 74, 74 and 74 bytes). (Places of siday's choosing: see `peek8`.)
    static let periods3At: UInt32 = 0x1000
    static let voices3At: UInt32 = 0x1100
    static let voice3Size: UInt32 = 0x28
    static let periods4At: UInt32 = 0x12000
    static let voices4At: UInt32 = 0x2000
    static let voice4Offsets: InlineArray<4, UInt32> = [0, 200, 274, 348]

    /// The six tracks' places in their patterns (`lbL018358` and the like) and the steps each of the four
    /// voices' and the transposing track's note has left (`lbL018370` and the like).
    var tracks = InlineArray<6, UInt32>(repeating: 0)
    var counters = InlineArray<6, UInt16>(repeating: 0)
    /// The place in the list of positions (in bytes, twelve a position), where the song starts again
    /// and where it ends (`lbW018380`, `lbL018800`, `lbL018804` and the like).
    var position: UInt16 = 0
    var startPosition: UInt16 = 0
    var endPosition: UInt16 = 0
    /// 3.0's and 3.2's counts of the host's ticks and of their halves (`lbW018384` and `lbW01837C`,
    /// `lbW00570C` and `lbW005704`).
    var frames: UInt16 = 0
    var halves: UInt16 = 0
    /// Each voice's transposition, from the transposing track: 3.2's bytes (`lbL005730`), 4.0's and 5.0's
    /// words (`lbL0086A2`, `lbL0664CE`).
    var transposes = InlineArray<4, UInt16>(repeating: 0)
    /// 4.0's and 5.0's tempo and what it has added up to (`lbW008688`, `lbL00868A`), and 5.0's count of
    /// quarter steps (`lbW066480`).
    var tempo: UInt16 = 0
    var tempoSum: UInt16 = 0
    var quarters: UInt16 = 0

    // MARK: Paula, as the routine has written her registers

    private var locations = InlineArray<4, UInt32>(repeating: 0)
    private var lengths = InlineArray<4, UInt16>(repeating: 0)
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)
    private var dmacon: UInt16 = 0
    /// True until the first tick, which tells Paula what the song's start wrote.
    private var starting = false

    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// Why the song stopped, if it did: where the routine would have taken the Amiga down or gone round
    /// for ever.
    var failure: String?
    /// For checks: each write the routine made to Paula's registers in the tick just run (the register's
    /// offset, $A0 to $D8 or DMACON's $96, and the word written), when this is not nil.
    var writes: [(register: UInt16, value: UInt16)]?

    /// The host's tick, fifty a second: the player has an interrupt (`DTP_Interrupt`) and sets no timer of
    /// its own, and UADE runs it on a CIA's timer of $376B (score.s, `cia_timer_base_value`).
    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in ten minutes is taken never to.
    private static let mostTicks = 600 * 50
    /// The most positions a step goes on through without a note (each a step begun again: one whose
    /// tracks all end at once, as a broken module's might, would hang the player), and the most commands
    /// an instrument reads in a tick before it waits (siday's choices: more than any module needs).
    static let mostPositions = 1024
    static let mostCommands = 4096
    /// The samples counted, at most, for the module information (the player's `MI_MaxSamples`).
    private static let mostSamples = 256

    // MARK: The check

    /// True for a file the player's check takes (`Check2`): a version word at 32 of 3, or of 2 with no
    /// instruments; the patterns' part less than 32K and of an even size; and that part ending in $FFFF and
    /// the samples' table beginning with $400, the place of the first sample, after the table.
    static func isOne(_ data: [UInt8]) -> Bool {
        func word(_ at: Int) -> UInt16? { at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : nil }
        func long(_ at: Int) -> UInt32? {
            guard let high = word(at), let low = word(at + 2) else { return nil }
            return UInt32(high) << 16 | UInt32(low)
        }
        switch word(32) {
        case 3: break
        case 2: guard long(28) == 0 else { return false }
        default: return false
        }
        guard word(16) == 0, let patterns = word(18), patterns & 0x8001 == 0 else { return false }
        return word(Int(patterns) + 62) == 0xFFFF && long(Int(patterns) + 64) == 0x400
    }

    // MARK: Making

    /// Reads the module and starts song `song` (counting from nought).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        func word(_ at: Int) -> UInt16 { at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0 }
        func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }
        module = data
        memoryCapacity = Int(Self.moduleAt) + data.count + Self.room
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)

        // (`InitPlayer`.) The parts' places, and the size they add up to, which is to be no more than the
        // file's (as the player compares them, by their signs).
        let patterns = long(16), samples = long(20), positions = long(24), instruments = long(28)
        let size = 64 &+ patterns &+ samples &+ positions &+ instruments
        calculatedSize = size
        patternsAt = Self.moduleAt + 0x40
        samplesAt = patternsAt &+ patterns
        positionsAt = samplesAt &+ samples
        instrumentsAt = positionsAt &+ positions
        positionsEnd = word(26)
        headerTempo = word(34)

        var name = String.UnicodeScalarView()
        for byte in data.prefix(16) {
            if byte == 0 { break }
            name.append(Unicode.Scalar(byte >= 0x20 && byte <= 0x7E ? byte : 0x20))
        }
        title = String(name).trimmed()

        // (`Samp`) The samples: counted by their sizes (each sample's long at 60), from the first, until
        // they add up to the part's size less its table.
        var count = 0, total: UInt32 = 0
        var at = Int(patterns) + 64 + 1084
        repeat {
            let step = long(at)
            at &+= Int(Int32(bitPattern: step))
            total &+= step
            count += 1
        } while Int32(bitPattern: samples &- 1024) > Int32(bitPattern: total) && count < Self.mostSamples
        sampleCount = count

        // Which routine, and how many songs, by the module's size: the player's fixes for the files it
        // knows.
        if instruments == 0 {
            switch size {
            case 126_446: (version, songCount) = (.v30, 3) // NUMBER9
            case 136_612: (version, songCount) = (.v30, 2) // DOMINATION 1
            case 154_704: (version, songCount) = (.v32, 2) // DYNATSONG
            case 103_808: (version, songCount) = (.v32, 1) // ELEVEN6
            default: (version, songCount) = (.v30, 1)
            }
        } else {
            switch size {
            case 54544: (version, songCount) = (.v40, 1) // HNDTITLE
            case 95960: (version, songCount) = (.v40, 2) // HNDONGAME2
            case 81906: (version, songCount) = (.v40, 4) // HNDINTRO
            default: (version, songCount) = (.v50, 1)
            }
        }
        // (Refused only once it is all made.)
        guard Self.isOne(data) else { throw TuneError.malformed("not a SoundControl module") }
        guard Int32(bitPattern: size) <= Int32(data.count) else {
            throw TuneError.malformed("a SoundControl module cut short: its parts add up to \(size) bytes, and it has \(data.count)")
        }
        begin(song)
    }

    deinit { memory.deallocate() }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        begin(song)
    }

    /// Starts song `song`, as a player newly loaded would; and finds how long it is.
    private mutating func begin(_ song: Int) {
        self.song = song >= 0 && song < songCount ? song : 0
        initialise()
        var none = TFMXSilentOutput()
        let logging = writes
        writes = nil
        var ticks = 0
        while endings == 0, stops == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again, or its stop.)
        lengthClocks = endings > 0 || stops > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        writes = logging
        initialise()
    }

    /// The module put back as it was given, the player's variables as its hunk has them, Paula's
    /// registers as they were, and `InitSound` for the song.
    private mutating func initialise() {
        let end = Int(Self.moduleAt) + module.count
        memory.update(repeating: 0, count: Int(Self.moduleAt))
        for (i, byte) in module.enumerated() { memory[Int(Self.moduleAt) + i] = byte }
        (memory + end).update(repeating: 0, count: memoryCapacity - end)
        tracks = .init(repeating: 0)
        counters = .init(repeating: 0)
        transposes = .init(repeating: 0)
        position = 0
        startPosition = 0
        endPosition = positionsEnd
        frames = 0
        halves = 0
        tempo = 0
        tempoSum = 0
        quarters = 0
        // (As UADE's host leaves them: each voice at a word of silence, at the period $96.)
        locations = .init(repeating: UInt32(silenceAt))
        lengths = .init(repeating: 1)
        paulaPeriods = .init(repeating: 0x96)
        paulaVolumes = .init(repeating: 0)
        dmacon = 0
        endings = 0
        stops = 0
        failure = nil
        var none = TFMXSilentOutput()
        switch version {
        case .v30, .v32:
            // (`InitSound`) The songs the player knows start and end at its own positions.
            switch (calculatedSize, song) {
            case (126_446, 0): (startPosition, endPosition) = (0, 0x1E0)
            case (126_446, 1): (startPosition, endPosition) = (0x1E0, 0x2D0)
            case (126_446, _): (startPosition, endPosition) = (0x2D0, 0x3C0)
            case (136_612, 0): (startPosition, endPosition) = (0, 0x144)
            case (136_612, _): (startPosition, endPosition) = (0x174, 0x348)
            case (154_704, 0): (startPosition, endPosition) = (0, 0x150)
            case (154_704, _): (startPosition, endPosition) = (0x150, 0x2E8)
            default: break
            }
            initialise3(&none)
        case .v40:
            initialise4(UInt16(song + songCount), &none)
        case .v50:
            initialise5(&none)
        }
        starting = true
    }

    // MARK: Playing

    /// The player's `DTP_Interrupt` (`Interrupt`): the routine's. Returns the tick's length in
    /// milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if writes != nil { writes = [] }
        if starting {
            // The first tick is the timer's first count, from when the host sets it going after the song's
            // start, whose writes are told as it begins (the voices' places, and their DMA, which 3.0's,
            // 3.2's and 4.0's start turn on): the routine's first tick is at its end.
            starting = false
            for v in 0 ..< 4 {
                tellBuffer(v, &output)
                if dmacon & 1 << UInt16(v) != 0 { output.on(v) }
            }
            return Self.tickClocks * 1000 / 3_546_895
        }
        if failure == nil {
            switch version {
            case .v30, .v32: interrupt3(&output)
            case .v40, .v50: interrupt4(&output)
            }
        }
        if failure != nil, stops == 0 { stops += 1 }
        return Self.tickClocks * 1000 / 3_546_895
    }

    /// The player's `SongEnd`, which tells EaglePlayer the song has come to its end.
    mutating func songEnd() { endings += 1 }

    /// The places of the six tracks' patterns at the position (`lbC0187B6` and the like): the even bytes of
    /// its twelve, each a pattern's number, its place in the patterns' table, and its rows after its 16
    /// bytes; the steps left of each of the four voices' notes cleared, and with them, from 3.2 on, the
    /// fifth track's and the transposing track's.
    mutating func loadTracks() {
        var d0 = UInt32(position)
        for k in 0 ..< 6 {
            let number = UInt32(peek8(positionsAt &+ wide(UInt16(truncatingIfNeeded: d0))))
            let offset = UInt32(peek16(patternsAt &+ 2 * number))
            tracks[k] = patternsAt &+ offset &+ 0x10
            d0 &+= 2
        }
        for k in 0 ..< (version == .v30 ? 4 : 6) { counters[k] = 0 }
    }

    // MARK: The Amiga's memory and Paula's registers

    /// A byte of memory (24 bits of address, as the 68000 has; nought past the machine's memory, and
    /// from Paula's registers).
    func peek8(_ address: UInt32) -> UInt8 {
        let at = Int(address & 0xFF_FFFF)
        return at < memoryCapacity ? memory[at] : 0
    }

    /// A word, or a long: at an odd address, the 68000 takes an address error, which would take the
    /// player down, and the song is stopped (`failure`).
    mutating func peek16(_ address: UInt32) -> UInt16 {
        if address & 1 != 0 { failure = "the routine read a word at an odd address" }
        let at = Int(address & 0xFF_FFFE)
        return at + 1 < memoryCapacity ? UInt16(memory[at]) << 8 | UInt16(memory[at + 1]) : 0
    }

    mutating func peek32(_ address: UInt32) -> UInt32 {
        UInt32(peek16(address)) << 16 | UInt32(peek16(address &+ 2))
    }

    mutating func poke8(_ address: UInt32, _ value: UInt8) {
        let at = Int(address & 0xFF_FFFF)
        if at >> 12 == 0xDFF { return }
        if at < memoryCapacity { memory[at] = value }
    }

    /// A word written: to Paula's registers (DMACON at $DFF096, a voice's from $DFF0A0), told to `output`;
    /// or to memory.
    mutating func poke16<Output: TFMXOutput>(_ address: UInt32, _ value: UInt16, _ output: inout Output) {
        if address & 1 != 0 {
            failure = "the routine wrote a word at an odd address"
            return
        }
        let at = Int(address & 0xFF_FFFE)
        if at >> 12 == 0xDFF {
            paula(UInt16(at & 0x1FE), value, &output)
        } else if at + 1 < memoryCapacity {
            memory[at] = UInt8(value >> 8)
            memory[at + 1] = UInt8(truncatingIfNeeded: value)
        }
    }

    mutating func poke32<Output: TFMXOutput>(_ address: UInt32, _ value: UInt32, _ output: inout Output) {
        poke16(address, UInt16(value >> 16), &output)
        poke16(address &+ 2, UInt16(truncatingIfNeeded: value), &output)
    }

    mutating func poke16(_ address: UInt32, _ value: UInt16) {
        var none = TFMXSilentOutput()
        poke16(address, value, &none)
    }

    mutating func poke32(_ address: UInt32, _ value: UInt32) {
        var none = TFMXSilentOutput()
        poke32(address, value, &none)
    }

    /// A write to Paula's registers, as the hardware takes it: a voice's location (two words, its low
    /// bit not kept) and length are where it goes on from when it next comes round, or where it starts
    /// when its DMA is turned on; DMACON sets or clears the voices' bits as its top bit says.
    private mutating func paula<Output: TFMXOutput>(_ register: UInt16, _ value: UInt16, _ output: inout Output) {
        writes?.append((register, value))
        switch register {
        case 0x096:
            let was = dmacon
            dmacon = value & 0x8000 != 0 ? dmacon | value & 0xF : dmacon & ~(value & 0xF)
            for v in 0 ..< 4 {
                let bit: UInt16 = 1 << UInt16(v)
                if dmacon & bit != 0, was & bit == 0 { output.on(v) }
                if dmacon & bit == 0, was & bit != 0 { output.off(v) }
            }
        case 0x0A0 ..< 0x0E0:
            let v = Int(register - 0xA0) >> 4
            switch register & 0xF {
            case 0x0:
                locations[v] = locations[v] & 0xFFFF | UInt32(value) << 16
                tellBuffer(v, &output)
            case 0x2:
                locations[v] = locations[v] & 0xFFFF_0000 | UInt32(value & 0xFFFE)
                tellBuffer(v, &output)
            case 0x4:
                lengths[v] = value
                tellBuffer(v, &output)
            case 0x6:
                paulaPeriods[v] = value
            case 0x8:
                paulaVolumes[v] = value
            default:
                break
            }
        default:
            break
        }
    }

    private func tellBuffer<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        // (Chip memory is two megabytes at most; a location past the machine's is read as nothing.)
        let at = Int(locations[v] & 0x1F_FFFE)
        output.takeNextBuffer(v, start: min(at, memoryCapacity), length: lengths[v])
    }

    /// Paula's period for the voice, and her volume, as the routine last wrote them.
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] }

    /// The routines' table of periods, from which each makes its own, an octave of it shifted down two
    /// places and then each next a place more (`lbL0183A8`, `lbW0086AE` and the like).
    static let octave: [UInt16] = [0xD600, 0xCA00, 0xBE80, 0xB400, 0xA980, 0xA000, 0x9700, 0x8E80, 0x8680, 0x7F00,
                                   0x7800, 0x7100, 0x6B00, 0, 0, 0]
}

/// SoundControl's music, played on Paula by `PaulaTickRenderer`.
extension SoundControlPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "SoundControl")
        info.title = title
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Holger Gehrmann's SoundControl \(version); \(sampleCount) sample\(plural)"
        return info
    }

    /// SoundControl's music is louder on the Amiga's chip than ProTracker's is, by 3.7 dB in the middle of
    /// its twenty tunes in UnExoticA's collection (by BS.1770 loudness, over their first minute, against 40
    /// ProTracker modules), and is turned down by that (2026-10-25).
    var gain: Float { 0.33 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}

/// A word as the 68000 takes it as an index or a displacement: sign-extended to a long.
private func wide(_ value: UInt16) -> UInt32 { UInt32(bitPattern: Int32(Int16(bitPattern: value))) }
