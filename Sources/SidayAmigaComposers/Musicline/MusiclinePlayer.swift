// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the Musicline Editor's own replay routine, as its authors made it a player for DeliTracker
// ("Musicline Editor DeliPlayer 1.02", by John Carehag, of the work of Conny Cyréus, Christian Cyréus,
// John Carehag and Jimmy Fredriksson; carried by UADE as players/MusiclineEditor, whose source UADE also
// carries as amigasrc/players/other/musicline_editor/mlineplayer102.asm, under the GNU LGPL). The names
// given are that source's labels.

import SidayChips
import SidayFoundation

/// The Musicline Editor's modules, made by Conny and Christian Cyréus's tracker for the Amiga of 1995, of
/// which UnExoticA's collection has Mark Sheeky's remix of his Xenex.
///
/// A module is chunks, each four letters and a length: after "MLED", "MODL" and "VERS", its tunes (TUNE,
/// each a song of the file: its title, tempo, speed, groove, and for each of its voices a list of parts
/// to play, each with a transposition, and commands to end, jump back and wait), its parts (PART, rows of
/// a note, an instrument and five effects, packed), its arpeggios (ARPG), its instruments (INST: a sample
/// or a waveform with its envelope, vibrato, tremolo, arpeggio, and five ways of making its waveform anew
/// at every tick: transform, phase, mix, resonance and filter, and a loop that moves through its sample),
/// its samples (SMPL, packed by deltas) and what the file says of itself (INFO). The player reads the
/// chunks in turn, and stops at the first it does not know.
///
/// This plays each tune as that player does on a PAL Amiga, tick by tick, as it tells Paula what to do:
/// its CIA's timer ticks at the tune's tempo (fifty times a second at 125); at each tick each voice's
/// rows are read at its speed, its effects played, its period and volume told Paula, and a voice that
/// starts a note is turned off, and turned on again with its sample after a wait the player times with
/// the CIA's other timer, and after another its loop told. A tune of eight voices (the player mixes two
/// to each of Paula's voices itself) is not played.
///
/// It owns the memory Paula plays from: nought at its start (a place a voice with nothing is pointed at,
/// and what is read where the player would read the Amiga's own first bytes), each voice's buffers for
/// the waveforms it makes, and the samples.
///
/// A tune ends when each of its voices has come to its end, to a jump back for ever, or past the end of
/// its list: the player plays on, but a voice past its list plays the module's part 0 for ever, which is
/// silence. One whose voices all came to their ends or past their lists stops; one that a voice goes
/// round in goes round.
struct MusiclinePlayer: ~Copyable {
    /// The memory Paula plays from.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int

    /// Where things are in it: the first bytes, nought (the player's `ZeroSample` among them); the
    /// buffers of chip memory each of the first four voices' waveforms is copied to (`WaveBuffer1` to 4,
    /// 256 bytes each), from `waveBuffersAt`; each voice's five buffers of 256 bytes for the waveforms it
    /// makes (`ch_TraWaveBuffer` and the four after it), from `buffersAt`; and the samples, from
    /// `samplesAt`.
    static let zeroSample = 0x100
    static let lowMemory = 0x1000
    static let waveBuffersAt = 0x1000
    static let buffersAt = 0x1400
    static let samplesAt = 0x4000
    var silenceAt: Int { Self.zeroSample }
    var mixingAt: Int { Self.zeroSample }

    /// The file's tunes, parts, arpeggios, instruments and samples, as the player loads them.
    let tunes: [Tune]
    let parts: [[UInt8]?]
    let arpeggios: [[UInt8]?]
    var instruments: [Instrument?]
    var samples: [Sample?]
    /// What the file says of itself, and its version.
    let info: [String]
    let version: String
    /// What could not be played as the file asks, and how a damaged file was mended.
    var shortfalls: [String] = []

    var songCount: Int { tunes.count }
    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// For checks: each write the player made to Paula's registers in the tick just run (the register's
    /// offset, $A0 to $D8 or DMACON's $96, and the word written), when this is not nil.
    var writes: [(register: UInt16, value: UInt16)]?

    // MARK: The player's own variables

    var voices: [Voice] = Array(repeating: Voice(), count: 8)
    /// `_TuneSpd`, `_TuneGrv`, `_TuneTmp`: the tune's speed and groove, which a voice takes up at each
    /// part, and its tempo; `_MasterVol`.
    var tuneSpeed: UInt8 = 0
    var tuneGroove: UInt8 = 0
    var tuneTempo: UInt16 = 0
    var masterVolume: UInt16 = 0
    /// `_PlayMode` (nought for four voices), `_PlayTune` (2 for the first tick after the start), `_IntMode`
    /// (nought once the player has stopped), `_DmaSave` (the voices turned off for their notes) and
    /// `_DmaWait1` to 4 (each voice's period at the tick before).
    var playMode: UInt8 = 0
    var playTune: UInt8 = 0
    var intMode: UInt16 = 0
    var dmaSave: UInt16 = 0
    var dmaWaits = InlineArray<4, UInt16>(repeating: 0)
    /// `_LoopError`: how many more times a voice may go round its list in a tick.
    var loopError: UInt16 = 0
    /// The CIA's timer A as the player set it: its latch, and its value as this tick began.
    var timerA: UInt16 = 0
    private var tickTimer: UInt16 = 0
    /// The Amiga's filter, as the player's effect $47 sets it by the power light (off as the tune starts).
    var lightFilter = false

    /// How each voice has come to its end: nought not yet, 1 at an end or past its list, 2 at a jump back
    /// for ever (siday's: the player does not say).
    var finished = InlineArray<8, UInt8>(repeating: 0)

    // MARK: Paula, as the player has written her registers

    private var locations = InlineArray<4, UInt32>(repeating: 0)
    private var lengths = InlineArray<4, UInt16>(repeating: 0)
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)
    private var dmacon: UInt16 = 0
    /// True until the first tick, which only starts the timer.
    private var starting = false
    /// Where in the tick the writes being made fall, in Paula's clocks (see `TFMXOutput.timed(at:)`).
    private var moment = 0

    /// A song that has not come to its end in ten minutes is taken never to.
    private static let mostClocks: UInt64 = 600 * 3_546_895

    /// The PAL Amiga's numbers the player takes from the system (`InitPlayer`): its timer's value for a
    /// tempo of one (`_TimerValue1`, 1,773,448: the CIA's 709,379 counts a second, times 125 / 50), from
    /// which a tempo's is had by dividing by it.
    static let timerValue = 1_773_448

    // MARK: The check

    /// True for a file the player's check takes (`CheckModule`): "MLED" and then "MODL".
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 8 && Array(data[0 ..< 8]) == Array("MLEDMODL".utf8)
    }

    // MARK: Making

    /// Reads the module and starts tune `song` (counting from nought).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        guard Self.isOne(data) else { throw TuneError.malformed("not a Musicline Editor module") }
        var file = data
        var mended: [String] = []
        if let repair = MusiclineRepair.repaired(data) {
            file = repair.bytes
            mended = repair.notes
        }
        let loaded = try Loaded(file)
        tunes = loaded.tunes
        parts = loaded.parts
        arpeggios = loaded.arpeggios
        info = loaded.info
        version = loaded.version
        memoryCapacity = Self.samplesAt + loaded.sampleBytes + 0x2_0000
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        instruments = loaded.instruments
        samples = loaded.samples
        // The samples' sounds, where they are; and each instrument's places in its sample (`LoadSmpl`).
        var at = Self.samplesAt
        for i in samples.indices {
            guard var sample = samples[i] else { continue }
            let sound = loaded.sounds[i]
            for (k, byte) in sound.enumerated() { memory[at + k] = byte }
            sample.place(at: at)
            samples[i] = sample
            at += (sound.count + 7) & ~7
        }
        for i in instruments.indices {
            guard var instrument = instruments[i] else { continue }
            let number = Int(instrument.byte(Instrument.smplNumber))
            // (An instrument whose sample is not in the file keeps the place the editor saved, which the
            // player would play whatever is at: here, nought.)
            instrument.pointer = 0
            instrument.repPointer = 0
            if number < samples.count, let sample = samples[number] {
                instrument.pointer = sample.data + 2 * Int(instrument.word(Instrument.smplStart))
                instrument.repPointer = sample.data + 2 * Int(instrument.word(Instrument.smplRepStart))
            }
            instruments[i] = instrument
        }
        shortfalls = mended + loaded.shortfalls
        if tunes.contains(where: { $0.playMode != 0 }) {
            let eight = tunes.indices.filter { tunes[$0].playMode != 0 }.map { "\($0 + 1)" }.joined(separator: ", ")
            shortfalls.append("The player's tunes of eight voices, which it mixes two to each of Paula's itself, are not played (tune \(eight)).")
        }
        begin(song)
    }

    deinit { memory.deallocate() }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        begin(song)
    }

    /// Starts tune `song`, as a player newly loaded would; and finds how long it is.
    private mutating func begin(_ song: Int) {
        self.song = song >= 0 && song < songCount ? song : 0
        initialise()
        var none = TFMXSilentOutput()
        let logging = writes
        writes = nil
        var clocks: UInt64 = 0
        while endings == 0, stops == 0, clocks < Self.mostClocks {
            _ = run(&none)
            clocks += UInt64(tickClocks)
        }
        // (The tick it came to its end in is the first of it again, or its stop.)
        lengthClocks = endings > 0 || stops > 0 ? clocks - min(clocks, UInt64(tickClocks)) : nil
        writes = logging
        initialise()
    }

    /// The tick's length, in Paula's clocks: five to a count of the CIA's timer, which counts the value
    /// it is set to and one more.
    var tickClocks: Int { (Int(tickTimer) + 1) * 5 }

    /// `InitSound` for the tune: the voices cleared (`ClearChannels`) and set up (`UpdateChStruct`), the
    /// waveforms' buffers cleared, and `InitPlay`: each voice given the tune's speed and groove, and the
    /// tune's first row read (the player's look for a place to start from, which is its start); then
    /// `StartPlay`: the timer set going at the tune's tempo.
    private mutating func initialise() {
        (memory + Self.waveBuffersAt).update(repeating: 0, count: Self.samplesAt - Self.waveBuffersAt)
        let tune = tunes[song]
        voices = Array(repeating: Voice(), count: 8)
        for c in 0 ..< 8 {
            voices[c].cVolume = 64 * 16
            voices[c].paulaVoice = c & 3
            voices[c].dmaChannel = 1 << UInt16(c & 3)
        }
        playMode = tune.playMode
        tuneTempo = tune.tempo
        tuneSpeed = tune.speed
        tuneGroove = tune.groove
        for c in 0 ..< 8 {
            voices[c].spd = tuneSpeed
            voices[c].grv = tuneGroove
            if tuneGroove != 0 { voices[c].partGrv = ~voices[c].partGrv }
            voices[c].spdCnt = 1
            voices[c].pchSldToNote = 0xFFFF
            // (A voice with no list the player points at the Amiga's first bytes, and plays what it finds
            // there: here it is silent from the start, siday's choice.)
            if tune.lists[c] == nil { voices[c].voiceOff = 1 }
        }
        masterVolume = 64 * 16
        dmaSave = 0
        dmaWaits = .init(repeating: 0)
        finished = .init(repeating: 0)
        for c in 0 ..< 4 where tune.lists[c] == nil { finished[c] = 1 }
        locations = .init(repeating: UInt32(Self.zeroSample))
        lengths = .init(repeating: 1)
        paulaPeriods = .init(repeating: 0)
        paulaVolumes = .init(repeating: 0)
        dmacon = 0
        endings = 0
        stops = 0
        moment = 0
        lightFilter = false
        intMode = 1
        var none = TFMXSilentOutput()
        if playMode == 0 {
            playTune(&none)
        } else {
            // (Eight voices are not played: the tune is stopped as it starts.)
            intMode = 0
            stops = 1
        }
        playTune = 2
        // (`StartPlay`) The timer: the PAL machine's value for a tempo of one, divided by the tempo.
        timerA = Self.timerValue(tempo: tuneTempo)
        tickTimer = timerA
        starting = true
    }

    /// The timer's value for a tempo: `divu` of `_TimerValue1` by it, which leaves the long as it was if
    /// the quotient would not fit a word (a tempo below 28); and fifty ticks a second for a tempo of
    /// nought, at which the 68000 would take a division by zero (siday's choice).
    static func timerValue(tempo: UInt16) -> UInt16 {
        guard tempo != 0 else { return UInt16(timerValue / 125) }
        let quotient = timerValue / Int(tempo)
        return quotient > 0xFFFF ? UInt16(truncatingIfNeeded: timerValue) : UInt16(quotient)
    }

    // MARK: Playing

    /// The CIA's interrupt (`PlayMusic`): on the first tick after the start the voices' volumes and the
    /// effects of the first row, and from then on each tick's rows (`PlayTune`); then the effects
    /// (`PlayEffects`), the periods (`PerCalc`), the periods and volumes of the voices that start no note
    /// (`PerVolPlay`) and the notes (`DmaPlay`). Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if writes != nil { writes = [] }
        tickTimer = timerA
        moment = 0
        if starting {
            // The first count of the timer, from when `StartPlay` set it going.
            starting = false
            return tickClocks * 1000 / 3_546_895
        }
        guard intMode != 0 else { return tickClocks * 1000 / 3_546_895 }
        if playTune == 2 {
            playTune = 1
            for v in 0 ..< 4 { paula(UInt16(0xA8 + 16 * v), 0, &output) }
        } else {
            playTune(&output)
        }
        playEffects(&output)
        for c in 0 ..< 4 { periodOf(c) }
        perVolPlay(&output)
        dmaPlay(&output)
        noteEnd()
        return tickClocks * 1000 / 3_546_895
    }

    /// `PerVolPlay` for four voices: each voice that starts no note told its period and its volume.
    private mutating func perVolPlay<Output: TFMXOutput>(_ output: inout Output) {
        for c in 0 ..< 4 where voices[c].play & 1 == 0 {
            let base = UInt16(0xA0 + 16 * c)
            paula(base + 6, voices[c].period2, &output)
            if voices[c].channelOff == 0 { paula(base + 8, outputVolume(c), &output) }
        }
    }

    /// A voice's volume as Paula is told it: its volume (`ch_Volume3`, 0 to 1,024) times its channel's
    /// (`ch_CVolume`) and the player's own (`_MasterVol`), each as the 68000 works them out: the products
    /// shifted and their upper words taken.
    func outputVolume(_ c: Int) -> UInt16 {
        var d1 = UInt32(voices[c].volume3) &* UInt32(voices[c].cVolume)
        d1 = (d1 << 6) >> 16
        d1 = (d1 & 0xFFFF) &* UInt32(masterVolume)
        return UInt16(truncatingIfNeeded: (d1 << 2) >> 16)
    }

    /// `DmaPlay` for four voices: the voices that start a note (`ch_Play` bit 0), but for a waveform of
    /// the same number as the voice's last, turned off, the waits' longest period kept, and the CIA's
    /// timer B set to wait that many of its counts, or 100 if that is longer; then, as the timer comes to
    /// its end, `Dma1`: each starting voice told its volume, sample, length and period and turned on; and
    /// after 150 counts more, `Dma2`: each turned-on voice told its loop.
    private mutating func dmaPlay<Output: TFMXOutput>(_ output: inout Output) {
        var d0 = dmaSave
        var d7: UInt16 = 100
        for c in 0 ..< 4 where voices[c].play & 1 != 0 {
            let number = voices[c].wsNumber
            let old = voices[c].wsNumberOld
            voices[c].wsNumberOld = number
            if voices[c].waveOrSample == 0 || number != old {
                d0 |= 1 << UInt16(c)
                if Int16(bitPattern: d7) < Int16(bitPattern: dmaWaits[c]) { d7 = dmaWaits[c] }
            }
        }
        paula(0x96, d0, &output)
        dmaSave = d0
        for c in 0 ..< 4 { dmaWaits[c] = voices[c].period2 }
        // (`Dma1`, when timer B, one-shot, has counted down.)
        moment += (Int(d7) + 1) * 5
        output.timed(at: moment)
        for c in 0 ..< 4 where voices[c].play & 1 != 0 {
            voices[c].play &= ~1
            let base = UInt16(0xA0 + 16 * c)
            if voices[c].channelOff == 0 { paula(base + 8, outputVolume(c), &output) }
            paula32(base, UInt32(voices[c].wsPointer), &output)
            paula(base + 4, voices[c].wsLength, &output)
            paula(base + 6, voices[c].period2, &output)
        }
        paula(0x96, 0x8000 | dmaSave, &output)
        // (`Dma2`, 150 counts on.)
        moment += 151 * 5
        output.timed(at: moment)
        for c in 0 ..< 4 where dmaSave & 1 << UInt16(c) != 0 {
            let base = UInt16(0xA0 + 16 * c)
            paula32(base, UInt32(voices[c].wsRepPointer), &output)
            paula(base + 4, voices[c].wsRepLength, &output)
        }
        dmaSave = 0
    }

    /// siday's test of the tune's end: each voice that has come to its end, to a jump back for ever or
    /// past its list counted; once all four have, the tune has ended, and goes round if any of them goes
    /// round, and has stopped if none does.
    private mutating func noteEnd() {
        guard (0 ..< 4).allSatisfy({ finished[$0] != 0 }) else { return }
        if (0 ..< 4).contains(where: { finished[$0] == 2 }) {
            endings += 1
            for c in 0 ..< 4 where finished[c] == 2 { finished[c] = 0 }
        } else if stops == 0 {
            stops += 1
        }
    }

    /// `StopPlay`, at a part whose first row is its end: the voices turned off and the timer stopped.
    mutating func stopPlay<Output: TFMXOutput>(_ output: inout Output) {
        paula(0x96, 0x000F, &output)
        playTune = 0
        intMode = 0
        for c in 0 ..< 8 { voices[c].wsNumberOld = 0 }
        if stops == 0 { stops += 1 }
    }

    // MARK: Paula's registers

    /// A word written to Paula (DMACON at $96, a voice's registers from $A0), as the hardware takes it,
    /// told to `output` at its moment in the tick.
    mutating func paula<Output: TFMXOutput>(_ register: UInt16, _ value: UInt16, _ output: inout Output) {
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
                output.writePeriod(v, value)
            case 0x8:
                paulaVolumes[v] = value
                output.writeVolume(v, value)
            default:
                break
            }
        default:
            break
        }
    }

    /// A long written to a voice's location register: its two words.
    mutating func paula32<Output: TFMXOutput>(_ register: UInt16, _ value: UInt32, _ output: inout Output) {
        paula(register, UInt16(value >> 16), &output)
        paula(register + 2, UInt16(truncatingIfNeeded: value), &output)
    }

    private func tellBuffer<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let at = Int(locations[v] & 0x1F_FFFE)
        output.takeNextBuffer(v, start: min(at, memoryCapacity), length: lengths[v])
    }

    /// Paula's period for the voice, and her volume, as the player last wrote them.
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] }

    // MARK: Memory

    /// A byte of the memory Paula plays from; nought past it.
    func byte(_ address: Int) -> UInt8 {
        let at = address & 0xFF_FFFF
        return at < memoryCapacity ? memory[at] : 0
    }

    /// A byte written: not to the first bytes, which stay nought, nor past the memory.
    func setByte(_ address: Int, _ value: UInt8) {
        let at = address & 0xFF_FFFF
        if at >= Self.lowMemory, at < memoryCapacity { memory[at] = value }
    }

    /// The place of one of a voice's buffers for the waveforms it makes: 0 transform's, 1 phase's, 2 mix's,
    /// 3 resonance's, 4 filter's.
    static func buffer(_ c: Int, _ which: Int) -> Int { buffersAt + (c * 5 + which) * 256 }
}

/// The Musicline Editor's music, played on Paula by `PaulaTickRenderer`.
extension MusiclinePlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var tuneInfo = TuneInfo(format: "Musicline Editor")
        let title = info.first ?? ""
        tuneInfo.title = title.isEmpty ? tunes.first?.title ?? "" : title
        if info.count > 1 { tuneInfo.author = info[1] }
        tuneInfo.comment = info.dropFirst(4).filter { !$0.isEmpty }.joined(separator: "\n")
        let sampleCount = samples.count(where: { $0 != nil })
        let instrumentCount = instruments.count(where: { $0 != nil })
        let tuneNames = tunes.map { $0.title }.filter { !$0.isEmpty }.joined(separator: ", ")
        tuneInfo.detail = "Musicline Editor \(version); \(instrumentCount) instrument\(instrumentCount == 1 ? "" : "s"), "
            + "\(sampleCount) sample\(sampleCount == 1 ? "" : "s")" + (tuneNames.isEmpty ? "" : "; tunes: \(tuneNames)")
        tuneInfo.shortfalls = shortfalls
        return tuneInfo
    }

    /// The Musicline Editor's music is a little louder on the Amiga's chip than ProTracker's is, by 0.4 dB
    /// in the one tune of UnExoticA's file that is music, Xenex-Remix (by BS.1770 loudness, over its first
    /// minute, against the middle of 30 ProTracker modules), and is turned down by that (2026-10-27).
    var gain: Float { 0.32 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { tickClocks }
}
