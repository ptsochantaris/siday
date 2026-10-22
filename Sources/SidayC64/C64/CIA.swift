// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Start-up state, ROM stand-ins and timing rules follow libsidplayfp (GPL-2.0-or-later; see THIRD-PARTY.md).

/// MOS 6526 CIA, reduced to what music needs: the two interval timers and the interrupt register.
/// Timers are not stepped every cycle; a running timer remembers the cycle at which it will next
/// reload, and the machine schedules an event for it.
///
/// Cycle-level behaviour follows the original 6526 as libsidplayfp models it, established with probe
/// programs: a timer started at cycle w reloads at w + n + 2 (w + latch + 3 when the start also forces a
/// load); the counter never reads 0, it shows the reloaded value for two cycles instead; and the
/// interrupt line follows the underflow by one cycle. Sample players that synchronise to a timer and
/// branch on its value depend on exactly this.
struct CIA {
    struct Timer {
        var latch = 0xFFFF
        /// Counter value while stopped (or while counting timer A underflows).
        var counter = 0xFFFF
        var control: UInt8 = 0
        /// Cycle of the next reload while running from the system clock.
        var underflowAt = Int.max
        /// The value the counter was last loaded with, which it shows until it has counted below it.
        var ceiling = 0xFFFF

        var started: Bool { control & 0x01 != 0 }
        var oneShot: Bool { control & 0x08 != 0 }
    }

    var a = Timer()
    var b = Timer()
    var interruptData: UInt8 = 0
    var interruptMask: UInt8 = 0
    /// The chip's interrupt output (IRQ for CIA 1, NMI for CIA 2).
    var interruptLine = false
    /// Cycle at which a raised interrupt reaches the output pin.
    private var interruptLineAt = Int.max
    var portA: UInt8 = 0, portB: UInt8 = 0, directionA: UInt8 = 0, directionB: UInt8 = 0
    var serialData: UInt8 = 0
    /// Time of day in tenths of a second, as an offset from the cycle count.
    var todOffsetTenths = 0
    let cyclesPerTenth: Int

    init(clockHz: Double) {
        cyclesPerTenth = max(1, Int(clockHz / 10))
    }

    /// Earliest cycle at which a timer or the interrupt output needs attention.
    var nextEvent: Int { min(interruptLineAt, min(a.underflowAt, b.underflowAt)) }

    /// Timer B counts timer A underflows when CRB bits 5–6 select it.
    private var bCountsA: Bool { b.control & 0x40 != 0 }
    /// A timer counts system clock cycles only with its input-mode bits clear.
    private var aCountsClock: Bool { a.control & 0x20 == 0 }
    private var bCountsClock: Bool { b.control & 0x60 == 0 }

    @inline(__always) private func current(_ timer: Timer, _ clock: Int) -> Int {
        timer.underflowAt == Int.max ? timer.counter : min(timer.ceiling, max(1, timer.underflowAt - clock))
    }

    /// Sets an interrupt flag at cycle `at`; if it is enabled the output follows one cycle later.
    private mutating func raise(_ bit: UInt8, at: Int) {
        interruptData |= bit
        if interruptData & interruptMask & 0x1F != 0, !interruptLine {
            interruptLineAt = min(interruptLineAt, at + 1)
        }
    }

    /// Handles every underflow due at or before `clock`.
    mutating func runEvents(_ clock: Int) {
        while a.underflowAt <= clock {
            let at = a.underflowAt
            raise(0x01, at: at)
            a.ceiling = a.latch
            if a.oneShot {
                a.control &= ~0x01
                a.counter = a.latch
                a.underflowAt = Int.max
            } else {
                a.underflowAt += a.latch + 1
            }
            if b.started, bCountsA {
                if b.counter == 0 {
                    raise(0x02, at: at)
                    b.counter = b.latch
                    if b.oneShot { b.control &= ~0x01 }
                } else {
                    b.counter -= 1
                }
            }
        }
        while b.underflowAt <= clock {
            raise(0x02, at: b.underflowAt)
            b.ceiling = b.latch
            if b.oneShot {
                b.control &= ~0x01
                b.counter = b.latch
                b.underflowAt = Int.max
            } else {
                b.underflowAt += b.latch + 1
            }
        }
        if interruptLineAt <= clock {
            interruptLineAt = Int.max
            if interruptData & interruptMask & 0x1F != 0 { interruptLine = true }
        }
    }

    private static func setControl(_ timer: inout Timer, _ value: UInt8, clock: Int, countsClock: Bool, current: Int) {
        let wasRunning = timer.underflowAt != Int.max
        timer.counter = current
        timer.control = value & 0xEF
        let load = value & 0x10 != 0
        if load { timer.counter = timer.latch }
        guard timer.started, countsClock else {
            timer.underflowAt = Int.max
            return
        }
        // A timer that keeps running through a control write with no reload is not disturbed.
        if wasRunning, !load { return }
        timer.ceiling = timer.counter
        timer.underflowAt = clock + timer.counter + (load ? 3 : 2)
    }

    private func tod(_ clock: Int) -> Int {
        (clock / cyclesPerTenth + todOffsetTenths) % 864_000
    }

    private func bcd(_ value: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (value / 10) << 4 | (value % 10))
    }

    mutating func read(_ register: Int, clock: Int) -> UInt8 {
        switch register & 0x0F {
        case 0x00: return portA | ~directionA
        case 0x01: return portB | ~directionB
        case 0x02: return directionA
        case 0x03: return directionB
        case 0x04: return UInt8(truncatingIfNeeded: current(a, clock))
        case 0x05: return UInt8(truncatingIfNeeded: current(a, clock) >> 8)
        case 0x06: return UInt8(truncatingIfNeeded: current(b, clock))
        case 0x07: return UInt8(truncatingIfNeeded: current(b, clock) >> 8)
        case 0x08: return bcd(tod(clock) % 10)
        case 0x09: return bcd(tod(clock) / 10 % 60)
        case 0x0A: return bcd(tod(clock) / 600 % 60)
        case 0x0B:
            let hours24 = tod(clock) / 36000
            let hours12 = hours24 % 12 == 0 ? 12 : hours24 % 12
            return bcd(hours12) | (hours24 >= 12 ? 0x80 : 0)
        case 0x0C: return serialData
        case 0x0D:
            let value = interruptData | (interruptLine ? 0x80 : 0)
            interruptData = 0
            interruptLine = false
            interruptLineAt = Int.max
            return value
        case 0x0E: return a.control
        default: return b.control
        }
    }

    mutating func write(_ register: Int, _ value: UInt8, clock: Int) {
        switch register & 0x0F {
        case 0x00: portA = value
        case 0x01: portB = value
        case 0x02: directionA = value
        case 0x03: directionB = value
        case 0x04: a.latch = (a.latch & 0xFF00) | Int(value)
        case 0x05:
            a.latch = (a.latch & 0x00FF) | Int(value) << 8
            if !a.started { a.counter = a.latch }
        case 0x06: b.latch = (b.latch & 0xFF00) | Int(value)
        case 0x07:
            b.latch = (b.latch & 0x00FF) | Int(value) << 8
            if !b.started { b.counter = b.latch }
        case 0x08 ... 0x0B:
            // Setting the clock: keep it simple and restart the day at the written tenths.
            if register & 0x0F == 0x08 { todOffsetTenths = Int(value & 0x0F) - clock / cyclesPerTenth % 10 }
        case 0x0C: serialData = value
        case 0x0D:
            if value & 0x80 != 0 {
                interruptMask |= value & 0x1F
            } else {
                interruptMask &= ~(value & 0x1F)
            }
            if interruptData & interruptMask & 0x1F != 0, !interruptLine {
                interruptLineAt = min(interruptLineAt, clock + 1)
            }
        case 0x0E:
            Self.setControl(&a, value, clock: clock, countsClock: value & 0x20 == 0, current: current(a, clock))
        default:
            Self.setControl(&b, value, clock: clock, countsClock: value & 0x60 == 0, current: current(b, clock))
        }
    }
}
