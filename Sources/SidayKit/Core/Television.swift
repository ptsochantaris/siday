// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The kind of television a tune can be played through.
public enum TelevisionSet: String, Sendable, CaseIterable {
    /// A small portable in a moulded plastic case: a three-inch paper cone behind a slotted grille.
    case plastic
    /// A large set in a veneered wooden cabinet, with a bigger elliptical speaker and more air behind it:
    /// its bass reaches down towards the low notes of a man's voice, and the cabinet adds a little there.
    case wood
}

/// What an early-1980s television made of the sound of a computer plugged into it: one channel, a sound
/// stage that lost some treble, a small amplifier and paper cone that were never quite linear, and a
/// speaker in a vented cabinet that had no bass, little top, and resonances of its own in between.
///
/// Nothing here was measured from a particular set. The stages are the ones such a set had, and their
/// figures are typical ones, chosen to be adjusted by ear: they are all in `Voicing`.
public struct Television {
    /// Everything that gives a set its sound.
    struct Voicing {
        /// Corner of the treble loss in the sound channel, in Hz (a single pole).
        var channelCutoff: Double
        /// Third- and second-order bending of the amplifier and cone: 0 is perfectly linear.
        var odd: Double, even: Double
        /// The speaker's own resonance and how sharply it peaks there; below it the output falls away.
        var coneResonance: Double, coneQ: Double
        /// Below this the sound from the back of the cone, let out by the vents, cancels the front's.
        var ventCutoff: Double
        /// Resonances of the cabinet and the cone, and the dips between them: centre in Hz, gain in dB, Q.
        var colour: [(hz: Double, dB: Double, q: Double)]
        /// Where the cone stops following the coil: the top of the speaker's range.
        var topCutoff: Double, topQ: Double

        static func voicing(of set: TelevisionSet) -> Voicing {
            switch set {
            case .plastic:
                Voicing(channelCutoff: 4500, odd: 0.22, even: 0.10, coneResonance: 170, coneQ: 1.3, ventCutoff: 110,
                        colour: [(310, 4.5, 3.5), (760, 3, 4), (1500, -3, 2.5), (2900, 5, 2.2)],
                        topCutoff: 6000, topQ: 0.8)
            case .wood:
                Voicing(channelCutoff: 5000, odd: 0.12, even: 0.05, coneResonance: 90, coneQ: 1.15, ventCutoff: 58,
                        colour: [(170, 4, 1.9), (430, 2.5, 3), (1200, -2, 2), (2400, 3.5, 2)],
                        topCutoff: 7000, topQ: 0.7)
            }
        }
    }

    /// One second-order filter section, in transposed direct form II.
    private struct Section {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var s1 = 0.0, s2 = 0.0

        @inline(__always) mutating func step(_ x: Double) -> Double {
            let y = b0 * x + s1
            s1 = b1 * x - a1 * y + s2
            s2 = b2 * x - a2 * y
            return y
        }

        /// Gain for a steady tone at `w` radians per sample.
        func gain(_ w: Double) -> Double {
            let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
            let top = hypot(b0 + b1 * c1 + b2 * c2, b1 * s1 + b2 * s2)
            let bottom = hypot(1 + a1 * c1 + a2 * c2, a1 * s1 + a2 * s2)
            return top / bottom
        }

        // The sections below are the usual "cookbook" ones (Robert Bristow-Johnson's formulae).

        static func lowPass(_ hz: Double, q: Double, rate: Double) -> Section {
            let w = 2 * Double.pi * hz / rate, alpha = sin(w) / (2 * q), a0 = 1 + alpha
            return Section(b0: (1 - cos(w)) / 2 / a0, b1: (1 - cos(w)) / a0, b2: (1 - cos(w)) / 2 / a0,
                           a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
        }

        static func highPass(_ hz: Double, q: Double, rate: Double) -> Section {
            let w = 2 * Double.pi * hz / rate, alpha = sin(w) / (2 * q), a0 = 1 + alpha
            return Section(b0: (1 + cos(w)) / 2 / a0, b1: -(1 + cos(w)) / a0, b2: (1 + cos(w)) / 2 / a0,
                           a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
        }

        static func peak(_ hz: Double, dB: Double, q: Double, rate: Double) -> Section {
            let w = 2 * Double.pi * hz / rate, amount = pow(10, dB / 40), alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha / amount
            return Section(b0: (1 + alpha * amount) / a0, b1: -2 * cos(w) / a0, b2: (1 - alpha * amount) / a0,
                           a1: -2 * cos(w) / a0, a2: (1 - alpha / amount) / a0)
        }

        /// A single pole, low-pass or high-pass.
        static func onePole(_ hz: Double, highPass: Bool, rate: Double) -> Section {
            let k = tan(Double.pi * hz / rate), a0 = 1 + k
            return highPass ? Section(b0: 1 / a0, b1: -1 / a0, a1: (k - 1) / a0)
                : Section(b0: k / a0, b1: k / a0, a1: (k - 1) / a0)
        }
    }

    public let set: TelevisionSet
    private let rate: Double
    private let odd: Double, even: Double
    private var channel: Section
    private var speaker: [Section]
    /// Brings the middle of the range back to the level it came in at.
    private let level: Double

    public init(_ set: TelevisionSet, sampleRate: Double = Double(outputSampleRate)) {
        self.set = set
        rate = sampleRate
        let voicing = Voicing.voicing(of: set)
        odd = voicing.odd
        even = voicing.even
        let channel = Section.onePole(voicing.channelCutoff, highPass: false, rate: sampleRate)
        let speaker = [Section.highPass(voicing.coneResonance, q: voicing.coneQ, rate: sampleRate),
                       Section.onePole(voicing.ventCutoff, highPass: true, rate: sampleRate)]
            + voicing.colour.map { Section.peak($0.hz, dB: $0.dB, q: $0.q, rate: sampleRate) }
            + [Section.lowPass(voicing.topCutoff, q: voicing.topQ, rate: sampleRate)]
        self.channel = channel
        self.speaker = speaker

        // Loudness lives in the middle of the range, so that is what is kept level: the average gain,
        // in decibels, from 300 Hz to 3 kHz.
        var sum = 0.0
        let steps = 48
        for step in 0 ... steps {
            let w = 2 * Double.pi * 300 * pow(10, Double(step) / Double(steps)) / sampleRate
            sum += log(speaker.reduce(channel.gain(w)) { $0 * $1.gain(w) })
        }
        level = exp(-sum / Double(steps + 1))
    }

    /// The gain of the whole set for a quiet steady tone, 1 being unchanged.
    public func response(at hz: Double) -> Double {
        let w = 2 * Double.pi * hz / rate
        return speaker.reduce(channel.gain(w) * level) { $0 * $1.gain(w) }
    }

    /// Forgets what has been played: the cone comes to rest.
    public mutating func reset() {
        channel.s1 = 0; channel.s2 = 0
        for index in speaker.indices { speaker[index].s1 = 0; speaker[index].s2 = 0 }
    }

    /// Plays `frames` interleaved stereo frames through the set, in place. Both channels come out the same.
    public mutating func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        let odd = odd, even = even, level = level
        var channel = channel
        speaker.withUnsafeMutableBufferPointer { speaker in
            for frame in 0 ..< frames {
                // One loudspeaker: the two channels are added before anything else happens to them.
                var x = channel.step(0.5 * Double(buffer[frame * 2] + buffer[frame * 2 + 1]))

                // The amplifier and the cone give a little less than they are asked for as the signal
                // grows, and not quite the same amount in each direction.
                x = max(-1, min(1, x))
                x += even * x * x - odd * x * x * x

                for index in speaker.indices { x = speaker[index].step(x) }
                x *= level

                // The resonances can lift a loud passage past full scale; ease it over the last stretch.
                let size = abs(x)
                if size > 0.8 { x = (x < 0 ? -1 : 1) * (0.8 + 0.2 * tanh((size - 0.8) / 0.2)) }

                buffer[frame * 2] = Float(x)
                buffer[frame * 2 + 1] = Float(x)
            }
        }
        self.channel = channel
    }
}
