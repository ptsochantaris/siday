// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import Foundation

/// Collects playable files from the paths on the command line.
struct Scanner {
    var formats: Set<TuneFormat>
    var match: String?

    struct Result {
        var files: [URL] = []
        var problems: [String] = []
        /// What a playlist says about a tune it names.
        var notes: [URL: String] = [:]
    }

    /// A playlist that is named is played as it is written: its tunes, in its order. A folder is
    /// played as its tunes in the order of their names. A playlist in it is the order of the tunes
    /// that are beside it and below it: those it names are played where the list is, as it has
    /// them. The tunes a list names that are somewhere else are added only if the folder does not
    /// itself hold them. (A collection kept as one folder of tunes and many of lists is then played
    /// once through and not once for every list, and a folder of nothing but lists is played too.)
    func scan(_ paths: [String]) -> Result {
        var result = Result()
        let manager = FileManager.default
        func consider(_ url: URL, explicit: Bool, from list: String? = nil, note: String = "") {
            guard let format = TuneFormat(url: url) else {
                if explicit { result.problems.append("\(list.map { "\($0): " } ?? "")\(url.path): not a recognised chiptune format") }
                return
            }
            guard formats.contains(format) else { return }
            if let match, !url.path.localizedCaseInsensitiveContains(match) { return }
            result.files.append(url)
            if !note.isEmpty, result.notes[url] == nil { result.notes[url] = note }
        }
        func playlist(_ url: URL) -> PlaylistFile? {
            guard let kind = PlaylistFile.Kind(fileExtension: url.pathExtension) else { return nil }
            return (try? Data(contentsOf: url)).flatMap { PlaylistFile([UInt8]($0), kind: kind) }
        }
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result.problems.append("\(path): no such file or folder")
                continue
            }
            if isDirectory.boolValue {
                guard let walker = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                    result.problems.append("\(path): cannot be read")
                    continue
                }
                var found: [URL] = []
                var lists: [URL] = []
                for case let file as URL in walker {
                    if TuneFormat(url: file) != nil {
                        found.append(file)
                    } else if PlaylistFile.reads(fileExtension: file.pathExtension) {
                        lists.append(file)
                    }
                }
                func key(_ file: URL) -> String { file.standardizedFileURL.path.lowercased() }
                // What each list says of the tunes in its own folder and below, and what tunes it
                // names that are somewhere else.
                var below: [URL: [(tune: URL, note: String)]] = [:]
                var elsewhere: [(folder: URL, entry: PlaylistFile.Entry)] = []
                var ordered = Set<String>()
                lists.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                for list in lists {
                    let folder = list.deletingLastPathComponent()
                    for entry in playlist(list)?.entries ?? [] {
                        if entry.absolute || entry.path.contains("..") {
                            elsewhere.append((folder, entry))
                        } else if let tune = Self.find(entry, from: folder) {
                            below[list, default: []].append((tune, entry.note))
                            ordered.insert(key(tune))
                        }
                    }
                }
                // The folder in the order of its names, with each list's tunes where the list is.
                var held = Set<String>()
                for file in (found + below.keys).sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                    if let tunes = below[file] {
                        for (tune, note) in tunes where held.insert(key(tune)).inserted { consider(tune, explicit: false, note: note) }
                    } else {
                        let name = key(file)
                        if !ordered.contains(name), held.insert(name).inserted { consider(file, explicit: false) }
                    }
                }
                for (folder, entry) in elsewhere {
                    // Most are the folder's own, and are known for that without a look at the disk.
                    var parts = entry.absolute ? [] : folder.standardizedFileURL.path.split(separator: "/").map { String($0) }
                    for part in entry.path {
                        if part != ".." { parts.append(part) } else if !parts.isEmpty { parts.removeLast() }
                    }
                    if held.contains("/" + parts.joined(separator: "/").lowercased()) { continue }
                    guard let tune = Self.find(entry, from: folder), held.insert(tune.path.lowercased()).inserted else { continue }
                    consider(tune, explicit: false, note: entry.note)
                }
            } else if PlaylistFile.reads(fileExtension: url.pathExtension) {
                guard let list = playlist(url) else {
                    result.problems.append("\(path): not a playlist that can be read")
                    continue
                }
                for entry in list.entries {
                    if let tune = Self.find(entry, from: url.deletingLastPathComponent()) {
                        consider(tune, explicit: true, from: path, note: entry.note)
                    } else {
                        result.problems.append("\(path): \(entry.name): no such file")
                    }
                }
            } else {
                consider(url, explicit: true)
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
    /// `FileFinder.loose`.
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

func describe(_ info: TuneInfo) -> String {
    var text = info.title.isEmpty ? "" : info.title
    if !info.author.isEmpty { text += text.isEmpty ? info.author : " — \(info.author)" }
    return text
}
