// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its copy of ModPlug's own reverb (`sounddsp/Reverb.cpp` and `Reverb.h`).

import SidayFoundation

/// ModPlug's own reverb, the one its mixer puts on the voices that ask for it, kept in OpenMPT as it
/// was, worked in whole numbers at the mixer's scale.
///
/// The voices that are sent to it are mixed into a buffer of their own (`touch(send:frames:)` and then
/// the mixing), and `process(main:send:frames:)` then puts the reverb of that buffer into the main mix,
/// and as much of the voices themselves as the depth leaves: the deeper the reverb, the less of them
/// is heard dry. The sound is dulled, smeared by a short all-pass delay and written into a long one,
/// from which seven taps make the early reflections. Those go on, a little later, into the tail: two
/// all-pass delays and a plain one for each side, the last fed back with a filter that lets the high
/// notes die sooner. A gentle filter takes any steady offset off what comes out.
///
/// When no voice has been sent to it for at least five seconds, or for as long as the room's reverb
/// takes to die if that is longer, it empties its delays and does nothing more until a voice is sent
/// again.
///
/// The room is one of twenty-nine, from the reverb settings of General MIDI 2 and the I3DL2
/// guidelines; the depth is from 1 to 16, 8 being half. Three of the original's oddities are kept: a
/// level in millibels is made into a gain with whole factors of two taken out of it, so that every
/// level comes out between -9 and +3 dB whatever the room asks for; only seven of the eight
/// reflections are heard; and where the left side of the tail takes the whole of its last all-pass
/// delay's output, the right takes only the scaled part that goes in.
///
/// The original's two functions for a reverb at half the rate, and its separate offset filter, are
/// left out: nothing calls them.
final class ModPlugReverb {
    /// How many frames the send buffer holds, and so the most `process` can be asked for with it: the
    /// mixer's block, `MIXBUFFERSIZE`.
    static let maxFrames = 512
    static let roomCount: UInt32 = 29

    // MARK: Settings

    /// How deep the reverb is, 1 to 16; OpenMPT's default is 8. It is read at every block.
    var depth: UInt32 = 8
    /// Which of the rooms, from 0; taken up by `initialize`, as OpenMPT takes it up.
    var room: UInt32 = 0

    /// The offset a voice sent to the reverb left when it stopped, which the send buffer is filled
    /// with, dying away, at the start of each block (`m_RvbROfsVol`, `m_RvbLOfsVol`). The mixer adds a
    /// voice's offset to these when it ends one; the reverb sets them to nought when it shuts down.
    var rightOffset: Int32 = 0, leftOffset: Int32 = 0

    /// A send buffer of `maxFrames` frames, left and right by turns, for a mixer that has none of its own.
    let sendBuffer: UnsafeMutablePointer<Int32>

    // MARK: State

    private var currentRoom = -1
    /// Whether the send buffer has been filled for this block (`gnReverbSend`).
    private var sending = false
    /// How many more samples to go on for with nothing sent, nought once the reverb has shut down.
    private(set) var samplesLeft: UInt32 = 0
    /// How many to start from when something is sent.
    private var decaySamples: UInt32 = 0

    private var lastInYL: Int32 = 0, lastInYR: Int32 = 0
    private var dcX1L: Int32 = 0, dcX1R: Int32 = 0, dcY1L: Int32 = 0, dcY1R: Int32 = 0

    // The pre-delay and reflections (`SWRvbRefDelay`).
    private var delayPos: UInt32 = 0, preDifPos: UInt32 = 0, refOutPos: UInt32 = 0
    private var reflectionsMasterGain: Int32 = 0
    private var roomCoeffL: Int16 = 0, roomCoeffR: Int16 = 0
    private var historyL: Int16 = 0, historyR: Int16 = 0
    private var preDifCoeffL: Int16 = 0, preDifCoeffR: Int16 = 0
    private var reflectionsGainL: Int16 = 0, reflectionsGainR: Int16 = 0
    /// Each reflection's delay, and its four gains: left to left, right to left, left to right, right to right.
    private let reflectionDelays: UnsafeMutablePointer<UInt32>
    private let reflectionGains: UnsafeMutablePointer<Int32>
    private let positions: UnsafeMutablePointer<UInt32>

    // The tail (`SWLateReverb`). Of the diffusion coefficients only the first pair is ever used.
    private var reverbDelay: UInt32 = 0, lateDelayPos: Int32 = 0
    private var difCoeffL: Int16 = 0, difCoeffR: Int16 = 0
    private var decayDC0L: Int16 = 0, decayDC1R: Int16 = 0
    private var decayLP0L: Int16 = 0, decayLP0R: Int16 = 0, decayLP1L: Int16 = 0, decayLP1R: Int16 = 0
    private var lpHistory0L: Int16 = 0, lpHistory0R: Int16 = 0, lpHistory1L: Int16 = 0, lpHistory1R: Int16 = 0
    private var dif2InGain0L: Int16 = 0, dif2InGain0R: Int16 = 0, dif2InGain1L: Int16 = 0, dif2InGain1R: Int16 = 0
    private var outGain0L: Int16 = 0, outGain0R: Int16 = 0, outGain1L: Int16 = 0, outGain1R: Int16 = 0
    private var lateMasterGain: Int32 = 0

    // The delays, left and right by turns, end to end in one piece of memory.
    private static let refDelayLength = 0x2000, preDifLength = 0x80, refOutLength = 0x1000, tankLength = 2048
    private static let refDelayMask: UInt32 = 0x1FFF, preDifMask: UInt32 = 0x7F, refOutMask: UInt32 = 0xFFF, tankMask: Int32 = 2047
    private let storage: UnsafeMutablePointer<Int16>
    private let storageCount: Int
    private let refDelay: UnsafeMutablePointer<Int16>, preDif: UnsafeMutablePointer<Int16>, refOut: UnsafeMutablePointer<Int16>
    private let diffusion1: UnsafeMutablePointer<Int16>, diffusion2: UnsafeMutablePointer<Int16>
    private let delay1: UnsafeMutablePointer<Int16>, delay2: UnsafeMutablePointer<Int16>

    init(sampleRate: Int, room: UInt32 = 0, depth: UInt32 = 8) {
        self.room = room
        self.depth = depth
        sendBuffer = .allocate(capacity: Self.maxFrames * 2)
        sendBuffer.initialize(repeating: 0, count: Self.maxFrames * 2)
        reflectionDelays = .allocate(capacity: 8)
        reflectionDelays.initialize(repeating: 0, count: 8)
        reflectionGains = .allocate(capacity: 32)
        reflectionGains.initialize(repeating: 0, count: 32)
        positions = .allocate(capacity: 8)
        positions.initialize(repeating: 0, count: 8)
        storageCount = 2 * (Self.refDelayLength + Self.preDifLength + Self.refOutLength + 4 * Self.tankLength)
        storage = .allocate(capacity: storageCount)
        storage.initialize(repeating: 0, count: storageCount)
        refDelay = storage
        preDif = refDelay + 2 * Self.refDelayLength
        refOut = preDif + 2 * Self.preDifLength
        diffusion1 = refOut + 2 * Self.refOutLength
        diffusion2 = diffusion1 + 2 * Self.tankLength
        delay1 = diffusion2 + 2 * Self.tankLength
        delay2 = delay1 + 2 * Self.tankLength
        initialize(reset: true, sampleRate: sampleRate)
    }

    deinit {
        sendBuffer.deallocate()
        reflectionDelays.deallocate()
        reflectionGains.deallocate()
        positions.deallocate()
        storage.deallocate()
    }

    // MARK: Rooms

    /// A room's settings as the I3DL2 guidelines have them (`SNDMIX_REVERB_PROPERTIES`), in millibels,
    /// seconds and per cent. The room's own level is not used.
    private struct Room {
        let roomHF: Int32
        let decayTime: Float, decayHFRatio: Float
        let reflections: Int32, reflectionsDelay: Float
        let reverb: Int32, reverbDelay: Float
        let diffusion: Float, density: Float

        init(_ room: Int32, _ roomHF: Int32, _ decayTime: Float, _ decayHFRatio: Float, _ reflections: Int32, _ reflectionsDelay: Float,
             _ reverb: Int32, _ reverbDelay: Float, _ diffusion: Float, _ density: Float) {
            self.roomHF = roomHF
            self.decayTime = decayTime
            self.decayHFRatio = decayHFRatio
            self.reflections = reflections
            self.reflectionsDelay = reflectionsDelay
            self.reverb = reverb
            self.reverbDelay = reverbDelay
            self.diffusion = diffusion
            self.density = density
        }
    }

    private static let rooms: [Room] = [
        Room(-1000, -200, 1.30, 0.90, 0, 0.002, 0, 0.010, 100.0, 75.0), // GM Plate
        Room(-1000, -600, 1.10, 0.83, -400, 0.005, 500, 0.010, 100.0, 100.0), // GM Small Room
        Room(-1000, -600, 1.30, 0.83, -1000, 0.010, -200, 0.020, 100.0, 100.0), // GM Medium Room
        Room(-1000, -600, 1.50, 0.83, -1600, 0.020, -1000, 0.040, 100.0, 100.0), // GM Large Room
        Room(-1000, -600, 1.80, 0.70, -1300, 0.015, -800, 0.030, 100.0, 100.0), // GM Medium Hall
        Room(-1000, -600, 1.80, 0.70, -2000, 0.030, -1400, 0.060, 100.0, 100.0), // GM Large Hall
        Room(-1000, -100, 1.49, 0.83, -2602, 0.007, 200, 0.011, 100.0, 100.0), // Generic
        Room(-1000, -6000, 0.17, 0.10, -1204, 0.001, 207, 0.002, 100.0, 100.0), // Padded Cell
        Room(-1000, -454, 0.40, 0.83, -1646, 0.002, 53, 0.003, 100.0, 100.0), // Room
        Room(-1000, -1200, 1.49, 0.54, -370, 0.007, 1030, 0.011, 100.0, 60.0), // Bathroom
        Room(-1000, -6000, 0.50, 0.10, -1376, 0.003, -1104, 0.004, 100.0, 100.0), // Living Room
        Room(-1000, -300, 2.31, 0.64, -711, 0.012, 83, 0.017, 100.0, 100.0), // Stone Room
        Room(-1000, -476, 4.32, 0.59, -789, 0.020, -289, 0.030, 100.0, 100.0), // Auditorium
        Room(-1000, -500, 3.92, 0.70, -1230, 0.020, -2, 0.029, 100.0, 100.0), // Concert Hall
        Room(-1000, 0, 2.91, 1.30, -602, 0.015, -302, 0.022, 100.0, 100.0), // Cave
        Room(-1000, -698, 7.24, 0.33, -1166, 0.020, 16, 0.030, 100.0, 100.0), // Arena
        Room(-1000, -1000, 10.05, 0.23, -602, 0.020, 198, 0.030, 100.0, 100.0), // Hangar
        Room(-1000, -4000, 0.30, 0.10, -1831, 0.002, -1630, 0.030, 100.0, 100.0), // Carpeted Hallway
        Room(-1000, -300, 1.49, 0.59, -1219, 0.007, 441, 0.011, 100.0, 100.0), // Hallway
        Room(-1000, -237, 2.70, 0.79, -1214, 0.013, 395, 0.020, 100.0, 100.0), // Stone Corridor
        Room(-1000, -270, 1.49, 0.86, -1204, 0.007, -4, 0.011, 100.0, 100.0), // Alley
        Room(-1000, -3300, 1.49, 0.54, -2560, 0.162, -613, 0.088, 79.0, 100.0), // Forest
        Room(-1000, -800, 1.49, 0.67, -2273, 0.007, -2217, 0.011, 50.0, 100.0), // City
        Room(-1000, -2500, 1.49, 0.21, -2780, 0.300, -2014, 0.100, 27.0, 100.0), // Mountains
        Room(-1000, -1000, 1.49, 0.83, -10000, 0.061, 500, 0.025, 100.0, 100.0), // Quarry
        Room(-1000, -2000, 1.49, 0.50, -2466, 0.179, -2514, 0.100, 21.0, 100.0), // Plain
        Room(-1000, 0, 1.65, 1.50, -1363, 0.008, -1153, 0.012, 100.0, 100.0), // Parking Lot
        Room(-1000, -1000, 2.81, 0.14, 429, 0.014, 648, 0.021, 80.0, 60.0), // Sewer Pipe
        Room(-1000, -4000, 1.49, 0.10, -449, 0.007, 1700, 0.011, 100.0, 100.0), // Underwater
    ]

    /// Where each reflection is, as a share in hundredths of the reverb's delay after the first, and
    /// its gains: left to left, right to right, left to right, right to left.
    private static let reflectionPresets: [(delay: Int32, ll: Int16, rr: Int16, lr: Int16, rl: Int16)] = [
        (0, 9830, 6554, 0, 0), (10, 6554, 13107, 0, 0), (24, -9830, 13107, 0, 0), (36, 13107, -6554, 0, 0),
        (54, 16384, 16384, -1638, -1638), (61, -13107, 8192, -328, -328), (73, -11468, -11468, -3277, 3277), (87, 13107, -9830, 4916, -4916),
    ]

    private static func saturateRound(_ value: Double) -> Int32 {
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        if rounded >= Double(Int32.max) { return .max }
        if rounded <= Double(Int32.min) { return .min }
        return Int32(rounded)
    }

    private static func onePoleLowPassCoef(_ scale: Int32, _ gain: Double, _ cutoff: Double, _ sampleRate: Double) -> Int32 {
        if gain > 0.999999 { return 0 }
        let g = gain * gain
        let scaleOver1mg = Double(scale) / (1.0 - g)
        let cosw = cos((2.0 * Double.pi) * cutoff / sampleRate)
        let root = ((g + g) * (1.0 - cosw) - g * g * (1.0 - cosw * cosw)).squareRoot()
        return saturateRound((1.0 - (root + g * cosw)) * scaleOver1mg)
    }

    /// OpenMPT's level in millibels as a gain. Its whole factors of two are lost (the power is of what
    /// is left once the whole number towards nought of the power plus a half is taken away), so -10 dB
    /// comes out as about -4 dB and +5 dB as -1 dB; that is kept, as the reverb's loudness rests on it.
    private static func mBToLinear(_ millibels: Int32) -> Double {
        if millibels == 0 { return 1 }
        if millibels <= -100_000 { return 0 }
        let value = Double(millibels) * 3.321928094887362304 / (100.0 * 20.0)
        return pow(2.0, value - Double(Int32(0.5 + value)))
    }

    private static func mBToLinear(_ scale: Int32, _ millibels: Int32) -> Int32 {
        saturateRound(mBToLinear(millibels) * Double(scale))
    }

    // MARK: Setting up

    /// OpenMPT's `CReverb::Initialize`: takes up the room, if it is not the one in use or `reset` is
    /// set, and with `reset` empties the delays and stops the reverb, as when a tune is started.
    func initialize(reset: Bool, sampleRate: Int) {
        if room >= Self.roomCount { room = 0 }
        let mixingFreq = UInt32(truncatingIfNeeded: sampleRate)
        if Int(room) != currentRoom || reset {
            currentRoom = Int(room)
            setUp(Self.rooms[Int(room)], outputFrequency: Float(mixingFreq))
        }
        if reset {
            samplesLeft = 0
            shutdown()
        }
        // Wait at least 5 seconds before shutting down the reverb
        if decaySamples < mixingFreq &* 5 { decaySamples = mixingFreq &* 5 }
    }

    /// `I3dl2_to_Generic` and the first half of `Initialize`, in one: the room's settings made into
    /// delays and gains for this sample rate.
    private func setUp(_ preset: Room, outputFrequency: Float) {
        let minRefDelay: Int32 = 96, maxRefDelay: Int32 = 7500, minRvbDelay: Int32 = 128, maxRvbDelay: Int32 = 3800
        let tankLength: Int32 = (298 + 446 + 842 + 1294 + 1366 + 1622 + 1546 + 2026) / 2

        var reverbLevel = preset.reverb, reflectionsLevel = preset.reflections
        // HACK: Somewhat normalize the reverb output level
        var maxLevel = reverbLevel > reflectionsLevel ? reverbLevel : reflectionsLevel
        if maxLevel < -600 {
            maxLevel += 600
            reverbLevel -= maxLevel
            reflectionsLevel -= maxLevel
        }

        let preDiffusion = 8192 + Int32((79.31 as Float) * preset.density)
        var tankDiffusion = Int32(((0.15 as Float) + preset.diffusion * ((0.36 as Float) * (0.01 as Float))) * (32767.0 as Float))
        if tankDiffusion > 0x7F00 { tankDiffusion = 0x7F00 }

        var refDelaySeconds = preset.reflectionsDelay
        if refDelaySeconds > (0.100 as Float) { refDelaySeconds = 0.100 }
        var lateDelay = Int32(preset.reverbDelay * outputFrequency)
        var reflectionsDelay = Int32(refDelaySeconds * outputFrequency)
        var decayTime = Int32(preset.decayTime * outputFrequency)
        if reflectionsDelay < minRefDelay {
            lateDelay -= minRefDelay - reflectionsDelay
            reflectionsDelay = minRefDelay
        }
        if reflectionsDelay > maxRefDelay {
            lateDelay += reflectionsDelay - maxRefDelay
            reflectionsDelay = maxRefDelay
        }
        // Adjust decay time when adjusting reverb delay
        if lateDelay < minRvbDelay {
            decayTime -= minRvbDelay - lateDelay
            lateDelay = minRvbDelay
        }
        if lateDelay > maxRvbDelay {
            decayTime += lateDelay - maxRvbDelay
            lateDelay = maxRvbDelay
        }

        let delayFactor: Float = decayTime <= tankLength ? 1.0 : Float(tankLength) / Float(decayTime)
        let reverbDecay = Int32(powf(0.001, delayFactor) * (32768.0 as Float))
        let decayTimeHF = Float(decayTime) * preset.decayHFRatio
        let delayFactorHF: Float = decayTimeHF <= Float(tankLength) ? 1.0 : Float(tankLength) / decayTimeHF
        let reverbDamping = powf(0.001, delayFactorHF)

        // Store reverb decay time (in samples) for reverb auto-shutdown
        decaySamples = UInt32(bitPattern: decayTime)

        // Room attenuation at high frequencies
        let roomLP = Self.onePoleLowPassCoef(32768, Self.mBToLinear(preset.roomHF), 5000, Double(outputFrequency))
        roomCoeffL = Int16(truncatingIfNeeded: roomLP)
        roomCoeffR = roomCoeffL

        // Pre-Diffusion factor (for both reflections and late reverb)
        preDifCoeffL = Int16(truncatingIfNeeded: preDiffusion &* 2)
        preDifCoeffR = preDifCoeffL

        for r in 0 ..< 8 {
            let p = Self.reflectionPresets[r]
            reflectionDelays[r] = UInt32(bitPattern: reflectionsDelay &+ (p.delay &* lateDelay &+ 50) / 100)
            reflectionGains[4 * r] = Int32(p.ll)
            reflectionGains[4 * r + 1] = Int32(p.rl)
            reflectionGains[4 * r + 2] = Int32(p.lr)
            reflectionGains[4 * r + 3] = Int32(p.rr)
        }
        reverbDelay = UInt32(bitPattern: lateDelay)

        reflectionsMasterGain = reflectionsLevel > -9000 ? Self.mBToLinear(32768, reflectionsLevel) : 0
        lateMasterGain = reverbLevel > -9000 ? Self.mBToLinear(32768, reverbLevel) : 0

        let tailDiffusion = UInt32(bitPattern: tankDiffusion) > 0x7F00 ? 0x7F00 : tankDiffusion
        difCoeffL = Int16(truncatingIfNeeded: tailDiffusion)
        difCoeffR = difCoeffL
        dif2InGain0L = 0x7000
        dif2InGain0R = 0x1000
        dif2InGain1L = 0x1000
        dif2InGain1R = 0x7000

        let decay = min(max(reverbDecay, 0), 0x7FF0)
        decayDC0L = Int16(decay)
        decayDC1R = Int16(decay)

        let damping = reverbDamping * reverbDamping
        let dampingLowPass = min(max(Self.onePoleLowPassCoef(32768, Double(damping), 5000, Double(outputFrequency)), 0x100), 0x7F00)
        decayLP0L = Int16(dampingLowPass)
        decayLP0R = 0
        decayLP1L = 0
        decayLP1R = Int16(dampingLowPass)
    }

    private func shutdown() {
        sending = false
        leftOffset = 0
        rightOffset = 0
        lastInYL = 0
        lastInYR = 0
        dcX1L = 0
        dcX1R = 0
        dcY1L = 0
        dcY1R = 0
        // The delays' positions and the histories of the two low-passes are left as they are, as OpenMPT leaves them.
        storage.update(repeating: 0, count: storageCount)
    }

    // MARK: Playing

    /// Fills a send buffer with the dying offset, unless it has been filled already in this block, and
    /// marks the block as one with something sent (`TouchReverbSendBuffer`). Call it before mixing a
    /// voice into the buffer; call it for each such voice, or once.
    func touch(send: UnsafeMutablePointer<Int32>, frames: Int) {
        if !sending { stereoFill(send, frames) }
        sending = true
    }

    /// Puts the reverb of what was sent in this block into `main`, which is OpenMPT's mix: left and right
    /// by turns, at its 28-bit scale. Call it once a block, whether or not anything was sent; `send` is
    /// then used as working memory and left changed.
    func process(main: UnsafeMutablePointer<Int32>, send: UnsafeMutablePointer<Int32>, frames: Int) {
        if !sending, samplesLeft == 0 { return }
        if !sending { stereoFill(send, frames) }

        // Dynamically adjust reverb master gains
        var masterGain = Int32(bitPattern: (UInt32(bitPattern: reflectionsMasterGain) &* depth) >> 4)
        if masterGain > 0x7FFF { masterGain = 0x7FFF }
        reflectionsGainL = Int16(truncatingIfNeeded: masterGain)
        reflectionsGainR = reflectionsGainL
        masterGain = Int32(bitPattern: (UInt32(bitPattern: lateMasterGain) &* depth) >> 4)
        if masterGain > 0x10000 { masterGain = 0x10000 }
        outGain0L = Int16(truncatingIfNeeded: (masterGain &+ 0x7F) >> 3)
        outGain0R = Int16(truncatingIfNeeded: (masterGain &+ 0xFF) >> 4)
        outGain1L = Int16(truncatingIfNeeded: (masterGain &+ 0xFF) >> 4)
        outGain1R = Int16(truncatingIfNeeded: (masterGain &+ 0x7F) >> 3)

        // Process Dry/Wet Mix
        var maxRvbGain = reflectionsMasterGain > lateMasterGain ? reflectionsMasterGain : lateMasterGain
        if maxRvbGain > 32768 { maxRvbGain = 32768 }
        var dryVol = Int32(bitPattern: (36 &- depth) >> 1)
        if dryVol < 8 { dryVol = 8 }
        if dryVol > 16 { dryVol = 16 }
        dryVol = 16 - (((16 - dryVol) &* maxRvbGain) >> 15)
        for i in 0 ..< 2 * frames {
            main[i] &+= (send[i] >> 4) &* dryVol
        }

        preFilter(send, frames)
        if frames > 0 { processPreDelay(send, frames) }

        // Process Reverb Reflections and Late Reverberation, in pieces that stop short of the ends of the
        // two places the reflections are written and read.
        var out = send
        var remaining = UInt32(truncatingIfNeeded: frames)
        while remaining > 0 {
            let posRef = refOutPos & Self.refOutMask
            let posRvb = (posRef &- reverbDelay) & Self.refOutMask
            let max1 = Self.refOutMask + 1 - posRef, max2 = Self.refOutMask + 1 - posRvb
            var n = remaining
            n = min(n, min(max1, max2))
            if n > 64 { n = 64 }
            processReflections(refOut + 2 * Int(posRef), out, Int(n))
            processLateReverb(refOut + 2 * Int(posRvb), out, Int(n))
            refOutPos = (refOutPos &+ n) & Self.refOutMask
            delayPos = (delayPos &+ n) & Self.refDelayMask
            out += 2 * Int(n)
            remaining -= n
        }

        postFilter(send, main, frames)

        // Automatically shut down if needed
        let count = UInt32(truncatingIfNeeded: frames)
        if sending {
            samplesLeft = decaySamples
        } else if samplesLeft > count {
            samplesLeft -= count
        } else {
            shutdown()
            samplesLeft = 0
        }
        sending = false
    }

    /// `StereoFill`: the offset, dying by a 256th a sample, rounded away from nought.
    private func stereoFill(_ buffer: UnsafeMutablePointer<Int32>, _ frames: Int) {
        if rightOffset == 0, leftOffset == 0 {
            buffer.update(repeating: 0, count: 2 * frames)
            return
        }
        var r = rightOffset, l = leftOffset
        for i in 0 ..< frames {
            r &-= (r &+ (((0 &- r) >> 31) & 0xFF)) >> 8
            l &-= (l &+ (((0 &- l) >> 31) & 0xFF)) >> 8
            buffer[2 * i] = r
            buffer[2 * i + 1] = l
        }
        rightOffset = r
        leftOffset = l
    }

    /// `ReverbProcessPreFiltering1x`: down to 16 bits, and the first stage of the room's low-pass.
    private func preFilter(_ wet: UnsafeMutablePointer<Int32>, _ frames: Int) {
        let lowpass = Int32(roomCoeffL)
        var y1L = lastInYL, y1R = lastInYR
        for i in 0 ..< frames {
            let xL = wet[2 * i] >> 12, xR = wet[2 * i + 1] >> 12
            y1L = xL &+ (((xL &- y1L) &* lowpass) >> 15)
            y1R = xR &+ (((xR &- y1R) &* lowpass) >> 15)
            wet[2 * i] = y1L
            wet[2 * i + 1] = y1R
        }
        lastInYL = y1L
        lastInYR = y1R
    }

    @inline(__always) private static func clamp16(_ x: Int32) -> Int32 {
        x < -32768 ? -32768 : (x > 32767 ? 32767 : x)
    }

    /// `ProcessPreDelay`: the second stage of the low-pass and the pre-diffusion, into the reflections' delay.
    private func processPreDelay(_ input: UnsafeMutablePointer<Int32>, _ frames: Int) {
        var pdPos = preDifPos
        var dPos = delayPos &- 1
        let coeffsL = Int32(roomCoeffL), coeffsR = Int32(roomCoeffR)
        let pdCoeffsL = Int32(preDifCoeffL), pdCoeffsR = Int32(preDifCoeffR)
        var hL = Int32(historyL), hR = Int32(historyR)
        let preDif = preDif, refDelay = refDelay
        for i in 0 ..< frames {
            let inL = Self.clamp16(input[2 * i]), inR = Self.clamp16(input[2 * i + 1])
            // Low-pass
            let lpL = (Self.clamp16(hL - inL) * coeffsL) / 65536
            let lpR = (Self.clamp16(hR - inR) * coeffsR) / 65536
            hL = Self.clamp16(Self.clamp16(lpL + lpL) + inL)
            hR = Self.clamp16(Self.clamp16(lpR + lpR) + inR)
            // Pre-Diffusion
            let preDifL = Int32(preDif[2 * Int(pdPos)]), preDifR = Int32(preDif[2 * Int(pdPos) + 1])
            pdPos = (pdPos + 1) & Self.preDifMask
            dPos = (dPos &+ 1) & Self.refDelayMask
            let preDif2L = Self.clamp16(hL - preDifL * pdCoeffsL / 65536)
            let preDif2R = Self.clamp16(hR - preDifR * pdCoeffsR / 65536)
            preDif[2 * Int(pdPos)] = Int16(preDif2L)
            preDif[2 * Int(pdPos) + 1] = Int16(preDif2R)
            refDelay[2 * Int(dPos)] = Int16(Self.clamp16(pdCoeffsL * preDif2L / 65536 + preDifL))
            refDelay[2 * Int(dPos) + 1] = Int16(Self.clamp16(pdCoeffsR * preDif2R / 65536 + preDifR))
        }
        preDifPos = pdPos
        historyL = Int16(hL)
        historyR = Int16(hR)
    }

    /// `ProcessReflections`: four reflections, then three more, each sum brought to 16 bits; the result is
    /// kept for the tail, and given the reflections' gain as the first of what the reverb puts out.
    private func processReflections(_ refOut: UnsafeMutablePointer<Int16>, _ out: UnsafeMutablePointer<Int32>, _ frames: Int) {
        let pos = positions, gains = reflectionGains, refDelay = refDelay
        for i in 0 ..< 7 { pos[i] = delayPos &- reflectionDelays[i] &- 1 }
        // For 28-bit final output: 16+15-3 = 28
        let refGain = Int32(reflectionsGainL) / 8
        for f in 0 ..< frames {
            // First stage
            var refOutL: Int32 = 0, refOutR: Int32 = 0
            for i in 0 ..< 4 {
                pos[i] = (pos[i] &+ 1) & Self.refDelayMask
                let refL = Int32(refDelay[2 * Int(pos[i])]), refR = Int32(refDelay[2 * Int(pos[i]) + 1])
                refOutL = refOutL &+ refL &* gains[4 * i] &+ refR &* gains[4 * i + 1]
                refOutR = refOutR &+ refL &* gains[4 * i + 2] &+ refR &* gains[4 * i + 3]
            }
            let stage1L = Self.clamp16(refOutL / 32768), stage1R = Self.clamp16(refOutR / 32768)
            // Second stage
            refOutL = 0
            refOutR = 0
            for i in 4 ..< 7 {
                pos[i] = (pos[i] &+ 1) & Self.refDelayMask
                let refL = Int32(refDelay[2 * Int(pos[i])]), refR = Int32(refDelay[2 * Int(pos[i]) + 1])
                refOutL = refOutL &+ refL &* gains[4 * i] &+ refR &* gains[4 * i + 1]
                refOutR = refOutR &+ refL &* gains[4 * i + 2] &+ refR &* gains[4 * i + 3]
            }
            let l = Self.clamp16(stage1L + refOutL / 32768), r = Self.clamp16(stage1R + refOutR / 32768)
            refOut[2 * f] = Int16(l)
            refOut[2 * f + 1] = Int16(r)
            out[2 * f] = l * refGain
            out[2 * f + 1] = r * refGain
        }
    }

    /// Where in one of the tail's delays the sample `length` before `position` is.
    @inline(__always) private static func tap(_ position: Int32, _ length: Int32) -> Int {
        2 * Int((position - length) & tankMask)
    }

    /// `ProcessLateReverb`: the tail, fed from the reflections of a little while ago and added to `mixOut`.
    private func processLateReverb(_ refIn: UnsafeMutablePointer<Int16>, _ mixOut: UnsafeMutablePointer<Int32>, _ frames: Int) {
        let mask = Self.tankMask
        let dif1 = diffusion1, dif2 = diffusion2, dly1 = delay1, dly2 = delay2
        let difL = Int32(difCoeffL), difR = Int32(difCoeffR)
        let lp0L = Int32(decayLP0L), lp0R = Int32(decayLP0R), lp1L = Int32(decayLP1L), lp1R = Int32(decayLP1R)
        let dcL = Int32(decayDC0L), dcR = Int32(decayDC1R)
        let g0L = Int32(dif2InGain0L), g0R = Int32(dif2InGain0R), g1L = Int32(dif2InGain1L), g1R = Int32(dif2InGain1R)
        let o0L = Int32(outGain0L), o0R = Int32(outGain0R), o1L = Int32(outGain1L), o1R = Int32(outGain1R)
        var h0L = Int32(lpHistory0L), h0R = Int32(lpHistory0R), h1L = Int32(lpHistory1L), h1R = Int32(lpHistory1R)
        var dPos = lateDelayPos & mask
        for f in 0 ..< frames {
            let refInL = Int32(refIn[2 * f]), refInR = Int32(refIn[2 * f + 1])

            let d2L = Self.tap(dPos, 773 * 2), d2R = Self.tap(dPos, 1013 * 2)
            let delay2LL = Int32(dly2[d2L]), delay2LR = Int32(dly2[d2L + 1])
            let delay2RL = Int32(dly2[d2R]), delay2RR = Int32(dly2[d2R + 1])
            let diff1L = Int32(dif1[Self.tap(dPos, 149 * 2)]), diff1R = Int32(dif1[Self.tap(dPos, 223 * 2) + 1])
            let diff2L = Int32(dif2[Self.tap(dPos, 421 * 2)]), diff2R = Int32(dif2[Self.tap(dPos, 647 * 2) + 1])

            let lpDecayLL = Self.clamp16(h0L - delay2LL) * lp0L / 65536
            let lpDecayLR = Self.clamp16(h0R - delay2LR) * lp0R / 65536
            let lpDecayRL = Self.clamp16(h1L - delay2RL) * lp1L / 65536
            let lpDecayRR = Self.clamp16(h1R - delay2RR) * lp1R / 65536
            // Low-passed decay
            h0L = Self.clamp16(Self.clamp16(lpDecayLL + lpDecayLL) + delay2LL)
            h0R = Self.clamp16(Self.clamp16(lpDecayLR + lpDecayLR) + delay2LR)
            h1L = Self.clamp16(Self.clamp16(lpDecayRL + lpDecayRL) + delay2RL)
            h1R = Self.clamp16(Self.clamp16(lpDecayRR + lpDecayRR) + delay2RR)

            // Apply decay gain
            let histDecayL = Self.clamp16(dcL * h0L / 32768)
            let histDecayR = Self.clamp16(dcR * h1R / 32768)
            let histDecayInL = Self.clamp16(histDecayL + refInL / 4)
            let histDecayInR = Self.clamp16(histDecayR + refInR / 4)
            let histDecayInDiffL = Self.clamp16(histDecayInL - diff1L * difL / 65536)
            let histDecayInDiffR = Self.clamp16(histDecayInR - diff1R * difR / 65536)
            let here = 2 * Int(dPos)
            dif1[here] = Int16(histDecayInDiffL)
            dif1[here + 1] = Int16(histDecayInDiffR)

            let delay1L = Self.clamp16(difL * histDecayInDiffL / 65536 + diff1L)
            let delay1R = Self.clamp16(difR * histDecayInDiffR / 65536 + diff1R)
            // Insert the diffusion output in the reverb delay line
            dly1[here] = Int16(delay1L)
            dly1[here + 1] = Int16(delay1R)
            let histDecayInDelayL = Self.clamp16(histDecayInL + delay1L)
            let histDecayInDelayR = Self.clamp16(histDecayInR + delay1R)

            // Input to second diffuser
            let d1L = Self.tap(dPos, 683 * 2), d1R = Self.tap(dPos, 811 * 2)
            let delay1LL = Int32(dly1[d1L]), delay1LR = Int32(dly1[d1L + 1])
            let delay1RL = Int32(dly1[d1R]), delay1RR = Int32(dly1[d1R + 1])

            let delay1GainsL = Self.clamp16((delay1LL * g0L + delay1LR * g0R) / 32768)
            let delay1GainsR = Self.clamp16((delay1RL * g1L + delay1RR * g1R) / 32768)

            // accumulate with reverb output
            let histDelay1LL = Self.clamp16(Self.clamp16(histDecayInDelayL + delay1LL) - delay1GainsL)
            let histDelay1LR = Self.clamp16(Self.clamp16(histDecayInDelayR + delay1LR) - delay1GainsR)
            let histDelay1RL = Self.clamp16(Self.clamp16(histDecayInDelayL + delay1RL) - delay1GainsL)
            let histDelay1RR = Self.clamp16(Self.clamp16(histDecayInDelayR + delay1RR) - delay1GainsR)
            let diff2outL = Self.clamp16(delay1GainsL - diff2L * difL / 65536)
            let diff2outR = Self.clamp16(delay1GainsR - diff2R * difR / 65536)
            let diff2outCoeffsL = difL * diff2outL / 65536
            let diff2outCoeffsR = difR * diff2outR / 65536
            dif2[here] = Int16(diff2outL)
            dif2[here + 1] = Int16(diff2outR)

            let delay2outL = Self.clamp16(diff2outCoeffsL + diff2L)
            let delay2outR = Self.clamp16(diff2outCoeffsR + diff2R)
            dly2[here] = Int16(delay2outL)
            dly2[here + 1] = Int16(delay2outR)
            dPos = (dPos + 1) & mask
            // Accumulate with reverb output; the right side takes the filtered input, as OpenMPT's does.
            mixOut[2 * f] = mixOut[2 * f] &+ Self.clamp16(histDelay1LL + delay2outL) &* o0L &+ Self.clamp16(histDelay1LR + delay2outR) &* o0R
            mixOut[2 * f + 1] = mixOut[2 * f + 1] &+ Self.clamp16(histDelay1RL + Self.clamp16(diff2outCoeffsL)) &* o1L
                &+ Self.clamp16(histDelay1RR + Self.clamp16(diff2outCoeffsR)) &* o1R
        }
        lpHistory0L = Int16(h0L)
        lpHistory0R = Int16(h0R)
        lpHistory1L = Int16(h1L)
        lpHistory1R = Int16(h1R)
        lateDelayPos = dPos
    }

    /// `ReverbProcessPostFiltering1x`: the reverb, with its steady offset taken off, added to the main mix.
    private func postFilter(_ reverb: UnsafeMutablePointer<Int32>, _ dry: UnsafeMutablePointer<Int32>, _ frames: Int) {
        var x1L = dcX1L, x1R = dcX1R, y1L = dcY1L, y1R = dcY1R
        var inL: Int32 = 0, inR: Int32 = 0
        for i in 0 ..< frames {
            inL = reverb[2 * i]
            inR = reverb[2 * i + 1]
            // x(n-1) - x(n)
            x1L &-= inL
            x1R &-= inR
            x1L = x1L / 1024 &- x1L
            x1R = x1R / 1024 &- x1R
            y1L &+= x1L
            y1R &+= x1R
            // add to dry mix
            dry[2 * i] &+= y1L
            dry[2 * i + 1] &+= y1R
            y1L &-= y1L / 512
            y1R &-= y1R / 512
            x1L = inL
            x1R = inR
        }
        dcY1L = y1L
        dcY1R = y1R
        dcX1L = inL
        dcX1R = inR
    }
}
