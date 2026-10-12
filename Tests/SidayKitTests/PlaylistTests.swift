// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import SidayKit

/// A playlist as Ay_Emul writes one: lines that end as Windows ends them.
private func list(_ lines: [String], version: String = "1.6") -> [UInt8] {
    Array((["ZX Spectrum Sound Chip Emulator Play List File v\(version)"] + lines).joined(separator: "\r\n").utf8) + [0x0D, 0x0A]
}

@Test func playlistNamesItsTunesInItsOrder() throws {
    let playlist = try #require(PlaylistFile(list([
        #"..\..\Authors\Someone\Second.pt3"#,
        "<", "Author=Someone", "Name=A tune", "Comment=2. 6,35 points", "Time=2048", ">",
        #"First.stc"#,
        "",
        #"sub/folder/./Third.ay"#,
    ])))
    #expect(playlist.entries.map(\.path) == [["..", "..", "Authors", "Someone", "Second.pt3"], ["First.stc"], ["sub", "folder", "Third.ay"]])
    #expect(playlist.entries.map(\.note) == ["2. 6,35 points", "", ""])
    #expect(playlist.entries.map(\.fileExtension) == ["pt3", "stc", "ay"])
    #expect(playlist.entries[0].name == "../../Authors/Someone/Second.pt3")
    #expect(!playlist.entries[0].absolute)
}

@Test func playlistSettingsBeforeTheFirstTuneAreNoTune() throws {
    // The oldest lists begin with Ay_Emul's settings, which are said of every tune and are none.
    let playlist = try #require(PlaylistFile(list([
        "<", "Channels=Stereo", "ChipFrequency=1773400", "Comment=not about a tune", ">",
        "One.stc",
        "<", "Name=One", "Length=3785", ">",
        // A module for two chips has what is known of each half, one after the other.
        "<", "Length=3887", "Offset=3785", "Comment=the second half", ">",
        "Two.stc",
    ], version: "1.0")))
    #expect(playlist.entries.map(\.path) == [["One.stc"], ["Two.stc"]])
    #expect(playlist.entries.map(\.note) == ["the second half", ""])
}

@Test func playlistIsReadInCyrillicOrUnicode() throws {
    // "Моя" in the Cyrillic of Windows, which is not well-formed Unicode, and then as Unicode.
    var old = list(["A.pt2", "<"])
    old += Array("Comment=".utf8) + [0xCC, 0xEE, 0xFF, 0x2E, 0x09, 0x20, 0x0D, 0x0A, 0x3E, 0x0D, 0x0A]
    #expect(PlaylistFile(old)?.entries.first?.note == "Моя.")
    let new = [0xEF, 0xBB, 0xBF] + list(["Папка/Музыка.pt2", "<", "Comment=Моя — «своя»", ">"])
    #expect(PlaylistFile(new)?.entries.first?.note == "Моя — «своя»")
    #expect(PlaylistFile(new)?.entries.first?.path == ["Папка", "Музыка.pt2"])
}

@Test func whatIsNotAPlaylistIsNotRead() {
    #expect(PlaylistFile([]) == nil)
    #expect(PlaylistFile(Array("#EXTM3U\nA.pt3\n".utf8)) == nil)
    #expect(PlaylistFile(Array("ZX Spectrum Sound Chip Emulator Play List File v1.6".utf8))?.entries.isEmpty == true)
    #expect(PlaylistFile.reads(fileExtension: "AYL"))
    #expect(!PlaylistFile.reads(fileExtension: "pt3"))
    // Bytes of every kind, and a list cut short at every place, are read without a trap.
    var noise = list(["a\\b.pt3", "<", "Comment=x", ">"])
    for cut in 0 ... noise.count { _ = PlaylistFile(Array(noise[..<cut])) }
    for value in 0 ... 255 {
        noise[50 + value % 20] = UInt8(value)
        _ = PlaylistFile(noise)
    }
}

@Test func playlistTunesAreFoundByTheEndsOfTheirPaths() throws {
    let finder = PlaylistFile.Finder([
        "music/Authors/Alos/Girl.pt2",
        "music/Authors/Davos/Girl.pt2",
        "music/Authors/Zbigniew N/Solidarnosc.stc",
        "Loose.pt3",
        "other/Authors/Davos/Girl.pt2",
    ])
    func place(_ path: [String]) -> Int? { finder.place(of: PlaylistFile.Entry(path: path)) }
    // The folders above the file say which of several of the same name is meant; the first, of those that are as good.
    #expect(place(["..", "..", "Authors", "Davos", "GIRL.pt2"]) == 1)
    #expect(place(["..", "..", "Authors", "Alos", "girl.pt2"]) == 0)
    #expect(place(["other", "Authors", "Davos", "Girl.pt2"]) == 4)
    // With none of its folders among them, a file of its name is still it.
    #expect(place(["Elsewhere", "Girl.pt2"]) == 0)
    #expect(place(["a", "b", "Loose.PT3"]) == 3)
    // Windows keeps no full stop at the end of a folder's name, whatever the list says.
    #expect(place(["..", "Authors", "Zbigniew N.", "Solidarnosc.stc"]) == 2)
    #expect(place(["Authors", "Davos", "Boy.pt2"]) == nil)
    #expect(place([]) == nil)
    // A tune beside the list or below it is the file at just that path, when the list's own is known.
    func beside(_ list: String, _ path: [String]) -> Int? { finder.place(of: PlaylistFile.Entry(path: path), besideList: list) }
    #expect(beside("other/all.ayl", ["Authors", "Davos", "GIRL.pt2"]) == 4)
    #expect(beside("music/Authors/Davos/one.ayl", ["girl.pt2"]) == 1)
    #expect(beside("list.ayl", ["Loose.pt3"]) == 3)
    #expect(beside("music/all.ayl", ["Davos", "Girl.pt2"]) == nil)
    #expect(beside("music/Authors/Alos/link.ayl", ["..", "Davos", "Girl.pt2"]) == nil)
    #expect(PlaylistFile.Finder([]).place(of: PlaylistFile.Entry(path: ["Girl.pt2"])) == nil)
}
