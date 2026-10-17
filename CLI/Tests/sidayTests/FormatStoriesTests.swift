// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import siday
import Foundation
import SidayKit
import Testing

@Test func theFormatsStoriesInThePlayerAreFORMATSmdAsItIs() throws {
    // FORMATS.md is packed into the player by Scripts/pack-formats.swift, to be run when it changes.
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../FORMATS.md")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(FormatStories.text + "\n" == text, "FORMATS.md has changed since it was packed: run swift Scripts/pack-formats.swift")
}

@Test func everyFormatHasAStoryThatFitsTheTerminal() throws {
    for format in TuneFormat.allCases {
        let story = try #require(FormatStories.setOut(on: format, width: 72, bold: false), "nothing on \(format)")
        let lines = story.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count > 5)
        // (A word longer than the line, a long path say, can only stand alone.)
        #expect(lines.allSatisfy { $0.count <= 72 || !$0.dropFirst().contains(" ") }, "\(format)")
    }
    // The heading, then its paragraphs: no marks left, and a link's address given beside its words.
    let it = try #require(FormatStories.setOut(on: .it, width: 100, bold: false))
    #expect(it.hasPrefix("IT — Impulse Tracker"))
    #expect(!it.contains("`") && !it.contains("**"))
    // A word at the start of another heading is not that heading: S3M's own, and not STM's.
    #expect(try #require(FormatStories.part(on: .s3m)).title.hasPrefix("S3M"))
    #expect(try #require(FormatStories.part(on: .stx)).title.hasPrefix("STM and STX"))
}
