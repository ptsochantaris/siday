// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A fountain of lights. Every note that is struck sends one up from the middle of the bottom of
/// the picture, as a firework goes up, to come down at a place along it come by chance and nothing
/// to do with its voice: as high as the note is loud, and in the colour of the note, as a lamp of the flame is (red for the
/// lowest the tune plays, through yellow, green and blue to violet for the highest, and pale for
/// what has no pitch). But nothing bursts. A light is a small round thing with a short tail behind
/// it: it slows as it rises, turns over, and falls away out of the picture, dimmer as it goes.
///
/// Notes are counted much as the pond counts its drops: a voice sends a light up when a note is
/// struck on it, and no more than eight of them a second, however fast its notes come.
///
/// The tails are what the lights leave behind them: the light at each dot of the picture is kept,
/// and fades quickly, and each light's way is drawn into it from where it was to where it is, as
/// bright as the light and no brighter where it crosses another or lingers. The lights themselves
/// are drawn over that afterwards.
final class Fountain: VisualScene {
    /// The colours of the analyser's bars, as the flame has them.
    let look = VisualLook.ofNotes
    /// A note keeps its colour until other colours are asked for.
    let drift: Float = 0

    /// How fast a light gains speed downward: by so many heights of the picture a second, each
    /// second. The loudest note is a little over a second in reaching its top.
    private static let gravity: Float = 1.3
    /// How long the light a place was left with takes to fall to about a third, in seconds.
    private static let tail: Float = 0.06
    /// How far a note at its quietest goes up the picture, and how much further at its loudest.
    private static let least: Float = 0.1, more: Float = 0.82
    /// The quietest that is told apart from quieter still. Levels go by decibels, and nearly all
    /// the notes of nearly every tune are struck within the loudest half of them, some twenty
    /// decibels: so it is that half that is spread over the height of the picture, and not the whole.
    private static let quietest: Float = 0.5
    /// How wide the spout is that the lights leave by, as a part of the width of the picture.
    private static let spout: Float = 0.06
    /// The most lights there can be at once.
    private static let most = 512

    /// How far up the picture, from 0 to 1, a note so loud is sent. Most notes are near the loudest
    /// even so, and the nearer the further apart they are sent: an AY chip's loudest volume goes
    /// nine tenths of the way up, the next three quarters, and the one after that six tenths.
    private static func top(of level: Float) -> Float {
        let loud = max(0, min(1, (level - quietest) / (1 - quietest)))
        return least + more * loud * loud.squareRoot()
    }

    /// What light is multiplied by to squeeze it into what a screen can show, given the most there
    /// is of any colour at a place: all three colours alike, so that they stay the colour they were.
    private static func shown(most light: Float) -> Float { light > 0.0001 ? (1 - expf(-light * 2.2)) / light : 2.2 }

    private struct Light {
        /// Where it is, in dots, and how fast it is going, in dots a second.
        var x: Float, y: Float, vx: Float, vy: Float
        /// Where along the bottom of the picture it is to come down.
        var land: Float
        var colour: (Float, Float, Float)
        /// The voice it was sent up by, and how loud that was heard to be.
        var voice: Int, level: Float
        /// How long it has been going, and how long it takes to reach its top, in seconds.
        var age: Float = 0, rise: Float

        /// How bright it is, from 0 to 1: as bright as it was until it turns over, and dimmer the
        /// longer it has fallen, less than half as bright by the time it is back where it began.
        var bright: Float { age < rise ? 1 : expf(-(age - rise) / (1.2 * rise)) }
    }

    private var across = 0, down = 0
    /// The light at each dot of the picture, as red, green and blue.
    private var light: [Float] = []
    private var lights: [Light] = []
    /// How struck each voice was a frame ago, and how long since it last sent a light up.
    private var kicks: [Float] = [], since: [Float] = []
    private var seed: UInt32 = 0x0F0A_7A17

    private func chance() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24)
    }

    func paint(_ frame: VisualFrame) {
        let width = frame.width, height = frame.height
        if across != width || down != height {
            across = width
            down = height
            light = [Float](repeating: 0, count: width * height * 3)
            lights.removeAll(keepingCapacity: true)
        }
        guard width > 8, height > 8 else { return }
        let count = frame.voices.count
        if kicks.count != count {
            kicks = [Float](repeating: 0, count: count)
            since = [Float](repeating: 1, count: count)
        }
        let tall = Float(height), gravity = Self.gravity * tall, elapsed = frame.elapsed
        // A light is some points across however large the picture is shown. Its tail is finer
        // than it is, with a glow about it.
        let size = max(2.2, tall / 80), fine = size * 0.45, reach = size * 2.2

        // A note has been struck if the voice is more struck than it was a frame ago, by however
        // little: a voice that is not struck is always less so than it was.
        for index in 0 ..< count {
            let voice = frame.voices[index]
            since[index] += elapsed
            if voice.kick > kicks[index] + 0.001, since[index] > 0.12, voice.heardLevel > 0.05, lights.count < Self.most {
                since[index] = 0
                // As fast as will take it as high as it is to go. It leaves by the spout in the
                // middle, and leans as far as will bring it down where it is to land: a place come
                // by chance, anywhere along the bottom. (Its place in the spout is come by with it.)
                let speed = (2 * gravity * Self.top(of: voice.heardLevel) * tall).squareRoot(), rise = speed / gravity
                let chosen = 0.04 + 0.92 * chance()
                let land = chosen * Float(width) + speed * 0.14 * (chance() - 0.5) * 2 * rise
                let x = (0.5 + Self.spout * (chosen - 0.5)) * Float(width)
                lights.append(Light(x: x, y: tall + size, vx: (land - x) / (2 * rise), vy: -speed, land: land,
                                    colour: frame.look.colour(ofNoteAt: voice.heardPitch > 0 ? frame.place(of: voice.heardPitch) : nil),
                                    voice: index, level: voice.heardLevel, rise: rise))
            }
            kicks[index] = voice.kick
        }

        light.withUnsafeMutableBufferPointer { light in
            guard let light = light.baseAddress else { return }
            var index = 0
            while index < lights.count {
                var one = lights[index]
                // A note is not always as loud as it will be at the moment it is struck. A light
                // that has only just left is sent on as high as its note has turned out to be.
                if one.age < 0.1, one.voice < count, one.vy < 0, frame.voices[one.voice].heardLevel > one.level {
                    let louder = frame.voices[one.voice].heardLevel
                    let faster = (Self.top(of: louder) / Self.top(of: one.level)).squareRoot()
                    one.vy *= faster
                    one.level = louder
                    one.rise = one.age - one.vy / gravity
                    // It is longer in the air, and leans the less to come down where it was to.
                    let left = (-one.vy + (one.vy * one.vy + 2 * gravity * max(0, tall + size - one.y)).squareRoot()) / gravity
                    if left > 0 { one.vx = (one.land - one.x) / left }
                }
                let fromX = one.x, fromY = one.y
                one.x += one.vx * elapsed
                one.y += (one.vy + gravity * elapsed / 2) * elapsed
                one.vy += gravity * elapsed
                one.age += elapsed
                // Gone, once it has fallen out of the picture. Its tail is left to fade.
                if one.vy > 0, fromY > tall + reach {
                    lights[index] = lights[lights.count - 1]
                    lights.removeLast()
                    continue
                }
                lights[index] = one
                index += 1

                let bright = one.bright
                let colour = (one.colour.0 * bright, one.colour.1 * bright, one.colour.2 * bright)
                // Drawn all the way from where it was, so that a fast one is a streak and not beads.
                let alongX = one.x - fromX, alongY = one.y - fromY
                let steps = max(1, Int((alongX * alongX + alongY * alongY).squareRoot() / max(0.6, fine)) + 1)
                for step in 1 ... steps {
                    let part = Float(step) / Float(steps)
                    let x = fromX + alongX * part, y = fromY + alongY * part
                    let top = max(0, Int(y - reach)), bottom = min(height - 1, Int(y + reach))
                    let first = max(0, Int(x - reach)), last = min(width - 1, Int(x + reach))
                    guard top <= bottom, first <= last else { continue }
                    for row in top ... bottom {
                        let fall = Float(row) + 0.5 - y
                        for column in first ... last {
                            let aside = Float(column) + 0.5 - x
                            let away = (aside * aside + fall * fall).squareRoot()
                            // The tail, soft at its edge, and the glow about it.
                            let glow = max(0, 1 - away / reach)
                            let amount = max(min(1, fine + 0.5 - away), 0.3 * glow * glow)
                            guard amount > 0 else { continue }
                            let at = light + (row * width + column) * 3
                            at[0] = max(at[0], colour.0 * amount)
                            at[1] = max(at[1], colour.1 * amount)
                            at[2] = max(at[2], colour.2 * amount)
                        }
                    }
                }
            }

            // The dots, over a dark that is a little less dark towards the bottom; and the light
            // at each fades for the next time.
            let fade = expf(-elapsed / Self.tail)
            var pixel = frame.pixels, at = light
            for row in 0 ..< height {
                let low = Float(row) / tall
                let dark = 0.012 + 0.02 * low * low
                for _ in 0 ..< width {
                    let squeezed = Self.shown(most: max(at[0], at[1], at[2])) * 255
                    pixel[0] = UInt8(max(0, min(255, at[0] * squeezed + dark * 390)))
                    pixel[1] = UInt8(max(0, min(255, at[1] * squeezed + dark * 450)))
                    pixel[2] = UInt8(max(0, min(255, at[2] * squeezed + dark * 780)))
                    pixel[3] = 255
                    at[0] *= fade
                    at[1] *= fade
                    at[2] *= fade
                    pixel += 4
                    at += 3
                }
            }
        }

        // And the lights themselves over their tails, each a round dot, whole and steady.
        for one in lights {
            let bright = one.bright * 255
            let top = max(0, Int(one.y - size - 1)), bottom = min(height - 1, Int(one.y + size + 1))
            let first = max(0, Int(one.x - size - 1)), last = min(width - 1, Int(one.x + size + 1))
            guard top <= bottom, first <= last else { continue }
            for row in top ... bottom {
                let fall = Float(row) + 0.5 - one.y
                for column in first ... last {
                    let aside = Float(column) + 0.5 - one.x
                    let cover = min(1, size + 0.5 - (aside * aside + fall * fall).squareRoot())
                    guard cover > 0 else { continue }
                    let at = frame.pixels + (row * width + column) * 4
                    at[0] = UInt8(max(0, min(255, Float(at[0]) + (one.colour.0 * bright - Float(at[0])) * cover)))
                    at[1] = UInt8(max(0, min(255, Float(at[1]) + (one.colour.1 * bright - Float(at[1])) * cover)))
                    at[2] = UInt8(max(0, min(255, Float(at[2]) + (one.colour.2 * bright - Float(at[2])) * cover)))
                }
            }
        }
    }
}
