// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A row of lamps on fire. Each voice is a round lamp, the voices in a row from side to side a
/// little above the bottom of the picture (the less above it the smaller they are, which is the
/// more of them there are), as the lights of the player are; a lamp is as large as its
/// voice is loud, and its colour is its note, by the colours of the analyser's bars: red for the
/// lowest the tune plays, through yellow, green and blue to violet for the highest (with the ends
/// of the tune's range drawn in: see `VisualFrame.place`). A voice with no pitch, a drum or
/// a hiss, is a pale lamp. And each lamp burns: a flame rises from it in its colour, slowly and all
/// the way up the picture, so that the notes a voice has played are still to be seen above the one
/// it is playing, the latest lowest.
///
/// The flames are the oldest trick there is for a fire, and the one this kind of picture began
/// with: the heat at each place is the mean of the heat just below it, less a little. So heat put
/// in rises, spreads and dies away, and all that has to be decided is what to put in. Here the heat
/// is kept as red, green and blue, so that a flame can be a colour, and what is put in is the lamps:
/// every place inside one is made as hot as the lamp, unevenly, a different amount in each column
/// each time, and it is out of that unevenness that the tongues of a flame come.
///
/// A lamp follows its voice as closely as the player's lights do, in its size and at once in its
/// colour. It is the fire above it, which only rises a place at a time and spreads as it goes, that
/// keeps the picture from jumping: a change of note is a band of another colour going up the flame.
/// The lamps themselves are drawn over the fire afterwards, whole and steady, at the picture's own
/// fineness. The fire is moved on so many times a second whatever the screen's rate, on a grid half
/// as fine as the picture.
final class Flame: VisualScene {
    /// The colours of the analyser's bars, to begin with: from red round to violet, which is most of
    /// the wheel, from the lowest note to the highest. Other colours are other stretches of the wheel.
    let look = VisualLook(hue: 145.0 / 360, spread: 290.0 / 360)
    /// A note keeps its colour until other colours are asked for.
    let drift: Float = 0

    /// The colour of a lamp playing a note that lies so far from the lowest the tune plays to the
    /// highest, from 0 to 1, or of one playing something with no pitch if there is no such place.
    private static func colour(of place: Float?, in look: VisualLook) -> (Float, Float, Float) {
        guard let place else { return VisualLook.rgb(hue: look.hue, saturation: 0.1, value: 0.7) }
        // (As strong and as bright as the bars are.)
        return VisualLook.rgb(hue: look.hue + look.spread * (place - 0.5), saturation: 0.815, value: 0.98)
    }

    /// How long heat takes to rise the height of the picture, in seconds: a flame's heat rises a
    /// place each time the fire is moved on, so this is how often that is.
    private static let climb: Float = 4
    /// How far a lamp's heat has cooled where its flame reaches the top of the picture: to this
    /// power of e below what it was, which is a third of it, and so a flame does not end but goes
    /// out of sight. What is lost at each place on the way is somewhere between nothing and twice
    /// its share of that, by chance, which is what gives a flame its ragged edge.
    private static let cooling: Float = 1.2
    /// How hot a lamp is.
    private static let glow: Float = 1.3

    /// What heat is multiplied by to squeeze it into what a screen can show, given the most there
    /// is of any colour at a place. All three colours are squeezed alike, and so stay the colour
    /// they were: squeezed each by itself, every colour would be paler the hotter it was.
    private static func shown(most heat: Float) -> Float { heat > 0.0001 ? (1 - expf(-heat * 2.2)) / heat : 2.2 }

    private var across = 0, down = 0
    /// The heat at each place on the grid, as red, green and blue, in rows from the top. The last
    /// two rows are never hot: they are what is below the bottom of the picture.
    private var heat: [Float] = []
    /// How much of a lamp's heat each column is given this time.
    private var fed: [Float] = []
    private var owed: Float = 0
    /// How loud each voice is, followed nearly as quickly as the player's lights follow it, and
    /// what was last heard of it.
    private var loud: [Float] = [], heard: [Float] = []
    /// The note each voice last played, or 0 if what it is playing now has no pitch.
    private var notes: [Float] = []
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
            fed = [Float](repeating: 1, count: across)
            owed = 0
        }
        guard across > 8, down > 8 else { return }
        let count = frame.voices.count
        if loud.count != count {
            loud = [Float](repeating: 0, count: count)
            heard = loud
            notes = [Float](repeating: 60, count: count)
        }
        // The lamps stand evenly along a row, and the more of them there are the smaller they are.
        let room = Float(across) / Float(max(1, count))
        let largest = min(room * 0.38, Float(down) * 0.12)
        // They stand above the bottom of the picture by a part of their own size, so that small
        // lamps are nearer to it than large ones, and are not left high over an empty floor. (The
        // last two rows of the grid are below the bottom of the picture.)
        let floor = Float(down - 2) - largest * 1.6

        // How large each voice's lamp is, on the grid, and its colour.
        var radius = [Float](repeating: 0, count: count)
        var colours = [(Float, Float, Float)](repeating: (0, 0, 0), count: count)
        for index in 0 ..< count {
            let voice = frame.voices[index]
            let level = voice.heardLevel
            // A voice that has stopped is given no pitch while its light is still going out: it
            // is only what sounds without one, holding its level or gaining, that is a pale lamp.
            if voice.heardPitch > 0 {
                notes[index] = voice.heardPitch
            } else if level > 0.05, level >= heard[index] {
                notes[index] = 0
            }
            heard[index] = level
            // A note being struck swells its lamp for a moment. A lamp is a few frames in growing,
            // which to the eye is at once, and not much longer in shrinking.
            let wanted = level * (1 + 0.12 * voice.kick)
            loud[index] += (wanted - loud[index]) * (1 - expf(-frame.elapsed / (wanted > loud[index] ? 0.06 : 0.12)))
            radius[index] = largest * loud[index]
            colours[index] = Self.colour(of: notes[index] > 0 ? frame.place(of: notes[index]) : nil, in: frame.look)
        }

        // The fire rises and cools by the height of the picture and not by the place, so that it
        // is the same fire in a small picture and a large one.
        owed += frame.elapsed * Float(down) / Self.climb
        let moves = min(5, Int(owed))
        owed -= Float(moves)
        if owed > 1 { owed = 1 }
        let lost = 2 * (1 - expf(-Self.cooling / (0.8 * Float(down))))
        let rowLength = across * 3
        for _ in 0 ..< moves {
            var dice = seed
            heat.withUnsafeMutableBufferPointer { heat in
                guard let heat = heat.baseAddress else { return }
                // Each place takes the mean of the three below it and the one below that, and loses
                // a little. From the top down, so that what is read is always what was there before
                // this move.
                for row in 0 ..< down - 2 {
                    let here = heat + row * rowLength, below = here + rowLength, under = below + rowLength
                    for column in 0 ..< across {
                        let middle = max(1, min(across - 2, column)) * 3
                        let at = column * 3
                        dice = dice &* 1_664_525 &+ 1_013_904_223
                        let kept = 0.25 * (1 - lost * Float(dice >> 8) * (1 / 16_777_216))
                        for part in 0 ..< 3 {
                            here[at + part] = (below[middle - 3 + part] + below[middle + part] + below[middle + 3 + part] + under[middle + part]) * kept
                        }
                    }
                }
                seed = dice

                // The lamps: every place inside one is made as hot as the lamp is, less whatever
                // its column is short of this time. (At a lamp's edge, in part.)
                for column in 0 ..< across { fed[column] = 0.25 + 0.75 * chance() }
                for index in 0 ..< count where radius[index] > 0.4 {
                    let middle = (Float(index) + 0.5) * room, reach = radius[index]
                    let top = max(0, Int(floor - reach - 1)), bottom = min(down - 3, Int(floor + reach + 1))
                    let first = max(1, Int(middle - reach - 1)), last = min(across - 2, Int(middle + reach + 1))
                    guard top <= bottom, first <= last else { continue }
                    for row in top ... bottom {
                        let fall = Float(row) - floor
                        for column in first ... last {
                            let aside = Float(column) - middle
                            let inside = min(1, reach - (aside * aside + fall * fall).squareRoot() + 0.5)
                            guard inside > 0 else { continue }
                            let wanted = Self.glow * fed[column]
                            let at = heat + row * rowLength + column * 3
                            at[0] += (colours[index].0 * wanted - at[0]) * inside
                            at[1] += (colours[index].1 * wanted - at[1]) * inside
                            at[2] += (colours[index].2 * wanted - at[2]) * inside
                        }
                    }
                }
            }
        }

        // The dots, each read off the four places of the grid around it. The fire is shown as far
        // on its way up to its next place as it is owed, so that it rises smoothly however seldom
        // it is moved on.
        var pixel = frame.pixels
        let scaleX = Float(across - 1) / Float(width), scaleY = Float(down - 2) / Float(height)
        for row in 0 ..< height {
            let gy = Float(row) * scaleY + owed
            let gridRow = min(down - 3, Int(gy)), v = min(1, gy - Float(gridRow))
            let low = Float(row) / Float(height)
            let dark = 0.012 + 0.02 * low * low
            for column in 0 ..< width {
                let gx = Float(column) * scaleX
                let gridColumn = min(across - 2, Int(gx)), u = gx - Float(gridColumn)
                let a = (gridRow * across + gridColumn) * 3, b = a + 3, c = a + rowLength, d = c + 3
                let wa = (1 - u) * (1 - v), wb = u * (1 - v), wc = (1 - u) * v, wd = u * v
                let red = heat[a] * wa + heat[b] * wb + heat[c] * wc + heat[d] * wd
                let green = heat[a + 1] * wa + heat[b + 1] * wb + heat[c + 1] * wc + heat[d + 1] * wd
                let blue = heat[a + 2] * wa + heat[b + 2] * wb + heat[c + 2] * wc + heat[d + 2] * wd
                let squeezed = Self.shown(most: max(red, green, blue)) * 255
                pixel[0] = UInt8(max(0, min(255, red * squeezed + dark * 780)))
                pixel[1] = UInt8(max(0, min(255, green * squeezed + dark * 450)))
                pixel[2] = UInt8(max(0, min(255, blue * squeezed + dark * 390)))
                pixel[3] = 255
                pixel += 4
            }
        }

        // And the lamps over the fire, each in its colour, and a little less bright towards its
        // edge, as a round lamp is.
        for index in 0 ..< count where radius[index] > 0.4 {
            let middle = (Float(index) + 0.5) * room / scaleX, level = floor / scaleY, reach = radius[index] / scaleX
            let colour = colours[index]
            let lit = (colour.0 * 255, colour.1 * 255, colour.2 * 255)
            let top = max(0, Int(level - reach - 1)), bottom = min(height - 1, Int(level + reach + 1))
            let first = max(0, Int(middle - reach - 1)), last = min(width - 1, Int(middle + reach + 1))
            guard top <= bottom, first <= last else { continue }
            for row in top ... bottom {
                let fall = Float(row) - level
                for column in first ... last {
                    let aside = Float(column) - middle
                    let away = (aside * aside + fall * fall).squareRoot()
                    let cover = min(1, reach - away + 0.5)
                    guard cover > 0 else { continue }
                    let shade = 1 - 0.22 * min(1, away * away / (reach * reach))
                    let at = frame.pixels + (row * width + column) * 4
                    at[0] = UInt8(max(0, min(255, Float(at[0]) + (lit.0 * shade - Float(at[0])) * cover)))
                    at[1] = UInt8(max(0, min(255, Float(at[1]) + (lit.1 * shade - Float(at[1])) * cover)))
                    at[2] = UInt8(max(0, min(255, Float(at[2]) + (lit.2 * shade - Float(at[2])) * cover)))
                }
            }
        }
    }
}
