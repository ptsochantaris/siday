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
///     details one to a line (format, title, author, detail) or the reason it does not, how many songs
///     it has, which one is playing, and its length in seconds.
///   - progress: where the playing song has got to, in seconds, and how loud it is just now (0 to 1).
///   - ended: the song is over.
///   - held: the browser will not let the sound start until the listener has pressed something on the
///     page; the tune is loaded and waiting.
@JSFunction(from: .global)
func sidayListen(
    _ accepts: @escaping (String) -> Bool,
    _ added: @escaping (String) -> Void,
    _ loaded: @escaping (Bool, String, Int, Int, Double) -> Void,
    _ progress: @escaping (Double, Double) -> Void,
    _ ended: @escaping () -> Void,
    _ held: @escaping () -> Void
) throws(JSException)

/// Opens the browser's file chooser, for files or for a whole folder.
@JSFunction(from: .global)
func sidayChoose(_ folder: Bool) throws(JSException)

/// Loads a file from the list, by its place in it, and plays a song of it: -1 for the one the file names.
@JSFunction(from: .global)
func sidayPlay(_ index: Int, _ subsong: Int) throws(JSException)

@JSFunction(from: .global)
func sidayPause(_ paused: Bool) throws(JSException)

/// 0 for none, then the sets in the order SidayKit lists them.
@JSFunction(from: .global)
func sidayTelevision(_ set: Int) throws(JSException)
