// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayPlayer

// The web player's engine. It is a WebAssembly module of its own, with no user interface and no
// JavaScript library: a worker (Web/engine.js) hands it what the page asks for, through the functions
// exported at the foot of this file, and passes on what it has for the audio thread and the page.
//
// It is SidayPlayer's `SongKeeper`, as the app's engine has it: a song is rendered whole as fast as
// it can be and kept, so that the listener can move about in it, and sent to be heard in chunks, a
// little ahead. The worker gives it its turns, and the time; the chunks and the news it leaves are
// taken from it a message at a time, as bytes (see `Packed`), and the worker sends them on.

nonisolated(unsafe) private let keeper = SongKeeper()
/// The files the tune next loaded or played through needs beside its own, as `siday_companion` gave them.
nonisolated(unsafe) private var companions: [[UInt8]?] = []
/// What was last handed out for the worker to read: a message, and a chunk's sound.
nonisolated(unsafe) private var packed: [UInt8] = []
nonisolated(unsafe) private let samples = UnsafeMutablePointer<Float>.allocate(capacity: SongKeeper.chunkFrames * 2)

/// A message for the worker to read, as bytes, one thing after another: a number as eight bytes, a
/// float; and a run of bytes, or a text in UTF-8, as its length in four, an integer, and then the
/// bytes; -1 for none. Both little-endian, as WebAssembly is.
private struct Packed {
    var bytes: [UInt8] = []

    mutating func add(_ number: Double) {
        var bits = number.bitPattern
        for _ in 0 ..< 8 {
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }

    mutating func add(_ run: [UInt8]?) {
        var bits = UInt32(bitPattern: Int32(run?.count ?? -1))
        for _ in 0 ..< 4 {
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
        if let run { bytes += run }
    }

    mutating func add(_ text: String) {
        add(Array(text.utf8))
    }
}

/// An event, for the worker to tell the page of: first its kind, a number, as `siday_take_event` has
/// them, and the tune it is of.
private func pack(_ event: SongKeeper.Event) -> Packed {
    var message = Packed()
    switch event {
    case let .loaded(tune, plays, problem, info, songs, song, length, _, levelKey):
        // (The songs are counted as the file has them: one, for a file of one song, which is not listed.)
        message.add(1)
        message.add(Double(tune))
        message.add(plays ? 1 : 0)
        message.add(Double(songs.isEmpty ? (plays ? 1 : 0) : songs.count))
        message.add(Double(song))
        message.add(length)
        message.add(info.map { TunePlayer.details(of: $0, songs: songs) } ?? problem ?? "")
        message.add(levelKey)
    case let .level(tune, key, text):
        message.add(2)
        message.add(Double(tune))
        message.add(key)
        message.add(text)
    case let .rendered(tune, seconds, length):
        message.add(3)
        message.add(Double(tune))
        message.add(seconds)
        message.add(length)
    case let .remaking(tune, busy):
        message.add(4)
        message.add(Double(tune))
        message.add(busy ? 1 : 0)
    case let .muted(tune, marks):
        message.add(5)
        message.add(Double(tune))
        message.add(marks)
    case let .measure(tune, _, _, _):
        // (The file is the one the worker has just given to `siday_load`, and has still.)
        message.add(6)
        message.add(Double(tune))
    case let .songs(tune, songs):
        message.add(7)
        message.add(Double(tune))
        message.add(keeper.player.info.map { TunePlayer.details(of: $0, songs: songs) } ?? "")
    }
    return message
}

private func bytes(_ data: UnsafePointer<UInt8>, _ length: Int32) -> [UInt8] {
    Array(UnsafeBufferPointer(start: data, count: Int(max(0, length))))
}

private func text(_ data: UnsafePointer<UInt8>, _ length: Int32) -> String {
    String(decoding: UnsafeBufferPointer(start: data, count: Int(max(0, length))), as: UTF8.self)
}

// MARK: Exports

// Memory for the worker to put a file in before calling `siday_load`.
@_expose(wasm, "siday_alloc")
@_cdecl("siday_alloc")
public func sidayAlloc(_ size: Int32) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: max(1, Int(size)), alignment: 16)
}

@_expose(wasm, "siday_free")
@_cdecl("siday_free")
public func sidayFree(_ pointer: UnsafeMutableRawPointer) {
    pointer.deallocate()
}

/// The files the tune next loaded needs beside its own, given one at a time before `siday_load` (or
/// `siday_measure`), in the order `Companions.wanted` has them: `found` 0 for one that was not found,
/// and a `length` of -1 forgets those given before.
@_expose(wasm, "siday_companion")
@_cdecl("siday_companion")
public func sidayCompanion(_ data: UnsafePointer<UInt8>?, _ length: Int32, _ found: Int32) {
    if length < 0 {
        companions = []
    } else if found == 0 {
        companions.append(nil)
    } else {
        companions.append(data.map { bytes($0, length) } ?? [])
    }
}

/// Loads the tune in `data`, the page's `tune`th request to play; `name` is its file name or path, in
/// UTF-8. It starts on `subsong`, or on the song the file asks to be played first, for a negative one,
/// and sends what it renders of it as the run of sound `serial`. `now` is the time, in seconds.
@_expose(wasm, "siday_load")
@_cdecl("siday_load")
public func sidayLoad(_ data: UnsafePointer<UInt8>, _ length: Int32, _ name: UnsafePointer<UInt8>, _ nameLength: Int32,
                      _ tune: Int32, _ serial: Int32, _ subsong: Int32, _ now: Double) {
    keeper.load(tune: Int(tune), serial: Int(serial), name: text(name, nameLength), bytes: bytes(data, length),
                companions: companions, subsong: Int(subsong), now: now)
}

/// The listener has moved to `position` in the song, in seconds: sent as the run of sound `serial`.
@_expose(wasm, "siday_seek")
@_cdecl("siday_seek")
public func sidaySeek(_ position: Double, _ serial: Int32, _ now: Double) {
    keeper.seek(to: position, serial: Int(serial), now: now)
}

/// The listener has pressed a voice's light, by its place among those that are shown: with `solo` 1,
/// to hear it alone (see `SongKeeper.mute`).
@_expose(wasm, "siday_mute")
@_cdecl("siday_mute")
public func sidayMute(_ light: Int32, _ solo: Int32) {
    keeper.mute(light: Int(light), solo: solo != 0)
}

/// What tunes are heard through: an output style, by its place in the order SidayPlayer lists them.
@_expose(wasm, "siday_set_output")
@_cdecl("siday_set_output")
public func sidaySetOutput(_ style: Int32) {
    let styles = OutputStyle.allCases
    guard styles.indices.contains(Int(style)) else { return }
    keeper.setOutput(styles[Int(style)])
}

/// The listener's settings: `count` numbers at `values`, one for each of SidayPlayer's settings in the
/// order it lists them.
@_expose(wasm, "siday_set_settings")
@_cdecl("siday_set_settings")
public func sidaySetSettings(_ values: UnsafePointer<Double>, _ count: Int32) {
    keeper.setSettings(Array(UnsafeBufferPointer(start: values, count: Int(count))))
}

/// HVSC's Songlengths.md5, for the SID tunes loaded after it. A length of zero forgets it.
@_expose(wasm, "siday_set_songlengths")
@_cdecl("siday_set_songlengths")
public func sidaySetSongLengths(_ data: UnsafePointer<UInt8>, _ length: Int32) -> Int32 {
    let database = SongLengthDatabase(bytes(data, length))
    keeper.setSongLengths(database.isEmpty ? nil : database)
    return database.isEmpty ? 0 : 1
}

/// The files the listener gave once, which the page keeps and gives again at each visit (see `KeptFiles`).
nonisolated(unsafe) private var kept = KeptFiles()

/// A file the page keeps, or has just been given and may keep: taken if it is one siday keeps, and its
/// ROMs or song lengths used from now on. Returns the length of a text at `siday_packed`: the name it is
/// kept under (empty for a file that is not one), and then what is kept, a line for each
/// (`KeptFiles.summary`).
@_expose(wasm, "siday_keep")
@_cdecl("siday_keep")
public func sidayKeep(_ data: UnsafePointer<UInt8>, _ length: Int32) -> Int32 {
    let file = bytes(data, length)
    let known = KeptFile.recognise(file)
    if known != nil { kept.add(file) }
    keeper.setMT32ROMs(kept.mt32ROMs)
    keeper.setSC55ROMs(kept.sc55ROMs)
    if let lengths = kept.songLengths { keeper.setSongLengths(lengths) }
    packed = Array(([known?.keptName ?? ""] + kept.summary).joined(separator: "\n").utf8)
    return Int32(packed.count)
}

/// Forgets every file kept: MIDI files are played on FM again.
@_expose(wasm, "siday_forget_kept")
@_cdecl("siday_forget_kept")
public func sidayForgetKept() {
    kept.forgetAll()
    keeper.setMT32ROMs(nil)
    keeper.setSC55ROMs(nil)
}

/// The level the page kept under `key` (see `SongLevel.key`), as the news of a song's level gave it,
/// both in UTF-8; none (a length of 0), if none was kept.
@_expose(wasm, "siday_set_kept_level")
@_cdecl("siday_set_kept_level")
public func sidaySetKeptLevel(_ key: UnsafePointer<UInt8>, _ keyLength: Int32, _ level: UnsafePointer<UInt8>, _ levelLength: Int32, _ now: Double) {
    keeper.setKeptLevel(key: text(key, keyLength), text: levelLength > 0 ? text(level, levelLength) : nil, now: now)
}

/// The tune has been taken out of the list, and nothing follows it: the song is let go.
@_expose(wasm, "siday_stop")
@_cdecl("siday_stop")
public func sidayStop() {
    keeper.stop()
}

/// From the audio thread: a chunk of the run of sound `serial` has been heard.
@_expose(wasm, "siday_played")
@_cdecl("siday_played")
public func sidayPlayed(_ serial: Int32, _ now: Double) {
    keeper.played(serial: Int(serial), now: now)
}

/// Renders up to `chunks` chunks of the song and sends what is due (none, to send only). Returns 1 if
/// there is more to render.
@_expose(wasm, "siday_work")
@_cdecl("siday_work")
public func sidayWork(_ chunks: Int32, _ now: Double) -> Int32 {
    keeper.work(chunks: Int(chunks), now: now) ? 1 : 0
}

/// 1 while there is more of the song to render.
@_expose(wasm, "siday_working")
@_cdecl("siday_working")
public func sidayWorking() -> Int32 {
    keeper.isWorking ? 1 : 0
}

/// When `siday_work` is to be called again, in seconds, though there is nothing to render; -1 if
/// it need not be.
@_expose(wasm, "siday_wakes_at")
@_cdecl("siday_wakes_at")
public func sidayWakesAt() -> Double {
    keeper.wakesAt ?? -1
}

/// Takes the next chunk of sound there is to be heard, if there is one, and returns the length of a
/// message at `siday_packed` (or 0, for none): the run of sound it is of, the tune, the place in the
/// song it reaches, in seconds, and 1 if it is the song's last, as numbers; then the analyser's bars
/// and their caps, the voices' lights, five rows of them and a sixth for those left out (see
/// `SongKeeper.Sent`), and their scopes, or none. Its sound is at `siday_samples`, interleaved stereo,
/// `SongKeeper.chunkFrames` frames.
@_expose(wasm, "siday_take_sent")
@_cdecl("siday_take_sent")
public func sidayTakeSent() -> Int32 {
    guard !keeper.outbox.isEmpty else { return 0 }
    let sent = keeper.outbox.removeFirst()
    sent.samples.withUnsafeBufferPointer { samples.update(from: $0.baseAddress!, count: min($0.count, SongKeeper.chunkFrames * 2)) }
    var message = Packed()
    message.add(Double(sent.serial))
    message.add(Double(sent.tune))
    message.add(sent.position)
    message.add(sent.last ? 1 : 0)
    message.add(sent.bars)
    message.add(sent.voices)
    message.add(sent.scopes)
    packed = message.bytes
    return Int32(packed.count)
}

@_expose(wasm, "siday_samples")
@_cdecl("siday_samples")
public func sidaySamples() -> UnsafeMutablePointer<Float> {
    samples
}

/// Takes the next piece of news there is for the page, if there is one, and returns the length of a
/// message at `siday_packed` (or 0, for none). Its first number is its kind, the second the tune it is
/// of, and the rest as follows (see `SongKeeper.Event`):
///   1 loaded: 1 if it plays, its songs, the one playing, how long it is to be played, in seconds;
///     its details (`TunePlayer.details`), or why it does not play; what its level is kept under.
///   2 level: what it is kept under, and the level.
///   3 rendered: how much there is to move about in, and the length that was found, or 0.
///   4 remaking: 1 while the song is being made again, and 0 once it has been.
///   5 muted: a byte for each voice with a light, 1 for one left out.
///   6 measure: the songs of the tune just loaded are to be played through by another instance of
///     this module (`siday_measure`), and what it finds given to `siday_adopt`.
///   7 songs: its details, now that how long each of its songs is is known.
@_expose(wasm, "siday_take_event")
@_cdecl("siday_take_event")
public func sidayTakeEvent() -> Int32 {
    guard !keeper.events.isEmpty else { return 0 }
    packed = pack(keeper.events.removeFirst()).bytes
    return Int32(packed.count)
}

@_expose(wasm, "siday_packed")
@_cdecl("siday_packed")
public func sidayPacked() -> UnsafePointer<UInt8>? {
    packed.withUnsafeBufferPointer { $0.baseAddress }
}

/// Plays every song of the tune in `data` through, to find how long each is, as `siday_load` would load
/// it (with the files beside it given before, as for that). Returns how many bytes of what was found
/// there are at `siday_packed`, for `siday_adopt` in another instance: none, for a tune that is not
/// played through.
@_expose(wasm, "siday_measure")
@_cdecl("siday_measure")
public func sidayMeasure(_ data: UnsafePointer<UInt8>, _ length: Int32, _ name: UnsafePointer<UInt8>, _ nameLength: Int32) -> Int32 {
    keeper.player.companions = companions
    // (The digest it is kept under, in UTF-8, which has no nought in it, a nought, and the finding.)
    packed = keeper.player.measure(bytes(data, length), name: text(name, nameLength)).map { Array($0.key.utf8) + [0] + $0.measures.bytes } ?? []
    return Int32(packed.count)
}

/// Takes what `siday_measure` found of the songs of the `tune`th tune, in another instance of the
/// module, and keeps it: the page is told of them, if it is the tune that is loaded.
@_expose(wasm, "siday_adopt")
@_cdecl("siday_adopt")
public func sidayAdopt(_ data: UnsafePointer<UInt8>, _ length: Int32, _ tune: Int32) {
    let found = bytes(data, length)
    guard let split = found.firstIndex(of: 0), let measures = SongMeasures(bytes: Array(found[(split + 1)...])) else { return }
    keeper.adopt(tune: Int(tune), key: String(decoding: found[..<split], as: UTF8.self), measures: measures)
}

@main struct Main {
    /// Nothing to do: the module waits to be called.
    static func main() {}
}
