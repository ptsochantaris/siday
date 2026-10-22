// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ASAP (Another Slight Atari Player), Copyright (C) 2010-2026 Piotr Fusik, used under
// the GNU General Public License, version 2 or later (see THIRD-PARTY.md).
//
// Atari's POKEY (1979), the chip that was the sound, the keyboard and the serial port of the Atari
// 400 and 800 and of every 8-bit Atari after them. Its four channels each count down from a
// frequency of their own, from the machine's clock divided by 28 or by 114, the first and third
// from the clock itself; each time one comes to nought its output may change, and which way it
// changes is its "distortion": a plain square wave, or the square wave let through only where one
// or two of the chip's shift registers, of 4, 5, 9 or 17 bits, say so. Two channels may be joined to count as
// one of sixteen bits, for a finer pitch, and the first two may each be passed through a high-pass
// filter clocked by the third and the fourth. A channel's level is one of sixteen, and may be held
// at it, so that what is written to it is heard as a sample.
//
// This is ASAP's emulation, which does not step the chip cycle by cycle but works out when each
// channel's output next changes, and puts each change into the sound where it falls between two
// of the player's samples, as a step smoothed by a windowed sinc, so that it is band-limited
// without being made at any rate of its own. The four channels' levels are added as the chip's DAC
// adds them, not quite in proportion, and the sum is passed through a gentle high-pass filter.

import SidayFoundation

/// When a channel will never next change.
let pokeyNever = 0x800000

struct POKEYChannel {
    var audf = 0
    var audc = 0
    var periodCycles = 28
    var tickCycle = pokeyNever
    /// When the channel's timer next interrupts the processor, if it is to.
    var timerCycle = pokeyNever
    /// What keeps it from sounding: the chip being held in its starting state, the serial port
    /// being used, and while a tune starts, the player (see `POKEYChannel.muteInit` and the rest).
    var mute = 0
    var out = 0
    /// The level it adds to the chip's sum when its output is high; while its output is low, the
    /// level it would add, made negative.
    var delta = 0

    static let muteInit = 1
    static let muteUser = 2
    static let muteSerialInput = 4

    mutating func endFrame(_ cycle: Int) {
        if timerCycle != pokeyNever { timerCycle -= cycle }
    }
}

final class POKEY {
    var channels = InlineArray<4, POKEYChannel>(repeating: POKEYChannel())
    private(set) var audctl = 0
    private var skctl = 3
    /// Which timers have interrupted the processor: a bit for each, clear when it has.
    var irqst = 0xFF
    /// True while the chip is held in its starting state, with its shift registers still.
    private(set) var initMode = false
    private var divCycles = 28
    private var reloadCycles1 = 28
    private var reloadCycles3 = 28
    /// Where the shift registers are, counted in cycles.
    private(set) var polyIndex = 15 * 31 * 131071

    private let deltaBufferLength: Int
    private let deltaBuffer: UnsafeMutablePointer<Int>
    private var sumDACInputs = 0
    private var sumDACOutputs = 0
    private var iirRate = 0
    private var iirAcc = 0
    private var trailing = 0

    /// Channels left out of the sound, a bit for each, and the sum of the levels of those that are
    /// not: the sum that is heard, which is the chip's whole sum while none is left out.
    private var leftOut = 0
    private var heardSum = 0
    private var heardChanged = false
    /// For what is shown of the voices, of the samples handed out since this was last asked: how loud
    /// each channel has been as a tone, the lowest and highest of the levels it has been held at (none,
    /// while `heldLow` is above `heldHigh`), whether its volume has jumped up, and the control (`audc`)
    /// it had at the last of them; and how often the console's loudspeaker has moved.
    private var reach = InlineArray<4, Int>(repeating: 0)
    private var heldLow = InlineArray<4, Int>(repeating: 16)
    private var heldHigh = InlineArray<4, Int>(repeating: -1)
    private var struck = InlineArray<4, Bool>(repeating: false)
    private var heardAudc = InlineArray<4, Int>(repeating: 0)
    private var speakerMoves = 0

    /// What the lights are to be told as the samples are handed out: a frame is made at once and
    /// handed out in parts, and the lights are of what has been handed out, as the scopes are. Each is
    /// a channel's control (`audc`) changed, from what to what, or (for no channel) the console's
    /// loudspeaker moving, and the sample it is heard in, as the sound's steps are put among them. They
    /// come in the order they are heard; `lampsTold` of them have been.
    private struct LampEvent {
        var index: Int
        var channel: Int
        var was: Int
        var now: Int
    }

    private var lampEvents: [LampEvent] = []
    private var lampsTold = 0

    /// For the voices' scopes, once asked (`keepVoices`): each channel's part of the sum, and fifth the
    /// console's loudspeaker, as its steps fall among the samples, kept as the sound's own steps are
    /// (`deltaBuffer`): in `voiceSteps` all of each step, in the sample it falls in, and in `voiceParts`
    /// the part of it that sample has, so that a sample is the average of what the voice was over it,
    /// and a tone too high to hear is a level, as it is heard, and not some lower one it is not.
    /// `voiceLevels` is where each stands as of the last sample handed out, and `speakerUp` whether the
    /// loudspeaker is out.
    private var voiceSteps: UnsafeMutablePointer<Int32>?
    private var voiceParts: UnsafeMutablePointer<Float>?
    private var voiceLevels = InlineArray<5, Int32>(repeating: 0)
    private var speakerUp = false
    var keepsVoices: Bool { voiceSteps != nil }

    // The DAC's sums, as ASAP has them from measurements of chips made by AMI: the channels'
    // levels added, and compressed by where the chip's output is set to work.
    private static let compressedSums: [Int] = [
        0, 35, 73, 111, 149, 189, 228, 266, 304, 342, 379, 415, 450, 484, 516, 546,
        575, 602, 628, 652, 674, 695, 715, 733, 750, 766, 782, 796, 809, 822, 834, 846,
        856, 867, 876, 886, 894, 903, 911, 918, 926, 933, 939, 946, 952, 958, 963, 969,
        974, 979, 984, 988, 993, 997, 1001, 1005, 1009, 1013, 1016, 1019, 1023,
    ]

    static let interpolationShift = 10
    static let unitDeltaLength = 32
    static let deltaResolution = 14

    init(sampleRate: Int) {
        // Enough for one PAL frame, and some over, as whole instructions are run and the steps
        // are spread over samples on either side.
        deltaBufferLength = Int(Int64(sampleRate) * 312 * 114 / 1_773_447) + Self.unitDeltaLength + 2
        deltaBuffer = .allocate(capacity: deltaBufferLength)
        deltaBuffer.initialize(repeating: 0, count: deltaBufferLength)
        lampEvents.reserveCapacity(1024)
        initialize(sampleRate: sampleRate)
    }

    deinit {
        deltaBuffer.deallocate()
        voiceSteps?.deallocate()
        voiceParts?.deallocate()
    }

    func startFrame() {
        let kept = deltaBufferLength - trailing
        if kept > 0 { deltaBuffer.update(from: deltaBuffer + trailing, count: kept) }
        (deltaBuffer + kept).update(repeating: 0, count: trailing)
        if kept > 0 {
            lampEvents.removeFirst(lampsTold)
            for e in lampEvents.indices { lampEvents[e].index -= trailing }
        } else {
            // Nothing is to be left of what the lights were to be told, as once a tune has been started,
            // whose first moments are made and not heard: what is heard is the chip as it is, and a note
            // struck then is struck as the tune is first heard, if it is still sounding.
            for event in lampEvents[lampsTold...] where event.channel >= 0 && event.now & 0xF > event.was & 0xF {
                if channels[event.channel].audc & 0xF != 0 { struck[event.channel] = true }
            }
            lampEvents.removeAll(keepingCapacity: true)
            for c in 0 ..< 4 { heardAudc[c] = channels[c].audc }
        }
        lampsTold = 0
        if let voiceSteps, let voiceParts {
            for voice in 0 ..< 5 {
                let steps = voiceSteps + voice * deltaBufferLength, parts = voiceParts + voice * deltaBufferLength
                if kept > 0 {
                    steps.update(from: steps + trailing, count: kept)
                    parts.update(from: parts + trailing, count: kept)
                }
                (steps + kept).update(repeating: 0, count: trailing)
                (parts + kept).update(repeating: 0, count: trailing)
            }
            // Nothing is left of the steps: where the voices stand is where the chip has them. (So it
            // is once a tune has been started, whose first moments are made and not heard.)
            if kept <= 0 { takeVoiceLevels() }
        }
        if heardChanged {
            heardChanged = false
            let newOutput = Self.compressedSums[heardSum] << 16
            addExternalDelta(0, newOutput - sumDACOutputs)
            sumDACOutputs = newOutput
        }
    }

    func initialize(sampleRate: Int) {
        trailing = deltaBufferLength
        for c in 0 ..< 4 { channels[c] = POKEYChannel() }
        audctl = 0
        skctl = 3
        irqst = 0xFF
        initMode = false
        divCycles = 28
        reloadCycles1 = 28
        reloadCycles3 = 28
        polyIndex = 15 * 31 * 131071
        iirAcc = 0
        iirRate = 44100 * 6 / sampleRate
        sumDACInputs = 0
        sumDACOutputs = 0
        heardSum = 0
        heardChanged = false
        for c in 0 ..< 4 {
            reach[c] = 0
            heldLow[c] = 16
            heldHigh[c] = -1
            struck[c] = false
        }
        speakerMoves = 0
        speakerUp = false
        startFrame()
    }

    /// Where in the samples each cycle falls, as the pair of chips keeps it (see `POKEYPair`).
    var sampleFactor = 0
    var sampleOffset = 0

    // MARK: The channels

    private func addDelta(_ c: Int, _ cycle: Int, _ delta: Int) {
        if voiceSteps != nil { addVoiceStep(c, cycle, delta) }
        sumDACInputs += delta
        if leftOut & (1 << c) == 0 { heardSum += delta }
        if channels[c].mute & POKEYChannel.muteUser != 0 { return }
        let newOutput = Self.compressedSums[heardSum] << 16
        addExternalDelta(cycle, newOutput - sumDACOutputs)
        sumDACOutputs = newOutput
    }

    /// A step in the sound at the given cycle, of the given size.
    func addExternalDelta(_ cycle: Int, _ delta: Int) {
        if delta == 0 { return }
        var i = cycle &* sampleFactor &+ sampleOffset
        let fraction = i >> (POKEYPair.sampleFactorShift - Self.interpolationShift) & ((1 << Self.interpolationShift) - 1)
        i >>= POKEYPair.sampleFactorShift
        guard i >= 0, i + Self.unitDeltaLength <= deltaBufferLength else { return }
        let step = delta >> Self.deltaResolution
        let sinc = POKEYPair.sincLookup.baseAddress! + fraction * Self.unitDeltaLength
        for j in 0 ..< Self.unitDeltaLength {
            deltaBuffer[i + j] += step * Int(sinc[j])
        }
    }

    private func slope(_ c: Int, _ cycle: Int) {
        channels[c].delta = -channels[c].delta
        addDelta(c, cycle, channels[c].delta)
    }

    private func doTick(_ c: Int, _ cycle: Int) {
        channels[c].tickCycle += channels[c].periodCycles
        let audc = channels[c].audc
        if audc & 0xB0 == 0xA0 {
            channels[c].out ^= 1
        } else if audc & 0x10 != 0 || initMode {
            return
        } else {
            let poly = cycle + polyIndex - c
            if audc < 0x80, 0x65BD_44E0 & (1 << (poly % 31)) == 0 { return } // 0000011100100010101111011010011
            if audc & 0x20 != 0 {
                channels[c].out ^= 1
            } else {
                var newOut: Int
                if audc & 0x40 != 0 {
                    newOut = 0x5370 >> (poly % 15) // 000011101100101
                } else if audctl < 0x80 {
                    let p = poly % 131071
                    newOut = Int(POKEYPair.poly17Lookup[p >> 3]) >> (p & 7)
                } else {
                    newOut = Int(POKEYPair.poly9Lookup[poly % 511])
                }
                newOut &= 1
                if channels[c].out == newOut { return }
                channels[c].out = newOut
            }
        }
        slope(c, cycle)
    }

    private func slopeDown(_ c: Int, _ cycle: Int) {
        if channels[c].delta > 0, channels[c].mute == 0 { slope(c, cycle) }
    }

    private func doStimer(_ c: Int, _ cycle: Int, _ reload: Int) {
        if channels[c].tickCycle != pokeyNever { channels[c].tickCycle = cycle + reload }
        if channels[c].out != 0 {
            channels[c].out = 0
            slope(c, cycle)
        }
    }

    private func setMute(_ c: Int, _ enable: Bool, _ mask: Int, _ cycle: Int) {
        if enable {
            channels[c].mute |= mask
            channels[c].tickCycle = pokeyNever
        } else {
            channels[c].mute &= ~mask
            if channels[c].mute == 0, channels[c].tickCycle == pokeyNever { channels[c].tickCycle = cycle }
        }
    }

    private func setAudc(_ c: Int, _ data: Int, _ cycle: Int) {
        if channels[c].audc == data { return }
        generateUntilCycle(cycle)
        let volume = data & 0xF
        lampEvents.append(LampEvent(index: lampIndex(cycle), channel: c, was: channels[c].audc, now: data))
        channels[c].audc = data
        let delta = channels[c].delta
        if data & 0x10 != 0 {
            addDelta(c, cycle, delta > 0 ? volume - delta : volume)
            channels[c].delta = volume
        } else if delta > 0 {
            addDelta(c, cycle, volume - delta)
            channels[c].delta = volume
        } else {
            channels[c].delta = -volume
        }
    }

    /// Works out the channels' changes up to the given cycle, as they are now set.
    func generateUntilCycle(_ cycleLimit: Int) {
        while true {
            var cycle = cycleLimit
            for c in 0 ..< 4 where cycle > channels[c].tickCycle { cycle = channels[c].tickCycle }
            if cycle == cycleLimit { break }

            if cycle == channels[2].tickCycle {
                if audctl & 4 != 0 { slopeDown(0, cycle) }
                doTick(2, cycle)
            }
            if cycle == channels[3].tickCycle {
                if audctl & 8 != 0 { channels[2].tickCycle = cycle + reloadCycles3 }
                if audctl & 2 != 0 { slopeDown(1, cycle) }
                doTick(3, cycle)
            }
            if cycle == channels[0].tickCycle {
                if skctl & 0x88 == 8 { channels[1].tickCycle = cycle + channels[1].periodCycles } // two-tone, sending 1
                doTick(0, cycle)
            }
            if cycle == channels[1].tickCycle {
                if audctl & 0x10 != 0 {
                    channels[0].tickCycle = cycle + reloadCycles1
                } else if skctl & 8 != 0 { // two-tone
                    channels[0].tickCycle = cycle + channels[0].periodCycles
                }
                doTick(1, cycle)
            }
        }
    }

    func endFrame(_ cycle: Int) {
        generateUntilCycle(cycle)
        polyIndex += cycle
        let m = audctl & 0x80 != 0 ? 15 * 31 * 511 : 15 * 31 * 131071
        if polyIndex >= 2 * m { polyIndex -= m }
        for c in 0 ..< 4 where channels[c].tickCycle != pokeyNever {
            channels[c].tickCycle -= cycle
        }
    }

    var isSilent: Bool {
        for c in 0 ..< 4 where channels[c].audc & 0xF != 0 { return false }
        return true
    }

    /// Mutes the channels by the player's own mute, which ASAP uses while a tune starts.
    func mute(_ mask: Int) {
        for c in 0 ..< 4 { setMute(c, mask & (1 << c) != 0, POKEYChannel.muteUser, 0) }
    }

    private func initMute(_ cycle: Int) {
        let held = initMode
        setMute(0, held && audctl & 0x40 == 0, POKEYChannel.muteInit, cycle)
        setMute(1, held && audctl & 0x50 != 0x50, POKEYChannel.muteInit, cycle)
        setMute(2, held && audctl & 0x20 == 0, POKEYChannel.muteInit, cycle)
        setMute(3, held && audctl & 0x28 != 0x28, POKEYChannel.muteInit, cycle)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func poke(_ addr: Int, _ data: Int, _ cycle: Int) -> Int {
        var nextEventCycle = pokeyNever
        switch addr & 0xF {
        case 0x00:
            if data == channels[0].audf { break }
            generateUntilCycle(cycle)
            channels[0].audf = data
            switch audctl & 0x50 {
            case 0x00:
                channels[0].periodCycles = divCycles * (data + 1)
            case 0x10:
                channels[1].periodCycles = divCycles * (data + (channels[1].audf << 8) + 1)
                reloadCycles1 = divCycles * (data + 1)
            case 0x40:
                channels[0].periodCycles = data + 4
            default:
                channels[1].periodCycles = data + (channels[1].audf << 8) + 7
                reloadCycles1 = data + 4
            }
        case 0x01:
            setAudc(0, data, cycle)
        case 0x02:
            if data == channels[1].audf { break }
            generateUntilCycle(cycle)
            channels[1].audf = data
            switch audctl & 0x50 {
            case 0x00, 0x40:
                channels[1].periodCycles = divCycles * (data + 1)
            case 0x10:
                channels[1].periodCycles = divCycles * (channels[0].audf + (data << 8) + 1)
            default:
                channels[1].periodCycles = channels[0].audf + (data << 8) + 7
            }
        case 0x03:
            setAudc(1, data, cycle)
        case 0x04:
            if data == channels[2].audf { break }
            generateUntilCycle(cycle)
            channels[2].audf = data
            switch audctl & 0x28 {
            case 0x00:
                channels[2].periodCycles = divCycles * (data + 1)
            case 0x08:
                channels[3].periodCycles = divCycles * (data + (channels[3].audf << 8) + 1)
                reloadCycles3 = divCycles * (data + 1)
            case 0x20:
                channels[2].periodCycles = data + 4
            default:
                channels[3].periodCycles = data + (channels[3].audf << 8) + 7
                reloadCycles3 = data + 4
            }
        case 0x05:
            setAudc(2, data, cycle)
        case 0x06:
            if data == channels[3].audf { break }
            generateUntilCycle(cycle)
            channels[3].audf = data
            switch audctl & 0x28 {
            case 0x00, 0x20:
                channels[3].periodCycles = divCycles * (data + 1)
            case 0x08:
                channels[3].periodCycles = divCycles * (channels[2].audf + (data << 8) + 1)
            default:
                channels[3].periodCycles = channels[2].audf + (data << 8) + 7
            }
        case 0x07:
            setAudc(3, data, cycle)
        case 0x08:
            if data == audctl { break }
            generateUntilCycle(cycle)
            audctl = data
            divCycles = data & 1 != 0 ? 114 : 28
            switch data & 0x50 {
            case 0x00:
                channels[0].periodCycles = divCycles * (channels[0].audf + 1)
                channels[1].periodCycles = divCycles * (channels[1].audf + 1)
            case 0x10:
                channels[0].periodCycles = divCycles << 8
                channels[1].periodCycles = divCycles * (channels[0].audf + (channels[1].audf << 8) + 1)
                reloadCycles1 = divCycles * (channels[0].audf + 1)
            case 0x40:
                channels[0].periodCycles = channels[0].audf + 4
                channels[1].periodCycles = divCycles * (channels[1].audf + 1)
            default:
                channels[0].periodCycles = 256
                channels[1].periodCycles = channels[0].audf + (channels[1].audf << 8) + 7
                reloadCycles1 = channels[0].audf + 4
            }
            switch data & 0x28 {
            case 0x00:
                channels[2].periodCycles = divCycles * (channels[2].audf + 1)
                channels[3].periodCycles = divCycles * (channels[3].audf + 1)
            case 0x08:
                channels[2].periodCycles = divCycles << 8
                channels[3].periodCycles = divCycles * (channels[2].audf + (channels[3].audf << 8) + 1)
                reloadCycles3 = divCycles * (channels[2].audf + 1)
            case 0x20:
                channels[2].periodCycles = channels[2].audf + 4
                channels[3].periodCycles = divCycles * (channels[3].audf + 1)
            default:
                channels[2].periodCycles = 256
                channels[3].periodCycles = channels[2].audf + (channels[3].audf << 8) + 7
                reloadCycles3 = channels[2].audf + 4
            }
            initMute(cycle)
        case 0x09:
            generateUntilCycle(cycle)
            doStimer(0, cycle, audctl & 0x10 == 0 ? channels[0].periodCycles : reloadCycles1)
            doStimer(1, cycle, channels[1].periodCycles)
            doStimer(2, cycle, audctl & 8 == 0 ? channels[2].periodCycles : reloadCycles3)
            doStimer(3, cycle, channels[3].periodCycles)
        case 0x0E:
            irqst |= data ^ 0xFF
            var i = 3
            while true {
                if data & irqst & (i + 1) != 0 {
                    if channels[i].timerCycle == pokeyNever {
                        var t = channels[i].tickCycle
                        while t < cycle { t += channels[i].periodCycles }
                        channels[i].timerCycle = t
                        if nextEventCycle > t { nextEventCycle = t }
                    }
                } else {
                    channels[i].timerCycle = pokeyNever
                }
                if i == 0 { break }
                i >>= 1
            }
        case 0x0F:
            if data == skctl { break }
            generateUntilCycle(cycle)
            skctl = data
            let held = data & 3 == 0
            if initMode, !held {
                polyIndex = (audctl & 0x80 != 0 ? 15 * 31 * 511 - 1 : 15 * 31 * 131071 - 1) - cycle
            }
            initMode = held
            initMute(cycle)
            setMute(2, data & 0x10 != 0, POKEYChannel.muteSerialInput, cycle)
            setMute(3, data & 0x10 != 0, POKEYChannel.muteSerialInput, cycle)
        default:
            break
        }
        return nextEventCycle
    }

    func checkIrq(_ cycle: Int, _ nextEventCycle: Int) -> Int {
        var next = nextEventCycle
        var i = 3
        while true {
            let timerCycle = channels[i].timerCycle
            if cycle >= timerCycle {
                irqst &= ~(i + 1)
                channels[i].timerCycle = pokeyNever
            } else if next > timerCycle {
                next = timerCycle
            }
            if i == 0 { break }
            i >>= 1
        }
        return next
    }

    /// The sample at `i` of those made, through the high-pass filter.
    @inline(__always) func storeSample(_ i: Int) -> Int16 {
        iirAcc += deltaBuffer[i] - ((iirRate * iirAcc) >> 11)
        return Int16(min(32767, max(-32767, iirAcc >> 11)))
    }

    func accumulateTrailing(_ i: Int) {
        trailing = i
    }

    // MARK: What is shown and heard

    /// Starts keeping each voice's steps for its scope (see `voiceSteps`), with the loudspeaker in or
    /// out as it now is.
    func keepVoices(speakerUp: Bool) {
        guard voiceSteps == nil else { return }
        let steps = UnsafeMutablePointer<Int32>.allocate(capacity: 5 * deltaBufferLength)
        steps.initialize(repeating: 0, count: 5 * deltaBufferLength)
        let parts = UnsafeMutablePointer<Float>.allocate(capacity: 5 * deltaBufferLength)
        parts.initialize(repeating: 0, count: 5 * deltaBufferLength)
        voiceSteps = steps
        voiceParts = parts
        self.speakerUp = speakerUp
        takeVoiceLevels()
    }

    /// Where each voice stands now, by the chip: a channel's part of the sum is its level while its
    /// output is high, and nothing while it is low (see `POKEYChannel.delta`).
    private func takeVoiceLevels() {
        for c in 0 ..< 4 { voiceLevels[c] = Int32(max(0, channels[c].delta)) }
        voiceLevels[4] = speakerUp ? 1 : 0
    }

    /// A voice's step at the given cycle, put in the sample where the middle of the sound's own step
    /// for it falls (see `addExternalDelta`).
    private func addVoiceStep(_ voice: Int, _ cycle: Int, _ delta: Int) {
        guard let voiceSteps, let voiceParts, delta != 0 else { return }
        let place = cycle &* sampleFactor &+ sampleOffset
        let i = (place >> POKEYPair.sampleFactorShift) + Self.unitDeltaLength / 2
        guard i >= 0, i < deltaBufferLength else { return }
        let into = Float(place & ((1 << POKEYPair.sampleFactorShift) - 1)) / Float(1 << POKEYPair.sampleFactorShift)
        voiceSteps[voice * deltaBufferLength + i] += Int32(delta)
        voiceParts[voice * deltaBufferLength + i] += Float(delta) * (1 - into)
    }

    /// The console's loudspeaker going out or in, at the given cycle, for its scope.
    func moveSpeaker(_ cycle: Int, up: Bool) {
        guard up != speakerUp else { return }
        speakerUp = up
        addVoiceStep(4, cycle, up ? 1 : -1)
    }

    /// Keeps what each voice was over the samples from `start` to `end` (as `storeSample` counts them),
    /// the four channels as voices `first` on and the loudspeaker, if it is asked for, as `speaker`.
    func keepVoices(from start: Int, to end: Int, in waves: ChannelWaves, first: Int, speaker: Int?) {
        guard let voiceSteps, let voiceParts, end > start else { return }
        for voice in 0 ..< (speaker == nil ? 4 : 5) {
            let steps = voiceSteps + voice * deltaBufferLength, parts = voiceParts + voice * deltaBufferLength
            let kept = voice < 4 ? first + voice : speaker!
            var level = voiceLevels[voice]
            for i in start ..< end {
                waves.store(kept, at: i - start, Float(level) + parts[i])
                level &+= steps[i]
            }
            voiceLevels[voice] = level
        }
    }

    /// Leaves channels out of the sound, a bit for each. The sound goes to the new sum at the start
    /// of the next frame.
    func leaveOut(_ mask: Int) {
        guard mask != leftOut else { return }
        leftOut = mask
        heardSum = 0
        for c in 0 ..< 4 where mask & (1 << c) == 0 { heardSum += max(0, channels[c].delta) }
        heardChanged = true
    }

    /// A level a channel has been held at, for its light.
    private func noteHeld(_ c: Int, _ level: Int) {
        heldLow[c] = min(heldLow[c], level)
        heldHigh[c] = max(heldHigh[c], level)
    }

    /// Where among the samples what happens at the given cycle is heard: where the middle of the
    /// sound's step for it falls (see `addExternalDelta`).
    private func lampIndex(_ cycle: Int) -> Int {
        let i = ((cycle &* sampleFactor &+ sampleOffset) >> POKEYPair.sampleFactorShift) + Self.unitDeltaLength / 2
        return max(0, min(deltaBufferLength - 1, i))
    }

    /// The console's loudspeaker moving, at the given cycle, for its light.
    func noteSpeakerMove(_ cycle: Int) {
        lampEvents.append(LampEvent(index: lampIndex(cycle), channel: -1, was: 0, now: 0))
    }

    /// Tells the lights of the samples up to `end` (as `storeSample` counts them), as they are handed out.
    func hearLamps(to end: Int) {
        while lampsTold < lampEvents.count, lampEvents[lampsTold].index < end {
            let event = lampEvents[lampsTold]
            lampsTold += 1
            let c = event.channel
            guard c >= 0 else {
                speakerMoves += 1
                continue
            }
            // What the channel was until now, and whether its volume jumped up.
            if event.was & 0x10 != 0 {
                noteHeld(c, event.was & 0xF)
            } else {
                reach[c] = max(reach[c], event.was & 0xF)
            }
            if event.now & 0xF > event.was & 0xF { struck[c] = true }
            heardAudc[c] = event.now
        }
    }

    /// How often the console's loudspeaker has moved in the samples handed out since this was last asked.
    func takeSpeakerMoves() -> Int {
        defer { speakerMoves = 0 }
        return speakerMoves
    }

    /// How loud each channel has been since this was last asked, out of 1. A channel playing a tone
    /// swings between nothing and its volume; one held at a level (`isSampled`) swings only as far as
    /// the levels it is held at have gone, so that one held still, which is not heard, is dark, as
    /// the AY's channels are.
    func takeLevels(into levels: UnsafeMutablePointer<Float>) {
        for c in 0 ..< 4 {
            let volume = heardAudc[c] & 0xF
            if heardAudc[c] & 0x10 != 0 {
                noteHeld(c, volume)
            } else if channels[c].mute & ~POKEYChannel.muteUser == 0 {
                reach[c] = max(reach[c], volume)
            }
            levels[c] = Float(max(reach[c], heldHigh[c] - heldLow[c])) / 15
            reach[c] = 0
            heldLow[c] = 16
            heldHigh[c] = -1
        }
    }

    /// Whether each channel's volume has jumped up since this was last asked.
    func takeStruck(into struck: UnsafeMutablePointer<Bool>) {
        for c in 0 ..< 4 {
            struck[c] = self.struck[c]
            self.struck[c] = false
        }
    }

    /// True for a channel held at its level, so that what is written to it is heard as a sample.
    func isSampled(_ c: Int) -> Bool {
        heardAudc[c] & 0x10 != 0
    }

    /// The pitch a channel is playing, in Hz, for one of the distortions that is heard as a note:
    /// the plain square wave, and the buzz of the 4-bit register alone, which repeats every 15 of
    /// the channel's counts. Nought for a channel that is silent, held, or noise, or is the lower
    /// half of a pair joined into one of sixteen bits.
    func pitch(of c: Int, clock: Double) -> Double {
        let audc = heardAudc[c]
        guard audc & 0xF != 0, audc & 0x10 == 0, channels[c].mute & ~POKEYChannel.muteUser == 0 else { return 0 }
        if c == 0, audctl & 0x10 != 0 { return 0 }
        if c == 2, audctl & 0x08 != 0 { return 0 }
        let period = Double(channels[c].periodCycles)
        switch audc & 0xE0 {
        case 0xA0, 0xE0: return clock / (2 * period)
        case 0xC0: return clock / (15 * period)
        default: return 0
        }
    }
}

/// One POKEY, or two for a tune written for a stereo upgrade, one heard on each side; and the
/// tables the chips share.
final class POKEYPair {
    let base: POKEY
    let extra: POKEY
    private var extraMask = 0

    static let sampleFactorShift = 18
    private(set) var sampleFactor = 0
    private(set) var sampleOffset = 0
    var readySamplesStart = 0
    private(set) var readySamplesEnd = 0
    var stereo: Bool { extraMask != 0 }
    /// Where each voice's sound is kept for its scope, once asked: the samples each chip has made of
    /// its voices are kept there as they are handed out.
    var waves: ChannelWaves?

    static let poly9Lookup: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 511)
        var reg = 0x1FF
        for i in 0 ..< 511 {
            reg = (((reg >> 5 ^ reg) & 1) << 8) + (reg >> 1)
            table[i] = UInt8(reg & 0xFF)
        }
        return table
    }()

    static let poly17Lookup: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 16385)
        var reg = 0x1FFFF
        for i in 0 ..< 16385 {
            reg = (((reg >> 5 ^ reg) & 0xFF) << 9) + (reg >> 8)
            table[i] = UInt8(reg >> 1 & 0xFF)
        }
        return table
    }()

    /// A step, band-limited, at each of 1,024 places between one sample and the next.
    nonisolated(unsafe) static let sincLookup: UnsafeBufferPointer<Int16> = {
        let length = POKEY.unitDeltaLength
        let phases = 1 << POKEY.interpolationShift
        let table = UnsafeMutableBufferPointer<Int16>.allocate(capacity: phases * length)
        for i in 0 ..< phases {
            var sincSum = 0.0, leftSum = 0.0, norm = 0.0
            var sinc = [Double](repeating: 0, count: length - 1)
            for j in -length ..< length {
                if j == -length / 2 {
                    leftSum = sincSum
                } else if j == length / 2 - 1 {
                    norm = sincSum
                }
                let x = Double.pi / Double(phases) * Double((j << POKEY.interpolationShift) - i)
                let s = x == 0 ? 1 : sin(x) / x
                if j >= -length / 2, j < length / 2 - 1 { sinc[length / 2 + j] = s }
                sincSum += s
            }
            norm = Double(1 << POKEY.deltaResolution) / (norm + (1 - sincSum) * 0.5)
            table[i * length] = Int16(((leftSum + (1 - sincSum) * 0.5) * norm).rounded())
            for j in 1 ..< length { table[i * length + j] = Int16((sinc[j - 1] * norm).rounded()) }
        }
        return UnsafeBufferPointer(table)
    }()

    init(sampleRate: Int) {
        base = POKEY(sampleRate: sampleRate)
        extra = POKEY(sampleRate: sampleRate)
    }

    private func sampleFactor(clock: Int, sampleRate: Int) -> Int {
        ((sampleRate << (Self.sampleFactorShift - 5)) + (clock >> 6)) / (clock >> 5)
    }

    func initialize(ntsc: Bool, stereo: Bool, sampleRate: Int) {
        extraMask = stereo ? 0x10 : 0
        base.initialize(sampleRate: sampleRate)
        extra.initialize(sampleRate: sampleRate)
        sampleFactor = sampleFactor(clock: ntsc ? 1_789_772 : 1_773_447, sampleRate: sampleRate)
        sampleOffset = 0
        readySamplesStart = 0
        readySamplesEnd = 0
        share()
    }

    private func share() {
        base.sampleFactor = sampleFactor
        base.sampleOffset = sampleOffset
        extra.sampleFactor = sampleFactor
        extra.sampleOffset = sampleOffset
    }

    func poke(_ addr: Int, _ data: Int, _ cycle: Int) -> Int {
        (addr & extraMask != 0 ? extra : base).poke(addr, data, cycle)
    }

    func peek(_ addr: Int, _ cycle: Int) -> Int {
        let pokey = addr & extraMask != 0 ? extra : base
        switch addr & 0xF {
        case 0x0A:
            if pokey.initMode { return 0xFF }
            var i = cycle + pokey.polyIndex
            if pokey.audctl & 0x80 != 0 { return Int(Self.poly9Lookup[i % 511]) }
            i %= 131071
            let j = i >> 3
            i &= 7
            return (Int(Self.poly17Lookup[j]) >> i + Int(Self.poly17Lookup[j + 1]) << (8 - i)) & 0xFF
        case 0x0E:
            return pokey.irqst
        default:
            return 0xFF
        }
    }

    func startFrame() {
        base.startFrame()
        if stereo { extra.startFrame() }
    }

    func endFrame(_ cycle: Int) {
        base.endFrame(cycle)
        if stereo { extra.endFrame(cycle) }
        sampleOffset += cycle * sampleFactor
        readySamplesStart = 0
        readySamplesEnd = sampleOffset >> Self.sampleFactorShift
        sampleOffset &= (1 << Self.sampleFactorShift) - 1
        share()
    }

    /// Writes up to `blocks` of the samples made, one for each chip, into `buffer`; returns how
    /// many it wrote.
    func generate(into buffer: UnsafeMutablePointer<Int16>, blocks: Int) -> Int {
        var i = readySamplesStart
        var samplesEnd = readySamplesEnd
        var blocks = blocks
        if blocks < samplesEnd - i {
            samplesEnd = i + blocks
        } else {
            blocks = samplesEnd - i
        }
        guard blocks > 0 else { return max(0, blocks) }
        var out = buffer
        while i < samplesEnd {
            out.pointee = base.storeSample(i)
            out += 1
            if stereo {
                out.pointee = extra.storeSample(i)
                out += 1
            }
            i += 1
        }
        if let waves {
            base.keepVoices(from: readySamplesStart, to: i, in: waves, first: 0, speaker: stereo ? 8 : 4)
            if stereo { extra.keepVoices(from: readySamplesStart, to: i, in: waves, first: 4, speaker: nil) }
            waves.advance(by: i - readySamplesStart)
        }
        base.hearLamps(to: i)
        if stereo { extra.hearLamps(to: i) }
        if i == readySamplesEnd {
            base.accumulateTrailing(i)
            extra.accumulateTrailing(i)
        }
        readySamplesStart = i
        return blocks
    }

    var isSilent: Bool { base.isSilent && extra.isSilent }
}
