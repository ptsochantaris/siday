// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

// What a player with a list of tunes does between the listener and its engine, for the web page and
// the app alike: which tune plays after which, what is known of the one playing, and what follows a
// song that has ended. It knows nothing of files, of the screen or of sound: a front end keeps one,
// in whatever it watches for changes, does what it says is to be done next (`TuneQueue.Step`), and
// tells it what the engine says. The tunes are known only by their places in the front end's list.

/// What is known about the tune that is playing.
public struct Tune: Equatable, Sendable {
    public var format: String
    public var title: String
    public var author: String
    public var detail: String
    /// Its songs, when it has more than one: what each is called and how long it is, where the file says.
    public var songs: [Song]
    /// The song that is playing, counted from 0.
    public var song: Int
    public var length: Double
    /// What its file asks for that is not played as it asks, a sentence each: an instrument that is
    /// not heard, a command that is left out. None, for a tune that is played whole.
    public var shortfalls: [String]
    /// The chips it is heard as made by, the one that makes the most of it first (`TuneInfo.chips`).
    public var chips: [SoundChip]
    /// The ROMs that, once kept, would have it played on another synthesiser (`TuneInfo.playedOtherwiseWith`).
    public var playedOtherwiseWith: [KeptROMs]

    public struct Song: Equatable, Sendable {
        public var title: String
        public var length: Double?
        /// True if there is known to be nothing in it: it is passed over when songs are played in turn.
        public var empty: Bool
        /// True while it is still being played through, unheard, to find how long it is (`SongInfo.pending`).
        public var pending: Bool

        public init(title: String, length: Double?, empty: Bool = false, pending: Bool = false) {
            self.title = title
            self.length = length
            self.empty = empty
            self.pending = pending
        }

        public init(_ song: SongInfo) {
            self.init(title: song.title, length: song.length, empty: song.empty, pending: song.pending)
        }
    }

    public init(format: String, title: String, author: String, detail: String, songs: [Song], song: Int, length: Double, shortfalls: [String] = [],
                chips: [SoundChip] = [], playedOtherwiseWith: [KeptROMs] = []) {
        self.format = format
        self.title = title
        self.author = author
        self.detail = detail
        self.songs = songs
        self.song = song
        self.length = length
        self.shortfalls = shortfalls
        self.chips = chips
        self.playedOtherwiseWith = playedOtherwiseWith
    }

    /// A tune as its engine tells of it (`SongKeeper.Event.loaded`).
    public init(_ info: TuneInfo, songs: [SongInfo], song: Int, length: Double) {
        self.init(format: info.format, title: info.title, author: info.author, detail: info.detail,
                  songs: songs.map(Song.init), song: song, length: length, shortfalls: info.shortfalls, chips: info.chips,
                  playedOtherwiseWith: info.playedOtherwiseWith)
    }

    /// A tune from its details in words, as `TunePlayer.details` puts them, of a tune of `count` songs.
    public init(details: String, songs count: Int, song: Int, length: Double) {
        let lines = Self.lines(details)
        func line(_ index: Int) -> String { index < lines.count ? lines[index] : "" }
        let songs = count > 1 ? Self.songs(count, in: lines) : []
        // (After the songs: what the file asks for that is not played as it asks, each line of it
        // marked with an exclamation mark.)
        let shortfalls = lines.dropFirst(4 + songs.count).filter { $0.utf8.first == 0x21 }.map { String($0.dropFirst()) }
        // (And the chips it is heard as made by, each marked with a hash.)
        let chips = lines.dropFirst(4 + songs.count).filter { $0.utf8.first == 0x23 }.compactMap { SoundChip(rawValue: String($0.dropFirst())) }
        // (And the ROMs that would have it played on another synthesiser, each marked with an at sign.)
        let otherwise = lines.dropFirst(4 + songs.count).filter { $0.utf8.first == 0x40 }.compactMap { KeptROMs(rawValue: String($0.dropFirst())) }
        self.init(format: line(0), title: line(1), author: line(2), detail: line(3), songs: songs, song: song, length: length, shortfalls: shortfalls, chips: chips,
                  playedOtherwiseWith: otherwise)
    }

    /// The songs of a tune of `count` songs, from its details in words (see `TunePlayer.details`).
    public static func songs(_ count: Int, inDetails details: String) -> [Song] {
        songs(count, in: lines(details))
    }

    private static func lines(_ details: String) -> [String] {
        details.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    }

    /// A song's line: its length in milliseconds or a question mark while that is still to be found, a
    /// tab, 1 for a song known to have nothing in it, a tab, and its name.
    private static func songs(_ count: Int, in lines: [String]) -> [Song] {
        (0 ..< count).map { index in
            let fields = (4 + index < lines.count ? lines[4 + index] : "").split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            let milliseconds = fields.first.flatMap { Int($0) }
            return Song(title: fields.count > 2 ? String(fields[2]) : "", length: milliseconds.map { Double($0) / 1000 },
                        empty: fields.count > 1 && fields[1] == "1", pending: fields.first == "?")
        }
    }

    /// True when the file names its songs, and not only numbers them.
    public var namesSongs: Bool { songs.contains { !$0.title.isEmpty } }

    /// Which of its songs are played when one ends and the next is to follow, with the listener's
    /// settings as they are: all of them, but for those the listener has asked to have passed over as
    /// too short; or none, if only a file's main song is to be played. The rule is the engine's own,
    /// which chooses the first by it.
    public func songsInTurn(_ settings: [Double]) -> [Bool] {
        guard Setting.songs.value(in: settings) == 0 else { return songs.map { _ in false } }
        return PlaybackPolicy.playedInTurn(songs.map { $0.length }, empty: songs.map { $0.empty },
                                           shortest: Setting.shortestSong.amount(of: Setting.shortestSong.value(in: settings)))
    }

    /// True if one of its songs is passed over when they are played in turn.
    public func passesOver(_ song: Int, _ settings: [Double]) -> Bool {
        let played = songsInTurn(settings)
        return Setting.songs.value(in: settings) == 0 && played.indices.contains(song) && !played[song]
    }
}

/// Which tune of a list plays after which, and what is known of the one that is playing.
public struct TuneQueue: Sendable {
    /// What a front end is to do next.
    public enum Step: Equatable, Sendable {
        case none
        /// Play the tune at this place in the list, from this song (or from the one the file starts
        /// with, for -1): that is, ask `play` and then the engine.
        case play(Int, song: Int)
        /// The last tune of the list has played to its end, and playing stops there.
        case finish
        /// The tune that was playing has been taken out of the list, and nothing follows it.
        case stop
    }

    /// How many tunes the list has.
    public private(set) var count = 0
    /// The order tunes are played in: places in the list.
    private var order: [Int] = []
    public private(set) var shuffled = false
    /// The place in the list of the tune that is playing or was asked for.
    public private(set) var current: Int?
    public private(set) var tune: Tune?
    /// The place in the list of the tune `tune` describes.
    public private(set) var tuneFile: Int?
    /// Why the tune asked for is not playing, when it is not.
    public private(set) var problem: String?
    /// True once the last tune of the list has finished.
    public private(set) var finished = false
    /// Tunes in a row that would not play. When it reaches the length of the list, there is nothing to play.
    private var failures = 0
    /// True when a song ended while some of the tune's songs were still being played through: which
    /// song follows it waits until it is known which of them are passed over.
    private var endedUnfollowed = false

    public init() {}

    private var orderPlace: Int {
        guard let current else { return -1 }
        return order.firstIndex(of: current) ?? -1
    }

    // MARK: The list

    /// Tunes have been added at the end of the list. If nothing is playing, or the list had finished,
    /// the first of them plays; mixed in with those still to come, if the order is shuffled.
    public mutating func add(_ added: Int) -> Step {
        guard added > 0 else { return .none }
        let first = count
        count += added
        order.append(contentsOf: first ..< count)
        if shuffled { order[max(1, orderPlace + 1)...].shuffle() }
        guard current == nil || finished else { return .none }
        return .play(order[first == 0 ? 0 : min(orderPlace + 1, order.count - 1)], song: -1)
    }

    /// Tunes have been added at a place in the list, those that were there and after it moved along
    /// past them; otherwise as `add(_:)`, and if one is to play, it is the first of them.
    public mutating func add(_ added: Int, at place: Int) -> Step {
        let first = count
        let step = add(added)
        guard added > 0, place >= 0, place < first else { return step }
        let newPlace = rearrange(moving: Array(first ..< count), to: place)
        if case .play(let index, let song) = step { return .play(newPlace[index], song: song) }
        return step
    }

    /// Tunes have been moved within the list: those at these places, in the order they were in, now
    /// come just before the tune that was at `destination` (or at the end, for the list's length).
    /// What is playing goes on, and what plays after it follows the list's new order; or, if the
    /// order is shuffled, the same tunes as before.
    public mutating func move(_ places: [Int], to destination: Int) {
        _ = rearrange(moving: places, to: destination)
    }

    /// Moves tunes within the list (see `move`), and says where each place in it went.
    private mutating func rearrange(moving places: [Int], to destination: Int) -> [Int] {
        var moved = [Bool](repeating: false, count: count)
        for place in places where place >= 0 && place < count { moved[place] = true }
        // The list as it is to be, by the places its tunes had.
        var list = (0 ..< count).filter { !moved[$0] }
        let before = list.count { $0 < destination }
        list.insert(contentsOf: (0 ..< count).filter { moved[$0] }, at: before)
        var newPlace = [Int](repeating: 0, count: count)
        for (place, was) in list.enumerated() { newPlace[was] = place }
        order = shuffled ? order.map { newPlace[$0] } : Array(0 ..< count)
        current = current.map { newPlace[$0] }
        tuneFile = tuneFile.map { newPlace[$0] }
        return newPlace
    }

    /// A tune has been taken out of the list. If it is the one playing, the next one plays; if there
    /// is no next one, nothing does.
    public mutating func remove(_ index: Int) -> Step {
        guard index >= 0, index < count else { return .none }
        let wasCurrent = index == current
        let place = order.firstIndex(of: index) ?? 0
        count -= 1
        // The order is of places in the list, and those after the one that has gone are each one less.
        order = order.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 }
        if let playing = current, playing > index { current = playing - 1 }
        if let described = tuneFile, described > index { tuneFile = described - 1 }
        guard wasCurrent else { return .none }
        current = nil
        tuneFile = nil
        if place < order.count { return .play(order[place], song: -1) }
        tune = nil
        problem = nil
        finished = false
        return .stop
    }

    /// The list has been emptied: nothing plays until tunes are added again.
    public mutating func removeAll() {
        count = 0
        order = []
        failures = 0
        current = nil
        tuneFile = nil
        tune = nil
        problem = nil
        finished = false
        endedUnfollowed = false
    }

    public mutating func toggleShuffle() {
        shuffled.toggle()
        let place = orderPlace
        if shuffled {
            // What has been played stays where it is; what is to come is mixed.
            if place + 1 < order.count { order[(place + 1)...].shuffle() }
        } else {
            order = Array(0 ..< count)
        }
    }

    // MARK: Playing

    /// A tune is about to be asked of the engine, from a song of it (or from the one its file starts
    /// with, for -1). Returns true if it is another song of the tune whose details are up: they stay
    /// up, with the new song marked, until the song itself reports in.
    @discardableResult
    public mutating func play(_ index: Int, song: Int) -> Bool {
        endedUnfollowed = false
        let same = index == tuneFile && tune?.songs.indices.contains(song) == true
        if same {
            tune?.song = song
        } else {
            tune = nil
            tuneFile = nil
        }
        current = index
        problem = nil
        finished = false
        return same
    }

    /// The engine has loaded the tune last asked for: what it is, or nil and why not, if it does not
    /// play. One that does not is passed over for the next.
    /// - Parameter isListed: whether a tune of the list is in it as it is shown (see `next`).
    public mutating func loaded(_ loaded: Tune?, problem: String, isListed: (Int) -> Bool) -> Step {
        guard var loaded else {
            tune = nil
            tuneFile = nil
            self.problem = problem
            failures += 1
            return failures < count ? next(automatic: true, isListed: isListed) : .none
        }
        failures = 0
        // A song whose file gives no length has it found when it is played. What was found for the
        // songs of this tune played before this one is kept; and so is a song's length found by playing
        // it through since, which this load had still to.
        if current == tuneFile, let known = tune?.songs, known.count == loaded.songs.count {
            for index in loaded.songs.indices where loaded.songs[index].length == nil { loaded.songs[index].length = known[index].length }
            for index in loaded.songs.indices where loaded.songs[index].pending && !known[index].pending { loaded.songs[index] = known[index] }
        }
        tuneFile = current
        tune = loaded
        return .none
    }

    /// The playing song had no length in its file and was given the usual time, or had one and fell
    /// silent for good before it; rendered to its end, it has turned out shorter. That is its length,
    /// here and in the list of songs.
    public mutating func measured(_ length: Double) {
        guard let song = tune?.song else { return }
        tune?.length = length
        if tune?.songs.indices.contains(song) == true { tune?.songs[song].length = length }
    }

    /// It is known now how long each of the playing tune's songs is, which some were still being
    /// played through to find. A song that ended while they were goes on to the one that follows it now.
    public mutating func learned(_ songs: [Tune.Song], settings: [Double], isListed: (Int) -> Bool) -> Step {
        guard var tune, tune.songs.count == songs.count else { return .none }
        for index in songs.indices where tune.songs[index].pending { tune.songs[index] = songs[index] }
        self.tune = tune
        guard endedUnfollowed else { return .none }
        endedUnfollowed = false
        return songEnded(settings: settings, isListed: isListed)
    }

    /// A song has played to its end: the next of the tune's songs that are played in turn follows,
    /// if there is one, and the next tune if not.
    public mutating func songEnded(settings: [Double], isListed: (Int) -> Bool) -> Step {
        if let tune, tune.songs.contains(where: { $0.pending }) {
            endedUnfollowed = true
            return .none
        }
        if let tune {
            let played = tune.songsInTurn(settings)
            if let following = played.indices.first(where: { $0 > tune.song && played[$0] }) { return playSong(following) }
        }
        return next(automatic: true, isListed: isListed)
    }

    /// The next tune in the order, of those the list shows (`isListed`): while there is a search, the
    /// list is what it finds, and playing goes through that and stops at its end; and from a tune
    /// that it does not find, it goes to the first that it does. When a tune ends of its own accord
    /// (`automatic`) at the end of the list, playing stops there.
    public mutating func next(automatic: Bool = false, isListed: (Int) -> Bool) -> Step {
        if let place = following(isListed: isListed) { return .play(order[place], song: -1) }
        guard automatic else { return .none }
        finished = true
        return .finish
    }

    /// The tune before the playing one in the order, of those the list shows.
    public func previous(isListed: (Int) -> Bool) -> Step {
        guard let before = order[..<max(0, orderPlace)].lastIndex(where: isListed) else { return .none }
        return .play(order[before], song: -1)
    }

    public func hasNext(isListed: (Int) -> Bool) -> Bool { following(isListed: isListed) != nil }
    public func hasPrevious(isListed: (Int) -> Bool) -> Bool { order[..<max(0, orderPlace)].contains(where: isListed) }

    private func following(isListed: (Int) -> Bool) -> Int? {
        let from = current.map(isListed) == true ? orderPlace + 1 : 0
        return from < order.count ? order[from...].firstIndex(where: isListed) : nil
    }

    /// A song of the tune that is loaded, counted from 0.
    public func playSong(_ song: Int) -> Step {
        guard let tune, let current, tune.songs.indices.contains(song) else { return .none }
        return .play(current, song: song)
    }

    /// The song after the one playing, or the one before.
    public func song(_ step: Int) -> Step {
        guard let tune else { return .none }
        return playSong(tune.song + step)
    }

    /// Tunes that would not play are counted afresh: what one wanted has been given, and it is to be
    /// tried again.
    public mutating func countFailuresAfresh() {
        failures = 0
    }

    /// The last tune of the list had finished, and its song is played again: after a move to a place
    /// in it, or a press on play.
    public mutating func playAgain() {
        finished = false
    }
}

extension Setting {
    /// Its value, from a list of values for every setting in the order of the cases: as it comes, if
    /// the list is short.
    public func value(in values: [Double]) -> Double {
        values.indices.contains(rawValue) ? values[rawValue] : standard
    }

    /// A value of it as it is kept from one visit to the next: for one chosen from a list, the code of
    /// what is chosen, and for one on a scale, the place on it.
    public func code(of value: Double) -> String {
        switch kind {
        case .choice(let choices): choices[Int(settled(value))].code
        case .scale: "\(Int(settled(value)))"
        }
    }

    /// The settings that have been changed, as they are kept (see `code`): by name, in the order of the cases.
    public static func kept(_ values: [Double]) -> [(name: String, code: String)] {
        allCases.filter { $0.value(in: values) != $0.standard }.map { ($0.name, $0.code(of: $0.value(in: values))) }
    }

    /// The settings as they were kept: every one as it comes, but for those named. Anything not
    /// understood is as it comes.
    public static func remembered(_ kept: [(name: String, code: String)], from values: [Double] = standards) -> [Double] {
        var settings = values
        for (name, code) in kept {
            guard let setting = allCases.first(where: { $0.name == name }) else { continue }
            switch setting.kind {
            case .choice(let choices):
                if let place = choices.firstIndex(where: { $0.code == code }) { settings[setting.rawValue] = Double(place) }
            case .scale:
                if let place = Int(code) { settings[setting.rawValue] = setting.settled(Double(place)) }
            }
        }
        return settings
    }
}

extension TuneFormat {
    /// The part of FORMATS.md that tells of a tune's format, by the word its heading begins with:
    /// by the kind of its file, and what the tune says it is. (A file named PSM is Epic MegaGames'
    /// if the tune says it is, and one named SID SidMon's.) Nil for a file of no kind that is known.
    public static func chapter(fileExtension: String, tuneFormat: String?) -> String? {
        let named = TuneFormat(fileExtension: fileExtension)
        if named == .psm, tuneFormat == "MASI" { return TuneFormat.masi.chapter }
        if named == .sid, tuneFormat == "SID1" { return TuneFormat.sid1.chapter }
        return named?.chapter
    }
}
