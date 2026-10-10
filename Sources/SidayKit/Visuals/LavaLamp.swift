// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A lava lamp. Each voice is a blob of wax in a lit liquid: it swells as the voice gets louder,
/// floats higher the higher its note, and sinks back to the pool at the bottom when the voice falls
/// silent. Blobs that meet run into one another, as wax does.
///
/// The wax is where a sum is more than 1: each blob adds its radius squared over the distance to it
/// squared. The sum is worked out on a grid, one place in four each way, and read off between them,
/// which for something so smooth is as good as working it out at every dot.
final class LavaLamp: VisualScene {
    /// Red and orange wax, to begin with.
    let look = VisualLook(hue: 0.03, spread: 0.1)
    /// And then every colour in turn, wax and liquid together: once round the wheel in five minutes,
    /// which is too slow to see moving.
    let drift: Float = 1.0 / 300

    private struct Blob {
        /// Where it is, across from 0 to 1 and up from 0 to 1, and how big, as a part of the height.
        var x: Float = 0.5, y: Float = 0.05, radius: Float = 0.02
        /// Its own time, so that no two wander alike.
        var phase: Float = 0, pace: Float = 0
    }

    private var blobs: [Blob] = []
    /// At each place on the grid: the sum, and the wax's red, green and blue weighted by who it is nearest.
    private var grid: [Float] = []
    private static let step = 4

    private func settle(for count: Int) {
        guard blobs.count != count else { return }
        blobs = (0 ..< count).map { index in
            // Evenly across, and each wandering at a pace of its own.
            let turn = Float(index) * 0.618034
            return Blob(x: (Float(index) + 0.5) / Float(max(1, count)), phase: turn * 6.2832, pace: 0.25 + 0.3 * (turn - turn.rounded(.down)))
        }
    }

    func paint(_ frame: VisualFrame) {
        let count = frame.voices.count
        settle(for: count)
        let width = frame.width, height = frame.height
        let shape = Float(width) / Float(height)
        // Many voices make for smaller blobs.
        let scale = max(0.5, min(1.15, (5 / Float(max(1, count))).squareRoot()))
        func eased(_ seconds: Float) -> Float { 1 - expf(-frame.elapsed / seconds) }

        var colours = [(Float, Float, Float)](repeating: (0, 0, 0), count: count)
        for index in 0 ..< count {
            let voice = frame.voices[index]
            let sounding = voice.level > 0.04
            // Up to where its note is, if it has one; a voice of noise hangs low; a silent one sinks.
            let wanted: Float = sounding ? (voice.pitched ? 0.2 + 0.66 * frame.height(of: voice.pitch) : 0.22) : 0.06
            blobs[index].y += (wanted - blobs[index].y) * eased(wanted > blobs[index].y ? 1.1 : 2.4)
            let home = (Float(index) + 0.5) / Float(count)
            let wander = 0.5 / Float(count) + 0.03
            blobs[index].x = home + wander * sinf(frame.time * blobs[index].pace + blobs[index].phase)
            let size = (0.04 + 0.1 * voice.level + 0.02 * voice.kick) * scale
            blobs[index].radius += (size - blobs[index].radius) * eased(0.12)
            // Wax glows as it is heated: a quiet voice's is dull.
            colours[index] = frame.look.colour(of: index, among: count, saturation: 0.88, value: 0.5 + 0.5 * voice.level)
        }
        let pool = frame.look.colour(of: 0, among: 1, saturation: 0.9, value: 0.5)
        // The liquid is lit from below, in a colour across the wheel from the wax.
        let liquid = VisualLook.rgb(hue: frame.look.hue + 0.58, saturation: 0.7, value: 1)

        // The grid.
        let step = Self.step
        let across = width / step + 2, down = height / step + 2
        if grid.count != across * down * 4 { grid = [Float](repeating: 0, count: across * down * 4) }
        let bob = frame.time * 0.8
        for row in 0 ..< down {
            let y = 1 - Float(row * step) / Float(height)
            for column in 0 ..< across {
                let x = Float(column * step) / Float(width)
                // The pool: wax lying along the bottom, a little uneven.
                let depth = y + 0.02 - 0.012 * sinf(x * 9 + bob * 0.4)
                var sum = 0.006 / (depth * depth + 0.0001)
                var weight = sum * sum
                var red = pool.0 * weight, green = pool.1 * weight, blue = pool.2 * weight
                for index in 0 ..< count {
                    let dx = (x - blobs[index].x) * shape
                    let dy = y - blobs[index].y - 0.012 * sinf(bob + blobs[index].phase)
                    let share = blobs[index].radius * blobs[index].radius / (dx * dx + dy * dy + 0.00002)
                    sum += share
                    let pull = share * share
                    weight += pull
                    red += colours[index].0 * pull
                    green += colours[index].1 * pull
                    blue += colours[index].2 * pull
                }
                let at = (row * across + column) * 4
                grid[at] = sum
                grid[at + 1] = red / weight
                grid[at + 2] = green / weight
                grid[at + 3] = blue / weight
            }
        }

        // The dots, each read off the four places of the grid around it.
        var pixel = frame.pixels
        let part = 1 / Float(step)
        for row in 0 ..< height {
            let gridRow = row / step
            let v = Float(row % step) * part
            let fromBottom = 1 - Float(row) / Float(height)
            let lit = 0.045 + 0.17 * (1 - fromBottom) * (1 - fromBottom)
            for column in 0 ..< width {
                let gridColumn = column / step
                let u = Float(column % step) * part
                let a = (gridRow * across + gridColumn) * 4, b = a + 4, c = a + across * 4, d = c + 4
                let wa = (1 - u) * (1 - v), wb = u * (1 - v), wc = (1 - u) * v, wd = u * v
                let sum = grid[a] * wa + grid[b] * wb + grid[c] * wc + grid[d] * wd
                let red = grid[a + 1] * wa + grid[b + 1] * wb + grid[c + 1] * wc + grid[d + 1] * wd
                let green = grid[a + 2] * wa + grid[b + 2] * wb + grid[c + 2] * wc + grid[d + 2] * wd
                let blue = grid[a + 3] * wa + grid[b + 3] * wb + grid[c + 3] * wc + grid[d + 3] * wd

                // Wax where the sum passes 1, its edge a little soft; brighter towards its middle;
                // and round it, a glow in the liquid.
                var wax = max(0, min(1, (sum - 0.9) * 5))
                wax = wax * wax * (3 - 2 * wax)
                let core = 0.74 + 0.26 * max(0, min(1, (sum - 1) * 0.5))
                var glow = max(0, min(1, (sum - 0.3) * 1.43))
                glow = glow * glow * 0.3 * (1 - wax)
                let body = wax * core + glow
                let r = liquid.0 * lit * (1 - wax) + red * body
                let g = liquid.1 * lit * (1 - wax) + green * body
                let b2 = liquid.2 * lit * (1 - wax) + blue * body
                pixel[0] = UInt8(max(0, min(255, r * 255)))
                pixel[1] = UInt8(max(0, min(255, g * 255)))
                pixel[2] = UInt8(max(0, min(255, b2 * 255)))
                pixel[3] = 255
                pixel += 4
            }
        }
    }
}
