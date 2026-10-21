// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayKit

/// The files and folders the listener has given the app, which it may read: a sandboxed app sees only
/// those. Each is kept as a bookmark, so that the list of tunes is there again the next time the app
/// is opened, and so are the folders a tune's companions were found in.
nonisolated final class Library: @unchecked Sendable {
    /// A file or folder the listener gave, and the access to it that the system gave with it.
    struct Root {
        var url: URL
        var bookmark: Data
        var accessing: Bool
    }

    private(set) var roots: [Root] = []

    /// Where the bookmarks and the list are kept between visits.
    static let store: URL = {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return folder.appendingPathComponent("Library.plist")
    }()

    /// Takes a file or folder the system gave the app (from a picker, a drop, or a file opened with
    /// it) as one it may go on reading. Returns its place among the roots.
    @discardableResult
    func add(_ url: URL) -> Int {
        let url = Self.plain(url)
        if let place = roots.firstIndex(where: { $0.url == url }) { return place }
        let accessing = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = (try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        roots.append(Root(url: url, bookmark: bookmark, accessing: accessing))
        return roots.count - 1
    }

    /// Brings back a root kept from an earlier visit; nil if the system no longer gives it.
    func restore(_ bookmark: Data) -> Int? {
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        let plain = Self.plain(url)
        if let place = roots.firstIndex(where: { $0.url == plain }) { return place }
        roots.append(Root(url: plain, bookmark: bookmark, accessing: accessing))
        return roots.count - 1
    }

    /// A file's URL as roots and tunes are compared by: its links followed, so that one way to a file
    /// is the same as another (`/tmp` is `/private/tmp`).
    static func plain(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The place of the root a file is, or is inside; nil if it is none of them.
    func root(of url: URL) -> Int? {
        let path = Self.plain(url).path
        return roots.indices.first { path == roots[$0].url.path || path.hasPrefix(roots[$0].url.path.hasSuffix("/") ? roots[$0].url.path : roots[$0].url.path + "/") }
    }

    /// Lets go of every root but those still wanted.
    func keep(only wanted: Set<Int>) {
        var kept: [Root] = []
        for (place, root) in roots.enumerated() {
            if wanted.contains(place) {
                kept.append(root)
            } else if root.accessing {
                root.url.stopAccessingSecurityScopedResource()
            }
        }
        roots = kept
    }
}

/// Reading tunes and the files they need beside them. Each folder is looked through once, and each
/// companion read once, as long as the app is open.
nonisolated enum TuneFiles {
    /// What is read for a tune: its bytes, and one for each of the files its kind needs beside it, in
    /// the order `Companions` gives them, nil for one that is not there; and of those it cannot be
    /// played without, the first that was not found.
    struct Read: Sendable {
        var bytes: [UInt8]
        var companions: [[UInt8]?]
        var missing: Companion?
    }

    nonisolated(unsafe) private static var folders: [String: FileFinder] = [:]
    private static let lock = NSLock()

    static func read(_ url: URL) throws -> Read {
        let bytes = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
        let name = url.lastPathComponent
        guard let format = TuneFormat(fileExtension: url.pathExtension) else { return Read(bytes: bytes, companions: [], missing: nil) }
        let wanted = Companions.wanted(for: format, fileName: name)
        guard !wanted.isEmpty else { return Read(bytes: bytes, companions: [], missing: nil) }
        let folder = url.deletingLastPathComponent()
        let beside = finder(for: folder)
        let companions: [[UInt8]?] = wanted.map { companion in
            if companion.folder { return self.folder(companion, beside: folder, among: beside) }
            guard let place = Companions.find(companion, for: name, among: beside) else { return nil }
            return (try? Data(contentsOf: folder.appendingPathComponent(beside.paths[place]), options: .mappedIfSafe)).map { [UInt8]($0) }
        }
        let missing = wanted.indices.first { wanted[$0].required && companions[$0] == nil }.map { wanted[$0] }
        return Read(bytes: bytes, companions: companions, missing: missing)
    }

    /// Forgets what was seen of a folder: it may since have been given to the app.
    static func forget(_ folder: URL) {
        lock.withLock { _ = folders.removeValue(forKey: folder.standardizedFileURL.path) }
    }

    private static func finder(for folder: URL) -> FileFinder {
        let key = folder.standardizedFileURL.path
        if let known = lock.withLock({ folders[key] }) { return known }
        // (Every file, since a companion may have any name.)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let finder = FileFinder(names)
        // (A folder that cannot be read yet is not kept as empty: the listener may give it.)
        if !names.isEmpty { lock.withLock { folders[key] = finder } }
        return finder
    }

    /// The files of a folder a tune needs beside it, packed as `CompanionFolder.pack` has them.
    private static func folder(_ companion: Companion, beside tunes: URL, among beside: FileFinder) -> [UInt8]? {
        for name in companion.names {
            guard let found = beside.paths.first(where: { FileFinder.plain($0) == FileFinder.plain(name) }) else { continue }
            let inside = tunes.appendingPathComponent(found, isDirectory: true)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: inside.path)) ?? []).sorted()
            let packed: [(name: String, bytes: [UInt8])] = names.compactMap { name in
                let file = inside.appendingPathComponent(name)
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
                return (name, [UInt8](data))
            }
            if !packed.isEmpty { return CompanionFolder.pack(packed) }
        }
        return nil
    }

    /// The tunes and playlists in a folder and the folders inside it, in order, and any
    /// `Songlengths.md5`; companions and other files are passed over.
    static func contents(of folder: URL) -> (tunes: [URL], playlists: [URL], songLengths: URL?) {
        var tunes: [URL] = []
        var playlists: [URL] = []
        var songLengths: URL?
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return ([], [], nil) }
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            let ending = url.pathExtension
            if url.lastPathComponent.lowercased() == "songlengths.md5" {
                songLengths = url
            } else if PlaylistFile.reads(fileExtension: ending) {
                playlists.append(url)
            } else if !Companions.are(fileName: url.lastPathComponent), TuneFormat(fileExtension: ending) != nil {
                tunes.append(url)
            }
        }
        let byPath: (URL, URL) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (tunes.sorted(by: byPath), playlists.sorted(by: byPath), songLengths)
    }
}
