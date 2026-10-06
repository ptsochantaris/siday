// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

import Foundation

// SQ-Tracker player, ported from Ay_Emul by Sergey Bulba (Players.pas, SQT_Get_Registers, with the load-time
// relocation from LoadTrackerModule and the structural checks from FoundSQT). Field names and control flow
// follow the Pascal so the two can be read side by side. The Pascal relies on 8- and 16-bit variables wrapping;
// here every field is an Int and the wrap is applied explicitly.

public final class SQTSource: AYFrameSource {
    // A class, not a struct: the Pascal passes a channel by reference to the pattern interpreter, which can
    // also reach the same channel through the global A/B/C records (the "all channels" volume commands).
    private final class Channel {
        var addressInPattern = 0, samplePointer = 0, pointInSample = 0, ornamentPointer = 0, pointInOrnament = 0
        var ton = 0, ix27 = 0
        var volume = 0, amplitude = 0, note = 0, ix21 = 0
        var tonSlideStep = 0, currentTonSliding = 0
        var sampleTikCounter = 0, ornamentTikCounter = 0, transposit = 0
        var enabled = false, envelopeEnabled = false, ornamentEnabled = false, gliss = false
        var mixNoise = false, mixTon = false
        var b4ix0 = false, b6ix0 = false, b7ix0 = false
    }

    // Header layout: five pointers after the size word. A module is compiled for the address it was saved
    // at, so they (and the pointer tables they lead to) are absolute until the loader rebases them.
    private let sqtSamplesPointer = 2, sqtOrnamentsPointer = 4, sqtPatternsPointer = 6
    private let sqtPositionsPointer = 8, sqtLoopPointer = 10

    private let mem: ModuleMemory
    private var a = Channel(), b = Channel(), c = Channel()
    private var delay = 0, delayCounter = 0, linesCounter = 0, positionsPointer = 0
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0
    private var looped = false

    public init(_ data: Data) throws {
        guard data.count >= 17, data.count <= 65536 else { throw TuneError.malformed("not an SQT module") }
        mem = ModuleMemory(data)

        // FoundSQT: the five header pointers are in ascending order and the samples table follows the header.
        // Its stricter tests (table spacing, lengths against the file size) are for finding modules inside
        // other files and turn away a few real ones, so they are left out.
        let samples = mem.word(sqtSamplesPointer), ornaments = mem.word(sqtOrnamentsPointer)
        let patterns = mem.word(sqtPatternsPointer), positions = mem.word(sqtPositionsPointer)
        guard samples >= 10, ornaments > samples + 1, patterns >= ornaments, positions > patterns,
              mem.word(sqtLoopPointer) >= positions
        else {
            throw TuneError.malformed("SQT structure is not valid")
        }

        // LoadTrackerModule: every pointer is rebased by the address the module was compiled for. The header
        // pointers, the sample and ornament tables and the pattern table are one run of words starting at
        // offset 2; the position list is scanned for the highest pattern number to find where the run ends.
        let i = samples - 10
        var i1 = 0
        var i2 = positions - i
        guard mem[i2] != 0 else { throw TuneError.malformed("SQT has no positions") }
        while mem[i2] != 0 {
            if i2 > 65536 - 8 { throw TuneError.malformed("SQT position list is not terminated") }
            if i1 < Int(mem[i2]) & 0x7F { i1 = Int(mem[i2]) & 0x7F }
            i2 += 2
            if i1 < Int(mem[i2]) & 0x7F { i1 = Int(mem[i2]) & 0x7F }
            i2 += 2
            if i1 < Int(mem[i2]) & 0x7F { i1 = Int(mem[i2]) & 0x7F }
            i2 += 3
        }
        i1 = (patterns - i + i1 * 2) / 2
        guard i1 >= 1, i1 < (65536 - 2) / 2 else { throw TuneError.malformed("SQT structure is not valid") }
        var pwrd = sqtSamplesPointer
        for _ in 1 ... i1 {
            let w = mem.word(pwrd)
            if w < i { throw TuneError.malformed("SQT pointer lies before the module") }
            mem.bytes[pwrd] = UInt8((w - i) & 0xFF)
            mem.bytes[pwrd + 1] = UInt8((w - i) >> 8)
            pwrd += 2
        }

        // The format has no title or author fields.
        var info = TuneInfo(format: "SQT")
        info.detail = "SQ-Tracker"
        self.info = info

        restart()
    }

    public func restart() {
        loopCount = 0
        a = Channel(); b = Channel(); c = Channel()
        delayCounter = 1
        delay = 1
        linesCounter = 1
        positionsPointer = mem.word(sqtPositionsPointer)
    }

    private func callLC1D1(_ ch: Channel, _ ptr: inout Int, _ a: Int, _ regs: UnsafeMutablePointer<AYRegs>) {
        ptr = u16(ptr + 1)
        if ch.b6ix0 {
            ch.addressInPattern = u16(ptr + 1)
            ch.b6ix0 = false
        }
        let value = Int(mem[ptr])
        switch a - 1 {
        case 0:
            if ch.b4ix0 { ch.volume = value & 15 }
        case 1:
            if ch.b4ix0 { ch.volume = (ch.volume + value) & 15 }
        case 2:
            if ch.b4ix0 {
                self.a.volume = value
                b.volume = value
                c.volume = value
            }
        case 3:
            if ch.b4ix0 {
                self.a.volume = (self.a.volume + value) & 15
                b.volume = (b.volume + value) & 15
                c.volume = (c.volume + value) & 15
            }
        case 4:
            if ch.b4ix0 {
                delayCounter = value & 31
                if delayCounter == 0 { delayCounter = 32 }
                delay = delayCounter
            }
        case 5:
            if ch.b4ix0 {
                delayCounter = (delayCounter + value) & 31
                if delayCounter == 0 { delayCounter = 32 }
                delay = delayCounter
            }
        case 6:
            ch.currentTonSliding = 0
            ch.gliss = true
            ch.tonSlideStep = -value
        case 7:
            ch.currentTonSliding = 0
            ch.gliss = true
            ch.tonSlideStep = value
        default:
            // Only the low byte of the envelope period is ever written.
            ch.envelopeEnabled = true
            regs[0].setEnvelopeRegister((a - 1) & 15)
            regs[0].envelope = (regs[0].envelope & 0xFF00) | value
        }
    }

    private func callLC2A8(_ ch: Channel, _ a: Int) {
        ch.envelopeEnabled = false
        ch.ornamentEnabled = false
        ch.gliss = false
        ch.enabled = true
        ch.samplePointer = mem.word(a * 2 + mem.word(sqtSamplesPointer))
        ch.pointInSample = u16(ch.samplePointer + 2)
        ch.sampleTikCounter = 32
        ch.mixNoise = true
        ch.mixTon = true
    }

    private func callLC2D9(_ ch: Channel, _ a: Int) {
        ch.ornamentPointer = mem.word(a * 2 + mem.word(sqtOrnamentsPointer))
        ch.pointInOrnament = u16(ch.ornamentPointer + 2)
        ch.ornamentTikCounter = 32
        ch.ornamentEnabled = true
    }

    private func callLC283(_ ch: Channel, _ ptr: inout Int, _ regs: UnsafeMutablePointer<AYRegs>) {
        let value = Int(mem[ptr])
        switch value {
        case 0 ... 0x7F:
            callLC1D1(ch, &ptr, value, regs)
        default:
            if (value >> 1) & 31 != 0 { callLC2A8(ch, (value >> 1) & 31) }
            if value & 64 != 0 {
                var temp = Int(mem[ptr + 1]) >> 4
                if value & 1 != 0 { temp |= 16 }
                if temp != 0 { callLC2D9(ch, temp) }
                ptr = u16(ptr + 1)
                if Int(mem[ptr]) & 15 != 0 { callLC1D1(ch, &ptr, Int(mem[ptr]) & 15, regs) }
            }
        }
        ptr = u16(ptr + 1)
    }

    private func callLC191(_ ch: Channel, _ ptr: inout Int, _ regs: UnsafeMutablePointer<AYRegs>) {
        ptr = ch.ix27
        ch.b6ix0 = false
        let value = Int(mem[ptr])
        switch value {
        case 0 ... 0x7F:
            ptr = u16(ptr + 1)
            callLC283(ch, &ptr, regs)
        default:
            callLC2A8(ch, value & 31)
        }
    }

    private func patternInterpreter(_ ch: Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        var ptr = 0
        if ch.ix21 != 0 {
            ch.ix21 -= 1
            if ch.b7ix0 { callLC191(ch, &ptr, regs) }
            return
        }
        ptr = ch.addressInPattern
        ch.b6ix0 = true
        ch.b7ix0 = false
        // The Pascal wraps this in "repeat ... until False", but every branch breaks out after one pass.
        let value = Int(mem[ptr])
        switch value {
        case 0 ... 0x5F:
            ch.note = value
            ch.ix27 = ptr
            ptr = u16(ptr + 1)
            callLC283(ch, &ptr, regs)
            if ch.b6ix0 { ch.addressInPattern = ptr }
        case 0x60 ... 0x6E:
            callLC1D1(ch, &ptr, value - 0x60, regs)
        case 0x6F ... 0x7F:
            ch.mixNoise = false
            ch.mixTon = false
            ch.enabled = false
            if value != 0x6F {
                callLC1D1(ch, &ptr, value - 0x6F, regs)
            } else {
                ch.addressInPattern = u16(ptr + 1)
            }
        case 0x80 ... 0xBF:
            ch.addressInPattern = u16(ptr + 1)
            if value <= 0x9F {
                if value & 16 == 0 {
                    ch.note = u8(ch.note + (value & 15))
                } else {
                    ch.note = u8(ch.note - (value & 15))
                }
            } else {
                ch.ix21 = value & 15
                if value & 16 == 0 { return }
                if ch.ix21 != 0 { ch.b7ix0 = true }
            }
            callLC191(ch, &ptr, regs)
        default:
            ch.addressInPattern = u16(ptr + 1)
            ch.ix27 = ptr
            callLC2A8(ch, value & 31)
        }
    }

    private func getRegisters(_ ch: Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        tempMixer = u8(tempMixer << 1)
        if ch.enabled {
            let b0 = Int(mem[ch.pointInSample])
            ch.amplitude = b0 & 15
            if ch.amplitude != 0 {
                ch.amplitude = u8(ch.amplitude - ch.volume)
                if s8(ch.amplitude) < 0 { ch.amplitude = 0 }
            } else if ch.envelopeEnabled {
                ch.amplitude = 16
            }
            let b1 = Int(mem[ch.pointInSample + 1])
            if b1 & 32 != 0 {
                tempMixer |= 8
                regs[0].noise = (b0 & 0xF0) >> 3
                if s8(b1) < 0 { regs[0].noise += 1 }
            }
            if b1 & 64 != 0 { tempMixer |= 1 }
            var j = ch.note
            if ch.ornamentEnabled {
                j = u8(j + Int(mem[ch.pointInOrnament]))
                ch.ornamentTikCounter = s8(ch.ornamentTikCounter - 1)
                if ch.ornamentTikCounter == 0 {
                    if mem[ch.ornamentPointer] != 32 {
                        ch.ornamentTikCounter = mem.signed(ch.ornamentPointer + 1)
                        ch.pointInOrnament = u16(ch.ornamentPointer + 2 + Int(mem[ch.ornamentPointer]))
                    } else {
                        // Sic: the loop comes from the sample's header, as in the original player.
                        ch.ornamentTikCounter = mem.signed(ch.samplePointer + 1)
                        ch.pointInOrnament = u16(ch.ornamentPointer + 2 + Int(mem[ch.samplePointer]))
                    }
                } else {
                    ch.pointInOrnament = u16(ch.pointInOrnament + 1)
                }
            }
            j = u8(j + ch.transposit)
            if j > 0x5F { j = 0x5F }
            let delta = ((b1 & 15) << 8) + Int(mem[ch.pointInSample + 2])
            if b1 & 16 == 0 {
                ch.ton = u16(TrackerTables.SQT_Table[j] - delta)
            } else {
                ch.ton = u16(TrackerTables.SQT_Table[j] + delta)
            }
            ch.sampleTikCounter = s8(ch.sampleTikCounter - 1)
            if ch.sampleTikCounter == 0 {
                ch.sampleTikCounter = mem.signed(ch.samplePointer + 1)
                if mem[ch.samplePointer] == 32 {
                    ch.enabled = false
                    ch.ornamentEnabled = false
                }
                ch.pointInSample = u16(ch.samplePointer + 2 + Int(mem[ch.samplePointer]) * 3)
            } else {
                ch.pointInSample = u16(ch.pointInSample + 3)
            }
            if ch.gliss {
                ch.ton = u16(ch.ton + ch.currentTonSliding)
                ch.currentTonSliding = s16(ch.currentTonSliding + ch.tonSlideStep)
            }
            ch.ton &= 0xFFF
        } else {
            ch.amplitude = 0
        }
    }

    /// Reads one channel's two bytes of the current position (pattern number, then volume and transposition)
    /// and returns the address the pattern table holds for it. A zero where a pattern number should be ends
    /// the position list.
    private func nextPosition(_ ch: Channel) -> Int {
        if mem[positionsPointer] == 0 {
            positionsPointer = mem.word(sqtLoopPointer)
            looped = true
        }
        let pattern = Int(mem[positionsPointer])
        ch.b4ix0 = s8(pattern) < 0
        let address = mem.word(u8(pattern * 2) + mem.word(sqtPatternsPointer))
        positionsPointer = u16(positionsPointer + 1)
        let value = Int(mem[positionsPointer])
        ch.volume = value & 15
        if (value >> 4) < 9 {
            ch.transposit = value >> 4
        } else {
            ch.transposit = -((value >> 4) - 9) - 1
        }
        positionsPointer = u16(positionsPointer + 1)
        ch.ix21 = 0
        return address
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        delayCounter = u8(delayCounter - 1)
        if delayCounter == 0 {
            delayCounter = delay
            linesCounter = u8(linesCounter - 1)
            if linesCounter == 0 {
                looped = false
                // Each channel has its own pattern, which starts with its length in lines. Channel C's
                // sets the length of the position; the other two are skipped.
                c.addressInPattern = nextPosition(c)
                linesCounter = Int(mem[c.addressInPattern])
                c.addressInPattern = u16(c.addressInPattern + 1)
                b.addressInPattern = u16(nextPosition(b) + 1)
                a.addressInPattern = u16(nextPosition(a) + 1)
                delay = Int(mem[positionsPointer])
                delayCounter = delay
                positionsPointer = u16(positionsPointer + 1)
                if looped { loopCount += 1 }
            }
            patternInterpreter(c, regs)
            patternInterpreter(b, regs)
            patternInterpreter(a, regs)
        }
        tempMixer = 0
        getRegisters(c, regs)
        getRegisters(b, regs)
        getRegisters(a, regs)
        tempMixer = -(tempMixer + 1) & 0x3F
        if !a.mixNoise { tempMixer |= 8 }
        if !a.mixTon { tempMixer |= 1 }
        if !b.mixNoise { tempMixer |= 16 }
        if !b.mixTon { tempMixer |= 2 }
        if !c.mixNoise { tempMixer |= 32 }
        if !c.mixTon { tempMixer |= 4 }
        regs[0].mixer = tempMixer
        regs[0].tonA = a.ton
        regs[0].tonB = b.ton
        regs[0].tonC = c.ton
        regs[0].amplA = a.amplitude
        regs[0].amplB = b.amplitude
        regs[0].amplC = c.amplitude
    }
}
