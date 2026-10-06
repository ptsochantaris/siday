// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

// Pro Tracker 1.x player, ported from Ay_Emul by Sergey Bulba (Players.pas, PT1_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.

public final class PT1Source: AYFrameSource {
    private struct Channel {
        var addressInPattern = 0, ornamentPointer = 0, samplePointer = 0, ton = 0
        var numberOfNotesToSkip = 0, volume = 0, loopSamplePosition = 0, positionInSample = 0, sampleLength = 0
        var amplitude = 0, note = 0
        var noteSkipCounter = 0 // shortint
        var envelopeEnabled = false, enabled = false
    }

    // Header layout.
    private let delayOffset = 0, numberOfPositions = 1, loopPosition = 2
    private let samplesPointers = 3, ornamentsPointers = 35, patternsPointer = 67, musicName = 69, positionList = 99

    private let mem: ModuleMemory
    private var delay = 0, delayCounter = 0, currentPosition = 0
    private var a = Channel(), b = Channel(), c = Channel()
    private let noteTable = TrackerTables.PT3NoteTable_ST
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0

    public init(_ data: [UInt8]) throws {
        // The cheap part of FoundPT1: room for a header and one position, and a pattern table inside the file.
        // Its other checks (the last sample ending where the first ornament starts, a whole 64-byte last
        // ornament) fail on modules that still play, so they are not applied.
        guard data.count >= 0x66, data.count <= 65536 else { throw TuneError.malformed("not a PT1 module") }
        mem = ModuleMemory(data)
        let patterns = mem.word(patternsPointer)
        guard patterns > positionList, patterns < data.count else {
            throw TuneError.malformed("PT1 structure is not valid")
        }

        var info = TuneInfo(format: "PT1")
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
        // No sample is selected to begin with: pointer, length and loop are all zero.
        a.ornamentPointer = mem.word(ornamentsPointers)
        a.volume = 15
        self.a = a; b = a; c = a
        let base = mem.word(patternsPointer) + Int(mem[positionList]) * 6
        self.a.addressInPattern = mem.word(base)
        b.addressInPattern = mem.word(base + 2)
        c.addressInPattern = mem.word(base + 4)
    }

    private func patternInterpreter(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        var quit = false
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        repeat {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0x00 ... 0x5F:
                ch.note = value
                ch.enabled = true
                ch.positionInSample = 0
                quit = true
            case 0x60 ... 0x6F:
                ch.samplePointer = mem.word(samplesPointers + (value - 0x60) * 2)
                ch.sampleLength = Int(mem[ch.samplePointer])
                ch.samplePointer = u16(ch.samplePointer + 1)
                ch.loopSamplePosition = Int(mem[ch.samplePointer])
                ch.samplePointer = u16(ch.samplePointer + 1)
            case 0x70 ... 0x7F:
                ch.ornamentPointer = mem.word(ornamentsPointers + (value - 0x70) * 2)
            case 0x80:
                ch.enabled = false
                quit = true
            case 0x81:
                ch.envelopeEnabled = false
            case 0x82 ... 0x8F:
                ch.envelopeEnabled = true
                regs.pointee.setEnvelopeRegister(value - 0x81)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                regs.pointee.envelope = mem.word(ch.addressInPattern)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x90:
                quit = true
            case 0x91 ... 0xA0:
                delay = value - 0x91
            case 0xA1 ... 0xB0:
                ch.volume = value - 0xA1
            default:
                ch.numberOfNotesToSkip = value - 0xB1
            }
            ch.addressInPattern = u16(ch.addressInPattern + 1)
            guardCount += 1
        } while !quit && guardCount < 65536
        ch.noteSkipCounter = s8(ch.numberOfNotesToSkip)
    }

    private func getRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        if ch.enabled {
            // An ornament is 64 offsets with no header, stepped in time with the sample.
            var j = u8(ch.note + Int(mem[ch.ornamentPointer + ch.positionInSample]))
            if j > 95 { j = 95 }
            let sample = ch.samplePointer + ch.positionInSample * 3
            var b = Int(mem[sample])
            ch.ton = ((b << 4) & 0xF00) + Int(mem[sample + 2])
            // round(x / 256); no product of a volume and a sample level lands on a half, so the rounding mode
            // does not come into it.
            ch.amplitude = ((ch.volume * 17 + (ch.volume > 7 ? 1 : 0)) * (b & 15) + 128) >> 8
            b = Int(mem[sample + 1])
            if b & 32 == 0 { ch.ton = u16(-ch.ton) }
            ch.ton = (ch.ton + noteTable[j] + (j == 46 ? 1 : 0)) & 0xFFF
            if ch.envelopeEnabled { ch.amplitude |= 16 }
            if s8(b) < 0 {
                tempMixer |= 64
            } else {
                regs.pointee.noise = b & 31
            }
            if b & 64 != 0 { tempMixer |= 8 }
            ch.positionInSample = u8(ch.positionInSample + 1)
            if ch.positionInSample == ch.sampleLength { ch.positionInSample = ch.loopSamplePosition }
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
                if mem[a.addressInPattern] == 255 {
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
