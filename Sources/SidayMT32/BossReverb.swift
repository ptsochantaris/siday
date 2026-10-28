// Copyright (C) 2003-2009 Dean Beeler, Jerome Fisher; (C) 2011-2024 Dean Beeler, Jerome Fisher, Sergey V. Mikayev
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Swift port of mt32emu's model of the Boss reverb chip with integer samples (BReverbModel.cpp of Munt's
// libmt32emu 2.8.3), free software under the GNU Lesser General Public License, version 2.1 or any later
// version (see THIRD-PARTY.md).

/// The settings of one of the reverb's four modes, as traced on the reverb RAM's lines of a real unit.
struct BossReverbSettings {
    let allpassSizes: [Int]
    let combSizes: [Int]
    let outLPositions: [Int]
    let outRPositions: [Int]
    let filterFactors: [UInt8]
    let feedbackFactors: [UInt8]
    let dryAmps: [UInt8]
    let wetLevels: [UInt8]
    let lpfAmp: UInt8

    /// The CM-32L's and the LAPC-I's, the newer model (the first comb's size is one more, for the Boss
    /// chip's working on the sample before; the tap delay's by three, for that and its own delays).
    static func cm32l(_ mode: Int) -> BossReverbSettings {
        let feedbackRoom: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0x28, 0x48, 0x60, 0x78, 0x80, 0x88, 0x90, 0x98,
                                     0x28, 0x48, 0x60, 0x78, 0x80, 0x88, 0x90, 0x98, 0x28, 0x48, 0x60, 0x78, 0x80, 0x88, 0x90, 0x98]
        switch mode {
        case 0:
            return BossReverbSettings(allpassSizes: [994, 729, 78], combSizes: [705 + 1, 2349, 2839, 3632],
                                      outLPositions: [2349, 141, 1960], outRPositions: [1174, 1570, 145],
                                      filterFactors: [0xA0, 0x60, 0x60, 0x60], feedbackFactors: feedbackRoom,
                                      dryAmps: [0xA0, 0xA0, 0xA0, 0xA0, 0xB0, 0xB0, 0xB0, 0xD0],
                                      wetLevels: [0x10, 0x30, 0x50, 0x70, 0x90, 0xC0, 0xF0, 0xF0], lpfAmp: 0x60)
        case 1:
            return BossReverbSettings(allpassSizes: [1324, 809, 176], combSizes: [961 + 1, 2619, 3545, 4519],
                                      outLPositions: [2618, 1760, 4518], outRPositions: [1300, 3532, 2274],
                                      filterFactors: [0x80, 0x60, 0x60, 0x60],
                                      feedbackFactors: [0, 0, 0, 0, 0, 0, 0, 0, 0x28, 0x48, 0x60, 0x70, 0x78, 0x80, 0x90, 0x98,
                                                        0x28, 0x48, 0x60, 0x78, 0x80, 0x88, 0x90, 0x98, 0x28, 0x48, 0x60, 0x78, 0x80, 0x88, 0x90, 0x98],
                                      dryAmps: [0xA0, 0xA0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xE0],
                                      wetLevels: [0x10, 0x30, 0x50, 0x70, 0x90, 0xC0, 0xF0, 0xF0], lpfAmp: 0x60)
        case 2:
            return BossReverbSettings(allpassSizes: [969, 644, 157], combSizes: [116 + 1, 2259, 2839, 3539],
                                      outLPositions: [2259, 718, 1769], outRPositions: [1136, 2128, 1],
                                      filterFactors: [0, 0x20, 0x20, 0x20],
                                      feedbackFactors: [0, 0, 0, 0, 0, 0, 0, 0, 0x30, 0x58, 0x78, 0x88, 0xA0, 0xB8, 0xC0, 0xD0,
                                                        0x30, 0x58, 0x78, 0x88, 0xA0, 0xB8, 0xC0, 0xD0, 0x30, 0x58, 0x78, 0x88, 0xA0, 0xB8, 0xC0, 0xD0],
                                      dryAmps: [0xA0, 0xA0, 0xB0, 0xB0, 0xB0, 0xB0, 0xC0, 0xE0],
                                      wetLevels: [0x10, 0x30, 0x50, 0x70, 0x90, 0xC0, 0xF0, 0xF0], lpfAmp: 0x80)
        default:
            return BossReverbSettings(allpassSizes: [], combSizes: [16000 + 1 + 1 + 1],
                                      outLPositions: [400, 624, 960, 1488, 2256, 3472, 5280, 8000],
                                      outRPositions: [800, 1248, 1920, 2976, 4512, 6944, 10560, 16000],
                                      filterFactors: [0x68], feedbackFactors: [0x68, 0x60],
                                      dryAmps: [0x20, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x20, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50],
                                      wetLevels: [0x18, 0x18, 0x28, 0x40, 0x60, 0x80, 0xA8, 0xF8], lpfAmp: 0)
        }
    }

    /// The first MT-32s', the older model.
    static func mt32(_ mode: Int) -> BossReverbSettings {
        let feedback: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0x28, 0x48, 0x60, 0x70, 0x78, 0x80, 0x90, 0x98,
                                 0x28, 0x48, 0x60, 0x78, 0x80, 0x88, 0x90, 0x98, 0x28, 0x48, 0x60, 0x78, 0x80, 0x88, 0x90, 0x98]
        let dry: [UInt8] = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80]
        let wet: [UInt8] = [0x10, 0x20, 0x30, 0x40, 0x50, 0x70, 0xA0, 0xE0]
        switch mode {
        case 0:
            return BossReverbSettings(allpassSizes: [994, 729, 78], combSizes: [575 + 1, 2040, 2752, 3629],
                                      outLPositions: [2040, 687, 1814], outRPositions: [1019, 2072, 1],
                                      filterFactors: [0xB0, 0x60, 0x60, 0x60], feedbackFactors: feedback, dryAmps: dry, wetLevels: wet, lpfAmp: 0x80)
        case 1:
            return BossReverbSettings(allpassSizes: [1324, 809, 176], combSizes: [961 + 1, 2619, 3545, 4519],
                                      outLPositions: [2618, 1760, 4518], outRPositions: [1300, 3532, 2274],
                                      filterFactors: [0x90, 0x60, 0x60, 0x60], feedbackFactors: feedback, dryAmps: dry, wetLevels: wet, lpfAmp: 0x80)
        case 2:
            return BossReverbSettings(allpassSizes: [969, 644, 157], combSizes: [116 + 1, 2259, 2839, 3539],
                                      outLPositions: [2259, 718, 1769], outRPositions: [1136, 2128, 1],
                                      filterFactors: [0, 0x60, 0x60, 0x60], feedbackFactors: feedback, dryAmps: dry, wetLevels: wet, lpfAmp: 0x80)
        default:
            return BossReverbSettings(allpassSizes: [], combSizes: [16000 + 1 + 1 + 1],
                                      outLPositions: [400, 624, 960, 1488, 2256, 3472, 5280, 8000],
                                      outRPositions: [800, 1248, 1920, 2976, 4512, 6944, 10560, 16000],
                                      filterFactors: [0x68], feedbackFactors: [0x68, 0x60],
                                      dryAmps: [0x10, 0x10, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x10, 0x20, 0x20, 0x10, 0x20, 0x10, 0x20, 0x10],
                                      wetLevels: [0x08, 0x18, 0x28, 0x40, 0x60, 0x80, 0xA8, 0xF8], lpfAmp: 0)
        }
    }
}

/// A ring buffer of 16-bit samples, the reverb's delays.
struct ReverbRingBuffer {
    let buffer: UnsafeMutablePointer<Int16>
    let size: Int
    var index = 0

    init(size: Int) {
        self.size = size
        buffer = .allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
    }

    func free() { buffer.deallocate() }

    @inline(__always)
    mutating func next() -> Int16 {
        index += 1
        if index >= size { index = 0 }
        return buffer[index]
    }

    var isEmpty: Bool {
        for i in 0 ..< size where buffer[i] < -8 || buffer[i] > 8 { return false }
        return true
    }

    func mute() { buffer.update(repeating: 0, count: size) }

    @inline(__always)
    func outputAt(_ outIndex: Int) -> Int16 { buffer[(size + index - outIndex) % size] }
}

/// The model of the Boss chip's reverb: an entrance delay with a low-pass filter, three all-pass filters in
/// series and three comb filters side by side; or, in the tap delay mode, one long comb.
final class BossReverb {
    // (The Boss chip's multiplications are taken in mt32emu's faster way, not its exact one.)
    @inline(__always)
    private static func weirdMul(_ sample: Int16, _ addMask: UInt8) -> Int16 {
        Int16(truncatingIfNeeded: (Int32(sample) * Int32(addMask)) >> 8)
    }

    @inline(__always)
    private static func mixCombs(_ out1: Int16, _ out2: Int16, _ out3: Int16) -> Int16 {
        // The Boss chip's adder saturates: the overflow is most likely here.
        let a = Int32(out1), b = Int32(out2)
        return MT32Synth.clip(a + (a >> 1) + b + (b >> 1) + Int32(out3))
    }

    let settings: BossReverbSettings
    let mt32Compatible: Bool
    private let tapDelayMode: Bool
    private var allpasses: [ReverbRingBuffer] = []
    private var combs: [ReverbRingBuffer] = []
    private var combFeedback: [UInt8] = []
    private var tapOutL = 0, tapOutR = 0
    private var dryAmp: UInt8 = 0
    private var wetLevel: UInt8 = 0

    init(mode: Int, mt32Compatible: Bool) {
        settings = mt32Compatible ? .mt32(mode) : .cm32l(mode)
        self.mt32Compatible = mt32Compatible
        tapDelayMode = mode == 3
    }

    deinit { close() }

    var isOpen: Bool { !combs.isEmpty }

    func open() {
        if isOpen { return }
        allpasses = settings.allpassSizes.map { ReverbRingBuffer(size: $0) }
        combs = settings.combSizes.map { ReverbRingBuffer(size: $0) }
        combFeedback = [UInt8](repeating: 0, count: combs.count)
        mute()
    }

    func close() {
        for buffer in allpasses { buffer.free() }
        for buffer in combs { buffer.free() }
        allpasses = []
        combs = []
    }

    func mute() {
        for buffer in allpasses { buffer.mute() }
        for buffer in combs { buffer.mute() }
    }

    func setParameters(time: UInt8, level: UInt8) {
        guard isOpen else { return }
        let level = Int(level & 7), time = Int(time & 7)
        if tapDelayMode {
            tapOutL = settings.outLPositions[time]
            tapOutR = settings.outRPositions[time & 7]
            combFeedback[0] = settings.feedbackFactors[level < 3 || time < 6 ? 0 : 1]
        } else {
            for i in 1 ..< combs.count { combFeedback[i] = settings.feedbackFactors[(i << 3) + time] }
        }
        if time == 0, level == 0 {
            dryAmp = 0
            wetLevel = 0
        } else {
            if tapDelayMode, time == 0 || (time == 1 && level == 1) {
                // (The MT-32's quirk in this mode, kept.)
                dryAmp = settings.dryAmps[level + 8]
            } else {
                dryAmp = settings.dryAmps[level]
            }
            wetLevel = settings.wetLevels[level]
        }
    }

    var isActive: Bool {
        guard isOpen else { return false }
        for buffer in allpasses where !buffer.isEmpty { return true }
        for buffer in combs where !buffer.isEmpty { return true }
        return false
    }

    @inline(__always)
    private func allpass(_ i: Int, _ input: Int16) -> Int16 {
        let bufferOut = allpasses[i].next()
        let index = allpasses[i].index
        // Stores the input less half the feedback, and gives the buffer's output plus half the feed-forward.
        allpasses[i].buffer[index] = Int16(truncatingIfNeeded: Int32(input) - Int32(bufferOut >> 1))
        return Int16(truncatingIfNeeded: Int32(bufferOut) + Int32(allpasses[i].buffer[index] >> 1))
    }

    @inline(__always)
    private func comb(_ i: Int, _ input: Int16) {
        let last = combs[i].buffer[combs[i].index]
        let filterIn = Int16(truncatingIfNeeded: Int32(input) + Int32(Self.weirdMul(combs[i].next(), combFeedback[i])))
        combs[i].buffer[combs[i].index] = Int16(truncatingIfNeeded: Int32(Self.weirdMul(last, settings.filterFactors[i])) - Int32(filterIn))
    }

    @inline(__always)
    private func entranceDelay(_ input: Int16) {
        let last = combs[0].buffer[combs[0].index]
        _ = combs[0].next()
        let lpfOut = Int16(truncatingIfNeeded: Int32(Self.weirdMul(last, settings.filterFactors[0])) + Int32(input))
        combs[0].buffer[combs[0].index] = Self.weirdMul(lpfOut, settings.lpfAmp)
    }

    @inline(__always)
    private func tapDelay(_ input: Int16) {
        let last = combs[0].buffer[combs[0].index]
        _ = combs[0].next()
        // (The feedback is taken from just below the right output: the filter's length goes with the time.)
        let filterIn = Int16(truncatingIfNeeded: Int32(input) + Int32(Self.weirdMul(combs[0].outputAt(tapOutR + 1), combFeedback[0])))
        combs[0].buffer[combs[0].index] = Int16(truncatingIfNeeded: Int32(Self.weirdMul(last, settings.filterFactors[0])) - Int32(filterIn))
    }

    /// Makes `count` samples of the reverb's sound (its wet output) from the two channels sent to it.
    func process(inLeft: UnsafePointer<Int16>, inRight: UnsafePointer<Int16>, outLeft: UnsafeMutablePointer<Int16>, outRight: UnsafeMutablePointer<Int16>, count: Int) {
        guard isOpen else {
            outLeft.update(repeating: 0, count: count)
            outRight.update(repeating: 0, count: count)
            return
        }
        for n in 0 ..< count {
            var dry: Int16
            if tapDelayMode {
                dry = Int16(truncatingIfNeeded: Int32(inLeft[n] >> 1) + Int32(inRight[n] >> 1))
            } else {
                dry = Int16(truncatingIfNeeded: Int32(inLeft[n] >> 2) + Int32(inRight[n] >> 2))
            }
            dry = Self.weirdMul(dry, dryAmp)
            if tapDelayMode {
                tapDelay(dry)
                outLeft[n] = Self.weirdMul(combs[0].outputAt(tapOutL + 1 + 1), wetLevel)
                outRight[n] = Self.weirdMul(combs[0].outputAt(tapOutR + 1 + 1), wetLevel)
            } else {
                // A position at the very end of a buffer is taken now, before it is written over.
                var link = combs[0].outputAt(settings.combSizes[0] - 1)
                entranceDelay(dry)
                link = allpass(0, link)
                link = allpass(1, link)
                link = allpass(2, link)
                let outL1 = combs[1].outputAt(settings.outLPositions[0] - 1)
                comb(1, link)
                comb(2, link)
                comb(3, link)
                let outL2 = combs[2].outputAt(settings.outLPositions[1])
                let outL3 = combs[3].outputAt(settings.outLPositions[2])
                outLeft[n] = Self.weirdMul(Self.mixCombs(outL1, outL2, outL3), wetLevel)
                let outR1 = combs[1].outputAt(settings.outRPositions[0])
                let outR2 = combs[2].outputAt(settings.outRPositions[1])
                let outR3 = combs[3].outputAt(settings.outRPositions[2])
                outRight[n] = Self.weirdMul(Self.mixCombs(outR1, outR2, outR3), wetLevel)
            }
        }
    }
}
