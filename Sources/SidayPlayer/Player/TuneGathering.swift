// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

// How the tunes in what a listener gives a player are put in the order they are played, for every
// front end: the command-line player and the app, which look on disk, and the web page, which has
// only the names of the files it was given. The rule is the same for all three. A playlist that is
// given is played as it is written: its tunes, in its order. A folder is played as its tunes in the
// order of their names, and a playlist in it is the order of the tunes beside it and below it: those
// it names are played where the list is, as it has them. The tunes a list names that are somewhere
// else come after the folder's, unless they are among them. (A collection kept as one folder of
// tunes and many of lists is then played once through, and not once for every list; and a folder of
// nothing but lists is played too.)
//
// What a front end has to say is how it knows its files (`Item`: a path, a place in a list), how it
// tells one from another (`Key`), and how it finds the tunes a list names among them.

public enum TuneGathering {
    /// What a file is to a player, by its name.
    public enum Kind: Sendable, Equatable {
        case tune
        case playlist
        /// A file a tune needs beside its own (see `Companions`), which is no tune of itself.
        case companion
        /// HVSC's list of song lengths, `Songlengths.md5`.
        case songLengths
        case other
    }

    /// What a file is, by its name or its path. (A tune is known by what follows the last full stop
    /// of its name, whatever is before it: there is a tune called `...pt3`. No ending of a companion
    /// is a tune's.)
    public static func kind(ofFileNamed name: String) -> Kind {
        let leaf = Companions.fileName(name)
        if leaf.lowercased() == "songlengths.md5" { return .songLengths }
        // (A companion known by the whole of its name may end as a tune does: Ultima VII's `sysex.mid`.)
        if Companions.names.contains(leaf.lowercased()) { return .companion }
        let letters = Array(leaf.utf8)
        if let stop = letters.lastIndex(of: 0x2E) {
            let ending = String(decoding: letters[(stop + 1)...], as: UTF8.self)
            if TuneFormat(fileExtension: ending) != nil { return .tune }
            if PlaylistFile.reads(fileExtension: ending) { return .playlist }
        }
        return Companions.are(fileName: leaf) ? .companion : .other
    }

    /// Where a tune a playlist names is, as the front end finds it.
    public enum Placement<Item> {
        /// Beside the list, or below it.
        case here(Item)
        /// Somewhere else, which is looked for afterwards (see `folder`).
        case elsewhere
        /// Not there.
        case nowhere
    }

    /// The tunes gathered, in the order they are played, each with what the list it came by says
    /// of it; and of the tunes lists named, how many, and those that were not found.
    public struct Gathered<Item> {
        public var tunes: [(item: Item, note: String)] = []
        public var named = 0
        public var unfound: [PlaylistFile.Entry] = []
        /// For each list, in the order they were given: how many tunes it names (of a kind that is
        /// played: see `counts`), and those that were found, by their places among them.
        public var lists: [(named: Int, found: [Int])] = []

        public var missing: Int { unfound.count }
    }

    /// True for an entry of a list that is a kind of tune played here: the rest are passed over, and
    /// not looked for or counted.
    public static func counts(_ entry: PlaylistFile.Entry) -> Bool {
        TuneFormat(fileExtension: entry.fileExtension) != nil
    }

    /// A playlist that was given: its tunes, in its order, as `find` finds them. (All of them: one it
    /// names twice is played twice.)
    public static func list<Item>(_ entries: [PlaylistFile.Entry], find: (PlaylistFile.Entry) -> Item?) -> Gathered<Item> {
        var gathered = Gathered<Item>()
        var found: [Int] = []
        for entry in entries where counts(entry) {
            if let item = find(entry) {
                gathered.tunes.append((item, entry.note))
                found.append(gathered.named)
            } else {
                gathered.unfound.append(entry)
            }
            gathered.named += 1
        }
        gathered.lists = [(gathered.named, found)]
        return gathered
    }

    /// A folder that was given, or what was given together as one: its tunes and playlists.
    /// - Parameters:
    ///   - files: its tunes and playlists, in the order of their names as the front end has them (as
    ///     people count, so that a "2" comes before a "10", and with no difference made between
    ///     capitals and small letters).
    ///   - isList: true for a playlist, and false for a tune.
    ///   - entries: what a playlist names; nothing, for one that cannot be read.
    ///   - place: where a tune a list names is: beside the list or below it, or somewhere else.
    ///   - elsewhere: where a tune of somewhere else is, if it is anywhere.
    ///   - presumed: the key a tune of somewhere else would have, if that can be told without looking
    ///     for it: one that is held already is not looked for.
    ///   - key: what tunes are told apart by. One of a key that is held is not gathered again.
    ///   - held: the keys of the tunes gathered so far, here and from what was given before.
    public static func folder<Item, Key: Hashable>(
        _ files: [Item], isList: (Item) -> Bool, entries: (Item) -> [PlaylistFile.Entry],
        place: (PlaylistFile.Entry, Item) -> Placement<Item>, elsewhere: (PlaylistFile.Entry, Item) -> Item?,
        presumed: (PlaylistFile.Entry, Item) -> Key? = { _, _ in nil }, key: (Item) -> Key, held: inout Set<Key>
    ) -> Gathered<Item> {
        var gathered = Gathered<Item>()
        // What each list says of the tunes in its own folder and below, and what tunes it names that
        // are somewhere else.
        var below: [Int: [(item: Item, note: String)]] = [:]
        var ordered = Set<Key>()
        var away: [(entry: PlaylistFile.Entry, list: Item, which: Int, place: Int)] = []
        for (position, file) in files.enumerated() where isList(file) {
            let which = gathered.lists.count
            gathered.lists.append((0, []))
            var counted = 0
            for entry in entries(file) where counts(entry) {
                gathered.named += 1
                switch place(entry, file) {
                case .here(let item):
                    below[position, default: []].append((item, entry.note))
                    ordered.insert(key(item))
                    gathered.lists[which].found.append(counted)
                case .elsewhere:
                    away.append((entry, file, which, counted))
                case .nowhere:
                    gathered.unfound.append(entry)
                }
                counted += 1
            }
            gathered.lists[which].named = counted
        }
        func take(_ item: Item, _ note: String) {
            if held.insert(key(item)).inserted { gathered.tunes.append((item, note)) }
        }
        // The folder in the order of its names, with each list's tunes where the list is.
        for (position, file) in files.enumerated() {
            if isList(file) {
                for (item, note) in below[position] ?? [] { take(item, note) }
            } else if !ordered.contains(key(file)) {
                take(file, "")
            }
        }
        // Then those of somewhere else. (Most are the folder's own, and are known for that without a look.)
        for (entry, list, which, place) in away {
            if let presumed = presumed(entry, list), held.contains(presumed) {
                gathered.lists[which].found.append(place)
            } else if let item = elsewhere(entry, list) {
                take(item, entry.note)
                gathered.lists[which].found.append(place)
            } else {
                gathered.unfound.append(entry)
            }
        }
        for which in gathered.lists.indices { gathered.lists[which].found.sort() }
        return gathered
    }
}
