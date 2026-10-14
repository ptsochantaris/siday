// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A DBM file, played by DigiBooster 3's own replayer (see `DBMPlayer`).
///
/// Each of a file's songs is looked through for more than one, as a module of any other kind is.
/// The sound is the replayer's sum of every track. It divides that by the number of tracks, so
/// that it can never be too loud, which makes a file of twenty tracks a sixth as loud as one of
/// four; DigiBooster Pro made up for the number of tracks itself, and so do OpenMPT and libxmp, and
/// so here every file is divided by eight, however many tracks it has.
public final class DBMRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.found.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(title: $0.title, length: $0.found.length, empty: $0.found.empty) } }
    public var knownLength: Double? { songList[currentSubsong].found.length }
    public var endsByLooping: Bool { true }
    /// A song that stops itself, or a song from part of the way down a list that has come to its end.
    public var hasEnded: Bool { player.stopped }

    private struct Song {
        /// Which of the file's songs it is part of, and where in that song's list it starts.
        var song: Int
        var found: ModuleSongs.Song
        var title: String
    }

    private let module: DBMModule
    private let songList: [Song]
    /// Each of the file's songs' rows: see `DBMPlayer.rowBase`.
    private let rowBases: [[Int]?]
    private let mono: Bool
    private var player: DBMPlayer
    /// The replayer's sums of a tick, left and right in turn.
    private let sums = Memory<Int32>(capacity: DBMPlayer.mostFrames * 2)
    private var tickFrames = 0, tickPosition = 0
    /// How far into the replayer's block of frames the sound is (see `mixTick`).
    private var blockPosition = 0
    /// True if the tick last made came to the end of one of those blocks.
    private var tickFilledBlock = false
    private var levels: TickLevels
    private var notes: TickNotes
    /// What the replayer multiplies its sums by, in 65,536ths: one over the number of tracks. (For
    /// `renderRaw`.)
    private let boost: Int64

    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// Set by measure, so that these files are about as loud as XM files are: what the sum of the
    /// tracks is multiplied by, as a part of the loudest a track can be.
    private static let gain: Float = 1.54 / 8
    /// How many frames the replayer's own example program asks of it at once. Whether a track that
    /// has come to the end of its sample goes on is settled once for each part of a tick that is
    /// asked for at once, so it is asked for in the same parts here.
    private static let block = 100_000

    public init(_ data: [UInt8], options: LoadOptions) throws {
        let module = try DBMModule(data)
        self.module = module
        mono = options.stereo == .mono
        var info = TuneInfo(format: "DBM")
        info.title = module.title
        info.detail = module.creator == 3 ? "DigiBooster 3" : "DigiBooster Pro"
        info.shortfalls = module.shortfalls
        self.info = info
        boost = ((Int64(1) << 32) / Int64(module.tracks)) >> 16
        levels = TickLevels(voices: module.tracks)
        notes = TickNotes(voices: module.tracks)

        // Once through each of its songs in silence, to find how long it is.
        var songList: [Song] = []
        rowBases = module.songs.indices.map { DBMPlayer.rowBase(module, song: $0) }
        // (However many songs a broken file says it has, all of them together are given no more
        // than a few times as long as one may take.)
        var budget = Self.mostTicks * 3
        for song in module.songs.indices {
            guard songList.count < ModuleSongs.most else { break }
            let rowBase = rowBases[song]
            let rows = rowBase?.last ?? 0
            let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, rows))
            firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: max(1, rows))
            defer { firstPlayedBy.deallocate() }
            let found = ModuleSongs.find(places: module.songs[song].orders.count, isPattern: { _ in true }) { start, number in
                let player = DBMPlayer(module, song: song, order: start, forSound: false, listEnd: start == 0 ? .goesRound : .stops,
                                       rowBase: rowBase, firstPlayedBy: firstPlayedBy, songNumber: number)
                var ticks = 0, frames = 0
                var watch = ModuleSongs.Watch()
                let most = min(Self.mostTicks, budget)
                while ticks < most {
                    let more = player.runTick()
                    if watch.tick(frames: frames, playedNote: player.playedNote, ledIntoEarlierSong: player.ledIntoEarlierSong) { break }
                    if !more || player.stopped { break }
                    ticks += 1
                    frames += player.tickSamples
                }
                budget -= ticks
                let length = ticks < most ? Double(frames) / Double(outputSampleRate) : nil
                return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: watch.sounded(player.playedNote), leadIn: watch.leadIn)
            }
            for one in found.prefix(ModuleSongs.most - songList.count) {
                // (A file's songs have names; the songs found part of the way down one have its name too.)
                songList.append(Song(song: song, found: one, title: module.songs.count > 1 ? module.songs[song].name : ""))
            }
        }
        self.songList = songList
        player = DBMPlayer(module, song: 0)
        currentSubsong = defaultSubsong
        restart()
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    /// The tracks left out of the sound, which a song started afresh is started without.
    private var muted: [Bool] = []

    public func setMuted(_ muted: [Bool]) {
        self.muted = muted
        for (index, track) in player.tracks.enumerated() { track.muted = index < muted.count && muted[index] }
    }

    /// - Parameter asReplayer: as the replayer's own example program plays the file, for `renderRaw`.
    private func restart(asReplayer: Bool = false) {
        let song = songList[currentSubsong]
        let start = song.found.start
        player = DBMPlayer(module, song: song.song, order: start, listEnd: asReplayer ? .stopsAsReplayer : start == 0 ? .goesRound : .stops,
                           asTheFileAsks: !asReplayer, rowBase: rowBases[song.song])
        setMuted(muted)
        tickFrames = 0
        tickPosition = 0
        blockPosition = 0
        levels.clear()
        notes.clear()
        loopCount = 0
    }

    /// Runs the player for a tick, and mixes the sound of that tick: in two parts, if the tick runs
    /// over the end of one of the replayer's blocks.
    private func mixTick() {
        if !player.runTick() { loopCount += 1 }
        tickFrames = min(DBMPlayer.mostFrames, player.tickSamples)
        tickPosition = 0
        for i in 0 ..< tickFrames * 2 { sums.pointer[i] = 0 }
        for voice in levels.now.indices { levels.now[voice] = 0 }
        tickFilledBlock = false
        var done = 0
        while done < tickFrames {
            let part = min(tickFrames - done, Self.block - blockPosition)
            player.mix(into: sums.pointer + done * 2, frames: part, levels: &levels.now)
            done += part
            blockPosition += part
            if blockPosition == Self.block {
                blockPosition = 0
                tickFilledBlock = true
            }
        }
        levels.tickMade()
        for (index, track) in player.tracks.enumerated() {
            let sounding = track.isOn && (track.gainLeft != 0 || track.gainRight != 0) && track.instrument != 0
            if sounding {
                let rate = Double(module.instruments[track.instrument - 1].c3Frequency) * pow(2.0, Double(track.heardPitch - 384) / 96)
                notes.pitches[index] = ChannelPitch.note(ofRate: rate)
            } else {
                notes.pitches[index] = 0
            }
            if track.struck { notes.struck[index] = true }
            track.struck = false
        }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        let scale = Self.gain / 32768
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { mixTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            let from = sums.pointer + tickPosition * 2
            let out = buffer + done * 2
            for i in 0 ..< count {
                let l = Float(from[i * 2]) * scale, r = Float(from[i * 2 + 1]) * scale
                out[i * 2] = mono ? (l + r) * 0.5 : l
                out[i * 2 + 1] = mono ? (l + r) * 0.5 : r
            }
            tickPosition += count
            done += count
        }
    }

    /// The song from its start as the replayer's own example program writes it to a file: sixteen
    /// bits, left and right in turn, at the player's rate, and nothing after the song stops.
    public func renderRaw(frames: Int) -> [Int16] {
        restart(asReplayer: true)
        var output = [Int16](repeating: 0, count: frames * 2)
        let limit = Int64(0x7FFF_FFFF) / max(1, boost)
        var done = 0
        var ends = false
        while done < frames {
            if tickPosition == tickFrames {
                // (The replayer makes the tick on which it stops, and no more: unless that tick
                // fills its block to the end, and then the example program asks for more, and it
                // goes on, to stop again a row later.)
                if ends { break }
                mixTick()
                ends = player.stopTick && !tickFilledBlock
            }
            let count = min(frames - done, tickFrames - tickPosition)
            for i in 0 ..< count * 2 {
                let s = Int64(sums.pointer[tickPosition * 2 + i])
                output[done * 2 + i] = s > limit ? 0x7FFF : s < -limit ? -0x7FFF : Int16(truncatingIfNeeded: (s * boost) >> 16)
            }
            tickPosition += count
            done += count
        }
        restart()
        return output
    }

    /// What the replayer does with the song asked for, as its own example program plays it: a line
    /// a tick, of where it is (after the row it has read), its speed and tempo, and for each track
    /// whether it is playing, its pitch in units of the speed, and its two gains. For setting beside
    /// the replayer itself. After an @, the row being played and how many samples the tick lasts.
    /// The first line says which of the file's songs it is, and where in its list it starts.
    public func trace(seconds: Double) -> [String] {
        restart(asReplayer: true)
        var lines = ["start \(songList[currentSubsong].song) \(songList[currentSubsong].found.start)"]
        var frames = 0
        while Double(frames) < seconds * Double(outputSampleRate), !player.stopped {
            _ = player.runTick()
            frames += player.tickSamples
            var line = "\(player.order) \(player.row) \(player.tick) \(player.speed) \(player.tempo)"
            for track in player.tracks { line += " | \(track.isOn ? 1 : 0) \(track.pitch) \(track.gainLeft) \(track.gainRight)" }
            lines.append(line + " @ \(player.lastOrder) \(player.lastRow) \(player.tickSamples)")
        }
        restart()
        return lines
    }

    public var channelCount: Int { module.tracks }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }

    /// Every track plays samples.
    public var channelsAreSampled: Bool { true }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for (index, track) in player.tracks.enumerated() { sides[index] = track.side }
    }
}
