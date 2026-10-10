// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import JavaScriptKit

// What the page's JavaScript (Web/siday.js) does for the Swift side: it owns the files the listener
// has chosen and the audio graph, because those are browser objects. Everything here is a function on
// the global object.

/// Hands over the Swift side's callbacks. Called once, before anything else.
/// - Parameters:
///   - accepts: whether a file of this name is a tune that can be played.
///   - added: files have been added to the list: their names, one to a line, in the order they now have
///     after those already there.
///   - loaded: the tune asked for with `sidayPlay` has started, or could not be: whether it plays, its
///     details one to a line (format, title, author, detail, then for a tune of several songs a line
///     for each: its length in milliseconds if known, a tab, its name if it has one) or the reason it
///     does not, how many songs it has, which one is playing, and its length in seconds.
///   - progress: where the playing song has got to, in seconds; then, in one list of numbers from 0
///     to 255, the spectrum analyser's bars (the height of each, low notes to high, and then the
///     height of each bar's cap) and what the tune's voices are doing, in three rows: a light for each
///     voice that has one (how bright it is), each one's pitch in half semitones (120 is middle C; 0
///     for none), and 1 for each that a note has just been started on; and how many voices there are.
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
    _ accepts: @escaping (String) -> Bool,
    _ added: @escaping (String) -> Void,
    _ loaded: @escaping (Bool, String, Int, Int, Double) -> Void,
    _ progress: @escaping (Double, [Double], Int) -> Void,
    _ rendered: @escaping (Double, Double) -> Void,
    _ ended: @escaping () -> Void,
    _ held: @escaping () -> Void,
    _ pointed: @escaping (Double, Bool) -> Void,
    _ scrolled: @escaping (Double, Double) -> Void,
    _ frame: @escaping (Double, Double, Double) -> Void
) throws(JSException)

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

/// Opens the browser's file chooser, for files or for a whole folder.
@JSFunction(from: .global)
func sidayChoose(_ folder: Bool) throws(JSException)

/// Loads a file from the list, by its place in it, and plays a song of it: -1 for the one the file names.
@JSFunction(from: .global)
func sidayPlay(_ index: Int, _ subsong: Int) throws(JSException)

@JSFunction(from: .global)
func sidayPause(_ paused: Bool) throws(JSException)

/// A file has been taken out of the list: the one at this place in it. Those after it move up one.
@JSFunction(from: .global)
func sidayRemove(_ index: Int) throws(JSException)

/// Every file has been taken out of the list.
@JSFunction(from: .global)
func sidayRemoveAll() throws(JSException)

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

/// What tunes are heard through: an output style, by its name and by its place in the order SidayKit
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

/// The listener's settings: a number for each of SidayKit's settings, in the order it lists them, with
/// commas between; and the same in the form they are to be remembered in from one visit to the next.
/// If the playing song has to be rendered again to be heard as they now are, it is, and goes on from
/// where it had got to once that much is ready.
@JSFunction(from: .global)
func sidaySettings(_ values: String, _ remembered: String) throws(JSException)

/// The settings remembered from the last visit, as `sidaySettings` was given them; empty if none were.
@JSFunction(from: .global)
func sidayRememberedSettings() throws(JSException) -> String

/// The name of the output style remembered from the last visit; empty if there was none.
@JSFunction(from: .global)
func sidayRememberedOutput() throws(JSException) -> String
