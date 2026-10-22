// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st3play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

import SidayFoundation

/// An S3M file, Scream Tracker 3's kind of module, played by Scream Tracker's replayer on one of the
/// two sound cards it knew.
///
/// Which card matters: a tune written with a Gravis Ultrasound was heard smoothly mixed, and one
/// written with a Sound Blaster was heard in eight bits at 22 kHz. A file saved by Scream Tracker
/// says which it was saved with, and is played on that unless another is asked for.
///
/// Beside either there may be an AdLib card, for the channels of a tune that are FM and not samples.
public final class S3MRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var endsByLooping: Bool { true }
    /// A song that runs off the end of the list into another is over there: see `ST3Player.over`.
    public var hasEnded: Bool { player.over }
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(title: module.song(at: $0.start)?.title ?? "", length: $0.length, empty: $0.empty) } }
    public var knownLength: Double? { songList[currentSubsong].length }

    private let module: ST3Module
    private let card: ST3Card
    /// True if samples in stereo are played with their sides apart: see `ST3Module.playStereoSamples`.
    private let stereoApart: Bool
    private let mono: Bool
    /// One of the file's songs: where in the list of patterns it starts, how long it is, and whether
    /// it plays a note on the AdLib card at some point. The card is then mixed in from the start, so
    /// that the samples do not drop in volume at its first note.
    private struct Song {
        var start: Int
        var number: UInt8
        var length: Double?
        var empty: Bool
        var adLib: Bool
    }

    private let songList: [Song]
    /// Which song first played each row. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>
    private var usesAdLib: Bool { songList[currentSubsong].adLib }
    private var player: ST3Player
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    /// For the lights: the player's channels that the file's patterns use, in the patterns' order (the
    /// first sixteen are the sound card's and the nine after them the AdLib's), and room for the
    /// levels of them all. A tick is made whole and heard as it is given out, which may be over
    /// several calls to `render`. So the tick is made a `piece` at a time, and each voice's level in
    /// each piece is kept, `pieceLevels`, as are its pitch and whether a note is struck on it in the
    /// tick; and the lights are of the pieces given out since they were last asked for, `heard`, and
    /// not of what has been made.
    /// (The levels are kept in plain memory, being written at every piece.)
    private let lights: [Int]
    private let lightChannels: UnsafeMutablePointer<Int>
    private let pieceLevels: UnsafeMutablePointer<Float>, heard: UnsafeMutablePointer<Float>
    private var tickPitches: [Float], tickStruck: [Bool]
    /// How many of the player's frames each piece of a tick is.
    private static let piece = 128
    private let channelLevels: UnsafeMutablePointer<Float>
    private var notes: TickNotes
    private var channelPitches = [Float](repeating: 0, count: 25)
    /// The part of a sample that ticks are over by, in 2^-32s, carried from tick to tick.
    private var remainder: UInt64 = 0
    private var started = false
    // For `renderRaw`: the reference player's dither.
    private var seed: UInt32 = 0x1234_5000
    private var ditherLeft: Float = 0, ditherRight: Float = 0

    /// The slowest tempo is some nineteen ticks a second, and a tick is then some 2,500 samples.
    private static let tickSpace = 16384
    private static let mostTicks = 50 * 60 * 120
    /// Set by ear and by measure, so that a module is about as loud as the chip tunes it is played
    /// among, whichever card it is on: what a GUS puts out is half as loud again as a Sound Blaster.
    /// The samples are made quieter by a third to leave room for the AdLib card in sixteen bits;
    /// there is room to spare here, so with that card both are brought back up by as much.
    private var gain: Float { (card == .gus ? 0.34 : 0.5) * (usesAdLib ? 1.5 : 1) * loudness }
    /// And for a module of another tracker's, beside an S3M file on the same card.
    private let loudness: Float

    public convenience init(_ data: [UInt8], options: LoadOptions) throws {
        try self.init(data, options: options, card: nil)
    }

    /// - Parameters:
    ///   - card: the card to play it on; nil for the one the file was saved with, or the one asked for.
    ///   - format: for a module of another tracker's that has been read into an S3M file (see
    ///     `DSMFile`): what kind of file it was, and the tracker or player it was made for, its title,
    ///     what of it is not played, how loud it is beside an S3M file, whether it is played as a DSM
    ///     file is (see `ST3Module.playsAsDSIK`), and its songs, for a MASI file's (see `ST3Module.songs`).
    init(_ data: [UInt8], options: LoadOptions, card chosen: ST3Card?, format: String = "S3M", tracker: String? = nil, title: String? = nil,
         shortfalls: [String] = [], loudness: Float = 1, asDSIK: Bool = false, songs: [ST3Module.Song] = []) throws {
        module = try ST3Module(data)
        module.playsAsDSIK = asDSIK
        // (A channel in surround is heard in the middle when the two sides are heard as one, as it
        // would be lost if one of them were upside down.)
        module.songs = songs.map { song in
            var song = song
            if options.stereo == .mono { song.surround = song.surround.map { _ in false } }
            return song
        }
        self.loudness = loudness
        card = chosen ?? options.s3mCard ?? (module.savedWithSoundBlaster ? .sb : .gus)
        // Samples in stereo are played so on a Gravis Ultrasound, in a file that is in stereo.
        stereoApart = card == .gus && module.mastermul & 128 != 0
        module.playStereoSamples(asScreamTracker: false, apart: stereoApart)
        mono = options.stereo == .mono
        left = .allocate(capacity: Self.tickSpace)
        right = .allocate(capacity: Self.tickSpace)

        // The channels that some pattern has a note or an instrument on. Scream Tracker gives a new
        // tune sixteen, and most tunes leave some of them empty.
        var used = [Bool](repeating: false, count: 32)
        for case let pattern? in module.patp {
            var at = 0
            while at < pattern.count {
                let what = pattern[at]
                at += 1
                if what & 0x20 != 0 {
                    if at + 1 < pattern.count, pattern[at] < 254 || pattern[at + 1] != 0 { used[Int(what & 0x1F)] = true }
                    at += 2
                }
                if what & 0x40 != 0 { at += 1 }
                if what & 0x80 != 0 { at += 2 }
            }
        }
        var lights: [Int] = []
        let table = module.channelTable(laterTrackers: !module.madeByScreamTracker && card == .gus)
        for place in 0 ..< 32 where used[place] && table[place] & 128 == 0 {
            let channel = Int(table[place]) % ST3Player.ACHANNELS
            if channel <= 24 || channel >= ST3Module.firstExtraChannel, !lights.contains(channel) { lights.append(channel) }
        }
        self.lights = lights
        lightChannels = .allocate(capacity: max(1, lights.count))
        for light in lights.indices { lightChannels[light] = lights[light] }
        pieceLevels = .allocate(capacity: max(1, lights.count * (Self.tickSpace / Self.piece)))
        pieceLevels.initialize(repeating: 0, count: max(1, lights.count * (Self.tickSpace / Self.piece)))
        heard = .allocate(capacity: max(1, lights.count))
        heard.initialize(repeating: 0, count: max(1, lights.count))
        channelLevels = .allocate(capacity: ST3Player.ACHANNELS)
        channelLevels.initialize(repeating: 0, count: ST3Player.ACHANNELS)
        tickPitches = [Float](repeating: 0, count: lights.count)
        tickStruck = [Bool](repeating: false, count: lights.count)
        notes = TickNotes(voices: lights.count)

        // Once through each of its songs in silence, to find how long it is and whether the AdLib
        // card is in it.
        let module = module, card = card
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: ST3Player.rowsInAll)
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: ST3Player.rowsInAll)
        self.firstPlayedBy = firstPlayedBy
        var adLib = [Bool](repeating: false, count: ST3Module.mostOrders + 1)
        let found = ModuleSongs.find(places: module.ordnum, isPattern: { module.order[$0] < 254 }) { start, number in
            let player = ST3Player(module, card: card, order: start, firstPlayedBy: firstPlayedBy, songNumber: number)
            var frames = 0, ticks = 0
            var remainder: UInt64 = 0
            var watch = ModuleSongs.Watch()
            if !player.silent {
                while ticks < Self.mostTicks {
                    player.tick()
                    if watch.tick(frames: frames, playedNote: player.playedNote, ledIntoEarlierSong: player.ledIntoEarlierSong) { break }
                    if player.cameRound, ticks > 0 { break }
                    frames += Self.tickLength(player, &remainder)
                    ticks += 1
                }
            }
            adLib[start] = player.adlibused
            let length = ticks > 0 && ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
            return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: watch.sounded(player.playedNote),
                                    leadIn: watch.leadIn)
        }
        songList = found.map { Song(start: $0.start, number: $0.number, length: $0.length, empty: $0.empty, adLib: adLib[$0.start]) }
        player = ST3Player(module, card: card)

        var info = TuneInfo(format: format)
        info.title = title ?? module.title
        info.detail = (tracker.map { $0 + ", as Scream Tracker 3 plays it on a " } ?? "Scream Tracker 3, ")
            + (card == .gus ? "Gravis Ultrasound" : "Sound Blaster Pro") + (songList.contains { $0.adLib } ? " and AdLib" : "")
        let apart = stereoApart, stereoSentence = module.stereoSentence
        let played = card == .gus ? [module.reverbSentence, module.extraChannelsSentence] : []
        info.shortfalls = shortfalls + module.shortfalls.filter { (!apart || $0 != stereoSentence) && !played.contains($0) }
        self.info = info
        currentSubsong = defaultSubsong
        restart()
    }

    deinit {
        left.deallocate()
        right.deallocate()
        firstPlayedBy.deallocate()
        lightChannels.deallocate()
        pieceLevels.deallocate()
        heard.deallocate()
        channelLevels.deallocate()
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    /// The voices left out of the sound, which a song started afresh is started without.
    private var muted: [Bool] = []

    public func setMuted(_ muted: [Bool]) {
        self.muted = muted
        tellCardsOfMuted()
    }

    /// Tells the two cards which of their channels are left out. A voice here is one of the
    /// channels the tune uses (see `lights`): the sound card's are told to it, and the AdLib's to
    /// the chip, which leaves a voice out of what it gives out.
    private func tellCardsOfMuted() {
        var channels: UInt64 = 0
        for light in lights.indices where light < muted.count && muted[light] { channels |= 1 << UInt64(lights[light]) }
        player.cards.setMuted(channels & ~0x1FF_0000)
        player.adlib.setMuted(UInt32((channels >> 16) & 0x1FF))
    }

    /// Where the two cards keep each voice's sound for its scope, once asked: the sound card's at its
    /// own rate and the AdLib's at its chip's. A song started afresh keeps it there too.
    private var waves: ChannelWaves?

    public func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            // (Each voice is given its own rate and loudness by the card it is on.)
            waves = ChannelWaves(voices: lights.count, rate: Double(outputSampleRate), fullSwing: 1)
            tellCardsOfWaves()
        }
        return waves
    }

    /// Tells the two cards where to keep their voices' sound, and which voice each of their channels is.
    private func tellCardsOfWaves() {
        guard let waves else { return }
        var sampled: [(channel: Int, voice: Int)] = [], fm: [(channel: Int, voice: Int)] = []
        for light in lights.indices {
            if Self.isSampled(lights[light]) {
                sampled.append((lights[light], light))
            } else {
                fm.append((lights[light] - 16, light))
            }
        }
        player.cards.keepWaves(in: waves, voices: sampled)
        player.adlib.keepWaves(in: waves, voices: fm)
    }

    /// - Parameter asScreamTracker: as the player this is ported from plays the file, for `renderRaw`.
    private func restart(asScreamTracker: Bool = false) {
        let song = songList[currentSubsong]
        player = ST3Player(module, card: card, order: song.start, adlib: song.adLib && !ST3Player.repeatsReferenceSlips,
                           firstPlayedBy: firstPlayedBy, songNumber: song.number, asScreamTracker: asScreamTracker)
        tellCardsOfMuted()
        if !asScreamTracker { tellCardsOfWaves() }
        tickFrames = 0
        tickPosition = 0
        pieceLevels.update(repeating: 0, count: max(1, lights.count * (Self.tickSpace / Self.piece)))
        for light in lights.indices {
            heard[light] = 0
            tickPitches[light] = 0
            tickStruck[light] = false
        }
        notes.clear()
        remainder = 0
        loopCount = 0
        started = false
        seed = 0x1234_5000
        ditherLeft = 0
        ditherRight = 0
    }

    /// How many samples the tick just run lasts, at the tempo it left.
    private static func tickLength(_ player: ST3Player, _ remainder: inout UInt64) -> Int {
        var frames = Int(player.samplesPerTick >> 32)
        remainder += player.samplesPerTick & 0xFFFF_FFFF
        if remainder > 0xFFFF_FFFF {
            remainder &= 0xFFFF_FFFF
            frames += 1
        }
        return min(Self.tickSpace, max(1, frames))
    }

    private func nextTick() {
        player.tick()
        if player.cameRound, started { loopCount += 1 }
        started = true
        tickFrames = Self.tickLength(player, &remainder)
        tickPosition = 0
        // A channel of samples is at the pitch of its period, which is a fourteen-millionth of a
        // second for each sample, as the tick begins: a Sound Blaster's that comes to the end of its
        // sample in the tick is stopped by the time it is made. The AdLib's voices are at whatever
        // the chip has been told, which it takes up as it makes the tick.
        for light in lights.indices where Self.isSampled(lights[light]) {
            let ch = player.zchn[lights[light]]
            tickPitches[light] = ch.aspd > 0 && ch.m_speed != 0 ? ChannelPitch.note(ofRate: 14_317_056 / Double(ch.aspd)) : 0
        }
        // A piece at a time, which makes the same sound as the tick made at once: but ModPlug's reverb
        // is given the sound in blocks of its own, and so a tick that has it is made whole.
        let piece = player.cards.makesTheSameInPieces ? Self.piece : tickFrames
        var start = 0
        while start < tickFrames {
            let count = min(piece, tickFrames - start)
            player.cards.render(left: left + start, right: right + start, count: count, channels: player.zchn)
            if player.adlibused {
                player.adlib.render(left: left + start, right: right + start, count: count, sinc: player.cards.sinc)
            } else if waves != nil {
                player.adlib.keepSilence(count: count)
            }
            player.cards.takeLevels(into: channelLevels)
            player.adlib.takeLevels(into: channelLevels)
            // (A tick made whole has its levels in every piece.)
            let voices = lights.count
            for first in stride(from: start, to: start + count, by: Self.piece) {
                let base = first / Self.piece * voices
                for light in 0 ..< voices { pieceLevels[base + light] = channelLevels[lightChannels[light]] }
            }
            start += count
        }
        player.adlib.takePitches(into: &channelPitches)
        for light in lights.indices {
            let ch = player.zchn[lights[light]]
            if !Self.isSampled(lights[light]) { tickPitches[light] = channelPitches[lights[light]] }
            tickStruck[light] = ch.struck
            ch.struck = false
        }
    }

    /// So many frames of the tick last made are being given out from where it has got to: the levels
    /// of the pieces they are in are heard, and where it is begun, its pitches and the notes struck in it.
    private func tickHeard(_ count: Int) {
        for index in tickPosition / Self.piece ... (tickPosition + count - 1) / Self.piece {
            let base = index * lights.count
            for light in lights.indices where pieceLevels[base + light] > heard[light] { heard[light] = pieceLevels[base + light] }
        }
        guard tickPosition == 0 else { return }
        for light in lights.indices {
            notes.pitches[light] = tickPitches[light]
            if tickStruck[light] { notes.struck[light] = true }
        }
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }

    public var channelCount: Int { lights.count }

    /// The sound card's sixteen channels play samples, and the AdLib's nine are FM. (So do a later
    /// tracker's past the sixteen: see `ST3Module.extraChannels`.)
    public func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>) {
        for light in lights.indices { sampled[light] = Self.isSampled(lights[light]) }
    }

    private static func isSampled(_ channel: Int) -> Bool { channel < 16 || channel >= ST3Module.firstExtraChannel }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for light in lights.indices { sides[light] = player.cards.side(of: player.zchn[lights[light]]) }
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        for light in lights.indices {
            levels[light] = heard[light]
            heard[light] = 0
        }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        let gain = gain
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            tickHeard(count)
            if mono {
                for i in 0 ..< count {
                    let both = (left[tickPosition + i] + right[tickPosition + i]) * (gain * 0.5)
                    buffer[(done + i) * 2] = both
                    buffer[(done + i) * 2 + 1] = both
                }
            } else {
                for i in 0 ..< count {
                    buffer[(done + i) * 2] = left[tickPosition + i] * gain
                    buffer[(done + i) * 2 + 1] = right[tickPosition + i] * gain
                }
            }
            tickPosition += count
            done += count
        }
        // (A tick is made whole, and given out as it is asked for.)
        waves?.ahead = tickFrames - tickPosition
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn, with that player's dither. For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        // (That player has a sample in stereo as Scream Tracker has it: its left side alone.)
        module.playStereoSamples(asScreamTracker: true)
        defer {
            module.playStereoSamples(asScreamTracker: false, apart: stereoApart)
            restart()
        }
        restart(asScreamTracker: true)
        var output: [Int16] = []
        output.reserveCapacity(frames * 2)

        func dithered(_ sample: Float, _ state: inout Float) -> Int16 {
            seed = seed &* 134_775_813 &+ 1
            let noise = Float(Int32(bitPattern: seed)) * (1.0 / 4_294_967_296.0)
            let value = (sample * 32768.0 + noise) - state
            state = noise
            return Int16(max(-32768, min(32767, Int32(max(-1e9, min(1e9, value))))))
        }
        while output.count < frames * 2 {
            if tickPosition == tickFrames { nextTick() }
            while tickPosition < tickFrames, output.count < frames * 2 {
                output.append(dithered(left[tickPosition], &ditherLeft))
                output.append(dithered(right[tickPosition], &ditherRight))
                tickPosition += 1
            }
        }
        return output
    }
}
