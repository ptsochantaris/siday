// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The songs in a module.
///
/// A module is a list of patterns to play in order, and most are one song: the list is played from
/// its top, and somewhere a jump takes it back. But a list can hold more than is ever reached that
/// way. A game's music was often one module with a tune for every level, each ending in a jump back
/// to its own start, and the game began the module at the place it wanted. So the part of the list
/// that playing from the top never reaches is looked at too: playing is started at the first place
/// not yet played, and whatever is reached from there is the next song, until no place is left.
///
/// A song is over when it comes round to a row it has played, or runs into a row that a song before
/// it played: a pattern nothing leads to, left behind after the end of the list, is then a song of
/// its own length and not that pattern with the whole of the first song after it. For that the songs
/// share a table of which of them played each row first (`unplayed` for none yet), which the players
/// fill in as they go.
///
/// A song found that way is kept only if a note is played in it and it lasts a second or more:
/// patterns left empty, and ends of lists that only jump away, are not songs. Nor is a short piece
/// that only leads into a song already found, which is what a place in the list that a jump passes
/// over looks like: it is kept only if it is half a minute or more of music before it gets there.
enum ModuleSongs {
    /// In the table of who played a row first: nobody yet.
    static let unplayed: UInt8 = 255

    struct Song {
        /// Where in the list of patterns it starts.
        var start: Int
        /// Its number in the table of who played each row first.
        var number: UInt8
        /// How long it is before it comes round, in seconds; nil if it was not found to.
        var length: Double?
        /// True if there is nothing to it: no note, or less than a second. Only the song from the
        /// top of the list can be, since no other is kept if it is.
        var empty = false
    }

    /// What one silent pass from a place in the list found.
    struct Pass {
        /// Which places in the list were played.
        var played: [Bool]
        var length: Double?
        /// True if a note was played.
        var sounded: Bool
        /// True if it ended by going on into a row that a song before it played, and not by coming
        /// round to itself, stopping, or running off the end of the list.
        var ledIntoEarlierSong: Bool
    }

    /// No file means more songs than this; one that seems to is a list of odds and ends.
    static let most = 32
    private static let mostPasses = 64
    /// How long a piece that leads into an earlier song has to be, in seconds, to count as a song.
    private static let leadIn = 30.0

    /// - Parameters:
    ///   - places: how long the list of patterns is.
    ///   - isPattern: whether a place in the list is a pattern, and not a mark of some kind.
    ///   - pass: plays from a place in silence, as the song of a number, until that song is over,
    ///     and says what it found.
    /// - Returns: the songs, the first of them the one from the top of the list, whatever it is.
    ///   (That one is what the tracker itself would play, so it is kept even if it is nothing, and
    ///   `first(of:)` says which to play.)
    static func find(places: Int, isPattern: (Int) -> Bool, pass: (_ start: Int, _ number: UInt8) -> Pass) -> [Song] {
        var songs: [Song] = []
        var played = [Bool](repeating: false, count: max(1, places))
        var start = 0
        var passes = 0
        while true {
            let found = pass(start, UInt8(passes))
            passes += 1
            for i in 0 ..< min(places, found.played.count) where found.played[i] { played[i] = true }
            if start < places { played[start] = true }
            let longEnough = (found.length ?? leadIn) >= (found.ledIntoEarlierSong ? leadIn : 1)
            let something = found.sounded && (found.length ?? 1) >= 1
            if songs.isEmpty || (something && longEnough) {
                songs.append(Song(start: start, number: UInt8(passes - 1), length: found.length, empty: !something))
            }
            if songs.count >= most || passes >= mostPasses { break }
            guard let next = (0 ..< places).first(where: { !played[$0] && isPattern($0) }) else { break }
            start = next
        }
        return songs
    }

    /// Which song to play when none is asked for: the first that is not empty.
    static func first(of empties: [Bool]) -> Int {
        empties.firstIndex(of: false) ?? 0
    }
}
