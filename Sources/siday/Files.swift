// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayKit
import Synchronization

// SidayKit works on bytes and reads no files. This is the part of loading that needs a file system:
// reading a tune from disk, and finding HVSC's song-length database for it.

extension TuneFormat {
    init?(url: URL) {
        self.init(fileExtension: url.pathExtension)
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
        if format == .rol {
            options.adLibBanks = BankFiles.find(for: url)
        }
        return try TuneLoader.load([UInt8](data), format: format, path: url.standardizedFileURL.path, options: options)
    }
}

/// AdLib instrument banks on disk, for ROL files. Each folder is looked through once and each bank read once.
enum BankFiles {
    private static let folders = Mutex<[String: [String: URL]]>([:])
    private static let banks = Mutex<[String: AdLibBank]>([:])

    /// The banks beside a ROL file: one of the tune's own name, and then `STANDARD.BNK`, in capitals
    /// or small letters.
    static func find(for tune: URL) -> [AdLibBank] {
        let folder = tune.standardizedFileURL.deletingLastPathComponent()
        let beside = folders.withLock { known -> [String: URL] in
            if let listed = known[folder.path] { return listed }
            var listed: [String: URL] = [:]
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where file.pathExtension.lowercased() == "bnk" {
                listed[file.lastPathComponent.lowercased()] = file
            }
            known[folder.path] = listed
            return listed
        }
        let own = tune.deletingPathExtension().lastPathComponent.lowercased() + ".bnk"
        var found: [AdLibBank] = []
        for name in own == "standard.bnk" ? [own] : [own, "standard.bnk"] {
            guard let file = beside[name] else { continue }
            if let read = banks.withLock({ $0[file.path] }) {
                found.append(read)
            } else if let data = try? Data(contentsOf: file) {
                let read = AdLibBank([UInt8](data))
                banks.withLock { $0[file.path] = read }
                found.append(read)
            }
        }
        return found
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
