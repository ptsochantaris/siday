// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A pond at night, seen from above. A note being struck is a drop falling into it: low notes to
/// the left and high ones to the right (with the ends of the tune's range drawn in, so that its
/// melodies are spread wide: see `VisualFrame.place`), each voice along a line of its own, and
/// harder the louder the note. The rings spread and cross and come back off the banks, as rings do. A voice that
/// holds its note keeps the water trembling where it is, in finer ripples the higher the note; and
/// each voice leaves its colour in the water, which spreads and fades. A voice with no pitch, a
/// drum or a hiss, is rain: its drops fall anywhere.
///
/// The water is real, in a small way: its height is kept for each place on a grid half as fine as
/// the picture, and moved on by the rule that a place is drawn towards the mean of its neighbours,
/// which is all a wave is. It is moved on so many times a second whatever the screen's rate.
final class Pond: VisualScene {
    /// The blues and greens of water, to begin with.
    let look = VisualLook(hue: 0.52, spread: 0.3)
    /// And then every colour, once round the wheel in eight minutes.
    let drift: Float = 1.0 / 480

    /// How many times a second the water is moved on. A ring crosses the pond in some six seconds.
    private static let pace: Float = 45
    /// What is left of a wave's height after each move: it dies away in a few seconds.
    private static let calming: Float = 0.992

    private var across = 0, down = 0
    /// The water's height now and one move ago, and the colour in it, for each place on the grid.
    private var water: [Float] = [], before: [Float] = [], dye: [Float] = []
    /// What each place on the grid looks like: red, green and blue, with no upper limit.
    private var seen: [Float] = []
    private var owed: Float = 0

    private struct Source {
        /// How far through its trembling it is, how struck it was a frame ago, and how long since its last drop.
        var phase: Float = 0, kick: Float = 0, sinceDrop: Float = 1
        var x: Float = 0.5, y: Float = 0.5
    }

    private var sources: [Source] = []
    private var seed: UInt32 = 0x1234_5678

    private func chance() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24)
    }

    /// Adds to the water round a place: a drop, or a nudge. It is spread over some places and not
    /// put all in one, which would make a ring as fine as the grid, and those look like scratches.
    private func disturb(_ x: Float, _ y: Float, by amount: Float) {
        let column = Int(x * Float(across)), row = Int(y * Float(down))
        for dy in -3 ... 3 {
            for dx in -3 ... 3 {
                let c = column + dx, r = row + dy
                guard c > 0, c < across - 1, r > 0, r < down - 1 else { continue }
                water[r * across + c] += amount * expf(-Float(dx * dx + dy * dy) / 4.5)
            }
        }
    }

    /// Lets colour into the water round a place.
    private func tint(_ x: Float, _ y: Float, _ colour: (Float, Float, Float), by amount: Float) {
        let column = Int(x * Float(across)), row = Int(y * Float(down))
        for dy in -4 ... 4 {
            for dx in -4 ... 4 {
                let c = column + dx, r = row + dy
                guard c > 0, c < across - 1, r > 0, r < down - 1 else { continue }
                let share = amount * max(0, 1 - Float(dx * dx + dy * dy) / 18)
                let at = (r * across + c) * 3
                dye[at] += colour.0 * share
                dye[at + 1] += colour.1 * share
                dye[at + 2] += colour.2 * share
            }
        }
    }

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        if across != width / 2 || down != height / 2 {
            across = width / 2
            down = height / 2
            water = [Float](repeating: 0, count: across * down)
            before = water
            dye = [Float](repeating: 0, count: across * down * 3)
            seen = dye
            owed = 0
        }
        guard across > 4, down > 4 else { return }
        let count = frame.voices.count
        if sources.count != count { sources = [Source](repeating: Source(), count: count) }

        // Where each voice is, and its drops.
        for index in 0 ..< count {
            let voice = frame.voices[index]
            let line = Float(index) * 0.618034
            if voice.pitched {
                sources[index].x = 0.1 + 0.8 * frame.place(of: voice.pitch)
                sources[index].y = 0.18 + 0.64 * (line - line.rounded(.down)) + 0.03 * sinf(frame.time * 0.31 + line * 6)
            }
            sources[index].sinceDrop += frame.elapsed
            // A note has been struck if the voice is more struck than it was a frame ago. Notes that
            // come faster than eight a second are one drop.
            if voice.kick > sources[index].kick + 0.3, sources[index].sinceDrop > 0.12, voice.heardLevel > 0.05 {
                sources[index].sinceDrop = 0
                if !voice.pitched {
                    sources[index].x = 0.06 + 0.88 * chance()
                    sources[index].y = 0.08 + 0.84 * chance()
                }
                disturb(sources[index].x, sources[index].y, by: -(voice.pitched ? 0.9 : 0.45) * (0.35 + 0.65 * voice.heardLevel))
            }
            sources[index].kick = voice.kick
        }

        // The water is moved on, as many times as are due.
        owed += frame.elapsed * Self.pace
        let moves = min(5, Int(owed))
        owed -= Float(moves)
        let step = 1 / Self.pace
        for _ in 0 ..< moves {
            for index in 0 ..< count {
                let voice = frame.voices[index]
                guard voice.level > 0.03 else { continue }
                let colour = frame.look.colour(of: index, among: count, saturation: voice.pitched ? 0.85 : 0.3)
                // A held note trembles: from one and a half times a second for the lowest to four
                // for the highest. And a voice's colour runs into the water while it sounds, most
                // as a note is struck.
                if voice.pitched {
                    sources[index].phase += step * 2 * Float.pi * (1.5 + 2.5 * frame.height(of: voice.pitch))
                    disturb(sources[index].x, sources[index].y, by: 0.022 * voice.level * sinf(sources[index].phase))
                }
                tint(sources[index].x, sources[index].y, colour, by: step * (voice.pitched ? 1 : 0.5) * (0.6 * voice.level + 1.4 * voice.kick * voice.level))
            }

            // A place is drawn towards the mean of the four beside it, and overshoots: that is the
            // wave. The banks stay where they are, which sends the rings back.
            water.withUnsafeMutableBufferPointer { water in
                before.withUnsafeMutableBufferPointer { before in
                    guard let water = water.baseAddress, let before = before.baseAddress else { return }
                    for row in 1 ..< down - 1 {
                        var at = row * across + 1
                        for _ in 1 ..< across - 1 {
                            before[at] = ((water[at - 1] + water[at + 1] + water[at - across] + water[at + across]) * 0.5 - before[at]) * Self.calming
                            at += 1
                        }
                    }
                }
            }
            swap(&water, &before)
            // And the finest ripples, which a grid makes more of than water does, are smoothed away.
            water.withUnsafeMutableBufferPointer { water in
                guard let water = water.baseAddress else { return }
                for row in 1 ..< down - 1 {
                    var at = row * across + 1
                    for _ in 1 ..< across - 1 {
                        water[at] = water[at] * 0.8 + (water[at - 1] + water[at + 1] + water[at - across] + water[at + across]) * 0.05
                        at += 1
                    }
                }
            }

            // The colour spreads a little and fades.
            let fade = expf(-step / 5)
            dye.withUnsafeMutableBufferPointer { dye in
                guard let dye = dye.baseAddress else { return }
                let rowLength = across * 3
                for row in 1 ..< down - 1 {
                    var at = row * rowLength + 3
                    for _ in 3 ..< rowLength - 3 {
                        dye[at] = (dye[at] * 0.6 + (dye[at - 3] + dye[at + 3] + dye[at - rowLength] + dye[at + rowLength]) * 0.1) * fade
                        at += 1
                    }
                }
            }
        }

        // What it looks like: dark water, the colour in it, and the light that the slopes of the
        // waves catch from one side and lose from the other.
        let still = VisualLook.rgb(hue: frame.look.hue + 0.08, saturation: 0.8, value: 1)
        for row in 1 ..< down - 1 {
            let far = 1 - Float(row) / Float(down)
            let depth = 0.05 + 0.05 * far
            for column in 1 ..< across - 1 {
                let at = row * across + column
                let slope = (water[at + 1] - water[at - 1]) * 0.6 + (water[at + across] - water[at - across]) * 0.8
                // A slope towards the light is brighter and one away from it darker, and neither by
                // more than so much: water has no hard edges.
                let lit = min(1, max(0, -slope) * 9), shaded = 1 - min(0.6, max(0, slope) * 7)
                let colour = at * 3
                seen[colour] = (still.0 * depth + dye[colour]) * shaded * (1 + lit * 1.5) + lit * 0.1
                seen[colour + 1] = (still.1 * depth + dye[colour + 1]) * shaded * (1 + lit * 1.5) + lit * 0.11
                seen[colour + 2] = (still.2 * depth + dye[colour + 2]) * shaded * (1 + lit * 1.5) + lit * 0.13
            }
        }

        // The dots, each read off the four places of the grid around it. (The outermost places are
        // banks, and are left out: the picture is of the water within them.)
        var pixel = frame.pixels
        let scaleX = Float(across - 3) / Float(width), scaleY = Float(down - 3) / Float(height)
        for row in 0 ..< height {
            let gy = 1 + Float(row) * scaleY
            let gridRow = Int(gy), v = gy - Float(gridRow)
            for column in 0 ..< width {
                let gx = 1 + Float(column) * scaleX
                let gridColumn = Int(gx), u = gx - Float(gridColumn)
                let a = (gridRow * across + gridColumn) * 3, b = a + 3, c = a + across * 3, d = c + 3
                let wa = (1 - u) * (1 - v), wb = u * (1 - v), wc = (1 - u) * v, wd = u * v
                let red = seen[a] * wa + seen[b] * wb + seen[c] * wc + seen[d] * wd
                let green = seen[a + 1] * wa + seen[b + 1] * wb + seen[c + 1] * wc + seen[d + 1] * wd
                let blue = seen[a + 2] * wa + seen[b + 2] * wb + seen[c + 2] * wc + seen[d + 2] * wd
                pixel[0] = UInt8(max(0, min(255, (1 - expf(-red * 1.8)) * 255)))
                pixel[1] = UInt8(max(0, min(255, (1 - expf(-green * 1.8)) * 255)))
                pixel[2] = UInt8(max(0, min(255, (1 - expf(-blue * 1.8)) * 255)))
                pixel[3] = 255
                pixel += 4
            }
        }
    }
}
