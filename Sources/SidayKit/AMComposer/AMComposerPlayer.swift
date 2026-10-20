// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Marc Hawlitzeck's A.M.Composer 1.2 replayer (1989), as Mr.Larmer of Wanted Team took it from
// the game Magic Jumper and adapted it for EaglePlayer ("A.M.Composer 1.2 player module V1.3 (20 Oct
// 2001)", carried by UADE as players/AM-Composer, whose source UADE also carries as amigasrc/players/
// wanted_team/AMComposer/src/AMComposer 1.2_v4.asm). The labels given are that source's; the player's
// variables are named by their addresses there, from `lbL00059C`.

/// A.M.Composer 1.2, Marc Hawlitzeck's, whose music UnExoticA has from his Magic Jumper and Thomas
/// Porschen's Krymini: not patterns but eight lists of events, each at a row of its own, four of notes
/// (one for each voice) and four of effects (one for each voice), and its own speed, which the module
/// sets as the timer that runs the player.
///
/// The file: "AMC V1.2 REPLAY!"; the row the song ends at (a word at 16); the length of its music (a long
/// at 20); where the eight lists are (longs at 24 to 52, from the file's start); the high byte of the
/// timer (at 57); and from 72 its samples, 16 bytes each (where it is from the file's start, a long, its
/// length in words, and where and how long what it goes on to is, a long and a word; the rest unused),
/// up to the first list. A note's event: its row (a word), its sample (a byte, from 1), its volume (a byte)
/// and its period (a word). An effect's: its row, its command (a byte) and the command's bytes: 1 a period,
/// 2 a slide (how many ticks between its steps, the step, how many ticks it lasts and the period it slides
/// from), 3 a volume, 4 eight periods played in turn, a tick each, for so many ticks, and 7 the Amiga's
/// filter (nought for off).
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It is run by EaglePlayer's timer, which it sets (`InitSound`) to the
/// module's byte, as the high byte of a CIA's timer: (that times 256, and one) times five of Paula's
/// clocks, some 43 to 87 times a second for UnExoticA's files. A row lasts four ticks; at the fourth the
/// row is moved on, and each list whose next event is at it has it played: a note's voice turned off and
/// told its sample, volume and period, and turned on at the start of the next tick, where after a wait
/// for Paula's DMA it is told what it goes on to. At every tick each voice's slide or eight periods move
/// on.
///
/// Each voice's writes are told Paula at their moments in the tick (`TFMXOutput.timed(at:)`), as they fall
/// in UADE: the wait is for the beam to begin nine lines (`DMAWait`).
///
/// A song goes round as its row comes to the song's end: the lists from their starts, the row nought
/// (where none of UnExoticA's has an event, as none has one at the end row). It is said here to have come
/// to its end at the tick after, which is as far from the next row as the song's first tick is from its
/// first, and the song's length is its end row's four ticks each. Where the player would read past the file
/// it reads nought.
struct AMComposerPlayer: ~Copyable {
    /// The file and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the noughts after the file.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// The row the song ends at (the word at 16), the lists' starts, and how many samples it has.
    let endRow: UInt16
    private let starts: InlineArray<8, Int>
    let sampleCount: Int
    /// How long each tick is, in Paula's clocks (see the type's comment).
    let tickClocks: Int

    var songCount: Int { 1 }
    var song: Int { 0 }
    private(set) var endings = 0
    var stops: Int { 0 }
    let lengthClocks: UInt64?

    /// A voice's effects: its slide (`lbW0005D8` on, ten bytes for each voice), the step and the ticks it
    /// lasts, the ticks between its steps and those left before the next, and the period it is at; and its
    /// eight periods (`lbB000600` on, twenty bytes for each voice), the ticks left of them, where it is
    /// among them (in bytes) and the periods.
    struct Effects {
        var slideStep: UInt16 = 0
        var slideTicks: UInt16 = 0
        var slideSpeed: UInt8 = 0
        var slideCount: UInt8 = 0
        var slidePeriod: UInt16 = 0
        var turns: UInt8 = 0
        var turn: UInt16 = 0
        var periods = InlineArray<8, UInt16>(repeating: 0)
    }

    private var effects = InlineArray<4, Effects>(repeating: Effects())
    /// Where each list is (`lbL0005A0` on), where each voice's last sample goes on to (`lbL0005C0` on),
    /// the row (`lbW0005D0`), the voices whose notes began in the last row (`lbB0005D2`), and the tick of
    /// the row (the word at `lbB0005D4`+2).
    private var lists = InlineArray<8, Int>(repeating: 0)
    private var loops = InlineArray<4, Int>(repeating: 0)
    private var row: UInt16 = 0
    private var started: UInt8 = 0
    private var tick: UInt16 = 0
    /// Whether the song has come to its end in the tick just run (and so goes round with the next).
    private var goesRound = false
    /// Whether the Amiga's filter is on, as the tick just run began, and as the player has left it.
    private var filterBefore = false
    private var filter = false
    /// What each of Paula's period and volume registers was last given, and what they held as the tick
    /// just run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the waits.
    private var clock = 0

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (the medians of its dumps of
    /// UnExoticA's files, whose moments are those of its samples, some 80 clocks apart): where it begins,
    /// turning on the voices of the last row's notes (a guess: only the distances between its writes are
    /// heard); after that, each voice's slide or eight periods; after the wait, the look at each voice for
    /// its loop and the writing of it; from there to the row's first look at a voice's list; that look; a
    /// note's volume after its place, its period after its volume, and what follows its period; and an
    /// effect's write.
    static let firstWrite = 100
    static let effectClocks = 60
    static let lookClocks = 10
    static let loopClocks = 32
    static let rowClocks = 150
    static let listClocks = 12
    static let volumeClocks = 45
    static let periodClocks = 65
    static let noteClocks = 96
    static let commandClocks = 60

    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's clocks
    /// and a half) has changed nine times, the first at the next line's start; and some clocks for the code
    /// around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return ((now * 2 / 455 + 9) * 455) / 2 + 160 - clock
    }

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at &+ 2)) }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 { UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2)) }

    /// A long of the file taken as a place in it, as the player adds the file's address to it.
    @inline(__always) private static func place(_ value: UInt32) -> Int { Int(Int32(bitPattern: value)) }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): "AMC V1.2 REPLAY!", and the high word of the
    /// first list's place nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 26 else { return false }
        return Array(data[0 ..< 16]) == Array("AMC V1.2 REPLAY!".utf8) && word(data, 24) == 0
    }

    /// Reads the file and starts its song (it has one: `song` is taken for that one, whatever it is). A file
    /// whose samples run past its end is refused, as `InitPlayer` refuses it ("module too short"), and so is
    /// one whose samples' table (of one sample or more) does not end where its first list begins, within
    /// the file, for which the player would look for its end for ever.
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        endRow = Self.word(data, 0x10)
        var starts = InlineArray<8, Int>(repeating: 0)
        for i in 0 ..< 8 { starts[i] = Self.place(Self.long(data, 0x18 + 4 * i)) }
        self.starts = starts
        // (`InitPlayer`: the samples' table up to the first list, and the furthest any of them reaches.)
        let first = starts[0]
        let whole = first >= 0x58 && first <= data.count && (first - 0x48) % 16 == 0
        var reach = 0
        var count = 0
        if whole {
            for at in stride(from: 0x48, to: first, by: 16) {
                reach = max(reach, Self.place(Self.long(data, at)) &+ 2 * Int(Self.word(data, at + 4)))
                count += 1
            }
        }
        sampleCount = count
        // (A timer of nought, which none has, is taken as $100.)
        let timer = data.count > 0x39 ? max(1, Int(data[0x39])) : 1
        tickClocks = (timer * 256 + 1) * 5
        lengthClocks = UInt64(endRow == 0 ? 0x1_0000 : Int(endRow)) * 4 * UInt64(tickClocks)
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not an A.M.Composer 1.2 module") }
        guard whole else { throw .malformed("its table of samples does not end where its music begins") }
        guard reach <= data.count else { throw .malformed("the module is cut short") }
        start()
    }

    deinit { memory.deallocate() }
}

// MARK: - Playing

extension AMComposerPlayer {
    mutating func select(song _: Int) throws(TuneError) { start() }

    /// `Init`: the lists from their starts, at row nought, and every voice's effects over. (The first row
    /// played is the first, at the fourth tick.)
    private mutating func start() {
        lists = .init(repeating: 0)
        for i in 0 ..< 8 { lists[i] = starts[i] }
        loops = .init(repeating: 0)
        effects = .init(repeating: Effects())
        row = 0
        started = 0
        tick = 0
        goesRound = false
        filter = false
        filterBefore = false
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = .init(repeating: 0)
        volumesBefore = .init(repeating: 0)
        clock = 0
        endings = 0
    }

    /// The player's interrupt (`Play`), for a tick: the voices of the last row's notes turned on; each
    /// voice's slide and eight periods moved on; after the wait, the voices turned on told what they go
    /// on to; and at the row's fourth tick, the next row. Returns the tick's length in milliseconds
    /// (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        filterBefore = filter
        if goesRound {
            goesRound = false
            endings += 1
        }
        var at = Self.firstWrite
        output.timed(at: at)
        for v in 0 ..< 4 where started & 1 << UInt8(v) != 0 { output.on(v) }
        for v in 0 ..< 4 {
            var effect = effects[v]
            if effect.slideTicks != 0 {
                effect.slideTicks &-= 1
                if effect.slideTicks != 0 {
                    effect.slideCount &-= 1
                    if effect.slideCount == 0 {
                        effect.slideCount = effect.slideSpeed
                        effect.slidePeriod &-= effect.slideStep
                        at += Self.effectClocks
                        write(v, period: effect.slidePeriod, at: at, &output)
                    }
                }
            }
            if effect.turns != 0 {
                effect.turns &-= 1
                at += Self.effectClocks
                write(v, period: effect.periods[Int(effect.turn >> 1) & 7], at: at, &output)
                effect.turn &+= 2
                if effect.turn == 0x10 { effect.turn = 0 }
            }
            effects[v] = effect
        }
        at = afterWait(at)
        for v in 0 ..< 4 {
            at += Self.lookClocks
            guard started & 1 << UInt8(v) != 0 else { continue }
            output.timed(at: at)
            output.takeNextBuffer(v, start: buffer(long(loops[v])), length: word(loops[v] &+ 4))
            at += Self.loopClocks
        }
        started = 0
        tick &+= 1
        if tick == 4 {
            tick = 0
            at += Self.rowClocks
            nextRow(&at, &output)
        }
        clock += tickClocks
        return 20
    }

    /// A place the player gives Paula, from the file's start; one past the memory is the silence.
    private func buffer(_ value: UInt32) -> Int {
        let at = Self.place(value)
        return at >= 0 && at < memoryCapacity ? at : silenceAt
    }

    private mutating func write<Output: TFMXOutput>(_ v: Int, period: UInt16, at: Int, _ output: inout Output) {
        periods[v] = period
        output.timed(at: at)
        output.writePeriod(v, period)
    }

    /// The row moved on, and at the song's end the lists back to their starts and the row to nought; then
    /// each list whose next event is at the row has it played: the notes', then the effects'.
    private mutating func nextRow<Output: TFMXOutput>(_ at: inout Int, _ output: inout Output) {
        row &+= 1
        if row == word(0x10) {
            // (`SongEnd`: the song goes round.)
            goesRound = true
            for i in 0 ..< 8 { lists[i] = starts[i] }
            row = 0
            tick = 0
        }
        for v in 0 ..< 4 {
            let event = lists[v]
            at += Self.listClocks
            guard word(event) == row else { continue }
            effects[v].turns = 0
            effects[v].slideTicks = 0
            output.timed(at: at)
            output.off(v)
            started |= 1 << UInt8(v)
            // (The sample's number less one, in a word, times 16: a sample of nought is 65,520 bytes on.)
            let entry = 0x48 &+ Int((UInt16(byte(event &+ 2)) &- 1) << 4)
            output.takeNextBuffer(v, start: buffer(long(entry)), length: word(entry &+ 4))
            loops[v] = entry &+ 6
            volumes[v] = Self.level(UInt16(byte(event &+ 3)))
            at += Self.volumeClocks
            output.timed(at: at)
            output.writeVolume(v, volumes[v])
            at += Self.periodClocks
            write(v, period: word(event &+ 4), at: at, &output)
            lists[v] = event &+ 6
            at += Self.noteClocks
        }
        for v in 0 ..< 4 {
            var event = lists[4 + v]
            guard word(event) == row else { continue }
            let command = byte(event &+ 2)
            event &+= 3
            at += Self.commandClocks
            switch command {
            case 1:
                write(v, period: word(event &+ 1), at: at, &output)
                event &+= 3
            case 2:
                effects[v].turns = 0
                effects[v].slideCount = byte(event)
                effects[v].slideSpeed = byte(event)
                effects[v].slideStep = word(event &+ 1)
                effects[v].slideTicks = word(event &+ 3)
                effects[v].slidePeriod = word(event &+ 5)
                event &+= 7
            case 3:
                volumes[v] = Self.level(word(event &+ 1))
                output.timed(at: at)
                output.writeVolume(v, volumes[v])
                event &+= 3
            case 4:
                effects[v].slideTicks = 0
                effects[v].turns = byte(event)
                for i in 0 ..< 8 { effects[v].periods[i] = word(event &+ 1 &+ 2 * i) }
                effects[v].turn = 2
                event &+= 17
            case 7:
                // (Bit 1 of the CIA's port, the power light: set for nought, which turns the filter off.)
                filter = byte(event) != 0
                output.timed(at: at)
                output.writeLightFilter(filter)
                event &+= 1
            default:
                break
            }
            lists[4 + v] = event
        }
    }

    /// A volume as the player gives it Paula (`Left1` and the rest): times EaglePlayer's volume, 64, in a
    /// word, over 64.
    private static func level(_ volume: UInt16) -> UInt16 { (volume &* 64) >> 6 }

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

/// A.M.Composer, played on Paula by `PaulaTickRenderer`.
extension AMComposerPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    /// The filter as the tick just run began (the player's write to it is told at its moment).
    var lightFilter: Bool { filterBefore }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "A.M.Composer")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "A.M.Composer 1.2's player; \(sampleCount) sample\(plural)"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { tickClocks }
}
