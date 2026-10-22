// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

// Sound Tracker (compiled module) player, ported from Ay_Emul by Sergey Bulba (Players.pas, STC_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.

public final class STCSource: AYFrameSource {
    private struct Channel {
        var addressInPattern = 0, samplePointer = 0, ornamentPointer = 0, ton = 0
        var amplitude = 0, note = 0, positionInSample = 0, numberOfNotesToSkip = 0
        var sampleTikCounter = 0, noteSkipCounter = 0
        var envelopeEnabled = false
    }

    // Header: delay, three pointers, an 18-character name and the module size.
    private let mem: ModuleMemory
    private let stDelay: Int
    private let stPositionsPointer: Int
    private let stOrnamentsPointer: Int
    private let stPatternsPointer: Int

    private var delayCounter = 0, transposition = 0, currentPosition = 0
    private var a = Channel(), b = Channel(), c = Channel()
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0

    public init(_ data: [UInt8]) throws {
        guard data.count > 27, data.count <= 65536 else { throw TuneError.malformed("not an STC module") }
        mem = ModuleMemory(data)
        stDelay = Int(mem[0])
        stPositionsPointer = mem.word(1)
        stOrnamentsPointer = mem.word(3)
        stPatternsPointer = mem.word(5)

        // The name is usually the compiler's signature, so validity is judged by structure (FoundSTC): the
        // three tables lie inside the file, the pattern table comes after the ornaments, and the first
        // position names a pattern the table has.
        guard stPositionsPointer < data.count, stOrnamentsPointer < data.count, stPatternsPointer < data.count,
              stPatternsPointer > stOrnamentsPointer, stPositionsPointer != stOrnamentsPointer else {
            throw TuneError.malformed("STC structure is not valid")
        }
        var i = 0
        let first = mem[stPositionsPointer + 1]
        while stPatternsPointer + 7 * i < data.count, mem[stPatternsPointer + 7 * i] != first { i += 1 }
        guard stPatternsPointer + 7 * i < data.count else {
            throw TuneError.malformed("STC position list names a missing pattern")
        }

        info = Self.readInfo(mem, patterns: stPatternsPointer, size: data.count)
        restart()
    }

    /// Title and author as Ay_Emul's playlist shows them (Players.pas, AddTrackerModule).
    private static func readInfo(_ mem: ModuleMemory, patterns: Int, size: Int) -> TuneInfo {
        var info = TuneInfo(format: "STC")
        info.detail = "Sound Tracker"
        // The 18 characters at offset 7 are a title unless they are one of the compilers' own signatures.
        let signatures: Set<String> = [
            "SONG BY ST COMPILE", "SONG BY MB COMPILE", "SONG BY ST-COMPILE", "SOUND TRACKER v1.1", "S.T.FULL EDITION",
            "SOUND TRACKER v1.3", "STU SONG COMPILER", "(C) KLAV \"S_SONIC\"", "ZX81 Compiler A.Re",
        ]
        var title = mem.text(at: 7, length: 18)
        if signatures.contains(title) {
            title = ""
        } else if mem.word(25) != size {
            // The size word was sometimes used for two more characters of the name.
            let c19 = mem[25], c20 = mem[26]
            if c19 >= 0x20, c19 <= 0x7F { title = mem.text(at: 7, length: c20 >= 0x20 && c20 <= 0x7F ? 20 : 19) }
        }
        // Some compilers put a 55-byte identifier in front of the pattern table.
        if patterns >= 55 + 27 {
            let id = mem.text(at: patterns - 55, length: 55)
            var s = ""
            if id.hasPrefix("SOUND TRACKER COMPILATION OF ") {
                info.author = mem.text(at: patterns - 55 + 43, length: 12)
                s = mem.text(at: patterns - 55 + 29, length: 10)
            } else if id.hasPrefix("KSA SOFTWARE COMPILATION OF ") {
                s = mem.text(at: patterns - 55 + 28, length: 27)
            }
            if !s.isEmpty {
                if title.isEmpty { title = s } else if title != s { title = "\(s) (\(title))" }
            }
        }
        info.title = title
        return info
    }

    // The Pascal searches the pattern table, the ornaments and the samples by number each time one is used,
    // and without a bound. The module never changes, so here each answer is kept, and a search gives up
    // after one lap of the 64 KB (which a real Z80 would also wrap around).
    private var patternEntries = [Int](repeating: -1, count: 256)
    private var ornamentEntries = [Int](repeating: -1, count: 16)
    private var sampleEntries = [Int](repeating: -1, count: 16)

    /// Address of the pattern table entry (number, then the three channel pointers) for a pattern number.
    private func patternEntry(_ number: Int) -> Int {
        if patternEntries[number] < 0 {
            var i = 0
            while Int(mem[stPatternsPointer + 7 * i]) != number, i < 65535 { i += 1 }
            patternEntries[number] = stPatternsPointer + 7 * i
        }
        return patternEntries[number]
    }

    /// Address of the ornament with the given number: the number byte, then 32 note offsets.
    private func ornamentEntry(_ number: Int) -> Int {
        if ornamentEntries[number] < 0 {
            var k = 0
            while Int(mem[stOrnamentsPointer + 0x21 * k]) != number, k < 65535 { k += 1 }
            ornamentEntries[number] = stOrnamentsPointer + 0x21 * k
        }
        return ornamentEntries[number]
    }

    /// Address of the sample with the given number: the number byte, 32 three-byte steps, then the loop
    /// position and loop length. Samples sit at fixed addresses from 0x1B.
    private func sampleEntry(_ number: Int) -> Int {
        if sampleEntries[number] < 0 {
            var k = 0
            while Int(mem[0x1B + 0x63 * k]) != number, k < 65535 { k += 1 }
            sampleEntries[number] = 0x1B + 0x63 * k
        }
        return sampleEntries[number]
    }

    public func restart() {
        loopCount = 0
        currentPosition = 0
        transposition = Int(mem[stPositionsPointer + 2])
        delayCounter = 1
        let entry = patternEntry(Int(mem[stPositionsPointer + 1]))
        var ch = Channel()
        ch.sampleTikCounter = -1
        ch.ornamentPointer = u16(stOrnamentsPointer + 1)
        a = ch; b = ch; c = ch
        a.addressInPattern = mem.word(entry + 1)
        b.addressInPattern = mem.word(entry + 3)
        c.addressInPattern = mem.word(entry + 5)
    }

    private func patternInterpreter(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        scan: while guardCount < 65536 {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0 ... 0x5F:
                ch.note = value
                ch.sampleTikCounter = 32
                ch.positionInSample = 0
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                break scan
            case 0x60 ... 0x6F:
                ch.samplePointer = u16(sampleEntry(value - 0x60) + 1)
            case 0x70 ... 0x7F:
                ch.ornamentPointer = u16(ornamentEntry(value - 0x70) + 1)
                ch.envelopeEnabled = false
            case 0x80:
                ch.sampleTikCounter = -1
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                break scan
            case 0x81:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                break scan
            case 0x82:
                ch.ornamentPointer = u16(ornamentEntry(0) + 1)
                ch.envelopeEnabled = false
            case 0x83 ... 0x8E:
                regs[0].setEnvelopeRegister(value - 0x80)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                // Only the low byte of the envelope period is ever written.
                regs[0].envelope = (regs[0].envelope & 0xFF00) | Int(mem[ch.addressInPattern])
                ch.envelopeEnabled = true
                ch.ornamentPointer = u16(ornamentEntry(0) + 1)
            default:
                ch.numberOfNotesToSkip = u8(value - 0xA1)
            }
            ch.addressInPattern = u16(ch.addressInPattern + 1)
            guardCount += 1
        }
        ch.noteSkipCounter = s8(ch.numberOfNotesToSkip)
    }

    private func getRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        if ch.sampleTikCounter >= 0 {
            ch.sampleTikCounter -= 1
            ch.positionInSample = (ch.positionInSample + 1) & 0x1F
            if ch.sampleTikCounter == 0 {
                if mem[ch.samplePointer + 0x60] != 0 {
                    ch.positionInSample = Int(mem[ch.samplePointer + 0x60]) & 0x1F
                    ch.sampleTikCounter = s8(Int(mem[ch.samplePointer + 0x61]) + 1)
                } else {
                    ch.sampleTikCounter = -1
                }
            }
        }
        if ch.sampleTikCounter >= 0 {
            let i = u16(((ch.positionInSample - 1) & 0x1F) * 3 + ch.samplePointer)
            let b0 = Int(mem[i]), b1 = Int(mem[i + 1])
            if b1 & 0x80 != 0 {
                tempMixer |= 64
            } else {
                regs[0].noise = b1 & 0x1F
            }
            if b1 & 0x40 != 0 { tempMixer |= 8 }
            ch.amplitude = b0 & 15
            var j = u8(ch.note + Int(mem[ch.ornamentPointer + ((ch.positionInSample - 1) & 0x1F)]) + transposition)
            if j > 95 { j = 95 }
            if b1 & 0x20 != 0 {
                ch.ton = (TrackerTables.ST_Table[j] + Int(mem[i + 2]) + ((b0 & 0xF0) << 4)) & 0xFFF
            } else {
                ch.ton = (TrackerTables.ST_Table[j] - Int(mem[i + 2]) - ((b0 & 0xF0) << 4)) & 0xFFF
            }
            if ch.envelopeEnabled { ch.amplitude |= 16 }
        } else {
            ch.amplitude = 0
        }
        tempMixer >>= 1
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        delayCounter = u8(delayCounter - 1)
        if delayCounter == 0 {
            delayCounter = stDelay
            a.noteSkipCounter = s8(a.noteSkipCounter - 1)
            if a.noteSkipCounter < 0 {
                if mem[a.addressInPattern] == 255 {
                    // There is no loop position: after the last position the tune starts over.
                    if currentPosition == Int(mem[stPositionsPointer]) {
                        currentPosition = 0
                        loopCount += 1
                    } else {
                        currentPosition = u8(currentPosition + 1)
                    }
                    transposition = Int(mem[stPositionsPointer + 2 + currentPosition * 2])
                    let entry = patternEntry(Int(mem[stPositionsPointer + 1 + currentPosition * 2]))
                    a.addressInPattern = mem.word(entry + 1)
                    b.addressInPattern = mem.word(entry + 3)
                    c.addressInPattern = mem.word(entry + 5)
                }
                patternInterpreter(&a, regs)
            }
            b.noteSkipCounter = s8(b.noteSkipCounter - 1)
            if b.noteSkipCounter < 0 { patternInterpreter(&b, regs) }
            c.noteSkipCounter = s8(c.noteSkipCounter - 1)
            if c.noteSkipCounter < 0 { patternInterpreter(&c, regs) }
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
