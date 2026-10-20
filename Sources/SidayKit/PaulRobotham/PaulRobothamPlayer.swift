// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Pete Barnett's music driver as Paul Robotham's music used it (the game Starlord's, with two commands
// from Dawn Patrol's), as Wanted Team adapted it for EaglePlayer ("Paul Robotham player module V1.0 (31 May
// 2001)"), carried by UADE as players/PaulRobotham, whose source UADE also carries as
// amigasrc/players/wanted_team/PaulRobotham/src/Paul Robotham_v1.asm. The labels given are that source's.

/// Paul Robotham's music (for Space 1889, Ashes of Empire, Dawn Patrol, MegaTraveller 2 and Starlord), on Pete
/// Barnett's driver, as Wanted Team's notes have it: a score (".dat") and its samples in a file of their own
/// (".ssd", or one "mdtest.ssd" that the scores of a game share). The score begins with four words: how many
/// voices it has (one to four), and how many vibratos, envelopes and samples; then the places in the score of
/// each voice's events, of each vibrato and of each envelope (longs), and twelve bytes for each sample (its place
/// in the sample file and its length in words, and its loop's). The first envelope comes straight after, and
/// begins with 254 bytes of $3F.
///
/// A voice's events are bytes: a note (1 to 126), then how long it lasts (its low five bits, times two to the
/// power of its top three, in parts of which the tempo makes so many a tick); $7F with a length, the note before
/// it held on; nought, the voice's end; or a command, $80 and its number, and its values: 1 a loop's beginning (so
/// many times round), 2 its end, 7 a vibrato's depth, 8 its speed, 9 a slide to each note, 11 the vibrato, 12 the
/// envelope, 13 the volume, 14 the tempo, 15 the sample, 19 how the next notes are begun, 22 a fade of the whole
/// (to a volume, a step every so many ticks), 23 the note let go, 24 how fast it then dies away, 25 and 26 the
/// Amiga's filter on and off (Dawn Patrol's), and 20 and 21 two the player keeps and never reads. A vibrato is 256
/// signed bytes, each the period's change in so many parts of it; an envelope, volumes every fourth byte, a
/// negative one taking it back so far.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`), and so is run by
/// EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second
/// and a little less. Everything it does is done at the tick's start. A note is begun with its voice turned off
/// and told its sample and period; the voice is turned on on the next tick, and on the one after it is told its
/// sample's loop. Every tick, each voice's slide and vibrato move its period, and its envelope, volume and the
/// fade its volume.
///
/// A voice's end turns it off. The song is over when all its voices have come to their ends, as the driver has it
/// (it counts them in `lbW015DA0`), and stops there; but most of the scores go round a loop of 255 or 100 times
/// (the composer's for ever), and the song is said to have come to its end each time its first voice goes back
/// round an outermost loop of a hundred times or more. Wanted Team's player instead begins the song again (and
/// says it has come to its end) as soon as the first voice has read its last note: when its place is the byte
/// before the second voice's events (`LastPos`), which cuts short the last notes of all four. That is done only
/// if it is asked for (`wantedTeamsEnd`). Where the player would read past the score or its samples it reads
/// nought, and a note past its table of periods (where it would read its own variables) has the period nought; a
/// voice's loops nested deeper than it has room for are kept only as far as that room goes; an envelope that
/// only ever goes back (on which the player would hang) is silent; and a voice that reads 262,144 commands in a
/// tick without a note (the same, or nearly) is taken to have come to its end.
struct PaulRobothamPlayer: ~Copyable {
    /// The score, its samples and the player's sixteen bytes of noughts (`Empty`), as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the player's noughts, after the samples.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048
    /// Where the sample file is, after the score.
    let samplesAt: Int

    let songCount = 1
    private(set) var song = 0
    /// How many voices, vibratos, envelopes and samples the score has (its first four words).
    let voiceCount: Int
    let vibratoCount: Int
    let envelopeCount: Int
    let sampleCount: Int
    /// How much of the sample file its samples play, as `Init_Mod` measures it (`SamplesSize`): the furthest
    /// end of any sample's first part.
    let samplesNeeded: Int
    /// Whether the song ends and begins again as Wanted Team's player has it (see the type's comment).
    let wantedTeamsEnd: Bool

    /// Where the lists of the voices' events, the vibratos and the envelopes are, and the samples (`lbL015D94`,
    /// `lbL015D98`, `lbL015CD0`); and where `Interrupt` says the song has come to its end (`LastPos`).
    private let voiceList = 8
    private let vibratoList: Int
    private let envelopeList: Int
    private let sampleTable: Int
    private let lastPlace: Int

    /// What the player keeps for each voice (`lbL015828` and the three after it, $38 bytes each).
    private struct Voice {
        /// Where its next event is (byte 0), how many ticks are left of its note (4) and the part of a tick the
        /// last note's length was over by (`$32`, in the tempo's parts).
        var place = 0
        var wait: UInt16 = 0
        var remainder: UInt16 = 0
        /// How far into its vibrato and its envelope it is (6, 7), and how far the vibrato moves every tick
        /// (`$1C`); the vibrato and envelope (10, 14), and what the period is divided by for the vibrato's
        /// change (`$1E`, 10,000 over its depth).
        var vibratoAt: UInt8 = 0
        var envelopeAt: UInt8 = 3
        var vibratoSpeed: UInt8 = 1
        var vibrato = 0
        var envelope = 0
        var vibratoDivisor: UInt16 = 10000
        /// Its sample's twelve bytes (`$12`), and where its loops are kept (`$16`, from `lbL015D84`: a place in
        /// `loopRoom`).
        var sample = 0
        var loops = 0
        /// Its volume (`$1A`) and its flags (`$1B`): bit 7 its end come to, 6 let go, 4 a vibrato, 3 a held note,
        /// 2 a slide to each note.
        var volume: UInt8 = 0
        var flags: UInt8 = 0x20
        /// Its period as it is now, sliding to the note's (`$20`, `$22`), and how far it slides a tick (`$24`).
        var period: UInt16 = 0
        var target: UInt16 = 0
        var slide: UInt16 = 0
        /// Its sample's loop (`$26`), and the loop's length and the note's period (`$2A`, a long).
        var loopPlace = 0
        var loopLength: UInt16 = 0
        var loopPeriod: UInt16 = 0
        /// How its notes are begun (`$2E`: bit 0 on from the last, without its sample begun again; bit 1 its
        /// envelope, and bit 2 its vibrato, not begun again), and whether its sample has just been chosen
        /// (`$2F`).
        var mode: UInt8 = 0
        var fresh: UInt8 = 0
        /// Its volume as it dies away once let go (`$36`), and by how much a tick (`$37`).
        var dying: UInt8 = 0
        var dyingStep: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The player's room for the voices' loops (from `lbL015908` to `lbL015CD0`): each voice's grows down from
    /// its place in `lbL015D84`, six bytes a loop (a count, a word, and a place, a long).
    private var loopRoom = [UInt8](repeating: 0, count: Self.loopRoomSize)
    private static let loopRoomSize = 0x3C8
    private static let loopTops = [0x1E8, 0x260, 0x2D8, 0x350]

    /// The tempo (`lbW015DB2`, in parts of a tick: 10,800 of them, `lbW015DB4`, are a tick at a tempo of one);
    /// the voices to be turned on on the next tick (`lbB015DA9`), the voices whose loops are to be told on it
    /// (`lbB015DA8`), and the voices turned on (`lbB015DAE`), whose volumes are told; how many voices have come
    /// to their ends (`lbW015DA0`).
    private var tempo: UInt16 = 1000
    private static let tickParts: UInt32 = 10800
    private var turnOn: UInt8 = 0
    private var loopDue: UInt8 = 0
    private var on: UInt8 = 0
    private var ended = 0
    /// The fade (`lbW015DBE`): the volume of the whole, its goal, its step, its count of ticks and every how many.
    private var fade: UInt16 = 0x3F
    private var fadeTarget: UInt16 = 0x3F
    private var fadeStep: UInt16 = 0
    private var fadeCount: UInt16 = 0
    private var fadeEvery: UInt16 = 1
    private(set) var lightFilter = false

    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    private(set) var endings = 0
    /// Whether the first voice's outermost loop is one of `roundTimes` times or more (or of nought times, which
    /// is 65,536): the composer's way of going round for ever, whose going back is the song's end.
    private var goesRound = false
    private static let roundTimes: UInt8 = 100
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to; and so is one whose voices have read so
    /// many commands in finding its length (only a broken score loops round commands so long).
    private static let mostTicks = 50 * 60 * 60
    private static let mostCommandsInAll = 1 << 26
    /// How many commands a voice may read in a tick before it is taken to have come to its end; and how many have
    /// been read in all.
    private static let mostCommands = 1 << 18
    private var commandsRead = 0

    /// The table of periods (`lbW015DCC`), from the note nought, which is never played: five octaves.
    static let periodTable: [UInt16] = [
        0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC, 0x1E0, 0x1C4,
        0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0, 0x0E2,
        0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0A9, 0x0A0, 0x097, 0x08E, 0x086, 0x07F, 0x078, 0x071,
        0x06B, 0x065, 0x05F, 0x05A, 0x054, 0x050, 0x04B, 0x047, 0x043, 0x03F, 0x03C, 0x038,
        0x035, 0x032, 0x02F, 0x02D, 0x02A, 0x028, 0x025, 0x023, 0x021, 0x01F, 0x01E, 0x01C,
    ]

    private static func period(_ note: UInt8) -> UInt16 {
        Int(note) < periodTable.count ? periodTable[Int(note)] : 0
    }

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < memoryCapacity ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    /// A long, as a place: taken as signed, that a place past what a 32-bit `Int` holds is one outside memory.
    @inline(__always) private func long(_ at: Int) -> Int {
        Int(Int32(bitPattern: UInt32(word(at)) << 16 | UInt32(word(at &+ 2))))
    }

    private func roomWord(_ at: Int) -> UInt16 {
        guard at >= 0, at + 1 < Self.loopRoomSize else { return 0 }
        return UInt16(loopRoom[at]) << 8 | UInt16(loopRoom[at + 1])
    }

    private mutating func setRoomWord(_ at: Int, _ value: UInt16) {
        guard at >= 0, at + 1 < Self.loopRoomSize else { return }
        loopRoom[at] = UInt8(value >> 8)
        loopRoom[at + 1] = UInt8(value & 0xFF)
    }

    // MARK: - Loading

    /// True for a score the player's check takes (`Check2`): one to four voices; the counts of vibratos and
    /// envelopes below 256; the places of the voices' events below 65,536 and none nought; the places of the
    /// vibratos and envelopes even and neither nought nor negative; the first envelope just after the samples'
    /// twelve bytes each; and its first 254 bytes all $3F.
    static func isOne(_ data: [UInt8]) -> Bool {
        func byte(_ at: Int) -> UInt8? { at >= 0 && at < data.count ? data[at] : nil }
        func word(_ at: Int) -> Int? {
            guard let high = byte(at), let low = byte(at + 1) else { return nil }
            return Int(high) << 8 | Int(low)
        }
        func long(_ at: Int) -> UInt32? {
            guard let high = word(at), let low = word(at + 2) else { return nil }
            return UInt32(high) << 16 | UInt32(low)
        }
        guard let voices = word(0), voices != 0, voices <= 4, byte(2) == 0, let vibratos = word(2), byte(4) == 0,
              let envelopes = word(4), byte(6) == 0, let samples = word(6) else { return false }
        var at = 8
        for _ in 0 ..< voices {
            guard word(at) == 0, let place = long(at), place != 0 else { return false }
            at += 4
        }
        // (A count of nought goes round 65,536 times, as `dbf` does.)
        for _ in 0 ..< (vibratos == 0 ? 0x10000 : vibratos) {
            guard let place = long(at), place != 0, place & 0x8000_0001 == 0 else { return false }
            at += 4
        }
        guard let first = long(at) else { return false }
        for _ in 0 ..< (envelopes == 0 ? 0x10000 : envelopes) {
            guard let place = long(at), place != 0, place & 0x8000_0001 == 0 else { return false }
            at += 4
        }
        // (Twelve bytes a sample, as a signed word.)
        at += Int(Int16(truncatingIfNeeded: samples &* 12))
        // (The first envelope's place, now known to be neither nought nor negative.)
        guard UInt32(truncatingIfNeeded: at) == first, at >= 0 else { return false }
        for k in 0 ..< 127 where word(at + 2 * k) != 0x3F3F { return false }
        return true
    }

    /// Reads the score and its samples (the ".ssd" file beside it), and starts its song. A score given no samples
    /// (an empty file) is refused, as the player's `ExtLoad` refuses it when it finds no sample file beside it;
    /// and so is one whose samples are shorter than its samples' first parts reach (`InitPlayer`'s
    /// `EPR_ModuleTooShort`).
    init(_ data: [UInt8], samples: [UInt8], song: Int = 0, wantedTeamsEnd: Bool = false) throws(TuneError) {
        self.wantedTeamsEnd = wantedTeamsEnd
        func dataWord(_ at: Int) -> Int { at >= 0 && at + 1 < data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : 0 }
        voiceCount = max(0, min(4, dataWord(0)))
        vibratoCount = dataWord(2)
        envelopeCount = dataWord(4)
        sampleCount = dataWord(6)
        // (`Init_Song`'s places, from the counts as words times four.)
        vibratoList = voiceList + Int(UInt16(truncatingIfNeeded: dataWord(0) << 2))
        envelopeList = vibratoList + Int(UInt16(truncatingIfNeeded: vibratoCount << 2))
        sampleTable = envelopeList + Int(UInt16(truncatingIfNeeded: envelopeCount << 2))

        // Where everything goes: the score at nought, the sample file after it, then the player's noughts.
        func aligned(_ n: Int) -> Int { (n + 15) & ~15 }
        samplesAt = aligned(max(data.count, 16))
        silenceAt = aligned(samplesAt + samples.count + 16)
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        for (i, b) in samples.enumerated() { memory[samplesAt + i] = b }

        // `Init_Mod`: the places of the voices' events, vibratos and envelopes made addresses (the score is at
        // nought, so they are as they are), and each sample's place and its loop's made places in memory, while
        // the furthest end of a sample's first part is measured. (A count of nought goes round 65,536 times;
        // only samples within the score are set up.)
        var needed: Int32 = 0
        let count = sampleCount == 0 ? 0x10000 : sampleCount
        for i in 0 ..< count {
            let entry = sampleTable + 12 * i
            guard entry + 12 <= data.count else { break }
            let start = Int32(bitPattern: UInt32(dataWord(entry)) << 16 | UInt32(dataWord(entry + 2)))
            let end = Int32(dataWord(entry + 4)) &* 2 &+ start
            if end > needed { needed = end }
            for at in [entry, entry + 6] {
                let place = UInt32(dataWord(at)) << 16 | UInt32(dataWord(at + 2))
                let made = place &+ UInt32(samplesAt)
                memory[at] = UInt8(made >> 24)
                memory[at + 1] = UInt8(made >> 16 & 0xFF)
                memory[at + 2] = UInt8(made >> 8 & 0xFF)
                memory[at + 3] = UInt8(made & 0xFF)
            }
        }
        samplesNeeded = Int(needed)
        // (`LastPos`: the long after the first voice's place, less one.)
        lastPlace = Int(Int32(bitPattern: (UInt32(dataWord(12)) << 16 | UInt32(dataWord(14))) &- 1))

        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .unsupported("not a Paul Robotham score") }
        guard !samples.isEmpty else {
            throw .missingCompanion("A Paul Robotham score keeps its samples in a file of their own (\".ssd\"), which was not given with it.")
        }
        guard Int32(clamping: samples.count) >= needed else { throw .malformed("its sample file is shorter than its samples") }

        // The song's length, from a playing of it in silence to its end.
        start(afresh: true)
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks, commandsRead < Self.mostCommandsInAll {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again, or one with every voice turned off.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        start(afresh: true)
        commandsRead = 0
    }

    deinit { memory.deallocate() }

    /// `Init_Song` (by way of `InitSound`, which also sets the fade's volume and goal to $3F): each voice to read
    /// its first event after ten ticks, its vibrato and envelope the first of each, its sample the first, and its
    /// loops none. What it does not set is as it was: the tempo, the voices to be turned on or told their loops,
    /// their periods, loops and dying volumes, and the fade's step and count. Afresh, as the player is loaded,
    /// they are as the player has them before it is first run.
    private mutating func start(afresh: Bool) {
        if afresh {
            voices = .init(repeating: Voice())
            loopRoom = [UInt8](repeating: 0, count: Self.loopRoomSize)
            tempo = 1000
            turnOn = 0
            loopDue = 0
            on = 0
            fadeStep = 0
            fadeCount = 0
            fadeEvery = 1
            lightFilter = false
            periods = .init(repeating: 0)
            volumes = .init(repeating: 0)
            endings = 0
            stops = 0
        }
        goesRound = false
        fade = 0x3F
        fadeTarget = 0x3F
        for v in 0 ..< voiceCount {
            voices[v].place = long(voiceList + 4 * v)
            voices[v].wait = 10
            voices[v].remainder = 0
            voices[v].volume = 0
            voices[v].flags = 0x20
            voices[v].mode = 0
            voices[v].slide = 0
            voices[v].vibratoAt = 0
            voices[v].envelopeAt = 3
            voices[v].fresh = 0
            voices[v].vibratoDivisor = 10000
            voices[v].vibratoSpeed = 1
            voices[v].vibrato = long(vibratoList)
            voices[v].envelope = long(envelopeList)
            voices[v].sample = sampleTable
            voices[v].loops = Self.loopTops[v]
        }
        ended = 0
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song == 0 else { throw .unsupported("there is no song \(song + 1)") }
        start(afresh: true)
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

    /// Runs the player for a tick (`Interrupt`, and `Play`), telling `output` what Paula is to do, in the order
    /// the player tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        for v in 0 ..< voiceCount { voice(v, &output) }
        // The fade: a step every so many ticks, to its goal.
        let count = fadeCount &+ 1
        if (count &- fadeEvery) & 0x8000 != 0 {
            fadeCount = count
        } else {
            fadeCount = 0
            if fadeStep != 0 {
                if fade == fadeTarget { fadeStep = 0 } else { fade &+= fadeStep }
            }
        }
        if wantedTeamsEnd {
            // (`Interrupt`: the first voice at `LastPos`, the song begun again.)
            if voiceCount > 0, voices[0].place == lastPlace {
                endings += 1
                start(afresh: false)
            }
        } else if voiceCount > 0, ended >= voiceCount, stops == 0 {
            endings += 1
            stops += 1
        }
        return 20
    }

    /// `lbC014E76`: a voice's tick. (`lbC015292`, what is done instead for a voice playing one of the game's
    /// sounds, is never reached here: only the game's code, which Wanted Team left out, starts one.)
    private mutating func voice<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        guard voices[v].flags & 0x80 == 0 else { return }
        let bit = UInt8(1) << UInt8(v)
        voices[v].vibratoAt &+= voices[v].vibratoSpeed
        voices[v].envelopeAt &+= 4
        if voices[v].wait == 0 {
            switch read(v, bit, &output) {
            case .ended:
                return
            case .continued:
                carryOn(v, bit, &output)
            case .begun:
                break
            }
        } else {
            carryOn(v, bit, &output)
        }
        sound(v, bit, &output)
    }

    private enum Reading { case ended, continued, begun }

    /// `lbC014E9A`: the voice's events up to its next note or its end.
    private mutating func read<Output: TFMXOutput>(_ v: Int, _ bit: UInt8, _ output: inout Output) -> Reading {
        var at = voices[v].place
        var commands = 0
        while true {
            let event = byte(at)
            at &+= 1
            if event & 0x80 != 0 {
                commands += 1
                if commands > Self.mostCommands { return end(v, bit, &output) }
                commandsRead &+= 1
                command(v, event & 0x1F, &at)
                voices[v].place = at
                continue
            }
            if event == 0 { return end(v, bit, &output) }
            voices[v].flags &= ~0x08
            if event == 0x7F {
                voices[v].flags |= 0x08
                return length(v, bit, &at)
            }
            if voices[v].mode & 1 == 0 {
                // `lbC014ED0`: the note begun, its voice turned off, told its sample and its period.
                voices[v].fresh = 0
                output.off(v)
                on &= ~bit
                voices[v].dying = 0
                voices[v].flags &= ~0x40
                let sample = voices[v].sample
                let period = Self.period(event)
                output.takeNextBuffer(v, start: long(sample), length: word(sample &+ 4))
                writePeriod(v, period, &output)
                voices[v].target = period
                setLoop(v, sample, period)
                return length(v, bit, &at)
            }
            if voices[v].fresh == 0 {
                // `lbC014F3E`: the note on from the last, its period and nothing more told.
                let period = Self.period(event)
                writePeriod(v, period, &output)
                voices[v].target = period
                lengthOf(v, &at)
                voices[v].place = at
                beginEnvelopes(v)
                return .begun
            }
            // `lbC014FB4`: the note on from the last but its sample just chosen: its voice made silent and turned
            // off, and told the sample's loop (or the player's noughts, at the period $100).
            writeVolume(v, 0, &output)
            output.off(v)
            on &= ~bit
            let sample = voices[v].sample
            let period: UInt16
            if word(sample &+ 10) == 0 {
                period = 0x100
                output.takeNextBuffer(v, start: silenceAt, length: 8)
            } else {
                period = Self.period(event)
                output.takeNextBuffer(v, start: long(sample &+ 6), length: word(sample &+ 10))
            }
            writePeriod(v, period, &output)
            voices[v].target = period
            setLoop(v, sample, period)
            voices[v].fresh = 0
            return length(v, bit, &at)
        }
    }

    /// The sample's loop kept, to be told after the voice is turned on (the player's noughts for one of
    /// nought words).
    private mutating func setLoop(_ v: Int, _ sample: Int, _ period: UInt16) {
        voices[v].loopPlace = long(sample &+ 6)
        voices[v].loopLength = word(sample &+ 10)
        if voices[v].loopLength == 0 {
            voices[v].loopPlace = silenceAt
            voices[v].loopLength = 8
        }
        voices[v].loopPeriod = period
    }

    /// `lbC0151D8`: the voice's end, and it turned off.
    private mutating func end<Output: TFMXOutput>(_ v: Int, _ bit: UInt8, _ output: inout Output) -> Reading {
        ended += 1
        voices[v].flags |= 0x80
        output.off(v)
        on &= ~bit
        return .ended
    }

    /// The note's length read, in ticks, and the part of a tick it is over by kept for the next.
    private mutating func lengthOf(_ v: Int, _ at: inout Int) {
        let value = byte(at)
        at &+= 1
        let parts = UInt32(UInt16(value & 0x1F) << UInt16(value >> 5)) * UInt32(tempo) + UInt32(voices[v].remainder)
        // (At most 3,968 parts times a tempo of 4,080: never more ticks than a word holds.)
        voices[v].wait = UInt16(truncatingIfNeeded: parts / Self.tickParts)
        voices[v].remainder = UInt16(truncatingIfNeeded: parts % Self.tickParts)
    }

    /// The vibrato and envelope begun again, unless the voice's notes are begun without.
    private mutating func beginEnvelopes(_ v: Int) {
        if voices[v].mode & 4 == 0 { voices[v].vibratoAt = 0 }
        if voices[v].mode & 2 == 0 { voices[v].envelopeAt = 3 }
    }

    /// `lbC015034`: the note's length; and, for one not held on, its vibrato and envelope begun and its voice to
    /// be turned on on the next tick.
    private mutating func length(_ v: Int, _ bit: UInt8, _ at: inout Int) -> Reading {
        lengthOf(v, &at)
        let held = voices[v].flags & 0x08 != 0
        if !held { beginEnvelopes(v) }
        voices[v].place = at
        if held { return .continued }
        turnOn |= bit
        return .begun
    }

    /// `lbC01509A`: the voice turned on on the tick after its note was begun, and told its loop on the one after
    /// that.
    private mutating func carryOn<Output: TFMXOutput>(_ v: Int, _ bit: UInt8, _ output: inout Output) {
        if turnOn & bit != 0 {
            turnOn &= ~bit
            loopDue |= bit
            output.on(v)
            on |= bit
        } else if loopDue & bit != 0 {
            loopDue &= ~bit
            output.takeNextBuffer(v, start: voices[v].loopPlace, length: voices[v].loopLength)
            writePeriod(v, voices[v].loopPeriod, &output)
        }
    }

    /// `lbC0150DE`: the voice's slide and vibrato, its period told, its count of ticks down by one, and, for a
    /// voice turned on, its volume: its envelope's times its own (or as it dies away, once let go), over 63,
    /// and times the fade's over 63.
    private mutating func sound<Output: TFMXOutput>(_ v: Int, _ bit: UInt8, _ output: inout Output) {
        var period = voices[v].target
        if voices[v].flags & 0x04 != 0 {
            // A slide to the note's period, so far a tick, and no further.
            let now = voices[v].period
            var distance = Int16(bitPattern: period &- now)
            var step = Int16(bitPattern: voices[v].slide)
            if distance < 0 { step = 0 &- step }
            let moved = now &+ UInt16(bitPattern: step)
            if step < 0 {
                distance = 0 &- distance
                step = 0 &- step
            }
            if step < distance { period = moved }
        }
        voices[v].period = period
        if voices[v].flags & 0x10 != 0 {
            // The vibrato: the period's change in so many parts of it (as `divs`, which leaves a quotient too big
            // for a word as it was).
            let change = Int32(Int8(bitPattern: byte(voices[v].vibrato &+ Int(voices[v].vibratoAt))))
            let product = Int32(Int16(bitPattern: period)) * change
            let divisor = Int32(Int16(bitPattern: voices[v].vibratoDivisor))
            let quotient = product / divisor
            let part = quotient >= -0x8000 && quotient <= 0x7FFF ? quotient : product
            period &+= UInt16(truncatingIfNeeded: part)
        }
        writePeriod(v, period, &output)
        voices[v].wait &-= 1
        guard on & bit != 0 else { return }
        var volume: UInt16 = 0
        if voices[v].volume != 0 {
            var level: UInt8?
            for _ in 0 ..< 256 {
                let step = byte(voices[v].envelope &+ Int(voices[v].envelopeAt))
                if step & 0x80 == 0 {
                    level = step
                    break
                }
                voices[v].envelopeAt &-= ((0 &- step) &+ 3) & 0xFC
            }
            if let level {
                var own = voices[v].volume
                if voices[v].flags & 0x40 != 0 {
                    // Let go: down by its step a tick, to nought.
                    own = voices[v].dying
                    if own != 0 {
                        own &-= voices[v].dyingStep
                        if own & 0x80 != 0 { own = 0 }
                        voices[v].dying = own
                    }
                }
                volume = UInt16(level & 0x3F) * UInt16(own & 0x3F) / 0x3F
                if fade != 0x3F { volume = UInt16(truncatingIfNeeded: UInt32(volume) * UInt32(fade) / 0x3F) & 0x3F }
            }
        }
        writeVolume(v, volume, &output)
    }

    /// `lbL015CE4`: a command, by its number (its low five bits), and its values. (The others are `Error`,
    /// which turns the screen white and goes on.)
    private mutating func command(_ v: Int, _ number: UInt8, _ at: inout Int) {
        func value() -> UInt8 {
            let b = byte(at)
            at &+= 1
            return b
        }
        switch number {
        case 1:
            // A loop's beginning: so many times round, and where it goes back to.
            let times = value()
            voices[v].loops &-= 4
            let place = UInt32(truncatingIfNeeded: at)
            setRoomWord(voices[v].loops, UInt16(place >> 16))
            setRoomWord(voices[v].loops &+ 2, UInt16(place & 0xFFFF))
            voices[v].loops &-= 2
            setRoomWord(voices[v].loops, UInt16(times))
            if v == 0, voices[0].loops == Self.loopTops[0] - 6 { goesRound = times == 0 || times >= Self.roundTimes }
        case 2:
            // Its end: back, while its count comes down to other than nought.
            let left = roomWord(voices[v].loops) &- 1
            setRoomWord(voices[v].loops, left)
            if left == 0 {
                voices[v].loops &+= 6
            } else {
                // (The song gone round, for the first voice's outermost loop of a hundred times or more.)
                if v == 0, goesRound, voices[0].loops == Self.loopTops[0] - 6 { endings += 1 }
                let high = UInt32(roomWord(voices[v].loops &+ 2)), low = UInt32(roomWord(voices[v].loops &+ 4))
                at = Int(Int32(bitPattern: high << 16 | low))
            }
        case 7:
            let depth = value()
            if depth == 0 {
                voices[v].flags &= ~0x10
            } else {
                voices[v].vibratoDivisor = 10000 / UInt16(depth)
                voices[v].flags |= 0x10
            }
        case 8:
            voices[v].vibratoSpeed = value()
        case 9:
            let step = value()
            if step == 0 {
                voices[v].flags &= ~0x04
            } else {
                voices[v].slide = UInt16(step) * 4
                voices[v].flags |= 0x04
            }
        case 11:
            voices[v].vibrato = long(vibratoList &+ 4 * Int(value()))
        case 12:
            voices[v].envelope = long(envelopeList &+ 4 * Int(value()))
        case 13:
            voices[v].volume = value()
        case 14:
            tempo = UInt16(value()) << 4
        case 15:
            voices[v].sample = sampleTable &+ 12 * Int(value())
            voices[v].mode &= ~1
            voices[v].fresh = 1
        case 19:
            voices[v].mode = value()
        case 20, 21:
            _ = value()
        case 22:
            // A fade to a volume: a step up to one above the whole's, else down; at once, if every nought ticks.
            fadeTarget = UInt16(value())
            fadeStep = Int16(bitPattern: fadeTarget) > Int16(bitPattern: fade) ? 1 : 0xFFFF
            let every = value()
            if every == 0 {
                fadeStep = 0
                fade = fadeTarget
            }
            fadeEvery = UInt16(every)
        case 23:
            voices[v].dying = voices[v].volume
            voices[v].flags |= 0x40
        case 24:
            voices[v].dyingStep = value()
        case 25:
            // (Dawn Patrol's: the power light lit, the filter on; and off.)
            lightFilter = true
        case 26:
            lightFilter = false
        default:
            break
        }
    }

    /// Paula's period for the voice as the player last told it (all it tells her is told at the tick's start).
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice as the player last told it.
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Paul Robotham's music, played on Paula by `PaulaTickRenderer`.
extension PaulRobothamPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Paul Robotham")
        info.detail = "\(voiceCount) voice\(voiceCount == 1 ? "" : "s"), \(sampleCount) sample\(sampleCount == 1 ? "" : "s")"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
