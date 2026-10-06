// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

// Pro Sound Maker player, ported from Ay_Emul by Sergey Bulba (Players.pas, PSM_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.
//
// The position list is pairs of pattern and transposition. It ends with 255 followed by the position to go
// back to, or by another 255 for a tune that stops. Channel C leads: its pattern says when a position is over.

public final class PSMSource: AYFrameSource {
    private struct Channel {
        var addressInPattern = 0, retAddress = 0, divShift = 0, ton = 0
        var numberOfNotesToSkip = 0, noteSkipCounter = 0
        var amplitude = 0, retCnt = 0, vol = 0, volCnt = 0, loopCnt = 0, orn = 0, envType = 0, envDiv = 0, samp = 0
        // Signed bytes. The low five bits count through the ornament and the sample; the bits above are flags.
        var ornTick = 0, smpTick = 0, note = 0
    }

    // Header layout.
    private static let positionsPointerOffset = 0, samplesPointerOffset = 2, ornamentsPointerOffset = 4
    private static let patternsPointerOffset = 6, remark = 8
    /// What the compiler puts at the start of the remark, with a zero after it.
    private static let psmId = Array("psm1".utf8) + [0]

    private let mem: ModuleMemory
    private let positionsPointer: Int, samplesPointer: Int, ornamentsPointer: Int, patternsPointer: Int
    private var delay = 0, delayCounter = 0, currentPosition = 0, transposition = 0, finished = false
    private var a = Channel(), b = Channel(), c = Channel()
    public private(set) var loopCount = 0
    public var hasEnded: Bool { finished }
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0

    public init(_ data: [UInt8]) throws {
        guard data.count > Self.remark + 2, data.count <= 65536 else { throw TuneError.malformed("not a PSM module") }
        mem = ModuleMemory(data)
        positionsPointer = mem.word(Self.positionsPointerOffset)
        samplesPointer = mem.word(Self.samplesPointerOffset)
        ornamentsPointer = mem.word(Self.ornamentsPointerOffset)
        patternsPointer = mem.word(Self.patternsPointerOffset)

        // Ay_Emul has no test for this format and opens a .psm file as it is. What is asked for here is the
        // least a module needs to start: four tables inside the file, a first position, and its pattern.
        for pointer in [positionsPointer, samplesPointer, ornamentsPointer, patternsPointer]
            where pointer < Self.remark || pointer >= data.count {
            throw TuneError.malformed("PSM structure is not valid")
        }
        let first = Int(mem[positionsPointer])
        let row = patternsPointer + first * 7
        guard first != 255, row + 7 <= data.count else { throw TuneError.malformed("PSM structure is not valid") }
        for channel in 0 ..< 3 where mem.word(row + 1 + channel * 2) >= data.count {
            throw TuneError.malformed("PSM structure is not valid")
        }

        // The remark fills the gap between the header and the position list; the compiler's own mark is not
        // part of the title.
        var info = TuneInfo(format: "PSM")
        var at = Self.remark, length = positionsPointer - Self.remark
        if length >= Self.psmId.count, [UInt8](data.prefix(at + Self.psmId.count).suffix(Self.psmId.count)) == Self.psmId {
            at += Self.psmId.count
            length -= Self.psmId.count
        }
        if length > 0 { info.title = mem.text(at: at, length: length) }
        self.info = info
        restart()
    }

    public func restart() {
        loopCount = 0
        tempMixer = 0
        currentPosition = 0
        finished = false
        let pattern = Int(mem[positionsPointer])
        transposition = s8(Int(mem[positionsPointer + 1]) + 48)
        delay = Int(mem[patternsPointer + pattern * 7])
        a = Channel(); b = Channel(); c = Channel()
        a.addressInPattern = mem.word(patternsPointer + pattern * 7 + 1)
        b.addressInPattern = mem.word(patternsPointer + pattern * 7 + 3)
        c.addressInPattern = mem.word(patternsPointer + pattern * 7 + 5)
        a.noteSkipCounter = 1
        b.noteSkipCounter = 1
        c.noteSkipCounter = 1
        a.note = -128
        b.note = -128
        c.note = -128
        delayCounter = 1
    }

    @inline(__always) private func setEnvelope(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        regs[0].setEnvelopeRegister(ch.envType - 0xB1 + 8)
        if ch.envDiv >= 0xF1 {
            regs[0].envelope = (ch.envDiv & 15) << 8
        } else {
            regs[0].envelope = ch.envDiv
        }
        ch.ornTick = s8(ch.ornTick | 0x40)
    }

    private func patternInterpreter(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        var patAddr = ch.addressInPattern
        if ch.retCnt != 0 {
            ch.retCnt -= 1
            if ch.retCnt == 0 { patAddr = ch.retAddress }
        }
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        interpret: repeat {
            let value = Int(mem[patAddr])
            switch value {
            case 0x00 ... 0x5F:
                // Notes count downwards: from the transposition for the first of a position, then from the
                // note before.
                if ch.note < 0 {
                    ch.note = s8(transposition - value)
                } else {
                    ch.note = s8(ch.note - value)
                }
                if ch.note < 0 { ch.note = s8(ch.note + 96) }
                ch.volCnt = ch.vol
                ch.smpTick = 0
                ch.divShift = 0
                ch.loopCnt = 1
                if ch.ornTick < 0 {
                    ch.ornTick = s8(ch.ornTick & 0xE0)
                } else {
                    ch.ornTick = s8(ch.ornTick & 0xC0)
                }
                if ch.ornTick & 0x40 != 0, ch.orn >= 33 {
                    if ch.envType >= 0xB1 {
                        setEnvelope(&ch, regs)
                    } else {
                        // An envelope that follows the note, one or more octaves below it.
                        var b = u8(ch.envType - 0xA1)
                        regs[0].setEnvelopeRegister(((b & 3) << 1) | 8)
                        b = u8((b & 12) * 3 + ch.note)
                        if b >= 48 {
                            b -= 48
                            if b >= 48 { b -= 48 }
                        }
                        // The Pascal reads past the table for a note in the top octaves; the last entry is used.
                        regs[0].envelope = TrackerTables.PSM_Table[min(b + 48, 95)]
                    }
                }
                patAddr = u16(patAddr + 1)
                break interpret
            case 0x60:
                ch.smpTick = s8(u8(ch.smpTick) | 128)
                patAddr = u16(patAddr + 1)
                break interpret
            case 0x61 ... 0x6F:
                ch.samp = value - 0x61
            case 0x70 ... 0x8F:
                ch.orn = value - 0x70
                ch.ornTick = 0
            case 0x90:
                patAddr = u16(patAddr + 1)
                break interpret
            case 0x91 ... 0x9F:
                ch.vol = value - 0x90
            case 0xA0:
                ch.ornTick = s8(value)
            case 0xA1 ... 0xB0:
                ch.orn = 33
                ch.envType = value
                ch.ornTick = s8(ch.ornTick | 0x40)
            case 0xB1 ... 0xB7:
                ch.envType = value
                patAddr = u16(patAddr + 1)
                ch.envDiv = Int(mem[patAddr])
                setEnvelope(&ch, regs)
            case 0xB8 ... 0xF8:
                ch.numberOfNotesToSkip = value - 0xB7
            case 0xF9:
                // Play some rows from elsewhere, then carry on after this command.
                ch.retAddress = u16(patAddr + 4)
                ch.retCnt = Int(mem[patAddr + 3])
                patAddr = u16(mem.word(patAddr + 1) - 1)
            case 0xFA ... 0xFB:
                ch.orn = value - 0xFA + 32
            default:
                patAddr = u16(patAddr + 1)
                break interpret
            }
            patAddr = u16(patAddr + 1)
            guardCount += 1
        } while guardCount < 65536
        ch.addressInPattern = patAddr
        ch.noteSkipCounter = ch.numberOfNotesToSkip
    }

    private func changeRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        var b = ch.note & 127
        var b2 = u8(ch.ornTick)
        let wo = mem.word(ornamentsPointer + ch.orn * 2)
        if ch.ornTick & 0x60 == 0 { b = u8(b + Int(mem[wo + 2 + b2])) }
        if s8(b) < 0 { b = 0 } else if b > 95 { b = 95 }
        ch.ton = TrackerTables.PSM_Table[b]

        b2 = u8(ch.smpTick * 3)
        let ws = mem.word(samplesPointer + ch.samp * 2)
        b = Int(mem[ws + 2 + b2])
        var b1 = Int(mem[ws + 2 + b2 + 1])
        b2 = Int(mem[ws + 2 + b2 + 2])

        // An 11-bit signed step for the tone period.
        var w = ((b1 & 7) << 8) + b2
        if b1 & 4 != 0 { w |= 0xF800 }

        ch.divShift = u16(ch.divShift + w)
        ch.ton = u16(ch.ton + ch.divShift)
        if s16(ch.ton) < 0 { ch.ton = 0 } else if ch.ton >= 4096 { ch.ton = 4095 }

        ch.amplitude = b & 15
        if ch.ornTick & 0x40 != 0 { ch.amplitude |= 16 }
        ch.amplitude = u8(ch.amplitude + ch.volCnt - 15)
        if s8(ch.amplitude) < 0 || ch.smpTick < 0 { ch.amplitude = 0 }

        tempMixer = ((b >> 1) & 0x48) | tempMixer
        if ch.smpTick < 0 { tempMixer |= 0x40 }

        if s8(b) >= 0, ch.amplitude != 0 { regs[0].noise = b1 >> 3 }

        // The sample's two header bytes: its length and volume step, then its loop.
        b = (ch.smpTick & 31) + 1
        b1 = Int(mem[ws])
        b2 = Int(mem[ws + 1])
        if b > (b1 & 31) {
            if b2 & 0xE0 == 0 {
                ch.smpTick = s8(u8(ch.smpTick) | 128)
            } else {
                b = b2 & 31
                ch.loopCnt = u8(ch.loopCnt - 1)
                if ch.loopCnt == 0 {
                    ch.loopCnt = b2 >> 5
                    if b1 & 0x20 == 0 {
                        ch.volCnt = u8(ch.volCnt + (b1 >> 6))
                    } else {
                        ch.volCnt = u8(ch.volCnt - ((b1 >> 6) + 1))
                    }
                    if s8(ch.volCnt) < 0 { ch.volCnt = 0 } else if ch.volCnt > 15 { ch.volCnt = 15 }
                }
            }
        }
        ch.smpTick = s8(((b ^ u8(ch.smpTick)) & 31) ^ u8(ch.smpTick))

        // The ornament's: its length, then its loop if the top bit is set.
        b = (ch.ornTick & 31) + 1
        b1 = Int(mem[wo])
        b2 = Int(mem[wo + 1])
        if b > b1 {
            if s8(b2) < 0 {
                b = b2
            } else {
                ch.ornTick = s8(ch.ornTick | 0x20)
            }
        }
        ch.ornTick = s8(((b ^ u8(ch.ornTick)) & 31) ^ u8(ch.ornTick))

        tempMixer >>= 1
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        regs[0].amplA = 0
        regs[0].amplB = 0
        regs[0].amplC = 0
        if finished { return }
        delayCounter = u8(delayCounter - 1)
        if delayCounter == 0 {
            c.noteSkipCounter = u8(c.noteSkipCounter - 1)
            if c.noteSkipCounter == 0 {
                if mem[c.addressInPattern] == 255 {
                    currentPosition = u8(currentPosition + 1)
                    var pattern = Int(mem[positionsPointer + currentPosition * 2])
                    if pattern == 255 {
                        pattern = Int(mem[positionsPointer + currentPosition * 2 + 1])
                        if pattern == 255 {
                            finished = true
                            return
                        }
                        currentPosition = pattern
                        pattern = Int(mem[positionsPointer + pattern * 2])
                        loopCount += 1
                    }
                    transposition = s8(Int(mem[positionsPointer + currentPosition * 2 + 1]) + 48)
                    delay = Int(mem[patternsPointer + pattern * 7])
                    a.addressInPattern = mem.word(patternsPointer + pattern * 7 + 1)
                    b.addressInPattern = mem.word(patternsPointer + pattern * 7 + 3)
                    c.addressInPattern = mem.word(patternsPointer + pattern * 7 + 5)
                    a.retCnt = 0
                    b.retCnt = 0
                    c.retCnt = 0
                    a.noteSkipCounter = 1
                    b.noteSkipCounter = 1
                    a.note = s8(u8(a.note) | 128)
                    b.note = s8(u8(b.note) | 128)
                    c.note = s8(u8(c.note) | 128)
                }
                patternInterpreter(&c, regs)
            }
            b.noteSkipCounter = u8(b.noteSkipCounter - 1)
            if b.noteSkipCounter == 0 { patternInterpreter(&b, regs) }
            a.noteSkipCounter = u8(a.noteSkipCounter - 1)
            if a.noteSkipCounter == 0 { patternInterpreter(&a, regs) }
            delayCounter = delay
        }
        tempMixer = 0
        changeRegisters(&a, regs)
        changeRegisters(&b, regs)
        changeRegisters(&c, regs)
        regs[0].mixer = tempMixer
        regs[0].tonA = a.ton
        regs[0].tonB = b.ton
        regs[0].tonC = c.ton
        regs[0].amplA = a.amplitude
        regs[0].amplB = b.amplitude
        regs[0].amplC = c.amplitude
    }
}
