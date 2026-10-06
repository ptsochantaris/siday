// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

import Foundation

// Fast Tracker player, ported from Ay_Emul by Sergey Bulba (Players.pas, FTC_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.
//
// A module on disk has its sample, ornament and pattern pointers counted from the start of the file; Ay_Emul
// only relocates modules it rips out of memory dumps, never a .ftc file, and neither does this port.

public final class FTCSource: AYFrameSource {
    private struct Channel {
        var addressInPattern = 0, ornamentPointer = 0, samplePointer = 0, envelopeAccumulator = 0, envelope = 0, ton = 0
        var ornamentLength = 0, loopOrnamentPosition = 0, positionInOrnament = 0
        var sampleLength = 0, loopSamplePosition = 0, positionInSample = 0
        var sampleNoiseAccumulator = 0, noiseAccumulator = 0, noteAccumulator = 0, tonSlideDirection = 0
        var volume = 0, noise = 0, amplitude = 0, previousNote = 0, note = 0
        var noteSkipCounter = 0, volumeSlide = 0
        var additionToTon = 0, tonSlideStep = 0, tonSlideStep1 = 0, currentTonSliding = 0, tonAccumulator = 0
        var envelopeEnabled = false, sampleEnabled = false
    }

    // Header layout. A position is two bytes, pattern and transposition; pattern 255 ends the list.
    private static let musicName = 0, delayOffset = 0x45, loopPosition = 0x46, patternsPointerOffset = 0x4B
    private static let samplesPointers = 0x52, ornamentsPointers = 0x92, positions = 0xD4

    private let mem: ModuleMemory
    private let version: Int
    private let noteTable: [Int]
    private let patternsPointer: Int
    private var delay = 0, delayCounter = 0, transposition = 0, currentPosition = 0, envT = 0, retrig = 0
    private var a = Channel(), b = Channel(), c = Channel()
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0
    private var newEnvT = -1

    public init(_ data: Data) throws {
        guard data.count >= Self.positions + 3, data.count <= 65536 else { throw TuneError.malformed("not an FTC module") }
        mem = ModuleMemory(data)
        patternsPointer = mem.word(Self.patternsPointerOffset)

        // The tracker's version is the last two characters of "Fast Tracker v1.0x"; 1.07 and later carry the
        // number of their note table in the byte before that text.
        var v = 0
        let digit = Int(mem[Self.musicName + 68])
        if mem[Self.musicName + 67] == 0x30, digit >= 0x30, digit <= 0x39 { v = digit - 0x30 }
        version = v
        if v < 7 {
            noteTable = TrackerTables.PT3NoteTable_ST
        } else if mem[Self.musicName + 0x32] == 2 {
            noteTable = TrackerTables.FTCNoteTable2
        } else {
            noteTable = TrackerTables.ST_Table
        }

        // Ay_Emul opens a .ftc file without testing it (FoundFTC is for ripping). What is asked for here is the
        // least a module needs to start: a first position, and its three pattern pointers inside the file.
        let first = Int(mem[Self.positions])
        let row = patternsPointer + first * 6
        guard first != 255, patternsPointer >= Self.positions + 2, row + 6 <= data.count else {
            throw TuneError.malformed("FTC structure is not valid")
        }
        for channel in 0 ..< 3 where mem.word(row + channel * 2) >= data.count {
            throw TuneError.malformed("FTC structure is not valid")
        }

        var info = TuneInfo(format: "FTC")
        info.title = mem.text(at: Self.musicName + 8, length: 42)
        let editor = mem.text(at: Self.musicName + 51, length: 18)
        if editor.hasPrefix("Fast Tracker") { info.detail = editor }
        self.info = info
        restart()
    }

    public func restart() {
        loopCount = 0
        tempMixer = 0
        newEnvT = -1
        delay = Int(mem[Self.delayOffset])
        delayCounter = 1
        currentPosition = 0
        envT = 0
        retrig = 0
        transposition = Int(mem[Self.positions + 1])
        var channel = Channel()
        channel.ornamentPointer = mem.word(Self.ornamentsPointers)
        channel.samplePointer = Self.samplesPointers
        channel.ornamentLength = 1
        channel.volume = 15
        a = channel; b = channel; c = channel
        let row = patternsPointer + Int(mem[Self.positions]) * 6
        a.addressInPattern = mem.word(row)
        b.addressInPattern = mem.word(row + 2)
        c.addressInPattern = mem.word(row + 4)
    }

    /// The Pascal indexes its tables with a byte and no range check; a note past the last one is taken as the last.
    @inline(__always) private func getNoteFreq(_ j: Int) -> Int {
        noteTable[min(j, 95)]
    }

    private func patternInterpreter(_ ch: inout Channel, _ chanNum: Int) {
        var quit = false
        var exxAF = 2
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        repeat {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0x00 ... 0x1F:
                ch.samplePointer = mem.word(Self.samplesPointers + value * 2)
                ch.samplePointer = u16(ch.samplePointer + 1)
                ch.loopSamplePosition = Int(mem[ch.samplePointer])
                ch.samplePointer = u16(ch.samplePointer + 1)
                ch.sampleLength = u8(Int(mem[ch.samplePointer]) + 1)
                ch.samplePointer = u16(ch.samplePointer + 1)
            case 0x20 ... 0x2F:
                ch.volume = value - 0x20
            case 0x30, 0x60 ... 0xCB:
                if value == 0x30 {
                    ch.sampleEnabled = false
                } else {
                    ch.previousNote = ch.note
                    ch.note = u8(transposition + value - 0x60)
                    ch.sampleEnabled = true
                }
                ch.positionInSample = 0
                ch.sampleNoiseAccumulator = 0
                ch.volumeSlide = 0
                ch.noiseAccumulator = 0
                ch.noteAccumulator = 0
                ch.positionInOrnament = 0
                ch.tonAccumulator = 0
                ch.envelopeAccumulator = 0
                if exxAF > 0 {
                    ch.currentTonSliding = 0
                    ch.tonSlideDirection = 0
                }
                if exxAF > 1 { ch.tonSlideStep = 0 }
                ch.noteSkipCounter = 0
                quit = true
            case 0x31 ... 0x3E:
                newEnvT = value - 0x30
                ch.envelopeEnabled = true
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.envelope = mem.word(ch.addressInPattern)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x3F:
                ch.envelopeEnabled = false
            case 0x40 ... 0x5F:
                ch.noteSkipCounter = value - 0x40
                exxAF = 1
                quit = true
            case 0xCC ... 0xEC:
                ch.ornamentPointer = mem.word(Self.ornamentsPointers + (value - 0xCC) * 2)
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.loopOrnamentPosition = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.ornamentLength = u8(Int(mem[ch.ornamentPointer]) + 1)
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.positionInOrnament = 0
                ch.noiseAccumulator = 0
                ch.noteAccumulator = 0
            case 0xED:
                exxAF = 1
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.tonSlideStep = s16(mem.word(ch.addressInPattern))
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0xEE:
                exxAF = 0
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.tonSlideStep1 = Int(mem[ch.addressInPattern])
            case 0xEF:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                if version > 7, mem[ch.addressInPattern] == 0xFE {
                    // Full envelope and tone retrigger.
                    retrig = chanNum
                } else {
                    ch.noise = Int(mem[ch.addressInPattern])
                }
            default:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                delay = Int(mem[ch.addressInPattern])
            }
            ch.addressInPattern = u16(ch.addressInPattern + 1)
            guardCount += 1
        } while !quit && guardCount < 65536
        if exxAF == 0 {
            ch.currentTonSliding = s16(getNoteFreq(ch.previousNote) - getNoteFreq(ch.note))
            if ch.currentTonSliding < 0 {
                ch.tonSlideStep = ch.tonSlideStep1
                ch.tonSlideDirection = 1
            } else {
                ch.tonSlideStep = -ch.tonSlideStep1
                ch.tonSlideDirection = 2
            }
        }
    }

    private func getRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        let ornament = ch.ornamentPointer + ch.positionInOrnament * 2
        let addToNote = u8(ch.noteAccumulator + Int(mem[ornament + 1]))
        var b = Int(mem[ornament])
        if b & 64 != 0 { ch.noteAccumulator = addToNote }
        let addToNoise = u8(ch.noiseAccumulator + b)
        if s8(b) < 0 { ch.noiseAccumulator = addToNoise }
        ch.positionInOrnament = u8(ch.positionInOrnament + 1)
        if ch.positionInOrnament == ch.ornamentLength { ch.positionInOrnament = ch.loopOrnamentPosition }
        var j = 0
        if ch.sampleEnabled {
            let sample = ch.samplePointer + ch.positionInSample * 5
            b = Int(mem[sample])
            j = u8(ch.sampleNoiseAccumulator + b)
            if s8(b) < 0 { ch.sampleNoiseAccumulator = j }
            if b & 64 == 0 {
                regs[0].noise = (j + ch.noise + addToNoise) & 31
            } else {
                tempMixer |= 64
            }
            var k = u16(ch.tonAccumulator + mem.word(sample + 1))
            b = Int(mem[sample + 2])
            if s8(b) < 0 { ch.tonAccumulator = s16(k) }
            ch.additionToTon = s16(k)
            if b & 64 != 0 { tempMixer |= 8 }
            b = Int(mem[sample + 3])
            if b & 32 != 0 {
                if b & 16 != 0 {
                    ch.volumeSlide -= 1
                    if ch.volumeSlide < -15 { ch.volumeSlide = -15 }
                } else {
                    ch.volumeSlide += 1
                    if ch.volumeSlide > 15 { ch.volumeSlide = 15 }
                }
            }
            j = u8(ch.volumeSlide + (b & 15))
            if s8(j) < 0 { j = 0 } else if j > 15 { j = 15 }
            // round(x / 256); x is never an odd multiple of 128, so there is no tie to break.
            ch.amplitude = ((ch.volume * 17 + (ch.volume > 7 ? 1 : 0)) * j + 128) >> 8
            k = u16(ch.envelopeAccumulator + mem.signed(sample + 4))
            if s8(b) < 0 { ch.envelopeAccumulator = k }
            if b & 64 != 0, ch.envelopeEnabled {
                regs[0].envelope = u16(ch.envelope - k)
                ch.amplitude |= 16
            }
            ch.positionInSample = u8(ch.positionInSample + 1)
            if ch.positionInSample == ch.sampleLength { ch.positionInSample = ch.loopSamplePosition }
        } else {
            ch.amplitude = 0
            tempMixer |= 72
        }
        j = u8(ch.note + addToNote)
        if j > 0x5F { j = 0x5F }
        ch.ton = u16(getNoteFreq(j) + ch.additionToTon)
        ch.currentTonSliding = s16(ch.currentTonSliding + ch.tonSlideStep)
        if (ch.tonSlideDirection == 1 && ch.currentTonSliding >= 0) || (ch.tonSlideDirection == 2 && ch.currentTonSliding < 0) {
            ch.currentTonSliding = 0
            ch.tonSlideStep = 0
        } else {
            ch.ton = u16(ch.ton + ch.currentTonSliding)
        }
        ch.ton &= 0xFFF
        tempMixer >>= 1
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        newEnvT = -1
        delayCounter = u8(delayCounter - 1)
        if delayCounter == 0 {
            a.noteSkipCounter = s8(a.noteSkipCounter - 1)
            if a.noteSkipCounter < 0 {
                if mem[a.addressInPattern] == 255 {
                    currentPosition = u8(currentPosition + 1)
                    if mem[Self.positions + currentPosition * 2] == 255 {
                        currentPosition = Int(mem[Self.loopPosition])
                        loopCount += 1
                    }
                    transposition = Int(mem[Self.positions + currentPosition * 2 + 1])
                    let row = patternsPointer + Int(mem[Self.positions + currentPosition * 2]) * 6
                    a.addressInPattern = mem.word(row)
                    b.addressInPattern = mem.word(row + 2)
                    c.addressInPattern = mem.word(row + 4)
                }
                patternInterpreter(&a, 1)
            }
            b.noteSkipCounter = s8(b.noteSkipCounter - 1)
            if b.noteSkipCounter < 0 { patternInterpreter(&b, 2) }
            c.noteSkipCounter = s8(c.noteSkipCounter - 1)
            if c.noteSkipCounter < 0 { patternInterpreter(&c, 3) }
            delayCounter = delay
        }

        // The original player does not write an envelope type it has already set, except to retrigger
        // (Fast Tracker 1.08). Ay_Emul's retrigger also restarts the tone generator of the channel that asked
        // for it; that is a state of the chip and not of its registers, and is left out here.
        if newEnvT >= 0, newEnvT != envT {
            envT = newEnvT
            regs[0].setEnvelopeRegister(envT)
        } else if retrig != 0 {
            regs[0].setEnvelopeRegister(envT)
        }
        retrig = 0

        tempMixer = 0
        getRegisters(&a, regs)
        getRegisters(&b, regs)
        getRegisters(&c, regs)
        regs[0].mixer = tempMixer
        regs[0].tonA = a.ton
        regs[0].tonB = b.ton
        regs[0].tonC = c.ton
        regs[0].amplA = a.amplitude
        regs[0].amplB = b.amplitude
        regs[0].amplC = c.amplitude
    }
}
