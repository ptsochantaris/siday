// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

// Pictures to listen by: something to watch that moves with a tune and is made from what the tune's
// voices are doing, each one's loudness and pitch and the notes it starts, and not from the sound
// they add up to. They are painted here, into a small picture that whoever shows it stretches to fit.
//
// They are meant to be calm: a lava lamp, not a strobe. So nothing in them changes at once. What a
// voice is doing is followed a little behind; colours change of themselves, if they do, so slowly
// that the change is not seen happening; and nothing changes of its own accord from one kind of
// picture to another.

/// A voice as the pictures see it: what it is doing, followed smoothly.
struct VisualVoice {
    /// What was last heard of it.
    var heardLevel: Float = 0, heardPitch: Float = 0
    /// How loud it is, from 0 to 1: quick to rise and slow to fall.
    var level: Float = 0
    /// Its pitch as a note number (see `ChannelPitch`), gliding to where it was last heard. A voice
    /// that has no pitch keeps the last it had.
    var pitch: Float = 60
    /// True while what it plays has a pitch.
    var pitched = false
    /// 1 when a note is struck, and dying away at once.
    var kick: Float = 0
    /// Which side it was last heard from: from -1 on the left to 1 on the right, and 0 for the
    /// middle, or for a voice of a tune that has no sides.
    var heardSide: Float = 0
}

/// The colours a picture is painted in. They are places on the colour wheel, from 0 round to 1.
struct VisualLook {
    /// Where the voices' colours are centred, and how much of the wheel they are spread over.
    var hue: Float
    var spread: Float

    /// The colour of one voice of several, as red, green and blue from 0 to 1.
    func colour(of voice: Int, among count: Int, saturation: Float = 0.85, value: Float = 1) -> (Float, Float, Float) {
        let place = count > 1 ? Float(voice) / Float(count - 1) - 0.5 : 0
        return Self.rgb(hue: hue + spread * place, saturation: saturation, value: value)
    }

    /// The colours of the analyser's bars: from red round to violet, which is most of the wheel,
    /// from the lowest note to the highest.
    static let ofNotes = VisualLook(hue: 145.0 / 360, spread: 290.0 / 360)

    /// The colour of a note that lies so far from the lowest a tune plays to the highest, from 0 to
    /// 1 (see `VisualFrame.place`), or of something with no pitch if there is no such place: as
    /// strong and as bright as the analyser's bars are, or pale.
    func colour(ofNoteAt place: Float?) -> (Float, Float, Float) {
        guard let place else { return Self.rgb(hue: hue, saturation: 0.1, value: 0.7) }
        return Self.rgb(hue: hue + spread * (place - 0.5), saturation: 0.815, value: 0.98)
    }

    static func rgb(hue: Float, saturation: Float, value: Float) -> (Float, Float, Float) {
        let turn = (hue - hue.rounded(.down)) * 6
        let sector = Int(turn) % 6
        let rise = turn - Float(Int(turn))
        let low = value * (1 - saturation), falling = value * (1 - saturation * rise), rising = value * (1 - saturation * (1 - rise))
        switch sector {
        case 0: return (value, rising, low)
        case 1: return (falling, value, low)
        case 2: return (low, value, rising)
        case 3: return (low, falling, value)
        case 4: return (rising, low, value)
        default: return (value, low, falling)
        }
    }
}

/// What a picture is painted from, for one frame.
struct VisualFrame {
    /// The picture: red, green, blue and a fourth byte that is always 255, for each dot, in rows from the top.
    let pixels: UnsafeMutablePointer<UInt8>
    let width: Int, height: Int
    /// Seconds since the pictures began, and since the last frame.
    let time: Float, elapsed: Float
    let voices: [VisualVoice]
    let look: VisualLook
    /// The lowest and highest notes the tune has been heard to play, with a little to spare.
    let lowestPitch: Float, highestPitch: Float

    /// Where a pitch lies between the lowest and the highest, from 0 to 1.
    func height(of pitch: Float) -> Float {
        max(0, min(1, (pitch - lowestPitch) / max(1, highestPitch - lowestPitch)))
    }

    /// How much of the tune's range of notes, at each end of it, counts as all one note.
    static let ends: Float = 0.12

    /// Where a pitch lies for telling notes apart, from 0 to 1: a picture that gives a note its
    /// colour by how high it is, or its place from side to side, goes by this. It is `height(of:)`
    /// with the ends drawn in, so that the lowest notes are all as one and the highest likewise,
    /// and the notes between, where a tune's melodies are, are further apart from one to the next.
    func place(of pitch: Float) -> Float {
        max(0, min(1, (height(of: pitch) - Self.ends) / (1 - 2 * Self.ends)))
    }
}

/// One kind of picture. It keeps whatever it needs from one frame to the next.
protocol VisualScene: AnyObject {
    /// The colours it starts in.
    var look: VisualLook { get }
    /// How fast its colours go round the wheel by themselves, in turns a second; nought if they stay
    /// as they are.
    var drift: Float { get }
    func paint(_ frame: VisualFrame)
}

public final class Visualiser {
    /// The kinds of picture there are.
    public enum Mode: String, CaseIterable, Sendable {
        case lava, aurora, pond, flame, fountain, rain, petri, harmonograph

        public var title: String {
            switch self {
            case .lava: "Lava lamp"
            case .aurora: "Aurora"
            case .pond: "Pond"
            case .flame: "Flame"
            case .fountain: "Fountain"
            case .rain: "Rain"
            case .petri: "Petri dish"
            case .harmonograph: "Harmonograph"
            }
        }
    }

    public var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            scene = Self.scene(for: mode)
            lookWanted = scene.look
        }
    }

    public private(set) var width = 0, height = 0
    /// The picture as last painted: `width * height * 4` bytes, or nil before it has a size.
    public private(set) var pixels: UnsafeMutablePointer<UInt8>?

    private var scene: any VisualScene
    private var voices: [VisualVoice] = []
    private var look: VisualLook, lookWanted: VisualLook
    private var lowestPitch: Float = 48, highestPitch: Float = 84
    private var time: Float = 0
    private var lastSeconds: Double?

    public init(mode: Mode = .lava) {
        self.mode = mode
        scene = Self.scene(for: mode)
        look = scene.look
        lookWanted = look
    }

    deinit {
        pixels?.deallocate()
    }

    private static func scene(for mode: Mode) -> any VisualScene {
        switch mode {
        case .lava: LavaLamp()
        case .aurora: Aurora()
        case .pond: Pond()
        case .flame: Flame()
        case .fountain: Fountain()
        case .rain: Rain()
        case .petri: PetriDish()
        case .harmonograph: Harmonograph()
        }
    }

    /// The size of picture that suits a space of so many points by so many: small enough to paint
    /// quickly and to come out soft when it is stretched, and of the same shape as the space.
    public static func size(for spaceWidth: Double, _ spaceHeight: Double) -> (width: Int, height: Int) {
        guard spaceWidth >= 8, spaceHeight >= 8 else { return (0, 0) }
        let width = max(160, min(448, Int(spaceWidth / 2))) & ~3
        let height = max(64, min(448, Int(Double(width) * spaceHeight / spaceWidth))) & ~3
        return (width, height)
    }

    /// Gives the picture a size, in dots. It starts again from black if the size is new.
    public func resize(width: Int, height: Int) {
        guard width != self.width || height != self.height, width > 0, height > 0 else { return }
        pixels?.deallocate()
        pixels = .allocate(capacity: width * height * 4)
        pixels?.initialize(repeating: 0, count: width * height * 4)
        self.width = width
        self.height = height
    }

    /// What the tune's voices are doing now: how loud each is, from 0 to 1, its pitch as a note
    /// number or 0 for none, whether a note has just been started on it, and which side it is heard
    /// from, from -1 on the left to 1 on the right, if it is known.
    public func hear(levels: [Float], pitches: [Float], struck: [Bool], sides: [Float] = []) {
        if voices.count != levels.count { voices = [VisualVoice](repeating: VisualVoice(), count: levels.count) }
        for voice in voices.indices {
            voices[voice].heardLevel = max(0, min(1, levels[voice]))
            voices[voice].heardPitch = voice < pitches.count ? pitches[voice] : 0
            if voice < struck.count, struck[voice] { voices[voice].kick = 1 }
            voices[voice].heardSide = voice < sides.count ? max(-1, min(1, sides[voice])) : 0
        }
    }

    /// Nothing is sounding: the voices fall quiet where they are.
    public func rest() {
        for voice in voices.indices { voices[voice].heardLevel = 0 }
    }

    /// Another tune: what was learned of the last one's range of notes is forgotten.
    public func newTune() {
        lowestPitch = 48
        highestPitch = 84
    }

    /// Paints the picture as it is at a time, in seconds by any clock that only goes forward.
    public func paint(at seconds: Double) {
        guard let pixels else { return }
        // A long gap, as when the page was out of sight, is not a long step.
        let elapsed = Float(max(0, min(0.1, seconds - (lastSeconds ?? seconds))))
        lastSeconds = seconds
        time += elapsed

        func eased(_ seconds: Float) -> Float { 1 - expf(-elapsed / seconds) }
        for voice in voices.indices {
            let heard = voices[voice].heardLevel
            voices[voice].level += (heard - voices[voice].level) * eased(heard > voices[voice].level ? 0.05 : 0.4)
            voices[voice].kick *= expf(-elapsed / 0.3)
            let pitch = voices[voice].heardPitch
            voices[voice].pitched = pitch > 0
            if pitch > 0 {
                voices[voice].pitch += (pitch - voices[voice].pitch) * eased(0.12)
                // The range of notes widens at once to take in what is heard, and never narrows.
                if heard > 0.1 {
                    lowestPitch = min(lowestPitch, pitch - 2)
                    highestPitch = max(highestPitch, pitch + 2)
                }
            }
        }
        // The colours, on their way to where they are wanted, which after another kind of picture
        // has been chosen is that picture's own: the short way round the wheel. Where the picture's
        // colours drift, where they are wanted moves on all the time.
        lookWanted.hue += scene.drift * elapsed
        lookWanted.hue -= lookWanted.hue.rounded(.down)
        var turn = lookWanted.hue - look.hue
        turn -= turn.rounded()
        look.hue += turn * eased(1.5)
        look.hue -= look.hue.rounded(.down)
        look.spread += (lookWanted.spread - look.spread) * eased(1.5)

        scene.paint(VisualFrame(pixels: pixels, width: width, height: height, time: time, elapsed: elapsed, voices: voices, look: look,
                                lowestPitch: lowestPitch, highestPitch: highestPitch))
    }
}
