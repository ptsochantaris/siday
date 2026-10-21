// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit

// The web player's engine. It is a WebAssembly module of its own, with no user interface and no
// JavaScript library: a worker (Web/engine.js) hands it the bytes of a tune and asks it for samples,
// through the functions exported at the foot of this file, and passes them on to the audio thread.
//
// The worker renders a whole song as fast as it can and keeps it, so that the listener can move about
// in it. What it keeps is the tune as the chip made it. The television, if the sound is going through
// one, and the spectrum analyser, which shows what is being heard, are applied to each piece as it is
// sent to be played: `pull` makes the sound and `present` finishes it. So a television can be put in
// the way or taken out of it at any moment; a change between mono and stereo is a change to what the
// chip makes, and the song has to be rendered again (`setOutput` says when).

/// The one tune player of the module (see SidayKit's `TunePlayer`), and what `siday_pull` last made:
/// interleaved stereo, the size of block a browser's audio thread works in.
private let quantumFrames = 128
nonisolated(unsafe) private let player = TunePlayer()
nonisolated(unsafe) private let output = UnsafeMutablePointer<Float>.allocate(capacity: quantumFrames * 2)
/// What `siday_level_key` and `siday_level` last handed out, kept for the page to read.
nonisolated(unsafe) private var levelBytes: [UInt8] = []

// MARK: Exports

// Memory for the page to put a file in before calling `siday_load`.
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

/// Loads the tune in `data`; `name` is its file name or path, in UTF-8. Returns 1 if it will play.
@_expose(wasm, "siday_load")
@_cdecl("siday_load")
public func sidayLoad(_ data: UnsafePointer<UInt8>, _ length: Int32, _ name: UnsafePointer<UInt8>, _ nameLength: Int32) -> Int32 {
    let bytes = Array(UnsafeBufferPointer(start: data, count: Int(length)))
    let name = String(decoding: UnsafeBufferPointer(start: name, count: Int(nameLength)), as: UTF8.self)
    return player.load(bytes, name: name) ? 1 : 0
}

/// The files the tune next loaded needs beside its own, given one at a time before `siday_load`, in
/// the order `Companions.wanted` has them: `found` 0 for one that was not found, and a `length` of
/// -1 forgets those given before.
@_expose(wasm, "siday_companion")
@_cdecl("siday_companion")
public func sidayCompanion(_ data: UnsafePointer<UInt8>?, _ length: Int32, _ found: Int32) {
    if length < 0 {
        player.companions = []
    } else if found == 0 {
        player.companions.append(nil)
    } else {
        player.companions.append(data.map { Array(UnsafeBufferPointer(start: $0, count: Int(length))) } ?? [])
    }
}

/// HVSC's Songlengths.md5, for the SID tunes loaded after it. A length of zero forgets it.
@_expose(wasm, "siday_set_songlengths")
@_cdecl("siday_set_songlengths")
public func sidaySetSongLengths(_ data: UnsafePointer<UInt8>, _ length: Int32) -> Int32 {
    let database = SongLengthDatabase(Array(UnsafeBufferPointer(start: data, count: Int(length))))
    player.setSongLengths(database.isEmpty ? nil : database)
    return database.isEmpty ? 0 : 1
}

@_expose(wasm, "siday_select")
@_cdecl("siday_select")
public func sidaySelect(_ subsong: Int32) {
    player.select(Int(subsong))
}

/// The listener's settings: `count` numbers at `values`, one for each of SidayKit's settings in the
/// order it lists them. Returns 1 if the tune that is loaded has to be loaded again (`siday_load`) to
/// be heard as they now are: a setting has changed that has to do with a tune of its kind.
@_expose(wasm, "siday_set_settings")
@_cdecl("siday_set_settings")
public func sidaySetSettings(_ values: UnsafePointer<Double>, _ count: Int32) -> Int32 {
    player.setSettings(Array(UnsafeBufferPointer(start: values, count: Int(count)))) ? 1 : 0
}

/// What tunes are heard through: an output style, by its place in the order SidayKit lists them.
/// Returns 1 if the tune that is loaded has to be loaded again (`siday_load`) to be heard that way,
/// which is so when the change is between mono and stereo, or one stereo and the other, and the tune
/// is one that stereo makes a difference to. A television is put in or taken out as the tune plays.
@_expose(wasm, "siday_set_output")
@_cdecl("siday_set_output")
public func sidaySetOutput(_ style: Int32) -> Int32 {
    let styles = OutputStyle.allCases
    guard styles.indices.contains(Int(style)) else { return 0 }
    return player.setOutput(styles[Int(style)]) ? 1 : 0
}

/// Renders the next 128 frames into the buffer at `siday_output`, as the chip made them. Returns 0
/// once the tune is over.
/// Says which voices are to be left out when the tune is next loaded: a byte for each voice, 1 for
/// one not to be heard; no bytes for every voice heard. Returns 1 if the tune can be loaded so at
/// once, and 0 if its song must first be played to the end with every voice heard.
@_expose(wasm, "siday_set_muted")
@_cdecl("siday_set_muted")
public func sidaySetMuted(_ marks: UnsafePointer<UInt8>?, _ count: Int32) -> Int32 {
    var muted: [Bool] = []
    if let marks { for index in 0 ..< Int(max(0, count)) { muted.append(marks[index] != 0) } }
    return player.setMuted(muted) ? 1 : 0
}

/// What the song's level is kept under (see `SongLevel.key`), in UTF-8, `siday_level_key_length`
/// bytes of it: the same for the same song of the same file played the same way.
@_expose(wasm, "siday_level_key")
@_cdecl("siday_level_key")
public func sidayLevelKey() -> UnsafePointer<UInt8>? {
    levelBytes = Array(player.levelKey.utf8)
    return levelBytes.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "siday_level_key_length")
@_cdecl("siday_level_key_length")
public func sidayLevelKeyLength() -> Int32 {
    Int32(player.levelKey.utf8.count)
}

/// The song's level as it was found by measuring it here (see `SongLevel.text`), to be kept, in
/// UTF-8, `siday_level_length` bytes; none until it has been.
@_expose(wasm, "siday_level")
@_cdecl("siday_level")
public func sidayLevel() -> UnsafePointer<UInt8>? {
    levelBytes = player.levelFound ? Array((player.level?.text ?? "").utf8) : []
    return levelBytes.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "siday_level_length")
@_cdecl("siday_level_length")
public func sidayLevelLength() -> Int32 {
    player.levelFound ? Int32((player.level?.text ?? "").utf8.count) : 0
}

/// Gives the song the level that was kept for it, as `siday_level` gave it. Returns 1 if it was one.
@_expose(wasm, "siday_set_level")
@_cdecl("siday_set_level")
public func sidaySetLevel(_ text: UnsafePointer<UInt8>, _ length: Int32) -> Int32 {
    guard let level = SongLevel(text: String(decoding: UnsafeBufferPointer(start: text, count: Int(length)), as: UTF8.self)) else { return 0 }
    player.setLevel(level)
    return 1
}

/// How far the song is turned up or down to be as loud as the rest, in dB; not a number while that
/// is not known, or songs are not levelled.
@_expose(wasm, "siday_level_change")
@_cdecl("siday_level_change")
public func sidayLevelChange() -> Double {
    player.levelChange
}

/// 1 if the song is not to be heard until it is levelled: songs are levelled, and its level is not
/// known yet, from what was kept or from measuring it whole.
@_expose(wasm, "siday_waits_for_level")
@_cdecl("siday_waits_for_level")
public func sidayWaitsForLevel() -> Int32 {
    player.waitsForLevel ? 1 : 0
}

/// The song can wait no longer: it starts at about its level, by as much of it as has been measured.
@_expose(wasm, "siday_start_at_provisional_level")
@_cdecl("siday_start_at_provisional_level")
public func sidayStartAtProvisionalLevel() {
    player.startAtProvisionalLevel()
}

@_expose(wasm, "siday_pull")
@_cdecl("siday_pull")
public func sidayPull() -> Int32 {
    player.pull(into: output, frames: quantumFrames) ? 1 : 0
}

@_expose(wasm, "siday_output")
@_cdecl("siday_output")
public func sidayOutput() -> UnsafeMutablePointer<Float> {
    output
}

/// Finishes `frames` frames of rendered sound at `samples`, in place, on their way to being heard:
/// the television, if one is on, and the spectrum analyser. They can be any part of the song, in any
/// order; call `siday_settle` first when they do not follow the last ones.
@_expose(wasm, "siday_present")
@_cdecl("siday_present")
public func sidayPresent(_ samples: UnsafeMutablePointer<Float>, _ frames: Int32) {
    player.present(samples, frames: Int(frames))
}

@_expose(wasm, "siday_settle")
@_cdecl("siday_settle")
public func sidaySettle() {
    player.settle()
}

/// The spectrum analyser's bars for the sound presented so far: `siday_spectrum_bands` bars, low to high,
/// and then as many caps, each a byte from 0 to 255. Call it as often as the bars are drawn.
@_expose(wasm, "siday_spectrum")
@_cdecl("siday_spectrum")
public func sidaySpectrum() -> UnsafePointer<UInt8>? {
    player.analyse()
    return player.bars.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "siday_spectrum_bands")
@_cdecl("siday_spectrum_bands")
public func sidaySpectrumBands() -> Int32 {
    Int32(player.bars.count / 2)
}

/// What is known of each voice of the tune, for the sound rendered since this was last called. There
/// are `siday_lights_count` voices, and five bytes for each, kept as five rows: first a light for
/// each voice, from 0, dark, to 255; then each voice's pitch in half semitones, 120 being middle C,
/// or 0 for a voice with none; then 1 for each voice a note was started on; then the side each is
/// heard from, 1 for the left, 128 for the middle, 255 for the right; then 1 for each voice that is
/// playing a sample, and 0 for one whose sound a chip makes of itself. Nil if there are no voices.
@_expose(wasm, "siday_lights")
@_cdecl("siday_lights")
public func sidayLights() -> UnsafePointer<UInt8>? {
    player.takeVoices()
    return player.voicesTaken.withUnsafeBufferPointer { $0.baseAddress }
}

/// Each voice's scope, as the sound rendered so far ends (see `ChannelWaves.take`): 64 bytes for each
/// of the `siday_lights_count` voices, one voice after another, 128 for the middle, 1 at the bottom
/// and 255 at the top. Flat for a tune whose player does not keep its voices' sound. Nil if there
/// are no voices.
@_expose(wasm, "siday_scopes")
@_cdecl("siday_scopes")
public func sidayScopes() -> UnsafePointer<UInt8>? {
    player.takeScopes()
    return player.scopes.withUnsafeBufferPointer { $0.baseAddress }
}

/// How many voices the loaded tune has lights for: an AY chip's three channels, a module's tracks.
@_expose(wasm, "siday_lights_count")
@_cdecl("siday_lights_count")
public func sidayLightsCount() -> Int32 { Int32(player.voiceCount) }

/// How many of them, the first, every tune of the kind has. The rest are for voices a tune may never
/// use (a beeper, the samples played on a SID's volume), and are worth showing once they have lit.
@_expose(wasm, "siday_lights_always")
@_cdecl("siday_lights_always")
public func sidayLightsAlways() -> Int32 { Int32(player.lightsAlwaysShown) }

@_expose(wasm, "siday_text")
@_cdecl("siday_text")
public func sidayText() -> UnsafePointer<UInt8>? {
    player.text.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "siday_text_length")
@_cdecl("siday_text_length")
public func sidayTextLength() -> Int32 {
    Int32(player.text.count)
}

@_expose(wasm, "siday_subsongs")
@_cdecl("siday_subsongs")
public func sidaySubsongs() -> Int32 { Int32(player.subsongCount) }

@_expose(wasm, "siday_subsong")
@_cdecl("siday_subsong")
public func sidaySubsong() -> Int32 { Int32(player.subsong) }

@_expose(wasm, "siday_length")
@_cdecl("siday_length")
public func sidayLength() -> Double { player.length }

/// 1 when the file says how long the song is; 0 when `siday_length` is only the time it is allowed.
@_expose(wasm, "siday_length_known")
@_cdecl("siday_length_known")
public func sidayLengthKnown() -> Int32 { player.lengthIsKnown ? 1 : 0 }

/// Once a song is over and it ended on its own terms: how long it played for, up to where its ending
/// began (see `TuneSession.playedLength`); 0 before then, or if it ended by falling silent.
@_expose(wasm, "siday_played_length")
@_cdecl("siday_played_length")
public func sidayPlayedLength() -> Double { player.playedLength }

/// Once a song is over: the seconds of silence at its end that showed it was, if that is how it
/// ended, and 0 if not. They are no part of the song.
@_expose(wasm, "siday_silence")
@_cdecl("siday_silence")
public func sidaySilence() -> Double { player.silenceAtEnd }

@_expose(wasm, "siday_position")
@_cdecl("siday_position")
public func sidayPosition() -> Double { player.position }

@_expose(wasm, "siday_state")
@_cdecl("siday_state")
public func sidayState() -> Int32 { Int32(player.state) }

@main struct Main {
    /// Nothing to do: the module waits to be called.
    static func main() {}
}
