// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AtariAudio, Copyright (c) Arnaud Carré, used under the MIT licence (see THIRD-PARTY.md).

/// A player whose output can be had exactly as the reference player (AtariAudio) makes it, sixteen
/// bits and one channel, for comparing the two.
public protocol ReferenceComparable {
    func renderRaw(frames: Int) -> [Int16]
}

extension SNDHRenderer: ReferenceComparable {}

/// Plays the YM files that were recorded from an Atari ST, on the ST's sound chip and timers.
///
/// A YM file is a recording of what a tune sent to the sound chip, a set of registers for each tick.
/// That is all there is to most of them, and `RegisterDumpSource` plays those on any machine's chip.
/// But what ST musicians did between ticks, from timer interrupts, cannot be written down as a set
/// of registers, so the later kinds of file (YM5 and YM6) say instead which effect was running, on
/// which channel and how fast, and leave the player to do it: a channel's volume switched on and off
/// (the SID voice), a sample played on a volume register (a digi-drum), or the envelope started over
/// and over (the sync-buzzer). The oldest kind (YM2) has drums too, by number, from a set the player
/// is expected to have.
///
/// Here the effects are done as the ST did them, by the ST's timers on the ST's chip, and the chip's
/// three channels are mixed as the ST mixed them.
///
/// Two other kinds of file that go by the name of YM have no sound chip in them at all, and are
/// played by `STSampleRenderer`.
public final class STYMRenderer: Renderer, ReferenceComparable {
    private enum Kind {
        case ym2, ym3, ym5, ym6
    }

    private enum Effect {
        case none, sid, syncBuzzer, drum
    }

    /// One of the two effects a tick can have going, each on a timer of its own.
    private struct Running {
        var effect = Effect.none
        var voice = 0
        var phase = 0
        /// The drum being played: where it is in `drums`, and how long.
        var sample = 0
        var sampleLength = 0
        var volume: UInt8 = 0
        var shape: UInt8 = 0
    }

    private let kind: Kind
    private let data: [UInt8]
    /// Where the registers start in `data`, how many there are to a tick, and whether they are kept a
    /// register at a time (all of register 0, then all of register 1) or a tick at a time.
    private let base: Int
    private let stride: Int
    private let interleaved: Bool
    private let ticks: Int
    private let loopTick: Int
    private let tickRate: Int
    /// The drums, of sixteen levels, end to end, and where each starts and how long it is.
    private let drums: [UInt8]
    private let drumStarts: [Int]
    private let drumLengths: [Int]

    private var chip: STSoundChip
    private var timers: MFP
    private var running = (Running(), Running())
    private var tick = 0
    /// True when the tick about to be played is the first of another time round.
    private var wrapped = false
    private let samplesPerTick: Int
    private var untilTick = 0
    private let gain: Float = 0.37 / 32768.0

    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var endsByLooping: Bool { true }
    public var knownLength: Double? { Double(ticks) * Double(samplesPerTick) / Double(outputSampleRate) }

    /// The player for a YM file, if it is one that belongs on an Atari ST: a YM2, YM3 or YM3b, which
    /// are the ST's by definition; or a YM5 or YM6 that says the chip ran at the ST's 2 MHz, or that
    /// uses the effects, on whatever clock. Nil for anything else, which is left to the player for
    /// register recordings in general.
    /// - Parameter always: play any YM5 or YM6 this way, for comparing with the reference player.
    public init?(_ file: [UInt8], always: Bool = false) {
        var bytes = file
        if let unpacked = LH5.unwrapArchive(bytes) { bytes = unpacked }
        let reader = ByteReader(bytes)
        var info = TuneInfo(format: "")
        var rate = 50
        var clock = Int(STSoundChip.atariClockHz)
        switch reader.ascii(at: 0, length: 4) {
        case "YM2!", "YM3!", "YM3b":
            let looping = reader[3] == UInt8(ascii: "b")
            kind = reader[2] == UInt8(ascii: "2") ? .ym2 : .ym3
            info.format = kind == .ym2 ? "YM2" : "YM3"
            base = 4
            stride = 14
            interleaved = true
            ticks = (bytes.count - 4) / 14
            // The place to go round to, in the last four bytes, low byte first.
            loopTick = looping ? reader.u32le(bytes.count - 4) : 0
            if kind == .ym2 {
                drums = YM2Drums.samples()
                drumStarts = YM2Drums.offsets
                drumLengths = YM2Drums.lengths
            } else {
                drums = []
                drumStarts = []
                drumLengths = []
            }
        case "YM5!", "YM6!":
            guard reader.ascii(at: 4, length: 8) == "LeOnArD!" else { return nil }
            kind = reader[2] == UInt8(ascii: "5") ? .ym5 : .ym6
            info.format = kind == .ym5 ? "YM5" : "YM6"
            ticks = reader.u32be(12)
            let flags = reader.u32be(16)
            let drumCount = reader.u16be(20)
            clock = reader.u32be(22)
            rate = reader.u16be(26)
            loopTick = reader.u32be(28)
            var place = 34 + reader.u16be(32)
            guard drumCount <= 64 else { return nil }
            // Each drum is a length and its samples. They are eight bits unless the file says they are
            // already four, and are brought down to the chip's sixteen levels the way the ST's players did.
            let levels: [UInt8] = [0, 7, 9, 10, 11, 12, 12, 13, 13, 13, 14, 14, 14, 15, 15, 15]
            var drums: [UInt8] = [], starts: [Int] = [], lengths: [Int] = []
            for _ in 0 ..< drumCount {
                let length = reader.u32be(place)
                place += 4
                guard length >= 0, place + length <= bytes.count else { return nil }
                starts.append(drums.count)
                lengths.append(length)
                for index in place ..< place + length {
                    drums.append(flags & 4 != 0 ? bytes[index] : levels[Int(bytes[index] >> 4)])
                }
                place += length
            }
            self.drums = drums
            drumStarts = starts
            drumLengths = lengths
            (info.title, place) = reader.cString(at: place)
            (info.author, place) = reader.cString(at: place)
            (info.comment, place) = reader.cString(at: place)
            base = place
            stride = 16
            interleaved = flags & 1 != 0
        default:
            return nil
        }
        guard ticks > 0, ticks < 1 << 24, rate > 0, rate <= 2000, base + ticks * stride <= bytes.count + 4,
              clock >= 500_000, clock <= 4_000_000 else { return nil }
        data = bytes
        tickRate = rate
        if kind == .ym5 || kind == .ym6, clock != Int(STSoundChip.atariClockHz), !always {
            // Not the ST's clock: it is the ST's to play only if some tick has an effect going.
            var effects = false
            for tick in 0 ..< ticks where !effects {
                for register in [1, 3] {
                    let index = interleaved ? base + ticks * register + tick : base + tick * stride + register
                    if index < bytes.count, bytes[index] & 0x30 != 0 { effects = true }
                }
            }
            guard effects else { return nil }
        }
        samplesPerTick = max(1, Int(Int64(outputSampleRate) * 313 * 512 * 50 / (Int64(rate) * Int64(atariSTCPUHz))))
        var detail = clock == Int(STSoundChip.atariClockHz) ? ["Atari ST"] : ["YM \(significant(Double(clock) / 1_000_000, digits: 4)) MHz, with the Atari ST's effects"]
        if rate != 50 { detail.append("\(rate) Hz") }
        info.detail = detail.joined(separator: ", ")
        self.info = info
        chip = STSoundChip(hostRate: outputSampleRate, clockHz: UInt32(clock))
        timers = MFP(hostRate: outputSampleRate)
        restart()
    }

    deinit {
        chip.deallocate()
        timers.deallocate()
    }

    private func restart() {
        tick = 0
        wrapped = false
        loopCount = 0
        untilTick = 0
        running = (Running(), Running())
        chip.reset()
        timers.reset()
        // Timers A and B are let interrupt; neither is going yet.
        timers.write8(0x07, 0x21)
        timers.write8(0x13, 0x21)
        setTimer(0, divider: 0, count: 0)
        setTimer(1, divider: 0, count: 0)
    }

    public func select(subsong _: Int) {
        restart()
    }

    // MARK: The recording

    /// A register as it was recorded for the tick being played.
    @inline(__always) private func recorded(_ register: Int) -> UInt8 {
        let index = interleaved ? base + ticks * register + tick : base + tick * stride + register
        return index < data.count ? data[index] : 0
    }

    private func setTimer(_ slot: Int, divider: UInt8, count: UInt8) {
        timers.write8(slot == 0 ? 0x19 : 0x1B, divider)
        timers.write8(slot == 0 ? 0x1F : 0x21, count)
    }

    /// Reads what the tick says of one of its two effects and sets it going, or stops it. The answer
    /// is the registers the effect has taken over, a bit for each, which the tick is not to write.
    private func decode(_ slot: Int, code codeRegister: Int, divider dividerRegister: Int, count countRegister: Int) -> UInt32 {
        var effect = slot == 0 ? running.0 : running.1
        defer { if slot == 0 { running.0 = effect } else { running.1 = effect } }
        var skip: UInt32 = 0
        var code = recorded(codeRegister) & 0xF0
        let divider = (recorded(dividerRegister) >> 5) & 7
        let count = recorded(countRegister)
        if kind == .ym5 {
            // The older file has one effect to a slot: the SID voice in the first and a drum in the second.
            code &= 0x30
            if code != 0, slot == 1 { code |= 0x40 }
        }
        if code & 0x30 != 0 {
            effect.voice = Int((code & 0x30) >> 4) - 1
            let level = recorded(effect.voice + 8)
            switch code & 0xC0 {
            case 0x00:
                effect.effect = .sid
                effect.volume = level & 15
                skip = 1 << UInt32(effect.voice + 8)
                setTimer(slot, divider: divider, count: count)
            case 0x40:
                let drum = Int(level & 31)
                if drum < drumStarts.count {
                    effect.effect = .drum
                    effect.sample = drumStarts[drum]
                    effect.sampleLength = drumLengths[drum]
                    effect.phase = 0
                    skip = 1 << UInt32(effect.voice + 8)
                    setTimer(slot, divider: divider, count: count)
                }
            case 0xC0:
                effect.effect = .syncBuzzer
                effect.shape = level & 15
                skip = 1 << UInt32(effect.voice + 8)
                setTimer(slot, divider: divider, count: count)
            default:
                // A SID voice on a sine wave, which nothing is known to use.
                break
            }
        } else if effect.effect != .drum {
            // No effect this tick. A drum plays out and stops itself; anything else stops now.
            setTimer(slot, divider: 0, count: 0)
            effect.effect = .none
        }
        if effect.effect == .drum { skip |= 1 << UInt32(effect.voice + 8) }
        return skip
    }

    /// One tick of a YM3, YM5 or YM6 file.
    private func playTick() {
        var skip: UInt32 = 0
        if kind == .ym5 || kind == .ym6 {
            skip |= decode(0, code: 1, divider: 6, count: 14)
            skip |= decode(1, code: 3, divider: 8, count: 15)
        }
        // A channel playing a drum has its tone and noise switched off.
        var mixer = recorded(7)
        if running.0.effect == .drum { mixer |= 0x09 << UInt8(running.0.voice) }
        if running.1.effect == .drum { mixer |= 0x09 << UInt8(running.1.voice) }
        chip.write(7, mixer)
        skip |= 1 << 7
        // Some files switch the envelope on a tick before they give its period: a long one stands in,
        // so that the tick is not spent on a squeal.
        if recorded(11) == 0, recorded(12) == 0 {
            chip.write(11, 0xFF)
            chip.write(12, 0xFF)
            skip |= 1 << 11 | 1 << 12
        }
        for register in 0 ... 12 where skip & 1 << UInt32(register) == 0 { chip.write(register, recorded(register)) }
        // The envelope starts again only when its shape was written, which the file marks.
        let shape = recorded(13)
        if shape != 0xFF { chip.write(13, shape) }
    }

    /// One tick of a YM2 file: a recording of one particular player, with its drums and its one envelope.
    private func playOldTick() {
        var skip: UInt32 = 0
        if recorded(13) != 0xFF {
            chip.write(11, recorded(11))
            chip.write(12, 0)
            chip.write(13, 10)
        }
        var level = recorded(10)
        if level & 0x80 != 0 {
            level &= 0x7F
            let count = recorded(12)
            if count != 0, level < 40 {
                running.0.effect = .drum
                running.0.phase = 0
                running.0.sample = drumStarts[Int(level)]
                running.0.sampleLength = drumLengths[Int(level)]
                running.0.voice = 2
                setTimer(0, divider: 1, count: count)
            }
        }
        if running.0.effect == .drum {
            chip.write(7, recorded(7) | 0x24)
            skip |= 1 << 7 | 1 << UInt32(running.0.voice + 8)
        }
        for register in 0 ... 10 where skip & 1 << UInt32(register) == 0 { chip.write(register, recorded(register)) }
    }

    private func nextTick() {
        if wrapped {
            wrapped = false
            loopCount += 1
        }
        if kind == .ym2 { playOldTick() } else { playTick() }
        tick += 1
        if tick >= ticks {
            tick = loopTick >= 0 && loopTick < ticks ? loopTick : 0
            wrapped = true
        }
    }

    /// After each sample: the two timers move on, and one that comes due does its effect's next step.
    @inline(__always) private func runTimers() {
        for slot in 0 ..< 2 where timers.tick(slot) {
            var effect = slot == 0 ? running.0 : running.1
            switch effect.effect {
            case .sid:
                effect.phase &+= 1
                chip.write(effect.voice + 8, effect.phase & 1 != 0 ? effect.volume : 0)
            case .syncBuzzer:
                chip.write(13, effect.shape)
            case .drum:
                if effect.phase < effect.sampleLength {
                    chip.write(effect.voice + 8, drums[effect.sample + effect.phase])
                    effect.phase += 1
                } else {
                    setTimer(slot, divider: 0, count: 0)
                    effect.effect = .none
                }
            case .none:
                break
            }
            if slot == 0 { running.0 = effect } else { running.1 = effect }
        }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if untilTick == 0 {
                nextTick()
                untilTick = samplesPerTick
            }
            let count = min(untilTick, frames - done)
            for frame in done ..< done + count {
                let sample = chip.nextFiltered() * gain
                runTimers()
                buffer[frame * 2] = sample
                buffer[frame * 2 + 1] = sample
            }
            done += count
            untilTick -= count
        }
    }

    public func renderRaw(frames: Int) -> [Int16] {
        var output: [Int16] = []
        output.reserveCapacity(frames)
        while output.count < frames {
            if untilTick == 0 {
                nextTick()
                untilTick = samplesPerTick
            }
            let count = min(untilTick, frames - output.count)
            for _ in 0 ..< count {
                output.append(chip.nextSample())
                runTimers()
            }
            untilTick -= count
        }
        return output
    }
}
