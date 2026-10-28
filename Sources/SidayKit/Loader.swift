// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayAmigaComposers
import SidayAmigaMachine
import SidayAmigaTrackers
import SidayAtari
import SidayC64
import SidayCodecs
import SidayEightBit
import SidayFoundation
import SidayTrackers

public extension TuneFormat {
    /// The format a file of this kind is, by how it begins, where two formats share a name: Pro Sound
    /// Maker's files for the ZX Spectrum and Epic MegaGames' MASI files are both PSM files, and the
    /// second says what it is in its first bytes; and a SID file is the Commodore 64's, but for one of
    /// SidMon's for the Amiga, which begins with its player's code; and an Impulse Tracker file
    /// named as a MOD file, which says what it is in its first four letters, is an IT file. (`leading`
    /// is the start of the file, as much of it as there is up to `leadingBytes`.)
    func refined(byLeading leading: [UInt8]) -> TuneFormat {
        switch self {
        case .psm: TrackerPlayers.isMASI(leading) ? .masi : self
        // (SidMon's own check looks for its code further in too; those found begin with it.)
        case .sid: AmigaComposerPlayers.isSidMon1(leading) ? .sid1 : self
        case .mod: leading.starts(with: [0x49, 0x4D, 0x50, 0x4D]) ? .it : self // "IMPM"
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
    //
    // (This and each family's `player` are compiled in their own modules and only called from others.
    // In the web player's Embedded Swift any other function is compiled again in every module that
    // calls it, and from these every player there is can be reached: SidayKit, and each module of the
    // web player's that loads a tune, took minutes to build, each of them making every player anew.)
    @export(interface)
    public static func load(_ data: [UInt8], format: TuneFormat, path: String? = nil, options: LoadOptions = LoadOptions(),
                            companions: [[UInt8]?] = []) throws -> any Renderer {
        guard !data.isEmpty else { throw TuneError.malformed("empty file") }
        // A module packed whole, by any of the packers modules were found packed with, is unpacked
        // first, and is then the module it was.
        let data = try Packed.unpacked(data)
        let format = format.refined(byLeading: Array(data.prefix(TuneFormat.leadingBytes)))
        // An MO3 file is the module it was made from, packed: it is unpacked into that module again,
        // its samples decoded, and played as that module is.
        if format == .mo3 {
            let packed = try MO3.unpacked(data)
            return MO3Player(try load(packed.bytes, format: packed.format, path: path, options: options), packed: packed)
        }
        // Each family of players is asked in turn whether the tune is one of theirs: the Atari's first,
        // as a YM file recorded from an Atari ST is played on the ST's chip before any other. A module
        // of more voices than the Amiga's four is FastTracker 2's to play.
        let widerModule = { (module: [UInt8]) throws in try TrackerPlayers.player(module, format: .xm, path: path, options: options, companions: []) }
        let families: [([UInt8], TuneFormat, String?, LoadOptions, [[UInt8]?]) throws -> (any Renderer)?] = [
            AtariPlayers.player, EightBitPlayers.player, C64Players.player,
            { try AmigaTrackerPlayers.player($0, format: $1, path: $2, options: $3, companions: $4, widerModule: widerModule) },
            AmigaComposerPlayers.player, AmigaMachinePlayers.player, TrackerPlayers.player, RecordingPlayers.player,
        ]
        for family in families {
            if let player = try family(data, format, path, options, companions) { return player }
        }
        throw TuneError.unsupported("no player for \(format.rawValue.uppercased())")
    }
}

/// Which synthesiser a MIDI file is played on, found before it is played: for a list to show it by.
public enum MIDISynthesisers {
    /// True for a MIDI file written for the MT-32, by its own messages or by those of the file beside it
    /// that sets the MT-32 up (one of `Companions.wanted(for: .mid, fileName:)`), if it was found.
    @export(interface)
    public static func isWrittenForMT32(_ data: [UInt8], companion: [UInt8]?) -> Bool {
        EightBitPlayers.midiIsWrittenForMT32(data, companion: companion)
    }

    /// The chip a MIDI file is played on, by whether it was written for the MT-32 and whose ROMs are kept.
    public static func chip(writtenForMT32: Bool, mt32ROMs: Bool, sc55ROMs: Bool) -> SoundChip {
        EightBitPlayers.midiChip(writtenForMT32: writtenForMT32, mt32ROMs: mt32ROMs, sc55ROMs: sc55ROMs)
    }
}
