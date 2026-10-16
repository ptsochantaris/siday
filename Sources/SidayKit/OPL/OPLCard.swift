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
    /// The chip's last sixteen samples, filtered: of its left side, or of the one side it is heard
    /// from; and of its right, for a card heard in stereo (`renderStereo`).
    private let window: UnsafeMutablePointer<Float>
    private let windowRight: UnsafeMutablePointer<Float>
    private let sinc: UnsafeMutablePointer<Float>
    /// Where the next of the player's samples lies among the chip's, in 2^-32s of one of them:
    /// at 2^32 and beyond, the chip has another to make first.
    private var position: UInt64 = 1 << 32
    private let step: UInt64
    // The filter that takes out what is steady: 3.18 Hz, from the parts on a Sound Blaster's board.
    private let b1: Float, a0: Float
    private var steady: Float = 0, steadyRight: Float = 0

    /// How many of the chip's samples are still to be made before the next tick.
    var samplesLeft = 0
    /// The chip's channels left out of the sound, a bit for each: kept here, since a reset makes the
    /// chip anew.
    private var muted: UInt32 = 0

    /// - Parameter rate: how many samples a second the chip makes, which is what its clock makes it:
    ///   an OPL2's clock over 72, an OPL3's over 288. The usual clocks make the same.
    init(rate: Double = OPL3Chip.rate) {
        chip = .allocate(capacity: 1)
        chip.initialize(to: OPL3Chip())
        window = .allocate(capacity: 16)
        window.initialize(repeating: 0, count: 16)
        windowRight = .allocate(capacity: 16)
        windowRight.initialize(repeating: 0, count: 16)
        sinc = .allocate(capacity: st3Sinc.count)
        for i in 0 ..< st3Sinc.count { sinc[i] = st3Sinc[i] }
        step = UInt64((4_294_967_296.0 * (rate / Double(outputSampleRate))).rounded())
        b1 = Float(exp(-2.0 * Double.pi * 3.18309886184 / rate))
        a0 = 1.0 - b1
    }

    deinit {
        chip.deinitialize(count: 1)
        chip.deallocate()
        window.deallocate()
        windowRight.deallocate()
        sinc.deallocate()
    }

    /// The card as it is when the PC is switched on.
    func reset() {
        chip.deinitialize(count: 1)
        chip.initialize(to: OPL3Chip())
        chip.pointee.setMuted(muted)
        window.update(repeating: 0, count: 16)
        windowRight.update(repeating: 0, count: 16)
        position = 1 << 32
        steady = 0
        steadyRight = 0
        samplesLeft = 0
    }

    /// Sets one of the chip's registers. A program could not set two at once: each took the chip a
    /// moment, and so each here lands a little after the one before.
    @inline(__always) func write(_ register: Int, _ value: UInt8) {
        chip.pointee.OPL3_WriteRegBuffered(UInt16(register & 0xFF), value)
    }

    /// Sets one of an OPL3's registers, of either of its two sets: the ninth bit of the number chooses
    /// the second.
    @inline(__always) func writeEither(_ register: Int, _ value: UInt8) {
        chip.pointee.OPL3_WriteRegBuffered(UInt16(register & 0x1FF), value)
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

    /// The same, with the chip's two sides each on its own side: for an OPL3, which puts each channel
    /// on the left, the right or both, as it is told. An OPL2 has both sides alike.
    /// - Parameter after: how many of the chip's samples the fade has still to run after
    ///   `samplesLeft`, for a fade longer than what the card is given at once.
    func renderStereo(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int = 0, after: Int = 0) -> Int {
        var made = 0
        var position = position
        while made < frames {
            if position >= 1 << 32 {
                if samplesLeft == 0 { break }
                samplesLeft -= 1
                position -= 1 << 32
                for i in 0 ..< 15 {
                    window[i] = window[i + 1]
                    windowRight[i] = windowRight[i + 1]
                }
                let both = chip.pointee.OPL3_Generate()
                var left = Float(both.left) * (1.0 / 32768.0), right = Float(both.right) * (1.0 / 32768.0)
                steady = (left * a0) + (steady * b1)
                steadyRight = (right * a0) + (steadyRight * b1)
                left -= steady
                right -= steadyRight
                window[15] = left
                windowRight[15] = right
                continue
            }
            let low = UInt32(truncatingIfNeeded: position)
            let phase = Int(low >> 24)
            let between = Float(Int32(low & 0xFF_FFFF)) * (1.0 / 16_777_216.0)
            let sinc1 = sinc + (phase << 4), sinc2 = sinc + ((phase + 1) << 4)
            var left: Float = 0, right: Float = 0
            for i in 0 ..< 16 {
                let y1 = sinc1[i], y2 = sinc2[i]
                let weight = y1 + ((y2 - y1) * between)
                left += window[i] * weight
                right += windowRight[i] * weight
            }
            let remaining = samplesLeft + after
            let level = remaining < fade ? gain * Float(remaining) / Float(fade) : gain
            buffer[made * 2] = left * level
            buffer[made * 2 + 1] = right * level
            made += 1
            position += step
        }
        self.position = position
        return made
    }

    /// Leaves voices out of the sound, or brings them back: see `Renderer.setMuted`. A mark for each
    /// of the chip's channels, the first first; a reset does not undo it.
    func setMuted(_ muted: [Bool]) {
        var channels: UInt32 = 0
        for voice in 0 ..< min(18, muted.count) where muted[voice] { channels |= 1 << UInt32(voice) }
        self.muted = channels
        chip.pointee.setMuted(channels)
    }

    /// How loud each of the first so many of the chip's nine voices has been since this was last asked.
    func takeLevels(into levels: UnsafeMutablePointer<Float>, voices: Int) {
        chip.pointee.takeLevels(into: levels, count: voices)
    }

    /// What each of them is playing.
    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>, voices: Int) {
        chip.pointee.takeNotes(pitches: pitches, struck: struck, count: voices)
    }

    /// One sample as the chip makes it, at the chip's own rate and before anything else is done to
    /// it: for comparing with a reference player.
    func raw() -> Int16 {
        samplesLeft -= 1
        return chip.pointee.OPL3_Generate().left
    }

    /// The same, both sides.
    func rawStereo() -> (left: Int16, right: Int16) {
        samplesLeft -= 1
        return chip.pointee.OPL3_Generate()
    }
}
