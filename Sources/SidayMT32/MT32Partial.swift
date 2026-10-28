// Copyright (C) 2003-2009 Dean Beeler, Jerome Fisher; (C) 2011-2024 Dean Beeler, Jerome Fisher, Sergey V. Mikayev
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Swift port of mt32emu's partials, the notes they make up, and their sharing out (Partial.cpp, Poly.cpp
// and PartialManager.cpp of Munt's libmt32emu 2.8.3), free software under the GNU Lesser General Public
// License, version 2.1 or any later version (see THIRD-PARTY.md).

/// What a part works out of a timbre for each of its four partials, kept until the timbre changes: a
/// note's partials point to it, and are given a copy of their own if it changes while they sound.
struct MT32PatchCache {
    var playPartial = false
    var pcmPartial = false
    var pcm = 0
    var waveform: UInt8 = 0
    var structureMix = 0
    var structurePosition = 0
    var structurePair = 0
    var dirty = false
    var partialCount = 0
    var sustain = false
    var reverb = false
    // The few of the partial's settings that are read as they were when the timbre was cached.
    var pulseWidth: UInt8 = 0
    var pulseWidthVeloSensitivity: UInt8 = 0
    var resonance: UInt8 = 0
    /// The partial's settings, where they are kept (and may be changed while it sounds).
    var partialParam = PartialParams(UnsafePointer(bitPattern: 1)!)
}

/// One of the 32 partials of the LA32: a wave and its amplifier, filter and pitch, playing one of a note's
/// (up to four) partials, alone or with its pair.
final class MT32Partial {
    private static let panNumeratorMaster: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7]
    private static let panNumeratorSlave: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 7, 7, 7, 7, 7, 7, 7]

    unowned(unsafe) let synth: MT32Synth
    let partialIndex: Int
    private var leftPanValue: Int32 = 0, rightPanValue: Int32 = 0
    /// The part playing it, or -1.
    private(set) var ownerPart = -1
    private var mixType = 0
    private var structurePosition = 0
    private(set) var pcmWave: MT32PCMWave?
    private var pulseWidthVal = 0
    private(set) var poly: MT32Poly?
    private unowned(unsafe) var pair: MT32Partial?
    private(set) var tva: MT32TVA!
    private var tvp: MT32TVP!
    private var tvf: MT32TVF!
    var ampRamp = LA32Ramp()
    var cutoffModifierRamp = LA32Ramp()
    /// The LA32's pair this partial plays as the first of (its second may be this one's pair).
    private var la32Pair = LA32PartialPair()
    /// The cache it plays from: the part's, or its own copy (`cacheBackup`).
    private var patchCache: UnsafeMutablePointer<MT32PatchCache>
    private let cacheBackup: UnsafeMutablePointer<MT32PatchCache>
    var alreadyOutputed = false

    init(synth: MT32Synth, index: Int) {
        self.synth = synth
        partialIndex = index
        cacheBackup = .allocate(capacity: 1)
        cacheBackup.initialize(to: MT32PatchCache())
        patchCache = cacheBackup
        tva = MT32TVA(self)
        tvp = MT32TVP(self)
        tvf = MT32TVF(self)
    }

    deinit {
        cacheBackup.deinitialize(count: 1)
        cacheBackup.deallocate()
    }

    var isActive: Bool { ownerPart > -1 }

    func activate(_ part: Int) { ownerPart = part }

    func deactivate() {
        if !isActive { return }
        ownerPart = -1
        synth.partialManager.partialDeactivated(partialIndex)
        poly?.partialDeactivated(self)
        if isRingModulatingSlave {
            pair!.la32Pair.slave.deactivate()
        } else {
            la32Pair.master.deactivate()
            if hasRingModulatingSlave {
                pair!.deactivate()
                pair = nil
            }
        }
        if let pair { pair.pair = nil }
    }

    func startPartial(part: MT32Part, poly usePoly: MT32Poly, cache: UnsafeMutablePointer<MT32PatchCache>, rhythmTemp: UnsafeMutablePointer<UInt8>?, pair pairPartial: MT32Partial?) {
        patchCache = cache
        poly = usePoly
        mixType = cache.pointee.structureMix
        structurePosition = cache.pointee.structurePosition
        var pairPartial = pairPartial
        var panSetting = rhythmTemp?[MT32Memory.rhythmPanpot] ?? part.patchTemp[MT32Memory.panpot]
        if mixType == 3 {
            panSetting = (structurePosition == 0 ? Self.panNumeratorMaster : Self.panNumeratorSlave)[Int(panSetting)] << 1
            // Mixed as two partials apart.
            mixType = 0
            pairPartial = nil
        } else if !synth.nicePanning {
            // (The LA32 is sent the pan with its lowest bit cleared.)
            panSetting &= 0x0E
        }
        leftPanValue = synth.reversedStereo ? 14 - Int32(panSetting) : Int32(panSetting)
        rightPanValue = 14 - leftPanValue
        leftPanValue = MT32Tables.panFactors[Int(leftPanValue)]
        rightPanValue = MT32Tables.panFactors[Int(rightPanValue)]
        // The partials of the four quarters of the 32 are mixed alternately added and taken away, as the
        // LA32 does (which makes a timbre of near-identical partials sound different note to note).
        if !synth.nicePartialMixing, partialIndex & 4 != 0 {
            leftPanValue = -leftPanValue
            rightPanValue = -rightPanValue
        }
        if cache.pointee.pcmPartial {
            var pcmNum = cache.pointee.pcm
            // The CM-32L's kind has two banks of PCM sounds, chosen by the waveform setting.
            if synth.controlROMMap.pcmCount > 128, cache.pointee.waveform > 1 { pcmNum += 128 }
            pcmWave = synth.pcmWaves[pcmNum]
        } else {
            pcmWave = nil
        }
        pulseWidthVal = (usePoly.velocity - 64) * (Int(cache.pointee.pulseWidthVeloSensitivity) - 7) + Int(MT32Tables.pulseWidth100To255[Int(cache.pointee.pulseWidth)])
        pulseWidthVal = max(0, min(255, pulseWidthVal))
        pair = pairPartial
        alreadyOutputed = false
        tva.reset(part: part, params: cache.pointee.partialParam, rhythmTemp: rhythmTemp)
        tvp.reset(part: part, params: cache.pointee.partialParam)
        tvf.reset(params: cache.pointee.partialParam, basePitch: tvp.basePitch)
        let asSlave = isRingModulatingSlave
        if !asSlave { la32Pair.initialise(ringModulated: hasRingModulatingSlave, mixed: mixType == 1) }
        if let pcmWave {
            let address = synth.pcmROMData + Int(pcmWave.address)
            if asSlave {
                pair!.la32Pair.initPCM(slave: true, address: address, length: pcmWave.length, looped: pcmWave.loop)
            } else {
                la32Pair.initPCM(slave: false, address: address, length: pcmWave.length, looped: pcmWave.loop)
            }
        } else {
            let sawtooth = cache.pointee.waveform & 1 != 0
            let resonance = cache.pointee.resonance &+ 1
            if asSlave {
                pair!.la32Pair.initSynth(slave: true, sawtooth: sawtooth, pulseWidth: UInt8(pulseWidthVal), resonance: resonance)
            } else {
                la32Pair.initSynth(slave: false, sawtooth: sawtooth, pulseWidth: UInt8(pulseWidthVal), resonance: resonance)
            }
        }
        if !hasRingModulatingSlave { la32Pair.slave.deactivate() }
    }

    @inline(__always)
    private func ampValue() -> UInt32 {
        let value = 67_117_056 &- ampRamp.nextValue()
        if ampRamp.checkInterrupt() { tva.handleInterrupt() }
        return value
    }

    @inline(__always)
    private func cutoffValue() -> UInt32 {
        if pcmWave != nil { return 0 }
        let value = cutoffModifierRamp.nextValue()
        if cutoffModifierRamp.checkInterrupt() { tvf.handleInterrupt() }
        return (UInt32(tvf.baseCutoff) << 18) &+ value
    }

    var hasRingModulatingSlave: Bool { pair != nil && structurePosition == 0 && (mixType == 1 || mixType == 2) }
    var isRingModulatingSlave: Bool { pair != nil && structurePosition == 1 && (mixType == 1 || mixType == 2) }
    var isRingModulatingNoMix: Bool { pair != nil && ((structurePosition == 1 && mixType == 1) || mixType == 2) }

    /// Called by a part about to change the cache this partial plays from: it keeps a copy of its own.
    func backupCache(_ cache: UnsafeMutablePointer<MT32PatchCache>) {
        if patchCache == cache {
            cacheBackup.pointee = cache.pointee
            patchCache = cacheBackup
        }
    }

    private var canProduceOutput: Bool {
        if !isActive || alreadyOutputed || isRingModulatingSlave { return false }
        return poly != nil
    }

    @inline(__always)
    private func generateNextSample() -> Bool {
        if !tva.playing || !la32Pair.master.active {
            deactivate()
            return false
        }
        la32Pair.master.generateNextSample(amp: ampValue(), pitch: tvp.nextPitch(), cutoff: cutoffValue())
        if hasRingModulatingSlave {
            let pair = pair!
            la32Pair.slave.generateNextSample(amp: pair.ampValue(), pitch: pair.tvp.nextPitch(), cutoff: pair.cutoffValue())
            if !pair.tva.playing || !la32Pair.slave.active {
                pair.deactivate()
                if mixType == 2 {
                    deactivate()
                    return false
                }
            }
        }
        return true
    }

    /// Adds this partial's next `length` samples, panned, to the two channels. False if it made none.
    /// Its sound before it is panned is added to `tap`, if there is one, and the largest of it kept in
    /// `peak`: what its part sounds like, and how loud.
    @discardableResult
    func produceOutput(left: UnsafeMutablePointer<Int16>, right: UnsafeMutablePointer<Int16>, length: Int,
                       tap: UnsafeMutablePointer<Int32>?, peak: UnsafeMutablePointer<Int32>) -> Bool {
        if !canProduceOutput { return false }
        alreadyOutputed = true
        for i in 0 ..< length {
            if !generateNextSample() { break }
            let sample = Int32(la32Pair.nextOutSample())
            if let tap { tap[i] &+= sample }
            let size = sample < 0 ? -sample : sample
            if size > peak.pointee { peak.pointee = size }
            // (mt32emu notes that the LA32 makes the right channel by taking the left from the whole, which can
            // overflow; it is not modelled, as it is not known to be heard.)
            let leftOut = ((sample &* leftPanValue) >> 13) &+ Int32(left[i])
            let rightOut = ((sample &* rightPanValue) >> 13) &+ Int32(right[i])
            left[i] = MT32Synth.clip(leftOut)
            right[i] = MT32Synth.clip(rightOut)
        }
        return true
    }

    var shouldReverb: Bool { isActive && patchCache.pointee.reverb }

    func startAbort() { tva.startAbort() }

    func startDecayAll() {
        tva.startDecay()
        tvp.startDecay()
        tvf.startDecay()
    }
}

/// A note being played: the partials of its timbre, and the state it is in.
final class MT32Poly {
    enum State { case playing, held, releasing, inactive }

    unowned(unsafe) var part: MT32Part?
    private(set) var key = 255
    private(set) var velocity = 255
    private(set) var activePartialCount = 0
    private(set) var canSustain = false
    private(set) var state = State.inactive
    private var partials: [MT32Partial?] = [nil, nil, nil, nil]
    var next: MT32Poly?

    var isActive: Bool { state != .inactive }

    func reset(key: Int, velocity: Int, sustain: Bool, partials newPartials: [MT32Partial?]) {
        if isActive {
            // (Never so, but as mt32emu.)
            for i in 0 ..< 4 where partials[i]?.isActive == true {
                partials[i]!.deactivate()
                activePartialCount -= 1
            }
            setState(.inactive)
        }
        self.key = key
        self.velocity = velocity
        canSustain = sustain
        activePartialCount = 0
        for i in 0 ..< 4 {
            partials[i] = newPartials[i]
            if newPartials[i] != nil {
                activePartialCount += 1
                setState(.playing)
            }
        }
    }

    @discardableResult
    func noteOff(pedalHeld: Bool) -> Bool {
        if state == .inactive || state == .releasing { return false }
        if pedalHeld {
            if state == .held { return false }
            setState(.held)
        } else {
            startDecay()
        }
        return true
    }

    @discardableResult
    func stopPedalHold() -> Bool {
        if state != .held { return false }
        return startDecay()
    }

    @discardableResult
    func startDecay() -> Bool {
        if state == .inactive || state == .releasing { return false }
        setState(.releasing)
        for partial in partials { partial?.startDecayAll() }
        return true
    }

    func startAbort() -> Bool {
        guard let part, state != .inactive, part.synth.abortingPoly == nil else { return false }
        for partial in partials {
            if let partial {
                partial.startAbort()
                part.synth.abortingPoly = self
            }
        }
        return true
    }

    private func setState(_ newState: State) {
        if state == newState { return }
        let oldState = state
        state = newState
        part?.polyStateChanged(oldState, newState)
    }

    func backupCacheToPartials(_ cache: UnsafeMutablePointer<MT32PatchCache>) {
        for i in 0 ..< 4 { partials[i]?.backupCache(cache + i) }
    }

    /// Told by a partial that it has stopped.
    func partialDeactivated(_ partial: MT32Partial) {
        for i in 0 ..< 4 where partials[i] === partial {
            partials[i] = nil
            activePartialCount -= 1
        }
        if activePartialCount == 0 {
            setState(.inactive)
            if part?.synth.abortingPoly === self { part?.synth.abortingPoly = nil }
        }
        part?.partialDeactivated(self)
    }
}

/// The sharing of the 32 partials among the nine parts, by each part's reserve and priority, as the
/// LAPC-I's and the MT-32's controllers share them.
final class MT32PartialManager {
    private unowned(unsafe) let synth: MT32Synth
    private var freePolys: [MT32Poly?]
    private(set) var partials: [MT32Partial]
    private var numReservedPartialsForPart = [Int](repeating: 0, count: 9)
    private var firstFreePolyIndex = 0
    private var inactivePartials: [Int]
    private var inactivePartialCount: Int

    init(synth: MT32Synth, count: Int) {
        self.synth = synth
        inactivePartialCount = count
        partials = []
        inactivePartials = []
        freePolys = []
        for i in 0 ..< count {
            partials.append(MT32Partial(synth: synth, index: i))
            inactivePartials.append(count - i - 1)
            freePolys.append(MT32Poly())
        }
    }

    private var parts: [MT32Part] { synth.parts }

    func clearAlreadyOutputed() {
        for partial in partials { partial.alreadyOutputed = false }
    }

    func deactivateAll() {
        for partial in partials { partial.deactivate() }
    }

    func setReserve(_ reserve: UnsafePointer<UInt8>) {
        for x in 0 ... 8 { numReservedPartialsForPart[x] = Int(reserve[x]) }
    }

    func allocPartial(_ partNum: Int) -> MT32Partial? {
        guard inactivePartialCount > 0 else { return nil }
        inactivePartialCount -= 1
        let partial = partials[inactivePartials[inactivePartialCount]]
        partial.activate(partNum)
        return partial
    }

    var freePartialCount: Int { inactivePartialCount }

    private func abortFirstReleasingPolyWhereReserveExceeded(_ minPart: Int) -> Bool {
        let minPart = minPart == 8 ? -1 : minPart
        var partNum = 7
        while partNum >= minPart {
            let usePartNum = partNum == -1 ? 8 : partNum
            if parts[usePartNum].activePartialCount > numReservedPartialsForPart[usePartNum], parts[usePartNum].abortFirstPoly(state: .releasing) {
                return true
            }
            partNum -= 1
        }
        return false
    }

    private func abortFirstPolyPreferHeldWhereReserveExceeded(_ minPart: Int) -> Bool {
        let minPart = minPart == 8 ? -1 : minPart
        var partNum = 7
        while partNum >= minPart {
            let usePartNum = partNum == -1 ? 8 : partNum
            if parts[usePartNum].activePartialCount > numReservedPartialsForPart[usePartNum], parts[usePartNum].abortFirstPolyPreferHeld() {
                return true
            }
            partNum -= 1
        }
        return false
    }

    private func abortFirstPolyPreferReleasingThenHeldWhereReserveExceeded(_ minPartNum: Int) -> Bool {
        var candidate = 7
        while candidate >= minPartNum {
            if parts[candidate].activePartialCount > numReservedPartialsForPart[candidate] {
                return abortFirstPolyOnPartPreferReleasingThenHeld(candidate)
            }
            candidate -= 1
        }
        return false
    }

    @discardableResult
    private func abortFirstPolyOnPartPreferReleasingThenHeld(_ partNum: Int) -> Bool {
        if parts[partNum].abortFirstPoly(state: .releasing) { return true }
        return parts[partNum].abortFirstPolyPreferHeld()
    }

    /// Frees enough partials for a note of a part, by stopping others as the controller would; false if
    /// the note is not to be played.
    func freePartials(_ needed: Int, _ partNum: Int) -> Bool {
        if synth.features.newGenNoteCancellation { return freePartialsNewGen(needed, partNum) }
        while synth.abortingPoly == nil, freePartialCount < needed {
            if parts[partNum].activeNonReleasingPartialCount + needed > numReservedPartialsForPart[partNum] {
                if parts[partNum].patchTemp[MT32Memory.assignMode] & 1 != 0 { return false }
                if needed <= numReservedPartialsForPart[partNum] {
                    abortFirstPolyOnPartPreferReleasingThenHeld(partNum)
                    continue
                }
                if abortFirstPolyPreferReleasingThenHeldWhereReserveExceeded(partNum < 8 ? partNum : 0) { continue }
                if parts[8].activePartialCount > numReservedPartialsForPart[8], abortFirstPolyOnPartPreferReleasingThenHeld(8) { continue }
                return false
            }
            if abortFirstPolyPreferReleasingThenHeldWhereReserveExceeded(0) { continue }
            if parts[8].activePartialCount > numReservedPartialsForPart[8], abortFirstPolyOnPartPreferReleasingThenHeld(8) { continue }
            if abortFirstPolyOnPartPreferReleasingThenHeld(partNum) { continue }
            return false
        }
        return true
    }

    /// As the LAPC-I's controller does it (with its own bug kept: the rhythm part's held and playing notes
    /// may be stopped before its releasing ones).
    private func freePartialsNewGen(_ needed: Int, _ partNum: Int) -> Bool {
        if needed == 0 { return true }
        if freePartialCount >= needed { return true }
        while true {
            if !abortFirstReleasingPolyWhereReserveExceeded(0) { break }
            if synth.abortingPoly != nil || freePartialCount >= needed { return true }
        }
        if parts[partNum].activeNonReleasingPartialCount + needed > numReservedPartialsForPart[partNum] {
            if parts[partNum].patchTemp[MT32Memory.assignMode] & 1 != 0 { return false }
            while true {
                if !abortFirstPolyPreferHeldWhereReserveExceeded(partNum) { break }
                if synth.abortingPoly != nil || freePartialCount >= needed { return true }
            }
            if needed > numReservedPartialsForPart[partNum] { return false }
        } else {
            while true {
                if !abortFirstPolyPreferHeldWhereReserveExceeded(-1) { break }
                if synth.abortingPoly != nil || freePartialCount >= needed { return true }
            }
        }
        while true {
            if !parts[partNum].abortFirstPolyPreferHeld() { break }
            if synth.abortingPoly != nil || freePartialCount >= needed { return true }
        }
        return false
    }

    func assignPolyToPart(_ part: MT32Part) -> MT32Poly? {
        guard firstFreePolyIndex < partials.count, let poly = freePolys[firstFreePolyIndex] else { return nil }
        freePolys[firstFreePolyIndex] = nil
        firstFreePolyIndex += 1
        poly.part = part
        return poly
    }

    func polyFreed(_ poly: MT32Poly) {
        if firstFreePolyIndex > 0 {
            firstFreePolyIndex -= 1
            freePolys[firstFreePolyIndex] = poly
        }
        poly.part = nil
    }

    func partialDeactivated(_ index: Int) {
        if inactivePartialCount < partials.count {
            inactivePartials[inactivePartialCount] = index
            inactivePartialCount += 1
        }
    }
}
