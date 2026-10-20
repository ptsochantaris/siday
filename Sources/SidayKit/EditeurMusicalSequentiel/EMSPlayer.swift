// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Thomas Pimmel's replay routine for his Editeur Musical Séquentiel (version 1.24, of 22 March 1991)
// as Wanted Team adapted it for EaglePlayer ("Editeur Musical Sequentiel 1.24 player module V1.0 (5 Dec
// 2005)"), carried by UADE as players/EMS, whose source UADE also carries as
// amigasrc/players/wanted_team/EMS/src/EMS_v1.asm. The labels given are that source's.

/// Editeur Musical Séquentiel, Thomas Pimmel's tracker of 1989 to 1991, whose music for OCB and for Imperial
/// (by Jean-Marc Boursot) is among UnExoticA's: a module much like a SoundTracker's of fifteen samples, with
/// commands of its own. A header of six bytes (a 1, a version, the song's length and its last pattern), the
/// order of 128 patterns, fifteen samples of twelve bytes (a long the player fills in with where the sample is,
/// its length, where it goes round from and for how long, in words, and its volume), the patterns, each of 64
/// rows of four notes of four bytes (a period, the sample in the high four bits of a byte and a command in the
/// low four, and the command's byte), and then the samples' sounds.
///
/// The commands: 7 brings the volume down by the byte on every tick between rows (until it is nought), B and C
/// slide the period up and down by it (not past $70 and $6B0), D shakes it by it either way on alternate ticks,
/// E sets the volume, F makes the sample go round whole, 8 breaks to the next pattern (at the byte's row), 9
/// sets the speed, A the filter (on for nought); those under 7 do nothing.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`), and so is run by
/// EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second
/// and a little less. A row is played on a tick when the count of ticks since the last has come to the speed
/// (six to begin with), and that count is not counted on the row's own tick, so that a row lasts a tick more
/// than the speed. At a row the voices with a sample are turned off, each voice is told its sample's volume
/// and its note's period and its command is done, and once `DMAWait` has waited for the beam to begin nine
/// lines (of 227 of Paula's clocks), the voices with a sample are told it and turned on; on the tick after,
/// they are told their loops. As the player begins (`ems_Init`) it finds its samples two bytes before where
/// the file has them (as `InitPlayer` reckons them), and clears each one's first word.
///
/// Each voice's writes are told Paula at their moments in the tick (`TFMXOutput.timed(at:)`), near where they
/// fall in UADE's dumps.
///
/// The song goes round when it comes to the end of its order, and is said to have come to its end there (as
/// the player tells EaglePlayer so); its length is taken to the next row, the first of it again. Where the
/// player would read past the file it reads nought; a speed of nought (at which its code would run away with
/// the machine) is taken as none; and a sample of no length whose long is not nought (which the player would
/// play from wherever the long says) is played as silence, while one whose long is nought is not told Paula,
/// who starts again what she was told last, as she does for the player.
struct EMSPlayer: ~Copyable {
    /// The file (with the player's clearing of each sample's first word) and what follows it, as Paula reads
    /// them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the noughts after the file.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// Where each sample is (`ems_Init`), as the player fills its table in: nil for one of no length whose
    /// long is nought (which no voice is pointed at), and the silence for one whose long is not.
    private let sampleAt: [Int?]
    /// The song's last position (`ems_length`, its length less one).
    private let lastPosition: UInt16
    let sampleCount: Int
    let patternCount: Int

    /// What the player keeps for each voice (`ems_snd`): the sample its row started (to be told its loop on
    /// the tick after; nil for none), its length, loop and volume, and its period.
    private struct Voice {
        var sample: Int?
        var length: UInt16 = 0
        var repeatFrom: UInt16 = 0
        var repeatLength: UInt16 = 0
        var volume: UInt16 = 0
        var period: UInt16 = 0
        /// Its row's command to be done between rows (`ems_com`: 7, B, C or D, and its byte).
        var command: UInt16 = 0
        var parameter: UInt16 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The ticks since the last row (`ems_count`), the speed (`ems_speedi`), where the song is (`ems_posi`) and
    /// the row (`ems_mesure`), the row a break goes to (`ems_cbreak`), and the pattern being played
    /// (`ems_actual`, a place in the file).
    private var count: UInt16 = 0
    private var speed: UInt16 = 6
    private var position: UInt16 = 0
    private var row: UInt16 = 0
    private var breakRow: UInt16 = 0
    private var pattern = 0
    /// The Amiga's filter (the power light's), as command A leaves it.
    private(set) var lightFilter = false
    /// What each of Paula's period and volume registers was last given, and what they held as the tick just
    /// run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told at their
    /// moments).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the wait.
    private var clock = 0
    /// Whether the song has come to its end and the next row is the first of it again.
    private var ending = false

    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (near the medians of its dumps of
    /// the six tunes): the first after the interrupt begins (a guess: only the distances between them are heard);
    /// between voices at a row, for one with a note and for one without; a note's period after its volume; and
    /// between the voices' loops and commands on other ticks.
    static let firstWrite = 300
    static let noteClocks = 400
    static let emptyClocks = 200
    static let periodClocks = 100
    static let loopClocks = 80
    static let commandClocks = 60

    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's clocks) has
    /// changed nine times, the first at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 80 - clock
    }

    /// The table of periods the player's check takes (`PeriodTable`): four octaves, from $6B0.
    static let periodTable: [UInt16] = [
        0x6B0, 0x650, 0x5F4, 0x5A0, 0x54C, 0x500, 0x4B8, 0x474, 0x434, 0x3F8, 0x3C0, 0x38A,
        0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC, 0x1E0, 0x1C5,
        0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0, 0x0E2,
        0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0x078, 0x071,
    ]

    // MARK: - Reading

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        at >= 0 && at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`): more than 1,338 bytes; a 1, a version of $25 or
    /// less, a length of 1 to 128 and a last pattern of 63 or less; an order of no pattern past the last; and a
    /// first pattern whose periods are all of the table (or nought), at least one of them not nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count > 1338, data[0] == 1, data[1] <= 0x25 else { return false }
        let length = word(data, 2), last = word(data, 4)
        guard length >= 1, length <= 128, last <= 63 else { return false }
        for i in 6 ..< 134 where UInt16(data[i]) > last { return false }
        var periods = 0
        for at in stride(from: 314, to: 1338, by: 4) {
            let period = word(data, at)
            guard period < 0x8000 else { return false }
            guard period != 0 else { continue }
            guard periodTable.contains(period) else { return false }
            periods += 1
        }
        return periods > 0
    }

    /// Reads the file and starts its song (it has one: `song` is taken for that one, whatever it is).
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        lastPosition = Self.word(data, 2) &- 1
        patternCount = Int(Self.word(data, 4)) + 1
        // (`ems_Init`: the samples from $538 on, each of a length's first word cleared, and the place of each
        // of no length left as the file has it.)
        var at = 0x538 + (patternCount - 1) * 1024
        var places: [Int?] = []
        var total = 0
        var used = 0
        for i in 0 ..< 15 {
            let entry = 134 + 12 * i
            let length = Int(Self.word(data, entry + 4))
            guard length != 0 else {
                places.append(Self.word(data, entry) | Self.word(data, entry + 2) == 0 ? nil : silenceAt)
                continue
            }
            if at + 1 < memoryCapacity {
                memory[at] = 0
                memory[at + 1] = 0
            }
            places.append(at)
            at += 2 * length
            total += 2 * length
            used += 1
        }
        sampleAt = places
        sampleCount = used
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not an Editeur Musical Séquentiel module") }
        // (`InitPlayer`: the patterns and samples it says it has must all be in the file.)
        guard 314 + patternCount * 1024 + total <= data.count else { throw .malformed("too short for its patterns and samples") }

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

    /// `ems_Init`: the speed six, the song at its beginning and the first pattern of its order.
    private mutating func start() {
        voices = .init(repeating: Voice())
        count = 0
        speed = 6
        position = 0
        row = 0
        breakRow = 0
        pattern = 314 + Int(byte(6)) * 1024
        lightFilter = false
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = periods
        volumesBefore = volumes
        clock = 0
        ending = false
        endings = 0
    }

    var songCount: Int { 1 }
    var song: Int { 0 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    /// Runs the player for a tick (`ems_play`), telling `output` what Paula is to do, in the order the player
    /// tells her: a row, or the loops and the commands between rows. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        if count < speed {
            between(&output)
        } else {
            count = 0
            if ending {
                ending = false
                endings += 1
            }
            nextRow(&output)
        }
        clock += Self.tickClocks
        return 20
    }

    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        // (`ChangeVolume`: seven bits, times EaglePlayer's volume, 64, over 64.)
        volumes[v] = volume & 0x7F
        output.writeVolume(v, volumes[v])
    }

    /// `ems_permit`: the row played.
    private mutating func nextRow<Output: TFMXOutput>(_ output: inout Output) {
        for v in 0 ..< 4 {
            voices[v].command = 0
            voices[v].parameter = 0
        }
        // (The row's place: its number times 16, a word, added to the pattern's as a signed one.)
        let notes = pattern &+ Int(Int16(bitPattern: row &<< 4))
        var at = Self.firstWrite
        output.timed(at: at)
        var started: UInt16 = 0
        for v in 0 ..< 4 where byte(notes &+ 4 * v &+ 2) >> 4 != 0 {
            started |= 1 << UInt16(v)
            output.off(v)
        }
        at += Self.commandClocks
        for v in 0 ..< 4 {
            let note = notes &+ 4 * v
            var wrote = false
            voices[v].sample = nil
            output.timed(at: at)
            let instrument = Int(byte(note &+ 2) >> 4)
            if instrument != 0 {
                let entry = 134 + 12 * (instrument - 1)
                voices[v].sample = sampleAt[instrument - 1]
                voices[v].length = word(entry + 4)
                voices[v].repeatFrom = word(entry + 6)
                voices[v].repeatLength = word(entry + 8)
                // (Its volume times `ems_voldiv`, 64, over 64, in a word.)
                voices[v].volume = (word(entry + 10) &* 64) >> 6
                writeVolume(v, voices[v].volume, &output)
                wrote = true
            }
            let period = word(note)
            if period != 0 {
                output.timed(at: at + Self.periodClocks)
                periods[v] = period
                output.writePeriod(v, period)
                voices[v].period = period
                wrote = true
            }
            let parameter = UInt16(byte(note &+ 3))
            switch byte(note &+ 2) & 15 {
            case 7, 11, 12, 13:
                // (`ems_special`: done between rows.)
                voices[v].command = UInt16(byte(note &+ 2) & 15)
                voices[v].parameter = parameter
            case 8:
                // (`ems_break`.)
                breakRow = parameter
                row = 63
            case 9:
                // (`ems_speed`.)
                if parameter != 0 { speed = parameter }
            case 10:
                // (`ems_led`: the power light's bit set, the light and the filter off, for anything but nought.)
                lightFilter = parameter == 0
            case 14:
                // (`ems_vol`.)
                voices[v].volume = parameter
                output.timed(at: at + Self.periodClocks)
                writeVolume(v, parameter, &output)
                wrote = true
            case 15:
                // (`ems_repeat`: the whole sample goes round.)
                voices[v].repeatLength = voices[v].length
                voices[v].repeatFrom = 0
            default:
                break
            }
            at += wrote ? Self.noteClocks : Self.emptyClocks
        }
        row &+= 1
        if row == 64 {
            // (On to the next pattern of the order, and back to the first after the last.)
            row = breakRow
            breakRow = 0
            position &+= 1
            if position > lastPosition {
                ending = true
                position = 0
            }
            pattern = 314 + Int(byte(6 &+ Int(position))) * 1024
        }
        // (`ems_makewait`, and then the samples told and turned on, `ems_docloop`.)
        at = afterWait(at)
        output.timed(at: at)
        for v in 0 ..< 4 {
            if let sample = voices[v].sample { output.takeNextBuffer(v, start: sample, length: voices[v].length) }
        }
        for v in 0 ..< 4 where started & 1 << UInt16(v) != 0 { output.on(v) }
    }

    /// `ems_notyet`: on the tick after a row, its samples told their loops; and on every tick between rows,
    /// the rows' commands.
    private mutating func between<Output: TFMXOutput>(_ output: inout Output) {
        var at = Self.firstWrite
        if count == 0 {
            for v in 0 ..< 4 {
                guard let sample = voices[v].sample else { continue }
                voices[v].sample = nil
                output.timed(at: at)
                output.takeNextBuffer(v, start: sample &+ 2 * Int(voices[v].repeatFrom), length: voices[v].repeatLength)
                at += Self.loopClocks
            }
        }
        for v in 0 ..< 4 {
            let parameter = voices[v].parameter
            switch voices[v].command & 0xFF {
            case 7:
                // (`ems_voldown`: down to nought, where the command ends.)
                // (`bgt`: kept while it was more than the byte, as signed words.)
                let above = Int16(bitPattern: voices[v].volume) > Int16(bitPattern: parameter)
                voices[v].volume &-= parameter
                if !above {
                    voices[v].volume = 0
                    voices[v].command = 0
                    voices[v].parameter = 0
                }
                output.timed(at: at)
                writeVolume(v, voices[v].volume, &output)
            case 11:
                // (`ems_up`: not below $70.)
                let period = voices[v].period &- parameter
                if Int16(bitPattern: period) >= 0x70 {
                    voices[v].period = period
                    output.timed(at: at)
                    periods[v] = period
                    output.writePeriod(v, period)
                }
            case 12:
                // (`ems_down`: not above $6B0.)
                let period = voices[v].period &+ parameter
                if Int16(bitPattern: period) <= 0x6B0 {
                    voices[v].period = period
                    output.timed(at: at)
                    periods[v] = period
                    output.writePeriod(v, period)
                }
            case 13:
                // (`ems_vib`: below on even ticks, above on odd.)
                let period = count & 1 == 0 ? voices[v].period &- parameter : voices[v].period &+ parameter
                output.timed(at: at)
                periods[v] = period
                output.writePeriod(v, period)
            default:
                continue
            }
            at += Self.commandClocks
        }
        count &+= 1
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

/// Editeur Musical Séquentiel, played on Paula by `PaulaTickRenderer`.
extension EMSPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Editeur Musical Séquentiel")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Thomas Pimmel's tracker; \(patternCount) pattern\(patternCount == 1 ? "" : "s"), \(sampleCount) sample\(plural)"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -22.3 dB.)
    var gain: Float { 0.37 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
