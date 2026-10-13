// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from it2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// An IT file, Impulse Tracker's kind of module, played by Impulse Tracker's replayer.
///
/// Impulse Tracker's own sound drivers were for the cards of its day and play neither a stereo
/// sample nor, most of them, a filter. The driver here is the one the port this is made from adds to
/// them: it mixes in floating point through a windowed sinc, ramps volumes, and has the resonant
/// filter, with the wider range ModPlug Tracker gave it where a file asks for that.
public final class ITRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var endsByLooping: Bool { true }
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length, empty: $0.empty) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    let module: IT2Module
    let songList: [ModuleSongs.Song]
    /// Which song first played each row. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>
    private let mono: Bool
    private var player: IT2Player
    private var tickFrames = 0, tickPosition = 0
    private var started = false
    /// For the lights: which of the 64 channels some pattern has a note on, in order.
    private let lights: [Int]
    /// For each of those, whether the first instrument its patterns give it is a sample, and not one
    /// of OpenMPT's FM instruments: what the channel is taken to play until it has played something.
    private let startsWithSamples: [Bool]

    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// Set by measure, so that a module is about as loud as the chip tunes it is played among.
    private static let gain: Float = 0.64
    /// That, by what an MPTM file's own settings make of it: see `OpenMPTSong`.
    private let gain: Float

    public convenience init(_ data: [UInt8], options: LoadOptions) throws {
        try self.init(module: IT2Module(data), format: "IT", options: options)
    }

    /// A module as Impulse Tracker holds one, wherever it came from: an IT file, or a file of another
    /// tracker's that this replayer is to play (see `IT2ForeignModule`), which says what kind it is.
    /// - Parameter shortfalls: for a module of another tracker's, what its loader left out or made do
    ///   for; nil for an IT file, which is looked over here for what later trackers added to it.
    init(module: IT2Module, format: String, author: String = "", shortfalls: [String]? = nil, options: LoadOptions) {
        self.module = module
        // (An MPTM file says how loud it is; an IT file of ModPlug Tracker's or OpenMPT's is as loud as OpenMPT has it.)
        gain = module.openMPT.map { Self.gain * $0.gain } ?? Self.gain * IT2Mixer.modPlugLevel(of: module)
        mono = options.stereo == .mono

        // The channels that some pattern has a note or an instrument on, and that are not switched off.
        // And for each, the first instrument a pattern gives it and the note it is given with: by
        // that, a channel is known for one of samples or of FM before it has played anything.
        var used = [Bool](repeating: false, count: 64)
        var first = [(note: UInt8, instrument: UInt8)?](repeating: nil, count: 64)
        var notes = [UInt8](repeating: 60, count: 64)
        for index in 0 ..< module.patternLimit where module.hasPattern(index) {
            let pattern = module.pattern(index)
            var masks = [UInt8](repeating: 0, count: 64)
            var at = 0, row = 0
            while row < Int(pattern.rows), at < pattern.data.count {
                let what = pattern.data[at]
                at += 1
                if what == 0 {
                    row += 1
                    continue
                }
                let channel = (Int(what & 0x7F) - 1) & 63
                if what & 0x80 != 0, at < pattern.data.count {
                    masks[channel] = pattern.data[at]
                    at += 1
                }
                // A note or an instrument, given here or said to be the same as last time.
                if masks[channel] & 0x33 != 0 { used[channel] = true }
                if masks[channel] & 1 != 0, at < pattern.data.count, pattern.data[at] < 120 { notes[channel] = pattern.data[at] }
                let after = at + (masks[channel] & 1 != 0 ? 1 : 0)
                if masks[channel] & 2 != 0, after < pattern.data.count, pattern.data[after] != 0, first[channel] == nil {
                    first[channel] = (notes[channel], pattern.data[after])
                }
                at += (masks[channel] & 1 != 0 ? 1 : 0) + (masks[channel] & 2 != 0 ? 1 : 0) + (masks[channel] & 4 != 0 ? 1 : 0)
                    + (masks[channel] & 8 != 0 ? 2 : 0)
            }
        }
        let places = module.ChnlPan
        lights = (0 ..< 64).filter { used[$0] && places[$0] & 128 == 0 }
        startsWithSamples = lights.map { channel in
            guard let (note, instrument) = first[channel] else { return true }
            let sample = module.usesInstruments ? Int(module.instrument(Int(instrument) - 1).SmpNoteTable[Int(note)] >> 8) : Int(instrument)
            return module.sample(sample - 1)?.AdLib == nil
        }

        var info = TuneInfo(format: format)
        info.title = module.title
        info.author = author
        info.detail = module.madeWith
        info.shortfalls = shortfalls ?? module.shortfalls()
        self.info = info

        // Once through each of its songs in silence, to find how long it is.
        let module = module
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: IT2Player.rowsInAll(of: module))
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: IT2Player.rowsInAll(of: module))
        self.firstPlayedBy = firstPlayedBy
        songList = ModuleSongs.find(places: module.Orders.count, isPattern: { Int(module.Orders[$0]) < module.patternLimit }) { start, number in
            let player = IT2Player(module, order: start, firstPlayedBy: firstPlayedBy, songNumber: number)
            var frames = 0, ticks = 0
            var watch = ModuleSongs.Watch()
            while ticks < Self.mostTicks {
                player.Update()
                if watch.tick(frames: frames, playedNote: player.playedNote, ledIntoEarlierSong: player.ledIntoEarlierSong) { break }
                if player.cameRound, ticks > 0 { break }
                frames += player.mixer.skipTick()
                ticks += 1
            }
            let length = ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
            return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: watch.sounded(player.playedNote),
                                    leadIn: watch.leadIn)
        }
        player = IT2Player(module)
        currentSubsong = defaultSubsong
        restart()
    }

    deinit {
        firstPlayedBy.deallocate()
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    /// - Parameter asImpulseTracker: as the player this is ported from plays the file, for `renderRaw`.
    private func restart(asImpulseTracker: Bool = false) {
        let song = songList[currentSubsong]
        player = IT2Player(module, order: song.start, firstPlayedBy: firstPlayedBy, songNumber: song.number, asImpulseTracker: asImpulseTracker, forSound: true)
        tickFrames = 0
        tickPosition = 0
        loopCount = 0
        started = false
    }

    private func nextTick() {
        player.Update()
        if player.cameRound, started { loopCount += 1 }
        started = true
        tickFrames = player.mixer.mixTick()
        tickPosition = 0
    }

    public var channelCount: Int { lights.count }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 64) { allPitches in
            withUnsafeTemporaryAllocation(of: Bool.self, capacity: 64) { allStruck in
                guard let allPitches = allPitches.baseAddress, let allStruck = allStruck.baseAddress else { return }
                player.mixer.notes.take(pitches: allPitches, struck: allStruck)
                for light in lights.indices {
                    pitches[light] = allPitches[lights[light]]
                    struck[light] = allStruck[lights[light]]
                }
            }
        }
    }

    /// A channel plays samples, unless what it has hold of is one of OpenMPT's FM instruments.
    public func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>) {
        for light in lights.indices { sampled[light] = player.mixer.sampled[lights[light]] ?? startsWithSamples[light] }
    }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for light in lights.indices { sides[light] = player.mixer.sides[lights[light]] }
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        // The mixer has all 64 channels; the ones in use are picked out of them.
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 64) { all in
            guard let all = all.baseAddress else { return }
            player.mixer.levels.take(into: all)
            for light in lights.indices { levels[light] = all[lights[light]] }
        }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            let out = buffer + done * 2
            player.mixer.postMix(into: out, from: tickPosition, count: count)
            if mono {
                for i in 0 ..< count {
                    let both = (out[i * 2] + out[i * 2 + 1]) * (gain * 0.5)
                    out[i * 2] = both
                    out[i * 2 + 1] = both
                }
            } else {
                for i in 0 ..< count * 2 { out[i] *= gain }
            }
            tickPosition += count
            done += count
        }
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn. For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        restart(asImpulseTracker: true)
        var output = [Int16](repeating: 0, count: frames * 2)
        var done = 0
        output.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            while done < frames {
                nextTick()
                let count = min(frames - done, tickFrames)
                player.mixer.postMix(into: base + done * 2, from: 0, count: count)
                done += count
            }
        }
        restart()
        return output
    }
}
