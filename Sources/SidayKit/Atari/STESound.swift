// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AtariAudio, Copyright (c) Arnaud Carré, used under the MIT licence (see THIRD-PARTY.md).

/// The sample player the Atari STE added: it plays eight-bit samples straight out of memory, from one
/// address to another, at one of four rates, once or round and round, with a volume set over a
/// three-wire serial line. The two stereo channels are added into the one output here.
struct STESound {
    /// The fastest of its four rates; the others are a half, a quarter and an eighth of it.
    static let fullRate: UInt32 = 50066

    private let hostRate: UInt32
    private let registers: UnsafeMutablePointer<UInt8>
    private var position: UInt32 = 0
    private var end: UInt32 = 0
    private var innerClock: UInt32 = 0
    private var serialMask: UInt16 = 0
    private var serialData: UInt16 = 0
    private var serialShift = 0
    private var volume: Int32 = 64
    /// At the full rate two samples are added and given out as one, so that a tune which puts its
    /// voices in alternate bytes and lets the hardware do the mixing comes out mixed.
    private var pairing = false
    private var pair: Int32 = 0
    private var level: Int16 = 0

    init(hostRate: Int) {
        self.hostRate = UInt32(hostRate)
        registers = .allocate(capacity: 256)
        reset()
    }

    func deallocate() {
        registers.deallocate()
    }

    mutating func reset() {
        registers.initialize(repeating: 0, count: 256)
        position = 0
        innerClock = 0
        serialMask = 0
        serialShift = 0
        serialData = 0
        volume = 64
        level = 0
        pair = 0
        pairing = false
    }

    private mutating func latch() {
        position = UInt32(registers[3]) << 16 | UInt32(registers[5]) << 8 | UInt32(registers[7] & 0xFE)
        end = UInt32(registers[0x0F]) << 16 | UInt32(registers[0x11]) << 8 | UInt32(registers[0x13] & 0xFE)
    }

    mutating func write8(_ port: UInt32, _ value: UInt8) {
        let port = Int(port & 0xFF)
        guard port & 1 != 0 else { return }
        var value = value
        switch port {
        case 0x01:
            // Playing has just been switched on.
            if value & 1 != 0, (value ^ registers[1]) & 1 != 0 { latch() }
        case 0x07, 0x0D:
            value &= 0xFE
        case 0x21:
            if value & 3 != registers[0x21] & 3 {
                pair = 0
                pairing = false
            }
        default:
            break
        }
        registers[port] = value
    }

    mutating func write16(_ port: UInt32, _ value: UInt16) {
        let port = port & 0xFF
        guard port & 1 == 0 else { return }
        switch port {
        case 0x22:
            serialData = value
            serial()
            serialShift = 16
        case 0x24:
            serialMask = value
        default:
            write8(port + 1, UInt8(truncatingIfNeeded: value))
        }
    }

    func read8(_ port: UInt32) -> UInt8 {
        let port = Int(port & 0xFF)
        guard port & 1 != 0 else { return 0xFF }
        switch port {
        case 0x09: return UInt8(truncatingIfNeeded: position >> 16)
        case 0x0B: return UInt8(truncatingIfNeeded: position >> 8)
        case 0x0D: return UInt8(truncatingIfNeeded: position)
        default: return registers[port]
        }
    }

    mutating func read16(_ port: UInt32) -> UInt16 {
        let port = port & 0xFF
        guard port & 1 == 0 else { return 0xFFFF }
        switch port {
        case 0x22:
            return serialData
        case 0x24:
            // The mask goes round as the bits go out, and tunes watch it to know when they have gone.
            if serialShift > 0 {
                serialMask = serialMask << 1 | serialMask >> 15
                serialShift -= 1
            }
            return serialMask
        default:
            return 0xFF00 | UInt16(read8(port + 1))
        }
    }

    /// A command has been sent down the serial line: the only one acted on is the master volume.
    private mutating func serial() {
        var value: UInt32 = 0, count: UInt32 = 0
        for bit in 0 ..< 16 where serialMask & (1 << UInt16(bit)) != 0 {
            if serialData & (1 << UInt16(bit)) != 0 { value |= 1 << count }
            count += 1
        }
        guard count == 11, value >> 9 == 2, (value >> 6) & 7 == 3 else { return }
        let data = Int32(value & 0x3F)
        volume = data > 40 ? 64 : data * 64 / 40
    }

    /// The next sample at the host's rate.
    @inline(__always) mutating func nextSample(ram: UnsafeMutablePointer<UInt8>, ramSize: UInt32, mfp: inout MFP) -> Int16 {
        guard registers[1] & 1 != 0 else {
            level = 0
            return 0
        }
        let mode = registers[0x21]
        innerClock &+= Self.fullRate >> (3 - UInt32(mode & 3))
        let stereo = mode & 0x80 == 0
        let fullRate = mode & 3 == 3
        while innerClock >= hostRate {
            if position == end {
                mfp.sampleEnded()
                latch()
                if registers[1] & 2 == 0 {
                    // Not set to go round: that was all.
                    registers[1] &= 0xFE
                    level = 0
                    break
                }
            }
            var sample = position < ramSize ? Int32(Int8(bitPattern: ram[Int(position)])) : 0
            if stereo, position &+ 1 < ramSize { sample += Int32(Int8(bitPattern: ram[Int(position) + 1])) }
            if fullRate {
                pair += sample
                pairing.toggle()
                if !pairing {
                    level = Int16(truncatingIfNeeded: (pair * volume) >> 1)
                    pair = 0
                }
            } else {
                level = Int16(truncatingIfNeeded: sample * volume)
            }
            position &+= stereo ? 2 : 1
            innerClock -= hostRate
        }
        return level
    }
}
