// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The levels of the voices of a player that makes its sound a tick at a time and gives each tick
/// out over as many calls for sound as it takes, told as the sound is heard: a tick's levels are
/// told for the calls that give some of it out, and for no other.
///
/// (`TickLevels` tells a tick's levels from when it is made, and goes on telling them for the call
/// after the one that gave out the last of it.)
package struct HeardLevels {
    /// Each voice's level in the tick being given out. The player sets these as it makes the tick.
    package var now: [Float]
    /// And how many of the tick's frames each voice sounded for, from its start: a voice whose note
    /// ends part of the way through a tick is dark for what is given out of the rest of it.
    package var until: [Int]
    /// The most each has been in what has been given out since the levels were last taken.
    private var since: [Float]

    package init(voices: Int) {
        now = [Float](repeating: 0, count: voices)
        since = now
        until = [Int](repeating: 0, count: voices)
    }

    package mutating func clear() {
        for voice in now.indices {
            now[voice] = 0
            since[voice] = 0
            until[voice] = 0
        }
    }

    /// The frames from `from` up to `to` of the tick whose levels are `now` have been given out.
    package mutating func heard(from: Int, to: Int) {
        for voice in now.indices where now[voice] > since[voice] && from < until[voice] && from < to { since[voice] = now[voice] }
    }

    /// Gives out the levels of what has been given out since they were last taken, and starts afresh.
    package mutating func take(into levels: UnsafeMutablePointer<Float>) {
        for voice in now.indices {
            levels[voice] = since[voice]
            since[voice] = 0
        }
    }
}
