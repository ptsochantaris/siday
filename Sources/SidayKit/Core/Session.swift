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
    /// When a tune's songs are played in turn, those known to be shorter than this many seconds are
    /// passed over: the sound effects and jingles that many files keep beside their music. Nought
    /// passes over none. See `playedInTurn`.
    public var shortestSong = 0.0
    /// Zero-based song to start multi-song files at; nil means the file's own start song.
    public var startSubsong: Int?

    public init() {}

    public func firstSubsong(of renderer: any Renderer) -> Int {
        if allSubsongs { return playedInTurn(of: renderer).firstIndex(of: true) ?? 0 }
        return min(max(0, startSubsong ?? renderer.defaultSubsong), renderer.subsongCount - 1)
    }

    /// The song that follows one that has ended, when a tune's songs are played in turn; nil after
    /// the last of them.
    public func subsong(after song: Int, of renderer: any Renderer) -> Int? {
        let played = playedInTurn(of: renderer)
        return played.indices.first { $0 > song && played[$0] }
    }

    public func playedInTurn(of renderer: any Renderer) -> [Bool] {
        Self.playedInTurn(renderer.songs.map { $0.length }, shortest: shortestSong)
    }

    /// Which of a tune's songs are played when they are played in turn, from how long each is where
    /// that is known: all but those shorter than `shortest` seconds. A song of unknown length is
    /// played, since it cannot be said to be short. And if none of them is as long as that, all
    /// are: a file of nothing but sound effects is there to be heard as much as any other. The
    /// rule is here, and in this form, so that a front end that only has the lengths can use it.
    public static func playedInTurn(_ lengths: [Double?], shortest: Double) -> [Bool] {
        let longEnough = lengths.map { $0.map { $0 >= shortest } ?? true }
        return longEnough.contains(true) ? longEnough : lengths.map { _ in true }
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
    /// A tune that has been silent for this long is looked into, to see whether it is over.
    private static let silenceToHaveBegun = 5.0, silenceNeverToHaveBegun = 10.0
    /// How far on a silent tune is played, unheard, to find whether its sound comes back.
    private static let longestPause = 60.0
    private static let aheadFrames = 4096
    /// What was found when a silent tune was played on: so much more silence, which is still to be
    /// given out, and then the block in which the sound came back, of which so much has been given.
    private var silenceAhead = 0
    private var soundAhead: UnsafeMutablePointer<Float>?
    private var soundAheadFrames = 0, soundAheadGiven = 0
    public private(set) var end = EndReason.playing
    /// How loud each of the tune's voices was in the frames last rendered: `renderer.channelCount` of
    /// them, each from 0 to 1. See `Renderer.takeChannelLevels`.
    public private(set) var channelLevels: [Float]
    /// What each voice was playing in those frames: its pitch, and whether a note was started on it.
    /// See `Renderer.takeChannelNotes`.
    public private(set) var channelPitches: [Float]
    public private(set) var channelStruck: [Bool]
    /// The same for the block in which the sound came back after a silence, kept with it.
    private var levelsAhead: [Float]
    private var pitchesAhead: [Float]
    private var struckAhead: [Bool]

    public init(renderer: any Renderer, policy: PlaybackPolicy) {
        self.renderer = renderer
        self.policy = policy
        channelLevels = [Float](repeating: 0, count: renderer.channelCount)
        levelsAhead = channelLevels
        channelPitches = channelLevels
        pitchesAhead = channelLevels
        channelStruck = [Bool](repeating: false, count: renderer.channelCount)
        struckAhead = channelStruck
    }

    deinit {
        soundAhead?.deallocate()
    }

    public var finished: Bool { end != .playing }
    public var elapsed: Double { Double(framesRendered) / Double(outputSampleRate) }
    /// Seconds of silence up to this moment. When a tune ends as `.silent` or `.neverSounded`, this is
    /// the wait that showed it was over, and no part of the tune.
    public var silence: Double { Double(silentFrames) / Double(outputSampleRate) }

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

    /// How far apart the lowest and the highest of some samples are.
    private static func swing(_ buffer: UnsafeMutablePointer<Float>, frames: Int) -> Float {
        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        for i in 0 ..< frames * 2 {
            let v = buffer[i]
            if v < low { low = v }
            if v > high { high = v }
        }
        return high - low
    }

    /// The tune's next frames: what was found by playing on through a silence, while there is any of
    /// that, and then the tune itself.
    private func next(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        for voice in channelLevels.indices {
            channelLevels[voice] = 0
            channelPitches[voice] = 0
            channelStruck[voice] = false
        }
        if silenceAhead > 0 {
            done = min(frames, silenceAhead)
            buffer.update(repeating: 0, count: done * 2)
            silenceAhead -= done
        }
        if done < frames, soundAheadGiven < soundAheadFrames, let soundAhead {
            let count = min(frames - done, soundAheadFrames - soundAheadGiven)
            (buffer + done * 2).update(from: soundAhead + soundAheadGiven * 2, count: count * 2)
            soundAheadGiven += count
            done += count
            for voice in channelLevels.indices {
                channelLevels[voice] = levelsAhead[voice]
                channelPitches[voice] = pitchesAhead[voice]
                channelStruck[voice] = struckAhead[voice]
                // (A note is struck once, though the block it was struck in may be given out in parts.)
                struckAhead[voice] = false
            }
        }
        if done < frames {
            renderer.render(into: buffer + done * 2, frames: frames - done)
            takeVoices(levels: &channelLevels, pitches: &channelPitches, struck: &channelStruck, over: done > 0)
        }
    }

    /// Asks the renderer how loud its voices have been and what they are playing. Where some of the
    /// frames these are for came from somewhere else, each voice keeps the louder of what it has and
    /// what the renderer says, the later pitch, and a note struck in either.
    private func takeVoices(levels: inout [Float], pitches: inout [Float], struck: inout [Bool], over: Bool = false) {
        let count = levels.count
        guard count > 0 else { return }
        withUnsafeTemporaryAllocation(of: Float.self, capacity: count * 2) { numbers in
            withUnsafeTemporaryAllocation(of: Bool.self, capacity: count) { marks in
                guard let taken = numbers.baseAddress, let marks = marks.baseAddress else { return }
                renderer.takeChannelLevels(into: taken)
                renderer.takeChannelNotes(pitches: taken + count, struck: marks)
                for voice in 0 ..< count {
                    if !over || taken[voice] > levels[voice] { levels[voice] = taken[voice] }
                    if !over || taken[count + voice] > 0 { pitches[voice] = taken[count + voice] }
                    struck[voice] = marks[voice] || (over && struck[voice])
                }
            }
        }
    }

    /// Plays a tune that has fallen silent on, unheard, to find whether it is a pause or the end.
    /// - Returns: true if the sound comes back within `longestPause` and before the tune is over.
    ///   The silence up to there and the block the sound came back in are then kept, to be given out
    ///   as the tune's next frames.
    private func soundComesBack() -> Bool {
        let rate = Double(outputSampleRate)
        var over = renderer.knownLength.map { renderer.endsByLooping ? $0 * Double(max(1, policy.loops)) : $0 } ?? policy.defaultTime
        if let cap = policy.maxTime { over = min(over, cap) }
        let block = soundAhead ?? .allocate(capacity: Self.aheadFrames * 2)
        soundAhead = block

        var ahead = 0
        while Double(ahead) / rate < Self.longestPause, Double(framesRendered + ahead) / rate < over {
            renderer.render(into: block, frames: Self.aheadFrames)
            takeVoices(levels: &levelsAhead, pitches: &pitchesAhead, struck: &struckAhead)
            // Sound from after the place where the tune goes round is the tune beginning again.
            if renderer.hasEnded || renderer.loopCount >= max(1, policy.loops) { return false }
            if Self.swing(block, frames: Self.aheadFrames) >= 0.0005 {
                silenceAhead = ahead
                soundAheadFrames = Self.aheadFrames
                soundAheadGiven = 0
                return true
            }
            ahead += Self.aheadFrames
        }
        return false
    }

    /// Renders up to `frames` frames; returns how many were produced (0 once finished).
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard !finished else { return 0 }
        next(into: buffer, frames: frames)

        let swing = Self.swing(buffer, frames: frames)
        if swing < 0.0005 {
            silentFrames += frames
        } else {
            heardSound = true
            silentFrames = 0
        }
        // Quiet relative to the tune itself, so a decayed last note or a chip's idle hum counts as rest.
        let quietBefore = quietFrames
        loudest = max(loudest, swing)
        quietFrames = swing < max(0.0005, loudest * 0.02) ? quietFrames + frames : 0

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
            // The lights fade with the sound.
            let gain = max(0, 1 - Float(framesRendered - fadeStart) / Float(fadeFrames))
            for voice in channelLevels.indices { channelLevels[voice] *= gain }
        }
        framesRendered += produced
        if endsAfterBlock, !finished { end = .completed }

        // A tune that has fallen silent may be over, or may be pausing: it is played on to find out.
        // (While what that found is still being given out, there is nothing more to find.)
        if !finished, silenceAhead == 0, soundAheadGiven == soundAheadFrames, fadeStart < 0,
           Double(silentFrames) / rate >= (heardSound ? Self.silenceToHaveBegun : Self.silenceNeverToHaveBegun),
           !soundComesBack() {
            end = heardSound ? .silent : .neverSounded
        }
        return produced
    }
}
