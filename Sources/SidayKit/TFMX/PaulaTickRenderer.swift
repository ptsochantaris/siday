// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after AGIAmigaRenderer, and so after MODRenderer, whose way with the sound chip's output is
// derived from pt2-clone, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence (see
// THIRD-PARTY.md).

/// What the player tells Paula in a tick, kept to be done once the tick has run; and, while it runs,
/// what Paula would say of how many times each voice has gone round, as libtfmxaudiodecoder's voices
/// say it: nought for one stopped, and counted afresh from when it is started.
struct TFMXTickOutput: TFMXOutput {
    enum Event {
        case on(Int)
        case off(Int)
        case buffer(Int, start: Int, length: UInt16)
    }

    var events: [Event] = []
    var playing = InlineArray<8, Bool>(repeating: false)
    var loops = InlineArray<8, UInt16>(repeating: 0)

    mutating func on(_ voice: Int) {
        if !playing[voice] {
            playing[voice] = true
            loops[voice] = 0
        }
        events.append(.on(voice))
    }

    mutating func off(_ voice: Int) {
        playing[voice] = false
        loops[voice] = 0
        events.append(.off(voice))
    }

    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) {
        events.append(.buffer(voice, start: start, length: length))
    }

    func loopCount(_ voice: Int) -> UInt16 { loops[voice] }
}

/// A player of music for Paula that runs a tick at a time and tells her what to do as
/// `TFMXOutput` has it: Chris Hülsbeck's TFMX (`TFMXPlayer`) and Jochen Hippel's players
/// (`HippelPlayer`), which `PaulaTickRenderer` plays.
protocol PaulaTickPlayer: ~Copyable {
    /// The memory Paula plays from, how much of it she may read, where a voice with nothing to play
    /// is pointed, and where TFMX 7V's buffers are mixed into (after a stretch of silence).
    var memory: UnsafeMutablePointer<UInt8> { get }
    var memoryCapacity: Int { get }
    var silenceAt: Int { get }
    var mixingAt: Int { get }
    var songCount: Int { get }
    var song: Int { get }
    /// How many times the song has come to its end since it was started, and of those how many
    /// were its stopping (see `TFMXPlayer`); and its length, in Paula's clocks, if it ends.
    var endings: Int { get }
    var stops: Int { get }
    var lengthClocks: UInt64? { get }
    /// Whose TFMX 7V its fourth voice is mixed as, if it is one; and the change to the tempo its
    /// song last asked for.
    var sevenVoiceStyle: TFMXSevenVoices.Style? { get }
    var sevenVoiceTempo: Int { get }
    /// What is said of the tune: its format and the rest.
    var tuneInfo: TuneInfo { get }
    /// What its sound is turned up or down by to be as loud as any other (see `MODRenderer`).
    var gain: Float { get }
    mutating func select(song: Int) throws(TuneError)
    /// Sets the player to go on round, as it is to be heard. (Called when it is made and with each song.)
    mutating func prepareToBeHeard()
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int
    /// The length of the tick that has just run, for a player of four voices.
    func fourVoiceTick(_ timing: inout TFMXTiming) -> Int
    func period(_ voice: Int) -> UInt16
    func volume(_ voice: Int) -> UInt16
}

extension TFMXPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { format == .sevenVoices ? .huelsbeck : nil }
    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "TFMX")
        info.detail = format.name
        info.title = title
        info.author = author
        return info
    }

    mutating func prepareToBeHeard() {
        loops = true
        playsOnInEndlessPatterns = true
    }

    func fourVoiceTick(_ timing: inout TFMXTiming) -> Int { timing.fourVoiceTick(rate: rate, timer: ciaTimer) }

    /// TFMX's songs are quieter on the Amiga's chip than modules are, by 5 dB in the middle of
    /// UnExoticA's 318, and are turned up by that (2026-10-17).
    var gain: Float { 0.46 }
}

/// Music for Paula played a tick at a time (see `PaulaTickPlayer`): its four voices on her four, or for
/// TFMX 7V three on her first three and four more mixed onto her fourth (`TFMXSevenVoices`).
///
/// A song goes round for as long as it is let, and is said to have looped each time it comes back to
/// its beginning; one that stops, stops. As with any music for the Amiga the two sides are brought
/// most of the way together (see `MODRenderer`).
final class PaulaTickRenderer<Player: PaulaTickPlayer & ~Copyable>: Renderer {
    private(set) var info: TuneInfo
    private(set) var knownLength: Double?
    var isPlayedOnAnAmiga: Bool { true }
    var endsByLooping: Bool { true }
    var hasEnded: Bool { stopped && tickPosition == tickFrames }
    private(set) var loopCount = 0
    var subsongCount: Int { player.songCount }
    var currentSubsong: Int { player.song }
    private(set) var songs: [SongInfo] = []
    var channelsAreSampled: Bool { true }

    private var player: Player
    private let sevenVoices: Bool
    private let style: TFMXSevenVoices.Style
    private let model: AmigaModel
    private var paula: Paula
    private var output = TFMXTickOutput()
    private var mixer: TFMXSevenVoices
    private var timing = TFMXTiming()
    /// Which of the two 7V buffers is mixed into next, and how long the one Paula is playing is.
    private var mixingBuffer = 0
    private var playingBytes = 0
    /// Each of the four 7V voices' part of the buffers last mixed and of those before them, as they are
    /// heard: for their scopes and lights.
    private var parts: UnsafeMutablePointer<Float>
    private var heardParts: UnsafeMutablePointer<Float>
    private var heardCount = 0
    private var stopped = false
    /// How much of the difference between the two sides is kept, halved: none of it for mono.
    private let side: Float
    /// One tick of sound: made at twice the rate, then brought down where it lies.
    private var left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickSpace = 0
    private var tickFrames = 0, tickPosition = 0
    private var levels: TickLevels
    private var notes: TickNotes
    private var down = (HalfBand(), HalfBand())
    /// The part of a sample that ticks are over by, carried from tick to tick: in samples times the
    /// sound chip's clock.
    private var remainder = 0

    private static var chipClock: Int { Int(Paula.clockHz) }
    /// As loud as a MOD file, which is played on the same chip (see `MODRenderer`), by the player's own
    /// measure (`PaulaTickPlayer.gain`).
    private let gain: Float

    init(_ made: consuming Player, options: LoadOptions) throws(TuneError) {
        player = made
        self.player.prepareToBeHeard()
        style = self.player.sevenVoiceStyle ?? .huelsbeck
        sevenVoices = self.player.sevenVoiceStyle != nil
        model = options.amigaModel
        side = options.stereo == .mono ? 0 : Float(max(0, min(1, options.amigaSeparation))) * 0.5
        info = self.player.tuneInfo
        gain = self.player.gain
        let memory = UnsafeRawPointer(player.memory).assumingMemoryBound(to: Int8.self)
        paula = Paula(rate: Double(outputSampleRate * 2), model: model, memory: memory, size: player.memoryCapacity,
                      silence: player.silenceAt)
        mixer = TFMXSevenVoices(silence: self.player.mixingAt - 0x10000, style: style)
        parts = .allocate(capacity: 4 * 1024)
        heardParts = .allocate(capacity: 4 * 1024)
        levels = TickLevels(voices: sevenVoices ? 7 : 4)
        notes = TickNotes(voices: sevenVoices ? 7 : 4)
        left = .allocate(capacity: 1)
        right = .allocate(capacity: 1)
        // Each song's length, from the player's own playing of it through before it starts.
        let first = self.player.song
        for song in 0 ..< self.player.songCount {
            if song != first { try self.player.select(song: song) }
            songs.append(SongInfo(length: self.player.lengthClocks.map { Double($0) / Paula.clockHz }))
        }
        if self.player.song != first { try self.player.select(song: first) }
        self.player.prepareToBeHeard()
        start()
    }

    deinit {
        left.deallocate()
        right.deallocate()
        parts.deallocate()
        heardParts.deallocate()
    }

    /// The voices left out of the sound, which the sound started afresh is started without.
    private var muted: [Bool] = []

    func setMuted(_ muted: [Bool]) {
        self.muted = muted
        applyMutes()
    }

    private func applyMutes() {
        if sevenVoices {
            // Paula's fourth plays the four mixed, which are left out of the mixing each for itself.
            paula.setMuted((0 ..< 4).map { $0 < 3 && $0 < muted.count && muted[$0] })
            for v in 0 ..< 4 { mixer.voices[v].muted = v + 3 < muted.count && muted[v + 3] }
        } else {
            paula.setMuted(muted)
        }
    }

    /// Where Paula keeps each voice's sound for its scope, at her own rate, once asked.
    private var waves: ChannelWaves?

    func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            let made = ChannelWaves(voices: channelCount, rate: Double(outputSampleRate * 2), fullSwing: 1)
            if sevenVoices {
                for v in 3 ..< 7 { made.setVoice(v, rate: Paula.clockHz / Double(style.period), fullSwing: 1) }
            }
            waves = made
            paula.waves = made
            if sevenVoices { paula.waveNumbers = [0, 1, 2, -1] }
        }
        return waves
    }

    func select(subsong: Int) {
        try? player.select(song: subsong)
        player.prepareToBeHeard()
        start()
    }

    /// Starts the song selected from its beginning, on a Paula started afresh.
    private func start() {
        let memory = UnsafeRawPointer(player.memory).assumingMemoryBound(to: Int8.self)
        paula = Paula(rate: Double(outputSampleRate * 2), model: model, memory: memory, size: player.memoryCapacity,
                      silence: player.silenceAt)
        paula.waves = waves
        if sevenVoices { paula.waveNumbers = [0, 1, 2, -1] }
        mixer = TFMXSevenVoices(silence: player.mixingAt - 0x10000, style: style)
        applyMutes()
        output = TFMXTickOutput()
        timing = TFMXTiming()
        knownLength = songs.indices.contains(player.song) ? songs[player.song].length : nil
        loopCount = 0
        stopped = false
        down = (HalfBand(), HalfBand())
        tickFrames = 0
        tickPosition = 0
        levels.clear()
        notes.clear()
        remainder = 0
        heardCount = 0
        if sevenVoices {
            // Paula's fourth plays the mixing from the start, a buffer of silence first.
            mixingBuffer = 0
            playingBytes = style.playedBytes(tempo: player.sevenVoiceTempo)
            paula.setPeriod(3, UInt16(style.period))
            paula.setVolume(3, 64)
            paula.setLocation(3, player.mixingAt + 1024)
            paula.setLength(3, UInt16(playingBytes / 2))
            paula.start(voices: 8)
            // (Which is no note.)
            var none = TickNotes(voices: 4)
            paula.takeNotes(into: &none)
        }
    }

    /// Runs the player once, and makes the sound of the tick that follows.
    private func nextTick() {
        var clocks: Int
        if stopped {
            clocks = 0
        } else if sevenVoices {
            // The next buffer is mixed, from what the four were told before the player runs (Chris
            // Hülsbeck's) or after (Jochen Hippel's), and set to be played after the one Paula is playing.
            let at = player.mixingAt + mixingBuffer * 1024
            let memory = UnsafeRawPointer(player.memory).assumingMemoryBound(to: Int8.self)
            let into = UnsafeMutableRawPointer(player.memory + at).assumingMemoryBound(to: Int8.self)
            swap(&parts, &heardParts)
            let heard = heardCount
            var bytes = style.mixedBytes(tempo: player.sevenVoiceTempo)
            if style.mixesFirst {
                mixer.mix(memory, size: player.memoryCapacity, into: into, count: bytes, parts: parts)
                runPlayer()
            } else {
                runPlayer()
                bytes = style.mixedBytes(tempo: player.sevenVoiceTempo)
                mixer.mix(memory, size: player.memoryCapacity, into: into, count: bytes, parts: parts)
            }
            heardCount = bytes
            paula.setLocation(3, at)
            paula.setLength(3, UInt16(bytes / 2))
            mixingBuffer ^= 1
            // The tick lasts as long as the buffer Paula is playing, which is the one mixed the tick before.
            clocks = playingBytes * style.period
            playingBytes = bytes & ~1
            keepHeardParts(count: heard)
        } else {
            runPlayer()
            clocks = player.fourVoiceTick(&timing)
        }
        if stopped, clocks == 0 {
            tickFrames = 0
            tickPosition = 0
            return
        }
        let whole = Int64(clocks) * Int64(outputSampleRate) + Int64(remainder)
        remainder = Int(whole % Int64(Self.chipClock))
        tickFrames = Int(whole / Int64(Self.chipClock))
        tickPosition = 0
        if tickFrames * 2 > tickSpace {
            left.deallocate()
            right.deallocate()
            tickSpace = tickFrames * 2 + 64
            left = .allocate(capacity: tickSpace)
            right = .allocate(capacity: tickSpace)
        }
        paula.generate(left: left, right: right, count: tickFrames * 2)
        paula.takeLevels(into: &levels.now)
        paula.takeNotes(into: &notes)
        if sevenVoices { takeMixedNotes() }
        levels.tickMade()
        for i in 0 ..< tickFrames {
            left[i] = down.0.step(left[i * 2], left[i * 2 + 1])
            right[i] = down.1.step(right[i * 2], right[i * 2 + 1])
        }
    }

    /// Runs the player for a tick and does what it told Paula, in the order it told it.
    private func runPlayer() {
        let paulaVoices = sevenVoices ? 3 : 4
        for v in 0 ..< 8 {
            if v < paulaVoices {
                output.playing[v] = paula.isPlaying(v)
                output.loops[v] = paula.loopCount(v)
            } else if sevenVoices, v < 7 {
                output.playing[v] = mixer.voices[v - 3].on
                output.loops[v] = mixer.voices[v - 3].on ? mixer.voices[v - 3].loops : 0
            } else {
                output.playing[v] = false
                output.loops[v] = 0
            }
        }
        output.events.removeAll(keepingCapacity: true)
        let stopsBefore = player.stops, endingsBefore = player.endings
        _ = player.run(&output)
        if player.stops > stopsBefore {
            // The song has stopped: what the player does next is to start it again, which is not heard.
            stopped = true
            paula.stop(voices: sevenVoices ? 7 : 15)
            return
        }
        loopCount += player.endings - endingsBefore
        // The periods first: a voice started in this tick takes up the period it is given in it, as
        // Paula's does, whose sound begins a little after the player has written both. (Started before
        // it, a voice that has had no period would never move on from its first sample.)
        for v in 0 ..< (sevenVoices ? 3 : 4) { paula.setPeriod(v, player.period(v)) }
        for event in output.events {
            switch event {
            case let .on(v):
                if v < paulaVoices {
                    if !paula.isPlaying(v) { paula.start(voices: 1 << UInt16(v)) }
                } else if sevenVoices, v < 7 {
                    mixer.voices[v - 3].on = true
                }
            case let .off(v):
                if v < paulaVoices {
                    paula.stop(voices: 1 << UInt16(v))
                } else if sevenVoices, v < 7 {
                    mixer.voices[v - 3].on = false
                    mixer.voices[v - 3].restart = true
                }
            case let .buffer(v, start, length):
                if v < paulaVoices {
                    paula.setLocation(v, start)
                    paula.setLength(v, length)
                } else if sevenVoices, v < 7 {
                    mixer.voices[v - 3].start = start
                    mixer.voices[v - 3].length = length
                }
            }
        }
        // The period and volume as the player left them, as libtfmxaudiodecoder's mixer takes them: of
        // the volume, its low byte, and no more than 64.
        for v in 0 ..< (sevenVoices ? 7 : 4) {
            let volume = min(64, player.volume(v) & 0xFF)
            if v < paulaVoices {
                paula.setVolume(v, volume)
            } else {
                mixer.voices[v - 3].period = player.period(v)
                mixer.voices[v - 3].volume = player.volume(v)
            }
        }
    }

    /// The four 7V voices' parts of the buffer Paula is now playing, kept for their scopes and lights.
    private func keepHeardParts(count: Int) {
        guard count > 0 else { return }
        for v in 0 ..< 4 {
            var low: Float = 0, high: Float = 0
            for i in 0 ..< count {
                let value = heardParts[v * count + i]
                low = min(low, value)
                high = max(high, value)
                waves?.store(3 + v, at: i, value)
            }
            waves?.advance(3 + v, by: count)
            mixedLevels[v] = mixer.voices[v].muted ? 0 : min(1, (high - low) * 0.5)
        }
    }

    private var mixedLevels = InlineArray<4, Float>(repeating: 0)

    /// What the four 7V voices are playing, by their periods.
    private func takeMixedNotes() {
        for v in 0 ..< 4 {
            levels.now[3 + v] = mixedLevels[v]
            let voice = mixer.voices[v]
            notes.pitches[3 + v] = voice.on && voice.period > 0 && voice.table > 0
                ? ChannelPitch.note(ofRate: Paula.clockHz / Double(voice.period)) : 0
            if voice.struck {
                notes.struck[3 + v] = true
                mixer.voices[v].struck = false
            }
        }
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames {
                nextTick()
                if tickFrames == 0 {
                    // The song has stopped: silence for the rest.
                    for i in done * 2 ..< frames * 2 { buffer[i] = 0 }
                    return
                }
            }
            let count = min(frames - done, tickFrames - tickPosition)
            for i in 0 ..< count {
                let l = left[tickPosition + i], r = right[tickPosition + i]
                let middle = (l + r) * 0.5, apart = (l - r) * side
                buffer[(done + i) * 2] = (middle + apart) * gain
                buffer[(done + i) * 2 + 1] = (middle - apart) * gain
            }
            tickPosition += count
            done += count
        }
        waves?.ahead = tickFrames - tickPosition
    }

    /// Paula's four voices; or for TFMX 7V her first three and the four mixed onto her fourth.
    var channelCount: Int { sevenVoices ? 7 : 4 }

    func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< channelCount { sides[voice] = Paula.side(ofVoice: min(voice, 3)) }
    }

    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }
}
