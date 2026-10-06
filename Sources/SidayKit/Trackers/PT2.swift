// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

import Foundation

// Pro Tracker 2.x player, ported from Ay_Emul by Sergey Bulba (Players.pas, PT2_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.

public final class PT2Source: AYFrameSource {
    private struct Channel {
        var addressInPattern = 0, ornamentPointer = 0, samplePointer = 0, ton = 0
        var loopOrnamentPosition = 0, ornamentLength = 0, positionInOrnament = 0
        var loopSamplePosition = 0, sampleLength = 0, positionInSample = 0
        var volume = 0, numberOfNotesToSkip = 0, note = 0, slideToNote = 0, amplitude = 0
        var currentTonSliding = 0, tonDelta = 0 // smallint
        var glissType = 0
        var envelopeEnabled = false, enabled = false
        var glissade = 0, additionToNoise = 0, noteSkipCounter = 0 // shortint
    }

    // Header layout.
    private let delayOffset = 0, numberOfPositions = 1, loopPosition = 2
    private let samplesPointers = 3, ornamentsPointers = 67, patternsPointer = 99, musicName = 101, positionList = 131

    private let mem: ModuleMemory
    private var delayCounter = 0, delay = 0, currentPosition = 0
    private var a = Channel(), b = Channel(), c = Channel()
    private let noteTable = TrackerTables.PT3NoteTable_ST
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0

    public init(_ data: Data) throws {
        // The cheap part of FoundPT2: room for a header and one position, and a pattern table inside the file.
        // The rest of its checks (ornament 0 being 01 00 00, the 255 that ends the position list, the size of
        // the pattern table) fail on modules that still play, so they are not applied.
        guard data.count >= 132, data.count <= 65536 else { throw TuneError.malformed("not a PT2 module") }
        mem = ModuleMemory(data)
        let patterns = mem.word(patternsPointer)
        guard patterns != 0, patterns < data.count else {
            throw TuneError.malformed("PT2 structure is not valid")
        }

        var info = TuneInfo(format: "PT2")
        info.title = mem.text(at: musicName, length: 30)
        self.info = info

        restart()
    }

    public func restart() {
        loopCount = 0
        delayCounter = 1
        delay = Int(mem[delayOffset])
        currentPosition = 0
        var a = Channel()
        // Ay_Emul gives every channel sample 1 to start with; the original player has no default sample.
        a.samplePointer = mem.word(samplesPointers + 2)
        a.sampleLength = Int(mem[a.samplePointer])
        a.samplePointer = u16(a.samplePointer + 1)
        a.loopSamplePosition = Int(mem[a.samplePointer])
        a.samplePointer = u16(a.samplePointer + 1)
        a.ornamentPointer = mem.word(ornamentsPointers)
        a.ornamentLength = Int(mem[a.ornamentPointer])
        a.ornamentPointer = u16(a.ornamentPointer + 1)
        a.loopOrnamentPosition = Int(mem[a.ornamentPointer])
        a.ornamentPointer = u16(a.ornamentPointer + 1)
        a.volume = 15
        self.a = a; b = a; c = a
        let base = mem.word(patternsPointer) + Int(mem[positionList]) * 6
        self.a.addressInPattern = mem.word(base)
        b.addressInPattern = mem.word(base + 2)
        c.addressInPattern = mem.word(base + 4)
    }

    private func patternInterpreter(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        var quit = false
        var gliss = false
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        repeat {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0xE1 ... 0xFF:
                ch.samplePointer = mem.word(samplesPointers + (value - 0xE0) * 2)
                ch.sampleLength = Int(mem[ch.samplePointer])
                ch.samplePointer = u16(ch.samplePointer + 1)
                ch.loopSamplePosition = Int(mem[ch.samplePointer])
                ch.samplePointer = u16(ch.samplePointer + 1)
            case 0xE0:
                ch.positionInSample = 0
                ch.positionInOrnament = 0
                ch.currentTonSliding = 0
                ch.glissType = 0
                ch.enabled = false
                quit = true
            case 0x80 ... 0xDF:
                ch.positionInSample = 0
                ch.positionInOrnament = 0
                ch.currentTonSliding = 0
                if gliss {
                    ch.slideToNote = value - 0x80
                    if ch.glissType == 1 { ch.note = ch.slideToNote }
                } else {
                    ch.note = value - 0x80
                    ch.glissType = 0
                }
                ch.enabled = true
                quit = true
            case 0x7F:
                ch.envelopeEnabled = false
            case 0x71 ... 0x7E:
                ch.envelopeEnabled = true
                regs.pointee.setEnvelopeRegister(value - 0x70)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                regs.pointee.envelope = (regs.pointee.envelope & 0xFF00) | Int(mem[ch.addressInPattern])
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                regs.pointee.envelope = (regs.pointee.envelope & 0x00FF) | Int(mem[ch.addressInPattern]) << 8
            case 0x70:
                quit = true
            case 0x60 ... 0x6F:
                ch.ornamentPointer = mem.word(ornamentsPointers + (value - 0x60) * 2)
                ch.ornamentLength = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.loopOrnamentPosition = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.positionInOrnament = 0
            case 0x20 ... 0x5F:
                ch.numberOfNotesToSkip = value - 0x20
            case 0x10 ... 0x1F:
                ch.volume = value - 0x10
            case 0x0F:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                delay = Int(mem[ch.addressInPattern])
            case 0x0E:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.glissade = mem.signed(ch.addressInPattern)
                ch.glissType = 1
                gliss = true
            case 0x0D:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.glissade = s8(abs(mem.signed(ch.addressInPattern)))
                // The two bytes that follow hold a precalculated Ton_Delta. It is wrong for the first note of
                // a pattern, so it is skipped and worked out below instead.
                ch.addressInPattern = u16(ch.addressInPattern + 2)
                ch.glissType = 2
                gliss = true
            case 0x0C:
                ch.glissType = 0
            default:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.additionToNoise = mem.signed(ch.addressInPattern)
            }
            ch.addressInPattern = u16(ch.addressInPattern + 1)
            guardCount += 1
        } while !quit && guardCount < 65536
        if gliss, ch.glissType == 2 {
            ch.tonDelta = abs(noteTable[ch.slideToNote] - noteTable[ch.note])
            if ch.slideToNote > ch.note { ch.glissade = s8(-ch.glissade) }
        }
        ch.noteSkipCounter = s8(ch.numberOfNotesToSkip)
    }

    private func getRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        if ch.enabled {
            let sample = ch.samplePointer + ch.positionInSample * 3
            let b0 = Int(mem[sample])
            let b1 = Int(mem[sample + 1])
            ch.ton = Int(mem[sample + 2]) + (b1 & 15) << 8
            if b0 & 4 == 0 { ch.ton = u16(-ch.ton) }
            var j = u8(ch.note + Int(mem[ch.ornamentPointer + ch.positionInOrnament]))
            if s8(j) < 0 { j = 0 } else if j > 95 { j = 95 }
            ch.ton = (ch.ton + ch.currentTonSliding + noteTable[j]) & 0xFFF
            if ch.glissType == 2 {
                ch.tonDelta = s16(ch.tonDelta - abs(ch.glissade))
                if ch.tonDelta < 0 {
                    ch.note = ch.slideToNote
                    ch.glissType = 0
                    ch.currentTonSliding = 0
                }
            }
            if ch.glissType != 0 { ch.currentTonSliding = s16(ch.currentTonSliding + ch.glissade) }
            // round(x / 256); no product of a volume and a sample level lands on a half, so the rounding mode
            // does not come into it.
            ch.amplitude = ((ch.volume * 17 + (ch.volume > 7 ? 1 : 0)) * (b1 >> 4) + 128) >> 8
            if ch.envelopeEnabled { ch.amplitude |= 16 }
            if b0 & 1 != 0 {
                tempMixer |= 64
            } else {
                regs.pointee.noise = ((b0 >> 3) + u8(ch.additionToNoise)) & 31
            }
            if b0 & 2 != 0 { tempMixer |= 8 }
            ch.positionInSample = u8(ch.positionInSample + 1)
            if ch.positionInSample == ch.sampleLength { ch.positionInSample = ch.loopSamplePosition }
            ch.positionInOrnament = u8(ch.positionInOrnament + 1)
            if ch.positionInOrnament == ch.ornamentLength { ch.positionInOrnament = ch.loopOrnamentPosition }
        } else {
            ch.amplitude = 0
        }
        tempMixer >>= 1
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        delayCounter = u8(delayCounter - 1)
        if delayCounter == 0 {
            a.noteSkipCounter = s8(a.noteSkipCounter - 1)
            if a.noteSkipCounter < 0 {
                if mem[a.addressInPattern] == 0 {
                    currentPosition = u8(currentPosition + 1)
                    if currentPosition == Int(mem[numberOfPositions]) {
                        currentPosition = Int(mem[loopPosition])
                        loopCount += 1
                    }
                    let base = mem.word(patternsPointer) + Int(mem[positionList + currentPosition]) * 6
                    a.addressInPattern = mem.word(base)
                    b.addressInPattern = mem.word(base + 2)
                    c.addressInPattern = mem.word(base + 4)
                }
                patternInterpreter(&a, regs)
            }
            b.noteSkipCounter = s8(b.noteSkipCounter - 1)
            if b.noteSkipCounter < 0 { patternInterpreter(&b, regs) }
            c.noteSkipCounter = s8(c.noteSkipCounter - 1)
            if c.noteSkipCounter < 0 { patternInterpreter(&c, regs) }
            delayCounter = delay
        }
        tempMixer = 0
        getRegisters(&a, regs)
        getRegisters(&b, regs)
        getRegisters(&c, regs)
        regs.pointee.mixer = tempMixer
        regs.pointee.tonA = a.ton
        regs.pointee.tonB = b.ton
        regs.pointee.tonC = c.ton
        regs.pointee.amplA = a.amplitude
        regs.pointee.amplB = b.amplitude
        regs.pointee.amplC = c.amplitude
    }
}
