// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from SAASound, Copyright (c) 1998-2025 Dave Hooper and Simon Owen, used under the BSD
// 3-Clause licence (see THIRD-PARTY.md).
//
// Philips' SAA1099: six square waves, each at its own volume on each side, two noises and two
// envelopes. It was the SAM Coupé's sound, and, two of them, Creative's first card: the Creative
// Music System of 1987, sold again as the Game Blaster. This is SAASound's emulation of it, as its
// author revised it from 2018 on others' study of the chip itself: when what is written to an
// oscillator is taken up, the noise's register, and how an envelope and a volume make one level.
// SAASound steps it many times for each of the player's samples and averages them; here it is
// stepped at a rate of its own, which the writes are timed to, and band-limited from that.

import SidayFoundation

private let saaNone = [Int](repeating: 0, count: 16)
private let saaFull = [Int](repeating: 15, count: 16), saaFullCoarse = [Int](repeating: 14, count: 16)

private let saaEnvelopes: [(phases: Int, loops: Bool, levels: [[[Int]]])] = [
    // nought
    (1, false, [[saaNone, saaNone], [saaNone, saaNone]]),
    // the loudest
    (1, true, [[saaFull, saaFull], [saaFullCoarse, saaFullCoarse]]),
    // down once
    (1, false, [[[15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0], saaNone],
                [[14, 14, 12, 12, 10, 10, 8, 8, 6, 6, 4, 4, 2, 2, 0, 0], saaNone]]),
    // down, round and round
    (1, true, [[[15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0], saaNone],
               [[14, 14, 12, 12, 10, 10, 8, 8, 6, 6, 4, 4, 2, 2, 0, 0], saaNone]]),
    // up and down once
    (2, false, [[[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]],
                [[0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14], [14, 14, 12, 12, 10, 10, 8, 8, 6, 6, 4, 4, 2, 2, 0, 0]]]),
    // up and down, round and round
    (2, true, [[[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]],
               [[0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14], [14, 14, 12, 12, 10, 10, 8, 8, 6, 6, 4, 4, 2, 2, 0, 0]]]),
    // up once
    (1, false, [[[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], saaNone],
                [[0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14], saaNone]]),
    // up, round and round
    (1, true, [[[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], saaNone],
               [[0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14], saaNone]]),
]

/// How loud a channel with an envelope is: the chip makes its volume and the envelope's level each
/// as a pattern of pulses and joins them, and this is what that comes to, by half the volume and
/// the envelope's level, as SAASound has it.
private let saaPulses: [[Int]] = [
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    [0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8],
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [0, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 23],
    [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30],
    [0, 3, 5, 8, 10, 13, 15, 18, 20, 23, 25, 28, 30, 33, 35, 38],
    [0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45],
    [0, 4, 7, 11, 14, 18, 21, 25, 28, 32, 35, 39, 42, 46, 49, 53],
]

struct SAA1099Chip {
    /// One of the six oscillators. What is written to it is taken up at the end of a half of its
    /// wave. (SAASound holds an offset written on its own for a half more, as its author read
    /// Philips' account of the chip, and marks that as not tried on the chip: it is left out here,
    /// since it puts a tune with many writes far from libvgm's two emulations, which both take a
    /// write up at once.)
    private struct Oscillator {
        var counter: UInt64 = 0, add: UInt64 = 0
        var level = 1
        var offset = 0, octave = 0, nextOffset = 0, nextOctave = 0
        var pending = false
    }

    private struct Noise {
        var counter: UInt64 = 0, add: UInt64 = 0
        var source = 0
        var shift: UInt32 = 0xFFFF_FFFF
        var level: Int { Int(shift & 1) }

        mutating func change() {
            // An 18-bit register, x^18 + x^11 + x, as Jepael found it to be.
            shift = shift & 1 != 0 ? shift >> 1 ^ 0x20400 : shift >> 1
        }
    }

    private struct Envelope {
        var enabled = false, ended = true, newData = false, external = false, invert = false, loops = false
        var phase = 0, position = 0, resolution = 1, phases = 1, shape = 0, nextData = 0
        var left = 0, right = 0
    }

    private struct Amp {
        var left = 0, right = 0
        var tone = false, noise = false
        /// What the channel's mixer makes now: nought, one or two.
        var intermediate = 0
    }

    private var oscillators = InlineArray<6, Oscillator>(repeating: Oscillator())
    private var noises = InlineArray<2, Noise>(repeating: Noise())
    private var envelopes = InlineArray<2, Envelope>(repeating: Envelope())
    private var amps = InlineArray<6, Amp>(repeating: Amp())
    private var register = 0
    private var sync = false, enabled = false
    /// The oscillators' rates, by octave and offset; and what a half of a wave is counted to.
    private let table: [UInt64]
    private let limit: UInt64
    private let noiseBase: UInt64
    var muted = InlineArray<6, Bool>(repeating: false)
    /// For what is shown of the voices.
    private var lowsLeft = InlineArray<6, Int>(repeating: .max), highsLeft = InlineArray<6, Int>(repeating: .min)
    private var lowsRight = InlineArray<6, Int>(repeating: .max), highsRight = InlineArray<6, Int>(repeating: .min)
    private var struck = InlineArray<6, Bool>(repeating: false)

    /// - Parameters:
    ///   - clock: the chip's clock: 8 MHz for the SAM Coupé, a PC's 7.16 MHz for the Creative Music System.
    ///   - rate: how many times a second it is stepped.
    init(clock: Double, rate: Double) {
        var table: [UInt64] = []
        for octave in 0 ..< 8 {
            for offset in 0 ..< 256 {
                table.append(UInt64(8192.0 * 15625.0 * Double(1 << octave) * (clock / 8_000_000) / (511 - Double(offset))))
            }
        }
        self.table = table
        limit = UInt64(rate) << 12
        noiseBase = UInt64(clock) << 4
        reset()
    }

    mutating func reset() {
        oscillators = InlineArray(repeating: Oscillator())
        for index in 0 ..< 6 { oscillators[index].add = table[0] }
        noises = InlineArray(repeating: Noise())
        for index in 0 ..< 2 { noises[index].add = noiseBase }
        envelopes = InlineArray(repeating: Envelope())
        amps = InlineArray(repeating: Amp())
        register = 0
        sync = false
        enabled = false
    }

    // MARK: Writes

    mutating func writeAddress(_ value: UInt8) {
        register = Int(value & 31)
        if register == 24 || register == 25 {
            let which = register - 24
            if envelopes[which].external, envelopes[which].enabled { tickEnvelope(which) }
        }
    }

    mutating func writeData(_ value: UInt8) {
        let data = Int(value)
        switch register {
        case 0 ... 5:
            let left = data & 0x0F, right = data >> 4 & 0x0F
            if max(left, right) > max(amps[register].left, amps[register].right) + 2 { struck[register] = true }
            amps[register].left = left
            amps[register].right = right
        case 8 ... 13:
            setOffset(register - 8, data)
        case 16 ... 18:
            setOctave((register - 16) * 2, data & 7)
            setOctave((register - 16) * 2 + 1, data >> 4 & 7)
        case 20:
            for channel in 0 ..< 6 { amps[channel].tone = data >> channel & 1 != 0 }
        case 21:
            for channel in 0 ..< 6 { amps[channel].noise = data >> channel & 1 != 0 }
        case 22:
            setNoiseSource(0, data & 3)
            setNoiseSource(1, data >> 4 & 3)
        case 24, 25:
            setEnvelope(register - 24, data)
        case 28:
            let syncing = data & 0x02 != 0
            if syncing != sync {
                sync = syncing
                if syncing {
                    for index in 0 ..< 6 {
                        oscillators[index].counter = 0
                        oscillators[index].level = 1
                        oscillators[index].octave = oscillators[index].nextOctave
                        oscillators[index].offset = oscillators[index].nextOffset
                        oscillators[index].add = table[oscillators[index].octave << 8 | oscillators[index].offset]
                    }
                    for index in 0 ..< 2 { noises[index].counter = 0 }
                }
            }
            enabled = data & 0x01 != 0
        default:
            break
        }
    }

    private mutating func setOffset(_ index: Int, _ offset: Int) {
        if !sync {
            oscillators[index].nextOffset = offset
            oscillators[index].pending = true
        } else {
            oscillators[index].pending = false
            oscillators[index].offset = offset
            oscillators[index].nextOffset = offset
            oscillators[index].octave = oscillators[index].nextOctave
            oscillators[index].add = table[oscillators[index].octave << 8 | offset]
        }
    }

    private mutating func setOctave(_ index: Int, _ octave: Int) {
        if !sync {
            oscillators[index].nextOctave = octave
            oscillators[index].pending = true
        } else {
            oscillators[index].pending = false
            oscillators[index].octave = octave
            oscillators[index].nextOctave = octave
            oscillators[index].offset = oscillators[index].nextOffset
            oscillators[index].add = table[octave << 8 | oscillators[index].offset]
        }
    }

    private mutating func setNoiseSource(_ index: Int, _ source: Int) {
        noises[index].source = source
        noises[index].add = noiseBase >> UInt64(source)
    }

    // MARK: Envelopes

    private mutating func setEnvelope(_ which: Int, _ data: Int) {
        let enable = data & 0x80 != 0
        if !enable, !envelopes[which].enabled { return }
        envelopes[which].enabled = enable
        if !enable {
            envelopes[which].ended = true
            return
        }
        let resolution = data & 0x10 != 0 ? 2 : 1
        if envelopes[which].resolution == 1, resolution == 2 {
            envelopes[which].position &= 0xE
        } else if envelopes[which].resolution == 2, resolution == 1 {
            envelopes[which].position |= 0x1
        }
        envelopes[which].resolution = resolution
        if envelopes[which].ended {
            loadEnvelope(which, data)
            envelopes[which].newData = false
        } else {
            setEnvelopeLevels(which)
            envelopes[which].newData = true
            envelopes[which].nextData = data
        }
    }

    private mutating func loadEnvelope(_ which: Int, _ data: Int) {
        var envelope = envelopes[which]
        envelope.phase = 0
        envelope.position = 0
        envelope.shape = data >> 1 & 7
        envelope.invert = data & 0x01 != 0
        envelope.external = data & 0x20 != 0
        envelope.phases = saaEnvelopes[envelope.shape].phases
        envelope.loops = saaEnvelopes[envelope.shape].loops
        envelope.resolution = data & 0x10 != 0 ? 2 : 1
        envelope.enabled = data & 0x80 != 0
        envelope.ended = !envelope.enabled
        envelopes[which] = envelope
        setEnvelopeLevels(which)
    }

    private mutating func setEnvelopeLevels(_ which: Int) {
        let envelope = envelopes[which]
        let fine = envelope.resolution == 1
        let left = envelope.ended && !envelope.loops ? 0 : saaEnvelopes[envelope.shape].levels[fine ? 0 : 1][envelope.phase][envelope.position]
        envelopes[which].left = left
        envelopes[which].right = envelope.invert ? (fine ? 15 : 14) - left : left
    }

    private mutating func tickEnvelope(_ which: Int) {
        guard envelopes[which].enabled else {
            envelopes[which].ended = true
            envelopes[which].phase = 0
            envelopes[which].position = 0
            return
        }
        if envelopes[which].ended { return }
        envelopes[which].position += envelopes[which].resolution
        var takeNew = false
        if envelopes[which].position >= 16 {
            envelopes[which].phase += 1
            if envelopes[which].phase == envelopes[which].phases {
                if !envelopes[which].loops {
                    envelopes[which].ended = true
                } else {
                    envelopes[which].ended = false
                    envelopes[which].phase = 0
                    envelopes[which].position -= 16
                }
                takeNew = true
            } else {
                envelopes[which].ended = false
                envelopes[which].position -= 16
            }
        } else {
            envelopes[which].ended = false
        }
        if envelopes[which].newData, takeNew {
            envelopes[which].newData = false
            loadEnvelope(which, envelopes[which].nextData)
        } else {
            setEnvelopeLevels(which)
        }
    }

    // MARK: Sound

    /// Steps an oscillator once. - Returns: its level, nought or one.
    @inline(__always) private mutating func tickOscillator(_ index: Int) -> Int {
        if sync { return 1 }
        oscillators[index].counter &+= oscillators[index].add
        while oscillators[index].counter >= limit {
            oscillators[index].counter &-= limit
            oscillators[index].level = 1 - oscillators[index].level
            // (The second and fifth step the envelopes, the first and fourth can step the noises.)
            switch index {
            case 0, 3: if noises[index / 3].source == 3 { noises[index / 3].change() }
            case 1, 4: if envelopes[index / 3].enabled, !envelopes[index / 3].external { tickEnvelope(index / 3) }
            default: break
            }
            if oscillators[index].pending {
                oscillators[index].octave = oscillators[index].nextOctave
                oscillators[index].offset = oscillators[index].nextOffset
                oscillators[index].pending = false
                oscillators[index].add = table[oscillators[index].octave << 8 | oscillators[index].offset]
            }
        }
        return oscillators[index].level
    }

    /// Steps the chip once: what it makes, left and right, each of its six channels from -1/2 to 1/2
    /// at its loudest.
    @inline(__always) mutating func step() -> (Double, Double) {
        for index in 0 ..< 2 where !sync && noises[index].source != 3 {
            noises[index].counter &+= noises[index].add
            while noises[index].counter >= limit {
                noises[index].counter &-= limit
                noises[index].change()
            }
        }
        var left = 0, right = 0
        for channel in 0 ..< 6 {
            if sync { continue }
            let tone = tickOscillator(channel)
            let noise = noises[channel / 3].level
            let amp = amps[channel]
            let level = switch (amp.tone, amp.noise) {
            case (false, false): 0
            case (true, false): tone * 2
            case (false, true): noise * 2
            case (true, true): tone * (2 - noise)
            }
            amps[channel].intermediate = level
            guard enabled else { continue }
            // Each channel swings either side of nought, as libvgm has them, and not from nought up
            // as the chip's own outputs do: a note started or stopped then moves nothing that is
            // steady, which the card's filter would let through as a thump.
            var l: Int, r: Int
            if channel == 2 || channel == 5, envelopes[channel / 3].enabled {
                let envelope = envelopes[channel / 3]
                let topLeft = saaPulses[amp.left >> 1][15] * 4, topRight = saaPulses[amp.right >> 1][15] * 4
                l = saaPulses[amp.left >> 1][envelope.left] * 4 * (2 - level) - topLeft
                r = saaPulses[amp.right >> 1][envelope.right] * 4 * (2 - level) - topRight
            } else if amp.tone || amp.noise {
                l = amp.left * (level - 1) * 16
                r = amp.right * (level - 1) * 16
            } else {
                continue
            }
            lowsLeft[channel] = min(lowsLeft[channel], l)
            highsLeft[channel] = max(highsLeft[channel], l)
            lowsRight[channel] = min(lowsRight[channel], r)
            highsRight[channel] = max(highsRight[channel], r)
            guard !muted[channel] else { continue }
            left += l
            right += r
        }
        return (Double(left) / 480, Double(right) / 480)
    }

    /// How far each channel has swung since this was last asked, on the side it has swung the more,
    /// where 1 is a tone at the loudest: half the way from the lowest it has been to the highest. A
    /// channel held at one level, as an envelope is while it rests, makes no sound and is dark; and
    /// one left out of the sound is as it would be heard.
    mutating func takeLevels(into levels: UnsafeMutablePointer<Float>) {
        for channel in 0 ..< 6 {
            let left = highsLeft[channel] > lowsLeft[channel] ? highsLeft[channel] - lowsLeft[channel] : 0
            let right = highsRight[channel] > lowsRight[channel] ? highsRight[channel] - lowsRight[channel] : 0
            levels[channel] = Float(max(left, right)) / 480
            lowsLeft[channel] = .max
            highsLeft[channel] = .min
            lowsRight[channel] = .max
            highsRight[channel] = .min
        }
    }

    /// What a channel puts out now on the louder of its two sides, as `step` works it out, from -240
    /// to 240 at its loudest: for the channel's scope, read once one of the player's samples is
    /// made, so that the chip itself does nothing more. A channel left out of the sound is told too.
    ///
    /// (Mutating, though it changes nothing: a method that only reads a chip kept in a class is handed
    /// a copy of it first.)
    mutating func channelOutput(_ channel: Int) -> Int {
        guard enabled, !sync else { return 0 }
        let amp = amps[channel], level = amp.intermediate
        let left = amp.left >= amp.right
        if channel == 2 || channel == 5, envelopes[channel / 3].enabled {
            let envelope = envelopes[channel / 3]
            let volume = left ? amp.left : amp.right
            return saaPulses[volume >> 1][left ? envelope.left : envelope.right] * 4 * (2 - level) - saaPulses[volume >> 1][15] * 4
        }
        guard amp.tone || amp.noise else { return 0 }
        return (left ? amp.left : amp.right) * (level - 1) * 16
    }

    /// Each channel's pitch, by its oscillator, if its tone is heard; and whether its volume has
    /// jumped up.
    mutating func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>, clock: Double) {
        for channel in 0 ..< 6 {
            let oscillator = oscillators[channel], amp = amps[channel]
            let hz = 15625 * Double(1 << oscillator.octave) * (clock / 8_000_000) / (511 - Double(oscillator.offset))
            pitches[channel] = enabled && amp.tone && max(amp.left, amp.right) > 0 ? ChannelPitch.note(ofHz: hz) : 0
            struck[channel] = self.struck[channel]
            self.struck[channel] = false
        }
    }

    /// Where each channel is between the sides, by its two volumes.
    func sides(into sides: UnsafeMutablePointer<Float>) {
        for channel in 0 ..< 6 {
            let left = Float(amps[channel].left), right = Float(amps[channel].right)
            sides[channel] = left + right > 0 ? (right - left) / (right + left) : 0
        }
    }
}
