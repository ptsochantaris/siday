// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayFoundation
import SidayPlayer
import Synchronization

/// The files on disk that tunes need beside their own (see `Companions`): the samples some keep in
/// a file of their own, the instrument banks of ROL files, the folder of instruments of a Sonix
/// score. They are looked for in the tune's folder, each folder looked through once.
public enum CompanionFiles {
    private static let folders = Mutex<[String: FileFinder]>([:])

    /// One for each of the files a tune of its kind needs, in the order `Companions` gives them, nil
    /// for one that is not there; and of those it cannot be played without, the first that was not found.
    public static func read(for tune: URL, format: TuneFormat) -> (companions: [[UInt8]?], missing: Companion?) {
        let name = tune.lastPathComponent
        let wanted = Companions.wanted(for: format, fileName: name)
        guard !wanted.isEmpty else { return ([], nil) }
        let folder = tune.standardizedFileURL.deletingLastPathComponent()
        let beside = finder(for: folder)
        let companions: [[UInt8]?] = wanted.map { companion in
            if companion.folder { return Self.folder(companion, beside: folder, among: beside) }
            guard let place = Companions.find(companion, for: name, among: beside) else { return nil }
            return (try? Coordinated.data(folder.appendingPathComponent(beside.paths[place]))).map { [UInt8]($0) }
        }
        let missing = wanted.indices.first { wanted[$0].required && companions[$0] == nil }.map { wanted[$0] }
        return (companions, missing)
    }

    /// Forgets what was seen of a folder: what is in it may have changed, or the player may since
    /// have been let read it.
    public static func forget(_ folder: URL) {
        _ = folders.withLock { $0.removeValue(forKey: folder.standardizedFileURL.path) }
    }

    private static func finder(for folder: URL) -> FileFinder {
        let key = folder.path
        if let known = folders.withLock({ $0[key] }) { return known }
        // (Every file, since a companion may have any name: Amberstar's samples are also kept as
        // `samp.hipc`.)
        let names = Coordinated.names(in: folder)
        let finder = FileFinder(names)
        // (A folder that cannot be read yet is not kept as empty: the listener may give it.)
        if !names.isEmpty { folders.withLock { $0[key] = finder } }
        return finder
    }

    /// The files of a folder a tune needs beside it, packed as `CompanionFolder.pack` has them: those
    /// of the first folder of the companion's names, in any case, that has any. Nil if none has.
    private static func folder(_ companion: Companion, beside tunes: URL, among beside: FileFinder) -> [UInt8]? {
        for name in companion.names {
            guard let found = beside.paths.first(where: { FileFinder.plain($0) == FileFinder.plain(name) }) else { continue }
            let inside = tunes.appendingPathComponent(found, isDirectory: true)
            let names = Coordinated.names(in: inside).sorted()
            let packed: [(name: String, bytes: [UInt8])] = names.compactMap { name in
                let file = inside.appendingPathComponent(name)
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let data = try? Coordinated.data(file) else { return nil }
                return (name, [UInt8](data))
            }
            if !packed.isEmpty { return CompanionFolder.pack(packed) }
        }
        return nil
    }
}

/// HVSC's `Songlengths.md5` on disk. Each file is read once.
public enum SongLengthFiles {
    private static let cache = Mutex<[String: SongLengthDatabase?]>([:])

    /// The database at an explicit path, or the one found in a `DOCUMENTS` folder above the tune.
    public static func find(explicitPath: String?, near url: URL?) -> SongLengthDatabase? {
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
    public static func database(atPath path: String) -> SongLengthDatabase? {
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
