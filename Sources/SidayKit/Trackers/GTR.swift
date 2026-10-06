// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

// Global Tracker player, ported from Ay_Emul by Sergey Bulba (Players.pas, GTR_Get_Registers).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.
//
// A module names the address it was compiled for and its pointers count from there. As in Ay_Emul's
// LoadTrackerModule they are turned into file offsets when the module is loaded.

public final class GTRSource: AYFrameSource {
    private struct Channel {
        var samplePointer = 0, ornamentPointer = 0, addressInPattern = 0, ton = 0
        var positionInSample = 0, loopSamplePosition = 0, sampleLength = 0
        var positionInOrnament = 0, loopOrnamentPosition = 0, ornamentLength = 0
        var volume = 0, note = 0, amplitude = 0
        var noteSkipCounter = 0
        var envelopeEnabled = false, enabled = false
    }

    // Header layout. A pattern is three pointers, one per channel; a position is the pattern's number times six.
    private static let delayOffset = 0, id = 1, addressOffset = 5, name = 7, samplesPointers = 39
    private static let ornamentsPointers = 69, patternsPointers = 101, numberOfPositions = 293, loopPosition = 294
    private static let positions = 295

    private let mem: ModuleMemory
    /// Version byte of the tracker; 0x10 is the first one, whose rest command and ornaments behave differently.
    private let version: Int
    private var delayCounter = 0, currentPosition = 0
    private var a = Channel(), b = Channel(), c = Channel()
    public private(set) var loopCount = 0
    public let info: TuneInfo

    // Scratch shared by the three channels within one tick.
    private var tempMixer = 0

    public init(_ data: [UInt8]) throws {
        guard data.count > Self.positions, data.count <= 65536 else { throw TuneError.malformed("not a GTR module") }
        // LoadTrackerModule: the 15 sample, 16 ornament and 32 * 3 pattern pointers lose the load address.
        // Ay_Emul turns down a module with a pointer below that address; here it wraps and the test below decides.
        var bytes = data
        let address = Int(bytes[Self.addressOffset]) | Int(bytes[Self.addressOffset + 1]) << 8
        for i in 0 ..< 15 + 16 + 32 * 3 {
            let at = Self.samplesPointers + i * 2
            let pointer = u16((Int(bytes[at]) | Int(bytes[at + 1]) << 8) - address)
            bytes[at] = UInt8(pointer & 0xFF)
            bytes[at + 1] = UInt8(pointer >> 8)
        }
        bytes[Self.addressOffset] = 0
        bytes[Self.addressOffset + 1] = 0
        mem = ModuleMemory(bytes)
        version = Int(mem[Self.id + 3])

        // Ay_Emul opens a .gtr file without testing it (FoundGTR is for ripping). What is asked for here is the
        // least a module needs to start: positions, and a first pattern that lies inside the file.
        let count = Int(mem[Self.numberOfPositions])
        guard count > 0, Self.positions + count <= data.count else { throw TuneError.malformed("GTR structure is not valid") }
        let row = Self.patternsPointers + Int(mem[Self.positions]) / 6 * 6
        for channel in 0 ..< 3 {
            let pointer = mem.word(row + channel * 2)
            guard pointer >= Self.positions, pointer < data.count else { throw TuneError.malformed("GTR structure is not valid") }
        }

        var info = TuneInfo(format: "GTR")
        info.title = mem.text(at: Self.name, length: 32)
        if mem.text(at: Self.id, length: 3) == "GTR" { info.detail = "Global Tracker 1.\(version & 15)" }
        self.info = info
        restart()
    }

    public func restart() {
        loopCount = 0
        tempMixer = 0
        currentPosition = 0
        delayCounter = 1
        // Until a pattern names a sample and an ornament the channels use empty ones, which Ay_Emul finds in
        // the zeroes at the very end of its 64 KB.
        var channel = Channel()
        channel.samplePointer = 65536 - 4
        channel.sampleLength = 4
        channel.ornamentPointer = 65536 - 4
        channel.ornamentLength = 1
        channel.enabled = true
        a = channel; b = channel; c = channel
        let row = Self.patternsPointers + Int(mem[Self.positions]) / 6 * 6
        a.addressInPattern = mem.word(row)
        b.addressInPattern = mem.word(row + 2)
        c.addressInPattern = mem.word(row + 4)
    }

    private func patternInterpreter(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        ch.noteSkipCounter = 0
        // A corrupt pattern could otherwise run forever; a real one ends within a few bytes.
        var guardCount = 0
        repeat {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0x00 ... 0x5F:
                ch.note = value
                ch.positionInSample = 0
                ch.positionInOrnament = 0
                ch.enabled = true
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                return
            case 0x60 ... 0x6F:
                ch.samplePointer = mem.word(Self.samplesPointers + (value - 0x60) * 2)
                ch.loopSamplePosition = Int(mem[ch.samplePointer])
                ch.samplePointer = u16(ch.samplePointer + 1)
                ch.sampleLength = Int(mem[ch.samplePointer])
                ch.samplePointer = u16(ch.samplePointer + 1)
            case 0x70 ... 0x7F:
                ch.ornamentPointer = mem.word(Self.ornamentsPointers + (value - 0x70) * 2)
                ch.loopOrnamentPosition = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.ornamentLength = Int(mem[ch.ornamentPointer])
                ch.ornamentPointer = u16(ch.ornamentPointer + 1)
                ch.positionInOrnament = 0
                if version != 0x10 { ch.envelopeEnabled = false }
            case 0x80 ... 0xBF:
                ch.noteSkipCounter = value - 0x80
            case 0xC0 ... 0xCF:
                regs[0].setEnvelopeRegister(value - 0xC0)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                // Only the low byte of the envelope period is ever written.
                regs[0].envelope = (regs[0].envelope & 0xFF00) | Int(mem[ch.addressInPattern])
                ch.envelopeEnabled = true
            case 0xD0 ... 0xDF:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                return
            case 0xE0:
                ch.enabled = false
                if version != 0x10 {
                    ch.addressInPattern = u16(ch.addressInPattern + 1)
                    return
                }
            case 0xE1 ... 0xEF:
                ch.volume = 15 - (value - 0xE0)
            default: break
            }
            ch.addressInPattern = u16(ch.addressInPattern + 1)
            guardCount += 1
        } while guardCount < 65536
    }

    private func getRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        if ch.enabled {
            var j = u8(ch.note + Int(mem[ch.ornamentPointer + ch.positionInOrnament]))
            if j > 0x5F { j = 0x5F }
            ch.positionInOrnament = u8(ch.positionInOrnament + 1)
            if ch.positionInOrnament == ch.ornamentLength { ch.positionInOrnament = ch.loopOrnamentPosition }
            let sample = ch.samplePointer + ch.positionInSample
            ch.ton = (TrackerTables.PT3NoteTable_ST[j] + mem.word(sample + 2)) & 0xFFF
            let b = Int(mem[sample + 1])
            regs[0].noise = (regs[0].noise | b) & 0x1F
            ch.amplitude = u8(Int(mem[sample]) - ch.volume)
            if s8(ch.amplitude) < 0 { ch.amplitude = 0 }
            ch.amplitude &= 0x0F
            if s8(b) < 0, ch.envelopeEnabled { ch.amplitude |= 16 }
            if b & 64 != 0 { tempMixer |= 64 }
            if b & 32 != 0 { tempMixer |= 8 }
            ch.positionInSample = u8(ch.positionInSample + 4)
            if ch.positionInSample == ch.sampleLength { ch.positionInSample = ch.loopSamplePosition }
        } else {
            ch.amplitude = 0
            tempMixer |= 8 | 64
        }
        tempMixer >>= 1
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        delayCounter = u8(delayCounter - 1)
        if delayCounter == 0 {
            delayCounter = Int(mem[Self.delayOffset])
            a.noteSkipCounter = s8(a.noteSkipCounter - 1)
            if a.noteSkipCounter < 0 {
                // A module whose every position is empty would otherwise go round forever.
                var guardCount = 0
                while mem[a.addressInPattern] == 255, guardCount < 512 {
                    currentPosition = u8(currentPosition + 1)
                    if currentPosition == Int(mem[Self.numberOfPositions]) {
                        currentPosition = Int(mem[Self.loopPosition])
                        loopCount += 1
                    }
                    let row = Self.patternsPointers + Int(mem[Self.positions + currentPosition]) / 6 * 6
                    a.addressInPattern = mem.word(row)
                    b.addressInPattern = mem.word(row + 2)
                    c.addressInPattern = mem.word(row + 4)
                    guardCount += 1
                }
                patternInterpreter(&a, regs)
            }
            b.noteSkipCounter = s8(b.noteSkipCounter - 1)
            if b.noteSkipCounter < 0 { patternInterpreter(&b, regs) }
            c.noteSkipCounter = s8(c.noteSkipCounter - 1)
            if c.noteSkipCounter < 0 { patternInterpreter(&c, regs) }
        }
        tempMixer = 0
        regs[0].noise = 0
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
