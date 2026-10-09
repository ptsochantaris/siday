// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// Register values a frame-based player wants on the chip after one tick.
/// Field names follow Ay_Emul's `RegisterAY` so the tracker ports read like their source.
public struct AYRegs {
    public var tonA = 0, tonB = 0, tonC = 0
    public var noise = 0
    public var mixer = 0
    public var amplA = 0, amplB = 0, amplC = 0
    public var envelope = 0
    public var envType = 0
    /// Set when the player wrote register 13 this tick. Writing it restarts the envelope even if the
    /// value is unchanged, so it cannot be inferred from the value.
    public var envWritten = false

    public init() {}

    @inline(__always) public mutating func setEnvelopeRegister(_ value: Int) {
        envType = value & 15
        envWritten = true
    }

    /// The fourteen register bytes as they would be written to the chip.
    public var bytes: [UInt8] {
        [
            UInt8(tonA & 0xFF), UInt8((tonA >> 8) & 0x0F),
            UInt8(tonB & 0xFF), UInt8((tonB >> 8) & 0x0F),
            UInt8(tonC & 0xFF), UInt8((tonC >> 8) & 0x0F),
            UInt8(noise & 0x1F), UInt8(mixer & 0x3F),
            UInt8(amplA & 0x1F), UInt8(amplB & 0x1F), UInt8(amplC & 0x1F),
            UInt8(envelope & 0xFF), UInt8((envelope >> 8) & 0xFF),
            UInt8(envType & 0x0F),
        ]
    }
}

/// A player that produces one set of AY registers per interrupt: tracker modules and register dumps.
public protocol AYFrameSource: AnyObject {
    var info: TuneInfo { get }
    /// 1, or 2 for TurboSound.
    var chipCount: Int { get }
    /// Values the file itself specifies; nil means "use the default".
    var fileClockHz: Double? { get }
    var fileFrameHz: Double? { get }
    var fileChipType: AYChipType? { get }
    /// Times the tune has wrapped to its loop point since `restart()`. It goes up during the tick that
    /// produces the first frame of the next pass.
    var loopCount: Int { get }
    /// True once a tune with no loop has run out.
    var hasEnded: Bool { get }
    func restart()
    /// Advances one interrupt, updating `regs[0]` (and `regs[1]` for TurboSound).
    /// `envWritten` is cleared by the caller beforehand.
    func tick(_ regs: UnsafeMutablePointer<AYRegs>)
}

public extension AYFrameSource {
    var chipCount: Int { 1 }
    var fileClockHz: Double? { nil }
    var fileFrameHz: Double? { nil }
    var fileChipType: AYChipType? { nil }
    var hasEnded: Bool { false }
}

/// Lets tools pull raw register frames out of a tune for comparison against reference players.
public protocol AYRegisterDumping {
    /// Restarts the tune and returns up to `maxFrames` frames, stopping at the first loop or end.
    /// Each frame is 14 register bytes plus a 15th byte that is 1 when register 13 was written; TurboSound frames carry both chips (30 bytes).
    func dumpFrames(maxFrames: Int) -> [[UInt8]]
}

/// Output gain for one AY chip. Set by ear against Spectrum emulators (JNext, Fuse): the AY sits at
/// half the level ayumi's own renderer would suggest, which with the beeper at twice one channel (see
/// `ayFileBeeperLevel`) leaves beeper tunes at the level Ay_Emul's defaults give them.
public let ayOutputGain: Float = 0.25
public let defaultAYClockHz = 1_773_400.0
public let defaultAYFrameHz = 50.0

public final class AYFramePlayer<Source: AYFrameSource>: Renderer, AYRegisterDumping {
    private let source: Source
    private let chips: UnsafeMutablePointer<AYChip>
    private let regs: UnsafeMutablePointer<AYRegs>
    private let chipCount: Int
    private let samplesPerFrame: Double
    private var untilNextFrame = 0.0
    private let gain: Float
    public let knownLength: Double?
    private let frameHz: Double

    public var info: TuneInfo { source.info }
    public var loopCount: Int { source.loopCount }
    public var hasEnded: Bool { source.hasEnded }
    public var endsByLooping: Bool { true }

    public init(source: Source, options: LoadOptions) {
        self.source = source
        chipCount = max(1, min(2, source.chipCount))
        let clock = options.clockHz ?? source.fileClockHz ?? defaultAYClockHz
        frameHz = options.frameHz ?? source.fileFrameHz ?? defaultAYFrameHz
        let type = options.chipType ?? source.fileChipType ?? .ay
        chips = .allocate(capacity: 2)
        for i in 0 ..< 2 {
            (chips + i).initialize(to: AYChip(type: type, clockHz: clock, sampleRate: outputSampleRate, stereo: options.stereo))
        }
        regs = .allocate(capacity: 2)
        regs.initialize(repeating: AYRegs(), count: 2)
        samplesPerFrame = Double(outputSampleRate) / frameHz
        // Two chips are turned down so that six channels fit, though not by half: they rarely all peak together.
        gain = chipCount == 2 ? ayOutputGain * 0.72 : ayOutputGain

        // Find the natural length by running the player silently to its first loop or end.
        let cap = Int(frameHz * 60 * 30)
        var frames = 0
        source.restart()
        while frames < cap, source.loopCount == 0, !source.hasEnded {
            source.tick(regs)
            frames += 1
        }
        if source.loopCount > 0 { frames -= 1 }
        knownLength = frames < cap ? Double(frames) / frameHz : nil
        restart()
    }

    deinit {
        chips.deinitialize(count: 2)
        chips.deallocate()
        regs.deallocate()
    }

    private func restart() {
        source.restart()
        regs[0] = AYRegs()
        regs[1] = AYRegs()
        chips[0].reset()
        chips[1].reset()
        untilNextFrame = 0
    }

    public func select(subsong _: Int) {
        restart()
    }

    @inline(__always) private func apply(_ chip: Int) {
        let r = regs[chip]
        let c = chips + chip
        c.pointee.write(0, UInt8(r.tonA & 0xFF)); c.pointee.write(1, UInt8((r.tonA >> 8) & 0x0F))
        c.pointee.write(2, UInt8(r.tonB & 0xFF)); c.pointee.write(3, UInt8((r.tonB >> 8) & 0x0F))
        c.pointee.write(4, UInt8(r.tonC & 0xFF)); c.pointee.write(5, UInt8((r.tonC >> 8) & 0x0F))
        c.pointee.write(6, UInt8(r.noise & 0x1F))
        c.pointee.write(7, UInt8(r.mixer & 0x3F))
        c.pointee.write(8, UInt8(r.amplA & 0x1F))
        c.pointee.write(9, UInt8(r.amplB & 0x1F))
        c.pointee.write(10, UInt8(r.amplC & 0x1F))
        c.pointee.write(11, UInt8(r.envelope & 0xFF)); c.pointee.write(12, UInt8((r.envelope >> 8) & 0xFF))
        if r.envWritten { c.pointee.write(13, UInt8(r.envType & 0x0F)) }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        let two = chipCount == 2
        let chip0 = chips, chip1 = chips + 1
        let gain = gain
        var countdown = untilNextFrame
        for i in 0 ..< frames {
            if countdown <= 0 {
                countdown += samplesPerFrame
                if source.hasEnded {
                    regs[0].amplA = 0; regs[0].amplB = 0; regs[0].amplC = 0
                    regs[1].amplA = 0; regs[1].amplB = 0; regs[1].amplC = 0
                } else {
                    regs[0].envWritten = false
                    regs[1].envWritten = false
                    source.tick(regs)
                }
                apply(0)
                if two { apply(1) }
            }
            countdown -= 1
            var (l, r) = chip0.pointee.sample()
            if two {
                let (l2, r2) = chip1.pointee.sample()
                l += l2; r += r2
            }
            buffer[i * 2] = Float(l) * gain
            buffer[i * 2 + 1] = Float(r) * gain
        }
        untilNextFrame = countdown
    }

    public var channelCount: Int { chipCount * 3 }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        for chip in 0 ..< chipCount { chips[chip].takeLevels(into: levels + chip * 3) }
    }

    public func dumpFrames(maxFrames: Int) -> [[UInt8]] {
        restart()
        var out: [[UInt8]] = []
        while out.count < maxFrames, source.loopCount == 0, !source.hasEnded {
            regs[0].envWritten = false
            regs[1].envWritten = false
            source.tick(regs)
            var frame = regs[0].bytes + [regs[0].envWritten ? 1 : 0]
            if chipCount == 2 { frame += regs[1].bytes + [regs[1].envWritten ? 1 : 0] }
            out.append(frame)
        }
        if source.loopCount > 0 { out.removeLast() }
        restart()
        return out
    }
}
