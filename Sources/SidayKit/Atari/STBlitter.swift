// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AtariAudio, Copyright (c) Arnaud Carré, used under the MIT licence (see THIRD-PARTY.md).

/// The STE's blitter, which copies and combines blocks of memory a word at a time while the processor
/// waits. It is for pictures; a tune or two uses it to move sound about. The whole job is done at once
/// when the processor starts it, as the processor would wait for it anyway.
struct STBlitter {
    /// Its registers, from 0xFF8A00: sixteen words of halftone pattern, then the increments, the
    /// addresses, the masks, the counts and the controls.
    private var registers = [UInt8](repeating: 0, count: 256)

    private var motif: UInt32 = 0
    private var count = 0
    private var source: UInt32 = 0
    private var sourceStep: Int16 = 0
    private var halftoneLine = 0
    private var lastWordOnly = false

    mutating func reset() {
        for i in registers.indices { registers[i] = 0 }
    }

    private func byte(_ r: Int) -> UInt8 { registers[r] }
    private func word(_ r: Int) -> UInt16 { UInt16(registers[r]) << 8 | UInt16(registers[r + 1]) }
    private mutating func setWord(_ r: Int, _ value: UInt16) {
        registers[r] = UInt8(truncatingIfNeeded: value >> 8)
        registers[r + 1] = UInt8(truncatingIfNeeded: value)
    }

    func read8(_ port: UInt32) -> UInt8 { byte(Int(port)) }
    func read16(_ port: UInt32) -> UInt16 { word(Int(port)) }

    /// A write to a register; one to the control byte starts the blitter, if it says to.
    /// - Returns: true if it is to run now (see `run`).
    mutating func write8(_ port: UInt32, _ value: UInt8) -> Bool {
        registers[Int(port)] = value
        return port == 0x3C
    }

    mutating func write16(_ port: UInt32, _ value: UInt16) -> Bool {
        setWord(Int(port), value)
        return port == 0x3C
    }

    /// The next word of the source.
    private mutating func sourceWord(_ read: (UInt32) -> UInt16) -> UInt16 {
        if lastWordOnly, count == 1 {
            // (As the original: the word kept is used again, and the address stepped back.)
            source = source &- UInt32(bitPattern: Int32(sourceStep))
            return UInt16(truncatingIfNeeded: motif)
        }
        let value = read(source)
        if count > 1 { source = source &+ UInt32(bitPattern: Int32(sourceStep)) }
        return value
    }

    /// Which of the sixteen operations take anything from the source.
    private static let usesSource = [false, true, true, true, true, false, true, true, true, true, false, true, true, true, true, false]

    /// What the halftone and the source make together, as the operation asks for them.
    private mutating func halftoneAndSource(_ read: (UInt32) -> UInt16) -> UInt16 {
        guard Self.usesSource[Int(byte(0x3B) & 0xF)] else { return 0 }
        switch byte(0x3A) & 3 {
        case 0: return 0xFFFF
        case 1: return word(halftoneLine << 1)
        case 2: return sourceWord(read)
        default: return sourceWord(read) & word(halftoneLine << 1)
        }
    }

    private mutating func fetch(_ read: (UInt32) -> UInt16) {
        motif = motif << 16 | UInt32(halftoneAndSource(read))
    }

    /// Does the job the registers describe, reading and writing words of memory through `read` and
    /// `write`, if the control byte says the blitter is busy; then says it is not.
    mutating func run(read: (UInt32) -> UInt16, write: (UInt32, UInt16) -> Void) {
        guard byte(0x3C) & 0x80 != 0 else { return }
        var lines = Int(word(0x38))
        if lines > 0 {
            motif = 0
            let width = word(0x36) == 0 ? 65536 : Int(word(0x36))
            sourceStep = Int16(bitPattern: word(0x20) & 0xFFFE)
            let sourceLineStep = Int16(bitPattern: word(0x22) & 0xFFFE)
            let targetStep = Int16(bitPattern: word(0x2E) & 0xFFFE)
            let targetLineStep = Int16(bitPattern: word(0x30) & 0xFFFE)
            let shift = UInt32(byte(0x3D) & 0x0F)
            let firstWordExtra = byte(0x3D) & 0x80 != 0
            lastWordOnly = byte(0x3D) & 0x40 != 0
            let operation = byte(0x3B) & 0x0F
            source = (UInt32(word(0x24)) << 16 | UInt32(word(0x26))) & 0x00FF_FFFE
            var target = (UInt32(word(0x32)) << 16 | UInt32(word(0x34))) & 0x00FF_FFFE
            let masks = [word(0x28), word(0x2A), word(0x2C)]
            halftoneLine = Int(byte(0x3C) & 0x0F)

            repeat {
                count = width
                if firstWordExtra { fetch(read) }
                var mask = 0
                while count >= 1 {
                    fetch(read)
                    let hop = byte(0x3A) != 1 ? UInt16(truncatingIfNeeded: motif >> shift) : UInt16(truncatingIfNeeded: motif)
                    let was = read(target)
                    let result: UInt16 = switch operation {
                    case 0: 0
                    case 1: hop & was
                    case 2: hop & ~was
                    case 3: hop
                    case 4: ~hop & was
                    case 5: was
                    case 6: hop ^ was
                    case 7: hop | was
                    case 8: ~hop & ~was
                    case 9: ~hop ^ was
                    case 10: ~was
                    case 11: hop | ~was
                    case 12: ~hop
                    case 13: ~hop | was
                    case 14: ~hop | ~was
                    default: 0xFFFF
                    }
                    write(target, (result & masks[mask]) | (was & ~masks[mask]))
                    if count > 1 { target = target &+ UInt32(bitPattern: Int32(targetStep)) }
                    count -= 1
                    if mask == 0 { mask = 1 }
                    if count == 1 { mask = 2 }
                }
                source = source &+ UInt32(bitPattern: Int32(sourceLineStep))
                target = target &+ UInt32(bitPattern: Int32(targetLineStep))
                halftoneLine = (halftoneLine + (targetLineStep >= 0 ? 1 : -1)) & 15
                lines -= 1
            } while lines > 0

            setWord(0x24, UInt16(truncatingIfNeeded: source >> 16))
            setWord(0x26, UInt16(truncatingIfNeeded: source) & 0xFFFE)
            setWord(0x32, UInt16(truncatingIfNeeded: target >> 16))
            setWord(0x34, UInt16(truncatingIfNeeded: target) & 0xFFFE)
            setWord(0x38, 0)
        }
        registers[0x3C] &= 0x7F
    }
}
