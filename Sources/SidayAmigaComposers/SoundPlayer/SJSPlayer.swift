// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Scott Johnston's "SoundPlayer V4.05" ("(C) Scott Johnston 12/3/1991"), the replay routine of DMA
// Design's Lemmings (its CDTV version), as Wanted Team adapted it for EaglePlayer ("SoundPlayer V4.05 replayer
// module V1.0 (2 Mar 2003)"), carried by UADE as players/SoundPlayer, whose source UADE also carries as
// amigasrc/players/wanted_team/SoundPlayer/src/SoundPlayer_v1.asm. The labels given are that source's.

import SidayChips
import SidayFoundation

/// Scott Johnston's SoundPlayer, the driver of DMA Design's Lemmings, in which Tim Wright wrote its music (and
/// Brian Johnston and Andy Whyte that of Oh No! More Lemmings and the Christmas Lemmings): a score (`.sjs`) and
/// its samples in a file of their own beside it (the score's name with `.smp`: `tim2.sjs`, `tim2.smp`).
///
/// The score is the CIA's timer for the tick (its first word, its low byte first), which voices it has (its third
/// byte: 7 for three, 15 for four), and then rows of twelve bytes, three for each voice: a note (nought for none,
/// else one of 39 periods, from 1,076 down), an instrument (one of the samples, from one) and a command. Each voice
/// reads its own column from its own place, so that a command to wait so many rows (`$57` to `$88`, one to fifty)
/// lets the others go on without it: a voice's column is its own track, and the tracks are only side by side. The
/// other commands: `$01` the Amiga's filter off and `$02` on; `$03` to `$42` the volume (nought to 63); `$43` the
/// voice turned off; `$A7` to `$B0` and `$B1` to `$BA` the volume faded up or down a step every so many ticks
/// (one to ten); `$CF` and `$D0` the loop held and let go; `$D2` to `$DB` the rows from here played again so many
/// times, to a `$DC`; `$DD` the row read again for ever; `$DE` the end, the voice's track begun again (each voice
/// has one at the same tick in every file of the collection); and the rest marks of the game's own (twenty flags
/// set and cleared, `$BB` to `$CE`, `$D1`, `$E5` to `$F8`) and Paula's modulation of one voice by the next (`$DF` to
/// `$E4` and `$F9` to `$FD`), which no file uses and which is not played. The sample file is the instruments' IFF
/// 8SVX files one after the other (`InstallSamples`: from each `FORM`, its length and loop from its `VHDR` and its
/// sound from its `BODY`), with four bytes in place of any instrument the song has none for, up to 38.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. Its tick is the score's own timer (`InitSound` puts it in `dtg_Timer`): five of Paula's
/// clocks for each of its counts and one more, 72,505 for Tim Wright's 14,500, 49 ticks a second. A row is read
/// every sixth tick (`lbC063D18`), the first on the sixth. On every tick, first each voice not holding its loop is
/// told it (or silence, for a sample without one) and the fades move its volume; then each note begun on the tick
/// before is told Paula, its sound, period and volume, and turned on. On a row's tick each voice's track moves on
/// a row (unless it waits), the notes are begun, each turned off and its sample, period and loop kept for the next
/// tick, and the commands are done.
///
/// Wanted Team's player moves a fading voice's volume but does not tell Paula (its `ChangeVolume` is called with
/// the voice's own address, not Paula's), so that a fade is heard only as the next note begins: that is done only
/// if it is asked for (`wantedTeamsFades`), as Scott Johnston's own player tells her every step. (No file of the
/// collection fades.)
///
/// Where the player would read past the score it reads nought, and a track sent where nothing is (a `$DC` before
/// any `$D2`, to the Amiga's address nought) reads nought for ever. An instrument past the 38 (or nought) has no
/// sample, as one the sample file has none for: where the player would take one from its own variables. A sample
/// whose `VHDR` the player cannot find has nought for its length and loop, and one whose `BODY` it cannot find is
/// played from silence (where it would play the Amiga's own first bytes).
struct SJSPlayer: ~Copyable {
    /// The sample file, the score after it, and the silence, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed (`Empty`): noughts after the score.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    /// Where the score is in `memory` (the sample file is at nought), and how long each is.
    let scoreAt: Int
    let scoreSize: Int
    let sampleFileSize: Int
    /// The CIA's timer for the tick (the score's first word, its bytes swapped), and how many voices it says it
    /// has (`MI_Voices`: four for 15 in its third byte, else three; all four are played).
    let timer: UInt16
    let voiceCount: Int
    /// How many samples `InstallSamples` found in the sample file.
    let sampleCount: Int
    var songCount: Int { 1 }
    var song: Int { 0 }
    /// Whether a fade's steps are told Paula only as Wanted Team's player tells her (see the type's comment).
    let wantedTeamsFades: Bool

    /// A sample as `lbC06392C` sets it up (`lbL0643F4`, fourteen bytes each, 38 of them): where its sound is and
    /// its length in words, and where its loop is and its length (nought for none).
    private struct Sample {
        var start = 0
        var length: UInt16 = 0
        var loopStart = 0
        var loopLength: UInt16 = 0
    }

    private var samples = [Sample](repeating: Sample(), count: 38)

    /// A voice's track (from `lbL0643F4` + $214, fourteen bytes each): where it reads (the row's place in the score,
    /// from which its own three bytes are 3 times its number in), where a repeat goes back to, where it begins (nine
    /// bytes before the score, that its first row is three bytes in), how many repeats are left ($FF for none being
    /// made), and how many rows it has yet to wait.
    private struct Track {
        var at = -9
        var loopAt = SJSPlayer.nowhere
        var repeats: UInt8 = 0xFF
        var wait: UInt8 = 0
    }

    /// What the player keeps for each voice (`lbW064178` + $8C, $20 bytes each), as its fields are named here.
    private struct Voice {
        /// The sound of the note to be begun on the next tick, and its length (nought for none: $0, $4); its
        /// period ($6) and volume ($8).
        var start = 0
        var length: UInt16 = 0
        var period: UInt16 = 0
        var volume: UInt16 = 0x3F
        /// Its sample's loop ($12, $16).
        var loopStart = 0
        var loopLength: UInt16 = 0
        /// What its row gave it: a note, an instrument and a command ($18, $19, $1A).
        var note: UInt8 = 0
        var instrument: UInt8 = 0
        var command: UInt8 = 0
        /// Whether its loop is held, not told Paula again ($1B).
        var held = false
        /// Its fade: down (else up), every how many ticks (nought for none) and the count of them ($1C, $1D, $1E).
        var fadesDown = false
        var fadeEvery: UInt8 = 0
        var fadeCount: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    private var tracks = InlineArray<4, Track>(repeating: Track())
    /// The count of ticks to the next row (`$10C`).
    private var rowCount: UInt16 = 0
    /// The game's twenty flags (`$11A`), which the music sets and clears for it and nothing reads.
    private var flags = InlineArray<20, UInt8>(repeating: 0)
    private(set) var lightFilter = false
    /// Whether the voices have been pointed at silence, as `Init` (`lbC063B6C`) does before the first tick.
    private var begun = false

    /// What each of Paula's period and volume registers was last given.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)

    private(set) var endings = 0
    /// Whether a track has come to its end in the tick being run (for the song's end to be counted once).
    private var endedInTick = false
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// How long each tick is, in Paula's clocks (see the type's comment).
    let tickClocks: Int
    /// A track sent where nothing is (see the type's comment).
    private static let nowhere = Int.max / 4

    /// The table of periods (`lbW0642A6`): 39 notes, from C an octave below ProTracker's lowest, and after it, as
    /// the player would read on into them, the 256 bytes of its table of commands (`lbW0642F4`).
    static let periodTable: [UInt16] = [
        0x434, 0x3F8, 0x3C0, 0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC,
        0x1E0, 0x1C5, 0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140, 0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0,
        0x0E2, 0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0x078, 0x071,
    ]

    /// The table of commands (`lbW0642F4`): for each command byte, its routine's place in the jump table at
    /// `lbC063F64` (nought for none).
    static let commandTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        table[1] = 4
        table[2] = 8
        for c in 3 ... 0x42 { table[c] = 0x0C }
        table[0x43] = 0x10
        for c in 0x57 ... 0x88 { table[c] = 0x14 }
        for c in 0xA7 ... 0xB0 { table[c] = 0x18 }
        for c in 0xB1 ... 0xBA { table[c] = 0x1C }
        for c in 0xBB ... 0xCE { table[c] = 0x20 }
        table[0xCF] = 0x24
        table[0xD0] = 0x28
        table[0xD1] = 0x2C
        for c in 0xD2 ... 0xDB { table[c] = 0x30 }
        table[0xDC] = 0x34
        table[0xDD] = 0x38
        table[0xDE] = 0x3C
        for c in 0xDF ... 0xE4 { table[c] = 0x40 + 4 * UInt8(c - 0xDF) }
        for c in 0xE5 ... 0xF8 { table[c] = 0x58 }
        for c in 0xF9 ... 0xFD { table[c] = 0x5C + 4 * UInt8(c - 0xF9) }
        return table
    }()

    /// The period of a note (one to 255, as the player reads the word (note - 1) * 2 bytes into its table): past
    /// the 39, the table of commands' bytes as words, and past those (where it would read the samples' table) nought.
    static func period(_ note: UInt8) -> UInt16 {
        let index = Int(note) - 1
        if index < periodTable.count { return index >= 0 ? periodTable[index] : 0 }
        let at = 2 * (index - periodTable.count)
        return at + 1 < commandTable.count ? UInt16(commandTable[at]) << 8 | UInt16(commandTable[at + 1]) : 0
    }

    // MARK: - Reading

    /// A byte of the score at `at`, nought past it.
    @inline(__always) private func scoreByte(_ at: Int) -> UInt8 { at >= 0 && at < scoreSize ? memory[scoreAt + at] : 0 }

    // MARK: - Loading

    /// True for a score the player's check takes (`Check2`): its second byte (the timer's high) above $0A and no
    /// more than $A0, its third 7 or 15, the fourth, fifth, tenth and eleventh nought and the words at six and
    /// twelve nought, and the first row's three (or four) commands the same and not nought.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 15 else { return false }
        guard data[1] > 0x0A, data[1] <= 0xA0, data[3] == 0, data[4] == 0, data[9] == 0, data[10] == 0,
              data[6] == 0, data[7] == 0, data[12] == 0, data[13] == 0 else { return false }
        let command = data[5]
        guard command != 0, data[2] == 7 || data[2] == 15 else { return false }
        if data[2] == 15, data[14] != command { return false }
        return data[11] == command && data[8] == command
    }

    /// Reads the score and its sample file and starts its song. A score given no samples (an empty file) is refused,
    /// as EaglePlayer refuses it when its `ExtLoad` finds no sample file beside it.
    init(_ data: [UInt8], samples sampleFile: [UInt8], song: Int = 0, wantedTeamsFades: Bool = false) throws(TuneError) {
        func aligned(_ n: Int) -> Int { (n + 15) & ~15 }
        sampleFileSize = sampleFile.count
        scoreSize = data.count
        scoreAt = aligned(sampleFile.count)
        silenceAt = aligned(scoreAt + data.count + 4)
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in sampleFile.enumerated() { memory[i] = b }
        for (i, b) in data.enumerated() { memory[scoreAt + i] = b }
        self.wantedTeamsFades = wantedTeamsFades
        timer = data.count >= 2 ? UInt16(data[1]) << 8 | UInt16(data[0]) : 0
        voiceCount = data.count >= 3 && data[2] == 15 ? 4 : 3
        // (`DTP_InitSound` puts the timer in `dtg_Timer`; UADE's CIA runs out a count after nought.)
        tickClocks = (Int(timer) + 1) * 5
        var count = 0
        Self.installSamples(sampleFile, into: &samples, count: &count, silence: silenceAt)
        sampleCount = count
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a SoundPlayer score") }
        guard !sampleFile.isEmpty else {
            throw .missingCompanion("A SoundPlayer score keeps its samples in a file of their own (its name with .smp), which was not given with it.")
        }
        guard song == 0 else { throw .unsupported("there is no song \(song + 1)") }

        // Its length, from a playing of it in silence to its end, for up to an hour.
        start()
        let mostTicks = Int(UInt64(3600) * UInt64(Paula.clockHz) / UInt64(tickClocks))
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick a track comes to its end in is as the first was begun: its next row is read six ticks later.)
        lengthClocks = endings > 0 ? UInt64(ticks) * UInt64(tickClocks) : nil
        start()
    }

    deinit { memory.deallocate() }

    /// `InstallSamples` (`lbC0639BE`): from the sample file's start, four bytes at a time and a sample's number for
    /// each, every `FORM` set up as that sample and stepped over by its length, to the file's end or the 38th.
    private static func installSamples(_ file: [UInt8], into samples: inout [Sample], count: inout Int, silence: Int) {
        func long(_ at: Int) -> UInt32 {
            var value: UInt32 = 0
            for k in 0 ..< 4 { value = value << 8 | UInt32(at &+ k >= 0 && at &+ k < file.count ? file[at &+ k] : 0) }
            return value
        }
        // (`lbC06398A`: the chunk's name looked for, a byte at a time, from the `FORM` to so far; the place after it.)
        func find(_ name: UInt32, from: Int, within: Int) -> Int? {
            var at = from
            while at != from + within {
                if long(at) == name { return at + 4 }
                at += 1
            }
            return nil
        }
        var at = 0
        var number = 1
        while true {
            if long(at) == 0x464F_524D {
                var sample = Sample()
                // (Its lengths in bytes halved, as words; and for a sample whose `VHDR` is not found, nought.)
                var firstPart: UInt32 = 0
                if let header = find(0x5648_4452, from: at, within: 0x400) {
                    firstPart = long(header + 4)
                    sample.length = UInt16(truncatingIfNeeded: firstPart >> 1)
                    sample.loopLength = UInt16(truncatingIfNeeded: long(header + 8) >> 1)
                }
                if let body = find(0x424F_4459, from: at, within: 0x800) {
                    sample.start = body + 4
                    // (`adda.w`: the first part's length as a signed word.)
                    sample.loopStart = sample.start + Int(Int16(truncatingIfNeeded: firstPart))
                } else {
                    sample.start = silence
                    sample.loopStart = silence
                }
                samples[number - 1] = sample
                count += 1
                at &+= 4
                at &+= Int(Int32(bitPattern: long(at)))
            }
            at &+= 4
            if at >= file.count || number == 38 { break }
            number += 1
        }
    }

    /// `InitSound` and `Init`: the voices cleared, their volumes 63, and each track set to the score's beginning.
    private mutating func start() {
        voices = .init(repeating: Voice())
        tracks = .init(repeating: Track())
        rowCount = 0
        flags = .init(repeating: 0)
        lightFilter = false
        begun = false
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        endings = 0
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song == 0 else { throw .unsupported("there is no song \(song + 1)") }
        start()
    }

    /// `ChangeVolume`: seven bits, times EaglePlayer's volume, 64, over 64.
    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume & 0x7F
        output.writeVolume(v, volumes[v])
    }

    /// Runs the player for a tick (`Play`), telling `output` what Paula is to do, in the order the player tells her.
    /// Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        endedInTick = false
        if !begun {
            // (`lbC063B6C`, as the song is begun: each voice turned off and pointed at silence, a word of it.)
            begun = true
            for v in 0 ..< 4 {
                output.off(v)
                output.takeNextBuffer(v, start: silenceAt, length: 1)
            }
        }
        // `lbC063E0A`: each voice's loop told again, and its fade moved.
        for v in 0 ..< 4 {
            if !voices[v].held {
                if voices[v].loopLength != 0 {
                    output.takeNextBuffer(v, start: voices[v].loopStart, length: voices[v].loopLength)
                } else {
                    output.takeNextBuffer(v, start: silenceAt, length: 1)
                }
            }
            fade(v, &output)
        }
        // `lbC063DAA`: the notes begun on the row before told Paula and turned on.
        for v in 0 ..< 4 where voices[v].length != 0 {
            output.takeNextBuffer(v, start: voices[v].start, length: voices[v].length)
            periods[v] = voices[v].period
            output.writePeriod(v, voices[v].period)
            writeVolume(v, voices[v].volume, &output)
            output.on(v)
            voices[v].length = 0
        }
        // `lbC063D18`: a row every sixth tick.
        if rowCount == 0 {
            rowCount = 5
        } else {
            rowCount -= 1
        }
        if rowCount == 0 {
            rows()
            for v in 0 ..< 4 { note(v, &output) }
            for v in 0 ..< 4 { command(v, &output) }
        }
        return 1000 * tickClocks / Int(Paula.clockHz)
    }

    /// `lbC063E38`: a fade's step every so many ticks, down to nought or up to 63, where it stops.
    private mutating func fade<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        guard voices[v].fadeEvery != 0 else { return }
        voices[v].fadeCount &-= 1
        guard voices[v].fadeCount == 0 else { return }
        voices[v].fadeCount = voices[v].fadeEvery
        if voices[v].fadesDown {
            guard voices[v].volume != 0 else {
                voices[v].fadeEvery = 0
                return
            }
            voices[v].volume &-= 1
        } else {
            guard voices[v].volume != 0x3F else {
                voices[v].fadeEvery = 0
                return
            }
            voices[v].volume &+= 1
        }
        // (Scott Johnston's player tells Paula; Wanted Team's tells no one.)
        if !wantedTeamsFades { writeVolume(v, voices[v].volume, &output) }
    }

    /// `lbC063D70` and `lbC063D2C`: each track moved on a row, but for one waiting, which counts a row down and
    /// moves on as it comes to nought; and each voice's three bytes read from its track's row, if it is not waiting.
    private mutating func rows() {
        for v in 0 ..< 4 {
            if tracks[v].wait != 0 {
                tracks[v].wait -= 1
                if tracks[v].wait != 0 { continue }
            }
            tracks[v].at &+= 12
        }
        for v in 0 ..< 4 where tracks[v].wait == 0 {
            let at = tracks[v].at &+ 3 * v
            voices[v].note = scoreByte(at)
            voices[v].instrument = scoreByte(at &+ 1)
            voices[v].command = scoreByte(at &+ 2)
        }
    }

    /// `lbC063ECE`: a voice's note begun: the voice turned off, and the note's period and its instrument's sample
    /// and loop kept for the next tick.
    private mutating func note<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        guard voices[v].note != 0 else { return }
        output.off(v)
        voices[v].period = Self.period(voices[v].note)
        let number = Int(voices[v].instrument)
        let sample = number >= 1 && number <= 38 ? samples[number - 1] : Sample()
        voices[v].start = sample.start
        voices[v].length = sample.length
        voices[v].loopStart = sample.loopStart
        voices[v].loopLength = sample.loopLength
        voices[v].note = 0
    }

    /// `lbC063F4C`: a voice's command done, by the table of commands.
    private mutating func command<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let c = voices[v].command
        voices[v].command = 0
        switch Self.commandTable[Int(c)] {
        case 0x04:
            // (`bset #1,$BFE001`: the power light off, and the filter.)
            lightFilter = false
            output.writeLightFilter(false)
        case 0x08:
            lightFilter = true
            output.writeLightFilter(true)
        case 0x0C:
            voices[v].volume = UInt16(c - 3)
            writeVolume(v, voices[v].volume, &output)
        case 0x10:
            output.off(v)
        case 0x14:
            if tracks[v].wait == 0 { tracks[v].wait = c - 0x56 }
        case 0x18:
            voices[v].fadesDown = false
            voices[v].fadeEvery = c - 0xA6
            voices[v].fadeCount = c - 0xA6
        case 0x1C:
            voices[v].fadesDown = true
            voices[v].fadeEvery = c - 0xB0
            voices[v].fadeCount = c - 0xB0
        case 0x20:
            flags[Int(c - 0xBB)] = 0xFF
        case 0x24:
            voices[v].held = true
        case 0x28:
            voices[v].held = false
        case 0x2C:
            flags = .init(repeating: 0)
        case 0x30:
            if tracks[v].repeats == 0xFF {
                tracks[v].loopAt = tracks[v].at
                tracks[v].repeats = c - 0xD1
            }
        case 0x34:
            if tracks[v].repeats == 0 {
                tracks[v].repeats = 0xFF
            } else {
                tracks[v].repeats &-= 1
                tracks[v].at = tracks[v].loopAt
            }
        case 0x38:
            tracks[v].at &-= 12
        case 0x3C:
            // (`lbC064090`: the track begun again, and EaglePlayer told the song has ended: once for the tick.)
            tracks[v].at = -9
            if !endedInTick { endings += 1 }
            endedInTick = true
        case 0x58:
            flags[Int(c - 0xE5)] = 0
        default:
            // (Nothing, and Paula's modulation, `$DF` to `$E4` and `$F9` to `$FD`, which is not played.)
            break
        }
    }

    /// Paula's period for the voice as the player last told it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice as the player last told it.
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }
    /// The same, by the names the other players' tests use.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Scott Johnston's SoundPlayer, played on Paula by `PaulaTickRenderer`.
extension SJSPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "SoundPlayer")
        info.detail = "Scott Johnston's driver; \(sampleCount) sample\(sampleCount == 1 ? "" : "s"), \(voiceCount) voices"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -23.9 dB.)
    var gain: Float { 0.44 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { tickClocks }
}
