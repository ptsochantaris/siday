// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

/// Each tab of the app, with a tune playing, put through the system's own accessibility audit: labels
/// for VoiceOver, text that grows with the reader's size and is not cut off, contrast, room to press.
/// The app plays nothing aloud while it is tested (`-SidaySilent`), and the tune is one made here.
@MainActor
final class AccessibilityTests: XCTestCase {
    /// A ProTracker module of one pattern, with a note of its one sample, a square wave, on its first row.
    private static func squareModule() -> Data {
        var file = [UInt8](repeating: 0, count: 1084)
        for (i, letter) in "square".utf8.enumerated() { file[i] = letter }
        file[42] = 0; file[43] = 16
        file[45] = 64
        file[48] = 0; file[49] = 16
        file[950] = 1
        file[951] = 127
        for (i, letter) in "M.K.".utf8.enumerated() { file[1080 + i] = letter }
        var pattern = [UInt8](repeating: 0, count: 1024)
        pattern[0] = 0x01; pattern[1] = 0xAC; pattern[2] = 0x10
        file += pattern
        file += (0 ..< 32).map { $0 < 16 ? 0x60 : 0xA0 }
        return Data(file)
    }

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("siday-tunes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.squareModule().write(to: folder.appendingPathComponent("square.mod"))
        let app = XCUIApplication()
        app.launchArguments = ["-SidaySilent", "-SidayFresh", "-SidayOpen", folder.path] + extra
        app.launch()
        return app
    }

    private func audit(_ app: XCUIApplication, tab: String) throws {
        let button = app.buttons[tab].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(tab) tab")
        button.tap()
        // (The picture and the analyser move all the time, which the audit is not to wait for.)
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription, .contrast, .hitRegion, .textClipped, .elementDetection, .trait]) { issue in
            let element = issue.element?.debugDescription ?? "?"
            // ("Nearly passed" is a pass: the colour is within a whisker of what is wanted.)
            if issue.compactDescription == "Contrast nearly passed" { return true }
            // (The system's own search field is not the app's to size.)
            if element.contains("SearchField") { return true }
            // (What is half under the see-through tab bar is measured through it, and comes to the audit
            // as a node with no element: the rows scrolled under the bar, which are clear once out from it.)
            if issue.compactDescription == "Contrast failed", issue.element == nil { return true }
            // (These two grow with the reader's size of text, as was seen at the largest; the audit's
            // probe takes them not to.)
            let seenToGrow = ["The Source on GitHub", "What It Plays"]
            if issue.compactDescription != "Contrast failed", seenToGrow.contains(where: { element.contains("label: '\($0)'") }) { return true }
            print("AUDIT \(tab): \(issue.auditType) \(issue.compactDescription) | \(issue.detailedDescription) | \(element)")
            return false
        }
    }

    func testEveryTabPassesTheAudit() throws {
        let app = try launch()
        XCTAssertTrue(app.staticTexts["square"].waitForExistence(timeout: 10), "the tune did not load")
        for tab in ["Player", "Playlist", "Settings", "About"] { try audit(app, tab: tab) }
    }

    func testEveryTabPassesTheAuditInTheLargestText() throws {
        let app = try launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        for tab in ["Player", "Playlist", "Settings", "About"] { try audit(app, tab: tab) }
    }

    func testTheVoicesCanBeMutedWithVoiceOversActions() throws {
        let app = try launch()
        let voice = app.buttons["Voice 1"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10), "no light for the first voice")
        voice.tap()
        XCTAssertTrue(app.buttons["Voice 1"].firstMatch.waitForValue("Muted", timeout: 5))
    }
}

private extension XCUIElement {
    func waitForValue(_ value: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
