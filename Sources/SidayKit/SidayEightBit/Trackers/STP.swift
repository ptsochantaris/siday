// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

// Sound Tracker Pro (compiled module) player, ported from Ay_Emul by Sergey Bulba (Players.pas, STP_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.

public final class STPSource: AYFrameSource {
    private struct Channel {
        var ornamentPointer = 0, samplePointer = 0, addressInPattern = 0, ton = 0
        var positionInOrnament = 0, loopOrnamentPosition = 0, ornamentLength = 0
        var positionInSample = 0, loopSamplePosition = 0, sampleLength = 0
        var volume = 0, numberOfNotesToSkip = 0, note = 0, amplitude = 0
        var currentTonSliding = 0
        var envelopeEnabled = false, enabled = false
        var glissade = 0, noteSkipCounter = 0
    }

    // Header: delay, four pointers and a byte the original player sets once it has relocated the module (not
    // trusted here). The compiler may add an identifier and a 25-character title after it.
    private static let ksaId = "KSA SOFTWARE COMPILATION OF "

    private let mem: ModuleMemory
    private let stpDelay: Int
    private let stpPositionsPointer: Int
    private let stpPatternsPointer: Int
    private let stpOrnamentsPointer: Int
    private let stpSamplesPointer: Int

    private var delayCounter = 0, currentPosition = 0, transposition = 0
    private var a = Channel(), b = Channel(), c = Channel()
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0

    public init(_ data: [UInt8]) throws {
        guard data.count > 10, data.count <= 65536 else { throw TuneError.malformed("not an STP module") }
        mem = ModuleMemory(data)
        stpDelay = Int(mem[0])
        stpPositionsPointer = mem.word(1)
        stpPatternsPointer = mem.word(3)
        stpOrnamentsPointer = mem.word(5)
        stpSamplesPointer = mem.word(7)

        // There is no signature, so validity is judged by structure (FoundSTP): the position list is followed
        // by the pattern table, then the 16 ornament pointers, then the 15 sample pointers.
        guard stpPositionsPointer < data.count, stpPatternsPointer < data.count,
              stpOrnamentsPointer < data.count, stpSamplesPointer < data.count,
              stpSamplesPointer - stpOrnamentsPointer == 0x20,
              stpOrnamentsPointer > stpPatternsPointer, stpPatternsPointer > stpPositionsPointer else {
            throw TuneError.malformed("STP structure is not valid")
        }

        var hasId = true
        for (n, char) in Self.ksaId.utf8.enumerated() where mem[10 + n] != char { hasId = false }

        // A module ripped after its player had run has absolute addresses in the three pointer tables. The
        // first pattern always follows the header (and the identifier, when there is one), which gives the
        // address the module was loaded at (Players.pas 7505–7540); LoadTrackerModule (2359–2382) takes it
        // back off every word from the pattern table to the end of the module.
        let address = mem.word(stpPatternsPointer) - 10 - (hasId ? 53 : 0)
        guard address >= 0 else { throw TuneError.malformed("STP load address cannot be worked out") }
        if address != 0 {
            let end = min(data.count, stpSamplesPointer + 30)
            var p = stpPatternsPointer
            while p + 1 < end {
                let w = mem.word(p)
                guard w >= address else { throw TuneError.malformed("STP structure is not valid") }
                mem.bytes[p] = UInt8((w - address) & 0xFF)
                mem.bytes[p + 1] = UInt8((w - address) >> 8)
                p += 2
            }
        }

        var info = TuneInfo(format: "STP")
        info.detail = "Sound Tracker Pro"
        if hasId { info.title = mem.text(at: 38, length: 25) }
        self.info = info
        restart()
    }

    public func restart() {
        loopCount = 0
        delayCounter = 1
        transposition = Int(mem[stpPositionsPointer + 3])
        currentPosition = 0
        var ch = Channel()
        ch.samplePointer = mem.word(stpSamplesPointer)
        ch.loopSamplePosition = Int(mem[ch.samplePointer])
        ch.samplePointer = u16(ch.samplePointer + 1)
        ch.sampleLength = Int(mem[ch.samplePointer])
        ch.samplePointer = u16(ch.samplePointer + 1)
        ch.ornamentPointer = mem.word(stpOrnamentsPointer)
        ch.loopOrnamentPosition = Int(mem[ch.ornamentPointer])
        ch.ornamentPointer = u16(ch.ornamentPointer + 1)
        ch.ornamentLength = Int(mem[ch.ornamentPointer])
        ch.ornamentPointer = u16(ch.ornamentPointer + 1)
        a = ch; b = ch; c = ch
        let pattern = stpPatternsPointer + Int(mem[stpPositionsPointer + 2])
        a.addressInPattern = mem.word(pattern)
        b.addressInPattern = mem.word(pattern + 2)
        c.addressInPattern = mem.word(pattern + 4)
    }

    private func patternInterpreter(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        var quit = false
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        repeat {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0x01 ... 0x60:
                ch.note = value - 1
                ch.positionInSample = 0
                ch.positionInOrnament = 0
                ch.currentTonSliding = 0
                ch.enabled = true
                quit = true
            case 0x61 ... 0x6F:
                ch.samplePointer = mem.word(stpSamplesPointer + (value - 0x61) * 2)
                ch.loopSamplePosition = Int(mem[ch.samplePointer])
                ch.samplePointer = u16(ch.samplePointer + 1)
                ch.sampleLength = Int(mem[ch.samplePointer])
                ch.samplePointer = u16(ch.samplePointer + 1)
            case 0x70 ... 0x7F:
                ch.ornamentPointer = mem.word(stpOrnamentsPointer + (value - 0x70) * 2)
                ch.loopOrnamentPosition = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.ornamentLength = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.envelopeEnabled = false
                ch.glissade = 0
            case 0x80 ... 0xBF:
                ch.numberOfNotesToSkip = value - 0x80
            case 0xC0 ... 0xCF:
                if value != 0xC0 {
                    regs[0].setEnvelopeRegister(value - 0xC0)
                    ch.addressInPattern = u16(ch.addressInPattern + 1)
                    // Only the low byte of the envelope period is ever written.
                    regs[0].envelope = (regs[0].envelope & 0xFF00) | Int(mem[ch.addressInPattern])
                }
                ch.envelopeEnabled = true
                ch.loopOrnamentPosition = 0
                ch.glissade = 0
                ch.ornamentLength = 1
            case 0xD0 ... 0xDF:
                ch.enabled = false
                quit = true
            case 0xE0 ... 0xEF:
                quit = true
            case 0xF0:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.glissade = mem.signed(ch.addressInPattern)
            case 0xF1 ... 0xFF:
                ch.volume = value - 0xF1
            default:
                break
            }
            ch.addressInPattern = u16(ch.addressInPattern + 1)
            guardCount += 1
        } while !quit && guardCount < 65536
        ch.noteSkipCounter = ch.numberOfNotesToSkip
    }

    private func getRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        if ch.enabled {
            ch.currentTonSliding = s16(ch.currentTonSliding + ch.glissade)
            var j: Int
            if ch.envelopeEnabled {
                j = u8(ch.note + transposition)
            } else {
                j = u8(ch.note + transposition + Int(mem[ch.ornamentPointer + ch.positionInOrnament]))
            }
            if j > 95 { j = 95 }
            let sample = ch.samplePointer + ch.positionInSample * 4
            let b0 = Int(mem[sample])
            let b1 = Int(mem[sample + 1])
            ch.ton = (TrackerTables.ST_Table[j] + ch.currentTonSliding + mem.word(sample + 2)) & 0xFFF
            ch.amplitude = u8((b0 & 15) - ch.volume)
            if s8(ch.amplitude) < 0 { ch.amplitude = 0 }
            if b1 & 1 != 0, ch.envelopeEnabled { ch.amplitude |= 16 }
            tempMixer = ((b0 >> 1) & 0x48) | tempMixer
            if s8(b0) >= 0 { regs[0].noise = (b1 >> 1) & 31 }
            ch.positionInOrnament = u8(ch.positionInOrnament + 1)
            if ch.positionInOrnament >= ch.ornamentLength { ch.positionInOrnament = ch.loopOrnamentPosition }
            ch.positionInSample = u8(ch.positionInSample + 1)
            if ch.positionInSample >= ch.sampleLength {
                ch.positionInSample = ch.loopSamplePosition
                if s8(ch.loopSamplePosition) < 0 { ch.enabled = false }
            }
        } else {
            tempMixer |= 0x48
            ch.amplitude = 0
        }
        tempMixer >>= 1
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        delayCounter = u8(delayCounter - 1)
        if delayCounter == 0 {
            delayCounter = stpDelay
            a.noteSkipCounter = s8(a.noteSkipCounter - 1)
            if a.noteSkipCounter < 0 {
                if mem[a.addressInPattern] == 0 {
                    currentPosition = u8(currentPosition + 1)
                    if currentPosition == Int(mem[stpPositionsPointer]) {
                        currentPosition = Int(mem[stpPositionsPointer + 1])
                        loopCount += 1
                    }
                    let pattern = stpPatternsPointer + Int(mem[stpPositionsPointer + 2 + currentPosition * 2])
                    a.addressInPattern = mem.word(pattern)
                    b.addressInPattern = mem.word(pattern + 2)
                    c.addressInPattern = mem.word(pattern + 4)
                    transposition = Int(mem[stpPositionsPointer + 3 + currentPosition * 2])
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
