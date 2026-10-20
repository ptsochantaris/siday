// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Fashion's replay routine of 1988 as Wanted Team adapted it for EaglePlayer ("Fashion Tracker
// player module V1.0 (26 June 2004)", carried by UADE as players/FashionTracker, whose source UADE also
// carries as amigasrc/players/wanted_team/FashionTracker-v1.0/FashionTracker.asm). The labels given are
// that source's.

/// Fashion Tracker, the tracker of the Dutch group Fashion, whose music Richard van de Veen wrote for
/// Combine and Mini Golf Plus among UnExoticA's: not a module but a piece of the game, its replay code
/// and its data as they lay in the machine's memory at the address the game put them (the "origin"),
/// which the player finds by the code: its first word of $2379 (a `move.l` to an address) has the origin
/// before it, and its instructions that read the tables have their addresses (`InitPlayer`).
///
/// The tables: for each sample its length in words, where it is, and whether it goes round (a long each);
/// fifteen instruments of two words, a sample and a volume; the order of patterns and its length; and the
/// patterns, of 64 rows of four notes, each a period (nought for none), the instrument in the high four
/// bits of a byte and a command in the low four, and the command's byte. Of the commands only 1, the
/// arpeggio, does anything.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`), and so is run
/// by EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a
/// second and a little less. Its speed is six ticks a row, always. At a row each voice with a note is
/// turned off, told its sample, period and volume, and turned on; a sample that does not go round is told
/// eight bytes of silence to go on to. On the five ticks after, a voice whose row has the arpeggio has its
/// period moved up the table of periods by the command's high four bits, its low four, nought, and the
/// two again. The row read is the one after where the player is (it moves on first), and so a pattern's
/// first row is heard last, after its 63 others, as the 64th of the pattern before it in memory (the first
/// of the next, or what follows the patterns).
///
/// Each voice's writes are told Paula at their moments in the tick (`TFMXOutput.timed(at:)`), as the
/// player's code makes them fall in UADE: a voice's DMA is turned on after `DMAWait`, which waits for the
/// beam to begin nine lines (of 227 of Paula's clocks), and the next voice is begun after another, some
/// 4,700 clocks after the one before (as measured in UADE's dumps).
///
/// A song goes round at the end of its order; it is said here to have come to its end when it comes back
/// to its first pattern (the player tells EaglePlayer so as it begins its last). Where the player would
/// read past the file it reads nought; an arpeggio on a period not in the table, for which the player would
/// search the machine's memory for it, moves nothing.
struct FashionTrackerPlayer: ~Copyable {
    /// The file and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed, and where the player's eight bytes of silence
    /// (`lbL0004BE`, the loop of a sample that does not go round) are: the noughts after the file.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where the game put the file in its memory, and where the player's tables are in the file: the
    /// samples' lengths (`lbL000412`), places (`lbL000432`) and repeats (`lbL000452`), the instruments
    /// (`lbW000476`), the patterns (`lbL000FF0`) and the order (`lbL002480`); and the order's length.
    let origin: UInt32
    private let lengths: Int
    private let places: Int
    private let repeats: Int
    private let instruments: Int
    private let patterns: Int
    private let order: Int
    let orderLength: UInt32
    /// How many samples it has (the tables of lengths and places being one after the other).
    let sampleCount: Int

    // The player's variables, named for what they are.
    /// The tick of the row (`lbB0004D9`), where the row is (`lbL0004EC`, a place in the file) and how far
    /// into the pattern (`lbW0004FA`, $400 to move on to the next), and the next entry of the order
    /// (`lbL0004FC`).
    private var tick: UInt8 = 5
    private var row = 0
    private var rowInPattern: UInt16 = 0x400
    private var position: UInt32 = 0
    /// Each voice's period of its last note (`lbL0004B6`) and its last instrument (`lbL0004E0`, at the
    /// voice's bit).
    private var lastPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var lastInstruments = InlineArray<4, UInt8>(repeating: 0)
    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    /// What they held as the tick just run began (what `PaulaTickRenderer` sets Paula to then, before the
    /// tick's writes are told at their moments).
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the waits.
    private var clock = 0
    /// Whether the song has begun its first pattern (and so comes to its end when it does again).
    private var begun = false

    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (the medians of its dumps of
    /// Combine's and Mini Golf Plus's music): the first voice's after the interrupt begins (a guess: only
    /// the distances between the voices are heard); the next voice's after a voice with no note; a note's
    /// volume after its place; and the next voice's place after a note's loop is told.
    static let firstWrite = 300
    static let voiceClocks = 110
    static let volumeClocks = 156
    static let afterLoopClocks = 468

    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's clocks)
    /// has changed nine times, the first at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 80 - clock
    }

    /// The table of periods (`lbW0003C8`): three octaves, ProTracker's, and a nought.
    static let periodTable: [UInt16] = [
        0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC, 0x1E0, 0x1C5,
        0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0, 0x0E2,
        0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0x078, 0x071,
        0,
    ]

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 { UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2)) }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): the game's replay code as it begins, a
    /// `move.b #$40` and a `nop` and `addq.b` to an address, a 1, a `bne` back and `rts`, and the
    /// `movem.l` that begins its interrupt.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 26 else { return false }
        return long(data, 0) == 0x13FC_0040 && long(data, 8) == 0x4E71_0439 && word(data, 12) == 1
            && long(data, 18) == 0x66F4_4E75 && long(data, 22) == 0x48E7_FFFE
    }

    /// Where the player finds its tables (`InitPlayer`), in its first thousand bytes: the origin, from
    /// the first `move.l` to an address ($2379), the long before it; then each of three instructions,
    /// once: the `move.l (a1),` ($23D1) whose neighbours give the samples' and instruments' tables, the
    /// `mulu #$400` ($C0FC0400) after which the patterns' address is, and the `cmpi.w #$400` ($0C790400)
    /// after which the order's address and length are. Nil for a file the player calls corrupt.
    private static func tables(_ data: [UInt8]) -> (origin: UInt32, values: InlineArray<6, UInt32>, length: UInt32)? {
        var origin: UInt32?
        for at in stride(from: 0, to: 1000, by: 2) where word(data, at) == 0x2379 {
            origin = long(data, at - 4)
            break
        }
        guard let origin else { return nil }
        var values = InlineArray<6, UInt32>(repeating: 0)
        var length: UInt32 = 0
        var count = 1
        for at in stride(from: 0, to: 1000, by: 2) {
            if word(data, at) == 0x23D1 {
                values[0] = long(data, at + 8) &- origin
                values[1] = long(data, at - 6) &- origin
                values[2] = long(data, at + 24) &- origin
                values[3] = long(data, at - 30) &- origin
                count -= 6
            } else if long(data, at) == 0xC0FC_0400 {
                values[4] = long(data, at + 6) &- origin
                count += 3
            } else if long(data, at) == 0x0C79_0400 {
                values[5] = long(data, at + 12) &- origin
                length = long(data, at + 34)
                count += 2
            }
        }
        guard count == 0 else { return nil }
        return (origin, values, length)
    }

    /// Reads the file and starts its song (it has one: `song` is taken for that one, whatever it is).
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        let found = Self.isOne(data) ? Self.tables(data) : nil
        func place(_ k: Int) -> Int { Int(Int32(bitPattern: found?.values[k] ?? 0)) }
        origin = found?.origin ?? 0
        lengths = place(0)
        places = place(1)
        repeats = place(2)
        instruments = place(3)
        patterns = place(4)
        order = place(5)
        orderLength = found?.length ?? 0
        sampleCount = max(0, min(256, (places - lengths) / 4))
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Fashion Tracker file") }
        guard found != nil else { throw .malformed("its player's tables are not where Fashion Tracker's player looks for them") }
        guard orderLength > 0 else { throw .malformed("its order is empty") }

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

    /// `InitSound`: the player's variables cleared, the tick set to the row's last and the pattern to its
    /// end, that the first tick begins the first pattern.
    private mutating func start() {
        tick = 5
        row = 0
        rowInPattern = 0x400
        position = 0
        lastPeriods = .init(repeating: 0)
        lastInstruments = .init(repeating: 0)
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = .init(repeating: 0)
        volumesBefore = .init(repeating: 0)
        clock = 0
        begun = false
        endings = 0
    }

    var songCount: Int { 1 }
    var song: Int { 0 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    /// Runs the player for a tick (`Play`), telling `output` what Paula is to do, in the order the player
    /// tells her: the row, at its sixth tick, or the arpeggios. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        for v in 0 ..< 4 { volumesBefore[v] = min(64, volumes[v]) }
        tick &+= 1
        if tick == 6 { nextRow(&output) } else { arpeggios(&output) }
        clock += Self.tickClocks
        return 20
    }

    /// `lbC000132`: on to the next row, and at a pattern's end to the next entry of the order (back to the
    /// first after the last); each voice with a note (a period) started on it (`lbC00024C`, `lbC0002D2`).
    private mutating func nextRow<Output: TFMXOutput>(_ output: inout Output) {
        if rowInPattern == 0x400 {
            if position == 0 {
                if begun { endings += 1 }
                begun = true
            }
            let at = order &+ Int(position)
            position &+= 1
            if position == orderLength { position = 0 }
            row = patterns &+ Int(byte(at)) * 0x400
            rowInPattern = 0
        }
        row &+= 16
        rowInPattern &+= 16
        tick = 0
        var at = Self.firstWrite
        for v in 0 ..< 4 {
            let note = row &+ 4 * v
            let period = word(note)
            guard period != 0 else {
                at += Self.voiceClocks
                continue
            }
            // The instrument, a word's offset into its table; nought for the voice's last.
            var instrument = (byte(note &+ 2) & 0xF0) >> 2
            if instrument == 0 { instrument = lastInstruments[v] } else { lastInstruments[v] = instrument }
            let entry = instruments &+ Int(instrument)
            let sample = Int(word(entry)) * 4
            let place = Int(Int32(bitPattern: long(places &+ sample) &- origin))
            lastPeriods[v] = period
            output.timed(at: at)
            output.off(v)
            output.takeNextBuffer(v, start: place, length: word(lengths &+ sample &+ 2))
            periods[v] = period
            output.writePeriod(v, period)
            // (`ChangeVolume`: seven bits, times EaglePlayer's volume, 64, over 64.)
            volumes[v] = word(entry &+ 2) & 0x7F
            output.timed(at: at + Self.volumeClocks)
            output.writeVolume(v, min(64, volumes[v]))
            let on = afterWait(at + Self.volumeClocks)
            output.timed(at: on)
            output.on(v)
            let after = afterWait(on)
            // (`lbC0002FA`: a sample but one whose repeat is 1 goes on to silence.)
            if byte(repeats &+ sample &+ 3) != 1 {
                output.timed(at: after)
                output.takeNextBuffer(v, start: silenceAt, length: 4)
            }
            at = after + Self.afterLoopClocks
        }
    }

    /// `lbC0000F4`, on the five ticks between rows: for each voice whose row has command 1, its period (its
    /// row's, or its last note's for a row without one) moved up the table by the command byte's high four
    /// bits (the first and fourth ticks), its low four (the second and fifth), or not at all (the third).
    private mutating func arpeggios<Output: TFMXOutput>(_ output: inout Output) {
        for v in 0 ..< 4 {
            output.timed(at: Self.firstWrite + Self.voiceClocks * v)
            let note = row &+ 4 * v
            guard byte(note &+ 2) & 15 == 1 else { continue }
            let period = word(note) != 0 ? word(note) : lastPeriods[v]
            let parameter = byte(note &+ 3)
            let steps: Int
            switch tick {
            case 1, 4: steps = Int(parameter >> 4)
            case 2, 5: steps = Int(parameter & 15)
            case 3:
                periods[v] = period
                output.writePeriod(v, period)
                continue
            default: continue
            }
            // (`lbC000394`: the period found in the table, and the one so many after it; past the table,
            // nought.)
            guard let at = Self.periodTable.firstIndex(of: period) else { continue }
            periods[v] = at + steps < Self.periodTable.count ? Self.periodTable[at + steps] : 0
            output.writePeriod(v, periods[v])
        }
    }

    /// Paula's period for the voice as the tick just run began (its writes in the tick are told at their
    /// moments).
    func period(_ voice: Int) -> UInt16 { periodsBefore[voice] }
    /// Paula's volume for the voice as the tick just run began, as she takes what the player gave her:
    /// seven bits, 64 or more being full.
    func volume(_ voice: Int) -> UInt16 { volumesBefore[voice] }
    /// What the player last gave Paula's period register for the voice.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Fashion Tracker, played on Paula by `PaulaTickRenderer`.
extension FashionTrackerPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Fashion Tracker")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Fashion's tracker, the game's own replayer; \(sampleCount) sample\(plural)"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
