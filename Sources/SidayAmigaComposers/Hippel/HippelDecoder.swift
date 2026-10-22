// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's player of Jochen Hippel's TFMX and of Future Composer
// (src/Jochen/HippelDecoder.cpp and .h, and what it uses of src/Decoder.cpp and src/SmartPtr.h),
// Copyright (C) Michael Schwendt, used under the GPL-2.0-or-later, as it is at its commit dcec102 of
// 2026-09-26.

import SidayChips

/// libtfmxaudiodecoder's HippelDecoder, all of its state and the running of it, for `HippelPlayer`,
/// which owns the memory this plays from. Its parts are named as that library names them, and its
/// numbers are of the widths it gives them, wrapping and cutting as they do there, so that what is done
/// with any module, sensible or not, is what that library does; reading outside the module gives what
/// its guarded pointers give (`byte(_:)`, `signedByte(_:)`).
///
/// Everything starts at nought, as in a decoder made in memory cleared to nought: the library leaves a
/// few of its numbers unset until a module sets them, and those are nought here.
struct HippelDecoder {
    // MARK: The memory

    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of the memory are the module's: the library's `input.len`.
    var length = 0
    /// The module and the eight bytes of silence after it (`silenceData`): the library's `bufLen`, the
    /// stretch its guarded pointers read and write.
    var size = 0
    /// The one byte the library's guarded pointer for unsigned bytes gives for every place outside
    /// `size`, and takes what is written to any of them. (Its pointer for signed bytes has a byte of its
    /// own, never written, so reads outside as nought.)
    var outside: UInt8 = 0
    /// Where in the memory Future Composer 1.0 to 1.3's built-in waveforms are (the library keeps them
    /// in a table of its own, outside the module).
    let wavesAt: Int

    // MARK: What reading the module found

    var offsets = Offsets()
    var stats = Stats()
    var traits = Traits()
    var format = HippelFormat.tfmx
    var initKind = InitKind.tfmx
    var startSongKind = StartSongKind.tfmx
    var nextNoteKind = NextNoteKind.tfmx
    var vibratoKind = VibratoKind.tfmx
    var portamentoKind = PortamentoKind.tfmx
    /// What each of the sound sequences' commands $E0 to $EA does, for the player the module wants.
    var sndModFuncs = InlineArray<11, ModFunc>(repeating: .e1)
    /// The songs that can be played, by their places in the module's table of songs.
    var vSongs: [UInt8] = []
    var samples = [Sample](repeating: Sample(), count: 256)
    var silentSample = Sample()
    var trackStepLen: UInt8 = 0, trackColumnSize: UInt8 = 0
    var trackTabLen: Int32 = 0
    var firstStep = 0, lastStep = 0
    var blacklisted = false
    var analyze = Analyze()

    // MARK: The running of it

    /// Ticks a second, times 256; and a tick's length in milliseconds, times 256, and what is left of
    /// a millisecond so far.
    var rate: UInt32 = 50 << 8
    var tickFP: UInt32 = 0
    var tickFPAdd: UInt32 = 0
    var songEnd = true
    var loopMode = false
    var duration: UInt32 = 0
    var songPosCurrent: UInt32 = 0
    var admin = Admin()
    var randomWord: UInt16 = 0
    var voices = InlineArray<8, Voice>(repeating: Voice())
    var paula = InlineArray<8, PaulaRegisters>(repeating: PaulaRegisters())
    /// The sound sequence's work to do for a voice, last first (the library's `vModFunc`): never more
    /// than sixteen, as no more than fifteen are done in a tick and each adds two at most.
    var modFuncs = InlineArray<32, ModFunc>(repeating: .e1)
    var modFuncCount = 0
    /// How many times the song has come to its end since it was started, and of those, how many were
    /// a command to stop, not the track table running out (in loop mode the song plays on after
    /// either). For whoever plays it: the library itself does not say.
    var endings = 0, stops = 0
    /// The change to TFMX 7V's tempo that the song last asked for, in 256ths, which its player keeps in
    /// the length of the buffer it mixes the four voices of Paula's fourth into: see `TFMXTiming`.
    var sevenVoiceTempo = 0
    /// How long the song played for, through to its end, in the dry run that found its length: in
    /// Paula's clocks, by the timing of a player of four voices and of TFMX 7V's.
    var lengthClocks: (four: UInt64, seven: UInt64) = (0, 0)
    var stopCommanded = false

    init(memory: UnsafeMutablePointer<UInt8>, wavesAt: Int) {
        self.memory = memory
        self.wavesAt = wavesAt
    }

    // MARK: Parts of the state

    struct Offsets {
        var header: UInt32 = 0
        var trackTable: UInt32 = 0
        var patterns: UInt32 = 0
        var sndModSeqs: UInt32 = 0
        var volModSeqs: UInt32 = 0
        var subSongTab: UInt32 = 0
        var sampleHeaders: UInt32 = 0
        var sampleData: UInt32 = 0
        var silence: UInt32 = 0
    }

    struct Stats {
        var voices = 0
        var trackSteps = 0
        var patterns = 0
        var sndSeqs = 0
        var volSeqs = 0
        var samples = 0
        var songs = 0
    }

    struct Admin {
        var speed: Int16 = 0, count: Int16 = 0
        var startSpeed = 0
        var startSong = 0
        var initialized = false
        var readModRecurse = 0
    }

    /// How the players of different times and games differed, as the library tells them apart.
    struct Traits {
        var compressed = false
        /// Future Composer does it, but not every TFMX player.
        var vibScaling = false
        var vibSpeedFlag = false
        /// Whether the sound sequence's commands go on to its next byte.
        var sndSeqGoto = false
        /// Whether they go on to a transpose, from the sound sequence's next byte.
        var sndSeqToTrans = false
        /// Whether a sustained sound sequence goes on modulating its wave.
        var skipToWaveMod = false
        /// Some players want a sample pack to begin with "SSMP".
        var checkSSMPtag = false
        var foundSSMP = false
        /// Whether sound sequence $80 in an instrument keeps the one playing.
        var volSeqSnd80 = false
        /// Future Composer's volume slide, command $EA of the volume sequence.
        var volSeqEA = false
        var randomVolume = false
        /// A volume of each voice's own, 0 to 100.
        var voiceVolume = false
        var portaIsBit6 = false
        /// Whether bit 6 of a note's second byte, or bit 7, makes its portamento speed the sound
        /// sequence.
        var porta40SetSnd = false
        var porta80SetSnd = false
        /// Future Composer 1.0 to 1.3, not 1.4.
        var isSMOD = false
        /// Nought for a compressed module.
        var patternSize = 0
        var sampleStructSize = 0
        var periodMin: UInt16 = Self.fc14PeriodMin
        var periodMax: UInt16 = Self.fc14PeriodMax
        var lowerPeriods = false
        var portaWeaker = false
        var avoidTRglitch = false

        static let fc14PeriodMin: UInt16 = 0x0071
        /// (Future Composer 1.3's octave below the first would want $1AC0, but its range check, kept
        /// in 1.4, cuts it off.)
        static let fc14PeriodMax: UInt16 = 0x0D60
        static let smodPeriodMax: UInt16 = 0x06B0
    }

    /// A sample or waveform: where it starts, its repeat (from its start) and their lengths in words.
    struct Sample {
        var startOffs: UInt32 = 0, repOffs: UInt32 = 0
        var len: UInt16 = 0, repLen: UInt16 = 0
        /// Where in the memory Paula plays it from.
        var pStart = 0

        /// Keeps a sample's stretches inside the module (`length` long), as the library does for
        /// samples defined there.
        mutating func assertBoundaries(_ length: Int) {
            let bufLen = UInt32(truncatingIfNeeded: length)
            if startOffs > bufLen &- 2 { startOffs = bufLen &- 2 }
            if startOffs &+ UInt32(len) &+ UInt32(len) > bufLen {
                len = UInt16(truncatingIfNeeded: (bufLen &- startOffs) >> 1)
            }
            if repOffs &+ startOffs > bufLen &- 2 { repOffs = (bufLen &- 2) &- startOffs }
            if repOffs &+ startOffs &+ UInt32(repLen) &+ UInt32(repLen) > bufLen {
                repLen = UInt16(truncatingIfNeeded: (bufLen &- (repOffs &+ startOffs)) >> 1)
            }
            pStart = Int(startOffs)
        }
    }

    struct Voice {
        var voiceNum: UInt8 = 0
        var trigger = false
        var pattVal1: UInt8 = 0, pattVal2: UInt8 = 0

        var currentVolSeq: UInt8 = 0
        var volSeq: UInt32 = 0
        var volSeqPos: UInt16 = 0

        var volume: Int8 = 0
        var voiceVol: UInt8 = 0
        var volRandomThreshold: UInt8 = 0, volRandomCurrent: UInt8 = 0

        var envelopeSpeed: UInt8 = 0, envelopeCount: UInt8 = 0

        var volSlideSpeed: UInt8 = 0, volSlideTime: UInt8 = 0, volSustainTime: UInt8 = 0
        var volSlideDelayFlag: UInt8 = 0

        var pitchBendSpeed: Int8 = 0
        var pitchBendTime: UInt8 = 0, pitchBendDelayFlag: UInt8 = 0

        var portaSpeed: Int8 = 0, portaDelayFlag: Int8 = 0
        var portaOffs: Int32 = 0

        var vibFlag: UInt8 = 0, vibDelay: UInt8 = 0, vibSpeed: UInt8 = 0
        var vibAmpl: UInt8 = 0, vibCurOffs: UInt8 = 0

        /// The voice's column of the track table, from the song's first step to after its last.
        var trackStart: UInt32 = 0, trackEnd: UInt32 = 0
        var trackPos: UInt16 = 0

        var pattStart: UInt32 = 0
        var pattPos: UInt16 = 0

        var transpose: Int8 = 0, transposeNew: Int8 = 0
        var soundTranspose: Int8 = 0
        /// From the sound sequence.
        var seqTranspose: Int8 = 0

        var currentSndSeq: UInt8 = 0
        var sndSeq: UInt32 = 0
        var sndSeqPos: UInt16 = 0
        var sndModSustainTime: UInt8 = 0

        var outputPeriod: UInt16 = 0, outputVolume: UInt16 = 0

        var pSampleStart = 0
        var repeatOffset: UInt16 = 0, repeatLength: UInt16 = 0
        var repeatDelay: UInt16 = 0

        var currentWave: UInt8 = 0
        /// Wave modulation's switches: on unless the first is nought, and stopped by the second.
        var waveModSwitch1: UInt8 = 0, waveModSwitch2: UInt8 = 0
        var waveModSpeed: Int8 = 0, waveModSpeedCount: Int8 = 0
        var waveModInit = false
        var waveModStartOffs: UInt32 = 0, waveModEndOffs: UInt32 = 0
        var waveModLen: UInt16 = 0
        var waveModOffs: Int16 = 0
        /// In words.
        var waveModCurrentOffs: UInt16 = 0

        var pattCompress: Int8 = 0, pattCompressCount: Int8 = 0
    }

    /// What Paula was last told for a voice. A voice starts as libtfmxaudiodecoder's mixer starts one,
    /// at silence (here the zeros after the module's first byte of `silenceData`), one word long.
    struct PaulaRegisters {
        var start = 0
        var length: UInt16 = 1
        var period: UInt16 = 0
        var volume: UInt16 = 0
    }

    /// What the library gathers while it plays the song through once, to tell from it a little more of
    /// what the player is (`Analyze`): only what it decides anything with is kept.
    struct Analyze {
        /// The sound sequences instruments have asked for (before a note's bits change them).
        var sndSeqs = InlineArray<4, UInt64>(repeating: 0)
        /// The sound sequences that have run command $E7.
        var e7Seqs = InlineArray<4, UInt64>(repeating: 0)
        /// Whether a vibrato speed above $80 has been set.
        var negVibSpeed = false

        static func has(_ set: InlineArray<4, UInt64>, _ n: UInt8) -> Bool {
            set[Int(n >> 6)] & (1 << UInt64(n & 63)) != 0
        }

        static func insert(_ set: inout InlineArray<4, UInt64>, _ n: UInt8) {
            set[Int(n >> 6)] |= 1 << UInt64(n & 63)
        }
    }

    enum InitKind { case smod, fc14, tfmx, coso, mcmd }
    enum StartSongKind { case tfmx, sevenVoices, mcmd, fc }
    enum NextNoteKind { case tfmx, coso, fc }
    enum VibratoKind { case tfmx, coso }
    enum PortamentoKind { case tfmx, coso, fc }

    /// The library's functions of the sound sequence, which it keeps by pointer.
    enum ModFunc {
        case processSndModSustain, processSndModSeq, waveModulation, sndSeqTrans
        case undef, e0, e1, e1WaveMod, e2, e3, e4, e5, e5RepOffs, e6, e7, e7SetDiffWave, e8, e9
        case eaSkip, ea, fcE9, fcEAPitchbend
    }

    static let recurseLimit = 16
    static let patternLength = 0x40
    static let silenceData: [UInt8] = [
        // Used as the silent instrument (its speed, sound sequence, vibrato speed, amplitude, delay, and
        // its volume sequence from here), and its volume sequence starts here.
        0x01,
        // The silent sound sequence starts here.
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE1,
    ]
    static let ssmp: UInt32 = 0x5353_4D50 // "SSMP"

    // MARK: Reading the memory, as the library's guarded pointers do

    @inline(__always) func byte(_ at: UInt32) -> UInt8 {
        Int(at) < size ? memory[Int(at)] : outside
    }

    @inline(__always) func signedByte(_ at: UInt32) -> Int8 {
        Int(at) < size ? Int8(bitPattern: memory[Int(at)]) : 0
    }

    @inline(__always) mutating func setByte(_ at: UInt32, _ value: UInt8) {
        if Int(at) < size { memory[Int(at)] = value } else { outside = value }
    }

    /// A big-endian word or long. (The library reads them through a copy of its pointer, which reads
    /// outside the memory as the pointer itself would.)
    @inline(__always) func word(_ at: UInt32) -> UInt16 {
        UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1))
    }

    @inline(__always) func long(_ at: UInt32) -> UInt32 {
        UInt32(byte(at)) << 24 | UInt32(byte(at &+ 1)) << 16 | UInt32(byte(at &+ 2)) << 8 | UInt32(byte(at &+ 3))
    }

    /// Writes a big-endian word through a copy of the pointer, as the library's `writeBEword` does: a
    /// byte outside the memory is written to the copy's own, and lost.
    mutating func setWord(_ at: UInt32, _ value: UInt16) {
        if Int(at &+ 1) < size { memory[Int(at &+ 1)] = UInt8(value & 0xFF) }
        if Int(at) < size { memory[Int(at)] = UInt8(value >> 8) }
    }

    // MARK: Telling Paula

    @inline(__always) func off<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if v < stats.voices { out.off(v) }
    }

    @inline(__always) func on<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if v < stats.voices { out.on(v) }
    }

    @inline(__always) func takeNextBuf<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if v < stats.voices { out.takeNextBuffer(v, start: paula[v].start, length: paula[v].length) }
    }

    /// Stops the voice and sets it to play silence.
    mutating func killChannel<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        off(v, &out)
        paula[v].start = Int(offsets.silence) + 1
        // (Some players set the length to $100 here.)
        paula[v].length = 1
        takeNextBuf(v, &out)
    }

    /// Stops the voice now, and has it started again at the end of the tick.
    mutating func prepareChannelUpdate<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        off(v, &out)
        voices[v].trigger = true
    }

    // MARK: Starting

    /// Assigns default values to the essential parts of the running.
    mutating func reset<Output: TFMXOutput>(_ out: inout Output) {
        songEnd = false
        songPosCurrent = 0
        tickFPAdd = 0
        for v in 0 ..< stats.voices {
            voices[v].voiceNum = UInt8(v)
            voices[v].trackPos = 0
            voices[v].pattPos = 0
            voices[v].volSlideSpeed = 0
            voices[v].volSlideTime = 0
            voices[v].volSlideDelayFlag = 0
            voices[v].volSustainTime = 0
            voices[v].vibSpeed = 0
            voices[v].vibDelay = 0
            voices[v].vibAmpl = 0
            voices[v].vibCurOffs = 0
            voices[v].vibFlag = 0
            voices[v].pitchBendSpeed = 0
            voices[v].pitchBendTime = 0
            voices[v].pitchBendDelayFlag = 0
            voices[v].transpose = 0
            voices[v].transposeNew = 0
            voices[v].soundTranspose = 0
            voices[v].seqTranspose = 0
            voices[v].portaSpeed = 0
            voices[v].portaOffs = 0
            voices[v].portaDelayFlag = 0
            voices[v].volSeq = offsets.silence
            voices[v].sndSeq = offsets.silence &+ 1
            voices[v].volSeqPos = 0
            voices[v].currentVolSeq = 0
            voices[v].currentSndSeq = 0
            voices[v].sndSeqPos = 0
            voices[v].sndModSustainTime = 0
            voices[v].pattVal1 = 0
            voices[v].pattVal2 = 0
            voices[v].outputPeriod = 0
            voices[v].outputVolume = 0
            voices[v].volume = 0
            voices[v].voiceVol = 100
            voices[v].volRandomThreshold = 0
            voices[v].volRandomCurrent = 0
            voices[v].repeatDelay = 0
            voices[v].waveModSwitch1 = 0
            voices[v].currentWave = 0xFF
            voices[v].pattCompress = 0
            voices[v].pattCompressCount = 0

            killChannel(v, &out)

            // The track table's step is read to start with.
            if traits.compressed {
                voices[v].pattStart = 0xFFFF_FFFF
            } else {
                voices[v].pattPos = UInt16(truncatingIfNeeded: traits.patternSize)
            }
        }
        admin.speed = Int16(truncatingIfNeeded: admin.startSpeed)
        if admin.speed == 0 {
            admin.speed = 3 // the documented default
        }
        admin.count = 1 // a quick start
        randomWord = 0
    }

    /// Starts the chosen song from its beginning.
    mutating func restart<Output: TFMXOutput>(_ out: inout Output) {
        switch startSongKind {
        case .tfmx: tfmxStartSong(&out)
        case .sevenVoices: sevenVoicesStartSong(&out)
        case .mcmd: mcmdStartSong(&out)
        case .fc: fcStartSong(&out)
        }
    }

    /// Sets each voice's column of the track table, from the song's first step to after its last (or
    /// the whole table, for steps outside it).
    mutating func setTrackRange() {
        for v in 0 ..< stats.voices {
            let column = UInt32(v) * UInt32(trackColumnSize)
            if firstStep >= 0, firstStep * Int(trackStepLen) < Int(trackTabLen) {
                voices[v].trackStart = offsets.trackTable &+ UInt32(truncatingIfNeeded: firstStep * Int(trackStepLen)) &+ column
            } else {
                voices[v].trackStart = offsets.trackTable &+ column
            }
            voices[v].trackPos = 0
            if lastStep >= 0, (lastStep + 1) * Int(trackStepLen) <= Int(trackTabLen) {
                voices[v].trackEnd = offsets.trackTable &+ UInt32(truncatingIfNeeded: (lastStep + 1) * Int(trackStepLen))
            } else {
                voices[v].trackEnd = offsets.trackTable &+ UInt32(bitPattern: trackTabLen)
            }
        }
    }

    /// The rate in ticks a second, times 256 (never nought: 50, or from 8,556 to 25,600 for TFMX 7V).
    mutating func setRate(_ r: UInt32) {
        rate = r
        tickFP = (1000 << 16) / rate
    }

    // MARK: Each tick

    /// Runs the player for one tick. Returns its length in whole milliseconds.
    mutating func run<Output: TFMXOutput>(_ out: inout Output) -> Int {
        guard admin.initialized else { return 0 }
        let endedBefore = songEnd
        stopCommanded = false
        if !songEnd || loopMode {
            admin.count &-= 1
            if admin.count == 0 {
                admin.count = admin.speed
                // Each voice's next note.
                for v in 0 ..< stats.voices {
                    switch nextNoteKind {
                    case .tfmx: tfmxNextNote(v, &out)
                    case .coso: cosoNextNote(v, &out)
                    case .fc: fcNextNote(v, &out)
                    }
                }
            }
        }
        if songEnd, !endedBefore {
            endings += 1
            if stopCommanded { stops += 1 }
        }
        for v in 0 ..< stats.voices {
            if !songEnd || loopMode {
                // What follows decides whether the voice is started.
                voices[v].trigger = false
                soundModulation(v, &out)
                paula[v].period = voices[v].outputPeriod
                paula[v].volume = voices[v].outputVolume
                if voices[v].repeatDelay != 0 {
                    voices[v].repeatDelay &-= 1
                    if voices[v].repeatDelay == 1 {
                        voices[v].repeatDelay = 0
                        paula[v].start = voices[v].pSampleStart + Int(voices[v].repeatOffset)
                        paula[v].length = voices[v].repeatLength
                        takeNextBuf(v, &out)
                    }
                }
                if voices[v].trigger { on(v, &out) }
            } else {
                // The volume is cut at the song's end.
                paula[v].volume = 0
            }
        }
        if songEnd, loopMode { songEnd = false }

        // Not every module runs at fifty ticks a second.
        tickFPAdd &+= tickFP
        let tick = Int(tickFPAdd >> 8)
        tickFPAdd &= 0xFF
        songPosCurrent &+= UInt32(tick)
        return tick
    }

    // MARK: The module's sequences

    func getPattOffs(_ v: Int) -> UInt32 { voices[v].pattStart &+ UInt32(voices[v].pattPos) }

    /// Where an instrument (a volume modulation sequence) is, or the silent one for one beyond the last.
    func getVolSeq(_ seq: UInt8) -> UInt32 {
        if Int(seq) > stats.volSeqs - 1 { return offsets.silence }
        if traits.compressed { return offsets.header &+ UInt32(word(offsets.volModSeqs &+ (UInt32(seq) << 1))) }
        return offsets.volModSeqs &+ (UInt32(seq) << 6)
    }

    /// Where a sound modulation sequence is, or the silent one for one beyond the last.
    func getSndSeq(_ seq: UInt8) -> UInt32 {
        if Int(seq) > stats.sndSeqs - 1 { return offsets.silence &+ 1 }
        if traits.compressed { return offsets.header &+ UInt32(word(offsets.sndModSeqs &+ (UInt32(seq) << 1))) }
        return offsets.sndModSeqs &+ (UInt32(seq) << 6)
    }

    /// Where the sound sequence after `seq` is (or the volume sequences, after the last).
    func getSndSeqEnd(_ seq: UInt8) -> UInt32 {
        let begin = getSndSeq(seq)
        var end = getSndSeq(seq &+ 1)
        if begin == offsets.silence &+ 1 {
            end = begin &+ 7
        } else if end == offsets.silence &+ 1 {
            end = offsets.volModSeqs
        }
        return end
    }

    /// True if a sound sequence that ran command $E7 also has an $E0 or $E1 in it, in which case $E7 is
    /// unlikely to be the old "set sequence", and is taken to be "set a different wave".
    func usesE7SetDiffWave() -> Bool {
        for seq in 0 ..< 256 where Analyze.has(analyze.e7Seqs, UInt8(seq)) {
            let start = getSndSeq(UInt8(seq))
            let count = getSndSeqEnd(UInt8(seq)) &- start
            if hasE0OrE1(from: start, count: count) { return true }
        }
        return false
    }

    /// Whether any of the `count` bytes from `start` (wrapping round at 2³², as the library's
    /// numbers do) is $E0 or $E1, reading outside the memory as the guarded pointer does; without
    /// reading the same byte outside four thousand million times over.
    func hasE0OrE1(from start: UInt32, count: UInt32) -> Bool {
        let first = UInt64(start), end = UInt64(start) + UInt64(count)
        var inside: UInt64 = 0
        for (lo, hi) in [(first, min(end, 1 << 32)), (0, end > 1 << 32 ? end - (1 << 32) : 0)] {
            let a = min(lo, UInt64(size)), b = min(hi, UInt64(size))
            if b > a {
                inside += b - a
                for i in Int(a) ..< Int(b) where memory[i] == 0xE0 || memory[i] == 0xE1 { return true }
            }
        }
        return UInt64(count) > inside && (outside == 0xE0 || outside == 0xE1)
    }
}
