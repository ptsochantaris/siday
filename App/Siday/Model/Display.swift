// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayKit

/// What the player shows at one moment, for one frame of the screen.
struct Frame {
    var position = 0.0
    var bars: [Float] = []
    var caps: [Float] = []
    /// A light for each voice, 0 to 1: it comes on at once and goes out over a moment, as a lamp does.
    var lights: [Float] = []
    var kinds: [VoiceKind] = []
    var muted: [Bool] = []
    /// Each voice's scope, `ChannelWaves.points` points from -1 to 1, one voice after another.
    var scopes: [Float] = []
    var resting = true
}

/// Works out each frame from what the engine says is being heard, and keeps the lights' glow from one
/// frame to the next.
final class Display {
    /// How fast a light goes out, in brightnesses a second: from full to dark in about a seventh of one.
    private static let lightFall: Float = 6.5

    private var lights: [Float] = []
    private var lastTime: Double?
    /// The chunk last told to the picture, so each is told once.
    private var lastHeard = (serial: -1, position: -1.0)

    func frame(_ heard: Heard, serial: Int, at time: Double, visualiser: Visualiser) -> Frame {
        let elapsed = Float(max(0, min(0.1, time - (lastTime ?? time))))
        lastTime = time
        guard heard.serial == serial, !heard.levels.isEmpty || !heard.bars.isEmpty else {
            lights = lights.map { max(0, $0 - Self.lightFall * elapsed) }
            return Frame(lights: lights)
        }
        let levels = heard.resting ? heard.levels.map { _ in Float(0) } : heard.levels
        if lights.count != levels.count { lights = levels }
        lights = levels.indices.map { max(levels[$0], lights[$0] - Self.lightFall * elapsed) }
        // The picture is told what the voices are doing, once for each chunk heard: of the voices
        // that are heard, since a muted voice has no part in it.
        if !heard.resting, (heard.serial, heard.position) != lastHeard {
            lastHeard = (heard.serial, heard.position)
            let muted = heard.muted
            func heardOf(_ voice: Int) -> Bool { !(voice < muted.count && muted[voice]) }
            visualiser.hear(levels: heard.levels.indices.map { heardOf($0) ? heard.levels[$0] : 0 },
                            pitches: heard.pitches.indices.map { heardOf($0) ? heard.pitches[$0] : 0 },
                            struck: heard.struck.indices.map { heardOf($0) && heard.struck[$0] },
                            sides: heard.sides)
        }
        return Frame(position: heard.position, bars: heard.resting ? heard.bars.map { _ in 0 } : heard.bars,
                     caps: heard.resting ? heard.caps.map { _ in 0 } : heard.caps, lights: lights,
                     kinds: heard.kinds, muted: heard.muted, scopes: heard.scopes, resting: heard.resting)
    }
}
