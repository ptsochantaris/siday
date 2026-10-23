// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayFoundation
@testable import SidayPlayer
import Testing

// MARK: The order tunes are gathered in, for every front end

/// A folder of files known by their paths, with the playlists in it as text.
private struct Folder {
    var files: [String]
    var lists: [String: [PlaylistFile.Entry]] = [:]

    func gather(held: inout Set<String>) -> TuneGathering.Gathered<String> {
        TuneGathering.folder(
            files.sorted(), isList: { lists[$0] != nil }, entries: { lists[$0] ?? [] },
            place: { entry, list in
                if entry.absolute || entry.path.contains("..") { return .elsewhere }
                let path = (list.split(separator: "/").dropLast().map { String($0) } + entry.path).joined(separator: "/")
                return files.contains(path) ? .here(path) : .nowhere
            },
            elsewhere: { entry, _ in entry.path.last.map { "elsewhere/" + $0 } },
            key: { $0 }, held: &held
        )
    }
}

private func entry(_ path: String, note: String = "") -> PlaylistFile.Entry {
    PlaylistFile.Entry(path: path.split(separator: "/").map { String($0) }, note: note)
}

@Test func filesAreKnownByTheirNames() {
    #expect(TuneGathering.kind(ofFileNamed: "music/a/...pt3") == .tune)
    #expect(TuneGathering.kind(ofFileNamed: "x/Tunes.AYL") == .playlist)
    #expect(TuneGathering.kind(ofFileNamed: "x/smp.set.smp") == .companion)
    #expect(TuneGathering.kind(ofFileNamed: "songplay") == .companion)
    #expect(TuneGathering.kind(ofFileNamed: "DOCUMENTS/Songlengths.md5") == .songLengths)
    #expect(TuneGathering.kind(ofFileNamed: "readme") == .other)
}

@Test func aFolderIsPlayedInTheOrderOfItsNamesWithAListsTunesWhereTheListIs() {
    let folder = Folder(
        files: ["f/a.pt3", "f/b.pt3", "f/c.pt3", "f/m.ayl", "f/z.pt3"],
        lists: ["f/m.ayl": [entry("z.pt3", note: "last"), entry("a.pt3"), entry("gone.pt3"), entry("readme.txt"), PlaylistFile.Entry(path: ["..", "x.pt3"])]]
    )
    var held = Set<String>()
    let gathered = folder.gather(held: &held)
    // b and c in their places; the list's tunes where it is, in its order; then the one from elsewhere.
    #expect(gathered.tunes.map(\.item) == ["f/b.pt3", "f/c.pt3", "f/z.pt3", "f/a.pt3", "elsewhere/x.pt3"])
    #expect(gathered.tunes[2].note == "last")
    // (What is no kind of tune is not counted.)
    #expect(gathered.named == 4 && gathered.missing == 1 && gathered.unfound.map(\.name) == ["gone.pt3"])
    #expect(gathered.lists.count == 1 && gathered.lists[0].named == 4 && gathered.lists[0].found == [0, 1, 3])
    // Gathered again, with what was held: nothing comes twice.
    #expect(folder.gather(held: &held).tunes.isEmpty)
}

@Test func aTuneTwoListsNameIsPlayedOnceWhereTheFirstHasIt() {
    let folder = Folder(
        files: ["f/1.ayl", "f/2.ayl", "f/a.pt3", "f/b.pt3"],
        lists: ["f/1.ayl": [entry("b.pt3")], "f/2.ayl": [entry("b.pt3"), entry("a.pt3")]]
    )
    var held = Set<String>()
    #expect(folder.gather(held: &held).tunes.map(\.item) == ["f/b.pt3", "f/a.pt3"])
}

@Test func aListGivenIsPlayedAsItIsWritten() {
    let entries = [entry("b.pt3"), entry("a.pt3"), entry("b.pt3"), entry("lost.pt3")]
    let gathered = TuneGathering.list(entries) { $0.name == "lost.pt3" ? nil : $0.name }
    #expect(gathered.tunes.map(\.item) == ["b.pt3", "a.pt3", "b.pt3"])
    #expect(gathered.named == 4 && gathered.missing == 1 && gathered.lists[0].found == [0, 1, 2])
}
