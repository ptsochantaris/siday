// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after MODRenderer, whose way with the sound chip's output is derived from pt2-clone,
// Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence (see THIRD-PARTY.md).

/// An Oktalyzer file: a module of four to eight tracks from the Amiga, played as Oktalyzer's own
/// routine played it, on an emulation of the Amiga's sound chip.
///
/// However many tracks it has, it is played on the chip's four voices, two to the left and two to
/// the right, and as with any module for the Amiga the two sides are brought most of the way
/// together (see `MODRenderer`). The two tracks of a voice that is split are on the same side.
///
/// A file is looked through for more than one song, as a module of any other kind is.
public final class OktalyzerRenderer: Renderer {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length, empty: $0.empty) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }
    public var hasEnded: Bool { player.stopped }
    public var isPlayedOnAnAmiga: Bool { true }

    private let module: OktalyzerModule
    private let songList: [ModuleSongs.Song]
    /// Which song first played each line. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>
    private let model: AmigaModel
    /// How much of the difference between the two sides is kept, halved: none of it for mono.
    private let side: Float
    private var player: OktalyzerPlayer
    /// One tick of sound: made at twice the rate, then brought down where it lies.
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    private var levels: TickLevels
    private var notes: TickNotes
    /// What the chip's own four voices are playing, which is asked for on the way to the tracks'.
    private var chipNotes = TickNotes(voices: 4)
    private var down = (HalfBand(), HalfBand())
    /// The part of a sample that ticks are over by, carried from tick to tick: in samples times the
    /// sound chip's clock.
    private var remainder = 0

    /// How long a tick is at twice the output's rate, and some to spare.
    /// (Worked out in 64 bits, as a tick's length is below: clocks times samples is more than the 32
    /// that a whole number has in a browser can hold.)
    private static let tickSpace = Int(Int64(OktalyzerPlayer.tickClocks) * Int64(outputSampleRate) * 2 / Int64(OktalyzerPlayer.chipClock)) + 64
    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// As loud as a MOD file, which is played on the same chip. See `MODRenderer`.
    private static let gain: Float = 0.26

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try OktalyzerModule(data)
        model = options.amigaModel
        side = options.stereo == .mono ? 0 : Float(max(0, min(1, options.amigaSeparation))) * 0.5
        levels = TickLevels(voices: module.trackCount)
        notes = TickNotes(voices: module.trackCount)

        var info = TuneInfo(format: "Oktalyzer")
        info.detail = "\(module.trackCount) tracks"
        info.shortfalls = module.shortfalls
        self.info = info

        // Once through each of its songs in silence, to find how long it is.
        let module = module, model = model
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, module.rowsInAll))
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: max(1, module.rowsInAll))
        self.firstPlayedBy = firstPlayedBy
        let tick = Double(OktalyzerPlayer.tickClocks) / Paula.clockHz
        songList = ModuleSongs.find(places: module.positions.count, isPattern: { module.lines(at: $0) > 0 }) { start, number in
            var player = OktalyzerPlayer(module, model: model, position: start, firstPlayedBy: firstPlayedBy, songNumber: number)
            var ticks = 0
            var watch = ModuleSongs.Watch()
            while ticks < Self.mostTicks {
                let more = player.runTick()
                ticks += 1
                if watch.tick(frames: Int(Double(ticks) * tick * Double(outputSampleRate)), playedNote: player.playedNote,
                              ledIntoEarlierSong: player.ledIntoEarlierSong) { break }
                if !more || player.stopped { break }
            }
            let length = ticks < Self.mostTicks ? Double(ticks) * tick : nil
            return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: watch.sounded(player.playedNote), leadIn: watch.leadIn)
        }
        left = .allocate(capacity: Self.tickSpace)
        right = .allocate(capacity: Self.tickSpace)
        player = OktalyzerPlayer(module, model: model)
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
        let song = songList[currentSubsong]
        player = OktalyzerPlayer(module, model: model, position: song.start, firstPlayedBy: firstPlayedBy, songNumber: song.number)
        down = (HalfBand(), HalfBand())
        tickFrames = 0
        tickPosition = 0
        levels.clear()
        notes.clear()
        chipNotes.clear()
        remainder = 0
        loopCount = 0
    }

    /// How many samples a tick lasts. What is over is kept for the next tick.
    private static func tickLength(_ remainder: inout Int) -> Int {
        let whole = Int64(OktalyzerPlayer.tickClocks) * Int64(outputSampleRate) + Int64(remainder)
        remainder = Int(whole % Int64(OktalyzerPlayer.chipClock))
        return Int(whole / Int64(OktalyzerPlayer.chipClock))
    }

    /// Runs the player for a tick, and makes the sound of that tick.
    private func nextTick() {
        if !player.runTick() { loopCount += 1 }
        tickFrames = Self.tickLength(&remainder)
        tickPosition = 0
        player.paula.generate(left: left, right: right, count: tickFrames)
        player.halfTick()
        player.paula.generate(left: left + tickFrames, right: right + tickFrames, count: tickFrames)
        player.takeLevels(into: &levels.now)
        levels.tickMade()
        player.takeNotes(into: &notes, chip: &chipNotes)
        for i in 0 ..< tickFrames {
            left[i] = down.0.step(left[i * 2], left[i * 2 + 1])
            right[i] = down.1.step(right[i * 2], right[i * 2 + 1])
        }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
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

    /// A light for each track: four, and one more for each voice that is split.
    public var channelCount: Int { module.trackCount }

    /// Every voice plays samples.
    public var channelsAreSampled: Bool { true }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        // The Amiga's own sides, however near they are brought to one another here.
        player.sides(into: sides)
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }

    /// What the player tells the sound chip, tick by tick, from the start of the song that is
    /// playing: for setting beside what Oktalyzer's own routine tells it. The song is left at its start.
    /// - Parameter wordsSeen: how many words Oktalyzer's own routine was seen to mix for each split
    ///   voice on each tick, to be gone by in place of this player's own reckoning of the chip's time.
    public func registerTicks(seconds: Double, wordsSeen: [[Int]]? = nil) -> [OktalyzerTick] {
        restart()
        player.record = OktalyzerTick()
        player.wordsSeen = wordsSeen
        var ticks: [OktalyzerTick] = []
        var clocks = 0.0
        while clocks < seconds * Paula.clockHz, !player.stopped {
            _ = player.runTick()
            if let tick = player.record { ticks.append(tick) }
            clocks += Double(OktalyzerPlayer.tickClocks)
        }
        restart()
        return ticks
    }
}
