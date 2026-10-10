// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// An AdLib or Sound Blaster card playing by itself: the FM chip, the filter on the card's board
/// that kept what came out of it centred, and the step from the chip's rate to the player's.
///
/// A player of FM music works in ticks of the PC's timer, and sets the chip's registers on each.
/// So the card is told how many of the chip's samples there are until the next tick, and makes
/// sound until it has made them all.
final class OPLCard {
    private let chip: UnsafeMutablePointer<OPL3Chip>
    /// The chip's last sixteen samples, filtered.
    private let window: UnsafeMutablePointer<Float>
    private let sinc: UnsafeMutablePointer<Float>
    /// Where the next of the player's samples lies among the chip's, in 2^-32s of one of them:
    /// at 2^32 and beyond, the chip has another to make first.
    private var position: UInt64 = 1 << 32
    private let step: UInt64
    // The filter that takes out what is steady: 3.18 Hz, from the parts on a Sound Blaster's board.
    private let b1: Float, a0: Float
    private var steady: Float = 0

    /// How many of the chip's samples are still to be made before the next tick.
    var samplesLeft = 0

    init() {
        chip = .allocate(capacity: 1)
        chip.initialize(to: OPL3Chip())
        window = .allocate(capacity: 16)
        window.initialize(repeating: 0, count: 16)
        sinc = .allocate(capacity: st3Sinc.count)
        for i in 0 ..< st3Sinc.count { sinc[i] = st3Sinc[i] }
        step = UInt64((4_294_967_296.0 * (OPL3Chip.rate / Double(outputSampleRate))).rounded())
        b1 = Float(exp(-2.0 * Double.pi * 3.18309886184 / OPL3Chip.rate))
        a0 = 1.0 - b1
    }

    deinit {
        chip.deinitialize(count: 1)
        chip.deallocate()
        window.deallocate()
        sinc.deallocate()
    }

    /// The card as it is when the PC is switched on.
    func reset() {
        chip.deinitialize(count: 1)
        chip.initialize(to: OPL3Chip())
        window.update(repeating: 0, count: 16)
        position = 1 << 32
        steady = 0
        samplesLeft = 0
    }

    /// Sets one of the chip's registers. A program could not set two at once: each took the chip a
    /// moment, and so each here lands a little after the one before.
    @inline(__always) func write(_ register: Int, _ value: UInt8) {
        chip.pointee.OPL3_WriteRegBuffered(UInt16(register & 0xFF), value)
    }

    /// Makes sound at the player's rate, both sides alike, until `frames` are made or the chip has
    /// made all of `samplesLeft`, whichever is first.
    /// - Parameter fade: if not nought, the sound is turned down over the last so many of
    ///   `samplesLeft`, to nothing at the last.
    /// - Returns: how many frames were made.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int = 0) -> Int {
        var made = 0
        var position = position
        while made < frames {
            if position >= 1 << 32 {
                if samplesLeft == 0 { break }
                samplesLeft -= 1
                position -= 1 << 32
                for i in 0 ..< 15 { window[i] = window[i + 1] }
                var sample = Float(chip.pointee.OPL3_Generate().left) * (1.0 / 32768.0)
                steady = (sample * a0) + (steady * b1)
                sample -= steady
                window[15] = sample
                continue
            }
            let low = UInt32(truncatingIfNeeded: position)
            let phase = Int(low >> 24)
            let between = Float(Int32(low & 0xFF_FFFF)) * (1.0 / 16_777_216.0)
            let sinc1 = sinc + (phase << 4), sinc2 = sinc + ((phase + 1) << 4)
            var sum: Float = 0
            for i in 0 ..< 16 {
                let y1 = sinc1[i], y2 = sinc2[i]
                sum += window[i] * (y1 + ((y2 - y1) * between))
            }
            sum *= samplesLeft < fade ? gain * Float(samplesLeft) / Float(fade) : gain
            buffer[made * 2] = sum
            buffer[made * 2 + 1] = sum
            made += 1
            position += step
        }
        self.position = position
        return made
    }

    /// How loud each of the chip's nine voices has been since this was last asked.
    func takeLevels(into levels: UnsafeMutablePointer<Float>) {
        chip.pointee.takeLevels(into: levels, count: 9)
    }

    /// What each of them is playing.
    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        chip.pointee.takeNotes(pitches: pitches, struck: struck, count: 9)
    }

    /// One sample as the chip makes it, at the chip's own rate and before anything else is done to
    /// it: for comparing with a reference player.
    func raw() -> Int16 {
        samplesLeft -= 1
        return chip.pointee.OPL3_Generate().left
    }
}
