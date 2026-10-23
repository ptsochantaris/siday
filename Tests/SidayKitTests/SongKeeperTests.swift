// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import SidayKit
@testable import SidayPlayer

/// A keeper with the test module loaded, as tune 1, run 1.
private func loaded() -> SongKeeper {
    let keeper = SongKeeper()
    keeper.load(tune: 1, serial: 1, name: "square.mod", bytes: squareModule(), companions: [], subsong: -1, now: 0)
    return keeper
}

/// Renders the whole song.
private func renderWhole(_ keeper: SongKeeper, now: Double = 10) {
    var turns = 0
    while keeper.work(chunks: 50, now: now), turns < 10_000 { turns += 1 }
}

@Test func keeperTellsOfTheTuneItLoads() throws {
    let keeper = loaded()
    guard case .loaded(let tune, let plays, let problem, let info, _, _, let length, _, let key) = try #require(keeper.events.first) else {
        Issue.record("no loaded event"); return
    }
    #expect(tune == 1 && plays && problem == nil)
    #expect(info?.title == "square")
    #expect(length > 0)
    #expect(!key.isEmpty)
    let refused = SongKeeper()
    refused.load(tune: 2, serial: 2, name: "nothing.doc", bytes: [0], companions: [], subsong: -1, now: 0)
    guard case .loaded(_, let plays2, let problem2, _, _, _, _, _, _) = try #require(refused.events.first) else { return }
    #expect(!plays2 && problem2 == "unknown file type .doc")
}

@Test func keeperSendsNoMoreThanAFifthOfASecondAhead() {
    let keeper = loaded()
    renderWhole(keeper)
    #expect(keeper.outbox.count == SongKeeper.ahead)
    #expect(keeper.outbox.allSatisfy { $0.serial == 1 && $0.tune == 1 && $0.samples.count == SongKeeper.chunkFrames * 2 })
    // Each chunk reaches further into the song than the last.
    let places = keeper.outbox.map(\.position)
    #expect(places == places.sorted() && places[0] > 0)
    // Once one is heard there is room for one more.
    keeper.played(serial: 1, now: 10)
    #expect(keeper.outbox.count == SongKeeper.ahead + 1)
    // What is heard of a run that has been left is no news.
    keeper.played(serial: 7, now: 10)
    #expect(keeper.outbox.count == SongKeeper.ahead + 1)
}

@Test func keeperSendsFromWhereTheListenerMovesTo() throws {
    let keeper = loaded()
    renderWhole(keeper)
    keeper.outbox.removeAll()
    keeper.seek(to: 2, serial: 2, now: 10)
    let first = try #require(keeper.outbox.first)
    #expect(first.serial == 2)
    #expect(abs(first.position - 2) < 0.05)
}

@Test func keeperWaitsAMomentForAKeptLevelWhenSongsAreLevelled() {
    let keeper = SongKeeper()
    var values = Setting.standards
    values[Setting.levelling.rawValue] = 1
    keeper.setSettings(values)
    keeper.load(tune: 1, serial: 1, name: "square.mod", bytes: squareModule(), companions: [], subsong: -1, now: 0)
    keeper.work(chunks: 20, now: 0.05)
    // Nothing is sent while the front end may yet say what level was kept for the song.
    #expect(keeper.outbox.isEmpty)
    keeper.setKeptLevel(key: keeper.player.levelKey, text: SongLevel(loudness: -20, truePeak: -3).text, now: 0.06)
    #expect(!keeper.outbox.isEmpty)
}

@Test func keeperSaysHowMuchOfTheSongIsReady() {
    let keeper = loaded()
    renderWhole(keeper)
    let ready = keeper.events.compactMap { event -> Double? in
        if case .rendered(_, let seconds, _) = event { return seconds }
        return nil
    }
    #expect(!ready.isEmpty)
    #expect(ready == ready.sorted())
}

@Test func keeperLeavesOutAVoiceTheListenerMutes() throws {
    let keeper = loaded()
    renderWhole(keeper)
    #expect(keeper.shown.filter { $0 }.count == 4)
    keeper.mute(light: 0, solo: false)
    guard case .muted(_, let marks) = try #require(keeper.events.last(where: { if case .muted = $0 { return true }; return false })) else { return }
    #expect(marks == [1, 0, 0, 0])
    renderWhole(keeper)
    // Sent from the start again, the song is silent: its one note was on the voice left out.
    keeper.outbox.removeAll()
    keeper.seek(to: 0, serial: 3, now: 20)
    let loudest = keeper.outbox.flatMap(\.samples).map { abs($0) }.max() ?? 1
    #expect(loudest < 0.0001)
    // And the voice is marked as left out in what is sent.
    let sent = try #require(keeper.outbox.first)
    #expect(sent.voices.suffix(4) == [1, 0, 0, 0])
    // Heard alone, the others are left out; heard alone again, every voice is back.
    keeper.mute(light: 1, solo: true)
    keeper.mute(light: 1, solo: true)
    guard case .muted(_, let back) = try #require(keeper.events.last(where: { if case .muted = $0 { return true }; return false })) else { return }
    #expect(back == [0, 0, 0, 0])
}
