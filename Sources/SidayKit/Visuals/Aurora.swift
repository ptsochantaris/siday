// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// An aurora: the tune as bands of light drifting across a night sky. What each voice plays is drawn
/// at the right-hand edge, higher for a higher note and brighter for a louder one, and the whole
/// drifts away to the left, spreading and fading as it goes. A voice with no pitch, a drum or a
/// hiss, is a low glow along the horizon.
///
/// The light is kept as red, green and blue for each dot, with no upper limit, and squeezed into what
/// a screen can show only as it is painted: so that bands that cross add up as light does.
final class Aurora: VisualScene {
    /// Green through to violet, to begin with, and until other colours are asked for.
    let look = VisualLook(hue: 0.47, spread: 0.42)
    let drift: Float = 0

    private var light: [Float] = []
    /// How loud each voice is, followed more slowly than the other pictures follow it: a band of
    /// light that flickered with every note would be a row of stripes.
    private var calm: [Float] = []
    private var width = 0, height = 0
    /// How far the sky has still to drift, in parts of a dot.
    private var owed: Float = 0
    /// Seconds for the sky to cross the picture.
    private static let crossing: Float = 14

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        if width != self.width || height != self.height {
            self.width = width
            self.height = height
            light = [Float](repeating: 0, count: width * height * 3)
            owed = 0
        }
        let count = frame.voices.count
        if calm.count != count { calm = [Float](repeating: 0, count: count) }
        for index in 0 ..< count {
            let level = frame.voices[index].level
            calm[index] += (level - calm[index]) * (1 - expf(-frame.elapsed / (level > calm[index] ? 0.2 : 0.8)))
        }

        // The drift: whole dots at a time, and what is left over is owed to the next frame.
        owed += frame.elapsed * Float(width) / Self.crossing
        let shift = min(width, Int(owed))
        owed -= Float(shift)

        // What is there fades, and spreads a little each way, as it ages.
        let fade = expf(-frame.elapsed / 7)
        let spread = min(0.15, frame.elapsed * 1.6), along = min(0.2, frame.elapsed * 4)
        let rowLength = width * 3
        light.withUnsafeMutableBufferPointer { light in
            guard let light = light.baseAddress else { return }
            if shift > 0 {
                for row in 0 ..< height {
                    let start = light + row * rowLength
                    start.update(from: start + shift * 3, count: (width - shift) * 3)
                }
            }
            let old = (width - shift) * 3
            for row in 0 ..< height {
                let here = light + row * rowLength
                // The top row has nothing above it and the bottom row nothing below: each is its own
                // neighbour on that side, and fades with the rest.
                let above = row > 0 ? here - rowLength : here, below = row < height - 1 ? here + rowLength : here
                // (The last columns are about to be drawn afresh.) So it is for the dots at either
                // end of a row, which only fade.
                guard old >= 6 else { continue }
                for index in 0 ..< 3 {
                    here[index] *= fade
                    here[old - 3 + index] *= fade
                }
                for index in 3 ..< old - 3 {
                    here[index] = (here[index] * (1 - 2 * spread - 2 * along) + (above[index] + below[index]) * spread
                        + (here[index - 3] + here[index + 3]) * along) * fade
                }
            }

            // The new edge: for each column that has come into the picture, each voice's light.
            guard shift > 0 else { return }
            for column in (width - shift) ..< width {
                for row in 0 ..< height {
                    let at = light + row * rowLength + column * 3
                    at[0] = 0
                    at[1] = 0
                    at[2] = 0
                }
            }
            for index in 0 ..< count {
                let voice = frame.voices[index], level = calm[index]
                guard level > 0.02 else { continue }
                let colour = frame.look.colour(of: index, among: count, saturation: voice.pitched ? 0.8 : 0.5)
                // A band is a curtain of light: a bright hem where the note is, soft below it, and
                // rays that reach up from it and thin away. It is taller and brighter the louder the
                // voice, and a note being struck brightens it a little. It sways, as curtains do.
                let sway = 0.012 * sinf(frame.time * 0.9 + Float(index) * 1.7)
                let centre: Float = voice.pitched ? 0.9 - 0.78 * frame.height(of: voice.pitch) + sway : 0.96
                let reach: Float = voice.pitched ? 0.008 + 0.014 * level : 0.035
                let rays: Float = voice.pitched ? reach * (3 + 5 * level) : reach
                let bright = level * level.squareRoot() * (voice.pitched ? 1.1 : 0.4) * (1 + 0.2 * voice.kick)
                let middle = centre * Float(height), size = max(1, reach * Float(height)), tail = max(1, rays * Float(height))
                let first = max(0, Int(middle - tail * 4)), last = min(height - 1, Int(middle + size * 3))
                guard first <= last else { continue }
                for row in first ... last {
                    let offset = Float(row) - middle
                    let share = bright * (offset > 0 ? expf(-0.5 * (offset / size) * (offset / size)) : expf(offset / tail))
                    for column in (width - shift) ..< width {
                        let at = light + row * rowLength + column * 3
                        at[0] += colour.0 * share
                        at[1] += colour.1 * share
                        at[2] += colour.2 * share
                    }
                }
            }
        }

        // The sky: night, a little lighter towards the horizon, and the light over it.
        let sky = VisualLook.rgb(hue: frame.look.hue + 0.2, saturation: 0.75, value: 1)
        var pixel = frame.pixels
        var at = 0
        for row in 0 ..< height {
            let low = Float(row) / Float(height)
            let dusk = 0.02 + 0.07 * low * low
            for _ in 0 ..< width {
                // Light adds up, and a screen has a limit: it is come to gently.
                let r = 1 - expf(-(light[at] + sky.0 * dusk) * 1.6)
                let g = 1 - expf(-(light[at + 1] + sky.1 * dusk) * 1.6)
                let b = 1 - expf(-(light[at + 2] + sky.2 * dusk) * 1.6)
                pixel[0] = UInt8(max(0, min(255, r * 255)))
                pixel[1] = UInt8(max(0, min(255, g * 255)))
                pixel[2] = UInt8(max(0, min(255, b * 255)))
                pixel[3] = 255
                pixel += 4
                at += 3
            }
        }
    }
}
