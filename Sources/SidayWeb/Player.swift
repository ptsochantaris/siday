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
    /// Its songs, when it has more than one: what each is called and how long it is, where the file says.
    var songs: [Song]
    /// The song that is playing, counted from 0.
    var song: Int
    var length: Double

    struct Song {
        var title: String
        var length: Double?
    }

    /// True when the file names its songs, and not only numbers them.
    var namesSongs: Bool { songs.contains { !$0.title.isEmpty } }
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
    /// The place in `files` of the file `tune` describes.
    private var tuneFile: Int?
    /// Why the current file is not playing, when it is not.
    private(set) var problem: String?
    private(set) var paused = false
    /// True once the last tune of the list has finished.
    private(set) var finished = false
    private(set) var position = 0.0
    /// How much of the playing song is ready to be moved about in, in seconds from its start.
    private(set) var rendered = 0.0
    /// True while the place the listener has moved to is still to be rendered, and the sound is waiting for it.
    var waiting: Bool { position > rendered + 0.05 }
    /// Where on the time bar the pointer is, from 0 to 1, while it is over it.
    private(set) var pointed: Double?
    /// The spectrum analyser: the height of each bar, low notes to high, and of the cap above it, 0 to 1.
    /// (Twenty-four of each: what the audio side sends. Until it does, the bars are there and flat.)
    private(set) var bars = [Double](repeating: 0, count: 24)
    private(set) var caps = [Double](repeating: 0, count: 24)
    /// What tunes are heard through: at first, what they were heard through on the last visit.
    private(set) var output = (try? sidayRememberedOutput()).flatMap { OutputStyle(rawValue: $0) } ?? .mono
    private(set) var shuffled = false
    /// The order tunes are played in: places in `files`.
    private var order: [Int] = []
    /// Files in a row that would not play. When it reaches the length of the list, there is nothing to play.
    private var failures = 0

    var search = "" {
        didSet {
            needle = Array(search.lowercased().utf8)
            find()
            scrollList(to: 0)
        }
    }

    private var needle: [UInt8] = []
    /// The places in `files` of the tunes the search finds, in order. Nil when nothing is being
    /// searched for, and every tune is listed.
    private(set) var found: [Int]?

    /// The height of a row of the list, in pixels. The stylesheet says the same.
    static let rowHeight = 28
    /// How far down the list has been scrolled and how much of it can be seen, in pixels: the
    /// JavaScript side's news. Only the rows in view are drawn, so the list can be as long as it likes.
    private var listTop = 0.0
    private var listHeight = 1200.0

    /// The player's own volume, 0 to 100: at first, what it was on the last visit. (It is asked for
    /// here and not once the page is up, so that the slider is drawn where it belongs from the start.)
    var volume: Double? = (((try? sidayRememberedVolume()) ?? 1) * 100).rounded() {
        didSet { try? sidayVolume(max(0, min(100, volume ?? 100)) / 100) }
    }

    /// Connects the page to the JavaScript side. Called once.
    func start() {
        try? sidayListen(
            { name in
                let parts = name.split(separator: ".")
                return parts.count > 1 && TuneFormat(fileExtension: String(parts[parts.count - 1])) != nil
            },
            { [self] names in add(names.split(separator: "\n").map { String($0) }) },
            { [self] plays, text, songs, song, length in loaded(plays, text, songs, song, length) },
            { [self] seconds, heights in
                position = seconds
                let count = heights.count / 2
                bars = Array(heights[..<count])
                caps = Array(heights[count...])
            },
            { [self] seconds, length in
                rendered = seconds
                if length > 0 { measured(length) }
            },
            { [self] in songEnded() },
            { [self] in paused = true },
            { [self] place, pressed in
                pointed = place >= 0 ? place : nil
                if pressed, place >= 0 { seek(to: place) }
            },
            { [self] top, height in
                if top != listTop { listTop = top }
                if height > 0, height != listHeight { listHeight = height }
            }
        )
        tellOutput()
    }

    // MARK: The list

    private func add(_ names: [String]) {
        guard !names.isEmpty else { return }
        let first = files.count
        files.append(contentsOf: names)
        searchable.append(contentsOf: names.map { Array($0.lowercased().utf8) })
        order.append(contentsOf: first ..< files.count)
        find()
        if shuffled { order[max(1, orderPlace + 1)...].shuffle() }
        if current == nil || finished { play(order[first == 0 ? 0 : min(orderPlace + 1, order.count - 1)]) }
    }

    /// Works out which tunes the search finds.
    private func find() {
        found = needle.isEmpty ? nil : files.indices.filter { contains(searchable[$0], needle) }
    }

    /// How many tunes the list has: all of them, or those the search finds.
    var listed: Int { found?.count ?? files.count }

    /// The rows of the list to draw: those that can be seen and a few either side, as the place in the
    /// list of the first of them and the place in `files` of each.
    var rows: (first: Int, files: [Int]) {
        let spare = 30
        let first = max(0, min(listed, Int(listTop) / Self.rowHeight - spare))
        let last = max(first, min(listed, Int(listTop + listHeight) / Self.rowHeight + 1 + spare))
        return (first, found.map { Array($0[first ..< last]) } ?? Array(first ..< last))
    }

    /// Where a tune is in the list, counted in rows, if it is in it.
    private func row(of index: Int) -> Int? {
        guard let found else { return index }
        return found.firstIndex(of: index)
    }

    private func isInView(_ index: Int) -> Bool {
        guard let row = row(of: index) else { return false }
        let top = Double(row * Self.rowHeight)
        return top + Double(Self.rowHeight) > listTop && top < listTop + listHeight
    }

    private func scrollList(to top: Double) {
        listTop = max(0, top)
        try? sidayScrollList(listTop)
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
        // The list follows the playing tune from one to the next, as long as the listener has not
        // scrolled away from it to look for something else.
        if index != current, let row = row(of: index) {
            // Until the list is first scrolled, its size is a guess: ask.
            if let height = try? sidayListHeight(), height > 0 { listHeight = height }
            if !isInView(index), current.map({ isInView($0) }) ?? true {
                scrollList(to: Double(row * Self.rowHeight) - listHeight / 3)
            }
        }
        // Another song of the tune that is showing: its details stay up, with the new song marked,
        // until the song itself reports in.
        if index == tuneFile, let tune, tune.songs.indices.contains(song) {
            self.tune?.song = song
        } else {
            tune = nil
            tuneFile = nil
        }
        current = index
        problem = nil
        finished = false
        paused = false
        position = 0
        rendered = 0
        try? sidayPlay(index, song)
    }

    private func loaded(_ plays: Bool, _ text: String, _ songs: Int, _ song: Int, _ length: Double) {
        guard plays else {
            tune = nil
            tuneFile = nil
            problem = text
            failures += 1
            if failures < files.count { next(automatic: true) }
            return
        }
        failures = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        func line(_ index: Int) -> String { index < lines.count ? lines[index] : "" }
        var list: [Tune.Song] = []
        if songs > 1 {
            for index in 0 ..< songs {
                let fields = line(4 + index).split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                let milliseconds = fields.first.flatMap { Int($0) }
                list.append(Tune.Song(title: fields.count > 1 ? String(fields[1]) : "", length: milliseconds.map { Double($0) / 1000 }))
            }
            // A song whose file gives no length has it found when it is played. What was found for the
            // songs of this tune played before this one is kept.
            if current == tuneFile, let known = tune?.songs, known.count == list.count {
                for index in list.indices where list[index].length == nil { list[index].length = known[index].length }
            }
        }
        tuneFile = current
        tune = Tune(format: line(0), title: line(1), author: line(2), detail: line(3), songs: list, song: song, length: length)
    }

    /// The playing song had no length in its file and was given the usual time, or had one and fell
    /// silent for good before it; rendered to its end, it has turned out shorter. That is its length,
    /// here and in the list of songs.
    private func measured(_ length: Double) {
        guard let song = tune?.song else { return }
        tune?.length = length
        if tune?.songs.indices.contains(song) == true { tune?.songs[song].length = length }
    }

    /// A song has played to its end: the tune's next song follows if it has one, and the next tune if not.
    private func songEnded() {
        if let tune, tune.song + 1 < tune.songs.count {
            playSong(tune.song + 1)
        } else {
            next(automatic: true)
        }
    }

    /// The next tune in the order. When a tune ends of its own accord at the end of the list, playing stops there.
    func next(automatic: Bool = false) {
        let place = orderPlace + 1
        if place < order.count {
            play(order[place])
        } else if automatic {
            finished = true
            rest()
        }
    }

    func previous() {
        let place = orderPlace - 1
        if place >= 0 { play(order[place]) }
    }

    /// Plays a song of the tune that is loaded, counted from 0.
    func playSong(_ song: Int) {
        guard let tune, let current, tune.songs.indices.contains(song) else { return }
        play(current, song: song)
    }

    /// The song after the one playing, or the one before.
    func song(_ step: Int) {
        if let tune { playSong(tune.song + step) }
    }

    /// Moves to a place in the playing song: how far through it, from 0 to 1. A paused player stays
    /// paused, and will start from there.
    func seek(to place: Double) {
        guard let tune, !finished, tune.length > 0 else { return }
        position = max(0, min(1, place)) * tune.length
        rest()
        try? sidaySeek(position)
    }

    func togglePause() {
        guard tune != nil, !finished else { return }
        paused.toggle()
        if paused { rest() }
        try? sidayPause(paused)
    }

    /// Nothing is sounding: the analyser's bars drop.
    private func rest() {
        bars = bars.map { _ in 0 }
        caps = caps.map { _ in 0 }
    }

    /// Changes what tunes are heard through.
    func hear(through style: OutputStyle) {
        guard style != output else { return }
        output = style
        tellOutput()
    }

    private func tellOutput() {
        if let place = OutputStyle.allCases.firstIndex(of: output) { try? sidayOutput(output.rawValue, place) }
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
        default: break
        }
    }
}
