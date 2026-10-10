// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A fire in a dark hearth. Each voice is a flame standing on a bed of embers, each in its own
/// place along the hearth, and it burns taller and hotter the louder the voice; its note leans it a
/// little, to the left for a low one and the right for a high one, so that a tune sways its flame.
/// Each burns in a colour of its own, and where flames meet their colours add, towards white heat.
/// A voice with no pitch, a drum or a hiss, throws sparks.
///
/// It is the oldest trick there is for a fire, and the one this kind of picture began with: the
/// heat at each place is the mean of the heat just below it, less a little. So heat put in along
/// the bottom rises, spreads and dies away, and all that has to be decided is what to put in. Here
/// the heat is kept as red, green and blue, so that a flame can be a colour, and a slow draught
/// leans the flames a little this way and that. It is moved on so many times a second whatever the
/// screen's rate, on a grid half as fine as the picture.
final class Flame: VisualScene {
    /// The reds and yellows of a fire, to begin with.
    let look = VisualLook(hue: 0.045, spread: 0.11)
    /// And then every colour a flame can be made to burn, once round the wheel in six minutes.
    let drift: Float = 1.0 / 360

    /// How many times a second the fire is moved on: a flame's heat rises a place each time.
    private static let pace: Float = 42
    /// What is left of the heat each time it rises a place, at most and at least: it is somewhere
    /// between the two by chance, which is what gives a flame its ragged edge and its tip.
    private static let cooling: Float = 0.975, coolingAtMost: Float = 0.1

    private var across = 0, down = 0
    /// The heat at each place on the grid, as red, green and blue, in rows from the top.
    private var heat: [Float] = []
    /// The draught at each row and each column: together they say which way a place leans for its heat.
    private var rowDraught: [Float] = [], columnDraught: [Float] = []
    /// How much each column of the embers is glowing, which wanders.
    private var embers: [Float] = []
    private var owed: Float = 0
    private var kicks: [Float] = []
    /// Where each voice's flame stands, across the hearth from 0 to 1, and how loud the voice is:
    /// both followed slowly, since a flame neither jumps about nor comes and goes with every note.
    private var places: [Float] = [], calm: [Float] = []
    private var seed: UInt32 = 0x0F1A_3E55

    private func chance() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24)
    }

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        if across != width / 2 || down != height / 2 {
            across = width / 2
            down = height / 2
            heat = [Float](repeating: 0, count: across * down * 3)
            rowDraught = [Float](repeating: 0, count: down)
            columnDraught = [Float](repeating: 0, count: across)
            embers = [Float](repeating: 0.5, count: across)
            owed = 0
        }
        guard across > 8, down > 8 else { return }
        let count = frame.voices.count
        if kicks.count != count {
            kicks = [Float](repeating: 0, count: count)
            places = (0 ..< count).map { (Float($0) + 0.5) / Float(count) }
            calm = [Float](repeating: 0, count: count)
        }
        // Many voices make for narrower flames.
        let room = 1 / Float(max(1, count))

        // What each voice puts into the fire: where, how wide, how hot and in what colour.
        var where_ = [Float](repeating: 0, count: count), wide = where_, hot = where_
        var colours = [(Float, Float, Float)](repeating: (0, 0, 0), count: count)
        var sparks: [(Float, Float, Float, Float)] = []
        for index in 0 ..< count {
            let voice = frame.voices[index]
            colours[index] = frame.look.colour(of: index, among: count, saturation: 0.9)
            if voice.pitched {
                let wanted = (Float(index) + 0.5) * room + (frame.height(of: voice.pitch) - 0.5) * room * 0.8
                places[index] += (wanted - places[index]) * (1 - expf(-frame.elapsed / 0.6))
                calm[index] += (voice.level - calm[index]) * (1 - expf(-frame.elapsed / (voice.level > calm[index] ? 0.2 : 1.6)))
                where_[index] = places[index] * Float(across)
                wide[index] = (max(0.007, min(0.02, room * 0.09)) + 0.008 * calm[index]) * Float(across)
                hot[index] = calm[index] * (1.2 + 2 * calm[index]) * (1 + 0.2 * voice.kick)
            } else if voice.kick > kicks[index] + 0.3, voice.heardLevel > 0.05 {
                // A note struck with no pitch: a few sparks, from anywhere along the hearth.
                for _ in 0 ..< 3 {
                    sparks.append((chance(), colours[index].0 * 0.5 + 0.5, colours[index].1 * 0.5 + 0.4, colours[index].2 * 0.5 + 0.25))
                }
            }
            kicks[index] = voice.kick
        }
        let bed = VisualLook.rgb(hue: frame.look.hue, saturation: 0.95, value: 1)

        owed += frame.elapsed * Self.pace
        let moves = min(5, Int(owed))
        owed -= Float(moves)
        let step = 1 / Self.pace
        var time = frame.time - Float(moves) * step
        let rowLength = across * 3
        for move in 0 ..< moves {
            time += step
            // The draught: slow waves up the chimney and along the hearth.
            for row in 0 ..< down { rowDraught[row] = 0.6 * sinf(Float(row) * 0.09 - time * 1.7) + 0.4 * sinf(Float(row) * 0.23 + time * 0.9) }
            for column in 0 ..< across { columnDraught[column] = 0.5 * sinf(Float(column) * 0.05 + time * 0.6) }
            var dice = seed

            heat.withUnsafeMutableBufferPointer { heat in
                guard let heat = heat.baseAddress else { return }
                // Each place takes the mean of the three below it and the one below that, leaning
                // with the draught, and loses a little. From the top down, so that what is read
                // is always what was there before this move.
                for row in 0 ..< down - 2 {
                    let here = heat + row * rowLength, below = here + rowLength, under = below + rowLength
                    for column in 0 ..< across {
                        let lean = Int((rowDraught[row] + columnDraught[column]).rounded())
                        let middle = max(1, min(across - 2, column + lean)) * 3
                        let at = column * 3
                        dice = dice &* 1_664_525 &+ 1_013_904_223
                        let kept = 0.25 * (Self.cooling - Self.coolingAtMost * Float(dice >> 8) * (1 / 16_777_216))
                        for part in 0 ..< 3 {
                            here[at + part] = (below[middle - 3 + part] + below[middle + part] + below[middle + 3 + part] + under[middle + part]) * kept
                        }
                    }
                }

                // The bottom two rows are the fire itself: the embers, glowing unevenly along the
                // hearth, and each voice's flame.
                for column in 0 ..< across {
                    embers[column] += (chance() - 0.5) * 0.16
                    embers[column] = max(0.25, min(1, embers[column]))
                    let glow = 0.11 * embers[column]
                    // A flame is fed unevenly, a different amount at each place each time, and it is
                    // out of that unevenness that its tongues come.
                    let fed = 0.25 + 0.75 * chance()
                    var red = bed.0 * glow, green = bed.1 * glow, blue = bed.2 * glow
                    for index in 0 ..< count where hot[index] > 0.01 {
                        let away = (Float(column) - where_[index]) / wide[index]
                        guard abs(away) < 3 else { continue }
                        let share = hot[index] * expf(-0.5 * away * away) * fed
                        red += colours[index].0 * share
                        green += colours[index].1 * share
                        blue += colours[index].2 * share
                    }
                    for row in down - 2 ..< down {
                        let at = heat + row * rowLength + column * 3
                        at[0] = red
                        at[1] = green
                        at[2] = blue
                    }
                }
                seed = dice
                // Sparks start a little above the embers, on the first move of a frame.
                if move == 0 {
                    for spark in sparks {
                        let column = max(1, min(across - 2, Int(spark.0 * Float(across))))
                        let at = heat + (down - 4) * rowLength + column * 3
                        at[0] += spark.1 * 5
                        at[1] += spark.2 * 5
                        at[2] += spark.3 * 5
                    }
                }
            }
        }

        // The dots, each read off the four places of the grid around it, and the heat squeezed into
        // what a screen can show: the hotter, the nearer white.
        var pixel = frame.pixels
        let scaleX = Float(across - 1) / Float(width), scaleY = Float(down - 2) / Float(height)
        for row in 0 ..< height {
            let gy = Float(row) * scaleY
            let gridRow = min(down - 3, Int(gy)), v = gy - Float(gridRow)
            let low = Float(row) / Float(height)
            let hearth = 0.012 + 0.02 * low * low
            for column in 0 ..< width {
                let gx = Float(column) * scaleX
                let gridColumn = min(across - 2, Int(gx)), u = gx - Float(gridColumn)
                let a = (gridRow * across + gridColumn) * 3, b = a + 3, c = a + rowLength, d = c + 3
                let wa = (1 - u) * (1 - v), wb = u * (1 - v), wc = (1 - u) * v, wd = u * v
                let red = heat[a] * wa + heat[b] * wb + heat[c] * wc + heat[d] * wd
                let green = heat[a + 1] * wa + heat[b + 1] * wb + heat[c + 1] * wc + heat[d + 1] * wd
                let blue = heat[a + 2] * wa + heat[b + 2] * wb + heat[c + 2] * wc + heat[d + 2] * wd
                // (A little of each colour's heat shows in the others, as it does in a real flame's middle.)
                let all = (red + green + blue) * 0.12
                pixel[0] = UInt8(max(0, min(255, (1 - expf(-(red + all + hearth * 1.4) * 2.2)) * 255)))
                pixel[1] = UInt8(max(0, min(255, (1 - expf(-(green + all + hearth * 0.8) * 2.2)) * 255)))
                pixel[2] = UInt8(max(0, min(255, (1 - expf(-(blue + all + hearth * 0.7) * 2.2)) * 255)))
                pixel[3] = 255
                pixel += 4
            }
        }
    }
}
