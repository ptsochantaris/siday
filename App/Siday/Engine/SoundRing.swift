// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Synchronization

/// Sound waiting to be heard: stereo frames that the engine's thread writes and the audio thread
/// reads, with nothing between them but two counters. The audio thread takes no lock, makes nothing
/// and waits for nothing: it copies what there is, and plays silence if there is none.
nonisolated final class SoundRing: @unchecked Sendable {
    /// Frames it holds: more than the engine sends ahead (`SongKeeper.ahead` chunks).
    static let capacity = 1 << 15
    private static let mask = capacity - 1

    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: SoundRing.capacity * 2)
    /// Frames ever written, and ever read: the difference is what is waiting.
    let written = Atomic<Int>(0)
    let read = Atomic<Int>(0)
    /// Where the audio thread is to jump to, if it is not there yet: what was waiting is dropped, as
    /// when the listener moves to another place or another tune starts.
    private let dropTo = Atomic<Int>(0)
    /// True while the listener has paused: the sound fades out over a moment, and nothing is read.
    let paused = Atomic<Bool>(false)
    /// Frames of silence played, while not paused, since the last there was anything to read: once a
    /// song's last sound has gone, how long ago that was.
    let dry = Atomic<Int>(0)

    /// The audio thread's own: how loud the sound is let through, going to 1 while playing and to
    /// 0 while paused, a little each frame, so that neither is a click.
    private var gain: Float = 0
    private static let fadeStep: Float = 1 / 480

    deinit {
        samples.deallocate()
    }

    /// Room for more, in frames.
    var room: Int {
        Self.capacity - (written.load(ordering: .acquiring) - read.load(ordering: .acquiring))
    }

    /// Adds frames after what is waiting. Only the engine's thread writes, and only as much as there is room for.
    func write(_ frames: UnsafePointer<Float>, count: Int) {
        var at = written.load(ordering: .relaxed)
        for frame in 0 ..< count {
            let place = (at & Self.mask) * 2
            samples[place] = frames[frame * 2]
            samples[place + 1] = frames[frame * 2 + 1]
            at += 1
        }
        written.store(at, ordering: .releasing)
    }

    /// Drops what is waiting: the audio thread goes on from what is written next. Returns where that is.
    @discardableResult
    func drop() -> Int {
        let at = written.load(ordering: .relaxed)
        dropTo.store(at, ordering: .releasing)
        dry.store(0, ordering: .relaxed)
        return at
    }

    /// The audio thread's turn: fills `left` and `right` with `count` frames.
    func fill(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        var at = read.load(ordering: .relaxed)
        let jump = dropTo.load(ordering: .acquiring)
        if jump > at {
            at = jump
            gain = 0
        }
        let end = written.load(ordering: .acquiring)
        let target: Float = paused.load(ordering: .relaxed) ? 0 : 1
        let from = at
        for frame in 0 ..< count {
            if gain < target { gain = min(target, gain + Self.fadeStep) } else if gain > target { gain = max(target, gain - Self.fadeStep) }
            // Paused and faded out: nothing is read, and the sound waits where it is.
            if (target == 0 && gain == 0) || at >= end {
                left[frame] = 0
                right[frame] = 0
                continue
            }
            let place = (at & Self.mask) * 2
            left[frame] = samples[place] * gain
            right[frame] = samples[place + 1] * gain
            at += 1
        }
        read.store(at, ordering: .releasing)
        if at > from {
            dry.store(0, ordering: .relaxed)
        } else if target == 1 {
            dry.add(count, ordering: .relaxed)
        }
    }
}
