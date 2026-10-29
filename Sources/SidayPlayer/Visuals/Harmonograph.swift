// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// A harmonograph: a pen held over the paper by pendulums, as the Victorians drew the shapes of
/// musical intervals. One pendulum swings the pen from side to side at the pitch of the loudest voice,
/// and another up and down at the pitch of the next: so the picture is the interval between them. A
/// unison draws a circle, an octave a figure of eight, a fifth a knot of three loops; and since an
/// equal-tempered interval is never quite the ratio of small numbers it stands for, the figure turns
/// slowly over, as a harmonograph's did when its pendulums were set a hair out of true. Even a true
/// unison or octave is let turn so, its two pendulums drifting slowly out of step and back: a circle
/// flattens to a line and opens again, a figure of eight folds to a bow. A tune with only one voice
/// heard draws a unison.
///
/// The pendulums swing the wider the louder the voices, and a note struck gives them a push; as the
/// music thins, they die away and the pen spirals in. The ink is the colour of the two voices, and
/// fades as it dries, so what is seen is the last few seconds of the drawing.
final class Harmonograph: VisualScene {
    /// Colours from most of the wheel, one for each voice.
    let look = VisualLook(hue: 0.08, spread: 0.6)
    /// Going round the wheel once in five minutes, as the lava lamp's do.
    let drift: Float = 1.0 / 300

    private var ink: [Float] = []
    private var width = 0, height = 0
    /// How loud each voice is, followed more slowly than the other pictures follow it, and the kick
    /// each last had, to tell when a new note is struck.
    private var calm: [Float] = []
    private var lastKick: [Float] = []
    /// The two voices the pendulums follow: the across one and the up-and-down one; -1 for none.
    private var across = -1, upDown = -1
    /// How far the pendulums swing, from 0 to 1, and where each is in its swing, in turns.
    private var swing: Float = 0
    private var acrossPhase: Float = 0, upDownPhase: Float = 0.25
    /// The ratio of the up-and-down swing to the across one, gliding to the interval heard.
    private var ratio: Float = 1
    /// The figure as a whole turns, slowly.
    private var turn: Float = 0
    /// The colour of the ink, gliding to that of the two voices.
    private var colour: (Float, Float, Float) = (1, 0.6, 0.3)

    /// The across pendulum's swings a second, and how far the up-and-down one drifts out of step with
    /// it, in turns a second.
    private static let pace: Float = 2, outOfStep: Float = 1.0 / 40
    /// Seconds for the ink to fade to about a third.
    private static let dries: Float = 4

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        if width != self.width || height != self.height {
            self.width = width
            self.height = height
            ink = [Float](repeating: 0, count: width * height * 3)
        }
        let count = frame.voices.count
        if calm.count != count {
            calm = [Float](repeating: 0, count: count)
            lastKick = calm
            across = -1
            upDown = -1
        }
        func eased(_ seconds: Float) -> Float { 1 - expf(-frame.elapsed / seconds) }
        var struck = false
        for index in 0 ..< count {
            let voice = frame.voices[index]
            calm[index] += (voice.level - calm[index]) * eased(voice.level > calm[index] ? 0.2 : 1)
            if voice.kick > lastKick[index] + 0.5, voice.pitched, index == across || index == upDown { struck = true }
            lastKick[index] = voice.kick
        }
        choose(frame)

        // The swing follows how loud the two voices are, quick to grow and slow to die; a note struck
        // pushes the pendulums a little further.
        let loudness = across >= 0 ? max(calm[across], upDown >= 0 ? calm[upDown] : 0) : 0
        let wanted = min(1, loudness.squareRoot())
        swing += (wanted - swing) * eased(wanted > swing ? 1.5 : 4)
        if struck { swing = min(1, swing + 0.04) }

        // The interval: the up-and-down voice's pitch over the across one's, brought within an octave
        // (an octave itself is two to one, and only a unison is one to one).
        var wantedRatio: Float = 1
        if across >= 0, upDown >= 0 {
            var semitones = abs(frame.voices[upDown].pitch - frame.voices[across].pitch)
            while semitones > 12.01 { semitones -= 12 }
            wantedRatio = powf(2, semitones / 12)
        }
        ratio += (wantedRatio - ratio) * eased(0.4)
        turn += frame.elapsed * 0.003

        var wantedColour = frame.look.colour(of: max(0, across), among: max(1, count), saturation: 0.75)
        if upDown >= 0 {
            let other = frame.look.colour(of: upDown, among: count, saturation: 0.75)
            wantedColour = ((wantedColour.0 + other.0) / 2, (wantedColour.1 + other.1) / 2, (wantedColour.2 + other.2) / 2)
        }
        colour.0 += (wantedColour.0 - colour.0) * eased(1)
        colour.1 += (wantedColour.1 - colour.1) * eased(1)
        colour.2 += (wantedColour.2 - colour.2) * eased(1)

        let fade = expf(-frame.elapsed / Self.dries)
        ink.withUnsafeMutableBufferPointer { ink in
            for index in ink.indices { ink[index] *= fade }
            draw(into: ink, frame)
        }

        // The paper: nearly black, and the ink on it, which adds up where the pen goes over a line
        // again and is come to a screen's limit gently.
        var pixel = frame.pixels
        var at = 0
        for _ in 0 ..< width * height {
            pixel[0] = UInt8(max(0, min(255, (0.03 + 0.97 * (1 - expf(-ink[at] * 1.4))) * 255)))
            pixel[1] = UInt8(max(0, min(255, (0.03 + 0.97 * (1 - expf(-ink[at + 1] * 1.4))) * 255)))
            pixel[2] = UInt8(max(0, min(255, (0.035 + 0.965 * (1 - expf(-ink[at + 2] * 1.4))) * 255)))
            pixel[3] = 255
            pixel += 4
            at += 3
        }
    }

    /// Which voices the pendulums follow: the two loudest that have a pitch. A pendulum keeps its voice
    /// until another is clearly louder, so that the figure does not jump between voices as loud as
    /// each other.
    private func choose(_ frame: VisualFrame) {
        func heard(_ index: Int) -> Bool { index >= 0 && index < frame.voices.count && frame.voices[index].pitched && calm[index] > 0.03 }
        func loudest(besides other: Int) -> Int {
            var best = -1
            for index in 0 ..< frame.voices.count where index != other && heard(index) {
                if best < 0 || calm[index] > calm[best] { best = index }
            }
            return best
        }
        let first = loudest(besides: -1)
        if !heard(across) || (first >= 0 && first != across && calm[first] > calm[across] * 1.5) { across = first }
        let second = loudest(besides: across)
        if !heard(upDown) || upDown == across || (second >= 0 && second != upDown && calm[second] > calm[upDown] * 1.5) { upDown = second }
    }

    /// Moves the pen on, by this frame's time, drawing as it goes: in steps short enough that the line
    /// is unbroken, each leaving as much ink as the next.
    private func draw(into ink: UnsafeMutableBufferPointer<Float>, _ frame: VisualFrame) {
        guard swing > 0.005, let ink = ink.baseAddress else {
            acrossPhase += frame.elapsed * Self.pace
            upDownPhase += frame.elapsed * (Self.pace * ratio + Self.outOfStep)
            return
        }
        let size = Float(min(width, height)) * 0.44
        let reachAcross = min(Float(width) * 0.46, size * 1.35) * swing, reachUpDown = size * swing
        let centreX = Float(width) / 2, centreY = Float(height) / 2
        let cosTurn = cosf(turn * 2 * .pi), sinTurn = sinf(turn * 2 * .pi)
        // The pen's fastest is about this many dots a second; the steps are each about half a dot.
        let speed = 2 * Float.pi * Self.pace * max(1, ratio) * max(reachAcross, reachUpDown)
        let steps = max(1, min(4000, Int(speed * frame.elapsed * 2)))
        let step = frame.elapsed / Float(steps)
        let strength = 0.3 * (0.4 + 0.6 * swing)
        for _ in 0 ..< steps {
            acrossPhase += step * Self.pace
            upDownPhase += step * (Self.pace * ratio + Self.outOfStep)
            let x = reachAcross * sinf(acrossPhase * 2 * .pi), y = reachUpDown * sinf(upDownPhase * 2 * .pi)
            dab(ink, x: centreX + x * cosTurn - y * sinTurn, y: centreY + x * sinTurn + y * cosTurn, strength)
        }
        acrossPhase -= acrossPhase.rounded(.down)
        upDownPhase -= upDownPhase.rounded(.down)
    }

    /// Ink on the paper at a place between dots, shared among the four dots round it.
    private func dab(_ ink: UnsafeMutablePointer<Float>, x: Float, y: Float, _ strength: Float) {
        let left = Int(x.rounded(.down)), top = Int(y.rounded(.down))
        guard left >= 0, top >= 0, left + 1 < width, top + 1 < height else { return }
        let right = x - Float(left), down = y - Float(top)
        let at = ink + (top * width + left) * 3, below = at + width * 3
        put(at, (1 - right) * (1 - down) * strength)
        put(at + 3, right * (1 - down) * strength)
        put(below, (1 - right) * down * strength)
        put(below + 3, right * down * strength)
    }

    private func put(_ at: UnsafeMutablePointer<Float>, _ share: Float) {
        at[0] += colour.0 * share
        at[1] += colour.1 * share
        at[2] += colour.2 * share
    }
}
