// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayKit
import Synchronization

// SidayKit works on bytes and reads no files. This is the part of loading that needs a file system:
// reading a tune from disk, and finding HVSC's song-length database for it.

extension TuneFormat {
    /// (By what follows the last full stop of the name, whatever is before it: there is a tune
    /// called `...pt3`, which to the system is a file of no kind.)
    init?(url: URL) {
        let name = url.lastPathComponent
        guard let stop = name.lastIndex(of: ".") else { return nil }
        self.init(fileExtension: String(name[name.index(after: stop)...]))
    }
}

/// Loads tunes from files.
struct TuneFiles: Sendable {
    var options = LoadOptions()
    /// A song-length database named by the user, tried before the one beside the tune.
    var songLengthsPath: String?

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
            options.songLengths = SongLengthFiles.find(explicitPath: songLengthsPath, near: url)
        }
        return try TuneLoader.load([UInt8](data), format: format, path: url.standardizedFileURL.path, options: options,
                                   companions: CompanionFiles.find(for: url, format: format))
    }
}

/// The files on disk that tunes need beside their own (see `Companions`): the samples some keep in
/// a file of their own, the instrument banks of ROL files. They are looked for in the tune's folder,
/// each folder looked through once and each file read once.
enum CompanionFiles {
    private static let folders = Mutex<[String: FileFinder]>([:])
    private static let files = Mutex<[String: [UInt8]]>([:])

    /// One for each of the files a tune of its kind needs, in the order `Companions` gives them; nil
    /// for one that is not there.
    static func find(for tune: URL, format: TuneFormat) -> [[UInt8]?] {
        let wanted = Companions.wanted(for: format, fileName: tune.lastPathComponent)
        guard !wanted.isEmpty else { return [] }
        let folder = tune.standardizedFileURL.deletingLastPathComponent()
        let beside = folders.withLock { known -> FileFinder in
            if let listed = known[folder.path] { return listed }
            // (Every file, since a companion may have any name: Amberstar's samples are also kept as
            // `samp.hipc`.)
            let listed = FileFinder((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            known[folder.path] = listed
            return listed
        }
        return wanted.map { companion in
            guard let place = Companions.find(companion, for: tune.lastPathComponent, among: beside) else { return nil }
            let file = folder.appendingPathComponent(beside.paths[place]).path
            if let read = files.withLock({ $0[file] }) { return read }
            guard let data = FileManager.default.contents(atPath: file) else { return nil }
            files.withLock { $0[file] = [UInt8](data) }
            return [UInt8](data)
        }
    }
}

/// HVSC's `Songlengths.md5` on disk. Each file is read once.
enum SongLengthFiles {
    private static let cache = Mutex<[String: SongLengthDatabase?]>([:])

    /// The database at an explicit path, or the one found in a `DOCUMENTS` folder above the tune.
    static func find(explicitPath: String?, near url: URL?) -> SongLengthDatabase? {
        if let explicitPath, let database = database(atPath: explicitPath) {
            return database
        }
        guard var folder = url?.standardizedFileURL.deletingLastPathComponent() else { return nil }
        for _ in 0 ..< 8 {
            let candidate = folder.appendingPathComponent("DOCUMENTS/Songlengths.md5").path
            if let database = database(atPath: candidate) { return database }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return nil
    }

    /// The database in the file at `path`. A file with no lengths in it is not one: were it taken for
    /// one, naming it would stop the search beside the tune and every length would go unfound.
    static func database(atPath path: String) -> SongLengthDatabase? {
        if let cached = cache.withLock({ $0[path] }) { return cached }
        var database: SongLengthDatabase?
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
            let read = SongLengthDatabase([UInt8](data))
            if !read.isEmpty { database = read }
        }
        cache.withLock { $0[path] = .some(database) }
        return database
    }
}
