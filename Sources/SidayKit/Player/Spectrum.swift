// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The bars of a spectrum analyser: how much of the sound just played lies in each of a row of
/// frequency bands, low to high, with the falling bars and the caps that sit on them a moment longer.
///
/// It is fed what is played and asked for its bars as often as they are drawn. Nothing about it is
/// exact, or needs to be: it is there to be watched.
public struct SpectrumAnalyzer {
    /// The samples looked at each time: 43 ms at 48 kHz, which tells notes a semitone apart from about 400 Hz up.
    private static let size = 2048
    /// What a bar at the bottom and a bar at the top stand for, in decibels below full scale.
    private static let bottom = -64.0, top = -16.0
    /// Brightness added per octave above 1 kHz. Without it the bars lean hard to the left, since every
    /// kind of wave these chips make has less in each harmonic than in the one before.
    private static let tilt = 1.5
    /// How fast a bar falls, in heights per second, and how its cap follows it. A bar drops quickly, so
    /// that the row takes the shape of the tune from one note to the next and does not hover.
    private static let fall: Float = 5, capHold = 0.3, capFall: Float = 1.5

    public let bands: Int
    /// The height of each bar, 0 to 1.
    public private(set) var levels: [Float]
    /// The height of the cap above each bar: where the bar lately reached.
    public private(set) var caps: [Float]

    private let sampleRate: Double
    /// The last `size` samples, both channels mixed, in a ring.
    private var recent: [Float]
    private var position = 0
    private var framesSinceLast = 0
    private var capAge: [Double]

    private let window: [Float]
    private let cosines: [Float], sines: [Float]
    private let reversed: [Int]
    /// The first bin of each band, and one more to close the last.
    private let edges: [Int]
    /// Each band's share of the tilt, as a gain.
    private let emphasis: [Float]
    private var real: [Float], imaginary: [Float]

    /// - Parameters:
    ///   - bands: how many bars, spread evenly by pitch from `lowest` to `highest`.
    public init(bands: Int = 24, lowest: Double = 45, highest: Double = 15000, sampleRate: Double = Double(outputSampleRate)) {
        let size = Self.size
        self.bands = bands
        self.sampleRate = sampleRate
        levels = [Float](repeating: 0, count: bands)
        caps = levels
        capAge = [Double](repeating: 0, count: bands)
        recent = [Float](repeating: 0, count: size)
        real = recent
        imaginary = recent

        // A Hann window, and the sines and cosines of the transform.
        window = (0 ..< size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        cosines = (0 ..< size / 2).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sines = (0 ..< size / 2).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
        var bits = 0
        while 1 << bits < size { bits += 1 }
        reversed = (0 ..< size).map { index in
            var result = 0
            for bit in 0 ..< bits where index & (1 << bit) != 0 { result |= 1 << (bits - 1 - bit) }
            return result
        }

        // Band edges an equal musical distance apart. The lowest bands are narrower than the transform
        // can tell apart, so each is given at least one bin of its own.
        let width = sampleRate / Double(size)
        var edges: [Int] = []
        for band in 0 ... bands {
            let frequency = lowest * pow(highest / lowest, Double(band) / Double(bands))
            let bin = Int((frequency / width).rounded())
            edges.append(min(size / 2, max(bin, (edges.last ?? 0) + 1)))
        }
        self.edges = edges
        emphasis = (0 ..< bands).map { band in
            let centre = lowest * pow(highest / lowest, (Double(band) + 0.5) / Double(bands))
            return Float(pow(10, Self.tilt * (log(centre / 1000) / log(2)) / 20))
        }
    }

    /// Everything falls silent and the bars drop at once.
    public mutating func reset() {
        for index in recent.indices { recent[index] = 0 }
        for band in 0 ..< bands {
            levels[band] = 0
            caps[band] = 0
            capAge[band] = 0
        }
        framesSinceLast = 0
    }

    /// Takes in sound as it is played: interleaved stereo.
    public mutating func add(_ buffer: UnsafePointer<Float>, frames: Int) {
        let mask = Self.size - 1
        for frame in 0 ..< frames {
            recent[position] = 0.5 * (buffer[frame * 2] + buffer[frame * 2 + 1])
            position = (position + 1) & mask
        }
        framesSinceLast += frames
    }

    /// Works out the bars for the sound taken in so far. Between calls the bars fall by as much as the
    /// sound added since the last one lasts, so they move at the same pace however often they are drawn.
    public mutating func analyse() {
        let size = Self.size, mask = size - 1
        let elapsed = Double(framesSinceLast) / sampleRate
        framesSinceLast = 0

        for index in 0 ..< size {
            let slot = reversed[index]
            real[slot] = recent[(position + index) & mask] * window[index]
            imaginary[slot] = 0
        }
        // The fast Fourier transform, in place.
        var half = 1
        while half < size {
            let step = size / (half * 2)
            var start = 0
            while start < size {
                for offset in 0 ..< half {
                    let c = cosines[offset * step], s = sines[offset * step]
                    let a = start + offset, b = a + half
                    let re = real[b] * c + imaginary[b] * s, im = imaginary[b] * c - real[b] * s
                    real[b] = real[a] - re
                    imaginary[b] = imaginary[a] - im
                    real[a] += re
                    imaginary[a] += im
                }
                start += half * 2
            }
            half *= 2
        }

        // A steady tone of amplitude 1 comes to 1 here: the window spreads it over three bins.
        let scale = 4 / (Float(size) * 1.2247)
        for band in 0 ..< bands {
            var power: Float = 0
            for bin in edges[band] ..< edges[band + 1] { power += real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
            let amplitude = Double(power.squareRoot() * scale * emphasis[band])
            let decibels = amplitude > 1e-9 ? 20 * log10(amplitude) : -200
            let height = Float(max(0, min(1, (decibels - Self.bottom) / (Self.top - Self.bottom))))

            levels[band] = max(height, levels[band] - Self.fall * Float(elapsed))
            if levels[band] >= caps[band] {
                caps[band] = levels[band]
                capAge[band] = 0
            } else {
                capAge[band] += elapsed
                if capAge[band] > Self.capHold { caps[band] = max(levels[band], caps[band] - Self.capFall * Float(elapsed)) }
            }
        }
    }
}
