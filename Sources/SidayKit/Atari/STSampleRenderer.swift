// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AtariAudio, Copyright (c) Arnaud Carré, used under the MIT licence (see THIRD-PARTY.md).

/// Plays the two kinds of YM file that are made of samples and not of sound-chip registers. On the
/// Atari ST they were played by writing sample after sample to the chip's volume registers; what the
/// files hold is the samples themselves, and they are played here as samples.
///
/// A digi-mix (MIX1) is a bank of samples and a list of pieces of it to play one after another, each
/// so many times over: a whole tune cut into the parts that repeat. A YM tracker tune (YMT1, YMT2)
/// is closer to a tracker module: up to eight voices, each told every tick which sample to play, how
/// fast and how loud.
public final class STSampleRenderer: Renderer, ReferenceComparable {
    private enum Kind {
        case mix, tracker
    }

    private struct Sample {
        var start = 0
        var length = 0
        var loopStart = 0
    }

    private struct Voice {
        var sample = 0
        var position = 0
        var rate: UInt32 = 0
        var innerClock: UInt32 = 0
        var volume: Int32 = 0
        var loops = false
        var running = false
    }

    private let kind: Kind
    private let data: [UInt8]
    private let hostRate = UInt32(outputSampleRate)

    // A digi-mix: the list of pieces, twelve bytes each, and the bank they are pieces of.
    private let pieces: Int
    private let pieceList: Int
    private let bank: Int
    private let signFlip: UInt8
    private var piece = 0
    private var pieceStart = 0
    private var pieceLength = 0
    private var pieceRepeats = 0
    private var pieceRate: UInt32 = 0
    private var piecePosition = 0
    private var pieceClock: UInt32 = 0

    // A tracker tune: four bytes a voice for each tick.
    private let voiceCount: Int
    private let samples: [Sample]
    private let score: Int
    private let interleaved: Bool
    private let ticks: Int
    private let loopTick: Int
    private let rateShift: UInt32
    private let samplesPerTick: Int
    private var voices = [Voice](repeating: Voice(), count: 8)
    /// For the lights: how far each voice has swung of late, or the one sample of a digi-mix.
    private var swings = [Swing<Int32>](repeating: Swing(from: -32768, to: 32767), count: 8)
    /// The voices that have been given a new note since the notes were last asked for.
    private var struckVoices = [Bool](repeating: false, count: 8)
    private var tick = 0
    private var wrapped = false
    private var untilTick = 0

    /// What the sound has been sitting at, taken off it: see `STSoundChip`.
    private let history: UnsafeMutablePointer<Int16>
    private var historyPosition = 0
    private var historySum: Int32 = 0
    private let gain: Float = 0.37 / 32768.0

    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var endsByLooping: Bool { true }
    public let knownLength: Double?

    /// The player for a YM file of one of these kinds; nil for any other.
    public init?(_ file: [UInt8]) {
        var bytes = file
        if let unpacked = LH5.unwrapArchive(bytes) { bytes = unpacked }
        let reader = ByteReader(bytes)
        var info = TuneInfo(format: reader.ascii(at: 0, length: 4))
        var place = 12
        switch info.format {
        case "MIX1":
            kind = .mix
            signFlip = reader.u32be(place) & 1 != 0 ? 0x00 : 0x80
            pieces = reader.u32be(place + 8)
            pieceList = place + 12
            guard pieces > 0, pieces < 1 << 16, pieceList + pieces * 12 <= bytes.count else { return nil }
            var length = 0.0
            for index in 0 ..< pieces {
                let entry = pieceList + index * 12
                let rate = reader.u16be(entry + 10)
                guard rate > 0 else { return nil }
                length += Double(reader.u32be(entry + 4)) * Double(min(16, reader.u16be(entry + 8))) / Double(rate)
            }
            place = pieceList + pieces * 12
            (info.title, place) = reader.cString(at: place)
            (info.author, place) = reader.cString(at: place)
            (info.comment, place) = reader.cString(at: place)
            bank = place
            knownLength = length
            info.detail = "Atari ST, samples"
            voiceCount = 0
            samples = []
            score = 0
            interleaved = false
            ticks = 0
            loopTick = 0
            rateShift = 0
            samplesPerTick = 0
        case "YMT1", "YMT2":
            kind = .tracker
            let second = info.format == "YMT2"
            voiceCount = reader.u16be(place)
            let rate = reader.u16be(place + 2)
            ticks = reader.u32be(place + 4)
            loopTick = reader.u32be(place + 8)
            let sampleCount = reader.u16be(place + 12)
            let flags = reader.u32be(place + 14)
            place += 18
            guard voiceCount > 0, voiceCount <= 8, rate > 0, rate <= 2000, ticks > 0, ticks < 1 << 24, sampleCount <= 64 else { return nil }
            (info.title, place) = reader.cString(at: place)
            (info.author, place) = reader.cString(at: place)
            (info.comment, place) = reader.cString(at: place)
            var samples: [Sample] = []
            for _ in 0 ..< sampleCount {
                var sample = Sample()
                sample.length = reader.u16be(place)
                place += 2
                if second {
                    // Where the sample goes round to, counted back from its end.
                    sample.loopStart = sample.length - reader.u16be(place)
                    if sample.loopStart < 0 || sample.loopStart >= sample.length { sample.loopStart = 0 }
                    place += 4
                }
                sample.start = place
                place += sample.length
                samples.append(sample)
            }
            guard place + ticks * voiceCount * 4 <= bytes.count + 4 else { return nil }
            self.samples = samples
            score = place
            interleaved = flags & 1 != 0
            rateShift = second ? UInt32(truncatingIfNeeded: flags) >> 28 : 0
            samplesPerTick = max(1, Int(Int64(outputSampleRate) * 313 * 512 * 50 / (Int64(rate) * Int64(atariSTCPUHz))))
            knownLength = Double(ticks) * Double(samplesPerTick) / Double(outputSampleRate)
            info.detail = "Atari ST, \(voiceCount) voices of samples" + (rate == 50 ? "" : ", \(rate) Hz")
            pieces = 0
            pieceList = 0
            bank = 0
            signFlip = 0
        default:
            return nil
        }
        data = bytes
        self.info = info
        history = .allocate(capacity: 2048)
        restart()
    }

    deinit {
        history.deallocate()
    }

    @inline(__always) private func byte(_ index: Int) -> UInt8 {
        index >= 0 && index < data.count ? data[index] : 0
    }

    private func restart() {
        history.initialize(repeating: 0, count: 2048)
        historyPosition = 0
        historySum = 0
        loopCount = 0
        tick = 0
        wrapped = false
        untilTick = 0
        voices = [Voice](repeating: Voice(), count: 8)
        piece = -1
        nextPiece()
        loopCount = 0
        piecePosition = 0
        pieceClock = 0
    }

    public func select(subsong _: Int) {
        restart()
    }

    // MARK: A digi-mix

    private func nextPiece() {
        guard kind == .mix else { return }
        piece += 1
        if piece >= pieces {
            piece = 0
            loopCount += 1
        }
        let reader = ByteReader(data)
        let entry = pieceList + piece * 12
        pieceStart = reader.u32be(entry)
        pieceLength = reader.u32be(entry + 4)
        pieceRepeats = reader.u16be(entry + 8)
        pieceRate = UInt32(reader.u16be(entry + 10))
    }

    @inline(__always) private func nextMixSample() -> Int16 {
        let sample = Int8(bitPattern: byte(bank + pieceStart + piecePosition) ^ signFlip)
        pieceClock &+= pieceRate
        if pieceClock >= hostRate {
            piecePosition += 1
            if piecePosition >= pieceLength {
                piecePosition = 0
                pieceRepeats -= 1
                if pieceRepeats <= 0 { nextPiece() }
            }
            pieceClock -= hostRate
        }
        swings[0].note(Int32(sample) << 7)
        return Int16(sample) << 7
    }

    // MARK: A tracker tune

    @inline(__always) private func scored(_ place: Int) -> UInt8 {
        byte(interleaved ? score + ticks * place + tick : score + tick * voiceCount * 4 + place)
    }

    private func nextTick() {
        if wrapped {
            wrapped = false
            loopCount += 1
        }
        for index in 0 ..< voiceCount {
            let sample = scored(index * 4), control = scored(index * 4 + 1)
            let rate = UInt32(scored(index * 4 + 2)) << 8 | UInt32(scored(index * 4 + 3))
            voices[index].rate = rate
            guard rate != 0 else {
                voices[index].running = false
                continue
            }
            voices[index].rate = rate << rateShift
            voices[index].loops = control & 0x40 != 0
            voices[index].volume = Int32(control & 63) * 64 / 63
            if sample != 0xFF {
                // A new note.
                if index < 8 { struckVoices[index] = true }
                voices[index].sample = Int(sample)
                voices[index].position = 0
                voices[index].running = true
                voices[index].innerClock = 0
            }
        }
        tick += 1
        if tick >= ticks {
            tick = loopTick >= 0 && loopTick < ticks ? loopTick : 0
            wrapped = true
        }
    }

    @inline(__always) private func nextTrackerSample() -> Int16 {
        var output: Int32 = 0
        for index in 0 ..< voiceCount where voices[index].running {
            guard voices[index].sample < samples.count else {
                voices[index].running = false
                continue
            }
            let sample = samples[voices[index].sample]
            let level = Int32(Int8(bitPattern: byte(sample.start + voices[index].position) ^ 0x80)) * voices[index].volume
            swings[index].note(level)
            output += level
            voices[index].innerClock &+= voices[index].rate
            while voices[index].innerClock >= hostRate {
                voices[index].position += 1
                if voices[index].position >= sample.length {
                    voices[index].position = sample.loopStart
                    if !voices[index].loops { voices[index].running = false }
                }
                voices[index].innerClock -= hostRate
            }
        }
        return Int16(truncatingIfNeeded: max(-32768, min(32767, output)))
    }

    // MARK: Sound

    @inline(__always) private func centred(_ value: Int16) -> Int16 {
        historySum -= Int32(history[historyPosition])
        historySum += Int32(value)
        history[historyPosition] = value
        historyPosition = (historyPosition + 1) & 2047
        return Int16(truncatingIfNeeded: Int32(value) - (historySum >> 11))
    }

    @inline(__always) private func nextSample() -> Int16 {
        if kind == .mix { return centred(nextMixSample()) }
        if untilTick == 0 {
            nextTick()
            untilTick = samplesPerTick
        }
        untilTick -= 1
        return centred(nextTrackerSample())
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        for frame in 0 ..< frames {
            let sample = Float(nextSample()) * gain
            buffer[frame * 2] = sample
            buffer[frame * 2 + 1] = sample
        }
    }

    public var channelCount: Int { kind == .mix ? 1 : min(8, voiceCount) }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        for voice in 0 ..< channelCount {
            // (A digi-mix is one recording, and has no notes.)
            pitches[voice] = kind == .tracker && voices[voice].running ? ChannelPitch.note(ofRate: Double(voices[voice].rate)) : 0
            struck[voice] = struckVoices[voice]
            struckVoices[voice] = false
        }
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        // A voice at full volume goes 8,192 either side of nothing, and a digi-mix twice as far.
        let full: Float = kind == .mix ? 32768 : 16384
        for voice in 0 ..< channelCount {
            levels[voice] = swings[voice].moved ? min(1, Float(swings[voice].high - swings[voice].low) / full) : 0
            swings[voice].clear()
        }
    }

    public func renderRaw(frames: Int) -> [Int16] {
        (0 ..< frames).map { _ in nextSample() }
    }
}
