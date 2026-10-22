// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday. It is no tracker's mixer and imitates no sound card.

/// A sound for `SampleMixer` to play: so many samples of sixteen bits, and where it goes round.
package struct MixerSound {
    var data: UnsafePointer<Int16>
    var length: Int
    /// It goes round from `loopEnd` to `loopStart` if `loopEnd` is the greater, and otherwise ends.
    var loopStart = 0, loopEnd = 0
    /// True if it turns back at each end of the part that goes round, and does not jump.
    var backAndForth = false

    var loops: Bool { loopEnd > loopStart }
}

/// The sounds of a module, kept where they stay put for as long as the module is there.
package final class SoundBank {
    package init() {}

    package private(set) var sounds: [MixerSound?] = []
    private var memory: [UnsafeMutablePointer<Int16>] = []

    /// Adds a sound and says which it is. A sound with nothing in it is kept as none.
    /// - Parameter loop: the part that goes round, if there is one: it is held to the sound.
    @discardableResult
    package func add(_ frames: [Int16], loop: (start: Int, end: Int)? = nil, backAndForth: Bool = false) -> Int {
        guard !frames.isEmpty else {
            sounds.append(nil)
            return sounds.count - 1
        }
        let data = UnsafeMutablePointer<Int16>.allocate(capacity: frames.count)
        for i in frames.indices { data[i] = frames[i] }
        memory.append(data)
        var sound = MixerSound(data: UnsafePointer(data), length: frames.count)
        if let loop {
            let end = min(loop.end, frames.count), start = max(0, loop.start)
            if end > start {
                sound.loopStart = start
                sound.loopEnd = end
                sound.backAndForth = backAndForth
            }
        }
        sounds.append(sound)
        return sounds.count - 1
    }

    /// A sound of eight bits, made sixteen.
    @discardableResult
    package func add(eightBit frames: [Int8], loop: (start: Int, end: Int)? = nil, backAndForth: Bool = false) -> Int {
        add(frames.map { Int16($0) << 8 }, loop: loop, backAndForth: backAndForth)
    }

    deinit {
        for data in memory { data.deallocate() }
    }
}

/// The mixing for the players of trackers whose own mixing is not to be had: so many channels,
/// each playing one sound at a time at any rate, as loud as it is told and where it is told between
/// left and right, all added together.
///
/// Those trackers played through whatever card the listener had: a Sound Blaster, where the program
/// did its own mixing at some twenty thousand samples a second with nothing between one sample and
/// the next, or a Gravis Ultrasound, which mixed in its own hardware. There is no one sound to be
/// had from them, and this imitates neither. It mixes at the rate of the output, with a curve
/// through each four samples of a sound, and it does two things no card of the time did so that
/// nothing clicks: a volume or a place that changes is come to over a few thousandths of a second,
/// and a note that another takes the place of dies away over as long, and is not cut dead.
package struct SampleMixer: ~Copyable {
    private struct Voice {
        var sound: MixerSound?
        /// Where it has got to, in samples and 2^32nds of one, and how far it goes for each sample
        /// of output.
        var position: Int64 = 0, step: Int64 = 0
        var backwards = false
        /// How much of it each side is to be given, and is being given now.
        var left: Float = 0, right: Float = 0, nowLeft: Float = 0, nowRight: Float = 0
        /// True for a note that is dying away: it is done with when it has.
        var dying = false
    }

    let channels: Int
    /// A channel's voice, and after them all, for each, the voice of the note it had before.
    private var voices: [Voice]
    private var volumes: [Float], sides: [Float], rates: [Double]
    /// The lowest and the highest each channel has been, as loud as it was, since its level was last taken.
    private var lows: [Float], highs: [Float]
    /// And for how many samples of output each has sounded, of what has been made since then.
    private var sounded: [Int]
    /// The channels that are left out of the sound: they play on, and are not added in.
    private var muted: [Bool]
    /// Where each channel's sound is kept for its scope, as loud as it is and before it is put to
    /// one side or the other, if it is wanted: a channel's note and the one dying away under it
    /// together, at the output's rate, at most 1 either side of nothing.
    package var waves: ChannelWaves?
    /// Each channel's sound for its scope, as it is made, one after another, each as long as the
    /// longest render yet.
    private var wave: UnsafeMutablePointer<Float>?
    private var waveLength = 0
    /// How far a voice's loudness moves in one sample of output, at most: all the way in two
    /// thousandths of a second.
    private static let ramp: Float = 1 / (0.002 * Float(outputSampleRate))

    package init(channels: Int) {
        self.channels = channels
        voices = [Voice](repeating: Voice(), count: channels * 2)
        volumes = [Float](repeating: 0, count: channels)
        sides = [Float](repeating: 0, count: channels)
        rates = [Double](repeating: 0, count: channels)
        lows = [Float](repeating: .greatestFiniteMagnitude, count: channels)
        highs = [Float](repeating: -.greatestFiniteMagnitude, count: channels)
        sounded = [Int](repeating: 0, count: channels)
        muted = [Bool](repeating: false, count: channels)
    }

    deinit {
        wave?.deallocate()
    }

    // MARK: What a player tells it

    /// Starts a sound on a channel, from a place in it. What the channel was playing dies away.
    package mutating func play(_ channel: Int, _ sound: MixerSound?, from offset: Int = 0) {
        guard channel >= 0, channel < channels else { return }
        if voices[channel].sound != nil {
            voices[channels + channel] = voices[channel]
            voices[channels + channel].dying = true
            voices[channels + channel].left = 0
            voices[channels + channel].right = 0
        }
        var voice = Voice()
        if let sound, offset < sound.length {
            voice.sound = sound
            voice.position = Int64(max(0, offset)) << 32
        }
        voices[channel] = voice
        setGains(channel)
        setStep(channel)
    }

    /// Stops a channel's sound: it dies away.
    package mutating func stop(_ channel: Int) {
        play(channel, nil)
    }

    /// How many samples of its sound a channel plays in a second.
    package mutating func setRate(_ channel: Int, _ hz: Double) {
        guard channel >= 0, channel < channels else { return }
        rates[channel] = max(0, hz)
        setStep(channel)
    }

    /// How loud a channel is, from 0 to 1, and where: from -1, all on the left, to 1.
    package mutating func setVolume(_ channel: Int, _ volume: Float, side: Float) {
        guard channel >= 0, channel < channels else { return }
        volumes[channel] = max(0, min(1, volume))
        sides[channel] = max(-1, min(1, side))
        setGains(channel)
    }

    /// Leaves channels out of the sound, or brings them back: see `Renderer.setMuted`. A mark for
    /// each channel, true for one not to be heard; a channel with no mark is heard.
    package mutating func setMuted(_ muted: [Bool]) {
        for channel in 0 ..< channels { self.muted[channel] = channel < muted.count && muted[channel] }
    }

    private mutating func setStep(_ channel: Int) {
        // (No faster than 512 samples of the sound to one of the output.)
        voices[channel].step = Int64(min(512, rates[channel] / Double(outputSampleRate)) * 4_294_967_296)
    }

    private mutating func setGains(_ channel: Int) {
        voices[channel].left = volumes[channel] * (1 - sides[channel]) * 0.5
        voices[channel].right = volumes[channel] * (1 + sides[channel]) * 0.5
    }

    // MARK: What a player asks of it

    package func isPlaying(_ channel: Int) -> Bool { voices[channel].sound != nil }
    package func side(of channel: Int) -> Float { sides[channel] }
    package func rate(of channel: Int) -> Double { rates[channel] }
    package func volume(of channel: Int) -> Float { volumes[channel] }

    /// How far each channel has swung either side of its middle, as loud as it was, since this was
    /// last asked: from 0 to 1. A channel held at one level has not swung, and is silent to the ear.
    /// And for how many samples of what was made since then it sounded, from the first.
    package mutating func takeLevels(into levels: inout HeardLevels) {
        for channel in 0 ..< min(channels, levels.now.count) {
            levels.now[channel] = lows[channel] < highs[channel] ? min(1, (highs[channel] - lows[channel]) * 0.5) : 0
            levels.until[channel] = sounded[channel]
            lows[channel] = .greatestFiniteMagnitude
            highs[channel] = -.greatestFiniteMagnitude
            sounded[channel] = 0
        }
    }

    // MARK: The mixing

    /// One sample of a sound, by its place: what lies past the end of a sound that goes round is
    /// what the sound goes on to.
    @inline(__always)
    private static func tap(_ sound: MixerSound, _ index: Int) -> Float {
        var at = index
        if sound.loops {
            if at >= sound.loopEnd {
                let length = sound.loopEnd - sound.loopStart
                let over = (at - sound.loopEnd) % (sound.backAndForth ? length * 2 : length)
                at = !sound.backAndForth ? sound.loopStart + over : over < length ? sound.loopEnd - 1 - over : sound.loopStart + over - length
            }
        } else if at >= sound.length {
            return 0
        }
        // (By way of Int, whose conversion is the processor's own; the generic one was left a call.)
        return at < 0 ? 0 : Float(Int(sound.data[at]))
    }

    /// Adds a voice to the sound, and moves it on; and adds it to `wave` too, if it is given, as
    /// loud as it is on both sides together.
    private mutating func mix(_ index: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int,
                              wave: UnsafeMutablePointer<Float>? = nil)
    {
        guard let sound = voices[index].sound else { return }
        var voice = voices[index]
        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        let scale: Float = 1 / 32768
        // (A channel's two voices are both its own: the note, and the one before it dying away.)
        let heard = !muted[index < channels ? index : index - channels]
        // (A voice on its way to silence is heard only for as long as it takes to get there.)
        var made = voice.left == 0 && voice.right == 0 ? min(count, Int((max(voice.nowLeft, voice.nowRight) / Self.ramp).rounded(.up))) : count
        for i in 0 ..< count {
            if voice.nowLeft != voice.left { voice.nowLeft += max(-Self.ramp, min(Self.ramp, voice.left - voice.nowLeft)) }
            if voice.nowRight != voice.right { voice.nowRight += max(-Self.ramp, min(Self.ramp, voice.right - voice.nowRight)) }
            if voice.dying, voice.nowLeft == 0, voice.nowRight == 0 {
                voice.sound = nil
                break
            }
            let at = Int(voice.position >> 32)
            let t = Float(UInt32(truncatingIfNeeded: voice.position)) * (1 / 4_294_967_296)
            // A curve through the four samples about the place.
            let a = Self.tap(sound, at - 1), b = Self.tap(sound, at), c = Self.tap(sound, at + 1), d = Self.tap(sound, at + 2)
            let value = (b + 0.5 * t * (c - a + t * (2 * a - 5 * b + 4 * c - d + t * (3 * (b - c) + d - a)))) * scale
            if heard {
                left[i] += value * voice.nowLeft
                right[i] += value * voice.nowRight
            }
            let loud = value * (voice.nowLeft + voice.nowRight)
            if loud < low { low = loud }
            if loud > high { high = loud }
            if let wave { wave[i] += loud }

            // On, or back, and round or about at the end.
            if voice.backwards {
                voice.position -= voice.step
                if voice.position < Int64(sound.loopStart) << 32 {
                    voice.position = (Int64(sound.loopStart) << 33) - voice.position
                    voice.backwards = false
                }
            } else {
                voice.position += voice.step
            }
            if sound.loops {
                let end = Int64(sound.loopEnd) << 32
                if voice.position >= end {
                    let length = Int64(sound.loopEnd - sound.loopStart) << 32
                    if sound.backAndForth {
                        let over = (voice.position - end) % (length * 2)
                        voice.backwards = over < length
                        voice.position = over < length ? end - 1 - over : (Int64(sound.loopStart) << 32) + over - length
                    } else {
                        voice.position = (Int64(sound.loopStart) << 32) + (voice.position - end) % length
                    }
                }
            } else if voice.position >= Int64(sound.length) << 32 {
                voice.sound = nil
                made = min(made, i + 1)
                break
            }
        }
        voices[index] = voice
        if index < channels, low <= high {
            lows[index] = min(lows[index], low)
            highs[index] = max(highs[index], high)
            sounded[index] = max(sounded[index], made)
        }
    }

    /// Makes so many samples of the sound of all the channels together, in place of what is there.
    package mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0 ..< count {
            left[i] = 0
            right[i] = 0
        }
        guard let waves else {
            for index in voices.indices { mix(index, left: left, right: right, count: count) }
            return
        }
        // (The voices are added to the sound in the same order as when no scope is kept, so that
        // the sound is the same to the last bit.)
        if waveLength < count {
            wave?.deallocate()
            wave = .allocate(capacity: count * channels)
            waveLength = count
        }
        let wave = wave!
        wave.update(repeating: 0, count: count * channels)
        for index in voices.indices {
            mix(index, left: left, right: right, count: count, wave: wave + (index < channels ? index : index - channels) * count)
        }
        for channel in 0 ..< channels {
            for i in 0 ..< count { waves.store(channel, at: i, wave[channel * count + i]) }
        }
        waves.advance(by: count)
    }
}
