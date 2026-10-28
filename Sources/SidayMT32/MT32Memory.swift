// Copyright (C) 2003-2009 Dean Beeler, Jerome Fisher; (C) 2011-2024 Dean Beeler, Jerome Fisher, Sergey V. Mikayev
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Swift port of the MT-32's memory as mt32emu keeps it (Structures.h and MemoryRegion.h of Munt's
// libmt32emu 2.8.3, and the memory parts of Synth.cpp), free software under the GNU Lesser General Public
// License, version 2.1 or any later version (see THIRD-PARTY.md).

/// The memory of an MT-32, which system exclusive messages write to, byte for byte as mt32emu lays it out:
/// the parts' patches and timbres as they are played, the rhythm part's keys, the 128 patches, the 256
/// timbres (two banks of the ROM's, the memory bank, the rhythm bank) and the system settings.
///
/// Its layout is what makes a message's bytes land where the MT-32's manual says, so it is kept as bytes,
/// and read through views of its parts (`PartialParams` and the offsets below).
final class MT32Memory {
    // The sizes of its parts, as mt32emu's packed structures have them.
    static let partialParamSize = 58, timbreCommonSize = 14, timbreSize = 14 + 4 * 58
    static let patchSize = 8, patchTempSize = 16, rhythmTempSize = 4, paddedTimbreSize = 256, systemSize = 23

    // Where each part begins.
    static let patchTemp = 0
    static let rhythmTemp = patchTemp + 9 * patchTempSize
    static let timbreTemp = rhythmTemp + 85 * rhythmTempSize
    static let patches = timbreTemp + 8 * timbreSize
    static let timbres = patches + 128 * patchSize
    static let system = timbres + 256 * paddedTimbreSize
    static let size = system + systemSize

    // The system settings, from `system`.
    static let masterTune = 0, reverbMode = 1, reverbTime = 2, reverbLevel = 3, reserveSettings = 4, chanAssign = 13, masterVol = 22
    // A patch's settings, from its start (and a part's patch as it is played, which goes on with its level
    // and pan).
    static let timbreGroup = 0, timbreNum = 1, keyShift = 2, fineTune = 3, benderRange = 4, assignMode = 5, reverbSwitch = 6
    static let outputLevel = 8, panpot = 9
    // A rhythm key's settings.
    static let rhythmTimbre = 0, rhythmOutputLevel = 1, rhythmPanpot = 2, rhythmReverbSwitch = 3
    // A timbre's common settings.
    static let partialStructure12 = 10, partialStructure34 = 11, partialMute = 12, noSustain = 13

    let bytes: UnsafeMutablePointer<UInt8>

    init() {
        bytes = .allocate(capacity: Self.size)
        // (As mt32emu, to show what has not been set.)
        bytes.initialize(repeating: 0x3F, count: Self.size)
    }

    deinit { bytes.deallocate() }

    func copy(from other: MT32Memory) { bytes.update(from: other.bytes, count: Self.size) }

    func system(_ offset: Int) -> UInt8 { bytes[Self.system + offset] }
    func setSystem(_ offset: Int, _ value: UInt8) { bytes[Self.system + offset] = value }

    /// Where a part's patch as it is played begins (parts 0 to 7, and 8 for the rhythm part).
    func patchTempAddress(_ part: Int) -> UnsafeMutablePointer<UInt8> { bytes + Self.patchTemp + part * Self.patchTempSize }
    /// Where a rhythm key's settings begin (keys 24 to 108 are 0 to 84).
    func rhythmTempAddress(_ key: Int) -> UnsafeMutablePointer<UInt8> { bytes + Self.rhythmTemp + key * Self.rhythmTempSize }
    /// Where a part's timbre as it is played begins.
    func timbreTempAddress(_ part: Int) -> UnsafeMutablePointer<UInt8> { bytes + Self.timbreTemp + part * Self.timbreSize }
    func patchAddress(_ number: Int) -> UnsafeMutablePointer<UInt8> { bytes + Self.patches + number * Self.patchSize }
    /// Where a timbre of the 256 begins: 0 to 63 bank A, 64 to 127 bank B, 128 to 191 the memory, 192 to 255
    /// the rhythm bank.
    func timbreAddress(_ number: Int) -> UnsafeMutablePointer<UInt8> { bytes + Self.timbres + number * Self.paddedTimbreSize }
}

/// One partial's settings in a timbre, read where they are kept (as the original reads them through a
/// pointer into the synthesiser's memory, so a message that changes them is heard by a note playing).
struct PartialParams {
    let base: UnsafePointer<UInt8>

    init(_ base: UnsafePointer<UInt8>) { self.base = base }

    // The wave generator.
    var pitchCoarse: Int { Int(base[0]) }
    var pitchFine: Int { Int(base[1]) }
    var pitchKeyfollow: Int { Int(base[2]) }
    var pitchBenderEnabled: Int { Int(base[3]) }
    var waveform: Int { Int(base[4]) }
    var pcmWave: Int { Int(base[5]) }
    var pulseWidth: Int { Int(base[6]) }
    var pulseWidthVeloSensitivity: Int { Int(base[7]) }
    // The pitch envelope.
    var pitchEnvDepth: Int { Int(base[8]) }
    var pitchEnvVeloSensitivity: Int { Int(base[9]) }
    var pitchEnvTimeKeyfollow: Int { Int(base[10]) }
    func pitchEnvTime(_ i: Int) -> Int { Int(base[11 + i]) }
    func pitchEnvLevel(_ i: Int) -> Int { Int(base[15 + i]) }
    // The pitch LFO.
    var lfoRate: Int { Int(base[20]) }
    var lfoDepth: Int { Int(base[21]) }
    var lfoModSensitivity: Int { Int(base[22]) }
    // The filter.
    var tvfCutoff: Int { Int(base[23]) }
    var tvfResonance: Int { Int(base[24]) }
    var tvfKeyfollow: Int { Int(base[25]) }
    var tvfBiasPoint: Int { Int(base[26]) }
    var tvfBiasLevel: Int { Int(base[27]) }
    var tvfEnvDepth: Int { Int(base[28]) }
    var tvfEnvVeloSensitivity: Int { Int(base[29]) }
    var tvfEnvDepthKeyfollow: Int { Int(base[30]) }
    var tvfEnvTimeKeyfollow: Int { Int(base[31]) }
    func tvfEnvTime(_ i: Int) -> Int { Int(base[32 + i]) }
    func tvfEnvLevel(_ i: Int) -> Int { Int(base[37 + i]) }
    // The amplifier.
    var tvaLevel: Int { Int(base[41]) }
    var tvaVeloSensitivity: Int { Int(base[42]) }
    var tvaBiasPoint1: Int { Int(base[43]) }
    var tvaBiasLevel1: Int { Int(base[44]) }
    var tvaBiasPoint2: Int { Int(base[45]) }
    var tvaBiasLevel2: Int { Int(base[46]) }
    var tvaEnvTimeKeyfollow: Int { Int(base[47]) }
    var tvaEnvTimeVeloSensitivity: Int { Int(base[48]) }
    func tvaEnvTime(_ i: Int) -> Int { Int(base[49 + i]) }
    func tvaEnvLevel(_ i: Int) -> Int { Int(base[54 + i]) }
}

/// The kinds of the MT-32's memory that system exclusive messages write to.
enum MT32MemoryKind {
    case patchTemp, rhythmTemp, timbreTemp, patches, timbres, system, display, reset
}

/// A part of the MT-32's memory as a message reaches it: where it is by the message's address, how
/// long its entries are, and the largest value each byte of an entry may be given (from the control ROM).
struct MT32MemoryRegion {
    let kind: MT32MemoryKind
    /// The memory, or nil for a part that cannot be read back (the display, the reset).
    let memory: UnsafeMutablePointer<UInt8>?
    let maxTable: UnsafePointer<UInt8>?
    /// Where it begins, as an address with the sysex's 7-bit bytes packed together.
    let startAddr: Int
    let entrySize: Int
    let entries: Int

    /// An address of a message (three 7-bit bytes) as the packed address mt32emu works with.
    static func memAddr(_ x: Int) -> Int { ((x & 0x7F0000) >> 2) | ((x & 0x7F00) >> 1) | (x & 0x7F) }

    func offset(_ addr: Int) -> Int { addr - startAddr }
    func firstTouched(_ addr: Int) -> Int { offset(addr) / entrySize }
    func lastTouched(_ addr: Int, _ len: Int) -> Int { (offset(addr) + len - 1) / entrySize }
    func firstTouchedOffset(_ addr: Int) -> Int { offset(addr) % entrySize }
    var regionEnd: Int { startAddr + entrySize * entries }
    func contains(_ addr: Int) -> Bool { addr >= startAddr && addr < regionEnd }
    func clampedLength(_ addr: Int, _ len: Int) -> Int { addr + len > regionEnd ? regionEnd - addr : len }
    func next(_ addr: Int, _ len: Int) -> Int { addr + len > regionEnd ? regionEnd - addr : 0 }
    func maxValue(_ off: Int) -> UInt8 { maxTable.map { $0[off % entrySize] } ?? 0xFF }

    /// Writes bytes to an entry, each no more than its largest value; a byte whose largest value is nought
    /// cannot be written, but by the synthesiser's own setting up (`initialising`).
    func write(entry: Int, offset off: Int, from source: UnsafePointer<UInt8>, count: Int, initialising: Bool = false) {
        var memOff = entry * entrySize + off
        // (As mt32emu, which checks the offset in the entry, not in the region.)
        if off > entrySize * entries - 1 { return }
        var len = count
        if off + len > entrySize * entries { len = entrySize * entries - off }
        guard let memory else { return }
        for i in 0 ..< len {
            var desired = source[i]
            let maximum = maxValue(memOff)
            if maximum != 0 || initialising {
                if desired > maximum { desired = maximum }
                memory[memOff] = desired
            }
            memOff += 1
        }
    }
}
