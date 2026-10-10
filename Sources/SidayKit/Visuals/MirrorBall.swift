// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A mirror ball, turning slowly at the top of a dark room and throwing its spots of light across
/// the wall behind it. The spots lie in rows, one for each ring of mirrors on the ball. Each voice
/// has a height on the wall that is its own, the first voice at the top, and lights the rows about
/// it; and the colour of its light is the note it is playing. Where the lights of two voices fall on
/// the same row their colours add, towards white.
///
/// The wall is flat and faces the ball, so a spot is where a line from the ball's middle meets it:
/// spots in the middle of the wall are round and bright and move slowly, and those far out to the
/// sides are long, dim and quick, as they are in a real room.
final class MirrorBall: VisualScene {
    /// A note's colour is its place in the octave, as a place on the colour wheel: the twelve notes
    /// are the wheel once round, and a note is the same colour in every octave. Which note is which
    /// colour is where the wheel starts, which is all of the look that means anything here.
    let look = VisualLook(hue: 0.62, spread: 1)
    /// And that goes round by itself, once in seven minutes.
    let drift: Float = 1.0 / 420

    private static let rings = 10, mirrors = 20
    /// Seconds for the ball to turn once.
    private static let turning: Float = 50
    /// Where the ball hangs, across and down the picture, and how far the wall's rows are thrown.
    private static let across: Float = 0.5, down: Float = 0.17, reach: Float = 0.44

    private var light: [Float] = []
    /// How loud each voice is, followed more slowly than the lamp follows it: a wall of lights that
    /// came on all at once would be a flash.
    private var calm: [Float] = []
    /// The colour each voice's light is, as a place on the wheel: it follows the voice's note round
    /// the wheel, the short way, and takes a moment over it.
    private var hues: [Float] = []

    /// A number from 0 to 1 that is always the same for the same two numbers.
    private static func chance(_ a: Int, _ b: Int) -> Float {
        let value = sinf(Float(a) * 12.9898 + Float(b) * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        if light.count != width * height * 3 { light = [Float](repeating: 0, count: width * height * 3) }
        let count = frame.voices.count
        if calm.count != count {
            calm = [Float](repeating: 0, count: count)
            hues = [Float](repeating: 0, count: count)
        }
        let shape = Float(width) / Float(height)
        let rings = Self.rings

        // The light each ring of mirrors has to throw: a little white always, so that the room is
        // never dark, and each voice's light on the rings about its own height. The voices are
        // spread from near the top of the wall to near the bottom, and each reaches far enough
        // either way to meet its neighbours, so that with few voices the wall is still filled.
        var thrown = [(Float, Float, Float)](repeating: (0.09, 0.09, 0.105), count: rings)
        let highest = Float(rings) - 1.8, lowest: Float = 0.8
        let apart = count > 1 ? (highest - lowest) / Float(count - 1) : 0
        let reaching = max(1.7, apart * 0.8)
        for index in 0 ..< count {
            let voice = frame.voices[index]
            calm[index] += (voice.level - calm[index]) * (1 - expf(-frame.elapsed / (voice.level > calm[index] ? 0.14 : 0.5)))
            if voice.pitched {
                var turn = voice.pitch / 12 - hues[index]
                turn -= turn.rounded()
                hues[index] += turn * (1 - expf(-frame.elapsed / 0.25))
                hues[index] -= hues[index].rounded(.down)
            }
            let level = calm[index]
            guard level > 0.02 else { continue }
            let power = level * level.squareRoot() * (1 + 0.3 * voice.kick)
            // A voice with no pitch, a drum or a hiss, has no colour to speak of: its light is all but white.
            let colour = VisualLook.rgb(hue: frame.look.hue + hues[index], saturation: voice.pitched ? 0.85 : 0.2, value: voice.pitched ? 1 : 0.7)
            let place = count > 1 ? highest - apart * Float(index) : (highest + lowest) / 2
            for ring in 0 ..< rings {
                let away = abs(Float(ring) - place)
                guard away < reaching else { continue }
                let share = (1 - away / reaching) * (1 - away / reaching) * power
                thrown[ring].0 += colour.0 * share
                thrown[ring].1 += colour.1 * share
                thrown[ring].2 += colour.2 * share
            }
        }

        let turn = frame.time * (2 * Float.pi / Self.turning)
        light.withUnsafeMutableBufferPointer { light in
            guard let light = light.baseAddress else { return }
            light.update(repeating: 0, count: width * height * 3)

            // The spots. The rings run from well below the ball's middle, whose light falls low on
            // the wall, to a little above it.
            for ring in 0 ..< rings {
                let tilt = (-62 + 74 * Float(ring) / Float(rings - 1)) * Float.pi / 180
                let level = cosf(tilt), rise = sinf(tilt) / level
                for mirror in 0 ..< Self.mirrors {
                    var angle = turn + (Float(mirror) + (ring & 1 == 0 ? 0 : 0.5)) * 2 * Float.pi / Float(Self.mirrors)
                    angle -= 2 * Float.pi * (angle / (2 * Float.pi)).rounded()
                    // Only the mirrors that face the wall, and not those so far round that their spots
                    // would be off it.
                    guard abs(angle) < 1.36 else { continue }
                    let facing = cosf(angle), aside = sinf(angle) / facing
                    let x = (Self.across + aside * Self.reach / shape) * Float(width)
                    let y = (Self.down - rise / facing * Self.reach) * Float(height)
                    let size = 0.042 * Float(height) / level
                    let wide = min(0.35 * Float(width), size / (facing * facing)), tall = size / facing
                    let bright = 1.25 * facing * facing.squareRoot() * level * (0.7 + 0.3 * Self.chance(ring, mirror))
                    let red = thrown[ring].0 * bright, green = thrown[ring].1 * bright, blue = thrown[ring].2 * bright
                    let top = max(0, Int(y - tall)), bottom = min(height - 1, Int(y + tall))
                    let left = max(0, Int(x - wide)), right = min(width - 1, Int(x + wide))
                    guard top <= bottom, left <= right else { continue }
                    for row in top ... bottom {
                        let dy = (Float(row) - y) / tall
                        for column in left ... right {
                            let dx = (Float(column) - x) / wide
                            let away = dx * dx + dy * dy
                            guard away < 1 else { continue }
                            // Brightest in its middle, and soft at its edge.
                            let share = (1 - away) * (1 - away)
                            let at = light + (row * width + column) * 3
                            at[0] += red * share
                            at[1] += green * share
                            at[2] += blue * share
                        }
                    }
                }
            }

            // The ball itself, in front of the wall, and the thread it hangs by.
            let middleX = Self.across * Float(width), middleY = Self.down * Float(height)
            let radius = 0.1 * Float(height)
            for row in 0 ..< max(0, Int(middleY - radius)) {
                let at = light + (row * width + Int(middleX)) * 3
                at[0] = 0.12
                at[1] = 0.12
                at[2] = 0.13
            }
            let top = max(0, Int(middleY - radius)), bottom = min(height - 1, Int(middleY + radius))
            let left = max(0, Int(middleX - radius)), right = min(width - 1, Int(middleX + radius))
            guard top <= bottom, left <= right else { return }
            for row in top ... bottom {
                let up = (middleY - Float(row)) / radius
                for column in left ... right {
                    let side = (Float(column) - middleX) / radius
                    let within = 1 - side * side - up * up
                    guard within > 0 else { continue }
                    let front = within.squareRoot()
                    // Which mirror this is: the ball has a dozen rings of them, more to a ring at its
                    // middle than towards its top and bottom.
                    // (The side of the ball that is seen goes the other way to the spots on the wall,
                    // which are thrown by the side that is not.)
                    let height = asinf(up), round = atan2f(side, front) + turn
                    let band = (height / Float.pi + 0.5) * 12
                    let bandNumber = Int(band)
                    let inBand = max(6, Int(26 * cosf((Float(bandNumber) + 0.5 - 6) * Float.pi / 12)))
                    var place = round / (2 * Float.pi)
                    place = (place - place.rounded(.down)) * Float(inBand)
                    let mirror = Int(place)
                    let edge = min(band - Float(bandNumber), 1 - (band - Float(bandNumber)), place - Float(mirror), 1 - (place - Float(mirror)))
                    let own = Self.chance(bandNumber, mirror)
                    // Lit from above and to the left; each mirror a little different from the next;
                    // dark in the gaps between them; and now and then one catches the light.
                    let lit = max(0, -0.4 * side + 0.5 * up + 0.75 * front)
                    let gap: Float = edge < 0.1 ? 0.45 : 1
                    let glint = max(0, sinf(own * 6.2832 + frame.time * (0.4 + own)) - 0.93) * 9
                    // And it shows the colours it is throwing, ring for ring.
                    let ring = max(0, min(rings - 1, Int((height * 180 / Float.pi + 62) / 74 * Float(rings - 1) + 0.5)))
                    let silver = (0.05 + 0.4 * lit * (0.55 + 0.45 * own)) * gap + glint * 0.5
                    let tint = 0.55 * (0.35 + 0.65 * own) * gap
                    let at = light + (row * width + column) * 3
                    at[0] = silver + (thrown[ring].0 - 0.09) * tint
                    at[1] = silver + (thrown[ring].1 - 0.09) * tint
                    at[2] = silver * 1.04 + (thrown[ring].2 - 0.105) * tint
                }
            }
        }

        // The room: all but dark, a little less so towards the floor.
        var pixel = frame.pixels
        var at = 0
        for row in 0 ..< height {
            let low = Float(row) / Float(height)
            let room = 0.012 + 0.02 * low
            for _ in 0 ..< width {
                let r = 1 - expf(-(light[at] + room) * 1.7)
                let g = 1 - expf(-(light[at + 1] + room) * 1.7)
                let b = 1 - expf(-(light[at + 2] + room * 1.3) * 1.7)
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
