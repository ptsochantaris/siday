// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// Constellations: the tune drawn as a map of stars. Each note struck is a star, brighter for a louder
/// one, and each phrase a voice plays is a figure of them somewhere in the sky: each note a short step
/// on from the last, across, and up or down as far as the melody goes up or down, joined to it by a
/// faint line, and now and then doubling back. A pause, or seven stars, ends a figure, and the next
/// begins somewhere else. The lines fade in a while and the stars more slowly, so the sky is a map of the
/// last minute or so of the tune; and it turns, very slowly, about a pole below the picture, as the
/// night sky does. A voice with no pitch, a drum or a hiss, makes no stars, but sets those of the sky
/// twinkling a little.
final class Constellations: VisualScene {
    /// Pale colours from much of the wheel, one for each voice, as stars are.
    let look = VisualLook(hue: 0.58, spread: 0.55)
    /// Going round the wheel once in ten minutes.
    let drift: Float = 1.0 / 600

    private struct Star {
        /// Where it is in the sky, in dots, before the sky's turning.
        var x: Float, y: Float
        var bright: Float
        var colour: (Float, Float, Float)
        /// When it was struck, in the picture's seconds.
        var born: Float
        /// The star before it in its voice's figure, if the line between them is to be drawn.
        var after: Int?
    }

    private var stars: [Star] = []
    /// For each voice: the star it struck last, and when; the note it was; the way its figure goes across,
    /// -1 or 1; and how many stars the figure has.
    private var lastStar: [Int?] = [], lastTime: [Float] = [], lastPitch: [Float] = []
    private var heading: [Float] = [], figure: [Int] = []
    private var lastKick: [Float] = []
    private var light: [Float] = []
    private var width = 0, height = 0
    /// How much the sky twinkles, from what the voices with no pitch are doing.
    private var twinkle: Float = 0
    private var random: UInt32 = 0x1234_5679

    /// How long a star and a line last, to fade out, in seconds.
    private static let starLasts: Float = 70, lineLasts: Float = 22
    /// How long a voice may be silent and still carry on its figure, in seconds.
    private static let pause: Float = 1.5
    /// The sky's turning, in turns a second.
    private static let turning: Float = 1.0 / 900
    private static let most = 900

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        if width != self.width || height != self.height {
            self.width = width
            self.height = height
            light = [Float](repeating: 0, count: width * height * 3)
        }
        let count = frame.voices.count
        if lastStar.count != count {
            lastStar = [Int?](repeating: nil, count: count)
            lastTime = [Float](repeating: -100, count: count)
            lastPitch = [Float](repeating: 60, count: count)
            heading = [Float](repeating: 1, count: count)
            figure = [Int](repeating: 0, count: count)
            lastKick = [Float](repeating: 0, count: count)
        }

        // The sky's turning, about a pole below the picture: a new star is put where it is seen now.
        let angle = frame.time * Self.turning * 2 * .pi
        let poleX = Float(width) / 2, poleY = Float(height) * 2.2
        let cosAngle = cosf(angle), sinAngle = sinf(angle)

        var drums: Float = 0
        for index in 0 ..< count {
            let voice = frame.voices[index]
            let struck = voice.kick > lastKick[index] + 0.5
            lastKick[index] = voice.kick
            guard struck else { continue }
            guard voice.pitched else {
                drums += voice.level
                continue
            }
            strike(index, voice, frame, seen: { x, y in
                // From where it is seen back to where it is in the sky.
                let dx = x - poleX, dy = y - poleY
                return (poleX + dx * cosAngle + dy * sinAngle, poleY - dx * sinAngle + dy * cosAngle)
            })
        }
        twinkle = max(twinkle * expf(-frame.elapsed / 0.6), min(1, drums))

        // Stars that have faded out are let go, and the lines that end at them.
        let now = frame.time
        if stars.count > Self.most || stars.first.map({ now - $0.born > Self.starLasts * 2 }) == true {
            let keep = stars.indices.filter { now - stars[$0].born <= Self.starLasts * 2 }.suffix(Self.most)
            var moved = [Int?](repeating: nil, count: stars.count)
            for (new, old) in keep.enumerated() { moved[old] = new }
            stars = keep.map { old in
                var star = stars[old]
                star.after = star.after.flatMap { moved[$0] }
                return star
            }
            lastStar = lastStar.map { $0.flatMap { moved[$0] } }
        }

        for index in light.indices { light[index] = 0 }
        light.withUnsafeMutableBufferPointer { light in
            guard let light = light.baseAddress else { return }
            func seen(_ star: Star) -> (Float, Float) {
                let dx = star.x - poleX, dy = star.y - poleY
                return (poleX + dx * cosAngle - dy * sinAngle, poleY + dx * sinAngle + dy * cosAngle)
            }
            for star in stars {
                let age = now - star.born
                guard let before = star.after else { continue }
                let fade = expf(-age / Self.lineLasts) * 0.22
                guard fade > 0.004 else { continue }
                let (x0, y0) = seen(stars[before]), (x1, y1) = seen(star)
                line(light, x0, y0, x1, y1, star.colour, fade)
            }
            for (index, star) in stars.enumerated() {
                let age = now - star.born
                // A star flares as it is struck, settles, and fades away slowly; and twinkles a little
                // with the drums, each star in its own time.
                let flare = 1 + 1.5 * expf(-age / 0.4)
                let shimmer = 1 + 0.35 * twinkle * sinf(now * 9 + Float(index) * 2.3)
                let bright = star.bright * flare * shimmer * expf(-age / Self.starLasts)
                guard bright > 0.01 else { continue }
                let (x, y) = seen(star)
                glow(light, x, y, star.colour, bright)
            }
        }

        // The night, a little lighter towards the horizon, and the light of the stars over it.
        let night = VisualLook.rgb(hue: frame.look.hue + 0.05, saturation: 0.7, value: 1)
        var pixel = frame.pixels
        var at = 0
        for row in 0 ..< height {
            let low = Float(row) / Float(height)
            let dusk = 0.025 + 0.06 * low * low
            for _ in 0 ..< width {
                pixel[0] = UInt8(max(0, min(255, (1 - expf(-(light[at] + night.0 * dusk) * 1.5)) * 255)))
                pixel[1] = UInt8(max(0, min(255, (1 - expf(-(light[at + 1] + night.1 * dusk) * 1.5)) * 255)))
                pixel[2] = UInt8(max(0, min(255, (1 - expf(-(light[at + 2] + night.2 * dusk) * 1.5)) * 255)))
                pixel[3] = 255
                pixel += 4
                at += 3
            }
        }
    }

    /// A note struck on a voice: a star, a short step on from the voice's last, up or down as far as the
    /// note is from the last, and joined to it; or, after a pause or seven stars, the first of a new
    /// figure somewhere else in the sky. A note struck again at once, the same as the last, only
    /// brightens that star.
    private func strike(_ index: Int, _ voice: VisualVoice, _ frame: VisualFrame, seen: (Float, Float) -> (Float, Float)) {
        let now = frame.time
        let w = Float(width), h = Float(height)
        if let last = lastStar[index], now - lastTime[index] < 0.3, abs(voice.pitch - lastPitch[index]) < 0.5 {
            stars[last].bright = min(1.6, stars[last].bright + 0.1)
            stars[last].born = now
            lastTime[index] = now
            return
        }
        var x: Float, y: Float, joined = false
        if let last = lastStar[index], now - lastTime[index] < Self.pause, figure[index] < 7 {
            // A step on, of about a thirtieth of the sky's width, a little uneven, and sometimes back the
            // way it came; and up or down by the interval, a semitone about a sixtieth of its height.
            let (lastX, lastY) = (stars[last].x, stars[last].y)
            if next() < 0.25 { heading[index] = -heading[index] }
            x = lastX + heading[index] * w * (0.02 + 0.025 * next())
            y = lastY - (voice.pitch - lastPitch[index]) * h / 60 + h * 0.02 * (next() - 0.5)
            // A figure that would leave the sky turns back.
            let (seenX, seenY) = (x, y)
            if seenX < w * 0.04 || seenX > w * 0.96 {
                heading[index] = -heading[index]
                x = lastX + heading[index] * w * (0.02 + 0.025 * next())
            }
            y = max(h * 0.05, min(h * 0.95, seenY))
            joined = true
            figure[index] += 1
        } else {
            // A new figure, somewhere in the sky, its first star as high as the note is.
            (x, y) = seen(w * (0.1 + 0.8 * next()), h * (0.88 - 0.76 * frame.place(of: voice.pitch)))
            heading[index] = next() < 0.5 ? -1 : 1
            figure[index] = 1
        }
        let bright = 0.6 + 0.6 * voice.level
        let colour = frame.look.colour(of: index, among: frame.voices.count, saturation: 0.35)
        stars.append(Star(x: x, y: y, bright: bright, colour: colour, born: now, after: joined ? lastStar[index] : nil))
        lastStar[index] = stars.count - 1
        lastTime[index] = now
        lastPitch[index] = voice.pitch
    }

    /// A star: a bright point and a soft glow round it.
    private func glow(_ light: UnsafeMutablePointer<Float>, _ x: Float, _ y: Float, _ colour: (Float, Float, Float), _ bright: Float) {
        let reach = 3
        let column = Int(x.rounded()), row = Int(y.rounded())
        for dy in -reach ... reach {
            let r = row + dy
            guard r >= 0, r < height else { continue }
            for dx in -reach ... reach {
                let c = column + dx
                guard c >= 0, c < width else { continue }
                let ex = Float(c) - x, ey = Float(r) - y
                let distance = ex * ex + ey * ey
                let share = bright * (1.6 * expf(-distance / 0.5) + 0.25 * expf(-distance / 4))
                let at = light + (r * width + c) * 3
                // The middle of a star is whiter than its glow.
                let white = expf(-distance / 0.5)
                at[0] += share * (colour.0 + (1 - colour.0) * white)
                at[1] += share * (colour.1 + (1 - colour.1) * white)
                at[2] += share * (colour.2 + (1 - colour.2) * white)
            }
        }
    }

    /// A faint line between two stars, in steps of about a dot.
    private func line(_ light: UnsafeMutablePointer<Float>, _ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ colour: (Float, Float, Float), _ bright: Float) {
        let length = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).squareRoot()
        let steps = max(1, Int(length))
        for step in 0 ... steps {
            let along = Float(step) / Float(steps)
            let x = x0 + (x1 - x0) * along, y = y0 + (y1 - y0) * along
            let left = Int(x.rounded(.down)), top = Int(y.rounded(.down))
            guard left >= 0, top >= 0, left + 1 < width, top + 1 < height else { continue }
            let right = x - Float(left), down = y - Float(top)
            let at = light + (top * width + left) * 3, below = at + width * 3
            put(at, colour, bright * (1 - right) * (1 - down))
            put(at + 3, colour, bright * right * (1 - down))
            put(below, colour, bright * (1 - right) * down)
            put(below + 3, colour, bright * right * down)
        }
    }

    private func put(_ at: UnsafeMutablePointer<Float>, _ colour: (Float, Float, Float), _ share: Float) {
        at[0] += colour.0 * share
        at[1] += colour.1 * share
        at[2] += colour.2 * share
    }

    /// A number from 0 up to 1, by a sequence that is the same each time (xorshift).
    private func next() -> Float {
        random ^= random << 13
        random ^= random >> 17
        random ^= random << 5
        return Float(random >> 8) / Float(1 << 24)
    }
}
