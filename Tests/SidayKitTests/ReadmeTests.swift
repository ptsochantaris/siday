// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayKit
import Testing

// The web player shows the README's chapter on a format when the format's name is pressed, and finds
// it by the word its heading begins with. A heading that is reworded must not leave a format without one.
@Test func everyFormatHasItsChapterInTheReadme() throws {
    let readme = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("README.md"), encoding: .utf8)
    let lines = readme.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex(of: "## How it is built"))
    let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
    let headings = lines[start ..< end].filter { $0.hasPrefix("### ") }.map { String($0.dropFirst(4)) }
    for format in TuneFormat.allCases {
        let word = format.chapter
        let found = headings.filter { heading in
            guard heading.hasPrefix(word) else { return false }
            let after = heading.dropFirst(word.count).first
            return after.map { !$0.isLetter && !$0.isNumber } ?? true
        }
        #expect(found.count == 1, "\(format.rawValue): \(found.count) headings begin with \(word)")
    }
}
