// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

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
    private var grid: [SIMD4<Float>] = []
    /// A row of dots' places on the grid, between the grid's rows on either side of it.
    private var blended: [SIMD4<Float>] = []
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
        if grid.count != across * down { grid = [SIMD4<Float>](repeating: .zero, count: across * down) }
        let bob = frame.time * 0.8
        // (What changes only from blob to blob, from row to row or from column to column, is worked out
        // once for each.)
        let squared = blobs.map { $0.radius * $0.radius }
        let lifted = blobs.map { $0.y + 0.012 * sinf(bob + $0.phase) }
        let uneven = (0 ..< across).map { column in 0.012 * sinf(Float(column * step) / Float(width) * 9 + bob * 0.4) }
        var rises = [Float](repeating: 0, count: count)
        grid.withUnsafeMutableBufferPointer { grid in
            for row in 0 ..< down {
                let y = 1 - Float(row * step) / Float(height)
                for index in 0 ..< count {
                    let dy = y - lifted[index]
                    rises[index] = dy * dy + 0.00002
                }
                for column in 0 ..< across {
                    let x = Float(column * step) / Float(width)
                    // The pool: wax lying along the bottom, a little uneven.
                    let depth = y + 0.02 - uneven[column]
                    var sum = 0.006 / (depth * depth + 0.0001)
                    var weight = sum * sum
                    var red = pool.0 * weight, green = pool.1 * weight, blue = pool.2 * weight
                    var index = 0
                    while index < count {
                        let dx = (x - blobs[index].x) * shape
                        let share = squared[index] / (dx * dx + rises[index])
                        sum += share
                        let pull = share * share
                        weight += pull
                        red += colours[index].0 * pull
                        green += colours[index].1 * pull
                        blue += colours[index].2 * pull
                        index += 1
                    }
                    grid[row * across + column] = SIMD4(sum, red / weight, green / weight, blue / weight)
                }
            }
        }

        // The dots, each read off the four places of the grid around it: the grid's two rows on either
        // side of a row of dots blended once for the row, and then read off across it.
        var pixel = frame.pixels
        let part = 1 / Float(step)
        if blended.count != across { blended = [SIMD4<Float>](repeating: .zero, count: across) }
        grid.withUnsafeBufferPointer { grid in
            blended.withUnsafeMutableBufferPointer { blended in
                for row in 0 ..< height {
                    let gridRow = row / step
                    let v = Float(row % step) * part
                    let above = gridRow * across, below = above + across
                    for column in 0 ..< across {
                        blended[column] = grid[above + column] + (grid[below + column] - grid[above + column]) * v
                    }
                    let fromBottom = 1 - Float(row) / Float(height)
                    let lit = 0.045 + 0.17 * (1 - fromBottom) * (1 - fromBottom)
                    // Where the sum is too small for wax or its glow, there is only the lit liquid.
                    let bare = (byte(liquid.0 * lit * 255), byte(liquid.1 * lit * 255),
                                byte(liquid.2 * lit * 255))
                    var gridColumn = 0, column = 0
                    while column < width {
                        let left = blended[gridColumn], right = blended[gridColumn + 1]
                        if left.x <= 0.3, right.x <= 0.3 {
                            for _ in 0 ..< min(step, width - column) {
                                pixel[0] = bare.0
                                pixel[1] = bare.1
                                pixel[2] = bare.2
                                pixel[3] = 255
                                pixel += 4
                            }
                        } else {
                            let change = (right - left) * part
                            var here = left
                            for _ in 0 ..< min(step, width - column) {
                                let sum = here.x
                                // Wax where the sum passes 1, its edge a little soft; brighter towards its
                                // middle; and round it, a glow in the liquid.
                                var wax = max(0, min(1, (sum - 0.9) * 5))
                                wax = wax * wax * (3 - 2 * wax)
                                let core = 0.74 + 0.26 * max(0, min(1, (sum - 1) * 0.5))
                                var glow = max(0, min(1, (sum - 0.3) * 1.43))
                                glow = glow * glow * 0.3 * (1 - wax)
                                let body = wax * core + glow
                                let r = liquid.0 * lit * (1 - wax) + here.y * body
                                let g = liquid.1 * lit * (1 - wax) + here.z * body
                                let b = liquid.2 * lit * (1 - wax) + here.w * body
                                pixel[0] = byte(r * 255)
                                pixel[1] = byte(g * 255)
                                pixel[2] = byte(b * 255)
                                pixel[3] = 255
                                pixel += 4
                                here += change
                            }
                        }
                        gridColumn += 1
                        column += step
                    }
                }
            }
        }
    }
}
