// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st3play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// An S3M file, Scream Tracker 3's kind of module, played by Scream Tracker's replayer on one of the
/// two sound cards it knew.
///
/// Which card matters: a tune written with a Gravis Ultrasound was heard smoothly mixed, and one
/// written with a Sound Blaster was heard in eight bits at 22 kHz. A file saved by Scream Tracker
/// says which it was saved with, and is played on that unless another is asked for.
public final class S3MRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var knownLength: Double?
    public private(set) var loopCount = 0
    public var endsByLooping: Bool { true }

    private let module: ST3Module
    private let card: ST3Card
    private let mono: Bool
    private var player: ST3Player
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    /// The part of a sample that ticks are over by, in 2^-32s, carried from tick to tick.
    private var remainder: UInt64 = 0
    private var started = false
    // For `renderRaw`: the reference player's dither.
    private var seed: UInt32 = 0x1234_5000
    private var ditherLeft: Float = 0, ditherRight: Float = 0

    /// The slowest tempo is some nineteen ticks a second, and a tick is then some 2,500 samples.
    private static let tickSpace = 16384
    private static let mostTicks = 50 * 60 * 120
    /// Set by ear and by measure, so that a module is about as loud as the chip tunes it is played
    /// among, whichever card it is on: what a GUS puts out is half as loud again as a Sound Blaster.
    private let gain: Float

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try ST3Module(data)
        card = options.s3mCard ?? (module.savedWithSoundBlaster ? .sb : .gus)
        mono = options.stereo == .mono
        gain = card == .gus ? 0.34 : 0.5
        left = .allocate(capacity: Self.tickSpace)
        right = .allocate(capacity: Self.tickSpace)

        var info = TuneInfo(format: "S3M")
        info.title = module.title
        info.detail = "Scream Tracker 3, " + (card == .gus ? "Gravis Ultrasound" : "Sound Blaster Pro")
        self.info = info

        // Once through in silence, to find how long the tune is.
        player = ST3Player(module, card: card)
        var frames = 0, ticks = 0
        if !player.silent {
            while ticks < Self.mostTicks {
                player.tick()
                if player.cameRound, ticks > 0 { break }
                frames += nextTickLength()
                ticks += 1
            }
        }
        knownLength = ticks > 0 && ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
        player = ST3Player(module, card: card)
        remainder = 0
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public func select(subsong _: Int) {
        restart()
    }

    private func restart() {
        player = ST3Player(module, card: card)
        tickFrames = 0
        tickPosition = 0
        remainder = 0
        loopCount = 0
        started = false
        seed = 0x1234_5000
        ditherLeft = 0
        ditherRight = 0
    }

    /// How many samples the tick just run lasts, at the tempo it left.
    private func nextTickLength() -> Int {
        var frames = Int(player.samplesPerTick >> 32)
        remainder += player.samplesPerTick & 0xFFFF_FFFF
        if remainder > 0xFFFF_FFFF {
            remainder &= 0xFFFF_FFFF
            frames += 1
        }
        return min(Self.tickSpace, max(1, frames))
    }

    private func nextTick() {
        player.tick()
        if player.cameRound, started { loopCount += 1 }
        started = true
        tickFrames = nextTickLength()
        tickPosition = 0
        player.cards.render(left: left, right: right, count: tickFrames, channels: player.zchn)
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            if mono {
                for i in 0 ..< count {
                    let both = (left[tickPosition + i] + right[tickPosition + i]) * (gain * 0.5)
                    buffer[(done + i) * 2] = both
                    buffer[(done + i) * 2 + 1] = both
                }
            } else {
                for i in 0 ..< count {
                    buffer[(done + i) * 2] = left[tickPosition + i] * gain
                    buffer[(done + i) * 2 + 1] = right[tickPosition + i] * gain
                }
            }
            tickPosition += count
            done += count
        }
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn, with that player's dither. For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        restart()
        var output: [Int16] = []
        output.reserveCapacity(frames * 2)

        func dithered(_ sample: Float, _ state: inout Float) -> Int16 {
            seed = seed &* 134_775_813 &+ 1
            let noise = Float(Int32(bitPattern: seed)) * (1.0 / 4_294_967_296.0)
            let value = (sample * 32768.0 + noise) - state
            state = noise
            return Int16(max(-32768, min(32767, Int32(max(-1e9, min(1e9, value))))))
        }
        while output.count < frames * 2 {
            if tickPosition == tickFrames { nextTick() }
            while tickPosition < tickFrames, output.count < frames * 2 {
                output.append(dithered(left[tickPosition], &ditherLeft))
                output.append(dithered(right[tickPosition], &ditherRight))
                tickPosition += 1
            }
        }
        restart()
        return output
    }
}
