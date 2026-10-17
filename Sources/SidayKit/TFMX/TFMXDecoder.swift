// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's player of TFMX (src/Chris/TFMXDecoder.cpp and .h), Copyright (C)
// Michael Schwendt, used under the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

/// libtfmxaudiodecoder's TFMXDecoder, all of its state and the running of it, for `TFMXPlayer`, which
/// owns the memory this plays from. Its parts are named as that library names them, and its numbers
/// are of the widths it gives them, wrapping and cutting as they do there, so that what is done with
/// any module, sensible or not, is what that library does; reading outside the memory gives what its
/// guarded pointer gives (`byte(_:)`).
///
/// Everything starts at nought, as in a decoder made in memory cleared to nought: the library leaves a
/// few of its numbers unset until a module sets them, and those are nought here.
struct TFMXDecoder {
    // MARK: The memory

    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of the memory are the module's: the library's `input.len` (and `bufLen`).
    var size = 0
    /// The one byte the library's guarded pointer gives for every place outside the memory, and takes
    /// what is written to any of them: so a place outside, read after one was written, reads as that.
    var outside: UInt8 = 0

    // MARK: What reading the module found

    var offsets = Offsets()
    var variant = Variant()
    var format = TFMXFormat.pro
    /// The module's songs, by their places in its table of 32.
    var songs: [UInt8] = []
    var voiceCount = 0
    var macroTable = InlineArray<64, MacroCommand>(repeating: .nop)
    var input = Input()
    var blacklisted = false
    var title: [UInt8] = [], author: [UInt8] = [], game: [UInt8] = []

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
    var triggerRestart = false
    var admin = Admin()
    var sequencer = Sequencer()
    var tracks = InlineArray<8, Track>(repeating: Track())
    var cmd = Command()
    var fade = Fade()
    var channelToVoiceMap = InlineArray<8, UInt8>(repeating: 0)
    var voices = InlineArray<8, Voice>(repeating: Voice())
    var paula = InlineArray<8, PaulaRegisters>(repeating: PaulaRegisters())
    var macroEvalAgain = false
    var trackCmdUsed = InlineArray<5, Bool>(repeating: false)
    /// The library calls the C library's `rand()` for its random play, seeded from where in memory the
    /// decoder happens to be. In its place, the C standard's example generator, seeded with one, for
    /// sound that is the same every time.
    var randomState: UInt32 = 1

    init(memory: UnsafeMutablePointer<UInt8>) {
        self.memory = memory
    }

    // MARK: Parts of the state

    struct Offsets {
        var header: UInt32 = 0
        var trackTable: UInt32 = 0
        var patterns: UInt32 = 0
        var macros: UInt32 = 0
        var sampleData: UInt32 = 0
        var silence: UInt32 = 0
        var trackTableEnd: UInt32 = 0
    }

    /// The order in which the sequencer, the macros and the effects run each tick.
    enum ExecOrder {
        case seqModMac, modMacSeq, macModSeq
    }

    /// How players of different times and games differed, as the library tells them apart.
    struct Variant {
        var compressed = false
        var finetuneUnscaled = false
        var vibratoUnscaled = false
        var vibratoTimeMask = false
        var portaUnscaled = false
        var portaOverride = false
        var noNoteDetune = false
        var setNoteV1 = false
        var extraWaitV1 = false
        var macroLoopExtraWait = false
        var bpmSpeed5 = false
        var noAddBeginCount = false
        var noDelayedDMAon = false
        var noTrackMute = false
        var execOrder = ExecOrder.seqModMac
    }

    struct Input {
        var mdatSize: UInt32 = 0, smplSize: UInt32 = 0
        /// From a TFHD file's header: the version of the player it wants (0 when it does not say).
        var versionHint = 0
        /// From a TFMX-MOD file: the one song it is of, or -1.
        var startSongHint = 0
    }

    struct Admin {
        var speed: Int16 = 0, count: Int16 = 0
        var startSpeed = 0, startSong = 0
        var initialized = false
        var randomWord: UInt16 = 0
    }

    struct Sequencer {
        var evalNext = false
        var loops: Int16 = 0
        var first = 0, last = 0, current = 0
        var next = false
        var stepSeenBefore = InlineArray<512, Bool>(repeating: false)
    }

    struct Track {
        var PT: UInt8 = 0
        var TR: Int8 = 0
        var on = false
        var offset: UInt32 = 0, offsetSaved: UInt32 = 0
        var step: UInt16 = 0, stepSaved: UInt16 = 0
        var wait: UInt8 = 0
        var loops: Int8 = 0
        var evalNext = false
        var infiniteLoop = false
    }

    struct Command {
        var aa: UInt8 = 0, bb: UInt8 = 0, cd: UInt8 = 0, ee: UInt8 = 0
    }

    struct Fade {
        var volume: UInt8 = 0, target: UInt8 = 0
        var speed: UInt8 = 0, count: UInt8 = 0
        var delta: Int8 = 0
        var active = false
    }

    /// What Paula was last told for a voice. A voice starts where libtfmxaudiodecoder's mixer starts
    /// one: at four bytes of silence of its own (here, `size`), one word long.
    struct PaulaRegisters {
        var start = 0
        var length: UInt16 = 1
        var period: UInt16 = 0
        var volume: UInt16 = 0
    }

    struct Voice {
        var outputPeriod: UInt16 = 0, outputVolume: UInt16 = 0
        var voiceNum: UInt8 = 0
        var effectsMode: Int8 = 0
        var volume: Int8 = 0
        var note: UInt8 = 0, notePrevious: UInt8 = 0
        var noteVolume: UInt8 = 0
        var period: UInt16 = 0
        var detune: Int16 = 0
        var keyUp = false

        // The macro being run.
        var macroOffset: UInt32 = 0, macroOffsetSaved: UInt32 = 0
        var macroStep: UInt32 = 0, macroStepSaved: UInt32 = 0
        var macroWait: Int16 = 0
        var macroLoop: UInt8 = 0
        /// -1 running, 0 not, 1 to be started on the next tick.
        var macroState: Int8 = 0
        var extraWait = false
        var delayedOff = false, delayedOn = false
        var branchIfSame = false

        var waitOnDMACount: Int16 = 0
        var waitOnDMAPrevLoops: UInt16 = 0

        var addBeginCount: UInt8 = 0, addBeginArg: UInt8 = 0
        var addBeginOffset: Int32 = 0

        var vibratoTime: UInt8 = 0, vibratoCount: UInt8 = 0
        var vibratoIntensity: Int8 = 0
        var vibratoDelta: Int16 = 0

        var envelopeFlag: UInt8 = 0, envelopeCount: UInt8 = 0, envelopeSpeed: UInt8 = 0, envelopeTarget: UInt8 = 0

        var portamentoCount: UInt8 = 0, portamentoWait: UInt8 = 0
        var portamentoSpeed: UInt16 = 0, portamentoPeriod: UInt16 = 0

        var sampleStart: UInt32 = 0
        var sampleLength: UInt16 = 0

        /// Paula's start and length as the macro gave them, before they were kept inside the memory.
        var paulaOrigOffset: UInt32 = 0
        var paulaOrigLength: UInt16 = 0

        var sid = SID()

        var rndMacro: UInt8 = 0
        var rndCount: Int8 = 0, rndSpeed: Int8 = 0
        var rndFlag: Int8 = 0
        var rndMode: UInt8 = 0
        var rndBlockWait = false
        var rndMask: UInt8 = 0
        var arpOffset: UInt32 = 0
        var arpPos: UInt16 = 0
    }

    /// The synthesiser some later players have, which makes a voice's sample afresh each tick from
    /// another stretch of the samples (macros $22 to $29).
    struct SID {
        var sourceOffset: UInt32 = 0
        var sourceLength: UInt16 = 0
        var targetOffset: UInt32 = 0
        var targetLength: UInt16 = 0
        var lastSample: Int8 = 0
        var op1Speed: UInt16 = 0, op1Count: UInt16 = 0, op1InterDelta: UInt16 = 0
        var op1InterMod: Int16 = 0
        var op2Speed: UInt16 = 0, op2Count: UInt16 = 0
        var op2Offset: UInt32 = 0
        var op2Delta: Int16 = 0
        var op3Speed: UInt16 = 0, op3Count: UInt16 = 0
        var op3Offset: UInt32 = 0
        var op3Delta: Int16 = 0
    }

    // MARK: Reading the memory, as the library's guarded pointer does

    @inline(__always) func byte(_ at: UInt32) -> UInt8 {
        Int(at) < size ? memory[Int(at)] : outside
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

    @inline(__always) static func makeWord(_ hi: UInt8, _ lo: UInt8) -> UInt16 { UInt16(hi) << 8 | UInt16(lo) }

    @inline(__always) static func makeDword(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    // MARK: Starting

    /// Assigns default values to the essential parts of the running (the library's `reset`).
    mutating func reset<Output: TFMXOutput>(_ out: inout Output) {
        cmd = Command()
        for t in 0 ..< 8 {
            tracks[t].on = false
            tracks[t].PT = 0xFF
            tracks[t].TR = 0
            tracks[t].offset = 0
            tracks[t].step = 0
            tracks[t].wait = 0
            tracks[t].loops = -1
        }
        for v in 0 ..< 8 {
            voices[v].voiceNum = UInt8(v)
            voices[v].envelopeFlag = 0
            voices[v].portamentoSpeed = 0
            voices[v].keyUp = true
            voices[v].vibratoTime = 0
            voices[v].vibratoDelta = 0
            voices[v].waitOnDMACount = -1
            voices[v].waitOnDMAPrevLoops = 0
            voices[v].addBeginCount = 0
            voices[v].addBeginArg = 0
            voices[v].addBeginOffset = 0
            voices[v].period = 0
            voices[v].outputPeriod = 0
            voices[v].detune = 0
            voices[v].volume = 0
            voices[v].outputVolume = 0
            voices[v].note = 0
            voices[v].notePrevious = 0
            voices[v].noteVolume = 0
            voices[v].macroWait = 1
            voices[v].macroStep = 0
            voices[v].macroState = 0
            voices[v].macroLoop = 0xFF
            voices[v].extraWait = true
            voices[v].delayedOff = false
            voices[v].delayedOn = false
            voices[v].macroOffset = 0
            voices[v].branchIfSame = false
            voices[v].sid.targetOffset = 0x100 * UInt32(v) + 4
            voices[v].sid.targetLength = 0
            voices[v].sid.lastSample = 0
            voices[v].sid.op1InterDelta = 0
            voices[v].rndFlag = 0

            off(v, &out)
            toPaulaLength(v, 1, &out)
            toPaulaStart(v, offsets.silence, &out)
            paula[v].volume = 0
            paula[v].period = 0
        }
        for m in 0 ..< 5 { trackCmdUsed[m] = false }
    }

    /// Starts the chosen song from its beginning.
    mutating func restart<Output: TFMXOutput>(_ out: inout Output) {
        reset(&out)
        let so = UInt32(songs[admin.startSong]) << 1
        sequencer.first = Int(word(offsets.header &+ 0x100 &+ so))
        sequencer.current = sequencer.first
        sequencer.last = Int(word(offsets.header &+ 0x140 &+ so))
        admin.speed = Int16(bitPattern: word(offsets.header &+ 0x180 &+ so))
        if admin.speed >= 0x10 {
            setBPM(UInt16(admin.speed))
            admin.speed = 0
            if variant.bpmSpeed5 { admin.speed = 5 }
        }
        admin.startSpeed = Int(admin.speed)
        admin.count = 0 // a quick start
        softRestart()
    }

    /// What is also needed when a song that ends without looping is started again.
    mutating func softRestart() {
        songEnd = false
        songPosCurrent = 0
        tickFPAdd = 0
        triggerRestart = false
        // Not all songs are made to loop cleanly, so they are helped.
        for v in 0 ..< voiceCount {
            voices[v].keyUp = true
            voices[v].volume = 0
            voices[v].outputVolume = 0
        }
        fade.active = false
        fade.volume = 64
        fade.target = 64
        fade.delta = 0
        resetSequencer()
        processTrackStep()
    }

    /// The rate in ticks a second, times 256 (never nought: it is set to 50, to between 32 and 511
    /// sixty-fourths of a tick a second by the speed command, and by beats a minute of 16 or more).
    mutating func setRate(_ r: UInt32) {
        rate = r
        tickFP = (1000 << 16) / rate
    }

    mutating func setBPM(_ bpm: UInt16) {
        setRate(UInt32((Int(bpm) << 8) * 2 / 5))
    }

    // MARK: Telling Paula

    @inline(__always) func on<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if v < voiceCount { out.on(v) }
    }

    @inline(__always) func off<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if v < voiceCount { out.off(v) }
    }

    @inline(__always) func loopCount<Output: TFMXOutput>(_ v: Int, _ out: inout Output) -> UInt16 {
        v < voiceCount ? out.loopCount(v) : 0
    }

    /// Paula's start and length are kept as they were given, so that they can be brought back inside
    /// the memory if they go outside it.
    mutating func toPaulaStart<Output: TFMXOutput>(_ v: Int, _ offset: UInt32, _ out: inout Output) {
        voices[v].paulaOrigOffset = offset
        paula[v].start = Int(offset)
        takeNextBufChecked(v, &out)
    }

    mutating func toPaulaLength<Output: TFMXOutput>(_ v: Int, _ length: UInt16, _ out: inout Output) {
        voices[v].paulaOrigLength = length
        paula[v].length = length
        takeNextBufChecked(v, &out)
    }

    mutating func takeNextBufChecked<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        let offset = voices[v].paulaOrigOffset
        if Int(offset) >= size {
            // The start outside the memory.
            paula[v].start = Int(offsets.silence)
            paula[v].length = 1
        } else if Int(offset) + (Int(voices[v].paulaOrigLength) << 1) > size {
            // The end outside it.
            paula[v].length = UInt16(truncatingIfNeeded: (UInt32(size) &- offset) >> 1)
            paula[v].start = Int(offset)
        }
        if v < voiceCount { out.takeNextBuffer(v, start: paula[v].start, length: paula[v].length) }
    }

    // MARK: Each tick

    /// As if an interrupt handler had counted Paula's "block finished" interrupts in the meantime.
    mutating func handleWaitOnPaulaDone<Output: TFMXOutput>(_ out: inout Output) {
        for v in 0 ..< voiceCount where voices[v].waitOnDMACount >= 0 {
            let x = Int(loopCount(v, &out))
            let y = Int(voices[v].waitOnDMAPrevLoops)
            let d = x >= y ? x - y : x + (0x10000 - y)
            if d > Int(voices[v].waitOnDMACount) {
                voices[v].waitOnDMACount = -1
                if voices[v].macroState == 0 { voices[v].macroState = -1 }
            } else {
                voices[v].waitOnDMACount = Int16(truncatingIfNeeded: Int(voices[v].waitOnDMACount) - d)
                voices[v].waitOnDMAPrevLoops = loopCount(v, &out)
            }
        }
    }

    mutating func handleDelayedDMAoff<Output: TFMXOutput>(_ out: inout Output) {
        for v in 0 ..< voiceCount where voices[v].delayedOff {
            voices[v].delayedOff = false
            off(v, &out)
        }
    }

    mutating func handleDelayedDMAon<Output: TFMXOutput>(_ out: inout Output) {
        for v in 0 ..< voiceCount where voices[v].delayedOn {
            voices[v].delayedOn = false
            on(v, &out)
        }
    }

    /// The sequencer's part of a tick: on every tick that its speed counts down to, each track's
    /// pattern goes on.
    mutating func runMain<Output: TFMXOutput>(_ out: inout Output) {
        admin.count &-= 1
        guard admin.count < 0 else { return }
        admin.count = admin.speed
        var evalMaxLoops = Self.recurseLimit
        repeat {
            sequencer.next = false
            var countInactive = 0
            var countInfinite = 0
            for t in 0 ..< 8 {
                tracks[t].on = getTrackMute(t)
                if tracks[t].PT >= 0x90 {
                    countInactive += 1
                } else if tracks[t].infiniteLoop {
                    countInfinite += 1
                }
                processPTTR(t, &out)
                if sequencer.next { break }
            }
            // The states in which the sequencer cannot go on.
            if !sequencer.next, countInactive == 8 || countInactive + countInfinite == 8 {
                songEnd = true
                triggerRestart = true
            }
            if songEnd, loopMode {
                songEnd = false
                if triggerRestart {
                    softRestart()
                    processTrackStep()
                }
            }
            if !sequencer.next { break }
            evalMaxLoops -= 1
        } while evalMaxLoops > 0
    }

    /// How many times over the library lets a step, a pattern or the sequencer go on at once.
    static let recurseLimit = 16

    /// A track's pattern: PT below $80 a pattern to play, below $90 one that goes on from the step
    /// before, and from $90 a track not used.
    mutating func processPTTR<Output: TFMXOutput>(_ t: Int, _ out: inout Output) {
        if tracks[t].PT < 0x90 {
            if tracks[t].offset == 0 { // the track did not set a pattern before
                tracks[t].PT = 0xFF
                return
            }
            if tracks[t].wait == 0 {
                processPattern(t)
            } else {
                tracks[t].wait &-= 1
            }
        } else if tracks[t].PT == 0xFE { // the track is cleared
            tracks[t].PT = 0xFF
            let v = Int(channelToVoiceMap[Int(UInt8(bitPattern: tracks[t].TR) & 7)])
            voices[v].macroState = 0
            off(v, &out)
        }
    }

    /// Runs the player for one tick. Returns its length in whole milliseconds.
    mutating func run<Output: TFMXOutput>(_ out: inout Output) -> Int {
        guard admin.initialized else { return 0 }
        playerCommon(&out)
        tickFPAdd &+= tickFP
        let tick = Int(tickFPAdd >> 8)
        tickFPAdd &= 0xFF
        songPosCurrent &+= UInt32(tick)
        return tick
    }

    mutating func playerCommon<Output: TFMXOutput>(_ out: inout Output) {
        guard !songEnd || loopMode else { return }
        handleWaitOnPaulaDone(&out)
        handleDelayedDMAoff(&out)
        switch variant.execOrder {
        case .modMacSeq:
            for v in 0 ..< voiceCount {
                processModulation(v, &out)
                processMacroMain(v, &out)
                paula[v].period = voices[v].outputPeriod
            }
            runMain(&out)
        case .seqModMac:
            runMain(&out)
            for v in 0 ..< voiceCount {
                processModulation(v, &out)
                processMacroMain(v, &out)
                paula[v].period = voices[v].outputPeriod
            }
        case .macModSeq:
            for v in 0 ..< voiceCount {
                processMacroMain(v, &out)
                processModulation(v, &out)
                paula[v].period = voices[v].outputPeriod
            }
            runMain(&out)
        }
        handleDelayedDMAon(&out)
    }

    /// A note, or a command to a voice, from a pattern or a macro: aa the note or command, bb the
    /// macro, c the volume, d the voice, and ee the detune.
    mutating func noteCmd() {
        let v = Int(channelToVoiceMap[Int(cmd.cd & 7)])
        if cmd.aa == 0xF7 { // envelope
            voices[v].envelopeSpeed = cmd.bb
            let count = (cmd.cd >> 4) + 1
            voices[v].envelopeCount = count
            voices[v].envelopeFlag = count
            voices[v].envelopeTarget = cmd.ee
        } else if cmd.aa == 0xF6 { // vibrato
            // Unlike the vibrato macro's, this one's time has always been an even number.
            let time = cmd.bb & 0xFE
            voices[v].vibratoTime = time
            voices[v].vibratoCount = time >> 1
            voices[v].vibratoIntensity = Int8(bitPattern: cmd.ee)
            voices[v].vibratoDelta = 0
        } else if cmd.aa == 0xF5 { // key up
            voices[v].keyUp = true
        } else if cmd.aa < 0xC0 { // a note
            voices[v].detune = variant.noNoteDetune ? 0 : Int16(Int8(bitPattern: cmd.ee))
            voices[v].noteVolume = cmd.cd >> 4
            voices[v].notePrevious = voices[v].note
            voices[v].note = cmd.aa
            voices[v].keyUp = false
            let mo = getMacroOffset(cmd.bb & 0x7F)
            if mo != voices[v].macroOffset { voices[v].branchIfSame = false }
            voices[v].macroOffset = mo
            voices[v].macroState = 1 // the macro is started on the next tick
        } else { // from $C0, a portamento to the note
            voices[v].portamentoCount = cmd.bb
            voices[v].portamentoWait = 1
            if voices[v].portamentoSpeed == 0 { voices[v].portamentoPeriod = voices[v].period }
            voices[v].portamentoSpeed = UInt16(cmd.ee)
            voices[v].note = cmd.aa & 0x3F
            voices[v].period = noteToPeriod(Int(voices[v].note))
        }
    }

    func noteToPeriod(_ note: Int) -> UInt16 {
        var note = note
        if note >= 0 {
            note &= 0x3F
        } else if note < -13 {
            note = -13
        }
        return Self.periods[note + 13]
    }

    /// The periods of the notes: an octave below the first, then the standard octaves, the last two
    /// of them the same as the one before.
    static let periods: [UInt16] = [
        0x0D5C,
        0x0C9C, 0x0BE8, 0x0B3C, 0x0A9A, 0x0A02, 0x0A02, 0x0972, 0x08EA, 0x086A, 0x07F2, 0x0780, 0x0718,
        0x06AE, 0x064E, 0x05F4, 0x059E, 0x054D, 0x0501, 0x04B9, 0x0475, 0x0435, 0x03F9, 0x03C0, 0x038C,
        0x0358, 0x032A, 0x02FC, 0x02D0, 0x02A8, 0x0282, 0x025E, 0x023B, 0x021B, 0x01FD, 0x01E0, 0x01C6,
        0x01AC, 0x0194, 0x017D, 0x0168, 0x0154, 0x0140, 0x012F, 0x011E, 0x010E, 0x00FE, 0x00F0, 0x00E3,
        0x00D6, 0x00CA, 0x00BF, 0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F, 0x0078, 0x0071,
        0x00D6, 0x00CA, 0x00BF, 0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F, 0x0078, 0x0071,
        0x00D6, 0x00CA, 0x00BF, 0x00B4,
    ]
}

/// What does nothing with what Paula is told, as the library's own stand-in voices do while it reads a
/// module and plays its song through once to find how long it is.
struct TFMXSilentOutput: TFMXOutput {
    func on(_: Int) {}
    func off(_: Int) {}
    func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
}
