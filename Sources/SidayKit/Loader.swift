// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

public enum TuneFormat: String, CaseIterable, Sendable {
    case pt3, pt2, pt1, stc, stp, asc, sqt, psc, ftc, fxm, psm, gtr
    case vtx, ym, ay, sid

    public init?(url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }
}

public enum TuneLoader {
    public static func load(_ url: URL, options: LoadOptions = LoadOptions()) throws -> any Renderer {
        guard let format = TuneFormat(url: url) else {
            throw TuneError.unsupported("unknown file type .\(url.pathExtension)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TuneError.unreadable(error.localizedDescription)
        }
        guard !data.isEmpty else { throw TuneError.malformed("empty file") }
        return try load(data, format: format, url: url, options: options)
    }

    public static func load(_ data: Data, format: TuneFormat, url: URL? = nil, options: LoadOptions = LoadOptions()) throws -> any Renderer {
        switch format {
        case .vtx:
            return try AYFramePlayer(source: RegisterDumpSource.vtx(data), options: options)
        case .ym:
            return try AYFramePlayer(source: RegisterDumpSource.ym(data), options: options)
        case .pt3, .pt2, .pt1, .stc, .stp, .asc, .sqt, .psc, .ftc, .fxm, .psm, .gtr:
            if let (type1, module1, type2, module2) = TurboSoundPair.split(data) {
                let pair = try TurboSoundPair(trackerSource(module1, format: type1), trackerSource(module2, format: type2))
                return AYFramePlayer(source: pair, options: options)
            }
            return try framePlayer(trackerSource(data, format: format), options)
        case .ay:
            return try AYFileRenderer(data, options: options)
        case .sid:
            return try SIDRenderer(data, url: url, options: options)
        }
    }

    private static func framePlayer(_ source: some AYFrameSource, _ options: LoadOptions) -> any Renderer {
        AYFramePlayer(source: source, options: options)
    }

    static func trackerSource(_ data: Data, format: TuneFormat) throws -> any AYFrameSource {
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
