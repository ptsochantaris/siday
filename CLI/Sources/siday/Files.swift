// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayFiles
import SidayPlayer

// SidayKit works on bytes and reads no files. This is the part of loading that needs a file system:
// reading a tune from disk, and finding HVSC's song-length database for it.

/// Loads tunes from files.
struct TuneFiles: Sendable {
    var options = LoadOptions()
    /// A song-length database named by the user, tried before the one beside the tune.
    var songLengthsPath: String?
    /// The one siday keeps (see `KeptFiles`), tried after both.
    var keptSongLengths: SongLengthDatabase?

    func load(_ url: URL) throws -> any Renderer {
        guard let format = TuneFormat(url: url) else {
            throw TuneError.unsupported("unknown file type .\(url.pathExtension)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TuneError.unreadable(error.localizedDescription)
        }
        var options = options
        if format == .sid {
            options.songLengths = SongLengthFiles.find(explicitPath: songLengthsPath, near: url) ?? keptSongLengths
        }
        return try TuneLoader.load([UInt8](data), format: format, path: url.standardizedFileURL.path, options: options,
                                   companions: CompanionFiles.read(for: url, format: format).companions)
    }
}
