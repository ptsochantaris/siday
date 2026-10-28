// Copyright (C) 2003-2009 Dean Beeler, Jerome Fisher; (C) 2011-2024 Dean Beeler, Jerome Fisher, Sergey V. Mikayev
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Swift port of mt32emu's synthesiser (Synth.cpp of Munt's libmt32emu 2.8.3, with its integer renderer and
// its MIDI event queue), free software under the GNU Lesser General Public License, version 2.1 or any later
// version (see THIRD-PARTY.md). Only what plays is ported: not the display, the reports to a host, the
// reading back of memory, or the floating-point renderer.

import SidayFoundation

/// What the control ROMs of each model do differently, as mt32emu tells them apart.
struct MT32Features {
    var quirkBasePitchOverflow = false
    var quirkPitchEnvelopeOverflow = false
    var quirkRingModulationNoMix = false
    var quirkTVAZeroEnvLevels = false
    var quirkPanMult = false
    var quirkKeyShift = false
    var quirkTVFBaseCutoffLimit = false
    var quirkFastPitchChanges = false
    var newGenNoteCancellation = false
    var defaultReverbMT32Compatible = false
    var oldMT32AnalogLPF = false

    static let oldMT32 = MT32Features(quirkBasePitchOverflow: true, quirkPitchEnvelopeOverflow: true, quirkRingModulationNoMix: true,
                                      quirkTVAZeroEnvLevels: true, quirkPanMult: true, quirkKeyShift: true, quirkTVFBaseCutoffLimit: true,
                                      defaultReverbMT32Compatible: true, oldMT32AnalogLPF: true)
    static let newMT32 = MT32Features(newGenNoteCancellation: true)
    static let cm32ln = MT32Features(quirkFastPitchChanges: true, newGenNoteCancellation: true)
}

/// Where a control ROM keeps its tables, by its version.
struct MT32ControlROMMap {
    let features: MT32Features
    let pcmTable: Int, pcmCount: Int
    let timbreAMap: Int, timbreAOffset: Int, timbreACompressed: Bool
    let timbreBMap: Int, timbreBOffset: Int, timbreBCompressed: Bool
    let timbreRMap: Int, timbreRCount: Int
    let rhythmSettings: Int, rhythmSettingsCount: Int
    let reserveSettings: Int, panSettings: Int, programSettings: Int
    let rhythmMaxTable: Int, patchMaxTable: Int, systemMaxTable: Int, timbreMaxTable: Int

    static func old(_ rhythm: Int, _ reserve: Int, _ pan: Int, _ program: Int, _ rhythmMax: Int, _ patchMax: Int, _ systemMax: Int, _ timbreMax: Int, _ features: MT32Features) -> MT32ControlROMMap {
        MT32ControlROMMap(features: features, pcmTable: 0x3000, pcmCount: 128, timbreAMap: 0x8000, timbreAOffset: 0x0000, timbreACompressed: false,
                          timbreBMap: 0xC000, timbreBOffset: 0x4000, timbreBCompressed: false, timbreRMap: 0x3200, timbreRCount: 30,
                          rhythmSettings: rhythm, rhythmSettingsCount: 85, reserveSettings: reserve, panSettings: pan, programSettings: program,
                          rhythmMaxTable: rhythmMax, patchMaxTable: patchMax, systemMaxTable: systemMax, timbreMaxTable: timbreMax)
    }

    static func new(_ features: MT32Features, _ pcmCount: Int, _ reserve: Int, _ pan: Int, _ program: Int, _ rhythmMax: Int, _ patchMax: Int, _ systemMax: Int, _ timbreMax: Int) -> MT32ControlROMMap {
        MT32ControlROMMap(features: features, pcmTable: 0x8100, pcmCount: pcmCount, timbreAMap: 0x8000, timbreAOffset: 0x8000, timbreACompressed: true,
                          timbreBMap: 0x8080, timbreBOffset: 0x8000, timbreBCompressed: true, timbreRMap: 0x8500, timbreRCount: 64,
                          rhythmSettings: 0x8580, rhythmSettingsCount: 85, reserveSettings: reserve, panSettings: pan, programSettings: program,
                          rhythmMaxTable: rhythmMax, patchMaxTable: patchMax, systemMaxTable: systemMax, timbreMaxTable: timbreMax)
    }

    /// mt32emu's table of them, by the control ROM's model and version.
    static func map(for control: MT32ControlROM) -> MT32ControlROMMap {
        switch control {
        case .mt32_1_04: old(0x73A6, 0x57C7, 0x57E2, 0x57D0, 0x5252, 0x525E, 0x526E, 0x520A, .oldMT32)
        case .mt32_1_05: old(0x7414, 0x57C7, 0x57E2, 0x57D0, 0x5252, 0x525E, 0x526E, 0x520A, .oldMT32)
        case .mt32_1_06: old(0x7414, 0x57D9, 0x57F4, 0x57E2, 0x5264, 0x5270, 0x5280, 0x521C, .oldMT32)
        case .mt32_1_07: old(0x73FE, 0x57B1, 0x57CC, 0x57BA, 0x523C, 0x5248, 0x5258, 0x51F4, .oldMT32)
        case .mt32BlueRidge: old(0x741C, 0x57E5, 0x5800, 0x57EE, 0x5270, 0x527C, 0x528C, 0x5228, .oldMT32)
        case .mt32_2_03: new(.newMT32, 128, 0x4F49, 0x4F64, 0x4F52, 0x4885, 0x4889, 0x48A2, 0x48B9)
        case .mt32_2_04: new(.newMT32, 128, 0x4F5D, 0x4F78, 0x4F66, 0x4899, 0x489D, 0x48B6, 0x48CD)
        case .mt32_2_06: new(.newMT32, 128, 0x4F69, 0x4F84, 0x4F72, 0x48A5, 0x48A9, 0x48C2, 0x48D9)
        case .mt32_2_07: new(.newMT32, 128, 0x4F81, 0x4F9C, 0x4F8A, 0x48B9, 0x48BD, 0x48D6, 0x48ED)
        case .cm32l_1_00: new(.newMT32, 256, 0x4F65, 0x4F80, 0x4F6E, 0x48A1, 0x48A5, 0x48BE, 0x48D5)
        case .cm32l_1_02: new(.newMT32, 256, 0x4F93, 0x4FAE, 0x4F9C, 0x48CB, 0x48CF, 0x48E8, 0x48FF)
        case .cm32ln_1_00: new(.cm32ln, 256, 0x4EC7, 0x4EE2, 0x4ED0, 0x47FF, 0x4803, 0x481C, 0x4833)
        }
    }
}

/// A PCM sound of the PCM ROM, as the control ROM lists it.
struct MT32PCMWave {
    /// Where it begins, and its length, in samples.
    let address: UInt32
    let length: UInt32
    let loop: Bool
    /// The list's length byte (its lowest bit set if the master tune does not change it).
    let lengthByte: UInt8
    /// Its pitch, to add to a partial's.
    let pitch: Int
}

/// How the LA32's output reaches the DAC.
public enum MT32DACInputMode: Int, Sendable {
    /// At twice the level, clipped (mt32emu's own, nicer than any real unit).
    case nice = 0
    /// As the LA32 gives it, at half the level of the others.
    case pure = 1
    /// Its bits as the first MT-32s wire them, which can overflow.
    case generation1 = 2
    /// Its bits as the later units, the CM-32L and the LAPC-I wire them, which can overflow.
    case generation2 = 3
}

/// How messages reaching the synthesiser at the same moment are spread out.
public enum MT32MIDIDelayMode: Int, Sendable {
    /// Played as they come.
    case immediate = 0
    /// Short messages as a MIDI cable delivers them, one after another; system exclusive ones at once.
    case delayShortMessagesOnly = 1
    /// All as a MIDI cable delivers them.
    case delayAll = 2
}

/// How the synthesiser is set up: siday's choices, as close to a real unit as mt32emu can be set (see
/// `MT32Synth`).
public struct MT32Configuration: Sendable {
    public var analogMode = MT32AnalogMode.accurate
    public var dacInputMode = MT32DACInputMode.generation2
    public var midiDelayMode = MT32MIDIDelayMode.delayShortMessagesOnly
    /// mt32emu's smoothing of a change of loudness of a sustained note, which a real unit does not do.
    public var niceAmpRamp = false
    /// Pan in sixteen steps, not the LA32's eight.
    public var nicePanning = false
    /// Partials always added, never the LA32's occasional taking away.
    public var nicePartialMixing = false
    public var reversedStereo = false
    public var outputGain: Float = 1
    public var reverbOutputGain: Float = 1

    public init() {}
}

/// The MT-32's kind of synthesiser: mt32emu's emulation of its controller, its LA32 chip, its Boss reverb
/// and its analogue output, given a control ROM and a PCM ROM.
///
/// It is given messages with the moment they reach it, in its own samples at 32,000 a second, and plays
/// each when it comes to that sample (as mt32emu's queue does); `render` makes its output.
public final class MT32Synth {
    /// The samples a second of the LA32 and the DAC.
    public static let sampleRate = 32000
    static let maxSamplesPerRun = 4096
    static let partialCount = 32
    /// A byte on a MIDI cable, in samples: 32,000 / 31,250 by eight (mt32emu's figure).
    private static let midiDataTransferRate = Double(sampleRate) / 31250.0 * 8.0

    let configuration: MT32Configuration
    let control: MT32ControlROM
    let controlROMMap: MT32ControlROMMap
    var features: MT32Features { controlROMMap.features }
    let controlROMData: UnsafeMutablePointer<UInt8>
    let pcmROMData: UnsafeMutablePointer<Int16>
    private let pcmROMSize: Int
    private(set) var pcmWaves: [MT32PCMWave] = []
    let memory = MT32Memory()
    private let defaults = MT32Memory()
    private(set) var parts: [MT32Part] = []
    private(set) var partialManager: MT32PartialManager!
    var abortingPoly: MT32Poly?
    private var abortingPartIx = 0
    /// The parts each MIDI channel plays, in order (above 8 for none).
    private var chantable = [[UInt8]](repeating: [UInt8](repeating: 0xFF, count: 9), count: 16)
    private(set) var masterTunePitchDelta: Int32 = 0
    private var reverbModels: [BossReverb] = []
    private var reverbModel: BossReverb?
    private var analog: MT32Analog
    private let paddedTimbreMaxTable: UnsafeMutablePointer<UInt8>
    private var regions: [MT32MemoryRegion] = []

    // The queue of messages to play, by their moments.
    private struct QueuedEvent {
        var timestamp: UInt32
        var shortMessage: UInt32
        var sysex: [UInt8]?
    }
    private var queue: [QueuedEvent] = []
    private var queueStart = 0
    private var lastReceivedMIDIEventTimestamp: UInt32 = 0
    /// The samples made so far, at 32,000 a second.
    public private(set) var renderedSampleCount: UInt32 = 0
    private var activated = false
    /// The C library's random numbers, as mt32emu draws them for its timer's jitter: the "minimal standard"
    /// generator of Park and Miller, as Apple's C library has it.
    private var randomState: UInt64 = 1

    var niceAmpRamp: Bool { configuration.niceAmpRamp }
    var nicePanning: Bool { configuration.nicePanning }
    var nicePartialMixing: Bool { configuration.nicePartialMixing }
    var reversedStereo: Bool { configuration.reversedStereo }

    // The buffers of a run: the two channels without reverb, the two sent to it, and its two.
    private let nonReverbLeft: UnsafeMutablePointer<Int16>, nonReverbRight: UnsafeMutablePointer<Int16>
    private let reverbDryLeft: UnsafeMutablePointer<Int16>, reverbDryRight: UnsafeMutablePointer<Int16>
    private let reverbWetLeft: UnsafeMutablePointer<Int16>, reverbWetRight: UnsafeMutablePointer<Int16>
    private let streams: UnsafeMutablePointer<Int16>

    /// The samples a second it makes.
    public var outputRate: Int { configuration.analogMode.outputRate }

    /// Opens a synthesiser of a set of ROMs (see `MT32ROMSet`).
    public init(roms: MT32ROMSet, configuration: MT32Configuration = MT32Configuration()) {
        self.configuration = configuration
        control = roms.control
        controlROMMap = MT32ControlROMMap.map(for: roms.control)
        let controlData = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        roms.controlData.withUnsafeBufferPointer { controlData.initialize(from: $0.baseAddress!, count: 65536) }
        controlROMData = controlData
        // 256 K samples for the MT-32, 512 K for the CM-32L's kind.
        pcmROMSize = controlROMMap.pcmCount == 256 ? 512 * 1024 : 256 * 1024
        pcmROMData = .allocate(capacity: pcmROMSize)
        streams = .allocate(capacity: Self.maxSamplesPerRun * 6)
        streams.initialize(repeating: 0, count: Self.maxSamplesPerRun * 6)
        nonReverbLeft = streams
        nonReverbRight = streams + Self.maxSamplesPerRun
        reverbDryLeft = streams + Self.maxSamplesPerRun * 2
        reverbDryRight = streams + Self.maxSamplesPerRun * 3
        reverbWetLeft = streams + Self.maxSamplesPerRun * 4
        reverbWetRight = streams + Self.maxSamplesPerRun * 5
        paddedTimbreMaxTable = .allocate(capacity: MT32Memory.paddedTimbreSize)
        let features = controlROMMap.features
        analog = MT32Analog(mode: configuration.analogMode, oldMT32: features.oldMT32AnalogLPF, outputGain: configuration.outputGain,
                            reverbGain: configuration.reverbOutputGain, mt32ReverbCompatible: features.defaultReverbMT32Compatible)
        let pcm = pcmROMData, size = pcmROMSize
        roms.pcmData.withUnsafeBufferPointer { Self.loadPCMROM($0.baseAddress!, into: pcm, count: size) }
        open()
    }

    deinit {
        partTap.deallocate()
        partPeaks.deallocate()
        scratch.deallocate()
        controlROMData.deallocate()
        pcmROMData.deallocate()
        streams.deallocate()
        paddedTimbreMaxTable.deallocate()
    }

    /// The PCM ROM's samples, with their bits in the order the LA32 reads them.
    private static func loadPCMROM(_ data: UnsafePointer<UInt8>, into pcmROMData: UnsafeMutablePointer<Int16>, count: Int) {
        let order = [0, 9, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15, 8]
        for i in 0 ..< count {
            let s = data[i * 2], c = data[i * 2 + 1]
            var log: UInt16 = 0
            for u in 0 ..< 16 {
                let bit = order[u] < 8 ? (s >> UInt8(7 - order[u])) & 1 : (c >> UInt8(7 - (order[u] - 8))) & 1
                log |= UInt16(bit) << UInt16(15 - u)
            }
            pcmROMData[i] = Int16(bitPattern: log)
        }
    }

    private func controlWord(_ address: Int) -> Int { Int(controlROMData[address + 1]) << 8 | Int(controlROMData[address]) }

    /// Writes a timbre of the control ROM's, kept there without its muted partials (but the first): each
    /// muted one's place is filled with the partial before it.
    private func initCompressedTimbre(_ region: MT32MemoryRegion, _ absTimbreNum: Int, _ source: UnsafePointer<UInt8>, _ sourceLength: Int) -> Bool {
        if sourceLength < MT32Memory.timbreCommonSize { return false }
        let timbreNum = absTimbreNum & 0x3F
        region.write(entry: timbreNum, offset: 0, from: source, count: MT32Memory.timbreCommonSize, initialising: true)
        let mute = memory.timbreAddress(absTimbreNum)[MT32Memory.partialMute]
        var sourcePos = MT32Memory.timbreCommonSize
        var memPos = MT32Memory.timbreCommonSize
        for t in 0 ..< 4 {
            if t != 0, (mute >> UInt8(t)) & 1 == 0 {
                sourcePos -= MT32Memory.partialParamSize
            } else if sourcePos + MT32Memory.partialParamSize >= sourceLength {
                return false
            }
            region.write(entry: timbreNum, offset: memPos, from: source + sourcePos, count: MT32Memory.partialParamSize)
            sourcePos += MT32Memory.partialParamSize
            memPos += MT32Memory.partialParamSize
        }
        return true
    }

    private func initTimbres(_ mapAddress: Int, _ offset: Int, _ count: Int, _ startTimbre: Int, _ compressed: Bool) {
        // (A region only to keep the values to the largest allowed.)
        let region = MT32MemoryRegion(kind: .timbres, memory: memory.timbreAddress(startTimbre), maxTable: UnsafePointer(paddedTimbreMaxTable),
                                      startAddr: MT32MemoryRegion.memAddr(0x080000), entrySize: MT32Memory.paddedTimbreSize, entries: 64)
        for timbreNum in 0 ..< count {
            var address = controlWord(mapAddress + timbreNum * 2)
            if !compressed, address + offset + MT32Memory.timbreSize > 65536 { return }
            address += offset
            if compressed {
                if !initCompressedTimbre(region, startTimbre + timbreNum, controlROMData + address, 65536 - address) { return }
            } else {
                region.write(entry: timbreNum, offset: 0, from: controlROMData + address, count: MT32Memory.timbreSize, initialising: true)
            }
        }
    }

    private func open() {
        let map = controlROMMap
        // The largest values of a timbre: the ROM has the common part's and one partial's.
        paddedTimbreMaxTable.initialize(repeating: 0, count: MT32Memory.paddedTimbreSize)
        paddedTimbreMaxTable.update(from: controlROMData + map.timbreMaxTable, count: MT32Memory.timbreCommonSize + MT32Memory.partialParamSize)
        for i in 1 ... 3 {
            (paddedTimbreMaxTable + MT32Memory.timbreCommonSize + i * MT32Memory.partialParamSize)
                .update(from: controlROMData + map.timbreMaxTable + MT32Memory.timbreCommonSize, count: MT32Memory.partialParamSize)
        }
        let maddr = MT32MemoryRegion.memAddr
        regions = [
            MT32MemoryRegion(kind: .patchTemp, memory: memory.patchTempAddress(0), maxTable: UnsafePointer(controlROMData + map.patchMaxTable),
                             startAddr: maddr(0x030000), entrySize: MT32Memory.patchTempSize, entries: 9),
            MT32MemoryRegion(kind: .rhythmTemp, memory: memory.rhythmTempAddress(0), maxTable: UnsafePointer(controlROMData + map.rhythmMaxTable),
                             startAddr: maddr(0x030110), entrySize: MT32Memory.rhythmTempSize, entries: 85),
            MT32MemoryRegion(kind: .timbreTemp, memory: memory.timbreTempAddress(0), maxTable: UnsafePointer(paddedTimbreMaxTable),
                             startAddr: maddr(0x040000), entrySize: MT32Memory.timbreSize, entries: 8),
            MT32MemoryRegion(kind: .patches, memory: memory.patchAddress(0), maxTable: UnsafePointer(controlROMData + map.patchMaxTable),
                             startAddr: maddr(0x050000), entrySize: MT32Memory.patchSize, entries: 128),
            MT32MemoryRegion(kind: .timbres, memory: memory.timbreAddress(128), maxTable: UnsafePointer(paddedTimbreMaxTable),
                             startAddr: maddr(0x080000), entrySize: MT32Memory.paddedTimbreSize, entries: 64),
            MT32MemoryRegion(kind: .system, memory: memory.bytes + MT32Memory.system, maxTable: UnsafePointer(controlROMData + map.systemMaxTable),
                             startAddr: maddr(0x100000), entrySize: MT32Memory.systemSize, entries: 1),
            MT32MemoryRegion(kind: .display, memory: nil, maxTable: nil, startAddr: maddr(0x200000), entrySize: 0x4013, entries: 1),
            MT32MemoryRegion(kind: .reset, memory: nil, maxTable: nil, startAddr: maddr(0x7F0000), entrySize: 0x3FFF, entries: 1),
        ]
        reverbModels = (0 ..< 4).map { BossReverb(mode: $0, mt32Compatible: map.features.defaultReverbMT32Compatible) }

        initTimbres(map.timbreAMap, map.timbreAOffset, 0x40, 0, map.timbreACompressed)
        initTimbres(map.timbreBMap, map.timbreBOffset, 0x40, 64, map.timbreBCompressed)
        initTimbres(map.timbreRMap, 0, map.timbreRCount, 192, true)
        if map.timbreRCount == 30 {
            // The first MT-32s' rhythm timbres 30 to 59 are as 0 to 29; 60 to 63 are nothing.
            memory.timbreAddress(222).update(from: memory.timbreAddress(192), count: 30 * MT32Memory.paddedTimbreSize)
            memory.timbreAddress(252).update(repeating: 0, count: 4 * MT32Memory.paddedTimbreSize)
        }
        // The memory bank starts as noughts (as the CM-64 does).
        memory.timbreAddress(128).update(repeating: 0, count: 64 * MT32Memory.paddedTimbreSize)

        partialManager = MT32PartialManager(synth: self, count: Self.partialCount)

        for i in 0 ..< map.pcmCount {
            let entry = controlROMData + map.pcmTable + i * 4
            let address = UInt32(entry[0]) * 0x800
            let length = UInt32(0x800) << UInt32((entry[1] & 0x70) >> 4)
            // (A bad entry stops the list, as mt32emu's does; never in a ROM it knows.)
            if Int(address + length) > pcmROMSize { break }
            pcmWaves.append(MT32PCMWave(address: address, length: length, loop: entry[1] & 0x80 != 0, lengthByte: entry[1],
                                        pitch: Int(entry[3]) << 8 | Int(entry[2])))
        }

        (memory.bytes + MT32Memory.rhythmTemp).update(from: controlROMData + map.rhythmSettings, count: map.rhythmSettingsCount * 4)
        for i in 0 ..< 128 {
            let patch = memory.patchAddress(i)
            patch[MT32Memory.timbreGroup] = UInt8(i / 64)
            patch[MT32Memory.timbreNum] = UInt8(i % 64)
            patch[MT32Memory.keyShift] = 24
            patch[MT32Memory.fineTune] = 50
            patch[MT32Memory.benderRange] = 12
            patch[MT32Memory.assignMode] = 0
            patch[MT32Memory.reverbSwitch] = 1
            patch[7] = 0
        }
        memory.setSystem(MT32Memory.masterTune, 0x4A)
        memory.setSystem(MT32Memory.reverbMode, 0)
        memory.setSystem(MT32Memory.reverbTime, 5)
        memory.setSystem(MT32Memory.reverbLevel, 3)
        (memory.bytes + MT32Memory.system + MT32Memory.reserveSettings).update(from: controlROMData + map.reserveSettings, count: 9)
        for i in 0 ..< 9 { memory.setSystem(MT32Memory.chanAssign + i, UInt8(i + 1)) }
        memory.setSystem(MT32Memory.masterVol, 100)

        parts = []
        refreshSystem()
        masterTunePitchDelta = 0
        for i in 0 ..< 9 {
            let patchTemp = memory.patchTempAddress(i)
            patchTemp[MT32Memory.timbreGroup] = 0
            patchTemp[MT32Memory.timbreNum] = 0
            patchTemp[MT32Memory.keyShift] = 24
            patchTemp[MT32Memory.fineTune] = 50
            patchTemp[MT32Memory.benderRange] = 12
            patchTemp[MT32Memory.assignMode] = 0
            patchTemp[MT32Memory.reverbSwitch] = 1
            patchTemp[7] = 0
            patchTemp[MT32Memory.outputLevel] = 80
            patchTemp[MT32Memory.panpot] = controlROMData[map.panSettings + i]
            (patchTemp + 10).update(repeating: 0, count: 6)
            patchTemp[11] = 127
            if i < 8 {
                let part = MT32Part(synth: self, partNum: i)
                parts.append(part)
                part.setProgram(Int(controlROMData[map.programSettings + i]))
            } else {
                parts.append(MT32RhythmPart(synth: self, partNum: i))
            }
        }
        defaults.copy(from: memory)
    }

    // MARK: Random numbers

    @inline(__always)
    func nextRandom() -> Int {
        randomState = randomState * 16807 % 2_147_483_647
        return Int(randomState)
    }

    // MARK: Samples

    @inline(__always)
    static func clip(_ sample: Int32) -> Int16 {
        -0x8000 <= sample && sample <= 0x7FFF ? Int16(sample) : Int16(truncatingIfNeeded: (sample >> 31) ^ 0x7FFF)
    }

    // MARK: Messages

    private func addMIDIInterfaceDelay(_ length: Int, _ timestamp: UInt32) -> UInt32 {
        let transferTime = UInt32(Double(length) * Self.midiDataTransferRate)
        var timestamp = timestamp
        if Int32(bitPattern: timestamp &- lastReceivedMIDIEventTimestamp) < 0 { timestamp = lastReceivedMIDIEventTimestamp }
        timestamp &+= transferTime
        lastReceivedMIDIEventTimestamp = timestamp
        return timestamp
    }

    private static func shortMessageLength(_ message: UInt32) -> Int {
        if message & 0xF0 == 0xF0 {
            switch message & 0xFF {
            case 0xF1, 0xF3: return 2
            case 0xF2: return 3
            default: return 1
            }
        }
        // (As mt32emu: running status is not taken into account.)
        return message & 0xE0 == 0xC0 ? 2 : 3
    }

    /// Takes a short message (its status byte the lowest), to be played at a sample.
    public func playMessage(_ message: UInt32, at timestamp: UInt32) {
        if message & 0xF8 == 0xF8 { return }
        var timestamp = timestamp
        if configuration.midiDelayMode != .immediate { timestamp = addMIDIInterfaceDelay(Self.shortMessageLength(message), timestamp) }
        activated = true
        queue.append(QueuedEvent(timestamp: timestamp, shortMessage: message, sysex: nil))
    }

    /// Takes a system exclusive message, whole (F0 to F7), to be played at a sample.
    public func playSysex(_ bytes: [UInt8], at timestamp: UInt32) {
        var timestamp = timestamp
        if configuration.midiDelayMode == .delayAll { timestamp = addMIDIInterfaceDelay(bytes.count, timestamp) }
        activated = true
        queue.append(QueuedEvent(timestamp: timestamp, shortMessage: 0, sysex: bytes))
    }

    private func playMsgNow(_ message: UInt32) {
        let command = UInt8((message & 0xF0) >> 4)
        // (Real-time and system messages, and running status, are not taken.)
        if command == 0x0F || command < 8 { return }
        let channel = Int(message & 0x0F)
        let data1 = UInt8((message & 0xFF00) >> 8)
        let data2 = command & 0x0E == 0x0C ? 0 : UInt8((message & 0xFF_0000) >> 16)
        if data1 > 127 || data2 > 127 { return }
        let chanParts = chantable[channel]
        if chanParts[0] > 8 { return }
        var i = abortingPartIx
        while i <= 8 {
            let partNum = Int(chanParts[i])
            if partNum > 8 { break }
            playUnpackedShortMessage(partNum, command, data1, data2)
            if abortingPoly != nil {
                abortingPartIx = i
                break
            } else if abortingPartIx != 0 {
                abortingPartIx = 0
            }
            i += 1
        }
    }

    private func playUnpackedShortMessage(_ partNum: Int, _ command: UInt8, _ data1: UInt8, _ data2: UInt8) {
        activated = true
        let part = parts[partNum]
        switch command {
        case 0x8:
            // (Note off's velocity is not used.)
            part.noteOff(Int(data1))
        case 0x9:
            if data2 == 0 {
                part.noteOff(Int(data1))
            } else if part.volumeOverride > 0 {
                part.noteOn(Int(data1), Int(data2))
            }
        case 0xB:
            switch data1 {
            case 0x01: part.setModulation(data2)
            case 0x06: part.setDataEntryMSB(data2)
            case 0x07: part.setVolume(Int(data2))
            case 0x0A: part.setPan(Int(data2))
            case 0x0B: part.setExpression(Int(data2))
            case 0x40: part.setHoldPedal(data2 >= 64)
            case 0x62, 0x63: part.setNRPN()
            case 0x64: part.setRPNLSB(data2)
            case 0x65: part.setRPNMSB(data2)
            case 0x79: part.resetAllControllers()
            case 0x7B: part.allNotesOff()
            case 0x7C, 0x7D, 0x7E, 0x7F:
                // (As a real LAPC-I answers them.)
                part.setHoldPedal(false)
                part.allNotesOff()
            default: break
            }
        case 0xC:
            part.setProgram(Int(data1))
        case 0xE:
            part.setBend(Int(data2) << 7 | Int(data1))
        default:
            break
        }
    }

    private func playSysexNow(_ sysex: [UInt8]) {
        guard sysex.count >= 1, sysex[0] == 0xF0 else { return }
        // To its end marker, whatever is after it.
        var endPos = 1
        while endPos < sysex.count, sysex[endPos] != 0xF7 { endPos += 1 }
        if endPos == sysex.count { return }
        let body = Array(sysex[1 ..< endPos])
        // Roland's, to the MT-32's model (not the D-50's).
        guard body.count >= 4, body[0] == 0x41, body[2] == 0x16 else { return }
        playSysexWithoutHeader(device: body[1], command: body[3], Array(body[4...]))
    }

    private func playSysexWithoutHeader(device: UInt8, command: UInt8, _ data: [UInt8]) {
        if device > 0x10 { return }
        // Every model checks the checksum first, and takes nothing without one.
        guard data.count >= 2 else { return }
        var checksum = 0
        for byte in data.dropLast() { checksum -= Int(byte) }
        if UInt8(checksum & 0x7F) != data[data.count - 1] { return }
        let body = Array(data.dropLast())
        switch command {
        case 0x42, 0x12:
            // DAT and DT1: data set.
            writeSysex(device: device, body)
        default:
            break
        }
    }

    private func writeSysex(device: UInt8, _ sysex: [UInt8]) {
        guard sysex.count >= 1 else { return }
        // (Checked first, as the real units do.)
        if sysex[0] == 0x7F {
            reset()
            return
        }
        if sysex.count < 3 { return }
        var addr = MT32MemoryRegion.memAddr(Int(sysex[0]) << 16 | Int(sysex[1]) << 8 | Int(sysex[2]))
        let data = Array(sysex[3...])
        let maddr = MT32MemoryRegion.memAddr
        if device < 0x10 {
            // To a channel: as to the part, or parts, it plays.
            let chanParts = chantable[Int(device)]
            if addr < maddr(0x010000) {
                addr += maddr(0x030000)
                if chanParts[0] <= 8 {
                    for partIx in 0 ... 8 {
                        if chanParts[partIx] > 8 { break }
                        let offset = chanParts[partIx] == 8 ? 0 : Int(chanParts[partIx]) * MT32Memory.patchTempSize
                        writeSysexGlobal(addr + offset, data)
                    }
                    return
                }
            } else if addr < maddr(0x020000) {
                addr += maddr(0x030110) - maddr(0x010000)
            } else if addr < maddr(0x030000) {
                addr += maddr(0x040000) - maddr(0x020000)
                if chanParts[0] <= 8 {
                    for partIx in 0 ... 8 {
                        if chanParts[partIx] > 8 { break }
                        let offset = chanParts[partIx] == 8 ? 0 : Int(chanParts[partIx]) * MT32Memory.timbreSize
                        writeSysexGlobal(addr + offset, data)
                    }
                    return
                }
            } else {
                return
            }
        }
        writeSysexGlobal(addr, data)
    }

    private func writeSysexGlobal(_ address: Int, _ data: [UInt8]) {
        var addr = address
        var start = 0
        var len = data.count
        while true {
            guard let region = regions.first(where: { $0.contains(addr) }) else { break }
            data.withUnsafeBufferPointer { buffer in
                writeMemoryRegion(region, addr, region.clampedLength(addr, len), buffer.baseAddress! + start)
            }
            let next = region.next(addr, len)
            if next == 0 { break }
            addr += next
            start += next
            len -= next
        }
    }

    private func writeMemoryRegion(_ region: MT32MemoryRegion, _ addr: Int, _ len: Int, _ data: UnsafePointer<UInt8>) {
        let first = region.firstTouched(addr)
        let last = region.lastTouched(addr, len)
        let off = region.firstTouchedOffset(addr)
        switch region.kind {
        case .patchTemp:
            region.write(entry: first, offset: off, from: data, count: len)
            for i in first ... max(first, last) where i < parts.count {
                if i != 8 {
                    // The timbre is set again only if the message reaches the patch's timbre settings.
                    if !(i == first && off > 2) { parts[i].resetTimbre() }
                }
                parts[i].refresh()
            }
        case .rhythmTemp:
            region.write(entry: first, offset: off, from: data, count: len)
            parts[8].refresh()
        case .timbreTemp:
            region.write(entry: first, offset: off, from: data, count: len)
            for i in first ... max(first, last) where i < 8 { parts[i].refresh() }
        case .patches:
            region.write(entry: first, offset: off, from: data, count: len)
        case .timbres:
            region.write(entry: first, offset: off, from: data, count: len)
            for i in first ... max(first, last) {
                // (As mt32emu: the number of the timbre in the memory bank, compared with each part's
                // timbre's number among all 256.)
                for part in parts { part.refreshTimbre(i) }
            }
        case .system:
            region.write(entry: 0, offset: off, from: data, count: len)
            if off <= MT32Memory.masterTune, off + len > MT32Memory.masterTune { refreshSystemMasterTune() }
            if off <= MT32Memory.reverbLevel, off + len > MT32Memory.reverbMode { refreshSystemReverbParameters() }
            if off <= MT32Memory.reserveSettings + 8, off + len > MT32Memory.reserveSettings { refreshSystemReserveSettings() }
            if off <= MT32Memory.chanAssign + 8, off + len > MT32Memory.chanAssign {
                let firstPart = max(0, off - MT32Memory.chanAssign)
                let lastPart = min(8, off + len - MT32Memory.chanAssign)
                refreshSystemChanAssign(firstPart, lastPart)
            }
            // (The master volume needs nothing more.)
        case .display:
            break
        case .reset:
            reset()
        }
    }

    private func refreshSystemMasterTune() {
        // 171 is about half a semitone.
        masterTunePitchDelta = ((Int32(memory.system(MT32Memory.masterTune)) - 64) * 171) >> 6
    }

    private func refreshSystemReverbParameters() {
        let old = reverbModel
        let time = memory.system(MT32Memory.reverbTime), level = memory.system(MT32Memory.reverbLevel)
        if time == 0, level == 0 {
            // No reverb at all, as a real unit sounds with both at nought.
            reverbModel = nil
        } else {
            reverbModel = reverbModels[Int(memory.system(MT32Memory.reverbMode))]
        }
        if reverbModel !== old {
            old?.close()
            reverbModel?.open()
        }
        reverbModel?.setParameters(time: time, level: level)
    }

    private func refreshSystemReserveSettings() {
        partialManager.setReserve(UnsafePointer(memory.bytes + MT32Memory.system + MT32Memory.reserveSettings))
    }

    private func refreshSystemChanAssign(_ firstPart: Int, _ lastPart: Int) {
        chantable = [[UInt8]](repeating: [UInt8](repeating: 0xFF, count: 9), count: 16)
        // A channel given to several parts is played by them all.
        for i in 0 ... 8 {
            if i < parts.count, i >= firstPart, i <= lastPart {
                // Every part whose channel the message touched lets its notes go and its controllers be.
                parts[i].allSoundOff()
                parts[i].resetAllControllers()
            }
            let channel = Int(memory.system(MT32Memory.chanAssign + i))
            if channel > 15 { continue }
            for j in 0 ... 8 where chantable[channel][j] > 8 {
                chantable[channel][j] = UInt8(i)
                break
            }
        }
    }

    private func refreshSystem() {
        refreshSystemMasterTune()
        refreshSystemReverbParameters()
        refreshSystemReserveSettings()
        refreshSystemChanAssign(0, 8)
    }

    /// As the MT-32 is reset by a message: its memory as it was when it was switched on, and its parts.
    private func reset() {
        partialManager.deactivateAll()
        memory.copy(from: defaults)
        for i in 0 ..< 9 {
            parts[i].reset()
            if i != 8 {
                parts[i].setProgram(Int(controlROMData[controlROMMap.programSettings + i]))
            } else {
                parts[8].refresh()
            }
        }
        refreshSystem()
        // (The master tune of 442 Hz is not taken on a reset, by a bug of every control ROM: 440 Hz.)
        masterTunePitchDelta = 0
        _ = isActive
    }

    private var hasActivePartials: Bool { partialManager.partials.contains { $0.isActive } }

    /// True while anything sounds or is to come; false once all is quiet, after which it makes no
    /// samples until it is given more.
    public var isActive: Bool {
        if queueStart < queue.count || hasActivePartials { return true }
        if let reverbModel, reverbModel.isActive { return true }
        activated = false
        return false
    }

    // MARK: Rendering

    /// Makes `frames` of stereo output, the left sample first, at `outputRate`. (With the parts' samples
    /// kept, no more than `maxSamplesPerRun` of its own samples at a time.)
    public func render(into out: UnsafeMutablePointer<Int16>, frames: Int) {
        if keepsPartSamples {
            tapPosition = 0
            let count = min(Self.maxSamplesPerRun, analog.inputCount(for: frames))
            for part in 0 ..< 9 { (partTap + part * Self.maxSamplesPerRun).update(repeating: 0, count: count) }
        }
        if !activated {
            renderedSampleCount &+= UInt32(analog.inputCount(for: frames))
            analog.skip(frames)
            out.update(repeating: 0, count: frames * 2)
            return
        }
        var done = 0
        while done < frames {
            let pass = min(frames - done, Self.maxSamplesPerRun)
            renderStreams(analog.inputCount(for: pass))
            analog.process(into: out + done * 2, nonReverbLeft: nonReverbLeft, nonReverbRight: nonReverbRight,
                           reverbDryLeft: reverbDryLeft, reverbDryRight: reverbDryRight,
                           reverbWetLeft: reverbWetLeft, reverbWetRight: reverbWetRight, count: pass)
            done += pass
        }
    }

    /// Makes `length` samples of the DAC's streams, playing each message at its moment.
    private func renderStreams(_ length: Int) {
        var offset = 0
        var length = length
        while length > 0 {
            // At least a sample at a time, so that a note of no length is heard.
            var thisLength = 1
            if abortingPoly == nil {
                if queueStart < queue.count {
                    let event = queue[queueStart]
                    let samplesToNextEvent = Int32(bitPattern: event.timestamp &- renderedSampleCount)
                    if samplesToNextEvent > 0 {
                        thisLength = min(length, Self.maxSamplesPerRun, Int(samplesToNextEvent))
                    } else {
                        if let sysex = event.sysex {
                            playSysexNow(sysex)
                            dropEvent()
                        } else {
                            playMsgNow(event.shortMessage)
                            // While a note is stopped to make room, the message is played again after.
                            if abortingPoly == nil { dropEvent() }
                        }
                    }
                } else {
                    thisLength = min(length, Self.maxSamplesPerRun)
                }
            }
            produceStreams(offset, thisLength)
            offset += thisLength
            length -= thisLength
        }
    }

    private func dropEvent() {
        queueStart += 1
        if queueStart == queue.count {
            queue.removeAll(keepingCapacity: true)
            queueStart = 0
        } else if queueStart >= 1024 {
            queue.removeFirst(queueStart)
            queueStart = 0
        }
    }

    /// The LA32's output as the DAC is wired to it.
    @inline(__always)
    private func produceLA32Output(_ buffer: UnsafeMutablePointer<Int16>, _ count: Int) {
        switch configuration.dacInputMode {
        case .generation2:
            for i in 0 ..< count {
                let u = UInt16(bitPattern: buffer[i])
                buffer[i] = Int16(bitPattern: (u & 0x8000) | ((u << 1) & 0x7FFE) | ((u >> 14) & 0x0001))
            }
        case .nice:
            for i in 0 ..< count { buffer[i] = Self.clip(Int32(buffer[i]) << 1) }
        default:
            break
        }
    }

    @inline(__always)
    private func convertSamplesToOutput(_ buffer: UnsafeMutablePointer<Int16>, _ count: Int) {
        if configuration.dacInputMode == .generation1 {
            for i in 0 ..< count {
                let u = UInt16(bitPattern: buffer[i])
                buffer[i] = Int16(bitPattern: (u & 0x8000) | ((u << 1) & 0x7FFE))
            }
        }
    }

    private func produceStreams(_ offset: Int, _ length: Int) {
        let nonReverbLeft = self.nonReverbLeft + offset, nonReverbRight = self.nonReverbRight + offset
        let reverbDryLeft = self.reverbDryLeft + offset, reverbDryRight = self.reverbDryRight + offset
        let reverbWetLeft = self.reverbWetLeft + offset, reverbWetRight = self.reverbWetRight + offset
        if activated {
            nonReverbLeft.update(repeating: 0, count: length)
            nonReverbRight.update(repeating: 0, count: length)
            reverbDryLeft.update(repeating: 0, count: length)
            reverbDryRight.update(repeating: 0, count: length)
            for partial in partialManager.partials {
                let owner = partial.ownerPart
                guard owner >= 0 else { continue }
                let tap = keepsPartSamples ? partTap + owner * Self.maxSamplesPerRun + tapPosition : nil
                if mutedParts[owner] {
                    // A part left out plays on, unheard: its sound goes nowhere.
                    partial.produceOutput(left: scratch, right: scratch + Self.maxSamplesPerRun, length: length, tap: tap, peak: partPeaks + owner)
                } else if partial.shouldReverb {
                    partial.produceOutput(left: reverbDryLeft, right: reverbDryRight, length: length, tap: tap, peak: partPeaks + owner)
                } else {
                    partial.produceOutput(left: nonReverbLeft, right: nonReverbRight, length: length, tap: tap, peak: partPeaks + owner)
                }
            }
            produceLA32Output(reverbDryLeft, length)
            produceLA32Output(reverbDryRight, length)
            if let reverbModel {
                reverbModel.process(inLeft: reverbDryLeft, inRight: reverbDryRight, outLeft: reverbWetLeft, outRight: reverbWetRight, count: length)
                convertSamplesToOutput(reverbWetLeft, length)
                convertSamplesToOutput(reverbWetRight, length)
            } else {
                reverbWetLeft.update(repeating: 0, count: length)
                reverbWetRight.update(repeating: 0, count: length)
            }
            produceLA32Output(nonReverbLeft, length)
            convertSamplesToOutput(nonReverbLeft, length)
            produceLA32Output(nonReverbRight, length)
            convertSamplesToOutput(nonReverbRight, length)
            convertSamplesToOutput(reverbDryLeft, length)
            convertSamplesToOutput(reverbDryRight, length)
        } else {
            for stream in [nonReverbLeft, nonReverbRight, reverbDryLeft, reverbDryRight, reverbWetLeft, reverbWetRight] {
                stream.update(repeating: 0, count: length)
            }
        }
        partialManager.clearAlreadyOutputed()
        renderedSampleCount &+= UInt32(length)
        tapPosition += length
    }

    // MARK: What it plays

    /// How many samples of its own make `frames` of its output, from where it is now.
    public func analogInputCount(for frames: Int) -> Int { analog.inputCount(for: frames) }

    /// True to keep each part's sound, before it is panned, as it is made (see `takePartSamples`).
    public var keepsPartSamples = false {
        didSet { if keepsPartSamples { partTap.update(repeating: 0, count: 9 * Self.maxSamplesPerRun) } }
    }
    private let partTap: UnsafeMutablePointer<Int32> = {
        let tap = UnsafeMutablePointer<Int32>.allocate(capacity: 9 * MT32Synth.maxSamplesPerRun)
        tap.initialize(repeating: 0, count: 9 * MT32Synth.maxSamplesPerRun)
        return tap
    }()
    private var tapPosition = 0
    /// The largest sample of each part since they were last taken.
    private let partPeaks: UnsafeMutablePointer<Int32> = {
        let peaks = UnsafeMutablePointer<Int32>.allocate(capacity: 9)
        peaks.initialize(repeating: 0, count: 9)
        return peaks
    }()
    private var mutedParts = [Bool](repeating: false, count: 9)
    private let scratch: UnsafeMutablePointer<Int16> = {
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * MT32Synth.maxSamplesPerRun)
        scratch.initialize(repeating: 0, count: 2 * MT32Synth.maxSamplesPerRun)
        return scratch
    }()
    /// A bit for each part on which a note has been started since they were last taken.
    var noteStarts: UInt32 = 0

    /// Gives each part's sound of the last `render`, `count` of its own samples.
    public func takePartSamples(_ count: Int, _ body: (Int, UnsafePointer<Int32>) -> Void) {
        for part in 0 ..< 9 { body(part, partTap + part * Self.maxSamplesPerRun) }
    }

    /// Gives each part's largest sample since this was last asked.
    public func takePartLevels(_ body: (Int, Int32) -> Void) {
        for part in 0 ..< 9 {
            body(part, partPeaks[part])
            partPeaks[part] = 0
        }
    }

    /// The parts on which a note has been started since this was last asked, a bit for each.
    public func takePartNoteStarts() -> UInt32 {
        let starts = noteStarts
        noteStarts = 0
        return starts
    }

    /// The highest key of a part's notes not yet let go, or nil.
    public func highestKey(ofPart part: Int) -> Int? {
        var highest: Int?
        var poly = parts[part].firstActivePoly
        while let current = poly {
            if current.state != .releasing, current.key > highest ?? -1 { highest = current.key }
            poly = current.next
        }
        return highest
    }

    /// True if a part is playing a sound of the PCM ROM.
    public func isPartPlayingPCM(_ part: Int) -> Bool {
        partialManager.partials.contains { $0.ownerPart == part && $0.pcmWave != nil }
    }

    /// Leaves parts out of the sound: they play on, unheard (a mark for each of the nine).
    public func setMutedParts(_ muted: [Bool]) {
        mutedParts = (0 ..< 9).map { $0 < muted.count && muted[$0] }
    }

    /// The parts' notes sounding, and their keys: for showing each part's notes.
    public func notes(ofPart part: Int) -> [(key: Int, velocity: Int)] {
        var notes: [(key: Int, velocity: Int)] = []
        var poly = parts[part].firstActivePoly
        while let current = poly {
            notes.append((current.key, current.velocity))
            poly = current.next
        }
        return notes
    }

    /// True for a part with a note not yet let go.
    public func isPartPlaying(_ part: Int) -> Bool { parts[part].activeNonReleasingPartialCount > 0 }

    /// A part's pan, 0 (right) to 14 (left), as the MT-32 has it.
    public func pan(ofPart part: Int) -> Int { Int(memory.patchTempAddress(part)[MT32Memory.panpot]) }

    /// Which part each MIDI channel plays first, or nil.
    public func part(ofChannel channel: Int) -> Int? {
        chantable[channel][0] <= 8 ? Int(chantable[channel][0]) : nil
    }

    /// The part a partial is playing for, or nil.
    public func owner(ofPartial index: Int) -> Int? {
        let owner = partialManager.partials[index].ownerPart
        return owner >= 0 ? owner : nil
    }
}
