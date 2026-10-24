// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_mo3.cpp`, `modcommand.h`, `ModInstrument.h`, `ModSample.h`,
// `MIDIMacros.cpp`), Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors, used under
// the BSD 3-Clause licence (see THIRD-PARTY.md).

/// What an MO3 file holds, as libopenmpt holds it once `ReadMO3` has read it: its pattern cells,
/// instruments and samples in OpenMPT's own terms, which the writers then put back into the terms
/// of the format the module was made in.
struct MO3Song {
    enum Kind { case it, xm, s3m, mod, mtm }

    var kind = Kind.xm
    var version: UInt8 = 0
    var name: [UInt8] = []
    var message: [UInt8] = []
    var channels = 0
    /// Pattern numbers, with `MO3Song.skipOrder` (+++) and `MO3Song.stopOrder` (---).
    var orders: [UInt16] = []
    var restart: UInt16 = 0
    var speed: UInt32 = 6
    var tempo: UInt32 = 125
    var linearSlides = false, amigaLimits = false, fastVolumeSlides = false, itOldEffects = false
    var itCompatibleGxx = false, extendedFilterRange = false, vblankTiming = false, isAmiga = false
    /// Whether ModPlug's own ways were asked for (`modplugMode`), and so what it changes.
    var modPlugMode = false
    /// 0...256, as OpenMPT keeps it.
    var globalVolume: UInt32 = 256
    var samplePreAmp: UInt32 = 48
    /// IT's pan separation, which libopenmpt does not use from an MO3.
    var panSeparation: UInt8 = 128
    var channelVolume = [UInt8](repeating: 64, count: 64)
    /// 0...256; and whether the channel is surround.
    var channelPan = [UInt16](repeating: 128, count: 64)
    var channelSurround = [Bool](repeating: false, count: 64)
    /// The MIDI macros: 9 global, 16 SFx, 128 Zxx, 32 bytes each, as `MIDIMacroConfigData` is.
    var macros = MO3Song.defaultMacros
    var patterns: [Pattern?] = []
    var instruments: [Instrument] = []
    /// False when an IT, S3M or MTM is in sample mode: its instrument headers are in the file and are
    /// passed over.
    var instrumentMode = false
    var samples: [Sample] = []

    // VERS, PRHI, OMPT and the plug-ins.
    var cwtv: UInt16 = 0, cmwt: UInt16 = 0
    var hasVersion = false
    var trackerName: [UInt8] = []
    var mtmVersion: UInt8? = nil
    var rowsPerBeat: UInt32? = nil, rowsPerMeasure: UInt32? = nil
    var hasMIDIChunk = false
    var patternNames: [[UInt8]] = []
    var channelNames: [[UInt8]] = []
    /// The OMPT chunk from where its pattern and channel names end: OpenMPT's instrument and song
    /// extensions ("XTPM", "STPM"), and for an MPTM file, after them, its own data ("228").
    var extensions: [UInt8] = []
    var isMPTM = false
    var plugIns: [(index: Int, data: [UInt8])] = []
    var channelPlugIns: [UInt32]? = nil

    var shortfalls: [String] = []

    static let skipOrder: UInt16 = 0xFFFE
    static let stopOrder: UInt16 = 0xFFFF

    struct Cell: Equatable {
        var note: UInt8 = 0, instr: UInt8 = 0, volcmd: UInt8 = 0, vol: UInt8 = 0, command: UInt8 = 0, param: UInt8 = 0
        var isEmpty: Bool { note == 0 && instr == 0 && volcmd == 0 && command == 0 }
    }

    struct Pattern {
        var rows: Int
        var cells: [Cell]
    }

    struct EnvelopeNode {
        var tick: UInt16
        var value: UInt8
    }

    struct Envelope {
        var enabled = false, sustain = false, loop = false, filter = false, carry = false
        var nodes: [EnvelopeNode] = []
        var loopStart: UInt8 = 0, loopEnd: UInt8 = 0, sustainStart: UInt8 = 0, sustainEnd: UInt8 = 0
    }

    struct Instrument {
        var exists = false
        var name: [UInt8] = [], filename: [UInt8] = []
        var noteMap = [UInt8](unsafeUninitializedCapacity: 120) { b, n in
            for i in 0 ..< 120 { b[i] = UInt8(i + 1) }
            n = 120
        }
        var keyboard = [UInt16](repeating: 0, count: 120)
        var volumeEnvelope = Envelope(), panEnvelope = Envelope(), pitchEnvelope = Envelope()
        var fadeOut: UInt32 = 256
        var globalVolume: UInt32 = 64
        var pan: UInt32 = 128
        var setPan = false
        var nna: UInt8 = 0, dct: UInt8 = 0, dna: UInt8 = 0
        var pps: Int8 = 0
        var ppc: UInt8 = 60
        var volSwing: UInt8 = 0, panSwing: UInt8 = 0
        /// Value 0...127, and 0x80 if it is used, as OpenMPT keeps them.
        var cutoff: UInt8 = 0, resonance: UInt8 = 0
        var midiBank: UInt16 = 0, midiProgram: UInt8 = 0, midiChannel: UInt8 = 0
        var midiPitchWheelDepth: Int8 = 2
        var plugIn: UInt32 = 0
        /// XM's auto-vibrato, which MO3 keeps with the instrument and libopenmpt moves to its samples.
        var vibrato: (type: UInt8, sweep: UInt8, depth: UInt8, rate: UInt8) = (0, 0, 0, 0)
    }

    struct Sample {
        var name: [UInt8] = [], filename: [UInt8] = []
        var c5Speed: UInt32 = 8363
        var fineTune: Int8 = 0
        var relativeTone: Int8 = 0
        var volume: UInt16 = 256
        var pan: UInt16 = 128
        var setPan = false
        var loop = false, pingPong = false, sustain = false, sustainPingPong = false
        var is16Bit = false, isStereo = false
        var length: UInt32 = 0, loopStart: UInt32 = 0, loopEnd: UInt32 = 0, sustainStart: UInt32 = 0, sustainEnd: UInt32 = 0
        var vibratoType: UInt8 = 0, vibratoSweep: UInt8 = 0, vibratoDepth: UInt8 = 0, vibratoRate: UInt8 = 0
        var globalVolume: UInt16 = 64
        /// For an XM, the instrument the sample was in (MO3Sample.globalVol).
        var xmInstrument: UInt8 = 0
        /// The sound, interleaved if stereo, as `is16Bit` says; nil if there is none.
        var data8: [Int8]? = nil
        var data16: [Int16]? = nil
        /// An OPL patch (S3M AdLib), 12 bytes.
        var adlib: [UInt8]? = nil

        var hasData: Bool { (data8 != nil || data16 != nil) && length > 0 }
    }

    // MIDIMacroConfig::Reset.
    static let defaultMacros: [UInt8] = {
        var m = [UInt8](repeating: 0, count: 153 * 32)
        func put(_ slot: Int, _ text: StaticString) {
            let p = text.utf8Start
            for i in 0 ..< text.utf8CodeUnitCount { m[slot * 32 + i] = p[i] }
        }
        put(0, "FF")
        put(1, "FC")
        put(3, "9c n v")
        put(4, "9c n 0")
        put(8, "Cc p")
        put(9, "F0F000z")
        let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
        for i in 0 ..< 16 {
            let base = (25 + i) * 32
            for (j, c) in "F0F001".utf8.enumerated() { m[base + j] = c }
            m[base + 6] = hex[(i * 8) >> 4]
            m[base + 7] = hex[(i * 8) & 15]
        }
        return m
    }()
}

/// OpenMPT's numbers for its commands (`EffectCommand`) and volume commands (`VolumeCommand`).
enum MO3Command {
    static let none: UInt8 = 0, arpeggio: UInt8 = 1, portamentoUp: UInt8 = 2, portamentoDown: UInt8 = 3
    static let tonePortamento: UInt8 = 4, vibrato: UInt8 = 5, tonePortaVol: UInt8 = 6, vibratoVol: UInt8 = 7
    static let tremolo: UInt8 = 8, panning8: UInt8 = 9, offset: UInt8 = 10, volumeSlide: UInt8 = 11
    static let positionJump: UInt8 = 12, volume: UInt8 = 13, patternBreak: UInt8 = 14, retrig: UInt8 = 15
    static let speed: UInt8 = 16, tempo: UInt8 = 17, tremor: UInt8 = 18, modCmdEx: UInt8 = 19, s3mCmdEx: UInt8 = 20
    static let channelVolume: UInt8 = 21, channelVolSlide: UInt8 = 22, globalVolume: UInt8 = 23
    static let globalVolSlide: UInt8 = 24, keyOff: UInt8 = 25, fineVibrato: UInt8 = 26, panbrello: UInt8 = 27
    static let xFinePortaUpDown: UInt8 = 28, panningSlide: UInt8 = 29, setEnvPosition: UInt8 = 30, midi: UInt8 = 31
    static let smoothMIDI: UInt8 = 32, delayCut: UInt8 = 33, xParam: UInt8 = 34, fineTune: UInt8 = 35
    static let fineTuneSmooth: UInt8 = 36, dummy: UInt8 = 37
}

enum MO3VolumeCommand {
    static let none: UInt8 = 0, volume: UInt8 = 1, panning: UInt8 = 2, volSlideUp: UInt8 = 3, volSlideDown: UInt8 = 4
    static let fineVolUp: UInt8 = 5, fineVolDown: UInt8 = 6, vibratoSpeed: UInt8 = 7, vibratoDepth: UInt8 = 8
    static let panSlideLeft: UInt8 = 9, panSlideRight: UInt8 = 10, tonePortamento: UInt8 = 11, portaUp: UInt8 = 12
    static let portaDown: UInt8 = 13, playControl: UInt8 = 14, offset: UInt8 = 15
}

enum MO3Note {
    static let none: UInt8 = 0, min: UInt8 = 1, middleC: UInt8 = 61
    static let keyOff: UInt8 = 0xFF, noteCut: UInt8 = 0xFE, fade: UInt8 = 0xFD, pc: UInt8 = 0xFC, pcs: UInt8 = 0xFB
    static func isNote(_ n: UInt8) -> Bool { n >= 1 && n <= 128 }
}
