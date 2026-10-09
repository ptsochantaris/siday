// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AtariAudio, Copyright (c) Arnaud Carré, used under the MIT licence (see THIRD-PARTY.md).

/// The YM2149 as it sits in an Atari ST: clocked at 2 MHz, its three channels joined into one output.
///
/// It is a different emulation from `AYChip`, which serves the Spectrum and the Amstrad, because the
/// ST's music asks different things of it. Its three outputs are tied together and load one another,
/// so the level of the three is looked up in a table recorded from the machine (`STMixTable`) and not
/// added up. And tunes rewrite its registers from timer interrupts, thousands of times a second, to
/// make sounds the chip has not got: a tone with its period set to nothing is a level to be switched
/// by hand, and a write made in an interrupt starts a square wave again from its edge.
///
/// The chip is run at an eighth of its clock, 250 kHz, which is as fast as anything in it moves.
///
/// There are two ways out of it. `nextSample` is the reference player's: each sample is the plain
/// average of the chip's steps since the last, which is what that player does, to the bit, and is kept
/// so that the two can be compared. `nextFiltered` is the one that is listened to: the steps go through
/// a low-pass filter on their way down to the host's rate, so that what the chip puts out above the
/// range of hearing, and a square wave puts out a great deal, does not come back down as tones that
/// were never played.
struct STSoundChip: ~Copyable {
    /// The clock the ST gives the chip.
    static let atariClockHz: UInt32 = 2_000_000
    /// The filter is kept in at most this many copies; see `kernel`.
    private static let mostPhases = 1024
    /// The filter's length in steps of the chip, and the size of the buffer the steps are kept in.
    private static let taps = 240
    private static let windowSize = 256

    /// The ten envelope shapes, each as four runs of 32 levels: the first two are played once and the
    /// last two go round. d falls, u rises, 0 stays at the bottom and 1 at the top.
    private static let shapes: [StaticString] = ["d000", "u000", "dddd", "d000", "dudu", "d111", "uuuu", "u111", "udud", "u000"]
    private static let shapeOfRegister: [Int] = [0, 0, 0, 0, 1, 1, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    private static let registerMasks: [UInt8] = [0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0x3F, 0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F]
    private static let voiceMasks: [UInt32] = [0x0000, 0x001F, 0x03E0, 0x03FF, 0x7C00, 0x7C1F, 0x7FE0, 0x7FFF]
    private static let historyBits = 11

    private let mix: UnsafeMutablePointer<UInt16>
    private let envelopes: UnsafeMutablePointer<UInt8>
    private let history: UnsafeMutablePointer<Int16>
    private let hostRate: UInt32
    /// Steps of the chip in a second: an eighth of its clock.
    private let stepRate: UInt32
    /// The filter, once for each place a sample can fall between two steps of the chip. The host's
    /// rate and the chip's have a common measure, and a sample falls on a multiple of it: with the
    /// ST's clock there are twenty-four such places. A clock that would make more than `mostPhases`
    /// of them gets that many, and each sample the nearest.
    private let kernel: UnsafeMutablePointer<Float>
    private let phases: UInt32
    /// The chip's last steps, kept twice over so that the newest `taps` of them always lie in a row.
    private let window: UnsafeMutablePointer<Float>
    private var windowHead = 0
    private let filteredHistory: UnsafeMutablePointer<Double>
    private var filteredSum = 0.0

    private var selected = 0
    private var registers: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    private var toneCounter: (UInt32, UInt32, UInt32) = (0, 0, 0)
    private var tonePeriod: (UInt32, UInt32, UInt32) = (0, 0, 0)
    /// Whether each channel's square wave is high: five bits a channel, all set or all clear.
    private var toneEdges: UInt32 = 0
    private var envelope = 0
    private var envelopeCounter: UInt32 = 0
    private var envelopePosition = 0
    private var envelopePeriod: UInt32 = 0
    private var noiseCounter: UInt32 = 0
    private var noisePeriod: UInt32 = 0
    private var toneMask: UInt32 = 0
    private var noiseMask: UInt32 = 0
    private var noiseShift: UInt32 = 1
    private var currentNoiseMask: UInt32 = 0
    private var noiseHalf: UInt32 = 0
    private var innerCycle: UInt32 = 0
    private var historyPosition = 0
    private var historySum: Int32 = 0
    private var insideTimer = false
    private var edgeNeedsReset: (Bool, Bool, Bool) = (false, false, false)
    /// For the lights: the levels each channel has been at of late, a bit for each of the thirty-two.
    private var levelsSeen: (UInt32, UInt32, UInt32) = (0, 0, 0)

    /// - Parameter clockHz: the chip's clock. The ST's unless the tune was recorded on something else.
    init(hostRate: Int, clockHz: UInt32 = STSoundChip.atariClockHz) {
        self.hostRate = UInt32(hostRate)
        stepRate = max(1, clockHz / 8)
        mix = .allocate(capacity: 32768)
        let packed = Base64.decode(STMixTable.packed)
        for index in 0 ..< 32768 {
            mix[index] = index * 2 + 1 < packed.count ? UInt16(packed[index * 2]) | UInt16(packed[index * 2 + 1]) << 8 : 0
        }
        let envelopes = UnsafeMutablePointer<UInt8>.allocate(capacity: 10 * 128)
        for (shape, runs) in Self.shapes.enumerated() {
            runs.withUTF8Buffer { runs in
                for (run, kind) in runs.enumerated() {
                    for step in 0 ..< 32 {
                        let level: Int = switch kind {
                        case UInt8(ascii: "d"): 31 - step
                        case UInt8(ascii: "u"): step
                        case UInt8(ascii: "1"): 31
                        default: 0
                        }
                        envelopes[shape * 128 + run * 32 + step] = UInt8(level)
                    }
                }
            }
        }
        self.envelopes = envelopes
        history = .allocate(capacity: 1 << Self.historyBits)
        filteredHistory = .allocate(capacity: 1 << Self.historyBits)
        window = .allocate(capacity: Self.windowSize * 2)

        // A windowed sinc that lets through what can be heard and has shut by the time the host's rate
        // would fold it back: down by half at 22 kHz. One copy for each place a sample can fall.
        let chipRate = Double(stepRate)
        var measure = stepRate, other = UInt32(hostRate)
        while other != 0 { (measure, other) = (other, measure % other) }
        let phases = min(Self.mostPhases, hostRate / Int(measure))
        self.phases = UInt32(phases)
        let kernel = UnsafeMutablePointer<Float>.allocate(capacity: phases * Self.taps)
        let cutoff = min(0.9, 2 * min(22000, Double(hostRate) * 0.458) / chipRate)
        let half = Double(Self.taps) / 2
        for phase in 0 ..< phases {
            // How far the newest step is past the moment the sample is for, as a part of a step.
            let lead = Double(phase) / Double(phases)
            var weights = [Double](repeating: 0, count: Self.taps)
            var total = 0.0
            for tap in 0 ..< Self.taps {
                // The step's distance from the middle of the filter, the newest step being the last.
                let distance = lead - 1 - Double(Self.taps - 1 - tap) + half
                guard abs(distance) < half else { continue }
                let angle = Double.pi * cutoff * distance
                let sinc = abs(angle) < 1e-9 ? 1 : sin(angle) / angle
                // Blackman-Harris.
                let turn = Double.pi * (distance / half + 1)
                let shape = 0.35875 - 0.48829 * cos(turn) + 0.14128 * cos(2 * turn) - 0.01168 * cos(3 * turn)
                weights[tap] = sinc * shape
                total += weights[tap]
            }
            // A steady level comes out as itself, whichever copy it meets.
            for tap in 0 ..< Self.taps { kernel[phase * Self.taps + tap] = Float(weights[tap] / total) }
        }
        self.kernel = kernel
        reset()
    }

    deinit {
        mix.deallocate()
        envelopes.deallocate()
        history.deallocate()
        filteredHistory.deallocate()
        window.deallocate()
        kernel.deallocate()
    }

    mutating func reset() {
        toneCounter = (0, 0, 0)
        tonePeriod = (0, 0, 0)
        // Which way up each square wave starts is chance on the real chip. Here it is always the same:
        // A and B high and C low, which is what the reference player's first song gets.
        toneEdges = 0x1F | 0x1F << 5
        insideTimer = false
        edgeNeedsReset = (false, false, false)
        levelsSeen = (0, 0, 0)
        noiseShift = 1
        noiseHalf = 0
        noiseCounter = 0
        currentNoiseMask = 0
        for register in 0 ..< 14 { write(register: register, register == 7 ? 0x3F : 0) }
        selected = 0
        innerCycle = 0
        envelopePosition = 0
        historyPosition = 0
        historySum = 0
        history.initialize(repeating: 0, count: 1 << Self.historyBits)
        filteredHistory.initialize(repeating: 0, count: 1 << Self.historyBits)
        filteredSum = 0
        window.initialize(repeating: 0, count: Self.windowSize * 2)
        windowHead = 0
    }

    /// The chip's two ports as the ST has them: the register to speak to, and what to tell it.
    mutating func writePort(_ port: UInt32, _ value: UInt8) {
        if port & 2 != 0 { write(register: selected, value) } else { selected = Int(value) }
    }

    /// A register told its value outright.
    mutating func write(_ register: Int, _ value: UInt8) {
        selected = register
        write(register: register, value)
    }

    func readPort(_ port: UInt32) -> UInt8 {
        guard port & 2 == 0 else { return 0xFF }
        guard selected < 16 else { return 0 }
        return withUnsafeBytes(of: registers) { $0[selected] }
    }

    private func stored(_ register: Int) -> UInt32 {
        UInt32(withUnsafeBytes(of: registers) { $0[register] })
    }

    private mutating func write(register: Int, _ value: UInt8) {
        guard register >= 0, register < 14 else { return }
        let masked = value & Self.registerMasks[register]
        withUnsafeMutableBytes(of: &registers) { $0[register] = masked }
        switch register {
        case 0 ... 5:
            let voice = register >> 1
            let period = stored(voice * 2 + 1) << 8 | stored(voice * 2)
            switch voice {
            case 0: tonePeriod.0 = period
            case 1: tonePeriod.1 = period
            default: tonePeriod.2 = period
            }
            // A period of nothing, set from a timer interrupt, is a tune starting its square wave
            // afresh in step with the timer: the edge is put back as the interrupt ends.
            if period <= 1, insideTimer {
                switch voice {
                case 0: edgeNeedsReset.0 = true
                case 1: edgeNeedsReset.1 = true
                default: edgeNeedsReset.2 = true
                }
            }
        case 6:
            noisePeriod = stored(6)
        case 7:
            toneMask = Self.voiceMasks[Int(value & 7)]
            noiseMask = Self.voiceMasks[Int((value >> 3) & 7)]
        case 11, 12:
            envelopePeriod = stored(12) << 8 | stored(11)
        case 13:
            envelope = Self.shapeOfRegister[Int(stored(13))] * 128
            envelopePosition = -64
            envelopeCounter = 0
        default:
            break
        }
    }

    /// One step of the chip, a 250,000th of a second: the level of the three channels together.
    @inline(__always) private mutating func tick() -> Int32 {
        // A channel sounds when its tone is high or switched off, and the noise is high or switched off.
        let voices = (toneEdges | toneMask) & (currentNoiseMask | noiseMask)

        toneCounter.0 &+= 1
        if toneCounter.0 >= tonePeriod.0 {
            toneEdges ^= 0x1F
            toneCounter.0 = 0
        }
        toneCounter.1 &+= 1
        if toneCounter.1 >= tonePeriod.1 {
            toneEdges ^= 0x1F << 5
            toneCounter.1 = 0
        }
        toneCounter.2 &+= 1
        if toneCounter.2 >= tonePeriod.2 {
            toneEdges ^= 0x1F << 10
            toneCounter.2 = 0
        }

        envelopeCounter &+= 1
        if envelopeCounter >= envelopePeriod {
            envelopePosition += 1
            if envelopePosition > 0 { envelopePosition &= 63 }
            envelopeCounter = 0
        }

        // The noise runs at half the speed of the rest.
        noiseHalf ^= 1
        if noiseHalf != 0 {
            noiseCounter &+= 1
            if noiseCounter >= noisePeriod {
                currentNoiseMask = (noiseShift ^ (noiseShift >> 2)) & 1 != 0 ? ~0 : 0
                noiseShift = noiseShift >> 1 | (currentNoiseMask & 1) << 16
                noiseCounter = 0
            }
        }

        let envelopeLevel = UInt32(envelopes[envelope + envelopePosition + 64])
        let a = stored(8), b = stored(9), c = stored(10)
        var levels = a & 0x10 != 0 ? envelopeLevel : a << 1 | 1
        levels |= (b & 0x10 != 0 ? envelopeLevel : b << 1 | 1) << 5
        levels |= (c & 0x10 != 0 ? envelopeLevel : c << 1 | 1) << 10
        levels &= voices
        levelsSeen.0 |= 1 &<< (levels & 0x1F)
        levelsSeen.1 |= 1 &<< ((levels >> 5) & 0x1F)
        levelsSeen.2 |= 1 &<< ((levels >> 10) & 0x1F)
        return Int32(mix[Int(levels & 0x7FFF)])
    }

    /// How far each channel has swung since this was last asked, where 1 is from silence to full
    /// volume: each as it would be if the other two were silent.
    mutating func takeLevels(into levels: UnsafeMutablePointer<Float>) {
        func level(_ seen: UInt32, _ period: UInt32, _ channel: Int) -> Float {
            let shift = channel * 5
            var seen = seen
            // A tone of a period under six is above 20 kHz, and is not heard as a tone: it is how a tune
            // holds a channel open to play a level by hand. Its silences do not count.
            if period < 6, toneMask >> UInt32(shift) & 1 == 0, noiseMask >> UInt32(shift) & 1 != 0 { seen &= ~1 }
            guard seen != 0 else { return 0 }
            let full = Float(mix[31 << shift]) - Float(mix[0])
            let high = 31 - seen.leadingZeroBitCount, low = seen.trailingZeroBitCount
            return full > 0 ? (Float(mix[high << shift]) - Float(mix[low << shift])) / full : 0
        }
        levels[0] = level(levelsSeen.0, tonePeriod.0, 0)
        levels[1] = level(levelsSeen.1, tonePeriod.1, 1)
        levels[2] = level(levelsSeen.2, tonePeriod.2, 2)
        levelsSeen = (0, 0, 0)
    }

    /// The level stripped of whatever it has been sitting at for the last twentieth of a second: the
    /// chip's output only ever goes one way from nothing, and a loudspeaker hears only the changes.
    @inline(__always) private mutating func centred(_ value: Int16) -> Int16 {
        historySum -= Int32(history[historyPosition])
        historySum += Int32(value)
        history[historyPosition] = value
        historyPosition = (historyPosition + 1) & ((1 << Self.historyBits) - 1)
        return Int16(truncatingIfNeeded: Int32(value) - (historySum >> Int32(Self.historyBits)))
    }

    /// The next sample at the host's rate: the average of the chip's steps since the last one.
    @inline(__always) mutating func nextSample() -> Int16 {
        var sum: Int32 = 0, count: Int32 = 0
        repeat {
            sum += tick()
            count += 1
            innerCycle &+= hostRate
        } while innerCycle < stepRate
        innerCycle -= stepRate
        return centred(Int16(truncatingIfNeeded: sum / count))
    }

    /// The next sample at the host's rate, for listening to: the chip's steps brought down to it through
    /// the low-pass filter, on the scale of `nextSample` and centred as it is.
    @inline(__always) mutating func nextFiltered() -> Float {
        repeat {
            let level = Float(tick())
            window[windowHead] = level
            window[windowHead + Self.windowSize] = level
            windowHead = (windowHead + 1) & (Self.windowSize - 1)
            innerCycle &+= hostRate
        } while innerCycle < stepRate
        innerCycle -= stepRate

        // Eight at a time into two running sums, as the other chips' filters are done.
        let steps = UnsafeRawPointer(window + ((windowHead - Self.taps) & (Self.windowSize - 1)))
        let phase = Int(UInt64(innerCycle) * UInt64(phases) / UInt64(hostRate))
        let weights = UnsafeRawPointer(kernel + phase * Self.taps)
        let width = MemoryLayout<SIMD8<Float>>.size
        var even = SIMD8<Float>.zero, odd = SIMD8<Float>.zero
        var offset = 0
        while offset < Self.taps * MemoryLayout<Float>.size {
            even += weights.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
                * steps.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
            odd += weights.loadUnaligned(fromByteOffset: offset + width, as: SIMD8<Float>.self)
                * steps.loadUnaligned(fromByteOffset: offset + width, as: SIMD8<Float>.self)
            offset += width * 2
        }
        let value = Double((even + odd).sum())

        filteredSum += value - filteredHistory[historyPosition]
        filteredHistory[historyPosition] = value
        historyPosition = (historyPosition + 1) & ((1 << Self.historyBits) - 1)
        return Float(value - filteredSum / Double(1 << Self.historyBits))
    }

    /// Told as a timer's interrupt code starts, and again as it ends.
    mutating func insideTimerInterrupt(_ inside: Bool) {
        if !inside {
            if edgeNeedsReset.0 {
                toneEdges ^= 0x1F
                toneCounter.0 = 0
            }
            if edgeNeedsReset.1 {
                toneEdges ^= 0x1F << 5
                toneCounter.1 = 0
            }
            if edgeNeedsReset.2 {
                toneEdges ^= 0x1F << 10
                toneCounter.2 = 0
            }
            edgeNeedsReset = (false, false, false)
        }
        insideTimer = inside
    }
}
