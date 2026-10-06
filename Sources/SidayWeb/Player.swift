// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Reactivity
import SidayKit

/// What is known about the tune that is playing.
struct Tune {
    var format: String
    var title: String
    var author: String
    var detail: String
    var songs: Int
    var song: Int
    var length: Double
}

/// The page's state: the list of files, which one is playing, and what the controls do. The files
/// themselves and the sound are the JavaScript side's (see Browser.swift); this is told about them.
@Reactive
final class Player {
    /// The files chosen so far, by name or by path inside the folder they came in.
    private(set) var files: [String] = []
    /// Lower-case copies, for searching.
    private var searchable: [[UInt8]] = []
    /// The place in `files` of the tune that is playing or was asked for.
    private(set) var current: Int?
    private(set) var tune: Tune?
    /// Why the current file is not playing, when it is not.
    private(set) var problem: String?
    private(set) var paused = false
    /// True once the last tune of the list has finished.
    private(set) var finished = false
    private(set) var position = 0.0
    private(set) var level = 0.0
    private(set) var television: TelevisionSet?
    private(set) var shuffled = false
    /// The order tunes are played in: places in `files`.
    private var order: [Int] = []
    /// Files in a row that would not play. When it reaches the length of the list, there is nothing to play.
    private var failures = 0

    var search = "" {
        didSet { needle = Array(search.lowercased().utf8) }
    }

    private var needle: [UInt8] = []

    /// Connects the page to the JavaScript side. Called once.
    func start() {
        try? sidayListen(
            { name in
                let parts = name.split(separator: ".")
                return parts.count > 1 && TuneFormat(fileExtension: String(parts[parts.count - 1])) != nil
            },
            { [self] names in add(names.split(separator: "\n").map { String($0) }) },
            { [self] plays, text, songs, song, length in loaded(plays, text, songs, song, length) },
            { [self] seconds, loudness in
                position = seconds
                level = loudness
            },
            { [self] in next(automatic: true) },
            { [self] in paused = true }
        )
    }

    // MARK: The list

    private func add(_ names: [String]) {
        guard !names.isEmpty else { return }
        let first = files.count
        files.append(contentsOf: names)
        searchable.append(contentsOf: names.map { Array($0.lowercased().utf8) })
        order.append(contentsOf: first ..< files.count)
        if shuffled { order[max(1, orderPlace + 1)...].shuffle() }
        if current == nil || finished { play(order[first == 0 ? 0 : min(orderPlace + 1, order.count - 1)]) }
    }

    /// Places in `files` to show: those that match the search, or a stretch around the playing tune.
    var visible: (rows: [Int], total: Int) {
        let limit = 200
        if needle.isEmpty {
            let start = max(0, min((current ?? 0) - 8, files.count - limit))
            return (Array(start ..< min(files.count, start + limit)), files.count)
        }
        var rows: [Int] = [], total = 0
        for index in files.indices where contains(searchable[index], needle) {
            total += 1
            if rows.count < limit { rows.append(index) }
        }
        return (rows, total)
    }

    private func contains(_ text: [UInt8], _ part: [UInt8]) -> Bool {
        guard part.count <= text.count else { return false }
        var start = 0
        while start + part.count <= text.count {
            var index = 0
            while index < part.count, text[start + index] == part[index] { index += 1 }
            if index == part.count { return true }
            start += 1
        }
        return false
    }

    private var orderPlace: Int {
        guard let current else { return -1 }
        return order.firstIndex(of: current) ?? -1
    }

    // MARK: Playing

    func play(_ index: Int, song: Int = -1) {
        guard files.indices.contains(index) else { return }
        current = index
        tune = nil
        problem = nil
        finished = false
        paused = false
        position = 0
        level = 0
        try? sidayPlay(index, song)
    }

    private func loaded(_ plays: Bool, _ text: String, _ songs: Int, _ song: Int, _ length: Double) {
        guard plays else {
            problem = text
            failures += 1
            if failures < files.count { next(automatic: true) }
            return
        }
        failures = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        func line(_ index: Int) -> String { index < lines.count ? lines[index] : "" }
        tune = Tune(format: line(0), title: line(1), author: line(2), detail: line(3), songs: songs, song: song, length: length)
    }

    /// The next tune in the order. When a tune ends of its own accord at the end of the list, playing stops there.
    func next(automatic: Bool = false) {
        let place = orderPlace + 1
        if place < order.count {
            play(order[place])
        } else if automatic {
            finished = true
            level = 0
        }
    }

    func previous() {
        let place = orderPlace - 1
        if place >= 0 { play(order[place]) }
    }

    func song(_ step: Int) {
        guard let tune, let current else { return }
        let song = tune.song + step
        guard song >= 0, song < tune.songs else { return }
        // Nothing comes back for a change of song but the progress that follows, so the details are kept
        // and the song number moved on; the new song's length arrives with a fresh load.
        play(current, song: song)
    }

    func togglePause() {
        guard tune != nil, !finished else { return }
        paused.toggle()
        if paused { level = 0 }
        try? sidayPause(paused)
    }

    /// Off, then each set in turn.
    func cycleTelevision() {
        let sets = TelevisionSet.allCases
        let place = television.flatMap { sets.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        television = place < sets.count ? sets[place] : nil
        try? sidayTelevision(television.flatMap { sets.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    }

    func toggleShuffle() {
        shuffled.toggle()
        let place = orderPlace
        if shuffled {
            // What has been played stays where it is; what is to come is mixed.
            if place + 1 < order.count { order[(place + 1)...].shuffle() }
        } else {
            order = Array(files.indices)
        }
    }

    /// The keys of the command-line player.
    func key(_ key: String) {
        switch key {
        case " ": togglePause()
        case "n", "N", "ArrowRight": next()
        case "p", "P", "ArrowLeft": previous()
        case "+", "=", "ArrowUp": song(1)
        case "-", "_", "ArrowDown": song(-1)
        case "t", "T": cycleTelevision()
        default: break
        }
    }
}
