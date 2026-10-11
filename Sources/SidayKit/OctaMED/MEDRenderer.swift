// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after MODRenderer, whose way with the sound chip's output is derived from pt2-clone,
// Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence (see THIRD-PARTY.md).

/// A MED file: a module made with MED or OctaMED on the Amiga, played as OctaMED's own player
/// played it.
///
/// OctaMED had three ways of playing, and a song says which it wants. With four tracks, or with
/// five to eight mixed in pairs, it is played on an emulation of the Amiga's sound chip, and as
/// with any module for the Amiga the two sides are brought most of the way together (see
/// `MODRenderer`). In mixing mode, where any number of tracks are mixed for whatever is there to
/// play them, there is no Amiga in it: the song says where each track lies between left and
/// right, and that is where it is put (see `MEDMixer`).
///
/// A file may hold several songs, and they are all its songs here. Each is also looked through as a
/// module of any other kind is, for tunes that playing from its top never reaches.
public final class MEDRenderer: Renderer {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(title: module.songs[$0.song].title, length: $0.length, empty: $0.empty) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }
    public var hasEnded: Bool { player.stopped }
    public var isPlayedOnAnAmiga: Bool { player.mode != .mixing }

    /// One of the songs: which of the file's own it is in, and where in that one's order it starts.
    private struct Song {
        var song: Int
        var place: Int?
        var number: UInt8
        var length: Double?
        var empty: Bool
    }

    private let module: MEDModule
    private let songList: [Song]
    /// Which song first played each line, for each of the file's own songs. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>
    private let firstRowOfSong: [Int]
    private let model: AmigaModel
    /// How much of the difference between the two sides is kept, halved: none of it for mono.
    private let side: Float
    private let mono: Bool
    private var player: MEDPlayer
    /// One tick of sound: made at twice the rate, then brought down where it lies.
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    private var levels = TickLevels(voices: 4)
    private var notes = TickNotes(voices: 4)
    /// How many lights the song that is playing has: one for each track that can be heard.
    private var lights = 4

    /// For comparing with OctaMED's own player only: true to have a song in mixing mode played
    /// with that player's mistakes, which are otherwise put right (see `MEDPlayer.playAsOctaMEDs`).
    /// The song starts again.
    public var makesOctaMEDsMistakes = false {
        didSet { restart() }
    }
    private var down = (HalfBand(), HalfBand())
    /// The part of a sample that ticks are over by, carried from tick to tick: in samples times the
    /// sound chip's clock.
    private var remainder = 0
    /// What the tick's length was last divided by: the remainder is of that.
    private var remainderOf = 0
    /// In mixing mode a tick's sound is made a piece at a time, as it is asked for: where in the
    /// tick the piece that has been made begins, and how long it is.
    private var pieceStart = 0, pieceFrames = 0

    /// The sound chip's clock, in whole cycles a second.
    private static let clock = Int(Paula.clockHz)
    /// The longest a tick can be, at twice the output's rate, and some to spare.
    /// (Worked out in 64 bits, as a tick's length is below: clocks times samples is more than the 32
    /// that a whole number has in a browser can hold.)
    private static let tickSpace = Int(Int64(MEDPlayer.longestTick) * Int64(outputSampleRate) * 2 / Int64(clock)) + 64
    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// As loud as a MOD file, which is played on the same chip. See `MODRenderer`.
    private static let gain: Float = 0.26
    /// And for a song in mixing mode, which has no chip: by measure, over the songs there were to
    /// measure, as loud as MOD files are.
    private static let mixingGain: Float = 0.58

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try MEDModule(data)
        model = options.amigaModel
        side = options.stereo == .mono ? 0 : Float(max(0, min(1, options.amigaSeparation))) * 0.5
        mono = options.stereo == .mono
        try Self.refuseWhatIsNotPlayed(module)

        var info = TuneInfo(format: "MED")
        info.title = module.songs[0].title
        info.comment = module.comment
        info.detail = "MMD\(module.songs[0].version)"
        info.shortfalls = Self.shortfalls(of: module)
        self.info = info

        // Once through each of its songs in silence, to find how long it is, and to find the songs
        // that each of the file's own has in it.
        let module = module, model = model
        var firstRowOfSong: [Int] = []
        var rows = 0
        for song in module.songs {
            firstRowOfSong.append(rows)
            rows += max(1, song.rowsInAll)
        }
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: rows)
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: rows)
        self.firstPlayedBy = firstPlayedBy
        self.firstRowOfSong = firstRowOfSong
        var songList: [Song] = []
        for (index, song) in module.songs.enumerated() {
            let table = firstPlayedBy + firstRowOfSong[index]
            let sequences = song.sequences, sections = song.sections, places = song.places, blocks = song.blocks.count
            let found = ModuleSongs.find(places: places.count, isPattern: { place in
                Int(sequences[sections[places[place].section]][places[place].position]) < blocks
            }) { start, number in
                // (The song from the top of the order starts where the file says, which is the top
                // unless it says otherwise.)
                var player = MEDPlayer(module, song: index, model: model, place: start == 0 ? nil : start, firstPlayedBy: table, songNumber: number)
                var frames = 0, ticks = 0
                var remainder = 0, remainderOf = 0
                var watch = ModuleSongs.Watch()
                while ticks < Self.mostTicks {
                    let more = player.runTick()
                    frames += Self.tickLength(player.tickTime, &remainder, &remainderOf)
                    ticks += 1
                    if watch.tick(frames: frames, playedNote: player.playedNote, ledIntoEarlierSong: player.ledIntoEarlierSong) { break }
                    if !more || player.stopped { break }
                }
                let length = ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
                return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: watch.sounded(player.playedNote),
                                        leadIn: watch.leadIn)
            }
            for one in found {
                songList.append(Song(song: index, place: one.start == 0 ? nil : one.start, number: one.number, length: one.length, empty: one.empty))
            }
        }
        self.songList = songList
        left = .allocate(capacity: Self.tickSpace)
        right = .allocate(capacity: Self.tickSpace)
        player = MEDPlayer(module, song: 0, model: model)
        currentSubsong = defaultSubsong
        restart()
    }

    deinit {
        left.deallocate()
        right.deallocate()
        firstPlayedBy.deallocate()
    }

    /// Says no to a module that needs what this player has not got, and why. A sound that no note
    /// in the module asks for does not count against it.
    private static func refuseWhatIsNotPlayed(_ module: MEDModule) throws {
        for song in module.songs {
            var used = [Bool](repeating: false, count: MEDModule.mostInstruments)
            for block in song.blocks {
                for i in 0 ..< block.tracks * block.lines {
                    let instrument = Int(module.cells[block.firstCell + i].instrument)
                    if instrument >= 1, instrument <= MEDModule.mostInstruments { used[instrument - 1] = true }
                }
            }
            for (i, instrument) in song.instruments.enumerated() where used[i] {
                if instrument.sixteenBit, song.mode != .mixing {
                    throw TuneError.unsupported("an OctaMED module with a sixteen-bit sample, which the Amiga's own four voices cannot play")
                }
                switch instrument.kind {
                case .absent, .sample, .octaves, .extended, .synthetic:
                    break
                case .unknown:
                    throw TuneError.unsupported("an OctaMED module with an instrument of a kind this player does not know")
                }
            }
        }
    }

    /// What a module asks for that is played without it, or in a way that could not be made sure
    /// of: see `TuneInfo.shortfalls`. Like `refuseWhatIsNotPlayed`, it goes by what the notes ask for.
    private static func shortfalls(of module: MEDModule) -> [String] {
        var midi = 0, forCard = 0, unchecked = 0
        var counted = [Bool](repeating: false, count: MEDModule.mostInstruments)
        for song in module.songs {
            var used = [Bool](repeating: false, count: MEDModule.mostInstruments)
            for block in song.blocks {
                for i in 0 ..< block.tracks * block.lines {
                    let instrument = Int(module.cells[block.firstCell + i].instrument)
                    if instrument >= 1, instrument <= MEDModule.mostInstruments { used[instrument - 1] = true }
                }
            }
            for (i, instrument) in song.instruments.enumerated() where used[i] && !counted[i] {
                if instrument.kind == .absent, instrument.midiChannel != 0 {
                    // Its notes went out of the Amiga to a synthesiser, and there is no sample to play.
                    midi += 1
                    counted[i] = true
                } else if instrument.kind != .absent, instrument.outputDevice != 0, song.mode != .mixing {
                    forCard += 1
                    counted[i] = true
                }
            }
            // Five tracks, six or seven: how those are mixed could not be set beside OctaMED's own
            // mixing of them, as the mixing of eight was.
            if song.mode == .eightChannel, song.mixed.contains(false) { unchecked = max(unchecked, 4 + song.mixed.filter { $0 }.count) }
        }
        var sentences: [String] = []
        if midi > 0 {
            sentences.append(Shortfall.some(midi, one: "instruments is for a MIDI synthesiser, and is not heard.", many: "instruments are for a MIDI synthesiser, and are not heard."))
        }
        if forCard > 0 {
            sentences.append(Shortfall.some(forCard, one: "instruments is for a sound card, and is not heard.", many: "instruments are for a sound card, and are not heard."))
        }
        if unchecked > 0 {
            sentences.append("Its \(Shortfall.number(unchecked)) tracks are mixed into the Amiga's four voices in a way that could not be checked against OctaMED.")
        }
        if let sentence = module.songs[0].cutShort.sentence { sentences.append(sentence) }
        return sentences
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    private func restart() {
        let song = songList[currentSubsong]
        player = MEDPlayer(module, song: song.song, model: model, place: song.place, firstPlayedBy: firstPlayedBy + firstRowOfSong[song.song],
                           songNumber: song.number)
        if makesOctaMEDsMistakes { player.playAsOctaMEDs() }
        down = (HalfBand(), HalfBand())
        tickFrames = 0
        tickPosition = 0
        // A light for each track that can be heard: of a song in mixing mode, no more than its
        // widest block has.
        lights = player.mode == .mixing ? max(1, min(player.channels, module.songs[song.song].blocks.map { $0.tracks }.max() ?? 4)) : player.channels
        levels = TickLevels(voices: lights)
        notes = TickNotes(voices: lights)
        remainder = 0
        remainderOf = 0
        pieceStart = 0
        pieceFrames = 0
        loopCount = 0
    }

    /// How many samples a tick lasts that is so many of such a part of a second. What is over is
    /// kept for the next tick, for as long as ticks are counted in the same parts.
    private static func tickLength(_ time: (count: Int, per: Int), _ remainder: inout Int, _ remainderOf: inout Int) -> Int {
        if time.per != remainderOf {
            remainder = 0
            remainderOf = time.per
        }
        let whole = Int64(time.count) * Int64(outputSampleRate) + Int64(remainder)
        remainder = Int(whole % Int64(max(1, time.per)))
        return Int(whole / Int64(max(1, time.per)))
    }

    /// Runs the player for a tick, unless the tune has stopped it, and makes the sound of that tick.
    private func nextTick() {
        if !player.runTick() { loopCount += 1 }
        tickFrames = Self.tickLength(player.tickTime, &remainder, &remainderOf)
        tickPosition = 0
        pieceStart = 0
        pieceFrames = 0
        if player.mode == .mixing {
            // The tick's sound is made as it is asked for (a tick can be seconds long here).
            player.mixer.takeLevels(into: &levels.now)
            levels.tickMade()
            player.takeNotes(into: &notes)
            return
        }
        player.paula.generate(left: left, right: right, count: tickFrames)
        player.halfTick()
        player.paula.generate(left: left + tickFrames, right: right + tickFrames, count: tickFrames)
        player.takeLevels(into: &levels.now)
        levels.tickMade()
        player.takeNotes(into: &notes)
        for i in 0 ..< tickFrames {
            left[i] = down.0.step(left[i * 2], left[i * 2 + 1])
            right[i] = down.1.step(right[i * 2], right[i * 2 + 1])
        }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            if player.mode == .mixing {
                // Each track where the song puts it, and for mono the two sides as one.
                if tickPosition == pieceStart + pieceFrames {
                    pieceStart = tickPosition
                    pieceFrames = min(tickFrames - tickPosition, Self.tickSpace)
                    player.mixer.render(left: left, right: right, count: pieceFrames)
                }
                let count = min(frames - done, pieceStart + pieceFrames - tickPosition)
                let from = tickPosition - pieceStart
                for i in 0 ..< count {
                    let l = left[from + i] * Self.mixingGain, r = right[from + i] * Self.mixingGain
                    buffer[(done + i) * 2] = mono ? (l + r) * 0.5 : l
                    buffer[(done + i) * 2 + 1] = mono ? (l + r) * 0.5 : r
                }
                tickPosition += count
                done += count
                continue
            }
            let count = min(frames - done, tickFrames - tickPosition)
            for i in 0 ..< count {
                let l = left[tickPosition + i], r = right[tickPosition + i]
                let middle = (l + r) * 0.5, apart = (l - r) * side
                buffer[(done + i) * 2] = (middle + apart) * Self.gain
                buffer[(done + i) * 2 + 1] = (middle - apart) * Self.gain
            }
            tickPosition += count
            done += count
        }
    }

    /// Paula's four voices, or the eight tracks that are mixed into them, or as many tracks as a
    /// song in mixing mode has.
    public var channelCount: Int { lights }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for track in 0 ..< lights {
            if player.mode == .mixing {
                // Where the song puts it.
                sides[track] = player.mixer.side(of: track)
            } else {
                // The Amiga's own sides, however near they are brought to one another here. (Of
                // eight tracks, the fifth shares the first's voice, and so on.)
                sides[track] = Paula.side(ofVoice: track)
            }
        }
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }

    /// What the player tells the mixer, in order, from the start of the song that is playing, for a
    /// song in mixing mode: for setting beside what OctaMED's own player mixes. The song is left at
    /// its start.
    public func mixEvents(seconds: Double, fileSong: Int? = nil) -> [MEDMixEvent] {
        if let fileSong, let song = songList.firstIndex(where: { $0.song == fileSong && $0.place == nil }) { currentSubsong = song }
        restart()
        guard player.mode == .mixing else { return [] }
        player.playAsOctaMEDs()
        player.mixer.events = []
        var time = 0.0
        while time < seconds, !player.stopped {
            _ = player.runTick()
            time += Double(player.tickTime.count) / Double(max(1, player.tickTime.per))
        }
        let events = player.mixer.events ?? []
        restart()
        return events
    }

    /// What the song that is playing says of its mixing, for the same purpose: how many channels,
    /// whether in stereo and with tracks placed freely, the percentage its volume is adjusted by,
    /// its echo (kind, depth, milliseconds), how far its sides are kept apart, whether its tempo
    /// is in beats a minute and how many lines make a beat.
    public var mixSettings: [Int] {
        let song = module.songs[songList[currentSubsong].song]
        return [song.channels, song.stereo ? 1 : 0, song.freePan ? 1 : 0, song.volumeAdjust, song.echo, song.echoDepth, song.echoLength,
                song.separation, song.beatsPerMinute ? 1 : 0, song.linesPerBeat]
    }

    /// What the player tells the sound chip, tick by tick, from the start of the song that is
    /// playing: for setting beside what OctaMED's own player tells it. The song is left at its start.
    /// - Parameter fileSong: which of the file's own songs to play from its top, counting from
    ///   nought, in place of the song that is playing.
    public func registerTicks(seconds: Double, fileSong: Int? = nil) -> [MEDRegisterTick] {
        if let fileSong, let song = songList.firstIndex(where: { $0.song == fileSong && $0.place == nil }) { currentSubsong = song }
        restart()
        player.record = MEDRegisterTick()
        var ticks: [MEDRegisterTick] = []
        var clocks = 0.0
        while clocks < seconds * Paula.clockHz, !player.stopped {
            _ = player.runTick()
            if let tick = player.record { ticks.append(tick) }
            clocks += Double(player.tickClocks)
        }
        restart()
        return ticks
    }
}
