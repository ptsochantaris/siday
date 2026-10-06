// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// How long a tune is played and how it ends: the same rules for every front end.

public struct PlaybackPolicy: Sendable {
    /// Passes through a looping tune before fading.
    public var loops = 1
    /// Play time for tunes whose length is unknown.
    public var defaultTime = 180.0
    /// Optional cap applied to every tune.
    public var maxTime: Double?
    /// Seconds of fade-out for a tune that is still playing when its time is up.
    public var loopFade = 20.0
    public var endFade = 1.0
    public var allSubsongs = false
    /// Zero-based song to start multi-song files at; nil means the file's own start song.
    public var startSubsong: Int?

    public init() {}

    public func firstSubsong(of renderer: any Renderer) -> Int {
        if allSubsongs { return 0 }
        return min(max(0, startSubsong ?? renderer.defaultSubsong), renderer.subsongCount - 1)
    }
}

public enum EndReason: String, Sendable {
    case playing, completed, silent, neverSounded
}

/// Renders one subsong of one tune and decides when it is over.
public final class TuneSession {
    public let renderer: any Renderer
    private let policy: PlaybackPolicy
    public private(set) var framesRendered = 0
    private var fadeStart = -1
    private var fadeFrames = 0
    private var heardSound = false
    private var silentFrames = 0
    /// Widest swing of any block so far, and how long the output has stayed well below it.
    private var loudest: Float = 0
    private var quietFrames = 0
    /// A tune that is this quiet for this long where it would loop has come to an end of its own.
    private static let restAtEnd = 0.2
    /// A fade stops early once the tune has been quiet for this long.
    private static let quietDuringFade = 0.5
    public private(set) var end = EndReason.playing

    public init(renderer: any Renderer, policy: PlaybackPolicy) {
        self.renderer = renderer
        self.policy = policy
    }

    public var finished: Bool { end != .playing }
    public var elapsed: Double { Double(framesRendered) / Double(outputSampleRate) }

    /// Length to show: the tune's own length when known, otherwise the time it will be given.
    public var displayLength: Double {
        var length = renderer.knownLength.map { renderer.endsByLooping ? $0 * Double(max(1, policy.loops)) : $0 } ?? policy.defaultTime
        if let cap = policy.maxTime { length = min(length, cap) }
        return length
    }

    private func beginFade(_ seconds: Double) {
        guard fadeStart < 0 else { return }
        fadeStart = framesRendered
        fadeFrames = max(1, Int(seconds * Double(outputSampleRate)))
    }

    /// Renders up to `frames` frames; returns how many were produced (0 once finished).
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard !finished else { return 0 }
        renderer.render(into: buffer, frames: frames)

        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        for i in 0 ..< frames * 2 {
            let v = buffer[i]
            if v < low { low = v }
            if v > high { high = v }
        }
        if high - low < 0.0005 {
            silentFrames += frames
        } else {
            heardSound = true
            silentFrames = 0
        }
        // Quiet relative to the tune itself, so a decayed last note or a chip's idle hum counts as rest.
        let quietBefore = quietFrames
        loudest = max(loudest, high - low)
        quietFrames = high - low < max(0.0005, loudest * 0.02) ? quietFrames + frames : 0

        let rate = Double(outputSampleRate)
        let t = Double(framesRendered) / rate
        // Only a tune that is still playing where it would repeat is faded: one that has come to rest
        // there has an ending and simply stops. A short jingle does not fade for longer than it lasts.
        let loopFade = min(policy.loopFade, max(3, renderer.knownLength ?? policy.loopFade))
        var endsAfterBlock = false
        if renderer.hasEnded {
            beginFade(0.25)
        } else if renderer.loopCount >= max(1, policy.loops) {
            if fadeStart < 0, Double(quietBefore) / rate >= Self.restAtEnd {
                // The repeat began somewhere inside this block; what came before it was rest.
                end = .completed
                return 0
            }
            beginFade(loopFade)
        } else if let length = renderer.knownLength {
            if !renderer.endsByLooping, fadeStart < 0, t + Double(frames) / rate >= length {
                if let fade = renderer.fileFade {
                    beginFade(fade)
                } else if Double(quietFrames) / rate >= Self.restAtEnd {
                    endsAfterBlock = true
                } else {
                    beginFade(loopFade)
                }
            }
        } else if t >= policy.defaultTime {
            beginFade(policy.loopFade)
        }
        if let cap = policy.maxTime, t >= cap { beginFade(policy.endFade) }
        if fadeStart >= 0, Double(quietFrames) / rate >= Self.quietDuringFade { endsAfterBlock = true }

        var produced = frames
        if fadeStart >= 0 {
            for i in 0 ..< frames {
                let into = framesRendered + i - fadeStart
                if into >= fadeFrames {
                    produced = i
                    end = .completed
                    break
                }
                let gain = 1 - Float(into) / Float(fadeFrames)
                buffer[i * 2] *= gain
                buffer[i * 2 + 1] *= gain
            }
        }
        framesRendered += produced
        if endsAfterBlock, !finished { end = .completed }

        if !finished {
            if heardSound, Double(silentFrames) / rate >= 5 {
                end = .silent
            } else if !heardSound, Double(silentFrames) / rate >= 10 {
                end = .neverSounded
            }
        }
        return produced
    }
}
