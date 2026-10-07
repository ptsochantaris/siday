// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

public enum TuneFormat: String, CaseIterable, Sendable {
    case pt3, pt2, pt1, stc, stp, asc, sqt, psc, ftc, fxm, psm, gtr
    case vtx, ym, ay, sid, sndh

    /// The format a file name's extension stands for, in any case.
    public init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }
}

/// Makes a player for a tune from the bytes of its file. The library reads no files itself: whoever
/// uses it brings the bytes, from a disk, a download or anywhere else.
public enum TuneLoader {
    /// - Parameter path: where the file came from, if it is known. A SID tune missing from the song-length
    ///   database by content is looked up by its place in the HVSC collection instead.
    public static func load(_ data: [UInt8], format: TuneFormat, path: String? = nil, options: LoadOptions = LoadOptions()) throws -> any Renderer {
        guard !data.isEmpty else { throw TuneError.malformed("empty file") }
        switch format {
        case .vtx:
            return try AYFramePlayer(source: RegisterDumpSource.vtx(data), options: options)
        case .ym:
            // A recording made on an Atari ST is played on the ST's chip, with the effects ST musicians
            // made between one set of registers and the next, unless a chip, clock or rate has been
            // asked for, which is to ask for the plain recording on a chip of one's own choosing.
            if options.chipType == nil, options.clockHz == nil, options.frameHz == nil, let atari = STYMRenderer(data) {
                return atari
            }
            // And two kinds of YM file are not recordings of the chip at all, but samples.
            if let sampled = STSampleRenderer(data) { return sampled }
            return try AYFramePlayer(source: RegisterDumpSource.ym(data), options: options)
        case .pt3, .pt2, .pt1, .stc, .stp, .asc, .sqt, .psc, .ftc, .fxm, .psm, .gtr:
            if let (type1, module1, type2, module2) = TurboSoundPair.split(data) {
                let pair = try TurboSoundPair(trackerSource(module1, format: type1), trackerSource(module2, format: type2))
                return AYFramePlayer(source: pair, options: options)
            }
            return try trackerPlayer(data, format: format, options)
        case .ay:
            return try AYFileRenderer(data, options: options)
        case .sid:
            return try SIDRenderer(data, path: path, options: options)
        case .sndh:
            return try SNDHRenderer(data, options: options)
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
