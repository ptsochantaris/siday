// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayChips
import SidayFoundation

/// A Sierra AGI sound played on the chip it was written for, the PCjr's and the Tandy 1000's, as the
/// interpreter for those machines wrote to it. That is as the recordings of King's Quest II on those
/// machines have it (NewRisingSun's, at vgmrips.net): sixty times a second, each voice whose note has
/// had its time is given its next, its three bytes written to the chip as they are in the file, the
/// tone's lower bits first, then its upper, then the volume; and when a voice comes to its end it is
/// silenced. The volumes are the chip's own, 2 dB apart. It plays once and ends.
///
/// A byte the file has for the tone's upper bits is written to the chip as it is. A note of silence
/// has nought there and in its other tone byte, and the chip takes those as for the register written
/// before them, the last voice's volume, as it takes any byte without a register of its own; the
/// recordings show that this is what the PC did. But a noise's note is given its two commands alone,
/// the noise's and the volume's, and not the nought it has beside them: written, it would turn the
/// noise to its other kind, which the music did not ask for. (There is no recording of a noise from
/// these interpreters to say what they wrote.)
final class AGIPCRenderer: Renderer {
    private(set) var info: TuneInfo
    let knownLength: Double?
    var hasEnded: Bool { stopped && chip.samplesLeft == 0 }

    private let sound: AGISoundFile
    private let chip: VGMSN

    private struct Voice {
        var next = 0
        var countdown: UInt16 = 1
        var playing = true
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    private var stopped = false
    private var ticks = 0
    /// How many of the chip's steps have been given out, up to the end of the last tick.
    private var given = 0

    /// The PCjr's clock, and the chip's kind as the recordings have it.
    private static let clock = 3_579_545.0
    private static let variant = SN76489Variant(taps: 0x0006, width: 16, sega: false, ncr: false, stereo: false, divider: 8)
    /// As loud as the rest of the music, by how loud the sounds of ten seconds or more are heard: the
    /// middle of a hundred of them, 6.7 dB under an SN76489's VGM recordings (2026-10-17).
    private static let gain: Float = 0.13

    init(_ sound: AGISoundFile, options _: LoadOptions) {
        self.sound = sound
        info = TuneInfo(format: "AGI")
        info.detail = "PCjr and Tandy 1000"
        knownLength = Double(sound.ticks) / 60
        chip = VGMSN(Self.variant, clock: Self.clock)
    }

    func select(subsong _: Int) {
        chip.reset()
        voices = InlineArray(repeating: Voice())
        stopped = false
        ticks = 0
        given = 0
    }

    /// One sixtieth of a second's notes.
    private func runTick() {
        for voice in 0 ..< 4 where voices[voice].playing {
            voices[voice].countdown &-= 1
            guard voices[voice].countdown == 0 else { continue }
            guard voices[voice].next < sound.voices[voice].count else {
                voices[voice].playing = false
                chip.write(0, 0x9F | UInt8(voice) << 5)
                continue
            }
            let note = sound.voices[voice][voices[voice].next]
            voices[voice].next += 1
            voices[voice].countdown = UInt16(truncatingIfNeeded: note.duration)
            chip.write(0, note.low)
            if voice != 3 { chip.write(0, note.high) }
            chip.write(0, note.volume)
        }
        if !(voices[0].playing || voices[1].playing || voices[2].playing || voices[3].playing) { stopped = true }
        ticks += 1
        let due = Int((Double(ticks) * chip.rate / 60).rounded())
        chip.samplesLeft += due - given
        given = due
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if chip.samplesLeft == 0 {
                if stopped {
                    (buffer + done * 2).update(repeating: 0, count: (frames - done) * 2)
                    return
                }
                runTick()
            }
            done += chip.render(into: buffer + done * 2, frames: frames - done, gain: Self.gain, fade: 0, after: 0)
        }
    }

    /// The chip's four channels: three tones and the noise.
    var channelCount: Int { 4 }

    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) { chip.takeLevels(into: levels) }

    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        chip.takeNotes(pitches: pitches, struck: struck)
    }

    func setMuted(_ muted: [Bool]) { chip.setMuted(muted) }

    /// Where the chip keeps each channel's sound for its scope, once asked.
    private var waves: ChannelWaves?

    func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            let waves = ChannelWaves(voices: 4, rate: chip.wavesRate, fullSwing: 1)
            chip.keepWaves(in: waves, first: 0)
            self.waves = waves
        }
        return waves
    }
}
