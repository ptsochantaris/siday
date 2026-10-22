// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's macros of TFMX (src/Chris/Macro.cpp), Copyright (C) Michael Schwendt,
// used under the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

import SidayChips

// A macro is an instrument: a list of commands of four bytes, a command (masked to $3F) and its three
// bytes of argument, run for a voice tick by tick from when a note starts it, until a command waits.
// The places of the macros are a list of longs with no count: a truncated module's may point anywhere,
// and nothing is gained by checking them, as what is outside the memory reads as one byte.

/// What each macro command does. Which number is which differs between players (`setTFMXv1`, and a few
/// modules known by their checksums).
enum MacroCommand {
    case nop, stopSound, startSample, setBegin, setLen, wait, loop, cont, stop
    case addNote, setNote, reset, portamento, vibrato, addVolume, addVolNote, setVolume, envelope
    case loopKeyUp, addBegin, addLen, stopSample, waitKeyUp, goto, `return`, setPeriod
    case sampleLoop, oneShot, waitOnDMA, randomPlay, splitKey, splitVolume, randomMask, setPrevNote
    case playMacro, sid22, sid23, sid24, sid25, sid26, sid27, sid28, sid29, branchIfSame, keyUp
    /// On to the next command, after the tick: what Chris Hülsbeck's players do with a command beyond
    /// their tables.
    case later
}

extension TFMXDecoder {
    func getMacroOffset(_ macro: UInt8) -> UInt32 {
        offsets.header &+ long(offsets.macros &+ (UInt32(macro & 0x7F) << 2))
    }

    mutating func initMacro(_ v: Int) {
        // (TFMX 1.x, $1160: the voice's audio interrupt is turned off, and cleared.)
        if variant.original == .tfmx { clearAudioInterrupt(v) }
        voices[v].macroStep = 0
        voices[v].macroWait = 0
        voices[v].macroLoop = 0xFF
        voices[v].macroState = -1
        voices[v].waitOnDMACount = 0
        voices[v].effectsMode = variant.execOrder == .macModSeq ? 0 : 1
        voices[v].extraWait = true
    }

    mutating func processMacroMain<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if voices[v].macroState == 0 {
            return
        } else if voices[v].macroState == 1 {
            initMacro(v)
            // TFMX 1.x, $1142: a macro a note starts is set going with a wait of a tick (68(a6), which
            // is one), and so begins on the tick after the note's.
            if variant.original == .tfmx { voices[v].macroWait = 1 }
        }
        if voices[v].macroWait > 0 {
            voices[v].macroWait -= 1
            return
        }
        var macroLen = 0
        repeat {
            macroEvalAgain = false
            let p = voices[v].macroOffset &+ (voices[v].macroStep &<< 2)
            let command = byte(p)
            cmd.aa = 0
            cmd.bb = byte(p &+ 1)
            cmd.cd = byte(p &+ 2)
            cmd.ee = byte(p &+ 3)
            runMacroCommand(originalCommand(command) ?? macroTable[Int(command & 0x3F)], v, &out)
            macroLen += 1
        } while macroEvalAgain && macroLen < 32
    }

    /// Chris Hülsbeck's players read a macro's command as the whole byte: one beyond their tables goes
    /// on to the next after the tick (TFMX 1.x, $119a, from $23; TFMX Pro, $1768, from $34).
    private func originalCommand(_ command: UInt8) -> MacroCommand? {
        switch variant.original {
        case .none: nil
        case .tfmx: command >= 0x23 ? .later : nil
        case .pro, .sevenVoices: command >= 0x34 ? .later : nil
        }
    }

    private mutating func runMacroCommand<Output: TFMXOutput>(_ command: MacroCommand, _ v: Int, _ out: inout Output) {
        switch command {
        case .nop: macroNOP(v)
        case .stopSound: macroStopSound(v, &out)
        case .startSample: macroStartSample(v, &out)
        case .setBegin: macroSetBegin(v, &out)
        case .setLen: macroSetLen(v, &out)
        case .wait: macroWait(v)
        case .loop: macroLoop(v)
        case .cont: macroCont(v)
        case .stop: voices[v].macroState = 0
        case .addNote: macroAddNote(v)
        case .setNote: macroSetNote(v)
        case .reset: macroReset(v)
        case .portamento: macroPortamento(v)
        case .vibrato: macroVibrato(v)
        case .addVolume: macroAddVolume(v)
        case .addVolNote: macroAddVolNote(v)
        case .setVolume: macroSetVolume(v)
        case .envelope: macroEnvelope(v)
        case .loopKeyUp: macroLoopKeyUp(v)
        case .addBegin: macroAddBegin(v, &out)
        case .addLen: macroAddLen(v, &out)
        case .stopSample: macroStopSampleSub(v, &out)
        case .waitKeyUp: macroWaitKeyUp(v)
        case .goto: macroGoto(v)
        case .return: macroReturn(v)
        case .setPeriod: macroSetPeriod(v)
        case .sampleLoop: macroSampleLoop(v, &out)
        case .oneShot: macroOneShot(v, &out)
        case .waitOnDMA: macroWaitOnDMA(v, &out)
        case .randomPlay: macroRandomPlay(v)
        case .splitKey: macroSplitKey(v)
        case .splitVolume: macroSplitVolume(v)
        case .randomMask: macroRandomMask(v)
        case .setPrevNote: macroSetPrevNote(v)
        case .playMacro: macroPlayMacro(v)
        case .sid22: macroSID22(v, &out)
        case .sid23: macroSID23(v, &out)
        case .sid24: macroSID24(v)
        case .sid25: macroSID25(v)
        case .sid26: macroSID26(v)
        case .sid27: macroSID27(v)
        case .sid28: macroSID28(v)
        case .sid29: macroSID29(v)
        case .branchIfSame: macroBranchIfSame(v)
        case .keyUp: macroKeyUp(v)
        case .later: macroExtraWait(v)
        }
    }

    /// On to the next command, after a wait of a tick: TFMX 1.5 and 2.2 wait there always. Only a few
    /// players could turn the wait off, through the DMAoff commands ($00 and $13), and only a few
    /// modules do.
    private mutating func macroExtraWait(_ v: Int) {
        voices[v].macroStep &+= 1
        if voices[v].extraWait || variant.extraWaitV1 { return }
        // No wait, but it is turned back on.
        voices[v].extraWait = true
        macroEvalAgain = true
    }

    /// On to the next command at once.
    private mutating func next(_ v: Int) {
        voices[v].macroStep &+= 1
        macroEvalAgain = true
    }

    private mutating func macroNOP(_ v: Int) { next(v) }

    /// DMAoff and reset: the sample is stopped, and the effects too.
    private mutating func macroStopSound<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].envelopeFlag = 0
        voices[v].vibratoTime = 0
        voices[v].portamentoSpeed = 0
        voices[v].sid.targetLength = 0
        voices[v].rndFlag = 0
        macroStopSampleSub(v, &out)
    }

    /// DMAon: the sample is started where it was set to begin, at the end of the tick unless the player
    /// is one that starts it at once.
    private mutating func macroStartSample<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if variant.original != .none {
            // TFMX Pro, $18f8: the voice's audio interrupt is turned off and cleared, and the first byte
            // made the voice's flag for its effects ($1fd0): nought has them left out for the rest of
            // the tick, and a byte below nought until the next note. As UADE runs it (see
            // `setOriginalPlayer`) the voice is then started at once ($192a), as TFMX 1.x starts it
            // ($11ec), which does nothing with the byte nor the interrupt.
            if variant.original != .tfmx {
                clearAudioInterrupt(v)
                voices[v].effectsMode = Int8(bitPattern: cmd.bb)
            }
            voices[v].macroStep &+= 1
            if variant.original == .sevenVoices {
                // The player of TFMX 7V ($1682) starts one of the four it mixes at once, and its macro
                // goes no further that tick; the others at the end of the tick.
                if isMixedVoice(v) {
                    on(v, &out)
                    return
                }
                voices[v].delayedOn = true
            } else {
                on(v, &out)
            }
            macroEvalAgain = true
            return
        }
        if variant.noDelayedDMAon {
            on(v, &out)
        } else {
            voices[v].delayedOn = true
        }
        voices[v].macroStep &+= 1
        // A few modules set the first byte to 1, to have the effects (the synthesiser) run once before
        // the voice is started.
        if cmd.bb != 0 {
            voices[v].effectsMode = 1
            if variant.execOrder == .modMacSeq { processModulation(v, &out) }
        }
        macroEvalAgain = true
    }

    private mutating func macroSetBegin<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].addBeginCount = 0
        let start = offsets.sampleData &+ Self.makeDword(0, cmd.bb, cmd.cd, cmd.ee)
        macroSetBeginSub(v, start, &out)
    }

    private mutating func macroSetBeginSub<Output: TFMXOutput>(_ v: Int, _ start: UInt32, _ out: inout Output) {
        voices[v].sampleStart = start
        toPaulaStart(v, start, &out)
        next(v)
    }

    private mutating func macroSetLen<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        let length = Self.makeWord(cmd.cd, cmd.ee)
        voices[v].sampleLength = length
        toPaulaLength(v, length, &out)
        next(v)
    }

    private mutating func macroWait(_ v: Int) {
        if cmd.bb & 1 != 0 { // as random play wants it
            if voices[v].rndBlockWait { return }
            voices[v].rndBlockWait = true
            next(v)
        } else {
            voices[v].macroWait = Int16(bitPattern: Self.makeWord(cmd.cd, cmd.ee))
            macroExtraWait(v)
        }
    }

    private mutating func macroLoop(_ v: Int) {
        if voices[v].macroLoop == 0 {
            voices[v].macroLoop = 0xFF
            voices[v].macroStep &+= 1
            // R-Type, perhaps alone, waits a tick here.
            if variant.macroLoopExtraWait { return }
        } else {
            if voices[v].macroLoop == 0xFF {
                voices[v].macroLoop = cmd.bb &- 1
            } else {
                voices[v].macroLoop &-= 1
            }
            voices[v].macroStep = UInt32(Self.makeWord(cmd.cd, cmd.ee))
        }
        macroEvalAgain = true
    }

    private mutating func macroCont(_ v: Int) {
        voices[v].macroOffset = getMacroOffset(cmd.bb & 0x7F)
        voices[v].macroStep = UInt32(Self.makeWord(cmd.cd, cmd.ee))
        voices[v].macroLoop = 0xFF
        voices[v].branchIfSame = false
        macroEvalAgain = true
    }

    private mutating func macroAddNote(_ v: Int) {
        macroAddNoteSub(v, voices[v].note, voices[v].detune)
        macroExtraWait(v)
    }

    private mutating func macroAddNoteSub(_ v: Int, _ noteAdd: UInt8, _ detuneAdd: Int16) {
        let n = Int8(truncatingIfNeeded: Int(noteAdd) + Int(Int8(bitPattern: cmd.bb)))
        var p = variant.original == .none ? noteToPeriod(Int(n)) : originalNoteToPeriod(Int(n))
        let finetune = detuneAdd &+ Int16(bitPattern: Self.makeWord(cmd.cd, cmd.ee))
        if variant.finetuneUnscaled {
            p &+= UInt16(bitPattern: finetune)
        } else if finetune != 0 {
            p = UInt16(truncatingIfNeeded: ((Int32(finetune) + 0x100) &* Int32(p)) >> 8)
        }
        voices[v].period = p
        if voices[v].portamentoSpeed == 0 { voices[v].outputPeriod = p }
    }

    private mutating func macroSetNote(_ v: Int) {
        // TFMX 1's SetNote leaves out the voice's detune.
        macroAddNoteSub(v, 0, variant.setNoteV1 ? 0 : voices[v].detune)
        macroExtraWait(v)
    }

    /// Reset of the vibrato, portamento and envelope.
    private mutating func macroReset(_ v: Int) {
        voices[v].addBeginCount = 0
        voices[v].envelopeFlag = 0
        voices[v].vibratoTime = 0
        voices[v].portamentoSpeed = 0
        // TFMX Pro, $1daa: and the synthesiser and random play.
        if variant.original == .pro || variant.original == .sevenVoices {
            voices[v].sid.targetLength = 0
            voices[v].rndFlag = 0
        }
        next(v)
    }

    private mutating func macroPortamento(_ v: Int) {
        voices[v].portamentoCount = cmd.bb
        voices[v].portamentoWait = 1
        if variant.portaOverride || voices[v].portamentoSpeed == 0 { voices[v].portamentoPeriod = voices[v].period }
        voices[v].portamentoSpeed = Self.makeWord(cmd.cd, cmd.ee)
        next(v)
    }

    private mutating func macroVibrato(_ v: Int) {
        voices[v].vibratoTime = cmd.bb
        // TFMX 1 and 2 make the time even, which, for an odd time, changes how far the vibrato goes.
        if variant.vibratoTimeMask { voices[v].vibratoTime &= 0xFE }
        voices[v].vibratoCount = cmd.bb >> 1
        voices[v].vibratoIntensity = Int8(bitPattern: cmd.ee)
        if voices[v].portamentoSpeed == 0 {
            voices[v].outputPeriod = voices[v].period
            voices[v].vibratoDelta = 0
        }
        next(v)
    }

    /// The note's volume, three times over, and so much more (only a byte of it).
    private mutating func noteVolumePlus(_ v: Int) -> Int8 {
        let volume = voices[v].noteVolume &+ voices[v].noteVolume &+ voices[v].noteVolume
        return Int8(bitPattern: volume &+ cmd.ee)
    }

    private mutating func macroAddVolume(_ v: Int) {
        voices[v].volume = noteVolumePlus(v)
        next(v)
    }

    /// AddVolume, and with $FE as the second byte of its argument, a note added first (AddNote with
    /// nought).
    private mutating func macroAddVolNote(_ v: Int) {
        addNoteFirst(v)
        voices[v].volume = noteVolumePlus(v)
        next(v)
    }

    private mutating func addNoteFirst(_ v: Int) {
        if cmd.cd == 0xFE {
            let ee = cmd.ee
            cmd.cd = 0
            cmd.ee = 0
            macroAddNoteSub(v, voices[v].note, voices[v].detune)
            cmd.ee = ee
        }
    }

    private mutating func macroSetVolume(_ v: Int) {
        addNoteFirst(v)
        voices[v].volume = Int8(bitPattern: cmd.ee)
        next(v)
    }

    private mutating func macroEnvelope(_ v: Int) {
        voices[v].envelopeSpeed = cmd.bb
        voices[v].envelopeFlag = cmd.cd
        voices[v].envelopeCount = cmd.cd
        voices[v].envelopeTarget = cmd.ee
        next(v)
    }

    private mutating func macroLoopKeyUp(_ v: Int) {
        if !voices[v].keyUp {
            macroLoop(v)
        } else {
            next(v)
        }
    }

    /// AddBegin, so much added to where the sample begins. TFMX 1.5 and 2.2, and the players of their
    /// time, take no count: their modules leave it nought, or set it by mistake, writing a negative
    /// change as 24 bits. Later players add the change again, every so many ticks (`addBegin`), for
    /// which `noAddBeginCount` is seen to there.
    private mutating func macroAddBegin<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].addBeginCount = cmd.bb
        voices[v].addBeginArg = cmd.bb
        let offset = Int32(Int16(bitPattern: Self.makeWord(cmd.cd, cmd.ee)))
        voices[v].addBeginOffset = offset
        var begin = voices[v].sampleStart &+ UInt32(bitPattern: offset)
        // (Chris Hülsbeck's players let it go before them: TFMX 1.x, $120e; TFMX Pro, $195c.)
        if begin < offsets.sampleData, variant.original == .none { begin = offsets.sampleData }
        if voices[v].sid.targetLength == 0 {
            macroSetBeginSub(v, begin, &out)
        } else {
            voices[v].sampleStart = begin
            voices[v].sid.sourceOffset = begin
            next(v)
        }
    }

    private mutating func macroAddLen<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        next(v)
        let length = Int16(bitPattern: Self.makeWord(cmd.cd, cmd.ee))
        voices[v].sampleLength &+= UInt16(bitPattern: length)
        if voices[v].sid.targetLength == 0 {
            toPaulaLength(v, voices[v].sampleLength, &out)
        } else {
            // (TFMX Pro, $19a2, sets it to the sample's length as it now is.)
            voices[v].sid.sourceLength = variant.original == .none ? UInt16(bitPattern: length) : voices[v].sampleLength
        }
    }

    /// DMAoff, the sample stopped (at the end of the tick, for a few players' modules that ask for it,
    /// with no wait after); and with a volume, a volume set too.
    private mutating func macroStopSampleSub<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].macroStep &+= 1
        switch variant.original {
        case .none: break
        case .tfmx:
            // TFMX 1.x, $14bc (and $11c2): the voice is stopped, its interrupt turned off and cleared,
            // and that is all.
            clearAudioInterrupt(v)
            off(v, &out)
            macroEvalAgain = true
            return
        case .sevenVoices:
            // The player of TFMX 7V ($1640) sets no volume; one of the four it mixes is stopped at once,
            // and the next command that would end the tick does not; the others as the library's TFMX
            // Pro does.
            if isMixedVoice(v) {
                off(v, &out)
                voices[v].extraWait = false
                macroEvalAgain = true
            } else if cmd.bb != 0 {
                voices[v].extraWait = false
                voices[v].delayedOff = true
            } else {
                off(v, &out)
                macroEvalAgain = true
            }
            return
        case .pro:
            // TFMX Pro, $1890, as UADE runs it (with "DMA" as the player's way of waiting, which UADE's
            // configuration of it chooses): the voice is stopped at once and the macro goes on; and
            // the volume is set, with the fade's (but not heeding the voice's lock, as $23fe does).
            off(v, &out)
            macroEvalAgain = true
            if cmd.cd == 0 {
                if cmd.ee == 0 { return }
                let volume = voices[v].noteVolume &+ voices[v].noteVolume &+ voices[v].noteVolume
                voices[v].volume = Int8(truncatingIfNeeded: Int(volume) + Int(Self.makeWord(cmd.cd, cmd.ee)))
            } else {
                voices[v].volume = Int8(bitPattern: cmd.ee)
            }
            paula[v].volume = originalVolume(v, lockHeeded: false)
            return
        }
        if cmd.bb != 0 {
            voices[v].extraWait = false
            voices[v].delayedOff = true
        } else {
            off(v, &out)
            voices[v].extraWait = true
            macroEvalAgain = true
        }
        if cmd.cd == 0 {
            if cmd.ee == 0 { return }
            let volume = voices[v].noteVolume &+ voices[v].noteVolume &+ voices[v].noteVolume
            voices[v].volume = Int8(truncatingIfNeeded: Int(volume) + Int(Self.makeWord(cmd.cd, cmd.ee)))
        } else {
            voices[v].volume = Int8(bitPattern: cmd.ee)
        }
        // With the fade's volume.
        var volume = voices[v].volume
        if fade.volume < 64 { volume = Int8(truncatingIfNeeded: (4 * Int(voices[v].volume) * Int(fade.volume)) / (4 * 0x40)) }
        paula[v].volume = UInt16(bitPattern: Int16(volume))
    }

    private mutating func macroWaitKeyUp(_ v: Int) {
        if voices[v].keyUp {
            next(v)
        } else if voices[v].macroLoop == 0 {
            voices[v].macroLoop = 0xFF
            next(v)
        } else if voices[v].macroLoop == 0xFF {
            voices[v].macroLoop = cmd.ee &- 1
        } else {
            voices[v].macroLoop &-= 1
        }
    }

    private mutating func macroGoto(_ v: Int) {
        voices[v].macroOffsetSaved = voices[v].macroOffset
        voices[v].macroStepSaved = voices[v].macroStep
        let loop = voices[v].macroLoop
        macroCont(v)
        // (TFMX 1.x, $150e, leaves the count of the loop as it was.)
        if variant.original == .tfmx { voices[v].macroLoop = loop }
    }

    private mutating func macroReturn(_ v: Int) {
        voices[v].macroOffset = voices[v].macroOffsetSaved
        voices[v].macroStep = voices[v].macroStepSaved &+ 1
        macroEvalAgain = true
    }

    private mutating func macroSetPeriod(_ v: Int) {
        let period = Self.makeWord(cmd.cd, cmd.ee)
        voices[v].period = period
        if voices[v].portamentoSpeed == 0 { voices[v].outputPeriod = period }
        next(v)
    }

    /// The sample's loop: so many bytes on from where it began, and so much shorter.
    private mutating func macroSampleLoop<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        // (TFMX 1.x, $1552, takes only the lower word of the offset.)
        let offset = Self.makeDword(0, variant.original == .tfmx ? 0 : cmd.bb, cmd.cd, cmd.ee)
        voices[v].sampleStart &+= offset
        voices[v].sampleLength &-= UInt16(truncatingIfNeeded: offset >> 1)
        toPaulaStart(v, voices[v].sampleStart, &out)
        toPaulaLength(v, voices[v].sampleLength, &out)
        next(v)
    }

    /// A sample played once: after it, the word of nought at the samples' beginning.
    private mutating func macroOneShot<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].addBeginCount = 0
        voices[v].sampleStart = offsets.sampleData
        voices[v].sampleLength = 1
        toPaulaStart(v, voices[v].sampleStart, &out)
        toPaulaLength(v, voices[v].sampleLength, &out)
        next(v)
    }

    /// A wait until the sample has been played through so many times (`handleWaitOnPaulaDone`).
    private mutating func macroWaitOnDMA<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if variant.original != .none {
            waitForAudioInterrupts(v, count: variant.original == .tfmx ? 0 : Int16(bitPattern: Self.makeWord(cmd.cd, cmd.ee)))
            macroExtraWait(v)
            return
        }
        voices[v].waitOnDMACount = Int16(bitPattern: Self.makeWord(cmd.cd, cmd.ee))
        voices[v].macroState = 0
        voices[v].waitOnDMAPrevLoops = loopCount(v, &out)
        macroExtraWait(v)
    }

    private mutating func macroRandomPlay(_ v: Int) {
        voices[v].rndMacro = cmd.bb
        voices[v].rndSpeed = Int8(bitPattern: cmd.cd)
        voices[v].rndMode = cmd.ee
        voices[v].rndCount = 1
        voices[v].rndFlag = 1
        randomPlay(v)
        voices[v].rndBlockWait = true
        next(v)
    }

    private mutating func macroSplitKey(_ v: Int) {
        if cmd.bb >= voices[v].note {
            voices[v].macroStep &+= 1
        } else {
            voices[v].macroStep = UInt32(Self.makeWord(cmd.cd, cmd.ee))
        }
        macroEvalAgain = true
    }

    private mutating func macroSplitVolume(_ v: Int) {
        if Int(cmd.bb) >= Int(voices[v].volume) {
            voices[v].macroStep &+= 1
        } else {
            voices[v].macroStep = UInt32(Self.makeWord(cmd.cd, cmd.ee))
        }
        macroEvalAgain = true
    }

    private mutating func macroRandomMask(_ v: Int) {
        voices[v].rndMask = cmd.bb
        next(v)
    }

    /// AddNote to the note before (not in TFMX 1, so with the voice's detune always).
    private mutating func macroSetPrevNote(_ v: Int) {
        macroAddNoteSub(v, voices[v].notePrevious, voices[v].detune)
        macroExtraWait(v)
    }

    /// Plays macro bb on voice d with this voice's note, its volume and detune ee.
    private mutating func macroPlayMacro(_ v: Int) {
        cmd.aa = voices[v].note
        cmd.cd |= UInt8(truncatingIfNeeded: Int(voices[v].noteVolume) << 4)
        noteCmd()
        next(v)
    }

    // MARK: The synthesiser

    /// Where the sound is made from, and Paula set to play the voice's own stretch it is made into.
    private mutating func macroSID22<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].addBeginCount = 0
        voices[v].sid.sourceOffset = offsets.sampleData &+ Self.makeDword(0, cmd.bb, cmd.cd, cmd.ee)
        voices[v].sampleStart = voices[v].sid.sourceOffset
        toPaulaStart(v, offsets.sampleData &+ voices[v].sid.targetOffset, &out)
        next(v)
    }

    /// How long the made sound is, in bytes (nought for 256), and the stretch it is made from.
    private mutating func macroSID23<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        var length = Self.makeWord(cmd.aa, cmd.bb)
        if length == 0 { length = 0x100 }
        toPaulaLength(v, length >> 1, &out)
        voices[v].sid.targetLength = (length &- 1) & 0xFF
        let sourceLength = Self.makeWord(cmd.cd, cmd.ee)
        voices[v].sid.sourceLength = sourceLength
        voices[v].sampleLength = sourceLength
        next(v)
    }

    private mutating func macroSID24(_ v: Int) {
        voices[v].sid.op3Offset = Self.makeDword(cmd.bb, cmd.cd, cmd.ee, 0)
        next(v)
    }

    /// The third operator moves where in the source the sound is made from.
    private mutating func macroSID25(_ v: Int) {
        voices[v].sid.op3Speed = Self.makeWord(cmd.aa, cmd.bb)
        voices[v].sid.op3Count = voices[v].sid.op3Speed
        voices[v].sid.op3Delta = Int16(bitPattern: Self.makeWord(cmd.cd, cmd.ee))
        next(v)
    }

    private mutating func macroSID26(_ v: Int) {
        voices[v].sid.op2Offset = Self.makeDword(0, cmd.bb, cmd.cd, cmd.ee)
        next(v)
    }

    /// The second operator changes the step through the source.
    private mutating func macroSID27(_ v: Int) {
        voices[v].sid.op2Speed = Self.makeWord(cmd.aa, cmd.bb)
        voices[v].sid.op2Count = voices[v].sid.op2Speed
        voices[v].sid.op2Delta = Int16(bitPattern: Self.makeWord(cmd.cd, cmd.ee))
        next(v)
    }

    /// The first operator changes how far the sound moves towards the source at each byte: the high
    /// byte of its step is set, and its low byte kept.
    private mutating func macroSID28(_ v: Int) {
        voices[v].sid.op1InterDelta = Self.makeWord(cmd.ee, UInt8(voices[v].sid.op1InterDelta & 0xFF))
        voices[v].sid.op1InterMod = Int16(truncatingIfNeeded: 16 * Int(Int8(bitPattern: cmd.cd)))
        voices[v].sid.op1Speed = Self.makeWord(cmd.aa, cmd.bb)
        voices[v].sid.op1Count = voices[v].sid.op1Speed
        next(v)
    }

    /// The synthesiser stopped; with a first byte, its operators cleared.
    private mutating func macroSID29(_ v: Int) {
        voices[v].macroStep &+= 1
        voices[v].sid.targetLength = 0
        if cmd.bb != 0 {
            voices[v].sid.op1Speed = 0
            voices[v].sid.op1Count = 0
            voices[v].sid.op1InterDelta = 0
            voices[v].sid.op1InterMod = 0
            voices[v].sid.op2Speed = 0
            voices[v].sid.op2Count = 0
            voices[v].sid.op2Offset = 0
            voices[v].sid.op2Delta = 0
            voices[v].sid.op3Speed = 0
            voices[v].sid.op3Count = 0
            voices[v].sid.op3Offset = 0
            voices[v].sid.op3Delta = 0
        }
        macroEvalAgain = true
    }

    /// $30, in Gem'X's and Turrican 3's players: on to step cdee if the voice's macro is the same as
    /// at its last note (a new note, Cont and Goto clear that). Only Gem'X's music is changed by it.
    private mutating func macroBranchIfSame(_ v: Int) {
        macroEvalAgain = true
        if voices[v].branchIfSame {
            voices[v].macroStep = UInt32(Self.makeWord(cmd.cd, cmd.ee))
        } else {
            voices[v].branchIfSame = true
            voices[v].macroStep &+= 1
        }
    }

    /// $31, in the same players, used only by Turrican 3's title: key up on voice d.
    private mutating func macroKeyUp(_ v: Int) {
        cmd.aa = 0xF5
        noteCmd()
        next(v)
    }
}
