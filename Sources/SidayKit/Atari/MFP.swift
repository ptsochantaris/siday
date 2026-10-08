// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AtariAudio, Copyright (c) Arnaud Carré, used under the MIT licence (see THIRD-PARTY.md).

/// The MC68901, the Atari ST's timer chip, as far as music uses it: four timers that count down from
/// a number at a chosen fraction of the chip's clock and interrupt the processor each time they get
/// there. Tunes hang their special effects on them. A fifth line, the one the STE's sample player
/// pulls as it reaches the end of a sample, is treated as one more timer that counts a single event.
struct MFP: ~Copyable {
    static let clockHz: UInt32 = 2_457_600
    /// What each setting of a timer divides the clock by; 0 is stopped.
    private static let prescale: [UInt32] = [0, 4, 10, 16, 50, 64, 100, 200]

    enum Line: Int {
        case timerA = 0, timerB, timerC, timerD, sampleEnd
    }

    private struct Timer {
        var enabled = false
        var unmasked = false
        var control = 0
        var data: UInt8 = 0
        var reload: UInt8 = 0
        var innerClock: UInt32 = 0
        var externalEvent = false

        /// Counting the clock, as against counting events or standing still.
        var counts: Bool { control & 7 != 0 && control & 8 == 0 }

        mutating func restart() {
            innerClock = 0
            data = reload
        }

        mutating func setEnabled(_ on: Bool) {
            if on, !enabled, counts { restart() }
            enabled = on
        }

        mutating func setData(_ value: UInt8) {
            reload = value
            if control == 0 { restart() }
        }

        /// Moves on by one sample of the host's time. True if it reached nothing on the way.
        @inline(__always) mutating func tick(hostRate: UInt32) -> Bool {
            guard enabled else { return false }
            var fired = false
            if control & 8 != 0 {
                if externalEvent {
                    data &-= 1
                    if data == 0 {
                        data = reload
                        fired = true
                    }
                    externalEvent = false
                }
            } else if control & 7 != 0 {
                innerClock &+= MFP.clockHz / MFP.prescale[control & 7]
                while innerClock >= hostRate {
                    data &-= 1
                    if data == 0 {
                        data = reload
                        fired = true
                    }
                    innerClock -= hostRate
                }
            }
            return fired && unmasked
        }
    }

    private let hostRate: UInt32
    private let registers: UnsafeMutablePointer<UInt8>
    private var timers = (Timer(), Timer(), Timer(), Timer(), Timer())

    init(hostRate: Int) {
        self.hostRate = UInt32(hostRate)
        registers = .allocate(capacity: 256)
        reset()
    }

    deinit {
        registers.deallocate()
    }

    mutating func reset() {
        registers.initialize(repeating: 0, count: 256)
        timers = (Timer(), Timer(), Timer(), Timer(), Timer())
        // The system leaves timer C going, and tunes that put the system's settings back expect it.
        timers.2.enabled = true
        timers.2.unmasked = true
        // The line from the sample player: an event counter that counts to one.
        timers.4.control = 8
        timers.4.reload = 1
        timers.4.data = 1
    }

    /// The sample player has reached the end of its sample.
    mutating func sampleEnded() {
        timers.0.externalEvent = true
        timers.4.externalEvent = true
    }

    @inline(__always) mutating func tick(_ line: Int) -> Bool {
        switch line {
        case 0: timers.0.tick(hostRate: hostRate)
        case 1: timers.1.tick(hostRate: hostRate)
        case 2: timers.2.tick(hostRate: hostRate)
        case 3: timers.3.tick(hostRate: hostRate)
        default: timers.4.tick(hostRate: hostRate)
        }
    }

    /// The chip's registers are at the odd addresses.
    mutating func write8(_ port: UInt32, _ value: UInt8) {
        let port = Int(port & 255)
        guard port & 1 != 0 else { return }
        switch port {
        case 0x19: timers.0.control = Int(value & 0x0F)
        case 0x1B: timers.1.control = Int(value & 0x0F)
        case 0x1D:
            timers.2.control = Int((value >> 4) & 7)
            timers.3.control = Int(value & 7)
        case 0x1F: timers.0.setData(value)
        case 0x21: timers.1.setData(value)
        case 0x23: timers.2.setData(value)
        case 0x25: timers.3.setData(value)
        case 0x07:
            timers.0.setEnabled(value & 0x20 != 0)
            timers.1.setEnabled(value & 0x01 != 0)
            timers.4.setEnabled(value & 0x80 != 0)
        case 0x09:
            timers.2.setEnabled(value & 0x20 != 0)
            timers.3.setEnabled(value & 0x10 != 0)
        case 0x13:
            timers.0.unmasked = value & 0x20 != 0
            timers.1.unmasked = value & 0x01 != 0
            timers.4.unmasked = value & 0x80 != 0
        case 0x15:
            timers.2.unmasked = value & 0x20 != 0
            timers.3.unmasked = value & 0x10 != 0
        default:
            break
        }
        registers[port] = value
    }

    func read8(_ port: UInt32) -> UInt8 {
        let port = Int(port & 255)
        guard port & 1 != 0 else { return 0xFF }
        switch port {
        case 0x01: return registers[1] & 0x7F | 0x80
        case 0x1F: return timers.0.data
        case 0x21: return timers.1.data
        case 0x23: return timers.2.data
        case 0x25: return timers.3.data
        default: return registers[port]
        }
    }

    func read16(_ port: UInt32) -> UInt16 {
        0xFF00 | UInt16(read8(port &+ 1))
    }

    mutating func write16(_ port: UInt32, _ value: UInt16) {
        write8(port &+ 1, UInt8(truncatingIfNeeded: value))
    }
}
