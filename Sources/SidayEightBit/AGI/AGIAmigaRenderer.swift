// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after SoundFXRenderer, and so after MODRenderer, whose way with the sound chip's output is
// derived from pt2-clone, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence (see
// THIRD-PARTY.md).

import SidayChips
import SidayFoundation

/// A Sierra AGI sound played as the Amiga versions of the games played it (see `AGIAmigaPlayer`).
/// It plays once and ends, as a sound in the game did.
///
/// As with any music for the Amiga the two sides are brought most of the way together (see
/// `MODRenderer`).
final class AGIAmigaRenderer: Renderer {
    private(set) var info: TuneInfo
    let knownLength: Double?
    var isPlayedOnAnAmiga: Bool { true }
    var hasEnded: Bool { player.stopped && tickPosition == tickFrames }

    private let sound: AGISoundFile
    private let later: Bool
    private let model: AmigaModel
    private let memory: UnsafeMutablePointer<Int8>
    /// How much of the difference between the two sides is kept, halved: none of it for mono.
    private let side: Float
    private var player: AGIAmigaPlayer
    /// One tick of sound: made at twice the rate, then brought down where it lies.
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    private var levels = TickLevels(voices: 4)
    private var notes = TickNotes(voices: 4)
    private var down = (HalfBand(), HalfBand())
    /// The part of a sample that ticks are over by, carried from tick to tick: in samples times the
    /// sound chip's clock.
    private var remainder = 0

    private static let chipClock = Int(Paula.clockHz)
    /// A tick's length at twice the output's rate, and some to spare. (Worked out in 64 bits: clocks
    /// times samples is more than the 32 that a whole number has in a browser can hold.)
    private static let tickSpace = Int(Int64(AGIAmigaPlayer.tickClocks) * Int64(outputSampleRate) * 2 / Int64(chipClock)) + 64
    /// As loud as a MOD file, which is played on the same chip (see `MODRenderer`): the sounds of ten
    /// seconds or more are heard within a dB of the rest of the music, the middle of a hundred of
    /// them with either routine (2026-10-17).
    private static let gain: Float = 0.26

    init(_ sound: AGISoundFile, later: Bool, options: LoadOptions) {
        self.sound = sound
        self.later = later
        model = options.amigaModel
        side = options.stereo == .mono ? 0 : Float(max(0, min(1, options.amigaSeparation))) * 0.5
        info = TuneInfo(format: "AGI")
        info.detail = later ? "Amiga, Sierra's later routine" : "Amiga"
        knownLength = Double((sound.ticks + 1) * AGIAmigaPlayer.tickClocks) / Paula.clockHz
        memory = AGIAmigaPlayer.makeMemory()
        left = .allocate(capacity: Self.tickSpace)
        right = .allocate(capacity: Self.tickSpace)
        player = AGIAmigaPlayer(sound, later: later, model: model, memory: memory)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        memory.deallocate()
    }

    /// The voices left out of the sound, which the sound started afresh is started without.
    private var muted: [Bool] = []

    func setMuted(_ muted: [Bool]) {
        self.muted = muted
        player.paula.setMuted(muted)
    }

    /// Where Paula keeps each voice's sound for its scope, at her own rate, once asked.
    private var waves: ChannelWaves?

    func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            waves = ChannelWaves(voices: 4, rate: Double(outputSampleRate * 2), fullSwing: 1)
            player.paula.waves = waves
        }
        return waves
    }

    func select(subsong _: Int) {
        player = AGIAmigaPlayer(sound, later: later, model: model, memory: memory)
        player.paula.setMuted(muted)
        player.paula.waves = waves
        down = (HalfBand(), HalfBand())
        tickFrames = 0
        tickPosition = 0
        levels.clear()
        notes.clear()
        remainder = 0
    }

    /// Runs the interrupt once, and makes the sound of the tick that follows it.
    private func nextTick() {
        _ = player.runTick()
        let whole = Int64(AGIAmigaPlayer.tickClocks) * Int64(outputSampleRate) + Int64(remainder)
        remainder = Int(whole % Int64(Self.chipClock))
        tickFrames = Int(whole / Int64(Self.chipClock))
        tickPosition = 0
        player.paula.generate(left: left, right: right, count: tickFrames * 2)
        player.paula.takeLevels(into: &levels.now)
        levels.tickMade()
        player.takeNotes(into: &notes)
        for i in 0 ..< tickFrames {
            left[i] = down.0.step(left[i * 2], left[i * 2 + 1])
            right[i] = down.1.step(right[i * 2], right[i * 2 + 1])
        }
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            for i in 0 ..< count {
                let l = left[tickPosition + i], r = right[tickPosition + i]
                let middle = (l + r) * 0.5, apart = (l - r) * side
                buffer[(done + i) * 2] = (middle + apart) * Self.gain
                buffer[(done + i) * 2 + 1] = (middle - apart) * Self.gain
            }
            tickPosition += count
            done += count
        }
        waves?.ahead = tickFrames - tickPosition
    }

    /// Paula's four voices: three tones and the noise.
    var channelCount: Int { 4 }

    func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< 4 { sides[voice] = Paula.side(ofVoice: voice) }
    }

    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }
}
