// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// A sound from one of Sierra's adventure games of the later 1980s, the ones its Adventure Game
/// Interpreter ran: King's Quest I to IV, Space Quest I and II, Police Quest, Leisure Suit Larry,
/// Gold Rush!, Manhunter and the rest. Each sound is four voices, three of tones and one of noise,
/// written for the sound chip of IBM's PCjr and the Tandy 1000. A voice is a list of notes, and a
/// note is how long it lasts, in sixtieths of a second, and the three bytes that were written to
/// the chip for it: the tone's (or the noise's) two and the volume's one.
///
/// The file is a sound as it was kept in the game, taken out of it: four places, one for each
/// voice, from the start of the file, and the voices after them, each ended by a duration of
/// 65,535.
struct AGISoundFile {
    struct Note {
        /// How many sixtieths of a second it lasts: up to 65,535, nought among them.
        var duration: Int
        /// The upper six bits of the tone's divider; for the noise, nothing it is played by.
        var high: UInt8
        /// The chip's command for the tone's lower four bits, or for the noise's kind and rate.
        var low: UInt8
        /// The chip's command for the volume, its lower four bits how far it is turned down: 15 is silence.
        var volume: UInt8

        /// How far the volume is turned down, from 0 (the loudest) to 15 (silence).
        var attenuation: Int { Int(volume & 0x0F) }
        /// What the chip's clock is divided by for the tone, from its two bytes: ten bits.
        var divider: Int { Int(high & 0x3F) << 4 | Int(low & 0x0F) }
    }

    /// The four voices' notes, up to the mark that ends each.
    let voices: [[Note]]

    init(_ data: [UInt8]) throws(TuneError) {
        guard data.count >= 8 else { throw .malformed("too short for a Sierra AGI sound") }
        func word(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        var voices: [[Note]] = []
        for voice in 0 ..< 4 {
            var place = word(voice * 2)
            guard place >= 8, place < data.count else { throw .malformed("not a Sierra AGI sound: voice \(voice + 1) is outside the file") }
            var notes: [Note] = []
            while true {
                guard place + 2 <= data.count else { throw .malformed("not a Sierra AGI sound: voice \(voice + 1) has no end") }
                let duration = word(place)
                if duration == 0xFFFF { break }
                guard place + 5 <= data.count else { throw .malformed("not a Sierra AGI sound: voice \(voice + 1) has no end") }
                notes.append(Note(duration: duration, high: data[place + 2], low: data[place + 3], volume: data[place + 4]))
                place += 5
            }
            voices.append(notes)
        }
        self.voices = voices
    }

    /// How long the sound lasts, in ticks: the longest voice's notes, one after another. A note of no
    /// length is held for 65,536 ticks, as both Sierra's interpreters have it (its count is taken down
    /// before it is looked at).
    var ticks: Int {
        voices.map { $0.reduce(0) { $0 + ($1.duration == 0 ? 65536 : $1.duration) } }.max() ?? 0
    }
}

enum AGIFile {
    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> any Renderer {
        let sound = try AGISoundFile(data)
        switch options.agiReplay {
        case .amiga: return AGIAmigaRenderer(sound, later: false, options: options)
        case .amigaLater: return AGIAmigaRenderer(sound, later: true, options: options)
        case .pc: return AGIPCRenderer(sound, options: options)
        }
    }
}
