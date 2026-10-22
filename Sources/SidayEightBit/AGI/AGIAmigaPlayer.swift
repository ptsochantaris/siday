// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Sierra's routines for playing the sounds of its AGI games on the Amiga (1986-88), as they are kept
// in Wanted Team's player of the sounds for EaglePlayer (2006), which was read for this.

import SidayChips
import SidayFoundation

/// Sierra's interpreter for the Amiga, as far as its sounds: the four voices of a sound played on
/// Paula's four, each tone from a wave of a few samples and the noise from a long stretch of it. Its
/// interrupt runs sixty times a second, as the PC's clock does, and starts each voice's next note
/// when its last has had its time.
///
/// There were two routines in the interpreter's time, which Wanted Team's player keeps both of. The
/// first plays a tone as a square wave and holds it at its volume; the later one plays it as a wave
/// in eight steps, more nearly a sine, and turns each note down over its first second, as Sierra's
/// later interpreters for the PC did. In both, a voice's volume is its note's, from 64 at the loudest
/// to nought in fifteen even steps: not the PC chip's steps of 2 dB.
///
/// A voice is started once, at its first note, and then left running: each note after that changes
/// only its period and its volume, so that a tone goes on from where the last left off.
struct AGIAmigaPlayer: ~Copyable {
    var paula: Paula
    private let sound: AGISoundFile
    private let later: Bool

    private struct Voice {
        var next = 0
        /// Ticks until the next note, which the interrupt counts down: one at the start, so that the
        /// first notes are begun by its first run.
        var countdown: UInt16 = 1
        var playing = true
        var attenuation = 0
        var volume: UInt16 = 0
        /// Where the voice is in the later routine's dying away, or nil once that is over.
        var fade: Int? = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The voices Paula has been started for.
    private var running: UInt16 = 0
    private(set) var stopped = false
    /// For what is shown of the voices: each tone's pitch, and whether a note has begun on it.
    private var pitches = InlineArray<4, Float>(repeating: 0)
    private var struck = InlineArray<4, Bool>(repeating: false)

    /// Where the waves are in the memory Paula plays from: the first routine's square, its later one's
    /// eight steps, the noise, and silence.
    static let squareAt = 0, roundAt = 4, noiseAt = 12, silenceAt = 12 + 4096
    static let memorySize = silenceAt + 16

    /// The memory Paula plays from, made afresh: the waves both routines make when they begin.
    static func makeMemory() -> UnsafeMutablePointer<Int8> {
        let memory = UnsafeMutablePointer<Int8>.allocate(capacity: memorySize)
        memory.initialize(repeating: 0, count: memorySize)
        // A square wave of two samples, twice over.
        for (i, value) in ([0, -128, 0, -128] as [Int8]).enumerated() { memory[squareAt + i] = value }
        for (i, value) in ([0, 64, 127, 64, 0, -64, -127, -64] as [Int8]).enumerated() { memory[roundAt + i] = value }
        // The noise is the lower byte of a shift register of sixteen bits, after each of its steps.
        var shift: UInt16 = 1
        for i in 0 ..< 4096 {
            shift = shift & 1 != 0 ? (shift >> 1) ^ 0x0CA0 : shift >> 1
            memory[noiseAt + i] = Int8(truncatingIfNeeded: shift)
        }
        return memory
    }

    /// The interrupt runs as often as a timer of the Amiga's that is set to 11,822 of its E clock's
    /// ticks, and takes one more than it is set to to come round: sixty times a second, all but
    /// exactly. (Wanted Team's player sets it to five sixths of DeliTracker's usual, which is set to
    /// 14,187 for fifty.) Paula's clock is five of the E clock's.
    static let tickClocks = (11822 + 1) * 5

    /// How far the later routine turns a note down, tick by tick from its first, in the PC chip's
    /// steps of volume; and after the last, it is left where that put it.
    private static let fading: [Int] = [2, 1, 0, 0, 0, 0, 1, 1, 1, 1]
        + Array(repeating: 2, count: 8) + Array(repeating: 3, count: 7)
        + [4, 5, 6, 7, 8, 9, 10].flatMap { Array(repeating: $0, count: 5) } + [11]

    init(_ sound: AGISoundFile, later: Bool, model: AmigaModel, memory: UnsafePointer<Int8>) {
        self.sound = sound
        self.later = later
        paula = Paula(rate: Double(outputSampleRate * 2), model: model, memory: memory, size: Self.memorySize, silence: Self.silenceAt)
        if later {
            // (The later routine points each voice at its wave once, before the first note.)
            for voice in 0 ..< 4 {
                paula.setLocation(voice, voice == 3 ? Self.noiseAt : Self.roundAt)
                paula.setLength(voice, voice == 3 ? 0x800 : 4)
            }
        }
    }

    /// Runs the interrupt once. Returns false once every voice has come to its end.
    mutating func runTick() -> Bool {
        guard !stopped else { return false }
        for voice in 0 ..< 4 where voices[voice].playing {
            voices[voice].countdown &-= 1
            if voices[voice].countdown != 0 {
                // (Only the later routine does anything to a note while it is held.)
                if later {
                    fadeStep(voice)
                    paula.setVolume(voice, voices[voice].volume)
                }
                continue
            }
            guard voices[voice].next < sound.voices[voice].count else {
                voices[voice].playing = false
                paula.stop(voices: 1 << voice)
                running &= ~(1 << UInt16(voice))
                pitches[voice] = 0
                continue
            }
            let note = sound.voices[voice][voices[voice].next]
            voices[voice].next += 1
            voices[voice].countdown = UInt16(truncatingIfNeeded: note.duration)
            start(note, on: voice)
        }
        if voices[0].playing || voices[1].playing || voices[2].playing || voices[3].playing { return true }
        stopped = true
        return false
    }

    private mutating func start(_ note: AGISoundFile.Note, on voice: Int) {
        let period: UInt16
        if voice == 3 {
            // The noise at one of three rates: the chip's 512th, 1,024th or 2,048th of its clock, as
            // near as Paula has it. Its fourth, at the third tone's rate, is taken as the slowest.
            period = [0x200, 0x400, 0x800, 0x800][Int(note.low & 3)]
        } else {
            if later { voices[voice].fade = 0 }
            // A period of the chip's divider times so many of Paula's clocks that the wave, of two
            // samples to a cycle or of eight, is at the chip's pitch.
            period = UInt16(note.divider << (later ? 2 : 4))
        }
        voices[voice].attenuation = note.attenuation
        voices[voice].volume = UInt16((15 - note.attenuation) << 6 / 15)
        paula.setPeriod(voice, period)
        if later {
            fadeStep(voice)
        } else {
            paula.setLocation(voice, voice == 3 ? Self.noiseAt : Self.squareAt)
            paula.setLength(voice, voice == 3 ? 0x800 : 2)
        }
        paula.setVolume(voice, voices[voice].volume)
        if running & (1 << UInt16(voice)) == 0 {
            paula.start(voices: 1 << UInt16(voice))
            running |= 1 << UInt16(voice)
        }
        if voices[voice].volume > 0 {
            struck[voice] = true
            let cycle = Double(period) * (voice == 3 ? 1 : later ? 8 : 2)
            pitches[voice] = voice == 3 || note.divider == 0 ? 0 : ChannelPitch.note(ofHz: Paula.clockHz / cycle)
        } else {
            pitches[voice] = 0
        }
    }

    /// The later routine's turning down of a note, a tick's worth. (The noise's is begun only with the
    /// sound, and not with each of its notes: so only its first second's notes die away.)
    private mutating func fadeStep(_ voice: Int) {
        guard let place = voices[voice].fade else { return }
        guard place < Self.fading.count else {
            voices[voice].fade = nil
            return
        }
        voices[voice].fade = place + 1
        let attenuation = max(0, min(15, voices[voice].attenuation + Self.fading[place]))
        voices[voice].volume = UInt16((15 - attenuation) << 6 / 15)
    }

    /// What each voice is playing, and whether a note has begun on it since this was last asked.
    mutating func takeNotes(into notes: inout TickNotes) {
        for voice in 0 ..< 4 {
            notes.pitches[voice] = voices[voice].playing && voices[voice].volume > 0 ? pitches[voice] : 0
            if struck[voice] { notes.struck[voice] = true }
            struck[voice] = false
        }
    }
}
