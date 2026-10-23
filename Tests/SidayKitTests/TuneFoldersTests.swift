// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
@testable import SidayFiles
import Testing

// MARK: The tunes on disk in what is given

@Test func aFolderOnDiskIsGatheredWithItsListsTunesWhereTheListsAre() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("siday-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let manager = FileManager.default
    try manager.createDirectory(at: folder.appendingPathComponent("Tunes/Inside"), withIntermediateDirectories: true)
    try manager.createDirectory(at: folder.appendingPathComponent("Other"), withIntermediateDirectories: true)
    for name in ["Tunes/a.pt3", "Tunes/b.pt3", "Tunes/Inside/c.pt3", "Tunes/x.smp", "Tunes/readme", "Other/far.pt3"] {
        try Data([0]).write(to: folder.appendingPathComponent(name))
    }
    // Written on Windows: backslashes, capitals that are not the file's, and a tune that is not there.
    let list = "ZX Spectrum Sound Chip Emulator Play List File v1.6\r\nInside\\C.PT3\r\nmissing.pt3\r\n..\\Other\\far.pt3\r\nb.pt3\r\n"
    try Data(list.utf8).write(to: folder.appendingPathComponent("Tunes/Best.ayl"))

    // (A list's tune is named as it is on disk, whether the disk takes account of capitals or not.)
    func named(_ tunes: [URL]) -> [String] { tunes.map { $0.pathComponents.suffix(2).joined(separator: "/") } }
    let found = TuneFolders.scan([folder.appendingPathComponent("Tunes")])
    #expect(named(found.tunes) == ["Tunes/a.pt3", "Inside/c.pt3", "Tunes/b.pt3", "Other/far.pt3"])
    #expect(found.named == 4 && found.missing == 1 && found.emptyFolders.isEmpty)
    // Given itself, the list is played as it is written; and with the folder again, nothing comes twice.
    let list2 = TuneFolders.scan([folder.appendingPathComponent("Tunes/Best.ayl"), folder.appendingPathComponent("Tunes")])
    #expect(named(list2.tunes) == ["Inside/c.pt3", "Other/far.pt3", "Tunes/b.pt3", "Tunes/a.pt3"] && list2.list == "Best.ayl")
    #expect(TuneFolders.scan([folder.appendingPathComponent("Tunes/Best.ayl")], oncePerTune: false).problems.count == 1)
    #expect(TuneFolders.scan([folder.appendingPathComponent("Other/none.pt3")]).problems.count == 1)
}
