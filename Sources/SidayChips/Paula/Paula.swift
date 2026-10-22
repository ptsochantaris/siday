// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from pt2-clone, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md). The band-limited steps are by aciddose, written for that project.

import SidayFoundation

/// Paula, the Amiga's sound chip, as far as music needs it: four voices that each read eight-bit
/// samples out of memory at a rate of their own, two of them wired to the left and two to the right.
///
/// It runs at twice the rate the player wants, and its output is brought down afterwards (`HalfBand`).
/// (But for an AHX tune written out for comparison: the player that is compared with runs its Paula
/// at the rate of its output, with nothing after her, and so is this one run then.)
/// A voice's output is a staircase, a level held from one sample to the next, and a staircase holds
/// tones far above what can be heard; so wherever a voice steps, a band-limited step is laid over the
/// output in place of the instant one.
package struct Paula: ~Copyable {
    /// The Amiga's colour clock on a PAL machine, which is what Paula counts periods of.
    package static let clockHz = 28_375_160.0 / 8.0
    /// Paula cannot fetch samples faster than this many clock periods apart.
    package static let shortestPeriod = 113

    private struct Voice {
        var active = false
        var justStarted = false, nextSampleDue = false
        /// The two bytes Paula has fetched: the one being played and the one after it.
        var data: (Int8, Int8) = (0, 0)
        var location = -1
        var lengthCounter: UInt16 = 0
        var bytesLeft = 0
        /// The level being held: the sample, with the volume already in it.
        var level: Float = 0
        var delta: Float = 0, phase: Float = 0
        var stepDelta: Float = 0, stepPhase: Float = 0

        // What the registers were last given. Paula takes them up as she reaches for them.
        var storedLocation = -1
        var storedLength: UInt16 = 0
        var storedVolume: Float = 0, storedDelta: Float = 0

        // The band-limited steps still being played out: from `stepIndex`, which is under 16, to 16 on,
        // where the last laid over ends, and noughts beyond that.
        var stepIndex = 0, stepsLeft = 0
        var steps = InlineArray<32, Float>(repeating: 0)
        var lastLevel: Float = 0
        /// For the lights: the lowest and highest the level has been, of late.
        var swing = Swing<Float>(from: -2, to: 2)
        /// The period it was last given, and whether it has been started since its notes were asked for.
        var period = 0
        var struck = false
        /// True for a voice that is left out of the sound: it plays on, and is not added in.
        var muted = false
        /// How many times the voice has come to the end of what it was playing and gone on from where
        /// it was last pointed, since it was started: what a player that waits for that counts.
        var loops: UInt16 = 0

        /// Paula takes up a new period only as she finishes counting the old one.
        @inline(__always) mutating func refetchPeriod() {
            stepPhase = phase
            stepDelta = delta
            delta = storedDelta
            nextSampleDue = true
        }

        @inline(__always) mutating func nextSample(_ memory: UnsafePointer<Int8>, _ size: Int, _ table: UnsafePointer<Float>) {
            if bytesLeft == 0 {
                // Time to fetch a word. The length and the place to go on from are not looked at on the
                // very first fetch after a voice is started.
                if !justStarted {
                    lengthCounter &-= 1
                    if lengthCounter == 0 {
                        lengthCounter = storedLength
                        location = storedLocation
                        loops &+= 1
                    }
                }
                justStarted = false
                data.0 = location >= 0 && location < size ? memory[location] : 0
                data.1 = location >= -1 && location &+ 1 < size ? memory[location &+ 1] : 0
                location &+= 2
                bytesLeft = 2
            }

            level = Float(Int(data.0)) * storedVolume
            swing.note(level)
            if level != lastLevel {
                if stepDelta > stepPhase {
                    addStep(at: stepPhase / stepDelta, of: lastLevel - level, table)
                }
                lastLevel = level
            }

            data.0 = data.1
            bytesLeft -= 1
        }

        /// Lays a step over the samples to come. `offset` is how far into the current sample it fell.
        /// `table` is the step's points a row of sixteen to each place between two (see `Paula.init`), and
        /// all sixteen are laid at once, each worked out as it would be alone.
        @inline(__always) private mutating func addStep(at offset: Float, of amplitude: Float, _ table: UnsafePointer<Float>) {
            var f = offset * 16
            let whole = Int(f)
            f -= Float(whole)
            let rows = UnsafeRawPointer(table), row = MemoryLayout<SIMD16<Float>>.size
            let a = rows.loadUnaligned(fromByteOffset: whole &* row, as: SIMD16<Float>.self)
            let b = rows.loadUnaligned(fromByteOffset: (whole &+ 1) &* row, as: SIMD16<Float>.self)
            let step = amplitude * (a + ((b - a) * f))
            let at = stepIndex &* MemoryLayout<Float>.size
            withUnsafeMutableBytes(of: &steps) { steps in
                steps.storeBytes(of: steps.loadUnaligned(fromByteOffset: at, as: SIMD16<Float>.self) + step, toByteOffset: at, as: SIMD16<Float>.self)
            }
            stepsLeft = 16
        }

        /// The next of the steps' samples, taken out. At the sixteenth, what is left is moved back to the start.
        @inline(__always) private mutating func takeStep() -> Float {
            let sample = steps[unchecked: stepIndex]
            steps[unchecked: stepIndex] = 0
            stepIndex &+= 1
            if stepIndex == 16 {
                stepIndex = 0
                withUnsafeMutableBytes(of: &steps) { steps in
                    let half = MemoryLayout<SIMD16<Float>>.size
                    steps.storeBytes(of: steps.loadUnaligned(fromByteOffset: half, as: SIMD16<Float>.self), toByteOffset: 0, as: SIMD16<Float>.self)
                    steps.storeBytes(of: SIMD16<Float>(), toByteOffset: half, as: SIMD16<Float>.self)
                }
            }
            return sample
        }

        /// Adds `count` samples of this voice to `output`, and keeps them in `waves` as voice `number`
        /// if it is given.
        mutating func mix(into output: UnsafeMutablePointer<Float>, count: Int, _ memory: UnsafePointer<Int8>, _ size: Int,
                          _ table: UnsafePointer<Float>, waves: ChannelWaves?, number: Int)
        {
            guard active, location != -1, storedLocation != -1 else {
                waves?.silence(number, count: count)
                return
            }
            var j = 0
            while j < count {
                if nextSampleDue {
                    nextSampleDue = false
                    nextSample(memory, size, table)
                }
                var sample = level
                if stepsLeft > 0 {
                    sample += takeStep()
                    stepsLeft -= 1
                }
                if !muted { output[j] += sample }
                waves?.store(number, at: j, sample)
                phase += delta
                if phase >= 1 {
                    phase -= 1
                    refetchPeriod()
                }
                j &+= 1
            }
        }
    }

    /// A resistor and a capacitor: six decibels an octave, low-pass or, taken away from its input, high-pass.
    private struct OnePole {
        var left: Float = 0, right: Float = 0
        var a0: Float = 0, b1: Float = 0

        init() {}

        init(rate: Double, cutoff: Double) {
            let b = exp((-2.0 * Double.pi) * min(cutoff, rate / 2.0 - 1e-4) / rate)
            b1 = Float(b)
            a0 = Float(1.0 - b)
        }

        @inline(__always) mutating func lowPass(_ l: inout Float, _ r: inout Float) {
            left = (l * a0) + (left * b1)
            right = (r * a0) + (right * b1)
            l = left
            r = right
        }

        @inline(__always) mutating func highPass(_ l: inout Float, _ r: inout Float) {
            left = (l * a0) + (left * b1)
            right = (r * a0) + (right * b1)
            l -= left
            r -= right
        }
    }

    /// The filter the power light's switch turns on: twelve decibels an octave from 3.1 kHz.
    private struct TwoPole {
        var left: (Float, Float, Float, Float) = (0, 0, 0, 0), right: (Float, Float, Float, Float) = (0, 0, 0, 0)
        var a1: Float = 0, a2: Float = 0, b1: Float = 0, b2: Float = 0

        init(rate: Double, cutoff: Double, q: Double) {
            let a = 1.0 / tan((Double.pi * min(cutoff, rate / 2.0 - 1e-4)) / rate)
            let r = 1.0 / q
            let first = 1.0 / (1.0 + r * a + a * a)
            a1 = Float(first)
            a2 = Float(2.0 * first)
            b1 = Float(2.0 * (1.0 - a * a) * first)
            b2 = Float((1.0 - r * a + a * a) * first)
        }

        mutating func clear() {
            left = (0, 0, 0, 0)
            right = (0, 0, 0, 0)
        }

        @inline(__always) mutating func lowPass(_ l: inout Float, _ r: inout Float) {
            let outL = (l * a1) + (left.0 * a2) + (left.1 * a1) - (left.2 * b1) - (left.3 * b2)
            let outR = (r * a1) + (right.0 * a2) + (right.1 * a1) - (right.2 * b1) - (right.3 * b2)
            left = (l, left.0, outL, left.2)
            right = (r, right.0, outR, right.2)
            l = outL
            r = outR
        }
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// Where each voice's sound is kept for its scope, before the voices are added together and
    /// filtered, if it is wanted.
    package var waves: ChannelWaves?
    /// Which of those each voice is kept as: her own number, unless a player's tracks are not her
    /// voices. -1 for a voice that is not kept, as one that plays what a player has mixed of two
    /// tracks, whose own sound the player keeps.
    package var waveNumbers: InlineArray<4, Int> = [0, 1, 2, 3]
    /// The memory the voices read their samples from, which is the module's and not Paula's.
    private let memory: UnsafePointer<Int8>
    private let memorySize: Int
    /// Where in that memory a voice with nothing to play is pointed: a stretch of silence.
    private let silence: Int
    /// The band-limited step (`paulaBandLimitedStep`), its points taken a sixteenth of a crossing
    /// apart, laid out by where they fall between two: row `w` is points `w`, `w + 16`, `w + 32` and on.
    private let table: UnsafeMutablePointer<Float>
    private let periodToDelta: Float

    private var lowPass = OnePole(), highPass: OnePole, light: TwoPole
    private let hasLowPass: Bool
    private(set) var lightFilter = false

    /// - Parameter rate: the rate samples are made at, which is to be twice the player's.
    package init(rate: Double, model: AmigaModel, memory: UnsafePointer<Int8>, size: Int, silence: Int) {
        self.memory = memory
        memorySize = size
        self.silence = silence
        periodToDelta = Float(Self.clockHz / rate)
        table = .allocate(capacity: 17 * 16)
        for w in 0 ... 16 {
            for n in 0 ..< 16 { table[w * 16 + n] = paulaBandLimitedStep[w + 16 * n] }
        }

        // The parts on the board, from the Amiga 500 (rev 6A) and the Amiga 1200 (rev 1D4). The 1200
        // has a low-pass too, but it only begins at 34 kHz and is left out.
        switch model {
        case .a500:
            hasLowPass = true
            lowPass = OnePole(rate: rate, cutoff: 1.0 / ((2.0 * Double.pi) * 360.0 * 1e-7))
            highPass = OnePole(rate: rate, cutoff: 1.0 / ((2.0 * Double.pi) * 1390.0 * 2.233e-5))
        case .a1200:
            hasLowPass = false
            highPass = OnePole(rate: rate, cutoff: 1.0 / ((2.0 * Double.pi) * 1360.0 * 2.2e-5))
        }
        let r1 = 10000.0, r2 = 10000.0, c1 = 6.8e-9, c2 = 3.9e-9
        let root = (r1 * r2 * c1 * c2).squareRoot()
        light = TwoPole(rate: rate, cutoff: 1.0 / ((2.0 * Double.pi) * root), q: root / (c2 * (r1 + r2)))
    }

    deinit {
        table.deallocate()
    }

    // MARK: The registers

    package mutating func setPeriod(_ voice: Int, _ period: UInt16) {
        // A period of nothing is the longest there is, and one too short is as short as Paula can go.
        let real = period == 0 ? 65536 : max(Self.shortestPeriod, Int(period))
        voices[voice].storedDelta = periodToDelta / Float(real)
        // A voice set going on a period of $FFFF (as Sean Conran's driver sets one before
        // each note and its period a moment after) takes up the new one at once: UAE's Paula takes up a
        // period only as the first word plays, a line or two after the start, and so never counts that one.
        if voices[voice].active, voices[voice].period == 0xFFFF, real < 0xFFFF {
            voices[voice].delta = voices[voice].storedDelta
        }
        voices[voice].period = real
        if voices[voice].stepDelta == 0 { voices[voice].stepDelta = voices[voice].delta }
    }

    package mutating func setVolume(_ voice: Int, _ volume: UInt16) {
        // The factor also brings a sample of -128 to 127 down to within one either side of nothing.
        voices[voice].storedVolume = Float(min(64, Int(volume & 127))) * (1.0 / (128.0 * 64.0))
    }

    /// The length of what is to be played, in words.
    package mutating func setLength(_ voice: Int, _ words: UInt16) {
        voices[voice].storedLength = words
    }

    /// Where what is to be played is, in the memory Paula was given; -1 for nowhere.
    package mutating func setLocation(_ voice: Int, _ location: Int) {
        voices[voice].storedLocation = location == -1 ? silence : location
    }

    /// Starts the voices whose bits are set: each begins fetching from where it was last pointed.
    package mutating func start(voices mask: UInt16) {
        for voice in 0 ..< 4 where mask & (1 << voice) != 0 {
            if voices[voice].storedLocation == -1 { voices[voice].storedLocation = silence }
            voices[voice].location = voices[voice].storedLocation
            voices[voice].lengthCounter = voices[voice].storedLength
            voices[voice].bytesLeft = 0
            voices[voice].justStarted = true
            voices[voice].refetchPeriod()
            voices[voice].phase = 0
            voices[voice].active = true
            voices[voice].struck = true
            voices[voice].loops = 0
        }
    }

    /// True while a voice is fetching samples, from when it is started until it is stopped.
    func isPlaying(_ voice: Int) -> Bool {
        voices[voice].active
    }

    /// How many times a voice has come to the end of what it was playing and gone round again since it
    /// was started; nothing, for one that is stopped.
    func loopCount(_ voice: Int) -> UInt16 {
        voices[voice].active ? voices[voice].loops : 0
    }

    /// Marks a voice as having begun a note, for one that begins it without being started: a voice
    /// left playing whose sound changes under it.
    package mutating func noteStruck(_ voice: Int) {
        voices[voice].struck = true
    }

    package mutating func stop(voices mask: UInt16) {
        for voice in 0 ..< 4 where mask & (1 << voice) != 0 { voices[voice].active = false }
    }

    /// Leaves voices out of the sound, or brings them back: see `Renderer.setMuted`. A mark for
    /// each voice, true for one not to be heard; a voice with no mark is heard.
    package mutating func setMuted(_ muted: [Bool]) {
        for voice in 0 ..< 4 { voices[voice].muted = voice < muted.count && muted[voice] }
    }

    /// The filter that the Amiga's power light shows the state of.
    package mutating func setLightFilter(_ on: Bool) {
        if on != lightFilter { light.clear() }
        lightFilter = on
    }

    /// The side a voice is on: -1 for the left, which the first and last are, and 1 for the right.
    package static func side(ofVoice voice: Int) -> Float { voice & 3 == 0 || voice & 3 == 3 ? -1 : 1 }

    /// How far each voice has swung since this was last asked, where 1 is as far as a voice at full
    /// volume can.
    package mutating func takeLevels(into levels: inout [Float]) {
        for voice in 0 ..< 4 {
            levels[voice] = voices[voice].swing.moved ? min(1, (voices[voice].swing.high - voices[voice].swing.low) * 0.5) : 0
            voices[voice].swing.clear()
        }
    }

    /// What each voice is playing: the pitch its period stands for, and whether it has been started
    /// since this was last asked.
    package mutating func takeNotes(into notes: inout TickNotes) {
        for voice in 0 ..< 4 {
            let playing = voices[voice].active && voices[voice].period > 0
            notes.pitches[voice] = playing ? ChannelPitch.note(ofRate: Self.clockHz / Double(voices[voice].period)) : 0
            if voices[voice].struck { notes.struck[voice] = true }
            voices[voice].struck = false
        }
    }

    // MARK: Sound

    /// Makes `count` samples, the first and last voices to the left and the middle two to the right.
    /// A voice at full volume swings one either side of nothing, and each side has two of them.
    package mutating func generate(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        generateUnfiltered(left: left, right: right, count: count)

        var i = 0
        while i < count {
            var l = left[i], r = right[i]
            if hasLowPass { lowPass.lowPass(&l, &r) }
            if lightFilter { light.lowPass(&l, &r) }
            highPass.highPass(&l, &r)
            left[i] = l
            right[i] = r
            i &+= 1
        }
    }

    /// Makes `count` samples as they leave the chip, with none of what the Amiga's board puts between
    /// it and the socket.
    package mutating func generateUnfiltered(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        let numbers = waveNumbers
        voices[0].mix(into: left, count: count, memory, memorySize, table, waves: numbers[0] < 0 ? nil : waves, number: numbers[0])
        voices[1].mix(into: right, count: count, memory, memorySize, table, waves: numbers[1] < 0 ? nil : waves, number: numbers[1])
        voices[2].mix(into: right, count: count, memory, memorySize, table, waves: numbers[2] < 0 ? nil : waves, number: numbers[2])
        voices[3].mix(into: left, count: count, memory, memorySize, table, waves: numbers[3] < 0 ? nil : waves, number: numbers[3])
        waves?.advance(by: count)
    }
}

/// Halves a sample rate: a half-band filter of 59 taps, taking two samples in for each one out.
///
/// It is kept as thirty running sums, each to come out that many samples later: with each sample the
/// sums move on by one, each taking the last's and adding its own tap times the sample, and the last of
/// them, with its tap, comes out. They are worked on eight at a time, which takes each sum as it would be
/// taken one by one, its product made and added in the same order; the one sum the middle sample is
/// added to is given it with nothing added to the rest, which is to say minus nought, so that a sum of
/// minus nought stays minus nought.
public struct HalfBand {
    public init() {
        weights = Self.table
    }

    /// The filter's odd taps from the middle outwards; the even ones are nothing, but for the middle one.
    private static let taps: InlineArray<15, Float> = [
        0.31679609962928, -0.10163877066856, 0.05646939759172, -0.03589869172828, 0.02384893442862,
        -0.01596102646846, 0.01054794795196, -0.00678935474634, 0.00420731862183, -0.00248066436637,
        0.00137207386220, -0.00069823637245, 0.00031710491117, -0.00012143320790, 0.00003501888526,
    ]
    @inlinable static var middle: Float { 0.5 }

    /// The tap each sum takes the sample by, sum 1 first: from the outermost in to the middle, which sum 15
    /// takes, and out again to the outermost, which the sum that comes out (30) takes. Sums 31 and 32 are
    /// none of the filter's, and take nothing.
    private static func weight(_ sum: Int) -> Float {
        sum <= 15 ? taps[unchecked: 15 - sum] : sum <= 30 ? taps[unchecked: sum - 16] : 0
    }

    private static let table: (SIMD8<Float>, SIMD8<Float>, SIMD8<Float>, SIMD8<Float>) = {
        var w = (SIMD8<Float>.zero, SIMD8<Float>.zero, SIMD8<Float>.zero, SIMD8<Float>.zero)
        for i in 0 ..< 8 {
            w.0[i] = weight(1 + i)
            w.1[i] = weight(9 + i)
            w.2[i] = weight(17 + i)
            w.3[i] = weight(25 + i)
        }
        return w
    }()

    /// The taps, eight sums' at a time, kept by each filter: read in the players of other modules, where it
    /// is inlined, a static table would be asked at every sample whether it had been made yet.
    @usableFromInline let weights: (SIMD8<Float>, SIMD8<Float>, SIMD8<Float>, SIMD8<Float>)

    /// Sums 1 to 32, eight at a time; each sum is nought to start with.
    @usableFromInline var sums = (SIMD8<Float>.zero, SIMD8<Float>.zero, SIMD8<Float>.zero, SIMD8<Float>.zero)

    /// The last lane of `a`, then the first seven of `b`: each sum taken one place on.
    @inlinable @inline(__always) static func on(_ a: SIMD8<Float>, _ b: SIMD8<Float>) -> SIMD8<Float> {
        SIMD8(a[7], b[0], b[1], b[2], b[3], b[4], b[5], b[6])
    }

    // (Inlinable, as it is run for every sample by players of other modules; and public for that, since
    // the compiler keeps no body of a package function for other modules to inline.)
    @inlinable @inline(__always) public mutating func step(_ first: Float, _ second: Float) -> Float {
        let centre = second * Self.middle
        let w = weights
        // (Before sum 1 there is none: it starts from minus nought, which its product added to is itself.)
        let n0 = Self.on(SIMD8(repeating: -0.0), sums.0) + first * w.0
        var n1 = Self.on(sums.0, sums.1) + first * w.1
        let n2 = Self.on(sums.1, sums.2) + first * w.2
        let n3 = Self.on(sums.2, sums.3) + first * w.3
        // Sum 15 also takes the middle sample.
        n1 += SIMD8(-0.0, -0.0, -0.0, -0.0, -0.0, -0.0, centre, -0.0)
        sums = (n0, n1, n2, n3)
        return n3[5]
    }
}
