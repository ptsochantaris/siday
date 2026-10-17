// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import siday
import Foundation
import Testing

@Test func aFileWithNoSongLengthsIsNotADatabase() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("siday-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("DOCUMENTS"), withIntermediateDirectories: true)
    let database = folder.appendingPathComponent("DOCUMENTS/Songlengths.md5")
    try Data("[Database]\n; /MUSICIANS/X/Tune.sid\n0123456789abcdef0123456789abcdef=1:00\n".utf8).write(to: database)
    let empty = folder.appendingPathComponent("empty.md5"), other = folder.appendingPathComponent("notes.txt")
    try Data().write(to: empty)
    try Data("Nothing here gives a length.\nname=value\n".utf8).write(to: other)

    #expect(SongLengthFiles.database(atPath: database.path) != nil)
    #expect(SongLengthFiles.database(atPath: empty.path) == nil)
    #expect(SongLengthFiles.database(atPath: other.path) == nil)
    #expect(SongLengthFiles.database(atPath: folder.appendingPathComponent("missing.md5").path) == nil)

    // Named in place of a database, such a file does not stop the one beside the tune being found.
    let tune = folder.appendingPathComponent("MUSICIANS/X/Tune.sid")
    for named in [empty, other] {
        let found = SongLengthFiles.find(explicitPath: named.path, near: tune)
        #expect(found?.lengths(of: [], path: tune.standardizedFileURL.path) == [60])
    }
}

@Test func aTuneIsLoadedFromItsFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("siday-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let files = TuneFiles()
    #expect(throws: (any Error).self) { _ = try files.load(folder.appendingPathComponent("missing.pt3")) }
    #expect(throws: (any Error).self) { _ = try files.load(folder.appendingPathComponent("notes.txt")) }
    let empty = folder.appendingPathComponent("empty.sid")
    try Data().write(to: empty)
    #expect(throws: (any Error).self) { _ = try files.load(empty) }
}
