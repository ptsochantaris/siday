// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Puts FORMATS.md into the command-line player, so that `siday --about` and the `i` key can tell a
// format's story wherever the player is installed:
//
//     swift Scripts/pack-formats.swift
//
// It writes Sources/siday/FormatStories.swift, which is to be committed with FORMATS.md whenever
// that changes. Run it from the top of the repository. A test sees that the two still agree.

import Foundation

let text = try String(contentsOfFile: "FORMATS.md", encoding: .utf8)
guard !text.contains("\"#") else {
    print("FORMATS.md has a quote followed by #, which the raw string the text is put in cannot hold.")
    exit(65)
}
let swift = """
// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Made by Scripts/pack-formats.swift from FORMATS.md, which is where to change it. Do not edit.

extension FormatStories {
    /// FORMATS.md, as it was when this was made.
    static let text = #\"\"\"
\(text)\"\"\"#
}

"""
try swift.write(toFile: "Sources/siday/FormatStories.swift", atomically: true, encoding: .utf8)
print("Wrote Sources/siday/FormatStories.swift (\(text.utf8.count) bytes of text).")
