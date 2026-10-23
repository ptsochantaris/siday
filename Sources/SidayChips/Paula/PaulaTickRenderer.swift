// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after AGIAmigaRenderer, and so after MODRenderer, whose way with the sound chip's output is
// derived from pt2-clone, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence (see
// THIRD-PARTY.md).

import SidayFoundation

/// What the player tells Paula in a tick, kept to be done once the tick has run; and, while it runs,
/// what Paula would say of how many times each voice has gone round, as libtfmxaudiodecoder's voices
/// say it: nought for one stopped, and counted afresh from when it is started.
package struct TFMXTickOutput: TFMXOutput {
    enum Event {
        case on(Int)
        case off(Int)
        case buffer(Int, start: Int, length: UInt16)
        /// What follows is heard this many of Paula's clocks into the tick; and her registers, as a
        /// player on an emulated Amiga writes them (see `TFMXOutput.timed(at:)`).
        case at(Int)
        case period(Int, UInt16)
        case volume(Int, UInt16)
        case filter(Bool)
    }

    var events: [Event] = []
    var playing = InlineArray<8, Bool>(repeating: false)
    var loops = InlineArray<8, UInt16>(repeating: 0)

    package mutating func on(_ voice: Int) {
        if !playing[voice] {
            playing[voice] = true
            loops[voice] = 0
        }
        events.append(.on(voice))
    }

    package mutating func off(_ voice: Int) {
        playing[voice] = false
        loops[voice] = 0
        events.append(.off(voice))
    }

    package mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) {
        events.append(.buffer(voice, start: start, length: length))
    }

    package func loopCount(_ voice: Int) -> UInt16 { loops[voice] }

    package mutating func timed(at clocks: Int) { events.append(.at(clocks)) }
    package mutating func writePeriod(_ voice: Int, _ period: UInt16) { events.append(.period(voice, period)) }
    package mutating func writeVolume(_ voice: Int, _ volume: UInt16) { events.append(.volume(voice, volume)) }
    package mutating func writeLightFilter(_ on: Bool) { events.append(.filter(on)) }
}

/// A player of music for Paula that runs a tick at a time and tells her what to do as
/// `TFMXOutput` has it: Chris Hülsbeck's TFMX (`TFMXPlayer`) and Jochen Hippel's players
/// (`HippelPlayer`), which `PaulaTickRenderer` plays.
package protocol PaulaTickPlayer: ~Copyable {
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
    /// For a player that plays its songs through unheard only when it is asked to (`measure`), to
    /// find how long they are: what it has found, for each song its length in Paula's clocks, or nil
    /// within for one that never ends, and nil for one not yet played through. Nil for a player that
    /// finds each song's length as it is made or selected (`lengthClocks`).
    var measured: [UInt64??]? { get }
    /// Plays a song through unheard to find its length, if that has not been done; the player is to
    /// be selected afresh after it. (Asked in the same order by every load of a file: see
    /// `PaulaTickRenderer.measure(through:)`.)
    mutating func measure(_ song: Int) throws(TuneError)
    /// Takes what another load of the same file found of every song (`measured`).
    mutating func adopt(_ lengths: [UInt64?])
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
    /// Runs a tick, told to the renderer's own output. (Named, rather than any `TFMXOutput`, so that the
    /// module of each player makes its generic `run` for this one: a generic requirement would be met
    /// by the player's generic code, unspecialised, as a module cannot specialise another's.)
    mutating func run(_ output: inout TFMXTickOutput) -> Int
    /// The length of the tick that has just run, for a player of four voices.
    func fourVoiceTick(_ timing: inout TFMXTiming) -> Int
    func period(_ voice: Int) -> UInt16
    func volume(_ voice: Int) -> UInt16
    /// True while the player has the Amiga's filter on (the one its power light shows).
    var lightFilter: Bool { get }
    /// For a player that mixes some of its voices onto one of Paula's itself, by the processor (Mugician
    /// II): what it says of them, for each to be shown and left out for itself. Nil for one that does not.
    var ownMixing: PaulaOwnMixing? { get }
    /// How many bytes the player mixed in the tick just run, and each mixed voice's part of each of them,
    /// as it is heard: turned down by its volume, in 128ths of a byte's fullest swing.
    var mixedCount: Int { get }
    func mixedPart(_ voice: Int, at index: Int) -> Float
    /// The period a mixed voice is playing its sample at now, nought for one that is silent; and whether
    /// it has started a sample since this was last asked.
    func mixedPeriod(_ voice: Int) -> UInt16
    mutating func takeMixedStruck(_ voice: Int) -> Bool
    /// Leaves a mixed voice out of the mixing, or brings it back.
    mutating func setMixedMuted(_ voice: Int, _ muted: Bool)
    /// How far into its tick, in Paula's clocks, the voices the player starts in it begin: where its
    /// write that turns their DMA on falls, after the rest of what it does in the tick, which is all done
    /// at the tick's start. Nought, for a player whose notes begin with the tick.
    var noteClocks: Int { get }
}

package extension PaulaTickPlayer where Self: ~Copyable {
    /// Most players find each song's length as they are made or selected.
    var measured: [UInt64??]? { nil }
    mutating func measure(_: Int) throws(TuneError) {}
    mutating func adopt(_: [UInt64?]) {}
    /// A player that does not set it leaves it off.
    var lightFilter: Bool { false }
    /// Most players' notes begin with their tick.
    var noteClocks: Int { 0 }
    /// Most players mix nothing themselves.
    var ownMixing: PaulaOwnMixing? { nil }
    var mixedCount: Int { 0 }
    func mixedPart(_: Int, at _: Int) -> Float { 0 }
    func mixedPeriod(_: Int) -> UInt16 { 0 }
    mutating func takeMixedStruck(_: Int) -> Bool { false }
    mutating func setMixedMuted(_: Int, _: Bool) {}
}

/// What a player that mixes some of its voices onto one of Paula's itself says of them (see
/// `PaulaTickPlayer.ownMixing`): how many there are, which of her voices plays what is mixed of them,
/// at what period, and after how many bytes of silence the first that is mixed is heard. Her other
/// three are shown first, in the order of `shown` (which of them each of her four is shown as, -1 for
/// the one that plays the mixing), and the mixed voices after them.
package struct PaulaOwnMixing {
    var voices: Int
    var onto: Int
    var period: Int
    var leadBytes: Int
    var shown: InlineArray<4, Int>

    package init(voices: Int, onto: Int, period: Int, leadBytes: Int, shown: InlineArray<4, Int>) {
        self.voices = voices
        self.onto = onto
        self.period = period
        self.leadBytes = leadBytes
        self.shown = shown
    }
}

/// Music for Paula played a tick at a time (see `PaulaTickPlayer`): its four voices on her four, or for
/// TFMX 7V three on her first three and four more mixed onto her fourth (`TFMXSevenVoices`).
///
/// A song goes round for as long as it is let, and is said to have looped each time it comes back to
/// its beginning; one that stops, stops. As with any music for the Amiga the two sides are brought
/// most of the way together (see `MODRenderer`).
package final class PaulaTickRenderer<Player: PaulaTickPlayer & ~Copyable>: Renderer {
    package private(set) var info: TuneInfo
    package private(set) var knownLength: Double?
    package var isPlayedOnAnAmiga: Bool { true }
    package var endsByLooping: Bool { true }
    package var hasEnded: Bool { stopped && tickPosition == tickFrames }
    package private(set) var loopCount = 0
    package var subsongCount: Int { player.songCount }
    package var currentSubsong: Int { player.song }
    /// The song played when none is asked for: the first that lasts a second or more, as a module's
    /// first song is chosen (`ModuleSongs.first(of:)`), so that a file whose first songs are empty
    /// or a moment's sound effect starts with its music. The first, if none does.
    package var defaultSubsong: Int { ModuleSongs.first(of: songs.map { $0.empty || ($0.length ?? 1) < 1 }) }
    package private(set) var songs: [SongInfo] = []
    package var channelsAreSampled: Bool { true }

    private var player: Player
    private let sevenVoices: Bool
    /// What the player says of the voices it mixes itself, if it does (see `PaulaOwnMixing`).
    private let own: PaulaOwnMixing?
    /// Their parts of what has been mixed and not yet heard, `ownSpace` of each voice's, `ownPending`
    /// of them kept; the part of a byte of the mixing the ticks so far are over by, in Paula's clocks;
    /// and how far each swung in the tick just made.
    private var ownParts: UnsafeMutablePointer<Float>
    private static var ownSpace: Int { 4096 }
    private var ownPending = 0
    private var ownClocks = 0
    private var ownLevels = InlineArray<4, Float>(repeating: 0)
    /// What Paula says of her four, before it is shown as the voices they are.
    private var paulaLevels = [Float](repeating: 0, count: 4)
    private var paulaNotes = TickNotes(voices: 4)
    /// How far into a tick the player's notes begin (`PaulaTickPlayer.noteClocks`), and the voices it has
    /// started in the tick being made, which begin there.
    private let noteClocks: Int
    private var startsLater: UInt16 = 0
    /// Where among the tick's events the first told at a moment within it is (`TFMXOutput.timed(at:)`):
    /// it and those after it are done as the tick's sound is made, each at its moment.
    private var timedFrom: Int?
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

    package init(_ made: consuming Player, options: LoadOptions) throws(TuneError) {
        player = made
        self.player.prepareToBeHeard()
        style = self.player.sevenVoiceStyle ?? .huelsbeck
        sevenVoices = self.player.sevenVoiceStyle != nil
        own = sevenVoices ? nil : self.player.ownMixing.map { mixing in
            var mixing = mixing
            mixing.voices = max(0, min(4, mixing.voices))
            mixing.onto = max(0, min(3, mixing.onto))
            mixing.period = max(1, mixing.period)
            mixing.leadBytes = max(0, min(Self.ownSpace / 2, mixing.leadBytes))
            for p in 0 ..< 4 where p == mixing.onto || mixing.shown[p] > 2 { mixing.shown[p] = -1 }
            return mixing
        }
        model = options.amigaModel
        side = options.stereo == .mono ? 0 : Float(max(0, min(1, options.amigaSeparation))) * 0.5
        info = self.player.tuneInfo
        gain = self.player.gain
        noteClocks = max(0, self.player.noteClocks)
        let memory = UnsafeRawPointer(player.memory).assumingMemoryBound(to: Int8.self)
        paula = Paula(rate: Double(outputSampleRate * 2), model: model, memory: memory, size: player.memoryCapacity,
                      silence: player.silenceAt)
        mixer = TFMXSevenVoices(silence: self.player.mixingAt - 0x10000, style: style)
        parts = .allocate(capacity: 4 * 1024)
        heardParts = .allocate(capacity: 4 * 1024)
        ownParts = .allocate(capacity: 4 * Self.ownSpace)
        let voices = sevenVoices ? 7 : own.map { 3 + $0.voices } ?? 4
        levels = TickLevels(voices: voices)
        notes = TickNotes(voices: voices)
        left = .allocate(capacity: 1)
        right = .allocate(capacity: 1)
        // Each song's length, from the player's own playing of it through before it starts.
        let first = self.player.song
        measuredFirst = first
        if self.player.measured != nil {
            // By one that does it when asked: all of them, or as far as the first song that is music,
            // or none, if another load of the file has found them.
            if let given = options.songMeasures, given.lengths.count == self.player.songCount {
                self.player.adopt(given.lengths)
            } else {
                try self.player.measure(first)
                if options.measuresEverySong {
                    try measure(through: self.player.songCount - 1)
                } else if first == 0 {
                    for song in 0 ..< self.player.songCount {
                        try measure(through: song)
                        noteMeasured()
                        if !songs[song].empty, (songs[song].length ?? 1) >= 1 { break }
                    }
                }
            }
            noteMeasured()
        } else {
            for song in 0 ..< self.player.songCount {
                if song != first { try self.player.select(song: song) }
                let length = self.player.lengthClocks.map { Double($0) / Paula.clockHz }
                songs.append(SongInfo(length: length, empty: length == 0))
            }
        }
        // (Asked for none but the first, the first that is music, as `defaultSubsong` says.)
        let starting = first == 0 ? defaultSubsong : first
        if self.player.song != starting || self.player.measured != nil { try self.player.select(song: starting) }
        self.player.prepareToBeHeard()
        start()
    }

    deinit {
        left.deallocate()
        right.deallocate()
        parts.deallocate()
        heardParts.deallocate()
        ownParts.deallocate()
    }

    /// The voices left out of the sound, which the sound started afresh is started without.
    private var muted: [Bool] = []

    package func setMuted(_ muted: [Bool]) {
        self.muted = muted
        applyMutes()
    }

    private func applyMutes() {
        if sevenVoices {
            // Paula's fourth plays the four mixed, which are left out of the mixing each for itself.
            paula.setMuted((0 ..< 4).map { $0 < 3 && $0 < muted.count && muted[$0] })
            for v in 0 ..< 4 { mixer.voices[v].muted = v + 3 < muted.count && muted[v + 3] }
        } else if let own {
            // Paula's three as the voices they are shown as; the one that plays the mixing is heard, and
            // the mixed voices are left out of it by the player, each for itself.
            paula.setMuted((0 ..< 4).map { own.shown[$0] >= 0 && own.shown[$0] < muted.count && muted[own.shown[$0]] })
            for v in 0 ..< own.voices { player.setMixedMuted(v, 3 + v < muted.count && muted[3 + v]) }
        } else {
            paula.setMuted(muted)
        }
    }

    /// Where Paula keeps each voice's sound for its scope, at her own rate, once asked.
    private var waves: ChannelWaves?

    package func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            let made = ChannelWaves(voices: channelCount, rate: Double(outputSampleRate * 2), fullSwing: 1)
            if sevenVoices {
                for v in 3 ..< 7 { made.setVoice(v, rate: Paula.clockHz / Double(style.period), fullSwing: 1) }
            }
            if let own {
                for v in 0 ..< own.voices { made.setVoice(3 + v, rate: Paula.clockHz / Double(own.period), fullSwing: 1) }
            }
            waves = made
            paula.waves = made
            if sevenVoices { paula.waveNumbers = [0, 1, 2, -1] }
            if let own { paula.waveNumbers = own.shown }
        }
        return waves
    }

    package func select(subsong: Int) {
        if player.measured != nil, songs.indices.contains(subsong), songs[subsong].pending {
            try? measure(through: subsong)
            noteMeasured()
        }
        try? player.select(song: subsong)
        player.prepareToBeHeard()
        start()
    }

    /// The song the player starts with, which a player that plays its songs through when asked plays
    /// through first (`measure(through:)`).
    private let measuredFirst: Int

    /// Has a player that plays its songs through when asked play each song up to `song` through that
    /// it has not, in order: the one it starts with first, and then the rest from the first, as every
    /// load of the file does. So each is played through after the same others, and comes out the same
    /// length whichever is asked for first: what one comes to can depend on how much was played
    /// before it (how much of the dry runs' budget is left, and what the others were found to do).
    private func measure(through song: Int) throws(TuneError) {
        guard let measured = player.measured else { return }
        if measured[measuredFirst] == nil { try player.measure(measuredFirst) }
        for earlier in 0 ... min(song, measured.count - 1) where measured[earlier] == nil { try player.measure(earlier) }
    }

    /// What the player has found of its songs, as `songs` says it.
    private func noteMeasured() {
        guard let measured = player.measured else { return }
        songs = measured.map { found in
            guard let found else { return SongInfo(pending: true) }
            let length = found.map { Double($0) / Paula.clockHz }
            return SongInfo(length: length, empty: length == 0)
        }
    }

    package var songMeasures: SongMeasures? {
        guard let measured = player.measured, !measured.contains(where: { $0 == nil }) else { return nil }
        return SongMeasures(lengths: measured.map { $0 ?? nil })
    }

    package func adopt(_ measures: SongMeasures) {
        guard let measured = player.measured, measures.lengths.count == measured.count else { return }
        player.adopt(measures.lengths)
        noteMeasured()
    }

    /// Starts the song selected from its beginning, on a Paula started afresh.
    private func start() {
        let memory = UnsafeRawPointer(player.memory).assumingMemoryBound(to: Int8.self)
        paula = Paula(rate: Double(outputSampleRate * 2), model: model, memory: memory, size: player.memoryCapacity,
                      silence: player.silenceAt)
        paula.waves = waves
        if sevenVoices { paula.waveNumbers = [0, 1, 2, -1] }
        if let own { paula.waveNumbers = own.shown }
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
        startsLater = 0
        timedFrom = nil
        if let own {
            // What is mixed first is heard after Paula has played the silence before it.
            for v in 0 ..< own.voices { (ownParts + v * Self.ownSpace).update(repeating: 0, count: own.leadBytes) }
            ownPending = own.leadBytes
            ownClocks = 0
            ownLevels = InlineArray(repeating: 0)
            paulaNotes.clear()
        }
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
            if own != nil, !stopped { keepOwnParts(clocks: clocks) }
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
        if let first = timedFrom {
            // The tick's sound up to each moment something is told Paula, and then the rest of it.
            timedFrom = nil
            let total = tickFrames * 2
            var made = 0
            for event in output.events[first...] {
                if case let .at(clocks) = event {
                    let upTo = min(total, max(made, Int(Int64(clocks) * Int64(outputSampleRate * 2) / Int64(Self.chipClock))))
                    paula.generate(left: left + made, right: right + made, count: upTo - made)
                    made = upTo
                } else {
                    tell(event)
                }
            }
            paula.generate(left: left + made, right: right + made, count: total - made)
        } else if startsLater != 0 {
            // The tick's sound up to where the player's notes begin, and then the rest of it.
            let before = min(tickFrames * 2, noteClocks * outputSampleRate * 2 / Self.chipClock)
            paula.generate(left: left, right: right, count: before)
            for v in 0 ..< 4 where startsLater & 1 << UInt16(v) != 0 && !paula.isPlaying(v) {
                paula.start(voices: 1 << UInt16(v))
            }
            startsLater = 0
            paula.generate(left: left + before, right: right + before, count: tickFrames * 2 - before)
        } else {
            paula.generate(left: left, right: right, count: tickFrames * 2)
        }
        if let own {
            takeOwnNotes(own)
        } else {
            paula.takeLevels(into: &levels.now)
            paula.takeNotes(into: &notes)
        }
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
        for (index, event) in output.events.enumerated() {
            switch event {
            case .at:
                // (The rest is done as the tick is made.)
                timedFrom = index
            case .period, .volume, .filter:
                tell(event)
            case let .on(v):
                if v < paulaVoices, noteClocks > 0, !sevenVoices, own?.onto != v {
                    // (Started later in the tick, as the player's write that starts it falls.)
                    startsLater |= 1 << UInt16(v)
                } else if v < paulaVoices {
                    if !paula.isPlaying(v) { paula.start(voices: 1 << UInt16(v)) }
                } else if sevenVoices, v < 7 {
                    mixer.voices[v - 3].on = true
                }
            case let .off(v):
                if v < paulaVoices {
                    paula.stop(voices: 1 << UInt16(v))
                    startsLater &= ~(1 << UInt16(v))
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
            if timedFrom != nil { break }
        }
        // The Amiga's filter, as the player has left it.
        paula.setLightFilter(player.lightFilter)
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

    /// Does what a player on an emulated Amiga told Paula, as it falls in the tick (see
    /// `TFMXOutput.timed(at:)`): as her registers do.
    private func tell(_ event: TFMXTickOutput.Event) {
        switch event {
        case let .on(v):
            if v < 4, !paula.isPlaying(v) { paula.start(voices: 1 << UInt16(v)) }
        case let .off(v):
            if v < 4 { paula.stop(voices: 1 << UInt16(v)) }
        case let .buffer(v, start, length):
            if v < 4 {
                paula.setLocation(v, start)
                paula.setLength(v, length)
            }
        case let .period(v, period):
            if v < 4 { paula.setPeriod(v, period) }
        case let .volume(v, volume):
            if v < 4 { paula.setVolume(v, volume) }
        case let .filter(on):
            paula.setLightFilter(on)
        case .at:
            break
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
            // (A muted voice's light is as if it were heard, as every voice's is: see `Renderer.setMuted`.)
            mixedLevels[v] = min(1, (high - low) * 0.5)
        }
    }

    private var mixedLevels = InlineArray<4, Float>(repeating: 0)

    /// Takes the parts of what the player has just mixed of its own voices, and keeps those Paula plays in
    /// the tick to come for their scopes and lights: all that was before them, and as much of them as
    /// she gets through, at the period she plays the mixing at.
    private func keepOwnParts(clocks: Int) {
        guard let own else { return }
        let count = min(player.mixedCount, Self.ownSpace - ownPending)
        if count > 0 {
            for v in 0 ..< own.voices {
                let into = ownParts + v * Self.ownSpace + ownPending
                for i in 0 ..< count { into[i] = player.mixedPart(v, at: i) }
            }
            ownPending += count
        }
        let whole = ownClocks + clocks
        let heard = whole / own.period
        ownClocks = whole % own.period
        let taken = min(heard, ownPending)
        for v in 0 ..< own.voices {
            let part = ownParts + v * Self.ownSpace
            var low: Float = 0, high: Float = 0
            for i in 0 ..< taken {
                low = min(low, part[i])
                high = max(high, part[i])
                waves?.store(3 + v, at: i, part[i])
            }
            if heard > taken { for i in taken ..< heard { waves?.store(3 + v, at: i, 0) } }
            waves?.advance(3 + v, by: heard)
            ownLevels[v] = min(1, (high - low) * 0.5)
            if taken < ownPending { part.update(from: part + taken, count: ownPending - taken) }
        }
        ownPending -= taken
    }

    /// What Paula's three and the voices the player mixes itself sound like and are playing, in the order
    /// they are shown.
    private func takeOwnNotes(_ own: PaulaOwnMixing) {
        paula.takeLevels(into: &paulaLevels)
        paula.takeNotes(into: &paulaNotes)
        for p in 0 ..< 4 where own.shown[p] >= 0 {
            let shown = own.shown[p]
            levels.now[shown] = paulaLevels[p]
            notes.pitches[shown] = paulaNotes.pitches[p]
            if paulaNotes.struck[p] { notes.struck[shown] = true }
        }
        for p in 0 ..< 4 { paulaNotes.struck[p] = false }
        for v in 0 ..< own.voices {
            levels.now[3 + v] = ownLevels[v]
            let period = player.mixedPeriod(v)
            notes.pitches[3 + v] = period > 0 ? ChannelPitch.note(ofRate: Paula.clockHz / Double(period)) : 0
            if player.takeMixedStruck(v) { notes.struck[3 + v] = true }
        }
    }

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

    package func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
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

    /// Paula's four voices; or for TFMX 7V her first three and the four mixed onto her fourth; or for a
    /// player that mixes voices itself her other three and those (see `PaulaOwnMixing`).
    package var channelCount: Int { sevenVoices ? 7 : own.map { 3 + $0.voices } ?? 4 }

    package func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        if let own {
            for p in 0 ..< 4 where own.shown[p] >= 0 && own.shown[p] < 3 { sides[own.shown[p]] = Paula.side(ofVoice: p) }
            for v in 0 ..< own.voices { sides[3 + v] = Paula.side(ofVoice: own.onto) }
            return
        }
        for voice in 0 ..< channelCount { sides[voice] = Paula.side(ofVoice: min(voice, 3)) }
    }

    package func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    package func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }
}
