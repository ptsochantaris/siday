// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The stories of the formats, from FORMATS.md as the app carries it: its introduction, and a part for
/// each format, under a heading whose first word names it.
enum Stories {
    struct Part: Identifiable {
        /// The word its heading begins with (as `TuneFormat.chapter` gives it), and the whole heading.
        let id: String
        let heading: String
        let text: String
    }

    static let introduction: String = parts.introduction
    static let all: [Part] = parts.list

    static func part(_ chapter: String) -> Part? {
        all.first { $0.id == chapter }
    }

    private static let parts: (introduction: String, list: [Part]) = {
        guard let url = Bundle.main.url(forResource: "FORMATS", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ("", []) }
        var introduction = ""
        var list: [Part] = []
        var heading: String?
        var lines: [Substring] = []
        func close() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let heading {
                let word = String(heading.split(separator: " ").first ?? "")
                list.append(Part(id: word, heading: heading, text: body))
            } else {
                introduction = body.split(separator: "\n", maxSplits: 1).dropFirst().joined()
            }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                close()
                heading = String(line.dropFirst(3))
            } else {
                lines.append(line)
            }
        }
        close()
        return (introduction, list)
    }()
}

/// Markdown of paragraphs and lists, as FORMATS.md and THIRD-PARTY.md are written, shown as text that
/// can be read in any size.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.item {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inline(block.text)
                    }
                } else if block.heading {
                    inline(block.text).font(.headline)
                } else {
                    inline(block.text)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }

    private struct Block {
        var text: String
        var item = false
        var heading = false
    }

    /// Paragraphs, list items and headings; the lines of each joined.
    private var blocks: [Block] {
        var blocks: [Block] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blocks.append(Block(text: ""))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(Block(text: String(line.dropFirst(2)), item: true))
            } else if line.hasPrefix("#") {
                blocks.append(Block(text: line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces), heading: true))
            } else if let last = blocks.last, !last.text.isEmpty, !last.heading {
                blocks[blocks.count - 1].text += " " + trimmed
            } else {
                blocks.append(Block(text: trimmed))
            }
        }
        return blocks.filter { !$0.text.isEmpty }
    }
}

/// A format's story, as a slide-over.
struct StoryView: View {
    let chapter: String

    var body: some View {
        ScrollView {
            if let part = Stories.part(chapter) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(part.heading).font(.title2.weight(.semibold))
                    MarkdownText(text: part.text)
                }
                .padding()
            } else {
                ContentUnavailableView("No Story", systemImage: "book.closed")
            }
        }
    }
}
