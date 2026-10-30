// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayFiles
import SidayPlayer

/// The files and folders the listener has given the app, which it may read: a sandboxed app sees only
/// those. Each is kept as a bookmark, so that the list of tunes is there again the next time the app
/// is opened, and so are the folders a tune's companions were found in.
nonisolated final class Library: @unchecked Sendable {
    /// A file or folder the listener gave, and the access to it that the system gave with it. The
    /// access is the URL's that came from the system, and not another's to the same place: on an
    /// iPhone or iPad, one made again from its path is given none.
    struct Root {
        var url: URL
        var bookmark: Data
        var given: URL
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
    func add(_ given: URL) -> Int {
        let accessing = given.startAccessingSecurityScopedResource()
        let url = Self.plain(given)
        if let place = roots.firstIndex(where: { $0.url == url }) {
            if accessing { given.stopAccessingSecurityScopedResource() }
            return place
        }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = (try? given.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        roots.append(Root(url: url, bookmark: bookmark, given: given, accessing: accessing))
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
        if let place = roots.firstIndex(where: { $0.url == plain }) {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return place
        }
        roots.append(Root(url: plain, bookmark: bookmark, given: url, accessing: accessing))
        return roots.count - 1
    }

    /// Keeps a copy of a file or folder the system gave only for a moment, in a folder of its own
    /// among the app's files (so that it keeps its name beside other copies of the same name).
    static func keep(_ given: URL) throws -> URL {
        let folder = store.deletingLastPathComponent().appendingPathComponent("Dropped", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent(given.lastPathComponent)
        try FileManager.default.copyItem(at: given, to: kept)
        return kept
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
                root.given.stopAccessingSecurityScopedResource()
            }
        }
        roots = kept
    }
}

/// Reading tunes and the files they need beside them (SidayFiles' `CompanionFiles`). Each folder is
/// looked through once, as long as the app is open.
nonisolated enum TuneFiles {
    /// What is read for a tune: its bytes, and one for each of the files its kind needs beside it, in
    /// the order `Companions` gives them, nil for one that is not there; of those it cannot be played
    /// without, the first that was not found; and of those it may want, the first that could not be
    /// looked for, because the app has not been let read the tune's folder (a file opened alone).
    struct Read: Sendable {
        var bytes: [UInt8]
        var companions: [[UInt8]?]
        var missing: Companion?
        var unlooked: Companion?
    }

    static func read(_ url: URL) throws -> Read {
        let bytes = [UInt8](try Coordinated.data(url))
        guard let format = TuneFormat(url: url) else { return Read(bytes: bytes, companions: [], missing: nil) }
        let (companions, missing) = CompanionFiles.read(for: url, format: format)
        var unlooked: Companion?
        if missing == nil, companions.contains(where: { $0 == nil }), !CompanionFiles.canLook(beside: url) {
            let wanted = Companions.wanted(for: format, fileName: url.lastPathComponent)
            unlooked = wanted.indices.first { companions[$0] == nil }.map { wanted[$0] }
        }
        return Read(bytes: bytes, companions: companions, missing: missing, unlooked: unlooked)
    }

    /// Forgets what was seen of a folder: it may since have been given to the app.
    static func forget(_ folder: URL) {
        CompanionFiles.forget(folder)
    }
}
