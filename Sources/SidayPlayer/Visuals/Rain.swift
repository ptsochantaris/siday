// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// Rain. Every note that is struck is a drop that falls from the top of the picture, straight down,
/// at a place along it as high as the note is, low notes to the left and high ones to the right, or
/// one come by chance for a voice with no pitch, a drum. Where it meets the bottom it
/// bounces: as high as the note is loud, to the side the note is heard from, or as chance has it if
/// that is the middle or the tune has no sides, and as fast sideways as the note is high. It turns
/// back at the sides of the picture. Each bounce is lower than the last, until one would be too low
/// to be a bounce at all, and the drop falls out of the picture.
///
/// A drop is the colour of its note, as a light of the fountain is, and is drawn as the way it has
/// come in the last moment: a thin line with round ends, all of one colour and as bright at its tail
/// as at its head, which is long where the drop is fast, bent where it has just bounced, and hardly
/// more than a dot at the top of a bounce. It is a little dimmer after each bounce but the first.
///
/// Notes are counted as the fountain counts them: a voice lets a drop fall when a note is struck on
/// it, and no more than eight of them a second, however fast its notes come.
final class Rain: VisualScene {
    /// The colours of the analyser's bars, as the flame and the fountain have them.
    let look = VisualLook.ofNotes
    /// A note keeps its colour.
    let drift: Float = 0

    /// How fast a drop gains speed downward: by so many heights of the picture a second, each second.
    private static let gravity: Float = 1.8
    /// How fast a drop is falling as it comes into the picture, in heights of the picture a second.
    /// It is some two thirds of a second in reaching the bottom.
    private static let falling: Float = 1
    /// How much of its way a drop is drawn as: where it has been in the last so many seconds.
    private static let tail: Float = 0.08
    /// How high a note at its quietest first bounces, as a part of the picture, and how much higher
    /// at its loudest.
    private static let least: Float = 0.08, more: Float = 0.8
    /// The quietest that is told apart from quieter still: see the fountain, which goes by the same.
    private static let quietest: Float = 0.5
    /// How high each bounce is, as a part of the one before; and how low a bounce can be. A drop
    /// that would bounce lower than that does not, and falls away.
    private static let kept: Float = 0.55, lowest: Float = 0.035
    /// How bright a drop is after a bounce, as a part of what it was before, and how long it takes
    /// to get there, in seconds: nothing here changes at once.
    private static let dimmed: Float = 0.8, dimming: Float = 0.3
    /// How far to one side a note has to be heard for its drop to go that way.
    private static let aside: Float = 0.05
    /// How fast the lowest note the tune plays goes sideways once it has bounced, in heights of the
    /// picture a second, and how much faster the highest.
    private static let slowest: Float = 0.1, faster: Float = 0.9
    /// The most drops there can be at once, and the most places that are kept of each one's way.
    private static let most = 512, joints = 16

    /// How high a note so loud first bounces, from 0 to 1 of the picture: as high as the fountain
    /// would send it, all but.
    private static func top(of level: Float) -> Float {
        let loud = max(0, min(1, (level - quietest) / (1 - quietest)))
        return least + more * loud * loud.squareRoot()
    }

    private struct Drop {
        /// Where its head is, in dots, and how fast it is going, in dots a second.
        var x: Float, y: Float, vx: Float = 0, vy: Float
        var colour: (Float, Float, Float)
        /// The voice it fell for, and how loud that was heard to be.
        var voice: Int, level: Float
        /// How fast it is to go sideways once it has bounced; which way, if its note is heard
        /// from the middle, as 1 or -1; and the side its note was heard from.
        var sideways: Float, turn: Float, side: Float
        /// How bright it is, from 0 to 1, and how bright it is on its way to being.
        var bright: Float = 1, wanted: Float = 1
        /// How long it has been going, in seconds.
        var age: Float = 0
        /// How high it last bounced, as a part of the picture.
        var bounce: Float = 0
        /// Whether it has reached the bottom yet, and whether it has done with bouncing.
        var landed = false, sinking = false
        /// How many places of its way are kept.
        var places = 0
    }

    private var across = 0, down = 0
    private var drops: [Drop] = []
    /// The way each drop has come: for each, places where it has been, the newest first, which is
    /// its head. Three numbers a place: across, down, and how old the drop was when it was there.
    private var way: [Float] = []
    /// How struck each voice was a frame ago, and how long since a drop last fell for it.
    private var kicks: [Float] = [], since: [Float] = []
    private var seed: UInt32 = 0x0D40_95A1

    private func chance() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24)
    }

    /// Puts a place into a drop's way behind its head, which is the place at `base`. The oldest is
    /// lost if there is no room.
    private func keep(_ x: Float, _ y: Float, at age: Float, base: Int, places: inout Int) {
        let last = min(places, Self.joints - 1)
        var place = last
        while place > 1 {
            let to = base + place * 3, from = to - 3
            way[to] = way[from]
            way[to + 1] = way[from + 1]
            way[to + 2] = way[from + 2]
            place -= 1
        }
        if last >= 1 {
            way[base + 3] = x
            way[base + 4] = y
            way[base + 5] = age
        }
        places = last + 1
    }

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        if across != width || down != height {
            across = width
            down = height
            drops.removeAll(keepingCapacity: true)
        }
        guard width > 8, height > 8 else { return }
        if way.isEmpty { way = [Float](repeating: 0, count: Self.most * Self.joints * 3) }
        let count = frame.voices.count
        if kicks.count != count {
            kicks = [Float](repeating: 0, count: count)
            since = [Float](repeating: 1, count: count)
        }
        let tall = Float(height), gravity = Self.gravity * tall, elapsed = frame.elapsed
        // A drop is thin, however large the picture is shown: this is half its thickness. It meets
        // the bottom and the sides with its edge, not its middle.
        let thick = max(1.4, tall / 110)
        let floor = tall - thick, near = thick, far = Float(width) - thick

        // A note has been struck if the voice is more struck than it was a frame ago, by however
        // little: a voice that is not struck is always less so than it was.
        for index in 0 ..< count {
            let voice = frame.voices[index]
            since[index] += elapsed
            if voice.kick > kicks[index] + 0.001, since[index] > 0.12, voice.heardLevel > 0.05, drops.count < Self.most {
                since[index] = 0
                let pitched = voice.heardPitch > 0
                let place: Float = pitched ? frame.place(of: voice.heardPitch) : 0
                let x = near + (far - near) * (0.02 + 0.96 * (pitched ? place : chance()))
                let base = drops.count * Self.joints * 3
                way[base] = x
                way[base + 1] = -thick
                way[base + 2] = 0
                drops.append(Drop(x: x, y: -thick, vy: Self.falling * tall,
                                  colour: frame.look.colour(ofNoteAt: pitched ? place : nil),
                                  voice: index, level: voice.heardLevel,
                                  sideways: (Self.slowest + Self.faster * place) * tall, turn: chance() < 0.5 ? -1 : 1,
                                  side: voice.heardSide, places: 1))
            }
            kicks[index] = voice.kick
        }

        // A dark that is a little less dark towards the bottom, as the fountain's is.
        var pixel = frame.pixels
        for row in 0 ..< height {
            let low = Float(row) / tall
            let dark = 0.012 + 0.02 * low * low
            let red = UInt8(dark * 390), green = UInt8(dark * 450), blue = UInt8(dark * 780)
            for _ in 0 ..< width {
                pixel[0] = red
                pixel[1] = green
                pixel[2] = blue
                pixel[3] = 255
                pixel += 4
            }
        }

        var index = 0
        while index < drops.count {
            var one = drops[index]
            let base = index * Self.joints * 3
            // A note is not always as loud as it will be at the moment it is struck, nor where it
            // will be, and a drop is a while in falling: it bounces as high as its note has turned
            // out to be, and to the side that it has turned out to be on.
            if !one.landed, one.voice < count {
                if one.age < 0.15 { one.level = max(one.level, frame.voices[one.voice].heardLevel) }
                if one.age < 0.1 { one.side = frame.voices[one.voice].heardSide }
            }
            one.bright += (one.wanted - one.bright) * (1 - expf(-elapsed / Self.dimming))

            // Where it was is kept, unless a place is already kept that is as good as there.
            if one.places < 2 || way[base + 2] - way[base + 5] >= Self.tail / 10 {
                keep(one.x, one.y, at: one.age, base: base, places: &one.places)
            }
            // And on it goes, as far as the bottom or a side if one is in its way, and on from there.
            var left = elapsed, turns = 0
            while left > 0, turns < 6 {
                turns += 1
                var step = left, met = 0
                if !one.sinking {
                    let toFloor = (-one.vy + (one.vy * one.vy + 2 * gravity * max(0, floor - one.y)).squareRoot()) / gravity
                    if toFloor <= step {
                        step = max(0, toFloor)
                        met = 1
                    }
                }
                if one.vx != 0 {
                    let toSide = ((one.vx > 0 ? far : near) - one.x) / one.vx
                    if toSide < step {
                        step = max(0, toSide)
                        met = 2
                    }
                }
                one.x += one.vx * step
                one.y += (one.vy + gravity * step / 2) * step
                one.vy += gravity * step
                one.age += step
                left -= step
                if met == 1 {
                    // The bottom: up again, less high than the last time, or not at all.
                    one.y = floor
                    if one.landed {
                        one.bounce *= Self.kept
                        one.wanted *= Self.dimmed
                    } else {
                        one.landed = true
                        one.bounce = Self.top(of: one.level)
                        one.vx = one.sideways * (one.side < -Self.aside ? -1 : one.side > Self.aside ? 1 : one.turn)
                    }
                    if one.bounce < Self.lowest {
                        one.sinking = true
                    } else {
                        one.vy = -(2 * gravity * one.bounce * tall).squareRoot()
                    }
                    keep(one.x, one.y, at: one.age, base: base, places: &one.places)
                } else if met == 2 {
                    // A side: back the way it came.
                    one.x = one.vx > 0 ? far : near
                    one.vx = -one.vx
                    keep(one.x, one.y, at: one.age, base: base, places: &one.places)
                }
            }
            way[base] = one.x
            way[base + 1] = one.y
            way[base + 2] = one.age

            // Its way is as long as the last moment of it: what is older is let go, but for the one
            // place that says where the moment began.
            let begun = one.age - Self.tail
            var place = 1
            while place < one.places - 1, way[base + place * 3 + 2] > begun { place += 1 }
            one.places = min(one.places, place + 1)

            // Gone, once the whole of it has fallen out of the picture.
            var highest = one.y
            for place in 1 ..< one.places { highest = min(highest, way[base + place * 3 + 1]) }
            if highest > tall + thick + 1 || one.age > 120 {
                let last = drops.count - 1
                if index != last {
                    let from = last * Self.joints * 3
                    for part in 0 ..< drops[last].places * 3 { way[base + part] = way[from + part] }
                    drops[index] = drops[last]
                }
                drops.removeLast()
                continue
            }
            drops[index] = one
            index += 1

            // Drawn: from its head back along its way, a stretch at a time.
            let bright = one.bright * 255
            let red = one.colour.0 * bright, green = one.colour.1 * bright, blue = one.colour.2 * bright
            for place in 0 ..< max(1, one.places - 1) {
                let from = base + place * 3
                let fromX = way[from], fromY = way[from + 1]
                var toX = fromX, toY = fromY
                if place + 1 < one.places {
                    toX = way[from + 3]
                    toY = way[from + 4]
                    // The oldest stretch, only as far back as the moment goes.
                    let newer = way[from + 2], older = way[from + 5]
                    if older < begun, newer > older {
                        let part = max(0, min(1, (newer - begun) / (newer - older)))
                        toX = fromX + (toX - fromX) * part
                        toY = fromY + (toY - fromY) * part
                    }
                }
                let top = max(0, Int(min(fromY, toY) - thick - 1)), bottom = min(height - 1, Int(max(fromY, toY) + thick + 1))
                let first = max(0, Int(min(fromX, toX) - thick - 1)), last = min(width - 1, Int(max(fromX, toX) + thick + 1))
                guard top <= bottom, first <= last else { continue }
                let alongX = toX - fromX, alongY = toY - fromY
                let length = alongX * alongX + alongY * alongY
                for row in top ... bottom {
                    let fall = Float(row) + 0.5 - fromY
                    for column in first ... last {
                        let aside = Float(column) + 0.5 - fromX
                        // How far the dot is from the stretch, at the nearest place along it.
                        let part = length > 0.0001 ? max(0, min(1, (aside * alongX + fall * alongY) / length)) : 0
                        let offX = aside - alongX * part, offY = fall - alongY * part
                        let cover = min(1, thick + 0.5 - (offX * offX + offY * offY).squareRoot())
                        guard cover > 0 else { continue }
                        let at = frame.pixels + (row * width + column) * 4
                        at[0] = UInt8(max(0, min(255, Float(at[0]) + (red - Float(at[0])) * cover)))
                        at[1] = UInt8(max(0, min(255, Float(at[1]) + (green - Float(at[1])) * cover)))
                        at[2] = UInt8(max(0, min(255, Float(at[2]) + (blue - Float(at[2])) * cover)))
                    }
                }
            }
        }
    }
}
