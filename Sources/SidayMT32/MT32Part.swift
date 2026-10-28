// Copyright (C) 2003-2009 Dean Beeler, Jerome Fisher; (C) 2011-2024 Dean Beeler, Jerome Fisher, Sergey V. Mikayev
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Swift port of mt32emu's parts (Part.cpp of Munt's libmt32emu 2.8.3), free software under the GNU Lesser
// General Public License, version 2.1 or any later version (see THIRD-PARTY.md).

/// One of the synthesiser's nine parts: eight that each play a timbre, and the rhythm part, which plays a
/// timbre of its own for each key. A part takes the messages of the MIDI channel it is set to.
class MT32Part {
    /// Which of the timbre's partial structures (0 to 12) make PCM partials: the first of a pair's by bit 1,
    /// the second's by bit 0.
    static let partialStruct: [UInt8] = [0, 0, 2, 2, 1, 3, 3, 0, 3, 0, 2, 1, 3]
    /// How each structure mixes its pair: 0 apart, 1 ring-modulated with the first's own sound, 2
    /// ring-modulated alone, 3 apart and panned apart.
    static let partialMixStruct: [Int] = [0, 1, 0, 1, 1, 0, 1, 3, 3, 2, 2, 2, 2]

    unowned(unsafe) let synth: MT32Synth
    let partNum: Int
    /// The part's timbre as it is played, in the synthesiser's memory (nil for the rhythm part).
    let timbreTemp: UnsafeMutablePointer<UInt8>?
    /// The part's patch as it is played, in the synthesiser's memory.
    let patchTemp: UnsafeMutablePointer<UInt8>
    private var holdPedal = false
    private(set) var activePartialCount = 0
    private var activeNonReleasingPolyCount = 0
    let patchCache: UnsafeMutablePointer<MT32PatchCache>
    private var activePolys = MT32PolyList()
    /// A level of 0 to 100 that overrides the part's, or above that none.
    var volumeOverride: UInt8 = 255
    private(set) var modulation: UInt8 = 0
    private(set) var expression: UInt8 = 100
    private(set) var pitchBend: Int32 = 0
    private var nrpn = false
    private var rpn: UInt16 = 0
    /// The patch's bender range by 683, as it was at the last program change or data entry.
    private var pitchBenderRange: Int32 = 0

    init(synth: MT32Synth, partNum: Int) {
        self.synth = synth
        self.partNum = partNum
        patchTemp = synth.memory.patchTempAddress(partNum)
        timbreTemp = partNum == 8 ? nil : synth.memory.timbreTempAddress(partNum)
        patchCache = .allocate(capacity: 4)
        patchCache.initialize(repeating: MT32PatchCache(), count: 4)
        // (As mt32emu: the cache is marked to be made, then all of it set to nought.)
        patchCache[0].dirty = false
    }

    deinit {
        patchCache.deinitialize(count: 4)
        patchCache.deallocate()
    }

    func setDataEntryMSB(_ value: UInt8) {
        // Only RPN 0, the bender range, is taken; never an NRPN.
        if nrpn || rpn != 0 { return }
        patchTemp[MT32Memory.benderRange] = value > 24 ? 24 : value
        updatePitchBenderRange()
    }

    func setNRPN() { nrpn = true }

    func setRPNLSB(_ value: UInt8) {
        nrpn = false
        rpn = (rpn & 0xFF00) | UInt16(value)
    }

    func setRPNMSB(_ value: UInt8) {
        nrpn = false
        rpn = (rpn & 0x00FF) | UInt16(value) << 8
    }

    func setHoldPedal(_ pressed: Bool) {
        if holdPedal, !pressed {
            holdPedal = false
            stopPedalHold()
        } else {
            holdPedal = pressed
        }
    }

    func setBend(_ midiBend: Int) {
        pitchBend = Int32(((midiBend - 8192) * Int(pitchBenderRange)) >> 14)
    }

    func setModulation(_ value: UInt8) { modulation = value }

    func resetAllControllers() {
        modulation = 0
        expression = 100
        pitchBend = 0
        setHoldPedal(false)
    }

    func reset() {
        resetAllControllers()
        allSoundOff()
        rpn = 0xFFFF
    }

    func refresh() {
        backupCacheToPartials(patchCache)
        for t in 0 ..< 4 {
            patchCache[t].dirty = true
            patchCache[t].reverb = patchTemp[MT32Memory.reverbSwitch] > 0
        }
        updatePitchBenderRange()
    }

    func refreshTimbre(_ absTimbreNum: Int) {
        if absTimbreNum == self.absTimbreNum { patchCache[0].dirty = true }
    }

    func resetTimbre() {
        holdPedal = false
        allSoundOff()
        timbreTemp!.update(from: synth.memory.timbreAddress(absTimbreNum), count: MT32Memory.timbreSize)
    }

    var absTimbreNum: Int { Int(patchTemp[MT32Memory.timbreGroup]) * 64 + Int(patchTemp[MT32Memory.timbreNum]) }

    func setProgram(_ patchNum: Int) {
        patchTemp.update(from: synth.memory.patchAddress(patchNum), count: MT32Memory.patchSize)
        resetTimbre()
        refresh()
    }

    func updatePitchBenderRange() { pitchBenderRange = Int32(patchTemp[MT32Memory.benderRange]) * 683 }

    func backupCacheToPartials(_ cache: UnsafeMutablePointer<MT32PatchCache>) {
        var poly = activePolys.first
        while let current = poly {
            current.backupCacheToPartials(cache)
            poly = current.next
        }
    }

    func cacheTimbre(_ cache: UnsafeMutablePointer<MT32PatchCache>, _ timbre: UnsafeMutablePointer<UInt8>) {
        backupCacheToPartials(cache)
        var partialCount = 0
        let mute = timbre[MT32Memory.partialMute]
        let structure12 = Int(timbre[MT32Memory.partialStructure12]), structure34 = Int(timbre[MT32Memory.partialStructure34])
        for t in 0 ..< 4 {
            if (mute >> UInt8(t)) & 1 == 1 {
                cache[t].playPartial = true
                partialCount += 1
            } else {
                cache[t].playPartial = false
                continue
            }
            let params = timbre + MT32Memory.timbreCommonSize + t * MT32Memory.partialParamSize
            cache[t].pulseWidth = params[6]
            cache[t].pulseWidthVeloSensitivity = params[7]
            cache[t].resonance = params[24]
            cache[t].pcm = Int(params[5])
            let structure = t < 2 ? structure12 : structure34
            cache[t].pcmPartial = Self.partialStruct[structure] & (t & 1 == 0 ? 2 : 1) != 0
            cache[t].structureMix = Self.partialMixStruct[structure]
            cache[t].structurePosition = t & 1
            cache[t].structurePair = t ^ 1
            cache[t].partialParam = PartialParams(params)
            cache[t].waveform = params[4]
        }
        for t in 0 ..< 4 {
            cache[t].dirty = false
            cache[t].partialCount = partialCount
            cache[t].sustain = timbre[MT32Memory.noSustain] == 0
        }
    }

    func setVolume(_ midiVolume: Int) {
        patchTemp[MT32Memory.outputLevel] = UInt8(midiVolume * 100 / 127)
    }

    /// The part's level, 0 to 100.
    var volume: UInt8 { volumeOverride <= 100 ? volumeOverride : patchTemp[MT32Memory.outputLevel] }

    func setVolumeOverride(_ value: UInt8) {
        volumeOverride = value
        // Nought stops the part altogether.
        if value == 0 { allSoundOff() }
    }

    func setExpression(_ midiExpression: Int) { expression = UInt8(midiExpression * 100 / 127) }

    func setPan(_ midiPan: Int) {
        // (The other way round from General MIDI's.)
        if synth.features.quirkPanMult {
            patchTemp[MT32Memory.panpot] = UInt8(midiPan / 9)
        } else {
            patchTemp[MT32Memory.panpot] = UInt8((midiPan << 3) / 68)
        }
    }

    /// A MIDI key with the patch's key shift, as a key of 36 to 132 less 24.
    private func midiKeyToKey(_ midiKey: Int) -> Int {
        if synth.features.quirkKeyShift { return midiKey }
        var key = midiKey + Int(patchTemp[MT32Memory.keyShift])
        if key < 36 {
            while key < 36 { key += 12 }
        } else if key > 132 {
            while key > 132 { key -= 12 }
        }
        return key - 24
    }

    func noteOn(_ midiKey: Int, _ velocity: Int) {
        let key = midiKeyToKey(midiKey)
        if patchCache[0].dirty { cacheTimbre(patchCache, timbreTemp!) }
        playPoly(patchCache, nil, midiKey, key, velocity)
    }

    private func abortFirstPoly(key: Int) -> Bool {
        var poly = activePolys.first
        while let current = poly {
            if current.key == key { return current.startAbort() }
            poly = current.next
        }
        return false
    }

    func abortFirstPoly(state: MT32Poly.State) -> Bool {
        var poly = activePolys.first
        while let current = poly {
            if current.state == state { return current.startAbort() }
            poly = current.next
        }
        return false
    }

    func abortFirstPolyPreferHeld() -> Bool {
        if abortFirstPoly(state: .held) { return true }
        return abortFirstPoly()
    }

    func abortFirstPoly() -> Bool {
        guard let first = activePolys.first else { return false }
        return first.startAbort()
    }

    func playPoly(_ cache: UnsafeMutablePointer<MT32PatchCache>, _ rhythmTemp: UnsafeMutablePointer<UInt8>?, _ midiKey: Int, _ key: Int, _ velocity: Int) {
        // (A timbre with every partial muted plays nothing, and stops nothing either.)
        let needPartials = cache[0].partialCount
        if needPartials == 0 { return }
        if patchTemp[MT32Memory.assignMode] & 2 == 0 {
            // One note to a key.
            _ = abortFirstPoly(key: key)
            if synth.abortingPoly != nil { return }
        }
        if !synth.partialManager.freePartials(needPartials, partNum) { return }
        if synth.abortingPoly != nil { return }
        guard let poly = synth.partialManager.assignPolyToPart(self) else { return }
        if patchTemp[MT32Memory.assignMode] & 1 != 0 {
            // The notes first played are kept first.
            activePolys.prepend(poly)
        } else {
            activePolys.append(poly)
        }
        var partials: [MT32Partial?] = [nil, nil, nil, nil]
        for x in 0 ..< 4 where cache[x].playPartial {
            partials[x] = synth.partialManager.allocPartial(partNum)
            activePartialCount += 1
        }
        poly.reset(key: key, velocity: velocity, sustain: cache[0].sustain, partials: partials)
        synth.noteStarts |= 1 << UInt32(partNum)
        for x in 0 ..< 4 {
            partials[x]?.startPartial(part: self, poly: poly, cache: cache + x, rhythmTemp: rhythmTemp, pair: partials[cache[x].structurePair])
        }
    }

    func allNotesOff() {
        // As the MIDI specification has it, with the hold pedal as it is; notes that do not sustain are
        // passed over, as the real ones are found to do.
        var poly = activePolys.first
        while let current = poly {
            if current.canSustain { current.noteOff(pedalHeld: holdPedal) }
            poly = current.next
        }
    }

    func allSoundOff() {
        var poly = activePolys.first
        while let current = poly {
            current.startDecay()
            poly = current.next
        }
    }

    func stopPedalHold() {
        var poly = activePolys.first
        while let current = poly {
            current.stopPedalHold()
            poly = current.next
        }
    }

    func noteOff(_ midiKey: Int) { stopNote(midiKeyToKey(midiKey)) }

    func stopNote(_ key: Int) {
        var poly = activePolys.first
        while let current = poly {
            // A note that does not sustain takes no note off (it dies away by itself), but for key 0, a
            // special case of the rhythm part's.
            if current.key == key, current.canSustain || key == 0 {
                if current.noteOff(pedalHeld: holdPedal && key != 0) { break }
            }
            poly = current.next
        }
    }

    var firstActivePoly: MT32Poly? { activePolys.first }

    var activeNonReleasingPartialCount: Int {
        var count = 0
        var poly = activePolys.first
        while let current = poly {
            if current.state != .releasing { count += current.activePartialCount }
            poly = current.next
        }
        return count
    }

    func partialDeactivated(_ poly: MT32Poly) {
        activePartialCount -= 1
        if !poly.isActive {
            activePolys.remove(poly)
            synth.partialManager.polyFreed(poly)
        }
    }

    func polyStateChanged(_ oldState: MT32Poly.State, _ newState: MT32Poly.State) {
        switch newState {
        case .playing:
            activeNonReleasingPolyCount += 1
        case .releasing, .inactive:
            if oldState == .playing || oldState == .held { activeNonReleasingPolyCount -= 1 }
        default:
            break
        }
    }
}

/// The rhythm part: each key a timbre of its own, with its own level, pan and reverb.
final class MT32RhythmPart: MT32Part {
    private let drumCache: UnsafeMutablePointer<MT32PatchCache>

    override init(synth: MT32Synth, partNum: Int) {
        drumCache = .allocate(capacity: 85 * 4)
        drumCache.initialize(repeating: MT32PatchCache(), count: 85 * 4)
        super.init(synth: synth, partNum: partNum)
        refresh()
    }

    deinit {
        drumCache.deinitialize(count: 85 * 4)
        drumCache.deallocate()
    }

    override func refresh() {
        for drumNum in 0 ..< synth.controlROMMap.rhythmSettingsCount {
            let drumTimbreNum = synth.memory.rhythmTempAddress(drumNum)[MT32Memory.rhythmTimbre]
            if drumTimbreNum >= 127 { continue }
            let cache = drumCache + drumNum * 4
            backupCacheToPartials(cache)
            for t in 0 ..< 4 {
                cache[t].dirty = true
                cache[t].reverb = synth.memory.rhythmTempAddress(drumNum)[MT32Memory.rhythmReverbSwitch] > 0
            }
        }
        updatePitchBenderRange()
    }

    override func refreshTimbre(_ absTimbreNum: Int) {
        for m in 0 ..< 85 where Int(synth.memory.rhythmTempAddress(m)[MT32Memory.rhythmTimbre]) == absTimbreNum - 128 {
            drumCache[m * 4].dirty = true
        }
    }

    override func resetTimbre() {}

    override var absTimbreNum: Int { 0 }

    override func setProgram(_: Int) {}

    override func setPan(_ midiPan: Int) {
        // (Changes the memory, as the original does, but is not heard.)
        super.setPan(midiPan)
    }

    override func noteOn(_ midiKey: Int, _ velocity: Int) {
        if midiKey < 24 || midiKey > 108 { return }
        var key = midiKey
        let drumNum = key - 24
        let rhythmTemp = synth.memory.rhythmTempAddress(drumNum)
        let drumTimbreNum = Int(rhythmTemp[MT32Memory.rhythmTimbre])
        let drumTimbreCount = 64 + synth.controlROMMap.timbreRCount
        if drumTimbreNum == 127 || drumTimbreNum >= drumTimbreCount { return }
        // Two special cases.
        if drumTimbreNum == 64 + 6 {
            noteOff(0)
            key = 1
        } else if drumTimbreNum == 64 + 7 {
            noteOff(0)
            key = 0
        }
        let timbre = synth.memory.timbreAddress(drumTimbreNum + 128)
        let cache = drumCache + drumNum * 4
        if cache[0].dirty { cacheTimbre(cache, timbre) }
        playPoly(cache, rhythmTemp, midiKey, key, velocity)
    }

    override func noteOff(_ midiKey: Int) { stopNote(midiKey) }

    override func polyStateChanged(_: MT32Poly.State, _: MT32Poly.State) {}
}

/// A part's notes, first to last.
struct MT32PolyList {
    private(set) var first: MT32Poly?
    private var last: MT32Poly?

    mutating func prepend(_ poly: MT32Poly) {
        poly.next = first
        first = poly
        if last == nil { last = poly }
    }

    mutating func append(_ poly: MT32Poly) {
        poly.next = nil
        last?.next = poly
        last = poly
        if first == nil { first = poly }
    }

    @discardableResult
    mutating func takeFirst() -> MT32Poly? {
        guard let oldFirst = first else { return nil }
        first = oldFirst.next
        if first == nil { last = nil }
        oldFirst.next = nil
        return oldFirst
    }

    mutating func remove(_ poly: MT32Poly) {
        if poly === first {
            takeFirst()
            return
        }
        var current = first
        while let node = current {
            if node.next === poly {
                if poly === last { last = node }
                node.next = poly.next
                poly.next = nil
                break
            }
            current = node.next
        }
    }
}
