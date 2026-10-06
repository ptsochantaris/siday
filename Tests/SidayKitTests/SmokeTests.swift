// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

@Test func lh5RejectsDataThatIsNotAnArchive() {
    #expect(LH5.unwrapArchive([1, 2, 3]) == nil)
    #expect(LH5.decode([0, 0, 0, 0], offset: 0, originalSize: 16) == nil)
}

@Test func ayChipProducesATone() {
    var chip = AYChip(type: .ay, clockHz: 1_773_400, sampleRate: 48000, stereo: .mono)
    defer { chip.deallocate() }
    // Tone period 252 on channel A is 1773400 / 16 / 252 = 439.8 Hz.
    chip.write(0, 252); chip.write(1, 0); chip.write(7, 0x3E); chip.write(8, 15)
    var crossings = 0
    var previous = 0.0
    for i in 0 ..< 48000 {
        let (l, _) = chip.sample()
        if i > 4800, previous < 0, l >= 0 { crossings += 1 }
        previous = l
    }
    // 0.9 s of a 439.8 Hz tone.
    #expect(abs(crossings - 396) <= 2)
}

@Test func songLengthDatabaseIsReadFromBytes() {
    let text = "[Database]\r\n; /MUSICIANS/H/Hubbard_Rob/Commando.sid\r\n0123456789abcdef0123456789abcdef=3:55 0:07.5 1:02.125\n"
        + ";a comment that names no tune\n; /DEMOS/A-F/Other.sid   \nfedcba9876543210fedcba9876543210=0:30\nnot an entry\n"
    let parsed = SongLengthDatabase.parse(Data(text.utf8))
    #expect(parsed.byHash.count == 2)
    #expect(parsed.byHash["0123456789abcdef0123456789abcdef"] == [235, 7.5, 62.125])
    #expect(parsed.byPath["/musicians/h/hubbard_rob/commando.sid"] == [235, 7.5, 62.125])
    #expect(parsed.byPath["/demos/a-f/other.sid"] == [30])
}

@Test func aFileWithNoSongLengthsIsNotADatabase() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("siday-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("DOCUMENTS"), withIntermediateDirectories: true)
    let database = folder.appendingPathComponent("DOCUMENTS/Songlengths.md5")
    try Data("[Database]\n; /MUSICIANS/X/Tune.sid\n0123456789abcdef0123456789abcdef=1:00\n".utf8).write(to: database)
    let empty = folder.appendingPathComponent("empty.md5"), other = folder.appendingPathComponent("notes.txt")
    try Data().write(to: empty)
    try Data("Nothing here gives a length.\nname=value\n".utf8).write(to: other)

    #expect(SongLengths.isDatabase(atPath: database.path))
    #expect(!SongLengths.isDatabase(atPath: empty.path))
    #expect(!SongLengths.isDatabase(atPath: other.path))
    #expect(!SongLengths.isDatabase(atPath: folder.appendingPathComponent("missing.md5").path))

    // Named in place of a database, such a file does not stop the one beside the tune being found.
    let tune = folder.appendingPathComponent("MUSICIANS/X/Tune.sid")
    for named in [empty, other] {
        let found = SongLengthDatabase.find(explicitPath: named.path, near: tune)
        #expect(found?.lengths(data: Data(), url: tune) == [60])
    }
}
