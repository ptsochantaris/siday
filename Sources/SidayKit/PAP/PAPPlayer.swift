// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Pierre Adane's player of his packed modules (1990), as Wanted Team's
// EaglePlayer module of it ("Pierre Adane Packer player module V1.1 (22 Dec 2001)", carried by UADE as
// `PierreAdane`) has it. The addresses given are of that module's code.

/// Pierre Adane's packed modules (from 1990, for Pang and Ivanhoe, with Pierre-Eric Loriaux's music):
/// a tracker's module made small for a game, its samples in a file of their own that a game's tunes
/// share (`set.smp` in UnExoticA's collection, `SMP.set` on the Amiga). A module is four lists of
/// patterns, one for each voice, played a position at a time; the patterns, each 64 rows of notes
/// packed by leaving out the empty rows after each; and a table of the samples, their lengths,
/// volumes and loops.
///
/// This is the player's own code, as it tells Paula what to do, tick by tick: what it tells her is the
/// same as UADE's running of that code for the files of UnExoticA's collection. It owns the memory
/// Paula plays from: the module, the samples, and room after them.
struct PAPPlayer: ~Copyable {
    /// The module, the samples and what follows them, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of `memory` are the module's, and where the samples are, after it.
    let size: Int
    let samplesAt: Int
    /// Where Paula starts a voice that has not been told where to: the room after the samples.
    let silenceAt: Int
    /// Room after the samples, as for any player of `PaulaTickRenderer`'s, for no mixing: far enough
    /// after them that a sample told a length, however long, reads only silence.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048
    /// How many bytes Paula may read of `memory`.
    let memoryCapacity: Int

    /// Where a sample the module has none for is: the Amiga's address nought, from which Paula is
    /// taken to play silence.
    static let nowhere = -0x4000_0000

    /// One voice of the four, as the player keeps it (at $B4E, $B6E, $B8E and $BAE, 32 bytes each),
    /// and its period as its slides have it ($BCE to $BD4).
    struct Voice {
        /// The row: its period (0), its sample and command (2) and the command's parameter (3).
        var rowPeriod: UInt16 = 0
        var command: UInt8 = 0
        var parameter: UInt8 = 0
        /// Where Paula is to play from and for how many words (4 and 8); where the sample's loop is and
        /// for how many (10, 14, where 1 is none).
        var sample = 0
        var length: UInt16 = 0
        var loop = 0
        var loopLength: UInt16 = 0
        /// The note's period, for its arpeggio (16), and the sample's volume (18).
        var notePeriod: UInt16 = 0
        var volume: UInt16 = 0
        /// The empty rows left before the next note, how many follow each (24, 26), and where the
        /// pattern's next row is (28) and the voice's list of patterns (30).
        var emptyRows: Int16 = 0
        var gap: Int16 = 0
        var patternAt: UInt16 = 0
        var list: UInt16 = 0
        var slidPeriod: UInt16 = 0
    }

    private(set) var voices = InlineArray<4, Voice>(repeating: Voice())
    /// What was last written to each of Paula's location, period and volume registers.
    private var paulaLocations = InlineArray<4, Int>(repeating: -1)
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)

    /// Where each of the samples is, in the order of the module's table of them ($BD6).
    private let sampleStarts: [Int]

    /// The tick of the row ($C66), the speed ($C68), the row of the pattern ($C62), where the next
    /// position is in the lists ($C60), and the voices whose DMA is turned on after each tick ($C64).
    private var tick: UInt16 = 0
    private var speed: UInt16 = 3
    private var row: UInt16 = 0
    private var position: UInt16 = 2
    private var dma: UInt16 = 0
    /// True from when the player has said that the song has ended, as it begins the last row of its
    /// last position, until its first row is played again, when it is counted.
    private var ending = false
    private(set) var endings = 0
    /// The song's length, in ticks, as the player plays it through before it begins; nil for one that
    /// does not come back to its beginning in 59 minutes.
    private(set) var lengthTicks: Int?

    /// True for a file that the player takes for one of its modules (its check, at $40A): four lists
    /// of patterns whose offsets, in its first four words, are even and in order, the first a word
    /// longer than the others, which are all as long; the first list's first pattern beginning with
    /// $FF; and every pattern of the lists even and no further on than the first list.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 8 else { return false }
        func word(_ at: Int) -> Int { Int(data[at]) << 8 | Int(data[at + 1]) }
        let lists = (0 ..< 4).map { word(2 * $0) }
        for list in lists where list == 0 || list & 0x8001 != 0 { return false }
        let length = lists[3] - lists[2]
        guard length >= 0, lists[2] - lists[1] == length, lists[1] - lists[0] - 2 == length else { return false }
        let end = Int(Int16(truncatingIfNeeded: lists[3] + length))
        guard lists[0] + 2 <= data.count else { return false }
        let first = Int(Int16(truncatingIfNeeded: word(lists[0])))
        guard first >= 0, first < data.count, data[first] == 0xFF else { return false }
        var at = lists[0]
        repeat {
            guard at + 2 <= data.count else { return false }
            let pattern = word(at)
            guard pattern & 0x8001 == 0, pattern <= lists[0] else { return false }
            at += 2
        } while at != end
        return true
    }

    /// Reads the module and its samples, as the player's setting up does ($486 and $772), and starts
    /// its song (it has one: `song` is not looked at).
    init(_ data: [UInt8], samples: [UInt8]?, song _: Int = 0) throws(TuneError) {
        guard Self.isOne(data) else { throw .unsupported("not a Pierre Adane Packer module") }
        guard let samples else {
            throw .missingCompanion("A Pierre Adane Packer module keeps its samples in a file of their own, which was not given with it.")
        }
        // The table of samples, eight bytes each from the eighth, until one whose first byte is $FF:
        // there is room for fifteen in the player's table of where they are.
        var count = 0
        while 8 + count * 8 < data.count, data[8 + count * 8] != 0xFF { count += 1 }
        guard 8 + count * 8 < data.count else { throw .malformed("Pierre Adane Packer module whose table of samples does not end") }
        guard count <= 15 else { throw .unsupported("more samples than Pierre Adane's player has room for") }
        size = data.count
        samplesAt = (data.count + 1) & ~1
        silenceAt = samplesAt + samples.count
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        for (i, b) in samples.enumerated() { memory[samplesAt + i] = b }
        let module = memory
        func word(_ at: Int) -> Int { at + 1 < data.count ? Int(module[at]) << 8 | Int(module[at + 1]) : 0 }
        // One module of Pang's (ingame_09) has a sample's length wrong, which the player mends ($4D2).
        if Int16(truncatingIfNeeded: 2 * word(6) - word(4)) == 0xA2C, word(16) == 0x6FC { module[17] = 0xAE }
        // Each sample's first four bytes are made nought, for its end to be heard as silence ($4FA).
        var starts: [Int] = []
        var at = samplesAt
        for i in 0 ..< count {
            starts.append(at)
            for b in at ..< max(at, min(at + 4, samplesAt + samples.count)) { module[b] = 0 }
            at += 2 * word(8 + 8 * i)
        }
        sampleStarts = starts
        lengthTicks = playThrough()
        start()
    }

    deinit { memory.deallocate() }

    /// The song from its beginning, as the player's setting up of its sound has it ($6BE and $772),
    /// with its voices as they are when the player is new.
    mutating func start() {
        voices = InlineArray(repeating: Voice())
        paulaLocations = InlineArray(repeating: -1)
        paulaPeriods = InlineArray(repeating: 0)
        paulaVolumes = InlineArray(repeating: 0)
        for v in 0 ..< 4 {
            voices[v].list = word(2 * v)
            voices[v].patternAt = word(at: voices[v].list)
        }
        tick = 0
        speed = 3
        row = 0
        position = 2
        dma = 0
        ending = false
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

    /// One byte or word of the module, nought for one outside it; for a word, at an offset of a word,
    /// as the player gives one (to be taken as below nought from $8000).
    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < size ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    @inline(__always) private func word(at offset: UInt16) -> UInt16 { word(Int(Int16(bitPattern: offset))) }

    /// Runs the player for one tick ($702), telling `output` what Paula is to do. Returns the tick's
    /// length in Paula's clocks.
    @discardableResult
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        // A row at each tick that comes to the speed; between them, each voice's command, if its
        // parameter is not nought ($7F8). (A speed set below the tick the row is at is not come to until
        // the tick, a word, goes round.)
        tick &+= 1
        if tick == speed {
            playRow(&output)
        } else {
            for v in 0 ..< 4 where voices[v].parameter != 0 { playCommand(v) }
        }
        // The voices given a note are started, and those whose sample has no loop told to play its
        // first word, after it, over and over ($9F0).
        if dma & 0x8000 != 0 {
            for v in 0 ..< 4 where dma & 1 << v != 0 { output.on(v) }
        }
        for v in 0 ..< 4 where voices[v].loopLength == 1 {
            voices[v].loopLength = 0
            output.takeNextBuffer(v, start: paulaLocations[v], length: 1)
        }
        return Self.tickClocks
    }

    /// A row of each voice ($932), and after the 64th the next position.
    private mutating func playRow<Output: TFMXOutput>(_ output: inout Output) {
        if ending {
            ending = false
            endings += 1
        }
        tick = 0
        dma = 0x8000
        for v in 0 ..< 4 { playRow(v, &output) }
        row = (row + 1) & 0x3F
        guard row == 0 else { return }
        // The next position: after the last, whose first list's pattern is nought, the first, and the
        // player's song end ($75E).
        var pattern = word(at: voices[0].list &+ position)
        if pattern == 0 {
            ending = true
            position = 0
            pattern = word(at: voices[0].list)
        }
        voices[0].patternAt = pattern
        for v in 1 ..< 4 { voices[v].patternAt = word(at: voices[v].list &+ position) }
        position &+= 2
    }

    /// A voice's row ($A50): a note of four bytes, or one of the empty rows that follow it, as many as
    /// the last $FF before a note said. Its sample sets the volume, unless its command does ($C); its
    /// period starts the note, Paula's DMA turned off for it until the tick's end; without one, its
    /// command is done at once.
    private mutating func playRow<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        voices[v].emptyRows &-= 1
        if voices[v].emptyRows >= 0 {
            voices[v].rowPeriod = 0
            voices[v].command = 0
            voices[v].parameter = 0
        } else {
            var at = Int(Int16(bitPattern: voices[v].patternAt))
            if byte(at) == 0xFF {
                voices[v].gap = Int16(byte(at + 1)) - 1
                voices[v].patternAt &+= 2
                at += 2
            }
            voices[v].rowPeriod = word(at)
            voices[v].command = byte(at + 2)
            voices[v].parameter = byte(at + 3)
            voices[v].patternAt &+= 4
            voices[v].emptyRows = voices[v].gap
        }
        let sample = Int(voices[v].command >> 4)
        if sample != 0 {
            let entry = 8 * sample
            voices[v].sample = sample <= sampleStarts.count ? sampleStarts[sample - 1] : Self.nowhere
            voices[v].length = word(entry)
            voices[v].volume = word(entry + 2)
            paulaVolumes[v] = (voices[v].command & 0xF == 0xC ? UInt16(voices[v].parameter) : voices[v].volume) & 0x7F
            voices[v].loop = voices[v].sample + Int(word(entry + 4))
            voices[v].loopLength = word(entry + 6)
            if voices[v].loopLength != 1 {
                // A sample with a loop is played from its loop, the loop's length.
                voices[v].sample = voices[v].loop
                voices[v].length = voices[v].loopLength
            }
        }
        guard voices[v].rowPeriod != 0 else {
            if voices[v].command != 0 || voices[v].parameter != 0 { playCommand(v) }
            return
        }
        output.off(v)
        if voices[v].loopLength == 0 { voices[v].loopLength = 1 }
        voices[v].slidPeriod = voices[v].rowPeriod
        voices[v].notePeriod = voices[v].rowPeriod
        output.takeNextBuffer(v, start: voices[v].sample, length: voices[v].length)
        paulaLocations[v] = voices[v].sample
        paulaPeriods[v] = voices[v].rowPeriod
        dma |= 1 << v
    }

    /// A voice's command ($86E): 0 arpeggio, 1 slide up (to a period of $71 at the least), 2 slide down
    /// (to $358 at the most), by the parameter's lower four bits; $C the volume; $F the speed, from 1 to
    /// 15 (nought leaves it). The others do nothing.
    private mutating func playCommand(_ v: Int) {
        let low = UInt16(voices[v].parameter & 0xF)
        switch voices[v].command & 0xF {
        case 0:
            arpeggio(v)
        case 1:
            var period = voices[v].slidPeriod &- low
            if (period &- 0x71) & 0x8000 != 0 { period = 0x71 }
            voices[v].slidPeriod = period
            paulaPeriods[v] = period
        case 2:
            var period = low &+ voices[v].slidPeriod
            if (period &- 0x358) & 0x8000 == 0 { period = 0x358 }
            voices[v].slidPeriod = period
            paulaPeriods[v] = period
        case 0xC:
            paulaVolumes[v] = UInt16(voices[v].parameter & 0x7F)
        case 0xF:
            if low != 0 { speed = low }
        default:
            break
        }
    }

    /// The arpeggio ($8F2): the note's period, or that of the note as many semitones above it as the
    /// parameter's upper or lower four bits say, by the tick. The player jumps by the tick into a table
    /// of three branches (for ticks 1 to 6) that its code goes on from: for later ticks, at a speed of
    /// more than 7, into the middle of its instructions, which do as `arpeggioShift` has it; the
    /// row's own tick is 0. (No module of UnExoticA's has one.)
    private mutating func arpeggio(_ v: Int) {
        let parameter = voices[v].parameter
        let semitones: Int
        switch tick {
        case 0, 2, 5, 14: semitones = Int(parameter & 0xF)
        case 1, 4, 8, 10: semitones = Int(parameter >> 4)
        case 3, 6: semitones = 0
        case 11: semitones = 22
        case 12: semitones = 1
        case 13: semitones = 26
        case 15: semitones = Int(30 & parameter)
        default: return
        }
        // The note's period is looked for in the table, and the one so many after it taken. (The
        // player would look on past its table for a period not in it, and read on past it for a note
        // beyond: neither is done.)
        guard let at = PAPTables.periods.firstIndex(of: voices[v].notePeriod) else { return }
        paulaPeriods[v] = at + semitones < PAPTables.periods.count ? PAPTables.periods[at + semitones] : 0
    }

    /// One song.
    var songCount: Int { 1 }
    var song: Int { 0 }
    var stops: Int { 0 }
    /// Paula's period and volume for the voice, as the player last set them.
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] }
}

/// The periods of Pierre Adane's player ($C12): three octaves, from $358 down to $71.
enum PAPTables {
    static let periods: [UInt16] = [
        0x0358, 0x0328, 0x02FA, 0x02D0, 0x02A6, 0x0280, 0x025C, 0x023A, 0x021A, 0x01FC, 0x01E0, 0x01C5,
        0x01AC, 0x0194, 0x017D, 0x0168, 0x0153, 0x0140, 0x012E, 0x011D, 0x010D, 0x00FE, 0x00F0, 0x00E2,
        0x00D6, 0x00CA, 0x00BE, 0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F, 0x0078, 0x0071,
    ]
}

/// Pierre Adane's packed modules, played on Paula by `PaulaTickRenderer`.
extension PAPPlayer: PaulaTickPlayer {
    var lengthClocks: UInt64? { lengthTicks.map { UInt64($0) * UInt64(Self.tickClocks) } }
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "PAP")
        info.detail = "Pierre Adane Packer"
        return info
    }

    var gain: Float { 0.46 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}

/// Paula told nothing, for playing a song through for its length.
private struct Unheard: TFMXOutput {
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
}
