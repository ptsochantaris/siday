// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SidayKit

/// What is known about the tune that is playing.
struct Tune: Equatable {
    var format: String
    var title: String
    var author: String
    var detail: String
    /// Its songs, when it has more than one: what each is called and how long it is, where the file says.
    var songs: [Song]
    /// The song that is playing, counted from 0.
    var song: Int
    var length: Double
    /// What its file asks for that is not played as it asks, a sentence each. None, for a tune that is played whole.
    var shortfalls: [String] = []

    struct Song: Equatable {
        var title: String
        var length: Double?
        /// True if there is known to be nothing in it: it is passed over when songs are played in turn.
        var empty = false
        /// True while it is still being played through, unheard, to find how long it is (`SongInfo.pending`).
        var pending = false
    }

    /// True when the file names its songs, and not only numbers them.
    var namesSongs: Bool { songs.contains { !$0.title.isEmpty } }

    /// What is said of a tune that is not played quite as its file asks, before what it is.
    static let shortfallHeading = String(localized: "Not played quite as the file asks.")
}

/// A tune in the list.
struct ListedTune: Identifiable, Equatable {
    let id: Int
    var url: URL
    /// What the playlist it came by says about it; empty for none.
    var note: String
    /// Why it is not played quite as its file asks, once it has been played and found to be so.
    var shortfalls: String?
    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
}

/// A part of the player that the listener can put away, and bring back.
enum Part: String, CaseIterable, Identifiable {
    case analyser, lights, waves, picture

    var id: Self { self }

    /// True for a part that is put away until the listener first asks for it: the scopes, which are
    /// more than most want to see, and the picture.
    var startsHidden: Bool { self == .waves || self == .picture }

    var title: String {
        switch self {
        case .analyser: String(localized: "Spectrum Analyser")
        case .lights: String(localized: "Voice Lights")
        case .waves: String(localized: "Voice Scopes")
        case .picture: String(localized: "Picture")
        }
    }

    var symbol: String {
        switch self {
        case .analyser: "chart.bar.xaxis"
        case .lights: "circle.grid.2x1.fill"
        case .waves: "waveform"
        case .picture: "sparkles"
        }
    }
}

/// The app's state: the list of tunes, which one is playing, and what the controls do. It is the web
/// page's `Player` (Web/Sources/SidayWeb/Player.swift), with the app's files and sound in place of
/// the browser's.
@Observable
final class PlayerModel {
    // MARK: The list

    private(set) var files: [ListedTune] = []
    private var nextID = 0
    /// The files and folders the app may read.
    @ObservationIgnored private let library = Library()
    /// What there is to say: that tunes a playlist names were not found, or that a tune could not be
    /// played for want of a file it needs beside its own. With the folder they are in, they are found.
    private(set) var listNotice: String?
    private(set) var companionNotice: String?
    var notice: String? {
        let both = [listNotice, companionNotice].compactMap { $0 }
        return both.isEmpty ? nil : both.joined(separator: " ")
    }
    /// The tune that could not be played for want of a companion, while it is still wanted.
    private var wanting: Int?
    /// The playlist whose tunes were not all found, to be read again when their folder is given.
    @ObservationIgnored private var unfoundList: URL?

    var search = ""
    /// The tunes of the list the search finds, in order.
    var listed: [ListedTune] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return files }
        return files.filter { $0.url.path.localizedStandardContains(needle) }
    }

    // MARK: Playing

    /// The place in `files` of the tune that is playing or was asked for.
    private(set) var current: Int?
    private(set) var tune: Tune?
    /// The place in `files` of the file `tune` describes.
    private var tuneFile: Int?
    private(set) var problem: String?
    private(set) var paused = false
    /// True once the last tune of the list has finished.
    private(set) var finished = false
    /// How much of the playing song is ready to be moved about in, in seconds from its start.
    private(set) var rendered = 0.0
    /// True while the song is being made again, for a voice left out or brought back.
    private(set) var remaking = false
    /// How many voices of the tune have a light.
    private(set) var voiceCount = 0
    /// What is slid over the player for a moment: a format's story, or what is not played as the
    /// playing tune's file asks.
    var slideOver: SlideOver?
    enum SlideOver: Hashable {
        case story(String)
        case shortfalls
    }
    /// True while the picture fills the screen.
    var pictureFillsScreen = false
    /// Which of the playlist and the player is showing, where there is room for only one (an iPhone):
    /// the player, but the playlist while there is nothing in it.
    var place = Place.player
    enum Place {
        case playlist, player
    }
    /// The settings, while they are showing over everything (not on a Mac, which has a window for them).
    var showingSettings = false
    /// The name of a folder the listener gave that had nothing in it to play, while they are told so.
    var emptyFolder: String?
    /// True while the listener is being asked whether every tune is to be taken out of the list.
    var askingToRemoveAll = false
    /// What the listener is choosing files for, while they are.
    var choosing: Choosing?
    enum Choosing: Identifiable {
        /// Tunes, playlists or a list of song lengths to add; a folder of them; or the folder that
        /// something wanted is in.
        case files, folder, wanted
        var id: Self { self }
    }
    private(set) var shuffled = false
    /// The order tunes are played in: places in `files`.
    private var order: [Int] = []
    /// Files in a row that would not play.
    private var failures = 0
    /// The count of requests to play, and of runs of sound: the engine's news of an older one is no news.
    private var asked = 0
    private var runs = 0

    /// The picture to listen by, painted from what the voices are doing.
    @ObservationIgnored let visualiser: Visualiser
    var picture: Visualiser.Mode {
        didSet {
            visualiser.mode = picture
            UserDefaults.standard.set(picture.rawValue, forKey: "picture")
        }
    }

    /// What tunes are heard through. Stereo is listed once: which way round is a setting.
    static let outputs = OutputStyle.allCases.filter { $0 != .acb }
    var output: OutputStyle {
        didSet {
            UserDefaults.standard.set(output.rawValue, forKey: "output")
            engine.send(.output(output))
        }
    }

    /// The player's own volume, 0 to 1.
    var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: "volume")
            engine.setVolume(volume)
        }
    }

    /// The parts that have been put away.
    private(set) var hidden: Set<Part>

    /// The listener's settings (see `Setting`): a value for each, in the order of its cases.
    private(set) var settings: [Double]

    @ObservationIgnored private(set) var engine: PlaybackEngine!
    /// Levels found for songs, by their keys (see `SongLevel.key`).
    @ObservationIgnored private var levels: [String: String]

    init() {
        let defaults = UserDefaults.standard
        let picture = defaults.string(forKey: "picture").flatMap { Visualiser.Mode(rawValue: $0) } ?? .lava
        self.picture = picture
        visualiser = Visualiser(mode: picture)
        output = defaults.string(forKey: "output").flatMap { OutputStyle(rawValue: $0) }.flatMap { Self.outputs.contains($0) ? $0 : nil } ?? .abc
        // (Kept as a number; given on the command line, as text: either is read.)
        volume = defaults.object(forKey: "volume") != nil ? max(0, min(1, defaults.double(forKey: "volume"))) : 1
        let words = Set(defaults.stringArray(forKey: "hidden") ?? [])
        hidden = Set(Part.allCases.filter { $0.startsHidden ? !words.contains("+" + $0.rawValue) : words.contains($0.rawValue) })
        settings = Self.rememberedSettings
        levels = defaults.dictionary(forKey: "levels") as? [String: String] ?? [:]
        engine = PlaybackEngine { [weak self] news in self?.hear(news) }
        engine.send(.output(output))
        engine.send(.settings(settings))
        engine.setVolume(volume)
        let silent = ProcessInfo.processInfo.arguments.contains("-SidaySilent") || UserDefaults.standard.bool(forKey: "SidaySilent")
        engine.startOutput(silent: silent)
        #if DEBUG
        // (For trying the app out: `-SidayFresh` starts with no list.)
        if ProcessInfo.processInfo.arguments.contains("-SidayFresh") {
            try? FileManager.default.removeItem(at: Library.store)
        }
        #endif
        restoreList()
        if files.isEmpty { place = .playlist }
        #if DEBUG
        // (And `-SidayShow settings`, or `playlist`, starts with that showing.)
        switch UserDefaults.standard.string(forKey: "SidayShow") {
        case "settings": showingSettings = true
        case "playlist": place = .playlist
        default: break
        }
        #endif
    }

    // MARK: Adding

    /// Adds what the listener gave: files, folders, playlists, and HVSC's list of song lengths.
    func add(_ urls: [URL]) {
        for url in urls { library.add(url) }
        Task.detached { [urls] in
            let found = Scanner.scan(urls)
            await MainActor.run { self.added(found) }
        }
    }

    private func added(_ found: Scanner.Found) {
        if let lengths = found.songLengths, let data = try? Coordinated.data(lengths) {
            engine.send(.songLengths([UInt8](data)))
            library.add(lengths)
        }
        listNotice = Self.notice(missing: found.missing, of: found.named, in: found.list)
        if let empty = found.emptyFolders.first { emptyFolder = empty }
        guard !found.tunes.isEmpty else {
            saveList()
            return
        }
        let first = files.count
        for url in found.tunes {
            files.append(ListedTune(id: nextID, url: url, note: found.notes[url] ?? ""))
            nextID += 1
        }
        order.append(contentsOf: first ..< files.count)
        if shuffled { order[max(1, orderPlace + 1)...].shuffle() }
        if current == nil || finished { play(order[first == 0 ? 0 : min(orderPlace + 1, order.count - 1)]) }
        saveList()
    }

    /// The listener has given the folder that tunes, or a tune's companion, were wanted from.
    func gaveFolder(_ url: URL) {
        library.add(url)
        TuneFiles.forget(url)
        if let wanting, files.indices.contains(wanting) {
            TuneFiles.forget(files[wanting].url.deletingLastPathComponent())
            failures = 0
            play(wanting)
        }
        if let list = unfoundList {
            unfoundList = nil
            add([list])
        }
        saveList()
    }

    private static func notice(missing: Int, of named: Int, in list: String) -> String? {
        guard missing > 0 else { return nil }
        let whose = list.isEmpty ? String(localized: "The playlists name") : String(localized: "\(list) names")
        let count = missing < named ? String(localized: "\(named) tunes, and \(missing) of them were not found")
            : named == 1 ? String(localized: "a tune that was not found") : String(localized: "\(named) tunes, and none of them were found")
        return "\(whose) \(count). " + String(localized: "Choose the folder they are in, and the app may read them.")
    }

    private static func notice(_ name: String, wants companion: Companion) -> String {
        String(localized: "\(name) keeps \(companion.what) \(Companions.whereKept(companion)). Choose the folder it is in, and the app may read it.")
    }

    // MARK: Taking out

    func remove(_ ids: Set<Int>) {
        for index in files.indices.reversed() where ids.contains(files[index].id) { remove(at: index) }
        saveList()
    }

    private func remove(at index: Int) {
        let wasCurrent = index == current
        let place = order.firstIndex(of: index) ?? 0
        files.remove(at: index)
        order = order.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 }
        if let playing = current, playing > index { current = playing - 1 }
        if let waiting = wanting {
            wanting = waiting > index ? waiting - 1 : waiting < index ? waiting : nil
            if wanting == nil { companionNotice = nil }
        }
        if let described = tuneFile, described > index { tuneFile = described - 1 }
        guard wasCurrent else { return }
        current = nil
        tuneFile = nil
        if place < order.count {
            play(order[place])
        } else {
            stopped()
        }
        if files.isEmpty { self.place = .playlist }
    }

    func removeAll() {
        listNotice = nil
        companionNotice = nil
        wanting = nil
        files = []
        order = []
        failures = 0
        search = ""
        current = nil
        tuneFile = nil
        stopped()
        place = .playlist
        saveList()
    }

    private func stopped() {
        tune = nil
        problem = nil
        finished = false
        paused = false
        rendered = 0
        engine.send(.stop)
        engine.pause(true)
        visualiser.rest()
    }

    // MARK: Playing

    private var orderPlace: Int {
        guard let current else { return -1 }
        return order.firstIndex(of: current) ?? -1
    }

    func play(id: Int) {
        if let index = files.firstIndex(where: { $0.id == id }) { play(index) }
    }

    /// - Parameter startPaused: the tune is made ready, and nothing is heard until play is pressed.
    func play(_ index: Int, song: Int = -1, paused startPaused: Bool = false) {
        guard files.indices.contains(index) else { return }
        endedUnfollowed = false
        // Another song of the tune that is showing: its details stay up, with the new song marked.
        if index == tuneFile, let tune, tune.songs.indices.contains(song) {
            self.tune?.song = song
        } else {
            tune = nil
            tuneFile = nil
            visualiser.newTune()
        }
        current = index
        problem = nil
        finished = false
        paused = startPaused
        rendered = 0
        engine.pause(startPaused)
        let url = files[index].url
        let read: TuneFiles.Read
        do {
            read = try TuneFiles.read(url)
        } catch {
            loaded(plays: false, problem: String(localized: "The file could not be read."), info: nil, songs: [], song: 0, length: 0)
            return
        }
        if let missing = read.missing {
            companionNotice = Self.notice(url.lastPathComponent, wants: missing)
            wanting = index
        } else if wanting == index {
            companionNotice = nil
            wanting = nil
        }
        asked += 1
        runs += 1
        engine.send(.load(tune: asked, serial: runs, name: url.lastPathComponent, bytes: read.bytes, companions: read.companions, subsong: song))
    }

    private func hear(_ news: PlaybackEngine.News) {
        switch news {
        case let .ended(tune, serial):
            if tune == asked, serial == runs { songEnded() }
        case let .voices(count):
            if count != voiceCount { voiceCount = count }
        case .interrupted:
            if !paused, !finished, tune != nil {
                paused = true
                engine.pause(true)
                visualiser.rest()
                nowPlayingChanged()
            }
        case let .keeper(event):
            switch event {
            case let .loaded(tune, plays, problem, info, songs, song, length, _, levelKey):
                guard tune == asked else { return }
                loaded(plays: plays, problem: problem, info: info, songs: songs, song: song, length: length)
                if plays { engine.send(.keptLevel(key: levelKey, text: levels[levelKey])) }
            case let .rendered(tune, seconds, length):
                guard tune == asked else { return }
                rendered = seconds
                if length > 0 { measured(length) }
            case let .level(_, key, text):
                levels[key] = text
                UserDefaults.standard.set(levels, forKey: "levels")
            case let .remaking(tune, busy):
                if tune == asked { remaking = busy }
            case let .songs(tune, songs):
                guard tune == asked else { return }
                learned(songs)
            case .muted, .measure:
                break
            }
        }
    }

    private func loaded(plays: Bool, problem: String?, info: TuneInfo?, songs: [SongInfo], song: Int, length: Double) {
        guard plays, let info else {
            tune = nil
            tuneFile = nil
            self.problem = problem ?? String(localized: "The file could not be played.")
            failures += 1
            if failures < files.count { next(automatic: true) }
            return
        }
        failures = 0
        var list = songs.map { Tune.Song(title: $0.title, length: $0.length, empty: $0.empty, pending: $0.pending) }
        // A song whose file gives no length has it found when it is played: what was found is kept.
        if current == tuneFile, let known = tune?.songs, known.count == list.count {
            for index in list.indices where list[index].length == nil { list[index].length = known[index].length }
            // (And one played through to find its length since, which this load had still to.)
            for index in list.indices where list[index].pending && !known[index].pending { list[index] = known[index] }
        }
        tuneFile = current
        tune = Tune(format: info.format, title: info.title, author: info.author, detail: info.detail, songs: list, song: song, length: length, shortfalls: info.shortfalls)
        if let current, files.indices.contains(current) {
            let why = info.shortfalls.isEmpty ? nil : info.shortfalls.joined(separator: " ")
            if files[current].shortfalls != why { files[current].shortfalls = why }
        }
        nowPlayingChanged()
    }

    /// The song turned out shorter than it was given: that is its length, here and in the list of songs.
    private func measured(_ length: Double) {
        guard let song = tune?.song else { return }
        tune?.length = length
        if tune?.songs.indices.contains(song) == true { tune?.songs[song].length = length }
        nowPlayingChanged()
    }

    /// It is known now how long each of the tune's songs is, which some were still being played
    /// through to find. A song that ended while they were goes on to the one that follows it now.
    private func learned(_ songs: [SongInfo]) {
        guard var tune, tune.songs.count == songs.count else { return }
        for (index, song) in songs.enumerated() where tune.songs[index].pending {
            tune.songs[index].length = song.length
            tune.songs[index].empty = song.empty
            tune.songs[index].pending = song.pending
        }
        self.tune = tune
        if endedUnfollowed {
            endedUnfollowed = false
            songEnded()
        }
    }

    /// True when a song ended while some of the tune's songs were still being played through: which
    /// song follows it waits until it is known which of them are passed over.
    private var endedUnfollowed = false

    /// A song has played to its end: the next of the tune's songs that are played in turn follows,
    /// if there is one, and the next tune if not.
    private func songEnded() {
        if let tune, tune.songs.contains(where: \.pending) {
            endedUnfollowed = true
            return
        }
        if let tune, let following = songsInTurn(of: tune).indices.first(where: { $0 > tune.song && songsInTurn(of: tune)[$0] }) {
            playSong(following)
        } else {
            next(automatic: true)
        }
    }

    /// Which of a tune's songs are played when one ends and the next is to follow.
    func songsInTurn(of tune: Tune) -> [Bool] {
        guard value(of: .songs) == 0 else { return tune.songs.map { _ in false } }
        return PlaybackPolicy.playedInTurn(tune.songs.map(\.length), empty: tune.songs.map(\.empty),
                                           shortest: Setting.shortestSong.amount(of: value(of: .shortestSong)))
    }

    /// True if a song of a tune is passed over when its songs are played in turn.
    func passesOver(_ song: Int, of tune: Tune) -> Bool {
        let played = songsInTurn(of: tune)
        return value(of: .songs) == 0 && played.indices.contains(song) && !played[song]
    }

    /// True for a tune in the list as it is shown: any, or one the search finds.
    private func isListed(_ index: Int) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || files[index].url.path.localizedStandardContains(needle)
    }

    var hasNext: Bool { following() != nil }
    var hasPrevious: Bool { order[..<max(0, orderPlace)].contains(where: isListed) }

    /// The next tune in the order, of those the list shows. When a tune ends of its own accord at the
    /// end of the list, playing stops there.
    func next(automatic: Bool = false) {
        if let place = following() {
            play(order[place])
        } else if automatic {
            finished = true
            engine.pause(true)
            visualiser.rest()
            nowPlayingChanged()
        }
    }

    func previous() {
        if let before = order[..<max(0, orderPlace)].lastIndex(where: isListed) { play(order[before]) }
    }

    private func following() -> Int? {
        let place = orderPlace
        let from = !search.isEmpty && !(current.map(isListed) ?? false) ? 0 : place + 1
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

    /// Where the song is, as it is heard; or, after a move to another place in it and until that is
    /// heard (while paused, or while the song is still being worked out as far as there), the place
    /// moved to.
    var position: Double {
        let heard = engine.heard
        if heard.serial == runs { return heard.position }
        if let moved, moved.serial == runs { return moved.place }
        return 0
    }

    /// The last move to another place in a song: the run of sound it began, and the place.
    @ObservationIgnored private var moved: (serial: Int, place: Double)?

    @ObservationIgnored private let display = Display()

    /// What the player shows for one frame of the screen, at a time in seconds by any clock that only
    /// goes forward.
    func frame(at time: Double) -> Frame {
        let heard = engine.heard
        var frame = display.frame(heard, serial: runs, at: time, visualiser: visualiser)
        // (Until a move to another place is heard, the place moved to: see `position`.)
        if heard.serial != runs, let moved, moved.serial == runs { frame.position = moved.place }
        return frame
    }

    /// Moves to a place in the playing song, in seconds. A paused player stays paused.
    func seek(to seconds: Double) {
        guard let tune, tune.length > 0 else { return }
        let place = max(0, min(tune.length, seconds))
        visualiser.rest()
        if finished {
            finished = false
            paused = false
            engine.pause(false)
        }
        runs += 1
        moved = (runs, place)
        engine.send(.seek(position: place, serial: runs))
        nowPlayingChanged(at: place)
    }

    /// Moves through the song by so many seconds, forward or back.
    func skip(_ seconds: Double) {
        seek(to: position + seconds)
    }

    /// The player's own volume, a step up or down.
    func nudgeVolume(_ step: Double) {
        volume = max(0, min(1, volume + step))
    }

    func togglePause() {
        if finished, tune != nil {
            seek(to: 0)
            return
        }
        guard tune != nil else { return }
        paused.toggle()
        engine.pause(paused)
        if paused { visualiser.rest() }
        nowPlayingChanged()
    }

    func setPaused(_ paused: Bool) {
        if paused != self.paused { togglePause() }
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

    /// A press on a voice's light: mutes it or brings it back, or with `solo`, has it heard alone.
    func press(light: Int, solo: Bool) {
        engine.send(.mute(light: light, solo: solo))
    }

    /// The part of FORMATS.md that tells of the playing tune's format, by the word its heading begins with.
    var chapter: String? {
        guard let tuneFile, files.indices.contains(tuneFile) else { return nil }
        let named = TuneFormat(fileExtension: files[tuneFile].url.pathExtension)
        if named == .psm, tune?.format == "MASI" { return TuneFormat.masi.chapter }
        if named == .sid, tune?.format == "SID1" { return TuneFormat.sid1.chapter }
        return named?.chapter
    }

    var fileName: String {
        current.flatMap { files.indices.contains($0) ? files[$0].name : nil } ?? ""
    }

    var note: String? {
        guard let tuneFile, files.indices.contains(tuneFile), !files[tuneFile].note.isEmpty else { return nil }
        return files[tuneFile].note
    }

    // MARK: Parts

    func shows(_ part: Part) -> Bool { !hidden.contains(part) }

    /// True if there is something for a part to show: a tune.
    var hasTune: Bool { current != nil && problem == nil }

    func toggle(_ part: Part) {
        if hidden.contains(part) { hidden.remove(part) } else { hidden.insert(part) }
        let words = Part.allCases.compactMap { part -> String? in
            part.startsHidden ? (hidden.contains(part) ? nil : "+" + part.rawValue) : (hidden.contains(part) ? part.rawValue : nil)
        }
        UserDefaults.standard.set(words, forKey: "hidden")
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

    func resetSettings() {
        guard !settingsAreStandard else { return }
        settings = Setting.standards
        tellSettings()
    }

    /// A setting as it is kept: for one chosen from a list, the code of what is chosen; for one on a
    /// scale, the place on it. Only those that have been changed are kept.
    private func tellSettings() {
        engine.send(.settings(settings))
        var kept: [String: String] = [:]
        for setting in Setting.allCases where value(of: setting) != setting.standard {
            switch setting.kind {
            case .choice(let choices): kept[setting.name] = choices[Int(setting.settled(value(of: setting)))].code
            case .scale: kept[setting.name] = "\(Int(setting.settled(value(of: setting))))"
            }
        }
        UserDefaults.standard.set(kept, forKey: "settings")
    }

    private static var rememberedSettings: [Double] {
        var settings = Setting.standards
        let kept = UserDefaults.standard.dictionary(forKey: "settings") as? [String: String] ?? [:]
        for (name, code) in kept {
            guard let setting = Setting.allCases.first(where: { $0.name == name }) else { continue }
            switch setting.kind {
            case .choice(let choices):
                if let place = choices.firstIndex(where: { $0.code == code }) { settings[setting.rawValue] = Double(place) }
            case .scale:
                if let place = Int(code) { settings[setting.rawValue] = setting.settled(Double(place)) }
            }
        }
        return settings
    }

    // MARK: Kept between visits

    /// The list is kept as the bookmarks of the files and folders it came from, and each tune by its
    /// place under one of them.
    private func saveList() {
        var used: [Int: Int] = [:]
        var roots: [Data] = []
        var tunes: [[String: Any]] = []
        for file in files {
            guard let root = library.root(of: file.url) else { continue }
            let place: Int
            if let known = used[root] {
                place = known
            } else {
                place = roots.count
                used[root] = place
                roots.append(library.roots[root].bookmark)
            }
            let rootPath = library.roots[root].url.path
            let path = Library.plain(file.url).path
            let below = path == rootPath ? "" : String(path.dropFirst(rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1))
            tunes.append(["root": place, "path": below, "note": file.note])
        }
        // (And the folders given for companions, which no tune came from.)
        for root in library.roots.indices where used[root] == nil {
            used[root] = roots.count
            roots.append(library.roots[root].bookmark)
        }
        let list: [String: Any] = ["roots": roots, "tunes": tunes]
        if let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) {
            try? data.write(to: Library.store, options: .atomic)
        }
    }

    private func restoreList() {
        guard let data = try? Data(contentsOf: Library.store),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let roots = list["roots"] as? [Data], let tunes = list["tunes"] as? [[String: Any]] else { return }
        let places = roots.map { library.restore($0) }
        for tune in tunes {
            guard let root = tune["root"] as? Int, roots.indices.contains(root), let place = places[root], let path = tune["path"] as? String else { continue }
            let base = library.roots[place].url
            let url = path.isEmpty ? base : base.appendingPathComponent(path)
            files.append(ListedTune(id: nextID, url: url, note: tune["note"] as? String ?? ""))
            nextID += 1
        }
        order = Array(files.indices)
        // A visit begins with the first tune ready, and paused: nothing is heard until it is asked for.
        if !files.isEmpty { play(0, paused: true) }
    }

    // MARK: Now playing

    /// Called whenever what the system shows of the tune that is playing changes.
    var onNowPlayingChange: ((Double?) -> Void)?

    private func nowPlayingChanged(at position: Double? = nil) {
        onNowPlayingChange?(position)
    }
}
