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
    }

    func scan(_ paths: [String]) -> Result {
        var result = Result()
        let manager = FileManager.default
        func consider(_ url: URL, explicit: Bool) {
            guard let format = TuneFormat(url: url) else {
                if explicit { result.problems.append("\(url.path): not a recognised chiptune format") }
                return
            }
            guard formats.contains(format) else { return }
            if let match, !url.path.localizedCaseInsensitiveContains(match) { return }
            result.files.append(url)
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
                for case let file as URL in walker where TuneFormat(url: file) != nil {
                    found.append(file)
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                for file in found { consider(file, explicit: false) }
            } else {
                consider(url, explicit: true)
            }
        }
        return result
    }
}

func describe(_ info: TuneInfo) -> String {
    var text = info.title.isEmpty ? "" : info.title
    if !info.author.isEmpty { text += text.isEmpty ? info.author : " — \(info.author)" }
    return text
}
