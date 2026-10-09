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
///   - progress: where the playing song has got to, in seconds; then, in one list, the spectrum
///     analyser's bars (the height of each, low notes to high, and then the height of each bar's cap)
///     and a light for each of the tune's voices that has one (how bright it is), all from 0 to 1;
///     and how many of the list's last numbers are the lights.
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
    _ scrolled: @escaping (Double, Double) -> Void
) throws(JSException)

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

/// Scrolls the list of tunes so that this many pixels of it are above what can be seen.
@JSFunction(from: .global)
func sidayScrollList(_ top: Double) throws(JSException)

/// What tunes are heard through: an output style, by its name and by its place in the order SidayKit
/// lists them. It is remembered from one visit to the next. If the playing song has to be rendered
/// again to be heard that way, it is, and goes on from where it had got to once that much is ready.
@JSFunction(from: .global)
func sidayOutput(_ name: String, _ place: Int) throws(JSException)

/// The name of the output style remembered from the last visit; empty if there was none.
@JSFunction(from: .global)
func sidayRememberedOutput() throws(JSException) -> String
