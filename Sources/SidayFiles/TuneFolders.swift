// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayFoundation
import SidayPlayer

// The tunes in the files and folders a listener gives a player that reads them from disk: the
// command-line player and the app. They are put in order by SidayPlayer's `TuneGathering`, as the
// web page puts the files it is given; what is here is the looking on disk.

/// The tunes on disk in what the listener gave: files, folders, playlists.
public enum TuneFolders {
    public struct Found: Sendable {
        /// The tunes, in the order they are played.
        public var tunes: [URL] = []
        /// What the playlist a tune came by says of it.
        public var notes: [URL: String] = [:]
        /// Of the tunes playlists named, how many, and how many were not there to be found; and the
        /// name of the playlist given, if one was.
        public var named = 0
        public var missing = 0
        public var list = ""
        /// HVSC's list of song lengths, if one was among them.
        public var songLengths: URL?
        /// Files that may be ones siday keeps (see `KeptFile`), by their size or their first bytes: to be
        /// read and known by what is in them.
        public var keepable: [URL] = []
        /// The names of folders given that had nothing in them to play, or could not be looked into.
        public var emptyFolders: [String] = []
        /// Each of those folders, and how many files were found in it, none of them to play: none at
        /// all is a folder that could not be looked into, or seemed empty.
        public var emptyFolderPlaces: [(url: URL, files: Int)] = []
        /// What was given that could not be taken as it was.
        public var problems: [Problem] = []
    }

    public enum Problem: Sendable {
        /// There is no such file or folder.
        case notThere(URL)
        /// A file given that is no kind of tune played here.
        case notATune(URL)
        /// A playlist given that cannot be read.
        case unreadableList(URL)
        /// A tune a playlist given names that is not there.
        case unfound(String, list: URL)
    }

    /// Finds the tunes.
    /// - Parameter oncePerTune: a tune is gathered once, however often it is given or named (true);
    ///   or once for each folder it is in, and for each time it is given itself or by a list given.
    /// - Parameter looked: told, as folders are looked through, how many files have been found in
    ///   them so far, for one who waits to be shown how it is going.
    public static func scan(_ urls: [URL], oncePerTune: Bool = true, looked: (Int) -> Void = { _ in }) -> Found {
        var result = Found()
        var lookedBefore = 0
        var held = Set<String>()
        func key(_ file: URL) -> String { file.standardizedFileURL.path.lowercased() }
        func take(_ url: URL, note: String = "") {
            if oncePerTune, !held.insert(key(url)).inserted { return }
            result.tunes.append(url)
            if !note.isEmpty, result.notes[url] == nil { result.notes[url] = note }
        }
        func playlist(_ url: URL) -> PlaylistFile? {
            guard let kind = PlaylistFile.Kind(fileExtension: url.pathExtension) else { return nil }
            return (try? Coordinated.data(url)).flatMap { PlaylistFile([UInt8]($0), kind: kind) }
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result.problems.append(.notThere(url))
                continue
            }
            let kind = TuneGathering.kind(ofFileNamed: url.lastPathComponent)
            if isDirectory.boolValue {
                var files: [URL] = []
                let below = Coordinated.files(below: url) { looked(lookedBefore + $0) }
                lookedBefore += below.count
                for file in below {
                    switch TuneGathering.kind(ofFileNamed: file.lastPathComponent) {
                    case .tune, .playlist: files.append(file)
                    case .songLengths: result.songLengths = file
                    case .companion, .other: if !KeptFileStore.keepable(in: [file]).isEmpty { result.keepable.append(file) }
                    }
                }
                if files.isEmpty {
                    result.emptyFolders.append(url.lastPathComponent)
                    result.emptyFolderPlaces.append((url, below.count))
                }
                files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                var own = oncePerTune ? held : []
                let gathered = TuneGathering.folder(
                    files, isList: { TuneGathering.kind(ofFileNamed: $0.lastPathComponent) == .playlist },
                    entries: { playlist($0)?.entries ?? [] },
                    place: { entry, list in
                        if entry.absolute || entry.path.contains("..") { return .elsewhere }
                        return find(entry, from: list.deletingLastPathComponent()).map { .here($0) } ?? .nowhere
                    },
                    elsewhere: { entry, list in find(entry, from: list.deletingLastPathComponent()) },
                    presumed: { entry, list in key(written(entry, from: list.deletingLastPathComponent())) },
                    key: key, held: &own
                )
                if oncePerTune { held = own }
                for (tune, note) in gathered.tunes {
                    result.tunes.append(tune)
                    if !note.isEmpty, result.notes[tune] == nil { result.notes[tune] = note }
                }
                result.named += gathered.named
                result.missing += gathered.missing
            } else if kind == .playlist {
                guard let list = playlist(url) else {
                    result.problems.append(.unreadableList(url))
                    continue
                }
                result.list = url.lastPathComponent
                let gathered = TuneGathering.list(list.entries) { find($0, from: url.deletingLastPathComponent()) }
                for (tune, note) in gathered.tunes { take(tune, note: note) }
                for entry in gathered.unfound { result.problems.append(.unfound(entry.name, list: url)) }
                result.named += gathered.named
                result.missing += gathered.missing
            } else if kind == .songLengths {
                result.songLengths = url
            } else if kind == .tune {
                take(url)
            } else if !KeptFileStore.keepable(in: [url]).isEmpty {
                result.keepable.append(url)
            } else {
                result.problems.append(.notATune(url))
            }
        }
        return result
    }

    /// Where a playlist's entry says its tune is, read as it is written.
    private static func written(_ entry: PlaylistFile.Entry, from folder: URL) -> URL {
        var url = entry.absolute ? URL(fileURLWithPath: "/") : folder
        for part in entry.path { url = part == ".." ? url.deletingLastPathComponent() : url.appendingPathComponent(part) }
        return url.standardizedFileURL
    }

    /// The file a playlist's entry means, if it is there. The lists were made on Windows, to which
    /// capitals and small letters in a name are the same, and a full stop at a name's end is nothing:
    /// if there is no file where the entry says, each step of its path is looked for as Windows would,
    /// and then, if there is still none, as the one name in its folder that is the same compared
    /// `FileFinder.loose`. (A file found is named as it is on disk, and not as the list spells it,
    /// on a disk to which capitals and small letters are the same too.)
    public static func find(_ entry: PlaylistFile.Entry, from folder: URL) -> URL? {
        let manager = FileManager.default
        var url = entry.absolute ? URL(fileURLWithPath: "/") : folder
        for part in entry.path {
            let next = url.appendingPathComponent(part)
            if part == ".." {
                url = url.deletingLastPathComponent()
            } else if part == "." {
                continue
            } else if manager.fileExists(atPath: next.path) {
                url = url.appendingPathComponent((try? next.resourceValues(forKeys: [.nameKey]))?.name ?? part)
            } else {
                let here = Coordinated.names(in: url)
                let wanted = FileFinder.plain(part), loosely = FileFinder.loose(part)
                let alike = here.filter { FileFinder.loose($0) == loosely }
                guard let named = here.first(where: { FileFinder.plain($0) == wanted }) ?? (alike.count == 1 ? alike[0] : nil) else { return nil }
                url = url.appendingPathComponent(named)
            }
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url.standardizedFileURL
    }
}

extension TuneFormat {
    /// The kind of tune in a file: by what follows the last full stop of its name, whatever is before
    /// it (there is a tune called `...pt3`, which to the system is a file of no kind), and for a kind
    /// that shares its name with another, by how the file begins.
    public init?(url: URL) {
        let name = url.lastPathComponent
        guard let stop = name.lastIndex(of: "."), let named = TuneFormat(fileExtension: String(name[name.index(after: stop)...])) else { return nil }
        guard named.sharesItsName, let file = try? FileHandle(forReadingFrom: url) else {
            self = named
            return
        }
        defer { try? file.close() }
        self = named.refined(byLeading: [UInt8]((try? file.read(upToCount: TuneFormat.leadingBytes)) ?? Data()))
    }
}

/// Files and folders read through file coordination on an iPhone or iPad, where one from a file
/// provider (a share on the network, a drive in the cloud) is only a stand-in until it is asked for
/// that way: a folder's contents are not listed, and a file's bytes are not there. On a Mac a plain
/// read does, and is quicker.
public enum Coordinated {
    private static func reading<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        #if os(iOS)
        var outcome: Result<T, Error>?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { url in
            outcome = Result { try body(url) }
        }
        if let outcome { return try outcome.get() }
        if let failure { throw failure }
        #endif
        return try body(url)
    }

    public static func data(_ url: URL) throws -> Data {
        try reading(url) { try Data(contentsOf: $0, options: .mappedIfSafe) }
    }

    /// The names in a folder; none if it cannot be read.
    public static func names(in folder: URL) -> [String] {
        listing(folder, hidden: true).map(\.url.lastPathComponent)
    }

    /// Every file in a folder and in the folders inside it, hidden ones passed over; `looked` is
    /// told how many have been found so far, as each folder is looked through.
    public static func files(below folder: URL, looked: (Int) -> Void = { _ in }) -> [URL] {
        var found: [URL] = []
        var waiting = [folder]
        while let next = waiting.popLast() {
            for (url, isFolder) in listing(next) {
                if isFolder { waiting.append(url) } else { found.append(url) }
            }
            looked(found.count)
        }
        return found
    }

    /// The files and folders in a folder, hidden ones too or not; none if it cannot be read.
    private static func listing(_ folder: URL, hidden: Bool = false) -> [(url: URL, isFolder: Bool)] {
        func asked() -> [(url: URL, isFolder: Bool)] {
            ((try? reading(folder) {
                try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey], options: hidden ? [] : [.skipsHiddenFiles])
            }) ?? []).map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) }
        }
        let listed = asked()
        #if os(iOS)
        // On an iPhone or iPad, Foundation first finds a folder on some shares on the network empty
        // (Apple's r.150542999), though it is not: it is asked again, after a moment and then after a
        // longer one, as the share may still be finding what is in it; and then the system itself is.
        if listed.isEmpty {
            for wait in [0.0, 0.3, 1.0] {
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let again = asked()
                if !again.isEmpty { return again }
            }
            return (try? reading(folder) { entries(of: $0, hidden: hidden) }) ?? []
        }
        #endif
        return listed
    }

    #if canImport(Darwin)
    /// The files and folders in a folder as the system lists them, without Foundation, hidden ones
    /// too or not.
    static func entries(of folder: URL, hidden: Bool) -> [(url: URL, isFolder: Bool)] {
        guard let directory = opendir(folder.path) else { return [] }
        defer { closedir(directory) }
        var found: [(url: URL, isFolder: Bool)] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            guard name != ".", name != "..", hidden || !name.hasPrefix(".") else { continue }
            let url = folder.appendingPathComponent(name)
            var isFolder = Int32(entry.pointee.d_type) == DT_DIR
            if Int32(entry.pointee.d_type) == DT_UNKNOWN {
                var isDirectory: ObjCBool = false
                isFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            found.append((url, isFolder))
        }
        return found
    }
    #endif
}
