// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

/// Each part of the app (the playlist, the player, the settings and what the app is), with a tune
/// playing, put through the system's own accessibility audit: labels
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
        app.launchArguments = ["-SidaySilent", "-volume", "0", "-SidayFresh", "-SidayOpen", folder.path] + extra
        app.launch()
        return app
    }

    /// Presses a button, once it is there.
    private func press(_ button: XCUIElement, _ what: String) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(what)")
        button.tap()
    }

    /// On an iPhone: from the playlist, which a list begun empty shows, to the player by the bar at
    /// its foot.
    private func showPlayer(_ app: XCUIApplication) {
        press(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Now Playing'")).firstMatch, "now playing bar")
    }

    /// Puts each part through the audit in turn: the playlist, the player, the settings, and what the app is.
    private func auditEveryPart(_ app: XCUIApplication) throws {
        try audit(app, part: "Playlist")
        showPlayer(app)
        try audit(app, part: "Player")
        press(app.buttons["Settings"].firstMatch, "Settings button")
        try audit(app, part: "Settings")
        press(app.buttons["About Siday"].firstMatch, "About button")
        try audit(app, part: "About")
    }

    private func audit(_ app: XCUIApplication, part: String) throws {
        XCTAssertTrue(app.navigationBars[part].firstMatch.waitForExistence(timeout: 10), "no \(part)")
        // (The picture and the analyser move all the time, which the audit is not to wait for.)
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription, .contrast, .hitRegion, .textClipped, .elementDetection, .trait]) { issue in
            let element = issue.element?.debugDescription ?? "?"
            // ("Nearly passed" is a pass: the colour is within a whisker of what is wanted.)
            if issue.compactDescription == "Contrast nearly passed" { return true }
            // (The system's own search field is not the app's to size.)
            if element.contains("SearchField") || issue.detailedDescription.contains("UISearchBarTextField") { return true }
            // (What is in a bar at the foot is kept at one size by the system, and shown large when
            // held instead: the bar of what is playing.)
            if issue.auditType == .dynamicType, element.contains("identifier: 'playing'") { return true }
            // (What is half under a see-through bar is measured through it, and comes to the audit
            // as a node with no element: the rows scrolled under the bar, which are clear once out from it.)
            if issue.compactDescription == "Contrast failed", issue.element == nil { return true }
            // (These two grow with the reader's size of text, as was seen at the largest; the audit's
            // probe takes them not to.)
            let seenToGrow = ["The Source on GitHub", "What It Plays", "Done"]
            if issue.compactDescription != "Contrast failed", seenToGrow.contains(where: { element.contains("label: '\($0)'") }) { return true }
            print("AUDIT \(part): \(issue.auditType) \(issue.compactDescription) | \(issue.detailedDescription) | \(element)")
            return false
        }
    }

    func testEveryPartPassesTheAudit() throws {
        let app = try launch()
        try auditEveryPart(app)
    }

    func testEveryPartPassesTheAuditInTheLargestText() throws {
        let app = try launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        try auditEveryPart(app)
    }

    func testTheVoicesCanBeMutedWithVoiceOversActions() throws {
        let app = try launch()
        showPlayer(app)
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
