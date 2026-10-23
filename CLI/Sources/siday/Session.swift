// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayFiles
import SidayPlayer

/// Collects playable files from the paths on the command line, as SidayFiles' `TuneFolders` finds
/// them (see SidayPlayer's `TuneGathering` for the order), each time a tune is given or named: of the
/// kinds asked for, and whose paths have the text asked for in them.
struct Scanner {
    var formats: Set<TuneFormat>
    var match: String?

    struct Result {
        var files: [URL] = []
        var problems: [String] = []
        /// What a playlist says about a tune it names.
        var notes: [URL: String] = [:]
    }

    func scan(_ paths: [String]) -> Result {
        let found = TuneFolders.scan(paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }, oncePerTune: false)
        var result = Result(notes: found.notes)
        result.files = found.tunes.filter { url in
            guard let format = TuneFormat(url: url), formats.contains(format) else { return false }
            return match.map { url.path.localizedCaseInsensitiveContains($0) } ?? true
        }
        result.problems = found.problems.map { problem in
            switch problem {
            case .notThere(let url): "\(url.path): no such file or folder"
            case .notATune(let url): "\(url.path): not a recognised chiptune format"
            case .unreadableList(let url): "\(url.path): not a playlist that can be read"
            case let .unfound(name, list): "\(list.path): \(name): no such file"
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
