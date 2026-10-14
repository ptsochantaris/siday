// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayKit
import Testing

// The web player shows FORMATS.md's part on a format when the format's name is pressed, and the
// command line's --about and i print it; both find it by the word its heading begins with. A
// heading that is reworded must not leave a format without one.
@Test func everyFormatHasItsPartInFORMATSmd() throws {
    let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FORMATS.md"), encoding: .utf8)
    let headings = text.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
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
