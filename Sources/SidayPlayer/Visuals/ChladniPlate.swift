// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// A Chladni plate: sand on a metal plate that the music sets ringing. A plate rings in patterns of
/// its own, in each of which some lines stay still while the rest of it shakes; and sand on it is
/// thrown about where it shakes and comes to rest on the lines that do not, drawing the pattern, as
/// Ernst Chladni showed in 1787 by drawing a bow along a plate's edge. Here each voice that has a pitch
/// rings the plate in a pattern of its own, a simple one of a few lines for a low note and a busier one
/// for a higher; only the two loudest ring it, the loudest the more, so that a tune of many voices
/// still draws a figure clear enough to see. The plate holds a figure for a few seconds at least, long
/// enough for the sand to settle on it, and then for as long as the notes keep to it; once they have
/// asked for another for a moment, it takes up the one they then ask for, passing to it over a second
/// or two, so that the sand on the old lines is shaken loose, spreads, and gathers on the new ones as
/// they form, and is not kept wavering between the two. How loud the music is only shakes the sand harder; a note struck shakes it harder still.
/// When the music stops, the sand stays where it lies.
///
/// The patterns are those of a square plate held at its middle, as Chladni's were, stretched to the
/// picture's shape: `cos(mπx)cos(nπy) ± cos(nπx)cos(mπy)` for two numbers `m` and `n`. How the plate
/// shakes is worked out on a coarse grid each frame, and the sand moves over it, grain by grain.
final class ChladniPlate: VisualScene {
    /// Brass and sand, warm, to begin with.
    let look = VisualLook(hue: 0.1, spread: 0.3)
    /// Going round the wheel once in ten minutes.
    let drift: Float = 1.0 / 600

    /// The patterns, simplest first: each a pair of numbers and which of the two ways they are put
    /// together. A note's pattern is found by how high it is among the tune's notes.
    private static let patterns: [(m: Float, n: Float, sign: Float)] = {
        var pairs: [(Float, Float)] = []
        for m in 0 ... 7 {
            for n in (m + 1) ... 8 { pairs.append((Float(m), Float(n))) }
        }
        pairs.sort { $0.0 * $0.0 + $0.1 * $0.1 < $1.0 * $1.0 + $1.1 * $1.1 }
        var patterns: [(m: Float, n: Float, sign: Float)] = []
        for (index, pair) in pairs.prefix(24).enumerated() { patterns.append((pair.0, pair.1, index % 2 == 0 ? -1 : 1)) }
        return patterns
    }()

    /// The grid the plate's shaking is worked out on, a side of it.
    private static let grid = 64
    /// How many grains of sand there are.
    private static let grains = 9000

    /// How the plate shakes, as the figure it holds would have it, and as it does, passing to that.
    private var wanted = [Float](repeating: 0, count: ChladniPlate.grid * ChladniPlate.grid)
    /// The figure the plate holds, as the patterns of the loudest voice and the next (-1 for none),
    /// since when it has held it, and since when the notes have asked for another, if they have.
    private var held = (-1, -1)
    private var heldSince: Float = 0, otherSince: Float?
    /// How long the plate holds a figure at least, and how long the notes must ask for another after
    /// that before it takes one up, in seconds.
    private static let lasting: Float = 2, asking: Float = 0.5
    private var shaking = [Float](repeating: 0, count: ChladniPlate.grid * ChladniPlate.grid)
    private var grainX: [Float] = [], grainY: [Float] = []
    private var light: [Float] = []
    private var width = 0, height = 0
    /// How loud each voice is, followed more slowly, and the kick it last had.
    private var calm: [Float] = []
    private var lastKick: [Float] = []
    /// How hard the plate is being shaken: how loud the music is, and a little more for a note struck.
    private var vigour: Float = 0
    private var random: UInt32 = 0x2545_F491

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        if width != self.width || height != self.height {
            self.width = width
            self.height = height
            light = [Float](repeating: 0, count: width * height)
        }
        if grainX.isEmpty {
            // Strewn evenly to begin with, as sand is shaken on to a plate.
            grainX = (0 ..< Self.grains).map { _ in next() }
            grainY = (0 ..< Self.grains).map { _ in next() }
        }
        let count = frame.voices.count
        if calm.count != count {
            calm = [Float](repeating: 0, count: count)
            lastKick = calm
        }
        func eased(_ seconds: Float) -> Float { 1 - expf(-frame.elapsed / seconds) }
        var loudness: Float = 0, struck = false
        for index in 0 ..< count {
            let voice = frame.voices[index]
            calm[index] += (voice.level - calm[index]) * eased(voice.level > calm[index] ? 0.3 : 0.8)
            if voice.pitched { loudness += calm[index] }
            if voice.kick > lastKick[index] + 0.5, voice.pitched { struck = true }
            lastKick[index] = voice.kick
        }
        vigour += (min(1, loudness) - vigour) * eased(0.5)
        if struck { vigour = min(1.3, vigour + 0.25) }

        ringPlate(frame)
        // The sand moves in small steps of the same length, however often the picture is painted.
        var left = frame.elapsed
        while left > 0.0001 {
            let step = min(left, 1.0 / 60)
            moveSand(step)
            left -= step
        }
        paintPlate(frame)
    }

    /// How the plate shakes at each place of the grid: the pattern of the loudest voice and half as much
    /// of the next's, added together and brought to a size from -1 to 1, for the figure the plate holds;
    /// passed to over a second or two when it takes up a new one.
    private func ringPlate(_ frame: VisualFrame) {
        var loudest = (-1, -1)
        for index in 0 ..< frame.voices.count where frame.voices[index].pitched && calm[index] > 0.02 {
            if loudest.0 < 0 || calm[index] > calm[loudest.0] {
                loudest = (index, loudest.0)
            } else if loudest.1 < 0 || calm[index] > calm[loudest.1] {
                loudest.1 = index
            }
        }
        func pattern(of index: Int) -> Int {
            guard index >= 0 else { return -1 }
            let place = frame.place(of: frame.voices[index].pitch)
            return min(Self.patterns.count - 1, Int(place * Float(Self.patterns.count - 1) + 0.5))
        }
        // (Nothing heard asks for nothing: the plate keeps the figure it has.)
        var now = (pattern(of: loudest.0), pattern(of: loudest.1))
        if now.1 == now.0 { now.1 = -1 }
        guard now.0 >= 0 else { return passToFigure(frame) }
        if now == held {
            otherSince = nil
        } else if otherSince == nil {
            otherSince = frame.time
        }
        if let since = otherSince, held.0 < 0 || (frame.time - heldSince >= Self.lasting && frame.time - since >= Self.asking) {
            held = now
            heldSince = frame.time
            otherSince = nil
            shape(held)
        }
        passToFigure(frame)
    }

    /// How the plate shakes passes to how the figure it holds would have it, most of the way in a second
    /// and a half.
    private func passToFigure(_ frame: VisualFrame) {
        let passing = 1 - expf(-frame.elapsed / 0.6)
        for index in shaking.indices { shaking[index] += (wanted[index] - shaking[index]) * passing }
    }

    /// Works out how the plate shakes for a figure.
    private func shape(_ figure: (Int, Int)) {
        let side = Self.grid
        for index in wanted.indices { wanted[index] = 0 }
        var acrossM = [Float](repeating: 0, count: side), acrossN = acrossM
        for (which, strength) in [(figure.0, Float(1)), (figure.1, Float(0.5))] where which >= 0 {
            let pattern = Self.patterns[which]
            for column in 0 ..< side {
                let x = Float(column) / Float(side - 1)
                acrossM[column] = cosf(pattern.m * .pi * x)
                acrossN[column] = cosf(pattern.n * .pi * x)
            }
            for row in 0 ..< side {
                let downM = acrossM[row], downN = acrossN[row]
                for column in 0 ..< side {
                    wanted[row * side + column] += strength * (acrossM[column] * downN + pattern.sign * acrossN[column] * downM)
                }
            }
        }
        let scale: Float = 1 / (2 * (figure.1 >= 0 ? 1.5 : 1))
        for index in wanted.indices { wanted[index] *= scale }
    }

    /// How the plate shakes at a place, and which way it shakes less, from the grid: x and y from 0 to 1.
    private func shake(_ x: Float, _ y: Float) -> (amount: Float, slopeX: Float, slopeY: Float) {
        let side = Self.grid, last = Float(side - 1)
        let gx = max(0, min(last - 0.001, x * last)), gy = max(0, min(last - 0.001, y * last))
        let column = Int(gx), row = Int(gy), right = gx - Float(column), down = gy - Float(row)
        let at = row * side + column
        let a = shaking[at], b = shaking[at + 1], c = shaking[at + side], d = shaking[at + side + 1]
        let amount = a + (b - a) * right + (c - a) * down + (a - b - c + d) * right * down
        let slopeX = ((b - a) + (a - b - c + d) * down) * last, slopeY = ((c - a) + (a - b - c + d) * right) * last
        return (amount, slopeX, slopeY)
    }

    /// Each grain is thrown about by as much as the plate shakes where it lies, and slides a little
    /// towards where it shakes less: so it comes to rest on a still line.
    private func moveSand(_ step: Float) {
        guard vigour > 0.01 else { return }
        let throwing = 0.3 * vigour * step.squareRoot(), sliding = 0.03 * vigour * step * 60
        for index in 0 ..< Self.grains {
            let x = grainX[index], y = grainY[index]
            let here = shake(x, y)
            // (Never quite nothing: a plate that rings is never quite still anywhere, and the lines of
            // sand have a soft edge and a few strays.)
            let shakes = abs(here.amount) + 0.03
            // Down the slope of how hard it shakes: towards the line where it is still.
            let sign: Float = here.amount > 0 ? 1 : -1
            var newX = x - sign * here.slopeX * sliding * 0.02 + (next() - 0.5) * throwing * shakes
            var newY = y - sign * here.slopeY * sliding * 0.02 + (next() - 0.5) * throwing * shakes
            // The plate's edge: sand that would fall off bounces back on.
            if newX < 0 { newX = -newX }
            if newX > 1 { newX = 2 - newX }
            if newY < 0 { newY = -newY }
            if newY > 1 { newY = 2 - newY }
            grainX[index] = max(0, min(1, newX))
            grainY[index] = max(0, min(1, newY))
        }
    }

    /// The plate, dark and a little lighter towards its middle, and the sand on it.
    private func paintPlate(_ frame: VisualFrame) {
        for index in light.indices { light[index] = 0 }
        let w = Float(width - 1), h = Float(height - 1)
        for index in 0 ..< Self.grains {
            let column = Int(grainX[index] * w + 0.5), row = Int(grainY[index] * h + 0.5)
            light[row * width + column] += 1
        }
        let metal = VisualLook.rgb(hue: frame.look.hue + 0.5, saturation: 0.35, value: 1)
        let sand = VisualLook.rgb(hue: frame.look.hue, saturation: 0.3, value: 1)
        var pixel = frame.pixels
        for row in 0 ..< height {
            let y = Float(row) / h - 0.5
            for column in 0 ..< width {
                let x = Float(column) / w - 0.5
                let sheen = 0.07 - 0.05 * (x * x + y * y) * 2
                // A dot with a grain or two on it is pale; more grains are no paler than a heap is.
                let grains = light[row * width + column]
                let heap = 1 - expf(-grains * 0.7)
                pixel[0] = UInt8(max(0, min(255, (metal.0 * sheen * (1 - heap) + sand.0 * heap * 0.95) * 255)))
                pixel[1] = UInt8(max(0, min(255, (metal.1 * sheen * (1 - heap) + sand.1 * heap * 0.95) * 255)))
                pixel[2] = UInt8(max(0, min(255, (metal.2 * sheen * (1 - heap) + sand.2 * heap * 0.95) * 255)))
                pixel[3] = 255
                pixel += 4
            }
        }
    }

    /// A number from 0 up to 1, by a sequence that is the same each time (xorshift).
    private func next() -> Float {
        random ^= random << 13
        random ^= random >> 17
        random ^= random << 5
        return Float(random >> 8) / Float(1 << 24)
    }
}
