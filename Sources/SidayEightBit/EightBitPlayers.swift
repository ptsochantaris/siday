// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// The players of the 8-bit machines' music, and of the PC's FM chips: the ZX Spectrum's trackers,
/// recordings of the AY chip and AY files, the 8-bit Atari's SAP files, Sierra's AGI sounds, the AdLib's
/// CMF, ROL and FMT tunes, and VGM recordings.
///
/// The loader asks each family in turn for a player (`TuneLoader`): nil is for a tune of a format
/// that is not this family's.
package enum EightBitPlayers {
    package static func player(_ data: [UInt8], format: TuneFormat, path: String?, options: LoadOptions,
                               companions: [[UInt8]?]) throws -> (any Renderer)? {
        switch format {
        case .vtx:
            return try AYFramePlayer(source: RegisterDumpSource.vtx(data), options: options)
        case .ym:
            // (A recording made on an Atari ST, played on the ST's chip, or a YM file of samples, is the
            // Atari's: see `AtariPlayers`.)
            return try AYFramePlayer(source: RegisterDumpSource.ym(data), options: options)
        case .pt3, .pt2, .pt1, .stc, .stp, .asc, .sqt, .psc, .ftc, .fxm, .psm, .gtr:
            if let (type1, module1, type2, module2) = TurboSoundPair.split(data) {
                let pair = try TurboSoundPair(trackerSource(module1, format: type1), trackerSource(module2, format: type2))
                return AYFramePlayer(source: pair, options: options)
            }
            return try trackerPlayer(data, format: format, options)
        case .ay:
            return try AYFileRenderer(data, options: options)
        case .sap:
            return try SAPRenderer(data, options: options)
        case .agi:
            // A sound from one of Sierra's adventure games, as the Amiga versions played it or on the
            // PC's chip, as the options say.
            return try AGIFile.renderer(data, options: options)
        case .cmf:
            return try CMFTune.renderer(data)
        case .rol:
            // Its instruments from the banks found for it, its own first.
            return try ROLTune.renderer(data, banks: companions.compactMap { $0.map { AdLibBank($0) } })
        case .fmt:
            return try FMTTune.renderer(data)
        case .vgm:
            // What was written to the AdLib's or Sound Blaster's FM chip, and when. (A VGZ file has
            // been unpacked by the loader.)
            return try VGMRenderer(data, options: options)
        default:
            return nil
        }
    }

    /// One player per kind of module, each built for its own source type. (Handing `trackerSource`'s
    /// result to a generic player would need the type at run time, which Embedded Swift does not have.)
    private static func trackerPlayer(_ data: [UInt8], format: TuneFormat, _ options: LoadOptions) throws -> any Renderer {
        switch format {
        case .pt3: return try AYFramePlayer(source: PT3Source(data), options: options)
        case .pt2: return try AYFramePlayer(source: PT2Source(data), options: options)
        case .pt1: return try AYFramePlayer(source: PT1Source(data), options: options)
        case .stc: return try AYFramePlayer(source: STCSource(data), options: options)
        case .stp: return try AYFramePlayer(source: STPSource(data), options: options)
        case .sqt: return try AYFramePlayer(source: SQTSource(data), options: options)
        case .asc: return try AYFramePlayer(source: ASCSource(data), options: options)
        case .psc: return try AYFramePlayer(source: PSCSource(data), options: options)
        case .ftc: return try AYFramePlayer(source: FTCSource(data), options: options)
        case .fxm: return try AYFramePlayer(source: FXMSource(data), options: options)
        case .psm: return try AYFramePlayer(source: PSMSource(data), options: options)
        case .gtr: return try AYFramePlayer(source: GTRSource(data), options: options)
        default: throw TuneError.unsupported("\(format.rawValue.uppercased()) is not a tracker module format")
        }
    }

    static func trackerSource(_ data: [UInt8], format: TuneFormat) throws -> any AYFrameSource {
        switch format {
        case .pt3: return try PT3Source(data)
        case .pt2: return try PT2Source(data)
        case .pt1: return try PT1Source(data)
        case .stc: return try STCSource(data)
        case .stp: return try STPSource(data)
        case .sqt: return try SQTSource(data)
        case .asc: return try ASCSource(data)
        case .psc: return try PSCSource(data)
        case .ftc: return try FTCSource(data)
        case .fxm: return try FXMSource(data)
        case .psm: return try PSMSource(data)
        case .gtr: return try GTRSource(data)
        default: throw TuneError.unsupported("\(format.rawValue.uppercased()) is not a tracker module format")
        }
    }
}
