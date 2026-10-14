// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayKit

/// What FORMATS.md says of each format, carried in the player (see `Scripts/pack-formats.swift`),
/// for `--about` and the `i` key: found by its heading, as the web player finds it, and set out for
/// a terminal of so many columns.
enum FormatStories {
    /// The part of FORMATS.md on a format: its heading, and its lines up to the next heading.
    static func part(on format: TuneFormat) -> (title: String, lines: [Substring])? {
        let word = format.chapter
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { line in
            guard line.hasPrefix("## ") else { return false }
            let heading = line.dropFirst(3)
            guard heading.hasPrefix(word) else { return false }
            // (The word whole: "S3M" is not the start of "S3MX".)
            return heading.dropFirst(word.count).first.map { !$0.isLetter && !$0.isNumber } ?? true
        }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        return (String(lines[start].dropFirst(3)), Array(lines[(start + 1) ..< end]))
    }

    /// The part on a format as text to print: the heading, then each paragraph and each item of a
    /// list run together and broken again at the width, with what is marked as code, stressed or a
    /// link left as plain words (and a link to the web given after its words). In bold for a
    /// terminal, the heading and what is strongly stressed.
    static func setOut(on format: TuneFormat, width: Int, bold: Bool) -> String? {
        guard let part = part(on: format) else { return nil }
        let width = max(40, width)
        var out = wrapped(part.title, width: width, first: "", rest: "").map { bold ? "\u{1B}[1m\($0)\u{1B}[0m" : $0 }
        var block: [Substring] = []
        func end() {
            guard !block.isEmpty else { return }
            out.append("")
            let item = /^(\d+\.|-)\s+/
            if block[0].firstMatch(of: item) != nil {
                // A list: each item from its mark, and what follows it on the lines below.
                var items: [String] = []
                for line in block {
                    if let found = line.firstMatch(of: item) {
                        items.append(String(found.output.1) + " " + line[found.range.upperBound...])
                    } else if !items.isEmpty {
                        items[items.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                    }
                }
                for text in items {
                    let mark = text.prefix { $0 != " " }
                    out += wrapped(plain(String(text.dropFirst(mark.count + 1)), bold: bold), width: width, first: mark + " ", rest: String(repeating: " ", count: mark.count + 1))
                }
            } else {
                out += wrapped(plain(block.joined(separator: " "), bold: bold), width: width, first: "", rest: "")
            }
            block = []
        }
        for line in part.lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { end() } else { block.append(line) }
        }
        end()
        return out.joined(separator: "\n")
    }

    /// Text with FORMATS.md's marks taken out.
    private static func plain(_ text: String, bold: Bool) -> String {
        var text = text
        text.replace(/\[([^\]]+)\]\((https?:[^)\s]*)\)/) { "\($0.output.1) (\($0.output.2))" }
        text.replace(/\[([^\]]+)\]\([^)\s]*\)/) { String($0.output.1) }
        text.replace(/\*\*([^*]+)\*\*/) { bold ? "\u{1B}[1m\($0.output.1)\u{1B}[0m" : String($0.output.1) }
        text.replace(/\*([^*\s][^*]*)\*/) { String($0.output.1) }
        text.replace(/`([^`]+)`/) { String($0.output.1) }
        return text
    }

    /// Words broken into lines no wider than the width, the first begun with one thing and the rest
    /// with another. (What a terminal shows of an escape takes no room, and is not counted.)
    private static func wrapped(_ text: String, width: Int, first: String, rest: String) -> [String] {
        var lines: [String] = [], line = first, room = width - first.count, empty = true
        for word in text.split(separator: " ") {
            let size = word.replacing(/\u{1B}\[[0-9]*m/, with: "").count
            if !empty, size + 1 > room {
                lines.append(line)
                line = rest
                room = width - rest.count
                empty = true
            }
            line += (empty ? "" : " ") + word
            room -= size + (empty ? 0 : 1)
            empty = false
        }
        if !empty { lines.append(line) }
        return lines
    }
}
