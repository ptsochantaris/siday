// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A FAR file, played by a player made for it (see `FarandolePlayer`) through `SampleMixer`.
///
/// Each of the sixteen channels is where the file puts it between the speakers. A file is looked
/// through for more than one song, as a module of any other kind is.
public final class FarandoleRenderer: Renderer {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length, empty: $0.empty) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }

    private let module: FarandoleModule
    private let songList: [ModuleSongs.Song]
    /// Which song first played each row. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>
    private let mono: Bool
    private var player: FarandolePlayer
    /// One tick of sound.
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    /// The part of a sample that ticks are over by, carried from tick to tick: in counts of the
    /// PC's timer times the samples a second that are being made.
    private var remainder: Int64 = 0
    private var levels = TickLevels(voices: FarandoleModule.channels)
    private var notes = TickNotes(voices: FarandoleModule.channels)

    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 32 * 60 * 120
    /// Set by measure, so that these files are about as loud as XM files are.
    private static let gain: Float = 0.187
    /// The most samples a tick can last: at the slowest tempo of the older kind, a second.
    private static let longestTick = outputSampleRate + outputSampleRate / 64

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try FarandoleModule(data)
        mono = options.stereo == .mono
        var info = TuneInfo(format: "FAR")
        info.title = module.title
        info.shortfalls = module.shortfalls
        self.info = info

        // Once through each of its songs in silence, to find how long it is.
        let module = module
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: module.rowsInAll)
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: module.rowsInAll)
        self.firstPlayedBy = firstPlayedBy
        songList = ModuleSongs.find(places: module.orders.count, isPattern: { _ in true }) { start, number in
            var player = FarandolePlayer(module, order: start, firstPlayedBy: firstPlayedBy, songNumber: number)
            var ticks = 0, frames = 0
            var remainder: Int64 = 0
            var watch = ModuleSongs.Watch()
            while ticks < Self.mostTicks {
                let more = player.runTick()
                if watch.tick(frames: frames, playedNote: player.playedNote, ledIntoEarlierSong: player.ledIntoEarlierSong) { break }
                if !more { break }
                ticks += 1
                frames += Self.frames(ofTick: player.tickLength, &remainder)
            }
            let length = ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
            return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: watch.sounded(player.playedNote), leadIn: watch.leadIn)
        }
        left = .allocate(capacity: Self.longestTick)
        right = .allocate(capacity: Self.longestTick)
        player = FarandolePlayer(module)
        currentSubsong = defaultSubsong
        restart()
    }

    deinit {
        left.deallocate()
        right.deallocate()
        firstPlayedBy.deallocate()
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    private func restart() {
        player = FarandolePlayer(module, order: songList[currentSubsong].start)
        tickFrames = 0
        tickPosition = 0
        remainder = 0
        levels.clear()
        notes.clear()
        loopCount = 0
    }

    /// How many samples a tick lasts that is so many counts of the PC's timer. What is over is
    /// kept for the next tick.
    private static func frames(ofTick length: Int, _ remainder: inout Int64) -> Int {
        remainder += Int64(length) * Int64(outputSampleRate)
        let frames = remainder / Int64(FarandolePlayer.timerRate)
        remainder -= frames * Int64(FarandolePlayer.timerRate)
        return max(1, min(longestTick, Int(frames)))
    }

    /// Runs the player for a tick, and makes the sound of that tick.
    private func nextTick() {
        if !player.runTick() { loopCount += 1 }
        tickFrames = Self.frames(ofTick: player.tickLength, &remainder)
        tickPosition = 0
        player.mixer.render(left: left, right: right, count: tickFrames)
        player.mixer.takeLevels(into: &levels.now)
        levels.tickMade()
        player.takeNotes(into: &notes)
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            for i in 0 ..< count {
                let l = left[tickPosition + i] * Self.gain, r = right[tickPosition + i] * Self.gain
                buffer[(done + i) * 2] = mono ? (l + r) * 0.5 : l
                buffer[(done + i) * 2 + 1] = mono ? (l + r) * 0.5 : r
            }
            tickPosition += count
            done += count
        }
    }

    public var channelCount: Int { FarandoleModule.channels }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for channel in 0 ..< FarandoleModule.channels { sides[channel] = player.mixer.side(of: channel) }
    }
}
