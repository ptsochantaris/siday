// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

import Foundation

// ASC Sound Master player, ported from Ay_Emul by Sergey Bulba (Players.pas, ASC_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.
//
// Two on-disk variants exist. ASC1 (Sound Master 1.x) has a loop position in byte 1; ASC0 (0.x) has no such
// byte, so everything after the delay sits one byte earlier. As in Ay_Emul's LoadTrackerModule, an ASC0
// module is converted to the ASC1 layout when loaded and the player only knows ASC1.

public final class ASCSource: AYFrameSource {
    private struct Channel {
        var initialPointInSample = 0, pointInSample = 0, loopPointInSample = 0
        var initialPointInOrnament = 0, pointInOrnament = 0, loopPointInOrnament = 0
        var addressInPattern = 0, ton = 0, tonDeviation = 0
        var note = 0, additionToNote = 0, numberOfNotesToSkip = 0, initialNoise = 0, currentNoise = 0
        var volume = 0, tonSlidingCounter = 0, amplitude = 0, amplitudeDelay = 0, amplitudeDelayCounter = 0
        var currentTonSliding = 0, substructionForTonSliding = 0
        var noteSkipCounter = 0, additionToAmplitude = 0
        var envelopeEnabled = false, soundEnabled = false, sampleFinished = false, breakSampleLoop = false
    }

    // Header layout (ASC1).
    private static let delayOffset = 0, loopingPosition = 1, patternsPointersOffset = 2, samplesPointersOffset = 4
    private static let ornamentsPointersOffset = 6, numberOfPositions = 8, positions = 9
    /// Title block a compiled module may carry between the position list and the patterns:
    /// this text, a 20-character title, " BY " and a 20-character author (63 bytes in all).
    private static let ascId = "ASM COMPILATION OF "

    private let mem: ModuleMemory
    private let patternsPointers: Int, samplesPointers: Int, ornamentsPointers: Int
    private var delay = 0, delayCounter = 0, currentPosition = 0
    private var a = Channel(), b = Channel(), c = Channel()
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0

    public init(_ data: Data) throws {
        guard data.count >= 10, data.count <= 65536 else { throw TuneError.malformed("not an ASC module") }
        // Nothing in the file names the variant, so it is told apart by structure, ASC1 first (FoundASC1, then
        // FoundASC0). Modules those tests turn down (recompiled ones with packed tables, files cut short) are
        // still taken if their header is at least self-consistent.
        let asc1 = ModuleMemory(data)
        let converted = Self.convertASC0(data)
        let asc0 = converted.map { ModuleMemory($0) }
        var detail = "Sound Master 1.x"
        if Self.found(asc1) {
            mem = asc1
        } else if let asc0, Self.found(asc0) {
            mem = asc0
            detail = "Sound Master 0.x"
        } else if Self.plausible(asc1) {
            mem = asc1
        } else if let asc0, Self.plausible(asc0) {
            mem = asc0
            detail = "Sound Master 0.x"
        } else {
            throw TuneError.malformed("ASC structure is not valid")
        }
        patternsPointers = mem.word(Self.patternsPointersOffset)
        samplesPointers = mem.word(Self.samplesPointersOffset)
        ornamentsPointers = mem.word(Self.ornamentsPointersOffset)

        var info = TuneInfo(format: "ASC")
        info.detail = detail
        let afterPositions = Self.positions + Int(mem[Self.numberOfPositions])
        if patternsPointers - afterPositions == 63 {
            info.title = mem.text(at: patternsPointers - 44, length: 20)
            info.author = mem.text(at: patternsPointers - 20, length: 20)
        } else if let marker = Self.marker(in: mem, from: afterPositions) {
            // Recompiled modules keep the same block elsewhere in the header, under a slightly different text.
            info.title = mem.text(at: marker, length: 20)
            info.author = mem.text(at: marker + 24, length: 20)
        }
        self.info = info
        restart()
    }

    /// LoadTrackerModule for ASC0: a zero loop position is inserted after the delay and the three pointers,
    /// which count from the start of the file, move up by one.
    private static func convertASC0(_ data: Data) -> Data? {
        guard data.count < 65535 else { return nil }
        var bytes = [UInt8](data)
        bytes.insert(0, at: 1)
        for offset in [patternsPointersOffset, samplesPointersOffset, ornamentsPointersOffset] {
            let pointer = (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8) + 1
            bytes[offset] = UInt8(pointer & 0xFF)
            bytes[offset + 1] = UInt8((pointer >> 8) & 0xFF)
        }
        return Data(bytes)
    }

    /// FoundASC1 without the timing run (FoundASC0 is the same test on the unconverted layout).
    private static func found(_ mem: ModuleMemory) -> Bool {
        let readen = mem.size
        let patterns = mem.word(patternsPointersOffset)
        let samples = mem.word(samplesPointersOffset)
        let ornaments = mem.word(ornamentsPointersOffset)
        let count = Int(mem[numberOfPositions])
        // The patterns follow the position list directly or after the title block.
        var j = patterns - count
        if j != 9, j != 72 { return false }
        if patterns > readen || samples > readen || ornaments > readen { return false }
        // 32 two-byte pointers come before the first sample and the first ornament.
        if mem.word(samples) != 0x40 || mem.word(ornaments) != 0x40 { return false }
        var j3 = 0
        for j1 in 0 ..< count where j3 < Int(mem[positions + j1]) {
            j3 = Int(mem[positions + j1])
        }
        if mem.word(patterns) != (j3 + 1) * 6 { return false }
        // The last ornament has to end inside the file.
        j = mem.word(ornaments + 0x40 - 2) + ornaments
        while j < readen, j < 65535, mem[j] & 0x40 == 0 {
            j += 2
        }
        return j <= 65534 && j < readen
    }

    /// The least a module needs to be played: a header that is consistent with itself and a first position
    /// that lies inside the file. Not from Ay_Emul.
    private static func plausible(_ mem: ModuleMemory) -> Bool {
        let patterns = mem.word(patternsPointersOffset)
        let samples = mem.word(samplesPointersOffset)
        let ornaments = mem.word(ornamentsPointersOffset)
        let count = Int(mem[numberOfPositions])
        guard count > 0, Int(mem[loopingPosition]) < count else { return false }
        guard patterns != samples, patterns != ornaments, samples != ornaments else { return false }
        for pointer in [patterns, samples, ornaments] where pointer < positions + count || pointer >= mem.size {
            return false
        }
        let row = patterns + 6 * Int(mem[positions])
        guard row + 6 <= mem.size else { return false }
        for channel in 0 ..< 3 where mem.word(row + channel * 2) + patterns >= mem.size {
            return false
        }
        return true
    }

    /// Address of the title in a title block that is not where a standard module has it.
    private static func marker(in mem: ModuleMemory, from start: Int) -> Int? {
        let text = Array("COMPILATION OF ".utf8)
        for at in start ..< start + 16 where (0 ..< text.count).allSatisfy({ mem[at + $0] == text[$0] }) {
            return at + text.count
        }
        return nil
    }

    public func restart() {
        loopCount = 0
        tempMixer = 0
        currentPosition = 0
        delayCounter = 1
        delay = Int(mem[Self.delayOffset])
        a = Channel(); b = Channel(); c = Channel()
        let row = patternsPointers + 6 * Int(mem[Self.positions])
        a.addressInPattern = u16(mem.word(row) + patternsPointers)
        b.addressInPattern = u16(mem.word(row + 2) + patternsPointers)
        c.addressInPattern = u16(mem.word(row + 4) + patternsPointers)
    }

    private func patternInterpreter(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        var deltaTon = 0
        var initializationOfOrnamentDisabled = false, initializationOfSampleDisabled = false
        ch.tonSlidingCounter = 0
        ch.amplitudeDelayCounter = 0
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        interpret: repeat {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0x00 ... 0x55:
                ch.note = value
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.currentNoise = ch.initialNoise
                if s8(ch.tonSlidingCounter) <= 0 { ch.currentTonSliding = 0 }
                if !initializationOfSampleDisabled {
                    ch.additionToAmplitude = 0
                    ch.tonDeviation = 0
                    ch.pointInSample = ch.initialPointInSample
                    ch.soundEnabled = true
                    ch.sampleFinished = false
                    ch.breakSampleLoop = false
                }
                if !initializationOfOrnamentDisabled {
                    ch.pointInOrnament = ch.initialPointInOrnament
                    ch.additionToNote = 0
                }
                if ch.envelopeEnabled {
                    // Only the low byte of the envelope period is ever written.
                    regs[0].envelope = (regs[0].envelope & 0xFF00) | Int(mem[ch.addressInPattern])
                    ch.addressInPattern = u16(ch.addressInPattern + 1)
                }
                break interpret
            case 0x56 ... 0x5D:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                break interpret
            case 0x5E:
                ch.breakSampleLoop = true
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                break interpret
            case 0x5F:
                ch.soundEnabled = false
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                break interpret
            case 0x60 ... 0x9F:
                ch.numberOfNotesToSkip = value - 0x60
            case 0xA0 ... 0xBF:
                ch.initialPointInSample = u16(mem.word((value - 0xA0) * 2 + samplesPointers) + samplesPointers)
            case 0xC0 ... 0xDF:
                ch.initialPointInOrnament = u16(mem.word((value - 0xC0) * 2 + ornamentsPointers) + ornamentsPointers)
            case 0xE0:
                ch.volume = 15
                ch.envelopeEnabled = true
            case 0xE1 ... 0xEF:
                ch.volume = value - 0xE0
                ch.envelopeEnabled = false
            case 0xF0:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.initialNoise = Int(mem[ch.addressInPattern])
            case 0xF1:
                initializationOfSampleDisabled = true
            case 0xF2:
                initializationOfOrnamentDisabled = true
            case 0xF3:
                initializationOfSampleDisabled = true
                initializationOfOrnamentDisabled = true
            case 0xF4:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                delay = Int(mem[ch.addressInPattern])
            case 0xF5:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.substructionForTonSliding = s16(-mem.signed(ch.addressInPattern) * 16)
                ch.tonSlidingCounter = 255
            case 0xF6:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.substructionForTonSliding = s16(mem.signed(ch.addressInPattern) * 16)
                ch.tonSlidingCounter = 255
            case 0xF7, 0xF9:
                // Slide to the note that follows, in as many ticks as the parameter says. 0xF7 starts from
                // wherever a slide in progress has got to and leaves the sample running.
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                if value == 0xF7 { initializationOfSampleDisabled = true }
                let next = Int(mem[ch.addressInPattern + 1])
                if next < 0x56 {
                    deltaTon = TrackerTables.ASM_Table[ch.note] - TrackerTables.ASM_Table[next]
                    if value == 0xF7 { deltaTon += ch.currentTonSliding / 16 }
                    deltaTon = s16(deltaTon)
                } else {
                    deltaTon = ch.currentTonSliding / 16
                }
                deltaTon = s16(deltaTon << 4)
                let steps = mem.signed(ch.addressInPattern)
                // The Pascal divides by the parameter unchecked; zero steps is taken as no slide here.
                if steps != 0 {
                    ch.substructionForTonSliding = s16(-deltaTon / steps)
                    ch.currentTonSliding = s16(deltaTon - deltaTon % steps)
                } else {
                    ch.substructionForTonSliding = 0
                    ch.currentTonSliding = 0
                }
                ch.tonSlidingCounter = u8(steps)
            case 0xF8:
                regs[0].setEnvelopeRegister(8)
            case 0xFA:
                regs[0].setEnvelopeRegister(10)
            case 0xFB:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                let parameter = Int(mem[ch.addressInPattern])
                if parameter & 32 == 0 {
                    ch.amplitudeDelay = u8(parameter << 3)
                    ch.amplitudeDelayCounter = ch.amplitudeDelay
                } else {
                    // Bit 0 of the result is the sign, bits 7-3 the magnitude.
                    ch.amplitudeDelay = u8((u8(parameter << 3) ^ 0xF8) + 9)
                    ch.amplitudeDelayCounter = ch.amplitudeDelay
                }
            case 0xFC:
                regs[0].setEnvelopeRegister(12)
            case 0xFE:
                regs[0].setEnvelopeRegister(14)
            default: break
            }
            ch.addressInPattern = u16(ch.addressInPattern + 1)
            guardCount += 1
        } while guardCount < 65536
        ch.noteSkipCounter = s8(ch.numberOfNotesToSkip)
    }

    private func getRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        if ch.sampleFinished || !ch.soundEnabled {
            ch.amplitude = 0
        } else {
            if ch.amplitudeDelayCounter != 0 {
                if ch.amplitudeDelayCounter >= 16 {
                    ch.amplitudeDelayCounter -= 8
                    if ch.additionToAmplitude < -15 {
                        ch.additionToAmplitude += 1
                    } else if ch.additionToAmplitude > 15 {
                        ch.additionToAmplitude -= 1
                    }
                } else {
                    if ch.amplitudeDelayCounter & 1 != 0 {
                        if ch.additionToAmplitude > -15 { ch.additionToAmplitude -= 1 }
                    } else if ch.additionToAmplitude < 15 {
                        ch.additionToAmplitude += 1
                    }
                    ch.amplitudeDelayCounter = ch.amplitudeDelay
                }
            }
            let b0 = Int(mem[ch.pointInSample])
            let b2 = Int(mem[ch.pointInSample + 2])
            if b0 & 128 != 0 { ch.loopPointInSample = ch.pointInSample }
            if b0 & 96 == 32 { ch.sampleFinished = true }
            ch.tonDeviation = u16(ch.tonDeviation + mem.signed(ch.pointInSample + 1))
            tempMixer = u8((b2 & 9) << 3 | tempMixer)
            let sampleSaysOKForEnvelope = b2 & 6 == 2
            if b2 & 6 == 4, ch.additionToAmplitude > -15 { ch.additionToAmplitude -= 1 }
            if b2 & 6 == 6, ch.additionToAmplitude < 15 { ch.additionToAmplitude += 1 }
            ch.amplitude = u8(u8(ch.additionToAmplitude) + (b2 >> 4))
            if s8(ch.amplitude) < 0 { ch.amplitude = 0 } else if ch.amplitude > 15 { ch.amplitude = 15 }
            ch.amplitude = (ch.amplitude * (ch.volume + 1)) >> 4
            // The low five bits are a signed step for the envelope period (when the sample plays through the
            // envelope with its noise off) or for the noise period.
            if sampleSaysOKForEnvelope, tempMixer & 64 != 0 {
                regs[0].envelope = (regs[0].envelope & 0xFF00) | u8(regs[0].envelope + s8(b0 << 3) / 8)
            } else {
                ch.currentNoise = u8(ch.currentNoise + s8(b0 << 3) / 8)
            }
            ch.pointInSample = u16(ch.pointInSample + 3)
            if b0 & 64 != 0 {
                if !ch.breakSampleLoop {
                    ch.pointInSample = ch.loopPointInSample
                } else if b0 & 32 != 0 {
                    ch.sampleFinished = true
                }
            }
            let o0 = Int(mem[ch.pointInOrnament])
            if o0 & 128 != 0 { ch.loopPointInOrnament = ch.pointInOrnament }
            ch.additionToNote = u8(ch.additionToNote + Int(mem[ch.pointInOrnament + 1]))
            ch.currentNoise = u8(ch.currentNoise + (-(o0 & 0x10) | o0))
            ch.pointInOrnament = u16(ch.pointInOrnament + 2)
            if o0 & 64 != 0 { ch.pointInOrnament = ch.loopPointInOrnament }
            if tempMixer & 64 == 0 {
                regs[0].noise = (u8(u16(ch.currentTonSliding) >> 8) + ch.currentNoise) & 0x1F
            }
            var j = s8(ch.note + ch.additionToNote)
            if j < 0 { j = 0 } else if j > 0x55 { j = 0x55 }
            ch.ton = (TrackerTables.ASM_Table[j] + ch.tonDeviation + u16(ch.currentTonSliding / 16)) & 0xFFF
            if ch.tonSlidingCounter != 0 {
                if s8(ch.tonSlidingCounter) > 0 { ch.tonSlidingCounter -= 1 }
                ch.currentTonSliding = s16(ch.currentTonSliding + ch.substructionForTonSliding)
            }
            if ch.envelopeEnabled, sampleSaysOKForEnvelope { ch.amplitude |= 0x10 }
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
                    if currentPosition >= Int(mem[Self.numberOfPositions]) {
                        currentPosition = Int(mem[Self.loopingPosition])
                        loopCount += 1
                    }
                    let row = patternsPointers + 6 * Int(mem[currentPosition + Self.positions])
                    a.addressInPattern = u16(mem.word(row) + patternsPointers)
                    b.addressInPattern = u16(mem.word(row + 2) + patternsPointers)
                    c.addressInPattern = u16(mem.word(row + 4) + patternsPointers)
                    a.initialNoise = 0
                    b.initialNoise = 0
                    c.initialNoise = 0
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
        regs[0].mixer = tempMixer
        regs[0].tonA = a.ton
        regs[0].tonB = b.ton
        regs[0].tonC = c.ton
        regs[0].amplA = a.amplitude
        regs[0].amplB = b.amplitude
        regs[0].amplC = c.amplitude
    }
}
