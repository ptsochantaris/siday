// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayKit

/// Finds the tunes in what the listener gives the app: files, folders, playlists. It is the
/// command-line player's way (CLI/Sources/siday/Session.swift), which the two are to keep to: a
/// folder's tunes in the order of their names, each playlist's tunes where the list is, and what a
/// list names elsewhere after them.
nonisolated enum Scanner {
    struct Found: Sendable {
        var tunes: [URL] = []
        /// What the playlist a tune came by says of it.
        var notes: [URL: String] = [:]
        /// Of the tunes playlists named, how many, and how many were not there to be found; and the
        /// name of the list, if there was one.
        var named = 0
        var missing = 0
        var list = ""
        /// HVSC's list of song lengths, if one was among them.
        var songLengths: URL?
    }

    static func scan(_ urls: [URL]) -> Found {
        var result = Found()
        let manager = FileManager.default
        var held = Set<String>()
        func key(_ file: URL) -> String { file.standardizedFileURL.path.lowercased() }
        func consider(_ url: URL, note: String = "") {
            guard TuneFormat(fileExtension: url.pathExtension) != nil, !Companions.are(fileName: url.lastPathComponent), held.insert(key(url)).inserted else { return }
            result.tunes.append(url)
            if !note.isEmpty { result.notes[url] = note }
        }
        func playlist(_ url: URL) -> PlaylistFile? {
            guard let kind = PlaylistFile.Kind(fileExtension: url.pathExtension) else { return nil }
            return (try? Data(contentsOf: url)).flatMap { PlaylistFile([UInt8]($0), kind: kind) }
        }
        func counted(_ entry: PlaylistFile.Entry) -> Bool { TuneFormat(fileExtension: entry.fileExtension) != nil }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if url.lastPathComponent.lowercased() == "songlengths.md5" {
                result.songLengths = url
            } else if isDirectory.boolValue {
                guard let walker = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                var found: [URL] = []
                var lists: [URL] = []
                for case let file as URL in walker {
                    if file.lastPathComponent.lowercased() == "songlengths.md5" {
                        result.songLengths = file
                    } else if TuneFormat(fileExtension: file.pathExtension) != nil, !Companions.are(fileName: file.lastPathComponent) {
                        found.append(file)
                    } else if PlaylistFile.reads(fileExtension: file.pathExtension) {
                        lists.append(file)
                    }
                }
                // What each list says of the tunes in its own folder and below, and what tunes it
                // names that are somewhere else.
                var below: [URL: [(tune: URL, note: String)]] = [:]
                var elsewhere: [(folder: URL, entry: PlaylistFile.Entry)] = []
                var ordered = Set<String>()
                lists.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                for list in lists {
                    let folder = list.deletingLastPathComponent()
                    for entry in playlist(list)?.entries ?? [] where counted(entry) {
                        if entry.absolute || entry.path.contains("..") {
                            elsewhere.append((folder, entry))
                        } else if let tune = find(entry, from: folder) {
                            below[list, default: []].append((tune, entry.note))
                            ordered.insert(key(tune))
                        } else {
                            result.named += 1
                            result.missing += 1
                        }
                    }
                }
                // The folder in the order of its names, with each list's tunes where the list is.
                for file in (found + below.keys).sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                    if let tunes = below[file] {
                        for (tune, note) in tunes { consider(tune, note: note) }
                        result.named += tunes.count
                    } else if !ordered.contains(key(file)) {
                        consider(file)
                    }
                }
                for (folder, entry) in elsewhere {
                    result.named += 1
                    guard let tune = find(entry, from: folder) else {
                        result.missing += 1
                        continue
                    }
                    consider(tune, note: entry.note)
                }
            } else if PlaylistFile.reads(fileExtension: url.pathExtension) {
                guard let list = playlist(url) else { continue }
                result.list = url.lastPathComponent
                for entry in list.entries where counted(entry) {
                    result.named += 1
                    if let tune = find(entry, from: url.deletingLastPathComponent()) {
                        consider(tune, note: entry.note)
                    } else {
                        result.missing += 1
                    }
                }
            } else {
                consider(url)
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

    /// The file a playlist's entry means, if it is there, as the command-line player finds it: where
    /// the entry says, or each step of its path as Windows would look for it, capitals and small
    /// letters the same.
    static func find(_ entry: PlaylistFile.Entry, from folder: URL) -> URL? {
        let manager = FileManager.default
        let direct = written(entry, from: folder)
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: direct.path, isDirectory: &isDirectory) { return isDirectory.boolValue ? nil : direct }
        var url = entry.absolute ? URL(fileURLWithPath: "/") : folder
        for part in entry.path {
            if part == ".." {
                url = url.deletingLastPathComponent()
            } else if manager.fileExists(atPath: url.appendingPathComponent(part).path) {
                url = url.appendingPathComponent(part)
            } else {
                let here = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
                let wanted = FileFinder.plain(part), loosely = FileFinder.loose(part)
                let alike = here.filter { FileFinder.loose($0) == loosely }
                guard let named = here.first(where: { FileFinder.plain($0) == wanted }) ?? (alike.count == 1 ? alike[0] : nil) else { return nil }
                url = url.appendingPathComponent(named)
            }
        }
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url.standardizedFileURL
    }
}
