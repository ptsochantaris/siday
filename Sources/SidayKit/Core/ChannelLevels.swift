// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// How loud each voice of a tune is, for a row of lights to show: a chip's three channels, a
// module's tracks, a sound card's FM voices. What is measured is the voice by itself, before it is
// mixed with the others, as how far it swings: 1 is as far as that kind of voice can go.
//
// Nothing here is exact, or needs to be. It is there to be watched.

/// The lowest and highest a voice has been, of late.
struct Swing<Value: Comparable> {
    private let floor: Value, ceiling: Value
    private(set) var low: Value, high: Value

    /// - Parameters:
    ///   - floor: the lowest the voice can be, and `ceiling` the highest.
    init(from floor: Value, to ceiling: Value) {
        self.floor = floor
        self.ceiling = ceiling
        low = ceiling
        high = floor
    }

    @inline(__always) mutating func note(_ value: Value) {
        if value < low { low = value }
        if value > high { high = value }
    }

    /// False if nothing has been noted.
    var moved: Bool { low < high }

    mutating func clear() {
        low = ceiling
        high = floor
    }
}

/// The levels of the voices of a player that makes its sound a tick at a time, which may be more or
/// less than is asked for at once: a tick's levels stand for as long as the tick is being given out.
struct TickLevels {
    /// Each voice's level in the tick just made. The player sets these and then calls `tickMade`.
    var now: [Float]
    /// The most each has been in the ticks made since the levels were last taken.
    private var since: [Float]

    init(voices: Int) {
        now = [Float](repeating: 0, count: voices)
        since = now
    }

    mutating func clear() {
        for voice in now.indices {
            now[voice] = 0
            since[voice] = 0
        }
    }

    mutating func tickMade() {
        for voice in now.indices where now[voice] > since[voice] { since[voice] = now[voice] }
    }

    /// Gives out the levels and starts afresh, from the tick that is still being heard.
    mutating func take(into levels: UnsafeMutablePointer<Float>) {
        for voice in now.indices {
            levels[voice] = since[voice]
            since[voice] = now[voice]
        }
    }
}

/// The notes of the voices of a player that makes its sound a tick at a time: the pitch each voice
/// has now, and whether a note has been started on it since the notes were last taken. The player
/// sets a pitch as it changes, and marks a voice struck; taking them clears the marks.
struct TickNotes {
    var pitches: [Float]
    var struck: [Bool]

    init(voices: Int) {
        pitches = [Float](repeating: 0, count: voices)
        struck = [Bool](repeating: false, count: voices)
    }

    mutating func clear() {
        for voice in pitches.indices {
            pitches[voice] = 0
            struck[voice] = false
        }
    }

    mutating func take(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        for voice in self.pitches.indices {
            pitches[voice] = self.pitches[voice]
            struck[voice] = self.struck[voice]
            self.struck[voice] = false
        }
    }
}

/// A voice's pitch as a number: twelve to the octave, 60 for middle C and 69 for the A above it, with
/// fractions for what lies between notes. Nought is no pitch at all: noise, or nothing.
public enum ChannelPitch {
    /// The pitch of a tone of so many cycles a second.
    public static func note(ofHz hz: Double) -> Float {
        guard hz > 1 else { return 0 }
        return Float(max(1, min(135, 69 + 12 * log(hz / 440) / log(2))))
    }

    /// The pitch a tracker means by playing a sample at so many samples a second. What is heard
    /// depends on the sample, but the trackers agree that 8,363 a second is middle C.
    public static func note(ofRate rate: Double) -> Float {
        guard rate > 1 else { return 0 }
        return Float(max(1, min(135, 60 + 12 * log(rate / 8363) / log(2))))
    }
}

public enum ChannelLight {
    /// The quietest level that shows at all, in decibels below the loudest a voice can be. An AY
    /// chip's fifteen volumes are 3 dB apart, so its quietest is about here.
    private static let range = 42.0

    /// How bright a light is for a level: from 0, dark, to 1. It goes by decibels, as the ear does.
    public static func brightness(of level: Float) -> Float {
        guard level > 0.0001 else { return 0 }
        return Float(max(0, min(1, 1 + 20 * log10(Double(level)) / range)))
    }
}
