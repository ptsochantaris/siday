// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import JavaScriptKit

// What the page's JavaScript (Web/siday.js) does for the Swift side: it owns the files the listener
// has chosen and the audio graph, because those are browser objects. Everything here is a function on
// the global object.

/// Hands over the Swift side's callbacks. Called once, before anything else.
/// - Parameters:
///   - kind: what a file of this name is: 1 for a tune that can be played, 2 for a playlist, 3 for
///     a tune's companion (see `Companions`), and 0 for anything else.
///   - added: files have been added to the list: a line for each, in the order they now have, of its
///     name, a tab, and what the playlist it came by says about it; and the place in the list they
///     were put at, before the file that was there, or -1 for after all of them.
///   - loaded: the tune asked for with `sidayPlay` has started, or could not be: whether it plays, its
///     details one to a line (format, title, author, detail; then for a tune of several songs a line
///     for each: its length in milliseconds if known, a tab, its name if it has one; then a line for
///     each thing the file asks for that is not played as it asks: an exclamation mark and a
///     sentence; then a line for each chip it is heard as made by: a hash and the chip's name, as
///     `SoundChip` has it) or the reason it does not, how many songs it has, which one is playing, and its
///     length in seconds. A song's length is a question mark while it is still being found.
///   - songs: it is known now how long each of the playing tune's songs is, which some were still
///     being played through to find: its details again, as `loaded` gave them.
///   - progress: where the playing song has got to, in seconds; then, in one list of numbers from 0
///     to 255, the spectrum analyser's bars (the height of each, low notes to high, and then the
///     height of each bar's cap) and what the tune's voices are doing, in six rows: a light for each
///     voice that has one (how bright it is), each one's pitch in half semitones (120 is middle C; 0
///     for none), 1 for each that a note has just been started on, the side each is heard from (1
///     for the left to 255 for the right), 1 for each that is playing a sample, and 1 for each that
///     the listener has muted; and how many voices there are.
///   - rendered: how much of the playing song is ready to be moved about in, in seconds from its start;
///     and the song's length, when the file did not give one and the song, now rendered to its end,
///     has turned out shorter than the time it was allowed (0 at any other time).
///   - ended: the song is over.
///   - held: the browser will not let the sound start until the listener has pressed something on the
///     page; the tune is loaded and waiting.
///   - pointed: the pointer is over the time bar (anything of class "seek"): how far along it, from 0
///     to 1, or a negative number when it has left; and whether the bar was pressed there.
///   - scrolled: the list of tunes (the element of class "rows") has been scrolled, or has changed
///     size: how far down it is, and how much of it can be seen, both in pixels.
///   - frame: the screen is about to be drawn, and the picture to listen by (the canvas of class
///     "picture") is on the page: the time in seconds, by a clock that only goes forward, and how
///     wide and tall the picture's space is, in points. What is to be shown is given to `sidayPaint`.
@JSFunction(from: .global)
func sidayListen(
    _ kind: @escaping (String) -> Int,
    _ added: @escaping (String, Int) -> Void,
    _ loaded: @escaping (Bool, String, Int, Int, Double) -> Void,
    _ songs: @escaping (String) -> Void,
    _ progress: @escaping (Double, [Double], Int) -> Void,
    _ rendered: @escaping (Double, Double) -> Void,
    _ ended: @escaping () -> Void,
    _ held: @escaping () -> Void,
    _ pointed: @escaping (Double, Bool) -> Void,
    _ scrolled: @escaping (Double, Double) -> Void,
    _ frame: @escaping (Double, Double, Double) -> Void
) throws(JSException)

/// Hands over the callbacks that find the files that come with others: the tunes a playlist names,
/// and the companions of a tune, the files it keeps its samples in or takes its instruments from. The
/// JavaScript side has the files, and the Swift side knows what a playlist says and what a tune
/// needs. Called once, with `sidayListen`.
/// - Parameters:
///   - given: the page has been given these files, which are tunes or their companions: their names,
///     one to a line. They are known from now on, after those given before, and are counted from 0
///     in that order, over all the times this is called; a name is given once.
///   - listed: a playlist's name, as the page has it, and its file, as text with a letter for each
///     of its bytes. The answer is in lines: first how many tunes it names and how many of those
///     were not among the files given, with a space between; then a line for each that was, in the
///     list's order: which of the list's tunes it is, counted from 0, a tab, its place among the files
///     given, a tab, 1 if it is a tune beside the list or below it and 0 if it is one from somewhere
///     else, a tab, and what the list says about it.
///   - read: a playlist's name and its file, as for `listed`, to be read for the next `gather`.
///   - gather: what the page was given, in the order of their names, the tunes in it to be added
///     to the list in the order they are played (see SidayPlayer's `TuneGathering`). A line for each
///     tune and playlist: 1 for a tune or 2 for a playlist, a tab, 1 if it was given itself and 0 if
///     it came in a folder, a tab, and the tune's place among the files given or the list's name, as
///     `read` had it. The answer is in lines: first how many of the tunes the lists name could not be
///     found and how many they name, with a space between; then a line for each tune to be added: its
///     place among the files given, a tab, and what the list it came by says about it; and then, for
///     each list that names tunes that were not found, an exclamation mark, a tab, which of the lists
///     that were read it is, counted from 0 (of those given themselves, if any were), a tab, and which
///     of the tunes it names were found, as in `listed`, with commas between.
///   - missed: playlists have been read, and this is how they came out: how many of the tunes they
///     name could not be found, how many they name, and the name of the list if it was a single one.
@JSFunction(from: .global)
func sidayFiles(
    _ given: @escaping (String) -> Void,
    _ listed: @escaping (String, String) -> String,
    _ read: @escaping (String, String) -> Void,
    _ gather: @escaping (String) -> String,
    _ missed: @escaping (Int, Int, String) -> Void
) throws(JSException)

/// Tells the browser what is playing, for its own Now Playing (a phone's lock screen, a computer's
/// media controls): the title, the author, the album's line (the format, and which song), the address
/// of the picture of its chip (empty for none), how long the song is and where it has got to, in
/// seconds, and whether it is playing. An empty title for nothing at all.
@JSFunction(from: .global)
func sidayNowPlaying(_ title: String, _ author: String, _ album: String, _ artwork: String, _ length: Double, _ position: Double, _ playing: Bool) throws(JSException)

/// Hands over what the browser's media keys, and the controls of its Now Playing, do: 0 to play, 1 to
/// pause, 2 for the next tune, 3 for the one before, and 4 to move to a place in the song, in seconds
/// (the second number). Called once.
@JSFunction(from: .global)
func sidayMediaKeys(_ pressed: @escaping (Int, Double) -> Void) throws(JSException)

/// Shows a picture in the canvas of class "picture": so many dots across and down, four bytes a dot
/// (red, green, blue and 255), in rows from the top, at an address in this module's own memory.
@JSFunction(from: .global)
func sidayPaint(_ address: Int, _ width: Int, _ height: Int) throws(JSException)

/// Fills the screen with the picture to listen by, or, if it is filling it, puts it back in the page.
@JSFunction(from: .global)
func sidayFillScreen() throws(JSException)

/// The kind of picture to listen by, by its name. It is remembered from one visit to the next.
@JSFunction(from: .global)
func sidayPicture(_ name: String) throws(JSException)

/// The kind of picture remembered from the last visit; empty if there was none.
@JSFunction(from: .global)
func sidayRememberedPicture() throws(JSException) -> String

/// Shows what FORMATS.md says of a format, over the page: the part whose heading begins with this
/// word. Nothing, if there is no such part or it cannot be fetched.
@JSFunction(from: .global)
func sidayAbout(_ chapter: String) throws(JSException)

/// Opens the browser's file chooser, for files or for a whole folder.
@JSFunction(from: .global)
func sidayChoose(_ folder: Bool) throws(JSException)

/// Opens the browser's folder chooser for the folder that holds the tunes of the playlists last
/// added, those of them that were not found, or the companion of a tune that was not. The folder is
/// looked in and is not added to the list: the tunes that were missing are, and `missed` is told how
/// the playlists stand now; its tunes and companions are given (see `sidayFiles`).
@JSFunction(from: .global)
func sidayChooseTunes() throws(JSException)

/// Loads a file from the list, by its place in it, and plays a song of it: -1 for the one the file
/// names. With it, the files it needs beside its own, by their places among the files given (see
/// `sidayFiles`), with a space between, and -1 for one that was not found; for a folder it needs,
/// "f" and the places of the files in it, with commas between ("f" alone if none were found), to be
/// brought to the engine as one, as `CompanionFolder.pack` has them.
@JSFunction(from: .global)
func sidayPlay(_ index: Int, _ subsong: Int, _ companions: String) throws(JSException)

@JSFunction(from: .global)
func sidayPause(_ paused: Bool) throws(JSException)

/// A file has been taken out of the list: the one at this place in it. Those after it move up one.
@JSFunction(from: .global)
func sidayRemove(_ index: Int) throws(JSException)

/// Every file has been taken out of the list.
@JSFunction(from: .global)
func sidayRemoveAll() throws(JSException)

/// A file has been moved within the list: the one at `from` now comes just before the one that was at
/// `to`, or after all of them for the list's length.
@JSFunction(from: .global)
func sidayMove(_ from: Int, _ to: Int) throws(JSException)

/// Nothing is to be played: the sound stops, and the song that was playing is let go.
@JSFunction(from: .global)
func sidayStop() throws(JSException)

/// Moves to another place in the song that is playing, in seconds from its start. If that much of
/// the song is not ready yet, the sound waits until it is.
@JSFunction(from: .global)
func sidaySeek(_ seconds: Double) throws(JSException)

/// How loud the player is, from 0 to 1: its own volume, apart from the computer's. It is remembered
/// from one visit to the next.
@JSFunction(from: .global)
func sidayVolume(_ volume: Double) throws(JSException)

/// The volume remembered from the last visit, from 0 to 1; 1 if there was none.
@JSFunction(from: .global)
func sidayRememberedVolume() throws(JSException) -> Double

/// How much of the list of tunes can be seen, in pixels; 0 if it is not on the page.
@JSFunction(from: .global)
func sidayListHeight() throws(JSException) -> Double

/// Scrolls the list of tunes so that this many pixels of it are above what can be seen. If the list
/// is only now being put on the page, it is scrolled as soon as it is there.
@JSFunction(from: .global)
func sidayScrollList(_ top: Double) throws(JSException)

/// What tunes are heard through: an output style, by its name and by its place in the order SidayPlayer
/// lists them. It is remembered from one visit to the next. If the playing song has to be rendered
/// again to be heard that way, it is, and goes on from where it had got to once that much is ready.
@JSFunction(from: .global)
func sidayOutput(_ name: String, _ place: Int) throws(JSException)

/// Which parts of the page have been put away, by their names with commas between. It is remembered
/// from one visit to the next.
@JSFunction(from: .global)
func sidayHidden(_ names: String) throws(JSException)

/// The parts of the page that were put away on the last visit, as `sidayHidden` was given them;
/// empty if none were. On a first visit, it is the parts that are away until they are asked for.
@JSFunction(from: .global)
func sidayRememberedHidden() throws(JSException) -> String

/// The listener's settings: a number for each of SidayPlayer's settings, in the order it lists them, with
/// commas between; and the same in the form they are to be remembered in from one visit to the next.
/// If the playing song has to be rendered again to be heard as they now are, it is, and goes on from
/// where it had got to once that much is ready.
@JSFunction(from: .global)
func sidaySettings(_ values: String, _ remembered: String) throws(JSException)

/// The settings remembered from the last visit, as `sidaySettings` was given them; empty if none were.
@JSFunction(from: .global)
func sidayRememberedSettings() throws(JSException) -> String

/// Hands over the callback that is told what siday keeps (see SidayPlayer's `KeptFiles`): the MT-32 ROMs
/// and song lengths the listener gave once, which the browser keeps from one visit to the next. A line
/// for each thing said of them, none if nothing is kept; told at once, with what was said last, and
/// again whenever it changes.
@JSFunction(from: .global)
func sidayListenKept(_ told: @escaping (String) -> Void) throws(JSException)

/// Forgets every file siday keeps.
@JSFunction(from: .global)
func sidayForgetKept() throws(JSException)

/// The name of the output style remembered from the last visit; empty if there was none.
@JSFunction(from: .global)
func sidayRememberedOutput() throws(JSException) -> String
