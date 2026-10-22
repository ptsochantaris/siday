// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday. What OctaMED Soundstudio's mixing does with a sample (where it ends and goes
// round, how loud each side gets it, what its echo is) was learned from the description of the file
// format and by setting this beside OctaMED's own player run in an emulated Amiga. None of its code
// is here, and the sound is not made as it made it: see below.

import SidayFoundation

/// What is told to the mixer, for setting beside OctaMED's own: see `MEDRenderer.mixEvents`.
public struct MEDMixEvent: Sendable {
    public enum Kind: Int, Sendable {
        /// A tick ends: `a` is the tempo, as the song has it then.
        case tick
        /// A note: `a` where its sample is, `b` how far on its right half is, `c` where it starts,
        /// `d` where it ends, `e` how long its repeat is, `f` what kind it is (1 if it repeats, 2 if
        /// it goes back and forth, 4 if it is played backwards, 8 for sixteen bits, 16 for stereo).
        case note
        case silence
        /// The next waveform a synthetic sound is given is to be started at once.
        case fresh
        /// A synthetic sound's waveform: `a` is where its length is, with the waveform after it.
        case waveform
        /// `a` is the volume, of 64, and `b` where between left (-16) and right (16).
        case volume
        /// `a` is how many samples a second the track's sample is played at.
        case rate
        /// `a` is how many times 256 samples the track's sample is moved along, back or forth.
        case jump
        case echoDepth
        case separation
    }

    public var kind: Kind
    public var track: Int
    public var a = 0, b = 0, c = 0, d = 0, e = 0, f = 0
}

/// The mixing of OctaMED Soundstudio's "mixing mode": any number of tracks, up to 64, each playing
/// a sample of eight or sixteen bits, in mono or stereo, at any pitch, placed anywhere between left
/// and right, all added together, with an echo over the whole if the song asks for one.
///
/// OctaMED mixed for whatever it was playing through: the Amiga's own eight bits, or a sound card.
/// So there is no one sound to be had from it as there is from the Amiga's four voices, and this
/// does not imitate any: it mixes at the rate of the output, smoothly between the samples, in more
/// bits than any card had. What it keeps is what a tune's composer set: how loud a volume is, and
/// how a place between left and right divides a track between the sides; where a sample ends and
/// repeats, forwards or back and forth; the echo's length and how fast it dies away; and how far
/// the two sides are brought together or pushed apart.
///
/// One thing of OctaMED's own is not kept. It made a sample of sixteen bits quieter by halving it,
/// as many times as it took, so that such a sample had seven volumes and no more. Here it has all
/// sixty-four, as a sample of eight bits had.
struct MEDMixer: ~Copyable {
    private struct Channel {
        var silent = true
        var repeats = false, backAndForth = false, backwards = false
        var sixteenBit = false, stereo = false
        /// True if the next waveform given is to be played from its start at once, and not when
        /// the one that is playing comes round.
        var fresh = true
        /// Where the sample is in the module's memory, and how far on its right half is.
        var sample = 0, right = 0
        /// How many samples there are in it (for knowing what lies either side of the one played).
        var frames = 0
        /// Where it has got to: a sample, and a part of one in 2^32nds.
        var offset = 0
        var fraction: UInt32 = 0
        /// How far it moves for each sample of output, in 2^32nds of a sample.
        var step: UInt64 = 0
        /// Where it ends, or turns, and how long the part that repeats is.
        var end = 0, restart = 0
        /// A waveform to go over to when this one comes round: nought for none.
        var nextSample = 0, nextEnd = 0
        /// How much of it each side is given, and where that puts it: from -1 on the left to 1.
        var leftGain: Float = 0, rightGain: Float = 0, side: Float = 0
        /// The volume without the place between the sides, for the lights.
        var loudness: Float = 0
        var rate = 0
        var struck = false
        /// True for a track that is left out of the sound: it plays on, and is not added in.
        var muted = false
        /// How far it has swung either side of its middle, at its volume, since the lights were last told.
        var peak: Float = 0
    }

    private let memory: UnsafePointer<Int8>
    private let memorySize: Int
    private let channels: UnsafeMutablePointer<Channel>
    let count: Int
    /// True if any of the tracks is left out of the sound.
    private var anyMuted = false
    private let stereo: Bool
    /// What every channel is divided by, so that all of them at their loudest do not overflow.
    private let share: Float
    private let rate: Int

    /// The echo: how many samples long, where in it the next sample goes, and what it holds.
    private let echoKind: Int
    private let echoLength: Int
    private var echoAt = 0
    private var echoGain: Float
    private let echoLeft: UnsafeMutablePointer<Float>, echoRight: UnsafeMutablePointer<Float>
    /// How much of each side is taken from the other (below nought) or given to it.
    private var cross: Float = 0

    /// When this is not nil, everything the mixer is told is written down.
    var events: [MEDMixEvent]?
    /// Where each track's sound is kept for its scope, if it is wanted: its sample at its volume,
    /// before it is divided between the sides and added to the others. (Of a stereo sample, the
    /// half for the side it is nearer.) A track at its loudest swings one either side of nothing.
    var waves: ChannelWaves?

    /// - Parameters:
    ///   - channels: how many tracks are mixed.
    ///   - stereo: false to mix every track to the middle.
    ///   - freePan: true if the song may place its tracks anywhere, which costs it half its volume.
    ///   - volumeAdjust: a percentage by which the whole is made louder or quieter.
    ///   - echo: 0 for none, 1 for an echo, 2 for one that crosses from side to side.
    ///   - echoMilliseconds: how long the echo takes to come back.
    init(memory: UnsafePointer<Int8>, size: Int, rate: Int, channels: Int, stereo: Bool, freePan: Bool, volumeAdjust: Int, echo: Int,
         echoDepth: Int, echoMilliseconds: Int, separation: Int) {
        self.memory = memory
        memorySize = size
        self.rate = rate
        count = max(1, min(MEDModule.mostTracks, channels))
        self.stereo = stereo
        self.channels = .allocate(capacity: count)
        self.channels.initialize(repeating: Channel(), count: count)
        // In stereo a track is as a rule all on one side, so each side has half of them to carry.
        let sharing = stereo && !freePan && count > 1 ? count / 2 : count
        share = Float(volumeAdjust == 0 ? 100 : volumeAdjust) / (100 * Float(sharing))
        echoKind = echo == 1 || echo == 2 ? echo : 0
        echoLength = echoKind == 0 ? 0 : max(1, Int(Int64(echoMilliseconds) * Int64(rate) / 1000))
        echoLeft = .allocate(capacity: max(1, echoLength))
        echoRight = .allocate(capacity: max(1, echoLength))
        echoLeft.initialize(repeating: 0, count: max(1, echoLength))
        echoRight.initialize(repeating: 0, count: max(1, echoLength))
        echoGain = 0.5
        setEchoDepth(echoDepth, quietly: true)
        setSeparation(separation, quietly: true)
    }

    deinit {
        channels.deallocate()
        echoLeft.deallocate()
        echoRight.deallocate()
    }

    private mutating func note(_ kind: MEDMixEvent.Kind, _ track: Int, _ a: Int = 0, _ b: Int = 0, _ c: Int = 0, _ d: Int = 0, _ e: Int = 0,
                               _ f: Int = 0) {
        events?.append(MEDMixEvent(kind: kind, track: track, a: a, b: b, c: c, d: d, e: e, f: f))
    }

    /// Marks the end of a tick in what is written down.
    mutating func tick(tempo: Int) {
        note(.tick, 0, tempo)
    }

    // MARK: What the player tells it

    /// Starts a sample on a track.
    /// - Parameters:
    ///   - sample: where it is in the module's memory, and `bytes` how long, a side.
    ///   - repeatStart: where the part that repeats begins, in samples, and `repeatLength` how
    ///     long it is: nought for a sample that is played once.
    ///   - from: how many samples in to start.
    mutating func play(_ track: Int, sample: Int, bytes: Int, sixteenBit: Bool, stereo: Bool, repeatStart: Int, repeatLength: Int,
                       backAndForth: Bool, backwards: Bool, from: Int) {
        guard track < count else { return }
        var now = channels[track]
        let frames = sixteenBit ? bytes >> 1 : bytes
        now.frames = frames
        now.repeats = repeatLength > 0
        now.backAndForth = now.repeats && backAndForth
        now.backwards = backwards
        now.restart = repeatLength
        if now.repeats, !backwards {
            now.end = repeatStart &+ repeatLength
            now.offset = from < now.end ? from : 0
        } else if now.repeats {
            // Backwards, from the end of the sample down to where the repeat begins, and round.
            now.end = repeatStart - 1
            now.offset = frames - 1
            if frames - 1 - repeatStart > from { now.offset -= from }
        } else if backwards {
            now.end = -1
            now.offset = frames - 1 - from >= 0 ? frames - 1 - from : frames - 1
        } else {
            now.end = frames
            now.offset = from < frames ? from : 0
        }
        now.fraction = 0
        now.nextSample = 0
        now.sample = sample
        now.right = stereo ? bytes : 0
        now.stereo = stereo
        now.sixteenBit = sixteenBit
        now.silent = false
        now.struck = true
        channels[track] = now
        note(.note, track, sample, now.right, now.offset, now.end, now.restart,
             (now.repeats ? 1 : 0) | (now.backAndForth ? 2 : 0) | (backwards ? 4 : 0) | (sixteenBit ? 8 : 0) | (stereo ? 16 : 0))
    }

    mutating func silence(_ track: Int) {
        guard track < count else { return }
        channels[track].silent = true
        note(.silence, track)
    }

    /// The next waveform the track is given is to be played at once.
    mutating func expectWaveform(_ track: Int) {
        guard track < count else { return }
        channels[track].fresh = true
        note(.fresh, track)
    }

    /// Gives a track the waveform of a synthetic sound: two bytes of length, in words, and then
    /// the waveform, which goes round and round. A track that is playing one already goes over to
    /// the new one when the old comes round.
    mutating func setWaveform(_ track: Int, at place: Int) {
        guard track < count else { return }
        let high = place >= 0 && place < memorySize ? Int(UInt8(bitPattern: memory[place])) : 0
        let low = place >= -1 && place + 1 < memorySize ? Int(UInt8(bitPattern: memory[place + 1])) : 0
        let length = ((high << 8 | low) * 2) & 0xFFFF
        var now = channels[track]
        now.nextSample = place + 2
        now.nextEnd = length
        if now.fresh {
            now.sample = place + 2
            now.end = length
            now.restart = length
            now.frames = length
            now.offset = 0
            now.struck = true
        }
        now.fresh = false
        now.silent = false
        now.repeats = true
        now.backAndForth = false
        now.backwards = false
        now.sixteenBit = false
        now.stereo = false
        now.right = 0
        channels[track] = now
        note(.waveform, track, place)
    }

    /// Sets how loud a track is, of 64, and where it lies between left (-16) and right (16).
    mutating func setVolume(_ track: Int, _ volume: Int, place: Int) {
        guard track < count else { return }
        note(.volume, track, volume, place)
        let loudness = Float(max(0, min(64, volume))) / 64
        channels[track].loudness = loudness
        let gain = loudness * share
        if !stereo {
            channels[track].leftGain = gain
            channels[track].rightGain = gain
        } else {
            let place = max(-16, min(16, place))
            channels[track].side = Float(place) / 16
            channels[track].leftGain = gain * Float(16 - place) / 32
            channels[track].rightGain = gain * Float(16 + place) / 32
        }
    }

    /// Sets how many samples a second a track's sample is played at. None at all silences it.
    mutating func setRate(_ track: Int, _ hz: Int) {
        guard track < count else { return }
        note(.rate, track, hz)
        guard hz > 0 else {
            channels[track].silent = true
            return
        }
        channels[track].rate = hz
        channels[track].step = UInt64(Double(hz) * 4_294_967_296.0 / Double(rate))
    }

    /// Moves a track's sample along by so many times 256 samples, back or forth: unless that would
    /// take it past either end.
    mutating func jump(_ track: Int, by amount: Int) {
        guard track < count else { return }
        note(.jump, track, amount)
        // (A sample going backwards to its start has its end below nought, which OctaMED took for
        // a number too large to reach.)
        let to = channels[track].offset &+ amount * 256
        if to >= 0, UInt32(truncatingIfNeeded: to) < UInt32(truncatingIfNeeded: channels[track].end) { channels[track].offset = to }
    }

    /// How fast the echo dies away: each time round it is halved this many times.
    mutating func setEchoDepth(_ depth: Int, quietly: Bool = false) {
        if !quietly { note(.echoDepth, 0, depth) }
        var gain: Float = 1
        for _ in 0 ..< max(1, min(6, depth)) { gain *= 0.5 }
        echoGain = gain
    }

    /// How far apart the two sides are kept: from -4, most of the way together, to 4, apart by
    /// more than they were mixed.
    mutating func setSeparation(_ separation: Int, quietly: Bool = false) {
        if !quietly { note(.separation, 0, separation) }
        guard separation != 0, separation >= -4, separation <= 4 else {
            cross = 0
            return
        }
        var part: Float = 1
        for _ in 0 ..< 5 - abs(separation) { part *= 0.5 }
        cross = separation > 0 ? -part : part
    }

    /// Leaves tracks out of the sound, or brings them back: see `Renderer.setMuted`. A mark for
    /// each track, true for one not to be heard; a track with no mark is heard. A track left out
    /// is not added to the others, and so has no part in the echo, which is of them all together.
    mutating func setMuted(_ muted: [Bool]) {
        anyMuted = false
        for track in 0 ..< count {
            channels[track].muted = track < muted.count && muted[track]
            if channels[track].muted { anyMuted = true }
        }
    }

    // MARK: The lights

    /// Where a track lies between the two sides, from -1 on the left to 1 on the right.
    func side(of track: Int) -> Float { track < count ? channels[track].side : 0 }

    mutating func takeLevels(into levels: inout [Float]) {
        for track in 0 ..< min(count, levels.count) {
            levels[track] = min(1, channels[track].peak)
            channels[track].peak = 0
        }
    }

    mutating func takeNotes(into notes: inout TickNotes) {
        for track in 0 ..< min(count, notes.pitches.count) {
            notes.pitches[track] = channels[track].silent ? 0 : ChannelPitch.note(ofRate: Double(channels[track].rate))
            if channels[track].struck { notes.struck[track] = true }
            channels[track].struck = false
        }
    }

    // MARK: Sound

    /// One sample of a track's sample, by its number: nothing for one before its start or after
    /// its end, and for a sample that goes round, the one it would come to.
    @inline(__always) private func frame(_ now: Channel, _ index: Int, _ base: Int) -> Float {
        var i = index
        if i >= now.end, now.repeats, !now.backAndForth, !now.backwards, now.restart > 0 { i -= now.restart }
        guard i >= 0, i < now.frames else { return 0 }
        // (A damaged file can say its sample is longer than memory, or than a whole number in a
        // browser can count: so it is asked whether there is room before anything is added up.)
        guard base >= 0, base < memorySize else { return 0 }
        if now.sixteenBit {
            guard i < (memorySize - base) / 2 else { return 0 }
            let at = base + i * 2
            return Float(Int16(memory[at]) << 8 | Int16(UInt8(bitPattern: memory[at + 1]))) * (1.0 / 32768.0)
        }
        guard i < memorySize - base else { return 0 }
        return Float(memory[base + i]) * (1.0 / 128.0)
    }

    /// A curve through four samples, a part of the way from the second to the third.
    @inline(__always) private static func curve(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
        let c1 = (c - a) * 0.5
        let c2 = a - 2.5 * b + 2 * c - 0.5 * d
        let c3 = (d - a) * 0.5 + 1.5 * (b - c)
        return ((c3 * t + c2) * t + c1) * t + b
    }

    /// A track's sample at where it has got to, drawn smoothly through the four samples about it.
    /// - Parameter plain: true if all four are known to be in the sample and in memory, with no
    ///   going round between them: then they are read where they lie, with nothing to ask.
    @inline(__always) private func value(_ now: Channel, _ base: Int, plain: Bool) -> Float {
        // (Going backwards, the part of a sample counts down from the sample it is at.)
        let part = Float(now.fraction >> 8) * (1.0 / 16_777_216.0)
        let i = now.backwards && part > 0 ? now.offset - 1 : now.offset
        let t = now.backwards && part > 0 ? 1 - part : part
        guard plain else {
            return Self.curve(frame(now, i - 1, base), frame(now, i, base), frame(now, i + 1, base), frame(now, i + 2, base), t)
        }
        if now.sixteenBit {
            let at = memory + (base + i * 2 - 2)
            func wide(_ n: Int) -> Float { Float(Int16(at[n]) << 8 | Int16(UInt8(bitPattern: at[n + 1]))) * (1.0 / 32768.0) }
            return Self.curve(wide(0), wide(2), wide(4), wide(6), t)
        }
        let at = memory + (base + i - 1)
        return Self.curve(Float(at[0]), Float(at[1]), Float(at[2]), Float(at[3]), t) * (1.0 / 128.0)
    }

    /// What happens when a track's sample comes to its end: it stops, or goes round, or turns back.
    private func turn(_ now: inout Channel) {
        guard now.repeats else {
            now.silent = true
            return
        }
        if now.backAndForth {
            now.offset = 2 &* now.end &- now.offset
            now.end &+= now.backwards ? now.restart : 0 &- now.restart
            now.backwards.toggle()
        } else if now.backwards {
            now.offset &+= now.restart
        } else {
            now.offset &-= now.restart
            if now.nextSample != 0 {
                now.sample = now.nextSample
                now.end = now.nextEnd
                now.restart = now.nextEnd
                now.frames = now.nextEnd
            }
        }
        // A repeat too short to hold where the sample has got to is the end of it.
        if now.backwards ? now.offset <= now.end : now.offset >= now.end { now.silent = true }
    }

    private mutating func mix(_ track: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        var now = channels[track]
        let waves = track < (waves?.voices ?? 0) ? waves : nil
        guard !now.silent else {
            waves?.silence(track, count: count)
            return
        }
        if now.backwards ? now.offset <= now.end : now.offset >= now.end {
            channels[track].silent = true
            waves?.silence(track, count: count)
            return
        }
        let whole = Int(now.step >> 32)
        let part = now.step & 0xFFFF_FFFF
        // A stereo sample has a half for each side: a track that is all on one side plays that
        // side's half and not the other. When everything is going to the middle, it is the left
        // half that is heard.
        let twoHalves = now.stereo && stereo
        let heard = now.leftGain != 0 || now.rightGain != 0
        // Is the whole of the sample in memory? (One cut off by the end of its file is not.)
        let width = now.sixteenBit ? 2 : 1
        let inMemory = now.sample >= 0 && now.right <= memorySize && now.frames <= memorySize
            && now.sample + now.right + now.frames * width <= memorySize
        // For the light: the least and the most of what is played, of either half of a stereo
        // sample that is heard. (A track held at one level is not heard, and is dark.)
        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        let measuresLeft = now.leftGain != 0 || !twoHalves, measuresRight = twoHalves && now.rightGain != 0
        let nearerLeft = now.leftGain >= now.rightGain
        for i in 0 ..< count {
            if heard {
                // The four samples about this one are plainly there unless it is near an end.
                let plain = inMemory && now.offset >= 2 && now.offset + 2 < min(now.end, now.frames)
                let l = now.leftGain != 0 || !twoHalves ? value(now, now.sample, plain: plain) : 0
                let r = twoHalves ? (now.rightGain != 0 ? value(now, now.sample + now.right, plain: plain) : 0) : l
                left[i] += l * now.leftGain
                right[i] += r * now.rightGain
                if measuresLeft {
                    low = min(low, l)
                    high = max(high, l)
                }
                if measuresRight {
                    low = min(low, r)
                    high = max(high, r)
                }
                waves?.store(track, at: i, (nearerLeft ? l : r) * now.loudness)
            } else {
                waves?.store(track, at: i, 0)
            }
            let sum = UInt64(now.fraction) + part
            now.fraction = UInt32(truncatingIfNeeded: sum)
            let moved = whole + Int(sum >> 32)
            if now.backwards {
                now.offset &-= moved
                if now.offset <= now.end { turn(&now) }
            } else {
                now.offset &+= moved
                if now.offset >= now.end { turn(&now) }
            }
            if now.silent {
                if let waves { for after in i + 1 ..< count { waves.store(track, at: after, 0) } }
                break
            }
        }
        if high > low { now.peak = max(now.peak, (high - low) * 0.5 * now.loudness) }
        channels[track] = now
    }

    /// Makes `count` samples of both sides.
    mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        // The tracks that are left out of the sound, if there are any, are mixed first, and what
        // they came to is cleared away before the others are: so they move on and are measured as
        // ever, and nothing of them is in what is heard, nor in the echo that is made of it.
        // (Once round for those, if there are any, and then once for the others.)
        var leftOut = anyMuted
        repeat {
            left.update(repeating: 0, count: count)
            right.update(repeating: 0, count: count)
            for track in 0 ..< self.count where channels[track].muted == leftOut { mix(track, left: left, right: right, count: count) }
            leftOut.toggle()
        } while !leftOut
        if let waves {
            // (Any track kept for another of the file's songs, and not mixed in this one, is silent.)
            for track in min(self.count, waves.voices) ..< waves.voices { waves.silence(track, count: count) }
            waves.advance(by: count)
        }

        if echoKind != 0 {
            // What came out so long ago is added, quieter, to what comes out now: so it comes
            // round again and again, quieter each time. The crossing kind adds each side's to the other.
            for i in 0 ..< count {
                let l = echoLeft[echoAt] * echoGain, r = echoRight[echoAt] * echoGain
                left[i] += echoKind == 2 && stereo ? r : l
                right[i] += echoKind == 2 && stereo ? l : r
                echoLeft[echoAt] = left[i]
                echoRight[echoAt] = right[i]
                echoAt += 1
                if echoAt >= echoLength { echoAt = 0 }
            }
        }
        if cross != 0, stereo {
            for i in 0 ..< count {
                let l = left[i], r = right[i]
                left[i] = l + r * cross
                right[i] = r + l * cross
            }
        }
    }
}
