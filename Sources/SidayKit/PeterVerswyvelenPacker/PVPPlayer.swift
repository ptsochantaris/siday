// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the replay routine of the game Ziriax (Whiz Kidz, 1989), as Wanted Team adapted it for
// EaglePlayer ("Peter Verswyvelen Packer player module V1.1 (22 Aug 2002)", carried by UADE as
// players/PeterVerswyvelen, whose source UADE also carries as amigasrc/players/wanted_team/
// PeterVerswyvelenPacker/src/Peter Verswyvelen Packer_2.asm). The labels given are that source's, which
// are those of the game's code.

/// Peter Verswyvelen's packer, in which Tomas Dahlgren's music of Ziriax and Zarathrusta was kept: a
/// Soundtracker module packed into tracks of sixteen rows. It has 31 samples of eight bytes (a length,
/// a volume, a loop's start and its length, in words); then the count of tracks, the count of steps of
/// the song, the step it goes round to and the size of the tracks; where each track is; the steps, four
/// tracks each (a voice's each), four steps making a pattern of the module it was; the tracks; and the
/// samples. A row of a track is four bytes: the sample (five bits), whether the row is played again on
/// the rows it is followed by (one), the period (ten), how many rows of nothing (or of it again) follow
/// it, and a command and its parameter: 0 arpeggio, 1 and 2 slides, 3 a slide to the note, 4 vibrato,
/// A a slide of the volume, B a jump, C the volume, D on to the next pattern, E the filter and F the
/// speed.
///
/// This is the game's player, as Wanted Team's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It is not ProTracker's, nor quite Soundtracker's: its vibrato only
/// ever lowers the note, by twice as much; its arpeggio goes on with the first note it adds after the
/// sixth tick; a row played again sets the volume and period back to what they were as it began. It sets
/// no timer of its own (it has only `DTP_Interrupt`), and so is run by EaglePlayer's, which UADE runs
/// from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second and a little less.
///
/// It owns the memory Paula plays from: the module, and after it the room `PaulaTickRenderer` wants,
/// whose noughts are where a voice with nothing to play is pointed. Where the player would read outside
/// the module (a module that is not what it says) it reads nought.
struct PVPPlayer: ~Copyable {
    /// The module and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    var silenceAt: Int { fileSize }
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { fileSize + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// How many samples have a sound (`MI_Samples`).
    let sampleCount: Int
    /// Where the steps, the tracks and each sample are, as `InitSong` works them out (with the 68000's
    /// words, which a module of sane sizes never overflows).
    private var steps = 0
    private var tracks = 0
    private var sampleStarts = InlineArray<31, Int>(repeating: 0)
    /// The end of the steps (10(A5)) and the step the song goes round to ($FC), in bytes of the steps.
    private var stepsEnd: UInt16 = 0
    private var restart: UInt16 = 0

    /// One voice, as the player keeps it ($2E bytes each, from 152 into its variables), named by what
    /// its fields are, at their offsets.
    private struct Voice {
        /// Where its track is read next (0).
        var track = 0
        /// The row's period (6, nought for none) and sample (8).
        var notePeriod: UInt16 = 0
        var sample: UInt16 = 0
        /// The rows left to pass before the next is read (10), and whether they play the row again (11).
        var skip: Int8 = 0
        var repeats = false
        /// The command, its parameter, and the parameter's low and high four bits (12 to $10).
        var command: UInt8 = 0
        var parameter: UInt8 = 0
        var low: UInt16 = 0
        var high: UInt16 = 0
        /// The sample's sound, its length, its volume, and its loop and the loop's length ($12 to $20).
        var start = 0
        var length: UInt16 = 0
        var volume: UInt16 = 0
        var loop = 0
        var loopLength: UInt16 = 0
        /// The volume and period as the row began ($1A, $24), and the period ($22).
        var savedVolume: UInt16 = 0
        var period: UInt16 = 0
        var savedPeriod: UInt16 = 0
        /// The slide to a note: down in period ($28), its speed ($29) and the period it goes to ($2A).
        var slidesDown = false
        var slideSpeed: UInt8 = 0
        var target: UInt16 = 0
        /// The vibrato's command and where it is in its wave ($2C, $2D).
        var vibrato: UInt8 = 0
        var vibratoAt: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The ticks a row lasts and the count of them (6(A5), 7(A5)); where in the steps the next is
    /// (8(A5)); the rows left of the step (12(A5)); the voices whose DMA the row turns on (14(A5)).
    private var speed: UInt8 = 6
    private var count: UInt8 = 0
    private var stepAt: UInt16 = 0
    private var rowsLeft: Int16 = 0
    private var started: UInt16 = 0
    /// What each of Paula's period and volume registers was last given, and the Amiga's filter.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private(set) var lightFilter = false

    /// Whether the player has gone round to the step it restarts at, which it tells EaglePlayer as it
    /// begins the song's last step (`SongEnd`); the song's end is counted where it starts again.
    private var wrapped = false
    /// The steps begun since the song last came to its end, one bit for each place in the steps.
    private var begun = [UInt64](repeating: 0, count: 1024)
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// The periods the arpeggio finds its notes among (`lbW000972`): three octaves of Soundtracker's, and
    /// two noughts (past which the 68000 would read on into whatever followed the player; here, nought).
    private static let periodTable: [UInt16] = [
        0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC, 0x1E0, 0x1C5,
        0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0, 0x0E2,
        0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0x078, 0x071, 0, 0,
    ]
    /// The vibrato's wave (`lbW000952`): half of a sine, from nought up to 255 and down.
    private static let sine: [UInt8] = [
        0x00, 0x18, 0x31, 0x4A, 0x61, 0x78, 0x8D, 0xA1, 0xB4, 0xC5, 0xD4, 0xE0, 0xEB, 0xF4, 0xFA, 0xFD,
        0xFF, 0xFD, 0xFA, 0xF4, 0xEB, 0xE0, 0xD4, 0xC5, 0xB4, 0xA1, 0x8D, 0x78, 0x61, 0x4A, 0x31, 0x18,
    ]

    @inline(__always) private func byte(_ a: Int) -> UInt8 { a >= 0 && a < memoryCapacity ? memory[a] : 0 }
    @inline(__always) private func word(_ a: Int) -> UInt16 { UInt16(byte(a)) << 8 | UInt16(byte(a + 1)) }
    /// A word as the 68000 adds it to an address: with its sign.
    @inline(__always) private static func signed(_ w: UInt16) -> Int { Int(Int16(bitPattern: w)) }

    /// True for a file the player's check takes (`Check2`): 31 samples, each with a length, loop and
    /// loop's length not negative and a volume of no more than 64; a count of tracks and of steps of
    /// more than nought (and not negative), the steps even and more than the one the song goes round
    /// to; a size of the tracks of more than nought; and where each track is, even, not negative, no
    /// further than the next nor than the tracks' size.
    static func isOne(_ data: [UInt8]) -> Bool {
        func word(_ a: Int) -> UInt16 { a + 1 < data.count ? UInt16(data[a]) << 8 | UInt16(data[a + 1]) : 0 }
        guard data.count >= 0x102 else { return false }
        for s in 0 ..< 31 {
            let at = 8 * s
            if word(at) & 0x8000 != 0 || word(at + 2) > 0x40 || word(at + 4) & 0x8000 != 0 || word(at + 6) & 0x8000 != 0 { return false }
        }
        let trackCount = Int16(bitPattern: word(0xF8)), stepCount = Int16(bitPattern: word(0xFA))
        let size = Int16(bitPattern: word(0xFE))
        // (`cmp.w (A0)+,D2` and `bls`: the step it goes round to is compared without a sign.)
        guard trackCount > 0, stepCount > 0, stepCount & 1 == 0, UInt16(bitPattern: stepCount) > word(0xFC), size > 0 else { return false }
        // The places of all the tracks but the last (`dbf` from the count less two).
        guard data.count >= 0x100 + 2 * Int(trackCount) else { return false }
        for t in 0 ..< max(1, Int(trackCount) - 1) {
            let place = Int16(bitPattern: word(0x100 + 2 * t))
            if place < 0 || place & 1 != 0 || UInt16(bitPattern: place) > word(0x100 + 2 * t + 2) || place > size { return false }
        }
        return true
    }

    /// Reads the module and starts its song (it has one: `song` is taken for that one, whatever it is).
    /// A module whose samples go on past its end is refused, as `InitPlayer` refuses it.
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        memoryCapacity = data.count + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        func word(_ a: Int) -> UInt16 { a >= 0 && a + 1 < data.count ? UInt16(data[a]) << 8 | UInt16(data[a + 1]) : 0 }
        var refusal: TuneError?
        if !Self.isOne(data) { refusal = .unsupported("not a Peter Verswyvelen Packer module") }
        // `InitPlayer`: the samples that have a sound, and the module's size with all of them.
        var sounds = 0, soundWords = 0
        for s in 0 ..< 31 where word(8 * s) != 0 {
            sounds += 1
            soundWords += Int(word(8 * s))
        }
        sampleCount = sounds
        let songSize = 0x100 + 2 * Int(word(0xF8)) + 8 * Int(word(0xFA)) + Self.signed(word(0xFE))
        if refusal == nil, songSize + 2 * soundWords > data.count { refusal = .malformed("it is cut short") }
        if let refusal { throw refusal }

        // `InitSong` (lbC000360): where the steps, tracks and samples are, in the 68000's words; and
        // each sample's first long made nought.
        steps = 0x100 + Self.signed(word(0xF8) &* 2)
        stepsEnd = word(0xFA) &<< 3
        tracks = steps + Self.signed(stepsEnd)
        restart = word(0xFC)
        var at = tracks + Self.signed(word(0xFE))
        for s in 0 ..< 31 {
            for i in 0 ..< 4 where at + i >= 0 && at + i < fileSize { memory[at + i] = 0 }
            sampleStarts[s] = at
            at += Self.signed(word(8 * s) &* 2)
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

    /// The rest of `InitSong`: all quiet, the speed six, the filter off (`bset #1,$BFE001`), and the
    /// first step to be begun at the first tick.
    private mutating func start() {
        voices = .init(repeating: Voice())
        speed = 6
        count = 0
        stepAt = 0
        rowsLeft = 0
        started = 0
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        lightFilter = false
        wrapped = false
        for i in begun.indices { begun[i] = 0 }
        endings = 0
    }

    var songCount: Int { 1 }
    var song: Int { 0 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    /// Runs the player for a tick (`Play`, lbC00044C), telling `output` what Paula is to do, in the order
    /// the player tells her. Returns the tick's length in milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        // (`subq.b` and `bgt`: a count of -128 comes down past nought, not round to 127.)
        let left = Int(Int8(bitPattern: count)) - 1
        count &-= 1
        if left > 0 {
            // lbC00079E: the commands of the tick between rows.
            for v in 0 ..< 4 { between(v) }
            return 20
        }
        count = speed
        started = 0
        rowsLeft &-= 1
        if rowsLeft <= 0 {
            // lbC0004AE: the next step, its four tracks begun.
            rowsLeft = 16
            let at = steps + Self.signed(stepAt)
            begin(step: stepAt)
            var next = stepAt &+ 8
            if Int16(bitPattern: next) >= Int16(bitPattern: stepsEnd) {
                next = restart &<< 3
                wrapped = true
            }
            stepAt = next
            for v in 0 ..< 4 {
                voices[v].track = tracks + Self.signed(word(0x100 + Self.signed(word(at + 2 * v))))
            }
        }
        for v in 0 ..< 4 { row(v, &output) }
        // The voices whose notes began turned on, and told their loops, periods and volumes.
        for v in 0 ..< 4 where started & 1 << v != 0 { output.on(v) }
        for v in 0 ..< 4 where started & 1 << v != 0 {
            output.takeNextBuffer(v, start: voices[v].loop, length: voices[v].loopLength)
            periods[v] = voices[v].period
            volumes[v] = voices[v].volume & 0x7F
        }
        return 20
    }

    /// Notes a step begun: the song has come to its end where it starts again after going round, or
    /// (siday's reckoning, for a jump back) where it comes again to a step it has begun since its start.
    private mutating func begin(step: UInt16) {
        let index = Int(step >> 6), bit = UInt64(1) << UInt64(step & 63)
        if wrapped || begun[index] & bit != 0 {
            endings += 1
            wrapped = false
            for i in begun.indices { begun[i] = 0 }
        }
        begun[index] |= bit
    }

    /// lbC000612: a voice's row. While rows of its last are left to pass, they are rows of nothing (its
    /// command and period put by) or that row again; then its next row is read.
    private mutating func row<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        voices[v].skip &-= 1
        if voices[v].skip >= 0 {
            guard voices[v].repeats else {
                voices[v].notePeriod = 0
                voices[v].command = 0
                voices[v].parameter = 0
                return
            }
            // lbC000628: the row again: its note from the volume and period it began with.
            guard voices[v].notePeriod != 0 else { return }
            voices[v].volume = voices[v].savedVolume
            voices[v].period = voices[v].savedPeriod
            guard voices[v].command != 3 else { return }
            strike(v, voices[v].notePeriod, &output)
            return
        }
        // lbC00064E: the next row.
        let at = voices[v].track
        let first = byte(at)
        let sample = first >> 3
        voices[v].repeats = first & 4 != 0
        voices[v].sample = UInt16(sample)
        if sample != 0 {
            let entry = 8 * Int(sample - 1)
            let start = sampleStarts[Int(sample - 1)]
            voices[v].start = start
            voices[v].length = word(entry)
            voices[v].volume = word(entry + 2)
            let loopStart = word(entry + 4)
            if loopStart != 0 {
                // (A loop from within the sample: the sound played as far as the loop's end.)
                voices[v].loopLength = word(entry + 6)
                voices[v].length = word(entry + 6) &+ loopStart
                voices[v].loop = start + Int(loopStart &* 2)
            } else {
                voices[v].loop = start
                voices[v].loopLength = word(entry + 6)
            }
        }
        let period = word(at) & 0x3FF
        let third = byte(at + 2)
        voices[v].command = third & 15
        voices[v].skip = Int8(third >> 4)
        let parameter = byte(at + 3)
        voices[v].parameter = parameter
        voices[v].track = at + 4
        voices[v].low = UInt16(parameter & 15)
        voices[v].high = UInt16(parameter >> 4)
        voices[v].notePeriod = period
        guard period != 0 else {
            command(v)
            return
        }
        if voices[v].command == 3 {
            // A slide to the note: where to, which way, and how fast (nought, if the row says none).
            voices[v].target = period
            voices[v].slidesDown = Int16(bitPattern: period) < Int16(bitPattern: voices[v].period)
            voices[v].slideSpeed = parameter
            started |= 1 << v
            return
        }
        strike(v, period, &output)
    }

    /// lbC0006F2: a note begun: Paula's voice quietened and turned off, and told the sample; then the
    /// row's command (lbC000720).
    private mutating func strike<Output: TFMXOutput>(_ v: Int, _ period: UInt16, _ output: inout Output) {
        voices[v].period = period
        voices[v].vibratoAt = 0
        volumes[v] = 0
        periods[v] = 1
        output.off(v)
        started |= 1 << v
        output.takeNextBuffer(v, start: voices[v].start, length: voices[v].length)
        command(v)
    }

    /// lbC000720: the volume and period put by as the row has them, and the row's command.
    private mutating func command(_ v: Int) {
        voices[v].savedVolume = voices[v].volume
        voices[v].savedPeriod = voices[v].period
        let parameter = UInt16(voices[v].parameter)
        switch voices[v].command {
        case 11:
            // lbC000750: to the pattern of the parameter, counted from one, four steps a pattern.
            stepAt = (parameter &- 1) &<< 5
            rowsLeft = 0
        case 12:
            setVolume(v, min(parameter, 0x40))
        case 13:
            // lbC000778: on to the next pattern's first step, from the step after this one (so from the
            // last step of a pattern, past the next pattern); past the end, to where the song goes round.
            let next = (stepAt & 0xFFE0) &+ 0x20
            if Int16(bitPattern: next) < Int16(bitPattern: stepsEnd) {
                stepAt = next
            } else {
                stepAt = restart &<< 3
                wrapped = true
            }
            rowsLeft = 0
        case 14:
            // lbC000762: the filter, off for an even parameter, on for an odd.
            lightFilter = parameter & 1 != 0
        case 15:
            speed = UInt8(parameter)
            count = UInt8(parameter)
        default:
            break
        }
    }

    /// lbC000818: the voice's volume, and Paula's.
    private mutating func setVolume(_ v: Int, _ volume: UInt16) {
        voices[v].volume = volume
        volumes[v] = volume & 0x7F
    }

    /// lbC0007D4: a voice's command at a tick between rows.
    private mutating func between(_ v: Int) {
        let voice = voices[v]
        switch voice.command {
        case 0:
            // lbC0008FA: the arpeggio: the note, then a note up by the high four bits, then by the low,
            // as the ticks since the row go 0 (and 3), 1 (and 4, and 6 on), 2 (and 5); the note found as
            // the first of the table the period is no lower than.
            guard voice.parameter != 0 else { return }
            let tick = speed &- count
            let add: UInt16
            switch tick {
            case 0, 3:
                periods[v] = voice.period
                return
            case 2, 5: add = voice.low
            default: add = voice.high
            }
            var found: UInt16 = 0
            for i in 0 ... 36 {
                found = Self.period(Int(add) + i)
                if Int16(bitPattern: voice.period) >= Int16(bitPattern: Self.period(i)) { break }
            }
            periods[v] = found
        case 10:
            // lbC0007F8: the volume slid up by the high four bits, or else down by the low.
            var volume = voice.volume
            if voice.high != 0 {
                volume &+= voice.high
                if Int16(bitPattern: volume) > 0x40 { volume = 0x40 }
            } else {
                volume &-= voice.low
                if Int16(bitPattern: volume) < 0 { volume = 0 }
            }
            setVolume(v, volume)
        case 1:
            var period = voice.period &- UInt16(voice.parameter)
            if Int16(bitPattern: period) < 0x71 { period = 0x71 }
            voices[v].period = period
            periods[v] = period
        case 2:
            var period = voice.period &+ UInt16(voice.parameter)
            if Int16(bitPattern: period) > 0x358 { period = 0x358 }
            voices[v].period = period
            periods[v] = period
        case 3:
            // lbC000870: the slide to the note.
            if voice.parameter != 0 { voices[v].slideSpeed = voice.parameter }
            var period = voice.period
            let target = voice.target
            guard period != target else { return }
            let by = UInt16(voices[v].slideSpeed)
            if !voice.slidesDown {
                period &+= by
                if Int16(bitPattern: target) <= Int16(bitPattern: period) { period = target }
            } else {
                period &-= by
                if Int16(bitPattern: target) >= Int16(bitPattern: period) { period = target }
            }
            voices[v].period = period
            periods[v] = period
        case 4:
            // lbC0008B4: the vibrato, below the note only, its depth over 64.
            if voice.parameter != 0 { voices[v].vibrato = voice.parameter }
            let vibrato = voices[v].vibrato
            let depth = (UInt16(Self.sine[Int((voice.vibratoAt & 0x7F) >> 2)]) * UInt16(vibrato & 15)) >> 6
            voices[v].vibratoAt &+= (vibrato >> 2) & 0x3C
            periods[v] = depth &+ voice.period
        default:
            break
        }
    }

    private static func period(_ i: Int) -> UInt16 { i < periodTable.count ? periodTable[i] : 0 }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as the player last set it.
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Peter Verswyvelen's packer, played on Paula by `PaulaTickRenderer`.
extension PVPPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "PVP")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Peter Verswyvelen Packer; \(sampleCount) sample\(plural)"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
