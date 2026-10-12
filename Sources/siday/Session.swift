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
    /// played as its tunes in the order of their names, and the playlists in it add only the tunes
    /// they name that the folder does not itself hold. (A collection kept as one folder of tunes
    /// and many of lists is then played once through and not once for every list, and a folder of
    /// nothing but lists is played too.)
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
            (try? Data(contentsOf: url)).flatMap { PlaylistFile([UInt8]($0)) }
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
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                for file in found { consider(file, explicit: false) }
                guard !lists.isEmpty else { continue }
                lists.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                var held = Set(found.map { $0.standardizedFileURL.path.lowercased() })
                for list in lists {
                    let folder = list.deletingLastPathComponent()
                    let above = folder.standardizedFileURL.path.split(separator: "/").map { String($0) }
                    for entry in playlist(list)?.entries ?? [] {
                        // Most are the folder's own, and are known for that without a look at the disk.
                        var parts = entry.absolute ? [] : above
                        for part in entry.path {
                            if part != ".." { parts.append(part) } else if !parts.isEmpty { parts.removeLast() }
                        }
                        if held.contains("/" + parts.joined(separator: "/").lowercased()) { continue }
                        guard let tune = Self.find(entry, from: folder), held.insert(tune.path.lowercased()).inserted else { continue }
                        consider(tune, explicit: false, note: entry.note)
                    }
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
    /// if there is no file where the entry says, each step of its path is looked for as Windows would.
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
                let wanted = PlaylistFile.plain(part)
                guard let named = (try? manager.contentsOfDirectory(atPath: url.path))?.first(where: { PlaylistFile.plain($0) == wanted }) else { return nil }
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
