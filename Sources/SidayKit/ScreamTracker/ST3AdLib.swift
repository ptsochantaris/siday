// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st3play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// The AdLib card as Scream Tracker used it: nine voices of FM beside the sixteen channels of
/// samples, each with an instrument that is eleven numbers for the card's chip.
///
/// The tracker works out a pitch for an AdLib channel as it does for a sample, and this turns it,
/// a tick at a time, into what the chip wants: a number for the pitch and one for the octave, a
/// level for the operators that are heard, and the note switched off and on again when it is struck
/// anew. Scream Tracker had drums for the card in mind and never finished them, so there are none.
///
/// The chip is the OPL3, which plays the AdLib's music as the AdLib's own chip did. What comes
/// out of it goes through the filter that kept the card's output centred, and is then brought from
/// the chip's rate to the player's.
final class ST3AdLib {
    private static let emptyadlibins: [UInt8] = [0, 0, 63, 63, 0, 0, 0, 0, 0, 0, 0, 0]
    /// Where each of the nine voices' first operator is among the chip's registers.
    private static let adlibiadd: [UInt8] = [0, 1, 2, 8, 9, 10, 16, 17, 18]

    private let module: ST3Module
    private let chip: UnsafeMutablePointer<OPL3Chip>
    /// What each register was last set to, so that none is set to what it already holds.
    private var adlibmem = [UInt8](repeating: 0xFC, count: 256)

    private let bufferL: UnsafeMutablePointer<Float>, bufferR: UnsafeMutablePointer<Float>
    private var resamplingFrac: UInt64 = 0
    private let resamplingDelta: UInt64
    // The filter that takes out what is steady: 3.18 Hz, from the parts on a Sound Blaster's board.
    private let b1: Float, a0: Float
    private var lastL: Float = 0, lastR: Float = 0

    init(module: ST3Module) {
        self.module = module
        chip = .allocate(capacity: 1)
        chip.initialize(to: OPL3Chip())
        bufferL = .allocate(capacity: 16)
        bufferR = .allocate(capacity: 16)
        bufferL.initialize(repeating: 0, count: 16)
        bufferR.initialize(repeating: 0, count: 16)
        resamplingDelta = UInt64((4_294_967_296.0 * (OPL3Chip.rate / Double(outputSampleRate))).rounded())
        b1 = Float(exp(-2.0 * Double.pi * 3.18309886184 / OPL3Chip.rate))
        a0 = 1.0 - b1

        // initadlib
        outaw(0x01, 0x20)
        outaw(0x08, 0x00)
        outaw(0xBD, 0x00)
        for ch in 0 ..< 9 {
            adlibloadins(ch, Self.emptyadlibins)
            outnote(ch, 0)
        }
    }

    deinit {
        chip.deinitialize(count: 1)
        chip.deallocate()
        bufferL.deallocate()
        bufferR.deallocate()
    }

    private func outaw(_ reg: Int, _ data: UInt8) {
        if data == adlibmem[reg & 0xFF] { return }
        adlibmem[reg & 0xFF] = data
        chip.pointee.OPL3_WriteRegBuffered(UInt16(reg & 0xFF), data)
    }

    private func outnote(_ channel: Int, _ note: UInt16) {
        outaw(0xA0 + channel, UInt8(truncatingIfNeeded: note))
        outaw(0xB0 + channel, UInt8(truncatingIfNeeded: note >> 8))
    }

    /// Gives a voice an instrument: eleven numbers, for the two operators' kind, level, attack and
    /// decay, sustain and release, and waveform, and for how the first bends the second.
    private func adlibloadins(_ channel: Int, _ ins: [UInt8]) {
        var reg = 0x20 + Int(Self.adlibiadd[channel])
        var at = 0
        for _ in 0 ..< 4 {
            outaw(reg, ins[at])
            outaw(reg + 3, ins[at + 1])
            at += 2
            reg += 32
        }
        reg += 64
        outaw(reg, ins[at])
        outaw(reg + 3, ins[at + 1])
        outaw(0xC0 + channel, ins[at + 2])
    }

    func adlibloadins(_ channel: Int, _ instrument: ST3Module.Instrument) {
        adlibloadins(channel, (0 ..< 12).map { instrument.adlib[$0] })
    }

    /// The instrument a voice was last given. A voice that has been given none since the tune began
    /// says 101, where Scream Tracker kept the instrument of its library and a module has nothing:
    /// its level is then not set at all, there being nothing to hear on it.
    private func instrument(_ number: Int, _ zchn: [ST3Channel]) -> ST3Module.Instrument? {
        if number <= module.ins.count { return module.ins[number - 1] }
        guard ST3Player.repeatsReferenceSlips else { return nil }
        // The player this is ported from reads past its instruments there, into its first channel,
        // and sets a level from what it finds.
        var found = ST3Module.Instrument()
        found.adlib[2] = zchn[0].lastnote
        found.adlib[3] = zchn[0].alastnfo
        found.adlib[10] = UInt8(truncatingIfNeeded: zchn[0].aspd)
        return found
    }

    /// After a tick: every voice's pitch and level told to the chip.
    func updateadlib(_ zchn: [ST3Channel]) {
        for i in 0 ..< 9 {
            let ch = zchn[16 + i]
            if ch.addherzhi & 32768 == 0 {
                // From a pitch in hertz to the chip's number and octave.
                var hz = (UInt32(ch.addherzhi) << 16) | UInt32(ch.addherzlo)
                hz <<= 1
                var block: UInt8 = 0
                while hz >= 3125 {
                    block &+= 1
                    hz >>= 1
                }
                block = (block << 2) | 32
                hz <<= 10
                let fnum = UInt16(truncatingIfNeeded: hz / 3125)
                let note = (UInt16(block) << 8) | fnum
                if ch.addherzretrig != 0 { outnote(i, note & 0xDFFF) } // the key let go
                if ch.addherzretrig != 254 { outnote(i, note) }
            }
            ch.addherzhi |= 32768

            if ch.addherzretrigvol != 0, ch.lastadlins > 0, let ins = instrument(Int(ch.lastadlins), zchn) {
                /// An operator's level with the channel's volume worked in. (The chip's levels are
                /// how much quieter than full, so it is turned over and back.)
                func level(_ own: UInt8) -> UInt8 {
                    var volOut = (0 &- (own & 63)) &+ 63
                    if ch.avol < 63 {
                        var vol = UInt8(bitPattern: ch.avol)
                        if vol != 0 { vol &+= 1 }
                        volOut = UInt8(truncatingIfNeeded: (Int(volOut) * Int(vol)) >> 6)
                    }
                    volOut = (0 &- volOut) &+ 63
                    return volOut | (own & (64 | 128))
                }
                // The first operator is heard only where the two are added.
                if ins.adlib[10] & 1 != 0 { outaw(0x40 + Int(Self.adlibiadd[i]), level(ins.adlib[2])) }
                outaw(0x43 + Int(Self.adlibiadd[i]), level(ins.adlib[3]))
            }
            ch.addherzretrig = 0
        }
    }

    /// How loud each of the card's nine voices was in the samples made since this was last asked:
    /// they are the channels from the sixteenth on.
    func takeLevels(into levels: inout [Float]) {
        levels.withUnsafeMutableBufferPointer { levels in
            guard let first = levels.baseAddress, levels.count >= 25 else { return }
            chip.pointee.takeLevels(into: first + 16, count: 9)
        }
    }

    /// The pitch each of the nine voices is set to: they are the channels from the sixteenth on.
    func takePitches(into pitches: inout [Float]) {
        pitches.withUnsafeMutableBufferPointer { pitches in
            guard let first = pitches.baseAddress, pitches.count >= 25 else { return }
            withUnsafeTemporaryAllocation(of: Bool.self, capacity: 9) { struck in
                guard let struck = struck.baseAddress else { return }
                chip.pointee.takeNotes(pitches: first + 16, struck: struck, count: 9)
            }
        }
    }

    /// Adds `count` samples of the card to what the sound card has made, which is first made quieter
    /// to leave room for it.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int, sinc: UnsafePointer<Float>) {
        var frac = resamplingFrac
        let delta = resamplingDelta
        for n in 0 ..< count {
            frac &+= delta
            while frac >= 1 << 32 {
                frac -= 1 << 32
                for i in 0 ..< 15 {
                    bufferL[i] = bufferL[i + 1]
                    bufferR[i] = bufferR[i + 1]
                }
                let made = chip.pointee.OPL3_Generate()
                var l = Float(made.left) * (1.0 / 32768.0), r = Float(made.right) * (1.0 / 32768.0)
                lastL = (l * a0) + (lastL * b1)
                l -= lastL
                lastR = (r * a0) + (lastR * b1)
                r -= lastR
                bufferL[15] = l
                bufferR[15] = r
            }
            let frac32 = UInt32(truncatingIfNeeded: frac)
            let phase = Int(frac32 >> 24)
            let between = Float(Int32(frac32 & 0xFF_FFFF)) * (1.0 / 16_777_216.0)
            let sinc1 = sinc + (phase << 4), sinc2 = sinc + ((phase + 1) << 4)
            var sumL: Float = 0, sumR: Float = 0
            for i in 0 ..< 16 {
                let y1 = sinc1[i], y2 = sinc2[i]
                let y = y1 + ((y2 - y1) * between)
                sumL += bufferL[i] * y
                sumR += bufferR[i] * y
            }
            left[n] = left[n] * (2.0 / 3.0) + sumL
            right[n] = right[n] * (2.0 / 3.0) + sumR
        }
        resamplingFrac = frac
    }
}
