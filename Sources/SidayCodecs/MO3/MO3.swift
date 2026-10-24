// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_mo3.cpp`), Copyright (c) 2004-2026 OpenMPT Project
// Developers and Contributors, used under the BSD 3-Clause licence (see THIRD-PARTY.md), whose MO3
// unpacking is based on UNMO3 by Laurent Clévy, relicensed to BSD with his permission.

import SidayFoundation

/// Un4seen's MO3 (Ian Luck's, of BASS): an IT, XM, S3M, MOD or MTM module, its music LZ-packed and
/// its samples packed without loss (as deltas) or with it (as MP3 or Ogg Vorbis).
///
/// siday plays one by making again, in memory, the module it was made from, every sample decoded,
/// as Un4seen's own UNMO3 does; the module is then played as any IT, XM, S3M, MOD or MTM is, by the
/// tracker that made it. The file is read as libopenmpt's `ReadMO3` reads it, and the module written
/// as OpenMPT's own savers write each format, with what the MO3 keeps of the file's maker (its
/// tracker version, an XM's tracker name) put back where the format keeps it.
public enum MO3 {
    /// True if the bytes begin as an MO3 file does (Load_mo3.cpp's ValidateHeader).
    public static func isOne(_ data: [UInt8]) -> Bool { MO3Song.validHeader(data) }

    /// The module the file was made from, rebuilt, and what kind it is.
    public static func unpacked(_ data: [UInt8]) throws(TuneError) -> MO3Module {
        var (song, infos, sampleStart) = try MO3Song.read(data)
        song.readSamples(data, infos: &infos, from: sampleStart)
        return song.module()
    }
}

public struct MO3Module: Sendable {
    /// A whole IT, XM, S3M, MOD or MTM file (or MPTM, for an MO3 made from one).
    public var bytes: [UInt8]
    /// .it, .xm, .s3m, .mod, .mtm or .mptm.
    public var format: TuneFormat
    /// The MO3 container's version, 0...5.
    public var version: Int
    /// What could not be carried over, one sentence each, as `TuneInfo.shortfalls` are worded.
    public var shortfalls: [String]
}

extension MO3Song {
    /// The module, written in its own format.
    func module() -> MO3Module {
        var notes = shortfalls
        let bytes: [UInt8]
        let format: TuneFormat
        switch kind {
        case .it:
            bytes = writeIT(&notes)
            format = isMPTM ? .mptm : .it
        case .xm:
            bytes = writeXM(&notes)
            format = .xm
        case .s3m:
            bytes = writeS3M(&notes)
            format = .s3m
        case .mod:
            bytes = writeMOD(&notes)
            format = .mod
        case .mtm:
            bytes = writeMTM(&notes)
            format = .mtm
        }
        var seen: [String] = []
        for n in notes where !seen.contains(n) { seen.append(n) }
        return MO3Module(bytes: bytes, format: format, version: Int(version), shortfalls: seen)
    }
}
