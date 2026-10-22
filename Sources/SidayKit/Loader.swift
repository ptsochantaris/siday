// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayAmigaComposers
import SidayAmigaMachine
import SidayAmigaTrackers
import SidayAtari
import SidayC64
import SidayEightBit
import SidayFoundation
import SidayTrackers

public extension TuneFormat {
    /// The format a file of this kind is, by how it begins, where two formats share a name: Pro Sound
    /// Maker's files for the ZX Spectrum and Epic MegaGames' MASI files are both PSM files, and the
    /// second says what it is in its first bytes; and a SID file is the Commodore 64's, but for one of
    /// SidMon's for the Amiga, which begins with its player's code. (`leading` is the start of the
    /// file, as much of it as there is up to `leadingBytes`.)
    func refined(byLeading leading: [UInt8]) -> TuneFormat {
        switch self {
        case .psm: TrackerPlayers.isMASI(leading) ? .masi : self
        // (SidMon's own check looks for its code further in too; those found begin with it.)
        case .sid: AmigaComposerPlayers.isSidMon1(leading) ? .sid1 : self
        default: self
        }
    }

    /// How much of the start of a file `refined(byLeading:)` looks at.
    static let leadingBytes = 64
}

/// Makes a player for a tune from the bytes of its file. The library reads no files itself: whoever
/// uses it brings the bytes, from a disk, a download or anywhere else.
public enum TuneLoader {
    /// - Parameter path: where the file came from, if it is known. A SID tune missing from the song-length
    ///   database by content is looked up by its place in the HVSC collection instead.
    /// - Parameter companions: the files the tune needs beside its own, for a kind that does: one for
    ///   each that `Companions.wanted(for:fileName:)` gives, in its order, nil for one that was not found.
    public static func load(_ data: [UInt8], format: TuneFormat, path: String? = nil, options: LoadOptions = LoadOptions(),
                            companions: [[UInt8]?] = []) throws -> any Renderer {
        guard !data.isEmpty else { throw TuneError.malformed("empty file") }
        // A module packed whole, by any of the packers modules were found packed with, is unpacked
        // first, and is then the module it was.
        let data = try Packed.unpacked(data)
        let format = format.refined(byLeading: Array(data.prefix(TuneFormat.leadingBytes)))
        // Each family of players is asked in turn whether the tune is one of theirs: the Atari's first,
        // as a YM file recorded from an Atari ST is played on the ST's chip before any other. A module
        // of more voices than the Amiga's four is FastTracker 2's to play.
        let widerModule = { (module: [UInt8]) in try? TrackerPlayers.player(module, format: .xm, path: path, options: options, companions: []) }
        let families: [([UInt8], TuneFormat, String?, LoadOptions, [[UInt8]?]) throws -> (any Renderer)?] = [
            AtariPlayers.player, EightBitPlayers.player, C64Players.player,
            { try AmigaTrackerPlayers.player($0, format: $1, path: $2, options: $3, companions: $4, widerModule: widerModule) },
            AmigaComposerPlayers.player, AmigaMachinePlayers.player, TrackerPlayers.player,
        ]
        for family in families {
            if let player = try family(data, format, path, options, companions) { return player }
        }
        throw TuneError.unsupported("no player for \(format.rawValue.uppercased())")
    }
}
