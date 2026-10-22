// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayM68000

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

    // (These, and `writes`, `signals` and `audio`, which are changed in place with each access the
    // processor makes to the chips, are not checked as they are used for being used twice over at once:
    // the compiler cannot prove it of a class's properties and checks each use, at the rate the processor
    // runs. None of them is: the chips call nothing beyond themselves while one is being changed.)

    /// CIA-A, then CIA-B.
    @exclusivity(unchecked) var cias = InlineArray<2, AmigaCIA>(repeating: AmigaCIA())
    @exclusivity(unchecked) private(set) var dmacon: UInt16 = 0
    @exclusivity(unchecked) private(set) var intena: UInt16 = 0
    @exclusivity(unchecked) private(set) var intreq: UInt16 = 0
    @exclusivity(unchecked) private(set) var adkcon: UInt16 = 0
    /// The writes to Paula and the DMA made since they were last taken, in order; and what the host's
    /// code has told it through its port.
    @exclusivity(unchecked) var writes: [AmigaWrite] = []
    @exclusivity(unchecked) var signals: [AmigaWrite] = []
    /// The time as the current call began, in Paula's clocks since the machine was switched on.
    var clock: UInt64 = 0
    /// How far the CIAs have been moved on, in ticks of the E clock (a fifth of Paula's).
    private var eTicks: UInt64 = 0
    /// Whether the filter was on, by the power light, as last told.
    private var filterOn = false

    /// Whether the chips ask for the processor's interrupts, as the hardware does: the beam's frame
    /// (VERTB), the CIAs' timers (PORTS and EXTER), Paula's voices (AUD0 to AUD3) and the program's own
    /// (SOFT). Off, as it is for a player whose host calls its code itself, nothing asks: INTREQ holds
    /// only what the program writes to it, and the chips are as they were before this was made.
    ///
    /// On, the frames are as UADE's UAE has them: short ones, of 312 lines (its long-frame bit, which only
    /// an interlaced display changes, is clear as it starts), and VPOSR says so. Off, every frame is a long
    /// one of 313, as the players called a tick at a time were made with.
    var interrupts = false {
        didSet {
            frameClocks = UInt64(Self.lineClocks * (interrupts ? Self.shortFrameLines : Self.frameLines))
            nextFrame = (clock / frameClocks + 1) * frameClocks
        }
    }
    /// Set by a write that may ask for an interrupt, while `interrupts` is on: to the interrupts' enables
    /// and requests, the DMA, Paula's voices, or a CIA. The processor stops after the instruction that
    /// made it (`M68000Bus.asksToBeLookedAt`), and the machine looks, as UAE does after the next.
    var wroteInterrupts = false
    override var asksToBeLookedAt: Bool { wroteInterrupts }

    /// A short frame's lines.
    static let shortFrameLines = 312
    /// A frame's length, in Paula's clocks.
    private(set) var frameClocks = UInt64(lineClocks * frameLines)
    /// When the next frame begins, for its interrupt, in Paula's clocks.
    private var nextFrame = UInt64(lineClocks * frameLines)
    /// When each voice asks for its interrupt (while `interrupts` is on).
    @exclusivity(unchecked) private var audio = AmigaAudioDMA()

    override init() {
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
        interrupts = false
        nextFrame = UInt64(Self.lineClocks * Self.frameLines)
        audio = AmigaAudioDMA()
    }

    /// The time, `cycles` into the current call.
    @inline(__always) func now(_ cycles: Int) -> UInt64 { clock &+ UInt64(max(0, cycles)) / 2 }

    /// The line the beam is on, and how far along it, at a time.
    static func beam(at time: UInt64) -> (line: Int, position: Int) {
        let inFrame = Int(time % UInt64(lineClocks * frameLines))
        return (inFrame / lineClocks, inFrame % lineClocks)
    }

    /// Brings the chips up to the time, `cycles` into the current call: the CIAs' timers, and, while the
    /// chips interrupt, the beam's frames and Paula's voices.
    func catchUp(_ cycles: Int) {
        let time = now(cycles)
        let e = time / 5
        if e > eTicks {
            let ticks = Int(min(e - eTicks, UInt64(Int32.max)))
            let a = cias[0].advance(by: ticks)
            let b = cias[1].advance(by: ticks)
            eTicks = e
            // A timer let through asks for its CIA's interrupt as it runs out (UAE's `RethinkICR`).
            if interrupts {
                if a & cias[0].interruptMask != 0 { intreq |= 0x0008 }
                if b & cias[1].interruptMask != 0 { intreq |= 0x2000 }
            }
        }
        guard interrupts else { return }
        if time >= nextFrame {
            intreq |= 0x0020
            nextFrame = (time / frameClocks + 1) * frameClocks
        }
        audio.run(to: time, intreq: &intreq, adkcon: adkcon)
    }

    // MARK: Interrupts

    /// The level of the interrupt the chips ask the processor for now (nought for none): the highest
    /// of those requested and enabled, while the master enable (INTEN) is on.
    var interruptLevel: Int {
        guard interrupts, intena & 0x4000 != 0 else { return 0 }
        let asked = intena & intreq & 0x3FFF
        if asked == 0 { return 0 }
        // TBE, DSKBLK, SOFT 1; PORTS 2; COPER, VERTB, BLIT 3; AUD0-3 4; RBF, DSKSYN 5; EXTER 6.
        if asked & 0x2000 != 0 { return 6 }
        if asked & 0x1800 != 0 { return 5 }
        if asked & 0x0780 != 0 { return 4 }
        if asked & 0x0070 != 0 { return 3 }
        if asked & 0x0008 != 0 { return 2 }
        return 1
    }

    /// When a CIA's timer next runs out, in Paula's clocks, if it is going (as the chips were last
    /// brought up to time).
    func timerRunsOut(cia: Int, timer: Int) -> UInt64? {
        cias[cia].ticksToRunOut(timer).map { (eTicks + UInt64($0)) * 5 }
    }

    /// The soonest time after `time` at which something may ask for an interrupt that is enabled: the
    /// next frame, a CIA's timer running out, or a voice of Paula's.
    func nextInterrupt(after time: UInt64) -> UInt64 {
        var soonest = nextTimedInterrupt
        guard interrupts else { return soonest }
        if intena & 0x0780 != 0, let next = audio.nextEvent { soonest = min(soonest, next) }
        return max(soonest, time)
    }

    /// The same, by `limit` at the latest, and for Paula's voices not the soonest they may ask but when one
    /// does (`AmigaAudioDMA.nextRequest`), for a processor that has none asked for that it does not take:
    /// until something asks, it may be left to run, since nothing it does before then is told apart by when
    /// it is looked at. Nil where that cannot be said (see `AmigaAudioDMA.canTellRequests`).
    func nextRequest(after time: UInt64, by limit: UInt64) -> UInt64? {
        var soonest = min(limit, nextTimedInterrupt)
        guard interrupts else { return max(soonest, time) }
        let voices = intena & 0x0780
        if voices != 0, intena & 0x4000 != 0 {
            guard AmigaAudioDMA.canTellRequests(of: voices, adkcon: adkcon) else { return nil }
            if let next = audio.nextRequest(of: voices, intreq: intreq, adkcon: adkcon, by: soonest) { soonest = min(soonest, next) }
        }
        return max(soonest, time)
    }

    /// When the next frame or a CIA's timer asks for an interrupt that is enabled.
    private var nextTimedInterrupt: UInt64 {
        var soonest = UInt64.max
        guard interrupts else { return soonest }
        if intena & 0x0020 != 0 { soonest = nextFrame }
        for c in 0 ..< 2 where intena & (c == 0 ? 0x0008 : 0x2000) != 0 {
            if let ticks = cias[c].ticksToInterrupt { soonest = min(soonest, (eTicks + UInt64(ticks)) * 5) }
        }
        return soonest
    }


    /// True while the filter is on: the power light's line is an output, and low.
    var lightFilter: Bool { filterOn }

    // MARK: The bus

    override func read8(_ address: UInt32) -> UInt8 { read8(address, at: 0) }
    override func read16(_ address: UInt32) -> UInt16 { read16(address, at: 0) }
    override func write8(_ address: UInt32, _ value: UInt8) { write8(address, value, at: 0) }
    override func write16(_ address: UInt32, _ value: UInt16) { write16(address, value, at: 0) }

    override func read8(_ address: UInt32, at cycles: Int) -> UInt8 {
        if address & 0xFFF000 == Self.custom {
            let word = readCustom(UInt16(address & 0xFFE), at: cycles)
            return UInt8(truncatingIfNeeded: address & 1 == 0 ? word >> 8 : word)
        }
        if address & 0xFF0000 == 0xBF0000 {
            catchUp(cycles)
            // (Their times of day, which nothing else reads: frames for CIA-A, lines for CIA-B.)
            let time = now(cycles)
            cias[0].timeOfDay = UInt32(truncatingIfNeeded: time / frameClocks)
            cias[1].timeOfDay = UInt32(truncatingIfNeeded: time / UInt64(Self.lineClocks))
            if address & 1 == 1, address & 0x1000 == 0 { return cias[0].read(Int(address >> 8 & 15)) }
            if address & 1 == 0, address & 0x2000 == 0 { return cias[1].read(Int(address >> 8 & 15)) }
            return 0xFF
        }
        return 0
    }

    override func read16(_ address: UInt32, at cycles: Int) -> UInt16 {
        if address & 0xFFF000 == Self.custom { return readCustom(UInt16(address & 0xFFE), at: cycles) }
        if address & 0xFF0000 == 0xBF0000 {
            // The high byte from CIA-B, the low from CIA-A.
            return UInt16(read8(address & ~1, at: cycles)) << 8 | UInt16(read8(address | 1, at: cycles))
        }
        return 0
    }

    override func write8(_ address: UInt32, _ value: UInt8, at cycles: Int) {
        if address & 0xFFF000 == Self.custom {
            // The 68000 puts a byte on both halves of the bus, and the chips take the whole word.
            writeCustom(UInt16(address & 0xFFE), UInt16(value) << 8 | UInt16(value), at: cycles)
            return
        }
        if address & 0xFF0000 == 0xBF0000 {
            catchUp(cycles)
            if interrupts { wroteInterrupts = true }
            if address & 1 == 1, address & 0x1000 == 0 {
                cias[0].write(Int(address >> 8 & 15), value)
                noteFilter(at: cycles)
                if interrupts, cias[0].interrupting, address >> 8 & 15 == 13 { intreq |= 0x0008 }
            }
            if address & 1 == 0, address & 0x2000 == 0 {
                cias[1].write(Int(address >> 8 & 15), value)
                if interrupts, cias[1].interrupting, address >> 8 & 15 == 13 { intreq |= 0x2000 }
            }
            return
        }
        if address & 0xFF0000 == Self.hostPort {
            signals.append(AmigaWrite(cycles: cycles, register: UInt16(address & 0xFFFF), value: UInt16(value)))
        }
    }

    override func write16(_ address: UInt32, _ value: UInt16, at cycles: Int) {
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

    /// The line the beam is on, as VPOSR and the upper byte of VHPOSR give it, changes only as a line
    /// begins; nothing else that is read is told of.
    override func unchanged(_ address: UInt32, word: Bool, from cycles: Int) -> Int? {
        guard address & 0xFFF000 == Self.custom else { return nil }
        switch address & 0xFFF {
        case 0x004, 0x005: break
        case 0x006 where !word: break
        default: return nil
        }
        let line = UInt64(Self.lineClocks)
        let next = (now(cycles) / line + 1) * line
        return Int(clamping: (next &- clock) &* 2)
    }

    // MARK: The custom chips

    private func readCustom(_ register: UInt16, at cycles: Int) -> UInt16 {
        if interrupts { catchUp(cycles) }
        switch register {
        case 0x002: return dmacon & 0x07FF
        case 0x004, 0x006:
            if interrupts {
                // A short frame (bit 15 of VPOSR clear).
                let inFrame = Int(now(cycles) % frameClocks)
                let line = inFrame / Self.lineClocks, position = inFrame % Self.lineClocks
                return register == 0x004 ? UInt16(line >> 8) : UInt16(line & 0xFF) << 8 | UInt16(position)
            }
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
        if interrupts {
            catchUp(cycles)
            if register == 0x96 || register == 0x9A || register == 0x9C || register >= 0xA0 && register < 0xE0 { wroteInterrupts = true }
        }
        switch register {
        case 0x096:
            dmacon = Self.setOrClear(dmacon, value)
            writes.append(AmigaWrite(cycles: cycles, register: register, value: value))
            if interrupts { audio.setDMA(dmacon, at: now(cycles)) }
        case 0x09A, 0x09C:
            if register == 0x09A { intena = Self.setOrClear(intena, value) } else { intreq = Self.setOrClear(intreq, value) }
            // (Kept with the rest while the chips interrupt, for a host to see; Paula takes no notice.)
            if interrupts { writes.append(AmigaWrite(cycles: cycles, register: register, value: value)) }
        case 0x09E:
            adkcon = Self.setOrClear(adkcon, value)
            writes.append(AmigaWrite(cycles: cycles, register: register, value: value))
        case 0x0A0 ..< 0x0E0:
            if register & 0xF < 0xC { writes.append(AmigaWrite(cycles: cycles, register: register, value: value)) }
            if interrupts { audio.write(Int(register - 0xA0) >> 4, register & 0xF, value, at: now(cycles), &intreq) }
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
