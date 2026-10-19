// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Written against Commodore's Amiga Hardware Reference Manual: the custom chips' registers at $DFF000
// and the two 8520s, as far as a player of music touches them.

/// A write a program made to Paula's registers, to the DMA's, or to the power light, at the moment it
/// made it (see `AmigaChips.writes`).
struct AmigaWrite: Equatable {
    /// The processor's cycles into the call it was made in (`M68000.cycles`).
    var cycles: Int
    /// The register: its offset from $DFF000 ($096 DMACON, $09E ADKCON, $0A0 to $0DF the four voices'
    /// AUDxLCH, AUDxLCL, AUDxLEN, AUDxPER, AUDxVOL and AUDxDAT), or `AmigaWrite.filter`.
    var register: UInt16
    var value: UInt16

    /// Not a register: the power light's line of CIA-A's first port, which switches the filter of the
    /// sound: its value is 1 as the filter comes on, 0 as it goes off.
    static let filter: UInt16 = 0x1000
}

/// What an Amiga's 68000 finds above its chip RAM, as a player of music uses it: the custom chips at
/// $DFF000 (the DMA's control, the interrupts', the beam's position, and Paula's registers, whose
/// writes are kept with their times to be heard as they fell), the two CIAs at $BFE001 and $BFD000,
/// and a port at $F00000 through which code written for the host tells it things.
///
/// Time is kept in Paula's clocks (the colour clock, 3,546,895 a second on a PAL machine), of which the
/// 68000 takes two to each of its cycles. `clock` is the time as the current call into the program's
/// code began; within it, the processor's cycles say how far it has got.
final class AmigaChips: M68000Bus {
    static let custom: UInt32 = 0xDFF000
    /// Where code the host has written into the machine (`AmigaMachine`) tells it something: a word or
    /// a long written anywhere in these 64 KB is kept in `signals`, its register the offset into them.
    static let hostPort: UInt32 = 0xF00000
    /// A PAL line is 227 of Paula's clocks, and a frame 313 lines.
    static let lineClocks = 227
    static let frameLines = 313

    /// CIA-A, then CIA-B.
    var cias = InlineArray<2, AmigaCIA>(repeating: AmigaCIA())
    private(set) var dmacon: UInt16 = 0, intena: UInt16 = 0, intreq: UInt16 = 0, adkcon: UInt16 = 0
    /// The writes to Paula and the DMA made since they were last taken, in order; and what the host's
    /// code has told it through its port.
    var writes: [AmigaWrite] = []
    var signals: [AmigaWrite] = []
    /// The time as the current call began, in Paula's clocks since the machine was switched on.
    var clock: UInt64 = 0
    /// How far the CIAs have been moved on, in ticks of the E clock (a fifth of Paula's).
    private var eTicks: UInt64 = 0
    /// Whether the filter was on, by the power light, as last told.
    private var filterOn = false

    init() {
        writes.reserveCapacity(256)
    }

    /// As the machine is switched on, with the power light's line an output and off (as UADE's
    /// `score.s` leaves it before it starts a player), and nothing else set.
    func reset() {
        cias = InlineArray(repeating: AmigaCIA())
        cias[0].write(AmigaCIA.Register.ddra.rawValue, 0x03)
        cias[0].write(AmigaCIA.Register.pra.rawValue, 0x02)
        dmacon = 0
        intena = 0
        intreq = 0
        adkcon = 0
        writes.removeAll(keepingCapacity: true)
        signals.removeAll(keepingCapacity: true)
        clock = 0
        eTicks = 0
        filterOn = false
    }

    /// The time, `cycles` into the current call.
    @inline(__always) func now(_ cycles: Int) -> UInt64 { clock &+ UInt64(max(0, cycles)) / 2 }

    /// The line the beam is on, and how far along it, at a time.
    static func beam(at time: UInt64) -> (line: Int, position: Int) {
        let inFrame = Int(time % UInt64(lineClocks * frameLines))
        return (inFrame / lineClocks, inFrame % lineClocks)
    }

    /// Brings the CIAs up to the time, `cycles` into the current call: their timers, and their times of
    /// day (frames for CIA-A, lines for CIA-B).
    func catchUp(_ cycles: Int) {
        let time = now(cycles)
        let e = time / 5
        if e > eTicks {
            let ticks = Int(min(e - eTicks, UInt64(Int32.max)))
            cias[0].advance(by: ticks)
            cias[1].advance(by: ticks)
            eTicks = e
        }
        cias[0].timeOfDay = UInt32(truncatingIfNeeded: time / UInt64(Self.lineClocks * Self.frameLines))
        cias[1].timeOfDay = UInt32(truncatingIfNeeded: time / UInt64(Self.lineClocks))
    }

    /// True while the filter is on: the power light's line is an output, and low.
    var lightFilter: Bool { filterOn }

    // MARK: The bus

    func read8(_ address: UInt32) -> UInt8 { read8(address, at: 0) }
    func read16(_ address: UInt32) -> UInt16 { read16(address, at: 0) }
    func write8(_ address: UInt32, _ value: UInt8) { write8(address, value, at: 0) }
    func write16(_ address: UInt32, _ value: UInt16) { write16(address, value, at: 0) }

    func read8(_ address: UInt32, at cycles: Int) -> UInt8 {
        if address & 0xFFF000 == Self.custom {
            let word = readCustom(UInt16(address & 0xFFE), at: cycles)
            return UInt8(truncatingIfNeeded: address & 1 == 0 ? word >> 8 : word)
        }
        if address & 0xFF0000 == 0xBF0000 {
            catchUp(cycles)
            if address & 1 == 1, address & 0x1000 == 0 { return cias[0].read(Int(address >> 8 & 15)) }
            if address & 1 == 0, address & 0x2000 == 0 { return cias[1].read(Int(address >> 8 & 15)) }
            return 0xFF
        }
        return 0
    }

    func read16(_ address: UInt32, at cycles: Int) -> UInt16 {
        if address & 0xFFF000 == Self.custom { return readCustom(UInt16(address & 0xFFE), at: cycles) }
        if address & 0xFF0000 == 0xBF0000 {
            // The high byte from CIA-B, the low from CIA-A.
            return UInt16(read8(address & ~1, at: cycles)) << 8 | UInt16(read8(address | 1, at: cycles))
        }
        return 0
    }

    func write8(_ address: UInt32, _ value: UInt8, at cycles: Int) {
        if address & 0xFFF000 == Self.custom {
            // The 68000 puts a byte on both halves of the bus, and the chips take the whole word.
            writeCustom(UInt16(address & 0xFFE), UInt16(value) << 8 | UInt16(value), at: cycles)
            return
        }
        if address & 0xFF0000 == 0xBF0000 {
            catchUp(cycles)
            if address & 1 == 1, address & 0x1000 == 0 {
                cias[0].write(Int(address >> 8 & 15), value)
                noteFilter(at: cycles)
            }
            if address & 1 == 0, address & 0x2000 == 0 { cias[1].write(Int(address >> 8 & 15), value) }
            return
        }
        if address & 0xFF0000 == Self.hostPort {
            signals.append(AmigaWrite(cycles: cycles, register: UInt16(address & 0xFFFF), value: UInt16(value)))
        }
    }

    func write16(_ address: UInt32, _ value: UInt16, at cycles: Int) {
        if address & 0xFFF000 == Self.custom {
            writeCustom(UInt16(address & 0xFFE), value, at: cycles)
            return
        }
        if address & 0xFF0000 == 0xBF0000 {
            write8(address & ~1, UInt8(truncatingIfNeeded: value >> 8), at: cycles)
            write8(address | 1, UInt8(truncatingIfNeeded: value), at: cycles)
            return
        }
        if address & 0xFF0000 == Self.hostPort {
            signals.append(AmigaWrite(cycles: cycles, register: UInt16(address & 0xFFFF), value: value))
        }
    }

    // MARK: The custom chips

    private func readCustom(_ register: UInt16, at cycles: Int) -> UInt16 {
        switch register {
        case 0x002: return dmacon & 0x07FF
        case 0x004, 0x006:
            let (line, position) = Self.beam(at: now(cycles))
            // Every frame is a long one (bit 15 of VPOSR); the Agnus says nothing of itself.
            return register == 0x004 ? 0x8000 | UInt16(line >> 8) : UInt16(line & 0xFF) << 8 | UInt16(position)
        case 0x010: return adkcon
        case 0x01C: return intena
        case 0x01E: return intreq
        default: return 0
        }
    }

    /// A register whose bit 15 says whether the others set are set or cleared.
    @inline(__always) private static func setOrClear(_ old: UInt16, _ value: UInt16) -> UInt16 {
        value & 0x8000 != 0 ? old | value & 0x7FFF : old & ~value
    }

    private func writeCustom(_ register: UInt16, _ value: UInt16, at cycles: Int) {
        switch register {
        case 0x096:
            dmacon = Self.setOrClear(dmacon, value)
            writes.append(AmigaWrite(cycles: cycles, register: register, value: value))
        case 0x09A: intena = Self.setOrClear(intena, value)
        case 0x09C: intreq = Self.setOrClear(intreq, value)
        case 0x09E:
            adkcon = Self.setOrClear(adkcon, value)
            writes.append(AmigaWrite(cycles: cycles, register: register, value: value))
        case 0x0A0 ..< 0x0E0:
            if register & 0xF < 0xC { writes.append(AmigaWrite(cycles: cycles, register: register, value: value)) }
        default:
            // (The copper's, the blitter's, the display's: nothing a player of music is heard by.)
            break
        }
    }

    /// Keeps a change to the filter, as CIA-A's first port now has its line.
    private func noteFilter(at cycles: Int) {
        let on = cias[0].ddra & 2 != 0 && cias[0].pra & 2 == 0
        guard on != filterOn else { return }
        filterOn = on
        writes.append(AmigaWrite(cycles: cycles, register: AmigaWrite.filter, value: on ? 1 : 0))
    }
}
