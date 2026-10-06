// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

import Foundation

// Pro Tracker 3.x / Vortex Tracker II player, ported from Ay_Emul by Sergey Bulba (Players.pas, PT3_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.

@inline(__always) func u8(_ x: Int) -> Int { x & 0xFF }
@inline(__always) func s8(_ x: Int) -> Int { Int(Int8(truncatingIfNeeded: x)) }
@inline(__always) func u16(_ x: Int) -> Int { x & 0xFFFF }
@inline(__always) func s16(_ x: Int) -> Int { Int(Int16(truncatingIfNeeded: x)) }

public final class PT3Source: AYFrameSource {
    private struct Channel {
        var addressInPattern = 0, ornamentPointer = 0, samplePointer = 0, ton = 0
        var loopOrnamentPosition = 0, ornamentLength = 0, positionInOrnament = 0
        var loopSamplePosition = 0, sampleLength = 0, positionInSample = 0
        var volume = 0, numberOfNotesToSkip = 0, note = 0, slideToNote = 0, amplitude = 0
        var envelopeEnabled = false, enabled = false, simpleGliss = false
        var currentAmplitudeSliding = 0, tonSlideCount = 0, currentOnOff = 0, onOffDelay = 0, offOnDelay = 0
        var tonSlideDelay = 0, currentTonSliding = 0, tonAccumulator = 0, tonSlideStep = 0, tonDelta = 0
        var noteSkipCounter = 0
        var currentNoiseSliding = 0, currentEnvelopeSliding = 0
    }

    private struct Chip {
        var envBase = 0 // 16-bit, hi/lo written separately
        var curEnvSlide = 0, envSlideAdd = 0
        var curEnvDelay = 0, envDelay = 0
        var noiseBase = 0, delay = 0, addToNoise = 0, delayCounter = 0, currentPosition = 0
        var a = Channel(), b = Channel(), c = Channel()
        /// 0x20 for an ordinary module; otherwise the pattern-mirroring value of a PT 3.7 TurboSound module.
        var ts = 0x20
    }

    // Header layout.
    private let tonTableId = 0x63, delayOffset = 0x64, numberOfPositions = 0x65, loopPosition = 0x66
    private let patternsPointer = 0x67, samplesPointers = 0x69, ornamentsPointers = 0xA9, positionList = 0xC9

    private let mem: ModuleMemory
    private let version: Int
    private var chips: [Chip]
    private let noteTable: [Int]
    private let volumeTable: [Int]
    public let chipCount: Int
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0
    private var addToEnv = 0

    public init(_ data: Data) throws {
        guard data.count > 0xC9 + 1, data.count <= 65536 else { throw TuneError.malformed("not a PT3 module") }
        mem = ModuleMemory(data)
        var v = 6
        let digit = Int(mem[13])
        if digit >= 0x30, digit <= 0x39 { v = digit - 0x30 }
        version = v

        // A PT 3.7+ module with a pattern count where a space would be is a six-channel TurboSound module:
        // the second chip plays the same module with the pattern list mirrored.
        let tsByte = Int(mem[98])
        chipCount = (v >= 7 && tsByte != 0x20) ? 2 : 1

        switch Int(mem[tonTableId]) {
        case 0: noteTable = v <= 3 ? TrackerTables.PT3NoteTable_PT_33_34r : TrackerTables.PT3NoteTable_PT_34_35
        case 1: noteTable = TrackerTables.PT3NoteTable_ST
        case 2: noteTable = v <= 3 ? TrackerTables.PT3NoteTable_ASM_34r : TrackerTables.PT3NoteTable_ASM_34_35
        default: noteTable = v <= 3 ? TrackerTables.PT3NoteTable_REAL_34r : TrackerTables.PT3NoteTable_REAL_34_35
        }
        volumeTable = v <= 4 ? TrackerTables.PT3VolumeTable_33_34 : TrackerTables.PT3VolumeTable_35

        // The signature is often junk, so validity is judged by structure: the pattern table follows the header.
        let patterns = mem.word(patternsPointer)
        guard patterns > positionList, patterns < data.count else {
            throw TuneError.malformed("PT3 structure is not valid")
        }

        var info = TuneInfo(format: chipCount == 2 ? "PT3 TS" : "PT3")
        info.title = mem.text(at: 0x1E, length: 32)
        info.author = mem.text(at: 0x42, length: 32)
        let header = mem.text(at: 0, length: 0x1E)
        info.detail = header.hasPrefix("Vortex") ? "Vortex Tracker II" : (header.hasPrefix("ProTracker 3.") ? "Pro Tracker 3.\(v)" : "")
        self.info = info

        chips = [Chip(), Chip()]
        restart()
    }

    public func restart() {
        loopCount = 0
        for n in 0 ..< 2 {
            var chip = Chip()
            chip.ts = (n == 1 && chipCount == 2) ? Int(mem[98]) : 0x20
            chip.delayCounter = 1
            chip.delay = Int(mem[delayOffset])
            var i = Int(mem[positionList])
            if chip.ts != 0x20 { i = chip.ts * 3 - 3 - i }
            let base = mem.word(patternsPointer)
            var a = Channel()
            a.ornamentPointer = mem.word(ornamentsPointers)
            a.loopOrnamentPosition = Int(mem[a.ornamentPointer])
            a.ornamentPointer = u16(a.ornamentPointer + 1)
            a.ornamentLength = Int(mem[a.ornamentPointer])
            a.ornamentPointer = u16(a.ornamentPointer + 1)
            a.samplePointer = mem.word(samplesPointers + 2)
            a.loopSamplePosition = Int(mem[a.samplePointer])
            a.samplePointer = u16(a.samplePointer + 1)
            a.sampleLength = Int(mem[a.samplePointer])
            a.samplePointer = u16(a.samplePointer + 1)
            a.volume = 15
            a.noteSkipCounter = 1
            chip.a = a; chip.b = a; chip.c = a
            chip.a.addressInPattern = mem.word(base + i * 2)
            chip.b.addressInPattern = mem.word(base + i * 2 + 2)
            chip.c.addressInPattern = mem.word(base + i * 2 + 4)
            chips[n] = chip
        }
    }

    @inline(__always) private func noteFreq(_ j: Int) -> Int {
        noteTable[min(max(j, 0), 95)]
    }

    private func patternInterpreter(_ ch: inout Channel, _ chipIndex: Int, _ regs: UnsafeMutablePointer<AYRegs>) {
        let prNote = ch.note
        let prSliding = ch.currentTonSliding
        var quit = false
        var counter = 0
        var flag9 = 0, flag8 = 0, flag5 = 0, flag4 = 0, flag3 = 0, flag2 = 0, flag1 = 0
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        repeat {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0xF0 ... 0xFF:
                ch.ornamentPointer = mem.word(ornamentsPointers + (value - 0xF0) * 2)
                ch.loopOrnamentPosition = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.ornamentLength = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                setSample(&ch, Int(mem[ch.addressInPattern]) / 2)
                ch.envelopeEnabled = false
                ch.positionInOrnament = 0
            case 0xD1 ... 0xEF:
                setSample(&ch, value - 0xD0)
            case 0xD0:
                quit = true
            case 0xC1 ... 0xCF:
                ch.volume = value - 0xC0
            case 0xC0:
                ch.positionInSample = 0
                ch.currentAmplitudeSliding = 0
                ch.currentNoiseSliding = 0
                ch.currentEnvelopeSliding = 0
                ch.positionInOrnament = 0
                ch.tonSlideCount = 0
                ch.currentTonSliding = 0
                ch.tonAccumulator = 0
                ch.currentOnOff = 0
                ch.enabled = false
                quit = true
            case 0xB2 ... 0xBF:
                ch.envelopeEnabled = true
                regs[chipIndex].setEnvelopeRegister(value - 0xB1)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                let hi = Int(mem[ch.addressInPattern])
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                let lo = Int(mem[ch.addressInPattern])
                chips[chipIndex].envBase = hi << 8 | lo
                ch.positionInOrnament = 0
                chips[chipIndex].curEnvSlide = 0
                chips[chipIndex].curEnvDelay = 0
            case 0xB1:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.numberOfNotesToSkip = Int(mem[ch.addressInPattern])
            case 0xB0:
                ch.envelopeEnabled = false
                ch.positionInOrnament = 0
            case 0x50 ... 0xAF:
                ch.note = value - 0x50
                ch.positionInSample = 0
                ch.currentAmplitudeSliding = 0
                ch.currentNoiseSliding = 0
                ch.currentEnvelopeSliding = 0
                ch.positionInOrnament = 0
                ch.tonSlideCount = 0
                ch.currentTonSliding = 0
                ch.tonAccumulator = 0
                ch.currentOnOff = 0
                ch.enabled = true
                quit = true
            case 0x40 ... 0x4F:
                ch.ornamentPointer = mem.word(ornamentsPointers + (value - 0x40) * 2)
                ch.loopOrnamentPosition = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.ornamentLength = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.positionInOrnament = 0
            case 0x20 ... 0x3F:
                chips[chipIndex].noiseBase = value - 0x20
            case 0x10 ... 0x1F:
                if value == 0x10 {
                    ch.envelopeEnabled = false
                } else {
                    regs[chipIndex].setEnvelopeRegister(value - 0x10)
                    ch.addressInPattern = u16(ch.addressInPattern + 1)
                    let hi = Int(mem[ch.addressInPattern])
                    ch.addressInPattern = u16(ch.addressInPattern + 1)
                    let lo = Int(mem[ch.addressInPattern])
                    chips[chipIndex].envBase = hi << 8 | lo
                    ch.envelopeEnabled = true
                    chips[chipIndex].curEnvSlide = 0
                    chips[chipIndex].curEnvDelay = 0
                }
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                setSample(&ch, Int(mem[ch.addressInPattern]) / 2)
                ch.positionInOrnament = 0
            case 0x09: counter += 1; flag9 = counter
            case 0x08: counter += 1; flag8 = counter
            case 0x05: counter += 1; flag5 = counter
            case 0x04: counter += 1; flag4 = counter
            case 0x03: counter += 1; flag3 = counter
            case 0x02: counter += 1; flag2 = counter
            case 0x01: counter += 1; flag1 = counter
            default: break
            }
            ch.addressInPattern = u16(ch.addressInPattern + 1)
            guardCount += 1
        } while !quit && guardCount < 65536

        while counter > 0 {
            if counter == flag1 {
                ch.tonSlideDelay = Int(mem[ch.addressInPattern])
                ch.tonSlideCount = ch.tonSlideDelay
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.tonSlideStep = s16(mem.word(ch.addressInPattern))
                ch.addressInPattern = u16(ch.addressInPattern + 2)
                ch.simpleGliss = true
                ch.currentOnOff = 0
                if ch.tonSlideCount == 0, version >= 7 { ch.tonSlideCount += 1 }
            } else if counter == flag2 {
                ch.simpleGliss = false
                ch.currentOnOff = 0
                ch.tonSlideDelay = Int(mem[ch.addressInPattern])
                ch.tonSlideCount = ch.tonSlideDelay
                ch.addressInPattern = u16(ch.addressInPattern + 3)
                ch.tonSlideStep = s16(abs(s16(mem.word(ch.addressInPattern))))
                ch.addressInPattern = u16(ch.addressInPattern + 2)
                ch.tonDelta = s16(noteFreq(ch.note) - noteFreq(prNote))
                ch.slideToNote = ch.note
                ch.note = prNote
                if version >= 6 { ch.currentTonSliding = prSliding }
                if ch.tonDelta - ch.currentTonSliding < 0 { ch.tonSlideStep = s16(-ch.tonSlideStep) }
            } else if counter == flag3 {
                ch.positionInSample = Int(mem[ch.addressInPattern])
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            } else if counter == flag4 {
                ch.positionInOrnament = Int(mem[ch.addressInPattern])
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            } else if counter == flag5 {
                ch.onOffDelay = Int(mem[ch.addressInPattern])
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.offOnDelay = Int(mem[ch.addressInPattern])
                ch.currentOnOff = ch.onOffDelay
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.tonSlideCount = 0
                ch.currentTonSliding = 0
            } else if counter == flag8 {
                chips[chipIndex].envDelay = s8(Int(mem[ch.addressInPattern]))
                chips[chipIndex].curEnvDelay = chips[chipIndex].envDelay
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                chips[chipIndex].envSlideAdd = s16(mem.word(ch.addressInPattern))
                ch.addressInPattern = u16(ch.addressInPattern + 2)
            } else if counter == flag9 {
                let b = Int(mem[ch.addressInPattern])
                chips[chipIndex].delay = b
                if chipCount == 2 {
                    chips[0].delay = b
                    chips[0].delayCounter = b
                    chips[1].delay = b
                }
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            }
            counter -= 1
        }
        ch.noteSkipCounter = s8(ch.numberOfNotesToSkip)
    }

    @inline(__always) private func setSample(_ ch: inout Channel, _ index: Int) {
        ch.samplePointer = mem.word(samplesPointers + index * 2)
        ch.loopSamplePosition = Int(mem[ch.samplePointer])
        ch.samplePointer = u16(ch.samplePointer + 1)
        ch.sampleLength = Int(mem[ch.samplePointer])
        ch.samplePointer = u16(ch.samplePointer + 1)
    }

    private func changeRegisters(_ ch: inout Channel, _ chipIndex: Int) {
        if ch.enabled {
            let sample = ch.samplePointer + ch.positionInSample * 4
            ch.ton = u16(mem.word(sample + 2) + ch.tonAccumulator)
            let b0 = Int(mem[sample])
            let b1 = Int(mem[sample + 1])
            if b1 & 0x40 != 0 { ch.tonAccumulator = s16(ch.ton) }
            var j = u8(ch.note + Int(mem[ch.ornamentPointer + ch.positionInOrnament]))
            if s8(j) < 0 { j = 0 } else if j > 95 { j = 95 }
            let w = noteTable[j]
            ch.ton = (ch.ton + ch.currentTonSliding + w) & 0xFFF
            if ch.tonSlideCount > 0 {
                ch.tonSlideCount -= 1
                if ch.tonSlideCount == 0 {
                    ch.currentTonSliding = s16(ch.currentTonSliding + ch.tonSlideStep)
                    ch.tonSlideCount = ch.tonSlideDelay
                    if !ch.simpleGliss {
                        if (ch.tonSlideStep < 0 && ch.currentTonSliding <= ch.tonDelta)
                            || (ch.tonSlideStep >= 0 && ch.currentTonSliding >= ch.tonDelta) {
                            ch.note = ch.slideToNote
                            ch.tonSlideCount = 0
                            ch.currentTonSliding = 0
                        }
                    }
                }
            }
            ch.amplitude = b1 & 0x0F
            if b0 & 0x80 != 0 {
                if b0 & 0x40 != 0 {
                    if ch.currentAmplitudeSliding < 15 { ch.currentAmplitudeSliding += 1 }
                } else if ch.currentAmplitudeSliding > -15 {
                    ch.currentAmplitudeSliding -= 1
                }
            }
            ch.amplitude = u8(ch.amplitude + ch.currentAmplitudeSliding)
            if s8(ch.amplitude) < 0 { ch.amplitude = 0 } else if ch.amplitude > 15 { ch.amplitude = 15 }
            ch.amplitude = volumeTable[ch.volume * 16 + ch.amplitude]
            if b0 & 1 == 0, ch.envelopeEnabled { ch.amplitude |= 16 }
            if b1 & 0x80 != 0 {
                if b0 & 0x20 != 0 {
                    j = u8(((b0 >> 1) | 0xF0) + ch.currentEnvelopeSliding)
                } else {
                    j = u8(((b0 >> 1) & 0x0F) + ch.currentEnvelopeSliding)
                }
                if b1 & 0x20 != 0 { ch.currentEnvelopeSliding = j }
                addToEnv = s8(addToEnv + j)
            } else {
                chips[chipIndex].addToNoise = u8((b0 >> 1) + ch.currentNoiseSliding)
                if b1 & 0x20 != 0 { ch.currentNoiseSliding = chips[chipIndex].addToNoise }
            }
            tempMixer = u8(((b1 >> 1) & 0x48) | tempMixer)
            ch.positionInSample = u8(ch.positionInSample + 1)
            if ch.positionInSample >= ch.sampleLength { ch.positionInSample = ch.loopSamplePosition }
            ch.positionInOrnament = u8(ch.positionInOrnament + 1)
            if ch.positionInOrnament >= ch.ornamentLength { ch.positionInOrnament = ch.loopOrnamentPosition }
        } else {
            ch.amplitude = 0
        }
        tempMixer >>= 1
        if ch.currentOnOff > 0 {
            ch.currentOnOff -= 1
            if ch.currentOnOff == 0 {
                ch.enabled.toggle()
                ch.currentOnOff = ch.enabled ? ch.onOffDelay : ch.offOnDelay
            }
        }
    }

    private func tickChip(_ n: Int, _ regs: UnsafeMutablePointer<AYRegs>) {
        chips[n].delayCounter = u8(chips[n].delayCounter - 1)
        if chips[n].delayCounter == 0 {
            var a = chips[n].a
            a.noteSkipCounter = s8(a.noteSkipCounter - 1)
            if a.noteSkipCounter == 0 {
                if mem[a.addressInPattern] == 0 {
                    var position = u8(chips[n].currentPosition + 1)
                    if position == Int(mem[numberOfPositions]) {
                        position = Int(mem[loopPosition])
                        if n == 0 { loopCount += 1 }
                    }
                    chips[n].currentPosition = position
                    var i = Int(mem[positionList + position])
                    if chips[n].ts != 0x20 { i = chips[n].ts * 3 - 3 - i }
                    let base = mem.word(patternsPointer)
                    a.addressInPattern = mem.word(base + i * 2)
                    chips[n].b.addressInPattern = mem.word(base + i * 2 + 2)
                    chips[n].c.addressInPattern = mem.word(base + i * 2 + 4)
                    chips[n].noiseBase = 0
                }
                patternInterpreter(&a, n, regs)
            }
            chips[n].a = a
            var b = chips[n].b
            b.noteSkipCounter = s8(b.noteSkipCounter - 1)
            if b.noteSkipCounter == 0 { patternInterpreter(&b, n, regs) }
            chips[n].b = b
            var c = chips[n].c
            c.noteSkipCounter = s8(c.noteSkipCounter - 1)
            if c.noteSkipCounter == 0 { patternInterpreter(&c, n, regs) }
            chips[n].c = c
            chips[n].delayCounter = chips[n].delay
        }
        addToEnv = 0
        tempMixer = 0
        var a = chips[n].a; changeRegisters(&a, n); chips[n].a = a
        var b = chips[n].b; changeRegisters(&b, n); chips[n].b = b
        var c = chips[n].c; changeRegisters(&c, n); chips[n].c = c
        regs[n].mixer = tempMixer
        regs[n].tonA = a.ton
        regs[n].tonB = b.ton
        regs[n].tonC = c.ton
        regs[n].amplA = a.amplitude
        regs[n].amplB = b.amplitude
        regs[n].amplC = c.amplitude
        regs[n].noise = (chips[n].noiseBase + chips[n].addToNoise) & 31
        regs[n].envelope = u16(s16(chips[n].envBase) + addToEnv + chips[n].curEnvSlide)
        if chips[n].curEnvDelay > 0 {
            chips[n].curEnvDelay -= 1
            if chips[n].curEnvDelay == 0 {
                chips[n].curEnvDelay = chips[n].envDelay
                chips[n].curEnvSlide = s16(chips[n].curEnvSlide + chips[n].envSlideAdd)
            }
        }
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        tickChip(0, regs)
        if chipCount == 2 { tickChip(1, regs) }
    }
}
