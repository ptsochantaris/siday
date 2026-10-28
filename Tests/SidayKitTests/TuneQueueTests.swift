// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayFoundation
@testable import SidayPlayer
import Testing

// MARK: Which tune plays after which, for the web page and the app

private func everyTune(_: Int) -> Bool { true }

/// A tune of songs of these lengths, playing the first.
private func tune(_ lengths: [Double?], pending: Set<Int> = [], song: Int = 0) -> Tune {
    Tune(format: "Test", title: "", author: "", detail: "",
         songs: lengths.indices.map { Tune.Song(title: "", length: lengths[$0], pending: pending.contains($0)) },
         song: song, length: 60)
}

@Test func aQueuePlaysTheFirstTuneAddedAndTheNextInTurn() {
    var queue = TuneQueue()
    #expect(queue.add(3) == .play(0, song: -1))
    queue.play(0, song: -1)
    // (Tunes added while one plays wait their turn.)
    #expect(queue.add(2) == .none)
    #expect(queue.next(isListed: everyTune) == .play(1, song: -1))
    queue.play(4, song: -1)
    #expect(queue.next(isListed: everyTune) == .none && !queue.finished)
    #expect(queue.next(automatic: true, isListed: everyTune) == .finish && queue.finished)
    // Added to a list that has finished, the first of them plays.
    #expect(queue.add(1) == .play(5, song: -1))
    #expect(queue.previous(isListed: everyTune) == .play(3, song: -1))
}

@Test func aQueueGoesThroughWhatTheSearchFindsAndFromATuneItDoesNotToTheFirstItDoes() {
    var queue = TuneQueue()
    _ = queue.add(6)
    queue.play(2, song: -1)
    let found: (Int) -> Bool = { [1, 4].contains($0) }
    #expect(queue.next(isListed: found) == .play(1, song: -1))
    queue.play(1, song: -1)
    #expect(queue.next(isListed: found) == .play(4, song: -1))
    #expect(queue.hasPrevious(isListed: found) == false)
    queue.play(4, song: -1)
    #expect(queue.hasNext(isListed: found) == false && queue.hasPrevious(isListed: found))
}

@Test func aSongThatEndsIsFollowedByTheNextPlayedInTurnAndTheLastByTheNextTune() {
    var queue = TuneQueue()
    _ = queue.add(2)
    queue.play(0, song: -1)
    // The second is a moment long, and is passed over.
    _ = queue.loaded(tune([90, 1, 40]), problem: "", isListed: everyTune)
    #expect(queue.songEnded(settings: Setting.standards, isListed: everyTune) == .play(0, song: 2))
    let same = queue.play(0, song: 2)
    #expect(same && queue.tune?.song == 2)
    #expect(queue.songEnded(settings: Setting.standards, isListed: everyTune) == .play(1, song: -1))
    // With only a file's main song played, the next tune follows at once.
    var main = Setting.standards
    main[Setting.songs.rawValue] = 1
    queue.play(0, song: 0)
    #expect(queue.songEnded(settings: main, isListed: everyTune) == .play(1, song: -1))
    #expect(queue.tune?.passesOver(1, Setting.standards) == true && queue.tune?.passesOver(1, main) == false)
}

@Test func aSongThatEndsWhileSongsAreStillBeingPlayedThroughWaitsForThem() {
    var queue = TuneQueue()
    _ = queue.add(2)
    queue.play(0, song: -1)
    _ = queue.loaded(tune([90, nil, nil], pending: [1, 2]), problem: "", isListed: everyTune)
    #expect(queue.songEnded(settings: Setting.standards, isListed: everyTune) == .none)
    // Once they are known: the second is passed over, and the third follows.
    let found = [Tune.Song(title: "", length: 90), Tune.Song(title: "", length: 2), Tune.Song(title: "", length: 30)]
    #expect(queue.learned(found, settings: Setting.standards, isListed: everyTune) == .play(0, song: 2))
    #expect(queue.tune?.songs.map(\.length) == [90, 2, 30])
}

@Test func aTuneLoadedAgainKeepsTheLengthsFoundForItsSongs() {
    var queue = TuneQueue()
    _ = queue.add(1)
    queue.play(0, song: -1)
    _ = queue.loaded(tune([nil, 20]), problem: "", isListed: everyTune)
    queue.measured(12)
    #expect(queue.tune?.length == 12 && queue.tune?.songs[0].length == 12)
    // Its second song: the details stay up, and what was found stays with them.
    let same = queue.play(0, song: 1)
    #expect(same)
    _ = queue.loaded(tune([nil, 20], pending: [1], song: 1), problem: "", isListed: everyTune)
    #expect(queue.tune?.songs.map(\.length) == [12, 20] && queue.tune?.song == 1)
}

@Test func aTuneThatWillNotPlayIsPassedOverUntilNoneWill() {
    var queue = TuneQueue()
    _ = queue.add(2)
    queue.play(0, song: -1)
    #expect(queue.loaded(nil, problem: "no", isListed: everyTune) == .play(1, song: -1))
    #expect(queue.problem == "no" && queue.tune == nil)
    queue.play(1, song: -1)
    // (Two in a row of a list of two: there is nothing to play.)
    #expect(queue.loaded(nil, problem: "no", isListed: everyTune) == .none)
    queue.countFailuresAfresh()
    queue.play(1, song: -1)
    #expect(queue.loaded(nil, problem: "no", isListed: everyTune) == .finish)
}

@Test func aTuneTakenOutOfTheListIsFollowedByTheNextOrByNothing() {
    var queue = TuneQueue()
    _ = queue.add(3)
    queue.play(1, song: -1)
    _ = queue.loaded(tune([30]), problem: "", isListed: everyTune)
    // One before it: the places after it are each one less.
    #expect(queue.remove(0) == .none)
    #expect(queue.current == 0 && queue.tuneFile == 0 && queue.count == 2)
    #expect(queue.remove(0) == .play(0, song: -1))
    queue.play(0, song: -1)
    #expect(queue.remove(0) == .stop)
    #expect(queue.current == nil && queue.tune == nil && queue.count == 0)
}

@Test func aTunesDetailsInWordsComeBackAsTheTune() {
    var info = TuneInfo(format: "DeliTracker custom")
    info.title = "A\tB"
    info.author = "Someone"
    info.shortfalls = ["An instrument is not heard."]
    info.chips = [.opl3]
    info.playedOtherwiseWith = [.mt32, .sc55]
    let songs = [SongInfo(title: "Title", length: 92.5), SongInfo(empty: true), SongInfo(pending: true)]
    let details = TunePlayer.details(of: info, songs: songs)
    let tune = Tune(details: details, songs: songs.count, song: 1, length: 30)
    #expect(tune == Tune(info, songs: songs, song: 1, length: 30).with { $0.title = "A B" })
    #expect(Tune.songs(3, inDetails: details) == songs.map(Tune.Song.init))
    // A tune of one song lists none.
    #expect(Tune(details: TunePlayer.details(of: info, songs: []), songs: 1, song: 0, length: 30).songs.isEmpty)
}

@Test func settingsAreKeptByNameAndCodeAndComeBack() {
    var settings = Setting.standards
    settings[Setting.levelling.rawValue] = 1
    settings[Setting.sidFilter.rawValue] = 70
    let kept = Setting.kept(settings)
    #expect(kept.map(\.name) == ["level", "sid-filter-curve"] && kept.map(\.code) == ["full", "70"])
    #expect(Setting.remembered(kept) == settings)
    #expect(Setting.remembered([("level", "nonsense"), ("nothing", "1")]) == Setting.standards)
    #expect(TuneFormat.chapter(fileExtension: "psm", tuneFormat: "MASI") == TuneFormat.masi.chapter)
}

private extension Tune {
    func with(_ change: (inout Tune) -> Void) -> Tune {
        var tune = self
        change(&tune)
        return tune
    }
}

@Test func tunesAddedAtAPlaceOrMovedKeepWhatPlaysAndWhatFollowsIt() {
    var queue = TuneQueue()
    _ = queue.add(3)
    queue.play(1, song: -1)
    _ = queue.loaded(tune([30]), problem: "", isListed: everyTune)
    // Two added before the one playing: it and the one after it are two places on, and it goes on.
    #expect(queue.add(2, at: 1) == .none)
    #expect(queue.current == 3 && queue.tuneFile == 3 && queue.count == 5)
    #expect(queue.next(isListed: everyTune) == .play(4, song: -1))
    // Added at the end, as without a place.
    #expect(queue.add(1, at: 5) == .none && queue.count == 6)
    // The last two moved to the front: the one playing is two places on again, and what follows it
    // is what follows it in the list.
    queue.move([4, 5], to: 0)
    #expect(queue.current == 5 && queue.tuneFile == 5)
    #expect(queue.next(isListed: everyTune) == .none && !queue.finished)
    // The one playing moved to the front: what follows it is what is second in the list now.
    queue.move([5], to: 0)
    #expect(queue.current == 0 && queue.next(isListed: everyTune) == .play(1, song: -1))
    // Added at a place to a list that has finished, the first of them plays.
    queue.play(5, song: -1)
    #expect(queue.next(automatic: true, isListed: everyTune) == .finish)
    #expect(queue.add(2, at: 2) == .play(2, song: -1) && queue.count == 8)
}
