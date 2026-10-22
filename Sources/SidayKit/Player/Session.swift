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
        let songs = renderer.songs
        return Self.playedInTurn(songs.map { $0.length }, empty: songs.map { $0.empty }, shortest: shortestSong)
    }

    /// Which of a tune's songs are played when they are played in turn, from how long each is where
    /// that is known: all but those shorter than `shortest` seconds. A song of unknown length is
    /// played, since it cannot be said to be short. And if none of them is as long as that, all
    /// are: a file of nothing but sound effects is there to be heard as much as any other. A song
    /// that is known to have nothing in it (see `SongInfo.empty`) is passed over however long it
    /// is, so long as there is another to play. The rule is here, and in this form, so that a
    /// front end that only has the lengths can use it.
    public static func playedInTurn(_ lengths: [Double?], empty: [Bool] = [], shortest: Double) -> [Bool] {
        let something = lengths.indices.map { !($0 < empty.count && empty[$0]) }
        guard something.contains(true) else { return lengths.map { _ in true } }
        let longEnough = lengths.indices.map { something[$0] && (lengths[$0].map { $0 >= shortest } ?? true) }
        return longEnough.contains(true) ? longEnough : something
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
    /// Which side each voice was heard from in those frames, from -1 on the left to 1 on the right.
    /// See `Renderer.takeChannelSides`.
    public private(set) var channelSides: [Float]
    /// Which voices were playing samples in those frames, and not sounds a chip makes of itself.
    /// See `Renderer.takeChannelsSampled`.
    public private(set) var channelsSampled: [Bool]
    /// The same for the block in which the sound came back after a silence, kept with it.
    private var levelsAhead: [Float]
    private var pitchesAhead: [Float]
    private var struckAhead: [Bool]
    private var sidesAhead: [Float]
    private var sampledAhead: [Bool]

    /// How a song came to its end, as a session found out by playing it: how many frames it gave,
    /// and where its fade began and how long it was, if it had one.
    public struct Ending: Sendable {
        public var frames: Int
        public var fadeStart: Int
        public var fadeFrames: Int
    }

    /// How this session ended, once it has: for playing the song again to the same end, see
    /// `init(renderer:policy:following:)`.
    public var ending: Ending? {
        finished ? Ending(frames: framesRendered, fadeStart: fadeStart, fadeFrames: fadeFrames) : nil
    }

    /// The ending this session is to come to, if it was given one.
    private let script: Ending?

    /// Another player of the same song, at the same place in it, with some of its voices left out
    /// (`Renderer.setMuted`): if there is one, it is what is heard, while the session goes on judging
    /// the song by `renderer`, whole. So a song with voices left out as it plays lasts as long as
    /// the whole song does, and fades where that fades, as one played to an ending already found
    /// does (`init(renderer:policy:following:)`); and the voices can be left out and brought back
    /// at any moment, since this player only has to be told. It must have been given as many frames
    /// as the session has (`framesRendered`) when it is set.
    public var heard: (any Renderer)?

    public init(renderer: any Renderer, policy: PlaybackPolicy) {
        self.renderer = renderer
        self.policy = policy
        script = nil
        channelLevels = [Float](repeating: 0, count: renderer.channelCount)
        levelsAhead = channelLevels
        channelPitches = channelLevels
        pitchesAhead = channelLevels
        channelStruck = [Bool](repeating: false, count: renderer.channelCount)
        struckAhead = channelStruck
        channelSides = channelLevels
        sidesAhead = channelLevels
        channelsSampled = channelStruck
        sampledAhead = channelStruck
    }

    /// A session that plays a song to an ending already found, and judges nothing for itself: for
    /// a song with some of its voices left out (`Renderer.setMuted`), which is to last as long as
    /// the whole song does and fade where it fades, though by its own sound it might be taken to
    /// have fallen silent long before.
    public init(renderer: any Renderer, policy: PlaybackPolicy, following ending: Ending) {
        self.renderer = renderer
        self.policy = policy
        script = ending
        channelLevels = [Float](repeating: 0, count: renderer.channelCount)
        levelsAhead = channelLevels
        channelPitches = channelLevels
        pitchesAhead = channelLevels
        channelStruck = [Bool](repeating: false, count: renderer.channelCount)
        struckAhead = channelStruck
        channelSides = channelLevels
        sidesAhead = channelLevels
        channelsSampled = channelStruck
        sampledAhead = channelStruck
    }

    deinit {
        soundAhead?.deallocate()
    }

    public var finished: Bool { end != .playing }
    public var elapsed: Double { Double(framesRendered) / Double(outputSampleRate) }
    /// Seconds of silence up to this moment. When a tune ends as `.silent` or `.neverSounded`, this is
    /// the wait that showed it was over, and no part of the tune.
    public var silence: Double { Double(silentFrames) / Double(outputSampleRate) }

    /// How long a tune of a known length plays for: for one that ends by looping, its first pass and
    /// each pass after it, which may be shorter (a tune that goes back to a place after its beginning).
    private func playedLength(_ known: Double) -> Double {
        guard renderer.endsByLooping else { return known }
        return known + Double(max(1, policy.loops) - 1) * (renderer.loopLength ?? known)
    }

    /// How long the tune turned out to play for, once it is over and if it ended on its own terms: up
    /// to where its ending began, the fade after its last time round or its stopping, or to where it
    /// came to rest. `displayLength` is what that was expected to be, which for a tune that goes back
    /// to a place after its beginning, or that was taken to go round and did not, may not be it. Nil
    /// while it plays, and for one that ended by falling silent (whose silence is no part of it).
    public var playedLength: Double? {
        guard finished, end != .silent, end != .neverSounded else { return nil }
        return Double(fadeStart >= 0 ? fadeStart : framesRendered) / Double(outputSampleRate)
    }

    /// Length to show: the tune's own length when known, otherwise the time it will be given.
    public var displayLength: Double {
        var length = renderer.knownLength.map(playedLength) ?? policy.defaultTime
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
                channelSides[voice] = sidesAhead[voice]
                channelsSampled[voice] = sampledAhead[voice]
                // (A note is struck once, though the block it was struck in may be given out in parts.)
                struckAhead[voice] = false
            }
        }
        if done < frames {
            renderer.render(into: buffer + done * 2, frames: frames - done)
            takeVoices(levels: &channelLevels, pitches: &channelPitches, struck: &channelStruck, sides: &channelSides, sampled: &channelsSampled, over: done > 0)
        }
    }

    /// What each voice's sound is kept in for its scope, once asked for (`keepChannelWaves`).
    private var waves: ChannelWaves?
    /// What the sound last rendered was turned down by at a fade: the lights are dimmed by it, and
    /// the scopes made smaller.
    private var heardGain: Float = 1

    /// Starts keeping what each voice sounds like, for its scope, if the player can. Returns
    /// false if it cannot.
    @discardableResult
    public func keepChannelWaves() -> Bool {
        if waves == nil { waves = renderer.keepChannelWaves() }
        return waves != nil
    }

    /// Each voice's scope, as the sound given out was `behind` frames ago: `ChannelWaves.points`
    /// bytes a voice, one voice after another, `renderer.channelCount` of them (see
    /// `ChannelWaves.take`). Flat for every voice of a player that keeps none, and while a
    /// silence that was played through to find whether the tune goes on is given out.
    public func takeChannelWaves(into scopes: UnsafeMutablePointer<UInt8>, behind: Int) {
        let count = renderer.channelCount
        guard let waves, silenceAhead == 0 else {
            scopes.update(repeating: 128, count: count * ChannelWaves.points)
            return
        }
        // Where the sound after a silence is being given out, the player has made all of it already.
        let unheard = soundAhead != nil ? soundAheadFrames - soundAheadGiven : 0
        let speaker = renderer.speakerChannel
        for voice in 0 ..< count {
            let pitch = voice < channelPitches.count ? channelPitches[voice] : 0
            let periodic = voice != speaker && !(voice < channelsSampled.count && channelsSampled[voice])
            waves.take(voice, pitch: pitch, periodic: periodic, behind: behind + unheard, loudness: heardGain, into: scopes + voice * ChannelWaves.points)
        }
    }

    /// Asks the renderer how loud its voices have been and what they are playing. Where some of the
    /// frames these are for came from somewhere else, each voice keeps the louder of what it has and
    /// what the renderer says, the later pitch and side, and a note struck in either.
    private func takeVoices(levels: inout [Float], pitches: inout [Float], struck: inout [Bool], sides: inout [Float], sampled: inout [Bool], over: Bool = false) {
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
                renderer.takeChannelSides(into: taken)
                for voice in 0 ..< count { sides[voice] = taken[voice] }
                renderer.takeChannelsSampled(into: marks)
                for voice in 0 ..< count { sampled[voice] = marks[voice] }
            }
        }
    }

    /// Plays a tune that has fallen silent on, unheard, to find whether it is a pause or the end.
    /// - Returns: true if the sound comes back within `longestPause` and before the tune is over.
    ///   The silence up to there and the block the sound came back in are then kept, to be given out
    ///   as the tune's next frames.
    private func soundComesBack() -> Bool {
        let rate = Double(outputSampleRate)
        var over = renderer.knownLength.map(playedLength) ?? policy.defaultTime
        if let cap = policy.maxTime { over = min(over, cap) }
        let block = soundAhead ?? .allocate(capacity: Self.aheadFrames * 2)
        soundAhead = block

        var ahead = 0
        while Double(ahead) / rate < Self.longestPause, Double(framesRendered + ahead) / rate < over {
            renderer.render(into: block, frames: Self.aheadFrames)
            takeVoices(levels: &levelsAhead, pitches: &pitchesAhead, struck: &struckAhead, sides: &sidesAhead, sampled: &sampledAhead)
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
    /// The next of the song for a session that was given its ending: what the player makes, faded
    /// where the ending fades and stopped where it stops.
    private func follow(_ script: Ending, into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        next(into: buffer, frames: frames)
        heard?.render(into: buffer, frames: frames)
        let produced = max(0, min(frames, script.frames - framesRendered))
        if script.fadeStart >= 0 {
            for i in 0 ..< produced where framesRendered + i >= script.fadeStart {
                let gain = max(0, 1 - Float(framesRendered + i - script.fadeStart) / Float(max(1, script.fadeFrames)))
                buffer[i * 2] *= gain
                buffer[i * 2 + 1] *= gain
            }
            if framesRendered >= script.fadeStart {
                let gain = max(0, 1 - Float(framesRendered - script.fadeStart) / Float(max(1, script.fadeFrames)))
                for voice in channelLevels.indices { channelLevels[voice] *= gain }
                heardGain = gain
            }
        }
        framesRendered += produced
        if framesRendered >= script.frames { end = .completed }
        return produced
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        heardGain = 1
        guard !finished else { return 0 }
        if let script { return follow(script, into: buffer, frames: frames) }
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

        // What is heard, if it is not the song whole, is now that song's sound in its place: what
        // follows is done to it as it would have been to the song's.
        heard?.render(into: buffer, frames: frames)

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
            // The lights fade with the sound, and the scopes with them.
            let gain = max(0, 1 - Float(framesRendered - fadeStart) / Float(fadeFrames))
            for voice in channelLevels.indices { channelLevels[voice] *= gain }
            heardGain = gain
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
