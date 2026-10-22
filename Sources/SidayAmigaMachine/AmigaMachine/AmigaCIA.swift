// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Written against Commodore's description of the 8520 (the Amiga Hardware Reference Manual, appendix F),
// as far as music uses it.

/// One of the Amiga's two 8520s, the chips of its ports and timers: CIA-A at $BFE001, whose first port
/// holds the power light that switches the sound's filter, and CIA-B at $BFD000. Each has two timers
/// that count down at the E clock (a fifth of Paula's), from a number they are given, and say so by an
/// interrupt when they get past nought: a player that times itself sets one going.
///
/// The chip is moved on by the machine (`advance(by:)`), before anything reads or writes it and
/// between calls into a program's code.
struct AmigaCIA {
    /// Its registers, by their number (the address's bits 8 to 11).
    enum Register: Int {
        case pra = 0, prb, ddra, ddrb, talo, tahi, tblo, tbhi, todLow, todMid, todHigh, unused, sdr, icr, cra, crb
    }

    private struct Timer {
        var latch: UInt16 = 0xFFFF
        var counter: UInt16 = 0xFFFF
        var control: UInt8 = 0

        var running: Bool { control & 1 != 0 }
        var oneShot: Bool { control & 8 != 0 }

        /// Counts `ticks` of the E clock, and how many times it ran out on the way. A timer runs out on
        /// the count that would take it below nought, reloads from its latch, and in one-shot mode stops.
        @inline(__always) mutating func count(_ ticks: Int) -> Int {
            guard running, ticks > 0 else { return 0 }
            if ticks <= Int(counter) {
                counter &-= UInt16(ticks)
                return 0
            }
            var left = ticks - Int(counter) - 1
            counter = latch
            if oneShot {
                control &= ~1
                return 1
            }
            let period = Int(latch) + 1
            let more = left / period
            left -= more * period
            counter = latch &- UInt16(left)
            return 1 + more
        }
    }

    private var timers = InlineArray<2, Timer>(repeating: Timer())
    /// The two ports, as last written, and which of their lines are outputs.
    private(set) var pra: UInt8 = 0xFF, prb: UInt8 = 0xFF
    private(set) var ddra: UInt8 = 0, ddrb: UInt8 = 0
    /// Which of the interrupts are let through (the mask), and which have happened since the
    /// register was last read (the data). Bit 0 is timer A, bit 1 timer B.
    private var mask: UInt8 = 0
    private var flags: UInt8 = 0
    /// The time of day: frames for CIA-A, lines for CIA-B, which the machine moves on.
    var timeOfDay: UInt32 = 0
    private var serial: UInt8 = 0

    /// True while the chip is pulling its interrupt line: an interrupt it lets through has happened and
    /// has not been read.
    var interrupting: Bool { flags & mask & 0x1F != 0 }

    /// Moves the timers on by `ticks` of the E clock. Timer B, set to count timer A's running out, counts
    /// those instead; a timer set to count the CNT line counts nothing, for nothing is on it. Returns the
    /// interrupts that happened on the way (bit 0 timer A, bit 1 timer B), whether let through or not.
    @discardableResult @inline(__always)
    mutating func advance(by ticks: Int) -> UInt8 {
        let a = timers[0].control & 0x20 == 0 ? timers[0].count(ticks) : 0
        if a > 0 { flags |= 1 }
        let b: Int
        if timers[1].control & 0x60 == 0x40 {
            b = timers[1].count(a)
        } else if timers[1].control & 0x20 == 0 {
            b = timers[1].count(ticks)
        } else {
            b = 0
        }
        if b > 0 { flags |= 2 }
        return (a > 0 ? 1 : 0) | (b > 0 ? 2 : 0)
    }

    /// How many ticks of the E clock until a timer that counts them runs out, if it is going.
    func ticksToRunOut(_ timer: Int) -> Int? {
        guard timers[timer].running, timers[timer].control & 0x20 == 0, timer == 0 || timers[1].control & 0x40 == 0 else {
            return nil
        }
        return Int(timers[timer].counter) + 1
    }

    /// The interrupts let through, as the mask has them.
    var interruptMask: UInt8 { mask }

    /// How many ticks of the E clock until a timer whose interrupt is let through next runs out: nil if
    /// none will. (For the machine, which runs the processor no further than that before it looks.)
    var ticksToInterrupt: Int? {
        var soonest: Int?
        let a = timers[0].running && timers[0].control & 0x20 == 0 ? Int(timers[0].counter) + 1 : nil
        if mask & 1 != 0, let a { soonest = a }
        if mask & 2 != 0, timers[1].running {
            var b: Int?
            if timers[1].control & 0x60 == 0x40 {
                // Counting timer A's running out: the counter's worth of A's periods after A next does.
                if let a, !timers[0].oneShot { b = a + Int(timers[1].counter) * (Int(timers[0].latch) + 1) }
                else if let a, timers[1].counter == 0 { b = a }
            } else if timers[1].control & 0x20 == 0 {
                b = Int(timers[1].counter) + 1
            }
            if let b { soonest = min(soonest ?? b, b) }
        }
        return soonest
    }

    mutating func read(_ register: Int) -> UInt8 {
        switch Register(rawValue: register & 15) ?? .unused {
        // The lines that are inputs read high: no buttons are pressed and nothing is plugged in.
        case .pra: return pra & ddra | ~ddra
        case .prb: return prb & ddrb | ~ddrb
        case .ddra: return ddra
        case .ddrb: return ddrb
        case .talo: return UInt8(truncatingIfNeeded: timers[0].counter)
        case .tahi: return UInt8(truncatingIfNeeded: timers[0].counter >> 8)
        case .tblo: return UInt8(truncatingIfNeeded: timers[1].counter)
        case .tbhi: return UInt8(truncatingIfNeeded: timers[1].counter >> 8)
        case .todLow: return UInt8(truncatingIfNeeded: timeOfDay)
        case .todMid: return UInt8(truncatingIfNeeded: timeOfDay >> 8)
        case .todHigh: return UInt8(truncatingIfNeeded: timeOfDay >> 16)
        case .unused: return 0xFF
        case .sdr: return serial
        case .icr:
            // Reading says what has happened, and forgets it.
            let value = flags | (interrupting ? 0x80 : 0)
            flags = 0
            return value
        case .cra: return timers[0].control & ~0x10
        case .crb: return timers[1].control & ~0x10
        }
    }

    mutating func write(_ register: Int, _ value: UInt8) {
        switch Register(rawValue: register & 15) ?? .unused {
        case .pra: pra = value
        case .prb: prb = value
        case .ddra: ddra = value
        case .ddrb: ddrb = value
        case .talo: setLatch(0, low: value)
        case .tahi: setLatch(0, high: value)
        case .tblo: setLatch(1, low: value)
        case .tbhi: setLatch(1, high: value)
        case .sdr: serial = value
        case .icr:
            // Bit 7 says whether the bits set are let through or held back.
            if value & 0x80 != 0 { mask |= value & 0x1F } else { mask &= ~value }
        case .cra: setControl(0, value)
        case .crb: setControl(1, value)
        case .todLow, .todMid, .todHigh, .unused: break
        }
    }

    private mutating func setLatch(_ timer: Int, low: UInt8) {
        timers[timer].latch = timers[timer].latch & 0xFF00 | UInt16(low)
    }

    /// The high byte: a timer standing still takes up its latch at once, and one in one-shot mode is
    /// started by it.
    private mutating func setLatch(_ timer: Int, high: UInt8) {
        timers[timer].latch = timers[timer].latch & 0x00FF | UInt16(high) << 8
        if !timers[timer].running { timers[timer].counter = timers[timer].latch }
        if timers[timer].oneShot {
            timers[timer].counter = timers[timer].latch
            timers[timer].control |= 1
        }
    }

    /// Bit 0 starts or stops, bit 3 is one-shot, and bit 4 loads the counter from the latch at once.
    private mutating func setControl(_ timer: Int, _ value: UInt8) {
        if value & 0x10 != 0 { timers[timer].counter = timers[timer].latch }
        timers[timer].control = value & ~0x10
    }

    /// Where the counter of a timer is, for a test.
    func counter(_ timer: Int) -> UInt16 { timers[timer].counter }
}
