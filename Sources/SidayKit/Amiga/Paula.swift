// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from pt2-clone, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md). The band-limited steps are by aciddose, written for that project.

/// Which Amiga the sound comes out of. The two differ in what stands between the chip and the socket.
public enum AmigaModel: String, Sendable, CaseIterable {
    /// The Amiga 500: everything goes through a low-pass filter at 4.4 kHz, which is the muffled sound
    /// most music for the machine was written on.
    case a500
    /// The Amiga 1200: no such filter worth the name, and a brighter sound for it.
    case a1200
}

/// Paula, the Amiga's sound chip, as far as music needs it: four voices that each read eight-bit
/// samples out of memory at a rate of their own, two of them wired to the left and two to the right.
///
/// It runs at twice the rate the player wants, and its output is brought down afterwards (`HalfBand`).
/// A voice's output is a staircase, a level held from one sample to the next, and a staircase holds
/// tones far above what can be heard; so wherever a voice steps, a band-limited step is laid over the
/// output in place of the instant one.
struct Paula: ~Copyable {
    /// The Amiga's colour clock on a PAL machine, which is what Paula counts periods of.
    static let clockHz = 28_375_160.0 / 8.0
    /// Paula cannot fetch samples faster than this many clock periods apart.
    static let shortestPeriod = 113

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

        // The band-limited steps still being played out.
        var stepIndex = 0, stepsLeft = 0
        var steps = InlineArray<32, Float>(repeating: 0)
        var lastLevel: Float = 0
        /// For the lights: the lowest and highest the level has been, of late.
        var swing = Swing<Float>(from: -2, to: 2)

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
                    }
                }
                justStarted = false
                data.0 = location >= 0 && location < size ? memory[location] : 0
                data.1 = location >= -1 && location &+ 1 < size ? memory[location &+ 1] : 0
                location &+= 2
                bytesLeft = 2
            }

            level = Float(data.0) * storedVolume
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
        @inline(__always) private mutating func addStep(at offset: Float, of amplitude: Float, _ table: UnsafePointer<Float>) {
            var f = offset * 16
            let whole = Int(f)
            f -= Float(whole)
            var source = whole
            var i = stepIndex
            for _ in 0 ..< 16 {
                let a = table[source], b = table[source &+ 1]
                steps[unchecked: i] += amplitude * (a + ((b - a) * f))
                source &+= 16
                i = (i &+ 1) & 31
            }
            stepsLeft = 16
        }

        /// Adds `count` samples of this voice to `output`.
        mutating func mix(into output: UnsafeMutablePointer<Float>, count: Int, _ memory: UnsafePointer<Int8>, _ size: Int,
                          _ table: UnsafePointer<Float>)
        {
            guard active, location != -1, storedLocation != -1 else { return }
            for j in 0 ..< count {
                if nextSampleDue {
                    nextSampleDue = false
                    nextSample(memory, size, table)
                }
                var sample = level
                if stepsLeft > 0 {
                    sample += steps[unchecked: stepIndex]
                    steps[unchecked: stepIndex] = 0
                    stepIndex = (stepIndex &+ 1) & 31
                    stepsLeft -= 1
                }
                output[j] += sample
                phase += delta
                if phase >= 1 {
                    phase -= 1
                    refetchPeriod()
                }
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
    /// The memory the voices read their samples from, which is the module's and not Paula's.
    private let memory: UnsafePointer<Int8>
    private let memorySize: Int
    /// Where in that memory a voice with nothing to play is pointed: a stretch of silence.
    private let silence: Int
    private let table: UnsafeMutablePointer<Float>
    private let periodToDelta: Float

    private var lowPass = OnePole(), highPass: OnePole, light: TwoPole
    private let hasLowPass: Bool
    private(set) var lightFilter = false

    /// - Parameter rate: the rate samples are made at, which is to be twice the player's.
    init(rate: Double, model: AmigaModel, memory: UnsafePointer<Int8>, size: Int, silence: Int) {
        self.memory = memory
        memorySize = size
        self.silence = silence
        periodToDelta = Float(Self.clockHz / rate)
        table = .allocate(capacity: paulaBandLimitedStep.count)
        for i in 0 ..< paulaBandLimitedStep.count { table[i] = paulaBandLimitedStep[i] }

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

    mutating func setPeriod(_ voice: Int, _ period: UInt16) {
        // A period of nothing is the longest there is, and one too short is as short as Paula can go.
        let real = period == 0 ? 65536 : max(Self.shortestPeriod, Int(period))
        voices[voice].storedDelta = periodToDelta / Float(real)
        if voices[voice].stepDelta == 0 { voices[voice].stepDelta = voices[voice].delta }
    }

    mutating func setVolume(_ voice: Int, _ volume: UInt16) {
        // The factor also brings a sample of -128 to 127 down to within one either side of nothing.
        voices[voice].storedVolume = Float(min(64, Int(volume & 127))) * (1.0 / (128.0 * 64.0))
    }

    /// The length of what is to be played, in words.
    mutating func setLength(_ voice: Int, _ words: UInt16) {
        voices[voice].storedLength = words
    }

    /// Where what is to be played is, in the memory Paula was given; -1 for nowhere.
    mutating func setLocation(_ voice: Int, _ location: Int) {
        voices[voice].storedLocation = location == -1 ? silence : location
    }

    /// Starts the voices whose bits are set: each begins fetching from where it was last pointed.
    mutating func start(voices mask: UInt16) {
        for voice in 0 ..< 4 where mask & (1 << voice) != 0 {
            if voices[voice].storedLocation == -1 { voices[voice].storedLocation = silence }
            voices[voice].location = voices[voice].storedLocation
            voices[voice].lengthCounter = voices[voice].storedLength
            voices[voice].bytesLeft = 0
            voices[voice].justStarted = true
            voices[voice].refetchPeriod()
            voices[voice].phase = 0
            voices[voice].active = true
        }
    }

    mutating func stop(voices mask: UInt16) {
        for voice in 0 ..< 4 where mask & (1 << voice) != 0 { voices[voice].active = false }
    }

    /// The filter that the Amiga's power light shows the state of.
    mutating func setLightFilter(_ on: Bool) {
        if on != lightFilter { light.clear() }
        lightFilter = on
    }

    /// How far each voice has swung since this was last asked, where 1 is as far as a voice at full
    /// volume can.
    mutating func takeLevels(into levels: inout [Float]) {
        for voice in 0 ..< 4 {
            levels[voice] = voices[voice].swing.moved ? min(1, (voices[voice].swing.high - voices[voice].swing.low) * 0.5) : 0
            voices[voice].swing.clear()
        }
    }

    // MARK: Sound

    /// Makes `count` samples, the first and last voices to the left and the middle two to the right.
    /// A voice at full volume swings one either side of nothing, and each side has two of them.
    mutating func generate(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        voices[0].mix(into: left, count: count, memory, memorySize, table)
        voices[1].mix(into: right, count: count, memory, memorySize, table)
        voices[2].mix(into: right, count: count, memory, memorySize, table)
        voices[3].mix(into: left, count: count, memory, memorySize, table)

        for i in 0 ..< count {
            var l = left[i], r = right[i]
            if hasLowPass { lowPass.lowPass(&l, &r) }
            if lightFilter { light.lowPass(&l, &r) }
            highPass.highPass(&l, &r)
            left[i] = l
            right[i] = r
        }
    }
}

/// Halves a sample rate: a half-band filter of 59 taps, taking two samples in for each one out.
struct HalfBand {
    /// The filter's odd taps from the middle outwards; the even ones are nothing, but for the middle one.
    private static let taps: InlineArray<15, Float> = [
        0.31679609962928, -0.10163877066856, 0.05646939759172, -0.03589869172828, 0.02384893442862,
        -0.01596102646846, 0.01054794795196, -0.00678935474634, 0.00420731862183, -0.00248066436637,
        0.00137207386220, -0.00069823637245, 0.00031710491117, -0.00012143320790, 0.00003501888526,
    ]
    private static let middle: Float = 0.5

    private var state = InlineArray<30, Float>(repeating: 0)

    @inline(__always) mutating func step(_ first: Float, _ second: Float) -> Float {
        var x = InlineArray<15, Float>(repeating: 0)
        for j in 0 ..< 15 { x[unchecked: j] = first * Self.taps[unchecked: j] }
        let centre = second * Self.middle

        let out = state[unchecked: 29] + x[unchecked: 14]
        var k = 29
        while k >= 16 {
            state[unchecked: k] = state[unchecked: k &- 1] + x[unchecked: k &- 16]
            k &-= 1
        }
        state[unchecked: 15] = state[unchecked: 14] + x[unchecked: 0] + centre
        k = 14
        while k >= 2 {
            state[unchecked: k] = state[unchecked: k &- 1] + x[unchecked: 15 &- k]
            k &-= 1
        }
        state[unchecked: 1] = x[unchecked: 14]
        return out
    }
}
