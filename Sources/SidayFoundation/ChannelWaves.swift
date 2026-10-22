// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// What each of a tune's voices has sounded like of late, kept for its scope: a little picture of
/// the voice's own wave, as FastTracker 2 drew one for each channel above its patterns.
///
/// A player that can show its voices keeps one of these once asked (`Renderer.keepChannelWaves`)
/// and writes each voice's sound into it as it makes it, before the voices are added together, at
/// whatever rate it makes them: each voice can have a rate and a loudness of its own, as a sound
/// card's samples and its FM chip's voices have. A scope is then taken from the latest of it (`take`).
///
/// A scope is steady: a voice whose pitch is the pitch of its wave, a chip's, is shown as two of its
/// cycles, begun where it rises through its middle, so a held note stands still and its shape can
/// be seen. A sample's pitch is not its wave's, and a beeper's is only counted, so those are shown
/// as the last fiftieth of a second, as FastTracker showed every voice. Either way, of the places
/// where the wave rises through its middle, the one taken is the one most like the scope shown
/// before it, so that a wave of several crossings a cycle does not jump from one to another.
public final class ChannelWaves {
    /// How many points a scope is drawn through.
    public static let points = 64
    /// How much of each voice is kept: a power of two.
    @inlinable static var capacity: Int { 16384 }

    public let voices: Int
    /// How many of its samples each voice is kept at in a second.
    private var rates: [Double]
    /// How far each voice at its loudest swings either side of its middle, as it is kept: its scope
    /// is full at that.
    private var fullSwings: [Float]
    /// How many frames of the output the player has made and not yet handed out: how far what is
    /// kept is ahead of what has been heard.
    public var ahead = 0

    @usableFromInline let ring: UnsafeMutablePointer<Float>
    /// How many samples of each voice have been kept.
    @usableFromInline let written: UnsafeMutablePointer<Int>
    /// The last scope shown of each voice, at full height; and whether there is one.
    private let previous: UnsafeMutablePointer<Float>
    private var shown: [Bool]
    private let candidate: UnsafeMutablePointer<Float>

    /// Every voice at the same rate and loudness, until told otherwise (`setVoice`).
    public init(voices: Int, rate: Double, fullSwing: Float) {
        self.voices = voices
        rates = Array(repeating: rate, count: voices)
        fullSwings = Array(repeating: fullSwing, count: voices)
        written = .allocate(capacity: max(1, voices))
        written.initialize(repeating: 0, count: max(1, voices))
        ring = .allocate(capacity: max(1, voices) * Self.capacity)
        ring.initialize(repeating: 0, count: max(1, voices) * Self.capacity)
        previous = .allocate(capacity: max(1, voices) * Self.points)
        previous.initialize(repeating: 0, count: max(1, voices) * Self.points)
        candidate = .allocate(capacity: Self.points)
        candidate.initialize(repeating: 0, count: Self.points)
        shown = Array(repeating: false, count: voices)
    }

    deinit {
        ring.deallocate()
        written.deallocate()
        previous.deallocate()
        candidate.deallocate()
    }

    /// Gives a voice a rate and a loudness of its own.
    public func setVoice(_ voice: Int, rate: Double, fullSwing: Float) {
        guard voice < voices else { return }
        rates[voice] = rate
        fullSwings[voice] = fullSwing
    }

    /// Keeps a sample of a voice, so many samples on from the last `advance` of it. (This and the two
    /// `advance`s are inlinable: the players of other modules call them at every sample.)
    @inlinable @inline(__always) public func store(_ voice: Int, at offset: Int, _ value: Float) {
        ring[voice &* Self.capacity &+ ((written[voice] &+ offset) & (Self.capacity &- 1))] = value
    }

    /// Keeps silence for a voice that is not playing, for so many samples on from the last `advance`.
    public func silence(_ voice: Int, count: Int) {
        for offset in 0 ..< count { store(voice, at: offset, 0) }
    }

    /// Moves every voice on past samples that have been kept.
    @inlinable @inline(__always) public func advance(by count: Int) {
        for voice in 0 ..< voices { written[voice] &+= count }
    }

    /// Moves one voice on past samples that have been kept: for a voice kept at a rate of its own.
    @inlinable @inline(__always) public func advance(_ voice: Int, by count: Int) {
        written[voice] &+= count
    }

    /// A voice's sample at a place in what has been kept, between two of them if need be.
    @inline(__always) private func sample(_ base: UnsafeMutablePointer<Float>, at place: Double, before end: Int) -> Float {
        let whole = Int(place.rounded(.down))
        let fraction = Float(place - Double(whole))
        let a = base[whole & (Self.capacity - 1)], b = base[min(whole &+ 1, end &- 1) & (Self.capacity - 1)]
        return a + (b - a) * fraction
    }

    /// A voice's scope, as it was `behind` frames of the output ago (and `ahead` more, which the player
    /// has made and not handed out): `points` bytes, 128 for the middle, 1 at the bottom and 255 at
    /// the top. Its height is how loud the voice is, as the lights have it: a quiet voice is small,
    /// and still seen.
    /// - Parameters:
    ///   - pitch: the voice's pitch, as `ChannelPitch` gives it; 0 for none.
    ///   - periodic: true if that pitch is the pitch of its wave.
    ///   - loudness: what the sound is turned down by as it is heard, as at a tune's fade, by which the
    ///     scope is made smaller as its light is made dimmer.
    public func take(_ voice: Int, pitch: Float, periodic: Bool, behind: Int, loudness: Float = 1, into scope: UnsafeMutablePointer<UInt8>) {
        let flat = { (scope: UnsafeMutablePointer<UInt8>) in
            scope.update(repeating: 128, count: Self.points)
            self.shown[voice] = false
        }
        guard voice < voices else { return flat(scope) }
        let base = ring + voice * Self.capacity
        let rate = rates[voice], fullSwing = fullSwings[voice], written = written[voice]
        let end = written - Int((Double(behind + ahead) * rate / Double(outputSampleRate)).rounded())
        var length: Double, span: Int
        // (A pitch under 20 Hz is no note but what a voice is left with, as when a game sets the
        // frequency to nearly nothing once a note is let go: the voice is shown as one with no pitch.)
        let hz = pitch > 0 ? 440 * pow(2, (Double(pitch) - 69) / 12) : 0
        if periodic, hz >= 20 {
            let period = rate / hz
            length = period * 2
            span = Int(period) + 1
        } else {
            length = rate / 50
            span = Int(length / 2)
        }
        let longest = Double(Self.capacity / 4)
        length = max(8, min(longest, length))
        span = max(1, min(Self.capacity / 4, span))
        let first = end - Int(length.rounded(.up)) - span
        // What is wanted has to be what is still kept (and has been kept at all).
        guard first > written - Self.capacity, first >= 0 else { return flat(scope) }

        // How far the wave goes over the latest of it, as much as the scope shows: that decides how
        // tall the scope is, and whether it is flat at all, so that a note that ended before then is
        // not shown, as its light is out. (The scope may begin a little earlier than that, to stand
        // still; what it shows from there is held to its height.)
        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        for place in end - Int(length.rounded(.up)) ..< end {
            let value = base[place & (Self.capacity - 1)]
            low = min(low, value)
            high = max(high, value)
        }
        let half = (high - low) / 2
        guard half * loudness > fullSwing * 0.002 else { return flat(scope) }
        let middle = (low + high) / 2
        let step = length / Double(Self.points)

        // The places where the wave rises through its middle, the latest first.
        var best = end - Int(length.rounded(.up))
        var bestLikeness = -Float.greatestFiniteMagnitude
        var tried = 0
        var start = end - Int(length.rounded(.up))
        while start > first, tried < 24 {
            let before = base[(start - 1) & (Self.capacity - 1)], at = base[start & (Self.capacity - 1)]
            if before < middle, at >= middle {
                tried += 1
                guard shown[voice] else {
                    best = start
                    break
                }
                var likeness: Float = 0
                let was = previous + voice * Self.points
                for point in 0 ..< Self.points {
                    let value = (sample(base, at: Double(start) + Double(point) * step, before: end) - middle) / half
                    likeness += value * was[point]
                }
                if likeness > bestLikeness {
                    bestLikeness = likeness
                    best = start
                }
            }
            start -= 1
        }

        let size = Float(min(1, half * loudness / fullSwing)).squareRoot()
        let was = previous + voice * Self.points
        for point in 0 ..< Self.points {
            let value = max(-1, min(1, (sample(base, at: Double(best) + Double(point) * step, before: end) - middle) / half))
            was[point] = value
            scope[point] = UInt8(max(1, min(255, 128 + (value * size * 127).rounded())))
        }
        shown[voice] = true
    }
}
