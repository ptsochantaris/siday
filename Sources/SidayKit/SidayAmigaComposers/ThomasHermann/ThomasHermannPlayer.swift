// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Thomas Hermann's replayer of 1989, from Magic Bytes' Beam, as Wanted Team adapted it for
// EaglePlayer ("Thomas Hermann player module V1.1 (1 Feb 2002)", carried by UADE as players/ThomasHermann,
// whose source UADE also carries as amigasrc/players/wanted_team/ThomasHermann/src/Thomas Hermann_v2.asm,
// with the game's own code for its interrupts left in it as comments). The labels given are that source's.

/// The music of Thomas Hermann for Magic Bytes' games (Beam, Blue Angel 69, Nightdawn, of 1989 and 1990): a
/// tracker's patterns, four voices of rows of three bytes, a note, a sample and an effect; the samples in a
/// file beside it (`NAME.smp`), or for Beam each in a file of its own, in the folder `Instruments` beside it.
///
/// The file has no mark: its first eight longs are where its tables are, from an origin it keeps at 46 (the
/// place the editor had it at): for each voice a table of 256 patterns, by position, and a table of 256
/// transpositions; then the loop, end and first positions, the number of samples, where their table is,
/// the rows of a pattern less one (41), the timer the song is played by (a word, 42) and its speed (44), the
/// origin, and a byte for each voice that is not to be played (50 to 53). The samples' table, 32 places at
/// 5,184, and their records, 48 bytes each from 5,312 (the first empty): length, volume, a kind, where its
/// sound is, where its loop begins and how long it is, a period of its own, its file's name, and how it is
/// to be repeated, an envelope's rates and levels, and the speed of its slides; the patterns from 6,784.
///
/// A row's note is a semitone (high nibble) in an octave (low: 15, 0, 1 or 2, from low to high); $CF plays
/// the sample at its own period, $DF lets it go (its envelope released), $EF stops it, $FF is nothing. The
/// effect's first bit slides the note to its period, and its second leaves the voice playing and gives it
/// the sample to go on to. A row is read a tick before its notes are played, and the voices about to play
/// one are turned off then; a row takes the song's speed and two ticks.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that
/// player tells her. The song runs on the module's own timer (the CIA's, 16,384 or 17,408, some 43 or 41
/// times a second), and the slides and envelopes on another, fifty times a second, which is how the game
/// ran them (from the beam's frames); Wanted Team's module set its timer with the bytes of the word the
/// wrong way round, and in UADE they are run some 26 times a second (`wantedTeamsTimer`), slower by half.
/// Paula's audio interrupts are the player's own as well, and are followed as they fall: it counts a
/// sample's interrupts, one waiting from when the voice was turned off (Paula asks for one as she stops), its
/// start's, and each as she comes to the end of what she is playing; at the third a sample played once is
/// stopped, and at the second one repeated is given its loop, to go on to after what she is playing. So a
/// sample after another on its voice is heard once before it stops or loops, and a voice's first, twice.
///
/// The songs: one, but for two files the player knows by their size (Blue Angel 69's five and Beam's
/// unused tunes' three), whose positions it has in tables of its own. A song goes round from its loop
/// position once it has played its end position's last row; the song's end is said then.
struct ThomasHermannPlayer: ~Copyable {
    /// The module, its samples and what follows them, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the noughts after the samples.
    let silenceAt: Int
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    /// The place the editor had the module at, which its pointers are from (46).
    private let origin: UInt32
    /// The number of samples (35), and where each record's sound is in `memory` (`InitPlayer` sets each
    /// record's address: the first record after the empty one, at 5,360, and on).
    let sampleCount: Int
    private let sounds: [Int]
    /// The samples' files that were not found among the instruments given, by name.
    let missingInstruments: [String]
    /// The song's positions: loop, end and first, and its speed, for each song (`SongData`, `SongData3`,
    /// `SongData5`).
    private let songTable: [(loop: UInt8, end: UInt8, first: UInt8, speed: UInt8)]
    /// The song's timer: the CIA's count, and a tick of it in Paula's clocks.
    let timer: UInt16
    let songClocks: UInt64

    var songCount: Int { songTable.count }
    private(set) var song = 0
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// True to run the slides and envelopes as Wanted Team's module does in UADE (`InitSound`): on CIA-B's
    /// timer B, set from EaglePlayer's timer of fifty times a second ($376B) with its bytes swapped ($6B37),
    /// some 25.8 times a second. False (the game's own way, as Blue Angel 69's custom module plays it): fifty.
    let wantedTeamsTimer: Bool
    var effectsClocks: UInt64 {
        wantedTeamsTimer ? UInt64(0x6B37 + 1) * 5 : UInt64(TFMXTiming.fiftyTimes)
    }

    // MARK: The player's variables, named as its source names them.

    /// The song's loop, end and present positions and its speed (the module's bytes 32, 33, 34 and 44, which
    /// `InitSound` sets and `Play` moves on).
    private var loopPosition: UInt8 = 0
    private var endPosition: UInt8 = 0
    private var position: UInt8 = 0
    private var speed: UInt8 = 0
    /// The ticks left of the row (`lbB00C7CD`: nought, a row to read; negative, its notes to play), the
    /// row (`lbB00C7CE`), the note last played (`lbB00C7CF`) and the transposition last read (`lbW00C804`).
    private var countdown: UInt8 = 0
    private var row: UInt8 = 0
    private var lastNote: UInt8 = 0
    private var transpose: UInt8 = 0
    /// Each voice's row as read: note, sample and effect (`lbB00C7BC`).
    private var rowNotes = InlineArray<4, UInt8>(repeating: 0)
    private var rowSamples = InlineArray<4, UInt8>(repeating: 0)
    private var rowEffects = InlineArray<4, UInt8>(repeating: 0)
    /// The sample being started, as `lbW00C85C` holds it: its length in bytes, volume, sound, how it is
    /// repeated, where its loop begins and its length, and its period and own period.
    private var workLength: UInt16 = 0xFFFF
    private var workVolume: UInt8 = 0xFF
    private var workSound: UInt32 = 0
    private var workMode: UInt8 = 0xFF
    private var workLoopStart: UInt32 = 0xFFFF_FFFF
    private var workLoopLength: UInt16 = 0xFFFF
    private var workPeriod: UInt16 = 0xFFFF
    private var workOwnPeriod: UInt16 = 0xFFFF
    /// The effects' interrupt's count, which runs the envelopes every fourth time (`lbL00C9D8`).
    private var envelopeCountdown: UInt8 = 3

    /// Each voice's state, as the player's tables of four hold it.
    private struct Voice {
        /// The sample's record (`lbL00CD44`), as a place in the module.
        var record = -1
        /// Whether the envelope runs (`lbL00CD14`: the sample's kind of repeat), and is let go (`lbL00CD34`).
        var envelope: UInt8 = 0
        var release: UInt8 = 0
        /// The audio interrupts counted since the sample began (`lbL00CD04`), the sample's kind of repeat
        /// (`lbL00CD0C`: nought, played once; else repeated from its loop), its loop (`lbL00CD1C`,
        /// `lbL00CD2C`).
        var interrupts: UInt8 = 0
        var mode: UInt8 = 0
        var loopStart: UInt32 = 0
        var loopLength: UInt16 = 0
        /// The envelope: its level (`lbL00CD3C`, the high byte heard), the step it moves by
        /// (`lbL00CD54`), its stage (`lbL00CD5C`) and the sample's volume it scales (`lbL00CD64`).
        var level: UInt16 = 0
        var step: UInt16 = 0
        var stage: UInt8 = 0
        var envelopeVolume: UInt8 = 0
        /// The slide: whether it runs (`lbL00CD6C`), the period it is at (`lbL00CD74`) and the one it goes
        /// to (`lbL00CD7C`).
        var sliding: UInt8 = 0
        var slidePeriod: UInt16 = 0
        var slideTarget: UInt16 = 0

        // Paula's part: whether the voice's DMA is on, its audio interrupt is let through and asked for;
        // what her location and length registers hold, and when she comes to the end of what she is
        // playing (in Paula's clocks); the period she plays at; and when the interrupt of its start is due,
        // if it is still to come.
        var dma = false
        var enabled = false
        var requested = false
        var location = 0
        var length: UInt16 = 0
        var endsAt: UInt64 = 0
        var period: UInt16 = 0
        var startInterrupt: UInt64?
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())

    /// What each of Paula's period and volume registers was last given, and what they held as the tick
    /// just run began.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)

    /// The time, in Paula's clocks from the song's start: now (the tick being run begins), when the song's
    /// timer and the effects' next come, and what is left to do of the song's tick, and when.
    private var now: UInt64 = 0
    private var nextSong: UInt64 = 0
    private var nextEffects: UInt64 = 0
    private var tickClocks = 1
    private enum Step { case read, voice(Int), on(Int) }
    private var steps: [(at: UInt64, step: Step)] = []
    /// When the song came to its end, in the dry run.
    private var endedAt: UInt64?
    /// When the song's tick being run began.
    private var songTickAt: UInt64 = 0

    /// Where in its tick, in Paula's clocks, what the player does falls in UADE (from its dumps of the
    /// music): the first voice's note, the wait for the beam (`DMAWait`) before its DMA is turned on, and the
    /// next voice's note after a note or after none; the voices turned off as a row is read; and Paula's
    /// interrupt after a voice is started (at the beam's next line, half a line on the average).
    static let firstNote: UInt64 = 300
    static let noteWait: UInt64 = 2570
    static let noteClocks: UInt64 = 3055
    static let quietClocks: UInt64 = 40
    static let readClocks: UInt64 = 200
    static let startInterrupt: UInt64 = 114
    /// Both timers are started by `InitSound`, the effects' first, and each comes first a whole tick of its
    /// own later: the song's this much after its own, as it is started after the effects' in UADE (the
    /// median of its dumps of the music).
    static let songLate: UInt64 = 1165
    /// The shortest tick that is run (see `run`).
    static let shortestTick: UInt64 = 1000

    /// The periods of an octave (`lbW00C7A4`).
    private static let periodTable: [UInt16] = [0x1AC, 0x194, 0x17C, 0x168, 0x154, 0x140, 0x12E, 0x11E, 0x10E, 0xFE, 0xF0, 0xE2]
    /// Blue Angel 69's songs and Beam's unused tunes' (`SongData5`, `SongData3`): loop, end and first
    /// positions, and speed.
    private static let blueAngel: [(loop: UInt8, end: UInt8, first: UInt8, speed: UInt8)] = [
        (0x11, 0x5A, 0xFF, 3), (0x60, 0x85, 0x5F, 5), (0x90, 0xB5, 0x8F, 5), (0xC0, 0xC7, 0xBF, 3), (0xD5, 0xD6, 0xCF, 3),
    ]
    private static let kramer: [(loop: UInt8, end: UInt8, first: UInt8, speed: UInt8)] = [
        (0x00, 0x6F, 0xFE, 3), (0x80, 0x87, 0x7F, 3), (0x89, 0x89, 0x88, 3),
    ]
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostClocks: UInt64 = 3600 * 3_546_895

    // MARK: - Reading

    @inline(__always) private static func byte(_ data: [UInt8], _ at: Int) -> UInt8 { at >= 0 && at < data.count ? data[at] : 0 }
    @inline(__always) private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        UInt16(byte(data, at)) << 8 | UInt16(byte(data, at + 1))
    }
    @inline(__always) private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2))
    }

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }
    /// A pointer of the module's, as a place in it; for one outside it, its end, where nought is read.
    @inline(__always) private func pointer(_ at: Int) -> Int {
        let place = long(at) &- origin
        return place < UInt32(fileSize) ? Int(place) : fileSize
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`; it has no mark): more than 6,848 bytes, an
    /// origin at 46 that is even and more than nought, and its first eight longs, from it, the four voices'
    /// tables of patterns (1,024 bytes each from 64) and of transpositions (256 bytes each after them).
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count > 6848 else { return false }
        let origin = long(data, 46)
        guard origin != 0, origin & 0x8000_0001 == 0 else { return false }
        for i in 0 ..< 8 {
            let want = i < 4 ? 64 + 1024 * i : 4160 + 256 * (i - 4)
            guard long(data, 4 * i) &- origin == UInt32(want) else { return false }
        }
        return true
    }

    /// The names of the samples' files, as `ExtLoad` loads them from the folder `Instruments` when there is
    /// no file of samples beside the module: each record's name (from its 14th byte), from after its last
    /// colon or stroke.
    static func instrumentNames(_ data: [UInt8]) -> [String] {
        var names: [String] = []
        for k in 0 ..< min(32, Int(byte(data, 35))) {
            var bytes: [UInt8] = []
            var at = 5360 + 48 * k + 14
            while at < data.count, data[at] != 0, bytes.count < 34 {
                bytes.append(data[at])
                if data[at] == 0x3A || data[at] == 0x2F { bytes.removeAll() }
                at += 1
            }
            var name = ""
            for b in bytes { name.unicodeScalars.append(Unicode.Scalar(b)) }
            names.append(name)
        }
        return names
    }

    /// The name of a file, as it is looked for: without regard to case, as the Amiga's disks find them.
    private static func key(_ name: String) -> String {
        var key = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            key.append(scalar.value >= 0x41 && scalar.value <= 0x5A ? Unicode.Scalar(scalar.value + 0x20)! : scalar)
        }
        return String(key)
    }

    /// Reads the module and its samples, and starts song `song` (the first, if it has no such song): the
    /// file of samples beside it (`NAME.smp`, which UADE's player looks for as `SMP.NAME`), the samples one
    /// after the other, in their records' order; or, with none, each sample's own file from the folder
    /// `Instruments` beside it, by name (an IFF 8SVX file's sound taken from its 104th byte, as the player
    /// takes it), a sample whose file is not given not heard. A module whose patterns go past its end is
    /// refused, as `InitPlayer` refuses it.
    init(_ data: [UInt8], samples: [UInt8]? = nil, instruments files: [(name: String, bytes: [UInt8])] = [], song: Int = 0,
         wantedTeamsTimer: Bool = false) throws(TuneError) {
        self.wantedTeamsTimer = wantedTeamsTimer
        fileSize = data.count
        origin = Self.long(data, 46)
        let count = min(32, Int(Self.byte(data, 35)))
        sampleCount = count
        timer = Self.word(data, 42)
        // (A timer of less than 1,000, which no file has, is taken as 1,000, that a broken file cannot run
        // the player thousands of times a second.)
        songClocks = UInt64(max(1000, Int(timer)) + 1) * 5

        // Where the samples go: after the module, a file of them whole, or each instrument's file.
        var at = (data.count + 15) & ~15
        var sounds = [Int](repeating: -1, count: count)
        var pieces: [(at: Int, bytes: [UInt8])] = []
        var missing: [String] = []
        if let samples {
            // (`InitPlayer`: each record's sound after the one before, by the long that ends at its length.)
            pieces.append((at, samples))
            var place = UInt32(0)
            for k in 0 ..< count {
                if place < UInt32(samples.count) { sounds[k] = at + Int(place) }
                place &+= Self.long(data, 5360 + 48 * k - 2)
            }
            at += (samples.count + 15) & ~15
        } else {
            var byKey = [String: [UInt8]]()
            for file in files { byKey[Self.key(file.name)] = file.bytes }
            for (k, name) in Self.instrumentNames(data).enumerated() {
                guard !name.isEmpty, let bytes = byKey[Self.key(name)] else {
                    if !name.isEmpty, !missing.contains(name) { missing.append(name) }
                    continue
                }
                pieces.append((at, bytes))
                let form = bytes.count >= 4 && bytes[0] == 0x46 && bytes[1] == 0x4F && bytes[2] == 0x52 && bytes[3] == 0x4D
                sounds[k] = at + (form ? 104 : 0)
                at += (bytes.count + 15) & ~15
            }
        }
        self.sounds = sounds
        missingInstruments = missing
        silenceAt = at
        memoryCapacity = at + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        for piece in pieces {
            for (i, b) in piece.bytes.enumerated() { memory[piece.at + i] = b }
        }

        // (`InitPlayer`: the song's size, from the furthest pattern, picks the files of more than one song.)
        var furthest = -1
        for i in 0 ..< 1024 {
            // (Compared as the addresses they are made, with their signs.)
            let place = Int(Int32(bitPattern: Self.long(data, 64 + 4 * i) &- origin))
            if place > furthest { furthest = place }
        }
        let size = furthest + 64
        if size == 11792 {
            songTable = Self.blueAngel
        } else if size == 10112 {
            songTable = Self.kramer
        } else {
            let first = Self.byte(data, 34)
            songTable = [(Self.byte(data, 32), Self.byte(data, 33), first & 0x80 != 0 ? first : 0xFF, Self.byte(data, 44))]
        }

        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Thomas Hermann module") }
        guard size <= data.count else { throw .malformed("the module is cut short") }
        guard samples != nil || pieces.count > 0 || count == 0 else {
            throw .missingCompanion("Its samples, which are kept in a file beside it (NAME.smp) or in an Instruments folder beside it, were not given with it.")
        }
        try select(song: song >= 0 && song < songCount ? song : 0)
    }

    deinit { memory.deallocate() }
}

// MARK: - Playing

extension ThomasHermannPlayer {
    /// Starts song `song`; and finds how long it is, played through to its end for up to an hour.
    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        start()
        var none = TFMXSilentOutput()
        while endings == 0, now < Self.mostClocks {
            _ = run(&none)
        }
        // (It comes to its end as its last row's notes are played: the row's ticks are still to be heard.)
        lengthClocks = endedAt.map { $0 + UInt64(Int(speed) + 2) * songClocks }
        start()
    }

    /// `InitSound`: the song's positions and speed, and the two timers started;
    /// and the player's other variables as a module newly loaded has them.
    private mutating func start() {
        let entry = songTable[song]
        loopPosition = entry.loop
        endPosition = entry.end
        position = entry.first
        speed = entry.speed
        countdown = entry.speed
        row = 0
        lastNote = 0
        transpose = 0
        rowNotes = .init(repeating: 0)
        rowSamples = .init(repeating: 0)
        rowEffects = .init(repeating: 0)
        workLength = 0xFFFF
        workVolume = 0xFF
        workSound = 0
        workMode = 0xFF
        workLoopStart = 0xFFFF_FFFF
        workLoopLength = 0xFFFF
        workPeriod = 0xFFFF
        workOwnPeriod = 0xFFFF
        envelopeCountdown = 3
        voices = .init(repeating: Voice())
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = .init(repeating: 0)
        volumesBefore = .init(repeating: 0)
        now = 0
        nextSong = songClocks + Self.songLate
        nextEffects = effectsClocks
        tickClocks = 1
        steps.removeAll()
        endings = 0
        endedAt = nil
    }

    /// Runs what falls in the time from now to the next of the two timers: the song's tick (`Play`) and the
    /// effects' (`lbC00C9DC`) as they come, what is left of the song's tick, and Paula's audio interrupts
    /// (`lbC00CD86`), each at its moment. (A timer that comes less than `shortestTick` after the tick's start
    /// is run within it, at its moment, that no tick is too short to be heard.) Returns the time run in
    /// milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        let begin = now
        var told = UInt64.max
        // The tick ends as the first timer comes that is not too soon after its start.
        let soonest = begin + Self.shortestTick
        let songEnd = nextSong >= soonest ? nextSong : nextSong + songClocks
        let effectsEnd = nextEffects >= soonest ? nextEffects : nextEffects + effectsClocks
        let end = min(songEnd, effectsEnd)
        // What is to be done, in order of time, up to it.
        while true {
            var at = end
            var which = -1
            if nextSong < at {
                at = nextSong
                which = 5
            }
            if nextEffects < at {
                at = nextEffects
                which = 6
            }
            if let first = steps.first, first.at < at {
                at = first.at
                which = 4
            }
            for v in 0 ..< 4 {
                if let due = interruptDue(v), due < at {
                    at = due
                    which = v
                }
            }
            switch which {
            case -1: break
            case 4:
                let step = steps.removeFirst()
                runStep(step.step, at: step.at, begin, &told, &output)
                continue
            case 5:
                play(at: at)
                nextSong += songClocks
                continue
            case 6:
                nextEffects += effectsClocks
                effectsTick(at: at, begin, &told, &output)
                continue
            default:
                interrupt(which, at: at, begin, &told, &output)
                continue
            }
            break
        }
        now = end
        tickClocks = Int(end - begin)
        return Int((end - begin) * 1000 / 3_546_895)
    }

    /// Says when what follows is told Paula, if it is later than what was told before.
    private func tell<Output: TFMXOutput>(_ at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        if at != told {
            output.timed(at: Int(at - begin))
            told = at
        }
    }

    /// `Play`: the song's tick. With nought left of the row, its row is read; with less than nought, its
    /// notes are played; else a tick of the row goes by.
    private mutating func play(at: UInt64) {
        songTickAt = at
        if countdown == 0 {
            steps.append((at + Self.readClocks, .read))
        } else if countdown & 0x80 != 0 {
            countdown = speed
            steps.append((at + Self.firstNote, .voice(0)))
        } else {
            countdown &-= 1
        }
    }

    private mutating func runStep<Output: TFMXOutput>(_ step: Step, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        switch step {
        case .read:
            for v in 0 ..< 4 { readRow(v, at: at, begin, &told, &output) }
            countdown &-= 1
        case let .voice(v):
            let started = playNote(v, at: at, begin, &told, &output)
            if started { steps.append((at + Self.noteWait, .on(v))) }
            if v < 3 {
                steps.append((at + (started ? Self.noteClocks : Self.quietClocks), .voice(v + 1)))
                steps.sort { $0.at < $1.at }
            } else {
                nextRow()
            }
        case let .on(v):
            // (`lbC00D3DE`, after its wait: the voice's interrupt let through, and its DMA turned on.)
            enableInterrupt(v, at: at, begin, &told, &output)
            dmaOn(v, at: at, begin, &told, &output)
        }
    }

    /// The row on, after its notes: at the end of the pattern, the next position, or at the end position the
    /// loop position, and the song's end said (`lbC00CFB4`).
    private mutating func nextRow() {
        let was = row
        row &+= 1
        guard was == byte(41) else { return }
        row = 0
        if position == endPosition {
            position = loopPosition
            endings += 1
            if endedAt == nil { endedAt = songTickAt }
        } else {
            position &+= 1
        }
    }

    /// `lbC00CFF8`: voice `v`'s row of the pattern at the present position, transposed; and the voice
    /// turned off if it is to start a note (unless its effect leaves it playing).
    private mutating func readRow<Output: TFMXOutput>(_ v: Int, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        let p = Int(position)
        transpose = byte(pointer(16 + 4 * v) + p)
        let place = pointer(pointer(4 * v) + 4 * p) + 3 * Int(row)
        var note = byte(place)
        rowNotes[v] = note
        rowSamples[v] = byte(place + 1)
        let effect = byte(place + 2)
        rowEffects[v] = effect
        // (`lbC00D236`: the transposition added to the semitone, and the octave moved by one if it goes
        // out of the twelve.)
        if note < 0xC0 {
            var semitone = (note >> 4) &+ transpose
            if semitone & 0x80 != 0 {
                semitone &-= 4
                note &-= 1
            } else if Int8(bitPattern: semitone) >= 12 {
                semitone &+= 4
                note &+= 1
            }
            note = semitone << 4 | note & 15
            rowNotes[v] = note
        }
        if effect & 2 == 0, note < 0xC0 || note == 0xCF { stopVoice(v, at: at, begin, &told, &output) }
    }

    /// `lbC00D092`: the voice's DMA turned off, its interrupt kept back, and its envelope stopped.
    private mutating func stopVoice<Output: TFMXOutput>(_ v: Int, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        dmaOff(v, at: at, begin, &told, &output)
        voices[v].enabled = false
        voices[v].envelope = 0
    }

    /// `lbC00D05A`: voice `v`'s note, if it is to be played; true if a sample is started.
    private mutating func playNote<Output: TFMXOutput>(_ v: Int, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) -> Bool {
        // (A voice the module says is not to be played is passed over.)
        guard byte(50 + v) == 0 else { return false }
        let note = rowNotes[v]
        guard note != 0xFF else { return false }
        lastNote = note
        if note == 0xDF {
            voices[v].release = 0xFF
            return false
        }
        if note == 0xEF {
            stopVoice(v, at: at, begin, &told, &output)
            return false
        }
        // `lbC00D0BA`: the sample's record copied, and its period found from the note.
        let table = pointer(36) + 4 * Int(rowSamples[v])
        // (Of the table only its 32 places are pointers the player has made addresses of; past them, a
        // record of noughts.)
        let record = table >= 5184 && table < 5312 ? pointer(table) : fileSize
        workOwnPeriod = word(record + 12)
        workLength = word(record)
        workVolume = byte(record + 2)
        workSound = UInt32(truncatingIfNeeded: sound(record))
        workMode = byte(record + 0x23)
        workLoopStart = UInt32(word(record + 8))
        workLoopLength = word(record + 10)
        var period = UInt16(rowSamples[v]) << 2
        if note != 0xCF {
            guard note < 0xC0 else { return false }
            period = Self.periodTable[Int(note >> 4)]
            let octave = note & 15
            if byte(record + 3) == 1 {
                switch octave {
                case 1: break
                case 2:
                    period >>= 1
                    guard period > 0x82 else { return false }
                case 0: period <<= 1
                case 15: period <<= 2
                default: return false
                }
                workPeriod = period
            } else {
                // (`lbC00D17E`: a sample of more than one octave, each twice as long as the one above it.)
                switch octave {
                case 3:
                    period >>= 1
                    guard period > 0x82 else { return false }
                    workPeriod = period
                case 2: workPeriod = period
                case 1: twoOctaves(period)
                case 0: fourOctaves(period)
                case 15: fourOctaves(period << 1)
                default: return false
                }
            }
        } else if byte(record + 3) != 1 {
            twoOctaves(period)
        }
        startSample(v, record: record, at: at, begin, &told, &output)
        return true
    }

    /// `lbC00D1D6`: the octave of a sample twice the length of the first, after it.
    private mutating func twoOctaves(_ period: UInt16) {
        workSound &+= UInt32(workLength)
        workLength <<= 1
        workPeriod = period
        workLoopStart <<= 1
        workLoopLength <<= 1
    }

    /// `lbC00D1FE`: the octave of a sample four times the length of the first, after the first two.
    private mutating func fourOctaves(_ period: UInt16) {
        workPeriod = period
        workSound &+= UInt32(workLength) * 3
        workLength <<= 2
        workLoopStart <<= 2
        workLoopLength <<= 2
    }

    /// Where a record's sound is in `memory`: as `InitPlayer` set it for a sample's record, or silence.
    private func sound(_ record: Int) -> Int {
        let k = (record - 5360) / 48
        guard record >= 5360, (record - 5360) % 48 == 0, k < sounds.count, sounds[k] >= 0 else { return silenceAt }
        return sounds[k]
    }

    /// `lbC00D27E`: the sample started on voice `v`: Paula told its place, length and period (unless it
    /// slides to it), its envelope begun or its volume, and its interrupts' count begun; its DMA is turned
    /// on after the player's wait.
    private mutating func startSample<Output: TFMXOutput>(_ v: Int, record: Int, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        voices[v].record = record
        tell(at, begin, &told, &output)
        // (What Paula has gone on to play so far is of what she was given before.)
        catchUp(v, to: at)
        let place = memoryPlace(workSound)
        voices[v].location = place
        voices[v].length = workLength >> 1
        output.takeNextBuffer(v, start: place, length: workLength >> 1)
        let period = lastNote == 0xCF ? workOwnPeriod : workPeriod
        voices[v].slideTarget = period
        voices[v].sliding = 0xFF
        if rowEffects[v] & 1 == 0 {
            voices[v].sliding = 0
            writePeriod(v, period, at: at, &output)
            voices[v].slidePeriod = period
        }
        voices[v].release = 0
        voices[v].mode = workMode
        voices[v].envelope = workMode
        var volume = UInt16(workVolume)
        if workMode != 0 {
            voices[v].loopStart = workLoopStart &+ workSound
            voices[v].loopLength = workLoopLength >> 1
            voices[v].stage = 0
            voices[v].envelopeVolume = workVolume
            if workMode & 0x80 == 0 {
                voices[v].level = 0x4000
            } else if byte(record + 0x24) != 0 {
                volume = 0
            } else {
                voices[v].step = 0
                voices[v].stage = 1
                voices[v].level = UInt16(byte(record + 0x28)) << 8
                writeEnvelopeVolume(v, byte(record + 0x28), &output)
                voices[v].interrupts = 0
                return
            }
        }
        writeVolume(v, volume & 0x7F, &output)
        voices[v].interrupts = 0
    }

    /// A sound's address, as a place in `memory` (silence for one outside it).
    private func memoryPlace(_ address: UInt32) -> Int {
        address < UInt32(memoryCapacity) ? Int(address) : silenceAt
    }

    private mutating func writePeriod<Output: TFMXOutput>(_ v: Int, _ period: UInt16, at: UInt64, _ output: inout Output) {
        periods[v] = period
        output.writePeriod(v, period)
        catchUp(v, to: at)
        // (What is left of what Paula is playing takes as much longer, or shorter, as the period has.)
        if voices[v].dma, at < voices[v].endsAt {
            let old = Self.clocksPerByte(voices[v].period), new = Self.clocksPerByte(period)
            voices[v].endsAt = at + (voices[v].endsAt - at) * new / old
        }
        voices[v].period = period
    }

    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume
        output.writeVolume(v, volume)
    }

    /// `lbC00CADA`: the envelope's level heard, as a part of the sample's volume.
    private mutating func writeEnvelopeVolume<Output: TFMXOutput>(_ v: Int, _ level: UInt8, _ output: inout Output) {
        let volume = (UInt16(voices[v].envelopeVolume) * UInt16(level)) >> 6
        writeVolume(v, volume & 0x7F, &output)
    }

    // MARK: Paula's interrupts

    /// How long Paula takes over a byte at a period, in her clocks (a period of nought is the longest).
    private static func clocksPerByte(_ period: UInt16) -> UInt64 { period == 0 ? 65536 : UInt64(max(Int(Paula.shortestPeriod), Int(period))) }

    /// How long she takes over a buffer of `length` words (nought is 65,536).
    private static func clocks(_ length: UInt16, _ period: UInt16) -> UInt64 {
        UInt64(length == 0 ? 65536 : Int(length)) * 2 * clocksPerByte(period)
    }

    /// When voice `v`'s next audio interrupt comes, if it is let through: the one of its start, or a byte
    /// after she has come to the end of what she was playing (once she has gone on to what she was given).
    private func interruptDue(_ v: Int) -> UInt64? {
        guard voices[v].enabled, voices[v].dma else { return nil }
        if let start = voices[v].startInterrupt { return start }
        return voices[v].endsAt + Self.clocksPerByte(voices[v].period)
    }

    /// The interrupts that are not let through, up to `at`: what Paula has gone on to play, and her asking.
    private mutating func catchUp(_ v: Int, to at: UInt64) {
        guard voices[v].dma, !voices[v].enabled else { return }
        if voices[v].startInterrupt.map({ $0 <= at }) == true {
            voices[v].startInterrupt = nil
            voices[v].requested = true
        }
        if voices[v].endsAt + Self.clocksPerByte(voices[v].period) <= at {
            voices[v].requested = true
            let each = Self.clocks(voices[v].length, voices[v].period)
            let past = at - voices[v].endsAt
            voices[v].endsAt += (past / each + 1) * each
        }
    }

    /// Voice `v`'s audio interrupt, at `at`: what she has gone on to play, and the player's handler.
    private mutating func interrupt<Output: TFMXOutput>(_ v: Int, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        if voices[v].startInterrupt != nil {
            voices[v].startInterrupt = nil
        } else {
            voices[v].endsAt += Self.clocks(voices[v].length, voices[v].period)
        }
        voices[v].requested = true
        handle(v, at: at, begin, &told, &output)
    }

    /// `lbC00CD86`: the player's audio interrupt for voice `v`. A sample played once is stopped at its third
    /// interrupt, as it comes to its end (its start's and one waiting from when the voice was turned off
    /// come before); one repeated is given its loop at its second, to go on with once it has been played.
    private mutating func handle<Output: TFMXOutput>(_ v: Int, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        voices[v].requested = false
        if voices[v].mode == 0 {
            if voices[v].interrupts >= 2 {
                voices[v].enabled = false
                voices[v].interrupts = 0
                dmaOff(v, at: at, begin, &told, &output)
            } else {
                voices[v].interrupts &+= 1
            }
        } else if voices[v].interrupts == 1 {
            tell(at, begin, &told, &output)
            let place = memoryPlace(voices[v].loopStart)
            voices[v].location = place
            voices[v].length = voices[v].loopLength
            output.takeNextBuffer(v, start: place, length: voices[v].loopLength)
            voices[v].enabled = false
        } else {
            voices[v].interrupts &+= 1
        }
    }

    /// The voice's interrupt let through (INTENA); one it has asked for comes at once.
    private mutating func enableInterrupt<Output: TFMXOutput>(_ v: Int, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        catchUp(v, to: at)
        voices[v].enabled = true
        if voices[v].requested { handle(v, at: at, begin, &told, &output) }
    }

    /// The voice's DMA turned on: Paula starts what she was last given, if she is not playing, and asks for
    /// its interrupt at the beam's next line.
    private mutating func dmaOn<Output: TFMXOutput>(_ v: Int, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        guard !voices[v].dma else { return }
        tell(at, begin, &told, &output)
        output.on(v)
        voices[v].dma = true
        voices[v].endsAt = at + Self.clocks(voices[v].length, voices[v].period)
        voices[v].startInterrupt = at + Self.startInterrupt
    }

    /// The voice's DMA turned off: Paula, if she was playing, asks for its interrupt as she stops.
    private mutating func dmaOff<Output: TFMXOutput>(_ v: Int, at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        catchUp(v, to: at)
        tell(at, begin, &told, &output)
        output.off(v)
        if voices[v].dma { voices[v].requested = true }
        voices[v].dma = false
        voices[v].startInterrupt = nil
    }

    // MARK: The effects

    /// `lbC00C9DC`: the effects' tick: each voice's slide, and every fourth time each voice's envelope.
    private mutating func effectsTick<Output: TFMXOutput>(at: UInt64, _ begin: UInt64, _ told: inout UInt64, _ output: inout Output) {
        tell(at, begin, &told, &output)
        for v in 0 ..< 4 { slide(v, at: at, &output) }
        envelopeCountdown &-= 1
        guard envelopeCountdown & 0x80 != 0 else { return }
        envelopeCountdown = 3
        for v in 0 ..< 4 { envelope(v, &output) }
    }

    /// `lbC00CC56`: the period slid towards the note's by the sample's speed (its byte 45), until it is there.
    private mutating func slide<Output: TFMXOutput>(_ v: Int, at: UInt64, _ output: inout Output) {
        guard voices[v].sliding != 0 else { return }
        let speed = UInt16(byte(voices[v].record + 0x2D))
        var period = voices[v].slidePeriod
        let target = voices[v].slideTarget
        var arrived = false
        if period < target {
            period &+= speed
            arrived = period >= target
        } else if period == target {
            arrived = true
        } else {
            period &-= speed
            arrived = period <= target
        }
        if arrived {
            period = target
            voices[v].sliding = 0
        }
        voices[v].slidePeriod = period
        writePeriod(v, period, at: at, &output)
    }

    /// `lbC00CA4A`: the envelope of a sample with one (its kind of repeat negative), from its attack's level
    /// through its decay's and sustain's (the rates and levels its bytes 36 to 42 give), or let go to nought.
    private mutating func envelope<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        guard voices[v].envelope != 0 else { return }
        let record = voices[v].record
        if voices[v].release & 0x80 != 0 {
            // `lbC00CB6E`: let go, from where it is, at the release's rate.
            if voices[v].stage == 4 {
                moveEnvelope(v, to: 0, then: 0, rate: 1, &output)
            } else {
                voices[v].stage = 4
                let rate = max(1, UInt16(byte(record + 0x27)))
                voices[v].step = Self.divs(0 &- UInt32(voices[v].level), rate)
                moveEnvelope(v, to: 0, then: 0, rate: 1, &output)
            }
            if voices[v].stage == 5 { voices[v].envelope = 0 }
            return
        }
        guard voices[v].envelope & 0x80 != 0 else { return }
        switch voices[v].stage {
        case 0:
            // (Its attack: from nought, the attack's level in as many steps as its rate.)
            let rate = UInt16(byte(record + 0x24))
            guard rate != 0 else { return }
            let step = (UInt16(byte(record + 0x28)) << 8) / rate
            voices[v].step = step
            voices[v].level = step
            voices[v].stage = 1
            writeEnvelopeVolume(v, UInt8(step >> 8), &output)
        case 1: moveEnvelope(v, to: byte(record + 0x28), then: byte(record + 0x29), rate: max(1, byte(record + 0x25)), &output)
        case 2: moveEnvelope(v, to: byte(record + 0x29), then: byte(record + 0x2A), rate: max(1, byte(record + 0x26)), &output)
        case 3: moveEnvelope(v, to: byte(record + 0x2A), then: 0, rate: max(1, byte(record + 0x27)), &output)
        default: break
        }
    }

    /// `lbC00CBF2`: the envelope's level moved by its step; once it is at `target` (or past it), it is set
    /// there, the step to `then` found at `rate`, and the next stage begun.
    private mutating func moveEnvelope<Output: TFMXOutput>(_ v: Int, to target: UInt8, then: UInt8, rate: UInt8, _ output: inout Output) {
        let step = voices[v].step
        voices[v].level &+= step
        let heard = Int8(bitPattern: UInt8(voices[v].level >> 8))
        let there = step & 0x8000 != 0 ? heard <= Int8(bitPattern: target) : heard >= Int8(bitPattern: target)
        guard there else {
            writeEnvelopeVolume(v, UInt8(bitPattern: heard), &output)
            return
        }
        voices[v].level = UInt16(target) << 8
        writeEnvelopeVolume(v, target, &output)
        voices[v].step = Self.divs((UInt32(then) &- UInt32(target)) << 8, UInt16(rate))
        voices[v].stage &+= 1
    }

    /// The 68000's DIVS.W, its quotient's word: a quotient too big for a word leaves the dividend as it was.
    private static func divs(_ dividend: UInt32, _ divisor: UInt16) -> UInt16 {
        let d = Int32(Int16(bitPattern: divisor))
        guard d != 0 else { return UInt16(truncatingIfNeeded: dividend) }
        let q = Int32(bitPattern: dividend) / d
        guard q >= -32768, q <= 32767 else { return UInt16(truncatingIfNeeded: dividend) }
        return UInt16(truncatingIfNeeded: q)
    }

    /// Paula's period for the voice as the tick just run began (its writes in the tick are told at their
    /// moments).
    func period(_ voice: Int) -> UInt16 { periodsBefore[voice] }
    /// Paula's volume for the voice as the tick just run began, as she takes it: no more than 64.
    func volume(_ voice: Int) -> UInt16 { min(64, volumesBefore[voice]) }
    /// What the player last gave Paula's period register for the voice.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
    /// The time the tick just run took, in Paula's clocks.
    var lastTickClocks: Int { tickClocks }
    /// When the tick to be run next begins, in Paula's clocks from the song's start.
    var clock: UInt64 { now }
}

/// Thomas Hermann's music, played on Paula by `PaulaTickRenderer`.
extension ThomasHermannPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Thomas Hermann")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Thomas Hermann's player, from Magic Bytes' Beam; \(sampleCount) sample\(plural)"
        if !missingInstruments.isEmpty {
            info.shortfalls.append(Shortfall.some(missingInstruments.count, one: "sample was not found in the folder of instruments beside it, and is not heard: ",
                                                  many: "samples were not found in the folder of instruments beside it, and are not heard: ")
                + Shortfall.list(missingInstruments) + ".")
        }
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -17.9 dB.)
    var gain: Float { 0.22 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { tickClocks }
}
