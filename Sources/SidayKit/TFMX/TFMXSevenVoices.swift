// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The four voices TFMX 7V plays on Paula's fourth, mixed as its player mixed them: by the processor,
/// a tick at a time, into one of two buffers that Paula's fourth voice plays in turn, at 16 kHz.
///
/// This is how Chris Hülsbeck's player of TFMX 7V does it, as Wanted Team keep it in their player for
/// EaglePlayer ("TFMX 7V player module V1.1", carried by UADE as `TFMX-7V`; it says of itself "(c)
/// 1991-94 by Chris H"), whose 68000 code was read for it:
/// - Each voice has the registers Paula's voices have, written as the player would write Paula's: where
///   its sample is, how long, its period and volume, and whether it plays.
/// - Each tick, as Paula begins the buffer mixed the tick before, the next is mixed from what the
///   voices were told up to then, and then the player runs. So what the four are told is heard two
///   ticks later than what the other three are told is.
/// - A voice steps through its sample at its period's rate against the mixing's, in sixteenths of
///   sixty-five-thousandths, taking the nearest sample before it, with nothing between.
/// - A sample is turned down by its voice's volume from a table of 64 (a volume of 64 is taken as 63):
///   the sample times the volume, over 64, rounded down. The four are added, and what goes beyond a
///   byte is clipped.
/// - A sample or loop of fewer than 32 words is not played: silence is, in its place.
struct TFMXSevenVoices {
    struct Voice {
        /// The registers, as the player last wrote them.
        var start = 0
        var length: UInt16 = 0
        var period: UInt16 = 0
        var volume: UInt16 = 0
        var on = false
        /// True once the voice has been stopped, until it starts again from the beginning of its sample.
        var restart = true
        /// Where the voice is: the end of what it is playing, and how far before that it is, in the low
        /// word of `position` as a negative count, with its fraction in the high word.
        var end = 0
        var position: UInt32 = 0
        /// What it goes on to when it comes to the end.
        var repeatEnd = 0
        var repeatBytes: UInt16 = 0
        var step: UInt32 = 0
        var table = 0
        /// How many times it has come to the end and gone round again since it was started.
        var loops: UInt16 = 0
        var muted = false
        /// True once the voice has started its sample afresh, until whoever shows notes has seen it.
        var struck = false
    }

    var voices = InlineArray<4, Voice>(repeating: Voice())
    /// Where silence is, played in place of a sample too short to be.
    let silence: Int
    /// How much silence is played in its place, in words.
    static let silenceWords: UInt16 = 0x25E

    init(silence: Int) {
        self.silence = silence
        for v in 0 ..< 4 { voices[v].end = silence }
    }

    /// What the player does as Paula takes up a voice: a voice that is to be heard starts its new
    /// sample when it has just been started, and goes on from the latest one when it comes to the end.
    private mutating func takeUp(_ v: Int) {
        let rate = UInt32(TFMXTiming.sevenVoicePeriod) << 11
        // The period and volume, unless the period is nought, when both are left as they were.
        if voices[v].period != 0 {
            let volume = Int(voices[v].volume & 0xFF)
            voices[v].table = volume >= 64 ? 63 : volume
            // (Where the division overflows, the 68000 leaves what was to be divided as it was.)
            let quotient = rate / UInt32(voices[v].period)
            let steps = (quotient > 0xFFFF ? rate : quotient) & 0xFFFF
            let shifted = steps << 5
            voices[v].step = shifted << 16 | shifted >> 16
        }
        guard voices[v].on else {
            voices[v].step = 0
            voices[v].restart = true
            return
        }
        let short = voices[v].length < 0x20
        let start = short ? silence : voices[v].start
        let bytes = UInt16(((short ? Self.silenceWords : voices[v].length) & 0x3FFF) * 2)
        voices[v].repeatEnd = start + Int(bytes)
        voices[v].repeatBytes = bytes
        if voices[v].restart {
            voices[v].restart = false
            voices[v].end = voices[v].repeatEnd
            voices[v].position = UInt32(bitPattern: -Int32(bytes))
            voices[v].loops = 0
            voices[v].struck = true
        }
    }

    /// Mixes `count` bytes of the four into `into`, and keeps each voice's own part in `parts` (four
    /// runs of `count`), turned down as it is heard, for its scope and its light.
    mutating func mix(_ memory: UnsafePointer<Int8>, size: Int, into: UnsafeMutablePointer<Int8>, count: Int,
                      parts: UnsafeMutablePointer<Float>) {
        for v in 0 ..< 4 { takeUp(v) }
        for i in 0 ..< count {
            var sum = 0
            for v in 0 ..< 4 {
                let at = voices[v].end + Int(Int16(truncatingIfNeeded: voices[v].position))
                let sample = at >= 0 && at < size ? Int(memory[at]) : 0
                let part = (sample * voices[v].table) >> 6
                parts[v * count + i] = Float(part) * (1.0 / 128.0)
                if !voices[v].muted { sum += part }
            }
            into[i] = Int8(clamping: sum)
            for v in 0 ..< 4 { stepOn(v) }
        }
    }

    /// Moves a voice on by its step: the fraction added to the fraction and the whole to the whole, the
    /// carry out of the fraction into the whole, as the 68000 does it in two instructions.
    @inline(__always) private mutating func stepOn(_ v: Int) {
        let sum = UInt64(voices[v].position) + UInt64(voices[v].step)
        var position = UInt32(truncatingIfNeeded: sum)
        let low = UInt16(truncatingIfNeeded: position) &+ UInt16(sum >> 32)
        position = position & 0xFFFF_0000 | UInt32(low)
        if Int16(bitPattern: low) >= 0 {
            voices[v].end = voices[v].repeatEnd
            position = position & 0xFFFF_0000 | UInt32(low &- voices[v].repeatBytes)
            voices[v].loops &+= 1
        }
        voices[v].position = position
    }
}
