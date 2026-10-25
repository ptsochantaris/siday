// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayPlayer

/// What is being heard at this moment, for the screen to show: where in the song, the spectrum
/// analyser's bars, and what each voice with a light is doing. (Of the sound that is coming out of
/// the speaker now, not of what was last sent: see `PlaybackEngine.latency`.)
nonisolated struct Heard: Sendable {
    var tune = 0
    var serial = 0
    var position = 0.0
    /// The analyser's bars and then their caps, 0 to 1.
    var bars: [Float] = []
    var caps: [Float] = []
    /// For each voice with a light: its brightness, 0 to 1; its pitch in semitones (60 is middle
    /// C), 0 for none; whether a note was started on it; the side it is heard from, -1 to 1; what it
    /// is playing; and whether the listener has left it out.
    var levels: [Float] = []
    var pitches: [Float] = []
    var struck: [Bool] = []
    var sides: [Float] = []
    var kinds: [VoiceKind] = []
    var muted: [Bool] = []
    /// Each voice's scope, `ChannelWaves.points` points of it from -1 to 1, one voice after another.
    var scopes: [Float] = []
    /// True if the listener has paused, or nothing is playing.
    var resting = true

    init() {}

    /// Unpacks a chunk as the engine sent it.
    init(_ sent: SongKeeper.Sent) {
        tune = sent.tune
        serial = sent.serial
        position = sent.position
        let bands = sent.bars.count / 2
        bars = sent.bars.prefix(bands).map { Float($0) / 255 }
        caps = sent.bars.dropFirst(bands).map { Float($0) / 255 }
        let count = sent.voices.count / 6
        let rows = (0 ..< 6).map { row in Array(sent.voices[(row * count) ..< ((row + 1) * count)]) }
        muted = rows[5].map { $0 != 0 }
        levels = rows[0].map { Float($0) / 255 }
        pitches = rows[1].map { Float($0) / 2 }
        struck = rows[2].map { $0 != 0 }
        sides = rows[3].map { (Float($0) - 128) / 127 }
        kinds = rows[4].map { $0 == 2 ? .speaker : $0 != 0 ? .sample : .chip }
        scopes = (sent.scopes ?? []).map { (Float($0) - 128) / 127 }
        resting = false
    }
}

/// What a voice plays, as its light shows it.
nonisolated enum VoiceKind: Sendable, Equatable {
    /// A sound a chip makes of itself: a square wave, an FM voice, a waveform drawn in a tracker.
    case chip
    /// A recording of a sound.
    case sample
    /// The clicks of a loudspeaker that the computer's own code moves in and out: a beeper.
    case speaker
}
