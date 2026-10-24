// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// What a recording is read from, some samples at a time, from its start to its end: a WAV file, or
/// a decoder of a file kept smaller.
public protocol RecordingSource: AnyObject {
    var channels: Int { get }
    var sampleRate: Int { get }
    /// The title and artist the file is tagged with; empty where it has none.
    var title: String { get }
    var artist: String { get }
    /// How many samples of each channel there are, where the file says.
    var length: Int? { get }
    /// Reads on to the next samples: how many of each channel there are, nought at the end.
    func next() -> Int
    /// A channel's samples from the last `next`, from -1 to 1.
    func samples(of channel: Int) -> UnsafePointer<Float>
    /// Back to the start.
    func restart()
}

/// Plays a recording: the music as it was heard, a sample at a time, brought to the player's rate.
///
/// It has a voice for each of its sides, left and right, or one for a recording in mono: the lights,
/// the scopes and the picture have those to follow, and either can be left out. Each voice is the
/// recording's own side, before the listener's settings: heard in mono, both are heard in both speakers.
public final class RecordingRenderer<Source: RecordingSource>: Renderer {
    private let source: Source
    private let resampler: Resampler
    private let voices: Int
    private let mono: Bool
    /// What the samples are multiplied by: to bring recordings to the loudness of every other kind of tune.
    private let gain: Float

    /// The input as far as it has been read and not yet left behind, each voice's in its own row of
    /// `capacity`: from input sample `base` (which may be before the first, as silence) on, `held` of them.
    private var input: UnsafeMutablePointer<Float>
    private var capacity: Int
    /// Each voice's output samples, as they are made, before they are put together.
    private var made: UnsafeMutablePointer<Float>
    private var madeCapacity = 4096
    private var base = 0, held = 0
    /// The place of the next output sample: `phase / resampler.places` of the way from input sample
    /// `position` to the one after it.
    private var position = 0, phase = 0
    /// True once the source has come to its end, and silence has been put after it; and how many samples
    /// it had.
    private var drained = false
    private var inputLength = 0
    public private(set) var hasEnded = false

    public let info: TuneInfo
    public var knownLength: Double? { source.length.map { Double($0) / Double(source.sampleRate) } }

    public init(_ source: Source, format: String, detail: String, gain: Float, options: LoadOptions) throws(TuneError) {
        guard source.channels == 1 || source.channels == 2 else {
            throw .unsupported("a recording of \(source.channels) channels")
        }
        guard source.sampleRate >= 1000, source.sampleRate <= 384_000 else {
            throw .malformed("a recording at \(source.sampleRate) samples a second")
        }
        self.source = source
        voices = source.channels
        mono = options.stereo == .mono
        self.gain = gain
        resampler = Resampler(from: source.sampleRate, to: outputSampleRate)
        capacity = 8192
        input = .allocate(capacity: capacity * voices)
        made = .allocate(capacity: madeCapacity * voices)
        var info = TuneInfo(format: format)
        info.title = source.title
        info.author = source.artist
        info.detail = detail
        self.info = info
        levels = [Float](repeating: 0, count: voices)
        onsets = [Onset](repeating: Onset(), count: voices)
        muted = [Bool](repeating: false, count: voices)
        start()
    }

    deinit {
        input.deallocate()
        made.deallocate()
    }

    /// Starts again from the beginning, with silence before it as far as the filter reaches back.
    private func start() {
        base = -(resampler.taps - 1)
        held = resampler.taps - 1
        for voice in 0 ..< voices { (input + voice * capacity).update(repeating: 0, count: held) }
        position = 0
        phase = 0
        drained = false
        inputLength = 0
        hasEnded = false
    }

    public func select(subsong _: Int) {
        source.restart()
        start()
        for voice in 0 ..< voices {
            levels[voice] = 0
            onsets[voice] = Onset()
        }
    }

    /// Makes room for `count` more input samples after those held, leaving behind those the next output
    /// sample no longer reaches.
    private func room(for count: Int) {
        let needed = position - resampler.taps + 1 - base
        if needed > 0 {
            let kept = held - needed
            for voice in 0 ..< voices {
                let row = input + voice * capacity
                row.update(from: row + needed, count: kept)
            }
            base += needed
            held = kept
        }
        guard held + count > capacity else { return }
        var larger = capacity * 2
        while held + count > larger { larger *= 2 }
        let grown = UnsafeMutablePointer<Float>.allocate(capacity: larger * voices)
        for voice in 0 ..< voices { (grown + voice * larger).update(from: input + voice * capacity, count: held) }
        input.deallocate()
        input = grown
        capacity = larger
    }

    /// Reads on until the input reaches as far as the next output sample needs, or to the source's end:
    /// false if it has ended there.
    private func fill() -> Bool {
        while base + held <= position + resampler.taps {
            if drained { return false }
            let count = source.next()
            if count <= 0 {
                // The filter reaches past the end into silence.
                room(for: resampler.taps)
                for voice in 0 ..< voices { (input + voice * capacity + held).update(repeating: 0, count: resampler.taps) }
                held += resampler.taps
                drained = true
                continue
            }
            room(for: count)
            // No further than full scale either way, as a decoder to sixteen bits has it: a decoder of
            // sound kept smaller may go a little past it in a loud recording, and a broken packet far
            // past it (the first of one of Dangerous Streets' tracks, to a thousand times as loud).
            for voice in 0 ..< voices {
                let from = source.samples(of: voice), to = input + voice * capacity + held
                for i in 0 ..< count { to[i] = max(-1, min(1, from[i])) }
            }
            held += count
            inputLength += count
        }
        return true
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        if frames > madeCapacity {
            made.deallocate()
            madeCapacity = frames
            made = .allocate(capacity: madeCapacity * voices)
        }
        var done = 0
        while done < frames, !hasEnded {
            guard fill(), !drained || position < inputLength else {
                hasEnded = true
                break
            }
            // As many output samples as the input held reaches, up to the recording's end.
            let reach = base + held - resampler.taps, end = drained ? inputLength : Int.max
            var run = 0, next = position, nextPhase = phase
            while done + run < frames, next < reach, next < end {
                run += 1
                nextPhase += resampler.step
                next += nextPhase / resampler.places
                nextPhase %= resampler.places
            }
            for voice in 0 ..< voices { resample(voice, run, into: made + voice * madeCapacity + done) }
            position = next
            phase = nextPhase
            done += run
        }
        if done < frames {
            for voice in 0 ..< voices { (made + voice * madeCapacity + done).update(repeating: 0, count: frames - done) }
        }
        // Each voice as it is, for its light, its scope and the notes it strikes; then as it is heard.
        for voice in 0 ..< voices {
            let samples = made + voice * madeCapacity
            note(voice, samples, frames)
            if let waves { for offset in 0 ..< frames { waves.store(voice, at: offset, samples[offset]) } }
            if muted[voice] { samples.update(repeating: 0, count: frames) }
        }
        waves?.advance(by: frames)
        let left = made, right = voices == 1 ? made : made + madeCapacity
        let gain = gain
        if voices == 2, mono {
            let half = gain * 0.5
            for i in 0 ..< frames {
                let sample = (left[i] + right[i]) * half
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            }
        } else {
            for i in 0 ..< frames {
                buffer[i * 2] = left[i] * gain
                buffer[i * 2 + 1] = right[i] * gain
            }
        }
    }

    /// Makes `count` output samples of a voice, from the next one's place on.
    private func resample(_ voice: Int, _ count: Int, into output: UnsafeMutablePointer<Float>) {
        let taps = resampler.taps, width = 2 * taps, step = resampler.step, places = resampler.places
        let exact = resampler.exact, rows = Double(resampler.rows)
        // (The input sample `taps - 1` before the place is the first of a row's.)
        let first = input + voice * capacity - base - taps + 1
        var position = position, phase = phase
        resampler.weights.withUnsafeBufferPointer { weights in
            let weights = weights.baseAddress!
            for i in 0 ..< count {
                let samples = first + position
                if exact {
                    output[i] = Self.sum(samples, weights + phase * width, width)
                } else {
                    // Between the two rows it lies between.
                    let place = Double(phase) * rows / Double(places)
                    let row = Int(place)
                    let a = Self.sum(samples, weights + row * width, width)
                    let b = Self.sum(samples, weights + (row + 1) * width, width)
                    output[i] = a + (b - a) * Float(place - Double(row))
                }
                phase += step
                position += phase / places
                phase %= places
            }
        }
    }

    /// The weighted sum of `count` samples, eight at a time.
    @inline(__always) private static func sum(_ samples: UnsafePointer<Float>, _ weights: UnsafePointer<Float>, _ count: Int) -> Float {
        var total = SIMD8<Float>()
        var k = 0
        while k < count {
            total += UnsafeRawPointer(samples + k).loadUnaligned(as: SIMD8<Float>.self)
                * UnsafeRawPointer(weights + k).loadUnaligned(as: SIMD8<Float>.self)
            k += 8
        }
        return total.sum()
    }

    // MARK: Voices

    public var channelCount: Int { voices }
    public var channelsAreSampled: Bool { true }

    /// The loudest each voice has been since it was last asked, and when it last grew suddenly louder.
    private var levels: [Float]
    private var onsets: [Onset]
    private var muted: [Bool]
    private var waves: ChannelWaves?

    /// A sudden rise in how loud a voice is, which is taken for a note struck: how loud it is over the
    /// last hundredth of a second, against the last third of a second, and how long since the last.
    private struct Onset {
        var fast: Float = 0, slow: Float = 0
        var quiet = 0
        var struck = false
    }

    private static var fastFall: Float { 1 - 1 / 480 }
    private static var slowFall: Float { 1 - 1 / 16000 }

    /// Notes how loud a voice has been over so many samples, and whether it has struck a note.
    private func note(_ voice: Int, _ samples: UnsafePointer<Float>, _ count: Int) {
        var level = levels[voice]
        var onset = onsets[voice]
        let fastFall = Self.fastFall, slowFall = Self.slowFall
        for i in 0 ..< count {
            let value = samples[i]
            level = max(level, abs(value))
            let power = value * value
            onset.fast = onset.fast * fastFall + power * (1 - fastFall)
            onset.slow = onset.slow * slowFall + power * (1 - slowFall)
            if onset.quiet > 0 {
                onset.quiet -= 1
            } else if onset.fast > 1e-4, onset.fast > onset.slow * 4 {
                // (Then none for a tenth of a second: a note is struck once.)
                onset.struck = true
                onset.quiet = outputSampleRate / 10
            }
        }
        levels[voice] = level
        onsets[voice] = onset
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< voices {
            levels[voice] = min(1, self.levels[voice])
            self.levels[voice] = 0
        }
    }

    /// A recording has no pitches to give, only the notes it can be heard to strike.
    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        for voice in 0 ..< voices {
            pitches[voice] = 0
            struck[voice] = onsets[voice].struck
            onsets[voice].struck = false
        }
    }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< voices { sides[voice] = voices == 1 ? 0 : voice == 0 ? -1 : 1 }
    }

    public func keepChannelWaves() -> ChannelWaves? {
        if waves == nil { waves = ChannelWaves(voices: voices, rate: Double(outputSampleRate), fullSwing: 1) }
        return waves
    }

    public func setMuted(_ muted: [Bool]) {
        for voice in 0 ..< voices { self.muted[voice] = voice < muted.count && muted[voice] }
    }
}
