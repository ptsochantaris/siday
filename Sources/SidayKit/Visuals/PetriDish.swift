// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A petri dish, and life of a kind in it that lives in waves, set off by the music. A note being struck charges the
/// picture where the note is: low notes to the left and high ones to the right (with the ends of the
/// tune's range drawn in: see `VisualFrame.place`), each voice along a line of its own. From there a
/// wave of charge spreads out as a ring, and goes on long after its note: for the charge at a place
/// sets off the places beside it, and the place is then tired for a while, and cannot be set off
/// again until it has rested. So a wave leaves the tired place behind it and moves on; two waves
/// that meet put each other out, each having nowhere left to go, or, the busier the music, the
/// likelier tear each other instead; and a wave that is broken, by a new note struck in its way or
/// by tearing, curls round at its broken ends into spirals, which turn and send out waves of their
/// own. So each note is a beginning, and what it begins meets what the others began,
/// and what comes of that meets more.
///
/// A voice with no pitch, a drum or a hiss, sets off no wave. It tires a place come by chance,
/// which breaks whatever wave comes through it.
///
/// It lives only on what the music gives it. Each note makes the whole picture more ready to be set
/// off, and the place round it most of all; and that readiness is spent away, slowly. So when the
/// music stops, the waves that are under way find less and less to carry them, and fade out.
///
/// Each wave is the colour of the voice that set it off, and a place takes the colour of the wave
/// that sets it off: so the colours go where the waves go.
///
/// The rule is Dwight Barkley's model of such things (the waves of the Belousov-Zhabotinsky
/// reaction, or those that keep a heart beating), worked out on a grid coarser than the picture,
/// in many small steps a second whatever the screen's rate.
final class PetriDish: VisualScene {
    /// Colours from most of the wheel, one for each voice.
    let look = VisualLook(hue: 0.62, spread: 0.7)
    /// Going round the wheel once in six minutes.
    let drift: Float = 1.0 / 360

    /// How many rows the grid has, whatever the size of the picture.
    private static let rows = 96
    /// Barkley's numbers: how charged a tired place must be to be set off again (`a` and `b`), and
    /// how much quicker a place is set off than it tires (`quickness`), which is less, and the waves
    /// the more unsettled, the busier the music: while it is busiest, a wave that meets another
    /// tears, and its torn ends curl up into spirals of their own; while it is sparse, they meet and
    /// go out quietly.
    private static let a: Float = 0.84, b: Float = 0.07, quickness: Float = 0.03, quicknessBusiest: Float = 0.09
    /// How fast charge spreads from a place to those beside it.
    private static let spreading: Float = 4
    /// How far the waves are moved on a second, and in steps of how much.
    private static let pace: Float = 3, step: Float = 0.01
    /// How much less ready a place is to be set off when the music has given it nothing.
    private static let starving: Float = 0.25
    /// How long readiness lasts, in seconds, to fall to about a third.
    private static let readinessLasts: Float = 8
    /// How much readier the whole picture is for each note.
    private static let readierByANote: Float = 0.15
    /// How wide a place a note charges, and how wide a place round it it makes readier, in places of the grid.
    private static let struckWidth: Float = 3, readyWidth: Float = 12

    private var across = 0, down = 0
    /// The charge at each place, how tired it is, and how ready it is to be set off by what the
    /// music gave it there; and its colour, as red, green and blue.
    private var charge: [Float] = [], tired: [Float] = [], ready: [Float] = [], colour: [Float] = []
    /// Whether each place has been given a colour yet: 1 if it has.
    private var coloured: [Float] = []
    /// The colour as it is shown: softened, so that where the waves of two voices meet, each fades
    /// into the other, and not along a line (which is where two rings growing alike meet: a straight
    /// one). Red, green, blue and how much colour there was, for each place; worked out afresh for
    /// each frame, from `colour`, which is left as it is.
    private var shown: [Float] = [], softening: [Float] = []
    /// How far the colour is softened, in places of the grid.
    private static let softness = 6
    /// How ready the whole picture is.
    private var readiness: Float = 0
    private var owed: Float = 0

    private struct Voice {
        /// Where it is, and how struck it was a frame ago, and how long since it last struck a note.
        var x: Float = 0.5, y: Float = 0.5, kick: Float = 0, since: Float = 10
    }

    private var voices: [Voice] = []
    private var seed: UInt32 = 0x11FE_C0DE

    private func chance() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24)
    }

    private func start(across: Int, down: Int) {
        self.across = across
        self.down = down
        charge = [Float](repeating: 0, count: across * down)
        tired = charge
        ready = charge
        colour = [Float](repeating: 0, count: across * down * 3)
        coloured = charge
        shown = [Float](repeating: 0, count: across * down * 4)
        softening = shown
        owed = 0
    }

    /// Calls `body` with each place of the grid within a radius of a point (in places of the grid),
    /// and how near it is, from 1 in the middle to nothing at the edge.
    private func around(_ x: Float, _ y: Float, radius: Float, _ body: (Int, Float) -> Void) {
        let column = Int(x), row = Int(y), span = Int(radius) + 1
        guard row + span >= 0, row - span < down, column + span >= 0, column - span < across else { return }
        for r in max(0, row - span) ... min(down - 1, row + span) {
            for c in max(0, column - span) ... min(across - 1, column + span) {
                let dx = Float(c) + 0.5 - x, dy = Float(r) + 0.5 - y
                let near = 1 - (dx * dx + dy * dy) / (radius * radius)
                if near > 0 { body(r * across + c, near) }
            }
        }
    }

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        let wantedAcross = max(24, min(3 * Self.rows, Self.rows * width / max(1, height)))
        if across != wantedAcross || down != Self.rows { start(across: wantedAcross, down: Self.rows) }
        let count = frame.voices.count
        if voices.count != count { voices = [Voice](repeating: Voice(), count: count) }

        for index in 0 ..< count {
            let voice = frame.voices[index]
            let line = Float(index) * 0.618034
            if voice.pitched {
                voices[index].x = Float(across) * (0.1 + 0.8 * frame.place(of: voice.pitch))
                voices[index].y = Float(down) * (0.15 + 0.7 * (line - line.rounded(.down)))
            }
            voices[index].since += frame.elapsed
            // As the pond counts its drops: a note is struck if the voice is more struck than it was
            // a frame ago, and notes that come faster than eight a second are one.
            if voice.kick > voices[index].kick + 0.3, voices[index].since > 0.12, voice.heardLevel > 0.05 {
                voices[index].since = 0
                readiness = min(1, readiness + Self.readierByANote)
                if voice.pitched {
                    let tint = frame.look.colour(of: index, among: count)
                    let loud = voice.heardLevel
                    around(voices[index].x, voices[index].y, radius: Self.struckWidth * (0.7 + 0.5 * loud)) { at, _ in
                        charge[at] = max(charge[at], 0.9)
                        colour[at * 3] = tint.0
                        colour[at * 3 + 1] = tint.1
                        colour[at * 3 + 2] = tint.2
                        coloured[at] = 1
                    }
                    around(voices[index].x, voices[index].y, radius: Self.readyWidth) { at, near in
                        ready[at] = min(1, ready[at] + near)
                    }
                } else {
                    let x = Float(across) * (0.05 + 0.9 * chance()), y = Float(down) * (0.05 + 0.9 * chance())
                    around(x, y, radius: Self.struckWidth * 1.5) { at, near in
                        tired[at] = min(1, tired[at] + 0.6 * near * voice.heardLevel)
                    }
                }
            }
            voices[index].kick = voice.kick
        }

        owed += frame.elapsed * Self.pace / Self.step
        let steps = min(Int(0.1 * Self.pace / Self.step), Int(owed))
        owed -= Float(steps)
        if steps > 0 { move(steps) }
        soften()
        let kept = expf(-frame.elapsed / Self.readinessLasts)
        readiness *= kept
        for at in ready.indices { ready[at] *= kept }

        // What it looks like: the charge, bright in its colour, and a dim glow of the same colour
        // where it has lately been, while the place is tired; read off the four places of the grid
        // round each dot.
        let scaleX = Float(across - 1) / Float(width), scaleY = Float(down - 1) / Float(height)
        var pixel = frame.pixels
        charge.withUnsafeBufferPointer { charge in
            tired.withUnsafeBufferPointer { tired in
                shown.withUnsafeBufferPointer { colour in
                    for row in 0 ..< height {
                        let gy = Float(row) * scaleY
                        let gridRow = Int(gy), v = gy - Float(gridRow)
                        let nextRow = min(down - 1, gridRow + 1)
                        for column in 0 ..< width {
                            let gx = Float(column) * scaleX
                            let gridColumn = Int(gx), u = gx - Float(gridColumn)
                            let nextColumn = min(across - 1, gridColumn + 1)
                            let a = gridRow * across + gridColumn, b = gridRow * across + nextColumn
                            let c = nextRow * across + gridColumn, d = nextRow * across + nextColumn
                            let wa = (1 - u) * (1 - v), wb = u * (1 - v), wc = (1 - u) * v, wd = u * v
                            let lit = charge[a] * wa + charge[b] * wb + charge[c] * wc + charge[d] * wd
                            let after = tired[a] * wa + tired[b] * wb + tired[c] * wc + tired[d] * wd
                            let light = 0.95 * lit + 0.22 * after
                            let red = (colour[a * 4] * wa + colour[b * 4] * wb + colour[c * 4] * wc + colour[d * 4] * wd) * light
                            let green = (colour[a * 4 + 1] * wa + colour[b * 4 + 1] * wb + colour[c * 4 + 1] * wc + colour[d * 4 + 1] * wd) * light
                            let blue = (colour[a * 4 + 2] * wa + colour[b * 4 + 2] * wb + colour[c * 4 + 2] * wc + colour[d * 4 + 2] * wd) * light
                            // A hint of white where the charge is greatest, as in the middle of a flame.
                            let white = max(0, lit - 0.7) * 0.5
                            pixel[0] = UInt8(max(0, min(255, (0.012 + red + white) * 255)))
                            pixel[1] = UInt8(max(0, min(255, (0.012 + green + white) * 255)))
                            pixel[2] = UInt8(max(0, min(255, (0.02 + blue + white) * 255)))
                            pixel[3] = 255
                            pixel += 4
                        }
                    }
                }
            }
        }
    }

    /// Moves the waves on by so many steps.
    private func move(_ steps: Int) {
        let across = across, down = down
        let step = Self.step, spreading = Self.spreading, a = Self.a, b = Self.b
        let quickness = Self.quickness + (Self.quicknessBusiest - Self.quickness) * readiness
        let starving = Self.starving, readiness = readiness
        var next = charge
        charge.withUnsafeMutableBufferPointer { kept in
            next.withUnsafeMutableBufferPointer { spare in
                tired.withUnsafeMutableBufferPointer { tired in
                    colour.withUnsafeMutableBufferPointer { colour in
                        coloured.withUnsafeMutableBufferPointer { coloured in
                            ready.withUnsafeBufferPointer { ready in
                                // The charge as it is, and as it will be after the step: the two are
                                // taken in turns.
                                var charge = kept, next = spare
                                for _ in 0 ..< steps {
                                    for row in 0 ..< down {
                                        let up = row > 0 ? -across : 0, below = row < down - 1 ? across : 0
                                        for column in 0 ..< across {
                                            let at = row * across + column
                                            let left = column > 0 ? -1 : 0, right = column < across - 1 ? 1 : 0
                                            let here = charge[at]
                                            // How the charge round it differs from its own: that is what spreads.
                                            let round = charge[at + left] + charge[at + right] + charge[at + up] + charge[at + below] - 4 * here
                                            // A place needs more charge to be set off the more tired it is, and
                                            // the less the music has made it ready.
                                            let fed = max(readiness, ready[at])
                                            let needed = (tired[at] + b + starving * (1 - min(1, fed))) / a
                                            let after = max(0, min(1, here + step * (here * (1 - here) * (here - needed) / quickness + spreading * round)))
                                            next[at] = after
                                            // A place tires only once it is well set off, and then all at once
                                            // (Markus Bär and Martin Eiswirth's change to Barkley's rule, which is
                                            // what lets the waves tear).
                                            let tiring: Float = here < 1.0 / 3 ? 0 : 1 - 6.75 * here * (here - 1) * (here - 1)
                                            tired[at] += step * (tiring - tired[at])
                                            // A place being set off takes the colour of the charge that sets it off:
                                            // that of the places beside it, each counted by how much charge it has.
                                            if here < 0.3, after >= 0.3 {
                                                var weight: Float = 0, red: Float = 0, green: Float = 0, blue: Float = 0
                                                for beside in [at + left, at + right, at + up, at + below] where beside != at {
                                                    // (Only those that are themselves set off: the places ahead of
                                                    // the wave have a little charge too, and no colour yet.)
                                                    let w = max(0, charge[beside] - 0.3)
                                                    red += colour[beside * 3] * w
                                                    green += colour[beside * 3 + 1] * w
                                                    blue += colour[beside * 3 + 2] * w
                                                    weight += w
                                                }
                                                if weight > 0.001 {
                                                    colour[at * 3] = red / weight
                                                    colour[at * 3 + 1] = green / weight
                                                    colour[at * 3 + 2] = blue / weight
                                                    coloured[at] = 1
                                                }
                                            }
                                        }
                                    }
                                    swap(&charge, &next)
                                }
                                if charge.baseAddress != kept.baseAddress { kept.update(fromContentsOf: charge) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Works out the colour as it is shown: each place's the mean of the colours round it, as far
    /// out as the softness, counting only places that have a colour. (The mean of a square, taken
    /// twice, which comes out round enough.)
    private func soften() {
        let across = across, down = down, reach = Self.softness
        shown.withUnsafeMutableBufferPointer { shown in
            softening.withUnsafeMutableBufferPointer { softening in
                colour.withUnsafeBufferPointer { colour in
                    coloured.withUnsafeBufferPointer { coloured in
                        for at in 0 ..< across * down {
                            let weight = coloured[at]
                            shown[at * 4] = colour[at * 3] * weight
                            shown[at * 4 + 1] = colour[at * 3 + 1] * weight
                            shown[at * 4 + 2] = colour[at * 3 + 2] * weight
                            shown[at * 4 + 3] = weight
                        }
                    }
                }
                /// Adds up, into `to`, the places of `from` within reach along each line, across or down.
                func pass(_ from: UnsafeMutableBufferPointer<Float>, _ to: UnsafeMutableBufferPointer<Float>, downwards: Bool) {
                    let lines = downwards ? across : down, length = downwards ? down : across
                    let apart = downwards ? across * 4 : 4, lineApart = downwards ? 4 : across * 4
                    for line in 0 ..< lines {
                        let first = line * lineApart
                        for channel in 0 ..< 4 {
                            var sum: Float = 0
                            for place in 0 ..< min(reach, length) { sum += from[first + place * apart + channel] }
                            for place in 0 ..< length {
                                if place + reach < length { sum += from[first + (place + reach) * apart + channel] }
                                to[first + place * apart + channel] = sum
                                if place - reach >= 0 { sum -= from[first + (place - reach) * apart + channel] }
                            }
                        }
                    }
                }
                for _ in 0 ..< 2 {
                    pass(shown, softening, downwards: false)
                    pass(softening, shown, downwards: true)
                }
                for at in 0 ..< across * down {
                    let weight = shown[at * 4 + 3]
                    guard weight > 0.0001 else { continue }
                    shown[at * 4] /= weight
                    shown[at * 4 + 1] /= weight
                    shown[at * 4 + 2] /= weight
                }
            }
        }
    }
}
