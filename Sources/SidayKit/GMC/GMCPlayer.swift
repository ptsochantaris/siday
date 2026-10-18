// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Andreas Tadic's replay routine of Game Music Creator (v1.0), as Delirium and Buggs adapted
// it for DeliTracker and EaglePlayer ("Game Music Creator player module V1.6 (9 May 93)", carried by
// UADE as players/GMC, whose source UADE also carries as amigasrc/players/defect/gmc/GMC.S). The
// addresses given are of that player's code.

/// Game Music Creator, Andreas Tadic's tracker, whose modules some twenty games of UnExoticA's played:
/// fifteen samples, an order of up to a hundred patterns, and patterns of 64 rows of four notes, each
/// a period, a sample and a command: 1 and 2 slide the period up and down on every tick until the
/// voice's next note, 3 sets the volume, 4 breaks the pattern, 5 jumps in the order and 8 sets the
/// speed. (6 and 7, the filter, its player leaves alone.)
///
/// This is the player that came with it, as EaglePlayer's GMC runs it, tick by tick: what it tells
/// Paula is what that player tells her. It runs fifty times a second, its row every sixth tick unless
/// the song sets another speed, and on every tick it slides each voice's period, sets its volume, and
/// starts the notes the row before began: a note is set up with Paula's voice turned off, turned on
/// at the next tick, and told its loop at the one after.
///
/// It owns the memory Paula plays from: the module, and after it the room `PaulaTickRenderer` wants
/// (whose first bytes, nought, are the silence the player's own empty sample is). Its samples follow
/// the patterns, from the highest the order names; a sample's loop is where the module says it was
/// in the editor's memory, counted from where the sample was.
struct GMCPlayer: ~Copyable {
    /// The module and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed, and where the player's own eight bytes of
    /// silence (`MU_empty`, the loop of a sample without one) are: the noughts after the module.
    var silenceAt: Int { fileSize }
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { fileSize + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// The order's length (the long at 240: three bytes of nought and the length).
    private let orderLength: UInt32

    /// Each sample as the player sets it up as the song starts (`MU_calcins`, $568): where it is and
    /// where its loop is, and their lengths in words, and its volume (the header's word at 6, whose
    /// first byte is nought). A sample whose place the module gives as nought is not one, and is left
    /// where it was, at the Amiga's address nought: here, at silence.
    private struct Sample {
        var start = 0, length: UInt16 = 0
        var loop = 0, loopLength: UInt16 = 0
        var volume: UInt16 = 0
    }

    private var samples = InlineArray<15, Sample>(repeating: Sample())

    // The player's variables (`mu_datas`, $A6A), named as its source names them.
    /// For each voice, set once its note has been turned on: its loop is to be told at the next tick.
    private var stop: UInt8 = 0
    private var slide = InlineArray<4, UInt16>(repeating: 0)
    /// The sample of each voice's note just begun, until its loop is told; -1 for none.
    private var channel = InlineArray<4, Int>(repeating: -1)
    private var note = InlineArray<4, UInt16>(repeating: 0)
    private var noteVolume = InlineArray<4, UInt16>(repeating: 0)
    private var songSpeed: UInt16 = 0
    private var songStep: UInt16 = 6
    private var patternCount: UInt16 = 64
    /// Where the next row is, and the order's entry being played, as places in the memory; and the
    /// position, counting from one.
    private var songPointer = 444
    private var tablePosition = 242
    private var positionPointer: UInt32 = 0
    /// What each of Paula's volume and period registers was last given.
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periods = InlineArray<4, UInt16>(repeating: 0)

    /// The order's entries begun since the song last came to its end (see `endings`).
    private var played: [Int] = []
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// How long each tick is: the player is run by EaglePlayer's timer (it has an interrupt and does
    /// not start one of its own), which UADE's runs on a CIA's timer from $376B, its count for fifty a
    /// second (score.s, `cia_timer_base_value`); the timer counts down to nought and starts again, $376C
    /// counts at a fifth of Paula's clock (70,940 of hers, as UADE's ticks are apart).
    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// True for a file the player's check takes (`Check`, $3FA): long enough for a pattern; an order
    /// of no more than a hundred, each a pattern's place (a multiple of 1024), the highest of them
    /// (counted as words with a sign, as the 68000's compare counts them) leaving room for a pattern
    /// before the file's end; and samples of no more than full volume, whose loops are no longer than
    /// they are and, but for a loop of one word or none, lie after their starts. An order of no entries
    /// (which the check reads the rest of the file as, and the player plays for ever without playing a
    /// row) is not taken.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 444 + 1024 else { return false }
        func word(_ at: Int) -> UInt16 { UInt16(data[at]) << 8 | UInt16(data[at + 1]) }
        func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }
        let length = long(240)
        guard length >= 1, length <= 100 else { return false }
        for s in 0 ..< 15 {
            let at = 16 * s
            if word(at + 12) != 2, Int32(bitPattern: long(at + 8) &- long(at)) < 0 { return false }
            if word(at + 6) > 0x40 { return false }
            if Int16(bitPattern: word(at + 4) &- word(at + 12)) < 0 { return false }
        }
        var highest: Int16 = 0
        for i in 0 ..< Int(length) {
            let place = word(244 + 2 * i)
            highest = max(highest, Int16(bitPattern: place))
            if place & 0x3FF != 0 { return false }
        }
        return Int(highest) + 1024 + 444 < data.count
    }

    /// Reads the module and starts its song (it has one: `song` is taken for that one, whatever it is).
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        memoryCapacity = data.count + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, byte) in data.enumerated() { memory[i] = byte }
        orderLength = data.count > 243 ? UInt32(data[243]) : 0
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Game Music Creator module") }

        // The samples begin after the patterns: a pattern after the highest in the order, counted as
        // words with a sign, so that a pattern of 32 or more is not counted (`MU_sizeloop`, $54C).
        // (Covert Action's theme has pattern 63 last in its order, and its samples are where this puts
        // them.) Each is where the last ended, but for one the module gives no place.
        func word(_ at: Int) -> UInt16 { UInt16(data[at]) << 8 | UInt16(data[at + 1]) }
        func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }
        var highest: Int16 = 0
        for i in 0 ..< Int(orderLength) { highest = max(highest, Int16(bitPattern: word(244 + 2 * i))) }
        var at = 444 + Int(highest) + 1024
        for s in 0 ..< 15 {
            let header = 16 * s
            var sample = Sample()
            sample.length = word(header + 4)
            sample.volume = word(header + 6)
            sample.loopLength = word(header + 12)
            if long(header) == 0 {
                sample.start = data.count
                sample.loop = data.count
            } else {
                // (The loop's distance from the start is taken as the Amiga takes it, in 32 bits.)
                sample.start = at
                sample.loop = at + Int(Int32(bitPattern: long(header + 8) &- long(header)))
                if sample.loopLength == 2 { sample.loop = data.count }
                at += 2 * Int(sample.length)
            }
            samples[s] = sample
        }

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

    /// The player's `MU_startmusic` ($4A8): the song from its start, all quiet.
    private mutating func start() {
        tablePosition = 242
        songPointer = 444
        patternCount = 64
        volumes = .init(repeating: 0)
        noteVolume = .init(repeating: 0)
        positionPointer = 0
        songSpeed = 0
        note = .init(repeating: 0)
        slide = .init(repeating: 0)
        stop = 0
        channel = .init(repeating: -1)
        songStep = 6
        periods = .init(repeating: 0)
        played.removeAll(keepingCapacity: true)
        endings = 0
    }

    private func word(_ at: Int) -> UInt16 {
        guard at >= 0, at + 1 < memoryCapacity else { return 0 }
        return UInt16(memory[at]) << 8 | UInt16(memory[at + 1])
    }

    var songCount: Int { 1 }
    var song: Int { 0 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    /// Runs the player for a tick (`MU_playsong`, $5D4), telling `output` what Paula is to do, in the
    /// order the player tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        everyTick(&output)
        songSpeed &+= 1
        guard songStep <= songSpeed else { return 20 }
        songSpeed = 0
        patternCount &+= 1
        if patternCount == 65 { nextPosition() }
        // `MU_playit` ($670): the row's four notes, then the voices with a note turned off.
        // (A jump leaves the player's pointer to the row, a0, pointing into the order, where it has
        // jumped to: the voices after its own read their notes from there, `MU_posjump`, $884.)
        var row = songPointer
        songPointer += 16
        var started: UInt16 = 0
        for v in 0 ..< 4 {
            let at = row + 4 * v
            let command = word(at + 2)
            setInstrument(v, period: word(at), command: command, &started, &output)
            setEffect(v, command)
            if command & 0x0F00 == 0x0500 { row = tablePosition }
        }
        for v in 0 ..< 4 where started & 1 << v != 0 { output.off(v) }
        return 20
    }

    /// `MU_setnewpat` ($60A): on to the next entry of the order; past its end, the song has come to
    /// its end, and starts again (telling EaglePlayer so, `dtg_SongEnd`).
    private mutating func nextPosition() {
        while true {
            positionPointer &+= 1
            if positionPointer > orderLength {
                positionPointer = 0
                tablePosition = 242
                endings += 1
                played.removeAll(keepingCapacity: true)
                continue
            }
            patternCount = 1
            tablePosition += 2
            songPointer = 444 + Int(word(tablePosition))
            // A song that goes round by jumping in its order, not by coming to its end, has come to its
            // end once it comes again to an entry it has played since it began (siday's reckoning: the
            // player itself plays on, telling nothing).
            if played.contains(tablePosition) {
                endings += 1
                played.removeAll(keepingCapacity: true)
            }
            played.append(tablePosition)
            return
        }
    }

    /// `MU_setinstr` ($6C4): a note, for a sample but nought. Paula's voice is told where the sample
    /// is and its period, its volume is set to nought until the next tick sets the sample's, and its
    /// slide stops.
    private mutating func setInstrument<Output: TFMXOutput>(_ v: Int, period: UInt16, command: UInt16, _ started: inout UInt16,
                                                            _ output: inout Output) {
        let number = Int(command >> 12)
        guard number != 0 else { return }
        let sample = samples[number - 1]
        volumes[v] = 0
        channel[v] = number - 1
        output.takeNextBuffer(v, start: sample.start, length: sample.length)
        periods[v] = period
        note[v] = period
        noteVolume[v] = sample.volume
        slide[v] = 0
        started |= 1 << v
    }

    /// `MU_seteffect` ($804): the row's command for the voice.
    private mutating func setEffect(_ v: Int, _ command: UInt16) {
        let parameter = command & 0xFF
        switch command & 0x0F00 {
        case 0x0100: slide[v] = 0 &- parameter
        case 0x0200: slide[v] = parameter
        case 0x0300: noteVolume[v] = parameter
        case 0x0400: patternCount = 64
        case 0x0500:
            // `MU_posjump` ($86A): to entry `parameter` of the order (counting from nought), whose
            // position is then counted from nought, not one; the arithmetic is the player's, which for
            // nought points 64K past the order's start.
            var d4 = UInt32(parameter) &- 1
            positionPointer = d4
            d4 = d4 &+ 1
            let low = (UInt16(truncatingIfNeeded: d4) << 1) &- 2
            d4 = d4 & 0xFFFF_0000 | UInt32(low)
            tablePosition = 244 + Int(d4)
            patternCount = 64
        case 0x0800: songStep = parameter
        default: break
        }
    }

    /// `MU_everyvert` ($8FA), on every tick before the row: each voice's period slid, the loops of the
    /// notes turned on the tick before told, the notes begun at the last row turned on, and the
    /// volumes set.
    private mutating func everyTick<Output: TFMXOutput>(_ output: inout Output) {
        for v in 0 ..< 4 {
            note[v] &+= slide[v]
            periods[v] = note[v]
        }
        for v in 0 ..< 4 where stop & 1 << v != 0 {
            stop &= ~(1 << v)
            let sample = samples[max(0, channel[v])]
            output.takeNextBuffer(v, start: sample.loop, length: sample.loopLength)
            channel[v] = -1
        }
        for v in 0 ..< 4 where channel[v] >= 0 {
            stop |= 1 << v
            output.on(v)
        }
        // (`Setvoice0` to 3, $372: the volume times EaglePlayer's for the voice, 64, over 64, in a word.)
        for v in 0 ..< 4 { volumes[v] = UInt16(truncatingIfNeeded: UInt32(noteVolume[v]) * 64) >> 6 }
    }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as she takes what the player last gave her: seven bits, 64 or
    /// more being full.
    func volume(_ voice: Int) -> UInt16 { min(64, volumes[voice] & 0x7F) }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Game Music Creator, played on Paula by `PaulaTickRenderer`.
extension GMCPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "GMC")
        info.detail = "Game Music Creator"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
