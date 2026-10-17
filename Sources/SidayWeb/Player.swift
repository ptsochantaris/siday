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
    /// What its file asks for that is not played as it asks, a sentence each: an instrument that is
    /// not heard, a command that is left out. None, for a tune that is played whole.
    var shortfalls: [String] = []

    struct Song {
        var title: String
        var length: Double?
        /// True if there is known to be nothing in it: it is passed over when songs are played in turn.
        var empty = false
    }

    /// True when the file names its songs, and not only numbers them.
    var namesSongs: Bool { songs.contains { !$0.title.isEmpty } }

    /// What is said of a tune that is not played quite as its file asks, before what it is.
    static let shortfallHeading = "Not played quite as the file asks."
}

/// A tune in the list that has been played, and was found not to be played quite as its file asks.
struct Marked {
    /// Its place in the list of files.
    var file: Int
    /// What is not played as it asks: the sentences, one after another.
    var why: String
}

/// A part of the page that the listener can put away, and bring back.
enum Part: String, CaseIterable {
    case analyser, lights, picture, list

    /// What its button says it is.
    var title: String {
        switch self {
        case .analyser: "Spectrum analyser"
        case .lights: "A light for each voice"
        case .picture: "A picture to listen by"
        case .list: "List of tunes"
        }
    }
}

/// The page's state: the list of files, which one is playing, and what the controls do. The files
/// themselves and the sound are the JavaScript side's (see Browser.swift); this is told about them.
@Reactive
final class Player {
    /// The files chosen so far, by name or by path inside the folder they came in.
    private(set) var files: [String] = []
    /// What the playlist a file came by says about it, for each of `files`: empty, for one that came
    /// by none, or that its playlist says nothing of.
    private var notes: [String] = []
    /// The note of the tune that is showing; nil if it has none.
    var note: String? {
        guard let tuneFile, notes.indices.contains(tuneFile), !notes[tuneFile].isEmpty else { return nil }
        return notes[tuneFile]
    }

    /// The part of FORMATS.md that tells of the format of the tune that is showing, by the word
    /// its heading begins with; nil if its file is of no format that is known by its name.
    var chapter: String? {
        guard let tuneFile, files.indices.contains(tuneFile) else { return nil }
        let letters = Array(files[tuneFile].utf8)
        guard let stop = letters.lastIndex(of: 0x2E) else { return nil }
        return TuneFormat(fileExtension: String(decoding: letters[(stop + 1)...], as: UTF8.self))?.chapter
    }

    /// What there is to say about the playlists last added: that tunes they name were not found.
    private(set) var notice: String?
    /// What the tunes of the playlists being read are found among. (Kept out of what the page is
    /// drawn from: it is there only while they are read.)
    private let finding = Finding()
    private final class Finding {
        var among = PlaylistFile.Finder([])
    }

    /// Lower-case copies, for searching.
    private var searchable: [[UInt8]] = []
    /// The place in `files` of the tune that is playing or was asked for.
    private(set) var current: Int?
    private(set) var tune: Tune?
    /// The place in `files` of the file `tune` describes.
    private var tuneFile: Int?
    /// The tunes of the list that have been played and were not played quite as their files ask:
    /// each keeps a mark on its row, which says why. (Only a tune that has been loaded can be known
    /// to be one, so the rest of the list has no marks, whatever is in it.)
    private(set) var marked: [Marked] = []
    /// True while what is not played as the playing tune's file asks is written out under its
    /// details, and not only marked. It stays as it is from one tune to the next.
    private(set) var shortfallsShown = false
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
    /// A light for each voice of the tune: how bright each is, 0 to 1. A light comes on at once and
    /// goes out over a moment, as a lamp does. (As many as the audio side sends: none, for a tune
    /// whose voices cannot be told apart.)
    private(set) var lights: [Double] = []
    /// For each of those voices, what it is playing: a sound a chip makes of itself, which has a red
    /// light, a sample, which has a blue one, or clicks of the computer's own loudspeaker, a pink one.
    private(set) var sampled: [VoiceKind] = []
    /// And whether the listener has muted it: a press on a light mutes its voice or brings it
    /// back, and a right click or a long press has it heard alone. The engine keeps count of that
    /// (`Web/siday.js` tells it of the presses) and says with the sound it sends how things stand.
    private(set) var muted: [Bool] = []
    /// How fast a light goes out, in brightnesses a second: from full to dark in about a seventh of one.
    private static let lightFall = 6.5
    /// The picture to listen by, which is painted from what the voices are doing: see `Visualiser`.
    /// It is not part of what the page is drawn from, and is painted for each frame of the screen.
    private let visualiser = Visualiser(mode: Player.rememberedPicture)
    /// The kind of picture it is: at first, the kind it was on the last visit. (The picture starts as
    /// that kind, in that kind's own colours, and does not come to them from another's.)
    private(set) var picture = Player.rememberedPicture
    private static let rememberedPicture = (try? sidayRememberedPicture()).flatMap { Visualiser.Mode(rawValue: $0) } ?? .lava
    /// What tunes are heard through: at first, what they were heard through on the last visit.
    private(set) var output = Player.outputs.contains(Player.rememberedOutput) ? Player.rememberedOutput : .abc
    private static let rememberedOutput = (try? sidayRememberedOutput()).flatMap { OutputStyle(rawValue: $0) } ?? .mono
    /// What there is to choose from. Stereo is listed once: which way round an AY chip's channels
    /// go is one of the settings.
    static let outputs = OutputStyle.allCases.filter { $0 != .acb }
    private(set) var shuffled = false
    /// The parts of the page that have been put away: at first, those that were on the last visit.
    private(set) var hidden: [Part] = ((try? sidayRememberedHidden()) ?? "").split(separator: ",").compactMap { Part(rawValue: String($0)) }
    /// The listener's settings (see `Setting`): a value for each, in the order of its cases. At
    /// first, what they were on the last visit.
    private(set) var settings = Player.rememberedSettings
    /// True while the panel of settings is on the page. It is opened to change something and shut
    /// again, and so is not remembered: a visit begins with it shut.
    private(set) var settingsShown = false
    /// How many times the settings have all been put back as they come. (The panel is made anew each
    /// time: a list on the page that has been chosen from keeps to what was chosen, whatever it is
    /// told afterwards.)
    private(set) var settingsRound = 0
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
                let letters = Array(name.utf8)
                guard let stop = letters.lastIndex(of: 0x2E) else { return 0 }
                let kind = String(decoding: letters[(stop + 1)...], as: UTF8.self)
                return TuneFormat(fileExtension: kind) != nil ? 1 : PlaylistFile.reads(fileExtension: kind) ? 2 : 0
            },
            { [self] lines in
                // Each line is a name, a tab and a note. (The tab that counts is the last: a note has none.)
                let lines = lines.split(separator: "\n").map { Array($0.utf8) }
                add(lines.map { String(decoding: $0[..<($0.lastIndex(of: 9) ?? $0.count)], as: UTF8.self) },
                    notes: lines.map { line in line.lastIndex(of: 9).map { String(decoding: line[($0 + 1)...], as: UTF8.self) } ?? "" })
            },
            { [self] plays, text, songs, song, length in loaded(plays, text, songs, song, length) },
            { [self] seconds, numbers, voices in
                // (A move to another place in the song is no time at all, and neither is a long wait.)
                let fall = Self.lightFall * max(0, min(0.1, seconds - position))
                position = seconds
                let voices = max(0, min(numbers.count / 6, voices))
                let count = (numbers.count - voices * 6) / 2
                bars = numbers[..<count].map { $0 / 255 }
                caps = numbers[count ..< count * 2].map { $0 / 255 }
                let levels = numbers[(count * 2) ..< (count * 2 + voices)].map { $0 / 255 }
                lights = levels.count == lights.count ? levels.indices.map { max(levels[$0], lights[$0] - fall) } : levels
                // What each voice is playing, which is told by its light's colour. (Told to the page
                // only when it changes, which is seldom.)
                let kinds = numbers[(count * 2 + voices * 4) ..< (count * 2 + voices * 5)].map { $0 == 2 ? VoiceKind.speaker : $0 != 0 ? .sample : .chip }
                if kinds != sampled { sampled = kinds }
                let silenced = numbers[(count * 2 + voices * 5) ..< (count * 2 + voices * 6)].map { $0 != 0 }
                if silenced != muted { muted = silenced }
                // The picture is told all of it: how loud each voice is, its pitch, which comes in
                // half semitones, whether a note has just been struck, and the side it is heard
                // from, which comes as 1 for the left to 255 for the right.
                // (Of the voices that are heard: a muted voice has no part in it.)
                visualiser.hear(levels: levels.indices.map { silenced[$0] ? 0 : Float(levels[$0]) },
                                pitches: numbers[(count * 2 + voices) ..< (count * 2 + voices * 2)].enumerated().map { silenced[$0.offset] ? 0 : Float($0.element) / 2 },
                                struck: numbers[(count * 2 + voices * 2) ..< (count * 2 + voices * 3)].enumerated().map { !silenced[$0.offset] && $0.element != 0 },
                                sides: numbers[(count * 2 + voices * 3) ..< (count * 2 + voices * 4)].map { Float($0 - 128) / 127 })
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
            },
            { [self] seconds, width, height in
                let size = Visualiser.size(for: width, height)
                visualiser.resize(width: size.width, height: size.height)
                visualiser.paint(at: seconds)
                if let pixels = visualiser.pixels { try? sidayPaint(Int(bitPattern: pixels), visualiser.width, visualiser.height) }
            }
        )
        try? sidayPlaylists(
            { [self] names in
                finding.among = PlaylistFile.Finder(names.split(separator: "\n").map { String($0) })
            },
            { [self] name, text in
                // The file comes as a letter for each of its bytes.
                let finder = finding.among
                let letters = Array(name.utf8)
                guard let stop = letters.lastIndex(of: 0x2E),
                      let kind = PlaylistFile.Kind(fileExtension: String(decoding: letters[(stop + 1)...], as: UTF8.self)),
                      let list = PlaylistFile(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }, kind: kind) else { return "0 0" }
                var named = 0
                var lines: [String] = []
                // (What a list names that is no kind of tune played here is passed over, and not looked for.)
                for entry in list.entries where TuneFormat(fileExtension: entry.fileExtension) != nil {
                    if let place = finder.place(of: entry, besideList: name) {
                        lines.append("\(named)\t\(place)\t1\t\(entry.note)")
                    } else if let place = finder.place(of: entry) {
                        lines.append("\(named)\t\(place)\t0\t\(entry.note)")
                    }
                    named += 1
                }
                return (["\(named) \(named - lines.count)"] + lines).joined(separator: "\n")
            },
            { [self] missing, named, list in
                notice = Self.notice(missing: missing, of: named, in: list)
            }
        )
        tellOutput()
        tellSettings()
    }

    // MARK: The list

    /// What is said when playlists have been read and tunes they name were not there to be found;
    /// nothing, if they all were.
    private static func notice(missing: Int, of named: Int, in list: String) -> String? {
        guard missing > 0 else { return nil }
        let whose = list.isEmpty ? "The playlists name" : "\(list) names"
        let count = missing < named ? "\(grouped(named)) tunes, and \(grouped(missing)) of them \(missing == 1 ? "was" : "were") not found"
            : named == 1 ? "a tune that was not found" : "\(grouped(named)) tunes, and none of them were found"
        return "\(whose) \(count). A web page can only read the files it is given, so it cannot fetch these tunes itself."
    }

    /// The listener is to say where the tunes are that the playlists name and were not found.
    func chooseTunes() {
        try? sidayChooseTunes()
    }

    private func add(_ names: [String], notes: [String]) {
        guard !names.isEmpty else { return }
        notice = nil
        let first = files.count
        files.append(contentsOf: names)
        self.notes.append(contentsOf: notes)
        searchable.append(contentsOf: names.map { Array($0.lowercased().utf8) })
        order.append(contentsOf: first ..< files.count)
        find()
        if shuffled { order[max(1, orderPlace + 1)...].shuffle() }
        if current == nil || finished { play(order[first == 0 ? 0 : min(orderPlace + 1, order.count - 1)]) }
    }

    /// The file at a place in the list, or nothing if the list is not that long. (A row can be drawn
    /// once more, for the place it had, after a tune has been taken out and the list is shorter.)
    func file(at index: Int) -> String {
        files.indices.contains(index) ? files[index] : ""
    }

    /// Takes a tune out of the list. If it is the one playing, the next one plays; if there is no next
    /// one, nothing does.
    func remove(_ index: Int) {
        guard files.indices.contains(index) else { return }
        let wasCurrent = index == current
        let place = order.firstIndex(of: index) ?? 0
        files.remove(at: index)
        notes.remove(at: index)
        searchable.remove(at: index)
        // The order is of places in the list, and those after the one that has gone are each one less.
        order = order.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 }
        marked = marked.filter { $0.file != index }.map { Marked(file: $0.file > index ? $0.file - 1 : $0.file, why: $0.why) }
        try? sidayRemove(index)
        find()
        if let playing = current, playing > index { current = playing - 1 }
        if let described = tuneFile, described > index { tuneFile = described - 1 }
        guard wasCurrent else { return }
        current = nil
        tuneFile = nil
        if place < order.count {
            play(order[place])
        } else {
            tune = nil
            problem = nil
            finished = false
            paused = false
            position = 0
            rendered = 0
            lights = []
            rest()
            try? sidayStop()
        }
    }

    /// Empties the list. Nothing plays after that until tunes are added again.
    func removeAll() {
        notice = nil
        guard !files.isEmpty else { return }
        files = []
        notes = []
        searchable = []
        order = []
        marked = []
        failures = 0
        // (Which also finds nothing, and puts the list back at its top.)
        search = ""
        current = nil
        tuneFile = nil
        tune = nil
        problem = nil
        finished = false
        paused = false
        position = 0
        rendered = 0
        lights = []
        rest()
        try? sidayRemoveAll()
        try? sidayStop()
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
            lights = []
            visualiser.newTune()
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
                let fields = line(4 + index).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                let milliseconds = fields.first.flatMap { Int($0) }
                list.append(Tune.Song(title: fields.count > 2 ? String(fields[2]) : "", length: milliseconds.map { Double($0) / 1000 },
                                      empty: fields.count > 1 && fields[1] == "1"))
            }
            // A song whose file gives no length has it found when it is played. What was found for the
            // songs of this tune played before this one is kept.
            if current == tuneFile, let known = tune?.songs, known.count == list.count {
                for index in list.indices where list[index].length == nil { list[index].length = known[index].length }
            }
        }
        // After the songs: what the file asks for that is not played as it asks, each line of it
        // marked with an exclamation mark.
        let shortfalls = lines.dropFirst(4 + list.count).filter { $0.utf8.first == 0x21 }.map { String($0.dropFirst()) }
        tuneFile = current
        tune = Tune(format: line(0), title: line(1), author: line(2), detail: line(3), songs: list, song: song, length: length, shortfalls: shortfalls)
        // And its row in the list is marked from now on, or is not.
        if let current {
            let why = shortfalls.joined(separator: " ")
            if let place = marked.firstIndex(where: { $0.file == current }) {
                if shortfalls.isEmpty { marked.remove(at: place) } else if marked[place].why != why { marked[place].why = why }
            } else if !shortfalls.isEmpty {
                marked.append(Marked(file: current, why: why))
            }
        }
    }

    /// Why a tune in the list is marked as not played quite as its file asks; nil if it is not marked.
    func shortfalls(ofFile index: Int) -> String? {
        marked.first { $0.file == index }?.why
    }

    /// Writes out under the playing tune's details what is not played as its file asks, or puts it away again.
    func toggleShortfalls() {
        shortfallsShown.toggle()
    }

    /// The playing song had no length in its file and was given the usual time, or had one and fell
    /// silent for good before it; rendered to its end, it has turned out shorter. That is its length,
    /// here and in the list of songs.
    private func measured(_ length: Double) {
        guard let song = tune?.song else { return }
        tune?.length = length
        if tune?.songs.indices.contains(song) == true { tune?.songs[song].length = length }
    }

    /// A song has played to its end: the next of the tune's songs that are played in turn follows,
    /// if there is one, and the next tune if not.
    private func songEnded() {
        if let tune, let following = songsInTurn(of: tune).indices.first(where: { $0 > tune.song && songsInTurn(of: tune)[$0] }) {
            playSong(following)
        } else {
            next(automatic: true)
        }
    }

    /// Which of a tune's songs are played when one ends and the next is to follow: all of them, but
    /// for those the listener has asked to have passed over as too short; or none, if only a file's
    /// main song is to be played. The rule is the engine's own, which chooses the first by it.
    func songsInTurn(of tune: Tune) -> [Bool] {
        guard value(of: .songs) == 0 else { return tune.songs.map { _ in false } }
        return PlaybackPolicy.playedInTurn(tune.songs.map { $0.length }, empty: tune.songs.map { $0.empty },
                                           shortest: Setting.shortestSong.amount(of: value(of: .shortestSong)))
    }

    /// True if a song of a tune is one that is passed over when its songs are played in turn.
    func passesOver(_ song: Int, of tune: Tune) -> Bool {
        let played = songsInTurn(of: tune)
        return value(of: .songs) == 0 && played.indices.contains(song) && !played[song]
    }

    /// The next tune in the order: of those the search finds, while there is a search. When a tune
    /// ends of its own accord at the end of the list, playing stops there.
    func next(automatic: Bool = false) {
        if let place = following() {
            play(order[place])
        } else if automatic {
            finished = true
            rest()
        }
    }

    func previous() {
        let place = orderPlace
        if let before = order[..<max(0, place)].lastIndex(where: isListed) { play(order[before]) }
    }

    /// True for a tune that is in the list as it is shown: any tune, or one the search finds.
    private func isListed(_ file: Int) -> Bool {
        guard let found else { return true }
        // (They are in order, and may be many.)
        var low = 0, high = found.count
        while low < high {
            let middle = (low + high) / 2
            if found[middle] < file { low = middle + 1 } else { high = middle }
        }
        return low < found.count && found[low] == file
    }

    /// Where in the order the tune after the playing one is: the next that the list shows. While a
    /// search is on, the list is what the search finds, and playing goes through that and stops at
    /// its end; and from a tune that the search does not find, it goes to the first that it does.
    private func following() -> Int? {
        let place = orderPlace
        let from = found != nil && !(current.map(isListed) ?? false) ? 0 : place + 1
        return from < order.count ? order[from...].firstIndex(where: isListed) : nil
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
    /// paused, and will start from there. After the last tune of the list has finished, the song
    /// that finished it is still there to be moved about in, and is played again from that place.
    func seek(to place: Double) {
        guard let tune, tune.length > 0 else { return }
        position = max(0, min(1, place)) * tune.length
        rest()
        if finished {
            finished = false
            paused = false
            try? sidayPause(false)
        }
        try? sidaySeek(position)
    }

    /// Pauses or plays. After the last tune of the list has finished, it plays the song that finished
    /// it again, from its start.
    func togglePause() {
        if finished, tune != nil {
            seek(to: 0)
            return
        }
        guard tune != nil else { return }
        paused.toggle()
        if paused { rest() }
        try? sidayPause(paused)
    }

    /// Nothing is sounding: the analyser's bars drop, and the lights go out.
    private func rest() {
        bars = bars.map { _ in 0 }
        caps = caps.map { _ in 0 }
        lights = lights.map { _ in 0 }
        visualiser.rest()
    }

    /// Changes the kind of picture to listen by.
    func show(_ mode: Visualiser.Mode) {
        guard mode != picture else { return }
        picture = mode
        visualiser.mode = mode
        try? sidayPicture(mode.rawValue)
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

    // MARK: Settings

    func value(of setting: Setting) -> Double {
        settings.indices.contains(setting.rawValue) ? settings[setting.rawValue] : setting.standard
    }

    func set(_ setting: Setting, to value: Double) {
        let value = setting.settled(value)
        guard value != self.value(of: setting) else { return }
        settings[setting.rawValue] = value
        tellSettings()
    }

    var settingsAreStandard: Bool { settings == Setting.standards }

    /// Puts every setting back as it comes.
    func resetSettings() {
        guard !settingsAreStandard else { return }
        settings = Setting.standards
        settingsRound += 1
        tellSettings()
    }

    func toggleSettings() {
        settingsShown.toggle()
    }

    /// A setting as it is kept from one visit to the next: for one chosen from a list, the code of
    /// what is chosen, and for one on a scale, the place on it.
    private static func code(of setting: Setting, _ value: Double) -> String {
        switch setting.kind {
        case .choice(let choices): choices[Int(setting.settled(value))].code
        case .scale: "\(Int(setting.settled(value)))"
        }
    }

    /// The settings of the last visit: those that had been changed were kept, by name, as
    /// "name=code" with commas between. Anything not understood is as it comes.
    private static var rememberedSettings: [Double] {
        var settings = Setting.standards
        // (Stereo the other way round was once something to be heard through, and is kept as that
        // from a visit of those days.)
        if rememberedOutput == .acb { settings[Setting.stereoOrder.rawValue] = 1 }
        for kept in ((try? sidayRememberedSettings()) ?? "").split(separator: ",") {
            let parts = kept.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let setting = Setting.allCases.first(where: { $0.name == parts[0] }) else { continue }
            switch setting.kind {
            case .choice(let choices):
                if let place = choices.firstIndex(where: { $0.code == parts[1] }) { settings[setting.rawValue] = Double(place) }
            case .scale:
                if let place = Int(parts[1]) { settings[setting.rawValue] = setting.settled(Double(place)) }
            }
        }
        return settings
    }

    private func tellSettings() {
        let changed = Setting.allCases.filter { value(of: $0) != $0.standard }
        try? sidaySettings(settings.map { "\(Int($0))" }.joined(separator: ","),
                           changed.map { "\($0.name)=\(Self.code(of: $0, value(of: $0)))" }.joined(separator: ","))
    }

    /// True if a part has not been put away. Whether it is on the page is another matter: see `isShowing`.
    func shows(_ part: Part) -> Bool {
        !hidden.contains(part)
    }

    /// True if there is something for a part to show: a tune, for the analyser, the lights and the
    /// picture. (The moment between one tune and the next counts as a tune.) The list is always
    /// there to be shown: it is where tunes are added, and with none in it yet it says how.
    func has(_ part: Part) -> Bool {
        switch part {
        case .analyser, .lights, .picture: current != nil && problem == nil
        case .list: true
        }
    }

    /// True if a part is on the page: there is something for it to show, and it has not been put away.
    func isShowing(_ part: Part) -> Bool {
        has(part) && shows(part)
    }

    /// Puts a part of the page away, or brings it back. It is remembered from one visit to the next.
    func toggle(_ part: Part) {
        if let place = hidden.firstIndex(of: part) {
            hidden.remove(at: place)
        } else {
            hidden.append(part)
        }
        try? sidayHidden(hidden.map { $0.rawValue }.joined(separator: ","))
        // The list comes back where it was, or where it would have followed the tunes to since.
        if part == .list, shows(.list) { scrollList(to: listTop) }
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
        case "f", "F": if isShowing(.picture) { try? sidayFillScreen() }
        default: break
        }
    }
}
