// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from MAME's sn76496.c, by Nicola Salmoria with contributions by others, used under the
// BSD 3-Clause licence (see THIRD-PARTY.md), as libvgm has it.
//
// Texas Instruments' SN76489 (1980), and the chips made like it: three square waves and a noise,
// each at one of sixteen volumes 2 dB apart. It was the sound of the BBC Micro, the Sega Master
// System and, as the NCR8496 and the PSSJ-3, of IBM's PCjr and the Tandy 1000 that followed it. The
// chips differ in their noise: how long its shift register is, which of its bits make the next, and
// whether they are added or their opposite is; a VGM file says which. A channel held at a period
// of one or less stays where its volume puts it, and so plays what is written to its volume: samples.

/// How a chip of the kind makes its noise, and the rest of what tells one from another.
struct SN76489Variant {
    /// Which bits of the shift register make its next bit (two, usually), and how long it is.
    var taps = 0x0009, width = 16
    /// True for the Sega chips, which take a period of nought as nought and not as 1,024.
    var sega = true
    /// True for the NCR8496 and the PSSJ-3: their next bit is the opposite of the two added, and
    /// their shift register starts again only when the noise is changed from one kind to the other.
    var ncr = false
    /// True for the chip that is the Game Gear's, which can put each channel on either side or both.
    var stereo = false
    /// How many of its clock's cycles each of its steps is: 8 for most, 1 for those without the divider.
    var divider = 8
}

struct SN76489Chip {
    private let variant: SN76489Variant
    private let feedback: UInt32, tap1: UInt32, tap2: UInt32
    private var registers = InlineArray<8, UInt16>(repeating: 0)
    private var lastRegister = 0
    /// Each channel's volume, out of 1; the noise's last.
    private(set) var volumes = InlineArray<4, Double>(repeating: 0)
    private var periods = InlineArray<4, Int>(repeating: 0)
    private var counts = InlineArray<4, Int>(repeating: 0)
    private var outputs = InlineArray<4, Bool>(repeating: false)
    private var shift: UInt32
    /// The Game Gear's: a bit for each channel on the left, from the fifth up, and on the right.
    private(set) var stereoMask: UInt8 = 0xFF
    /// Channels left out of the sound.
    var muted = InlineArray<4, Bool>(repeating: false)
    /// For what is shown of the voices: how loud each has been since this was last asked, and
    /// whether its volume has jumped up.
    private var reach = InlineArray<4, Double>(repeating: 0)
    private var struck = InlineArray<4, Bool>(repeating: false)

    /// The sixteen volumes, the last silence.
    private static let table: [Double] = (0 ..< 16).map { $0 == 15 ? 0 : pow(2, Double($0) / -3) }

    init(_ variant: SN76489Variant) {
        self.variant = variant
        var found: [UInt32] = []
        for bit in 0 ..< variant.width where variant.taps & (1 << bit) != 0 && found.count < 2 { found.append(1 << UInt32(bit)) }
        tap1 = found.count > 0 ? found[0] : 0
        tap2 = found.count > 1 ? found[1] : 0
        feedback = 1 << UInt32(variant.width - 1)
        shift = feedback
        reset()
    }

    mutating func reset() {
        for channel in 0 ..< 4 {
            volumes[channel] = 0
            periods[channel] = 0
            counts[channel] = 0
            outputs[channel] = false
            reach[channel] = 0
            struck[channel] = false
        }
        for register in 0 ..< 8 { registers[register] = 0 }
        lastRegister = variant.sega ? 3 : 0
        shift = feedback
        outputs[3] = shift & 1 != 0
        stereoMask = 0xFF
    }

    mutating func write(_ data: UInt8) {
        let r: Int
        if data & 0x80 != 0 {
            r = Int(data >> 4) & 7
            lastRegister = r
            if variant.ncr, r == 6, data & 0x04 != UInt8(registers[6] & 0x04) { shift = feedback }
            registers[r] = registers[r] & 0x3F0 | UInt16(data & 0x0F)
        } else {
            r = lastRegister
        }
        let channel = r >> 1
        switch r {
        case 0, 2, 4:
            if data & 0x80 == 0 { registers[r] = registers[r] & 0x0F | UInt16(data & 0x3F) << 4 }
            periods[channel] = registers[r] != 0 || variant.sega ? Int(registers[r]) : 0x400
            if r == 4, registers[6] & 3 == 3 { periods[3] = periods[2] << 1 }
        case 1, 3, 5, 7:
            let volume = Self.table[Int(data & 0x0F)]
            if volume > volumes[channel] * 1.5 + 0.01 { struck[channel] = true }
            volumes[channel] = volume
            if data & 0x80 == 0 { registers[r] = registers[r] & 0x3F0 | UInt16(data & 0x0F) }
        default: // 6: the noise's rate and kind
            if data & 0x80 == 0 { registers[r] = registers[r] & 0x3F0 | UInt16(data & 0x0F) }
            let n = Int(registers[6] & 3)
            periods[3] = n == 3 ? periods[2] << 1 : 1 << (5 + n)
            if !variant.ncr { shift = feedback }
        }
    }

    mutating func writeStereo(_ data: UInt8) {
        if variant.stereo { stereoMask = data }
    }

    /// One of the chip's steps: what it makes, left and right, each channel from -1/2 to 1/2 at its
    /// loudest, as MAME has it (made to swing both ways, and halved for that).
    @inline(__always) mutating func step() -> (Double, Double) {
        for channel in 0 ..< 3 {
            counts[channel] &-= 1
            if counts[channel] <= 0 {
                outputs[channel].toggle()
                counts[channel] = periods[channel]
            }
        }
        counts[3] &-= 1
        if counts[3] <= 0 {
            // (In the noise's periodic kind the second tap is held where it adds nothing.)
            let first = shift & tap1 != 0
            let second = shift & tap2 != (variant.ncr ? tap2 : 0) && registers[6] & 4 != 0
            shift = first != second ? shift >> 1 | feedback : shift >> 1
            outputs[3] = shift & 1 != 0
            counts[3] = periods[3]
        }
        var left = 0.0, right = 0.0
        for channel in 0 ..< 4 where !muted[channel] {
            let volume = volumes[channel]
            let level = channel == 3 || periods[channel] > 1 ? (outputs[channel] ? volume : -volume) : volume
            if level != 0 { reach[channel] = max(reach[channel], abs(level)) }
            if variant.stereo {
                if stereoMask & (0x10 << UInt8(channel)) != 0 { left += level }
                if stereoMask & (0x01 << UInt8(channel)) != 0 { right += level }
            } else {
                left += level
            }
        }
        return variant.stereo ? (left * 0.5, right * 0.5) : (left * 0.5, left * 0.5)
    }

    mutating func takeLevels(into levels: UnsafeMutablePointer<Float>) {
        for channel in 0 ..< 4 {
            levels[channel] = Float(reach[channel])
            reach[channel] = 0
        }
    }

    /// What a channel puts out now, as `step` adds it in, from -1 to 1 at its loudest: for the
    /// channel's scope, read once one of the player's samples is made, so that the chip itself does
    /// nothing more. A channel left out of the sound is told too.
    func channelOutput(_ channel: Int) -> Double {
        let volume = volumes[channel]
        return channel == 3 || periods[channel] > 1 ? (outputs[channel] ? volume : -volume) : volume
    }

    /// Each channel's pitch, a tone's by its period; and whether its volume has jumped up.
    mutating func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>, clock: Double) {
        for channel in 0 ..< 4 {
            let period = periods[channel]
            pitches[channel] = channel < 3 && period > 6 && volumes[channel] > 0
                ? ChannelPitch.note(ofHz: clock / Double(variant.divider * 4 * period)) : 0
            struck[channel] = self.struck[channel]
            self.struck[channel] = false
        }
    }

    /// Where each channel is: the Game Gear's between the sides, every other chip's in the middle.
    func sides(into sides: UnsafeMutablePointer<Float>) {
        for channel in 0 ..< 4 {
            let left = stereoMask & (0x10 << UInt8(channel)) != 0, right = stereoMask & (0x01 << UInt8(channel)) != 0
            sides[channel] = !variant.stereo || left == right ? 0 : left ? -1 : 1
        }
    }
}
