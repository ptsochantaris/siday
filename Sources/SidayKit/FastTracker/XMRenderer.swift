// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ft2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// An XM file, FastTracker 2's own kind of module, or a MOD file of more channels than the Amiga
/// has: played by FastTracker's replayer and mixer.
///
/// An XM has its instruments where its composer placed them between the speakers, and that is how it
/// is heard here unless the sound is asked for in mono. FastTracker plays a MOD file's channels all
/// in the middle.
public final class XMRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var knownLength: Double?
    public private(set) var loopCount = 0
    public var endsByLooping: Bool { true }
    public var hasEnded: Bool { player.stopped }

    private let module: FT2Module
    private let mono: Bool
    private var player: FT2Player
    private var tickFrames = 0, tickPosition = 0

    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// From the mixer's whole numbers to the player's range, at a level set by ear and by measure so
    /// that a module is about as loud as the chip tunes it is played among.
    private static let gain: Float = 1.0 / (256.0 * 32768.0) * 1.6

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try FT2Module(data)
        mono = options.stereo == .mono
        var info = TuneInfo(format: module.isMOD ? "MOD" : "XM")
        info.title = module.title
        info.detail = "FastTracker 2, \(module.song.antChn) channels"
        self.info = info

        // Once through in silence, to find how long the tune is.
        player = FT2Player(module)
        var frames = 0, ticks = 0
        while ticks < Self.mostTicks, !player.stopped {
            if !player.runSilentTick() { break }
            frames += Int(player.speedVal)
            ticks += 1
        }
        knownLength = ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
        player = FT2Player(module)
    }

    public func select(subsong _: Int) {
        restart()
    }

    private func restart() {
        player = FT2Player(module)
        tickFrames = 0
        tickPosition = 0
        loopCount = 0
    }

    private var started = false

    private func nextTick() {
        tickFrames = player.runTick()
        tickPosition = 0
        // The first row is always new; after that, a row played before is the tune come round.
        if player.cameRound, started { loopCount += 1 }
        started = true
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            let source = player.mixBuffer + tickPosition * 2
            if mono {
                for i in 0 ..< count {
                    let both = (Float(source[i * 2]) + Float(source[i * 2 + 1])) * (Self.gain * 0.5)
                    buffer[(done + i) * 2] = both
                    buffer[(done + i) * 2 + 1] = both
                }
            } else {
                for i in 0 ..< count {
                    buffer[(done + i) * 2] = Float(source[i * 2]) * Self.gain
                    buffer[(done + i) * 2 + 1] = Float(source[i * 2 + 1]) * Self.gain
                }
            }
            tickPosition += count
            done += count
        }
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn, clipped where it is too loud for them. For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        restart()
        var output: [Int16] = []
        output.reserveCapacity(frames * 2)
        while output.count < frames * 2 {
            if tickPosition == tickFrames { nextTick() }
            while tickPosition < tickFrames, output.count < frames * 2 {
                for side in 0 ..< 2 {
                    output.append(Int16(max(-32768, min(32767, player.mixBuffer[tickPosition * 2 + side] >> 8))))
                }
                tickPosition += 1
            }
        }
        restart()
        return output
    }
}
