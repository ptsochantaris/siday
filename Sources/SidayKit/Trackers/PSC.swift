// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

import Foundation

// Pro Sound Creator player, ported from Ay_Emul by Sergey Bulba (Players.pas, PSC_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.
//
// Modules compiled by PSC 1.00-1.03 store ornament and sample offsets from the start of the file; later
// ones store ornament offsets from the ornament table and sample offsets from the sample table (0x4C).

public final class PSCSource: AYFrameSource {
    private struct Channel {
        var addressInPattern = 0, ornamentPointer = 0, samplePointer = 0, ton = 0
        var currentTonSliding = 0, tonAccumulator = 0, additionToTon = 0
        var initialVolume = 0, noteSkipCounter = 0
        var note = 0, volume = 0, amplitude = 0
        var volumeCounter = 0, volumeCounter1 = 0, volumeCounterInit = 0, noiseAccumulator = 0
        var positionInSample = 0, loopSamplePosition = 0, positionInOrnament = 0, loopOrnamentPosition = 0
        var enabled = false, ornamentEnabled = false, envelopeEnabled = false, gliss = false
        var tonSlideEnabled = false, breakSampleLoop = false, breakOrnamentLoop = false, volumeInc = false
    }

    // Header layout: 69 characters of text ("PSC V1.0x COMPILATION OF <title> BY <author>"), then pointers.
    private static let patternsPointerOffset = 0x47, delayOffset = 0x49, ornamentsPointerOffset = 0x4A
    private static let samplesPointers = 0x4C

    private let mem: ModuleMemory
    private let version: Int
    private let ornamentsPointer: Int
    // All five are 16-bit in the Pascal, the delays included.
    private var delay = 0, delayCounter = 0, linesCounter = 0, noiseBase = 0, positionsPointer = 0
    private var a = Channel(), b = Channel(), c = Channel()
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0

    public init(_ data: Data) throws {
        guard data.count >= Self.samplesPointers + 2, data.count <= 65536 else { throw TuneError.malformed("not a PSC module") }
        let mem = ModuleMemory(data)
        self.mem = mem
        // The last digit of "PSC V1.0x" is the compiler version. The text is not always there, and what the
        // player needs to know is how offsets are stored, so the structure decides where it can (FoundPSC,
        // new layout tried first) and the digit is only believed if it agrees.
        var v = 7
        let digit = Int(mem[8])
        if digit >= 0x30, digit <= 0x39 { v = digit - 0x30 }
        if Self.found(mem, psc100: false) {
            if v <= 3 { v = 7 }
        } else if Self.found(mem, psc100: true) {
            if v > 3 { v = 0 }
        } else {
            // Neither fits: take the module if its first position at least lies inside the file.
            let patterns = mem.word(Self.patternsPointerOffset)
            guard patterns + 8 <= mem.size, mem[patterns + 1] != 255, mem.word(Self.ornamentsPointerOffset) < mem.size,
                  (1 ... 3).allSatisfy({ mem.word(patterns + $0 * 2) < mem.size })
            else {
                throw TuneError.malformed("PSC structure is not valid")
            }
        }
        version = v
        ornamentsPointer = mem.word(Self.ornamentsPointerOffset)

        var info = TuneInfo(format: "PSC")
        info.title = mem.text(at: 0x19, length: 20)
        info.author = mem.text(at: 0x31, length: 20)
        info.detail = "Pro Sound Creator 1.0\(v)"
        self.info = info
        restart()
    }

    /// FoundPSC without the timing run. `psc100` asks for the layout of the early compilers.
    private static func found(_ mem: ModuleMemory, psc100: Bool) -> Bool {
        let readen = mem.size
        let ornaments = mem.word(ornamentsPointerOffset)
        let patterns = mem.word(patternsPointerOffset)
        if readen < 0x4C + 2 { return false }
        if ornaments >= readen || ornaments < 0x4C + 2 || ornaments > 64 + 0x4C || ornaments % 2 != 0 { return false }
        let samBase = psc100 ? 0 : 0x4C
        var j = samBase + mem.word(samplesPointers)
        // The samples come straight after the ornament offsets, and there are no more than 32 of those.
        if j > ornaments + 64 { return false }
        if j + 5 > readen { return false }
        var ornFirst = mem.word(ornaments)
        if !psc100 { ornFirst += ornaments }
        if ornFirst > 65535 || ornFirst >= readen { return false }
        // The last sample ends where the first ornament begins.
        var j2 = mem.word(ornaments - 2) + samBase
        if j2 > 65534 - 5 || j2 + 5 > readen { return false }
        if ornFirst - j2 < 8 { return false }
        if (ornFirst - j2) % 6 != 2 { return false }
        // The first sample ends where the second begins (or the first ornament, if it is the only one).
        var j1 = mem.word(samplesPointers) + samBase + 4
        while j1 < 65536, j1 <= readen, mem[j1] & 32 != 0 {
            j1 += 6
        }
        if j1 > 65534 || j1 > readen { return false }
        if ornaments - 0x4C - 2 > 0 {
            if j1 + 3 != mem.word(samplesPointers + 2) + samBase { return false }
        } else if j1 + 4 != ornFirst {
            return false
        }
        // Every position points at channel data between the ornaments and the position list.
        j = patterns + 11
        if j > 65535 || j > readen { return false }
        j -= 10
        if mem[j] == 255 { return false }
        j1 = 0
        while true {
            for channel in 0 ..< 3 {
                j2 = mem.word(j + 1 + channel * 2)
                if j2 <= ornFirst || j2 >= patterns { return false }
            }
            j += 8
            j1 += 1
            if mem[j] == 255 {
                // A loop to a position that does not exist.
                if Int(mem[j - 1]) >= j1 { return false }
                break
            }
            if j > 65532 || j + 2 > readen { return false }
        }
        return true
    }

    public func restart() {
        loopCount = 0
        tempMixer = 0
        delayCounter = 1
        delay = Int(mem[Self.delayOffset])
        positionsPointer = mem.word(Self.patternsPointerOffset)
        linesCounter = 1
        noiseBase = 0
        // Until a pattern chooses otherwise every channel has sample 0 and ornament 0. Ay_Emul works these
        // two out the new way whatever the version (Players.pas 3530-3534), which in a 1.00-1.03 module
        // points a note played before the channel has chosen its own at the wrong data. This is a deliberate
        // departure: the bases follow the module's version, as they do everywhere else in the player.
        a = Channel()
        a.samplePointer = u16(mem.word(Self.samplesPointers) + (version > 3 ? 0x4C : 0))
        a.ornamentPointer = u16(mem.word(ornamentsPointer) + (version > 3 ? ornamentsPointer : 0))
        a.noteSkipCounter = 1
        b = a
        c = a
    }

    /// ASM_Table as the Pascal indexes it. A pattern can hold note 0x56, one past the end of the table,
    /// which in Ay_Emul reads the first entry of the table declared after it (ST_Table).
    @inline(__always) private func asmTable(_ j: Int) -> Int {
        j < 0x56 ? TrackerTables.ASM_Table[j] : TrackerTables.ST_Table[j - 0x56]
    }

    private func patternInterpreter(_ ch: inout Channel, isB: Bool, _ regs: UnsafeMutablePointer<AYRegs>) {
        var quit = false
        var b1b = false, b2b = false, b3b = false, b4b = false, b5b = false, b6b = false, b7b = false
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        repeat {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0xC0 ... 0xFF:
                ch.noteSkipCounter = value - 0xBF
                quit = true
            case 0xA0 ... 0xBF:
                ch.ornamentPointer = mem.word(ornamentsPointer + (value - 0xA0) * 2)
                if version > 3 { ch.ornamentPointer = u16(ch.ornamentPointer + ornamentsPointer) }
            case 0x7E ... 0x9F:
                if value >= 0x80 {
                    ch.samplePointer = mem.word(Self.samplesPointers + (value - 0x80) * 2)
                    if version > 3 { ch.samplePointer = u16(ch.samplePointer + 0x4C) }
                }
            case 0x6B:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.additionToTon = Int(mem[ch.addressInPattern])
                b5b = true
            case 0x6C:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.additionToTon = -mem.signed(ch.addressInPattern)
                b5b = true
            case 0x6D:
                b4b = true
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.additionToTon = Int(mem[ch.addressInPattern])
            case 0x6E:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                delay = Int(mem[ch.addressInPattern])
            case 0x6F:
                b1b = true
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x70:
                b3b = true
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.volumeCounter1 = Int(mem[ch.addressInPattern])
            case 0x71:
                ch.breakOrnamentLoop = true
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x7A:
                // Envelope shape and period; only channel B's copy is acted on, and only there is it four bytes long.
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                if isB {
                    regs[0].setEnvelopeRegister(Int(mem[ch.addressInPattern]) & 15)
                    regs[0].envelope = mem.word(ch.addressInPattern + 1)
                    ch.addressInPattern = u16(ch.addressInPattern + 2)
                }
            case 0x7B:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                if isB { noiseBase = Int(mem[ch.addressInPattern]) }
            case 0x7C:
                b1b = false
                b2b = true
                b3b = false
                b4b = false
                b5b = false
                b6b = false
                b7b = false
            case 0x7D:
                ch.breakSampleLoop = true
            case 0x58 ... 0x66:
                ch.initialVolume = value - 0x57
                ch.envelopeEnabled = false
                b6b = true
            case 0x57:
                ch.initialVolume = 0xF
                ch.envelopeEnabled = true
                b6b = true
            case 0x00 ... 0x56:
                ch.note = value
                b6b = true
                b7b = true
            default:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            }
            ch.addressInPattern = u16(ch.addressInPattern + 1)
            guardCount += 1
        } while !quit && guardCount < 65536

        if b7b {
            ch.breakOrnamentLoop = false
            ch.ornamentEnabled = true
            ch.enabled = true
            ch.breakSampleLoop = false
            ch.tonSlideEnabled = false
            ch.tonAccumulator = 0
            ch.currentTonSliding = 0
            ch.noiseAccumulator = 0
            ch.volumeCounter = 0
            ch.positionInSample = 0
            ch.positionInOrnament = 0
        }
        if b6b { ch.volume = ch.initialVolume }
        if b5b {
            ch.gliss = false
            ch.tonSlideEnabled = true
        }
        if b4b {
            ch.currentTonSliding = s16(ch.ton - asmTable(ch.note))
            ch.gliss = true
            if ch.currentTonSliding >= 0 { ch.additionToTon = -ch.additionToTon }
            ch.tonSlideEnabled = true
        }
        if b3b {
            ch.volumeCounter = ch.volumeCounter1
            ch.volumeInc = true
            if ch.volumeCounter & 0x40 != 0 {
                ch.volumeCounter = u8(-s8(ch.volumeCounter | 128))
                ch.volumeInc = false
            }
            ch.volumeCounterInit = ch.volumeCounter
        }
        if b2b {
            ch.breakOrnamentLoop = false
            ch.ornamentEnabled = false
            ch.enabled = false
            ch.breakSampleLoop = false
            ch.tonSlideEnabled = false
        }
        if b1b { ch.ornamentEnabled = false }
    }

    private func getRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        if ch.enabled {
            var j = ch.note
            if ch.ornamentEnabled {
                let b = Int(mem[ch.ornamentPointer + ch.positionInOrnament * 2])
                ch.noiseAccumulator = u8(ch.noiseAccumulator + b)
                j = u8(j + Int(mem[ch.ornamentPointer + ch.positionInOrnament * 2 + 1]))
                if s8(j) < 0 { j = u8(j + 0x56) }
                if j > 0x55 { j = u8(j - 0x56) }
                if j > 0x55 { j = 0x55 }
                if b & 128 == 0 { ch.loopOrnamentPosition = ch.positionInOrnament }
                if b & 64 == 0 {
                    if !ch.breakOrnamentLoop {
                        ch.positionInOrnament = ch.loopOrnamentPosition
                    } else {
                        ch.breakOrnamentLoop = false
                        if b & 32 == 0 { ch.ornamentEnabled = false }
                        ch.positionInOrnament = u8(ch.positionInOrnament + 1)
                    }
                } else {
                    if b & 32 == 0 { ch.ornamentEnabled = false }
                    ch.positionInOrnament = u8(ch.positionInOrnament + 1)
                }
            }
            ch.note = j
            let sample = ch.samplePointer + ch.positionInSample * 6
            ch.ton = mem.word(sample)
            ch.tonAccumulator = s16(ch.tonAccumulator + ch.ton)
            ch.ton = u16(asmTable(j) + ch.tonAccumulator)
            if ch.tonSlideEnabled {
                ch.currentTonSliding = s16(ch.currentTonSliding + ch.additionToTon)
                if ch.gliss, (ch.currentTonSliding < 0 && ch.additionToTon <= 0)
                    || (ch.currentTonSliding >= 0 && ch.additionToTon >= 0) {
                    ch.tonSlideEnabled = false
                }
                ch.ton = u16(ch.ton + ch.currentTonSliding)
            }
            ch.ton &= 0xFFF
            let b = Int(mem[sample + 4])
            tempMixer |= (b & 9) << 3
            j = 0
            if b & 2 != 0 { j = u8(j + 1) }
            if b & 4 != 0 { j = u8(j - 1) }
            if ch.volumeCounter > 0 {
                ch.volumeCounter -= 1
                if ch.volumeCounter == 0 {
                    if ch.volumeInc { j = u8(j + 1) } else { j = u8(j - 1) }
                    ch.volumeCounter = ch.volumeCounterInit
                }
            }
            ch.volume = u8(ch.volume + j)
            if s8(ch.volume) < 0 { ch.volume = 0 } else if ch.volume > 15 { ch.volume = 15 }
            ch.amplitude = ((ch.volume + 1) * (Int(mem[sample + 3]) & 15)) >> 4
            if ch.envelopeEnabled, b & 16 == 0 { ch.amplitude |= 16 }
            // Byte 2 is a step for the envelope period when the sample plays through the envelope with its
            // noise off, otherwise for the noise period.
            if ch.amplitude & 16 != 0, b & 8 != 0 {
                regs[0].envelope = u16(regs[0].envelope + mem.signed(sample + 2))
            } else {
                ch.noiseAccumulator = u8(ch.noiseAccumulator + Int(mem[sample + 2]))
                if b & 8 == 0 { regs[0].noise = ch.noiseAccumulator & 31 }
            }
            if b & 128 == 0 { ch.loopSamplePosition = ch.positionInSample }
            if b & 64 == 0 {
                if !ch.breakSampleLoop {
                    ch.positionInSample = ch.loopSamplePosition
                } else {
                    ch.breakSampleLoop = false
                    if b & 32 == 0 { ch.enabled = false }
                    ch.positionInSample = u8(ch.positionInSample + 1)
                }
            } else {
                if b & 32 == 0 { ch.enabled = false }
                ch.positionInSample = u8(ch.positionInSample + 1)
            }
        } else {
            ch.amplitude = 0
        }
        tempMixer >>= 1
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        delayCounter = u16(delayCounter - 1)
        if delayCounter == 0 {
            linesCounter = u16(linesCounter - 1)
            if linesCounter == 0 {
                // Each position is eight bytes: a number, the line count and three channel addresses.
                // A line count of 255 ends the list and is followed by the address of the position to loop to.
                if mem[positionsPointer + 1] == 255 {
                    positionsPointer = mem.word(positionsPointer + 2)
                    loopCount += 1
                }
                linesCounter = Int(mem[positionsPointer + 1])
                a.addressInPattern = mem.word(positionsPointer + 2)
                b.addressInPattern = mem.word(positionsPointer + 4)
                c.addressInPattern = mem.word(positionsPointer + 6)
                positionsPointer = u16(positionsPointer + 8)
                a.noteSkipCounter = 1
                b.noteSkipCounter = 1
                c.noteSkipCounter = 1
            }
            a.noteSkipCounter = s8(a.noteSkipCounter - 1)
            if a.noteSkipCounter == 0 { patternInterpreter(&a, isB: false, regs) }
            b.noteSkipCounter = s8(b.noteSkipCounter - 1)
            if b.noteSkipCounter == 0 { patternInterpreter(&b, isB: true, regs) }
            c.noteSkipCounter = s8(c.noteSkipCounter - 1)
            if c.noteSkipCounter == 0 { patternInterpreter(&c, isB: false, regs) }
            a.noiseAccumulator = u8(a.noiseAccumulator + noiseBase)
            b.noiseAccumulator = u8(b.noiseAccumulator + noiseBase)
            c.noiseAccumulator = u8(c.noiseAccumulator + noiseBase)
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
